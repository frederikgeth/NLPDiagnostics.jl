function _hessian_failure(
    stage::Symbol,
    source::Symbol,
    affected::EntityRef,
    exception,
)
    return EvaluationFailure(
        stage,
        source,
        affected,
        string(typeof(exception)),
        sprint(showerror, exception),
    )
end

function _ordinary_lagrangian_value(
    model::MOI.ModelLike,
    model_snapshot::ModelSnapshot,
    functions,
    values::Vector{T},
    point::EvaluationPoint{T},
    objective_weight::T,
    ordinary_multipliers::Vector{T},
    skip_objective::Bool,
) where {T}
    lookup = Dict(
        variable => values[index] for
        (index, variable) in enumerate(point.variables)
    )
    total = zero(T)
    if !skip_objective &&
       !isnothing(model_snapshot.objective) &&
       !iszero(objective_weight)
        total += objective_weight * MOI.Utilities.eval_variables(
            variable -> lookup[variable],
            model,
            model_snapshot.objective.function_value,
        )
    end
    for (multiplier, function_value) in
        zip(ordinary_multipliers, functions)
        iszero(multiplier) && continue
        total += multiplier * MOI.Utilities.eval_variables(
            variable -> lookup[variable],
            model,
            function_value,
        )
    end
    return convert(T, total)
end

function _finite_difference_hessian(
    value_function,
    point::EvaluationPoint{T},
    relative_step::T,
) where {T}
    variables = copy(point.values)
    variable_count = length(variables)
    steps = [
        relative_step * max(abs(value), one(T)) for value in variables
    ]
    cache = Dict{Tuple,T}()
    evaluate = values -> get!(cache, Tuple(values)) do
        result = value_function(values)
        isfinite(result) ||
            throw(DomainError(result, "non-finite Lagrangian value"))
        return result
    end
    center = evaluate(variables)
    entries = HessianEntry{T}[]
    for row in 1:variable_count
        plus = copy(variables)
        minus = copy(variables)
        plus[row] += steps[row]
        minus[row] -= steps[row]
        diagonal =
            (evaluate(plus) - 2 * center + evaluate(minus)) / steps[row]^2
        push!(entries, HessianEntry{T}(row, row, diagonal))
        for column in 1:(row - 1)
            plus_plus = copy(variables)
            plus_minus = copy(variables)
            minus_plus = copy(variables)
            minus_minus = copy(variables)
            plus_plus[row] += steps[row]
            plus_plus[column] += steps[column]
            plus_minus[row] += steps[row]
            plus_minus[column] -= steps[column]
            minus_plus[row] -= steps[row]
            minus_plus[column] += steps[column]
            minus_minus[row] -= steps[row]
            minus_minus[column] -= steps[column]
            mixed = (
                evaluate(plus_plus) -
                evaluate(plus_minus) -
                evaluate(minus_plus) +
                evaluate(minus_minus)
            ) / (4 * steps[row] * steps[column])
            push!(entries, HessianEntry{T}(row, column, mixed))
        end
    end
    return entries
end

