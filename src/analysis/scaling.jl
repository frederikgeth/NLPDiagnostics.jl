abstract type AbstractSemanticConstraintSetContract end

"""A vector residual block constrained to the origin."""
struct ZeroEqualitySetContract <: AbstractSemanticConstraintSetContract end

"""Independent scalar bounds in the model coordinates of one residual block."""
struct ScalarBoundsSetContract{T<:AbstractFloat} <:
       AbstractSemanticConstraintSetContract
    bounds::Vector{ScalarConstraintBounds{T}}
end

function ScalarBoundsSetContract(bounds)
    raw = collect(bounds)
    converted = ScalarConstraintBounds[
        item isa ScalarConstraintBounds ? item :
        item isa Tuple && length(item) == 2 ? ScalarConstraintBounds(item...) :
        throw(ArgumentError(
            "scalar bounds entries must be ScalarConstraintBounds or (lower, upper) tuples",
        )) for item in raw
    ]
    values = Real[]
    for bound in converted
        isnothing(bound.lower) || push!(values, bound.lower)
        isnothing(bound.upper) || push!(values, bound.upper)
    end
    T = isempty(values) ? Float64 : float(promote_type(map(typeof, values)...))
    return ScalarBoundsSetContract{T}([
        ScalarConstraintBounds{T}(
            isnothing(bound.lower) ? nothing : T(bound.lower),
            isnothing(bound.upper) ? nothing : T(bound.upper),
        ) for bound in converted
    ])
end

"""A Euclidean ball in the model coordinates of one residual block."""
struct EuclideanBallSetContract{T<:AbstractFloat} <:
       AbstractSemanticConstraintSetContract
    center::Vector{T}
    radius::T
end

function EuclideanBallSetContract(
    radius::Real;
    center::AbstractVector{<:Real} = Float64[],
)
    T = float(promote_type(typeof(radius), map(typeof, center)...))
    converted_radius = T(radius)
    isfinite(converted_radius) && converted_radius >= zero(T) ||
        throw(ArgumentError("ball radius must be finite and nonnegative"))
    converted_center = T.(center)
    all(isfinite, converted_center) ||
        throw(ArgumentError("ball center must be finite"))
    return EuclideanBallSetContract{T}(converted_center, converted_radius)
end

"""An explicit unavailable contract for a coupled set not yet transformable."""
struct UnsupportedSetContract <: AbstractSemanticConstraintSetContract
    reason::String
end

UnsupportedSetContract() = UnsupportedSetContract(
    "no physical set transformation contract was supplied",
)

"""
    SemanticLinearBlock(keys, positions, model_to_physical)

Declare one square semantic coordinate block. `positions` index the original
model/evaluation vector. The output coordinates are identified by `keys` and
obey `z_physical = model_to_physical * z_model[positions]`.

The inverse and orthogonality error are retained as inspectable transformation
evidence. Blocks are deliberately small: the assembled whole-model maps remain
sparse and no dense whole-model inverse is formed.
"""
struct SemanticLinearBlock{T<:AbstractFloat}
    keys::Vector{String}
    positions::Vector{Int}
    model_to_physical::Matrix{T}
    physical_to_model::Matrix{T}
    condition_number::T
    orthogonality_error::T
end

function SemanticLinearBlock(keys, positions, model_to_physical::AbstractMatrix)
    normalized_keys = string.(collect(keys))
    normalized_positions = Int.(collect(positions))
    matrix_input = Matrix(model_to_physical)
    dimension = length(normalized_keys)
    length(normalized_positions) == dimension || throw(DimensionMismatch(
        "semantic block key and position lengths differ",
    ))
    size(matrix_input) == (dimension, dimension) || throw(DimensionMismatch(
        "semantic block transform must be $dimension-by-$dimension",
    ))
    length(unique(normalized_keys)) == dimension ||
        throw(ArgumentError("semantic block keys must be unique"))
    length(unique(normalized_positions)) == dimension ||
        throw(ArgumentError("semantic block positions must be unique"))
    all(>(0), normalized_positions) ||
        throw(ArgumentError("semantic block positions must be positive"))
    T = float(eltype(matrix_input))
    matrix = Matrix{T}(matrix_input)
    all(isfinite, matrix) ||
        throw(ArgumentError("semantic block transform must be finite"))
    inverse = try
        inv(matrix)
    catch exception
        throw(ArgumentError(
            "semantic block transform must be nonsingular: $(sprint(showerror, exception))",
        ))
    end
    all(isfinite, inverse) ||
        throw(ArgumentError("semantic block inverse is non-finite"))
    identity_matrix = Matrix{T}(I, dimension, dimension)
    orthogonality_error = isempty(matrix) ? zero(T) :
        T(opnorm(transpose(matrix) * matrix - identity_matrix, Inf))
    condition_number = isempty(matrix) ? one(T) : T(cond(matrix))
    return SemanticLinearBlock{T}(
        normalized_keys,
        normalized_positions,
        matrix,
        inverse,
        condition_number,
        orthogonality_error,
    )
end

"""One semantic residual block together with its model-coordinate set."""
struct SemanticConstraintBlock{T<:AbstractFloat,S<:AbstractSemanticConstraintSetContract}
    linear::SemanticLinearBlock{T}
    set_contract::S
end

function SemanticConstraintBlock(
    keys,
    positions,
    model_to_physical::AbstractMatrix;
    set::AbstractSemanticConstraintSetContract = UnsupportedSetContract(),
)
    linear = SemanticLinearBlock(keys, positions, model_to_physical)
    dimension = length(linear.keys)
    if set isa ScalarBoundsSetContract
        length(set.bounds) == dimension || throw(DimensionMismatch(
            "scalar-bound contract dimension does not match constraint block",
        ))
    elseif set isa EuclideanBallSetContract
        !isempty(set.center) && length(set.center) != dimension &&
            throw(DimensionMismatch(
                "ball center dimension does not match constraint block",
            ))
    end
    return SemanticConstraintBlock(linear, set)
end

function _convert_semantic_linear_block(block::SemanticLinearBlock, ::Type{T}) where {T}
    return SemanticLinearBlock(
        block.keys,
        block.positions,
        Matrix{T}(block.model_to_physical),
    )
end

function _convert_set_contract(
    contract::ZeroEqualitySetContract,
    ::Type{T},
) where {T}
    return contract
end

function _convert_set_contract(
    contract::UnsupportedSetContract,
    ::Type{T},
) where {T}
    return contract
end

function _convert_set_contract(
    contract::ScalarBoundsSetContract,
    ::Type{T},
) where {T}
    return ScalarBoundsSetContract{T}([
        ScalarConstraintBounds{T}(
            isnothing(bound.lower) ? nothing : T(bound.lower),
            isnothing(bound.upper) ? nothing : T(bound.upper),
        ) for bound in contract.bounds
    ])
end

function _convert_set_contract(
    contract::EuclideanBallSetContract,
    ::Type{T},
) where {T}
    return EuclideanBallSetContract{T}(T.(contract.center), T(contract.radius))
end

"""
    SemanticBlockScalingMap(name; variable_blocks, constraint_blocks,
                            objective_scale=1)

Map a model to common physical coordinates using independently declared small
linear blocks. Block positions must partition each model vector exactly. The
assembled matrices are sparse; inverses are formed only inside the declared
blocks.
"""
struct SemanticBlockScalingMap{T<:AbstractFloat}
    name::String
    variable_blocks::Vector{SemanticLinearBlock{T}}
    constraint_blocks::Vector{SemanticConstraintBlock}
    variable_keys::Vector{String}
    constraint_keys::Vector{String}
    variable_model_to_physical::SparseMatrixCSC{T,Int}
    variable_physical_to_model::SparseMatrixCSC{T,Int}
    constraint_model_to_physical::SparseMatrixCSC{T,Int}
    constraint_physical_to_model::SparseMatrixCSC{T,Int}
    objective_scale::T
end

function _validate_block_partition(blocks, kind)
    positions = reduce(vcat, (block.positions for block in blocks); init=Int[])
    isempty(positions) && return 0
    dimension = maximum(positions)
    sort(positions) == collect(1:dimension) || throw(ArgumentError(
        "$kind block positions must partition 1:$dimension exactly",
    ))
    keys = reduce(vcat, (block.keys for block in blocks); init=String[])
    length(unique(keys)) == length(keys) || throw(ArgumentError(
        "$kind semantic keys must be globally unique",
    ))
    return dimension
end

function _assemble_block_maps(blocks, model_dimension::Integer, ::Type{T}) where {T}
    output_dimension = sum(length(block.keys) for block in blocks)
    forward_rows = Int[]
    forward_columns = Int[]
    forward_values = T[]
    inverse_rows = Int[]
    inverse_columns = Int[]
    inverse_values = T[]
    offset = 0
    for block in blocks
        dimension = length(block.keys)
        for row in 1:dimension, column in 1:dimension
            forward_value = T(block.model_to_physical[row, column])
            if !iszero(forward_value)
                push!(forward_rows, offset + row)
                push!(forward_columns, block.positions[column])
                push!(forward_values, forward_value)
            end
            inverse_value = T(block.physical_to_model[row, column])
            if !iszero(inverse_value)
                push!(inverse_rows, block.positions[row])
                push!(inverse_columns, offset + column)
                push!(inverse_values, inverse_value)
            end
        end
        offset += dimension
    end
    return (
        sparse(forward_rows, forward_columns, forward_values,
            output_dimension, model_dimension),
        sparse(inverse_rows, inverse_columns, inverse_values,
            model_dimension, output_dimension),
    )
end

function SemanticBlockScalingMap(
    name::AbstractString;
    variable_blocks,
    constraint_blocks,
    objective_scale::Real = 1.0,
)
    isempty(strip(name)) &&
        throw(ArgumentError("scaling-map name must not be empty"))
    raw_variable_blocks = collect(variable_blocks)
    raw_constraint_blocks = collect(constraint_blocks)
    all(block -> block isa SemanticLinearBlock, raw_variable_blocks) ||
        throw(ArgumentError("variable_blocks must contain SemanticLinearBlock values"))
    all(block -> block isa SemanticConstraintBlock, raw_constraint_blocks) ||
        throw(ArgumentError(
            "constraint_blocks must contain SemanticConstraintBlock values",
        ))
    scalar_types = Type[typeof(objective_scale)]
    append!(scalar_types,
        [eltype(block.model_to_physical) for block in raw_variable_blocks])
    append!(scalar_types,
        [eltype(block.linear.model_to_physical) for block in raw_constraint_blocks])
    T = float(promote_type(scalar_types...))
    oscale = T(objective_scale)
    isfinite(oscale) && oscale > zero(T) || throw(ArgumentError(
        "objective scale must be finite and positive",
    ))
    variable_blocks_t = SemanticLinearBlock{T}[
        _convert_semantic_linear_block(block, T) for block in raw_variable_blocks
    ]
    constraint_blocks_t = SemanticConstraintBlock[
        SemanticConstraintBlock(
            block.linear.keys,
            block.linear.positions,
            Matrix{T}(block.linear.model_to_physical);
            set=_convert_set_contract(block.set_contract, T),
        ) for block in raw_constraint_blocks
    ]
    variable_dimension = _validate_block_partition(
        variable_blocks_t, "variable",
    )
    constraint_dimension = _validate_block_partition(
        [block.linear for block in constraint_blocks_t], "constraint",
    )
    variable_forward, variable_inverse = _assemble_block_maps(
        variable_blocks_t, variable_dimension, T,
    )
    constraint_forward, constraint_inverse = _assemble_block_maps(
        [block.linear for block in constraint_blocks_t], constraint_dimension, T,
    )
    return SemanticBlockScalingMap{T}(
        String(name),
        variable_blocks_t,
        constraint_blocks_t,
        reduce(vcat, (block.keys for block in variable_blocks_t); init=String[]),
        reduce(vcat,
            (block.linear.keys for block in constraint_blocks_t); init=String[]),
        variable_forward,
        variable_inverse,
        constraint_forward,
        constraint_inverse,
        oscale,
    )
