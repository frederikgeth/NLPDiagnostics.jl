#!/usr/bin/env julia

"""Validate the combined MV/LV hard-OPF transfer budget sweep evidence."""

using JSON

include(joinpath(@__DIR__, "common.jl"))
using .NLPDiagnosticsBenchmarkCommon: repo_root, write_json

const ROOT = repo_root()
const INPUT = abspath(isempty(ARGS) ?
    joinpath(ROOT, "docs", "bmopf_combined_mv_lv_transfer_budget_sweep_summary.json") : ARGS[1])
const OUTPUT = abspath(length(ARGS) < 2 ?
    joinpath(ROOT, "docs", "bmopf_transfer_budget_sweep_validation_summary.json") : ARGS[2])
const EXPECTED_BUDGETS = [50, 100, 200, 400]

isfile(INPUT) || error("transfer budget sweep is missing: $INPUT")
sweep = JSON.parsefile(INPUT)
failures = String[]

get(sweep, "status", nothing) == "completed" || push!(failures, "sweep status is not completed")
budgets = get(sweep, "budgets", Any[])
budgets == EXPECTED_BUDGETS || push!(failures, "budgets do not match the reviewed ladder")
results = get(sweep, "results", Any[])
length(results) == length(EXPECTED_BUDGETS) || push!(failures, "result count does not match the budget ladder")

native_by_budget = Dict{Int,Any}()
transfer_by_budget = Dict{Int,Any}()
for result in results
    result isa AbstractDict || (push!(failures, "a sweep result is not an object"); continue)
    budget = get(result, "max_iter", nothing)
    budget isa Integer || (push!(failures, "a sweep result has no integer max_iter"); continue)
    get(result, "status", nothing) == "completed" || push!(failures, "budget $budget did not complete")
    records = get(result, "records", Any[])
    records isa AbstractVector || (push!(failures, "budget $budget records are not an array"); continue)
    labels = String[]
    for record in records
        record isa AbstractDict || (push!(failures, "budget $budget contains a non-object record"); continue)
        label = get(record, "label", nothing)
        label isa AbstractString || (push!(failures, "budget $budget record has no label"); continue)
        push!(labels, String(label))
        label == "native" && (native_by_budget[Int(budget)] = record)
        label == "feasibility_voltage_transfer" && (transfer_by_budget[Int(budget)] = record)
        status = get(record, "termination_status", nothing)
        status isa AbstractString || push!(failures, "budget $budget $label record has no termination status")
    end
    sort!(labels) == ["feasibility_voltage_transfer", "native"] ||
        push!(failures, "budget $budget does not contain exactly one native and one transfer record")
end

high_budget_pair_count = 0
iteration_limited_pair_count = 0
for budget in EXPECTED_BUDGETS
    haskey(native_by_budget, budget) || push!(failures, "budget $budget is missing native evidence")
    haskey(transfer_by_budget, budget) || push!(failures, "budget $budget is missing transfer evidence")
    if haskey(native_by_budget, budget) && haskey(transfer_by_budget, budget)
        native_status = get(native_by_budget[budget], "termination_status", nothing)
        transfer_status = get(transfer_by_budget[budget], "termination_status", nothing)
        if budget >= 200 && native_status != "ITERATION_LIMIT" && transfer_status != "ITERATION_LIMIT"
            global high_budget_pair_count += 1
        end
        if native_status == "ITERATION_LIMIT" && transfer_status == "ITERATION_LIMIT"
            global iteration_limited_pair_count += 1
        end
    end
end

high_budget_pair_count > 0 || push!(failures, "no upper-budget pair escaped ITERATION_LIMIT")
status = isempty(failures) ? "pass" : "fail"
write_json(OUTPUT, Dict{String,Any}(
    "schema_version" => "nlpdiagnostics-bmopf-transfer-budget-sweep-validation-v1",
    "status" => status,
    "source" => relpath(INPUT, ROOT),
    "expected_budgets" => EXPECTED_BUDGETS,
    "validated_budget_count" => length(results),
    "high_budget_pair_count" => high_budget_pair_count,
    "iteration_limited_pair_count" => iteration_limited_pair_count,
    "failure_count" => length(failures),
    "failures" => failures,
    "interpretation" => "This validates paired native/transfer coverage and the observed upper-budget termination boundary. It does not establish hard feasibility, convergence, or a production iteration policy.",
))
println("wrote BMOPFTools transfer budget-sweep validation to $OUTPUT")
status == "pass" || exit(1)
