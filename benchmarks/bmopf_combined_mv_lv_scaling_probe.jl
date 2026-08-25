#!/usr/bin/env julia

"""Probe BMOPFTools scaling strategies on the combined MV+LV case.

This is deliberately a non-solving, sparse readiness experiment. It builds the
SI, classic single-base, and two-level MV/LV local-base coordinates, evaluates
the same BMOPFTools-generated physical start, and records covariance, semantic
intervention, and coordinate-geometry gates. Solver-work claims require a
separate bounded campaign after these gates pass.

The default input is BMOPFTools' combined case at
`test/data/Master.dss`. Override it with `NLPDIAGNOSTICS_COMBINED_MV_LV_DSS`.
"""

using NLPDiagnostics
using BMOPFTools
using JuMP
using Ipopt

include(joinpath(@__DIR__, "benchmark_environment.jl"))
include(joinpath(@__DIR__, "common.jl"))
using .NLPDiagnosticsBenchmarkCommon: write_json

const _RUNNER_VERSION = "bmopf-combined-mv-lv-scaling-probe-v1"

function _network_path()
    override = strip(get(ENV, "NLPDIAGNOSTICS_COMBINED_MV_LV_DSS", ""))
    return isempty(override) ?
        joinpath(pkgdir(BMOPFTools), "test", "data", "Master.dss") :
        abspath(override)
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

function _warning_codes(warnings)
    codes = Set{String}()
    for warning in warnings
        if warning isa AbstractDict
            push!(codes, string(get(warning, "code", "unknown")))
        elseif warning isa AbstractString
            match_result = match(r"^([A-Z0-9_.-]+):", String(warning))
            push!(codes, isnothing(match_result) ? "unknown" : String(match_result.captures[1]))
        end
    end
    return sort!(collect(codes))
end

function _build_case(network, policy, label)
    context = BMOPFTools.build_opf_model(
        deepcopy(network);
        optimizer = Ipopt.Optimizer,
        scaling_policy = policy,
        add_objective = false,
    )
    BMOPFTools.enforce_kcl!(context)
    point = NLPDiagnostics.bmopf_start_completion_point(
        context; missing_value = 0.0, label,
    )
    evaluation = NLPDiagnostics.evaluate_numerical(
        JuMP.backend(BMOPFTools.opf_model(context)), point,
    )
    bases = BMOPFTools.opf_bases(context)
    return (; context, evaluation, bases, point, policy)
end

function _policy_data(policy, bases)
    policy_data = BMOPFTools.opf_scaling_policy_data(policy)
    return Dict{String,Any}(
        "policy" => policy_data,
        "variable_count" => length(bases.v_base),
        "voltage_base_count" => length(bases.v_base),
        "voltage_base_values" => sort!(unique(round.(collect(values(bases.v_base)); digits = 4))),
        "power_base_values" => sort!(unique(collect(values(bases.s_base_bus)))),
        "mv_bus_count" => count(value -> value > 1_000.0, values(bases.v_base)),
        "lv_bus_count" => count(value -> value <= 1_000.0, values(bases.v_base)),
    )
end

function _gate_data(report)
    report isa AbstractDict || return Dict{String,Any}(
        "available" => false,
        "equivalence_gate_passed" => nothing,
    )
    return Dict{String,Any}(
        "available" => get(report, "available", nothing),
        "equivalence_gate_passed" => get(report, "equivalence_gate_passed", nothing),
        "semantic_interpretation_qualified" => get(report, "semantic_interpretation_qualified", nothing),
        "intervention_class" => get(report, "intervention_class", nothing),
        "geometry_gate_passed" => get(report, "geometry_gate_passed", nothing),
        "registry_coverage" => get(report, "registry_coverage", nothing),
    )
end

