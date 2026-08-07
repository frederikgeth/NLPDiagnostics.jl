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
function _finite_float(value)
    value isa Number || return nothing
    result = Float64(value)
    return isfinite(result) ? result : nothing
end

function _controller_snapshot_metrics(snapshot, iteration_records)
    snapshot isa AbstractDict || return nothing
    observations = get(snapshot, "observations", Any[])
    observations isa AbstractVector || (observations = Any[])
    slopes = Float64[]
    breakpoint_distances = Float64[]
    residuals = Float64[]
    equation_residual_violation_count = 0
    cap_violation_count = 0
    equation_residual_violation_components = Dict{String,Int}()
    cap_violation_components = Dict{String,Int}()
    status_counts = Dict{String,Int}()
    semantics_counts = Dict{String,Int}()
    for raw_observation in observations
        observation = raw_observation isa AbstractDict ? raw_observation : Dict{String,Any}()
        status = get(observation, "status", nothing)
        status === nothing || begin
            key = String(status)
            status_counts[key] = get(status_counts, key, 0) + 1
        end
        semantics = get(observation, "monitor_semantics", nothing)
        semantics === nothing || begin
            key = String(semantics)
            semantics_counts[key] = get(semantics_counts, key, 0) + 1
        end
        for (field, destination) in (
            ("local_slope", slopes),
            ("breakpoint_distance", breakpoint_distances),
            ("equation_residual", residuals),
        )
            value = _finite_float(get(observation, field, nothing))
            isnothing(value) || push!(destination, field == "equation_residual" ? abs(value) : value)
        end
        metadata = get(observation, "metadata", Dict())
        metadata isa AbstractDict || (metadata = Dict())
        tolerance = try
            parse(Float64, String(get(metadata, "controller_residual_tolerance", "1.0e-6")))
        catch
            1.0e-6
        end
        residual = _finite_float(get(observation, "equation_residual", nothing))
        component_key = join((
            get(observation, "component_type", "unknown"),
            get(observation, "component_id", "unknown"),
            get(observation, "curve_family", "unknown"),
        ), ":")
        !isnothing(residual) && abs(residual) > tolerance && begin
            equation_residual_violation_count += 1
            equation_residual_violation_components[component_key] =
                get(equation_residual_violation_components, component_key, 0) + 1
        end
        cap = _finite_float(get(observation, "cap_violation", nothing))
        !isnothing(cap) && cap > tolerance && begin
            cap_violation_count += 1
            cap_violation_components[component_key] =
                get(cap_violation_components, component_key, 0) + 1
        end
    end
    iteration = get(snapshot, "iteration", nothing)
    snapshot_phase = get(snapshot, "phase", nothing)
    snapshot_segment = get(snapshot, "segment", nothing)
    trace_record = nothing
    for candidate in iteration_records
        candidate_iteration = get(candidate, "iteration", nothing)
        candidate_phase = get(candidate, "phase", nothing)
        candidate_iteration == iteration &&
            (isnothing(snapshot_phase) || candidate_phase == snapshot_phase) &&
            (trace_record = candidate; break)
    end
    trace_record isa AbstractDict || (trace_record = Dict{String,Any}())
    return Dict{String,Any}(
        "iteration" => iteration,
        "phase" => snapshot_phase,
        "segment" => snapshot_segment,
        "label" => get(snapshot, "label", nothing),
        "observation_count" => length(observations),
        "status_counts" => status_counts,
        "monitor_semantics_counts" => semantics_counts,
        "local_slope" => _metric_summary(slopes),
        "breakpoint_distance" => _metric_summary(breakpoint_distances),
        "absolute_equation_residual" => _metric_summary(residuals),
        "equation_residual_violation_count" => equation_residual_violation_count,
        "cap_violation_count" => cap_violation_count,
        "equation_residual_violation_components" => equation_residual_violation_components,
        "cap_violation_components" => cap_violation_components,
        "solver_primal_infeasibility" => get(trace_record, "primal_infeasibility", nothing),
        "solver_dual_infeasibility" => get(trace_record, "dual_infeasibility", nothing),
        "solver_objective" => get(trace_record, "objective", nothing),
        "solver_trace_phase" => get(trace_record, "phase", nothing),
    )
