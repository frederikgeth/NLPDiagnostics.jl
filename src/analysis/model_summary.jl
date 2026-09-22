"""
Magnitude statistics for one explicitly defined family of model coefficients.

Zero coefficients are counted but excluded from `minimum_nonzero_magnitude` and
`span_ratio`. `nonfinite_count` is kept explicit so a missing range is never
mistaken for an empty coefficient family.
"""
struct CoefficientRange
    total_count::Int
    finite_count::Int
    nonzero_count::Int
    zero_count::Int
    nonfinite_count::Int
    minimum_nonzero_magnitude::Union{Nothing,Float64}
    maximum_magnitude::Union{Nothing,Float64}
    span_ratio::Union{Nothing,Float64}
end

"""
Static coefficient statistics copied from the algebraic MOI representation.

`linear_matrix` covers canonical affine terms in supported constraint rows.
`quadratic_constraints` and `quadratic_objective` use polynomial
coefficients, so a stored MOI diagonal quadratic coefficient is divided by
two. `right_hand_sides` moves an exposed function constant to the set side.
Nonlinear expressions and callback rows are counted as opaque; their
point-local derivatives belong in `jacobian_scale_summary`.
"""
struct CoefficientProfile
    linear_matrix::CoefficientRange
    quadratic_constraints::CoefficientRange
    linear_objective::CoefficientRange
    quadratic_objective::CoefficientRange
    variable_bounds::CoefficientRange
    right_hand_sides::CoefficientRange
    linear_matrix_rows::Int
    linear_matrix_columns::Int
    linear_matrix_nonzeros::Int
    linear_matrix_density::Union{Nothing,Float64}
    supported_constraint_count::Int
    opaque_constraint_count::Int
    objective_available::Bool
    objective_opaque::Bool
    opaque_sources::Vector{String}
    observations::Vector{String}
end

"""
A compact, renderer-neutral inventory of a model and its static coefficients.

The summary uses only copied public MOI model data. Bridge provenance is
reported as unavailable because the generic public `MOI.ModelLike` interface
does not expose a portable list of instantiated bridges.
"""
struct ModelSummary
    model_name::Union{Nothing,String}
    model_fingerprint::Union{Nothing,String}
    variable_count::Int
    named_variable_count::Int
    constraint_count::Int
    scalarized_constraint_count::Int
    named_constraint_count::Int
    variable_domain_constraint_count::Int
    discrete_variable_constraint_count::Int
    constraint_type_counts::Dict{String,Int}
    objective_sense::String
    objective_function_type::Union{Nothing,String}
    opaque_sources::Vector{String}
    source_type::String
    bridge_wrapper_visible::Bool
    bridge_usage_available::Bool
    bridge_usage_reason::String
    coefficient_profile::CoefficientProfile
end

mutable struct _CoefficientRangeAccumulator
    total_count::Int
    finite_count::Int
    nonzero_count::Int
    zero_count::Int
    nonfinite_count::Int
    minimum_nonzero_magnitude::Union{Nothing,Float64}
    maximum_magnitude::Union{Nothing,Float64}
end

_CoefficientRangeAccumulator() =
    _CoefficientRangeAccumulator(0, 0, 0, 0, 0, nothing, nothing)

function _record_coefficient!(accumulator::_CoefficientRangeAccumulator, value)
    accumulator.total_count += 1
    if !(value isa Real) || !isfinite(value)
        accumulator.nonfinite_count += 1
        return
    end
    accumulator.finite_count += 1
    if iszero(value)
        accumulator.zero_count += 1
        return
    end
    accumulator.nonzero_count += 1
    magnitude = Float64(abs(BigFloat(value)))
    accumulator.minimum_nonzero_magnitude = isnothing(accumulator.minimum_nonzero_magnitude) ?
                                            magnitude :
                                            min(accumulator.minimum_nonzero_magnitude, magnitude)
    accumulator.maximum_magnitude = isnothing(accumulator.maximum_magnitude) ?
                                    magnitude :
                                    max(accumulator.maximum_magnitude, magnitude)
    return
end

function _coefficient_range(accumulator::_CoefficientRangeAccumulator)
    ratio = if isnothing(accumulator.minimum_nonzero_magnitude) ||
               isnothing(accumulator.maximum_magnitude)
        nothing
    else
        accumulator.maximum_magnitude / accumulator.minimum_nonzero_magnitude
    end
    return CoefficientRange(
        accumulator.total_count,
        accumulator.finite_count,
        accumulator.nonzero_count,
        accumulator.zero_count,
        accumulator.nonfinite_count,
        accumulator.minimum_nonzero_magnitude,
        accumulator.maximum_magnitude,
        ratio,
    )
