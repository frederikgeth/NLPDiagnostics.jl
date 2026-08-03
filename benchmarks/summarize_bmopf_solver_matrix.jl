#!/usr/bin/env julia

"""Summarize a BMOPF solver matrix and generate pairwise comparisons.

The report is evidence-preserving: each solver keeps its original summary and
each comparison is retained as a nested artifact. Missing summaries or failed
comparison subprocesses are recorded explicitly rather than treated as empty
or successful evidence.
"""

using JSON

function _run_summary(output_dir, project)
    summary_script = joinpath(@__DIR__, "summarize_bmopf_solver_trace.jl")
    summary_path = joinpath(output_dir, "summary.json")
    isfile(summary_path) && return (path = summary_path, error = nothing)
    julia = Base.julia_cmd()
    command = isnothing(project) ?
        `$julia --startup-file=no $summary_script $output_dir $summary_path` :
        `$julia --startup-file=no --project=$project $summary_script $output_dir $summary_path`
    try
        run(setenv(command, copy(ENV)))
        return (path = summary_path, error = nothing)
    catch error
        return (path = nothing, error = sprint(showerror, error))
    end
end

function _compare(left_path, right_path, output_path, project)
    compare_script = joinpath(@__DIR__, "compare_bmopf_solver_traces.jl")
    julia = Base.julia_cmd()
    command = isnothing(project) ?
        `$julia --startup-file=no $compare_script $left_path $right_path $output_path` :
        `$julia --startup-file=no --project=$project $compare_script $left_path $right_path $output_path`
    try
        run(setenv(command, copy(ENV)))
        return nothing
    catch error
        return sprint(showerror, error)
    end
end

function _compact_summary(summary)
    return Dict{String,Any}(
        "runner_version" => get(summary, "runner_version", nothing),
        "solver" => get(summary, "solver", nothing),
        "environment_fingerprint" => get(summary, "environment_fingerprint", nothing),
        "status_counts" => get(summary, "status_counts", Dict()),
        "successful_case_count" => get(summary, "successful_case_count", 0),
        "iteration_count_total" => get(summary, "iteration_count_total", 0),
        "iteration_count_minimum" => get(summary, "iteration_count_minimum", nothing),
        "iteration_count_maximum" => get(summary, "iteration_count_maximum", nothing),
        "failure_category_counts" => get(summary, "failure_category_counts", Dict()),
        "solver_log_evidence_case_count" => get(summary, "solver_log_evidence_case_count", 0),
        "solver_log_observation_count" => get(summary, "solver_log_observation_count", 0),
        "solver_log_iteration_count" => get(summary, "solver_log_iteration_count", 0),
        "solver_log_finding_codes" => get(summary, "solver_log_finding_codes", Dict()),
        "summary_path" => nothing,
    )
end

function main()
    length(ARGS) in (1, 2) || error(
        "usage: summarize_bmopf_solver_matrix.jl <matrix-output> [matrix-summary.json]",
    )
    root = abspath(ARGS[1])
    index_path = joinpath(root, "matrix_index.json")
    isfile(index_path) || error("missing matrix_index.json in $root")
    index = JSON.parsefile(index_path)
    solvers = String.(get(index, "solvers", String[]))
    isempty(solvers) && error("matrix_index.json contains no solvers")
    project_raw = get(ENV, "NLPDIAGNOSTICS_BENCHMARK_PROJECT", "")
    project = isempty(project_raw) ? Base.active_project() : abspath(project_raw)
    summaries = Dict{String,Any}()
    summary_paths = Dict{String,String}()
    summary_errors = Dict{String,String}()
    for solver in solvers
        solver_dir = joinpath(root, solver)
        result = _run_summary(solver_dir, project)
        if isnothing(result.path)
            summary_errors[solver] = result.error
            summaries[solver] = _compact_summary(Dict{String,Any}())
        else
            summary_paths[solver] = result.path
            summary = JSON.parsefile(result.path)
            compact = _compact_summary(summary)
            compact["summary_path"] = result.path
            summaries[solver] = compact
        end
    end
    comparison_dir = joinpath(root, "comparisons")
    mkpath(comparison_dir)
    comparisons = Dict{String,Any}()
    for left_index in 1:length(solvers), right_index in (left_index + 1):length(solvers)
        left = solvers[left_index]
        right = solvers[right_index]
        key = "$(left)__vs__$(right)"
        if !haskey(summary_paths, left) || !haskey(summary_paths, right)
            comparisons[key] = Dict{String,Any}(
                "status" => "missing_summary",
                "left" => left,
                "right" => right,
            )
            continue
        end
        output_path = joinpath(comparison_dir, "$key.json")
        error_text = _compare(summary_paths[left], summary_paths[right], output_path, project)
        if isnothing(error_text) && isfile(output_path)
            comparisons[key] = Dict{String,Any}(
                "status" => "ok",
                "left" => left,
                "right" => right,
                "path" => output_path,
                "comparison" => JSON.parsefile(output_path),
            )
        else
            comparisons[key] = Dict{String,Any}(
                "status" => "comparison_error",
                "left" => left,
                "right" => right,
                "path" => output_path,
                "error" => something(error_text, "comparison output missing"),
            )
        end
    end
    output_path = length(ARGS) == 2 ? abspath(ARGS[2]) : joinpath(root, "matrix_summary.json")
    write(output_path, JSON.json(Dict(
        "runner_version" => get(index, "runner_version", nothing),
        "matrix_index" => index_path,
        "benchmark_root" => get(index, "benchmark_root", nothing),
        "solvers" => solvers,
        "cases" => get(index, "cases", Any[]),
        "child_timeout_seconds" => get(index, "child_timeout_seconds", nothing),
        "environment" => get(index, "environment", nothing),
        "solver_summaries" => summaries,
        "summary_errors" => summary_errors,
        "comparisons" => comparisons,
    )))
    println("wrote BMOPF solver matrix summary to $output_path")
end

main()
