# Reproducible full-extension regressions

This environment pins Julia 1.12.6, direct dependency versions, and the complete
resolved dependency graph. In particular, PowerIO 0.11.1 matches the selected
BMOPFTools checkout. NLPDiagnostics uses the current repository via a relative
path; BMOPFTools uses `.ci/BMOPFTools` via a relative path.

From the repository root, on a fresh checkout:

```sh
git clone https://github.com/frederikgeth/BMOPFTools.jl.git .ci/BMOPFTools
git -C .ci/BMOPFTools checkout b5e050dff579c9a0c3e69c1e1ad11d0b748f2482
julia --startup-file=no --project=benchmarks/environments/full_extensions -e 'using Pkg; Pkg.instantiate()'
julia --startup-file=no --project=benchmarks/environments/full_extensions benchmarks/check_benchmark_environment.jl
julia --startup-file=no --project=benchmarks/environments/full_extensions test/runtests.jl
```

The preflight rejects absent/unloadable dependencies and a changed or dirty
BMOPFTools checkout. CI checks out the same commit and instantiates this manifest;
it does not resolve against the moving upstream branch. Package CI separately
checks the generic library on Julia 1.10 and current stable Julia.

Do not resolve/update this environment during a comparison. Dependency upgrades
require an explicit manifest update and another regression run. The development
bootstrap under `benchmarks/bootstrap_benchmark_environment.jl` remains available
for experiments with a caller-selected sibling checkout; it is not this pinned
validation lane. Use a writable first entry in `JULIA_DEPOT_PATH` if the default
package cache is read-only. Installation requires network access unless all
packages and platform artifacts are cached.
