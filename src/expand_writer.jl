"""
    ExpandWriter{T <: AbstractBufWriter} <: AbstractBufWriter

Writer which wraps another writer and provides an infinitely expandable buffer.
`ExpandWriter` forwards its inner writer's buffer where possible, but if `grow_buffer`
is called and the inner writer can't expand its buffer, `ExpandWriter` will serve
its own growable buffer.
This implies that `grow_buffer(::ExpandWriter)` never returns zero, and
`get_nonempty_buffer(::ExpandWriter, ::Int)` never returns `nothing`.
If the inner writer is full, i.e. its buffer is empty and it can't make room for more data,
which may happen if e.g. the underlying device cannot store more data,
these functions instead throw an `IOError` of kind `WriterFull`.

`ExpandWriter` is useful when users need a minimum amount of contiguous buffer space
(e.g. to encode a value of `N` bytes directly into the buffer), but want to write to a
generic `AbstractBufWriter`.
Generic code may use the [`expandable`](@ref) function to opt-into `ExpandWriter` only
when necessary.

Data written to the own buffer of `ExpandWriter` is written to the inner writer when
`ExpandWriter` is flushed, seeked or closed, or when it needs to make room in its buffer.
If the inner writer becomes full before all this data could be written to it, these
operations throw an `IOError` of kind `WriterFull`.

`ExpandWriter` takes control of the inner writer, and mutating the inner writer may
invalidate the `ExpandWriter`.

See also: [`expandable`](@ref), [`BufferIO.is_expandable`](@ref), [`ExpandReader`](@ref)

# Examples
```jldoctest
julia> using BufferIO.Testing: BoundedWriter

julia> sink = UInt8[]; inner = BoundedWriter(sink, 4);

julia> get_nonempty_buffer(inner, 8) === nothing # inner can't hold 8 bytes
true

julia> writer = ExpandWriter(inner); # In generic code, prefer `expandable(inner)`

julia> buffer = get_nonempty_buffer(writer, 8); length(buffer) ≥ 8
true

julia> buffer[1:8] .= codeunits("Hello, w"); consume(writer, 8)

julia> write(writer, "orld!")
5

julia> flush(writer); String(sink)
"Hello, world!"

julia> BufferIO.is_expandable(typeof(writer))
true
```
"""
mutable struct ExpandWriter{T <: AbstractBufWriter} <: AbstractBufWriter
    # In the common case, the inner's buffer is forwarded
    const inner::T
    # Memory owned by this ExpandWriter. When `serving_own` is set, the first `n_pending`
    # bytes of the memory are data written by the user which have not yet been written
    # to inner, and the remaining bytes are the buffer served to the user.
    # The memory is kept when switching back to inner, so it can be reused.
    mem::Memory{UInt8}
    n_pending::Int
    # Whether we serve from own buffer.
    serving_own::Bool
    # When closed, we also set `serving_own`, and keep the own memory empty with no
    # pending bytes. That way, `get_buffer` and `consume` behave correctly without
    # checking this field, and only the slow paths, which handle the own buffer,
    # need to check it.
    closed::Bool

    function ExpandWriter{T}(inner::T) where {T <: AbstractBufWriter}
        return new{T}(inner, Memory{UInt8}(), 0, false, false)
    end
end

ExpandWriter(inner::AbstractBufWriter) = ExpandWriter{typeof(inner)}(inner)

function get_buffer(io::ExpandWriter)::MutableMemoryView{UInt8}
    io.serving_own || return get_buffer(io.inner)::MutableMemoryView{UInt8}
    return @inbounds truncate_start(MemoryView(io.mem), io.n_pending + 1)
end

Base.@propagate_inbounds function consume(io::ExpandWriter, n::Int)
    if io.serving_own
        @boundscheck if (n % UInt) > ((length(io.mem) - io.n_pending) % UInt)
            throw(IOError(IOErrorKinds.ConsumeBufferError))
        end
        io.n_pending += n
    else
        consume(io.inner, n)
    end
    return nothing
end

function grow_buffer(io::ExpandWriter)::Int
    io.serving_own && return grow_buffer_own(io)
    n = grow_buffer(io.inner)::Int
    # Inner's buffer couldn't be grown, so we must use our own buffer.
    return iszero(n) ? start_serving_own(io) : n
end

@noinline function throw_invalid_inner_writer()
    error("ExpandWriter's inner writer was mutated, or does not implement grow_buffer / get_buffer correctly")
end

