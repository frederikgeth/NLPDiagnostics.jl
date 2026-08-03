#!/usr/bin/env julia

"""Summarize `bmopf_solver_trace.jl` records without reducing them to a score."""

using JSON

_as_dict(value) = value isa AbstractDict ?
    Dict{String,Any}(string(k) => v for (k, v) in value) : Dict{String,Any}()

function _count_codes(report)
    counts = Dict{String,Int}()
    report isa AbstractDict || return counts
    for finding in get(report, "findings", Any[])
        code = String(get(finding, "code", "unknown"))
        counts[code] = get(counts, code, 0) + 1
    end
    return counts
end

function _merge_counts!(target, source)
    for (key, value) in source
        target[key] = get(target, key, 0) + value
    end
    return target
end

function _trace_summary(trace)
    records = get(trace, "records", Any[])
    phases = Dict{String,Int}()
    formats = Dict{String,Int}()
    primal = Float64[]
    dual = Float64[]
    for record in records
        phase = String(get(record, "phase", "unknown"))
        format = String(get(record, "format", "unknown"))
        phases[phase] = get(phases, phase, 0) + 1
        formats[format] = get(formats, format, 0) + 1
        p = get(record, "primal_infeasibility", nothing)
        d = get(record, "dual_infeasibility", nothing)
        p isa Real && isfinite(p) && push!(primal, Float64(p))
        d isa Real && isfinite(d) && push!(dual, Float64(d))
    end
    final = isempty(records) ? nothing : last(records)
    return Dict{String,Any}(
        "record_count" => length(records),
        "segment_count" => get(trace, "segment_count", nothing),
        "binding_count" => get(trace, "binding_count", nothing),
        "phase_counts" => phases,
        "format_counts" => formats,
        "first_iteration" => isempty(records) ? nothing : get(first(records), "iteration", nothing),
        "final_iteration" => isnothing(final) ? nothing : get(final, "iteration", nothing),
        "final_objective" => isnothing(final) ? nothing : get(final, "objective", nothing),
        "final_primal_infeasibility" => isnothing(final) ? nothing : get(final, "primal_infeasibility", nothing),
        "final_dual_infeasibility" => isnothing(final) ? nothing : get(final, "dual_infeasibility", nothing),
        "minimum_primal_infeasibility" => isempty(primal) ? nothing : minimum(primal),
        "minimum_dual_infeasibility" => isempty(dual) ? nothing : minimum(dual),
    )
end

function _failure_categories(record, nested_profile, trace_summary)
    categories = String[]
    postmortem = get(nested_profile, "postmortem", nothing)
    termination = postmortem isa AbstractDict ?
        String(get(postmortem, "termination", "unknown")) : "unknown"
    termination == "slow_progress" && push!(categories, "slow_progress")
    termination == "restoration_failed" && push!(categories, "restoration_failed")
    termination in ("numerical_failure", "invalid_number") &&
        push!(categories, "numerical_failure")
    termination in ("iteration_limit", "time_limit") &&
        push!(categories, "resource_limit")
    termination in ("invalid_model", "invalid_option") &&
        push!(categories, "invalid_configuration")
    phase_counts = _as_dict(get(trace_summary, "phase_counts", nothing))
    get(phase_counts, "restoration", 0) > 0 && push!(categories, "restoration_attempted")
    isempty(categories) && termination in ("locally_optimal", "optimal") &&
        push!(categories, "successful_termination")
    isempty(categories) && push!(categories, "unclassified")
    return unique(categories)
end

function main()
    length(ARGS) in (1, 2) || error(
        "usage: summarize_bmopf_solver_trace.jl <output-directory> [summary.json]",
    )
    output_dir = abspath(ARGS[1])
    index_path = joinpath(output_dir, "index.json")
    isfile(index_path) || error("missing index.json in $output_dir")
    index = JSON.parsefile(index_path)
    cases = Dict{String,Any}[]
    trace_finding_codes = Dict{String,Int}()
    bmopf_finding_codes = Dict{String,Int}()
    failure_category_counts = Dict{String,Int}()
    status_counts = Dict{String,Int}()
    iteration_counts = Int[]
    for entry in get(index, "cases", Any[])
        name = String(get(entry, "name", "unknown"))
        result_file = get(entry, "result_file", nothing)
        result_file isa AbstractString || continue
        path = joinpath(output_dir, result_file)
        isfile(path) || continue
        record = JSON.parsefile(path)
        status = String(get(record, "status", get(entry, "status", "unknown")))
        status_counts[status] = get(status_counts, status, 0) + 1
        summary = Dict{String,Any}(entry)
        summary["status"] = status
        for key in ("solver", "solver_options", "per_unit", "model_coordinate_units",
                    "solver_objective_convention", "objective_comparison_reference",
                    "bmopf_extracted_result_convention", "environment_fingerprint")
            haskey(record, key) && (summary[key] = record[key])
        end
        if status == "ok"
            trace = get(record, "iteration_trace", Dict{String,Any}())
            trace_summary = _trace_summary(trace)
            summary["trace"] = trace_summary
            push!(iteration_counts, Int(get(trace_summary, "record_count", 0)))
            solver_profile = get(record, "solver_profile", Dict{String,Any}())
            nested_profile = get(solver_profile, "solver_profile", Dict{String,Any}())
            summary["failure_categories"] = _failure_categories(
                record, nested_profile, trace_summary,
            )
            for category in summary["failure_categories"]
                failure_category_counts[category] =
                    get(failure_category_counts, category, 0) + 1
            end
            summary["termination"] = get(
                get(nested_profile, "postmortem", Dict{String,Any}()),
                "termination", "unknown",
            )
            result_report = get(nested_profile, "result_report", Dict{String,Any}())
            summary["solver_result_finding_codes"] = _count_codes(result_report)
            _merge_counts!(trace_finding_codes, summary["solver_result_finding_codes"])
            bmopf_profile = get(record, "bmopf_profile", nothing)
            if bmopf_profile isa AbstractDict
                context_report = get(bmopf_profile, "bmopf_context_report", nothing)
                summary["bmopf_context_finding_codes"] = _count_codes(context_report)
                _merge_counts!(bmopf_finding_codes, summary["bmopf_context_finding_codes"])
            else
                summary["bmopf_context_finding_codes"] = Dict{String,Int}()
            end
        end
        push!(cases, summary)
    end
    summary_path = length(ARGS) == 2 ? abspath(ARGS[2]) : joinpath(output_dir, "summary.json")
    payload = Dict{String,Any}(
        "runner_version" => get(index, "runner_version", nothing),
        "solver" => get(index, "solver", nothing),
        "environment" => get(index, "environment", nothing),
        "environment_fingerprint" => get(index, "environment_fingerprint", nothing),
        "status_counts" => status_counts,
        "successful_case_count" => get(status_counts, "ok", 0),
        "iteration_count_total" => sum(iteration_counts; init = 0),
        "iteration_count_minimum" => isempty(iteration_counts) ? nothing : minimum(iteration_counts),
        "iteration_count_maximum" => isempty(iteration_counts) ? nothing : maximum(iteration_counts),
        "solver_result_finding_codes" => trace_finding_codes,
        "bmopf_context_finding_codes" => bmopf_finding_codes,
        "failure_category_counts" => failure_category_counts,
        "cases" => cases,
    )
    write(summary_path, JSON.json(payload))
    println("wrote solver-trace summary to $summary_path")
end

main()
