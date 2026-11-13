################################
# Internals of Vector{UInt8}
################################
# VecWriter writes directly into the unused memory after the last element of its
# `Vector{UInt8}`, and then extends the vector's length to cover the written bytes.
# Base has no public API for this, so this section relies on implementation details
# of `Vector`. All such use is confined to this section: Outside it, vectors are only
# accessed through public Base API, or through the functions defined here.

# Fail loudly at load time if Julia changes the layout of `Vector`,
# instead of silently corrupting memory.
if fieldnames(Vector{UInt8}) != (:ref, :size) ||
        fieldtypes(Vector{UInt8}) != (MemoryRef{UInt8}, Tuple{Int})
    error("BufferIO does not support this Julia version, because the layout of `Vector` changed")
end

@static if VERSION ≥ v"1.12.0-DEV.966"
    get_memory(ref::MemoryRef{UInt8}) = parent(ref)
else
    get_memory(ref::MemoryRef{UInt8}) = ref.mem
end

# One-based index of `ref` into its memory
@static if VERSION ≥ v"1.13.0-DEV.1289"
    memindex(ref::MemoryRef{UInt8}) = Base.memoryindex(ref)
else
    memindex(ref::MemoryRef{UInt8}) = Core.memoryrefoffset(ref)
end

# The vector's elements are stored in `get_memory(ref)`, starting at `memindex(ref)`
memory_ref(v::Vector{UInt8}) = getfield(v, :ref)

# Make `v` use `mem` as its memory, starting at the first element of `mem`.
# The elements of `v` are not copied.
# Callers must ensure `length(v) ≤ length(mem)`.
function unsafe_set_memory!(v::Vector{UInt8}, mem::Memory{UInt8})
    setfield!(v, :ref, memoryref(mem))
    return nothing
end

# Set the length of `v` without initializing or reallocating memory.
# Callers must ensure `n` is in `0:(length(v) + unused_space(v))`.
unsafe_set_length!(v::Vector{UInt8}, n::Int) = setfield!(v, :size, (n,))

# Memory owned by a `String`, such that `String(v)` of a vector using the memory can take
# ownership of the memory instead of copying it. Base keeps this property when the vector
# grows, but only if the memory is nonempty: Empty string memory is Base's shared empty
# memory, which is not owned by a string.
string_memory(len::Int) = Base.StringMemory(len)
string_vector(len::Int) = Base.StringVector(len)

################################

get_memory(v::Vector{UInt8}) = get_memory(memory_ref(v))

first_unused_memindex(v::Vector{UInt8}) = memindex(memory_ref(v)) + length(v)

unused_space(v::Vector{UInt8}) = length(get_memory(v)) - first_unused_memindex(v) + 1

# Ensure unused space is at least `space` bytes. Will overallocate
function ensure_unused_space!(v::Vector{UInt8}, space::UInt)
    unused_space(v) % UInt ≥ space && return nothing
    return @noinline add_unused_space!(v, space)
end

# N.B: `sizehint!` is not used, since it does not guarantee unused space
# if the vector has a nonzero offset into its memory.
function add_unused_space!(v::Vector{UInt8}, space::UInt)
    # Base would grow empty memory into memory not owned by a string, so `String(v)`
    # would copy. Allocate string memory instead. This lets vectors, and therefore
    # `VecWriter()`, start without allocating memory.
    if isempty(get_memory(v))
        unsafe_set_memory!(v, string_memory(max(space, DEFAULT_VECWRITER_SIZE % UInt) % Int))
        return nothing
    end
    len = length(v)
    # Growing reallocates (with overallocation), or moves the elements to the start of the memory
    resize!(v, len + space)
    unsafe_set_length!(v, len)
    return nothing
end

Base.@deprecate_binding ByteVector Vector{UInt8}

