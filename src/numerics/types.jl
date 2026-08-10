@enum EvaluationPointKind begin
    UserPoint
    InitializationPoint
    CompletedInitializationPoint
    SolverIteratePoint
    SolverResultPoint
    PerturbedPoint
    SyntheticSmokePoint
end

"""Typed origin and completeness evidence for one numerical point."""
struct EvaluationPointProvenance
    kind::EvaluationPointKind
    source::String
    complete::Bool
    metadata::Dict{String,String}
end

function EvaluationPointProvenance(
    kind::EvaluationPointKind = UserPoint;
    source::AbstractString = "user",
    complete::Bool = true,
    metadata::AbstractDict = Dict{String,String}(),
)
    isempty(strip(source)) && throw(ArgumentError("point provenance source must not be empty"))
    return EvaluationPointProvenance(
        kind,
        String(source),
        complete,
        Dict(string(key) => string(value) for (key, value) in metadata),
    )
end

function Base.:(==)(left::EvaluationPointProvenance, right::EvaluationPointProvenance)
    return left.kind == right.kind && left.source == right.source &&
           left.complete == right.complete && left.metadata == right.metadata
end


function Base.hash(provenance::EvaluationPointProvenance, seed::UInt)
    metadata = sort!(collect(provenance.metadata); by = first)
    return hash((provenance.kind, provenance.source, provenance.complete, metadata), seed)
end

"""
    EvaluationPoint(variables, values; label = "user", provenance = EvaluationPointProvenance())

A numerical point whose coordinate order is explicit and stable.

Every cached value and derivative is attached to an `EvaluationPoint`. This
prevents numerical evidence from being accidentally compared across different
variable orders or iterates. Its typed provenance records how the point was
obtained and whether every required coordinate was present.
"""
struct EvaluationPoint{T<:AbstractFloat}
    variables::Vector{MOI.VariableIndex}
    values::Vector{T}
    label::String
    provenance::EvaluationPointProvenance

    function EvaluationPoint(
        variables::AbstractVector{MOI.VariableIndex},
        values::AbstractVector{<:Real};
        label::AbstractString = "user",
        provenance::EvaluationPointProvenance = EvaluationPointProvenance(),
    )
        length(variables) == length(values) ||
            throw(DimensionMismatch("variable and value lengths differ"))
        length(unique(variables)) == length(variables) ||
            throw(ArgumentError("evaluation-point variables must be unique"))
        T = isempty(values) ? Float64 : float(promote_type(map(typeof, values)...))
        return new{T}(collect(variables), T.(values), String(label), provenance)
    end

    function EvaluationPoint{T}(
        variables::AbstractVector{MOI.VariableIndex},
        values::AbstractVector{<:Real},
        label::AbstractString = "user",
        provenance::EvaluationPointProvenance = EvaluationPointProvenance(),
    ) where {T<:AbstractFloat}
        length(variables) == length(values) ||
            throw(DimensionMismatch("variable and value lengths differ"))
        length(unique(variables)) == length(variables) ||
            throw(ArgumentError("evaluation-point variables must be unique"))
        return new{T}(collect(variables), T.(values), String(label), provenance)
    end
end

"""Result of applying an explicit trust policy to a collection of points."""
struct TrustedPointSelection
    selected::Vector{EvaluationPoint}
    rejected::Vector{Tuple{EvaluationPoint,String}}
    metadata::Dict{String,String}
end

"""
    select_trusted_evaluation_points(points; kwargs...)

Select complete, finite points with explicitly allowed provenance kinds. The
default policy admits only solver iterates and solver results; user,
initialization, perturbed, synthetic, and artificially completed points are
retained in `rejected` with reasons rather than silently promoted.
"""
function select_trusted_evaluation_points(
    points::AbstractVector{<:EvaluationPoint};
    allowed_kinds::AbstractVector{EvaluationPointKind} =
        EvaluationPointKind[SolverIteratePoint, SolverResultPoint],
    require_complete::Bool = true,
    require_finite::Bool = true,
)
    isempty(allowed_kinds) && throw(ArgumentError("allowed_kinds must not be empty"))
    allowed = Set(allowed_kinds)
    selected = EvaluationPoint[]
    rejected = Tuple{EvaluationPoint,String}[]
    for point in points
        reason = if !(point.provenance.kind in allowed)
            "provenance kind $(point.provenance.kind) is not allowed by the trust policy"
        elseif require_complete && !point.provenance.complete
            "point provenance is incomplete"
        elseif require_finite && any(value -> !isfinite(value), point.values)
            "point contains non-finite coordinates"
        else
            nothing
        end
        if isnothing(reason)
            push!(selected, point)
        else
            push!(rejected, (point, reason))
        end
    end
    metadata = Dict{String,String}(
        "input_count" => string(length(points)),
        "selected_count" => string(length(selected)),
        "rejected_count" => string(length(rejected)),
        "allowed_kinds" => join(string.(sort!(collect(allowed); by = string)), ","),
        "require_complete" => string(require_complete),
        "require_finite" => string(require_finite),
        "selected_fingerprints" => join(evaluation_point_fingerprint.(selected), ","),
        "rejected_reasons" => join((reason for (_, reason) in rejected), " | "),
    )
    return TrustedPointSelection(selected, rejected, metadata)
end

function trusted_point_selection_data(selection::TrustedPointSelection)
    return Dict{String,Any}(
        "metadata" => copy(selection.metadata),
        "selected" => [_evaluation_point_data(point) for point in selection.selected],
        "rejected" => [Dict{String,Any}(
            "point" => _evaluation_point_data(point),
            "reason" => reason,
        ) for (point, reason) in selection.rejected],
    )
end

function Base.:(==)(left::EvaluationPoint, right::EvaluationPoint)
    return left.variables == right.variables &&
           left.values == right.values &&
           left.label == right.label &&
           left.provenance == right.provenance
end

function Base.hash(point::EvaluationPoint, seed::UInt)
    return hash((point.variables, point.values, point.label, point.provenance), seed)
end

function _evaluation_point_data(point::EvaluationPoint)
    return Dict{String,Any}(
        "label" => point.label,
        "variables" => [variable.value for variable in point.variables],
        "values" => copy(point.values),
        "fingerprint" => evaluation_point_fingerprint(point),
        "provenance" => Dict{String,Any}(
            "kind" => string(point.provenance.kind),
            "source" => point.provenance.source,
            "complete" => point.provenance.complete,
            "metadata" => Dict(point.provenance.metadata),
        ),
    )
end

"""
    evaluation_point(model, values; label = "user")

Construct an `EvaluationPoint` in `ListOfVariableIndices` order.
"""
function evaluation_point(
    model::MOI.ModelLike,
    values::AbstractVector{<:Real};
    label::AbstractString = "user",
    provenance::EvaluationPointProvenance = EvaluationPointProvenance(),
)
    variables = MOI.get(model, MOI.ListOfVariableIndices())
    return EvaluationPoint(variables, values; label = label, provenance = provenance)
end

