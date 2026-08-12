#!/usr/bin/env julia

"""Run objective-bearing BMOPF scaling campaigns across physical-start strata.

The campaign contains two compact truth fixtures: an unbalanced three-phase
line/load/generator problem and a two-voltage-level wye-delta transformer
problem with a delta generator. Candidate scaling policies are constructed
from BMOPFTools' authoritative classic voltage bases. Every policy/replicate in
a stratum receives the same physical point through semantic-block transport.

Environment controls:

  * `NLPDIAGNOSTICS_STRATIFIED_REPEATS` (default `5`, minimum `2`)
  * `NLPDIAGNOSTICS_STRATIFIED_SEEDS` (default `11,29`; native is also run)
  * `NLPDIAGNOSTICS_STRATIFIED_PERTURBATION` (default `0.01`)
  * `NLPDIAGNOSTICS_STRATIFIED_CASES` (`three_phase,transformer` by default)
  * `NLPDIAGNOSTICS_STRATIFIED_OUTPUT` (default under `work/`)
  * `NLPDIAGNOSTICS_STRATIFIED_MAX_ITER` (default `150`)
  * `NLPDIAGNOSTICS_STRATIFIED_TOL` (default `1e-8`)
"""

include(joinpath(@__DIR__, "bmopf_magnitude_scaling_campaign.jl"))

using Random

const _STRATIFIED_RUNNER_VERSION = "bmopf-stratified-scaling-campaign-v1"

function _three_phase_objective_fixture()
    return BMOPFTools.parse_bmopf(raw"""
    {"bus":{
        "source":{"terminal_names":["1","2","3","n"],
                  "perfectly_grounded_terminals":["n"]},
        "loadbus":{"terminal_names":["1","2","3","n"],
                   "perfectly_grounded_terminals":["n"]}},
     "voltage_source":{"source":{"bus":"source",
         "terminal_map":["1","2","3"],
         "v_magnitude":[1000.0,1000.0,1000.0],
         "v_angle":[0.0,-2.0943951023931953,2.0943951023931953],
         "cost":[1.0,1.0,1.0]}},
     "linecode":{"lc":{"R_series_1_1":0.08,"R_series_2_2":0.10,
         "R_series_3_3":0.12,"i_max":[500.0,500.0,500.0]}},
     "line":{"line":{"bus_from":"source","bus_to":"loadbus",
         "terminal_map_from":["1","2","3"],
         "terminal_map_to":["1","2","3"],
         "linecode":"lc","length":1.0}},
     "load":{"load":{"bus":"loadbus",
         "terminal_map":["1","2","3","n"],"configuration":"WYE",
         "p_nom":[150000.0,100000.0,75000.0],
         "q_nom":[45000.0,20000.0,10000.0]}},
     "generator":{"local":{"bus":"loadbus",
         "terminal_map":["1","2","3","n"],"configuration":"WYE",
         "p_min":[0.0,0.0,0.0],"p_max":[70000.0,70000.0,70000.0],
         "q_min":[-30000.0,-30000.0,-30000.0],
         "q_max":[30000.0,30000.0,30000.0],
         "cost":[0.25,0.25,0.25]}}}
    """; from_string=true)
end

function _transformer_objective_fixture()
    s, vf, vt = 500_000.0, 11_000.0, 415.0
    zbf, zbt = vf^2 / s, vt^2 / s
    return Dict{String,Any}(
        "bus" => Dict(
            "hv" => Dict{String,Any}(
                "terminal_names" => ["1", "2", "3", "n"],
                "perfectly_grounded_terminals" => ["n"],
            ),
            "lv" => Dict{String,Any}(
                "terminal_names" => ["1", "2", "3"],
                "perfectly_grounded_terminals" => ["1"],
            ),
        ),
        "voltage_source" => Dict("source" => Dict(
            "bus" => "hv",
            "terminal_map" => ["1", "2", "3"],
            "v_magnitude" => fill(vf / sqrt(3), 3),
            "v_angle" => [0.0, -2pi / 3, 2pi / 3],
            "cost" => fill(1.0, 3),
        )),
        "transformer" => Dict("wye_delta" => Dict("t1" => Dict(
            "bus_from" => "hv",
            "bus_to" => "lv",
            "terminal_map_from" => ["1", "2", "3", "n"],
            "terminal_map_to" => ["1", "2", "3"],
            "v_nom_from" => vf,
            "v_nom_to" => vt,
            "s_rating" => s,
            "r_series_from" => 0.01zbf,
            "r_series_to" => 0.01zbt,
            "x_series_from" => 0.02zbf,
            "x_series_to" => 0.02zbt,
        ))),
        "load" => Dict("delta" => Dict(
            "bus" => "lv",
            "terminal_map" => ["1", "2", "3"],
            "configuration" => "DELTA",
            "p_nom" => [180_000.0, 60_000.0, 120_000.0],
            "q_nom" => [60_000.0, 20_000.0, 40_000.0],
        )),
        "generator" => Dict("local_delta" => Dict(
            "bus" => "lv",
            "terminal_map" => ["1", "2", "3"],
            "configuration" => "DELTA",
            "p_min" => fill(0.0, 3),
            "p_max" => [30_000.0, 20_000.0, 25_000.0],
            "q_min" => fill(-10_000.0, 3),
            "q_max" => fill(10_000.0, 3),
            "cost" => fill(0.2, 3),
        )),
    )
