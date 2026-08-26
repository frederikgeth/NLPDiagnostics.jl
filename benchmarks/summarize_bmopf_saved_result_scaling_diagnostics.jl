#!/usr/bin/env julia

"""Classify paired SI/PU saved-result rank outcomes from the campaign ledger."""

using JSON

Base.include(@__MODULE__, joinpath(@__DIR__, "common.jl"))
using .NLPDiagnosticsBenchmarkCommon: git_revision, git_status_entries, write_json

const ROOT = abspath(joinpath(@__DIR__, ".."))
const CAMPAIGN = abspath(get(
    ENV,
    "NLPDIAGNOSTICS_BMOPF_CAMPAIGN_SUMMARY",
    joinpath(ROOT, "docs", "bmopf_saved_result_sparse_rank_campaign_summary.json"),
))
const OUTPUT = abspath(isempty(ARGS) ?
    joinpath(ROOT, "docs", "bmopf_saved_result_scaling_diagnostics_summary.json") : ARGS[1])

campaign = JSON.parsefile(CAMPAIGN)
campaign isa AbstractDict || error("campaign summary is not a JSON object: $CAMPAIGN")
records = get(campaign, "records", Any[])
records isa AbstractVector || error("campaign records are not an array: $CAMPAIGN")

_dict(value) = value isa AbstractDict ? Dict{String,Any}(String(k) => v for (k, v) in value) : Dict{String,Any}()
_number(value) = value isa Number ? value : nothing

by_snapshot = Dict{String,Dict{String,Dict{String,Any}}}()
for value in records
    value isa AbstractDict || continue
    record = _dict(value)
    snapshot = get(record, "snapshot", nothing)
    units = get(record, "result_units", nothing)
    snapshot isa AbstractString || continue
    units isa AbstractString || continue
    get!(by_snapshot, String(snapshot), Dict{String,Dict{String,Any}}())[lowercase(String(units))] = record
end

pairs = Dict{String,Any}[]
for snapshot in sort!(collect(keys(by_snapshot)))
    units = by_snapshot[snapshot]
    haskey(units, "pu") && haskey(units, "si") || continue
    pu = units["pu"]
    si = units["si"]
    pu_delta = _number(get(pu, "rank_delta", nothing))
    si_delta = _number(get(si, "rank_delta", nothing))
    rank_outcome_differs = !isnothing(pu_delta) && !isnothing(si_delta) && pu_delta != si_delta
    push!(pairs, Dict{String,Any}(
        "snapshot" => snapshot,
        "pu_rank_delta" => pu_delta,
        "si_rank_delta" => si_delta,
        "pu_scaling_sensitive" => get(pu, "scaling_sensitive", false),
        "si_scaling_sensitive" => get(si, "scaling_sensitive", false),
        "pu_point_provenance_complete" => get(pu, "point_provenance_complete", false),
        "si_point_provenance_complete" => get(si, "point_provenance_complete", false),
        "pu_mapping_diagnostics" => get(pu, "mapping_diagnostics", Dict{String,Any}()),
        "si_mapping_diagnostics" => get(si, "mapping_diagnostics", Dict{String,Any}()),
        "rank_outcome_differs" => rank_outcome_differs,
        "si_condition_proxy_ratio" => begin
            value = get(si, "condition_proxy_ratio_row_column_over_unscaled", nothing)
            value isa Number ? value : nothing
        end,
        "pu_condition_proxy_ratio" => begin
            value = get(pu, "condition_proxy_ratio_row_column_over_unscaled", nothing)
            value isa Number ? value : nothing
        end,
    ))
end

sensitive_records = Dict{String,Any}[]
for value in records
    record = _dict(value)
    get(record, "scaling_sensitive", false) || continue
    push!(sensitive_records, Dict{String,Any}(
        "snapshot" => get(record, "snapshot", nothing),
        "result_units" => get(record, "result_units", nothing),
        "rank_delta" => get(record, "rank_delta", nothing),
        "point_provenance_complete" => get(record, "point_provenance_complete", false),
        "mapping_diagnostics" => get(record, "mapping_diagnostics", Dict{String,Any}()),
        "unscaled_rank" => get(record, "unscaled_rank", nothing),
        "row_column_rank" => get(record, "row_column_rank", nothing),
        "condition_proxy_ratio_row_column_over_unscaled" => get(record, "condition_proxy_ratio_row_column_over_unscaled", nothing),
    ))
end

unit_dependent_pairs = filter(pair -> get(pair, "rank_outcome_differs", false), pairs)
incomplete_sensitive_records = filter(
    record -> !get(record, "point_provenance_complete", false),
    sensitive_records,
)

mapping_fallback_counts = [
    get(get(record, "mapping_diagnostics", Dict{String,Any}()), "fallback_coordinate_count", nothing)
    for record in sensitive_records
]

write_json(OUTPUT, Dict{String,Any}(
    "schema_version" => "nlpdiagnostics-bmopf-saved-result-scaling-diagnostics-v1",
    "source" => Dict{String,Any}(
        "campaign_summary" => CAMPAIGN,
        "runner" => "benchmarks/summarize_bmopf_saved_result_scaling_diagnostics.jl",
        "pairing_policy" => "Pair records by exact snapshot path and compare SI versus PU rank outcomes.",
    ),
    "environment" => Dict{String,Any}(
        "julia_version" => string(VERSION),
        "git_revision" => git_revision(),
        "git_worktree_dirty" => !isempty(git_status_entries()),
    ),
    "campaign_record_count" => length(records),
    "paired_snapshot_count" => length(pairs),
    "unit_dependent_rank_outcome_count" => length(unit_dependent_pairs),
    "sensitive_record_count" => length(sensitive_records),
    "incomplete_provenance_sensitive_record_count" => length(incomplete_sensitive_records),
    "sensitive_mapping_fallback_coordinate_counts" => mapping_fallback_counts,
    "pairs" => pairs,
    "sensitive_records" => sensitive_records,
    "interpretation" => "The paired comparison identifies unit-dependent sparse-rank outcomes without treating them as physical singularity claims. Incomplete point provenance is retained as a release boundary; the affected endpoints require provenance completion before policy conclusions.",
    "next_action" => "Complete or explain LN SI saved-result provenance for the affected snapshots, then repeat the paired diagnostic on the t15/t16 tranche.",
))
println("wrote BMOPF saved-result scaling diagnostics to $OUTPUT")
