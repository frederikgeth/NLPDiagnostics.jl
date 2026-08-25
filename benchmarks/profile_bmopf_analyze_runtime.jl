#!/usr/bin/env julia

"""Profile point-free `NLPDiagnostics.analyze(model)` on small BMOPFTools cases.

This is deliberately bounded. It profiles only selected OpenDSS fixtures that
fit the configured variable guard; larger adapter models are retained as an
explicit size-guard result rather than being forced through a high-allocation
point-free analysis.
"""

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
const OUTPUT = abspath(isempty(ARGS) ? get(
    ENV,
    "NLPDIAGNOSTICS_BMOPF_ANALYZE_PROFILE_OUTPUT",
    joinpath(ROOT, "docs", "bmopf_analyze_runtime_profile_summary.json"),
) : ARGS[1])

function selected_cases()
    raw = strip(get(
        ENV,
        "NLPDIAGNOSTICS_BMOPF_ANALYZE_PROFILE_CASES",
        "pf_1ph_line.dss,pf_exp_1ph.dss,pf_1ph_xfmr.dss",
    ))
    cases = filter(!isempty, strip.(split(raw, ',')))
    isempty(cases) && error("NLPDIAGNOSTICS_BMOPF_ANALYZE_PROFILE_CASES must not be empty")
    return unique(cases)
end

function positive_integer(name::AbstractString, default::Int)
    value = try
        parse(Int, get(ENV, name, string(default)))
    catch
        error("$name must be a positive integer")
    end
    value > 0 || error("$name must be a positive integer")
    return value
end

function warning_count(network)
    metadata = get(network, "_meta", Dict{String,Any}())
    warnings = get(metadata, "powerio_warnings", Any[])
    return warnings isa AbstractVector ? length(warnings) : 0
end

function profile_case(root::AbstractString, filename::AbstractString, max_variables::Int)
    path = joinpath(root, filename)
    isfile(path) || return Dict{String,Any}(
        "case" => filename,
        "status" => "unavailable",
        "reason" => "fixture_missing",
    )
    started = time()
    try
        parse_timing = @timed BMOPFTools.from_dss(path)
        network = parse_timing.value
        build_timing = @timed BMOPFTools.build_opf_model(
            deepcopy(network);
            optimizer = Ipopt.Optimizer,
            add_objective = true,
        )
        context = build_timing.value
        kcl_timing = @timed BMOPFTools.enforce_kcl!(context)
        model = BMOPFTools.opf_model(context)
        snapshot = NLPDiagnostics.snapshot(model)
        variable_count = length(snapshot.variables)
        constraint_count = length(snapshot.constraints)
        base = Dict{String,Any}(
            "case" => filename,
            "status" => variable_count <= max_variables ? "measured" : "skipped_size_guard",
            "variable_count" => variable_count,
            "constraint_count" => constraint_count,
            "max_variables" => max_variables,
            "powerio_warning_count" => warning_count(network),
            "parse_seconds" => parse_timing.time,
            "parse_allocated_bytes" => parse_timing.bytes,
            "build_seconds" => build_timing.time,
            "build_allocated_bytes" => build_timing.bytes,
            "kcl_seconds" => kcl_timing.time,
            "kcl_allocated_bytes" => kcl_timing.bytes,
            "wall_seconds" => time() - started,
            "memory_observation" =>
                "Sys.maxrss process high-water mark; increments are descriptive",
        )
        variable_count <= max_variables || return merge(base, Dict(
            "skip_reason" => "model_variable_count_exceeds_guard",
        ))
        GC.gc()
        rss_before = Int(Sys.maxrss())
        analyze_timing = @timed NLPDiagnostics.analyze(model)
        rss_after = Int(Sys.maxrss())
        report = analyze_timing.value
        counts = NLPDiagnostics.finding_code_counts(report)
        return merge(base, Dict(
            "analyze_seconds" => analyze_timing.time,
            "analyze_allocated_bytes" => analyze_timing.bytes,
            "analyze_finding_count" => length(report),
            "analyze_finding_code_counts" => Dict(
                string(code) => count for (code, count) in counts
            ),
            "process_maxrss_before_bytes" => rss_before,
            "process_maxrss_after_bytes" => rss_after,
            "process_maxrss_increment_bytes" => max(0, rss_after - rss_before),
            "wall_seconds" => time() - started,
        ))
    catch error
        return Dict{String,Any}(
            "case" => filename,
            "status" => "error",
            "error_type" => string(typeof(error)),
            "error" => sprint(showerror, error),
            "wall_seconds" => time() - started,
        )
    end
end

fixture_root = abspath(get(
    ENV, "NLPDIAGNOSTICS_BMOPF_ANALYZE_PROFILE_FIXTURE_ROOT",
    DEFAULT_FIXTURE_ROOT,
))
max_variables = positive_integer(
    "NLPDIAGNOSTICS_BMOPF_ANALYZE_PROFILE_MAX_VARIABLES", 24,
)
cases = selected_cases()
records = [profile_case(fixture_root, case, max_variables) for case in cases]
status_entries = git_status_entries()

write_json(OUTPUT, Dict{String,Any}(
    "schema_version" => "nlpdiagnostics-bmopf-analyze-runtime-profile-v1",
    "source" => Dict(
        "runner" => "benchmarks/profile_bmopf_analyze_runtime.jl",
        "fixture_root" => fixture_root,
        "cases" => cases,
        "max_variables" => max_variables,
        "point_supplied" => false,
        "entry_point" => "NLPDiagnostics.analyze(model)",
    ),
    "environment" => Dict(
        "julia_version" => string(VERSION),
        "active_project" => Base.active_project(),
        "os" => string(Sys.KERNEL),
        "architecture" => string(Sys.ARCH),
        "git_revision" => git_revision(),
        "git_worktree_dirty" => !isempty(status_entries),
        "git_status_entry_count" => length(status_entries),
        "bmopftools_version" => string(Base.pkgversion(BMOPFTools)),
    ),
    "records" => records,
    "interpretation" => Dict(
        "claim" =>
            "Local bounded adapter and point-free analysis observations on selected BMOPFTools OpenDSS fixtures.",
        "does_not_establish" => [
            "OPF solver runtime or convergence scaling",
            "isolated peak-memory measurements",
            "portable complexity laws or fixture-independent adapter performance",
        ],
        "warning_boundary" =>
            "PowerIO conversion warnings are retained as counts and are not silently treated as failures.",
    ),
))
println("wrote BMOPFTools analyze runtime profile to $OUTPUT")
