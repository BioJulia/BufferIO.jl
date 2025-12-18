# Unreleased

# 0.3.0
## Breaking changes
* When a `LineViewIterator` is iterated, and the underlying IO cannot buffer an entire line, an `IOError` with kind `BufferTooShort` is now thrown, whereas previously, an `ArgumentError` was thrown.

# 0.2.3
* Add function `relative_seek`
* Add `write_repeated`
* Expand documentation of `line_views`, and make stronger promises about its
  semantics.

# 0.2.2
* Add method `line_views(::MemoryView{UInt8})`

# 0.2.1
* Add methods for `unsafe_write` for AbstractBufWriter

# 0.2.0
Major breaking change.

## Breaking changes
* `VecWriter` no longer wraps a `Vector{UInt8}`, but instead the new, exported type
  `ByteVector`. This is so the code no longer relies on Base internals.
  `ByteVector` is largely backwards compatible with `Vector{UInt8}`, and is
  guaranteed forward compatible. It may be aliased to `Vector{UInt8}` in the future.
* The definition of `filesize(::AbstractBufWriter)` has changed, and now does not
  include unflushed, but committed data. Further, implementers should also
  implement `position`
* The definition of `seek(::AbstractBufWriter)` has changed, and it must now also
  flush before seeking.

## New features
* New type `IOWriter <: IO` that wraps an `AbstractBufWriter` and forwards its methods,
  while being a subtype of `IO`.
* On Julia 1.11 and 1.12, a new function `takestring!` has been added

## Other
* The requirements of growth behaviour for `grow_buffer` has been loosened
* The definition of `position` has been clarified

# 0.1.1
* Add ClosedIO IOErrorKind
* Document existing method `unsafe_read(::AbstractBufReader, ::Ptr{UInt8}, ::UInt)`
* Fix bug in generic write method
