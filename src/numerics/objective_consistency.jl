function _objective_sense_symbol(model::MOI.ModelLike)
    sense = try
        MOI.get(model, MOI.ObjectiveSense())
    catch
        return :unknown
    end
    return sense == MOI.MIN_SENSE ? :minimize :
           sense == MOI.MAX_SENSE ? :maximize :
           sense == MOI.FEASIBILITY_SENSE ? :feasibility : :unknown
end

function _objective_result_status(model, attribute, fallback::AbstractString)
    return try
        string(MOI.get(model, attribute))
    catch
        String(fallback)
    end
end

function _finite_objective_value(value, ::Type{T}) where {T<:AbstractFloat}
    value isa Real || return nothing
    converted = try
        convert(T, value)
    catch
        return nothing
    end
    return isfinite(converted) ? converted : nothing
end

_affine_gap_function(function_value) =
    function_value isa MOI.VariableIndex ||
    function_value isa MOI.ScalarAffineFunction

_affine_gap_set(set_value) =
    set_value isa MOI.EqualTo ||
    set_value isa MOI.LessThan ||
    set_value isa MOI.GreaterThan ||
    set_value isa MOI.Interval

function _affine_gap_model(model_snapshot::ModelSnapshot)
    objective = model_snapshot.objective
    isnothing(objective) && return false,
        "the model has no ordinary scalar objective available for affine dual analysis"
    _affine_gap_function(objective.function_value) || return false,
        "the objective is not scalar affine"
    for constraint in model_snapshot.constraints
        _affine_gap_function(constraint.function_value) || return false,
            "one or more constraint functions are not scalar affine"
        _affine_gap_set(constraint.set_value) || return false,
            "one or more constraints lack supported continuous scalar-bound dual semantics"
    end
    isempty(model_snapshot.opaque_sources) || return false,
        "the model contains an opaque nonlinear source"
    return true, nothing
end

function _gap_failure_reason(
    model::MOI.ModelLike,
    evaluation::NumericalEvaluation{T},
    snapshot_value::Union{Nothing,SolverDualSnapshot{T}},
    result_index::Int,
    objective_sense::Symbol,
    feasibility_tolerance::T,
    stationarity_tolerance::T,
    dual_tolerance::T,
) where {T<:AbstractFloat}
    supported, reason = _affine_gap_model(snapshot(model))
    supported || return reason, nothing, nothing, nothing, nothing, nothing
    snapshot_value isa SolverDualSnapshot{T} || return (
        "no row-aligned public solver-dual snapshot was supplied",
        nothing, nothing, nothing, nothing, nothing,
    )
    snapshot_value.available || return (
        "the public solver-dual snapshot is unavailable: $(something(snapshot_value.reason, "unknown reason"))",
        nothing, nothing, nothing, nothing, nothing,
    )
    snapshot_value.result_index == result_index || return (
        "the public solver-dual snapshot belongs to a different result index",
        nothing, nothing, nothing, nothing, nothing,
    )
    snapshot_point = snapshot_value.point
    snapshot_point isa EvaluationPoint{T} || return (
        "the public solver-dual snapshot has no recorded endpoint",
        nothing, nothing, nothing, nothing, nothing,
    )
    same_point = snapshot_point.variables == evaluation.point.variables &&
        isequal(snapshot_point.values, evaluation.point.values)
    same_point || return (
        "the public solver-dual snapshot belongs to a different evaluation point",
        nothing, nothing, nothing, nothing, nothing,
    )
    expected_objective_weight = objective_sense == :minimize ? one(T) :
        objective_sense == :maximize ? -one(T) : nothing
    snapshot_value.objective_weight == expected_objective_weight || return (
        "the public solver-dual snapshot has an objective weight inconsistent with the model sense",
        nothing, nothing, nothing, nothing, nothing,
    )
    snapshot_value.side_decomposition_complete || return (
        "one or more affine rows lack scalar-side dual semantics",
        nothing, nothing, nothing, nothing, nothing,
    )

    feasibility = constraint_feasibility_summary(
        model,
        evaluation;
        feasibility_tolerance,
        active_tolerance = feasibility_tolerance,
    )
    feasibility.complete || return (
        "primal feasibility could not be evaluated for every affine row",
        nothing, nothing, nothing, nothing, nothing,
    )
    violations = T[
        activity.feasibility_violation for activity in feasibility.activities
        if activity.feasibility_violation isa T
    ]
    length(violations) == length(feasibility.activities) || return (
        "one or more affine rows have no finite primal-feasibility violation",
        nothing, nothing, nothing, nothing, nothing,
    )
    maximum_primal_violation = maximum(violations; init = zero(T))
    primal_feasible = maximum_primal_violation <= feasibility_tolerance
    primal_feasible || return (
        "the selected point is not primal feasible under the recorded tolerance",
        primal_feasible, nothing, maximum_primal_violation, nothing, nothing,
    )

    stationarity = _dual_stationarity_vector(
        evaluation,
        snapshot_value.objective_weight,
        snapshot_value.row_multipliers,
    )
    isnothing(stationarity) && return (
        "stationarity cannot be evaluated from the retained derivatives and multipliers",
        primal_feasible, nothing, maximum_primal_violation, nothing, nothing,
    )
    maximum_stationarity_residual = maximum(abs, stationarity; init = zero(T))
    inequality_sides = [
        side for side in snapshot_value.sides if side.side != :equality
    ]
    maximum_dual_violation = maximum(
        (max(-side.multiplier, zero(T)) for side in inequality_sides);
        init = zero(T),
    )
    dual_feasible = maximum_stationarity_residual <= stationarity_tolerance &&
        maximum_dual_violation <= dual_tolerance
    dual_feasible || return (
        "the supplied multiplier representative is not dual feasible under the recorded stationarity and sign tolerances",
        primal_feasible,
        dual_feasible,
        maximum_primal_violation,
        maximum_stationarity_residual,
        maximum_dual_violation,
    )
    return nothing,
        primal_feasible,
        dual_feasible,
        maximum_primal_violation,
        maximum_stationarity_residual,
        maximum_dual_violation
