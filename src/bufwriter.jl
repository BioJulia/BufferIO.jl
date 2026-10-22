"""
    BufWriter{T <: IO} <: AbstractBufWriter
    BufWriter(io::IO, [buffer_size::Int])::BufWriter

Wrap an `IO` in a struct with a new buffer, giving it the `AbstractBufWriter` interface.

The `BufWriter` has an infinitely growable buffer, and will only expand the buffer if `grow_buffer`
is called on it while it does not contain any data (as shown by `get_unflushed`).

Throw an `ArgumentError` if `buffer_size` is < 1.

```jldoctest
julia> io = IOBuffer(); wtr = BufWriter(io);

julia> print(wtr, "Hello!")

julia> write(wtr, [0x34, 0x12, 0x78, 0x56])
4

julia> isempty(read(io)) # wtr not flushed
true

julia> flush(wtr); seekstart(io); String(read(io))
"Hello!4\\x12xV"

julia> isempty(get_unflushed(wtr))
true
```

# Extended help
For an `io::Base.IO` type to function correctly when wrapped in a `BufWriter`,
it must implement:
* `close(io)`
* `flush(io)`
* `unsafe_write(io, ::Ptr{UInt8}, ::UInt)`

Seeking, and `filesize` and `position` of the `BufWriter`, additionally require `io`
to implement `seek`, `filesize` and `position`, where:
* Writing overwrites existing data, and seeking does not truncate `io`.
* `filesize(io)` includes any data written to `io` beyond `position(io)`.
  For example, `IOStream` meets this, because it writes out its own buffer when seeking.

Seeking is not supported if `io` is in append mode (e.g. a file opened with
`append = true`), because then `io` ignores its position when writing.
"""
mutable struct BufWriter{T <: IO} <: AbstractBufWriter
    io::T
    # Always points to index 1 of the buffer. Storing a `MemoryRef` and the capacity,
    # instead of the `Memory`, saves a dependent load in `get_buffer`, since the
    # data pointer is stored inline in the ref.
    # The capacity must always equal the length of the buffer, except when closed,
    # where it is zero, such that the closed writer can't be written to.
    ref::MemoryRef{UInt8}
    capacity::Int
    consumed::Int
    is_closed::Bool

    function BufWriter{T}(io::T, mem::Memory{UInt8}) where {T <: IO}
        if isempty(mem)
            throw(ArgumentError("BufWriter cannot be created with empty buffer"))
        end
        return new{T}(io, memoryref(mem), length(mem), 0, false)
    end
end

get_memory(x::BufWriter) = x.ref.mem

function set_memory!(x::BufWriter, mem::Memory{UInt8})
    x.ref = memoryref(mem)
    x.capacity = length(mem)
    return x
end

function BufWriter(io::IO, buffer_size::Int = 4096)
    if buffer_size < 1
        throw(ArgumentError("BufWriter buffer size must be at least 1"))
    end
    mem = Memory{UInt8}(undef, buffer_size)
    return BufWriter{typeof(io)}(io, mem)
end

"""
    BufWriter(f, io::IO, [buffer_size::Int])

Create a `BufWriter` wrapping `io`, then call `f` on the `BufWriter`,
and close the writer once `f` is finished or if it errors.

This pattern is useful for automatically cleaning up the resource of
`io`.

```jldoctest
julia> io = IOBuffer();

julia> BufWriter(io) do writer
           write(writer, "hello, world!")
           shallow_flush(writer)
           seekstart(io)
           println(String(read(io)))
       end
hello, world!

julia> iswritable(io) # closing writer closes io also
false
```
"""
function BufWriter(f, io::IO, buffer_size::Int = 4096)
    writer = BufWriter(io, buffer_size)
    return try
        f(writer)
    finally
        close(writer)
    end
end

"""
    get_buffer(io::AbstractBufWriter)::MutableMemoryView{UInt8}

Get the available mutable buffer of `io` that can be written to.

Calling this function should never do actual system I/O, and in particular
should not attempt to flush data from the buffer or grow the buffer.
To increase the size of the buffer, call [`grow_buffer`](@ref).

# Examples
```jldoctest
julia> writer = BufWriter(IOBuffer(), 5);

julia> buffer = get_buffer(writer);

julia> (typeof(buffer), length(buffer))
(MutableMemoryView{UInt8}, 5)

julia> write(writer, "abcde")
5

julia> get_buffer(writer) |> isempty
true

julia> flush(writer)

julia> buffer = get_buffer(writer); length(buffer)
5
```
"""
function get_buffer(x::BufWriter)::MutableMemoryView{UInt8}
    len = x.capacity - x.consumed
    # When the buffer is full, `consumed + 1` is one past the end of the memory,
    # which is not a valid index for a `MemoryRef`. Since the memory is never empty,
    # index 1 is always valid.
    index = ifelse(iszero(len), 1, x.consumed + 1)
    ref = @inbounds memoryref(x.ref, index)
    return MemoryViews.unsafe_from_parts(ref, len)
