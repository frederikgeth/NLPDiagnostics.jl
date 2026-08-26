#!/usr/bin/env julia

"""Run a bounded practical solver campaign on series-transformer ladders.

The campaign reuses the matched-start, endpoint, and comparison contracts from
the established BMOPF scaling campaign while varying voltage levels and the
number of series transformer interfaces.  The default artifact is the
established Ipopt campaign; a companion runner selects the same path with
MadNLP when that solver is available.
"""

using NLPDiagnostics
using BMOPFTools
using JuMP
using Ipopt
import MathOptInterface as MOI

include(joinpath(@__DIR__, "bmopf_magnitude_scaling_campaign.jl"))

const _SERIES_SOLVER_RUNNER_VERSION = "bmopf-voltage-level-series-solver-campaign-v1"

function _series_case(
    label,
    voltage_levels;
    loads_per_level,
    load_multiplier = 1.0,
    rating_multiplier = 1.0,
)
    bus = Dict{String,Any}()
    for index in eachindex(voltage_levels)
        bus["$(label)_bus_$(index)"] = Dict{String,Any}(
            "terminal_names" => ["1", "n"],
            "perfectly_grounded_terminals" => ["n"],
        )
    end
    network = Dict{String,Any}(
        "bus" => bus,
        "voltage_source" => Dict("source" => Dict(
            "bus" => "$(label)_bus_1", "terminal_map" => ["1"],
            "v_magnitude" => [Float64(first(voltage_levels))], "v_angle" => [0.0],
        )),
        "transformer" => Dict("single_phase" => Dict{String,Any}()),
        "load" => Dict{String,Any}(),
    )
    for index in 1:(length(voltage_levels) - 1)
        from_voltage, to_voltage = Float64(voltage_levels[index]), Float64(voltage_levels[index + 1])
        rating = rating_multiplier * max(
            2.0e6,
            10.0e3 * loads_per_level * (length(voltage_levels) - index + 1),
        )
        z_from, z_to = from_voltage^2 / rating, to_voltage^2 / rating
        network["transformer"]["single_phase"]["$(label)_t_$(index)"] = Dict(
            "bus_from" => "$(label)_bus_$(index)", "bus_to" => "$(label)_bus_$(index + 1)",
            "terminal_map_from" => ["1", "n"], "terminal_map_to" => ["1", "n"],
            "v_nom_from" => from_voltage, "v_nom_to" => to_voltage, "s_rating" => rating,
            "r_series_from" => 0.01z_from, "r_series_to" => 0.01z_to,
            "x_series_from" => 0.04z_from, "x_series_to" => 0.04z_to,
        )
    end
    for index in 2:length(voltage_levels), load_index in 1:loads_per_level
        voltage = Float64(voltage_levels[index])
        scale = 1.0 + 0.05 * (index - 2) + 0.02 * (load_index - 1)
        network["load"]["$(label)_load_$(index)_$(load_index)"] = Dict(
            "bus" => "$(label)_bus_$(index)", "terminal_map" => ["1", "n"],
            "configuration" => "WYE",
            "p_nom" => [load_multiplier * 2.0e3 * scale * max(voltage / 240.0, 1.0)],
            "q_nom" => [load_multiplier * 0.7e3 * scale * max(voltage / 240.0, 1.0)],
        )
    end
    return network
end

function _series_policies(network; optimizer = Ipopt.Optimizer)
    anchor = _build_context(
        network,
        BMOPFTools.OpfScaling(:classic; power_base = 1.0e6);
        add_objective = true,
        optimizer,
    )
    bases = BMOPFTools.opf_bases(anchor)
    voltage_bases = Dict(String(bus) => Float64(value) for (bus, value) in bases.v_base)
    power_bases = Dict(bus => (value > 1_000.0 ? 1.0e6 : 1.0e5) for (bus, value) in voltage_bases)
    return [
        ("classic_1mva", () -> BMOPFTools.OpfScaling(:classic; power_base = 1.0e6)),
        ("si_units", () -> BMOPFTools.OpfScaling(:si)),
        ("series_voltage_local", () -> BMOPFTools.OpfScaling(
            name = :series_voltage_local,
            voltage_bases = copy(voltage_bases), power_bases = copy(power_bases),
        )),
    ], anchor
end

function _compact_record(record)
    artifact = get(record, "artifact", Dict{String,Any}())
    endpoint = get(artifact, "physical_endpoint", Dict{String,Any}())
    return Dict{String,Any}(
        "policy" => get(record, "policy", "unknown"),
        "replicate" => get(record, "replicate", nothing),
        "termination_status" => get(record, "termination_status", "unknown"),
        "solve_seconds" => get(record, "solve_seconds", nothing),
        "common_start_covariance_passed" => get(record, "common_start_covariance_passed", false),
        "physical_endpoint_accepted" => get(endpoint, "acceptance_passed", false),
    )
end

