function _bmopf_covariance_fixture()
    return BMOPFTools.parse_bmopf(raw"""
    {"bus":{
        "source":{"terminal_names":["1","n"],
                  "perfectly_grounded_terminals":["n"]},
        "loadbus":{"terminal_names":["1","n"],
                   "perfectly_grounded_terminals":["n"]}},
     "voltage_source":{"source":{"bus":"source","terminal_map":["1"],
         "v_magnitude":[1000.0],"v_angle":[0.0]}},
     "linecode":{"lc":{"R_series_1_1":0.5,"R_series_2_2":0.5,
         "i_max":[500.0,500.0]}},
     "line":{"line":{"bus_from":"source","bus_to":"loadbus",
         "terminal_map_from":["1","n"],"terminal_map_to":["1","n"],
         "linecode":"lc","length":1.0}},
     "load":{"load":{"bus":"loadbus","terminal_map":["1","n"],
         "configuration":"WYE","p_nom":[100000.0],"q_nom":[20000.0]}}}
    """; from_string=true)
end

function _bmopf_covariance_evaluation(context, label)
    BMOPFTools.opf_lifecycle(context) == :kcl_finalized ||
        BMOPFTools.enforce_kcl!(context)
    point = NLPDiagnostics.bmopf_start_completion_point(
        context; missing_value=0.0, label)
    return NLPDiagnostics.evaluate_numerical(
        JuMP.backend(BMOPFTools.opf_model(context)), point)
end

