"""
    ByteVector <: DenseVector{UInt8}

A re-implementation of `Vector{UInt8}` that only supports a subset of its methods.
In future minor releases, this may change to be an alias of `Vector{UInt8}`.

Note that `String(x::ByteVector)` will truncate `x`, to mirror the behaviour of
`String(::Vector{UInt8})`. It is recommended to use `takestring!` instead.

All Base methods implemented for `ByteVector` is guaranteed to have the same semantics
as those for `Vector`. Futhermore, `ByteVector` supports:
* `takestring!(::ByteVector)` even on Julia < 1.13, whereas `takestring!(::Vector{UInt8})`
  is only defined from Julia 1.13 onwards.
"""
mutable struct ByteVector <: DenseVector{UInt8}
    ref::MemoryRef{UInt8}
    len::Int

    global function unsafe_from_parts(ref::MemoryRef{UInt8}, len::Int)
        return new(ref, len)
    end
end

function ByteVector()
    return unsafe_from_parts(memoryref(Memory{UInt8}()), 0)
end

function ByteVector(::UndefInitializer, len::Int)
    return unsafe_from_parts(memoryref(Memory{UInt8}(undef, len)), len)
end

@inline function _takestring!(v::ByteVector)
    s = GC.@preserve v unsafe_string(pointer(v), length(v))
    # We defensively truncate here and reallocate the memory.
    # Currently this is inefficient, but I want to be able to do zero-copy string creation
    # in the future, and that will only be doable without breakage by reallocating the memory.
    empty!(v)
    v.ref = memoryref(Memory{UInt8}()) # note: a zero-sized memory usually does not allocate
    return s
end

# This is for forward compatibility so we can switch in Vector{UInt8} in the future.
Base.String(v::ByteVector) = _takestring!(v)

@static if hasmethod(parent, Tuple{MemoryRef})
    get_memory(v::ByteVector) = parent(v.ref)
else
    get_memory(v::ByteVector) = v.ref.mem
end

Base.size(x::ByteVector) = (x.len,)
Base.length(x::ByteVector) = x.len

Base.empty!(x::ByteVector) = (x.len = 0; x)

function Base.resize!(x::ByteVector, n::Integer)
    n = Int(n)::Int
    if (n % UInt) > UInt(2)^48
        throw(ArgumentError("New length must be in 0:2^48"))
    end
    if n > length(get_memory(x))
        memsize = overallocation_size(n % UInt)
        newmem = Memory{UInt8}(undef, memsize)
        unsafe_copyto!(MemoryView(newmem), MemoryView(x))
        x.ref = memoryref(newmem)
        x.len = n
    end
    x.len = n
    return x
end

function Base.getindex(v::ByteVector, i::Integer)
    i = Int(i)::Int
    @boundscheck checkbounds(v, i)
    ref = @inbounds memoryref(v.ref, i)
    return @inbounds ref[]
end

function Base.setindex!(v::ByteVector, x, i::Integer)
    @boundscheck checkbounds(v, i)
    xT = convert(UInt8, x)::UInt8
    ref = @inbounds memoryref(v.ref, i)
    @inbounds ref[] = xT
    return v
end

function Base.iterate(x::ByteVector, i::Int = 1)
    ((i - 1) % UInt) < (length(x) % UInt) || return nothing
    return (@inbounds x[i], i + 1)
end

function Base.push!(x::ByteVector, u::UInt8)
    ensure_unused_space!(x, UInt(1))
    xlen = x.len + 1
    x.len = xlen
    @inbounds x[xlen] = u
    return x
end

function Base.append!(x::ByteVector, mem::MemoryView{UInt8})
    ensure_unused_space!(x, length(mem) % UInt)
    start_index = memindex(x.ref) + x.len
    dst = @inbounds MemoryView(get_memory(x))[start_index:end]
    @inbounds copyto!(dst, mem)
    x.len += length(mem)
    return x
end

Base.pointer(x::ByteVector) = Ptr{UInt8}(pointer(x.ref))

