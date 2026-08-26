#!/usr/bin/env julia

"""Run the bounded MadNLP follow-up for the largest feasible series ladder.

This intentionally reuses the series campaign's matched-start and endpoint
contracts.  The demand multiplier is fixed at the feasibility-sweep boundary
(0.25) so the solver comparison tests solver diversity, not a known-infeasible
fixture.
"""

using NLPDiagnostics
using BMOPFTools
using JuMP
using Ipopt
using MadNLP

include(joinpath(@__DIR__, "bmopf_voltage_level_series_solver_campaign.jl"))

const _MADNLP_RUNNER_VERSION = "bmopf-voltage-level-series-madnlp-campaign-v1"

function _json_safe(value)
    value isa AbstractFloat && !isfinite(value) && return nothing
    value isa AbstractDict && return Dict(string(key) => _json_safe(item) for (key, item) in value)
    value isa NamedTuple && return Dict(string(key) => _json_safe(getfield(value, key)) for key in keys(value))
    value isa Tuple && return [_json_safe(item) for item in value]
    value isa AbstractArray && return [_json_safe(item) for item in value]
    return value
end

function main()
    repeats = parse(Int, get(ENV, "NLPDIAGNOSTICS_BMOPF_SERIES_MADNLP_REPEATS", "2"))
    max_iter = parse(Int, get(ENV, "NLPDIAGNOSTICS_BMOPF_SERIES_MADNLP_MAX_ITER", "60"))
    solver_tolerance = parse(Float64, get(ENV, "NLPDIAGNOSTICS_BMOPF_SERIES_MADNLP_TOL", "1e-8"))
    load_multiplier = parse(Float64, get(ENV, "NLPDIAGNOSTICS_BMOPF_SERIES_MADNLP_LOAD_MULTIPLIER", "0.25"))
    repeats >= 2 || error("repeats must be at least 2")
    max_iter >= 1 || error("max_iter must be positive")
    record = _run_case(
        "series_8level_230kV_208V",
        [230_000.0, 69_000.0, 34_500.0, 24_900.0, 12_470.0, 4_160.0, 480.0, 208.0],
        3;
        repeats,
        max_iter,
        solver_tolerance,
        load_multiplier,
        optimizer = MadNLP.Optimizer,
        solver = :madnlp,
    )
    output = abspath(get(
        ENV,
        "NLPDIAGNOSTICS_BMOPF_SERIES_MADNLP_OUTPUT",
        joinpath(@__DIR__, "..", "docs", "bmopf_voltage_level_series_madnlp_campaign_summary.json"),
    ))
    mkpath(dirname(output))
    write_json(output, _json_safe(Dict{String,Any}(
        "schema_version" => "nlpdiagnostics-bmopf-voltage-level-series-madnlp-campaign-v1",
        "runner" => "benchmarks/bmopf_voltage_level_series_madnlp_campaign.jl",
        "runner_version" => _MADNLP_RUNNER_VERSION,
        "status" => record["campaign_qualified"] ? "madnlp_campaign_complete" : "madnlp_campaign_partial",
        "solver" => "MadNLP",
        "budgets" => Dict(
            "repeats" => repeats,
            "max_iter" => max_iter,
            "solver_tolerance" => solver_tolerance,
            "load_multiplier" => load_multiplier,
        ),
        "case_count" => 1,
        "campaign_qualified_count" => record["campaign_qualified"] ? 1 : 0,
        "records" => [record],
        "qualification" => Dict(
            "claim" => "bounded matched-start MadNLP evidence on the largest currently feasible synthetic series-transformer ladder",
            "does_not_establish" => [
                "solver superiority or a universal scaling policy",
                "feasibility at the nominal demand multiplier",
                "portable performance or memory scaling",
            ],
            "next_experiment" => "compare this solver-diverse result with the combined MV+LV practical application ledger and tune the nominal-demand fixture separately",
        ),
    )))
    println("wrote BMOPFTools voltage-level series MadNLP campaign to $output")
end

if abspath(PROGRAM_FILE) == abspath(@__FILE__)
    main()
end
