#!/usr/bin/env julia

"""Summarize saved `analyze(model)` runtime and resource trends.

The ledger adds allocation and process high-water trend attribution to the
existing repeated affine and nonlinear campaigns. It does not promote a
portable complexity or memory law.
"""

include(joinpath(@__DIR__, "common.jl"))
using .NLPDiagnosticsBenchmarkCommon

const ROOT = repo_root()
const INPUT = "docs/analyze_runtime_scaling_summary.json"
const OUTPUT = abspath(isempty(ARGS) ?
    joinpath(ROOT, "docs", "analyze_runtime_resource_summary.json") : ARGS[1])

summary = read_summary(INPUT)

function log_slope(previous, current, key)
    x1 = Float64(previous["dimension"])
    x2 = Float64(current["dimension"])
    y1 = get(previous, key, nothing)
    y2 = get(current, key, nothing)
    y1 isa Real && y2 isa Real && y1 > 0 && y2 > 0 || return nothing
    log(Float64(y2) / Float64(y1)) / log(x2 / x1)
end

function trend(records, key)
    ordered = sort!(Dict{String,Any}[Dict{String,Any}(record) for record in records]; by = record -> record["dimension"])
    slopes = Float64[]
    ratios = Dict{String,Any}[]
    for (previous, current) in zip(ordered[1:end-1], ordered[2:end])
        previous_value = get(previous, key, nothing)
        current_value = get(current, key, nothing)
        ratio = previous_value isa Real && current_value isa Real && previous_value > 0 ?
            Float64(current_value) / Float64(previous_value) : nothing
        interval_slope = log_slope(previous, current, key)
        ratio === nothing || push!(ratios, Dict{String,Any}(
            "from_dimension" => previous["dimension"],
            "to_dimension" => current["dimension"],
            "ratio" => ratio,
        ))
        interval_slope === nothing || push!(slopes, interval_slope)
    end
    Dict{String,Any}(
        "value_key" => key,
        "point_count" => length(ordered),
        "dimensions" => [record["dimension"] for record in ordered],
        "adjacent_ratios" => ratios,
        "log_log_slopes" => slopes,
        "log_log_slope_minimum" => isempty(slopes) ? nothing : minimum(slopes),
        "log_log_slope_maximum" => isempty(slopes) ? nothing : maximum(slopes),
    )
end

function dominant_stage(record, key)
    stages = get(record, "stage_attribution", Any[])
    isempty(stages) && return nothing
    dominant = reduce((left, right) -> get(left, key, 0.0) >= get(right, key, 0.0) ? left : right, stages)
    Dict{String,Any}("stage" => dominant["stage"], "value" => get(dominant, key, nothing))
end

function repeatability(values)
    numeric = Float64[Float64(value) for value in values if value isa Real]
    isempty(numeric) && return Dict{String,Any}(
        "sample_count" => 0,
        "mean" => nothing,
        "standard_deviation" => nothing,
        "coefficient_of_variation" => nothing,
    )
    mean_value = sum(numeric) / length(numeric)
    variance = length(numeric) < 2 ? 0.0 :
        sum((value - mean_value)^2 for value in numeric) / (length(numeric) - 1)
    standard_deviation = sqrt(variance)
    Dict{String,Any}(
        "sample_count" => length(numeric),
        "mean" => mean_value,
        "standard_deviation" => standard_deviation,
        "coefficient_of_variation" => mean_value > 0 ? standard_deviation / mean_value : nothing,
    )
end

function stage_repeatability(record, key)
    runs = get(record, "runs", Any[])
    stage_names = sort!(unique(String[
        stage["stage"] for run in runs
        for stage in get(run, "stage_attribution", Any[])
    ]))
    stages = Dict{String,Any}()
    for name in stage_names
        values = Float64[
            Float64(stage[key])
            for run in runs
            for stage in get(run, "stage_attribution", Any[])
            if stage["stage"] == name && stage[key] isa Real
        ]
        stages[name] = repeatability(values)
    end
    coefficients = Float64[
        Float64(item["coefficient_of_variation"])
        for item in values(stages)
        if item["coefficient_of_variation"] isa Real
    ]
    Dict{String,Any}(
        "stage_count" => length(stages),
        "maximum_coefficient_of_variation" => isempty(coefficients) ? nothing : maximum(coefficients),
        "mean_coefficient_of_variation" => isempty(coefficients) ? nothing : sum(coefficients) / length(coefficients),
        "stages" => stages,
    )
end

affine = get(summary, "records", Any[])
nonlinear = get(get(summary, "workload_comparisons", Dict{String,Any}()), "sparse_nonlinear_chain", Any[])
workloads = Dict{String,Any}[]
for (name, records) in [("sparse_affine_chain", affine), ("sparse_nonlinear_chain", nonlinear)]
    isempty(records) && continue
    ordered = sort!(Dict{String,Any}[Dict{String,Any}(record) for record in records]; by = record -> record["dimension"])
    push!(workloads, Dict{String,Any}(
        "workload" => name,
        "point_count" => length(ordered),
        "evidence_stable" => all(get(record, "evidence_stable_across_repetitions", false) for record in ordered),
        "runtime" => trend(ordered, "elapsed_seconds"),
        "allocation" => trend(ordered, "allocated_bytes"),
        "process_maxrss_increment" => trend(ordered, "process_maxrss_increment_bytes"),
        "dominant_elapsed_stage_at_largest_dimension" => dominant_stage(ordered[end], "elapsed_seconds"),
        "dominant_allocation_stage_at_largest_dimension" => dominant_stage(ordered[end], "allocated_bytes"),
        "runtime_repeatability_at_largest_dimension" => repeatability([
            run["elapsed_seconds"] for run in get(ordered[end], "runs", Any[])
        ]),
        "allocation_repeatability_at_largest_dimension" => repeatability([
            run["allocated_bytes"] for run in get(ordered[end], "runs", Any[])
        ]),
        "stage_timing_repeatability_at_largest_dimension" => stage_repeatability(
            ordered[end], "elapsed_seconds",
        ),
        "stage_allocation_repeatability_at_largest_dimension" => stage_repeatability(
            ordered[end], "allocated_bytes",
        ),
    ))
end

write_json(OUTPUT, Dict{String,Any}(
    "schema_version" => "nlpdiagnostics-analyze-runtime-resource-v1",
    "source" => Dict(
        "runner" => "benchmarks/summarize_analyze_runtime_resources.jl",
        "input" => INPUT,
        "claim_boundary" => "descriptive bounded-fixture runtime and resource trends",
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
        "claim" => "Saved repeated analyze(model) campaigns are summarized by runtime, allocation, process high-water, and stage-attribution trends.",
        "does_not_establish" => [
            "a portable asymptotic complexity or memory law",
            "solver runtime or allocator-level peak memory",
            "fixture-independent production thresholds",
        ],
        "repeatability_note" => "Per-run and per-stage coefficients of variation at the largest dimension summarize repeated local measurements only; they do not quantify cross-machine, solver, or allocator repeatability.",
    ),
))
println("wrote analyze runtime resource summary to $OUTPUT")
