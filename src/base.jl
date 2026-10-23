Base.bytesavailable(x::AbstractBufReader) = length(get_buffer(x))

Base.eof(x::AbstractBufReader) = isnothing(get_nonempty_buffer(x))

Base.read(x::AbstractBufReader, ::Type{String}) = String(read(x))

"""
    read(io::AbstractBufReader)::Vector{UInt8}

Read all of `io` into a new `Vector{UInt8}` and return the vector.

This function repeatedly reads from `io` and resizes the vector until `io` reached EOF.
If the filesize of `io` is known beforehand, calling `read(io, file_size)` may be faster.

# Examples
```jldoctest
julia> v = read(CursorReader("hello"));

julia> typeof(v) === Vector{UInt8}
true

julia> v == b"hello"
true
```
"""
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
    read(io::AbstractBufReader, nb::Integer)::Vector{UInt8}

Read bytes from `io` until either `nb` bytes are read or `io` is EOF, and return the
bytes read as a `Vector{UInt8}`.

This allocates a `Vector{UInt8}` of size `nb`, so do not pass a large
value as `nb` in order to read the whole of `io`; use `read(io)` instead.

Throw an `ArgumentError` if `nb` is negative.

# Examples
```jldoctest
julia> io = CursorReader("hello, world!");

julia> v = read(io, 8);

julia> typeof(v) == Vector{UInt8}
true

julia> v == b"hello, w"
true

julia> read(io, 100) == b"orld!"
true

julia> isempty(read(io, 10))
true
```
"""
function Base.read(x::AbstractBufReader, nb::Integer)
    nb = Int(nb)::Int
    nb < 0 && throw(ArgumentError("nb cannot be negative"))
    v = sizehint!(UInt8[], nb)
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
    readavailable(io::AbstractBufReader)::Vector{UInt8}

Read the available bytes of `io` to a new `Vector{UInt8}`, except if zero bytes
are available. In that case, it will attempt to get more bytes exactly once.
If still no bytes are available, `io` is EOF, and the resulting vector is empty.

# Examples
```jldoctest
julia> io = BufReader(IOBuffer("hello, world!"), 10);

julia> bytesavailable(io)
0

julia> readavailable(io) == b"hello, wor"
true

julia> readavailable(io) == b"ld!"
true

julia> readavailable(io) == b""
true
```
"""
function Base.readavailable(x::AbstractBufReader)
    buf = get_nonempty_buffer(x)::Union{Nothing, ImmutableMemoryView{UInt8}}
    isnothing(buf) && return UInt8[]
    result = Vector(buf)
    @inbounds consume(x, length(buf))
    return result
end

"""
    peek(io::AbstractBufReader, UInt8)::UInt8

Get the next `UInt8` in `io`, without advancing the IO,
or throw an `IOError` containing `IOErrorKinds.EOF` if `io` is EOF.

# Examples
```jldoctest
julia> io = CursorReader("x");

julia> peek(io, UInt8) === UInt8('x')
true

julia> read(io, UInt8) == UInt8('x') # now EOF
true

julia> peek(io, UInt8)
ERROR: End of file
[...]
```
"""
function Base.peek(io::AbstractBufReader, ::Type{UInt8})
    buffer = get_buffer(io)::ImmutableMemoryView{UInt8}
    if isempty(buffer)
        return @noinline _peek(io)
    end
    return @inbounds buffer[1]
end

function _peek(io::AbstractBufReader)
    fill_buffer(io)
    buffer = get_buffer(io)::ImmutableMemoryView{UInt8}
    return isempty(buffer) ? throw(IOError(IOErrorKinds.EOF)) : @inbounds buffer[1]
end

Base.peek(io::AbstractBufReader) = peek(io, UInt8)

