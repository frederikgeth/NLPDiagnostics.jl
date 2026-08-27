#!/usr/bin/env julia

"""Validate the combined MV/LV demand-multiplier sweep evidence."""

using JSON

include(joinpath(@__DIR__, "common.jl"))
using .NLPDiagnosticsBenchmarkCommon: repo_root, write_json

const ROOT = repo_root()
const INPUT = abspath(isempty(ARGS) ?
    joinpath(ROOT, "docs", "bmopf_combined_mv_lv_load_multiplier_sweep_summary.json") : ARGS[1])
const OUTPUT = abspath(length(ARGS) < 2 ?
    joinpath(ROOT, "docs", "bmopf_combined_mv_lv_load_sweep_validation_summary.json") : ARGS[2])
const EXPECTED_MULTIPLIERS = [1.0, 0.75, 0.5, 0.25]

isfile(INPUT) || error("combined MV/LV load sweep is missing: $INPUT")
sweep = JSON.parsefile(INPUT)
failures = String[]
get(sweep, "status", nothing) == "completed" || push!(failures, "sweep status is not completed")
multipliers = Float64.(get(sweep, "multipliers", Any[]))
multipliers == EXPECTED_MULTIPLIERS || push!(failures, "multipliers do not match the reviewed ladder")
results = get(sweep, "results", Any[])
length(results) == length(EXPECTED_MULTIPLIERS) || push!(failures, "result count does not match the multiplier ladder")

qualified_count = 0
for result in results
    result isa AbstractDict || (push!(failures, "a result is not an object"); continue)
    multiplier = get(result, "load_multiplier", nothing)
    get(result, "status", nothing) == "completed" || push!(failures, "multiplier $multiplier did not complete")
    records = get(result, "records", Any[])
    labels = sort!(String[get(record, "label", "") for record in records if record isa AbstractDict])
    labels == ["feasibility_voltage_transfer", "native"] ||
        push!(failures, "multiplier $multiplier does not contain one native and one transfer record")
    get(result, "hard_locally_solved", false) && (global qualified_count += 1)
end

qualified_count > 0 || push!(failures, "no demand multiplier produced paired hard local solves")
qualified_count < length(results) || push!(failures, "the sweep has no observed feasibility boundary")
quarter = only(filter(result -> get(result, "load_multiplier", nothing) == 0.25, results))
quarter["hard_locally_solved"] == true || push!(failures, "0.25 multiplier is not qualified")
for record in quarter["records"]
    get(record, "termination_status", nothing) == "LOCALLY_SOLVED" ||
        push!(failures, "0.25 multiplier has a non-local-solve termination")
    get(record, "primal_status", nothing) == "FEASIBLE_POINT" ||
        push!(failures, "0.25 multiplier has a non-feasible primal status")
end

status = isempty(failures) ? "pass" : "fail"
write_json(OUTPUT, Dict{String,Any}(
    "schema_version" => "nlpdiagnostics-bmopf-combined-mv-lv-load-sweep-validation-v1",
    "status" => status,
    "source" => relpath(INPUT, ROOT),
    "expected_multipliers" => EXPECTED_MULTIPLIERS,
    "validated_multiplier_count" => length(results),
    "paired_hard_local_solve_count" => qualified_count,
    "failure_count" => length(failures),
    "failures" => failures,
    "interpretation" => "This validates a practical combined MV/LV demand sweep and the 0.25 paired local-solve point. It does not establish a physical demand threshold, universal scaling policy, or solver superiority.",
))
println("wrote combined MV/LV load-sweep validation to $OUTPUT")
status == "pass" || exit(1)
