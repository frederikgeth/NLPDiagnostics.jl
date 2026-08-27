#!/usr/bin/env julia

"""Summarize the reviewed larger-iteration full combined MV/LV probe."""

using JSON

Base.include(@__MODULE__, joinpath(@__DIR__, "common.jl"))
using .NLPDiagnosticsBenchmarkCommon: git_revision, git_status_entries, write_json

length(ARGS) == 2 || error("usage: summarize_bmopf_combined_mv_lv_budget_extension.jl input.json output.json")
input_path = abspath(ARGS[1])
output_path = abspath(ARGS[2])
campaign = JSON.parsefile(input_path)
records = [record for record in get(campaign, "records", Any[]) if record isa AbstractDict]
length(records) == 3 || error("expected three policy records, found $(length(records))")

model_counts = unique(Int(record["model_variable_count"]) for record in records)
length(model_counts) == 1 || error("policy model variable counts disagree")
model_variable_count = only(model_counts)
model_variable_count == 56142 || error("unexpected combined model size: $model_variable_count")
budgets = get(campaign, "budgets", Dict{String,Any}())
get(budgets, "max_iter", 0) == 10 || error("expected the reviewed ten-iteration budget")

policy_records = [Dict{String,Any}(
    "label" => record["label"],
    "status" => record["status"],
    "model_variable_count" => record["model_variable_count"],
    "termination_status" => get(record, "termination_status", nothing),
    "primal_status" => get(record, "primal_status", nothing),
    "dual_status" => get(record, "dual_status", nothing),
    "result_count" => get(record, "result_count", nothing),
    "build_seconds" => get(record, "build_seconds", nothing),
    "solve_seconds" => get(record, "solve_seconds", nothing),
    "wall_seconds" => get(record, "wall_seconds", nothing),
) for record in records]

all_reached_solver = all(get(record, "status", "") == "solved_or_bounded" for record in records)
all_iteration_limited = all(get(record, "termination_status", "") == "ITERATION_LIMIT" for record in records)
write_json(output_path, Dict{String,Any}(
    "schema_version" => "nlpdiagnostics-bmopf-combined-mv-lv-budget-extension-v1",
    "source" => Dict{String,Any}(
        "runner" => "benchmarks/bmopf_combined_mv_lv_scaling_campaign.jl",
        "input" => input_path,
        "policy" => "Summarize the reviewed ten-iteration full-case termination evidence; do not infer convergence or scaling.",
    ),
    "environment" => Dict{String,Any}(
        "julia_version" => string(VERSION),
        "git_revision" => git_revision(),
        "git_worktree_dirty" => !isempty(git_status_entries()),
    ),
    "model_variable_count" => model_variable_count,
    "policy_count" => length(policy_records),
    "budgets" => budgets,
    "all_reached_solver" => all_reached_solver,
    "all_iteration_limited" => all_iteration_limited,
    "records" => policy_records,
    "interpretation" => "The 56,142-variable combined MV/LV model reached Ipopt for all three policies under the reviewed ten-iteration and 30-second-per-policy budget. All policies remained iteration-limited infeasible points; this is bounded termination evidence only and does not establish convergence, policy ranking, allocator peak memory, or runtime complexity.",
    "next_action" => "Run a reviewed 50-iteration full-case probe or add allocator-level peak telemetry before making a production scaling claim.",
))
println("wrote combined MV/LV budget-extension summary to $output_path")
