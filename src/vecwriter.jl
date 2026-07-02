"""
    ByteVector <: DenseVector{UInt8}

Alias of `Vector{UInt8}`.
"""
const ByteVector = Vector{UInt8}

@static if VERSION ≥ v"1.12.0-DEV.966"
    get_memory(v::Vector{UInt8}) = parent(Base.cconvert(Ptr, v))
else
    get_memory(v::Vector{UInt8}) = v.ref.mem
end

@static if VERSION ≥ v"1.13.0-DEV.1289"
    memindex(x::MemoryRef) = Base.memoryindex(x)
else
    memindex(x::MemoryRef) = Core.memoryrefoffset(x)
end

# If C = Current capacity (get_unflushed + get_buffer)
# Then makes sure new capacity is overallocation(C + additional).
# Do this by zeroing offset and, if necessary, reallocating memory
function add_space_with_overallocation!(vec::Vector{UInt8}, additional::UInt)
    current_mem = get_memory(vec)
    new_size = overallocation_size(capacity(vec) % UInt + additional)
    new_mem = if length(current_mem) ≥ new_size
        current_mem
    else
        Memory{UInt8}(undef, new_size)
    end
    @inbounds copyto!(@inbounds(MemoryView(new_mem)[1:length(vec)]), MemoryView(vec))
    setfield!(vec, :ref, memoryref(new_mem))
    return nothing
end

# Ensure unused space is at least `space` bytes. Will overallocate
function ensure_unused_space!(v::Vector{UInt8}, space::UInt)
    us = unused_space(v) % UInt
    us ≥ space && return nothing
    space_to_add = space - us
    return @noinline add_space_with_overallocation!(v, space_to_add)
end


"""
    VecWriter <: AbstractBufWriter

A writer backed by a [`Vector{UInt8}`](@ref).
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
* `VecWriter(undef, ::Int)`
* `VecWriter(::Vector{UInt8})`

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
    vec::Vector{UInt8}

    VecWriter(v::Vector{UInt8}) = new(v)
end

const DEFAULT_VECWRITER_SIZE = 32

VecWriter() = VecWriter(undef, DEFAULT_VECWRITER_SIZE)

function VecWriter(::UndefInitializer, len::Int)
    return VecWriter(empty!(Vector{UInt8}(undef, len)))
end

function get_buffer(x::VecWriter)
    vec = x.vec
    return @inbounds MemoryView(get_memory(vec))[first_unused_memindex(vec):end]
end

first_unused_memindex(v::Vector{UInt8}) = (length(v) + memindex(v.ref))

unused_space(v::Vector{UInt8}) = length(get_memory(v)) - first_unused_memindex(v) + 1

capacity(v::Vector{UInt8}) = length(get_memory(v)) - memindex(v.ref) + 1

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
    setfield!(vec, :size, (veclen + n,))
    return nothing
end

function grow_buffer(io::VecWriter)
    initial_capacity = capacity(io.vec)
    @inline add_space_with_overallocation!(io.vec, UInt(1))
    return capacity(io.vec) - initial_capacity
end

Base.close(::VecWriter) = nothing
Base.flush(::VecWriter) = nothing

## Optimised write implementations
Base.write(io::VecWriter, x::UInt8) = (push!(io.vec, x); 1)

function Base.unsafe_write(io::VecWriter, ptr::Ptr{UInt8}, n_bytes::UInt)
    iszero(n_bytes) && return 0
    buffer = get_nonempty_buffer(io, n_bytes % Int)
    GC.@preserve buffer unsafe_copyto!(pointer(buffer), ptr, n_bytes)
    @inbounds consume(io, n_bytes % Int)
    return n_bytes % Int
end

@static if VERSION ≥ v"1.13.0-DEV.611"
    Base.takestring!(io::VecWriter) = String(io.vec)
else
    takestring!(io::VecWriter) = String(io.vec)
end
