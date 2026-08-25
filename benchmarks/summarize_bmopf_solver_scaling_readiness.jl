#!/usr/bin/env julia

"""Extract bounded solver-workload evidence from reviewed BMOPFTools campaigns.

The ledger keeps selected measured snapshots separate from the full-case size
guard. It records solve-time and termination provenance, but does not invent
allocator peaks or a solver complexity law.
"""

include(joinpath(@__DIR__, "common.jl"))
using .NLPDiagnosticsBenchmarkCommon

const ROOT = repo_root()
const FULL_INPUT = "docs/bmopf_combined_mv_lv_scaling_campaign_summary.json"
const SNAPSHOT_INPUT = "docs/bmopf_combined_mv_lv_snapshot_campaign_summary.json"
const OUTPUT = abspath(isempty(ARGS) ?
    joinpath(ROOT, "docs", "bmopf_solver_scaling_readiness_summary.json") : ARGS[1])

full = read_summary(FULL_INPUT)
snapshot = read_summary(SNAPSHOT_INPUT)
full_source = get(full, "source", Dict{String,Any}())
full_shape = get(full, "network_shape", Dict{String,Any}())
full_budgets = get(full, "budgets", Dict{String,Any}())
snapshot_shape = get(snapshot, "snapshot_shape", Dict{String,Any}())

records = Dict{String,Any}[
    Dict{String,Any}(
        "id" => "combined_mv_lv_full_case",
        "fixture" => get(full_source, "case", "unknown"),
        "solver" => "Ipopt/MadNLP",
        "model_variable_count" => get(full_shape, "model_variable_count", nothing),
        "status" => "skipped_size_guard",
        "measured" => false,
        "guarded" => true,
        "max_variables" => get(full_budgets, "max_variables", nothing),
        "max_iter" => get(full_budgets, "max_iter", nothing),
        "max_cpu_seconds" => get(full_budgets, "max_cpu_seconds", nothing),
        "termination_statuses_observed" => String[],
        "reason" => "full combined MV/LV model exceeds the declared solver size guard",
    ),
]

function measured_record(id, fixture, solver, dimensions, workload)
    statuses = get(workload, "termination_statuses_observed", Any[])
    solve_range = get(workload, "solve_seconds_range", Any[])
    valid = !isempty(statuses) && all(string(status) == "LOCALLY_SOLVED" for status in statuses) &&
        length(solve_range) == 2 && all(value -> value isa Real && isfinite(value), solve_range)
    Dict{String,Any}(
        "id" => id,
        "fixture" => fixture,
        "solver" => solver,
        "model_variable_count" => dimensions,
        "status" => valid ? "measured" : "incomplete",
        "measured" => valid,
        "guarded" => false,
        "run_count" => get(workload, "run_count", 0),
        "max_iter" => get(workload, "max_iter", nothing),
        "solver_tolerance" => get(workload, "solver_tolerance", nothing),
        "termination_statuses_observed" => statuses,
        "solve_seconds_range" => solve_range,
        "campaign_qualified" => get(workload, "campaign_qualified", nothing),
        "endpoint_gates_passed" => get(workload, "all_endpoint_gates_passed",
            get(workload, "all_physical_endpoints_accepted", nothing)),
        "comparison_qualified" => get(workload, "comparison_qualified_for_all_policy_pairs", nothing),
    )
end

