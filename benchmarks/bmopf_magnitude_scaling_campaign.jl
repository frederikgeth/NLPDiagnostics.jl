#!/usr/bin/env julia

"""Run a repeated, matched magnitude-only BMOPF scaling experiment.

This first campaign intentionally uses the small line/load truth fixture. Every
fresh model receives the same physical initial state through the authoritative
BMOPFTools semantic-block transport. The output retains intervention,
common-start covariance, endpoint covariance, semantic geometry, native solver
work, and physical KKT evidence without ranking policies.

Environment controls:

  * `NLPDIAGNOSTICS_SCALING_REPEATS` (default `2`, minimum `2`)
  * `NLPDIAGNOSTICS_SCALING_OUTPUT` (default under `work/`)
  * `NLPDIAGNOSTICS_SCALING_MAX_ITER` (default `100`)
  * `NLPDIAGNOSTICS_SCALING_TOL` (default `1e-8`)
"""

using NLPDiagnostics
using BMOPFTools
using JuMP
using Ipopt
using JSON
import MathOptInterface as MOI

include(joinpath(@__DIR__, "benchmark_environment.jl"))

const _RUNNER_VERSION = "bmopf-magnitude-scaling-campaign-v1"

function _env_int(name, default; minimum=0)
    value = tryparse(Int, strip(get(ENV, name, string(default))))
    isnothing(value) && error("$name must be an integer")
    value >= minimum || error("$name must be at least $minimum")
    return value
end

function _env_float(name, default; positive=false)
    value = tryparse(Float64, strip(get(ENV, name, string(default))))
    isnothing(value) && error("$name must be numeric")
    isfinite(value) || error("$name must be finite")
    positive && value <= 0 && error("$name must be positive")
    return value
end

function _json_safe(value)
    value isa AbstractFloat && !isfinite(value) && return nothing
    value isa AbstractDict && return Dict(
        string(key) => _json_safe(item) for (key, item) in value
    )
    value isa NamedTuple && return Dict(
        string(key) => _json_safe(getfield(value, key)) for key in keys(value)
    )
    value isa Tuple && return [_json_safe(item) for item in value]
    value isa AbstractArray && return [_json_safe(item) for item in value]
    return value
end

function _truth_fixture()
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

function _policy_factories()
    voltage_bases = Dict("source" => 500.0, "loadbus" => 500.0)
    high_voltage_bases = Dict("source" => 1500.0, "loadbus" => 1500.0)
    return [
        ("classic_1mva", () -> BMOPFTools.OpfScaling(:classic; power_base=1.0e6)),
        ("si_units", () -> BMOPFTools.OpfScaling(:si)),
        (
            "local_500v_200kva",
            () -> BMOPFTools.OpfScaling(
                name=:local_500v_200kva,
                power_base=2.0e5,
                voltage_bases=copy(voltage_bases),
            ),
        ),
        (
            "local_1500v_5mva",
            () -> BMOPFTools.OpfScaling(
                name=:local_1500v_5mva,
                power_base=5.0e6,
                voltage_bases=copy(high_voltage_bases),
            ),
        ),
    ]
end

function _build_context(
    network,
    policy;
    add_objective=false,
    optimizer=Ipopt.Optimizer,
)
    context = BMOPFTools.build_opf_model(
        deepcopy(network);
        optimizer,
        scaling_policy=policy,
        add_objective,
    )
    BMOPFTools.enforce_kcl!(context)
    return context
end

function _schema_evaluation(context, label)
    point = NLPDiagnostics.bmopf_start_completion_point(
        context; missing_value=0.0, label,
    )
    return NLPDiagnostics.evaluate_numerical(
        JuMP.backend(BMOPFTools.opf_model(context)), point,
    )
end

function _apply_start!(model, point)
    backend = JuMP.backend(model)
    for (variable, value) in zip(point.variables, point.values)
        MOI.set(backend, MOI.VariablePrimalStart(), variable, Float64(value))
    end
    return model
end