end

function SemanticBlockScalingMap(map::DiagonalScalingMap{T}) where {T}
    variable_blocks = [
        SemanticLinearBlock([key], [position], reshape([scale], 1, 1))
        for (position, (key, scale)) in enumerate(
            zip(map.variable_keys, map.variable_scales),
        )
    ]
    constraint_blocks = SemanticConstraintBlock[]
    for (position, (key, scale)) in enumerate(
        zip(map.constraint_keys, map.constraint_scales),
    )
        contract = isnothing(map.constraint_bounds) ? UnsupportedSetContract() :
            ScalarBoundsSetContract([map.constraint_bounds[position]])
        push!(constraint_blocks, SemanticConstraintBlock(
            [key], [position], reshape([scale], 1, 1); set=contract,
        ))
    end
    return SemanticBlockScalingMap(
        map.name;
        variable_blocks,
        constraint_blocks,
        objective_scale=map.objective_scale,
    )
end

function _semantic_model_positions_by_key(blocks, keys, kind)
    positions = Dict{String,Int}()
    for block in blocks
        for (key, position) in zip(block.keys, block.positions)
            haskey(positions, key) && throw(ArgumentError(
                "$kind semantic key $(repr(key)) occurs in multiple blocks",
            ))
            positions[key] = position
        end
    end
    return [positions[key] for key in keys]
end

function _coordinate_relation(
    reference_keys,
    reference_blocks,
    reference_forward,
    candidate_keys,
    candidate_blocks,
    candidate_inverse,
    kind,
)
    physical_alignment = _scaling_alignment(
        candidate_keys, reference_keys, "$kind physical coordinate",
    )
    reference_model_positions = _semantic_model_positions_by_key(
        reference_blocks, reference_keys, "$kind reference model coordinate",
    )
    candidate_positions = _semantic_model_positions_by_key(
        candidate_blocks, candidate_keys, "$kind candidate model coordinate",
    )
    candidate_position_by_key = Dict(
        key => position for (key, position) in
        zip(candidate_keys, candidate_positions)
    )
    candidate_model_positions = [
        candidate_position_by_key[key] for key in reference_keys
    ]
    return candidate_inverse[candidate_model_positions, :] *
        reference_forward[physical_alignment, reference_model_positions]
end

function _coordinate_relation_classification(
    relation::AbstractMatrix;
    tolerance::Real,
    max_dense_entries::Integer,
)
    dimension = size(relation, 1)
    size(relation, 2) == dimension || return Dict{String,Any}(
        "classification" => "general_linear",
        "reason" => "coordinate relation is not square",
    )
    matrix = sparse(Float64.(relation))
    all(isfinite, nonzeros(matrix)) || return Dict{String,Any}(
        "classification" => "nonfinite",
        "reason" => "coordinate relation contains non-finite entries",
    )
    scale = max(opnorm(matrix, Inf), 1.0)
    diagonal = diag(matrix)
    rows, columns, values = findnz(matrix)
    maximum_off_diagonal = maximum(
        (abs(value) for (row, column, value) in
         zip(rows, columns, values) if row != column);
        init=0.0,
    )
    diagonal_relation = maximum_off_diagonal <= tolerance * scale
    positive_diagonal = diagonal_relation && all(>(0.0), diagonal)
    sparse_identity = spdiagm(0 => ones(Float64, dimension))
    identity_error = isempty(matrix) ? 0.0 :
        opnorm(matrix - sparse_identity, Inf)
    column_norms = vec(sqrt.(sum(abs2, matrix; dims=1)))
    nonsingular_columns = all(>(tolerance), column_norms)
    normalized_gram_error = if diagonal_relation && nonsingular_columns
        0.0
    elseif nonsingular_columns
        normalized = matrix * spdiagm(0 => inv.(column_norms))
        opnorm(transpose(normalized) * normalized - sparse_identity, Inf)
    else
        Inf
    end
    orthogonal_axis_mixing =
        normalized_gram_error <= tolerance * max(dimension, 1)
    unit_magnitudes = all(
        magnitude -> isapprox(magnitude, 1.0; rtol=tolerance, atol=tolerance),
        column_norms,
    )
    classification = if identity_error <= tolerance * max(dimension, 1)
        "identity"
    elseif positive_diagonal
        "magnitude_only"
    elseif orthogonal_axis_mixing && unit_magnitudes
        "phase_like_orthogonal"
    elseif orthogonal_axis_mixing
        "magnitude_and_phase_like"
    else
        "general_linear"
    end
    dense_materialization_performed = !diagonal_relation &&
        dimension^2 <= max_dense_entries
    determinant_sign = if diagonal_relation
        isempty(diagonal) ? 1.0 : prod(sign, diagonal)
    elseif dense_materialization_performed
        sign(det(Matrix(matrix)))
    else
        nothing
    end
    return Dict{String,Any}(
        "classification" => classification,
        "dimension" => dimension,
        "storage" => "sparse",
        "stored_entry_count" => nnz(matrix),
        "dense_materialization_performed" =>
            dense_materialization_performed,
        "identity_error_infinity_norm" => identity_error,
        "maximum_off_diagonal_magnitude" => maximum_off_diagonal,
        "positive_diagonal" => positive_diagonal,
        "column_magnitudes" => column_norms,
        "normalized_gram_error_infinity_norm" => normalized_gram_error,
        "orthogonal_axis_mixing" => orthogonal_axis_mixing,
        "determinant_sign" => determinant_sign,
        "determinant_sign_available" => !isnothing(determinant_sign),
    )
end

"""
    scaling_intervention_classification(reference, candidate; ...)

Classify the declared coordinate relation between two semantic scaling maps.
The result distinguishes positive diagonal magnitude changes, norm-preserving
axis mixing, their combination, and general linear changes. `phase_like` is a
linear-algebra description: physical complex-phase meaning still requires a
plugin declaration for the affected two-coordinate blocks. Whole-model
relations remain sparse. `max_dense_entries` controls only optional
determinant-sign evidence; exceeding it does not make sparse classification
unavailable.
"""
function scaling_intervention_classification(
    reference::Union{DiagonalScalingMap,SemanticBlockScalingMap},
    candidate::Union{DiagonalScalingMap,SemanticBlockScalingMap};
    tolerance::Real=1.0e-10,
    max_dense_entries::Integer=100_000,
)
    tolerance >= 0 || throw(ArgumentError("tolerance must be nonnegative"))
    max_dense_entries >= 0 || throw(ArgumentError(
        "max_dense_entries must be nonnegative",
    ))
    reference_map = reference isa DiagonalScalingMap ?
        SemanticBlockScalingMap(reference) : reference
    candidate_map = candidate isa DiagonalScalingMap ?
        SemanticBlockScalingMap(candidate) : candidate
    variable_dimension = length(reference_map.variable_keys)
    constraint_dimension = length(reference_map.constraint_keys)
    required_entries = variable_dimension^2 + constraint_dimension^2
    variable_relation = _coordinate_relation(
        reference_map.variable_keys,
        reference_map.variable_blocks,
        reference_map.variable_model_to_physical,
        candidate_map.variable_keys,
        candidate_map.variable_blocks,
        candidate_map.variable_physical_to_model,
        "variable",
    )
    reference_constraint_blocks = [
        block.linear for block in reference_map.constraint_blocks
    ]
    candidate_constraint_blocks = [
        block.linear for block in candidate_map.constraint_blocks
    ]
    constraint_relation = _coordinate_relation(
        reference_map.constraint_keys,
        reference_constraint_blocks,
        reference_map.constraint_model_to_physical,
        candidate_map.constraint_keys,
        candidate_constraint_blocks,
        candidate_map.constraint_physical_to_model,
        "constraint",
    )
    variables = _coordinate_relation_classification(
        variable_relation; tolerance, max_dense_entries,
    )
    constraints = _coordinate_relation_classification(
        constraint_relation; tolerance, max_dense_entries,
    )
    axis_classes = Set((
        variables["classification"], constraints["classification"],
    ))
    objective_ratio = reference_map.objective_scale /
        candidate_map.objective_scale
    objective_changed = !isapprox(
        objective_ratio, 1.0; rtol=tolerance, atol=tolerance,
    )
    general = any(
        class -> class in ("general_linear", "nonfinite"), axis_classes,
    )
    phase_like = any(
        class -> class in (
            "phase_like_orthogonal", "magnitude_and_phase_like",
        ),
        axis_classes,
    )
    magnitude = objective_changed || any(
        class -> class in (
            "magnitude_only", "magnitude_and_phase_like",
        ),
        axis_classes,
    )
    classification = if general
        "general_coordinate_change"
    elseif phase_like && magnitude
        "magnitude_and_phase"
    elseif phase_like
        "phase_only"
    elseif magnitude
        "magnitude_only"
    else
        "identity"
    end
    return Dict{String,Any}(
        "report_version" => "scaling-intervention-classification-v1",
        "available" => true,
        "classification" => classification,
        "reference_map" => reference_map.name,
        "candidate_map" => candidate_map.name,
        "variables" => variables,
        "constraints" => constraints,
        "objective_scale_ratio" => objective_ratio,
        "objective_scale_changed" => objective_changed,
        "required_dense_entries" => required_entries,
        "stored_relation_entry_count" =>
            nnz(sparse(variable_relation)) + nnz(sparse(constraint_relation)),
        "dense_materialization_performed" =>
            variables["dense_materialization_performed"] ||
            constraints["dense_materialization_performed"],
        "qualification" => Dict{String,Any}(
            "phase_like_is_physical_phase_claim" => false,
            "model_axis_identity_assumption" =>
                "within each declared semantic block, input axes inherit the block key order",
            "classification_storage" =>
                "sparse whole-model coordinate relations; dense materialization is optional and used only for determinant-sign evidence",
            "does_not_establish" => [
                "model covariance",
                "physical meaning of orthogonal axis mixing",
                "solver merit",
            ],
        ),
    )
end

"""
    ScalingPointTransport

Evidence returned by [`transport_scaling_point`](@ref). `point` is expressed in
the target model coordinates. Both physical vectors are retained in source-key
order so callers can inspect the round-trip error instead of trusting an
implicit conversion.
"""
struct ScalingPointTransport{T<:AbstractFloat}
    point::EvaluationPoint{T}
    semantic_keys::Vector{String}
    source_physical_values::Vector{T}
    reconstructed_physical_values::Vector{T}
    maximum_roundtrip_error::T
    finite::Bool
end

"""Return a serialization-friendly record for a scaling-point transport."""
function scaling_point_transport_data(transport::ScalingPointTransport)
    return Dict{String,Any}(
        "report_version" => "scaling-point-transport-v1",
        "point" => _evaluation_point_data(transport.point),
        "semantic_keys" => copy(transport.semantic_keys),
        "source_physical_values" => copy(transport.source_physical_values),
        "reconstructed_physical_values" =>
            copy(transport.reconstructed_physical_values),
        "maximum_roundtrip_error" => transport.maximum_roundtrip_error,
        "finite" => transport.finite,
        "provenance_complete" => transport.point.provenance.complete,
        "qualification" => Dict{String,Any}(
            "claim" => "exact declared coordinate transport at one point",
            "does_not_establish" => [
                "mathematical equivalence of the two models",
                "feasibility in the target model",
                "target-solver convergence",
                "optimality or KKT equivalence",
            ],
        ),
    )
end