end

function _affine_dual_objective(
    primal_objective::T,
    objective_sense::Symbol,
    snapshot_value::SolverDualSnapshot{T},
) where {T<:AbstractFloat}
    transformed = snapshot_value.objective_weight * primal_objective
    for side in snapshot_value.sides
        side.value isa T && side.bound isa T || return nothing
        if side.side == :lower
            transformed += side.multiplier * (side.bound - side.value)
        elseif side.side == :upper
            transformed += side.multiplier * (side.value - side.bound)
        elseif side.side == :equality
            transformed += side.multiplier * (side.value - side.bound)
        else
            return nothing
        end
    end
    return objective_sense == :maximize ? -transformed : transformed
end

function _objective_consistency_tolerance(
    ::Type{T}, absolute_tolerance, relative_tolerance, name,
) where {T<:AbstractFloat}
    absolute = convert(T, absolute_tolerance)
    relative = convert(T, relative_tolerance)
    isfinite(absolute) && absolute >= zero(T) ||
        throw(ArgumentError("$(name)_absolute_tolerance must be finite and nonnegative"))
    isfinite(relative) && relative >= zero(T) ||
        throw(ArgumentError("$(name)_relative_tolerance must be finite and nonnegative"))
    return absolute, relative
end

"""
    objective_consistency_summary(model, evaluation; solver_objective_value,
                                  dual_snapshot=nothing, ...)

Compare a solver-reported objective with an independent evaluation at the exact
recorded point. For a continuous scalar affine model, a row-aligned public dual
snapshot also enables a numerical primal-dual gap after primal feasibility,
stationarity, and multiplier-sign checks pass. General nonlinear models retain
the objective comparison and an explicit unavailable gap reason.
"""
function objective_consistency_summary(
    model::MOI.ModelLike,
    evaluation::NumericalEvaluation{T};
    solver_objective_value = nothing,
    solver_objective_source::Symbol = :caller_supplied,
    result_index::Integer = 1,
    termination_status::AbstractString = "unknown",
    primal_status::AbstractString = "unknown",
    dual_snapshot::Union{Nothing,SolverDualSnapshot{T}} = nothing,
    absolute_tolerance::Real = zero(T),
    relative_tolerance::Real = sqrt(eps(T)),
    feasibility_tolerance::Real = sqrt(eps(T)),
    stationarity_tolerance::Real = sqrt(eps(T)),
    dual_tolerance::Real = sqrt(eps(T)),
    gap_absolute_tolerance::Real = zero(T),
    gap_relative_tolerance::Real = sqrt(eps(T)),
) where {T<:AbstractFloat}
    result_index >= 1 || throw(ArgumentError("result_index must be positive"))
    absolute, relative = _objective_consistency_tolerance(
        T, absolute_tolerance, relative_tolerance, "objective",
    )
    gap_absolute, gap_relative = _objective_consistency_tolerance(
        T, gap_absolute_tolerance, gap_relative_tolerance, "gap",
    )
    feasibility = convert(T, feasibility_tolerance)
    stationarity = convert(T, stationarity_tolerance)
    dual = convert(T, dual_tolerance)
    for (name, value) in (
        ("feasibility_tolerance", feasibility),
        ("stationarity_tolerance", stationarity),
        ("dual_tolerance", dual),
    )
        isfinite(value) && value >= zero(T) || throw(ArgumentError(
            "$name must be finite and nonnegative",
        ))
    end

    reported = _finite_objective_value(solver_objective_value, T)
    raw_evaluated = evaluation.objective_value
    evaluated = _finite_objective_value(raw_evaluated, T)
    failures = String[]
    isnothing(reported) && push!(failures,
        "the solver-reported objective is unavailable or non-finite")
    isnothing(evaluated) && push!(failures,
        "the represented objective could not be evaluated to a finite value at the selected point")
    append!(failures, [
        "$(failure.stage): $(failure.message)" for failure in evaluation.failures
        if failure.stage == :objective_value
    ])
    dual_snapshot isa SolverDualSnapshot{T} &&
        append!(failures, dual_snapshot.failures)

    comparison_available = !isnothing(reported) && !isnothing(evaluated)
    comparison_reason = comparison_available ? nothing : join(unique(failures), "; ")
    absolute_difference = comparison_available ? abs(reported - evaluated) : nothing
    comparison_scale = comparison_available ?
        max(one(T), abs(reported), abs(evaluated)) : nothing
    comparison_threshold = comparison_available ?
        absolute + relative * comparison_scale : nothing
    relative_difference = comparison_available ?
        absolute_difference / comparison_scale : nothing
    consistent = comparison_available ?
        absolute_difference <= comparison_threshold : nothing

    sense = _objective_sense_symbol(model)
    gap_reason, primal_feasible, dual_feasible, maximum_primal_violation,
        maximum_stationarity_residual, maximum_dual_violation =
        _gap_failure_reason(
            model,
            evaluation,
            dual_snapshot,
            Int(result_index),
            sense,
            feasibility,
            stationarity,
            dual,
        )
    if isnothing(evaluated)
        gap_reason = "the represented primal objective is unavailable or non-finite"
    elseif !(sense in (:minimize, :maximize))
        gap_reason = "the model has no minimization or maximization objective"
    end
    dual_objective = nothing
    primal_dual_gap = nothing
    relative_primal_dual_gap = nothing
    gap_threshold = nothing
    gap_passed = nothing
    if isnothing(gap_reason) && dual_snapshot isa SolverDualSnapshot{T}
        dual_objective = _affine_dual_objective(evaluated, sense, dual_snapshot)
        if isnothing(dual_objective) || !isfinite(dual_objective)
            gap_reason = "the affine dual objective could not be assembled from finite scalar-side evidence"
            dual_objective = nothing
        else
            primal_dual_gap = sense == :minimize ?
                evaluated - dual_objective : dual_objective - evaluated
            gap_scale = max(one(T), abs(evaluated), abs(dual_objective))
            relative_primal_dual_gap = abs(primal_dual_gap) / gap_scale
            gap_threshold = gap_absolute + gap_relative * gap_scale
            gap_passed = primal_dual_gap >= -gap_threshold &&
                abs(primal_dual_gap) <= gap_threshold
        end
    end
    gap_available = isnothing(gap_reason)

    methods = Symbol[:independent_model_objective_evaluation]
    !isnothing(reported) && push!(methods, solver_objective_source)
    gap_available && append!(methods, [
        :public_moi_constraint_duals,
        :continuous_scalar_affine_duality,
    ])
    observations = String[]
    comparison_available && push!(observations,
        "The solver objective is compared with the represented objective evaluated independently at the exact recorded point.")
    !comparison_available && push!(observations,
        "Objective-value consistency is unavailable: $(something(comparison_reason, "unknown reason")).")
    gap_available && push!(observations,
        "The primal-dual gap uses continuous scalar affine duality after primal feasibility, stationarity, and multiplier-sign checks under the recorded tolerances.")
    !gap_available && push!(observations,
        "A primal-dual gap is not reported: $(something(gap_reason, "unknown reason")).")
    push!(observations,
        "A numerical gap within tolerance does not establish exact optimality, multiplier uniqueness, or solver-internal scaling semantics.")

    return ObjectiveConsistencySummary{T}(
        evaluation.point,
        Int(result_index),
        sense,
        String(termination_status),
        String(primal_status),
        dual_snapshot isa SolverDualSnapshot{T} ?
            dual_snapshot.dual_status : "unavailable",
        solver_objective_source,
        reported,
        evaluated,
        comparison_available,
        comparison_reason,
        consistent,
        absolute_difference,
        relative_difference,
        absolute,
        relative,
        comparison_threshold,
        gap_available,
        gap_reason,
        gap_available ? :continuous_scalar_affine_duality : :none,
        dual_objective,
        primal_dual_gap,
        relative_primal_dual_gap,
        gap_absolute,
        gap_relative,
        gap_threshold,
        gap_passed,
        primal_feasible,
        dual_feasible,
        maximum_primal_violation,
        maximum_stationarity_residual,
        maximum_dual_violation,
        sort!(unique(methods); by = string),
        unique(failures),
        observations,
    )