function evaluation_point(
    model::MOI.ModelLike,
    values::AbstractDict{MOI.VariableIndex,<:Real};
    label::AbstractString = "user",
    provenance::EvaluationPointProvenance = EvaluationPointProvenance(),
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
        provenance = provenance,
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
An explicit numerical-rank policy.

`backend` selects the numerical method, while `scaling`, the relative and
absolute tolerances, and `matrix_norm` define the numerical semantics attached
to its evidence. `max_dense_entries` is a work guard, not a model-size claim.
`provenance` records who selected the policy (`:default`, `:user`, a benchmark,
or a plugin) without promoting the resulting rank to a mathematical fact.
"""
struct RankPolicy{T<:AbstractFloat}
    backend::Symbol
    scaling::Symbol
    relative_tolerance::T
    absolute_tolerance::T
    matrix_norm::Symbol
    max_dense_entries::Int
    compute_vectors::Bool
    provenance::Symbol
end

function RankPolicy(
    ::Type{T} = Float64;
    backend::Symbol = :dense_svd,
    scaling::Symbol = :none,
    relative_tolerance::Real = sqrt(eps(T)),
    absolute_tolerance::Real = zero(T),
    matrix_norm::Symbol = :frobenius,
    max_dense_entries::Integer = 4_000_000,
    compute_vectors::Bool = true,
    provenance::Symbol = :user,
) where {T<:AbstractFloat}
    backend in (:dense_svd, :sparse_qr) ||
        throw(ArgumentError("backend must be :dense_svd or :sparse_qr"))
    scaling in (:none, :row, :column, :row_column) ||
        throw(ArgumentError("scaling must be :none, :row, :column, or :row_column"))
    matrix_norm in (:frobenius, :one, :infinity) ||
        throw(ArgumentError("matrix_norm must be :frobenius, :one, or :infinity"))
    relative = T(relative_tolerance)
    absolute = T(absolute_tolerance)
    isfinite(relative) && relative >= zero(T) ||
        throw(ArgumentError("relative_tolerance must be finite and nonnegative"))
    isfinite(absolute) && absolute >= zero(T) ||
        throw(ArgumentError("absolute_tolerance must be finite and nonnegative"))
    max_dense_entries >= 0 ||
        throw(ArgumentError("max_dense_entries must be nonnegative"))
    return RankPolicy{T}(
        backend, scaling, relative, absolute, matrix_norm,
        Int(max_dense_entries), compute_vectors, provenance,
    )
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
    policy::RankPolicy{T}
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
Sparse nonzero-pattern upper bound on local Jacobian rank.

The matching rank is the term rank of the observed, combined sparse Jacobian.
It can prove rank deficiency when below `min(rows, columns)`, but it cannot
certify full numerical rank or provide a nullspace.
"""
struct SparseJacobianPatternEstimate{T<:AbstractFloat}
    available::Bool
    reason::Union{Nothing,String}
    point::EvaluationPoint{T}
    rows::Int
    columns::Int
    nonzero_count::Int
    zero_tolerance::T
    rank_upper_bound::Int
    unmatched_rows::Vector{Int}
    unmatched_columns::Vector{Int}
end

"""Sparse-QR local rank estimate with inspectable factorization evidence."""
struct SparseQRRankEstimate{T<:AbstractFloat}
    available::Bool
    reason::Union{Nothing,String}
    point::EvaluationPoint{T}
    policy::RankPolicy{T}
    method::Symbol
    scaling::Symbol
    rows::Int
    columns::Int
    rank::Int
    diagonal_pivots::Vector{T}
    relative_tolerance::T
    absolute_threshold::T
    condition_proxy::Union{Nothing,T}
    matrix_norm::Union{Nothing,T}
    row_permutation::Vector{Int}
    column_permutation::Vector{Int}
    factorization_relative_residual::Union{Nothing,T}
    factorization_residual_reason::Union{Nothing,String}
end

"""Iterative sparse-matvec probe for one candidate right-null direction."""
struct IterativeNullspaceEstimate{T<:AbstractFloat}
    available::Bool
    reason::Union{Nothing,String}
    point::EvaluationPoint{T}
    iterations::Int
    converged::Bool
    operator_source::Symbol
    direction::Vector{T}
    residual_norm::Union{Nothing,T}
    matrix_norm::Union{Nothing,T}
    relative_residual_norm::Union{Nothing,T}
end

"""Iterative sparse-matvec probe for a candidate right-null subspace."""
struct IterativeNullspaceSubspaceEstimate{T<:AbstractFloat}
    available::Bool
    reason::Union{Nothing,String}
    point::EvaluationPoint{T}
    requested_dimension::Int
    iterations::Int
    converged::Bool
    operator_source::Symbol
    directions::Matrix{T}
    residual_norms::Vector{T}
    matrix_norm::Union{Nothing,T}
    relative_residual_norms::Vector{T}
    subspace_change::Union{Nothing,T}
end

"""Iterative sparse-matvec probe for a candidate left-null subspace."""
struct IterativeLeftNullspaceSubspaceEstimate{T<:AbstractFloat}
    available::Bool
    reason::Union{Nothing,String}
    point::EvaluationPoint{T}
    requested_dimension::Int
    iterations::Int
    converged::Bool
    operator_source::Symbol
    directions::Matrix{T}
    residual_norms::Vector{T}
    matrix_norm::Union{Nothing,T}
    relative_residual_norms::Vector{T}
    subspace_change::Union{Nothing,T}
end

"""Sparse-matvec spectral-scale and small-direction residual probe."""
struct IterativeJacobianSpectrumEstimate{T<:AbstractFloat}
    available::Bool
    reason::Union{Nothing,String}
    point::EvaluationPoint{T}
    iterations::Int
    operator_source::Symbol
    largest_singular_value_proxy::Union{Nothing,T}
    candidate_small_singular_values::Vector{T}
    spectral_spread_proxies::Vector{T}
    candidate_subspace_converged::Bool
end

"""
A local Jacobian linear operator with explicit product provenance.

The assembled sparse matrix remains available for inspection. When `source`
is `:hybrid_moi_jacvec`, products for NLP-block rows use MOI's public
`:JacVec` callbacks while all other rows use the assembled matrix. This is a
local numerical object, not a rank or derivative-correctness certificate.
"""
struct JacobianLinearOperator{T<:AbstractFloat,M,E}
    available::Bool
    reason::Union{Nothing,String}
    point::EvaluationPoint{T}
    rows::Int
    columns::Int
    source::Symbol
    assembled_matrix::M
    nlp_evaluator::E
    nlp_rows::Vector{Int}
    native_unavailable_reason::Union{Nothing,String}
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
    reduced_eigenvectors::Matrix{T}
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

"""Point-local feasibility and boundary evidence for one supported coupled set."""
struct CoupledSetActivity{T<:AbstractFloat}
    source::EntityRef
    set_kind::Symbol
    values::Vector{Union{Missing,T}}
    margin::Union{Nothing,T}
    feasibility_violation::Union{Nothing,T}
    boundary_active::Bool
    classification::Symbol
    reason::Union{Nothing,String}
end

"""Backward-compatible construction without an explicit availability reason."""
function CoupledSetActivity{T}(
    source,
    set_kind,
    values,
    margin,
    feasibility_violation,
    boundary_active,
    classification,
) where {T<:AbstractFloat}
    return CoupledSetActivity{T}(
        source, set_kind, values, margin, feasibility_violation, boundary_active,
        classification, nothing,
    )
end

"""A smooth coupled-set boundary normal supplied by the generic core or a plugin."""
struct CoupledSetTangentEvidence{T<:AbstractFloat}
    source::EntityRef
    set_kind::Symbol
    normal::Vector{T}
    description::String
end

"""Local cone-aware Robinson-CQ evidence, separate from scalar LICQ/MFCQ.

`tangent_sources` lists the smooth coupled boundaries used by the screen at
the recorded point. `witness_direction` is meaningful only when
`robinson_regular` is true. The normal-combination fields retain the
minimum-norm convex-hull calculation used to reach the conclusion.
"""
struct CoupledSetQualificationScreen{T<:AbstractFloat}
    available::Bool
    reason::Union{Nothing,String}
    point::EvaluationPoint{T}
    tangent_sources::Vector{EntityRef}
    robinson_regular::Bool
    witness_direction::Vector{T}
    normal_weights::Vector{T}
    normal_combination::Vector{T}
    combination_residual::Union{Nothing,T}
    tolerance::Union{Nothing,T}
    iterations::Int
    converged::Bool
    derivative_methods::Vector{Symbol}
end

"""A smooth coupled-set boundary normal mapped into model coordinates."""
struct CoupledSetMappedTangent{T<:AbstractFloat}
    source::EntityRef
    set_kind::Symbol
    rows::Vector{Int}
    gradient::Vector{T}
    derivative_methods::Vector{Symbol}
end

"""Coupled-set activity evidence tied to one numerical evaluation point."""
struct CoupledSetFeasibilitySummary{T<:AbstractFloat}
    point::EvaluationPoint{T}
    activities::Vector{CoupledSetActivity{T}}
    tangents::Vector{CoupledSetTangentEvidence{T}}
    feasibility_tolerance::T
    active_tolerance::T
    complete::Bool
    reason::Union{Nothing,String}
end


"""
Result of a deliberately conservative Mangasarian--Fromovitz screen.

`direction_found` is a sufficient numerical certificate. A
`failure_witness_found` result is a separate numerical Farkas-style witness:
a nonnegative convex combination of selected active inequality gradients is
nearly zero in the equality tangent space. Neither result is an exact
mathematical certificate outside the recorded derivative and tolerance model.
"""
struct MFCQScreen{T<:AbstractFloat}
    available::Bool
    reason::Union{Nothing,String}
    equality_rows::Vector{Int}
    inequality_rows::Vector{Int}
    direction_found::Bool
    direction::Vector{T}
    largest_active_inequality_directional_derivative::Union{Nothing,T}
    failure_witness_found::Bool
    failure_witness_weights::Vector{T}
    failure_witness_residual::Union{Nothing,T}
    failure_witness_projected_gradient_scale::Union{Nothing,T}
    failure_witness_effective_tolerance::Union{Nothing,T}
    failure_witness_iterations::Int
    failure_witness_converged::Bool
    equality_jacobian_rank::Union{Nothing,Int}
    equality_jacobian_threshold::Union{Nothing,T}
end

"""Backward-compatible construction without witness scale/progress evidence."""
function MFCQScreen{T}(
    available::Bool,
    reason::Union{Nothing,String},
    equality_rows::Vector{Int},
    inequality_rows::Vector{Int},
    direction_found::Bool,
    direction::Vector{T},
    largest_active_inequality_directional_derivative::Union{Nothing,T},
    failure_witness_found::Bool,
    failure_witness_weights::Vector{T},
    failure_witness_residual::Union{Nothing,T},
) where {T<:AbstractFloat}
    return MFCQScreen{T}(
        available, reason, equality_rows, inequality_rows, direction_found,
        direction, largest_active_inequality_directional_derivative,
        failure_witness_found, failure_witness_weights, failure_witness_residual,
        nothing, nothing, 0, false, nothing, nothing,
    )
end

"""Backward-compatible construction without equality-rank evidence."""
function MFCQScreen{T}(
    available::Bool,
    reason::Union{Nothing,String},
    equality_rows::Vector{Int},
    inequality_rows::Vector{Int},
    direction_found::Bool,
    direction::Vector{T},
    largest_active_inequality_directional_derivative::Union{Nothing,T},
    failure_witness_found::Bool,
    failure_witness_weights::Vector{T},
    failure_witness_residual::Union{Nothing,T},
    failure_witness_projected_gradient_scale::Union{Nothing,T},
    failure_witness_effective_tolerance::Union{Nothing,T},
    failure_witness_iterations::Int,
) where {T<:AbstractFloat}
    return MFCQScreen{T}(
        available, reason, equality_rows, inequality_rows, direction_found,
        direction, largest_active_inequality_directional_derivative,
        failure_witness_found, failure_witness_weights, failure_witness_residual,
        failure_witness_projected_gradient_scale,
        failure_witness_effective_tolerance, failure_witness_iterations, false,
        nothing, nothing,
    )
end

"""
Local least-squares recovery of multipliers for explicitly selected active sides.

The result is diagnostic evidence, not a solver dual solution. `unique` refers
only to the selected active-gradient system at the recorded point.
"""
struct MultiplierRecovery{T<:AbstractFloat}
    available::Bool
    reason::Union{Nothing,String}
    point::EvaluationPoint{T}
    rows::Vector{Int}
    sides::Vector{Symbol}
    multipliers::Vector{T}
    active_gradient_rank::Int
    unique::Bool
    stationarity_residual_norm::Union{Nothing,T}
    objective_weight::T
    feasible_point::Bool
    inequality_dual_violation::Union{Nothing,T}
    complementarity_residual::Union{Nothing,T}
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
Typed, dependency-free metadata supplied by an optional domain plugin.
"""
struct ComponentMetadata
    component_type::Symbol
    component_id::String
    variables::Vector{MOI.VariableIndex}
    constraints::Vector{EntityRef}
    units::Dict{Symbol,String}
    expected_rank::Union{Nothing,Int}
    metadata::Dict{String,String}
end

"""
Typed port/connection declaration supplied by an optional domain plugin.

`connection_matrix` maps the declared mode coordinates (its columns) into the
declared terminal coordinates (its rows). The generic core preserves this map
as inspectable structural metadata; its physical voltage/current semantics are
owned by the plugin.
"""
struct ComponentPortMetadata{T<:AbstractFloat}
    component_type::Symbol
    component_id::String
    port_id::String
    terminal_labels::Vector{String}
    mode_labels::Vector{String}
    variables::Vector{MOI.VariableIndex}
    connection_matrix::Matrix{T}
    metadata::Dict{String,String}
end

"""A plugin-declared terminal- or mode-space null direction for one port map."""
struct PortNullspaceMode{T<:AbstractFloat}
    component_type::Symbol
    component_id::String
    port_id::String
    name::Union{Nothing,Symbol}
    space::Symbol
    direction::Vector{T}
    description::String
end

"""
Opaque plugin-owned semantic label for one named `PortNullspaceMode`.

`category` is intentionally not interpreted by the generic core. It gives a
domain plugin a stable way to retain identifiers such as `:floating_neutral`
or `:delta_circulation` beside generic structural and numerical evidence.
"""
struct PortNullspaceModeSemantics
    component_type::Symbol
    component_id::String
    port_id::String
    mode_name::Symbol
    category::Symbol
    description::String
end

"""A plugin-declared directed linear map between two named component ports."""
struct PortConnectionMetadata{T<:AbstractFloat}
    from_component_type::Symbol
    from_component_id::String
    from_port_id::String
    to_component_type::Symbol
    to_component_id::String
    to_port_id::String
    connection_matrix::Matrix{T}
    metadata::Dict{String,String}
end

"""Structural connected-component summary of a declared port assembly graph."""
struct PortAssemblySummary
    available::Bool
    reason::Union{Nothing,String}
    port_count::Int
    connection_count::Int
    component_count::Int
    connected_component_count::Int
    nodes::Vector{String}
    connected_components::Vector{Vector{String}}
end

"""Static fingerprint of a plugin-declared nonlinear current law."""
struct CurrentLawFingerprint
    component_type::Symbol
    component_id::String
    law_family::Symbol
    terminal_labels::Vector{String}
    differentiability::Symbol
    singularity_risk::Symbol
    metadata::Dict{String,String}
end

"""One operating-point observation of a plugin-declared current law.

The voltage and current magnitudes use the coordinate convention declared by
the caller. `derivative_norm` is a local real 2-by-2 finite-difference estimate
of the complex current map; it is evidence about the supplied point, not a
certificate about the full nonlinear model.
"""
struct CurrentLawOperatingPointProbe
    component_type::Symbol
    component_id::String
    law_family::Symbol
    terminal_labels::Vector{String}
    voltage_magnitude::Float64
    current_magnitude::Float64
    derivative_norm::Union{Nothing,Float64}
    derivative_condition::Union{Nothing,Float64}
    domain_status::Symbol
    finite::Bool
    metadata::Dict{String,String}
end

"""Typed operating-point fingerprint for one public Volt-var/Volt-watt curve.

The observation keeps controller semantics separate from the generic current-law
probe. `equation_residual` is used for Volt-var equality evidence, while
`cap_violation` is used for Volt-watt inequality evidence. Missing values are
represented as `nothing`, never as zero.
"""
struct ControllerCurveOperatingPointObservation
    component_type::Symbol
    component_id::String
    curve_family::Symbol
    terminal_labels::Vector{String}
    voltage_reference::Symbol
    aggregation::Symbol
    monitor_semantics::Symbol
    monitored_voltage::Union{Nothing,Float64}
    output_normalized::Union{Nothing,Float64}
    local_slope::Union{Nothing,Float64}
    breakpoint_distance::Union{Nothing,Float64}
    smoothing_epsilon::Union{Nothing,Float64}
    device_base::Union{Nothing,Float64}
    expected_output::Union{Nothing,Float64}
    equation_residual::Union{Nothing,Float64}
    cap_violation::Union{Nothing,Float64}
    status::Symbol
    metadata::Dict{String,String}
end

"""A plugin-declared linear constitutive map over one or more named ports.

The matrix acts on the concatenated terminal coordinates listed in
`port_terminal_labels`; its rows are labeled equations or coil coordinates.
Unlike `PortConnectionMetadata`, this map is not interpreted as a network
equality or a topology edge.
"""
struct PortConstitutiveMap{T<:AbstractFloat}
    component_type::Symbol
    component_id::String
    map_id::String
    port_ids::Vector{String}
    port_terminal_labels::Vector{Vector{String}}
    matrix::Matrix{T}
    equation_labels::Vector{String}
    metadata::Dict{String,String}
end

"""Nullspace of explicitly declared port-connection equations."""
struct PortTopologyNullspace{T<:AbstractFloat}
    available::Bool
    reason::Union{Nothing,String}
    port_keys::Vector{Tuple{Symbol,String,String}}
    connection_matrix::Matrix{T}
    rank::Int
    nullspace::Matrix{T}
end

"""A plugin-declared linear map from port terminal coordinates to model variables."""
struct PortCoordinateMap{T<:AbstractFloat}
    component_type::Symbol
    component_id::String
    port_id::String
    variables::Vector{MOI.VariableIndex}
    terminal_to_variable::Matrix{T}
    description::String
end

"""Plugin-declared physical interpretation of one port's terminal coordinates."""
struct PortCoordinateSemantics
    component_type::Symbol
    component_id::String
    port_id::String
    quantity::Symbol
    representation::Symbol
    units::Dict{String,String}
    nominal_scale::Union{Nothing,Float64}
    description::String
end

"""Compatibility construction for port semantics without a nominal scale."""
function PortCoordinateSemantics(
    component_type::Symbol,
    component_id::String,
    port_id::String,
    quantity::Symbol,
    representation::Symbol,
    units::Dict{String,String},
    description::String,
)
    return PortCoordinateSemantics(
        component_type, component_id, port_id, quantity, representation,
        units, nothing, description,
    )
end

"""Plugin-declared physical interpretation of selected component model coordinates."""
struct ComponentCoordinateSemantics
    component_type::Symbol
    component_id::String
    variables::Vector{MOI.VariableIndex}
    quantity::Symbol
    representation::Symbol
    units::Dict{String,String}
    nominal_scale::Union{Nothing,Float64}
    description::String
end

"""Plugin-declared nominal scale for set-relative scalar constraint violations."""
struct ComponentConstraintScaleSemantics
    component_type::Symbol
    component_id::String
    constraints::Vector{EntityRef}
    quantity::Symbol
    units::Dict{String,String}
    nominal_scale::Float64
    description::String
end

"""Compatibility construction for component semantics without a nominal scale."""
function ComponentCoordinateSemantics(
    component_type::Symbol,
    component_id::String,
    variables::Vector{MOI.VariableIndex},
    quantity::Symbol,
    representation::Symbol,
    units::Dict{String,String},
    description::String,
)
    return ComponentCoordinateSemantics(
        component_type, component_id, variables, quantity, representation,
        units, nothing, description,
    )
end

function ComponentConstraintScaleSemantics(
    component_type::Symbol,
    component_id,
    constraints::AbstractVector{<:EntityRef};
    quantity::Symbol = :generic,
    units::AbstractDict = Dict{String,String}(),
    nominal_scale::Real,
    description::AbstractString = "",
)
    isempty(String(component_type)) && throw(ArgumentError("component_type must be nonempty"))
    isempty(strip(string(component_id))) && throw(ArgumentError("component_id must be nonempty"))
    isempty(constraints) && throw(ArgumentError("constraint scale semantics requires at least one constraint"))
    length(unique(constraints)) == length(constraints) ||
        throw(ArgumentError("constraint scale semantics constraint references must be unique"))
    all(reference -> reference.kind in (:constraint, :nlp_constraint), constraints) ||
        throw(ArgumentError("constraint scale semantics references must have kind :constraint or :nlp_constraint"))
    isfinite(nominal_scale) && nominal_scale > 0 ||
        throw(ArgumentError("constraint nominal_scale must be finite and positive"))
    return ComponentConstraintScaleSemantics(
        component_type, string(component_id), collect(constraints), quantity,
        Dict(string(key) => string(value) for (key, value) in units),
        Float64(nominal_scale), String(description),
    )
end

"""A topology-nullspace basis projected through plugin-declared port coordinate maps."""
struct PortTopologyCoordinateProjection{T<:AbstractFloat}
    available::Bool
    reason::Union{Nothing,String}
    variables::Vector{MOI.VariableIndex}
    topology::PortTopologyNullspace{T}
    projected_nullspace::Matrix{T}
    consistency_residual::T
end

"""
Inspectable model-coordinate span of projected component- and topology-port
expected-mode candidates. Candidate directions remain individually named for
provenance; `rank` is their independent coordinate-span dimension.
"""
struct PortExpectedNullspaceSummary{T<:AbstractFloat}
    variables::Vector{MOI.VariableIndex}
    candidate_names::Vector{Symbol}
    candidate_origins::Vector{Symbol}
    candidate_descriptions::Vector{String}
    directions::Matrix{T}
    rank::Int
    relative_tolerance::T
end

"""Inspectable, non-mutating scope for a future elastic-feasibility auxiliary model."""
struct ElasticFeasibilityPlan
    relaxable_constraints::Vector{EntityRef}
    unsupported_constraints::Vector{EntityRef}
    excluded_constraints::Vector{EntityRef}
    relaxation_count::Int
    slack_count::Int
end

"""One source constraint and its nonnegative elastic auxiliary variables."""
struct ElasticRelaxation
    source::EntityRef
    slacks::Vector{MOI.VariableIndex}
    weight::Float64
    kind::Symbol
end

"""A nonlinear operator-domain condition relevant to an elastic auxiliary scope."""
struct ElasticDomainGuard
    source::EntityRef
    path::Vector{Int}
    operator::Symbol
    argument::Int
    requirement::String
    assessment::Symbol
    variables::Vector{MOI.VariableIndex}
    lower::Float64
    upper::Float64
    interval_informative::Bool
    materializable::Bool
    reason::String
    related_argument::Union{Nothing,Int}
end

"""Compatibility construction for a one-argument elastic domain guard."""
function ElasticDomainGuard(
    source::EntityRef,
    path::Vector{Int},
    operator::Symbol,
    argument::Int,
    requirement::String,
    assessment::Symbol,
    variables::Vector{MOI.VariableIndex},
    lower::Float64,
    upper::Float64,
    interval_informative::Bool,
    materializable::Bool,
    reason::String,
)
    return ElasticDomainGuard(
        source, path, operator, argument, requirement, assessment, variables,
        lower, upper, interval_informative, materializable, reason, nothing,
    )
end

"""Inspectable scope for optional, explicit nonlinear domain guards."""
struct ElasticDomainGuardPlan
    guards::Vector{ElasticDomainGuard}
    nonmaterializable::Vector{ElasticDomainGuard}
    selected_constraint_count::Int
end

"""A separately built affine elastic-feasibility auxiliary model."""
struct ElasticFeasibilityModel
    model::Any
    plan::ElasticFeasibilityPlan
    relaxations::Vector{ElasticRelaxation}
    source_variable_map::Dict{MOI.VariableIndex,MOI.VariableIndex}
    objective_norm::Symbol
    epigraph_variable::Union{Nothing,MOI.VariableIndex}
    relaxed_constraint_map::Dict{EntityRef,Any}
    domain_guards::Vector{ElasticDomainGuard}
    domain_guard_margin::Union{Nothing,Float64}
end

"""Observed slack values mapped back to one original constraint."""
struct ElasticRelaxationValue
    source::EntityRef
    values::Vector{Float64}
    total::Float64
    weighted_total::Float64
    kind::Symbol
end

"""An explicitly solved elastic auxiliary model and its auxiliary-to-solver slack map."""
struct ElasticFeasibilitySolve
    auxiliary::ElasticFeasibilityModel
    optimizer::Any
    slack_map::Dict{MOI.VariableIndex,MOI.VariableIndex}
end

"""One solved scope considered by a greedy local elastic-subset experiment."""
struct ElasticSubsetProbe
    selected_constraints::Vector{EntityRef}
    objective_value::Union{Nothing,Float64}
    has_primal_result::Bool
    termination_status::String
    primal_status::String
end

"""Inspectable result of a greedy, scope-dependent elastic subset reduction."""
struct ElasticSubsetSearch
    baseline::ElasticSubsetProbe
    probes::Vector{ElasticSubsetProbe}
    retained_constraints::Vector{EntityRef}
    removed_constraints::Vector{EntityRef}
    tolerance::Float64
end

"""Order-sensitivity summary for multiple local elastic subset reductions."""
struct ElasticSubsetEnsemble
    searches::Vector{ElasticSubsetSearch}
    consensus_constraints::Vector{EntityRef}
    possible_constraints::Vector{EntityRef}
end

"""Bounded exact search result for minimum-cardinality elastic relaxation supports."""
struct ElasticMinimumRelaxationSearch
    candidate_constraints::Vector{EntityRef}
    minimum_relaxation_count::Union{Nothing,Int}
    solutions::Vector{ElasticSubsetProbe}
    evaluated_count::Int
    truncated::Bool
    tolerance::Float64
end

"""Solver-provided conflict memberships mapped back to source constraints."""
struct SolverConflictResult
    optimizer_type::String
    optimize_before_conflict::Bool
    termination_status::String
    conflict_status::String
    source_variable_count::Int
    source_constraint_count::Int
    conflicts::Vector{Vector{EntityRef}}
    maybe_conflicts::Vector{Vector{EntityRef}}
    error::Union{Nothing,String}
end

"""Compatibility construction for conflict evidence without recorded source scope."""
function SolverConflictResult(
    optimizer_type::AbstractString,
    optimize_before_conflict::Bool,
    termination_status::AbstractString,
    conflict_status::AbstractString,
    conflicts::Vector{Vector{EntityRef}},
    maybe_conflicts::Vector{Vector{EntityRef}},
    error::Union{Nothing,AbstractString},
)
    return SolverConflictResult(
        String(optimizer_type), optimize_before_conflict, String(termination_status),
        String(conflict_status), 0, 0, conflicts, maybe_conflicts,
        isnothing(error) ? nothing : String(error),
    )
end

function ComponentMetadata(
    component_type::Symbol,
    component_id;
    variables::AbstractVector{MOI.VariableIndex} = MOI.VariableIndex[],
    constraints::AbstractVector{EntityRef} = EntityRef[],
    units::AbstractDict = Dict{Symbol,String}(),
    expected_rank::Union{Nothing,Integer} = nothing,
    metadata::AbstractDict = Dict{String,String}(),
)
    isempty(String(component_type)) &&
        throw(ArgumentError("component_type must be nonempty"))
    isempty(strip(string(component_id))) &&
        throw(ArgumentError("component_id must be nonempty"))
    !isnothing(expected_rank) && expected_rank < 0 &&
        throw(ArgumentError("expected_rank must be nonnegative"))
    length(unique(variables)) == length(variables) ||
        throw(ArgumentError("component metadata variables must be unique"))
    all(constraint -> constraint.kind == :constraint, constraints) ||
        throw(ArgumentError("component metadata constraints must be constraint references"))
    # A one-sided declaration has an unambiguous rank ceiling. With both
    # variable and constraint scope present, plugins may intentionally expose
    # only part of a component's internal equations, so retain the declaration
    # for the later, evidence-bearing metadata diagnostic.
    one_sided_scope = isempty(variables) ? length(constraints) :
                      (isempty(constraints) ? length(variables) : 0)
    !isnothing(expected_rank) && one_sided_scope > 0 && expected_rank > one_sided_scope &&
        throw(ArgumentError("expected_rank cannot exceed the declared one-sided component scope"))
    any(isempty(String(key)) || isempty(strip(string(value))) for (key, value) in units) &&
        throw(ArgumentError("unit field names and labels must be nonempty"))
    return ComponentMetadata(component_type, string(component_id), collect(variables), collect(constraints),
        Dict(Symbol(key) => string(value) for (key, value) in units),
        isnothing(expected_rank) ? nothing : Int(expected_rank),
        Dict(string(key) => string(value) for (key, value) in metadata))
end

function ComponentPortMetadata(
    component_type::Symbol,
    component_id,
    port_id;
    terminal_labels::AbstractVector = String[],
    mode_labels::AbstractVector = String[],
    variables::AbstractVector{MOI.VariableIndex} = MOI.VariableIndex[],
    connection_matrix::AbstractArray{<:Real},
    metadata::AbstractDict = Dict{String,String}(),
)
    isempty(String(component_type)) &&
        throw(ArgumentError("component_type must be nonempty"))
    isempty(strip(string(component_id))) &&
        throw(ArgumentError("component_id must be nonempty"))
    isempty(strip(string(port_id))) &&
        throw(ArgumentError("port_id must be nonempty"))
    terminals = string.(terminal_labels)
    modes = string.(mode_labels)
    isempty(terminals) && throw(ArgumentError("port terminal_labels must be nonempty"))
    isempty(modes) && throw(ArgumentError("port mode_labels must be nonempty"))
    any(isempty ∘ strip, terminals) &&
        throw(ArgumentError("port terminal labels must be nonempty"))
    any(isempty ∘ strip, modes) &&
        throw(ArgumentError("port mode labels must be nonempty"))
    length(unique(terminals)) == length(terminals) ||
        throw(ArgumentError("port terminal labels must be unique"))
    length(unique(modes)) == length(modes) ||
        throw(ArgumentError("port mode labels must be unique"))
    length(unique(variables)) == length(variables) ||
        throw(ArgumentError("port variables must be unique"))
    size(connection_matrix) == (length(terminals), length(modes)) ||
        throw(DimensionMismatch(
            "connection_matrix dimensions must match terminal_labels by mode_labels",
        ))
    T = float(eltype(connection_matrix))
    return ComponentPortMetadata{T}(
        component_type,
        string(component_id),
        string(port_id),
        terminals,
        modes,
        collect(variables),
        T.(connection_matrix),
        Dict(string(key) => string(value) for (key, value) in metadata),
    )
end

function PortNullspaceMode(
    component_type::Symbol,
    component_id,
    port_id,
    space::Symbol,
    direction::AbstractVector{<:Real};
    name::Union{Nothing,Symbol} = nothing,
    description::AbstractString = "",
)
    space in (:terminal, :mode) ||
        throw(ArgumentError("port nullspace space must be :terminal or :mode"))
    isempty(direction) && throw(ArgumentError("port nullspace direction must be nonempty"))
    !isnothing(name) && isempty(strip(string(name))) &&
        throw(ArgumentError("port nullspace mode name must be nonempty when supplied"))
    T = float(promote_type(map(typeof, direction)...))
    converted = T.(direction)
    all(isfinite, converted) ||
        throw(ArgumentError("port nullspace direction must be finite"))
    iszero(norm(converted)) &&
        throw(ArgumentError("port nullspace direction must be nonzero"))
    return PortNullspaceMode{T}(
        component_type, string(component_id), string(port_id), name, space,
        converted, String(description),
    )
end

function PortNullspaceModeSemantics(
    component_type::Symbol,
    component_id,
    port_id,
    mode_name::Symbol;
    category::Symbol,
    description::AbstractString = "",
)
    all(!isempty(strip(string(value))) for value in (
        component_type, component_id, port_id, mode_name, category,
    )) || throw(ArgumentError("port nullspace mode semantic identities and category must be nonempty"))
    return PortNullspaceModeSemantics(
        component_type, string(component_id), string(port_id), mode_name,
        category, String(description),
    )
end

function PortConnectionMetadata(
    from_component_type::Symbol, from_component_id, from_port_id,
    to_component_type::Symbol, to_component_id, to_port_id;
    connection_matrix::AbstractMatrix{<:Real},
    metadata::AbstractDict = Dict{String,String}(),
)
    all(!isempty(strip(string(value))) for value in (
        from_component_type, from_component_id, from_port_id,
        to_component_type, to_component_id, to_port_id,
    )) || throw(ArgumentError("port connection identities must be nonempty"))
    T = float(eltype(connection_matrix))
    return PortConnectionMetadata{T}(
        from_component_type, string(from_component_id), string(from_port_id),
        to_component_type, string(to_component_id), string(to_port_id),
        T.(connection_matrix), Dict(string(key) => string(value) for (key, value) in metadata),
    )
end

function PortConstitutiveMap(
    component_type::Symbol, component_id, map_id,
    port_ids::AbstractVector,
    port_terminal_labels::AbstractVector{<:AbstractVector},
    matrix::AbstractMatrix{<:Real};
    equation_labels::AbstractVector = String[],
    metadata::AbstractDict = Dict{String,String}(),
)
    all(!isempty(strip(string(value))) for value in (component_type, component_id, map_id)) ||
        throw(ArgumentError("port constitutive-map identities must be nonempty"))
    length(port_ids) == length(port_terminal_labels) ||
        throw(DimensionMismatch("port ids and terminal-label groups must have equal length"))
    ids = string.(port_ids)
    all(!isempty(strip(id)) for id in ids) ||
        throw(ArgumentError("port constitutive-map port ids must be nonempty"))
    length(unique(ids)) == length(ids) ||
        throw(ArgumentError("port constitutive-map port ids must be unique"))
    labels = [string.(collect(group)) for group in port_terminal_labels]
    all(!isempty(label) for group in labels for label in group) ||
        throw(ArgumentError("port constitutive-map terminal labels must be nonempty"))
    expected_columns = sum(length, labels; init = 0)
    size(matrix, 2) == expected_columns ||
        throw(DimensionMismatch("constitutive-map columns must match concatenated port terminal coordinates"))
    equations = isempty(equation_labels) ?
        ["equation$(index)" for index in axes(matrix, 1)] : string.(equation_labels)
    length(equations) == size(matrix, 1) ||
        throw(DimensionMismatch("constitutive-map equation labels must match matrix rows"))
    all(!isempty(strip(label)) for label in equations) ||
        throw(ArgumentError("port constitutive-map equation labels must be nonempty"))
    all(isfinite, matrix) || throw(ArgumentError("port constitutive-map matrix must be finite"))
    T = float(eltype(matrix))
    return PortConstitutiveMap{T}(
        component_type, string(component_id), string(map_id), ids, labels,
        T.(matrix), equations,
        Dict(string(key) => string(value) for (key, value) in metadata),
    )
end

function PortCoordinateMap(
    component_type::Symbol, component_id, port_id,
    variables::AbstractVector{MOI.VariableIndex};
    terminal_to_variable::AbstractMatrix{<:Real},
    description::AbstractString = "",
)
    all(!isempty(strip(string(value))) for value in (component_type, component_id, port_id)) ||
        throw(ArgumentError("port coordinate-map identities must be nonempty"))
    length(unique(variables)) == length(variables) ||
        throw(ArgumentError("port coordinate-map variables must be unique"))
    size(terminal_to_variable, 1) == length(variables) ||
        throw(DimensionMismatch(
            "terminal_to_variable rows must match declared variables",
        ))
    T = float(eltype(terminal_to_variable))
    return PortCoordinateMap{T}(
        component_type, string(component_id), string(port_id), collect(variables),
        T.(terminal_to_variable), String(description),
    )
end

function PortCoordinateSemantics(
    component_type::Symbol, component_id, port_id;
    quantity::Symbol,
    representation::Symbol = :generic,
    units::AbstractDict = Dict{String,String}(),
    nominal_scale::Union{Nothing,Real} = nothing,
    description::AbstractString = "",
)
    all(!isempty(strip(string(value))) for value in (component_type, component_id, port_id)) ||
        throw(ArgumentError("port coordinate-semantics identities must be nonempty"))
    quantity in (:voltage, :current, :power, :angle, :generic) ||
        throw(ArgumentError("port coordinate quantity must be :voltage, :current, :power, :angle, or :generic"))
    isempty(String(representation)) &&
        throw(ArgumentError("port coordinate representation must be nonempty"))
    any(isempty(strip(string(key))) || isempty(strip(string(value))) for (key, value) in units) &&
        throw(ArgumentError("port coordinate semantics unit names and labels must be nonempty"))
    !isnothing(nominal_scale) &&
        (!isfinite(nominal_scale) || nominal_scale <= 0) &&
        throw(ArgumentError("port coordinate nominal_scale must be finite and positive"))
    return PortCoordinateSemantics(
        component_type, string(component_id), string(port_id), quantity, representation,
        Dict(string(key) => string(value) for (key, value) in units),
        isnothing(nominal_scale) ? nothing : Float64(nominal_scale), String(description),
    )
end

function ComponentCoordinateSemantics(
    component_type::Symbol, component_id, variables::AbstractVector{MOI.VariableIndex};
    quantity::Symbol, representation::Symbol = :generic,
    units::AbstractDict = Dict{String,String}(),
    nominal_scale::Union{Nothing,Real} = nothing,
    description::AbstractString = "",
)
    all(!isempty(strip(string(value))) for value in (component_type, component_id)) ||
        throw(ArgumentError("component coordinate-semantics identities must be nonempty"))
    isempty(variables) && throw(ArgumentError("component coordinate semantics requires variables"))
    length(unique(variables)) == length(variables) ||
        throw(ArgumentError("component coordinate semantics variables must be unique"))
    quantity in (:voltage, :current, :power, :angle, :generic) ||
        throw(ArgumentError("component coordinate quantity is unsupported"))
    isempty(String(representation)) && throw(ArgumentError("component coordinate representation must be nonempty"))
    any(isempty(strip(string(key))) || isempty(strip(string(value))) for (key, value) in units) &&
        throw(ArgumentError("component coordinate semantics unit names and labels must be nonempty"))
    !isnothing(nominal_scale) &&
        (!isfinite(nominal_scale) || nominal_scale <= 0) &&
        throw(ArgumentError("component coordinate nominal_scale must be finite and positive"))
    return ComponentCoordinateSemantics(component_type, string(component_id), collect(variables),
        quantity, representation, Dict(string(key) => string(value) for (key, value) in units),
        isnothing(nominal_scale) ? nothing : Float64(nominal_scale), String(description))
end

"""
A named expected right-nullspace direction supplied by a caller or domain plugin.

The direction is expressed in the listed `MOI.VariableIndex` coordinates. It
is an expectation to compare with local numerical evidence, not an assertion
that the model is correctly referenced or physically valid.
"""
struct ExpectedNullspaceMode{T<:AbstractFloat}
    name::Symbol
    variables::Vector{MOI.VariableIndex}
    direction::Vector{T}
    description::String
end

function ExpectedNullspaceMode(
    name::Symbol,
    variables::AbstractVector{MOI.VariableIndex},
    direction::AbstractVector{<:Real};
    description::AbstractString = "",
)
    length(variables) == length(direction) ||
        throw(DimensionMismatch("expected-nullspace variables and direction lengths differ"))
    isempty(variables) &&
        throw(ArgumentError("expected-nullspace direction must not be empty"))
    length(unique(variables)) == length(variables) ||
        throw(ArgumentError("expected-nullspace variables must be unique"))
    T = float(promote_type(map(typeof, direction)...))
    converted = T.(direction)
    all(isfinite, converted) ||
        throw(ArgumentError("expected-nullspace direction must be finite"))
    iszero(norm(converted)) &&
        throw(ArgumentError("expected-nullspace direction must be nonzero"))
    return ExpectedNullspaceMode{T}(
        name,
        collect(variables),
        converted,
        String(description),
    )
end

"""
A plugin-supplied coordinate scope for a physically admissible tangent check.

The variables are additional model coordinates that may be fixed or otherwise
excluded from the generic free-variable comparison. Including them does not
release bounds or modify the model; it only asks the numerical comparison to
retain those columns and records the policy provenance.
"""
struct ExpectedNullspaceTangentPolicy
    name::Symbol
    variables::Vector{MOI.VariableIndex}
    description::String
    metadata::Dict{String,String}
end

function ExpectedNullspaceTangentPolicy(
    name::Symbol,
    variables::AbstractVector{MOI.VariableIndex};
    description::AbstractString = "",
    metadata::AbstractDict = Dict{String,String}(),
)
    isempty(variables) && throw(ArgumentError(
        "expected-nullspace tangent policy must retain at least one variable",
    ))
    length(unique(variables)) == length(variables) || throw(ArgumentError(
        "expected-nullspace tangent policy variables must be unique",
    ))
    isempty(strip(String(description))) && throw(ArgumentError(
        "expected-nullspace tangent policy description must not be empty",
    ))
    return ExpectedNullspaceTangentPolicy(
        name,
        collect(variables),
        String(description),
        Dict(string(key) => string(value) for (key, value) in metadata),
    )
end

"""
A labeled, solver-independent numerical profiling scenario.

The descriptive fields make task, formulation, initialization, scale, and
solver intent explicit without requiring the generic core to understand their
domain semantics. `expected_evidence` records hypotheses to inspect, not
assertions.
"""
struct ProfileCase{T<:AbstractFloat}
    name::String
    description::String
    task::Union{Nothing,String}
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
    task::Union{Nothing,AbstractString} = nothing,
    formulation::AbstractString = "unspecified",
    initialization::AbstractString = point.label,
    scale::AbstractString = "unspecified",
    solver::Union{Nothing,AbstractString} = nothing,
    expected_evidence::AbstractVector{Symbol} = Symbol[],
    tags::AbstractVector{Symbol} = Symbol[],
    metadata::AbstractDict = Dict{String,String}(),
) where {T<:AbstractFloat}
    resolved_tags = unique!(collect(tags))
    resolved_point = point
    if :synthetic in resolved_tags &&
       point.provenance.kind == UserPoint &&
       point.provenance.source == "user"
        resolved_point = EvaluationPoint{T}(
            point.variables,
            point.values,
            point.label,
            EvaluationPointProvenance(
                SyntheticSmokePoint;
                source = "ProfileCase :synthetic tag",
                complete = point.provenance.complete,
                metadata = merge(
                    point.provenance.metadata,
                    Dict("profile_case" => String(name)),
                ),
            ),
        )
    end
    return ProfileCase{T}(
        String(name),
        String(description),
        isnothing(task) || isempty(strip(task)) ? nothing : String(task),
        String(formulation),
        String(initialization),
        String(scale),
        isnothing(solver) ? nothing : String(solver),
        unique!(collect(expected_evidence)),
        resolved_tags,
        Dict(string(key) => string(value) for (key, value) in metadata),
        resolved_point,
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
    objective_gradient_method::Symbol
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
        Dict{Symbol,Tuple{Int,Float64}}(), :unavailable,
    )
