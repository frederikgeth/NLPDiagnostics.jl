module IpoptExt

import Ipopt
import MathOptInterface as MOI
import NLPDiagnostics

function _get_or_nothing(model, attribute)
    try
        return MOI.get(model, attribute)
    catch
        return nothing
    end
end

function _ipopt_termination(raw_status, moi_status)
    raw_status === "Solve_Succeeded" && return :locally_optimal
    raw_status === "Solved_To_Acceptable_Level" && return :acceptable_solution
    raw_status === "Infeasible_Problem_Detected" && return :locally_infeasible
    raw_status === "Search_Direction_Becomes_Too_Small" && return :slow_progress
    raw_status === "Diverging_Iterates" && return :diverging_iterates
    raw_status === "User_Requested_Stop" && return :interrupted
    raw_status === "Feasible_Point_Found" && return :feasible_point
    raw_status === "Maximum_Iterations_Exceeded" && return :iteration_limit
    raw_status === "Restoration_Failed" && return :restoration_failed
    raw_status === "Error_In_Step_Computation" && return :numerical_failure
    raw_status in ("Maximum_CpuTime_Exceeded", "Maximum_WallTime_Exceeded") &&
        return :time_limit
    raw_status in ("Not_Enough_Degrees_Of_Freedom", "Invalid_Problem_Definition") &&
        return :invalid_model
    raw_status === "Invalid_Option" && return :invalid_option
    raw_status === "Invalid_Number_Detected" && return :invalid_number
    raw_status === "Insufficient_Memory" && return :memory_limit
    raw_status in ("Unrecoverable_Exception", "NonIpopt_Exception_Thrown", "Internal_Error") &&
        return :other_error
    moi_status == MOI.OPTIMAL && return :optimal
    moi_status == MOI.LOCALLY_SOLVED && return :locally_optimal
    moi_status == MOI.ALMOST_LOCALLY_SOLVED && return :acceptable_solution
    moi_status == MOI.LOCALLY_INFEASIBLE && return :locally_infeasible
    moi_status == MOI.ITERATION_LIMIT && return :iteration_limit
    moi_status == MOI.TIME_LIMIT && return :time_limit
    moi_status == MOI.NUMERICAL_ERROR && return :numerical_failure
    moi_status == MOI.INVALID_MODEL && return :invalid_model
    moi_status == MOI.INVALID_OPTION && return :invalid_option
    moi_status == MOI.MEMORY_LIMIT && return :memory_limit
    moi_status == MOI.INTERRUPTED && return :interrupted
    return :unknown
end

"""
    NLPDiagnostics.solver_postmortem(model)

Extract public MOI result attributes from a completed Ipopt optimizer and map
Ipopt's raw application status into `SolverPostmortem`. Ipopt does not expose
its final primal, dual, or complementarity residuals through stable public MOI
attributes, so this adapter deliberately leaves those fields empty rather than
reconstructing or guessing them. `Restoration_Failed` is the only raw status
that establishes a failed restoration outcome.
"""
function _is_ipopt_optimizer(model)
    extension = Base.get_extension(Ipopt, :IpoptMathOptInterfaceExt)
    return !isnothing(extension) &&
           isdefined(extension, :Optimizer) &&
           model isa getfield(extension, :Optimizer)
end

function _ipopt_postmortem(model)
    raw_status = _get_or_nothing(model, MOI.RawStatusString())
    raw_status = isnothing(raw_status) ? nothing : String(raw_status)
    moi_status = _get_or_nothing(model, MOI.TerminationStatus())
    iterations = _get_or_nothing(model, MOI.BarrierIterations())
    objective_value = _get_or_nothing(model, MOI.ObjectiveValue())
    solve_time = _get_or_nothing(model, MOI.SolveTimeSec())
    primal_status = _get_or_nothing(model, MOI.PrimalStatus())
    dual_status = _get_or_nothing(model, MOI.DualStatus())
    result_count = _get_or_nothing(model, MOI.ResultCount())
    metadata = Dict{String,String}()
    for (key, value) in (
        "moi_termination_status" => moi_status,
        "moi_primal_status" => primal_status,
        "moi_dual_status" => dual_status,
        "result_count" => result_count,
        "solve_time_seconds" => solve_time,
    )
        isnothing(value) || (metadata[key] = string(value))
    end
    return NLPDiagnostics.SolverPostmortem(
        "Ipopt",
        _ipopt_termination(raw_status, moi_status);
        raw_status = raw_status,
        iterations = iterations isa Integer ? iterations : nothing,
        objective_value = objective_value isa Real ? objective_value : nothing,
        restoration_attempted = raw_status == "Restoration_Failed",
        restoration_succeeded = raw_status == "Restoration_Failed" ? false : nothing,
        metadata = metadata,
    )
