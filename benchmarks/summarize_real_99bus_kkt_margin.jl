#!/usr/bin/env julia

"""Summarize strict physical-KKT tolerance margins for the saved 99-bus campaign.

This is a per-endpoint evidence ledger. It reports the largest observed physical
complementarity residual, the gap to the strict declared tolerance, and the
smallest tolerance that would accept the endpoint under the saved sensitivity
policy. It does not recommend relaxing the strict gate or establish causality.
"""

include(joinpath(@__DIR__, "common.jl"))
using .NLPDiagnosticsBenchmarkCommon

const ROOT = repo_root()
const INPUT = abspath(get(
    ENV,
    "NLPDIAGNOSTICS_REAL_99BUS_CAMPAIGN_INPUT",
    joinpath(ROOT, "work", "real-99bus-phase-only-campaign.json"),
))
const OUTPUT = abspath(isempty(ARGS) ?
    joinpath(ROOT, "docs", "real_99bus_kkt_margin_summary.json") : ARGS[1])
const FAILURE_ARTIFACT = joinpath(ROOT, "docs", "real_99bus_phase_only_kkt_failure_summary.json")
const STRICT_TOLERANCE = 1.0e-5

isfile(INPUT) || error("campaign artifact does not exist: $INPUT")
campaign = read_summary(INPUT; root = "/")
failure_summary = isfile(FAILURE_ARTIFACT) ? read_summary(FAILURE_ARTIFACT) : Dict{String,Any}()
failure_counts = get(failure_summary, "summary", Dict{String,Any}())

function endpoint_margin(report)
    sensitivity = get(report, "tolerance_sensitivity", Dict{String,Any}())
    required = get(sensitivity, "minimum_observed_complementarity_tolerance", nothing)
    maximum = get(sensitivity, "maximum_complementarity_residual", required)
    policy = get(get(sensitivity, "policies", Dict{String,Any}()), "1.0e-5", Dict{String,Any}())
    required isa Real || return Dict{String,Any}(
        "available" => get(report, "available", false),
        "acceptance_passed" => get(report, "acceptance_passed", nothing),
        "strict_tolerance" => STRICT_TOLERANCE,
        "required_tolerance" => nothing,
        "strict_tolerance_gap" => nothing,
        "strict_tolerance_ratio" => nothing,
        "failed_side_count" => get(policy, "failed_side_count", nothing),
        "strict_policy_acceptance_passed" => get(policy, "compound_acceptance_passed", nothing),
    )
    required_value = Float64(required)
    maximum_value = maximum isa Real ? Float64(maximum) : required_value
    Dict{String,Any}(
        "available" => get(report, "available", false),
        "acceptance_passed" => get(report, "acceptance_passed", nothing),
        "strict_tolerance" => STRICT_TOLERANCE,
        "required_tolerance" => required_value,
        "maximum_complementarity_residual" => maximum_value,
        "strict_tolerance_gap" => required_value - STRICT_TOLERANCE,
        "strict_tolerance_ratio" => required_value / STRICT_TOLERANCE,
        "failed_side_count" => get(policy, "failed_side_count", nothing),
        "strict_policy_acceptance_passed" => get(policy, "compound_acceptance_passed", nothing),
    )
end

profiles = Dict{String,Any}[]
for run in get(campaign, "runs", Any[])
    reference = endpoint_margin(get(run, "reference_physical_solver_kkt", Dict{String,Any}()))
    phase_only = endpoint_margin(get(get(run, "phase_only", Dict{String,Any}()), "physical_solver_kkt", Dict{String,Any}()))
    push!(profiles, Dict{String,Any}(
        "snapshot" => get(run, "snapshot", nothing),
        "angle" => get(run, "angle", nothing),
        "reference" => reference,
        "phase_only" => phase_only,
        "margin_difference_phase_only_minus_reference" =>
            reference["required_tolerance"] isa Real && phase_only["required_tolerance"] isa Real ?
            phase_only["required_tolerance"] - reference["required_tolerance"] : nothing,
    ))
end

