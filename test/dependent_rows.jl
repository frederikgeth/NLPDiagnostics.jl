using LinearAlgebra
using Test

import MathOptInterface as MOI
import NLPDiagnostics

function _dependent_rows_evaluation(matrix; methods = fill(:exact, size(matrix, 1)))
    rows, columns = size(matrix)
    point = NLPDiagnostics.EvaluationPoint(
        [MOI.VariableIndex(i) for i in 1:columns], zeros(columns);
        label = "row localization fixture",
    )
    entries = NLPDiagnostics.JacobianEntry{Float64}[
        NLPDiagnostics.JacobianEntry(row, column, Float64(matrix[row, column]))
        for row in 1:rows for column in 1:columns if !iszero(matrix[row, column])
    ]
    return NLPDiagnostics.NumericalEvaluation{Float64}(
        point, nothing, nothing, Union{Missing,Float64}[],
        Union{Missing,Float64}[0.0 for _ in 1:rows],
        [NLPDiagnostics.EntityRef(:constraint, row) for row in 1:rows],
        entries, methods, NLPDiagnostics.EvaluatorCapabilities[],
        NLPDiagnostics.EvaluationFailure[],
    )
end

@testset "dependent-row localization and minimality" begin
    evaluation = _dependent_rows_evaluation([1.0 1.0; 1.0 -1.0; 2.0 0.0])
    result = NLPDiagnostics.Advanced.dependent_row_localization(
        evaluation; relative_tolerance = 1.0e-10,
        absolute_tolerance = 1.0e-12, provenance = :test,
    )
    @test result.available
    @test result.selected_rank == 2
    @test result.dependent === true
    @test result.rows == [1, 2, 3]
    @test result.deletion_ranks == [2, 2, 2]
    @test result.irreducible_under_policy
    @test result.relative_residual <= 1.0e-12
    @test norm(transpose([1.0 1.0; 1.0 -1.0; 2.0 0.0]) *
        result.coefficients) <= 1.0e-12
    @test [source.index for source in result.sources] == result.rows
    data = NLPDiagnostics.Advanced.dependent_row_localization_data(result)
    @test data["fixed_threshold"] == result.threshold
    @test data["irreducible_under_policy"]
    @test data["point"]["label"] == "row localization fixture"
    report = NLPDiagnostics.Advanced.dependent_row_localization_report(result)
    @test only(report.findings).code == :numerical_irreducible_dependent_rows
    @test length(only(report.findings).affected) == 3

    independent = NLPDiagnostics.dependent_row_localization(
        evaluation; rows = [2, 1], relative_tolerance = 1.0e-10,
    )
    @test independent.available
    @test independent.dependent === false
    @test independent.rows == Int[]
    @test isempty(NLPDiagnostics.dependent_row_localization_report(independent))

    pair = NLPDiagnostics.dependent_row_localization(
        _dependent_rows_evaluation([1.0 2.0; 2.0 4.0; 0.0 1.0]);
        relative_tolerance = 1.0e-10,
    )
    @test pair.rows == [1, 2]
    @test pair.deletion_ranks == [1, 1]
    @test pair.irreducible_under_policy

    zero_row = NLPDiagnostics.dependent_row_localization(
        _dependent_rows_evaluation([1.0 0.0; 0.0 0.0]);
        relative_tolerance = 1.0e-10,
    )
    @test zero_row.rows == [2]
    @test zero_row.deletion_ranks == [0]
    @test zero_row.relative_residual == 0.0
end

@testset "dependent-row availability and policy boundaries" begin
    evaluation = _dependent_rows_evaluation([1.0 0.0; 2.0 0.0])
    @test !NLPDiagnostics.dependent_row_localization(
        evaluation; max_rows = 1).available
    @test !NLPDiagnostics.dependent_row_localization(
        evaluation; max_dense_entries = 1).available
    @test_throws ArgumentError NLPDiagnostics.dependent_row_localization(
        evaluation; rows = [1, 1])
    @test_throws ArgumentError NLPDiagnostics.dependent_row_localization(
        evaluation; rows = [3])
    @test_throws ArgumentError NLPDiagnostics.dependent_row_localization(
        evaluation; relative_tolerance = -1.0)

    incomplete = _dependent_rows_evaluation(
        [1.0 0.0; 2.0 0.0]; methods = [:exact, :unavailable],
    )
    unavailable = NLPDiagnostics.dependent_row_localization(incomplete)
    @test !unavailable.available
    @test occursin("incomplete", unavailable.reason)
    @test only(NLPDiagnostics.dependent_row_localization_report(
        unavailable).findings).code == :dependent_row_localization_unavailable

    near = _dependent_rows_evaluation([1.0 0.0; 1.0 1.0e-8])
    strict = NLPDiagnostics.dependent_row_localization(
        near; relative_tolerance = 0.0, absolute_tolerance = 1.0e-10,
    )
    loose = NLPDiagnostics.dependent_row_localization(
        near; relative_tolerance = 0.0, absolute_tolerance = 1.0e-6,
    )
    @test strict.dependent === false
    @test loose.dependent === true
    @test loose.irreducible_under_policy
end
