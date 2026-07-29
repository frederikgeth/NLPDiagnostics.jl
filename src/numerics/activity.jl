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
    elseif set_value isa MOI.Reals
        return fill((nothing, nothing), row_count)
    elseif set_value isa MOI.HyperRectangle
        length(set_value.lower) == row_count || return fill(nothing, row_count)
        length(set_value.upper) == row_count || return fill(nothing, row_count)
        return [(set_value.lower[row], set_value.upper[row]) for row in 1:row_count]
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

_activity_source_key(source::EntityRef) = (
    source.kind,
    source.index,
    source.subindex,
    source.function_type,
    source.set_type,
)

"""
    coupled_set_activity(set, source, values, feasibility_tolerance, active_tolerance)

Return `CoupledSetActivity` for a coupled vector set, or `nothing` when the
generic core has no semantics for it. Domain packages may extend this function
for their own MOI set types. Implementations must preserve vector-set
semantics; they should not manufacture scalar active rows.
"""
coupled_set_activity(args...) = nothing

"""
    coupled_set_tangent_evidence(set, source, values, activity, active_tolerance)

Return a smooth boundary normal in the vector-function output coordinates, or
`nothing` when no generic or plugin tangent statement is available. This hook
does not authorize scalar active-row conversion.
"""
coupled_set_tangent_evidence(args...) = nothing

"""Return the explicit current availability state of cone-aware qualification."""
function coupled_set_qualification_screen(
    evaluation::NumericalEvaluation{T},
    summary::CoupledSetFeasibilitySummary{T},
) where {T<:AbstractFloat}
    evaluation.point == summary.point ||
        throw(ArgumentError("evaluation and coupled-set summary points differ"))
    sources = EntityRef[tangent.source for tangent in summary.tangents]
    return CoupledSetQualificationScreen{T}(
        false,
        isempty(sources) ?
        "no smooth coupled-set boundary tangent is available at this point" :
        "cone-aware qualification semantics are not implemented; scalar LICQ/MFCQ is intentionally unchanged",
        evaluation.point,
        sources,
        false,
        zeros(T, length(evaluation.point.variables)),
        T[],
        zeros(T, length(evaluation.point.variables)),
        nothing,
        nothing,
        0,
        false,
        Symbol[],
    )
end

"""Build the coupled-set summary first, then return its qualification screen."""
function coupled_set_qualification_screen(
    model::MOI.ModelLike,
    evaluation::NumericalEvaluation{T};
    feasibility_tolerance::Real = sqrt(eps(T)),
    active_tolerance::Real = sqrt(eps(T)),
    strict_tolerance::Real = sqrt(eps(T)),
    max_iterations::Integer = 1_000,
) where {T<:AbstractFloat}
    return coupled_set_qualification_screen(
        evaluation,
        coupled_set_feasibility_summary(
            model, evaluation;
            feasibility_tolerance = feasibility_tolerance,
            active_tolerance = active_tolerance,
        );
        strict_tolerance = strict_tolerance,
        max_iterations = max_iterations,
    )
end

function coupled_set_activity(
    set_value::MOI.SecondOrderCone,
    source::EntityRef,
    values::Vector{Union{Missing,T}},
    feasibility::T,
    active::T,
) where {T<:AbstractFloat}
    if any(ismissing, values) || any(value -> !ismissing(value) && !isfinite(value), values)
        return CoupledSetActivity{T}(source, :second_order_cone, values, nothing, nothing, false, :unavailable)
    end
    numeric = T[value::T for value in values]
    margin = numeric[1] - norm(numeric[2:end])
    violation = max(-margin, zero(T))
    classification = violation > feasibility ? :violated :
                     abs(margin) <= active ? :boundary : :interior
    return CoupledSetActivity{T}(
        source, :second_order_cone, values, margin, violation,
        classification == :boundary, classification,
    )
end

function coupled_set_tangent_evidence(
    ::MOI.SecondOrderCone,
    source::EntityRef,
    values::Vector{Union{Missing,T}},
    activity::CoupledSetActivity{T},
    active::T,
) where {T<:AbstractFloat}
    activity.classification == :boundary || return nothing
    any(ismissing, values) && return nothing
    numeric = T[value::T for value in values]
    tail_norm = norm(numeric[2:end])
    tail_norm > active || return nothing
    return CoupledSetTangentEvidence{T}(
        source,
        :second_order_cone,
        vcat(one(T), -numeric[2:end] ./ tail_norm),
        "gradient of t - norm(x) at a smooth SOC boundary",
    )
end

function coupled_set_activity(
    ::MOI.NormOneCone,
    source::EntityRef,
    values::Vector{Union{Missing,T}},
    feasibility::T,
    active::T,
) where {T<:AbstractFloat}
    if any(ismissing, values) || any(value -> !ismissing(value) && !isfinite(value), values)
        return CoupledSetActivity{T}(source, :norm_one_cone, values, nothing, nothing, false, :unavailable)
    end
    numeric = T[value::T for value in values]
    margin = numeric[1] - sum(abs, numeric[2:end])
    violation = max(-margin, zero(T))
    classification = violation > feasibility ? :violated :
                     abs(margin) <= active ? :boundary : :interior
    return CoupledSetActivity{T}(
        source, :norm_one_cone, values, margin, violation,
        classification == :boundary, classification,
    )
end

function coupled_set_tangent_evidence(
    ::MOI.NormOneCone,
    source::EntityRef,
    values::Vector{Union{Missing,T}},
    activity::CoupledSetActivity{T},
    active::T,
) where {T<:AbstractFloat}
    activity.classification == :boundary || return nothing
    any(ismissing, values) && return nothing
    numeric = T[value::T for value in values]
    all(abs(value) > active for value in numeric[2:end]) || return nothing
    return CoupledSetTangentEvidence{T}(
        source, :norm_one_cone, vcat(one(T), -sign.(numeric[2:end])),
        "gradient of t - sum(abs, x) at a smooth norm-one-cone boundary",
    )
end

function coupled_set_activity(
    ::MOI.NormInfinityCone,
    source::EntityRef,
    values::Vector{Union{Missing,T}},
    feasibility::T,
    active::T,
) where {T<:AbstractFloat}
    if any(ismissing, values) || any(value -> !ismissing(value) && !isfinite(value), values)
        return CoupledSetActivity{T}(source, :norm_infinity_cone, values, nothing, nothing, false, :unavailable)
    end
    numeric = T[value::T for value in values]
    margin = numeric[1] - maximum(abs, numeric[2:end])
    violation = max(-margin, zero(T))
    classification = violation > feasibility ? :violated :
                     abs(margin) <= active ? :boundary : :interior
    return CoupledSetActivity{T}(
        source, :norm_infinity_cone, values, margin, violation,
        classification == :boundary, classification,
    )
end

function coupled_set_tangent_evidence(
    ::MOI.NormInfinityCone,
    source::EntityRef,
    values::Vector{Union{Missing,T}},
    activity::CoupledSetActivity{T},
    active::T,
) where {T<:AbstractFloat}
    activity.classification == :boundary || return nothing
    any(ismissing, values) && return nothing
    numeric = T[value::T for value in values]
    tail = numeric[2:end]
    maximum_magnitude = maximum(abs, tail)
    maximum_magnitude > active || return nothing
    maximizers = findall(value -> abs(abs(value) - maximum_magnitude) <= active, tail)
    length(maximizers) == 1 || return nothing
    normal = zeros(T, length(numeric))
    normal[1] = one(T)
    normal[1 + only(maximizers)] = -sign(tail[only(maximizers)])
    return CoupledSetTangentEvidence{T}(
        source, :norm_infinity_cone, normal,
        "gradient of t - norm(x, Inf) at a smooth norm-infinity-cone boundary",
    )
end

function _norm_cone_kind(p::Float64)
    p == 1.0 && return :norm_cone_one
    isinf(p) && return :norm_cone_infinity
    return :norm_cone
end

function coupled_set_activity(
    set_value::MOI.NormCone,
    source::EntityRef,
    values::Vector{Union{Missing,T}},
    feasibility::T,
    active::T,
) where {T<:AbstractFloat}
    if any(ismissing, values) || any(value -> !ismissing(value) && !isfinite(value), values)
        return CoupledSetActivity{T}(source, _norm_cone_kind(set_value.p), values, nothing, nothing, false, :unavailable)
    end
    numeric = T[value::T for value in values]
    tail_norm = norm(numeric[2:end], set_value.p)
    margin = numeric[1] - tail_norm
    violation = max(-margin, zero(T))
    classification = violation > feasibility ? :violated :
                     abs(margin) <= active ? :boundary : :interior
    return CoupledSetActivity{T}(
        source, _norm_cone_kind(set_value.p), values, margin, violation,
        classification == :boundary, classification,
    )
end

