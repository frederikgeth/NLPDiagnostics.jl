#!/usr/bin/env julia

"""Run a qualified three-zone, three-converter AC/DC scaling campaign.

The retained network has three independently scaled AC islands coupled by a
three-node meshed pole-and-metallic-return DC network. A full two-level `2^4`
varies the three AC power bases and the DC power base. Ipopt iterate coordinates
support family-resolved Jacobian trajectories and regularization summaries.
Factorization counts, inertia, fill, pivots, and linear-solver time remain
explicitly unavailable through Ipopt's public callback.

Environment controls use the prefix `NLPDIAGNOSTICS_ACDC_MULTI_`.
"""

include(joinpath(@__DIR__, "bmopf_acdc_base_grid_campaign.jl"))

const _ACDC_MULTI_RUNNER_VERSION = "bmopf-acdc-multiconverter-campaign-v1"
const _ACDC_MULTI_FACTORS = ("s_ac1", "s_ac2", "s_ac3", "s_dc")
const _ACDC_MULTI_EFFECT_SPECS =
    _full_factorial_effect_specs(_ACDC_MULTI_FACTORS)

function _acdc_multiconverter_fixture(; droop=false)
    network = BMOPFTools.parse_bmopf(raw"""
    {"bus":{
        "f1":{"terminal_names":["a","n"],
              "perfectly_grounded_terminals":["n"]},
        "f2":{"terminal_names":["a","n"],
              "perfectly_grounded_terminals":["n"]},
        "f3":{"terminal_names":["a","n"],
              "perfectly_grounded_terminals":["n"]}},
     "voltage_source":{
        "s1":{"bus":"f1","terminal_map":["a"],
              "v_magnitude":[230.0],"v_angle":[0.0],"cost":[0.10]},
        "s2":{"bus":"f2","terminal_map":["a"],
              "v_magnitude":[400.0],"v_angle":[0.0],"cost":[0.25]},
        "s3":{"bus":"f3","terminal_map":["a"],
              "v_magnitude":[690.0],"v_angle":[0.0],"cost":[0.40]}},
     "load":{
        "load2":{"bus":"f2","terminal_map":["a","n"],
            "configuration":"SINGLE_PHASE","p_nom":[5000.0],"q_nom":[0.0]},
        "load3":{"bus":"f3","terminal_map":["a","n"],
            "configuration":"SINGLE_PHASE","p_nom":[3000.0],"q_nom":[0.0]}},
     "ibr":{
        "vsc1":{"bus":"f1","terminal_map":["a","n"],
            "topology":"SINGLE_PHASE","prime_mover":"GENERIC",
            "s_max":[15000.0],"q_min":[0.0],"q_max":[0.0],
            "dc_bus":"dcA","dc_terminal_map":["p","m"],
            "dc_control":"V","dc_v_set":1000.0},
        "vsc2":{"bus":"f2","terminal_map":["a","n"],
            "topology":"SINGLE_PHASE","prime_mover":"GENERIC",
            "s_max":[12000.0],"q_min":[0.0],"q_max":[0.0],
            "dc_bus":"dcB","dc_terminal_map":["p","m"]},
        "vsc3":{"bus":"f3","terminal_map":["a","n"],
            "topology":"SINGLE_PHASE","prime_mover":"GENERIC",
            "s_max":[10000.0],"q_min":[0.0],"q_max":[0.0],
            "dc_bus":"dcC","dc_terminal_map":["p","m"]}},
     "dc_bus":{
        "dcA":{"terminal_names":["p","m"],"v_dc_nom":[1000.0,0.0],
            "v_dc_min":[850.0,-100.0],"v_dc_max":[1100.0,100.0]},
        "dcB":{"terminal_names":["p","m"],"v_dc_nom":[1000.0,0.0],
            "v_dc_min":[850.0,-100.0],"v_dc_max":[1100.0,100.0]},
        "dcC":{"terminal_names":["p","m"],"v_dc_nom":[1000.0,0.0],
            "v_dc_min":[850.0,-100.0],"v_dc_max":[1100.0,100.0]}},
     "dc_branch":{
        "ab":{"dc_bus_from":"dcA","dc_bus_to":"dcB",
            "terminal_map_from":["p","m"],"terminal_map_to":["p","m"],
            "r":[0.40,0.05],"i_max":[30.0,30.0],"p_max":20000.0},
        "bc":{"dc_bus_from":"dcB","dc_bus_to":"dcC",
            "terminal_map_from":["p","m"],"terminal_map_to":["p","m"],
            "r":[0.60,0.08],"i_max":[30.0,30.0],"p_max":20000.0},
        "ac":{"dc_bus_from":"dcA","dc_bus_to":"dcC",
            "terminal_map_from":["p","m"],"terminal_map_to":["p","m"],
            "r":[0.90,0.12],"i_max":[30.0,30.0],"p_max":20000.0}},
     "dc_grounding":{"ground":{"dc_bus":"dcA","terminal":"m","r":0.0}}}
    """; from_string=true)
    if droop
        vsc2 = network["ibr"]["vsc2"]
        vsc2["dc_control"] = "droop"
        vsc2["dc_v_set"] = 990.0
        vsc2["dc_p_ref"] = 2500.0
        vsc2["dc_deadband"] = 2.0
        vsc2["dc_droop"] = 0.01
        vsc3 = network["ibr"]["vsc3"]
        vsc3["dc_control"] = "droop"
        vsc3["dc_v_set"] = 985.0
        vsc3["dc_p_ref"] = 1500.0
        vsc3["dc_deadband"] = 2.0
        vsc3["dc_droop"] = 0.015
    end
    return network
