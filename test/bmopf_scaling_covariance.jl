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

function _bmopf_volt_watt_covariance_fixture()
    return BMOPFTools.parse_bmopf(raw"""
    {"bus":{"source":{"terminal_names":["a","n"],
                        "perfectly_grounded_terminals":["n"]}},
     "voltage_source":{"source":{"bus":"source","terminal_map":["a"],
         "v_magnitude":[230.0],"v_angle":[0.0],"cost":[1.0]}},
     "control_profile":{"vw":{"volt_watt":{
         "breakpoints":[0.9,1.1],"p_limits":[1.0,0.0],
         "p_unit":"VA_FRACTION","p_ref":"S_MAX"}}},
     "ibr":{"pv":{"bus":"source","terminal_map":["a","n"],
         "topology":"SINGLE_PHASE","prime_mover":"PV",
         "s_max":[10000.0],"p_min":0.0,"p_max":8000.0,
         "p_avail":8000.0,"q_min":[-3000.0],"q_max":[3000.0],
         "control_profile":"vw"}}}
    """; from_string=true)
end

function _bmopf_transformer_chain_initialization_fixture()
    return BMOPFTools.parse_bmopf(raw"""
    {"bus":{
        "hv":{"terminal_names":["a","b","c","n"],
              "perfectly_grounded_terminals":["n"]},
        "delta":{"terminal_names":["a","b","c"]},
        "lv":{"terminal_names":["a","b","c","n"],
              "perfectly_grounded_terminals":["n"]}},
     "voltage_source":{"source":{"bus":"hv",
         "terminal_map":["a","b","c"],
         "v_magnitude":[6350.0,6350.0,6350.0],
         "v_angle":[0.29670597283903605,-1.7976891295541593,2.3911010752322315]}},
     "transformer":{
       "wye_delta":{"yd":{"bus_from":"hv","bus_to":"delta",
         "terminal_map_from":["a","b","c","n"],
         "terminal_map_to":["a","b","c"],
         "v_nom_from":11000.0,"v_nom_to":415.0,"s_rating":500000.0,
         "r_series_from":0.01,"x_series_from":0.02,
         "r_series_to":0.00001,"x_series_to":0.00002}},
       "delta_wye":{"dy":{"bus_from":"delta","bus_to":"lv",
         "terminal_map_from":["a","b","c"],
         "terminal_map_to":["a","b","c","n"],
         "v_nom_from":415.0,"v_nom_to":230.0,"s_rating":100000.0,
         "r_series_from":0.00001,"x_series_from":0.00002,
         "r_series_to":0.00001,"x_series_to":0.00002}}}}
    """; from_string=true)
end

function _bmopf_zone_local_transformer_fixture()
    return BMOPFTools.parse_bmopf(raw"""
    {"bus":{
        "hv":{"terminal_names":["a","n"],
              "perfectly_grounded_terminals":["n"]},
        "lv":{"terminal_names":["x","n"],
              "perfectly_grounded_terminals":["n"]}},
     "voltage_source":{"source":{"bus":"hv","terminal_map":["a"],
         "v_magnitude":[2400.0],"v_angle":[0.17]}},
     "transformer":{"single_phase":{"tx":{"bus_from":"hv","bus_to":"lv",
         "terminal_map_from":["a","n"],"terminal_map_to":["x","n"],
         "v_nom_from":2400.0,"v_nom_to":240.0,"s_rating":50000.0,
         "r_series_from":1.0,"x_series_from":2.0,
         "r_series_to":0.01,"x_series_to":0.02}}},
     "load":{"load":{"bus":"lv","terminal_map":["x","n"],
         "configuration":"WYE","p_nom":[10000.0],"q_nom":[3000.0]}}}
    """; from_string=true)
end

function _bmopf_zone_local_center_tap_fixture(; explicit_t_model=false)
    network = BMOPFTools.parse_bmopf(raw"""
    {"bus":{"mv":{"terminal_names":["1","n"],
                   "perfectly_grounded_terminals":["n"]},
            "lv":{"terminal_names":["1","n","2"],
                   "perfectly_grounded_terminals":["n"]}},
     "voltage_source":{"src":{"bus":"mv","terminal_map":["1"],
         "v_magnitude":[2400.0],"v_angle":[0.11]}},
     "transformer":{"center_tap":{"ct":{"bus_from":"mv","bus_to":"lv",
         "terminal_map_from":["1","n"],"terminal_map_to":["1","n","2"],
         "v_nom_from":2400.0,"v_nom_to":120.0,"s_rating":25000.0,
         "i_max_from":[100.0,100.0],"i_max_to":[1000.0,1000.0,1000.0],
         "r_series_from":0.1,"x_series_from":0.4,
         "r_series_to":0.001,"x_series_to":0.004,
         "g_no_load":2e-5,"b_no_load":8e-5}}},
     "load":{"l1":{"bus":"lv","terminal_map":["1","n"],
                     "configuration":"SINGLE_PHASE",
                     "p_nom":[3000.0],"q_nom":[500.0]},
             "l2":{"bus":"lv","terminal_map":["2","n"],
                     "configuration":"SINGLE_PHASE",
                     "p_nom":[1000.0],"q_nom":[100.0]}}}
    """; from_string=true)
    if explicit_t_model
        transformer = network["transformer"]["center_tap"]["ct"]
        transformer["r_series_from"] = 0.0
        transformer["x_series_from"] = 0.0
    end
    return network
