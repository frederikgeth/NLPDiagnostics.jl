const _NUMERICAL_FEATURE_ORDER = [:Grad, :Jac, :Hess, :JacVec, :HessVec, :ExprGraph]

function evaluator_capabilities(evaluator::MOI.AbstractNLPEvaluator)
    available = try
        collect(MOI.features_available(evaluator))
    catch
        Symbol[]
    end
    sort!(
        unique!(available);
        by = feature -> something(
            findfirst(==(feature), _NUMERICAL_FEATURE_ORDER),
            length(_NUMERICAL_FEATURE_ORDER) + 1,
        ),
    )
    requested = filter(feature -> feature in available, [:Grad, :Jac])
    return EvaluatorCapabilities(
        :nlp_block,
        string(typeof(evaluator)),
        true,
        true,
        available,
        requested,
    )
end

function _optional_nlp_block(model::MOI.ModelLike)
    try
        return MOI.get(model, MOI.NLPBlock())
    catch
        return nothing
    end
end

function _ordinary_function_capability(model_snapshot::ModelSnapshot)
    has_constraints = any(
        !(constraint.set_value isa MOI.VectorNonlinearOracle) for
        constraint in model_snapshot.constraints
    )
    has_objective = !isnothing(model_snapshot.objective)
    if !has_constraints && !has_objective
        return nothing
    end
    return EvaluatorCapabilities(
        :symbolic,
        "MOI.Utilities.eval_variables",
        has_objective,
        has_constraints,
        [
            :Value,
            :ExactAffineQuadraticGrad,
            :ExactAffineQuadraticJac,
            :FiniteDifferenceGrad,
            :FiniteDifferenceJac,
        ],
        [
            :Value,
            :ExactAffineQuadraticGrad,
            :ExactAffineQuadraticJac,
            :FiniteDifferenceGrad,
            :FiniteDifferenceJac,
        ],
    )
end

function _oracle_capabilities(model_snapshot::ModelSnapshot)
    capabilities = EvaluatorCapabilities[]
    for constraint in model_snapshot.constraints
        set = constraint.set_value
        set isa MOI.VectorNonlinearOracle || continue
        features = [:Value, :Jac]
        if !isnothing(set.eval_hessian_lagrangian)
            push!(features, :Hess)
        end
        push!(
            capabilities,
            EvaluatorCapabilities(
                :nonlinear_oracle,
                string(constraint.index),
                false,
                true,
                features,
                [:Value, :Jac],
            ),
        )
    end
    return capabilities
end

"""
    evaluator_capabilities(model::MOI.ModelLike)

Discover numerical sources without evaluating the model or initializing an
`AbstractNLPEvaluator`.
"""
function evaluator_capabilities(model::MOI.ModelLike)
    model_snapshot = snapshot(model)
    capabilities = EvaluatorCapabilities[]
    symbolic = _ordinary_function_capability(model_snapshot)
    isnothing(symbolic) || push!(capabilities, symbolic)
    block = _optional_nlp_block(model)
    isnothing(block) || push!(capabilities, evaluator_capabilities(block.evaluator))
    append!(capabilities, _oracle_capabilities(model_snapshot))
    return capabilities
end

_objective_ref(function_value; source::Symbol = :objective) = EntityRef(
    source,
    1;
    function_type = string(typeof(function_value)),
)

function _nlp_constraint_ref(row::Integer, evaluator)
    return EntityRef(
        :nlp_constraint,
        row;
        function_type = string(typeof(evaluator)),
        set_type = "MOI.NLPBoundsPair",
    )
end

function _point_lookup(point::EvaluationPoint)
    return Dict(variable => point.values[i] for (i, variable) in enumerate(point.variables))
end

function _scalar_rows(function_value)
    if function_value isa MOI.AbstractVectorFunction
        return MOI.Utilities.scalarize(function_value)
    end
    return Any[function_value]
end

function _ordinary_rows(model_snapshot::ModelSnapshot)
    functions = Any[]
    sources = EntityRef[]
    for constraint in model_snapshot.constraints
        constraint.set_value isa MOI.VectorNonlinearOracle && continue
        rows = try
            _scalar_rows(constraint.function_value)
        catch
            continue
        end
        for (row, function_value) in enumerate(rows)
            push!(functions, function_value)
            push!(
                sources,
                _constraint_ref(
                    constraint;
                    row = length(rows) == 1 ? nothing : row,
                ),
            )
        end
    end
    return functions, sources