function main()
    input_path = _network_path()
    isfile(input_path) || error("combined MV/LV DSS case is missing: $input_path")
    println("reading combined MV/LV source: $input_path"); flush(stdout)
    network = BMOPFTools.from_dss(input_path)
    println("source read; building classic coordinates"); flush(stdout)
    source_meta = get(network, "_meta", Dict{String,Any}())
    warnings = get(source_meta, "powerio_warnings", Any[])

    classic = _build_case(
        network,
        BMOPFTools.OpfScaling(:classic; power_base = 1.0e6),
        "combined-mv-lv-classic-start",
    )
    println("classic built; building local MV/LV coordinates"); flush(stdout)
    classic_bases = classic.bases
    voltage_bases = Dict(String(bus) => Float64(value)
                         for (bus, value) in classic_bases.v_base)
    power_bases = Dict(
        bus => (value > 1_000.0 ? 1.0e6 : 1.0e5)
        for (bus, value) in voltage_bases
    )
    local_case = _build_case(
        network,
        BMOPFTools.OpfScaling(
            name = :combined_mv_lv_local,
            voltage_bases = voltage_bases,
            power_bases = power_bases,
        ),
        "combined-mv-lv-local-start",
    )
    println("local MV/LV built; building SI coordinates"); flush(stdout)
    si = _build_case(
        network,
        BMOPFTools.OpfScaling(:si),
        "combined-mv-lv-si-start",
    )
    println("SI built; evaluating sparse comparison gates"); flush(stdout)

    policies = Dict{String,Any}(
        "classic" => _policy_data(classic.policy, classic.bases),
        "combined_mv_lv_local" => _policy_data(local_case.policy, local_case.bases),
        "si" => _policy_data(si.policy, si.bases),
    )
    comparisons = Dict{String,Any}[]
    for (name, candidate) in (("combined_mv_lv_local", local_case), ("si", si))
        covariance = NLPDiagnostics.bmopf_block_scaling_covariance_report(
            classic.context,
            classic.evaluation,
            candidate.context,
            candidate.evaluation;
            absolute_tolerance = 1.0e-6,
            relative_tolerance = 1.0e-8,
            max_dense_entries = 0,
        )
        intervention = NLPDiagnostics.bmopf_scaling_intervention_classification(
            classic.context,
            classic.evaluation,
            candidate.context,
            candidate.evaluation;
            max_dense_entries = 0,
        )
        geometry = NLPDiagnostics.bmopf_block_scaling_coordinate_geometry_report(
            classic.context,
            classic.evaluation,
            candidate.context,
            candidate.evaluation;
            absolute_tolerance = 1.0e-6,
            relative_tolerance = 1.0e-8,
            max_dense_entries = 0,
        )
        push!(comparisons, Dict{String,Any}(
            "candidate_policy" => name,
            "covariance" => _gate_data(covariance),
            "intervention" => _gate_data(intervention),
            "geometry" => _gate_data(geometry),
        ))
    end

    output = abspath(get(
        ENV,
        "NLPDIAGNOSTICS_COMBINED_MV_LV_SCALING_OUTPUT",
        joinpath(@__DIR__, "..", "work", "bmopf-combined-mv-lv-scaling-probe.json"),
    ))
    mkpath(dirname(output))
    payload = Dict{String,Any}(
        "schema_version" => "nlpdiagnostics-bmopf-combined-mv-lv-scaling-probe-v1",
        "status" => "structural_scaling_readiness",
        "runner_version" => _RUNNER_VERSION,
        "input" => Dict(
            "path" => input_path,
            "source_warning_count" => length(warnings),
            "source_warning_codes" => _warning_codes(warnings),
        ),
        "network_shape" => Dict(
            "bus_count" => length(get(network, "bus", Dict())),
            "line_count" => length(get(network, "line", Dict())),
            "load_count" => length(get(network, "load", Dict())),
            "transformer_interface_count" => length(
                get(BMOPFTools.opf_transformer_scaling_contract_data(classic.context), "interfaces", Any[]),
            ),
        ),
        "policies" => policies,
        "comparisons" => comparisons,
        "qualification" => Dict(
            "claim" => "sparse BMOPFTools scaling-coordinate readiness and physical covariance",
            "solver_work_claim_supported" => false,
            "next_experiment" => "bounded Ipopt/MadNLP solve campaign after these sparse gates pass",
            "does_not_establish" => [
                "solver superiority or a universal base policy",
                "causal convergence or conditioning mechanism",
                "absolute physical KKT acceptance",
            ],
        ),
    )
    write_json(output, _json_safe(payload))
    println("wrote combined MV/LV scaling probe to $output")
end

if abspath(PROGRAM_FILE) == abspath(@__FILE__)
    main()
end