end

function _bmopf_zone_local_n_winding_fixture()
    return BMOPFTools.parse_bmopf(raw"""
    {"bus":{
        "hv":{"terminal_names":["a","b","c","n"],
              "perfectly_grounded_terminals":["n"]},
        "mv":{"terminal_names":["a","b","c","n"],
              "perfectly_grounded_terminals":["n"]},
        "lv":{"terminal_names":["a","b","c","n"],
              "perfectly_grounded_terminals":["n"]}},
     "voltage_source":{"src":{"bus":"hv",
         "terminal_map":["a","b","c"],
         "v_magnitude":[2400.0,2400.0,2400.0],
         "v_angle":[0.17,-1.9243951023931953,2.2643951023931953]}},
     "transformer":{"n_winding":{"nw":{"s_rating":500000.0,
         "g_no_load":1e-5,"b_no_load":4e-5,
         "windings":[
           {"bus":"hv","terminal_map":["a","b","c","n"],
            "v_nom":2400.0,"configuration":"WYE","r_winding":0.08,
            "i_max":500.0,"s_max":500000.0},
           {"bus":"mv","terminal_map":["a","b","c","n"],
            "v_nom":480.0,"configuration":"WYE","r_winding":0.003,
            "i_max":800.0,"s_max":200000.0},
           {"bus":"lv","terminal_map":["a","b","c","n"],
            "v_nom":120.0,"configuration":"WYE","r_winding":0.0002,
            "i_max":1000.0,"s_max":50000.0}],
         "x_sc":{"1_2":0.40,"1_3":0.55,"2_3":0.30}}}},
     "load":{
       "mvload":{"bus":"mv","terminal_map":["a","b","c","n"],
         "configuration":"WYE","p_nom":[10000.0,9000.0,11000.0],
         "q_nom":[2000.0,1800.0,2200.0]},
       "lvload":{"bus":"lv","terminal_map":["a","b","c","n"],
         "configuration":"WYE","p_nom":[2000.0,1500.0,2500.0],
         "q_nom":[400.0,300.0,500.0]}}}
    """; from_string=true)
end

function _bmopf_zone_local_single_regulator_fixture(; free_tap=false)
    network = BMOPFTools.parse_bmopf(raw"""
    {"bus":{
        "src":{"terminal_names":["1","n"],
               "perfectly_grounded_terminals":["n"]},
        "reg":{"terminal_names":["1","n"],
               "perfectly_grounded_terminals":[]}},
     "voltage_source":{"src":{"bus":"src","terminal_map":["1","n"],
         "v_magnitude":[2400.0],"v_angle":[0.13]}},
     "transformer":{"single_phase_autotransformer":{"regulator":{
         "bus_from":"src","bus_to":"reg",
         "terminal_map_from":["1","n"],"terminal_map_to":["1","n"],
         "tap_ratio":1.025,"regulator_type":"B","s_rating":250000.0,
         "r_series_from":0.45,"x_series_from":0.20,
         "r_series_to":0.08,"x_series_to":0.04,
         "g_no_load":1.0e-6,"b_no_load":3.0e-6,
         "i_max_from":[150.0],"i_max_to":[150.0]}}},
     "load":{"load":{"bus":"reg","terminal_map":["1","n"],
         "configuration":"SINGLE_PHASE","p_nom":[50000.0],
         "q_nom":[12000.0]}}}
    """; from_string=true)
    if free_tap
        regulator = network["transformer"][
            "single_phase_autotransformer"]["regulator"]
        regulator["tap_ratio_min"] = 0.98
        regulator["tap_ratio_max"] = 1.06
    end
    return network
end

function _bmopf_zone_local_open_delta_regulator_fixture(; free_tap=false)
    network = BMOPFTools.parse_bmopf(raw"""
    {"bus":{
        "src":{"terminal_names":["1","2","3","n"],
               "perfectly_grounded_terminals":["n"]},
        "reg":{"terminal_names":["1","2","3","n"],
               "perfectly_grounded_terminals":["n"]}},
     "voltage_source":{"src":{"bus":"src",
         "terminal_map":["1","2","3"],
         "v_magnitude":[2400.0,2400.0,2400.0],
         "v_angle":[0.13,-1.9643951023931953,2.2243951023931953]}},
     "transformer":{"open_delta_regulator":{"bank":{
         "bus_from":"src","bus_to":"reg",
         "terminal_map_from":["1","2","3","n"],
         "terminal_map_to":["1","2","3","n"],
         "connection":"ABBC","tap_ratio":[1.025,0.99],
         "regulator_type":"B","s_rating":250000.0,
         "r_series_from":0.35,"x_series_from":0.15,
         "r_series_to":0.05,"x_series_to":0.02,
         "g_no_load":8.0e-7,"b_no_load":2.0e-6,
         "i_max_from":[150.0,150.0,150.0],
         "i_max_to":[150.0,150.0]}}},
     "load":{"load":{"bus":"reg",
         "terminal_map":["1","2","3","n"],
         "configuration":"WYE",
         "p_nom":[30000.0,20000.0,25000.0],
         "q_nom":[6000.0,4000.0,5000.0]}}}
    """; from_string=true)
    if free_tap
        regulator = network["transformer"]["open_delta_regulator"]["bank"]
        regulator["tap_ratio_min"] = [0.98, 0.97]
        regulator["tap_ratio_max"] = [1.06, 1.04]
    end
    return network