reference_values = [
    profile["reference"]["required_tolerance"]
    for profile in profiles if profile["reference"]["required_tolerance"] isa Real
]
phase_values = [
    profile["phase_only"]["required_tolerance"]
    for profile in profiles if profile["phase_only"]["required_tolerance"] isa Real
]
all_values = vcat(reference_values, phase_values)
paired_values = [
    max(profile["reference"]["required_tolerance"], profile["phase_only"]["required_tolerance"])
    for profile in profiles
    if profile["reference"]["required_tolerance"] isa Real &&
       profile["phase_only"]["required_tolerance"] isa Real
]

function empirical_quantile(values, probability::Real)
    isempty(values) && return nothing
    ordered = sort(Float64.(values))
    position = 1 + (length(ordered) - 1) * probability
    lower = floor(Int, position)
    upper = ceil(Int, position)
    lower == upper && return ordered[lower]
    weight = position - lower
    return ordered[lower] + weight * (ordered[upper] - ordered[lower])
end

function quantile_summary(values)
    Dict{String,Any}(
        "count" => length(values),
        "p50" => empirical_quantile(values, 0.50),
        "p90" => empirical_quantile(values, 0.90),
        "p95" => empirical_quantile(values, 0.95),
        "p100" => empirical_quantile(values, 1.00),
    )
end

strict_failed = [
    profile for profile in profiles
    if profile["reference"]["strict_policy_acceptance_passed"] === false ||
       profile["phase_only"]["strict_policy_acceptance_passed"] === false
]
strict_passed = [
    profile for profile in profiles
    if profile["reference"]["strict_policy_acceptance_passed"] === true &&
       profile["phase_only"]["strict_policy_acceptance_passed"] === true
]

write_json(OUTPUT, Dict{String,Any}(
    "schema_version" => "nlpdiagnostics-real-99bus-kkt-margin-v1",
    "source" => Dict(
        "runner" => "benchmarks/summarize_real_99bus_kkt_margin.jl",
        "campaign_artifact" => INPUT,
        "failure_localization_artifact" => FAILURE_ARTIFACT,
        "strict_complementarity_tolerance" => STRICT_TOLERANCE,
        "margin_definition" => "required_tolerance_minus_strict_tolerance",
    ),
    "environment" => Dict(
        "julia_version" => string(VERSION),
        "active_project" => Base.active_project(),
        "git_revision" => git_revision(),
        "git_worktree_dirty" => !isempty(git_status_entries()),
    ),
    "profile_count" => length(profiles),
    "strict_failed_snapshot_count" => length(strict_failed),
    "strict_passed_snapshot_count" => length(strict_passed),
    "required_tolerance_range" => isempty(all_values) ? nothing : [minimum(all_values), maximum(all_values)],
    "maximum_required_tolerance" => isempty(all_values) ? nothing : maximum(all_values),
    "maximum_strict_tolerance_gap" => isempty(all_values) ? nothing : maximum(all_values) - STRICT_TOLERANCE,
    "maximum_strict_tolerance_ratio" => isempty(all_values) ? nothing : maximum(all_values) / STRICT_TOLERANCE,
    "required_tolerance_quantiles" => Dict(
        "reference" => quantile_summary(reference_values),
        "phase_only" => quantile_summary(phase_values),
        "all_endpoints" => quantile_summary(all_values),
        "paired_endpoint_maximum" => quantile_summary(paired_values),
    ),
    "failure_localization" => Dict(
        "all_strict_failures_are_ibr_p_upper" => get(failure_counts, "all_failed_sides_are_ibr_p_upper", nothing),
        "failed_constraint_families" => get(failure_counts, "failed_constraint_families", Any[]),
        "interpretation" => "The companion failure-localization ledger identifies the failed family; this margin ledger quantifies the tolerance gap only.",
    ),
    "profiles" => profiles,
    "interpretation" => Dict(
        "claim" => "Per-snapshot required physical complementarity tolerance and strict-gate margin for saved reference and phase-only endpoints.",
        "does_not_establish" => [
            "absolute physical correctness",
            "a causal explanation for the residual floor",
            "a recommended relaxed tolerance or universal tolerance policy",
        ],
    ),
))
println("wrote real 99-bus KKT margin summary to $OUTPUT")
