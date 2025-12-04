struct GenericBufWriter <: AbstractBufWriter
    x::VecWriter
end

GenericBufWriter() = GenericBufWriter(VecWriter())
GenericBufWriter(v::Vector{UInt8}) = GenericBufWriter(VecWriter(v))

BufferIO.get_buffer(x::GenericBufWriter) = get_buffer(x.x)
BufferIO.consume(x::GenericBufWriter, n::Int) = consume(x.x, n)
BufferIO.grow_buffer(x::GenericBufWriter) = grow_buffer(x.x)

Base.flush(x::GenericBufWriter) = flush(x.x)
Base.close(x::GenericBufWriter) = close(x.x)

struct GenericBufReader <: AbstractBufReader
    x::CursorReader

    GenericBufReader(x) = new(CursorReader(x))
end

BufferIO.get_buffer(x::GenericBufReader) = get_buffer(x.x)
BufferIO.consume(x::GenericBufReader, n::Int) = consume(x.x, n)
BufferIO.fill_buffer(x::GenericBufReader) = fill_buffer(x.x)

# This type has a max buffer size so we can check the code paths
# where the buffer size is restricted.
mutable struct BoundedReader <: AbstractBufReader
    x::CursorReader
    buffer_size::Int
    max_size::Int
end

function BoundedReader(mem, max_size::Int)
    max_size < 1 && error("Bad parameterization")
    return BoundedReader(CursorReader(mem), 0, max_size)
end

function BufferIO.fill_buffer(x::BoundedReader)
    x.buffer_size == x.max_size && return nothing
    buffer = get_buffer(x.x)
    old = x.buffer_size
    x.buffer_size = min(length(buffer), x.max_size)
    return x.buffer_size - old
end

function BufferIO.get_buffer(x::BoundedReader)
    buffer = get_buffer(x.x)
    return buffer[1:min(length(buffer), x.buffer_size)]
end

function BufferIO.consume(x::BoundedReader, n::Int)
    in(n, 0:x.buffer_size) || throw(IOError(IOErrors.ConsumeBufferError))
    consume(x.x, n)
    x.buffer_size -= n
    return nothing
end

mutable struct BoundedWriter <: AbstractBufWriter
    x::VecWriter
    mem::Memory{UInt8}
    written::Int
end

function BoundedWriter(size::Int)
    size < 1 && error("Bad parameterization")
    return BoundedWriter(VecWriter(), Memory{UInt8}(undef, size), 0)
end

function BufferIO.get_buffer(x::BoundedWriter)
    return MemoryView(x.mem)[(x.written + 1):end]
end

function BufferIO.grow_buffer(x::BoundedWriter)
    write(x.x, x.mem[1:x.written])
    old = x.written
    x.written = 0
    return old
end

function BufferIO.consume(x::BoundedWriter, n::Int)
    remaining = length(x.mem) - x.written
    in(n, 0:remaining) || throw(IOError(IOErrors.ConsumeBufferError))
    x.written += n
    return nothing
end

function Base.close(x::BoundedWriter)
    flush(x)
    return nothing
end

function Base.flush(x::BoundedWriter)
    grow_buffer(x)
    return nothing
end
