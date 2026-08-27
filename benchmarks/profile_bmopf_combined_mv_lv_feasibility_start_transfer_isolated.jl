#!/usr/bin/env julia

"""Repeat the full-case start-transfer probe in fresh Julia child processes."""

using JSON

include(joinpath(@__DIR__, "common.jl"))
using .NLPDiagnosticsBenchmarkCommon: git_revision, git_status_entries, repo_root, write_json

const ROOT = repo_root()
const CHILD = joinpath(@__DIR__, "run_bmopf_combined_mv_lv_feasibility_start_transfer_child.jl")

function _external_peak_rss(stderr_path)
    text = try read(stderr_path, String) catch; return nothing end
    pattern = Sys.isapple() ?
        r"maximum resident set size:\s+(\d+)" :
        r"Maximum resident set size \(kbytes\):\s+(\d+)"
    match_result = match(pattern, text)
    isnothing(match_result) && return nothing
    value = parse(Int, match_result.captures[1])
    return Sys.isapple() ? value : value * 1024
end

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
    metrics_path, metrics_io = mktemp()
    close(metrics_io)
    try
        child_env = Dict{String,String}(ENV)
        child_env["NLPDIAGNOSTICS_COMBINED_MV_LV_TRANSFER_OUTPUT"] = path
        command = setenv(
            `$(Base.julia_cmd()) --compiled-modules=no --startup-file=no --project=$(joinpath(ROOT, "work", "benchmark-environment")) $CHILD $path`,
            child_env,
        )
        timed_command = Cmd(vcat(
            ["/usr/bin/time", Sys.isapple() ? "-l" : "-v"], command.exec,
        ))
        external_probe_error = nothing
        try
            run(pipeline(setenv(timed_command, child_env), stderr=metrics_path))
        catch error
            # Keep the benchmark useful when a sandboxed/macOS time wrapper
            # cannot execute or inspect a child process.
            external_probe_error = string(typeof(error))
            run(command)
        end
        child = JSON.parsefile(path)
        child["repetition"] = repetition
        child["isolated_process"] = true
        child["external_peak_rss_bytes"] = _external_peak_rss(metrics_path)
        child["external_peak_rss_source"] = isnothing(external_probe_error) ?
            (Sys.isapple() ? "/usr/bin/time -l" : "/usr/bin/time -v") :
            "unavailable: " * external_probe_error
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
        isfile(metrics_path) && rm(metrics_path; force = true)
    end
end

measured = filter(record -> get(record, "status", "") == "bounded_hard_opf_start_transfer", records)
peak_rss = [
    Int(record["child_peak_rss_bytes"])
    for record in measured
    if get(record, "child_peak_rss_bytes", nothing) isa Real
]
external_peak_rss = [
    Int(record["external_peak_rss_bytes"])
    for record in measured
    if get(record, "external_peak_rss_bytes", nothing) isa Real
]
allocator_deltas = [
    Int(record["allocator_telemetry"]["current_size_allocated_delta_bytes"])
    for record in measured
    if get(record, "allocator_telemetry", nothing) isa AbstractDict &&
       get(record["allocator_telemetry"], "current_size_allocated_delta_bytes", nothing) isa Real
]
allocator_available_count = count(
    record -> get(get(record, "allocator_telemetry", Dict()), "peak_available", false),
    measured,
)
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
    "external_peak_rss_bytes_range" => isempty(external_peak_rss) ? Any[] :
        [minimum(external_peak_rss), maximum(external_peak_rss)],
    "external_peak_rss_measured_count" => length(external_peak_rss),
    "allocator_peak_available_count" => allocator_available_count,
    "allocator_size_allocated_delta_bytes_range" => isempty(allocator_deltas) ? Any[] :
        [minimum(allocator_deltas), maximum(allocator_deltas)],
    "records" => records,
    "interpretation" => Dict(
        "claim" => "Fresh-child local Sys.maxrss and independent /usr/bin/time (or time -v) high-water observations for the full combined MV/LV feasibility-start transfer benchmark.",
        "does_not_establish" => [
            "allocator-level peak memory beyond process high-water telemetry",
            "portable memory scaling or a second-environment guarantee",
            "hard OPF convergence or a production scaling policy",
        ],
    ),
))
println("wrote isolated combined MV/LV transfer summary to $output")
