#!/usr/bin/env julia

"""Compare promoted 538-bus SI sparse-rank profiles with the old campaign."""

using JSON

Base.include(@__MODULE__, joinpath(@__DIR__, "common.jl"))
using .NLPDiagnosticsBenchmarkCommon: git_revision, git_status_entries, write_json

length(ARGS) == 3 || error(
    "usage: summarize_bmopf_promoted_sparse_rank.jl old-campaign.json profile-dir output.json",
)
old_path = abspath(ARGS[1])
profile_dir = abspath(ARGS[2])
output_path = abspath(ARGS[3])
isfile(old_path) || error("old campaign summary is missing: $old_path")
isdir(profile_dir) || error("profile directory is missing: $profile_dir")
old = JSON.parsefile(old_path)
old_index = Dict{String,Any}()
for record in get(old, "records", Any[])
    record isa AbstractDict || continue
    snapshot = String(get(record, "snapshot", ""))
    get(record, "result_units", nothing) == "si" || continue
    old_index[snapshot] = record
end

function _number(value)
    value isa Number && return value
    try
        return parse(Float64, String(value))
    catch
        return nothing
    end
end

function _profile_record(path)
    raw = JSON.parsefile(path)
    profile = get(raw, "profile", Dict())
    nested = get(profile, "profile", Dict())
    reports = get(nested, "reports", Dict())
    numerical = get(reports, "numerical", Dict())
    metadata = get(numerical, "metadata", Dict())
    mapping = get(profile, "bmopf_saved_result_mapping_report", Dict())
    mapping_metadata = get(mapping, "metadata", Dict())
    snapshot = String(get(raw, "snapshot", ""))
    mapped = get(mapping_metadata, "bmopf_saved_result_mapped_coordinate_count", nothing)
    fallback = get(mapping_metadata, "bmopf_saved_result_fallback_coordinate_count", nothing)
    registered = get(mapping_metadata, "bmopf_saved_result_registered_coordinate_count", nothing)
    mapped_value = _number(mapped)
    fallback_value = _number(fallback)
    registered_value = _number(registered)
    return Dict{String,Any}(
        "snapshot" => snapshot,
        "result_units" => "si",
        "model_variable_count" => get(raw, "model_variable_count", nothing),
        "point_provenance_complete" => get(metadata, "evaluation_point_provenance_complete", nothing) == "true" || get(metadata, "evaluation_point_provenance_complete", false) === true,
        "point_provenance_kind" => get(metadata, "evaluation_point_provenance_kind", nothing),
        "unscaled_rank" => _number(get(metadata, "sparse_qr_rank", nothing)),
        "row_column_rank" => _number(get(metadata, "sparse_qr_row_column_rank", nothing)),
        "unscaled_condition_proxy" => _number(get(metadata, "sparse_qr_condition_proxy", nothing)),
        "row_column_condition_proxy" => _number(get(metadata, "scaled_sparse_qr_condition_proxy", nothing)),
        "mapped_coordinate_count" => mapped_value,
        "fallback_coordinate_count" => fallback_value,
        "registered_coordinate_count" => registered_value,
        "mapping_complete" => fallback_value == 0 && mapped_value == registered_value,
    )
end

records = Dict{String,Any}[]
for name in sort!(readdir(profile_dir))
    endswith(name, ".json") || continue
    name in ("campaign_manifest.json", "index.json") && continue
    current = _profile_record(joinpath(profile_dir, name))
    previous = get(old_index, current["snapshot"], Dict{String,Any}())
    current_rank = current["unscaled_rank"]
    current_row_rank = current["row_column_rank"]
    current["rank_delta"] = current_rank isa Number && current_row_rank isa Number ? current_row_rank - current_rank : nothing
    current["scaling_sensitive"] = current["rank_delta"] isa Number && current["rank_delta"] != 0
    current["before"] = Dict{String,Any}(
        "rank_delta" => get(previous, "rank_delta", nothing),
        "scaling_sensitive" => get(previous, "scaling_sensitive", nothing),
        "point_provenance_complete" => get(previous, "point_provenance_complete", nothing),
        "mapping_diagnostics" => get(previous, "mapping_diagnostics", Dict()),
    )
    push!(records, current)
end

after_incomplete = count(!get(record, "mapping_complete", false) for record in records)
after_sensitive = count(get(record, "scaling_sensitive", false) for record in records)
before_incomplete = count(get(get(record, "before", Dict()), "point_provenance_complete", nothing) === false for record in records)
before_sensitive = count(get(get(record, "before", Dict()), "scaling_sensitive", false) === true for record in records)
payload = Dict{String,Any}(
    "schema_version" => "nlpdiagnostics-bmopf-promoted-sparse-rank-v1",
    "source" => Dict{String,Any}(
        "old_campaign" => old_path,
        "profile_directory" => profile_dir,
        "runner" => "benchmarks/bmopf_draft_corpus.jl",
        "summarizer" => "benchmarks/summarize_bmopf_promoted_sparse_rank.jl",
    ),
    "environment" => Dict{String,Any}(
        "git_revision" => git_revision(),
        "git_worktree_dirty" => !isempty(git_status_entries()),
    ),
    "record_count" => length(records),
    "before_incomplete_provenance_count" => before_incomplete,
    "after_incomplete_mapping_count" => after_incomplete,
    "before_scaling_sensitive_count" => before_sensitive,
    "after_scaling_sensitive_count" => after_sensitive,
    "all_after_mappings_complete" => after_incomplete == 0 && !isempty(records),
    "records" => records,
    "interpretation" => "This is a before/after diagnostic for the seven promoted SI endpoints. It confirms mapping and local sparse-rank behavior after explicit promotion; it does not generalize rank stability beyond this declared corpus.",
)
write_json(output_path, payload)
println("wrote promoted BMOPF sparse-rank comparison to $output_path")