function coupled_set_tangent_evidence(
    set_value::MOI.NormCone,
    source::EntityRef,
    values::Vector{Union{Missing,T}},
    activity::CoupledSetActivity{T},
    active::T,
) where {T<:AbstractFloat}
    activity.classification == :boundary || return nothing
    any(ismissing, values) && return nothing
    numeric = T[value::T for value in values]
    tail = numeric[2:end]
    p = set_value.p
    if p == 1.0
        all(abs(value) > active for value in tail) || return nothing
        normal = vcat(one(T), -sign.(tail))
    elseif isinf(p)
        maximum_magnitude = maximum(abs, tail)
        maximum_magnitude > active || return nothing
        maximizers = findall(value -> abs(abs(value) - maximum_magnitude) <= active, tail)
        length(maximizers) == 1 || return nothing
        normal = zeros(T, length(numeric))
        normal[1] = one(T)
        normal[1 + only(maximizers)] = -sign(tail[only(maximizers)])
    else
        tail_norm = norm(tail, p)
        tail_norm > active || return nothing
        normal = vcat(
            one(T),
            [-sign(value) * abs(value)^(p - 1) / tail_norm^(p - 1) for value in tail],
        )
    end
    return CoupledSetTangentEvidence{T}(
        source,
        _norm_cone_kind(p),
        normal,
        "gradient of t - norm(x, p) at a smooth generic norm-cone boundary",
    )
end

"""Return whether the leading spectral-norm mode is locally unique."""
function _spectral_norm_is_smooth(singular_values::AbstractVector{T}, active::T) where {T<:AbstractFloat}
    isempty(singular_values) && return false
    singular_values[1] > active || return false
    return length(singular_values) == 1 ||
           singular_values[1] - singular_values[2] > active
end

function coupled_set_activity(
    set_value::MOI.NormSpectralCone,
    source::EntityRef,
    values::Vector{Union{Missing,T}},
    feasibility::T,
    active::T,
) where {T<:AbstractFloat}
    if any(ismissing, values) || any(value -> !ismissing(value) && !isfinite(value), values)
        return CoupledSetActivity{T}(
            source, :norm_spectral_cone, values, nothing, nothing, false,
            :unavailable, "matrix entries are missing or non-finite",
        )
    end
    numeric = T[value::T for value in values]
    matrix_value = reshape(numeric[2:end], set_value.row_dim, set_value.column_dim)
    singular_values = svdvals(matrix_value)
    spectral_norm = isempty(singular_values) ? zero(T) : singular_values[1]
    margin = numeric[1] - spectral_norm
    violation = max(-margin, zero(T))
    classification = violation > feasibility ? :violated :
                     abs(margin) <= active ? :boundary : :interior
    reason = classification == :boundary &&
             !_spectral_norm_is_smooth(singular_values, active) ?
             "the leading singular value is zero or not separated from the next singular value" :
             nothing
    return CoupledSetActivity{T}(
        source, :norm_spectral_cone, values, margin, violation,
        classification == :boundary, classification, reason,
    )
end

function coupled_set_tangent_evidence(
    set_value::MOI.NormSpectralCone,
    source::EntityRef,
    values::Vector{Union{Missing,T}},
    activity::CoupledSetActivity{T},
    active::T,
) where {T<:AbstractFloat}
    activity.classification == :boundary || return nothing
    any(ismissing, values) && return nothing
    numeric = T[value::T for value in values]
    matrix_value = reshape(numeric[2:end], set_value.row_dim, set_value.column_dim)
    factorization = svd(matrix_value)
    _spectral_norm_is_smooth(factorization.S, active) || return nothing
    normal = vcat(one(T), -vec(factorization.U[:, 1] * factorization.Vt[1:1, :]))
    return CoupledSetTangentEvidence{T}(
        source,
        :norm_spectral_cone,
        normal,
        "gradient of t - sigma_max(X) at a simple nonzero leading singular value",
    )
end

"""Return whether the nuclear norm has a unique local gradient at this matrix."""
function _nuclear_norm_is_smooth(singular_values::AbstractVector{T}, active::T) where {T<:AbstractFloat}
    return !isempty(singular_values) && all(value -> value > active, singular_values)
end

function coupled_set_activity(
    set_value::MOI.NormNuclearCone,
    source::EntityRef,
    values::Vector{Union{Missing,T}},
    feasibility::T,
    active::T,
) where {T<:AbstractFloat}
    if any(ismissing, values) || any(value -> !ismissing(value) && !isfinite(value), values)
        return CoupledSetActivity{T}(
            source, :norm_nuclear_cone, values, nothing, nothing, false,
            :unavailable, "matrix entries are missing or non-finite",
        )
    end
    numeric = T[value::T for value in values]
    matrix_value = reshape(numeric[2:end], set_value.row_dim, set_value.column_dim)
    singular_values = svdvals(matrix_value)
    margin = numeric[1] - sum(singular_values)
    violation = max(-margin, zero(T))
    classification = violation > feasibility ? :violated :
                     abs(margin) <= active ? :boundary : :interior
    reason = classification == :boundary &&
             !_nuclear_norm_is_smooth(singular_values, active) ?
             "the matrix is rank deficient, so the nuclear norm has no unique boundary normal" :
             nothing
    return CoupledSetActivity{T}(
        source, :norm_nuclear_cone, values, margin, violation,
        classification == :boundary, classification, reason,
    )
end

function coupled_set_tangent_evidence(
    set_value::MOI.NormNuclearCone,
    source::EntityRef,
    values::Vector{Union{Missing,T}},
    activity::CoupledSetActivity{T},
    active::T,
) where {T<:AbstractFloat}
    activity.classification == :boundary || return nothing
    any(ismissing, values) && return nothing
    numeric = T[value::T for value in values]
    matrix_value = reshape(numeric[2:end], set_value.row_dim, set_value.column_dim)
    factorization = svd(matrix_value)
    _nuclear_norm_is_smooth(factorization.S, active) || return nothing
    rank_dimension = length(factorization.S)
    normal = vcat(
        one(T),
        -vec(factorization.U[:, 1:rank_dimension] * factorization.Vt[1:rank_dimension, :]),
    )
    return CoupledSetTangentEvidence{T}(
        source,
        :norm_nuclear_cone,
        normal,
        "gradient of t - nuclear_norm(X) at a full-rank matrix",
    )
end

"""Expand MOI's upper-triangle, column-major symmetric packing into a matrix."""
function _symmetric_triangle_matrix(values::AbstractVector{T}, side_dimension::Integer) where {T<:AbstractFloat}
    matrix_value = zeros(T, side_dimension, side_dimension)
    position = 1
    for column in 1:side_dimension, row in 1:column
        matrix_value[row, column] = values[position]
        matrix_value[column, row] = values[position]
        position += 1
    end
    return matrix_value
end

"""Pack the symmetric directional derivative `v * v'` in MOI triangle order."""
function _symmetric_triangle_outer_gradient(vector::AbstractVector{T}) where {T<:AbstractFloat}
    side_dimension = length(vector)
    gradient = Vector{T}(undef, div(side_dimension * (side_dimension + 1), 2))
    position = 1
    for column in 1:side_dimension, row in 1:column
        gradient[position] = row == column ? vector[row]^2 :
                             2 * vector[row] * vector[column]
        position += 1
    end
    return gradient
end

"""Pack a symmetric matrix derivative in MOI's upper-triangle coordinates."""
function _symmetric_triangle_matrix_gradient(matrix_value::AbstractMatrix{T}) where {T<:AbstractFloat}
    side_dimension = size(matrix_value, 1)
    gradient = Vector{T}(undef, div(side_dimension * (side_dimension + 1), 2))
    position = 1
    for column in 1:side_dimension, row in 1:column
        gradient[position] = row == column ? matrix_value[row, column] :
                             2 * matrix_value[row, column]
        position += 1
    end
    return gradient
end

"""Undo the √2 off-diagonal coordinate scaling of a scaled packed PSD cone."""
function _unscale_symmetric_triangle_coordinates(values::AbstractVector{T}, side_dimension::Integer) where {T<:AbstractFloat}
    unscaled = copy(values)
    position = 1
    off_diagonal_scale = sqrt(T(2))
    for column in 1:side_dimension, row in 1:column
        row == column || (unscaled[position] /= off_diagonal_scale)
        position += 1
    end
    return unscaled
end

"""Map an unscaled packed-symmetric gradient into scaled PSD coordinates."""
function _scale_symmetric_triangle_gradient(gradient::AbstractVector{T}, side_dimension::Integer) where {T<:AbstractFloat}
    scaled = copy(gradient)
    position = 1
    off_diagonal_scale = sqrt(T(2))
    for column in 1:side_dimension, row in 1:column
        row == column || (scaled[position] /= off_diagonal_scale)
        position += 1
    end
    return scaled
end

"""Undo √2 scaling on real and imaginary off-diagonals of packed Hermitian data."""
function _unscale_hermitian_triangle_coordinates(values::AbstractVector{T}, side_dimension::Integer) where {T<:AbstractFloat}
    unscaled = copy(values)
    real_count = div(side_dimension * (side_dimension + 1), 2)
    position = 1
    off_diagonal_scale = sqrt(T(2))
    for column in 1:side_dimension, row in 1:column
        row == column || (unscaled[position] /= off_diagonal_scale)
        position += 1
    end
    real_count < length(unscaled) && (unscaled[(real_count + 1):end] ./= off_diagonal_scale)
    return unscaled
end

"""Map a packed Hermitian gradient into MOI scaled coordinates."""
function _scale_hermitian_triangle_gradient(gradient::AbstractVector{T}, side_dimension::Integer) where {T<:AbstractFloat}
    scaled = copy(gradient)
    real_count = div(side_dimension * (side_dimension + 1), 2)
    position = 1
    off_diagonal_scale = sqrt(T(2))
    for column in 1:side_dimension, row in 1:column
        row == column || (scaled[position] /= off_diagonal_scale)
        position += 1
    end
    real_count < length(scaled) && (scaled[(real_count + 1):end] ./= off_diagonal_scale)
    return scaled
end

