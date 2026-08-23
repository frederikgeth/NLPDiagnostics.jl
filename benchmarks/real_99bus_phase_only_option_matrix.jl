#!/usr/bin/env julia

"""Run the real-99-bus phase-only campaign under local Ipopt option policies."""

const CAMPAIGN = joinpath(@__DIR__, "real_99bus_phase_only_campaign.jl")
const PROJECT = abspath(joinpath(@__DIR__, "..", "work", "benchmark-environment"))
const CASES = [
    ("baseline_max40", 40, Dict{String,String}()),
    ("tight_tol_max60", 60, Dict(
        "NLPDIAGNOSTICS_REAL_99BUS_IPOPT_TOL" => "1.0e-10",
        "NLPDIAGNOSTICS_REAL_99BUS_IPOPT_ACCEPTABLE_TOL" => "1.0e-10",
    )),
    ("monotone_mu_max60", 60, Dict(
        "NLPDIAGNOSTICS_REAL_99BUS_IPOPT_MU_STRATEGY" => "monotone",
    )),
    ("scaling_none_max60", 60, Dict(
        "NLPDIAGNOSTICS_REAL_99BUS_IPOPT_NLP_SCALING_METHOD" => "none",
    )),
]
const ACTIVE_CASES = let
    selected = filter(!isempty, strip.(split(
        get(ENV, "NLPDIAGNOSTICS_REAL_99BUS_OPTION_MATRIX_CASES", ""), ',';
    )))
    isempty(selected) ? CASES : [case for case in CASES if case[1] in selected]
end

include(CAMPAIGN)
using .NLPDiagnosticsBenchmarkCommon

function with_campaign_environment(callback, max_iter, settings)
    local_settings = copy(settings)
    local_settings["NLPDIAGNOSTICS_REAL_99BUS_MAX_ITER"] = string(max_iter)
    local_settings["NLPDIAGNOSTICS_REAL_99BUS_MODEL_FEASIBILITY_TOLERANCE"] = "1.0e-8"
    for key in (
        "NLPDIAGNOSTICS_REAL_99BUS_IPOPT_TOL",
        "NLPDIAGNOSTICS_REAL_99BUS_IPOPT_ACCEPTABLE_TOL",
        "NLPDIAGNOSTICS_REAL_99BUS_IPOPT_ACCEPTABLE_ITER",
        "NLPDIAGNOSTICS_REAL_99BUS_IPOPT_MU_STRATEGY",
        "NLPDIAGNOSTICS_REAL_99BUS_IPOPT_NLP_SCALING_METHOD",
    )
        haskey(local_settings, key) || (local_settings[key] = "")
    end
    keys_to_restore = collect(keys(local_settings))
    prior = Dict(key => haskey(ENV, key) ? ENV[key] : nothing for key in keys_to_restore)
    try
        for (key, value) in local_settings
            ENV[key] = value
        end
        return callback()
    finally
        for (key, value) in prior
            isnothing(value) ? delete!(ENV, key) : (ENV[key] = value)
        end
    end
end

function run_case(label, max_iter, settings)
    try
        report = with_campaign_environment(max_iter, settings) do
            run_campaign()
        end
        summary = report["summary"]
        return Dict{String,Any}(
            "label" => label,
            "max_iter" => max_iter,
            "ipopt_environment" => settings,
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
            "phase_only_complementarity_scaling_audit_pass_count" =>
                summary["phase_only_complementarity_scaling_audit_pass_count"],
            "reference_maximum_complementarity_residual" =>
                summary["reference_maximum_complementarity_residual"],
            "phase_only_maximum_complementarity_residual" =>
                summary["phase_only_maximum_complementarity_residual"],
            "phase_only_termination_statuses" => [
                get(get(run, "phase_only", Dict()), "termination_status", nothing)
                for run in report["runs"]
            ],
        )
    catch error
        return Dict{String,Any}(
            "label" => label,
            "max_iter" => max_iter,
            "ipopt_environment" => settings,
            "process_completed" => false,
            "report_available" => false,
            "process_error" => sprint(showerror, error),
        )
    end
end

results = [run_case(label, max_iter, settings) for (label, max_iter, settings) in ACTIVE_CASES]
output = abspath(get(
    ENV,
    "NLPDIAGNOSTICS_REAL_99BUS_OPTION_MATRIX_OUTPUT",
    joinpath(@__DIR__, "..", "work", "real-99bus-phase-only-option-matrix.json"),
))
mkpath(dirname(output))
NLPDiagnosticsBenchmarkCommon.write_json(output, Dict(
    "schema_version" => "nlpdiagnostics-real-99bus-phase-only-option-matrix-v1",
    "source" => Dict(
        "campaign" => basename(CAMPAIGN),
        "project" => PROJECT,
        "case_count" => length(ACTIVE_CASES),
        "qualification" => "local Ipopt option sensitivity; no automatic policy selection",
    ),
    "cases" => results,
))
println("wrote real 99-bus phase-only option matrix to $output")
