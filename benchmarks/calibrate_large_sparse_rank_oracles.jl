#!/usr/bin/env julia

"""
Calibrate sparse rank estimates on guarded, large sparse construction oracles.

Dense SVD is deliberately disabled (`max_dense_entries = 0`). The planted
construction supplies the expected rank, while SuiteSparseQR remains a local
numerical observation with explicit availability and mismatch accounting.
"""

using LinearAlgebra
using SparseArrays

import MathOptInterface as MOI
import NLPDiagnostics

include(joinpath(@__DIR__, "common.jl"))
using .NLPDiagnosticsBenchmarkCommon

const REPO_ROOT = repo_root()
const OUTPUT = abspath(isempty(ARGS) ?
    joinpath(REPO_ROOT, "docs", "large_sparse_rank_oracle_summary.json") :
    ARGS[1])

function evaluation(matrix::SparseMatrixCSC{Float64,Int}, label::String)
    rows, columns = size(matrix)
    variables = [MOI.VariableIndex(column) for column in 1:columns]
    point = NLPDiagnostics.EvaluationPoint(variables, zeros(columns); label)
    row_indices, column_indices, values = findnz(matrix)
    entries = NLPDiagnostics.JacobianEntry{Float64}[
        NLPDiagnostics.JacobianEntry(row, column, value)
        for (row, column, value) in zip(row_indices, column_indices, values)
    ]
    return NLPDiagnostics.NumericalEvaluation{Float64}(
        point,
        nothing,
        nothing,
        Union{Missing,Float64}[0.0 for _ in 1:columns],
        Union{Missing,Float64}[0.0 for _ in 1:rows],
        [NLPDiagnostics.EntityRef(:constraint, row) for row in 1:rows],
        entries,
        fill(:large_sparse_rank_oracle, rows),
        NLPDiagnostics.EvaluatorCapabilities[],
        NLPDiagnostics.EvaluationFailure[],
    )
end

function sparse_case(kind::String, dimension::Int)
    dimension >= 2 || error("dimension must be at least two")
    if kind == "bidiagonal_full_rank"
        matrix = spdiagm(
            0 => ones(Float64, dimension),
            -1 => fill(-0.25, dimension - 1),
        )
        return matrix, dimension, :none, "lower-bidiagonal full-rank construction"
    elseif kind == "diagonal_rank_deficient"
        diagonal = ones(Float64, dimension)
        diagonal[end] = 0.0
        return sparse(spdiagm(0 => diagonal)), dimension - 1, :none,
            "diagonal construction with one planted zero direction"
    elseif kind == "wide_full_row_rank"
        matrix = sparse(
            collect(1:dimension), collect(1:dimension),
            ones(Float64, dimension), dimension, dimension + 8,
        )
        return matrix, dimension, :none, "wide identity with eight planted free columns"
    elseif kind == "tall_full_column_rank"
        matrix = sparse(
            collect(1:dimension), collect(1:dimension),
            ones(Float64, dimension), dimension + 8, dimension,
        )
        return matrix, dimension, :none, "tall identity with eight zero rows"
    elseif kind == "scaled_full_rank"
        diagonal = [isodd(index) ? 1.0e8 : 1.0e-8 for index in 1:dimension]
        return sparse(spdiagm(0 => diagonal)), dimension, :row_column,
            "alternating twenty-order diagonal under explicit row-column scaling"
    end
    error("unknown sparse rank case: $kind")
end

dimensions = [128, 256, 512, 1024]
kinds = [
    "bidiagonal_full_rank",
    "diagonal_rank_deficient",
    "wide_full_row_rank",
    "tall_full_column_rank",
    "scaled_full_rank",
]
records = Dict{String,Any}[]