@testset "BMOPF cross-policy physical scaling covariance" begin
    network = _bmopf_covariance_fixture()
    classic = BMOPFTools.ClassicPerUnitScaling(1e6)
    custom = BMOPFTools.ConsistentPerUnitScaling(
        name=:half_voltage_200kva,
        s_base=2e5,
        voltage_bases=Dict("source" => 500.0, "loadbus" => 500.0),
    )
    reference_context = BMOPFTools.build_opf_model(
        network; scaling_policy=classic, add_objective=false)
    candidate_context = BMOPFTools.build_opf_model(
        network; scaling_policy=custom, add_objective=false)
    reference_evaluation = _bmopf_covariance_evaluation(
        reference_context, "classic-start")
    candidate_evaluation = _bmopf_covariance_evaluation(
        candidate_context, "custom-start")

    reference_map = NLPDiagnostics.bmopf_diagonal_scaling_map(
        reference_context, reference_evaluation)
    candidate_map = NLPDiagnostics.bmopf_diagonal_scaling_map(
        candidate_context, candidate_evaluation)
    @test reference_map["available"]
    @test candidate_map["available"]
    @test isempty(reference_map["unsupported_variables"])
    @test isempty(reference_map["unsupported_constraint_rows"])

    reference_block_map = NLPDiagnostics.bmopf_semantic_block_scaling_map(
        reference_context, reference_evaluation)
    candidate_block_map = NLPDiagnostics.bmopf_semantic_block_scaling_map(
        candidate_context, candidate_evaluation)
    @test reference_block_map["available"]
    @test candidate_block_map["available"]
    @test reference_block_map["applied_variable_block_count"] > 0
    @test reference_block_map["applied_constraint_block_count"] > 0
    @test isempty(reference_block_map["skipped_declarations"])
    @test any(record ->
        record["quantity"] == "power" &&
        record["reference_scale_source"] ==
            "load per-phase nominal apparent power" &&
        record["reference_physical_scale"] ≈ hypot(100000.0, 20000.0),
        reference_block_map["reference_scales"],
    )

    transported = NLPDiagnostics.bmopf_transport_scaling_point(
        reference_context,
        reference_evaluation,
        candidate_context,
        candidate_evaluation;
        label="classic-state-in-custom-coordinates",
    )
    @test transported["available"]
    @test transported["semantic_blocks"]
    @test transported["transport"].point.provenance.kind ==
        NLPDiagnostics.TransportedPoint
    @test transported["maximum_roundtrip_error"] <= 1e-8
    transported_evaluation = NLPDiagnostics.evaluate_numerical(
        JuMP.backend(BMOPFTools.opf_model(candidate_context)),
        transported["transport"].point,
    )
    transported_covariance =
        NLPDiagnostics.bmopf_block_scaling_covariance_report(
            reference_context,
            reference_evaluation,
            candidate_context,
            transported_evaluation;
            relative_tolerance=5e-9,
            absolute_tolerance=1e-9,
        )
    @test transported_covariance["equivalence_gate_passed"]
    @test transported_covariance["metrics"]["physical_point"]["passed"]

    quantity_tolerances = Dict(
        quantity => 1e100 for quantity in
        union(Set(reference_map["constraint_quantities"]), Set(["mixed"]))
    )
    feasibility = NLPDiagnostics.bmopf_physical_feasibility_report(
        reference_context,
        reference_evaluation;
        quantity_absolute_tolerances=quantity_tolerances,
    )
    @test feasibility["available"]
    @test feasibility["tolerance_coverage_complete"]
    @test feasibility["acceptance_passed"]
    @test all(
        residual["physical_quantity"] != "unknown" for
        residual in values(feasibility["residuals"])
    )
    @test feasibility["qualification"]["solver_option_translation"] ==
        "not claimed; solver-internal scaled stopping tests remain separate evidence"

    report = NLPDiagnostics.bmopf_scaling_covariance_report(
        reference_context, reference_evaluation,
        candidate_context, candidate_evaluation;
        relative_tolerance=5e-9, absolute_tolerance=1e-9,
    )
    @test report["available"]
    @test report["semantic_alignment"]
    @test report["equivalence_gate_passed"]
    @test report["metrics"]["physical_point"]["passed"]
    @test report["metrics"]["constraint_function_values"]["passed"]
    @test report["metrics"]["constraint_sets"]["passed"]
    @test report["metrics"]["constraint_residuals"]["passed"]
    @test report["metrics"]["physical_jacobian"]["passed"]

    block_report = NLPDiagnostics.bmopf_block_scaling_covariance_report(
        reference_context, reference_evaluation,
        candidate_context, candidate_evaluation;
        relative_tolerance=5e-9, absolute_tolerance=1e-9,
    )
    @test block_report["available"]
    @test block_report["semantic_alignment"]
    @test block_report["equivalence_gate_passed"]
    @test block_report["metrics"]["constraint_sets"]["passed"]
    @test block_report["metrics"]["constraint_residuals"]["passed"]
    @test block_report["metrics"]["physical_jacobian"]["passed"]

    geometry = NLPDiagnostics.bmopf_scaling_coordinate_geometry_report(
        reference_context, reference_evaluation,
        candidate_context, candidate_evaluation;
        relative_tolerance=5e-9, absolute_tolerance=1e-9,
    )
    @test geometry["available"]
    @test geometry["comparison_qualified"]
    @test geometry["reference_geometry"]["spectrum_available"]
    @test geometry["candidate_geometry"]["spectrum_available"]
    @test geometry["comparisons"]["condition_proxy"]["relation"] in
        ("candidate_lower", "candidate_higher", "approximately_equal")

    block_geometry =
        NLPDiagnostics.bmopf_block_scaling_coordinate_geometry_report(
            reference_context, reference_evaluation,
            candidate_context, candidate_evaluation;
            relative_tolerance=5e-9, absolute_tolerance=1e-9,
        )
    @test block_geometry["available"]
    @test block_geometry["comparison_qualified"]
    @test block_geometry["reference_geometry"]["spectrum_available"]
    @test block_geometry["candidate_geometry"]["spectrum_available"]

    # A physical coefficient change is not a scaling policy. The same semantic
    # alignment and complete scale coverage must not let it through the gate.
    perturbed_network = deepcopy(network)
    perturbed_network["linecode"]["lc"]["R_series_1_1"] = 0.6
    perturbed_context = BMOPFTools.build_opf_model(
        perturbed_network; scaling_policy=custom, add_objective=false)
    perturbed_evaluation = _bmopf_covariance_evaluation(
        perturbed_context, "custom-perturbed-physics")
    rejected = NLPDiagnostics.bmopf_scaling_covariance_report(
        reference_context, reference_evaluation,
        perturbed_context, perturbed_evaluation;
        relative_tolerance=5e-9, absolute_tolerance=1e-9,
    )
    @test rejected["available"]
    @test rejected["metrics"]["physical_point"]["passed"]
    @test !rejected["metrics"]["physical_jacobian"]["passed"]
    @test !rejected["equivalence_gate_passed"]

    block_rejected = NLPDiagnostics.bmopf_block_scaling_covariance_report(
        reference_context, reference_evaluation,
        perturbed_context, perturbed_evaluation;
        relative_tolerance=5e-9, absolute_tolerance=1e-9,
    )
    @test block_rejected["available"]
    @test !block_rejected["metrics"]["physical_jacobian"]["passed"]
    @test !block_rejected["equivalence_gate_passed"]
end

