Base.bytesavailable(x::AbstractBufReader) = length(get_buffer(x))

Base.eof(x::AbstractBufReader) = isnothing(get_nonempty_buffer(x))

Base.read(x::AbstractBufReader, ::Type{String}) = String(read(x))

function Base.read(x::AbstractBufReader)
    v = UInt8[]
    while true
        buf = get_nonempty_buffer(x)::Union{Nothing, ImmutableMemoryView{UInt8}}
        isnothing(buf) && return v
        append!(v, buf)
        @inbounds consume(x, length(buf))
    end
    return v # unreachable
end

"""
    read(io::AbstractBufReader, nb::Integer)

Read at exactly `nb` bytes from `io`, or until end of file, and return the
bytes read as a `Vector{UInt8}`.

Throw an `ArgumentError` if `nb` is negative.
"""
function Base.read(x::AbstractBufReader, nb::Integer)
    nb = Int(nb)::Int
    nb < 0 && throw(ArgumentError("nb cannot be negative"))
    v = UInt8[]
    remaining = nb
    while !iszero(remaining)
        buf = get_nonempty_buffer(x)::Union{Nothing, ImmutableMemoryView{UInt8}}
        isnothing(buf) && return v
        mn = min(length(buf), remaining)
        buf = @inbounds buf[1:mn]
        append!(v, buf)
        @inbounds consume(x, mn)
        remaining -= mn
    end
    return v
end

"""
    unsafe_read(io::AbstractBufReader, ref, nbytes::UInt)::Int
    unsafe_read(io::AbstractBufReader, p::Ptr{UInt8}, nbytes::UInt)::Int

Copy `nbytes` from `io` into `ref`, returning the number of bytes copied.
If `io` reached end of file, stop at EOF.
`ref` is converted to a pointer using `cref = Base.cconvert(Ptr, ref)`, then
`Base.unsafe_convert(Ptr{UInt8}, cref)`.

Safety: The user must ensure that
* The resulting pointer is valid, and points to at least `nbytes` of writeable memory.
* `GC.@preserve`ing `cref` pins `ref` in memory, i.e. the pointer will not become
  invalid during the `GC.@preserve` block.
"""
function Base.unsafe_read(x::AbstractBufReader, ref, n::UInt)::Int
    cref = Base.cconvert(Ptr, ref)
    GC.@preserve cref begin
        ptr = Base.unsafe_convert(Ptr{UInt8}, cref)::Ptr{UInt8}
        result = unsafe_read(x, ptr, n)
    end
    return result
end

function Base.unsafe_read(x::AbstractBufReader, p::Ptr{UInt8}, n::UInt)::Int
    buffer = get_buffer(x)
    (length(buffer) % UInt) < n && return _unsafe_read(x, p, n)
    GC.@preserve buffer unsafe_copyto!(p, pointer(buffer), n)
    @inbounds consume(x, n % Int)
    return n % Int
end

@noinline function _unsafe_read(x::AbstractBufReader, p::Ptr{UInt8}, n::UInt)::Int
    p_start = p
    while p < (p_start + n)
        buf = get_nonempty_buffer(x)::Union{Nothing, ImmutableMemoryView{UInt8}}
        isnothing(buf) && break
        L = min(length(buf) % UInt, (p_start + n - p))
        GC.@preserve buf unsafe_copyto!(p, pointer(buf), L)
        p += L
        @inbounds consume(x, L % Int)
    end
    return (p - p_start) % Int
end

"""
    readavailable(io::AbstractBufReader)::Vector{UInt8}

Read the available bytes of `io` to a new `Vector{UInt8}`, except if zero bytes
are available. In that case, it will attempt to get more bytes exactly once.
If still no bytes are available, `io` is EOF, and the resulting vector is empty.
"""
function Base.readavailable(x::AbstractBufReader)
    buf = get_nonempty_buffer(x)::Union{Nothing, ImmutableMemoryView{UInt8}}
    isnothing(buf) && return UInt8[]
    result = Vector(buf)
    @inbounds consume(x, length(buf))
    return result
end

