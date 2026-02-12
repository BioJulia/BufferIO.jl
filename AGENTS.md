# AGENTS.md

This file provides guidance to AI agents when working with code in this repository.

## Project Overview

BufferIO.jl is a Julia package providing an alternative buffered IO interface inspired by Rust. It exposes buffers directly to users for explicit zero-copy reads/writes, offering lower-level control and better performance than `Base.IO`. Requires Julia 1.11+ (uses `Memory` type). Part of the BioJulia ecosystem.

## Commands

**Run all tests:**
```bash
JULIA_TEST_FAILFAST=true julia --project=. --startup=no -e "using Pkg; Pkg.test()"
```

**Run a single test file interactively:**
```bash
JULIA_TEST_FAILFAST=true julia --project=. --startup=no -e 'using BufferIO, Test, MemoryViews; include("test/generic_types.jl"); include("test/bufreader.jl")'
```
Note: `test/generic_types.jl` defines test helper types and must be included before any individual test file.

**Experiment with boundschecks on**
Add julia option `--check-bounds=yes` when running Julia code, to avoid undefined behaviour from out of bounds access.

**Build documentation locally:**
```bash
julia --project=docs --startup=no docs/make.jl
```

## Architecture

### Two core abstract types

- **`AbstractBufReader`** — read interface exposing an immutable buffer. Subtypes implement: `get_buffer`, `fill_buffer`, `consume`, `close`.
- **`AbstractBufWriter`** — write interface exposing a mutable buffer. Subtypes implement: `get_buffer`, `grow_buffer`, `consume`, `close`, `flush`.

Most generic `Base.IO`-compatible methods (`read`, `write`, `peek`, `readline`, `skip`, `seek`, etc.) are implemented generically in `src/base.jl` on top of these ~4-5 primitives.
However, the semantics of the `Base.IO` functions may be slightly different when implemented for `BufReader` and `BufWriter`. In that case, the precise semantics are always documented in the docstring for the new methods.

### Concrete types

| Type | Role |
|------|------|
| `BufReader{T<:IO}` | Buffers reads from a `Base.IO` |
| `BufWriter{T<:IO}` | Buffers writes to a `Base.IO` |
| `CursorReader` | Stateful reader over in-memory data (no IO) |
| `VecWriter` | Builds bytes in memory; uses `ByteVector` internally |
| `IOReader` / `IOWriter` | Thin wrappers making `AbstractBufReader`/`AbstractBufWriter` usable as `Base.IO` |
| `ByteVector` | Custom `DenseVector{UInt8}` supporting `takestring!` for zero-copy string creation. , This is a re-implementation of `Vector{UInt8}`, since it uses what would otherwise be implementation details of `Vector` |

### Source file layout

- `BufferIO.jl` — module definition, exports, `IOErrorKinds` enum, includes all other files
- `base.jl` — generic reader/writer methods (the bulk of the shared implementation)
- `bufreader.jl`, `bufwriter.jl` — `BufReader`/`BufWriter` implementations
- `cursor.jl` — `CursorReader`
- `vecwriter.jl` — `VecWriter` and `ByteVector`
- `ioreader.jl`, `iowriter.jl` — IO wrapper types
- `lineiterator.jl` — `LineViewIterator` (created via `line_views()`)

### Dependencies

Only one dependency: `MemoryViews.jl` (provides `ImmutableMemoryView`, `MutableMemoryView`).

## Code Conventions
Performance is very important for this codebase.

- **Hot-path splitting:** Fast paths are kept inline; slow/cold paths are extracted into `@noinline` helper functions for better compiler optimization.
- **`@boundscheck`/`@inbounds`:** `consume` uses `@boundscheck` so callers can opt into `@inbounds` for performance.
- **Memory safety:** Pointer operations use `GC.@preserve` blocks. Buffer views use `MemoryView` types rather than raw pointers.
- **Not threadsafe:** Types are explicitly not threadsafe by design.
- **Positions are zero-based** (0:filesize), matching `Base.IO` conventions.

### When committing
Do not add yourself (you, the agent) as a co-author.
