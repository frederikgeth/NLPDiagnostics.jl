#!/usr/bin/env julia

# Explicit opt-in environment bootstrap for local benchmark work. This is the
# only benchmark helper that mutates Julia project metadata: it develops the
# caller-selected local BMOPFTools checkout, instantiates the declared test
# dependencies, and precompiles them. Run it from a clean branch and review the
# resulting Project.toml/Manifest.toml diff.

using Pkg

const REPO_ROOT = normpath(joinpath(@__DIR__, ".."))
const ENV_ROOT = abspath(get(
    ENV,
    "NLPDIAGNOSTICS_BENCHMARK_ENVIRONMENT",
    normpath(joinpath(REPO_ROOT, "work", "benchmark-environment")),
))
const BMOPF_ROOT = get(
    ENV,
    "NLPDIAGNOSTICS_BMOPFTOOLS_PATH",
    normpath(joinpath(REPO_ROOT, "..", "BMOPFTools.jl")),
)

isdir(BMOPF_ROOT) || error(
    "BMOPFTools checkout is missing at $BMOPF_ROOT; set NLPDIAGNOSTICS_BMOPFTOOLS_PATH",
)

mkpath(ENV_ROOT)
Pkg.activate(ENV_ROOT)
Pkg.develop(Pkg.PackageSpec(path = REPO_ROOT))
Pkg.develop(Pkg.PackageSpec(path = BMOPF_ROOT))
# Extras are intentionally not resolved by `Pkg.instantiate()` for a package
# project. Add the solver/test surface explicitly so the preflight and full
# regression suite see the same environment.
Pkg.add([
    Pkg.PackageSpec(name = "JSON"),
    Pkg.PackageSpec(name = "JuMP"),
    Pkg.PackageSpec(name = "Ipopt"),
    Pkg.PackageSpec(name = "MathOptInterface"),
    Pkg.PackageSpec(name = "PowerModels"),
    Pkg.PackageSpec(name = "PowerIO"),
    Pkg.PackageSpec(name = "MadNLP"),
])
Pkg.instantiate()
Pkg.precompile()
println("benchmark environment bootstrapped")
println("benchmark environment: $ENV_ROOT")
println("NLPDiagnostics checkout: $REPO_ROOT")
println("BMOPFTools checkout: $BMOPF_ROOT")
