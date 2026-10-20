"""
    module BufferIO.Testing

Minimal implementations of `AbstractBufReader` and `AbstractBufWriter` intended for
testing code that is generic over buffered readers and writers, similar in spirit to
`Test.GenericString`.

The types in this module implement only the required interface methods, and have
deliberately restricted buffers. This exercises the code paths that `BufReader` or
`VecWriter` never hit, such as `fill_buffer` returning `nothing`, and fallback
definitions of optional methods.
Furthermore, `BoundedReader` overwrites its old buffer whenever views of its buffer may be
invalidated, which helps to catch code that uses such views after they have been invalidated.

These types are not optimized for performance, and should only be used in tests.

See also: [`BoundedReader`](@ref BufferIO.Testing.BoundedReader),
[`BoundedWriter`](@ref BufferIO.Testing.BoundedWriter)
"""
module Testing

using ..BufferIO: BufferIO,
    AbstractBufReader,
    AbstractBufWriter,
    CursorReader,
    IOError,
    IOErrorKinds,
    get_buffer,
    consume

using MemoryViews: ImmutableMemoryView, MutableMemoryView, MemoryView

export BoundedReader, BoundedWriter

"""
    BoundedReader(data, max_buffer_size::Int; max_fill::Int = 1) <: AbstractBufReader

Reader of the bytes of `data`, whose buffer can hold at most `max_buffer_size` bytes,
and where each call to `fill_buffer` adds at most `max_fill` bytes.
`data` can be any object `x` which implements `ImmutableMemoryView{UInt8}(x)`.

When the buffer holds `max_buffer_size` bytes, `fill_buffer` returns `nothing`, and so
`BufferIO.is_expandable(BoundedReader)` is `false`.
This makes `BoundedReader` useful to test that generic code correctly handles readers
with a limited buffer size, and, with a small `max_fill`, readers which fill their buffer
in small increments.

Views returned by `get_buffer` are invalidated by `fill_buffer`, `consume` and `close`.
To catch code which nonetheless uses such views, every call to these functions moves
the buffer to new memory, and overwrites the old memory by flipping all bits of every byte.
Hence, invalidated views will appear to contain different data.
The bytes of `data` itself are never modified.

`BoundedReader` only implements the methods required of an `AbstractBufReader`, so
optional methods such as `seek` and `position` are unsupported or use the generic
fallback definitions.

# Examples
```jldoctest
julia> using BufferIO.Testing: BoundedReader

julia> reader = BoundedReader("abcdefg", 4; max_fill = 3);

julia> fill_buffer(reader), fill_buffer(reader), fill_buffer(reader)
(3, 1, nothing)

julia> buffer = get_buffer(reader); String(buffer)
"abcd"

julia> consume(reader, 3); buffer == b"abcd" # buffer invalidated by consume
false

julia> String(read(reader))
"defg"

julia> BufferIO.is_expandable(BoundedReader)
false
```
"""
mutable struct BoundedReader <: AbstractBufReader
    # Bytes are moved from `inner` to `buffer` when filling the buffer
    const inner::CursorReader
    # Replaced by new memory whenever views of the buffer may be invalidated
    buffer::Memory{UInt8}
    const max_buffer_size::Int
    const max_fill::Int
    closed::Bool

    function BoundedReader(data, max_buffer_size::Int; max_fill::Int = 1)
        max_buffer_size < 1 && throw(ArgumentError("max_buffer_size must be positive"))
        max_fill < 1 && throw(ArgumentError("max_fill must be positive"))
        return new(CursorReader(data), Memory{UInt8}(), max_buffer_size, max_fill, false)
    end
end

function BufferIO.get_buffer(x::BoundedReader)::ImmutableMemoryView{UInt8}
    return ImmutableMemoryView(x.buffer)
end

function BufferIO.fill_buffer(x::BoundedReader)::Union{Int, Nothing}
    x.closed && throw(IOError(IOErrorKinds.ClosedIO))
    was_full = length(x.buffer) == x.max_buffer_size
    n_fill = min(length(get_buffer(x.inner)), x.max_buffer_size - length(x.buffer), x.max_fill)
    # Relocate even if nothing is filled, since views are invalidated regardless
    relocate!(x, 0, n_fill)
    return was_full ? nothing : n_fill
