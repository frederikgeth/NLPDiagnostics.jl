@testset "objective consistency and affine primal-dual gap" begin
    optimizer = MOIU.MockOptimizer(
        Float64;
        eval_objective_value = true,
        eval_variable_constraint_dual = true,
    )
    variable = MOI.add_variable(optimizer)
    MOI.add_constraint(optimizer, variable, MOI.GreaterThan(1.0))
    MOI.set(optimizer, MOI.ObjectiveSense(), MOI.MIN_SENSE)
    MOI.set(
        optimizer,
        MOI.ObjectiveFunction{MOI.VariableIndex}(),
        variable,
    )
    optimizer.optimize! = mock -> MOIU.mock_optimize!(
        mock,
        MOI.OPTIMAL,
        (MOI.FEASIBLE_POINT, [1.0]),
        MOI.FEASIBLE_POINT,
        (MOI.VariableIndex, MOI.GreaterThan{Float64}) => [1.0],
    )
    MOI.optimize!(optimizer)

    summary = NLPDiagnostics.Stable.objective_consistency_summary(optimizer)
    @test summary isa NLPDiagnostics.ObjectiveConsistencySummary{Float64}
    @test summary.objective_sense == :minimize
    @test summary.termination_status == "OPTIMAL"
    @test summary.primal_status == "FEASIBLE_POINT"
    @test summary.dual_status == "FEASIBLE_POINT"
    @test summary.solver_objective_source == :moi_objective_value
    @test summary.solver_objective_value == 1.0
    @test summary.reevaluated_objective_value == 1.0
    @test summary.comparison_available
    @test summary.consistent
    @test summary.absolute_difference == 0.0
    @test summary.relative_difference == 0.0
    @test summary.gap_available
    @test summary.gap_basis == :continuous_scalar_affine_duality
    @test summary.dual_objective_value == 1.0
    @test summary.primal_dual_gap == 0.0
    @test summary.relative_primal_dual_gap == 0.0
    @test summary.gap_passed
    @test summary.primal_feasible
    @test summary.dual_feasible
    @test summary.maximum_primal_violation == 0.0
    @test summary.maximum_stationarity_residual == 0.0
    @test summary.maximum_dual_violation == 0.0
    @test occursin("comparison=true", sprint(show, summary))

    data = NLPDiagnostics.Stable.objective_consistency_summary_data(summary)
    @test data["schema_version"] ==
          "nlpdiagnostics-objective-consistency-summary-v1"
    @test data["point"]["provenance"]["kind"] == "SolverResultPoint"
    @test data["dual_status"] == "FEASIBLE_POINT"
    @test data["comparison_unavailable_reason"] === nothing
    @test data["gap_unavailable_reason"] === nothing
    @test data["qualification"]["gap_claim"] ==
          "tolerance-qualified continuous scalar affine primal-dual gap"

    report = NLPDiagnostics.Stable.objective_consistency_report(summary)
    @test length(NLPDiagnostics.findings(
        report; code = :solver_result_objective_consistent,
    )) == 1
    @test length(NLPDiagnostics.findings(
        report; code = :primal_dual_gap_within_tolerance,
    )) == 1

    evaluation = NLPDiagnostics.evaluate_numerical(optimizer, summary.point)
    duals = NLPDiagnostics.solver_dual_snapshot(optimizer, evaluation)
    mismatch = NLPDiagnostics.objective_consistency_summary(
        optimizer,
        evaluation;
        solver_objective_value = 1.25,
        dual_snapshot = duals,
        relative_tolerance = 1.0e-8,
    )
    @test !mismatch.consistent
    @test mismatch.absolute_difference == 0.25
    @test mismatch.gap_available
    @test length(NLPDiagnostics.findings(
        NLPDiagnostics.objective_consistency_report(mismatch);
        code = :solver_result_objective_mismatch,
    )) == 1
end

