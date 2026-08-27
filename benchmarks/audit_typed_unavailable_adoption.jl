#!/usr/bin/env julia

"""Audit typed unavailable-reason adoption across source adapters.

This is a source-boundary inventory, not a correctness score. It records the
typed constructor/serializer calls and metadata writes that capability and
work-guard adapters use so the migration from ad-hoc strings stays measurable.
"""

using JSON

include(joinpath(@__DIR__, "common.jl"))
using .NLPDiagnosticsBenchmarkCommon

const ROOT = repo_root()
const OUTPUT = abspath(isempty(ARGS) ?
    joinpath(ROOT, "docs", "typed_unavailable_adoption_summary.json") : ARGS[1])

source_files = recursive_files(joinpath(ROOT, "src"), ".jl")
relative(path) = relpath(path, ROOT)

typed_constructor_files = String[]
typed_serializer_files = String[]
metadata_reason_files = String[]
capability_or_guard_files = String[]
constructor_call_count = 0
serializer_call_count = 0
metadata_reason_write_count = 0
bare_catch_count = 0
bound_catch_count = 0

for path in source_files
    text = read_text(path)
    constructors = length(collect(eachmatch(r"typed_reason\s*=\s*unavailable_reason\(", text)))
    serializers = length(collect(eachmatch(r"unavailable_reason_data\(", text)))
    metadata_writes = length(collect(eachmatch(r"metadata[^\n]*unavailable_reason", text)))
    bare_catches = length(collect(eachmatch(r"catch\s*(?:\n|$)", text)))
    bound_catches = length(collect(eachmatch(r"catch\s+[A-Za-z_]\w*", text)))
    global constructor_call_count += constructors
    global serializer_call_count += serializers
    global metadata_reason_write_count += metadata_writes
    global bare_catch_count += bare_catches
    global bound_catch_count += bound_catches
    constructors > 0 && push!(typed_constructor_files, relative(path))
    serializers > 0 && push!(typed_serializer_files, relative(path))
    metadata_writes > 0 && push!(metadata_reason_files, relative(path))
    (occursin("capability", lowercase(text)) || occursin("work_guard", lowercase(text))) &&
        occursin("unavailable_reason", text) && push!(capability_or_guard_files, relative(path))
end

sort!(typed_constructor_files)
sort!(typed_serializer_files)
sort!(metadata_reason_files)
sort!(capability_or_guard_files)

write_json(OUTPUT, Dict{String,Any}(
    "schema_version" => "nlpdiagnostics-typed-unavailable-adoption-v1",
    "source" => Dict(
        "runner" => "benchmarks/audit_typed_unavailable_adoption.jl",
        "root" => "src",
        "policy" => "Count explicit typed unavailable-reason boundaries without changing legacy report layouts or inferring adapter correctness from source counts.",
    ),
    "environment" => Dict(
        "julia_version" => string(VERSION),
        "active_project" => Base.active_project(),
        "git_revision" => git_revision(),
        "git_worktree_dirty" => !isempty(git_status_entries()),
    ),
    "source_file_count" => length(source_files),
    "typed_constructor_call_count" => constructor_call_count,
    "typed_serializer_call_count" => serializer_call_count,
    "metadata_unavailable_reason_write_count" => metadata_reason_write_count,
    "bare_catch_count" => bare_catch_count,
    "bound_catch_count" => bound_catch_count,
    "typed_constructor_files" => typed_constructor_files,
    "typed_serializer_files" => typed_serializer_files,
    "metadata_reason_files" => metadata_reason_files,
    "capability_or_work_guard_files" => capability_or_guard_files,
    "status" => "partial",
    "interpretation" => Dict(
        "claim" => "Typed unavailable-reason construction and serialization are explicitly inventoried across source adapters; metadata writes remain a compatibility boundary.",
        "does_not_establish" => [
            "semantic correctness of every capability or work-guard adapter",
            "that legacy report layouts can be changed without review",
            "release readiness or CI execution",
        ],
    ),
    "next_actions" => [
        "Keep new capability and work-guard adapters on the typed unavailable-reason path.",
        "Review remaining metadata-only boundaries before changing report schemas.",
        "Re-run this audit when adapter ownership or the BMOPFTools contract changes.",
    ],
))
println("wrote typed unavailable-reason adoption audit to $OUTPUT")