@testset "BMOPF solved physical state across four scaling policies" begin
    network = _bmopf_covariance_fixture()
    reference_context = BMOPFTools.build_opf_model(
        deepcopy(network);
        scaling_policy=BMOPFTools.ClassicPerUnitScaling(1e6),
        add_objective=false,
    )
    BMOPFTools.enforce_kcl!(reference_context)
    reference_model = BMOPFTools.opf_model(reference_context)
    JuMP.set_silent(reference_model)
    reference_run = NLPDiagnostics.ipopt_profile_with_iteration_trace!(
        reference_model; capture_points=true,
    )
    @test JuMP.termination_status(reference_model) in
        (MOI.LOCALLY_SOLVED, MOI.OPTIMAL)
    @test JuMP.primal_status(reference_model) == MOI.FEASIBLE_POINT
    reference_point = NLPDiagnostics.solver_result_point(
        reference_model; label="classic-feasible-solution",
    )
    @test !isnothing(reference_point)
    @test reference_point.provenance.kind == NLPDiagnostics.SolverResultPoint
    reference_evaluation = NLPDiagnostics.evaluate_numerical(
        JuMP.backend(reference_model), reference_point,
    )
    reference_map = NLPDiagnostics.bmopf_diagonal_scaling_map(
        reference_context, reference_evaluation,
    )
    quantity_tolerances = Dict(
        quantity => 1.0 for quantity in unique(
            reference_map["constraint_quantities"],
        )
    )
    reference_feasibility =
        NLPDiagnostics.bmopf_physical_feasibility_report(
            reference_context,
            reference_evaluation;
            quantity_absolute_tolerances=quantity_tolerances,
        )
    @test reference_feasibility["acceptance_passed"]
    reference_kkt = NLPDiagnostics.bmopf_physical_solver_kkt_report(
        reference_context,
        reference_model,
        reference_evaluation;
        semantic_blocks=false,
        quantity_feasibility_absolute_tolerances=quantity_tolerances,
        stationarity_default_absolute_tolerance=1.0e-5,
        dual_default_absolute_tolerance=1.0e-5,
        complementarity_default_absolute_tolerance=1.0e-5,
    )
    @test reference_kkt["available"]
    @test reference_kkt["acceptance_passed"]
    @test reference_kkt["stationarity"]["acceptance_passed"]
    @test reference_kkt["complementarity"]["acceptance_passed"]
    attribution = reference_kkt["semantic_attribution"]
    @test attribution["available"]
    @test attribution["interpretation_qualified"]
    @test attribution["registry_coverage_complete"]
    @test isempty(attribution["missing_record_attributions"])
    @test !isempty(attribution["primal_feasibility"]["families"])
    @test !isempty(attribution["stationarity"]["families"])
    @test attribution["complementarity"]["applicable"]
    @test !isempty(attribution["complementarity"]["families"])
    @test haskey(
        attribution["complementarity"]["families"],
        "line_current_thermal",
    )
    @test all(
        summary -> haskey(summary, "maxima"),
        values(attribution["primal_feasibility"]["families"]),
    )
    trace_endpoint =
        NLPDiagnostics.bmopf_solver_trace_physical_endpoint_data(
            reference_context,
            reference_model,
            reference_run;
            semantic_blocks=false,
            quantity_feasibility_absolute_tolerances=quantity_tolerances,
            stationarity_default_absolute_tolerance=1.0e-5,
            dual_default_absolute_tolerance=1.0e-5,
            complementarity_default_absolute_tolerance=1.0e-5,
        )
    @test trace_endpoint["schema_version"] ==
        "bmopf-solver-trace-physical-endpoint-v1"
    @test trace_endpoint["available"]
    @test trace_endpoint["acceptance_passed"]
    @test trace_endpoint["physical_endpoint"]["semantic_attribution"][
        "available"
    ]
    @test trace_endpoint["solver_trace_profile"]["iteration_trace"][
        "record_count"
    ] == length(reference_run.trace.records)

    policies = (
        BMOPFTools.SIUnitsScaling(),
        BMOPFTools.ConsistentPerUnitScaling(
            name=:low_local_bases,
            s_base=2e5,
            voltage_bases=Dict("source" => 500.0, "loadbus" => 500.0),
        ),
        BMOPFTools.ConsistentPerUnitScaling(
            name=:high_local_bases,
            s_base=5e6,
            voltage_bases=Dict("source" => 1500.0, "loadbus" => 1500.0),
        ),
    )
    for policy in policies
        target_context = BMOPFTools.build_opf_model(
            deepcopy(network); scaling_policy=policy, add_objective=false,
        )
        target_schema = _bmopf_covariance_evaluation(
            target_context, "target-schema",
        )
        transported = NLPDiagnostics.bmopf_transport_scaling_point(
            reference_context,
            reference_evaluation,
            target_context,
            target_schema,
        )
        @test transported["available"]
        @test transported["transport"].point.provenance.kind ==
            NLPDiagnostics.TransportedPoint
        @test transported["maximum_roundtrip_error"] <= 1e-8
        target_evaluation = NLPDiagnostics.evaluate_numerical(
            JuMP.backend(BMOPFTools.opf_model(target_context)),
            transported["transport"].point,
        )
        covariance = NLPDiagnostics.bmopf_block_scaling_covariance_report(
            reference_context,
            reference_evaluation,
            target_context,
            target_evaluation;
            absolute_tolerance=1e-5,
            relative_tolerance=1e-8,
        )
        @test covariance["equivalence_gate_passed"]
        @test covariance["metrics"]["physical_point"]["passed"]
        @test covariance["metrics"]["constraint_residuals"]["passed"]
        @test covariance["metrics"]["physical_jacobian"]["passed"]
        @test covariance["metrics"]["physical_jacobian"][
            "physical_rank_agrees"
        ]
        geometry =
            NLPDiagnostics.bmopf_block_scaling_coordinate_geometry_report(
                reference_context,
                reference_evaluation,
                target_context,
                target_evaluation;
                absolute_tolerance=1e-5,
                relative_tolerance=1e-8,
            )
        @test geometry["comparison_qualified"]
        target_feasibility =
            NLPDiagnostics.bmopf_physical_feasibility_report(
                target_context,
                target_evaluation;
                quantity_absolute_tolerances=quantity_tolerances,
            )
        @test target_feasibility["acceptance_passed"]
        @test target_feasibility["tolerance_coverage_complete"]
    end
end
