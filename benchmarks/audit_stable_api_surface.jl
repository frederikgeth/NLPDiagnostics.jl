#!/usr/bin/env julia

"""Audit the explicit Stable facade declaration, aliases, and smoke path."""

using JSON
using NLPDiagnostics
import MathOptInterface as MOI

include(joinpath(@__DIR__, "common.jl"))
using .NLPDiagnosticsBenchmarkCommon

const ROOT = repo_root()
const OUTPUT = abspath(isempty(ARGS) ?
    joinpath(ROOT, "docs", "stable_api_surface_summary.json") : ARGS[1])
const STABLE_MODULE = joinpath(ROOT, "src", "api", "stable.jl")

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

declared = declared_exports(STABLE_MODULE)
runtime = sort!(String[
    string(name) for name in names(NLPDiagnostics.Stable; all = false, imported = false)
    if name != :Stable
])
root_names = Set(string.(names(NLPDiagnostics; all = false, imported = false)))
stable_only = sort!(setdiff(declared, collect(root_names)))
root_overlap = sort!(intersect(declared, collect(root_names)))
missing_runtime = sort!(setdiff(declared, runtime))
unexpected_runtime = sort!(setdiff(runtime, declared))
alias_mismatches = String[]
for name in root_overlap
    symbol = Symbol(name)
    try
        getfield(NLPDiagnostics.Stable, symbol) === getfield(NLPDiagnostics, symbol) ||
            push!(alias_mismatches, name)
    catch
        push!(alias_mismatches, name)
    end
end

smoke = Dict{String,Any}(
    "status" => "pass",
    "model_variable_count" => 0,
    "snapshot_variable_count" => 0,
    "report_finding_count" => 0,
)
try
    model = MOI.Utilities.UniversalFallback(MOI.Utilities.Model{Float64}())
    variable = MOI.add_variable(model)
    MOI.add_constraint(
        model,
        MOI.ScalarAffineFunction([MOI.ScalarAffineTerm(1.0, variable)], 0.0),
        MOI.EqualTo(0.0),
    )
    point = NLPDiagnostics.Stable.EvaluationPoint(
        [variable], [0.0]; label = "stable-api-audit",
    )
    snapshot = NLPDiagnostics.Stable.snapshot(model)
    evaluation = NLPDiagnostics.Stable.evaluate_numerical(model, point)
    report = NLPDiagnostics.Stable.analyze(
        model;
        evaluation = evaluation,
        rank_max_dense_entries = 100,
    )
    report_data = NLPDiagnostics.Stable.report_data(report)
    smoke["model_variable_count"] = MOI.get(model, MOI.NumberOfVariables())
    smoke["snapshot_variable_count"] = length(snapshot.variables)
    smoke["report_finding_count"] = length(report)
    smoke["report_data_has_findings"] = haskey(report_data, "findings")
catch error
    smoke["status"] = "failed"
    smoke["error_type"] = string(typeof(error))
    smoke["error"] = sprint(showerror, error)
end

surface_matches = declared == runtime && isempty(missing_runtime) && isempty(unexpected_runtime)
status = surface_matches && isempty(alias_mismatches) && smoke["status"] == "pass" ?
    "pass" : "review_required"

write_json(OUTPUT, Dict{String,Any}(
    "schema_version" => "nlpdiagnostics-stable-api-surface-v1",
    "status" => status,
    "source" => Dict(
        "runner" => "benchmarks/audit_stable_api_surface.jl",
        "stable_module" => "src/api/stable.jl",
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
    "stable_only" => stable_only,
    "alias_mismatches" => sort!(alias_mismatches),
    "smoke" => smoke,
    "interpretation" => Dict(
        "claim" => "The explicit Stable facade declaration, runtime export set, root aliases, and one-variable smoke path are auditable in the known local environment.",
        "does_not_establish" => [
            "semantic compatibility for every Stable method",
            "safety of removing legacy root exports",
            "release readiness or numerical qualification",
        ],
    ),
))
println("wrote Stable API surface summary to $OUTPUT")
