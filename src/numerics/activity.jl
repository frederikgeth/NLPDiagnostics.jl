function _scalar_set_bounds(set_value, row_count::Integer)
    if set_value isa MOI.EqualTo
        return fill((set_value.value, set_value.value), row_count)
    elseif set_value isa MOI.LessThan
        return fill((nothing, set_value.upper), row_count)
    elseif set_value isa MOI.GreaterThan
        return fill((set_value.lower, nothing), row_count)
    elseif set_value isa MOI.Interval
        return fill((set_value.lower, set_value.upper), row_count)
    elseif set_value isa MOI.Zeros
        return fill((0.0, 0.0), row_count)
    elseif set_value isa MOI.Nonnegatives
        return fill((0.0, nothing), row_count)
    elseif set_value isa MOI.Nonpositives
        return fill((nothing, 0.0), row_count)
    end
    return fill(nothing, row_count)
end

function _evaluated_row_bounds(model::MOI.ModelLike, evaluation::NumericalEvaluation)
    model_snapshot = snapshot(model)
    bounds = Any[]
    for constraint in model_snapshot.constraints
        constraint.set_value isa MOI.VectorNonlinearOracle && continue
        functions = try
            _scalar_rows(constraint.function_value)
        catch
            Any[]
        end
        append!(
            bounds,
            _scalar_set_bounds(constraint.set_value, length(functions)),
        )
    end
    block = _optional_nlp_block(model)
    if !isnothing(block)
        for bound in block.constraint_bounds
            push!(bounds, (bound.lower, bound.upper))
        end
    end
    for constraint in model_snapshot.constraints
        oracle = constraint.set_value
        oracle isa MOI.VectorNonlinearOracle || continue
        for row in 1:oracle.output_dimension
            push!(bounds, (oracle.l[row], oracle.u[row]))
        end
    end
    length(bounds) == length(evaluation.constraint_sources) || return nothing
    return bounds
end

function _activity_record(
    ::Type{T},
    row::Int,
    source::EntityRef,
    value,
    bounds,
    feasibility_tolerance::T,
    active_tolerance::T,
) where {T<:AbstractFloat}
    isnothing(bounds) && return ConstraintActivity{T}(
        row,
        source,
        ismissing(value) ? missing : convert(T, value),
        nothing,
        nothing,
        nothing,
        nothing,
        nothing,
        false,
        false,
        :opaque_set,
    )
    lower_raw, upper_raw = bounds
    lower = isnothing(lower_raw) || !isfinite(lower_raw) ?
            nothing :
            convert(T, lower_raw)
    upper = isnothing(upper_raw) || !isfinite(upper_raw) ?
            nothing :
            convert(T, upper_raw)
    if ismissing(value) || !isfinite(value)
        return ConstraintActivity{T}(
            row, source, missing, lower, upper, nothing, nothing, nothing,
            false, false, :unavailable,
        )
    end
    converted_value = convert(T, value)
    lower_margin = isnothing(lower) ? nothing : converted_value - lower
    upper_margin = isnothing(upper) ? nothing : upper - converted_value
    lower_violation = isnothing(lower_margin) ? zero(T) : max(-lower_margin, zero(T))
    upper_violation = isnothing(upper_margin) ? zero(T) : max(-upper_margin, zero(T))
    violation = max(lower_violation, upper_violation)
    equality = !isnothing(lower) && !isnothing(upper) && lower == upper
    lower_active = !isnothing(lower_margin) && abs(lower_margin) <= active_tolerance
    upper_active = !isnothing(upper_margin) && abs(upper_margin) <= active_tolerance
    classification = if violation > feasibility_tolerance
        :violated
    elseif equality
        :equality
    elseif lower_active && upper_active
        :active_lower_upper
    elseif lower_active
        :active_lower
    elseif upper_active
        :active_upper
    elseif isnothing(lower) && isnothing(upper)
        :free
    else
        :interior
    end
    return ConstraintActivity{T}(
        row, source, converted_value, lower, upper, lower_margin, upper_margin,
        violation, lower_active, upper_active, classification,
    )
end

"""
    constraint_feasibility_summary(model, evaluation; ...)

Classify scalar constraint rows at an exact point using public MOI bounds.
The row order is exactly `NumericalEvaluation.constraint_sources` order. Sets
whose scalar bounds are not represented by the generic core remain explicit
`:opaque_set` records instead of receiving invented feasibility semantics.
"""
function constraint_feasibility_summary(
    model::MOI.ModelLike,
    evaluation::NumericalEvaluation{T};
    feasibility_tolerance::Real = sqrt(eps(T)),
    active_tolerance::Real = sqrt(eps(T)),
) where {T<:AbstractFloat}
    feasibility = convert(T, feasibility_tolerance)
    active = convert(T, active_tolerance)
    feasibility >= zero(T) ||
        throw(ArgumentError("feasibility_tolerance must be nonnegative"))
    active >= zero(T) ||
        throw(ArgumentError("active_tolerance must be nonnegative"))
    bounds = _evaluated_row_bounds(model, evaluation)
    if isnothing(bounds)
        activities = ConstraintActivity{T}[
            ConstraintActivity{T}(
                row,
                source,
                ismissing(evaluation.constraint_values[row]) ?
                missing :
                evaluation.constraint_values[row],
                nothing, nothing, nothing, nothing, nothing, false, false,
                :unavailable,
            ) for (row, source) in enumerate(evaluation.constraint_sources)
        ]
        return ConstraintFeasibilitySummary{T}(
            evaluation.point,
            activities,
            feasibility,
            active,
            false,
            "could not align public MOI sets with evaluated scalar rows",
        )
    end
    activities = ConstraintActivity{T}[
        _activity_record(
            T,
            row,
            evaluation.constraint_sources[row],
            evaluation.constraint_values[row],
            bounds[row],
            feasibility,
            active,
        ) for row in eachindex(bounds)
    ]
    complete = all(activity -> activity.classification != :opaque_set, activities)
    return ConstraintFeasibilitySummary{T}(
        evaluation.point,
        activities,
        feasibility,
        active,
        complete,
        complete ? nothing : "one or more sets have no generic scalar-bound interpretation",
    )
