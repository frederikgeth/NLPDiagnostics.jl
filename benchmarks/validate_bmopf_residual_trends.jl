#!/usr/bin/env julia

"""Validate sparse row-family residual trends against solver phases."""

using JSON

_dict(value) = value isa AbstractDict ? Dict{String,Any}(string(k) => v for (k, v) in value) : Dict{String,Any}()

function _trend_counts(raw)
    counts = Dict{String,Int}()
    for value in values(_dict(raw))
        key = String(value)
        counts[key] = get(counts, key, 0) + 1
    end
    return counts
end

function _row_view(row)
    policies = _dict(get(row, "policies", nothing))
    residuals = _dict(get(row, "row_family_residual_by_policy", nothing))
    views = Dict{String,Any}()
    for (policy, raw_policy) in policies
        policy_view = _dict(raw_policy)
        trace = _dict(get(policy_view, "trace", nothing))
        residual = _dict(get(residuals, policy, nothing))
        phase_counts = _dict(get(trace, "phase_counts", nothing))
        restoration_count = Int(get(phase_counts, "restoration", 0))
        trend_counts = _trend_counts(get(residual, "family_residual_trend", nothing))
        restoration_only_count = get(trend_counts, "restoration_only", 0)
        persistent_count = get(trend_counts, "persistent", 0)
        alignment = restoration_count > 0 && restoration_only_count > 0 ?
            "aligned_restoration_only" : restoration_count > 0 && persistent_count > 0 ?
            "restoration_with_persistent_family" : restoration_count == 0 &&
            restoration_only_count == 0 ? "aligned_no_restoration" :
            restoration_count > 0 ? "restoration_without_family_trend" :
            "trend_without_restoration_phase"
        final_primal = get(trace, "final_primal_infeasibility", nothing)
        final_dual = get(trace, "final_dual_infeasibility", nothing)
        endpoint_residual_failure = (final_primal isa Number && abs(Float64(final_primal)) > 1.0e-6) ||
            (final_dual isa Number && abs(Float64(final_dual)) > 1.0e-6)
        views[policy] = Dict{String,Any}(
            "phase_counts" => phase_counts,
            "restoration_record_count" => restoration_count,
            "trend_counts" => trend_counts,
            "restoration_only_family_count" => restoration_only_count,
            "restoration_alignment" => alignment,
            "endpoint_residual_failure_signature" => endpoint_residual_failure,
            "residual_trace_status" => get(residual, "status", "unavailable"),
        )
    end
    return Dict{String,Any}(
        "key" => get(row, "key", "unknown"),
        "policies" => views,
    )
end

function main()
    length(ARGS) in (1, 2) || error(
        "usage: validate_bmopf_residual_trends.jl <comparison.json> [output.json]",
    )
    comparison_path = abspath(ARGS[1])
    output_path = length(ARGS) == 2 ? abspath(ARGS[2]) :
        joinpath(dirname(comparison_path), "residual_trend_validation.json")
    comparison = JSON.parsefile(comparison_path)
    rows = [_row_view(_dict(raw)) for raw in get(comparison, "rows", Any[])]
    policy_views = [view for row in rows for view in values(_dict(row["policies"]))]
    output = Dict{String,Any}(
        "validation_version" => "bmopf-residual-trend-validation-v1",
        "comparison" => comparison_path,
        "rows" => rows,
        "readiness" => Dict{String,Any}(
            "comparison_grid_ready" => get(comparison, "readiness", Dict()) isa AbstractDict,
            "all_residual_traces_available" => !isempty(policy_views) && all(view ->
                get(view, "residual_trace_status", "unavailable") in ("available", "partial"),
                policy_views),
        ),
        "alignment_counts" => Dict(
            alignment => count(view -> get(view, "restoration_alignment", "unknown") == alignment,
                policy_views)
            for alignment in unique(get(view, "restoration_alignment", "unknown") for view in policy_views)
        ),
        "interpretation" =>
            "Restoration alignment is a consistency check between captured solver phases and family residual trends; it is not a convergence certificate or a causal diagnosis.",
    )
    write(output_path, JSON.json(output))
    println("wrote residual trend validation to $output_path")
end

main()
