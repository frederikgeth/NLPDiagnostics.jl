#!/usr/bin/env julia

"""Review whether the analyze allocator-peak limitation is release-ready."""

include(joinpath(@__DIR__, "common.jl"))
using .NLPDiagnosticsBenchmarkCommon

const ROOT = repo_root()
const COMPARISON_INPUT = "docs/bmopf_analyze_allocator_telemetry_portability_summary.json"
const ACTIVE_INPUT = "docs/bmopf_analyze_allocator_telemetry_summary.json"
const CLEAN_INPUT = "docs/bmopf_analyze_allocator_telemetry_clean_summary.json"
const OUTPUT = abspath(isempty(ARGS) ?
    joinpath(ROOT, "docs", "bmopf_analyze_allocator_boundary_summary.json") : ARGS[1])

comparison = read_summary(COMPARISON_INPUT)
active = read_summary(ACTIVE_INPUT)
clean = read_summary(CLEAN_INPUT)
active_peak_count = get(active, "allocator_peak_available_count", -1)
clean_peak_count = get(clean, "allocator_peak_available_count", -1)
comparison_ready = get(comparison, "status", "") == "cross_environment_allocator_candidate" &&
    get(comparison, "environment_distinct", false) &&
    get(get(comparison, "semantic_comparison", Dict{String,Any}()), "mismatch_count", 1) == 0 &&
    get(comparison, "stage_count", 0) == 4
current_available = get(active, "allocator_current_available", false) &&
    get(clean, "allocator_current_available", false)
peak_unavailable = active_peak_count == 0 && clean_peak_count == 0
status = comparison_ready && current_available && peak_unavailable ?
    "release_boundary_ready" : "boundary_requires_review"

write_json(OUTPUT, Dict{String,Any}(
    "schema_version" => "nlpdiagnostics-bmopf-analyze-allocator-boundary-v1",
    "status" => status,
    "source" => Dict(
        "runner" => "benchmarks/review_bmopf_analyze_allocator_boundary.jl",
        "comparison_input" => COMPARISON_INPUT,
        "active_input" => ACTIVE_INPUT,
        "clean_input" => CLEAN_INPUT,
        "review_policy" => "A release boundary is ready only when two distinct environments match semantically, current allocator counters are available, and peak fields are explicitly unavailable in both.",
    ),
    "checks" => Dict(
        "comparison_candidate" => comparison_ready,
        "current_allocator_available_both" => current_available,
        "peak_field_unavailable_active" => active_peak_count == 0,
        "peak_field_unavailable_clean" => clean_peak_count == 0,
        "stage_count_active" => get(active, "stage_count", 0),
        "stage_count_clean" => get(clean, "stage_count", 0),
    ),
    "decision" => Dict(
        "portable_memory_claim_allowed" => false,
        "allocator_peak_claim_allowed" => false,
        "current_allocation_attribution_allowed" => current_available,
        "release_note_required" => true,
        "boundary" => "Allocator-level peak memory is unavailable on the reviewed host/process; current-allocation stage deltas and OS-level RSS high-water observations remain descriptive only.",
        "next_evidence" => "Obtain a peak-capable allocator measurement on a reviewed host if a portable memory claim is required; otherwise retain this explicit boundary in release documentation.",
    ),
    "interpretation" => Dict(
        "claim" => "The allocator limitation is internally consistent across the two reviewed environments and can be carried as an explicit release boundary.",
        "does_not_establish" => [
            "allocator-level peak memory",
            "portable retained-memory limits",
            "performance or solver scaling",
        ],
    ),
))
println("wrote BMOPFTools analyze allocator boundary review to $OUTPUT")
