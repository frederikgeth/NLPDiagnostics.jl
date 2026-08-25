#!/usr/bin/env julia

"""Calibrate rank-policy stability under controlled nullspace perturbations.

The construction spectrum is the oracle.  Values below the declared relative
threshold are intentionally retained as tolerance-sensitive controls rather
than being promoted to algebraic-rank claims.
"""

using LinearAlgebra
using Random

import MathOptInterface as MOI
import NLPDiagnostics

include(joinpath(@__DIR__, "common.jl"))
using .NLPDiagnosticsBenchmarkCommon

const ROOT = repo_root()
const OUTPUT = abspath(isempty(ARGS) ?
    joinpath(ROOT, "docs", "rank_perturbation_sweep_summary.json") : ARGS[1])
const RELATIVE_TOLERANCE = 1.0e-8

orthogonal(rng, dimension) = Matrix(qr(randn(rng, dimension, dimension)).Q)

function planted_matrix(rng, rows, columns, spectrum)
    active = min(rows, columns)
    length(spectrum) == active || error("spectrum length must equal min dimension")
    left = orthogonal(rng, rows)[:, 1:active]
    right = orthogonal(rng, columns)[:, 1:active]
    return left * Diagonal(Float64.(spectrum)) * transpose(right)
end

function evaluation(matrix, label)
    rows, columns = size(matrix)
    variables = [MOI.VariableIndex(column) for column in 1:columns]
    point = NLPDiagnostics.EvaluationPoint(variables, zeros(columns); label)
    entries = NLPDiagnostics.JacobianEntry{Float64}[]
    for column in axes(matrix, 2), row in axes(matrix, 1)
        value = Float64(matrix[row, column])
        iszero(value) || push!(entries, NLPDiagnostics.JacobianEntry(row, column, value))
    end
    return NLPDiagnostics.NumericalEvaluation{Float64}(
        point, nothing, nothing,
        Union{Missing,Float64}[0.0 for _ in 1:columns],
        Union{Missing,Float64}[0.0 for _ in 1:rows],
        [NLPDiagnostics.EntityRef(:constraint, row) for row in 1:rows],
        entries, fill(:rank_perturbation_sweep, rows),
        NLPDiagnostics.EvaluatorCapabilities[], NLPDiagnostics.EvaluationFailure[],
    )
end

policy_rank(spectrum) = count(value -> abs(value) >
    RELATIVE_TOLERANCE * maximum(abs, spectrum), spectrum)

function record(matrix, spectrum; seed, case_name, oracle_class, hard_expectation)
    expected = policy_rank(spectrum)
    eval = evaluation(matrix, "$(case_name)_seed_$(seed)")
    dense_policy = NLPDiagnostics.RankPolicy(Float64;
        backend = :dense_svd, scaling = :none,
        relative_tolerance = RELATIVE_TOLERANCE,
        compute_vectors = false, max_dense_entries = length(matrix),
        provenance = :rank_perturbation_sweep)
    sparse_policy = NLPDiagnostics.RankPolicy(Float64;
        backend = :sparse_qr, scaling = :none,
        relative_tolerance = RELATIVE_TOLERANCE,
        compute_vectors = false, max_dense_entries = length(matrix),
        provenance = :rank_perturbation_sweep)
    dense = NLPDiagnostics.jacobian_rank_estimate(eval, dense_policy)
    sparse = NLPDiagnostics.sparse_qr_rank_estimate(eval, sparse_policy)
    dense_match = dense.available && dense.rank == expected
    sparse_match = sparse.available && sparse.rank == expected
    return Dict{String,Any}(
        "name" => "$(case_name)_seed_$(seed)", "seed" => seed,
        "case" => case_name, "oracle_class" => oracle_class,
        "rows" => size(matrix, 1), "columns" => size(matrix, 2),
        "planted_spectrum" => Float64.(spectrum),
        "planted_algebraic_rank" => count(!iszero, spectrum),
        "policy_expected_rank" => expected,
        "relative_tolerance" => RELATIVE_TOLERANCE,
        "hard_expectation" => hard_expectation,
        "dense_available" => dense.available, "dense_rank" => dense.rank,
        "dense_match" => dense_match,
        "sparse_available" => sparse.available, "sparse_rank" => sparse.rank,
        "sparse_match" => sparse_match,
        "backend_rank_relation" => dense.available && sparse.available ?
            (dense.rank == sparse.rank ? "agreement" : "disagreement") : "unavailable",
        "expectation_matched" => dense_match && sparse_match,
        "claim_level" => oracle_class == "threshold_sensitive" ?
            "numerical policy sensitivity" : "planted construction plus numerical observation",
    )
