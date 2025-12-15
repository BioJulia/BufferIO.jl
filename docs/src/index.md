```@meta
CurrentModule = BufferIO
DocTestSetup = quote
    using BufferIO
end
```

# BufferIO.jl
BufferIO provides new and improved I/O interfaces for Julia [inspired by Rust](https://doc.rust-lang.org/std/io/trait.BufRead.html), and designed around exposing buffers to users in order to explicitly copy bytes to and from them. Compared to the `Base.IO` interface, the new interfaces in this package are:

* Lower level and faster
* Better specified, with more well-defined semantics and therefore easier to reason about
* Free from slow fallback methods that silently trash your performance

Beside the new interfaces, BufferIO also provides a small set of basic types to make use of the new interface, and/or allow easy interoperation between `Base.IO` types and the new buffered interfaces.

## Overview of content:
* [`AbstractBufReader`](@ref): A reader type that exposes its internal data as an immutable memory view of bytes
* [`AbstractBufWriter`](@ref): A writer type that allows writing to it by copying data to a mutable memory view of its internal buffer
* [`BufReader`](@ref): An `AbstractBufReader` that wraps a `Base.IO`
* [`BufWriter`](@ref): An `AbstractBufWriter` type that wraps a `Base.IO`
* [`CursorReader`](@ref): An `AbstractBufReader` that wraps any contiguous, memory of bytes into a stateful reader
* [`IOReader`](@ref): A `Base.IO` type that wraps an `AbstractBufReader`
* [`IOWriter`](@ref): A `Base.IO` type that wraps an `AbstractBufWriter`
* [`VecWriter`](@ref): An `AbstractBufWriter` type that is a faster and simpler alternative to `IOBuffer` usable e.g. to build strings.

## Examples
See the page with [Example use of BufferIO](@ref) in the sidebar to the left, or take a look at the docstrings of functions.

## Design notes and limitations
#### Requires Julia 1.11
BufferIO relies heavily on the `Memory` type and associated types introduced in 1.11 for its buffers

#### **Not** threadsafe by default
Locks introduce unwelcome overhead and defeats the purpose of low-level control of your IO. Wrap your IO in a lock if you need thread safety.

#### Separate readers and writers
Unlike `Base.IO` which encompasses both readers and writers, this package has two distinct interfaces for `AbstractBufReader` and `AbstractBufWriter`. This simplifies the interface for most types.

In the unlikely case someone wants to create a type which is both, you can create a base type `T`, wrapper types `R <: AbstractBufReader` and `W <: AbstractBufWriter` and then implement `reader(::T)::R` and `writer(::T)::W`.

#### Limitations on working with strings
`String` is special-cased in Julia, which makes several important optimisations impossible in an external package. Hopefully, these will be removed in future versions of Julia:

* Currently, reading from a `String` allocates. This is because strings are currently not backed by `Memory` and therefore cannot present a `MemoryView`.
  Constructing a memory view from a string requires allocating a new `Memory` object.
  Fortunately, the allocation is small since string need not be copied, but can share storage with the `Memory`.

#### Julia compiler limitation
This package makes heavy use of pointer-ful union-typed return values.
ABI support for these [will be added in Julia 1.14](https://github.com/JuliaLang/julia/pull/55045), so use of this package may incur additional allocations on earlier Julia versions.