"""
    transport_scaling_point(source_point, source_map, target_variables,
                            target_map; label)

Map an explicit point to another model coordinate system through the common
physical coordinates declared by two semantic scaling maps. Semantic keys may
be ordered differently. The returned point has `TransportedPoint` provenance:
even when its source was a solver result, it was not observed from a solve of
the target model. A complete round-trip certificate is retained, but model
equivalence and target feasibility remain separate gates.
"""
function transport_scaling_point(
    source_point::EvaluationPoint,
    source_map::SemanticBlockScalingMap,
    target_variables::AbstractVector{MOI.VariableIndex},
    target_map::SemanticBlockScalingMap;
    label::AbstractString =
        "transported-$(source_map.name)-to-$(target_map.name)",
)
    size(source_map.variable_model_to_physical, 2) ==
        length(source_point.values) || throw(DimensionMismatch(
            "source variable map does not match source point",
        ))
    size(target_map.variable_physical_to_model, 1) ==
        length(target_variables) || throw(DimensionMismatch(
            "target variable map does not match target variable order",
        ))
    alignment = _scaling_alignment(
        target_map.variable_keys, source_map.variable_keys, "variable",
    )
    source_physical = source_map.variable_model_to_physical *
        source_point.values
    target_physical_order = source_physical[alignment]
    target_values = target_map.variable_physical_to_model *
        target_physical_order
    reconstructed_target_order = target_map.variable_model_to_physical *
        target_values
    target_positions = Dict(
        key => position for (position, key) in pairs(target_map.variable_keys)
    )
    reconstructed_source_order = reconstructed_target_order[
        [target_positions[key] for key in source_map.variable_keys]
    ]
    differences = abs.(source_physical .- reconstructed_source_order)
    T = float(promote_type(
        eltype(source_physical), eltype(reconstructed_source_order),
        eltype(target_values),
    ))
    maximum_error = isempty(differences) ? zero(T) : T(maximum(differences))
    finite = all(isfinite, source_physical) && all(isfinite, target_values) &&
        all(isfinite, reconstructed_source_order)
    point = EvaluationPoint(
        target_variables,
        target_values;
        label,
        provenance=EvaluationPointProvenance(
            TransportedPoint;
            source="semantic scaling-point transport",
            complete=source_point.provenance.complete,
            metadata=Dict(
                "source_point_fingerprint" =>
                    evaluation_point_fingerprint(source_point),
                "source_point_kind" => source_point.provenance.kind,
                "source_policy" => source_map.name,
                "target_policy" => target_map.name,
                "semantic_coordinate_count" => length(source_map.variable_keys),
                "maximum_roundtrip_error" => maximum_error,
                "finite" => finite,
            ),
        ),
    )
    return ScalingPointTransport{eltype(point.values)}(
        point,
        copy(source_map.variable_keys),
        eltype(point.values).(source_physical),
        eltype(point.values).(reconstructed_source_order),
        eltype(point.values)(maximum_error),
        finite,
    )
end

transport_scaling_point(
    source_point::EvaluationPoint,
    source_map::DiagonalScalingMap,
    target_variables::AbstractVector{MOI.VariableIndex},
    target_map::Union{DiagonalScalingMap,SemanticBlockScalingMap};
    kwargs...,
) = transport_scaling_point(
    source_point, SemanticBlockScalingMap(source_map), target_variables,
    target_map isa DiagonalScalingMap ? SemanticBlockScalingMap(target_map) :
        target_map;
    kwargs...,
)

transport_scaling_point(
    source_point::EvaluationPoint,
    source_map::SemanticBlockScalingMap,
    target_variables::AbstractVector{MOI.VariableIndex},
    target_map::DiagonalScalingMap;
    kwargs...,
) = transport_scaling_point(
    source_point, source_map, target_variables,
    SemanticBlockScalingMap(target_map); kwargs...,
)

function _validate_semantic_map_evaluation(evaluation, map, label)
    size(map.variable_model_to_physical, 2) == length(evaluation.point.values) ||
        throw(DimensionMismatch("$label variable map does not match evaluation"))
    size(map.constraint_model_to_physical, 2) ==
        length(evaluation.constraint_sources) || throw(DimensionMismatch(
            "$label constraint map does not match evaluation",
        ))
end

function _semantic_physical_jacobian(evaluation, map::SemanticBlockScalingMap)
    matrix = _combined_sparse_jacobian_matrix(evaluation)
    return map.constraint_model_to_physical * matrix *
        map.variable_physical_to_model
end

function _semantic_sparse_entries(matrix, row_keys, column_keys)
    entries = Dict{Tuple{String,String},Float64}()
    rows, columns, values = findnz(sparse(matrix))
    for (row, column, value) in zip(rows, columns, values)
        iszero(value) && continue
        entries[(row_keys[row], column_keys[column])] = Float64(value)
    end
    return entries
end

function _positive_diagonal(matrix; tolerance)
    rows, columns = size(matrix)
    rows == columns || return nothing
    diagonal = diag(matrix)
    all(value -> isfinite(value) && value > tolerance, diagonal) || return nothing
    off_diagonal = matrix - Diagonal(diagonal)
    norm(off_diagonal, Inf) <= tolerance * max(norm(matrix, Inf), 1) || return nothing
    return diagonal
end

function _conformal_scale(matrix; tolerance)
    dimension = size(matrix, 1)
    dimension == size(matrix, 2) || return nothing
    dimension == 0 && return one(eltype(matrix))
    gram = transpose(matrix) * matrix
    scale_squared = tr(gram) / dimension
    scale_squared >= zero(scale_squared) || return nothing
    residual = norm(gram - scale_squared * I, Inf)
    residual <= tolerance * max(norm(gram, Inf), one(scale_squared)) ||
        return nothing
    return sqrt(scale_squared)
end

function _semantic_set_descriptor(block::SemanticConstraintBlock;
                                  tolerance::Real)
    linear = block.linear
    contract = block.set_contract
    block_id = join(sort(linear.keys), "\u001f")
    if contract isa UnsupportedSetContract
        return nothing, contract.reason
    elseif contract isa ZeroEqualitySetContract
        return Dict{String,Any}(
            "block_id" => block_id,
            "kind" => "zero_equality",
            "keys" => sort(copy(linear.keys)),
        ), nothing
    elseif contract isa ScalarBoundsSetContract
        diagonal = _positive_diagonal(
            linear.model_to_physical; tolerance=tolerance,
        )
        isnothing(diagonal) && return nothing,
            "scalar bounds require a positive diagonal block transform; a rotated box is not represented as independent bounds"
        values = Dict{String,Any}()
        for (index, key) in enumerate(linear.keys)
            bound = contract.bounds[index]
            values[key] = Dict{String,Any}(
                "lower" => isnothing(bound.lower) ? nothing :
                    Float64(diagonal[index] * bound.lower),
                "upper" => isnothing(bound.upper) ? nothing :
                    Float64(diagonal[index] * bound.upper),
            )
        end
        return Dict{String,Any}(
            "block_id" => block_id,
            "kind" => "scalar_bounds",
            "keys" => sort(copy(linear.keys)),
            "bounds" => values,
        ), nothing
    elseif contract isa EuclideanBallSetContract
        scale = _conformal_scale(
            linear.model_to_physical; tolerance=tolerance,
        )
        isnothing(scale) && return nothing,
            "Euclidean-ball covariance currently requires a conformal block transform"
        center = isempty(contract.center) ? zeros(eltype(
            linear.model_to_physical), length(linear.keys)) : contract.center
        physical_center = linear.model_to_physical * center
        center_by_key = Dict(
            key => Float64(physical_center[index])
            for (index, key) in enumerate(linear.keys)
        )
        return Dict{String,Any}(
            "block_id" => block_id,
            "kind" => "euclidean_ball",
            "keys" => sort(copy(linear.keys)),
            "center" => center_by_key,
            "radius" => Float64(scale * contract.radius),
        ), nothing
    end
    return nothing, "unsupported semantic set contract $(typeof(contract))"
end

function _semantic_set_descriptors(map::SemanticBlockScalingMap;
                                   tolerance::Real)
    descriptors = Dict{String,Any}()
    reasons = String[]
    for block in map.constraint_blocks
        descriptor, reason = _semantic_set_descriptor(block; tolerance)
        if isnothing(descriptor)
            push!(reasons, reason)
        else
            descriptors[descriptor["block_id"]] = descriptor
        end
    end
    return descriptors, reasons
end

function _scaling_unavailable_reason_records(
    reasons;
    capability::Symbol,
    side::Symbol,
)
    return [
        begin
            reason = UnavailableReason(
                string(raw_reason);
                code = Symbol("$(capability)_unavailable"),
                category = :capability,
                stage = :scaling,
            )
            data = unavailable_reason_data(reason)
            data["capability"] = string(capability)
            data["side"] = string(side)
            data
        end for raw_reason in reasons
    ]
end

function _descriptor_numeric_values(descriptor)
    values = Dict{String,Float64}()
    kind = descriptor["kind"]
    if kind == "scalar_bounds"
        for key in descriptor["keys"]
            bound = descriptor["bounds"][key]
            for side in ("lower", "upper")
                value = bound[side]
                isnothing(value) || (values["$key/$side"] = value)
            end
        end
    elseif kind == "euclidean_ball"
        for key in descriptor["keys"]
            values["$key/center"] = descriptor["center"][key]
        end
        values["radius"] = descriptor["radius"]
    end
    return values
end

function _semantic_set_covariance_metric(
    reference_map::SemanticBlockScalingMap,
    candidate_map::SemanticBlockScalingMap,
    absolute_tolerance,
    relative_tolerance,
)
    tolerance = max(Float64(absolute_tolerance), sqrt(eps(Float64)))
    reference, reference_reasons = _semantic_set_descriptors(
        reference_map; tolerance,
    )
    candidate, candidate_reasons = _semantic_set_descriptors(
        candidate_map; tolerance,
    )
    if !isempty(reference_reasons) || !isempty(candidate_reasons)
        metric = _unavailable_covariance_metric(
            "one or more residual blocks lack a supported physical set transform",
        )
        metric["reference_unavailable_reasons"] = reference_reasons
        metric["candidate_unavailable_reasons"] = candidate_reasons
        metric["reference_unavailable_reason_records"] =
            _scaling_unavailable_reason_records(
                reference_reasons;
                capability = :constraint_set_transform,
                side = :reference,
            )
        metric["candidate_unavailable_reason_records"] =
            _scaling_unavailable_reason_records(
                candidate_reasons;
                capability = :constraint_set_transform,
                side = :candidate,
            )
        return metric
    end
    block_ids_agree = Set(keys(reference)) == Set(keys(candidate))
    topology_agrees = block_ids_agree
    reference_values = Float64[]
    candidate_values = Float64[]
    if block_ids_agree
        for block_id in sort!(collect(keys(reference)))
            reference_descriptor = reference[block_id]
            candidate_descriptor = candidate[block_id]
            topology_agrees &= reference_descriptor["kind"] ==
                candidate_descriptor["kind"]
            reference_numeric = _descriptor_numeric_values(reference_descriptor)
            candidate_numeric = _descriptor_numeric_values(candidate_descriptor)
            topology_agrees &= Set(keys(reference_numeric)) ==
                Set(keys(candidate_numeric))
            if Set(keys(reference_numeric)) == Set(keys(candidate_numeric))
                for key in sort!(collect(keys(reference_numeric)))
                    push!(reference_values, reference_numeric[key])
                    push!(candidate_values, candidate_numeric[key])
                end
            end
            if reference_descriptor["kind"] == "scalar_bounds" &&
               candidate_descriptor["kind"] == "scalar_bounds"
                for key in reference_descriptor["keys"]
                    for side in ("lower", "upper")
                        topology_agrees &= isnothing(
                            reference_descriptor["bounds"][key][side],
                        ) == isnothing(candidate_descriptor["bounds"][key][side])
                    end
                end
            end
        end
    end
    metric = _covariance_metric(
        reference_values,
        candidate_values,
        absolute_tolerance,
        relative_tolerance,
    )
    metric["block_count"] = length(reference)
    metric["block_topology_agrees"] = topology_agrees
    metric["passed"] = topology_agrees && metric["passed"]
    return metric
end

