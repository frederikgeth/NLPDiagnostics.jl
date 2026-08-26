const _JACOBIAN_INCOMPLETE_METHODS =
    (:unavailable, :partial_central_finite_difference)

function _matrix_norm(matrix, kind::Symbol)
    kind == :frobenius && return norm(matrix)
    kind == :one && return opnorm(matrix, 1)
    kind == :infinity && return opnorm(matrix, Inf)
    throw(ArgumentError("unsupported matrix norm $kind"))
end

function _relative_residual(
    residual::T,
    matrix_norm::T,
    direction_norm::T,
) where {T<:AbstractFloat}
    denominator = matrix_norm * direction_norm
    iszero(denominator) && return iszero(residual) ? zero(T) : T(Inf)
    return residual / denominator
end

function _combined_jacobian_matrix(evaluation::NumericalEvaluation{T}) where {T}
    matrix = zeros(
        T,
        length(evaluation.constraint_sources),
        length(evaluation.point.variables),
    )
    for entry in evaluation.jacobian_entries
        matrix[entry.row, entry.column] += entry.value
    end
    return matrix
end

function _normalized_columns(matrix::Matrix{T}) where {T}
    for column in axes(matrix, 2)
        column_norm = norm(view(matrix, :, column))
        iszero(column_norm) || (matrix[:, column] ./= column_norm)
    end
    return matrix
end

"""Combine additive raw Jacobian entries into one sparse matrix."""
function _combined_sparse_jacobian_matrix(
    evaluation::NumericalEvaluation{T},
) where {T<:AbstractFloat}
    combined = Dict{Tuple{Int,Int},T}()
    for entry in evaluation.jacobian_entries
        key = (entry.row, entry.column)
        combined[key] = get(combined, key, zero(T)) + entry.value
    end
    rows = Int[]
    columns = Int[]
    values = T[]
    for ((row, column), value) in combined
        push!(rows, row)
        push!(columns, column)
        push!(values, value)
    end
    return sparse(
        rows,
        columns,
        values,
        length(evaluation.constraint_sources),
        length(evaluation.point.variables),
    )
end

function _jacobian_diagonal_scaling(
    matrix::AbstractMatrix{T}, scaling::Symbol,
) where {T<:AbstractFloat}
    scaling in (:none, :row, :column, :row_column) || throw(ArgumentError(
        "scaling must be :none, :row, :column, or :row_column",
    ))
    rows, columns = size(matrix)
    row_scaling = ones(T, rows)
    column_scaling = ones(T, columns)
    scaled = copy(matrix)
    if scaling in (:row, :row_column)
        for row in axes(scaled, 1)
            row_norm = norm(view(scaled, row, :))
            if isfinite(row_norm) && !iszero(row_norm)
                factor = inv(row_norm)
                isfinite(factor) && (row_scaling[row] = factor)
            end
        end
        scaled = Diagonal(row_scaling) * scaled
    end
    if scaling in (:column, :row_column)
        for column in axes(scaled, 2)
            column_norm = norm(view(scaled, :, column))
            if isfinite(column_norm) && !iszero(column_norm)
                factor = inv(column_norm)
                isfinite(factor) && (column_scaling[column] = factor)
            end
        end
        scaled = scaled * Diagonal(column_scaling)
    end
    return (
        matrix = scaled,
        row_scaling = row_scaling,
        column_scaling = column_scaling,
    )
end

"""
Build a point-local diagonally scaled Jacobian evaluation for a controlled
numerical intervention. Row factors are computed first, followed by column
factors, exactly as in `RankPolicy(...; scaling = ...)`. Zero-norm rows or
columns retain factor one. The model, point values, function values, and
derivative provenance are not modified.
"""
function _diagonally_scaled_jacobian_evaluation(
    evaluation::NumericalEvaluation{T}, scaling::Symbol,
) where {T<:AbstractFloat}
    combined = _combined_sparse_jacobian_matrix(evaluation)
    intervention = _jacobian_diagonal_scaling(combined, scaling)
    entries = JacobianEntry{T}[
        JacobianEntry{T}(
            entry.row,
            entry.column,
            entry.value * intervention.row_scaling[entry.row] *
                intervention.column_scaling[entry.column],
        ) for entry in evaluation.jacobian_entries
    ]
    scaled_evaluation = NumericalEvaluation{T}(
        evaluation.point,
        evaluation.objective_value,
        evaluation.objective_source,
        copy(evaluation.objective_gradient),
        copy(evaluation.constraint_values),
        copy(evaluation.constraint_sources),
        entries,
        copy(evaluation.jacobian_row_methods),
        copy(evaluation.capabilities),
        copy(evaluation.failures),
        copy(evaluation.call_statistics),
        evaluation.objective_gradient_method,
    )
    return (
        evaluation = scaled_evaluation,
        scaling = scaling,
        row_scaling = intervention.row_scaling,
        column_scaling = intervention.column_scaling,
    )
end

function _unavailable_jacobian_linear_operator(
    evaluation::NumericalEvaluation{T},
    reason::AbstractString,
) where {T<:AbstractFloat}
    rows = length(evaluation.constraint_sources)
    columns = length(evaluation.point.variables)
    return JacobianLinearOperator{T,SparseMatrixCSC{T,Int},Nothing}(
        false, String(reason), evaluation.point, rows, columns, :unavailable,
        spzeros(T, rows, columns), nothing, Int[], nothing,
    )
end

"""
    jacobian_linear_operator(evaluation)

Construct an inspectable sparse local Jacobian operator from the additive
entries in `evaluation`. Incomplete derivative rows and non-finite entries
produce an unavailable operator rather than an implicit zero contribution.
"""
function jacobian_linear_operator(
    evaluation::NumericalEvaluation{T},
) where {T<:AbstractFloat}
    incomplete = findall(
        method -> method in _JACOBIAN_INCOMPLETE_METHODS,
        evaluation.jacobian_row_methods,
    )
    isempty(incomplete) || return _unavailable_jacobian_linear_operator(
        evaluation, "Jacobian rows $(join(incomplete, ',')) are incomplete",
    )
    all(entry -> isfinite(entry.value), evaluation.jacobian_entries) ||
        return _unavailable_jacobian_linear_operator(
            evaluation, "Jacobian contains non-finite raw entries",
        )
    matrix = _combined_sparse_jacobian_matrix(evaluation)
    all(isfinite, nonzeros(matrix)) || return _unavailable_jacobian_linear_operator(
        evaluation, "Jacobian contains non-finite combined entries",
    )
    return JacobianLinearOperator{T,typeof(matrix),Nothing}(
        true, nothing, evaluation.point, size(matrix, 1), size(matrix, 2),
        :assembled_sparse, matrix, nothing, Int[], nothing,
    )
end

"""
    jacobian_linear_operator(model, evaluation; prefer_native = true)

Construct a hybrid operator that uses public MOI `:JacVec` and transposed
Jacobian-product callbacks for NLP-block rows when available. The operator
retains the assembled sparse matrix and reports an explicit fallback reason
when the evaluator does not provide a usable native product path.
"""
function jacobian_linear_operator(
    model::MOI.ModelLike,
    evaluation::NumericalEvaluation{T};
    prefer_native::Bool = true,
    native_consistency_tolerance::Real = sqrt(eps(T)),
) where {T<:AbstractFloat}
    consistency_tolerance = T(native_consistency_tolerance)
    isfinite(consistency_tolerance) && consistency_tolerance >= zero(T) ||
        throw(ArgumentError(
            "native_consistency_tolerance must be finite and nonnegative",
        ))
    evaluation.point.variables == MOI.get(model, MOI.ListOfVariableIndices()) ||
        throw(ArgumentError("evaluation-point variable order does not match the model"))
    assembled = jacobian_linear_operator(evaluation)
    assembled.available || return assembled
    prefer_native || return assembled
    block = _optional_nlp_block(model)
    isnothing(block) && return JacobianLinearOperator{T,typeof(assembled.assembled_matrix),Nothing}(
        true, nothing, evaluation.point, assembled.rows, assembled.columns,
        :assembled_sparse, assembled.assembled_matrix, nothing, Int[],
        "no NLPBlock",
    )
    capability = evaluator_capabilities(block.evaluator)
    if !(:JacVec in capability.available_features)
        return JacobianLinearOperator{T,typeof(assembled.assembled_matrix),Nothing}(
            true, nothing, evaluation.point, assembled.rows, assembled.columns,
            :assembled_sparse, assembled.assembled_matrix, nothing, Int[],
            "NLP evaluator does not advertise :JacVec",
        )
    end
    nlp_rows = findall(source -> source.kind == :nlp_constraint,
        evaluation.constraint_sources)
    length(nlp_rows) == length(block.constraint_bounds) ||
        return _unavailable_jacobian_linear_operator(
            evaluation,
            "NLP row mapping does not match NLPBlock constraint bounds",
        )
    try
        MOI.initialize(block.evaluator, copy(capability.requested_features))
    catch error
        return JacobianLinearOperator{T,typeof(assembled.assembled_matrix),Nothing}(
            true, nothing, evaluation.point, assembled.rows, assembled.columns,
            :assembled_sparse, assembled.assembled_matrix, nothing, Int[],
            "MOI :JacVec initialization failed: $(sprint(showerror, error))",
        )
    end
    try
        right_probe = T[sin(T(column)) for column in 1:assembled.columns]
        right_norm = norm(right_probe)
        iszero(right_norm) || (right_probe ./= right_norm)
        native_product = zeros(T, length(nlp_rows))
        MOI.eval_constraint_jacobian_product(
            block.evaluator, native_product, copy(evaluation.point.values), right_probe,
        )
        assembled_product = assembled.assembled_matrix[nlp_rows, :] * right_probe
        product_error = norm(native_product - assembled_product) /
            max(one(T), norm(native_product), norm(assembled_product))

        left_probe = T[cos(T(row)) for row in 1:length(nlp_rows)]
        left_norm = norm(left_probe)
        iszero(left_norm) || (left_probe ./= left_norm)
        native_transpose = zeros(T, assembled.columns)
        MOI.eval_constraint_jacobian_transpose_product(
            block.evaluator, native_transpose, copy(evaluation.point.values), left_probe,
        )
        assembled_transpose = adjoint(assembled.assembled_matrix[nlp_rows, :]) * left_probe
        transpose_error = norm(native_transpose - assembled_transpose) /
            max(one(T), norm(native_transpose), norm(assembled_transpose))
        if !(isfinite(product_error) && isfinite(transpose_error) &&
             product_error <= consistency_tolerance &&
             transpose_error <= consistency_tolerance)
            return JacobianLinearOperator{T,typeof(assembled.assembled_matrix),Nothing}(
                true, nothing, evaluation.point, assembled.rows, assembled.columns,
                :assembled_sparse, assembled.assembled_matrix, nothing, Int[],
                "MOI :JacVec consistency screen failed: product_relative_error=$(product_error), transpose_relative_error=$(transpose_error), tolerance=$(consistency_tolerance)",
            )
        end
    catch error
        return JacobianLinearOperator{T,typeof(assembled.assembled_matrix),Nothing}(
            true, nothing, evaluation.point, assembled.rows, assembled.columns,
            :assembled_sparse, assembled.assembled_matrix, nothing, Int[],
            "MOI :JacVec consistency screen failed: $(sprint(showerror, error))",
        )
    end
    return JacobianLinearOperator{T,typeof(assembled.assembled_matrix),typeof(block.evaluator)}(
        true, nothing, evaluation.point, assembled.rows, assembled.columns,
        :hybrid_moi_jacvec, assembled.assembled_matrix, block.evaluator,
        nlp_rows, nothing,
    )
end

Base.size(operator::JacobianLinearOperator) = (operator.rows, operator.columns)
Base.size(operator::JacobianLinearOperator, dimension::Integer) =
    size(operator)[dimension]

function jacobian_product(
    operator::JacobianLinearOperator{T},
    direction::AbstractVector{<:Real},
) where {T<:AbstractFloat}
    operator.available || throw(ArgumentError(
        "Jacobian operator is unavailable: $(operator.reason)",
    ))
    length(direction) == operator.columns || throw(DimensionMismatch(
        "Jacobian product direction has length $(length(direction)); expected $(operator.columns)",
    ))
    converted = T.(direction)
    result = operator.assembled_matrix * converted
    if operator.source == :hybrid_moi_jacvec
        native = zeros(T, length(operator.nlp_rows))
        MOI.eval_constraint_jacobian_product(
            operator.nlp_evaluator, native, copy(operator.point.values), converted,
        )
        result[operator.nlp_rows] .= native
    end
    all(isfinite, result) || throw(ArgumentError(
        "Jacobian product returned non-finite values",
    ))
    return result
end

function jacobian_transpose_product(
    operator::JacobianLinearOperator{T},
    direction::AbstractVector{<:Real},
) where {T<:AbstractFloat}
    operator.available || throw(ArgumentError(
        "Jacobian operator is unavailable: $(operator.reason)",
    ))
    length(direction) == operator.rows || throw(DimensionMismatch(
        "transposed-Jacobian product direction has length $(length(direction)); expected $(operator.rows)",
    ))
    converted = T.(direction)
    result = adjoint(operator.assembled_matrix) * converted
    if operator.source == :hybrid_moi_jacvec
        nlp_direction = converted[operator.nlp_rows]
        result .-= adjoint(operator.assembled_matrix[operator.nlp_rows, :]) * nlp_direction
        native = zeros(T, operator.columns)
        MOI.eval_constraint_jacobian_transpose_product(
            operator.nlp_evaluator, native, copy(operator.point.values), nlp_direction,
        )
        result .+= native
    end
    all(isfinite, result) || throw(ArgumentError(
        "transposed-Jacobian product returned non-finite values",
    ))
    return result
end

function _jacobian_products(operator::JacobianLinearOperator{T}, directions) where {T}
    return hcat((jacobian_product(operator, view(directions, :, column))
        for column in axes(directions, 2))...)
end

function _jacobian_transpose_products(
    operator::JacobianLinearOperator{T}, directions,
) where {T}
    return hcat((jacobian_transpose_product(operator, view(directions, :, column))
        for column in axes(directions, 2))...)
end

function _unavailable_rank_estimate(
    evaluation::NumericalEvaluation{T},
    policy::RankPolicy{T},
    reason::AbstractString,
) where {T}
    rows = length(evaluation.constraint_sources)
    columns = length(evaluation.point.variables)
    return JacobianRankEstimate{T}(
        false,
        String(reason),
        evaluation.point,
        policy,
        :dense_svd,
        policy.scaling,
        rows,
        columns,
        0,
        rows,
        columns,
        T[],
        policy.relative_tolerance,
        policy.absolute_tolerance,
        nothing,
        ones(T, rows),
        ones(T, columns),
        zeros(T, rows, 0),
        zeros(T, columns, 0),
    )
end

function _unavailable_sparse_pattern_estimate(
    evaluation::NumericalEvaluation{T},
    tolerance::T,
    reason::AbstractString,
) where {T}
    rows = length(evaluation.constraint_sources)
    columns = length(evaluation.point.variables)
    return SparseJacobianPatternEstimate{T}(
        false, String(reason), evaluation.point, rows, columns, 0, tolerance,
        0, Int[], Int[],
    )
end

function _augment_sparse_row!(
    row::Int,
    adjacency::Vector{Vector{Int}},
    column_match::Vector{Int},
    seen_columns::BitVector,
)
    for column in adjacency[row]
        seen_columns[column] && continue
        seen_columns[column] = true
        previous_row = column_match[column]
        if iszero(previous_row) ||
           _augment_sparse_row!(
            previous_row,
            adjacency,
            column_match,
            seen_columns,
        )
            column_match[column] = row
            return true
        end
    end
    return false
end

