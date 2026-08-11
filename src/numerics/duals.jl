"""One solver-reported scalar constraint-side multiplier at an exact endpoint."""
struct SolverConstraintSideDual{T<:AbstractFloat}
    row::Int
    source::EntityRef
    side::Symbol
    multiplier::T
    value::Union{Missing,T}
    bound::Union{Nothing,T}
    slack::Union{Nothing,T}
    provenance::Symbol
end

"""
Read-only solver dual evidence aligned with `NumericalEvaluation` rows.

`row_multipliers` use NLPDiagnostics' Lagrangian convention
`objective_weight * f + dot(row_multipliers, g)`. MOI's conic dual is therefore
negated. `sides` retain canonical nonnegative lower/upper multipliers where a
scalar-bound set admits an exact decomposition.
"""
struct SolverDualSnapshot{T<:AbstractFloat}
    available::Bool
    reason::Union{Nothing,String}
    point::Union{Nothing,EvaluationPoint{T}}
    result_index::Int
    dual_status::String
    objective_weight::T
    row_multipliers::Vector{T}
    sides::Vector{SolverConstraintSideDual{T}}
    side_decomposition_complete::Bool
    maximum_point_difference::Union{Nothing,T}
    failures::Vector{String}
end

function _solver_dual_unavailable(
    evaluation::NumericalEvaluation{T},
    result_index::Int,
    reason::AbstractString;
    point::Union{Nothing,EvaluationPoint{T}} = nothing,
    dual_status::AbstractString = "unknown",
    objective_weight::T = zero(T),
    maximum_point_difference::Union{Nothing,T} = nothing,
    failures::Vector{String} = String[],
) where {T<:AbstractFloat}
    return SolverDualSnapshot{T}(
        false, String(reason), point, result_index, String(dual_status),
        objective_weight, T[], SolverConstraintSideDual{T}[], false,
        maximum_point_difference, failures,
    )
end

function _solver_dual_status(model, result_index)
    return try
        string(MOI.get(model, MOI.DualStatus(result_index)))
    catch exception
        "unavailable ($(typeof(exception)))"
    end
end

function _dual_components(raw, row_count::Int, ::Type{T}) where {T<:AbstractFloat}
    values = if row_count == 1 && raw isa Real
        T[raw]
    elseif raw isa AbstractVector || raw isa Tuple
        T.(collect(raw))
    else
        throw(ArgumentError(
            "dual value $(typeof(raw)) cannot represent $row_count scalar rows",
        ))
    end
    length(values) == row_count || throw(DimensionMismatch(
        "dual component count $(length(values)) does not match $row_count scalar rows",
    ))
    all(isfinite, values) || throw(ArgumentError(
        "solver dual contains non-finite components",
    ))
    return values
end

function _normalized_finite_bounds(bounds, ::Type{T}) where {T<:AbstractFloat}
    isnothing(bounds) && return nothing
    lower_raw, upper_raw = bounds
    lower = isnothing(lower_raw) || !isfinite(lower_raw) ? nothing : T(lower_raw)
    upper = isnothing(upper_raw) || !isfinite(upper_raw) ? nothing : T(upper_raw)
    return lower, upper
end

function _side_slack(value, bound, side, ::Type{T}) where {T<:AbstractFloat}
    if ismissing(value) || isnothing(bound) || !isfinite(value)
        return nothing
    end
    converted = T(value)
    return side == :lower ? converted - bound :
           side == :upper ? bound - converted : converted - bound
end