end

function _unavailable_objective_consistency(
    model::MOI.ModelLike,
    result_index::Int,
    reason::AbstractString;
    absolute_tolerance::Real,
    relative_tolerance::Real,
    gap_absolute_tolerance::Real,
    gap_relative_tolerance::Real,
)
    T = Float64
    absolute, relative = _objective_consistency_tolerance(
        T, absolute_tolerance, relative_tolerance, "objective",
    )
    gap_absolute, gap_relative = _objective_consistency_tolerance(
        T, gap_absolute_tolerance, gap_relative_tolerance, "gap",
    )
    return ObjectiveConsistencySummary{T}(
        nothing, result_index, _objective_sense_symbol(model),
        _objective_result_status(model, MOI.TerminationStatus(), "unavailable"),
        _objective_result_status(model, MOI.PrimalStatus(result_index), "unavailable"),
        _objective_result_status(model, MOI.DualStatus(result_index), "unavailable"),
        :moi_objective_value, nothing, nothing, false, String(reason), nothing,
        nothing, nothing, absolute, relative, nothing, false, String(reason),
        :none, nothing, nothing, nothing, gap_absolute, gap_relative, nothing,
        nothing, nothing, nothing, nothing, nothing, nothing, Symbol[],
        [String(reason)], [
            "Objective-value consistency and the primal-dual gap are unavailable: $reason.",
        ],
    )
