function _scaling_test_evaluation(
    variables, point_values, objective_value, objective_gradient,
    constraint_values, jacobian;
    label,
)
    rows = size(jacobian, 1)
    entries = NLPDiagnostics.JacobianEntry{Float64}[]
    for row in axes(jacobian, 1), column in axes(jacobian, 2)
        iszero(jacobian[row, column]) || push!(entries,
            NLPDiagnostics.JacobianEntry(row, column, jacobian[row, column]))
    end
    return NLPDiagnostics.NumericalEvaluation{Float64}(
        NLPDiagnostics.EvaluationPoint(variables, point_values; label),
        objective_value,
        NLPDiagnostics.EntityRef(:objective, 1; name="objective"),
        Union{Missing,Float64}[objective_gradient...],
        Union{Missing,Float64}[constraint_values...],
        [NLPDiagnostics.EntityRef(:constraint, row; name="row$row")
            for row in 1:rows],
        entries,
        fill(:analytic, rows),
        NLPDiagnostics.EvaluatorCapabilities[],
        NLPDiagnostics.EvaluationFailure[],
        Dict{Symbol,Tuple{Int,Float64}}(),
        :analytic,
    )
end

@testset "Diagonal scaling covariance" begin
    reference = _scaling_test_evaluation(
        [MOI.VariableIndex(1), MOI.VariableIndex(2)],
        [2.0, 3.0], 7.0, [4.0, 1.0], [8.0, 3.0],
        [1.0 2.0; 3.0 -1.0]; label="reference",
    )
    candidate = _scaling_test_evaluation(
        [MOI.VariableIndex(2), MOI.VariableIndex(1)],
        [6.0, 1.0], 1.4, [0.1, 1.6], [30.0, 0.8],
        [-5.0 60.0; 0.1 0.2]; label="candidate",
    )
    reference_map = NLPDiagnostics.DiagonalScalingMap(
        "physical";
        variable_keys=["x", "y"], variable_scales=[1.0, 1.0],
        constraint_keys=["r1", "r2"], constraint_scales=[1.0, 1.0],
        constraint_bounds=[(8.0, 8.0), (0.0, nothing)],
    )
    candidate_map = NLPDiagnostics.DiagonalScalingMap(
        "custom";
        variable_keys=["y", "x"], variable_scales=[0.5, 2.0],
        constraint_keys=["r2", "r1"], constraint_scales=[0.1, 10.0],
        objective_scale=5.0,
        constraint_bounds=[(0.0, nothing), (0.8, 0.8)],
    )
    report = NLPDiagnostics.scaling_covariance_report(
        reference, reference_map, candidate, candidate_map)
    @test report["report_version"] == "diagonal-scaling-covariance-v1"
    @test report["semantic_alignment"]
    @test report["overall_covariant"]
    @test report["equivalence_gate_passed"]
    @test report["constraint_set_coverage_complete"]
    @test report["metrics"]["physical_point"]["passed"]
    @test report["metrics"]["constraint_function_values"]["passed"]
    @test report["metrics"]["constraint_sets"]["passed"]
    @test report["metrics"]["constraint_residuals"]["passed"]
    @test report["metrics"]["objective_value"]["passed"]
    @test report["metrics"]["objective_gradient"]["passed"]
    @test report["metrics"]["physical_jacobian"]["passed"]
    @test report["metrics"]["physical_jacobian"]["physical_rank_agrees"]

    geometry = NLPDiagnostics.scaling_coordinate_geometry_report(
        reference, reference_map, candidate, candidate_map)
    @test geometry["comparison_qualified"]
    @test geometry["reference_geometry"]["spectrum_available"]
    @test geometry["candidate_geometry"]["spectrum_available"]
    @test geometry["comparisons"]["zero_pattern"]["counts_agree"]
    @test geometry["comparisons"]["condition_proxy"]["relation"] in
        ("candidate_lower", "candidate_higher", "approximately_equal")
    guarded_geometry = NLPDiagnostics.scaling_coordinate_geometry_report(
        reference, reference_map, candidate, candidate_map;
        max_dense_entries=0)
    @test guarded_geometry["comparison_qualified"]
    @test guarded_geometry["covariance"]["equivalence_gate_passed"]
    @test guarded_geometry["covariance"]["metrics"]["physical_jacobian"][
        "comparison_backend"] == "semantic_sparse_entries"
    @test !guarded_geometry["covariance"]["metrics"]["physical_jacobian"][
        "physical_rank_available"]
    @test !guarded_geometry["reference_geometry"]["spectrum_available"]

    broken_candidate = _scaling_test_evaluation(
        [MOI.VariableIndex(2), MOI.VariableIndex(1)],
        [6.0, 1.0], 1.4, [0.1, 1.6], [31.0, 0.8],
        [-5.0 60.0; 0.1 0.2]; label="broken",
    )
    broken = NLPDiagnostics.scaling_covariance_report(
        reference, reference_map, broken_candidate, candidate_map)
    @test !broken["overall_covariant"]
    @test !broken["equivalence_gate_passed"]
    @test !broken["metrics"]["constraint_function_values"]["passed"]
    broken_geometry = NLPDiagnostics.scaling_coordinate_geometry_report(
        reference, reference_map, broken_candidate, candidate_map)
    @test !broken_geometry["comparison_qualified"]

    partial = NLPDiagnostics.NumericalEvaluation{Float64}(
        candidate.point, candidate.objective_value, candidate.objective_source,
        candidate.objective_gradient, candidate.constraint_values,
        candidate.constraint_sources, candidate.jacobian_entries,
        [:analytic, :unavailable], candidate.capabilities, candidate.failures,
        candidate.call_statistics, candidate.objective_gradient_method,
    )
    partial_report = NLPDiagnostics.scaling_covariance_report(
        reference, reference_map, partial, candidate_map)
    @test partial_report["overall_covariant"] === nothing
    @test !partial_report["metrics"]["physical_jacobian"]["available"]

    boundless_candidate_map = NLPDiagnostics.DiagonalScalingMap(
        "custom-without-set-semantics";
        variable_keys=["y", "x"], variable_scales=[0.5, 2.0],
        constraint_keys=["r2", "r1"], constraint_scales=[0.1, 10.0],
        objective_scale=5.0)
    boundless_report = NLPDiagnostics.scaling_covariance_report(
        reference, reference_map, candidate, boundless_candidate_map)
    @test boundless_report["overall_covariant"]
    @test boundless_report["equivalence_gate_passed"] === nothing
    @test !boundless_report["metrics"]["constraint_sets"]["available"]

    nonfinite = _scaling_test_evaluation(
        [MOI.VariableIndex(2), MOI.VariableIndex(1)],
        [Inf, 1.0], 1.4, [0.1, 1.6], [30.0, 0.8],
        [-5.0 60.0; 0.1 0.2]; label="nonfinite",
    )
    nonfinite_report = NLPDiagnostics.scaling_covariance_report(
        reference, reference_map, nonfinite, candidate_map)
    @test nonfinite_report["overall_covariant"] === nothing
    @test !nonfinite_report["metrics"]["physical_point"]["available"]

    @test_throws ArgumentError NLPDiagnostics.DiagonalScalingMap(
        "bad"; variable_keys=["x"], variable_scales=[0.0],
        constraint_keys=String[], constraint_scales=Float64[])
    mismatched_map = NLPDiagnostics.DiagonalScalingMap(
        "mismatch"; variable_keys=["x", "z"], variable_scales=[1.0, 1.0],
        constraint_keys=["r1", "r2"], constraint_scales=[1.0, 1.0],
        constraint_bounds=[(8.0, 8.0), (0.0, nothing)])
    @test_throws ArgumentError NLPDiagnostics.scaling_covariance_report(
        reference, reference_map, candidate, mismatched_map)
end
