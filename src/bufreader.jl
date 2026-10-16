"""
    BufReader{T <: IO} <: AbstractBufReader
    BufReader(io::IO, [buffer_size::Int])::BufReader

Wrap an `IO` in a struct with a new buffer, giving it the `AbstractBufReader` interface.

The `BufReader` has an infinitely growable buffer, which may grow when
[`fill_buffer`](@ref) is called.

When filling its buffer, the `BufReader` may move the buffered bytes to the beginning of
its internal memory to make room for new bytes. This compaction is guaranteed to be
amortized `O(n_bytes_read)`, no matter how calls to `fill_buffer` and `consume` are interleaved.

This wrapper reads from `io` using `readbytes!`. If `io` is not EOF,
and `readbytes!` reads zero bytes, an exception is thrown when filling the buffer.

Throw an `ArgumentError` if `buffer_size` is less than 1.

```jldoctest
julia> rdr = BufReader(IOBuffer("Hello, world!\\nabc\\r\\ndef"));

julia> get_buffer(rdr) |> isempty
true

julia> peek(rdr)
0x48

julia> readline(rdr)
"Hello, world!"

julia> String(readavailable(rdr))
"abc\\r\\ndef"
```

# Extended help
For an `io::Base.IO` type to function correctly when wrapped in a `BufReader`,
it must implement:
* `eof(io)::Bool`, which may block until at least one byte is available or EOF is known.
  If this returns `false`, at least one byte must be available to read.
* Either `readbytes!(io, v::MutableMemoryView{UInt8})::Integer`, or else
  `unsafe_read(io, ::Ptr{UInt8}, ::UInt)` and `bytesavailable(io)::Integer`.
  If `readbytes!` are implemented, it should read at least one byte when
  `eof(io) === false`.
"""
mutable struct BufReader{T <: IO} <: AbstractBufReader
    const io::T
    # Always points to index 1 of the buffer. Storing a `MemoryRef` instead of the
    # `Memory` saves a dependent load in `get_buffer`, since the data pointer
    # is stored inline in the ref.
    ref::MemoryRef{UInt8}
    start::Int
    stop::Int
    is_closed::Bool

    function BufReader{T}(io::T, mem::Memory{UInt8}) where {T <: IO}
        if isempty(mem)
            throw(ArgumentError("BufReader cannot be created with empty buffer"))
        end
        return new{T}(io, memoryref(mem), 1, 0, false)
    end
end

get_memory(x::BufReader) = x.ref.mem

function BufReader(io::IO, buffer_size::Int = 8192)
    if buffer_size < 1
        throw(ArgumentError("BufReader buffer size must be at least 1"))
    end
    mem = Memory{UInt8}(undef, buffer_size)
    return BufReader{typeof(io)}(io, mem)
end

"""
    BufReader(f, io::IO, [buffer_size::Int])

Create a `BufReader` wrapping `io`, then call `f` on the `BufReader`,
and close the reader once `f` is finished or if it errors.

This pattern is useful for automatically cleaning up the resource of
`io`.

```jldoctest
julia> io = IOBuffer("hello world");

julia> BufReader(io) do reader
           println(String(read(io, 5)))
       end
hello

julia> read(io) # closing reader closes io also
ERROR: ArgumentError: read failed, IOBuffer is not readable
[...]
```
"""
function BufReader(f, io::IO, buffer_size::Int = 8192)
    reader = BufReader(io, buffer_size)
    return try
        f(reader)
    finally
        close(reader)
    end
end

function get_buffer(x::BufReader)::ImmutableMemoryView{UInt8}
    len = x.stop - x.start + 1
    # When the buffer is fully consumed, `start` may be one past the end of the memory,
    # which is not a valid index for a `MemoryRef`. Since the memory is never empty,
    # index 1 is always valid.
    index = ifelse(iszero(len), 1, x.start)
    ref = @inbounds memoryref(x.ref, index)
    return ImmutableMemoryView(MemoryViews.unsafe_from_parts(ref, len))
end