end

"""Require supplied numerical coordinates to match the model's public MOI order."""
function _validate_evaluation_variable_order(
    model::MOI.ModelLike,
    evaluation::NumericalEvaluation,
)
    evaluation.point.variables == MOI.get(model, MOI.ListOfVariableIndices()) ||
        throw(ArgumentError(
            "evaluation-point variable order does not match ListOfVariableIndices",
        ))
    return nothing
end

"""
One explicitly supplied reduced-Hessian result for cross-point comparison.

The snapshot preserves the point and the local analysis separately so a
persistence screen never reconstructs an iterate or silently recomputes a
Hessian.
"""
struct ReducedHessianSnapshot{T<:AbstractFloat}
    evaluation::NumericalEvaluation{T}
    analysis::ReducedHessianAnalysis{T}
    hessian::Union{Nothing,HessianEvaluation{T}}
end

function ReducedHessianSnapshot(
    evaluation::NumericalEvaluation{T},
    analysis::ReducedHessianAnalysis{T},
) where {T<:AbstractFloat}
    size(analysis.tangent_basis, 1) == length(evaluation.point.variables) ||
        throw(DimensionMismatch(
            "reduced-Hessian tangent basis does not match evaluation coordinates",
        ))
    return ReducedHessianSnapshot{T}(evaluation, analysis, nothing)
