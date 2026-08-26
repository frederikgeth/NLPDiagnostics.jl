#!/usr/bin/env julia

"""Build an explicit bridge between synthetic ladder and practical ledgers.

The bridge checks that both evidence families expose the same procedural
contracts, while refusing to imply direct physical equivalence between the
synthetic ladder and the combined MV/LV feeders.
"""

include(joinpath(@__DIR__, "common.jl"))
using .NLPDiagnosticsBenchmarkCommon

const ROOT = repo_root()
const PRACTICAL_INPUT = "docs/bmopf_practical_application_success_summary.json"
const MADNLP_INPUT = "docs/bmopf_voltage_level_series_madnlp_campaign_summary.json"
const UPRATED_INPUT = "docs/bmopf_voltage_level_series_uprated_nominal_campaign_summary.json"
const LV13_GUARD_INPUT = "docs/bmopf_lv13_madnlp_transfer_guard_summary.json"
const LV13_RESULT_INPUT = "docs/bmopf_lv13_madnlp_isolated_result_summary.json"
const FEASIBILITY_INPUT = "docs/bmopf_voltage_level_series_feasibility_sweep_summary.json"
const OUTPUT = abspath(isempty(ARGS) ?
    joinpath(ROOT, "docs", "bmopf_series_application_bridge_summary.json") : ARGS[1])

function _practical_row(row)
    controls = get(row, "fragility_controls", Dict{String,Any}())
    return Dict{String,Any}(
        "evidence_id" => get(row, "id", "unknown"),
        "evidence_family" => "combined_mv_lv_application",
        "solver" => get(row, "solver", "unknown"),
        "case" => get(row, "feeder", "unknown"),
        "model_variable_count" => nothing,
        "transformer_count" => nothing,
        "load_multiplier" => nothing,
        "run_count" => get(row, "run_count", 0),
        "success" => get(row, "success", false),
        "locally_solved" => get(row, "termination_statuses_observed", Any[]) == ["LOCALLY_SOLVED"],
        "physical_endpoints_accepted" => get(controls, "physical_endpoints_accepted", false),
        "comparisons_qualified" => get(controls, "comparisons_qualified", false),
        "coverage_complete" => get(controls, "coverage_complete", get(controls, "all_variants_qualified", false)),
    )
end

function _series_row(record; evidence_id, solver, rating_multiplier = nothing)
    gates = get(record, "campaign_gates", Dict{String,Any}())
    rows = get(record, "records", Any[])
    return Dict{String,Any}(
        "evidence_id" => evidence_id,
        "evidence_family" => "series_transformer_synthetic",
        "solver" => solver,
        "case" => get(record, "label", "unknown"),
        "model_variable_count" => get(record, "model_variable_count", nothing),
        "transformer_count" => get(record, "transformer_count", nothing),
        "load_multiplier" => get(record, "load_multiplier", nothing),
        "rating_multiplier" => rating_multiplier,
        "run_count" => length(rows),
        "success" => get(record, "campaign_qualified", false),
        "locally_solved" => all(get(row, "termination_status", "") == "LOCALLY_SOLVED" for row in rows),
        "physical_endpoints_accepted" => get(gates, "all_physical_endpoints_accepted", false),
        "comparisons_qualified" => get(gates, "all_comparisons_qualified", false),
        "coverage_complete" => get(gates, "comparison_coverage_complete", false),
    )
end

practical = read_summary(PRACTICAL_INPUT)
madnlp = read_summary(MADNLP_INPUT)
uprated = read_summary(UPRATED_INPUT)
lv13_guard = read_summary(LV13_GUARD_INPUT)
lv13_result = read_summary(LV13_RESULT_INPUT)
feasibility = read_summary(FEASIBILITY_INPUT)
practical_rows = [_practical_row(row) for row in get(practical, "records", Any[])]
series_records = get(madnlp, "records", Any[])
isempty(series_records) && error("MadNLP campaign has no records")
series_row = _series_row(
    first(series_records);
    evidence_id = "series_8level_230kV_208V_madnlp",
    solver = "MadNLP",
    rating_multiplier = 1.0,
)
uprated_rows = Dict{String,Any}[]
for campaign in get(uprated, "campaigns", Any[])
    push!(uprated_rows, _series_row(
        get(campaign, "record", Dict{String,Any}());
        evidence_id = "series_8level_230kV_208V_uprated_$(lowercase(get(campaign, "solver", "unknown")))",
        solver = get(campaign, "solver", "unknown"),
        rating_multiplier = get(uprated, "rating_multiplier", nothing),
    ))
end
evidence_rows = vcat(practical_rows, [series_row], uprated_rows)
solver_coverage = Dict{String,Any}()
for case in sort!(unique(row["case"] for row in evidence_rows))
    case_rows = filter(row -> row["case"] == case, evidence_rows)
    solver_coverage[case] = Dict(
        "solvers" => sort!(unique(row["solver"] for row in case_rows)),
        "evidence_row_count" => length(case_rows),
    )