end

function _safe_value(
    model::MOI.ModelLike,
    function_value,
    lookup,
    source::EntityRef,
    stage::Symbol,
    failures::Vector{EvaluationFailure},
)
    try
        return MOI.Utilities.eval_variables(
            variable -> lookup[variable],
            model,
            function_value,
        )
    catch exception
        push!(
            failures,
            EvaluationFailure(
                stage,
                :symbolic,
                source,
                string(typeof(exception)),
                sprint(showerror, exception),
            ),
        )
        return missing
    end
end

function _convert_value(::Type{T}, value) where {T<:AbstractFloat}
    ismissing(value) && return missing
    return convert(T, value)
end

function _exact_symbolic_gradient(
    function_value::MOI.VariableIndex,
    lookup,
    ::Type{T},
) where {T<:AbstractFloat}
    return Dict(function_value => one(T))
end

function _exact_symbolic_gradient(
    function_value::MOI.ScalarAffineFunction,
    lookup,
    ::Type{T},
) where {T<:AbstractFloat}
    gradient = Dict{MOI.VariableIndex,T}()
    for term in function_value.terms
        gradient[term.variable] =
            get(gradient, term.variable, zero(T)) + convert(T, term.coefficient)
    end
    return gradient
end

function _exact_symbolic_gradient(
    function_value::MOI.ScalarQuadraticFunction,
    lookup,
    ::Type{T},
) where {T<:AbstractFloat}
    gradient = Dict{MOI.VariableIndex,T}()
    for term in function_value.affine_terms
        gradient[term.variable] =
            get(gradient, term.variable, zero(T)) + convert(T, term.coefficient)
    end
    for term in function_value.quadratic_terms
        coefficient = convert(T, term.coefficient)
        variable_1 = term.variable_1
        variable_2 = term.variable_2
        if variable_1 == variable_2
            gradient[variable_1] =
                get(gradient, variable_1, zero(T)) +
                coefficient * lookup[variable_1]
        else
            gradient[variable_1] =
                get(gradient, variable_1, zero(T)) +
                coefficient * lookup[variable_2]
            gradient[variable_2] =
                get(gradient, variable_2, zero(T)) +
                coefficient * lookup[variable_1]
        end
    end
    return gradient
end

_exact_symbolic_gradient(function_value, lookup, ::Type{T}) where {T} = nothing

function _finite_difference_derivative(
    value_function,
    baseline,
    x::Vector{T},
    column::Int,
    relative_step::T,
) where {T<:AbstractFloat}
    step = relative_step * max(one(T), abs(x[column]))
    iszero(step) && (step = sqrt(eps(T)))
    forward_x = copy(x)
    backward_x = copy(x)
    forward_x[column] += step
    backward_x[column] -= step
    forward = try
        value_function(forward_x)
    catch
        missing
    end
    backward = try
        value_function(backward_x)
    catch
        missing
    end
    forward_usable = !ismissing(forward) && isfinite(forward)
    backward_usable = !ismissing(backward) && isfinite(backward)
    baseline_usable = !ismissing(baseline) && isfinite(baseline)
    if forward_usable && backward_usable
        return (forward - backward) / (2 * step)
    elseif forward_usable && baseline_usable
        return (forward - baseline) / step
    elseif backward_usable && baseline_usable
        return (baseline - backward) / step
    end
    return missing
end