function _append_solver_dual_row!(
    row_multipliers::Vector{T},
    sides::Vector{SolverConstraintSideDual{T}},
    failures::Vector{String},
    row::Int,
    source::EntityRef,
    value,
    raw_dual::T,
    raw_bounds,
    provenance::Symbol,
) where {T<:AbstractFloat}
    # MOI uses a0 - A'y = 0 for minimization. NLPDiagnostics uses
    # objective_weight*f + lambda'g, hence lambda = -y for every row.
    push!(row_multipliers, -raw_dual)
    bounds = _normalized_finite_bounds(raw_bounds, T)
    if isnothing(bounds)
        push!(failures,
            "row $row ($(source.kind)) has no scalar-bound dual decomposition")
        return false
    end
    lower, upper = bounds
    converted_value = ismissing(value) ? missing : T(value)
    if !ismissing(converted_value) && !isfinite(converted_value)
        converted_value = missing
    end
    if !isnothing(lower) && !isnothing(upper) && lower == upper
        push!(sides, SolverConstraintSideDual{T}(
            row, source, :equality, -raw_dual, converted_value, lower,
            _side_slack(converted_value, lower, :equality, T), provenance,
        ))
    elseif !isnothing(lower) && !isnothing(upper)
        # An interval constraint exposes one aggregate MOI dual. Its sign gives
        # the minimum-support lower/upper representative; simultaneous endpoint
        # multipliers are not identifiable from that aggregate.
        lower_multiplier = max(raw_dual, zero(T))
        upper_multiplier = max(-raw_dual, zero(T))
        push!(sides, SolverConstraintSideDual{T}(
            row, source, :lower, lower_multiplier, converted_value, lower,
            _side_slack(converted_value, lower, :lower, T),
            :moi_aggregate_sign_split,
        ))
        push!(sides, SolverConstraintSideDual{T}(
            row, source, :upper, upper_multiplier, converted_value, upper,
            _side_slack(converted_value, upper, :upper, T),
            :moi_aggregate_sign_split,
        ))
    elseif !isnothing(lower)
        push!(sides, SolverConstraintSideDual{T}(
            row, source, :lower, raw_dual, converted_value, lower,
            _side_slack(converted_value, lower, :lower, T), provenance,
        ))
    elseif !isnothing(upper)
        push!(sides, SolverConstraintSideDual{T}(
            row, source, :upper, -raw_dual, converted_value, upper,
            _side_slack(converted_value, upper, :upper, T), provenance,
        ))
    elseif !iszero(raw_dual)
        push!(failures, "free row $row reports a nonzero MOI dual")
        return false
    end
    return true
end

function _append_constraint_duals!(
    model,
    constraint::ConstraintRecord,
    evaluation::NumericalEvaluation{T},
    result_index::Int,
    row::Int,
    row_multipliers,
    sides,
    failures,
) where {T<:AbstractFloat}
    functions = _scalar_rows(constraint.function_value)
    row_count = length(functions)
    raw = MOI.get(model, MOI.ConstraintDual(result_index), constraint.index)
    duals = _dual_components(raw, row_count, T)
    bounds = _scalar_set_bounds(constraint.set_value, row_count)
    complete = true
    for local_row in 1:row_count
        global_row = row + local_row - 1
        expected = _constraint_ref(
            constraint; row=row_count == 1 ? nothing : local_row,
        )
        evaluation.constraint_sources[global_row] == expected || throw(ArgumentError(
            "solver-dual row order does not match NumericalEvaluation at row $global_row",
        ))
        complete &= _append_solver_dual_row!(
            row_multipliers, sides, failures, global_row, expected,
            evaluation.constraint_values[global_row], duals[local_row],
            bounds[local_row], :moi_constraint_dual,
        )
    end
    return row + row_count, complete
end

