```@meta
CurrentModule = BufferIO
DocTestSetup = quote
    using BufferIO
end
```

# `AbstractBufWriter`
## Core, low-level interface
Similar to `AbstractBufReader`, the core interface of `AbstractBufWriter` consists of three functions:

* `get_buffer(io)` returns a mutable view into the part of the buffer which is not yet used. Data is written to `io` by copying to the first bytes of the buffer, then calling `consume`.
* `grow_buffer(io)` request to expand the buffer returned by future calls to `get_buffer`. This may happen by flushing data in the buffer or by reallocating a larger buffer
* `consume(io, n::Int)` signals that the first `n` bytes in the buffer are written to `io`, and will therefore not be returned from future calls to `get_buffer`.

### Example: Writing `v::Vector{UInt8}` to an `AbstractBufWriter`
The method `write(::AbstractBufWriter, v::Vector{UInt8})` is already implemented, but it's illustrative to see how this be implemented in terms of the core primitives above.

First, let's define it in terms of `ImmutableMemoryView`, and then forward the `Vector` method to the memory one.

```julia
using MemoryViews

# Forward the vector method to a memory view method
my_write(io::AbstractBufWriter, v::Vector{UInt8}) = my_write(io, ImmutableMemoryView(v))

function my_write(io::AbstractBufWriter, mem::ImmutableMemoryView{UInt8})::Int
    n_bytes = length(mem)
    while !isempty(mem)
        # Get mutable buffer with uninitialized data to write to
        buffer = get_buffer(io)::MutableMemoryView{UInt8}
        if isempty(buffer)
            # grow_buffer cannot return `nothing`, unlike for readers, but the writer
            # may still be unable to add more bytes (in which case grow_buffer returns
            # zero). A real implementation would use a better error
            iszero(grow_buffer(io)) && error("Could not flush")
            buffer = get_buffer(io)::MutableMemoryView{UInt8}
        end
        mn = min(length(mem), length(buffer))
        # This would indicate an error in the implementation of `grow_buffer`.
        # As it did not return zero, the buffer must have grown.
        @assert !iszero(mn)
        (to_write, mem) = split_at(mem, mn + 1)
        copyto!(buffer[1:mn], to_write)
        # Mark the first `mn` bytes of the buffer as being committed, thereby
        # actually writing it to `io`
        consume(io, mn)
    end
    return n_bytes
end
```

### Wrapping a `Base.IO`
[`BufWriter`](@ref) gives any `Base.IO` the `AbstractBufWriter` interface.
See the extended help of [`BufWriter`](@ref) for the precise contract.

```@docs; canonical=false
get_buffer
grow_buffer
consume
```

## Notable `AbstractWriter` functions
```@docs; canonical=false
get_unflushed
get_nonempty_buffer(::VecWriter, ::Int)
```