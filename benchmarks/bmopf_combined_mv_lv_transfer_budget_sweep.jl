#!/usr/bin/env julia

"""Sweep hard-OPF iteration budgets for the combined MV/LV start transfer."""

using JSON

include(joinpath(@__DIR__, "common.jl"))
using .NLPDiagnosticsBenchmarkCommon: repo_root, write_json

const ROOT = repo_root()
const RUNNER = joinpath(ROOT, "benchmarks", "bmopf_combined_mv_lv_feasibility_start_transfer.jl")
const PROJECT = joinpath(ROOT, "work", "benchmark-environment")
const OUTPUT = abspath(get(ENV, "NLPDIAGNOSTICS_COMBINED_MV_LV_SWEEP_OUTPUT",
    joinpath(ROOT, "docs", "bmopf_combined_mv_lv_transfer_budget_sweep_summary.json")))

function budgets()
    raw = split(get(ENV, "NLPDIAGNOSTICS_COMBINED_MV_LV_SWEEP_BUDGETS", "50,100,200"), ',')
    values = try parse.(Int, strip.(raw)) catch; error("sweep budgets must be comma-separated integers") end
    all(value -> value > 0, values) || error("sweep budgets must be positive")
    return unique(values)
end

function child_command(output_path)
    Cmd(vcat(
        Base.julia_cmd().exec,
        ["--compiled-modules=no", "--startup-file=no", "--project=$PROJECT", RUNNER, output_path],
    ))
end

results = Dict{String,Any}[]
for max_iter in budgets()
    path, io = mktemp()
    close(io)
    try
        environment = Dict{String,String}(string(key) => string(value) for (key, value) in ENV)
        environment["NLPDIAGNOSTICS_COMBINED_MV_LV_TRANSFER_OUTPUT"] = path
        environment["NLPDIAGNOSTICS_COMBINED_MV_LV_TRANSFER_MAX_ITER"] = string(max_iter)
        environment["NLPDIAGNOSTICS_COMBINED_MV_LV_TRANSFER_MAX_CPU_SECONDS"] =
            get(ENV, "NLPDIAGNOSTICS_COMBINED_MV_LV_SWEEP_MAX_CPU_SECONDS", "60")
        run(setenv(child_command(path), environment))
        payload = JSON.parsefile(path)
        push!(results, Dict{String,Any}(
            "max_iter" => max_iter,
            "status" => "completed",
            "runner_status" => get(payload, "status", nothing),
            "records" => get(payload, "records", Any[]),
            "relaxed_termination_status" => get(
                get(payload, "relaxed_initialization", Dict()), "termination_status", nothing,
            ),
        ))
    catch error
        push!(results, Dict{String,Any}(
            "max_iter" => max_iter,
            "status" => "error",
            "error_type" => string(typeof(error)),
            "error" => sprint(showerror, error),
        ))
    finally
        isfile(path) && rm(path; force = true)
    end
end

completed = filter(item -> item["status"] == "completed", results)
hard_records = [record for item in completed for record in get(item, "records", Any[])]
transfer_records = filter(record -> get(record, "label", "") == "feasibility_voltage_transfer", hard_records)
native_records = filter(record -> get(record, "label", "") == "native", hard_records)
all_iteration_limited = !isempty(hard_records) && all(
    record -> get(record, "termination_status", "") == "ITERATION_LIMIT", hard_records,
)
write_json(OUTPUT, Dict{String,Any}(
    "schema_version" => "nlpdiagnostics-bmopf-combined-mv-lv-transfer-budget-sweep-v1",
    "status" => isempty(results) || length(completed) != length(results) ? "partial" : "completed",
    "budgets" => [item["max_iter"] for item in results],
    "record_count" => length(results),
    "completed_count" => length(completed),
    "native_record_count" => length(native_records),
    "transfer_record_count" => length(transfer_records),
    "all_hard_runs_iteration_limited" => all_iteration_limited,
    "termination_statuses" => Dict(
        "native" => sort!(unique(string(get(record, "termination_status", "")) for record in native_records)),
        "feasibility_voltage_transfer" => sort!(unique(string(get(record, "termination_status", "")) for record in transfer_records)),
    ),
    "results" => results,
    "interpretation" => "This bounded sweep tests whether larger hard-OPF iteration budgets change the native/transfer termination class. It does not establish convergence, scaling policy, or a causal solver explanation.",
))
println("wrote combined MV/LV transfer budget sweep to $OUTPUT")
