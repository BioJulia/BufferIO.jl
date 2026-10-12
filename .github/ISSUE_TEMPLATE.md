Thank you for opening an issue and helping improve our software.
If you are submitting a bug report, it may help us if you include the following information:
1. A small example that demonstrates the bug. If possible, please make the code copy-pastable into a fresh REPL.

2. Your Julia version and the versions of all packages in your current environment
    - Get the Julia version by running `versioninfo()`
    - Get versions of all packages with `using Pkg; Pkg.status(mode=PKGMODE_MANIFEST)`
    - Please be aware that due to [stacked environments](https://docs.julialang.org/en/v1/manual/code-loading/#Environments), you may have accidentally loaded packages not in your current environment. If you suspect this is the case, try running the code below and include its output in your bug report:

```julia
for (_, mod) in Base.loaded_modules
    version = Base.pkgversion(mod)
    version === nothing || println(nameof(mod), " ", version)
end
```

