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

function __init__()
    NLPDiagnostics.register_solver_postmortem_adapter!(
        :ipopt,
        _is_ipopt_optimizer,
        _ipopt_postmortem,
    )
    return
end

end
