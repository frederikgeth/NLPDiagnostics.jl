#!/usr/bin/env julia

"""Produce a bounded, evidence-preserving restoration campaign report."""

using JSON

_dict(value) = value isa AbstractDict ? Dict{String,Any}(string(k) => v for (k, v) in value) : Dict{String,Any}()

function _family_peaks(residual)
    values = _dict(get(residual, "family_peak_max_feasibility_violation", nothing))
    ranked = sort!(collect(values); by = pair -> (-Float64(pair.second), String(pair.first)))
    return [Dict{String,Any}("family" => String(pair.first), "peak" => pair.second)
            for pair in first(ranked, min(length(ranked), 5))]
end

function _policy_view(raw)
    policy = _dict(raw)
    trace = _dict(get(policy, "trace", nothing))
    residual = _dict(get(policy, "row_family_residual_trace", nothing))
    residual_summary = _dict(get(policy, "row_family_residual_summary", nothing))
    phase_counts = _dict(get(trace, "phase_counts", nothing))
    restoration_count = Int(get(phase_counts, "restoration", 0))
    final_primal = get(trace, "final_primal_infeasibility", nothing)
    final_dual = get(trace, "final_dual_infeasibility", nothing)
    endpoint_failure = (final_primal isa Number && abs(Float64(final_primal)) > 1.0e-6) ||
        (final_dual isa Number && abs(Float64(final_dual)) > 1.0e-6)
    trends = _dict(get(residual, "family_residual_trend", nothing))
    trend_counts = Dict{String,Int}()
    for value in values(trends)
        label = String(value)
        trend_counts[label] = get(trend_counts, label, 0) + 1
    end
    classification = String(get(policy, "classification", "unavailable"))
    interpretation = restoration_count > 0 && endpoint_failure ?
        "restoration coincides with a large endpoint residual signature" :
        restoration_count > 0 ? "restoration occurred but endpoint residuals recovered" :
        endpoint_failure ? "endpoint residual signature without restoration records" :
        "no restoration or endpoint residual signature observed"
    return Dict{String,Any}(
        "classification" => classification,
        "trace_record_count" => get(trace, "record_count", nothing),
        "phase_counts" => phase_counts,
        "restoration_record_count" => restoration_count,
        "final_primal_infeasibility" => final_primal,
        "final_dual_infeasibility" => final_dual,
        "endpoint_residual_failure_signature" => endpoint_failure,
        "residual_trace_status" => get(residual, "status",
            get(residual_summary, "status", "unavailable")),
        "family_trend_counts" => trend_counts,
        "largest_family_peak_residuals" => _family_peaks(
            _dict(get(policy, "row_family_residual_view", residual))),
        "interpretation" => interpretation,
    )
end

function main()
    length(ARGS) in (1, 2) || error(
        "usage: summarize_bmopf_restoration_campaign.jl <comparison.json> [output.json]",
    )
    comparison_path = abspath(ARGS[1])
    output_path = length(ARGS) == 2 ? abspath(ARGS[2]) :
        joinpath(dirname(comparison_path), "restoration_campaign_report.json")
    comparison = JSON.parsefile(comparison_path)
    rows = Dict{String,Any}[]
    restoration_count = 0
    endpoint_failure_count = 0
    cooccurrence_count = 0
    for raw_row in get(comparison, "rows", Any[])
        row = _dict(raw_row)
        policies = _dict(get(row, "policies", nothing))
        residual_views = _dict(get(row, "row_family_residual_by_policy", nothing))
        policy_rows = Dict{String,Any}[]
        for (policy_name, raw_policy) in policies
            view = _policy_view(raw_policy)
            residual_view = get(residual_views, policy_name, Dict{String,Any}())
            view["row_family_residual_view"] = residual_view
            view["largest_family_peak_residuals"] = _family_peaks(_dict(residual_view))
            push!(policy_rows, Dict{String,Any}(
                "policy" => policy_name,
                "evidence" => view,
            ))
            restoration = get(view, "restoration_record_count", 0) > 0
            endpoint_failure = get(view, "endpoint_residual_failure_signature", false) === true
            restoration && (restoration_count += 1)
            endpoint_failure && (endpoint_failure_count += 1)
            restoration && endpoint_failure && (cooccurrence_count += 1)
        end
        push!(rows, Dict{String,Any}(
            "key" => get(row, "key", "unknown"),
            "policy_count" => length(policy_rows),
            "policies" => policy_rows,
        ))
    end
    output = Dict{String,Any}(
        "report_version" => "bmopf-restoration-campaign-v1",
        "comparison" => comparison_path,
        "rows" => rows,
        "bounded_scope" => Dict{String,Any}(
            "dense_rank_required" => false,
            "evidence_source" => "captured public solver iterates and sparse row-family residual summaries",
            "causal_interpretation" => false,
        ),
        "campaign_counts" => Dict{String,Any}(
            "row_count" => length(rows),
            "policy_observation_count" => sum(row["policy_count"] for row in rows; init = 0),
            "restoration_observation_count" => restoration_count,
            "endpoint_residual_failure_count" => endpoint_failure_count,
            "restoration_endpoint_failure_cooccurrence_count" => cooccurrence_count,
        ),
        "readiness" => Dict{String,Any}(
            "comparison_grid_ready" => get(comparison, "readiness", Dict()) isa AbstractDict,
            "all_rows_have_policies" => !isempty(rows) && all(row -> row["policy_count"] > 0, rows),
            "all_residual_traces_available" => get(
                get(comparison, "readiness", Dict()),
                "all_row_family_residual_traces_available", false,
            ) === true,
        ),
        "interpretation" =>
            "This report preserves bounded restoration evidence and co-occurrence counts. It does not identify a causal formulation defect or certify convergence.",
    )
    write(output_path, JSON.json(output))
    println("wrote bounded restoration campaign report to $output_path")
end

main()
