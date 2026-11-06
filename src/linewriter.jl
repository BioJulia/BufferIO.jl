# This must carry no mutable state to be a transparent wrapper around its inner, which is what
# allows not taking ownership of inner.
# We also don't have LineWriter <: AbstractBufWriter, because its automatic flushing breaks
# the expected semantics of get_buffer / consume / grow_buffer. Specifically, it would require
# flushing on `consume`, which is not permitted by the AbstractBufWriter semantics.
"""
    LineWriter{T <: AbstractBufWriter} <: IO

An `io::LineWriter` wraps an inner `AbstractBufWriter` in an `IO`, and flushes
when a newline is written to `io`.

`LineWriter`s are useful for streams like stdout, stderr or log files, where you may
want automatic flushing every time a log line has been written.
Newlines are defined as `0x0a` bytes, even when part of binary data (e.g. a `UInt32`).
When a single `write` call has multiple newlines,
`LineWriter` may only flush at the last newline in the `write`, not on every newline.
`LineWriter` may additionally flush on non-newlines, as controlled by the inner `AbstractBufWriter`.

`LineWriter` does **not** take control of the inner writer. The inner writer can be obtained
with the public property `.inner`, and may be mutated by the user without this invalidating
the `LineWriter`.

# Examples
```jldoctest
julia> (path, io) = mktemp();

julia> writer = LineWriter(BufWriter(io));

julia> write(writer, "abc\\ndef\\nghi")
11

julia> read(path, String)
"abc\\ndef\\n"

julia> close(writer.inner) # same as `close(writer)`
```
"""
struct LineWriter{T <: AbstractBufWriter} <: IO
    inner::T
end

# Users can also just operate on the inner, but we might as well
# provide forwarders, for convenience
for f in Any[:close, :isopen, :flush, :filesize, :position]
    @eval Base.$(f)(io::LineWriter) = $(f)(io.inner)
end

# Return `io`, not its inner writer, since writes to the latter are not line flushed
Base.seek(io::LineWriter, p::Integer) = (seek(io.inner, p); io)
Base.seekend(io::LineWriter) = (seekend(io.inner); io)

function Base.unsafe_write(io::LineWriter, ptr::Ptr{UInt8}, n_bytes::Integer)
    return unsafe_write(io, ptr, UInt(n_bytes)::UInt)
end

function Base.unsafe_write(io::LineWriter, ptr::Ptr{UInt8}, n_bytes::UInt)
    # Search for last newline in chunk; flush after that newline
    m = @ccall memrchr(ptr::Ptr{Cvoid}, 0x0a::Cint, n_bytes::Csize_t)::Ptr{Cvoid}
    before_flush = m == C_NULL ? n_bytes : m - ptr + UInt(1)
    unsafe_write(io.inner, ptr, before_flush)
    # Only flush if we actually found a newline
    m == C_NULL || flush(io.inner)
    # This is zero if we didn't find a newline, so the write call below
    # will be skipped
    rest = n_bytes - before_flush
    iszero(rest) || unsafe_write(io.inner, Ptr{UInt8}(m) + 1, rest)
    return n_bytes % Int
end

# Base's fallback writes strings char by char, which is slow. Converting to `String` is
# typically fast.
Base.write(io::LineWriter, s::AbstractString) = write(io, String(s)::String)

# These resolve method ambiguities between the method above and Base's more specific
# `write(::IO, ...)` methods. Base's methods must be used instead of converting to `String`:
# They eventually call `unsafe_write(::LineWriter, ...)`, so they are correctly line flushed,
# but `StringView` avoids a copy, and `AnnotatedString` may be written with its styling.
# Base added this `AnnotatedString` method in 1.13.0-DEV.428, backported to 1.12.0-beta2.
# Julia 1.11 has the type but not the method, so there is no ambiguity to resolve.
@static if VERSION ≥ v"1.12.0-beta2"
    function Base.write(io::LineWriter, s::Union{Base.AnnotatedString, SubString{<:Base.AnnotatedString}})
        return invoke(write, Tuple{IO, typeof(s)}, io, s)::Int
    end
end

@static if VERSION ≥ v"1.14.0-DEV.2029"
    function Base.write(io::LineWriter, s::Union{Base.StringView, SubString{<:Base.StringView}})
        return invoke(write, Tuple{IO, typeof(s)}, io, s)::Int
    end
end

function Base.write(io::LineWriter, s::Union{String, SubString{String}})
    return GC.@preserve s unsafe_write(io, pointer(s), ncodeunits(s) % UInt)
end

function Base.write(io::LineWriter, byte::UInt8)
    write(io.inner, byte)
    byte == 0x0a && flush(io.inner)
    return 1
end
