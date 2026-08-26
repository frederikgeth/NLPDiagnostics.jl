#!/usr/bin/env julia

"""Validate the guarded normal-eigen backend on trusted BMOPF endpoints.

This runs a predeclared 30/99/538-bus endpoint set.  It records solver-point
provenance and compares normal-eigen, dense-SVD, and sparse-QR ranks under all
four scaling policies; larger cases are size-guarded before optimization and
no physical interpretation is inferred from rank.
"""

using BMOPFTools
using Ipopt
using JuMP
using NLPDiagnostics

Base.include(@__MODULE__, joinpath(@__DIR__, "common.jl"))
using .NLPDiagnosticsBenchmarkCommon: repo_root, write_json, git_revision, git_status_entries

const DATA_ROOT = abspath(get(ENV, "NLPDIAGNOSTICS_BMOPF_BENCHMARK_ROOT",
    joinpath(repo_root(), "..", "BMOPFDraftData", "benchmarks")))
const OUTPUT = abspath(isempty(ARGS) ?
    joinpath(repo_root(), "docs", "bmopf_normal_eigen_jacobian_validation_summary.json") : ARGS[1])
const SNAPSHOTS = [
    "ENWLsnapshots/30bus_LN/30bus_LN_t01_0800.bmopf.json",
    "ENWLsnapshots/30bus_LG/30bus_LG_t01_0800.bmopf.json",
    "ENWLsnapshots/99bus_LN/99bus_LN_t01_0800.bmopf.json",
    "ENWLsnapshots/538bus_LN/538bus_LN_t01_0800.bmopf.json",
]
const POLICIES = (:none, :row, :column, :row_column)

function run_snapshot(relative)
    path = joinpath(DATA_ROOT, relative)
    isfile(path) || error("snapshot is missing: $path")
    network = BMOPFTools.parse_bmopf(path)
    context = BMOPFTools.build_opf_model(
        deepcopy(network); optimizer = Ipopt.Optimizer, add_objective = true,
    )
    BMOPFTools.enforce_kcl!(context)
    model = BMOPFTools.opf_model(context)
    JuMP.set_silent(model)
    max_variables = parse(Int, get(ENV, "NLPDIAGNOSTICS_BMOPF_NORMAL_EIGEN_MAX_VARIABLES", "5000"))
    variable_count = JuMP.num_variables(model)
    variable_count <= max_variables || return Dict{String,Any}(
        "snapshot" => relative,
        "status" => "size_guarded",
        "variable_count" => variable_count,
        "max_variables" => max_variables,
        "guard_reason" => "model variable count exceeds the pre-solve normal-eigen guard",
    )
    max_iter = parse(Int, get(ENV, "NLPDIAGNOSTICS_BMOPF_NORMAL_EIGEN_MAX_ITER", "100"))
    JuMP.set_optimizer_attribute(model, "max_iter", max_iter)
    JuMP.optimize!(model)
    point = NLPDiagnostics.solver_result_point(model; label = "normal-eigen-bmopf-result")
    point isa NLPDiagnostics.EvaluationPoint || error("solver result point unavailable")
    evaluation = NLPDiagnostics.evaluate_numerical(JuMP.backend(model), point)
    variable_count = length(evaluation.point.variables)
    records = Dict{String,Any}[]
    for policy in POLICIES
        tolerance = max(variable_count, length(evaluation.constraint_sources), 1) * eps(Float64)
        dense = NLPDiagnostics.jacobian_rank_estimate(
            evaluation; scaling = policy, relative_tolerance = tolerance,
            provenance = :bmopf_normal_eigen_validation,
        )
        sparse = NLPDiagnostics.sparse_qr_rank_estimate(
            evaluation; scaling = policy, relative_tolerance = tolerance,
        )
        normal = NLPDiagnostics.jacobian_rank_estimate(
            evaluation,
            NLPDiagnostics.RankPolicy(
                Float64; backend = :normal_eigen, scaling = policy,
                relative_tolerance = tolerance,
                provenance = :bmopf_normal_eigen_validation,
            ),
        )
        push!(records, Dict{String,Any}(
            "policy" => String(policy),
            "relative_tolerance" => tolerance,
            "dense_available" => dense.available,
            "sparse_qr_available" => sparse.available,
            "normal_eigen_available" => normal.available,
            "dense_reason" => dense.reason,
            "sparse_qr_reason" => sparse.reason,
            "normal_eigen_reason" => normal.reason,
            "dense_rank" => dense.available ? dense.rank : nothing,
            "sparse_qr_rank" => sparse.available ? sparse.rank : nothing,
            "normal_eigen_rank" => normal.available ? normal.rank : nothing,
            "dense_right_nullity" => dense.available ? dense.right_nullity : nothing,
            "normal_eigen_right_nullity" => normal.available ? normal.right_nullity : nothing,
            "cross_backend_comparison_available" => dense.available && sparse.available && normal.available,
            "cross_backend_agreement" => dense.available && sparse.available && normal.available &&
                dense.rank == sparse.rank == normal.rank,
        ))
    end
    Dict{String,Any}(
        "snapshot" => relative,
        "termination_status" => string(JuMP.termination_status(model)),
        "primal_status" => string(JuMP.primal_status(model)),
        "variable_count" => variable_count,
        "constraint_count" => length(evaluation.constraint_sources),
        "jacobian_entry_count" => length(evaluation.jacobian_entries),
        "point_provenance_kind" => string(point.provenance.kind),
        "point_provenance_complete" => point.provenance.complete,
        "policies" => records,
    )