function _quantity_tolerances(context, evaluation)
    map_build = NLPDiagnostics.bmopf_diagonal_scaling_map(context, evaluation)
    get(map_build, "available", false) === true || return Dict{String,Float64}()
    return Dict{String,Float64}(
        string(quantity) => 1.0 for quantity in
        unique(map_build["constraint_quantities"])
    )
end

function _run_policy(
    network,
    policy_name,
    policy,
    replicate,
    anchor_context,
    anchor_evaluation,
    environment_fingerprint;
    max_iter,
    solver_tolerance,
    add_objective=false,
    physical_complementarity_tolerance=1.0e-5,
    capture_points=false,
    trace_geometry=false,
    trace_geometry_max_points=8,
    optimizer=Ipopt.Optimizer,
    solver=:ipopt,
    require_canonical_voltage_pattern=true,
    require_phasor_transport=false,
    complete_fixed_variable_duals=false,
    max_dense_entries=100_000,
)
    trace_geometry && !capture_points && throw(ArgumentError(
        "trace_geometry=true requires capture_points=true",
    ))
    solver in (:ipopt, :madnlp) || throw(ArgumentError(
        "solver must be :ipopt or :madnlp",
    ))
    solver == :madnlp && capture_points && throw(ArgumentError(
        "MadNLP's public callback does not expose primal iterate coordinates",
    ))
    context = _build_context(network, policy; add_objective, optimizer)
    schema = _schema_evaluation(
        context, "$policy_name-replicate-$replicate-schema",
    )
    native_initialization_covariance =
        NLPDiagnostics.bmopf_initialization_scaling_covariance_report(
            anchor_context,
            context;
            missing_value=0.0,
            require_canonical_voltage_pattern,
            require_phasor_transport,
            absolute_tolerance=1.0e-6,
            relative_tolerance=1.0e-8,
            max_dense_entries,
        )
    transport = NLPDiagnostics.bmopf_transport_scaling_point(
        anchor_context,
        anchor_evaluation,
        context,
        schema;
        label="$policy_name-replicate-$replicate-common-start",
    )
    get(transport, "available", false) === true || error(
        "common-start transport is unavailable for $policy_name replicate $replicate",
    )
    initial_evaluation = NLPDiagnostics.evaluate_numerical(
        JuMP.backend(BMOPFTools.opf_model(context)),
        transport["transport"].point,
    )
    common_start_covariance =
        NLPDiagnostics.bmopf_block_scaling_covariance_report(
            anchor_context,
            anchor_evaluation,
            context,
            initial_evaluation;
            absolute_tolerance=1.0e-6,
            relative_tolerance=1.0e-8,
            max_dense_entries,
        )
    model = BMOPFTools.opf_model(context)
    _apply_start!(model, transport["transport"].point)
    JuMP.set_silent(model)
    JuMP.set_optimizer_attribute(model, "max_iter", max_iter)
    JuMP.set_optimizer_attribute(model, "tol", solver_tolerance)
    timed = if solver == :ipopt
        @timed NLPDiagnostics.ipopt_profile_with_iteration_trace!(
            model; capture_points,
        )
    else
        @timed NLPDiagnostics.madnlp_profile_with_iteration_trace!(model)
    end
    run = timed.value
    endpoint_point = NLPDiagnostics.solver_result_point(
        model; label="$policy_name-replicate-$replicate-endpoint",
    )
    isnothing(endpoint_point) && error(
        "solver result point is unavailable for $policy_name replicate $replicate",
    )
    endpoint_evaluation = NLPDiagnostics.evaluate_numerical(
        JuMP.backend(model), endpoint_point,
    )
    quantity_tolerances = _quantity_tolerances(context, endpoint_evaluation)
    artifact = NLPDiagnostics.bmopf_solver_trace_physical_endpoint_data(
        context,
        model,
        run;
        semantic_blocks=false,
        quantity_feasibility_absolute_tolerances=quantity_tolerances,
        stationarity_default_absolute_tolerance=1.0e-5,
        dual_default_absolute_tolerance=1.0e-5,
        complementarity_default_absolute_tolerance=
            physical_complementarity_tolerance,
        complete_fixed_variable_duals,
    )
    if trace_geometry
        artifact["trace_family_geometry"] =
            NLPDiagnostics.bmopf_iteration_trace_jacobian_family_geometry_data(
                context,
                run.trace;
                max_points=trace_geometry_max_points,
            )
    end
    public_record = Dict{String,Any}(
        "policy" => policy_name,
        "replicate" => replicate,
        "provenance_fingerprint" => environment_fingerprint,
        "common_start_covariance_passed" =>
            get(common_start_covariance, "equivalence_gate_passed", false),
        "native_initialization_covariance_passed" => get(
            native_initialization_covariance,
            "equivalence_gate_passed",
            false,
        ),
        "native_initialization_covariance_report" =>
            native_initialization_covariance,
        "common_start_transport" => Dict{String,Any}(
            "maximum_roundtrip_error" => transport["maximum_roundtrip_error"],
            "point_fingerprint" => NLPDiagnostics.evaluation_point_fingerprint(
                transport["transport"].point,
            ),
        ),
        "common_start_covariance_report" => common_start_covariance,
        "solve_seconds" => timed.time,
        "solve_allocations" => timed.bytes,
        "termination_status" => string(JuMP.termination_status(model)),
        "primal_status" => string(JuMP.primal_status(model)),
        "artifact" => artifact,
    )
    private_record = (
        context=context,
        initial_evaluation=initial_evaluation,
        endpoint_evaluation=endpoint_evaluation,
        artifact=artifact,
    )
    return public_record, private_record