function _evaluate_symbolic!(
    model::MOI.ModelLike,
    model_snapshot::ModelSnapshot,
    point::EvaluationPoint{T},
    objective_value,
    objective_source,
    objective_gradient,
    constraint_values,
    constraint_sources,
    jacobian_entries,
    jacobian_row_methods,
    failures;
    relative_step::T,
    skip_objective::Bool,
) where {T<:AbstractFloat}
    lookup = _point_lookup(point)
    if !skip_objective && !isnothing(model_snapshot.objective)
        function_value = model_snapshot.objective.function_value
        source = _objective_ref(function_value)
        raw_value = _safe_value(
            model,
            function_value,
            lookup,
            source,
            :objective_value,
            failures,
        )
        objective_value = _convert_value(T, raw_value)
        objective_source = source
        exact_gradient =
            _exact_symbolic_gradient(function_value, lookup, T)
        if isnothing(exact_gradient)
            value_function = values -> begin
                local_lookup = Dict(
                    variable => values[i] for
                    (i, variable) in enumerate(point.variables)
                )
                return MOI.Utilities.eval_variables(
                    variable -> local_lookup[variable],
                    model,
                    function_value,
                )
            end
            for column in eachindex(point.variables)
                derivative = _finite_difference_derivative(
                    value_function,
                    raw_value,
                    point.values,
                    column,
                    relative_step,
                )
                push!(objective_gradient, _convert_value(T, derivative))
            end
            if any(ismissing, objective_gradient)
                push!(
                    failures,
                    EvaluationFailure(
                        :objective_gradient,
                        :symbolic,
                        source,
                        "DerivativeUnavailable",
                        "central and one-sided finite differences failed",
                    ),
                )
            end
        else
            append!(
                objective_gradient,
                [
                    get(exact_gradient, variable, zero(T)) for
                    variable in point.variables
                ],
            )
        end
    end

    functions, sources = _ordinary_rows(model_snapshot)
    first_row = length(constraint_values) + 1
    raw_values = Any[]
    exact_gradients = Any[]
    for (function_value, source) in zip(functions, sources)
        raw_value = _safe_value(
            model,
            function_value,
            lookup,
            source,
            :constraint_value,
            failures,
        )
        push!(raw_values, raw_value)
        exact_gradient =
            _exact_symbolic_gradient(function_value, lookup, T)
        push!(exact_gradients, exact_gradient)
        push!(constraint_values, _convert_value(T, raw_value))
        push!(constraint_sources, source)
        push!(
            jacobian_row_methods,
            isnothing(exact_gradient) ?
            :central_finite_difference :
            :exact_symbolic,
        )
    end
    for (local_row, (function_value, source)) in enumerate(zip(functions, sources))
        global_row = first_row + local_row - 1
        exact_gradient = exact_gradients[local_row]
        if !isnothing(exact_gradient)
            for (column, variable) in enumerate(point.variables)
                haskey(exact_gradient, variable) || continue
                push!(
                    jacobian_entries,
                    JacobianEntry{T}(
                        global_row,
                        column,
                        exact_gradient[variable],
                    ),
                )
            end
            continue
        end
        support = variable_support(function_value)
        columns = if support.complete
            Set(support.variables)
        else
            Set(point.variables)
        end
        value_function = values -> begin
            local_lookup = Dict(
                variable => values[i] for
                (i, variable) in enumerate(point.variables)
            )
            return MOI.Utilities.eval_variables(
                variable -> local_lookup[variable],
                model,
                function_value,
            )
        end
        for (column, variable) in enumerate(point.variables)
            variable in columns || continue
            derivative = _finite_difference_derivative(
                value_function,
                raw_values[local_row],
                point.values,
                column,
                relative_step,
            )
            if ismissing(derivative)
                jacobian_row_methods[global_row] =
                    :partial_central_finite_difference
                push!(
                    failures,
                    EvaluationFailure(
                        :constraint_jacobian,
                        :symbolic,
                        source,
                        "DerivativeUnavailable",
                        "central and one-sided finite differences failed",
                    ),
                )
            else
                push!(
                    jacobian_entries,
                    JacobianEntry{T}(global_row, column, convert(T, derivative)),
                )
            end
        end
    end
    return objective_value, objective_source
end

