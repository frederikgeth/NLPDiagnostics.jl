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
Point-local feasibility and activity information for one scalar constraint row.

Margins are signed distances to finite lower and upper bounds. `classification`
is descriptive only; an active inequality is selected only by the explicit
`active_tolerance` used to create the parent summary.
"""
struct ConstraintActivity{T<:AbstractFloat}
    row::Int
    source::EntityRef
    value::Union{Missing,T}
    lower::Union{Nothing,T}
    upper::Union{Nothing,T}
    lower_margin::Union{Nothing,T}
    upper_margin::Union{Nothing,T}
    feasibility_violation::Union{Nothing,T}
    lower_active::Bool
    upper_active::Bool
    classification::Symbol
end

"""
Feasibility and active-set evidence tied to one `EvaluationPoint`.
"""
struct ConstraintFeasibilitySummary{T<:AbstractFloat}
    point::EvaluationPoint{T}
    activities::Vector{ConstraintActivity{T}}
    feasibility_tolerance::T
    active_tolerance::T
    complete::Bool
    reason::Union{Nothing,String}
end

"""
Result of a deliberately conservative Mangasarian--Fromovitz screen.

`direction_found` is a sufficient numerical certificate only. A false value is
inconclusive and is never reported as MFCQ failure.
"""
struct MFCQScreen{T<:AbstractFloat}
    available::Bool
    reason::Union{Nothing,String}
    equality_rows::Vector{Int}
    inequality_rows::Vector{Int}
    direction_found::Bool
    direction::Vector{T}
    largest_active_inequality_directional_derivative::Union{Nothing,T}
end

"""
Comparison of structural equality matching with a local numerical Jacobian.

The comparison is restricted to free variables and ordinary equality rows that
can be aligned exactly between the incidence graph and numerical evaluation.
It does not assign a physical interpretation to a nullspace.
"""
struct StructuralNumericalComparison{T<:AbstractFloat}
    available::Bool
    reason::Union{Nothing,String}
    point::EvaluationPoint{T}
    structural_matching_rank::Int
    structural_right_nullity::Int
    structural_left_nullity::Int
    numerical_rank::Int
    numerical_right_nullity::Int
    numerical_left_nullity::Int
    equality_rows::Vector{Int}
    free_variable_columns::Vector{Int}
    estimate::Union{Nothing,JacobianRankEstimate{T}}
end

"""
An inspectable pattern observed in one local Jacobian null vector.

`kind` is deliberately a candidate label, not a semantic diagnosis. The
support indices refer to the full evaluation's variable columns or constraint
rows according to `side`.
"""
struct NullspaceFingerprint{T<:AbstractFloat}
    side::Symbol
    vector_index::Int
    kind::Symbol
    support::Vector{Int}
    score::T
end

"""
A labeled, solver-independent numerical profiling scenario.

The descriptive fields make formulation, initialization, scale, and solver
intent explicit without requiring the generic core to understand their domain
semantics. `expected_evidence` records hypotheses to inspect, not assertions.
"""
struct ProfileCase{T<:AbstractFloat}
    name::String
    description::String
    formulation::String
    initialization::String
    scale::String
    solver::Union{Nothing,String}
    expected_evidence::Vector{Symbol}
    tags::Vector{Symbol}
    metadata::Dict{String,String}
    point::EvaluationPoint{T}
end

function ProfileCase(
    name::AbstractString,
    point::EvaluationPoint{T};
    description::AbstractString = "",
    formulation::AbstractString = "unspecified",
    initialization::AbstractString = point.label,
    scale::AbstractString = "unspecified",
    solver::Union{Nothing,AbstractString} = nothing,
    expected_evidence::AbstractVector{Symbol} = Symbol[],
    tags::AbstractVector{Symbol} = Symbol[],
    metadata::AbstractDict = Dict{String,String}(),
) where {T<:AbstractFloat}
    return ProfileCase{T}(
        String(name),
        String(description),
        String(formulation),
        String(initialization),
        String(scale),
        isnothing(solver) ? nothing : String(solver),
        unique!(collect(expected_evidence)),
        unique!(collect(tags)),
        Dict(string(key) => string(value) for (key, value) in metadata),
        point,
    )
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
    call_statistics::Dict{Symbol,Tuple{Int,Float64}}
end

function NumericalEvaluation{T}(
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
) where {T<:AbstractFloat}
    return NumericalEvaluation{T}(
        point, objective_value, objective_source, objective_gradient,
        constraint_values, constraint_sources, jacobian_entries,
        jacobian_row_methods, capabilities, failures,
        Dict{Symbol,Tuple{Int,Float64}}(),
    )
end

"""
Evidence and wall-clock timings from one `ProfileCase` run.

Timings are diagnostic observations and include Julia compilation/allocation
effects unless the caller has performed a warm-up run.
"""
struct ProfileResult{T<:AbstractFloat}
    case::ProfileCase{T}
    evaluation::NumericalEvaluation{T}
    numerical_report::DiagnosticReport
    active_set_report::DiagnosticReport
    degeneracy_report::DiagnosticReport
    stage_seconds::Dict{Symbol,Float64}
    callback_statistics::Dict{Symbol,Tuple{Int,Float64}}
    derivative_row_method_counts::Dict{Symbol,Int}
    capability_source_counts::Dict{Symbol,Int}
    cache_hits::Int
    cache_misses::Int
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