end

function ReducedHessianSnapshot(
    evaluation::NumericalEvaluation{T},
    analysis::ReducedHessianAnalysis{T},
    hessian::HessianEvaluation{T},
) where {T<:AbstractFloat}
    size(analysis.tangent_basis, 1) == length(evaluation.point.variables) ||
        throw(DimensionMismatch(
            "reduced-Hessian tangent basis does not match evaluation coordinates",
        ))
    hessian.point == evaluation.point ||
        throw(ArgumentError("reduced-Hessian snapshot Hessian point differs from evaluation point"))
    return ReducedHessianSnapshot{T}(evaluation, analysis, hessian)
end

"""
Evidence and wall-clock timings from one `ProfileCase` run.

Timings are diagnostic observations and include Julia compilation/allocation
effects unless the caller has performed a warm-up run.
"""
struct ProfileResult{T<:AbstractFloat}
    case::ProfileCase{T}
    evaluation::NumericalEvaluation{T}
    static_report::DiagnosticReport
    expression_report::DiagnosticReport
    reformulation_report::DiagnosticReport
    numerical_report::DiagnosticReport
    active_set_report::DiagnosticReport
    degeneracy_report::DiagnosticReport
    stage_seconds::Dict{Symbol,Float64}
    stage_allocations::Dict{Symbol,Int}
    callback_statistics::Dict{Symbol,Tuple{Int,Float64}}
    derivative_row_method_counts::Dict{Symbol,Int}
    capability_source_counts::Dict{Symbol,Int}
    cache_hits::Int
    cache_misses::Int
