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
            "model" => model,
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

function native_baseline_comparison(reference, candidate; margin)
    reference_max = get(reference, "maximum_violation", nothing)
    candidate_max = get(candidate, "maximum_violation", nothing)
    comparable = reference_max isa Real && candidate_max isa Real &&
        isfinite(reference_max) && isfinite(candidate_max)
    threshold = comparable ? Float64(reference_max) + margin : nothing
    return Dict{String,Any}(
        "available" => comparable,
        "reference_maximum_violation" => comparable ? Float64(reference_max) : nothing,
        "candidate_maximum_violation" => comparable ? Float64(candidate_max) : nothing,
        "absolute_margin" => margin,
        "candidate_within_native_margin" => comparable &&
            Float64(candidate_max) <= threshold,
        "qualification" => Dict{String,Any}(
            "claim" => "candidate endpoint residual scale is no worse than the matched native endpoint by the declared margin",
            "absolute_physical_acceptance" => false,
        ),
    )
end

function physical_feasibility(context, evaluation; tolerance)
    map = NLPDiagnostics.bmopf_diagonal_scaling_map(context, evaluation)
    map["available"] || return Dict{String,Any}(
        "available" => false,
        "acceptance_passed" => nothing,
        "reason" => "the physical scaling map is unavailable",
    )
    quantities = unique(string.(map["constraint_quantities"]))
    report = NLPDiagnostics.bmopf_physical_feasibility_report(
        context,
        evaluation;
        quantity_absolute_tolerances=Dict(quantity => tolerance for quantity in quantities),
    )
    residuals = collect(values(get(report, "residuals", Dict())))
    return Dict{String,Any}(
        "available" => get(report, "available", false),
        "acceptance_passed" => get(report, "acceptance_passed", nothing),
        "tolerance_coverage_complete" => get(report, "tolerance_coverage_complete", false),
        "residual_count" => length(residuals),
        "passed_residual_count" => count(record -> get(record, "passed", false) === true, residuals),
        "maximum_violation" => isempty(residuals) ? nothing : maximum(
            get(record, "violation", 0.0) for record in residuals),
    )
end

