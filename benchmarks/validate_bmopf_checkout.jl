#!/usr/bin/env julia

"""Validate a BMOPFTools checkout in an isolated local Julia environment."""

include(joinpath(@__DIR__, "common.jl"))
using .NLPDiagnosticsBenchmarkCommon

const ROOT = normpath(joinpath(@__DIR__, ".."))
const JULIA = Base.julia_cmd()
const CHECKOUT = abspath(get(
    ENV,
    "NLPDIAGNOSTICS_BMOPFTOOLS_PATH",
    normpath(joinpath(ROOT, "..", "BMOPFTools.jl")),
))
const PROJECT_OVERRIDE = get(ENV, "NLPDIAGNOSTICS_BMOPF_VALIDATION_PROJECT", nothing)
const ENV_ROOT = isnothing(PROJECT_OVERRIDE) ?
    mktempdir(tempdir(); prefix="nlpdiagnostics-bmopf-validation-") :
    abspath(PROJECT_OVERRIDE)
const OUTPUT = abspath(get(
    ENV,
    "NLPDIAGNOSTICS_BMOPF_VALIDATION_OUTPUT",
    joinpath(ROOT, "docs", "bmopf_checkout_validation_summary.json"),
))
const LOG = abspath(get(
    ENV,
    "NLPDIAGNOSTICS_BMOPF_VALIDATION_LOG",
    joinpath(tempdir(), "nlpdiagnostics-bmopf-validation.log"),
))

isdir(CHECKOUT) || error("BMOPFTools checkout is missing: $CHECKOUT")
isfile(joinpath(ROOT, "Project.toml")) || error("NLPDiagnostics project is missing: $ROOT")

function command(args::Vector{String})
    Cmd(vcat(JULIA.exec, ["--startup-file=no"], args))
end

function run_with_environment(cmd::Cmd, environment::Dict{String,String})
    try
        run(setenv(cmd, environment))
        return 0
    catch error
        error isa Base.ProcessFailedException || rethrow()
        processes = getproperty(error, :procs)
        isempty(processes) && return 1
        return processes[end].exitcode
    end
end

function child_environment()
    environment = Dict{String,String}(string(key) => string(value) for (key, value) in ENV)
    environment["NLPDIAGNOSTICS_BMOPFTOOLS_PATH"] = CHECKOUT
    environment["NLPDIAGNOSTICS_BENCHMARK_ENVIRONMENT"] = ENV_ROOT
    return environment
end

environment = child_environment()
bootstrap_exit = nothing
if isnothing(PROJECT_OVERRIDE)
    bootstrap_exit = run_with_environment(
        command([joinpath(ROOT, "benchmarks", "bootstrap_benchmark_environment.jl")]),
        environment,
    )
    bootstrap_exit == 0 || error("benchmark environment bootstrap failed with exit code $bootstrap_exit")
else
    isfile(joinpath(ENV_ROOT, "Project.toml")) ||
        error("validation project is missing Project.toml: $ENV_ROOT")
end

contract_output = joinpath(
    tempdir(),
    "nlpdiagnostics-bmopf-contract-$(getpid()).json",
)
contract_exit = run_with_environment(
    command([
        "--project=$ENV_ROOT",
        joinpath(ROOT, "benchmarks", "audit_bmopf_api_contract.jl"),
        contract_output,
    ]),
    environment,
)

mkpath(dirname(LOG))
suite_exit = open(LOG, "w") do io
    try
        run(pipeline(
            setenv(command(["--project=$ENV_ROOT", joinpath(ROOT, "test", "runtests.jl")]), environment),
            stdout=io,
            stderr=io,
        ))
        0
    catch error
        error isa Base.ProcessFailedException || rethrow()
        processes = getproperty(error, :procs)
        isempty(processes) ? 1 : processes[end].exitcode
    end
end

contract = isfile(contract_output) ? read_summary(contract_output; root = "/") : Dict{String,Any}(
    "status" => "missing",
)
dependency = get(contract, "dependency", Dict{String,Any}())
suite_text = isfile(LOG) ? read(LOG, String) : ""
suite_match = match(r"NLPDiagnostics\s+\|\s+(\d+)\s+(\d+)", suite_text)
suite_total = isnothing(suite_match) ? nothing : parse(Int, suite_match.captures[2])
suite_passed = isnothing(suite_match) ? nothing : parse(Int, suite_match.captures[1])
passed = contract_exit == 0 && suite_exit == 0 &&
         get(contract, "status", "missing") == "pass"

summary = Dict{String,Any}(
    "schema_version" => "nlpdiagnostics-bmopf-checkout-validation-v1",
    "status" => passed ? "pass" : "blocked",
    "validation_passed" => passed,
    "checkout" => CHECKOUT,
    "validation_project" => ENV_ROOT,
    "bootstrap_exit_code" => bootstrap_exit,
    "contract_exit_code" => contract_exit,
    "contract_artifact" => contract_output,
    "contract_status" => get(contract, "status", "missing"),
    "dependency" => Dict{String,Any}(
        "branch" => get(dependency, "git_branch", nothing),
        "revision" => get(dependency, "git_revision", nothing),
        "dirty" => get(dependency, "git_dirty", nothing),
    ),
    "suite_exit_code" => suite_exit,
    "suite_log" => LOG,
    "suite_passed" => suite_passed,
    "suite_total" => suite_total,
    "qualification" => Dict{String,Any}(
        "claim" => "local BMOPFTools checkout compatibility and regression-suite readiness",
        "does_not_establish" => [
            "remote branch publication or pull-request review",
            "CI or GitHub Actions execution",
            "scientific validity beyond the declared regression suite",
        ],
    ),
)
write_json(OUTPUT, summary)
println("wrote BMOPFTools checkout validation to $OUTPUT")
passed || exit(1)