end

"""
    objective_consistency_summary(model; result_index=1, ...)

Read one complete public MOI solver result, re-evaluate its represented
objective, and return objective-consistency evidence. The model is never solved
or modified by this function.
"""
function objective_consistency_summary(
    model::MOI.ModelLike;
    result_index::Integer = 1,
    absolute_tolerance::Real = 0.0,
    relative_tolerance::Real = sqrt(eps(Float64)),
    feasibility_tolerance::Real = sqrt(eps(Float64)),
    stationarity_tolerance::Real = sqrt(eps(Float64)),
    dual_tolerance::Real = sqrt(eps(Float64)),
    gap_absolute_tolerance::Real = 0.0,
    gap_relative_tolerance::Real = sqrt(eps(Float64)),
    kwargs...,
)
    result_index >= 1 || throw(ArgumentError("result_index must be positive"))
    for (name, value) in (
        ("feasibility_tolerance", feasibility_tolerance),
        ("stationarity_tolerance", stationarity_tolerance),
        ("dual_tolerance", dual_tolerance),
    )
        converted = convert(Float64, value)
        isfinite(converted) && converted >= 0.0 || throw(ArgumentError(
            "$name must be finite and nonnegative",
        ))
    end
    index = Int(result_index)
    point = solver_result_point(
        model; result_index = index, label = "solver-result-$index",
    )
    isnothing(point) && return _unavailable_objective_consistency(
        model,
        index,
        "the selected result has no complete public primal point";
        absolute_tolerance,
        relative_tolerance,
        gap_absolute_tolerance,
        gap_relative_tolerance,
    )
    evaluation = evaluate_numerical(model, point)
    reported = try
        MOI.get(model, MOI.ObjectiveValue(index))
    catch
        nothing
    end
    dual_snapshot = solver_dual_snapshot(model, evaluation; result_index = index)
    return objective_consistency_summary(
        model,
        evaluation;
        solver_objective_value = reported,
        solver_objective_source = :moi_objective_value,
        result_index = index,
        termination_status = _objective_result_status(
            model, MOI.TerminationStatus(), "unavailable",
        ),
        primal_status = _objective_result_status(
            model, MOI.PrimalStatus(index), "unavailable",
        ),
        dual_snapshot,
        absolute_tolerance,
        relative_tolerance,
        feasibility_tolerance,
        stationarity_tolerance,
        dual_tolerance,
        gap_absolute_tolerance,
        gap_relative_tolerance,
        kwargs...,
    )
