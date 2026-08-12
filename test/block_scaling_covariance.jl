function _permuted_block_vector(block_values, positions)
    result = zeros(eltype(block_values), length(positions))
    result[positions] = block_values
    return result
end

function _permuted_block_matrix(block_matrix, row_positions, column_positions)
    result = zeros(eltype(block_matrix), length(row_positions), length(column_positions))
    result[row_positions, column_positions] = block_matrix
    return result
end

function _test_hessian(evaluation, objective_weight, multipliers, matrix)
    entries = NLPDiagnostics.HessianEntry{Float64}[]
    for row in axes(matrix, 1), column in 1:row
        iszero(matrix[row, column]) || push!(
            entries,
            NLPDiagnostics.HessianEntry(row, column, matrix[row, column]),
        )
    end
    return NLPDiagnostics.HessianEvaluation(
        evaluation.point,
        objective_weight,
        multipliers,
        entries,
        [:analytic],
        true,
        NLPDiagnostics.EvaluationFailure[],
    )
end

@testset "Semantic block scaling covariance" begin
    theta_variable = 0.37
    theta_constraint = -0.61
    variable_rotation = [
        cos(theta_variable) -sin(theta_variable)
        sin(theta_variable) cos(theta_variable)
    ]
    constraint_rotation = [
        cos(theta_constraint) -sin(theta_constraint)
        sin(theta_constraint) cos(theta_constraint)
    ]
    physical_point = [2.0, -0.4]
    physical_constraint = [0.0, 0.0]
    physical_gradient = [1.2, -0.7]
    physical_jacobian = [2.0 0.5; -1.0 3.0]
    physical_hessian = [4.0 1.0; 1.0 3.0]
    physical_multipliers = [0.8, -1.1]
    objective_scale = 5.0

    reference = _scaling_test_evaluation(
        [MOI.VariableIndex(1), MOI.VariableIndex(2)],
        physical_point,
        2.0,
        physical_gradient,
        physical_constraint,
        physical_jacobian;
        label="block-reference",
    )
    positions = [2, 1]
    candidate_point_block = transpose(variable_rotation) * physical_point
    candidate_constraint_block = transpose(constraint_rotation) *
        physical_constraint
    candidate_gradient_block = transpose(variable_rotation) *
        physical_gradient / objective_scale
    candidate_jacobian_block = transpose(constraint_rotation) *
        physical_jacobian * variable_rotation
    candidate = _scaling_test_evaluation(
        [MOI.VariableIndex(11), MOI.VariableIndex(12)],
        _permuted_block_vector(candidate_point_block, positions),
        2.0 / objective_scale,
        _permuted_block_vector(candidate_gradient_block, positions),
        _permuted_block_vector(candidate_constraint_block, positions),
        _permuted_block_matrix(candidate_jacobian_block, positions, positions);
        label="block-candidate",
    )

    reference_map = NLPDiagnostics.SemanticBlockScalingMap(
        "physical";
        variable_blocks=[NLPDiagnostics.SemanticLinearBlock(
            ["vr", "vi"], [1, 2], [1.0 0.0; 0.0 1.0],
        )],
        constraint_blocks=[NLPDiagnostics.SemanticConstraintBlock(
            ["p", "q"], [1, 2], [1.0 0.0; 0.0 1.0];
            set=NLPDiagnostics.ZeroEqualitySetContract(),
        )],
    )
    candidate_map = NLPDiagnostics.SemanticBlockScalingMap(
        "rotated";
        variable_blocks=[NLPDiagnostics.SemanticLinearBlock(
            ["vr", "vi"], positions, variable_rotation,
        )],
        constraint_blocks=[NLPDiagnostics.SemanticConstraintBlock(
            ["p", "q"], positions, constraint_rotation;
            set=NLPDiagnostics.ZeroEqualitySetContract(),
        )],
        objective_scale,
    )
    intervention = NLPDiagnostics.scaling_intervention_classification(
        reference_map, candidate_map,
    )
    @test intervention["available"]
    @test intervention["classification"] == "magnitude_and_phase"
    @test intervention["variables"]["classification"] ==
          "phase_like_orthogonal"
    @test intervention["constraints"]["classification"] ==
          "phase_like_orthogonal"
    @test !intervention["qualification"][
        "phase_like_is_physical_phase_claim"
    ]
    phase_map = NLPDiagnostics.SemanticBlockScalingMap(
        "phase-only";
        variable_blocks=candidate_map.variable_blocks,
        constraint_blocks=candidate_map.constraint_blocks,
    )
    @test NLPDiagnostics.scaling_intervention_classification(
        reference_map, phase_map,
    )["classification"] == "phase_only"
    @test !NLPDiagnostics.scaling_intervention_classification(
        reference_map, phase_map; max_dense_entries=1,
    )["available"]

    report = NLPDiagnostics.scaling_covariance_report(
        reference, reference_map, candidate, candidate_map,
    )
    @test report["report_version"] ==
        "semantic-block-scaling-covariance-v1"
    @test report["overall_covariant"]
    @test report["equivalence_gate_passed"]
    @test report["constraint_set_coverage_complete"]
    @test all(metric["passed"] for metric in values(report["metrics"]))
    @test report["metrics"]["physical_jacobian"]["physical_rank_agrees"]

    transport = NLPDiagnostics.transport_scaling_point(
        reference.point,
        reference_map,
        candidate.point.variables,
        candidate_map;
        label="transported-physical-state",
    )
    @test transport.point.provenance.kind == NLPDiagnostics.TransportedPoint
    @test transport.point.provenance.complete
    @test transport.finite
    @test transport.maximum_roundtrip_error <= 10eps(Float64)
    @test transport.point.values ≈ candidate.point.values
    transport_data = NLPDiagnostics.scaling_point_transport_data(transport)
    @test transport_data["report_version"] == "scaling-point-transport-v1"
    @test transport_data["qualification"]["claim"] ==
        "exact declared coordinate transport at one point"
    transported_trust = NLPDiagnostics.select_trusted_evaluation_points([
        transport.point,
    ])
    @test isempty(transported_trust.selected)
    @test length(transported_trust.rejected) == 1

    physical_feasibility = NLPDiagnostics.physical_feasibility_report(
        reference,
        reference_map;
        absolute_tolerances=Dict("p\u001fq" => 1e-8),
    )
    @test physical_feasibility["available"]
    @test physical_feasibility["tolerance_coverage_complete"]
    @test physical_feasibility["acceptance_passed"]
    @test physical_feasibility["configured_residual_count"] == 1

    unconfigured_feasibility = NLPDiagnostics.physical_feasibility_report(
        reference, reference_map,
    )
    @test unconfigured_feasibility["available"]
    @test !unconfigured_feasibility["tolerance_coverage_complete"]
    @test !unconfigured_feasibility["acceptance_passed"]

    infeasible_reference = _scaling_test_evaluation(
        reference.point.variables,
        reference.point.values,
        reference.objective_value,
        physical_gradient,
        [2e-3, 0.0],
        physical_jacobian;
        label="block-reference-infeasible",
    )
    failed_feasibility = NLPDiagnostics.physical_feasibility_report(
        infeasible_reference,
        reference_map;
        absolute_tolerances=Dict("p\u001fq" => 1e-3),
    )
    @test !failed_feasibility["acceptance_passed"]
    @test only(values(failed_feasibility["residuals"]))["violation"] ≈
        2e-3

    stationary_gradient = -transpose(physical_jacobian) *
        physical_multipliers
    stationary_reference = _scaling_test_evaluation(
        reference.point.variables,
        reference.point.values,
        reference.objective_value,
        stationary_gradient,
        physical_constraint,
        physical_jacobian;
        label="block-reference-stationary",
    )
    stationarity = NLPDiagnostics.physical_stationarity_report(
        stationary_reference,
        reference_map,
        physical_multipliers;
        absolute_tolerances=Dict("vr" => 1e-12, "vi" => 1e-12),
    )
    @test stationarity["available"]
    @test stationarity["tolerance_coverage_complete"]
    @test stationarity["acceptance_passed"]
    @test all(
        record["absolute_residual"] <= 1e-12 for
        record in values(stationarity["stationarity"])
    )
    failed_stationarity = NLPDiagnostics.physical_stationarity_report(
        stationary_reference,
        reference_map,
        physical_multipliers .+ [0.1, 0.0];
        default_absolute_tolerance=1e-12,
    )
    @test !failed_stationarity["acceptance_passed"]
    physical_kkt_acceptance =
        NLPDiagnostics.physical_kkt_acceptance_report(
            stationary_reference,
            reference_map,
            physical_multipliers;
            feasibility_absolute_tolerances=Dict("p\u001fq" => 1e-12),
            stationarity_absolute_tolerances=Dict(
                "vr" => 1e-12, "vi" => 1e-12,
            ),
        )
    @test physical_kkt_acceptance["acceptance_passed"]
    @test physical_kkt_acceptance["complementarity"]["available"]
    @test !physical_kkt_acceptance["complementarity"]["applicable"]

    # A feasibility model may expose no objective gradient at all. Empty
    # vectors are incomplete evidence, not vacuously complete derivatives and
    # must not be multiplied by a nonempty coordinate map.
    no_objective_reference = _scaling_test_evaluation(
        reference.point.variables,
        reference.point.values,
        nothing,
        Float64[],
        physical_constraint,
        physical_jacobian;
        label="block-reference-no-objective",
    )
    no_objective_candidate = _scaling_test_evaluation(
        candidate.point.variables,
        candidate.point.values,
        nothing,
        Float64[],
        _permuted_block_vector(candidate_constraint_block, positions),
        _permuted_block_matrix(
            candidate_jacobian_block, positions, positions,
        );
        label="block-candidate-no-objective",
    )
    no_objective_report = NLPDiagnostics.scaling_covariance_report(
        no_objective_reference,
        reference_map,
        no_objective_candidate,
        candidate_map,
    )
    @test no_objective_report["equivalence_gate_passed"]
    @test !no_objective_report["metrics"]["objective_gradient"]["available"]
    zero_objective_stationarity =
        NLPDiagnostics.physical_stationarity_report(
            no_objective_reference,
            reference_map,
            zeros(2);
            objective_weight=0.0,
            default_absolute_tolerance=0.0,
        )
    @test zero_objective_stationarity["available"]
    @test zero_objective_stationarity["acceptance_passed"]
    @test !zero_objective_stationarity["objective_gradient_required"]
    @test !zero_objective_stationarity["objective_gradient_available"]

    geometry = NLPDiagnostics.scaling_coordinate_geometry_report(
        reference, reference_map, candidate, candidate_map,
    )
    @test geometry["comparison_qualified"]
    invariance = geometry["comparisons"][
        "orthogonal_singular_value_invariance"
    ]
    @test invariance["expected_from_complete_orthogonal_blocks"]
    @test invariance["passed"]
    @test geometry["comparisons"]["condition_proxy"]["relation"] ==
        "approximately_equal"

    reference_hessian = _test_hessian(
        reference,
        1.0,
        physical_multipliers,
        physical_hessian,
    )
    candidate_hessian_block = transpose(variable_rotation) *
        physical_hessian * variable_rotation
    candidate_hessian = _test_hessian(
        candidate,
        objective_scale,
        _permuted_block_vector(
            transpose(constraint_rotation) * physical_multipliers,
            positions,
        ),
        _permuted_block_matrix(
            candidate_hessian_block, positions, positions,
        ),
    )
    kkt = NLPDiagnostics.scaling_kkt_covariance_report(
        reference,
        reference_map,
        reference_hessian,
        candidate,
        candidate_map,
        candidate_hessian,
    )
    @test kkt["optimality_covariant"]
    @test kkt["metrics"]["physical_objective_weight"]["passed"]
    @test kkt["metrics"]["physical_multipliers"]["passed"]
    @test kkt["metrics"]["physical_stationarity"]["passed"]
    @test kkt["metrics"]["physical_lagrangian_hessian"]["passed"]
    @test kkt["metrics"]["physical_kkt_matrix"]["passed"]
    @test !kkt["metrics"]["complementarity"]["available"]
    @test kkt["metrics"]["complementarity"][
        "not_applicable_for_zero_equalities"
    ]

    guarded_kkt = NLPDiagnostics.scaling_kkt_covariance_report(
        reference,
        reference_map,
        reference_hessian,
        candidate,
        candidate_map,
        candidate_hessian;
        max_dense_entries=0,
    )
    @test guarded_kkt["optimality_covariant"] === nothing
    @test guarded_kkt["metrics"]["physical_multipliers"]["passed"]
    @test guarded_kkt["metrics"]["physical_stationarity"]["passed"]
    @test !guarded_kkt["metrics"]["physical_lagrangian_hessian"][
        "available"
    ]
    @test !guarded_kkt["metrics"]["physical_kkt_matrix"]["available"]

    wrong_candidate_hessian = _test_hessian(
        candidate,
        objective_scale,
        candidate_hessian.constraint_multipliers .+ [0.1, 0.0],
        _permuted_block_matrix(
            candidate_hessian_block, positions, positions,
        ),
    )
    wrong_kkt = NLPDiagnostics.scaling_kkt_covariance_report(
        reference,
        reference_map,
        reference_hessian,
        candidate,
        candidate_map,
        wrong_candidate_hessian,
    )
    @test !wrong_kkt["optimality_covariant"]
    @test !wrong_kkt["metrics"]["physical_multipliers"]["passed"]
    @test !wrong_kkt["metrics"]["physical_stationarity"]["passed"]

    reference_ball_map = NLPDiagnostics.SemanticBlockScalingMap(
        "physical-ball";
        variable_blocks=reference_map.variable_blocks,
        constraint_blocks=[NLPDiagnostics.SemanticConstraintBlock(
            ["p", "q"], [1, 2], [1.0 0.0; 0.0 1.0];
            set=NLPDiagnostics.EuclideanBallSetContract(2.0),
        )],
    )
    candidate_ball_map = NLPDiagnostics.SemanticBlockScalingMap(
        "rotated-ball";
        variable_blocks=candidate_map.variable_blocks,
        constraint_blocks=[NLPDiagnostics.SemanticConstraintBlock(
            ["p", "q"], positions, constraint_rotation;
            set=NLPDiagnostics.EuclideanBallSetContract(2.0),
        )],
        objective_scale,
    )
    ball_report = NLPDiagnostics.scaling_covariance_report(
        reference, reference_ball_map, candidate, candidate_ball_map,
    )
    @test ball_report["metrics"]["constraint_sets"]["passed"]
    @test ball_report["metrics"]["constraint_residuals"]["passed"]
    @test ball_report["equivalence_gate_passed"]
    inequality_kkt = NLPDiagnostics.physical_kkt_acceptance_report(
        stationary_reference,
        reference_ball_map,
        physical_multipliers;
        feasibility_default_absolute_tolerance=1e-12,
        stationarity_default_absolute_tolerance=1e-12,
    )
    @test inequality_kkt["acceptance_passed"] === nothing
    @test !inequality_kkt["complementarity"]["available"]
    @test inequality_kkt["complementarity"]["applicable"]

    reference_box_map = NLPDiagnostics.SemanticBlockScalingMap(
        "physical-box";
        variable_blocks=reference_map.variable_blocks,
        constraint_blocks=[NLPDiagnostics.SemanticConstraintBlock(
            ["p", "q"], [1, 2], [1.0 0.0; 0.0 1.0];
            set=NLPDiagnostics.ScalarBoundsSetContract([
                (-1.0, 1.0), (-1.0, 1.0),
            ]),
        )],
    )
    candidate_box_map = NLPDiagnostics.SemanticBlockScalingMap(
        "rotated-box";
        variable_blocks=candidate_map.variable_blocks,
        constraint_blocks=[NLPDiagnostics.SemanticConstraintBlock(
            ["p", "q"], positions, constraint_rotation;
            set=NLPDiagnostics.ScalarBoundsSetContract([
                (-1.0, 1.0), (-1.0, 1.0),
            ]),
        )],
        objective_scale,
    )
    box_report = NLPDiagnostics.scaling_covariance_report(
        reference, reference_box_map, candidate, candidate_box_map,
    )
    @test box_report["overall_covariant"]
    @test box_report["equivalence_gate_passed"] === nothing
    @test !box_report["metrics"]["constraint_sets"]["available"]
    @test occursin(
        "rotated box",
        only(box_report["metrics"]["constraint_sets"][
            "candidate_unavailable_reasons"
        ]),
    )

    magnitude_map = NLPDiagnostics.SemanticBlockScalingMap(
        "magnitude";
        variable_blocks=[NLPDiagnostics.SemanticLinearBlock(
            ["vr", "vi"], [1, 2], [2.0 0.0; 0.0 0.5],
        )],
        constraint_blocks=reference_map.constraint_blocks,
    )
    @test NLPDiagnostics.scaling_intervention_classification(
        reference_map, magnitude_map,
    )["classification"] == "magnitude_only"
    magnitude_geometry = NLPDiagnostics.scaling_coordinate_geometry_report(
        reference,
        reference_map,
        reference,
        magnitude_map,
    )
    @test !magnitude_geometry["comparisons"][
        "orthogonal_singular_value_invariance"
    ]["expected_from_complete_orthogonal_blocks"]
    @test !magnitude_geometry["comparisons"][
        "orthogonal_singular_value_invariance"
    ]["available"]

    @test_throws ArgumentError NLPDiagnostics.SemanticLinearBlock(
        ["x", "y"], [1, 2], [1.0 0.0; 0.0 0.0],
    )
    @test_throws ArgumentError NLPDiagnostics.SemanticBlockScalingMap(
        "gap";
        variable_blocks=[NLPDiagnostics.SemanticLinearBlock(
            ["x"], [2], reshape([1.0], 1, 1),
        )],
        constraint_blocks=reference_map.constraint_blocks,
    )
end