function _semantic_block_violations(evaluation, map; tolerance)
    length(evaluation.constraint_values) ==
        size(map.constraint_model_to_physical, 2) || return nothing,
        ["constraint-function values have the wrong dimension"]
    all(!ismissing, evaluation.constraint_values) || return nothing,
        ["constraint-function values are incomplete"]
    model_values = Float64.(evaluation.constraint_values)
    values = Dict{String,Float64}()
    reasons = String[]
    for block in map.constraint_blocks
        linear = block.linear
        physical = linear.model_to_physical * model_values[linear.positions]
        descriptor, reason = _semantic_set_descriptor(block; tolerance)
        if isnothing(descriptor)
            push!(reasons, reason)
            continue
        end
        block_id = descriptor["block_id"]
        if descriptor["kind"] == "zero_equality"
            values[block_id] = Float64(norm(physical, Inf))
        elseif descriptor["kind"] == "scalar_bounds"
            for (index, key) in enumerate(linear.keys)
                bound = descriptor["bounds"][key]
                lower_violation = isnothing(bound["lower"]) ? 0.0 :
                    max(bound["lower"] - physical[index], 0.0)
                upper_violation = isnothing(bound["upper"]) ? 0.0 :
                    max(physical[index] - bound["upper"], 0.0)
                values["$block_id/$key"] = max(lower_violation, upper_violation)
            end
        elseif descriptor["kind"] == "euclidean_ball"
            center = [descriptor["center"][key] for key in linear.keys]
            values[block_id] = max(
                Float64(norm(physical - center) - descriptor["radius"]), 0.0,
            )
        end
    end
    return values, reasons
end

"""
    physical_feasibility_report(evaluation, map;
        absolute_tolerances=Dict(), default_absolute_tolerance=nothing)

Evaluate set violations after mapping every supported residual block and its
set to physical coordinates. Tolerances may be keyed by the exact residual key
reported in `residuals` or by its semantic block ID. A default is optional and
explicit because a single number generally has no coherent meaning across
voltage, current, power, and squared-quantity residuals.

This is an endpoint acceptance contract, not a translation of an NLP solver's
internal stopping test. In particular, it makes no stationarity,
complementarity, or solver-scaling claim.
"""
function physical_feasibility_report(
    evaluation::NumericalEvaluation,
    map::SemanticBlockScalingMap;
    absolute_tolerances::AbstractDict = Dict{String,Float64}(),
    default_absolute_tolerance::Union{Nothing,Real} = nothing,
    set_transform_tolerance::Real = sqrt(eps(Float64)),
)
    set_transform_tolerance >= 0 || throw(ArgumentError(
        "set_transform_tolerance must be nonnegative",
    ))
    normalized_tolerances = Dict{String,Float64}()
    for (key, value) in absolute_tolerances
        value isa Real && isfinite(value) && value >= 0 || throw(ArgumentError(
            "physical feasibility tolerance for $(repr(key)) must be finite and nonnegative",
        ))
        normalized_tolerances[string(key)] = Float64(value)
    end
    if !isnothing(default_absolute_tolerance)
        isfinite(default_absolute_tolerance) &&
            default_absolute_tolerance >= 0 || throw(ArgumentError(
                "default_absolute_tolerance must be finite and nonnegative",
            ))
    end
    _validate_semantic_map_evaluation(evaluation, map, "physical feasibility")
    violations, reasons = _semantic_block_violations(
        evaluation, map; tolerance=set_transform_tolerance,
    )
    if isnothing(violations) || !isempty(reasons)
        return Dict{String,Any}(
            "report_version" => "physical-feasibility-v1",
            "available" => false,
            "acceptance_passed" => nothing,
            "reasons" => reasons,
            "residuals" => Dict{String,Any}(),
            "qualification" => Dict{String,Any}(
                "claim" => "unavailable physical endpoint feasibility",
                "does_not_establish" => [
                    "solver stopping-test equivalence",
                    "stationarity",
                    "complementarity",
                    "optimality",
                ],
            ),
        )
    end
    block_ids = sort!([
        join(sort(block.linear.keys), "\u001f") for
        block in map.constraint_blocks
    ]; by=length, rev=true)
    records = Dict{String,Any}()
    configured_count = 0
    passed_count = 0
    finite = true
    for key in sort!(collect(keys(violations)))
        violation = Float64(violations[key])
        finite &= isfinite(violation)
        block_id = something(findfirst(
            candidate -> key == candidate || startswith(key, "$candidate/"),
            block_ids,
        ), 0)
        resolved_block_id = block_id == 0 ? "" : block_ids[block_id]
        tolerance, tolerance_source = if haskey(normalized_tolerances, key)
            normalized_tolerances[key], "residual"
        elseif haskey(normalized_tolerances, resolved_block_id)
            normalized_tolerances[resolved_block_id], "block"
        elseif !isnothing(default_absolute_tolerance)
            Float64(default_absolute_tolerance), "default"
        else
            nothing, "unconfigured"
        end
        configured = !isnothing(tolerance)
        passed = configured && isfinite(violation) ? violation <= tolerance :
            nothing
        configured_count += configured
        passed_count += passed === true
        records[key] = Dict{String,Any}(
            "block_id" => resolved_block_id,
            "violation" => violation,
            "absolute_tolerance" => tolerance,
            "tolerance_source" => tolerance_source,
            "configured" => configured,
            "passed" => passed,
        )
    end
    complete_coverage = configured_count == length(records)
    provenance_complete = evaluation.point.provenance.complete
    acceptance = complete_coverage && finite && provenance_complete &&
        passed_count == length(records)
    return Dict{String,Any}(
        "report_version" => "physical-feasibility-v1",
        "available" => true,
        "policy" => map.name,
        "point_label" => evaluation.point.label,
        "point_fingerprint" => evaluation_point_fingerprint(evaluation.point),
        "point_provenance_complete" => provenance_complete,
        "finite" => finite,
        "residual_count" => length(records),
        "configured_residual_count" => configured_count,
        "passed_residual_count" => passed_count,
        "tolerance_coverage_complete" => complete_coverage,
        "default_absolute_tolerance" => isnothing(
            default_absolute_tolerance,
        ) ? nothing : Float64(default_absolute_tolerance),
        "uniform_default_tolerance_assumption" =>
            !isnothing(default_absolute_tolerance),
        "acceptance_passed" => acceptance,
        "residuals" => records,
        "qualification" => Dict{String,Any}(
            "claim" => "physical-coordinate endpoint set feasibility under caller-declared per-residual tolerances",
            "does_not_establish" => [
                "solver stopping-test equivalence",
                "stationarity",
                "complementarity",
                "optimality",
                "comparability of differently dimensioned violations",
            ],
        ),
    )
end

physical_feasibility_report(
    evaluation::NumericalEvaluation,
    map::DiagonalScalingMap;
    kwargs...,
) = physical_feasibility_report(
    evaluation, SemanticBlockScalingMap(map); kwargs...,
)

function _physical_stationarity_unavailable(reason, map, evaluation)
    return Dict{String,Any}(
        "report_version" => "physical-stationarity-v1",
        "available" => false,
        "acceptance_passed" => nothing,
        "reason" => reason,
        "policy" => map.name,
        "point_label" => evaluation.point.label,
        "stationarity" => Dict{String,Any}(),
        "qualification" => Dict{String,Any}(
            "claim" => "unavailable physical stationarity endpoint test",
            "does_not_establish" => [
                "multiplier uniqueness",
                "dual feasibility",
                "complementarity",
                "optimality",
            ],
        ),
    )
end