end

function _controller_snapshot_transitions(metrics)
    transitions = Any[]
    for index in 2:length(metrics)
        previous = metrics[index - 1]
        current = metrics[index]
        function delta(metric, field)
            left = previous[metric]
            right = current[metric]
            left isa AbstractDict && (left = get(left, field, nothing))
            right isa AbstractDict && (right = get(right, field, nothing))
            left = _finite_float(left)
            right = _finite_float(right)
            return isnothing(left) || isnothing(right) ? nothing : right - left
        end
        push!(transitions, Dict{String,Any}(
            "from_iteration" => get(previous, "iteration", nothing),
            "to_iteration" => get(current, "iteration", nothing),
            "from_phase" => get(previous, "phase", nothing),
            "to_phase" => get(current, "phase", nothing),
            "local_slope_mean_delta" => delta("local_slope", "mean"),
            "breakpoint_distance_minimum_delta" => delta("breakpoint_distance", "minimum"),
            "absolute_equation_residual_maximum_delta" => delta("absolute_equation_residual", "maximum"),
            "solver_primal_infeasibility_delta" => delta("solver_primal_infeasibility", ""),
            "solver_dual_infeasibility_delta" => delta("solver_dual_infeasibility", ""),
        ))
    end
    return transitions
end

function _controller_violation_registry_crosswalk(residual_components,
                                                   cap_components,
                                                   semantic_rows)
    components = union(keys(residual_components), keys(cap_components))
    result = Dict{String,Any}()
    for key in sort!(collect(components))
        parts = split(String(key), ':'; limit = 3)
        component_type = length(parts) >= 1 ? parts[1] : "unknown"
        component_id = length(parts) >= 2 ? parts[2] : "unknown"
        curve_family = length(parts) >= 3 ? parts[3] : "unknown"
        expected_family = curve_family == "volt_var" ? "ibr_q_volt_var" :
            curve_family == "volt_watt" ? "ibr_p_volt_watt" : "unknown"
        matching_rows = String[]
        registered_rows = String[]
        if semantic_rows isa AbstractDict
            for (row, raw_descriptor) in semantic_rows
                descriptor = raw_descriptor isa AbstractDict ? raw_descriptor : Dict{String,Any}()
                family = String(get(descriptor, "constraint_family", ""))
                index = String(get(descriptor, "constraint_index", ""))
                occursin(expected_family, family) || continue
                occursin("\"$(component_id)\"", index) || continue
                row_string = String(row)
                push!(matching_rows, row_string)
                registered = get(descriptor, "registered", false)
                registered === true || lowercase(String(registered)) == "true" || continue
                push!(registered_rows, row_string)
            end
        end
        status = !(semantic_rows isa AbstractDict) ? "unavailable" :
            isempty(matching_rows) ? "not_found" :
            isempty(registered_rows) ? "unregistered" : "registered"
        result[String(key)] = Dict{String,Any}(
            "component_type" => component_type,
            "component_id" => component_id,
            "curve_family" => curve_family,
            "expected_constraint_family" => expected_family,
            "equation_residual_violation_count" => get(residual_components, key, 0),
            "cap_violation_count" => get(cap_components, key, 0),
            "matching_row_count" => length(matching_rows),
            "matching_row_indices" => sort!(matching_rows),
            "registered_row_indices" => sort!(registered_rows),
            "status" => status,
        )
    end
    return result
end