@testset "applicable gap policy and abstention" begin
    model = MOIU.UniversalFallback(MOIU.Model{Float64}())
    variable = MOI.add_variable(model)
    MOI.add_constraint(model, variable, MOI.GreaterThan(0.0))
    MOI.set(model, MOI.ObjectiveSense(), MOI.MIN_SENSE)
    MOI.set(model, MOI.ObjectiveFunction{MOI.VariableIndex}(), variable)
    point = NLPDiagnostics.EvaluationPoint(
        [variable], [1.0]; label = "feasible but nonoptimal",
    )
    evaluation = NLPDiagnostics.evaluate_numerical(model, point)
    side = NLPDiagnostics.SolverConstraintSideDual(
        1,
        only(evaluation.constraint_sources),
        :lower,
        1.0,
        1.0,
        0.0,
        1.0,
        :synthetic_affine_dual,
    )
    duals = NLPDiagnostics.SolverDualSnapshot(
        true,
        nothing,
        point,
        1,
        "FEASIBLE_POINT",
        1.0,
        [-1.0],
        [side],
        true,
        0.0,
        String[],
    )
    open_gap = NLPDiagnostics.objective_consistency_summary(
        model,
        evaluation;
        solver_objective_value = 1.0,
        dual_snapshot = duals,
    )
    @test open_gap.gap_available
    @test open_gap.dual_objective_value == 0.0
    @test open_gap.primal_dual_gap == 1.0
    @test !open_gap.gap_passed
    @test length(NLPDiagnostics.findings(
        NLPDiagnostics.objective_consistency_report(open_gap);
        code = :primal_dual_gap_exceeds_tolerance,
    )) == 1

    other_point = NLPDiagnostics.EvaluationPoint(
        [variable], [2.0]; label = "different endpoint",
    )
    other_side = NLPDiagnostics.SolverConstraintSideDual(
        1,
        only(evaluation.constraint_sources),
        :lower,
        1.0,
        2.0,
        0.0,
        2.0,
        :synthetic_affine_dual,
    )
    wrong_point_duals = NLPDiagnostics.SolverDualSnapshot(
        true,
        nothing,
        other_point,
        1,
        "FEASIBLE_POINT",
        1.0,
        [-1.0],
        [other_side],
        true,
        0.0,
        String[],
    )
    wrong_point_summary = NLPDiagnostics.objective_consistency_summary(
        model,
        evaluation;
        solver_objective_value = 1.0,
        dual_snapshot = wrong_point_duals,
    )
    @test !wrong_point_summary.gap_available
    @test occursin("different evaluation point", wrong_point_summary.gap_reason)

    wrong_result_duals = NLPDiagnostics.SolverDualSnapshot(
        true,
        nothing,
        point,
        2,
        "FEASIBLE_POINT",
        1.0,
        [-1.0],
        [side],
        true,
        0.0,
        String[],
    )
    wrong_result_summary = NLPDiagnostics.objective_consistency_summary(
        model,
        evaluation;
        solver_objective_value = 1.0,
        dual_snapshot = wrong_result_duals,
    )
    @test !wrong_result_summary.gap_available
    @test occursin("different result index", wrong_result_summary.gap_reason)

    wrong_weight_duals = NLPDiagnostics.SolverDualSnapshot(
        true,
        nothing,
        point,
        1,
        "FEASIBLE_POINT",
        -1.0,
        [-1.0],
        [side],
        true,
        0.0,
        String[],
    )
    wrong_weight_summary = NLPDiagnostics.objective_consistency_summary(
        model,
        evaluation;
        solver_objective_value = 1.0,
        dual_snapshot = wrong_weight_duals,
    )
    @test !wrong_weight_summary.gap_available
    @test occursin("objective weight", wrong_weight_summary.gap_reason)

    max_model = MOIU.UniversalFallback(MOIU.Model{Float64}())
    max_variable = MOI.add_variable(max_model)
    MOI.add_constraint(max_model, max_variable, MOI.LessThan(1.0))
    MOI.set(max_model, MOI.ObjectiveSense(), MOI.MAX_SENSE)
    MOI.set(
        max_model,
        MOI.ObjectiveFunction{MOI.VariableIndex}(),
        max_variable,
    )
    max_point = NLPDiagnostics.EvaluationPoint(
        [max_variable], [1.0]; label = "max endpoint",
    )
    max_evaluation = NLPDiagnostics.evaluate_numerical(max_model, max_point)
    max_side = NLPDiagnostics.SolverConstraintSideDual(
        1,
        only(max_evaluation.constraint_sources),
        :upper,
        1.0,
        1.0,
        1.0,
        0.0,
        :synthetic_affine_dual,
    )
    max_duals = NLPDiagnostics.SolverDualSnapshot(
        true,
        nothing,
        max_point,
        1,
        "FEASIBLE_POINT",
        -1.0,
        [1.0],
        [max_side],
        true,
        0.0,
        String[],
    )
    max_summary = NLPDiagnostics.objective_consistency_summary(
        max_model,
        max_evaluation;
        solver_objective_value = 1.0,
        dual_snapshot = max_duals,
    )
    @test max_summary.objective_sense == :maximize
    @test max_summary.dual_objective_value == 1.0
    @test max_summary.primal_dual_gap == 0.0
    @test max_summary.gap_passed

    nonlinear = JuMP.Model()
    JuMP.@variable(nonlinear, z)
    JuMP.@objective(nonlinear, Min, (z - 2)^2)
    nonlinear_evaluation = NLPDiagnostics.evaluate_numerical(nonlinear, [2.0])
    nonlinear_summary = NLPDiagnostics.objective_consistency_summary(
        nonlinear,
        nonlinear_evaluation;
        solver_objective_value = 0.0,
    )
    @test nonlinear_summary.comparison_available
    @test nonlinear_summary.consistent
    @test !nonlinear_summary.gap_available
    @test occursin("not scalar affine", nonlinear_summary.gap_reason)
    nonlinear_data = NLPDiagnostics.objective_consistency_summary_data(
        nonlinear_summary,
    )
    @test nonlinear_data["gap_unavailable_reason"]["code"] ==
          "primal_dual_gap_unavailable"
    @test length(NLPDiagnostics.findings(
        NLPDiagnostics.objective_consistency_report(nonlinear_summary);
        code = :primal_dual_gap_unavailable,
    )) == 1

    unsolved = MOIU.UniversalFallback(MOIU.Model{Float64}())
    MOI.add_variable(unsolved)
    unavailable = NLPDiagnostics.objective_consistency_summary(unsolved)
    @test unavailable.point === nothing
    @test !unavailable.comparison_available
    @test !unavailable.gap_available
    @test occursin("no complete public primal point", unavailable.comparison_reason)

    @test_throws ArgumentError NLPDiagnostics.objective_consistency_summary(
        model,
        evaluation;
        solver_objective_value = 1.0,
        absolute_tolerance = -1.0,
    )
    @test_throws ArgumentError NLPDiagnostics.objective_consistency_summary(
        model,
        evaluation;
        solver_objective_value = 1.0,
        stationarity_tolerance = Inf,
    )
    @test_throws ArgumentError NLPDiagnostics.objective_consistency_summary(
        unsolved;
        dual_tolerance = -1.0,
    )
end
