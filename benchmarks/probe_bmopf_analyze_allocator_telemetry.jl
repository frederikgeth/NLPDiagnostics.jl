#!/usr/bin/env julia

"""Probe Darwin allocator counters around one point-free analyze workload."""

using JSON
using NLPDiagnostics
using BMOPFTools
using JuMP
using Ipopt

include(joinpath(@__DIR__, "common.jl"))
using .NLPDiagnosticsBenchmarkCommon

const ROOT = repo_root()
const DEFAULT_FIXTURE_ROOT = normpath(joinpath(
    dirname(pathof(BMOPFTools)), "..", "test", "data", "pf_comparison",
))
const CASE = strip(get(ENV, "NLPDIAGNOSTICS_BMOPF_ANALYZE_ALLOCATOR_CASE", "pf_1ph_line.dss"))
const FIXTURE_ROOT = abspath(get(
    ENV, "NLPDIAGNOSTICS_BMOPF_ANALYZE_ALLOCATOR_FIXTURE_ROOT", DEFAULT_FIXTURE_ROOT,
))
const OUTPUT = abspath(isempty(ARGS) ? get(
    ENV, "NLPDIAGNOSTICS_BMOPF_ANALYZE_ALLOCATOR_OUTPUT",
    joinpath(ROOT, "docs", "bmopf_analyze_allocator_telemetry_summary.json"),
) : ARGS[1])

struct MallocStatistics
    blocks_in_use::Csize_t
    size_in_use::Csize_t
    max_size_in_use::Csize_t
    size_allocated::Csize_t
end

function allocator_snapshot()
    Sys.isapple() || return Dict{String,Any}(
        "available" => false, "reason" => "darwin_only",
    )
    try
        zone = ccall(:malloc_default_zone, Ptr{Cvoid}, ())
        stats = Ref(MallocStatistics(0, 0, 0, 0))
        ccall(:malloc_zone_statistics, Cvoid,
            (Ptr{Cvoid}, Ref{MallocStatistics}), zone, stats)
        value = stats[]
        return Dict{String,Any}(
            "available" => true,
            "blocks_in_use" => Int(value.blocks_in_use),
            "size_in_use_bytes" => Int(value.size_in_use),
            "max_size_in_use_bytes" => Int(value.max_size_in_use),
            "size_allocated_bytes" => Int(value.size_allocated),
            "peak_field_available" => value.max_size_in_use > 0,
        )
    catch error
        return Dict{String,Any}(
            "available" => false,
            "error_type" => string(typeof(error)),
            "error" => sprint(showerror, error),
        )
    end
end

function allocator_delta(before, after)
    before isa AbstractDict && after isa AbstractDict || return Dict{String,Any}()
    get(before, "available", false) && get(after, "available", false) || return Dict{String,Any}()
    Dict{String,Any}(
        "size_in_use_delta_bytes" => after["size_in_use_bytes"] - before["size_in_use_bytes"],
        "size_allocated_delta_bytes" => after["size_allocated_bytes"] - before["size_allocated_bytes"],
        "peak_field_available" => get(after, "peak_field_available", false),
    )
end

function timed_stage(label, action)
    before = allocator_snapshot()
    timing = @timed action()
    after = allocator_snapshot()
    return timing.value, Dict{String,Any}(
        "stage" => label,
        "seconds" => timing.time,
        "allocated_bytes" => timing.bytes,
        "allocator_before" => before,
        "allocator_after" => after,
        "allocator_delta" => allocator_delta(before, after),
    )
end

path = joinpath(FIXTURE_ROOT, CASE)
isfile(path) || error("fixture missing: $path")
started = time()
network, parse_stage = timed_stage("parse", () -> BMOPFTools.from_dss(path))
context, build_stage = timed_stage("build", () -> BMOPFTools.build_opf_model(
    deepcopy(network); optimizer=Ipopt.Optimizer, add_objective=true,
))
_, kcl_stage = timed_stage("kcl", () -> BMOPFTools.enforce_kcl!(context))
model = BMOPFTools.opf_model(context)
warmup = NLPDiagnostics.analyze(model)
GC.gc()
rss_before = Int(Sys.maxrss())
report, analyze_stage = timed_stage("analyze", () -> NLPDiagnostics.analyze(model))
rss_after = Int(Sys.maxrss())
all_stages = [parse_stage, build_stage, kcl_stage, analyze_stage]
available_stages = filter(stage -> get(get(stage, "allocator_delta", Dict{String,Any}()), "peak_field_available", false), all_stages)
allocator_available = all(
    get(get(stage, "allocator_before", Dict{String,Any}()), "available", false) &&
    get(get(stage, "allocator_after", Dict{String,Any}()), "available", false)
    for stage in all_stages
)
status = allocator_available ? "allocator_current_available" : "allocator_telemetry_unavailable"
write_json(OUTPUT, Dict{String,Any}(
    "schema_version" => "nlpdiagnostics-bmopf-analyze-allocator-telemetry-v1",
    "status" => status,
    "source" => Dict(
        "runner" => "benchmarks/probe_bmopf_analyze_allocator_telemetry.jl",
        "case" => CASE,
        "fixture_root" => FIXTURE_ROOT,
        "entry_point" => "NLPDiagnostics.analyze(model)",
        "stage_labels" => ["parse", "build", "kcl", "analyze"],
    ),
    "environment" => Dict(
        "julia_version" => string(VERSION),
        "active_project" => Base.active_project(),
        "os" => string(Sys.KERNEL),
        "architecture" => string(Sys.ARCH),
        "git_revision" => git_revision(),
        "git_worktree_dirty" => !isempty(git_status_entries()),
        "bmopftools_version" => string(Base.pkgversion(BMOPFTools)),
    ),
    "variable_count" => length(NLPDiagnostics.snapshot(model).variables),
    "constraint_count" => length(NLPDiagnostics.snapshot(model).constraints),
    "finding_count" => length(report),
    "process_maxrss_before_bytes" => rss_before,
    "process_maxrss_after_bytes" => rss_after,
    "process_maxrss_increment_bytes" => max(0, rss_after - rss_before),
    "stage_count" => length(all_stages),
    "allocator_current_available" => allocator_available,
    "allocator_peak_available_count" => length(available_stages),
    "stages" => all_stages,
    "wall_seconds" => time() - started,
    "interpretation" => Dict(
        "claim" => "Darwin malloc_zone_statistics current-allocation and peak-field capability around one point-free analyze workload.",
        "does_not_establish" => [
            "allocator-level peak when max_size_in_use is zero",
            "portable or retained-memory behavior",
            "multi-case or solver scaling",
        ],
        "boundary" => "Current allocator deltas are stage attribution; the max_size_in_use field is reported independently and is not inferred from current bytes.",
    ),
))
println("wrote BMOPFTools analyze allocator telemetry to $OUTPUT")