for dimension in dimensions, kind in kinds
    matrix, expected_rank, scaling, construction = sparse_case(kind, dimension)
    label = "$(kind)_$(dimension)"
    point_evaluation = evaluation(matrix, label)
    dense_policy = NLPDiagnostics.RankPolicy(
        Float64;
        backend = :dense_svd,
        scaling,
        relative_tolerance = 1.0e-10,
        max_dense_entries = 0,
        compute_vectors = false,
        provenance = :large_sparse_rank_oracle,
    )
    sparse_policy = NLPDiagnostics.RankPolicy(
        Float64;
        backend = :sparse_qr,
        scaling,
        relative_tolerance = 1.0e-10,
        max_dense_entries = 0,
        compute_vectors = false,
        provenance = :large_sparse_rank_oracle,
    )
    dense = NLPDiagnostics.jacobian_rank_estimate(point_evaluation, dense_policy)
    sparse = NLPDiagnostics.sparse_qr_rank_estimate(point_evaluation, sparse_policy)
    sparse_match = sparse.available && sparse.rank == expected_rank
    dense_unavailable_reason = NLPDiagnostics.unavailable_reason(
        dense;
        code = :dense_rank_work_guard,
        category = :work_guard,
        stage = :numerical,
    )
    sparse_unavailable_reason = NLPDiagnostics.unavailable_reason(
        sparse;
        code = :sparse_rank_unavailable,
        category = :capability,
        stage = :numerical,
    )
    push!(records, Dict{String,Any}(
        "name" => label,
        "case" => kind,
        "rows" => size(matrix, 1),
        "columns" => size(matrix, 2),
        "input_nonzeros" => nnz(matrix),
        "expected_rank" => expected_rank,
        "scaling" => String(scaling),
        "construction" => construction,
        "dense_available" => dense.available,
        "dense_rank" => dense.rank,
        "dense_unavailable_reason" => dense.reason,
        "dense_unavailable_reason_typed" => isnothing(dense_unavailable_reason) ?
            nothing : NLPDiagnostics.unavailable_reason_data(dense_unavailable_reason),
        "sparse_available" => sparse.available,
        "sparse_rank" => sparse.rank,
        "sparse_match" => sparse_match,
        "sparse_unavailable_reason" => sparse.reason,
        "sparse_unavailable_reason_typed" => isnothing(sparse_unavailable_reason) ?
            nothing : NLPDiagnostics.unavailable_reason_data(sparse_unavailable_reason),
        "sparse_factorization_relative_residual" =>
            sparse.factorization_relative_residual,
        "sparse_factor_nonzeros" => sparse.factor_nonzeros,
        "sparse_fill_ratio" => sparse.fill_ratio,
        "sparse_max_input_nonzeros" => sparse.max_input_nonzeros,
        "sparse_max_factor_nonzeros" => sparse.max_factor_nonzeros,
        "backend_relation" => !dense.available ? "dense_unavailable" :
            dense.rank == sparse.rank ? "agreement" : "disagreement",
    ))
end

hard_mismatches = [
    record["name"] for record in records if !record["sparse_match"]
]
dense_unavailable = count(record -> !record["dense_available"], records)
sparse_unavailable = count(record -> !record["sparse_available"], records)
by_case = Dict{String,Any}()
for kind in kinds
    selected = filter(record -> record["case"] == kind, records)
    by_case[kind] = Dict(
        "record_count" => length(selected),
        "sparse_available_count" => count(record -> record["sparse_available"], selected),
        "sparse_match_count" => count(record -> record["sparse_match"], selected),
        "sparse_mismatch_names" => [
            record["name"] for record in selected if !record["sparse_match"]
        ],
    )
end

summary = Dict{String,Any}(
    "schema_version" => "nlpdiagnostics-large-sparse-rank-oracles-v1",
    "source" => Dict(
        "runner" => "benchmarks/calibrate_large_sparse_rank_oracles.jl",
        "dimensions" => dimensions,
        "case_kinds" => kinds,
        "dense_max_dense_entries" => 0,
        "sparse_backend" => "SuiteSparseQR",
    ),
    "environment" => Dict(
        "julia_version" => string(VERSION),
        "active_project" => Base.active_project(),
        "git_revision" => git_revision(),
        "architecture" => string(Sys.ARCH),
        "os" => string(Sys.KERNEL),
    ),
    "record_count" => length(records),
    "dense_unavailable_count" => dense_unavailable,
    "sparse_unavailable_count" => sparse_unavailable,
    "sparse_mismatch_count" => length(hard_mismatches),
    "all_sparse_expectations_matched" => isempty(hard_mismatches),
    "sparse_mismatch_names" => hard_mismatches,
    "by_case" => by_case,
    "records" => records,
    "interpretation" => Dict(
        "claim" =>
            "Guarded sparse-QR rank observations agree with planted construction ranks on the recorded corpus when available.",
        "does_not_establish" => [
            "dense-reference agreement for the guarded large models",
            "a mathematical rank certificate for arbitrary sparse matrices",
            "OPF physical interpretation or solver KKT conditioning",
        ],
        "dense_guard" =>
            "Dense SVD was intentionally unavailable because max_dense_entries was set to zero.",
    ),
)

write_json(OUTPUT, summary)
println("wrote large sparse rank-oracle summary to $OUTPUT")