end

function cases(rng)
    common = [1.0, 0.5, 0.25, 0.1, 0.05, 0.02]
    return [
        ("well_conditioned_full_rank", planted_matrix(rng, 8, 8, [common; 0.01; 0.005]), [common; 0.01; 0.005], "hard_control", true),
        ("exact_rank_deficient", planted_matrix(rng, 8, 8, [common; 0.0; 0.0]), [common; 0.0; 0.0], "hard_control", true),
        ("lift_below_threshold", planted_matrix(rng, 8, 8, [common; 1.0e-10; 5.0e-10]), [common; 1.0e-10; 5.0e-10], "threshold_sensitive", false),
        ("threshold_band_low", planted_matrix(rng, 8, 8, [common; 2.0e-9; 5.0e-9]), [common; 2.0e-9; 5.0e-9], "threshold_sensitive", false),
        ("threshold_band_high", planted_matrix(rng, 8, 8, [common; 2.0e-8; 5.0e-8]), [common; 2.0e-8; 5.0e-8], "threshold_sensitive", false),
        ("well_above_threshold", planted_matrix(rng, 8, 8, [common; 1.0e-7; 2.0e-7]), [common; 1.0e-7; 2.0e-7], "hard_control", true),
        ("rectangular_full_row_rank", planted_matrix(rng, 6, 10, common), common, "hard_control", true),
        ("rectangular_rank_deficient", planted_matrix(rng, 6, 10, [common[1:4]; 0.0; 0.0]), [common[1:4]; 0.0; 0.0], "hard_control", true),
    ]
end

records = Dict{String,Any}[]
seeds = [101, 211, 307, 401, 509]
for seed in seeds
    rng = MersenneTwister(seed)
    for (name, matrix, spectrum, class, hard) in cases(rng)
        push!(records, record(matrix, spectrum;
            seed, case_name = name, oracle_class = class,
            hard_expectation = hard))
    end
end

hard_mismatches = [r["name"] for r in records if r["hard_expectation"] && !r["expectation_matched"]]
unavailable = [r["name"] for r in records if !r["dense_available"] || !r["sparse_available"]]
threshold_records = filter(r -> r["oracle_class"] == "threshold_sensitive", records)
threshold_disagreements = [r["name"] for r in threshold_records if r["backend_rank_relation"] == "disagreement"]

write_json(OUTPUT, Dict{String,Any}(
    "schema_version" => "nlpdiagnostics-rank-perturbation-sweep-v1",
    "source" => Dict(
        "runner" => "benchmarks/calibrate_rank_perturbation_sweep.jl",
        "seeds" => seeds, "relative_tolerance" => RELATIVE_TOLERANCE,
        "case_count_per_seed" => 8,
    ),
    "environment" => Dict(
        "julia_version" => string(VERSION), "active_project" => Base.active_project(),
        "git_revision" => git_revision(), "git_worktree_dirty" => !isempty(git_status_entries()),
    ),
    "record_count" => length(records),
    "hard_control_count" => count(r -> r["hard_expectation"], records),
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
        "claim" => "Dense-SVD and sparse-QR observations on controlled perturbations agree with the declared numerical rank policy for hard controls when available.",
        "does_not_establish" => [
            "algebraic rank for threshold-sensitive perturbations",
            "a universal tolerance choice or arbitrary-matrix certificate",
            "OPF physical interpretation or solver KKT conditioning",
        ],
    ),
))
isempty(hard_mismatches) && isempty(unavailable) || error("rank perturbation hard controls failed")
println("wrote rank perturbation sweep to $OUTPUT")
