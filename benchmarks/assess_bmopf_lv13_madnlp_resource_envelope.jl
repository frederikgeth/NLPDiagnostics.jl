#!/usr/bin/env julia

"""Assess host capacity for the approved LV13 MadNLP isolated run.

This is descriptive host telemetry only.  It does not reserve memory, enforce
the envelope, construct the feeder model, or invoke MadNLP.
"""

include(joinpath(@__DIR__, "common.jl"))
using .NLPDiagnosticsBenchmarkCommon

const ROOT = repo_root()
const OUTPUT = abspath(get(
    ENV,
    "NLPDIAGNOSTICS_LV13_MADNLP_RESOURCE_OUTPUT",
    joinpath(ROOT, "docs", "bmopf_lv13_madnlp_resource_envelope_summary.json"),
))

plan = read_summary("docs/bmopf_lv13_madnlp_isolated_run_plan.json")
environment = read_summary("docs/bmopf_lv13_madnlp_isolated_environment_summary.json")
envelope = get(plan, "resource_envelope", Dict{String,Any}())
required_memory_mb = Int(get(envelope, "memory_limit_mb", 0))
total_memory_bytes = try
    Sys.total_memory()
catch
    nothing
end
free_memory_bytes = try
    Sys.free_memory()
catch
    nothing
end
total_memory_mb = total_memory_bytes isa Number ? Int(fld(total_memory_bytes, 1_048_576)) : nothing
free_memory_mb = free_memory_bytes isa Number ? Int(fld(free_memory_bytes, 1_048_576)) : nothing
capacity_margin_mb = total_memory_mb isa Number ? total_memory_mb - required_memory_mb : nothing
free_memory_margin_mb = free_memory_mb isa Number ? free_memory_mb - required_memory_mb : nothing
additional_free_memory_required_mb = free_memory_margin_mb isa Number ?
    max(0, -free_memory_margin_mb) : nothing
checks = Dict{String,Any}(
    "environment_ready" => get(environment, "status", "") == "environment_ready",
    "plan_ready" => get(plan, "status", "") == "isolated_run_ready",
    "declared_memory_positive" => required_memory_mb > 0,
    "host_capacity_meets_envelope" => total_memory_mb isa Number && total_memory_mb >= required_memory_mb,
    "current_free_memory_meets_envelope" => free_memory_mb isa Number && free_memory_mb >= required_memory_mb,
)
capacity_ready = checks["environment_ready"] && checks["plan_ready"] &&
    checks["declared_memory_positive"] && checks["host_capacity_meets_envelope"]
status = !capacity_ready ? "resource_capacity_insufficient" :
    checks["current_free_memory_meets_envelope"] ? "resource_envelope_ready" :
    "resource_capacity_available_but_current_free_memory_insufficient"
write_json(OUTPUT, Dict{String,Any}(
    "schema_version" => "nlpdiagnostics-bmopf-lv13-madnlp-resource-envelope-v1",
    "runner" => "benchmarks/assess_bmopf_lv13_madnlp_resource_envelope.jl",
    "status" => status,
    "declared_envelope" => envelope,
    "checks" => checks,
    "observed" => Dict(
        "julia_version" => string(VERSION),
        "cpu_threads" => Sys.CPU_THREADS,
        "total_memory_mb" => total_memory_mb,
        "free_memory_mb" => free_memory_mb,
        "capacity_margin_mb" => capacity_margin_mb,
        "free_memory_margin_mb" => free_memory_margin_mb,
        "additional_free_memory_required_mb" => additional_free_memory_required_mb,
        "telemetry_scope" => "descriptive point-in-time host observation",
    ),
    "qualification" => Dict(
        "claim" => "the host capacity and current free-memory state are recorded against the approved isolated-run envelope",
        "does_not_establish" => [
            "memory reservation or enforcement",
            "solver success, model construction success, or timeout compliance",
        ],
        "next_action" => status == "resource_envelope_ready" ?
            "apply external timeout and memory enforcement, then run the approved isolated command" :
            "repeat this assessment when sufficient free memory is available before launching the isolated command",
    ),
))
println("wrote LV13 MadNLP resource-envelope assessment to $OUTPUT")
