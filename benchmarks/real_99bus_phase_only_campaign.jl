#!/usr/bin/env julia

"""Run bounded matched reference and phase-only Ipopt solves on real ENWL snapshots."""

using BMOPFTools
using Ipopt
using JSON
using JuMP
using NLPDiagnostics
using SHA
import MathOptInterface as MOI

const DEFAULT_ROOT = normpath(joinpath(@__DIR__, "..", "..", "BMOPFDraftData", "benchmarks"))
const SELECTED_SNAPSHOTS = [
    "ENWLsnapshots/99bus_LN/99bus_LN_t01_0800.bmopf.json",
    "ENWLsnapshots/99bus_LN/99bus_LN_t13_1400.bmopf.json",
    "ENWLsnapshots/99bus_LN/99bus_LN_t25_2000.bmopf.json",
    "ENWLsnapshots/99bus_LG/99bus_LG_t01_0800.bmopf.json",
    "ENWLsnapshots/99bus_LG/99bus_LG_t13_1400.bmopf.json",
    "ENWLsnapshots/99bus_LG/99bus_LG_t25_2000.bmopf.json",
]

function set_start_values!(model, variables, values)
    length(variables) == length(values) || error("start vector does not match model variables")
    for (variable, value) in zip(variables, values)
        MOI.set(JuMP.backend(model), MOI.VariablePrimalStart(), variable, value)
    end
end

function solve_reference(context, point; max_iter)
    model = BMOPFTools.opf_model(context)
        set_start_values!(model, point.variables, point.values)
    JuMP.set_optimizer_attribute(model, "max_iter", max_iter)
    try
        JuMP.optimize!(model)
        return Dict{String,Any}(
            "available" => true,
            "solver_run_completed" => true,
            "termination_status" => string(JuMP.termination_status(model)),
            "primal_status" => string(JuMP.primal_status(model)),
            "objective_value" => try Float64(JuMP.objective_value(model)) catch; nothing end,
        )
    catch error
        return Dict{String,Any}(
            "available" => false,
            "solver_run_completed" => false,
            "reason" => "reference optimizer failed",
            "error" => sprint(showerror, error),
        )
    end
end

function run_snapshot(root, relative; angle, max_iter)
    path = joinpath(root, relative)
    try
        network = BMOPFTools.parse_bmopf(path)
        context = BMOPFTools.build_opf_model(
            deepcopy(network);
            optimizer=Ipopt.Optimizer,
            add_objective=true,
        )
        BMOPFTools.enforce_kcl!(context)
        point = NLPDiagnostics.bmopf_start_completion_point(
            context;
            missing_value=0.0,
            label="real-99bus-phase-only-campaign",
        )
        evaluation = NLPDiagnostics.evaluate_numerical(
            JuMP.backend(BMOPFTools.opf_model(context)),
            point,
        )
        plan = NLPDiagnostics.bmopf_phase_only_transform_plan(
            context,
            evaluation;
            angle,
            max_dense_entries=0,
        )
        reference = solve_reference(context, point; max_iter)
        candidate_model = JuMP.Model(Ipopt.Optimizer)
        JuMP.set_optimizer_attribute(candidate_model, "max_iter", max_iter)
        phase_only = NLPDiagnostics.bmopf_phase_only_solve_model(
            context,
            evaluation;
            plan,
            optimizer_model=candidate_model,
            optimize=true,
        )
        return Dict{String,Any}(
            "available" => true,
            "snapshot" => relative,
            "sha256" => bytes2hex(SHA.sha256(read(path))),
            "angle" => angle,
            "variable_count" => length(evaluation.point.variables),
            "constraint_count" => length(evaluation.constraint_sources),
            "rotated_variable_block_count" => plan["rotated_variable_block_count"],
            "intervention_classification" => plan["intervention"]["classification"],
            "reference" => reference,
            "phase_only" => Dict(
                "available" => get(phase_only, "available", false),
                "model_attached" => get(phase_only, "model_attached", false),
                "solver_run_completed" => get(phase_only, "solver_run_completed", false),
                "termination_status" => get(phase_only, "termination_status", nothing),
                "primal_status" => get(phase_only, "primal_status", nothing),
                "objective_value" => get(phase_only, "objective_value", nothing),
                "model_rebuilt" => get(get(phase_only, "rebuild", Dict()), "model_rebuilt", false),
                "start_values_copied" => get(get(phase_only, "rebuild", Dict()), "start_values_copied", false),
                "user_defined_function_count" => get(get(phase_only, "rebuild", Dict()), "user_defined_function_count", nothing),
                "error" => get(phase_only, "error", nothing),
            ),
            "qualification" => Dict(
                "physical_endpoint_validation" => false,
                "solver_campaign_ready" => false,
            ),
        )
    catch error
        return Dict{String,Any}(
            "snapshot" => relative,
            "available" => false,
            "error" => sprint(showerror, error),
        )
    end
end

function run_campaign()
    root = abspath(get(ENV, "NLPDIAGNOSTICS_REAL_99BUS_ROOT", DEFAULT_ROOT))
    isdir(root) || error("real 99-bus benchmark root does not exist: $root")
    max_iter = parse(Int, get(ENV, "NLPDIAGNOSTICS_REAL_99BUS_MAX_ITER", "40"))
    angle = parse(Float64, get(ENV, "NLPDIAGNOSTICS_REAL_99BUS_PHASE_ANGLE", "0.01"))
    runs = [run_snapshot(root, relative; angle, max_iter) for relative in SELECTED_SNAPSHOTS]
    solved = [
        run for run in runs
        if get(get(run, "phase_only", Dict()), "solver_run_completed", false) === true
    ]
    locally_solved = [
        run for run in solved
        if get(get(run, "phase_only", Dict()), "termination_status", nothing) == "LOCALLY_SOLVED"
    ]
    return Dict(
        "schema_version" => "nlpdiagnostics-real-99bus-phase-only-campaign-v1",
        "source" => Dict(
            "root_basename" => basename(root),
            "selected_snapshot_count" => length(SELECTED_SNAPSHOTS),
            "max_iter" => max_iter,
            "phase_angle" => angle,
        ),
        "runs" => runs,
        "summary" => Dict(
            "run_count" => length(runs),
            "available_run_count" => count(run -> get(run, "available", false) === true, runs),
            "phase_only_solver_run_count" => length(solved),
            "phase_only_locally_solved_count" => length(locally_solved),
            "all_phase_only_runs_locally_solved" => length(locally_solved) == length(SELECTED_SNAPSHOTS),
            "solver_campaign_ready" => false,
            "physical_endpoint_validation" => false,
            "blocking_reason" => "local transformed-coordinate solves are attached and recorded, but physical endpoint recovery, KKT acceptance, and covariance validation are not yet implemented",
        ),
    )
end

output = abspath(get(ENV, "NLPDIAGNOSTICS_REAL_99BUS_CAMPAIGN_OUTPUT", joinpath(@__DIR__, "..", "work", "real-99bus-phase-only-campaign.json")))
mkpath(dirname(output))
write(output, JSON.json(run_campaign()))
println("wrote real 99-bus phase-only campaign report to $output")
