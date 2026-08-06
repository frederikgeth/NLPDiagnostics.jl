#!/usr/bin/env julia

"""Run a benchmark script with a writable, reproducible Julia depot overlay.

Usage:

    julia benchmarks/run_benchmark.jl benchmarks/bmopf_solver_trace.jl

The first depot entry is a writable local benchmark depot (under `tempdir()` by
default). Existing depot entries remain visible for package sources and
artifacts, but compiled caches and usage locks are written to the local entry
instead of a restricted global depot. Set `NLPDIAGNOSTICS_BENCHMARK_DEPOT` or
`NLPDIAGNOSTICS_BENCHMARK_PROJECT` to override the defaults.
"""

length(ARGS) >= 1 || error(
    "usage: run_benchmark.jl <benchmark-script.jl> [script arguments...]",
)

const REPO_ROOT = normpath(joinpath(@__DIR__, ".."))
const script = abspath(ARGS[1])
isfile(script) || error("benchmark script does not exist: $script")
const script_args = ARGS[2:end]
const project = abspath(get(
    ENV,
    "NLPDIAGNOSTICS_BENCHMARK_PROJECT",
    joinpath(REPO_ROOT, "work", "benchmark-environment"),
))
isfile(joinpath(project, "Project.toml")) || error(
    "benchmark project is missing: $project; run bootstrap_benchmark_environment.jl first",
)
const depot = abspath(get(
    ENV,
    "NLPDIAGNOSTICS_BENCHMARK_DEPOT",
    joinpath(tempdir(), "nlpdiagnostics-benchmark-depot"),
))
mkpath(depot)

existing_depots = String[]
for entry in DEPOT_PATH
    entry == depot || push!(existing_depots, entry)
end
child_depot = join((depot, existing_depots...), Sys.iswindows() ? ';' : ':')
child_env = copy(ENV)
child_env["JULIA_DEPOT_PATH"] = child_depot
child_env["JULIA_PKG_PRECOMPILE_AUTO"] = get(
    ENV, "JULIA_PKG_PRECOMPILE_AUTO", "0",
)
child_env["JULIA_NUM_PRECOMPILE_TASKS"] = get(
    ENV, "JULIA_NUM_PRECOMPILE_TASKS", "1",
)

julia = Base.julia_cmd()
# Build the command from argv explicitly. Interpolating a splatted vector into
# a command literal can concatenate adjacent arguments on newer Julia releases.
command = Cmd(vcat(julia.exec, ["--startup-file=no", "--project=$project", script], script_args))
println("benchmark project: $project")
println("benchmark depot: $depot")
println("benchmark script: $script")
try
    run(setenv(command, child_env))
catch error
    error isa Base.ProcessFailedException || rethrow()
    processes = getproperty(error, :procs)
    isempty(processes) && exit(1)
    exit(processes[end].exitcode)
end
