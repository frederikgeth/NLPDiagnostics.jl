#!/usr/bin/env julia

"""Aggregate the root-only API review queue into actionable triage buckets."""

include(joinpath(@__DIR__, "common.jl"))
using .NLPDiagnosticsBenchmarkCommon

const ROOT = repo_root()
const INPUT = "docs/api_tier_usage_summary.json"
const OUTPUT = abspath(isempty(ARGS) ?
    joinpath(ROOT, "docs", "api_migration_queue_summary.json") : ARGS[1])

usage = read_summary(INPUT)
queue = get(usage, "queue", Any[])
isempty(queue) && error("API tier usage summary has no review queue")

priorities = [
    "test_and_benchmark_usage",
    "test_usage",
    "benchmark_usage",
    "source_only",
    "unreferenced_in_code",
]
dispositions = ["advanced_candidate", "legacy_manual_review"]

matrix = Dict{String,Any}()
for disposition in dispositions
    matrix[disposition] = Dict(
        priority => count(row ->
            get(row, "proposed_disposition", "") == disposition &&
            get(row, "usage_priority", "") == priority, queue)
        for priority in priorities
    )
end

priority_buckets = Dict{String,Any}(
    priority => [
        Dict(
            "name" => row["name"],
            "proposed_disposition" => row["proposed_disposition"],
            "code_file_count" => row["code_file_count"],
            "has_runtime_usage_evidence" => row["has_runtime_usage_evidence"],
        )
        for row in queue if row["usage_priority"] == priority
    ] for priority in priorities
)
for bucket in values(priority_buckets)
    sort!(bucket; by = row -> row["name"])
end

runtime_evidence_count = get(usage, "runtime_usage_evidence_count", 0)
unreferenced_names = [row["name"] for row in queue if row["usage_priority"] == "unreferenced_in_code"]

write_json(OUTPUT, Dict{String,Any}(
    "schema_version" => "nlpdiagnostics-api-migration-queue-v1",
    "source" => Dict(
        "runner" => "benchmarks/summarize_api_migration_queue.jl",
        "usage_artifact" => INPUT,
        "policy" => "Usage priority orders review effort only; no root-only export is promoted, deprecated, or removed automatically.",
    ),
    "environment" => Dict(
        "julia_version" => string(VERSION),
        "active_project" => Base.active_project(),
        "git_revision" => git_revision(),
        "git_worktree_dirty" => !isempty(git_status_entries()),
    ),
    "queue_count" => length(queue),
    "runtime_usage_evidence_count" => runtime_evidence_count,
    "unreferenced_in_code_count" => length(unreferenced_names),
    "disposition_usage_matrix" => matrix,
    "priority_counts" => Dict(
        priority => length(priority_buckets[priority]) for priority in priorities
    ),
    "priority_buckets" => priority_buckets,
    "unreferenced_names" => sort!(unreferenced_names),
    "recommended_review_order" => priorities,
    "interpretation" => Dict(
        "claim" => "The 539 root-only exports are grouped by proposed disposition and repository-usage priority for deterministic review triage.",
        "does_not_establish" => [
            "Stable or Advanced namespace ownership",
            "semantic compatibility or deprecation safety",
            "that an unreferenced export is safe to remove",
        ],
    ),
))
println("wrote API migration queue summary to $OUTPUT")
