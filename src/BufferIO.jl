module BufferIO

using MemoryViews: MemoryViews,
    ImmutableMemoryView,
    MutableMemoryView,
    MemoryView,
    unsafe_memoryref

export AbstractBufReader,
    AbstractBufWriter,
    BufReader,
    BufWriter,
    VecWriter,
    ByteVector,
    IOReader,
    IOWriter,
    CursorReader,
    ExpandReader,
    IOError,
    IOErrorKinds,
    get_buffer,
    get_unflushed,
    get_nonempty_buffer,
    fill_buffer,
    grow_buffer,
    consume,
    shallow_flush,
    resize_buffer,
    read_into!,
    read_all!,
    line_views,
    skip_exact,
    takestring!,
    write_repeated,
    relative_seek,
    take_inner,
    drop_own,
    expandable

public LineViewIterator, is_expandable, Testing

"""
    module IOErrorKinds

Used as a namespace for IOErrorKind.
"""
module IOErrorKinds
    """
        IOErrorKind

    Enum indicating what error was thrown. The current list is non-exhaustive, and
    more may be added in future releases.
    The integral value of these enums are subject to change in minor versions.

    Current errors:
    * `ConsumeBufferError`: Occurs when calling `consume` with a negative amount of bytes,
      or with more bytes than `length(get_buffer(io))`
    * `EOF`: Occurs when trying a reading operation on a file that has reached end-of-file
    * `BufferTooShort`: Thrown by various functions that require a minimum buffer size, which
      the `io` cannot provide. This should only be thrown if the buffer is unable to grow to
      the required size, and not if e.g. the buffer does not expand because the io is EOF.
    * `WriterFull`: Occurs when a writer cannot make room for more data, i.e. when
      `grow_buffer` returns zero, such that a write operation cannot complete.
      If a writer can make room, but not a contiguous buffer of a required minimum size,
      `BufferTooShort` is thrown instead.
    * `BadSeek`: An out-of-bounds seek operation was attempted
    * `ClosedIO`: Indicates an operation was done on a closed IO.
    """
    @enum IOErrorKind::UInt8 begin
        ConsumeBufferError
        BadSeek
        EOF
        BufferTooShort
        WriterFull
        ClosedIO
    end

    public IOErrorKind,
        ConsumeBufferError,
        BadSeek,
        EOF,
        BufferTooShort,
        WriterFull,
        ClosedIO
end

using .IOErrorKinds: IOErrorKind

"""
    IOError

This type is thrown by errors of `AbstractBufReader` and `AbstractBufWriter`.
They contain the `.kind::IOErrorKind` public property.

See also: [`IOErrorKinds.IOErrorKind`](@ref)

# Examples
```jldoctest
julia> rdr = CursorReader("some content");

julia> try
           seek(rdr, 500)
       catch error
           if error.kind == IOErrorKinds.BadSeek
               println(stderr, "Seeking operation out of bounds")
           else
               rethrow()
           end
        end
Seeking operation out of bounds
```
"""
struct IOError <: Exception
    kind::IOErrorKind
end

function Base.showerror(io::IO, err::IOError)
    kind = err.kind
    str = if kind === IOErrorKinds.ConsumeBufferError
        "Called `consume` with a negative amount, or larger than available buffer size"
    elseif kind === IOErrorKinds.BadSeek
        "Invalid seek, possibly seek out of bounds"
    elseif kind === IOErrorKinds.EOF
        "End of file"
    elseif kind === IOErrorKinds.BufferTooShort
        "Buffer of reader or writer is too short for operation"
    elseif kind === IOErrorKinds.WriterFull
        "Writer is full and cannot make room for more data"
    elseif kind === IOErrorKinds.ClosedIO
        "Unsupported operation on closed IO"
    end
    return print(io, str)
end

# Internal type!
struct HitBufferLimit end

function _chomp(x::ImmutableMemoryView{UInt8})::ImmutableMemoryView{UInt8}
    len = if isempty(x)
        0
    else
        has_lf = @inbounds(x[end]) == 0x0a
        two_bytes = length(x) > 1
        has_cr = has_lf & two_bytes & (@inbounds(x[length(x) - two_bytes]) == 0x0d)
        length(x) - (has_lf + has_cr)
    end
    @inbounds return x[1:len]
end

