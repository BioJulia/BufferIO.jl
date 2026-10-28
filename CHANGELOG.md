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
* The unused error kinds `PermissionDenied`, `NotFound`, `BrokenPipe`, `AlreadyExists`,
  `NotADirectory`, `IsADirectory`, `DirectoryNotEmpty` and `InvalidFileName` have been
  removed from `IOErrorKinds.IOErrorKind`.
* Writing to an `AbstractBufWriter` which cannot make room for more data now throws an
  `IOError` of the new kind `WriterFull`, whereas previously, it threw kind `EOF`.
* `write_repeated` now throws an `IOError` of kind `WriterFull` if the writer cannot make
  room for all bytes, and always returns the number of bytes requested. Previously, it
  returned the number of bytes written.
* The `chomp` keyword of `line_views`, and the public `LineViewIterator.chomp` property,
  have been renamed to `keep`, with the opposite meaning and default (`keep = false`),
  to match `eachline`, `readline` and `copyline`. Replace `chomp = false` with
  `keep = true`.
* `skip(::AbstractBufReader, n)` has been removed, because it read and discarded bytes,
  whereas `Base.skip` is documented to seek relative to the current position.
  The same functionality is now provided by the new function `discard(io, n::Int)`.
  Correspondingly, `skip_exact` has been renamed to `discard_exact`.
  To seek relative to the current position, use `relative_seek`.
* `unsafe_read(::AbstractBufReader, ref, nbytes)` has been removed, because it silently
  stopped at EOF, whereas `Base.unsafe_read` is documented to copy `nbytes` bytes.
  The same functionality is now provided by the new function
  `unsafe_read_all!(io, p::Ptr{UInt8}, nbytes::Int)`, the unsafe counterpart of
  `read_all!`. It throws an `ArgumentError` if `nbytes` is negative.
  `unsafe_read(::IOReader, ...)` is unaffected.
* `isopen` is now a required method of `AbstractBufReader` and `AbstractBufWriter`,
  like `close`. It returns whether the IO is still usable, so types whose `close` does
  nothing, such as `CursorReader`, always return `true`. Subtypes defined outside BufferIO
  which do not implement `isopen` must now do so.
  The behaviour of `close`, `isopen` and `take_inner` is now documented: `close` is
  idempotent, and closing a writer flushes it first.
* `discard_exact` (previously `skip_exact`) and `write_repeated` now take `n::Int` instead
  of `n::Integer`. As a rule, BufferIO's own functions take concrete types, while
  overloads of Base functions accept any `Integer`.
* `filesize(::AbstractBufWriter)` now includes data which is consumed, but not yet
  flushed, i.e. it is the size the file will have once flushed. Previously, it only
  counted flushed data. Consequently, `position(io)` is now always in `0:filesize(io)`,
  and `seek` and `seekend` no longer need to flush before checking their bounds.
* `seek(::BufWriter)` no longer flushes the wrapped IO. It now writes its buffered data
  to the wrapped IO, like `shallow_flush`, before seeking. An out-of-bounds `seek` now
  leaves the writer unchanged, whereas previously, it flushed the writer before throwing.
* Seeking a `BufReader` now requires the wrapped IO to implement `position`, in addition
  to `seek` and `filesize`. In return, seeking backwards no longer calls `filesize`
  on the wrapped IO.

## New features
* `IOErrorKinds.IOErrorKind` is now public.
* The two-arg `get_nonempty_buffer(io, min_size)` now works for every `AbstractBufWriter`,
  through a generic fallback which returns `nothing` if `io` can't provide a buffer of
  at least `min_size` bytes. Previously, only `VecWriter` and `BufWriter` implemented it.
* `seek` now accepts any `Integer` for all `AbstractBufReader`s and `AbstractBufWriter`s,
  through a generic fallback that converts to `Int`. Implementors still define `seek(::T, ::Int)`.
  Previously, e.g. `seek(::BufReader, ::Int32)` threw a `MethodError`.
* `unsafe_write` now accepts any `Integer` for `nbytes`, not just `UInt`.
* `readline` on an `AbstractBufReader` is faster: 1.4x to 3x for lines that fit in the
  buffer, and 3x to 5x for lines longer than the buffer. If the reader can grow its
  buffer, `readline` now grows it to fit the line, like `line_views` does.

## Bugfixes
* `eachline` now works on readers that can't grow their buffer, like `readline` does,
  and each iteration consumes exactly one line.
  Previously, it threw an `IOError` of kind `BufferTooShort` on lines longer than the
  buffer.
* `print` and `println` on an `AbstractBufWriter` now work for all arguments, by
  printing through an `IOWriter`. Previously, printing anything but a `String` or
  `SubString{String}` threw a `MethodError`, and the varargs forms, e.g.
  `println(io, "x")`, silently printed the writer and the arguments to stdout.
* `unsafe_write(::AbstractBufWriter, ::Ref, ::UInt)` now works for a `Ref` of any type.
  Previously, it threw a `MethodError` for e.g. `Ref{Int64}`.

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