# Called when inner's buffer can't be grown. Switch to serving the own buffer, which is
# larger than inner's buffer, and return the number of bytes the buffer grew.
@noinline function start_serving_own(io::ExpandWriter)::Int
    n_inner = length(get_buffer(io.inner)::MutableMemoryView{UInt8})
    # If inner's buffer is empty and can't grow, inner is full, so we can't make room.
    # Using the own buffer would only accept data which could never be written.
    # Returning zero would violate `is_expandable`, so we throw.
    iszero(n_inner) && throw(IOError(IOErrorKinds.WriterFull))
    ensure_own_size!(io, n_inner + 1)
    io.n_pending = 0
    io.serving_own = true
    return length(io.mem) - n_inner
end

# Make sure the own memory has at least `min_size` bytes. Must only be called when
# the own memory contains no pending bytes, since these are not kept.
function ensure_own_size!(io::ExpandWriter, min_size::Int)
    if length(io.mem) < min_size
        io.mem = Memory{UInt8}(undef, overallocation_size(min_size % UInt))
    end
    return nothing
end

@noinline function grow_buffer_own(io::ExpandWriter)::Int
    io.closed && throw_closed()
    n_old = length(io.mem) - io.n_pending
    drain_own!(io)
    # Switch back to inner if it can provide a larger buffer than the current one.
    # Else, the user would write to the own buffer, and the data would need to be copied
    # to inner, even though inner could hold it.
    n_inner = length(get_buffer(io.inner)::MutableMemoryView{UInt8})
    while n_inner ≤ n_old
        n = grow_buffer(io.inner)::Int
        iszero(n) && break
        n_new = length(get_buffer(io.inner)::MutableMemoryView{UInt8})
        n_new == n_inner + n || throw_invalid_inner_writer()
        n_inner = n_new
    end
    if n_inner > n_old
        io.serving_own = false
        return n_inner - n_old
    end
    # Else, keep serving the own buffer, which is now empty.
    # If no bytes were pending, emptying it did not grow it, so allocate a larger one.
    ensure_own_size!(io, n_old + 1)
    return length(io.mem) - n_old
end

# Write the pending bytes of the own buffer to inner. If inner becomes full before all
# bytes are written, keep the remaining bytes pending and throw `WriterFull`.
function drain_own!(io::ExpandWriter)
    n_pending = io.n_pending
    iszero(n_pending) && return nothing
    pending = MemoryViews.truncate(ImmutableMemoryView(io.mem), n_pending)
    n_written = write_to_inner(io.inner, pending)
    if n_written < n_pending
        # Keep the remaining pending bytes at the start of the memory
        copyto!(io.mem, 1, io.mem, n_written + 1, n_pending - n_written)
        io.n_pending = n_pending - n_written
        throw(IOError(IOErrorKinds.WriterFull))
    end
    io.n_pending = 0
    return nothing
end

# Copy `src` to `inner`, and return the number of bytes copied, which is less than
# `length(src)` only if inner is full.
# We don't use `unsafe_write`, since it does not report how many bytes it wrote if
# inner becomes full.
function write_to_inner(inner::AbstractBufWriter, src::ImmutableMemoryView{UInt8})::Int
    n_written = 0
    while n_written < length(src)
        buffer = get_nonempty_buffer(inner)::Union{Nothing, MutableMemoryView{UInt8}}
        isnothing(buffer) && break
        n = copyto_start!(buffer, @inbounds truncate_start(src, n_written + 1))
        consume(inner, n)
        n_written += n
    end
    return n_written
end

# Called by the generic `get_nonempty_buffer(::AbstractBufWriter, ::Int)`
@noinline function get_nonempty_buffer_slowpath(
        io::ExpandWriter,
        min_size::Int,
        ::Int,
    )::MutableMemoryView{UInt8}
    io.closed && throw_closed()
    # When not serving own buffer, an expandable inner can provide the buffer directly,
    # possibly more efficiently.
    if is_expandable(typeof(io.inner)) && !io.serving_own
        return get_nonempty_buffer(io.inner, min_size)::MutableMemoryView{UInt8}
    end
    # Writing the pending bytes empties the own buffer, and inner may then be able to
    # provide the buffer.
    io.serving_own && drain_own!(io)
    buffer = get_buffer(io.inner)::MutableMemoryView{UInt8}
    while length(buffer) < min_size
        n = grow_buffer(io.inner)::Int
        iszero(n) && break
        buffer = get_buffer(io.inner)::MutableMemoryView{UInt8}
    end
    if length(buffer) ≥ min_size || isempty(buffer)
        io.serving_own = false
        # If inner's buffer is empty and can't grow, inner is full
        isempty(buffer) && throw(IOError(IOErrorKinds.WriterFull))
        return buffer
    end
    ensure_own_size!(io, min_size)
    io.n_pending = 0
    io.serving_own = true
    return MemoryView(io.mem)
