function _bmopf_single_phase_transformer_fixture()
    s, vf, vt = 50_000.0, 11_000.0, 240.0
    zbf, zbt = vf^2 / s, vt^2 / s
    return Dict{String,Any}(
        "bus" => Dict(
            "hv" => Dict{String,Any}("terminal_names" => ["1", "n"],
                         "perfectly_grounded_terminals" => ["n"]),
            "lv" => Dict{String,Any}("terminal_names" => ["1", "n"],
                         "perfectly_grounded_terminals" => ["n"])),
        "voltage_source" => Dict("source" => Dict(
            "bus" => "hv", "terminal_map" => ["1"],
            "v_magnitude" => [vf], "v_angle" => [0.0])),
        "transformer" => Dict("single_phase" => Dict("t1" => Dict(
            "bus_from" => "hv", "bus_to" => "lv",
            "terminal_map_from" => ["1", "n"],
            "terminal_map_to" => ["1", "n"],
            "v_nom_from" => vf, "v_nom_to" => vt, "s_rating" => s,
            "r_series_from" => 0.01zbf, "r_series_to" => 0.01zbt,
            "x_series_from" => 0.04zbf, "x_series_to" => 0.0))),
        "load" => Dict("load" => Dict(
            "bus" => "lv", "terminal_map" => ["1", "n"],
            "configuration" => "WYE", "p_nom" => [30_000.0],
            "q_nom" => [10_000.0])))
end

function _bmopf_wye_delta_transformer_fixture()
    s, vf, vt = 500_000.0, 11_000.0, 415.0
    zbf, zbt = vf^2 / s, vt^2 / s
    return Dict{String,Any}(
        "bus" => Dict(
            "hv" => Dict{String,Any}("terminal_names" => ["1", "2", "3", "n"],
                         "perfectly_grounded_terminals" => ["n"]),
            "lv" => Dict{String,Any}("terminal_names" => ["1", "2", "3"],
                         "perfectly_grounded_terminals" => ["1"])),
        "voltage_source" => Dict("source" => Dict(
            "bus" => "hv", "terminal_map" => ["1", "2", "3"],
            "v_magnitude" => fill(vf / sqrt(3), 3),
            "v_angle" => [0.0, -2pi / 3, 2pi / 3])),
        "transformer" => Dict("wye_delta" => Dict("t1" => Dict(
            "bus_from" => "hv", "bus_to" => "lv",
            "terminal_map_from" => ["1", "2", "3", "n"],
            "terminal_map_to" => ["1", "2", "3"],
            "v_nom_from" => vf, "v_nom_to" => vt, "s_rating" => s,
            "r_series_from" => 0.01zbf, "r_series_to" => 0.01zbt,
            "x_series_from" => 0.02zbf, "x_series_to" => 0.02zbt))),
        "load" => Dict("delta" => Dict(
            "bus" => "lv", "terminal_map" => ["1", "2", "3"],
            "configuration" => "DELTA",
            "p_nom" => [180_000.0, 60_000.0, 120_000.0],
            "q_nom" => [60_000.0, 20_000.0, 40_000.0])))
end

function _bmopf_nwinding_transformer_fixture()
    s = 30e6
    vpn(kv) = kv * 1e3 / sqrt(3)
    zb(kv) = (kv * 1e3)^2 / s
    bus(name) = Dict{String,Any}("terminal_names" => ["a", "b", "c", "n"],
                     "perfectly_grounded_terminals" => ["n"])
    winding(name, kv, percent_r) = Dict(
        "bus" => name, "terminal_map" => ["a", "b", "c", "n"],
        "v_nom" => vpn(kv), "configuration" => "WYE",
        "r_winding" => percent_r / 100 * zb(kv),
        "s_max" => s, "i_max" => s / (3vpn(kv)))
    load(name, p, q) = Dict(
        "bus" => name, "terminal_map" => ["a", "b", "c", "n"],
        "configuration" => "WYE", "p_nom" => fill(p, 3),
        "q_nom" => fill(q, 3))
    return Dict{String,Any}(
        "bus" => Dict("hv" => bus("hv"), "mv" => bus("mv"), "lv" => bus("lv")),
        "voltage_source" => Dict("source" => Dict(
            "bus" => "hv", "terminal_map" => ["a", "b", "c"],
            "v_magnitude" => fill(vpn(115), 3),
            "v_angle" => [0.0, -2pi / 3, 2pi / 3])),
        "transformer" => Dict("n_winding" => Dict("t1" => Dict(
            "windings" => [winding("hv", 115.0, 0.3),
                           winding("mv", 24.9, 0.4),
                           winding("lv", 4.16, 0.4)],
            "x_sc" => Dict("1_2" => 0.08zb(115.0),
                           "1_3" => 0.08zb(115.0),
                           "2_3" => 0.06zb(115.0)),
            "s_rating" => s))),
        "load" => Dict("mvload" => load("mv", 1e6, 2e5),
                       "lvload" => load("lv", 5e5, 1e5)))
end

