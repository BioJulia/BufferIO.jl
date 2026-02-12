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

julia> write(wtr, [0x1234, 0x5678])
4

julia> isempty(read(io)) # wtr not flushed
true

julia> flush(wtr); seekstart(io); String(read(io))
"Hello!4\\x12xV"

julia> isempty(get_unflushed(wtr))
true
```
"""
mutable struct BufWriter{T <: IO} <: AbstractBufWriter
    io::T
    buffer::Memory{UInt8}
    consumed::Int
    is_closed::Bool

    function BufWriter{T}(io::T, mem::Memory{UInt8}) where {T <: IO}
        if isempty(mem)
            throw(ArgumentError("BufWriter cannot be created with empty buffer"))
        end
        return new{T}(io, mem, 0, false)
    end
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
    return @inbounds MemoryView(x.buffer)[(x.consumed + 1):end]
end

function get_nonempty_buffer(x::BufWriter, min_size::Int)
    n_avail = length(x.buffer) - x.consumed
    n_avail ≥ min_size && return get_buffer(x)
    return _get_nonempty_buffer(x, min_size)
end

@noinline function _get_nonempty_buffer(x::BufWriter, min_size::Int)
    shallow_flush(x)
    length(x.buffer) ≥ min_size && return get_buffer(x)
    # Note: If min_size is negative, we would have taken the branch above
    # so this cast is safe
    new_size = overallocation_size(min_size % UInt)
    x.buffer = Memory{UInt8}(undef, new_size)
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
    return @inbounds MemoryView(x.buffer)[1:(x.consumed)]
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
        used = @inbounds ImmutableMemoryView(x.buffer)[1:to_flush]
        write(x.io, used)
        x.consumed = 0
    end
    return to_flush
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
    old_size = length(x.buffer)
    new_size = overallocation_size(old_size % UInt)
    new_memory = Memory{UInt8}(undef, new_size)
    x.buffer = new_memory
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
    length(x.buffer) == n && return x
    n < 1 && throw(ArgumentError("Buffer size must be at least 1"))
    n_buffered = x.consumed
    if n < n_buffered
        throw(ArgumentError("Buffer size smaller than current number of buffered bytes"))
    end
    new_buffer = Memory{UInt8}(undef, n)
    if !iszero(n_buffered)
        dst = @inbounds MemoryView(new_buffer)
        src = @inbounds MemoryView(x.buffer)[1:n_buffered]
        @inbounds copyto!(dst, src)
    end
    x.buffer = new_buffer
    return x
end

"""
    flush(io::AbstractBufWriter)::Nothing

Ensure that all intermediate buffered writes in `io` reaches their final destination.

For writers with an underlying I/O, the underlying I/O should also be flushed.

For writers without an underlying I/O, where the final writing destination is `io`
ifself, the implementation may be simply `return nothing`.
"""
function Base.flush(x::BufWriter)
    @inline shallow_flush(x)
    flush(x.io)
    return nothing
end

function Base.close(x::BufWriter)
    x.is_closed && return nothing
    flush(x)
    close(x.io)
    x.is_closed = true
    return nothing
end

function consume(x::BufWriter, n::Int)
    @boundscheck if (n % UInt) > (length(x.buffer) - x.consumed) % UInt
        throw(IOError(IOErrorKinds.ConsumeBufferError))
    end
    x.consumed += n
    return nothing
end

"""
    seek(io::AbstractBufWriter, offset::Int) -> io

Flush `io`, then seek `io` to the zero-based position `offset`.

Valid values for `offset` are in `0:filesize(io)`, if `filesize(io)` is defined.
The filesize  is computed *after* the flush.
Seeking outside these bounds throws an `IOError` of kind `BadSeek`.
Seeking should only change the filesize through its flush, so seeking an already-flushed
stream should not change the filesize.

If seeking to before the current position (as defined by `position`), data between
the new and the previous position need not be changed, and the underlying file or IO
need not immediately be truncated. However, new write operations should write (or
overwrite) data at the new position.

This method is not generically defined for `AbstractBufWriter`. Implementors of `seek`
should also define `filesize(io)` and `position(io)`
"""
function Base.seek(io::BufWriter, offset::Int)
    flush(io)
    fz = filesize(io.io)
    in(offset, 0:fz) || throw(IOError(IOErrorKinds.BadSeek))
    seek(io.io, offset)
    return io
end

"""
    filesize(io::AbstractBufWriter)::Int

Get the filesize of `io`, in bytes.

The filesize is understood as the number of bytes flushed to the underlying resource
of `io`, and which can be retrived by re-reading the data (so e.g. some streams like
`devnull` may have a filesize of zero, even if many bytes was flushed to it.)
The filesize does not depend on, and does not include, the number of buffered and
unflushed bytes.

Types implementing `filesize` should also implement `seek` and `position`.
"""
Base.filesize(io::BufWriter) = filesize(io.io)

"""
    Base.position(io::AbstractBufWriter)::Int

Get the zero-based stream position.

If the stream position is `p` (zero-based), then the next byte written will be byte number
`p + 1` (one-based) in the file.
The stream position does account for buffered (consumed, but unflushed) bytes, and therefore may exceed `filesize`.
After calling `flush`, `position` must be in `0:filesize(io)`, if `filesize` is defined.
"""
Base.position(io::BufWriter) = position(io.io) + io.consumed

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