end

function _matched_comparison(
    reference_policy,
    reference_replicate,
    reference,
    candidate_policy,
    candidate_replicate,
    candidate;
    baseline_repeat=false,
    endpoint_absolute_tolerance=1.0e-5,
    endpoint_relative_tolerance=1.0e-7,
    max_dense_entries=100_000,
)
    raw_endpoint_covariance =
        NLPDiagnostics.bmopf_block_scaling_covariance_report(
            reference.context,
            reference.endpoint_evaluation,
            candidate.context,
            candidate.endpoint_evaluation;
            absolute_tolerance=endpoint_absolute_tolerance,
            relative_tolerance=endpoint_relative_tolerance,
            max_dense_entries,
        )
    endpoint_covariance = NLPDiagnostics.physical_endpoint_equivalence_report(
        raw_endpoint_covariance,
        reference.artifact["physical_endpoint"],
        candidate.artifact["physical_endpoint"],
    )
    geometry = NLPDiagnostics.bmopf_block_scaling_coordinate_geometry_report(
        reference.context,
        reference.initial_evaluation,
        candidate.context,
        candidate.initial_evaluation;
        absolute_tolerance=1.0e-6,
        relative_tolerance=1.0e-8,
        max_dense_entries,
    )
    intervention = NLPDiagnostics.bmopf_scaling_intervention_classification(
        reference.context,
        reference.initial_evaluation,
        candidate.context,
        candidate.initial_evaluation,
    )
    comparison = NLPDiagnostics.bmopf_scaling_solver_experiment_comparison(
        reference.artifact,
        candidate.artifact;
        intervention=baseline_repeat ? :baseline_repeat : :magnitude_only,
        intervention_report=intervention,
        covariance_report=endpoint_covariance,
        geometry_report=geometry,
        hypothesis=baseline_repeat ?
            "fresh identical-policy runs should be repeatable" :
            "a magnitude-only coordinate policy may change solver work while preserving the physical endpoint contract",
        metadata=Dict(
            "reference_policy" => reference_policy,
            "reference_replicate" => reference_replicate,
            "candidate_policy" => candidate_policy,
            "candidate_replicate" => candidate_replicate,
            "geometry_point" => "transported common physical start",
            "covariance_point" => "independently solved physical endpoints",
        ),
    )
    return Dict{String,Any}(
        "reference_policy" => reference_policy,
        "reference_replicate" => reference_replicate,
        "candidate_policy" => candidate_policy,
        "candidate_replicate" => candidate_replicate,
        "comparison" => comparison,
    )
end

