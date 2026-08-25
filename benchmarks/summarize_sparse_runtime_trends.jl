#!/usr/bin/env julia

"""Summarize growth trends in the isolated synthetic sparse profiling ladder.

This joins saved child-process records and reports descriptive adjacent ratios,
log-log slopes, allocation trends, and largest-stage attribution. It is not a
solver-scaling or portable-complexity claim.
"""

include(joinpath(@__DIR__, "common.jl"))
using .NLPDiagnosticsBenchmarkCommon

const ROOT = repo_root()
const INPUT_ARTIFACT = "docs/sparse_runtime_memory_isolated_summary.json"
const OUTPUT = abspath(isempty(ARGS) ?
    joinpath(ROOT, "docs", "sparse_runtime_trend_summary.json") : ARGS[1])

summary = read_summary(INPUT_ARTIFACT)
records = get(summary, "records", Any[])

function slope(x1, y1, x2, y2)
    x1 > 0 && x2 > 0 && y1 > 0 && y2 > 0 || return nothing
    log(y2 / y1) / log(x2 / x1)
end

function trend(points, value_key)
    ordered = sort!(Dict{String,Any}[Dict{String,Any}(point) for point in points]; by = point -> point["dimension"])
    ratios = Dict{String,Any}[]
    slopes = Float64[]
    for index in 2:length(ordered)
        previous = ordered[index - 1]
        current = ordered[index]
        previous_value = get(previous, value_key, nothing)
        current_value = get(current, value_key, nothing)
        ratio = previous_value isa Real && current_value isa Real && previous_value > 0 ?
            current_value / previous_value : nothing
        interval_slope = previous_value isa Real && current_value isa Real ?
            slope(Float64(previous["dimension"]), Float64(previous_value), Float64(current["dimension"]), Float64(current_value)) : nothing
        ratio === nothing || push!(ratios, Dict{String,Any}(
            "from_dimension" => previous["dimension"],
            "to_dimension" => current["dimension"],
            "ratio" => ratio,
        ))
        interval_slope === nothing || push!(slopes, interval_slope)
    end
    Dict{String,Any}(
        "value_key" => value_key,
        "point_count" => length(ordered),
        "adjacent_ratios" => ratios,
        "log_log_slopes" => slopes,
        "log_log_slope_minimum" => isempty(slopes) ? nothing : minimum(slopes),
        "log_log_slope_maximum" => isempty(slopes) ? nothing : maximum(slopes),
    )
end

function stage_dominant(record)
    stages = get(record, "stage_timing", Dict{String,Any}())
    isempty(stages) && return nothing
    dominant = reduce((left, right) -> left[2] >= right[2] ? left : right,
        [(name, get(data, "mean_seconds", 0.0)) for (name, data) in pairs(stages)])
    Dict{String,Any}("stage" => dominant[1], "mean_seconds" => dominant[2])
end

function stage_repeatability(record, collection_key, mean_key, standard_deviation_key)
    summaries = get(record, collection_key, Dict{String,Any}())
    coefficients = Dict{String,Any}()
    for stage in sort!(collect(keys(summaries)); by = string)
        summary = summaries[stage]
        mean = get(summary, mean_key, nothing)
        standard_deviation = get(summary, standard_deviation_key, nothing)
        mean isa Real && standard_deviation isa Real && mean > 0 || continue
        coefficients[string(stage)] = Dict{String,Any}(
            "mean" => mean,
            "standard_deviation" => standard_deviation,
            "coefficient_of_variation" => standard_deviation / mean,
            "sample_count" => get(summary, "sample_count", nothing),
        )
    end
    coefficient_values = Float64[
        Float64(item["coefficient_of_variation"])
        for item in values(coefficients)
    ]
    Dict{String,Any}(
        "stage_count" => length(coefficients),
        "maximum_coefficient_of_variation" => isempty(coefficient_values) ? nothing : maximum(coefficient_values),
        "mean_coefficient_of_variation" => isempty(coefficient_values) ? nothing : sum(coefficient_values) / length(coefficient_values),
        "stages" => coefficients,
    )
end

workloads = Dict{String,Any}[]
for case_name in sort!(unique(String[get(record, "case", "unknown") for record in records]))
    case_records = filter(record -> get(record, "case", "unknown") == case_name, records)
    ordered = sort!(Dict{String,Any}[Dict{String,Any}(record) for record in case_records]; by = record -> record["dimension"])
    push!(workloads, Dict{String,Any}(
        "case" => case_name,
        "point_count" => length(ordered),
        "dimensions" => [record["dimension"] for record in ordered],
        "runtime" => trend(ordered, "total_stage_mean_seconds"),
        "allocation" => trend(ordered, "total_stage_mean_allocated_bytes"),
        "process_maxrss_increment" => trend(ordered, "process_maxrss_increment_bytes"),
        "dominant_stage_at_largest_dimension" => stage_dominant(ordered[end]),
        "timing_repeatability_at_largest_dimension" => stage_repeatability(
            ordered[end], "stage_timing", "mean_seconds", "standard_deviation_seconds",
        ),
        "allocation_repeatability_at_largest_dimension" => stage_repeatability(
            ordered[end], "stage_allocations", "mean_bytes", "standard_deviation_bytes",
        ),
        "repetitions_complete" => all(get(record, "repetitions", 0) == get(get(summary, "source", Dict{String,Any}()), "repetitions", -1) for record in ordered),
    ))
end

write_json(OUTPUT, Dict{String,Any}(
    "schema_version" => "nlpdiagnostics-sparse-runtime-trend-v1",
    "source" => Dict(
        "runner" => "benchmarks/summarize_sparse_runtime_trends.jl",
        "input_artifact" => INPUT_ARTIFACT,
        "dimensions" => get(get(summary, "source", Dict{String,Any}()), "dimensions", Any[]),
        "repetitions" => get(get(summary, "source", Dict{String,Any}()), "repetitions", nothing),
    ),
    "environment" => Dict(
        "julia_version" => string(VERSION),
        "active_project" => Base.active_project(),
        "git_revision" => git_revision(),
        "git_worktree_dirty" => !isempty(git_status_entries()),
    ),
    "workload_count" => length(workloads),
    "workloads" => workloads,
    "interpretation" => Dict(
        "claim" => "Descriptive growth and stage-attribution trends for the saved isolated synthetic sparse profiling ladder.",
        "does_not_establish" => [
            "OPF solver runtime or memory scaling",
            "allocator-level peak memory",
            "a portable asymptotic complexity law or production threshold",
        ],
        "repeatability_note" => "Per-stage coefficients of variation at the largest dimension summarize within-dimension repetition only; they do not quantify cross-machine or solver repeatability.",
    ),
))
println("wrote sparse runtime trend summary to $OUTPUT")
