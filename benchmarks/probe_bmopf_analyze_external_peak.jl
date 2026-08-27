#!/usr/bin/env julia

"""Probe an independent operating-system peak RSS measurement for one analyze child.

This is intentionally a capability probe, not a benchmark campaign.  On macOS,
`/usr/bin/time -l` reports the child process maximum resident set size; the
existing child artifact remains the source of semantic and Julia-level fields.
The result is retained as descriptive evidence and never promoted to an
allocator-level peak or portable performance claim.
"""

using JSON

include(joinpath(@__DIR__, "common.jl"))
using .NLPDiagnosticsBenchmarkCommon

const ROOT = repo_root()
const CHILD = joinpath(ROOT, "benchmarks", "profile_bmopf_analyze_runtime.jl")
const PROJECT = abspath(get(
    ENV,
    "NLPDIAGNOSTICS_BMOPF_ANALYZE_EXTERNAL_PROJECT",
    joinpath(ROOT, "work", "benchmark-environment"),
))
const CASE = strip(get(ENV, "NLPDIAGNOSTICS_BMOPF_ANALYZE_EXTERNAL_CASE", "pf_1ph_line.dss"))
const MAX_VARIABLES = strip(get(ENV, "NLPDIAGNOSTICS_BMOPF_ANALYZE_EXTERNAL_MAX_VARIABLES", "24"))
const WARMUP = strip(get(ENV, "NLPDIAGNOSTICS_BMOPF_ANALYZE_EXTERNAL_WARMUP", "true"))
const OUTPUT = abspath(isempty(ARGS) ? get(
    ENV,
    "NLPDIAGNOSTICS_BMOPF_ANALYZE_EXTERNAL_OUTPUT",
    joinpath(ROOT, "docs", "bmopf_analyze_external_peak_probe_summary.json"),
) : ARGS[1])

function parse_peak_rss(text::AbstractString)
    match_result = match(r"maximum resident set size:\s*([0-9]+)", text)
    isnothing(match_result) && return nothing
    return parse(Int, match_result.captures[1])
end

# Darwin's rusage stores ru_maxrss in bytes.  The first four fields are the
# two timeval values; the remaining fields are long integers on this host.
struct DarwinRUsage
    utime_sec::Int64
    utime_usec::Int64
    stime_sec::Int64
    stime_usec::Int64
    maxrss::Int64
    ixrss::Int64
    idrss::Int64
    isrss::Int64
    minflt::Int64
    majflt::Int64
    nswap::Int64
    inblock::Int64
    oublock::Int64
    msgsnd::Int64
    msgrcv::Int64
    nsignals::Int64
    nvcsw::Int64
    nivcsw::Int64
end

function child_rusage_peak()
    Sys.isapple() || return nothing
    usage = Ref{DarwinRUsage}()
    result = try
        ccall(:getrusage, Cint, (Cint, Ref{DarwinRUsage}), -1, usage)
    catch
        return nothing
    end
    result == 0 || return nothing
    usage[].maxrss > 0 ? Int(usage[].maxrss) : nothing
end