end

function _bmopf_zone_local_acdc_fixture(; droop=false)
    network = BMOPFTools.parse_bmopf(raw"""
    {"bus":{
        "f1":{"terminal_names":["a","n"],
              "perfectly_grounded_terminals":["n"]},
        "f2":{"terminal_names":["a","n"],
              "perfectly_grounded_terminals":["n"]}},
     "voltage_source":{
        "s1":{"bus":"f1","terminal_map":["a"],
              "v_magnitude":[230.0],"v_angle":[0.0]},
        "s2":{"bus":"f2","terminal_map":["a"],
              "v_magnitude":[230.0],"v_angle":[0.0]}},
     "load":{"load":{"bus":"f2","terminal_map":["a","n"],
        "configuration":"SINGLE_PHASE","p_nom":[5000.0],"q_nom":[0.0]}},
     "ibr":{
        "vsc1":{"bus":"f1","terminal_map":["a","n"],
            "topology":"SINGLE_PHASE","prime_mover":"GENERIC",
            "s_max":[8000.0],"dc_bus":"dcA",
            "dc_terminal_map":["p","m"],"dc_control":"V",
            "dc_v_set":850.0},
        "vsc2":{"bus":"f2","terminal_map":["a","n"],
            "topology":"SINGLE_PHASE","prime_mover":"GENERIC",
            "s_max":[8000.0],"dc_bus":"dcB",
            "dc_terminal_map":["p","m"]}},
     "dc_bus":{
        "dcA":{"terminal_names":["p","m"],"v_dc_nom":[850.0,0.0],
            "v_dc_min":[700.0,0.0],"v_dc_max":[900.0,0.0]},
        "dcB":{"terminal_names":["p","m"],"v_dc_nom":[850.0,0.0],
            "v_dc_min":[700.0,0.0],"v_dc_max":[900.0,0.0]}},
     "dc_branch":{"tie":{"dc_bus_from":"dcA","dc_bus_to":"dcB",
        "terminal_map_from":["p","m"],"terminal_map_to":["p","m"],
        "r":[0.5,0.0],"i_max":[20.0,20.0],"p_max":12000.0}},
     "dc_grounding":{"ground":{"dc_bus":"dcA","terminal":"m","r":0.0}}}
    """; from_string=true)
    if droop
        converter = network["ibr"]["vsc2"]
        converter["dc_control"] = "droop"
        converter["dc_v_set"] = 840.0
        converter["dc_p_ref"] = 3000.0
        converter["dc_deadband"] = 2.0
        converter["dc_droop"] = 0.01
    end
    return network
end

function _bmopf_covariance_evaluation(context, label)
    BMOPFTools.opf_lifecycle(context) == :kcl_finalized ||
        BMOPFTools.enforce_kcl!(context)
    point = NLPDiagnostics.bmopf_start_completion_point(
        context; missing_value=0.0, label)
    return NLPDiagnostics.evaluate_numerical(
        JuMP.backend(BMOPFTools.opf_model(context)), point)
end

@testset "BMOPF applied zone-local transformer scaling contract" begin
    network = _bmopf_zone_local_transformer_fixture()
    zone = BMOPFTools.ZonePerUnitScaling(
        name=:diagnostic_zone_local,
        voltage_bases=Dict("hv" => 2400.0, "lv" => 240.0),
        power_bases=Dict("hv" => 1.0e6, "lv" => 25.0e3),
    )
    si_context = BMOPFTools.build_opf_model(
        network; scaling_policy=BMOPFTools.SIUnitsScaling(),
        add_objective=false,
    )
    local_context = BMOPFTools.build_opf_model(
        network; scaling_policy=zone, add_objective=false,
    )
    contract = NLPDiagnostics.bmopf_transformer_scaling_contract_data(
        local_context,
    )
    @test contract["comparison_ready"]
    @test contract["model_experiment_ready"]
    @test contract["applied_to_model"]
    @test !contract["requires_new_transformer_stamping"]
    @test contract["interfaces_requiring_current_conversion"] == 1
    @test contract["interfaces_requiring_power_conversion"] == 1
    @test contract["interface_count_by_subtype"] == Dict("single_phase" => 1)
    @test contract["conversion_ranges"]["power"][
        "maximum_symmetric_factor"
    ] ≈ 40.0

    initialization = NLPDiagnostics.bmopf_initialization_scaling_covariance_report(
        si_context,
        local_context;
        require_phasor_transport=true,
        absolute_tolerance=1.0e-6,
        relative_tolerance=1.0e-8,
    )
    @test initialization["equivalence_gate_passed"]
    @test initialization["initialization_covariance_passed"]
    @test initialization["phasor_transport_passed"]
