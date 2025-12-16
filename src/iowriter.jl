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

# Forward basic I/O methods
for f in [
        :close,
        :flush,
        :position,
        :filesize,
    ]
    @eval Base.$(f)(x::IOWriter) = $(f)(x.x)
end

# Write methods
Base.write(x::IOWriter, y::UInt8) = write(x.x, y)
# Base.write(x::IOWriter, data) = write(x.x, data)
# Base.write(x::IOWriter, data::Union{String, SubString{String}}) = write(x.x, data)
# Base.write(x::IOWriter, data::StridedArray) = write(x.x, data)
# Base.write(x::IOWriter, data::Char) = write(x.x, data)
# Base.write(x::IOWriter, data::Base.CodeUnits) = write(x.x, data.s)
# Base.write(x::IOWriter, x1, x2, xs...) = write(x.x, x1, x2, xs...)
Base.unsafe_write(io::IOWriter, p::Ptr{UInt8}, n::UInt) = unsafe_write(io.x, p, n)

Base.write(
    x::IOWriter, y::Union{
        Int16, UInt16,
        Int32, UInt32,
        Int64, UInt64,
        Int128, UInt128,
        Float16, Float32, Float64,
    }
) = write(x.x, y)

# Other methods
Base.seek(x::IOWriter, n::Integer) = (seek(x.x, n); x)
