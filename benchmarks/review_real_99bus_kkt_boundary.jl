#!/usr/bin/env julia

"""Build the approved bounded policy for the real-99-bus physical-KKT boundary."""

using JSON

Base.include(@__MODULE__, joinpath(@__DIR__, "common.jl"))
using .NLPDiagnosticsBenchmarkCommon: git_revision, git_status_entries, read_summary, write_json

const ROOT = abspath(joinpath(@__DIR__, ".."))
const OUTPUT = abspath(isempty(ARGS) ? joinpath(ROOT, "docs", "real_99bus_kkt_boundary_review_summary.json") : ARGS[1])
const DECISION = "retain_strict_gate"
const DECISION_RECORDED_ON = "2026-09-22"

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
decision_accepted = evidence_consistent && DECISION == "retain_strict_gate"

write_json(OUTPUT, Dict{String,Any}(
    "schema_version" => "nlpdiagnostics-real-99bus-kkt-boundary-review-v2",
    "source" => Dict{String,Any}(
        "endpoint_matrix" => "docs/real_99bus_kkt_endpoint_matrix_summary.json",
        "margin" => "docs/real_99bus_kkt_margin_summary.json",
        "tolerance_policies" => "docs/real_99bus_kkt_tolerance_policy_summary.json",
        "reviewer" => "project-owner-authorized implementation",
        "decision_recorded_on" => DECISION_RECORDED_ON,
    ),
    "environment" => Dict{String,Any}(
        "julia_version" => string(VERSION),
        "git_revision" => git_revision(),
        "git_worktree_dirty" => !isempty(git_status_entries()),
    ),
    "status" => decision_accepted ? "accepted_bounded_boundary" : "evidence_inconsistent",
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
    "decision" => DECISION,
    "decision_rationale" => "The strict 1e-5 diagnostic threshold remains unchanged. All six paired endpoints are locally solved, the four strict failures are consistently localized to ibr_p_upper, and the reference/phase-only residual ratios are near one. The release policy accepts this result as an explicit bounded limitation; it does not claim that the four endpoints pass or infer a physical cause from the observed residual floor.",
    "enforced_boundary" => Dict(
        "retain_strict_tolerance" => true,
        "strict_endpoint_gate_passed" => strict_failure_count == 0,
        "release_boundary_accepted" => decision_accepted,
        "automatic_tolerance_relaxation" => false,
        "physical_kkt_acceptance_claim_authorized" => false,
        "residual_floor_causal_claim_authorized" => false,
        "future_endpoint_failures_must_remain_visible" => true,
    ),
    "interpretation" => "The six-endpoint ledger is complete and internally consistent. The retained 1e-5 threshold passes two paired endpoints and fails four; accepting the bounded release boundary does not convert those failures into strict acceptances. The 1.2e-5 sensitivity result remains margin evidence only, and no causal explanation is established.",
    "next_action" => "Apply the retained strict threshold to future endpoint corpora and reopen this decision if localization changes, evidence becomes incomplete, or a physical-KKT acceptance claim is required.",
))
println("wrote real-99-bus KKT boundary review summary to $OUTPUT")
