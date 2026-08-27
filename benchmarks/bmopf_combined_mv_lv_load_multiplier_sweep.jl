#!/usr/bin/env julia

"""Sweep demand multipliers on the combined MV/LV feeder."""

using JSON

include(joinpath(@__DIR__, "common.jl"))
using .NLPDiagnosticsBenchmarkCommon: repo_root, write_json

const ROOT = repo_root()
const RUNNER = joinpath(ROOT, "benchmarks", "bmopf_combined_mv_lv_feasibility_start_transfer.jl")
const PROJECT = joinpath(ROOT, "work", "benchmark-environment")
const OUTPUT = abspath(get(ENV, "NLPDIAGNOSTICS_COMBINED_MV_LV_LOAD_SWEEP_OUTPUT",
    joinpath(ROOT, "docs", "bmopf_combined_mv_lv_load_multiplier_sweep_summary.json")))

function multipliers()
    raw = split(get(ENV, "NLPDIAGNOSTICS_COMBINED_MV_LV_LOAD_MULTIPLIERS", "1.0,0.75,0.5,0.25"), ',')
    values = try parse.(Float64, strip.(raw)) catch; error("load multipliers must be comma-separated numbers") end
    all(value -> isfinite(value) && value > 0.0, values) || error("load multipliers must be positive and finite")
    return unique(values)
end

function child_command(output_path)
    Cmd(vcat(Base.julia_cmd().exec,
        ["--compiled-modules=no", "--startup-file=no", "--project=$PROJECT", RUNNER, output_path]))
end

results = Dict{String,Any}[]
for multiplier in multipliers()
    path, io = mktemp()
    close(io)
    try
        environment = Dict{String,String}(string(key) => string(value) for (key, value) in ENV)
        environment["NLPDIAGNOSTICS_COMBINED_MV_LV_TRANSFER_OUTPUT"] = path
        environment["NLPDIAGNOSTICS_COMBINED_MV_LV_LOAD_MULTIPLIER"] = string(multiplier)
        environment["NLPDIAGNOSTICS_COMBINED_MV_LV_TRANSFER_MAX_ITER"] =
            get(ENV, "NLPDIAGNOSTICS_COMBINED_MV_LV_LOAD_SWEEP_MAX_ITER", "100")
        environment["NLPDIAGNOSTICS_COMBINED_MV_LV_TRANSFER_MAX_CPU_SECONDS"] =
            get(ENV, "NLPDIAGNOSTICS_COMBINED_MV_LV_LOAD_SWEEP_MAX_CPU_SECONDS", "30")
        run(setenv(child_command(path), environment))
        payload = JSON.parsefile(path)
        records = get(payload, "records", Any[])
        push!(results, Dict{String,Any}(
            "load_multiplier" => multiplier,
            "status" => "completed",
            "relaxed_initialization" => get(payload, "relaxed_initialization", Dict()),
            "records" => records,
            "hard_locally_solved" => !isempty(records) && all(
                get(record, "termination_status", "") == "LOCALLY_SOLVED" for record in records),
        ))
    catch error
        push!(results, Dict{String,Any}(
            "load_multiplier" => multiplier,
            "status" => "error",
            "error_type" => string(typeof(error)),
            "error" => sprint(showerror, error),
        ))
    finally
        isfile(path) && rm(path; force = true)
    end
end

completed = filter(item -> item["status"] == "completed", results)
qualified = filter(item -> get(item, "hard_locally_solved", false), completed)
write_json(OUTPUT, Dict{String,Any}(
    "schema_version" => "nlpdiagnostics-bmopf-combined-mv-lv-load-multiplier-sweep-v1",
    "campaign" => get(ENV, "NLPDIAGNOSTICS_COMBINED_MV_LV_LOAD_SWEEP_CAMPAIGN", "coarse"),
    "status" => length(completed) == length(results) ? "completed" : "partial",
    "multipliers" => [item["load_multiplier"] for item in results],
    "record_count" => length(results),
    "completed_count" => length(completed),
    "hard_locally_solved_count" => length(qualified),
    "results" => results,
    "interpretation" => "This bounded demand sweep identifies a practical combined MV/LV operating point and a fixture-sensitive feasibility boundary. It does not establish a physical demand threshold, universal scaling policy, or solver superiority.",
))
println("wrote combined MV/LV load-multiplier sweep to $OUTPUT")
