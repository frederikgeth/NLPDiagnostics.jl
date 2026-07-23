const _JACOBIAN_INCOMPLETE_METHODS =
    (:unavailable, :partial_central_finite_difference)

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

function _unavailable_rank_estimate(
    evaluation::NumericalEvaluation{T},
    scaling::Symbol,
    relative_tolerance::T,
    reason::AbstractString,
) where {T}
    rows = length(evaluation.constraint_sources)
    columns = length(evaluation.point.variables)
    return JacobianRankEstimate{T}(
        false,
        String(reason),
        evaluation.point,
        :dense_svd,
        scaling,
        rows,
        columns,
        0,
        rows,
        columns,
        T[],
        relative_tolerance,
        zero(T),
        nothing,
        ones(T, rows),
        ones(T, columns),
        zeros(T, rows, 0),
        zeros(T, columns, 0),
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
    max_dense_entries::Integer = 4_000_000,
    compute_vectors::Bool = true,
) where {T<:AbstractFloat}
    scaling in (:none, :row, :column, :row_column) || throw(
        ArgumentError(
            "scaling must be :none, :row, :column, or :row_column",
        ),
    )
    converted_tolerance = convert(T, relative_tolerance)
    converted_tolerance >= zero(T) ||
        throw(ArgumentError("relative_tolerance must be nonnegative"))
    max_dense_entries >= 0 ||
        throw(ArgumentError("max_dense_entries must be nonnegative"))
    rows = length(evaluation.constraint_sources)
    columns = length(evaluation.point.variables)
    rows * columns <= max_dense_entries || return _unavailable_rank_estimate(
        evaluation,
        scaling,
        converted_tolerance,
        "dense Jacobian would contain $(rows * columns) entries, exceeding guard $max_dense_entries",
    )
    incomplete_rows = findall(
        method -> method in _JACOBIAN_INCOMPLETE_METHODS,
        evaluation.jacobian_row_methods,
    )
    isempty(incomplete_rows) || return _unavailable_rank_estimate(
        evaluation,
        scaling,
        converted_tolerance,
        "Jacobian rows $(join(incomplete_rows, ',')) are incomplete",
    )
    matrix = _combined_jacobian_matrix(evaluation)
    all(isfinite, matrix) || return _unavailable_rank_estimate(
        evaluation,
        scaling,
        converted_tolerance,
        "Jacobian contains non-finite combined entries",
    )

    row_scaling = ones(T, rows)
    column_scaling = ones(T, columns)
    scaled = copy(matrix)
    if scaling in (:row, :row_column)
        for row in axes(scaled, 1)
            row_norm = norm(view(scaled, row, :))
            iszero(row_norm) || (row_scaling[row] = inv(row_norm))
        end
        scaled .*= row_scaling
    end
    if scaling in (:column, :row_column)
        for column in axes(scaled, 2)
            column_norm = norm(view(scaled, :, column))
            iszero(column_norm) || (column_scaling[column] = inv(column_norm))
        end
        scaled .*= transpose(column_scaling)
    end

    if iszero(rows) || iszero(columns)
        right_nullspace =
            compute_vectors && iszero(rows) ? Matrix{T}(I, columns, columns) :
            zeros(T, columns, 0)
        left_nullspace =
            compute_vectors && iszero(columns) ? Matrix{T}(I, rows, rows) :
            zeros(T, rows, 0)
        return JacobianRankEstimate{T}(
            true,
            nothing,
            evaluation.point,
            :dense_svd,
            scaling,
            rows,
            columns,
            0,
            rows,
            columns,
            T[],
            converted_tolerance,
            zero(T),
            nothing,
            row_scaling,
            column_scaling,
            left_nullspace,
            right_nullspace,
        )
    end

    factorization = svd(scaled; full = true)
    singular_values = T.(factorization.S)
    threshold = converted_tolerance * maximum(singular_values; init = zero(T))
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
    if compute_vectors
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
        :dense_svd,
        scaling,
        rows,
        columns,
        estimated_rank,
        left_nullity,
        right_nullity,
        singular_values,
        converted_tolerance,
        threshold,
        condition_estimate,
        row_scaling,
        column_scaling,
        left_nullspace,
        right_nullspace,
    )
end
