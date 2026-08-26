#!/usr/bin/env julia

"""Summarize a bounded rerun of the excluded 538-bus SI endpoints.

The rerun is deliberately kept separate from the canonical BMOPFDraftData
saved-result files.  It records solver-work evidence and never promotes that
evidence into the saved-result quality gate without an explicit replacement
of the upstream result files.

Usage:

    julia benchmarks/summarize_bmopf_si_rerun.jl isolated-index.json output.json
"""

using JSON

Base.include(@__MODULE__, joinpath(@__DIR__, "common.jl"))
using .NLPDiagnosticsBenchmarkCommon: git_revision, git_status_entries, write_json

length(ARGS) == 2 || error(
    "usage: summarize_bmopf_si_rerun.jl isolated-index.json output.json",
)
index_path = abspath(ARGS[1])
output_path = abspath(ARGS[2])
isfile(index_path) || error("isolated solver index is missing: $index_path")
index = JSON.parsefile(index_path)
index isa AbstractDict || error("isolated solver index is not an object: $index_path")
cases = get(index, "cases", Any[])
cases isa AbstractVector || error("isolated solver index cases is not an array: $index_path")

function _case_name(value)
    replace(replace(String(value), '/' => "__"), ".bmopf.json" => "")
end

function _log_path(case)
    name = _case_name(get(case, "snapshot", get(case, "name", "")))
    joinpath(dirname(index_path), "$name.log")
end

function _log_evidence(path)
    isfile(path) || return Dict{String,Any}(
        "available" => false,
        "termination" => nothing,
        "iteration_count" => nothing,
    )
    text = read(path, String)
    iteration_match = match(r"Number of Iterations\.+:\s*(\d+)", text)
    exit_match = match(r"EXIT:\s*(.+)", text)
    termination = isnothing(exit_match) ? nothing : strip(exit_match.captures[1])
    return Dict{String,Any}(
        "available" => true,
        "termination" => termination,
        "iteration_count" => isnothing(iteration_match) ? nothing : parse(Int, iteration_match.captures[1]),
        "optimal_solution" => termination == "Optimal Solution Found.",
    )
end

function _result_data(case)
    result_file = get(case, "result_file", nothing)
    result_file isa AbstractString || return Dict{String,Any}()
    path = joinpath(dirname(index_path), result_file)
    isfile(path) || return Dict{String,Any}()
    result = JSON.parsefile(path)
    result isa AbstractDict || return Dict{String,Any}()
    return Dict{String,Any}(
        "model_variable_count" => get(result, "model_variable_count", nothing),
        "status" => get(result, "status", nothing),
    )
end

records = Dict{String,Any}[]
for case in cases
    case isa AbstractDict || continue
    snapshot = String(get(case, "snapshot", ""))
    log_path = _log_path(case)
    evidence = _log_evidence(log_path)
    result = _result_data(case)
    push!(records, Dict{String,Any}(
        "snapshot" => snapshot,
        "name" => String(get(case, "name", _case_name(snapshot))),
        "runner_status" => get(case, "status", nothing),
        "process_exit_code" => get(case, "process_exit_code", nothing),
        "process_timeout" => get(case, "process_timeout", nothing),
        "model_variable_count" => get(result, "model_variable_count", nothing),
        "result_status" => get(result, "status", nothing),
        "solver_log" => basename(log_path),
        "solver_log_evidence" => evidence,
        "bounded_success" => get(case, "process_exit_code", nothing) == 0 &&
            get(case, "process_timeout", false) === false &&
            get(evidence, "optimal_solution", false) === true,
    ))
end

sort!(records; by = record -> record["snapshot"])
successful = count(get(record, "bounded_success", false) === true for record in records)
payload = Dict{String,Any}(
    "schema_version" => "nlpdiagnostics-bmopf-si-bounded-rerun-v1",
    "source" => Dict{String,Any}(
        "runner" => "benchmarks/launch_bmopf_solver_trace.jl",
        "summarizer" => "benchmarks/summarize_bmopf_si_rerun.jl",
        "isolated_index" => index_path,
        "benchmark_root" => get(index, "benchmark_root", nothing),
    ),
    "environment" => Dict{String,Any}(
        "git_revision" => git_revision(),
        "git_worktree_dirty" => !isempty(git_status_entries()),
        "solver" => get(index, "solver", nothing),
        "solver_options" => get(index, "solver_options", Dict{String,Any}()),
        "child_timeout_seconds" => get(index, "child_timeout_seconds", nothing),
        "profile_stage" => get(index, "profile_stage", nothing),
        "environment_fingerprint" => get(index, "environment_fingerprint", nothing),
    ),
    "case_count" => length(records),
    "bounded_success_count" => successful,
    "bounded_failure_count" => length(records) - successful,
    "all_bounded_successes" => successful == length(records) && !isempty(records),
    "records" => records,
    "interpretation" => "All records are bounded solver-work evidence from a fresh isolated run. They do not replace the seven nonfinite canonical saved results; physical endpoint claims remain subject to the saved-result quality boundary until those files are regenerated and re-audited.",
)
write_json(output_path, payload)
println("wrote BMOPF SI bounded-rerun summary to $output_path")
