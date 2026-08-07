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
    provenance::Symbol = :default,
) where {T<:AbstractFloat}
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
    return sparse_qr_rank_estimate(evaluation, policy)
end

function sparse_qr_rank_estimate(
    evaluation::NumericalEvaluation{T},
    policy::RankPolicy{T},
) where {T<:AbstractFloat}
    policy.backend == :sparse_qr ||
        throw(ArgumentError("sparse_qr_rank_estimate requires a :sparse_qr RankPolicy"))
    rows, columns = length(evaluation.constraint_sources), length(evaluation.point.variables)
    pattern = sparse_jacobian_pattern_estimate(evaluation)
    unavailable(reason) = SparseQRRankEstimate{T}(
        false, reason, evaluation.point, policy, :suitesparse_qr,
        policy.scaling, rows, columns, 0, T[], policy.relative_tolerance,
        policy.absolute_tolerance, nothing, nothing, Int[], Int[], nothing,
        nothing,
    )
    !pattern.available && return unavailable(pattern.reason)
    matrix = _combined_sparse_jacobian_matrix(evaluation)
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
        pivots = T.(abs.(diag(factorization.R)))
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
) where {T<:AbstractFloat}
    iterations > 0 || throw(ArgumentError("iterations must be positive"))
    tolerance = convert(T, convergence_tolerance)
    tolerance >= zero(T) ||
        throw(ArgumentError("convergence_tolerance must be nonnegative"))
    rows = length(evaluation.constraint_sources)
    columns = length(evaluation.point.variables)
    unavailable(reason) = IterativeNullspaceEstimate{T}(
        false, reason, evaluation.point, 0, false, T[], nothing, nothing,
        nothing,
    )
    columns > 0 || return unavailable("Jacobian has no variable columns")
    pattern = sparse_jacobian_pattern_estimate(evaluation)
    pattern.available || return unavailable(pattern.reason)

    matrix = _combined_sparse_jacobian_matrix(evaluation)
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
        normal_product = adjoint(matrix) * (matrix * probe)
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
        candidate = direction - (adjoint(matrix) * (matrix * direction)) / shift
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
    residual = norm(matrix * direction)
    isfinite(residual) || return unavailable("candidate residual became non-finite")
    relative_residual = _relative_residual(residual, norm_value, norm(direction))
    return IterativeNullspaceEstimate{T}(
        true, nothing, evaluation.point, completed_iterations, converged,
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
) where {T<:AbstractFloat}
    dimension > 0 || throw(ArgumentError("dimension must be positive"))
    iterations > 0 || throw(ArgumentError("iterations must be positive"))
    tolerance = convert(T, convergence_tolerance)
    tolerance >= zero(T) ||
        throw(ArgumentError("convergence_tolerance must be nonnegative"))
    rows = length(evaluation.constraint_sources)
    columns = length(evaluation.point.variables)
    unavailable(reason) = IterativeNullspaceSubspaceEstimate{T}(
        false, reason, evaluation.point, Int(dimension), 0, false,
        zeros(T, columns, 0), T[], nothing, T[], nothing,
    )
    columns > 0 || return unavailable("Jacobian has no variable columns")
    dimension <= columns ||
        throw(ArgumentError("dimension must not exceed the Jacobian column count"))
    pattern = sparse_jacobian_pattern_estimate(evaluation)
    pattern.available || return unavailable(pattern.reason)
    matrix = _combined_sparse_jacobian_matrix(evaluation)
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
        normal_product = adjoint(matrix) * (matrix * probe)
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
        candidate = directions - (adjoint(matrix) * (matrix * directions)) / shift
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
    residuals = T[norm(matrix * directions[:, column]) for column in 1:dimension]
    all(isfinite, residuals) || return unavailable("candidate residual became non-finite")
    relative_residuals = T[
        _relative_residual(residuals[column], norm_value, norm(view(directions, :, column)))
        for column in 1:dimension
    ]
    return IterativeNullspaceSubspaceEstimate{T}(
        true, nothing, evaluation.point, Int(dimension), completed_iterations,
        converged, directions, residuals, norm_value, relative_residuals,
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
) where {T<:AbstractFloat}
    dimension > 0 || throw(ArgumentError("dimension must be positive"))
    iterations > 0 || throw(ArgumentError("iterations must be positive"))
    tolerance = convert(T, convergence_tolerance)
    tolerance >= zero(T) ||
        throw(ArgumentError("convergence_tolerance must be nonnegative"))
    rows = length(evaluation.constraint_sources)
    unavailable(reason) = IterativeLeftNullspaceSubspaceEstimate{T}(
        false, reason, evaluation.point, Int(dimension), 0, false,
        zeros(T, rows, 0), T[], nothing, T[], nothing,
    )
    rows > 0 || return unavailable("Jacobian has no constraint rows")
    dimension <= rows ||
        throw(ArgumentError("dimension must not exceed the Jacobian row count"))
    pattern = sparse_jacobian_pattern_estimate(evaluation)
    pattern.available || return unavailable(pattern.reason)
    matrix = _combined_sparse_jacobian_matrix(evaluation)
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
        normal_product = matrix * (adjoint(matrix) * probe)
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
        candidate = directions - matrix * (adjoint(matrix) * directions) / shift
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
    residuals = T[norm(adjoint(matrix) * directions[:, column]) for column in 1:dimension]
    all(isfinite, residuals) || return unavailable("candidate residual became non-finite")
    relative_residuals = T[
        _relative_residual(residuals[column], norm_value, norm(view(directions, :, column)))
        for column in 1:dimension
    ]
    return IterativeLeftNullspaceSubspaceEstimate{T}(
        true, nothing, evaluation.point, Int(dimension), completed_iterations,
        converged, directions, residuals, norm_value, relative_residuals,
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
) where {T<:AbstractFloat}
    iterations > 0 || throw(ArgumentError("iterations must be positive"))
    probe_dimension > 0 || throw(ArgumentError("probe_dimension must be positive"))
    columns = length(evaluation.point.variables)
    unavailable(reason) = IterativeJacobianSpectrumEstimate{T}(
        false, reason, evaluation.point, 0, nothing, T[], T[], false,
    )
    columns > 0 || return unavailable("Jacobian has no variable columns")
    probe_dimension <= columns ||
        throw(ArgumentError("probe_dimension must not exceed the Jacobian column count"))
    pattern = sparse_jacobian_pattern_estimate(evaluation)
    pattern.available || return unavailable(pattern.reason)
    matrix = _combined_sparse_jacobian_matrix(evaluation)
    vector = T[sin(T(index)) for index in 1:columns]
    vector_norm = norm(vector)
    isfinite(vector_norm) && !iszero(vector_norm) ||
        return unavailable("could not construct a finite power-iteration seed")
    vector ./= vector_norm
    completed_iterations = 0
    for iteration in 1:Int(iterations)
        normal_product = adjoint(matrix) * (matrix * vector)
        product_norm = norm(normal_product)
        isfinite(product_norm) ||
            return unavailable("sparse normal-operator product became non-finite")
        completed_iterations = iteration
        iszero(product_norm) && break
        vector = normal_product / product_norm
    end
    normal_product = adjoint(matrix) * (matrix * vector)
    rayleigh = dot(vector, normal_product)
    isfinite(rayleigh) && rayleigh >= zero(T) ||
        return unavailable("power-iteration Rayleigh quotient became invalid")
    largest = sqrt(rayleigh)
    subspace = iterative_right_nullspace_subspace_estimate(
        evaluation,
        probe_dimension;
        iterations = iterations,
        convergence_tolerance = convergence_tolerance,
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
        largest,
        subspace.residual_norms,
        spreads,
        subspace.converged,
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

function jacobian_rank_estimate(
    evaluation::NumericalEvaluation{T},
    policy::RankPolicy{T},
) where {T<:AbstractFloat}
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

    row_scaling = ones(T, rows)
    column_scaling = ones(T, columns)
    scaled = copy(matrix)
    if policy.scaling in (:row, :row_column)
        for row in axes(scaled, 1)
            row_norm = norm(view(scaled, row, :))
            iszero(row_norm) || (row_scaling[row] = inv(row_norm))
        end
        scaled .*= row_scaling
    end
    if policy.scaling in (:column, :row_column)
        for column in axes(scaled, 2)
            column_norm = norm(view(scaled, :, column))
            iszero(column_norm) || (column_scaling[column] = inv(column_norm))
        end
        scaled .*= transpose(column_scaling)
    end

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
