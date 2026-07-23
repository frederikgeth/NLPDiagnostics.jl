"""
    EvaluationPoint(variables, values; label = "user")

A numerical point whose coordinate order is explicit and stable.

Every cached value and derivative is attached to an `EvaluationPoint`. This
prevents numerical evidence from being accidentally compared across different
variable orders or iterates.
"""
struct EvaluationPoint{T<:AbstractFloat}
    variables::Vector{MOI.VariableIndex}
    values::Vector{T}
    label::String

    function EvaluationPoint(
        variables::AbstractVector{MOI.VariableIndex},
        values::AbstractVector{<:Real};
        label::AbstractString = "user",
    )
        length(variables) == length(values) ||
            throw(DimensionMismatch("variable and value lengths differ"))
        length(unique(variables)) == length(variables) ||
            throw(ArgumentError("evaluation-point variables must be unique"))
        T = isempty(values) ? Float64 : float(promote_type(map(typeof, values)...))
        return new{T}(collect(variables), T.(values), String(label))
    end
end

function Base.:(==)(left::EvaluationPoint, right::EvaluationPoint)
    return left.variables == right.variables &&
           left.values == right.values &&
           left.label == right.label
end

function Base.hash(point::EvaluationPoint, seed::UInt)
    return hash((point.variables, point.values, point.label), seed)
end

"""
    evaluation_point(model, values; label = "user")

Construct an `EvaluationPoint` in `ListOfVariableIndices` order.
"""
function evaluation_point(
    model::MOI.ModelLike,
    values::AbstractVector{<:Real};
    label::AbstractString = "user",
)
    variables = MOI.get(model, MOI.ListOfVariableIndices())
    return EvaluationPoint(variables, values; label = label)
end

function evaluation_point(
    model::MOI.ModelLike,
    values::AbstractDict{MOI.VariableIndex,<:Real};
    label::AbstractString = "user",
)
    variables = MOI.get(model, MOI.ListOfVariableIndices())
    missing_variables = filter(variable -> !haskey(values, variable), variables)
    isempty(missing_variables) || throw(
        ArgumentError(
            "values are missing variable indices " *
            join((variable.value for variable in missing_variables), ", "),
        ),
    )
    return EvaluationPoint(
        variables,
        [values[variable] for variable in variables];
        label = label,
    )
end

"""
Capabilities exposed by one numerical source.

`available_features` and `requested_features` use MOI evaluator feature names
where applicable. Values are represented explicitly because
`AbstractNLPEvaluator` value evaluation is mandatory and has no feature flag.
"""
struct EvaluatorCapabilities
    source::Symbol
    identifier::String
    objective_values::Bool
    constraint_values::Bool
    available_features::Vector{Symbol}
    requested_features::Vector{Symbol}
end

"""
An exception captured during numerical probing.

Evaluations are diagnostic operations. A callback failure is retained as
evidence instead of escaping and aborting the remaining analyses.
"""
struct EvaluationFailure
    stage::Symbol
    source::Symbol
    affected::EntityRef
    exception_type::String
    message::String
end

"""
One raw sparse Jacobian entry.

Duplicate `(row, column)` positions are intentionally retained because MOI
evaluators and nonlinear oracles define them additively.
"""
struct JacobianEntry{T<:AbstractFloat}
    row::Int
    column::Int
    value::T
end

"""
A guarded dense-SVD estimate of local Jacobian rank.

`left_nullspace` and `right_nullspace` are expressed in the original
constraint and variable coordinates, even when the SVD used diagonal scaling.
"""
struct JacobianRankEstimate{T<:AbstractFloat}
    available::Bool
    reason::Union{Nothing,String}
    point::EvaluationPoint{T}
    method::Symbol
    scaling::Symbol
    rows::Int
    columns::Int
    rank::Int
    left_nullity::Int
    right_nullity::Int
    singular_values::Vector{T}
    relative_tolerance::T
    absolute_threshold::T
    condition_estimate::Union{Nothing,T}
    row_scaling::Vector{T}
    column_scaling::Vector{T}
    left_nullspace::Matrix{T}
    right_nullspace::Matrix{T}
end

"""
One raw Hessian-of-the-Lagrangian entry.

Duplicate and transposed positions are retained. MOI defines these entries
additively, so consumers must combine them before forming a matrix.
"""
struct HessianEntry{T<:AbstractFloat}
    row::Int
    column::Int
    value::T
end

"""
Point- and multiplier-tagged Hessian-of-the-Lagrangian evidence.
"""
struct HessianEvaluation{T<:AbstractFloat}
    point::EvaluationPoint{T}
    objective_weight::T
    constraint_multipliers::Vector{T}
    entries::Vector{HessianEntry{T}}
    methods::Vector{Symbol}
    complete::Bool
    failures::Vector{EvaluationFailure}
end

"""
Spectrum and inertia of a Hessian projected into a selected Jacobian nullspace.

The active rows are explicit because activity cannot be inferred reliably from
function values alone.
"""
struct ReducedHessianAnalysis{T<:AbstractFloat}
    available::Bool
    reason::Union{Nothing,String}
    point::EvaluationPoint{T}
    active_rows::Vector{Int}
    jacobian_rank::Int
    tangent_dimension::Int
    jacobian_threshold::T
    eigenvalue_threshold::T
    eigenvalues::Vector{T}
    positive_eigenvalues::Int
    negative_eigenvalues::Int
    zero_eigenvalues::Int
    condition_estimate::Union{Nothing,T}
    tangent_basis::Matrix{T}
end

"""
Numerical values and derivatives observed at one exact point.

Missing values indicate that an evaluation failed or was unavailable. The
corresponding reason appears in `failures`.
"""
struct NumericalEvaluation{T<:AbstractFloat}
    point::EvaluationPoint{T}
    objective_value::Union{Nothing,Missing,T}
    objective_source::Union{Nothing,EntityRef}
    objective_gradient::Vector{Union{Missing,T}}
    constraint_values::Vector{Union{Missing,T}}
    constraint_sources::Vector{EntityRef}
    jacobian_entries::Vector{JacobianEntry{T}}
    jacobian_row_methods::Vector{Symbol}
    capabilities::Vector{EvaluatorCapabilities}
    failures::Vector{EvaluationFailure}
end

"""
Infinity-norm row and column statistics for an evaluated Jacobian.

Raw duplicate sparse entries are summed before norms are calculated. This
matches MOI's derivative semantics while leaving raw entries available in the
parent `NumericalEvaluation`.
"""
struct JacobianScaleSummary{T<:AbstractFloat}
    row_norms::Vector{T}
    column_norms::Vector{T}
    zero_rows::Vector{Int}
    zero_columns::Vector{Int}
    nonfinite_rows::Vector{Int}
    nonfinite_columns::Vector{Int}
    smallest_positive_row_norm::Union{Nothing,T}
    largest_finite_row_norm::Union{Nothing,T}
    row_scale_ratio::Union{Nothing,T}
    smallest_positive_column_norm::Union{Nothing,T}
    largest_finite_column_norm::Union{Nothing,T}
    column_scale_ratio::Union{Nothing,T}
    norm::Symbol
end

"""
A reusable cache for complete point-tagged numerical evaluations.
"""
mutable struct EvaluationCache
    entries::Dict{Any,Any}
    hits::Int
    misses::Int
    generation::Int
end

EvaluationCache() = EvaluationCache(Dict{Any,Any}(), 0, 0, 0)

function Base.empty!(cache::EvaluationCache)
    empty!(cache.entries)
    cache.hits = 0
    cache.misses = 0
    cache.generation += 1
    return cache
end
