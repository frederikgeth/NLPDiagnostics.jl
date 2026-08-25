#!/usr/bin/env julia

"""Calibrate rank backends on deterministic scaled and dependency-rich matrices."""

using LinearAlgebra
import MathOptInterface as MOI
import NLPDiagnostics

include(joinpath(@__DIR__, "common.jl"))
using .NLPDiagnosticsBenchmarkCommon

const ROOT = repo_root()
const OUTPUT = abspath(isempty(ARGS) ?
    joinpath(ROOT, "docs", "rank_adversarial_extension_summary.json") : ARGS[1])
const RELATIVE_TOLERANCE = 1.0e-8

function evaluation(matrix, label)
    rows, columns = size(matrix)
    variables = [MOI.VariableIndex(column) for column in 1:columns]
    point = NLPDiagnostics.EvaluationPoint(variables, zeros(columns); label)
    entries = NLPDiagnostics.JacobianEntry{Float64}[]
    for column in axes(matrix, 2), row in axes(matrix, 1)
        value = Float64(matrix[row, column])
        iszero(value) || push!(entries, NLPDiagnostics.JacobianEntry(row, column, value))
    end
    NLPDiagnostics.NumericalEvaluation{Float64}(
        point, nothing, nothing,
        Union{Missing,Float64}[0.0 for _ in 1:columns],
        Union{Missing,Float64}[0.0 for _ in 1:rows],
        [NLPDiagnostics.EntityRef(:constraint, row) for row in 1:rows],
        entries, fill(:rank_adversarial_extension, rows),
        NLPDiagnostics.EvaluatorCapabilities[], NLPDiagnostics.EvaluationFailure[],
    )
end

function policy_rank(matrix)
    values = svdvals(matrix)
    isempty(values) && return 0
    threshold = RELATIVE_TOLERANCE * maximum(abs, values)
    count(value -> abs(value) > threshold, values)
end

function record(name, matrix, oracle_class, hard_expectation)
    expected = policy_rank(matrix)
    eval = evaluation(matrix, name)
    dense_policy = NLPDiagnostics.RankPolicy(Float64;
        backend = :dense_svd, scaling = :none,
        relative_tolerance = RELATIVE_TOLERANCE,
        compute_vectors = false, max_dense_entries = length(matrix),
        provenance = :rank_adversarial_extension)
    sparse_policy = NLPDiagnostics.RankPolicy(Float64;
        backend = :sparse_qr, scaling = :none,
        relative_tolerance = RELATIVE_TOLERANCE,
        compute_vectors = false, max_dense_entries = length(matrix),
        provenance = :rank_adversarial_extension)
    dense = NLPDiagnostics.jacobian_rank_estimate(eval, dense_policy)
    sparse = NLPDiagnostics.sparse_qr_rank_estimate(eval, sparse_policy)
    dense_match = dense.available && dense.rank == expected
    sparse_match = sparse.available && sparse.rank == expected
    Dict{String,Any}(
        "name" => name,
        "oracle_class" => oracle_class,
        "rows" => size(matrix, 1),
        "columns" => size(matrix, 2),
        "policy_expected_rank" => expected,
        "relative_tolerance" => RELATIVE_TOLERANCE,
        "hard_expectation" => hard_expectation,
        "dense_available" => dense.available,
        "dense_rank" => dense.rank,
        "dense_match" => dense_match,
        "sparse_available" => sparse.available,
        "sparse_rank" => sparse.rank,
        "sparse_match" => sparse_match,
        "backend_rank_relation" => dense.available && sparse.available ?
            (dense.rank == sparse.rank ? "agreement" : "disagreement") : "unavailable",
        "expectation_matched" => dense_match && sparse_match,
        "claim_level" => oracle_class == "threshold_sensitive" ?
            "numerical policy sensitivity" : "deterministic construction plus numerical observation",
    )
end

