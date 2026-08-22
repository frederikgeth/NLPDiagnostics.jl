#!/usr/bin/env julia

"""
Build a deterministic, seeded rank-oracle campaign.

The planted spectrum is the construction oracle. Dense SVD is used only as a
small-matrix numerical reference, and SuiteSparseQR is compared against the
same explicit tolerance and scaling policies. Threshold-clustered cases are
allowed to disagree: their purpose is to expose policy sensitivity, not to
manufacture a single "true numerical rank".
"""

using LinearAlgebra
using Random

include(joinpath(@__DIR__, "common.jl"))
using .NLPDiagnosticsBenchmarkCommon

import MathOptInterface as MOI
import NLPDiagnostics

function _oracle_evaluation(
    matrix::AbstractMatrix{<:Real};
    label::AbstractString,
    point_values::AbstractVector{<:Real} = zeros(size(matrix, 2)),
)
    values = Float64.(matrix)
    rows, columns = size(values)
    variables = [MOI.VariableIndex(column) for column in 1:columns]
    point = NLPDiagnostics.EvaluationPoint(variables, point_values; label)
    entries = NLPDiagnostics.JacobianEntry{Float64}[]
    for column in axes(values, 2), row in axes(values, 1)
        iszero(values[row, column]) && continue
        push!(entries, NLPDiagnostics.JacobianEntry(
            row, column, values[row, column],
        ))
    end
    return NLPDiagnostics.NumericalEvaluation{Float64}(
        point,
        nothing,
        nothing,
        Union{Missing,Float64}[0.0 for _ in 1:columns],
        Union{Missing,Float64}[0.0 for _ in 1:rows],
        [NLPDiagnostics.EntityRef(:constraint, row) for row in 1:rows],
        entries,
        fill(:planted_rank_oracle, rows),
        NLPDiagnostics.EvaluatorCapabilities[],
        NLPDiagnostics.EvaluationFailure[],
    )
end

_orthogonal(rng, dimension) = Matrix(qr(randn(rng, dimension, dimension)).Q)

function _planted_matrix(rng, rows, columns, spectrum)
    active = min(rows, columns)
    length(spectrum) == active || throw(ArgumentError(
        "spectrum length must equal min(rows, columns)",
    ))
    left = _orthogonal(rng, rows)[:, 1:active]
    right = _orthogonal(rng, columns)[:, 1:active]
    return left * Diagonal(Float64.(spectrum)) * transpose(right)
end

function _policy_rank(spectrum, relative_tolerance)
    isempty(spectrum) && return 0
    threshold = relative_tolerance * maximum(abs, spectrum)
    return count(value -> abs(value) > threshold, spectrum)
end

