#!/usr/bin/env julia

"""Build an explicit review record for the declared rank-threshold policy."""

using JSON

Base.include(@__MODULE__, joinpath(@__DIR__, "common.jl"))
using .NLPDiagnosticsBenchmarkCommon: git_revision, git_status_entries, read_summary, write_json

const ROOT = abspath(joinpath(@__DIR__, ".."))
const INPUT = read_summary("docs/rank_threshold_disagreement_summary.json")
const OUTPUT = abspath(isempty(ARGS) ? joinpath(ROOT, "docs", "rank_threshold_policy_review_summary.json") : ARGS[1])

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

write_json(OUTPUT, Dict{String,Any}(
    "schema_version" => "nlpdiagnostics-rank-threshold-policy-review-v1",
    "source" => Dict{String,Any}(
        "classification_summary" => "docs/rank_threshold_disagreement_summary.json",
        "reviewer" => "pending project-owner decision",
    ),
    "environment" => Dict{String,Any}(
        "julia_version" => string(VERSION),
        "git_revision" => git_revision(),
        "git_worktree_dirty" => !isempty(git_status_entries()),
    ),
    "status" => evidence_consistent ? "review_required" : "evidence_inconsistent",
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
    "decision" => nothing,
    "interpretation" => "The evidence is internally consistent but does not select a policy decision. Near-threshold backend disagreement is not promoted to a mathematical-rank failure, and no tolerance change is authorized by this review record.",
    "next_action" => "Project owner selects one decision option and records the rationale, or supplies an independent backend qualification artifact.",
))
println("wrote rank threshold policy review summary to $OUTPUT")
