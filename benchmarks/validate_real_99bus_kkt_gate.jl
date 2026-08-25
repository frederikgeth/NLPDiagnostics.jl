#!/usr/bin/env julia

"""Validate consistency of the saved real-99-bus physical-KKT ledgers.

This is a review-boundary validator: it checks that the campaign, endpoint,
margin, residual-distribution, stability, and tolerance-policy artifacts agree.
It does not rerun solves or relax the strict 1e-5 gate.
"""

include(joinpath(@__DIR__, "common.jl"))
using .NLPDiagnosticsBenchmarkCommon

const ROOT = repo_root()
const OUTPUT = abspath(isempty(ARGS) ?
    joinpath(ROOT, "docs", "real_99bus_kkt_gate_validation_summary.json") : ARGS[1])

campaign = read_summary("docs/real_99bus_phase_only_campaign_summary.json")
stability = read_summary("docs/real_99bus_kkt_stability_summary.json")
margin = read_summary("docs/real_99bus_kkt_margin_summary.json")
distribution = read_summary("docs/real_99bus_kkt_residual_distribution_summary.json")
policies = read_summary("docs/real_99bus_kkt_tolerance_policy_summary.json")
endpoint = read_summary("docs/real_99bus_kkt_endpoint_matrix_summary.json")

campaign_source = get(campaign, "source", Dict{String,Any}())
campaign_summary = get(campaign, "summary", Dict{String,Any}())
rows = get(endpoint, "rows", Any[])
paired_pass_count = count(row -> get(row, "paired_strict_acceptance", false), rows)
paired_failure_count = count(row -> !get(row, "paired_strict_acceptance", false), rows)
ratio_range = get(distribution, "paired_maximum_residual_ratio_range", Any[])
strict_tolerance = get(get(margin, "source", Dict{String,Any}()),
    "strict_complementarity_tolerance", nothing)
first_full_policy = get(policies, "first_observed_full_paired_acceptance_policy", nothing)

checks = Dict{String,Any}(
    "campaign_snapshot_count_matches_endpoint_count" =>
        get(campaign_source, "selected_snapshot_count", 0) == get(endpoint, "endpoint_count", -1),
    "all_campaign_solves_locally_solved" =>
        get(campaign_summary, "reference_locally_solved_count", 0) == 6 &&
        get(campaign_summary, "phase_only_locally_solved_count", 0) == 6,
    "endpoint_rows_match_declared_count" => length(rows) == get(endpoint, "endpoint_count", -1),
    "strict_pass_failure_partition_matches" =>
        paired_pass_count == get(endpoint, "strict_paired_acceptance_count", -1) &&
        paired_failure_count == get(endpoint, "strict_paired_failure_count", -1),
    "all_failures_localized" => get(endpoint, "all_failures_localized", false) &&
        get(get(stability, "failure_localization", Dict{String,Any}()),
            "all_failed_sides_are_ibr_p_upper", false),
    "strict_acceptance_matches_margin" =>
        get(margin, "strict_passed_snapshot_count", -1) == paired_pass_count &&
        get(margin, "strict_failed_snapshot_count", -1) == paired_failure_count,
    "strict_acceptance_matches_distribution" =>
        get(distribution, "reference_strict_acceptance_count", -1) == paired_pass_count &&
        get(distribution, "phase_only_strict_acceptance_count", -1) == paired_pass_count,
    "residual_ratio_is_near_one" => length(ratio_range) == 2 &&
        minimum(Float64.(ratio_range)) > 0.999999 &&
        maximum(Float64.(ratio_range)) < 1.000001,
    "strict_tolerance_is_1e-5" => strict_tolerance == 1.0e-5,
    "full_acceptance_policy_is_sensitivity_only" => first_full_policy == "1.2e-5",
)

status_entries = git_status_entries()
all_checks_passed = all(values(checks))
write_json(OUTPUT, Dict{String,Any}(
    "schema_version" => "nlpdiagnostics-real-99bus-kkt-gate-validation-v1",
    "source" => Dict{String,Any}(
        "runner" => "benchmarks/validate_real_99bus_kkt_gate.jl",
        "artifacts" => [
            "docs/real_99bus_phase_only_campaign_summary.json",
            "docs/real_99bus_kkt_stability_summary.json",
            "docs/real_99bus_kkt_margin_summary.json",
            "docs/real_99bus_kkt_residual_distribution_summary.json",
            "docs/real_99bus_kkt_tolerance_policy_summary.json",
            "docs/real_99bus_kkt_endpoint_matrix_summary.json",
        ],
        "strict_tolerance_policy" => "1e-5 remains the release threshold; saved relaxed policies are sensitivity evidence only.",
    ),
    "environment" => Dict{String,Any}(
        "julia_version" => string(VERSION),
        "active_project" => Base.active_project(),
        "git_revision" => git_revision(),
        "git_worktree_dirty" => !isempty(status_entries),
    ),
    "status" => all_checks_passed ? "consistent_partial" : "inconsistent",
    "all_checks_passed" => all_checks_passed,
    "checks" => checks,
    "strict_gate" => Dict{String,Any}(
        "tolerance" => strict_tolerance,
        "endpoint_count" => length(rows),
        "paired_pass_count" => paired_pass_count,
        "paired_failure_count" => paired_failure_count,
        "all_failures_localized" => get(endpoint, "all_failures_localized", false),
    ),
    "margin" => Dict{String,Any}(
        "maximum_required_tolerance" => get(margin, "maximum_required_tolerance", nothing),
        "maximum_strict_tolerance_gap" => get(margin, "maximum_strict_tolerance_gap", nothing),
        "paired_endpoint_p95_required_tolerance" => get(
            get(margin, "required_tolerance_quantiles", Dict{String,Any}()),
            "paired_endpoint_maximum", Dict{String,Any}(),
        )["p95"],
    ),
    "policy_sensitivity" => Dict{String,Any}(
        "first_observed_full_paired_acceptance_policy" => first_full_policy,
        "release_threshold_changed" => false,
    ),
    "interpretation" => Dict{String,Any}(
        "claim" => "The saved real-99-bus KKT ledgers are internally consistent: six locally solved paired endpoints, two strict 1e-5 passes, four localized ibr_p_upper failures, and near-unity paired residual ratios.",
        "does_not_establish" => [
            "strict physical-KKT acceptance beyond the six saved endpoints",
            "a relaxed release threshold",
            "a causal explanation for the ibr_p_upper residual floor",
        ],
    ),
))

all_checks_passed || error("real-99-bus KKT ledger validation failed")
println("wrote real-99-bus KKT gate validation summary to $OUTPUT")