function fill_buffer(x::BufReader)::Int
    x.is_closed && throw(IOError(IOErrorKinds.ClosedIO))

    # Move the buffered bytes to the beginning of the memory, if that frees at least as
    # many bytes as it moves. The freed bytes have been consumed since `start` was last
    # reset to 1, so the total number of bytes moved is at most the number of bytes
    # consumed.
    # This avoids any pathological cases that require either copying most of the buffer
    # to make room for few bytes, or else calls read on the underlying IO to read only
    # a few bytes.
    # In particular, an exhausted buffer is reset here without copying.
    n_buffered = x.stop - x.start + 1
    mem = get_memory(x)
    if x.start - 1 ≥ n_buffered
        iszero(n_buffered) || copyto!(mem, 1, mem, x.start, n_buffered)
        x.start = 1
        x.stop = n_buffered
    end

    # Add more bytes at the end, if possible
    if x.stop < length(mem)
        n_added = read_some!(x.io, MemoryView(mem)[(x.stop + 1):length(mem)])
        x.stop += n_added
        return n_added
    else
        return fill_buffer_slowpath(x)
    end
end

@noinline function fill_buffer_slowpath(x::BufReader)::Int
    # We now know there is no more room at the end, and the buffer contains more bytes
    # than there is room for at the beginning, so moving the bytes would be too expensive.
    # Hence, we grow the buffer. Check EOF first, so we don't allocate a new buffer
    # just to discover there is nothing to read.
    eof(x.io) && return 0
    n_filled = x.stop - x.start + 1
    mem = get_memory(x)
    size = overallocation_size(length(mem) % UInt)
    new_mem = Memory{UInt8}(undef, size)
    copyto!(new_mem, 1, mem, x.start, n_filled)
    x.ref = memoryref(new_mem)
    mem = new_mem
    # Now fill in the newly freed bytes
    view = MemoryView(mem)[(n_filled + 1):length(mem)]
    @assert !isempty(view)
    n_added = read_nonzero!(x.io, view)
    x.start = 1
    x.stop = n_added + n_filled
    return n_added
end

# Read at least one byte from the underlying IO into `dst`, which must be nonempty.
# The underlying IO must be known to not be EOF.
function read_nonzero!(io::IO, dst::MutableMemoryView{UInt8})::Int
    n_read = 0
    attempts = 0
    while n_read == 0
        # Safety check to prevent a bad IO object from making this loop
        # infinite
        attempts > 2 && error("BufReader's IO is not eof, but does not yield any bytes")
        n_read = readbytes!(io, dst)
        attempts += 1
    end
    return n_read
end

# Read into `dst`, which must be nonempty, returning the number of bytes read,
# which is zero only at EOF.
# This function exists for dispatch; most underlying IO's need an `eof(io)` guard
# to prevent throwing, but we must not call `eof(IOStream)` specifically since that
# prevents an optimization (see below).
# If not for this optimization, this function could be inlined and removed.
function read_some!(io::IO, dst::MutableMemoryView{UInt8})::Int
    eof(io) && return 0
    return read_nonzero!(io, dst)
end

# For `IOStream`, calling `eof` first would fill the stream's internal buffer, so every
# byte would be copied twice. Instead, we do a single `ios_read`, which returns zero only
# at EOF, and which reads directly into `dst`, bypassing the stream's buffer, if `dst`
# is large.
# Base only has a fast `IOStream` method for views of `Memory` (but not for
# `MemoryView`) from Julia 1.12, so on earlier versions, we use the generic method.
@static if VERSION ≥ v"1.12"
    function read_some!(io::IOStream, dst::MutableMemoryView{UInt8})::Int
        mem = MemoryViews.memory(dst)
        # The all=false is specific to IOStream, and is documented.
        return readbytes!(io, view(mem, only(parentindices(dst))); all = false)
    end
end

function read_into!(x::BufReader, dst::MutableMemoryView{UInt8})::Int
    isempty(dst) && return 0
    src = get_buffer(x)
    isempty(src) && return read_into_slowpath!(x, dst)
    n_read = copyto_start!(dst, src)
    @inbounds consume(x, n_read)
    return n_read
end

# Called when the buffer is empty and `dst` is nonempty.
@noinline function read_into_slowpath!(x::BufReader, dst::MutableMemoryView{UInt8})::Int
    # If `dst` is at least as large as the buffer, filling the buffer can't save any
    # reads from the underlying IO, so we read directly into `dst`, bypassing the buffer.
    if length(dst) ≥ length(get_memory(x))
        x.is_closed && throw(IOError(IOErrorKinds.ClosedIO))
        return read_some!(x.io, dst)
    end
    fill_buffer(x)
    n_read = copyto_start!(dst, get_buffer(x))
    @inbounds consume(x, n_read)
    return n_read
