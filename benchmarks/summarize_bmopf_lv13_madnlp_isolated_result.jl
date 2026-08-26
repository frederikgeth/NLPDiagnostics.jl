#!/usr/bin/env julia

"""Validate the eventual isolated LV13 MadNLP result without rerunning it.

The default state is an explicit pending artifact.  Once the approved runner
produces its JSON, this summarizer checks the declared budget, perturbation
matrix, source-warning provenance, endpoint gates, and cross-policy gates.
"""

include(joinpath(@__DIR__, "common.jl"))
using .NLPDiagnosticsBenchmarkCommon
using JSON

const ROOT = repo_root()
const INPUT = abspath(get(
    ENV,
    "NLPDIAGNOSTICS_LV13_MADNLP_ISOLATED_RESULT_INPUT",
    joinpath(ROOT, "work", "bmopf-combined-mv-lv-perturbed-start-LV13_58bus-madnlp-isolated.json"),
))
const PLAN_PATH = "docs/bmopf_lv13_madnlp_isolated_run_plan.json"
const OUTPUT = abspath(get(
    ENV,
    "NLPDIAGNOSTICS_LV13_MADNLP_ISOLATED_RESULT_OUTPUT",
    joinpath(ROOT, "docs", "bmopf_lv13_madnlp_isolated_result_summary.json"),
))

plan = read_summary(PLAN_PATH)
plan_environment = get(get(plan, "execution", Dict{String,Any}()), "environment", Dict{String,Any}())
expected_feeder = String(get(plan_environment, "NLPDIAGNOSTICS_COMBINED_MV_LV_PERTURBED_START_FEEDER", "LV13_58bus"))
expected_max_variables = Int(get(plan_environment, "NLPDIAGNOSTICS_COMBINED_MV_LV_PERTURBED_START_MAX_VARIABLES", 0))
expected_repeats = Int(get(plan_environment, "NLPDIAGNOSTICS_COMBINED_MV_LV_PERTURBED_START_REPEATS", 0))
expected_max_iter = Int(get(plan_environment, "NLPDIAGNOSTICS_COMBINED_MV_LV_PERTURBED_START_MAX_ITER", 0))
expected_tolerance = Float64(get(plan_environment, "NLPDIAGNOSTICS_COMBINED_MV_LV_PERTURBED_START_TOL", 0.0))
expected_variants = Set(["plus_1pct", "minus_1pct"])

artifact_present = isfile(INPUT)
payload = artifact_present ? JSON.parsefile(INPUT) : Dict{String,Any}()
budgets = get(payload, "budgets", Dict{String,Any}())
snapshot = get(payload, "snapshot", Dict{String,Any}())
matrix_gates = get(payload, "matrix_gates", Dict{String,Any}())
variants = get(payload, "variants", Any[])
variant_names = Set(String(get(item, "variant", "")) for item in variants if item isa AbstractDict)
records = [
    record for item in variants if item isa AbstractDict
    for record in get(item, "records", Any[])
]
all_termination_local = !isempty(records) && all(
    get(record, "termination_status", "") == "LOCALLY_SOLVED" for record in records
)
checks = Dict{String,Any}(
    "artifact_present" => artifact_present,
    "schema_matches_runner" => artifact_present &&
        get(payload, "schema_version", "") == "nlpdiagnostics-bmopf-combined-mv-lv-perturbed-start-campaign-v1",
    "feeder_matches_plan" => artifact_present &&
        get(snapshot, "feeder", "") == expected_feeder,
    "solver_matches_plan" => artifact_present && lowercase(String(get(payload, "solver", ""))) == "madnlp",
    "budget_matches_plan" => artifact_present &&
        Int(get(budgets, "max_variables", -1)) == expected_max_variables &&
        Int(get(budgets, "repeats", -1)) == expected_repeats &&
        Int(get(budgets, "max_iter", -1)) == expected_max_iter &&
        Float64(get(budgets, "solver_tolerance", -1.0)) == expected_tolerance,
    "declared_variants_match" => artifact_present && variant_names == expected_variants,
    "all_variants_qualified" => artifact_present && get(matrix_gates, "all_variants_qualified", false),
    "all_physical_endpoints_accepted" => artifact_present && get(matrix_gates, "all_physical_endpoints_accepted", false),
    "all_comparisons_qualified" => artifact_present && get(matrix_gates, "all_comparisons_qualified", false),
    "all_terminations_locally_solved" => artifact_present && all_termination_local,
    "source_warning_count_retained" => artifact_present &&
        Int(get(snapshot, "source_warning_count", -1)) == 46,
)
complete = artifact_present && all(values(checks))
status = complete ? "isolated_result_complete" : artifact_present ? "isolated_result_partial" : "awaiting_artifact"
write_json(OUTPUT, Dict{String,Any}(
    "schema_version" => "nlpdiagnostics-bmopf-lv13-madnlp-isolated-result-v1",
    "runner" => "benchmarks/summarize_bmopf_lv13_madnlp_isolated_result.jl",
    "status" => status,
    "input" => relpath(INPUT, ROOT),
    "expected" => Dict(
        "feeder" => expected_feeder,
        "solver" => "MadNLP",
        "max_variables" => expected_max_variables,
        "repeats" => expected_repeats,
        "max_iter" => expected_max_iter,
        "solver_tolerance" => expected_tolerance,
        "variants" => sort!(collect(expected_variants)),
    ),
    "observed" => Dict(
        "variant_count" => length(variants),
        "record_count" => length(records),
        "source_warning_count" => get(snapshot, "source_warning_count", nothing),
        "matrix_gates" => matrix_gates,
    ),
    "checks" => checks,
    "qualification" => Dict(
        "claim" => complete ?
            "the approved isolated LV13 MadNLP transfer satisfies its declared closure criteria" :
            "the isolated LV13 MadNLP transfer is not yet qualified",
        "does_not_establish" => [
            "solver superiority or a universal scaling policy",
            "cross-feeder equivalence beyond the declared application contract",
        ],
        "next_action" => complete ?
            "add the qualified result to the application bridge" :
            "run the approved isolated command, then rerun this summarizer",
    ),
))
println("wrote LV13 MadNLP isolated-result summary to $OUTPUT")