function _current_law_trace_summary(current_law_trace, iteration_trace = nothing,
                                    semantic_rows = nothing)
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
    iteration_records = if iteration_trace isa AbstractDict
        records = get(iteration_trace, "records", Any[])
        records isa AbstractVector ? records : Any[]
    else
        Any[]
    end
    snapshot_metrics = Any[]
    for snapshot in controller_snapshots
        metrics = _controller_snapshot_metrics(snapshot, iteration_records)
        isnothing(metrics) || push!(snapshot_metrics, metrics)
    end
    family_counts = Dict{String,Int}()
    status_counts = Dict{String,Int}()
    semantics_counts = Dict{String,Int}()
    slopes = Float64[]
    breakpoint_distances = Float64[]
    residuals = Float64[]
    equation_residual_violation_count = 0
    cap_violation_count = 0
    equation_residual_violation_components = Dict{String,Int}()
    cap_violation_components = Dict{String,Int}()
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
            metadata = get(observation, "metadata", Dict())
            metadata isa AbstractDict || (metadata = Dict())
            tolerance = try
                parse(Float64, String(get(metadata, "controller_residual_tolerance", "1.0e-6")))
            catch
                1.0e-6
            end
            residual = _finite_float(get(observation, "equation_residual", nothing))
            component_key = join((
                get(observation, "component_type", "unknown"),
                get(observation, "component_id", "unknown"),
                get(observation, "curve_family", "unknown"),
            ), ":")
            !isnothing(residual) && abs(residual) > tolerance && begin
                equation_residual_violation_count += 1
                equation_residual_violation_components[component_key] =
                    get(equation_residual_violation_components, component_key, 0) + 1
            end
            cap = _finite_float(get(observation, "cap_violation", nothing))
            !isnothing(cap) && cap > tolerance && begin
                cap_violation_count += 1
                cap_violation_components[component_key] =
                    get(cap_violation_components, component_key, 0) + 1
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
        "controller_curve_equation_residual_violation_count" => equation_residual_violation_count,
        "controller_curve_cap_violation_count" => cap_violation_count,
        "controller_curve_equation_residual_violation_components" => equation_residual_violation_components,
        "controller_curve_cap_violation_components" => cap_violation_components,
        "controller_curve_violation_registry_crosswalk" =>
            _controller_violation_registry_crosswalk(
                equation_residual_violation_components,
                cap_violation_components,
                semantic_rows,
            ),
        "controller_curve_snapshot_metrics" => snapshot_metrics,
        "controller_curve_transition_metrics" => _controller_snapshot_transitions(snapshot_metrics),
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

