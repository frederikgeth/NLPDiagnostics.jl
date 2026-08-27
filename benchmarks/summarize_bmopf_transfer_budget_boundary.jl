#!/usr/bin/env julia

"""Summarize paired termination and allocation deltas from the budget sweep."""

using JSON

include(joinpath(@__DIR__, "common.jl"))
using .NLPDiagnosticsBenchmarkCommon: repo_root, read_summary, write_json

const ROOT = repo_root()
const INPUT = abspath(isempty(ARGS) ?
    joinpath(ROOT, "docs", "bmopf_combined_mv_lv_transfer_budget_sweep_summary.json") : ARGS[1])
const OUTPUT = abspath(length(ARGS) < 2 ?
    joinpath(ROOT, "docs", "bmopf_transfer_budget_boundary_summary.json") : ARGS[2])

isfile(INPUT) || error("transfer budget sweep is missing: $INPUT")
sweep = read_summary(relpath(INPUT, ROOT))
rows = Dict{String,Any}[]
failures = String[]

for result in get(sweep, "results", Any[])
    result isa AbstractDict || (push!(failures, "a result is not an object"); continue)
    budget = get(result, "max_iter", nothing)
    records = get(result, "records", Any[])
    budget isa Integer || (push!(failures, "a result has no integer max_iter"); continue)
    native = only(filter(record -> get(record, "label", "") == "native", records))
    transfer = only(filter(record -> get(record, "label", "") == "feasibility_voltage_transfer", records))
    native_status = get(native, "termination_status", nothing)
    transfer_status = get(transfer, "termination_status", nothing)
    native_alloc = get(native, "solve_allocated_bytes", nothing)
    transfer_alloc = get(transfer, "solve_allocated_bytes", nothing)
    delta = native_alloc isa Number && transfer_alloc isa Number ? transfer_alloc - native_alloc : nothing
    classification = native_status == "ITERATION_LIMIT" && transfer_status == "ITERATION_LIMIT" ?
        "both_iteration_limited" :
        native_status != "ITERATION_LIMIT" && transfer_status != "ITERATION_LIMIT" ?
        "both_outside_iteration_limit" : "mixed_termination_boundary"
    push!(rows, Dict{String,Any}(
        "max_iter" => budget,
        "native_termination_status" => native_status,
        "transfer_termination_status" => transfer_status,
        "native_primal_status" => get(native, "primal_status", nothing),
        "transfer_primal_status" => get(transfer, "primal_status", nothing),
        "native_dual_status" => get(native, "dual_status", nothing),
        "transfer_dual_status" => get(transfer, "dual_status", nothing),
        "native_solve_allocated_bytes" => native_alloc,
        "transfer_solve_allocated_bytes" => transfer_alloc,
        "transfer_minus_native_solve_allocated_bytes" => delta,
        "termination_classification" => classification,
    ))
end

sort!(rows; by = row -> row["max_iter"])
high_budget_rows = filter(row -> row["max_iter"] >= 200, rows)
high_budget_stable = !isempty(high_budget_rows) && all(
    row["termination_classification"] == "both_outside_iteration_limit" for row in high_budget_rows
)
isempty(rows) && push!(failures, "no budget rows were summarized")
high_budget_stable || push!(failures, "upper-budget termination class is not stable")

status = isempty(failures) ? "pass" : "fail"
write_json(OUTPUT, Dict{String,Any}(
    "schema_version" => "nlpdiagnostics-bmopf-transfer-budget-boundary-v1",
    "status" => status,
    "source" => relpath(INPUT, ROOT),
    "row_count" => length(rows),
    "high_budget_row_count" => length(high_budget_rows),
    "high_budget_stable" => high_budget_stable,
    "rows" => rows,
    "failure_count" => length(failures),
    "failures" => failures,
    "interpretation" => "This summarizes observed termination classes and process-local solve allocation deltas. It does not infer infeasibility from allocation, establish convergence, or prescribe an iteration budget.",
))
println("wrote BMOPFTools transfer budget boundary summary to $OUTPUT")
status == "pass" || exit(1)
