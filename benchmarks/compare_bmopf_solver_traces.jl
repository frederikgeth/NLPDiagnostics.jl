#!/usr/bin/env julia

"""Compare two `summarize_bmopf_solver_trace.jl` outputs without a score."""

using JSON
using NLPDiagnostics

include(joinpath(@__DIR__, "common.jl"))
using .NLPDiagnosticsBenchmarkCommon

function _as_dict(value)
    return value isa AbstractDict ? Dict{String,Any}(string(k) => v for (k, v) in value) : Dict{String,Any}()
end

function _delta(left, right)
    left isa Real && right isa Real || return nothing
    return Float64(right) - Float64(left)
end

function _ratio(left, right)
    left isa Real && right isa Real && left != 0 || return nothing
    return Float64(right) / Float64(left)
end

function _relative_difference(left, right)
    left isa Real && right isa Real || return nothing
    return abs(Float64(right) - Float64(left)) /
           max(1.0, abs(Float64(left)), abs(Float64(right)))
end

function _case_map(summary)
    result = Dict{String,Any}()
    for case in get(summary, "cases", Any[])
        case isa AbstractDict || continue
        key = get(case, "name", get(case, "snapshot", get(case, "relative", "unknown")))
        result[String(key)] = case
    end
    return result
end

function _trace_campaign_summary(summary, policy)
    campaign = get(summary, "iteration_trace_campaign_summary", nothing)
    campaign isa AbstractDict && return Dict{String,Any}(
        String(key) => value for (key, value) in campaign
    )
    entries = Dict{String,Any}[]
    for case in get(summary, "cases", Any[])
        case isa AbstractDict || continue
        trace = _as_dict(get(case, "trace", nothing))
        isempty(trace) && (trace = Dict{String,Any}(
            "schema_version" => "unavailable",
            "available" => false,
        ))
        push!(entries, Dict{String,Any}(
            "provenance" => Dict{String,Any}(
                "policy" => policy,
                "solver" => get(summary, "solver", nothing),
                "case" => get(case, "name", "unknown"),
                "status" => get(case, "status", nothing),
                "environment_fingerprint" =>
                    get(summary, "environment_fingerprint", nothing),
            ),
            "summary" => trace,
        ))
    end
    return NLPDiagnostics.iteration_trace_campaign_summary(entries)
end

function _controller_trace_compare(left, right)
    left_trace = _as_dict(get(left, "current_law_trace", nothing))
    right_trace = _as_dict(get(right, "current_law_trace", nothing))
    pair(name) = Dict(
        "left" => get(left_trace, name, nothing),
        "right" => get(right_trace, name, nothing),
    )
    numeric_pair(name) = begin
        left_value = get(left_trace, name, nothing)
        right_value = get(right_trace, name, nothing)
        Dict(
            "left" => left_value,
            "right" => right_value,
            "delta_right_minus_left" => _delta(left_value, right_value),
        )
    end
    function registry_view(trace)
        crosswalk = _as_dict(get(trace,
            "controller_curve_violation_registry_crosswalk", nothing))
        status_counts = Dict{String,Int}()
        components_by_status = Dict{String,Vector{String}}()
        for (component, raw_entry) in crosswalk
            entry = _as_dict(raw_entry)
            status = String(get(entry, "status", "unknown"))
            status_counts[status] = get(status_counts, status, 0) + 1
            push!(get!(components_by_status, status, String[]), String(component))
        end
        for components in values(components_by_status)
            sort!(components)
        end
        return Dict{String,Any}(
            "available" => !isempty(crosswalk),
            "status_counts" => status_counts,
            "components_by_status" => components_by_status,
            "crosswalk" => crosswalk,
        )
    end
    return Dict{String,Any}(
        "available" => pair("available"),
        "snapshot_count" => numeric_pair("controller_curve_snapshot_count"),
        "observation_count" => numeric_pair("controller_curve_observation_count"),
        "family_counts" => pair("controller_curve_family_counts"),
        "status_counts" => pair("controller_curve_status_counts"),
        "monitor_semantics_counts" => pair("controller_curve_monitor_semantics_counts"),
        "status_changes" => numeric_pair("controller_curve_status_changes"),
        "coverage_changes" => numeric_pair("controller_curve_coverage_changes"),
        "slope_changes" => numeric_pair("controller_curve_slope_changes"),
        "finding_codes" => pair("finding_codes"),
        "local_slope" => pair("controller_curve_local_slope"),
        "breakpoint_distance" => pair("controller_curve_breakpoint_distance"),
        "absolute_equation_residual" => pair("controller_curve_absolute_equation_residual"),
        "snapshot_metrics" => pair("controller_curve_snapshot_metrics"),
        "transition_metrics" => pair("controller_curve_transition_metrics"),
        "equation_residual_violation_counts" => pair(
            "controller_curve_equation_residual_violation_count",
        ),
        "cap_violation_counts" => pair("controller_curve_cap_violation_count"),
        "equation_residual_violation_components" => pair(
            "controller_curve_equation_residual_violation_components",
        ),
        "cap_violation_components" => pair(
            "controller_curve_cap_violation_components",
        ),
        "violation_registry_crosswalk" => pair(
            "controller_curve_violation_registry_crosswalk",
        ),
        "violation_registry" => Dict(
            "left" => registry_view(left_trace),
            "right" => registry_view(right_trace),
        ),
    )