"""
    physical_stationarity_report(evaluation, map, constraint_multipliers;
        objective_weight=1, absolute_tolerances=Dict(),
        default_absolute_tolerance=nothing)

Transform a caller-supplied, row-aligned model-coordinate multiplier vector and
the resulting Lagrangian stationarity residual to physical coordinates. Each
physical variable key has its own tolerance. A global default is allowed only
as an explicit caller assumption because stationarity components generally
carry different compound units.

The multiplier vector must use the convention
`objective_weight * f_model + dot(constraint_multipliers, g_model)`. This
routine checks the supplied representative; it neither reads solver duals nor
proves that the representative is unique or sign-feasible.
"""
function physical_stationarity_report(
    evaluation::NumericalEvaluation,
    map::SemanticBlockScalingMap,
    constraint_multipliers::AbstractVector{<:Real};
    objective_weight::Real = 1.0,
    absolute_tolerances::AbstractDict = Dict{String,Float64}(),
    default_absolute_tolerance::Union{Nothing,Real} = nothing,
)
    _validate_semantic_map_evaluation(evaluation, map, "physical stationarity")
    length(constraint_multipliers) == length(evaluation.constraint_sources) ||
        throw(DimensionMismatch(
            "constraint multiplier vector does not match evaluated rows",
        ))
    isfinite(objective_weight) || throw(ArgumentError(
        "objective_weight must be finite",
    ))
    normalized_tolerances = Dict{String,Float64}()
    for (key, value) in absolute_tolerances
        value isa Real && isfinite(value) && value >= 0 || throw(ArgumentError(
            "physical stationarity tolerance for $(repr(key)) must be finite and nonnegative",
        ))
        normalized_tolerances[string(key)] = Float64(value)
    end
    if !isnothing(default_absolute_tolerance)
        isfinite(default_absolute_tolerance) &&
            default_absolute_tolerance >= 0 || throw(ArgumentError(
                "default_absolute_tolerance must be finite and nonnegative",
            ))
    end
    gradient_required = !iszero(objective_weight)
    gradient_available =
        length(evaluation.objective_gradient) == length(evaluation.point.values) &&
        all(!ismissing, evaluation.objective_gradient)
    gradient_required && !gradient_available &&
        return _physical_stationarity_unavailable(
            "the objective gradient is unavailable or incomplete for a nonzero objective weight",
            map,
            evaluation,
        )
    all(method -> !(method in _JACOBIAN_INCOMPLETE_METHODS),
        evaluation.jacobian_row_methods) ||
        return _physical_stationarity_unavailable(
            "one or more Jacobian rows are unavailable or partial", map,
            evaluation,
        )
    multipliers = Float64.(constraint_multipliers)
    all(isfinite, multipliers) || return _physical_stationarity_unavailable(
        "the supplied multiplier vector contains non-finite values", map,
        evaluation,
    )
    model_gradient = gradient_required ?
        Float64.(evaluation.objective_gradient) :
        zeros(Float64, length(evaluation.point.values))
    gradient_required && !all(isfinite, model_gradient) &&
        return _physical_stationarity_unavailable(
            "the objective gradient contains non-finite values", map,
            evaluation,
        )
    physical_gradient = transpose(map.variable_physical_to_model) *
        (map.objective_scale .* model_gradient)
    physical_multipliers = transpose(map.constraint_physical_to_model) *
        multipliers
    physical_jacobian = _semantic_physical_jacobian(evaluation, map)
    physical_objective_weight = Float64(objective_weight / map.objective_scale)
    constraint_stationarity = transpose(physical_jacobian) * physical_multipliers
    stationarity = physical_objective_weight .* physical_gradient +
        constraint_stationarity
    gradient_squared_norm = sum(abs2, physical_gradient)
    objective_weight_fit_available = isfinite(gradient_squared_norm) &&
        gradient_squared_norm > eps(Float64)
    fitted_objective_weight = objective_weight_fit_available ?
        -dot(physical_gradient, constraint_stationarity) /
            gradient_squared_norm : nothing
    fitted_stationarity = objective_weight_fit_available ?
        fitted_objective_weight .* physical_gradient .+
            constraint_stationarity : Float64[]
    fitted_maximum_residual = objective_weight_fit_available &&
        all(isfinite, fitted_stationarity) ?
        maximum(abs, fitted_stationarity; init=0.0) : nothing
    configured_maximum_residual = all(isfinite, stationarity) ?
        maximum(abs, stationarity; init=0.0) : nothing
    normalization_scale = max(
        maximum(abs, constraint_stationarity; init=0.0),
        abs(physical_objective_weight) *
            maximum(abs, physical_gradient; init=0.0),
        eps(Float64),
    )
    fitted_weight_differs = objective_weight_fit_available &&
        isfinite(fitted_objective_weight) &&
        !isapprox(
            fitted_objective_weight,
            physical_objective_weight;
            atol=1.0e-8,
            rtol=1.0e-6,
        )
    global_normalization_mismatch = fitted_weight_differs &&
        fitted_maximum_residual isa Real &&
        fitted_maximum_residual <= 1.0e-6 * normalization_scale
    gradient_component_scale = maximum(abs, physical_gradient; init=0.0)
    coordinate_fit_threshold = sqrt(eps(Float64)) *
        max(gradient_component_scale, eps(Float64))
    coordinate_weight_fits = Dict{String,Any}()
    inconsistent_coordinate_count = 0
    for (position, key) in pairs(map.variable_keys)
        gradient_component = Float64(physical_gradient[position])
        abs(gradient_component) > coordinate_fit_threshold || continue
        constraint_component = Float64(constraint_stationarity[position])
        fitted_weight = -constraint_component / gradient_component
        configured_residual = Float64(stationarity[position])
        component_scale = max(
            abs(constraint_component),
            abs(physical_objective_weight * gradient_component),
            eps(Float64),
        )
        weight_differs = isfinite(fitted_weight) && !isapprox(
            fitted_weight,
            physical_objective_weight;
            atol=1.0e-8,
            rtol=1.0e-6,
        )
        materially_inconsistent = weight_differs &&
            abs(configured_residual) > 1.0e-6 * component_scale
        inconsistent_coordinate_count += materially_inconsistent
        coordinate_weight_fits[key] = Dict{String,Any}(
            "fitted_physical_weight" => fitted_weight,
            "configured_stationarity_residual" => configured_residual,
            "component_scale" => component_scale,
            "materially_inconsistent" => materially_inconsistent,
        )
    end
    potential_normalization_mismatch = global_normalization_mismatch ||
        inconsistent_coordinate_count > 0
    records = Dict{String,Any}()
    configured_count = 0
    passed_count = 0
    finite = all(isfinite, stationarity) && all(isfinite, physical_multipliers)
    for (position, key) in pairs(map.variable_keys)
        value = Float64(stationarity[position])
        tolerance, source = if haskey(normalized_tolerances, key)
            normalized_tolerances[key], "variable"
        elseif !isnothing(default_absolute_tolerance)
            Float64(default_absolute_tolerance), "default"
        else
            nothing, "unconfigured"
        end
        configured = !isnothing(tolerance)
        passed = configured && isfinite(value) ? abs(value) <= tolerance :
            nothing
        configured_count += configured
        passed_count += passed === true
        records[key] = Dict{String,Any}(
            "value" => value,
            "absolute_residual" => abs(value),
            "absolute_tolerance" => tolerance,
            "tolerance_source" => source,
            "configured" => configured,
            "passed" => passed,
        )
    end
    complete_coverage = configured_count == length(records)
    provenance_complete = evaluation.point.provenance.complete
    acceptance = complete_coverage && finite && provenance_complete &&
        passed_count == length(records)
    return Dict{String,Any}(
        "report_version" => "physical-stationarity-v1",
        "available" => true,
        "acceptance_passed" => acceptance,
        "policy" => map.name,
        "point_label" => evaluation.point.label,
        "point_fingerprint" => evaluation_point_fingerprint(evaluation.point),
        "point_provenance_complete" => provenance_complete,
        "finite" => finite,
        "objective_weight_model" => Float64(objective_weight),
        "objective_weight_physical" => physical_objective_weight,
        "objective_weight_consistency" => Dict{String,Any}(
            "available" => objective_weight_fit_available,
            "configured_physical_weight" => physical_objective_weight,
            "least_squares_fitted_physical_weight" => fitted_objective_weight,
            "configured_maximum_stationarity_residual" =>
                configured_maximum_residual,
            "fitted_maximum_stationarity_residual" =>
                fitted_maximum_residual,
            "normalization_scale" => normalization_scale,
            "potential_multiplier_normalization_mismatch" =>
                potential_normalization_mismatch,
            "global_fit_indicates_mismatch" =>
                global_normalization_mismatch,
            "coordinate_fit_threshold" => coordinate_fit_threshold,
            "coordinate_fit_count" => length(coordinate_weight_fits),
            "materially_inconsistent_coordinate_count" =>
                inconsistent_coordinate_count,
            "coordinate_weight_fits" => coordinate_weight_fits,
            "interpretation" =>
                "global or coordinate-local fitted objective weights that materially differ from the configured weight are evidence of an inconsistent multiplier representative; this screen does not distinguish normalization from dual nonuniqueness or redundant fixed-coordinate equations and never applies an automatic correction",
        ),
        "objective_gradient_required" => gradient_required,
        "objective_gradient_available" => gradient_available,
        "constraint_multiplier_semantics" =>
            "caller-supplied model-coordinate row multipliers",
        "physical_constraint_multipliers" =>
            Float64.(physical_multipliers),
        "stationarity_coordinate_count" => length(records),
        "configured_coordinate_count" => configured_count,
        "passed_coordinate_count" => passed_count,
        "tolerance_coverage_complete" => complete_coverage,
        "default_absolute_tolerance" => isnothing(
            default_absolute_tolerance,
        ) ? nothing : Float64(default_absolute_tolerance),
        "uniform_default_tolerance_assumption" =>
            !isnothing(default_absolute_tolerance),
        "stationarity" => records,
        "qualification" => Dict{String,Any}(
            "claim" => "physical-coordinate stationarity of one supplied multiplier representative",
            "does_not_establish" => [
                "multiplier uniqueness",
                "dual feasibility",
                "complementarity",
                "local or global optimality",
            ],
        ),
    )
end

physical_stationarity_report(
    evaluation::NumericalEvaluation,
    map::DiagonalScalingMap,
    constraint_multipliers::AbstractVector{<:Real};
    kwargs...,
) = physical_stationarity_report(
    evaluation, SemanticBlockScalingMap(map), constraint_multipliers;
    kwargs...,
)

function _normalized_physical_tolerances(values, label)
    normalized = Dict{String,Float64}()
    for (key, value) in values
        value isa Real && isfinite(value) && value >= 0 || throw(ArgumentError(
            "$label tolerance for $(repr(key)) must be finite and nonnegative",
        ))
        normalized[string(key)] = Float64(value)
    end
    return normalized
end

function _physical_scalar_side_coordinates(
    map::SemanticBlockScalingMap;
    tolerance::Real,
)
    coordinates = Dict{Int,Tuple{String,Float64}}()
    reasons = String[]
    for block in map.constraint_blocks
        contract = block.set_contract
        contract isa ZeroEqualitySetContract && continue
        if !(contract isa ScalarBoundsSetContract)
            push!(reasons,
                "constraint block $(join(block.linear.keys, ", ")) is not a scalar-bound block")
            continue
        end
        diagonal = _positive_diagonal(
            block.linear.model_to_physical; tolerance,
        )
        if isnothing(diagonal)
            push!(reasons,
                "constraint block $(join(block.linear.keys, ", ")) rotates or reverses scalar sides")
            continue
        end
        for (local_index, position) in enumerate(block.linear.positions)
            coordinates[position] = (
                block.linear.keys[local_index], Float64(diagonal[local_index]),
            )
        end
    end
    return coordinates, reasons
end

"""
    physical_complementarity_report(snapshot, map; ...)

Transform scalar-side slacks and multipliers to declared physical residual
coordinates and test dual feasibility and complementarity using independently
declared tolerances. The complementarity product is invariant under a positive
diagonal residual scaling; the two factors and their tolerances are not.

Rotated scalar boxes and general coupled cones remain explicitly unavailable:
their solver dual must be transformed with the full dual-cone contract rather
than split into invented componentwise sides.
"""
function physical_complementarity_report(
    snapshot::SolverDualSnapshot,
    map::SemanticBlockScalingMap;
    dual_absolute_tolerances::AbstractDict = Dict{String,Float64}(),
    default_dual_absolute_tolerance::Union{Nothing,Real} = nothing,
    complementarity_absolute_tolerances::AbstractDict =
        Dict{String,Float64}(),
    default_complementarity_absolute_tolerance::Union{Nothing,Real} = nothing,
    set_transform_tolerance::Real = sqrt(eps(Float64)),
)
    set_transform_tolerance >= 0 || throw(ArgumentError(
        "set_transform_tolerance must be nonnegative",
    ))
    dual_tolerances = _normalized_physical_tolerances(
        dual_absolute_tolerances, "physical dual",
    )
    complementarity_tolerances = _normalized_physical_tolerances(
        complementarity_absolute_tolerances, "physical complementarity",
    )
    for (value, label) in (
        (default_dual_absolute_tolerance, "default physical dual"),
        (default_complementarity_absolute_tolerance,
            "default physical complementarity"),
    )
        isnothing(value) && continue
        isfinite(value) && value >= 0 || throw(ArgumentError(
            "$label tolerance must be finite and nonnegative",
        ))
    end
    unavailable = function (reason)
        return Dict{String,Any}(
            "report_version" => "physical-complementarity-v1",
            "available" => false,
            "applicable" => true,
            "acceptance_passed" => nothing,
            "reason" => reason,
            "sides" => Dict{String,Any}(),
        )
    end
    snapshot.available || return unavailable(
        "solver dual snapshot is unavailable: $(snapshot.reason)",
    )
    snapshot.side_decomposition_complete || return unavailable(
        "one or more solver dual rows lack scalar-side semantics",
    )
    size(map.constraint_model_to_physical, 2) ==
        length(snapshot.row_multipliers) || throw(DimensionMismatch(
            "physical complementarity map does not match solver dual rows",
        ))
    coordinates, reasons = _physical_scalar_side_coordinates(
        map; tolerance=set_transform_tolerance,
    )
    inequality_sides = filter(
        side -> side.side != :equality, snapshot.sides,
    )
    isempty(inequality_sides) && return Dict{String,Any}(
        "report_version" => "physical-complementarity-v1",
        "available" => true,
        "applicable" => false,
        "acceptance_passed" => true,
        "reason" => "the solver snapshot contains equality rows only",
        "side_count" => 0,
        "sides" => Dict{String,Any}(),
    )
    missing_rows = sort!(unique([
        side.row for side in inequality_sides if !haskey(coordinates, side.row)
    ]))
    if !isempty(missing_rows)
        return unavailable(
            "physical scalar-side transforms are unavailable for rows $(join(missing_rows, ", "))" *
            (isempty(reasons) ? "" : ": $(join(unique(reasons), "; "))"),
        )
    end
    records = Dict{String,Any}()
    configured_dual = 0
    configured_complementarity = 0
    passed_count = 0
    finite = true
    for side in inequality_sides
        key, scale = coordinates[side.row]
        side_key = "$key/$(side.side)"
        physical_multiplier = Float64(side.multiplier / scale)
        physical_slack = isnothing(side.slack) ? nothing :
            Float64(scale * side.slack)
        dual_violation = max(-physical_multiplier, 0.0)
        complementarity = isnothing(physical_slack) ? nothing :
            abs(physical_multiplier * physical_slack)
        dual_tolerance, dual_source = if haskey(dual_tolerances, side_key)
            dual_tolerances[side_key], "side"
        elseif haskey(dual_tolerances, key)
            dual_tolerances[key], "residual"
        elseif !isnothing(default_dual_absolute_tolerance)
            Float64(default_dual_absolute_tolerance), "default"
        else
            nothing, "unconfigured"
        end
        complementarity_tolerance, complementarity_source = if haskey(
            complementarity_tolerances, side_key,
        )
            complementarity_tolerances[side_key], "side"
        elseif haskey(complementarity_tolerances, key)
            complementarity_tolerances[key], "residual"
        elseif !isnothing(default_complementarity_absolute_tolerance)
            Float64(default_complementarity_absolute_tolerance), "default"
        else
            nothing, "unconfigured"
        end
        dual_configured = !isnothing(dual_tolerance)
        complementarity_configured = !isnothing(complementarity_tolerance)
        side_finite = isfinite(physical_multiplier) &&
            !isnothing(physical_slack) && isfinite(physical_slack) &&
            !isnothing(complementarity) && isfinite(complementarity)
        side_passed = dual_configured && complementarity_configured &&
            side_finite && dual_violation <= dual_tolerance &&
            complementarity <= complementarity_tolerance
        configured_dual += dual_configured
        configured_complementarity += complementarity_configured
        passed_count += side_passed
        finite &= side_finite
        records[side_key] = Dict{String,Any}(
            "row" => side.row,
            "side" => string(side.side),
            "physical_multiplier" => physical_multiplier,
            "physical_slack" => physical_slack,
            "complementarity_residual" => complementarity,
            "dual_violation" => dual_violation,
            "dual_absolute_tolerance" => dual_tolerance,
            "dual_tolerance_source" => dual_source,
            "complementarity_absolute_tolerance" =>
                complementarity_tolerance,
            "complementarity_tolerance_source" => complementarity_source,
            "passed" => side_passed,
            "model_multiplier" => Float64(side.multiplier),
            "model_slack" => side.slack,
            "residual_scale" => scale,
            "provenance" => string(side.provenance),
        )
    end
    count = length(records)
    coverage = configured_dual == count &&
        configured_complementarity == count
    acceptance = coverage && finite && passed_count == count
    return Dict{String,Any}(
        "report_version" => "physical-complementarity-v1",
        "available" => true,
        "applicable" => true,
        "acceptance_passed" => acceptance,
        "policy" => map.name,
        "side_count" => count,
        "configured_dual_side_count" => configured_dual,
        "configured_complementarity_side_count" =>
            configured_complementarity,
        "passed_side_count" => passed_count,
        "tolerance_coverage_complete" => coverage,
        "finite" => finite,
        "sides" => records,
        "qualification" => Dict{String,Any}(
            "claim" => "physical scalar-side dual feasibility and complementarity at one solver endpoint",
            "scaling_invariant" =>
                "multiplier-times-slack product under positive diagonal residual scaling",
            "does_not_establish" => [
                "multiplier uniqueness",
                "constraint qualification",
                "solver stopping-test equivalence",
                "optimality",
            ],
        ),
    )
