#!/usr/bin/env julia

"""Summarize a fresh paired SI/PU BMOPF t15/t16 sparse-profile tranche."""

using JSON

Base.include(@__MODULE__, joinpath(@__DIR__, "common.jl"))
using .NLPDiagnosticsBenchmarkCommon: git_revision, git_status_entries, write_json

length(ARGS) == 3 || error(
    "usage: summarize_bmopf_t15t16_tranche.jl output.json si_directory pu_directory",
)
output_path = abspath(ARGS[1])
si_directory = abspath(ARGS[2])
pu_directory = abspath(ARGS[3])

_dict(value) = value isa AbstractDict ? Dict{String,Any}(String(k) => v for (k, v) in value) : Dict{String,Any}()
function _number(value)
    value isa Number && return value
    value isa AbstractString || return nothing
    parsed = tryparse(Int, value)
    parsed !== nothing && return parsed
    tryparse(Float64, value)
end
_bool(value) = value isa Bool ? value : lowercase(String(value)) == "true"

function _records(directory, units)
    isdir(directory) || error("profile directory is missing: $directory")
    records = Dict{String,Any}[]
    for path in sort(filter(path -> endswith(path, ".json") && !endswith(path, "index.json") && !endswith(path, "campaign_manifest.json"), readdir(directory; join = true)))
        raw = _dict(JSON.parsefile(path))
        profile = _dict(get(raw, "profile", nothing))
        nested_profile = _dict(get(profile, "profile", nothing))
        reports = _dict(get(nested_profile, "reports", nothing))
        numerical = _dict(get(reports, "numerical", nothing))
        metadata = _dict(get(numerical, "metadata", nothing))
        mapping = _dict(get(profile, "bmopf_saved_result_mapping_report", nothing))
        mapping_metadata = _dict(get(mapping, "metadata", nothing))
        mapped = _number(get(mapping_metadata, "bmopf_saved_result_mapped_coordinate_count", nothing))
        registered = _number(get(mapping_metadata, "bmopf_saved_result_registered_coordinate_count", nothing))
        fallback = _number(get(mapping_metadata, "bmopf_saved_result_fallback_coordinate_count", nothing))
        sparse_rank = _number(get(metadata, "sparse_qr_rank", nothing))
        row_column_rank = _number(get(metadata, "sparse_qr_row_column_rank", nothing))
        rank_delta = sparse_rank !== nothing && row_column_rank !== nothing ? row_column_rank - sparse_rank : nothing
        provenance_complete = _bool(get(metadata, "evaluation_point_provenance_complete", false))
        mapping_complete = provenance_complete && mapped !== nothing && registered !== nothing && mapped == registered && fallback == 0
        snapshot = get(raw, "snapshot", nothing)
        snapshot isa AbstractString || continue
        push!(records, Dict{String,Any}(
            "snapshot" => snapshot,
            "result_units" => units,
            "source_file" => path,
            "model_variable_count" => get(raw, "model_variable_count", nothing),
            "model_constraint_count" => get(raw, "scalar_constraint_row_count", nothing),
            "point_provenance_kind" => get(metadata, "evaluation_point_provenance_kind", nothing),
            "point_provenance_complete" => provenance_complete,
            "mapping_complete" => mapping_complete,
            "mapped_coordinate_count" => mapped,
            "registered_coordinate_count" => registered,
            "fallback_coordinate_count" => fallback,
            "unscaled_rank" => sparse_rank,
            "row_column_rank" => row_column_rank,
            "rank_delta" => rank_delta,
            "scaling_sensitive" => rank_delta !== nothing && rank_delta != 0,
            "unscaled_condition_proxy" => _number(get(metadata, "sparse_qr_condition_proxy", nothing)),
            "scaled_condition_proxy" => _number(get(metadata, "scaled_sparse_qr_condition_proxy", nothing)),
            "sparse_qr_rank_available" => _bool(get(metadata, "sparse_qr_rank_available", false)),
            "scaled_sparse_qr_rank_available" => _bool(get(metadata, "scaled_sparse_qr_rank_available", false)),
        ))
    end
    return records
end

records = vcat(_records(si_directory, "si"), _records(pu_directory, "pu"))
by_snapshot = Dict{String,Dict{String,Dict{String,Any}}}()
for record in records
    snapshot = String(record["snapshot"])
    units = String(record["result_units"])
    get!(by_snapshot, snapshot, Dict{String,Dict{String,Any}}())[units] = record
end

pairs = Dict{String,Any}[]
for snapshot in sort!(collect(keys(by_snapshot)))
    units = by_snapshot[snapshot]
    haskey(units, "si") && haskey(units, "pu") || continue
    si = units["si"]
    pu = units["pu"]
    rank_outcome_differs = si["unscaled_rank"] != pu["unscaled_rank"] || si["row_column_rank"] != pu["row_column_rank"] || si["rank_delta"] != pu["rank_delta"]
    push!(pairs, Dict{String,Any}(
        "snapshot" => snapshot,
        "si_rank_delta" => si["rank_delta"],
        "pu_rank_delta" => pu["rank_delta"],
        "si_mapping_complete" => si["mapping_complete"],
        "pu_mapping_complete" => pu["mapping_complete"],
        "rank_outcome_differs" => rank_outcome_differs,
        "si_condition_proxy" => si["unscaled_condition_proxy"],
        "pu_condition_proxy" => pu["unscaled_condition_proxy"],
    ))
end

write_json(output_path, Dict{String,Any}(
    "schema_version" => "nlpdiagnostics-bmopf-t15-t16-tranche-v1",
    "source" => Dict{String,Any}(
        "runner" => "benchmarks/bmopf_draft_corpus.jl",
        "summarizer" => "benchmarks/summarize_bmopf_t15t16_tranche.jl",
        "si_profile_directory" => si_directory,
        "pu_profile_directory" => pu_directory,
        "point_policy" => "saved_result",
        "dense_policy" => "disabled by explicit work guard",
    ),
    "environment" => Dict{String,Any}(
        "julia_version" => string(VERSION),
        "git_revision" => git_revision(),
        "git_worktree_dirty" => !isempty(git_status_entries()),
    ),
    "endpoint_count" => length(records),
    "snapshot_count" => length(unique(get.(records, "snapshot", nothing))),
    "paired_snapshot_count" => length(pairs),
    "mapping_complete_endpoint_count" => count(get.(records, "mapping_complete", false)),
    "point_provenance_complete_endpoint_count" => count(get.(records, "point_provenance_complete", false)),
    "scaling_sensitive_endpoint_count" => count(get.(records, "scaling_sensitive", false)),
    "unit_dependent_rank_outcome_count" => count(get.(pairs, "rank_outcome_differs", false)),
    "all_mapping_complete" => all(get.(records, "mapping_complete", false)),
    "all_sparse_estimates_available" => all(get.(records, "sparse_qr_rank_available", false)),
    "pairs" => pairs,
    "records" => records,
    "interpretation" => "This is a fresh reviewed t15/t16 endpoint tranche. SI and PU are paired by exact snapshot path; sparse rank stability and saved-result mapping completeness are local evidence, not universal conditioning or physical-singularity claims.",
    "next_action" => "Use the tranche to classify remaining rank-policy/backend threshold disagreements before any release decision.",
))
println("wrote BMOPF t15/t16 tranche summary to $output_path")
