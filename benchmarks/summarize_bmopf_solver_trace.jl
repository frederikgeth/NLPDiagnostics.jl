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

function _integer_value(value, default = 0)
    value isa Integer && return Int(value)
    try
        return parse(Int, String(value))
    catch
        return default
    end
end

function _log_iteration_summary(report)
    report isa AbstractDict || return Dict{String,Any}()
    metadata = get(report, "metadata", nothing)
    metadata isa AbstractDict || return Dict{String,Any}()
    result = Dict{String,Any}()
    function normalized(value)
        value isa Number && return value
        value isa AbstractString || return value
        try
            return parse(Int, value)
        catch
        end
        try
            return parse(Float64, value)
        catch
            return value
        end
    end
    for (output, key) in (
        "record_count" => "parsed_iteration_count",
        "segment_count" => "iteration_segment_count",
        "final_iteration" => "final_parsed_iteration",
        "final_primal_infeasibility" => "final_logged_primal_infeasibility",
        "final_dual_infeasibility" => "final_logged_dual_infeasibility",
        "minimum_primal_infeasibility" => "minimum_logged_primal_infeasibility",
        "minimum_dual_infeasibility" => "minimum_logged_dual_infeasibility",
    )
        value = get(metadata, key, nothing)
        isnothing(value) || (result[output] = normalized(value))
    end
    return result
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

"""Summarize controller-curve persistence evidence retained beside a trace."""
function _current_law_trace_summary(current_law_trace)
    current_law_trace isa AbstractDict || return Dict{String,Any}(
        "available" => false,
    )
    persistence = get(current_law_trace, "persistence_report", Dict())
    persistence isa AbstractDict || (persistence = Dict())
    metadata = get(persistence, "metadata", Dict())
    metadata isa AbstractDict || (metadata = Dict())
    finding_codes = _count_codes(persistence)
    controller_snapshots = get(current_law_trace, "controller_curve_snapshots", Any[])
    controller_snapshots isa AbstractVector || (controller_snapshots = Any[])
    family_counts = Dict{String,Int}()
    status_counts = Dict{String,Int}()
    semantics_counts = Dict{String,Int}()
    slopes = Float64[]
    breakpoint_distances = Float64[]
    residuals = Float64[]
    observation_count = 0
    for snapshot in controller_snapshots
        snapshot isa AbstractDict || continue
        observations = get(snapshot, "observations", Any[])
        observations isa AbstractVector || continue
        for observation in observations
            observation isa AbstractDict || continue
            observation_count += 1
            for (field, destination) in (
                ("curve_family", family_counts),
                ("status", status_counts),
                ("monitor_semantics", semantics_counts),
            )
                value = get(observation, field, nothing)
                value === nothing && continue
                key = String(value)
                destination[key] = get(destination, key, 0) + 1
            end
            for (field, destination) in (
                ("local_slope", slopes),
                ("breakpoint_distance", breakpoint_distances),
                ("equation_residual", residuals),
            )
                value = get(observation, field, nothing)
                value isa Number || continue
                isfinite(Float64(value)) || continue
                push!(destination, field == "equation_residual" ? abs(Float64(value)) : Float64(value))
            end
        end
    end
    result = Dict{String,Any}(
        "available" => true,
        "selected_binding_count" => get(
            get(current_law_trace, "metadata", Dict()),
            "trace_selected_binding_count", nothing,
        ),
        "snapshot_count" => get(metadata,
            "bmopf_current_law_operating_point_snapshot_count", nothing),
        "controller_curve_status_changes" => get(metadata,
            "bmopf_controller_curve_changed_status_count", "0"),
        "controller_curve_coverage_changes" => get(metadata,
            "bmopf_controller_curve_changed_coverage_count", "0"),
        "controller_curve_slope_changes" => get(metadata,
            "bmopf_controller_curve_changed_slope_count", "0"),
        "finding_codes" => finding_codes,
        "controller_curve_snapshot_count" => length(controller_snapshots),
        "controller_curve_observation_count" => observation_count,
        "controller_curve_family_counts" => family_counts,
        "controller_curve_status_counts" => status_counts,
        "controller_curve_monitor_semantics_counts" => semantics_counts,
        "controller_curve_local_slope" => _metric_summary(slopes),
        "controller_curve_breakpoint_distance" => _metric_summary(breakpoint_distances),
        "controller_curve_absolute_equation_residual" => _metric_summary(residuals),
    )
    return result
