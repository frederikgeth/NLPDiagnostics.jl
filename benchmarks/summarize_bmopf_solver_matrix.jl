#!/usr/bin/env julia

"""Summarize a BMOPF solver matrix and generate pairwise comparisons.

The report is evidence-preserving: each solver keeps its original summary and
each comparison is retained as a nested artifact. Missing summaries or failed
comparison subprocesses are recorded explicitly rather than treated as empty
or successful evidence.
"""

using JSON

function _int(value, default = 0)
    value isa Integer && return Int(value)
    value isa Number && isfinite(Float64(value)) && return Int(value)
    value isa AbstractString || return default
    try parse(Int, value) catch; default end
end

function _as_dict(value)
    value isa AbstractDict || return Dict{String,Any}()
    return Dict{String,Any}(string(k) => v for (k, v) in value)
end

function _enabled(value)
    value === true && return true
    lowercase(string(value)) in ("true", "1", "yes", "on")
end

"""Collect paired model-variant evidence from full solver summaries.

This is intentionally descriptive. It counts repeated observations across
cases/solvers but does not convert them into a causal score or claim that an
incomplete family omission is a physically valid formulation.
"""
function _family_matrix_summary(full_summaries)
    variants = Dict{String,Any}[]
    status_counts = Dict{String,Int}()
    termination_counts = Dict{String,Int}()
    by_family = Dict{String,Any}()
    for (solver, summary) in full_summaries
        enabled = _enabled(get(summary, "family_perturbations_enabled", false))
        enabled || continue
        for case in get(summary, "cases", Any[])
            case isa AbstractDict || continue
            case_name = String(get(case, "name", get(case, "snapshot", "unknown")))
            family_summary = _as_dict(get(case, "family_perturbation", nothing))
            baseline_summary = _as_dict(get(family_summary, "baseline", nothing))
            baseline_termination = get(baseline_summary, "termination", "unknown")
            baseline_iterations = get(baseline_summary, "iteration_count", nothing)
            for (family_raw, details_raw) in _as_dict(get(family_summary, "by_family", Dict()))
                family = String(family_raw)
                details = _as_dict(details_raw)
                status = String(get(details, "status", "unknown"))
                termination = String(get(details, "termination", "unknown"))
                changed = get(details, "termination_changed_vs_baseline", nothing)
                delta = get(details, "iteration_delta_vs_baseline", nothing)
                record = Dict{String,Any}(
                    "solver" => String(solver), "case" => case_name,
                    "family" => family, "status" => status,
                    "termination" => termination,
                    "baseline_termination" => baseline_termination,
                    "baseline_iteration_count" => baseline_iterations,
                    "termination_changed_vs_baseline" => changed,
                    "iteration_delta_vs_baseline" => delta,
                    "model_variable_count" => get(details, "model_variable_count", nothing),
                    "row_family_perturbation" => get(details, "row_family_perturbation", Dict()),
                )
                push!(variants, record)
                status_counts[status] = get(status_counts, status, 0) + 1
                termination_counts[termination] = get(termination_counts, termination, 0) + 1
                aggregate = get!(by_family, family, Dict{String,Any}(
                    "variant_count" => 0, "case_count" => 0,
                    "status_counts" => Dict{String,Int}(),
                    "termination_counts" => Dict{String,Int}(),
                    "baseline_termination_counts" => Dict{String,Int}(),
                    "termination_changed_count" => 0,
                    "iteration_deltas" => Any[],
                    "rank_effect_family_counts" => Dict{String,Int}(),
                ))
                aggregate["variant_count"] += 1
                aggregate["case_count"] += 1
                statuses = aggregate["status_counts"]
                statuses[status] = get(statuses, status, 0) + 1
                terminations = aggregate["termination_counts"]
                terminations[termination] = get(terminations, termination, 0) + 1
                baselines = aggregate["baseline_termination_counts"]
                baselines[String(baseline_termination)] = get(baselines, String(baseline_termination), 0) + 1
                changed === true && (aggregate["termination_changed_count"] += 1)
                delta isa Number && push!(aggregate["iteration_deltas"], delta)
                row = _as_dict(get(details, "row_family_perturbation", nothing))
                effect_count = _int(get(row, "rank_effect_family_count", 0)) +
                               _int(get(row, "sparse_pattern_effect_family_count", 0))
                effect_count > 0 && (aggregate["rank_effect_family_counts"][String(solver)] =
                    get(aggregate["rank_effect_family_counts"], String(solver), 0) + effect_count)
            end
        end
    end
    repeatability = Dict{String,Any}()
    for (family, aggregate_raw) in by_family
        aggregate = _as_dict(aggregate_raw)
        count = _int(get(aggregate, "variant_count", 0))
        changed = _int(get(aggregate, "termination_changed_count", 0))
        repeatability[family] = Dict{String,Any}(
            "observations" => count,
            "termination_change_observations" => changed,
            "same_termination_change_direction" => count >= 2 && (changed == 0 || changed == count),
            "interpretation" => "Descriptive repeatability across completed variants; not a causal or physical validity claim.",
        )
    end
    return Dict{String,Any}(
        "variant_count" => length(variants),
        "status_counts" => status_counts,
        "termination_counts" => termination_counts,
        "by_family" => by_family,
        "repeatability" => repeatability,
        "variants" => variants,
    )
end

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
        "family_perturbations_enabled" => get(summary, "family_perturbations_enabled", false),
        "family_perturbation_families" => get(summary, "family_perturbation_families", Any[]),
        "family_perturbation_status_counts" => get(summary, "family_perturbation_status_counts", Dict()),
        "family_perturbation_termination_counts" => get(summary, "family_perturbation_termination_counts", Dict()),
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
    full_summaries = Dict{String,Any}()
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
            full_summaries[solver] = summary
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
        "family_perturbations_enabled" => get(index, "family_perturbations_enabled", false),
        "family_perturbation_families" => get(index, "family_perturbation_families", Any[]),
        "family_perturbation_max_iter" => get(index, "family_perturbation_max_iter", nothing),
        "family_perturbation_matrix" => _family_matrix_summary(full_summaries),
        "comparisons" => comparisons,
    )))
    println("wrote BMOPF solver matrix summary to $output_path")
end

main()