end

function _validate_acdc_multi_levels(levels)
    for factor in _ACDC_MULTI_FACTORS
        values = getproperty(levels, Symbol(factor))
        length(values) == 2 || throw(ArgumentError(
            "$factor must contain exactly two levels",
        ))
        all(value -> isfinite(value) && value > 0, values) ||
            throw(ArgumentError("$factor levels must be finite and positive"))
        values[1] < values[2] || throw(ArgumentError(
            "$factor levels must be strictly increasing (low,high)",
        ))
    end
    return levels
end

function _acdc_multiconverter_policies(levels)
    _validate_acdc_multi_levels(levels)
    policies = Tuple{String,Function}[
        ("classic_1mva", () -> BMOPFTools.ClassicPerUnitScaling(1.0e6)),
    ]
    cells = Dict{String,Any}[]
    voltage_bases = Dict("f1" => 230.0, "f2" => 400.0, "f3" => 690.0)
    labels = ("low", "high")
    signs = (-1, 1)
    for i1 in 1:2, i2 in 1:2, i3 in 1:2, idc in 1:2
        s_ac1 = Float64(levels.s_ac1[i1])
        s_ac2 = Float64(levels.s_ac2[i2])
        s_ac3 = Float64(levels.s_ac3[i3])
        s_dc = Float64(levels.s_dc[idc])
        policy_name =
            "multi_a1_$(labels[i1])_a2_$(labels[i2])_" *
            "a3_$(labels[i3])_dc_$(labels[idc])"
        policy_symbol = Symbol(policy_name)
        push!(policies, (
            policy_name,
            () -> BMOPFTools.ZonePerUnitScaling(
                name=policy_symbol,
                voltage_bases=copy(voltage_bases),
                power_bases=Dict(
                    "f1" => s_ac1, "f2" => s_ac2, "f3" => s_ac3,
                ),
                dc_voltage_base=1000.0,
                dc_power_base=s_dc,
            ),
        ))
        push!(cells, Dict{String,Any}(
            "policy" => policy_name,
            "levels" => Dict(
                "s_ac1" => labels[i1],
                "s_ac2" => labels[i2],
                "s_ac3" => labels[i3],
                "s_dc" => labels[idc],
            ),
            "coded_levels" => Dict(
                "s_ac1" => signs[i1],
                "s_ac2" => signs[i2],
                "s_ac3" => signs[i3],
                "s_dc" => signs[idc],
            ),
            "power_bases" => Dict(
                "s_ac1" => s_ac1,
                "s_ac2" => s_ac2,
                "s_ac3" => s_ac3,
                "s_dc" => s_dc,
            ),
            "converter_coefficients" => Dict(
                "vsc1_s_ac_over_s_dc" => s_ac1 / s_dc,
                "vsc2_s_ac_over_s_dc" => s_ac2 / s_dc,
                "vsc3_s_ac_over_s_dc" => s_ac3 / s_dc,
            ),
        ))
    end
    return policies, cells
end