function sparse_qr_rank_estimate(
    evaluation::NumericalEvaluation{T};
    relative_tolerance::Real = max(length(evaluation.constraint_sources), length(evaluation.point.variables), 1) * eps(T),
    absolute_tolerance::Real = zero(T),
    scaling::Symbol = :none,
    matrix_norm::Symbol = :frobenius,
    max_dense_entries::Integer = 100_000,
    max_input_nonzeros::Integer = 1_000_000,
    max_factor_nonzeros::Integer = 4_000_000,
    provenance::Symbol = :default,
) where {T<:AbstractFloat}
    for (name, value) in (
        ("max_input_nonzeros", max_input_nonzeros),
        ("max_factor_nonzeros", max_factor_nonzeros),
    )
        value >= 0 || throw(ArgumentError("$name must be nonnegative"))
        value <= typemax(Int) || throw(ArgumentError("$name is too large"))
    end
    policy = RankPolicy(
        T;
        backend = :sparse_qr,
        scaling,
        relative_tolerance,
        absolute_tolerance,
        matrix_norm,
        max_dense_entries,
        compute_vectors = false,
        provenance,
    )
    return _sparse_qr_rank_estimate(
        evaluation, policy, Int(max_input_nonzeros), Int(max_factor_nonzeros),
    )
end

function sparse_qr_nullspace_estimate(
    evaluation::NumericalEvaluation{T};
    relative_tolerance::Real = max(
        length(evaluation.constraint_sources),
        length(evaluation.point.variables),
        1,
    ) * eps(T),
    absolute_tolerance::Real = zero(T),
    scaling::Symbol = :none,
    matrix_norm::Symbol = :frobenius,
    max_input_nonzeros::Integer = 1_000_000,
    max_factor_nonzeros::Integer = 4_000_000,
    max_nullspace_entries::Integer = 1_000_000,
    provenance::Symbol = :default,
) where {T<:AbstractFloat}
    for (name, value) in (
        ("max_input_nonzeros", max_input_nonzeros),
        ("max_factor_nonzeros", max_factor_nonzeros),
        ("max_nullspace_entries", max_nullspace_entries),
    )
        value >= 0 || throw(ArgumentError("$name must be nonnegative"))
        value <= typemax(Int) || throw(ArgumentError("$name is too large"))
    end
    policy = RankPolicy(
        T;
        backend = :sparse_qr,
        scaling,
        relative_tolerance,
        absolute_tolerance,
        matrix_norm,
        max_dense_entries = 0,
        compute_vectors = true,
        provenance,
    )
    rows = length(evaluation.constraint_sources)
    columns = length(evaluation.point.variables)
    input_limit = Int(max_input_nonzeros)
    factor_limit = Int(max_factor_nonzeros)
    nullspace_limit = Int(max_nullspace_entries)
    unavailable(
        reason;
        rank = 0,
        pivots = T[],
        threshold = policy.absolute_tolerance,
        row_scaling = ones(T, rows),
        column_scaling = ones(T, columns),
        row_permutation = Int[],
        column_permutation = Int[],
        input_nonzeros = 0,
        factor_nonzeros = 0,
        fill_ratio = nothing,
    ) = SparseQRNullspaceEstimate{T}(
        false, String(reason), evaluation.point, policy, rows, columns,
        rank, max(columns - rank, 0), pivots, threshold, row_scaling,
        column_scaling, row_permutation, column_permutation,
        zeros(T, columns, 0), T[], T[], nothing, nothing,
        input_nonzeros, factor_nonzeros, fill_ratio, input_limit,
        factor_limit, nullspace_limit,
    )

    pattern = sparse_jacobian_pattern_estimate(evaluation)
    pattern.available || return unavailable(pattern.reason)
    matrix = _combined_sparse_jacobian_matrix(evaluation)
    input_nonzeros = nnz(matrix)
    input_nonzeros <= input_limit || return unavailable(
        "combined Jacobian has $input_nonzeros nonzeros, exceeding max_input_nonzeros=$input_limit";
        input_nonzeros,
    )
    scaling_intervention = _jacobian_diagonal_scaling(matrix, scaling)
    scaled = sparse(scaling_intervention.matrix)
    all(isfinite, nonzeros(scaled)) || return unavailable(
        "scaled Jacobian contains non-finite entries";
        row_scaling = scaling_intervention.row_scaling,
        column_scaling = scaling_intervention.column_scaling,
        input_nonzeros,
    )
    try
        factorization = qr(scaled)
        R = sparse(factorization.R)
        factor_nonzeros = nnz(R)
        fill_ratio = T(factor_nonzeros) / T(max(input_nonzeros, 1))
        pivots = collect(T, abs.(diag(R)))
        threshold = isempty(pivots) ? policy.absolute_tolerance : max(
            policy.absolute_tolerance,
            policy.relative_tolerance * maximum(pivots),
        )
        retained = pivots .> threshold
        rank = count(retained)
        row_permutation = Int.(factorization.prow)
        column_permutation = Int.(factorization.pcol)
        factor_nonzeros <= factor_limit || return unavailable(
            "SuiteSparseQR R factor has $factor_nonzeros nonzeros, exceeding max_factor_nonzeros=$factor_limit";
            rank, pivots, threshold,
            row_scaling = scaling_intervention.row_scaling,
            column_scaling = scaling_intervention.column_scaling,
            row_permutation, column_permutation, input_nonzeros,
            factor_nonzeros, fill_ratio,
        )
        rank <= length(pivots) || return unavailable(
            "estimated QR rank exceeds the available diagonal pivots";
            rank, pivots, threshold,
            row_scaling = scaling_intervention.row_scaling,
            column_scaling = scaling_intervention.column_scaling,
            row_permutation, column_permutation, input_nonzeros,
            factor_nonzeros, fill_ratio,
        )
        leading_profile = all(retained[1:rank]) &&
            all(.!retained[(rank + 1):end])
        leading_profile || return unavailable(
            "QR pivots above the declared threshold do not form a leading block";
            rank, pivots, threshold,
            row_scaling = scaling_intervention.row_scaling,
            column_scaling = scaling_intervention.column_scaling,
            row_permutation, column_permutation, input_nonzeros,
            factor_nonzeros, fill_ratio,
        )
        nullity = columns - rank
        big(columns) * nullity <= nullspace_limit || return unavailable(
            "right-nullspace basis would contain $(big(columns) * nullity) entries, exceeding max_nullspace_entries=$nullspace_limit";
            rank, pivots, threshold,
            row_scaling = scaling_intervention.row_scaling,
            column_scaling = scaling_intervention.column_scaling,
            row_permutation, column_permutation, input_nonzeros,
            factor_nonzeros, fill_ratio,
        )
        directions = zeros(T, columns, nullity)
        if nullity > 0
            permuted = zeros(T, columns, nullity)
            permuted[(rank + 1):columns, :] .= Matrix{T}(I, nullity, nullity)
            if rank > 0
                R11 = UpperTriangular(R[1:rank, 1:rank])
                R12 = Matrix(R[1:rank, (rank + 1):columns])
                permuted[1:rank, :] .= -(R11 \ R12)
            end
            scaled_directions = zeros(T, columns, nullity)
            scaled_directions[column_permutation, :] .= permuted
            mapped = scaled_directions .* scaling_intervention.column_scaling
            mapped_factorization = qr(mapped)
            mapped_pivots = abs.(diag(mapped_factorization.R))
            mapped_threshold = sqrt(eps(T)) *
                maximum(mapped_pivots; init = zero(T))
            count(value -> value > mapped_threshold, mapped_pivots) == nullity ||
                return unavailable(
                    "mapped QR nullspace lost dimension in original coordinates";
                    rank, pivots, threshold,
                    row_scaling = scaling_intervention.row_scaling,
                    column_scaling = scaling_intervention.column_scaling,
                    row_permutation, column_permutation, input_nonzeros,
                    factor_nonzeros, fill_ratio,
                )
            directions .= Matrix(mapped_factorization.Q[:, 1:nullity])
        end
        operator = jacobian_linear_operator(evaluation)
        operator.available || return unavailable(
            something(operator.reason, "original Jacobian operator unavailable");
            rank, pivots, threshold,
            row_scaling = scaling_intervention.row_scaling,
            column_scaling = scaling_intervention.column_scaling,
            row_permutation, column_permutation, input_nonzeros,
            factor_nonzeros, fill_ratio,
        )
        norm_value = T(_matrix_norm(operator.assembled_matrix, matrix_norm))
        residual_norms = T[
            norm(jacobian_product(operator, view(directions, :, index)))
            for index in axes(directions, 2)
        ]
        relative_residuals = T[
            _relative_residual(
                residual_norms[index], norm_value,
                norm(view(directions, :, index)),
            ) for index in eachindex(residual_norms)
        ]
        orthogonality_loss = nullity == 0 ? zero(T) : T(norm(
            transpose(directions) * directions - Matrix{T}(I, nullity, nullity),
        ))
        return SparseQRNullspaceEstimate{T}(
            true, nothing, evaluation.point, policy, rows, columns, rank,
            nullity, pivots, threshold, scaling_intervention.row_scaling,
            scaling_intervention.column_scaling, row_permutation,
            column_permutation, directions, residual_norms,
            relative_residuals, norm_value, orthogonality_loss,
            input_nonzeros, factor_nonzeros, fill_ratio, input_limit,
            factor_limit, nullspace_limit,
        )
    catch error
        return unavailable(
            "SuiteSparseQR nullspace extraction failed: $(sprint(showerror, error))";
            row_scaling = scaling_intervention.row_scaling,
            column_scaling = scaling_intervention.column_scaling,
            input_nonzeros,
        )
    end
end

function sparse_qr_nullspace_dense_calibration(
    evaluation::NumericalEvaluation{T};
    relative_tolerance::Real = max(
        length(evaluation.constraint_sources),
        length(evaluation.point.variables),
        1,
    ) * eps(T),
    absolute_tolerance::Real = zero(T),
    scaling::Symbol = :none,
    matrix_norm::Symbol = :frobenius,
    max_input_nonzeros::Integer = 1_000_000,
    max_factor_nonzeros::Integer = 4_000_000,
    max_nullspace_entries::Integer = 1_000_000,
    dense_max_entries::Integer = 4_000_000,
    subspace_alignment_threshold::Real = 0.98,
    threshold_margin_factor::Real = 10,
    provenance::Symbol = :dense_calibration,
) where {T<:AbstractFloat}
    alignment_threshold = T(subspace_alignment_threshold)
    margin = T(threshold_margin_factor)
    isfinite(alignment_threshold) && zero(T) <= alignment_threshold <= one(T) ||
        throw(ArgumentError("subspace_alignment_threshold must lie in [0, 1]"))
    isfinite(margin) && margin > one(T) || throw(ArgumentError(
        "threshold_margin_factor must be finite and greater than one",
    ))
    estimate = sparse_qr_nullspace_estimate(
        evaluation;
        relative_tolerance,
        absolute_tolerance,
        scaling,
        matrix_norm,
        max_input_nonzeros,
        max_factor_nonzeros,
        max_nullspace_entries,
        provenance,
    )
    dense_policy = RankPolicy(
        T;
        backend = :dense_svd,
        scaling,
        relative_tolerance,
        absolute_tolerance,
        matrix_norm,
        max_dense_entries = dense_max_entries,
        compute_vectors = true,
        provenance,
    )
    dense = jacobian_rank_estimate(evaluation, dense_policy)
    unavailable(reason) = SparseQRNullspaceDenseCalibration{T}(
        false, String(reason), evaluation.point, :unavailable, estimate,
        dense, nothing, false, alignment_threshold, margin,
    )
    estimate.available || return unavailable(
        "sparse-QR nullspace unavailable: $(estimate.reason)",
    )
    dense.available || return unavailable(
        "dense SVD unavailable: $(dense.reason)",
    )
    threshold = dense.absolute_threshold
    ambiguous = if iszero(threshold)
        false
    else
        any(value -> value > zero(T) &&
            threshold / margin <= value <= threshold * margin,
            dense.singular_values)
    end
    minimum_cosine = nothing
    if estimate.right_nullity == dense.right_nullity &&
       estimate.right_nullity > 0
        cosines = _principal_cosines(
            estimate.directions,
            dense.right_nullspace,
        )
        isempty(cosines) || (minimum_cosine = minimum(cosines))
    end
    relation = if estimate.right_nullity != dense.right_nullity
        :dimension_disagreement
    elseif iszero(estimate.right_nullity)
        ambiguous ? :agreement_no_nullspace_threshold_ambiguous :
            :agreement_no_nullspace
    elseif ambiguous
        :dense_rank_threshold_ambiguous
    elseif something(minimum_cosine, zero(T)) >= alignment_threshold
        :subspace_agreement
    else
        :subspace_disagreement
    end
    return SparseQRNullspaceDenseCalibration{T}(
        true, nothing, evaluation.point, relation, estimate, dense,
        minimum_cosine, ambiguous, alignment_threshold, margin,
    )
end

function sparse_qr_nullspace_persistence(
    evaluations::AbstractVector{<:NumericalEvaluation{T}};
    minimum_evaluations::Integer = 2,
    subspace_alignment_threshold::Real = 0.98,
    relative_tolerance::Real = isempty(evaluations) ? eps(T) : max(
        length(first(evaluations).constraint_sources),
        length(first(evaluations).point.variables),
        1,
    ) * eps(T),
    absolute_tolerance::Real = zero(T),
    scaling::Symbol = :none,
    matrix_norm::Symbol = :frobenius,
    max_input_nonzeros::Integer = 1_000_000,
    max_factor_nonzeros::Integer = 4_000_000,
    max_nullspace_entries::Integer = 1_000_000,
    provenance::Symbol = :persistence,
) where {T<:AbstractFloat}
    minimum_evaluations >= 2 || throw(ArgumentError(
        "minimum_evaluations must be at least two",
    ))
    minimum_evaluations <= typemax(Int) || throw(ArgumentError(
        "minimum_evaluations is too large",
    ))
    alignment_threshold = T(subspace_alignment_threshold)
    isfinite(alignment_threshold) && zero(T) <= alignment_threshold <= one(T) ||
        throw(ArgumentError("subspace_alignment_threshold must lie in [0, 1]"))
    minimum_count = Int(minimum_evaluations)
    estimates = SparseQRNullspaceEstimate{T}[]
    labels = String[evaluation.point.label for evaluation in evaluations]
    unavailable(reason) = SparseQRNullspacePersistenceEstimate{T}(
        false, String(reason), estimates, labels,
        Int[estimate.rank for estimate in estimates],
        Int[estimate.right_nullity for estimate in estimates],
        NTuple{2,Int}[], T[], T[], nothing, nothing, nothing,
        false, false, alignment_threshold, minimum_count,
    )
    length(evaluations) >= minimum_count || return unavailable(
        "received $(length(evaluations)) evaluations, fewer than minimum_evaluations=$minimum_count",
    )
    reference_variables = first(evaluations).point.variables
    reference_rows = first(evaluations).constraint_sources
    all(evaluation -> evaluation.point.variables == reference_variables,
        evaluations) || return unavailable(
            "evaluation variable coordinates are not aligned",
        )
    all(evaluation -> evaluation.constraint_sources == reference_rows,
        evaluations) || return unavailable(
            "evaluation constraint rows are not aligned",
        )
    append!(estimates, (
        sparse_qr_nullspace_estimate(
            evaluation;
            relative_tolerance,
            absolute_tolerance,
            scaling,
            matrix_norm,
            max_input_nonzeros,
            max_factor_nonzeros,
            max_nullspace_entries,
            provenance,
        ) for evaluation in evaluations
    ))
    unavailable_indices = findall(estimate -> !estimate.available, estimates)
    isempty(unavailable_indices) || return unavailable(
        "sparse-QR nullspace unavailable at evaluation indices $(join(unavailable_indices, ','))",
    )
    ranks = Int[estimate.rank for estimate in estimates]
    nullities = Int[estimate.right_nullity for estimate in estimates]
    pair_indices = NTuple{2,Int}[]
    pair_distances = T[]
    pair_cosines = T[]
    repeat_cosines = T[]
    nearby_cosines = T[]
    for left in eachindex(estimates), right in (left + 1):length(estimates)
        push!(pair_indices, (left, right))
        left_values = evaluations[left].point.values
        right_values = evaluations[right].point.values
        scale = max(
            norm(left_values, Inf), norm(right_values, Inf), one(T),
        )
        distance = T(norm(left_values - right_values, Inf) / scale)
        push!(pair_distances, distance)
        cosine = if nullities[left] != nullities[right]
            zero(T)
        elseif iszero(nullities[left])
            one(T)
        else
            cosines = _principal_cosines(
                estimates[left].directions,
                estimates[right].directions,
            )
            isempty(cosines) ? zero(T) : minimum(cosines)
        end
        push!(pair_cosines, cosine)
        if iszero(distance)
            push!(repeat_cosines, cosine)
        else
            push!(nearby_cosines, cosine)
        end
    end
    residuals = T[
        residual for estimate in estimates
        for residual in estimate.relative_residual_norms
    ]
    maximum_residual = isempty(residuals) ? zero(T) : maximum(residuals)
    rank_stable = all(==(first(ranks)), ranks) &&
        all(==(first(nullities)), nullities)
    persistent = rank_stable &&
        all(cosine -> cosine >= alignment_threshold, pair_cosines)
    return SparseQRNullspacePersistenceEstimate{T}(
        true, nothing, estimates, labels, ranks, nullities, pair_indices,
        pair_distances, pair_cosines,
        isempty(repeat_cosines) ? nothing : minimum(repeat_cosines),
        isempty(nearby_cosines) ? nothing : minimum(nearby_cosines),
        maximum_residual, rank_stable, persistent, alignment_threshold,
        minimum_count,
    )