function run_campaign(; repeats, max_iter, solver_tolerance)
    network = _truth_fixture()
    policies = _policy_factories()
    reference_policy = first(policies)[1]
    anchor_context = _build_context(network, first(policies)[2]())
    anchor_evaluation = _schema_evaluation(
        anchor_context, "magnitude-campaign-anchor",
    )
    environment = _benchmark_environment()
    environment_fingerprint = _benchmark_environment_fingerprint(environment)
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
            )
            push!(public_runs, public_record)
            private_runs[(policy_name, replicate)] = private_record
        end
    end
    comparisons = Dict{String,Any}[]
    reference_first = private_runs[(reference_policy, 1)]
    for replicate in 2:repeats
        push!(comparisons, _matched_comparison(
            reference_policy,
            1,
            reference_first,
            reference_policy,
            replicate,
            private_runs[(reference_policy, replicate)];
            baseline_repeat=true,
        ))
    end
    for (policy_name, _) in policies[2:end]
        for replicate in 1:repeats
            push!(comparisons, _matched_comparison(
                reference_policy,
                replicate,
                private_runs[(reference_policy, replicate)],
                policy_name,
                replicate,
                private_runs[(policy_name, replicate)],
            ))
        end
    end
    campaign = NLPDiagnostics.scaling_solver_experiment_campaign_data(
        public_runs,
        comparisons;
        reference_policy,
        minimum_repeats=repeats,
        metadata=Dict(
            "runner_version" => _RUNNER_VERSION,
            "case" => "single-phase-line-load-truth-fixture",
            "solver" => "Ipopt",
            "common_start_policy" => reference_policy,
            "max_iter" => max_iter,
            "solver_tolerance" => solver_tolerance,
        ),
    )
    altered_runs = deepcopy(public_runs)
    altered_runs[end]["provenance_fingerprint"] =
        "intentional-negative-control"
    provenance_negative =
        NLPDiagnostics.scaling_solver_experiment_campaign_data(
            altered_runs,
            comparisons;
            reference_policy,
            minimum_repeats=repeats,
        )
    missing_intervention =
        NLPDiagnostics.bmopf_scaling_solver_experiment_comparison(
            reference_first.artifact,
            reference_first.artifact;
            intervention=:baseline_repeat,
            covariance_report=Dict("equivalence_gate_passed" => true),
            geometry_report=Dict(
                "semantic_interpretation_qualified" => true,
            ),
        )
    campaign["negative_controls"] = Dict{String,Any}(
        "provenance_mismatch_rejected" =>
            get(provenance_negative, "campaign_qualified", true) === false,
        "missing_intervention_report_rejected" =>
            get(missing_intervention, "comparison_qualified", true) === false,
    )
    campaign["environment"] = environment
    campaign["environment_fingerprint"] = environment_fingerprint
    return campaign
end

function main()
    repeats = _env_int("NLPDIAGNOSTICS_SCALING_REPEATS", 2; minimum=2)
    max_iter = _env_int("NLPDIAGNOSTICS_SCALING_MAX_ITER", 100; minimum=1)
    solver_tolerance = _env_float(
        "NLPDIAGNOSTICS_SCALING_TOL", 1.0e-8; positive=true,
    )
    output = abspath(get(
        ENV,
        "NLPDIAGNOSTICS_SCALING_OUTPUT",
        joinpath(
            @__DIR__, "..", "work", "bmopf-magnitude-scaling-campaign.json",
        ),
    ))
    mkpath(dirname(output))
    campaign = run_campaign(; repeats, max_iter, solver_tolerance)
    write(output, JSON.json(_json_safe(campaign)))
    println("wrote matched magnitude-only campaign to $output")
    campaign_qualified = campaign["campaign_qualified"]
    println("campaign_qualified=$campaign_qualified")
    for (policy, summary) in sort!(collect(campaign["policies"]); by=first)
        range = summary["record_count_range"]
        endpoint_passed = summary["all_physical_endpoints_accepted"]
        minimum_iterations = get(range, "minimum", nothing)
        maximum_iterations = get(range, "maximum", nothing)
        println(
            "$policy: endpoint_pass=$endpoint_passed " *
            "iterations=$minimum_iterations..$maximum_iterations",
        )
    end
end

if abspath(PROGRAM_FILE) == abspath(@__FILE__)
    main()
end