end

"""
One generic profile run plus optional domain-plugin context evidence.

`BMOPFProfileResult` keeps BMOPFTools-specific observations separate from the
generic `ProfileResult`, so plugin construction metadata is not mistaken for a
generic numerical stage while one serializable benchmark record is retained.
"""
struct BMOPFProfileResult{T<:AbstractFloat}
    profile::ProfileResult{T}
    context_report::DiagnosticReport
    initialization_report::Union{Nothing,DiagnosticReport}
    bmopf_stage_seconds::Dict{Symbol,Float64}
    bmopf_stage_allocations::Dict{Symbol,Int}
end

"""Backward-compatible positional construction without static/expression/reformulation reports."""
function ProfileResult(
    case::ProfileCase{T},
    evaluation::NumericalEvaluation{T},
    numerical_report::DiagnosticReport,
    active_set_report::DiagnosticReport,
    degeneracy_report::DiagnosticReport,
    stage_seconds::Dict{Symbol,Float64},
    stage_allocations::Dict{Symbol,Int},
    callback_statistics::Dict{Symbol,Tuple{Int,Float64}},
    derivative_row_method_counts::Dict{Symbol,Int},
    capability_source_counts::Dict{Symbol,Int},
    cache_hits::Int,
    cache_misses::Int,
) where {T<:AbstractFloat}
    return ProfileResult{T}(
        case,
        evaluation,
        DiagnosticReport(),
        DiagnosticReport(),
        DiagnosticReport(),
        numerical_report,
        active_set_report,
        degeneracy_report,
        stage_seconds,
        stage_allocations,
        callback_statistics,
        derivative_row_method_counts,
        capability_source_counts,
        cache_hits,
        cache_misses,
    )