"""
    peek(io::AbstractBufReader)::UInt8

Get the next `UInt8` in `io`, without advancing `io`, or throw an `IOError`
containing `IOErrorKinds.EOF` if `io` is EOF.
"""
function Base.peek(x::AbstractBufReader, ::Type{UInt8})
    buffer = get_buffer(x)::ImmutableMemoryView{UInt8}
    isempty(buffer) && return _peek_empty(x, UInt8)
    return @inbounds buffer[1]
end

@noinline function _peek_empty(x::AbstractBufReader, ::Type{UInt8})
    fill_buffer(x)
    buffer = get_buffer(x)::ImmutableMemoryView{UInt8}
    isempty(buffer) && throw(IOError(IOErrorKinds.EOF))
    return @inbounds buffer[1]
end

"""
    read(io::AbstractBufReader, UInt8)::UInt8

Get the next `UInt8` in `io`, or throw an `IOError` containing `IOErrorKinds.EOF`
if `io` is EOF.
"""
function Base.read(x::AbstractBufReader, ::Type{UInt8})
    res = peek(x, UInt8)
    @inbounds consume(x, 1)
    return res
end

# One based indexing
# Read until EOF or nb
"""
    readbytes!(io::AbstractBufReader, b::AbstractVector{UInt8}, nb::Integer=length(b))::Int

Read at most `nb` bytes from `io` into `b`, returning the number of bytes read.
This function will read zero bytes if and only if `io` is EOF.

`b` must use one-based indexing. The size of `b` will be increased if needed (i.e. if nb is greater than
length(b) and enough bytes could be read), but it will never be decreased.

It is generally preferred to use `read_into!` instead of this method.
"""
function Base.readbytes!(x::AbstractBufReader, b::AbstractVector{UInt8}, nb::Integer = length(b))
    Base.require_one_based_indexing(b)
    nb = Int(nb)::Int
    n_read = 0
    initial_b_len = length(b)
    while n_read < nb
        buffer = get_nonempty_buffer(x)::Union{Nothing, ImmutableMemoryView{UInt8}}
        buffer === nothing && break
        remaining_b_space = max(0, initial_b_len - n_read)
        # Make sure to only append if `b` has already been filled, so it works
        # correctly with `b` that cannot be resized.
        if iszero(remaining_b_space)
            buffer = buffer[1:min(length(buffer), nb - n_read)]
            append!(b, buffer)
        else
            buffer = buffer[1:min(remaining_b_space, nb - n_read, length(buffer))]
            copyto!(b, n_read + 1, buffer, 1, length(buffer))
        end
        @inbounds consume(x, length(buffer))
        n_read += length(buffer)
    end
    return n_read
end

"""
    read!(io::AbstractBufReader, A::AbstractArray{UInt8}) -> A

Read from `io` into `A`, filling and returning it.
If `io` reaches EOF before filling `A`, throw an `IOError` with `IOErrorKinds.EOF`.

`A` is assumed to have `length(A)` number of contiguous, linear indices.

See also: [`read_all!`](@ref), [`read_into!`](@ref)
"""
function Base.read!(x::AbstractBufReader, A::AbstractArray{UInt8})
    return @something _read!(x, A) throw(IOError(IOErrorKinds.EOF))
end

@inline function _read!(
        x::AbstractBufReader,
        A::AbstractArray{UInt8}
    )::Union{AbstractArray, Nothing}
    Ai = first(eachindex(IndexLinear(), A))
    remaining = Int(length(A))::Int
    while remaining > 0
        buffer = get_nonempty_buffer(x)::Union{Nothing, ImmutableMemoryView{UInt8}}
        isnothing(buffer) && return nothing
        mn = min(remaining, length(buffer))
        buffer = @inbounds buffer[1:mn]
        copyto!(A, Ai, buffer, 1, mn)
        @inbounds consume(x, mn)
        Ai += mn
        remaining -= mn
    end
    return A
end

