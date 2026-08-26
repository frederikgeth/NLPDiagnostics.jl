#!/usr/bin/env julia

"""Run nominal-demand campaigns on an explicitly uprated series ladder.

The rating multiplier is part of the fixture definition, not a solver option.
This campaign tests whether the previously overloaded nominal case becomes a
qualified numerical fixture after that physical capacity intervention.
"""

using NLPDiagnostics
using BMOPFTools
using JuMP
using Ipopt
using MadNLP

include(joinpath(@__DIR__, "bmopf_voltage_level_series_solver_campaign.jl"))

const _UPRATED_RUNNER_VERSION = "bmopf-voltage-level-series-uprated-nominal-campaign-v1"
const _LEVELS = [230_000.0, 69_000.0, 34_500.0, 24_900.0, 12_470.0, 4_160.0, 480.0, 208.0]
const _RATING_MULTIPLIER = 2.5

function _json_safe(value)
    value isa AbstractFloat && !isfinite(value) && return nothing
    value isa AbstractDict && return Dict(string(key) => _json_safe(item) for (key, item) in value)
    value isa NamedTuple && return Dict(string(key) => _json_safe(getfield(value, key)) for key in keys(value))
    value isa Tuple && return [_json_safe(item) for item in value]
    value isa AbstractArray && return [_json_safe(item) for item in value]
    return value
end

function main()
    repeats = parse(Int, get(ENV, "NLPDIAGNOSTICS_BMOPF_UPRATED_REPEATS", "2"))
    max_iter = parse(Int, get(ENV, "NLPDIAGNOSTICS_BMOPF_UPRATED_MAX_ITER", "60"))
    solver_tolerance = parse(Float64, get(ENV, "NLPDIAGNOSTICS_BMOPF_UPRATED_TOL", "1e-8"))
    repeats >= 2 || error("repeats must be at least 2")
    max_iter >= 1 || error("max_iter must be positive")
    campaigns = Dict{String,Any}[]
    for (solver_name, optimizer, solver) in [
        ("Ipopt", Ipopt.Optimizer, :ipopt),
        ("MadNLP", MadNLP.Optimizer, :madnlp),
    ]
        record = _run_case(
            "series_8level_230kV_208V_uprated_nominal",
            _LEVELS,
            3;
            repeats,
            max_iter,
            solver_tolerance,
            load_multiplier = 1.0,
            rating_multiplier = _RATING_MULTIPLIER,
            optimizer,
            solver,
        )
        push!(campaigns, Dict{String,Any}(
            "solver" => solver_name,
            "record" => record,
        ))
    end
    output = abspath(get(
        ENV,
        "NLPDIAGNOSTICS_BMOPF_UPRATED_OUTPUT",
        joinpath(@__DIR__, "..", "docs", "bmopf_voltage_level_series_uprated_nominal_campaign_summary.json"),
    ))
    mkpath(dirname(output))
    qualified = all(get(item["record"], "campaign_qualified", false) for item in campaigns)
    write_json(output, _json_safe(Dict{String,Any}(
        "schema_version" => "nlpdiagnostics-bmopf-voltage-level-series-uprated-nominal-campaign-v1",
        "runner" => "benchmarks/bmopf_voltage_level_series_uprated_nominal_campaign.jl",
        "runner_version" => _UPRATED_RUNNER_VERSION,
        "status" => qualified ? "uprated_nominal_campaign_complete" : "uprated_nominal_campaign_partial",
        "case" => "series_8level_230kV_208V_uprated_nominal",
        "solver_count" => length(campaigns),
        "rating_multiplier" => _RATING_MULTIPLIER,
        "load_multiplier" => 1.0,
        "budgets" => Dict("repeats" => repeats, "max_iter" => max_iter, "solver_tolerance" => solver_tolerance),
        "campaigns" => campaigns,
        "qualification" => Dict(
            "claim" => "nominal-demand Ipopt and MadNLP evidence on an explicitly uprated largest series-transformer fixture",
            "does_not_establish" => [
                "the original 2 MVA fixture is feasible",
                "solver superiority or a universal rating multiplier",
                "portable performance or physical KKT acceptance beyond declared gates",
            ],
            "next_action" => "compare uprated nominal results with the practical bridge and retain the rating multiplier as fixture metadata",
        ),
    )))
    println("wrote BMOPFTools uprated nominal series campaign to $output")
end

if abspath(PROGRAM_FILE) == abspath(@__FILE__)
    main()
end
