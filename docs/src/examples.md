## Example use of BufferIO

### Examples in the wild
At the time of writing, BufferIO is a brand-new package with limited usage in the Julia ecosystem.

So far, the users of BufferIO are:

* [BGZFLib.jl](https://github.com/BioJulia/BGZFLib.jl)

### Reader example
For bulk I/O operations, there is often not much practical difference between `Base.IO` and the BufferIO interfaces - except somewhat more precise semantics of the latter.

Where BufferIO really shines are when you need to read and parse at the same time.
For example, suppose you need to read a non-negative decimal number from an io object. You need to figure out where the number ends, _before_ reading it, lest you read too many bytes.
With a `Base.IO` type, your choices are:
1. Read one byte at a time, which is inefficient
2. Implement your own buffering layer, and load data into the buffer, then read the number from the buffer.

The latter is essentially an ad-hoc implementation of a BufferIO-like interface.
This is what packages like FASTX.jl, XAM.jl and other parsing packages do.

Below is an implementation of how to do it using BufferIO.

```julia
using BufferIO, StringViews, MemoryViews

is_decimal(x::UInt8) = in(x, UInt8('0'):UInt8('9'))

function read_decimal_number(io::AbstractBufReader)::Union{Int, Nothing}
    scan_from = 1
    buffer = get_buffer(io)
    local non_digit_pos
    # Keep expanding buffer until we reach EOF, or find the first non-digit
    while true
        non_digit_pos = findnext(!is_decimal, buffer, scan_from)
        if isnothing(non_digit_pos)
            # Next iteration, do not re-scan the same bytes to find end of number
            scan_from = length(buffer) + 1
            n_filled = fill_buffer(io)
            # `nothing` means buffer could not grow. Many subtypes of `AbstractBufReader`
            # will never return this, in which case this error branch is compiled away
            isnothing(n_filled) && throw(IOError(IOErrorKinds.BufferTooShort))
            # This indicates EOF, so we attempt to parse the rest of the line
            if iszero(n_filled)
                non_digit_pos = lastindex(buffer) + 1
                break
            end
            buffer = get_buffer(io)
            # Check `fill_buffer` was implemented correctly
            @assert length(buffer) ≥ scan_from
        else
            break
        end
    end
    # If no digit was found, do not attempt to parse
    non_digit_pos == 1 && return nothing
    # Rely on existing Base parsing functionality to throw e.g. overflow
    # errors. Since this is validated data of a known type, a custom implementation
    # could be much faster.
    digit = parse(Int, StringView(buffer[1:non_digit_pos - 1]))
    consume(io, non_digit_pos - 1)
    return digit
end
```

### Writer example
Similar to the above example, where BufferIO's principle of _the buffer is the interface_ enabled integrating reading and parsing for a more efficient API, BufferIO's writer shine when you can write data directly into a buffer without any intermediate allocations.

For example, currently, writing a number to an `IOBuffer` allocates. This is because the number is first heap-allocated, and then data from the heap is copied into the io.
In contrast, BufferIO provides the the a buffer to write into directly.

The following method is already implemented in BufferIO, but is useful as an example:

```julia
using BufferIO, MemoryViews

# Constrain the signature to types of a known binary layout which we can copy
# directly using a pointer
const BitInteger = Union{Int, UInt...}

function write(io::AbstractBufWriter, n::BitInteger)
    buffer = get_buffer(io)
    while length(buffer) < sizeof(n)
        n_filled = grow_buffer(io)
        iszero(n_filled) && throw(IOError(IOErrorKinds.BufferTooShort))
        buffer = get_buffer(io)
    end
    GC.@preserve buffer unsafe_store!(Ptr{typeof(n)}(pointer(buffer)), n)
    consume(io, sizeof(n))
    return sizeof(n)
end
```

For types that implement the two-arg method of `get_nonempty_buffer`, the while loop can be omitted,
since all the required buffer space can be reserved immediately:

```julia
# For some hypothetical MyButWriter which implements two-arg `get_nonempty_buffer`
function write(io::MyBufWriter, n::BitInteger)
    buffer = get_nonempty_buffer(io, sizeof(n))
    isnothing(buffer) && throw(IOError(IOErrorKinds.BufferTooShort))
    GC.@preserve buffer unsafe_store!(Ptr{typeof(n)}(pointer(buffer)), n)
    consume(io, sizeof(n))
    return sizeof(n)
end
```