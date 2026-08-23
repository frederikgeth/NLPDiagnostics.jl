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

mutable struct _MadNLPTraceCallback <: MadNLP.AbstractUserCallback
    capture::NLPDiagnostics.IterationTraceCapture
end

function (callback::_MadNLPTraceCallback)(solver, mode::MadNLP.AbstractUserCallbackStatus)
    counters = MadNLP.get_cnt(solver)
    record = NLPDiagnostics.SolverIterationRecord(
        :madnlp_callback,
        0,
        Int(counters.k),
        mode isa MadNLP.UserCallbackRestore ? :restoration :
        mode isa MadNLP.UserCallbackRobust ? :robust : :regular,
        # MadNLP's callback getter exposes the internally scaled objective;
        # unpacking through its public callback accessor keeps the trace in
        # model objective units, matching MOI ObjectiveValue and Ipopt traces.
        Float64(MadNLP.unpack_obj(
            MadNLP.get_cb(solver), MadNLP.get_obj_val(solver),
        )),
        Float64(MadNLP.get_inf_pr(solver)),
        Float64(MadNLP.get_inf_du(solver)),
        Float64(MadNLP.get_inf_compl(solver)),
        Float64(MadNLP.get_alpha(solver)),
        "",
        barrier_parameter = Float64(MadNLP.get_mu(solver)),
        regularization_size = Float64(MadNLP.get_del_w(solver)),
        dual_step = Float64(MadNLP.get_alpha_z(solver)),
        linear_telemetry = Dict{String,Any}(
            "source" => "MadNLP.get_cnt callback counters",
            "api_stability" => "package-qualified callback API",
            "temporal_alignment" =>
                "cumulative work completed before this callback observation; the line-search counter may describe the preceding step",
            "linear_solver_time_seconds_cumulative" =>
                Float64(counters.linear_solver_time),
            "factorization_count_cumulative" =>
                Int(counters.factorization_cnt),
            "backsolve_count_cumulative" => Int(counters.backsolve_cnt),
            "iterative_refinement_count_current" => Int(counters.ir),
            "line_search_counter_at_callback" => Int(counters.l),
            "objective_evaluation_count_cumulative" => Int(counters.obj_cnt),
            "objective_gradient_evaluation_count_cumulative" =>
                Int(counters.obj_grad_cnt),
            "constraint_evaluation_count_cumulative" => Int(counters.con_cnt),
            "jacobian_evaluation_count_cumulative" => Int(counters.con_jac_cnt),
            "hessian_evaluation_count_cumulative" => Int(counters.lag_hess_cnt),
        ),
        semantics = NLPDiagnostics.SolverIterationMetricSemantics(
            objective = NLPDiagnostics.OriginalModelCoordinates,
            primal_infeasibility = NLPDiagnostics.SolverDefinedCoordinates,
            dual_infeasibility = NLPDiagnostics.SolverDefinedCoordinates,
            complementarity = NLPDiagnostics.SolverDefinedCoordinates,
            barrier_parameter = NLPDiagnostics.SolverDefinedCoordinates,
        ),
    )
    NLPDiagnostics.capture_iteration!(callback.capture, record)
    return true
end

"""
    NLPDiagnostics.madnlp_iteration_trace_callback(; capture=nothing)

Construct a MadNLP `AbstractUserCallback` for the public
`intermediate_callback` option and return its `IterationTraceCapture`. Pass the
callback object to `MadNLP.MadNLPSolver(...; intermediate_callback=callback)`
or the corresponding MOI raw optimizer attribute. MadNLP exposes solver
metrics, but not a stable MOI callback primal-vector interface, so this adapter
captures iteration metrics only and never fabricates `EvaluationPoint`s.
"""
function NLPDiagnostics.madnlp_iteration_trace_callback(
    ; capture::NLPDiagnostics.IterationTraceCapture = NLPDiagnostics.IterationTraceCapture(),
)
    callback = _MadNLPTraceCallback(capture)
    return callback, capture
end

"""Explain the current public MadNLP callback-coordinate boundary."""
function NLPDiagnostics.madnlp_primal_capture_capability()
    report = NLPDiagnostics.DiagnosticReport()
    report.metadata[:solver] = "MadNLP"
    report.metadata[:metric_callback] = "available"
    report.metadata[:primal_callback] = "unavailable"
    typed_reason = NLPDiagnostics.unavailable_reason(
        (
            available = false,
            reason = "MadNLP's public intermediate callback exposes no stable public primal-vector accessor",
        );
        code = :madnlp_primal_capture_unavailable,
        category = :capability,
        stage = :madnlp_primal_capture,
    )
    report.metadata[:primal_callback_reason] = typed_reason.message
    report.metadata[:primal_callback_unavailable_reason] = typed_reason.message
    push!(report, NLPDiagnostics.Finding(:madnlp_primal_capture_unavailable;
        severity = NLPDiagnostics.SeverityInfo,
        domain = NLPDiagnostics.RepresentationalIssue,
        basis = NLPDiagnostics.StructuralProof,
        confidence = NLPDiagnostics.ConfidenceCertain,
        observation = "MadNLP's public intermediate callback exposes iteration metrics but no stable public primal-vector accessor.",
        why_it_matters = "Current-law and Jacobian diagnostics require model-coordinate values; reconstructing them from objective or infeasibility metrics would create unsupported evidence.",
        suggested_actions = ["Supply explicit EvaluationPoint bindings or saved result dictionaries for coordinate diagnostics.",
                             "If MadNLP publishes a supported callback primal accessor, add it at this extension boundary before enabling automatic capture."],
    ))
    return report
end

"""
    NLPDiagnostics.madnlp_optimize_with_iteration_trace!(model)

Install MadNLP's public `intermediate_callback`, call `MOI.optimize!`, and
return a frozen metric-only `SolverIterationTrace`.
"""
function NLPDiagnostics.madnlp_optimize_with_iteration_trace!(
    model::MOI.ModelLike;
    capture::NLPDiagnostics.IterationTraceCapture = NLPDiagnostics.IterationTraceCapture(),
)
    callback, capture = NLPDiagnostics.madnlp_iteration_trace_callback(; capture)
    MOI.set(model, MOI.RawOptimizerAttribute("intermediate_callback"), callback)
    MOI.optimize!(model)
    return NLPDiagnostics.iteration_trace(capture)
end

"""
    NLPDiagnostics.madnlp_profile_with_iteration_trace!(model; kwargs...)

Solve through MadNLP's public intermediate callback, then build a
solver-result profile retaining the metric-only trace.
"""
function NLPDiagnostics.madnlp_profile_with_iteration_trace!(
    model::MOI.ModelLike;
    capture::NLPDiagnostics.IterationTraceCapture = NLPDiagnostics.IterationTraceCapture(),
    kwargs...,
)
    return NLPDiagnostics.profile_solver_with_iteration_trace!(
        model,
        current -> NLPDiagnostics.madnlp_optimize_with_iteration_trace!(current;
            capture,
        );
        kwargs...,
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
