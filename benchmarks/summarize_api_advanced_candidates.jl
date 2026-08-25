#!/usr/bin/env julia

"""Summarize Advanced API candidates into reviewable ownership batches.

The name-family buckets are triage hints, not namespace assignments.  A
candidate remains root-only until an explicit compatibility and ownership
decision is made.
"""

include(joinpath(@__DIR__, "common.jl"))
using .NLPDiagnosticsBenchmarkCommon

const ROOT = repo_root()
const INPUT = "docs/api_tier_usage_summary.json"
const OUTPUT = abspath(isempty(ARGS) ?
    joinpath(ROOT, "docs", "api_advanced_candidate_summary.json") : ARGS[1])

const PRIORITIES = [
    "test_and_benchmark_usage",
    "test_usage",
    "benchmark_usage",
    "source_only",
    "unreferenced_in_code",
]

function candidate_family(name)
    startswith(name, "bmopf_") && return "bmopf_extension"
    startswith(name, "port_") && return "port_extension"
    return "other_advanced"
end

usage = read_summary(INPUT)
queue = get(usage, "queue", Any[])
candidates = filter(row -> get(row, "proposed_disposition", "") == "advanced_candidate", queue)
length(candidates) == 102 || error("expected 102 Advanced candidates, found $(length(candidates))")

families = sort!(unique(candidate_family(row["name"]) for row in candidates))
family_buckets = Dict{String,Any}(
    family => [
        Dict(
            "name" => row["name"],
            "usage_priority" => row["usage_priority"],
            "code_file_count" => row["code_file_count"],
            "has_runtime_usage_evidence" => row["has_runtime_usage_evidence"],
        )
        for row in candidates if candidate_family(row["name"]) == family
    ] for family in families
)
for bucket in values(family_buckets)
    sort!(bucket; by = row -> row["name"])
end

family_priority_matrix = Dict{String,Any}(
    family => Dict(
        priority => count(row -> candidate_family(row["name"]) == family &&
            row["usage_priority"] == priority, candidates)
        for priority in PRIORITIES
    ) for family in families
)

review_batches = [
    Dict(
        "family" => family,
        "usage_priority" => priority,
        "candidate_count" => family_priority_matrix[family][priority],
        "reason" => priority == "test_and_benchmark_usage" ?
            "Highest repository evidence; review ownership before any facade promotion." :
            "Retain as a later manual review batch; usage evidence alone does not establish compatibility.",
    )
    for family in families for priority in PRIORITIES
    if family_priority_matrix[family][priority] > 0
]

write_json(OUTPUT, Dict{String,Any}(
    "schema_version" => "nlpdiagnostics-api-advanced-candidates-v1",
    "source" => Dict(
        "runner" => "benchmarks/summarize_api_advanced_candidates.jl",
        "usage_artifact" => INPUT,
        "policy" => "Family and usage buckets order review only; no candidate is promoted, deprecated, or removed automatically.",
    ),
    "environment" => Dict(
        "julia_version" => string(VERSION),
        "active_project" => Base.active_project(),
        "git_revision" => git_revision(),
        "git_worktree_dirty" => !isempty(git_status_entries()),
    ),
    "candidate_count" => length(candidates),
    "family_counts" => Dict(family => length(family_buckets[family]) for family in families),
    "family_priority_matrix" => family_priority_matrix,
    "family_buckets" => family_buckets,
    "review_batches" => review_batches,
    "interpretation" => Dict(
        "claim" => "The 102 Advanced candidates are grouped into deterministic BMOPF and port-extension review batches.",
        "does_not_establish" => [
            "Stable or Advanced namespace ownership",
            "semantic compatibility or deprecation safety",
            "that repository usage justifies automatic promotion",
        ],
    ),
))
println("wrote Advanced API candidate summary to $OUTPUT")