end

@testset "BMOPF applied zone-local AC/DC covariance" begin
    policy = BMOPFTools.ZonePerUnitScaling(
        name=:diagnostic_acdc_local_power,
        voltage_bases=Dict("f1" => 230.0, "f2" => 230.0),
        power_bases=Dict("f1" => 1.0e6, "f2" => 100.0e3),
        dc_voltage_base=850.0,
        dc_power_base=20.0e3,
    )
    for (label, droop, expected_modes) in (
        ("p-control", false, Dict("P" => 1, "V" => 1)),
        ("droop-control", true, Dict("V" => 1, "droop" => 1)),
    )
        @testset "$label" begin
            network = _bmopf_zone_local_acdc_fixture(; droop)
            si_context = BMOPFTools.build_opf_model(
                network;
                scaling_policy=BMOPFTools.SIUnitsScaling(),
                add_objective=false,
            )
            local_context = BMOPFTools.build_opf_model(
                network; scaling_policy=policy, add_objective=false,
            )

            contract = NLPDiagnostics.bmopf_acdc_scaling_contract_data(
                local_context,
            )
            @test contract["available"]
            @test contract["comparison_ready"]
            @test contract["applied_to_model"]
            @test contract["converter_count"] == 2
            @test contract["converter_count_by_control_mode"] == expected_modes
            @test contract["distinct_power_coordinates_present"]
            @test contract["coefficient_contract_passed"]
            @test contract["control_modes_qualified"]
            @test contract["power_coordinate_conversion_range"][
                "maximum_symmetric_factor"
            ] == 50.0

            si_evaluation = _bmopf_covariance_evaluation(
                si_context, "acdc-$label-si",
            )
            local_evaluation = _bmopf_covariance_evaluation(
                local_context, "acdc-$label-zone-local",
            )
            for (context, evaluation) in (
                (si_context, si_evaluation),
                (local_context, local_evaluation),
            )
                map = NLPDiagnostics.bmopf_diagonal_scaling_map(
                    context, evaluation,
                )
                @test map["available"]
                @test isempty(map["unsupported_variables"])
                @test isempty(map["unsupported_constraint_rows"])
            end

            report =
                NLPDiagnostics.bmopf_initialization_scaling_covariance_report(
                    si_context,
                    local_context;
                    require_phasor_transport=true,
                    absolute_tolerance=1.0e-8,
                    relative_tolerance=1.0e-8,
                )
            @test report["equivalence_gate_passed"]
            @test report["initialization_covariance_passed"]
            @test report["phasor_transport_passed"]
            covariance = report["covariance_report"]
            @test covariance["metrics"]["physical_point"]["passed"]
            @test covariance["metrics"]["constraint_function_values"]["passed"]
            @test covariance["metrics"]["constraint_sets"]["passed"]
            @test covariance["metrics"]["constraint_residuals"]["passed"]
            @test covariance["metrics"]["physical_jacobian"]["passed"]
        end
    end
end

