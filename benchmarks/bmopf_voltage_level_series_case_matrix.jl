#!/usr/bin/env julia

"""Build a bounded BMOPFTools voltage-level/series-transformer case matrix.

The cases are synthetic, solver-free readiness fixtures for numerical scaling
experiments.  They deliberately vary the number of voltage levels and series
transformer interfaces while preserving a simple single-phase physical
topology.  A later solver campaign can select the largest cases that fit its
explicit time and memory budget.
"""

using NLPDiagnostics
using BMOPFTools
using JuMP
using Ipopt
import MathOptInterface as MOI

include(joinpath(@__DIR__, "benchmark_environment.jl"))
include(joinpath(@__DIR__, "common.jl"))
using .NLPDiagnosticsBenchmarkCommon: write_json

const _RUNNER_VERSION = "bmopf-voltage-level-series-case-matrix-v1"

function _json_safe(value)
    value isa AbstractFloat && !isfinite(value) && return nothing
    value isa AbstractDict && return Dict(string(key) => _json_safe(item) for (key, item) in value)
    value isa NamedTuple && return Dict(string(key) => _json_safe(getfield(value, key)) for key in keys(value))
    value isa Tuple && return [_json_safe(item) for item in value]
    value isa AbstractArray && return [_json_safe(item) for item in value]
    return value
end

function _series_case(label, voltage_levels; loads_per_level)
    bus = Dict{String,Any}()
    for index in eachindex(voltage_levels)
        bus["$(label)_bus_$(index)"] = Dict{String,Any}(
            "terminal_names" => ["1", "n"],
            "perfectly_grounded_terminals" => ["n"],
        )
    end

    source_bus = "$(label)_bus_1"
    source_voltage = Float64(first(voltage_levels))
    network = Dict{String,Any}(
        "bus" => bus,
        "voltage_source" => Dict("source" => Dict(
            "bus" => source_bus,
            "terminal_map" => ["1"],
            "v_magnitude" => [source_voltage],
            "v_angle" => [0.0],
        )),
        "transformer" => Dict("single_phase" => Dict{String,Any}()),
        "load" => Dict{String,Any}(),
    )

    for index in 1:(length(voltage_levels) - 1)
        from_voltage = Float64(voltage_levels[index])
        to_voltage = Float64(voltage_levels[index + 1])
        rating = max(2.0e6, 10.0e3 * loads_per_level * (length(voltage_levels) - index + 1))
        z_from = from_voltage^2 / rating
        z_to = to_voltage^2 / rating
        network["transformer"]["single_phase"]["$(label)_t_$(index)"] = Dict(
            "bus_from" => "$(label)_bus_$(index)",
            "bus_to" => "$(label)_bus_$(index + 1)",
            "terminal_map_from" => ["1", "n"],
            "terminal_map_to" => ["1", "n"],
            "v_nom_from" => from_voltage,
            "v_nom_to" => to_voltage,
            "s_rating" => rating,
            "r_series_from" => 0.01 * z_from,
            "r_series_to" => 0.01 * z_to,
            "x_series_from" => 0.04 * z_from,
            "x_series_to" => 0.04 * z_to,
        )
    end

    for index in 2:length(voltage_levels)
        bus_name = "$(label)_bus_$(index)"
        voltage = Float64(voltage_levels[index])
        for load_index in 1:loads_per_level
            scale = 1.0 + 0.05 * (index - 2) + 0.02 * (load_index - 1)
            network["load"]["$(label)_load_$(index)_$(load_index)"] = Dict(
                "bus" => bus_name,
                "terminal_map" => ["1", "n"],
                "configuration" => "WYE",
                "p_nom" => [2.0e3 * scale * max(voltage / 240.0, 1.0)],
                "q_nom" => [0.7e3 * scale * max(voltage / 240.0, 1.0)],
            )
        end
    end
    return network
end