end

function sparse_qr_rank_estimate(
    evaluation::NumericalEvaluation{T},
    policy::RankPolicy{T},
) where {T<:AbstractFloat}
    return _sparse_qr_rank_estimate(
        evaluation, policy, 1_000_000, 4_000_000,
    )
end

function _sparse_qr_rank_estimate(
    evaluation::NumericalEvaluation{T},
    policy::RankPolicy{T},
    max_input_nonzeros::Int,
    max_factor_nonzeros::Int,
) where {T<:AbstractFloat}
    policy.backend == :sparse_qr ||
        throw(ArgumentError("sparse_qr_rank_estimate requires a :sparse_qr RankPolicy"))
    rows, columns = length(evaluation.constraint_sources), length(evaluation.point.variables)
    pattern = sparse_jacobian_pattern_estimate(evaluation)
    unavailable(
        reason;
        input_nonzeros = 0,
        factor_nonzeros = 0,
        fill_ratio = nothing,
    ) = SparseQRRankEstimate{T}(
        false, reason, evaluation.point, policy, :suitesparse_qr,
        policy.scaling, rows, columns, 0, T[], policy.relative_tolerance,
        policy.absolute_tolerance, nothing, nothing, Int[], Int[], nothing,
        nothing, input_nonzeros, factor_nonzeros, fill_ratio,
        max_input_nonzeros, max_factor_nonzeros,
    )
    !pattern.available && return unavailable(pattern.reason)
    matrix = _combined_sparse_jacobian_matrix(evaluation)
    input_nonzeros = nnz(matrix)
    input_nonzeros <= max_input_nonzeros || return unavailable(
        "combined Jacobian has $input_nonzeros nonzeros, exceeding max_input_nonzeros=$max_input_nonzeros";
        input_nonzeros,
    )
    try
        if policy.scaling in (:row, :row_column)
            row_norms = [norm(matrix[row, :]) for row in 1:rows]
            matrix = spdiagm(0 => T[iszero(value) ? one(T) : inv(value) for value in row_norms]) * matrix
        end
        if policy.scaling in (:column, :row_column)
            column_norms = [norm(matrix[:, column]) for column in 1:columns]
            matrix = matrix * spdiagm(0 => T[iszero(value) ? one(T) : inv(value) for value in column_norms])
        end
        factorization = qr(matrix)
        R = sparse(factorization.R)
        factor_nonzeros = nnz(R)
        fill_ratio = T(factor_nonzeros) / T(max(input_nonzeros, 1))
        factor_nonzeros <= max_factor_nonzeros || return unavailable(
            "SuiteSparseQR R factor has $factor_nonzeros nonzeros, exceeding max_factor_nonzeros=$max_factor_nonzeros";
            input_nonzeros, factor_nonzeros, fill_ratio,
        )
        pivots = T.(abs.(diag(R)))
        threshold = isempty(pivots) ? policy.absolute_tolerance : max(
            policy.absolute_tolerance,
            policy.relative_tolerance * maximum(pivots),
        )
        retained = filter(value -> value > threshold, pivots)
        proxy = isempty(retained) ? nothing : maximum(retained) / minimum(retained)
        norm_value = T(_matrix_norm(matrix, policy.matrix_norm))
        row_permutation = Int.(factorization.prow)
        column_permutation = Int.(factorization.pcol)
        relative_factorization_residual = nothing
        residual_reason = nothing
        if rows * columns <= policy.max_dense_entries
            try
                permuted = Matrix(matrix[row_permutation, column_permutation])
                reconstructed = Matrix(factorization.Q) * Matrix(factorization.R)
                residual = T(norm(permuted - reconstructed))
                relative_factorization_residual = _relative_residual(
                    residual, norm_value, one(T),
                )
            catch error
                residual_reason = "factorization residual unavailable: $(sprint(showerror, error))"
            end
        else
            residual_reason = "factorization residual dense guard exceeded: $(rows * columns) > $(policy.max_dense_entries)"
        end
        return SparseQRRankEstimate{T}(
            true, nothing, evaluation.point, policy, :suitesparse_qr,
            policy.scaling, rows, columns, length(retained), pivots,
            policy.relative_tolerance, threshold, proxy, norm_value,
            row_permutation, column_permutation,
            relative_factorization_residual, residual_reason,
            input_nonzeros, factor_nonzeros, fill_ratio,
            max_input_nonzeros, max_factor_nonzeros,
        )
    catch error
        return unavailable(sprint(showerror, error))
    end
end

"""
    iterative_right_nullspace_estimate(evaluation; iterations = 100,
                                       convergence_tolerance = 1e-8)

Use only sparse Jacobian--vector and transposed-Jacobian--vector products to
probe for one locally small-residual right direction. The returned direction is
a *candidate*: a small residual can be useful evidence of a possible gauge or
near-null mode, but neither convergence nor a small residual proves a
nullspace or establishes its dimension.

The iteration is a normalized inverse-free iteration on a shifted `J'J`.
Its deterministic initial direction makes reports reproducible, but callers
should use the dense SVD nullspace when it is available and a certified local
rank/nullity statement is needed.
"""
function iterative_right_nullspace_estimate(
    evaluation::NumericalEvaluation{T};
    iterations::Integer = 100,
    convergence_tolerance::Real = sqrt(eps(T)),
    matrix_norm::Symbol = :frobenius,
    operator::JacobianLinearOperator = jacobian_linear_operator(evaluation),
) where {T<:AbstractFloat}
    iterations > 0 || throw(ArgumentError("iterations must be positive"))
    tolerance = convert(T, convergence_tolerance)
    tolerance >= zero(T) ||
        throw(ArgumentError("convergence_tolerance must be nonnegative"))
    rows = length(evaluation.constraint_sources)
    columns = length(evaluation.point.variables)
    unavailable(reason) = IterativeNullspaceEstimate{T}(
        false, reason, evaluation.point, 0, false, operator.source, T[], nothing, nothing,
        nothing,
    )
    columns > 0 || return unavailable("Jacobian has no variable columns")
    operator.available || return unavailable(operator.reason)
    operator.point == evaluation.point || throw(ArgumentError(
        "Jacobian operator and evaluation points do not match",
    ))
    matrix = operator.assembled_matrix
    norm_value = T(_matrix_norm(matrix, matrix_norm))
    direction = T[sin(T(index)) for index in 1:columns]
    direction_norm = norm(direction)
    isfinite(direction_norm) && !iszero(direction_norm) ||
        return unavailable("could not construct a finite initial direction")
    direction ./= direction_norm

    # Estimate a safe upper scale for J'J with power products. Overestimating
    # only slows the iteration; underestimating can reverse large modes.
    probe = copy(direction)
    spectral_scale = zero(T)
    for _ in 1:min(20, Int(iterations))
        normal_product = jacobian_transpose_product(
            operator, jacobian_product(operator, probe),
        )
        product_norm = norm(normal_product)
        isfinite(product_norm) ||
            return unavailable("sparse Jacobian product became non-finite")
        spectral_scale = max(spectral_scale, product_norm)
        iszero(product_norm) && break
        probe = normal_product / product_norm
    end
    shift = max(T(4) * spectral_scale, eps(T))
    converged = false
    completed_iterations = 0
    for iteration in 1:Int(iterations)
        candidate = direction - jacobian_transpose_product(
            operator, jacobian_product(operator, direction),
        ) / shift
        candidate_norm = norm(candidate)
        isfinite(candidate_norm) && !iszero(candidate_norm) ||
            return unavailable("iterative nullspace direction became invalid")
        candidate ./= candidate_norm
        dot(candidate, direction) < zero(T) && (candidate .*= -one(T))
        completed_iterations = iteration
        if norm(candidate - direction) <= tolerance
            direction = candidate
            converged = true
            break
        end
        direction = candidate
    end
    residual = norm(jacobian_product(operator, direction))
    isfinite(residual) || return unavailable("candidate residual became non-finite")
    relative_residual = _relative_residual(residual, norm_value, norm(direction))
    return IterativeNullspaceEstimate{T}(
        true, nothing, evaluation.point, completed_iterations, converged,
        operator.source,
        direction, residual, norm_value, relative_residual,
    )
end

"""
    iterative_right_nullspace_subspace_estimate(evaluation, dimension; ...)

Use a block sparse-matvec iteration to probe `dimension` candidate right
directions associated with small local Jacobian residuals. The returned matrix
has orthonormal columns, and each residual is reported separately. This is an
opt-in numerical probe, not a rank estimate, nullity certificate, or physical
classification.
"""
function iterative_right_nullspace_subspace_estimate(
    evaluation::NumericalEvaluation{T},
    dimension::Integer;
    iterations::Integer = 100,
    convergence_tolerance::Real = sqrt(eps(T)),
    matrix_norm::Symbol = :frobenius,
    operator::JacobianLinearOperator = jacobian_linear_operator(evaluation),
) where {T<:AbstractFloat}
    dimension > 0 || throw(ArgumentError("dimension must be positive"))
    iterations > 0 || throw(ArgumentError("iterations must be positive"))
    tolerance = convert(T, convergence_tolerance)
    tolerance >= zero(T) ||
        throw(ArgumentError("convergence_tolerance must be nonnegative"))
    rows = length(evaluation.constraint_sources)
    columns = length(evaluation.point.variables)
    unavailable(reason) = IterativeNullspaceSubspaceEstimate{T}(
        false, reason, evaluation.point, Int(dimension), 0, false, operator.source,
        zeros(T, columns, 0), T[], nothing, T[], nothing,
    )
    columns > 0 || return unavailable("Jacobian has no variable columns")
    dimension <= columns ||
        throw(ArgumentError("dimension must not exceed the Jacobian column count"))
    operator.available || return unavailable(operator.reason)
    operator.point == evaluation.point || throw(ArgumentError(
        "Jacobian operator and evaluation points do not match",
    ))
    matrix = operator.assembled_matrix
    norm_value = T(_matrix_norm(matrix, matrix_norm))
    seed = T[
        sin(T(row * (column + 1))) + cos(T((row + 1) * column)) for
        row in 1:columns, column in 1:dimension
    ]
    directions = try
        Matrix(qr(seed).Q)[:, 1:dimension]
    catch error
        return unavailable("could not orthonormalize initial block: $(sprint(showerror, error))")
    end
    all(isfinite, directions) || return unavailable("initial block is non-finite")

    probe = view(directions, :, 1)
    spectral_scale = zero(T)
    for _ in 1:min(20, Int(iterations))
        normal_product = jacobian_transpose_product(
            operator, jacobian_product(operator, probe),
        )
        product_norm = norm(normal_product)
        isfinite(product_norm) ||
            return unavailable("sparse Jacobian product became non-finite")
        spectral_scale = max(spectral_scale, product_norm)
        iszero(product_norm) && break
        probe = normal_product / product_norm
    end
    shift = max(T(4) * spectral_scale, eps(T))
    completed_iterations = 0
    converged = false
    subspace_change = nothing
    for iteration in 1:Int(iterations)
        candidate = directions - _jacobian_transpose_products(
            operator, _jacobian_products(operator, directions),
        ) / shift
        candidate = try
            Matrix(qr(candidate).Q)[:, 1:dimension]
        catch error
            return unavailable("iterative candidate block became rank deficient: $(sprint(showerror, error))")
        end
        all(isfinite, candidate) || return unavailable("iterative candidate block became non-finite")
        for column in 1:dimension
            dot(candidate[:, column], directions[:, column]) < zero(T) &&
                (candidate[:, column] .*= -one(T))
        end
        subspace_change = norm(candidate * transpose(candidate) -
                               directions * transpose(directions))
        directions = candidate
        completed_iterations = iteration
        if subspace_change <= tolerance
            converged = true
            break
        end
    end
    residuals = T[norm(jacobian_product(operator, directions[:, column]))
        for column in 1:dimension]
    all(isfinite, residuals) || return unavailable("candidate residual became non-finite")
    relative_residuals = T[
        _relative_residual(residuals[column], norm_value, norm(view(directions, :, column)))
        for column in 1:dimension
    ]
    return IterativeNullspaceSubspaceEstimate{T}(
        true, nothing, evaluation.point, Int(dimension), completed_iterations,
        converged, operator.source, directions, residuals, norm_value, relative_residuals,
        subspace_change,
    )
end