@testset "BMOPF Volt-Watt residual scaling covariance" begin
    network = _bmopf_volt_watt_covariance_fixture()
    reference_context = BMOPFTools.build_opf_model(
        deepcopy(network);
        scaling_policy=BMOPFTools.ClassicPerUnitScaling(1.0e6),
        add_objective=true,
    )
    BMOPFTools.enforce_kcl!(reference_context)
    candidate_context = BMOPFTools.build_opf_model(
        deepcopy(network);
        scaling_policy=BMOPFTools.ZonePerUnitScaling(
            name=:volt_watt_10kva,
            voltage_bases=Dict("source" => 230.0),
            power_bases=Dict("source" => 10000.0),
        ),
        add_objective=true,
    )
    BMOPFTools.enforce_kcl!(candidate_context)
    reference_evaluation = _bmopf_covariance_evaluation(
        reference_context, "volt-watt-reference",
    )
    candidate_schema = _bmopf_covariance_evaluation(
        candidate_context, "volt-watt-candidate-schema",
    )
    reference_map = NLPDiagnostics.bmopf_diagonal_scaling_map(
        reference_context, reference_evaluation,
    )
    candidate_map = NLPDiagnostics.bmopf_diagonal_scaling_map(
        candidate_context, candidate_schema,
    )
    @test reference_map["available"]
    @test candidate_map["available"]
    @test isempty(reference_map["unsupported_constraint_rows"])
    @test isempty(candidate_map["unsupported_constraint_rows"])
    transported = NLPDiagnostics.bmopf_transport_scaling_point(
        reference_context,
        reference_evaluation,
        candidate_context,
        candidate_schema,
    )
    @test transported["available"]
    candidate_evaluation = NLPDiagnostics.evaluate_numerical(
        JuMP.backend(BMOPFTools.opf_model(candidate_context)),
        transported["transport"].point,
    )
    covariance = NLPDiagnostics.bmopf_block_scaling_covariance_report(
        reference_context,
        reference_evaluation,
        candidate_context,
        candidate_evaluation;
        absolute_tolerance=1.0e-6,
        relative_tolerance=1.0e-8,
    )
    @test covariance["equivalence_gate_passed"]
    @test covariance["metrics"]["constraint_residuals"]["passed"]
    @test covariance["metrics"]["physical_jacobian"]["passed"]
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

    initialization_covariance =
        NLPDiagnostics.bmopf_initialization_scaling_covariance_report(
            reference_context,
            candidate_context;
            absolute_tolerance=1e-9,
            relative_tolerance=5e-9,
            require_phasor_transport=true,
        )
    @test initialization_covariance["available"]
    @test initialization_covariance["initialization_covariance_passed"]
    @test initialization_covariance["equivalence_gate_passed"]
    @test initialization_covariance["reference_voltage_pattern"][
        "checked_invariants_passed"
    ]
    @test initialization_covariance["candidate_voltage_pattern"][
        "checked_invariants_passed"
    ]
    @test !initialization_covariance["canonical_voltage_pattern_required"]
    @test initialization_covariance["phasor_transport_required"]
    @test initialization_covariance["phasor_transport_passed"]
    @test initialization_covariance["reference_voltage_pattern"][
        "phasor_transport"
    ]["residual_passed"]
    @test initialization_covariance["candidate_voltage_pattern"][
        "phasor_transport"
    ]["transport_gate_passed"]

    reference_map = NLPDiagnostics.bmopf_diagonal_scaling_map(
        reference_context, reference_evaluation)
    candidate_map = NLPDiagnostics.bmopf_diagonal_scaling_map(
        candidate_context, candidate_evaluation)
    @test reference_map["available"]
    @test candidate_map["available"]
    @test isempty(reference_map["unsupported_variables"])
    @test isempty(reference_map["unsupported_constraint_rows"])
    reference_columns = NLPDiagnostics.bmopf_variable_semantic_column_map(
        reference_context, reference_evaluation,
    )
    @test length(reference_columns) ==
          length(reference_evaluation.point.variables)
    @test all(column["registered"] for column in values(reference_columns))

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
    intervention = NLPDiagnostics.bmopf_scaling_intervention_classification(
        reference_context,
        reference_evaluation,
        candidate_context,
        candidate_evaluation,
    )
    @test intervention["available"]
    @test intervention["classification"] == "magnitude_only"
    @test intervention["variables"]["classification"] in
          ("identity", "magnitude_only")
    @test intervention["constraints"]["classification"] in
          ("identity", "magnitude_only")

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
    @test geometry["semantic_interpretation_qualified"]
    @test geometry["semantic_family_geometry"]["registry_coverage_complete"]
    @test geometry["semantic_family_geometry"]["family_sets_agree"]
    @test !isempty(geometry["semantic_family_geometry"]["comparisons"][
        "columns"
    ]["families"])
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
    @test block_geometry["semantic_interpretation_qualified"]
    @test block_geometry["semantic_family_geometry"][
        "registry_coverage_complete"
    ]

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

@testset "BMOPF transformer-chain initialization covariance" begin
    network = _bmopf_transformer_chain_initialization_fixture()
    si_context = BMOPFTools.build_opf_model(
        network;
        scaling_policy=BMOPFTools.SIUnitsScaling(),
        add_objective=false,
    )
    pu_context = BMOPFTools.build_opf_model(
        network;
        scaling_policy=BMOPFTools.ClassicPerUnitScaling(1.0e6),
        add_objective=false,
    )
    report = NLPDiagnostics.bmopf_initialization_scaling_covariance_report(
        si_context,
        pu_context;
        require_phasor_transport=true,
        absolute_tolerance=1.0e-8,
        relative_tolerance=1.0e-8,
    )
    @test report["equivalence_gate_passed"]
    @test report["initialization_covariance_passed"]
    @test report["phasor_transport_passed"]
    for side in ("reference_voltage_pattern", "candidate_voltage_pattern")
        transport = report[side]["phasor_transport"]
        @test transport["equation_count_by_kind"]["wye_delta"] == 3
        @test transport["equation_count_by_kind"]["delta_wye"] == 3
        @test transport["maximum_normalized_physics_residual"] < 1.0e-10
        @test isempty(transport["unsupported_transformer_subtypes"])
    end

    contract = NLPDiagnostics.bmopf_transformer_scaling_contract_data(
        si_context;
        voltage_bases=Dict(
            "hv" => 6350.0,
            "delta" => 415.0 / sqrt(3.0),
            "lv" => 230.0 / sqrt(3.0),
        ),
        power_bases=Dict(
            "hv" => 10.0e6,
            "delta" => 1.0e6,
            "lv" => 100.0e3,
        ),
    )
    @test contract["comparison_ready"]
    @test !contract["model_experiment_ready"]
    @test contract["requires_new_transformer_stamping"]
    @test contract["interfaces_requiring_current_conversion"] == 2
    @test contract["interfaces_requiring_power_conversion"] == 2
    @test contract["interface_count_by_subtype"]["wye_delta"] == 1
    @test contract["interface_count_by_subtype"]["delta_wye"] == 1
    @test contract["conversion_ranges"]["power"][
        "maximum_symmetric_factor"
    ] ≈ 10.0