Base.sizeof(x::ByteVector) = length(x)

MemoryViews.MemoryKind(::Type{ByteVector}) = IsMemory{MutableMemoryView{UInt8}}()

function MemoryViews.MemoryView(v::ByteVector)
    return MemoryViews.unsafe_from_parts(v.ref, v.len)
end

function Base.Vector(v::ByteVector)
    result = Vector{UInt8}(undef, length(v))
    unsafe_copyto!(MemoryView(result), MemoryView(v))
    return result
end

@static if isdefined(Base, :memoryindex)
    memindex(x::MemoryRef) = Base.memoryindex(x)
else
    memindex(x::MemoryRef) = Core.memoryrefoffset(x)
end

# If C = Current capacity (get_unflushed + get_buffer)
# Then makes sure new capacity is overallocation(C + additional).
# Do this by zeroing offset and, if necessary, reallocating memory
function add_space_with_overallocation!(vec::ByteVector, additional::UInt)
    current_mem = get_memory(vec)
    new_size = overallocation_size(capacity(vec) % UInt + additional)
    new_mem = if length(current_mem) ≥ new_size
        current_mem
    else
        Memory{UInt8}(undef, new_size)
    end
    @inbounds copyto!(@inbounds(MemoryView(new_mem)[1:length(vec)]), MemoryView(vec))
    vec.ref = memoryref(new_mem)
    return nothing
end

# Ensure unused space is at least `space` bytes. Will overallocate
function ensure_unused_space!(v::ByteVector, space::UInt)
    us = unused_space(v)
    us % UInt ≥ space && return nothing
    space_to_add = space - us
    return @noinline add_space_with_overallocation!(v, space_to_add)
end


"""
    VecWriter <: AbstractBufWriter

A writer backed by a [`ByteVector`](@ref).
Read the (public) property `.vec` to get the vector back.

This type is useful as an efficient string builder through `takestring!(io)`.

Functions `flush` and `close` do not affect the writer.

Mutating `io` will mutate `vec` and vice versa. Neither `vec` nor `io` will
be invalidated by mutating the other, but doing so may affect the
implicit (non-semantic) behaviour (e.g. memory reallocations or efficiency) of the other.
For example, repeated and interleaved `push!(vec)` and `write(io, x)`
may be less efficient, if one operation has memory allocation patterns
that is suboptimal for the other operation.

Create with one of the following constructors:
* `VecWriter([vec::Vector{UInt8}])`
* `VecWriter(undef, ::Int)`
* `VecWriter(::ByteVector)`

Note that, currently, when constructing from a `Vector{UInt8}`,
the vector is invalidated and the `VecWriter` and its wrapped `ByteVector`
take shared control of the underlying memory.
This restriction may be lifted in the future.

A VecWriter has no notion of `filesize`, and cannot be `seek`ed. Instead, resize
the underlying vector `io.vec`.

```jldoctest
julia> vw = VecWriter();

julia> write(vw, "Hello, world!", 0xe1fa)
15

julia> append!(vw.vec, b"More data");

julia> String(vw.vec)
"Hello, world!\\xfa\\xe1More data"
```
"""
struct VecWriter <: AbstractBufWriter
    vec::ByteVector

    VecWriter(v::ByteVector) = new(v)
end

const DEFAULT_VECWIRTER_SIZE = 32

VecWriter() = VecWriter(undef, DEFAULT_VECWIRTER_SIZE)

function VecWriter(::UndefInitializer, len::Int)
    return VecWriter(empty!(ByteVector(undef, len)))
end

function VecWriter(v::Vector{UInt8})
    ref = Base.cconvert(Ptr, v)
    return VecWriter(unsafe_from_parts(ref, length(v)))
end

function get_buffer(x::VecWriter)
    vec = x.vec
    return @inbounds MemoryView(get_memory(vec))[first_unused_memindex(vec):end]
end

# Note: memoryrefoffset is 1-based despite the name
first_unused_memindex(v::ByteVector) = (length(v) + memindex(v.ref))