function _rank_record(
    matrix,
    spectrum;
    name,
    seed,
    oracle_class,
    relative_tolerance = 1.0e-8,
    scaling = :none,
    expected_rank = _policy_rank(spectrum, relative_tolerance),
    hard_expectation = true,
    point_values = zeros(size(matrix, 2)),
    construction,
)
    evaluation = _oracle_evaluation(
        matrix; label = name, point_values,
    )
    dense_policy = NLPDiagnostics.RankPolicy(
        Float64;
        backend = :dense_svd,
        scaling,
        relative_tolerance,
        compute_vectors = true,
        max_dense_entries = length(matrix),
        provenance = :seeded_rank_oracle,
    )
    sparse_policy = NLPDiagnostics.RankPolicy(
        Float64;
        backend = :sparse_qr,
        scaling,
        relative_tolerance,
        compute_vectors = false,
        max_dense_entries = length(matrix),
        provenance = :seeded_rank_oracle,
    )
    dense = NLPDiagnostics.jacobian_rank_estimate(evaluation, dense_policy)
    sparse = NLPDiagnostics.sparse_qr_rank_estimate(evaluation, sparse_policy)
    dense_residual = if dense.available && dense.right_nullity > 0
        norm(Float64.(matrix) * dense.right_nullspace) /
            max(norm(Float64.(matrix)), eps(Float64))
    else
        nothing
    end
    dense_match = dense.available && dense.rank == expected_rank
    sparse_match = sparse.available && sparse.rank == expected_rank
    return Dict{String,Any}(
        "name" => name,
        "seed" => seed,
        "oracle_class" => oracle_class,
        "construction" => construction,
        "rows" => size(matrix, 1),
        "columns" => size(matrix, 2),
        "scaling" => String(scaling),
        "relative_tolerance" => relative_tolerance,
        "planted_spectrum" => Float64.(spectrum),
        "planted_algebraic_rank" => count(!iszero, spectrum),
        "policy_expected_rank" => expected_rank,
        "hard_expectation" => hard_expectation,
        "dense_available" => dense.available,
        "dense_rank" => dense.rank,
        "dense_match" => dense_match,
        "dense_singular_values" => dense.singular_values,
        "dense_absolute_threshold" => dense.absolute_threshold,
        "dense_right_nullspace_relative_residual" => dense_residual,
        "sparse_available" => sparse.available,
        "sparse_rank" => sparse.rank,
        "sparse_match" => sparse_match,
        "sparse_diagonal_pivots" => sparse.diagonal_pivots,
        "sparse_absolute_threshold" => sparse.absolute_threshold,
        "sparse_factorization_relative_residual" =>
            sparse.factorization_relative_residual,
        "backend_rank_relation" => dense.available && sparse.available ?
            (dense.rank == sparse.rank ? "agreement" : "disagreement") :
            "unavailable",
        "expectation_matched" => dense_match && sparse_match,
        "claim_level" => oracle_class == "threshold_cluster" ?
            "numerical policy sensitivity" :
            "planted construction plus numerical observation",
    )
end

function _seed_records(seed)
    rng = MersenneTwister(seed)
    records = Dict{String,Any}[]

    tall_spectrum = [10.0, 4.0, 2.0, 1.0, 0.5, 0.2, 0.1, 0.05]
    tall = _planted_matrix(rng, 12, 8, tall_spectrum)
    push!(records, _rank_record(
        tall, tall_spectrum;
        name = "seed_$(seed)_tall_full_column_rank",
        seed,
        oracle_class = "full_rank_negative_control",
        relative_tolerance = 1.0e-10,
        construction = "12x8 orthogonally rotated planted full-column-rank spectrum",
    ))

    wide_spectrum = [8.0, 3.0, 1.0, 0.4, 0.2, 0.08, 0.02]
    wide = _planted_matrix(rng, 7, 10, wide_spectrum)
    push!(records, _rank_record(
        wide, wide_spectrum;
        name = "seed_$(seed)_wide_right_nullity_three",
        seed,
        oracle_class = "rectangular_exact_nullity",
        relative_tolerance = 1.0e-10,
        construction = "7x10 orthogonally rotated rank-seven matrix; algebraic right nullity three",
    ))

    clustered_spectrum = [1.0, 0.2, 1.2e-8, 0.8e-8, 0.0]
    clustered = _planted_matrix(rng, 5, 5, clustered_spectrum)
    for tolerance in (5.0e-9, 1.0e-8, 2.0e-8)
        push!(records, _rank_record(
            clustered, clustered_spectrum;
            name = "seed_$(seed)_threshold_cluster_$(tolerance)",
            seed,
            oracle_class = "threshold_cluster",
            relative_tolerance = tolerance,
            hard_expectation = false,
            construction = "rotated spectrum straddling the selected relative threshold",
        ))
    end

    permutation = randperm(rng, 8)
    scaled_spectrum = [1.0e8, 1.0e4, 1.0e2, 1.0, 1.0e-2, 1.0e-4, 1.0e-8, 1.0e-12]
    scaled = Matrix(Diagonal(scaled_spectrum[permutation]))
    push!(records, _rank_record(
        scaled, scaled_spectrum;
        name = "seed_$(seed)_badly_scaled_unscaled_policy",
        seed,
        oracle_class = "scaling_sensitive_full_rank",
        relative_tolerance = 1.0e-10,
        scaling = :none,
        construction = "seed-permuted diagonal full-rank matrix spanning twenty orders of magnitude",
    ))
    push!(records, _rank_record(
        scaled, ones(8);
        name = "seed_$(seed)_badly_scaled_equilibrated_policy",
        seed,
        oracle_class = "scaling_intervention",
        relative_tolerance = 1.0e-10,
        scaling = :row_column,
        expected_rank = 8,
        construction = "same full-rank matrix under explicit row-column equilibration",
    ))

    # f₁=x+y; f₂=x+y+(x-y)^2/2. At x=y the two Jacobian rows
    # coincide exactly. A nearby point restores the second local direction.
    left = _orthogonal(rng, 2)
    right = _orthogonal(rng, 2)
    stationary = left * [1.0 1.0; 1.0 1.0] * transpose(right)
    delta = 1.0e-5
    nearby = left * [1.0 1.0; 1.0 + delta 1.0 - delta] * transpose(right)
    stationary_spectrum = svdvals(stationary)
    nearby_spectrum = svdvals(nearby)
    push!(records, _rank_record(
        stationary, stationary_spectrum;
        name = "seed_$(seed)_nonlinear_cancellation_point",
        seed,
        oracle_class = "nonlinear_cancellation",
        relative_tolerance = 1.0e-10,
        expected_rank = 1,
        point_values = [0.0, 0.0],
        construction = "orthogonally transformed Jacobian of f1=x+y, f2=x+y+(x-y)^2/2 at x=y",
    ))
    push!(records, _rank_record(
        nearby, nearby_spectrum;
        name = "seed_$(seed)_nonlinear_cancellation_nearby",
        seed,
        oracle_class = "nonlinear_cancellation_negative_control",
        relative_tolerance = 1.0e-10,
        expected_rank = 2,
        point_values = [delta, 0.0],
        construction = "same transformed nonlinear Jacobian at x-y=1e-5",
    ))
    return records