end

function _canonical_sum!(entries::Dict, key, coefficient)
    entries[key] = haskey(entries, key) ? entries[key] + coefficient : coefficient
    return
end

function _linear_entries(function_value::MOI.ScalarAffineFunction)
    entries = Dict{Tuple{Int,MOI.VariableIndex},Any}()
    for term in function_value.terms
        _canonical_sum!(entries, (1, term.variable), term.coefficient)
    end
    return entries
end

function _linear_entries(function_value::MOI.ScalarQuadraticFunction)
    entries = Dict{Tuple{Int,MOI.VariableIndex},Any}()
    for term in function_value.affine_terms
        _canonical_sum!(entries, (1, term.variable), term.coefficient)
    end
    return entries
end

function _linear_entries(function_value::MOI.VectorAffineFunction)
    entries = Dict{Tuple{Int,MOI.VariableIndex},Any}()
    for term in function_value.terms
        scalar = term.scalar_term
        _canonical_sum!(entries, (term.output_index, scalar.variable), scalar.coefficient)
    end
    return entries
end

function _linear_entries(function_value::MOI.VectorQuadraticFunction)
    entries = Dict{Tuple{Int,MOI.VariableIndex},Any}()
    for term in function_value.affine_terms
        scalar = term.scalar_term
        _canonical_sum!(entries, (term.output_index, scalar.variable), scalar.coefficient)
    end
    return entries
end

function _linear_entries(function_value::MOI.VectorOfVariables)
    entries = Dict{Tuple{Int,MOI.VariableIndex},Any}()
    for (row, variable) in enumerate(function_value.variables)
        entries[(row, variable)] = 1.0
    end
    return entries
end

_linear_entries(function_value::MOI.VariableIndex) =
    Dict{Tuple{Int,MOI.VariableIndex},Any}((1, function_value) => 1.0)
_linear_entries(function_value::Real) =
    Dict{Tuple{Int,MOI.VariableIndex},Any}()
_linear_entries(function_value) = nothing

function _quadratic_entries(function_value::MOI.ScalarQuadraticFunction)
    entries = Dict{Tuple{Int,MOI.VariableIndex,MOI.VariableIndex},Any}()
    for term in function_value.quadratic_terms
        left, right = term.variable_1.value <= term.variable_2.value ?
                      (term.variable_1, term.variable_2) :
                      (term.variable_2, term.variable_1)
        coefficient = left == right ? term.coefficient / 2 : term.coefficient
        _canonical_sum!(entries, (1, left, right), coefficient)
    end
    return entries
end

function _quadratic_entries(function_value::MOI.VectorQuadraticFunction)
    entries = Dict{Tuple{Int,MOI.VariableIndex,MOI.VariableIndex},Any}()
    for term in function_value.quadratic_terms
        scalar = term.scalar_term
        left, right = scalar.variable_1.value <= scalar.variable_2.value ?
                      (scalar.variable_1, scalar.variable_2) :
                      (scalar.variable_2, scalar.variable_1)
        coefficient = left == right ? scalar.coefficient / 2 : scalar.coefficient
        _canonical_sum!(entries, (term.output_index, left, right), coefficient)
    end
    return entries
end

_quadratic_entries(function_value) = nothing

_function_constant(function_value::MOI.ScalarAffineFunction) = function_value.constant
_function_constant(function_value::MOI.ScalarQuadraticFunction) = function_value.constant
_function_constant(function_value::MOI.VariableIndex) = 0
_function_constant(function_value::Real) = function_value
_function_constant(function_value) = nothing

_scalar_set_endpoints(set_value::MOI.LessThan) = (set_value.upper,)
_scalar_set_endpoints(set_value::MOI.GreaterThan) = (set_value.lower,)
_scalar_set_endpoints(set_value::MOI.EqualTo) = (set_value.value,)
_scalar_set_endpoints(set_value::MOI.Interval) = (set_value.lower, set_value.upper)
_scalar_set_endpoints(set_value::MOI.Semicontinuous) = (set_value.lower, set_value.upper)
_scalar_set_endpoints(set_value::MOI.Semiinteger) = (set_value.lower, set_value.upper)
_scalar_set_endpoints(set_value::MOI.Parameter) = (set_value.value,)
_scalar_set_endpoints(set_value) = ()

_is_variable_domain_set(set_value) = set_value isa Union{
    MOI.LessThan,
    MOI.GreaterThan,
    MOI.EqualTo,
    MOI.Interval,
    MOI.Integer,
    MOI.ZeroOne,
    MOI.Semicontinuous,
    MOI.Semiinteger,
    MOI.Parameter,
}