"""Return whether the minimum PSD eigenvalue is a locally simple boundary mode."""
function _psd_minimum_mode_is_smooth(eigenvalues::AbstractVector{T}, active::T) where {T<:AbstractFloat}
    isempty(eigenvalues) && return false
    return length(eigenvalues) == 1 || eigenvalues[2] - eigenvalues[1] > active
end

function coupled_set_activity(
    set_value::MOI.PositiveSemidefiniteConeTriangle,
    source::EntityRef,
    values::Vector{Union{Missing,T}},
    feasibility::T,
    active::T,
) where {T<:AbstractFloat}
    if any(ismissing, values) || any(value -> !ismissing(value) && !isfinite(value), values)
        return CoupledSetActivity{T}(
            source, :positive_semidefinite_cone_triangle, values,
            nothing, nothing, false, :unavailable,
            "packed symmetric-matrix entries are missing or non-finite",
        )
    end
    set_value.side_dimension > 0 || return CoupledSetActivity{T}(
        source, :positive_semidefinite_cone_triangle, values,
        nothing, nothing, false, :unavailable,
        "zero-dimensional PSD cone has no boundary mode to classify",
    )
    numeric = T[value::T for value in values]
    eigenvalues = eigen(Symmetric(_symmetric_triangle_matrix(
        numeric, set_value.side_dimension,
    ))).values
    margin = eigenvalues[1]
    violation = max(-margin, zero(T))
    classification = violation > feasibility ? :violated :
                     abs(margin) <= active ? :boundary : :interior
    reason = classification == :boundary &&
             !_psd_minimum_mode_is_smooth(eigenvalues, active) ?
             "the zero minimum eigenvalue is repeated, so the PSD boundary has no unique normal" :
             nothing
    return CoupledSetActivity{T}(
        source, :positive_semidefinite_cone_triangle, values, margin, violation,
        classification == :boundary, classification, reason,
    )
end

function coupled_set_tangent_evidence(
    set_value::MOI.PositiveSemidefiniteConeTriangle,
    source::EntityRef,
    values::Vector{Union{Missing,T}},
    activity::CoupledSetActivity{T},
    active::T,
) where {T<:AbstractFloat}
    activity.classification == :boundary || return nothing
    any(ismissing, values) && return nothing
    numeric = T[value::T for value in values]
    factorization = eigen(Symmetric(_symmetric_triangle_matrix(
        numeric, set_value.side_dimension,
    )))
    _psd_minimum_mode_is_smooth(factorization.values, active) || return nothing
    return CoupledSetTangentEvidence{T}(
        source,
        :positive_semidefinite_cone_triangle,
        _symmetric_triangle_outer_gradient(factorization.vectors[:, 1]),
        "gradient of the simple minimum eigenvalue in MOI packed-symmetric coordinates",
    )
end

function coupled_set_activity(
    set_value::MOI.Scaled{MOI.PositiveSemidefiniteConeTriangle},
    source::EntityRef,
    values::Vector{Union{Missing,T}},
    feasibility::T,
    active::T,
) where {T<:AbstractFloat}
    if any(ismissing, values) || any(value -> !ismissing(value) && !isfinite(value), values)
        return CoupledSetActivity{T}(
            source, :scaled_positive_semidefinite_cone_triangle, values,
            nothing, nothing, false, :unavailable,
            "scaled packed symmetric-matrix entries are missing or non-finite",
        )
    end
    side_dimension = set_value.set.side_dimension
    side_dimension > 0 || return CoupledSetActivity{T}(
        source, :scaled_positive_semidefinite_cone_triangle, values,
        nothing, nothing, false, :unavailable,
        "zero-dimensional scaled PSD cone has no boundary mode to classify",
    )
    numeric = T[value::T for value in values]
    unscaled = _unscale_symmetric_triangle_coordinates(numeric, side_dimension)
    eigenvalues = eigen(Symmetric(_symmetric_triangle_matrix(unscaled, side_dimension))).values
    margin = eigenvalues[1]
    violation = max(-margin, zero(T))
    classification = violation > feasibility ? :violated :
                     abs(margin) <= active ? :boundary : :interior
    reason = classification == :boundary &&
             !_psd_minimum_mode_is_smooth(eigenvalues, active) ?
             "the zero minimum eigenvalue is repeated, so the scaled PSD boundary has no unique normal" :
             nothing
    return CoupledSetActivity{T}(
        source, :scaled_positive_semidefinite_cone_triangle, values,
        margin, violation, classification == :boundary, classification, reason,
    )
end

function coupled_set_tangent_evidence(
    set_value::MOI.Scaled{MOI.PositiveSemidefiniteConeTriangle},
    source::EntityRef,
    values::Vector{Union{Missing,T}},
    activity::CoupledSetActivity{T},
    active::T,
) where {T<:AbstractFloat}
    activity.classification == :boundary || return nothing
    any(ismissing, values) && return nothing
    side_dimension = set_value.set.side_dimension
    numeric = T[value::T for value in values]
    unscaled = _unscale_symmetric_triangle_coordinates(numeric, side_dimension)
    factorization = eigen(Symmetric(_symmetric_triangle_matrix(unscaled, side_dimension)))
    _psd_minimum_mode_is_smooth(factorization.values, active) || return nothing
    normal = _scale_symmetric_triangle_gradient(
        _symmetric_triangle_outer_gradient(factorization.vectors[:, 1]),
        side_dimension,
    )
    return CoupledSetTangentEvidence{T}(
        source,
        :scaled_positive_semidefinite_cone_triangle,
        normal,
        "gradient of the simple minimum eigenvalue in scaled MOI packed-symmetric coordinates",
    )
end

function coupled_set_activity(
    set_value::MOI.PositiveSemidefiniteConeSquare,
    source::EntityRef,
    values::Vector{Union{Missing,T}},
    feasibility::T,
    active::T,
) where {T<:AbstractFloat}
    if any(ismissing, values) || any(value -> !ismissing(value) && !isfinite(value), values)
        return CoupledSetActivity{T}(
            source, :positive_semidefinite_cone_square, values,
            nothing, nothing, false, :unavailable,
            "square-matrix entries are missing or non-finite",
        )
    end
    set_value.side_dimension > 0 || return CoupledSetActivity{T}(
        source, :positive_semidefinite_cone_square, values,
        nothing, nothing, false, :unavailable,
        "zero-dimensional PSD cone has no boundary mode to classify",
    )
    numeric = T[value::T for value in values]
    matrix_value = reshape(numeric, set_value.side_dimension, set_value.side_dimension)
    symmetry_violation = maximum(abs, matrix_value .- transpose(matrix_value))
    eigenvalues = eigen(Symmetric((matrix_value .+ transpose(matrix_value)) ./ 2)).values
    margin = eigenvalues[1]
    violation = max(symmetry_violation, -margin, zero(T))
    classification = violation > feasibility ? :violated :
                     abs(margin) <= active ? :boundary : :interior
    reason = classification == :boundary ?
             "square PSD form embeds symmetry equalities; feasibility is available but no single boundary normal is claimed" :
             nothing
    return CoupledSetActivity{T}(
        source, :positive_semidefinite_cone_square, values, margin, violation,
        classification == :boundary, classification, reason,
    )
end

"""Expand MOI's real-packed Hermitian upper triangle into a complex matrix."""
function _hermitian_triangle_matrix(values::AbstractVector{T}, side_dimension::Integer) where {T<:AbstractFloat}
    real_count = div(side_dimension * (side_dimension + 1), 2)
    matrix_value = zeros(Complex{T}, side_dimension, side_dimension)
    position = 1
    for column in 1:side_dimension, row in 1:column
        matrix_value[row, column] = values[position]
        matrix_value[column, row] = values[position]
        position += 1
    end
    position = real_count + 1
    for column in 2:side_dimension, row in 1:(column - 1)
        imaginary_part = values[position]
        matrix_value[row, column] += im * imaginary_part
        matrix_value[column, row] -= im * imaginary_part
        position += 1
    end
    return matrix_value
end

"""Pack the Hermitian directional derivative `v * v'` in MOI real coordinates."""
function _hermitian_triangle_outer_gradient(vector::AbstractVector{Complex{T}}) where {T<:AbstractFloat}
    side_dimension = length(vector)
    real_count = div(side_dimension * (side_dimension + 1), 2)
    gradient = Vector{T}(undef, real_count + div(side_dimension * (side_dimension - 1), 2))
    position = 1
    for column in 1:side_dimension, row in 1:column
        product = conj(vector[row]) * vector[column]
        gradient[position] = row == column ? real(product) : 2 * real(product)
        position += 1
    end
    for column in 2:side_dimension, row in 1:(column - 1)
        gradient[position] = -2 * imag(conj(vector[row]) * vector[column])
        position += 1
    end
    return gradient
end

