#!/usr/bin/env julia

"""Run a matched objective-bearing AC/DC local-base scaling campaign.

The retained fixture has two AC zones joined only through a resistive DC link.
Each fresh model receives the same physical start through BMOPFTools' semantic
transport. In addition to the generic endpoint, geometry, provenance, and
repeatability gates, every run must pass the native lossless AC/DC coefficient
contract for its own power-coordinate allocation.

Environment controls:

  * `NLPDIAGNOSTICS_ACDC_REPEATS` (default `2`, minimum `2`)
  * `NLPDIAGNOSTICS_ACDC_SEEDS` (default `11`; native is also run)
  * `NLPDIAGNOSTICS_ACDC_PERTURBATION` (default `0.001`)
  * `NLPDIAGNOSTICS_ACDC_MAX_ITER` (default `150`)
  * `NLPDIAGNOSTICS_ACDC_TOL` (default `1e-8`)
  * `NLPDIAGNOSTICS_ACDC_OUTPUT` (default under `work/`)
"""

include(joinpath(@__DIR__, "bmopf_stratified_scaling_campaign.jl"))

const _ACDC_RUNNER_VERSION = "bmopf-acdc-scaling-campaign-v1"

function _acdc_objective_fixture(; droop=false)
    network = BMOPFTools.parse_bmopf(raw"""
    {"bus":{
        "f1":{"terminal_names":["a","n"],
              "perfectly_grounded_terminals":["n"]},
        "f2":{"terminal_names":["a","n"],
              "perfectly_grounded_terminals":["n"]}},
     "voltage_source":{
        "s1":{"bus":"f1","terminal_map":["a"],
              "v_magnitude":[230.0],"v_angle":[0.0],"cost":[0.1]},
        "s2":{"bus":"f2","terminal_map":["a"],
              "v_magnitude":[230.0],"v_angle":[0.0],"cost":[0.3]}},
     "load":{"load":{"bus":"f2","terminal_map":["a","n"],
        "configuration":"SINGLE_PHASE","p_nom":[5000.0],"q_nom":[0.0]}},
     "ibr":{
        "vsc1":{"bus":"f1","terminal_map":["a","n"],
            "topology":"SINGLE_PHASE","prime_mover":"GENERIC",
            "s_max":[8000.0],"q_min":[0.0],"q_max":[0.0],"dc_bus":"dcA",
            "dc_terminal_map":["p","m"],"dc_control":"V",
            "dc_v_set":850.0},
        "vsc2":{"bus":"f2","terminal_map":["a","n"],
            "topology":"SINGLE_PHASE","prime_mover":"GENERIC",
            "s_max":[8000.0],"q_min":[0.0],"q_max":[0.0],"dc_bus":"dcB",
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

function _acdc_policy_factories()
    voltage_bases = Dict("f1" => 230.0, "f2" => 230.0)
    return [
        ("classic_1mva", () -> BMOPFTools.OpfScaling(:classic; power_base=1.0e6)),
        ("si_units", () -> BMOPFTools.OpfScaling(:si)),
        (
            "zone_rating_aligned",
            () -> BMOPFTools.OpfScaling(
                name=:zone_rating_aligned,
                voltage_bases=copy(voltage_bases),
                power_bases=Dict("f1" => 10.0e3, "f2" => 10.0e3),
                dc_voltage_base=850.0,
                dc_power_base=10.0e3,
            ),
        ),
        (
            "zone_asymmetric_50x5",
            () -> BMOPFTools.OpfScaling(
                name=:zone_asymmetric_50x5,
                voltage_bases=copy(voltage_bases),
                power_bases=Dict("f1" => 1.0e6, "f2" => 100.0e3),
                dc_voltage_base=850.0,
                dc_power_base=20.0e3,
            ),
        ),
    ]
end

function _acdc_campaign_for_stratum(
    network,
    policies,
    control_case,
    stratum_name,
    anchor_context,
    anchor_evaluation,
    environment_fingerprint;
    repeats,
    max_iter,
    solver_tolerance,
    endpoint_absolute_tolerance,
    endpoint_relative_tolerance,
    physical_complementarity_tolerance,
    runner_version=_ACDC_RUNNER_VERSION,
    optimizer=Ipopt.Optimizer,
    solver=:ipopt,
    solver_name="Ipopt",
    capture_points=true,
    trace_geometry=true,
    trace_geometry_max_points=8,
    complete_fixed_variable_duals=false,
    max_dense_entries=100_000,
)
    reference_policy = first(policies)[1]
    public_runs = Dict{String,Any}[]
    private_runs = Dict{Tuple{String,Int},Any}()
    for (policy_name, factory) in policies
        for replicate in 1:repeats
            public_record, private_record = _run_policy(
                network,
                policy_name,
                factory(),
                replicate,
                anchor_context,
                anchor_evaluation,
                environment_fingerprint;
                max_iter,
                solver_tolerance,
                add_objective=true,
                physical_complementarity_tolerance,
                capture_points,
                trace_geometry,
                trace_geometry_max_points,
                optimizer,
                solver,
                require_canonical_voltage_pattern=false,
                require_phasor_transport=true,
                complete_fixed_variable_duals,
                max_dense_entries,
            )
            contract = NLPDiagnostics.bmopf_acdc_scaling_contract_data(
                private_record.context,
            )
            public_record["case"] = control_case
            public_record["start_stratum"] = stratum_name
            public_record["acdc_scaling_contract"] = contract
            public_record["acdc_scaling_contract_passed"] =
                get(contract, "comparison_ready", false) === true
            push!(public_runs, public_record)
            private_runs[(policy_name, replicate)] = private_record
        end
    end

    comparisons = Dict{String,Any}[]
    reference_first = private_runs[(reference_policy, 1)]
    for replicate in 2:repeats
        comparison = _matched_comparison(
            reference_policy,
            1,
            reference_first,
            reference_policy,
            replicate,
            private_runs[(reference_policy, replicate)];
            baseline_repeat=true,
            endpoint_absolute_tolerance,
            endpoint_relative_tolerance,
            max_dense_entries,
        )
        comparison["case"] = control_case
        comparison["start_stratum"] = stratum_name
        push!(comparisons, comparison)
    end
    for (policy_name, _) in policies[2:end]
        for replicate in 1:repeats
            comparison = _matched_comparison(
                reference_policy,
                replicate,
                private_runs[(reference_policy, replicate)],
                policy_name,
                replicate,
                private_runs[(policy_name, replicate)];
                endpoint_absolute_tolerance,
                endpoint_relative_tolerance,
                max_dense_entries,
            )
            comparison["case"] = control_case
            comparison["start_stratum"] = stratum_name
            push!(comparisons, comparison)
        end
    end

    campaign = NLPDiagnostics.scaling_solver_experiment_campaign_data(
        public_runs,
        comparisons;
        reference_policy,
        minimum_repeats=repeats,
        require_native_initialization_covariance=true,
        metadata=Dict(
            "runner_version" => runner_version,
            "case" => control_case,
            "start_stratum" => stratum_name,
            "physical_start_fingerprint" =>
                NLPDiagnostics.evaluation_point_fingerprint(
                    anchor_evaluation.point,
                ),
            "solver" => solver_name,
            "max_iter" => max_iter,
            "solver_tolerance" => solver_tolerance,
            "endpoint_absolute_tolerance" => endpoint_absolute_tolerance,
            "endpoint_relative_tolerance" => endpoint_relative_tolerance,
            "physical_complementarity_tolerance" =>
                physical_complementarity_tolerance,
        ),
    )
    contract_gate = all(
        get(run, "acdc_scaling_contract_passed", false) === true
        for run in public_runs
    )
    campaign["acdc_scaling_contract_gate"] = Dict{String,Any}(
        "required" => true,
        "passed" => contract_gate,
        "run_count" => length(public_runs),
        "passed_run_count" => count(
            run -> get(run, "acdc_scaling_contract_passed", false) === true,
            public_runs,
        ),
        "qualified_scope" =>
            "native lossless AC/DC P, V, and droop controller equations",
    )
    campaign["campaign_qualified"] =
        get(campaign, "campaign_qualified", false) === true && contract_gate
    return campaign
end

function run_acdc_campaign(;
    repeats,
    seeds,
    relative_perturbation,
    max_iter,
    solver_tolerance,
    endpoint_absolute_tolerance=0.1,
    endpoint_relative_tolerance=2.0e-5,
    physical_complementarity_tolerance=1.0e-4,
)
    isempty(seeds) && throw(ArgumentError(
        "at least one perturbed-start seed is required for stratification",
    ))
    environment = _benchmark_environment()
    environment_fingerprint = _benchmark_environment_fingerprint(environment)
    policies = _acdc_policy_factories()
    case_records = Dict{String,Any}[]
    for (control_case, droop) in (("p-v-control", false), ("droop-v-control", true))
        network = _acdc_objective_fixture(; droop)
        anchor_context = _build_context(
            network,
            first(policies)[2]();
            add_objective=true,
        )
        base_point = NLPDiagnostics.bmopf_start_completion_point(
            anchor_context;
            missing_value=0.0,
            label="$control_case-native-start",
        )
        anchor_model = BMOPFTools.opf_model(anchor_context)
        strata = [(name="native", point=base_point)]
        append!(strata, [
            (
                name="nearby-seed-$seed",
                point=_safe_perturbed_point(
                    anchor_model, base_point, seed, relative_perturbation,
                ),
            ) for seed in seeds
        ])
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
            )
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
            ),
        )
        contract_gates_passed = all(
            get(record["campaign"]["acdc_scaling_contract_gate"], "passed", false) === true
            for record in stratum_records
        )
        stratified["acdc_scaling_contract_gates_passed"] = contract_gates_passed
        stratified["campaign_qualified"] =
            get(stratified, "campaign_qualified", false) === true &&
            contract_gates_passed
        push!(case_records, Dict{String,Any}(
            "case" => control_case,
            "campaign" => stratified,
        ))
    end
    return Dict{String,Any}(
        "schema_version" => "bmopf-acdc-scaling-study-v1",
        "runner_version" => _ACDC_RUNNER_VERSION,
        "available" => true,
        "campaign_qualified" => all(
            get(record["campaign"], "campaign_qualified", false) === true
            for record in case_records
        ),
        "case_count" => length(case_records),
        "cases" => case_records,
        "environment" => environment,
        "environment_fingerprint" => environment_fingerprint,
        "design" => Dict{String,Any}(
            "objective_bearing" => true,
            "lossless_converters" => true,
            "reactive_converter_power_fixed" => true,
            "repeats_per_policy_per_stratum" => repeats,
            "native_start_included" => true,
            "perturbed_start_seeds" => seeds,
            "relative_perturbation" => relative_perturbation,
            "physical_start_transport" =>
                "BMOPFTools semantic-block model-to-physical-to-model transport",
            "native_acdc_contract_required" => true,
            "policy_ranking_performed" => false,
            "solver" => "Ipopt",
        ),
        "qualification" => Dict{String,Any}(
            "claim" =>
                "repeat- and start-stratified matched scaling evidence for native lossless AC/DC converter coordinates",
            "does_not_establish" => [
                "global scaling-policy superiority",
                "lossy or custom converter covariance",
                "behavior on large AC/DC networks",
                "performance portability to another nonlinear solver",
            ],
        ),
    )
end

function _compact_acdc_campaign(campaign)
    return Dict{String,Any}(
        "schema_version" => "bmopf-acdc-scaling-study-summary-v1",
        "source_schema_version" => campaign["schema_version"],
        "runner_version" => campaign["runner_version"],
        "available" => campaign["available"],
        "campaign_qualified" => campaign["campaign_qualified"],
        "case_count" => campaign["case_count"],
        "environment_fingerprint" => campaign["environment_fingerprint"],
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
                        "trace_evidence_records" =>
                            _compact_trace_evidence_records(stratum["campaign"]),
                    ) for stratum in record["campaign"]["stratum_records"]
                ],
            ) for record in campaign["cases"]
        ],
    )
end

function acdc_main()
    repeats = _env_int("NLPDIAGNOSTICS_ACDC_REPEATS", 2; minimum=2)
    seeds = _parse_seeds(get(ENV, "NLPDIAGNOSTICS_ACDC_SEEDS", "11"))
    isempty(seeds) && error(
        "NLPDIAGNOSTICS_ACDC_SEEDS must contain at least one integer seed",
    )
    relative_perturbation = _env_float(
        "NLPDIAGNOSTICS_ACDC_PERTURBATION", 0.001; positive=true,
    )
    max_iter = _env_int("NLPDIAGNOSTICS_ACDC_MAX_ITER", 150; minimum=1)
    solver_tolerance = _env_float(
        "NLPDIAGNOSTICS_ACDC_TOL", 1.0e-8; positive=true,
    )
    output = abspath(get(
        ENV,
        "NLPDIAGNOSTICS_ACDC_OUTPUT",
        joinpath(@__DIR__, "..", "work", "bmopf-acdc-scaling-campaign.json"),
    ))
    campaign = run_acdc_campaign(;
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
    write(summary_output, JSON.json(_json_safe(_compact_acdc_campaign(campaign))))
    println("wrote matched AC/DC scaling campaign to $output")
    println("wrote compact AC/DC campaign summary to $summary_output")
    println("campaign_qualified=$(campaign["campaign_qualified"])")
    for record in campaign["cases"]
        case_campaign = record["campaign"]
        println(
            "$(record["case"]): qualified=$(case_campaign["campaign_qualified"]) " *
            "strata=$(case_campaign["stratum_count"])",
        )
        for (policy, summary) in sort!(collect(case_campaign["policies"]); by=first)
            records = summary["record_count_range"]
            trials = summary["line_search_trial_sum_range"]
            println(
                "  $policy records=$(get(records, "minimum", nothing))..$(get(records, "maximum", nothing)) " *
                "trials=$(get(trials, "minimum", nothing))..$(get(trials, "maximum", nothing))",
            )
        end
    end
end

if abspath(PROGRAM_FILE) == abspath(@__FILE__)
    acdc_main()
end