_is_discrete_set(set_value) = set_value isa Union{
    MOI.Integer,
    MOI.ZeroOne,
    MOI.Semiinteger,
}

function _constraint_rows(record::ConstraintRecord)
    try
        return MOI.dimension(record.set_value)
    catch
        return 1
    end
end

function _objective_linear_entries(function_value)
    if function_value isa MOI.VariableIndex
        return Dict{Tuple{Int,MOI.VariableIndex},Any}((1, function_value) => 1.0)
    end
    return _linear_entries(function_value)
end

function _profile_observations(ranges, opaque_count, opaque_sources, large_ratio)
    observations = String[]
    for (label, range) in ranges
        if range.nonfinite_count > 0
            push!(observations, "$label contains $(range.nonfinite_count) nonfinite coefficient value(s).")
        end
        if !isnothing(range.span_ratio) && range.span_ratio >= large_ratio
            push!(observations,
                "$label spans $(range.span_ratio)× in nonzero magnitude; check units and scaling before attributing solver behavior.")
        end
    end
    if opaque_count > 0 || !isempty(opaque_sources)
        push!(observations,
            "Static coefficient coverage is incomplete because nonlinear or callback content is opaque; evaluate Jacobian scaling at an explicit point.")
    end
    return observations
end

function _coefficient_profile(
    model::ModelSnapshot;
    extra_rhs = Any[],
    extra_opaque_constraint_count::Integer = 0,
    opaque_objective::Bool = false,
    large_ratio::Real = 1.0e6,
)
    large_ratio > 1 || throw(ArgumentError("large_ratio must be greater than one"))
    matrix_acc = _CoefficientRangeAccumulator()
    quadratic_constraint_acc = _CoefficientRangeAccumulator()
    objective_linear_acc = _CoefficientRangeAccumulator()
    objective_quadratic_acc = _CoefficientRangeAccumulator()
    bound_acc = _CoefficientRangeAccumulator()
    rhs_acc = _CoefficientRangeAccumulator()
    matrix_rows = 0
    matrix_nonzeros = 0
    supported_constraint_count = 0
    opaque_constraint_count = Int(extra_opaque_constraint_count)

    for record in model.constraints
        is_variable_domain = record.function_value isa MOI.VariableIndex &&
                             _is_variable_domain_set(record.set_value)
        if is_variable_domain
            for endpoint in _scalar_set_endpoints(record.set_value)
                _record_coefficient!(bound_acc, endpoint)
            end
            supported_constraint_count += 1
            continue
        end

        linear = _linear_entries(record.function_value)
        quadratic = _quadratic_entries(record.function_value)
        if isnothing(linear)
            opaque_constraint_count += 1
        else
            supported_constraint_count += 1
            matrix_rows += _constraint_rows(record)
            for coefficient in values(linear)
                _record_coefficient!(matrix_acc, coefficient)
                iszero(coefficient) || (matrix_nonzeros += 1)
            end
            if !isnothing(quadratic)
                for coefficient in values(quadratic)
                    _record_coefficient!(quadratic_constraint_acc, coefficient)
                end
            end
        end

        constant = _function_constant(record.function_value)
        if !isnothing(constant)
            for endpoint in _scalar_set_endpoints(record.set_value)
                _record_coefficient!(rhs_acc, endpoint - constant)
            end
        end
    end
    for endpoint in extra_rhs
        _record_coefficient!(rhs_acc, endpoint)
    end

    objective_available = !isnothing(model.objective) || opaque_objective
    objective_opaque = opaque_objective
    if !isnothing(model.objective)
        function_value = model.objective.function_value
        linear = _objective_linear_entries(function_value)
        quadratic = _quadratic_entries(function_value)
        if isnothing(linear) && !(function_value isa Real)
            objective_opaque = true
        elseif !isnothing(linear)
            for coefficient in values(linear)
                _record_coefficient!(objective_linear_acc, coefficient)
            end
        end
        if !isnothing(quadratic)
            for coefficient in values(quadratic)
                _record_coefficient!(objective_quadratic_acc, coefficient)
            end
        end
    end

    linear_matrix = _coefficient_range(matrix_acc)
    quadratic_constraints = _coefficient_range(quadratic_constraint_acc)
    linear_objective = _coefficient_range(objective_linear_acc)
    quadratic_objective = _coefficient_range(objective_quadratic_acc)
    variable_bounds = _coefficient_range(bound_acc)
    right_hand_sides = _coefficient_range(rhs_acc)
    denominator = matrix_rows * length(model.variables)
    density = denominator == 0 ? nothing : matrix_nonzeros / denominator
    opaque_sources = copy(model.opaque_sources)
    observations = _profile_observations(
        [
            "linear matrix" => linear_matrix,
            "quadratic constraints" => quadratic_constraints,
            "linear objective" => linear_objective,
            "quadratic objective" => quadratic_objective,
            "variable bounds" => variable_bounds,
            "right-hand sides" => right_hand_sides,
        ],
        opaque_constraint_count + Int(objective_opaque),
        opaque_sources,
        large_ratio,
    )
    return CoefficientProfile(
        linear_matrix,
        quadratic_constraints,
        linear_objective,
        quadratic_objective,
        variable_bounds,
        right_hand_sides,
        matrix_rows,
        length(model.variables),
        matrix_nonzeros,
        density,
        supported_constraint_count,
        opaque_constraint_count,
        objective_available,
        objective_opaque,
        opaque_sources,
        observations,
    )
