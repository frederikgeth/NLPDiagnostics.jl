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

function _mapping_diagnostics(source)
    input = get(source, "input", nothing)
    input isa AbstractString && isfile(input) || return Dict{String,Any}()
    raw = try
        JSON.parsefile(input)
    catch
        return Dict{String,Any}()
    end
    profile = _dict(get(raw, "profile", nothing))
    mapping = _dict(get(profile, "bmopf_saved_result_mapping_report", nothing))
    metadata = _dict(get(mapping, "metadata", nothing))
    isempty(metadata) && return Dict{String,Any}()
    selected = (
        "mapped_coordinate_count",
        "fallback_coordinate_count",
        "registered_coordinate_count",
        "unmapped_registered_coordinate_count",
        "mapped_registered_coordinate_fraction",
        "mapped_families",
        "projected_families",
        "projection_contracts",
        "unit_fingerprint_count",
        "unit_fingerprint_zero_magnitude_count",
    )
    result = Dict{String,Any}()
    for key in selected
        metadata_key = "bmopf_saved_result_$(key)"
        haskey(metadata, metadata_key) && (result[key] = metadata[metadata_key])
    end
    return result
end

summaries = [_load(path) for path in input_paths]
records = Dict{String,Any}[]
for summary in summaries
    evaluation = _dict(get(summary, "evaluation", nothing))
    sparse_qr = _dict(get(summary, "sparse_qr", nothing))
    comparison = _dict(get(sparse_qr, "comparison", nothing))
    source = _dict(get(summary, "source", nothing))
    mapping_diagnostics = _mapping_diagnostics(source)
    unscaled_condition_proxy = get(sparse_qr, "unscaled_condition_proxy", nothing)
    row_column_condition_proxy = get(sparse_qr, "row_column_condition_proxy", nothing)
    condition_proxy_ratio = if unscaled_condition_proxy isa Number &&
            row_column_condition_proxy isa Number && unscaled_condition_proxy > 0
        row_column_condition_proxy / unscaled_condition_proxy
    else
        nothing
    end
    push!(records, Dict{String,Any}(
        "snapshot" => get(summary, "snapshot", nothing),
        "result_units" => get(source, "result_units", nothing),
        "result_field_units" => get(source, "result_field_units", nothing),
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
        "unscaled_condition_proxy" => unscaled_condition_proxy,
        "row_column_condition_proxy" => row_column_condition_proxy,
        "condition_proxy_ratio_row_column_over_unscaled" => condition_proxy_ratio,
        "unscaled_fill_ratio" => get(sparse_qr, "unscaled_fill_ratio", nothing),
        "row_column_fill_ratio" => get(sparse_qr, "row_column_fill_ratio", nothing),
        "dense_available" => get(_dict(get(summary, "dense_rank", nothing)), "available", false),
        "dense_reason" => get(_dict(get(summary, "dense_rank", nothing)), "reason", nothing),
        "mapping_diagnostics" => mapping_diagnostics,
    ))
end

_numeric(records, key) = [value for value in get.(records, key, nothing) if value isa Number]
function _span(records, key)
    values = _numeric(records, key)
    isempty(values) && return Dict{String,Any}("available" => false)
    minimum_value, maximum_value = extrema(values)
    return Dict{String,Any}(
        "available" => true,
        "min" => minimum_value,
        "max" => maximum_value,
        "range" => maximum_value - minimum_value,
        "count" => length(values),
    )
end

unit_groups = Dict{String,Vector{Dict{String,Any}}}()
for record in records
    units = get(record, "result_units", nothing)
    units isa AbstractString || continue
    push!(get!(unit_groups, String(units), Dict{String,Any}[]), record)
end
span_keys = [
    "unscaled_rank",
    "row_column_rank",
    "rank_delta",
    "unscaled_condition_proxy",
    "row_column_condition_proxy",
    "condition_proxy_ratio_row_column_over_unscaled",
    "unscaled_fill_ratio",
    "row_column_fill_ratio",
]
endpoint_span_diagnostics = Dict{String,Any}(
    "overall" => Dict(key => _span(records, key) for key in span_keys),
    "by_result_units" => Dict(
        units => Dict(
            "record_count" => length(group),
            "spans" => Dict(key => _span(group, key) for key in span_keys),
        ) for (units, group) in sort!(collect(unit_groups); by = first)
    ),
    "interpretation" => "Endpoint spans describe observed rank, condition-proxy, and fill-ratio variation across this saved-result corpus. They are comparative diagnostics, not a universal conditioning or scaling certificate.",
)

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
    "result_units" => sort!(unique(filter(!isnothing, get.(records, "result_units", nothing)))),
    "endpoint_span_diagnostics" => endpoint_span_diagnostics,
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
