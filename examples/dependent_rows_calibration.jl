using JuMP
using NLPDiagnostics
using NLPDiagnostics.Advanced

function _calibration_row(evaluation, name)
    matches = findall(source -> source.name == name,
        evaluation.constraint_sources)
    @assert length(matches) == 1
    return only(matches)
end

function run_dependent_rows_calibration()
    curved = Model()
    @variable(curved, x)
    @variable(curved, y)
    @constraint(curved, anchor, x + y == 1)
    @constraint(curved, quadratic, x^2 == 1)

    function localize_curved(values, label)
        point = evaluation_point(curved, values; label)
        evaluation = evaluate_numerical(curved, point)
        rows = [_calibration_row(evaluation, "anchor"),
            _calibration_row(evaluation, "quadratic")]
        result = dependent_row_localization(evaluation; rows,
            scaling = :none, relative_tolerance = 0.0,
            absolute_tolerance = 1.0e-10,
            provenance = :cross_point_calibration)
        return (; evaluation, rows, result)
    end

    stationary = localize_curved([0.0, 1.0], "stationary, infeasible")
    feasible = localize_curved([1.0, 0.0], "feasible solution")
    @assert stationary.result.dependent === true
    @assert feasible.result.dependent === false
    @assert stationary.result.rows == [stationary.rows[2]]

    active_model = Model()
    @variable(active_model, u)
    @variable(active_model, v)
    @constraint(active_model, balance, u + v == 0)
    @constraint(active_model, lower_u, u >= 0)
    @constraint(active_model, lower_v, v >= 0)
    @constraint(active_model, loose_cap, u + v <= 2)
    active_point = evaluation_point(active_model, [0.0, 0.0];
        label = "feasible active-set point")
    active_evaluation = evaluate_numerical(active_model, active_point)
    row(name) = _calibration_row(active_evaluation, name)
    active_rows = [row("balance"), row("lower_u"), row("lower_v")]
    active = dependent_row_localization(active_evaluation; rows = active_rows,
        scaling = :none, relative_tolerance = 0.0,
        absolute_tolerance = 1.0e-10,
        provenance = :active_set_calibration)
    inactive_pair = dependent_row_localization(active_evaluation;
        rows = [row("balance"), row("loose_cap")],
        scaling = :none, relative_tolerance = 0.0,
        absolute_tolerance = 1.0e-10,
        provenance = :inactive_row_control)
    @assert active.irreducible_under_policy
    @assert Set(active.rows) == Set(active_rows)
    @assert inactive_pair.irreducible_under_policy

    return (; stationary, feasible, active_evaluation, active_rows,
        active, inactive_pair)
end

if abspath(PROGRAM_FILE) == @__FILE__
    results = run_dependent_rows_calibration()
    println((stationary = dependent_row_localization_data(
        results.stationary.result),
        feasible = dependent_row_localization_data(results.feasible.result),
        active = dependent_row_localization_data(results.active)))
end
