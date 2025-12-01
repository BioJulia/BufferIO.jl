module BufferIO

using MemoryViews: MemoryViews,
    ImmutableMemoryView,
    MutableMemoryView,
    MemoryView,
    MemoryKind,
    IsMemory,
    NotMemory

export AbstractBufReader,
    AbstractBufWriter,
    BufReader,
    BufWriter,
    VecWriter,
    ByteVector,
    IOReader,
    IOWriter,
    CursorReader,
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
    relative_seek

public LineViewIterator

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
    * `BadSeek`: An out-of-bounds seek operation was attempted
    * `PermissionDenied`: Acces was denied to a system (filesystem, network, OS, etc.) resource
    * `NotFound`: Resource was not found, e.g. no such file or directory
    * `BrokenPipe`: The operation failed because a pipe was broken. This typically happens when
       writing to stdout or stderr, which then gets closed.
    * `AlreadyExists`: Resource (e.g. file) could not be created because it already exists
    * `NotADirectory`: Resource is unexpectedly not a directory. E.g. a path contained a non-directory
      file as an intermediate component.
    * `IsADirectory`: Resource is a directory when a non-directory was expected
    * `DirectoryNotEmpty`: Operation cannot succeed because it requires an empty directory
    * `InvalidFileName`: File name was invalid for platform, e.g. too long name, or invalid characters.
    * `ClosedIO`: Indicates an operation was done on a closed IO.
    """
    @enum IOErrorKind::UInt8 begin
        ConsumeBufferError
        BadSeek
        EOF
        BufferTooShort
        PermissionDenied
        NotFound
        BrokenPipe
        AlreadyExists
        NotADirectory
        IsADirectory
        DirectoryNotEmpty
        InvalidFileName
        ClosedIO
    end

    public ConsumeBufferError,
        BadSeek,
        EOF,
        BufferTooShort,
        PermissionDenied,
        NotFound,
        BrokenPipe,
        AlreadyExists,
        NotADirectory,
        IsADirectory,
        DirectoryNotEmpty,
        InvalidFileName,
        ClosedIO
end

using .IOErrorKinds: IOErrorKind

"""
    IOError

This type is thrown by errors of AbstractBufReader.
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
        "Invalid seek, possible out of range"
    elseif kind === IOErrorKinds.EOF
        "End of file"
    elseif kind === IOErrorKinds.BufferTooShort
        "Buffer of reader or writer is too short for operation"
    elseif kind === IOErrorKinds.PermissionDenied
        "Permission denied"
    elseif kind === IOErrorKinds.NotFound
        "Resource, perhaps a file, not found"
    elseif kind === IOErrorKinds.BrokenPipe
        "Write to broken UNIX pipe, possibly writing to closed stdout"
    elseif kind === IOErrorKinds.AlreadyExists
        "Unique resource already exists, possibly a filesystem path"
    elseif kind === IOErrorKinds.NotADirectory
        "Not a directory"
    elseif kind === IOErrorKinds.DirectoryNotEmpty
        "Directory not empty"
    elseif kind === IOErrorKinds.InvalidFileName
        "Invalid file name"
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

* `Base.seek(io::T, ::Int)`
* `relative_seek(io::T, ::Int)`
* `Base.filesize(io::T)`
* `Base.position(io::T)`
* `resize_buffer(io::T, ::Int)`

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
* `Base.seek(io::T, ::Int)`
* `Base.filesize(io::T)`
* `Base.position(io::T)`
* `get_unflushed(io::T)`
* `shallow_flush(io::T)`
* `resize_buffer(io::T, ::Int)`
* `get_nonempty_buffer(io::T, ::Int)`
"""
abstract type AbstractBufWriter end

function get_buffer end

"""
    fill_buffer(io::AbstractBufReader)::Union{Int, Nothing}

Fill more bytes into the buffer from `io`'s underlying buffer, returning
the number of bytes added. After calling `fill_buffer` and getting `n`,
the buffer obtained by `get_buffer` should have `n` new bytes appended.

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
    skip_exact(io::AbstractBufReader, n::Integer)::Nothing

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
function skip_exact(io::AbstractBufReader, n::Integer)
    n < 0 && throw(ArgumentError("Cannot skip negative amount"))
    skipped = skip(io, n)
    skipped == n || throw(IOError(IOErrorKinds.EOF))
    return nothing
end

#########################

# Types where write(io, x) is the same as copying x
const PLAIN_TYPES = (
    Int8, UInt8, Int16, UInt16, Int32, UInt32, Int64, UInt64, Int128, UInt128,
    Bool,
    Float16, Float32, Float64,
)

const PlainTypes = Union{PLAIN_TYPES...}
const PlainMemory = Union{map(T -> MemoryView{T}, PLAIN_TYPES)...}

"""
    get_nonempty_buffer(x::AbstractBufWriter)::Union{Nothing, MutableMemoryView{UInt8}}

Get a buffer with at least one byte, if bytes are available.
Otherwise, call `grow_buffer`, then get the buffer again.
Returns `nothing` if the buffer is still empty.
"""
function get_nonempty_buffer(x::AbstractBufWriter)::Union{Nothing, MutableMemoryView{UInt8}}
    buffer = get_buffer(x)::MutableMemoryView{UInt8}
    isempty(buffer) || return buffer
    grow_buffer(x)
    buffer = get_buffer(x)::MutableMemoryView{UInt8}
    return isempty(buffer) ? nothing : buffer
end

##########################

"""
	write_repeated(io::AbstractBufWriter, byte::UInt8, n::Integer)::Int

Write `byte` to `io` `n` times, or until `io` is full, and return the number
of written bytes.
This is equivalent to `write(io, fill(byte, n))`, but more efficient.

Throw an `InexactError` if `n` is negative.

# Examples
```jldoctest
julia> w = VecWriter(collect(b"abc"));

julia> write_repeated(w, UInt8('x'), 6)
6

julia> takestring!(w)
"abcxxxxxx"
```
"""
function write_repeated(io::AbstractBufWriter, byte::UInt8, n::Integer)
    remaining = UInt(n)::UInt
    original = remaining
    while !iszero(remaining)
        buffer = @something get_nonempty_buffer(io) return (original - remaining) % Int
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

include("base.jl")
include("bufreader.jl")
include("bufwriter.jl")
include("lineiterator.jl")
include("cursor.jl")
include("ioreader.jl")
include("iowriter.jl")
include("vecwriter.jl")

end # module BufferIO