end
transfer_gaps = [Dict(
    "case" => "LV13_58bus",
    "missing_solver" => "MadNLP",
    "guard_status" => get(lv13_guard, "status", "missing"),
    "guard_max_variables" => get(get(lv13_guard, "budget", Dict{String,Any}()), "max_variables", nothing),
    "guard_model_variables" => get(get(lv13_guard, "snapshot", Dict{String,Any}()), "model_variable_count", nothing),
    "solver_runs_under_guard" => get(get(lv13_guard, "observed", Dict{String,Any}()), "solver_runs", nothing),
    "result_status" => get(lv13_result, "status", "missing"),
    "result_artifact_present" => get(get(lv13_result, "checks", Dict{String,Any}()), "artifact_present", false),
    "reason" => "the qualified practical ledger currently has Ipopt evidence on LV13_58bus but no bounded solver-diverse repeat",
    "next_experiment" => "run the approved isolated MadNLP command and rerun the result validator before making cross-feeder solver comparisons",
)]
shared_contracts = [
    all(row["success"] for row in evidence_rows),
    all(row["locally_solved"] for row in evidence_rows),
    all(row["physical_endpoints_accepted"] for row in evidence_rows),
    all(row["comparisons_qualified"] for row in evidence_rows),
]
sweep_records = get(feasibility, "records", Any[])
nominal = isempty(sweep_records) ? Dict{String,Any}() : first(sweep_records)
bridge = Dict{String,Any}(
    "schema_version" => "nlpdiagnostics-bmopf-series-application-bridge-v1",
    "runner" => "benchmarks/summarize_bmopf_series_application_bridge.jl",
    "status" => all(shared_contracts) ? "procedural_bridge_complete" : "procedural_bridge_partial",
    "evidence_rows" => evidence_rows,
    "solver_coverage" => solver_coverage,
    "transfer_gaps" => transfer_gaps,
    "uprated_fixture" => Dict(
        "rating_multiplier" => get(uprated, "rating_multiplier", nothing),
        "load_multiplier" => get(uprated, "load_multiplier", nothing),
        "solver_count" => length(uprated_rows),
        "campaigns_qualified" => all(row["success"] for row in uprated_rows),
        "source" => UPRATED_INPUT,
    ),
    "lv13_madnlp_guard" => Dict(
        "status" => get(lv13_guard, "status", "missing"),
        "source" => LV13_GUARD_INPUT,
        "solver_runs" => get(get(lv13_guard, "observed", Dict{String,Any}()), "solver_runs", nothing),
    ),
    "lv13_madnlp_result" => Dict(
        "status" => get(lv13_result, "status", "missing"),
        "source" => LV13_RESULT_INPUT,
        "artifact_present" => get(get(lv13_result, "checks", Dict{String,Any}()), "artifact_present", false),
    ),
    "shared_contracts" => Dict(
        "all_rows_procedurally_successful" => all(shared_contracts),
        "physical_endpoint_contract" => "all evidence rows retain explicit physical-endpoint acceptance",
        "comparison_contract" => "all evidence rows retain explicit comparison qualification",
        "direct_physical_equivalence" => false,
        "direct_physical_equivalence_reason" => "synthetic series ladders and combined MV/LV feeders have different topology and operating-point provenance",
    ),
    "nominal_demand_boundary" => Dict(
        "series_case" => get(series_row, "case", nothing),
        "feasibility_sweep_records" => length(sweep_records),
        "currently_qualified_multiplier" => get(series_row, "load_multiplier", nothing),
        "nominal_multiplier_status" => isempty(sweep_records) ? "unavailable" : "not_qualified_in_recorded_sweep",
        "original_fixture_nominal_status" => "overloaded_by_capacity_screen",
        "uprated_fixture_nominal_status" => all(row["success"] for row in uprated_rows) ? "qualified" : "partial",
        "next_experiment" => "retain the uprated rating multiplier as explicit fixture metadata and compare its results with practical application evidence",
        "evidence_source" => FEASIBILITY_INPUT,
        "boundary_record" => nominal,
    ),
    "qualification" => Dict(
        "claim" => "the synthetic ladder and practical combined MV/LV ledgers share explicit procedural success contracts",
        "does_not_establish" => [
            "direct physical equivalence of the fixtures",
            "solver or scaling-policy superiority",
            "nominal-demand feasibility",
        ],
        "next_action" => "use the bridge as the acceptance checklist for future uprated and practical application campaigns",
    ),
)
write_json(OUTPUT, bridge)
println("wrote BMOPFTools series/application bridge summary to $OUTPUT")
