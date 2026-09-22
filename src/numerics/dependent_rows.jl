"""
One point-local row-dependency investigation. `rows` contains positions in the
original `NumericalEvaluation`, not reindexed positions in a submatrix.

`irreducible_under_policy` means that the localized rows are dependent and
every one-row deletion is independent under the same fixed singular-value
threshold. It is a numerical statement, not a proof of exact algebraic
dependence, feasibility, or a physical cause.
"""
struct DependentRowLocalization{T<:AbstractFloat}
    available::Bool
    reason::Union{Nothing,String}
    point::EvaluationPoint{T}
    policy::RankPolicy{T}
    selected_rows::Vector{Int}
    selected_sources::Vector{EntityRef}
    selected_rank::Union{Nothing,Int}
    threshold::Union{Nothing,T}
    dependent::Union{Nothing,Bool}
    rows::Vector{Int}
    sources::Vector{EntityRef}
    coefficients::Vector{T}
    residual_norm::Union{Nothing,T}
    relative_residual::Union{Nothing,T}
    deletion_ranks::Vector{Int}
    irreducible_under_policy::Bool
    rank_checks::Int
end

function _unavailable_dependent_rows(evaluation, policy, selected, reason;
    rank_checks = 0)
    T = eltype(evaluation.point.values)
    return DependentRowLocalization{T}(
        false, String(reason), evaluation.point, policy, selected,
        evaluation.constraint_sources[selected], nothing, nothing, nothing,
        Int[], EntityRef[], T[], nothing, nothing, Int[], false, rank_checks,
    )
end

"""
    dependent_row_localization(evaluation; rows = 1:nrows, ...)

Find one inclusion-minimal dependent set of evaluated Jacobian rows by
deterministic deletion. All rank checks use dense SVD on the same globally
scaled matrix and the same singular-value threshold. The result exposes every
one-row deletion rank and a left-null combination in original row coordinates.
The row and dense-entry guards make this a bounded, small-subsystem diagnostic.
Select equality or active rows explicitly when interpreting constraint
qualification; the default includes every represented Jacobian row.
"""
function dependent_row_localization(
    evaluation::NumericalEvaluation{T};
    rows::AbstractVector{<:Integer} = collect(eachindex(evaluation.constraint_sources)),
    scaling::Symbol = :none,
    relative_tolerance::Real = max(
        length(rows), length(evaluation.point.variables), 1,
    ) * eps(T),
    absolute_tolerance::Real = zero(T),
    max_rows::Integer = 128,
    max_dense_entries::Integer = 4_000_000,
    provenance::Symbol = :default,
) where {T<:AbstractFloat}
    max_rows >= 0 || throw(ArgumentError("max_rows must be nonnegative"))
    selected = Int.(rows)
    length(unique(selected)) == length(selected) ||
        throw(ArgumentError("rows must not contain duplicates"))
    all(row -> 1 <= row <= length(evaluation.constraint_sources), selected) ||
        throw(ArgumentError("rows must index evaluated constraint rows"))
    sort!(selected)
    policy = RankPolicy(T; backend = :dense_svd, scaling, relative_tolerance,
        absolute_tolerance, max_dense_entries, compute_vectors = true,
        provenance)
    length(selected) <= max_rows || return _unavailable_dependent_rows(
        evaluation, policy, selected,
        "selected row count $(length(selected)) exceeds max_rows $max_rows",
    )
    columns = length(evaluation.point.variables)
    largest = max(widen(length(selected)) * columns,
        widen(length(selected))^2)
    largest <= max_dense_entries || return _unavailable_dependent_rows(
        evaluation, policy, selected,
        "dense Jacobian or singular-vector factor requires $largest entries, exceeding guard $max_dense_entries",
    )
    incomplete = filter(row -> evaluation.jacobian_row_methods[row] in
        _JACOBIAN_INCOMPLETE_METHODS, selected)
    isempty(incomplete) || return _unavailable_dependent_rows(
        evaluation, policy, selected,
        "selected Jacobian rows $(join(incomplete, ',')) are incomplete",
    )
    selected_set = Set(selected)
    all(entry -> !(entry.row in selected_set) || isfinite(entry.value),
        evaluation.jacobian_entries) || return _unavailable_dependent_rows(
        evaluation, policy, selected, "selected Jacobian entries are non-finite",
    )
    matrix = _combined_jacobian_matrix(evaluation)[selected, :]
    all(isfinite, matrix) || return _unavailable_dependent_rows(
        evaluation, policy, selected,
        "combined selected Jacobian entries are non-finite",
    )
    intervention = _jacobian_diagonal_scaling(matrix, scaling)
    scaled = intervention.matrix
    initial_values = isempty(selected) || iszero(columns) ? T[] :
        T.(svdvals(scaled))
    threshold = max(policy.absolute_tolerance,
        policy.relative_tolerance * maximum(initial_values; init = zero(T)))
    rank_of(positions) = isempty(positions) || iszero(columns) ? 0 :
        count(value -> value > threshold, svdvals(scaled[positions, :]))
    checks = 1
    selected_rank = count(value -> value > threshold, initial_values)
    if selected_rank == length(selected)
        return DependentRowLocalization{T}(
            true, nothing, evaluation.point, policy, selected,
            evaluation.constraint_sources[selected], selected_rank, threshold,
            false, Int[], EntityRef[], T[], nothing, nothing, Int[], false,
            checks,
        )
    end
    localized = collect(eachindex(selected))
    for index in reverse(eachindex(selected))
        index in localized || continue
        trial = filter(!=(index), localized)
        trial_rank = rank_of(trial)
        checks += 1
        trial_rank < length(trial) && (localized = trial)
    end
    deletion_ranks = Int[]
    for index in localized
        trial = filter(!=(index), localized)
        push!(deletion_ranks, rank_of(trial))
        checks += 1
    end
    irreducible = rank_of(localized) < length(localized) &&
        all(deletion_ranks .== (length(localized) - 1))
    checks += 1
    irreducible || return _unavailable_dependent_rows(
        evaluation, policy, selected,
        "the localized rows did not pass the fixed-threshold deletion check";
        rank_checks = checks,
    )
    factorization = svd(scaled[localized, :]; full = length(localized) > columns)
    scaled_coefficients = factorization.U[:, end]
    coefficients = scaled_coefficients .* intervention.row_scaling[localized]
    coefficients ./= norm(coefficients)
    local_matrix = matrix[localized, :]
    residual = norm(transpose(local_matrix) * coefficients)
    relative = _relative_residual(residual, norm(local_matrix), norm(coefficients))
    source_rows = selected[localized]
    return DependentRowLocalization{T}(
        true, nothing, evaluation.point, policy, selected,
        evaluation.constraint_sources[selected], selected_rank, threshold,
        true, source_rows, evaluation.constraint_sources[source_rows],
        coefficients, residual, relative, deletion_ranks, true, checks,
    )