function coupled_set_activity(
    set_value::MOI.HermitianPositiveSemidefiniteConeTriangle,
    source::EntityRef,
    values::Vector{Union{Missing,T}},
    feasibility::T,
    active::T,
) where {T<:AbstractFloat}
    if any(ismissing, values) || any(value -> !ismissing(value) && !isfinite(value), values)
        return CoupledSetActivity{T}(
            source, :hermitian_positive_semidefinite_cone_triangle, values,
            nothing, nothing, false, :unavailable,
            "packed Hermitian-matrix entries are missing or non-finite",
        )
    end
    set_value.side_dimension > 0 || return CoupledSetActivity{T}(
        source, :hermitian_positive_semidefinite_cone_triangle, values,
        nothing, nothing, false, :unavailable,
        "zero-dimensional Hermitian PSD cone has no boundary mode to classify",
    )
    numeric = T[value::T for value in values]
    eigenvalues = eigen(Hermitian(_hermitian_triangle_matrix(
        numeric, set_value.side_dimension,
    ))).values
    margin = eigenvalues[1]
    violation = max(-margin, zero(T))
    classification = violation > feasibility ? :violated :
                     abs(margin) <= active ? :boundary : :interior
    reason = classification == :boundary &&
             !_psd_minimum_mode_is_smooth(eigenvalues, active) ?
             "the zero minimum eigenvalue is repeated, so the Hermitian PSD boundary has no unique normal" :
             nothing
    return CoupledSetActivity{T}(
        source, :hermitian_positive_semidefinite_cone_triangle, values,
        margin, violation, classification == :boundary, classification, reason,
    )
end

function coupled_set_tangent_evidence(
    set_value::MOI.HermitianPositiveSemidefiniteConeTriangle,
    source::EntityRef,
    values::Vector{Union{Missing,T}},
    activity::CoupledSetActivity{T},
    active::T,
) where {T<:AbstractFloat}
    activity.classification == :boundary || return nothing
    any(ismissing, values) && return nothing
    numeric = T[value::T for value in values]
    factorization = eigen(Hermitian(_hermitian_triangle_matrix(
        numeric, set_value.side_dimension,
    )))
    _psd_minimum_mode_is_smooth(factorization.values, active) || return nothing
    return CoupledSetTangentEvidence{T}(
        source,
        :hermitian_positive_semidefinite_cone_triangle,
        _hermitian_triangle_outer_gradient(factorization.vectors[:, 1]),
        "gradient of the simple minimum Hermitian eigenvalue in MOI packed coordinates",
    )
end

function coupled_set_activity(
    set_value::MOI.Scaled{MOI.HermitianPositiveSemidefiniteConeTriangle},
    source::EntityRef,
    values::Vector{Union{Missing,T}},
    feasibility::T,
    active::T,
) where {T<:AbstractFloat}
    if any(ismissing, values) || any(value -> !ismissing(value) && !isfinite(value), values)
        return CoupledSetActivity{T}(
            source, :scaled_hermitian_positive_semidefinite_cone_triangle,
            values, nothing, nothing, false, :unavailable,
            "scaled packed Hermitian-matrix entries are missing or non-finite",
        )
    end
    numeric = T[value::T for value in values]
    unscaled_numeric = _unscale_hermitian_triangle_coordinates(
        numeric, set_value.set.side_dimension,
    )
    unscaled = Union{Missing,T}[unscaled_numeric...]
    raw = coupled_set_activity(set_value.set, source, unscaled, feasibility, active)
    return CoupledSetActivity{T}(
        source, :scaled_hermitian_positive_semidefinite_cone_triangle,
        values, raw.margin, raw.feasibility_violation, raw.boundary_active,
        raw.classification, raw.reason,
    )
end

function coupled_set_tangent_evidence(
    set_value::MOI.Scaled{MOI.HermitianPositiveSemidefiniteConeTriangle},
    source::EntityRef,
    values::Vector{Union{Missing,T}},
    activity::CoupledSetActivity{T},
    active::T,
) where {T<:AbstractFloat}
    activity.classification == :boundary || return nothing
    any(ismissing, values) && return nothing
    numeric = T[value::T for value in values]
    side_dimension = set_value.set.side_dimension
    unscaled_numeric = _unscale_hermitian_triangle_coordinates(numeric, side_dimension)
    unscaled = Union{Missing,T}[unscaled_numeric...]
    raw_activity = coupled_set_activity(set_value.set, source, unscaled, zero(T), active)
    raw = coupled_set_tangent_evidence(set_value.set, source, unscaled, raw_activity, active)
    isnothing(raw) && return nothing
    return CoupledSetTangentEvidence{T}(
        source,
        :scaled_hermitian_positive_semidefinite_cone_triangle,
        _scale_hermitian_triangle_gradient(raw.normal, side_dimension),
        "gradient of the simple minimum Hermitian eigenvalue in scaled MOI packed coordinates",
    )
end

function coupled_set_activity(
    set_value::MOI.LogDetConeTriangle,
    source::EntityRef,
    values::Vector{Union{Missing,T}},
    feasibility::T,
    active::T,
) where {T<:AbstractFloat}
    if any(ismissing, values) || any(value -> !ismissing(value) && !isfinite(value), values)
        return CoupledSetActivity{T}(
            source, :logdet_cone_triangle, values, nothing, nothing, false,
            :unavailable, "log-determinant inputs are missing or non-finite",
        )
    end
    set_value.side_dimension > 0 || return CoupledSetActivity{T}(
        source, :logdet_cone_triangle, values, nothing, nothing, false,
        :unavailable, "zero-dimensional log-determinant cone has no generic boundary semantics",
    )
    numeric = T[value::T for value in values]
    scale = numeric[2]
    matrix_value = _symmetric_triangle_matrix(numeric[3:end], set_value.side_dimension)
    eigenvalues = eigen(Symmetric(matrix_value)).values
    if scale <= zero(T) || any(value -> value <= zero(T), eigenvalues)
        return CoupledSetActivity{T}(
            source, :logdet_cone_triangle, values, nothing, nothing, false,
            :unavailable,
            "log-determinant feasibility requires a positive scale and a positive-definite matrix",
        )
    end
    log_determinant = sum(log, eigenvalues) - set_value.side_dimension * log(scale)
    margin = scale * log_determinant - numeric[1]
    isfinite(margin) || return CoupledSetActivity{T}(
        source, :logdet_cone_triangle, values, nothing, nothing, false,
        :unavailable, "log-determinant range calculation is non-finite",
    )
    violation = max(-margin, zero(T))
    classification = violation > feasibility ? :violated :
                     abs(margin) <= active ? :boundary : :interior
    reason = classification == :boundary &&
             any(value -> value <= active, eigenvalues) ?
             "the matrix is positive definite but within the active tolerance of singularity, so the log-determinant tangent is withheld" :
             nothing
    return CoupledSetActivity{T}(
        source, :logdet_cone_triangle, values, margin, violation,
        classification == :boundary, classification, reason,
    )
end

function coupled_set_tangent_evidence(
    set_value::MOI.LogDetConeTriangle,
    source::EntityRef,
    values::Vector{Union{Missing,T}},
    activity::CoupledSetActivity{T},
    active::T,
) where {T<:AbstractFloat}
    activity.classification == :boundary || return nothing
    any(ismissing, values) && return nothing
    numeric = T[value::T for value in values]
    scale = numeric[2]
    matrix_value = _symmetric_triangle_matrix(numeric[3:end], set_value.side_dimension)
    eigenvalues = eigen(Symmetric(matrix_value)).values
    scale > active && all(value -> value > active, eigenvalues) || return nothing
    log_determinant = sum(log, eigenvalues) - set_value.side_dimension * log(scale)
    inverse_matrix = inv(matrix_value)
    normal = vcat(
        -one(T),
        log_determinant - set_value.side_dimension,
        scale .* _symmetric_triangle_matrix_gradient(inverse_matrix),
    )
    return CoupledSetTangentEvidence{T}(
        source,
        :logdet_cone_triangle,
        normal,
        "gradient of u*log(det(X/u)) - t on the positive-definite log-determinant slice",
    )
end

function coupled_set_activity(
    set_value::MOI.LogDetConeSquare,
    source::EntityRef,
    values::Vector{Union{Missing,T}},
    feasibility::T,
    active::T,
) where {T<:AbstractFloat}
    if any(ismissing, values) || any(value -> !ismissing(value) && !isfinite(value), values)
        return CoupledSetActivity{T}(
            source, :logdet_cone_square, values, nothing, nothing, false,
            :unavailable, "square log-determinant inputs are missing or non-finite",
        )
    end
    set_value.side_dimension > 0 || return CoupledSetActivity{T}(
        source, :logdet_cone_square, values, nothing, nothing, false,
        :unavailable, "zero-dimensional square log-determinant cone has no generic boundary semantics",
    )
    numeric = T[value::T for value in values]
    scale = numeric[2]
    matrix_value = reshape(numeric[3:end], set_value.side_dimension, set_value.side_dimension)
    symmetry_violation = maximum(abs, matrix_value .- transpose(matrix_value))
    if symmetry_violation > feasibility
        return CoupledSetActivity{T}(
            source, :logdet_cone_square, values, nothing, symmetry_violation,
            false, :violated, "square log-determinant cone requires a symmetric matrix",
        )
    end
    eigenvalues = eigen(Symmetric((matrix_value .+ transpose(matrix_value)) ./ 2)).values
    if scale <= zero(T) || any(value -> value <= zero(T), eigenvalues)
        return CoupledSetActivity{T}(
            source, :logdet_cone_square, values, nothing, nothing, false,
            :unavailable,
            "log-determinant feasibility requires a positive scale and a positive-definite symmetric matrix",
        )
    end
    log_determinant = sum(log, eigenvalues) - set_value.side_dimension * log(scale)
    margin = scale * log_determinant - numeric[1]
    isfinite(margin) || return CoupledSetActivity{T}(
        source, :logdet_cone_square, values, nothing, nothing, false,
        :unavailable, "log-determinant range calculation is non-finite",
    )
    violation = max(-margin, zero(T))
    classification = violation > feasibility ? :violated :
                     abs(margin) <= active ? :boundary : :interior
    reason = classification == :boundary &&
             any(value -> value <= active, eigenvalues) ?
             "the matrix is positive definite but within the active tolerance of singularity, so the log-determinant tangent is withheld" :
             classification == :boundary ?
             "square log-determinant form embeds symmetry equalities; feasibility is available but no single boundary normal is claimed" :
             nothing
    return CoupledSetActivity{T}(
        source, :logdet_cone_square, values, margin, violation,
        classification == :boundary, classification, reason,
    )
