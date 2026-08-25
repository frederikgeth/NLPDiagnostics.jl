#!/usr/bin/env julia

"""Join point-free analyze trend, resource, and adapter evidence."""

include(joinpath(@__DIR__, "common.jl"))
using .NLPDiagnosticsBenchmarkCommon

const ROOT = repo_root()
const TREND_INPUT = "docs/analyze_runtime_trend_summary.json"
const RESOURCE_INPUT = "docs/analyze_runtime_resource_summary.json"
const PROFILE_INPUT = "docs/bmopf_analyze_runtime_profile_summary.json"
const AB_INPUT = "docs/analyze_static_optimization_ab_summary.json"
const OUTPUT = abspath(isempty(ARGS) ?
    joinpath(ROOT, "docs", "analyze_scaling_readiness_summary.json") : ARGS[1])

trend = read_summary(TREND_INPUT)
resources = read_summary(RESOURCE_INPUT)
profile = read_summary(PROFILE_INPUT)
optimization_ab = read_summary(AB_INPUT)

trend_by_workload = Dict{String,Any}(
    "sparse_affine_chain" => get(trend, "affine_chain", Dict{String,Any}()),
    "sparse_nonlinear_chain" => get(trend, "nonlinear_chain", Dict{String,Any}()),
)
resource_by_workload = Dict{String,Any}(
    string(get(workload, "workload", "unknown")) => workload
    for workload in get(resources, "workloads", Any[])
)

workloads = Dict{String,Any}[]
for workload_name in sort(collect(keys(resource_by_workload)))
    resource = resource_by_workload[workload_name]
    trend_row = get(trend_by_workload, workload_name, Dict{String,Any}())
    push!(workloads, Dict(
        "workload" => workload_name,
        "point_count" => get(resource, "point_count", 0),
        "dimensions" => get(get(resource, "runtime", Dict{String,Any}()), "dimensions", Any[]),
        "evidence_stable" => get(resource, "evidence_stable", false) &&
            get(trend_row, "evidence_stable", false),
        "runtime_log_log_slope_range" => [
            get(get(resource, "runtime", Dict{String,Any}()), "log_log_slope_minimum", nothing),
            get(get(resource, "runtime", Dict{String,Any}()), "log_log_slope_maximum", nothing),
        ],
        "allocation_log_log_slope_range" => [
            get(get(resource, "allocation", Dict{String,Any}()), "log_log_slope_minimum", nothing),
            get(get(resource, "allocation", Dict{String,Any}()), "log_log_slope_maximum", nothing),
        ],
        "dominant_elapsed_stage_at_largest_dimension" => get(
            get(resource, "dominant_elapsed_stage_at_largest_dimension", Dict{String,Any}()),
            "stage",
            "unavailable",
        ),
        "dominant_allocation_stage_at_largest_dimension" => get(
            get(resource, "dominant_allocation_stage_at_largest_dimension", Dict{String,Any}()),
            "stage",
            "unavailable",
        ),
        "runtime_repeatability_cv_at_largest_dimension" => get(
            get(resource, "runtime_repeatability_at_largest_dimension", Dict{String,Any}()),
            "coefficient_of_variation",
            nothing,
        ),
        "trend_dominant_stage_at_largest_dimension" => get(
            trend_row,
            "dominant_stage_at_largest_dimension",
            "unavailable",
        ),
    ))
end

profile_records = get(profile, "records", Any[])
measured_count = count(record -> get(record, "status", "") == "measured", profile_records)
guarded_count = count(record -> get(record, "status", "") == "skipped_size_guard", profile_records)

open_gaps = [
    Dict("id" => "broader_analyze_workload_families", "next_evidence" => "add a reviewed mixed-density and nonlinear fixture ladder beyond the two sparse chains"),
    Dict("id" => "static_stage_optimization_generalization", "next_evidence" => "repeat the cached affine-row A/B on mixed-density and nonlinear workloads before making a performance claim"),
    Dict("id" => "portable_analyze_memory", "next_evidence" => "repeat the workload and adapter profiles in a second reviewed environment with allocator-level peak telemetry"),
]

ab_records = get(optimization_ab, "records", Any[])
ab_speedups = Float64[
    Float64(get(record, "elapsed_speedup", NaN))
    for record in ab_records
    if get(record, "elapsed_speedup", nothing) isa Real
]
ab_allocation_reductions = Float64[
    Float64(get(record, "allocation_reduction_ratio", NaN))
    for record in ab_records
    if get(record, "allocation_reduction_ratio", nothing) isa Real
]

write_json(OUTPUT, Dict{String,Any}(
    "schema_version" => "nlpdiagnostics-analyze-scaling-readiness-v1",
    "source" => Dict(
        "runner" => "benchmarks/summarize_analyze_scaling_readiness.jl",
        "artifacts" => [TREND_INPUT, RESOURCE_INPUT, PROFILE_INPUT, AB_INPUT],
        "policy" => "This ledger joins bounded point-free analyze trends, resource repeatability, and BMOPFTools adapter coverage without promoting a portable complexity or memory claim.",
    ),
    "environment" => Dict(
        "julia_version" => string(VERSION),
        "active_project" => Base.active_project(),
        "git_revision" => git_revision(),
        "git_worktree_dirty" => !isempty(git_status_entries()),
    ),
    "workload_count" => length(workloads),
    "workloads" => workloads,
    "adapter_profile" => Dict(
        "record_count" => length(profile_records),
        "measured_count" => measured_count,
        "guarded_count" => guarded_count,
        "warmup" => get(get(profile, "source", Dict{String,Any}()), "warmup", nothing),
    ),
    "static_optimization_ab" => Dict(
        "record_count" => length(ab_records),
        "equivalence_passed" => get(optimization_ab, "equivalence_passed", false),
        "candidate_not_slower_at_every_dimension" => get(optimization_ab, "candidate_not_slower_at_every_dimension", false),
        "elapsed_speedup_range" => isempty(ab_speedups) ? Any[] : [minimum(ab_speedups), maximum(ab_speedups)],
        "allocation_reduction_range" => isempty(ab_allocation_reductions) ? Any[] : [minimum(ab_allocation_reductions), maximum(ab_allocation_reductions)],
        "decision" => "Semantics are preserved, but the bounded timing result is mixed; retain the experiment as local evidence and do not promote a portable performance claim.",
    ),
    "open_gap_count" => length(open_gaps),
    "open_gaps" => open_gaps,
    "interpretation" => Dict(
        "claim" => "Both bounded analyze workloads have stable, repeatable local evidence with static as the dominant largest-dimension stage; the affine-row cache A/B preserves findings but has mixed local timing; the BMOPFTools adapter profile is measured only on guarded small fixtures.",
        "does_not_establish" => [
            "a production or asymptotic complexity law",
            "allocator-level peak memory behavior",
            "cross-machine reproducibility or OPF-solver scalability",
        ],
    ),
))
println("wrote analyze scaling readiness summary to $OUTPUT")
