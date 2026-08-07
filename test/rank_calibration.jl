using LinearAlgebra
using Test

import MathOptInterface as MOI
import NLPDiagnostics

function _rank_calibration_evaluation(
    matrix::AbstractMatrix{<:Real};
    label::AbstractString,
)
    values = Float64.(matrix)
    rows, columns = size(values)
    variables = [MOI.VariableIndex(column) for column in 1:columns]
    point = NLPDiagnostics.EvaluationPoint(
        variables,
        zeros(columns);
        label,
    )
    entries = NLPDiagnostics.JacobianEntry{Float64}[]
    for column in axes(values, 2), row in axes(values, 1)
        iszero(values[row, column]) && continue
        push!(entries, NLPDiagnostics.JacobianEntry(row, column, values[row, column]))
    end
    sources = [NLPDiagnostics.EntityRef(:constraint, row) for row in 1:rows]
    return NLPDiagnostics.NumericalEvaluation{Float64}(
        point,
        nothing,
        nothing,
        Union{Missing,Float64}[0.0 for _ in 1:columns],
        Union{Missing,Float64}[0.0 for _ in 1:rows],
        sources,
        entries,
        fill(:calibration_exact, rows),
        NLPDiagnostics.EvaluatorCapabilities[],
        NLPDiagnostics.EvaluationFailure[],
    )
end

