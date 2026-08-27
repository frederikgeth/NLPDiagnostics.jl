#!/usr/bin/env julia

"""Join point-free analyze trend, resource, and adapter evidence."""

include(joinpath(@__DIR__, "common.jl"))
using .NLPDiagnosticsBenchmarkCommon

const ROOT = repo_root()
const TREND_INPUT = "docs/analyze_runtime_trend_summary.json"
const RESOURCE_INPUT = "docs/analyze_runtime_resource_summary.json"
const PROFILE_INPUT = "docs/bmopf_analyze_runtime_profile_summary.json"
const AB_INPUT = "docs/analyze_static_optimization_ab_summary.json"
const GENERALIZATION_INPUT = "docs/analyze_static_optimization_generalization_summary.json"
const TARGET_TERMS_INPUT = "docs/analyze_static_target_terms_summary.json"
const ISOLATED_MEMORY_INPUT = "docs/bmopf_analyze_runtime_isolated_summary.json"
const PORTABILITY_INPUT = "docs/bmopf_analyze_portability_summary.json"
const EXTERNAL_PEAK_INPUT = "docs/bmopf_analyze_external_peak_probe_summary.json"
const EXTERNAL_PEAK_PORTABILITY_INPUT = "docs/bmopf_analyze_external_peak_portability_summary.json"
const ALLOCATOR_TELEMETRY_INPUT = "docs/bmopf_analyze_allocator_telemetry_summary.json"
const ALLOCATOR_PORTABILITY_INPUT = "docs/bmopf_analyze_allocator_telemetry_portability_summary.json"
const ALLOCATOR_BOUNDARY_INPUT = "docs/bmopf_analyze_allocator_boundary_summary.json"
const BMOPF_COMBINED_INPUT = "docs/bmopf_combined_mv_lv_analyze_scaling_summary.json"
const OUTPUT = abspath(isempty(ARGS) ?
    joinpath(ROOT, "docs", "analyze_scaling_readiness_summary.json") : ARGS[1])

trend = read_summary(TREND_INPUT)
resources = read_summary(RESOURCE_INPUT)
profile = read_summary(PROFILE_INPUT)
optimization_ab = read_summary(AB_INPUT)
optimization_generalization = read_summary(GENERALIZATION_INPUT)
optimization_target_terms = read_summary(TARGET_TERMS_INPUT)
isolated_memory = read_summary(ISOLATED_MEMORY_INPUT)
portability = read_summary(PORTABILITY_INPUT)
external_peak = read_summary(EXTERNAL_PEAK_INPUT)
external_peak_portability = read_summary(EXTERNAL_PEAK_PORTABILITY_INPUT)
allocator_telemetry = read_summary(ALLOCATOR_TELEMETRY_INPUT)
allocator_portability = read_summary(ALLOCATOR_PORTABILITY_INPUT)
allocator_boundary = read_summary(ALLOCATOR_BOUNDARY_INPUT)
bmopf_combined = read_summary(BMOPF_COMBINED_INPUT)

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

combined_records = get(bmopf_combined, "records", Any[])
combined_measured = filter(record -> get(record, "status", "") == "measured", combined_records)
combined_feeders = unique(string(get(record, "feeder", "unknown")) for record in combined_records)

combined_snapshot_covered = length(combined_feeders) >= 4 &&
    any(get(record, "status", "") == "skipped_size_guard" for record in combined_records)

target_terms_equivalence = get(optimization_target_terms, "equivalence_passed", false)
isolated_memory_records = get(isolated_memory, "records", Any[])
isolated_memory_measured = filter(record -> get(record, "status", "") == "measured", isolated_memory_records)
isolated_memory_summaries = get(isolated_memory, "case_summaries", Any[])
isolated_memory_stable_count = count(summary -> get(summary, "stable_across_repetitions", false), isolated_memory_summaries)
portability_validation = get(portability, "baseline_validation", Dict{String,Any}())
portability_comparison_status = get(portability, "portable_evidence_status", "unavailable")
portability_semantic_comparison = get(get(portability, "comparison", Dict{String,Any}()), "semantic_comparison", Dict{String,Any}())
portability_resource_comparison = get(get(portability, "comparison", Dict{String,Any}()), "resource_comparison", Dict{String,Any}())