end

function constraint_feasibility_summary(
    model::MOI.ModelLike,
    point::EvaluationPoint;
    cache::EvaluationCache = EvaluationCache(),
    kwargs...,
)
    return constraint_feasibility_summary(
        model,
        evaluate_numerical(model, point; cache = cache);
        kwargs...,
    )
end

function active_constraint_rows(
    summary::ConstraintFeasibilitySummary;
    include_equalities::Bool = true,
    include_violated::Bool = false,
)
    rows = Int[]
    for activity in summary.activities
        if activity.classification == :equality
            include_equalities && push!(rows, activity.row)
        elseif activity.classification in (:active_lower, :active_upper, :active_lower_upper)
            push!(rows, activity.row)
        elseif include_violated && activity.classification == :violated
            push!(rows, activity.row)
        end
    end
    return rows
end

function _selected_jacobian_evaluation(
    evaluation::NumericalEvaluation{T},
    rows::Vector{Int},
) where {T}
    positions = Dict(row => position for (position, row) in enumerate(rows))
    entries = JacobianEntry{T}[
        JacobianEntry{T}(positions[entry.row], entry.column, entry.value) for
        entry in evaluation.jacobian_entries if haskey(positions, entry.row)
    ]
    return NumericalEvaluation{T}(
        evaluation.point,
        evaluation.objective_value,
        evaluation.objective_source,
        evaluation.objective_gradient,
        evaluation.constraint_values[rows],
        evaluation.constraint_sources[rows],
        entries,
        evaluation.jacobian_row_methods[rows],
        evaluation.capabilities,
        evaluation.failures,
    )
end

function mfcq_screen(
    evaluation::NumericalEvaluation{T},
    summary::ConstraintFeasibilitySummary{T};
    strict_tolerance::Real = sqrt(eps(T)),
    rank_relative_tolerance::Real =
        max(length(evaluation.point.variables), 1) * eps(T),
    max_dense_entries::Integer = 4_000_000,
) where {T<:AbstractFloat}
    evaluation.point == summary.point ||
        throw(ArgumentError("evaluation and activity summary points differ"))
    strict = convert(T, strict_tolerance)
    strict > zero(T) || throw(ArgumentError("strict_tolerance must be positive"))
    equalities = Int[
        activity.row for activity in summary.activities if
        activity.classification == :equality
    ]
    inequality_rows = Int[]
    signs = T[]
    for activity in summary.activities
        activity.classification == :active_lower &&
            (push!(inequality_rows, activity.row); push!(signs, -one(T)))
        activity.classification == :active_upper &&
            (push!(inequality_rows, activity.row); push!(signs, one(T)))
        if activity.classification == :active_lower_upper
            push!(inequality_rows, activity.row); push!(signs, -one(T))
            push!(inequality_rows, activity.row); push!(signs, one(T))
        end
    end
    equality_estimate = jacobian_rank_estimate(
        _selected_jacobian_evaluation(evaluation, equalities);
        relative_tolerance = rank_relative_tolerance,
        max_dense_entries = max_dense_entries,
    )
    equality_estimate.available || return MFCQScreen{T}(
        false, equality_estimate.reason, equalities, inequality_rows, false,
        zeros(T, length(evaluation.point.variables)), nothing,
    )
    equality_estimate.rank == length(equalities) || return MFCQScreen{T}(
        true, "equality Jacobian is rank deficient", equalities, inequality_rows,
        false, zeros(T, length(evaluation.point.variables)), nothing,
    )
    isempty(inequality_rows) && return MFCQScreen{T}(
        true, nothing, equalities, inequality_rows, true,
        zeros(T, length(evaluation.point.variables)), nothing,
    )
    tangent = equality_estimate.right_nullspace
    size(tangent, 2) > 0 || return MFCQScreen{T}(
        true, "equality tangent space is trivial", equalities, inequality_rows,
        false, zeros(T, length(evaluation.point.variables)), nothing,
    )
    jacobian = _combined_jacobian_matrix(evaluation)
    gradients = jacobian[inequality_rows, :] .* signs
    projected = gradients * tangent
    direction = -tangent * transpose(projected) * ones(T, length(inequality_rows))
    direction_norm = norm(direction)
    iszero(direction_norm) || (direction ./= direction_norm)
    directional_values = gradients * direction
    largest = maximum(directional_values)
    return MFCQScreen{T}(
        true,
        largest < -strict ? nothing : "simple common-descent direction was not found",
        equalities,
        inequality_rows,
        largest < -strict,
        direction,
        largest,
    )
end