end

results = Dict{String,Any}[]
for snapshot in SNAPSHOTS
    try
        push!(results, run_snapshot(snapshot))
    catch error
        push!(results, Dict{String,Any}("snapshot" => snapshot,
            "error" => sprint(showerror, error)))
    end
end
successful = filter(result -> haskey(result, "policies"), results)
size_guarded = filter(result -> get(result, "status", "") == "size_guarded", results)
policy_records = [record for result in successful for record in result["policies"]]
write_json(OUTPUT, Dict{String,Any}(
    "schema_version" => "nlpdiagnostics-bmopf-normal-eigen-jacobian-validation-v1",
    "source" => Dict{String,Any}(
        "runner" => "benchmarks/bmopf_normal_eigen_jacobian_validation.jl",
        "data_root" => DATA_ROOT,
        "snapshots" => SNAPSHOTS,
        "policies" => String.(POLICIES),
        "solver" => "Ipopt",
        "policy" => "Trusted solver-result points only; rank is local numerical evidence and is not a physical-mode certificate.",
    ),
    "environment" => Dict{String,Any}(
        "julia_version" => string(VERSION),
        "active_project" => Base.active_project(),
        "git_revision" => git_revision(),
        "git_worktree_dirty" => !isempty(git_status_entries()),
    ),
    "snapshot_count" => length(SNAPSHOTS),
    "successful_snapshot_count" => length(successful),
    "size_guarded_snapshot_count" => length(size_guarded),
    "policy_record_count" => length(policy_records),
    "all_policy_records_available" => all(
        record["dense_available"] && record["sparse_qr_available"] && record["normal_eigen_available"]
        for record in policy_records
    ),
    "cross_backend_agreement_count" => count(record -> record["cross_backend_agreement"], policy_records),
    "cross_backend_disagreement_count" => count(
        record -> record["cross_backend_comparison_available"] && !record["cross_backend_agreement"],
        policy_records,
    ),
    "cross_backend_unavailable_count" => count(
        record -> !record["cross_backend_comparison_available"], policy_records,
    ),
    "results" => results,
    "interpretation" => "This bounded BMOPF endpoint validation checks implementation availability and local rank agreement under explicit scaling policies. Disagreements remain evidence for follow-up; no physical or solver-superiority claim is made.",
))
println("wrote BMOPF normal-eigen Jacobian validation to $OUTPUT")
