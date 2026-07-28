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

"""Sparse-QR diagonal-pivot local rank estimate without a dense SVD."""
struct SparseQRRankEstimate{T<:AbstractFloat}
    available::Bool
    reason::Union{Nothing,String}
    point::EvaluationPoint{T}
    scaling::Symbol
    rows::Int
    columns::Int
    rank::Int
    diagonal_pivots::Vector{T}
    relative_tolerance::T
    absolute_threshold::T
    condition_proxy::Union{Nothing,T}
end

"""Iterative sparse-matvec probe for one candidate right-null direction."""
struct IterativeNullspaceEstimate{T<:AbstractFloat}
    available::Bool
    reason::Union{Nothing,String}
    point::EvaluationPoint{T}
    iterations::Int
    converged::Bool
    direction::Vector{T}
    residual_norm::Union{Nothing,T}
end

"""Iterative sparse-matvec probe for a candidate right-null subspace."""
struct IterativeNullspaceSubspaceEstimate{T<:AbstractFloat}
    available::Bool
    reason::Union{Nothing,String}
    point::EvaluationPoint{T}
    requested_dimension::Int
    iterations::Int
    converged::Bool
    directions::Matrix{T}
    residual_norms::Vector{T}
    subspace_change::Union{Nothing,T}
end

"""Sparse-matvec spectral-scale and small-direction residual probe."""
struct IterativeJacobianSpectrumEstimate{T<:AbstractFloat}
    available::Bool
    reason::Union{Nothing,String}
    point::EvaluationPoint{T}
    iterations::Int
    largest_singular_value_proxy::Union{Nothing,T}
    candidate_small_singular_values::Vector{T}
    spectral_spread_proxies::Vector{T}
    candidate_subspace_converged::Bool
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
end

"""A smooth coupled-set boundary normal supplied by the generic core or a plugin."""
struct CoupledSetTangentEvidence{T<:AbstractFloat}
    source::EntityRef
    set_kind::Symbol
    normal::Vector{T}
    description::String
end

"""Coupled-set activity evidence tied to one numerical evaluation point."""
struct CoupledSetFeasibilitySummary{T<:AbstractFloat}
    point::EvaluationPoint{T}
    activities::Vector{CoupledSetActivity{T}}
    tangents::Vector{CoupledSetTangentEvidence{T}}
    feasibility_tolerance::T
    active_tolerance::T
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
    space::Symbol
    direction::Vector{T}
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

"""A topology-nullspace basis projected through plugin-declared port coordinate maps."""
struct PortTopologyCoordinateProjection{T<:AbstractFloat}
    available::Bool
    reason::Union{Nothing,String}
    variables::Vector{MOI.VariableIndex}
    topology::PortTopologyNullspace{T}
    projected_nullspace::Matrix{T}
    consistency_residual::T
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
    conflicts::Vector{Vector{EntityRef}}
    maybe_conflicts::Vector{Vector{EntityRef}}
    error::Union{Nothing,String}
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
    constraint_keys = [(item.index, item.subindex) for item in constraints]
    length(unique(constraint_keys)) == length(constraint_keys) ||
        throw(ArgumentError("component metadata constraints must be unique"))
    scope_rank_bound = minimum(
        filter(value -> !iszero(value), [length(variables), length(constraints)]);
        init = typemax(Int),
    )
    scope_rank_bound != typemax(Int) && !isnothing(expected_rank) && expected_rank > scope_rank_bound &&
        throw(ArgumentError("expected_rank cannot exceed the declared component scope"))
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
    connection_matrix::AbstractMatrix{<:Real},
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
    description::AbstractString = "",
)
    space in (:terminal, :mode) ||
        throw(ArgumentError("port nullspace space must be :terminal or :mode"))
    isempty(direction) && throw(ArgumentError("port nullspace direction must be nonempty"))
    T = float(promote_type(map(typeof, direction)...))
    converted = T.(direction)
    iszero(norm(converted)) &&
        throw(ArgumentError("port nullspace direction must be nonzero"))
    return PortNullspaceMode{T}(
        component_type, string(component_id), string(port_id), space,
        converted, String(description),
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
    return ProfileCase{T}(
        String(name),
        String(description),
        isnothing(task) || isempty(strip(task)) ? nothing : String(task),
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

"""One complete, numerically parsed solver iteration-log row."""
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
    text::String
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

"""A caller-supplied numerical point explicitly associated with one log row."""
struct IterationPointBinding{T<:AbstractFloat}
    record::SolverIterationRecord
    point::EvaluationPoint{T}
end

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