function _run_case(
    label,
    voltage_levels,
    loads_per_level;
    repeats,
    max_iter,
    solver_tolerance,
    load_multiplier = 1.0,
    rating_multiplier = 1.0,
    optimizer = Ipopt.Optimizer,
    solver = :ipopt,
)
    network = _series_case(
        label,
        voltage_levels;
        loads_per_level,
        load_multiplier,
        rating_multiplier,
    )
    policies, anchor_context = _series_policies(network; optimizer)
    anchor_evaluation = _schema_evaluation(anchor_context, "$label-anchor")
    backend = JuMP.backend(BMOPFTools.opf_model(anchor_context))
    variable_count = length(MOI.get(backend, MOI.ListOfVariableIndices()))
    fingerprint = _benchmark_environment_fingerprint(_benchmark_environment())
    public_records = Dict{String,Any}[]
    private_records = Dict{Tuple{String,Int},Any}()
    for (policy_name, factory) in policies, replicate in 1:repeats
        public, private = _run_policy(
            network, policy_name, factory(), replicate,
            anchor_context, anchor_evaluation, fingerprint;
            max_iter, solver_tolerance, add_objective = true,
            optimizer, solver, max_dense_entries = 0,
        )
        push!(public_records, public)
        private_records[(policy_name, replicate)] = private
    end
    reference = first(policies)[1]
    comparisons = Dict{String,Any}[
        _matched_comparison(
            reference, 1, private_records[(reference, 1)],
            reference, 2, private_records[(reference, 2)];
            baseline_repeat = true, max_dense_entries = 0,
        ),
    ]
    for (policy_name, _) in policies[2:end], replicate in 1:repeats
        push!(comparisons, _matched_comparison(
            reference, replicate, private_records[(reference, replicate)],
            policy_name, replicate, private_records[(policy_name, replicate)];
            max_dense_entries = 0,
        ))
    end
    campaign = NLPDiagnostics.scaling_solver_experiment_campaign_data(
        public_records, comparisons;
        reference_policy = reference, minimum_repeats = repeats,
        metadata = Dict(
            "runner_version" => _SERIES_SOLVER_RUNNER_VERSION,
            "case" => label, "solver" => string(solver),
            "max_iter" => max_iter, "solver_tolerance" => solver_tolerance,
        ),
    )
    return Dict{String,Any}(
        "label" => label,
        "voltage_levels" => voltage_levels,
        "loads_per_level" => loads_per_level,
        "load_multiplier" => load_multiplier,
        "rating_multiplier" => rating_multiplier,
        "bus_count" => length(network["bus"]),
        "transformer_count" => length(network["transformer"]["single_phase"]),
        "model_variable_count" => variable_count,
        "records" => [_compact_record(record) for record in public_records],
        "campaign_gates" => get(campaign, "gates", Dict{String,Any}()),
        "campaign_qualified" => get(campaign, "campaign_qualified", false),
    )
end

function main()
    repeats = parse(Int, get(ENV, "NLPDIAGNOSTICS_BMOPF_SERIES_SOLVER_REPEATS", "2"))
    max_iter = parse(Int, get(ENV, "NLPDIAGNOSTICS_BMOPF_SERIES_SOLVER_MAX_ITER", "20"))
    solver_tolerance = parse(Float64, get(ENV, "NLPDIAGNOSTICS_BMOPF_SERIES_SOLVER_TOL", "1e-8"))
    repeats >= 2 || error("repeats must be at least 2")
    max_iter >= 1 || error("max_iter must be positive")
    cases = [
        ("series_4level_115kV_480V", [115_000.0, 24_900.0, 4_160.0, 480.0], 2),
        ("series_6level_115kV_240V", [115_000.0, 34_500.0, 24_900.0, 12_470.0, 4_160.0, 240.0], 2),
        ("series_8level_230kV_208V", [230_000.0, 69_000.0, 34_500.0, 24_900.0, 12_470.0, 4_160.0, 480.0, 208.0], 3),
    ]
    records = [_run_case(label, levels, loads; repeats, max_iter, solver_tolerance)
               for (label, levels, loads) in cases]
    output = abspath(get(
        ENV, "NLPDIAGNOSTICS_BMOPF_SERIES_SOLVER_OUTPUT",
        joinpath(@__DIR__, "..", "docs", "bmopf_voltage_level_series_solver_campaign_summary.json"),
    ))
    mkpath(dirname(output))
    write_json(output, Dict{String,Any}(
        "schema_version" => "nlpdiagnostics-bmopf-voltage-level-series-solver-campaign-v1",
        "runner" => "benchmarks/bmopf_voltage_level_series_solver_campaign.jl",
        "runner_version" => _SERIES_SOLVER_RUNNER_VERSION,
        "status" => all(record["campaign_qualified"] for record in records) ?
            "matched_start_solver_campaign_complete" : "matched_start_solver_campaign_partial",
        "solver" => "Ipopt",
        "budgets" => Dict("repeats" => repeats, "max_iter" => max_iter, "solver_tolerance" => solver_tolerance),
        "case_count" => length(records),
        "campaign_qualified_count" => count(record -> record["campaign_qualified"], records),
        "records" => records,
        "qualification" => Dict(
            "claim" => "bounded matched-start solver evidence across synthetic voltage-level ladders with series transformers",
            "does_not_establish" => [
                "a universal scaling policy or solver superiority",
                "portable performance or memory scaling",
                "physical validity beyond the declared synthetic fixtures",
            ],
            "next_experiment" => "repeat the largest ladder with MadNLP when available and connect the practical success ledger to these solver records",
        ),
    ))
    println("wrote BMOPFTools voltage-level series solver campaign to $output")
end

if abspath(PROGRAM_FILE) == abspath(@__FILE__)
    main()
end
