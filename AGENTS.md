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
BufferIO types are not subtypes of `IO`, and need not be compatible with code written for `IO`. Base methods for `IO` may be implemented for BufferIO types, but their implementation should not violate the documented `IO` behaviour of those functions to avoid accidental misuse.
If BufferIO's method semantics would violate the documented Base IO function semantics, make it a method of a BufferIO-owned function.

Because Base methods usually are defined for abstract types like `Integer`, overloads of Base functions accept the same abstract types as Base's `IO` methods do (e.g. `n::Integer`), and convert to the concrete type straight away.
This can be done once, in a generic method on the abstract type that converts and forwards, so that subtypes and the methods doing the work keep concrete types.

### When committing
Do not add yourself (you, the agent) as a co-author.

