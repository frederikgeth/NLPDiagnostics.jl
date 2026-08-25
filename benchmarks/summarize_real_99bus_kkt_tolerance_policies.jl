#!/usr/bin/env julia

"""Summarize the saved 99-bus physical-KKT tolerance-policy matrix.

The campaign already records several declared complementarity tolerances. This
ledger counts endpoint acceptance and failed sides at each policy, preserving
the strict 1e-5 gate and avoiding a recommendation to relax it.
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
    joinpath(ROOT, "docs", "real_99bus_kkt_tolerance_policy_summary.json") : ARGS[1])
const STRICT_TOLERANCE = 1.0e-5

isfile(INPUT) || error("campaign artifact does not exist: $INPUT")
campaign = read_summary(INPUT; root = "/")
runs = get(campaign, "runs", Any[])

function endpoint_policies(report)
    get(get(report, "tolerance_sensitivity", Dict{String,Any}()), "policies", Dict{String,Any}())
end

policy_names = sort!(unique(String[
    name for run in runs
    for report in [
        get(run, "reference_physical_solver_kkt", Dict{String,Any}()),
        get(get(run, "phase_only", Dict{String,Any}()), "physical_solver_kkt", Dict{String,Any}()),
    ]
    for name in keys(endpoint_policies(report))
]))

function policy_record(name)
    reference_records = Dict{String,Any}[]
    phase_only_records = Dict{String,Any}[]
    profiles = Dict{String,Any}[]
    for run in runs
        reference_policy = get(endpoint_policies(get(run, "reference_physical_solver_kkt", Dict{String,Any}())), name, Dict{String,Any}())
        phase_only_policy = get(endpoint_policies(get(get(run, "phase_only", Dict{String,Any}()), "physical_solver_kkt", Dict{String,Any}())), name, Dict{String,Any}())
        push!(reference_records, reference_policy)
        push!(phase_only_records, phase_only_policy)
        push!(profiles, Dict{String,Any}(
            "snapshot" => get(run, "snapshot", nothing),
            "reference_acceptance_passed" => get(reference_policy, "compound_acceptance_passed", nothing),
            "phase_only_acceptance_passed" => get(phase_only_policy, "compound_acceptance_passed", nothing),
            "reference_failed_side_count" => get(reference_policy, "failed_side_count", nothing),
            "phase_only_failed_side_count" => get(phase_only_policy, "failed_side_count", nothing),
            "reference_failed_constraint_families" => get(reference_policy, "failed_constraint_families", Any[]),
            "phase_only_failed_constraint_families" => get(phase_only_policy, "failed_constraint_families", Any[]),
        ))
    end
    reference_tolerance = findfirst(record -> get(record, "complementarity_absolute_tolerance", nothing) isa Real, reference_records)
    tolerance = isnothing(reference_tolerance) ? nothing : reference_records[reference_tolerance]["complementarity_absolute_tolerance"]
    Dict{String,Any}(
        "policy_name" => name,
        "complementarity_absolute_tolerance" => tolerance,
        "reference_acceptance_count" => count(record -> get(record, "compound_acceptance_passed", false) === true, reference_records),
        "phase_only_acceptance_count" => count(record -> get(record, "compound_acceptance_passed", false) === true, phase_only_records),
        "paired_acceptance_count" => count(profile -> profile["reference_acceptance_passed"] === true && profile["phase_only_acceptance_passed"] === true, profiles),
        "reference_failed_side_total" => sum((get(record, "failed_side_count", 0) for record in reference_records); init = 0),
        "phase_only_failed_side_total" => sum((get(record, "failed_side_count", 0) for record in phase_only_records); init = 0),
        "profiles" => profiles,
    )
end

policies = [policy_record(name) for name in policy_names]
full_acceptance = filter(policy -> policy["paired_acceptance_count"] == length(runs), policies)
sort!(full_acceptance; by = policy -> policy["complementarity_absolute_tolerance"] isa Real ? policy["complementarity_absolute_tolerance"] : Inf)
strict_policy = findfirst(policy -> policy["complementarity_absolute_tolerance"] isa Real &&
    isapprox(policy["complementarity_absolute_tolerance"], STRICT_TOLERANCE; rtol = 0, atol = 1.0e-15), policies)

write_json(OUTPUT, Dict{String,Any}(
    "schema_version" => "nlpdiagnostics-real-99bus-kkt-tolerance-policy-v1",
    "source" => Dict(
        "runner" => "benchmarks/summarize_real_99bus_kkt_tolerance_policies.jl",
        "campaign_artifact" => INPUT,
        "strict_complementarity_tolerance" => STRICT_TOLERANCE,
    ),
    "environment" => Dict(
        "julia_version" => string(VERSION),
        "active_project" => Base.active_project(),
        "git_revision" => git_revision(),
        "git_worktree_dirty" => !isempty(git_status_entries()),
    ),
    "run_count" => length(runs),
    "policy_count" => length(policies),
    "strict_policy_name" => isnothing(strict_policy) ? nothing : policies[strict_policy]["policy_name"],
    "strict_reference_acceptance_count" => isnothing(strict_policy) ? nothing : policies[strict_policy]["reference_acceptance_count"],
    "strict_phase_only_acceptance_count" => isnothing(strict_policy) ? nothing : policies[strict_policy]["phase_only_acceptance_count"],
    "first_observed_full_paired_acceptance_policy" => isempty(full_acceptance) ? nothing : first(full_acceptance)["policy_name"],
    "policies" => policies,
    "interpretation" => Dict(
        "claim" => "Acceptance counts and failed-side totals under the already-recorded 99-bus complementarity policies.",
        "does_not_establish" => [
            "a recommended relaxed tolerance",
            "absolute physical correctness at any policy",
            "a causal explanation for the residual floor",
        ],
    ),
))
println("wrote real 99-bus KKT tolerance policy summary to $OUTPUT")