end

function Base.unsafe_write(io::ExpandWriter, ptr::Ptr{UInt8}, n_bytes::UInt)::Int
    # Forward to inner, which may have a more efficient implementation, e.g. `BufWriter`
    # writes large data directly to its wrapped IO.
    io.serving_own || return unsafe_write(io.inner, ptr, n_bytes)
    return @invoke unsafe_write(io::AbstractBufWriter, ptr::Ptr{UInt8}, n_bytes::UInt)
end

function Base.flush(io::ExpandWriter)
    io.closed && throw_closed()
    io.serving_own && drain_own!(io)
    flush(io.inner)
    return nothing
end

function Base.close(io::ExpandWriter)
    io.closed && return nothing
    # Mark closed first, so `io` is closed even if writing to or closing inner throws.
    pending = if io.serving_own
        MemoryViews.truncate(ImmutableMemoryView(io.mem), io.n_pending)
    else
        ImmutableMemoryView(Memory{UInt8}())
    end
    mark_closed!(io)
    try
        if write_to_inner(io.inner, pending) < length(pending)
            throw(IOError(IOErrorKinds.WriterFull))
        end
    finally
        # Close inner even if writing failed, since `io` can't be closed again.
        close(io.inner)
    end
    return nothing
end

"""
    take_inner(io::ExpandWriter{T})::T

Write the data buffered in the own buffer of `io` to its inner writer, then close `io`
and return the inner writer. The inner writer is neither closed nor flushed.

After this, all operations on `io` which would access the inner writer throw an `IOError`
of kind `ClosedIO`, and `close(io)` does nothing.

Throw an `IOError` of kind `ClosedIO` if `io` is already closed, or of kind `WriterFull`
if the inner writer can't hold the data buffered in `io`. In the latter case, `io` is
not closed.

# Examples
```jldoctest
julia> using BufferIO.Testing: BoundedWriter

julia> sink = UInt8[]; inner = BoundedWriter(sink, 4);

julia> writer = ExpandWriter(inner);

julia> write_repeated(writer, UInt8('a'), 3); fill!(get_nonempty_buffer(writer, 6), UInt8('b'));

julia> consume(writer, 6);

julia> take_inner(writer) === inner
true

julia> flush(inner); String(sink)
"aaabbbbbb"

julia> write(writer, 0x01)
ERROR: Unsupported operation on closed IO
[...]
```
"""
function take_inner(io::ExpandWriter)
    io.closed && throw_closed()
    io.serving_own && drain_own!(io)
    mark_closed!(io)
    return io.inner
end

function mark_closed!(io::ExpandWriter)
    # Release the memory, and serve an empty own buffer. See comment on the `closed` field.
    io.mem = Memory{UInt8}()
    io.n_pending = 0
    io.serving_own = true
    io.closed = true
    return nothing
end

Base.isopen(io::ExpandWriter) = !io.closed

# Number of bytes written by the user, but not yet written to inner.
n_unwritten(io::ExpandWriter) = io.serving_own ? io.n_pending : 0

function Base.position(io::ExpandWriter)
    io.closed && throw_closed()
    return Int(position(io.inner))::Int + n_unwritten(io)
end

function Base.filesize(io::ExpandWriter)
    io.closed && throw_closed()
    # The pending bytes will be written at inner's position, overwriting existing data,
    # so the data ends at the end of inner, or at the end of the pending data,
    # whichever is later.
    return max(Int(filesize(io.inner))::Int, position(io))
end

function Base.seek(io::ExpandWriter, offset::Int)
    io.closed && throw_closed()
    if io.serving_own
        # Check before writing the pending bytes, so an invalid seek leaves `io` unchanged.
        in(offset, 0:filesize(io)) || throw(IOError(IOErrorKinds.BadSeek))
        drain_own!(io)
        io.serving_own = false
    end
    seek(io.inner, offset)
    return io
end

function drop_own(io::ExpandWriter)
    io.serving_own && return nothing
    old_mem = io.mem
    io.mem = Memory{UInt8}()
    return old_mem
end

is_expandable(::Type{<:ExpandWriter}) = true