# delim is UInt8, if delimiter is not found, copies to end
function Base.copyuntil(
        out::Union{IO, AbstractBufWriter},
        from::AbstractBufReader,
        delim::UInt8;
        keep::Bool = false
    )
    while true
        buffer = get_nonempty_buffer(from)::Union{Nothing, ImmutableMemoryView{UInt8}}
        buffer === nothing && return out
        pos = findfirst(==(delim), buffer)
        if pos === nothing
            write(out, buffer)
            @inbounds consume(from, length(buffer))
        else
            to_write = @inbounds buffer[1:(pos - !keep)]
            write(out, to_write)
            @inbounds consume(from, pos)
            return out
        end
    end
    return out # unreachable
end

"""
    copyline(
        out::Union{IO, AbstractBufWriter},
        from::AbstractBufReader;
        keep::Bool = false
    ) -> out

Copy one line from `from` to `out`, returning `out`.
A line is defined as data up to and including \\n (byte 0x0a), or all remaining data in `from` if no such
byte is present.

If `keep` is `false`, as it is by default, the trailing `\\r\\n` (encoded as 0x0d 0x0a) or `\\n` will not be copied to `out`,
but it will be consumed from `from`.

This function may throw an `IOerror` with `IOErrorKinds.BufferTooShort`, if all the following occurs:
* `keep` is `false`
* The reader has a buffer size of 1
* The reader cannot expand its buffer
* The only byte in the buffer is `\\r` (0x0d). 
"""
function Base.copyline(out::Union{IO, AbstractBufWriter}, from::AbstractBufReader; keep::Bool = false)
    buffer = get_nonempty_buffer(from)::Union{Nothing, ImmutableMemoryView{UInt8}}
    buffer === nothing && return out
    while true
        pos = findfirst(==(0x0a), buffer)
        if pos === nothing
            to_write = if !keep && last(buffer) == 0x0d
                # If the buffer ends with \r (0xd), and we remove the newlines, we need to
                # conservatively not write the \r in case it's the beginning of an \r\n.
                if length(buffer) == 1
                    n_filled = fill_buffer(from)
                    if n_filled === nothing
                        # If the buffer is 1 byte long and cannot be expanded, we would never
                        # progress because we would always conservatively avoid writing anything, so error
                        throw(IOError(IOErrorKinds.BufferTooShort))
                    elseif iszero(n_filled)
                        # If nothing was filled, the stream ended at \r. Then, we can write everything out
                        buffer
                    else
                        # Else, we need to fill in more bytes
                        buffer = get_nonempty_buffer(from)::ImmutableMemoryView{UInt8}
                        continue
                    end
                else
                    @inbounds buffer[1:(end - 1)]
                end
            else
                buffer
            end
            write(out, to_write)
            @inbounds consume(from, length(to_write))
            fill_buffer(from)
            # This let-trick works around a compiler limitation and ensures it infers the type
            # of buffer in this loop.
            buffer = let
                b = get_nonempty_buffer(from)
                isnothing(b) && return out
                b
            end
        else
            buf = @inbounds buffer[1:pos]
            buf = keep ? buf : _chomp(buf)
            write(out, buf)
            @inbounds consume(from, pos)
            return out
        end
    end
    return out # unreachable
end

"""
    skip(io::AbstractBufReader, n::Integer)::Int

Read `n` bytes from `io`, or until EOF, whichever comes first, and discard
the read bytes. Return the number of bytes read.

This function is defined generically for `AbstractBufReader` by reading bytes,
not by seeking. Subtypes of `AbstractBufReader` may implement this using seeking.
In order to skip a generic `AbstractBufReader` and guarantee seeking is used,
use `seek(io, position(io) + n)`.

Throws an `ArgumentError` if `n < 0`.

See also: [`skip_exact`](@ref)

# Examples
```
julia> reader = CursorReader("abcdefghij");

julia> skip(reader, 5)
5

julia> read(reader, 3) |> String
"fgh"

julia> skip(reader, 10) # 2 bytes remaining
2

julia> eof(reader)
true

julia> skip(reader, 100)
0
```
"""
function Base.skip(io::AbstractBufReader, n::Integer)
    n < 0 && throw(ArgumentError("Cannot skip negative amount"))
    n = UInt(n)::UInt
    remaining = n
    while !iszero(remaining)
        buffer = get_nonempty_buffer(io)::Union{Nothing, ImmutableMemoryView{UInt8}}
        isnothing(buffer) && break
        mn = min(length(buffer) % UInt, remaining) % Int
        @inbounds consume(io, mn)
        remaining -= mn
    end
    return (n - remaining) % Int