function run_probe()
    isfile(CHILD) || error("analyze child runner is missing: $CHILD")
    isdir(PROJECT) || error("analyze external project is missing: $PROJECT")
    isempty(CASE) && error("NLPDIAGNOSTICS_BMOPF_ANALYZE_EXTERNAL_CASE must not be empty")

    child_path, child_io = mktemp()
    close(child_io)
    stdout_path, stdout_io = mktemp()
    close(stdout_io)
    stderr_path, stderr_io = mktemp()
    close(stderr_io)
    child_status = "not_started"
    child_error = nothing
    external_tool_error = nothing
    child = Dict{String,Any}()
    external_tool = (Sys.isapple() && isfile("/usr/bin/time")) ? "/usr/bin/time -l" : nothing
    try
        child_env = Dict{String,String}(ENV)
        child_env["NLPDIAGNOSTICS_BMOPF_ANALYZE_PROFILE_CASES"] = CASE
        child_env["NLPDIAGNOSTICS_BMOPF_ANALYZE_PROFILE_MAX_VARIABLES"] = MAX_VARIABLES
        child_env["NLPDIAGNOSTICS_BMOPF_ANALYZE_PROFILE_WARMUP"] = WARMUP
        child_cmd = setenv(`$(Base.julia_cmd()) --compiled-modules=no --startup-file=no --project=$PROJECT $CHILD $child_path`, child_env)
        command = isnothing(external_tool) ? child_cmd :
            setenv(`/usr/bin/time -l $(Base.julia_cmd()) --compiled-modules=no --startup-file=no --project=$PROJECT $CHILD $child_path`, child_env)
        open(stdout_path, "w") do stdout_io_capture
            open(stderr_path, "w") do stderr_io_capture
                try
                    run(pipeline(command, stdout=stdout_io_capture, stderr=stderr_io_capture))
                    child_status = "completed"
                catch error
                    child_status = "failed"
                    # Avoid copying the full setenv command (which may contain
                    # unrelated environment details) into the evidence file.
                    external_tool_error = "time_wrapper_exit_nonzero ($(typeof(error)))"
                end
            end
        end
        if isfile(child_path)
            try
                child = JSON.parsefile(child_path)
            catch error
                child_error = isnothing(child_error) ? sprint(showerror, error) : child_error
            end
        end
        stderr_text = read(stderr_path, String)
        peak_rss = parse_peak_rss(stderr_text)
        child_records = get(child, "records", Any[])
        child_record = isempty(child_records) ? Dict{String,Any}() : child_records[1]
        child_completed = child_status == "completed" ||
            (!isempty(child_record) && get(child_record, "status", "") != "error")
        child_completed && child_status == "failed" && (child_status = "completed_with_external_tool_error")
        if isnothing(peak_rss)
            peak_rss = child_rusage_peak()
            !isnothing(peak_rss) && (external_tool = "getrusage(RUSAGE_CHILDREN)")
        end
        child_after = get(child_record, "process_maxrss_after_bytes", nothing)
        difference = peak_rss isa Integer && child_after isa Integer ? peak_rss - child_after : nothing
        status = peak_rss isa Integer && child_completed ?
            "peak_telemetry_available" : "peak_telemetry_unavailable"
        return Dict{String,Any}(
            "schema_version" => "nlpdiagnostics-bmopf-analyze-external-peak-v1",
            "status" => status,
            "source" => Dict(
                "runner" => "benchmarks/probe_bmopf_analyze_external_peak.jl",
                "child_runner" => "benchmarks/profile_bmopf_analyze_runtime.jl",
                "case" => CASE,
                "max_variables" => try parse(Int, MAX_VARIABLES) catch; MAX_VARIABLES end,
                "warmup" => lowercase(WARMUP) in ("true", "1", "yes"),
                "project" => PROJECT,
                "tool" => isnothing(external_tool) ? nothing : external_tool,
            ),
            "environment" => Dict(
                "julia_version" => string(VERSION),
                "active_project" => Base.active_project(),
                "os" => string(Sys.KERNEL),
                "architecture" => string(Sys.ARCH),
                "git_revision" => git_revision(),
                "git_worktree_dirty" => !isempty(git_status_entries()),
            ),
            "child_status" => child_status,
            "child_error" => child_error,
            "external_tool_error" => external_tool_error,
            "child_variable_count" => get(child_record, "variable_count", nothing),
            "child_analyze_finding_count" => get(child_record, "analyze_finding_count", nothing),
            "child_process_maxrss_after_bytes" => child_after,
            "external_peak_rss_bytes" => peak_rss,
            "external_peak_rss_minus_child_after_bytes" => difference,
            "interpretation" => Dict(
                "claim" => "Independent operating-system peak RSS observation for one fresh analyze child on the local host.",
                "does_not_establish" => [
                    "allocator-level peak or retained-memory behavior",
                    "portable peak memory or performance",
                    "multi-case or solver scaling",
                ],
                "boundary" => "The external peak is a process high-water observation; compare it descriptively with the child Sys.maxrss field and do not treat it as allocator telemetry.",
            ),
        )
    finally
        rm(child_path; force=true)
        rm(stdout_path; force=true)
        rm(stderr_path; force=true)
    end
end

write_json(OUTPUT, run_probe())
println("wrote BMOPFTools external analyze peak probe to $OUTPUT")