end

"""
    NLPDiagnostics.ipopt_iteration_trace_capture(model; capture_points=false)

Install Ipopt's public `CallbackFunction` intermediate callback and return an
`IterationTraceCapture` that receives solver iteration metrics. The callback
uses only public MOI attributes. With `capture_points=true`, it additionally
copies the callback primal vector through `CallbackVariablePrimal`; this is
explicitly labeled as a captured point and is never reconstructed from log
text. Call `iteration_trace(capture)` after `optimize!`.
"""
function NLPDiagnostics.ipopt_iteration_trace_capture(
    model::MOI.ModelLike;
    capture::NLPDiagnostics.IterationTraceCapture = NLPDiagnostics.IterationTraceCapture(),
    capture_points::Bool = false,
)
    variables = capture_points ? MOI.get(model, MOI.ListOfVariableIndices()) : MOI.VariableIndex[]
    callback = function(
        alg_mod::Cint,
        iter_count::Cint,
        obj_value::Float64,
        inf_pr::Float64,
        inf_du::Float64,
        mu::Float64,
        d_norm::Float64,
        regularization_size::Float64,
        alpha_du::Float64,
        alpha_pr::Float64,
        ls_trials::Cint,
    )
        record = NLPDiagnostics.SolverIterationRecord(
            :ipopt_callback,
            0,
            Int(iter_count),
            alg_mod == 0 ? :regular : :restoration,
            obj_value,
            inf_pr,
            inf_du,
            nothing,
            alpha_pr,
            "",
            barrier_parameter = mu,
            step_norm = d_norm,
            regularization_size = regularization_size,
            dual_step = alpha_du,
            line_search_trials = Int(ls_trials),
            semantics = NLPDiagnostics.SolverIterationMetricSemantics(
                objective = NLPDiagnostics.OriginalModelCoordinates,
                primal_infeasibility = NLPDiagnostics.SolverScaledCoordinates,
                dual_infeasibility = NLPDiagnostics.SolverScaledCoordinates,
                barrier_parameter = NLPDiagnostics.SolverDefinedCoordinates,
            ),
        )
        point = if capture_points
            values = [MOI.get(model, MOI.CallbackVariablePrimal(model), variable)
                      for variable in variables]
            NLPDiagnostics.EvaluationPoint(variables, values;
                label = "ipopt-callback-iteration-$(Int(iter_count))",
                provenance = NLPDiagnostics.EvaluationPointProvenance(
                    NLPDiagnostics.SolverIteratePoint;
                    source = "Ipopt.CallbackVariablePrimal",
                    complete = true,
                    metadata = Dict("iteration" => Int(iter_count)),
                ),
            )
        else
            nothing
        end
        NLPDiagnostics.capture_iteration!(capture, record; point = point)
        return true
    end
    MOI.set(model, Ipopt.CallbackFunction(), callback)
    return capture
end

"""
    NLPDiagnostics.ipopt_optimize_with_iteration_trace!(model; capture_points=false)

Install the public Ipopt callback, call `MOI.optimize!`, and return the frozen
`SolverIterationTrace`. Supply `capture_points=true` only when callback primal
coordinates are needed; the default keeps the trace metric-only.
"""
function NLPDiagnostics.ipopt_optimize_with_iteration_trace!(
    model::MOI.ModelLike;
    capture::NLPDiagnostics.IterationTraceCapture = NLPDiagnostics.IterationTraceCapture(),
    capture_points::Bool = false,
)
    NLPDiagnostics.ipopt_iteration_trace_capture(model;
        capture, capture_points,
    )
    MOI.optimize!(model)
    return NLPDiagnostics.iteration_trace(capture)
end

"""
    NLPDiagnostics.ipopt_profile_with_iteration_trace!(model; kwargs...)

Solve through Ipopt's public callback, then build a solver-result profile that
retains the captured trace and serializes both artifacts together.
"""
function NLPDiagnostics.ipopt_profile_with_iteration_trace!(
    model::MOI.ModelLike;
    capture::NLPDiagnostics.IterationTraceCapture = NLPDiagnostics.IterationTraceCapture(),
    capture_points::Bool = false,
    kwargs...,
)
    return NLPDiagnostics.profile_solver_with_iteration_trace!(
        model,
        current -> NLPDiagnostics.ipopt_optimize_with_iteration_trace!(current;
            capture, capture_points,
        );
        kwargs...,
    )
end

function __init__()
    NLPDiagnostics.register_solver_postmortem_adapter!(
        :ipopt,
        _is_ipopt_optimizer,
        _ipopt_postmortem,
    )
    return
end

end
