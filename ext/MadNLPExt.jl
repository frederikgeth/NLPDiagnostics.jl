module MadNLPExt

import MadNLP
import MathOptInterface as MOI
import NLPDiagnostics

function _get_or_nothing(model, attribute)
    try
        return MOI.get(model, attribute)
    catch
        return nothing
    end
end

function _madnlp_termination(raw_status, moi_status)
    if !isnothing(raw_status)
        startswith(raw_status, "Optimal Solution Found") && return :locally_optimal
        startswith(raw_status, "Solved To Acceptable Level") &&
            return :acceptable_solution
        startswith(raw_status, "Search Direction") && return :slow_progress
        startswith(raw_status, "Iterates diverging") && return :diverging_iterates
        startswith(raw_status, "Maximum Number of Iterations") &&
            return :iteration_limit
        startswith(raw_status, "Maximum wall-clock Time") && return :time_limit
        raw_status == "Restoration Failed" && return :restoration_failed
        occursin("local infeasibility", raw_status) && return :locally_infeasible
        startswith(raw_status, "Invalid number") && return :invalid_number
        startswith(raw_status, "Error in step computation") &&
            return :numerical_failure
        startswith(raw_status, "Problem has too few degrees of freedom") &&
            return :invalid_model
        startswith(raw_status, "Stopping optimization") && return :interrupted
        startswith(raw_status, "Internal Error") && return :other_error
    end
    moi_status == MOI.OPTIMAL && return :optimal
    moi_status == MOI.LOCALLY_SOLVED && return :locally_optimal
    moi_status == MOI.ALMOST_LOCALLY_SOLVED && return :acceptable_solution
    moi_status == MOI.LOCALLY_INFEASIBLE && return :locally_infeasible
    moi_status == MOI.ITERATION_LIMIT && return :iteration_limit
    moi_status == MOI.TIME_LIMIT && return :time_limit
    moi_status == MOI.SLOW_PROGRESS && return :slow_progress
    moi_status == MOI.NUMERICAL_ERROR && return :numerical_failure
    moi_status == MOI.INVALID_MODEL && return :invalid_model
    moi_status == MOI.INTERRUPTED && return :interrupted
    return :unknown
end

function _is_madnlp_optimizer(model)
    extension = Base.get_extension(MadNLP, :MadNLPMOI)
    return !isnothing(extension) &&
           isdefined(extension, :Optimizer) &&
           model isa getfield(extension, :Optimizer)
end

"""
Extract a `SolverPostmortem` from a MadNLP MOI optimizer.

The adapter uses MadNLP's public MOI status, iteration, timing, and objective
attributes and retains the raw status string. It deliberately does not inspect
MadNLP optimizer internals for residuals or restoration history. A raw
`Restoration Failed` result is the only explicit unsuccessful-restoration
observation.
"""
function _madnlp_postmortem(model)
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
        "MadNLP",
        _madnlp_termination(raw_status, moi_status);
        raw_status = raw_status,
        iterations = iterations isa Integer ? iterations : nothing,
        objective_value = objective_value isa Real ? objective_value : nothing,
        restoration_attempted = raw_status == "Restoration Failed",
        restoration_succeeded = raw_status == "Restoration Failed" ? false : nothing,
        metadata = metadata,
    )
end

function __init__()
    NLPDiagnostics.register_solver_postmortem_adapter!(
        :madnlp,
        _is_madnlp_optimizer,
        _madnlp_postmortem,
    )
    return
end

end