end

physical_complementarity_report(
    snapshot::SolverDualSnapshot,
    map::DiagonalScalingMap;
    kwargs...,
) = physical_complementarity_report(
    snapshot, SemanticBlockScalingMap(map); kwargs...,
)

"""
    physical_kkt_acceptance_report(evaluation, map, snapshot; ...)

Evaluate physical primal feasibility, solver-reported stationarity, dual
feasibility, and scalar-side complementarity at one verified solver endpoint.
This overload closes the inequality gate left intentionally unavailable by the
caller-supplied multiplier API.
"""
function physical_kkt_acceptance_report(
    evaluation::NumericalEvaluation,
    map::SemanticBlockScalingMap,
    snapshot::SolverDualSnapshot;
    feasibility_absolute_tolerances::AbstractDict = Dict{String,Float64}(),
    feasibility_default_absolute_tolerance::Union{Nothing,Real} = nothing,
    stationarity_absolute_tolerances::AbstractDict = Dict{String,Float64}(),
    stationarity_default_absolute_tolerance::Union{Nothing,Real} = nothing,
    dual_absolute_tolerances::AbstractDict = Dict{String,Float64}(),
    dual_default_absolute_tolerance::Union{Nothing,Real} = nothing,
    complementarity_absolute_tolerances::AbstractDict =
        Dict{String,Float64}(),
    complementarity_default_absolute_tolerance::Union{Nothing,Real} = nothing,
    set_transform_tolerance::Real = sqrt(eps(Float64)),
)
    snapshot.available || return Dict{String,Any}(
        "report_version" => "physical-kkt-acceptance-v2",
        "acceptance_passed" => nothing,
        "reason" => "solver dual snapshot is unavailable: $(snapshot.reason)",
        "solver_duals" => solver_dual_snapshot_data(snapshot),
    )
    length(snapshot.row_multipliers) == length(evaluation.constraint_sources) ||
        throw(DimensionMismatch(
            "solver dual snapshot does not match evaluated constraint rows",
        ))
    primal = physical_feasibility_report(
        evaluation, map;
        absolute_tolerances=feasibility_absolute_tolerances,
        default_absolute_tolerance=feasibility_default_absolute_tolerance,
        set_transform_tolerance,
    )
    stationarity = physical_stationarity_report(
        evaluation, map, snapshot.row_multipliers;
        objective_weight=snapshot.objective_weight,
        absolute_tolerances=stationarity_absolute_tolerances,
        default_absolute_tolerance=stationarity_default_absolute_tolerance,
    )
    complementarity = physical_complementarity_report(
        snapshot, map;
        dual_absolute_tolerances,
        default_dual_absolute_tolerance=dual_default_absolute_tolerance,
        complementarity_absolute_tolerances,
        default_complementarity_absolute_tolerance=
            complementarity_default_absolute_tolerance,
        set_transform_tolerance,
    )
    acceptance = if primal["available"] && stationarity["available"] &&
                    complementarity["available"]
        primal["acceptance_passed"] &&
            stationarity["acceptance_passed"] &&
            complementarity["acceptance_passed"]
    else
        nothing
    end
    return Dict{String,Any}(
        "report_version" => "physical-kkt-acceptance-v2",
        "acceptance_passed" => acceptance,
        "primal_feasibility" => primal,
        "stationarity" => stationarity,
        "complementarity" => complementarity,
        "solver_duals" => solver_dual_snapshot_data(snapshot),
        "qualification" => Dict{String,Any}(
            "claim" => "physical endpoint first-order KKT residual acceptance using public solver duals",
            "solver_stopping_test_equivalence" => false,
            "does_not_establish" => [
                "multiplier uniqueness",
                "constraint qualification",
                "second-order sufficiency",
                "global optimality",
            ],
        ),
    )
end

physical_kkt_acceptance_report(
    evaluation::NumericalEvaluation,
    map::DiagonalScalingMap,
    snapshot::SolverDualSnapshot;
    kwargs...,
) = physical_kkt_acceptance_report(
    evaluation, SemanticBlockScalingMap(map), snapshot; kwargs...,
)

"""
    physical_kkt_acceptance_report(evaluation, map,
                                   constraint_multipliers; kwargs...)

Combine physical primal-feasibility and stationarity endpoint contracts. Full
acceptance is returned only when all constraint blocks are equalities, making
inequality complementarity inapplicable. Models with inequalities receive an
explicitly unavailable complementarity gate until side-specific duals and
slacks are supplied.
"""
function physical_kkt_acceptance_report(
    evaluation::NumericalEvaluation,
    map::SemanticBlockScalingMap,
    constraint_multipliers::AbstractVector{<:Real};
    objective_weight::Real = 1.0,
    feasibility_absolute_tolerances::AbstractDict =
        Dict{String,Float64}(),
    feasibility_default_absolute_tolerance::Union{Nothing,Real} = nothing,
    stationarity_absolute_tolerances::AbstractDict =
        Dict{String,Float64}(),
    stationarity_default_absolute_tolerance::Union{Nothing,Real} = nothing,
    set_transform_tolerance::Real = sqrt(eps(Float64)),
)
    primal = physical_feasibility_report(
        evaluation,
        map;
        absolute_tolerances=feasibility_absolute_tolerances,
        default_absolute_tolerance=feasibility_default_absolute_tolerance,
        set_transform_tolerance,
    )
    stationarity = physical_stationarity_report(
        evaluation,
        map,
        constraint_multipliers;
        objective_weight,
        absolute_tolerances=stationarity_absolute_tolerances,
        default_absolute_tolerance=stationarity_default_absolute_tolerance,
    )
    equality_only = all(
        block -> block.set_contract isa ZeroEqualitySetContract,
        map.constraint_blocks,
    )
    complementarity = equality_only ? Dict{String,Any}(
        "available" => true,
        "applicable" => false,
        "passed" => true,
        "reason" => "all declared constraint blocks are equalities",
    ) : Dict{String,Any}(
        "available" => false,
        "applicable" => true,
        "passed" => nothing,
        "reason" =>
            "side-specific inequality multipliers and physical slacks were not supplied",
    )
    acceptance = if primal["available"] && stationarity["available"] &&
                    complementarity["available"]
        primal["acceptance_passed"] &&
            stationarity["acceptance_passed"] &&
            complementarity["passed"]
    else
        nothing
    end
    return Dict{String,Any}(
        "report_version" => "physical-kkt-acceptance-v1",
        "acceptance_passed" => acceptance,
        "primal_feasibility" => primal,
        "stationarity" => stationarity,
        "complementarity" => complementarity,
        "qualification" => Dict{String,Any}(
            "claim" => equality_only ?
                "physical endpoint KKT residual acceptance for an equality-only model" :
                "partial physical endpoint KKT evidence with unavailable inequality complementarity",
            "solver_stopping_test_equivalence" => false,
            "does_not_establish" => [
                "equivalence to a solver-internal scaled stopping test",
                "multiplier uniqueness",
                "constraint qualification",
                "second-order sufficiency",
                "global optimality",
            ],
        ),
    )
end

physical_kkt_acceptance_report(
    evaluation::NumericalEvaluation,
    map::DiagonalScalingMap,
    constraint_multipliers::AbstractVector{<:Real};
    kwargs...,
) = physical_kkt_acceptance_report(
    evaluation, SemanticBlockScalingMap(map), constraint_multipliers;
    kwargs...,
)

function _semantic_residual_covariance_metric(
    reference,
    reference_map,
    candidate,
    candidate_map,
    absolute_tolerance,
    relative_tolerance,
)
    tolerance = max(Float64(absolute_tolerance), sqrt(eps(Float64)))
    reference_values, reference_reasons = _semantic_block_violations(
        reference, reference_map; tolerance,
    )
    candidate_values, candidate_reasons = _semantic_block_violations(
        candidate, candidate_map; tolerance,
    )
    if isnothing(reference_values) || isnothing(candidate_values) ||
       !isempty(reference_reasons) || !isempty(candidate_reasons)
        metric = _unavailable_covariance_metric(
            "one or more residual blocks lack supported finite violation semantics",
        )
        metric["reference_unavailable_reasons"] = reference_reasons
        metric["candidate_unavailable_reasons"] = candidate_reasons
        metric["reference_unavailable_reason_records"] =
            _scaling_unavailable_reason_records(
                reference_reasons;
                capability = :constraint_residual_semantics,
                side = :reference,
            )
        metric["candidate_unavailable_reason_records"] =
            _scaling_unavailable_reason_records(
                candidate_reasons;
                capability = :constraint_residual_semantics,
                side = :candidate,
            )
        return metric
    end
    keys_agree = Set(keys(reference_values)) == Set(keys(candidate_values))
    common_keys = sort!(collect(intersect(
        Set(keys(reference_values)), Set(keys(candidate_values)),
    )))
    metric = _covariance_metric(
        [reference_values[key] for key in common_keys],
        [candidate_values[key] for key in common_keys],
        absolute_tolerance,
        relative_tolerance,
    )
    metric["semantic_residual_keys_agree"] = keys_agree
    metric["passed"] = keys_agree && metric["passed"]
    return metric
end

