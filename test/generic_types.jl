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
Base.isopen(x::GenericBufWriter) = isopen(x.x)

struct GenericBufReader <: AbstractBufReader
    x::CursorReader

    GenericBufReader(x) = new(CursorReader(x))
end

BufferIO.get_buffer(x::GenericBufReader) = get_buffer(x.x)
BufferIO.consume(x::GenericBufReader, n::Int) = consume(x.x, n)
BufferIO.fill_buffer(x::GenericBufReader) = fill_buffer(x.x)

Base.close(x::GenericBufReader) = close(x.x)
Base.isopen(x::GenericBufReader) = isopen(x.x)

# Reader which serves data in fixed-size blocks, and can only fill its buffer when it is
# empty, like e.g. a block decompressor. Its buffer can never be expanded.
mutable struct BlockReader <: AbstractBufReader
    data::Vector{UInt8}
    blocksize::Int
    pos::Int
    stop::Int
    closed::Bool
end

function BlockReader(data, blocksize::Int)
    blocksize < 1 && error("Bad parameterization")
    return BlockReader(Vector{UInt8}(data), blocksize, 0, 0, false)
end

BufferIO.get_buffer(x::BlockReader) = ImmutableMemoryView(x.data)[(x.pos + 1):x.stop]

function BufferIO.fill_buffer(x::BlockReader)
    x.pos < x.stop && return nothing
    old = x.stop
    x.stop = min(length(x.data), x.stop + x.blocksize)
    return x.stop - old
end

function BufferIO.consume(x::BlockReader, n::Int)
    in(n, 0:(x.stop - x.pos)) || throw(IOError(IOErrorKinds.ConsumeBufferError))
    x.pos += n
    return nothing
end

# `closed` only records that `close` was called, for use in tests.
# Closing does not make the reader unusable, so it is always open.
Base.close(x::BlockReader) = (x.closed = true; nothing)
Base.isopen(::BlockReader) = true
Base.position(x::BlockReader) = x.pos
Base.filesize(x::BlockReader) = length(x.data)

function Base.seek(x::BlockReader, offset::Int)
    in(offset, 0:length(x.data)) || throw(IOError(IOErrorKinds.BadSeek))
    x.pos = x.stop = offset
    return x
end

BufferIO.relative_seek(x::BlockReader, delta::Int) = seek(x, x.pos + delta)

# Wraps a BlockReader, but `fill_buffer` returns the values in `script` without
# filling, until the script is exhausted. Used to test handling of invalid readers.
struct ScriptedReader <: AbstractBufReader
    x::BlockReader
    script::Vector{Union{Nothing, Int}}
end

ScriptedReader(data, blocksize::Int) = ScriptedReader(BlockReader(data, blocksize), [])

BufferIO.get_buffer(x::ScriptedReader) = get_buffer(x.x)
BufferIO.consume(x::ScriptedReader, n::Int) = consume(x.x, n)

function BufferIO.fill_buffer(x::ScriptedReader)
    return isempty(x.script) ? fill_buffer(x.x) : popfirst!(x.script)
end

Base.close(x::ScriptedReader) = close(x.x)
Base.isopen(x::ScriptedReader) = isopen(x.x)

# Writer with a fixed capacity, which can never make room for more data.
mutable struct FixedWriter <: AbstractBufWriter
    const mem::Memory{UInt8}
    n_written::Int
end

FixedWriter(capacity::Int) = FixedWriter(Memory{UInt8}(undef, capacity), 0)

BufferIO.get_buffer(x::FixedWriter) = MemoryView(x.mem)[(x.n_written + 1):end]
BufferIO.grow_buffer(::FixedWriter) = 0

function BufferIO.consume(x::FixedWriter, n::Int)
    in(n, 0:(length(x.mem) - x.n_written)) || throw(IOError(IOErrorKinds.ConsumeBufferError))
    x.n_written += n
    return nothing
end

Base.flush(::FixedWriter) = nothing
Base.close(::FixedWriter) = nothing
Base.isopen(::FixedWriter) = true