end

@testset "BMOPF applied zone-local Yd/Dy chain covariance" begin
    network = _bmopf_transformer_chain_initialization_fixture()
    si_context = BMOPFTools.build_opf_model(
        network;
        scaling_policy=BMOPFTools.SIUnitsScaling(),
        add_objective=false,
    )
    classic_context = BMOPFTools.build_opf_model(
        network;
        scaling_policy=BMOPFTools.ClassicPerUnitScaling(1.0e6),
        add_objective=false,
    )
    voltage_bases = Dict(BMOPFTools.opf_bases(classic_context).v_base)
    zone_policy = BMOPFTools.ZonePerUnitScaling(
        name=:diagnostic_yd_dy_chain,
        voltage_bases=voltage_bases,
        power_bases=Dict(
            "hv" => 10.0e6,
            "delta" => 1.0e6,
            "lv" => 100.0e3,
        ),
    )
    local_context = BMOPFTools.build_opf_model(
        network; scaling_policy=zone_policy, add_objective=false,
    )

    contract = NLPDiagnostics.bmopf_transformer_scaling_contract_data(
        local_context,
    )
    @test contract["comparison_ready"]
    @test contract["model_experiment_ready"]
    @test contract["applied_to_model"]
    @test !contract["requires_new_transformer_stamping"]
    @test contract["interfaces_requiring_current_conversion"] == 2
    @test contract["interfaces_requiring_power_conversion"] == 2
    @test contract["interface_count_by_subtype"]["wye_delta"] == 1
    @test contract["interface_count_by_subtype"]["delta_wye"] == 1
    @test contract["conversion_ranges"]["power"][
        "maximum_symmetric_factor"
    ] ≈ 10.0

    report = NLPDiagnostics.bmopf_initialization_scaling_covariance_report(
        si_context,
        local_context;
        require_phasor_transport=true,
        absolute_tolerance=1.0e-8,
        relative_tolerance=1.0e-8,
    )
    @test report["equivalence_gate_passed"]
    @test report["initialization_covariance_passed"]
    @test report["phasor_transport_passed"]
    covariance = report["covariance_report"]
    @test covariance["metrics"]["physical_point"]["passed"]
    @test covariance["metrics"]["constraint_residuals"]["passed"]
    @test covariance["metrics"]["constraint_sets"]["passed"]
    @test covariance["metrics"]["physical_jacobian"]["passed"]
end

@testset "BMOPF applied zone-local center-tap covariance" begin
    zone_policy = BMOPFTools.ZonePerUnitScaling(
        name=:diagnostic_center_tap,
        voltage_bases=Dict("mv" => 2400.0, "lv" => 120.0),
        power_bases=Dict("mv" => 1.0e6, "lv" => 25.0e3),
    )
    for (label, explicit_t_model) in
            (("fixed-primitive", false), ("explicit-t-model", true))
        @testset "$label" begin
            network = _bmopf_zone_local_center_tap_fixture(; explicit_t_model)
            si_context = BMOPFTools.build_opf_model(
                network;
                scaling_policy=BMOPFTools.SIUnitsScaling(),
                add_objective=false,
            )
            local_context = BMOPFTools.build_opf_model(
                network; scaling_policy=zone_policy, add_objective=false,
            )
            contract = NLPDiagnostics.bmopf_transformer_scaling_contract_data(
                local_context,
            )
            @test contract["comparison_ready"]
            @test contract["model_experiment_ready"]
            @test contract["applied_to_model"]
            @test contract["interfaces_requiring_current_conversion"] == 1
            @test contract["interfaces_requiring_power_conversion"] == 1
            @test contract["interface_count_by_subtype"] ==
                  Dict("center_tap" => 1)
            @test contract["conversion_ranges"]["power"][
                "maximum_symmetric_factor"
            ] ≈ 40.0

            si_evaluation = _bmopf_covariance_evaluation(
                si_context, "center-tap-$label-si",
            )
            local_evaluation = _bmopf_covariance_evaluation(
                local_context, "center-tap-$label-zone-local",
            )
            for scaling_map in (
                    NLPDiagnostics.bmopf_diagonal_scaling_map(
                        si_context, si_evaluation,
                    ),
                    NLPDiagnostics.bmopf_diagonal_scaling_map(
                        local_context, local_evaluation,
                    ),
                )
                @test scaling_map["available"]
                @test isempty(scaling_map["unsupported_constraint_rows"])
                current_box_rows = count(
                    key -> occursin("xf_", key) && occursin("_bound:", key),
                    scaling_map["map"].constraint_keys,
                )
                @test current_box_rows == (explicit_t_model ? 16 : 0)
            end

            report =
                NLPDiagnostics.bmopf_initialization_scaling_covariance_report(
                    si_context,
                    local_context;
                    require_phasor_transport=true,
                    absolute_tolerance=1.0e-8,
                    relative_tolerance=1.0e-8,
                )
            @test report["equivalence_gate_passed"]
            @test report["initialization_covariance_passed"]
            @test report["phasor_transport_passed"]
            covariance = report["covariance_report"]
            @test covariance["metrics"]["physical_point"]["passed"]
            @test covariance["metrics"]["constraint_function_values"]["passed"]
            @test covariance["metrics"]["constraint_residuals"]["passed"]
            @test covariance["metrics"]["constraint_sets"]["passed"]
            @test covariance["metrics"]["physical_jacobian"]["passed"]
        end
    end