function _policy_case(network, label)
    classic_context = BMOPFTools.build_opf_model(
        deepcopy(network);
        optimizer = Ipopt.Optimizer,
        scaling_policy = BMOPFTools.OpfScaling(:classic; power_base = 1.0e6),
        add_objective = false,
    )
    BMOPFTools.enforce_kcl!(classic_context)
    classic_model = BMOPFTools.opf_model(classic_context)
    classic_point = NLPDiagnostics.bmopf_start_completion_point(
        classic_context; missing_value = 0.0, label = "$label-classic",
    )
    classic_eval = NLPDiagnostics.evaluate_numerical(JuMP.backend(classic_model), classic_point)
    classic_bases = BMOPFTools.opf_bases(classic_context)
    voltage_bases = Dict(String(bus) => Float64(value) for (bus, value) in classic_bases.v_base)
    power_bases = Dict(bus => (value > 1_000.0 ? 1.0e6 : 1.0e5)
                       for (bus, value) in voltage_bases)
    local_context = BMOPFTools.build_opf_model(
        deepcopy(network);
        optimizer = Ipopt.Optimizer,
        scaling_policy = BMOPFTools.OpfScaling(
            name = :series_voltage_local,
            voltage_bases = voltage_bases,
            power_bases = power_bases,
        ),
        add_objective = false,
    )
    BMOPFTools.enforce_kcl!(local_context)
    local_model = BMOPFTools.opf_model(local_context)
    local_point = NLPDiagnostics.bmopf_start_completion_point(
        local_context; missing_value = 0.0, label = "$label-local",
    )
    local_eval = NLPDiagnostics.evaluate_numerical(JuMP.backend(local_model), local_point)
    covariance = NLPDiagnostics.bmopf_block_scaling_covariance_report(
        classic_context,
        classic_eval,
        local_context,
        local_eval;
        absolute_tolerance = 1.0e-6,
        relative_tolerance = 1.0e-8,
        max_dense_entries = 0,
    )
    geometry = NLPDiagnostics.bmopf_block_scaling_coordinate_geometry_report(
        classic_context,
        classic_eval,
        local_context,
        local_eval;
        absolute_tolerance = 1.0e-6,
        relative_tolerance = 1.0e-8,
        max_dense_entries = 0,
    )
    contract = BMOPFTools.opf_transformer_scaling_contract_data(classic_context)
    return Dict{String,Any}(
        "label" => label,
        "bus_count" => length(network["bus"]),
        "transformer_count" => length(network["transformer"]["single_phase"]),
        "load_count" => length(network["load"]),
        "model_variable_count" => length(MOI.get(JuMP.backend(classic_model), MOI.ListOfVariableIndices())),
        "voltage_base_values" => sort!(unique(Float64.(collect(values(classic_bases.v_base))))),
        "transformer_interface_count" => length(get(contract, "interfaces", Any[])),
        "covariance" => Dict(
            "available" => get(covariance, "available", false),
            "equivalence_gate_passed" => get(covariance, "equivalence_gate_passed", false),
            "semantic_alignment" => get(covariance, "semantic_alignment", false),
        ),
        "geometry" => Dict(
            "available" => get(geometry, "available", false),
            # `bmopf_block_scaling_coordinate_geometry_report` uses the
            # shared comparison contract name for its qualification gate.
            # Keep the benchmark's domain-specific alias in the artifact, but
            # read the authoritative field rather than silently defaulting to
            # false when the report is available.
            "geometry_gate_passed" => get(geometry, "comparison_qualified", false),
        ),
    )
end

function main()
    cases = [
        ("series_4level_115kV_480V", [115_000.0, 24_900.0, 4_160.0, 480.0], 2),
        ("series_6level_115kV_240V", [115_000.0, 34_500.0, 24_900.0, 12_470.0, 4_160.0, 240.0], 2),
        ("series_8level_230kV_208V", [230_000.0, 69_000.0, 34_500.0, 24_900.0, 12_470.0, 4_160.0, 480.0, 208.0], 3),
    ]
    records = Dict{String,Any}[]
    for (label, voltage_levels, loads_per_level) in cases
        push!(records, merge(
            Dict{String,Any}(
                "voltage_levels" => voltage_levels,
                "loads_per_level" => loads_per_level,
            ),
            _policy_case(_series_case(label, voltage_levels; loads_per_level), label),
        ))
    end
    output = abspath(get(
        ENV,
        "NLPDIAGNOSTICS_BMOPF_SERIES_CASE_MATRIX_OUTPUT",
        joinpath(@__DIR__, "..", "docs", "bmopf_voltage_level_series_case_matrix_summary.json"),
    ))
    mkpath(dirname(output))
    write_json(output, _json_safe(Dict{String,Any}(
        "schema_version" => "nlpdiagnostics-bmopf-voltage-level-series-case-matrix-v1",
        "runner" => "benchmarks/bmopf_voltage_level_series_case_matrix.jl",
        "runner_version" => _RUNNER_VERSION,
        "status" => all(record["covariance"]["equivalence_gate_passed"] for record in records) ?
            "structural_scaling_matrix_complete" : "structural_scaling_matrix_partial",
        "case_count" => length(records),
        "covariance_gate_passed_count" => count(record -> record["covariance"]["equivalence_gate_passed"], records),
        "geometry_gate_passed_count" => count(record -> record["geometry"]["geometry_gate_passed"], records),
        "records" => records,
        "qualification" => Dict(
            "claim" => "synthetic BMOPFTools scaling-coordinate readiness across voltage-level ladders with series transformers",
            "solver_work_claim_supported" => false,
            "next_experiment" => "tune the largest ladder's initialization/model formulation, then run matched-start Ipopt/MadNLP campaigns under explicit budgets",
            "does_not_establish" => [
                "solver superiority or a universal voltage-base policy",
                "causal convergence or conditioning mechanism",
                "physical KKT acceptance for these synthetic cases",
            ],
        ),
    )))
    println("wrote BMOPFTools voltage-level series case matrix to $output")
end

if abspath(PROGRAM_FILE) == abspath(@__FILE__)
    main()
end
