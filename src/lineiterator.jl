"""
    LineViewIterator{T <: AbstractBufReader}

This iterator is created by [`line_views(::AbstractBufReader)`](@ref).
It is public, but is currently unexported.

It has two public properties: `io.reader` obtains its inner `AbstractBufReader`, and
`io.chomp::Bool` returns whether this iterator strips line endings.

For semantics of iteration, see documentation of [`line_views(::AbstractBufReader)`](@ref).
"""
struct LineViewIterator{T <: AbstractBufReader}
    reader::T
    chomp::Bool
end

"""
    line_views(x::AbstractBufReader; chomp::Bool=true)::LineViewIterator{typeof(x)}

Create an iterator of lines of `x`.
The returned views are `ImmutableMemoryView{UInt8}` into `x`'s buffer.
Use the package StringViews.jl to turn the lines into `AbstractString`s.

The views may be invalidated when mutating `x`, which may happen on subsequent iterations
of the iterator. See extended help for more precise semantics.

The `chomp` keyword (default: `true`), controls whether
any trailing `\\r\\n` or `\\n` bytes should be removed from the output.

# Examples
```jldoctest
julia> lines = line_views(CursorReader("abc\\r\\ndef\\n\\r\\ngh"));

julia> first(lines) |> String
"abc"

julia> first(lines) == b"abc"
true

julia> first(iterate(lines, 9)) |> String
""

julia> sum(length, lines)
2

julia> isempty(lines)
true
```

# Extended help
A line is defined as all data up to and including `\\n` (0x0a) or `\\r\\n` (0x0d 0x0a),
or the remainder of the data in `io` if no `\\n` byte was found.
If the input is empty, this iterator is also empty.

If `x` had a limited buffer size, and cannot grow its buffer,
and an entire line cannot be kept in the buffer, an `ArgumentError` is thrown.

The resulting iterator will NOT close `x` when exhausted, this must be handled elsewhere.

### Iterator state and io advancement
The resulting iterator `itr::LineViewIterator`'s state is guaranteed, public interface:

* `iterate(itr)` is equivalent to `iterate(itr, 0)`
* `iterate(itr, n::Int)` is equivalent to `consume(x, n); iterate(itr)`
* The state returned by `iterate` is an `Int` equal to the length of the line
  emitted, plus the number of stripped `\\r\\n` or `\\n` bytes, if `chomp`.

These semantics together mean that a normal for-loop will exhaust the underlying io,
and that no emitted line will be invalidated before the next call to `iterate`.

As an example, to read two lines, one may do:
```julia
# Read first line, and do something  with it
(line_1, s) = iterate(itr);    x = process(line_1)
# Two argument iterate advances itr to the begining of next line.
(line_2, s) = iterate(itr, s); y = process(line_2)
# Advance iterator from second line to third line
consume(itr.reader, s) # .reader is a public property
```
"""
function line_views(x::AbstractBufReader; chomp::Bool = true)
    return LineViewIterator{typeof(x)}(x, chomp)
end

Base.eltype(::Type{<:LineViewIterator}) = ImmutableMemoryView{UInt8}
Base.IteratorSize(::Type{<:LineViewIterator}) = Base.SizeUnknown()

function Base.iterate(x::LineViewIterator, state::Int = 0)
    # Consume data from previous line
    state > 0 && consume(x.reader, state)

    pos = buffer_until(x.reader, 0x0a)
    if pos isa HitBufferLimit
        throw(ArgumentError("Buffer too short to buffer a whole line, and cannot be expanded."))
    elseif pos === nothing
        # No more newlines until EOF. Close as we reached EOF
        buffer = get_buffer(x.reader)
        # If no bytes, do not emit
        return isempty(buffer) ? nothing : (buffer, length(buffer))
    else
        buffer = get_buffer(x.reader)
        line_view = buffer[1:pos]
        if x.chomp
            line_view = _chomp(line_view)
        end
        return (line_view, pos)
    end
end