"""
    solver_dual_snapshot(model, evaluation; result_index=1, ...)

Read public MOI endpoint duals and align them with an evaluation made at that
same solver result. The method never solves or modifies the model. A point
mismatch, missing result, missing dual row, or non-finite dual makes the
snapshot unavailable rather than attaching duals to the wrong derivatives.
"""
function solver_dual_snapshot(
    model::MOI.ModelLike,
    evaluation::NumericalEvaluation{T};
    result_index::Integer = 1,
    point_absolute_tolerance::Real = 10eps(T),
    point_relative_tolerance::Real = 10eps(T),
) where {T<:AbstractFloat}
    result_index >= 1 || throw(ArgumentError("result_index must be positive"))
    point_absolute_tolerance >= 0 || throw(ArgumentError(
        "point_absolute_tolerance must be nonnegative",
    ))
    point_relative_tolerance >= 0 || throw(ArgumentError(
        "point_relative_tolerance must be nonnegative",
    ))
    index = Int(result_index)
    _validate_evaluation_variable_order(model, evaluation)
    endpoint = solver_result_point(
        model; result_index=index, label="solver-result-$index",
    )
    isnothing(endpoint) && return _solver_dual_unavailable(
        evaluation, index, "the selected result has no complete primal point",
    )
    endpoint.variables == evaluation.point.variables ||
        return _solver_dual_unavailable(
            evaluation, index, "solver and evaluation variable orders differ";
            point=endpoint,
        )
    differences = abs.(T.(endpoint.values) .- T.(evaluation.point.values))
    maximum_difference = isempty(differences) ? zero(T) : maximum(differences)
    point_matches = all(zip(endpoint.values, evaluation.point.values)) do (a, b)
        isapprox(a, b; atol=point_absolute_tolerance,
            rtol=point_relative_tolerance)
    end
    point_matches || return _solver_dual_unavailable(
        evaluation, index,
        "evaluation coordinates do not match the selected solver result";
        point=endpoint, maximum_point_difference=maximum_difference,
    )
    status = _solver_dual_status(model, index)
    occursin("NO_SOLUTION", status) && return _solver_dual_unavailable(
        evaluation, index, "MOI reports no dual solution";
        point=endpoint, dual_status=status,
        maximum_point_difference=maximum_difference,
    )
    objective_weight = _objective_stationarity_weight(model, T)
    model_snapshot = snapshot(model)
    row_multipliers = T[]
    sides = SolverConstraintSideDual{T}[]
    failures = String[]
    side_complete = true
    row = 1
    try
        for constraint in model_snapshot.constraints
            constraint.set_value isa MOI.VectorNonlinearOracle && continue
            row, complete = _append_constraint_duals!(
                model, constraint, evaluation, index, row,
                row_multipliers, sides, failures,
            )
            side_complete &= complete
        end
        block = _optional_nlp_block(model)
        if !isnothing(block)
            raw = MOI.get(model, MOI.NLPBlockDual(index))
            duals = _dual_components(raw, length(block.constraint_bounds), T)
            for local_row in eachindex(duals)
                source = _nlp_constraint_ref(local_row, block.evaluator)
                evaluation.constraint_sources[row] == source || throw(ArgumentError(
                    "NLP-block dual row order does not match NumericalEvaluation at row $row",
                ))
                bound = block.constraint_bounds[local_row]
                side_complete &= _append_solver_dual_row!(
                    row_multipliers, sides, failures, row, source,
                    evaluation.constraint_values[row], duals[local_row],
                    (bound.lower, bound.upper), :moi_nlp_block_dual,
                )
                row += 1
            end
        end
        for constraint in model_snapshot.constraints
            oracle = constraint.set_value
            oracle isa MOI.VectorNonlinearOracle || continue
            raw = MOI.get(model, MOI.ConstraintDual(index), constraint.index)
            duals = _dual_components(raw, oracle.output_dimension, T)
            for local_row in eachindex(duals)
                source = _constraint_ref(constraint; row=local_row)
                evaluation.constraint_sources[row] == source || throw(ArgumentError(
                    "oracle dual row order does not match NumericalEvaluation at row $row",
                ))
                side_complete &= _append_solver_dual_row!(
                    row_multipliers, sides, failures, row, source,
                    evaluation.constraint_values[row], duals[local_row],
                    (oracle.l[local_row], oracle.u[local_row]),
                    :moi_constraint_dual,
                )
                row += 1
            end
        end
    catch exception
        push!(failures, sprint(showerror, exception))
        return _solver_dual_unavailable(
            evaluation, index,
            "one or more public MOI dual values could not be aligned";
            point=endpoint, dual_status=status, objective_weight,
            maximum_point_difference=maximum_difference, failures,
        )
    end
    row - 1 == length(evaluation.constraint_sources) ||
        return _solver_dual_unavailable(
            evaluation, index,
            "solver dual row count does not match NumericalEvaluation";
            point=endpoint, dual_status=status, objective_weight,
            maximum_point_difference=maximum_difference, failures,
        )
    return SolverDualSnapshot{T}(
        true, nothing, endpoint, index, status, objective_weight,
        row_multipliers, sides, side_complete, maximum_difference, failures,
    )
