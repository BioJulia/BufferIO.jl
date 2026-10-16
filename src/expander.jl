"""
    ExpandReader{T <: AbstractBufReader} <: AbstractBufReader

Reader which wraps another reader and provides an infinitely expandable buffer.
`ExpandReader` forwards its inner reader's buffer where possible, but if `fill_buffer`
is called and the inner reader can't expand its buffer, `ExpandReader` will serve the data
from its own growable buffer.
This implies that `fill_buffer(::ExpandReader)` always returns an `Int`, never `nothing`.

`ExpandReader` is useful when users need to buffer a minimum amount (e.g. an entire line, or N bytes),
but want to read from a generic `AbstractBufReader`.
Generic code may use the [`expandable`](@ref) function to opt-into `ExpandReader` only
when necessary.

`ExpandReader` takes control of the inner reader, and mutating the inner reader may
invalidate the `ExpandReader`.

See also: [`expandable`](@ref), [`BufferIO.is_expandable`](@ref)

# Examples
```jldoctest
julia> using BufferIO.Testing: BoundedReader

julia> inner = BoundedReader("Hello, world!", 4; max_fill = 4);

julia> fill_buffer(inner); fill_buffer(inner) === nothing # inner can't grow its buffer
true

julia> reader = ExpandReader(inner); # In generic code, prefer `expandable(inner)`

julia> String(get_buffer(reader)) # inner's buffer is forwarded
"Hell"

julia> while !iszero(fill_buffer(reader)) end

julia> String(get_buffer(reader)) # served from the own buffer of `reader`
"Hello, world!"

julia> BufferIO.is_expandable(typeof(reader))
true
```
"""
mutable struct ExpandReader{T <: AbstractBufReader} <: AbstractBufReader
    # In the common case, the inner's buffer is forwarded
    const inner::T
    # View into a memory owned by this ExpandReader. When `serving_own` is set, it contains
    # the bytes served to the user, including data inner's buffer cannot hold.
    # The backing memory is kept when switching back to inner, so it can be reused.
    buffer::MutableMemoryView{UInt8}
    # Where possible, we defer consuming bytes moved by `buffer` from the underlying IO.
    # Else, after having consumed most of `buffer`'s content, if the user demands more bytes,
    # we would have to copy bytes from `inner`, which means all bytes would eventually be
    # copied in, and the fast path of forwarding inner's buffer would be lost.
    # This field tracks how many bytes we have deferred consuming from inner.
    # Invariant: When serving from own buffer, the last `debt` bytes in the backing memory
    # up to and including the last byte of `buffer` are identical to the first `debt` bytes
    # of inner's buffer. Some of these bytes may have been consumed from `buffer` already.
    debt::Int
    # Whether we serve from own buffer. The own buffer may be empty, yet still be served
    # from, if all its bytes have been consumed, but the debt has not been paid.
    serving_own::Bool
    # When closed, we also set `serving_own`, and keep the own buffer empty with zero debt.
    # That way, `get_buffer` and `consume` behave correctly without checking this field,
    # and only the slow paths, which handle the own buffer, need to check it.
    closed::Bool

    function ExpandReader{T}(inner::T) where {T <: AbstractBufReader}
        return new{T}(inner, MemoryView(Memory{UInt8}()), 0, false, false)
    end
end

ExpandReader(inner::AbstractBufReader) = ExpandReader{typeof(inner)}(inner)

function get_buffer(io::ExpandReader)::ImmutableMemoryView{UInt8}
    return io.serving_own ? ImmutableMemoryView(io.buffer) : get_buffer(io.inner)::ImmutableMemoryView{UInt8}
end

Base.@propagate_inbounds function consume(io::ExpandReader, n::Int)
    if io.serving_own
        @boundscheck if (n % UInt) > (length(io.buffer) % UInt)
            throw(IOError(IOErrorKinds.ConsumeBufferError))
        end
        # Even if this empties the own buffer, we do not switch back to inner's buffer here,
        # since inner's buffer may contain more bytes, and the buffer must only grow
        # when `fill_buffer` is called.
        # Note: truncate_start keeps the backing memory, even when the result is empty.
        io.buffer = @inbounds MemoryViews.truncate_start(io.buffer, n + 1)
    else
        consume(io.inner, n)
    end
    return nothing
