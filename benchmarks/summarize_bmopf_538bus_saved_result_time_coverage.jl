#!/usr/bin/env julia

"""Inventory available 538-bus saved-result endpoints before profiling.

This is a source-corpus readiness artifact. It does not construct a BMOPF
model or infer numerical rank; it records which SI/PU result files exist and
which endpoints are already represented in the sparse-rank campaign ledger.
"""

using JSON

Base.include(@__MODULE__, joinpath(@__DIR__, "common.jl"))
using .NLPDiagnosticsBenchmarkCommon: git_revision, git_status_entries, write_json

const ROOT = abspath(get(ENV, "NLPDIAGNOSTICS_BMOPF_BENCHMARK_ROOT",
    "/Users/uqfgeth/Documents/GitHub/BMOPFDraftData/benchmarks"))
const CAMPAIGN = abspath(get(ENV, "NLPDIAGNOSTICS_BMOPF_CAMPAIGN_SUMMARY",
    joinpath(@__DIR__, "..", "docs", "bmopf_saved_result_sparse_rank_campaign_summary.json")))
const OUTPUT = abspath(isempty(ARGS) ?
    joinpath(@__DIR__, "..", "docs", "bmopf_538bus_saved_result_time_coverage_summary.json") : ARGS[1])

isdir(ROOT) || error("benchmark root is missing: $ROOT")
isfile(CAMPAIGN) || error("campaign summary is missing: $CAMPAIGN")

campaign = JSON.parsefile(CAMPAIGN)
campaign isa AbstractDict || error("campaign summary is not a JSON object: $CAMPAIGN")
campaign_records = get(campaign, "records", Any[])
campaign_records isa AbstractVector || error("campaign records are not an array: $CAMPAIGN")

profiled = Set{Tuple{String,String}}()
for record in campaign_records
    record isa AbstractDict || continue
    snapshot = get(record, "snapshot", nothing)
    units = get(record, "result_units", nothing)
    snapshot isa AbstractString || continue
    units isa AbstractString || continue
    startswith(snapshot, "ENWLsnapshots/538bus_") || continue
    push!(profiled, (String(snapshot), lowercase(String(units))))
end

records = Dict{String,Any}[]
for family in ("538bus_LN", "538bus_LG")
    directory = joinpath(ROOT, "ENWLsnapshots", family)
    isdir(directory) || error("538-bus family directory is missing: $directory")
    snapshots = sort(filter(name -> endswith(name, ".bmopf.json"), readdir(directory)))
    for name in snapshots
        relative = joinpath("ENWLsnapshots", family, name)
        available_units = String[]
        for units in ("si", "pu")
            result_path = replace(joinpath(directory, name), ".bmopf.json" => "_result_$(units).json")
            isfile(result_path) && push!(available_units, units)
        end
        profiled_units = sort([units for units in available_units if (relative, units) in profiled])
        missing_profile_units = sort(setdiff(available_units, profiled_units))
        push!(records, Dict{String,Any}(
            "snapshot" => replace(relative, '\\' => '/'),
            "available_result_units" => available_units,
            "profiled_result_units" => profiled_units,
            "missing_profile_units" => missing_profile_units,
        ))
    end
end

available_endpoint_count = sum(length(get(record, "available_result_units", String[])) for record in records)
profiled_endpoint_count = sum(length(get(record, "profiled_result_units", String[])) for record in records)
available_unit_counts = Dict(
    units => count(units in get(record, "available_result_units", String[]) for record in records)
    for units in ("pu", "si")
)
profiled_unit_counts = Dict(
    units => count(units in get(record, "profiled_result_units", String[]) for record in records)
    for units in ("pu", "si")
)

write_json(OUTPUT, Dict{String,Any}(
    "schema_version" => "nlpdiagnostics-bmopf-538bus-saved-result-time-coverage-v1",
    "source" => Dict{String,Any}(
        "benchmark_root" => ROOT,
        "campaign_summary" => CAMPAIGN,
        "runner" => "benchmarks/summarize_bmopf_538bus_saved_result_time_coverage.jl",
        "result_units" => ["si", "pu"],
    ),
    "environment" => Dict{String,Any}(
        "julia_version" => string(VERSION),
        "git_revision" => git_revision(),
        "git_worktree_dirty" => !isempty(git_status_entries()),
    ),
    "snapshot_count" => length(records),
    "available_endpoint_count" => available_endpoint_count,
    "profiled_endpoint_count" => profiled_endpoint_count,
    "unprofiled_endpoint_count" => available_endpoint_count - profiled_endpoint_count,
    "available_unit_counts" => available_unit_counts,
    "profiled_unit_counts" => profiled_unit_counts,
    "records" => records,
    "interpretation" => "This inventory describes source-file readiness and campaign coverage only. Unprofiled endpoints require the BMOPFTools bridge and guarded sparse-rank workflow before numerical conclusions are drawn.",
))
println("wrote 538-bus saved-result time coverage summary to $OUTPUT")