end

function solver_dual_snapshot_data(snapshot::SolverDualSnapshot)
    return Dict{String,Any}(
        "schema_version" => "solver-dual-snapshot-v1",
        "available" => snapshot.available,
        "reason" => snapshot.reason,
        "result_index" => snapshot.result_index,
        "dual_status" => snapshot.dual_status,
        "objective_weight" => snapshot.objective_weight,
        "row_multipliers" => copy(snapshot.row_multipliers),
        "side_decomposition_complete" => snapshot.side_decomposition_complete,
        "maximum_point_difference" => snapshot.maximum_point_difference,
        "failures" => copy(snapshot.failures),
        "sides" => [Dict{String,Any}(
            "row" => side.row,
            "source" => string(side.source),
            "side" => string(side.side),
            "multiplier" => side.multiplier,
            "value" => ismissing(side.value) ? nothing : side.value,
            "bound" => side.bound,
            "slack" => side.slack,
            "provenance" => string(side.provenance),
        ) for side in snapshot.sides],
        "qualification" => Dict{String,Any}(
            "moi_to_lagrangian_sign" => "row_multiplier = -MOI.ConstraintDual",
            "interval_decomposition" =>
                "minimum-support sign split of the aggregate MOI dual",
            "does_not_establish" => [
                "multiplier uniqueness",
                "constraint qualification",
                "solver-internal scaling semantics",
                "optimality",
            ],
        ),
    )
end

"""Check model-coordinate dual feasibility and side complementarity."""
function solver_complementarity_report(
    snapshot::SolverDualSnapshot;
    dual_absolute_tolerance::Real = 1.0e-7,
    complementarity_absolute_tolerance::Real = 1.0e-7,
)
    dual_absolute_tolerance >= 0 || throw(ArgumentError(
        "dual_absolute_tolerance must be nonnegative",
    ))
    complementarity_absolute_tolerance >= 0 || throw(ArgumentError(
        "complementarity_absolute_tolerance must be nonnegative",
    ))
    available = snapshot.available && snapshot.side_decomposition_complete
    if !available
        return Dict{String,Any}(
            "report_version" => "solver-complementarity-v1",
            "available" => false,
            "acceptance_passed" => nothing,
            "reason" => snapshot.available ?
                "one or more rows lack scalar side semantics" : snapshot.reason,
            "sides" => Dict{String,Any}[],
        )
    end
    records = Dict{String,Any}[]
    passed = true
    for side in snapshot.sides
        side.side == :equality && continue
        dual_violation = max(-side.multiplier, zero(side.multiplier))
        complementarity = isnothing(side.slack) ? nothing :
            abs(side.multiplier * side.slack)
        side_passed = !isnothing(complementarity) &&
            dual_violation <= dual_absolute_tolerance &&
            complementarity <= complementarity_absolute_tolerance
        passed &= side_passed
        push!(records, Dict{String,Any}(
            "row" => side.row,
            "side" => string(side.side),
            "multiplier" => side.multiplier,
            "slack" => side.slack,
            "dual_violation" => dual_violation,
            "complementarity_residual" => complementarity,
            "passed" => side_passed,
        ))
    end
    return Dict{String,Any}(
        "report_version" => "solver-complementarity-v1",
        "available" => true,
        "acceptance_passed" => passed,
        "dual_absolute_tolerance" => Float64(dual_absolute_tolerance),
        "complementarity_absolute_tolerance" =>
            Float64(complementarity_absolute_tolerance),
        "side_count" => length(records),
        "sides" => records,
        "qualification" => Dict{String,Any}(
            "coordinates" => "model",
            "claim" => "endpoint scalar-side dual feasibility and complementarity",
            "does_not_establish" => ["optimality", "multiplier uniqueness"],
        ),
    )
end
