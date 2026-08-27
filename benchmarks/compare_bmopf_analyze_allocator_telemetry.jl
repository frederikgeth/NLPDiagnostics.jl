#!/usr/bin/env julia

"""Compare stage allocator telemetry across the two reviewed environments."""

include(joinpath(@__DIR__, "common.jl"))
using .NLPDiagnosticsBenchmarkCommon

const ROOT = repo_root()
const ACTIVE_INPUT = "docs/bmopf_analyze_allocator_telemetry_summary.json"
const CLEAN_INPUT = "docs/bmopf_analyze_allocator_telemetry_clean_summary.json"
const OUTPUT = abspath(isempty(ARGS) ?
    joinpath(ROOT, "docs", "bmopf_analyze_allocator_telemetry_portability_summary.json") : ARGS[1])

active = read_summary(ACTIVE_INPUT)
clean = read_summary(CLEAN_INPUT)
active_source = get(active, "source", Dict{String,Any}())
clean_source = get(clean, "source", Dict{String,Any}())
active_environment = get(active, "environment", Dict{String,Any}())
clean_environment = get(clean, "environment", Dict{String,Any}())
active_stages = Dict(string(get(stage, "stage", "unknown")) => stage for stage in get(active, "stages", Any[]))
clean_stages = Dict(string(get(stage, "stage", "unknown")) => stage for stage in get(clean, "stages", Any[]))
stage_names = sort(collect(intersect(Set(keys(active_stages)), Set(keys(clean_stages)))))

mismatches = Dict{String,Any}()
for name in ("case", "stage_labels")
    get(active_source, name, nothing) == get(clean_source, name, nothing) ||
        (mismatches[name] = Dict("active" => get(active_source, name, nothing), "clean" => get(clean_source, name, nothing)))
end
for name in ("variable_count", "constraint_count", "finding_count", "stage_count", "allocator_peak_available_count")
    get(active, name, nothing) == get(clean, name, nothing) ||
        (mismatches[name] = Dict("active" => get(active, name, nothing), "clean" => get(clean, name, nothing)))
end
environment_distinct = get(active_environment, "git_revision", nothing) != get(clean_environment, "git_revision", nothing) ||
    get(active_environment, "active_project", nothing) != get(clean_environment, "active_project", nothing)
stage_rows = Dict{String,Any}[]
nonzero_difference_count = Ref(0)
for name in stage_names
    active_delta = get(active_stages[name], "allocator_delta", Dict{String,Any}())
    clean_delta = get(clean_stages[name], "allocator_delta", Dict{String,Any}())
    size_in_use_delta = get(clean_delta, "size_in_use_delta_bytes", nothing) isa Integer && get(active_delta, "size_in_use_delta_bytes", nothing) isa Integer ?
        clean_delta["size_in_use_delta_bytes"] - active_delta["size_in_use_delta_bytes"] : nothing
    size_allocated_delta = get(clean_delta, "size_allocated_delta_bytes", nothing) isa Integer && get(active_delta, "size_allocated_delta_bytes", nothing) isa Integer ?
        clean_delta["size_allocated_delta_bytes"] - active_delta["size_allocated_delta_bytes"] : nothing
    nonzero = (size_in_use_delta isa Integer && size_in_use_delta != 0) ||
        (size_allocated_delta isa Integer && size_allocated_delta != 0)
    nonzero && (nonzero_difference_count[] += 1)
    push!(stage_rows, Dict(
        "stage" => name,
        "active_size_in_use_delta_bytes" => get(active_delta, "size_in_use_delta_bytes", nothing),
        "clean_size_in_use_delta_bytes" => get(clean_delta, "size_in_use_delta_bytes", nothing),
        "clean_minus_active_size_in_use_delta_bytes" => size_in_use_delta,
        "active_size_allocated_delta_bytes" => get(active_delta, "size_allocated_delta_bytes", nothing),
        "clean_size_allocated_delta_bytes" => get(clean_delta, "size_allocated_delta_bytes", nothing),
        "clean_minus_active_size_allocated_delta_bytes" => size_allocated_delta,
        "peak_field_available_active" => get(active_delta, "peak_field_available", false),
        "peak_field_available_clean" => get(clean_delta, "peak_field_available", false),
    ))
end

semantic_match = isempty(mismatches) && environment_distinct && stage_names == ["analyze", "build", "kcl", "parse"]
write_json(OUTPUT, Dict{String,Any}(
    "schema_version" => "nlpdiagnostics-bmopf-analyze-allocator-telemetry-comparison-v1",
    "status" => semantic_match ? "cross_environment_allocator_candidate" : "candidate_requires_review",
    "source" => Dict(
        "runner" => "benchmarks/compare_bmopf_analyze_allocator_telemetry.jl",
        "active_input" => ACTIVE_INPUT,
        "clean_input" => CLEAN_INPUT,
        "comparison_required_for_portable_claim" => true,
    ),
    "environment_distinct" => environment_distinct,
    "mismatches" => mismatches,
    "stage_count" => length(stage_rows),
    "nonzero_stage_difference_count" => nonzero_difference_count[],
    "semantic_comparison" => Dict(
        "status" => semantic_match ? "matched" : "mismatch",
        "stage_names" => stage_names,
        "mismatch_count" => length(mismatches),
    ),
    "resource_comparison" => Dict(
        "status" => "descriptive_only",
        "stages" => stage_rows,
        "interpretation" => "Current allocator deltas vary across environments and are useful for attribution only; peak-field availability remains false in both runs.",
    ),
    "interpretation" => Dict(
        "claim" => "The two reviewed environments expose matching stage coverage and current-allocation telemetry for the same analyze fixture.",
        "does_not_establish" => [
            "allocator-level peak memory",
            "portable retained-memory limits",
            "performance or solver scaling",
        ],
        "next_review" => "Obtain a peak-capable allocator measurement or record an explicit release boundary.",
    ),
))
println("wrote BMOPFTools analyze allocator comparison to $OUTPUT")
