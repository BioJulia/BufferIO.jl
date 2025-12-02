struct LineViewIterator{T <: AbstractBufReader}
    reader::T
    chomp::Bool
end

"""
    line_views(x::AbstractBufReader; chomp::Bool=true)

Create an efficient iterator of lines of `x`.
The returned views are `ImmutableMemoryView{UInt8}` views into `x`'s buffer, 
and are invalidated when `x` is mutated or the line iterator is advanced.

When iterating the iterator, `x` is not advanced on the first call to `iterate`.
Subsequent calls will advance `x` to get the next line, thus invalidating the
previous line view.

A line is defined as all data up to and
including `\\n` (0x0a) or `\\r\\n` (0x0d 0x0a), or the remainder of the data in `io` if
no `\\n` byte was found.
If the input is empty, this iterator is also empty.

The lines are iterated as `ImmutableMemoryView{UInt8}`. Use the package StringViews.jl
to turn them into `AbstractString`s. The `chomp` keyword (default: true), controls whether
any trailing `\\r\\n` or `\\n` should be removed from the output.

If `x` had a limited buffer size, and an entire line cannot be kept in the buffer, an
`ArgumentError` is thrown.

The resulting iterator will NOT close `x` when done, this must be handled by the caller.

# Examples
```jldoctest
julia> lines = line_views(CursorReader("abc\\r\\ndef\\n\\r\\ngh"));

julia> (line, state) = iterate(lines); String(line)
"abc"

julia> println(first(lines)) # not advanced until 2-arg iterate call
UInt8[0x61, 0x62, 0x63]

julia> iterate(lines, state) |> first |> String # advance to "def"
"def"

julia> line = nothing # `line` is now invalidated

julia> sum(length, lines) # "def" + "" + "gh"
5
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
        throw(ArgumentError("Could not buffer a whole line!"))
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