end

"""
    coefficient_profile(model; large_ratio=1e6)

Compute static coefficient ranges and linear-matrix density without modifying
`model`. The result deliberately excludes coefficients inferred from nonlinear
expression trees and callback derivatives.
"""
coefficient_profile(model::ModelSnapshot; kwargs...) =
    _coefficient_profile(model; kwargs...)

function coefficient_profile(model::MOI.ModelLike; kwargs...)
    model_snapshot = snapshot(model)
    block = _optional_nlp_block(model)
    extra_rhs = Any[]
    if !isnothing(block)
        for bounds in block.constraint_bounds
            isfinite(bounds.lower) && push!(extra_rhs, bounds.lower)
            isfinite(bounds.upper) && push!(extra_rhs, bounds.upper)
        end
    end
    return _coefficient_profile(
        model_snapshot;
        extra_rhs = extra_rhs,
        extra_opaque_constraint_count =
            isnothing(block) ? 0 : length(block.constraint_bounds),
        opaque_objective = !isnothing(block) && block.has_objective,
        kwargs...,
    )
end

function _constraint_type_counts(model::ModelSnapshot)
    counts = Dict{String,Int}()
    for record in model.constraints
        key = "$(typeof(record.function_value))-in-$(typeof(record.set_value))"
        counts[key] = get(counts, key, 0) + 1
    end
    return counts
end

function _model_summary(
    model::ModelSnapshot,
    profile::CoefficientProfile;
    fingerprint::Union{Nothing,String},
    source_type::String,
    bridge_wrapper_visible::Bool,
    objective_sense::Union{Nothing,String} = nothing,
    extra_opaque_constraint_count::Integer = 0,
)
    domain_count = count(record ->
        record.function_value isa MOI.VariableIndex &&
        _is_variable_domain_set(record.set_value), model.constraints)
    discrete_count = count(record ->
        record.function_value isa MOI.VariableIndex &&
        _is_discrete_set(record.set_value), model.constraints)
    reported_objective_sense = isnothing(objective_sense) ?
                               (isnothing(model.objective) ? "feasibility_or_opaque" :
                                string(model.objective.sense)) :
                               objective_sense
    objective_type = isnothing(model.objective) ? nothing :
                     string(typeof(model.objective.function_value))
    return ModelSummary(
        model.model_name,
        fingerprint,
        length(model.variables),
        count(record -> !isnothing(record.name), model.variables),
        length(model.constraints) + extra_opaque_constraint_count,
        sum(_constraint_rows, model.constraints; init = 0) +
            extra_opaque_constraint_count,
        count(record -> !isnothing(record.name), model.constraints),
        domain_count,
        discrete_count,
        let counts = _constraint_type_counts(model)
            extra_opaque_constraint_count > 0 &&
                (counts["MOI.NLPBlockData(opaque)"] = extra_opaque_constraint_count)
            counts
        end,
        reported_objective_sense,
        objective_type,
        copy(model.opaque_sources),
        source_type,
        bridge_wrapper_visible,
        false,
        "Portable instantiated-bridge provenance is not exposed by the public MOI.ModelLike interface.",
        profile,
    )
end

"""
    model_summary(model; large_ratio=1e6)

Return model counts, function-in-set type counts, objective metadata,
fingerprint provenance, bridge observability, and a [`CoefficientProfile`](@ref).
"""
function model_summary(model::ModelSnapshot; kwargs...)
    return _model_summary(
        model,
        coefficient_profile(model; kwargs...);
        fingerprint = nothing,
        source_type = string(typeof(model)),
        bridge_wrapper_visible = false,
    )
