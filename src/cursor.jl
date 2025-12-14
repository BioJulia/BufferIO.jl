"""
    CursorReader(x) <: AbstractBufReader

A seekable, stateful reader of the content of any object `x` which implements
`MemoryView(x)::MemoryView{UInt8}`.

Closing it does nothing.

```jldoctest
julia> rdr = CursorReader("some\\ncontent\\nhere");

julia> readline(rdr)
"some"

julia> read(rdr, String)
"content\\nhere"

julia> seek(rdr, 8);

julia> read(rdr, String)
"tent\\nhere"
```
"""
mutable struct CursorReader <: AbstractBufReader
    data::ImmutableMemoryView{UInt8}
    offset::Int # always in 0:length(data)

    function CursorReader(x)
        mem = ImmutableMemoryView{UInt8}(x)::ImmutableMemoryView{UInt8}
        return new(mem, 0)
    end
end

fill_buffer(::CursorReader) = 0

get_buffer(x::CursorReader) = @inbounds x.data[(x.offset + 1):end]

"""
    Base.position(io::AbstractBufReader)::Int

Get the zero-based stream position.

If the stream position is `p` (zero-based), then the next byte read will be byte
number `p + 1` (one-based).
The value of `position` must be in `0:filesize(io)`, if `filesize` is defined.

# Examples
```jldoctest
julia> reader = CursorReader("abcdefghij");

julia> position(reader) # zero-indexed
0

julia> read(reader, 3) |> String
"abc"

julia> position(reader)
3

julia> read(reader, 2) |> String
"de"

julia> position(reader)
5

julia> seekstart(reader); position(reader)
0
```
"""
Base.position(x::CursorReader) = x.offset

"""
    filesize(io::AbstractBufReader)::Int

Get the total size, in bytes, which can be read by `io`, and the span in which
`io` can be seeked. Types implementing `filesize` should also implement `seek`.

The filesize does not depend on the current reading state of the `io`, i.e.
reading bytes should not change the filesize.
"""
Base.filesize(x::CursorReader) = length(x.data)

function consume(x::CursorReader, n::Int)
    @boundscheck if (n % UInt) > (length(x.data) - x.offset) % UInt
        throw(IOError(IOErrorKinds.ConsumeBufferError))
    end
    x.offset += n
    return nothing
end

Base.close(::CursorReader) = nothing

function Base.seek(x::CursorReader, offset::Integer)
    offset = Int(offset)::Int
    in(offset, 0:filesize(x)) || throw(IOError(IOErrorKinds.BadSeek))
    x.offset = offset
    return x
end

"""
    relative_seek(io::AbstractBufReader, delta::Int) -> io

Seek the stream by `delta` relative to the current position.
Seeking by a positive delta will advance the stream, and a negative
delta rewinds the stream. When delta is zero, the stream is unchanged.

Seeking beyond either end of the stream will throw an `IOError` of kind `BadSeek`.

This method can be faster than `seek`, because it does not require
`io` to query its absolute position, and therefore, in certain circumstances,
the seeking can occur purely in-memory without interacting with the underlying IO.
"""
relative_seek(x::CursorReader, delta::Int) = seek(x, delta + x.offset)

read_all!(io::CursorReader, dst::MutableMemoryView{UInt8}) = read_into!(io, dst)