function run_snapshot(root, relative; angle, max_iter, endpoint_tolerance, baseline_margin)
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
        reference_summary = Dict{String,Any}(
            "available" => get(reference, "available", false),
            "solver_run_completed" => get(reference, "solver_run_completed", false),
            "termination_status" => get(reference, "termination_status", nothing),
            "primal_status" => get(reference, "primal_status", nothing),
            "objective_value" => get(reference, "objective_value", nothing),
            "error" => get(reference, "error", nothing),
        )
        get(reference, "available", false) === true || return Dict{String,Any}(
            "snapshot" => relative,
            "available" => false,
            "reference" => reference_summary,
            "error" => "reference endpoint is unavailable",
        )
        reference_point = NLPDiagnostics.solver_result_point(
            reference["model"];
            label="real-99bus-reference-endpoint",
        )
        reference_evaluation = NLPDiagnostics.evaluate_numerical(
            JuMP.backend(reference["model"]), reference_point,
        )
        reference_feasibility = physical_feasibility(
            context,
            reference_evaluation;
            tolerance=endpoint_tolerance,
        )
        candidate_model = JuMP.Model(Ipopt.Optimizer)
        JuMP.set_optimizer_attribute(candidate_model, "max_iter", max_iter)
        phase_only = NLPDiagnostics.bmopf_phase_only_solve_model(
            context,
            evaluation;
            plan,
            optimizer_model=candidate_model,
            optimize=true,
        )
        endpoint = NLPDiagnostics.bmopf_phase_only_endpoint(
            context,
            evaluation;
            solved=phase_only,
            plan,
        )
        phase_only_feasibility = get(endpoint, "available", false) === true ?
            physical_feasibility(
                context,
                endpoint["endpoint_evaluation"];
                tolerance=endpoint_tolerance,
            ) : Dict{String,Any}(
                "available" => false,
                "acceptance_passed" => nothing,
                "reason" => "the source-coordinate phase-only endpoint was unavailable",
            )
        baseline_comparison = native_baseline_comparison(
            reference_feasibility,
            phase_only_feasibility;
            margin=baseline_margin,
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
            "reference" => reference_summary,
            "reference_physical_feasibility" => reference_feasibility,
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
                "endpoint_recovered" => get(endpoint, "available", false),
                "physical_feasibility" => phase_only_feasibility,
                "native_baseline_comparison" => baseline_comparison,
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
    endpoint_tolerance = parse(Float64, get(
        ENV, "NLPDIAGNOSTICS_REAL_99BUS_ENDPOINT_TOLERANCE", "1.0e-6",
    ))
    baseline_margin = parse(Float64, get(
        ENV, "NLPDIAGNOSTICS_REAL_99BUS_BASELINE_MARGIN", "1.0e-8",
    ))
    runs = [run_snapshot(
        root,
        relative;
        angle,
        max_iter,
        endpoint_tolerance,
        baseline_margin,
    ) for relative in SELECTED_SNAPSHOTS]
    solved = [
        run for run in runs
        if get(get(run, "phase_only", Dict()), "solver_run_completed", false) === true
    ]
    locally_solved = [
        run for run in solved
        if get(get(run, "phase_only", Dict()), "termination_status", nothing) == "LOCALLY_SOLVED"
    ]
    reference_physical = [
        run for run in runs
        if get(get(run, "reference_physical_feasibility", Dict()), "acceptance_passed", false) === true
    ]
    phase_only_physical = [
        run for run in runs
        if get(get(get(run, "phase_only", Dict()), "physical_feasibility", Dict()), "acceptance_passed", false) === true
    ]
    baseline_comparable = [
        run for run in runs
        if get(get(get(run, "phase_only", Dict()), "native_baseline_comparison", Dict()), "available", false) === true
    ]
    baseline_passed = [
        run for run in baseline_comparable
        if get(get(get(run, "phase_only", Dict()), "native_baseline_comparison", Dict()), "candidate_within_native_margin", false) === true
    ]
    return Dict(
        "schema_version" => "nlpdiagnostics-real-99bus-phase-only-campaign-v1",
        "source" => Dict(
            "root_basename" => basename(root),
            "selected_snapshot_count" => length(SELECTED_SNAPSHOTS),
            "max_iter" => max_iter,
            "phase_angle" => angle,
            "endpoint_tolerance" => endpoint_tolerance,
            "baseline_margin" => baseline_margin,
        ),
        "runs" => runs,
        "summary" => Dict(
            "run_count" => length(runs),
            "available_run_count" => count(run -> get(run, "available", false) === true, runs),
            "phase_only_solver_run_count" => length(solved),
            "phase_only_locally_solved_count" => length(locally_solved),
            "all_phase_only_runs_locally_solved" => length(locally_solved) == length(SELECTED_SNAPSHOTS),
            "reference_physical_endpoint_acceptance_count" => length(reference_physical),
            "phase_only_physical_endpoint_acceptance_count" => length(phase_only_physical),
            "native_baseline_comparison_count" => length(baseline_comparable),
            "native_baseline_comparison_pass_count" => length(baseline_passed),
            "all_phase_only_endpoints_within_native_margin" => length(baseline_passed) == length(SELECTED_SNAPSHOTS),
            "all_reference_physical_endpoints_accepted" => length(reference_physical) == length(SELECTED_SNAPSHOTS),
            "all_phase_only_physical_endpoints_accepted" => length(phase_only_physical) == length(SELECTED_SNAPSHOTS),
            "solver_campaign_ready" => false,
            "physical_endpoint_validation" => false,
            "blocking_reason" => "source-coordinate endpoint recovery is implemented, but transformed variable-domain sets, KKT acceptance, and physical covariance validation are not yet qualified",
        ),
    )
end

output = abspath(get(ENV, "NLPDIAGNOSTICS_REAL_99BUS_CAMPAIGN_OUTPUT", joinpath(@__DIR__, "..", "work", "real-99bus-phase-only-campaign.json")))
mkpath(dirname(output))
write(output, JSON.json(run_campaign()))
println("wrote real 99-bus phase-only campaign report to $output")
