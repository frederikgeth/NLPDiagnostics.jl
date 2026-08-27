#!/usr/bin/env julia

"""Plan the next guarded BMOPFTools solver-scaling measurements."""

using JSON

Base.include(@__MODULE__, joinpath(@__DIR__, "common.jl"))
using .NLPDiagnosticsBenchmarkCommon: git_revision, git_status_entries, read_summary, write_json

const ROOT = abspath(joinpath(@__DIR__, ".."))
const OUTPUT = abspath(isempty(ARGS) ? joinpath(ROOT, "docs", "bmopf_solver_scaling_extension_plan.json") : ARGS[1])
readiness = read_summary("docs/bmopf_solver_scaling_readiness_summary.json")

write_json(OUTPUT, Dict{String,Any}(
    "schema_version" => "nlpdiagnostics-bmopf-solver-scaling-extension-plan-v1",
    "source" => Dict{String,Any}(
        "readiness_summary" => "docs/bmopf_solver_scaling_readiness_summary.json",
        "planner" => "benchmarks/plan_bmopf_solver_scaling_extension.jl",
    ),
    "environment" => Dict{String,Any}(
        "julia_version" => string(VERSION),
        "git_revision" => git_revision(),
        "git_worktree_dirty" => !isempty(git_status_entries()),
    ),
    "status" => "ready_for_review",
    "current_measured_dimensions" => get(readiness, "dimensions", Any[]),
    "current_measured_count" => get(readiness, "measured_count", 0),
    "current_guarded_count" => get(readiness, "guarded_count", 0),
    "planned_cases" => [
        Dict(
            "id" => "538bus_lg_t15_1500",
            "snapshot" => "ENWLsnapshots/538bus_LG/538bus_LG_t15_1500.bmopf.json",
            "expected_model_variable_count" => 11028,
            "solver" => "Ipopt",
            "max_iter" => 50,
            "timeout_seconds" => 180,
        ),
        Dict(
            "id" => "538bus_ln_t15_1500",
            "snapshot" => "ENWLsnapshots/538bus_LN/538bus_LN_t15_1500.bmopf.json",
            "expected_model_variable_count" => 11028,
            "solver" => "Ipopt",
            "max_iter" => 50,
            "timeout_seconds" => 180,
        ),
    ],
    "guards" => Dict(
        "max_variables" => 12000,
        "max_cpu_seconds" => 180,
        "child_process" => true,
        "dense_rank_max_entries" => 0,
        "sparse_qr_max_input_nonzeros" => 1000000,
        "sparse_qr_max_factor_nonzeros" => 4000000,
    ),
    "acceptance_criteria" => [
        "record model variable count and solver termination for every child",
        "retain solve-time range and endpoint provenance",
        "classify timeout, iteration-limit, infeasible, and size-guard outcomes separately",
        "do not fit a complexity law from two new cases",
        "do not interpret Sys.maxrss as allocator-level peak memory",
    ],
    "open_gaps" => get(readiness, "open_gaps", Any[]),
    "interpretation" => "This is an execution-ready measurement plan, not solver evidence. The 11,028-variable cases are selected to extend the existing 4,180/4,902-variable ladder while preserving explicit child-process and dense-work guards.",
    "next_action" => "Run the reviewed 538-bus child-process cases and summarize termination, solve-time, and endpoint provenance before drawing any scaling conclusion.",
))
println("wrote BMOPFTools solver scaling extension plan to $OUTPUT")