function _acdc_multi_trace_records(artifact)
    trace_profile = get(artifact, "solver_trace_profile", Dict())
    trace = get(trace_profile, "iteration_trace", Dict())
    return get(trace, "records", Any[])
end

function _acdc_multi_regularization_summary(artifact)
    values = Float64[]
    for record in _acdc_multi_trace_records(artifact)
        value = get(record, "regularization_size", nothing)
        value isa Real && isfinite(value) && push!(values, Float64(value))
    end
    return Dict{String,Any}(
        "coverage_complete" =>
            length(values) == length(_acdc_multi_trace_records(artifact)),
        "record_count" => length(values),
        "positive_record_count" => count(>(0.0), values),
        "maximum" => isempty(values) ? nothing : maximum(values),
        "is_factorization_telemetry" => false,
    )
end

function _acdc_multi_top_trajectory_movers(geometry, axis; maximum_count=6)
    trajectories = get(get(geometry, "trajectories", Dict()), axis, Dict())
    metric = axis == "rows" ?
        "largest_finite_row_norm" : "largest_finite_column_norm"
    records = Dict{String,Any}[]
    for (family, family_record) in trajectories
        summary = get(family_record, metric, Dict())
        ratio = get(summary, "maximum_to_minimum_positive_ratio", nothing)
        ratio isa Real && isfinite(ratio) || continue
        push!(records, Dict{String,Any}(
            "family" => family,
            "metric" => metric,
            "first" => get(summary, "first", nothing),
            "last" => get(summary, "last", nothing),
            "minimum" => get(summary, "minimum", nothing),
            "maximum" => get(summary, "maximum", nothing),
            "maximum_to_minimum_positive_ratio" => Float64(ratio),
        ))
    end
    sort!(records; by=record -> (
        -record["maximum_to_minimum_positive_ratio"], record["family"],
    ))
    return records[1:min(maximum_count, length(records))]
end

function _acdc_multiconverter_attribution(campaign)
    records = Dict{String,Any}[]
    for run in get(campaign, "run_records", Any[])
        artifact = get(run, "artifact", Dict())
        geometry = get(artifact, "trace_family_geometry", Dict())
        telemetry = get(artifact, "linear_solver_telemetry", Dict())
        regularization = _acdc_multi_regularization_summary(artifact)
        push!(records, Dict{String,Any}(
            "policy" => get(run, "policy", nothing),
            "replicate" => get(run, "replicate", nothing),
            "geometry_available" => get(geometry, "available", false),
            "geometry_interpretation_qualified" =>
                get(geometry, "interpretation_qualified", false),
            "selected_iterations" =>
                get(geometry, "selected_iterations", Any[]),
            "regularization" => regularization,
            "factorization_work_available" =>
                get(telemetry, "factorization_work_available", false),
            "linear_solver_time_available" =>
                get(telemetry, "linear_solver_time_available", false),
            "factorization_numerics" =>
                get(telemetry, "factorization_numerics", Dict()),
            "top_row_trajectory_movers" =>
                _acdc_multi_top_trajectory_movers(geometry, "rows"),
            "top_column_trajectory_movers" =>
                _acdc_multi_top_trajectory_movers(geometry, "columns"),
        ))
    end
    run_count = length(get(campaign, "run_records", Any[]))
    geometry_coverage = length(records) == run_count && all(
        get(record, "geometry_interpretation_qualified", false) === true
        for record in records
    )
    regularization_coverage = length(records) == run_count && all(
        get(record["regularization"], "coverage_complete", false) === true
        for record in records
    )
    trajectory_coverage = length(records) == run_count && all(
        !isempty(record["top_row_trajectory_movers"]) &&
        !isempty(record["top_column_trajectory_movers"])
        for record in records
    )
    factorization_count = count(
        record -> get(record, "factorization_work_available", false) === true,
        records,
    )
    qualified = run_count > 0 && geometry_coverage &&
        regularization_coverage && trajectory_coverage
    return Dict{String,Any}(
        "schema_version" => "bmopf-acdc-multiconverter-attribution-v1",
        "available" => !isempty(records),
        "attribution_qualified" => qualified,
        "run_count" => run_count,
        "records" => records,
        "gates" => Dict{String,Any}(
            "trace_geometry_coverage_complete" => geometry_coverage,
            "regularization_proxy_coverage_complete" =>
                regularization_coverage,
            "family_trajectory_coverage_complete" => trajectory_coverage,
        ),
        "linear_solver_capability" => Dict{String,Any}(
            "solver" => "Ipopt",
            "factorization_work_available_count" => factorization_count,
            "run_count" => run_count,
            "joint_geometry_and_factorization_attribution_available" =>
                factorization_count == run_count && geometry_coverage,
            "reason" =>
                "Ipopt.CallbackFunction exposes iterate coordinates and regularization but not factorization counts, inertia, fill, pivots, backward error, or linear-solver time",
            "absence_is_not_a_qualification_failure" => true,
        ),
        "qualification" => Dict{String,Any}(
            "claim" =>
                "trace-resolved semantic-family geometry and regularization attribution for every retained Ipopt run",
            "does_not_establish" => [
                "factorization work or stability through the Ipopt callback",
                "causality between a family trajectory and iteration count",
                "joint trajectory/factorization attribution",
            ],
        ),
    )
