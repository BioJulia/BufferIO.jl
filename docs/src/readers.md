```@meta
CurrentModule = BufferIO
DocTestSetup = quote
    using BufferIO
end
```

# `AbstractBufReader`
## Core, low-level interface
The core interface of an `io::AbstractBufReader` consists of three functions, that are to be used together:
* `get_buffer(io)` returns a view into the internal buffer with data ready to read. You read from the io by copying.
* `fill_buffer(io)` attempts to append more bytes to the buffer returned by future calls to `get_buffer`
* `consume(io, n::Int)` removes the first `n` bytes of the buffer from future buffers returned by `get_buffer`

While lots of higher-level convenience functions are also defined, nearly all functionality is defined in terms of these three core functions.
See the docstrings of these functions for details and edge cases.

Let's see two use cases to demonstrate how this core interface is used.

### Example: Reading N bytes
Suppose we want a function `read_exact(io::AbstractBufReader, n::Int)` which reads exactly `n` bytes to a new `Vector{UInt8}`, unless `io` hits end-of-file (EOF).

This functionality is already implemented as `read(::AbstractBufReader, ::Integer)`, so the below implementation is for illustration purposes.

Since `io` itself controls how many bytes are filled with `fill_buffer` (typically whatever is the most efficient), we do this best by calling the functions above in a loop:

```julia
function read_exact(io::AbstractBufReader, n::Int)
    n > -1 || throw(ArgumentError("n must be non-negative"))
    result = sizehint!(UInt8[], n)
    remaining = n
    while !iszero(remaining)
        # Get the buffer to copy bytes from in order to read from `io`
        buffer = get_buffer(io)
        if isempty(buffer)
            # Fill new bytes into the buffer. This returns `0` if `io` if EOF,
            # in which case we break to return the result.
            # `fill_buffer` can return `nothing` for some reader types, but only if
            # the buffer is not empty.
            iszero(something(fill_buffer(io))) && break
            buffer = get_buffer(io)
        end
        mn = min(remaining, length(buffer))
        append!(result, buffer[1:mn])
        # Signal to `io` that the first `mn` bytes have already been read,
        # so these should not be output in future calls to `get_buffer`
        consume(io, mn)
        remaining -= mn
    end
    return result
end
```

The code above may be simplified by using the convenience function [`get_nonempty_buffer`](@ref)
or by simply calling the already-implemented `read(io, n)`.

### Example: Reading a line without intermediate allocations
In this example, we want to buffer a full line in `io`'s buffer, and then return a view into the buffer
representing that line.

This function is an unusual use case, because we need to ensure the buffer is able to hold a full line.
For most IO operations, we do not need, nor want to control exactly how much is buffered by `io`,
since leaving that up to `io` is typically more efficient.

Therefore, this is one of the rare cases where we may need to force `io` to grow its buffer.

```julia
function get_line_view(io::AbstractBufReader)
    # Which position to search for a newline from
    scan_from = 1
    while true
        buffer = get_buffer(io)
        pos = findnext(==(UInt8('\n')), buffer, scan_from)
        if pos === nothing
            scan_from = length(buffer) + 1
            n_filled = fill_buffer(io)
            if n_filled === nothing
                # fill_buffer may return nothing if the buffer is not empty,
                # and the buffer cannot be expanded further.
                error("io could not buffer an entire line")
            elseif iszero(n_filled)
                # This indicates EOF, so the line is defined as the rest of the
                # content of `io`
                return buffer
            end
        else
            return buffer[1:pos]
        end
    end
end
```

Functionality similar to the above is provided by the [`line_views`](@ref) iterator.

### Wrapping a `Base.IO`
[`BufReader`](@ref) gives any `Base.IO` the `AbstractBufReader` interface.
The wrapped io must implement `eof`, and — unless it is one of the
internally-buffered IO types like `IOBuffer` or `IOStream` — a method of
`Base.readbytes!` for `MutableMemoryView{UInt8}` destinations that performs a
single, short read.
See the extended help of [`BufReader`](@ref) for the precise contract.

```@docs; canonical=false
get_buffer
fill_buffer
consume
```

## Notable `AbstractReader` functions
`AbstractBufReader` implements most of the `Base.IO` interface, see the section in the sidebar.
They also have a few special convenience functions:

```@docs; canonical=false
get_nonempty_buffer(::AbstractBufReader)
read_into!
read_all!
```