# Fill buffer of `x` until it contains a `byte`, then return the index
# in the buffer of that byte.
# If `x` doesn't contain `byte` until EOF, returned value is nothing.
function buffer_until(x::AbstractBufReader, byte::UInt8)::Union{Int, HitBufferLimit, Nothing}
    scan_from = 1
    buffer = get_nonempty_buffer(x)::Union{Nothing, ImmutableMemoryView{UInt8}}
    isnothing(buffer) && return nothing
    while true
        pos = findnext(==(byte), buffer, scan_from)
        pos === nothing || return pos
        scan_from = length(buffer) + 1
        n_filled = fill_buffer(x)
        if n_filled === nothing
            return HitBufferLimit()
        elseif iszero(n_filled)
            return nothing
        else
            buffer = get_buffer(x)::ImmutableMemoryView{UInt8}
            length(buffer) < scan_from && error("Invalid fill_buffer / get_buffer implementation")
        end
    end
    return # unreachable
end

struct EachLine{T <: AbstractBufReader}
    x::LineViewIterator{T}
end

Base.eltype(::Type{<:EachLine}) = String
Base.IteratorSize(::Type{<:EachLine}) = Base.SizeUnknown()

function Base.iterate(x::EachLine, _::Nothing = nothing)
    it = iterate(x.x)
    isnothing(it) && return nothing
    (view, state) = it
    str = String(view)
    consume(x.x.reader, state)
    return (str, nothing)
end

"""
    eachline(io::AbstractBufReader; keep::Bool = false)

Return an iterator of lines (as `String`) in `io`. A line is defined as all data up to and
including `\\n` (0x0a) or `\\r\\n` (0x0d 0x0a), or the remainder of the data in `io` if
no `\\n` byte was found.
If the input is empty, this iterator is also empty.

If `keep` is `false`, trailing `\\r\\n` or `\\n` are removed from each iterated line.

Unlike `eachline(::IO)`, this method does not close `io` when iteration is done, and does not
yet support `Iterators.reverse` or `last`.

See also: [`line_views`](@ref)
"""
function Base.eachline(x::AbstractBufReader; keep::Bool = false)
    return EachLine{typeof(x)}(line_views(x; chomp = !keep))
end

struct MemLineViewIterator
    mem::ImmutableMemoryView{UInt8}
    chomp::Bool
end

Base.IteratorSize(::Type{MemLineViewIterator}) = Base.SizeUnknown()
Base.eltype(::Type{MemLineViewIterator}) = ImmutableMemoryView{UInt8}

"""
    line_views(x::MemoryView{UInt8}; chomp::Bool=true)

Return a stateless iterator of the lines in `x`.
The returned views are `ImmutableMemoryView{UInt8}` views into `x`.
Use the package StringViews.jl to turn them into `AbstractString`s.

A line is defined as all data up to and
including `\\n` (0x0a) or `\\r\\n` (0x0d 0x0a), or the remainder of the data in `io` if
no `\\n` byte was found.
If the input is empty, this iterator is also empty.

The `chomp` keyword (default: true), controls whether
any trailing `\\r\\n` or `\\n` should be removed from the output.

# Examples
```jldoctest
julia> mem = MemoryView("abc\\r\\ndef\\nab\\n");

julia> foreach(i -> println(repr(String(i))), line_views(mem))
"abc"
"def"
"ab"
```
"""
function line_views(x::MemoryView{UInt8}; chomp::Bool = true)
    return MemLineViewIterator(ImmutableMemoryView(x), chomp)
end

function Base.iterate(x::MemLineViewIterator, state::Int = 0)
    # State is the offset
    mem = x.mem
    state >= length(mem) && return nothing

    newref = @inbounds memoryref(mem.ref, state + 1)
    mem = ImmutableMemoryView(MemoryViews.unsafe_from_parts(newref, length(mem) - state))
    pos = findfirst(==(0x0a), mem)
    if pos === nothing
        return (mem, state + length(mem))
    end
    line = @inbounds mem[1:pos]
    if x.chomp
        line = _chomp(line)
    end
    return (line, state + pos)
end