end

function run_acdc_multiconverter_campaign(;
    levels,
    repeats,
    seeds,
    relative_perturbation,
    max_iter,
    solver_tolerance,
    endpoint_absolute_tolerance=0.2,
    endpoint_relative_tolerance=3.0e-5,
    physical_complementarity_tolerance=2.0e-4,
)
    _validate_acdc_multi_levels(levels)
    repeats >= 2 || throw(ArgumentError("repeats must be at least two"))
    isempty(seeds) && throw(ArgumentError(
        "at least one perturbed-start seed is required for stratification",
    ))
    environment = _benchmark_environment()
    environment_fingerprint = _benchmark_environment_fingerprint(environment)
    policies, cells = _acdc_multiconverter_policies(levels)
    case_records = Dict{String,Any}[]
    for (control_case, droop) in (
        ("three-converter-p-v", false),
        ("three-converter-droop-sharing", true),
    )
        network = _acdc_multiconverter_fixture(; droop)
        anchor_context = _build_context(
            network, first(policies)[2](); add_objective=true,
        )
        base_point = NLPDiagnostics.bmopf_start_completion_point(
            anchor_context;
            missing_value=0.0,
            label="$control_case-native-start",
        )
        anchor_model = BMOPFTools.opf_model(anchor_context)
        strata = [(name="native", point=base_point)]
        append!(strata, [(
            name="nearby-seed-$seed",
            point=_safe_perturbed_point(
                anchor_model, base_point, seed, relative_perturbation,
            ),
        ) for seed in seeds])
        stratum_records = Dict{String,Any}[]
        for stratum in strata
            anchor_evaluation = NLPDiagnostics.evaluate_numerical(
                JuMP.backend(anchor_model), stratum.point,
            )
            campaign = _acdc_campaign_for_stratum(
                network,
                policies,
                control_case,
                stratum.name,
                anchor_context,
                anchor_evaluation,
                environment_fingerprint;
                repeats,
                max_iter,
                solver_tolerance,
                endpoint_absolute_tolerance,
                endpoint_relative_tolerance,
                physical_complementarity_tolerance,
                runner_version=_ACDC_MULTI_RUNNER_VERSION,
                trace_geometry_max_points=10,
            )
            factorial = _acdc_grid_factorial_analysis(
                campaign,
                cells;
                factors=_ACDC_MULTI_FACTORS,
                effect_specs=_ACDC_MULTI_EFFECT_SPECS,
                schema_version=
                    "bmopf-acdc-multiconverter-factorial-analysis-v1",
            )
            attribution = _acdc_multiconverter_attribution(campaign)
            campaign["factorial_analysis"] = factorial
            campaign["trajectory_attribution"] = attribution
            campaign["campaign_qualified"] =
                get(campaign, "campaign_qualified", false) === true &&
                get(factorial, "analysis_qualified", false) === true &&
                get(attribution, "attribution_qualified", false) === true
            push!(stratum_records, Dict{String,Any}(
                "stratum" => stratum.name,
                "campaign" => campaign,
            ))
        end
        stratified = NLPDiagnostics.scaling_solver_experiment_stratified_campaign_data(
            stratum_records;
            minimum_strata=length(strata),
            minimum_repeats=repeats,
            metadata=Dict(
                "case" => control_case,
                "relative_perturbation" => relative_perturbation,
                "seeds" => seeds,
                "factorial_cell_count" => length(cells),
                "ac_zone_count" => 3,
                "dc_bus_count" => 3,
                "dc_branch_count" => 3,
            ),
        )
        contract_gates_passed = all(
            get(record["campaign"]["acdc_scaling_contract_gate"], "passed", false) === true
            for record in stratum_records
        )
        factorial_gates_passed = all(
            get(record["campaign"]["factorial_analysis"], "analysis_qualified", false) === true
            for record in stratum_records
        )
        attribution_gates_passed = all(
            get(record["campaign"]["trajectory_attribution"], "attribution_qualified", false) === true
            for record in stratum_records
        )
        stratified["acdc_scaling_contract_gates_passed"] = contract_gates_passed
        stratified["factorial_analysis_gates_passed"] = factorial_gates_passed
        stratified["trajectory_attribution_gates_passed"] =
            attribution_gates_passed
        stratified["campaign_qualified"] =
            get(stratified, "campaign_qualified", false) === true &&
            contract_gates_passed && factorial_gates_passed &&
            attribution_gates_passed
        push!(case_records, Dict{String,Any}(
            "case" => control_case,
            "campaign" => stratified,
        ))
    end
    qualified = all(
        get(record["campaign"], "campaign_qualified", false) === true
        for record in case_records
    )
    return Dict{String,Any}(
        "schema_version" => "bmopf-acdc-multiconverter-study-v1",
        "runner_version" => _ACDC_MULTI_RUNNER_VERSION,
        "available" => true,
        "campaign_qualified" => qualified,
        "case_count" => length(case_records),
        "cases" => case_records,
        "environment" => environment,
        "environment_fingerprint" => environment_fingerprint,
        "factorial_design" => Dict{String,Any}(
            "type" => "full 2^4 two-level factorial",
            "factors" => collect(_ACDC_MULTI_FACTORS),
            "levels" => Dict(
                factor => collect(Float64.(getproperty(levels, Symbol(factor))))
                for factor in _ACDC_MULTI_FACTORS
            ),
            "cell_count" => length(cells),
            "cells" => cells,
            "reference_policy" => first(policies)[1],
            "policy_ranking_performed" => false,
        ),
        "effect_direction_summary" => _acdc_grid_direction_summary(case_records),
        "design" => Dict{String,Any}(
            "objective_bearing" => true,
            "ac_zone_count" => 3,
            "converter_count" => 3,
            "dc_bus_count" => 3,
            "dc_branch_count" => 3,
            "dc_topology" => "meshed triangle with resistive pole and return",
            "lossless_converters" => true,
            "reactive_converter_power_fixed" => true,
            "repeats_per_policy_per_stratum" => repeats,
            "native_start_included" => true,
            "perturbed_start_seeds" => seeds,
            "relative_perturbation" => relative_perturbation,
            "controller_cases" => ["P/V", "two-droop sharing plus V master"],
            "native_acdc_contract_required" => true,
            "trace_family_geometry_required" => true,
            "regularization_attribution_required" => true,
            "factorization_telemetry_required" => false,
            "solver" => "Ipopt",
        ),
        "qualification" => Dict{String,Any}(
            "claim" =>
                "qualified four-factor base-allocation and trace-geometry evidence on a retained three-converter meshed AC/DC fixture",
            "does_not_establish" => [
                "a best power-base allocation",
                "factorization-level attribution through Ipopt",
                "behavior on lossy converters or large feeder networks",
                "performance portability to another nonlinear solver",
            ],
        ),
    )
