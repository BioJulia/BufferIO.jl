module StringViewsExt

using BufferIO: AbstractBufWriter, LineWriter
using StringViews: StringView

# On Julia ≥ 1.14.0-DEV.2029, `StringView` is defined in Base, and StringViews.jl
# re-exports it, so these methods are instead defined in BufferIO itself.
@static if VERSION < v"1.14.0-DEV.2029"
    Base.write(io::AbstractBufWriter, s::StringView) = write(io, codeunits(s))

    # Resolves a method ambiguity between StringViews' `write(::IO, ...)` method and
    # `write(::LineWriter, ::AbstractString)`. See the corresponding method in src/linewriter.jl.
    function Base.write(io::LineWriter, s::Union{StringView, SubString{<:StringView}})
        return write(io, codeunits(s))
    end
end

end # module