end

function _objective_unavailable_reason_data(reason, code)
    isnothing(reason) && return nothing
    return unavailable_reason_data(UnavailableReason(
        reason;
        code,
        category = :capability,
        stage = :objective_consistency,
    ))
end

"""Return renderer-neutral data for an [`ObjectiveConsistencySummary`](@ref)."""
function objective_consistency_summary_data(summary::ObjectiveConsistencySummary)
    return Dict{String,Any}(
        "schema_version" => "nlpdiagnostics-objective-consistency-summary-v1",
        "point" => isnothing(summary.point) ? nothing :
            _evaluation_point_data(summary.point),
        "result_index" => summary.result_index,
        "objective_sense" => string(summary.objective_sense),
        "termination_status" => summary.termination_status,
        "primal_status" => summary.primal_status,
        "dual_status" => summary.dual_status,
        "solver_objective_source" => string(summary.solver_objective_source),
        "solver_objective_value" => summary.solver_objective_value,
        "reevaluated_objective_value" => summary.reevaluated_objective_value,
        "comparison_available" => summary.comparison_available,
        "comparison_reason" => summary.comparison_reason,
        "comparison_unavailable_reason" => _objective_unavailable_reason_data(
            summary.comparison_reason, :objective_comparison_unavailable,
        ),
        "consistent" => summary.consistent,
        "absolute_difference" => summary.absolute_difference,
        "relative_difference" => summary.relative_difference,
        "absolute_tolerance" => summary.absolute_tolerance,
        "relative_tolerance" => summary.relative_tolerance,
        "consistency_threshold" => summary.consistency_threshold,
        "gap_available" => summary.gap_available,
        "gap_reason" => summary.gap_reason,
        "gap_unavailable_reason" => _objective_unavailable_reason_data(
            summary.gap_reason, :primal_dual_gap_unavailable,
        ),
        "gap_basis" => string(summary.gap_basis),
        "dual_objective_value" => summary.dual_objective_value,
        "primal_dual_gap" => summary.primal_dual_gap,
        "relative_primal_dual_gap" => summary.relative_primal_dual_gap,
        "gap_absolute_tolerance" => summary.gap_absolute_tolerance,
        "gap_relative_tolerance" => summary.gap_relative_tolerance,
        "gap_threshold" => summary.gap_threshold,
        "gap_passed" => summary.gap_passed,
        "primal_feasible" => summary.primal_feasible,
        "dual_feasible" => summary.dual_feasible,
        "maximum_primal_violation" => summary.maximum_primal_violation,
        "maximum_stationarity_residual" =>
            summary.maximum_stationarity_residual,
        "maximum_dual_violation" => summary.maximum_dual_violation,
        "methods" => string.(summary.methods),
        "failures" => copy(summary.failures),
        "observations" => copy(summary.observations),
        "qualification" => Dict{String,Any}(
            "comparison_claim" =>
                "solver objective versus represented objective at one exact point",
            "gap_claim" =>
                "tolerance-qualified continuous scalar affine primal-dual gap",
            "does_not_establish" => [
                "exact optimality",
                "multiplier uniqueness",
                "solver-internal scaling or barrier-objective equivalence",
                "a global dual bound for a general nonlinear program",
            ],
        ),
    )
end

