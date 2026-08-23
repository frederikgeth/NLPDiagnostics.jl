#!/usr/bin/env julia

"""Summarize real 99-bus physical-KKT failure localization from a campaign artifact."""

Base.include(@__MODULE__, joinpath(@__DIR__, "common.jl"))
using .NLPDiagnosticsBenchmarkCommon: read_summary, write_json

function failed_keys(report)
    sides = get(get(report, "complementarity", Dict()), "sides", Dict())
    sort!(String[string(key) for (key, side) in pairs(sides) if get(side, "passed", false) === false])
end

function family_counts(report, keys)
    records = get(get(get(report, "semantic_attribution", Dict()), "complementarity", Dict()), "records", Dict())
    counts = Dict{String,Int}()
    for key in keys
        family = string(get(get(records, key, Dict()), "constraint_family", "unknown"))
        counts[family] = get(counts, family, 0) + 1
    end
    counts
end

function metric_range(report, keys, field)
    sides = get(get(report, "complementarity", Dict()), "sides", Dict())
    values = Float64[
        Float64(get(get(sides, key, Dict()), field, NaN))
        for key in keys
        if get(get(sides, key, Dict()), field, nothing) isa Real
    ]
    isempty(values) ? nothing : [minimum(values), maximum(values)]
end

function phase_summary(run, prefix)
    report = get(run, prefix, Dict())
    keys = failed_keys(report)
    return Dict{String,Any}(
        "available" => get(report, "available", false),
        "acceptance_passed" => get(report, "acceptance_passed", nothing),
        "failed_side_count" => length(keys),
        "failed_constraint_families" => family_counts(report, keys),
        "failed_complementarity_residual_range" => metric_range(report, keys, "complementarity_residual"),
        "failed_physical_slack_range" => metric_range(report, keys, "physical_slack"),
        "failed_side_keys" => keys,
    )
end

input = abspath(get(
    ENV,
    "NLPDIAGNOSTICS_REAL_99BUS_CAMPAIGN_INPUT",
    joinpath(@__DIR__, "..", "work", "real-99bus-phase-only-campaign.json"),
))
isfile(input) || error("campaign artifact does not exist: $input")
campaign = read_summary(input; root = "/")
runs = get(campaign, "runs", Any[])
run_summaries = Dict{String,Any}[]
for run in runs
    reference = phase_summary(run, "reference_physical_solver_kkt")
    phase_only = phase_summary(get(run, "phase_only", Dict()), "physical_solver_kkt")
    reference_keys = Set(reference["failed_side_keys"])
    phase_keys = Set(phase_only["failed_side_keys"])
    push!(run_summaries, Dict{String,Any}(
        "snapshot" => get(run, "snapshot", nothing),
        "reference" => reference,
        "phase_only" => phase_only,
        "failed_side_key_sets_equal" => reference_keys == phase_keys,
        "failed_side_count_equal" => reference["failed_side_count"] == phase_only["failed_side_count"],
        "failed_family_sets_equal" => reference["failed_constraint_families"] == phase_only["failed_constraint_families"],
    ))
end
failed_runs = filter(run -> run["reference"]["failed_side_count"] > 0, run_summaries)
all_failed_families = sort!(unique(String[family for run in failed_runs for family in keys(run["reference"]["failed_constraint_families"])]))
summary = Dict{String,Any}(
    "run_count" => length(run_summaries),
    "reference_kkt_accepted_count" => count(run -> run["reference"]["acceptance_passed"] === true, run_summaries),
    "phase_only_kkt_accepted_count" => count(run -> run["phase_only"]["acceptance_passed"] === true, run_summaries),
    "failed_run_count" => length(failed_runs),
    "failed_side_key_sets_equal_count" => count(run -> run["failed_side_key_sets_equal"], run_summaries),
    "failed_side_count_equal_count" => count(run -> run["failed_side_count_equal"], run_summaries),
    "failed_family_sets_equal_count" => count(run -> run["failed_family_sets_equal"], run_summaries),
    "failed_constraint_families" => all_failed_families,
    "all_failed_sides_are_ibr_p_upper" => all_failed_families == ["ibr_p_upper"],
    "qualification" => "failure localization from a saved real-99-bus campaign; not a causal solver or formulation diagnosis",
)
output = abspath(get(
    ENV,
    "NLPDIAGNOSTICS_REAL_99BUS_KKT_FAILURE_SUMMARY_OUTPUT",
    joinpath(@__DIR__, "..", "work", "real-99bus-phase-only-kkt-failure-summary.json"),
))
mkpath(dirname(output))
write_json(output, Dict(
    "schema_version" => "nlpdiagnostics-real-99bus-phase-only-kkt-failure-summary-v1",
    "source" => Dict(
        "runner" => basename(@__FILE__),
        "campaign_artifact" => input,
        "complementarity_tolerance" => 1.0e-5,
        "row_family_scope" => "physical KKT complementarity sides",
    ),
    "summary" => summary,
    "runs" => run_summaries,
))
println("wrote real 99-bus KKT failure summary to $output")
