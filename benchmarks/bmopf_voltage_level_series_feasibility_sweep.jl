#!/usr/bin/env julia

"""Sweep demand on the largest series-transformer ladder.

This diagnostic reuses the matched-start solver campaign and varies only the
synthetic load multiplier.  It is intended to distinguish a fixture-feasibility
boundary from a scaling-policy or iteration-budget boundary.
"""

include(joinpath(@__DIR__, "bmopf_voltage_level_series_solver_campaign.jl"))

function main()
    repeats = parse(Int, get(ENV, "NLPDIAGNOSTICS_BMOPF_SERIES_SWEEP_REPEATS", "2"))
    max_iter = parse(Int, get(ENV, "NLPDIAGNOSTICS_BMOPF_SERIES_SWEEP_MAX_ITER", "60"))
    solver_tolerance = parse(Float64, get(ENV, "NLPDIAGNOSTICS_BMOPF_SERIES_SWEEP_TOL", "1e-8"))
    multipliers = [1.0, 0.75, 0.5, 0.25]
    levels = [230_000.0, 69_000.0, 34_500.0, 24_900.0, 12_470.0, 4_160.0, 480.0, 208.0]
    records = [
        _run_case(
            "series_8level_230kV_208V_load$(multiplier)", levels, 3;
            repeats, max_iter, solver_tolerance, load_multiplier = multiplier,
        ) for multiplier in multipliers
    ]
    output = abspath(get(
        ENV, "NLPDIAGNOSTICS_BMOPF_SERIES_FEASIBILITY_SWEEP_OUTPUT",
        joinpath(@__DIR__, "..", "docs", "bmopf_voltage_level_series_feasibility_sweep_summary.json"),
    ))
    mkpath(dirname(output))
    write_json(output, Dict{String,Any}(
        "schema_version" => "nlpdiagnostics-bmopf-voltage-level-series-feasibility-sweep-v1",
        "runner" => "benchmarks/bmopf_voltage_level_series_feasibility_sweep.jl",
        "solver" => "Ipopt",
        "budgets" => Dict("repeats" => repeats, "max_iter" => max_iter, "solver_tolerance" => solver_tolerance),
        "case" => "series_8level_230kV_208V",
        "load_multiplier_count" => length(records),
        "campaign_qualified_count" => count(record -> record["campaign_qualified"], records),
        "records" => records,
        "qualification" => Dict(
            "claim" => "load-multiplier sensitivity of matched-start solver qualification on the largest synthetic series-transformer ladder",
            "does_not_establish" => [
                "a physical demand threshold",
                "a universal scaling policy",
                "solver superiority or portable performance",
            ],
            "next_action" => "retain the first qualified multiplier as a controlled regression fixture and build an explicitly uprated nominal-demand case",
        ),
    ))
    println("wrote BMOPFTools voltage-level series feasibility sweep to $output")
end

if abspath(PROGRAM_FILE) == abspath(@__FILE__)
    main()
end
