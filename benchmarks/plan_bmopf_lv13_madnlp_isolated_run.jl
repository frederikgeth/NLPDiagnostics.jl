#!/usr/bin/env julia

"""Materialize the approved LV13 MadNLP transfer handoff.

This planner validates the resource-guard artifact and emits the exact
environment needed by the existing perturbed-start runner.  It deliberately
does not launch a solver: the timeout and memory envelope require an explicit
operator decision and an isolated process.
"""

include(joinpath(@__DIR__, "common.jl"))
using .NLPDiagnosticsBenchmarkCommon

const ROOT = repo_root()
const INPUT = abspath(get(
    ENV,
    "NLPDIAGNOSTICS_LV13_MADNLP_GUARD_INPUT",
    joinpath(ROOT, "docs", "bmopf_lv13_madnlp_transfer_guard_summary.json"),
))
const OUTPUT = abspath(get(
    ENV,
    "NLPDIAGNOSTICS_LV13_MADNLP_PLAN_OUTPUT",
    joinpath(ROOT, "docs", "bmopf_lv13_madnlp_isolated_run_plan.json"),
))

guard = read_summary(relpath(INPUT, ROOT); root=ROOT)
guard["status"] == "resource_guard_validated" ||
    error("LV13 transfer guard is not validated: $(guard["status"])")
plan = get(guard, "isolated_run_plan", nothing)
plan isa AbstractDict || error("guard artifact has no isolated_run_plan")

feeder = String(get(guard, "feeder", "LV13_58bus"))
solver = lowercase(String(get(plan, "solver", "MadNLP")))
solver == "madnlp" || error("isolated plan must target MadNLP")
required_variables = Int(get(plan, "required_max_variables", 0))
proposed_variables = Int(get(plan, "proposed_max_variables", 0))
proposed_variables >= required_variables ||
    error("proposed variable budget is below the guarded model size")
timeout_seconds = Int(get(plan, "timeout_seconds", 0))
memory_limit_mb = Int(get(plan, "memory_limit_mb", 0))
timeout_seconds > 0 || error("timeout must be positive")
memory_limit_mb > 0 || error("memory limit must be positive")
repeats = Int(get(plan, "repeats", 0))
repeats >= 2 || error("isolated plan requires at least two repeats")
max_iter = Int(get(plan, "max_iter", 0))
solver_tolerance = Float64(get(plan, "solver_tolerance", 0.0))
variants = [String(value) for value in get(plan, "variants", Any[])]
variants == ["plus_1pct", "minus_1pct"] ||
    error("isolated plan variants must be the declared ±1% pair")
output_path = joinpath(ROOT, "work", "bmopf-combined-mv-lv-perturbed-start-$feeder-madnlp-isolated.json")
runner = joinpath(ROOT, "benchmarks", "bmopf_combined_mv_lv_perturbed_start_campaign.jl")
command_environment = Dict{String,Any}(
    "NLPDIAGNOSTICS_COMBINED_MV_LV_SNAPSHOT_SOLVER" => "madnlp",
    "NLPDIAGNOSTICS_COMBINED_MV_LV_SNAPSHOT_MAX_VARIABLES" => proposed_variables,
    "NLPDIAGNOSTICS_COMBINED_MV_LV_PERTURBED_START_FEEDER" => feeder,
    "NLPDIAGNOSTICS_COMBINED_MV_LV_PERTURBED_START_SOLVER" => "madnlp",
    "NLPDIAGNOSTICS_COMBINED_MV_LV_PERTURBED_START_REPEATS" => repeats,
    "NLPDIAGNOSTICS_COMBINED_MV_LV_PERTURBED_START_MAX_ITER" => max_iter,
    "NLPDIAGNOSTICS_COMBINED_MV_LV_PERTURBED_START_TOL" => solver_tolerance,
    "NLPDIAGNOSTICS_COMBINED_MV_LV_PERTURBED_START_MAX_VARIABLES" => proposed_variables,
    "NLPDIAGNOSTICS_COMBINED_MV_LV_PERTURBED_START_OUTPUT" => output_path,
)
command = join([
    "JULIA_PKG_PRECOMPILE_AUTO=0",
    "julia --compiled-modules=no --startup-file=no --project=work/benchmark-environment",
    runner,
], " ")

write_json(OUTPUT, Dict{String,Any}(
    "schema_version" => "nlpdiagnostics-bmopf-lv13-madnlp-isolated-run-plan-v1",
    "runner" => "benchmarks/plan_bmopf_lv13_madnlp_isolated_run.jl",
    "status" => "isolated_run_ready",
    "source_guard" => Dict(
        "artifact" => "docs/bmopf_lv13_madnlp_transfer_guard_summary.json",
        "status" => guard["status"],
        "model_variable_count" => get(guard["snapshot"], "model_variable_count", nothing),
        "source_warning_count" => get(guard["snapshot"], "source_warning_count", nothing),
    ),
    "resource_envelope" => Dict(
        "max_variables" => proposed_variables,
        "timeout_seconds" => timeout_seconds,
        "memory_limit_mb" => memory_limit_mb,
        "enforcement" => "external isolated-process launcher",
    ),
    "execution" => Dict(
        "approval_required" => true,
        "runner_script" => relpath(runner, ROOT),
        "command" => command,
        "environment" => command_environment,
        "output" => relpath(output_path, ROOT),
    ),
    "closure_criteria" => get(plan, "closure_criteria", Any[]),
    "qualification" => Dict(
        "claim" => "the LV13 MadNLP transfer is ready for an explicitly approved isolated run",
        "does_not_establish" => [
            "that the current environment can execute the run within the envelope",
            "MadNLP success or cross-feeder equivalence before the artifact is produced",
        ],
        "next_action" => "run the emitted command under the declared timeout and memory envelope, then summarize its artifact",
    ),
))
println("wrote LV13 MadNLP isolated-run plan to $OUTPUT")