"""
    abstract type AbstractBufReader end

An `AbstractBufReader` is a readable IO type that exposes a buffer of
readable bytes to the user.

!!! warning
    By default, subtypes of `AbstractBufReader` are **not threadsafe**, so concurrent usage
    should protect the instance behind a lock.

# Extended help
Subtypes of this type should not have a zero-sized buffer which cannot expand when calling
`fill_buffer`.

Subtypes `T` of this type should implement at least:

* `get_buffer(io::T)`
* `fill_buffer(io::T)`
* `consume(io::T, n::Int)`
* `Base.close(io::T)`

Subtypes may optionally define the following methods. See their docstring for `BufReader` / `BufWriter`
for details of the implementation:

* `Base.isopen(io::T)`
* `Base.seek(io::T, ::Int)`
* `relative_seek(io::T, ::Int)`
* `Base.filesize(io::T)`
* `Base.position(io::T)`
* `resize_buffer(io::T, ::Int)`
* `BufferIO.is_expandable(::Type{T})`

`AbstractBufReader`s have implementations for many Base IO methods, but with more precisely
specified semantics than for `Base.IO`.
See docstrings of the specific functions of interest.
"""
abstract type AbstractBufReader end

"""
    abstract type AbstractBufWriter end

An `AbstractBufWriter` is an IO-like type which exposes mutable memory
to the user, which can be written to directly.
This can help avoiding intermediate allocations when writing.
For example, integers can usually be written to buffered writers without allocating.

!!! warning
    By default, subtypes of `AbstractBufWriter` are **not threadsafe**, so concurrent usage
    should protect the instance behind a lock.

# Extended help

Subtypes of this type should not have a zero-sized buffer which cannot expand when calling
`grow_buffer`.

Subtypes `T` of this type should implement at least:

* `get_buffer(io::T)`
* `grow_buffer(io::T)`
* `consume(io::T, n::Int)`
* `Base.close(io::T)`
* `Base.flush(io::T)`

They may optionally implement
* `Base.isopen(io::T)`
* `Base.seek(io::T, ::Int)`
* `Base.filesize(io::T)`
* `Base.position(io::T)`
* `get_unflushed(io::T)`
* `shallow_flush(io::T)`
* `resize_buffer(io::T, ::Int)`
* `get_nonempty_buffer(io::T, ::Int)`
"""
abstract type AbstractBufWriter end

"""
    get_buffer(io::AbstractBufReader)::ImmutableMemoryView{UInt8}

Get the available bytes of `io`.

Calling this function, even when the buffer is empty, should never do actual system I/O,
and in particular should not attempt to fill the buffer.
To fill the buffer, call [`fill_buffer`](@ref).

# Examples
```jldoctest
julia> reader = BufReader(IOBuffer("abcdefghij"), 5);

julia> get_buffer(reader) |> isempty
true

julia> fill_buffer(reader)
5

julia> get_buffer(reader) |> println
UInt8[0x61, 0x62, 0x63, 0x64, 0x65]
```
"""
function get_buffer end

"""
    fill_buffer(io::AbstractBufReader)::Union{Int, Nothing}

Fill more bytes into the buffer from `io`'s underlying buffer, returning
the number of bytes added. After calling `fill_buffer` and getting `n`,
the buffer obtained by `get_buffer` should have `n` new bytes appended.

This function may move data in the internal buffer, invalidating previous
buffers obtained by `get_buffer`. However, data present in previous results
from `get_buffer` must be present in the new buffer at the same indices.
In other words, the following must always hold:

```julia
old_buffer = copy(get_buffer(io))
fill_buffer(io)
@assert get_buffer(io)[1:length(old_buffer)] == old_buffer
```

This function must fill at least one byte, except
* If the underlying io is EOF, or there is no underlying io to fill bytes from, return 0
* If the buffer is not empty, and cannot be expanded, return `nothing`.

Buffered readers which do not wrap another underlying IO, and therefore can't fill
its buffer should return 0 unconditionally.
This function should never return `nothing` if the buffer is empty.

!!! note
    Idiomatically, users should not call `fill_buffer` when the buffer is not empty,
    because doing so may force growing the buffer instead of letting `io` choose an optimal
    buffer size. Calling `fill_buffer` with a nonempty buffer is only appropriate if, for
    algorithmic reasons you need `io` itself to buffer some minimum amount of data.

# Examples
```jldoctest
julia> reader = CursorReader("abcde");

julia> fill_buffer(reader) # CursorReader can't fill its buffer
0

julia> reader = BufReader(IOBuffer("abcde"), 3);

julia> length(get_buffer(reader)) # buffer of BufReader initially empty
0

julia> fill_buffer(reader)
3

julia> length(get_buffer(reader)) # now must be 0 + 3
3
```
"""
function fill_buffer end