end

# Different logic than `copyline`, because the destination vector is owned by
# this function, and therefore we can better handle the case where a 1-byte buffer
# ends with \r.
function Base.readline(x::AbstractBufReader; keep::Bool = false)
    v = UInt8[]
    while true
        buffer = get_nonempty_buffer(x)::Union{Nothing, ImmutableMemoryView{UInt8}}
        buffer === nothing && return String(v)
        pos = findfirst(==(0x0a), buffer)
        if pos === nothing
            append!(v, buffer)
            @inbounds consume(x, length(buffer))
        else
            append!(v, @inbounds buffer[1:pos])
            @inbounds consume(x, pos)
            break
        end
    end
    if !keep
        removed = false
        if !isempty(v) && @inbounds(last(v)) == 0x0a
            removed = true
            @inbounds pop!(v)
        end
        if removed && !isempty(v) && @inbounds(last(v)) == 0x0d
            @inbounds pop!(v)
        end
    end
    return String(v)
end

function Base.readuntil(x::AbstractBufReader, delim::UInt8; keep::Bool = false)
    io = VecWriter()
    copyuntil(io, x, delim; keep)
    return to_vector(io.vec)
end

"""
    unsafe_write(io::AbstractBufWriter, ref, nbytes::UInt)::Int

Write `nbytes` bytes from `ref` (converted to a pointer) to `io`,
and return `Int(nbytes)`.
If `io` does not have capacity to write more bytes, throw an `IOError(IOErrorKinds.EOF)`.

!!! warning
    Safety: If `ref` is a pointer, the caller is responsible for ensuring that the
    pointer is valid, GC protected, and points to at least `nbytes` data of readable memory.
"""
function Base.unsafe_write(io::AbstractBufWriter, ref, nbytes::UInt)::Int
    cval = Base.cconvert(Ptr{UInt8}, ref)
    GC.@preserve cval begin
        ptr = Base.unsafe_convert(Ptr{UInt8}, cval)::Ptr{UInt8}
        return unsafe_write(io, ptr, nbytes)
    end
end

function Base.unsafe_write(io::AbstractBufWriter, ptr::Ptr{UInt8}, n_bytes::UInt)::Int
    buffer = get_buffer(io)::MutableMemoryView{UInt8}
    return if (length(buffer) % UInt) ≥ n_bytes
        GC.@preserve buffer unsafe_copyto!(pointer(buffer), ptr, n_bytes)
        @inbounds consume(io, n_bytes % Int)
        n_bytes % Int
    else
        _unsafe_write(io, ptr, n_bytes)
    end
end

@noinline function _unsafe_write(io::AbstractBufWriter, ptr::Ptr{UInt8}, n_bytes::UInt)::Int
    remaining = n_bytes
    while !iszero(remaining)
        buffer = get_nonempty_buffer(io)::Union{Nothing, MutableMemoryView{UInt8}}
        isnothing(buffer) && throw(IOError(IOErrorKinds.EOF))
        isempty(buffer) && error("Invalid implementation of get_nonempty_buffer")
        mn = min(remaining, length(buffer) % UInt)
        GC.@preserve buffer unsafe_copyto!(pointer(buffer), ptr, mn)
        remaining -= mn
        ptr += mn
        @inbounds consume(io, mn % Int)
    end
    return n_bytes % Int
end

function Base.write(io::AbstractBufWriter, x::UInt8)
    buffer = get_nonempty_buffer(io)::Union{Nothing, MutableMemoryView{UInt8}}
    isnothing(buffer) && throw(IOError(IOErrorKinds.EOF))
    buffer[1] = x
    @inbounds consume(io, 1)
    return 1
end

Base.write(io::AbstractBufWriter, x::Bool) = write(io, reinterpret(UInt8, x))

# N.B: At least two args to prevent a stackoverflow.
function Base.write(io::AbstractBufWriter, x1, x2, xs...)
    n_written = write(io, x1)
    n_written += write(io, x2)
    for i in xs
        n_written += write(io, i)
    end
    return n_written
end

