#!/usr/bin/env julia

"""Join runtime, memory, analyze, and BMOPFTools profile coverage."""

include(joinpath(@__DIR__, "common.jl"))
using .NLPDiagnosticsBenchmarkCommon

const ROOT = repo_root()
const SPARSE_INPUT = "docs/sparse_runtime_memory_scaling_summary.json"
const ISOLATED_INPUT = "docs/sparse_runtime_memory_isolated_summary.json"
const TREND_INPUT = "docs/sparse_runtime_trend_summary.json"
const ANALYZE_INPUT = "docs/analyze_runtime_scaling_summary.json"
const BMOPF_INPUT = "docs/bmopf_analyze_runtime_profile_summary.json"
const OUTPUT = abspath(isempty(ARGS) ?
    joinpath(ROOT, "docs", "runtime_scaling_readiness_summary.json") : ARGS[1])

sparse = read_summary(SPARSE_INPUT)
isolated = read_summary(ISOLATED_INPUT)
trend = read_summary(TREND_INPUT)
analyze = read_summary(ANALYZE_INPUT)
bmopf = read_summary(BMOPF_INPUT)

sparse_records = get(sparse, "records", Any[])
isolated_records = get(isolated, "records", Any[])
trend_workloads = get(trend, "workloads", Any[])
analyze_records = get(analyze, "records", Any[])
bmopf_records = get(bmopf, "records", Any[])

coverage = Dict{String,Any}[
    Dict(
        "id" => "synthetic_sparse_end_to_end",
        "record_count" => length(sparse_records),
        "dimensions" => get(get(sparse, "source", Dict{String,Any}()), "dimensions", Any[]),
        "isolated_process" => false,
        "memory_observation" => "process high-water mark is descriptive and cumulative",
        "claim_level" => "bounded synthetic scaling only",
    ),
    Dict(
        "id" => "isolated_sparse_end_to_end",
        "record_count" => length(isolated_records),
        "dimensions" => get(get(isolated, "source", Dict{String,Any}()), "dimensions", Any[]),
        "isolated_process" => true,
        "memory_observation" => "per-dimension child-process high-water mark; not allocator-level peak",
        "claim_level" => "bounded synthetic scaling with isolated process attribution",
    ),
    Dict(
        "id" => "public_analyze_workloads",
        "record_count" => length(analyze_records),
        "workload_count" => length(trend_workloads),
        "dimensions" => unique(Int[record["dimension"] for record in analyze_records]),
        "isolated_process" => false,
        "memory_observation" => "allocation and process telemetry are descriptive",
        "claim_level" => "bounded public-API fixture scaling only",
    ),
    Dict(
        "id" => "bmopf_adapter_profile",
        "record_count" => length(bmopf_records),
        "measured_count" => count(record -> get(record, "status", "") == "measured", bmopf_records),
        "guarded_count" => count(record -> get(record, "status", "") == "skipped_size_guard", bmopf_records),
        "isolated_process" => false,
        "memory_observation" => "descriptive process high-water mark with explicit size guard",
        "claim_level" => "small-fixture adapter coverage only",
    ),
]

open_gaps = [
    Dict("id" => "opf_solver_scaling", "next_evidence" => "guarded solver-workload ladder with explicit iteration and termination provenance"),
    Dict("id" => "allocator_peak_memory", "next_evidence" => "allocator-level peak measurement independent of cumulative Sys.maxrss"),
    Dict("id" => "portable_reproducibility", "next_evidence" => "reviewed cross-environment repeatability campaign"),
]

write_json(OUTPUT, Dict{String,Any}(
    "schema_version" => "nlpdiagnostics-runtime-scaling-readiness-v1",
    "source" => Dict(
        "runner" => "benchmarks/summarize_runtime_scaling_readiness.jl",
        "artifacts" => [SPARSE_INPUT, ISOLATED_INPUT, TREND_INPUT, ANALYZE_INPUT, BMOPF_INPUT],
        "policy" => "Coverage rows preserve the distinction between synthetic, public-API, adapter, isolated-process, and open solver-memory evidence.",
    ),
    "environment" => Dict(
        "julia_version" => string(VERSION),
        "active_project" => Base.active_project(),
        "git_revision" => git_revision(),
        "git_worktree_dirty" => !isempty(git_status_entries()),
    ),
    "coverage_count" => length(coverage),
    "coverage" => coverage,
    "open_gap_count" => length(open_gaps),
    "open_gaps" => open_gaps,
    "interpretation" => Dict(
        "claim" => "Current runtime evidence is organized into four bounded coverage rows with three explicit gaps for release-grade scaling claims.",
        "does_not_establish" => [
            "OPF-solver complexity or scalability",
            "allocator-level peak memory",
            "cross-machine performance reproducibility",
        ],
    ),
))
println("wrote runtime scaling readiness summary to $OUTPUT")