end

function consume(x::BufReader, n::Int)
    existing_bytes = x.stop - x.start + 1
    @boundscheck if (existing_bytes % UInt) < (n % UInt)
        throw(IOError(IOErrorKinds.ConsumeBufferError))
    end
    x.start += n
    return nothing
end

function resize_buffer(x::BufReader, n::Int)
    length(get_memory(x)) == n && return x
    n < 1 && throw(ArgumentError("Buffer size must be at least 1"))
    n_buffered = x.stop - x.start + 1
    if n < n_buffered
        throw(ArgumentError("Buffer size smaller than current number of buffered bytes"))
    end
    new_buffer = Memory{UInt8}(undef, n)
    if !iszero(n_buffered)
        dst = @inbounds MemoryView(new_buffer)[1:n_buffered]
        src = @inbounds MemoryView(get_memory(x))[x.start:x.stop]
        @inbounds copyto!(dst, src)
    end
    x.ref = memoryref(new_buffer)
    x.start = 1
    x.stop = n_buffered
    return x
end

function Base.close(x::BufReader)
    x.is_closed && return nothing
    mark_closed!(x)
    close(x.io)
    return nothing
end

"""
    take_inner(io::BufReader{T})::T

Close `io` and return its wrapped IO, without closing the wrapped IO.

Any data buffered in `io` and not yet consumed is discarded.
To keep it, copy it from `get_buffer(io)` before calling `take_inner`.

After this, all operations on `io` which would access the wrapped IO throw an `IOError`
of kind `ClosedIO`, and `close(io)` does nothing.

Throw an `IOError` of kind `ClosedIO` if `io` is already closed.

# Examples
```jldoctest
julia> reader = BufReader(IOBuffer("abcdef"), 4);

julia> String(read(reader, 2))
"ab"

julia> io = take_inner(reader); # "cd" was buffered in reader, and is discarded

julia> String(read(io))
"ef"

julia> read(reader, UInt8)
ERROR: Unsupported operation on closed IO
[...]
```
"""
function take_inner(x::BufReader)
    x.is_closed && throw(IOError(IOErrorKinds.ClosedIO))
    mark_closed!(x)
    return x.io
end

function mark_closed!(x::BufReader)
    x.is_closed = true
    # Discard buffered data, such that the closed reader is empty
    x.start = 1
    x.stop = 0
    return nothing
end

Base.isopen(x::BufReader) = !x.is_closed

function Base.position(x::BufReader)
    x.is_closed && throw(IOError(IOErrorKinds.ClosedIO))
    res = Int(position(x.io))::Int - length(get_buffer(x))
    @assert res >= 0
    return res
end

"""
    seek(io::AbstractBufReader, offset::Int) -> io

Seek `io` to the zero-based position `offset`, if `io` supports seeking,
and return `io`.
When `offset === 0`, this is equivalent to `seekstart`.
If `filesize(io)` is implemented, `seek(io, filesize(io))` is equivalent to `seekend(io)`.

Valid offsets are `0:filesize(io)`, if `io` implements `filesize`. Seeking outside
these bounds throws an `IOError` of kind `BadSeek`.

This method is not generically defined for `AbstractBufReader`.

```jldoctest
julia> rdr = BufReader(IOBuffer("Hello, world!"));

julia> String(read(rdr, 5))
"Hello"

julia> seek(rdr, 3);

julia> String(read(rdr, 5))
"lo, w"

julia> seek(rdr, 13);

julia> read(rdr)
UInt8[]
```
"""
function Base.seek(x::BufReader, position::Int)
    x.is_closed && throw(IOError(IOErrorKinds.ClosedIO))
    if !in(position, 0:filesize(x.io))
        throw(IOError(IOErrorKinds.BadSeek))
    end
    x.start = 1
    x.stop = 0
    return seek(x.io, position)
end

function relative_seek(io::BufReader, delta::Int)
    # Check if we can achieve the seek by moving purely within
    # the buffer
    new_start = io.start + delta
    return if in(new_start, 1:(io.stop + 1))
        io.start = new_start
        io
    else
        @noinline _relative_seek(io, delta)
    end
end

_relative_seek(io::BufReader, delta::Int) = seek(io, position(io) + delta)

is_expandable(::Type{<:BufReader}) = true