@testset "rank backend calibration corpus" begin
    cases = [
        (
            name = "exact row dependence",
            matrix = [1.0 2.0; 2.0 4.0],
            rank = 1,
            left_nullity = 1,
            right_nullity = 1,
        ),
        (
            name = "rectangular underdetermined",
            matrix = [1.0 0.0 1.0; 0.0 1.0 1.0],
            rank = 2,
            left_nullity = 0,
            right_nullity = 1,
        ),
        (
            name = "rectangular overdetermined",
            matrix = [1.0 0.0; 0.0 1.0; 1.0 1.0],
            rank = 2,
            left_nullity = 1,
            right_nullity = 0,
        ),
        (
            name = "clustered small and exact zero",
            matrix = Matrix(Diagonal([1.0, 1.0e-6, 0.0])),
            rank = 2,
            left_nullity = 1,
            right_nullity = 1,
        ),
        (
            name = "zero Jacobian",
            matrix = zeros(2, 3),
            rank = 0,
            left_nullity = 2,
            right_nullity = 3,
        ),
    ]

    for case in cases
        evaluation = _rank_calibration_evaluation(case.matrix; label = case.name)
        dense_policy = NLPDiagnostics.RankPolicy(
            Float64;
            backend = :dense_svd,
            relative_tolerance = 1.0e-8,
            provenance = :calibration_corpus,
        )
        sparse_policy = NLPDiagnostics.RankPolicy(
            Float64;
            backend = :sparse_qr,
            relative_tolerance = 1.0e-8,
            max_dense_entries = length(case.matrix),
            compute_vectors = false,
            provenance = :calibration_corpus,
        )
        dense = NLPDiagnostics.jacobian_rank_estimate(evaluation, dense_policy)
        sparse = NLPDiagnostics.sparse_qr_rank_estimate(evaluation, sparse_policy)
        @test dense.available
        @test sparse.available
        @test dense.rank == case.rank
        @test sparse.rank == case.rank
        @test dense.left_nullity == case.left_nullity
        @test dense.right_nullity == case.right_nullity
        @test dense.policy.provenance == :calibration_corpus
        @test sparse.policy.provenance == :calibration_corpus
        @test sparse.method == :suitesparse_qr
        @test sort(sparse.row_permutation) == collect(1:size(case.matrix, 1))
        @test sort(sparse.column_permutation) == collect(1:size(case.matrix, 2))
        @test !isnothing(sparse.factorization_relative_residual)
        @test sparse.factorization_relative_residual <= 1.0e-12
        if dense.right_nullity > 0
            @test norm(case.matrix * dense.right_nullspace) <= 1.0e-10
        end
        if dense.left_nullity > 0
            @test norm(transpose(case.matrix) * dense.left_nullspace) <= 1.0e-10
        end
    end

    ill_conditioned = _rank_calibration_evaluation(
        [1.0 0.0; 0.0 1.0e-10];
        label = "ill-conditioned full rank",
    )
    tight = NLPDiagnostics.jacobian_rank_estimate(
        ill_conditioned,
        NLPDiagnostics.RankPolicy(
            Float64;
            backend = :dense_svd,
            relative_tolerance = 1.0e-12,
            provenance = :calibration_corpus,
        ),
    )
    loose = NLPDiagnostics.jacobian_rank_estimate(
        ill_conditioned,
        NLPDiagnostics.RankPolicy(
            Float64;
            backend = :dense_svd,
            relative_tolerance = 1.0e-8,
            provenance = :calibration_corpus,
        ),
    )
    @test tight.rank == 2
    @test loose.rank == 1

    absolute_floor = NLPDiagnostics.jacobian_rank_estimate(
        ill_conditioned,
        NLPDiagnostics.RankPolicy(
            Float64;
            backend = :dense_svd,
            relative_tolerance = 0.0,
            absolute_tolerance = 1.0e-9,
            provenance = :calibration_corpus,
        ),
    )
    @test absolute_floor.rank == 1
    @test absolute_floor.absolute_threshold == 1.0e-9

    badly_scaled = _rank_calibration_evaluation(
        [1.0e-12 0.0; 0.0 1.0];
        label = "scaled full rank",
    )
    unscaled = NLPDiagnostics.jacobian_rank_estimate(
        badly_scaled;
        relative_tolerance = 1.0e-10,
    )
    scaled = NLPDiagnostics.jacobian_rank_estimate(
        badly_scaled;
        scaling = :row_column,
        relative_tolerance = 1.0e-10,
    )
    sparse_scaled = NLPDiagnostics.sparse_qr_rank_estimate(
        badly_scaled;
        scaling = :row_column,
        relative_tolerance = 1.0e-10,
    )
    @test unscaled.rank == 1
    @test scaled.rank == 2
    @test sparse_scaled.rank == 2

    dependent = _rank_calibration_evaluation(
        [1.0 1.0; 2.0 2.0];
        label = "backward-error calibration",
    )
    scaled_dependent = _rank_calibration_evaluation(
        1.0e9 .* [1.0 1.0; 2.0 2.0];
        label = "scaled backward-error calibration",
    )
    right = NLPDiagnostics.iterative_right_nullspace_subspace_estimate(
        dependent, 1; iterations = 300,
    )
    right_scaled = NLPDiagnostics.iterative_right_nullspace_subspace_estimate(
        scaled_dependent, 1; iterations = 300,
    )
    left = NLPDiagnostics.iterative_left_nullspace_subspace_estimate(
        dependent, 1; iterations = 300,
    )
    @test right.available && right_scaled.available && left.available
    @test only(right.relative_residual_norms) <= 1.0e-7
    @test only(right_scaled.relative_residual_norms) <= 1.0e-7
    @test only(left.relative_residual_norms) <= 1.0e-7
    @test only(right.relative_residual_norms) ≈
          only(right_scaled.relative_residual_norms) rtol = 1.0e-6 atol = 1.0e-14

    guarded_sparse = NLPDiagnostics.sparse_qr_rank_estimate(
        dependent;
        max_dense_entries = 0,
    )
    @test guarded_sparse.available
    @test isnothing(guarded_sparse.factorization_relative_residual)
    @test occursin("dense guard exceeded", guarded_sparse.factorization_residual_reason)

    @test_throws ArgumentError NLPDiagnostics.RankPolicy(Float64; backend = :unknown)
    @test_throws ArgumentError NLPDiagnostics.RankPolicy(Float64; absolute_tolerance = -1)
    @test_throws ArgumentError NLPDiagnostics.jacobian_rank_estimate(
        dependent,
        NLPDiagnostics.RankPolicy(Float64; backend = :sparse_qr),
    )
end