end

@testset "BMOPF applied zone-local n-winding covariance" begin
    network = _bmopf_zone_local_n_winding_fixture()
    zone_policy = BMOPFTools.ZonePerUnitScaling(
        name=:diagnostic_n_winding,
        voltage_bases=Dict("hv" => 2400.0, "mv" => 480.0, "lv" => 120.0),
        power_bases=Dict("hv" => 1.0e6, "mv" => 100.0e3, "lv" => 20.0e3),
    )
    si_context = BMOPFTools.build_opf_model(
        network;
        scaling_policy=BMOPFTools.SIUnitsScaling(),
        add_objective=false,
    )
    local_context = BMOPFTools.build_opf_model(
        network; scaling_policy=zone_policy, add_objective=false,
    )
    contract = NLPDiagnostics.bmopf_transformer_scaling_contract_data(
        local_context,
    )
    @test contract["comparison_ready"]
    @test contract["model_experiment_ready"]
    @test contract["applied_to_model"]
    @test contract["interfaces_requiring_current_conversion"] == 2
    @test contract["interfaces_requiring_power_conversion"] == 2
    @test contract["interface_count_by_subtype"] == Dict("n_winding" => 2)
    @test contract["conversion_ranges"]["power"][
        "maximum_symmetric_factor"
    ] ≈ 50.0

    si_evaluation = _bmopf_covariance_evaluation(
        si_context, "n-winding-si",
    )
    local_evaluation = _bmopf_covariance_evaluation(
        local_context, "n-winding-zone-local",
    )
    for scaling_map in (
            NLPDiagnostics.bmopf_diagonal_scaling_map(
                si_context, si_evaluation,
            ),
            NLPDiagnostics.bmopf_diagonal_scaling_map(
                local_context, local_evaluation,
            ),
        )
        @test scaling_map["available"]
        @test isempty(scaling_map["unsupported_constraint_rows"])
        current_box_rows = count(
            key -> occursin("_nw_", key) && occursin("_bound:", key),
            scaling_map["map"].constraint_keys,
        )
        @test current_box_rows == 36
    end

    report = NLPDiagnostics.bmopf_initialization_scaling_covariance_report(
        si_context,
        local_context;
        require_phasor_transport=true,
        absolute_tolerance=1.0e-8,
        relative_tolerance=1.0e-8,
    )
    @test report["equivalence_gate_passed"]
    @test report["initialization_covariance_passed"]
    @test report["phasor_transport_passed"]
    covariance = report["covariance_report"]
    @test covariance["metrics"]["physical_point"]["passed"]
    @test covariance["metrics"]["constraint_function_values"]["passed"]
    @test covariance["metrics"]["constraint_residuals"]["passed"]
    @test covariance["metrics"]["constraint_sets"]["passed"]
    @test covariance["metrics"]["physical_jacobian"]["passed"]
end