end

function _compact_acdc_multiconverter_campaign(campaign)
    return Dict{String,Any}(
        "schema_version" => "bmopf-acdc-multiconverter-study-summary-v1",
        "source_schema_version" => campaign["schema_version"],
        "runner_version" => campaign["runner_version"],
        "available" => campaign["available"],
        "campaign_qualified" => campaign["campaign_qualified"],
        "case_count" => campaign["case_count"],
        "environment_fingerprint" => campaign["environment_fingerprint"],
        "factorial_design" => campaign["factorial_design"],
        "effect_direction_summary" => campaign["effect_direction_summary"],
        "design" => campaign["design"],
        "qualification" => campaign["qualification"],
        "cases" => [
            Dict{String,Any}(
                "case" => record["case"],
                "campaign_qualified" => record["campaign"]["campaign_qualified"],
                "gates" => record["campaign"]["gates"],
                "policies" => record["campaign"]["policies"],
                "metadata" => record["campaign"]["metadata"],
                "acdc_scaling_contract_gates_passed" =>
                    record["campaign"]["acdc_scaling_contract_gates_passed"],
                "factorial_analysis_gates_passed" =>
                    record["campaign"]["factorial_analysis_gates_passed"],
                "trajectory_attribution_gates_passed" =>
                    record["campaign"]["trajectory_attribution_gates_passed"],
                "strata" => [
                    Dict{String,Any}(
                        "stratum" => stratum["stratum"],
                        "campaign_qualified" =>
                            stratum["campaign"]["campaign_qualified"],
                        "gates" => stratum["campaign"]["gates"],
                        "policies" => stratum["campaign"]["policies"],
                        "comparisons" => stratum["campaign"]["comparisons"],
                        "acdc_scaling_contract_gate" =>
                            stratum["campaign"]["acdc_scaling_contract_gate"],
                        "factorial_analysis" =>
                            stratum["campaign"]["factorial_analysis"],
                        "trajectory_attribution" =>
                            stratum["campaign"]["trajectory_attribution"],
                    ) for stratum in record["campaign"]["stratum_records"]
                ],
            ) for record in campaign["cases"]
        ],
    )