"""
    consume(io::Union{AbstractBufReader, AbstractBufWriter}, n::Int)::Nothing

Remove the first `n` bytes of the buffer of `io`.
Consumed bytes will not be returned by future calls to `get_buffer`.

If n is negative, or larger than the current buffer size,
throw an `IOError` with `ConsumeBufferError` kind.
This check is a boundscheck and may be elided with `@inbounds`.

# Examples
```jldoctest
julia> reader = CursorReader("abcdefghij");

julia> get_buffer(reader) == b"abcdefghij"
true

julia> consume(reader, 8); get_buffer(reader) |> println
UInt8[0x69, 0x6a]

julia> consume(reader, 3) # 2 bytes remaining
ERROR: Called `consume` with a negative amount, or larger than available buffer size
```
"""
function consume end

"""
    take_inner(io)

Return the inner io wrapped by `io`.

After calling `take_inner`, `io` is considered closed, and should not be used.
In particular, operations on `io` may mutate the wrapped IO, and so may invalidate it.
Calling `take_inner` on an `io` which is closed, or whose wrapped IO has already
been taken, is not allowed.

Implementations may, but are not required to, detect and prevent using `io` after `take_inner`,
or calling `take_inner` on a closed `io`, by throwing an `IOError` of kind `ClosedIO`.

# Examples
```jldoctest
julia> cursor = CursorReader("abc");

julia> reader = IOReader(cursor);

julia> take_inner(reader) === cursor
true
```
"""
function take_inner end

######################

"""
    get_nonempty_buffer(x::AbstractBufReader)::Union{Nothing, ImmutableMemoryView{UInt8}}

Get a buffer with at least one byte, if bytes are available.
Otherwise, fill the buffer, and return the newly filled buffer.
Returns `nothing` only if `x` is EOF.

# Examples
```jldoctest
julia> reader = BufReader(IOBuffer("abc"));

julia> get_buffer(reader) |> isempty
true

julia> get_nonempty_buffer(reader) |> println
UInt8[0x61, 0x62, 0x63]

julia> consume(reader, 3)

julia> get_nonempty_buffer(reader) === nothing # EOF
true
```
"""
function get_nonempty_buffer(x::AbstractBufReader)::Union{Nothing, ImmutableMemoryView{UInt8}}
    buf = get_buffer(x)::ImmutableMemoryView{UInt8}
    isempty(buf) || return buf
    fill_buffer(x)
    buf = get_buffer(x)::ImmutableMemoryView{UInt8}
    return isempty(buf) ? nothing : buf
end

"""
    read_into!(x::AbstractBufReader, dst::MutableMemoryView{UInt8})::Int

Read bytes into the beginning of `dst`, returning the number of bytes read.
This function will always read at least 1 byte, except when `dst` is empty,
or `x` is EOF.

This function is defined generically for `AbstractBufReader`. New methods
should strive to do at most one read call to the underlying IO, if `x`
wraps such an `IO`.

# Examples
```jldoctest
julia> reader = CursorReader("abcde");

julia> v = zeros(UInt8, 8);

julia> read_into!(reader, MemoryView(v))
5

julia> println(v)
UInt8[0x61, 0x62, 0x63, 0x64, 0x65, 0x00, 0x00, 0x00]
```
"""
function read_into!(x::AbstractBufReader, dst::MutableMemoryView{UInt8})::Int
    isempty(dst) && return 0
    src = get_nonempty_buffer(x)::Union{Nothing, ImmutableMemoryView{UInt8}}
    isnothing(src) && return 0
    n_read = copyto_start!(dst, src)
    @inbounds consume(x, n_read)
    return n_read
end

