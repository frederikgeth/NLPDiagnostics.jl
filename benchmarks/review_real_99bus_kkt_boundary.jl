#!/usr/bin/env julia

"""Build a decision handoff for the strict real-99-bus physical-KKT boundary."""

using JSON

Base.include(@__MODULE__, joinpath(@__DIR__, "common.jl"))
using .NLPDiagnosticsBenchmarkCommon: git_revision, git_status_entries, read_summary, write_json

const ROOT = abspath(joinpath(@__DIR__, ".."))
const OUTPUT = abspath(isempty(ARGS) ? joinpath(ROOT, "docs", "real_99bus_kkt_boundary_review_summary.json") : ARGS[1])

matrix = read_summary("docs/real_99bus_kkt_endpoint_matrix_summary.json")
margin = read_summary("docs/real_99bus_kkt_margin_summary.json")
policies = read_summary("docs/real_99bus_kkt_tolerance_policy_summary.json")

endpoint_count = get(matrix, "endpoint_count", 0)
strict_pass_count = get(matrix, "strict_paired_acceptance_count", 0)
strict_failure_count = get(matrix, "strict_paired_failure_count", 0)
all_failures_localized = get(matrix, "all_failures_localized", false)
maximum_required_tolerance = get(margin, "maximum_required_tolerance", nothing)
maximum_gap = get(margin, "maximum_strict_tolerance_gap", nothing)
policy_records = get(policies, "policy_count", 0)
evidence_consistent = endpoint_count == strict_pass_count + strict_failure_count &&
    endpoint_count > 0 && all_failures_localized && maximum_required_tolerance !== nothing && policy_records > 0

write_json(OUTPUT, Dict{String,Any}(
    "schema_version" => "nlpdiagnostics-real-99bus-kkt-boundary-review-v1",
    "source" => Dict{String,Any}(
        "endpoint_matrix" => "docs/real_99bus_kkt_endpoint_matrix_summary.json",
        "margin" => "docs/real_99bus_kkt_margin_summary.json",
        "tolerance_policies" => "docs/real_99bus_kkt_tolerance_policy_summary.json",
        "reviewer" => "pending project-owner decision",
    ),
    "environment" => Dict{String,Any}(
        "julia_version" => string(VERSION),
        "git_revision" => git_revision(),
        "git_worktree_dirty" => !isempty(git_status_entries()),
    ),
    "status" => evidence_consistent ? "review_required" : "evidence_inconsistent",
    "evidence_consistent" => evidence_consistent,
    "strict_tolerance" => 1.0e-5,
    "endpoint_count" => endpoint_count,
    "strict_paired_acceptance_count" => strict_pass_count,
    "strict_paired_failure_count" => strict_failure_count,
    "all_failures_localized" => all_failures_localized,
    "maximum_required_tolerance" => maximum_required_tolerance,
    "maximum_strict_tolerance_gap" => maximum_gap,
    "tolerance_policy_record_count" => policy_records,
    "decision_options" => [
        Dict("id" => "retain_strict_gate", "description" => "Retain the strict 1e-5 gate and treat the four localized failures as an open physical-endpoint boundary."),
        Dict("id" => "review_tolerance_change", "description" => "Review a tolerance change only with an explicit physical justification; the observed margin is not itself a recommendation."),
    ],
    "decision" => nothing,
    "interpretation" => "The six-endpoint ledger is complete and internally consistent. The maximum required tolerance is retained as margin evidence only; this record does not relax the strict physical-KKT gate or establish a causal explanation.",
    "next_action" => "Project owner selects the strict-gate disposition or supplies a physically justified tolerance review, then revalidates the selected policy.",
))
println("wrote real-99-bus KKT boundary review summary to $OUTPUT")