end

"""
Summary statistics for repeated local profiling observations.

`standard_deviation` is the population standard deviation of the retained
samples; it describes observed run-to-run spread, not a confidence interval.
"""
struct ProfileTimingSummary
    sample_count::Int
    minimum::Float64
    mean::Float64
    maximum::Float64
    standard_deviation::Float64
end

"""
Summary of bytes allocated by one profiling stage across retained runs.

Allocation counts are local Julia-runtime observations. They include any
remaining compilation and garbage-collector effects, and therefore complement
rather than replace timing or algorithmic-complexity evidence.
"""
struct ProfileAllocationSummary
    sample_count::Int
    minimum::Int
    mean::Float64
    maximum::Int
    standard_deviation::Float64
end

"""Occurrence stability of one diagnostic code across repeated profile runs."""
struct ProfileFindingStability
    stage::Symbol
    code::Symbol
    occurrence_count::Int
    run_count::Int
    fraction::Float64
end

"""
Observed recovery rate for one `ProfileCase.expected_evidence` diagnostic code.

The profile author supplies expected evidence as a hypothesis. A low recovery
rate identifies a changed or point-sensitive diagnostic path; it does not by
itself invalidate the model or the expectation.
"""
struct ProfileExpectedEvidenceSummary
    code::Symbol
    occurrence_count::Int
    run_count::Int
    fraction::Float64