"""
    VecWriter <: AbstractBufWriter

A writer that appends to a `Vector{UInt8}`, which is stored in the (public)
property `.vec`.

This type is useful as an efficient string builder through `takestring!(io)`.

Functions `flush` and `close` do not affect the writer.

Mutating `io` will mutate `vec` and vice versa. Neither `vec` nor `io` will
be invalidated by mutating the other, but doing so may affect the
implicit (non-semantic) behaviour (e.g. memory reallocations or efficiency) of the other.
Mutating `vec` invalidates buffers previously obtained from `io` with e.g. `get_buffer`.

Create with one of the following constructors:
* `VecWriter()`: Create an empty vector.
* `VecWriter(undef, n::Int)`: Create an empty vector with space for at least `n` bytes
* `VecWriter(vec::Vector{UInt8})`: Append to `vec`, which is not copied.

A VecWriter has no notion of `filesize`, and cannot be `seek`ed. Instead, resize
the underlying vector `io.vec`.

```jldoctest
julia> vw = VecWriter();

julia> write(vw, "Hello, world!")
13

julia> append!(vw.vec, b" More data");

julia> takestring!(vw)
"Hello, world! More data"

julia> v = collect(b"abc");

julia> write(VecWriter(v), "def");

julia> String(v)
"abcdef"
```
"""
struct VecWriter <: AbstractBufWriter
    vec::Vector{UInt8}

    VecWriter(v::Vector{UInt8}) = new(v)
end

# Number of bytes allocated when a `VecWriter` with no memory is first written to
const DEFAULT_VECWRITER_SIZE = 32

VecWriter() = VecWriter(UInt8[])

function VecWriter(::UndefInitializer, len::Int)
    return VecWriter(empty!(string_vector(len)))
end

function get_buffer(x::VecWriter)
    vec = x.vec
    return @inbounds MemoryView(get_memory(vec))[first_unused_memindex(vec):end]
end

function get_nonempty_buffer(x::VecWriter, min_size::Int)
    ensure_unused_space!(x.vec, max(min_size, 1) % UInt)
    return get_buffer(x)
end

get_nonempty_buffer(x::VecWriter) = get_nonempty_buffer(x, 1)

get_unflushed(x::VecWriter) = MemoryView(x.vec)

function consume(x::VecWriter, n::Int)
    vec = x.vec
    @boundscheck begin
        # Casting to unsigned handles negative n
        (n % UInt) > (unused_space(vec) % UInt) && throw(IOError(IOErrorKinds.ConsumeBufferError))
    end
    unsafe_set_length!(vec, length(vec) + n)
    return nothing
end

function grow_buffer(io::VecWriter)
    initial_space = unused_space(io.vec)
    add_unused_space!(io.vec, (initial_space + 1) % UInt)
    return unused_space(io.vec) - initial_space
end

Base.close(::VecWriter) = nothing
Base.isopen(::VecWriter) = true
Base.flush(::VecWriter) = nothing

## Optimised write implementations
# Not `push!`, since Base would grow empty memory into memory not owned by a string
function Base.write(io::VecWriter, x::UInt8)
    vec = io.vec
    ensure_unused_space!(vec, UInt(1))
    len = length(vec) + 1
    unsafe_set_length!(vec, len)
    @inbounds vec[len] = x
    return 1
end

function Base.unsafe_write(io::VecWriter, ptr::Ptr{UInt8}, n_bytes::UInt)
    iszero(n_bytes) && return 0
    buffer = get_nonempty_buffer(io, n_bytes % Int)
    GC.@preserve buffer unsafe_copyto!(pointer(buffer), ptr, n_bytes)
    @inbounds consume(io, n_bytes % Int)
    return n_bytes % Int
end

@static if VERSION ≥ v"1.13.0-DEV.611"
    Base.takestring!(io::VecWriter) = takestring!(io.vec)
else
    takestring!(io::VecWriter) = String(io.vec)
    # Base defines this method from Julia 1.13
    takestring!(v::Vector{UInt8}) = String(v)
end

"""
    take!(io::VecWriter)::MutableMemoryView{UInt8}

Return the previous written ([`consume`](@ref)d) bytes without copying.
Leave `io` empty, and backed by a different `Memory`.

# Examples
```jldoctest
julia> io = VecWriter();

julia> write(io, "Hello, world!")
13

julia> v = take!(io); v == b"Hello, world!"
true

julia> write(io, "Other data")
10

julia> v == b"Hello, world!" # unchanged
true
```
"""
function Base.take!(io::VecWriter)
    result = get_unflushed(io)
    unsafe_set_length!(io.vec, 0)
    unsafe_set_memory!(io.vec, Memory{UInt8}())
    return result
end
