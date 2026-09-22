using Ipopt
using JuMP
using NLPDiagnostics
import MathOptInterface as MOI

const CONTROLLED_SCALING_START = (x = 2.0, y = 0.5)

function _controlled_scaling_model(row_multiplier::Real)
    model = Model(Ipopt.Optimizer)
    set_silent(model)

    # Hold the solver policy fixed and expose the model-level intervention.
    set_optimizer_attribute(model, "nlp_scaling_method", "none")
    set_optimizer_attribute(model, "tol", 1.0e-9)
    set_optimizer_attribute(model, "max_iter", 100)

    @variable(model, x, start = CONTROLLED_SCALING_START.x)
    @variable(model, y, start = CONTROLLED_SCALING_START.y)
    @objective(model, Min, (x - 1)^2 + (y - 1)^2)
    @constraint(model, row_multiplier * (x * y - 1) == 0)
    @constraint(model, x - y == 0)
    return model, x, y
end

function _run_controlled_scaling_case(label::Symbol, row_multiplier::Real)
    model, x, y = _controlled_scaling_model(row_multiplier)
    moi_model = backend(model)
    point = evaluation_point(
        moi_model,
        [CONTROLLED_SCALING_START.x, CONTROLLED_SCALING_START.y];
        label = "shared-physical-start",
    )
    evaluation = evaluate_numerical(moi_model, point)
    scale_summary = jacobian_scale_summary(evaluation)
    numerical_report = analyze_numerical(
        moi_model,
        evaluation;
        scale_ratio_threshold = 1.0e6,
    )

    run = ipopt_profile_with_iteration_trace!(model; capture_points = true)
    trace_summary = solver_iteration_summary(run.trace.records)
    trace_summary === nothing && error("Ipopt returned no callback trace records")

    endpoint = (x = value(x), y = value(y))
    return (
        label = label,
        row_multiplier = Float64(row_multiplier),
        start = CONTROLLED_SCALING_START,
        start_physical_residuals = (
            product = CONTROLLED_SCALING_START.x * CONTROLLED_SCALING_START.y - 1,
            equality = CONTROLLED_SCALING_START.x - CONTROLLED_SCALING_START.y,
        ),
        scale_summary = scale_summary,
        numerical_report = numerical_report,
        run = run,
        trace_summary = trace_summary,
        trace_data = iteration_trace_data(run.trace),
        termination = termination_status(model),
        primal = primal_status(model),
        endpoint = endpoint,
        endpoint_physical_residuals = (
            product = endpoint.x * endpoint.y - 1,
            equality = endpoint.x - endpoint.y,
        ),
        objective = objective_value(model),
        total_line_search_trials = sum(
            something(record.line_search_trials, 0) for record in run.trace.records
        ),
    )
end

"""
    run_controlled_scaling_solver_trace()

Compare two algebraically equivalent NLPs from the same start and under the
same Ipopt policy. The only intervention divides one equality row by `1e8`.
Both native callback traces and independently evaluated endpoint diagnostics
are retained.
"""
function run_controlled_scaling_solver_trace()
    ill_scaled = _run_controlled_scaling_case(:ill_scaled, 1.0e8)
    normalized = _run_controlled_scaling_case(:normalized, 1.0)

    @assert :large_jacobian_row_scale_spread in
            Set(finding.code for finding in ill_scaled.numerical_report)
    @assert :large_jacobian_row_scale_spread ∉
            Set(finding.code for finding in normalized.numerical_report)
    @assert ill_scaled.scale_summary.row_scale_ratio > 1.0e8
    @assert normalized.scale_summary.row_scale_ratio <= 2.0
    @assert !isempty(ill_scaled.run.trace.records)
    @assert !isempty(normalized.run.trace.records)
    @assert length(ill_scaled.run.trace.bindings) ==
            length(ill_scaled.run.trace.records)
    @assert length(normalized.run.trace.bindings) ==
            length(normalized.run.trace.records)
    @assert ill_scaled.termination in (MOI.LOCALLY_SOLVED, MOI.OPTIMAL)
    @assert normalized.termination in (MOI.LOCALLY_SOLVED, MOI.OPTIMAL)
    @assert ill_scaled.primal == MOI.FEASIBLE_POINT
    @assert normalized.primal == MOI.FEASIBLE_POINT
    @assert maximum(abs, (
        ill_scaled.endpoint.x - normalized.endpoint.x,
        ill_scaled.endpoint.y - normalized.endpoint.y,
    )) < 1.0e-7

    return (
        ill_scaled = ill_scaled,
        normalized = normalized,
        maximum_endpoint_difference = maximum(abs, (
            ill_scaled.endpoint.x - normalized.endpoint.x,
            ill_scaled.endpoint.y - normalized.endpoint.y,
        )),
        objective_difference = abs(ill_scaled.objective - normalized.objective),
    )
end

if abspath(PROGRAM_FILE) == @__FILE__
    result = run_controlled_scaling_solver_trace()
    for case in (result.ill_scaled, result.normalized)
        println((
            case = case.label,
            row_scale_ratio = case.scale_summary.row_scale_ratio,
            trace_records = case.trace_summary.record_count,
            line_search_trials = case.total_line_search_trials,
            endpoint = case.endpoint,
        ))
    end
end