push!(records, measured_record(
    "mv21_lv1_ipopt_baseline",
    "MV21_328bus + LV1_14bus",
    "Ipopt",
    get(snapshot_shape, "model_variable_count", nothing),
    get(snapshot, "campaigns", Any[])[1],
))
push!(records, measured_record(
    "mv21_lv1_madnlp_baseline",
    "MV21_328bus + LV1_14bus",
    "MadNLP",
    get(snapshot_shape, "model_variable_count", nothing),
    get(snapshot, "campaigns", Any[])[2],
))
push!(records, measured_record(
    "mv21_lv1_ipopt_tight_tolerance",
    "MV21_328bus + LV1_14bus",
    "Ipopt",
    get(snapshot_shape, "model_variable_count", nothing),
    get(snapshot, "ipopt_tolerance_diagnostic", Dict{String,Any}()),
))
second_feeder = get(snapshot, "second_feeder_campaign", Dict{String,Any}())
lv13_matrix = get(snapshot, "perturbed_start_lv13_matrix", Dict{String,Any}())
lv13_variants = get(lv13_matrix, "variants", Any[])
lv13_ranges = [
    Float64(value)
    for variant in lv13_variants
    for value in get(variant, "solve_seconds_range", Any[])
    if value isa Real && isfinite(value)
]
lv13_workload = merge(
    second_feeder,
    Dict{String,Any}(
        "run_count" => sum(get(variant, "run_count", 0) for variant in lv13_variants),
        "termination_statuses_observed" => unique(vcat([
            get(variant, "termination_statuses_observed", Any[])
            for variant in lv13_variants
        ]...)),
        "solve_seconds_range" => isempty(lv13_ranges) ? Any[] : [minimum(lv13_ranges), maximum(lv13_ranges)],
        "all_physical_endpoints_accepted" => get(lv13_matrix, "matrix_gates", Dict{String,Any}())["all_physical_endpoints_accepted"],
        "comparison_qualified_for_all_policy_pairs" => get(lv13_matrix, "matrix_gates", Dict{String,Any}())["all_comparisons_qualified"],
    ),
)
push!(records, measured_record(
    "mv21_lv13_ipopt_perturbed_starts",
    get(second_feeder, "feeder", "LV13_58bus"),
    get(second_feeder, "solver", "Ipopt"),
    get(get(second_feeder, "snapshot_shape", Dict{String,Any}()), "model_variable_count", nothing),
    lv13_workload,
))

measured_count = count(record -> get(record, "measured", false), records)
guarded_count = count(record -> get(record, "guarded", false), records)
status_entries = git_status_entries()
write_json(OUTPUT, Dict{String,Any}(
    "schema_version" => "nlpdiagnostics-bmopf-solver-scaling-readiness-v1",
    "source" => Dict{String,Any}(
        "runner" => "benchmarks/summarize_bmopf_solver_scaling_readiness.jl",
        "artifacts" => [FULL_INPUT, SNAPSHOT_INPUT],
        "policy" => "Measured records require explicit solve-time ranges and locally-solved termination provenance; full-case size guards remain readiness evidence.",
    ),
    "environment" => Dict{String,Any}(
        "julia_version" => string(VERSION),
        "active_project" => Base.active_project(),
        "git_revision" => git_revision(),
        "git_worktree_dirty" => !isempty(status_entries),
    ),
    "record_count" => length(records),
    "measured_count" => measured_count,
    "guarded_count" => guarded_count,
    "dimensions" => sort(unique(Int[record["model_variable_count"] for record in records if record["model_variable_count"] isa Integer])),
    "records" => records,
    "open_gaps" => [
        "extend the solver ladder beyond the two selected BMOPFTools snapshots",
        "add allocator-level peak telemetry independent of Sys.maxrss",
        "repeat the workload in a second reviewed environment",
    ],
    "interpretation" => Dict{String,Any}(
        "claim" => "The selected BMOPFTools MV+LV campaigns provide bounded solver-workload records at 4,180 and 4,902 variables, while the 56,142-variable full case remains explicitly size-guarded.",
        "does_not_establish" => [
            "a solver complexity law or production scalability guarantee",
            "allocator-level peak memory",
            "portable cross-machine performance",
            "solver or scaling-policy superiority",
        ],
    ),
))

measured_count > 0 || error("no measured solver-workload records were available")
guarded_count > 0 || error("full-case solver size guard was not retained")
println("wrote BMOPFTools solver scaling readiness summary to $OUTPUT")
