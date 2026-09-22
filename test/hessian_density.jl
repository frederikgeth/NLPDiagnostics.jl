@testset "structural and numerical Hessian density" begin
    model = JuMP.Model()
    JuMP.@variable(model, x)
    JuMP.@variable(model, y)
    JuMP.@objective(model, Min, (x * y)^2)

    sparse_at_point = NLPDiagnostics.Stable.hessian_density_summary(
        model,
        [0.0, 1.0];
        label = "axis point",
    )
    @test sparse_at_point isa NLPDiagnostics.HessianDensitySummary{Float64}
    @test sparse_at_point.methods == [:exact_constructed_nonlinear_ad]
    @test sparse_at_point.objective_weight == 1.0
    @test isempty(sparse_at_point.constraint_multipliers)
    @test isempty(sparse_at_point.failures)
    @test sparse_at_point.structure_provenance == :declared_derivative_structure
    @test sparse_at_point.variable_count == 2
    @test sparse_at_point.lower_triangle_slot_count == 3
    @test sparse_at_point.raw_entry_count == 3
    @test sparse_at_point.structural_entry_count == 3
    @test sparse_at_point.numerical_nonzero_count == 1
    @test sparse_at_point.numerical_zero_count == 2
    @test sparse_at_point.nonfinite_count == 0
    @test sparse_at_point.duplicate_entry_count == 0
    @test sparse_at_point.structural_symmetric_entry_count == 4
    @test sparse_at_point.numerical_symmetric_nonzero_count == 1
    @test sparse_at_point.structural_lower_triangle_density == 1.0
    @test sparse_at_point.numerical_lower_triangle_density == 1 / 3
    @test sparse_at_point.structural_symmetric_density == 1.0
    @test sparse_at_point.numerical_symmetric_density == 1 / 4
    @test sparse_at_point.numerical_fraction_of_structure == 1 / 3
    @test sparse_at_point.maximum_absolute_value == 2.0
    @test sparse_at_point.complete
    @test any(contains("globally removable"), sparse_at_point.observations)
    @test occursin("axis point", sprint(show, sparse_at_point))

    dense_at_point = NLPDiagnostics.hessian_density_summary(
        model,
        [1.0, 1.0];
        label = "interior point",
    )
    @test dense_at_point.structural_entry_count == 3
    @test dense_at_point.numerical_nonzero_count == 3
    @test dense_at_point.numerical_lower_triangle_density == 1.0

    data = NLPDiagnostics.Stable.hessian_density_summary_data(sparse_at_point)
    @test data["schema_version"] ==
          "nlpdiagnostics-hessian-density-summary-v1"
    @test data["point"]["label"] == "axis point"
    @test data["objective_weight"] == 1.0
    @test isempty(data["constraint_multipliers"])
    @test isempty(data["failures"])
    @test data["structure_provenance"] == "declared_derivative_structure"
end

@testset "Hessian density duplicate, tolerance, and coverage semantics" begin
    point = NLPDiagnostics.EvaluationPoint(
        [MOI.VariableIndex(1), MOI.VariableIndex(2)],
        [0.0, 0.0];
        label = "constructed evidence",
    )
    failure = NLPDiagnostics.EvaluationFailure(
        :hessian,
        :constructed_test,
        NLPDiagnostics.EntityRef(:constraint, 7; name = "power balance"),
        "DomainError",
        "synthetic partial-coverage failure",
    )
    hessian = NLPDiagnostics.HessianEvaluation(
        point,
        0.5,
        [2.0, -1.0],
        NLPDiagnostics.HessianEntry{Float64}[
            NLPDiagnostics.HessianEntry(1, 1, 2.0),
            NLPDiagnostics.HessianEntry(2, 1, 1.0e-10),
            NLPDiagnostics.HessianEntry(1, 2, -1.0e-10),
            NLPDiagnostics.HessianEntry(2, 2, NaN),
        ],
        [:finite_difference_function_values],
        false,
        [failure],
    )
    summary = NLPDiagnostics.hessian_density_summary(
        hessian;
        relative_tolerance = 1.0e-8,
    )
    @test summary.raw_entry_count == 4
    @test summary.structural_entry_count == 3
    @test summary.duplicate_entry_count == 1
    @test summary.numerical_nonzero_count == 1
    @test summary.numerical_zero_count == 1
    @test summary.nonfinite_count == 1
    @test summary.numerical_zero_threshold == 2.0e-8
    @test summary.structure_provenance == :finite_difference_dense_candidate
    @test summary.objective_weight == 0.5
    @test summary.constraint_multipliers == [2.0, -1.0]
    @test summary.failures == [failure]
    @test !summary.complete
    @test any(contains("dense candidate"), summary.observations)
    @test any(contains("partial evidence"), summary.observations)

    data = NLPDiagnostics.hessian_density_summary_data(summary)
    @test data["objective_weight"] == 0.5
    @test data["constraint_multipliers"] == [2.0, -1.0]
    @test data["failures"][1]["stage"] == "hessian"
    @test data["failures"][1]["source"] == "constructed_test"
    @test data["failures"][1]["affected"]["name"] == "power balance"
    @test data["failures"][1]["exception_type"] == "DomainError"
    @test data["failures"][1]["message"] ==
          "synthetic partial-coverage failure"

    @test_throws ArgumentError NLPDiagnostics.hessian_density_summary(
        hessian;
        absolute_tolerance = -1.0,
    )
    @test_throws ArgumentError NLPDiagnostics.hessian_density_summary(
        hessian;
        relative_tolerance = Inf,
    )
    malformed = NLPDiagnostics.HessianEvaluation(
        point,
        1.0,
        Float64[],
        [NLPDiagnostics.HessianEntry(3, 1, 1.0)],
        [:test],
        true,
        NLPDiagnostics.EvaluationFailure[],
    )
    @test_throws ArgumentError NLPDiagnostics.hessian_density_summary(malformed)
end
