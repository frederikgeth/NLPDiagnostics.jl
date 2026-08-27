#!/usr/bin/env julia

"""Repeat the full-case start-transfer probe in fresh Julia child processes."""

using JSON

include(joinpath(@__DIR__, "common.jl"))
using .NLPDiagnosticsBenchmarkCommon: git_revision, git_status_entries, repo_root, write_json

const ROOT = repo_root()
const CHILD = joinpath(@__DIR__, "run_bmopf_combined_mv_lv_feasibility_start_transfer_child.jl")

function _positive_integer(name, default)
    value = try parse(Int, get(ENV, name, string(default)))
    catch
        error("$name must be a positive integer")
    end
    value > 0 || error("$name must be a positive integer")
    return value
end

repetitions = _positive_integer("NLPDIAGNOSTICS_COMBINED_MV_LV_TRANSFER_REPETITIONS", 1)
output = abspath(get(
    ENV,
    "NLPDIAGNOSTICS_COMBINED_MV_LV_TRANSFER_ISOLATED_OUTPUT",
    joinpath(ROOT, "work", "bmopf-combined-mv-lv-feasibility-start-transfer-isolated.json"),
))
records = Dict{String,Any}[]

for repetition in 1:repetitions
    path, io = mktemp()
    close(io)
    try
        child_env = Dict{String,String}(ENV)
        child_env["NLPDIAGNOSTICS_COMBINED_MV_LV_TRANSFER_OUTPUT"] = path
        command = setenv(
            `$(Base.julia_cmd()) --compiled-modules=no --startup-file=no --project=$(joinpath(ROOT, "work", "benchmark-environment")) $CHILD $path`,
            child_env,
        )
        run(command)
        child = JSON.parsefile(path)
        child["repetition"] = repetition
        child["isolated_process"] = true
        push!(records, child)
    catch error
        push!(records, Dict{String,Any}(
            "repetition" => repetition,
            "isolated_process" => true,
            "status" => "error",
            "error_type" => string(typeof(error)),
            "error" => sprint(showerror, error),
        ))
    finally
        isfile(path) && rm(path; force = true)
    end
end

measured = filter(record -> get(record, "status", "") == "bounded_hard_opf_start_transfer", records)
peak_rss = [
    Int(record["child_peak_rss_bytes"])
    for record in measured
    if get(record, "child_peak_rss_bytes", nothing) isa Real
]
status_entries = git_status_entries()
write_json(output, Dict{String,Any}(
    "schema_version" => "nlpdiagnostics-bmopf-combined-mv-lv-feasibility-start-transfer-isolated-v1",
    "source" => Dict(
        "runner" => "benchmarks/profile_bmopf_combined_mv_lv_feasibility_start_transfer_isolated.jl",
        "child_runner" => "benchmarks/run_bmopf_combined_mv_lv_feasibility_start_transfer_child.jl",
        "repetitions" => repetitions,
        "isolated_process_per_repetition" => true,
    ),
    "environment" => Dict(
        "julia_version" => string(VERSION),
        "active_project" => Base.active_project(),
        "os" => string(Sys.KERNEL),
        "architecture" => string(Sys.ARCH),
        "git_revision" => git_revision(),
        "git_worktree_dirty" => !isempty(status_entries),
    ),
    "record_count" => length(records),
    "measured_count" => length(measured),
    "peak_rss_bytes_range" => isempty(peak_rss) ? Any[] : [minimum(peak_rss), maximum(peak_rss)],
    "records" => records,
    "interpretation" => Dict(
        "claim" => "Fresh-child local Sys.maxrss high-water observations for the full combined MV/LV feasibility-start transfer benchmark.",
        "does_not_establish" => [
            "allocator-level peak memory beyond process high-water telemetry",
            "portable memory scaling or a second-environment guarantee",
            "hard OPF convergence or a production scaling policy",
        ],
    ),
))
println("wrote isolated combined MV/LV transfer summary to $output")
