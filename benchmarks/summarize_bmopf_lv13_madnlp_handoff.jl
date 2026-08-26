#!/usr/bin/env julia

"""Join the LV13 MadNLP plan, preflight, resource, and result ledgers."""

include(joinpath(@__DIR__, "common.jl"))
using .NLPDiagnosticsBenchmarkCommon

const ROOT = repo_root()
const OUTPUT = abspath(get(
    ENV,
    "NLPDIAGNOSTICS_LV13_MADNLP_HANDOFF_OUTPUT",
    joinpath(ROOT, "docs", "bmopf_lv13_madnlp_handoff_summary.json"),
))

plan = read_summary("docs/bmopf_lv13_madnlp_isolated_run_plan.json")
environment = read_summary("docs/bmopf_lv13_madnlp_isolated_environment_summary.json")
resources = read_summary("docs/bmopf_lv13_madnlp_resource_envelope_summary.json")
result = read_summary("docs/bmopf_lv13_madnlp_isolated_result_summary.json")
resource_checks = get(resources, "checks", Dict{String,Any}())
software_ready = get(environment, "status", "") == "environment_ready"
capacity_ready = get(resource_checks, "host_capacity_meets_envelope", false)
free_ready = get(resource_checks, "current_free_memory_meets_envelope", false)
result_complete = get(result, "status", "") == "isolated_result_complete"
blockers = String[]
software_ready || push!(blockers, "software_preflight_incomplete")
capacity_ready || push!(blockers, "host_capacity_below_declared_envelope")
free_ready || push!(blockers, "current_free_memory_below_declared_envelope")
result_complete && push!(blockers, "isolated_result_already_recorded")
status = result_complete ? "handoff_complete" :
    !software_ready ? "blocked_software_preflight" :
    !capacity_ready ? "blocked_host_capacity" :
    !free_ready ? "blocked_current_memory_pressure" :
    "ready_to_launch"
next_action = status == "blocked_current_memory_pressure" ?
    "repeat the resource assessment after reducing host memory pressure, then launch the approved command" :
    status == "ready_to_launch" ?
    "apply external timeout and memory enforcement, then launch the approved command" :
    status == "handoff_complete" ?
    "rerun the result validator and add the qualified result to the application bridge" :
    "repair the reported blocker before launching the approved command"
write_json(OUTPUT, Dict{String,Any}(
    "schema_version" => "nlpdiagnostics-bmopf-lv13-madnlp-handoff-v1",
    "runner" => "benchmarks/summarize_bmopf_lv13_madnlp_handoff.jl",
    "status" => status,
    "blockers" => blockers,
    "inputs" => Dict(
        "plan" => "docs/bmopf_lv13_madnlp_isolated_run_plan.json",
        "environment" => "docs/bmopf_lv13_madnlp_isolated_environment_summary.json",
        "resources" => "docs/bmopf_lv13_madnlp_resource_envelope_summary.json",
        "result" => "docs/bmopf_lv13_madnlp_isolated_result_summary.json",
    ),
    "readiness" => Dict(
        "software_ready" => software_ready,
        "host_capacity_ready" => capacity_ready,
        "current_free_memory_ready" => free_ready,
        "result_complete" => result_complete,
    ),
    "resource_observation" => get(resources, "observed", Dict{String,Any}()),
    "resource_envelope" => get(plan, "resource_envelope", Dict{String,Any}()),
    "execution" => get(plan, "execution", Dict{String,Any}()),
    "qualification" => Dict(
        "claim" => "the isolated LV13 MadNLP handoff has one joined, reviewable readiness state",
        "does_not_establish" => [
            "memory reservation or external enforcement",
            "solver success or cross-feeder equivalence before the result artifact qualifies",
        ],
        "next_action" => next_action,
    ),
))
println("wrote LV13 MadNLP handoff summary to $OUTPUT")
