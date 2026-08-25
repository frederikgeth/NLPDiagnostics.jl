#!/usr/bin/env julia

"""Audit the explicit Advanced facade declaration, aliases, and typed smoke path."""

using JSON
using NLPDiagnostics

include(joinpath(@__DIR__, "common.jl"))
using .NLPDiagnosticsBenchmarkCommon

const ROOT = repo_root()
const OUTPUT = abspath(isempty(ARGS) ?
    joinpath(ROOT, "docs", "advanced_api_surface_summary.json") : ARGS[1])
const ADVANCED_MODULE = joinpath(ROOT, "src", "api", "advanced.jl")

function declared_exports(path::AbstractString)
    exports = String[]
    for line in eachline(path)
        match_result = match(r"^\s*export\s+(.+)$", line)
        isnothing(match_result) && continue
        for name in split(match_result.captures[1], ',')
            normalized = strip(name)
            isempty(normalized) || push!(exports, normalized)
        end
    end
    sort!(unique(exports))
end

declared = declared_exports(ADVANCED_MODULE)
runtime = sort!(String[
    string(name) for name in names(NLPDiagnostics.Advanced; all = false, imported = false)
    if name != :Advanced
])
root_names = Set(string.(names(NLPDiagnostics; all = false, imported = false)))
root_overlap = sort!(intersect(declared, collect(root_names)))
advanced_only = sort!(setdiff(declared, collect(root_names)))
missing_runtime = sort!(setdiff(declared, runtime))
unexpected_runtime = sort!(setdiff(runtime, declared))
alias_mismatches = String[]
for name in root_overlap
    symbol = Symbol(name)
    try
        getfield(NLPDiagnostics.Advanced, symbol) === getfield(NLPDiagnostics, symbol) ||
            push!(alias_mismatches, name)
    catch
        push!(alias_mismatches, name)
    end
end

smoke = Dict{String,Any}(
    "status" => "pass",
    "rank_policy_backend" => nothing,
    "rank_policy_provenance" => nothing,
    "unavailable_reason_code" => nothing,
    "unavailable_reason_schema_version" => nothing,
)
try
    policy = NLPDiagnostics.Advanced.RankPolicy(
        Float64;
        backend = :sparse_qr,
        compute_vectors = false,
        provenance = :advanced_api_audit,
    )
    reason = NLPDiagnostics.Advanced.UnavailableReason(
        "advanced API audit smoke reason";
        code = :advanced_api_audit,
        category = :work_guard,
        stage = :numerical,
    )
    serialized = NLPDiagnostics.Advanced.unavailable_reason_data(reason)
    smoke["rank_policy_backend"] = string(policy.backend)
    smoke["rank_policy_provenance"] = string(policy.provenance)
    smoke["unavailable_reason_code"] = serialized["code"]
    smoke["unavailable_reason_schema_version"] = serialized["schema_version"]
catch error
    smoke["status"] = "failed"
    smoke["error_type"] = string(typeof(error))
    smoke["error"] = sprint(showerror, error)
end

surface_matches = declared == runtime && isempty(missing_runtime) && isempty(unexpected_runtime)
status = surface_matches && isempty(alias_mismatches) && smoke["status"] == "pass" ?
    "pass" : "review_required"

write_json(OUTPUT, Dict{String,Any}(
    "schema_version" => "nlpdiagnostics-advanced-api-surface-v1",
    "status" => status,
    "source" => Dict(
        "runner" => "benchmarks/audit_advanced_api_surface.jl",
        "advanced_module" => "src/api/advanced.jl",
        "root_module" => "src/NLPDiagnostics.jl",
    ),
    "environment" => Dict(
        "julia_version" => string(VERSION),
        "active_project" => Base.active_project(),
        "git_revision" => git_revision(),
        "git_worktree_dirty" => !isempty(git_status_entries()),
    ),
    "declared_exports" => declared,
    "runtime_exports" => runtime,
    "declared_export_count" => length(declared),
    "runtime_export_count" => length(runtime),
    "surface_matches" => surface_matches,
    "missing_runtime_exports" => missing_runtime,
    "unexpected_runtime_exports" => unexpected_runtime,
    "root_overlap" => root_overlap,
    "advanced_only" => advanced_only,
    "alias_mismatches" => sort!(alias_mismatches),
    "smoke" => smoke,
    "interpretation" => Dict(
        "claim" => "The explicit Advanced facade declaration, runtime export set, root aliases, and typed rank-policy/unavailable-reason smoke path are auditable in the known local environment.",
        "does_not_establish" => [
            "Stable-tier compatibility for Advanced names",
            "semantic correctness of every Advanced method",
            "release readiness or numerical qualification",
        ],
    ),
))
println("wrote Advanced API surface summary to $OUTPUT")