function cases()
    scaled = Diagonal([1.0e3, -1.0e2, 10.0, -1.0, 0.1, -0.01]) |> Matrix
    duplicate_columns = hcat(Matrix{Float64}(I, 6, 6), Matrix{Float64}(I, 6, 6)[:, 1:2])
    duplicate_rows = vcat(Matrix{Float64}(I, 5, 5), Matrix{Float64}(I, 5, 5)[1:2, :])
    tall = vcat(Matrix{Float64}(I, 8, 4), [1.0 2.0 3.0 4.0; -1.0 0.5 2.0 -3.0])
    wide = hcat(Matrix{Float64}(I, 4, 4), zeros(4, 5))
    signed_dependency = [
        1.0 2.0 -1.0 0.0 0.0;
        2.0 4.0 -2.0 0.0 0.0;
        0.0 0.0 0.0 3.0 1.0;
        0.0 0.0 0.0 6.0 2.0;
        1.0 -1.0 0.5 0.0 0.0;
    ]
    threshold_band = Diagonal([1.0, 0.25, 1.0e-9, 2.0e-9]) |> Matrix
    threshold_above = Diagonal([1.0, 0.25, 2.0e-8, 5.0e-8]) |> Matrix
    [
        ("scaled_signed_full_rank", scaled, "hard_control", true),
        ("duplicate_column_rank_deficient", duplicate_columns, "hard_control", true),
        ("duplicate_row_rank_deficient", duplicate_rows, "hard_control", true),
        ("rectangular_tall_full_column_rank", tall, "hard_control", true),
        ("rectangular_wide_full_row_rank", wide, "hard_control", true),
        ("signed_dependency_rank_deficient", signed_dependency, "hard_control", true),
        ("threshold_band_below", threshold_band, "threshold_sensitive", false),
        ("threshold_band_above", threshold_above, "threshold_sensitive", false),
    ]
end

records = [record(name, matrix, class, hard) for (name, matrix, class, hard) in cases()]
hard_records = filter(item -> item["hard_expectation"], records)
threshold_records = filter(item -> item["oracle_class"] == "threshold_sensitive", records)
hard_mismatches = [item["name"] for item in hard_records if !item["expectation_matched"]]
unavailable = [item["name"] for item in records if !item["dense_available"] || !item["sparse_available"]]
threshold_disagreements = [item["name"] for item in threshold_records if item["backend_rank_relation"] == "disagreement"]
status_entries = git_status_entries()
write_json(OUTPUT, Dict{String,Any}(
    "schema_version" => "nlpdiagnostics-rank-adversarial-extension-v1",
    "source" => Dict(
        "runner" => "benchmarks/calibrate_rank_adversarial_extensions.jl",
        "relative_tolerance" => RELATIVE_TOLERANCE,
        "case_count" => length(records),
        "backend_pair" => ["dense_svd", "sparse_qr"],
    ),
    "environment" => Dict(
        "julia_version" => string(VERSION),
        "active_project" => Base.active_project(),
        "git_revision" => git_revision(),
        "git_worktree_dirty" => !isempty(status_entries),
    ),
    "record_count" => length(records),
    "hard_control_count" => length(hard_records),
    "hard_control_mismatch_count" => length(hard_mismatches),
    "hard_control_mismatch_names" => hard_mismatches,
    "unavailable_count" => length(unavailable),
    "unavailable_names" => unavailable,
    "threshold_sensitive_count" => length(threshold_records),
    "threshold_backend_disagreement_count" => length(threshold_disagreements),
    "threshold_backend_disagreement_names" => threshold_disagreements,
    "all_hard_controls_matched" => isempty(hard_mismatches) && isempty(unavailable),
    "records" => records,
    "interpretation" => Dict(
        "claim" => "Dense-SVD and sparse-QR observations on deterministic scaled, rectangular, and dependency-rich constructions agree with the declared rank policy for hard controls when available.",
        "does_not_establish" => [
            "a third-backend crosscheck",
            "algebraic rank for threshold-sensitive perturbations",
            "a universal tolerance choice or arbitrary-matrix certificate",
        ],
    ),
))
isempty(hard_mismatches) && isempty(unavailable) || error("rank adversarial extension hard controls failed")
println("wrote rank adversarial extension summary to $OUTPUT")
