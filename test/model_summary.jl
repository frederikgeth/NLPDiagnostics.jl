struct SummaryOpaqueEvaluator <: MOI.AbstractNLPEvaluator end

@testset "model summary and static coefficient profile" begin
    model = MOI.Utilities.UniversalFallback(MOI.Utilities.Model{Float64}())
    x, y = MOI.add_variables(model, 2)
    MOI.set(model, MOI.VariableName(), x, "power_mw")
    MOI.add_constraint(model, x, MOI.Interval(-10.0, 20.0))
    MOI.add_constraint(model, y, MOI.Integer())
    affine = MOI.ScalarAffineFunction([
        MOI.ScalarAffineTerm(1.0e6, x),
        MOI.ScalarAffineTerm(2.0, y),
        MOI.ScalarAffineTerm(-1.0, y),
    ], 3.0)
    MOI.add_constraint(model, affine, MOI.EqualTo(8.0))
    quadratic = MOI.ScalarQuadraticFunction(
        [MOI.ScalarQuadraticTerm(4.0, x, x)],
        [MOI.ScalarAffineTerm(5.0, y)],
        1.0,
    )
    MOI.add_constraint(model, quadratic, MOI.LessThan(10.0))
    objective = MOI.ScalarQuadraticFunction(
        [MOI.ScalarQuadraticTerm(6.0, y, y)],
        [MOI.ScalarAffineTerm(7.0, x)],
        0.0,
    )
    MOI.set(model, MOI.ObjectiveSense(), MOI.MIN_SENSE)
    MOI.set(model, MOI.ObjectiveFunction{typeof(objective)}(), objective)

    summary = NLPDiagnostics.model_summary(model)
    profile = summary.coefficient_profile
    @test summary.variable_count == 2
    @test summary.named_variable_count == 1
    @test summary.constraint_count == 4
    @test summary.variable_domain_constraint_count == 2
    @test summary.discrete_variable_constraint_count == 1
    @test summary.model_fingerprint == NLPDiagnostics.model_fingerprint(model)
    @test summary.bridge_usage_available == false
    @test profile.supported_constraint_count == 4
    @test profile.opaque_constraint_count == 0
    @test profile.linear_matrix_rows == 2
    @test profile.linear_matrix_nonzeros == 3
    @test profile.linear_matrix_density == 3 / 4
    @test profile.linear_matrix.minimum_nonzero_magnitude == 1.0
    @test profile.linear_matrix.maximum_magnitude == 1.0e6
    @test profile.linear_matrix.span_ratio == 1.0e6
    @test profile.quadratic_constraints.minimum_nonzero_magnitude == 2.0
    @test profile.linear_objective.maximum_magnitude == 7.0
    @test profile.quadratic_objective.maximum_magnitude == 3.0
    @test profile.variable_bounds.total_count == 2
    @test profile.variable_bounds.maximum_magnitude == 20.0
    @test profile.right_hand_sides.total_count == 2
    @test sort([profile.right_hand_sides.minimum_nonzero_magnitude,
                profile.right_hand_sides.maximum_magnitude]) == [5.0, 9.0]
    @test any(contains("check units and scaling"), profile.observations)

    summary_data = NLPDiagnostics.model_summary_data(summary)
    @test summary_data["schema_version"] == "nlpdiagnostics-model-summary-v1"
    @test summary_data["coefficient_profile"]["schema_version"] ==
          "nlpdiagnostics-coefficient-profile-v1"
    @test occursin("2 variables", sprint(show, summary))
end

@testset "NLPBlock coverage stays explicit" begin
    model = MOI.Utilities.UniversalFallback(MOI.Utilities.Model{Float64}())
    MOI.add_variable(model)
    MOI.set(model, MOI.ObjectiveSense(), MOI.MIN_SENSE)
    MOI.set(
        model,
        MOI.NLPBlock(),
        MOI.NLPBlockData(
            [MOI.NLPBoundsPair(-Inf, 1.0), MOI.NLPBoundsPair(2.0, Inf)],
            SummaryOpaqueEvaluator(),
            true,
        ),
    )
    summary = NLPDiagnostics.model_summary(model)
    profile = summary.coefficient_profile
    @test summary.constraint_count == 2
    @test summary.scalarized_constraint_count == 2
    @test summary.constraint_type_counts["MOI.NLPBlockData(opaque)"] == 2
    @test profile.opaque_constraint_count == 2
    @test profile.objective_available
    @test profile.objective_opaque
    @test profile.right_hand_sides.total_count == 2
    @test profile.right_hand_sides.minimum_nonzero_magnitude == 1.0
    @test profile.right_hand_sides.maximum_magnitude == 2.0
end

@testset "JuMP summary forwarding" begin
    model = JuMP.Model()
    JuMP.@variable(model, x >= 0)
    JuMP.@constraint(model, 2x <= 4)
    summary = NLPDiagnostics.Stable.model_summary(model)
    @test summary.variable_count == 1
    @test summary.coefficient_profile.linear_matrix.maximum_magnitude == 2.0
end

@testset "profile keeps nonlinear coefficients opaque" begin
    model = MOI.Utilities.UniversalFallback(MOI.Utilities.Model{Float64}())
    x = MOI.add_variable(model)
    nonlinear = MOI.ScalarNonlinearFunction(:*, Any[1.0e9, x])
    MOI.add_constraint(model, nonlinear, MOI.EqualTo(1.0))
    profile = NLPDiagnostics.coefficient_profile(model)
    @test profile.opaque_constraint_count == 1
    @test profile.linear_matrix.total_count == 0
    @test profile.linear_matrix_density === nothing
    @test any(contains("explicit point"), profile.observations)

    snap_summary = NLPDiagnostics.model_summary(NLPDiagnostics.snapshot(model))
    @test snap_summary.model_fingerprint === nothing
end
