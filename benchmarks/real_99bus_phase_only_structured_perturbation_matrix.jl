#!/usr/bin/env julia

"""Run deterministic completed-start perturbations by physical variable block."""

using JSON

const CAMPAIGN = joinpath(@__DIR__, "real_99bus_phase_only_campaign.jl")
const PROJECT = abspath(joinpath(@__DIR__, "..", "work", "benchmark-environment"))
const CASES = [
    ("completed_baseline_max40", 40, "completed", 11, 0.0, "all"),
    ("voltage_seed11_1e5_max60", 60, "perturbed", 11, 1.0e-5, "voltage"),
    ("voltage_seed11_1e4_max60", 60, "perturbed", 11, 1.0e-4, "voltage"),
    ("current_seed11_1e4_max60", 60, "perturbed", 11, 1.0e-4, "current"),
]

include(CAMPAIGN)

function with_campaign_environment(callback, max_iter, policy, seed, relative_size, family)
    settings = Dict(
        "NLPDIAGNOSTICS_REAL_99BUS_MAX_ITER" => string(max_iter),
        "NLPDIAGNOSTICS_REAL_99BUS_MODEL_FEASIBILITY_TOLERANCE" => "1.0e-8",
        "NLPDIAGNOSTICS_REAL_99BUS_INITIALIZATION_POLICY" => policy,
        "NLPDIAGNOSTICS_REAL_99BUS_START_PERTURBATION_SEED" => string(seed),
        "NLPDIAGNOSTICS_REAL_99BUS_START_PERTURBATION_RELATIVE_SIZE" => string(relative_size),
        "NLPDIAGNOSTICS_REAL_99BUS_START_PERTURBATION_FAMILY" => family,
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

function run_case(label, max_iter, policy, seed, relative_size, family)
    try
        report = with_campaign_environment(max_iter, policy, seed, relative_size, family) do
            run_campaign()
        end
        summary = report["summary"]
        return Dict{String,Any}(
            "label" => label,
            "max_iter" => max_iter,
            "initialization_policy" => policy,
            "seed" => seed,
            "relative_size" => relative_size,
            "family" => family,
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
        )
    catch error
        return Dict{String,Any}(
            "label" => label,
            "max_iter" => max_iter,
            "initialization_policy" => policy,
            "seed" => seed,
            "relative_size" => relative_size,
            "family" => family,
            "process_completed" => false,
            "report_available" => false,
            "process_error" => sprint(showerror, error),
        )
    end
end

results = [
    run_case(label, max_iter, policy, seed, relative_size, family)
    for (label, max_iter, policy, seed, relative_size, family) in CASES
]
output = abspath(get(
    ENV,
    "NLPDIAGNOSTICS_REAL_99BUS_STRUCTURED_PERTURBATION_MATRIX_OUTPUT",
    joinpath(@__DIR__, "..", "work", "real-99bus-phase-only-structured-perturbation-matrix.json"),
))
mkpath(dirname(output))
write(output, JSON.json(Dict(
    "schema_version" => "nlpdiagnostics-real-99bus-phase-only-structured-perturbation-matrix-v1",
    "source" => Dict(
        "campaign" => basename(CAMPAIGN),
        "project" => PROJECT,
        "case_count" => length(CASES),
        "qualification" => "local bounded-start block perturbation sensitivity; no causal or automatic policy claim",
    ),
    "cases" => results,
)))
println("wrote real 99-bus phase-only structured perturbation matrix to $output")
