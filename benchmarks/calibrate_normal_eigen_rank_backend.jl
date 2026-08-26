#!/usr/bin/env julia

"""Calibrate the experimental normal-equations rank backend against SVD/QR.

The normal-equations path is intentionally a calibration backend: forming a
Gram matrix squares the condition number, so threshold-sensitive differences
are retained as evidence and never promoted to a default policy.
"""

using LinearAlgebra
import MathOptInterface as MOI
import NLPDiagnostics

include(joinpath(@__DIR__, "common.jl"))
using .NLPDiagnosticsBenchmarkCommon

const ROOT = repo_root()
const OUTPUT = abspath(isempty(ARGS) ?
    joinpath(ROOT, "docs", "normal_eigen_rank_calibration_summary.json") : ARGS[1])

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

const CASES = [
    (name = "identity_full_rank", matrix = Matrix(I, 3, 3), expected_rank = 3, class = "hard", tolerance = 1.0e-8),
    (name = "dependent_rows", matrix = [1.0 2.0; 2.0 4.0], expected_rank = 1, class = "hard", tolerance = 1.0e-8),
    (name = "rectangular_right_nullspace", matrix = [1.0 0.0 1.0; 0.0 1.0 1.0], expected_rank = 2, class = "hard", tolerance = 1.0e-8),
    (name = "zero_operator", matrix = zeros(2, 3), expected_rank = 0, class = "hard", tolerance = 1.0e-8),
    (name = "near_threshold", matrix = Matrix(Diagonal([1.0, 1.0e-8, 0.0])), expected_rank = 1, class = "threshold", tolerance = 1.0e-8),
    (name = "squared_condition_floor", matrix = Matrix(Diagonal([1.0, 1.0e-10])), expected_rank = 2, class = "threshold", tolerance = 1.0e-14),
]

function record(case)
    evaluation_point = evaluation(case.matrix, case.name)
    tolerance = case.tolerance
    dense = NLPDiagnostics.jacobian_rank_estimate(
        evaluation_point; relative_tolerance = tolerance,
    )
    sparse = NLPDiagnostics.sparse_qr_rank_estimate(
        evaluation_point; relative_tolerance = tolerance,
        max_dense_entries = length(case.matrix),
    )
    normal = NLPDiagnostics.jacobian_rank_estimate(
        evaluation_point,
        NLPDiagnostics.RankPolicy(
            Float64; backend = :normal_eigen,
            relative_tolerance = tolerance, provenance = :third_backend_calibration,
        ),
    )
    ranks = Dict(
        "dense_svd" => dense.available ? dense.rank : nothing,
        "sparse_qr" => sparse.available ? sparse.rank : nothing,
        "normal_eigen" => normal.available ? normal.rank : nothing,
    )
    available = all(value !== nothing for value in values(ranks))
    hard_match = case.class == "hard" && available && all(==(case.expected_rank), values(ranks))
    threshold_disagreement = case.class == "threshold" && available && length(unique(values(ranks))) > 1
    Dict{String,Any}(
        "name" => case.name,
        "rows" => size(case.matrix, 1),
        "columns" => size(case.matrix, 2),
        "class" => case.class,
        "expected_rank" => case.expected_rank,
        "ranks" => ranks,
        "all_available" => available,
        "hard_control_match" => hard_match,
        "threshold_backend_disagreement" => threshold_disagreement,
    )
end

records = [record(case) for case in CASES]
hard_records = filter(record -> record["class"] == "hard", records)
threshold_records = filter(record -> record["class"] == "threshold", records)
hard_mismatches = count(record -> !record["hard_control_match"], hard_records)
unavailable = count(record -> !record["all_available"], records)
disagreements = count(record -> record["threshold_backend_disagreement"], threshold_records)

write_json(OUTPUT, Dict{String,Any}(
    "schema_version" => "nlpdiagnostics-normal-eigen-rank-calibration-v1",
    "source" => Dict{String,Any}(
        "runner" => "benchmarks/calibrate_normal_eigen_rank_backend.jl",
        "backend" => "normal_eigen",
        "semantics" => "Eigenvalues of the scaled symmetric Gram matrix J'J are square-rooted; an explicit roundoff floor is applied before the RankPolicy threshold.",
        "policy" => "Experimental third backend for bounded cross-checks only; normal equations square the condition number and are not a production default.",
    ),
    "environment" => Dict{String,Any}(
        "julia_version" => string(VERSION),
        "active_project" => Base.active_project(),
        "git_revision" => git_revision(),
        "git_worktree_dirty" => !isempty(git_status_entries()),
    ),
    "backend" => "normal_eigen",
    "record_count" => length(records),
    "hard_control_count" => length(hard_records),
    "hard_control_mismatch_count" => hard_mismatches,
    "unavailable_count" => unavailable,
    "threshold_sensitive_count" => length(threshold_records),
    "threshold_backend_disagreement_count" => disagreements,
    "hard_controls_complete" => hard_mismatches == 0 && unavailable == 0,
    "records" => records,
    "interpretation" => "Hard controls assess exact planted rank under the declared tolerance; threshold disagreements are retained as numerical-policy evidence. This finite corpus is not a universal rank guarantee.",
))

println("wrote normal-eigen rank calibration to $OUTPUT")
