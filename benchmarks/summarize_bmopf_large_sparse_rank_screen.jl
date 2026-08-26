#!/usr/bin/env julia

"""Summarize a guarded sparse-QR screen on a larger BMOPFTools snapshot.

The input is a `bmopf_draft_corpus.jl` profile result produced with
`point_policy=zero` and dense rank disabled. This intentionally records a
synthetic coordinate probe, not a solver endpoint or a physical nullspace.
"""

using JSON

Base.include(@__MODULE__, joinpath(@__DIR__, "common.jl"))
using .NLPDiagnosticsBenchmarkCommon: git_revision, git_status_entries, write_json

length(ARGS) in (1, 2) || error(
    "usage: summarize_bmopf_large_sparse_rank_screen.jl profile-result.json [summary.json]",
)
input_path = abspath(ARGS[1])
isfile(input_path) || error("profile result is missing: $input_path")
output_path = length(ARGS) == 2 ? abspath(ARGS[2]) :
    joinpath(dirname(input_path), "bmopf_large_sparse_rank_screen_summary.json")

result = JSON.parsefile(input_path)
result isa AbstractDict || error("profile result is not a JSON object: $input_path")

# The runner records the saved-result unit system in the campaign manifest,
# rather than repeating it in each profile record. Carry that provenance into
# the compact summary so SI and per-unit screens remain distinguishable when
# they are aggregated later.
manifest_metadata = let manifest_path = joinpath(dirname(input_path), "campaign_manifest.json")
    if isfile(manifest_path)
        manifest = JSON.parsefile(manifest_path)
        manifest isa AbstractDict ? manifest : Dict{String,Any}()
    else
        Dict{String,Any}()
    end
end
profile = get(result, "profile", Dict{String,Any}())
profile isa AbstractDict || error("profile field is not a JSON object: $input_path")
profile_core = get(profile, "profile", Dict{String,Any}())
reports = get(profile_core, "reports", Dict{String,Any}())
numerical = get(reports, "numerical", Dict{String,Any}())
metadata = get(numerical, "metadata", Dict{String,Any}())

_string(key, default = nothing) = haskey(metadata, key) ? string(metadata[key]) : default
_int(key, default = nothing) = try parse(Int, _string(key, string(default))) catch; default end
_float(key, default = nothing) = try parse(Float64, _string(key, string(default))) catch; default end

sparse_rank = _int("sparse_qr_rank")
row_column_rank = _int("sparse_qr_row_column_rank")
scaled_rank = _int("scaled_sparse_qr_rank")
rank_delta = isnothing(sparse_rank) || isnothing(row_column_rank) ? nothing :
    row_column_rank - sparse_rank
comparison = Dict{String,Any}(
    "unscaled_rank" => sparse_rank,
    "row_column_rank" => row_column_rank,
    "row_column_minus_unscaled_rank" => rank_delta,
    "scaled_rank" => scaled_rank,
    "scaling_sensitive" => !isnothing(rank_delta) && rank_delta != 0,
    "unscaled_available" => _string("sparse_qr_rank_available", "false") == "true",
    "row_column_available" => _string("scaled_sparse_qr_rank_available", "false") == "true",
)

payload = Dict{String,Any}(
    "schema_version" => "nlpdiagnostics-bmopf-large-sparse-rank-screen-v1",
    "source" => Dict{String,Any}(
        "runner" => "benchmarks/bmopf_draft_corpus.jl",
        "summarizer" => "benchmarks/summarize_bmopf_large_sparse_rank_screen.jl",
        "input" => input_path,
        "point_policy" => get(result, "point_policy", nothing),
        "result_units" => get(manifest_metadata, "result_units", nothing),
        "result_field_units" => get(manifest_metadata, "result_field_units", nothing),
        "analysis_mode" => get(result, "analysis_mode", nothing),
        "dense_rank_max_entries" => get(result, "rank_max_dense_entries", nothing),
        "sparse_qr_max_input_nonzeros" => get(result, "sparse_qr_max_input_nonzeros", nothing),
        "sparse_qr_max_factor_nonzeros" => get(result, "sparse_qr_max_factor_nonzeros", nothing),
    ),
    "environment" => Dict{String,Any}(
        "git_revision" => git_revision(),
        "git_worktree_dirty" => !isempty(git_status_entries()),
        "source_environment_fingerprint" => get(result, "environment_fingerprint", nothing),
    ),
    "snapshot" => get(result, "snapshot", nothing),
    "status" => haskey(result, "profile") ? "ok" : "invalid",
    "model_variable_count" => get(result, "model_variable_count", nothing),
    "model_constraint_count" => get(result, "scalar_constraint_row_count", nothing),
    "evaluation" => Dict{String,Any}(
        "point_provenance_kind" => _string("evaluation_point_provenance_kind"),
        "point_provenance_complete" => _string("evaluation_point_provenance_complete") == "true",
        "point_label" => _string("evaluation_point_label"),
        "evaluated_row_count" => _int("evaluated_constraint_row_count"),
        "raw_jacobian_entry_count" => _int("raw_jacobian_entry_count"),
        "pattern_rank_upper_bound" => _int("sparse_jacobian_pattern_rank_upper_bound"),
    ),
    "sparse_qr" => Dict{String,Any}(
        "comparison" => comparison,
        "unscaled_input_nonzeros" => _int("sparse_qr_input_nonzeros"),
        "unscaled_factor_nonzeros" => _int("sparse_qr_factor_nonzeros"),
        "unscaled_fill_ratio" => _float("sparse_qr_fill_ratio"),
        "unscaled_condition_proxy" => _float("sparse_qr_condition_proxy"),
        "row_column_input_nonzeros" => _int("scaled_sparse_qr_input_nonzeros"),
        "row_column_factor_nonzeros" => _int("scaled_sparse_qr_factor_nonzeros"),
        "row_column_fill_ratio" => _float("scaled_sparse_qr_fill_ratio"),
        "row_column_condition_proxy" => _float("scaled_sparse_qr_condition_proxy"),
    ),
    "dense_rank" => Dict{String,Any}(
        "available" => _string("jacobian_rank_available", "false") == "true",
        "reason" => _string("jacobian_rank_reason"),
    ),
    "interpretation" => "This is sparse-QR evidence at a synthetic BMOPFTools coordinate probe. A rank change between unscaled and row-column sparse estimates localizes scaling sensitivity, but does not establish a physical gauge, a solver endpoint, or a default-policy recommendation.",
)
write_json(output_path, payload)
println("wrote large sparse rank screen summary to $output_path")