"""
    iterative_left_nullspace_subspace_estimate(evaluation, dimension; ...)

Use a block sparse-matvec iteration to probe `dimension` candidate left
directions with small `J' * y` residuals. These directions can screen for
locally dependent constraint combinations at scale. They are not a rank
estimate, dependency certificate, IIS, or physical classification.
"""
function iterative_left_nullspace_subspace_estimate(
    evaluation::NumericalEvaluation{T},
    dimension::Integer;
    iterations::Integer = 100,
    convergence_tolerance::Real = sqrt(eps(T)),
    matrix_norm::Symbol = :frobenius,
    operator::JacobianLinearOperator = jacobian_linear_operator(evaluation),
) where {T<:AbstractFloat}
    dimension > 0 || throw(ArgumentError("dimension must be positive"))
    iterations > 0 || throw(ArgumentError("iterations must be positive"))
    tolerance = convert(T, convergence_tolerance)
    tolerance >= zero(T) ||
        throw(ArgumentError("convergence_tolerance must be nonnegative"))
    rows = length(evaluation.constraint_sources)
    unavailable(reason) = IterativeLeftNullspaceSubspaceEstimate{T}(
        false, reason, evaluation.point, Int(dimension), 0, false, operator.source,
        zeros(T, rows, 0), T[], nothing, T[], nothing,
    )
    rows > 0 || return unavailable("Jacobian has no constraint rows")
    dimension <= rows ||
        throw(ArgumentError("dimension must not exceed the Jacobian row count"))
    operator.available || return unavailable(operator.reason)
    operator.point == evaluation.point || throw(ArgumentError(
        "Jacobian operator and evaluation points do not match",
    ))
    matrix = operator.assembled_matrix
    norm_value = T(_matrix_norm(matrix, matrix_norm))
    seed = T[
        sin(T(row * (column + 1))) + cos(T((row + 1) * column)) for
        row in 1:rows, column in 1:dimension
    ]
    directions = try
        Matrix(qr(seed).Q)[:, 1:dimension]
    catch error
        return unavailable("could not orthonormalize initial block: $(sprint(showerror, error))")
    end
    all(isfinite, directions) || return unavailable("initial block is non-finite")

    probe = view(directions, :, 1)
    spectral_scale = zero(T)
    for _ in 1:min(20, Int(iterations))
        normal_product = jacobian_product(
            operator, jacobian_transpose_product(operator, probe),
        )
        product_norm = norm(normal_product)
        isfinite(product_norm) ||
            return unavailable("sparse transposed-Jacobian product became non-finite")
        spectral_scale = max(spectral_scale, product_norm)
        iszero(product_norm) && break
        probe = normal_product / product_norm
    end
    shift = max(T(4) * spectral_scale, eps(T))
    completed_iterations = 0
    converged = false
    subspace_change = nothing
    for iteration in 1:Int(iterations)
        candidate = directions - _jacobian_products(
            operator, _jacobian_transpose_products(operator, directions),
        ) / shift
        candidate = try
            Matrix(qr(candidate).Q)[:, 1:dimension]
        catch error
            return unavailable("iterative candidate block became rank deficient: $(sprint(showerror, error))")
        end
        all(isfinite, candidate) || return unavailable("iterative candidate block became non-finite")
        for column in 1:dimension
            dot(candidate[:, column], directions[:, column]) < zero(T) &&
                (candidate[:, column] .*= -one(T))
        end
        subspace_change = norm(candidate * transpose(candidate) -
                               directions * transpose(directions))
        directions = candidate
        completed_iterations = iteration
        if subspace_change <= tolerance
            converged = true
            break
        end
    end
    residuals = T[norm(jacobian_transpose_product(operator, directions[:, column]))
        for column in 1:dimension]
    all(isfinite, residuals) || return unavailable("candidate residual became non-finite")
    relative_residuals = T[
        _relative_residual(residuals[column], norm_value, norm(view(directions, :, column)))
        for column in 1:dimension
    ]
    return IterativeLeftNullspaceSubspaceEstimate{T}(
        true, nothing, evaluation.point, Int(dimension), completed_iterations,
        converged, operator.source, directions, residuals, norm_value, relative_residuals,
        subspace_change,
    )
end

"""
    iterative_jacobian_spectrum_estimate(evaluation; probe_dimension = 1, ...)

Return a sparse-matvec spectral-scale proxy from a normal-operator power
iteration together with residuals of one or more candidate small directions.
The reported spreads divide the former by the latter. They are deliberately
heuristic: neither side is a certified singular value, so this API must not be
used as a condition-number calculation.
"""
function iterative_jacobian_spectrum_estimate(
    evaluation::NumericalEvaluation{T};
    probe_dimension::Integer = 1,
    iterations::Integer = 100,
    convergence_tolerance::Real = sqrt(eps(T)),
    operator::JacobianLinearOperator = jacobian_linear_operator(evaluation),
) where {T<:AbstractFloat}
    iterations > 0 || throw(ArgumentError("iterations must be positive"))
    probe_dimension > 0 || throw(ArgumentError("probe_dimension must be positive"))
    columns = length(evaluation.point.variables)
    unavailable(reason) = IterativeJacobianSpectrumEstimate{T}(
        false, reason, evaluation.point, 0, operator.source, nothing, T[], T[], false,
    )
    columns > 0 || return unavailable("Jacobian has no variable columns")
    probe_dimension <= columns ||
        throw(ArgumentError("probe_dimension must not exceed the Jacobian column count"))
    operator.available || return unavailable(operator.reason)
    operator.point == evaluation.point || throw(ArgumentError(
        "Jacobian operator and evaluation points do not match",
    ))
    vector = T[sin(T(index)) for index in 1:columns]
    vector_norm = norm(vector)
    isfinite(vector_norm) && !iszero(vector_norm) ||
        return unavailable("could not construct a finite power-iteration seed")
    vector ./= vector_norm
    completed_iterations = 0
    for iteration in 1:Int(iterations)
        normal_product = jacobian_transpose_product(
            operator, jacobian_product(operator, vector),
        )
        product_norm = norm(normal_product)
        isfinite(product_norm) ||
            return unavailable("sparse normal-operator product became non-finite")
        completed_iterations = iteration
        iszero(product_norm) && break
        vector = normal_product / product_norm
    end
    normal_product = jacobian_transpose_product(
        operator, jacobian_product(operator, vector),
    )
    rayleigh = dot(vector, normal_product)
    isfinite(rayleigh) && rayleigh >= zero(T) ||
        return unavailable("power-iteration Rayleigh quotient became invalid")
    largest = sqrt(rayleigh)
    subspace = iterative_right_nullspace_subspace_estimate(
        evaluation,
        probe_dimension;
        iterations = iterations,
        convergence_tolerance = convergence_tolerance,
        operator = operator,
    )
    subspace.available || return unavailable(something(subspace.reason, "small-direction probe unavailable"))
    spreads = T[
        iszero(residual) ? T(Inf) : largest / residual for
        residual in subspace.residual_norms
    ]
    return IterativeJacobianSpectrumEstimate{T}(
        true,
        nothing,
        evaluation.point,
        completed_iterations,
        operator.source,
        largest,
        subspace.residual_norms,
        spreads,
        subspace.converged,
    )
end

function _gk_reorthogonalize!(
    vector::AbstractVector{T}, basis::AbstractMatrix{T}, columns::Integer,
) where {T<:AbstractFloat}
    columns <= 0 && return vector
    # Two modified Gram--Schmidt passes keep loss of orthogonality inspectable
    # without silently trusting the three-term recurrence in finite precision.
    for _ in 1:2, column in 1:Int(columns)
        vector .-= dot(view(basis, :, column), vector) .* view(basis, :, column)
    end
    return vector
end

function _gk_orthogonality_loss(basis::AbstractMatrix{T}) where {T<:AbstractFloat}
    size(basis, 2) == 0 && return zero(T)
    return T(opnorm(transpose(basis) * basis - I, Inf))
end

"""
    golub_kahan_ritz_estimate(evaluation; steps = 20, kwargs...)

Generate finite Golub--Kahan left and right Krylov bases using only Jacobian
and transposed-Jacobian products. Singular triplets are extracted from the
small projected matrix and lifted to model coordinates. Every triplet is
checked with direct `Jv - sigma*u` and `J'u - sigma*v` residuals.

This is a bounded projection probe. Its smallest Ritz value is not a certified
smallest singular value, and absence of a projected null candidate does not
establish full rank.
"""
function golub_kahan_ritz_estimate(
    evaluation::NumericalEvaluation{T};
    steps::Integer = 20,
    breakdown_tolerance::Real = sqrt(eps(T)),
    projection_relative_tolerance::Real =
        max(length(evaluation.constraint_sources), length(evaluation.point.variables), 1) * eps(T),
    matrix_norm::Symbol = :frobenius,
    seed::Union{Nothing,AbstractVector{<:Real}} = nothing,
    operator::JacobianLinearOperator = jacobian_linear_operator(evaluation),
) where {T<:AbstractFloat}
    steps > 0 || throw(ArgumentError("steps must be positive"))
    breakdown_tol = T(breakdown_tolerance)
    isfinite(breakdown_tol) && breakdown_tol >= zero(T) ||
        throw(ArgumentError("breakdown_tolerance must be finite and nonnegative"))
    projection_tol = T(projection_relative_tolerance)
    isfinite(projection_tol) && projection_tol >= zero(T) ||
        throw(ArgumentError(
            "projection_relative_tolerance must be finite and nonnegative",
        ))
    rows = length(evaluation.constraint_sources)
    columns = length(evaluation.point.variables)
    requested = Int(steps)
    unavailable(reason) = GolubKahanRitzEstimate{T}(
        false, String(reason), evaluation.point, requested, 0, operator.source,
        :unavailable, T[], T[], zeros(T, 0, 0), T[], zeros(T, rows, 0),
        zeros(T, columns, 0), T[], T[], T[], nothing, nothing, nothing,
        nothing, nothing, zeros(T, columns, 0), T[], T[],
    )
    rows > 0 || return unavailable("Jacobian has no constraint rows")
    columns > 0 || return unavailable("Jacobian has no variable columns")
    operator.available || return unavailable(something(operator.reason, "operator unavailable"))
    operator.point == evaluation.point || throw(ArgumentError(
        "Jacobian operator and evaluation points do not match",
    ))
    # An underdetermined problem may require one step beyond the row-space
    # dimension before the left recurrence exposes the remaining right-space
    # direction. Never request more than `rows + 1` orthogonal left recurrences.
    maximum_steps = min(requested, columns, rows + 1)
    norm_value = T(_matrix_norm(operator.assembled_matrix, matrix_norm))
    isfinite(norm_value) || return unavailable("Jacobian matrix norm is non-finite")

    left_basis = zeros(T, rows, maximum_steps)
    right_basis = zeros(T, columns, maximum_steps + 1)
    initial = isnothing(seed) ?
        T[sin(T(index)) + cos(T(2 * index)) for index in 1:columns] :
        T.(seed)
    length(initial) == columns || throw(DimensionMismatch(
        "Golub--Kahan seed has length $(length(initial)); expected $columns",
    ))
    all(isfinite, initial) || throw(ArgumentError(
        "Golub--Kahan seed must contain only finite values",
    ))
    seed_norm = norm(initial)
    isfinite(seed_norm) && !iszero(seed_norm) ||
        throw(ArgumentError("Golub--Kahan seed must have nonzero finite norm"))
    right_basis[:, 1] .= initial ./ seed_norm
    alphas = T[]
    betas = T[]
    completed = 0
    right_columns = 1
    breakdown = :none

    for step in 1:maximum_steps
        av = jacobian_product(operator, view(right_basis, :, step))
        candidate_left = copy(av)
        step > 1 && (candidate_left .-= betas[step - 1] .* view(left_basis, :, step - 1))
        _gk_reorthogonalize!(candidate_left, left_basis, step - 1)
        alpha = norm(candidate_left)
        threshold = breakdown_tol * max(one(T), norm(av), norm_value)
        if !isfinite(alpha)
            return unavailable("Golub--Kahan left recurrence became non-finite")
        elseif alpha <= threshold
            breakdown = :left_recurrence
            right_columns = step
            break
        end
        push!(alphas, alpha)
        left_basis[:, step] .= candidate_left ./ alpha
        completed = step
        right_columns = step

        atu = jacobian_transpose_product(operator, view(left_basis, :, step))
        candidate_right = atu .- alpha .* view(right_basis, :, step)
        _gk_reorthogonalize!(candidate_right, right_basis, step)
        beta = norm(candidate_right)
        threshold = breakdown_tol * max(one(T), norm(atu), norm_value)
        if !isfinite(beta)
            return unavailable("Golub--Kahan right recurrence became non-finite")
        elseif beta <= threshold
            breakdown = :right_recurrence
            break
        elseif step < maximum_steps
            push!(betas, beta)
            right_basis[:, step + 1] .= candidate_right ./ beta
            right_columns = step + 1
        end
    end

    U = left_basis[:, 1:completed]
    V = right_basis[:, 1:right_columns]
    AV = right_columns == 0 ? zeros(T, rows, 0) : _jacobian_products(operator, V)
    projection = transpose(U) * AV
    projection_residual = norm(AV - U * projection) / max(one(T), norm(AV))
    left_loss = _gk_orthogonality_loss(U)
    right_loss = _gk_orthogonality_loss(V)

    singular_values = T[]
    left_directions = zeros(T, rows, 0)
    right_directions = zeros(T, columns, 0)
    primal_residuals = T[]
    dual_residuals = T[]
    backward_errors = T[]
    rank_threshold = zero(T)
    projected_null_directions = zeros(T, columns, 0)
    projected_null_residuals = T[]
    projected_null_relative_residuals = T[]
    if right_columns > 0
        if completed == 0
            projected_null_directions = copy(V)
        else
            factor = svd(projection; full = true)
            singular_values = T.(factor.S)
            triplet_count = length(singular_values)
            left_directions = U * Matrix(factor.U[:, 1:triplet_count])
            right_directions = V * Matrix(factor.V[:, 1:triplet_count])
            for index in 1:triplet_count
                sigma = singular_values[index]
                primal = norm(jacobian_product(
                    operator, view(right_directions, :, index),
                ) - sigma .* view(left_directions, :, index))
                dual = norm(jacobian_transpose_product(
                    operator, view(left_directions, :, index),
                ) - sigma .* view(right_directions, :, index))
                push!(primal_residuals, primal)
                push!(dual_residuals, dual)
                push!(backward_errors,
                      hypot(primal, dual) / max(norm_value, sigma, eps(T)))
            end
            rank_threshold = projection_tol *
                (isempty(singular_values) ? one(T) : maximum(singular_values))
            projected_rank = count(value -> value > rank_threshold, singular_values)
            if projected_rank < right_columns
                projected_null_directions = V *
                    Matrix(factor.V[:, (projected_rank + 1):right_columns])
            end
        end
        for index in axes(projected_null_directions, 2)
            residual = norm(jacobian_product(
                operator, view(projected_null_directions, :, index),
            ))
            push!(projected_null_residuals, residual)
            push!(projected_null_relative_residuals,
                  _relative_residual(residual, norm_value,
                                     norm(view(projected_null_directions, :, index))))
        end
    end
    all(isfinite, vcat(primal_residuals, dual_residuals, backward_errors,
                       projected_null_residuals)) ||
        return unavailable("Golub--Kahan residual audit became non-finite")
    return GolubKahanRitzEstimate{T}(
        true, nothing, evaluation.point, requested, completed, operator.source,
        breakdown, alphas, betas, projection, singular_values,
        left_directions, right_directions, primal_residuals, dual_residuals,
        backward_errors, norm_value, projection_residual, left_loss, right_loss,
        rank_threshold, projected_null_directions, projected_null_residuals,
        projected_null_relative_residuals,
    )
end

function _golub_kahan_seed(::Type{T}, columns::Integer, seed_index::Integer) where {T<:AbstractFloat}
    k = Int(seed_index)
    return T[
        sin(T((k + 1) * index)) + cos(T((2 * k + 1) * index)) +
        T(0.5) * sin(T((k + 3) * (index + 1)))
        for index in 1:Int(columns)
    ]
end

function _candidate_basis(
    operator::JacobianLinearOperator{T},
    directions::Matrix{T},
    relative_tolerance::T,
) where {T<:AbstractFloat}
    columns = size(directions, 1)
    isempty(directions) && return (
        zeros(T, columns, 0), T[], T[], zero(T),
    )
    factor = svd(directions; full = false)
    values = T.(factor.S)
    threshold = relative_tolerance * maximum(values; init = zero(T))
    rank = count(value -> value > threshold, values)
    basis = rank == 0 ? zeros(T, columns, 0) : Matrix(factor.U[:, 1:rank])
    matrix_norm = T(_matrix_norm(operator.assembled_matrix, :frobenius))
    residuals = T[
        _relative_residual(
            norm(jacobian_product(operator, view(basis, :, index))),
            matrix_norm,
            norm(view(basis, :, index)),
        ) for index in axes(basis, 2)
    ]
    return basis, residuals, values, threshold
end

function _principal_cosines(left::AbstractMatrix{T}, right::AbstractMatrix{T}) where {T<:AbstractFloat}
    (size(left, 2) == 0 || size(right, 2) == 0) && return T[]
    left_basis = Matrix(qr(left).Q[:, 1:size(left, 2)])
    right_basis = Matrix(qr(right).Q[:, 1:size(right, 2)])
    return clamp.(T.(svdvals(transpose(left_basis) * right_basis)), zero(T), one(T))
end