function Base.write(io::AbstractBufWriter, maybe_mem)
    return _write(MemoryKind(typeof(maybe_mem)), io, maybe_mem)
end

function Base.write(io::AbstractBufWriter, s::Union{String, SubString{String}})
    # TODO: In the future, we may want to simply forward to write(io, codeunits(s))
    # However, currently this would force the allocation of a new Memory object sharing
    # memory with `s`, so we can choose the more optimised route by using unsafe call instead.
    # We can change this if `ImmutableMemoryView(s)` no longer allocates in the future.
    return unsafe_write(io, s, sizeof(s) % UInt)
end

function _write(::IsMemory{<:MemoryView{<:PlainTypes}}, io::AbstractBufWriter, mem)
    return unsafe_write(io, mem, sizeof(mem) % UInt)
end

function Base.write(io::AbstractBufWriter, x::PlainTypes)
    # The bet here is that in 99% of cases, x will fit in the buffer on the first try.
    # so if we outline get grow_buffer code, which usually is more complex than get_buffer,
    # write itself will inline better
    buffer = get_buffer(io)::MutableMemoryView{UInt8}
    length(buffer) < sizeof(x) && return _write_grow_buffer(io, x, length(buffer))
    return @inline _copy_bits(io, buffer, x)
end

@noinline function _write_grow_buffer(io::AbstractBufWriter, x::PlainTypes, bufferlen::Int)
    while true
        grow_buffer(io)
        buffer = get_buffer(io)::MutableMemoryView{UInt8}
        # If the buffer does not grow, we go to the real slow path where x is written
        # one byte at a time
        length(buffer) ≤ bufferlen && return _write_slowpath(io, x)
        bufferlen = length(buffer)
        length(buffer) ≥ sizeof(x) && return _copy_bits(io, buffer, x)
    end
    error("unreachable")
end

@inline function _copy_bits(io::AbstractBufWriter, buffer::MutableMemoryView{UInt8}, x::PlainTypes)
    GC.@preserve buffer begin
        p = Ptr{typeof(x)}(pointer(buffer))
        unsafe_store!(p, x)
    end
    @inbounds consume(io, sizeof(x))
    return sizeof(x)
end

@noinline function _write_slowpath(io::AbstractBufWriter, x::PlainTypes)
    # We serialize as little endian, so byteswap if machine is big endian
    u = as_unsigned(x)
    n_written = 0
    while n_written < sizeof(u)
        buffer = get_nonempty_buffer(io)::Union{Nothing, MutableMemoryView{UInt8}}
        isnothing(buffer) && throw(IOError(IOErrorKinds.EOF))
        n_written_at_start = n_written
        for i in eachindex(buffer)
            buffer[i] = u % UInt8
            u >>>= 8
            n_written += 1
            n_written == sizeof(u) && break
        end
        @inbounds consume(io, n_written - n_written_at_start)
    end
    return sizeof(u)
end

Base.write(io::AbstractBufWriter, v::Union{Memory, Array}) = write(io, ImmutableMemoryView(v))

function Base.write(io::AbstractBufWriter, c::Char)
    u = bswap(reinterpret(UInt32, c))
    n = 0
    while true
        n += write(io, u % UInt8)
        u >>>= 8
        iszero(u) && return n
    end
    return
end

as_unsigned(x::PlainTypes) = as_unsigned(x, Val{sizeof(x)}())
as_unsigned(x, ::Val{1}) = reinterpret(UInt8, x)
as_unsigned(x, ::Val{2}) = reinterpret(UInt16, x)
as_unsigned(x, ::Val{4}) = reinterpret(UInt32, x)
as_unsigned(x, ::Val{8}) = reinterpret(UInt64, x)
as_unsigned(x, ::Val{16}) = reinterpret(UInt128, x)

Base.seekstart(x::Union{AbstractBufReader, AbstractBufWriter}) = seek(x, 0)
Base.seekend(x::Union{AbstractBufReader, AbstractBufWriter}) = seek(x, filesize(x))

Base.print(io::AbstractBufWriter, x) = show(io, x)
Base.print(io::AbstractBufWriter, s::Union{String, SubString{String}}) = (write(io, s); nothing)