@testset "BMOPF applied zone-local galvanic regulator covariance" begin
    zone_policy = BMOPFTools.ZonePerUnitScaling(
        name=:diagnostic_galvanic_regulator,
        voltage_bases=Dict("src" => 2400.0, "reg" => 2400.0),
        power_bases=Dict("src" => 500.0e3, "reg" => 500.0e3),
    )
    fixtures = (
        ("single-fixed", _bmopf_zone_local_single_regulator_fixture,
         false, "single_phase_autotransformer", 1),
        ("single-free", _bmopf_zone_local_single_regulator_fixture,
         true, "single_phase_autotransformer", 1),
        ("open-delta-fixed", _bmopf_zone_local_open_delta_regulator_fixture,
         false, "open_delta_regulator", 1),
        ("open-delta-free", _bmopf_zone_local_open_delta_regulator_fixture,
         true, "open_delta_regulator", 2),
    )
    for (label, fixture, free_tap, subtype, expected_taps) in fixtures
        @testset "$label" begin
            network = fixture(; free_tap)
            si_context = BMOPFTools.build_opf_model(
                network;
                scaling_policy=BMOPFTools.SIUnitsScaling(),
                add_objective=false,
            )
            local_context = BMOPFTools.build_opf_model(
                network; scaling_policy=zone_policy, add_objective=false,
            )
            contract = NLPDiagnostics.bmopf_transformer_scaling_contract_data(
                local_context,
            )
            @test contract["comparison_ready"]
            @test contract["model_experiment_ready"]
            @test contract["galvanic_voltage_compatibility_passed"]
            @test contract["galvanically_continuous_interface_count"] == 1
            @test contract[
                "interfaces_requiring_shared_conductor_voltage_conversion"] == 0
            @test contract["interfaces_requiring_current_conversion"] == 0
            @test contract["interfaces_requiring_power_conversion"] == 0
            @test contract["interface_count_by_subtype"] == Dict(subtype => 1)

            si_evaluation = _bmopf_covariance_evaluation(
                si_context, "regulator-$label-si",
            )
            local_evaluation = _bmopf_covariance_evaluation(
                local_context, "regulator-$label-zone-local",
            )
            for (context, evaluation) in (
                    (si_context, si_evaluation),
                    (local_context, local_evaluation),
                )
                scaling_map = NLPDiagnostics.bmopf_diagonal_scaling_map(
                    context, evaluation,
                )
                @test scaling_map["available"]
                @test isempty(scaling_map["unsupported_variables"])
                @test isempty(scaling_map["unsupported_constraint_rows"])
            end

            report =
                NLPDiagnostics.bmopf_initialization_scaling_covariance_report(
                    si_context,
                    local_context;
                    require_phasor_transport=true,
                    absolute_tolerance=1.0e-8,
                    relative_tolerance=1.0e-8,
                )
            @test report["equivalence_gate_passed"]
            @test report["initialization_covariance_passed"]
            @test report["phasor_transport_passed"]
            covariance = report["covariance_report"]
            @test covariance["metrics"]["physical_point"]["passed"]
            @test covariance["metrics"]["constraint_function_values"]["passed"]
            @test covariance["metrics"]["constraint_residuals"]["passed"]
            @test covariance["metrics"]["constraint_sets"]["passed"]
            @test covariance["metrics"]["physical_jacobian"]["passed"]

            semantic_columns =
                NLPDiagnostics.bmopf_variable_semantic_column_map(
                    local_context, local_evaluation,
                )
            tap_columns = count(column ->
                "tap" in column["variable_families"],
                values(semantic_columns),
            )
            @test tap_columns == (free_tap ? expected_taps : 0)
        end
    end

    si_context = BMOPFTools.build_opf_model(
        _bmopf_zone_local_single_regulator_fixture();
        scaling_policy=BMOPFTools.SIUnitsScaling(), add_objective=false,
    )
    inadmissible = NLPDiagnostics.bmopf_transformer_scaling_contract_data(
        si_context;
        voltage_bases=Dict("src" => 2400.0, "reg" => 1200.0),
        power_bases=Dict("src" => 500.0e3, "reg" => 500.0e3),
    )
    @test !inadmissible["comparison_ready"]
    @test !inadmissible["model_experiment_ready"]
    @test !inadmissible["galvanic_voltage_compatibility_passed"]
    @test inadmissible["galvanically_continuous_interface_count"] == 1
    @test inadmissible[
        "interfaces_requiring_shared_conductor_voltage_conversion"] == 1
    @test inadmissible["requires_new_transformer_stamping"]
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
    trace_geometry =
        NLPDiagnostics.bmopf_iteration_trace_jacobian_family_geometry_data(
            reference_context,
            reference_run.trace;
            max_points=3,
        )
    @test trace_geometry["available"]
    @test trace_geometry["coverage_complete"]
    @test trace_geometry["interpretation_qualified"]
    @test trace_geometry["registry_coverage"]["complete"]
    @test trace_geometry["selected_binding_count"] <= 3
    @test !isempty(trace_geometry["trajectories"]["rows"])
    @test !isempty(trace_geometry["trajectories"]["columns"])
    repeat_covariance = NLPDiagnostics.bmopf_block_scaling_covariance_report(
        reference_context,
        reference_evaluation,
        reference_context,
        reference_evaluation;
        absolute_tolerance=1.0e-8,
        relative_tolerance=1.0e-8,
    )
    repeat_geometry =
        NLPDiagnostics.bmopf_block_scaling_coordinate_geometry_report(
            reference_context,
            reference_evaluation,
            reference_context,
            reference_evaluation;
            absolute_tolerance=1.0e-8,
            relative_tolerance=1.0e-8,
        )
    repeat_comparison =
        NLPDiagnostics.bmopf_scaling_solver_experiment_comparison(
            trace_endpoint,
            trace_endpoint;
            intervention=:baseline_repeat,
            intervention_report=
                NLPDiagnostics.scaling_intervention_classification(
                    reference_map["map"], reference_map["map"],
                ),
            covariance_report=repeat_covariance,
            geometry_report=repeat_geometry,
            hypothesis="identical retained evidence should pass every gate",
        )
    @test repeat_comparison["available"]
    @test repeat_comparison["comparison_qualified"]
    @test repeat_comparison["reference_scaling_policy"] ==
          trace_endpoint["bmopf_scaling_policy"]
    @test repeat_comparison["native_work"]["comparisons"]["record_count"][
        "candidate_to_reference_ratio"
    ] == 1.0
    @test repeat_comparison["physical_endpoint_families"][
        "family_sets_agree"
    ]

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
        @test geometry["semantic_interpretation_qualified"]
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