end

function _derived_policy_factories(
    network;
    s_reference,
    optimizer=Ipopt.Optimizer,
)
    probe = _build_context(
        network, BMOPFTools.ClassicPerUnitScaling(1.0e6);
        add_objective=true,
        optimizer,
    )
    bases = BMOPFTools.opf_bases(probe)
    classic_voltages = Dict(
        string(bus) => Float64(value) for (bus, value) in bases.v_base
    )
    low_voltages = Dict(bus => 0.65value for (bus, value) in classic_voltages)
    high_voltages = Dict(bus => 1.5value for (bus, value) in classic_voltages)
    return [
        ("classic_1mva", () -> BMOPFTools.ClassicPerUnitScaling(1.0e6)),
        ("si_units", () -> BMOPFTools.SIUnitsScaling()),
        (
            "local_0p65v_0p25s",
            () -> BMOPFTools.ConsistentPerUnitScaling(
                name=:local_0p65v_0p25s,
                s_base=0.25s_reference,
                voltage_bases=copy(low_voltages),
            ),
        ),
        (
            "local_1p5v_10s",
            () -> BMOPFTools.ConsistentPerUnitScaling(
                name=:local_1p5v_10s,
                s_base=10.0s_reference,
                voltage_bases=copy(high_voltages),
            ),
        ),
    ]
end

function _safe_perturbed_point(model, point, seed, relative_size)
    rng = MersenneTwister(seed)
    values = copy(Float64.(point.values))
    for (index, variable) in enumerate(point.variables)
        reference = JuMP.VariableRef(model, variable)
        JuMP.is_fixed(reference) && continue
        scale = max(abs(values[index]), 1.0)
        proposed = values[index] + relative_size * scale * randn(rng)
        lower = JuMP.has_lower_bound(reference) ? JuMP.lower_bound(reference) : -Inf
        upper = JuMP.has_upper_bound(reference) ? JuMP.upper_bound(reference) : Inf
        if isfinite(lower) && isfinite(upper) && lower == upper
            values[index] = lower
            continue
        end
        width = upper - lower
        margin = isfinite(width) ? min(0.01width, 1.0e-8 * max(abs(lower), abs(upper), 1.0)) : 0.0
        isfinite(lower) && (proposed = max(proposed, lower + margin))
        isfinite(upper) && (proposed = min(proposed, upper - margin))
        values[index] = proposed
    end
    return NLPDiagnostics.EvaluationPoint(
        point.variables,
        values;
        label="deterministic-physical-start-seed-$seed",
        provenance=NLPDiagnostics.EvaluationPointProvenance(
            NLPDiagnostics.PerturbedPoint;
            source="deterministic bounded perturbation of BMOPFTools completed start",
            complete=true,
            metadata=Dict(
                "seed" => seed,
                "relative_size" => relative_size,
                "base_fingerprint" =>
                    NLPDiagnostics.evaluation_point_fingerprint(point),
            ),
        ),
    )
end

function _campaign_for_stratum(
    network,
    policies,
    case_name,
    stratum_name,
    anchor_context,
    anchor_evaluation,
    environment,
    environment_fingerprint;
    repeats,
    max_iter,
    solver_tolerance,
    endpoint_absolute_tolerance,
    endpoint_relative_tolerance,
    physical_complementarity_tolerance,
    optimizer,
    solver,
    solver_name,
    capture_points,
    trace_geometry,
    trace_geometry_max_points,
    runner_version,
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
            )
            public_record["case"] = case_name
            public_record["start_stratum"] = stratum_name
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
        )
        comparison["case"] = case_name
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
                private_runs[(policy_name, replicate)],
                endpoint_absolute_tolerance=endpoint_absolute_tolerance,
                endpoint_relative_tolerance=endpoint_relative_tolerance,
            )
            comparison["case"] = case_name
            comparison["start_stratum"] = stratum_name
            push!(comparisons, comparison)
        end
    end
    return NLPDiagnostics.scaling_solver_experiment_campaign_data(
        public_runs,
        comparisons;
        reference_policy,
        minimum_repeats=repeats,
        require_native_initialization_covariance=true,
        metadata=Dict(
            "runner_version" => runner_version,
            "case" => case_name,
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
            "environment_fingerprint" => environment_fingerprint,
        ),
    )