"""
    read(io::AbstractBufReader, UInt8)::UInt8

Get the next `UInt8` in `io`, or throw an `IOError` containing `IOErrorKinds.EOF`
if `io` is EOF.

# Examples
```jldoctest
julia> io = CursorReader("xy");

julia> read(io, UInt8) === UInt8('x')
true

julia> read(io, UInt8) === UInt8('y')
true

julia> read(io, UInt8)
ERROR: End of file
[...]
```
"""
function Base.read(x::AbstractBufReader, ::Type{UInt8})
    byte = peek(x)
    @inbounds consume(x, 1)
    return byte
end

# One based indexing
# Read until EOF or nb
"""
    readbytes!(io::AbstractBufReader, b::AbstractVector{UInt8}, nb::Integer=length(b))::Int

Read at most `nb` bytes from `io` into `b`, returning the number of bytes read.
If `nb > 0`, this function will read zero bytes if and only if `io` is EOF.

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
                        # If nothing was filled, the stream ended at \r. Then, we can write everything out.
                        # Get the buffer again, since `fill_buffer` may have invalidated it.
                        get_buffer(from)
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

function Base.readline(x::AbstractBufReader; keep::Bool = false)
    buffer = get_nonempty_buffer(x)::Union{Nothing, ImmutableMemoryView{UInt8}}
    buffer === nothing && return ""
    pos = findfirst(==(0x0a), buffer)
    pos === nothing && return readline_slowpath(x, keep)
    return take_line!(x, buffer, pos, keep)
end

# Copy the first `n` bytes of `buffer`, which is the buffer of `x`, into a string,
# and consume them.
@inline function take_line!(x::AbstractBufReader, buffer::ImmutableMemoryView{UInt8}, n::Int, keep::Bool)
    line = @inbounds buffer[1:n]
    str = String(keep ? line : _chomp(line))
    @inbounds consume(x, n)
    return str
end

# The buffer of `x` is nonempty, and contains no newline.
# Grow the buffer until it contains the line, so it can be copied into a string once.
@noinline function readline_slowpath(x::AbstractBufReader, keep::Bool)
    pos = buffer_until(x, 0x0a)
    pos isa HitBufferLimit && return readline_accumulate(x, keep)
    buffer = get_buffer(x)
    # If no newline was found, the buffer holds the remaining data until EOF.
    return take_line!(x, buffer, something(pos, length(buffer)), keep)
end

# The buffer of `x` is nonempty, contains no newline, and can't grow.
# Different logic than `copyline`, because the destination vector is owned by
# this function, and therefore we can better handle the case where a 1-byte buffer
# ends with \r.
function readline_accumulate(x::AbstractBufReader, keep::Bool)
    buffer = get_buffer(x)
    # `String(v)` takes ownership of the memory of `v` instead of copying it, also after
    # `v` has grown. This requires `v` to start with nonempty memory, since an empty
    # `StringVector` uses Base's shared empty memory, which is not owned by a string.
    v = empty!(string_vector(length(buffer)))
    while true
        pos = findfirst(==(0x0a), buffer)
        if pos === nothing
            append!(v, buffer)
            @inbounds consume(x, length(buffer))
        else
            append!(v, @inbounds buffer[1:pos])
            @inbounds consume(x, pos)
            break
        end
        buffer = @something get_nonempty_buffer(x)::Union{Nothing, ImmutableMemoryView{UInt8}} break
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
    return io.vec
end

"""
    unsafe_write(io::AbstractBufWriter, ref, nbytes::Integer)::Int

Write `nbytes` bytes from `ref` (converted to a pointer) to `io`,
and return `Int(nbytes)`.
If `io` does not have capacity to write more bytes, throw an `IOError(IOErrorKinds.WriterFull)`.
In that case, some bytes may already have been written.

`ref` may be a `Ref{T}` of any bitstype `T`, in which case the bytes of the referenced
value are written.

!!! warning
    Safety: If `ref` is a pointer, the caller is responsible for ensuring that the
    pointer is valid, GC protected, and points to at least `nbytes` data of readable memory.
    If `ref` is a `Ref{T}` that is not a `Ptr`, `nbytes` must not exceed `sizeof(T)`.
