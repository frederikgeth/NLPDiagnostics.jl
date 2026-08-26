#!/usr/bin/env julia

"""Repeat the normal-eigen backend across scaling policies and points.

This is a bounded numerical campaign.  Repeated calls use the same immutable
evaluation, so any change is attributable to policy or backend arithmetic;
nullspace comparisons use principal cosines rather than basis-column identity.
"""

using LinearAlgebra
using Random
import MathOptInterface as MOI
import NLPDiagnostics

include(joinpath(@__DIR__, "common.jl"))
using .NLPDiagnosticsBenchmarkCommon

const ROOT = repo_root()
const OUTPUT = abspath(isempty(ARGS) ?
    joinpath(ROOT, "docs", "normal_eigen_policy_persistence_summary.json") : ARGS[1])
const POLICIES = (:none, :row, :column, :row_column)

function evaluation(matrix, label)
    values = Float64.(matrix)
    rows, columns = size(values)
    point = NLPDiagnostics.EvaluationPoint(
        [MOI.VariableIndex(column) for column in 1:columns],
        zeros(columns); label,
    )
    entries = NLPDiagnostics.JacobianEntry{Float64}[]
    for column in axes(values, 2), row in axes(values, 1)
        iszero(values[row, column]) && continue
        push!(entries, NLPDiagnostics.JacobianEntry(row, column, values[row, column]))
    end
    NLPDiagnostics.NumericalEvaluation{Float64}(
        point, nothing, nothing, zeros(columns), zeros(rows),
        [NLPDiagnostics.EntityRef(:constraint, row) for row in 1:rows],
        entries, fill(:calibration_exact, rows),
        NLPDiagnostics.EvaluatorCapabilities[], NLPDiagnostics.EvaluationFailure[],
    )
end

function principal_cosine(left, right)
    size(left, 2) == size(right, 2) || return nothing
    iszero(size(left, 2)) && return nothing
    values = svdvals(transpose(left) * right)
    isempty(values) ? nothing : minimum(values)
end

function cases()
    duplicate = randn(MersenneTwister(20260827), 12, 8)
    duplicate[:, end] .= duplicate[:, 1]
    sparse = zeros(20, 25)
    for row in 1:20
        sparse[row, row] = 1.0
        row < 20 && (sparse[row, row + 1] = -0.2)
        sparse[row, 21 + (row % 5)] = 0.1
    end
    ill_scaled = [1.0e8 0.0 1.0e8 0.0 0.0;
                  0.0 1.0e-8 0.0 1.0e-8 0.0;
                  1.0 0.0 1.0 0.0 1.0;
                  0.0 1.0 0.0 1.0 1.0]
    [
        (name = "duplicate_column_repeat", matrix = duplicate, tolerance = 1.0e-8),
        (name = "sparse_underdetermined_repeat", matrix = sparse, tolerance = 1.0e-8),
        (name = "ill_scaled_repeat", matrix = ill_scaled, tolerance = 1.0e-10),
    ]
end

function policy_record(case, policy)
    point = evaluation(case.matrix, "$(case.name)_$(policy)")
    normal_policy = NLPDiagnostics.RankPolicy(
        Float64; backend = :normal_eigen, scaling = policy,
        relative_tolerance = case.tolerance, provenance = :policy_persistence,
    )
    normal_first = NLPDiagnostics.jacobian_rank_estimate(point, normal_policy)
    normal_second = NLPDiagnostics.jacobian_rank_estimate(point, normal_policy)
    dense = NLPDiagnostics.jacobian_rank_estimate(
        point; scaling = policy, relative_tolerance = case.tolerance,
    )
    sparse = NLPDiagnostics.sparse_qr_rank_estimate(
        point; scaling = policy, relative_tolerance = case.tolerance,
    )
    repeat_cosine = normal_first.available && normal_second.available ?
        principal_cosine(normal_first.right_nullspace, normal_second.right_nullspace) : nothing
    repeatable = normal_first.available && normal_second.available &&
        normal_first.rank == normal_second.rank &&
        (isnothing(repeat_cosine) || repeat_cosine >= 0.999999)
    cross_backend_agreement = normal_first.available && dense.available && sparse.available &&
        normal_first.rank == dense.rank == sparse.rank
    Dict{String,Any}(
        "case" => case.name,
        "policy" => String(policy),
        "rows" => size(case.matrix, 1),
        "columns" => size(case.matrix, 2),
        "normal_rank" => normal_first.available ? normal_first.rank : nothing,
        "normal_right_nullity" => normal_first.available ? normal_first.right_nullity : nothing,
        "normal_repeat_rank" => normal_second.available ? normal_second.rank : nothing,
        "dense_rank" => dense.available ? dense.rank : nothing,
        "sparse_qr_rank" => sparse.available ? sparse.rank : nothing,
        "normal_available" => normal_first.available && normal_second.available,
        "dense_available" => dense.available,
        "sparse_qr_available" => sparse.available,
        "repeat_principal_cosine" => repeat_cosine,
        "repeatable" => repeatable,
        "cross_backend_agreement" => cross_backend_agreement,
    )
end

records = Dict{String,Any}[]
for case in cases(), policy in POLICIES
    push!(records, policy_record(case, policy))
end
repeatability_failures = count(record -> !record["repeatable"], records)
cross_backend_disagreements = count(record -> !record["cross_backend_agreement"], records)
unavailable = count(record -> !record["normal_available"] ||
    !record["dense_available"] || !record["sparse_qr_available"], records)
case_summaries = Dict{String,Any}[]
for case in cases()
    subset = filter(record -> record["case"] == case.name, records)
    ranks = [record["normal_rank"] for record in subset]
    push!(case_summaries, Dict(
        "case" => case.name,
        "policy_count" => length(subset),
        "normal_rank_values" => ranks,
        "rank_stable_across_policies" => length(unique(ranks)) == 1,
        "all_policies_repeatable" => all(record["repeatable"] for record in subset),
        "all_policies_cross_backend_agree" => all(record["cross_backend_agreement"] for record in subset),
    ))
end

write_json(OUTPUT, Dict{String,Any}(
    "schema_version" => "nlpdiagnostics-normal-eigen-policy-persistence-v1",
    "source" => Dict{String,Any}(
        "runner" => "benchmarks/calibrate_normal_eigen_policy_persistence.jl",
        "backend" => "normal_eigen",
        "policies" => String.(POLICIES),
        "policy" => "Repeated same-point calls and cross-backend rank checks are bounded numerical evidence; normal-equations conditioning limitations remain explicit.",
    ),
    "environment" => Dict{String,Any}(
        "julia_version" => string(VERSION),
        "active_project" => Base.active_project(),
        "git_revision" => git_revision(),
        "git_worktree_dirty" => !isempty(git_status_entries()),
    ),
    "case_count" => length(case_summaries),
    "policy_record_count" => length(records),
    "repeatability_failure_count" => repeatability_failures,
    "cross_backend_disagreement_count" => cross_backend_disagreements,
    "unavailable_count" => unavailable,
    "case_summaries" => case_summaries,
    "records" => records,
    "interpretation" => "Same-point repeatability and policy comparisons are finite numerical evidence. Rank changes across scaling policies or disagreements with dense/QR are retained as policy sensitivity, not resolved by preference.",
))

println("wrote normal-eigen policy persistence summary to $OUTPUT")