"""
    multi_seed_golub_kahan_estimate(evaluation; seed_count = 4, steps = 20, kwargs...)

Run independent deterministic Golub--Kahan projections and consolidate only
projected-null candidates that pass a direct full-Jacobian residual test. The
result records cross-seed subspace agreement and a hard basis-storage guard.
It remains a candidate screen: an empty candidate span does not establish full
rank, and `candidate_span_rank` is not a nullity estimate.
"""
function multi_seed_golub_kahan_estimate(
    evaluation::NumericalEvaluation{T};
    seed_count::Integer = 4,
    steps::Integer = 20,
    residual_relative_tolerance::Real = sqrt(eps(T)),
    candidate_span_relative_tolerance::Real = sqrt(eps(T)),
    seed_agreement_threshold::Real = 0.98,
    max_basis_entries::Integer = 1_000_000,
    operator::JacobianLinearOperator = jacobian_linear_operator(evaluation),
    kwargs...,
) where {T<:AbstractFloat}
    seed_count > 0 || throw(ArgumentError("seed_count must be positive"))
    steps > 0 || throw(ArgumentError("steps must be positive"))
    max_basis_entries >= 0 || throw(ArgumentError(
        "max_basis_entries must be nonnegative",
    ))
    seed_count <= typemax(Int) || throw(ArgumentError("seed_count is too large"))
    steps <= typemax(Int) || throw(ArgumentError("steps is too large"))
    max_basis_entries <= typemax(Int) || throw(ArgumentError(
        "max_basis_entries is too large",
    ))
    residual_tolerance = T(residual_relative_tolerance)
    span_tolerance = T(candidate_span_relative_tolerance)
    agreement_threshold = T(seed_agreement_threshold)
    isfinite(residual_tolerance) && residual_tolerance >= zero(T) ||
        throw(ArgumentError("residual_relative_tolerance must be finite and nonnegative"))
    isfinite(span_tolerance) && span_tolerance >= zero(T) ||
        throw(ArgumentError("candidate_span_relative_tolerance must be finite and nonnegative"))
    isfinite(agreement_threshold) && zero(T) <= agreement_threshold <= one(T) ||
        throw(ArgumentError("seed_agreement_threshold must lie in [0, 1]"))

    rows = length(evaluation.constraint_sources)
    columns = length(evaluation.point.variables)
    requested_seeds = Int(seed_count)
    requested_steps = Int(steps)
    maximum_steps = min(requested_steps, columns, rows + 1)
    estimated_entries_wide = big(requested_seeds) *
        (big(rows) * maximum_steps + big(columns) * (maximum_steps + 1))
    estimated_entries = estimated_entries_wide > typemax(Int) ?
        typemax(Int) : Int(estimated_entries_wide)
    empty_estimates = GolubKahanRitzEstimate{T}[]
    unavailable(reason) = MultiSeedGolubKahanEstimate{T}(
        false, String(reason), evaluation.point, requested_seeds, 0,
        requested_steps, operator.source, residual_tolerance, span_tolerance,
        empty_estimates, Int[],
        zeros(T, columns, 0), T[], Int[], zeros(T, columns, 0), T[], 0,
        T[], zero(T), 0, 0, nothing, agreement_threshold,
        estimated_entries, Int(max_basis_entries),
    )
    operator.available || return unavailable(something(operator.reason, "operator unavailable"))
    estimated_entries_wide <= max_basis_entries || return unavailable(
        "estimated Golub--Kahan basis storage $estimated_entries_wide entries exceeds max_basis_entries=$(Int(max_basis_entries))",
    )

    estimates = GolubKahanRitzEstimate{T}[]
    counts = Int[]
    retained = Matrix{T}[]
    retained_residuals = T[]
    sources = Int[]
    per_seed = Matrix{T}[]
    for seed_index in 1:requested_seeds
        estimate = golub_kahan_ritz_estimate(
            evaluation;
            steps = requested_steps,
            seed = _golub_kahan_seed(T, columns, seed_index),
            operator = operator,
            kwargs...,
        )
        push!(estimates, estimate)
        if !estimate.available
            push!(counts, 0)
            push!(per_seed, zeros(T, columns, 0))
            continue
        end
        selected = findall(
            value -> value <= residual_tolerance,
            estimate.projected_right_null_relative_residual_norms,
        )
        directions = estimate.projected_right_null_directions[:, selected]
        push!(counts, length(selected))
        push!(per_seed, directions)
        isempty(selected) || push!(retained, directions)
        append!(retained_residuals,
                estimate.projected_right_null_relative_residual_norms[selected])
        append!(sources, fill(seed_index, length(selected)))
    end
    available_count = count(estimate -> estimate.available, estimates)
    available_count > 0 || return unavailable(
        join(unique(something(estimate.reason, "projection unavailable") for estimate in estimates), "; "),
    )
    retained_matrix = isempty(retained) ? zeros(T, columns, 0) : hcat(retained...)
    basis, basis_residuals, span_values, span_threshold = _candidate_basis(
        operator, retained_matrix, span_tolerance,
    )

    comparable_pairs = 0
    agreeing_pairs = 0
    minimum_cosine = nothing
    for left_index in 1:(requested_seeds - 1), right_index in (left_index + 1):requested_seeds
        left = per_seed[left_index]
        right = per_seed[right_index]
        (size(left, 2) == 0 || size(right, 2) == 0) && continue
        comparable_pairs += 1
        cosines = _principal_cosines(left, right)
        pair_minimum = isempty(cosines) ? zero(T) : minimum(cosines)
        minimum_cosine = isnothing(minimum_cosine) ? pair_minimum :
            min(minimum_cosine, pair_minimum)
        size(left, 2) == size(right, 2) &&
            pair_minimum >= agreement_threshold && (agreeing_pairs += 1)
    end
    return MultiSeedGolubKahanEstimate{T}(
        true, nothing, evaluation.point, requested_seeds, available_count,
        requested_steps, operator.source, residual_tolerance, span_tolerance,
        estimates, counts, retained_matrix,
        retained_residuals, sources, basis, basis_residuals, size(basis, 2),
        span_values, span_threshold, comparable_pairs, agreeing_pairs,
        minimum_cosine, agreement_threshold, estimated_entries,
        Int(max_basis_entries),
    )
end

function _orthonormal_trial_basis(
    trial::AbstractMatrix{T}, relative_tolerance::T,
) where {T<:AbstractFloat}
    size(trial, 2) == 0 && return zeros(T, size(trial, 1), 0)
    factor = svd(trial; full = false)
    threshold = relative_tolerance * maximum(factor.S; init = zero(T))
    rank = count(value -> value > threshold, factor.S)
    return rank == 0 ? zeros(T, size(trial, 1), 0) :
        Matrix(factor.U[:, 1:rank])
end

function _smallest_candidate_audit(
    operator::JacobianLinearOperator{T},
    directions::AbstractMatrix{T},
    matrix_norm::T,
) where {T<:AbstractFloat}
    dimension = size(directions, 2)
    left = zeros(T, operator.rows, dimension)
    singular_values = zeros(T, dimension)
    operator_residuals = zeros(T, dimension)
    relative_operator_residuals = zeros(T, dimension)
    normal_residuals = zeros(T, dimension)
    relative_normal_residuals = zeros(T, dimension)
    backward_errors = zeros(T, dimension)
    normal_scale = max(matrix_norm^2, eps(T))
    for index in 1:dimension
        direction = view(directions, :, index)
        av = jacobian_product(operator, direction)
        sigma = norm(av)
        singular_values[index] = sigma
        operator_residuals[index] = sigma
        relative_operator_residuals[index] = _relative_residual(
            sigma, matrix_norm, norm(direction),
        )
        normal_product = jacobian_transpose_product(operator, av)
        normal_residual = norm(normal_product - sigma^2 .* direction)
        normal_residuals[index] = normal_residual
        relative_normal_residuals[index] = normal_residual /
            max(normal_scale, sigma^2, eps(T))
        if sigma > eps(T) * max(one(T), matrix_norm)
            left[:, index] .= av ./ sigma
            dual_residual = norm(
                jacobian_transpose_product(operator, view(left, :, index)) -
                sigma .* direction,
            )
            backward_errors[index] = dual_residual /
                max(matrix_norm, sigma, eps(T))
        else
            # A near-null right direction has no stable associated left
            # singular vector. Its directly scaled J*v residual is the useful
            # candidate evidence.
            backward_errors[index] = relative_operator_residuals[index]
        end
    end
    return (
        left, singular_values, operator_residuals, relative_operator_residuals,
        normal_residuals, relative_normal_residuals, backward_errors,
    )
end

"""
    restarted_smallest_singular_candidates(evaluation; dimension = 1, kwargs...)

Track a candidate smallest right-singular subspace using restarted locally
optimal Rayleigh--Ritz steps on a matrix-free normal operator. Each cycle uses
only `J*v` and `J'*u`, retains singular-value, normal-residual, backward-error,
and principal-angle histories, and enforces an explicit trial-basis work guard.

This method does not form `J'J`, but its spectrum is still squared. Convergence
therefore establishes only a stationary candidate subspace for the requested
finite-precision policy; it is not a numerical-rank certificate.
"""
function restarted_smallest_singular_candidates(
    evaluation::NumericalEvaluation{T};
    dimension::Integer = 1,
    iterations::Integer = 50,
    minimum_iterations::Integer = 2,
    convergence_tolerance::Real = sqrt(eps(T)),
    subspace_alignment_threshold::Real = 0.999,
    trial_basis_relative_tolerance::Real = 10 * eps(T),
    max_basis_entries::Integer = 1_000_000,
    initial_directions::Union{Nothing,AbstractMatrix{<:Real}} = nothing,
    matrix_norm::Symbol = :frobenius,
    operator::JacobianLinearOperator = jacobian_linear_operator(evaluation),
) where {T<:AbstractFloat}
    dimension > 0 || throw(ArgumentError("dimension must be positive"))
    iterations > 0 || throw(ArgumentError("iterations must be positive"))
    minimum_iterations > 0 || throw(ArgumentError(
        "minimum_iterations must be positive",
    ))
    minimum_iterations <= iterations || throw(ArgumentError(
        "minimum_iterations must not exceed iterations",
    ))
    max_basis_entries >= 0 || throw(ArgumentError(
        "max_basis_entries must be nonnegative",
    ))
    for (name, value) in (
        ("dimension", dimension), ("iterations", iterations),
        ("minimum_iterations", minimum_iterations),
        ("max_basis_entries", max_basis_entries),
    )
        value <= typemax(Int) || throw(ArgumentError("$name is too large"))
    end
    convergence_tol = T(convergence_tolerance)
    alignment_threshold = T(subspace_alignment_threshold)
    basis_tolerance = T(trial_basis_relative_tolerance)
    isfinite(convergence_tol) && convergence_tol >= zero(T) ||
        throw(ArgumentError("convergence_tolerance must be finite and nonnegative"))
    isfinite(alignment_threshold) && zero(T) <= alignment_threshold <= one(T) ||
        throw(ArgumentError("subspace_alignment_threshold must lie in [0, 1]"))
    isfinite(basis_tolerance) && basis_tolerance >= zero(T) ||
        throw(ArgumentError("trial_basis_relative_tolerance must be finite and nonnegative"))

    rows = length(evaluation.constraint_sources)
    columns = length(evaluation.point.variables)
    requested_dimension = Int(dimension)
    requested_iterations = Int(iterations)
    minimum_iteration_count = Int(minimum_iterations)
    requested_dimension <= columns || throw(ArgumentError(
        "dimension $requested_dimension exceeds the $columns Jacobian columns",
    ))
    estimated_entries_wide = big(columns) * (6 * requested_dimension) +
        big(rows) * (3 * requested_dimension) +
        big(3) * requested_dimension * requested_iterations
    estimated_entries = estimated_entries_wide > typemax(Int) ?
        typemax(Int) : Int(estimated_entries_wide)
    empty_history = zeros(T, requested_dimension, 0)
    unavailable(reason) = RestartedSmallestSingularCandidateEstimate{T}(
        false, String(reason), evaluation.point, requested_dimension,
        requested_iterations, 0, minimum_iteration_count, false, operator.source, :unavailable,
        empty_history, empty_history, empty_history,
        Union{Nothing,T}[], zeros(T, columns, 0), zeros(T, rows, 0),
        T[], T[], T[], T[], T[], T[], nothing, nothing, convergence_tol,
        alignment_threshold, basis_tolerance, estimated_entries,
        Int(max_basis_entries),
    )
    rows > 0 || return unavailable("Jacobian has no constraint rows")
    columns > 0 || return unavailable("Jacobian has no variable columns")
    operator.available || return unavailable(something(operator.reason, "operator unavailable"))
    operator.point == evaluation.point || throw(ArgumentError(
        "Jacobian operator and evaluation points do not match",
    ))
    estimated_entries_wide <= max_basis_entries || return unavailable(
        "estimated restarted trial storage $estimated_entries_wide entries exceeds max_basis_entries=$(Int(max_basis_entries))",
    )
    norm_value = T(_matrix_norm(operator.assembled_matrix, matrix_norm))
    isfinite(norm_value) || return unavailable("Jacobian matrix norm is non-finite")

    initial = if isnothing(initial_directions)
        hcat((
            _golub_kahan_seed(T, columns, seed_index)
            for seed_index in 1:requested_dimension
        )...)
    else
        size(initial_directions) == (columns, requested_dimension) ||
            throw(DimensionMismatch(
                "initial_directions has size $(size(initial_directions)); expected ($columns, $requested_dimension)",
            ))
        T.(initial_directions)
    end
    all(isfinite, initial) || throw(ArgumentError(
        "initial_directions must contain only finite values",
    ))
    X = _orthonormal_trial_basis(initial, basis_tolerance)
    size(X, 2) == requested_dimension || throw(ArgumentError(
        "initial_directions do not span the requested dimension",
    ))
    previous_search = zeros(T, columns, 0)
    previous_directions = nothing
    singular_histories = Vector{Vector{T}}()
    normal_histories = Vector{Vector{T}}()
    backward_histories = Vector{Vector{T}}()
    alignments = Union{Nothing,T}[]
    converged = false
    breakdown = :iteration_limit
    completed = 0
    final_audit = nothing

    for iteration in 1:requested_iterations
        AX = _jacobian_products(operator, X)
        normal_products = hcat((
            jacobian_transpose_product(operator, view(AX, :, index))
            for index in axes(AX, 2)
        )...)
        projected = Symmetric(
            (transpose(X) * normal_products +
             transpose(normal_products) * X) ./ 2,
        )
        factor = eigen(projected)
        order = sortperm(factor.values)
        rotation = Matrix(factor.vectors[:, order])
        X = X * rotation
        audit = _smallest_candidate_audit(operator, X, norm_value)
        final_audit = audit
        push!(singular_histories, copy(audit[2]))
        push!(normal_histories, copy(audit[6]))
        push!(backward_histories, copy(audit[7]))
        alignment = if isnothing(previous_directions)
            nothing
        else
            cosines = _principal_cosines(previous_directions, X)
            isempty(cosines) ? zero(T) : minimum(cosines)
        end
        push!(alignments, alignment)
        completed = iteration
        if iteration >= minimum_iteration_count &&
           maximum(audit[6]; init = zero(T)) <= convergence_tol &&
           !isnothing(alignment) && alignment >= alignment_threshold
            converged = true
            breakdown = :converged
            break
        end
        iteration == requested_iterations && break
        previous_directions = copy(X)

        residual = hcat((
            jacobian_transpose_product(
                operator, jacobian_product(operator, view(X, :, index)),
            ) - audit[2][index]^2 .* view(X, :, index)
            for index in axes(X, 2)
        )...)
        trial = hcat(X, residual, previous_search)
        basis = _orthonormal_trial_basis(trial, basis_tolerance)
        if size(basis, 2) <= requested_dimension
            if maximum(audit[6]; init = zero(T)) <= convergence_tol
                converged = true
                breakdown = :exact_invariant_subspace
            else
                breakdown = :trial_subspace_stagnation
            end
            break
        end
        AB = _jacobian_products(operator, basis)
        local_factor = eigen(Symmetric(transpose(AB) * AB))
        local_order = sortperm(local_factor.values)
        selected = local_order[1:requested_dimension]
        next_directions = basis * Matrix(local_factor.vectors[:, selected])
        previous_search = next_directions - X * (transpose(X) * next_directions)
        next_basis = _orthonormal_trial_basis(next_directions, basis_tolerance)
        size(next_basis, 2) == requested_dimension || begin
            breakdown = :candidate_subspace_rank_loss
            break
        end
        X = next_basis
    end

    isnothing(final_audit) && return unavailable(
        "restarted candidate audit did not complete",
    )
    singular_history = isempty(singular_histories) ? empty_history :
        hcat(singular_histories...)
    normal_history = isempty(normal_histories) ? empty_history :
        hcat(normal_histories...)
    backward_history = isempty(backward_histories) ? empty_history :
        hcat(backward_histories...)
    return RestartedSmallestSingularCandidateEstimate{T}(
        true, nothing, evaluation.point, requested_dimension,
        requested_iterations, completed, minimum_iteration_count, converged, operator.source,
        breakdown, singular_history, normal_history, backward_history,
        alignments, X, final_audit[1], final_audit[2], final_audit[3],
        final_audit[4], final_audit[5], final_audit[6], final_audit[7],
        norm_value, _gk_orthogonality_loss(X), convergence_tol,
        alignment_threshold, basis_tolerance, estimated_entries,
        Int(max_basis_entries),
    )
