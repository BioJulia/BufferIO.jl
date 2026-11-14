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
BufferIO.remaining_bytes_hint(x::BlockReader) = length(x.data) - x.pos

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

# Reader wrapping another reader, whose `remaining_bytes_hint` is off by `error` bytes
# (but not negative), or `nothing` if `error` is `nothing`.
# When constructed from data, the inner reader fills its buffer in small increments.
struct HintedReader{T <: AbstractBufReader} <: AbstractBufReader
    x::T
    error::Union{Nothing, Int}
end

HintedReader(data, error::Union{Nothing, Int}) = HintedReader(BufReader(IOBuffer(data), 3), error)

BufferIO.get_buffer(x::HintedReader) = get_buffer(x.x)
BufferIO.consume(x::HintedReader, n::Int) = consume(x.x, n)
BufferIO.fill_buffer(x::HintedReader) = fill_buffer(x.x)

function BufferIO.remaining_bytes_hint(x::HintedReader)
    x.error === nothing && return nothing
    return max(0, BufferIO.remaining_bytes_hint(x.x) + x.error)
end

Base.close(x::HintedReader) = close(x.x)
Base.isopen(x::HintedReader) = isopen(x.x)

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

# Writer with a fixed-size buffer, which can never be expanded, like e.g. a block
# compressor. Buffered bytes are written to `data` at position `pos`, overwriting existing
# bytes. `data` can't grow beyond `max_size` bytes, after which the writer is full.
# Supports seeking.
mutable struct BlockWriter <: AbstractBufWriter
    const data::Vector{UInt8}
    const buffer::Memory{UInt8}
    const max_size::Int
    # Position in `data` of the first buffered byte
    pos::Int
    n_buffered::Int
    closed::Bool
end

function BlockWriter(blocksize::Int; max_size::Int = typemax(Int))
    blocksize < 1 && error("Bad parameterization")
    return BlockWriter(UInt8[], Memory{UInt8}(undef, blocksize), max_size, 0, 0, false)
end

function BufferIO.get_buffer(x::BlockWriter)
    stop = clamp(x.max_size - x.pos, x.n_buffered, length(x.buffer))
    return MemoryView(x.buffer)[(x.n_buffered + 1):stop]
end

function write_buffered!(x::BlockWriter)
    x.closed && throw(IOError(IOErrorKinds.ClosedIO))
    n = x.n_buffered
    length(x.data) < x.pos + n && resize!(x.data, x.pos + n)
    copyto!(x.data, x.pos + 1, x.buffer, 1, n)
    x.pos += n
    x.n_buffered = 0
    return nothing
end

function BufferIO.grow_buffer(x::BlockWriter)
    n_old = length(get_buffer(x))
    write_buffered!(x)
    return length(get_buffer(x)) - n_old
end

function BufferIO.consume(x::BlockWriter, n::Int)
    in(n, 0:length(get_buffer(x))) || throw(IOError(IOErrorKinds.ConsumeBufferError))
    x.n_buffered += n
    return nothing
end

Base.flush(x::BlockWriter) = write_buffered!(x)

function Base.close(x::BlockWriter)
    x.closed && return nothing
    write_buffered!(x)
    x.closed = true
    return nothing
end

Base.isopen(x::BlockWriter) = !x.closed
Base.position(x::BlockWriter) = x.pos + x.n_buffered
Base.filesize(x::BlockWriter) = max(length(x.data), position(x))

function Base.seek(x::BlockWriter, offset::Int)
    in(offset, 0:filesize(x)) || throw(IOError(IOErrorKinds.BadSeek))
    write_buffered!(x)
    x.pos = offset
    return x
end