end

function coupled_set_activity(
    set_value::MOI.Scaled{MOI.LogDetConeTriangle},
    source::EntityRef,
    values::Vector{Union{Missing,T}},
    feasibility::T,
    active::T,
) where {T<:AbstractFloat}
    if any(ismissing, values) || any(value -> !ismissing(value) && !isfinite(value), values)
        return CoupledSetActivity{T}(
            source, :scaled_logdet_cone_triangle, values, nothing, nothing, false,
            :unavailable, "scaled log-determinant inputs are missing or non-finite",
        )
    end
    numeric = T[value::T for value in values]
    side_dimension = set_value.set.side_dimension
    unscaled_numeric = vcat(
        numeric[1:2],
        _unscale_symmetric_triangle_coordinates(numeric[3:end], side_dimension),
    )
    unscaled = Union{Missing,T}[unscaled_numeric...]
    raw = coupled_set_activity(set_value.set, source, unscaled, feasibility, active)
    return CoupledSetActivity{T}(
        source, :scaled_logdet_cone_triangle, values, raw.margin,
        raw.feasibility_violation, raw.boundary_active, raw.classification, raw.reason,
    )
end

function coupled_set_tangent_evidence(
    set_value::MOI.Scaled{MOI.LogDetConeTriangle},
    source::EntityRef,
    values::Vector{Union{Missing,T}},
    activity::CoupledSetActivity{T},
    active::T,
) where {T<:AbstractFloat}
    activity.classification == :boundary || return nothing
    any(ismissing, values) && return nothing
    numeric = T[value::T for value in values]
    side_dimension = set_value.set.side_dimension
    unscaled_numeric = vcat(
        numeric[1:2],
        _unscale_symmetric_triangle_coordinates(numeric[3:end], side_dimension),
    )
    unscaled = Union{Missing,T}[unscaled_numeric...]
    raw_activity = coupled_set_activity(set_value.set, source, unscaled, zero(T), active)
    raw = coupled_set_tangent_evidence(set_value.set, source, unscaled, raw_activity, active)
    isnothing(raw) && return nothing
    normal = vcat(
        raw.normal[1:2],
        _scale_symmetric_triangle_gradient(raw.normal[3:end], side_dimension),
    )
    return CoupledSetTangentEvidence{T}(
        source, :scaled_logdet_cone_triangle, normal,
        "gradient of scaled packed log-determinant coordinates on the positive-definite slice",
    )
end

function coupled_set_activity(
    set_value::MOI.RootDetConeTriangle,
    source::EntityRef,
    values::Vector{Union{Missing,T}},
    feasibility::T,
    active::T,
) where {T<:AbstractFloat}
    if any(ismissing, values) || any(value -> !ismissing(value) && !isfinite(value), values)
        return CoupledSetActivity{T}(
            source, :rootdet_cone_triangle, values, nothing, nothing, false,
            :unavailable, "root-determinant inputs are missing or non-finite",
        )
    end
    set_value.side_dimension > 0 || return CoupledSetActivity{T}(
        source, :rootdet_cone_triangle, values, nothing, nothing, false,
        :unavailable, "zero-dimensional root-determinant cone has no generic boundary semantics",
    )
    numeric = T[value::T for value in values]
    eigenvalues = eigen(Symmetric(_symmetric_triangle_matrix(
        numeric[2:end], set_value.side_dimension,
    ))).values
    minimum_eigenvalue = eigenvalues[1]
    if minimum_eigenvalue < -feasibility
        return CoupledSetActivity{T}(
            source, :rootdet_cone_triangle, values, minimum_eigenvalue,
            -minimum_eigenvalue, false, :violated,
            "root-determinant cone requires a positive-semidefinite matrix",
        )
    end
    root_determinant = any(value -> value <= zero(T), eigenvalues) ? zero(T) :
                       exp(sum(log, eigenvalues) / set_value.side_dimension)
    isfinite(root_determinant) || return CoupledSetActivity{T}(
        source, :rootdet_cone_triangle, values, nothing, nothing, false,
        :unavailable, "root-determinant range calculation is non-finite",
    )
    margin = root_determinant - numeric[1]
    violation = max(-margin, zero(T))
    classification = violation > feasibility ? :violated :
                     abs(margin) <= active ? :boundary : :interior
    reason = classification == :boundary &&
             any(value -> value <= active, eigenvalues) ?
             "the matrix is rank deficient, so the root-determinant boundary has no unique normal" :
             nothing
    return CoupledSetActivity{T}(
        source, :rootdet_cone_triangle, values, margin, violation,
        classification == :boundary, classification, reason,
    )
end

function coupled_set_tangent_evidence(
    set_value::MOI.RootDetConeTriangle,
    source::EntityRef,
    values::Vector{Union{Missing,T}},
    activity::CoupledSetActivity{T},
    active::T,
) where {T<:AbstractFloat}
    activity.classification == :boundary || return nothing
    any(ismissing, values) && return nothing
    numeric = T[value::T for value in values]
    matrix_value = _symmetric_triangle_matrix(numeric[2:end], set_value.side_dimension)
    eigenvalues = eigen(Symmetric(matrix_value)).values
    all(value -> value > active, eigenvalues) || return nothing
    root_determinant = exp(sum(log, eigenvalues) / set_value.side_dimension)
    normal = vcat(
        -one(T),
        (root_determinant / set_value.side_dimension) .*
        _symmetric_triangle_matrix_gradient(inv(matrix_value)),
    )
    return CoupledSetTangentEvidence{T}(
        source,
        :rootdet_cone_triangle,
        normal,
        "gradient of det(X)^(1/d) - t at a positive-definite root-determinant boundary",
    )
end

function coupled_set_activity(
    set_value::MOI.RootDetConeSquare,
    source::EntityRef,
    values::Vector{Union{Missing,T}},
    feasibility::T,
    active::T,
) where {T<:AbstractFloat}
    if any(ismissing, values) || any(value -> !ismissing(value) && !isfinite(value), values)
        return CoupledSetActivity{T}(
            source, :rootdet_cone_square, values, nothing, nothing, false,
            :unavailable, "square root-determinant inputs are missing or non-finite",
        )
    end
    set_value.side_dimension > 0 || return CoupledSetActivity{T}(
        source, :rootdet_cone_square, values, nothing, nothing, false,
        :unavailable, "zero-dimensional square root-determinant cone has no generic boundary semantics",
    )
    numeric = T[value::T for value in values]
    matrix_value = reshape(numeric[2:end], set_value.side_dimension, set_value.side_dimension)
    symmetry_violation = maximum(abs, matrix_value .- transpose(matrix_value))
    if symmetry_violation > feasibility
        return CoupledSetActivity{T}(
            source, :rootdet_cone_square, values, nothing, symmetry_violation,
            false, :violated, "square root-determinant cone requires a symmetric matrix",
        )
    end
    eigenvalues = eigen(Symmetric((matrix_value .+ transpose(matrix_value)) ./ 2)).values
    minimum_eigenvalue = eigenvalues[1]
    if minimum_eigenvalue < -feasibility
        return CoupledSetActivity{T}(
            source, :rootdet_cone_square, values, minimum_eigenvalue,
            -minimum_eigenvalue, false, :violated,
            "root-determinant cone requires a positive-semidefinite matrix",
        )
    end
    root_determinant = any(value -> value <= zero(T), eigenvalues) ? zero(T) :
                       exp(sum(log, eigenvalues) / set_value.side_dimension)
    isfinite(root_determinant) || return CoupledSetActivity{T}(
        source, :rootdet_cone_square, values, nothing, nothing, false,
        :unavailable, "root-determinant range calculation is non-finite",
    )
    margin = root_determinant - numeric[1]
    violation = max(-margin, zero(T))
    classification = violation > feasibility ? :violated :
                     abs(margin) <= active ? :boundary : :interior
    reason = classification == :boundary ?
             "square root-determinant form embeds symmetry equalities; feasibility is available but no single boundary normal is claimed" :
             nothing
    return CoupledSetActivity{T}(
        source, :rootdet_cone_square, values, margin, violation,
        classification == :boundary, classification, reason,
    )
end

function coupled_set_activity(
    set_value::MOI.Scaled{MOI.RootDetConeTriangle},
    source::EntityRef,
    values::Vector{Union{Missing,T}},
    feasibility::T,
    active::T,
) where {T<:AbstractFloat}
    if any(ismissing, values) || any(value -> !ismissing(value) && !isfinite(value), values)
        return CoupledSetActivity{T}(
            source, :scaled_rootdet_cone_triangle, values, nothing, nothing, false,
            :unavailable, "scaled root-determinant inputs are missing or non-finite",
        )
    end
    numeric = T[value::T for value in values]
    side_dimension = set_value.set.side_dimension
    unscaled_numeric = vcat(
        numeric[1:1],
        _unscale_symmetric_triangle_coordinates(numeric[2:end], side_dimension),
    )
    unscaled = Union{Missing,T}[unscaled_numeric...]
    raw = coupled_set_activity(set_value.set, source, unscaled, feasibility, active)
    return CoupledSetActivity{T}(
        source, :scaled_rootdet_cone_triangle, values, raw.margin,
        raw.feasibility_violation, raw.boundary_active, raw.classification, raw.reason,
    )