end

"""
Side-by-side descriptive comparison of one measured profiling stage.

Ratios are candidate divided by baseline. They are unavailable when the
baseline mean is zero, rather than being replaced with an arbitrary value.
"""
struct ProfileStageComparison
    stage::Symbol
    baseline_seconds::Float64
    candidate_seconds::Float64
    seconds_ratio::Union{Nothing,Float64}
    baseline_allocations::Float64
    candidate_allocations::Float64
    allocations_ratio::Union{Nothing,Float64}
end

"""
Side-by-side occurrence rates for one diagnostic code in a profile stage.

The rates are observed across retained runs and do not assert that either
profile is mathematically valid or physically preferable.
"""
struct ProfileFindingComparison
    stage::Symbol
    code::Symbol
    baseline_fraction::Float64
    candidate_fraction::Float64
end

"""
Side-by-side availability-aware comparison of one numerical profile metric.

Means and their difference/ratio are unavailable when either aggregate did
not retain a finite observation. Availability counts make that distinction
explicit rather than treating an unavailable rank or condition proxy as zero.
"""
struct ProfileNumericalComparison
    metric::Symbol
    baseline_available_count::Int
    baseline_run_count::Int
    candidate_available_count::Int
    candidate_run_count::Int
    baseline_mean::Union{Nothing,Float64}
    candidate_mean::Union{Nothing,Float64}
    mean_difference::Union{Nothing,Float64}
    mean_ratio::Union{Nothing,Float64}
end

"""
Observed numerical metric across retained repeated profile runs.

Only runs that expose a finite value contribute to the descriptive statistics.
`available_count` is retained separately so an unavailable dense rank or
condition estimate cannot be mistaken for a zero-valued observation.
"""
struct ProfileNumericalSummary
    metric::Symbol
    run_count::Int
    available_count::Int
    minimum::Union{Nothing,Float64}
    mean::Union{Nothing,Float64}
    maximum::Union{Nothing,Float64}
    standard_deviation::Union{Nothing,Float64}
end

"""
Normalized evidence captured from a completed solver run.

Solver extensions translate their native status and residual information into
this immutable record. All fields are observations reported by that solver;
they are not independently verified feasibility or optimality certificates.
"""
struct SolverPostmortem
    solver::String
    termination::Symbol
    raw_status::Union{Nothing,String}
    iterations::Union{Nothing,Int}
    objective_value::Union{Nothing,Float64}
    primal_residual::Union{Nothing,Float64}
    dual_residual::Union{Nothing,Float64}
    complementarity::Union{Nothing,Float64}
    restoration_attempted::Bool
    restoration_succeeded::Union{Nothing,Bool}
    metadata::Dict{String,String}
end

"""
One read-only diagnostic capture from a solver result.

`point` is present only when every public MOI variable primal at
`result_index` was readable as a real value. `postmortem` is present only when
the caller supplied one or a loaded solver extension could read one. The
contained report keeps either absence explicit as representational evidence;
neither absence is silently replaced with defaults.
"""
struct SolverResultAnalysis
    point::Union{Nothing,EvaluationPoint}
    postmortem::Union{Nothing,SolverPostmortem}
    report::DiagnosticReport
    result_index::Int
    postmortem_read_error::Union{Nothing,String}
end

"""
One profile built from a completed solver result.

`profile` and `case` are `nothing` when the requested result did not expose a
complete primal point. `result_report` retains postmortem and availability
evidence independently of the generic profile stages.
"""
struct SolverProfileResult
    profile::Union{Nothing,ProfileResult}
    case::Union{Nothing,ProfileCase}
    postmortem::Union{Nothing,SolverPostmortem}
    result_report::DiagnosticReport
    result_index::Int
    postmortem_read_error::Union{Nothing,String}
end

"""
One line-level observation extracted from a solver log.

`category` labels text that was explicitly present in the log. It is not an
independent reconstruction of solver state and does not establish a
mathematical property of the model.
"""
struct SolverLogObservation
    line::Int
    category::Symbol
    text::String
end

"""Coordinate/scaling convention attached to one solver-reported metric."""
@enum SolverMetricCoordinates::UInt8 begin
    MetricCoordinatesUnknown = 0
    OriginalModelCoordinates = 1
    SolverScaledCoordinates = 2
    SolverDefinedCoordinates = 3
end

"""
Typed semantics for the principal numerical columns in a solver iteration row.

The fields describe coordinate/scaling provenance, not accuracy. A solver may
report the objective in original model units while reporting infeasibility or
barrier quantities in an internally scaled system. Unknown semantics remain
explicit rather than being inferred from a numeric value.
"""
struct SolverIterationMetricSemantics
    objective::SolverMetricCoordinates
    primal_infeasibility::SolverMetricCoordinates
    dual_infeasibility::SolverMetricCoordinates
    complementarity::SolverMetricCoordinates
    barrier_parameter::SolverMetricCoordinates
end

