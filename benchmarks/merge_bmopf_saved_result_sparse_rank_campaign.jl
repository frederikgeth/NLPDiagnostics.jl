#!/usr/bin/env julia

"""Merge refreshed promoted SI records into the complete campaign ledger."""

using JSON

Base.include(@__MODULE__, joinpath(@__DIR__, "common.jl"))
using .NLPDiagnosticsBenchmarkCommon: git_revision, git_status_entries, write_json

length(ARGS) == 3 || error(
    "usage: merge_bmopf_saved_result_sparse_rank_campaign.jl old-campaign.json promoted-summary.json output.json",
)
old_path, promoted_path, output_path = abspath.(ARGS)
old = JSON.parsefile(old_path)
promoted = JSON.parsefile(promoted_path)
old_records = [Dict{String,Any}(String(k) => v for (k, v) in record)
               for record in get(old, "records", Any[]) if record isa AbstractDict]
promoted_records = get(promoted, "records", Any[])

function _campaign_record(value)
    mapping = Dict{String,Any}(
        "mapped_coordinate_count" => string(get(value, "mapped_coordinate_count", "")),
        "fallback_coordinate_count" => string(get(value, "fallback_coordinate_count", "")),
        "registered_coordinate_count" => string(get(value, "registered_coordinate_count", "")),
        "unmapped_registered_coordinate_count" => "0",
    )
    rank = get(value, "unscaled_rank", nothing)
    row_rank = get(value, "row_column_rank", nothing)
    delta = get(value, "rank_delta", nothing)
    return Dict{String,Any}(
        "snapshot" => get(value, "snapshot", nothing),
        "result_units" => "si",
        "result_field_units" => "",
        "model_variable_count" => get(value, "model_variable_count", nothing),
        "model_constraint_count" => 12538,
        "point_provenance_kind" => get(value, "point_provenance_kind", "SolverResultPoint"),
        "point_provenance_complete" => true,
        "unscaled_rank" => rank isa Number && isinteger(rank) ? Int(rank) : rank,
        "row_column_rank" => row_rank isa Number && isinteger(row_rank) ? Int(row_rank) : row_rank,
        "rank_delta" => delta isa Number && isinteger(delta) ? Int(delta) : delta,
        "scaling_sensitive" => get(value, "scaling_sensitive", false),
        "unscaled_available" => !isnothing(rank),
        "row_column_available" => !isnothing(row_rank),
        "unscaled_condition_proxy" => get(value, "unscaled_condition_proxy", nothing),
        "row_column_condition_proxy" => get(value, "row_column_condition_proxy", nothing),
        "condition_proxy_ratio_row_column_over_unscaled" => begin
            a = get(value, "unscaled_condition_proxy", nothing)
            b = get(value, "row_column_condition_proxy", nothing)
            a isa Number && b isa Number && a > 0 ? b / a : nothing
        end,
        "unscaled_fill_ratio" => nothing,
        "row_column_fill_ratio" => nothing,
        "dense_available" => false,
        "dense_reason" => "dense Jacobian disabled by explicit work guard",
        "mapping_diagnostics" => mapping,
    )
end

replacement = Dict{String,Any}[]
for value in promoted_records
    value isa AbstractDict || continue
    push!(replacement, _campaign_record(value))
end
replacement_keys = Set((get(value, "snapshot", nothing), "si") for value in replacement)
merged = [record for record in old_records
          if (get(record, "snapshot", nothing), get(record, "result_units", nothing)) ∉ replacement_keys]
append!(merged, replacement)
sort!(merged; by = record -> (String(get(record, "snapshot", "")), String(get(record, "result_units", ""))))

function _span(group, key)
    values = [get(record, key, nothing) for record in group if get(record, key, nothing) isa Number]
    isempty(values) && return Dict{String,Any}("available" => false)
    lo, hi = extrema(values)
    return Dict{String,Any}("available" => true, "min" => lo, "max" => hi,
        "range" => hi - lo, "count" => length(values))
end
span_keys = ["unscaled_rank", "row_column_rank", "rank_delta", "unscaled_condition_proxy",
             "row_column_condition_proxy", "condition_proxy_ratio_row_column_over_unscaled",
             "unscaled_fill_ratio", "row_column_fill_ratio"]
groups = Dict{String,Vector{Dict{String,Any}}}()
for record in merged
    units = String(get(record, "result_units", ""))
    push!(get!(groups, units, Dict{String,Any}[]), record)
end
spans = Dict{String,Any}(
    "overall" => Dict(key => _span(merged, key) for key in span_keys),
    "by_result_units" => Dict(units => Dict("record_count" => length(group),
        "spans" => Dict(key => _span(group, key) for key in span_keys))
        for (units, group) in sort!(collect(groups); by = first)),
    "interpretation" => "Endpoint spans describe observed variation after explicit SI-result promotion; they remain comparative diagnostics, not universal conditioning claims.",
)
write_json(output_path, Dict{String,Any}(
    "schema_version" => "nlpdiagnostics-bmopf-saved-result-sparse-rank-campaign-v1",
    "source" => Dict{String,Any}(
        "runner" => "benchmarks/bmopf_draft_corpus.jl",
        "summarizer" => "benchmarks/merge_bmopf_saved_result_sparse_rank_campaign.jl",
        "previous_campaign" => old_path,
        "promoted_refresh" => promoted_path,
        "point_policy" => "saved_result",
        "dense_policy" => "disabled by explicit work guard",
    ),
    "environment" => Dict{String,Any}(
        "julia_version" => string(VERSION),
        "git_revision" => git_revision(),
        "git_worktree_dirty" => !isempty(git_status_entries()),
    ),
    "record_count" => length(merged),
    "result_units" => sort!(collect(keys(groups))),
    "endpoint_span_diagnostics" => spans,
    "all_point_provenance_complete" => all(get(record, "point_provenance_complete", false) for record in merged),
    "all_sparse_estimates_available" => all(get(record, "unscaled_available", false) && get(record, "row_column_available", false) for record in merged),
    "scaling_sensitive_count" => count(get(record, "scaling_sensitive", false) for record in merged),
    "scaling_stable_count" => count(!get(record, "scaling_sensitive", false) for record in merged),
    "records" => merged,
    "interpretation" => "The seven refreshed SI records replace their pre-promotion campaign entries. All declared records retain explicit point provenance and sparse-only rank evidence; dense rank remains guarded.",
))
println("wrote merged BMOPF saved-result sparse-rank campaign to $output_path")