end

function acdc_multiconverter_main()
    levels = (
        s_ac1=_parse_acdc_grid_levels(
            "NLPDIAGNOSTICS_ACDC_MULTI_S_AC1",
            get(ENV, "NLPDIAGNOSTICS_ACDC_MULTI_S_AC1", "10000,1000000"),
        ),
        s_ac2=_parse_acdc_grid_levels(
            "NLPDIAGNOSTICS_ACDC_MULTI_S_AC2",
            get(ENV, "NLPDIAGNOSTICS_ACDC_MULTI_S_AC2", "10000,100000"),
        ),
        s_ac3=_parse_acdc_grid_levels(
            "NLPDIAGNOSTICS_ACDC_MULTI_S_AC3",
            get(ENV, "NLPDIAGNOSTICS_ACDC_MULTI_S_AC3", "10000,50000"),
        ),
        s_dc=_parse_acdc_grid_levels(
            "NLPDIAGNOSTICS_ACDC_MULTI_S_DC",
            get(ENV, "NLPDIAGNOSTICS_ACDC_MULTI_S_DC", "10000,200000"),
        ),
    )
    repeats = _env_int("NLPDIAGNOSTICS_ACDC_MULTI_REPEATS", 2; minimum=2)
    seeds = _parse_seeds(get(ENV, "NLPDIAGNOSTICS_ACDC_MULTI_SEEDS", "11"))
    isempty(seeds) && error(
        "NLPDIAGNOSTICS_ACDC_MULTI_SEEDS must contain at least one integer seed",
    )
    relative_perturbation = _env_float(
        "NLPDIAGNOSTICS_ACDC_MULTI_PERTURBATION", 0.001; positive=true,
    )
    max_iter = _env_int("NLPDIAGNOSTICS_ACDC_MULTI_MAX_ITER", 200; minimum=1)
    solver_tolerance = _env_float(
        "NLPDIAGNOSTICS_ACDC_MULTI_TOL", 1.0e-8; positive=true,
    )
    output = abspath(get(
        ENV,
        "NLPDIAGNOSTICS_ACDC_MULTI_OUTPUT",
        joinpath(
            @__DIR__, "..", "work", "bmopf-acdc-multiconverter-campaign.json",
        ),
    ))
    campaign = run_acdc_multiconverter_campaign(;
        levels,
        repeats,
        seeds,
        relative_perturbation,
        max_iter,
        solver_tolerance,
    )
    mkpath(dirname(output))
    write(output, JSON.json(_json_safe(campaign)))
    stem, extension = splitext(output)
    summary_output = stem * "-summary" * extension
    write(
        summary_output,
        JSON.json(_json_safe(_compact_acdc_multiconverter_campaign(campaign))),
    )
    println("wrote multi-converter AC/DC campaign to $output")
    println("wrote compact multi-converter summary to $summary_output")
    println("campaign_qualified=$(campaign["campaign_qualified"])")
    for record in campaign["cases"]
        println(
            "$(record["case"]): qualified=$(record["campaign"]["campaign_qualified"]) " *
            "strata=$(record["campaign"]["stratum_count"])",
        )
    end
end

if abspath(PROGRAM_FILE) == abspath(@__FILE__)
    acdc_multiconverter_main()
end