"""
    scaling_covariance_report(reference, reference_map::SemanticBlockScalingMap,
                              candidate, candidate_map::SemanticBlockScalingMap)

Test first-order covariance under semantic block-linear coordinate maps. The
report supports nonsingular variable and zero-equality residual mixing,
positive diagonal scalar bounds, and conformally transformed Euclidean balls.
Unsupported set images are unavailable and block the equivalence gate.
"""
function scaling_covariance_report(
    reference::NumericalEvaluation,
    reference_map::SemanticBlockScalingMap,
    candidate::NumericalEvaluation,
    candidate_map::SemanticBlockScalingMap;
    absolute_tolerance::Real = 1e-9,
    relative_tolerance::Real = 1e-7,
    max_dense_entries::Integer = 100_000,
)
    absolute_tolerance >= 0 ||
        throw(ArgumentError("absolute_tolerance must be nonnegative"))
    relative_tolerance >= 0 ||
        throw(ArgumentError("relative_tolerance must be nonnegative"))
    max_dense_entries >= 0 ||
        throw(ArgumentError("max_dense_entries must be nonnegative"))
    _validate_semantic_map_evaluation(reference, reference_map, "reference")
    _validate_semantic_map_evaluation(candidate, candidate_map, "candidate")
    variable_alignment = _scaling_alignment(
        reference_map.variable_keys, candidate_map.variable_keys, "variable",
    )
    constraint_alignment = _scaling_alignment(
        reference_map.constraint_keys,
        candidate_map.constraint_keys,
        "constraint",
    )

    reference_point = reference_map.variable_model_to_physical *
        reference.point.values
    candidate_point = (candidate_map.variable_model_to_physical *
        candidate.point.values)[variable_alignment]
    point_metric = _covariance_metric(
        reference_point, candidate_point, absolute_tolerance, relative_tolerance,
    )
    point_metric["provenance_complete"] =
        reference.point.provenance.complete && candidate.point.provenance.complete

    constraint_metric = if length(reference.constraint_values) ==
                               size(reference_map.constraint_model_to_physical, 2) &&
                           length(candidate.constraint_values) ==
                               size(candidate_map.constraint_model_to_physical, 2) &&
                           all(!ismissing, reference.constraint_values) &&
                           all(!ismissing, candidate.constraint_values)
        reference_values = reference_map.constraint_model_to_physical *
            Float64.(reference.constraint_values)
        candidate_values = (candidate_map.constraint_model_to_physical *
            Float64.(candidate.constraint_values))[constraint_alignment]
        _covariance_metric(
            reference_values,
            candidate_values,
            absolute_tolerance,
            relative_tolerance,
        )
    else
        _unavailable_covariance_metric(
            "one or both evaluations have missing constraint-function values",
        )
    end
    set_metric = _semantic_set_covariance_metric(
        reference_map,
        candidate_map,
        absolute_tolerance,
        relative_tolerance,
    )
    residual_metric = _semantic_residual_covariance_metric(
        reference,
        reference_map,
        candidate,
        candidate_map,
        absolute_tolerance,
        relative_tolerance,
    )
    objective_metric = if reference.objective_value isa Real &&
                          candidate.objective_value isa Real
        _covariance_metric(
            [Float64(reference.objective_value) * reference_map.objective_scale],
            [Float64(candidate.objective_value) * candidate_map.objective_scale],
            absolute_tolerance,
            relative_tolerance,
        )
    else
        _unavailable_covariance_metric(
            "one or both objective values are unavailable",
        )
    end
    gradient_metric = if length(reference.objective_gradient) ==
                             size(reference_map.variable_physical_to_model, 1) &&
                         length(candidate.objective_gradient) ==
                             size(candidate_map.variable_physical_to_model, 1) &&
                         all(!ismissing, reference.objective_gradient) &&
                         all(!ismissing, candidate.objective_gradient)
        reference_gradient = transpose(
            reference_map.variable_physical_to_model,
        ) * (reference_map.objective_scale .* Float64.(
            reference.objective_gradient,
        ))
        candidate_gradient = (transpose(
            candidate_map.variable_physical_to_model,
        ) * (candidate_map.objective_scale .* Float64.(
            candidate.objective_gradient,
        )))[variable_alignment]
        _covariance_metric(
            reference_gradient,
            candidate_gradient,
            absolute_tolerance,
            relative_tolerance,
        )
    else
        _unavailable_covariance_metric(
            "one or both objective gradients are incomplete",
        )
    end
    derivative_complete = all(method ->
        !(method in _JACOBIAN_INCOMPLETE_METHODS),
        reference.jacobian_row_methods,
    ) && all(method ->
        !(method in _JACOBIAN_INCOMPLETE_METHODS),
        candidate.jacobian_row_methods,
    )
    jacobian_metric = if derivative_complete
        reference_jacobian = _semantic_physical_jacobian(reference, reference_map)
        candidate_jacobian = _semantic_physical_jacobian(candidate, candidate_map)
        reference_entries = _semantic_sparse_entries(
            reference_jacobian,
            reference_map.constraint_keys,
            reference_map.variable_keys,
        )
        candidate_entries = _semantic_sparse_entries(
            candidate_jacobian,
            candidate_map.constraint_keys,
            candidate_map.variable_keys,
        )
        semantic_entries = sort!(collect(union(
            keys(reference_entries), keys(candidate_entries),
        )))
        metric = _covariance_metric(
            [get(reference_entries, key, 0.0) for key in semantic_entries],
            [get(candidate_entries, key, 0.0) for key in semantic_entries],
            absolute_tolerance,
            relative_tolerance,
        )
        metric["comparison_backend"] = "semantic_sparse_block_entries"
        metric["semantic_entry_count"] = length(semantic_entries)
        metric["exact_sparse_support_agrees"] = Set(keys(reference_entries)) ==
            Set(keys(candidate_entries))
        dense_entries = length(reference_map.variable_keys) *
            length(reference_map.constraint_keys)
        metric["physical_rank_available"] = dense_entries <= max_dense_entries
        if metric["physical_rank_available"]
            reference_dense = Matrix(reference_jacobian)
            candidate_dense = Matrix(candidate_jacobian)[
                constraint_alignment, variable_alignment,
            ]
            reference_singular = svdvals(reference_dense)
            candidate_singular = svdvals(candidate_dense)
            reference_threshold = isempty(reference_singular) ? 0.0 :
                max(size(reference_dense)..., 1) * eps(Float64) *
                maximum(reference_singular)
            candidate_threshold = isempty(candidate_singular) ? 0.0 :
                max(size(candidate_dense)..., 1) * eps(Float64) *
                maximum(candidate_singular)
            metric["reference_physical_rank"] = count(
                >(reference_threshold), reference_singular,
            )
            metric["candidate_physical_rank"] = count(
                >(candidate_threshold), candidate_singular,
            )
            metric["physical_rank_agrees"] =
                metric["reference_physical_rank"] ==
                metric["candidate_physical_rank"]
        else
            metric["reference_physical_rank"] = nothing
            metric["candidate_physical_rank"] = nothing
            metric["physical_rank_agrees"] = nothing
            metric["physical_rank_reason"] =
                "dense rank comparison exceeds max_dense_entries=$max_dense_entries"
        end
        metric
    else
        _unavailable_covariance_metric(
            "one or both Jacobians have unavailable or partial rows",
        )
    end
    metrics = Dict{String,Any}(
        "physical_point" => point_metric,
        "constraint_function_values" => constraint_metric,
        "constraint_sets" => set_metric,
        "constraint_residuals" => residual_metric,
        "objective_value" => objective_metric,
        "objective_gradient" => gradient_metric,
        "physical_jacobian" => jacobian_metric,
    )
    required_names = (
        "physical_point", "constraint_function_values", "physical_jacobian",
    )
    required_available = all(metrics[name]["available"] for name in required_names)
    overall = required_available ?
        all(metrics[name]["passed"] for name in required_names) : nothing
    equivalence_names = (
        "physical_point",
        "constraint_function_values",
        "constraint_sets",
        "constraint_residuals",
        "physical_jacobian",
    )
    equivalence_available = all(
        metrics[name]["available"] for name in equivalence_names
    )
    equivalence = equivalence_available ?
        all(metrics[name]["passed"] for name in equivalence_names) : nothing
    available = [metric for metric in values(metrics) if metric["available"]]
    return Dict{String,Any}(
        "report_version" => "semantic-block-scaling-covariance-v1",
        "reference_policy" => reference_map.name,
        "candidate_policy" => candidate_map.name,
        "absolute_tolerance" => Float64(absolute_tolerance),
        "relative_tolerance" => Float64(relative_tolerance),
        "semantic_alignment" => true,
        "mathematical_rank_invariance_under_declared_maps" => true,
        "overall_covariant" => overall,
        "equivalence_gate_passed" => equivalence,
        "constraint_set_coverage_complete" =>
            set_metric["available"] && residual_metric["available"],
        "available_check_count" => length(available),
        "passed_available_check_count" => count(
            metric -> metric["passed"] === true, available,
        ),
        "metrics" => metrics,
        "qualification" => Dict{String,Any}(
            "claim" => "same-point semantic block-linear coordinate covariance",
            "does_not_establish" => [
                "global mathematical equivalence",
                "solver trajectory equivalence",
                "superiority of either scaling policy",
                "covariance of an unsupported coupled set",
            ],
        ),
    )
end

function scaling_covariance_report(
    reference::NumericalEvaluation,
    reference_map::DiagonalScalingMap,
    candidate::NumericalEvaluation,
    candidate_map::SemanticBlockScalingMap;
    kwargs...,
)
    return scaling_covariance_report(
        reference,
        SemanticBlockScalingMap(reference_map),
        candidate,
        candidate_map;
        kwargs...,
    )
end

function scaling_covariance_report(
    reference::NumericalEvaluation,
    reference_map::SemanticBlockScalingMap,
    candidate::NumericalEvaluation,
    candidate_map::DiagonalScalingMap;
    kwargs...,
)
    return scaling_covariance_report(
        reference,
        reference_map,
        candidate,
        SemanticBlockScalingMap(candidate_map);
        kwargs...,
    )
end

function _all_blocks_orthogonal(map::SemanticBlockScalingMap; tolerance)
    blocks = vcat(
        map.variable_blocks,
        [block.linear for block in map.constraint_blocks],
    )
    return all(block -> block.orthogonality_error <= tolerance, blocks)
end

"""Compare solver-coordinate geometry after semantic block covariance passes."""
function scaling_coordinate_geometry_report(
    reference::NumericalEvaluation,
    reference_map::SemanticBlockScalingMap,
    candidate::NumericalEvaluation,
    candidate_map::SemanticBlockScalingMap;
    absolute_tolerance::Real = 1e-9,
    relative_tolerance::Real = 1e-7,
    max_dense_entries::Integer = 100_000,
)
    covariance = scaling_covariance_report(
        reference,
        reference_map,
        candidate,
        candidate_map;
        absolute_tolerance,
        relative_tolerance,
        max_dense_entries,
    )
    reference_geometry = _solver_coordinate_jacobian_geometry(
        reference; max_dense_entries,
    )
    candidate_geometry = _solver_coordinate_jacobian_geometry(
        candidate; max_dense_entries,
    )
    provenance_complete = reference.point.provenance.complete &&
        candidate.point.provenance.complete
    qualified = covariance["equivalence_gate_passed"] === true &&
        provenance_complete && reference_geometry["available"] &&
        candidate_geometry["available"]
    comparisons = Dict{String,Any}()
    for metric in ("row_norm_spread", "column_norm_spread", "condition_proxy")
        reference_value = reference_geometry[metric]
        candidate_value = candidate_geometry[metric]
        comparisons[metric] = Dict{String,Any}(
            "reference" => reference_value,
            "candidate" => candidate_value,
            "candidate_to_reference_ratio" =>
                _scaling_geometry_ratio(candidate_value, reference_value),
            "relation" => _scaling_geometry_relation(
                candidate_value,
                reference_value;
                relative_tolerance,
            ),
        )
    end
    comparisons["zero_pattern"] = Dict{String,Any}(
        "reference_zero_rows" => reference_geometry["zero_row_count"],
        "candidate_zero_rows" => candidate_geometry["zero_row_count"],
        "reference_zero_columns" => reference_geometry["zero_column_count"],
        "candidate_zero_columns" => candidate_geometry["zero_column_count"],
        "counts_agree" =>
            reference_geometry["zero_row_count"] ==
                candidate_geometry["zero_row_count"] &&
            reference_geometry["zero_column_count"] ==
                candidate_geometry["zero_column_count"],
    )
    orthogonality_tolerance = max(
        Float64(absolute_tolerance),
        100 * eps(Float64),
    )
    orthogonal_expected = _all_blocks_orthogonal(
        reference_map; tolerance=orthogonality_tolerance,
    ) && _all_blocks_orthogonal(
        candidate_map; tolerance=orthogonality_tolerance,
    )
    invariance = _unavailable_covariance_metric(
        orthogonal_expected ?
            "dense singular spectrum exceeds the work guard" :
            "one or more declared blocks is not an orthogonal unit-magnitude transformation",
    )
    rows = length(reference.constraint_sources)
    columns = length(reference.point.variables)
    if orthogonal_expected && rows * columns <= max_dense_entries
        reference_singular = svdvals(_combined_jacobian_matrix(reference))
        candidate_singular = svdvals(_combined_jacobian_matrix(candidate))
        invariance = _covariance_metric(
            reference_singular,
            candidate_singular,
            absolute_tolerance,
            relative_tolerance,
        )
        invariance["expected_from_complete_orthogonal_blocks"] = true
    else
        invariance["expected_from_complete_orthogonal_blocks"] =
            orthogonal_expected
    end
    comparisons["orthogonal_singular_value_invariance"] = invariance
    return Dict{String,Any}(
        "report_version" => "semantic-block-scaling-coordinate-geometry-v1",
        "reference_policy" => reference_map.name,
        "candidate_policy" => candidate_map.name,
        "comparison_qualified" => qualified,
        "point_provenance_complete" => provenance_complete,
        "covariance" => covariance,
        "reference_geometry" => reference_geometry,
        "candidate_geometry" => candidate_geometry,
        "comparisons" => comparisons,
        "interpretation" => qualified ?
            "Local solver-coordinate geometry may be compared under the declared physical block-covariance gate." :
            "Scaling-merit interpretation is blocked; inspect covariance, set contracts, point provenance, and derivative coverage.",
        "does_not_establish" => [
            "global model equivalence",
            "solver trajectory equivalence",
            "better convergence or robustness",
            "a universally superior scaling policy",
        ],
    )