end

"""
    restarted_smallest_singular_dense_calibration(evaluation; kwargs...)

Compare the restarted candidate subspace with a guarded dense SVD in original
Jacobian coordinates. The comparison is intended for a small adversarial
oracle corpus and is unavailable when the dense-entry guard is exceeded.
"""
function _target_relative_singular_value_errors(
    candidate_values::AbstractVector{T},
    dense_values::AbstractVector{T},
    global_scale::T,
) where {T<:AbstractFloat}
    floor = eps(T) * max(global_scale, one(T))
    denominators = all(iszero, dense_values) ?
        fill(max(global_scale, one(T)), length(dense_values)) :
        max.(abs.(dense_values), floor)
    return abs.(candidate_values - dense_values) ./ denominators
end

function _dense_target_numerically_resolved(
    dense_values::AbstractVector{T},
    global_scale::T,
    rows::Int,
    columns::Int,
) where {T<:AbstractFloat}
    all(iszero, dense_values) && return true
    resolution_floor = eps(T) * max(global_scale, one(T)) * max(rows, columns)
    return minimum(abs, dense_values; init = T(Inf)) > resolution_floor
end

function _dense_target_subspace_unique(
    sorted_values::AbstractVector{T},
    requested_dimension::Int,
    columns::Int,
    relative_tolerance::T,
    global_scale::T,
) where {T<:AbstractFloat}
    requested_dimension == columns && return true
    lower = sorted_values[requested_dimension]
    upper = sorted_values[requested_dimension + 1]
    local_scale = max(abs(lower), abs(upper), eps(T) * max(global_scale, one(T)))
    return abs(upper - lower) > relative_tolerance * local_scale
end

function restarted_smallest_singular_dense_calibration(
    evaluation::NumericalEvaluation{T};
    dimension::Integer = 1,
    dense_max_entries::Integer = 4_000_000,
    singular_value_relative_tolerance::Real = 1.0e-6,
    subspace_alignment_threshold::Real = 0.98,
    candidate_subspace_alignment_threshold::Real =
        subspace_alignment_threshold,
    kwargs...,
) where {T<:AbstractFloat}
    dense_max_entries >= 0 || throw(ArgumentError(
        "dense_max_entries must be nonnegative",
    ))
    dense_max_entries <= typemax(Int) || throw(ArgumentError(
        "dense_max_entries is too large",
    ))
    value_tolerance = T(singular_value_relative_tolerance)
    alignment_threshold = T(subspace_alignment_threshold)
    isfinite(value_tolerance) && value_tolerance >= zero(T) ||
        throw(ArgumentError(
            "singular_value_relative_tolerance must be finite and nonnegative",
        ))
    isfinite(alignment_threshold) && zero(T) <= alignment_threshold <= one(T) ||
        throw(ArgumentError("subspace_alignment_threshold must lie in [0, 1]"))
    estimate = restarted_smallest_singular_candidates(
        evaluation; dimension = dimension,
        subspace_alignment_threshold =
            candidate_subspace_alignment_threshold,
        kwargs...,
    )
    requested_dimension = Int(dimension)
    rows = length(evaluation.constraint_sources)
    columns = length(evaluation.point.variables)
    unavailable(reason) = RestartedSmallestSingularDenseCalibration{T}(
        false, String(reason), evaluation.point, :unavailable, estimate, T[],
        zeros(T, columns, 0), T[], nothing, false, false, value_tolerance,
        alignment_threshold, Int(dense_max_entries),
    )
    estimate.available || return unavailable(
        "candidate estimate unavailable: $(something(estimate.reason, "unknown reason"))",
    )
    big(rows) * columns <= dense_max_entries || return unavailable(
        "dense Jacobian would contain $(big(rows) * columns) entries, exceeding guard $(Int(dense_max_entries))",
    )
    incomplete_rows = findall(
        method -> method in _JACOBIAN_INCOMPLETE_METHODS,
        evaluation.jacobian_row_methods,
    )
    isempty(incomplete_rows) || return unavailable(
        "Jacobian rows $(join(incomplete_rows, ',')) are incomplete",
    )
    matrix = _combined_jacobian_matrix(evaluation)
    all(isfinite, matrix) || return unavailable(
        "Jacobian contains non-finite combined entries",
    )
    factor = svd(matrix; full = true)
    all_values = vcat(T.(factor.S), zeros(T, columns - length(factor.S)))
    order = sortperm(all_values)
    selected = order[1:requested_dimension]
    dense_values = all_values[selected]
    dense_directions = Matrix(factor.V[:, selected])
    candidate_order = sortperm(estimate.singular_values)
    candidate_values = estimate.singular_values[candidate_order]
    candidate_directions = estimate.directions[:, candidate_order]
    scale = max(maximum(T.(factor.S); init = zero(T)), eps(T))
    sorted_dense_values = sort(all_values)
    target_subspace_unique = _dense_target_subspace_unique(
        sorted_dense_values, requested_dimension, columns, value_tolerance,
        scale,
    )
    relative_errors = _target_relative_singular_value_errors(
        candidate_values, dense_values, scale,
    )
    target_numerically_resolved = _dense_target_numerically_resolved(
        dense_values, scale, rows, columns,
    )
    cosines = _principal_cosines(dense_directions, candidate_directions)
    minimum_cosine = isempty(cosines) ? nothing : minimum(cosines)
    relation = if !estimate.converged
        :candidate_unconverged
    elseif !target_numerically_resolved
        :dense_target_numerically_unresolved
    elseif maximum(relative_errors; init = zero(T)) > value_tolerance
        :singular_value_disagreement
    elseif target_subspace_unique &&
           something(minimum_cosine, zero(T)) < alignment_threshold
        :subspace_disagreement
    elseif !target_subspace_unique
        :agreement_nonunique_subspace
    else
        :agreement
    end
    return RestartedSmallestSingularDenseCalibration{T}(
        true, nothing, evaluation.point, relation, estimate, dense_values,
        dense_directions, relative_errors, minimum_cosine,
        target_subspace_unique, target_numerically_resolved, value_tolerance,
        alignment_threshold, Int(dense_max_entries),
    )
end

function _golub_kahan_trial_space(
    evaluation::NumericalEvaluation{T},
    operator::JacobianLinearOperator{T},
    seeds::AbstractVector{<:AbstractVector{<:Real}},
    steps::Int,
    basis_tolerance::T,
) where {T<:AbstractFloat}
    spaces = Matrix{T}[]
    for seed in seeds
        estimate = golub_kahan_ritz_estimate(
            evaluation; steps = steps, seed = seed, operator = operator,
        )
        estimate.available || return nothing, estimate.reason
        space = hcat(
            estimate.right_directions,
            estimate.projected_right_null_directions,
        )
        size(space, 2) == 0 || push!(spaces, space)
    end
    isempty(spaces) && return nothing, "Golub--Kahan seeds generated no right trial space"
    basis = _orthonormal_trial_basis(hcat(spaces...), basis_tolerance)
    return basis, nothing
end

function _harmonic_zero_target_extract(
    operator::JacobianLinearOperator{T},
    basis::Matrix{T},
    retained_dimension::Int,
    metric_tolerance::T,
    matrix_norm::T,
) where {T<:AbstractFloat}
    AB = _jacobian_products(operator, basis)
    normal_products = hcat((
        jacobian_transpose_product(operator, view(AB, :, index))
        for index in axes(AB, 2)
    )...)
    metric_matrix = transpose(AB) * AB
    metric = Symmetric((metric_matrix + transpose(metric_matrix)) ./ 2)
    squared_metric_matrix = transpose(normal_products) * normal_products
    squared_metric = Symmetric(
        (squared_metric_matrix + transpose(squared_metric_matrix)) ./ 2,
    )
    metric_factor = eigen(metric)
    metric_values = max.(T.(metric_factor.values), zero(T))
    metric_scale = maximum(metric_values; init = zero(T))
    threshold = metric_tolerance * metric_scale
    positive = findall(value -> value > threshold, metric_values)
    null_indices = findall(value -> value <= threshold, metric_values)
    candidates = Matrix{T}[]
    harmonic_values = T[]
    if !isempty(null_indices)
        push!(candidates, basis * Matrix(metric_factor.vectors[:, null_indices]))
        append!(harmonic_values, zeros(T, length(null_indices)))
    end
    if !isempty(positive)
        transform = Matrix(metric_factor.vectors[:, positive]) *
            Diagonal(inv.(sqrt.(metric_values[positive])))
        harmonic_projection = Symmetric(
            transpose(transform) * Matrix(squared_metric) * transform,
        )
        harmonic_factor = eigen(harmonic_projection)
        order = sortperm(harmonic_factor.values)
        positive_vectors = transform * Matrix(harmonic_factor.vectors[:, order])
        push!(candidates, basis * positive_vectors)
        append!(harmonic_values,
                sqrt.(max.(T.(harmonic_factor.values[order]), zero(T))))
    end
    directions = isempty(candidates) ? zeros(T, size(basis, 1), 0) :
        hcat(candidates...)
    # Do not orthogonalize the harmonic Ritz vectors as a block here. A block
    # SVD would rotate candidates belonging to distinct projected values and
    # sever the link between each direction, its harmonic value, and its direct
    # singular-triplet audit. Individual normalization preserves that evidence.
    valid = Int[]
    for index in axes(directions, 2)
        direction_norm = norm(view(directions, :, index))
        if isfinite(direction_norm) && direction_norm > eps(T)
            directions[:, index] ./= direction_norm
            push!(valid, index)
        end
    end
    directions = directions[:, valid]
    harmonic_values = harmonic_values[valid]
    audit = _smallest_candidate_audit(operator, directions, matrix_norm)
    order = sortperm(audit[2])
    keep = min(retained_dimension, length(order))
    selected = order[1:keep]
    directions = directions[:, selected]
    harmonic_values = harmonic_values[selected]
    # Recompute after the final orthogonal selection so every retained column's
    # direct evidence matches the returned direction exactly.
    audit = _smallest_candidate_audit(operator, directions, matrix_norm)
    metric_rank = length(positive)
    metric_condition = isempty(positive) ? nothing :
        maximum(metric_values[positive]) / minimum(metric_values[positive])
    return directions, harmonic_values, audit, metric_rank, metric_condition
end

