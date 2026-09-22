using Ipopt
using JuMP
using NLPDiagnostics
import MathOptInterface as MOI

const LINE_SUSCEPTANCE = 10.0
const LOAD_P = 1.0
const LOAD_Q = 0.2

function build_polar_model()
    model = Model(Ipopt.Optimizer)
    set_silent(model)
    set_optimizer_attribute(model, "sb", "yes")
    @variable(model, 0.5 <= vm <= 1.2, start = 1.0)
    @variable(model, -pi / 2 <= va <= pi / 2, start = -0.1)
    @NLconstraint(
        model,
        p_balance,
        LINE_SUSCEPTANCE * vm * sin(va) == -LOAD_P,
    )
    @NLconstraint(
        model,
        q_balance,
        LINE_SUSCEPTANCE * (vm^2 - vm * cos(va)) == -LOAD_Q,
    )
    @NLobjective(model, Min, vm^2 - 2.0 * vm * cos(va) + 1.0)
    return (; model, vm, va)
end

function build_rectangular_model()
    model = Model(Ipopt.Optimizer)
    set_silent(model)
    set_optimizer_attribute(model, "sb", "yes")
    @variable(model, 0.0 <= vr <= 1.2, start = cos(-0.1))
    @variable(model, -1.2 <= vi <= 1.2, start = sin(-0.1))
    @constraint(model, p_balance, LINE_SUSCEPTANCE * vi == -LOAD_P)
    @constraint(
        model,
        q_balance,
        LINE_SUSCEPTANCE * (vr^2 - vr + vi^2) == -LOAD_Q,
    )
    @constraint(model, voltage_min, vr^2 + vi^2 >= 0.25)
    @constraint(model, voltage_max, vr^2 + vi^2 <= 1.44)
    @objective(model, Min, (vr - 1.0)^2 + vi^2)
    return (; model, vr, vi)
end

polar_state(formulation) = (
    vr = value(formulation.vm) * cos(value(formulation.va)),
    vi = value(formulation.vm) * sin(value(formulation.va)),
)

rectangular_state(formulation) = (
    vr = value(formulation.vr),
    vi = value(formulation.vi),
)

function physical_balance_residual(state)
    return (
        active = LINE_SUSCEPTANCE * state.vi + LOAD_P,
        reactive = LINE_SUSCEPTANCE *
            (state.vr^2 - state.vr + state.vi^2) + LOAD_Q,
    )
end

function solve_and_diagnose(formulation, label)
    optimize!(formulation.model)
    result = analyze_solver_result(formulation.model; label)
    return (
        termination = termination_status(formulation.model),
        primal = primal_status(formulation.model),
        objective = objective_value(formulation.model),
        result,
        error_count = length(findings(result.report; severity = SeverityError)),
    )
end

function run_controlled_opf_comparison()
    polar = build_polar_model()
    rectangular = build_rectangular_model()
    polar_run = solve_and_diagnose(polar, "polar two-bus result")
    rectangular_run = solve_and_diagnose(
        rectangular,
        "rectangular two-bus result",
    )
    polar_physical = polar_state(polar)
    rectangular_physical = rectangular_state(rectangular)
    return (
        polar = polar_run,
        rectangular = rectangular_run,
        polar_state = polar_physical,
        rectangular_state = rectangular_physical,
        polar_residual = physical_balance_residual(polar_physical),
        rectangular_residual = physical_balance_residual(rectangular_physical),
        maximum_state_difference = max(
            abs(polar_physical.vr - rectangular_physical.vr),
            abs(polar_physical.vi - rectangular_physical.vi),
        ),
        objective_difference = abs(polar_run.objective - rectangular_run.objective),
    )
end

if abspath(PROGRAM_FILE) == @__FILE__
    comparison = run_controlled_opf_comparison()
    @assert comparison.polar.termination in (MOI.LOCALLY_SOLVED, MOI.OPTIMAL)
    @assert comparison.rectangular.termination in (MOI.LOCALLY_SOLVED, MOI.OPTIMAL)
    @assert comparison.polar.primal == MOI.FEASIBLE_POINT
    @assert comparison.rectangular.primal == MOI.FEASIBLE_POINT
    @assert comparison.polar.error_count == 0
    @assert comparison.rectangular.error_count == 0
    @assert comparison.maximum_state_difference < 1.0e-8
    @assert comparison.objective_difference < 1.0e-8
    display((
        polar_state = comparison.polar_state,
        rectangular_state = comparison.rectangular_state,
        maximum_state_difference = comparison.maximum_state_difference,
    ))
end