function _evaluate_nlp_block!(
    block,
    point::EvaluationPoint{T},
    objective_value,
    objective_source,
    objective_gradient,
    constraint_values,
    constraint_sources,
    jacobian_entries,
    jacobian_row_methods,
    failures,
) where {T<:AbstractFloat}
    evaluator = block.evaluator
    capability = evaluator_capabilities(evaluator)
    try
        MOI.initialize(evaluator, copy(capability.requested_features))
    catch exception
        source = EntityRef(:nlp_block, 1; function_type = string(typeof(evaluator)))
        push!(
            failures,
            EvaluationFailure(
                :initialize,
                :nlp_block,
                source,
                string(typeof(exception)),
                sprint(showerror, exception),
            ),
        )
        return objective_value, objective_source
    end

    if block.has_objective
        source = _objective_ref(evaluator; source = :nlp_objective)
        try
            objective_value =
                convert(T, MOI.eval_objective(evaluator, copy(point.values)))
            objective_source = source
        catch exception
            objective_value = missing
            objective_source = source
            push!(
                failures,
                EvaluationFailure(
                    :objective_value,
                    :nlp_block,
                    source,
                    string(typeof(exception)),
                    sprint(showerror, exception),
                ),
            )
        end
        if :Grad in capability.requested_features
            gradient = zeros(T, length(point.variables))
            try
                MOI.eval_objective_gradient(
                    evaluator,
                    gradient,
                    copy(point.values),
                )
                append!(objective_gradient, gradient)
            catch exception
                append!(objective_gradient, fill(missing, length(point.variables)))
                push!(
                    failures,
                    EvaluationFailure(
                        :objective_gradient,
                        :nlp_block,
                        source,
                        string(typeof(exception)),
                        sprint(showerror, exception),
                    ),
                )
            end
        else
            append!(objective_gradient, fill(missing, length(point.variables)))
        end
    end

    row_count = length(block.constraint_bounds)
    first_row = length(constraint_values) + 1
    values = zeros(T, row_count)
    try
        MOI.eval_constraint(evaluator, values, copy(point.values))
        append!(constraint_values, values)
    catch exception
        append!(constraint_values, fill(missing, row_count))
        source = EntityRef(:nlp_block, 1; function_type = string(typeof(evaluator)))
        push!(
            failures,
            EvaluationFailure(
                :constraint_value,
                :nlp_block,
                source,
                string(typeof(exception)),
                sprint(showerror, exception),
            ),
        )
    end
    for row in 1:row_count
        push!(constraint_sources, _nlp_constraint_ref(row, evaluator))
        push!(
            jacobian_row_methods,
            :Jac in capability.requested_features ? :exact_nlp_evaluator : :unavailable,
        )
    end

    if :Jac in capability.requested_features
        structure = try
            MOI.jacobian_structure(evaluator)
        catch exception
            push!(
                failures,
                EvaluationFailure(
                    :jacobian_structure,
                    :nlp_block,
                    EntityRef(:nlp_block, 1; function_type = string(typeof(evaluator))),
                    string(typeof(exception)),
                    sprint(showerror, exception),
                ),
            )
            Tuple{Int,Int}[]
        end
        raw_values = zeros(T, length(structure))
        try
            MOI.eval_constraint_jacobian(
                evaluator,
                raw_values,
                copy(point.values),
            )
            for ((row, column), value) in zip(structure, raw_values)
                push!(
                    jacobian_entries,
                    JacobianEntry{T}(first_row + row - 1, column, value),
                )
            end
        catch exception
            push!(
                failures,
                EvaluationFailure(
                    :constraint_jacobian,
                    :nlp_block,
                    EntityRef(:nlp_block, 1; function_type = string(typeof(evaluator))),
                    string(typeof(exception)),
                    sprint(showerror, exception),
                ),
            )
        end
    end
    return objective_value, objective_source
end

function _evaluate_oracles!(
    model::MOI.ModelLike,
    model_snapshot::ModelSnapshot,
    point::EvaluationPoint{T},
    constraint_values,
    constraint_sources,
    jacobian_entries,
    jacobian_row_methods,
    failures,
) where {T<:AbstractFloat}
    lookup = _point_lookup(point)
    point_columns = Dict(variable => i for (i, variable) in enumerate(point.variables))
    for constraint in model_snapshot.constraints
        set = constraint.set_value
        set isa MOI.VectorNonlinearOracle || continue
        source = _constraint_ref(constraint)
        input_function = constraint.function_value
        inputs = try
            MOI.Utilities.eval_variables(
                variable -> lookup[variable],
                model,
                input_function,
            )
        catch exception
            push!(
                failures,
                EvaluationFailure(
                    :oracle_input,
                    :nonlinear_oracle,
                    source,
                    string(typeof(exception)),
                    sprint(showerror, exception),
                ),
            )
            continue
        end
        first_row = length(constraint_values) + 1
        values = zeros(T, set.output_dimension)
        try
            set.eval_f(values, copy(inputs))
            append!(constraint_values, values)
        catch exception
            append!(constraint_values, fill(missing, set.output_dimension))
            push!(
                failures,
                EvaluationFailure(
                    :constraint_value,
                    :nonlinear_oracle,
                    source,
                    string(typeof(exception)),
                    sprint(showerror, exception),
                ),
            )
        end
        for row in 1:set.output_dimension
            push!(
                constraint_sources,
                _constraint_ref(constraint; row = row),
            )
            push!(
                jacobian_row_methods,
                input_function isa MOI.VectorOfVariables ?
                :exact_nonlinear_oracle :
                :unavailable,
            )
        end
        if !(input_function isa MOI.VectorOfVariables)
            push!(
                failures,
                EvaluationFailure(
                    :constraint_jacobian,
                    :nonlinear_oracle,
                    source,
                    "UnsupportedOracleInputFunction",
                    "oracle Jacobian composition currently requires MOI.VectorOfVariables inputs",
                ),
            )
            continue
        end
        raw_values = zeros(T, length(set.jacobian_structure))
        try
            set.eval_jacobian(raw_values, copy(inputs))
            for ((row, input_column), value) in
                zip(set.jacobian_structure, raw_values)
                variable = input_function.variables[input_column]
                column = point_columns[variable]
                push!(
                    jacobian_entries,
                    JacobianEntry{T}(first_row + row - 1, column, value),
                )
            end
        catch exception
            push!(
                failures,
                EvaluationFailure(
                    :constraint_jacobian,
                    :nonlinear_oracle,
                    source,
                    string(typeof(exception)),
                    sprint(showerror, exception),
                ),
            )
        end
    end
    return
