## Example uses of BufferIO

Most applications of `BufferIO` use basic read/write operations, where there is little difference between BufferIO
and `Base.IO`, apart from somewhat more precise semantics in the former.

The examples below highlight situations where BufferIO's semantics enable behaviour that is difficult to achieve with `Base.IO`.
The enabling semantics are typically that data can be read directly from the IO's buffer, without having to copy the data
out of the IO or advance the IO.

### BufferIO in the wild
At the time of writing, BufferIO is a brand-new package with limited usage in the Julia ecosystem.

So far, the users of BufferIO are:

* [BGZFLib.jl](https://github.com/BioJulia/BGZFLib.jl)
* [PairwiseMappingFormat.jl](https://github.com/BioJulia/PairwiseMappingFormat.jl)

### Reader examples
#### Reading a decimal number
Suppose we are reading a tab-delimited field consisting of a non-negative decimal number.
The following code has properties that are hard to achieve with Base code:
* Non-allocating on Julia 1.14 and above
* Non-throwing on EOF, which is an expected condition, unlike e.g. permission-denied errors
* Does not advance `io` if the data is unexpectedly malformed, allowing recovery

For the sake of the example, this function uses a `BufReader`, but it could use another
`AbstractBufReader`. To use a generic `AbstractBufReader`, the function would have to handle
the case where the buffer is shorter than the field length. This is possible, but requires some boilerplate
not relevant here.

```julia
function try_read_number_field(io::BufReader)
    buffer = buffer_until(io, UInt8('\t'))
    isempty(buffer) && return EOFError()
    has_tab = buffer[end] == UInt8('\t')
    buffer = @inbounds buffer[1:end-has_tab]
    isempty(buffer) && return nothing
    all(b -> in(b, 0x30:0x39), buffer) || return nothing
    # TODO: We don't handle overflow here, for simplicity's sake
    number = foldl((acc, byte) -> 10 * acc + (byte - 0x30), buffer; init=0)
    consume(io, length(buffer) + has_tab)
    return number
end
```

#### State machine
The package Automa.jl generates regex-based state machines that operate on byte arrays, e.g. for parsing.
Suppose we have an Automa-generated function `try_parse_chunk`,
which parses a 1024-byte chunk according to some complicated rule.
With `Base.IO`, you would normally have to copy the data into a `Vector{UInt8}` and run the state machine
on the vector. On error, the stream would then have to be rewound.

With BufferIO, you can read the data directly from the `io` itself:

```julia
function try_read_chunk(io::BufReader)
    buffer = @something get_nonempty_buffer(io, 1024) return nothing # EOF
    buffer = buffer[1:1024]
    chunk = @something try_parse_chunk(buffer) return nothing # Bad parse
    consume(io, 1024)
    return chunk
end
```

### Writer examples
Similar to the buffered readers, `AbstractBufWriter`s typically have an advantage over `Base.IO` types when it is useful
to write directly into the writer's buffer.

#### Efficiently storing a custom bitstype
This example shows how to efficiently write a custom bitstype into a `BufWriter`.
This method writes the struct directly into the writer. With `Base.IO`, you would have to
allocate an intermediate object that can be written as bytes, e.g. a `Ref`, which may or may not be optimized away.

Similar code can also work generically for `AbstractBufWriter`, but generic code will
have to handle the situation where the buffer is not growable and smaller than the struct size.
Since the buffer of `BufWriter` is growable, we don't need to handle that case here.

```julia
struct MyStruct
    a::UInt32
    b::Float32
end

function write_struct(io::BufWriter, x::MyStruct)
    sz = sizeof(x)
    buffer = get_nonempty_buffer(io, sz)
    GC.@preserve buffer unsafe_store!(Ptr{MyStruct}(pointer(buffer)), x)
    consume(io, sz)
    return sz
end
```

#### String building
Base Julia uses `IOBuffer` for string building. This package's `VecWriter` is generally faster.

```julia
function name_to_tab_sep_string(fst::StringView, lst::StringView)::String
    # Preallocate exact size for performance
    v = VecWriter(undef, ncodeunits(fst) + ncodeunits(lst) + 1)
    write(v, fst)
    write(v, UInt8('\t'))
    write(v, lst)
    takestring!(v)
end
```
