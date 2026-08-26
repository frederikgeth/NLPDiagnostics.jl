#!/usr/bin/env julia

"""Summarize the bounded LV13 MadNLP transfer guard.

This artifact records a size guard, not a solver result.  A guarded run must
remain distinguishable from failed or infeasible optimization.
"""

include(joinpath(@__DIR__, "common.jl"))
using .NLPDiagnosticsBenchmarkCommon

const ROOT = repo_root()
const INPUT = "work/bmopf-combined-mv-lv-perturbed-start-LV13_58bus-madnlp-guarded.json"
const OUTPUT = abspath(isempty(ARGS) ?
    joinpath(ROOT, "docs", "bmopf_lv13_madnlp_transfer_guard_summary.json") : ARGS[1])

source = read_summary(INPUT)
shape = get(get(source, "snapshot", Dict{String,Any}()), "network_shape", Dict{String,Any}())
budget = get(source, "budgets", Dict{String,Any}())
model_variables = get(shape, "model_variable_count", nothing)
max_variables = get(budget, "max_variables", nothing)
guarded = get(source, "status", "") == "snapshot_size_guarded" &&
    model_variables isa Number && max_variables isa Number && model_variables > max_variables &&
    isempty(get(source, "variants", Any[]))
write_json(OUTPUT, Dict{String,Any}(
    "schema_version" => "nlpdiagnostics-bmopf-lv13-madnlp-transfer-guard-v1",
    "runner" => "benchmarks/summarize_bmopf_lv13_madnlp_transfer_guard.jl",
    "status" => guarded ? "resource_guard_validated" : "guard_contract_failed",
    "solver" => "MadNLP",
    "feeder" => "LV13_58bus",
    "snapshot" => Dict(
        "model_variable_count" => model_variables,
        "source_warning_count" => get(source["snapshot"], "source_warning_count", nothing),
        "source_warning_codes" => get(source["snapshot"], "source_warning_codes", Any[]),
    ),
    "budget" => Dict(
        "max_variables" => max_variables,
        "max_iter" => get(budget, "max_iter", nothing),
        "solver_tolerance" => get(budget, "solver_tolerance", nothing),
        "variants_requested" => length(get(budget, "variants", Any[])),
    ),
    "observed" => Dict(
        "solver_runs" => 0,
        "variant_count" => length(get(source, "variants", Any[])),
        "termination_statuses" => Any[],
        "physical_endpoints_accepted" => false,
        "comparisons_qualified" => false,
    ),
    "qualification" => Dict(
        "claim" => "the LV13 MadNLP transfer is explicitly size-guarded before solver execution at 4,902 variables under a 4,000-variable budget",
        "does_not_establish" => [
            "MadNLP failure or infeasibility on LV13_58bus",
            "solver superiority or cross-feeder equivalence",
            "that the guard is sufficient for all environments",
        ],
        "next_action" => "repeat in an isolated process with an approved larger resource budget or select a smaller LV13 snapshot",
    ),
))
println("wrote LV13 MadNLP transfer guard summary to $OUTPUT")
