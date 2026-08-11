function _bmopf_covariance_fixture()
    return BMOPFTools.parse_bmopf(raw"""
    {"bus":{
        "source":{"terminal_names":["1","n"],
                  "perfectly_grounded_terminals":["n"]},
        "loadbus":{"terminal_names":["1","n"],
                   "perfectly_grounded_terminals":["n"]}},
     "voltage_source":{"source":{"bus":"source","terminal_map":["1"],
         "v_magnitude":[1000.0],"v_angle":[0.0]}},
     "linecode":{"lc":{"R_series_1_1":0.5,"R_series_2_2":0.5}},
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
end
