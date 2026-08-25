#!/usr/bin/env julia

"""Summarize observed repeated `analyze(model)` scaling trends.

The output is descriptive attribution over the bounded fixture campaign. It
does not fit or promote a portable complexity law.
"""

include(joinpath(@__DIR__, "common.jl"))
using .NLPDiagnosticsBenchmarkCommon

const ROOT = repo_root()
const INPUT = "docs/analyze_runtime_scaling_summary.json"
const OUTPUT = abspath(isempty(ARGS) ?
    joinpath(ROOT, "docs", "analyze_runtime_trend_summary.json") : ARGS[1])

function trend(records)
    ordered = sort(records; by = record -> record["dimension"])
    ratios = Dict{String,Any}[]
    for (previous, current) in zip(ordered[1:end-1], ordered[2:end])
        dimension_ratio = current["dimension"] / previous["dimension"]
        elapsed_ratio = current["elapsed_seconds"] / previous["elapsed_seconds"]
        push!(ratios, Dict{String,Any}(
            "from_dimension" => previous["dimension"],
            "to_dimension" => current["dimension"],
            "dimension_ratio" => dimension_ratio,
            "elapsed_ratio" => elapsed_ratio,
            "log_log_slope" => log(elapsed_ratio) / log(dimension_ratio),
        ))
    end
    dominant_stages = [
        begin
            stage = argmax(item -> item["elapsed_seconds"], record["stage_attribution"])
            Dict("dimension" => record["dimension"], "stage" => stage["stage"],
                "elapsed_seconds" => stage["elapsed_seconds"])
        end for record in ordered
    ]
    slopes = [ratio["log_log_slope"] for ratio in ratios]
    return Dict{String,Any}(
        "point_count" => length(ordered),
        "dimensions" => [record["dimension"] for record in ordered],
        "elapsed_seconds" => [record["elapsed_seconds"] for record in ordered],
        "evidence_stable" => all(
            get(record, "evidence_stable_across_repetitions", false)
            for record in ordered
        ),
        "adjacent_ratios" => ratios,
        "log_log_slope_minimum" => isempty(slopes) ? nothing : minimum(slopes),
        "log_log_slope_maximum" => isempty(slopes) ? nothing : maximum(slopes),
        "dominant_stages" => dominant_stages,
        "dominant_stage_at_largest_dimension" => isempty(dominant_stages) ?
            nothing : dominant_stages[end]["stage"],
    )
end

summary = read_summary(INPUT)
affine_records = get(summary, "records", Any[])
nonlinear_records = get(
    get(summary, "workload_comparisons", Dict{String,Any}()),
    "sparse_nonlinear_chain",
    Any[],
)
affine_trend = trend(affine_records)
nonlinear_trend = isempty(nonlinear_records) ? Dict{String,Any}(
    "point_count" => 0,
    "dimensions" => Any[],
    "adjacent_ratios" => Any[],
    "evidence_stable" => false,
) : trend(nonlinear_records)

write_json(OUTPUT, Dict{String,Any}(
    "schema_version" => "nlpdiagnostics-analyze-runtime-trend-v1",
    "source" => Dict(
        "runner" => "benchmarks/summarize_analyze_runtime_trends.jl",
        "input" => INPUT,
        "claim_boundary" => "descriptive bounded-fixture trend attribution",
    ),
    "environment" => Dict(
        "julia_version" => string(VERSION),
        "active_project" => Base.active_project(),
        "git_revision" => git_revision(),
        "git_worktree_dirty" => !isempty(git_status_entries()),
    ),
    "affine_chain" => affine_trend,
    "nonlinear_chain" => nonlinear_trend,
    "interpretation" => Dict(
        "claim" => "Repeated bounded analyze(model) measurements are summarized by adjacent growth ratios, descriptive log-log slopes, and dominant stages.",
        "does_not_establish" => [
            "a portable asymptotic complexity law",
            "solver runtime or memory scaling",
            "fixture-independent production thresholds",
        ],
    ),
))
println("wrote analyze runtime trend summary to $OUTPUT")