end

function get_nonempty_buffer(x::BufWriter, min_size::Int)
    # The returned buffer must never be empty
    min_size = max(min_size, 1)
    n_avail = x.capacity - x.consumed
    n_avail ≥ min_size && return get_buffer(x)
    return _get_nonempty_buffer(x, min_size)
end

@noinline function _get_nonempty_buffer(x::BufWriter, min_size::Int)
    shallow_flush(x)
    x.capacity ≥ min_size && return get_buffer(x)
    # Note: The caller ensures min_size is positive, so this cast is safe
    new_size = overallocation_size(min_size % UInt)
    set_memory!(x, Memory{UInt8}(undef, new_size))
    return get_buffer(x)
end

"""
    get_unflushed(io::AbstractBufWriter)::MutableMemoryView{UInt8}

Return a view into the buffered data already written to `io` and `consume`d,
but not yet flushed to its underlying IO.

Bytes not appearing in the buffer may not be completely flushed
if there are more layers of buffering in the IO wrapped by `io`. However, any bytes
already consumed and not returned in `get_unflushed` should not be buffered in `io` itself.

Mutating the returned buffer is allowed, and should not cause `io` to malfunction.
After mutating the returned buffer and calling `flush`, values in the updated buffer
will be flushed.

This function has no default implementation and methods are optionally added to subtypes
of `AbstractBufWriter` that can fullfil the above restrictions.

# Examples
```jldoctest
julia> io = IOBuffer(); writer = BufWriter(io);

julia> isempty(get_unflushed(writer))
true

julia> write(writer, "abc"); unflushed = get_unflushed(writer);

julia> println(unflushed)
UInt8[0x61, 0x62, 0x63]

julia> unflushed[2] = UInt8('x')
0x78

julia> flush(writer); take!(io) |> println
UInt8[0x61, 0x78, 0x63]

julia> get_unflushed(writer) |> isempty
true
```
"""
function get_unflushed(x::BufWriter)::MutableMemoryView{UInt8}
    return MemoryViews.unsafe_from_parts(x.ref, x.consumed)
end

"""
    shallow_flush(io::AbstractBufWriter)::Int

Clear the buffer(s) of `io` by writing to the underlying I/O, but do not
flush the underlying I/O.
Return the number of bytes flushed.

This function is not generically defined for `AbstractBufWriter`.

```jldoctest
julia> io = IOBuffer();

julia> wtr = BufWriter(io);

julia> write(wtr, "hello!");

julia> take!(io)
UInt8[]

julia> shallow_flush(wtr)
6

julia> String(take!(io))
"hello!"
```
"""
function shallow_flush(x::BufWriter)::Int
    if x.is_closed
        throw(IOError(IOErrorKinds.ClosedIO))
    end
    to_flush = x.consumed
    if !iszero(to_flush)
        write_buffered(x, to_flush)
        x.consumed = 0
    end
    return to_flush
end

# Write the first `n` bytes of the memory of `x` to the underlying IO
function write_buffered(x::BufWriter, n::Int)
    used = ImmutableMemoryView(MemoryViews.unsafe_from_parts(x.ref, n))
    GC.@preserve used unsafe_write(x.io, pointer(used), length(used) % UInt)
    return nothing
end

"""
    grow_buffer(io::AbstractBufWriter)::Int

Increase the amount of bytes in the writeable buffer of `io` if possible, returning
the number of bytes added. After calling `grow_buffer` and getting `n`,
the buffer obtained by `get_buffer` should have `n` more bytes.

The buffer is usually grown by flushing the buffer, expanding or reallocating the buffer.
If none of these can grow the buffer, return zero.

!!! note
    Idiomatically, users should not call `grow_buffer` when the buffer is not empty,
    because doing so forces growing the buffer instead of letting `io` choose an optimal
    buffer size. Calling `grow_buffer` with a nonempty buffer is only appropriate if, for
    algorithmic reasons you need `io` buffer to be able to hold some minimum amount of data
    before flushing.

# Examples
```jldoctest
julia> v = VecWriter(undef, 0); get_buffer(v) |> isempty
true

julia> n_grown = grow_buffer(v); n_grown > 0
true

julia> length(get_buffer(v)) == n_grown
true
```
"""
function grow_buffer(x::BufWriter)
    flushed = @inline shallow_flush(x)
    return iszero(flushed) ? grow_buffer_slowpath(x) : flushed