unused_space(v::ByteVector) = length(get_memory(v)) - first_unused_memindex(v) + 1

capacity(v::ByteVector) = length(get_memory(v)) - memindex(v.ref) + 1

"""
    get_nonempty_buffer(
        io::AbstractBufWriter, min_size::Int
    )::Union{Nothing, MutableMemoryView{UInt8}}

Get a buffer of at least size `max(min_size, 1)`, or `nothing` if that is
not possible.

This method is optionally implemented for subtypes of `AbstractBufWriter`,
and is typically only implemented for types which do not flush their data to an
underlying IO, such that there is no memory savings by writing in smaller
chunks.

!!! warning
    Use of this method may cause excessive buffering without flushing,
    which is less memory efficient than calling the one-argument method
    and flushing in a loop.

# Examples
```jldoctest
julia> function write_int_le(writer::AbstractBufWriter, int::Int64)
           buf = get_nonempty_buffer(writer, sizeof(Int64))::Union{Nothing, MutableMemoryView{UInt8}}
           isnothing(buf) && throw(IOError(IOErrorKinds.BufferTooShort))
           length(buf) < sizeof(Int64) && error("Bad implementation of get_nonempty_buffer")
           GC.@preserve buf unsafe_store!(Ptr{Int64}(pointer(buf)), htol(int))
           @inbounds consume(writer, sizeof(Int64))
           return sizeof(Int64)
       end;

julia> v = VecWriter(); write_int_le(v, Int64(515))
8

julia> String(v.vec)
"\\x03\\x02\\0\\0\\0\\0\\0\\0"
```
"""
function get_nonempty_buffer(x::VecWriter, min_size::Int)
    ensure_unused_space!(x.vec, max(min_size, 1) % UInt)
    mem = get_memory(x.vec)
    fst = first_unused_memindex(x.vec)
    memref = @inbounds memoryref(mem, fst)
    len = length(mem) - fst + 1
    return MemoryViews.unsafe_from_parts(memref, len)
end

get_nonempty_buffer(x::VecWriter) = get_nonempty_buffer(x, 1)

get_unflushed(x::VecWriter) = MemoryView(x.vec)

function consume(x::VecWriter, n::Int)
    vec = x.vec
    @boundscheck begin
        # Casting to unsigned handles negative n
        (n % UInt) > (unused_space(vec) % UInt) && throw(IOError(IOErrorKinds.ConsumeBufferError))
    end
    veclen = length(vec)
    vec.len = veclen + n
    return nothing
end

function grow_buffer(io::VecWriter)
    initial_capacity = capacity(io.vec)
    @inline add_space_with_overallocation!(io.vec, UInt(1))
    return capacity(io.vec) - initial_capacity
end

Base.close(::VecWriter) = nothing
Base.flush(::VecWriter) = nothing

if isdefined(Base, :takestring!)
    Base.takestring!(io::VecWriter) = _takestring!(io.vec)
    Base.takestring!(v::ByteVector) = _takestring!(v)
else
    takestring!(io::VecWriter) = _takestring!(io.vec)
    takestring!(v::ByteVector) = _takestring!(v)
end

## Optimised write implementations
Base.write(io::VecWriter, x::UInt8) = (push!(io.vec, x); 1)

function Base.unsafe_write(io::VecWriter, ptr::Ptr{UInt8}, n_bytes::UInt)
    iszero(n_bytes) && return 0
    buffer = get_nonempty_buffer(io, n_bytes % Int)
    GC.@preserve buffer unsafe_copyto!(pointer(buffer), ptr, n_bytes)
    @inbounds consume(io, n_bytes % Int)
    return n_bytes % Int
end

function Base.write(io::VecWriter, x::PlainTypes)
    buffer = get_nonempty_buffer(io, sizeof(x))
    GC.@preserve buffer begin
        p = Ptr{typeof(x)}(pointer(buffer))
        unsafe_store!(p, x)
    end
    @inbounds consume(io, sizeof(x))
    return sizeof(x)
end
