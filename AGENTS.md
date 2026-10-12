# AGENTS.md
BufferIO.jl is a Julia package providing an alternative buffered IO interface inspired by Rust.
It exposes buffers directly to users for explicit zero-copy reads/writes, offering lower-level control and better performance than `Base.IO`.

## Code Conventions
Performance is very important for this codebase.
* Where codegen may improve, keep fast paths inline and extract slow/cold paths into `@noinline` helper functions.
* `consume` uses `@boundscheck` so callers can opt into `@inbounds` for performance.
* Types are explicitly not threadsafe by design.
* The code base is formatted by Runic. Run `runic -i .` after changes. If formatting fails, alert the user and do not attempt to install Runic.

Unlike most idiomatic Julia code, this code base perfers concrete types, e.g. a function may be `advance_reader(::SomeReader, ::UInt)`, not taking `::Integer` as the second argument.

### When committing
Do not add yourself (you, the agent) as a co-author.

