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

function _merge_int_counts!(target, source)
    source isa AbstractDict || return target
    for (key, value) in source
        target[String(key)] = get(target, String(key), 0) + _int(value)
    end
    return target
end

"""Aggregate controller transition and registry evidence across solver pairs."""
function _controller_matrix_summary(comparisons)
    records = Any[]
    registry_status_counts = Dict("left" => Dict{String,Int}(),
                                  "right" => Dict{String,Int}())
    unmatched_component_counts = Dict("left" => Dict{String,Int}(),
                                     "right" => Dict{String,Int}())
    residual_violation_counts = Dict("left" => 0, "right" => 0)
    cap_violation_counts = Dict("left" => 0, "right" => 0)
    pair_count = 0
    for (pair_name, raw_pair) in _as_dict(comparisons)
        pair = _as_dict(raw_pair)
        get(pair, "status", "") == "ok" || continue
        nested = _as_dict(get(pair, "comparison", nothing))
        for raw_case in get(nested, "comparisons", Any[])
            case = _as_dict(raw_case)
            comparison = _as_dict(get(case, "comparison", nothing))
            trace = _as_dict(get(comparison, "controller_curve_trace", nothing))
            isempty(trace) && continue
            pair_count += 1
            registry = _as_dict(get(trace, "violation_registry", nothing))
            registry_record = Dict{String,Any}()
            for side in ("left", "right")
                side_view = _as_dict(get(registry, side, nothing))
                statuses = _as_dict(get(side_view, "status_counts", nothing))
                _merge_int_counts!(registry_status_counts[side], statuses)
                components = _as_dict(get(side_view, "components_by_status", nothing))
                unmatched = vcat(get(components, "unregistered", Any[]),
                                 get(components, "not_found", Any[]))
                for component in unmatched
                    key = String(component)
                    unmatched_component_counts[side][key] =
                        get(unmatched_component_counts[side], key, 0) + 1
                end
                registry_record[side] = Dict(
                    "status_counts" => statuses,
                    "unmatched_components" => unmatched,
                )
                residual_pair = _as_dict(get(trace,
                    "equation_residual_violation_counts", nothing))
                cap_pair = _as_dict(get(trace, "cap_violation_counts", nothing))
                residual_violation_counts[side] += _int(get(residual_pair, side, 0))
                cap_violation_counts[side] += _int(get(cap_pair, side, 0))
            end
            push!(records, Dict(
                "pair" => String(pair_name),
                "case" => get(case, "name", nothing),
                "registry" => registry_record,
                "equation_residual_violation_counts" => get(trace,
                    "equation_residual_violation_counts", Dict()),
                "cap_violation_counts" => get(trace, "cap_violation_counts", Dict()),
                "status_changes" => get(trace, "status_changes", Dict()),
                "coverage_changes" => get(trace, "coverage_changes", Dict()),
                "slope_changes" => get(trace, "slope_changes", Dict()),
            ))
        end
    end
    return Dict{String,Any}(
        "paired_case_count" => pair_count,
        "registry_status_counts" => registry_status_counts,
        "unmatched_component_counts" => unmatched_component_counts,
        "equation_residual_violation_counts" => residual_violation_counts,
        "cap_violation_counts" => cap_violation_counts,
        "records" => records,
        "interpretation" => "Aggregated controller evidence across solver pairs; registry boundaries and residuals remain policy-specific observations, not a quality score.",
    )
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
        "trusted_point_selection_counts" => get(summary, "trusted_point_selection_counts", Dict()),
        "source_snapshot_counts" => get(summary, "source_snapshot_counts", Dict()),
        "source_schema_coverage" => get(summary, "source_schema_coverage", Dict()),
        "process_health_counts" => get(summary, "process_health_counts", Dict()),
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
    child_indexes_available = Dict{String,Bool}()
    child_status_counts = Dict{String,Any}()
    process_health = Dict{String,Int}(
        "process_exit_count" => 0,
        "process_timeout_count" => 0,
        "process_wait_error_count" => 0,
        "nonzero_process_exit_count" => 0,
        "process_log_count" => 0,
    )
    for entry in get(index, "entries", Any[])
        entry isa AbstractDict || continue
        get(entry, "status", "") == "process_exit" &&
            (process_health["process_exit_count"] += 1)
        get(entry, "process_timeout", false) === true &&
            (process_health["process_timeout_count"] += 1)
        wait_error = get(entry, "process_wait_error", nothing)
        !(wait_error === nothing || isempty(String(wait_error))) &&
            (process_health["process_wait_error_count"] += 1)
        exit_code = get(entry, "process_exit_code", nothing)
        exit_code isa Number && exit_code != 0 &&
            (process_health["nonzero_process_exit_count"] += 1)
        log_path = get(entry, "process_log", nothing)
        output_directory = get(entry, "output_directory", nothing)
        log_path isa AbstractString && output_directory isa AbstractString &&
            isfile(joinpath(output_directory, log_path)) &&
            (process_health["process_log_count"] += 1)
    end
    for solver in solvers
        child_index_path = joinpath(root, solver, "index.json")
        available = isfile(child_index_path)
        child_indexes_available[solver] = available
        statuses = Dict{String,Int}()
        if available
            child_index = try
                JSON.parsefile(child_index_path)
            catch
                Dict{String,Any}()
            end
            for entry in get(child_index, "cases", Any[])
                entry isa AbstractDict || continue
                status = String(get(entry, "status", "unknown"))
                statuses[status] = get(statuses, status, 0) + 1
            end
        end
        child_status_counts[solver] = statuses
    end
    all_child_cases_successful = all(
        get(child_indexes_available, solver, false) &&
        !isempty(get(child_status_counts, solver, Dict())) &&
        all(String(status) == "ok" for status in keys(get(child_status_counts, solver, Dict())) )
        for solver in solvers
    )
    comparisons_available = !isempty(comparisons) &&
        all(get(comparison, "status", "unknown") == "ok" for comparison in values(comparisons))
    trusted_solver_results = !isempty(solvers) && all(begin
        summary = get(full_summaries, solver, Dict())
        counts = _as_dict(get(summary, "trusted_point_selection_counts", nothing))
        successful = _int(get(summary, "successful_case_count", 0))
        successful > 0 &&
            (_int(get(counts, "successful_cases_with_trusted_solver_result_points", 0)) == successful &&
             _int(get(counts, "successful_cases_with_incomplete_solver_result_points", 0)) == 0 &&
             _int(get(counts, "successful_cases_missing_solver_result_trust_metadata", 0)) == 0)
    end for solver in solvers)
    solver_process_health = process_health["process_exit_count"] == 0 &&
                            process_health["process_timeout_count"] == 0 &&
                            process_health["process_wait_error_count"] == 0 &&
                            process_health["nonzero_process_exit_count"] == 0
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
        "controller_curve_matrix" => _controller_matrix_summary(comparisons),
        "readiness" => Dict(
            "child_indexes_available" => !isempty(solvers) &&
                                          all(values(child_indexes_available)),
            "solver_children_successful" => !isempty(solvers) && all_child_cases_successful,
            "pairwise_comparisons_available" => comparisons_available,
            "summary_errors_absent" => isempty(summary_errors),
            "trusted_solver_result_points" => trusted_solver_results,
            "solver_process_health" => solver_process_health,
        ),
        "child_status_counts" => child_status_counts,
        "process_health" => process_health,
    )))
    println("wrote BMOPF solver matrix summary to $output_path")
end

main()