end

function coupled_set_tangent_evidence(
    set_value::MOI.Scaled{MOI.RootDetConeTriangle},
    source::EntityRef,
    values::Vector{Union{Missing,T}},
    activity::CoupledSetActivity{T},
    active::T,
) where {T<:AbstractFloat}
    activity.classification == :boundary || return nothing
    any(ismissing, values) && return nothing
    numeric = T[value::T for value in values]
    side_dimension = set_value.set.side_dimension
    unscaled_numeric = vcat(
        numeric[1:1],
        _unscale_symmetric_triangle_coordinates(numeric[2:end], side_dimension),
    )
    unscaled = Union{Missing,T}[unscaled_numeric...]
    raw_activity = coupled_set_activity(set_value.set, source, unscaled, zero(T), active)
    raw = coupled_set_tangent_evidence(set_value.set, source, unscaled, raw_activity, active)
    isnothing(raw) && return nothing
    normal = vcat(
        raw.normal[1:1],
        _scale_symmetric_triangle_gradient(raw.normal[2:end], side_dimension),
    )
    return CoupledSetTangentEvidence{T}(
        source, :scaled_rootdet_cone_triangle, normal,
        "gradient of scaled packed root-determinant coordinates at a positive-definite boundary",
    )
end

function coupled_set_activity(
    set_value::MOI.PowerCone,
    source::EntityRef,
    values::Vector{Union{Missing,T}},
    feasibility::T,
    active::T,
) where {T<:AbstractFloat}
    if any(ismissing, values) || any(value -> !ismissing(value) && !isfinite(value), values)
        return CoupledSetActivity{T}(source, :power_cone, values, nothing, nothing, false, :unavailable)
    end
    numeric = T[value::T for value in values]
    exponent = convert(T, set_value.exponent)
    if numeric[1] < zero(T) || numeric[2] < zero(T)
        violation = max(-numeric[1], -numeric[2], zero(T))
        return CoupledSetActivity{T}(
            source, :power_cone, values, nothing, violation, false, :violated,
        )
    end
    product = numeric[1]^exponent * numeric[2]^(one(T) - exponent)
    margin = product - abs(numeric[3])
    violation = max(-margin, zero(T))
    classification = violation > feasibility ? :violated :
                     abs(margin) <= active ? :boundary : :interior
    return CoupledSetActivity{T}(
        source, :power_cone, values, margin, violation,
        classification == :boundary, classification,
    )
end

function coupled_set_tangent_evidence(
    set_value::MOI.PowerCone,
    source::EntityRef,
    values::Vector{Union{Missing,T}},
    activity::CoupledSetActivity{T},
    active::T,
) where {T<:AbstractFloat}
    activity.classification == :boundary || return nothing
    any(ismissing, values) && return nothing
    numeric = T[value::T for value in values]
    numeric[1] > active && numeric[2] > active && abs(numeric[3]) > active ||
        return nothing
    exponent = convert(T, set_value.exponent)
    product = numeric[1]^exponent * numeric[2]^(one(T) - exponent)
    return CoupledSetTangentEvidence{T}(
        source,
        :power_cone,
        T[
            exponent * product / numeric[1],
            (one(T) - exponent) * product / numeric[2],
            -sign(numeric[3]),
        ],
        "gradient of x^a y^(1-a) - abs(z) at a smooth power-cone boundary",
    )
end

function coupled_set_activity(
    set_value::MOI.DualPowerCone,
    source::EntityRef,
    values::Vector{Union{Missing,T}},
    feasibility::T,
    active::T,
) where {T<:AbstractFloat}
    if any(ismissing, values) || any(value -> !ismissing(value) && !isfinite(value), values)
        return CoupledSetActivity{T}(source, :dual_power_cone, values, nothing, nothing, false, :unavailable)
    end
    numeric = T[value::T for value in values]
    exponent = convert(T, set_value.exponent)
    complement = one(T) - exponent
    if numeric[1] < zero(T) || numeric[2] < zero(T)
        violation = max(-numeric[1], -numeric[2], zero(T))
        return CoupledSetActivity{T}(
            source, :dual_power_cone, values, nothing, violation, false, :violated,
        )
    end
    product = (numeric[1] / exponent)^exponent *
              (numeric[2] / complement)^complement
    margin = product - abs(numeric[3])
    violation = max(-margin, zero(T))
    classification = violation > feasibility ? :violated :
                     abs(margin) <= active ? :boundary : :interior
    return CoupledSetActivity{T}(
        source, :dual_power_cone, values, margin, violation,
        classification == :boundary, classification,
    )
end

function coupled_set_tangent_evidence(
    set_value::MOI.DualPowerCone,
    source::EntityRef,
    values::Vector{Union{Missing,T}},
    activity::CoupledSetActivity{T},
    active::T,
) where {T<:AbstractFloat}
    activity.classification == :boundary || return nothing
    any(ismissing, values) && return nothing
    numeric = T[value::T for value in values]
    numeric[1] > active && numeric[2] > active && abs(numeric[3]) > active ||
        return nothing
    exponent = convert(T, set_value.exponent)
    complement = one(T) - exponent
    product = (numeric[1] / exponent)^exponent *
              (numeric[2] / complement)^complement
    return CoupledSetTangentEvidence{T}(
        source,
        :dual_power_cone,
        T[
            exponent * product / numeric[1],
            complement * product / numeric[2],
            -sign(numeric[3]),
        ],
        "gradient of (u/a)^a (v/(1-a))^(1-a) - abs(w) at a smooth dual-power-cone boundary",
    )
end

function coupled_set_activity(
    ::MOI.ExponentialCone,
    source::EntityRef,
    values::Vector{Union{Missing,T}},
    feasibility::T,
    active::T,
) where {T<:AbstractFloat}
    if any(ismissing, values) || any(value -> !ismissing(value) && !isfinite(value), values)
        return CoupledSetActivity{T}(source, :exponential_cone, values, nothing, nothing, false, :unavailable)
    end
    numeric = T[value::T for value in values]
    numeric[2] > zero(T) || return CoupledSetActivity{T}(
        source, :exponential_cone, values, nothing, nothing, false, :unavailable,
        "the generic exponential-cone slice requires y > 0",
    )
    exponential = exp(numeric[1] / numeric[2])
    isfinite(exponential) || return CoupledSetActivity{T}(
        source, :exponential_cone, values, nothing, nothing, false, :unavailable,
        "exp(x / y) is non-finite at the evaluation point",
    )
    margin = numeric[3] - numeric[2] * exponential
    violation = max(-margin, zero(T))
    classification = violation > feasibility ? :violated :
                     abs(margin) <= active ? :boundary : :interior
    return CoupledSetActivity{T}(
        source, :exponential_cone, values, margin, violation,
        classification == :boundary, classification,
    )
end

function coupled_set_tangent_evidence(
    ::MOI.ExponentialCone,
    source::EntityRef,
    values::Vector{Union{Missing,T}},
    activity::CoupledSetActivity{T},
    active::T,
) where {T<:AbstractFloat}
    activity.classification == :boundary || return nothing
    any(ismissing, values) && return nothing
    numeric = T[value::T for value in values]
    numeric[2] > active || return nothing
    ratio = numeric[1] / numeric[2]
    exponential = exp(ratio)
    isfinite(exponential) || return nothing
    return CoupledSetTangentEvidence{T}(
        source,
        :exponential_cone,
        T[-exponential, exponential * (ratio - one(T)), one(T)],
        "gradient of z - y * exp(x / y) at a smooth exponential-cone boundary",
    )
end

function coupled_set_activity(
    ::MOI.DualExponentialCone,
    source::EntityRef,
    values::Vector{Union{Missing,T}},
    feasibility::T,
    active::T,
) where {T<:AbstractFloat}
    if any(ismissing, values) || any(value -> !ismissing(value) && !isfinite(value), values)
        return CoupledSetActivity{T}(source, :dual_exponential_cone, values, nothing, nothing, false, :unavailable)
    end
    numeric = T[value::T for value in values]
    numeric[1] < zero(T) || return CoupledSetActivity{T}(
        source, :dual_exponential_cone, values, nothing, nothing, false, :unavailable,
        "the generic dual-exponential-cone slice requires u < 0",
    )
    exponential = exp(numeric[2] / numeric[1])
    isfinite(exponential) || return CoupledSetActivity{T}(
        source, :dual_exponential_cone, values, nothing, nothing, false, :unavailable,
        "exp(v / u) is non-finite at the evaluation point",
    )
    margin = exp(one(T)) * numeric[3] + numeric[1] * exponential
    violation = max(-margin, zero(T))
    classification = violation > feasibility ? :violated :
                     abs(margin) <= active ? :boundary : :interior
    return CoupledSetActivity{T}(
        source, :dual_exponential_cone, values, margin, violation,
        classification == :boundary, classification,
    )
end