end

function _compare_case(left, right)
    left_trace = _as_dict(get(left, "trace", nothing))
    right_trace = _as_dict(get(right, "trace", nothing))
    left_codes = _as_dict(get(left, "solver_result_finding_codes", nothing))
    right_codes = _as_dict(get(right, "solver_result_finding_codes", nothing))
    bmopf_left = _as_dict(get(left, "bmopf_context_finding_codes", nothing))
    bmopf_right = _as_dict(get(right, "bmopf_context_finding_codes", nothing))
    initialization_left = _as_dict(get(left, "initialization", nothing))
    initialization_right = _as_dict(get(right, "initialization", nothing))
    derivative_left = _as_dict(get(left, "endpoint_derivative", nothing))
    derivative_right = _as_dict(get(right, "endpoint_derivative", nothing))
    initialization_left = _as_dict(get(left, "initialization", nothing))
    initialization_right = _as_dict(get(right, "initialization", nothing))
    left_log = _as_dict(get(left, "solver_log_iterations", nothing))
    right_log = _as_dict(get(right, "solver_log_iterations", nothing))
    return Dict{String,Any}(
        "status" => Dict("left" => get(left, "status", nothing), "right" => get(right, "status", nothing)),
        "conventions" => Dict(
            "solver_options" => Dict("left" => get(left, "solver_options", nothing), "right" => get(right, "solver_options", nothing)),
            "per_unit" => Dict("left" => get(left, "per_unit", nothing), "right" => get(right, "per_unit", nothing)),
            "model_coordinate_units" => Dict("left" => get(left, "model_coordinate_units", nothing), "right" => get(right, "model_coordinate_units", nothing)),
            "solver_objective_convention" => Dict("left" => get(left, "solver_objective_convention", nothing), "right" => get(right, "solver_objective_convention", nothing)),
            "objective_comparison_reference" => Dict("left" => get(left, "objective_comparison_reference", nothing), "right" => get(right, "objective_comparison_reference", nothing)),
        ),
        "model_variable_count" => Dict("left" => get(left, "model_variable_count", nothing), "right" => get(right, "model_variable_count", nothing)),
        "initialization" => Dict(
            "policy" => Dict("left" => get(initialization_left, "policy", nothing),
                "right" => get(initialization_right, "policy", nothing)),
            "status" => Dict("left" => get(initialization_left, "status", nothing),
                "right" => get(initialization_right, "status", nothing)),
            "finite_start_count" => Dict(
                "left" => get(initialization_left, "finite_start_count", nothing),
                "right" => get(initialization_right, "finite_start_count", nothing)),
            "missing_start_count" => Dict(
                "left" => get(initialization_left, "missing_start_count", nothing),
                "right" => get(initialization_right, "missing_start_count", nothing)),
            "point_fingerprint" => Dict(
                "left" => get(_as_dict(get(initialization_left, "point", nothing)),
                    "fingerprint", nothing),
                "right" => get(_as_dict(get(initialization_right, "point", nothing)),
                    "fingerprint", nothing)),
        ),
        "endpoint_derivative" => Dict(
            "status" => Dict("left" => get(derivative_left, "status", nothing),
                "right" => get(derivative_right, "status", nothing)),
            "fingerprint" => Dict(
                "left" => get(derivative_left, "fingerprint", nothing),
                "right" => get(derivative_right, "fingerprint", nothing),
                "match" => get(derivative_left, "fingerprint", nothing) ==
                    get(derivative_right, "fingerprint", nothing)),
            "point_fingerprint" => Dict(
                "left" => get(derivative_left, "point_fingerprint", nothing),
                "right" => get(derivative_right, "point_fingerprint", nothing)),
            "jacobian_entry_count" => Dict(
                "left" => get(derivative_left, "jacobian_entry_count", nothing),
                "right" => get(derivative_right, "jacobian_entry_count", nothing)),
            "jacobian_max_abs" => Dict(
                "left" => get(derivative_left, "jacobian_max_abs", nothing),
                "right" => get(derivative_right, "jacobian_max_abs", nothing)),
        ),
        "initialization" => Dict(
            "policy" => Dict(
                "left" => get(initialization_left, "policy", nothing),
                "right" => get(initialization_right, "policy", nothing),
            ),
            "status" => Dict(
                "left" => get(initialization_left, "status", nothing),
                "right" => get(initialization_right, "status", nothing),
            ),
            "finite_start_count" => Dict(
                "left" => get(initialization_left, "finite_start_count", nothing),
                "right" => get(initialization_right, "finite_start_count", nothing),
            ),
            "missing_start_count" => Dict(
                "left" => get(initialization_left, "missing_start_count", nothing),
                "right" => get(initialization_right, "missing_start_count", nothing),
            ),
            "point_fingerprint" => Dict(
                "left" => get(_as_dict(get(initialization_left, "point", nothing)),
                    "fingerprint", nothing),
                "right" => get(_as_dict(get(initialization_right, "point", nothing)),
                    "fingerprint", nothing),
            ),
        ),
        "trace" => Dict(
            "record_count" => Dict("left" => get(left_trace, "record_count", nothing), "right" => get(right_trace, "record_count", nothing),
                                    "delta_right_minus_left" => _delta(get(left_trace, "record_count", nothing), get(right_trace, "record_count", nothing))),
            "segment_count" => Dict("left" => get(left_trace, "segment_count", nothing), "right" => get(right_trace, "segment_count", nothing)),
            "binding_count" => Dict("left" => get(left_trace, "binding_count", nothing), "right" => get(right_trace, "binding_count", nothing)),
            "final_objective" => Dict("left" => get(left_trace, "final_objective", nothing), "right" => get(right_trace, "final_objective", nothing),
                                       "delta_right_minus_left" => _delta(get(left_trace, "final_objective", nothing), get(right_trace, "final_objective", nothing)),
                                       "ratio_right_over_left" => _ratio(get(left_trace, "final_objective", nothing), get(right_trace, "final_objective", nothing)),
                                       "relative_difference" => _relative_difference(get(left_trace, "final_objective", nothing), get(right_trace, "final_objective", nothing)),
                                       "alignment" => begin
                                           difference = _relative_difference(get(left_trace, "final_objective", nothing), get(right_trace, "final_objective", nothing))
                                           isnothing(difference) ? "unavailable" :
                                               (difference <= 1.0e-6 ? "aligned" : "different_convention_or_solution")
                                       end),
            "final_primal_infeasibility" => Dict("left" => get(left_trace, "final_primal_infeasibility", nothing), "right" => get(right_trace, "final_primal_infeasibility", nothing)),
            "final_dual_infeasibility" => Dict("left" => get(left_trace, "final_dual_infeasibility", nothing), "right" => get(right_trace, "final_dual_infeasibility", nothing)),
            "phase_counts" => Dict("left" => get(left_trace, "phase_counts", Dict()), "right" => get(right_trace, "phase_counts", Dict())),
        ),
        "controller_curve_trace" => _controller_trace_compare(left, right),
        "solver_log" => Dict(
            "available" => Dict(
                "left" => get(left, "solver_log_available", false),
                "right" => get(right, "solver_log_available", false),
            ),
            "finding_codes" => Dict(
                "left" => get(left, "solver_log_finding_codes", Dict()),
                "right" => get(right, "solver_log_finding_codes", Dict()),
            ),
            "iteration_count" => Dict(
                "left" => get(left_log, "record_count", nothing),
                "right" => get(right_log, "record_count", nothing),
                "delta_right_minus_left" => _delta(
                    get(left_log, "record_count", nothing),
                    get(right_log, "record_count", nothing),
                ),
            ),
            "segment_count" => Dict(
                "left" => get(left_log, "segment_count", nothing),
                "right" => get(right_log, "segment_count", nothing),
            ),
            "final_primal_infeasibility" => Dict(
                "left" => get(left_log, "final_primal_infeasibility", nothing),
                "right" => get(right_log, "final_primal_infeasibility", nothing),
            ),
            "final_dual_infeasibility" => Dict(
                "left" => get(left_log, "final_dual_infeasibility", nothing),
                "right" => get(right_log, "final_dual_infeasibility", nothing),
            ),
        ),
        "solver_result_finding_codes" => Dict("left" => left_codes, "right" => right_codes),
        "bmopf_context_finding_codes" => Dict("left" => bmopf_left, "right" => bmopf_right),
    )