"""
    evaluate_lagrangian_hessian(model, point; ...)

Evaluate the Hessian of
`objective_weight * objective + dot(constraint_multipliers, constraints)`.

MOI `NLPBlock` and nonlinear-oracle Hessian callbacks are used exactly when
available. Ordinary symbolic functions use a dense finite-difference fallback,
guarded by `max_finite_difference_variables`.
"""
function evaluate_lagrangian_hessian(
    model::MOI.ModelLike,
    point::EvaluationPoint{T};
    objective_weight::Real = one(T),
    constraint_multipliers::Union{Nothing,AbstractVector{<:Real}} = nothing,
    relative_step::Real = eps(T)^(one(T) / 4),
    max_finite_difference_variables::Integer = 100,
) where {T<:AbstractFloat}
    evaluation = evaluate_numerical(model, point)
    constraint_count = length(evaluation.constraint_sources)
    multipliers = isnothing(constraint_multipliers) ?
                  zeros(T, constraint_count) :
                  T.(constraint_multipliers)
    length(multipliers) == constraint_count || throw(
        DimensionMismatch(
            "constraint multiplier length $(length(multipliers)) does not match evaluated row count $constraint_count",
        ),
    )
    converted_objective_weight = convert(T, objective_weight)
    converted_step = convert(T, relative_step)
    converted_step > zero(T) ||
        throw(ArgumentError("relative_step must be positive"))
    max_finite_difference_variables >= 0 || throw(
        ArgumentError("max_finite_difference_variables must be nonnegative"),
    )

    model_snapshot = snapshot(model)
    functions, sources = _ordinary_rows(model_snapshot)
    block = _optional_nlp_block(model)
    entries = HessianEntry{T}[]
    methods = Symbol[]
    failures = EvaluationFailure[]
    complete = true
    ordinary_count = length(functions)
    ordinary_multipliers = multipliers[1:ordinary_count]
    ordinary_objective =
        !isnothing(model_snapshot.objective) &&
        (isnothing(block) || !block.has_objective) &&
        !iszero(converted_objective_weight)
    ordinary_constraints = any(!iszero, ordinary_multipliers)
    if ordinary_objective || ordinary_constraints
        source = ordinary_objective ?
                 _objective_ref(model_snapshot.objective.function_value) :
                 first(sources)
        if length(point.variables) > max_finite_difference_variables
            complete = false
            push!(
                failures,
                EvaluationFailure(
                    :lagrangian_hessian,
                    :symbolic,
                    source,
                    "DenseWorkGuardExceeded",
                    "$(length(point.variables)) variables exceed finite-difference guard $max_finite_difference_variables",
                ),
            )
        else
            value_function = values -> _ordinary_lagrangian_value(
                model,
                model_snapshot,
                functions,
                values,
                point,
                converted_objective_weight,
                ordinary_multipliers,
                !isnothing(block) && block.has_objective,
            )
            try
                append!(
                    entries,
                    _finite_difference_hessian(
                        value_function,
                        point,
                        converted_step,
                    ),
                )
                push!(methods, :finite_difference_function_values)
            catch exception
                complete = false
                push!(
                    failures,
                    _hessian_failure(
                        :lagrangian_hessian,
                        :symbolic,
                        source,
                        exception,
                    ),
                )
            end
        end
    end

    offset = ordinary_count
    if !isnothing(block)
        block_count = length(block.constraint_bounds)
        block_multipliers = multipliers[(offset + 1):(offset + block_count)]
        block_weight =
            block.has_objective ? converted_objective_weight : zero(T)
        needs_block =
            !iszero(block_weight) || any(!iszero, block_multipliers)
        if needs_block
            evaluator = block.evaluator
            source =
                EntityRef(:nlp_block, 1; function_type = string(typeof(evaluator)))
            if :Hess in evaluator_capabilities(evaluator).available_features
                try
                    MOI.initialize(evaluator, [:Hess])
                    structure = MOI.hessian_lagrangian_structure(evaluator)
                    values = zeros(T, length(structure))
                    MOI.eval_hessian_lagrangian(
                        evaluator,
                        values,
                        copy(point.values),
                        block_weight,
                        block_multipliers,
                    )
                    for ((row, column), value) in zip(structure, values)
                        push!(
                            entries,
                            HessianEntry{T}(row, column, value),
                        )
                    end
                    push!(methods, :exact_nlp_evaluator)
                catch exception
                    complete = false
                    push!(
                        failures,
                        _hessian_failure(
                            :lagrangian_hessian,
                            :nlp_block,
                            source,
                            exception,
                        ),
                    )
                end
            else
                complete = false
                push!(
                    failures,
                    EvaluationFailure(
                        :lagrangian_hessian,
                        :nlp_block,
                        source,
                        "HessianUnavailable",
                        "the evaluator does not advertise :Hess",
                    ),
                )
            end
        end
        offset += block_count
    end

    point_columns =
        Dict(variable => index for (index, variable) in enumerate(point.variables))
    for constraint in model_snapshot.constraints
        oracle = constraint.set_value
        oracle isa MOI.VectorNonlinearOracle || continue
        oracle_count = oracle.output_dimension
        oracle_multipliers =
            multipliers[(offset + 1):(offset + oracle_count)]
        offset += oracle_count
        any(!iszero, oracle_multipliers) || continue
        source = _constraint_ref(constraint)
        input_function = constraint.function_value
        if !(input_function isa MOI.VectorOfVariables)
            complete = false
            push!(
                failures,
                EvaluationFailure(
                    :lagrangian_hessian,
                    :nonlinear_oracle,
                    source,
                    "UnsupportedOracleInputFunction",
                    "oracle Hessian composition requires MOI.VectorOfVariables inputs",
                ),
            )
        elseif isnothing(oracle.eval_hessian_lagrangian)
            complete = false
            push!(
                failures,
                EvaluationFailure(
                    :lagrangian_hessian,
                    :nonlinear_oracle,
                    source,
                    "HessianUnavailable",
                    "the nonlinear oracle has no Hessian callback",
                ),
            )
        else
            inputs = [
                point.values[point_columns[variable]] for
                variable in input_function.variables
            ]
            try
                values = zeros(T, length(oracle.hessian_lagrangian_structure))
                oracle.eval_hessian_lagrangian(
                    values,
                    inputs,
                    oracle_multipliers,
                )
                for ((input_row, input_column), value) in
                    zip(oracle.hessian_lagrangian_structure, values)
                    row =
                        point_columns[input_function.variables[input_row]]
                    column =
                        point_columns[input_function.variables[input_column]]
                    push!(entries, HessianEntry{T}(row, column, value))
                end
                push!(methods, :exact_nonlinear_oracle)
            catch exception
                complete = false
                push!(
                    failures,
                    _hessian_failure(
                        :lagrangian_hessian,
                        :nonlinear_oracle,
                        source,
                        exception,
                    ),
                )
            end
        end
    end
    return HessianEvaluation{T}(
        point,
        converted_objective_weight,
        multipliers,
        entries,
        unique(methods),
        complete,
        failures,
    )
