#!/usr/bin/env julia

"""Audit saved-result solver status and numeric finiteness for the 538-bus corpus.

This is an input-quality gate, separate from sparse-rank evidence. A result can
exist and be mappable while still being unsuitable as a solver endpoint when
its termination status is not `LOCALLY_SOLVED`, its feasibility flag is false,
or its payload contains non-finite numeric values.

Usage:

    NLPDIAGNOSTICS_BMOPF_BENCHMARK_ROOT=/path/to/BMOPFDraftData/benchmarks \
        julia benchmarks/summarize_bmopf_saved_result_quality.jl output.json \
        [campaign-summary.json]
"""

using JSON

Base.include(@__MODULE__, joinpath(@__DIR__, "common.jl"))
using .NLPDiagnosticsBenchmarkCommon: git_revision, git_status_entries, write_json

length(ARGS) in (1, 2) || error(
    "usage: summarize_bmopf_saved_result_quality.jl output.json [campaign-summary.json]",
)
root = get(ENV, "NLPDIAGNOSTICS_BMOPF_BENCHMARK_ROOT", "")
isempty(root) && error("Set NLPDIAGNOSTICS_BMOPF_BENCHMARK_ROOT to BMOPFDraftData/benchmarks")
isdir(root) || error("benchmark root does not exist: $root")
output_path = abspath(first(ARGS))
campaign_path = length(ARGS) == 2 ? abspath(ARGS[2]) :
    joinpath(@__DIR__, "..", "docs", "bmopf_saved_result_sparse_rank_campaign_summary.json")
isfile(campaign_path) || error("campaign summary is missing: $campaign_path")

campaign = JSON.parsefile(campaign_path)
campaign isa AbstractDict || error("campaign summary is not an object: $campaign_path")
records = get(campaign, "records", Any[])
records isa AbstractVector || error("campaign summary records is not an array: $campaign_path")

snapshots = sort!(unique(String(get(record, "snapshot", "")) for record in records
                         if record isa AbstractDict &&
                            startswith(String(get(record, "snapshot", "")), "ENWLsnapshots/538bus_")))
isempty(snapshots) && error("campaign summary contains no 538-bus snapshots")
units = ("pu", "si")

function _walk_numbers(value, counts)
    if value isa Bool
        return
    elseif value isa Number
        if value isa AbstractFloat && !isfinite(value)
            counts["nonfinite_numeric_count"] += 1
        else
            counts["finite_numeric_count"] += 1
        end
    elseif value isa AbstractDict
        for item in values(value)
            _walk_numbers(item, counts)
        end
    elseif value isa AbstractVector
        for item in value
            _walk_numbers(item, counts)
        end
    end
end

function _result_path(snapshot, unit)
    replace(joinpath(root, snapshot), ".bmopf.json" => "_result_$(unit).json")
end

result_records = Dict{String,Any}[]
for snapshot in snapshots, unit in units
    path = _result_path(snapshot, unit)
    base = Dict{String,Any}(
        "snapshot" => snapshot,
        "result_units" => unit,
        "path" => abspath(path),
        "available" => isfile(path),
        "termination_status" => nothing,
        "feasible" => nothing,
        "finite_numeric_count" => 0,
        "nonfinite_numeric_count" => 0,
        "endpoint_quality" => "missing",
    )
    if isfile(path)
        result = JSON.parsefile(path; allownan = true)
        result isa AbstractDict || error("saved result is not an object: $path")
        base["termination_status"] = get(result, "termination_status", nothing)
        base["feasible"] = get(result, "feasible", nothing)
        counts = Dict("finite_numeric_count" => 0, "nonfinite_numeric_count" => 0)
        _walk_numbers(result, counts)
        merge!(base, counts)
        base["endpoint_quality"] =
            get(base, "termination_status", nothing) == "LOCALLY_SOLVED" &&
            get(base, "feasible", nothing) === true &&
            get(base, "nonfinite_numeric_count", 0) == 0 ? "usable_solver_endpoint" :
            "nonfinite_or_unsolved"
    end
    push!(result_records, base)
end

status_counts = Dict{String,Int}()
quality_counts = Dict{String,Int}()
for record in result_records
    status = string(get(record, "termination_status", "missing"))
    status_counts[status] = get(status_counts, status, 0) + 1
    quality = String(record["endpoint_quality"])
    quality_counts[quality] = get(quality_counts, quality, 0) + 1
end

payload = Dict{String,Any}(
    "schema_version" => "nlpdiagnostics-bmopf-saved-result-quality-v1",
    "source" => Dict{String,Any}(
        "runner" => "benchmarks/bmopf_draft_corpus.jl",
        "summarizer" => "benchmarks/summarize_bmopf_saved_result_quality.jl",
        "benchmark_root" => abspath(root),
        "campaign_summary" => campaign_path,
        "result_units" => collect(units),
    ),
    "environment" => Dict{String,Any}(
        "git_revision" => git_revision(),
        "git_worktree_dirty" => !isempty(git_status_entries()),
    ),
    "snapshot_count" => length(snapshots),
    "endpoint_count" => length(result_records),
    "available_endpoint_count" => count(get(record, "available", false) === true for record in result_records),
    "usable_solver_endpoint_count" => count(get(record, "endpoint_quality", "") == "usable_solver_endpoint" for record in result_records),
    "nonfinite_or_unsolved_endpoint_count" => count(get(record, "endpoint_quality", "") == "nonfinite_or_unsolved" for record in result_records),
    "missing_endpoint_count" => count(get(record, "endpoint_quality", "") == "missing" for record in result_records),
    "termination_status_counts" => Dict(key => status_counts[key] for key in sort!(collect(keys(status_counts)))),
    "endpoint_quality_counts" => Dict(key => quality_counts[key] for key in sort!(collect(keys(quality_counts)))),
    "records" => result_records,
    "interpretation" => "Saved-result availability, solver termination, feasibility, and numeric finiteness are input-quality evidence. A nonfinite or unsolved result must not be treated as a physical solver endpoint, even when a partial coordinate mapping and sparse-rank estimate can be produced.",
)
write_json(output_path, payload)
println("wrote BMOPF saved-result quality summary to $output_path")