end

function main()
    length(ARGS) in (2, 3) || error(
        "usage: compare_bmopf_solver_traces.jl <left-summary.json> <right-summary.json> [comparison.json]",
    )
    left_path, right_path = abspath.(ARGS[1:2])
    left = read_summary(left_path; root = "/")
    right = read_summary(right_path; root = "/")
    left_cases = _case_map(left)
    right_cases = _case_map(right)
    names = sort!(collect(union(keys(left_cases), keys(right_cases))))
    comparisons = Dict{String,Any}[]
    for name in names
        if !haskey(left_cases, name) || !haskey(right_cases, name)
            push!(comparisons, Dict("name" => name, "status" => "missing_on_one_side",
                                    "left_present" => haskey(left_cases, name),
                                    "right_present" => haskey(right_cases, name)))
        else
            push!(comparisons, Dict("name" => name,
                                    "comparison" => _compare_case(left_cases[name], right_cases[name])))
        end
    end
    left_trace_campaign = _trace_campaign_summary(left, "left")
    right_trace_campaign = _trace_campaign_summary(right, "right")
    trace_coverage_comparison = NLPDiagnostics.iteration_trace_policy_comparison(
        Dict("left" => left_trace_campaign, "right" => right_trace_campaign);
        reference_policy = "left",
    )
    output_path = length(ARGS) == 3 ? abspath(ARGS[3]) : joinpath(dirname(left_path), "solver_trace_comparison.json")
    payload = Dict{String,Any}(
        "left_summary" => left_path,
        "right_summary" => right_path,
        "left_solver" => get(left, "solver", nothing),
        "right_solver" => get(right, "solver", nothing),
        "environment_fingerprint" => Dict(
            "left" => get(left, "environment_fingerprint", nothing),
            "right" => get(right, "environment_fingerprint", nothing),
            "match" => get(left, "environment_fingerprint", nothing) == get(right, "environment_fingerprint", nothing),
        ),
        "case_count" => length(comparisons),
        "comparisons" => comparisons,
        "trace_coverage_comparison" => trace_coverage_comparison,
    )
    write_json(output_path, payload)
    println("wrote solver-trace comparison to $output_path")
end

main()