end

function fill_buffer(io::ExpandReader)::Int
    io.serving_own && return fill_buffer_own(io)
    n = fill_buffer(io.inner)::Union{Int, Nothing}
    # Inner's buffer couldn't be grown, so we must use our own buffer.
    return n === nothing ? start_serving_own(io) : n
end

@noinline throw_closed() = throw(IOError(IOErrorKinds.ClosedIO))

@noinline function throw_invalid_inner()
    error("ExpandReader's inner reader was mutated, or does not implement fill_buffer / get_buffer correctly")
end

# Move the content of inner's buffer, which is nonempty and can't be grown, into the
# own buffer, then add new bytes to the own buffer.
@noinline function start_serving_own(io::ExpandReader)::Int
    inner_buffer = get_buffer(io.inner)::ImmutableMemoryView{UInt8}
    # Per fill_buffer's documentation, fill_buffer never returns nothing on an empty buffer
    isempty(inner_buffer) && throw_invalid_inner()
    n = length(inner_buffer)
    mem = MemoryViews.memory(io.buffer)
    if length(mem) < n
        mem = Memory{UInt8}(undef, overallocation_size(n % UInt))
    end
    buffer = MemoryView(mem)[1:n]
    copyto!(buffer, inner_buffer)
    consume(io.inner, n)
    io.buffer = buffer
    io.debt = 0
    io.serving_own = true
    # Get more bytes - that was the whole point of the user calling `fill_buffer`
    return add_bytes_to_own(io)
end

@noinline function fill_buffer_own(io::ExpandReader)::Int
    io.closed && throw_closed()
    n_own = length(io.buffer)
    # If the own buffer contains bytes inner's buffer does not, we must keep using it
    n_own > io.debt && return add_bytes_to_own(io)

    # Else, all remaining bytes of own buffer are at the start of inner's buffer,
    # after paying the part of the debt the user has consumed from own buffer.
    # So we can switch back to serving inner's buffer.
    consume(io.inner, io.debt - n_own)
    io.debt = 0
    io.serving_own = false
    n_inner = length(get_buffer(io.inner)::ImmutableMemoryView{UInt8})
    n_inner < n_own && throw_invalid_inner()
    # If inner's buffer contains bytes beyond what the own buffer did, these bytes are
    # the newly filled bytes, and we don't need to fill inner.
    n_inner > n_own && return n_inner - n_own
    n = fill_buffer(io.inner)::Union{Int, Nothing}
    return n === nothing ? start_serving_own(io) : n
end

# Append bytes from inner to the own buffer, without consuming them from inner.
# Must only be called when serving from own buffer, and when own buffer contains
# bytes that inner's buffer does not. In particular, the own buffer is not empty.
function add_bytes_to_own(io::ExpandReader)::Int
    inner_buffer = get_buffer(io.inner)::ImmutableMemoryView{UInt8}
    length(inner_buffer) < io.debt && throw_invalid_inner()
    # If every byte of inner's buffer is already copied to own, we need inner to get more.
    if length(inner_buffer) == io.debt
        n = fill_buffer(io.inner)::Union{Int, Nothing}
        if n === nothing
            # Inner's buffer can't grow. Pay off the debt, such that the copied bytes
            # are only in the own buffer, and get new bytes into the now-empty inner buffer.
            consume(io.inner, io.debt)
            io.debt = 0
            n = fill_buffer(io.inner)::Union{Int, Nothing}
            n === nothing && throw_invalid_inner()
        end
        iszero(n) && return 0
        inner_buffer = get_buffer(io.inner)::ImmutableMemoryView{UInt8}
    end
    n_available = length(inner_buffer) - io.debt
    n_available < 1 && throw_invalid_inner()
    # We don't copy all available bytes, only an amount proportional to the own buffer.
    # This makes sure that the number of copied bytes before we can switch back to inner's
    # buffer scales with the amount of bytes the user needs buffered, and not with the
    # size of inner's buffer.
    n_own = length(io.buffer)
    n_copy = min(n_available, max(1, overallocation_size(n_own % UInt) - n_own))
    start = reserve_own!(io, n_copy)
    stop = start + n_own - 1
    mem = MemoryView(MemoryViews.memory(io.buffer))
    copyto!(mem[(stop + 1):(stop + n_copy)], inner_buffer[(io.debt + 1):(io.debt + n_copy)])
    io.buffer = mem[start:(stop + n_copy)]
    io.debt += n_copy
    return n_copy