end

"""Return a renderer-neutral representation of a row-localization result."""
function dependent_row_localization_data(result::DependentRowLocalization)
    return Dict{String,Any}(
        "schema_version" => "nlpdiagnostics-dependent-row-localization-v1",
        "available" => result.available,
        "reason" => result.reason,
        "point" => _evaluation_point_data(result.point),
        "policy" => Dict{String,Any}(
            "method" => "dense_svd_fixed_threshold_deletion",
            "scaling" => string(result.policy.scaling),
            "relative_tolerance" => result.policy.relative_tolerance,
            "absolute_tolerance" => result.policy.absolute_tolerance,
            "max_dense_entries" => result.policy.max_dense_entries,
            "provenance" => string(result.policy.provenance),
        ),
        "selected_rows" => copy(result.selected_rows),
        "selected_sources" => entity_data.(result.selected_sources),
        "selected_rank" => result.selected_rank,
        "fixed_threshold" => result.threshold,
        "dependent" => result.dependent,
        "rows" => copy(result.rows),
        "sources" => entity_data.(result.sources),
        "coefficients" => copy(result.coefficients),
        "residual_norm" => result.residual_norm,
        "relative_residual" => result.relative_residual,
        "deletion_ranks" => copy(result.deletion_ranks),
        "irreducible_under_policy" => result.irreducible_under_policy,
        "rank_checks" => result.rank_checks,
        "qualification" => "one point-local numerical row dependence under a fixed threshold; no exact, feasibility, or physical claim",
    )
end

"""Turn a localized row dependency into a typed, point-qualified finding."""
function dependent_row_localization_report(result::DependentRowLocalization)
    report = DiagnosticReport()
    report.metadata[:stage] = "dependent_row_localization"
    report.metadata[:point_fingerprint] = evaluation_point_fingerprint(result.point)
    report.metadata[:scaling] = string(result.policy.scaling)
    report.metadata[:rank_checks] = string(result.rank_checks)
    if !result.available
        push!(report, Finding(:dependent_row_localization_unavailable;
            severity = SeverityInfo,
            domain = NumericalIssue,
            basis = NumericalObservation,
            confidence = ConfidenceHigh,
            observation = "Dependent-row localization is unavailable at point \"$(result.point.label)\".",
            why_it_matters = "Incomplete derivatives or a work guard prevent a verified row-dependency claim.",
            evidence = [Evidence("Localization boundary"; details = [
                "reason" => result.reason,
                "selected_rows" => result.selected_rows,
            ])],
            suggested_actions = ["Inspect the stated boundary and select a smaller complete row scope."],
        ))
    elseif result.dependent === true
        push!(report, Finding(:numerical_irreducible_dependent_rows;
            severity = SeverityWarning,
            domain = NumericalIssue,
            basis = NumericalObservation,
            confidence = ConfidenceHigh,
            observation = "Rows $(join(result.rows, ", ")) form a point-local numerical irreducible dependent set under the recorded rank policy.",
            why_it_matters = "Every one-row deletion is independent under the same fixed threshold. These rows are a compact starting point for checking duplicate equations, local derivative cancellation, and constraint qualification.",
            evidence = [Evidence("Fixed-threshold deletion checks"; details = [
                "point_fingerprint" => evaluation_point_fingerprint(result.point),
                "selected_rows" => result.selected_rows,
                "selected_rank" => result.selected_rank,
                "rows" => result.rows,
                "deletion_ranks" => result.deletion_ranks,
                "fixed_threshold" => result.threshold,
                "scaling" => string(result.policy.scaling),
                "relative_residual" => result.relative_residual,
                "rank_checks" => result.rank_checks,
            ])],
            affected = result.sources,
            suggested_actions = [
                "Inspect these source rows and repeat at a nearby domain-valid point and another justified tolerance.",
                "Verify row activity and feasibility before interpreting this as a constraint-qualification failure.",
            ],
        ))
    end
    return report
end