"""
function Base.unsafe_write(io::AbstractBufWriter, ref, nbytes::UInt)::Int
    cval = Base.cconvert(Ptr{UInt8}, ref)
    GC.@preserve cval begin
        ptr = Base.unsafe_convert(Ptr{UInt8}, cval)::Ptr{UInt8}
        return unsafe_write(io, ptr, nbytes)
    end
end

# Base's `IO` accepts any `Integer` for `nbytes`. Inlined for the same reason as the
# `Ref{T}` method below.
@inline function Base.unsafe_write(io::AbstractBufWriter, ref, nbytes::Integer)::Int
    return unsafe_write(io, ref, UInt(nbytes)::UInt)
end

# Base's `unsafe_convert(Ptr{UInt8}, ::Ref{T})` only exists for some `T`, so we convert
# to `Ptr{T}` instead, like Base's `unsafe_write(::IO, ::Ref, ::Integer)` does.
# Inlining means the pointer, not the `Ref`, is passed to any non-inlined slow path,
# which lets the compiler allocate the `Ref` on the stack.
# A `Ptr{T}` is a `Ref{T}`, but points to raw memory
# the caller vouches for, so it's exempt. Both checks are resolved at compile time.
@inline function Base.unsafe_write(io::AbstractBufWriter, ref::Ref{T}, nbytes::UInt)::Int where {T}
    ref isa Ptr || isbitstype(T) || throw(ArgumentError("Can only write from a Ref{T} if T is a bitstype"))
    cval = Base.cconvert(Ref{T}, ref)
    GC.@preserve cval begin
        ptr = Ptr{UInt8}(Base.unsafe_convert(Ref{T}, cval)::Ptr)
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
        isnothing(buffer) && throw(IOError(IOErrorKinds.WriterFull))
        isempty(buffer) && error("Invalid implementation of get_nonempty_buffer")
        mn = min(remaining, length(buffer) % UInt)
        GC.@preserve buffer unsafe_copyto!(pointer(buffer), ptr, mn)
        remaining -= mn
        ptr += mn
        @inbounds consume(io, mn % Int)
    end
    return n_bytes % Int
end

function Base.write(io::AbstractBufWriter, byte::UInt8)
    buffer = get_buffer(io)::MutableMemoryView{UInt8}
    if isempty(buffer)
        return @noinline _write_slowpath(io, byte)
    else
        @inbounds buffer[1] = byte
        @inbounds consume(io, 1)
        return 1
    end
end

function _write_slowpath(io::AbstractBufWriter, byte::UInt8)
    grow_buffer(io)
    buffer = get_buffer(io)::MutableMemoryView{UInt8}
    isempty(buffer) && throw(IOError(IOErrorKinds.WriterFull))
    @inbounds buffer[1] = byte
    @inbounds consume(io, 1)
    return 1
end

function Base.write(io::AbstractBufWriter, s::Union{String, SubString{String}})
    # TODO: In the future, we may want to simply forward to write(io, codeunits(s))
    # However, currently this would force the allocation of a new Memory object sharing
    # memory with `s`, so we can choose the more optimised route by using unsafe call instead.
    # We can change this if `ImmutableMemoryView(s)` no longer allocates in the future.
    return unsafe_write(io, s, sizeof(s) % UInt)
end

Base.write(io::AbstractBufWriter, mem::MemoryView{UInt8}) = unsafe_write(io, mem, length(mem) % UInt)

function Base.write(
        io::AbstractBufWriter,
        mem::Base.CodeUnits{UInt8, <:Union{String, SubString{String}}},
    )
    return unsafe_write(io, mem, sizeof(mem) % UInt)
end

Base.write(io::AbstractBufWriter, v::Union{Memory{UInt8}, Array{UInt8}}) = write(io, ImmutableMemoryView(v))

function Base.write(
        io::AbstractBufWriter,
        v::SubArray{UInt8, N, P, I, true},
    ) where {
        N,
        P,
        I <: Union{Tuple{AbstractUnitRange, Vararg{Any}}, Tuple{Vararg{Integer}}},
    }
    return write(io, ImmutableMemoryView(v))
end

"""
    close(io::Union{AbstractBufReader, AbstractBufWriter})

