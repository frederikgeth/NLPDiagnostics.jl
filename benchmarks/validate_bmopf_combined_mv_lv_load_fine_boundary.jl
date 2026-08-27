#!/usr/bin/env julia

"""Validate the fine combined MV/LV demand-boundary sweep."""

using JSON

include(joinpath(@__DIR__, "common.jl"))
using .NLPDiagnosticsBenchmarkCommon: repo_root, write_json

const ROOT = repo_root()
const INPUT = abspath(isempty(ARGS) ?
    joinpath(ROOT, "docs", "bmopf_combined_mv_lv_load_fine_boundary_summary.json") : ARGS[1])
const OUTPUT = abspath(length(ARGS) < 2 ?
    joinpath(ROOT, "docs", "bmopf_combined_mv_lv_load_fine_boundary_validation_summary.json") : ARGS[2])
const EXPECTED_MULTIPLIERS = [0.26, 0.27, 0.28, 0.29]

isfile(INPUT) || error("fine load-boundary artifact is missing: $INPUT")
payload = JSON.parsefile(INPUT)
failures = String[]
get(payload, "campaign", nothing) == "fine_boundary_refinement" || push!(failures, "unexpected campaign")
get(payload, "status", nothing) == "completed" || push!(failures, "campaign did not complete")
Float64.(get(payload, "multipliers", Any[])) == EXPECTED_MULTIPLIERS ||
    push!(failures, "multipliers do not match the fine ladder")
results = get(payload, "results", Any[])
length(results) == 4 || push!(failures, "expected four fine-boundary results")

by_multiplier = Dict{Float64,Any}()
for result in results
    result isa AbstractDict || (push!(failures, "a result is not an object"); continue)
    multiplier = get(result, "load_multiplier", nothing)
    multiplier isa Number || (push!(failures, "a result has no numeric multiplier"); continue)
    by_multiplier[Float64(multiplier)] = result
    records = get(result, "records", Any[])
    labels = sort!(String[get(record, "label", "") for record in records if record isa AbstractDict])
    labels == ["feasibility_voltage_transfer", "native"] ||
        push!(failures, "multiplier $multiplier lacks paired records")
end

for multiplier in (0.26, 0.27)
    haskey(by_multiplier, multiplier) || (push!(failures, "multiplier $multiplier is missing"); continue)
    get(by_multiplier[multiplier], "hard_locally_solved", false) || push!(failures, "$multiplier is not a paired local solve")
end
for multiplier in (0.28, 0.29)
    haskey(by_multiplier, multiplier) || (push!(failures, "multiplier $multiplier is missing"); continue)
    get(by_multiplier[multiplier], "hard_locally_solved", true) && push!(failures, "$multiplier unexpectedly qualified")
    all(get(record, "termination_status", nothing) == "LOCALLY_INFEASIBLE" for record in by_multiplier[multiplier]["records"]) ||
        push!(failures, "$multiplier is not consistently locally infeasible")
end

status = isempty(failures) ? "pass" : "fail"
write_json(OUTPUT, Dict{String,Any}(
    "schema_version" => "nlpdiagnostics-bmopf-combined-mv-lv-load-fine-boundary-validation-v1",
    "status" => status,
    "source" => relpath(INPUT, ROOT),
    "expected_multipliers" => EXPECTED_MULTIPLIERS,
    "paired_local_solve_range" => [0.26, 0.27],
    "paired_infeasible_range" => [0.28, 0.29],
    "failure_count" => length(failures),
    "failures" => failures,
    "interpretation" => "This validates the fine fixture-demand bracket under the declared Ipopt guard. It does not establish a physical demand threshold, universal scaling policy, or solver-independent feasibility limit.",
))
println("wrote combined MV/LV fine-boundary validation to $OUTPUT")
status == "pass" || exit(1)
