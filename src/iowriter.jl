"""
    IOWriter{T <: AbstractBufWriter} <: IO

Wrapper type to convert an `AbstractBufWriter` to an `IO`.

`IOWriter`s implement the same part of the `IO` interface as `AbstractBufWriter`,
so this type is only used to satisfy type constraints.

# Examples
```jldoctest
julia> io = VecWriter();

julia> f(x::IO) = write(x, "hello");

julia> f(io)
ERROR: MethodError: no method matching f(::VecWriter)
[...]

julia> f(IOWriter(io))
5

julia> String(io.vec)
"hello"
```
"""
struct IOWriter{T <: AbstractBufWriter} <: IO
    x::T
end

take_inner(x::IOWriter) = x.x

"""
    get_inner(io::IOWriter{T})::T

Return the `AbstractBufWriter` wrapped by `io`.

An `IOWriter` has no buffer or state of its own, so the wrapped writer may be used freely,
and `io` reflects any operation on it. For example, closing the wrapped writer closes `io`.

# Examples
```jldoctest
julia> vec = VecWriter(); io = IOWriter(vec);

julia> get_inner(io) === vec
true

julia> write(io, "ab"); write(get_inner(io), "cd"); String(vec.vec)
"abcd"
```
"""
get_inner(x::IOWriter) = x.x

# Forward basic I/O methods
for f in [
        :close,
        :isopen,
        :flush,
        :position,
        :filesize,
    ]
    @eval Base.$(f)(x::IOWriter) = $(f)(x.x)
end

# Write methods
Base.write(x::IOWriter, y::UInt8) = write(x.x, y)
Base.unsafe_write(io::IOWriter, p::Ptr{UInt8}, n::UInt) = unsafe_write(io.x, p, n)

# Other methods
Base.seek(x::IOWriter, n::Integer) = (seek(x.x, n); x)
Base.seekend(x::IOWriter) = (seekend(x.x); x)

# Base falls back to `isopen` for `IO`
Base.isreadable(::IOWriter) = false

# See comment on `copyline` in ioreader.jl
function Base.copyline(out::IOWriter, from::IOReader; keep::Bool = false)
    return copyline(out, from.x; keep)
end