end

function _parse_seeds(value)
    isempty(strip(value)) && return Int[]
    seeds = Int[]
    for token in split(value, ',')
        seed = tryparse(Int, strip(token))
        isnothing(seed) && error(
            "NLPDIAGNOSTICS_STRATIFIED_SEEDS must be comma-separated integers",
        )
        push!(seeds, seed)
    end
    length(unique(seeds)) == length(seeds) || error(
        "NLPDIAGNOSTICS_STRATIFIED_SEEDS must not contain duplicates",
    )
    return seeds
end

function _selected_cases(value)
    available = Dict(
        "three_phase" => (
            name="three-phase-unbalanced-line-load-generator",
            builder=_three_phase_objective_fixture,
            s_reference=400_000.0,
        ),
        "transformer" => (
            name="wye-delta-transformer-load-generator",
            builder=_transformer_objective_fixture,
            s_reference=500_000.0,
        ),
    )
    names = filter(!isempty, strip.(split(value, ',')))
    isempty(names) && error("NLPDIAGNOSTICS_STRATIFIED_CASES is empty")
    unknown = setdiff(names, collect(keys(available)))
    isempty(unknown) || error("unknown stratified cases: $(join(unknown, ", "))")
    return [(key=key, available[key]...) for key in names]
end

function run_stratified_campaign(;
    repeats,
    seeds,
    relative_perturbation,
    cases,
    max_iter,
    solver_tolerance,
    endpoint_absolute_tolerance=0.1,
    endpoint_relative_tolerance=2.0e-5,
    physical_complementarity_tolerance=1.0e-4,
    optimizer=Ipopt.Optimizer,
    solver=:ipopt,
    solver_name="Ipopt",
    capture_points=true,
    trace_geometry=true,
    trace_geometry_max_points=8,
    runner_version=_STRATIFIED_RUNNER_VERSION,
)
    environment = _benchmark_environment()
    environment_fingerprint = _benchmark_environment_fingerprint(environment)
    case_records = Dict{String,Any}[]
    for case_spec in cases
        network = case_spec.builder()
        policies = _derived_policy_factories(
            network; s_reference=case_spec.s_reference, optimizer,
        )
        reference_policy = first(policies)[2]()
        anchor_context = _build_context(
            network, reference_policy; add_objective=true, optimizer,
        )
        base_point = NLPDiagnostics.bmopf_start_completion_point(
            anchor_context;
            missing_value=0.0,
            label="$(case_spec.name)-native-start",
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
            campaign = _campaign_for_stratum(
                network,
                policies,
                case_spec.name,
                stratum.name,
                anchor_context,
                anchor_evaluation,
                environment,
                environment_fingerprint;
                repeats,
                max_iter,
                solver_tolerance,
                endpoint_absolute_tolerance,
                endpoint_relative_tolerance,
                physical_complementarity_tolerance,
                optimizer,
                solver,
                solver_name,
                capture_points,
                trace_geometry,
                trace_geometry_max_points,
                runner_version,
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
                "case" => case_spec.name,
                "relative_perturbation" => relative_perturbation,
                "seeds" => seeds,
                "endpoint_absolute_tolerance" => endpoint_absolute_tolerance,
                "endpoint_relative_tolerance" => endpoint_relative_tolerance,
                "physical_complementarity_tolerance" =>
                    physical_complementarity_tolerance,
            ),
        )
        push!(case_records, Dict{String,Any}(
            "case" => case_spec.name,
            "campaign" => stratified,
        ))
    end
    all_cases_qualified = !isempty(case_records) && all(
        get(record["campaign"], "campaign_qualified", false) === true
        for record in case_records
    )
    return Dict{String,Any}(
        "schema_version" => "bmopf-objective-scaling-study-v1",
        "runner_version" => runner_version,
        "available" => true,
        "campaign_qualified" => all_cases_qualified,
        "case_count" => length(case_records),
        "cases" => case_records,
        "environment" => environment,
        "environment_fingerprint" => environment_fingerprint,
        "design" => Dict{String,Any}(
            "objective_bearing" => true,
            "repeats_per_policy_per_stratum" => repeats,
            "native_start_included" => true,
            "perturbed_start_seeds" => seeds,
            "relative_perturbation" => relative_perturbation,
            "endpoint_equivalence_tolerances" => Dict(
                "absolute" => endpoint_absolute_tolerance,
                "relative" => endpoint_relative_tolerance,
            ),
            "physical_complementarity_tolerance" =>
                physical_complementarity_tolerance,
            "physical_start_transport" =>
                "BMOPFTools semantic-block model-to-physical-to-model transport",
            "policy_ranking_performed" => false,
            "solver" => solver_name,
            "trace_point_capture" => capture_points,
            "trace_family_geometry" => trace_geometry,
        ),
        "qualification" => Dict{String,Any}(
            "claim" =>
                "objective-bearing, repeat- and start-stratified matched scaling evidence on the retained compact BMOPF cases",
            "does_not_establish" => [
                "global scaling-policy superiority",
                "behavior on large feeder models",
                "behavior under another nonlinear solver",
            ],
        ),
    )