end

# Since this type is for testing, we always check bounds, even in an `@inbounds` context.
function BufferIO.consume(x::BoundedReader, n::Int)
    in(n, 0:length(x.buffer)) || throw(IOError(IOErrorKinds.ConsumeBufferError))
    relocate!(x, n, 0)
    return nothing
end

function Base.close(x::BoundedReader)
    x.closed = true
    relocate!(x, length(x.buffer), 0)
    return nothing
end

# Move the buffer to new memory, removing its first `n_consume` bytes, and moving
# `n_fill` bytes from `inner` to its end. Then flip all bits of the old memory, such that
# any byte seen through an invalidated view differs from the byte that was there.
function relocate!(x::BoundedReader, n_consume::Int, n_fill::Int)
    old = x.buffer
    n_kept = length(old) - n_consume
    new = Memory{UInt8}(undef, n_kept + n_fill)
    copyto!(new, 1, old, n_consume + 1, n_kept)
    copyto!(MemoryView(new)[(n_kept + 1):end], get_buffer(x.inner)[1:n_fill])
    consume(x.inner, n_fill)
    map!(~, old, old)
    x.buffer = new
    return nothing
end

"""
    BoundedWriter(sink::Vector{UInt8}, max_buffer_size::Int) <: AbstractBufWriter

Writer with a fixed-size buffer of `max_buffer_size` bytes, which is never expanded.
When flushed, or when `grow_buffer` is called, all buffered bytes are appended to `sink`.

This makes `BoundedWriter` useful to test that generic code correctly handles writers
with a limited buffer size.

`BoundedWriter` only implements the methods required of an `AbstractBufWriter`, so
optional methods such as `seek` and `position` are unsupported or use the generic
fallback definitions.

# Examples
```jldoctest
julia> using BufferIO.Testing: BoundedWriter

julia> sink = UInt8[]; writer = BoundedWriter(sink, 4);

julia> length(get_buffer(writer))
4

julia> write(writer, "Hello, world!")
13

julia> String(copy(sink)) # 12 bytes flushed, 1 still buffered
"Hello, world"

julia> flush(writer); String(sink)
"Hello, world!"
```
"""
mutable struct BoundedWriter <: AbstractBufWriter
    const sink::Vector{UInt8}
    const buffer::Memory{UInt8}
    # The buffer is all bytes of `buffer` after the first `n_buffered`
    n_buffered::Int
    closed::Bool

    function BoundedWriter(sink::Vector{UInt8}, max_buffer_size::Int)
        max_buffer_size < 1 && throw(ArgumentError("max_buffer_size must be positive"))
        return new(sink, Memory{UInt8}(undef, max_buffer_size), 0, false)
    end
end

function BufferIO.get_buffer(x::BoundedWriter)::MutableMemoryView{UInt8}
    return MemoryView(x.buffer)[(x.n_buffered + 1):end]
end

function BufferIO.grow_buffer(x::BoundedWriter)::Int
    x.closed && throw(IOError(IOErrorKinds.ClosedIO))
    n = x.n_buffered
    append!(x.sink, ImmutableMemoryView(x.buffer)[1:n])
    x.n_buffered = 0
    return n
end

# Since this type is for testing, we always check bounds, even in an `@inbounds` context.
function BufferIO.consume(x::BoundedWriter, n::Int)
    in(n, 0:(length(x.buffer) - x.n_buffered)) || throw(IOError(IOErrorKinds.ConsumeBufferError))
    x.n_buffered += n
    return nothing
end

function Base.flush(x::BoundedWriter)
    BufferIO.grow_buffer(x)
    return nothing
end

function Base.close(x::BoundedWriter)
    x.closed && return nothing
    flush(x)
    x.closed = true
    # Make the buffer empty, so it can't be written to after closing
    x.n_buffered = length(x.buffer)
    return nothing
end

end # module Testing