end

function _evaluation_cache_key(
    model::MOI.ModelLike,
    point::EvaluationPoint,
    relative_step,
    generation::Integer,
)
    return (
        objectid(model),
        generation,
        Tuple(variable.value for variable in point.variables),
        Tuple(point.values),
        point.label,
        relative_step,
    )
end

"""
    evaluate_numerical(model, point; cache = EvaluationCache(), relative_step)

Safely evaluate all public numerical sources at `point`.

Ordinary MOI functions use public symbolic evaluation and finite differences.
`NLPBlock` and `VectorNonlinearOracle` derivatives use their exact sparse
callback interfaces when available.
"""
function evaluate_numerical(
    model::MOI.ModelLike,
    point::EvaluationPoint{T};
    cache::EvaluationCache = EvaluationCache(),
    relative_step::Real = cbrt(eps(T)),
) where {T<:AbstractFloat}
    model_variables = MOI.get(model, MOI.ListOfVariableIndices())
    point.variables == model_variables || throw(
        ArgumentError(
            "evaluation-point variable order does not match ListOfVariableIndices",
        ),
    )
    converted_step = convert(T, relative_step)
    converted_step > zero(T) ||
        throw(ArgumentError("relative_step must be positive"))
    key = _evaluation_cache_key(
        model,
        point,
        converted_step,
        cache.generation,
    )
    if haskey(cache.entries, key)
        cache.hits += 1
        return cache.entries[key]::NumericalEvaluation{T}
    end
    cache.misses += 1

    model_snapshot = snapshot(model)
    capabilities = evaluator_capabilities(model)
    failures = EvaluationFailure[]
    objective_value::Union{Nothing,Missing,T} = nothing
    objective_source::Union{Nothing,EntityRef} = nothing
    objective_gradient = Union{Missing,T}[]
    constraint_values = Union{Missing,T}[]
    constraint_sources = EntityRef[]
    jacobian_entries = JacobianEntry{T}[]
    jacobian_row_methods = Symbol[]

    block = _optional_nlp_block(model)
    objective_value, objective_source = _evaluate_symbolic!(
        model,
        model_snapshot,
        point,
        objective_value,
        objective_source,
        objective_gradient,
        constraint_values,
        constraint_sources,
        jacobian_entries,
        jacobian_row_methods,
        failures;
        relative_step = converted_step,
        skip_objective = !isnothing(block) && block.has_objective,
    )
    if !isnothing(block)
        objective_value, objective_source = _evaluate_nlp_block!(
            block,
            point,
            objective_value,
            objective_source,
            objective_gradient,
            constraint_values,
            constraint_sources,
            jacobian_entries,
            jacobian_row_methods,
            failures,
        )
    end
    _evaluate_oracles!(
        model,
        model_snapshot,
        point,
        constraint_values,
        constraint_sources,
        jacobian_entries,
        jacobian_row_methods,
        failures,
    )
    result = NumericalEvaluation{T}(
        point,
        objective_value,
        objective_source,
        objective_gradient,
        constraint_values,
        constraint_sources,
        jacobian_entries,
        jacobian_row_methods,
        capabilities,
        failures,
    )
    cache.entries[key] = result
    return result
end

function evaluate_numerical(
    model::MOI.ModelLike,
    values::Union{
        AbstractVector{<:Real},
        AbstractDict{MOI.VariableIndex,<:Real},
    };
    label::AbstractString = "user",
    kwargs...,
)
    return evaluate_numerical(
        model,
        evaluation_point(model, values; label = label);
        kwargs...,
    )
end