end

@noinline function grow_buffer_slowpath(x::BufWriter)
    # We know we have no data to flush
    old_size = x.capacity
    new_size = overallocation_size(old_size % UInt)
    set_memory!(x, Memory{UInt8}(undef, new_size))
    return new_size - old_size
end

"""
    resize_buffer(io::Union{BufWriter, BufReader}, n::Int) -> io

Resize the internal buffer of `io` to exactly `n` bytes.

Throw an `ArgumentError` if `n` is less than 1, or lower than the currently
number of buffered bytes (length of `get_unflushed` for `BufWriter`, length of
`get_buffer` for `BufReader`).

```jldoctest
julia> w = BufWriter(IOBuffer());

julia> write(w, "abc")
3

julia> length(get_buffer(resize_buffer(w, 5)))
2

julia> resize_buffer(w, 2)
ERROR: ArgumentError: Buffer size smaller than current number of buffered bytes
[...]

julia> shallow_flush(w)
3

julia> resize_buffer(w, 2) === w
true
```
"""
function resize_buffer(x::BufWriter, n::Int)
    # Else, resizing would make room in the buffer of a closed writer
    x.is_closed && throw(IOError(IOErrorKinds.ClosedIO))
    x.capacity == n && return x
    n < 1 && throw(ArgumentError("Buffer size must be at least 1"))
    n_buffered = x.consumed
    if n < n_buffered
        throw(ArgumentError("Buffer size smaller than current number of buffered bytes"))
    end
    new_buffer = Memory{UInt8}(undef, n)
    if !iszero(n_buffered)
        dst = @inbounds MemoryView(new_buffer)
        src = MemoryViews.unsafe_from_parts(x.ref, n_buffered)
        @inbounds copyto!(dst, src)
    end
    set_memory!(x, new_buffer)
    return x
end

"""
    flush(io::AbstractBufWriter)::Nothing

Ensure that all intermediate buffered writes in `io` reaches their final destination.

For writers with an underlying I/O, the underlying I/O should also be flushed.

For writers without an underlying I/O, where the final writing destination is `io`
ifself, the implementation may be simply `return nothing`.

# Examples
```jldoctest
julia> buf = IOBuffer(); io = BufWriter(buf);

julia> print(io, "hello")

julia> String(take!(buf))
""

julia> flush(io)

julia> String(take!(buf))
"hello"
```
"""
function Base.flush(x::BufWriter)
    @inline shallow_flush(x)
    flush(x.io)
    return nothing
end

function Base.close(x::BufWriter)
    x.is_closed && return nothing
    # Mark closed first, so `x` is closed even if writing to or closing the underlying
    # IO throws. This keeps the content of the memory.
    n_buffered = x.consumed
    mark_closed!(x)
    iszero(n_buffered) || write_buffered(x, n_buffered)
    # Per the docstring of `close(::IO)`, this flushes the underlying IO
    close(x.io)
    return nothing
end

function mark_closed!(x::BufWriter)
    x.is_closed = true
    # Make the buffer empty, so writes will try to grow the buffer and throw.
    # The memory is kept, since `get_buffer` relies on it never being empty.
    x.capacity = 0
    x.consumed = 0
    return nothing
end

Base.isopen(x::BufWriter) = !x.is_closed

"""
    take_inner(io::BufWriter{T})::T

Write the buffered data of `io` to its wrapped IO using [`shallow_flush`](@ref),
then close `io` and return the wrapped IO. The wrapped IO is neither closed not flushed.

After this, all operations on `io` which would access the wrapped IO throw an `IOError`
of kind `ClosedIO`, and `close(io)` does nothing.

Throw an `IOError` of kind `ClosedIO` if `io` is already closed.

# Examples
```jldoctest
julia> buf = IOBuffer(); writer = BufWriter(buf);

julia> write(writer, "abc");

julia> take_inner(writer) === buf
true

julia> String(take!(buf)) # buffered data was written
"abc"

julia> flush(writer)
ERROR: Unsupported operation on closed IO
[...]
```
"""
function take_inner(x::BufWriter)
    shallow_flush(x) # throws if closed
    mark_closed!(x)
    return x.io
end

