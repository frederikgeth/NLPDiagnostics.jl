#!/usr/bin/env julia

"""Run the real-99-bus phase-only campaign under deterministic start policies."""

using JSON

const CAMPAIGN = joinpath(@__DIR__, "real_99bus_phase_only_campaign.jl")
const PROJECT = abspath(joinpath(@__DIR__, "..", "work", "benchmark-environment"))
const CASES = [
    ("completed_start_max40", 40, "completed"),
    ("bmopf_native_start_max40", 40, "bmopf"),
    ("bmopf_generated_start_max40", 40, "bmopf_generated"),
    ("zero_start_max40", 40, "zero"),
]
const ACTIVE_CASES = let
    selected = filter(!isempty, strip.(split(
        get(ENV, "NLPDIAGNOSTICS_REAL_99BUS_INITIALIZATION_MATRIX_CASES", ""), ',';
    )))
    isempty(selected) ? CASES : [case for case in CASES if case[1] in selected]
end

include(CAMPAIGN)

function with_campaign_environment(callback, max_iter, initialization_policy)
    settings = Dict(
        "NLPDIAGNOSTICS_REAL_99BUS_MAX_ITER" => string(max_iter),
        "NLPDIAGNOSTICS_REAL_99BUS_MODEL_FEASIBILITY_TOLERANCE" => "1.0e-8",
        "NLPDIAGNOSTICS_REAL_99BUS_INITIALIZATION_POLICY" => initialization_policy,
    )
    keys_to_restore = collect(keys(settings))
    prior = Dict(key => haskey(ENV, key) ? ENV[key] : nothing for key in keys_to_restore)
    try
        for (key, value) in settings
            ENV[key] = value
        end
        return callback()
    finally
        for (key, value) in prior
            isnothing(value) ? delete!(ENV, key) : (ENV[key] = value)
        end
    end
end

function run_case(label, max_iter, initialization_policy)
    try
        report = with_campaign_environment(max_iter, initialization_policy) do
            run_campaign()
        end
        summary = report["summary"]
        return Dict{String,Any}(
            "label" => label,
            "max_iter" => max_iter,
            "initialization_policy" => initialization_policy,
            "process_completed" => true,
            "report_available" => true,
            "phase_only_locally_solved_count" => summary["phase_only_locally_solved_count"],
            "all_phase_only_runs_locally_solved" => summary["all_phase_only_runs_locally_solved"],
            "phase_only_solver_floor_calibrated_acceptance_count" =>
                summary["phase_only_solver_floor_calibrated_acceptance_count"],
            "phase_only_physical_solver_kkt_acceptance_count" =>
                summary["phase_only_physical_solver_kkt_acceptance_count"],
            "phase_only_physical_solver_kkt_acceptance_by_complementarity_tolerance" =>
                summary["phase_only_physical_solver_kkt_acceptance_by_complementarity_tolerance"],
            "phase_only_maximum_complementarity_residual" =>
                summary["phase_only_maximum_complementarity_residual"],
            "phase_only_complementarity_scaling_audit_pass_count" =>
                summary["phase_only_complementarity_scaling_audit_pass_count"],
            "phase_only_termination_statuses" => [
                get(get(run, "phase_only", Dict()), "termination_status", nothing)
                for run in report["runs"]
            ],
            "initialization_provenance_kinds" => [
                get(get(run, "initialization", Dict()), "provenance_kind", nothing)
                for run in report["runs"]
            ],
            "initialization_missing_coordinate_counts" => [
                get(get(run, "initialization", Dict()), "missing_coordinate_count", nothing)
                for run in report["runs"]
            ],
            "initialization_summaries" => [
                get(run, "initialization", Dict()) for run in report["runs"]
            ],
        )
    catch error
        return Dict{String,Any}(
            "label" => label,
            "max_iter" => max_iter,
            "initialization_policy" => initialization_policy,
            "process_completed" => false,
            "report_available" => false,
            "process_error" => sprint(showerror, error),
        )
    end
end

results = [
    run_case(label, max_iter, initialization_policy)
    for (label, max_iter, initialization_policy) in ACTIVE_CASES
]
output = abspath(get(
    ENV,
    "NLPDIAGNOSTICS_REAL_99BUS_INITIALIZATION_MATRIX_OUTPUT",
    joinpath(@__DIR__, "..", "work", "real-99bus-phase-only-initialization-matrix.json"),
))
mkpath(dirname(output))
write(output, JSON.json(Dict(
    "schema_version" => "nlpdiagnostics-real-99bus-phase-only-initialization-matrix-v1",
    "source" => Dict(
        "campaign" => basename(CAMPAIGN),
        "project" => PROJECT,
        "case_count" => length(ACTIVE_CASES),
        "qualification" => "local initialization sensitivity; no automatic start-policy selection",
    ),
    "cases" => results,
)))
println("wrote real 99-bus phase-only initialization matrix to $output")