end

function _compact_trace_evidence_records(stratum_campaign)
    records = Dict{String,Any}[]
    for run_record in get(stratum_campaign, "run_records", Any[])
        artifact = get(run_record, "artifact", Dict())
        geometry = get(artifact, "trace_family_geometry", Dict())
        linear_telemetry = get(
            artifact, "linear_solver_telemetry", Dict(),
        )
        isempty(geometry) && isempty(linear_telemetry) && continue
        push!(records, Dict{String,Any}(
            "policy" => get(run_record, "policy", nothing),
            "replicate" => get(run_record, "replicate", nothing),
            "available" => get(geometry, "available", false),
            "interpretation_qualified" =>
                get(geometry, "interpretation_qualified", false),
            "selected_binding_count" =>
                get(geometry, "selected_binding_count", 0),
            "available_snapshot_count" =>
                get(geometry, "available_snapshot_count", 0),
            "selected_iterations" =>
                get(geometry, "selected_iterations", Any[]),
            "registry_coverage" =>
                get(geometry, "registry_coverage", Dict()),
            "trajectories" => get(geometry, "trajectories", Dict()),
            "linear_solver_telemetry" =>
                linear_telemetry,
        ))
    end
    return records
end

function _compact_stratified_campaign(campaign)
    return Dict{String,Any}(
        "schema_version" => "bmopf-objective-scaling-study-summary-v1",
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
                "strata" => [
                    Dict{String,Any}(
                        "stratum" => stratum["stratum"],
                        "campaign_qualified" =>
                            stratum["campaign"]["campaign_qualified"],
                        "gates" => stratum["campaign"]["gates"],
                        "policies" => stratum["campaign"]["policies"],
                        "comparisons" => stratum["campaign"]["comparisons"],
                        "trace_evidence_records" =>
                            _compact_trace_evidence_records(
                                stratum["campaign"],
                            ),
                        "metadata" => stratum["campaign"]["metadata"],
                    ) for stratum in record["campaign"]["stratum_records"]
                ],
            ) for record in campaign["cases"]
        ],
    )
end

function stratified_main()
    repeats = _env_int("NLPDIAGNOSTICS_STRATIFIED_REPEATS", 5; minimum=2)
    seeds = _parse_seeds(get(ENV, "NLPDIAGNOSTICS_STRATIFIED_SEEDS", "11,29"))
    relative_perturbation = _env_float(
        "NLPDIAGNOSTICS_STRATIFIED_PERTURBATION", 0.01; positive=true,
    )
    cases = _selected_cases(get(
        ENV, "NLPDIAGNOSTICS_STRATIFIED_CASES", "three_phase,transformer",
    ))
    max_iter = _env_int("NLPDIAGNOSTICS_STRATIFIED_MAX_ITER", 150; minimum=1)
    solver_tolerance = _env_float(
        "NLPDIAGNOSTICS_STRATIFIED_TOL", 1.0e-8; positive=true,
    )
    output = abspath(get(
        ENV,
        "NLPDIAGNOSTICS_STRATIFIED_OUTPUT",
        joinpath(@__DIR__, "..", "work", "bmopf-stratified-scaling-campaign.json"),
    ))
    campaign = run_stratified_campaign(;
        repeats,
        seeds,
        relative_perturbation,
        cases,
        max_iter,
        solver_tolerance,
    )
    mkpath(dirname(output))
    write(output, JSON.json(_json_safe(campaign)))
    stem, extension = splitext(output)
    summary_output = stem * "-summary" * extension
    write(
        summary_output,
        JSON.json(_json_safe(_compact_stratified_campaign(campaign))),
    )
    println("wrote objective-bearing stratified campaign to $output")
    println("wrote compact campaign summary to $summary_output")
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
    stratified_main()
end