Close `io`, releasing its underlying resources, such as a wrapped IO or a file handle.
If `io` is a writer, `close` first flushes `io`, so no written data is lost.

Closing is idempotent: Closing an `io` which is already closed does nothing.

After `io` is closed, the behaviour of operations on `io` is unspecified, except
that `close` and `isopen` behave as documented, and that no operation causes undefined
behaviour. Depending on the implementation, operations on a closed `io` may throw an
`IOError` of kind `ClosedIO`, or continue to work normally.

See also: [`take_inner`](@ref)

# Examples
```jldoctest
julia> reader = BufReader(IOBuffer("abc"));

julia> close(reader); close(reader) # closing twice does nothing

julia> isopen(reader)
false

julia> read(reader)
ERROR: Unsupported operation on closed IO
[...]
```
"""
Base.close(::Union{AbstractBufReader, AbstractBufWriter})

"""
    isopen(io::Union{AbstractBufReader, AbstractBufWriter})::Bool

Return whether `io` is still usable, that is, return `false` if and only if `io` has been
made unusable by `close` or `take_inner`, or a similar function.

For types that remain usable after `close`, such as [`VecWriter`](@ref), `isopen`
should return `true`, even after `close` has been called on the io. 
Hence, `isopen(io)` does not generically tell whether `close(io)` has been called.

# Examples
```jldoctest
julia> reader = BufReader(IOBuffer("abc"));

julia> isopen(reader)
true

julia> close(reader); isopen(reader)
false

julia> cursor = CursorReader("abc");

julia> close(cursor); isopen(cursor) # closing a CursorReader does nothing
true
```
"""
Base.isopen(::Union{AbstractBufReader, AbstractBufWriter})

# Subtypes implement `seek(::T, ::Int)`. Like Base's `seek`, this accepts any `Integer`,
# converting and forwarding it to the subtype's method.
# The `Int` check stops a subtype without a `seek` method from recursing forever.
function Base.seek(x::Union{AbstractBufReader, AbstractBufWriter}, offset::Integer)
    offset isa Int && throw(MethodError(seek, (x, offset)))
    return seek(x, Int(offset)::Int)
end

Base.seekstart(x::Union{AbstractBufReader, AbstractBufWriter}) = seek(x, 0)
Base.seekend(x::Union{AbstractBufReader, AbstractBufWriter}) = seek(x, filesize(x))

# Printing a single value is forwarded to `IOWriter`, which inherits Base's `print` and
# `show` methods for `IO`.
Base.print(io::AbstractBufWriter, x) = print(IOWriter(io), x)
Base.print(io::AbstractBufWriter, s::Union{String, SubString{String}}) = (write(io, s); nothing)

# The varargs methods must be defined here, because otherwise, Base's `print(xs...)`
# would print the writer itself, and the arguments, to stdout.
# Unlike Base's `print(::IO, xs...)`, this does not lock the IO in a `try`/`finally`
# block, which is slow, and not needed because writers are not threadsafe anyway.
# Recursion instead of a loop lets the compiler specialize on each argument.
# `Vararg{Any, N}` forces specialization, which Julia otherwise does not do for
# varargs that are only passed through to another function.
Base.print(::AbstractBufWriter) = nothing

@inline function Base.print(io::AbstractBufWriter, x, xs::Vararg{Any, N}) where {N}
    print(io, x)
    return print(io, xs...)
end

@inline Base.println(io::AbstractBufWriter, xs::Vararg{Any, N}) where {N} = print(io, xs..., "\n")
