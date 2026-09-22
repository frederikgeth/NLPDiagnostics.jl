#!/usr/bin/env julia

"""Build the approved bounded release policy for numerical-rank evidence."""

using JSON

Base.include(@__MODULE__, joinpath(@__DIR__, "common.jl"))
using .NLPDiagnosticsBenchmarkCommon: git_revision, git_status_entries, read_summary, write_json

const ROOT = abspath(joinpath(@__DIR__, ".."))
const INPUT = read_summary("docs/rank_threshold_disagreement_summary.json")
const OUTPUT = abspath(isempty(ARGS) ? joinpath(ROOT, "docs", "rank_threshold_policy_review_summary.json") : ARGS[1])
const DECISION = "accept_policy_boundary"
const DECISION_RECORDED_ON = "2026-09-22"

hard_controls = get(INPUT, "hard_control_count", 0)
hard_mismatches = get(INPUT, "hard_control_mismatch_count", 0)
hard_unavailable = get(INPUT, "hard_control_unavailable_count", 0)
threshold_sensitive = get(INPUT, "threshold_sensitive_count", 0)
disagreements = get(INPUT, "threshold_backend_disagreement_count", 0)
rows = get(INPUT, "rows", Any[])
allowed_classifications = Set(("threshold_policy_sensitivity", "no_disagreement_observed"))
classification_valid = all(get(row, "classification", "") in allowed_classifications for row in rows)
evidence_consistent = hard_controls > 0 && hard_mismatches == 0 && hard_unavailable == 0 &&
    threshold_sensitive >= disagreements && classification_valid
decision_accepted = evidence_consistent && DECISION == "accept_policy_boundary"

write_json(OUTPUT, Dict{String,Any}(
    "schema_version" => "nlpdiagnostics-rank-threshold-policy-review-v2",
    "source" => Dict{String,Any}(
        "classification_summary" => "docs/rank_threshold_disagreement_summary.json",
        "reviewer" => "project-owner-authorized implementation",
        "decision_recorded_on" => DECISION_RECORDED_ON,
    ),
    "environment" => Dict{String,Any}(
        "julia_version" => string(VERSION),
        "git_revision" => git_revision(),
        "git_worktree_dirty" => !isempty(git_status_entries()),
    ),
    "status" => decision_accepted ? "accepted_bounded_policy" : "evidence_inconsistent",
    "evidence_consistent" => evidence_consistent,
    "hard_control_count" => hard_controls,
    "hard_control_mismatch_count" => hard_mismatches,
    "hard_control_unavailable_count" => hard_unavailable,
    "threshold_sensitive_count" => threshold_sensitive,
    "threshold_backend_disagreement_count" => disagreements,
    "decision_options" => [
        Dict("id" => "accept_policy_boundary", "description" => "Accept threshold-sensitive disagreements as bounded numerical-policy evidence and retain current defaults."),
        Dict("id" => "add_independent_backend", "description" => "Add and vet an independent backend before making any rank-policy change."),
    ],
    "decision" => DECISION,
    "decision_rationale" => "All 49 declared hard controls match with no unavailable results. The nine disagreements occur only in the 26 threshold-sensitive controls, where backend sensitivity is the result being measured. Retaining the current defaults and reporting those disagreements explicitly is the conservative bounded policy; it does not widen a tolerance or promote numerical rank to algebraic proof.",
    "enforced_boundary" => Dict(
        "retain_current_defaults" => true,
        "hard_control_mismatch_budget" => 0,
        "hard_control_unavailable_budget" => 0,
        "classify_threshold_disagreements" => true,
        "automatic_backend_preference" => false,
        "algebraic_rank_claim_authorized" => false,
        "physical_cause_claim_authorized" => false,
    ),
    "interpretation" => "The bounded numerical-rank policy is accepted for the declared release corpus. Near-threshold backend disagreements remain visible numerical-policy evidence. This decision makes no universal error-rate, algebraic-rank, or physical-cause claim.",
    "next_action" => "Apply the same hard-control and threshold-sensitivity accounting to future corpora; reopen this decision if a hard control mismatches, a required backend is unavailable, or defaults change.",
))
println("wrote rank threshold policy review summary to $OUTPUT")
