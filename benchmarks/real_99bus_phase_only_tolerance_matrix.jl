#!/usr/bin/env julia

"""Run the bounded real-99-bus phase-only campaign under local tolerance/budget policies."""

using JSON

const CAMPAIGN = joinpath(@__DIR__, "real_99bus_phase_only_campaign.jl")
const PROJECT = abspath(joinpath(@__DIR__, "..", "work", "benchmark-environment"))
const CASES = [
    ("baseline_1e8_max40", 40, 1.0e-8),
    ("tight_1e9_max40", 40, 1.0e-9),
    ("budget_1e8_max20", 20, 1.0e-8),
    ("budget_1e8_max60", 60, 1.0e-8),
]

include(CAMPAIGN)

function with_campaign_environment(callback, max_iter, model_tolerance)
    settings = Dict(
        "NLPDIAGNOSTICS_REAL_99BUS_MAX_ITER" => string(max_iter),
        "NLPDIAGNOSTICS_REAL_99BUS_MODEL_FEASIBILITY_TOLERANCE" => string(model_tolerance),
    )
    setting_keys = collect(keys(settings))
    prior = Dict(key => haskey(ENV, key) ? ENV[key] : nothing for key in setting_keys)
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

function run_case(label, max_iter, model_tolerance)
    try
        report = with_campaign_environment(max_iter, model_tolerance) do
            run_campaign()
        end
        summary = report["summary"]
        return Dict{String,Any}(
            "label" => label,
            "max_iter" => max_iter,
            "model_feasibility_tolerance" => model_tolerance,
            "process_completed" => true,
            "report_available" => true,
            "available_run_count" => summary["available_run_count"],
            "phase_only_solver_run_count" => summary["phase_only_solver_run_count"],
            "phase_only_locally_solved_count" => summary["phase_only_locally_solved_count"],
            "phase_only_solver_floor_calibrated_acceptance_count" =>
                summary["phase_only_solver_floor_calibrated_acceptance_count"],
            "all_phase_only_runs_locally_solved" =>
                summary["all_phase_only_runs_locally_solved"],
            "all_phase_only_solver_floor_calibrated_accepted" =>
                summary["all_phase_only_solver_floor_calibrated_accepted"],
            "native_baseline_comparison_pass_count" =>
                summary["native_baseline_comparison_pass_count"],
            "reference_physical_solver_kkt_available_count" =>
                summary["reference_physical_solver_kkt_available_count"],
            "reference_physical_solver_kkt_acceptance_count" =>
                summary["reference_physical_solver_kkt_acceptance_count"],
            "reference_solver_floor_compound_kkt_acceptance_count" =>
                summary["reference_solver_floor_compound_kkt_acceptance_count"],
            "reference_physical_solver_kkt_acceptance_by_complementarity_tolerance" =>
                summary["reference_physical_solver_kkt_acceptance_by_complementarity_tolerance"],
            "phase_only_physical_solver_kkt_available_count" =>
                summary["phase_only_physical_solver_kkt_available_count"],
            "phase_only_physical_solver_kkt_acceptance_count" =>
                summary["phase_only_physical_solver_kkt_acceptance_count"],
            "phase_only_solver_floor_compound_kkt_acceptance_count" =>
                summary["phase_only_solver_floor_compound_kkt_acceptance_count"],
            "phase_only_physical_solver_kkt_acceptance_by_complementarity_tolerance" =>
                summary["phase_only_physical_solver_kkt_acceptance_by_complementarity_tolerance"],
            "reference_complementarity_scaling_audit_pass_count" =>
                summary["reference_complementarity_scaling_audit_pass_count"],
            "phase_only_complementarity_scaling_audit_pass_count" =>
                summary["phase_only_complementarity_scaling_audit_pass_count"],
            "phase_only_covariance_available_count" =>
                summary["phase_only_covariance_available_count"],
            "phase_only_covariance_acceptance_count" =>
                summary["phase_only_covariance_acceptance_count"],
            "phase_only_termination_statuses" => [
                get(get(run, "phase_only", Dict()), "termination_status", nothing)
                for run in report["runs"]
            ],
        )
    catch error
        return Dict{String,Any}(
            "label" => label,
            "max_iter" => max_iter,
            "model_feasibility_tolerance" => model_tolerance,
            "process_completed" => false,
            "report_available" => false,
            "process_error" => sprint(showerror, error),
        )
    end
end

results = [run_case(label, max_iter, model_tolerance) for
    (label, max_iter, model_tolerance) in CASES]
output = abspath(get(
    ENV,
    "NLPDIAGNOSTICS_REAL_99BUS_TOLERANCE_MATRIX_OUTPUT",
    joinpath(@__DIR__, "..", "work", "real-99bus-phase-only-tolerance-matrix.json"),
))
mkpath(dirname(output))
write(output, JSON.json(Dict(
    "schema_version" => "nlpdiagnostics-real-99bus-phase-only-tolerance-matrix-v2",
    "source" => Dict(
        "campaign" => basename(CAMPAIGN),
        "project" => PROJECT,
        "case_count" => length(CASES),
    ),
    "cases" => results,
)))
println("wrote real 99-bus phase-only tolerance matrix to $output")