end

function _metric_summary(values::AbstractVector{<:Real})
    isempty(values) && return nothing
    return Dict{String,Any}(
        "sample_count" => length(values),
        "minimum" => minimum(values),
        "mean" => sum(values) / length(values),
        "maximum" => maximum(values),
    )
end

function _finding_rows(finding)
    rows = Set{Int}()
    for evidence in get(finding, "evidence", Any[])
        details = get(evidence, "details", Dict())
        details isa AbstractDict || continue
        for key in ("support_rows", "rows", "equality_rows")
            raw = get(details, key, nothing)
            raw isa AbstractString || continue
            for token in split(raw, ',')
                parsed = tryparse(Int, strip(token))
                isnothing(parsed) || push!(rows, parsed)
            end
        end
    end
    return rows
end

function _rank_semantic_family_counts(result_report, semantic_rows)
    counts = Dict{String,Dict{String,Int}}()
    semantic_rows isa AbstractDict || return counts
    for finding in get(result_report, "findings", Any[])
        code = String(get(finding, "code", "unknown"))
        rows = _finding_rows(finding)
        isempty(rows) && continue
        family_counts = get!(counts, code, Dict{String,Int}())
        for row in rows
            descriptor = get(semantic_rows, string(row), nothing)
            descriptor isa AbstractDict || continue
            family = String(get(descriptor, "constraint_family", "unregistered_constraint"))
            family_counts[family] = get(family_counts, family, 0) + 1
        end
    end
    return counts
end

function _profile_finding_codes(profile)
    counts = Dict{String,Int}()
    profile isa AbstractDict || return counts
    reports = get(profile, "reports", Dict())
    reports isa AbstractDict || return counts
    for report in values(reports)
        _merge_counts!(counts, _count_codes(report))
    end
    return counts
end

function _rank_profile_findings(profile)
    profile isa AbstractDict || return Any[]
    reports = get(profile, "reports", Dict())
    reports isa AbstractDict || return Any[]
    findings = Any[]
    for report in values(reports)
        report isa AbstractDict || continue
        for finding in get(report, "findings", Any[])
            code = String(get(finding, "code", ""))
            (startswith(code, "candidate_") || startswith(code, "unexpected_") ||
             occursin("rank", code) || startswith(code, "zero_jacobian")) || continue
            push!(findings, finding)
        end
    end
    return findings
end

function _row_family_perturbation_summary(report)
    report isa AbstractDict || return Dict{String,Any}()
    metadata = get(report, "metadata", Dict())
    metadata isa AbstractDict || (metadata = Dict())
    counts = _count_codes(report)
    families = Dict{String,Int}()
    for finding in get(report, "findings", Any[])
        code = String(get(finding, "code", "unknown"))
        code in (
            "jacobian_row_family_perturbation_rank_effect",
            "jacobian_row_family_perturbation_no_rank_effect",
            "jacobian_row_family_perturbation_sparse_pattern_effect",
            "jacobian_row_family_perturbation_sparse_pattern_no_rank_effect",
            "jacobian_row_family_perturbation_unavailable",
        ) || continue
        for evidence in get(finding, "evidence", Any[])
            details = get(evidence, "details", Dict())
            details isa AbstractDict || continue
            family = get(details, "family", nothing)
            isnothing(family) || (families[String(family)] = get(families, String(family), 0) + 1)
        end
    end
    return Dict{String,Any}(
        "baseline_rank_available" => get(metadata, "baseline_rank_available", nothing),
        "baseline_rank" => get(metadata, "baseline_rank", nothing),
        "baseline_right_nullity" => get(metadata, "baseline_right_nullity", nothing),
        "row_family_count" => get(metadata, "row_family_count", nothing),
        "rank_effect_family_count" => get(metadata, "rank_effect_family_count", nothing),
        "no_rank_effect_family_count" => get(metadata, "no_rank_effect_family_count", nothing),
        "sparse_pattern_effect_family_count" => get(metadata, "sparse_pattern_effect_family_count", nothing),
        "sparse_pattern_no_rank_effect_family_count" => get(metadata, "sparse_pattern_no_rank_effect_family_count", nothing),
        "finding_codes" => counts,
        "family_counts" => families,
    )
end