open_gaps = Dict[
    Dict("id" => "static_stage_candidate_selection", "next_evidence" => "profile a different semantics-preserving static-stage candidate because the affine-row cache A/B is neutral to slightly slower locally"),
    Dict("id" => "portable_analyze_memory", "next_evidence" => portability_comparison_status == "candidate_requires_review" ? "review the matched second-environment analyze comparison and OS peak comparison, then obtain peak-capable allocator telemetry before making a portable memory claim" : "repeat the isolated analyze profile in a second reviewed environment with allocator-level peak telemetry"),
]
if !combined_snapshot_covered
    pushfirst!(open_gaps, Dict("id" => "larger_combined_mv_lv_analyze", "next_evidence" => "extend the guarded combined MV+LV analyze profile to additional feeders or a reviewed larger snapshot without forcing the full-case memory path"))
end
target_terms_equivalence && deleteat!(open_gaps, findall(gap -> gap["id"] == "static_stage_candidate_selection", open_gaps))

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
generalization_records = get(optimization_generalization, "records", Any[])
generalization_speedups = Float64[
    Float64(get(record, "elapsed_speedup", NaN))
    for record in generalization_records
    if get(record, "elapsed_speedup", nothing) isa Real
]
generalization_allocation_reductions = Float64[
    Float64(get(record, "allocation_reduction_ratio", NaN))
    for record in generalization_records
    if get(record, "allocation_reduction_ratio", nothing) isa Real
]
write_json(OUTPUT, Dict{String,Any}(
    "schema_version" => "nlpdiagnostics-analyze-scaling-readiness-v1",
    "source" => Dict(
        "runner" => "benchmarks/summarize_analyze_scaling_readiness.jl",
        "artifacts" => [TREND_INPUT, RESOURCE_INPUT, PROFILE_INPUT, AB_INPUT, GENERALIZATION_INPUT, TARGET_TERMS_INPUT, ISOLATED_MEMORY_INPUT, PORTABILITY_INPUT, EXTERNAL_PEAK_INPUT, EXTERNAL_PEAK_PORTABILITY_INPUT, ALLOCATOR_TELEMETRY_INPUT, ALLOCATOR_PORTABILITY_INPUT, ALLOCATOR_BOUNDARY_INPUT, BMOPF_COMBINED_INPUT],
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
    "static_optimization_generalization" => Dict(
        "workload_count" => get(optimization_generalization, "workload_count", 0),
        "record_count" => length(generalization_records),
        "equivalence_passed" => get(optimization_generalization, "equivalence_passed", false),
        "elapsed_speedup_range" => isempty(generalization_speedups) ? Any[] : [minimum(generalization_speedups), maximum(generalization_speedups)],
        "allocation_reduction_range" => isempty(generalization_allocation_reductions) ? Any[] : [minimum(generalization_allocation_reductions), maximum(generalization_allocation_reductions)],
        "decision" => "Mixed-density affine and sparse nonlinear evidence preserves semantics; local timing is neutral to slightly slower, so the candidate is not promoted as a performance win.",
    ),
    "static_optimization_target_terms" => Dict(
        "record_count" => length(get(optimization_target_terms, "records", Any[])),
        "equivalence_passed" => target_terms_equivalence,
        "candidate_not_slower_at_every_workload" => get(optimization_target_terms, "candidate_not_slower_at_every_workload", false),
        "elapsed_speedup_range" => begin
            values = Float64[Float64(get(record, "elapsed_speedup", NaN)) for record in get(optimization_target_terms, "records", Any[]) if get(record, "elapsed_speedup", nothing) isa Real]
            isempty(values) ? Any[] : [minimum(values), maximum(values)]
        end,
        "allocation_reduction_range" => begin
            values = Float64[Float64(get(record, "allocation_reduction_ratio", NaN)) for record in get(optimization_target_terms, "records", Any[]) if get(record, "allocation_reduction_ratio", nothing) isa Real]
            isempty(values) ? Any[] : [minimum(values), maximum(values)]
        end,
        "decision" => get(optimization_target_terms, "decision", "unavailable"),
    ),
    "isolated_adapter_memory" => Dict(
        "record_count" => length(isolated_memory_records),
        "measured_count" => length(isolated_memory_measured),
        "guarded_count" => count(record -> get(record, "status", "") == "skipped_size_guard", isolated_memory_records),
        "case_count" => length(isolated_memory_summaries),
        "stable_case_count" => isolated_memory_stable_count,
        "all_measured_cases_stable" => get(isolated_memory, "all_measured_cases_stable", false),
        "isolated_process_per_case_and_repetition" => get(get(isolated_memory, "source", Dict{String,Any}()), "isolated_process_per_case_and_repetition", false),
        "claim" => "Fresh-child local process allocation and Sys.maxrss observations are retained for guarded adapter analyze cases; portable and allocator-level claims remain open.",
    ),
    "portability_contract" => Dict(
        "baseline_status" => get(portability_validation, "status", "unavailable"),
        "baseline_error_count" => length(get(portability_validation, "errors", Any[])),
        "comparison_status" => portability_comparison_status,
        "comparison_environment_distinct" => get(get(portability, "comparison", Dict{String,Any}()), "environment_distinct", false),
        "comparison_mismatch_count" => length(get(get(portability, "comparison", Dict{String,Any}()), "mismatches", Dict{String,Any}())),
        "semantic_comparison_status" => get(portability_semantic_comparison, "status", "unavailable"),
        "semantic_comparison_mismatch_count" => get(portability_semantic_comparison, "mismatch_count", 0),
        "semantic_comparison_matched_record_count" => get(portability_semantic_comparison, "matched_record_count", 0),
        "resource_comparison_status" => get(portability_resource_comparison, "status", "unavailable"),
        "resource_comparison_matched_record_count" => get(portability_resource_comparison, "matched_record_count", 0),
        "resource_comparison_nonzero_difference_count" => get(portability_resource_comparison, "records_with_nonzero_differences", 0),
        "comparison_required_for_portable_claim" => get(get(portability, "source", Dict{String,Any}()), "comparison_required_for_portable_claim", true),
        "claim" => portability_comparison_status == "candidate_requires_review" ? "The replay contract validates local provenance and a matched second-environment candidate with semantic status $(get(portability_semantic_comparison, "status", "unavailable")); resource differences are descriptive-only, and allocator-level peak and performance review are still required for portability." : "The replay contract validates local provenance and guard compatibility; a second environment comparison is still required for portability.",
    ),
    "external_peak_probe" => Dict(
        "status" => get(external_peak, "status", "unavailable"),
        "available" => get(external_peak, "status", "") == "peak_telemetry_available",
        "case" => get(get(external_peak, "source", Dict{String,Any}()), "case", "unknown"),
        "tool" => get(get(external_peak, "source", Dict{String,Any}()), "tool", nothing),
        "child_status" => get(external_peak, "child_status", "unknown"),
        "external_peak_rss_bytes" => get(external_peak, "external_peak_rss_bytes", nothing),
        "child_process_maxrss_after_bytes" => get(external_peak, "child_process_maxrss_after_bytes", nothing),
        "external_peak_rss_minus_child_after_bytes" => get(external_peak, "external_peak_rss_minus_child_after_bytes", nothing),
        "claim" => "An independent OS-level peak RSS observation is available for one fresh analyze child on the local host; it is not allocator-level or portable evidence.",
    ),
    "external_peak_portability" => Dict(
        "status" => get(external_peak_portability, "status", "unavailable"),
        "environment_distinct" => get(external_peak_portability, "environment_distinct", false),
        "semantic_status" => get(get(external_peak_portability, "semantic_comparison", Dict{String,Any}()), "status", "unavailable"),
        "resource_status" => get(get(external_peak_portability, "resource_comparison", Dict{String,Any}()), "status", "unavailable"),
        "peak_delta_bytes" => get(get(external_peak_portability, "resource_comparison", Dict{String,Any}()), "clean_minus_active_peak_rss_bytes", nothing),
        "peak_ratio" => get(get(external_peak_portability, "resource_comparison", Dict{String,Any}()), "clean_over_active_peak_ratio", nothing),
        "claim" => "The same guarded one-fixture OS-level peak probe matches semantically across two distinct local environments; peak differences remain descriptive and do not establish portability or allocator behavior.",
    ),
    "allocator_telemetry" => Dict(
        "status" => get(allocator_telemetry, "status", "unavailable"),
        "current_available" => get(allocator_telemetry, "allocator_current_available", false),
        "peak_available_count" => get(allocator_telemetry, "allocator_peak_available_count", 0),
        "stage_count" => get(allocator_telemetry, "stage_count", 0),
        "case" => get(get(allocator_telemetry, "source", Dict{String,Any}()), "case", "unknown"),
        "claim" => "Darwin allocator current-allocation deltas are available around one analyze child; the allocator peak field remains independently unavailable when zero.",
    ),
    "allocator_portability" => Dict(
        "status" => get(allocator_portability, "status", "unavailable"),
        "environment_distinct" => get(allocator_portability, "environment_distinct", false),
        "semantic_status" => get(get(allocator_portability, "semantic_comparison", Dict{String,Any}()), "status", "unavailable"),
        "stage_count" => get(allocator_portability, "stage_count", 0),
        "nonzero_stage_difference_count" => get(allocator_portability, "nonzero_stage_difference_count", 0),
        "claim" => "Stage coverage and current-allocation telemetry match across two reviewed environments; differences remain descriptive and both allocator peak fields are unavailable.",
    ),
    "allocator_boundary" => Dict(
        "status" => get(allocator_boundary, "status", "unavailable"),
        "portable_memory_claim_allowed" => get(get(allocator_boundary, "decision", Dict{String,Any}()), "portable_memory_claim_allowed", false),
        "allocator_peak_claim_allowed" => get(get(allocator_boundary, "decision", Dict{String,Any}()), "allocator_peak_claim_allowed", false),
        "release_note_required" => get(get(allocator_boundary, "decision", Dict{String,Any}()), "release_note_required", true),
        "claim" => get(get(allocator_boundary, "decision", Dict{String,Any}()), "boundary", "Allocator peak availability remains unreviewed."),
    ),
    "bmopf_combined_mv_lv_analyze" => Dict(
        "feeder_count" => length(combined_feeders),
        "feeders" => combined_feeders,
        "record_count" => length(combined_records),
        "measured_count" => length(combined_measured),
        "stable_measured_count" => count(record -> get(record, "evidence_stable_across_repetitions", false), combined_measured),
        "guarded_count" => count(record -> get(record, "status", "") == "skipped_size_guard", combined_records),
        "policy_count" => length(unique(string(get(record, "policy", "unknown")) for record in combined_records)),
        "variable_count_range" => isempty(combined_measured) ? Any[] : [minimum(Int[get(record, "variable_count", 0) for record in combined_measured]), maximum(Int[get(record, "variable_count", 0) for record in combined_measured])],
        "claim" => "$(length(combined_feeders)) reviewed combined MV+LV feeder snapshots are profiled through the public point-free analyze entry point under classic, SI, and local policies; measured findings are stable under the guard and larger cases remain explicit skips.",
    ),
    "open_gap_count" => length(open_gaps),
    "open_gaps" => open_gaps,
    "interpretation" => Dict(
        "claim" => "Bounded analyze workloads now include sparse, mixed-density affine, nonlinear, and reviewed BMOPFTools combined MV+LV feeder snapshots with stable findings; an independent OS-level peak probe is available for one representative child; the affine-row cache A/B preserves semantics but is neutral to slightly slower locally; all claims remain guarded local evidence.",
        "does_not_establish" => [
            "a production or asymptotic complexity law",
            "allocator-level peak memory behavior",
            "cross-machine reproducibility or OPF-solver scalability",
        ],
    ),
))
println("wrote analyze scaling readiness summary to $OUTPUT")
