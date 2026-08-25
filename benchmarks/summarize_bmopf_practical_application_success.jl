#!/usr/bin/env julia

"""Summarize successful practical BMOPFTools application workflows.

This is a regression-oriented ledger over the reviewed combined MV/LV feeder
campaign.  It does not rerun the expensive solver campaign; it makes the
success criteria explicit so later changes can detect fragility in the
application workflow and its evidence artifact.
"""

include(joinpath(@__DIR__, "common.jl"))
using .NLPDiagnosticsBenchmarkCommon

const ROOT = repo_root()
const INPUT = "docs/bmopf_combined_mv_lv_snapshot_campaign_summary.json"
const OUTPUT = abspath(isempty(ARGS) ?
    joinpath(ROOT, "docs", "bmopf_practical_application_success_summary.json") : ARGS[1])

function _all_locally_solved(rows)
    rows isa AbstractVector || return false
    isempty(rows) && return false
    return all(
        all(status -> status == "LOCALLY_SOLVED", get(row, "termination_statuses_observed", Any[]))
        for row in rows
    )
end

function _campaign_success(data)
    gates = data isa AbstractDict ? data : Dict{String,Any}()
    return get(gates, "all_physical_endpoints_accepted", false) &&
           get(gates, "all_comparisons_qualified", false) &&
           get(gates, "comparison_coverage_complete", false) &&
           get(gates, "terminations_stable_within_policy", false)
end

function _matrix_success(data)
    matrix = data isa AbstractDict ? get(data, "matrix_gates", Dict{String,Any}()) : Dict{String,Any}()
    return get(matrix, "all_variants_qualified", false) &&
           get(matrix, "all_physical_endpoints_accepted", false) &&
           get(matrix, "all_comparisons_qualified", false) &&
           _all_locally_solved(get(data, "variants", Any[]))
end

function _record(id, application, feeder, solver, data, kind)
    success = kind == "campaign" ? _campaign_success(data) : _matrix_success(data)
    rows = kind == "campaign" ? Any[] : get(data, "variants", Any[])
    terminations = kind == "campaign" ? get(data, "termination_statuses_observed", Any[]) :
        sort!(unique(vcat([get(row, "termination_statuses_observed", Any[]) for row in rows]...)))
    run_count = haskey(data, "run_count") ? data["run_count"] :
        sum(get(row, "run_count", 0) for row in rows; init = 0)
    comparison_count = haskey(data, "comparison_count") ? data["comparison_count"] :
        sum(get(row, "comparison_count", 0) for row in rows; init = 0)
    return Dict{String,Any}(
        "id" => id,
        "application" => application,
        "feeder" => feeder,
        "solver" => solver,
        "evidence_kind" => kind,
        "success" => success,
        "termination_statuses_observed" => terminations,
        "run_count" => run_count,
        "comparison_count" => comparison_count,
        "maximum_physical_covariance_absolute_difference" =>
            get(data, "maximum_physical_covariance_absolute_difference", nothing),
        "fragility_controls" => kind == "campaign" ? Dict(
            "physical_endpoints_accepted" => get(data, "all_physical_endpoints_accepted", false),
            "comparisons_qualified" => get(data, "all_comparisons_qualified", false),
            "coverage_complete" => get(data, "comparison_coverage_complete", false),
            "terminations_stable" => get(data, "terminations_stable_within_policy", false),
        ) : Dict(
            "all_variants_qualified" => get(data, "matrix_gates", Dict())["all_variants_qualified"],
            "physical_endpoints_accepted" => get(data, "matrix_gates", Dict())["all_physical_endpoints_accepted"],
            "comparisons_qualified" => get(data, "matrix_gates", Dict())["all_comparisons_qualified"],
        ),
    )
end

source = read_summary(INPUT)
records = Dict{String,Any}[
    _record("lv1_14bus_ipopt_tight_tolerance", "tight-tolerance matched-start campaign", "LV1_14bus", "Ipopt", source["ipopt_tolerance_diagnostic"], "campaign"),
    _record("lv13_58bus_ipopt_transfer", "second-feeder matched-start campaign", "LV13_58bus", "Ipopt", source["second_feeder_campaign"], "campaign"),
    _record("lv1_14bus_perturbed_starts", "global affine start perturbation matrix", "LV1_14bus", "Ipopt", source["perturbed_start_matrix"], "matrix"),
    _record("lv13_58bus_perturbed_starts", "second-feeder start perturbation matrix", "LV13_58bus", "Ipopt", source["perturbed_start_lv13_matrix"], "matrix"),
    _record("lv1_14bus_madnlp_perturbed_starts", "solver-diverse start perturbation matrix", "LV1_14bus", "MadNLP", source["perturbed_start_madnlp_matrix"], "matrix"),
    _record("lv1_14bus_voltage_only_starts", "voltage-only start perturbation matrix", "LV1_14bus", "Ipopt", source["voltage_only_start_matrix"], "matrix"),
]
success_count = count(record -> record["success"], records)
status_entries = git_status_entries()
write_json(OUTPUT, Dict{String,Any}(
    "schema_version" => "nlpdiagnostics-bmopf-practical-application-success-v1",
    "source" => Dict(
        "runner" => "benchmarks/summarize_bmopf_practical_application_success.jl",
        "campaign_summary" => INPUT,
        "execution_mode" => "summary_only_no_solver_rerun",
    ),
    "environment" => Dict(
        "julia_version" => string(VERSION),
        "active_project" => Base.active_project(),
        "git_revision" => git_revision(),
        "git_worktree_dirty" => !isempty(status_entries),
    ),
    "application_count" => length(records),
    "successful_application_count" => success_count,
    "status" => success_count == length(records) ? "practical_application_successes_validated" : "practical_application_followup_required",
    "records" => records,
    "qualification" => Dict(
        "claim" => "reviewed combined MV/LV feeder workflows reached locally solved, endpoint-gated, cross-policy qualified outcomes in the known environment",
        "fragility_value" => "explicitly preserves physical-endpoint, comparison-coverage, termination-stability, and start-perturbation checks",
        "does_not_establish" => [
            "a universal scaling policy",
            "solver superiority",
            "portable performance or memory scaling",
        ],
        "next_action" => "rerun this ledger after campaign or dependency changes, then extend it to selected series-transformer ladder solver cases",
    ),
))
println("wrote BMOPFTools practical application success summary to $OUTPUT")