"""Turn objective-consistency evidence into typed findings."""
function objective_consistency_report(summary::ObjectiveConsistencySummary)
    report = DiagnosticReport(Finding[], Dict{Symbol,String}(
        :result_index => string(summary.result_index),
        :objective_sense => string(summary.objective_sense),
        :dual_status => summary.dual_status,
        :comparison_available => string(summary.comparison_available),
        :gap_available => string(summary.gap_available),
    ))
    if !summary.comparison_available
        push!(report, Finding(:objective_value_comparison_unavailable;
            severity = SeverityInfo,
            domain = RepresentationalIssue,
            basis = NumericalObservation,
            confidence = ConfidenceHigh,
            observation = "The solver-reported and independently evaluated objectives could not both be obtained.",
            why_it_matters = "Objective agreement cannot be assessed without two finite values tied to the same point.",
            evidence = [Evidence("Objective comparison availability"; details = [
                "reason" => summary.comparison_reason,
                "result_index" => summary.result_index,
            ])],
            suggested_actions = [
                "Check ResultCount, PrimalStatus, ObjectiveValue, and objective evaluation failures.",
            ],
        ))
    elseif summary.consistent
        push!(report, Finding(:solver_result_objective_consistent;
            severity = SeverityInfo,
            domain = NumericalIssue,
            basis = NumericalObservation,
            confidence = ConfidenceHigh,
            observation = "The solver-reported objective agrees with independent model evaluation under the recorded tolerance.",
            why_it_matters = "This supports treating the two values as one endpoint record under the stated comparison policy.",
            evidence = [Evidence("Objective comparison"; details = [
                "solver_objective" => summary.solver_objective_value,
                "reevaluated_objective" => summary.reevaluated_objective_value,
                "absolute_difference" => summary.absolute_difference,
                "threshold" => summary.consistency_threshold,
            ])],
        ))
    else
        push!(report, Finding(:solver_result_objective_mismatch;
            severity = SeverityWarning,
            domain = RepresentationalIssue,
            basis = NumericalObservation,
            confidence = ConfidenceHigh,
            observation = "The solver-reported objective differs from independent model evaluation beyond the recorded tolerance.",
            why_it_matters = "Scaling, offsets, barrier terms, sign conventions, or point timing must be resolved before these values are treated as one result record.",
            evidence = [Evidence("Objective comparison"; details = [
                "solver_objective" => summary.solver_objective_value,
                "reevaluated_objective" => summary.reevaluated_objective_value,
                "absolute_difference" => summary.absolute_difference,
                "threshold" => summary.consistency_threshold,
            ])],
            suggested_actions = [
                "Check solver objective scaling, offsets, sign conventions, barrier terms, and endpoint timing.",
            ],
        ))
    end
    if !summary.gap_available
        push!(report, Finding(:primal_dual_gap_unavailable;
            severity = SeverityInfo,
            domain = RepresentationalIssue,
            basis = StructuralProof,
            confidence = ConfidenceHigh,
            observation = "A mathematically applicable primal-dual gap was not produced for this result.",
            why_it_matters = "A generic difference between arbitrary primal and dual-looking numbers is not a valid optimality gap.",
            evidence = [Evidence("Primal-dual gap availability"; details = [
                "reason" => summary.gap_reason,
                "gap_basis" => summary.gap_basis,
            ])],
        ))
    elseif summary.gap_passed
        push!(report, Finding(:primal_dual_gap_within_tolerance;
            severity = SeverityInfo,
            domain = NumericalIssue,
            basis = NumericalObservation,
            confidence = ConfidenceHigh,
            observation = "The continuous scalar affine primal-dual gap is within the recorded tolerance.",
            why_it_matters = "Together with the retained primal- and dual-feasibility checks, this is numerical endpoint optimality evidence for the represented affine model.",
            evidence = [Evidence("Affine primal-dual gap"; details = [
                "primal_objective" => summary.reevaluated_objective_value,
                "dual_objective" => summary.dual_objective_value,
                "gap" => summary.primal_dual_gap,
                "threshold" => summary.gap_threshold,
            ])],
        ))
    else
        push!(report, Finding(:primal_dual_gap_exceeds_tolerance;
            severity = SeverityWarning,
            domain = NumericalIssue,
            basis = NumericalObservation,
            confidence = ConfidenceHigh,
            observation = "The continuous scalar affine primal-dual gap exceeds the recorded tolerance.",
            why_it_matters = "The retained feasible primal and dual representatives do not support endpoint optimality under this policy.",
            evidence = [Evidence("Affine primal-dual gap"; details = [
                "primal_objective" => summary.reevaluated_objective_value,
                "dual_objective" => summary.dual_objective_value,
                "gap" => summary.primal_dual_gap,
                "threshold" => summary.gap_threshold,
            ])],
        ))
    end
    sort!(report.findings; by = finding -> (-Int(finding.severity), string(finding.code)))
    return report
end

objective_consistency_report(model::MOI.ModelLike; kwargs...) =
    objective_consistency_report(objective_consistency_summary(model; kwargs...))

function Base.show(io::IO, summary::ObjectiveConsistencySummary)
    print(io, "ObjectiveConsistencySummary(comparison=", summary.consistent,
        ", gap=", summary.gap_available ? summary.primal_dual_gap : "unavailable",
        ", result=", summary.result_index, ")")
end