end

function _physical_hessian(hessian, map::SemanticBlockScalingMap)
    model_hessian = _combined_hessian_matrix(hessian)
    return transpose(map.variable_physical_to_model) * model_hessian *
        map.variable_physical_to_model
end

function _physical_multipliers(hessian, map::SemanticBlockScalingMap)
    length(hessian.constraint_multipliers) ==
        size(map.constraint_model_to_physical, 2) || throw(DimensionMismatch(
            "Hessian multiplier vector does not match residual scaling map",
        ))
    return transpose(map.constraint_physical_to_model) *
        hessian.constraint_multipliers
end

"""
    scaling_kkt_covariance_report(reference, reference_map, reference_hessian,
                                  candidate, candidate_map, candidate_hessian)

Compare supplied multiplier representatives, stationarity vectors,
Hessians-of-the-Lagrangian, and saddle-point KKT matrices in common physical
coordinates. The report proves covariance of the supplied local objects; it
does not prove KKT optimality, multiplier uniqueness, or complementarity for
general inequalities.
"""
function scaling_kkt_covariance_report(
    reference::NumericalEvaluation,
    reference_map::SemanticBlockScalingMap,
    reference_hessian::HessianEvaluation,
    candidate::NumericalEvaluation,
    candidate_map::SemanticBlockScalingMap,
    candidate_hessian::HessianEvaluation;
    absolute_tolerance::Real = 1e-9,
    relative_tolerance::Real = 1e-7,
    max_dense_entries::Integer = 100_000,
)
    primal = scaling_covariance_report(
        reference,
        reference_map,
        candidate,
        candidate_map;
        absolute_tolerance,
        relative_tolerance,
        max_dense_entries,
    )
    reference.point == reference_hessian.point || throw(ArgumentError(
        "reference evaluation and Hessian points differ",
    ))
    candidate.point == candidate_hessian.point || throw(ArgumentError(
        "candidate evaluation and Hessian points differ",
    ))
    variable_alignment = _scaling_alignment(
        reference_map.variable_keys, candidate_map.variable_keys, "variable",
    )
    constraint_alignment = _scaling_alignment(
        reference_map.constraint_keys,
        candidate_map.constraint_keys,
        "constraint",
    )
    objective_weight_metric = _covariance_metric(
        [Float64(reference_hessian.objective_weight /
            reference_map.objective_scale)],
        [Float64(candidate_hessian.objective_weight /
            candidate_map.objective_scale)],
        absolute_tolerance,
        relative_tolerance,
    )
    reference_multipliers = _physical_multipliers(
        reference_hessian, reference_map,
    )
    candidate_multipliers = _physical_multipliers(
        candidate_hessian, candidate_map,
    )[constraint_alignment]
    multiplier_metric = _covariance_metric(
        reference_multipliers,
        candidate_multipliers,
        absolute_tolerance,
        relative_tolerance,
    )
    reference_jacobian = _semantic_physical_jacobian(
        reference, reference_map,
    )
    candidate_jacobian = _semantic_physical_jacobian(
        candidate, candidate_map,
    )[constraint_alignment, variable_alignment]
    gradients_available = length(reference.objective_gradient) ==
            size(reference_map.variable_physical_to_model, 1) &&
        length(candidate.objective_gradient) ==
            size(candidate_map.variable_physical_to_model, 1) &&
        all(!ismissing, reference.objective_gradient) &&
        all(!ismissing, candidate.objective_gradient)
    stationarity_metric = if gradients_available
        reference_gradient = transpose(
            reference_map.variable_physical_to_model,
        ) * (reference_map.objective_scale .* Float64.(
            reference.objective_gradient,
        ))
        candidate_gradient = (transpose(
            candidate_map.variable_physical_to_model,
        ) * (candidate_map.objective_scale .* Float64.(
            candidate.objective_gradient,
        )))[variable_alignment]
        reference_weight = reference_hessian.objective_weight /
            reference_map.objective_scale
        candidate_weight = candidate_hessian.objective_weight /
            candidate_map.objective_scale
        reference_stationarity = reference_weight .* reference_gradient +
            transpose(reference_jacobian) * reference_multipliers
        candidate_stationarity = candidate_weight .* candidate_gradient +
            transpose(candidate_jacobian) * candidate_multipliers
        _covariance_metric(
            reference_stationarity,
            candidate_stationarity,
            absolute_tolerance,
            relative_tolerance,
        )
    else
        _unavailable_covariance_metric(
            "one or both objective gradients are incomplete",
        )
    end
    variable_count = length(reference_map.variable_keys)
    constraint_count = length(reference_map.constraint_keys)
    required_dense_entries = max(
        variable_count * variable_count,
        (variable_count + constraint_count)^2,
    )
    dense_available = required_dense_entries <= max_dense_entries
    hessian_available = reference_hessian.complete &&
        candidate_hessian.complete && dense_available
    hessian_reason = !reference_hessian.complete || !candidate_hessian.complete ?
        "one or both Hessian evaluations are incomplete" :
        "physical Hessian/KKT comparison requires $required_dense_entries dense entries, exceeding max_dense_entries=$max_dense_entries"
    reference_hessian_physical = nothing
    candidate_hessian_physical = nothing
    hessian_metric = if hessian_available
        reference_hessian_physical = Matrix(_physical_hessian(
            reference_hessian, reference_map,
        ))
        candidate_hessian_physical = Matrix(_physical_hessian(
            candidate_hessian, candidate_map,
        ))[variable_alignment, variable_alignment]
        metric = _covariance_metric(
            vec(reference_hessian_physical),
            vec(candidate_hessian_physical),
            absolute_tolerance,
            relative_tolerance,
        )
        metric["required_dense_entries"] = required_dense_entries
        metric["max_dense_entries"] = max_dense_entries
        metric
    else
        metric = _unavailable_covariance_metric(hessian_reason)
        metric["required_dense_entries"] = required_dense_entries
        metric["max_dense_entries"] = max_dense_entries
        metric
    end
    kkt_metric = if hessian_available
        reference_jacobian_dense = Matrix(reference_jacobian)
        candidate_jacobian_dense = Matrix(candidate_jacobian)
        reference_kkt = [
            reference_hessian_physical transpose(reference_jacobian_dense)
            reference_jacobian_dense zeros(
                eltype(reference_hessian_physical),
                constraint_count,
                constraint_count,
            )
        ]
        candidate_kkt = [
            candidate_hessian_physical transpose(candidate_jacobian_dense)
            candidate_jacobian_dense zeros(
                eltype(candidate_hessian_physical),
                constraint_count,
                constraint_count,
            )
        ]
        metric = _covariance_metric(
            vec(reference_kkt),
            vec(candidate_kkt),
            absolute_tolerance,
            relative_tolerance,
        )
        metric["required_dense_entries"] = required_dense_entries
        metric["max_dense_entries"] = max_dense_entries
        metric
    else
        metric = _unavailable_covariance_metric(hessian_reason)
        metric["required_dense_entries"] = required_dense_entries
        metric["max_dense_entries"] = max_dense_entries
        metric
    end
    complementarity = _unavailable_covariance_metric(
        "general side-specific inequality multipliers are not supplied by HessianEvaluation",
    )
    complementarity["not_applicable_for_zero_equalities"] = all(
        block -> block.set_contract isa ZeroEqualitySetContract,
        reference_map.constraint_blocks,
    ) && all(
        block -> block.set_contract isa ZeroEqualitySetContract,
        candidate_map.constraint_blocks,
    )
    metrics = Dict{String,Any}(
        "physical_objective_weight" => objective_weight_metric,
        "physical_multipliers" => multiplier_metric,
        "physical_stationarity" => stationarity_metric,
        "physical_lagrangian_hessian" => hessian_metric,
        "physical_kkt_matrix" => kkt_metric,
        "complementarity" => complementarity,
    )
    required = (
        "physical_objective_weight",
        "physical_multipliers",
        "physical_stationarity",
        "physical_lagrangian_hessian",
        "physical_kkt_matrix",
    )
    required_available = all(metrics[name]["available"] for name in required)
    optimality_covariant = if primal["equivalence_gate_passed"] === false
        false
    elseif primal["equivalence_gate_passed"] === true && required_available
        all(metrics[name]["passed"] for name in required)
    else
        nothing
    end
    return Dict{String,Any}(
        "report_version" => "semantic-block-kkt-covariance-v1",
        "reference_policy" => reference_map.name,
        "candidate_policy" => candidate_map.name,
        "required_dense_entries" => required_dense_entries,
        "max_dense_entries" => max_dense_entries,
        "primal_covariance" => primal,
        "optimality_covariant" => optimality_covariant,
        "metrics" => metrics,
        "qualification" => Dict{String,Any}(
            "claim" => "covariance of supplied local KKT objects",
            "does_not_establish" => [
                "primal or dual optimality",
                "multiplier uniqueness",
                "inequality complementarity without side-specific duals",
                "nonsingularity of the physical KKT matrix",
            ],
        ),
    )
end

function scaling_kkt_covariance_report(
    reference::NumericalEvaluation,
    reference_map::DiagonalScalingMap,
    reference_hessian::HessianEvaluation,
    candidate::NumericalEvaluation,
    candidate_map::SemanticBlockScalingMap,
    candidate_hessian::HessianEvaluation;
    kwargs...,
)
    return scaling_kkt_covariance_report(
        reference,
        SemanticBlockScalingMap(reference_map),
        reference_hessian,
        candidate,
        candidate_map,
        candidate_hessian;
        kwargs...,
    )
end

function scaling_kkt_covariance_report(
    reference::NumericalEvaluation,
    reference_map::SemanticBlockScalingMap,
    reference_hessian::HessianEvaluation,
    candidate::NumericalEvaluation,
    candidate_map::DiagonalScalingMap,
    candidate_hessian::HessianEvaluation;
    kwargs...,
)
    return scaling_kkt_covariance_report(
        reference,
        reference_map,
        reference_hessian,
        candidate,
        SemanticBlockScalingMap(candidate_map),
        candidate_hessian;
        kwargs...,
    )
end
