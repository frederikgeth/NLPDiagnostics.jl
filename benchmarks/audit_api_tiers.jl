#!/usr/bin/env julia

"""Inventory root API exports against the explicit Stable and Advanced facades."""

using JSON

include(joinpath(@__DIR__, "common.jl"))
using .NLPDiagnosticsBenchmarkCommon

const ROOT = repo_root()
const OUTPUT = abspath(isempty(ARGS) ?
    joinpath(ROOT, "docs", "api_tier_inventory_summary.json") : ARGS[1])
const ROOT_MODULE = joinpath(ROOT, "src", "NLPDiagnostics.jl")
const STABLE_MODULE = joinpath(ROOT, "src", "api", "stable.jl")
const ADVANCED_MODULE = joinpath(ROOT, "src", "api", "advanced.jl")

function exported_names(path::AbstractString)
    names = String[]
    for line in eachline(path)
        match_result = match(r"^\s*export\s+(.+)$", line)
        isnothing(match_result) && continue
        for name in split(match_result.captures[1], ',')
            normalized = strip(name)
            isempty(normalized) || push!(names, normalized)
        end
    end
    return sort!(unique(names))
end

root_exports = exported_names(ROOT_MODULE)
stable_exports = exported_names(STABLE_MODULE)
advanced_exports = exported_names(ADVANCED_MODULE)
stable_overlap = sort!(intersect(root_exports, stable_exports))
advanced_overlap = sort!(intersect(root_exports, advanced_exports))
domain_extension = sort!([
    name for name in root_exports
    if startswith(name, "bmopf_") || startswith(name, "port_") ||
       startswith(name, "power_models_")
])
advanced_only = sort!(setdiff(advanced_exports, root_exports))
root_only = sort!(setdiff(root_exports, advanced_exports))
domain_extension_legacy = sort!(intersect(root_only, domain_extension))
legacy_manual_review = sort!(setdiff(root_only, domain_extension_legacy))
review_queue = [
    Dict{String,Any}(
        "name" => name,
        "current_surface" => "root-only",
        "proposed_disposition" => name in domain_extension_legacy ?
            "advanced_candidate" : "legacy_manual_review",
        "reason" => name in domain_extension_legacy ?
            "domain-extension prefix indicates research-facing adapter scope; confirm Advanced ownership before promotion" :
            "no automatic tier promotion; review compatibility, usage, and migration path before a breaking release",
    ) for name in root_only
]

summary = Dict{String,Any}(
    "schema_version" => "nlpdiagnostics-api-tier-inventory-v2",
    "status" => "inventory",
    "source" => Dict{String,Any}(
        "root_module" => relpath(ROOT_MODULE, ROOT),
        "stable_module" => relpath(STABLE_MODULE, ROOT),
        "advanced_module" => relpath(ADVANCED_MODULE, ROOT),
        "runner" => "benchmarks/audit_api_tiers.jl",
    ),
    "counts" => Dict{String,Any}(
        "root_export_count" => length(root_exports),
        "stable_export_count" => length(stable_exports),
        "stable_root_overlap_count" => length(stable_overlap),
        "advanced_export_count" => length(advanced_exports),
        "advanced_root_overlap_count" => length(advanced_overlap),
        "advanced_only_count" => length(advanced_only),
        "root_only_count" => length(root_only),
        "domain_extension_root_count" => length(domain_extension),
    ),
    "advanced_facade" => Dict{String,Any}(
        "exports" => advanced_exports,
        "root_overlap" => advanced_overlap,
        "advanced_only" => advanced_only,
    ),
    "stable_facade" => Dict{String,Any}(
        "exports" => stable_exports,
        "root_overlap" => stable_overlap,
        "stable_only" => sort!(setdiff(stable_exports, root_exports)),
    ),
    "policy" => Dict{String,Any}(
        "stable_namespace" => "NLPDiagnostics.Stable",
        "stable_contract" =>
            "new application code may depend on the Stable exports; additive fields and typed report-boundary records are allowed, while breaking signature or semantic changes require a documented release decision",
        "advanced_namespace" => "NLPDiagnostics.Advanced",
        "advanced_contract" =>
            "research-facing profiling, rank-policy, and capability APIs may evolve without Stable-tier compatibility guarantees",
        "legacy_root_contract" =>
            "root exports remain backward-compatible during consolidation; root-only exports are not implicitly Stable",
        "review_artifact" => "docs/api_stability.md",
    ),
    "domain_extension_root_exports" => domain_extension,
    "legacy_root_exports" => root_only,
    "review" => Dict{String,Any}(
        "status" => "review_required",
        "queue_count" => length(review_queue),
        "advanced_candidate_count" => length(domain_extension_legacy),
        "legacy_manual_review_count" => length(legacy_manual_review),
        "advanced_candidate_names" => domain_extension_legacy,
        "legacy_manual_review_names" => legacy_manual_review,
        "queue" => review_queue,
        "policy" => "No root-only export is promoted automatically. Advanced candidates require explicit namespace ownership and contract review; all other legacy names require compatibility and migration review.",
    ),
    "interpretation" => Dict{String,Any}(
        "claim" => "inventory of explicit Stable and Advanced aliases and domain-extension root exports",
        "does_not_establish" => [
            "that root-only exports are stable rather than legacy",
            "that an export can be removed without a compatibility policy",
            "semantic correctness of any exported function",
        ],
        "next_action" =>
            "review root-only exports and promote selected research-facing names into explicit namespaces before a breaking API release; keep Stable intentionally small",
    ),
)

write_json(OUTPUT, summary)
println("wrote API tier inventory to $OUTPUT")