"""Summarize the provenance boundary of one serialized solver profile."""
function _solver_point_trust_summary(solver_profile, iteration_trace)
    nested = solver_profile isa AbstractDict ?
        get(solver_profile, "solver_profile", Dict()) : Dict()
    case = nested isa AbstractDict ? get(nested, "case", Dict()) : Dict()
    trust = case isa AbstractDict ? get(case, "point_trust", nothing) : nothing
    trust_metadata = trust isa AbstractDict ? get(trust, "metadata", Dict()) : Dict()
    result_selected = trust isa AbstractDict ?
        _integer_value(get(trust_metadata, "selected_count", 0)) : 0
    result_rejected = trust isa AbstractDict ?
        _integer_value(get(trust_metadata, "rejected_count", 0)) : 0
    result_complete = result_selected == 1 && result_rejected == 0

    bindings = iteration_trace isa AbstractDict ?
        get(iteration_trace, "bindings", Any[]) : Any[]
    bindings isa AbstractVector || (bindings = Any[])
    trusted_iterates = 0
    incomplete_iterates = 0
    non_solver_bindings = 0
    nonfinite_iterates = 0
    for raw_binding in bindings
        raw_binding isa AbstractDict || continue
        kind = String(get(raw_binding, "point_provenance_kind", "unknown"))
        complete = get(raw_binding, "point_provenance_complete", false) === true
        point = get(raw_binding, "point", Dict())
        values = point isa AbstractDict ? get(point, "values", Any[]) : Any[]
        finite = values isa AbstractVector && all(
            value -> value isa Number && isfinite(Float64(value)), values,
        )
        if kind == "SolverIteratePoint" && complete && finite
            trusted_iterates += 1
        elseif kind == "SolverIteratePoint"
            incomplete_iterates += 1
            (!finite) && (nonfinite_iterates += 1)
        else
            non_solver_bindings += 1
        end
    end
    return Dict{String,Any}(
        "solver_result_point_trust_metadata_available" => trust isa AbstractDict,
        "solver_result_point_selected_count" => result_selected,
        "solver_result_point_rejected_count" => result_rejected,
        "solver_result_point_trusted" => result_complete,
        "solver_iterate_binding_count" => length(bindings),
        "solver_iterate_trusted_binding_count" => trusted_iterates,
        "solver_iterate_incomplete_binding_count" => incomplete_iterates,
        "solver_iterate_non_solver_binding_count" => non_solver_bindings,
        "solver_iterate_nonfinite_binding_count" => nonfinite_iterates,
    )
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
    controller_curve_trace_transition_metrics = Any[]
    controller_curve_trace_equation_residual_violation_counts = Int[]
    controller_curve_trace_cap_violation_counts = Int[]
    controller_curve_trace_equation_residual_violation_components = Dict{String,Int}()
    controller_curve_trace_cap_violation_components = Dict{String,Int}()
    controller_curve_trace_violation_registry_crosswalk = Dict{String,Any}()
    trusted_solver_result_cases = 0
    incomplete_solver_result_cases = 0
    missing_solver_result_trust_cases = 0
    trusted_solver_iterate_bindings = 0
    incomplete_solver_iterate_bindings = 0
    non_solver_trace_bindings = 0
    nonfinite_solver_iterate_bindings = 0
    successful_source_snapshot_cases = 0
    successful_source_snapshot_missing_cases = 0
    source_snapshot_hashes = Set{String}()
    source_schema_warning_count = 0
    physical_metadata_warning_count = 0
    source_schema_warning_field_counts = Dict{String,Int}()
    source_schema_warning_scope_counts = Dict{String,Int}()
    source_schema_warning_impact_counts = Dict{String,Int}()
    source_schema_warning_policy_status_counts = Dict{String,Int}()
    successful_physical_metadata_complete_cases = 0
    successful_physical_metadata_incomplete_cases = 0
    successful_physical_metadata_missing_cases = 0
    process_exit_case_count = 0
    process_timeout_case_count = 0
    process_wait_error_case_count = 0
    nonzero_process_exit_case_count = 0
    process_log_case_count = 0
    iteration_counts = Int[]
    for entry in get(index, "cases", Any[])
        name = String(get(entry, "name", "unknown"))
        result_file = get(entry, "result_file", nothing)
        process_log = get(entry, "process_log", nothing)
        process_log_available = process_log isa AbstractString &&
                                isfile(joinpath(output_dir, process_log))
        process_log_available && (process_log_case_count += 1)
        get(entry, "process_timeout", false) === true &&
            (process_timeout_case_count += 1)
        wait_error = get(entry, "process_wait_error", nothing)
        !(wait_error === nothing || isempty(String(wait_error))) &&
            (process_wait_error_case_count += 1)
        exit_code = get(entry, "process_exit_code", nothing)
        exit_code isa Number && exit_code != 0 &&
            (nonzero_process_exit_case_count += 1)
        # An isolated child can terminate in native code before it writes a
        # result JSON.  Keep that process-health evidence in the summary so
        # a missing profile is distinguishable from an omitted case.
        if !(result_file isa AbstractString) || !isfile(joinpath(output_dir, result_file))
            status = String(get(entry, "status", "unknown"))
            status_counts[status] = get(status_counts, status, 0) + 1
            summary = Dict{String,Any}(entry)
            summary["status"] = status
            summary["result_file"] = nothing
            timed_out = get(entry, "process_timeout", false) === true
            status == "process_exit" && (process_exit_case_count += 1)
            summary["process_health"] = Dict(
                "status" => status,
                "exit_code" => exit_code,
                "timeout" => timed_out,
                "wait_error" => wait_error,
                "process_log" => process_log,
                "process_log_available" => process_log_available,
            )
            push!(cases, summary)
            continue
        end
        path = joinpath(output_dir, result_file)
        record = JSON.parsefile(path)
        status = String(get(record, "status", get(entry, "status", "unknown")))
        status_counts[status] = get(status_counts, status, 0) + 1
        summary = Dict{String,Any}(entry)
        summary["status"] = status
        source_snapshot = get(record, "source_snapshot",
            get(entry, "source_snapshot", nothing))
        summary["source_snapshot"] = source_snapshot
        if status == "ok"
            preserved = source_snapshot isa AbstractDict &&
                        get(source_snapshot, "preserved", false) === true &&
                        !isempty(String(get(source_snapshot, "sha256", "")))
            if preserved
                successful_source_snapshot_cases += 1
                push!(source_snapshot_hashes,
                    String(get(source_snapshot, "sha256", "")))
            else
                successful_source_snapshot_missing_cases += 1
            end
        end
        preflight = get(record, "integrity_preflight", nothing)
        if preflight isa AbstractDict
            schema_fields_available = haskey(preflight, "source_schema_warning_count") &&
                                      haskey(preflight, "physical_metadata_warning_count")
            warning_count = _integer_value(get(preflight,
                "source_schema_warning_count", 0))
            physical_count = _integer_value(get(preflight,
                "physical_metadata_warning_count", 0))
            source_schema_warning_count += warning_count
            physical_metadata_warning_count += physical_count
            for (field, destination) in (
                ("source_schema_warning_fields", source_schema_warning_field_counts),
                ("source_schema_warning_scopes", source_schema_warning_scope_counts),
                ("source_schema_warning_impacts", source_schema_warning_impact_counts),
            )
                values = get(preflight, field, Any[])
                values isa AbstractVector || continue
                for value in values
                    key = String(value)
                    destination[key] = get(destination, key, 0) + 1
                end
            end
            policies = get(preflight, "source_schema_warning_policies", Any[])
            policies isa AbstractVector || (policies = Any[policies])
            for policy in policies
                policy isa AbstractDict || continue
                key = String(get(policy, "status", "unknown"))
                source_schema_warning_policy_status_counts[key] =
                    get(source_schema_warning_policy_status_counts, key, 0) + 1
            end
            if status == "ok"
                !schema_fields_available ?
                    (successful_physical_metadata_missing_cases += 1) :
                physical_count == 0 ?
                    (successful_physical_metadata_complete_cases += 1) :
                    (successful_physical_metadata_incomplete_cases += 1)
            end
        elseif status == "ok"
            successful_physical_metadata_missing_cases += 1
        end
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
                    "sweep_label", "run_id", "replicate_index", "capture_logs",
                    "process_exit_code", "process_wait_error", "process_log",
                    "process_timeout")
            haskey(record, key) && (summary[key] = record[key])
        end
        if haskey(entry, "process_exit_code") || haskey(entry, "process_log") ||
           haskey(entry, "process_timeout") || haskey(entry, "process_wait_error")
            summary["process_health"] = Dict(
                "status" => status,
                "exit_code" => get(entry, "process_exit_code", nothing),
                "timeout" => get(entry, "process_timeout", false) === true,
                "wait_error" => get(entry, "process_wait_error", nothing),
                "process_log" => get(entry, "process_log", nothing),
                "process_log_available" => process_log_available,
            )
        end
        if status == "ok"
            trace = get(record, "iteration_trace", Dict{String,Any}())
            trace_summary = _trace_summary(trace)
            summary["trace"] = trace_summary
            controller_curve_trace = _current_law_trace_summary(
                get(record, "current_law_trace", nothing), trace,
                get(get(record, "bmopf_profile", Dict()),
                    "bmopf_constraint_semantic_rows", nothing),
            )
            summary["current_law_trace"] = controller_curve_trace
            if get(controller_curve_trace, "available", false)
                transition_metrics = get(controller_curve_trace,
                    "controller_curve_transition_metrics", Any[])
                transition_metrics isa AbstractVector || (transition_metrics = Any[])
                !isempty(transition_metrics) && push!(
                    controller_curve_trace_transition_metrics,
                    Dict("case" => name, "transitions" => transition_metrics),
                )
                _merge_counts!(controller_curve_trace_finding_codes,
                    get(controller_curve_trace, "finding_codes", Dict()))
                push!(controller_curve_trace_equation_residual_violation_counts,
                    _integer_value(get(controller_curve_trace,
                        "controller_curve_equation_residual_violation_count", 0)))
                push!(controller_curve_trace_cap_violation_counts,
                    _integer_value(get(controller_curve_trace,
                        "controller_curve_cap_violation_count", 0)))
                _merge_counts!(controller_curve_trace_equation_residual_violation_components,
                    get(controller_curve_trace,
                        "controller_curve_equation_residual_violation_components", Dict()))
                _merge_counts!(controller_curve_trace_cap_violation_components,
                    get(controller_curve_trace,
                        "controller_curve_cap_violation_components", Dict()))
                for (component, crosswalk) in get(
                    controller_curve_trace,
                    "controller_curve_violation_registry_crosswalk", Dict(),
                )
                    controller_curve_trace_violation_registry_crosswalk[String(component)] = crosswalk
                end
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
            point_trust = _solver_point_trust_summary(solver_profile, trace)
            summary["point_trust"] = point_trust
            if get(point_trust, "solver_result_point_trust_metadata_available", false)
                get(point_trust, "solver_result_point_trusted", false) &&
                    (trusted_solver_result_cases += 1)
            else
                missing_solver_result_trust_cases += 1
            end
            if get(point_trust, "solver_result_point_selected_count", 0) != 1 ||
               get(point_trust, "solver_result_point_rejected_count", 0) != 0
                incomplete_solver_result_cases += 1
            end
            trusted_solver_iterate_bindings += _integer_value(get(
                point_trust, "solver_iterate_trusted_binding_count", 0,
            ))
            incomplete_solver_iterate_bindings += _integer_value(get(
                point_trust, "solver_iterate_incomplete_binding_count", 0,
            ))
            non_solver_trace_bindings += _integer_value(get(
                point_trust, "solver_iterate_non_solver_binding_count", 0,
            ))
            nonfinite_solver_iterate_bindings += _integer_value(get(
                point_trust, "solver_iterate_nonfinite_binding_count", 0,
            ))
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
        "controller_curve_trace_transition_metrics" => controller_curve_trace_transition_metrics,
        "controller_curve_trace_equation_residual_violation_counts" => _metric_summary(
            controller_curve_trace_equation_residual_violation_counts,
        ),
        "controller_curve_trace_cap_violation_counts" => _metric_summary(
            controller_curve_trace_cap_violation_counts,
        ),
        "controller_curve_trace_equation_residual_violation_components" =>
            controller_curve_trace_equation_residual_violation_components,
        "controller_curve_trace_cap_violation_components" =>
            controller_curve_trace_cap_violation_components,
        "controller_curve_trace_violation_registry_crosswalk" =>
            controller_curve_trace_violation_registry_crosswalk,
        "trusted_point_selection_counts" => Dict(
            "successful_cases_with_trusted_solver_result_points" => trusted_solver_result_cases,
            "successful_cases_with_incomplete_solver_result_points" => incomplete_solver_result_cases,
            "successful_cases_missing_solver_result_trust_metadata" => missing_solver_result_trust_cases,
            "trusted_solver_iterate_binding_count" => trusted_solver_iterate_bindings,
            "incomplete_solver_iterate_binding_count" => incomplete_solver_iterate_bindings,
            "non_solver_trace_binding_count" => non_solver_trace_bindings,
            "nonfinite_solver_iterate_binding_count" => nonfinite_solver_iterate_bindings,
        ),
        "source_snapshot_counts" => Dict(
            "successful_cases_with_preserved_source_snapshot" => successful_source_snapshot_cases,
            "successful_cases_missing_source_snapshot" => successful_source_snapshot_missing_cases,
            "unique_source_snapshot_sha256_count" => length(source_snapshot_hashes),
        ),
        "source_schema_coverage" => Dict(
            "source_schema_warning_count" => source_schema_warning_count,
            "physical_metadata_warning_count" => physical_metadata_warning_count,
            "source_schema_warning_field_counts" => source_schema_warning_field_counts,
            "source_schema_warning_scope_counts" => source_schema_warning_scope_counts,
            "source_schema_warning_impact_counts" => source_schema_warning_impact_counts,
            "source_schema_warning_policy_status_counts" => source_schema_warning_policy_status_counts,
            "successful_cases_with_complete_physical_metadata" => successful_physical_metadata_complete_cases,
            "successful_cases_with_incomplete_physical_metadata" => successful_physical_metadata_incomplete_cases,
            "successful_cases_missing_physical_metadata_schema" => successful_physical_metadata_missing_cases,
        ),
        "process_health_counts" => Dict(
            "process_exit_case_count" => process_exit_case_count,
            "process_timeout_case_count" => process_timeout_case_count,
            "process_wait_error_case_count" => process_wait_error_case_count,
            "nonzero_process_exit_case_count" => nonzero_process_exit_case_count,
            "process_log_case_count" => process_log_case_count,
        ),
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
