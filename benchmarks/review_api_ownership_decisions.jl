#!/usr/bin/env julia

"""Record a bounded manual review of high-impact root-only API names.

The ledger is intentionally decision-only: it does not edit exports, move
symbols, or deprecate compatibility paths. The selected names are the most
referenced runtime/test/benchmark surface and one BMOPF extension candidate.
"""

include(joinpath(@__DIR__, "common.jl"))
using .NLPDiagnosticsBenchmarkCommon

const ROOT = repo_root()
const INPUT = "docs/api_tier_usage_summary.json"
const OUTPUT = abspath(isempty(ARGS) ?
    joinpath(ROOT, "docs", "api_ownership_decision_summary.json") : ARGS[1])

const REVIEW_DECISIONS = Dict{String,Dict{String,Any}}(
    "snapshot" => Dict(
        "decision" => "retain_root_compatibility",
        "namespace_target" => "root",
        "rationale" => "Core model-boundary constructor with broad test and benchmark usage; retain until a versioned compatibility plan exists.",
    ),
    "evaluate_numerical" => Dict(
        "decision" => "retain_root_compatibility",
        "namespace_target" => "root",
        "rationale" => "Core numerical evaluation entry point used across tests and adapters; moving it would create a broad compatibility break.",
    ),
    "findings" => Dict(
        "decision" => "retain_root_compatibility",
        "namespace_target" => "root",
        "rationale" => "Report inspection helper used throughout regression assertions; retain as a compatibility surface.",
    ),
    "EvaluationPoint" => Dict(
        "decision" => "retain_root_compatibility",
        "namespace_target" => "root",
        "rationale" => "Public point type appears in model, numerical, and test contracts; no safe namespace-only migration is established.",
    ),
    "EntityRef" => Dict(
        "decision" => "retain_root_compatibility",
        "namespace_target" => "root",
        "rationale" => "Shared report identity type used by multiple subsystems; preserve root identity while the API is pre-1.0.",
    ),
    "solver_result_point" => Dict(
        "decision" => "retain_root_compatibility",
        "namespace_target" => "root",
        "rationale" => "Solver-result provenance boundary is consumed by adapters and tests; retain until solver extension ownership is reviewed.",
    ),
    "Finding" => Dict(
        "decision" => "retain_root_compatibility",
        "namespace_target" => "root",
        "rationale" => "Primary diagnostic record type with broad downstream construction and inspection; compatibility takes precedence over tier cleanup.",
    ),
    "NumericalEvaluation" => Dict(
        "decision" => "retain_root_compatibility",
        "namespace_target" => "root",
        "rationale" => "Central evaluator contract used by rank, activity, and adapter paths; no migration without a coordinated type-identity plan.",
    ),
    "DiagnosticReport" => Dict(
        "decision" => "retain_root_compatibility",
        "namespace_target" => "root",
        "rationale" => "Top-level report container used by all analysis entry points; root identity is part of the current compatibility contract.",
    ),
    "evaluation_point_fingerprint" => Dict(
        "decision" => "retain_root_compatibility",
        "namespace_target" => "root",
        "rationale" => "Provenance helper is used by reproducibility and cross-check ledgers; retain while artifact schemas remain v1-compatible.",
    ),
    "Evidence" => Dict(
        "decision" => "retain_root_compatibility",
        "namespace_target" => "root",
        "rationale" => "Evidence record is shared by renderer-neutral reports and tests; do not split ownership without a report-schema review.",
    ),
    "bmopf_start_completion_point" => Dict(
        "decision" => "advanced_candidate_review",
        "namespace_target" => "Advanced",
        "rationale" => "BMOPFTools-specific lifecycle helper is a plausible Advanced candidate, but adapter ownership and compatibility still require explicit review.",
    ),
)

queue = read_summary(INPUT)["queue"]
rows = Dict{String,Any}[]
for (name, decision) in REVIEW_DECISIONS
    matches = filter(row -> get(row, "name", "") == name, queue)
    length(matches) == 1 || error("expected one queue row for reviewed name $name")
    source = only(matches)
    push!(rows, merge(
        Dict{String,Any}(
            "name" => name,
            "usage_priority" => source["usage_priority"],
            "code_file_count" => source["code_file_count"],
            "has_runtime_usage_evidence" => source["has_runtime_usage_evidence"],
            "proposed_disposition" => source["proposed_disposition"],
            "migration_allowed" => false,
            "review_status" => "reviewed_local",
        ),
        decision,
    ))
end
sort!(rows; by = row -> row["name"])
status_entries = git_status_entries()
write_json(OUTPUT, Dict{String,Any}(
    "schema_version" => "nlpdiagnostics-api-ownership-decisions-v1",
    "source" => Dict{String,Any}(
        "runner" => "benchmarks/review_api_ownership_decisions.jl",
        "input" => INPUT,
        "selection_policy" => "Highest repository-usage root-only names plus one BMOPF Advanced candidate; this bounded review does not represent the full queue.",
        "migration_policy" => "No export is moved, deprecated, or removed by this ledger.",
    ),
    "environment" => Dict{String,Any}(
        "julia_version" => string(VERSION),
        "active_project" => Base.active_project(),
        "git_revision" => git_revision(),
        "git_worktree_dirty" => !isempty(status_entries),
    ),
    "reviewed_count" => length(rows),
    "root_compatibility_retained_count" => count(row -> row["decision"] == "retain_root_compatibility", rows),
    "advanced_candidate_count" => count(row -> row["decision"] == "advanced_candidate_review", rows),
    "migration_allowed_count" => count(row -> row["migration_allowed"], rows),
    "rows" => rows,
    "next_actions" => [
        "Review the remaining root-only queue in similarly bounded batches.",
        "Approve any namespace move only with an explicit compatibility and type-identity plan.",
        "Keep Stable and Advanced facades unchanged until ownership review is complete.",
    ],
    "interpretation" => Dict{String,Any}(
        "claim" => "Twelve high-impact root-only names now have explicit local ownership decisions; all remain non-migrating compatibility decisions except one Advanced candidate review.",
        "does_not_establish" => [
            "a complete review of all root-only exports",
            "permission to remove or deprecate root symbols",
            "Stable or Advanced namespace compatibility for future releases",
        ],
    ),
))

println("wrote API ownership decision summary to $OUTPUT")
