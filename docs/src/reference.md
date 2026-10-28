# Reference
```@autodocs
Modules = [BufferIO]
Private = false
Order   = [:type, :function]
```

```@docs
IOErrorKinds.IOErrorKind
IOErrorKinds
Base.readavailable(::AbstractBufReader)
Base.peek(x::AbstractBufReader, ::Type{UInt8})
Base.read(x::AbstractBufReader, ::Type{UInt8})
Base.readbytes!(x::AbstractBufReader, b::AbstractVector{UInt8}, nb::Integer = length(b))
Base.copyline(out::Union{IO, AbstractBufWriter}, from::AbstractBufReader; keep::Bool = false)
Base.close(::Union{AbstractBufReader, AbstractBufWriter})
Base.isopen(::Union{AbstractBufReader, AbstractBufWriter})
Base.filesize(::CursorReader)
Base.filesize(::BufWriter)
Base.seek(::BufReader, ::Int)
Base.seek(::BufWriter, ::Int)
Base.position(::BufWriter)
Base.position(::CursorReader)
```
## Testing utilities
```@docs
BufferIO.Testing
BufferIO.Testing.BoundedReader
BufferIO.Testing.ChunkedReader
BufferIO.Testing.BoundedWriter
```