end

# Index in the backing memory of the first byte of the own buffer.
# The own buffer must not be empty, since an empty view's position in its memory
# is not well defined.
function own_start(io::ExpandReader)::Int
    mem = MemoryViews.memory(io.buffer)
    return GC.@preserve mem Int(pointer(io.buffer) - pointer(mem)) + 1
end

# Make sure there is room for `n` more bytes after the own buffer in its backing memory,
# and return the index in the backing memory of the first byte of the own buffer.
# The own buffer must not be empty.
function reserve_own!(io::ExpandReader, n::Int)::Int
    mem = MemoryViews.memory(io.buffer)
    n_own = length(io.buffer)
    start = own_start(io)
    start + n_own - 1 + n ≤ length(mem) && return start
    if n_own + n ≤ length(mem)
        # Moving the own bytes to the start of mem is enough.
        # This overwrites the consumed bytes before the own buffer, which therefore can no
        # longer be reached by seeking backwards in memory in `relative_seek`.
        copyto!(mem, 1, mem, start, n_own)
    else
        new_mem = Memory{UInt8}(undef, overallocation_size((n_own + n) % UInt))
        copyto!(new_mem, 1, mem, start, n_own)
        mem = new_mem
    end
    io.buffer = MemoryView(mem)[1:n_own]
    return 1
end

# Number of bytes consumed from inner, but not yet by the user.
# This is negative if the user has consumed into the debt.
n_unpaid(io::ExpandReader) = io.serving_own ? length(io.buffer) - io.debt : 0

# Switch to serving from inner, assuming inner's position is already where the user's
# position should be. Keeps the backing memory for reuse.
function stop_serving_own!(io::ExpandReader)
    io.serving_own = false
    io.debt = 0
    return nothing
end

function Base.close(io::ExpandReader)
    io.closed && return nothing
    mark_closed!(io)
    close(io.inner)
    return nothing
end

"""
    take_inner(io::ExpandReader{T})::T

Close `io` and return its inner reader, without closing the inner reader.

Any data buffered in `io` and not yet consumed is discarded, and the returned inner
reader is positioned immediately after the consumed data.
To keep the discarded data, copy it from `get_buffer(io)` before calling `take_inner`.

After this, all operations on `io` which would access the inner reader throw an `IOError`
of kind `ClosedIO`, and `close(io)` does nothing.

Throw an `IOError` of kind `ClosedIO` if `io` is already closed.

# Examples
```jldoctest
julia> reader = ExpandReader(BufReader(IOBuffer("abcdef"), 4));

julia> String(read(reader, 2))
"ab"

julia> kept = String(get_buffer(reader))
"cd"

julia> inner = take_inner(reader); # "cd" is discarded

julia> String(read(inner)) # inner continues right after `kept`
"ef"

julia> read(reader, UInt8)
ERROR: Unsupported operation on closed IO
[...]
```
"""
function take_inner(io::ExpandReader)
    io.closed && throw_closed()
    # When serving own buffer, its last `debt` bytes are the first bytes of inner's
    # buffer. Else, the buffer of `io` is inner's buffer.
    n = io.serving_own ? io.debt : length(get_buffer(io.inner)::ImmutableMemoryView{UInt8})
    consume(io.inner, n)
    mark_closed!(io)
    return io.inner
end

function mark_closed!(io::ExpandReader)
    # Release the memory, and serve an empty own buffer. See comment on the `closed` field.
    io.buffer = MemoryView(Memory{UInt8}())
    io.debt = 0
    io.serving_own = true
    io.closed = true
    return nothing
end

Base.isopen(io::ExpandReader) = !io.closed

