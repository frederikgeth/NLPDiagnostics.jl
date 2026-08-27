#!/usr/bin/env julia

"""Run each bounded BMOPFTools point-free analyze case in a fresh Julia child."""

using JSON

include(joinpath(@__DIR__, "common.jl"))
using .NLPDiagnosticsBenchmarkCommon

const ROOT = repo_root()
const CHILD = joinpath(@__DIR__, "profile_bmopf_analyze_runtime.jl")
const PROJECT = abspath(get(
    ENV,
    "NLPDIAGNOSTICS_BMOPF_ANALYZE_ISOLATED_PROJECT",
    joinpath(ROOT, "work", "benchmark-environment"),
))
const OUTPUT = abspath(isempty(ARGS) ?
    joinpath(ROOT, "docs", "bmopf_analyze_runtime_isolated_summary.json") : ARGS[1])

function positive_integer(name::AbstractString, default::Int)
    value = try
        parse(Int, get(ENV, name, string(default)))
    catch
        error("$name must be a positive integer")
    end
    value > 0 || error("$name must be a positive integer")
    return value
end

function selected_cases()
    raw = strip(get(
        ENV,
        "NLPDIAGNOSTICS_BMOPF_ANALYZE_ISOLATED_CASES",
        "pf_1ph_line.dss,pf_exp_1ph.dss,pf_1ph_xfmr.dss,pf_cap_wye.dss,pf_dy_xfmr.dss",
    ))
    cases = unique(filter(!isempty, strip.(split(raw, ','))))
    isempty(cases) && error("NLPDIAGNOSTICS_BMOPF_ANALYZE_ISOLATED_CASES must not be empty")
    return cases
end

repetitions = positive_integer("NLPDIAGNOSTICS_BMOPF_ANALYZE_ISOLATED_REPETITIONS", 2)
max_variables = positive_integer("NLPDIAGNOSTICS_BMOPF_ANALYZE_PROFILE_MAX_VARIABLES", 24)
warmup = lowercase(strip(get(ENV, "NLPDIAGNOSTICS_BMOPF_ANALYZE_PROFILE_WARMUP", "true")))
warmup in ("true", "1", "yes") || error("NLPDIAGNOSTICS_BMOPF_ANALYZE_PROFILE_WARMUP must be true for the isolated profile")
cases = selected_cases()

records = Dict{String,Any}[]
for case in cases
    for repetition in 1:repetitions
        path, io = mktemp()
        close(io)
        try
            child_env = Dict{String,String}(ENV)
            child_env["NLPDIAGNOSTICS_BMOPF_ANALYZE_PROFILE_CASES"] = case
            child_env["NLPDIAGNOSTICS_BMOPF_ANALYZE_PROFILE_MAX_VARIABLES"] = string(max_variables)
            child_env["NLPDIAGNOSTICS_BMOPF_ANALYZE_PROFILE_WARMUP"] = "true"
            cmd = setenv(`$(Base.julia_cmd()) --compiled-modules=no --startup-file=no --project=$PROJECT $CHILD $path`, child_env)
            run(cmd)
            child_summary = JSON.parsefile(path)
            child_records = get(child_summary, "records", Any[])
            length(child_records) == 1 || error("child profile returned an unexpected record count for $case")
            push!(records, merge(
                Dict{String,Any}(child_records[1]),
                Dict{String,Any}(
                    "repetition" => repetition,
                    "isolated_process" => true,
                    "memory_observation" => "fresh child-process Sys.maxrss before/after analyze; high-water telemetry, not allocator-level peak",
                ),
            ))
        catch error
            push!(records, Dict{String,Any}(
                "case" => case,
                "repetition" => repetition,
                "status" => "error",
                "isolated_process" => true,
                "error_type" => string(typeof(error)),
                "error" => sprint(showerror, error),
            ))
        finally
            isfile(path) && rm(path; force = true)
        end
    end
end

function stable_records(case_records)
    measured = filter(record -> get(record, "status", "") == "measured", case_records)
    length(measured) < 2 && return false
    reference = first(measured)
    all(record -> get(record, "variable_count", nothing) == get(reference, "variable_count", nothing) &&
        get(record, "constraint_count", nothing) == get(reference, "constraint_count", nothing) &&
        get(record, "analyze_finding_count", nothing) == get(reference, "analyze_finding_count", nothing) &&
        get(record, "analyze_finding_code_counts", nothing) == get(reference, "analyze_finding_code_counts", nothing), measured)
end

case_summaries = Dict{String,Any}[]
for case in cases
    case_records = filter(record -> get(record, "case", "") == case, records)
    measured = filter(record -> get(record, "status", "") == "measured", case_records)
    increments = Float64[
        Float64(record["process_maxrss_increment_bytes"])
        for record in measured
        if get(record, "process_maxrss_increment_bytes", nothing) isa Real
    ]
    push!(case_summaries, Dict{String,Any}(
        "case" => case,
        "record_count" => length(case_records),
        "measured_count" => length(measured),
        "guarded_count" => count(record -> get(record, "status", "") == "skipped_size_guard", case_records),
        "stable_across_repetitions" => stable_records(case_records),
        "rss_increment_range_bytes" => isempty(increments) ? Any[] : [minimum(increments), maximum(increments)],
    ))
end

status_entries = git_status_entries()
measured_records = filter(record -> get(record, "status", "") == "measured", records)
write_json(OUTPUT, Dict{String,Any}(
    "schema_version" => "nlpdiagnostics-bmopf-analyze-runtime-isolated-v1",
    "source" => Dict(
        "runner" => "benchmarks/profile_bmopf_analyze_runtime_isolated.jl",
        "child_runner" => "benchmarks/profile_bmopf_analyze_runtime.jl",
        "project" => PROJECT,
        "cases" => cases,
        "repetitions" => repetitions,
        "max_variables" => max_variables,
        "warmup" => true,
        "isolated_process_per_case_and_repetition" => true,
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
    "measured_count" => length(measured_records),
    "case_summaries" => case_summaries,
    "records" => records,
    "all_measured_cases_stable" => all(summary["stable_across_repetitions"] for summary in case_summaries if summary["measured_count"] > 0),
    "interpretation" => Dict(
        "claim" => "Fresh-child local observations of point-free BMOPFTools analyze allocations and process high-water increments on guarded fixtures.",
        "does_not_establish" => [
            "a second-environment or portable memory guarantee",
            "allocator-level peak memory beyond Sys.maxrss high-water telemetry",
            "OPF solver runtime or memory scaling",
        ],
    ),
))
println("wrote isolated BMOPFTools analyze runtime summary to $OUTPUT")