"""
    read_all!(io::AbstractBufReader, dst::MutableMemoryView{UInt8})::Int

Read bytes into `dst` until either `dst` is filled or `io` is EOF, returning
the number of bytes read.

# Examples
```jldoctest
julia> reader = BufReader(IOBuffer("abcdefgh"), 3);

julia> v = zeros(UInt8, 10);

julia> read_all!(reader, MemoryView(v))
8

julia> String(v)
"abcdefgh\\0\\0"
```
"""
function read_all!(io::AbstractBufReader, dst::MutableMemoryView{UInt8})::Int
    n_total_read = 0
    while !isempty(dst)
        buf = get_nonempty_buffer(io)::Union{Nothing, ImmutableMemoryView{UInt8}}
        isnothing(buf) && return n_total_read
        n_read_here = copyto_start!(dst, buf)
        n_total_read += n_read_here
        dst = @inbounds dst[(n_read_here + 1):end]
        @inbounds consume(io, n_read_here)
    end
    return n_total_read
end

"""
    skip_exact(io::AbstractBufReader, n::Int)::Nothing

Like `skip`, but throw an `IOError` of kind `IOErrorKinds.EOF` if `n` bytes could
not be skipped.

See also: [`Base.skip`](@ref)

# Examples
```jldoctest
julia> reader = CursorReader("abcdefghij");

julia> position(reader)
0

julia> skip_exact(reader, 3)

julia> read(reader, 2) |> String
"de"

julia> skip_exact(reader, 6) # 5 bytes remaining
ERROR: End of file
```
"""
# `skip` throws the `ArgumentError` for negative `n`
function skip_exact(io::AbstractBufReader, n::Int)
    skipped = skip(io, n)
    skipped == n || throw(IOError(IOErrorKinds.EOF))
    return nothing
end

#########################

"""
    get_nonempty_buffer(x::AbstractBufWriter)::Union{Nothing, MutableMemoryView{UInt8}}

Get a buffer with at least one byte, if bytes are available.
Otherwise, call `grow_buffer`, then get the buffer again.
Returns `nothing` if the buffer is still empty.

# Examples
```jldoctest
julia> io = BufWriter(IOBuffer(), 12);

julia> write_repeated(io, 0x00, 12)
12

julia> get_buffer(io) |> isempty
true

julia> get_nonempty_buffer(io) |> isempty
false

julia> get_buffer(io) |> isempty # buffer now grown
false
```
"""
function get_nonempty_buffer(x::AbstractBufWriter)::Union{Nothing, MutableMemoryView{UInt8}}
    buffer = get_buffer(x)::MutableMemoryView{UInt8}
    isempty(buffer) || return buffer
    grow_buffer(x)
    buffer = get_buffer(x)::MutableMemoryView{UInt8}
    return isempty(buffer) ? nothing : buffer
end

"""
    get_nonempty_buffer(
        io::AbstractBufWriter, min_size::Int
    )::Union{Nothing, MutableMemoryView{UInt8}}

Get a buffer of at least `max(min_size, 1)` bytes, or `nothing` if `io` cannot
provide a buffer of that size.
The desired buffer length is obtained by repeatedly calling [`grow_buffer`](@ref).

Writers whose buffer can grow without bound, such as [`VecWriter`](@ref) and
[`BufWriter`](@ref), never return `nothing`.

!!! warning
    Use of this method may cause excessive buffering without flushing,
    which is less memory efficient than calling the one-argument method
    and flushing in a loop.

# Extended help
Subtypes of `AbstractBufWriter` may implement this method if they can provide a large
buffer more efficiently than the generic fallback.
The returned buffer must contain at least `max(min_size, 1)` bytes.

# Examples
```jldoctest
julia> using BufferIO.Testing: BoundedWriter

julia> writer = BoundedWriter(UInt8[], 4);

julia> length(get_nonempty_buffer(writer, 3)) ≥ 3
true

julia> get_nonempty_buffer(writer, 5) === nothing # buffer can hold at most 4 bytes
true

julia> length(get_nonempty_buffer(VecWriter(), 100)) ≥ 100 # VecWriter can always grow
true
```
"""
function get_nonempty_buffer(x::AbstractBufWriter, min_size::Int)::Union{Nothing, MutableMemoryView{UInt8}}
    buffer = get_buffer(x)::MutableMemoryView{UInt8}
    length(buffer) ≥ max(min_size, 1) && return buffer
    return get_nonempty_buffer_slowpath(x, max(min_size, 1), length(buffer))
end