"""
    harmonic_golub_kahan_candidates(evaluation; dimension = 1, kwargs...)

Use thick-restarted Golub--Kahan trial spaces and a zero-target harmonic
generalized projection to track candidate smallest singular directions. The
method retains direct singular-triplet audits and refuses convergence without
residual, value-history, and principal-angle stability.
"""
function harmonic_golub_kahan_candidates(
    evaluation::NumericalEvaluation{T};
    dimension::Integer = 1,
    steps_per_seed::Integer = 6,
    cycles::Integer = 8,
    retained_dimension::Integer = max(Int(dimension) + 1, 2),
    minimum_cycles::Integer = 2,
    convergence_tolerance::Real = sqrt(eps(T)),
    value_change_tolerance::Real = sqrt(eps(T)),
    subspace_alignment_threshold::Real = 0.999,
    projected_metric_relative_tolerance::Real = 10 * eps(T),
    trial_basis_relative_tolerance::Real = 10 * eps(T),
    max_basis_entries::Integer = 1_000_000,
    initial_directions::Union{Nothing,AbstractMatrix{<:Real}} = nothing,
    matrix_norm::Symbol = :frobenius,
    operator::JacobianLinearOperator = jacobian_linear_operator(evaluation),
) where {T<:AbstractFloat}
    for (name, value) in (
        ("dimension", dimension), ("steps_per_seed", steps_per_seed),
        ("cycles", cycles), ("retained_dimension", retained_dimension),
        ("minimum_cycles", minimum_cycles),
    )
        value > 0 || throw(ArgumentError("$name must be positive"))
        value <= typemax(Int) || throw(ArgumentError("$name is too large"))
    end
    retained_dimension >= dimension || throw(ArgumentError(
        "retained_dimension must be at least dimension",
    ))
    minimum_cycles <= cycles || throw(ArgumentError(
        "minimum_cycles must not exceed cycles",
    ))
    max_basis_entries >= 0 || throw(ArgumentError(
        "max_basis_entries must be nonnegative",
    ))
    max_basis_entries <= typemax(Int) || throw(ArgumentError(
        "max_basis_entries is too large",
    ))
    requested_dimension = Int(dimension)
    steps = Int(steps_per_seed)
    requested_cycles = Int(cycles)
    retained = Int(retained_dimension)
    minimum_cycle_count = Int(minimum_cycles)
    convergence_tol = T(convergence_tolerance)
    value_tolerance = T(value_change_tolerance)
    alignment_threshold = T(subspace_alignment_threshold)
    metric_tolerance = T(projected_metric_relative_tolerance)
    basis_tolerance = T(trial_basis_relative_tolerance)
    for (name, value) in (
        ("convergence_tolerance", convergence_tol),
        ("value_change_tolerance", value_tolerance),
        ("projected_metric_relative_tolerance", metric_tolerance),
        ("trial_basis_relative_tolerance", basis_tolerance),
    )
        isfinite(value) && value >= zero(T) || throw(ArgumentError(
            "$name must be finite and nonnegative",
        ))
    end
    isfinite(alignment_threshold) && zero(T) <= alignment_threshold <= one(T) ||
        throw(ArgumentError("subspace_alignment_threshold must lie in [0, 1]"))
    rows = length(evaluation.constraint_sources)
    columns = length(evaluation.point.variables)
    requested_dimension <= columns || throw(ArgumentError(
        "dimension $requested_dimension exceeds the $columns Jacobian columns",
    ))
    retained = min(retained, columns)
    estimated_entries_wide =
        big(retained) * steps * (big(rows) + columns) +
        big(retained) * (big(rows) + 4 * columns) +
        big(3) * requested_dimension * requested_cycles
    estimated_entries = estimated_entries_wide > typemax(Int) ?
        typemax(Int) : Int(estimated_entries_wide)
    empty_history = zeros(T, requested_dimension, 0)
    unavailable(reason) = HarmonicGolubKahanCandidateEstimate{T}(
        false, String(reason), evaluation.point, requested_dimension, steps,
        requested_cycles, 0, retained, minimum_cycle_count, false,
        operator.source, :unavailable, Int[], Int[], Union{Nothing,T}[],
        empty_history, empty_history, empty_history, Union{Nothing,T}[],
        Union{Nothing,T}[], zeros(T, columns, 0), zeros(T, rows, 0), T[],
        T[], T[], T[], T[], nothing, nothing, convergence_tol,
        value_tolerance, alignment_threshold, metric_tolerance,
        basis_tolerance, estimated_entries, Int(max_basis_entries),
    )
    rows > 0 || return unavailable("Jacobian has no constraint rows")
    columns > 0 || return unavailable("Jacobian has no variable columns")
    operator.available || return unavailable(something(operator.reason, "operator unavailable"))
    operator.point == evaluation.point || throw(ArgumentError(
        "Jacobian operator and evaluation points do not match",
    ))
    estimated_entries_wide <= max_basis_entries || return unavailable(
        "estimated harmonic Golub--Kahan storage $estimated_entries_wide entries exceeds max_basis_entries=$(Int(max_basis_entries))",
    )
    norm_value = T(_matrix_norm(operator.assembled_matrix, matrix_norm))
    isfinite(norm_value) || return unavailable("Jacobian matrix norm is non-finite")

    seeds = if isnothing(initial_directions)
        [
            _golub_kahan_seed(T, columns, seed_index)
            for seed_index in 1:requested_dimension
        ]
    else
        size(initial_directions, 1) == columns || throw(DimensionMismatch(
            "initial_directions has $(size(initial_directions, 1)) rows; expected $columns",
        ))
        size(initial_directions, 2) >= requested_dimension || throw(ArgumentError(
            "initial_directions must contain at least $requested_dimension columns",
        ))
        converted = T.(initial_directions)
        all(isfinite, converted) || throw(ArgumentError(
            "initial_directions must contain only finite values",
        ))
        [copy(view(converted, :, index)) for index in axes(converted, 2)]
    end
    trial_dimensions = Int[]
    metric_ranks = Int[]
    metric_conditions = Union{Nothing,T}[]
    harmonic_histories = Vector{Vector{T}}()
    singular_histories = Vector{Vector{T}}()
    backward_histories = Vector{Vector{T}}()
    alignments = Union{Nothing,T}[]
    value_changes = Union{Nothing,T}[]
    previous_directions = nothing
    previous_values = nothing
    completed = 0
    converged = false
    breakdown = :cycle_limit
    final_directions = zeros(T, columns, 0)
    final_harmonic = T[]
    final_audit = nothing

    for cycle in 1:requested_cycles
        basis, reason = _golub_kahan_trial_space(
            evaluation, operator, seeds, steps, basis_tolerance,
        )
        isnothing(basis) && return unavailable(something(reason, "trial space unavailable"))
        if size(basis, 2) < requested_dimension
            breakdown = :trial_subspace_rank_loss
            break
        end
        directions, harmonic_values, audit, metric_rank, metric_condition =
            _harmonic_zero_target_extract(
                operator, basis, retained, metric_tolerance, norm_value,
            )
        if size(directions, 2) < requested_dimension
            breakdown = :harmonic_candidate_rank_loss
            break
        end
        requested_directions = directions[:, 1:requested_dimension]
        requested_audit = _smallest_candidate_audit(
            operator, requested_directions, norm_value,
        )
        requested_harmonic = harmonic_values[1:requested_dimension]
        push!(trial_dimensions, size(basis, 2))
        push!(metric_ranks, metric_rank)
        push!(metric_conditions, metric_condition)
        push!(harmonic_histories, copy(requested_harmonic))
        push!(singular_histories, copy(requested_audit[2]))
        push!(backward_histories, copy(requested_audit[7]))
        alignment = if isnothing(previous_directions)
            nothing
        else
            cosines = _principal_cosines(
                previous_directions, requested_directions,
            )
            isempty(cosines) ? zero(T) : minimum(cosines)
        end
        value_change = if isnothing(previous_values)
            nothing
        else
            maximum(abs.(requested_audit[2] - previous_values); init = zero(T)) /
                max(norm_value, maximum(requested_audit[2]; init = zero(T)), eps(T))
        end
        push!(alignments, alignment)
        push!(value_changes, value_change)
        completed = cycle
        final_directions = requested_directions
        final_harmonic = requested_harmonic
        final_audit = requested_audit
        # At a true or numerically resolved null direction the normalized left
        # singular vector is undefined, so the two-sided triplet backward error
        # can be large even when J*v is at roundoff. Accept the smaller of the
        # direct null residual and triplet audit as the per-direction stopping
        # measure; both remain exposed separately in the returned evidence.
        convergence_errors = min.(requested_audit[4], requested_audit[7])
        if cycle >= minimum_cycle_count &&
           maximum(convergence_errors; init = zero(T)) <= convergence_tol &&
           !isnothing(alignment) && alignment >= alignment_threshold &&
           !isnothing(value_change) && value_change <= value_tolerance
            converged = true
            breakdown = :converged
            break
        end
        previous_directions = copy(requested_directions)
        previous_values = copy(requested_audit[2])
        seeds = [copy(view(directions, :, index)) for index in axes(directions, 2)]
    end
    isnothing(final_audit) && return unavailable(
        "harmonic Golub--Kahan candidate audit did not complete ($breakdown)",
    )
    return HarmonicGolubKahanCandidateEstimate{T}(
        true, nothing, evaluation.point, requested_dimension, steps,
        requested_cycles, completed, retained, minimum_cycle_count, converged,
        operator.source, breakdown, trial_dimensions, metric_ranks,
        metric_conditions, hcat(harmonic_histories...),
        hcat(singular_histories...), hcat(backward_histories...), alignments,
        value_changes, final_directions, final_audit[1], final_harmonic,
        final_audit[2], final_audit[4], final_audit[6], final_audit[7],
        norm_value, _gk_orthogonality_loss(final_directions), convergence_tol,
        value_tolerance, alignment_threshold, metric_tolerance,
        basis_tolerance, estimated_entries, Int(max_basis_entries),
    )
end

"""Guarded dense-SVD comparison for harmonic Golub--Kahan candidates."""
function harmonic_golub_kahan_dense_calibration(
    evaluation::NumericalEvaluation{T};
    dimension::Integer = 1,
    dense_max_entries::Integer = 4_000_000,
    singular_value_relative_tolerance::Real = 1.0e-6,
    subspace_alignment_threshold::Real = 0.98,
    candidate_subspace_alignment_threshold::Real =
        subspace_alignment_threshold,
    kwargs...,
) where {T<:AbstractFloat}
    dense_max_entries >= 0 || throw(ArgumentError(
        "dense_max_entries must be nonnegative",
    ))
    dense_max_entries <= typemax(Int) || throw(ArgumentError(
        "dense_max_entries is too large",
    ))
    value_tolerance = T(singular_value_relative_tolerance)
    alignment_threshold = T(subspace_alignment_threshold)
    isfinite(value_tolerance) && value_tolerance >= zero(T) ||
        throw(ArgumentError(
            "singular_value_relative_tolerance must be finite and nonnegative",
        ))
    isfinite(alignment_threshold) && zero(T) <= alignment_threshold <= one(T) ||
        throw(ArgumentError("subspace_alignment_threshold must lie in [0, 1]"))
    estimate = harmonic_golub_kahan_candidates(
        evaluation; dimension = dimension,
        subspace_alignment_threshold =
            candidate_subspace_alignment_threshold,
        kwargs...,
    )
    rows = length(evaluation.constraint_sources)
    columns = length(evaluation.point.variables)
    requested_dimension = Int(dimension)
    unavailable(reason) = HarmonicGolubKahanDenseCalibration{T}(
        false, String(reason), evaluation.point, :unavailable, estimate, T[],
        zeros(T, columns, 0), T[], nothing, false, false, value_tolerance,
        alignment_threshold, Int(dense_max_entries),
    )
    estimate.available || return unavailable(
        "candidate estimate unavailable: $(something(estimate.reason, "unknown reason"))",
    )
    big(rows) * columns <= dense_max_entries || return unavailable(
        "dense Jacobian would contain $(big(rows) * columns) entries, exceeding guard $(Int(dense_max_entries))",
    )
    incomplete_rows = findall(
        method -> method in _JACOBIAN_INCOMPLETE_METHODS,
        evaluation.jacobian_row_methods,
    )
    isempty(incomplete_rows) || return unavailable(
        "Jacobian rows $(join(incomplete_rows, ',')) are incomplete",
    )
    matrix = _combined_jacobian_matrix(evaluation)
    all(isfinite, matrix) || return unavailable(
        "Jacobian contains non-finite combined entries",
    )
    factor = svd(matrix; full = true)
    all_values = vcat(T.(factor.S), zeros(T, columns - length(factor.S)))
    order = sortperm(all_values)
    selected = order[1:requested_dimension]
    dense_values = all_values[selected]
    dense_directions = Matrix(factor.V[:, selected])
    candidate_order = sortperm(estimate.singular_values)
    candidate_values = estimate.singular_values[candidate_order]
    candidate_directions = estimate.directions[:, candidate_order]
    scale = max(maximum(T.(factor.S); init = zero(T)), eps(T))
    sorted_dense_values = sort(all_values)
    target_subspace_unique = _dense_target_subspace_unique(
        sorted_dense_values, requested_dimension, columns, value_tolerance,
        scale,
    )
    relative_errors = _target_relative_singular_value_errors(
        candidate_values, dense_values, scale,
    )
    target_numerically_resolved = _dense_target_numerically_resolved(
        dense_values, scale, rows, columns,
    )
    cosines = _principal_cosines(dense_directions, candidate_directions)
    minimum_cosine = isempty(cosines) ? nothing : minimum(cosines)
    relation = if !estimate.converged
        :candidate_unconverged
    elseif !target_numerically_resolved
        :dense_target_numerically_unresolved
    elseif maximum(relative_errors; init = zero(T)) > value_tolerance
        :singular_value_disagreement
    elseif target_subspace_unique &&
           something(minimum_cosine, zero(T)) < alignment_threshold
        :subspace_disagreement
    elseif !target_subspace_unique
        :agreement_nonunique_subspace
    else
        :agreement
    end
    return HarmonicGolubKahanDenseCalibration{T}(
        true, nothing, evaluation.point, relation, estimate, dense_values,
        dense_directions, relative_errors, minimum_cosine,
        target_subspace_unique, target_numerically_resolved, value_tolerance,
        alignment_threshold,
        Int(dense_max_entries),
    )
end

"""
    smallest_singular_backend_crosscheck(evaluation; dimension = 1, kwargs...)

Compare the locally optimal normal-operator tracker with the zero-target
harmonic Golub--Kahan tracker without forming a dense Jacobian. Agreement is
finite-search evidence only; disagreement is classified by backend
convergence, candidate values, and principal-angle alignment.
"""
function smallest_singular_backend_crosscheck(
    evaluation::NumericalEvaluation{T};
    dimension::Integer = 1,
    restarted_iterations::Integer = 50,
    restarted_minimum_iterations::Integer = 2,
    restarted_convergence_tolerance::Real = sqrt(eps(T)),
    restarted_alignment_threshold::Real = 0.999,
    restarted_trial_basis_relative_tolerance::Real = 10 * eps(T),
    harmonic_steps_per_seed::Integer = 6,
    harmonic_cycles::Integer = 8,
    harmonic_retained_dimension::Integer = max(Int(dimension) + 1, 2),
    harmonic_minimum_cycles::Integer = 2,
    harmonic_convergence_tolerance::Real = sqrt(eps(T)),
    harmonic_value_change_tolerance::Real = sqrt(eps(T)),
    harmonic_alignment_threshold::Real = 0.999,
    harmonic_projected_metric_relative_tolerance::Real = 10 * eps(T),
    harmonic_trial_basis_relative_tolerance::Real = 10 * eps(T),
    singular_value_relative_tolerance::Real = 1.0e-4,
    near_zero_relative_tolerance::Real = sqrt(eps(T)),
    subspace_alignment_threshold::Real = 0.98,
    max_basis_entries::Integer = 1_000_000,
    matrix_norm::Symbol = :frobenius,
    operator::JacobianLinearOperator = jacobian_linear_operator(evaluation),
) where {T<:AbstractFloat}
    value_tolerance = T(singular_value_relative_tolerance)
    zero_tolerance = T(near_zero_relative_tolerance)
    alignment_threshold = T(subspace_alignment_threshold)
    for (name, value) in (
        ("singular_value_relative_tolerance", value_tolerance),
        ("near_zero_relative_tolerance", zero_tolerance),
    )
        isfinite(value) && value >= zero(T) || throw(ArgumentError(
            "$name must be finite and nonnegative",
        ))
    end
    isfinite(alignment_threshold) && zero(T) <= alignment_threshold <= one(T) ||
        throw(ArgumentError("subspace_alignment_threshold must lie in [0, 1]"))
    restarted = restarted_smallest_singular_candidates(
        evaluation;
        dimension = dimension,
        iterations = restarted_iterations,
        minimum_iterations = restarted_minimum_iterations,
        convergence_tolerance = restarted_convergence_tolerance,
        subspace_alignment_threshold = restarted_alignment_threshold,
        trial_basis_relative_tolerance =
            restarted_trial_basis_relative_tolerance,
        max_basis_entries = max_basis_entries,
        matrix_norm = matrix_norm,
        operator = operator,
    )
    harmonic = harmonic_golub_kahan_candidates(
        evaluation;
        dimension = dimension,
        steps_per_seed = harmonic_steps_per_seed,
        cycles = harmonic_cycles,
        retained_dimension = harmonic_retained_dimension,
        minimum_cycles = harmonic_minimum_cycles,
        convergence_tolerance = harmonic_convergence_tolerance,
        value_change_tolerance = harmonic_value_change_tolerance,
        subspace_alignment_threshold = harmonic_alignment_threshold,
        projected_metric_relative_tolerance =
            harmonic_projected_metric_relative_tolerance,
        trial_basis_relative_tolerance =
            harmonic_trial_basis_relative_tolerance,
        max_basis_entries = max_basis_entries,
        matrix_norm = matrix_norm,
        operator = operator,
    )
    unavailable_reason = if !restarted.available && !harmonic.available
        "both candidate engines are unavailable: restarted=$(restarted.reason); harmonic=$(harmonic.reason)"
    elseif !restarted.available
        "restarted candidate engine is unavailable: $(restarted.reason)"
    elseif !harmonic.available
        "harmonic candidate engine is unavailable: $(harmonic.reason)"
    else
        nothing
    end
    if !isnothing(unavailable_reason)
        return SmallestSingularBackendCrosscheck{T}(
            false, unavailable_reason, evaluation.point, :unavailable,
            restarted, harmonic, T[], nothing, value_tolerance,
            zero_tolerance, alignment_threshold,
        )
    end
    restarted_order = sortperm(restarted.singular_values)
    harmonic_order = sortperm(harmonic.singular_values)
    restarted_values = restarted.singular_values[restarted_order]
    harmonic_values = harmonic.singular_values[harmonic_order]
    restarted_directions = restarted.directions[:, restarted_order]
    harmonic_directions = harmonic.directions[:, harmonic_order]
    scale = max(
        something(restarted.matrix_norm, zero(T)),
        something(harmonic.matrix_norm, zero(T)), eps(T),
    )
    differences = similar(restarted_values)
    for index in eachindex(differences)
        local_scale = max(
            abs(restarted_values[index]), abs(harmonic_values[index]),
            eps(T) * max(scale, one(T)),
        )
        differences[index] =
            max(abs(restarted_values[index]), abs(harmonic_values[index])) <=
            zero_tolerance * scale ? zero(T) :
            abs(restarted_values[index] - harmonic_values[index]) / local_scale
    end
    cosines = _principal_cosines(restarted_directions, harmonic_directions)
    minimum_cosine = isempty(cosines) ? nothing : minimum(cosines)
    relation = if !restarted.converged && !harmonic.converged
        :both_unconverged
    elseif !restarted.converged
        :restarted_unconverged
    elseif !harmonic.converged
        :harmonic_unconverged
    elseif maximum(differences; init = zero(T)) > value_tolerance
        :singular_value_disagreement
    elseif something(minimum_cosine, zero(T)) < alignment_threshold
        :subspace_disagreement
    else
        :agreement
    end
    return SmallestSingularBackendCrosscheck{T}(
        true, nothing, evaluation.point, relation, restarted, harmonic,
        differences, minimum_cosine, value_tolerance, zero_tolerance,
        alignment_threshold,
    )
