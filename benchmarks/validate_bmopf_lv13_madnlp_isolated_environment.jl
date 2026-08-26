#!/usr/bin/env julia

"""Validate software prerequisites for the isolated LV13 MadNLP handoff.

This is a preflight only.  It does not build the feeder model, invoke a solver,
or claim that the declared timeout and memory envelope is available.
"""

include(joinpath(@__DIR__, "common.jl"))
using .NLPDiagnosticsBenchmarkCommon

const ROOT = repo_root()
const OUTPUT = abspath(get(
    ENV,
    "NLPDIAGNOSTICS_LV13_MADNLP_ENV_OUTPUT",
    joinpath(ROOT, "docs", "bmopf_lv13_madnlp_isolated_environment_summary.json"),
))

plan = read_summary("docs/bmopf_lv13_madnlp_isolated_run_plan.json")
runner = joinpath(ROOT, "benchmarks", "bmopf_combined_mv_lv_perturbed_start_campaign.jl")
active_project = try
    Base.active_project()
catch
    nothing
end
madnlp_path = try
    Base.find_package("MadNLP")
catch
    nothing
end
bmopf_path = try
    Base.find_package("BMOPFTools")
catch
    nothing
end
madnlp_loadable = try
    @eval import MadNLP
    true
catch
    false
end
bmopf_loadable = try
    @eval import BMOPFTools
    true
catch
    false
end
expected_project = joinpath(ROOT, "work", "benchmark-environment", "Project.toml")
checks = Dict{String,Any}(
    "plan_ready" => get(plan, "status", "") == "isolated_run_ready",
    "runner_present" => isfile(runner),
    "madnlp_package_found" => madnlp_path !== nothing,
    "madnlp_loadable" => madnlp_loadable,
    "bmopf_package_found" => bmopf_path !== nothing,
    "bmopf_loadable" => bmopf_loadable,
    "benchmark_project_active" => active_project == expected_project,
)
ready = all(values(checks))
write_json(OUTPUT, Dict{String,Any}(
    "schema_version" => "nlpdiagnostics-bmopf-lv13-madnlp-isolated-environment-v1",
    "runner" => "benchmarks/validate_bmopf_lv13_madnlp_isolated_environment.jl",
    "status" => ready ? "environment_ready" : "environment_incomplete",
    "checks" => checks,
    "observed" => Dict(
        "julia_version" => string(VERSION),
        "active_project" => active_project,
        "expected_project" => expected_project,
        "madnlp_path" => madnlp_path,
        "bmopf_path" => bmopf_path,
        "runner" => relpath(runner, ROOT),
    ),
    "qualification" => Dict(
        "claim" => ready ?
            "the approved isolated LV13 MadNLP software prerequisites are available in the known benchmark environment" :
            "the approved isolated LV13 MadNLP software prerequisites are incomplete in the known benchmark environment",
        "does_not_establish" => [
            "model construction success at 4,902 variables",
            "solver success, timeout compliance, or peak-memory compliance",
        ],
        "next_action" => ready ?
            "apply the external resource envelope and run the approved isolated command" :
            "repair the reported software prerequisite before requesting an isolated run",
    ),
))
println("wrote LV13 MadNLP isolated-environment summary to $OUTPUT")