function Base.filesize(io::ExpandReader)
    io.closed && throw_closed()
    return filesize(io.inner)
end

function Base.position(io::ExpandReader)
    io.closed && throw_closed()
    return Int(position(io.inner))::Int - n_unpaid(io)
end

function Base.seek(io::ExpandReader, offset::Int)
    io.closed && throw_closed()
    # Inner validates the offset. If it throws, we have not mutated `io`.
    seek(io.inner, offset)
    stop_serving_own!(io)
    return io
end

function relative_seek(io::ExpandReader, delta::Int)
    io.serving_own || return (relative_seek(io.inner, delta); io)
    io.closed && throw_closed()
    n_own = length(io.buffer)
    if delta >= 0
        if delta <= n_own
            io.buffer = @inbounds MemoryViews.truncate_start(io.buffer, delta + 1)
            return io
        end
    elseif !iszero(n_own)
        # Seeking backwards within the backing memory is possible, because the bytes in the
        # memory before the own buffer are always the bytes most recently consumed from it.
        # This is because consume only moves the start of the own buffer forward, and every
        # operation that moves bytes in the memory places the own buffer at index 1.
        # We can't get the start of an empty own buffer, so we don't seek in memory then.
        start = own_start(io)
        new_start = start + delta
        if new_start >= 1
            mem = MemoryView(MemoryViews.memory(io.buffer))
            io.buffer = @inbounds mem[new_start:(start + n_own - 1)]
            return io
        end
    end
    # Inner validates the offset. If it throws, we have not mutated `io`.
    relative_seek(io.inner, delta - n_unpaid(io))
    stop_serving_own!(io)
    return io
end

"""
    drop_own(io::ExpandReader)::Union{Nothing, Memory}

If the own buffer of `io` is in use or `io` is closed, return `nothing`.
Else, drop the buffer from `io`, and return it.
The returned memory may be empty, and is owned by the caller, i.e. `io` is
guaranteed to not keep a reference to it.

Since `ExpandReader`s allocates new buffers as needed, this function does not
change the semantic behaviour of `io`, only its allocation patterns, and never
puts `io` in an invalid state.
It is intended to free memory if extra buffering is only transiently needed.

When this function returns `nothing` or the buffer depends on which buffer
is used by `io`, which is an implementation detail.

# Examples
```jldoctest
julia> io = ExpandReader(CursorReader("Hello, world!"));

julia> String(read(io, 5))
"Hello"

julia> mem = drop_own(io);

julia> mem isa Union{Nothing, Memory{UInt8}}
true

julia> String(read(io)) # dropping does not change the content of io
", world!"
```
"""
function drop_own(io::ExpandReader)
    io.serving_own && return nothing
    old_buffer = MemoryViews.memory(io.buffer)
    # Constructing empty Memory do not allocate in Julia, so this is very fast
    io.buffer = MemoryView(Memory{UInt8}())
    return old_buffer
end

is_expandable(::Type{<:ExpandReader}) = true

"""
    expandable(io::T)::Union{T, ExpandReader{T}} where {T <: AbstractBufReader}

Return `io` unchanged if `BufferIO.is_expandable(typeof(io))`, else wrap `io` in an
`ExpandReader` and return it.
The type of the result is guaranteed to have `is_expandable` return `true`, which
means its buffer size is able to grow until EOF. Equivalently, calling `fill_buffer`
on the result will not return `nothing`.

This function is useful when working with non-expandable readers, or generic readers,
where the maximum buffer size is unknown, and where some minimum buffering is required.
An example could be a reader that wraps a generic `AbstractBufReader`, and must be
able to buffer a full line of input.

The concrete return type of `expandable(io)` is resolved at compile time.

See also: [`BufferIO.is_expandable`](@ref)

# Examples
```jldoctest
julia> io = BufReader(IOBuffer("abc"));

julia> expandable(io) === io # BufReader is already expandable
true

julia> io = BufferIO.Testing.BoundedReader("abc", 2);

julia> expandable(io) isa ExpandReader
true
```
"""
expandable(io::AbstractBufReader) = is_expandable(typeof(io)) ? io : ExpandReader(io)