function coupled_set_tangent_evidence(
    ::MOI.DualExponentialCone,
    source::EntityRef,
    values::Vector{Union{Missing,T}},
    activity::CoupledSetActivity{T},
    active::T,
) where {T<:AbstractFloat}
    activity.classification == :boundary || return nothing
    any(ismissing, values) && return nothing
    numeric = T[value::T for value in values]
    numeric[1] < -active || return nothing
    ratio = numeric[2] / numeric[1]
    exponential = exp(ratio)
    isfinite(exponential) || return nothing
    return CoupledSetTangentEvidence{T}(
        source,
        :dual_exponential_cone,
        T[exponential * (one(T) - ratio), exponential, exp(one(T))],
        "gradient of exp(1) * w + u * exp(v / u) at a smooth dual-exponential-cone boundary",
    )
end

function coupled_set_activity(
    ::MOI.GeometricMeanCone,
    source::EntityRef,
    values::Vector{Union{Missing,T}},
    feasibility::T,
    active::T,
) where {T<:AbstractFloat}
    if any(ismissing, values) || any(value -> !ismissing(value) && !isfinite(value), values)
        return CoupledSetActivity{T}(source, :geometric_mean_cone, values, nothing, nothing, false, :unavailable)
    end
    numeric = T[value::T for value in values]
    tail = numeric[2:end]
    if any(value -> value < zero(T), tail)
        violation = maximum((-value for value in tail if value < zero(T)); init = zero(T))
        return CoupledSetActivity{T}(
            source, :geometric_mean_cone, values, nothing, violation, false, :violated,
        )
    end
    exponent = inv(T(length(tail)))
    mean_value = prod(tail)^exponent
    margin = mean_value - numeric[1]
    violation = max(-margin, zero(T))
    classification = violation > feasibility ? :violated :
                     abs(margin) <= active ? :boundary : :interior
    return CoupledSetActivity{T}(
        source, :geometric_mean_cone, values, margin, violation,
        classification == :boundary, classification,
    )
end

function coupled_set_tangent_evidence(
    ::MOI.GeometricMeanCone,
    source::EntityRef,
    values::Vector{Union{Missing,T}},
    activity::CoupledSetActivity{T},
    active::T,
) where {T<:AbstractFloat}
    activity.classification == :boundary || return nothing
    any(ismissing, values) && return nothing
    numeric = T[value::T for value in values]
    tail = numeric[2:end]
    all(value -> value > active, tail) || return nothing
    exponent = inv(T(length(tail)))
    mean_value = prod(tail)^exponent
    return CoupledSetTangentEvidence{T}(
        source,
        :geometric_mean_cone,
        vcat(-one(T), [mean_value * exponent / value for value in tail]),
        "gradient of geometric_mean(x) - t at a smooth geometric-mean-cone boundary",
    )
end

function coupled_set_activity(
    ::MOI.RelativeEntropyCone,
    source::EntityRef,
    values::Vector{Union{Missing,T}},
    feasibility::T,
    active::T,
) where {T<:AbstractFloat}
    if any(ismissing, values) || any(value -> !ismissing(value) && !isfinite(value), values)
        return CoupledSetActivity{T}(source, :relative_entropy_cone, values, nothing, nothing, false, :unavailable)
    end
    numeric = T[value::T for value in values]
    count = (length(numeric) - 1) ÷ 2
    v = numeric[2:(count + 1)]
    w = numeric[(count + 2):end]
    all(value -> value > zero(T), v) && all(value -> value > zero(T), w) ||
        return CoupledSetActivity{T}(
            source, :relative_entropy_cone, values, nothing, nothing, false, :unavailable,
            "the generic relative-entropy slice requires every v and w coordinate to be positive",
        )
    entropy = sum(weight * log(weight / reference) for (reference, weight) in zip(v, w))
    isfinite(entropy) || return CoupledSetActivity{T}(
        source, :relative_entropy_cone, values, nothing, nothing, false, :unavailable,
        "the relative-entropy sum is non-finite at the evaluation point",
    )
    margin = numeric[1] - entropy
    violation = max(-margin, zero(T))
    classification = violation > feasibility ? :violated :
                     abs(margin) <= active ? :boundary : :interior
    return CoupledSetActivity{T}(
        source, :relative_entropy_cone, values, margin, violation,
        classification == :boundary, classification,
    )
end

function coupled_set_tangent_evidence(
    ::MOI.RelativeEntropyCone,
    source::EntityRef,
    values::Vector{Union{Missing,T}},
    activity::CoupledSetActivity{T},
    active::T,
) where {T<:AbstractFloat}
    activity.classification == :boundary || return nothing
    any(ismissing, values) && return nothing
    numeric = T[value::T for value in values]
    count = (length(numeric) - 1) ÷ 2
    v = numeric[2:(count + 1)]
    w = numeric[(count + 2):end]
    all(value -> value > active, v) && all(value -> value > active, w) ||
        return nothing
    return CoupledSetTangentEvidence{T}(
        source,
        :relative_entropy_cone,
        vcat(
            one(T),
            w ./ v,
            [-(log(weight / reference) + one(T)) for (reference, weight) in zip(v, w)],
        ),
        "gradient of u - sum(w .* log.(w ./ v)) at a smooth relative-entropy-cone boundary",
    )
end

function coupled_set_tangent_evidence(
    ::MOI.RotatedSecondOrderCone,
    source::EntityRef,
    values::Vector{Union{Missing,T}},
    activity::CoupledSetActivity{T},
    active::T,
) where {T<:AbstractFloat}
    activity.classification == :boundary || return nothing
    any(ismissing, values) && return nothing
    numeric = T[value::T for value in values]
    numeric[1] > active && numeric[2] > active || return nothing
    return CoupledSetTangentEvidence{T}(
        source,
        :rotated_second_order_cone,
        vcat(2 * numeric[2], 2 * numeric[1], -2 .* numeric[3:end]),
        "gradient of 2uv - norm(w)^2 at a smooth rotated-SOC boundary",
    )
end

function coupled_set_activity(
    set_value::MOI.RotatedSecondOrderCone,
    source::EntityRef,
    values::Vector{Union{Missing,T}},
    feasibility::T,
    active::T,
) where {T<:AbstractFloat}
    if any(ismissing, values) || any(value -> !ismissing(value) && !isfinite(value), values)
        return CoupledSetActivity{T}(source, :rotated_second_order_cone, values, nothing, nothing, false, :unavailable)
    end
    numeric = T[value::T for value in values]
    margin = 2 * numeric[1] * numeric[2] - sum(abs2, numeric[3:end])
    violation = max(-numeric[1], -numeric[2], -margin, zero(T))
    classification = violation > feasibility ? :violated :
                     abs(margin) <= active ? :boundary : :interior
    return CoupledSetActivity{T}(
        source, :rotated_second_order_cone, values, margin, violation,
        classification == :boundary, classification,
    )
end

