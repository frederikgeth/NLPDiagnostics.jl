#!/usr/bin/env julia

"""Compare independent analyze-child peak observations across two environments."""

include(joinpath(@__DIR__, "common.jl"))
using .NLPDiagnosticsBenchmarkCommon

const ROOT = repo_root()
const ACTIVE_INPUT = "docs/bmopf_analyze_external_peak_probe_summary.json"
const CLEAN_INPUT = "docs/bmopf_analyze_external_peak_probe_clean_summary.json"
const OUTPUT = abspath(isempty(ARGS) ?
    joinpath(ROOT, "docs", "bmopf_analyze_external_peak_portability_summary.json") : ARGS[1])

active = read_summary(ACTIVE_INPUT)
clean = read_summary(CLEAN_INPUT)
active_source = get(active, "source", Dict{String,Any}())
clean_source = get(clean, "source", Dict{String,Any}())
active_environment = get(active, "environment", Dict{String,Any}())
clean_environment = get(clean, "environment", Dict{String,Any}())

function compare_field(name, left, right, mismatches)
    left == right || (mismatches[name] = Dict("active" => left, "clean" => right))
end

mismatches = Dict{String,Any}()
for name in ("case", "max_variables", "warmup")
    compare_field(name, get(active_source, name, nothing), get(clean_source, name, nothing), mismatches)
end
for name in ("child_status", "child_variable_count", "child_analyze_finding_count")
    compare_field(name, get(active, name, nothing), get(clean, name, nothing), mismatches)
end
environment_distinct = get(active_source, "project", nothing) != get(clean_source, "project", nothing) ||
    get(active_environment, "git_revision", nothing) != get(clean_environment, "git_revision", nothing)
active_peak = get(active, "external_peak_rss_bytes", nothing)
clean_peak = get(clean, "external_peak_rss_bytes", nothing)
peak_delta = active_peak isa Integer && clean_peak isa Integer ? clean_peak - active_peak : nothing
peak_ratio = active_peak isa Integer && clean_peak isa Integer && active_peak > 0 ? clean_peak / active_peak : nothing
semantic_match = isempty(mismatches) &&
    get(active, "status", "") == "peak_telemetry_available" &&
    get(clean, "status", "") == "peak_telemetry_available"

write_json(OUTPUT, Dict{String,Any}(
    "schema_version" => "nlpdiagnostics-bmopf-analyze-external-peak-comparison-v1",
    "source" => Dict(
        "runner" => "benchmarks/compare_bmopf_analyze_external_peak.jl",
        "active_input" => ACTIVE_INPUT,
        "clean_input" => CLEAN_INPUT,
        "comparison_required_for_portable_claim" => true,
    ),
    "status" => semantic_match && environment_distinct ?
        "cross_environment_peak_candidate" : "candidate_requires_review",
    "environment_distinct" => environment_distinct,
    "mismatches" => mismatches,
    "semantic_comparison" => Dict(
        "status" => isempty(mismatches) ? "matched" : "mismatch",
        "matched_fields" => ["case", "max_variables", "warmup", "child_status", "child_variable_count", "child_analyze_finding_count"],
        "mismatch_count" => length(mismatches),
    ),
    "resource_comparison" => Dict(
        "status" => active_peak isa Integer && clean_peak isa Integer ? "descriptive_only" : "unavailable",
        "active_external_peak_rss_bytes" => active_peak,
        "clean_external_peak_rss_bytes" => clean_peak,
        "clean_minus_active_peak_rss_bytes" => peak_delta,
        "clean_over_active_peak_ratio" => peak_ratio,
        "active_child_after_bytes" => get(active, "child_process_maxrss_after_bytes", nothing),
        "clean_child_after_bytes" => get(clean, "child_process_maxrss_after_bytes", nothing),
        "interpretation" => "Peak RSS differences are host/process observations only; they do not establish portable performance, allocator peaks, or retained memory.",
    ),
    "interpretation" => Dict(
        "claim" => "The two reviewed environments ran the same one-fixture analyze-child probe with matching configuration and child semantics, and both exposed an independent OS-level peak observation.",
        "does_not_establish" => [
            "portable peak-memory limits",
            "allocator-level peak or retained-memory behavior",
            "multi-case or solver scaling",
        ],
        "next_review" => "Decide whether a third host or allocator-capable measurement is required before a portable memory statement.",
    ),
))
println("wrote BMOPFTools external analyze peak comparison to $OUTPUT")