end

function randomized_rank_oracle_campaign(; seeds = [11, 29, 47])
    isempty(seeds) && throw(ArgumentError("seeds must not be empty"))
    length(unique(seeds)) == length(seeds) ||
        throw(ArgumentError("seeds must be unique"))
    records = reduce(vcat, _seed_records.(Int.(seeds)))
    hard_mismatches = [
        record["name"] for record in records
        if record["hard_expectation"] && !record["expectation_matched"]
    ]
    threshold_disagreements = [
        record["name"] for record in records
        if record["oracle_class"] == "threshold_cluster" &&
           record["backend_rank_relation"] == "disagreement"
    ]
    return Dict{String,Any}(
        "report_version" => "seeded-randomized-rank-oracles-v1",
        "source" => Dict(
            "runner" => "benchmarks/calibrate_randomized_rank_oracles.jl",
            "git_revision" => git_revision(),
            "git_worktree_dirty" => !isempty(git_status_entries()),
        ),
        "seeds" => Int.(seeds),
        "record_count" => length(records),
        "hard_expectation_count" => count(record -> record["hard_expectation"], records),
        "all_hard_expectations_matched" => isempty(hard_mismatches),
        "hard_expectation_mismatches" => hard_mismatches,
        "threshold_backend_disagreement_count" => length(threshold_disagreements),
        "threshold_backend_disagreements" => threshold_disagreements,
        "records" => records,
        "interpretation" => "Seeded planted-spectrum calibration. Hard controls test implementation behavior away from thresholds. Clustered-threshold disagreements are retained as tolerance-dependent evidence and are not failures or mathematical-rank claims.",
    )
end

function main()
    length(ARGS) == 1 || error(
        "usage: calibrate_randomized_rank_oracles.jl <output.json>",
    )
    payload = randomized_rank_oracle_campaign()
    output = abspath(only(ARGS))
    write_json(output, payload)
    mismatches = payload["hard_expectation_mismatches"]
    payload["all_hard_expectations_matched"] || error(
        "hard oracle mismatches: $(join(mismatches, ','))",
    )
    println("wrote randomized rank-oracle calibration to $output")
end

abspath(PROGRAM_FILE) == abspath(@__FILE__) && main()
