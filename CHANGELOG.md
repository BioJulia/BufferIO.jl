# 0.3.0
## Breaking changes
* This release has removed reading and writing of any other primitive type than UInt8,
  such that e.g. Int32 and Char no longer can be written to, or read from, BufferIO types.
  Such more complex serialization will be moved to a different serialization package.
* Vararg `write(::AbstractBufWriter, x, ::Vararg)` has been removed. Instead, call write
  multiple times.
* When a `LineViewIterator` is iterated, and the underlying IO cannot buffer an entire line, an `IOError` with kind `BufferTooShort` is now thrown, whereas previously, an `ArgumentError` was thrown.
* `ByteVector` is now an alias of `Vector{UInt8}`, and `VecWriter` wraps a `Vector{UInt8}`.
  `VecWriter(v::Vector{UInt8})` now appends to `v`, whereas previously, it took over the
  memory of `v` and emptied `v`.

# 0.2.8
* `BufferIO.Testing.BoundedReader` now moves its buffer to new memory on every call to
  `fill_buffer`, `consume` and `close`, and overwrites the old memory by flipping its bits
  This helps catch code that uses views of the buffer after they have been invalidated
* Bump default buffer size for `BufReader{IOStream}`. This may circumvent IOStream's
  internal buffer and leads to a modest speed increase.
* Many bugfixes

# 0.2.7
## New features
* Add public trait function `BufferIO.is_expandable(::Type{<:AbstractBufReader})`,
  which signals that `fill_buffer` on the type never returns `nothing`.
  It defaults to `false`, and is `true` for `BufReader`, `CursorReader` and `ExpandReader`.
* Add `ExpandReader`, which wraps an `AbstractBufReader` and provides an infinitely
  expandable buffer, and `expandable`, which construct an `ExpandReader` only if needed,
  based on `is_expandable`
* Add function `take_inner`, which returns the IO wrapped by a `BufReader`, `BufWriter`,
  `IOReader`, `IOWriter` or `ExpandReader`, without closing it
* Add public module `BufferIO.Testing` with the types `BoundedReader` and `BoundedWriter`:
  Minimal readers and writers with restricted buffers, useful for testing code that is
  generic over `AbstractBufReader` and `AbstractBufWriter`
* Implement `Base.isopen` for `BufReader`, `BufWriter`, `CursorReader`, `VecWriter`,
  `IOReader`, `IOWriter` and `ExpandReader`, and document it as an optional method
  of the `AbstractBufReader` and `AbstractBufWriter` interfaces

## Changes
* `BufReader` now tracks whether it is closed: Reading from or seeking a closed
  `BufReader` throws an `IOError` of kind `ClosedIO`, and closing it twice only
  closes the wrapped IO once
* `position` and `filesize` of a closed `BufWriter` now throws an `IOError` of
  kind `ClosedIO`
* `BufReader` now only moves its buffered bytes to the start of its memory when that
  frees at least as many bytes as it moves, and otherwise grows its buffer.
  This makes compaction amortized `O(n_bytes_read)`, but means the buffer may now grow
  in `fill_buffer` even when it is not full, which was previously documented not to happen

## Performance
* Faster byte-wise operations for `BufReader` and `BufWriter`, such as `peek` and
  `write(io, ::UInt8)`
* Faster reads from a `BufReader` into a `MutableMemoryView`. When the buffer is
  empty, reads at least as large as the buffer's capacity skip the buffer and read
  directly from the wrapped IO
* On Julia 1.12 and later, large reads from a `BufReader` wrapping an `IOStream` also
  bypass the `IOStream`'s internal buffer

# 0.2.6
* Require MemoryViews 0.5
* `BufWriter` now flushes to its wrapped IO using `unsafe_write`.
* Document the interface required by an `IO` wrapped in `BufReader` and `BufWriter`.
* Clarify that seeking backwards in an `AbstractBufWriter` should not truncate.

# 0.2.5
* Allow MemoryViews 0.4
* Several small bugfixes and documentation fixes.

# 0.2.4
* Bugfix: Remove erroneous print method
* Various optimisations

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
