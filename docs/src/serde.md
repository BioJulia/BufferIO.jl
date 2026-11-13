# Why doesn't BufferIO support non-`UInt8` types?
`Base.IO` allows writing other types than `UInt8`. For example, `write(::IOBuffer, ::Int64)` is implemented, but `write(::AbstractBufWriter, ::Int64)` is not. Why not?

Indeed, early versions of BufferIO *did* support such non-byte IO, but I removed it.
As it turns out, implementation- and API-wise, byte-oriented IO and non-byte IO are rather different.
Specifically, non-byte IO has several complications compared to byte IO, which forces tradeoffs that necessitate a different and more complicated API to guide the user in making these tradeoffs.
Reading and writing such types are more akin to the much broader task of serialization/deserialization (serde), and I judged this API out of scope for BufferIO.
I expect to make a companion package in the near future, built on BufferIO, which provides the necessary abstractions for non-byte IO.

These are some of the complications specific to non-byte IO:

### Only non-byte IO has endianness
Any multi-byte type needs a notion of [endianness](https://en.wikipedia.org/wiki/Endianness), which is the byte order the type is serialized in.
Practically all CPUs are natively little-endian, but important formats like JPEG and protocols like TCP are big-endian.

`Base.IO` serializes in whatever endianness the host machine is, but I find that unacceptable: This kind of platform-dependent silent behaviour is a recipe for bugs.

Endianness is not a concern with byte-oriented IO as `UInt8` has no endianness.

### Error handling on partial IO is tricky
Suppose BufferIO supported non-byte IO, and you want to read a `UInt64`, but the buffer only contains three bytes. When calling `fill_buffer`, it returns `nothing`. What ought BufferIO to do in this situation?

**Option 1**: Allocate a `Vector` to load partial data in, then load the `UInt64` from the `Vector`. This incurs a hidden allocation in something as low-level as reading a single integer. If the buffer size is small, the allocation is not amortized and may even happen for *every integer read*. That is completely unacceptable for a library which is built around zero-copy access to the internal buffer of the io objects.

**Option 2**: Throw an exception on partial reads. The exception could then store any partially read data. However, this is suboptimal API: Catching exceptions is slow in Julia, which makes high-performance 'peeking' not possible. It's also a highly predictable state and not a user error. A good rule of thumb is that bad code can cause crashes, but bad data should not. Throwing in this edge case violates that principle.

**Option 3**: Read the integer incrementally, one byte at a time, and build it via bitshift and bitwise ORs before reinterpreting as the target type. This creates a slow path that is hard to guard against, where for some types some of the time, even integers are loaded one byte at a time.

**Option 4**: Attempt to grow the buffer until it has at least 8 bytes, and throw an exception if that is not possible. That's probably the most promising approach, but it would mean *generic* BufferIO types would still not support non-byte IO, as it would place a minimum limit on the buffer size.

Worse, for options 1-3, if the reader hits EOF before reading the full integer, the read is partially complete, and the bytes read before EOF are lost.

These tradeoffs are mostly not unacceptable, but since they do not occur for byte-oriented IO, these tradeoffs force semantics onto non-byte reads, which leave nasty surprises for users.

### Some types have custom serialization rules
For `Base.IO`, when a `Bool` is read, the byte `0x00` is interpreted as `false`, and any other byte is interpreted as `true`. This means that `true` may not roundtrip.
A `Char` may be read as anywhere between 1 and 4 bytes, with complex reading rules, following UTF-8 rules.

These are perfectly reasonable deserialization strategies, but they are just that. They are not the same as merely copying bytes.

Their complications also generalize: What should BufferIO do, *in general*, for types like `Bool`, where not all bit patterns are valid? Throw? Then how can a user efficiently peek these values?
How should a user *in general* specify that a type has a non-standard deserialization, like `Char`?
