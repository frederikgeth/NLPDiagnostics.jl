using Test
using LinearAlgebra

include(joinpath(@__DIR__, "..", "examples", "dependent_rows_calibration.jl"))

@testset "dependent-row cross-point and active-set calibration" begin
    cases = run_dependent_rows_calibration()
    stationary = cases.stationary.result
    feasible = cases.feasible.result
    @test stationary.available && stationary.irreducible_under_policy
    @test stationary.rows == [cases.stationary.rows[2]]
    @test stationary.deletion_ranks == [0]
    @test stationary.relative_residual == 0.0
    @test feasible.available && feasible.dependent === false
    @test feasible.selected_rank == 2
    @test stationary.threshold == feasible.threshold == 1.0e-10
    @test stationary.point.values != feasible.point.values
    @test cases.stationary.evaluation.constraint_values[
        cases.stationary.rows[2]] == 0.0
    @test cases.feasible.evaluation.constraint_values[
        cases.feasible.rows[2]] == 1.0

    active = cases.active
    @test active.available && active.irreducible_under_policy
    @test Set(active.rows) == Set(cases.active_rows)
    @test active.deletion_ranks == [2, 2, 2]
    @test all(iszero, cases.active_evaluation.constraint_values[
        cases.active_rows])
    @test cases.inactive_pair.irreducible_under_policy
    @test cases.inactive_pair.selected_rows != cases.active_rows
    @test Set(source.name for source in cases.inactive_pair.sources) ==
        Set(["balance", "loose_cap"])
    cap_row = _calibration_row(cases.active_evaluation, "loose_cap")
    @test cases.active_evaluation.constraint_values[cap_row] == 0.0
    @test cases.active_evaluation.constraint_values[cap_row] < 2.0
end

@testset "larger equality-row deletion oracle" begin
    identity = Matrix{Float64}(I, 8, 8)
    matrix = vcat(identity,
        reshape(identity[1, :] + identity[2, :], 1, :),
        reshape(identity[3, :] + identity[4, :], 1, :))
    evaluation = _dependent_rows_evaluation(matrix)
    result = NLPDiagnostics.dependent_row_localization(evaluation;
        scaling = :none, relative_tolerance = 0.0,
        absolute_tolerance = 1.0e-10,
        provenance = :larger_equality_oracle)
    @test result.available && result.irreducible_under_policy
    @test result.selected_rank == 8
    @test length(result.rows) == 3
    @test all(==(2), result.deletion_ranks)
    @test Set(result.rows) in (Set([1, 2, 9]), Set([3, 4, 10]))
    @test norm(transpose(matrix[result.rows, :]) * result.coefficients) <=
        1.0e-12
    @test result.rank_checks <= 1 + size(matrix, 1) + length(result.rows) + 1
end
