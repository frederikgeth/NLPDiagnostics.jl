#!/usr/bin/env julia

"""Compare the tracked phase-only calibration campaigns without rerunning solvers."""

using JSON

const SUMMARY_FILES = [
    ("algebraic", "docs/phase_only_control_summary.json"),
    ("quadratic", "docs/phase_only_ipopt_campaign_summary.json"),
    ("nonlinear", "docs/phase_only_nonlinear_ipopt_campaign_summary.json"),
    ("controller_rich", "docs/phase_only_controller_ipopt_campaign_summary.json"),
    ("transformer", "docs/phase_only_transformer_ipopt_campaign_summary.json"),
    ("feeder", "docs/phase_only_feeder_ipopt_campaign_summary.json"),
]

function first_present(values, default_value=nothing)
    for value in values
        value === nothing || return value
    end
    return default_value
end

function average(values)
    return isempty(values) ? nothing : sum(Float64.(values)) / length(values)
end

function work_delta(summary)
    solver_work = get(summary, "solver_work", Dict{String,Any}())
    reference = get(solver_work, "reference", nothing)
    candidate = get(solver_work, "phase_only", nothing)
    if !(reference isa AbstractDict && candidate isa AbstractDict)
        return Dict("available" => false, "classification" => "unavailable")
    end
    deltas = Dict{String,Any}()
    for field in ("record_count", "line_search_trial_sum", "positive_regularization_record_count")
        reference_mean = average(get(reference, field, Any[]))
        candidate_mean = average(get(candidate, field, Any[]))
        deltas[field] = isnothing(reference_mean) || isnothing(candidate_mean) ? nothing : candidate_mean - reference_mean
    end
    values = [deltas[field] for field in keys(deltas) if deltas[field] !== nothing]
    classification = all(iszero, values) ? "matched" : (all(>=(0), values) && any(>(0), values) ? "candidate_more_work" : (all(<=(0), values) && any(<(0), values) ? "candidate_less_work" : "mixed"))
    return Dict("available" => true, "classification" => classification, "mean_delta" => deltas)
end

function campaign_row(root, id, relative_path)
    summary = JSON.parsefile(joinpath(root, relative_path))
    gates = get(summary, "gates", Dict{String,Any}())
    solver_work = get(summary, "solver_work", Dict{String,Any}())
    intervention = get(gates, "intervention_classification", "unavailable")
    covariance = first_present([
        get(gates, "endpoint_covariance_passed", nothing),
        get(gates, "covariance_gate_passed", nothing),
    ])
    geometry = get(gates, "geometry_gate_passed", nothing)
    locally_solved = first_present([
        get(gates, "all_endpoints_locally_solved", nothing),
        get(gates, "all_endpoints_accepted", nothing),
    ])
    return Dict(
        "id" => id,
        "summary" => relative_path,
        "schema_version" => get(summary, "schema_version", "unavailable"),
        "intervention_classification" => intervention,
        "endpoint_covariance_passed" => covariance,
        "geometry_gate_passed" => geometry,
        "all_endpoints_locally_solved" => locally_solved,
        "solver_work_available" => get(solver_work, "available", true) != false,
        "work_delta" => work_delta(summary),
    )
end

function run_comparison()
    root = normpath(joinpath(@__DIR__, ".."))
    campaigns = [campaign_row(root, id, path) for (id, path) in SUMMARY_FILES]
    qualified = [row for row in campaigns if row["intervention_classification"] == "phase_only" && row["endpoint_covariance_passed"] == true && row["geometry_gate_passed"] == true]
    locally_solved = [row for row in campaigns if row["all_endpoints_locally_solved"] == true]
    work_rows = [row for row in campaigns if row["work_delta"]["available"]]
    return Dict(
        "schema_version" => "nlpdiagnostics-phase-only-campaign-comparison-v1",
        "sources" => [path for (_, path) in SUMMARY_FILES],
        "campaigns" => campaigns,
        "findings" => Dict(
            "campaign_count" => length(campaigns),
            "gate_qualified_count" => length(qualified),
            "locally_solved_count" => length(locally_solved),
            "solver_work_comparison_count" => length(work_rows),
            "matched_work_campaigns" => [row["id"] for row in work_rows if row["work_delta"]["classification"] == "matched"],
            "candidate_less_work_campaigns" => [row["id"] for row in work_rows if row["work_delta"]["classification"] == "candidate_less_work"],
            "candidate_more_work_campaigns" => [row["id"] for row in work_rows if row["work_delta"]["classification"] == "candidate_more_work"],
            "work_withheld_campaigns" => [row["id"] for row in campaigns if !row["work_delta"]["available"]],
        ),
        "qualification" => Dict(
            "claim" => "Across the tracked fixtures, phase-only interventions pass the declared covariance and geometry gates; available Ipopt work is matched on the quadratic, nonlinear, and controller-rich fixtures, lower on the transformer fixture, and higher on the feeder fixture.",
            "scope" => "Six tracked summaries produced by the bounded local calibration campaigns; solver work is compared only where both reference and phase-only records were reported.",
            "does_not_establish" => ["global phase-policy superiority", "wall-time portability", "causal mechanism", "full feeder or transformer network semantics", "automatic policy safety"],
        ),
    )
end

output = abspath(get(ENV, "NLPDIAGNOSTICS_PHASE_ONLY_COMPARISON_OUTPUT", joinpath(@__DIR__, "..", "work", "phase-only-campaign-comparison.json")))
mkpath(dirname(output))
write(output, JSON.json(run_comparison()))
println("wrote phase-only campaign comparison to $output")
