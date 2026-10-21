# AGENTS.md
BufferIO.jl is a Julia package providing an alternative buffered IO interface inspired by Rust.
It exposes buffers directly to users for explicit zero-copy reads/writes, offering lower-level control and better performance than `Base.IO`.

## Code Conventions
Performance is very important for this codebase.
* Where codegen may improve, keep fast paths inline and extract slow/cold paths into `@noinline` helper functions.
* `consume` uses `@boundscheck` so callers can opt into `@inbounds` for performance.
* Types are explicitly not threadsafe by design.
* The code base is formatted by Runic. Run `runic -i .` after changes. If formatting fails, alert the user and do not attempt to install Runic.
* Avoid using leading underscores in names, like `function _foo`. The `export` and `public` keywords, not names, determine public/private distinction.

Unlike most idiomatic Julia code, this code base perfers concrete types, e.g. a function may be `advance_reader(::SomeReader, ::UInt)`, not taking `::Integer` as the second argument.

### Overloading Base functions
BufferIO types are not subtypes of `IO`, but should be usable from untyped generic code written against `IO`.
A method may overload a Base function unless it:
* contradicts the documented behaviour of the function for `IO`, or
* does something obviously wrong given what the function is for.

Matching how a particular `IO` type, such as `IOBuffer` or `IOStream`, happens to implement the function is not a requirement.
Base's `IO` API is underspecified, and those implementations often disagree with each other.
If a method fails either test, give it a BufferIO-owned name instead of overloading the Base function.

Because generic code may pass any `Integer`, overloads of Base functions accept the same abstract types as Base's `IO` methods do (e.g. `n::Integer`), and convert to the concrete type straight away.
This can be done once, in a generic method on the abstract type that converts and forwards, so that subtypes and the methods doing the work keep concrete types.
For example, subtypes implement `seek(::T, ::Int)`, and `seek(::AbstractBufReader, ::Integer)` converts and forwards to it.
BufferIO's own functions, like `consume` or `relative_seek`, take concrete types (e.g. `Int`), following the rule above.

### When committing
Do not add yourself (you, the agent) as a co-author.