end

"""
    sparse_jacobian_pattern_estimate(evaluation; zero_tolerance = 0)

Compute a maximum matching in the combined sparse Jacobian nonzero pattern
without forming a dense matrix. The result is an upper bound on numerical rank
(the term rank). A bound below `min(rows, columns)` proves local rank
deficiency for the observed entries, but equality does not prove full rank.
"""
function sparse_jacobian_pattern_estimate(
    evaluation::NumericalEvaluation{T};
    zero_tolerance::Real = zero(T),
) where {T<:AbstractFloat}
    tolerance = convert(T, zero_tolerance)
    tolerance >= zero(T) ||
        throw(ArgumentError("zero_tolerance must be nonnegative"))
    incomplete_rows = findall(
        method -> method in _JACOBIAN_INCOMPLETE_METHODS,
        evaluation.jacobian_row_methods,
    )
    isempty(incomplete_rows) || return _unavailable_sparse_pattern_estimate(
        evaluation,
        tolerance,
        "Jacobian rows $(join(incomplete_rows, ',')) are incomplete",
    )
    combined = Dict{Tuple{Int,Int},T}()
    for entry in evaluation.jacobian_entries
        isfinite(entry.value) || return _unavailable_sparse_pattern_estimate(
            evaluation,
            tolerance,
            "Jacobian contains non-finite raw entries",
        )
        key = (entry.row, entry.column)
        combined[key] = get(combined, key, zero(T)) + entry.value
    end
    all(isfinite, values(combined)) || return _unavailable_sparse_pattern_estimate(
        evaluation,
        tolerance,
        "Jacobian contains non-finite combined entries",
    )
    rows = length(evaluation.constraint_sources)
    columns = length(evaluation.point.variables)
    adjacency = [Int[] for _ in 1:rows]
    nonzero_count = 0
    for ((row, column), value) in combined
        abs(value) > tolerance || continue
        push!(adjacency[row], column)
        nonzero_count += 1
    end
    for neighbors in adjacency
        sort!(neighbors)
    end
    column_match = zeros(Int, columns)
    for row in 1:rows
        _augment_sparse_row!(row, adjacency, column_match, falses(columns))
    end
    row_match = zeros(Int, rows)
    for (column, row) in enumerate(column_match)
        iszero(row) || (row_match[row] = column)
    end
    return SparseJacobianPatternEstimate{T}(
        true,
        nothing,
        evaluation.point,
        rows,
        columns,
        nonzero_count,
        tolerance,
        count(!iszero, column_match),
        findall(iszero, row_match),
        findall(iszero, column_match),
    )
end

"""
    jacobian_rank_estimate(evaluation; scaling = :none, ...)

Estimate local Jacobian rank and nullspaces using a guarded dense SVD.

Supported scaling modes are `:none`, `:row`, `:column`, and `:row_column`.
The threshold is `relative_tolerance * maximum(singular_values)`. An estimate
is unavailable when derivative rows are incomplete, entries are non-finite,
or the dense-work guard is exceeded.
"""
function jacobian_rank_estimate(
    evaluation::NumericalEvaluation{T};
    scaling::Symbol = :none,
    relative_tolerance::Real =
        max(
            length(evaluation.constraint_sources),
            length(evaluation.point.variables),
            1,
        ) * eps(T),
    absolute_tolerance::Real = zero(T),
    matrix_norm::Symbol = :frobenius,
    max_dense_entries::Integer = 4_000_000,
    compute_vectors::Bool = true,
    provenance::Symbol = :default,
) where {T<:AbstractFloat}
    policy = RankPolicy(
        T;
        backend = :dense_svd,
        scaling,
        relative_tolerance,
        absolute_tolerance,
        matrix_norm,
        max_dense_entries,
        compute_vectors,
        provenance,
    )
    return jacobian_rank_estimate(evaluation, policy)
end

"""
    golub_kahan_dense_calibration(evaluation; dense_policy, kwargs...)

Compare a multi-seed Golub--Kahan candidate span with a guarded dense-SVD
right nullspace on the same evaluated Jacobian. This is a calibration oracle
for representative small matrices, not a production fallback for large ones.
`relation` distinguishes missed dense directions, over-capture, and subspace
disagreement even when the reported dimensions coincide.
"""
function golub_kahan_dense_calibration(
    evaluation::NumericalEvaluation{T};
    dense_policy::RankPolicy{T} = RankPolicy(
        T;
        backend = :dense_svd,
        relative_tolerance = max(
            length(evaluation.constraint_sources),
            length(evaluation.point.variables),
            1,
        ) * eps(T),
        compute_vectors = true,
        provenance = :golub_kahan_calibration,
    ),
    subspace_alignment_threshold::Real = 0.98,
    kwargs...,
) where {T<:AbstractFloat}
    dense_policy.backend == :dense_svd || throw(ArgumentError(
        "dense_policy must use the :dense_svd backend",
    ))
    dense_policy.compute_vectors || throw(ArgumentError(
        "dense_policy.compute_vectors must be true for subspace calibration",
    ))
    alignment_threshold = T(subspace_alignment_threshold)
    isfinite(alignment_threshold) && zero(T) <= alignment_threshold <= one(T) ||
        throw(ArgumentError("subspace_alignment_threshold must lie in [0, 1]"))
    dense = jacobian_rank_estimate(evaluation, dense_policy)
    probe = multi_seed_golub_kahan_estimate(evaluation; kwargs...)
    unavailable(reason) = GolubKahanDenseCalibration{T}(
        false, String(reason), evaluation.point, :unavailable, dense, probe,
        dense.right_nullity, probe.candidate_span_rank, nothing, nothing,
    )
    dense.available || return unavailable(
        "dense SVD unavailable: $(something(dense.reason, "unknown reason"))",
    )
    probe.available || return unavailable(
        "multi-seed probe unavailable: $(something(probe.reason, "unknown reason"))",
    )

    dense_nullity = dense.right_nullity
    candidate_rank = probe.candidate_span_rank
    detected_fraction = iszero(dense_nullity) ? nothing :
        T(min(candidate_rank, dense_nullity) / dense_nullity)
    minimum_cosine = nothing
    if dense_nullity > 0 && candidate_rank > 0
        cosines = _principal_cosines(dense.right_nullspace, probe.candidate_basis)
        isempty(cosines) || (minimum_cosine = minimum(cosines))
    end
    relation = if candidate_rank < dense_nullity
        :candidate_miss
    elseif candidate_rank > dense_nullity
        :candidate_overcapture
    elseif iszero(dense_nullity)
        :dimension_agreement_no_candidate
    elseif something(minimum_cosine, zero(T)) >= alignment_threshold
        :subspace_agreement
    else
        :dimension_agreement_subspace_mismatch
    end
    return GolubKahanDenseCalibration{T}(
        true, nothing, evaluation.point, relation, dense, probe,
        dense_nullity, candidate_rank, detected_fraction, minimum_cosine,
    )
end

function jacobian_rank_estimate(
    evaluation::NumericalEvaluation{T},
    policy::RankPolicy{T},
) where {T<:AbstractFloat}
    policy.backend == :normal_eigen && return _normal_eigen_rank_estimate(evaluation, policy)
    policy.backend == :dense_svd ||
        throw(ArgumentError("jacobian_rank_estimate requires a :dense_svd RankPolicy"))
    rows = length(evaluation.constraint_sources)
    columns = length(evaluation.point.variables)
    rows * columns <= policy.max_dense_entries || return _unavailable_rank_estimate(
        evaluation,
        policy,
        "dense Jacobian would contain $(rows * columns) entries, exceeding guard $(policy.max_dense_entries)",
    )
    incomplete_rows = findall(
        method -> method in _JACOBIAN_INCOMPLETE_METHODS,
        evaluation.jacobian_row_methods,
    )
    isempty(incomplete_rows) || return _unavailable_rank_estimate(
        evaluation,
        policy,
        "Jacobian rows $(join(incomplete_rows, ',')) are incomplete",
    )
    matrix = _combined_jacobian_matrix(evaluation)
    all(isfinite, matrix) || return _unavailable_rank_estimate(
        evaluation,
        policy,
        "Jacobian contains non-finite combined entries",
    )

    intervention = _jacobian_diagonal_scaling(matrix, policy.scaling)
    row_scaling = intervention.row_scaling
    column_scaling = intervention.column_scaling
    scaled = intervention.matrix

    if iszero(rows) || iszero(columns)
        right_nullspace =
            policy.compute_vectors && iszero(rows) ? Matrix{T}(I, columns, columns) :
            zeros(T, columns, 0)
        left_nullspace =
            policy.compute_vectors && iszero(columns) ? Matrix{T}(I, rows, rows) :
            zeros(T, rows, 0)
        return JacobianRankEstimate{T}(
            true,
            nothing,
            evaluation.point,
            policy,
            :dense_svd,
            policy.scaling,
            rows,
            columns,
            0,
            rows,
            columns,
            T[],
            policy.relative_tolerance,
            policy.absolute_tolerance,
            nothing,
            row_scaling,
            column_scaling,
            left_nullspace,
            right_nullspace,
        )
    end

    factorization = svd(scaled; full = true)
    singular_values = T.(factorization.S)
    threshold = max(
        policy.absolute_tolerance,
        policy.relative_tolerance * maximum(singular_values; init = zero(T)),
    )
    estimated_rank = count(value -> value > threshold, singular_values)
    left_nullity = rows - estimated_rank
    right_nullity = columns - estimated_rank
    condition_estimate = if estimated_rank < min(rows, columns)
        T(Inf)
    elseif isempty(singular_values)
        nothing
    elseif iszero(last(singular_values))
        T(Inf)
    else
        first(singular_values) / last(singular_values)
    end
    left_nullspace = zeros(T, rows, 0)
    right_nullspace = zeros(T, columns, 0)
    if policy.compute_vectors
        left_nullspace =
            Matrix(factorization.U[:, (estimated_rank + 1):rows])
        left_nullspace .*= row_scaling
        _normalized_columns(left_nullspace)
        right_nullspace =
            Matrix(factorization.V[:, (estimated_rank + 1):columns])
        right_nullspace .*= column_scaling
        _normalized_columns(right_nullspace)
    end
    return JacobianRankEstimate{T}(
        true,
        nothing,
        evaluation.point,
        policy,
        :dense_svd,
        policy.scaling,
        rows,
        columns,
        estimated_rank,
        left_nullity,
        right_nullity,
        singular_values,
        policy.relative_tolerance,
        threshold,
        condition_estimate,
        row_scaling,
        column_scaling,
        left_nullspace,
        right_nullspace,
    )
end

"""
    _normal_eigen_rank_estimate(evaluation, policy)

Experimental third rank backend based on the symmetric normal equations.  The
smallest eigenvalues of the scaled Gram matrix are square-rooted and compared
with the same explicit rank threshold as the dense-SVD backend.  This is an
independent algebraic path for calibration, but squaring the condition number
can erase small singular values; it must not be treated as a production oracle.
"""
function _normal_eigen_rank_estimate(
    evaluation::NumericalEvaluation{T},
    policy::RankPolicy{T},
) where {T<:AbstractFloat}
    rows = length(evaluation.constraint_sources)
    columns = length(evaluation.point.variables)
    rows * columns <= policy.max_dense_entries || return _unavailable_rank_estimate(
        evaluation, policy,
        "normal-equations Jacobian would contain $(rows * columns) entries, exceeding guard $(policy.max_dense_entries)",
    )
    incomplete_rows = findall(
        method -> method in _JACOBIAN_INCOMPLETE_METHODS,
        evaluation.jacobian_row_methods,
    )
    isempty(incomplete_rows) || return _unavailable_rank_estimate(
        evaluation, policy,
        "Jacobian rows $(join(incomplete_rows, ',')) are incomplete",
    )
    matrix = _combined_jacobian_matrix(evaluation)
    all(isfinite, matrix) || return _unavailable_rank_estimate(
        evaluation, policy, "Jacobian contains non-finite combined entries",
    )
    intervention = _jacobian_diagonal_scaling(matrix, policy.scaling)
    scaled = intervention.matrix
    row_scaling = intervention.row_scaling
    column_scaling = intervention.column_scaling
    if iszero(rows) || iszero(columns)
        right_nullspace = policy.compute_vectors && iszero(rows) ?
            Matrix{T}(I, columns, columns) : zeros(T, columns, 0)
        left_nullspace = policy.compute_vectors && iszero(columns) ?
            Matrix{T}(I, rows, rows) : zeros(T, rows, 0)
        return JacobianRankEstimate{T}(
            true, nothing, evaluation.point, policy, :normal_eigen,
            policy.scaling, rows, columns, 0, rows, columns, T[],
            policy.relative_tolerance, policy.absolute_tolerance, nothing,
            row_scaling, column_scaling, left_nullspace, right_nullspace,
        )
    end

    # Use the smaller Gram matrix for the rank spectrum and form the other
    # side only when vectors are explicitly requested.
    right_gram = Symmetric(transpose(scaled) * scaled)
    right_factor = eigen(right_gram)
    raw_right_values = T.(right_factor.values)
    # Forming J'J introduces an O(eps * ||J||²) floor.  Clamp only that
    # roundoff band so exact rectangular nullity is not reported as a tiny
    # positive singular direction.
    gram_scale = maximum(abs, raw_right_values; init = zero(T))
    gram_floor = eps(T) * max(gram_scale, one(T)) * max(rows, columns) * 10
    right_values = T[
        value <= gram_floor ? zero(T) : max(value, zero(T))
        for value in raw_right_values
    ]
    singular_values = sort!(sqrt.(right_values); rev = true)
    threshold = max(
        policy.absolute_tolerance,
        policy.relative_tolerance * maximum(singular_values; init = zero(T)),
    )
    estimated_rank = count(value -> value > threshold, singular_values)
    left_nullity = rows - estimated_rank
    right_nullity = columns - estimated_rank
    condition_estimate = if estimated_rank < min(rows, columns)
        T(Inf)
    elseif isempty(singular_values) || iszero(last(singular_values))
        T(Inf)
    else
        first(singular_values) / last(singular_values)
    end
    left_nullspace = zeros(T, rows, 0)
    right_nullspace = zeros(T, columns, 0)
    if policy.compute_vectors
        # Eigenvectors are returned in ascending eigenvalue order.  Map the
        # scaled right nullspace back to original coordinates and normalize.
        right_nullspace = Diagonal(column_scaling) *
            Matrix(right_factor.vectors[:, 1:right_nullity])
        _normalized_columns(right_nullspace)
        left_gram = Symmetric(scaled * transpose(scaled))
        left_factor = eigen(left_gram)
        left_nullspace = Diagonal(row_scaling) *
            Matrix(left_factor.vectors[:, 1:left_nullity])
        _normalized_columns(left_nullspace)
    end
    return JacobianRankEstimate{T}(
        true, nothing, evaluation.point, policy, :normal_eigen,
        policy.scaling, rows, columns, estimated_rank, left_nullity,
        right_nullity, singular_values, policy.relative_tolerance, threshold,
        condition_estimate, row_scaling, column_scaling, left_nullspace,
        right_nullspace,
    )
end