function consume(x::BufWriter, n::Int)
    @boundscheck if (n % UInt) > (x.capacity - x.consumed) % UInt
        throw(IOError(IOErrorKinds.ConsumeBufferError))
    end
    x.consumed += n
    return nothing
end

"""
    seek(io::AbstractBufWriter, offset::Integer) -> io

Seek `io` to the zero-based position `offset`, and return `io`.
Subsequent writes write (or overwrite) data starting at `offset`.

Valid values for `offset` are in `0:filesize(io)`, if `filesize(io)` is defined.
Seeking outside these bounds throws an `IOError` of kind `BadSeek`, and leaves `io`
unchanged.

Seeking never changes the filesize, nor any data already written to `io`, including data
not yet flushed. In particular, seeking never truncates the underlying file or IO.

Seeking may write buffered data to the underlying IO, but need not flush it.
Use `flush` for that.

This method is not generically defined for `AbstractBufWriter`. Implementors of `seek`
should also define `filesize(io)` and `position(io)`

# Examples
```jldoctest
julia> buf = IOBuffer();

julia> io = BufWriter(buf);

julia> write(io, "abcdef");

julia> seek(io, 3);

julia> write(io, "xyzghi");

julia> seek(io, 10)
ERROR: Invalid seek, possibly seek out of bounds
[...]

julia> flush(io);

julia> String(take!(buf))
"abcxyzghi"
```
"""
function Base.seek(io::BufWriter, offset::Int)
    # Check before writing out the buffer, so an invalid seek leaves `io` unchanged.
    # This also throws if `io` is closed.
    in(offset, 0:filesize(io)) || throw(IOError(IOErrorKinds.BadSeek))
    shallow_flush(io)
    seek(io.io, offset)
    return io
end

"""
    filesize(io::AbstractBufWriter)::Int

Get the size, in bytes, of the data written to `io`, including data which has been
committed with `consume`, but not yet flushed.
This is the size the underlying file or IO will have once `io` is flushed, provided
nothing else modifies it.

`0:filesize(io)` is the range of valid offsets for `seek`, and `position(io)` is always
in this range. Writing beyond the end of the data increases the filesize.
Other operations, including seeking and flushing, do not change it.

Types implementing `filesize` should also implement `seek` and `position`.

# Examples
```jldoctest
julia> io = BufWriter(IOBuffer());

julia> write(io, "abc");

julia> filesize(io) # includes unflushed data
3

julia> seek(io, 1); filesize(io)
3

julia> write(io, "xyz"); filesize(io)
4
```
"""
function Base.filesize(io::BufWriter)
    io.is_closed && throw(IOError(IOErrorKinds.ClosedIO))
    # Writes overwrite, but never truncate, so the data written to `io` ends at the
    # end of the wrapped IO, or at the end of the buffered data, whichever is later.
    # This relies on the wrapped IO following the requirements in the docstring of
    # `BufWriter`.
    buffered_end = Int(position(io.io))::Int + io.consumed
    return max(Int(filesize(io.io))::Int, buffered_end)
end

"""
    Base.position(io::AbstractBufWriter)::Int

Get the zero-based stream position.

If the stream position is `p` (zero-based), then the next byte written will be byte number
`p + 1` (one-based) in the file.
The stream position accounts for buffered (consumed, but unflushed) bytes.
The value of `position` is always in `0:filesize(io)`, if `filesize` is defined.

# Examples
```jldoctest
julia> io = BufWriter(IOBuffer());

julia> write(io, "hello");

julia> (filesize(io), position(io))
(5, 5)

julia> seek(io, 2);

julia> (filesize(io), position(io))
(5, 2)
```
"""
function Base.position(io::BufWriter)
    io.is_closed && throw(IOError(IOErrorKinds.ClosedIO))
    return position(io.io) + io.consumed
end

# This specialized method is used whenever `n_bytes` is longer than the remaining room in `io`.
@noinline function _unsafe_write(io::BufWriter, ptr::Ptr{UInt8}, n_bytes::UInt)::Int
    shallow_flush(io)

    # If we fill the buffer up completely, or we can't fit the write in the buffer,
    # we write to the underlying IO directly, bypassing the buffer.
    buffer = get_buffer(io)
    if n_bytes ≥ length(buffer)
        unsafe_write(io.io, ptr, n_bytes)
    else
        GC.@preserve buffer unsafe_copyto!(pointer(buffer), ptr, n_bytes)
        @inbounds consume(io, n_bytes % Int)
    end
    return n_bytes % Int
end
