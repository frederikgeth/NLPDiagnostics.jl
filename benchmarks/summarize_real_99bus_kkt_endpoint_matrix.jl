#!/usr/bin/env julia

"""Join real-99-bus KKT margin and residual evidence by endpoint."""

include(joinpath(@__DIR__, "common.jl"))
using .NLPDiagnosticsBenchmarkCommon

const ROOT = repo_root()
const MARGIN_INPUT = "docs/real_99bus_kkt_margin_summary.json"
const RESIDUAL_INPUT = "docs/real_99bus_kkt_residual_distribution_summary.json"
const STABILITY_INPUT = "docs/real_99bus_kkt_stability_summary.json"
const OUTPUT = abspath(isempty(ARGS) ?
    joinpath(ROOT, "docs", "real_99bus_kkt_endpoint_matrix_summary.json") : ARGS[1])

margin = read_summary(MARGIN_INPUT)
residual = read_summary(RESIDUAL_INPUT)
stability = read_summary(STABILITY_INPUT)
margin_profiles = get(margin, "profiles", Any[])
residual_profiles = get(residual, "profiles", Any[])
length(margin_profiles) == 6 || error("expected six KKT margin endpoints")
length(residual_profiles) == length(margin_profiles) ||
    error("KKT margin and residual endpoint counts differ")

residual_by_snapshot = Dict(row["snapshot"] => row for row in residual_profiles)
failure_family = get(get(margin, "failure_localization", Dict{String,Any}()),
    "failed_constraint_families", String[])
rows = Dict{String,Any}[]
for profile in margin_profiles
    snapshot = profile["snapshot"]
    haskey(residual_by_snapshot, snapshot) || error("missing residual endpoint $snapshot")
    residual_profile = residual_by_snapshot[snapshot]
    reference = profile["reference"]
    phase_only = profile["phase_only"]
    paired_ratio = get(residual_profile,
        "phase_only_reference_maximum_residual_ratio", nothing)
    required_tolerance = max(reference["required_tolerance"], phase_only["required_tolerance"])
    push!(rows, Dict{String,Any}(
        "snapshot" => snapshot,
        "reference_strict_acceptance" => reference["strict_policy_acceptance_passed"],
        "phase_only_strict_acceptance" => phase_only["strict_policy_acceptance_passed"],
        "paired_strict_acceptance" => reference["strict_policy_acceptance_passed"] &&
            phase_only["strict_policy_acceptance_passed"],
        "reference_required_tolerance" => reference["required_tolerance"],
        "phase_only_required_tolerance" => phase_only["required_tolerance"],
        "paired_required_tolerance" => required_tolerance,
        "paired_strict_tolerance_gap" => required_tolerance - reference["strict_tolerance"],
        "paired_strict_tolerance_ratio" => required_tolerance / reference["strict_tolerance"],
        "reference_failed_side_count" => reference["failed_side_count"],
        "phase_only_failed_side_count" => phase_only["failed_side_count"],
        "paired_maximum_residual_ratio" => paired_ratio,
        "failure_families" => failure_family,
        "classification" => reference["strict_policy_acceptance_passed"] &&
            phase_only["strict_policy_acceptance_passed"] ?
            "strict_pass" : "strict_fail_localized_family",
    ))
end
sort!(rows; by = row -> row["snapshot"])

write_json(OUTPUT, Dict{String,Any}(
    "schema_version" => "nlpdiagnostics-real-99bus-kkt-endpoint-matrix-v1",
    "source" => Dict(
        "runner" => "benchmarks/summarize_real_99bus_kkt_endpoint_matrix.jl",
        "margin_artifact" => MARGIN_INPUT,
        "residual_artifact" => RESIDUAL_INPUT,
        "stability_artifact" => STABILITY_INPUT,
        "policy" => "Endpoint rows join strict acceptance, required tolerance, failure family, and paired residual ratios without relaxing the strict gate.",
    ),
    "environment" => Dict(
        "julia_version" => string(VERSION),
        "active_project" => Base.active_project(),
        "git_revision" => git_revision(),
        "git_worktree_dirty" => !isempty(git_status_entries()),
    ),
    "endpoint_count" => length(rows),
    "strict_paired_acceptance_count" => count(row -> row["paired_strict_acceptance"], rows),
    "strict_paired_failure_count" => count(row -> !row["paired_strict_acceptance"], rows),
    "all_failures_localized" => all(
        row -> row["classification"] == "strict_pass" || !isempty(row["failure_families"]),
        rows,
    ),
    "stable_profile_count" => get(stability, "qualified_profile_count", 0),
    "stable_strict_acceptance_count" => get(stability, "stable_strict_acceptance_count", nothing),
    "rows" => rows,
    "interpretation" => Dict(
        "claim" => "The six saved real-99-bus endpoints have a joined strict-KKT decision row with tolerance margin and paired residual provenance.",
        "does_not_establish" => [
            "a relaxed release threshold",
            "causal attribution beyond the localized failed family",
            "global optimality or physical correctness outside the saved endpoints",
        ],
    ),
))
println("wrote real-99-bus KKT endpoint matrix to $OUTPUT")