function SolverIterationMetricSemantics(;
    objective::SolverMetricCoordinates = MetricCoordinatesUnknown,
    primal_infeasibility::SolverMetricCoordinates = MetricCoordinatesUnknown,
    dual_infeasibility::SolverMetricCoordinates = MetricCoordinatesUnknown,
    complementarity::SolverMetricCoordinates = MetricCoordinatesUnknown,
    barrier_parameter::SolverMetricCoordinates = MetricCoordinatesUnknown,
)
    return SolverIterationMetricSemantics(
        objective,
        primal_infeasibility,
        dual_infeasibility,
        complementarity,
        barrier_parameter,
    )
end

"""
One solver iteration observation.

The common fields support parsed logs and public solver callbacks. Optional
algorithm telemetry is retained when the source exposes it. `semantics`
records whether the main metrics use original model coordinates, solver-scaled
coordinates, solver-defined coordinates, or an unknown convention.
"""
struct SolverIterationRecord
    format::Symbol
    line::Int
    iteration::Int
    phase::Symbol
    objective::Float64
    primal_infeasibility::Float64
    dual_infeasibility::Float64
    complementarity::Union{Nothing,Float64}
    primal_step::Union{Nothing,Float64}
    barrier_parameter::Union{Nothing,Float64}
    step_norm::Union{Nothing,Float64}
    regularization_size::Union{Nothing,Float64}
    dual_step::Union{Nothing,Float64}
    line_search_trials::Union{Nothing,Int}
    semantics::SolverIterationMetricSemantics
    text::String
end

function SolverIterationRecord(
    format::Symbol,
    line::Integer,
    iteration::Integer,
    phase::Symbol,
    objective::Real,
    primal_infeasibility::Real,
    dual_infeasibility::Real,
    complementarity::Union{Nothing,Real},
    primal_step::Union{Nothing,Real},
    text::AbstractString;
    barrier_parameter::Union{Nothing,Real} = nothing,
    step_norm::Union{Nothing,Real} = nothing,
    regularization_size::Union{Nothing,Real} = nothing,
    dual_step::Union{Nothing,Real} = nothing,
    line_search_trials::Union{Nothing,Integer} = nothing,
    semantics::SolverIterationMetricSemantics = SolverIterationMetricSemantics(),
)
    return SolverIterationRecord(
        format,
        Int(line),
        Int(iteration),
        phase,
        Float64(objective),
        Float64(primal_infeasibility),
        Float64(dual_infeasibility),
        isnothing(complementarity) ? nothing : Float64(complementarity),
        isnothing(primal_step) ? nothing : Float64(primal_step),
        isnothing(barrier_parameter) ? nothing : Float64(barrier_parameter),
        isnothing(step_norm) ? nothing : Float64(step_norm),
        isnothing(regularization_size) ? nothing : Float64(regularization_size),
        isnothing(dual_step) ? nothing : Float64(dual_step),
        isnothing(line_search_trials) ? nothing : Int(line_search_trials),
        semantics,
        String(text),
    )
end

"""
One contiguous log-order iteration segment.

Segments split when the printed iteration number decreases. Such a boundary can
mean an appended solve, restart, or phase change; the generic core does not
assign it a solver-specific cause.
"""
struct SolverIterationSegment
    start_line::Int
    end_line::Int
    record_count::Int
    first_iteration::Int
    final_iteration::Int
    formats::Vector{Symbol}
    annotated_row_count::Int
end

"""
Descriptive facts from a parsed solver iteration trace.

Rows remain in log order. These fields summarize printed columns only; they
do not certify residual semantics, feasibility, or convergence.
"""
struct SolverIterationSummary
    record_count::Int
    formats::Vector{Symbol}
    first_iteration::Int
    final_iteration::Int
    first_primal_infeasibility::Float64
    final_primal_infeasibility::Float64
    minimum_primal_infeasibility::Float64
    first_dual_infeasibility::Float64
    final_dual_infeasibility::Float64
    minimum_dual_infeasibility::Float64
    annotated_row_count::Int
    segment_count::Int
end

"""A caller-supplied numerical point explicitly associated with one log row.

`segment` identifies the monotone iteration segment within an appended or
restarted log. `selector` records whether a binding was supplied directly, by
a legacy iteration number, or by an unambiguous `(segment, iteration)` key.
"""
struct IterationPointBinding{T<:AbstractFloat}
    record::SolverIterationRecord
    point::EvaluationPoint{T}
    segment::Int
    selector::Symbol
end

"""
An explicit solver iteration trace assembled from parsed records and optional
caller-captured points. `records` remain in source order; `segments` preserve
restart boundaries inferred from decreasing printed iteration numbers.
"""
struct SolverIterationTrace
    records::Vector{SolverIterationRecord}
    bindings::Vector{IterationPointBinding}
    segments::Vector{SolverIterationSegment}
end

"""Current-law probes aligned with explicitly captured solver iterates.

Only trace bindings that contain an `EvaluationPoint` are included. Metric-only
solver rows remain in `trace` but cannot be turned into model coordinates.
`persistence_report` compares the selected snapshots and retains the same
coverage caveat when fewer than two points are available.
"""
struct CurrentLawOperatingPointTrace
    trace::SolverIterationTrace
    bindings::Vector{IterationPointBinding}
    probes::Vector{Vector{CurrentLawOperatingPointProbe}}
    snapshot_reports::Vector{DiagnosticReport}
    persistence_report::DiagnosticReport
    metadata::Dict{String,String}
end

"""Mutable collector for solver callbacks that expose iteration records."""
mutable struct IterationTraceCapture
    records::Vector{SolverIterationRecord}
    bindings::Vector{IterationPointBinding}
    segment::Int
    last_iteration::Union{Nothing,Int}
end

IterationTraceCapture() = IterationTraceCapture(
    SolverIterationRecord[], IterationPointBinding[], 1, nothing,
)

function SolverIterationTrace(
    records::AbstractVector{SolverIterationRecord},
    bindings::AbstractVector{<:IterationPointBinding},
)
    copied_records = copy(records)
    return SolverIterationTrace(
        copied_records,
        IterationPointBinding[bindings...],
        solver_iteration_segments(copied_records),
    )
end

"""
One completed solve that retains both the callback iteration trace and the
read-only solver-result profile built from the final public MOI result.
"""
struct SolverTraceProfileRun
    trace::SolverIterationTrace
    result::SolverProfileResult
end

IterationPointBinding(
    record::SolverIterationRecord,
    point::EvaluationPoint{T},
) where {T<:AbstractFloat} = IterationPointBinding(record, point, 1, :direct)

IterationPointBinding(
    record::SolverIterationRecord,
    point::EvaluationPoint{T},
    segment::Integer,
) where {T<:AbstractFloat} = IterationPointBinding(record, point, Int(segment), :direct)

function SolverPostmortem(
    solver::AbstractString,
    termination::Symbol;
    raw_status::Union{Nothing,AbstractString} = nothing,
    iterations::Union{Nothing,Integer} = nothing,
    objective_value::Union{Nothing,Real} = nothing,
    primal_residual::Union{Nothing,Real} = nothing,
    dual_residual::Union{Nothing,Real} = nothing,
    complementarity::Union{Nothing,Real} = nothing,
    restoration_attempted::Bool = false,
    restoration_succeeded::Union{Nothing,Bool} = nothing,
    metadata::AbstractDict = Dict{String,String}(),
)
    return SolverPostmortem(
        String(solver), termination,
        isnothing(raw_status) ? nothing : String(raw_status),
        isnothing(iterations) ? nothing : Int(iterations),
        isnothing(objective_value) ? nothing : Float64(objective_value),
        isnothing(primal_residual) ? nothing : Float64(primal_residual),
        isnothing(dual_residual) ? nothing : Float64(dual_residual),
        isnothing(complementarity) ? nothing : Float64(complementarity),
        restoration_attempted,
        restoration_succeeded,
        Dict(string(key) => string(value) for (key, value) in metadata),
    )
end

"""
Repeated independent `ProfileCase` measurements with timing, allocation,
finding-stability, and finite numerical-observation summaries.
"""
struct ProfileAggregate{T<:AbstractFloat}
    case::ProfileCase{T}
    runs::Vector{ProfileResult{T}}
    warmup_performed::Bool
    stage_timing::Dict{Symbol,ProfileTimingSummary}
    stage_allocations::Dict{Symbol,ProfileAllocationSummary}
    finding_stability::Vector{ProfileFindingStability}
    expected_evidence::Vector{ProfileExpectedEvidenceSummary}
    numerical_summary::Vector{ProfileNumericalSummary}
end

"""
Transparent comparison between two repeated `ProfileCase` aggregates.

Only stages measured by both cases are compared. Finding comparisons include
the union of codes observed in either retained aggregate, with a zero rate
when a code was not observed on one side.
"""
struct ProfileComparison{T<:AbstractFloat}
    baseline::ProfileAggregate{T}
    candidate::ProfileAggregate{T}
    task_relation::Symbol
    task::Union{Nothing,String}
    stage_comparisons::Vector{ProfileStageComparison}
    finding_comparisons::Vector{ProfileFindingComparison}
    numerical_comparisons::Vector{ProfileNumericalComparison}
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
