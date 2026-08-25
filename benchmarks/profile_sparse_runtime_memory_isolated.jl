#!/usr/bin/env julia

"""Run one sparse profiling dimension per child process.

The existing sparse ladder intentionally keeps all dimensions in one process.
This wrapper isolates each dimension so `Sys.maxrss()` is a per-dimension
high-water observation rather than a cumulative process history.
"""

using JSON

include(joinpath(@__DIR__, "common.jl"))
using .NLPDiagnosticsBenchmarkCommon

const ROOT = repo_root()
const CHILD = joinpath(@__DIR__, "profile_sparse_runtime_memory_scaling.jl")
const PROJECT = joinpath(ROOT, "work", "benchmark-environment")
const OUTPUT = abspath(isempty(ARGS) ?
    joinpath(ROOT, "docs", "sparse_runtime_memory_isolated_summary.json") : ARGS[1])

function positive_list(raw::AbstractString)
    values = try
        parse.(Int, split(raw, ','))
    catch
        error("NLPDIAGNOSTICS_ISOLATED_PROFILE_DIMENSIONS must be comma-separated integers")
    end
    isempty(values) && error("isolated profile dimensions must not be empty")
    all(>=(2), values) || error("isolated profile dimensions must be at least 2")
    length(unique(values)) == length(values) ||
        error("isolated profile dimensions must not contain duplicates")
    return values
end

dimensions = positive_list(get(
    ENV, "NLPDIAGNOSTICS_ISOLATED_PROFILE_DIMENSIONS", "16,32,64,128,256",
))
repetitions = try
    parse(Int, get(ENV, "NLPDIAGNOSTICS_ISOLATED_PROFILE_REPETITIONS", "3"))
catch
    error("NLPDIAGNOSTICS_ISOLATED_PROFILE_REPETITIONS must be positive")
end
repetitions > 0 || error("isolated profile repetitions must be positive")

records = Dict{String,Any}[]
for dimension in dimensions
    path, io = mktemp()
    close(io)
    try
        child_env = Dict{String,String}(ENV)
        child_env["NLPDIAGNOSTICS_PROFILE_DIMENSIONS"] = string(dimension)
        child_env["NLPDIAGNOSTICS_PROFILE_REPETITIONS"] = string(repetitions)
        cmd = setenv(`$(Base.julia_cmd()) --compiled-modules=no --startup-file=no --project=$PROJECT $CHILD $path`, child_env)
        run(cmd)
        child_summary = JSON.parsefile(path)
        child_records = get(child_summary, "records", Any[])
        isempty(child_records) && error("child profile returned no records for dimension $dimension")
        for child_record in child_records
            push!(records, merge(
                Dict{String,Any}(child_record),
                Dict("isolated_process" => true),
            ))
        end
    finally
        isfile(path) && rm(path; force = true)
    end
end

status_entries = git_status_entries()
write_json(OUTPUT, Dict{String,Any}(
    "schema_version" => "nlpdiagnostics-sparse-runtime-memory-isolated-v1",
    "source" => Dict(
        "runner" => "benchmarks/profile_sparse_runtime_memory_isolated.jl",
        "child_runner" => "benchmarks/profile_sparse_runtime_memory_scaling.jl",
        "dimensions" => dimensions,
        "repetitions" => repetitions,
        "isolated_process_per_dimension" => true,
    ),
    "environment" => Dict(
        "julia_version" => string(VERSION),
        "active_project" => Base.active_project(),
        "os" => string(Sys.KERNEL),
        "architecture" => string(Sys.ARCH),
        "git_revision" => git_revision(),
        "git_worktree_dirty" => !isempty(status_entries),
        "git_status_entry_count" => length(status_entries),
    ),
    "record_count" => length(records),
    "records" => records,
    "interpretation" => Dict(
        "claim" =>
            "Local isolated-process runtime, allocation, and high-water observations for the synthetic sparse profiling corpus.",
        "does_not_establish" => [
            "OPF solver runtime or solver memory scaling",
            "isolated allocator peak beyond the process high-water observation",
            "a portable complexity law or production threshold",
        ],
        "memory_note" =>
            "Each dimension runs in a fresh child process; Sys.maxrss is therefore isolated to that child but remains a high-water mark.",
    ),
))
println("wrote isolated sparse runtime/memory summary to $OUTPUT")
