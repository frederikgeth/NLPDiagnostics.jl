#!/usr/bin/env julia

"""Add repository-usage evidence to the root-only API tier review queue.

Usage is a prioritization signal only. It does not promote a root export into
Stable or Advanced and does not establish semantic compatibility.
"""

include(joinpath(@__DIR__, "common.jl"))
using .NLPDiagnosticsBenchmarkCommon

const ROOT = repo_root()
const OUTPUT = abspath(isempty(ARGS) ?
    joinpath(ROOT, "docs", "api_tier_usage_summary.json") : ARGS[1])
const INVENTORY = joinpath(ROOT, "docs", "api_tier_inventory_summary.json")

inventory = read_summary(INVENTORY)
root_only = String[get(row, "name", "") for row in get(get(inventory, "review", Dict{String,Any}()), "queue", Any[])]
isempty(root_only) && error("API tier inventory has no review queue")

function source_files(relative_root, suffixes)
    root = joinpath(ROOT, relative_root)
    files = String[]
    isdir(root) || return files
    for (directory, _, names) in walkdir(root)
        for name in names
            any(endswith(name, suffix) for suffix in suffixes) || continue
            push!(files, joinpath(directory, name))
        end
    end
    sort!(files)
end

function occurrence_count(content, needle)
    count = 0
    offset = firstindex(content)
    while offset <= lastindex(content)
        found = findnext(needle, content, offset)
        found === nothing && break
        start_index, end_index = first(found), last(found)
        before_ok = start_index == firstindex(content) ||
            !isletter(content[prevind(content, start_index)]) &&
            !isdigit(content[prevind(content, start_index)]) &&
            content[prevind(content, start_index)] != '_'
        after_ok = end_index == lastindex(content) ||
            !isletter(content[nextind(content, end_index)]) &&
            !isdigit(content[nextind(content, end_index)]) &&
            content[nextind(content, end_index)] != '_'
        if before_ok && after_ok
            count += 1
        end
        offset = nextind(content, end_index)
    end
    count
end

function loaded_files(relative_root, suffixes; excluded = Set{String}())
    files = source_files(relative_root, suffixes)
    [
        (relpath(path, ROOT), read(path, String))
        for path in files if relpath(path, ROOT) ∉ excluded
    ]
end

source = loaded_files("src", [".jl"]; excluded = Set([
    "src/NLPDiagnostics.jl", "src/api/stable.jl", "src/api/advanced.jl",
]))
tests = loaded_files("test", [".jl"])
benchmarks = loaded_files("benchmarks", [".jl"])
documentation = loaded_files("docs", [".md"]; excluded = Set([
    "docs/api_tier_inventory_summary.json",
]))

function usage(name, files)
    matches = Dict{String,Any}[]
    for (path, content) in files
        count = occurrence_count(content, name)
        count == 0 && continue
        push!(matches, Dict{String,Any}("path" => path, "occurrence_count" => count))
    end
    Dict{String,Any}(
        "file_count" => length(matches),
        "occurrence_count" => sum((get(match, "occurrence_count", 0) for match in matches); init = 0),
        "files" => matches,
    )
end

queue = Dict{String,Any}[]
for name in root_only
    source_usage = usage(name, source)
    test_usage = usage(name, tests)
    benchmark_usage = usage(name, benchmarks)
    documentation_usage = usage(name, documentation)
    code_file_count = source_usage["file_count"] + test_usage["file_count"] + benchmark_usage["file_count"]
    priority = test_usage["file_count"] > 0 && benchmark_usage["file_count"] > 0 ?
        "test_and_benchmark_usage" : test_usage["file_count"] > 0 ?
        "test_usage" : benchmark_usage["file_count"] > 0 ?
        "benchmark_usage" : source_usage["file_count"] > 0 ?
        "source_only" : "unreferenced_in_code"
    push!(queue, Dict{String,Any}(
        "name" => name,
        "proposed_disposition" => get(get(inventory, "review", Dict{String,Any}()), "queue", Any[])[findfirst(row -> get(row, "name", "") == name, get(get(inventory, "review", Dict{String,Any}()), "queue", Any[]))]["proposed_disposition"],
        "usage_priority" => priority,
        "source" => source_usage,
        "tests" => test_usage,
        "benchmarks" => benchmark_usage,
        "documentation" => documentation_usage,
        "code_file_count" => code_file_count,
        "has_runtime_usage_evidence" => test_usage["file_count"] > 0 || benchmark_usage["file_count"] > 0,
    ))
end

count_priority(priority) = count(row -> row["usage_priority"] == priority, queue)
write_json(OUTPUT, Dict{String,Any}(
    "schema_version" => "nlpdiagnostics-api-tier-usage-v1",
    "source" => Dict(
        "runner" => "benchmarks/audit_api_tier_usage.jl",
        "inventory" => "docs/api_tier_inventory_summary.json",
        "scanned_roots" => ["src", "test", "benchmarks", "docs"],
        "excluded_files" => ["src/NLPDiagnostics.jl", "src/api/stable.jl", "src/api/advanced.jl", "docs/api_tier_inventory_summary.json"],
    ),
    "environment" => Dict(
        "julia_version" => string(VERSION),
        "active_project" => Base.active_project(),
        "git_revision" => git_revision(),
        "git_worktree_dirty" => !isempty(git_status_entries()),
    ),
    "queue_count" => length(queue),
    "usage_priority_counts" => Dict(
        "test_and_benchmark_usage" => count_priority("test_and_benchmark_usage"),
        "test_usage" => count_priority("test_usage"),
        "benchmark_usage" => count_priority("benchmark_usage"),
        "source_only" => count_priority("source_only"),
        "unreferenced_in_code" => count_priority("unreferenced_in_code"),
    ),
    "runtime_usage_evidence_count" => count(row -> row["has_runtime_usage_evidence"], queue),
    "unreferenced_in_code_count" => count_priority("unreferenced_in_code"),
    "queue" => queue,
    "interpretation" => Dict(
        "claim" => "Repository references provide a reproducible prioritization signal for root-only API compatibility review.",
        "does_not_establish" => [
            "Stable or Advanced namespace ownership",
            "semantic compatibility or deprecation safety",
            "that an unreferenced export is safe to remove",
        ],
    ),
))
println("wrote API tier usage summary to $OUTPUT")
