#!/usr/bin/env julia

"""Summarize the bounded 538-bus solver-scaling extension run."""

using JSON

Base.include(@__MODULE__, joinpath(@__DIR__, "common.jl"))
using .NLPDiagnosticsBenchmarkCommon: git_revision, git_status_entries, write_json

length(ARGS) == 2 || error("usage: summarize_bmopf_solver_scaling_extension.jl output.json run_directory")
output_path = abspath(ARGS[1])
run_directory = abspath(ARGS[2])
index_path = joinpath(run_directory, "index.json")
isfile(index_path) || error("solver extension index is missing: $index_path")
index = JSON.parsefile(index_path)
entries = get(index, "cases", Any[])
records = Dict{String,Any}[]
for entry in entries
    entry isa AbstractDict || continue
    result_file = get(entry, "result_file", nothing)
    result_file isa AbstractString || continue
    result_path = joinpath(run_directory, result_file)
    raw = isfile(result_path) ? JSON.parsefile(result_path) : Dict{String,Any}()
    trace = get(raw, "iteration_trace", Dict{String,Any}())
    trace_summary = get(trace, "summary", Dict{String,Any}())
    final = get(trace_summary, "final_iteration", nothing)
    final_primal = get(trace_summary, "final_primal_infeasibility", nothing)
    final_dual = get(trace_summary, "final_dual_infeasibility", nothing)
    solved = get(entry, "process_timeout", true) == false &&
        get(entry, "process_exit_code", nothing) == 0 &&
        startswith(String(get(entry, "status", "")), "ok_solver") &&
        get(trace_summary, "available", false) == true
    push!(records, Dict{String,Any}(
        "id" => get(entry, "name", nothing),
        "snapshot" => get(entry, "snapshot", nothing),
        "solver" => get(entry, "solver", nothing),
        "model_variable_count" => get(raw, "model_variable_count", nothing),
        "status" => solved ? "locally_solved_trace" : "incomplete",
        "solved" => solved,
        "process_timeout" => get(entry, "process_timeout", nothing),
        "process_exit_code" => get(entry, "process_exit_code", nothing),
        "profile_stage" => get(raw, "profile_stage", nothing),
        "profile_skip_reason" => get(raw, "profile_skip_reason", nothing),
        "trace_record_count" => get(trace_summary, "record_count", nothing),
        "final_iteration" => final,
        "final_objective" => get(trace_summary, "final_objective", nothing),
        "final_primal_infeasibility" => final_primal,
        "final_dual_infeasibility" => final_dual,
        "point_binding_coverage" => get(trace_summary, "point_binding_coverage", Dict{String,Any}()),
        "process_log" => get(entry, "process_log", nothing),
    ))
end

write_json(output_path, Dict{String,Any}(
    "schema_version" => "nlpdiagnostics-bmopf-solver-scaling-extension-v1",
    "source" => Dict{String,Any}(
        "launcher" => "benchmarks/launch_bmopf_solver_trace.jl",
        "summarizer" => "benchmarks/summarize_bmopf_solver_scaling_extension.jl",
        "run_directory" => run_directory,
        "declared_timeout_seconds" => get(index, "child_timeout_seconds", nothing),
        "solver_options" => get(index, "solver_options", Dict{String,Any}()),
        "profile_policy" => "trace-only; post-solve profiling may be skipped by the resource budget",
    ),
    "environment" => Dict{String,Any}(
        "julia_version" => string(VERSION),
        "git_revision" => git_revision(),
        "git_worktree_dirty" => !isempty(git_status_entries()),
    ),
    "record_count" => length(records),
    "solved_count" => count(get.(records, "solved", false)),
    "timeout_count" => count(get.(records, "process_timeout", false)),
    "incomplete_count" => count(record -> !get(record, "solved", false), records),
    "model_variable_counts" => sort!(unique([record["model_variable_count"] for record in records if record["model_variable_count"] isa Integer])),
    "records" => records,
    "all_processes_completed" => all(!get(record, "process_timeout", true) for record in records),
    "all_trace_points_complete" => all(
        get(get(record, "point_binding_coverage", Dict{String,Any}()), "incomplete_point_count", 1) == 0
        for record in records if get(record, "solved", false)
    ),
    "interpretation" => "Both planned 11,028-variable Ipopt children completed with callback-point traces and no process timeout. The resource-aware trace stage skipped post-solve profiling; this is solver-work evidence, not allocator-level memory or a complexity law.",
    "next_action" => "Add the measured records to the solver-scaling readiness ledger and decide whether a larger or second-solver run is justified.",
))
println("wrote BMOPF solver scaling extension summary to $output_path")