function _bmopf_dc_converter_fixture()
    return BMOPFTools.parse_bmopf(raw"""
    {"bus":{
        "f1":{"terminal_names":["a","n"],"perfectly_grounded_terminals":["n"]},
        "f2":{"terminal_names":["a","n"],"perfectly_grounded_terminals":["n"]}},
     "voltage_source":{
        "s1":{"bus":"f1","terminal_map":["a"],"v_magnitude":[230.0],"v_angle":[0.0]},
        "s2":{"bus":"f2","terminal_map":["a"],"v_magnitude":[230.0],"v_angle":[0.0]}},
     "load":{"load":{"bus":"f2","terminal_map":["a","n"],
        "configuration":"SINGLE_PHASE","p_nom":[5000.0],"q_nom":[0.0]}},
     "ibr":{
        "vsc1":{"bus":"f1","terminal_map":["a","n"],"topology":"SINGLE_PHASE",
            "prime_mover":"GENERIC","s_max":[8000.0],"dc_bus":"dcA",
            "dc_terminal_map":["p","m"],"dc_control":"V","dc_v_set":850.0},
        "vsc2":{"bus":"f2","terminal_map":["a","n"],"topology":"SINGLE_PHASE",
            "prime_mover":"GENERIC","s_max":[8000.0],"dc_bus":"dcB",
            "dc_terminal_map":["p","m"]}},
     "dc_bus":{
        "dcA":{"terminal_names":["p","m"],"v_dc_nom":[850.0,0.0],
            "v_dc_min":[700.0,0.0],"v_dc_max":[900.0,0.0]},
        "dcB":{"terminal_names":["p","m"],"v_dc_nom":[850.0,0.0],
            "v_dc_min":[700.0,0.0],"v_dc_max":[900.0,0.0]}},
     "dc_branch":{"tie":{"dc_bus_from":"dcA","dc_bus_to":"dcB",
        "terminal_map_from":["p","m"],"terminal_map_to":["p","m"],
        "r":[0.5,0.0]}},
     "dc_grounding":{"ground":{"dc_bus":"dcA","terminal":"m","r":0.0}}}
    """; from_string=true)
end

function _bmopf_formulation_context_pair(network; voltage_factor=0.6, s_base=2.5e5)
    reference = BMOPFTools.build_opf_model(
        deepcopy(network); scaling_policy=BMOPFTools.ClassicPerUnitScaling(1e6),
        add_objective=false)
    bases = BMOPFTools.opf_bases(reference)
    custom_voltages = Dict(string(bus) => voltage_factor * Float64(value)
                           for (bus, value) in bases.v_base)
    dc_voltage_base = isempty(bases.v_dc_base) ? nothing :
        voltage_factor * first(values(bases.v_dc_base))
    candidate = BMOPFTools.build_opf_model(
        deepcopy(network);
        scaling_policy=BMOPFTools.ConsistentPerUnitScaling(
            name=:formulation_covariance, s_base=s_base,
            voltage_bases=custom_voltages,
            dc_voltage_base=dc_voltage_base),
        add_objective=false)
    return reference, candidate
end

function _bmopf_assert_formulation_covariance(network, label)
    reference, candidate = _bmopf_formulation_context_pair(network)
    ref_eval = _bmopf_covariance_evaluation(reference, "$(label)-classic")
    can_eval = _bmopf_covariance_evaluation(candidate, "$(label)-custom")
    ref_map = NLPDiagnostics.bmopf_diagonal_scaling_map(reference, ref_eval)
    can_map = NLPDiagnostics.bmopf_diagonal_scaling_map(candidate, can_eval)
    @test ref_map["available"]
    @test can_map["available"]
    @test isempty(ref_map["unsupported_variables"])
    @test isempty(ref_map["unsupported_constraint_rows"])
    @test isempty(can_map["unsupported_variables"])
    @test isempty(can_map["unsupported_constraint_rows"])
    report = NLPDiagnostics.bmopf_block_scaling_covariance_report(
        reference, ref_eval, candidate, can_eval;
        relative_tolerance=2e-8, absolute_tolerance=1e-8)
    @test report["available"]
    @test report["semantic_alignment"]
    @test report["equivalence_gate_passed"]
    @test report["metrics"]["physical_point"]["passed"]
    @test report["metrics"]["constraint_sets"]["passed"]
    @test report["metrics"]["constraint_residuals"]["passed"]
    @test report["metrics"]["physical_jacobian"]["passed"]
    return reference, ref_eval
end

@testset "BMOPF formulation scaling covariance" begin
    fixtures = (
        (label=:single_phase_transformer,
         builder=_bmopf_single_phase_transformer_fixture,
         perturb! = net -> (net["transformer"]["single_phase"]["t1"]["r_series_from"] *= 1.2)),
        (label=:wye_delta_transformer,
         builder=_bmopf_wye_delta_transformer_fixture,
         perturb! = net -> (net["transformer"]["wye_delta"]["t1"]["r_series_from"] *= 1.2)),
        (label=:n_winding_transformer,
         builder=_bmopf_nwinding_transformer_fixture,
         perturb! = net -> (net["transformer"]["n_winding"]["t1"]["windings"][1]["r_winding"] *= 1.2)),
        (label=:dc_converter_tie,
         builder=_bmopf_dc_converter_fixture,
         perturb! = net -> (net["dc_branch"]["tie"]["r"][1] *= 1.2)),
    )
    for fixture in fixtures
        label, builder = fixture.label, fixture.builder
        @testset "$label" begin
            network = builder()
            reference, ref_eval = _bmopf_assert_formulation_covariance(network, label)

            # Every formulation gets a changed-physics control. It shares the
            # semantic schema and starting physical point, but must be rejected
            # because a winding resistance changed by 20 percent.
            changed = deepcopy(network)
            fixture.perturb!(changed)
            _, changed_context = _bmopf_formulation_context_pair(changed)
            changed_eval = _bmopf_covariance_evaluation(
                changed_context, "$(label)-changed-physics")
            rejected = NLPDiagnostics.bmopf_block_scaling_covariance_report(
                reference, ref_eval, changed_context, changed_eval;
                relative_tolerance=2e-8, absolute_tolerance=1e-8)
            @test rejected["available"]
            @test !rejected["metrics"]["physical_jacobian"]["passed"]
            @test !rejected["equivalence_gate_passed"]
        end
    end
end
