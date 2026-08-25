#!/usr/bin/env julia

"""Summarize paired physical-KKT residual distributions for the saved 99-bus campaign.

This is a descriptive endpoint ledger. It preserves the strict 1e-5 policy,
reports full-side and failed-side quantiles, and compares reference with
phase-only maxima without diagnosing a cause or relaxing acceptance.
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
    joinpath(ROOT, "docs", "real_99bus_kkt_residual_distribution_summary.json") : ARGS[1])
const STRICT_TOLERANCE = 1.0e-5

isfile(INPUT) || error("campaign artifact does not exist: $INPUT")
campaign = read_summary(INPUT; root = "/")

function quantile(values, probability)
    isempty(values) && return nothing
    ordered = sort(Float64.(values))
    position = 1 + probability * (length(ordered) - 1)
    lower = floor(Int, position)
    upper = ceil(Int, position)
    lower == upper && return ordered[lower]
    ordered[lower] + (position - lower) * (ordered[upper] - ordered[lower])
end

function distribution(report)
    sides = get(get(report, "complementarity", Dict{String,Any}()), "sides", Dict{String,Any}())
    all_values = Float64[
        Float64(get(side, "complementarity_residual", NaN))
        for side in values(sides)
        if get(side, "complementarity_residual", nothing) isa Real
    ]
    failed_values = Float64[
        Float64(get(side, "complementarity_residual", NaN))
        for side in values(sides)
        if get(side, "passed", true) === false &&
           get(side, "complementarity_residual", nothing) isa Real
    ]
    stats(values) = isempty(values) ? nothing : Dict{String,Any}(
        "count" => length(values),
        "minimum" => minimum(values),
        "maximum" => maximum(values),
        "p50" => quantile(values, 0.50),
        "p90" => quantile(values, 0.90),
        "p95" => quantile(values, 0.95),
        "p99" => quantile(values, 0.99),
        "strict_tolerance_exceedance_count" => count(>(STRICT_TOLERANCE), values),
    )
    Dict{String,Any}(
        "available" => get(report, "available", false),
        "acceptance_passed" => get(report, "acceptance_passed", nothing),
        "strict_tolerance" => STRICT_TOLERANCE,
        "all_side_residuals" => stats(all_values),
        "failed_side_residuals" => stats(failed_values),
    )
end

profiles = Dict{String,Any}[]
for run in get(campaign, "runs", Any[])
    reference_report = get(run, "reference_physical_solver_kkt", Dict{String,Any}())
    phase_only_report = get(get(run, "phase_only", Dict{String,Any}()), "physical_solver_kkt", Dict{String,Any}())
    reference = distribution(reference_report)
    phase_only = distribution(phase_only_report)
    reference_max = get(get(reference, "all_side_residuals", Dict{String,Any}()), "maximum", nothing)
    phase_only_max = get(get(phase_only, "all_side_residuals", Dict{String,Any}()), "maximum", nothing)
    push!(profiles, Dict{String,Any}(
        "snapshot" => get(run, "snapshot", nothing),
        "angle" => get(run, "angle", nothing),
        "reference" => reference,
        "phase_only" => phase_only,
        "phase_only_minus_reference_maximum_residual" =>
            reference_max isa Real && phase_only_max isa Real ? phase_only_max - reference_max : nothing,
        "phase_only_reference_maximum_residual_ratio" =>
            reference_max isa Real && phase_only_max isa Real && reference_max > 0 ? phase_only_max / reference_max : nothing,
    ))
end

paired_differences = Float64[
    profile["phase_only_minus_reference_maximum_residual"]
    for profile in profiles if profile["phase_only_minus_reference_maximum_residual"] isa Real
]
paired_ratios = Float64[
    profile["phase_only_reference_maximum_residual_ratio"]
    for profile in profiles if profile["phase_only_reference_maximum_residual_ratio"] isa Real
]

write_json(OUTPUT, Dict{String,Any}(
    "schema_version" => "nlpdiagnostics-real-99bus-kkt-residual-distribution-v1",
    "source" => Dict(
        "runner" => "benchmarks/summarize_real_99bus_kkt_residual_distributions.jl",
        "campaign_artifact" => INPUT,
        "strict_complementarity_tolerance" => STRICT_TOLERANCE,
        "quantiles" => ["p50", "p90", "p95", "p99"],
    ),
    "environment" => Dict(
        "julia_version" => string(VERSION),
        "active_project" => Base.active_project(),
        "git_revision" => git_revision(),
        "git_worktree_dirty" => !isempty(git_status_entries()),
    ),
    "profile_count" => length(profiles),
    "reference_strict_acceptance_count" => count(profile -> get(profile["reference"], "acceptance_passed", false) === true, profiles),
    "phase_only_strict_acceptance_count" => count(profile -> get(profile["phase_only"], "acceptance_passed", false) === true, profiles),
    "paired_maximum_residual_difference_range" => isempty(paired_differences) ? nothing : [minimum(paired_differences), maximum(paired_differences)],
    "paired_maximum_residual_ratio_range" => isempty(paired_ratios) ? nothing : [minimum(paired_ratios), maximum(paired_ratios)],
    "profiles" => profiles,
    "interpretation" => Dict(
        "claim" => "Paired full-side and failed-side physical complementarity residual distributions for saved reference and phase-only 99-bus endpoints.",
        "does_not_establish" => [
            "a causal explanation for the residual floor",
            "absolute physical correctness",
            "a relaxed or universal tolerance policy",
        ],
    ),
))
println("wrote real 99-bus KKT residual distribution summary to $OUTPUT")