function _family_perturbation_case_summary(record)
    variants = get(record, "family_perturbations", Any[])
    variants isa AbstractVector || return Dict{String,Any}()
    status_counts = Dict{String,Int}()
    termination_counts = Dict{String,Int}()
    by_family = Dict{String,Any}()
    baseline_trace = _trace_summary(get(record, "iteration_trace", Dict()))
    baseline_profile = get(record, "solver_profile", Dict())
    baseline_nested = baseline_profile isa AbstractDict ?
        get(baseline_profile, "solver_profile", Dict()) : Dict()
    baseline_postmortem = baseline_nested isa AbstractDict ?
        get(baseline_nested, "postmortem", Dict()) : Dict()
    baseline_termination = baseline_postmortem isa AbstractDict ?
        String(get(baseline_postmortem, "termination", "unknown")) : "unknown"
    baseline_iteration_count = _integer_value(get(baseline_trace, "record_count", 0))
    for variant in variants
        variant isa AbstractDict || continue
        family = String(get(variant, "family", "unknown"))
        status = String(get(variant, "status", "unknown"))
        status_counts[status] = get(status_counts, status, 0) + 1
        solver_profile = get(variant, "solver_profile", Dict())
        nested = solver_profile isa AbstractDict ?
            get(solver_profile, "solver_profile", Dict()) : Dict()
        postmortem = nested isa AbstractDict ? get(nested, "postmortem", Dict()) : Dict()
        termination = postmortem isa AbstractDict ?
            String(get(postmortem, "termination", "unknown")) : "unknown"
        termination_counts[termination] = get(termination_counts, termination, 0) + 1
        row_summary = _row_family_perturbation_summary(
            get(variant, "bmopf_row_family_perturbation_report", nothing),
        )
        variant_trace = _trace_summary(get(variant, "iteration_trace", Dict()))
        variant_iteration_count = _integer_value(get(variant_trace, "record_count", 0))
        by_family[family] = Dict{String,Any}(
            "status" => status,
            "termination" => termination,
            "iteration_count" => variant_iteration_count,
            "iteration_delta_vs_baseline" => variant_iteration_count - baseline_iteration_count,
            "termination_changed_vs_baseline" => termination != baseline_termination,
            "model_variable_count" => get(variant, "model_variable_count", nothing),
            "row_family_perturbation" => row_summary,
            "error" => get(variant, "error", nothing),
        )
    end
    return Dict{String,Any}(
        "variant_count" => length(variants),
        "baseline" => Dict{String,Any}(
            "termination" => baseline_termination,
            "iteration_count" => baseline_trace["record_count"],
            "model_variable_count" => get(record, "model_variable_count", nothing),
        ),
        "status_counts" => status_counts,
        "termination_counts" => termination_counts,
        "by_family" => by_family,
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
    solver_log_evidence_case_count = 0
    solver_log_observation_count = 0
    solver_log_finding_codes = Dict{String,Int}()
    solver_log_iteration_count = 0
    solver_log_iteration_segment_count = 0
    rank_semantic_family_counts = Dict{String,Dict{String,Int}}()
    row_family_perturbation_code_counts = Dict{String,Int}()
    row_family_perturbation_family_counts = Dict{String,Int}()
    family_perturbation_status_counts = Dict{String,Int}()
    family_perturbation_termination_counts = Dict{String,Int}()
    family_perturbation_by_family = Dict{String,Any}()
    bmopf_profile_finding_codes = Dict{String,Int}()
    controller_curve_trace_finding_codes = Dict{String,Int}()
    controller_curve_trace_status_changes = Int[]
    controller_curve_trace_coverage_changes = Int[]
    controller_curve_trace_slope_changes = Int[]
    controller_curve_trace_observation_counts = Int[]
    controller_curve_trace_family_counts = Dict{String,Int}()
    controller_curve_trace_status_counts = Dict{String,Int}()
    controller_curve_trace_semantics_counts = Dict{String,Int}()
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
        family_perturbation = _family_perturbation_case_summary(record)
        summary["family_perturbation"] = family_perturbation
        _merge_counts!(family_perturbation_status_counts,
            get(family_perturbation, "status_counts", Dict()))
        _merge_counts!(family_perturbation_termination_counts,
            get(family_perturbation, "termination_counts", Dict()))
        for (family, details) in get(family_perturbation, "by_family", Dict())
            family_perturbation_by_family[family] = details
        end
        for key in ("solver", "solver_options", "per_unit", "model_coordinate_units",
                    "solver_objective_convention", "objective_comparison_reference",
                    "bmopf_extracted_result_convention", "environment_fingerprint",
                    "sweep_label", "run_id", "replicate_index", "capture_logs")
            haskey(record, key) && (summary[key] = record[key])
        end
        if status == "ok"
            trace = get(record, "iteration_trace", Dict{String,Any}())
            trace_summary = _trace_summary(trace)
            summary["trace"] = trace_summary
            controller_curve_trace = _current_law_trace_summary(
                get(record, "current_law_trace", nothing),
            )
            summary["current_law_trace"] = controller_curve_trace
            if get(controller_curve_trace, "available", false)
                _merge_counts!(controller_curve_trace_finding_codes,
                    get(controller_curve_trace, "finding_codes", Dict()))
                raw_observation_count = get(controller_curve_trace,
                    "controller_curve_observation_count", nothing)
                try
                    raw_observation_count !== nothing && push!(
                        controller_curve_trace_observation_counts,
                        parse(Int, string(raw_observation_count)),
                    )
                catch
                end
                for (field, destination) in (
                    ("controller_curve_family_counts", controller_curve_trace_family_counts),
                    ("controller_curve_status_counts", controller_curve_trace_status_counts),
                    ("controller_curve_monitor_semantics_counts", controller_curve_trace_semantics_counts),
                )
                    _merge_counts!(destination, get(controller_curve_trace, field, Dict()))
                end
                for (key, destination) in (
                    ("controller_curve_status_changes", controller_curve_trace_status_changes),
                    ("controller_curve_coverage_changes", controller_curve_trace_coverage_changes),
                    ("controller_curve_slope_changes", controller_curve_trace_slope_changes),
                )
                    raw = get(controller_curve_trace, key, nothing)
                    try
                        raw !== nothing && push!(destination, parse(Int, string(raw)))
                    catch
                    end
                end
            end
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
                profile_codes = _profile_finding_codes(
                    get(bmopf_profile, "profile", nothing),
                )
                summary["bmopf_profile_finding_codes"] = profile_codes
                _merge_counts!(bmopf_profile_finding_codes, profile_codes)
                profile_rank_report = Dict{String,Any}(
                    "findings" => _rank_profile_findings(
                        get(bmopf_profile, "profile", nothing),
                    ),
                )
                semantic_families = _rank_semantic_family_counts(
                    Dict{String,Any}(
                        "findings" => vcat(
                            get(result_report, "findings", Any[]),
                            get(profile_rank_report, "findings", Any[]),
                        ),
                    ),
                    get(bmopf_profile, "bmopf_constraint_semantic_rows", nothing),
                )
                summary["solver_rank_semantic_family_counts"] = semantic_families
                for (code, families) in semantic_families
                    aggregate = get!(rank_semantic_family_counts, code, Dict{String,Int}())
                    _merge_counts!(aggregate, families)
                end
                perturbation = get(
                    bmopf_profile, "bmopf_row_family_perturbation_report", nothing,
                )
                perturbation_summary = _row_family_perturbation_summary(perturbation)
                summary["bmopf_row_family_perturbation"] = perturbation_summary
                _merge_counts!(row_family_perturbation_code_counts,
                    get(perturbation_summary, "finding_codes", Dict()))
                _merge_counts!(row_family_perturbation_family_counts,
                    get(perturbation_summary, "family_counts", Dict()))
                context_report = get(bmopf_profile, "bmopf_context_report", nothing)
                summary["bmopf_context_finding_codes"] = _count_codes(context_report)
                _merge_counts!(bmopf_finding_codes, summary["bmopf_context_finding_codes"])
            else
                summary["bmopf_context_finding_codes"] = Dict{String,Int}()
                summary["bmopf_profile_finding_codes"] = Dict{String,Int}()
                summary["solver_rank_semantic_family_counts"] = Dict{String,Dict{String,Int}}()
                summary["bmopf_row_family_perturbation"] = Dict{String,Any}()
            end
        end
        solver_log = get(record, "solver_log_evidence", nothing)
        summary["solver_log_available"] = solver_log isa AbstractDict
        summary["solver_log_path"] = get(record, "solver_log_path", nothing)
        if solver_log isa AbstractDict
            solver_log_evidence_case_count += 1
            raw = get(solver_log, "raw", nothing)
            raw_metadata = raw isa AbstractDict ? get(raw, "metadata", nothing) : nothing
            if raw_metadata isa AbstractDict
                solver_log_observation_count += _integer_value(
                    get(raw_metadata, "recognized_log_observation_count", 0),
                )
            end
            _merge_counts!(solver_log_finding_codes, _count_codes(raw))
            iterations = get(solver_log, "iterations", nothing)
            _merge_counts!(solver_log_finding_codes, _count_codes(iterations))
            summary["solver_log_finding_codes"] = _count_codes(raw)
            _merge_counts!(summary["solver_log_finding_codes"], _count_codes(iterations))
            iteration_summary = _log_iteration_summary(iterations)
            summary["solver_log_iterations"] = iteration_summary
            solver_log_iteration_count += _integer_value(
                get(iteration_summary, "record_count", 0),
            )
            solver_log_iteration_segment_count += _integer_value(
                get(iteration_summary, "segment_count", 0),
            )
        else
            summary["solver_log_finding_codes"] = Dict{String,Int}()
            summary["solver_log_iterations"] = Dict{String,Any}()
        end
        push!(cases, summary)
    end
    summary_path = length(ARGS) == 2 ? abspath(ARGS[2]) : joinpath(output_dir, "summary.json")
    payload = Dict{String,Any}(
        "runner_version" => get(index, "runner_version", nothing),
        "solver" => get(index, "solver", nothing),
        "environment" => get(index, "environment", nothing),
        "environment_fingerprint" => get(index, "environment_fingerprint", nothing),
        "family_perturbations_enabled" => get(index, "family_perturbations_enabled", false),
        "family_perturbation_families" => get(index, "family_perturbation_families", Any[]),
        "family_perturbation_max_iter" => get(index, "family_perturbation_max_iter", nothing),
        "status_counts" => status_counts,
        "successful_case_count" => get(status_counts, "ok", 0),
        "iteration_count_total" => sum(iteration_counts; init = 0),
        "iteration_count_minimum" => isempty(iteration_counts) ? nothing : minimum(iteration_counts),
        "iteration_count_maximum" => isempty(iteration_counts) ? nothing : maximum(iteration_counts),
        "solver_result_finding_codes" => trace_finding_codes,
        "bmopf_context_finding_codes" => bmopf_finding_codes,
        "bmopf_profile_finding_codes" => bmopf_profile_finding_codes,
        "controller_curve_trace_finding_codes" => controller_curve_trace_finding_codes,
        "controller_curve_trace_status_changes" => _metric_summary(controller_curve_trace_status_changes),
        "controller_curve_trace_coverage_changes" => _metric_summary(controller_curve_trace_coverage_changes),
        "controller_curve_trace_slope_changes" => _metric_summary(controller_curve_trace_slope_changes),
        "controller_curve_trace_observation_counts" => _metric_summary(controller_curve_trace_observation_counts),
        "controller_curve_trace_family_counts" => controller_curve_trace_family_counts,
        "controller_curve_trace_status_counts" => controller_curve_trace_status_counts,
        "controller_curve_trace_monitor_semantics_counts" => controller_curve_trace_semantics_counts,
        "failure_category_counts" => failure_category_counts,
        "solver_log_evidence_case_count" => solver_log_evidence_case_count,
        "solver_log_observation_count" => solver_log_observation_count,
        "solver_log_finding_codes" => solver_log_finding_codes,
        "solver_log_iteration_count" => solver_log_iteration_count,
        "solver_log_iteration_segment_count" => solver_log_iteration_segment_count,
        "solver_rank_semantic_family_counts" => rank_semantic_family_counts,
        "bmopf_row_family_perturbation_code_counts" => row_family_perturbation_code_counts,
        "bmopf_row_family_perturbation_family_counts" => row_family_perturbation_family_counts,
        "family_perturbation_status_counts" => family_perturbation_status_counts,
        "family_perturbation_termination_counts" => family_perturbation_termination_counts,
        "family_perturbation_by_family" => family_perturbation_by_family,
        "cases" => cases,
    )
    write(summary_path, JSON.json(payload))
    println("wrote solver-trace summary to $summary_path")
end

main()