end

function evaluate_lagrangian_hessian(
    model::MOI.ModelLike,
    values::Union{
        AbstractVector{<:Real},
        AbstractDict{MOI.VariableIndex,<:Real},
    };
    label::AbstractString = "user",
    kwargs...,
)
    return evaluate_lagrangian_hessian(
        model,
        evaluation_point(model, values; label = label);
        kwargs...,
    )
end

function _combined_hessian_matrix(
    hessian::HessianEvaluation{T},
) where {T}
    variable_count = length(hessian.point.variables)
    combined = Dict{Tuple{Int,Int},T}()
    for entry in hessian.entries
        key = minmax(entry.row, entry.column)
        combined[key] = get(combined, key, zero(T)) + entry.value
    end
    matrix = zeros(T, variable_count, variable_count)
    for ((row, column), value) in combined
        matrix[row, column] = value
        matrix[column, row] = value
    end
    return matrix
end

function _unavailable_reduced_hessian(
    evaluation::NumericalEvaluation{T},
    active_rows::Vector{Int},
    reason::AbstractString,
) where {T}
    return ReducedHessianAnalysis{T}(
        false,
        String(reason),
        evaluation.point,
        active_rows,
        0,
        0,
        zero(T),
        zero(T),
        T[],
        0,
        0,
        0,
        nothing,
        zeros(T, length(evaluation.point.variables), 0),
    )
end

