#!/usr/bin/env julia

"""
Run the solver-independent sparse profiling ladder and write a compact
runtime/allocation/high-watermark report.

The report intentionally measures the package's repeated profiling stages, not
an OPF solver. `Sys.maxrss()` is a process high-water mark, so the per-size
field is an incremental observation within this process rather than an
isolated peak-memory certificate.

Usage:

    julia --project=work/benchmark-environment \
        benchmarks/profile_sparse_runtime_memory_scaling.jl \
        docs/sparse_runtime_memory_scaling_summary.json

Environment overrides:

    NLPDIAGNOSTICS_PROFILE_DIMENSIONS=16,32,64,128
    NLPDIAGNOSTICS_PROFILE_REPETITIONS=3
"""

using JSON
using NLPDiagnostics

include(joinpath(@__DIR__, "common.jl"))
using .NLPDiagnosticsBenchmarkCommon

const REPO_ROOT = repo_root()
const OUTPUT = abspath(isempty(ARGS) ?
    joinpath(REPO_ROOT, "docs", "sparse_runtime_memory_scaling_summary.json") :
    ARGS[1])

function parse_positive_list(raw::AbstractString, label::AbstractString)
    values = try
        parse.(Int, split(raw, ','))
    catch
        error("$label must be a comma-separated list of integers")
    end
    isempty(values) && error("$label must not be empty")
    all(>(0), values) || error("$label must contain only positive integers")
    length(unique(values)) == length(values) ||
        error("$label must not contain duplicates")
    return values
end

dimensions = parse_positive_list(
    get(ENV, "NLPDIAGNOSTICS_PROFILE_DIMENSIONS", "16,32,64,128"),
    "NLPDIAGNOSTICS_PROFILE_DIMENSIONS",
)
all(dimension -> dimension >= 2, dimensions) ||
    error("NLPDIAGNOSTICS_PROFILE_DIMENSIONS must be at least 2")
repetitions = parse(Int, get(ENV, "NLPDIAGNOSTICS_PROFILE_REPETITIONS", "3"))
repetitions > 0 || error("NLPDIAGNOSTICS_PROFILE_REPETITIONS must be positive")

function stage_data(aggregate::NLPDiagnostics.ProfileAggregate)
    timing = Dict(
        string(stage) => Dict(
            "sample_count" => summary.sample_count,
            "minimum_seconds" => summary.minimum,
            "mean_seconds" => summary.mean,
            "maximum_seconds" => summary.maximum,
            "standard_deviation_seconds" => summary.standard_deviation,
        ) for (stage, summary) in aggregate.stage_timing
    )
    allocations = Dict(
        string(stage) => Dict(
            "sample_count" => summary.sample_count,
            "minimum_bytes" => summary.minimum,
            "mean_bytes" => summary.mean,
            "maximum_bytes" => summary.maximum,
            "standard_deviation_bytes" => summary.standard_deviation,
        ) for (stage, summary) in aggregate.stage_allocations
    )
    return timing, allocations
end

function compact_record(
    dimension::Int,
    case_name::String,
    aggregate::NLPDiagnostics.ProfileAggregate,
    rss_before::Int,
    rss_after::Int,
)
    timing, allocations = stage_data(aggregate)
    total_seconds = sum(item["mean_seconds"] for item in values(timing))
    total_allocations = sum(item["mean_bytes"] for item in values(allocations))
    expected = Dict(
        string(item.code) => Dict(
            "occurrence_count" => item.occurrence_count,
            "run_count" => item.run_count,
            "fraction" => item.fraction,
        ) for item in aggregate.expected_evidence
    )
    return Dict{String,Any}(
        "dimension" => dimension,
        "case" => case_name,
        "variable_count" => dimension,
        "constraint_count" => dimension,
        "repetitions" => length(aggregate.runs),
        "warmup_performed" => aggregate.warmup_performed,
        "total_stage_mean_seconds" => total_seconds,
        "total_stage_mean_allocated_bytes" => total_allocations,
        "stage_timing" => timing,
        "stage_allocations" => allocations,
        "expected_evidence" => expected,
        "process_maxrss_before_bytes" => rss_before,
        "process_maxrss_after_bytes" => rss_after,
        "process_maxrss_increment_bytes" => max(0, rss_after - rss_before),
        "memory_observation" =>
            "Sys.maxrss process high-water mark; increment is not an isolated per-case peak",
    )
end

status_entries = git_status_entries()
records = Dict{String,Any}[]
for dimension in dimensions
    GC.gc()
    rss_before = Int(Sys.maxrss())
    models, cases = NLPDiagnostics.synthetic_sparse_profile_corpus(dimension = dimension)
    aggregates = NLPDiagnostics.profile_cases_repeated(
        models,
        cases;
        repetitions = repetitions,
        warmup = true,
        rank_max_dense_entries = 0,
    )
    rss_after = Int(Sys.maxrss())
    for case in cases
        push!(records, compact_record(
            dimension,
            case.name,
            aggregates[case.name],
            rss_before,
            rss_after,
        ))
    end
end

summary = Dict{String,Any}(
    "schema_version" => "nlpdiagnostics-sparse-runtime-memory-scaling-v1",
    "source" => Dict(
        "runner" => "benchmarks/profile_sparse_runtime_memory_scaling.jl",
        "dimensions" => dimensions,
        "repetitions" => repetitions,
        "warmup" => true,
        "rank_max_dense_entries" => 0,
        "profile_corpus" => "NLPDiagnostics.synthetic_sparse_profile_corpus",
    ),
    "environment" => Dict(
        "julia_version" => string(VERSION),
        "active_project" => Base.active_project(),
        "os" => string(Sys.KERNEL),
        "architecture" => string(Sys.ARCH),
        "git_revision" => git_revision(),
        "git_worktree_dirty" => !isempty(status_entries),
        "git_status_entry_count" => length(status_entries),
    ),
    "records" => records,
    "interpretation" => Dict(
        "claim" =>
            "Local warm-up-aware runtime and allocation observations for the synthetic sparse profiling corpus.",
        "does_not_establish" => [
            "OPF solver runtime or solver memory scaling",
            "a portable complexity law or production threshold",
            "isolated per-case peak memory from process high-water marks",
        ],
        "memory_note" =>
            "Sys.maxrss is retained as a process high-water mark; incremental values are descriptive only.",
    ),
)

mkpath(dirname(OUTPUT))
open(OUTPUT, "w") do io
    JSON.print(io, summary, 2)
    write(io, '\n')
end
println("wrote sparse runtime/memory scaling summary to $OUTPUT")