"""
    coupled_set_feasibility_summary(model, evaluation; ...)

Evaluate supported generic vector-set feasibility without scalarizing its
activity semantics. Domain packages may extend `coupled_set_activity` for
other coupled MOI set types.
"""
function coupled_set_feasibility_summary(
    model::MOI.ModelLike,
    evaluation::NumericalEvaluation{T};
    feasibility_tolerance::Real = sqrt(eps(T)),
    active_tolerance::Real = sqrt(eps(T)),
) where {T<:AbstractFloat}
    feasibility = convert(T, feasibility_tolerance)
    active = convert(T, active_tolerance)
    feasibility >= zero(T) || throw(ArgumentError("feasibility_tolerance must be nonnegative"))
    active >= zero(T) || throw(ArgumentError("active_tolerance must be nonnegative"))
    values_by_source = Dict{Tuple,Union{Missing,T}}(
        _activity_source_key(source) => evaluation.constraint_values[row] for
        (row, source) in enumerate(evaluation.constraint_sources)
    )
    activities = CoupledSetActivity{T}[]
    tangents = CoupledSetTangentEvidence{T}[]
    for constraint in snapshot(model).constraints
        set_value = constraint.set_value
        constraint.function_value isa MOI.AbstractVectorFunction || continue
        is_coordinatewise_set(set_value) && continue
        functions = try
            _scalar_rows(constraint.function_value)
        catch
            continue
        end
        source_values = Union{Missing,T}[
            get(
                values_by_source,
                _activity_source_key(_constraint_ref(constraint; row = row)),
                missing,
            ) for row in 1:length(functions)
        ]
        source = _constraint_ref(constraint)
        activity = coupled_set_activity(
            set_value,
            source,
            source_values,
            feasibility,
            active,
        )
        if isnothing(activity)
            activity = CoupledSetActivity{T}(
                source,
                :unsupported_coupled_set,
                source_values,
                nothing,
                nothing,
                false,
                :unavailable,
                "no generic coupled-set activity semantics are registered for this set",
            )
        end
        push!(activities, activity)
        tangent = coupled_set_tangent_evidence(
            set_value, source, source_values, activity, active,
        )
        isnothing(tangent) || push!(tangents, tangent)
    end
    unavailable = CoupledSetActivity{T}[
        activity for activity in activities if activity.classification == :unavailable
    ]
    reasons = unique(String[
        activity.reason for activity in unavailable if !isnothing(activity.reason)
    ])
    return CoupledSetFeasibilitySummary{T}(
        evaluation.point,
        activities,
        tangents,
        feasibility,
        active,
        isempty(unavailable),
        isempty(reasons) ? nothing : join(reasons, "; "),
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

function _objective_stationarity_weight(model::MOI.ModelLike, ::Type{T}) where {T}
    sense = MOI.get(model, MOI.ObjectiveSense())
    return sense == MOI.MAX_SENSE ? -one(T) :
           sense == MOI.FEASIBILITY_SENSE ? zero(T) : one(T)
end

function _unavailable_multiplier_recovery(
    evaluation::NumericalEvaluation{T},
    reason::AbstractString,
    objective_weight::T,
) where {T}
    return MultiplierRecovery{T}(
        false, String(reason), evaluation.point, Int[], Symbol[], T[], 0,
        false, nothing, objective_weight, false, nothing, nothing,
    )
end

"""
    recover_stationarity_multipliers(model, evaluation, summary; ...)

Recover minimum-norm least-squares multipliers for the active equality and
near-active inequality sides. Lower sides use the canonical derivative `-∇g`;
upper sides use `∇g`. Objective sense is respected automatically.
"""
function recover_stationarity_multipliers(
    model::MOI.ModelLike,
    evaluation::NumericalEvaluation{T},
    summary::ConstraintFeasibilitySummary{T};
    rank_relative_tolerance::Real =
        max(length(evaluation.point.variables), 1) * eps(T),
    max_dense_entries::Integer = 4_000_000,
) where {T<:AbstractFloat}
    evaluation.point == summary.point ||
        throw(ArgumentError("evaluation and activity summary points differ"))
    weight = _objective_stationarity_weight(model, T)
    gradient = evaluation.objective_gradient
    isempty(gradient) && !iszero(weight) && return _unavailable_multiplier_recovery(
        evaluation, "objective gradient is unavailable", weight,
    )
    any(value -> ismissing(value) || !isfinite(value), gradient) &&
        return _unavailable_multiplier_recovery(
            evaluation, "objective gradient contains unavailable or non-finite entries", weight,
        )
    objective_gradient = iszero(weight) ?
                         zeros(T, length(evaluation.point.variables)) :
                         T.(gradient)
    rows = Int[]
    sides = Symbol[]
    signs = T[]
    for activity in summary.activities
        if activity.classification == :equality
            push!(rows, activity.row); push!(sides, :equality); push!(signs, one(T))
        elseif activity.classification == :active_lower
            push!(rows, activity.row); push!(sides, :lower); push!(signs, -one(T))
        elseif activity.classification == :active_upper
            push!(rows, activity.row); push!(sides, :upper); push!(signs, one(T))
        elseif activity.classification == :active_lower_upper
            push!(rows, activity.row); push!(sides, :lower); push!(signs, -one(T))
            push!(rows, activity.row); push!(sides, :upper); push!(signs, one(T))
        end
    end
    length(rows) * length(evaluation.point.variables) <= max_dense_entries ||
        return _unavailable_multiplier_recovery(evaluation, "active-gradient dense-work guard exceeded", weight)
    jacobian = _combined_jacobian_matrix(evaluation)
    gradient_matrix = jacobian[rows, :] .* signs
    all(isfinite, gradient_matrix) ||
        return _unavailable_multiplier_recovery(evaluation, "active Jacobian contains non-finite entries", weight)
    factorization = svd(gradient_matrix; full = false)
    threshold = convert(T, rank_relative_tolerance) * maximum(factorization.S; init = zero(T))
    rank = count(value -> value > threshold, factorization.S)
    multipliers = zeros(T, length(rows))
    if !isempty(rows) && rank > 0
        right_coordinates = transpose(factorization.V[:, 1:rank]) *
                            (-weight .* objective_gradient)
        multipliers = factorization.U[:, 1:rank] *
                      (right_coordinates ./ factorization.S[1:rank])
    end
    residual = norm(weight .* objective_gradient + transpose(gradient_matrix) * multipliers)
    feasible = all(
        activity -> isnothing(activity.feasibility_violation) ||
                    activity.feasibility_violation <= summary.feasibility_tolerance,
        summary.activities,
    )
    activities = Dict(activity.row => activity for activity in summary.activities)
    dual_violation = zero(T)
    complementarity = zero(T)
    for (row, side, multiplier) in zip(rows, sides, multipliers)
        side == :equality && continue
        dual_violation = max(dual_violation, max(-multiplier, zero(T)))
        activity = activities[row]
        margin = side == :lower ? activity.lower_margin : activity.upper_margin
        isnothing(margin) ||
            (complementarity = max(complementarity, abs(multiplier * margin)))
    end
    return MultiplierRecovery{T}(
        true, nothing, evaluation.point, rows, sides, T.(multipliers), rank,
        rank == length(rows), convert(T, residual), weight, feasible,
        dual_violation, complementarity,
    )
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

"""Minimum-norm point in the convex hull of rows using deterministic Frank--Wolfe steps."""
function _minimum_norm_convex_combination(
    rows::Matrix{T};
    max_iterations::Integer,
    convergence_tolerance::T,
) where {T<:AbstractFloat}
    count = size(rows, 1)
    count > 0 || return T[], nothing, false, 0
    weights = fill(inv(T(count)), count)
    point = transpose(rows) * weights
    for iteration in 1:max_iterations
        scores = rows * point
        target = argmin(scores)
        displacement = view(rows, target, :) - point
        denominator = sum(abs2, displacement)
        if iszero(denominator)
            return weights, norm(point), true, iteration
        end
        step = clamp(-dot(point, displacement) / denominator, zero(T), one(T))
        weights .*= one(T) - step
        weights[target] += step
        point .+= step .* displacement
        if step * sqrt(denominator) <= convergence_tolerance
            return weights, norm(point), true, iteration
        end
    end
    return weights, norm(point), false, Int(max_iterations)
end

function mfcq_screen(
    evaluation::NumericalEvaluation{T},
    summary::ConstraintFeasibilitySummary{T};
    strict_tolerance::Real = sqrt(eps(T)),
    witness_tolerance::Real = sqrt(eps(T)),
    witness_relative_tolerance::Real = 0,
    witness_max_iterations::Integer = 1_000,
    rank_relative_tolerance::Real =
        max(length(evaluation.point.variables), 1) * eps(T),
    max_dense_entries::Integer = 4_000_000,
) where {T<:AbstractFloat}
    evaluation.point == summary.point ||
        throw(ArgumentError("evaluation and activity summary points differ"))
    strict = convert(T, strict_tolerance)
    strict > zero(T) || throw(ArgumentError("strict_tolerance must be positive"))
    witness = convert(T, witness_tolerance)
    witness >= zero(T) || throw(ArgumentError("witness_tolerance must be nonnegative"))
    witness_relative = convert(T, witness_relative_tolerance)
    witness_relative >= zero(T) ||
        throw(ArgumentError("witness_relative_tolerance must be nonnegative"))
    witness_max_iterations > 0 ||
        throw(ArgumentError("witness_max_iterations must be positive"))
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
        zeros(T, length(evaluation.point.variables)), nothing, false, T[], nothing,
        nothing, nothing, 0, false, nothing, nothing,
    )
    equality_estimate.rank == length(equalities) || return MFCQScreen{T}(
        true, "equality Jacobian is rank deficient", equalities, inequality_rows,
        false, zeros(T, length(evaluation.point.variables)), nothing, false, T[], nothing,
        nothing, nothing, 0, false, equality_estimate.rank, equality_estimate.threshold,
    )
    isempty(inequality_rows) && return MFCQScreen{T}(
        true, nothing, equalities, inequality_rows, true,
        zeros(T, length(evaluation.point.variables)), nothing, false, T[], nothing,
        nothing, nothing, 0, false, equality_estimate.rank, equality_estimate.threshold,
    )
    tangent = equality_estimate.right_nullspace
    jacobian = _combined_jacobian_matrix(evaluation)
    gradients = jacobian[inequality_rows, :] .* signs
    projected = gradients * tangent
    projected_row_scale = maximum(
        (norm(view(projected, row, :)) for row in axes(projected, 1));
        init = zero(T),
    )
    effective_witness_tolerance = witness +
                                  witness_relative * projected_row_scale
    weights, witness_residual, witness_converged, witness_iterations =
        _minimum_norm_convex_combination(
        projected;
        max_iterations = witness_max_iterations,
        convergence_tolerance = effective_witness_tolerance,
    )
    witness_found = witness_converged && !isnothing(witness_residual) &&
                    witness_residual <= effective_witness_tolerance
    # The negative minimum-norm point in the convex hull is a much more
    # reliable common-descent candidate than the negative unweighted sum of
    # gradients. At an exact nonzero convex-hull minimizer p, every projected
    # gradient has inner product at least ||p||² with p, so -p decreases every
    # selected inequality. The subsequent explicit directional check retains
    # conservative numerical semantics for the iterative approximation.
    projected_witness = transpose(projected) * weights
    direction = -tangent * projected_witness
    direction_norm = norm(direction)
    iszero(direction_norm) || (direction ./= direction_norm)
    directional_values = gradients * direction
    largest = maximum(directional_values)
    reason = if largest < -strict
        nothing
    elseif witness_found
        "a numerical no-common-descent witness was found"
    elseif !witness_converged
        "minimum-norm convex-hull witness did not converge within the iteration budget"
    else
        "converged convex-hull screen found neither a strict common-descent direction nor a no-common-descent witness"
    end
    return MFCQScreen{T}(
        true,
        reason,
        equalities,
        inequality_rows,
        largest < -strict,
        direction,
        largest,
        witness_found,
        weights,
        witness_residual,
        projected_row_scale,
        effective_witness_tolerance,
        witness_iterations,
        witness_converged,
        equality_estimate.rank,
        equality_estimate.threshold,
    )
end