"""
    reduced_hessian_analysis(evaluation, hessian; active_rows, ...)

Project the Hessian into the nullspace of the explicitly selected Jacobian
rows and report the local spectrum and inertia.
"""
function reduced_hessian_analysis(
    evaluation::NumericalEvaluation{T},
    hessian::HessianEvaluation{T};
    active_rows::AbstractVector{<:Integer},
    jacobian_relative_tolerance::Real =
        max(
            length(active_rows),
            length(evaluation.point.variables),
            1,
        ) * eps(T),
    eigenvalue_relative_tolerance::Real =
        max(length(evaluation.point.variables), 1) * eps(T),
    max_dense_entries::Integer = 4_000_000,
) where {T<:AbstractFloat}
    evaluation.point == hessian.point ||
        throw(ArgumentError("Jacobian and Hessian points differ"))
    selected_rows = Int.(active_rows)
    length(unique(selected_rows)) == length(selected_rows) ||
        throw(ArgumentError("active_rows must be unique"))
    row_count = length(evaluation.constraint_sources)
    all(row -> 1 <= row <= row_count, selected_rows) ||
        throw(BoundsError(1:row_count, selected_rows))
    hessian.complete || return _unavailable_reduced_hessian(
        evaluation,
        selected_rows,
        "Hessian-of-the-Lagrangian evaluation is incomplete",
    )
    incomplete = filter(
        row ->
            evaluation.jacobian_row_methods[row] in
            _JACOBIAN_INCOMPLETE_METHODS,
        selected_rows,
    )
    isempty(incomplete) || return _unavailable_reduced_hessian(
        evaluation,
        selected_rows,
        "active Jacobian rows $(join(incomplete, ',')) are incomplete",
    )
    variable_count = length(evaluation.point.variables)
    required_entries =
        length(selected_rows) * variable_count + variable_count^2
    required_entries <= max_dense_entries ||
        return _unavailable_reduced_hessian(
            evaluation,
            selected_rows,
            "dense reduced-Hessian work requires $required_entries entries, exceeding guard $max_dense_entries",
        )
    full_jacobian = _combined_jacobian_matrix(evaluation)
    active_jacobian = full_jacobian[selected_rows, :]
    all(isfinite, active_jacobian) ||
        return _unavailable_reduced_hessian(
            evaluation,
            selected_rows,
            "active Jacobian contains non-finite entries",
        )
    hessian_matrix = _combined_hessian_matrix(hessian)
    all(isfinite, hessian_matrix) ||
        return _unavailable_reduced_hessian(
            evaluation,
            selected_rows,
            "Hessian contains non-finite entries",
        )

    jacobian_tolerance = convert(T, jacobian_relative_tolerance)
    eigenvalue_tolerance = convert(T, eigenvalue_relative_tolerance)
    jacobian_tolerance >= zero(T) ||
        throw(ArgumentError("jacobian_relative_tolerance must be nonnegative"))
    eigenvalue_tolerance >= zero(T) ||
        throw(ArgumentError("eigenvalue_relative_tolerance must be nonnegative"))
    if isempty(selected_rows)
        jacobian_rank = 0
        jacobian_threshold = zero(T)
        tangent_basis = Matrix{T}(I, variable_count, variable_count)
    else
        factorization = svd(active_jacobian; full = true)
        maximum_singular =
            maximum(factorization.S; init = zero(T))
        jacobian_threshold = jacobian_tolerance * maximum_singular
        jacobian_rank =
            count(value -> value > jacobian_threshold, factorization.S)
        tangent_basis =
            Matrix(factorization.V[:, (jacobian_rank + 1):variable_count])
    end
    tangent_dimension = size(tangent_basis, 2)
    eigenvalues = tangent_dimension == 0 ?
                  T[] :
                  T.(eigvals(Symmetric(
                      transpose(tangent_basis) *
                      hessian_matrix *
                      tangent_basis,
                  )))
    maximum_eigenvalue =
        maximum(abs, eigenvalues; init = zero(T))
    eigenvalue_threshold =
        eigenvalue_tolerance * maximum_eigenvalue
    positive = count(value -> value > eigenvalue_threshold, eigenvalues)
    negative = count(value -> value < -eigenvalue_threshold, eigenvalues)
    zero_count = tangent_dimension - positive - negative
    condition_estimate = if tangent_dimension == 0
        nothing
    elseif negative > 0 || zero_count > 0
        T(Inf)
    else
        maximum(abs, eigenvalues) / minimum(abs, eigenvalues)
    end
    return ReducedHessianAnalysis{T}(
        true,
        nothing,
        evaluation.point,
        selected_rows,
        jacobian_rank,
        tangent_dimension,
        jacobian_threshold,
        eigenvalue_threshold,
        eigenvalues,
        positive,
        negative,
        zero_count,
        condition_estimate,
        tangent_basis,
    )
end
