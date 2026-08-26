#!/usr/bin/env julia

"""Screen the synthetic series ladder for an analytical capacity boundary.

The screen is deliberately solver-independent: it computes downstream complex
load flow and compares each transformer's apparent-power rating.  It provides
a necessary-condition explanation for the solver feasibility boundary without
claiming that thermal capacity alone proves AC feasibility or KKT acceptance.
"""

include(joinpath(@__DIR__, "common.jl"))
using .NLPDiagnosticsBenchmarkCommon

const ROOT = repo_root()
const FEASIBILITY_INPUT = "docs/bmopf_voltage_level_series_feasibility_sweep_summary.json"
const OUTPUT = abspath(isempty(ARGS) ?
    joinpath(ROOT, "docs", "bmopf_series_nominal_capacity_boundary_summary.json") : ARGS[1])

const VOLTAGE_LEVELS = [230_000.0, 69_000.0, 34_500.0, 24_900.0, 12_470.0, 4_160.0, 480.0, 208.0]
const LOADS_PER_LEVEL = 3

function _capacity_records(multiplier)
    loads = [(
        multiplier * LOADS_PER_LEVEL * 2.0e3 * (1.0 + 0.05 * (index - 1)) * max(VOLTAGE_LEVELS[index] / 240.0, 1.0),
        multiplier * LOADS_PER_LEVEL * 0.7e3 * (1.0 + 0.05 * (index - 1)) * max(VOLTAGE_LEVELS[index] / 240.0, 1.0),
    ) for index in 2:length(VOLTAGE_LEVELS)]
    records = Dict{String,Any}[]
    for transformer_index in 1:(length(VOLTAGE_LEVELS) - 1)
        p_downstream = sum(load[1] for load in loads[transformer_index:end])
        q_downstream = sum(load[2] for load in loads[transformer_index:end])
        apparent_power = hypot(p_downstream, q_downstream)
        rating = max(2.0e6, 10.0e3 * LOADS_PER_LEVEL * (length(VOLTAGE_LEVELS) - transformer_index + 1))
        push!(records, Dict{String,Any}(
            "transformer_index" => transformer_index,
            "from_voltage" => VOLTAGE_LEVELS[transformer_index],
            "to_voltage" => VOLTAGE_LEVELS[transformer_index + 1],
            "downstream_p_w" => p_downstream,
            "downstream_q_var" => q_downstream,
            "downstream_s_va" => apparent_power,
            "rating_va" => rating,
            "loading_ratio" => apparent_power / rating,
            "capacity_gate_passed" => apparent_power <= rating,
        ))
    end
    return records
end

function _solver_row(feasibility, multiplier)
    label = "series_8level_230kV_208V_load$(multiplier)"
    for record in get(feasibility, "records", Any[])
        get(record, "label", "") == label || continue
        rows = get(record, "records", Any[])
        return Dict{String,Any}(
            "label" => label,
            "all_policies_locally_solved" => all(get(row, "termination_status", "") == "LOCALLY_SOLVED" for row in rows),
            "all_physical_endpoints_accepted" => get(get(record, "campaign_gates", Dict{String,Any}()), "all_physical_endpoints_accepted", false),
            "campaign_qualified" => get(record, "campaign_qualified", false),
        )
    end
    return Dict{String,Any}("label" => label, "available" => false)
end

feasibility = read_summary(FEASIBILITY_INPUT)
multipliers = [1.0, 0.75, 0.5, 0.25]
records = Dict{String,Any}[]
for multiplier in multipliers
    transformer_records = _capacity_records(multiplier)
    maximum_ratio = maximum(record["loading_ratio"] for record in transformer_records)
    push!(records, Dict{String,Any}(
        "load_multiplier" => multiplier,
        "transformer_count" => length(transformer_records),
        "maximum_loading_ratio" => maximum_ratio,
        "capacity_gate_passed" => all(record["capacity_gate_passed"] for record in transformer_records),
        "overloaded_transformer_indices" => [record["transformer_index"] for record in transformer_records if !record["capacity_gate_passed"]],
        "transformers" => transformer_records,
        "solver_observation" => _solver_row(feasibility, multiplier),
    ))
end
nominal_ratio = first(records)["maximum_loading_ratio"]
threshold = 1.0 / nominal_ratio
capacity_solver_alignment = all(
    (record["capacity_gate_passed"] == get(record["solver_observation"], "all_policies_locally_solved", false))
    for record in records
)
write_json(OUTPUT, Dict{String,Any}(
    "schema_version" => "nlpdiagnostics-bmopf-series-nominal-capacity-boundary-v1",
    "runner" => "benchmarks/analyze_bmopf_series_nominal_capacity_boundary.jl",
    "status" => capacity_solver_alignment ? "capacity_boundary_aligned" : "capacity_boundary_partial",
    "case" => Dict(
        "voltage_levels" => VOLTAGE_LEVELS,
        "loads_per_level" => LOADS_PER_LEVEL,
        "transformer_count" => length(VOLTAGE_LEVELS) - 1,
    ),
    "records" => records,
    "analytical_threshold" => Dict(
        "necessary_capacity_multiplier" => threshold,
        "nominal_maximum_loading_ratio" => nominal_ratio,
        "interpretation" => "multipliers below this value are required by the declared transformer ratings before voltage-drop and nonlinear feasibility effects are considered",
    ),
    "qualification" => Dict(
        "claim" => "the recorded 0.25 solver boundary is consistent with a necessary transformer-capacity screen, while nominal, 0.75, and 0.5 overload the upstream transformer",
        "does_not_establish" => [
            "AC feasibility or physical KKT acceptance",
            "that transformer capacity is the only source of solver failure",
            "a universal demand threshold outside this synthetic fixture",
        ],
        "next_action" => "retain the capacity screen as a pre-solver guard and focus nominal-demand work on an explicitly uprated or reformulated fixture rather than initialization-only tuning",
    ),
))
println("wrote BMOPFTools series nominal capacity boundary summary to $OUTPUT")
