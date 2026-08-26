#!/usr/bin/env julia

"""Aggregate saved-result sparse-QR screen summaries across BMOPF snapshots."""

using JSON

Base.include(@__MODULE__, joinpath(@__DIR__, "common.jl"))
using .NLPDiagnosticsBenchmarkCommon: git_revision, git_status_entries, write_json

length(ARGS) >= 2 || error(
    "usage: summarize_bmopf_saved_result_sparse_rank_campaign.jl output.json summary1.json [summary2.json ...]",
)
output_path = abspath(ARGS[1])
input_paths = abspath.(ARGS[2:end])

_dict(value) = value isa AbstractDict ? Dict{String,Any}(String(k) => v for (k, v) in value) : Dict{String,Any}()
function _load(path)
    isfile(path) || error("summary is missing: $path")
    value = JSON.parsefile(path)
    value isa AbstractDict || error("summary is not a JSON object: $path")
    return _dict(value)
end

summaries = [_load(path) for path in input_paths]
records = Dict{String,Any}[]
for summary in summaries
    evaluation = _dict(get(summary, "evaluation", nothing))
    sparse_qr = _dict(get(summary, "sparse_qr", nothing))
    comparison = _dict(get(sparse_qr, "comparison", nothing))
    push!(records, Dict{String,Any}(
        "snapshot" => get(summary, "snapshot", nothing),
        "model_variable_count" => get(summary, "model_variable_count", nothing),
        "model_constraint_count" => get(summary, "model_constraint_count", nothing),
        "point_provenance_kind" => get(evaluation, "point_provenance_kind", nothing),
        "point_provenance_complete" => get(evaluation, "point_provenance_complete", false),
        "unscaled_rank" => get(comparison, "unscaled_rank", nothing),
        "row_column_rank" => get(comparison, "row_column_rank", nothing),
        "rank_delta" => get(comparison, "row_column_minus_unscaled_rank", nothing),
        "scaling_sensitive" => get(comparison, "scaling_sensitive", false),
        "unscaled_available" => get(comparison, "unscaled_available", false),
        "row_column_available" => get(comparison, "row_column_available", false),
        "dense_available" => get(_dict(get(summary, "dense_rank", nothing)), "available", false),
        "dense_reason" => get(_dict(get(summary, "dense_rank", nothing)), "reason", nothing),
    ))
end

write_json(output_path, Dict{String,Any}(
    "schema_version" => "nlpdiagnostics-bmopf-saved-result-sparse-rank-campaign-v1",
    "source" => Dict{String,Any}(
        "runner" => "benchmarks/bmopf_draft_corpus.jl",
        "summarizer" => "benchmarks/summarize_bmopf_saved_result_sparse_rank_campaign.jl",
        "input_summaries" => input_paths,
        "point_policy" => "saved_result",
        "dense_policy" => "disabled by explicit work guard",
    ),
    "environment" => Dict{String,Any}(
        "julia_version" => string(VERSION),
        "git_revision" => git_revision(),
        "git_worktree_dirty" => !isempty(git_status_entries()),
    ),
    "record_count" => length(records),
    "all_point_provenance_complete" => all(get(record, "point_provenance_complete", false) for record in records),
    "all_sparse_estimates_available" => all(
        get(record, "unscaled_available", false) && get(record, "row_column_available", false)
        for record in records
    ),
    "scaling_sensitive_count" => count(record -> get(record, "scaling_sensitive", false), records),
    "scaling_stable_count" => count(record -> !get(record, "scaling_sensitive", false), records),
    "records" => records,
    "interpretation" => "Saved solver-result points provide sparse-only rank evidence with explicit provenance. Dense rank remains guarded; rank stability is local numerical evidence and not a physical gauge or universal policy certificate.",
))
println("wrote saved-result sparse rank campaign summary to $output_path")
