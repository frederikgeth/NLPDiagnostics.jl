#!/usr/bin/env julia

"""Summarize strict physical-KKT stability across the saved 99-bus matrices.

This is a join and qualification ledger, not a new solver campaign. Profiles
with incomplete solves are retained but excluded from the stable strict-KKT
count so iteration-limit failures cannot be mistaken for physical evidence.
"""

include(joinpath(@__DIR__, "common.jl"))
using .NLPDiagnosticsBenchmarkCommon

const ROOT = repo_root()
const OUTPUT = abspath(isempty(ARGS) ?
    joinpath(ROOT, "docs", "real_99bus_kkt_stability_summary.json") : ARGS[1])
const MATRIX_ARTIFACTS = [
    "docs/real_99bus_phase_only_tolerance_matrix_summary.json",
    "docs/real_99bus_phase_only_option_matrix_summary.json",
    "docs/real_99bus_phase_only_initialization_matrix_summary.json",
    "docs/real_99bus_phase_only_perturbation_matrix_summary.json",
    "docs/real_99bus_phase_only_structured_perturbation_matrix_summary.json",
]
const FAILURE_ARTIFACT = "docs/real_99bus_phase_only_kkt_failure_summary.json"

profiles = Dict{String,Any}[]
for artifact in MATRIX_ARTIFACTS
    summary = read_summary(artifact)
    for raw in get(summary, "cases", Any[])
        row = Dict{String,Any}(raw)
        statuses = get(row, "phase_only_termination_statuses", Any[])
        locally_solved = !isempty(statuses) && all(status -> status == "LOCALLY_SOLVED", statuses)
        solver_floor_complete = get(
            row, "phase_only_solver_floor_calibrated_acceptance_count", 0,
        ) == 6
        strict_count = get(row, "phase_only_physical_solver_kkt_acceptance_count", 0)
        push!(profiles, merge(row, Dict{String,Any}(
            "source_artifact" => artifact,
            "all_phase_only_locally_solved" => locally_solved,
            "solver_floor_complete" => solver_floor_complete,
            "strict_kkt_qualified" => locally_solved && solver_floor_complete,
            "strict_kkt_acceptance_count" => strict_count,
        )))
    end
end

qualified = filter(profile -> profile["strict_kkt_qualified"], profiles)
qualified_counts = [profile["strict_kkt_acceptance_count"] for profile in qualified]
count_histogram = Dict{String,Int}()
for count in qualified_counts
    key = string(count)
    count_histogram[key] = get(count_histogram, key, 0) + 1
end
residuals = [
    profile["phase_only_maximum_complementarity_residual"]
    for profile in qualified
    if get(profile, "phase_only_maximum_complementarity_residual", nothing) isa Number
]
failure_summary = read_summary(FAILURE_ARTIFACT)
failure_counts = get(failure_summary, "summary", Dict{String,Any}())

write_json(OUTPUT, Dict{String,Any}(
    "schema_version" => "nlpdiagnostics-real-99bus-kkt-stability-v1",
    "source" => Dict(
        "runner" => "benchmarks/summarize_real_99bus_kkt_stability.jl",
        "matrix_artifacts" => MATRIX_ARTIFACTS,
        "failure_artifact" => FAILURE_ARTIFACT,
        "strict_kkt_tolerance" => 1.0e-5,
    ),
    "environment" => Dict(
        "julia_version" => string(VERSION),
        "active_project" => Base.active_project(),
        "git_revision" => git_revision(),
        "git_worktree_dirty" => !isempty(git_status_entries()),
    ),
    "profile_count" => length(profiles),
    "qualified_profile_count" => length(qualified),
    "excluded_incomplete_profile_count" => length(profiles) - length(qualified),
    "qualified_strict_acceptance_counts" => qualified_counts,
    "qualified_strict_acceptance_count_histogram" => count_histogram,
    "stable_strict_acceptance_count" =>
        isempty(qualified_counts) ? nothing : first(qualified_counts),
    "strict_acceptance_count_is_stable" =>
        !isempty(qualified_counts) && length(unique(qualified_counts)) == 1,
    "qualified_maximum_complementarity_residual" =>
        isempty(residuals) ? nothing : maximum(residuals),
    "failure_localization" => Dict(
        "failed_run_count" => get(failure_counts, "failed_run_count", nothing),
        "all_failed_sides_are_ibr_p_upper" =>
            get(failure_counts, "all_failed_sides_are_ibr_p_upper", nothing),
        "failed_side_key_sets_equal_count" =>
            get(failure_counts, "failed_side_key_sets_equal_count", nothing),
    ),
    "profiles" => profiles,
    "interpretation" => Dict(
        "claim" => "Among complete solver-floor-qualified saved profiles, strict physical KKT acceptance is summarized without treating incomplete solves as failures or passes.",
        "does_not_establish" => [
            "absolute physical KKT acceptance for every 99-bus endpoint",
            "a causal explanation for the ibr_p_upper residual floor",
            "solver equivalence or a universal tolerance policy",
        ],
    ),
))
println("wrote real 99-bus KKT stability summary to $OUTPUT")
