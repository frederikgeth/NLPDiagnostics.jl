#!/usr/bin/env julia

"""
Audit API, test, and benchmark consolidation boundaries without mutating code.

The output is an inventory and gap report, not a quality score. It is intended
to make the consolidation gate measurable before any export or namespace
changes are made.
"""

using JSON

include(joinpath(@__DIR__, "common.jl"))
using .NLPDiagnosticsBenchmarkCommon

const REPO_ROOT = repo_root()
const OUTPUT = abspath(isempty(ARGS) ?
    joinpath(REPO_ROOT, "docs", "api_test_benchmark_consolidation_summary.json") :
    ARGS[1])

function matching_lines(path::AbstractString, pattern::Regex)
    [line for line in eachline(path) if occursin(pattern, line)]
end

function relative_paths(paths)
    [relpath(path, REPO_ROOT) for path in paths]
end

root_module = joinpath(REPO_ROOT, "src", "NLPDiagnostics.jl")
root_lines = readlines(root_module)
export_names = String[]
for line in root_lines
    match_result = match(r"^\s*export\s+([A-Za-z_][A-Za-z0-9_!]*)", line)
    isnothing(match_result) || push!(export_names, match_result.captures[1])
end

source_files = recursive_files(joinpath(REPO_ROOT, "src"), ".jl")
test_files = recursive_files(joinpath(REPO_ROOT, "test"), ".jl")
benchmark_files = filter(
    path -> basename(path) != "common.jl",
    recursive_files(joinpath(REPO_ROOT, "benchmarks"), ".jl"),
)
json_files = recursive_files(joinpath(REPO_ROOT, "docs"), ".json")

source_includes = String[]
for line in root_lines
    match_result = match(r"include\(\"([^\"]+)\"\)", line)
    isnothing(match_result) || push!(source_includes, match_result.captures[1])
end
test_root = joinpath(REPO_ROOT, "test", "runtests.jl")
test_includes = String[]
for line in readlines(test_root)
    match_result = match(r"include\(\"([^\"]+)\"\)", line)
    isnothing(match_result) || push!(test_includes, match_result.captures[1])
end

schema_files = String[]
schema_errors = Dict{String,String}[]
for path in json_files
    try
        parsed = JSON.parsefile(path)
        if parsed isa AbstractDict && haskey(parsed, "schema_version")
            push!(schema_files, path)
        end
    catch error
        push!(schema_errors, Dict(
            "path" => relpath(path, REPO_ROOT),
            "error_type" => string(typeof(error)),
        ))
    end
end

benchmark_schema_files = [
    path for path in benchmark_files if occursin("schema_version", read_text(path))
]
source_text = join(read_text.(source_files), "\n")
benchmark_text = join(read_text.(benchmark_files), "\n")
bare_catch_count = count(line -> occursin(r"^\s*catch\s*$", line),
    split(source_text, '\n'))
bound_catch_count = count(line -> occursin(r"^\s*catch\s+\w+", line),
    split(source_text, '\n'))
typed_unavailable_tokens = [
    token for token in ("UnavailableReason", "CapabilityUnavailable", "TypedUnavailable")
    if occursin(token, source_text)
]
typed_adapter_call_count = count(
    line -> occursin(r"unavailable_reason\(", line),
    split(source_text * "\n" * benchmark_text, '\n'),
)
namespace_tokens = [
    token for token in ("module Advanced", "module Experimental", "module Research")
    if occursin(token, source_text)
]
testset_count = count(line -> occursin("@testset", line), readlines(test_root))

function export_bucket(name::String)
    startswith(name, "bmopf_") && return "domain_extension"
    startswith(name, "profile") || occursin("Profile", name) && return "profiling"
    startswith(name, "solver") || occursin("Solver", name) && return "solver_extension"
    startswith(name, "scaling") || occursin("Scaling", name) && return "scaling"
    startswith(name, "structural") || occursin("Structural", name) && return "structural"
    return "core_or_unclassified"
end

export_buckets = Dict{String,Int}()
for name in export_names
    bucket = export_bucket(name)
    export_buckets[bucket] = get(export_buckets, bucket, 0) + 1
end

summary = Dict{String,Any}(
    "schema_version" => "nlpdiagnostics-api-test-benchmark-consolidation-v1",
    "source" => Dict(
        "runner" => "benchmarks/audit_api_test_benchmark_consolidation.jl",
        "root_module" => "src/NLPDiagnostics.jl",
        "test_root" => "test/runtests.jl",
    ),
    "api_inventory" => Dict(
        "root_export_count" => length(export_names),
        "root_export_names" => sort(unique(export_names)),
        "export_buckets" => export_buckets,
        "advanced_or_experimental_namespace_count" => length(namespace_tokens),
        "advanced_or_experimental_namespace_tokens" => namespace_tokens,
    ),
    "module_boundaries" => Dict(
        "source_file_count" => length(source_files),
        "source_include_count" => length(source_includes),
        "source_includes" => source_includes,
        "test_file_count" => length(test_files),
        "test_include_count" => length(test_includes),
        "test_includes" => test_includes,
        "testset_count_in_root" => testset_count,
        "benchmark_script_count" => length(benchmark_files),
        "shared_benchmark_helper" => "benchmarks/common.jl",
    ),
    "benchmark_schema_inventory" => Dict(
        "json_file_count" => length(json_files),
        "json_schema_file_count" => length(schema_files),
        "json_without_schema_count" => length(json_files) - length(schema_files),
        "schema_errors" => schema_errors,
        "benchmark_scripts_with_schema_version_count" => length(benchmark_schema_files),
    ),
    "typed_unavailable_audit" => Dict(
        "explicit_typed_unavailable_token_count" => length(typed_unavailable_tokens),
        "explicit_typed_unavailable_tokens" => typed_unavailable_tokens,
        "typed_adapter_call_count" => typed_adapter_call_count,
        "bare_catch_count_in_source" => bare_catch_count,
        "bound_catch_count_in_source" => bound_catch_count,
    ),
    "interpretation" => Dict(
        "status" => "partial",
        "finding" =>
            "The repository has broad root exports and split implementation files. A typed unavailable-reason schema now exists at the report boundary, while explicit advanced namespaces and broad adapter adoption are not yet complete.",
        "completed_evidence" => [
            "root export inventory",
            "source and test include boundaries",
            "benchmark JSON schema coverage",
            "source catch-boundary inventory",
        ],
        "remaining_work" => [
            "define and document stable versus advanced/experimental API tiers",
            "adopt typed unavailable reasons across capability and work-guard adapters without changing legacy result layouts accidentally",
            "migrate the remaining runners to benchmarks/common.jl",
            "add reviewed formatting, documentation-example, Aqua, and targeted JET policies",
        ],
        "does_not_establish" => [
            "API compatibility across a future namespace refactor",
            "quality or correctness from export counts alone",
            "CI readiness or GitHub Actions execution",
        ],
    ),
)

mkpath(dirname(OUTPUT))
open(OUTPUT, "w") do io
    JSON.print(io, summary, 2)
    write(io, '\n')
end
println("wrote API/test/benchmark consolidation summary to $OUTPUT")