end

function model_summary(model::MOI.ModelLike; kwargs...)
    model_snapshot = snapshot(model)
    block = _optional_nlp_block(model)
    bridge_visible = model isa MOI.Bridges.AbstractBridgeOptimizer
    return _model_summary(
        model_snapshot,
        coefficient_profile(model; kwargs...);
        fingerprint = _model_fingerprint(model, model_snapshot),
        source_type = string(typeof(model)),
        bridge_wrapper_visible = bridge_visible,
        objective_sense = string(MOI.get(model, MOI.ObjectiveSense())),
        extra_opaque_constraint_count =
            isnothing(block) ? 0 : length(block.constraint_bounds),
    )
end


"""Return a renderer-neutral dictionary for a [`CoefficientRange`](@ref)."""
function coefficient_range_data(range::CoefficientRange)
    return Dict{String,Any}(
        "total_count" => range.total_count,
        "finite_count" => range.finite_count,
        "nonzero_count" => range.nonzero_count,
        "zero_count" => range.zero_count,
        "nonfinite_count" => range.nonfinite_count,
        "minimum_nonzero_magnitude" => range.minimum_nonzero_magnitude,
        "maximum_magnitude" => range.maximum_magnitude,
        "span_ratio" => range.span_ratio,
    )
end

"""Return a renderer-neutral dictionary for a [`CoefficientProfile`](@ref)."""
function coefficient_profile_data(profile::CoefficientProfile)
    return Dict{String,Any}(
        "schema_version" => "nlpdiagnostics-coefficient-profile-v1",
        "linear_matrix" => coefficient_range_data(profile.linear_matrix),
        "quadratic_constraints" => coefficient_range_data(profile.quadratic_constraints),
        "linear_objective" => coefficient_range_data(profile.linear_objective),
        "quadratic_objective" => coefficient_range_data(profile.quadratic_objective),
        "variable_bounds" => coefficient_range_data(profile.variable_bounds),
        "right_hand_sides" => coefficient_range_data(profile.right_hand_sides),
        "linear_matrix_rows" => profile.linear_matrix_rows,
        "linear_matrix_columns" => profile.linear_matrix_columns,
        "linear_matrix_nonzeros" => profile.linear_matrix_nonzeros,
        "linear_matrix_density" => profile.linear_matrix_density,
        "supported_constraint_count" => profile.supported_constraint_count,
        "opaque_constraint_count" => profile.opaque_constraint_count,
        "objective_available" => profile.objective_available,
        "objective_opaque" => profile.objective_opaque,
        "opaque_sources" => copy(profile.opaque_sources),
        "observations" => copy(profile.observations),
    )
end

"""Return a renderer-neutral dictionary for a [`ModelSummary`](@ref)."""
function model_summary_data(summary::ModelSummary)
    return Dict{String,Any}(
        "schema_version" => "nlpdiagnostics-model-summary-v1",
        "model_name" => summary.model_name,
        "model_fingerprint" => summary.model_fingerprint,
        "variable_count" => summary.variable_count,
        "named_variable_count" => summary.named_variable_count,
        "constraint_count" => summary.constraint_count,
        "scalarized_constraint_count" => summary.scalarized_constraint_count,
        "named_constraint_count" => summary.named_constraint_count,
        "variable_domain_constraint_count" => summary.variable_domain_constraint_count,
        "discrete_variable_constraint_count" => summary.discrete_variable_constraint_count,
        "constraint_type_counts" => copy(summary.constraint_type_counts),
        "objective_sense" => summary.objective_sense,
        "objective_function_type" => summary.objective_function_type,
        "opaque_sources" => copy(summary.opaque_sources),
        "source_type" => summary.source_type,
        "bridge_wrapper_visible" => summary.bridge_wrapper_visible,
        "bridge_usage_available" => summary.bridge_usage_available,
        "bridge_usage_reason" => summary.bridge_usage_reason,
        "coefficient_profile" => coefficient_profile_data(summary.coefficient_profile),
    )
end

function Base.show(io::IO, summary::ModelSummary)
    profile = summary.coefficient_profile
    print(io, "ModelSummary(", summary.variable_count, " variables, ",
        summary.constraint_count, " constraints, objective=", summary.objective_sense,
        ", linear_matrix_nnz=", profile.linear_matrix_nonzeros)
    if !isnothing(profile.linear_matrix.span_ratio)
        print(io, ", linear_matrix_span=", profile.linear_matrix.span_ratio, "×")
    end
    print(io, ")")
end