@noinline function get_nonempty_buffer_slowpath(
        x::AbstractBufWriter,
        min_size::Int,
        current_size::Int,
    )::Union{Nothing, MutableMemoryView{UInt8}}
    while true
        grown = grow_buffer(x)::Int
        iszero(grown) && return nothing
        buffer = get_buffer(x)::MutableMemoryView{UInt8}
        if length(buffer) != current_size + grown
            error("Invalid implementation of grow_buffer")
        end
        length(buffer) ≥ min_size && return buffer
        current_size = length(buffer)
    end
    return
end

##########################

"""
	write_repeated(io::AbstractBufWriter, byte::UInt8, n::Int)::Int

Write `byte` to `io` `n` times, and return `n`.
This is equivalent to `write(io, fill(byte, n))`, but more efficient.

Throw an `InexactError` if `n` is negative.
If `io` cannot make room for all `n` bytes, throw an `IOError` of kind
`IOErrorKinds.WriterFull`. In that case, some bytes may already have been written.

# Examples
```jldoctest
julia> w = VecWriter(collect(b"abc"));

julia> write_repeated(w, UInt8('x'), 6)
6

julia> takestring!(w)
"abcxxxxxx"
```
"""
function write_repeated(io::AbstractBufWriter, byte::UInt8, n::Int)
    remaining = UInt(n)::UInt
    original = remaining
    while !iszero(remaining)
        buffer = @something get_nonempty_buffer(io) throw(IOError(IOErrorKinds.WriterFull))
        buffer = @inbounds buffer[1:min(length(buffer) % UInt, remaining)]
        fill!(buffer, byte)
        @inbounds consume(io, length(buffer))
        remaining -= length(buffer) % UInt
    end
    return original % Int
end

function copyto_start!(dst::MutableMemoryView{T}, src::ImmutableMemoryView{T})::Int where {T}
    mn = min(length(dst), length(src))
    @inbounds copyto!(@inbounds(dst[begin:mn]), @inbounds(src[begin:mn]))
    return mn
end

# Get the new size of a buffer grown from size `size`
# Copied from Base
function overallocation_size(size::UInt)
    # compute maxsize = maxsize + 3*maxsize^(7/8) + maxsize/8
    # for small n, we grow faster than O(n)
    # for large n, we grow at O(n/8)
    # and as we reach O(memory) for memory>>1MB,
    # this means we end by adding about 10% of memory each time
    # most commonly, this will take steps of 0-3-9-34 or 1-4-16-66 or 2-8-33
    exp2 = sizeof(size) * 8 - leading_zeros(size)
    eighth = div(size, 8)
    log = (1 << div(exp2 * 7, 8)) * 3
    return (size + log + eighth) % Int
end

"""
    is_expandable(T::Type{<:AbstractBufReader})::Bool

Trait function that signals if `fill_buffer` on instances of type `T` never returns
`nothing`. That is, a type `T` must only implement `is_expandable(::Type{T}) = true`
if `fill_buffer(::T)` returns an `Int` for every instance of `T`.

In practice, this means instances of `T` are able to buffer their entire content with
repeated calls to `fill_buffer`. Types for which this returns `true` either already
buffer their whole content (such as [`CursorReader`](@ref)), or else have a growable
buffer large enough to hold all the underlying data (such as [`BufReader`](@ref) or
[`ExpandReader`](@ref)).

This is a property of the type, not of the instance, and must be constant foldable.
It is usually implemented as a constant `true`.
The default is `is_expandable(::Type{<:AbstractBufReader}) = false`.

Readers that wrap another reader and forward its buffer, e.g. a type `Wrapper{T}`,
can typically only grow their buffer if the inner reader can. Such types should usually
forward the trait instead of returning `true`:

```julia
BufferIO.is_expandable(::Type{Wrapper{T}}) where {T} = BufferIO.is_expandable(T)
```

See also: [`expandable`](@ref)

# Examples
```jldoctest
julia> BufferIO.is_expandable(BufReader)
true

julia> BufferIO.is_expandable(CursorReader)
true

julia> struct FooReader <: AbstractBufReader end

julia> BufferIO.is_expandable(FooReader) # default is false
false
```
"""
is_expandable(::Type{<:AbstractBufReader}) = false

include("base.jl")
include("bufreader.jl")
include("bufwriter.jl")
include("lineiterator.jl")
include("cursor.jl")
include("ioreader.jl")
include("iowriter.jl")
include("vecwriter.jl")
include("expander.jl")
include("testing.jl")

end # module BufferIO
