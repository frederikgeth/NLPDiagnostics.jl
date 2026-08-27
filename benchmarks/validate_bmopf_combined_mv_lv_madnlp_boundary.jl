#!/usr/bin/env julia

"""Validate the solver-diverse combined MV/LV boundary check."""

using JSON

include(joinpath(@__DIR__, "common.jl"))
using .NLPDiagnosticsBenchmarkCommon: repo_root, write_json

const ROOT = repo_root()
const INPUT = abspath(isempty(ARGS) ?
    joinpath(ROOT, "docs", "bmopf_combined_mv_lv_madnlp_boundary_summary.json") : ARGS[1])
const OUTPUT = abspath(length(ARGS) < 2 ?
    joinpath(ROOT, "docs", "bmopf_combined_mv_lv_madnlp_boundary_validation_summary.json") : ARGS[2])

isfile(INPUT) || error("MadNLP boundary artifact is missing: $INPUT")
payload = JSON.parsefile(INPUT)
failures = String[]
get(payload, "campaign", nothing) == "madnlp_boundary_refinement" || push!(failures, "unexpected campaign")
get(payload, "status", nothing) == "completed" || push!(failures, "campaign did not complete")
get(payload, "multipliers", Any[]) == [0.25, 0.3] || push!(failures, "unexpected multipliers")
results = get(payload, "results", Any[])
length(results) == 2 || push!(failures, "expected two multiplier results")

for result in results
    result isa AbstractDict || (push!(failures, "a result is not an object"); continue)
    records = get(result, "records", Any[])
    length(records) == 2 || push!(failures, "a multiplier does not have paired records")
    for record in records
        get(record, "solver", nothing) == "MadNLP" || push!(failures, "a record is not MadNLP evidence")
    end
end

by_multiplier = Dict(Float64(get(result, "load_multiplier", NaN)) => result for result in results)
if haskey(by_multiplier, 0.25)
    get(by_multiplier[0.25], "hard_locally_solved", false) || push!(failures, "MadNLP 0.25 is not a paired local solve")
else
    push!(failures, "MadNLP 0.25 result is missing")
end
if haskey(by_multiplier, 0.3)
    get(by_multiplier[0.3], "hard_locally_solved", true) && push!(failures, "MadNLP 0.30 unexpectedly qualified")
    all(get(record, "termination_status", nothing) == "ITERATION_LIMIT" for record in by_multiplier[0.3]["records"]) ||
        push!(failures, "MadNLP 0.30 is not consistently iteration-limited")
else
    push!(failures, "MadNLP 0.30 result is missing")
end

status = isempty(failures) ? "pass" : "fail"
write_json(OUTPUT, Dict{String,Any}(
    "schema_version" => "nlpdiagnostics-bmopf-combined-mv-lv-madnlp-boundary-validation-v1",
    "status" => status,
    "source" => relpath(INPUT, ROOT),
    "solver" => "MadNLP",
    "qualified_multiplier" => 0.25,
    "iteration_limited_multiplier" => 0.3,
    "failure_count" => length(failures),
    "failures" => failures,
    "interpretation" => "This validates solver-diverse bounded evidence at two fixture-demand points. It does not establish solver superiority, a physical threshold, universal scaling policy, or hard convergence beyond the observed local statuses.",
))
println("wrote combined MV/LV MadNLP boundary validation to $OUTPUT")
status == "pass" || exit(1)
