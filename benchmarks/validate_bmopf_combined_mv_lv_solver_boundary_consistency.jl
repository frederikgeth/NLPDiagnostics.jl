#!/usr/bin/env julia

"""Validate consistency of the combined MV/LV boundary across solvers."""

using JSON

include(joinpath(@__DIR__, "common.jl"))
using .NLPDiagnosticsBenchmarkCommon: repo_root, write_json

const ROOT = repo_root()
const IPOPT_INPUT = joinpath(ROOT, "docs", "bmopf_combined_mv_lv_load_boundary_refinement_summary.json")
const MADNLP_INPUT = joinpath(ROOT, "docs", "bmopf_combined_mv_lv_madnlp_boundary_summary.json")
const OUTPUT = abspath(isempty(ARGS) ?
    joinpath(ROOT, "docs", "bmopf_combined_mv_lv_solver_boundary_consistency_summary.json") : ARGS[1])

isfile(IPOPT_INPUT) || error("Ipopt boundary artifact is missing: $IPOPT_INPUT")
isfile(MADNLP_INPUT) || error("MadNLP boundary artifact is missing: $MADNLP_INPUT")
ipopt = JSON.parsefile(IPOPT_INPUT)
madnlp = JSON.parsefile(MADNLP_INPUT)
failures = String[]

function indexed_results(payload)
    Dict(Float64(get(result, "load_multiplier", NaN)) => result for result in get(payload, "results", Any[]))
end

ipopt_results = indexed_results(ipopt)
madnlp_results = indexed_results(madnlp)
for multiplier in (0.25, 0.3)
    haskey(ipopt_results, multiplier) || push!(failures, "Ipopt is missing multiplier $multiplier")
    haskey(madnlp_results, multiplier) || push!(failures, "MadNLP is missing multiplier $multiplier")
end

rows = Dict{String,Any}[]
for multiplier in (0.25, 0.3)
    haskey(ipopt_results, multiplier) && haskey(madnlp_results, multiplier) || continue
    ipopt_result, madnlp_result = ipopt_results[multiplier], madnlp_results[multiplier]
    ipopt_solved = get(ipopt_result, "hard_locally_solved", false)
    madnlp_solved = get(madnlp_result, "hard_locally_solved", false)
    ipopt_solved == madnlp_solved || push!(failures, "solver boundary disagreement at multiplier $multiplier")
    push!(rows, Dict{String,Any}(
        "load_multiplier" => multiplier,
        "ipopt_hard_locally_solved" => ipopt_solved,
        "madnlp_hard_locally_solved" => madnlp_solved,
        "boundary_agreement" => ipopt_solved == madnlp_solved,
        "ipopt_termination_statuses" => [get(record, "termination_status", nothing) for record in get(ipopt_result, "records", Any[])],
        "madnlp_termination_statuses" => [get(record, "termination_status", nothing) for record in get(madnlp_result, "records", Any[])],
    ))
end

length(rows) == 2 || push!(failures, "solver comparison does not cover both reviewed multipliers")
all(get(row, "boundary_agreement", false) for row in rows) || push!(failures, "solver boundary agreement is incomplete")
status = isempty(failures) ? "pass" : "fail"
write_json(OUTPUT, Dict{String,Any}(
    "schema_version" => "nlpdiagnostics-bmopf-combined-mv-lv-solver-boundary-consistency-v1",
    "status" => status,
    "solvers" => ["Ipopt", "MadNLP"],
    "multipliers" => [0.25, 0.3],
    "agreement_count" => count(get(row, "boundary_agreement", false) for row in rows),
    "rows" => rows,
    "failure_count" => length(failures),
    "failures" => failures,
    "interpretation" => "This validates shared boundary classification across two local solver backends. It does not establish solver equivalence, superiority, a physical threshold, or hard convergence beyond recorded statuses.",
))
println("wrote combined MV/LV solver-boundary consistency validation to $OUTPUT")
status == "pass" || exit(1)
