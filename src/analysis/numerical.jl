function _finite_scale_extrema(norms)
    positive = filter(value -> isfinite(value) && value > zero(value), norms)
    isempty(positive) && return nothing, nothing, nothing
    smallest = minimum(positive)
    largest = maximum(positive)
    return smallest, largest, largest / smallest
end

"""
    jacobian_scale_summary(evaluation)

Compute row and column infinity norms after additively combining duplicate
sparse entries.
"""
function jacobian_scale_summary(evaluation::NumericalEvaluation{T}) where {T}
    row_count = length(evaluation.constraint_sources)
    column_count = length(evaluation.point.variables)
    combined = Dict{Tuple{Int,Int},T}()
    for entry in evaluation.jacobian_entries
        key = (entry.row, entry.column)
        combined[key] = get(combined, key, zero(T)) + entry.value
    end
    row_norms = zeros(T, row_count)
    column_norms = zeros(T, column_count)
    nonfinite_rows = Set{Int}()
    nonfinite_columns = Set{Int}()
    for ((row, column), value) in combined
        if !isfinite(value)
            push!(nonfinite_rows, row)
            push!(nonfinite_columns, column)
            row_norms[row] = T(NaN)
            column_norms[column] = T(NaN)
        else
            row in nonfinite_rows ||
                (row_norms[row] = max(row_norms[row], abs(value)))
            column in nonfinite_columns ||
                (column_norms[column] = max(column_norms[column], abs(value)))
        end
    end
    unavailable_rows = Set(
        i for (i, method) in enumerate(evaluation.jacobian_row_methods) if
        method in (:unavailable, :partial_central_finite_difference)
    )
    zero_rows = [
        row for row in eachindex(row_norms) if
        iszero(row_norms[row]) && !(row in unavailable_rows)
    ]
    jacobian_complete =
        !isempty(evaluation.jacobian_row_methods) &&
        isempty(unavailable_rows)
    zero_columns = jacobian_complete ?
                   [
        column for column in eachindex(column_norms) if
        iszero(column_norms[column])
    ] :
                   Int[]
    row_min, row_max, row_ratio = _finite_scale_extrema(row_norms)
    column_min, column_max, column_ratio =
        _finite_scale_extrema(column_norms)
    return JacobianScaleSummary{T}(
        row_norms,
        column_norms,
        zero_rows,
        zero_columns,
        sort!(collect(nonfinite_rows)),
        sort!(collect(nonfinite_columns)),
        row_min,
        row_max,
        row_ratio,
        column_min,
        column_max,
        column_ratio,
        :infinity,
    )
end

function _jacobian_row_family_labels(row_labels, row_count::Integer)
    label_value(value) = begin
        if value isa AbstractDict
            raw = get(value, "constraint_family",
                      get(value, :constraint_family, "unclassified_row"))
            return String(raw)
        end
        return string(value isa Symbol ? value : value)
    end
    labels = Vector{String}(undef, row_count)
    if row_labels isa AbstractDict
        for row in 1:row_count
            value = get(row_labels, row,
                        get(row_labels, string(row), "unclassified_row"))
            labels[row] = label_value(value)
        end
    else
        length(row_labels) == row_count || throw(ArgumentError(
            "row_labels must have one entry per evaluated Jacobian row",
        ))
        for row in 1:row_count
            labels[row] = label_value(row_labels[row])
        end
    end
    return labels
end

function _jacobian_scale_quantile(values, probability)
    isempty(values) && return nothing
    length(values) == 1 && return first(values)
    position = one(probability) + probability * (length(values) - 1)
    lower = floor(Int, position)
    upper = ceil(Int, position)
    lower == upper && return values[lower]
    weight = position - lower
    return (one(weight) - weight) * values[lower] + weight * values[upper]
end

"""
    jacobian_row_family_scale_attribution(evaluation, row_labels)

Attribute evaluated Jacobian row-scale evidence to declared row families.
The result contains robust infinity-norm summaries, zero/non-finite/unavailable
row counts, combined sparse-entry counts, and ownership of the global row-scale
extrema. Duplicate sparse entries are summed exactly as in
[`jacobian_scale_summary`](@ref).

This is point-local derivative evidence. It identifies which labelled families
contain large or small derivative rows, but does not claim that a family caused
a global condition estimate or solver failure.
"""
function jacobian_row_family_scale_attribution(
    evaluation::NumericalEvaluation{T}, row_labels,
) where {T<:AbstractFloat}
    row_count = length(evaluation.constraint_sources)
    labels = _jacobian_row_family_labels(row_labels, row_count)
    scale = jacobian_scale_summary(evaluation)
    unavailable = Set(
        row for (row, method) in enumerate(evaluation.jacobian_row_methods) if
        method in (:unavailable, :partial_central_finite_difference)
    )
    nonfinite = Set(scale.nonfinite_rows)
    combined = Dict{Tuple{Int,Int},T}()
    for entry in evaluation.jacobian_entries
        key = (entry.row, entry.column)
        combined[key] = get(combined, key, zero(T)) + entry.value
    end
    row_entry_counts = zeros(Int, row_count)
    for ((row, _), value) in combined
        iszero(value) || (row_entry_counts[row] += 1)
    end
    global_min = scale.smallest_positive_row_norm
    global_max = scale.largest_finite_row_norm
    families = Dict{String,Any}()
    for family in sort!(unique(labels))
        rows = findall(==(family), labels)
        positive = sort!(T[
            scale.row_norms[row] for row in rows if
            !(row in unavailable) && !(row in nonfinite) &&
            isfinite(scale.row_norms[row]) && scale.row_norms[row] > zero(T)
        ])
        zero_rows = [row for row in rows if
            !(row in unavailable) && !(row in nonfinite) &&
            iszero(scale.row_norms[row])]
        minimum_rows = isnothing(global_min) ? Int[] : [
            row for row in rows if scale.row_norms[row] == global_min
        ]
        maximum_rows = isnothing(global_max) ? Int[] : [
            row for row in rows if scale.row_norms[row] == global_max
        ]
        family_min = isempty(positive) ? nothing : first(positive)
        family_max = isempty(positive) ? nothing : last(positive)
        families[family] = Dict{String,Any}(
            "row_count" => length(rows),
            "finite_positive_row_count" => length(positive),
            "zero_row_count" => length(zero_rows),
            "nonfinite_row_count" => count(row -> row in nonfinite, rows),
            "unavailable_row_count" => count(row -> row in unavailable, rows),
            "combined_nonzero_entry_count" => sum(row_entry_counts[rows]; init = 0),
            "smallest_positive_row_norm" => family_min,
            "row_norm_q25" => _jacobian_scale_quantile(positive, 0.25),
            "row_norm_median" => _jacobian_scale_quantile(positive, 0.5),
            "row_norm_q75" => _jacobian_scale_quantile(positive, 0.75),
            "largest_finite_row_norm" => family_max,
            "row_scale_ratio" => isnothing(family_min) || isnothing(family_max) ?
                nothing : family_max / family_min,
            "owns_global_smallest_positive_row_norm" => !isempty(minimum_rows),
            "owns_global_largest_finite_row_norm" => !isempty(maximum_rows),
            "global_minimum_row_indices" => minimum_rows,
            "global_maximum_row_indices" => maximum_rows,
        )
    end
    return Dict{String,Any}(
        "report_version" => "jacobian-row-family-scale-attribution-v1",
        "point_label" => evaluation.point.label,
        "row_count" => row_count,
        "family_count" => length(families),
        "norm" => string(scale.norm),
        "smallest_positive_row_norm" => global_min,
        "largest_finite_row_norm" => global_max,
        "row_scale_ratio" => scale.row_scale_ratio,
        "global_minimum_families" => sort!([
            family for (family, data) in families if
            get(data, "owns_global_smallest_positive_row_norm", false) === true
        ]),
        "global_maximum_families" => sort!([
            family for (family, data) in families if
            get(data, "owns_global_largest_finite_row_norm", false) === true
        ]),
        "families" => families,
        "interpretation" => "point-local derivative-scale attribution; not causal conditioning evidence",
    )
end

function _jacobian_row_rescaled_evaluation(
    evaluation::NumericalEvaluation{T}, factors::AbstractVector{T},
) where {T<:AbstractFloat}
    length(factors) == length(evaluation.constraint_sources) ||
        throw(ArgumentError("row scale factors must align with evaluated rows"))
    entries = JacobianEntry{T}[
        JacobianEntry{T}(entry.row, entry.column,
                         entry.value * factors[entry.row])
        for entry in evaluation.jacobian_entries
    ]
    return NumericalEvaluation{T}(
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
end

"""
    jacobian_row_family_scaling_experiment(evaluation, row_labels; families)

Run a controlled, point-local sparse-QR experiment in which the nonzero rows
of each requested family are individually normalized to unit infinity norm,
while every other Jacobian row is unchanged. The baseline and perturbed rank
and retained-pivot spread are returned with explicit scale-factor evidence.

This changes only a recorded linearization. It does not rescale the JuMP/MOI
model, change feasibility tolerances, rebuild a KKT system, or invoke a solver.
"""
function jacobian_row_family_scaling_experiment(
    evaluation::NumericalEvaluation{T}, row_labels;
    families,
    relative_tolerance::Real = max(
        length(evaluation.constraint_sources), length(evaluation.point.variables), 1,
    ) * eps(T),
    max_dense_entries::Integer = 100_000,
    max_families::Integer = 8,
) where {T<:AbstractFloat}
    max_families > 0 || throw(ArgumentError("max_families must be positive"))
    labels = _jacobian_row_family_labels(
        row_labels, length(evaluation.constraint_sources),
    )
    requested = unique(string(value isa Symbol ? value : value) for value in families)
    length(requested) <= max_families || throw(ArgumentError(
        "requested $(length(requested)) families exceeds max_families=$max_families",
    ))
    known = Set(labels)
    unknown = sort!([family for family in requested if !(family in known)])
    isempty(unknown) || throw(ArgumentError(
        "unknown row families: $(join(unknown, ", "))",
    ))
    baseline = sparse_qr_rank_estimate(
        evaluation;
        relative_tolerance,
        scaling = :none,
        max_dense_entries,
        provenance = :row_family_scaling_experiment_baseline,
    )
    row_scale = jacobian_scale_summary(evaluation)
    results = Dict{String,Any}()
    for family in requested
        rows = findall(==(family), labels)
        positive_rows = [row for row in rows if
            isfinite(row_scale.row_norms[row]) &&
            row_scale.row_norms[row] > zero(T)]
        zero_rows = [row for row in rows if iszero(row_scale.row_norms[row])]
        nonfinite_rows = [row for row in rows if !isfinite(row_scale.row_norms[row])]
        if isempty(positive_rows)
            results[family] = Dict{String,Any}(
                "available" => false,
                "reason" => "family has no finite positive-norm Jacobian rows",
                "row_count" => length(rows),
                "scaled_row_count" => 0,
                "zero_row_count" => length(zero_rows),
                "nonfinite_row_count" => length(nonfinite_rows),
            )
            continue
        end
        factors = ones(T, length(labels))
        for row in positive_rows
            factors[row] = inv(row_scale.row_norms[row])
        end
        perturbed = sparse_qr_rank_estimate(
            _jacobian_row_rescaled_evaluation(evaluation, factors);
            relative_tolerance,
            scaling = :none,
            max_dense_entries,
            provenance = :row_family_scaling_experiment,
        )
        baseline_proxy = baseline.condition_proxy
        perturbed_proxy = perturbed.condition_proxy
        results[family] = Dict{String,Any}(
            "available" => baseline.available && perturbed.available,
            "reason" => baseline.available && perturbed.available ? nothing :
                something(perturbed.reason, baseline.reason),
            "row_count" => length(rows),
            "scaled_row_count" => length(positive_rows),
            "zero_row_count" => length(zero_rows),
            "nonfinite_row_count" => length(nonfinite_rows),
            "minimum_scale_factor" => minimum(factors[positive_rows]),
            "maximum_scale_factor" => maximum(factors[positive_rows]),
            "baseline_rank" => baseline.available ? baseline.rank : nothing,
            "scaled_rank" => perturbed.available ? perturbed.rank : nothing,
            "rank_delta" => baseline.available && perturbed.available ?
                perturbed.rank - baseline.rank : nothing,
            "baseline_condition_proxy" => baseline_proxy,
            "scaled_condition_proxy" => perturbed_proxy,
            "condition_proxy_ratio" =>
                !isnothing(baseline_proxy) && !isnothing(perturbed_proxy) &&
                baseline_proxy != zero(T) ? perturbed_proxy / baseline_proxy : nothing,
        )
    end
    return Dict{String,Any}(
        "report_version" => "jacobian-row-family-scaling-experiment-v1",
        "point_label" => evaluation.point.label,
        "scaling_intervention" =>
            "normalize requested finite nonzero rows to unit infinity norm",
        "baseline_available" => baseline.available,
        "baseline_rank" => baseline.available ? baseline.rank : nothing,
        "baseline_condition_proxy" => baseline.condition_proxy,
        "relative_tolerance" => baseline.relative_tolerance,
        "families" => results,
        "interpretation" =>
            "controlled recorded-Jacobian scaling experiment; not a model rescale or solver/KKT result",
    )
end

"""
    analyze_jacobian_row_family_perturbations(evaluation, row_labels; kwargs...)

Compare the local Jacobian rank after removing each labelled row family in
turn. `row_labels` may be an aligned vector, or a dictionary keyed by the
one-based evaluation row number. Dictionary values may be strings, symbols, or
metadata dictionaries containing `constraint_family`; this makes the generic
routine usable with domain-plugin row maps without importing their types.

This is a linearized, point-local perturbation. It does not delete constraints
from a model, re-solve the problem, or establish that a family is causally
responsible for a solver failure. A changed rank is evidence about the
recorded Jacobian only.
"""
function analyze_jacobian_row_family_perturbations(
    evaluation::NumericalEvaluation{T},
    row_labels;
    families = nothing,
    scaling::Symbol = :none,
    relative_tolerance::Real = max(
        length(evaluation.constraint_sources), length(evaluation.point.variables), 1,
    ) * eps(T),
    max_dense_entries::Integer = 4_000_000,
) where {T<:AbstractFloat}
    row_count = length(evaluation.constraint_sources)
    labels = _jacobian_row_family_labels(row_labels, row_count)
    unique_labels = sort!(unique(labels))
    if !isnothing(families)
        requested = Set(string(value isa Symbol ? value : value) for value in families)
        unique_labels = [label for label in unique_labels if label in requested]
    end

    report = DiagnosticReport()
    report.metadata[:stage] = "jacobian_row_family_perturbations"
    report.metadata[:evaluation_point_label] = evaluation.point.label
    report.metadata[:row_family_count] = string(length(unique_labels))
    report.metadata[:row_count] = string(row_count)
    report.metadata[:scaling] = string(scaling)
    report.metadata[:relative_tolerance] = string(relative_tolerance)
    report.metadata[:max_dense_entries] = string(max_dense_entries)
    if isempty(unique_labels)
        report.metadata[:baseline_rank_available] = "false"
        report.metadata[:baseline_rank_reason] = "no labelled rows"
        return report
    end

    baseline = jacobian_rank_estimate(evaluation;
        scaling = scaling,
        relative_tolerance = relative_tolerance,
        max_dense_entries = max_dense_entries,
        compute_vectors = false,
    )
    baseline_sparse = sparse_jacobian_pattern_estimate(evaluation)
    report.metadata[:baseline_rank_available] = string(baseline.available)
    report.metadata[:baseline_rank] = baseline.available ? string(baseline.rank) : "unavailable"
    report.metadata[:baseline_left_nullity] = baseline.available ? string(baseline.left_nullity) : "unavailable"
    report.metadata[:baseline_right_nullity] = baseline.available ? string(baseline.right_nullity) : "unavailable"
    if !baseline.available
        report.metadata[:baseline_rank_reason] = something(baseline.reason, "unavailable")
    end
    report.metadata[:baseline_sparse_pattern_available] = string(baseline_sparse.available)
    report.metadata[:baseline_sparse_pattern_rank_upper_bound] =
        baseline_sparse.available ? string(baseline_sparse.rank_upper_bound) : "unavailable"

    for label in unique_labels
        removed = findall(==(label), labels)
        retained = [row for row in 1:row_count if !(row in removed)]
        affected = copy(evaluation.constraint_sources[removed])
        if isempty(retained)
            push!(report, Finding(:jacobian_row_family_perturbation_unavailable;
                severity = SeverityInfo, domain = NumericalIssue,
                basis = NumericalObservation, confidence = ConfidenceHigh,
                observation = "Jacobian family '$label' contains every evaluated row, so the retained perturbation has no rows.",
                why_it_matters = "A zero-row Jacobian cannot distinguish whether the removed family supplied independent equations.",
                evidence = [Evidence("Jacobian family perturbation"; details = [
                    "family" => label, "removed_rows" => length(removed),
                    "retained_rows" => 0, "point" => evaluation.point.label,
                ])], affected = affected,
                suggested_actions = ["Use a point with at least one retained equation family before interpreting family rank effects."],
            ))
            continue
        end
        perturbed = _jacobian_row_subset_evaluation(evaluation, retained)
        estimate = jacobian_rank_estimate(perturbed;
            scaling = scaling,
            relative_tolerance = relative_tolerance,
            max_dense_entries = max_dense_entries,
            compute_vectors = false,
        )
        sparse_estimate = sparse_jacobian_pattern_estimate(perturbed)
        if (!baseline.available || !estimate.available) &&
           baseline_sparse.available && sparse_estimate.available
            rank_delta = sparse_estimate.rank_upper_bound -
                         baseline_sparse.rank_upper_bound
            code = iszero(rank_delta) ?
                :jacobian_row_family_perturbation_sparse_pattern_no_rank_effect :
                :jacobian_row_family_perturbation_sparse_pattern_effect
            push!(report, Finding(code;
                severity = SeverityInfo, domain = NumericalIssue,
                basis = StructuralProof, confidence = ConfidenceMedium,
                observation = iszero(rank_delta) ?
                    "Removing Jacobian row family '$label' leaves the sparse nonzero-pattern rank upper bound unchanged at $(baseline_sparse.rank_upper_bound)." :
                    "Removing Jacobian row family '$label' changes the sparse nonzero-pattern rank upper bound from $(baseline_sparse.rank_upper_bound) to $(sparse_estimate.rank_upper_bound).",
                why_it_matters = "This is a structural perturbation of the observed derivative sparsity pattern used as a guarded fallback when dense numerical rank is unavailable; equality with full dimension does not certify numerical rank.",
                evidence = [Evidence("Sparse Jacobian row-family perturbation"; details = [
                    "family" => label,
                    "removed_rows" => join(removed, ","),
                    "retained_rows" => length(retained),
                    "baseline_rank_upper_bound" => baseline_sparse.rank_upper_bound,
                    "perturbed_rank_upper_bound" => sparse_estimate.rank_upper_bound,
                    "rank_upper_bound_delta" => rank_delta,
                    "baseline_dense_available" => baseline.available,
                    "perturbed_dense_available" => estimate.available,
                    "zero_tolerance" => baseline_sparse.zero_tolerance,
                    "point" => evaluation.point.label,
                ])], affected = affected,
                suggested_actions = [
                    "Treat this as structural pattern evidence and compare with sparse-QR or guarded dense rank on a smaller scope.",
                    "Repeat at another operating point before assigning a physical or causal interpretation.",
                ],
            ))
            continue
        end
        if !baseline.available || !estimate.available
            push!(report, Finding(:jacobian_row_family_perturbation_unavailable;
                severity = SeverityInfo, domain = NumericalIssue,
                basis = NumericalObservation, confidence = ConfidenceHigh,
                observation = "The local Jacobian rank perturbation for family '$label' is unavailable.",
                why_it_matters = "No rank change is inferred when either the baseline or retained Jacobian exceeds the explicit numerical-evidence guard.",
                evidence = [Evidence("Jacobian family perturbation availability"; details = [
                    "family" => label, "removed_rows" => length(removed),
                    "retained_rows" => length(retained),
                    "baseline_available" => baseline.available,
                    "baseline_reason" => something(baseline.reason, ""),
                    "perturbed_available" => estimate.available,
                    "perturbed_reason" => something(estimate.reason, ""),
                ])], affected = affected,
                suggested_actions = ["Increase the explicit dense-rank guard only when the model size makes that safe, or use sparse rank evidence separately."],
            ))
            continue
        end
        rank_delta = estimate.rank - baseline.rank
        left_delta = estimate.left_nullity - baseline.left_nullity
        right_delta = estimate.right_nullity - baseline.right_nullity
        code = iszero(rank_delta) ?
            :jacobian_row_family_perturbation_no_rank_effect :
            :jacobian_row_family_perturbation_rank_effect
        observation = if iszero(rank_delta)
            "Removing Jacobian row family '$label' leaves the estimated local rank unchanged at $(baseline.rank)."
        else
            "Removing Jacobian row family '$label' changes the estimated local rank from $(baseline.rank) to $(estimate.rank)."
        end
        push!(report, Finding(code;
            severity = SeverityInfo, domain = NumericalIssue,
            basis = LocalInference, confidence = ConfidenceMedium,
            observation = observation,
            why_it_matters = "This isolates the contribution of the labelled rows in the recorded local linearization; it is not a model re-solve or a causal proof of redundancy or physical degeneracy.",
            evidence = [Evidence("Controlled Jacobian row-family perturbation"; details = [
                "family" => label,
                "removed_rows" => join(removed, ","),
                "retained_rows" => length(retained),
                "baseline_rank" => baseline.rank,
                "perturbed_rank" => estimate.rank,
                "rank_delta" => rank_delta,
                "baseline_left_nullity" => baseline.left_nullity,
                "perturbed_left_nullity" => estimate.left_nullity,
                "left_nullity_delta" => left_delta,
                "baseline_right_nullity" => baseline.right_nullity,
                "perturbed_right_nullity" => estimate.right_nullity,
                "right_nullity_delta" => right_delta,
                "scaling" => scaling,
                "relative_tolerance" => relative_tolerance,
                "point" => evaluation.point.label,
            ])], affected = affected,
            suggested_actions = [
                "Repeat the perturbation at another operating point and with an explicit scaling convention.",
                "If a causal formulation test is required, rebuild or re-solve a model with this family disabled rather than interpreting this local screen as a deletion experiment.",
            ],
        ))
    end
    report.metadata[:rank_effect_family_count] = string(length(findings(
        report; code = :jacobian_row_family_perturbation_rank_effect,
    )))
    report.metadata[:no_rank_effect_family_count] = string(length(findings(
        report; code = :jacobian_row_family_perturbation_no_rank_effect,
    )))
    report.metadata[:sparse_pattern_effect_family_count] = string(length(findings(
        report; code = :jacobian_row_family_perturbation_sparse_pattern_effect,
    )))
    report.metadata[:sparse_pattern_no_rank_effect_family_count] = string(length(findings(
        report; code = :jacobian_row_family_perturbation_sparse_pattern_no_rank_effect,
    )))
    return report
end

function _jacobian_row_subset_evaluation(
    evaluation::NumericalEvaluation{T}, rows::AbstractVector{<:Integer},
) where {T<:AbstractFloat}
    selected = Int.(rows)
    row_map = Dict(old => new for (new, old) in enumerate(selected))
    entries = JacobianEntry{T}[
        JacobianEntry(row_map[entry.row], entry.column, entry.value)
        for entry in evaluation.jacobian_entries if haskey(row_map, entry.row)
    ]
    return NumericalEvaluation{T}(
        evaluation.point,
        evaluation.objective_value,
        evaluation.objective_source,
        copy(evaluation.objective_gradient),
        copy(evaluation.constraint_values[selected]),
        copy(evaluation.constraint_sources[selected]),
        entries,
        copy(evaluation.jacobian_row_methods[selected]),
        copy(evaluation.capabilities),
        copy(evaluation.failures),
        copy(evaluation.call_statistics),
        evaluation.objective_gradient_method,
    )
end

"""
    analyze_iterative_right_nullspace_probe(evaluation; ...)

Run the explicit sparse-matvec candidate-direction probe and turn its output
into inspectable numerical findings. This is intentionally separate from
`analyze_numerical`: a requested probe dimension is not an inferred nullity,
and a small residual is not a rank or physical-gauge certificate.
"""
function analyze_iterative_right_nullspace_probe(
    evaluation::NumericalEvaluation{T};
    probe_dimension::Integer = 1,
    iterations::Integer = 100,
    convergence_tolerance::Real = sqrt(eps(T)),
    residual_relative_tolerance::Real = sqrt(eps(T)),
    support_relative::Real = 0.1,
    operator::JacobianLinearOperator = jacobian_linear_operator(evaluation),
) where {T<:AbstractFloat}
    probe_dimension > 0 || throw(ArgumentError("probe_dimension must be positive"))
    iterations > 0 || throw(ArgumentError("iterations must be positive"))
    residual_tolerance = convert(T, residual_relative_tolerance)
    isfinite(residual_tolerance) && residual_tolerance >= zero(T) ||
        throw(ArgumentError("residual_relative_tolerance must be finite and nonnegative"))
    zero(T) < support_relative <= one(T) ||
        throw(ArgumentError("support_relative must lie in (0, 1]"))
    probe = iterative_right_nullspace_subspace_estimate(
        evaluation, probe_dimension;
        iterations = iterations,
        convergence_tolerance = convergence_tolerance,
        operator = operator,
    )
    report = DiagnosticReport()
    report.metadata[:stage] = "iterative_right_nullspace_probe"
    report.metadata[:evaluation_point_label] = evaluation.point.label
    report.metadata[:iterative_probe_requested_dimension] = string(probe_dimension)
    report.metadata[:iterative_probe_available] = string(probe.available)
    report.metadata[:iterative_probe_iterations] = string(probe.iterations)
    report.metadata[:iterative_probe_converged] = string(probe.converged)
    report.metadata[:iterative_probe_operator_source] = string(probe.operator_source)
    report.metadata[:iterative_probe_native_operator_unavailable_reason] =
        something(operator.native_unavailable_reason, "")
    report.metadata[:iterative_probe_residual_relative_tolerance] =
        string(residual_tolerance)
    report.metadata[:iterative_probe_support_relative] = string(support_relative)
    if !probe.available
        push!(report, Finding(:iterative_jacobian_nullspace_probe_unavailable;
            severity = SeverityInfo, domain = NumericalIssue,
            basis = NumericalObservation, confidence = ConfidenceHigh,
            observation = "The requested iterative sparse Jacobian candidate-direction probe is unavailable: $(probe.reason).",
            why_it_matters = "No candidate null direction is reported when sparse products or the probe initialization are unavailable.",
            evidence = [_point_evidence(evaluation.point), Evidence("Iterative sparse probe availability"; details = [
                "requested_dimension" => probe_dimension, "reason" => probe.reason,
            ])],
            suggested_actions = ["Resolve incomplete or non-finite Jacobian evidence, or use guarded dense rank analysis when feasible."],
        ))
        return report
    end
    scale_summary = jacobian_scale_summary(evaluation)
    scale = max(one(T), something(scale_summary.largest_finite_row_norm, zero(T)))
    report.metadata[:iterative_probe_residual_scale] = string(scale)
    report.metadata[:iterative_probe_residual_norms] = join(probe.residual_norms, ",")
    report.metadata[:iterative_probe_matrix_norm] = string(probe.matrix_norm)
    report.metadata[:iterative_probe_relative_residual_norms] =
        join(probe.relative_residual_norms, ",")
    reported = 0
    for column in axes(probe.directions, 2)
        direction = view(probe.directions, :, column)
        residual = probe.residual_norms[column]
        relative_residual = probe.relative_residual_norms[column]
        relative_residual <= residual_tolerance || continue
        magnitude = maximum(abs, direction; init = zero(T))
        support = iszero(magnitude) ? Int[] :
                  findall(value -> abs(value) >= T(support_relative) * magnitude, direction)
        variables = evaluation.point.variables[support]
        push!(report, Finding(:iterative_jacobian_candidate_small_residual_direction;
            severity = SeverityInfo, domain = NumericalIssue,
            basis = NumericalObservation,
            confidence = probe.converged ? ConfidenceMedium : ConfidenceLow,
            observation = "Iterative sparse probe direction $column has relative Jacobian residual $relative_residual below the requested threshold $residual_tolerance.",
            why_it_matters = "This is a candidate local small-sensitivity direction only; it does not certify rank deficiency, nullity, or a physical gauge.",
            evidence = [_point_evidence(evaluation.point), Evidence("Iterative sparse candidate direction"; details = [
                "direction" => column, "residual_norm" => residual,
                "residual_scale" => scale, "relative_residual" => relative_residual,
                "matrix_norm" => probe.matrix_norm,
                "relative_residual_definition" => "norm(J*v)/(norm(J)*norm(v))",
                "relative_tolerance" => residual_tolerance,
                "iterations" => probe.iterations, "converged" => probe.converged,
                "support_variables" => join((variable.value for variable in variables), ","),
                "support_relative" => support_relative,
            ])],
            affected = EntityRef[EntityRef(:variable, variable.value) for variable in variables],
            suggested_actions = ["Inspect the listed coordinate support and compare with guarded dense nullspace analysis when feasible.", "Repeat with a documented probe dimension, iteration budget, and scaling convention before drawing formulation conclusions."],
        ))
        reported += 1
    end
    report.metadata[:iterative_probe_small_residual_direction_count] = string(reported)
    if iszero(reported)
        push!(report, Finding(:iterative_jacobian_no_small_residual_direction;
            severity = SeverityInfo, domain = NumericalIssue,
            basis = NumericalObservation, confidence = probe.converged ? ConfidenceMedium : ConfidenceLow,
            observation = "The requested iterative sparse probe found no direction below its relative residual threshold.",
            why_it_matters = "This does not establish local full rank: the finite probe budget and initial subspace can miss small directions.",
            evidence = [_point_evidence(evaluation.point), Evidence("Iterative sparse probe residuals"; details = [
                "residual_norms" => join(probe.residual_norms, ","), "residual_scale" => scale,
                "matrix_norm" => probe.matrix_norm,
                "relative_residual_norms" => join(probe.relative_residual_norms, ","),
                "relative_tolerance" => residual_tolerance, "converged" => probe.converged,
            ])],
            suggested_actions = ["Increase the explicit probe dimension or iteration budget, or use guarded dense rank analysis when feasible."],
        ))
    end
    return report
end

"""
    analyze_iterative_left_nullspace_probe(evaluation; ...)

Run the explicit sparse-matvec candidate-dependency probe and turn its output
into inspectable numerical findings. A small `J' * y` residual is only a
candidate local dependent-equation combination. It does not certify row rank,
redundancy, infeasibility, or a physical interpretation.
"""
function analyze_iterative_left_nullspace_probe(
    evaluation::NumericalEvaluation{T};
    probe_dimension::Integer = 1,
    iterations::Integer = 100,
    convergence_tolerance::Real = sqrt(eps(T)),
    residual_relative_tolerance::Real = sqrt(eps(T)),
    support_relative::Real = 0.1,
    operator::JacobianLinearOperator = jacobian_linear_operator(evaluation),
) where {T<:AbstractFloat}
    probe_dimension > 0 || throw(ArgumentError("probe_dimension must be positive"))
    iterations > 0 || throw(ArgumentError("iterations must be positive"))
    residual_tolerance = convert(T, residual_relative_tolerance)
    isfinite(residual_tolerance) && residual_tolerance >= zero(T) ||
        throw(ArgumentError("residual_relative_tolerance must be finite and nonnegative"))
    zero(T) < support_relative <= one(T) ||
        throw(ArgumentError("support_relative must lie in (0, 1]"))
    probe = iterative_left_nullspace_subspace_estimate(
        evaluation, probe_dimension;
        iterations = iterations,
        convergence_tolerance = convergence_tolerance,
        operator = operator,
    )
    report = DiagnosticReport()
    report.metadata[:stage] = "iterative_left_nullspace_probe"
    report.metadata[:evaluation_point_label] = evaluation.point.label
    report.metadata[:iterative_left_probe_requested_dimension] = string(probe_dimension)
    report.metadata[:iterative_left_probe_available] = string(probe.available)
    report.metadata[:iterative_left_probe_iterations] = string(probe.iterations)
    report.metadata[:iterative_left_probe_converged] = string(probe.converged)
    report.metadata[:iterative_left_probe_operator_source] = string(probe.operator_source)
    report.metadata[:iterative_left_probe_native_operator_unavailable_reason] =
        something(operator.native_unavailable_reason, "")
    report.metadata[:iterative_left_probe_residual_relative_tolerance] =
        string(residual_tolerance)
    report.metadata[:iterative_left_probe_support_relative] = string(support_relative)
    if !probe.available
        push!(report, Finding(:iterative_jacobian_left_nullspace_probe_unavailable;
            severity = SeverityInfo, domain = NumericalIssue,
            basis = NumericalObservation, confidence = ConfidenceHigh,
            observation = "The requested iterative sparse Jacobian candidate-dependency probe is unavailable: $(probe.reason).",
            why_it_matters = "No candidate dependent-equation combination is reported when sparse products or the probe initialization are unavailable.",
            evidence = [_point_evidence(evaluation.point), Evidence("Iterative sparse left probe availability"; details = [
                "requested_dimension" => probe_dimension, "reason" => probe.reason,
            ])],
            suggested_actions = ["Resolve incomplete or non-finite Jacobian evidence, or use guarded dense left-nullspace analysis when feasible."],
        ))
        return report
    end
    scale_summary = jacobian_scale_summary(evaluation)
    scale = max(one(T), something(scale_summary.largest_finite_column_norm, zero(T)))
    report.metadata[:iterative_left_probe_residual_scale] = string(scale)
    report.metadata[:iterative_left_probe_residual_norms] = join(probe.residual_norms, ",")
    report.metadata[:iterative_left_probe_matrix_norm] = string(probe.matrix_norm)
    report.metadata[:iterative_left_probe_relative_residual_norms] =
        join(probe.relative_residual_norms, ",")
    reported = 0
    for column in axes(probe.directions, 2)
        direction = view(probe.directions, :, column)
        residual = probe.residual_norms[column]
        relative_residual = probe.relative_residual_norms[column]
        relative_residual <= residual_tolerance || continue
        magnitude = maximum(abs, direction; init = zero(T))
        support = iszero(magnitude) ? Int[] :
                  findall(value -> abs(value) >= T(support_relative) * magnitude, direction)
        constraints = evaluation.constraint_sources[support]
        push!(report, Finding(:iterative_jacobian_candidate_small_residual_left_direction;
            severity = SeverityInfo, domain = NumericalIssue,
            basis = NumericalObservation,
            confidence = probe.converged ? ConfidenceMedium : ConfidenceLow,
            observation = "Iterative sparse left probe direction $column has relative transposed-Jacobian residual $relative_residual below the requested threshold $residual_tolerance.",
            why_it_matters = "This is a candidate local dependent-equation combination only; it does not certify redundancy, an IIS, row rank, or a physical cause.",
            evidence = [_point_evidence(evaluation.point), Evidence("Iterative sparse candidate left direction"; details = [
                "direction" => column, "residual_norm" => residual,
                "residual_scale" => scale, "relative_residual" => relative_residual,
                "matrix_norm" => probe.matrix_norm,
                "relative_residual_definition" => "norm(J'*u)/(norm(J)*norm(u))",
                "relative_tolerance" => residual_tolerance,
                "iterations" => probe.iterations, "converged" => probe.converged,
                "support_constraints" => join((constraint.index for constraint in constraints), ","),
                "support_relative" => support_relative,
            ])],
            affected = copy(constraints),
            suggested_actions = ["Inspect the listed constraint combination and compare with guarded dense left-nullspace analysis when feasible.", "Repeat with a documented probe dimension, iteration budget, and scaling convention before drawing formulation conclusions."],
        ))
        reported += 1
    end
    report.metadata[:iterative_left_probe_small_residual_direction_count] = string(reported)
    if iszero(reported)
        push!(report, Finding(:iterative_jacobian_no_small_residual_left_direction;
            severity = SeverityInfo, domain = NumericalIssue,
            basis = NumericalObservation, confidence = probe.converged ? ConfidenceMedium : ConfidenceLow,
            observation = "The requested iterative sparse left probe found no direction below its relative transposed-Jacobian residual threshold.",
            why_it_matters = "This does not establish local row independence: the finite probe budget and initial subspace can miss small directions.",
            evidence = [_point_evidence(evaluation.point), Evidence("Iterative sparse left probe residuals"; details = [
                "residual_norms" => join(probe.residual_norms, ","), "residual_scale" => scale,
                "matrix_norm" => probe.matrix_norm,
                "relative_residual_norms" => join(probe.relative_residual_norms, ","),
                "relative_tolerance" => residual_tolerance, "converged" => probe.converged,
            ])],
            suggested_actions = ["Increase the explicit probe dimension or iteration budget, or use guarded dense left-nullspace analysis when feasible."],
        ))
    end
    return report
end

"""
    analyze_iterative_jacobian_spectrum_probe(evaluation; ...)

Turn the explicit iterative sparse spectral-scale probe into evidence-first
findings. The resulting spreads are screening heuristics, never condition
numbers or singular-value bounds.
"""
function analyze_iterative_jacobian_spectrum_probe(
    evaluation::NumericalEvaluation{T};
    probe_dimension::Integer = 1,
    iterations::Integer = 100,
    convergence_tolerance::Real = sqrt(eps(T)),
    spectral_spread_threshold::Real = 1.0e6,
    operator::JacobianLinearOperator = jacobian_linear_operator(evaluation),
) where {T<:AbstractFloat}
    probe_dimension > 0 || throw(ArgumentError("probe_dimension must be positive"))
    iterations > 0 || throw(ArgumentError("iterations must be positive"))
    isfinite(spectral_spread_threshold) && spectral_spread_threshold > 1 ||
        throw(ArgumentError("spectral_spread_threshold must be finite and greater than one"))
    estimate = iterative_jacobian_spectrum_estimate(
        evaluation;
        probe_dimension = probe_dimension,
        iterations = iterations,
        convergence_tolerance = convergence_tolerance,
        operator = operator,
    )
    report = DiagnosticReport()
    report.metadata[:stage] = "iterative_jacobian_spectrum_probe"
    report.metadata[:evaluation_point_label] = evaluation.point.label
    report.metadata[:iterative_spectrum_probe_requested_dimension] = string(probe_dimension)
    report.metadata[:iterative_spectrum_probe_available] = string(estimate.available)
    report.metadata[:iterative_spectrum_probe_iterations] = string(estimate.iterations)
    report.metadata[:iterative_spectrum_probe_operator_source] =
        string(estimate.operator_source)
    report.metadata[:iterative_spectrum_probe_native_operator_unavailable_reason] =
        something(operator.native_unavailable_reason, "")
    report.metadata[:iterative_spectrum_probe_candidate_subspace_converged] = string(estimate.candidate_subspace_converged)
    report.metadata[:iterative_spectrum_probe_candidate_count] = string(length(estimate.candidate_small_singular_values))
    report.metadata[:iterative_spectrum_probe_spread_threshold] =
        string(spectral_spread_threshold)
    if !estimate.available
        push!(report, Finding(:iterative_jacobian_spectrum_probe_unavailable;
            severity = SeverityInfo, domain = NumericalIssue,
            basis = NumericalObservation, confidence = ConfidenceHigh,
            observation = "The requested iterative sparse Jacobian spectral probe is unavailable: $(estimate.reason).",
            why_it_matters = "No spectral-scale screening observation is made without a complete finite sparse-product path.",
            evidence = [_point_evidence(evaluation.point), Evidence("Iterative sparse spectrum availability"; details = [
                "requested_dimension" => probe_dimension, "reason" => estimate.reason,
            ])],
            suggested_actions = ["Resolve incomplete or non-finite Jacobian evidence, or use guarded dense SVD conditioning when feasible."],
        ))
        return report
    end
    report.metadata[:iterative_spectrum_probe_largest_singular_value_proxy] =
        string(estimate.largest_singular_value_proxy)
    report.metadata[:iterative_spectrum_probe_candidate_residuals] =
        join(estimate.candidate_small_singular_values, ",")
    report.metadata[:iterative_spectrum_probe_spreads] = join(estimate.spectral_spread_proxies, ",")
    flagged = 0
    for (index, spread) in enumerate(estimate.spectral_spread_proxies)
        spread > spectral_spread_threshold || continue
        push!(report, Finding(:iterative_jacobian_large_spectral_spread_proxy;
            severity = SeverityWarning, domain = NumericalIssue,
            basis = HeuristicInterpretation, confidence = estimate.candidate_subspace_converged ? ConfidenceMedium : ConfidenceLow,
            observation = "Iterative sparse probe reports spectral-spread proxy $spread for candidate direction $index, above threshold $spectral_spread_threshold.",
            why_it_matters = "The power-scale and small-direction residual suggest a large scale separation, which can make local linear algebra sensitive. This is not a condition-number estimate or a rank conclusion.",
            evidence = [_point_evidence(evaluation.point), Evidence("Iterative sparse spectral spread proxy"; details = [
                "candidate_direction" => index,
                "largest_singular_value_proxy" => estimate.largest_singular_value_proxy,
                "candidate_residual" => estimate.candidate_small_singular_values[index],
                "spectral_spread_proxy" => spread,
                "threshold" => spectral_spread_threshold,
                "iterations" => estimate.iterations,
                "candidate_subspace_converged" => estimate.candidate_subspace_converged,
            ])],
            suggested_actions = ["Inspect Jacobian row/column scaling and run guarded dense conditioning analysis when feasible.", "Use the iterative right-nullspace probe separately if candidate coordinate support is needed."],
        ))
        flagged += 1
    end
    report.metadata[:iterative_spectrum_probe_large_spread_count] = string(flagged)
    if iszero(flagged)
        push!(report, Finding(:iterative_jacobian_no_large_spectral_spread_proxy;
            severity = SeverityInfo, domain = NumericalIssue,
            basis = HeuristicInterpretation, confidence = estimate.candidate_subspace_converged ? ConfidenceMedium : ConfidenceLow,
            observation = "The requested iterative sparse probe reports no spectral-spread proxy above its threshold.",
            why_it_matters = "This finite heuristic probe does not establish good conditioning or full rank.",
            evidence = [_point_evidence(evaluation.point), Evidence("Iterative sparse spectrum proxies"; details = [
                "spreads" => join(estimate.spectral_spread_proxies, ","),
                "threshold" => spectral_spread_threshold,
                "candidate_subspace_converged" => estimate.candidate_subspace_converged,
            ])],
            suggested_actions = ["Increase the explicit probe dimension or iteration budget, or use guarded dense conditioning analysis when feasible."],
        ))
    end
    return report
end

"""
    analyze_golub_kahan_probe(evaluation; steps = 20, kwargs...)

Turn a finite Golub--Kahan projection into evidence-bearing findings. Lifted
Ritz triplets are audited against the full operator. A retained projected-null
direction is reported only when its direct relative residual passes the
caller's threshold; neither its presence nor absence is a rank certificate.
"""
function analyze_golub_kahan_probe(
    evaluation::NumericalEvaluation{T};
    steps::Integer = 20,
    residual_relative_tolerance::Real = sqrt(eps(T)),
    ritz_backward_error_tolerance::Real = sqrt(eps(T)),
    support_relative::Real = 0.1,
    operator::JacobianLinearOperator = jacobian_linear_operator(evaluation),
    kwargs...,
) where {T<:AbstractFloat}
    residual_tolerance = T(residual_relative_tolerance)
    backward_tolerance = T(ritz_backward_error_tolerance)
    isfinite(residual_tolerance) && residual_tolerance >= zero(T) ||
        throw(ArgumentError(
            "residual_relative_tolerance must be finite and nonnegative",
        ))
    isfinite(backward_tolerance) && backward_tolerance >= zero(T) ||
        throw(ArgumentError(
            "ritz_backward_error_tolerance must be finite and nonnegative",
        ))
    zero(T) < support_relative <= one(T) ||
        throw(ArgumentError("support_relative must lie in (0, 1]"))
    estimate = golub_kahan_ritz_estimate(
        evaluation; steps = steps, operator = operator, kwargs...,
    )
    report = DiagnosticReport()
    report.metadata[:stage] = "golub_kahan_ritz_probe"
    report.metadata[:evaluation_point_label] = evaluation.point.label
    report.metadata[:golub_kahan_available] = string(estimate.available)
    report.metadata[:golub_kahan_requested_steps] = string(steps)
    report.metadata[:golub_kahan_completed_steps] = string(estimate.completed_steps)
    report.metadata[:golub_kahan_operator_source] = string(estimate.operator_source)
    report.metadata[:golub_kahan_breakdown] = string(estimate.breakdown)
    report.metadata[:golub_kahan_residual_relative_tolerance] =
        string(residual_tolerance)
    report.metadata[:golub_kahan_ritz_backward_error_tolerance] =
        string(backward_tolerance)
    if !estimate.available
        push!(report, Finding(:golub_kahan_probe_unavailable;
            severity = SeverityInfo, domain = NumericalIssue,
            basis = NumericalObservation, confidence = ConfidenceHigh,
            observation = "The requested Golub--Kahan Jacobian projection is unavailable: $(estimate.reason).",
            why_it_matters = "No Ritz or projected-null evidence is reported without a complete finite product path.",
            evidence = [_point_evidence(evaluation.point), Evidence(
                "Golub--Kahan projection availability"; details = [
                    "requested_steps" => steps, "reason" => estimate.reason,
                ],
            )],
            suggested_actions = ["Resolve incomplete/non-finite derivative evidence or use a guarded dense SVD on a smaller calibration case."],
        ))
        return report
    end
    report.metadata[:golub_kahan_singular_values] =
        join(estimate.singular_values, ",")
    report.metadata[:golub_kahan_ritz_relative_backward_errors] =
        join(estimate.relative_backward_errors, ",")
    report.metadata[:golub_kahan_projection_relative_residual] =
        string(estimate.projection_relative_residual)
    report.metadata[:golub_kahan_left_orthogonality_loss] =
        string(estimate.left_orthogonality_loss)
    report.metadata[:golub_kahan_right_orthogonality_loss] =
        string(estimate.right_orthogonality_loss)
    report.metadata[:golub_kahan_projection_rank_threshold] =
        string(estimate.projection_rank_threshold)

    poor_ritz = findall(error -> error > backward_tolerance,
                        estimate.relative_backward_errors)
    report.metadata[:golub_kahan_large_ritz_backward_error_count] =
        string(length(poor_ritz))
    isempty(poor_ritz) || push!(report, Finding(
        :golub_kahan_ritz_residual_large;
        severity = SeverityWarning, domain = NumericalIssue,
        basis = NumericalObservation, confidence = ConfidenceHigh,
        observation = "$(length(poor_ritz)) lifted Golub--Kahan Ritz triplet(s) exceed the requested direct backward-error threshold.",
        why_it_matters = "Projection singular values with large full-operator residuals are not reliable approximations to Jacobian singular triplets at the current Krylov budget.",
        evidence = [_point_evidence(evaluation.point), Evidence(
            "Lifted Golub--Kahan Ritz residual audit"; details = [
                "indices" => join(poor_ritz, ","),
                "singular_values" => join(estimate.singular_values, ","),
                "primal_residual_norms" => join(estimate.primal_residual_norms, ","),
                "dual_residual_norms" => join(estimate.dual_residual_norms, ","),
                "relative_backward_errors" => join(estimate.relative_backward_errors, ","),
                "relative_backward_error_tolerance" => backward_tolerance,
            ],
        )],
        suggested_actions = ["Increase the explicit Golub--Kahan step budget and compare against dense SVD on a representative smaller matrix."],
    ))

    retained = 0
    for index in axes(estimate.projected_right_null_directions, 2)
        relative_residual =
            estimate.projected_right_null_relative_residual_norms[index]
        relative_residual <= residual_tolerance || continue
        direction = view(estimate.projected_right_null_directions, :, index)
        magnitude = maximum(abs, direction; init = zero(T))
        support = iszero(magnitude) ? Int[] : findall(
            value -> abs(value) >= T(support_relative) * magnitude, direction,
        )
        variables = evaluation.point.variables[support]
        push!(report, Finding(:golub_kahan_projected_right_null_candidate;
            severity = SeverityInfo, domain = NumericalIssue,
            basis = NumericalObservation, confidence = ConfidenceMedium,
            observation = "Golub--Kahan projected-null candidate $index has direct relative Jacobian residual $relative_residual below threshold $residual_tolerance.",
            why_it_matters = "The generated Krylov subspace contains a locally insensitive candidate direction. This finite projection does not establish the full Jacobian's rank or nullity.",
            evidence = [_point_evidence(evaluation.point), Evidence(
                "Golub--Kahan projected-null residual"; details = [
                    "candidate" => index,
                    "residual_norm" => estimate.projected_right_null_residual_norms[index],
                    "relative_residual" => relative_residual,
                    "relative_tolerance" => residual_tolerance,
                    "matrix_norm" => estimate.matrix_norm,
                    "breakdown" => estimate.breakdown,
                    "completed_steps" => estimate.completed_steps,
                    "support_variables" => join(
                        (variable.value for variable in variables), ",",
                    ),
                    "support_relative" => support_relative,
                ],
            )],
            affected = EntityRef[
                EntityRef(:variable, variable.value) for variable in variables
            ],
            suggested_actions = ["Compare the candidate with structural unmatched coordinates, plugin-declared physical modes, and guarded dense SVD when feasible."],
        ))
        retained += 1
    end
    report.metadata[:golub_kahan_projected_right_null_candidate_count] =
        string(size(estimate.projected_right_null_directions, 2))
    report.metadata[:golub_kahan_retained_right_null_candidate_count] =
        string(retained)
    return report
end

"""
    analyze_multi_seed_golub_kahan_probe(evaluation; kwargs...)

Report deterministic cross-seed coverage and consolidated direct-residual
candidate evidence. No finding from this stage certifies rank or nullity.
"""
function analyze_multi_seed_golub_kahan_probe(
    evaluation::NumericalEvaluation{T};
    support_relative::Real = 0.1,
    kwargs...,
) where {T<:AbstractFloat}
    zero(T) < support_relative <= one(T) ||
        throw(ArgumentError("support_relative must lie in (0, 1]"))
    estimate = multi_seed_golub_kahan_estimate(evaluation; kwargs...)
    report = DiagnosticReport()
    report.metadata[:stage] = "multi_seed_golub_kahan_probe"
    report.metadata[:evaluation_point_label] = evaluation.point.label
    report.metadata[:multi_seed_golub_kahan_available] = string(estimate.available)
    report.metadata[:multi_seed_golub_kahan_requested_seed_count] =
        string(estimate.requested_seed_count)
    report.metadata[:multi_seed_golub_kahan_available_seed_count] =
        string(estimate.available_seed_count)
    report.metadata[:multi_seed_golub_kahan_requested_steps] =
        string(estimate.requested_steps)
    report.metadata[:multi_seed_golub_kahan_residual_relative_tolerance] =
        string(estimate.residual_relative_tolerance)
    report.metadata[:multi_seed_golub_kahan_candidate_span_relative_tolerance] =
        string(estimate.candidate_span_relative_tolerance)
    report.metadata[:multi_seed_golub_kahan_estimated_basis_entries] =
        string(estimate.estimated_basis_entries)
    report.metadata[:multi_seed_golub_kahan_max_basis_entries] =
        string(estimate.max_basis_entries)
    if !estimate.available
        push!(report, Finding(:multi_seed_golub_kahan_probe_unavailable;
            severity = SeverityInfo, domain = NumericalIssue,
            basis = NumericalObservation, confidence = ConfidenceHigh,
            observation = "The requested multi-seed Golub--Kahan probe is unavailable: $(estimate.reason).",
            why_it_matters = "No candidate-coverage conclusion is drawn when the operator path or bounded-work contract is unavailable.",
            evidence = [_point_evidence(evaluation.point), Evidence(
                "Multi-seed Golub--Kahan availability"; details = [
                    "reason" => estimate.reason,
                    "estimated_basis_entries" => estimate.estimated_basis_entries,
                    "max_basis_entries" => estimate.max_basis_entries,
                ],
            )],
            suggested_actions = ["Reduce the seed/step budget, raise the explicit storage guard on an appropriate machine, or calibrate a smaller representative matrix."],
        ))
        return report
    end

    report.metadata[:multi_seed_golub_kahan_retained_candidate_counts] =
        join(estimate.retained_candidate_counts, ",")
    report.metadata[:multi_seed_golub_kahan_retained_candidate_count] =
        string(size(estimate.retained_directions, 2))
    report.metadata[:multi_seed_golub_kahan_candidate_span_rank] =
        string(estimate.candidate_span_rank)
    report.metadata[:multi_seed_golub_kahan_candidate_basis_relative_residuals] =
        join(estimate.candidate_basis_relative_residual_norms, ",")
    report.metadata[:multi_seed_golub_kahan_comparable_seed_pair_count] =
        string(estimate.comparable_seed_pair_count)
    report.metadata[:multi_seed_golub_kahan_agreeing_seed_pair_count] =
        string(estimate.agreeing_seed_pair_count)
    report.metadata[:multi_seed_golub_kahan_minimum_pairwise_principal_cosine] =
        string(estimate.minimum_pairwise_principal_cosine)

    if iszero(estimate.candidate_span_rank)
        push!(report, Finding(:multi_seed_golub_kahan_no_retained_candidate;
            severity = SeverityInfo, domain = NumericalIssue,
            basis = NumericalObservation, confidence = ConfidenceHigh,
            observation = "No projected-null direction from $(estimate.available_seed_count) available deterministic seed(s) passed the requested direct-residual screen.",
            why_it_matters = "This records finite-probe coverage only; absence of a retained direction does not establish full rank or exclude a missed null mode.",
            evidence = [_point_evidence(evaluation.point), Evidence(
                "Multi-seed candidate coverage"; details = [
                    "retained_candidate_counts" => join(estimate.retained_candidate_counts, ","),
                    "requested_steps" => estimate.requested_steps,
                    "available_seed_count" => estimate.available_seed_count,
                ],
            )],
            suggested_actions = ["Increase the explicit step or seed budget and compare miss rates with guarded dense SVD on representative smaller matrices."],
        ))
        return report
    end

    row_magnitudes = vec(maximum(abs.(estimate.candidate_basis); dims = 2))
    maximum_magnitude = maximum(row_magnitudes; init = zero(T))
    support = iszero(maximum_magnitude) ? Int[] : findall(
        value -> value >= T(support_relative) * maximum_magnitude,
        row_magnitudes,
    )
    variables = evaluation.point.variables[support]
    push!(report, Finding(:multi_seed_golub_kahan_candidate_span;
        severity = SeverityInfo, domain = NumericalIssue,
        basis = NumericalObservation, confidence = ConfidenceMedium,
        observation = "$(estimate.available_seed_count) deterministic projection(s) retained a consolidated candidate span of dimension $(estimate.candidate_span_rank).",
        why_it_matters = "The span collects locally insensitive directions that passed direct full-operator residual checks. It is finite-budget evidence, not a Jacobian-nullity certificate.",
        evidence = [_point_evidence(evaluation.point), Evidence(
            "Consolidated Golub--Kahan candidate span"; details = [
                "candidate_span_rank" => estimate.candidate_span_rank,
                "retained_candidate_counts" => join(estimate.retained_candidate_counts, ","),
                "basis_relative_residuals" => join(estimate.candidate_basis_relative_residual_norms, ","),
                "span_singular_values" => join(estimate.candidate_span_singular_values, ","),
                "span_threshold" => estimate.candidate_span_threshold,
                "support_variables" => join((variable.value for variable in variables), ","),
            ],
        )],
        affected = EntityRef[
            EntityRef(:variable, variable.value) for variable in variables
        ],
        suggested_actions = ["Compare this candidate span with structural unmatched coordinates, declared physical modes, and dense-SVD calibration evidence where affordable."],
    ))

    if estimate.comparable_seed_pair_count > 0
        stable = estimate.agreeing_seed_pair_count ==
            estimate.comparable_seed_pair_count
        push!(report, Finding(stable ?
            :multi_seed_golub_kahan_candidate_span_stable :
            :multi_seed_golub_kahan_candidate_span_seed_sensitive;
            severity = stable ? SeverityInfo : SeverityWarning,
            domain = NumericalIssue, basis = NumericalObservation,
            confidence = ConfidenceHigh,
            observation = stable ?
                "All $(estimate.comparable_seed_pair_count) comparable nonempty seed pairs agree in dimension and principal-angle threshold." :
                "Only $(estimate.agreeing_seed_pair_count) of $(estimate.comparable_seed_pair_count) comparable nonempty seed pairs agree in dimension and principal-angle threshold.",
            why_it_matters = stable ?
                "Repeated deterministic starts support reproducibility of the finite candidate span, while still not certifying completeness." :
                "Seed sensitivity is direct evidence that the current Krylov budget does not robustly resolve the candidate subspace.",
            evidence = [Evidence("Cross-seed subspace comparison"; details = [
                "comparable_seed_pair_count" => estimate.comparable_seed_pair_count,
                "agreeing_seed_pair_count" => estimate.agreeing_seed_pair_count,
                "minimum_pairwise_principal_cosine" => estimate.minimum_pairwise_principal_cosine,
                "seed_agreement_threshold" => estimate.seed_agreement_threshold,
            ])],
            suggested_actions = stable ?
                ["Retain the direct residuals and validate coverage against dense SVD on the calibration corpus."] :
                ["Increase the step budget before interpreting the candidate span, then rerun the dense-SVD calibration corpus."],
        ))
    end
    return report
end

"""Report a guarded dense-SVD oracle comparison for the multi-seed probe."""
function analyze_golub_kahan_dense_calibration(
    evaluation::NumericalEvaluation{T}; kwargs...,
) where {T<:AbstractFloat}
    calibration = golub_kahan_dense_calibration(evaluation; kwargs...)
    report = DiagnosticReport()
    report.metadata[:stage] = "golub_kahan_dense_calibration"
    report.metadata[:evaluation_point_label] = evaluation.point.label
    report.metadata[:golub_kahan_dense_calibration_available] =
        string(calibration.available)
    report.metadata[:golub_kahan_dense_calibration_relation] =
        string(calibration.relation)
    report.metadata[:golub_kahan_dense_right_nullity] =
        string(calibration.dense_right_nullity)
    report.metadata[:golub_kahan_candidate_span_rank] =
        string(calibration.candidate_span_rank)
    report.metadata[:golub_kahan_dense_detected_fraction] =
        string(calibration.detected_fraction)
    report.metadata[:golub_kahan_dense_minimum_principal_cosine] =
        string(calibration.minimum_principal_cosine)
    if !calibration.available
        push!(report, Finding(:golub_kahan_dense_calibration_unavailable;
            severity = SeverityInfo, domain = NumericalIssue,
            basis = NumericalObservation, confidence = ConfidenceHigh,
            observation = "The dense-SVD Golub--Kahan calibration is unavailable: $(calibration.reason).",
            why_it_matters = "The candidate probe has not been compared with the small-matrix oracle for this evaluation.",
            evidence = [_point_evidence(evaluation.point)],
            suggested_actions = ["Use this calibration only on representative matrices within the explicit dense and Krylov work guards."],
        ))
        return report
    end
    relation = calibration.relation
    adverse = relation in (
        :candidate_miss, :candidate_overcapture,
        :dimension_agreement_subspace_mismatch,
    )
    push!(report, Finding(adverse ?
        :golub_kahan_dense_calibration_disagreement :
        :golub_kahan_dense_calibration_agreement;
        severity = adverse ? SeverityWarning : SeverityInfo,
        domain = NumericalIssue, basis = NumericalObservation,
        confidence = ConfidenceHigh,
        observation = "Under the explicit dense rank policy, the multi-seed candidate comparison is $(relation).",
        why_it_matters = adverse ?
            "This is measured evidence that the current projection budget or threshold semantics do not reproduce the dense small-matrix oracle." :
            "This calibration case agrees under the stated thresholds, contributing bounded evidence about candidate-screen coverage.",
        evidence = [_point_evidence(evaluation.point), Evidence(
            "Dense-SVD versus multi-seed Golub--Kahan"; details = [
                "relation" => relation,
                "dense_right_nullity" => calibration.dense_right_nullity,
                "candidate_span_rank" => calibration.candidate_span_rank,
                "detected_fraction" => calibration.detected_fraction,
                "minimum_principal_cosine" => calibration.minimum_principal_cosine,
                "dense_relative_tolerance" => calibration.dense_estimate.relative_tolerance,
                "dense_absolute_threshold" => calibration.dense_estimate.absolute_threshold,
            ],
        )],
        suggested_actions = adverse ?
            ["Treat the sparse probe as a candidate screen, increase its budget, and record the miss in the calibration ledger."] :
            ["Expand the corpus across scaling, clustered singular values, rectangular shapes, and deliberately insufficient budgets before trusting large-model coverage."],
    ))
    return report
end

function _history_metadata(matrix::AbstractMatrix)
    return join((join(view(matrix, row, :), ",") for row in axes(matrix, 1)), ";")
end

"""
    analyze_restarted_smallest_singular_candidates(evaluation; kwargs...)

Report convergence histories and final direct residual audits for the
matrix-free restarted smallest-direction candidate tracker. Converged results
remain candidates because the normal-operator spectrum is squared and a finite
trial subspace can omit smaller directions.
"""
function analyze_restarted_smallest_singular_candidates(
    evaluation::NumericalEvaluation{T};
    support_relative::Real = 0.1,
    near_null_relative_tolerance::Real = sqrt(eps(T)),
    kwargs...,
) where {T<:AbstractFloat}
    zero(T) < support_relative <= one(T) ||
        throw(ArgumentError("support_relative must lie in (0, 1]"))
    null_tolerance = T(near_null_relative_tolerance)
    isfinite(null_tolerance) && null_tolerance >= zero(T) ||
        throw(ArgumentError(
            "near_null_relative_tolerance must be finite and nonnegative",
        ))
    estimate = restarted_smallest_singular_candidates(evaluation; kwargs...)
    report = DiagnosticReport()
    report.metadata[:stage] = "restarted_smallest_singular_candidates"
    report.metadata[:evaluation_point_label] = evaluation.point.label
    report.metadata[:restarted_smallest_singular_available] =
        string(estimate.available)
    report.metadata[:restarted_smallest_singular_requested_dimension] =
        string(estimate.requested_dimension)
    report.metadata[:restarted_smallest_singular_requested_iterations] =
        string(estimate.requested_iterations)
    report.metadata[:restarted_smallest_singular_completed_iterations] =
        string(estimate.completed_iterations)
    report.metadata[:restarted_smallest_singular_converged] =
        string(estimate.converged)
    report.metadata[:restarted_smallest_singular_breakdown] =
        string(estimate.breakdown)
    report.metadata[:restarted_smallest_singular_operator_source] =
        string(estimate.operator_source)
    report.metadata[:restarted_smallest_singular_estimated_basis_entries] =
        string(estimate.estimated_basis_entries)
    report.metadata[:restarted_smallest_singular_max_basis_entries] =
        string(estimate.max_basis_entries)
    if !estimate.available
        push!(report, Finding(:restarted_smallest_singular_probe_unavailable;
            severity = SeverityInfo, domain = NumericalIssue,
            basis = NumericalObservation, confidence = ConfidenceHigh,
            observation = "The restarted smallest-direction probe is unavailable: $(estimate.reason).",
            why_it_matters = "No candidate is emitted when its product path or bounded-work contract is unavailable.",
            evidence = [_point_evidence(evaluation.point), Evidence(
                "Restarted candidate availability"; details = [
                    "reason" => estimate.reason,
                    "estimated_basis_entries" => estimate.estimated_basis_entries,
                    "max_basis_entries" => estimate.max_basis_entries,
                ],
            )],
            suggested_actions = ["Reduce the requested block dimension, raise the explicit guard on an appropriate machine, or calibrate a smaller matrix."],
        ))
        return report
    end

    report.metadata[:restarted_smallest_singular_values] =
        join(estimate.singular_values, ",")
    report.metadata[:restarted_smallest_singular_relative_normal_residuals] =
        join(estimate.relative_normal_residual_norms, ",")
    report.metadata[:restarted_smallest_singular_triplet_backward_errors] =
        join(estimate.triplet_backward_errors, ",")
    report.metadata[:restarted_smallest_singular_value_histories] =
        _history_metadata(estimate.singular_value_histories)
    report.metadata[:restarted_smallest_singular_normal_residual_histories] =
        _history_metadata(estimate.normal_relative_residual_histories)
    report.metadata[:restarted_smallest_singular_backward_error_histories] =
        _history_metadata(estimate.triplet_backward_error_histories)
    report.metadata[:restarted_smallest_singular_subspace_alignment_history] =
        join(string.(estimate.subspace_alignment_history), ",")
    report.metadata[:restarted_smallest_singular_right_orthogonality_loss] =
        string(estimate.right_orthogonality_loss)

    push!(report, Finding(estimate.converged ?
        :restarted_smallest_singular_candidate_converged :
        :restarted_smallest_singular_candidate_unconverged;
        severity = estimate.converged ? SeverityInfo : SeverityWarning,
        domain = NumericalIssue, basis = NumericalObservation,
        confidence = ConfidenceHigh,
        observation = estimate.converged ?
            "The requested $(estimate.requested_dimension)-direction restarted candidate subspace met its residual and stability policy after $(estimate.completed_iterations) iteration(s)." :
            "The requested restarted candidate subspace stopped as $(estimate.breakdown) after $(estimate.completed_iterations) iteration(s) without meeting its complete convergence policy.",
        why_it_matters = estimate.converged ?
            "This supports stationarity and reproducibility inside the explored trial spaces, but does not prove that no smaller singular direction was omitted." :
            "Unconverged or stagnant candidates must not be interpreted as smallest singular directions, nullspaces, or rank evidence.",
        evidence = [_point_evidence(evaluation.point), Evidence(
            "Restarted candidate convergence"; details = [
                "breakdown" => estimate.breakdown,
                "completed_iterations" => estimate.completed_iterations,
                "convergence_tolerance" => estimate.convergence_tolerance,
                "subspace_alignment_threshold" => estimate.subspace_alignment_threshold,
                "relative_normal_residuals" => join(estimate.relative_normal_residual_norms, ","),
                "subspace_alignment_history" => join(string.(estimate.subspace_alignment_history), ","),
            ],
        )],
        suggested_actions = estimate.converged ?
            ["Compare the candidate values and span against guarded dense SVD on representative small matrices and across scaling policies."] :
            ["Increase the iteration/block budget, inspect the retained history for stagnation, and record dense-oracle misses on a smaller calibration case."],
    ))

    for index in axes(estimate.directions, 2)
        direction = view(estimate.directions, :, index)
        magnitude = maximum(abs, direction; init = zero(T))
        support = iszero(magnitude) ? Int[] : findall(
            value -> abs(value) >= T(support_relative) * magnitude, direction,
        )
        variables = evaluation.point.variables[support]
        push!(report, Finding(:restarted_smallest_singular_candidate;
            severity = SeverityInfo, domain = NumericalIssue,
            basis = NumericalObservation,
            confidence = estimate.converged ? ConfidenceMedium : ConfidenceLow,
            observation = "Restarted candidate $index has Rayleigh singular-value proxy $(estimate.singular_values[index]) and direct triplet backward error $(estimate.triplet_backward_errors[index]).",
            why_it_matters = "This local direction is a reproducible target for solver and formulation experiments only when its convergence, residual, and dense-oracle evidence are considered together.",
            evidence = [_point_evidence(evaluation.point), Evidence(
                "Restarted smallest-direction audit"; details = [
                    "candidate" => index,
                    "singular_value_proxy" => estimate.singular_values[index],
                    "operator_residual_norm" => estimate.operator_residual_norms[index],
                    "relative_operator_residual" => estimate.relative_operator_residual_norms[index],
                    "normal_residual_norm" => estimate.normal_residual_norms[index],
                    "relative_normal_residual" => estimate.relative_normal_residual_norms[index],
                    "triplet_backward_error" => estimate.triplet_backward_errors[index],
                    "matrix_norm" => estimate.matrix_norm,
                    "support_variables" => join((variable.value for variable in variables), ","),
                ],
            )],
            affected = EntityRef[
                EntityRef(:variable, variable.value) for variable in variables
            ],
            suggested_actions = ["Compare this direction with structural freedom, expected physical modes, nearby iterates, and dense calibration before assigning a degeneracy class."],
        ))
        estimate.relative_operator_residual_norms[index] <= null_tolerance ||
            continue
        push!(report, Finding(:restarted_smallest_singular_near_null_candidate;
            severity = SeverityInfo, domain = NumericalIssue,
            basis = NumericalObservation,
            confidence = estimate.converged ? ConfidenceMedium : ConfidenceLow,
            observation = "Restarted candidate $index has direct relative Jacobian residual $(estimate.relative_operator_residual_norms[index]) below $null_tolerance.",
            why_it_matters = "The observed direction is locally insensitive under the stated scaling, but the finite restarted search does not establish Jacobian nullity or completeness.",
            evidence = [_point_evidence(evaluation.point)],
            affected = EntityRef[
                EntityRef(:variable, variable.value) for variable in variables
            ],
            suggested_actions = ["Cross-check the direction against dense SVD or declared physical modes and repeat it at trusted nearby points."],
        ))
    end
    return report
end

function analyze_sparse_qr_nullspace(
    evaluation::NumericalEvaluation{T};
    support_relative::Real = 0.1,
    residual_relative_tolerance::Real = sqrt(eps(T)),
    fill_ratio_warning_threshold::Real = 20,
    kwargs...,
) where {T<:AbstractFloat}
    zero(T) < support_relative <= one(T) || throw(ArgumentError(
        "support_relative must lie in (0, 1]",
    ))
    residual_tolerance = T(residual_relative_tolerance)
    fill_threshold = T(fill_ratio_warning_threshold)
    isfinite(residual_tolerance) && residual_tolerance >= zero(T) ||
        throw(ArgumentError(
            "residual_relative_tolerance must be finite and nonnegative",
        ))
    isfinite(fill_threshold) && fill_threshold > zero(T) ||
        throw(ArgumentError(
            "fill_ratio_warning_threshold must be finite and positive",
        ))
    estimate = sparse_qr_nullspace_estimate(evaluation; kwargs...)
    report = DiagnosticReport()
    report.metadata[:stage] = "sparse_qr_nullspace"
    report.metadata[:evaluation_point_label] = evaluation.point.label
    report.metadata[:sparse_qr_nullspace_available] = string(estimate.available)
    report.metadata[:sparse_qr_nullspace_scaling] = string(estimate.policy.scaling)
    report.metadata[:sparse_qr_nullspace_rank] = string(estimate.rank)
    report.metadata[:sparse_qr_right_nullity] = string(estimate.right_nullity)
    report.metadata[:sparse_qr_nullspace_absolute_threshold] =
        string(estimate.absolute_threshold)
    report.metadata[:sparse_qr_nullspace_relative_residuals] =
        join(estimate.relative_residual_norms, ",")
    report.metadata[:sparse_qr_nullspace_orthogonality_loss] =
        string(estimate.orthogonality_loss)
    report.metadata[:sparse_qr_nullspace_input_nonzeros] =
        string(estimate.input_nonzeros)
    report.metadata[:sparse_qr_nullspace_factor_nonzeros] =
        string(estimate.factor_nonzeros)
    report.metadata[:sparse_qr_nullspace_fill_ratio] =
        string(estimate.fill_ratio)
    report.metadata[:sparse_qr_nullspace_max_input_nonzeros] =
        string(estimate.max_input_nonzeros)
    report.metadata[:sparse_qr_nullspace_max_factor_nonzeros] =
        string(estimate.max_factor_nonzeros)
    report.metadata[:sparse_qr_nullspace_max_nullspace_entries] =
        string(estimate.max_nullspace_entries)
    if !estimate.available
        push!(report, Finding(:sparse_qr_nullspace_unavailable;
            severity = SeverityInfo,
            domain = NumericalIssue,
            basis = NumericalObservation,
            confidence = ConfidenceHigh,
            observation = "The guarded SuiteSparseQR right-nullspace extraction is unavailable: $(estimate.reason).",
            why_it_matters = "No sparse-QR direction or nullity conclusion is emitted outside the explicit input, factor-fill, and basis-storage contracts.",
            evidence = [_point_evidence(evaluation.point), Evidence(
                "Sparse-QR nullspace work guards"; details = [
                    "input_nonzeros" => estimate.input_nonzeros,
                    "factor_nonzeros" => estimate.factor_nonzeros,
                    "max_input_nonzeros" => estimate.max_input_nonzeros,
                    "max_factor_nonzeros" => estimate.max_factor_nonzeros,
                    "max_nullspace_entries" => estimate.max_nullspace_entries,
                ],
            )],
            suggested_actions = [
                "Inspect the recorded guard or factorization reason; raise a budget only for an intentionally bounded case.",
            ],
        ))
        return report
    end
    if iszero(estimate.right_nullity)
        push!(report, Finding(:sparse_qr_no_right_nullspace_under_policy;
            severity = SeverityInfo,
            domain = NumericalIssue,
            basis = NumericalObservation,
            confidence = ConfidenceMedium,
            observation = "SuiteSparseQR retained all $(estimate.columns) Jacobian columns under the declared pivot policy.",
            why_it_matters = "This is tolerance-local full-column-rank evidence, not proof that smaller unresolved singular directions are absent.",
            evidence = [_point_evidence(evaluation.point)],
            suggested_actions = [
                "Use guarded dense SVD or an independent operator method before treating full-column-rank evidence as definitive.",
            ],
        ))
        return report
    end
    maximum_residual = maximum(
        estimate.relative_residual_norms; init = zero(T),
    )
    residuals_pass = maximum_residual <= residual_tolerance
    affected_indices = Set{Int}()
    for direction in eachcol(estimate.directions)
        magnitude = maximum(abs, direction; init = zero(T))
        iszero(magnitude) && continue
        for index in findall(
            value -> abs(value) >= T(support_relative) * magnitude,
            direction,
        )
            push!(affected_indices, index)
        end
    end
    push!(report, Finding(residuals_pass ?
        :sparse_qr_right_nullspace_candidate :
        :sparse_qr_right_nullspace_residual_failure;
        severity = residuals_pass ? SeverityInfo : SeverityWarning,
        domain = NumericalIssue,
        basis = NumericalObservation,
        confidence = residuals_pass ? ConfidenceMedium : ConfidenceHigh,
        observation = "SuiteSparseQR constructed $(estimate.right_nullity) original-coordinate right-nullspace candidate direction(s); the largest direct relative Jacobian residual is $maximum_residual.",
        why_it_matters = residuals_pass ?
            "This is independent rank-revealing-factorization evidence that avoids normal-spectrum squaring, while remaining pivot-threshold and operating-point dependent." :
            "The triangular nullspace construction does not satisfy its direct original-Jacobian audit and must not be interpreted as a nullspace.",
        evidence = [_point_evidence(evaluation.point), Evidence(
            "Sparse-QR right-nullspace audit"; details = [
                "rank" => estimate.rank,
                "right_nullity" => estimate.right_nullity,
                "scaling" => estimate.policy.scaling,
                "pivot_threshold" => estimate.absolute_threshold,
                "relative_residuals" => join(estimate.relative_residual_norms, ","),
                "residual_tolerance" => residual_tolerance,
                "orthogonality_loss" => estimate.orthogonality_loss,
                "input_nonzeros" => estimate.input_nonzeros,
                "factor_nonzeros" => estimate.factor_nonzeros,
                "fill_ratio" => estimate.fill_ratio,
            ],
        )],
        affected = EntityRef[
            EntityRef(:variable, evaluation.point.variables[index].value)
            for index in sort!(collect(affected_indices))
        ],
        suggested_actions = residuals_pass ? [
            "Compare the dimension and span with guarded dense SVD, structural nullity, and the independent smallest-direction engines.",
        ] : [
            "Inspect pivot threshold, scaling, triangular conditioning, and factorization fill before increasing trust.",
        ],
    ))
    if !isnothing(estimate.fill_ratio) && estimate.fill_ratio >= fill_threshold
        push!(report, Finding(:sparse_qr_nullspace_large_factor_fill;
            severity = SeverityWarning,
            domain = NumericalIssue,
            basis = NumericalObservation,
            confidence = ConfidenceHigh,
            observation = "SuiteSparseQR factor fill ratio $(estimate.fill_ratio) exceeds the declared warning threshold $fill_threshold.",
            why_it_matters = "Large fill can make this extraction unsuitable for larger network Jacobians even when the current factorization completed.",
            evidence = [_point_evidence(evaluation.point)],
            suggested_actions = [
                "Retain sparse QR as a bounded representative-case backend and prefer matrix-free methods on larger decks.",
            ],
        ))
    end
    return report
end

function analyze_sparse_qr_nullspace_dense_calibration(
    evaluation::NumericalEvaluation{T}; kwargs...,
) where {T<:AbstractFloat}
    calibration = sparse_qr_nullspace_dense_calibration(
        evaluation; kwargs...,
    )
    report = DiagnosticReport()
    report.metadata[:stage] = "sparse_qr_nullspace_dense_calibration"
    report.metadata[:evaluation_point_label] = evaluation.point.label
    report.metadata[:sparse_qr_nullspace_dense_calibration_available] =
        string(calibration.available)
    report.metadata[:sparse_qr_nullspace_dense_calibration_relation] =
        string(calibration.relation)
    if !calibration.available
        push!(report, Finding(:sparse_qr_nullspace_dense_calibration_unavailable;
            severity = SeverityInfo,
            domain = NumericalIssue,
            basis = NumericalObservation,
            confidence = ConfidenceHigh,
            observation = "Sparse-QR nullspace dense calibration is unavailable: $(calibration.reason).",
            why_it_matters = "No oracle comparison is made unless both guarded backends complete.",
            evidence = [_point_evidence(evaluation.point)],
            suggested_actions = [
                "Use dense calibration only on an explicitly bounded representative Jacobian.",
            ],
        ))
        return report
    end
    report.metadata[:sparse_qr_nullspace_dense_rank] =
        string(calibration.dense_estimate.rank)
    report.metadata[:sparse_qr_nullspace_dense_right_nullity] =
        string(calibration.dense_estimate.right_nullity)
    report.metadata[:sparse_qr_nullspace_dense_minimum_principal_cosine] =
        string(calibration.minimum_principal_cosine)
    report.metadata[:sparse_qr_nullspace_dense_threshold_ambiguous] =
        string(calibration.dense_threshold_ambiguous)
    agreement = calibration.relation in (
        :subspace_agreement,
        :agreement_no_nullspace,
    )
    ambiguous = calibration.relation in (
        :dense_rank_threshold_ambiguous,
        :agreement_no_nullspace_threshold_ambiguous,
    )
    push!(report, Finding(agreement ?
        :sparse_qr_nullspace_dense_calibration_agreement :
        ambiguous ?
            :sparse_qr_nullspace_dense_calibration_ambiguous :
            :sparse_qr_nullspace_dense_calibration_disagreement;
        severity = agreement || ambiguous ? SeverityInfo : SeverityWarning,
        domain = NumericalIssue,
        basis = NumericalObservation,
        confidence = ambiguous ? ConfidenceLow : ConfidenceHigh,
        observation = "The sparse-QR nullspace comparison with guarded dense SVD is $(calibration.relation).",
        why_it_matters = agreement ?
            "Two independent factorizations agree under the stated rank, scaling, subspace, and work policies." :
            ambiguous ?
                "A dense singular value lies near the declared rank threshold, so dimension or span agreement cannot be promoted beyond threshold-sensitive evidence." :
                "The sparse-QR and dense-SVD nullspace evidence disagree under the declared policies.",
        evidence = [_point_evidence(evaluation.point), Evidence(
            "Sparse QR versus dense SVD nullspace"; details = [
                "relation" => calibration.relation,
                "sparse_rank" => calibration.estimate.rank,
                "dense_rank" => calibration.dense_estimate.rank,
                "sparse_right_nullity" => calibration.estimate.right_nullity,
                "dense_right_nullity" => calibration.dense_estimate.right_nullity,
                "minimum_principal_cosine" => calibration.minimum_principal_cosine,
                "dense_threshold_ambiguous" => calibration.dense_threshold_ambiguous,
                "threshold_margin_factor" => calibration.threshold_margin_factor,
            ],
        )],
        suggested_actions = agreement ? [
            "Retain the case in the nullspace oracle corpus and repeat under nearby tolerances and points.",
        ] : [
            "Inspect pivot and singular-value threshold margins, direct residuals, and scaling before choosing either dimension.",
        ],
    ))
    return report
end

function _finite_scaling_extrema(factors::AbstractVector{T}) where {T<:AbstractFloat}
    finite = filter(isfinite, factors)
    isempty(finite) && return (nothing, nothing)
    return (minimum(finite), maximum(finite))
end

function _annotate_smallest_singular_scaling_intervention!(
    report::DiagnosticReport,
    intervention;
    emit_finding::Bool = false,
)
    scaling = intervention.scaling
    row_minimum, row_maximum =
        _finite_scaling_extrema(intervention.row_scaling)
    column_minimum, column_maximum =
        _finite_scaling_extrema(intervention.column_scaling)
    transformed_coordinates = scaling in (:column, :row_column)
    report.metadata[:smallest_singular_backend_crosscheck_scaling] =
        string(scaling)
    report.metadata[:smallest_singular_backend_crosscheck_coordinate_system] =
        transformed_coordinates ? "diagonally_transformed_variables" :
        "original_variables"
    report.metadata[:smallest_singular_backend_crosscheck_row_scaling_minimum] =
        string(row_minimum)
    report.metadata[:smallest_singular_backend_crosscheck_row_scaling_maximum] =
        string(row_maximum)
    report.metadata[:smallest_singular_backend_crosscheck_column_scaling_minimum] =
        string(column_minimum)
    report.metadata[:smallest_singular_backend_crosscheck_column_scaling_maximum] =
        string(column_maximum)
    report.metadata[:smallest_singular_backend_crosscheck_model_modified] = "false"
    if emit_finding && scaling != :none
        push!(report, Finding(
            :smallest_singular_backend_crosscheck_scaling_intervention;
            severity = SeverityInfo,
            domain = RepresentationalIssue,
            basis = NumericalObservation,
            confidence = ConfidenceHigh,
            observation = "The smallest-direction engines were applied to a point-local $scaling diagonally scaled Jacobian.",
            why_it_matters = transformed_coordinates ?
                "Column scaling changes the candidate coordinate metric. Returned spans and singular values are scaled-system evidence and must be mapped and audited before physical interpretation." :
                "Row scaling changes the residual metric. Returned singular values describe the scaled linearization, not solver scaling or a modified model.",
            evidence = [Evidence("Controlled Jacobian scaling intervention"; details = [
                "scaling" => scaling,
                "coordinate_system" => transformed_coordinates ?
                    "diagonally_transformed_variables" : "original_variables",
                "row_factor_minimum" => row_minimum,
                "row_factor_maximum" => row_maximum,
                "column_factor_minimum" => column_minimum,
                "column_factor_maximum" => column_maximum,
                "model_modified" => false,
                "solver_scaling_changed" => false,
            ])],
            suggested_actions = [
                "Compare against the unscaled run at the same point and work budget.",
                "Do not assign a physical mode label from a column-scaled candidate without mapping it to original coordinates and directly auditing the original Jacobian.",
            ],
        ))
    end
    return report
end

"""Report the guarded dense-oracle comparison for restarted candidates."""
function analyze_restarted_smallest_singular_dense_calibration(
    evaluation::NumericalEvaluation{T}; kwargs...,
) where {T<:AbstractFloat}
    calibration = restarted_smallest_singular_dense_calibration(
        evaluation; kwargs...,
    )
    report = DiagnosticReport()
    report.metadata[:stage] = "restarted_smallest_singular_dense_calibration"
    report.metadata[:evaluation_point_label] = evaluation.point.label
    report.metadata[:restarted_dense_calibration_available] =
        string(calibration.available)
    report.metadata[:restarted_dense_calibration_relation] =
        string(calibration.relation)
    if !calibration.available
        push!(report, Finding(:restarted_smallest_singular_dense_calibration_unavailable;
            severity = SeverityInfo, domain = NumericalIssue,
            basis = NumericalObservation, confidence = ConfidenceHigh,
            observation = "The restarted-candidate dense calibration is unavailable: $(calibration.reason).",
            why_it_matters = "No dense-oracle agreement claim is made outside both explicit work guards.",
            evidence = [_point_evidence(evaluation.point)],
            suggested_actions = ["Use dense calibration only on a bounded representative matrix."],
        ))
        return report
    end
    report.metadata[:restarted_dense_singular_values] =
        join(calibration.dense_singular_values, ",")
    report.metadata[:restarted_dense_relative_singular_value_errors] =
        join(calibration.relative_singular_value_errors, ",")
    report.metadata[:restarted_dense_minimum_principal_cosine] =
        string(calibration.minimum_principal_cosine)
    report.metadata[:restarted_dense_target_subspace_unique] =
        string(calibration.dense_target_subspace_unique)
    report.metadata[:restarted_dense_target_numerically_resolved] =
        string(calibration.dense_target_numerically_resolved)
    agreement = calibration.relation in (
        :agreement, :agreement_nonunique_subspace,
    )
    push!(report, Finding(agreement ?
        :restarted_smallest_singular_dense_calibration_agreement :
        :restarted_smallest_singular_dense_calibration_disagreement;
        severity = agreement ? SeverityInfo : SeverityWarning,
        domain = NumericalIssue, basis = NumericalObservation,
        confidence = ConfidenceHigh,
        observation = "The restarted candidate comparison with guarded dense SVD is $(calibration.relation).",
        why_it_matters = agreement ?
            "This adds bounded oracle evidence under explicit value, subspace, and work policies." :
            "The finite restarted search does not reproduce the dense oracle under the stated policies and must remain candidate-only.",
        evidence = [_point_evidence(evaluation.point), Evidence(
            "Restarted candidate versus dense SVD"; details = [
                "relation" => calibration.relation,
                "candidate_values" => join(calibration.estimate.singular_values, ","),
                "dense_values" => join(calibration.dense_singular_values, ","),
                "relative_value_errors" => join(calibration.relative_singular_value_errors, ","),
                "minimum_principal_cosine" => calibration.minimum_principal_cosine,
                "dense_target_subspace_unique" => calibration.dense_target_subspace_unique,
                "dense_target_numerically_resolved" => calibration.dense_target_numerically_resolved,
            ],
        )],
        suggested_actions = agreement ?
            ["Retain this case in the oracle corpus and expand scaling and clustered-spectrum controls."] :
            ["Inspect convergence history, trial-basis rank, scaling sensitivity, and insufficient-budget behavior before increasing trust."],
    ))
    return report
end

"""
    analyze_harmonic_golub_kahan_candidates(evaluation; kwargs...)

Report thick-restarted, zero-target harmonic Golub--Kahan candidates together
with their projected-metric conditioning and direct singular-triplet audits.
The harmonic values are projection evidence; the direct Jacobian residuals are
the quantities used to describe the returned physical-coordinate directions.
"""
function analyze_harmonic_golub_kahan_candidates(
    evaluation::NumericalEvaluation{T};
    support_relative::Real = 0.1,
    near_null_relative_tolerance::Real = sqrt(eps(T)),
    kwargs...,
) where {T<:AbstractFloat}
    zero(T) < support_relative <= one(T) ||
        throw(ArgumentError("support_relative must lie in (0, 1]"))
    null_tolerance = T(near_null_relative_tolerance)
    isfinite(null_tolerance) && null_tolerance >= zero(T) ||
        throw(ArgumentError(
            "near_null_relative_tolerance must be finite and nonnegative",
        ))
    estimate = harmonic_golub_kahan_candidates(evaluation; kwargs...)
    report = DiagnosticReport()
    report.metadata[:stage] = "harmonic_golub_kahan_candidates"
    report.metadata[:evaluation_point_label] = evaluation.point.label
    report.metadata[:harmonic_golub_kahan_available] = string(estimate.available)
    report.metadata[:harmonic_golub_kahan_requested_dimension] =
        string(estimate.requested_dimension)
    report.metadata[:harmonic_golub_kahan_steps_per_seed] =
        string(estimate.steps_per_seed)
    report.metadata[:harmonic_golub_kahan_requested_cycles] =
        string(estimate.requested_cycles)
    report.metadata[:harmonic_golub_kahan_completed_cycles] =
        string(estimate.completed_cycles)
    report.metadata[:harmonic_golub_kahan_retained_dimension] =
        string(estimate.retained_dimension)
    report.metadata[:harmonic_golub_kahan_converged] = string(estimate.converged)
    report.metadata[:harmonic_golub_kahan_breakdown] = string(estimate.breakdown)
    report.metadata[:harmonic_golub_kahan_operator_source] =
        string(estimate.operator_source)
    report.metadata[:harmonic_golub_kahan_estimated_basis_entries] =
        string(estimate.estimated_basis_entries)
    report.metadata[:harmonic_golub_kahan_max_basis_entries] =
        string(estimate.max_basis_entries)
    if !estimate.available
        push!(report, Finding(:harmonic_golub_kahan_probe_unavailable;
            severity = SeverityInfo, domain = NumericalIssue,
            basis = NumericalObservation, confidence = ConfidenceHigh,
            observation = "The harmonic Golub--Kahan probe is unavailable: $(estimate.reason).",
            why_it_matters = "No candidate is emitted when the product path, projected problem, or bounded-work contract is unavailable.",
            evidence = [_point_evidence(evaluation.point), Evidence(
                "Harmonic candidate availability"; details = [
                    "reason" => estimate.reason,
                    "estimated_basis_entries" => estimate.estimated_basis_entries,
                    "max_basis_entries" => estimate.max_basis_entries,
                ],
            )],
            suggested_actions = ["Reduce the trial and retained dimensions, raise the explicit guard on an appropriate machine, or use a bounded calibration matrix."],
        ))
        return report
    end

    report.metadata[:harmonic_golub_kahan_values] =
        join(estimate.harmonic_values, ",")
    report.metadata[:harmonic_golub_kahan_singular_values] =
        join(estimate.singular_values, ",")
    report.metadata[:harmonic_golub_kahan_triplet_backward_errors] =
        join(estimate.triplet_backward_errors, ",")
    report.metadata[:harmonic_golub_kahan_trial_dimensions] =
        join(estimate.trial_dimensions, ",")
    report.metadata[:harmonic_golub_kahan_projected_metric_ranks] =
        join(estimate.projected_metric_ranks, ",")
    report.metadata[:harmonic_golub_kahan_projected_metric_conditions] =
        join(string.(estimate.projected_metric_condition_histories), ",")
    report.metadata[:harmonic_golub_kahan_value_histories] =
        _history_metadata(estimate.singular_value_histories)
    report.metadata[:harmonic_golub_kahan_backward_error_histories] =
        _history_metadata(estimate.triplet_backward_error_histories)
    report.metadata[:harmonic_golub_kahan_subspace_alignment_history] =
        join(string.(estimate.subspace_alignment_history), ",")
    report.metadata[:harmonic_golub_kahan_relative_value_change_history] =
        join(string.(estimate.relative_value_change_history), ",")
    report.metadata[:harmonic_golub_kahan_right_orthogonality_loss] =
        string(estimate.right_orthogonality_loss)

    push!(report, Finding(estimate.converged ?
        :harmonic_golub_kahan_candidate_converged :
        :harmonic_golub_kahan_candidate_unconverged;
        severity = estimate.converged ? SeverityInfo : SeverityWarning,
        domain = NumericalIssue, basis = NumericalObservation,
        confidence = ConfidenceHigh,
        observation = estimate.converged ?
            "The requested $(estimate.requested_dimension)-direction harmonic candidate subspace met its direct residual, value-history, and principal-angle policy after $(estimate.completed_cycles) cycle(s)." :
            "The harmonic candidate search stopped as $(estimate.breakdown) after $(estimate.completed_cycles) cycle(s) without meeting its complete convergence policy.",
        why_it_matters = estimate.converged ?
            "This is independent zero-target projection evidence, but a finite trial space can still omit a smaller singular direction." :
            "An unstable harmonic candidate must not be promoted to a smallest singular direction, nullspace, or rank conclusion.",
        evidence = [_point_evidence(evaluation.point), Evidence(
            "Harmonic convergence and projected metric"; details = [
                "breakdown" => estimate.breakdown,
                "completed_cycles" => estimate.completed_cycles,
                "trial_dimensions" => join(estimate.trial_dimensions, ","),
                "projected_metric_ranks" => join(estimate.projected_metric_ranks, ","),
                "projected_metric_conditions" => join(string.(estimate.projected_metric_condition_histories), ","),
                "triplet_backward_errors" => join(estimate.triplet_backward_errors, ","),
                "subspace_alignment_history" => join(string.(estimate.subspace_alignment_history), ","),
                "relative_value_change_history" => join(string.(estimate.relative_value_change_history), ","),
            ],
        )],
        suggested_actions = estimate.converged ?
            ["Compare this independent candidate span with the locally optimal tracker and guarded dense SVD on representative small models."] :
            ["Increase the cycle, step, or retained-subspace budget and inspect projected-metric conditioning before interpreting the candidate."],
    ))

    for index in axes(estimate.directions, 2)
        direction = view(estimate.directions, :, index)
        magnitude = maximum(abs, direction; init = zero(T))
        support = iszero(magnitude) ? Int[] : findall(
            value -> abs(value) >= T(support_relative) * magnitude,
            direction,
        )
        variables = evaluation.point.variables[support]
        push!(report, Finding(:harmonic_golub_kahan_candidate;
            severity = SeverityInfo, domain = NumericalIssue,
            basis = NumericalObservation,
            confidence = estimate.converged ? ConfidenceMedium : ConfidenceLow,
            observation = "Harmonic candidate $index has projection value $(estimate.harmonic_values[index]), direct singular value $(estimate.singular_values[index]), and triplet backward error $(estimate.triplet_backward_errors[index]).",
            why_it_matters = "Projection and direct audits are retained separately so projected ill-conditioning cannot silently become physical-coordinate evidence.",
            evidence = [_point_evidence(evaluation.point), Evidence(
                "Harmonic smallest-direction audit"; details = [
                    "candidate" => index,
                    "harmonic_projection_value" => estimate.harmonic_values[index],
                    "direct_singular_value" => estimate.singular_values[index],
                    "relative_operator_residual" => estimate.relative_operator_residual_norms[index],
                    "relative_normal_residual" => estimate.relative_normal_residual_norms[index],
                    "triplet_backward_error" => estimate.triplet_backward_errors[index],
                    "support_variables" => join((variable.value for variable in variables), ","),
                ],
            )],
            affected = EntityRef[
                EntityRef(:variable, variable.value) for variable in variables
            ],
            suggested_actions = ["Compare this direction with structural freedom, expected physical modes, scaling variants, and the independent restarted backend."],
        ))
        estimate.relative_operator_residual_norms[index] <= null_tolerance ||
            continue
        push!(report, Finding(:harmonic_golub_kahan_near_null_candidate;
            severity = SeverityInfo, domain = NumericalIssue,
            basis = NumericalObservation,
            confidence = estimate.converged ? ConfidenceMedium : ConfidenceLow,
            observation = "Harmonic candidate $index has direct relative Jacobian residual $(estimate.relative_operator_residual_norms[index]) below $null_tolerance.",
            why_it_matters = "The direction is locally insensitive under the stated scaling, but the finite harmonic search does not establish nullity or completeness.",
            evidence = [_point_evidence(evaluation.point)],
            affected = EntityRef[
                EntityRef(:variable, variable.value) for variable in variables
            ],
            suggested_actions = ["Cross-check against dense SVD or declared physical modes and repeat at trusted nearby points."],
        ))
    end
    return report
end

"""Report the guarded dense-oracle comparison for harmonic candidates."""
function analyze_harmonic_golub_kahan_dense_calibration(
    evaluation::NumericalEvaluation{T}; kwargs...,
) where {T<:AbstractFloat}
    calibration = harmonic_golub_kahan_dense_calibration(
        evaluation; kwargs...,
    )
    report = DiagnosticReport()
    report.metadata[:stage] = "harmonic_golub_kahan_dense_calibration"
    report.metadata[:evaluation_point_label] = evaluation.point.label
    report.metadata[:harmonic_dense_calibration_available] =
        string(calibration.available)
    report.metadata[:harmonic_dense_calibration_relation] =
        string(calibration.relation)
    if !calibration.available
        push!(report, Finding(:harmonic_golub_kahan_dense_calibration_unavailable;
            severity = SeverityInfo, domain = NumericalIssue,
            basis = NumericalObservation, confidence = ConfidenceHigh,
            observation = "The harmonic-candidate dense calibration is unavailable: $(calibration.reason).",
            why_it_matters = "No dense-oracle agreement claim is made outside both explicit work guards.",
            evidence = [_point_evidence(evaluation.point)],
            suggested_actions = ["Use dense calibration only on a bounded representative matrix."],
        ))
        return report
    end
    report.metadata[:harmonic_dense_singular_values] =
        join(calibration.dense_singular_values, ",")
    report.metadata[:harmonic_dense_relative_singular_value_errors] =
        join(calibration.relative_singular_value_errors, ",")
    report.metadata[:harmonic_dense_minimum_principal_cosine] =
        string(calibration.minimum_principal_cosine)
    report.metadata[:harmonic_dense_target_subspace_unique] =
        string(calibration.dense_target_subspace_unique)
    report.metadata[:harmonic_dense_target_numerically_resolved] =
        string(calibration.dense_target_numerically_resolved)
    agreement = calibration.relation in (
        :agreement, :agreement_nonunique_subspace,
    )
    push!(report, Finding(agreement ?
        :harmonic_golub_kahan_dense_calibration_agreement :
        :harmonic_golub_kahan_dense_calibration_disagreement;
        severity = agreement ? SeverityInfo : SeverityWarning,
        domain = NumericalIssue, basis = NumericalObservation,
        confidence = ConfidenceHigh,
        observation = "The harmonic candidate comparison with guarded dense SVD is $(calibration.relation).",
        why_it_matters = agreement ?
            "This adds bounded oracle evidence for the zero-target projection under explicit value, subspace, and work policies." :
            "The finite harmonic search does not reproduce the dense oracle under the stated policies and must remain candidate-only.",
        evidence = [_point_evidence(evaluation.point), Evidence(
            "Harmonic candidate versus dense SVD"; details = [
                "relation" => calibration.relation,
                "candidate_values" => join(calibration.estimate.singular_values, ","),
                "dense_values" => join(calibration.dense_singular_values, ","),
                "relative_value_errors" => join(calibration.relative_singular_value_errors, ","),
                "minimum_principal_cosine" => calibration.minimum_principal_cosine,
                "dense_target_subspace_unique" => calibration.dense_target_subspace_unique,
                "dense_target_numerically_resolved" => calibration.dense_target_numerically_resolved,
            ],
        )],
        suggested_actions = agreement ?
            ["Retain the case in the cross-backend oracle corpus and expand scaling and clustered-spectrum controls."] :
            ["Inspect trial-space growth, projected-metric conditioning, scaling sensitivity, and insufficient-budget behavior."],
    ))
    return report
end

function _mapped_original_candidate_residuals(
    original_evaluation::NumericalEvaluation{T},
    directions::AbstractMatrix{T},
    column_scaling::AbstractVector{<:Real},
) where {T<:AbstractFloat}
    length(column_scaling) == length(original_evaluation.point.variables) ||
        throw(DimensionMismatch(
            "column scaling does not align with original Jacobian columns",
        ))
    size(directions, 1) == length(column_scaling) || throw(DimensionMismatch(
        "candidate directions do not align with column scaling",
    ))
    operator = jacobian_linear_operator(original_evaluation)
    operator.available || return T[], T[]
    matrix_norm = T(_matrix_norm(operator.assembled_matrix, :frobenius))
    residuals = T[]
    mapped_norms = T[]
    for index in axes(directions, 2)
        mapped = T.(column_scaling) .* view(directions, :, index)
        mapped_norm = norm(mapped)
        push!(mapped_norms, mapped_norm)
        if iszero(mapped_norm)
            push!(residuals, T(Inf))
            continue
        end
        mapped ./= mapped_norm
        push!(residuals, _relative_residual(
            norm(jacobian_product(operator, mapped)),
            matrix_norm,
            one(T),
        ))
    end
    return residuals, mapped_norms
end

"""Report the dense-free comparison between independent candidate engines."""
function analyze_smallest_singular_backend_crosscheck(
    evaluation::NumericalEvaluation{T};
    original_evaluation_for_scaled_audit::Union{Nothing,NumericalEvaluation{T}} = nothing,
    column_scaling_for_original_audit::Union{Nothing,AbstractVector{<:Real}} = nothing,
    kwargs...,
) where {T<:AbstractFloat}
    xor(
        isnothing(original_evaluation_for_scaled_audit),
        isnothing(column_scaling_for_original_audit),
    ) && throw(ArgumentError(
        "original_evaluation_for_scaled_audit and column_scaling_for_original_audit must be supplied together",
    ))
    crosscheck = smallest_singular_backend_crosscheck(evaluation; kwargs...)
    report = DiagnosticReport()
    report.metadata[:stage] = "smallest_singular_backend_crosscheck"
    report.metadata[:evaluation_point_label] = evaluation.point.label
    report.metadata[:smallest_singular_backend_crosscheck_available] =
        string(crosscheck.available)
    report.metadata[:smallest_singular_backend_crosscheck_relation] =
        string(crosscheck.relation)
    report.metadata[:smallest_singular_backend_crosscheck_restarted_converged] =
        string(crosscheck.restarted.converged)
    report.metadata[:smallest_singular_backend_crosscheck_harmonic_converged] =
        string(crosscheck.harmonic.converged)
    report.metadata[:smallest_singular_backend_crosscheck_restarted_breakdown] =
        string(crosscheck.restarted.breakdown)
    report.metadata[:smallest_singular_backend_crosscheck_harmonic_breakdown] =
        string(crosscheck.harmonic.breakdown)
    report.metadata[:smallest_singular_backend_crosscheck_restarted_completed_iterations] =
        string(crosscheck.restarted.completed_iterations)
    report.metadata[:smallest_singular_backend_crosscheck_harmonic_completed_cycles] =
        string(crosscheck.harmonic.completed_cycles)
    structural_minimum_right_nullity = max(
        length(evaluation.point.variables) - length(evaluation.constraint_sources), 0,
    )
    requested_dimension = crosscheck.restarted.requested_dimension
    report.metadata[:smallest_singular_backend_crosscheck_structural_minimum_right_nullity] =
        string(structural_minimum_right_nullity)
    report.metadata[:smallest_singular_backend_crosscheck_dimension_covers_structural_minimum] =
        string(requested_dimension >= structural_minimum_right_nullity)
    if requested_dimension < structural_minimum_right_nullity
        push!(report, Finding(
            :smallest_singular_backend_crosscheck_dimension_below_structural_nullity;
            severity = SeverityWarning,
            domain = MathematicalIssue,
            basis = StructuralProof,
            confidence = ConfidenceHigh,
            observation = "The requested candidate dimension $requested_dimension is below the structurally unavoidable right nullity $structural_minimum_right_nullity of this wide Jacobian.",
            why_it_matters = "A lower-dimensional candidate slice cannot cover the full structurally guaranteed nullspace, and its span is non-unique.",
            evidence = [_point_evidence(evaluation.point), Evidence(
                "Rectangular Jacobian dimension bound"; details = [
                    "rows" => length(evaluation.constraint_sources),
                    "columns" => length(evaluation.point.variables),
                    "requested_dimension" => requested_dimension,
                    "structural_minimum_right_nullity" =>
                        structural_minimum_right_nullity,
                ],
            )],
            suggested_actions = [
                "Request at least the columns-minus-rows dimension before comparing a complete right-nullspace candidate span.",
            ],
        ))
    end
    if !crosscheck.available
        push!(report, Finding(:smallest_singular_backend_crosscheck_unavailable;
            severity = SeverityInfo, domain = NumericalIssue,
            basis = NumericalObservation, confidence = ConfidenceHigh,
            observation = "The independent smallest-direction backend crosscheck is unavailable: $(crosscheck.reason).",
            why_it_matters = "No backend-agreement statement is emitted unless both candidate engines complete their bounded product paths.",
            evidence = [_point_evidence(evaluation.point)],
            suggested_actions = ["Reduce the requested budgets or inspect each backend's availability reason."],
        ))
        return report
    end
    report.metadata[:smallest_singular_backend_crosscheck_relative_value_differences] =
        join(crosscheck.relative_singular_value_differences, ",")
    report.metadata[:smallest_singular_backend_crosscheck_restarted_values] =
        join(crosscheck.restarted.singular_values, ",")
    report.metadata[:smallest_singular_backend_crosscheck_harmonic_values] =
        join(crosscheck.harmonic.singular_values, ",")
    report.metadata[:smallest_singular_backend_crosscheck_restarted_backward_errors] =
        join(crosscheck.restarted.triplet_backward_errors, ",")
    report.metadata[:smallest_singular_backend_crosscheck_harmonic_backward_errors] =
        join(crosscheck.harmonic.triplet_backward_errors, ",")
    if !isnothing(original_evaluation_for_scaled_audit)
        original_evaluation_for_scaled_audit.point == evaluation.point ||
            throw(ArgumentError(
                "scaled and original Jacobian evaluations must use the same point",
            ))
        restarted_original_residuals, restarted_mapped_norms =
            _mapped_original_candidate_residuals(
                original_evaluation_for_scaled_audit,
                crosscheck.restarted.directions,
                column_scaling_for_original_audit,
            )
        harmonic_original_residuals, harmonic_mapped_norms =
            _mapped_original_candidate_residuals(
                original_evaluation_for_scaled_audit,
                crosscheck.harmonic.directions,
                column_scaling_for_original_audit,
            )
        report.metadata[:smallest_singular_backend_crosscheck_restarted_original_relative_residuals] =
            join(restarted_original_residuals, ",")
        report.metadata[:smallest_singular_backend_crosscheck_harmonic_original_relative_residuals] =
            join(harmonic_original_residuals, ",")
        report.metadata[:smallest_singular_backend_crosscheck_restarted_mapped_direction_norms] =
            join(restarted_mapped_norms, ",")
        report.metadata[:smallest_singular_backend_crosscheck_harmonic_mapped_direction_norms] =
            join(harmonic_mapped_norms, ",")
        report.metadata[:smallest_singular_backend_crosscheck_original_audit_available] =
            string(
                length(restarted_original_residuals) ==
                    size(crosscheck.restarted.directions, 2) &&
                length(harmonic_original_residuals) ==
                    size(crosscheck.harmonic.directions, 2),
            )
    else
        report.metadata[:smallest_singular_backend_crosscheck_original_audit_available] =
            "false"
    end
    report.metadata[:smallest_singular_backend_crosscheck_minimum_principal_cosine] =
        string(crosscheck.minimum_principal_cosine)
    agreement = crosscheck.relation == :agreement
    convergence_limited = crosscheck.relation in (
        :both_unconverged, :restarted_unconverged, :harmonic_unconverged,
    )
    finding_code = agreement ?
        :smallest_singular_backend_crosscheck_agreement :
        convergence_limited ?
            :smallest_singular_backend_crosscheck_inconclusive :
            :smallest_singular_backend_crosscheck_disagreement
    push!(report, Finding(finding_code;
        severity = agreement || convergence_limited ? SeverityInfo : SeverityWarning,
        domain = NumericalIssue, basis = NumericalObservation,
        confidence = ConfidenceHigh,
        observation = "The restarted normal-operator and zero-target harmonic candidate engines have relation $(crosscheck.relation).",
        why_it_matters = agreement ?
            "Independent finite-search agreement raises confidence in the observed candidate span, but does not prove completeness or rank." :
            convergence_limited ?
                "At least one bounded search did not meet its convergence policy, so candidate values or spans cannot yet be compared as backend disagreement." :
                "Converged backend disagreement is evidence that scaling, spectral compression, or a non-unique target subspace still limits interpretation.",
        evidence = [_point_evidence(evaluation.point), Evidence(
            "Independent smallest-direction backend comparison"; details = [
                "relation" => crosscheck.relation,
                "restarted_converged" => crosscheck.restarted.converged,
                "harmonic_converged" => crosscheck.harmonic.converged,
                "restarted_values" => join(crosscheck.restarted.singular_values, ","),
                "harmonic_values" => join(crosscheck.harmonic.singular_values, ","),
                "relative_value_differences" => join(crosscheck.relative_singular_value_differences, ","),
                "minimum_principal_cosine" => crosscheck.minimum_principal_cosine,
                "original_coordinate_audit_available" => get(report.metadata,
                    :smallest_singular_backend_crosscheck_original_audit_available,
                    "false"),
                "restarted_original_relative_residuals" => get(report.metadata,
                    :smallest_singular_backend_crosscheck_restarted_original_relative_residuals,
                    ""),
                "harmonic_original_relative_residuals" => get(report.metadata,
                    :smallest_singular_backend_crosscheck_harmonic_original_relative_residuals,
                    ""),
                "value_tolerance" => crosscheck.singular_value_relative_tolerance,
                "near_zero_relative_tolerance" => crosscheck.near_zero_relative_tolerance,
                "subspace_alignment_threshold" => crosscheck.subspace_alignment_threshold,
            ],
        )],
        suggested_actions = agreement ?
            ["Validate representative small cases against dense SVD and classify the direction using structural and physical evidence."] :
            convergence_limited ?
                ["Increase the explicit work budget or adjust the declared convergence policy; retain this result as coverage evidence only."] :
                ["Inspect projected conditioning, repeat under explicit scaling policies, and use guarded dense SVD on a smaller representative case."],
    ))
    return report
end

"""
    analyze_iterative_right_nullspace_probe(model, point; cache, relative_step, ...)

Evaluate `model` at `point`, then run the explicit sparse candidate-direction
probe. This is a convenience overload only: it performs numerical evaluation
and never changes the model. Reuse the `NumericalEvaluation` overload when an
iterate has already been captured.
"""
function analyze_iterative_right_nullspace_probe(
    model::MOI.ModelLike,
    point::EvaluationPoint{T};
    cache::EvaluationCache = EvaluationCache(),
    relative_step::Real = cbrt(eps(T)),
    kwargs...,
) where {T<:AbstractFloat}
    evaluation = evaluate_numerical(
        model, point; cache = cache, relative_step = relative_step,
    )
    return analyze_iterative_right_nullspace_probe(
        evaluation;
        operator = jacobian_linear_operator(model, evaluation),
        kwargs...,
    )
end

function analyze_iterative_right_nullspace_probe(
    model::MOI.ModelLike,
    values::Union{AbstractVector{<:Real},AbstractDict{MOI.VariableIndex,<:Real}};
    label::AbstractString = "user",
    kwargs...,
)
    return analyze_iterative_right_nullspace_probe(
        model,
        evaluation_point(model, values; label = label);
        kwargs...,
    )
end

"""
    analyze_iterative_left_nullspace_probe(model, point; cache, relative_step, ...)

Evaluate `model` at `point`, then run the explicit sparse candidate-dependency
probe. This convenience overload is non-mutating. Reuse the
`NumericalEvaluation` overload when an iterate has already been captured.
"""
function analyze_iterative_left_nullspace_probe(
    model::MOI.ModelLike,
    point::EvaluationPoint{T};
    cache::EvaluationCache = EvaluationCache(),
    relative_step::Real = cbrt(eps(T)),
    kwargs...,
) where {T<:AbstractFloat}
    evaluation = evaluate_numerical(
        model, point; cache = cache, relative_step = relative_step,
    )
    return analyze_iterative_left_nullspace_probe(
        evaluation;
        operator = jacobian_linear_operator(model, evaluation),
        kwargs...,
    )
end

function analyze_iterative_left_nullspace_probe(
    model::MOI.ModelLike,
    values::Union{AbstractVector{<:Real},AbstractDict{MOI.VariableIndex,<:Real}};
    label::AbstractString = "user",
    kwargs...,
)
    return analyze_iterative_left_nullspace_probe(
        model,
        evaluation_point(model, values; label = label);
        kwargs...,
    )
end

"""
    analyze_iterative_jacobian_spectrum_probe(model, point; cache, relative_step, ...)

Evaluate `model` at `point`, then run the explicit sparse spectral-scale
probe. The resulting report remains a heuristic screening result, not a
condition-number or rank certificate. Reuse the `NumericalEvaluation`
overload when the point has already been evaluated.
"""
function analyze_iterative_jacobian_spectrum_probe(
    model::MOI.ModelLike,
    point::EvaluationPoint{T};
    cache::EvaluationCache = EvaluationCache(),
    relative_step::Real = cbrt(eps(T)),
    kwargs...,
) where {T<:AbstractFloat}
    evaluation = evaluate_numerical(
        model, point; cache = cache, relative_step = relative_step,
    )
    return analyze_iterative_jacobian_spectrum_probe(
        evaluation;
        operator = jacobian_linear_operator(model, evaluation),
        kwargs...,
    )
end

function analyze_iterative_jacobian_spectrum_probe(
    model::MOI.ModelLike,
    values::Union{AbstractVector{<:Real},AbstractDict{MOI.VariableIndex,<:Real}};
    label::AbstractString = "user",
    kwargs...,
)
    return analyze_iterative_jacobian_spectrum_probe(
        model,
        evaluation_point(model, values; label = label);
        kwargs...,
    )
end

function _iterative_probe_persistence_scale(
    evaluation::NumericalEvaluation{T},
    side::Symbol,
) where {T<:AbstractFloat}
    summary = jacobian_scale_summary(evaluation)
    raw_scale = side == :right ? summary.largest_finite_row_norm :
                summary.largest_finite_column_norm
    return max(one(T), something(raw_scale, zero(T)))
end

function _iterative_probe_persistence_report(
    evaluations::AbstractVector{<:NumericalEvaluation{T}},
    side::Symbol;
    probe_dimension::Integer,
    minimum_evaluations::Integer,
    iterations::Integer,
    convergence_tolerance::Real,
    residual_relative_tolerance::Real,
    subspace_alignment_threshold::Real,
    support_relative::Real,
) where {T<:AbstractFloat}
    side in (:right, :left) || throw(ArgumentError("side must be :right or :left"))
    probe_dimension > 0 || throw(ArgumentError("probe_dimension must be positive"))
    minimum_evaluations >= 2 ||
        throw(ArgumentError("minimum_evaluations must be at least two"))
    iterations > 0 || throw(ArgumentError("iterations must be positive"))
    tolerance = convert(T, residual_relative_tolerance)
    isfinite(tolerance) && tolerance >= zero(T) ||
        throw(ArgumentError("residual_relative_tolerance must be finite and nonnegative"))
    zero(T) <= subspace_alignment_threshold <= one(T) ||
        throw(ArgumentError("subspace_alignment_threshold must lie in [0, 1]"))
    zero(T) < support_relative <= one(T) ||
        throw(ArgumentError("support_relative must lie in (0, 1]"))
    report = DiagnosticReport()
    stage_prefix = side == :right ? "iterative_right_nullspace_persistence" :
                   "iterative_left_nullspace_persistence"
    report.metadata[:stage] = stage_prefix
    report.metadata[:evaluation_count] = string(length(evaluations))
    report.metadata[:minimum_evaluations] = string(minimum_evaluations)
    report.metadata[:probe_dimension] = string(probe_dimension)
    report.metadata[:iterations] = string(iterations)
    report.metadata[:residual_relative_tolerance] = string(tolerance)
    report.metadata[:subspace_alignment_threshold] = string(subspace_alignment_threshold)
    report.metadata[:support_relative] = string(support_relative)
    isempty(evaluations) && return report
    reference_coordinates = side == :right ? first(evaluations).point.variables :
                            first(evaluations).constraint_sources
    if any(
        (side == :right ? evaluation.point.variables : evaluation.constraint_sources) !=
        reference_coordinates for evaluation in evaluations
    )
        push!(report, Finding(
            Symbol(stage_prefix * "_coordinate_mismatch");
            severity = SeverityInfo,
            domain = RepresentationalIssue,
            basis = StructuralProof,
            confidence = ConfidenceCertain,
            observation = "Iterative $(side)-candidate probes do not share one ordered coordinate scope across the supplied evaluations.",
            why_it_matters = "Candidate-subspace persistence requires the same coordinates at every explicitly supplied point.",
            evidence = [Evidence("Iterative candidate-subspace coordinate alignment"; details = [
                "side" => side,
                "evaluation_count" => length(evaluations),
            ])],
            suggested_actions = ["Evaluate the same ordered variables or scalar constraint rows at every point."],
        ))
        return report
    end
    probes = [
        side == :right ?
        iterative_right_nullspace_subspace_estimate(
            evaluation, probe_dimension;
            iterations = iterations, convergence_tolerance = convergence_tolerance,
        ) :
        iterative_left_nullspace_subspace_estimate(
            evaluation, probe_dimension;
            iterations = iterations, convergence_tolerance = convergence_tolerance,
        ) for evaluation in evaluations
    ]
    available_indices = findall(probe -> probe.available, probes)
    report.metadata[:available_evaluation_count] = string(length(available_indices))
    if length(available_indices) < minimum_evaluations
        push!(report, Finding(
            Symbol(stage_prefix * "_unavailable");
            severity = SeverityInfo,
            domain = NumericalIssue,
            basis = NumericalObservation,
            confidence = ConfidenceHigh,
            observation = "Only $(length(available_indices)) supplied evaluation(s) have an available iterative $(side)-candidate probe.",
            why_it_matters = "Persistence cannot be assessed when too few explicitly requested sparse probes have complete finite products.",
            evidence = [Evidence("Iterative candidate-subspace availability"; details = [
                "side" => side,
                "evaluation_count" => length(evaluations),
                "available_evaluation_count" => length(available_indices),
                "minimum_evaluations" => minimum_evaluations,
            ])],
            suggested_actions = ["Resolve derivative availability or repeat at explicitly chosen points with a documented probe budget."],
        ))
        return report
    end
    candidate_subspaces = Matrix{T}[]
    dimensions = Int[]
    converged = Bool[]
    labels = String[]
    supported_coordinates = Set{Int}()
    for index in available_indices
        probe = probes[index]
        evaluation = evaluations[index]
        retained = findall(residual -> residual <= tolerance, probe.relative_residual_norms)
        push!(candidate_subspaces, probe.directions[:, retained])
        push!(dimensions, length(retained))
        push!(converged, probe.converged)
        push!(labels, evaluation.point.label)
        isempty(retained) && continue
        magnitudes = vec(maximum(abs, probe.directions[:, retained]; dims = 2))
        maximum_magnitude = maximum(magnitudes; init = zero(T))
        iszero(maximum_magnitude) && continue
        union!(supported_coordinates, findall(
            magnitude -> magnitude >= T(support_relative) * maximum_magnitude,
            magnitudes,
        ))
    end
    report.metadata[:available_point_labels] = join(labels, ",")
    report.metadata[:candidate_dimensions] = join(dimensions, ",")
    report.metadata[:candidate_probe_converged_count] = string(count(identity, converged))
    report.metadata[:candidate_support_coordinate_count] =
        string(length(supported_coordinates))
    if all(iszero, dimensions)
        push!(report, Finding(
            Symbol(stage_prefix * "_no_small_residual_candidate");
            severity = SeverityInfo,
            domain = NumericalIssue,
            basis = NumericalObservation,
            confidence = all(converged) ? ConfidenceMedium : ConfidenceLow,
            observation = "No available iterative $(side)-candidate probe produced a direction below its relative residual threshold across the supplied points.",
            why_it_matters = "This finite screen does not establish full rank or row independence; it only lacks a retained candidate at the chosen budget.",
            evidence = [Evidence("Iterative candidate-subspace persistence"; details = [
                "side" => side,
                "point_labels" => join(labels, ","),
                "candidate_dimensions" => join(dimensions, ","),
                "relative_tolerance" => tolerance,
            ])],
            suggested_actions = ["Increase the explicit probe dimension or iteration budget, or use guarded dense rank/nullspace analysis when feasible."],
        ))
        return report
    end
    same_dimension = all(==(first(dimensions)), dimensions) && first(dimensions) > 0
    minimum_cosine = zero(T)
    if same_dimension
        minimum_cosine = one(T)
        for left in 1:(length(candidate_subspaces) - 1),
            right in (left + 1):length(candidate_subspaces)
            cosines = svdvals(transpose(candidate_subspaces[left]) * candidate_subspaces[right])
            minimum_cosine = min(minimum_cosine, isempty(cosines) ? zero(T) : minimum(cosines))
        end
    end
    persistent = same_dimension && minimum_cosine >= convert(T, subspace_alignment_threshold)
    report.metadata[:minimum_principal_cosine] = string(minimum_cosine)
    support = sort!(collect(supported_coordinates))
    affected = side == :right ?
               EntityRef[EntityRef(:variable, reference_coordinates[index].value) for index in support] :
               EntityRef[reference_coordinates[index] for index in support]
    push!(report, Finding(
        Symbol(stage_prefix * (persistent ? "_persistent" : "_not_persistent"));
        severity = persistent ? SeverityInfo : SeverityWarning,
        domain = NumericalIssue,
        basis = NumericalObservation,
        confidence = all(converged) ? ConfidenceMedium : ConfidenceLow,
        observation = persistent ?
                      "Iterative $(side)-candidate subspaces have the same retained dimension and align across the supplied points." :
                      "Iterative $(side)-candidate subspaces change dimension or fail the requested alignment threshold across the supplied points.",
        why_it_matters = "This compares finite-probe candidate geometry only; it does not certify rank, nullity, redundancy, or a physical explanation.",
        evidence = [Evidence("Iterative candidate-subspace persistence"; details = [
            "side" => side,
            "point_labels" => join(labels, ","),
            "candidate_dimensions" => join(dimensions, ","),
            "minimum_principal_cosine" => minimum_cosine,
            "alignment_threshold" => subspace_alignment_threshold,
            "relative_tolerance" => tolerance,
            "support_relative" => support_relative,
            "support_coordinates" => join(support, ","),
            "all_probes_converged" => all(converged),
        ])],
        affected = affected,
        suggested_actions = persistent ?
                            ["Compare the repeated candidate support with structural analysis and any plugin-declared expected modes."] :
                            ["Inspect the explicit points, residual thresholds, and scaling before attributing a changing candidate to the model formulation."],
    ))
    return report
end

"""
    analyze_iterative_right_nullspace_persistence(evaluations; ...)

Compare finite-budget candidate right-null subspaces over explicitly supplied
evaluations. This is not a numerical-rank persistence certificate.
"""
function analyze_iterative_right_nullspace_persistence(
    evaluations::AbstractVector{<:NumericalEvaluation{T}};
    probe_dimension::Integer = 1,
    minimum_evaluations::Integer = 2,
    iterations::Integer = 100,
    convergence_tolerance::Real = sqrt(eps(T)),
    residual_relative_tolerance::Real = sqrt(eps(T)),
    subspace_alignment_threshold::Real = 0.98,
    support_relative::Real = 0.1,
) where {T<:AbstractFloat}
    return _iterative_probe_persistence_report(
        evaluations, :right;
        probe_dimension = probe_dimension,
        minimum_evaluations = minimum_evaluations,
        iterations = iterations,
        convergence_tolerance = convergence_tolerance,
        residual_relative_tolerance = residual_relative_tolerance,
        subspace_alignment_threshold = subspace_alignment_threshold,
        support_relative = support_relative,
    )
end

"""
    analyze_iterative_left_nullspace_persistence(evaluations; ...)

Compare finite-budget candidate left-null subspaces over explicitly supplied
evaluations. This is not a dependency, redundancy, or IIS certificate.
"""
function analyze_iterative_left_nullspace_persistence(
    evaluations::AbstractVector{<:NumericalEvaluation{T}};
    probe_dimension::Integer = 1,
    minimum_evaluations::Integer = 2,
    iterations::Integer = 100,
    convergence_tolerance::Real = sqrt(eps(T)),
    residual_relative_tolerance::Real = sqrt(eps(T)),
    subspace_alignment_threshold::Real = 0.98,
    support_relative::Real = 0.1,
) where {T<:AbstractFloat}
    return _iterative_probe_persistence_report(
        evaluations, :left;
        probe_dimension = probe_dimension,
        minimum_evaluations = minimum_evaluations,
        iterations = iterations,
        convergence_tolerance = convergence_tolerance,
        residual_relative_tolerance = residual_relative_tolerance,
        subspace_alignment_threshold = subspace_alignment_threshold,
        support_relative = support_relative,
    )
end

"""
    analyze_iterative_right_nullspace_persistence(model, points; cache, relative_step, ...)

Evaluate one model at explicitly supplied points, then compare finite-budget
candidate right-null subspaces. This convenience method neither chooses nor
modifies points.
"""
function analyze_iterative_right_nullspace_persistence(
    model::MOI.ModelLike,
    points::AbstractVector{<:EvaluationPoint{T}};
    cache::EvaluationCache = EvaluationCache(),
    relative_step::Real = cbrt(eps(T)),
    kwargs...,
) where {T<:AbstractFloat}
    evaluations = NumericalEvaluation{T}[
        evaluate_numerical(model, point; cache = cache, relative_step = relative_step) for
        point in points
    ]
    return analyze_iterative_right_nullspace_persistence(evaluations; kwargs...)
end

"""
    analyze_iterative_left_nullspace_persistence(model, points; cache, relative_step, ...)

Evaluate one model at explicitly supplied points, then compare finite-budget
candidate left-null subspaces. This convenience method neither chooses nor
modifies points.
"""
function analyze_iterative_left_nullspace_persistence(
    model::MOI.ModelLike,
    points::AbstractVector{<:EvaluationPoint{T}};
    cache::EvaluationCache = EvaluationCache(),
    relative_step::Real = cbrt(eps(T)),
    kwargs...,
) where {T<:AbstractFloat}
    evaluations = NumericalEvaluation{T}[
        evaluate_numerical(model, point; cache = cache, relative_step = relative_step) for
        point in points
    ]
    return analyze_iterative_left_nullspace_persistence(evaluations; kwargs...)
end

function _point_evidence(point::EvaluationPoint)
    preview_length = min(length(point.variables), 20)
    variables = point.variables[1:preview_length]
    values = point.values[1:preview_length]
    return Evidence(
        "Numerical evaluation point";
        details = [
            "label" => point.label,
            "provenance_kind" => point.provenance.kind,
            "provenance_source" => point.provenance.source,
            "provenance_complete" => point.provenance.complete,
            "provenance_metadata" => join(
                ("$(key)=$(value)" for (key, value) in sort!(collect(point.provenance.metadata); by = first)),
                ",",
            ),
            "variable_count" => length(point.variables),
            "variable_order_preview" =>
                join((variable.value for variable in variables), ","),
            "value_preview" => join(values, ","),
            "preview_truncated" =>
                preview_length < length(point.variables),
        ],
    )
end

function _apply_point_provenance_guard!(
    report::DiagnosticReport,
    point::EvaluationPoint,
)
    limited = point.provenance.kind in
              (SyntheticSmokePoint, CompletedInitializationPoint) ||
              !point.provenance.complete
    limited || return report
    guarded = 0
    for index in eachindex(report.findings)
        finding = report.findings[index]
        finding.domain == PhysicalIssue || continue
        any(evidence -> evidence.summary == "Numerical evaluation point", finding.evidence) ||
            continue
        any(
            evidence -> evidence.summary ==
                        "Evaluation-point provenance confidence guard",
            finding.evidence,
        ) && continue
        report.findings[index] = Finding(
            finding.code;
            severity = finding.severity,
            domain = finding.domain,
            basis = HeuristicInterpretation,
            confidence = ConfidenceLow,
            observation = finding.observation,
            why_it_matters = finding.why_it_matters,
            evidence = vcat(
                finding.evidence,
                [Evidence("Evaluation-point provenance confidence guard"; details = [
                    "kind" => point.provenance.kind,
                    "source" => point.provenance.source,
                    "complete" => point.provenance.complete,
                ])],
            ),
            suggested_actions = unique(vcat(
                finding.suggested_actions,
                ["Repeat the physical interpretation at a complete initialization, solver iterate, or solver-result point."],
            )),
            affected = finding.affected,
        )
        guarded += 1
    end
    existing_guarded = try
        parse(
            Int,
            get(
                report.metadata,
                :evaluation_point_physical_confidence_guarded_count,
                "0",
            ),
        )
    catch
        0
    end
    total_guarded = existing_guarded + guarded
    report.metadata[:evaluation_point_physical_confidence_guarded_count] =
        string(total_guarded)
    if guarded > 0
        filter!(
            finding -> finding.code !=
                       :physical_interpretation_limited_by_point_provenance,
            report.findings,
        )
        push!(report, Finding(
            :physical_interpretation_limited_by_point_provenance;
            severity = SeverityInfo,
            domain = RepresentationalIssue,
            basis = StructuralProof,
            confidence = ConfidenceCertain,
            observation = "$total_guarded point-local physical finding(s) were limited to low-confidence heuristic evidence because the evaluation point is synthetic, artificially completed, or incomplete.",
            why_it_matters = "A complete coordinate vector is not necessarily a physically meaningful initialization or operating point.",
            evidence = [_point_evidence(point)],
            suggested_actions = ["Repeat at a complete initialization, captured solver iterate, or solver result before assigning physical confidence."],
        ))
    end
    return report
end

function _operating_point_domain_issues(
    model_snapshot::ModelSnapshot,
    point::EvaluationPoint,
)
    intervals = Dict(
        variable => IntervalEnclosure(value, value, true, true) for
        (variable, value) in zip(point.variables, point.values)
    )
    issues = ExpressionDomainIssue[]
    if !isnothing(model_snapshot.objective)
        objective = model_snapshot.objective
        source = _objective_ref(objective.function_value)
        _source_domain_issues!(
            issues,
            objective.function_value,
            source,
            intervals;
            skip_constant_source = false,
        )
    end
    for constraint in model_snapshot.constraints
        constraint.set_value isa MOI.VectorNonlinearOracle && continue
        rows = try
            _scalar_rows(constraint.function_value)
        catch
            continue
        end
        for (row, function_value) in enumerate(rows)
            source = _constraint_ref(
                constraint;
                row = length(rows) == 1 ? nothing : row,
            )
            _source_domain_issues!(
                issues,
                function_value,
                source,
                intervals;
                skip_constant_source = false,
            )
        end
    end
    return filter(
        issue -> issue.assessment == DomainProvenViolation,
        issues,
    )
end

function _operating_point_domain_findings(
    model_snapshot::ModelSnapshot,
    evaluation::NumericalEvaluation,
)
    findings = Finding[]
    variable_records =
        Dict(record.index => record for record in model_snapshot.variables)
    for issue in _operating_point_domain_issues(
        model_snapshot,
        evaluation.point,
    )
        affected = EntityRef[issue.path.source]
        for variable in issue.variables
            if haskey(variable_records, variable)
                push!(affected, _variable_ref(variable_records[variable]))
            end
        end
        push!(
            findings,
            Finding(
                :operating_point_domain_violation;
                severity = SeverityError,
                domain = MathematicalIssue,
                basis = MathematicalProof,
                confidence = ConfidenceCertain,
                observation = "Expression $(_path_string(issue.path)) violates $(issue.requirement) at point \"$(evaluation.point.label)\".",
                why_it_matters = "The real-valued expression is undefined at this exact operating point, independently of solver choice.",
                evidence = [
                    _point_evidence(evaluation.point),
                    Evidence(
                        "Exact-point operator-domain check";
                        details = [
                            "path" => _path_string(issue.path),
                            "operator" => issue.operator,
                            "argument" => issue.argument,
                            "required_domain" => issue.requirement,
                            "argument_value" => issue.enclosure.lower,
                        ],
                    ),
                ],
                suggested_actions = [
                    "Choose a domain-valid initialization if this point is only a starting guess.",
                    "Correct the formulation or data if this point is intended to be admissible.",
                ],
                affected = affected,
            ),
        )
    end
    return findings
end

function _nonfinite_value_findings(evaluation::NumericalEvaluation)
    findings = Finding[]
    if !isnothing(evaluation.objective_value) &&
       !ismissing(evaluation.objective_value) &&
       !isfinite(evaluation.objective_value)
        push!(
            findings,
            Finding(
                :nonfinite_objective_value;
                severity = SeverityError,
                domain = NumericalIssue,
                basis = NumericalObservation,
                confidence = ConfidenceCertain,
                observation = "The objective evaluated to $(evaluation.objective_value) at point \"$(evaluation.point.label)\".",
                why_it_matters = "Non-finite function values prevent reliable merit-function and convergence calculations.",
                evidence = [_point_evidence(evaluation.point)],
                suggested_actions = [
                    "Inspect the objective expression and input values at this exact point.",
                    "Check operator domains, overflow, and units before solving.",
                ],
                affected = isnothing(evaluation.objective_source) ?
                           EntityRef[] :
                           [evaluation.objective_source],
            ),
        )
    end
    nonfinite_gradient_columns = findall(
        value -> !ismissing(value) && !isfinite(value),
        evaluation.objective_gradient,
    )
    if !isempty(nonfinite_gradient_columns)
        affected = EntityRef[
            EntityRef(
                :variable,
                evaluation.point.variables[column].value,
            ) for column in nonfinite_gradient_columns
        ]
        isnothing(evaluation.objective_source) ||
            pushfirst!(affected, evaluation.objective_source)
        push!(
            findings,
            Finding(
                :nonfinite_objective_gradient;
                severity = SeverityError,
                domain = NumericalIssue,
                basis = NumericalObservation,
                confidence = ConfidenceCertain,
                observation = "The objective gradient contains non-finite entries in $(length(nonfinite_gradient_columns)) columns.",
                why_it_matters = "Non-finite objective derivatives make first-order steps and stationarity tests unreliable.",
                evidence = [
                    _point_evidence(evaluation.point),
                    Evidence(
                        "Non-finite objective-gradient locations";
                        details = [
                            "columns" =>
                                join(nonfinite_gradient_columns, ","),
                        ],
                    ),
                ],
                suggested_actions = [
                    "Inspect the objective and affected variables at the recorded point.",
                    "Check operator domains, overflow, and derivative callback implementations.",
                ],
                affected = affected,
            ),
        )
    end
    for (row, value) in enumerate(evaluation.constraint_values)
        (ismissing(value) || isfinite(value)) && continue
        source = evaluation.constraint_sources[row]
        push!(
            findings,
            Finding(
                :nonfinite_constraint_value;
                severity = SeverityError,
                domain = NumericalIssue,
                basis = NumericalObservation,
                confidence = ConfidenceCertain,
                observation = "Constraint row $row evaluated to $value at point \"$(evaluation.point.label)\".",
                why_it_matters = "Non-finite residuals prevent meaningful feasibility and line-search calculations.",
                evidence = [
                    _point_evidence(evaluation.point),
                    Evidence(
                        "Non-finite constraint value";
                        details = ["row" => row, "value" => value],
                    ),
                ],
                suggested_actions = [
                    "Inspect the affected expression and its inputs at this exact point.",
                    "Check operator domains, overflow, and physical units.",
                ],
                affected = [source],
            ),
        )
    end
    nonfinite_entries = filter(
        entry -> !isfinite(entry.value),
        evaluation.jacobian_entries,
    )
    if !isempty(nonfinite_entries)
        rows = sort!(unique(entry.row for entry in nonfinite_entries))
        columns = sort!(unique(entry.column for entry in nonfinite_entries))
        affected = EntityRef[evaluation.constraint_sources[row] for row in rows]
        append!(
            affected,
            EntityRef[
                EntityRef(:variable, evaluation.point.variables[column].value) for
                column in columns
            ],
        )
        push!(
            findings,
            Finding(
                :nonfinite_jacobian_entries;
                severity = SeverityError,
                domain = NumericalIssue,
                basis = NumericalObservation,
                confidence = ConfidenceCertain,
                observation = "The Jacobian contains $(length(nonfinite_entries)) non-finite raw sparse entries.",
                why_it_matters = "Non-finite derivatives make linearized steps and scaling calculations unreliable.",
                evidence = [
                    _point_evidence(evaluation.point),
                    Evidence(
                        "Non-finite derivative locations";
                        details = [
                            "rows" => join(rows, ","),
                            "columns" => join(columns, ","),
                        ],
                    ),
                ],
                suggested_actions = [
                    "Inspect the affected functions and variables at the recorded point.",
                    "Compare exact and finite-difference derivatives where both are available.",
                ],
                affected = affected,
            ),
        )
    end
    return findings
end

function _jacobian_derivative_provenance_findings(
    evaluation::NumericalEvaluation,
)
    methods = evaluation.jacobian_row_methods
    unique_methods = sort!(unique!(copy(methods)); by = string)
    findings = Finding[]
    if length(unique_methods) > 1
        push!(findings, Finding(
            :mixed_jacobian_derivative_provenance;
            severity = SeverityInfo,
            domain = RepresentationalIssue,
            basis = NumericalObservation,
            confidence = ConfidenceHigh,
            observation = "The evaluated Jacobian combines $(length(unique_methods)) derivative methods across $(length(methods)) row(s).",
            why_it_matters = "Rank, nullspace, conditioning, and scaling findings use all evaluated rows. Mixed derivative paths can have different accuracy, sparsity, and failure semantics, especially near numerical thresholds.",
            evidence = [
                _point_evidence(evaluation.point),
                Evidence("Jacobian derivative provenance"; details = [
                    "methods" => join(unique_methods, ","),
                    "row_methods" => join(methods, ","),
                ]),
            ],
            affected = copy(evaluation.constraint_sources),
            suggested_actions = [
                "Compare consequential rank or conditioning conclusions using one verified derivative path.",
                "Inspect row-level derivative provenance before interpreting marginal numerical findings.",
            ],
        ))
    end
    finite_difference_rows = findall(==(:central_finite_difference), methods)
    if !isempty(finite_difference_rows)
        push!(findings, Finding(
            :finite_difference_jacobian_derivatives;
            severity = SeverityInfo,
            domain = NumericalIssue,
            basis = NumericalObservation,
            confidence = ConfidenceHigh,
            observation = "The evaluated Jacobian uses complete central finite-difference derivatives for $(length(finite_difference_rows)) row(s).",
            why_it_matters = "Numerical rank, nullspace, conditioning, and scaling observations for these rows depend on the finite-difference step and evaluation stability. This is provenance, not a model defect.",
            evidence = [
                _point_evidence(evaluation.point),
                Evidence("Jacobian derivative provenance"; details = [
                    "finite_difference_rows" => join(finite_difference_rows, ","),
                    "methods" => join(methods, ","),
                ]),
            ],
            affected = evaluation.constraint_sources[finite_difference_rows],
            suggested_actions = [
                "Vary the finite-difference step and compare the numerical conclusion.",
                "Provide exact or automatic-differentiation derivatives when possible.",
            ],
        ))
    end
    partial_rows = findall(==(:partial_central_finite_difference), methods)
    if !isempty(partial_rows)
        push!(findings, Finding(
            :partial_finite_difference_jacobian_derivatives;
            severity = SeverityWarning,
            domain = NumericalIssue,
            basis = NumericalObservation,
            confidence = ConfidenceHigh,
            observation = "The evaluated Jacobian has incomplete central finite-difference derivatives for $(length(partial_rows)) row(s).",
            why_it_matters = "Missing derivative coordinates must not be treated as zeros. Rank and scaling conclusions may be unavailable or incomplete at this point.",
            evidence = [
                _point_evidence(evaluation.point),
                Evidence("Jacobian derivative provenance"; details = [
                    "partial_finite_difference_rows" => join(partial_rows, ","),
                    "methods" => join(methods, ","),
                ]),
            ],
            affected = evaluation.constraint_sources[partial_rows],
            suggested_actions = [
                "Resolve the derivative-domain or finite-difference step failure before interpreting numerical geometry.",
                "Provide exact or automatic-differentiation derivatives when possible.",
            ],
        ))
    end
    objective_method = evaluation.objective_gradient_method
    if objective_method == :central_finite_difference ||
       objective_method == :partial_central_finite_difference
        partial = objective_method == :partial_central_finite_difference
        push!(findings, Finding(
            partial ? :partial_finite_difference_objective_gradient :
                      :finite_difference_objective_gradient;
            severity = partial ? SeverityWarning : SeverityInfo,
            domain = NumericalIssue,
            basis = NumericalObservation,
            confidence = ConfidenceHigh,
            observation = partial ?
                          "The objective gradient has incomplete central finite-difference entries." :
                          "The objective gradient uses complete central finite differences.",
            why_it_matters = partial ?
                             "Missing objective derivative coordinates must not be treated as zeros; stationarity and multiplier evidence can be unavailable or incomplete." :
                             "Objective-gradient and stationarity observations depend on the finite-difference step and evaluation stability. This is derivative provenance, not a model defect.",
            evidence = [
                _point_evidence(evaluation.point),
                Evidence("Objective-gradient derivative provenance"; details = [
                    "method" => objective_method,
                ]),
            ],
            affected = isnothing(evaluation.objective_source) ?
                       EntityRef[] : [evaluation.objective_source],
            suggested_actions = partial ?
                                [
                "Resolve the derivative-domain or finite-difference step failure before interpreting stationarity.",
                "Provide exact or automatic-differentiation objective derivatives when possible.",
            ] :
                                [
                "Vary the finite-difference step and compare stationarity conclusions.",
                "Provide exact or automatic-differentiation objective derivatives when possible.",
            ],
        ))
    end
    return findings
end

function _evaluation_failure_findings(evaluation::NumericalEvaluation)
    findings = Finding[]
    for failure in evaluation.failures
        domain_error = occursin("DomainError", failure.exception_type)
        push!(
            findings,
            Finding(
                domain_error ?
                :operating_point_domain_violation :
                :numerical_evaluation_failed;
                severity = domain_error ? SeverityError : SeverityWarning,
                domain = domain_error ? MathematicalIssue : NumericalIssue,
                basis = NumericalObservation,
                confidence = domain_error ?
                             ConfidenceCertain :
                             ConfidenceHigh,
                observation = domain_error ?
                              "Evaluation encountered an operator-domain error at point \"$(evaluation.point.label)\"." :
                              "Numerical stage $(failure.stage) failed for source $(failure.source).",
                why_it_matters = domain_error ?
                                 "The model is not real-valued at this operating point." :
                                 "The affected numerical evidence is unavailable and downstream conclusions must exclude it.",
                evidence = [
                    _point_evidence(evaluation.point),
                    Evidence(
                        "Captured evaluation exception";
                        details = [
                            "stage" => failure.stage,
                            "source" => failure.source,
                            "exception_type" => failure.exception_type,
                            "message" => failure.message,
                        ],
                    ),
                ],
                suggested_actions = domain_error ?
                                    [
                    "Inspect the affected operator and arguments at the recorded point.",
                    "Choose a domain-valid initialization or correct the formulation.",
                ] :
                                    [
                    "Inspect the callback exception and advertised evaluator capabilities.",
                    "Do not interpret missing values or derivatives as structural zeros.",
                ],
                affected = [failure.affected],
            ),
        )
    end
    return findings
end

function _scale_findings(
    evaluation::NumericalEvaluation,
    summary::JacobianScaleSummary;
    scale_ratio_threshold::Real,
)
    findings = Finding[]
    point_evidence = _point_evidence(evaluation.point)
    if !isempty(summary.zero_rows)
        affected = EntityRef[
            evaluation.constraint_sources[row] for row in summary.zero_rows
        ]
        push!(
            findings,
            Finding(
                :zero_jacobian_rows;
                severity = SeverityWarning,
                domain = NumericalIssue,
                basis = LocalInference,
                confidence = ConfidenceHigh,
                observation = "$(length(summary.zero_rows)) constraint rows have zero evaluated Jacobian infinity norm.",
                why_it_matters = "A locally flat constraint row may indicate a constant equation, a stationary nonlinear expression, or a singular active set.",
                evidence = [
                    point_evidence,
                    Evidence(
                        "Evaluated Jacobian row norms";
                        details = [
                            "norm" => summary.norm,
                            "rows" => join(summary.zero_rows, ","),
                        ],
                    ),
                ],
                suggested_actions = [
                    "Inspect whether each zero row is expected at this operating point.",
                    "Compare with structural incidence before concluding that a row is redundant.",
                ],
                affected = affected,
            ),
        )
    end
    if !isempty(summary.zero_columns)
        affected = EntityRef[
            EntityRef(:variable, evaluation.point.variables[column].value) for
            column in summary.zero_columns
        ]
        push!(
            findings,
            Finding(
                :zero_jacobian_columns;
                severity = SeverityWarning,
                domain = NumericalIssue,
                basis = LocalInference,
                confidence = ConfidenceHigh,
                observation = "$(length(summary.zero_columns)) variable columns have zero evaluated Jacobian infinity norm.",
                why_it_matters = "A locally invisible variable direction may represent a degree of freedom, a stationary point, or missing derivative evidence.",
                evidence = [
                    point_evidence,
                    Evidence(
                        "Evaluated Jacobian column norms";
                        details = [
                            "norm" => summary.norm,
                            "columns" => join(summary.zero_columns, ","),
                        ],
                    ),
                ],
                suggested_actions = [
                    "Compare the zero columns with structural unmatched variables.",
                    "Check whether the derivative vanishes only at this operating point.",
                ],
                affected = affected,
            ),
        )
    end
    if !isnothing(summary.row_scale_ratio) &&
       summary.row_scale_ratio >= scale_ratio_threshold
        push!(
            findings,
            Finding(
                :large_jacobian_row_scale_spread;
                severity = SeverityWarning,
                domain = NumericalIssue,
                basis = NumericalObservation,
                confidence = ConfidenceHigh,
                observation = "Positive finite Jacobian row norms span a ratio of $(summary.row_scale_ratio).",
                why_it_matters = "Large derivative-scale differences can distort feasibility tolerances and linear-system conditioning.",
                evidence = [
                    point_evidence,
                    Evidence(
                        "Jacobian row scale summary";
                        details = [
                            "norm" => summary.norm,
                            "smallest_positive" =>
                                summary.smallest_positive_row_norm,
                            "largest_finite" =>
                                summary.largest_finite_row_norm,
                            "ratio" => summary.row_scale_ratio,
                            "threshold" => scale_ratio_threshold,
                        ],
                    ),
                ],
                suggested_actions = [
                    "Review constraint units and characteristic magnitudes.",
                    "Consider explicit constraint scaling while preserving physical interpretation.",
                ],
            ),
        )
    end
    if !isnothing(summary.column_scale_ratio) &&
       summary.column_scale_ratio >= scale_ratio_threshold
        push!(
            findings,
            Finding(
                :large_jacobian_column_scale_spread;
                severity = SeverityWarning,
                domain = NumericalIssue,
                basis = NumericalObservation,
                confidence = ConfidenceHigh,
                observation = "Positive finite Jacobian column norms span a ratio of $(summary.column_scale_ratio).",
                why_it_matters = "Large sensitivity differences between coordinates can impair step computation and stopping-test semantics.",
                evidence = [
                    point_evidence,
                    Evidence(
                        "Jacobian column scale summary";
                        details = [
                            "norm" => summary.norm,
                            "smallest_positive" =>
                                summary.smallest_positive_column_norm,
                            "largest_finite" =>
                                summary.largest_finite_column_norm,
                            "ratio" => summary.column_scale_ratio,
                            "threshold" => scale_ratio_threshold,
                        ],
                    ),
                ],
                suggested_actions = [
                    "Review variable units and characteristic magnitudes.",
                    "Consider explicit coordinate scaling with documented tolerance semantics.",
                ],
            ),
        )
    end
    return findings
end

function _rank_evidence(estimate::JacobianRankEstimate)
    singular_minimum = isempty(estimate.singular_values) ?
                       nothing :
                       last(estimate.singular_values)
    singular_maximum = isempty(estimate.singular_values) ?
                       nothing :
                       first(estimate.singular_values)
    return Evidence(
        "Guarded dense Jacobian SVD";
        details = [
            "method" => estimate.method,
            "scaling" => estimate.scaling,
            "rows" => estimate.rows,
            "columns" => estimate.columns,
            "rank" => estimate.rank,
            "left_nullity" => estimate.left_nullity,
            "right_nullity" => estimate.right_nullity,
            "relative_tolerance" => estimate.relative_tolerance,
            "policy_absolute_tolerance" => estimate.policy.absolute_tolerance,
            "policy_matrix_norm" => estimate.policy.matrix_norm,
            "policy_provenance" => estimate.policy.provenance,
            "absolute_threshold" => estimate.absolute_threshold,
            "largest_singular_value" => singular_maximum,
            "smallest_singular_value" => singular_minimum,
            "condition_estimate" => estimate.condition_estimate,
        ],
    )
end

function _rank_findings(
    evaluation::NumericalEvaluation,
    unscaled::JacobianRankEstimate,
    scaled::JacobianRankEstimate;
    condition_threshold::Real,
    sparse_pattern::Union{Nothing,SparseJacobianPatternEstimate} = nothing,
    sparse_qr::Union{Nothing,SparseQRRankEstimate} = nothing,
)
    findings = Finding[]
    affected = vcat(
        evaluation.constraint_sources,
        EntityRef[
            EntityRef(:variable, variable.value) for
            variable in evaluation.point.variables
        ],
    )
    if !unscaled.available
        if !isnothing(sparse_pattern) && sparse_pattern.available &&
           sparse_pattern.rank_upper_bound < min(sparse_pattern.rows, sparse_pattern.columns)
            push!(
                findings,
                Finding(
                    :sparse_jacobian_pattern_rank_deficiency;
                    severity = SeverityWarning,
                    domain = NumericalIssue,
                    basis = NumericalObservation,
                    confidence = ConfidenceHigh,
                    observation = "The combined sparse Jacobian pattern has matching rank upper bound $(sparse_pattern.rank_upper_bound), below its maximum possible rank $(min(sparse_pattern.rows, sparse_pattern.columns)).",
                    why_it_matters = "No numerical Jacobian with this observed nonzero pattern can have full rank, even though the guarded dense SVD was not run.",
                    evidence = [
                        _point_evidence(evaluation.point),
                        Evidence("Sparse Jacobian pattern matching"; details = [
                            "rows" => sparse_pattern.rows,
                            "columns" => sparse_pattern.columns,
                            "combined_nonzero_count" => sparse_pattern.nonzero_count,
                            "zero_tolerance" => sparse_pattern.zero_tolerance,
                            "rank_upper_bound" => sparse_pattern.rank_upper_bound,
                            "unmatched_rows" => join(sparse_pattern.unmatched_rows, ","),
                            "unmatched_columns" => join(sparse_pattern.unmatched_columns, ","),
                        ]),
                    ],
                    suggested_actions = [
                        "Inspect the unmatched rows and columns for inactive or zero sensitivities.",
                        "Raise the dense-work guard or use a future sparse numerical-rank method for singular values and null vectors.",
                    ],
                    affected = affected,
                ),
            )
        end
        if !isnothing(sparse_qr) && sparse_qr.available &&
           sparse_qr.rank < min(sparse_qr.rows, sparse_qr.columns)
            push!(findings, Finding(
                :sparse_qr_jacobian_rank_deficiency;
                severity = SeverityWarning, domain = NumericalIssue,
                basis = NumericalObservation, confidence = ConfidenceMedium,
                observation = "Sparse QR estimates local Jacobian rank $(sparse_qr.rank), below maximum rank $(min(sparse_qr.rows, sparse_qr.columns)).",
                why_it_matters = "This numerical pivot estimate complements the structural pattern bound but does not provide singular values or null vectors.",
                evidence = [_point_evidence(evaluation.point), Evidence("Sparse QR diagonal pivots"; details = [
                    "method" => sparse_qr.method,
                    "rank" => sparse_qr.rank,
                    "threshold" => sparse_qr.absolute_threshold,
                    "relative_tolerance" => sparse_qr.relative_tolerance,
                    "absolute_tolerance" => sparse_qr.policy.absolute_tolerance,
                    "pivot_count" => length(sparse_qr.diagonal_pivots),
                    "matrix_norm" => sparse_qr.matrix_norm,
                    "matrix_norm_kind" => sparse_qr.policy.matrix_norm,
                    "row_permutation" => join(sparse_qr.row_permutation, ","),
                    "column_permutation" => join(sparse_qr.column_permutation, ","),
                    "factorization_relative_residual" => sparse_qr.factorization_relative_residual,
                    "factorization_residual_reason" => sparse_qr.factorization_residual_reason,
                ])],
                suggested_actions = ["Inspect sparse-QR pivots and, where feasible, confirm with guarded dense SVD or iterative methods."],
                affected = affected,
            ))
        end
        if !isnothing(sparse_qr) && !isnothing(sparse_qr.condition_proxy) &&
           sparse_qr.condition_proxy > condition_threshold
            push!(findings, Finding(
                :sparse_qr_pivot_scale_spread;
                severity = SeverityWarning, domain = NumericalIssue,
                basis = HeuristicInterpretation, confidence = ConfidenceMedium,
                observation = "Sparse QR retained-pivot ratio $(sparse_qr.condition_proxy) exceeds threshold $condition_threshold.",
                why_it_matters = "A large pivot spread may indicate scaling-sensitive linear algebra, but it is not a condition-number certificate.",
                evidence = [_point_evidence(evaluation.point), Evidence("Sparse QR pivot proxy"; details = ["condition_proxy" => sparse_qr.condition_proxy, "threshold" => condition_threshold, "scaling" => sparse_qr.scaling])],
                suggested_actions = ["Inspect row and column scaling and compare with dense-SVD conditioning where feasible."],
                affected = affected,
            ))
        end
        push!(
            findings,
            Finding(
                :jacobian_rank_analysis_unavailable;
                severity = SeverityInfo,
                domain = NumericalIssue,
                basis = NumericalObservation,
                confidence = ConfidenceCertain,
                observation = "Local Jacobian rank analysis is unavailable at point \"$(evaluation.point.label)\".",
                why_it_matters = "A rank verdict without complete finite derivative evidence would be misleading.",
                evidence = [
                    _point_evidence(evaluation.point),
                    Evidence(
                        "Rank-analysis availability";
                        details = [
                            "method" => unscaled.method,
                            "scaling" => unscaled.scaling,
                            "reason" => unscaled.reason,
                        ],
                    ),
                ],
                suggested_actions = [
                    "Resolve unavailable or non-finite derivative rows, or raise the explicit dense-work guard for a deliberate profiling run.",
                ],
                affected = affected,
            ),
        )
        return findings
    end
    maximum_rank = min(unscaled.rows, unscaled.columns)
    if unscaled.rank < maximum_rank
        push!(
            findings,
            Finding(
                :numerical_jacobian_rank_deficiency;
                severity = SeverityWarning,
                domain = NumericalIssue,
                basis = NumericalObservation,
                confidence = ConfidenceHigh,
                observation = "The local Jacobian has estimated rank $(unscaled.rank) below its maximum possible rank $maximum_rank at point \"$(evaluation.point.label)\".",
                why_it_matters = "Dependent rows or locally invisible directions can cause singular linear systems, non-unique multipliers, or an unexpected degree of freedom.",
                evidence = [_point_evidence(evaluation.point), _rank_evidence(unscaled)],
                suggested_actions = [
                    "Compare the left and right nullspaces with structural unmatched rows and variables.",
                    "Repeat at a nearby domain-valid point before classifying the mode as structural or physical.",
                ],
                affected = affected,
            ),
        )
    elseif !isnothing(unscaled.condition_estimate) &&
           unscaled.condition_estimate >= condition_threshold
        push!(
            findings,
            Finding(
                :ill_conditioned_jacobian;
                severity = SeverityWarning,
                domain = NumericalIssue,
                basis = NumericalObservation,
                confidence = ConfidenceHigh,
                observation = "The full-rank local Jacobian has condition estimate $(unscaled.condition_estimate).",
                why_it_matters = "A full-rank Jacobian can still produce unstable steps and tolerance-sensitive conclusions when its singular values are widely separated.",
                evidence = [
                    _point_evidence(evaluation.point),
                    _rank_evidence(unscaled),
                    Evidence(
                        "Conditioning threshold";
                        details = ["threshold" => condition_threshold],
                    ),
                ],
                suggested_actions = [
                    "Inspect units, coordinate choices, and constraint scaling.",
                    "Compare this unscaled estimate with the diagonally scaled estimate before attributing the issue to model physics.",
                ],
                affected = affected,
            ),
        )
    end
    if scaled.available && scaled.rank != unscaled.rank
        push!(
            findings,
            Finding(
                :jacobian_rank_scaling_sensitive;
                severity = SeverityWarning,
                domain = NumericalIssue,
                basis = NumericalObservation,
                confidence = ConfidenceHigh,
                observation = "The estimated local Jacobian rank changes from $(unscaled.rank) unscaled to $(scaled.rank) after row/column normalization.",
                why_it_matters = "The apparent rank depends on numerical scale, so it is not yet evidence of a scale-independent mathematical degeneracy.",
                evidence = [
                    _point_evidence(evaluation.point),
                    _rank_evidence(unscaled),
                    _rank_evidence(scaled),
                ],
                suggested_actions = [
                    "Review physical units and scaling before interpreting the nullspace as a gauge or redundant equation.",
                    "Record both thresholds and scalings in any reproducible degeneracy profile.",
                ],
                affected = affected,
            ),
        )
    end
    return findings
end

"""Cross-check guarded dense-SVD and sparse-QR rank estimates when both exist."""
function _dense_sparse_qr_rank_crosscheck_findings(
    evaluation::NumericalEvaluation,
    dense::JacobianRankEstimate,
    dense_scaled::JacobianRankEstimate,
    sparse::SparseQRRankEstimate,
    sparse_scaled::SparseQRRankEstimate,
)
    findings = Finding[]
    dense.available && sparse.available || return findings
    unscaled_agree = dense.rank == sparse.rank
    scaled_comparable = dense_scaled.available && sparse_scaled.available
    scaled_agree = !scaled_comparable || dense_scaled.rank == sparse_scaled.rank
    agreement = unscaled_agree && scaled_agree
    affected = vcat(
        evaluation.constraint_sources,
        EntityRef[EntityRef(:variable, variable.value) for variable in evaluation.point.variables],
    )
    push!(findings, Finding(
        agreement ? :dense_sparse_qr_rank_agreement : :dense_sparse_qr_rank_disagreement;
        severity = agreement ? SeverityInfo : SeverityWarning,
        domain = NumericalIssue,
        basis = NumericalObservation,
        confidence = agreement ? ConfidenceMedium : ConfidenceHigh,
        observation = agreement ?
                      "Guarded dense SVD and sparse QR give the same local Jacobian rank at the recorded scaling(s)." :
                      "Guarded dense SVD and sparse QR give different local Jacobian rank estimates at one or more recorded scaling(s).",
        why_it_matters = agreement ?
                         "Agreement between independent dense singular-value and sparse pivot screens strengthens this local numerical observation, without proving exact rank." :
                         "The rank conclusion is method- or threshold-sensitive; it should not be promoted to a scale-independent structural or physical diagnosis.",
        evidence = [_point_evidence(evaluation.point), Evidence("Dense-SVD and sparse-QR rank cross-check"; details = [
            "dense_unscaled_rank" => dense.rank,
            "sparse_qr_unscaled_rank" => sparse.rank,
            "unscaled_agree" => unscaled_agree,
            "dense_row_column_rank" => dense_scaled.rank,
            "sparse_qr_row_column_rank" => sparse_scaled.rank,
            "scaled_comparable" => scaled_comparable,
            "scaled_agree" => scaled_agree,
            "dense_relative_tolerance" => dense.relative_tolerance,
            "sparse_qr_relative_tolerance" => sparse.relative_tolerance,
            "sparse_qr_absolute_tolerance" => sparse.policy.absolute_tolerance,
            "sparse_qr_factorization_relative_residual" => sparse.factorization_relative_residual,
        ])],
        affected = affected,
        suggested_actions = agreement ?
                            ["Use the agreement as repeated local numerical evidence and still compare nearby points before making a structural interpretation."] :
                            ["Inspect pivot and singular-value thresholds, row/column scaling, and derivative provenance before relying on either rank estimate."],
    ))
    return findings
end

"""
    analyze_jacobian_rank_tolerance_sweep(evaluation; ...)

Re-estimate one guarded dense Jacobian rank over explicit relative tolerances.
The result is a numerical sensitivity screen: stable ranks do not prove exact
rank, and changing ranks do not identify a mathematical cause.
"""
function analyze_jacobian_rank_tolerance_sweep(
    evaluation::NumericalEvaluation{T};
    relative_tolerances::AbstractVector{<:Real} = T[
        sqrt(eps(T)) / 100,
        sqrt(eps(T)),
        sqrt(eps(T)) * 100,
    ],
    scaling::Symbol = :none,
    max_dense_entries::Integer = 4_000_000,
) where {T<:AbstractFloat}
    isempty(relative_tolerances) &&
        throw(ArgumentError("relative_tolerances must not be empty"))
    tolerances = sort!(unique(T.(relative_tolerances)))
    all(value -> isfinite(value) && value >= zero(T), tolerances) ||
        throw(ArgumentError("relative_tolerances must be finite and nonnegative"))
    estimates = [
        jacobian_rank_estimate(
            evaluation;
            scaling = scaling,
            relative_tolerance = tolerance,
            max_dense_entries = max_dense_entries,
        ) for tolerance in tolerances
    ]
    report = DiagnosticReport()
    report.metadata[:stage] = "jacobian_rank_tolerance_sweep"
    report.metadata[:evaluation_point_label] = evaluation.point.label
    report.metadata[:scaling] = string(scaling)
    report.metadata[:relative_tolerances] = join(tolerances, ",")
    report.metadata[:available_estimate_count] = string(count(estimate -> estimate.available, estimates))
    affected = vcat(
        evaluation.constraint_sources,
        EntityRef[EntityRef(:variable, variable.value) for variable in evaluation.point.variables],
    )
    if any(!estimate.available for estimate in estimates)
        push!(report, Finding(:jacobian_rank_tolerance_sweep_unavailable;
            severity = SeverityInfo, domain = NumericalIssue,
            basis = NumericalObservation, confidence = ConfidenceHigh,
            observation = "At least one requested dense Jacobian rank estimate is unavailable in the tolerance sweep.",
            why_it_matters = "Rank sensitivity cannot be compared when derivative evidence is incomplete, non-finite, or exceeds the explicit dense guard.",
            evidence = [_point_evidence(evaluation.point), Evidence("Jacobian rank tolerance-sweep availability"; details = [
                "relative_tolerances" => report.metadata[:relative_tolerances],
                "availability" => join((estimate.available for estimate in estimates), ","),
                "reasons" => join((something(estimate.reason, "") for estimate in estimates), ";"),
                "scaling" => scaling,
            ])],
            affected = affected,
            suggested_actions = ["Resolve derivative availability or raise the explicit dense-work guard before interpreting a tolerance sweep."],
        ))
        return report
    end
    ranks = [estimate.rank for estimate in estimates]
    stable = all(==(first(ranks)), ranks)
    report.metadata[:ranks] = join(ranks, ",")
    report.metadata[:minimum_rank] = string(minimum(ranks))
    report.metadata[:maximum_rank] = string(maximum(ranks))
    report.metadata[:rank_span] = string(maximum(ranks) - minimum(ranks))
    report.metadata[:absolute_thresholds] = join(
        (estimate.absolute_threshold for estimate in estimates), ",",
    )
    push!(report, Finding(
        stable ? :jacobian_rank_tolerance_stable : :jacobian_rank_tolerance_sensitive;
        severity = stable ? SeverityInfo : SeverityWarning,
        domain = NumericalIssue,
        basis = NumericalObservation,
        confidence = stable ? ConfidenceMedium : ConfidenceHigh,
        observation = stable ?
                      "The guarded dense Jacobian rank remains $(first(ranks)) across $(length(tolerances)) requested relative tolerances." :
                      "The guarded dense Jacobian rank changes across $(length(tolerances)) requested relative tolerances.",
        why_it_matters = stable ?
                         "The local rank observation is less sensitive to this documented tolerance range, but remains numerical and point-local." :
                         "The apparent nullity is threshold-sensitive, so it should not be interpreted as a scale-independent structural or physical degeneracy.",
        evidence = [_point_evidence(evaluation.point), Evidence("Jacobian rank tolerance sweep"; details = [
            "relative_tolerances" => report.metadata[:relative_tolerances],
            "absolute_thresholds" => report.metadata[:absolute_thresholds],
            "ranks" => report.metadata[:ranks],
            "scaling" => scaling,
        ])],
        affected = affected,
        suggested_actions = stable ?
                            ["Record this tolerance range with the local rank observation and compare nearby points before interpreting its cause."] :
                            ["Inspect singular values, physical scaling, and derivative provenance before classifying the apparent nullspace."],
    ))
    return report
end

"""Evaluate one explicit point before sweeping guarded dense rank tolerances."""
function analyze_jacobian_rank_tolerance_sweep(
    model::MOI.ModelLike,
    point::EvaluationPoint;
    cache::EvaluationCache = EvaluationCache(),
    relative_step::Union{Nothing,Real} = nothing,
    kwargs...,
)
    evaluation = isnothing(relative_step) ?
                 evaluate_numerical(model, point; cache = cache) :
                 evaluate_numerical(model, point; cache = cache, relative_step = relative_step)
    return analyze_jacobian_rank_tolerance_sweep(evaluation; kwargs...)
end

"""
    analyze_jacobian_condition_persistence(evaluations; ...)

Compare finite guarded dense-SVD Jacobian condition estimates at explicit
points. It is deliberately unavailable for rank-deficient or non-finite local
estimates, because those do not support a finite condition-ratio comparison.
"""
function analyze_jacobian_condition_persistence(
    evaluations::AbstractVector{<:NumericalEvaluation{T}};
    minimum_evaluations::Integer = 2,
    relative_tolerance::Real = maximum((
        max(length(evaluation.constraint_sources), length(evaluation.point.variables), 1)
        for evaluation in evaluations); init = 1) * eps(T),
    scaling::Symbol = :none,
    max_dense_entries::Integer = 4_000_000,
    change_factor_threshold::Real = 100,
) where {T<:AbstractFloat}
    minimum_evaluations >= 2 ||
        throw(ArgumentError("minimum_evaluations must be at least two"))
    tolerance = convert(T, relative_tolerance)
    tolerance >= zero(T) || throw(ArgumentError("relative_tolerance must be nonnegative"))
    change_factor_threshold >= one(T) ||
        throw(ArgumentError("change_factor_threshold must be at least one"))
    report = DiagnosticReport()
    report.metadata[:stage] = "jacobian_condition_persistence"
    report.metadata[:evaluation_count] = string(length(evaluations))
    report.metadata[:minimum_evaluations] = string(minimum_evaluations)
    report.metadata[:relative_tolerance] = string(tolerance)
    report.metadata[:scaling] = string(scaling)
    report.metadata[:change_factor_threshold] = string(change_factor_threshold)
    if length(evaluations) < minimum_evaluations
        push!(report, Finding(:jacobian_condition_persistence_unavailable;
            severity = SeverityInfo, domain = NumericalIssue,
            basis = NumericalObservation, confidence = ConfidenceHigh,
            observation = "Only $(length(evaluations)) explicitly supplied evaluation(s) are available for Jacobian conditioning persistence.",
            why_it_matters = "Cross-point conditioning comparison requires at least $(minimum_evaluations) evaluations.",
            evidence = [Evidence("Jacobian conditioning persistence availability"; details = [
                "evaluation_count" => length(evaluations),
                "minimum_evaluations" => minimum_evaluations,
            ])],
            suggested_actions = ["Supply multiple evaluations over the operating region of interest."],
        ))
        return report
    end
    reference_variables = first(evaluations).point.variables
    reference_rows = first(evaluations).constraint_sources
    if any(evaluation.point.variables != reference_variables for evaluation in evaluations) ||
       any(evaluation.constraint_sources != reference_rows for evaluation in evaluations)
        push!(report, Finding(:jacobian_condition_persistence_coordinate_mismatch;
            severity = SeverityInfo, domain = RepresentationalIssue,
            basis = StructuralProof, confidence = ConfidenceCertain,
            observation = "Jacobian evaluations do not share one ordered variable and constraint-row scope.",
            why_it_matters = "Condition estimates can be compared only in common derivative coordinates.",
            evidence = [Evidence("Jacobian conditioning persistence alignment"; details = [
                "evaluation_count" => length(evaluations),
            ])],
            suggested_actions = ["Evaluate the same ordered variables and scalar constraint rows at every point."],
        ))
        return report
    end
    estimates = [
        jacobian_rank_estimate(
            evaluation;
            scaling = scaling,
            relative_tolerance = tolerance,
            max_dense_entries = max_dense_entries,
            compute_vectors = false,
        ) for evaluation in evaluations
    ]
    conditions = [estimate.condition_estimate for estimate in estimates]
    finite_available = all(
        estimate.available && !isnothing(condition) && isfinite(condition)
        for (estimate, condition) in zip(estimates, conditions)
    )
    if !finite_available
        push!(report, Finding(:jacobian_condition_persistence_unavailable;
            severity = SeverityInfo, domain = NumericalIssue,
            basis = NumericalObservation, confidence = ConfidenceHigh,
            observation = "At least one supplied point lacks a finite guarded dense Jacobian condition estimate.",
            why_it_matters = "Rank-deficient, non-finite, or dense-guarded local Jacobians cannot support a finite conditioning-ratio comparison.",
            evidence = [Evidence("Jacobian conditioning persistence availability"; details = [
                "point_labels" => join((evaluation.point.label for evaluation in evaluations), ","),
                "rank_estimate_available" => join((estimate.available for estimate in estimates), ","),
                "ranks" => join((estimate.rank for estimate in estimates), ","),
                "condition_estimates" => join(conditions, ","),
                "reasons" => join((something(estimate.reason, "") for estimate in estimates), ";"),
            ])],
            affected = vcat(
                reference_rows,
                EntityRef[EntityRef(:variable, variable.value) for variable in reference_variables],
            ),
            suggested_actions = ["Resolve rank deficiency or derivative availability before comparing finite condition estimates across points."],
        ))
        return report
    end
    finite_conditions = T[condition::T for condition in conditions]
    reference_condition = first(finite_conditions)
    change_factor = maximum((
        max(reference_condition / condition, condition / reference_condition)
        for condition in finite_conditions[2:end]
    ); init = one(T))
    persistent = change_factor <= convert(T, change_factor_threshold)
    report.metadata[:condition_estimates] = join(finite_conditions, ",")
    report.metadata[:change_factor] = string(change_factor)
    push!(report, Finding(
        persistent ? :jacobian_condition_persistent : :jacobian_condition_changing;
        severity = persistent ? SeverityInfo : SeverityWarning,
        domain = NumericalIssue,
        basis = NumericalObservation,
        confidence = ConfidenceHigh,
        observation = persistent ?
                      "Finite guarded dense Jacobian condition estimates remain within a factor of $(change_factor_threshold) across $(length(evaluations)) supplied points." :
                      "Finite guarded dense Jacobian condition estimates change by more than a factor of $(change_factor_threshold) across $(length(evaluations)) supplied points.",
        why_it_matters = persistent ?
                         "Stable local conditioning helps interpret cross-point numerical behavior, but is neither a global condition bound nor a solver prediction." :
                         "Changing conditioning can alter linear-solve accuracy and tolerance semantics without proving a mathematical or physical model change.",
        evidence = [Evidence("Jacobian conditioning persistence"; details = [
            "point_labels" => join((evaluation.point.label for evaluation in evaluations), ","),
            "condition_estimates" => report.metadata[:condition_estimates],
            "change_factor" => change_factor,
            "change_factor_threshold" => change_factor_threshold,
            "relative_tolerance" => tolerance,
            "scaling" => scaling,
        ])],
        affected = vcat(
            reference_rows,
            EntityRef[EntityRef(:variable, variable.value) for variable in reference_variables],
        ),
        suggested_actions = persistent ?
                            ["Use the stable local conditioning evidence with rank, scaling, and derivative-provenance reports."] :
                            ["Inspect row/column scales, coordinate units, and nearby active geometry before attributing conditioning changes to the formulation."],
    ))
    return report
end

"""Evaluate explicit points before comparing Jacobian conditioning persistence."""
function analyze_jacobian_condition_persistence(
    model::MOI.ModelLike,
    points::AbstractVector{<:EvaluationPoint};
    cache::EvaluationCache = EvaluationCache(),
    relative_step::Union{Nothing,Real} = nothing,
    kwargs...,
)
    evaluations = [
        isnothing(relative_step) ? evaluate_numerical(model, point; cache = cache) :
        evaluate_numerical(model, point; cache = cache, relative_step = relative_step)
        for point in points
    ]
    return analyze_jacobian_condition_persistence(evaluations; kwargs...)
end

"""
    analyze_numerical(model, point; cache, scale_ratio_threshold)

Evaluate values and first derivatives, then produce point-local numerical
findings. No model data is modified.
"""
function _analyze_numerical_evaluation(
    model::MOI.ModelLike,
    evaluation::NumericalEvaluation{T};
    scale_ratio_threshold::Real = 1.0e6,
    numeric_type::Type{<:AbstractFloat} = T,
    strict_domain_proximity_threshold::Union{Nothing,Real} = nothing,
    rank_relative_tolerance::Real =
        max(length(evaluation.point.variables), 1) * eps(T),
    rank_absolute_tolerance::Real = zero(T),
    rank_matrix_norm::Symbol = :frobenius,
    rank_max_dense_entries::Integer = 4_000_000,
    jacobian_condition_threshold::Real = 1.0e10,
    component_scale_mismatch_factor::Real = 1.0e3,
) where {T<:AbstractFloat}
    _validate_evaluation_variable_order(model, evaluation)
    scale_ratio_threshold > 1 ||
        throw(ArgumentError("scale_ratio_threshold must be greater than one"))
    jacobian_condition_threshold > 1 || throw(
        ArgumentError("jacobian_condition_threshold must be greater than one"),
    )
    point = evaluation.point
    summary = jacobian_scale_summary(evaluation)
    unscaled_rank = jacobian_rank_estimate(
        evaluation;
        scaling = :none,
        relative_tolerance = rank_relative_tolerance,
        absolute_tolerance = rank_absolute_tolerance,
        matrix_norm = rank_matrix_norm,
        max_dense_entries = rank_max_dense_entries,
        provenance = :analyze_numerical,
    )
    scaled_rank = jacobian_rank_estimate(
        evaluation;
        scaling = :row_column,
        relative_tolerance = rank_relative_tolerance,
        absolute_tolerance = rank_absolute_tolerance,
        matrix_norm = rank_matrix_norm,
        max_dense_entries = rank_max_dense_entries,
        provenance = :analyze_numerical,
    )
    sparse_pattern = sparse_jacobian_pattern_estimate(evaluation)
    sparse_qr = sparse_qr_rank_estimate(
        evaluation;
        relative_tolerance = rank_relative_tolerance,
        absolute_tolerance = rank_absolute_tolerance,
        matrix_norm = rank_matrix_norm,
        provenance = :analyze_numerical,
    )
    scaled_sparse_qr = sparse_qr_rank_estimate(
        evaluation;
        relative_tolerance = rank_relative_tolerance,
        absolute_tolerance = rank_absolute_tolerance,
        scaling = :row_column,
        matrix_norm = rank_matrix_norm,
        provenance = :analyze_numerical,
    )
    model_snapshot = snapshot(model)
    report = DiagnosticReport()
    append!(
        report.findings,
        _operating_point_domain_findings(model_snapshot, evaluation),
    )
    if sparse_qr.available && scaled_sparse_qr.available &&
       sparse_qr.rank != scaled_sparse_qr.rank
        push!(report, Finding(:sparse_qr_rank_scaling_sensitivity;
            severity = SeverityWarning, domain = NumericalIssue,
            basis = NumericalObservation, confidence = ConfidenceMedium,
            observation = "Sparse QR estimates rank $(sparse_qr.rank) unscaled and $(scaled_sparse_qr.rank) after row-column normalization.",
            why_it_matters = "The local rank conclusion is sensitive to scaling and pivot threshold semantics, so it should not be classified as a robust structural deficiency yet.",
            evidence = [_point_evidence(point), Evidence("Sparse QR scaling comparison"; details = ["unscaled_rank" => sparse_qr.rank, "scaled_rank" => scaled_sparse_qr.rank, "relative_tolerance" => rank_relative_tolerance])],
            suggested_actions = ["Inspect row and column scales and compare with dense-SVD results when feasible."],
        ))
    end
    append!(
        report.findings,
        _dense_sparse_qr_rank_crosscheck_findings(
            evaluation,
            unscaled_rank,
            scaled_rank,
            sparse_qr,
            scaled_sparse_qr,
        ),
    )
    append!(
        report.findings,
        _rank_findings(
            evaluation,
            unscaled_rank,
            scaled_rank;
            condition_threshold = jacobian_condition_threshold,
        sparse_pattern = sparse_pattern,
        sparse_qr = sparse_qr,
        ),
    )
    append!(report.findings, _nonfinite_value_findings(evaluation))
    append!(report.findings, _jacobian_derivative_provenance_findings(evaluation))
    append!(report.findings, _evaluation_failure_findings(evaluation))
    component_scale_report = analyze_component_coordinate_scales(
        model,
        point;
        mismatch_factor = component_scale_mismatch_factor,
    )
    append!(report.findings, component_scale_report.findings)
    component_constraint_scale_report = analyze_component_constraint_scales(
        model, evaluation;
        mismatch_factor = component_scale_mismatch_factor,
    )
    append!(report.findings, component_constraint_scale_report.findings)
    derivative_report =
        analyze_derivatives(model_snapshot; point = point)
    expression_report = analyze_expressions(
        model_snapshot;
        point = point,
        numeric_type = numeric_type,
        strict_domain_proximity_threshold = strict_domain_proximity_threshold,
    )
    append!(report.findings, derivative_report.findings)
    append!(report.findings, expression_report.findings)
    append!(
        report.findings,
        _scale_findings(
            evaluation,
            summary;
            scale_ratio_threshold = scale_ratio_threshold,
        ),
    )
    report.metadata[:stage] = "numerical"
    report.metadata[:evaluation_point_label] = point.label
    report.metadata[:evaluation_point_provenance_kind] = string(point.provenance.kind)
    report.metadata[:evaluation_point_provenance_source] = point.provenance.source
    report.metadata[:evaluation_point_provenance_complete] =
        string(point.provenance.complete)
    report.metadata[:model_fingerprint] = model_fingerprint(model)
    report.metadata[:evaluation_point_fingerprint] =
        evaluation_point_fingerprint(point)
    report.metadata[:evaluation_source_fingerprint] =
        evaluation_source_fingerprint(evaluation)
    report.metadata[:evaluation_variable_count] =
        string(length(point.variables))
    report.metadata[:evaluated_constraint_row_count] =
        string(length(evaluation.constraint_sources))
    report.metadata[:raw_jacobian_entry_count] =
        string(length(evaluation.jacobian_entries))
    report.metadata[:evaluation_failure_count] =
        string(length(evaluation.failures))
    method_counts = Dict{Symbol,Int}()
    for method in evaluation.jacobian_row_methods
        method_counts[method] = get(method_counts, method, 0) + 1
    end
    method_pairs = sort!(collect(method_counts); by = pair -> string(pair[1]))
    report.metadata[:jacobian_derivative_method_count] = string(length(method_counts))
    report.metadata[:jacobian_derivative_row_method_counts] = join(
        ("$(method)=$(count)" for (method, count) in method_pairs), ",",
    )
    report.metadata[:jacobian_central_finite_difference_row_count] = string(get(
        method_counts, :central_finite_difference, 0,
    ))
    report.metadata[:jacobian_partial_finite_difference_row_count] = string(get(
        method_counts, :partial_central_finite_difference, 0,
    ))
    report.metadata[:objective_gradient_method] =
        string(evaluation.objective_gradient_method)
    report.metadata[:jacobian_rank] = string(unscaled_rank.rank)
    report.metadata[:jacobian_rank_scaling] = string(unscaled_rank.scaling)
    report.metadata[:jacobian_rank_available] = string(unscaled_rank.available)
    report.metadata[:jacobian_rank_relative_tolerance] =
        string(unscaled_rank.policy.relative_tolerance)
    report.metadata[:jacobian_rank_absolute_tolerance] =
        string(unscaled_rank.policy.absolute_tolerance)
    report.metadata[:jacobian_rank_matrix_norm_kind] =
        string(unscaled_rank.policy.matrix_norm)
    report.metadata[:jacobian_rank_policy_provenance] =
        string(unscaled_rank.policy.provenance)
    report.metadata[:sparse_jacobian_pattern_available] =
        string(sparse_pattern.available)
    report.metadata[:sparse_jacobian_pattern_rank_upper_bound] =
        string(sparse_pattern.rank_upper_bound)
    report.metadata[:sparse_qr_rank_available] = string(sparse_qr.available)
    report.metadata[:sparse_qr_rank] = string(sparse_qr.rank)
    report.metadata[:sparse_qr_rank_scaling] = string(sparse_qr.scaling)
    report.metadata[:sparse_qr_row_column_rank] = string(scaled_sparse_qr.rank)
    report.metadata[:sparse_qr_condition_proxy] = string(sparse_qr.condition_proxy)
    report.metadata[:sparse_qr_method] = string(sparse_qr.method)
    report.metadata[:sparse_qr_absolute_tolerance] =
        string(sparse_qr.policy.absolute_tolerance)
    report.metadata[:sparse_qr_matrix_norm_kind] = string(sparse_qr.policy.matrix_norm)
    report.metadata[:sparse_qr_matrix_norm] = string(sparse_qr.matrix_norm)
    report.metadata[:sparse_qr_row_permutation] = join(sparse_qr.row_permutation, ",")
    report.metadata[:sparse_qr_column_permutation] =
        join(sparse_qr.column_permutation, ",")
    report.metadata[:sparse_qr_factorization_relative_residual] =
        string(sparse_qr.factorization_relative_residual)
    report.metadata[:sparse_qr_factorization_residual_reason] =
        string(sparse_qr.factorization_residual_reason)
    report.metadata[:dense_sparse_qr_unscaled_rank_agree] = string(
        unscaled_rank.available && sparse_qr.available &&
        unscaled_rank.rank == sparse_qr.rank,
    )
    report.metadata[:dense_sparse_qr_row_column_rank_agree] = string(
        scaled_rank.available && scaled_sparse_qr.available &&
        scaled_rank.rank == scaled_sparse_qr.rank,
    )
    report.metadata[:jacobian_condition_threshold] = string(jacobian_condition_threshold)
    report.metadata[:evaluation_sources] = join(
        unique(string(capability.source) for capability in evaluation.capabilities),
        ",",
    )
    merge!(report.metadata, derivative_report.metadata)
    merge!(report.metadata, expression_report.metadata)
    for (key, value) in component_scale_report.metadata
        key == :stage && continue
        report.metadata[key] = value
    end
    for (key, value) in component_constraint_scale_report.metadata
        key == :stage && continue
        report.metadata[key] = value
    end
    _apply_point_provenance_guard!(report, point)
    sort!(
        report.findings;
        by = finding -> (-Int(finding.severity), string(finding.code)),
    )
    return report
end

"""
    analyze_numerical(model, point; cache, relative_step, ...)

Evaluate values and first derivatives, then produce point-local numerical
findings. No model data is modified.
"""
function analyze_numerical(
    model::MOI.ModelLike,
    point::EvaluationPoint{T};
    cache::EvaluationCache = EvaluationCache(),
    relative_step::Real = cbrt(eps(T)),
    kwargs...,
) where {T<:AbstractFloat}
    evaluation = evaluate_numerical(
        model,
        point;
        cache = cache,
        relative_step = relative_step,
    )
    return _analyze_numerical_evaluation(model, evaluation; kwargs...)
end

"""
    analyze_numerical(model, evaluation; ...)

Analyze a caller-supplied `NumericalEvaluation` without re-evaluating the
model. The evaluation's recorded point, derivatives, failures, and provenance
remain the sole numerical evidence used by this overload.
"""
function analyze_numerical(
    model::MOI.ModelLike,
    evaluation::NumericalEvaluation;
    kwargs...,
)
    return _analyze_numerical_evaluation(model, evaluation; kwargs...)
end

function _reduced_hessian_expected_mode_findings(
    evaluation::NumericalEvaluation{T},
    analysis::ReducedHessianAnalysis{T},
    modes::AbstractVector{<:ExpectedNullspaceMode};
    residual_tolerance::Real = sqrt(eps(T)),
) where {T<:AbstractFloat}
    isempty(modes) && return Finding[]
    tolerance = convert(T, residual_tolerance)
    tolerance >= zero(T) || throw(ArgumentError(
        "reduced-Hessian expected-mode residual_tolerance must be nonnegative",
    ))
    column_by_variable = Dict(
        variable => column for (column, variable) in enumerate(evaluation.point.variables)
    )
    findings = Finding[]
    for mode in modes
        columns = [get(column_by_variable, variable, 0) for variable in mode.variables]
        if any(iszero, columns)
            push!(findings, Finding(
                :reduced_hessian_expected_flat_mode_unaligned;
                severity = SeverityInfo,
                domain = RepresentationalIssue,
                basis = StructuralProof,
                confidence = ConfidenceCertain,
                observation = "Declared expected mode $(mode.name) cannot be aligned with the reduced-Hessian evaluation coordinates.",
                why_it_matters = "A second-order comparison is not meaningful when a declaration references variables absent from the evaluated point.",
                evidence = [Evidence("Reduced-Hessian expected-mode declaration"; details = [
                    "mode" => mode.name,
                    "description" => mode.description,
                ])],
                suggested_actions = [
                    "Declare the mode in the current evaluation-point variable coordinates.",
                ],
            ))
            continue
        end
        direction = zeros(T, length(evaluation.point.variables))
        for (column, value) in zip(columns, mode.direction)
            direction[column] += convert(T, value)
        end
        tangent_coordinates = transpose(analysis.tangent_basis) * direction
        tangent_projection = analysis.tangent_basis * tangent_coordinates
        tangent_residual = norm(direction - tangent_projection)
        direction_norm = norm(direction)
        tangent = tangent_residual <= tolerance * max(one(T), direction_norm)
        flat_residual = zero(T)
        if tangent && !isempty(tangent_coordinates)
            spectral_coordinates = transpose(analysis.reduced_eigenvectors) * tangent_coordinates
            flat_residual = norm(
                analysis.reduced_eigenvectors * (analysis.eigenvalues .* spectral_coordinates),
            )
        end
        flat_threshold = analysis.eigenvalue_threshold *
                         max(one(T), norm(tangent_coordinates))
        observed = tangent && flat_residual <= flat_threshold
        push!(findings, Finding(
            observed ? :reduced_hessian_expected_flat_mode_observed :
                       :reduced_hessian_expected_flat_mode_not_observed;
            severity = SeverityInfo,
            domain = RepresentationalIssue,
            basis = observed ? PhysicalExpectation : LocalInference,
            confidence = observed ? ConfidenceHigh : ConfidenceMedium,
            observation = observed ?
                          "Declared mode $(mode.name) is a near-flat tangent direction of the reduced Hessian at this point." :
                          "Declared mode $(mode.name) is not a near-flat tangent direction of the reduced Hessian at this point.",
            why_it_matters = observed ?
                             "The local second-order geometry is consistent with the declared expected mode, without independently validating its physical semantics." :
                             "Active constraints, curvature, or the operating point can remove an expected flat mode; this is point-local evidence rather than a plugin error.",
            evidence = [
                _point_evidence(evaluation.point),
                Evidence("Reduced-Hessian expected-mode comparison"; details = [
                    "mode" => mode.name,
                    "description" => mode.description,
                    "tangent_residual" => tangent_residual,
                    "flat_residual" => flat_residual,
                    "flat_threshold" => flat_threshold,
                ]),
            ],
            affected = EntityRef[
                EntityRef(:variable, variable.value) for variable in mode.variables
            ],
            suggested_actions = observed ?
                                ["Retain the declaration as expected-mode evidence and confirm its units and physical semantics."] :
                                ["Inspect the active rows, reduced curvature, and operating point before changing the expected-mode declaration."],
        ))
    end
    return findings
end

function _flat_reduced_hessian_subspace(analysis::ReducedHessianAnalysis{T}) where {T}
    analysis.available || return zeros(T, size(analysis.tangent_basis, 1), 0)
    indices = findall(abs(value) <= analysis.eigenvalue_threshold for value in analysis.eigenvalues)
    isempty(indices) && return zeros(T, size(analysis.tangent_basis, 1), 0)
    return analysis.tangent_basis * analysis.reduced_eigenvectors[:, indices]
end

function _persistent_flat_support_variables(
    snapshots::AbstractVector{<:ReducedHessianSnapshot{T}},
    relative_tolerance::Real,
) where {T<:AbstractFloat}
    candidates = [
        snapshot for snapshot in snapshots
        if snapshot.analysis.available && snapshot.analysis.zero_eigenvalues > 0
    ]
    isempty(candidates) && return MOI.VariableIndex[]
    subspace = _flat_reduced_hessian_subspace(first(candidates).analysis)
    row_magnitudes = [norm(view(subspace, row, :)) for row in axes(subspace, 1)]
    maximum_magnitude = maximum(row_magnitudes; init = zero(T))
    positions = findall(value >= convert(T, relative_tolerance) * maximum_magnitude
                        for value in row_magnitudes)
    return first(candidates).evaluation.point.variables[positions]
end

function _flat_subspace_support_positions(
    analysis::ReducedHessianAnalysis{T},
    relative_tolerance::Real,
) where {T<:AbstractFloat}
    subspace = _flat_reduced_hessian_subspace(analysis)
    row_magnitudes = [norm(view(subspace, row, :)) for row in axes(subspace, 1)]
    maximum_magnitude = maximum(row_magnitudes; init = zero(T))
    return findall(value >= convert(T, relative_tolerance) * maximum_magnitude
                   for value in row_magnitudes)
end

function _append_flat_support_persistence_findings!(
    report::DiagnosticReport,
    snapshots::AbstractVector{<:ReducedHessianSnapshot{T}},
    candidates::AbstractVector{<:ReducedHessianSnapshot{T}};
    support_relative_tolerance::Real,
) where {T<:AbstractFloat}
    length(candidates) >= 2 || return report
    supports = [
        _flat_subspace_support_positions(
            snapshot.analysis, support_relative_tolerance,
        ) for snapshot in candidates
    ]
    support_sets = Set.(supports)
    pairwise_jaccard = T[]
    for left in eachindex(support_sets), right in (left + 1):length(support_sets)
        intersection_size = length(intersect(support_sets[left], support_sets[right]))
        union_size = length(union(support_sets[left], support_sets[right]))
        push!(pairwise_jaccard, union_size == 0 ? one(T) :
              T(intersection_size) / T(union_size))
    end
    support_persistent = all(==(first(supports)), supports)
    minimum_jaccard = isempty(pairwise_jaccard) ? one(T) : minimum(pairwise_jaccard)
    union_support = sort!(collect(union(support_sets...)))
    reference_variables = first(snapshots).evaluation.point.variables
    labels = join((snapshot.evaluation.point.label for snapshot in candidates), ",")
    push!(report, Finding(
        support_persistent ? :reduced_hessian_flat_support_persistent :
                             :reduced_hessian_flat_support_changing;
        severity = SeverityInfo,
        domain = NumericalIssue,
        basis = HeuristicInterpretation,
        confidence = ConfidenceMedium,
        observation = support_persistent ?
                      "The material variable support of the reduced-Hessian flat subspace is unchanged across $(length(candidates)) explicitly supplied points." :
                      "The material variable support of the reduced-Hessian flat subspace changes across $(length(candidates)) explicitly supplied points.",
        why_it_matters = support_persistent ?
                         "Repeated support strengthens the case for a localized persistent weak-curvature subsystem, but does not identify its cause." :
                         "Support changes can reveal operating-point-sensitive weak curvature or changing active geometry, even when some flat directions remain aligned.",
        evidence = [Evidence("Reduced-Hessian flat-support persistence"; details = [
            "point_labels" => labels,
            "support_relative_tolerance" => support_relative_tolerance,
            "support_sizes" => join(length.(supports), ","),
            "minimum_pairwise_jaccard" => minimum_jaccard,
            "union_support_coordinates" => join(union_support, ","),
        ])],
        affected = EntityRef[
            EntityRef(:variable, reference_variables[position].value)
            for position in union_support
        ],
        suggested_actions = support_persistent ?
                            ["Inspect the stable support as a candidate localized subsystem, then compare incidence and declared component context."] :
                            ["Compare active rows, scaling, and nearby operating points to explain the changing support."],
    ))
    return report
end

function _append_reduced_hessian_active_row_persistence_findings!(
    report::DiagnosticReport,
    candidates::AbstractVector{<:ReducedHessianSnapshot},
)
    length(candidates) >= 2 || return report
    reference_sources = first(candidates).evaluation.constraint_sources
    if any(snapshot.evaluation.constraint_sources != reference_sources for snapshot in candidates)
        push!(report, Finding(
            :reduced_hessian_active_row_persistence_unaligned;
            severity = SeverityInfo,
            domain = RepresentationalIssue,
            basis = StructuralProof,
            confidence = ConfidenceCertain,
            observation = "Reduced-Hessian snapshots do not share one constraint-row source ordering for active-row comparison.",
            why_it_matters = "Active-row indices are only comparable when their constraint sources are aligned across points.",
            evidence = [Evidence("Reduced-Hessian active-row alignment"; details = [
                "snapshot_count" => length(candidates),
            ])],
            suggested_actions = [
                "Evaluate the same ordered constraint rows at every point before comparing active-set persistence.",
            ],
        ))
        return report
    end
    row_sets = [Set(snapshot.analysis.active_rows) for snapshot in candidates]
    active_rows_persistent = all(==(first(row_sets)), row_sets)
    changing_rows = sort!(collect(union(row_sets...)))
    labels = join((snapshot.evaluation.point.label for snapshot in candidates), ",")
    push!(report, Finding(
        active_rows_persistent ? :reduced_hessian_active_rows_persistent :
                                 :reduced_hessian_active_rows_changing;
        severity = SeverityInfo,
        domain = NumericalIssue,
        basis = NumericalObservation,
        confidence = ConfidenceHigh,
        observation = active_rows_persistent ?
                      "The explicitly supplied reduced-Hessian active-row set is unchanged across $(length(candidates)) points." :
                      "The explicitly supplied reduced-Hessian active-row set changes across $(length(candidates)) points.",
        why_it_matters = active_rows_persistent ?
                         "A changing flat subspace under this stable selected active set is more directly attributable to local curvature or derivative changes than to row selection." :
                         "A changing selected active set can alter the tangent space and therefore the reduced-Hessian flat directions; this records the supplied selection rather than inferring activity.",
        evidence = [Evidence("Reduced-Hessian active-row persistence"; details = [
            "point_labels" => labels,
            "active_row_sets" => join((join(sort!(collect(rows)), ",") for rows in row_sets), ";"),
        ])],
        affected = EntityRef[
            reference_sources[row] for row in changing_rows
            if 1 <= row <= length(reference_sources)
        ],
        suggested_actions = active_rows_persistent ?
                            ["Compare Hessian and derivative changes at the supplied points before attributing changing flat geometry to active-set selection."] :
                            ["Inspect feasibility margins and active-set selection tolerances before interpreting changing reduced-Hessian geometry."],
    ))
    return report
end

function _append_reduced_hessian_active_jacobian_persistence_findings!(
    report::DiagnosticReport,
    candidates::AbstractVector{<:ReducedHessianSnapshot},
)
    length(candidates) >= 2 || return report
    reference_sources = first(candidates).evaluation.constraint_sources
    if any(snapshot.evaluation.constraint_sources != reference_sources for snapshot in candidates)
        push!(report, Finding(
            :reduced_hessian_active_jacobian_rank_persistence_unaligned;
            severity = SeverityInfo,
            domain = RepresentationalIssue,
            basis = StructuralProof,
            confidence = ConfidenceCertain,
            observation = "Reduced-Hessian snapshots do not share one constraint-row source ordering for active-Jacobian rank comparison.",
            why_it_matters = "First-order active-Jacobian geometry is only semantically comparable when the selected row sources are aligned across points.",
            evidence = [Evidence("Reduced-Hessian active-Jacobian alignment"; details = [
                "snapshot_count" => length(candidates),
            ])],
            suggested_actions = [
                "Evaluate the same ordered constraint rows at every point before comparing active-Jacobian rank persistence.",
            ],
        ))
        return report
    end
    ranks = [snapshot.analysis.jacobian_rank for snapshot in candidates]
    tangent_dimensions = [snapshot.analysis.tangent_dimension for snapshot in candidates]
    row_sets = [Set(snapshot.analysis.active_rows) for snapshot in candidates]
    persistent = all(==(first(ranks)), ranks) &&
                 all(==(first(tangent_dimensions)), tangent_dimensions)
    active_rows_persistent = all(==(first(row_sets)), row_sets)
    affected_rows = sort!(collect(union(row_sets...)))
    labels = join((snapshot.evaluation.point.label for snapshot in candidates), ",")
    push!(report, Finding(
        persistent ? :reduced_hessian_active_jacobian_rank_persistent :
                     :reduced_hessian_active_jacobian_rank_changing;
        severity = SeverityInfo,
        domain = NumericalIssue,
        basis = NumericalObservation,
        confidence = ConfidenceHigh,
        observation = persistent ?
                      "The reduced-Hessian active-Jacobian rank and tangent dimension are unchanged across $(length(candidates)) points." :
                      "The reduced-Hessian active-Jacobian rank or tangent dimension changes across $(length(candidates)) points.",
        why_it_matters = persistent ?
                         "Changing flat curvature under stable first-order geometry is more consistent with a second-order or derivative-value effect than a changing local rank deficiency." :
                         (active_rows_persistent ?
                          "The selected rows are unchanged, so this first-order geometry change is local derivative evidence rather than a row-selection change." :
                          "Both active-row selection and local derivative geometry may contribute; inspect the separate active-row persistence evidence."),
        evidence = [Evidence("Reduced-Hessian active-Jacobian persistence"; details = [
            "point_labels" => labels,
            "active_jacobian_ranks" => join(ranks, ","),
            "tangent_dimensions" => join(tangent_dimensions, ","),
            "active_rows_persistent" => active_rows_persistent,
        ])],
        affected = EntityRef[
            reference_sources[row] for row in affected_rows
            if 1 <= row <= length(reference_sources)
        ],
        suggested_actions = persistent ?
                            ["Use the stable first-order geometry as context when inspecting Hessian, scaling, and multiplier changes."] :
                            ["Inspect active-row persistence, Jacobian singular values, and nearby points before attributing reduced-Hessian changes to curvature alone."],
    ))
    return report
end

function _append_reduced_hessian_multiplier_persistence_findings!(
    report::DiagnosticReport,
    candidates::AbstractVector{<:ReducedHessianSnapshot{T}};
    relative_tolerance::Real,
) where {T<:AbstractFloat}
    all(!isnothing(snapshot.hessian) for snapshot in candidates) || return report
    reference_sources = first(candidates).evaluation.constraint_sources
    if any(snapshot.evaluation.constraint_sources != reference_sources for snapshot in candidates)
        push!(report, Finding(
            :reduced_hessian_multiplier_persistence_unaligned;
            severity = SeverityInfo,
            domain = RepresentationalIssue,
            basis = StructuralProof,
            confidence = ConfidenceCertain,
            observation = "Reduced-Hessian snapshots do not share one constraint-row source ordering for multiplier comparison.",
            why_it_matters = "Multiplier entries can only be compared when their constraint sources are aligned across points.",
            evidence = [Evidence("Reduced-Hessian multiplier alignment"; details = [
                "snapshot_count" => length(candidates),
            ])],
            suggested_actions = [
                "Supply Hessian snapshots evaluated against the same ordered constraint rows.",
            ],
        ))
        return report
    end
    hessians = HessianEvaluation{T}[snapshot.hessian for snapshot in candidates]
    if any(length(hessian.constraint_multipliers) != length(reference_sources)
           for hessian in hessians)
        push!(report, Finding(
            :reduced_hessian_multiplier_persistence_unavailable;
            severity = SeverityInfo,
            domain = NumericalIssue,
            basis = NumericalObservation,
            confidence = ConfidenceHigh,
            observation = "At least one retained Hessian snapshot does not provide one multiplier per evaluated constraint row.",
            why_it_matters = "A partial multiplier vector cannot be compared with a full row-aligned multiplier representative.",
            evidence = [Evidence("Reduced-Hessian multiplier availability"; details = [
                "constraint_row_count" => length(reference_sources),
                "multiplier_lengths" => join(
                    (length(hessian.constraint_multipliers) for hessian in hessians), ",",
                ),
            ])],
            suggested_actions = [
                "Retain complete row-aligned multiplier vectors with every Hessian snapshot.",
            ],
        ))
        return report
    end
    reference_hessian = first(hessians)
    maximum_difference = maximum(
        maximum(abs, hessian.constraint_multipliers .-
                 reference_hessian.constraint_multipliers; init = zero(T))
        for hessian in hessians[2:end];
        init = zero(T),
    )
    scale = maximum(
        maximum(abs, hessian.constraint_multipliers; init = zero(T))
        for hessian in hessians;
        init = one(T),
    )
    weight_difference = maximum(
        (abs(hessian.objective_weight - reference_hessian.objective_weight)
         for hessian in hessians[2:end]);
        init = zero(T),
    )
    multiplier_persistent = maximum_difference <= convert(T, relative_tolerance) * scale &&
                             weight_difference <= convert(T, relative_tolerance) *
                                                  max(one(T), abs(reference_hessian.objective_weight))
    active_rows = sort!(collect(union((Set(snapshot.analysis.active_rows) for snapshot in candidates)...)))
    push!(report, Finding(
        multiplier_persistent ? :reduced_hessian_multiplier_representative_persistent :
                               :reduced_hessian_multiplier_representative_changing;
        severity = SeverityInfo,
        domain = NumericalIssue,
        basis = NumericalObservation,
        confidence = ConfidenceHigh,
        observation = multiplier_persistent ?
                      "The retained reduced-Hessian multiplier representative is unchanged within the configured relative tolerance." :
                      "The retained reduced-Hessian multiplier representative changes across the supplied points.",
        why_it_matters = multiplier_persistent ?
                         "Stable multiplier weighting helps isolate reduced-Hessian changes to local derivatives or curvature rather than multiplier selection." :
                         "Changing multiplier representatives can alter a Lagrangian Hessian even under stable active-row geometry; this is evidence about the retained representatives, not dual uniqueness.",
        evidence = [Evidence("Reduced-Hessian multiplier persistence"; details = [
            "maximum_multiplier_difference" => maximum_difference,
            "multiplier_scale" => scale,
            "objective_weight_difference" => weight_difference,
            "relative_tolerance" => relative_tolerance,
        ])],
        affected = EntityRef[
            reference_sources[row] for row in active_rows
            if 1 <= row <= length(reference_sources)
        ],
        suggested_actions = multiplier_persistent ?
                            ["Interpret curvature changes together with derivative and Hessian changes, retaining multiplier representative evidence."] :
                            ["Inspect multiplier recovery uniqueness and active-gradient dependence before attributing reduced-Hessian changes to primal curvature."],
    ))
    return report
end

function _scale_ratio_change_factor(
    left::Union{Nothing,T},
    right::Union{Nothing,T},
    ::Type{T},
) where {T<:AbstractFloat}
    isnothing(left) && isnothing(right) && return one(T)
    (isnothing(left) || isnothing(right)) && return T(Inf)
    (isfinite(left) && isfinite(right) && !iszero(left) && !iszero(right)) ||
        return T(Inf)
    return max(left / right, right / left)
end

"""
    analyze_jacobian_scaling_persistence(evaluations; ...)

Compare Jacobian row- and column-scale spread at explicitly supplied points.
This is numerical scaling evidence, not a rank estimate or a mathematical
explanation for a changing derivative scale.
"""
function analyze_jacobian_scaling_persistence(
    evaluations::AbstractVector{<:NumericalEvaluation{T}};
    minimum_evaluations::Integer = 2,
    change_factor_threshold::Real = 100,
) where {T<:AbstractFloat}
    minimum_evaluations >= 2 ||
        throw(ArgumentError("minimum_evaluations must be at least two"))
    change_factor_threshold >= one(T) ||
        throw(ArgumentError("change_factor_threshold must be at least one"))
    report = DiagnosticReport()
    report.metadata[:stage] = "jacobian_scaling_persistence"
    report.metadata[:evaluation_count] = string(length(evaluations))
    report.metadata[:minimum_evaluations] = string(minimum_evaluations)
    report.metadata[:change_factor_threshold] = string(change_factor_threshold)
    if length(evaluations) < minimum_evaluations
        push!(report, Finding(:jacobian_scaling_persistence_unavailable;
            severity = SeverityInfo, domain = NumericalIssue,
            basis = NumericalObservation, confidence = ConfidenceHigh,
            observation = "Only $(length(evaluations)) explicitly supplied evaluation(s) are available for Jacobian scaling persistence.",
            why_it_matters = "Cross-point scaling comparison requires at least $(minimum_evaluations) evaluations.",
            evidence = [Evidence("Jacobian scaling persistence availability"; details = [
                "evaluation_count" => length(evaluations),
                "minimum_evaluations" => minimum_evaluations,
            ])],
            suggested_actions = ["Supply multiple evaluations over the operating region of interest."],
        ))
        return report
    end
    reference_variables = first(evaluations).point.variables
    reference_rows = first(evaluations).constraint_sources
    if any(evaluation.point.variables != reference_variables for evaluation in evaluations) ||
       any(evaluation.constraint_sources != reference_rows for evaluation in evaluations)
        push!(report, Finding(:jacobian_scaling_persistence_coordinate_mismatch;
            severity = SeverityInfo, domain = RepresentationalIssue,
            basis = StructuralProof, confidence = ConfidenceCertain,
            observation = "Jacobian evaluations do not share one ordered variable and constraint-row scope.",
            why_it_matters = "Row and column scale changes are comparable only in common coordinates.",
            evidence = [Evidence("Jacobian scaling persistence alignment"; details = [
                "evaluation_count" => length(evaluations),
            ])],
            suggested_actions = ["Evaluate the same ordered variable coordinates and scalar constraint rows at every point."],
        ))
        return report
    end
    summaries = jacobian_scale_summary.(evaluations)
    report.metadata[:nonfinite_row_counts] = join(
        (length(summary.nonfinite_rows) for summary in summaries), ",",
    )
    report.metadata[:nonfinite_column_counts] = join(
        (length(summary.nonfinite_columns) for summary in summaries), ",",
    )
    if any(!isempty(summary.nonfinite_rows) || !isempty(summary.nonfinite_columns)
           for summary in summaries)
        push!(report, Finding(:jacobian_scaling_persistence_unavailable;
            severity = SeverityInfo, domain = NumericalIssue,
            basis = NumericalObservation, confidence = ConfidenceHigh,
            observation = "Jacobian scaling persistence is unavailable because at least one supplied evaluation has non-finite derivatives.",
            why_it_matters = "Scale ratios cannot be safely compared across non-finite derivative observations.",
            evidence = [Evidence("Jacobian scaling persistence availability"; details = [
                "point_labels" => join((evaluation.point.label for evaluation in evaluations), ","),
                "nonfinite_row_counts" => report.metadata[:nonfinite_row_counts],
                "nonfinite_column_counts" => report.metadata[:nonfinite_column_counts],
            ])],
            suggested_actions = ["Resolve derivative-domain or numerical failures before interpreting cross-point scaling changes."],
        ))
        return report
    end
    reference = first(summaries)
    row_change_factor = maximum((
        _scale_ratio_change_factor(reference.row_scale_ratio, summary.row_scale_ratio, T)
        for summary in summaries[2:end]
    ); init = one(T))
    column_change_factor = maximum((
        _scale_ratio_change_factor(reference.column_scale_ratio, summary.column_scale_ratio, T)
        for summary in summaries[2:end]
    ); init = one(T))
    persistent = row_change_factor <= convert(T, change_factor_threshold) &&
                 column_change_factor <= convert(T, change_factor_threshold)
    report.metadata[:row_change_factor] = string(row_change_factor)
    report.metadata[:column_change_factor] = string(column_change_factor)
    push!(report, Finding(
        persistent ? :jacobian_scaling_persistent : :jacobian_scaling_changing;
        severity = persistent ? SeverityInfo : SeverityWarning,
        domain = NumericalIssue,
        basis = NumericalObservation,
        confidence = ConfidenceHigh,
        observation = persistent ?
                      "Jacobian row and column scale-spread ratios remain within a factor of $(change_factor_threshold) across $(length(evaluations)) supplied points." :
                      "Jacobian row or column scale-spread ratios change by more than the configured factor across $(length(evaluations)) supplied points.",
        why_it_matters = persistent ?
                         "Stable derivative scaling helps distinguish repeated rank evidence from changing numerical scale." :
                         "Changing derivative scale spread can change rank thresholds, conditioning, and solver-tolerance semantics without proving a mathematical defect.",
        evidence = [Evidence("Jacobian scaling persistence"; details = [
            "point_labels" => join((evaluation.point.label for evaluation in evaluations), ","),
            "row_scale_ratios" => join((summary.row_scale_ratio for summary in summaries), ","),
            "column_scale_ratios" => join((summary.column_scale_ratio for summary in summaries), ","),
            "row_change_factor" => row_change_factor,
            "column_change_factor" => column_change_factor,
            "change_factor_threshold" => change_factor_threshold,
        ])],
        affected = vcat(
            EntityRef[reference_rows[row] for row in eachindex(reference_rows)],
            EntityRef[EntityRef(:variable, variable.value) for variable in reference_variables],
        ),
        suggested_actions = persistent ?
                            ["Use the stable scaling evidence when interpreting cross-point rank changes."] :
                            ["Inspect derivative row/column norms, units, and solver scaling before treating rank changes as intrinsic."],
    ))
    return report
end

"""Evaluate explicit points before running Jacobian scaling persistence analysis."""
function analyze_jacobian_scaling_persistence(
    model::MOI.ModelLike,
    points::AbstractVector{<:EvaluationPoint};
    cache::EvaluationCache = EvaluationCache(),
    relative_step::Union{Nothing,Real} = nothing,
    kwargs...,
)
    evaluations = [
        isnothing(relative_step) ? evaluate_numerical(model, point; cache = cache) :
        evaluate_numerical(model, point; cache = cache, relative_step = relative_step)
        for point in points
    ]
    return analyze_jacobian_scaling_persistence(evaluations; kwargs...)
end

"""
    analyze_jacobian_derivative_provenance_persistence(evaluations; ...)

Compare the row-level derivative methods recorded at explicit points. This
checks evidence provenance only; it does not compare derivative values or
certify the accuracy of any recorded method.
"""
function analyze_jacobian_derivative_provenance_persistence(
    evaluations::AbstractVector{<:NumericalEvaluation};
    minimum_evaluations::Integer = 2,
)
    minimum_evaluations >= 2 ||
        throw(ArgumentError("minimum_evaluations must be at least two"))
    report = DiagnosticReport()
    report.metadata[:stage] = "jacobian_derivative_provenance_persistence"
    report.metadata[:evaluation_count] = string(length(evaluations))
    report.metadata[:minimum_evaluations] = string(minimum_evaluations)
    if length(evaluations) < minimum_evaluations
        push!(report, Finding(:jacobian_derivative_provenance_persistence_unavailable;
            severity = SeverityInfo, domain = NumericalIssue,
            basis = NumericalObservation, confidence = ConfidenceHigh,
            observation = "Only $(length(evaluations)) explicitly supplied evaluation(s) are available for Jacobian derivative-provenance persistence.",
            why_it_matters = "Cross-point method comparison requires at least $(minimum_evaluations) evaluations.",
            evidence = [Evidence("Jacobian derivative-provenance persistence availability"; details = [
                "evaluation_count" => length(evaluations),
                "minimum_evaluations" => minimum_evaluations,
            ])],
            suggested_actions = ["Supply multiple evaluations over the operating region of interest."],
        ))
        return report
    end
    reference_rows = first(evaluations).constraint_sources
    if any(evaluation.constraint_sources != reference_rows for evaluation in evaluations)
        push!(report, Finding(:jacobian_derivative_provenance_persistence_coordinate_mismatch;
            severity = SeverityInfo, domain = RepresentationalIssue,
            basis = StructuralProof, confidence = ConfidenceCertain,
            observation = "Jacobian evaluations do not share one ordered constraint-row scope.",
            why_it_matters = "Derivative methods can be compared only when each row refers to the same scalar constraint across points.",
            evidence = [Evidence("Jacobian derivative-provenance persistence alignment"; details = [
                "evaluation_count" => length(evaluations),
            ])],
            suggested_actions = ["Evaluate the same ordered scalar constraint rows at every point."],
        ))
        return report
    end
    if any(length(evaluation.jacobian_row_methods) != length(reference_rows)
           for evaluation in evaluations)
        push!(report, Finding(:jacobian_derivative_provenance_persistence_unavailable;
            severity = SeverityInfo, domain = NumericalIssue,
            basis = NumericalObservation, confidence = ConfidenceHigh,
            observation = "At least one evaluation lacks one row-level derivative-provenance label.",
            why_it_matters = "Method persistence cannot be assessed without one label for every common Jacobian row.",
            evidence = [Evidence("Jacobian derivative-provenance persistence availability"; details = [
                "row_count" => length(reference_rows),
                "method_counts" => join((length(evaluation.jacobian_row_methods) for evaluation in evaluations), ","),
            ])],
            suggested_actions = ["Capture complete row-level derivative provenance before comparing points."],
        ))
        return report
    end
    methods_by_row = [
        Symbol[evaluation.jacobian_row_methods[row] for evaluation in evaluations]
        for row in eachindex(reference_rows)
    ]
    changing_rows = findall(methods -> !all(==(first(methods)), methods), methods_by_row)
    incomplete_rows = findall(methods -> any(
        method -> method in (:unavailable, :partial_central_finite_difference), methods,
    ), methods_by_row)
    report.metadata[:stable_row_count] = string(length(reference_rows) - length(changing_rows))
    report.metadata[:changing_row_count] = string(length(changing_rows))
    report.metadata[:incomplete_row_count] = string(length(incomplete_rows))
    report.metadata[:point_labels] = join((evaluation.point.label for evaluation in evaluations), ",")
    if !isempty(incomplete_rows)
        push!(report, Finding(:jacobian_derivative_provenance_persistence_incomplete;
            severity = SeverityWarning, domain = NumericalIssue,
            basis = NumericalObservation, confidence = ConfidenceHigh,
            observation = "$(length(incomplete_rows)) Jacobian row(s) use unavailable or partial finite-difference derivative evidence at one or more supplied points.",
            why_it_matters = "Rank and scaling changes involving these rows may reflect incomplete derivative evidence rather than changing model geometry.",
            evidence = [Evidence("Jacobian derivative-provenance persistence"; details = [
                "point_labels" => report.metadata[:point_labels],
                "incomplete_rows" => join(incomplete_rows, ","),
                "row_methods" => join((join(methods_by_row[row], "->") for row in incomplete_rows), ";"),
            ])],
            affected = reference_rows[incomplete_rows],
            suggested_actions = ["Resolve derivative-domain and finite-difference failures before interpreting cross-point rank or scaling changes."],
        ))
    end
    persistent = isempty(changing_rows)
    push!(report, Finding(
        persistent ? :jacobian_derivative_provenance_persistent :
                     :jacobian_derivative_provenance_changing;
        severity = persistent ? SeverityInfo : SeverityWarning,
        domain = persistent ? RepresentationalIssue : NumericalIssue,
        basis = NumericalObservation,
        confidence = isempty(incomplete_rows) ? ConfidenceHigh : ConfidenceMedium,
        observation = persistent ?
                      "Jacobian row-level derivative provenance is unchanged across $(length(evaluations)) explicitly supplied points." :
                      "Jacobian row-level derivative provenance changes for $(length(changing_rows)) row(s) across $(length(evaluations)) explicitly supplied points.",
        why_it_matters = persistent ?
                         "Stable provenance makes a cross-point derivative comparison easier to interpret, without proving derivative accuracy." :
                         "A rank, conditioning, or scaling change can be influenced by changing derivative construction or fallback behavior; this is provenance evidence, not a solver or model-defect claim.",
        evidence = [Evidence("Jacobian derivative-provenance persistence"; details = [
            "point_labels" => report.metadata[:point_labels],
            "changing_rows" => join(changing_rows, ","),
            "row_methods" => join((join(methods, "->") for methods in methods_by_row), ";"),
        ])],
        affected = persistent ? copy(reference_rows) : reference_rows[changing_rows],
        suggested_actions = persistent ?
                            ["Use the stable provenance alongside value, scaling, and rank evidence."] :
                            ["Compare the affected rows under one verified derivative method before attributing a numerical-geometry change to the formulation."],
    ))
    return report
end

"""Evaluate explicit points before comparing Jacobian derivative provenance."""
function analyze_jacobian_derivative_provenance_persistence(
    model::MOI.ModelLike,
    points::AbstractVector{<:EvaluationPoint};
    cache::EvaluationCache = EvaluationCache(),
    relative_step::Union{Nothing,Real} = nothing,
    kwargs...,
)
    evaluations = [
        isnothing(relative_step) ? evaluate_numerical(model, point; cache = cache) :
        evaluate_numerical(model, point; cache = cache, relative_step = relative_step)
        for point in points
    ]
    return analyze_jacobian_derivative_provenance_persistence(evaluations; kwargs...)
end

function _append_reduced_hessian_jacobian_scaling_persistence_findings!(
    report::DiagnosticReport,
    candidates::AbstractVector{<:ReducedHessianSnapshot{T}};
    change_factor_threshold::Real,
) where {T<:AbstractFloat}
    length(candidates) >= 2 || return report
    reference_sources = first(candidates).evaluation.constraint_sources
    if any(snapshot.evaluation.constraint_sources != reference_sources for snapshot in candidates)
        push!(report, Finding(
            :reduced_hessian_jacobian_scaling_persistence_unaligned;
            severity = SeverityInfo,
            domain = RepresentationalIssue,
            basis = StructuralProof,
            confidence = ConfidenceCertain,
            observation = "Reduced-Hessian snapshots do not share one constraint-row source ordering for Jacobian scaling comparison.",
            why_it_matters = "Row-scale changes are only semantically comparable when their constraint rows are aligned across points.",
            evidence = [Evidence("Reduced-Hessian Jacobian scaling alignment"; details = [
                "snapshot_count" => length(candidates),
            ])],
            suggested_actions = [
                "Evaluate the same ordered constraint rows at every point before comparing Jacobian scaling persistence.",
            ],
        ))
        return report
    end
    summaries = [jacobian_scale_summary(snapshot.evaluation) for snapshot in candidates]
    if any(!isempty(summary.nonfinite_rows) || !isempty(summary.nonfinite_columns)
           for summary in summaries)
        push!(report, Finding(
            :reduced_hessian_jacobian_scaling_persistence_unavailable;
            severity = SeverityInfo,
            domain = NumericalIssue,
            basis = NumericalObservation,
            confidence = ConfidenceHigh,
            observation = "Jacobian scaling persistence is unavailable because at least one snapshot has non-finite row or column derivatives.",
            why_it_matters = "Scale ratios cannot be safely compared across non-finite derivative observations.",
            evidence = [Evidence("Reduced-Hessian Jacobian scaling availability"; details = [
                "nonfinite_row_counts" => join(
                    (length(summary.nonfinite_rows) for summary in summaries), ",",
                ),
                "nonfinite_column_counts" => join(
                    (length(summary.nonfinite_columns) for summary in summaries), ",",
                ),
            ])],
            suggested_actions = [
                "Resolve derivative-domain or numerical failures before interpreting cross-point scaling changes.",
            ],
        ))
        return report
    end
    reference_summary = first(summaries)
    row_change_factor = maximum(
        (_scale_ratio_change_factor(
            reference_summary.row_scale_ratio, summary.row_scale_ratio,
            T,
        ) for summary in summaries[2:end]);
        init = one(T),
    )
    column_change_factor = maximum(
        (_scale_ratio_change_factor(
            reference_summary.column_scale_ratio, summary.column_scale_ratio,
            T,
        ) for summary in summaries[2:end]);
        init = one(T),
    )
    persistent = row_change_factor <= convert(T, change_factor_threshold) &&
                 column_change_factor <= convert(T, change_factor_threshold)
    labels = join((snapshot.evaluation.point.label for snapshot in candidates), ",")
    push!(report, Finding(
        persistent ? :reduced_hessian_jacobian_scaling_persistent :
                     :reduced_hessian_jacobian_scaling_changing;
        severity = SeverityInfo,
        domain = NumericalIssue,
        basis = NumericalObservation,
        confidence = ConfidenceHigh,
        observation = persistent ?
                      "Jacobian row and column scale-spread ratios remain within a factor of $(change_factor_threshold) across $(length(candidates)) points." :
                      "Jacobian row or column scale-spread ratios change by more than the configured factor across $(length(candidates)) points.",
        why_it_matters = persistent ?
                         "Stable derivative scaling helps isolate rank or curvature changes from operating-point-dependent scale spread." :
                         "Changing derivative scale spread can alter rank thresholds, linear-system conditioning, and tolerance semantics without proving a mathematical model defect.",
        evidence = [Evidence("Reduced-Hessian Jacobian scaling persistence"; details = [
            "point_labels" => labels,
            "row_scale_ratios" => join((summary.row_scale_ratio for summary in summaries), ","),
            "column_scale_ratios" => join((summary.column_scale_ratio for summary in summaries), ","),
            "row_change_factor" => row_change_factor,
            "column_change_factor" => column_change_factor,
            "change_factor_threshold" => change_factor_threshold,
        ])],
        affected = EntityRef[
            EntityRef(:variable, variable.value)
            for variable in first(candidates).evaluation.point.variables
        ],
        suggested_actions = persistent ?
                            ["Use the stable scaling evidence when interpreting cross-point rank and curvature changes."] :
                            ["Inspect row/column norm changes, coordinate units, and solver scaling before treating rank or curvature changes as intrinsic."],
    ))
    return report
end

function _spectral_scale_change_factor(left::T, right::T) where {T<:AbstractFloat}
    iszero(left) && iszero(right) && return one(T)
    (isfinite(left) && isfinite(right) && !iszero(left) && !iszero(right)) ||
        return T(Inf)
    return max(left / right, right / left)
end

function _append_reduced_hessian_spectral_scale_persistence_findings!(
    report::DiagnosticReport,
    candidates::AbstractVector{<:ReducedHessianSnapshot{T}};
    change_factor_threshold::Real,
) where {T<:AbstractFloat}
    length(candidates) >= 2 || return report
    spectral_scales = [
        maximum(abs, snapshot.analysis.eigenvalues; init = zero(T))
        for snapshot in candidates
    ]
    if any(!isfinite, spectral_scales)
        push!(report, Finding(
            :reduced_hessian_spectral_scale_persistence_unavailable;
            severity = SeverityInfo,
            domain = NumericalIssue,
            basis = NumericalObservation,
            confidence = ConfidenceHigh,
            observation = "Reduced-Hessian spectral-scale persistence is unavailable because at least one local spectrum is non-finite.",
            why_it_matters = "A finite curvature-magnitude comparison cannot be made from non-finite eigenvalue evidence.",
            evidence = [Evidence("Reduced-Hessian spectral-scale availability"; details = [
                "spectral_scales" => join(spectral_scales, ","),
            ])],
            suggested_actions = [
                "Resolve Hessian or derivative non-finiteness before comparing local curvature scale across points.",
            ],
        ))
        return report
    end
    reference_scale = first(spectral_scales)
    change_factor = maximum(
        (_spectral_scale_change_factor(reference_scale, scale)
         for scale in spectral_scales[2:end]);
        init = one(T),
    )
    persistent = change_factor <= convert(T, change_factor_threshold)
    labels = join((snapshot.evaluation.point.label for snapshot in candidates), ",")
    push!(report, Finding(
        persistent ? :reduced_hessian_spectral_scale_persistent :
                     :reduced_hessian_spectral_scale_changing;
        severity = SeverityInfo,
        domain = NumericalIssue,
        basis = NumericalObservation,
        confidence = ConfidenceHigh,
        observation = persistent ?
                      "Reduced-Hessian spectral scale remains within a factor of $(change_factor_threshold) across $(length(candidates)) points." :
                      "Reduced-Hessian spectral scale changes by more than the configured factor across $(length(candidates)) points.",
        why_it_matters = persistent ?
                         "Stable curvature magnitude helps distinguish changing flat-direction geometry from a broad change in local second-order scale." :
                         "Changing curvature magnitude can alter Newton-step behavior and reduced-Hessian thresholds without, by itself, proving a bifurcation or modeling error.",
        evidence = [Evidence("Reduced-Hessian spectral-scale persistence"; details = [
            "point_labels" => labels,
            "spectral_scales" => join(spectral_scales, ","),
            "change_factor" => change_factor,
            "change_factor_threshold" => change_factor_threshold,
            "tangent_dimensions" => join(
                (snapshot.analysis.tangent_dimension for snapshot in candidates), ",",
            ),
        ])],
        affected = EntityRef[
            EntityRef(:variable, variable.value)
            for variable in first(candidates).evaluation.point.variables
        ],
        suggested_actions = persistent ?
                            ["Interpret changing flat-direction orientation together with stable curvature magnitude and first-order geometry."] :
                            ["Inspect Hessian terms, multiplier representatives, and coordinate scaling before assigning a physical cause to curvature-scale changes."],
    ))
    return report
end

function _append_persistent_flat_component_metadata_findings!(
    report::DiagnosticReport,
    snapshots::AbstractVector{<:ReducedHessianSnapshot{T}},
    components::AbstractVector{<:ComponentMetadata};
    support_relative_tolerance::Real,
) where {T<:AbstractFloat}
    report.metadata[:persistent_flat_declared_component_count] = string(length(components))
    isempty(components) && return report
    support_variables = _persistent_flat_support_variables(
        snapshots, support_relative_tolerance,
    )
    overlaps = [
        component for component in components
        if !isempty(intersect(component.variables, support_variables))
    ]
    report.metadata[:persistent_flat_overlapping_component_count] = string(length(overlaps))
    isempty(overlaps) && return report
    affected_variables = unique(vcat(
        (intersect(component.variables, support_variables) for component in overlaps)...,
    ))
    component_labels = join(
        ("$(component.component_type):$(component.component_id)" for component in overlaps),
        ",",
    )
    push!(report, Finding(
        :reduced_hessian_persistent_flat_declared_component_overlap;
        severity = SeverityInfo,
        domain = RepresentationalIssue,
        basis = PhysicalExpectation,
        confidence = ConfidenceHigh,
        observation = "The persistent flat subspace overlaps $(length(overlaps)) domain-declared component scope(s).",
        why_it_matters = "Plugin-declared component ownership gives inspectable domain context for a persistent numerical mode, but does not validate the metadata or identify a physical cause.",
        evidence = [Evidence("Persistent flat-mode declared component overlap"; details = [
            "components" => component_labels,
            "overlap_variable_count" => length(affected_variables),
            "support_relative_tolerance" => support_relative_tolerance,
        ])],
        affected = EntityRef[
            EntityRef(:variable, variable.value) for variable in affected_variables
        ],
        suggested_actions = [
            "Inspect the listed declared components alongside their expected rank, units, and mode declarations.",
            "Treat metadata overlap as domain context, then confirm the mechanism with constraints and nearby points.",
        ],
    ))
    return report
end

function _orthonormal_mode_basis(
    directions::Matrix{T};
    relative_tolerance::Real,
) where {T<:AbstractFloat}
    isempty(directions) && return zeros(T, size(directions, 1), 0)
    factorization = svd(directions)
    isempty(factorization.S) && return zeros(T, size(directions, 1), 0)
    threshold = convert(T, relative_tolerance) * maximum(factorization.S)
    rank = count(value -> value > threshold, factorization.S)
    return factorization.U[:, 1:rank]
end

function _append_persistent_flat_expected_mode_findings!(
    report::DiagnosticReport,
    snapshots::AbstractVector{<:ReducedHessianSnapshot{T}},
    modes::AbstractVector{<:ExpectedNullspaceMode};
    alignment_threshold::Real,
    mode_rank_relative_tolerance::Real,
) where {T<:AbstractFloat}
    report.metadata[:persistent_flat_expected_mode_count] = string(length(modes))
    isempty(modes) && return report
    reference_variables = first(snapshots).evaluation.point.variables
    columns_by_variable = Dict(
        variable => column for (column, variable) in enumerate(reference_variables)
    )
    directions = zeros(T, length(reference_variables), length(modes))
    for (mode_column, mode) in enumerate(modes)
        coordinates = [get(columns_by_variable, variable, 0) for variable in mode.variables]
        if any(iszero, coordinates)
            push!(report, Finding(
                :reduced_hessian_persistent_expected_mode_subspace_unaligned;
                severity = SeverityInfo,
                domain = RepresentationalIssue,
                basis = StructuralProof,
                confidence = ConfidenceCertain,
                observation = "Declared expected mode $(mode.name) cannot be aligned with the persistent flat-subspace coordinates.",
                why_it_matters = "A subspace comparison requires every declared mode to use the shared evaluation-coordinate scope.",
                evidence = [Evidence("Persistent flat-mode expected declaration"; details = [
                    "mode" => mode.name,
                    "description" => mode.description,
                ])],
                suggested_actions = [
                    "Declare expected modes using the shared evaluation-point variable coordinates.",
                ],
            ))
            return report
        end
        for (coordinate, value) in zip(coordinates, mode.direction)
            directions[coordinate, mode_column] += convert(T, value)
        end
    end
    declared_basis = _orthonormal_mode_basis(
        directions; relative_tolerance = mode_rank_relative_tolerance,
    )
    flat_basis = _flat_reduced_hessian_subspace(first(filter(
        snapshot -> snapshot.analysis.available && snapshot.analysis.zero_eigenvalues > 0,
        snapshots,
    )).analysis)
    declared_dimension = size(declared_basis, 2)
    flat_dimension = size(flat_basis, 2)
    singular_values = declared_dimension == 0 ? T[] :
                      svdvals(transpose(flat_basis) * declared_basis)
    minimum_alignment = isempty(singular_values) ? zero(T) : minimum(singular_values)
    observed = declared_dimension > 0 && declared_dimension <= flat_dimension &&
               minimum_alignment >= convert(T, alignment_threshold)
    report.metadata[:persistent_flat_expected_mode_span_dimension] = string(declared_dimension)
    report.metadata[:persistent_flat_subspace_dimension] = string(flat_dimension)
    affected = EntityRef[]
    for mode in modes, variable in mode.variables
        push!(affected, EntityRef(:variable, variable.value))
    end
    unique!(affected)
    push!(report, Finding(
        observed ? :reduced_hessian_persistent_expected_mode_subspace_observed :
                   :reduced_hessian_persistent_expected_mode_subspace_not_observed;
        severity = SeverityInfo,
        domain = RepresentationalIssue,
        basis = observed ? PhysicalExpectation : LocalInference,
        confidence = observed ? ConfidenceHigh : ConfidenceMedium,
        observation = observed ?
                      "The declared expected-mode span is aligned with the persistent reduced-Hessian flat subspace." :
                      "The declared expected-mode span is not aligned with the persistent reduced-Hessian flat subspace.",
        why_it_matters = observed ?
                         "Repeated local curvature is consistent with the declared mode span, without validating the declaration's physical interpretation." :
                         "A declared mode can be removed, supplemented, or rotated by the operating point and active geometry; this is persistent numerical evidence, not a plugin error.",
        evidence = [Evidence("Persistent flat-subspace expected-mode comparison"; details = [
            "declared_mode_count" => length(modes),
            "declared_span_dimension" => declared_dimension,
            "flat_subspace_dimension" => flat_dimension,
            "minimum_principal_cosine" => minimum_alignment,
            "alignment_threshold" => alignment_threshold,
        ])],
        affected = affected,
        suggested_actions = observed ?
                            ["Retain the declaration as expected-mode evidence and confirm the units and domain semantics in the plugin."] :
                            ["Inspect active geometry and nearby points before changing the declared expected-mode span."],
    ))
    return report
end

"""Compare a declared expected-mode span with every persistent right-nullspace."""
function _append_persistent_jacobian_expected_mode_span_findings!(
    report::DiagnosticReport,
    modes::AbstractVector{<:ExpectedNullspaceMode},
    variables::AbstractVector{MOI.VariableIndex},
    estimates::AbstractVector{<:JacobianRankEstimate{T}},
    point_labels::AbstractString;
    alignment_threshold::Real,
    mode_rank_relative_tolerance::Real,
) where {T<:AbstractFloat}
    report.metadata[:persistent_jacobian_expected_mode_span_count] = string(length(modes))
    isempty(modes) && return report
    zero(T) <= alignment_threshold <= one(T) ||
        throw(ArgumentError("expected_mode_span_alignment_threshold must lie in [0, 1]"))
    mode_rank_relative_tolerance >= zero(T) || throw(ArgumentError(
        "expected-mode span relative tolerance must be nonnegative",
    ))
    columns_by_variable = Dict(variable => column for (column, variable) in enumerate(variables))
    directions = zeros(T, length(variables), length(modes))
    affected = EntityRef[]
    for (mode_column, mode) in enumerate(modes)
        missing = Int[]
        for (variable, coefficient) in zip(mode.variables, mode.direction)
            column = get(columns_by_variable, variable, 0)
            if iszero(column)
                push!(missing, variable.value)
            else
                directions[column, mode_column] += convert(T, coefficient)
            end
            push!(affected, EntityRef(:variable, variable.value))
        end
        if !isempty(missing)
            push!(report, Finding(:persistent_jacobian_expected_mode_span_unaligned;
                severity = SeverityInfo, domain = RepresentationalIssue,
                basis = StructuralProof, confidence = ConfidenceCertain,
                observation = "The declared expected-mode span cannot be aligned with the common Jacobian persistence coordinates.",
                why_it_matters = "A span comparison requires every declared coordinate to be present at every supplied point.",
                evidence = [Evidence("Persistent Jacobian expected-mode span alignment"; details = [
                    "mode" => mode.name,
                    "unaligned_variable_indices" => join(missing, ","),
                ])],
                suggested_actions = ["Declare every expected mode in the common evaluation-coordinate scope."],
            ))
            return report
        end
    end
    unique!(affected)
    declared_basis = _orthonormal_mode_basis(
        directions; relative_tolerance = mode_rank_relative_tolerance,
    )
    declared_dimension = size(declared_basis, 2)
    minimum_cosine = one(T)
    observed_dimensions = Int[]
    for estimate in estimates
        nullspace = estimate.right_nullspace
        push!(observed_dimensions, size(nullspace, 2))
        cosines = declared_dimension == 0 ? T[] :
                  svdvals(transpose(nullspace) * declared_basis)
        minimum_cosine = min(
            minimum_cosine,
            isempty(cosines) ? zero(T) : minimum(cosines),
        )
    end
    observed = declared_dimension > 0 &&
               all(dimension -> declared_dimension <= dimension, observed_dimensions) &&
               minimum_cosine >= convert(T, alignment_threshold)
    report.metadata[:persistent_jacobian_expected_mode_span_dimension] =
        string(declared_dimension)
    report.metadata[:persistent_jacobian_expected_mode_span_minimum_principal_cosine] =
        string(minimum_cosine)
    push!(report, Finding(
        observed ? :persistent_jacobian_expected_mode_span_observed :
                   :persistent_jacobian_expected_mode_span_not_observed;
        severity = SeverityInfo,
        domain = RepresentationalIssue,
        basis = observed ? PhysicalExpectation : LocalInference,
        confidence = observed ? ConfidenceHigh : ConfidenceMedium,
        observation = observed ?
                      "The declared expected-mode span aligns with the persistent local Jacobian right-nullspace at every supplied point." :
                      "The declared expected-mode span does not align with the persistent local Jacobian right-nullspace at every supplied point.",
        why_it_matters = observed ?
                         "The repeated local nullspace is consistent with the declared span, without proving its physical interpretation or global invariance." :
                         "Individual expected modes can appear plausible while their collective span is too large, dependent, or misaligned; this is local numerical evidence rather than a plugin error.",
        evidence = [Evidence("Persistent Jacobian expected-mode span comparison"; details = [
            "point_labels" => point_labels,
            "declared_mode_count" => length(modes),
            "declared_span_dimension" => declared_dimension,
            "observed_right_nullities" => join(observed_dimensions, ","),
            "minimum_principal_cosine" => minimum_cosine,
            "alignment_threshold" => alignment_threshold,
        ])],
        affected = affected,
        suggested_actions = observed ?
                            ["Retain the span as expected-mode evidence and confirm its semantics in the relevant plugin."] :
                            ["Inspect declared mode independence, coordinate scope, and nearby active geometry before changing the declaration."],
    ))
    return report
end

"""
    analyze_jacobian_rank_persistence(evaluations; ...)

Compare caller-supplied Jacobian rank and right-nullspace evidence across
explicitly chosen points. This is a cross-point numerical screen: a persistent
subspace is not, by itself, a structural or physical explanation.
"""
function analyze_jacobian_rank_persistence(
    evaluations::AbstractVector{<:NumericalEvaluation{T}};
    minimum_evaluations::Integer = 2,
    relative_tolerance::Real = maximum((
        max(length(evaluation.constraint_sources), length(evaluation.point.variables), 1)
        for evaluation in evaluations); init = 1) * eps(T),
    max_dense_entries::Integer = 4_000_000,
    subspace_alignment_threshold::Real = 0.98,
    scaling_change_factor_threshold::Real = 100,
    left_nullspace_support_relative::Real = 0.1,
    right_nullspace_support_relative::Real = 0.1,
    expected_modes::AbstractVector{<:ExpectedNullspaceMode} = ExpectedNullspaceMode[],
    expected_mode_residual_tolerance::Real = sqrt(eps(T)),
    expected_mode_span_alignment_threshold::Real = 0.98,
    expected_mode_span_rank_relative_tolerance::Real = sqrt(eps(T)),
) where {T<:AbstractFloat}
    minimum_evaluations >= 2 ||
        throw(ArgumentError("minimum_evaluations must be at least two"))
    tolerance = convert(T, relative_tolerance)
    tolerance >= zero(T) ||
        throw(ArgumentError("relative_tolerance must be nonnegative"))
    zero(T) <= subspace_alignment_threshold <= one(T) ||
        throw(ArgumentError("subspace_alignment_threshold must lie in [0, 1]"))
    scaling_change_factor_threshold >= one(T) ||
        throw(ArgumentError("scaling_change_factor_threshold must be at least one"))
    zero(T) < left_nullspace_support_relative <= one(T) ||
        throw(ArgumentError("left_nullspace_support_relative must lie in (0, 1]"))
    zero(T) < right_nullspace_support_relative <= one(T) ||
        throw(ArgumentError("right_nullspace_support_relative must lie in (0, 1]"))
    expected_mode_residual_tolerance >= zero(T) ||
        throw(ArgumentError("expected_mode_residual_tolerance must be nonnegative"))
    zero(T) <= expected_mode_span_alignment_threshold <= one(T) ||
        throw(ArgumentError("expected_mode_span_alignment_threshold must lie in [0, 1]"))
    expected_mode_span_rank_relative_tolerance >= zero(T) ||
        throw(ArgumentError("expected_mode_span_rank_relative_tolerance must be nonnegative"))
    report = DiagnosticReport()
    report.metadata[:stage] = "jacobian_rank_persistence"
    report.metadata[:evaluation_count] = string(length(evaluations))
    report.metadata[:minimum_evaluations] = string(minimum_evaluations)
    report.metadata[:relative_tolerance] = string(tolerance)
    report.metadata[:subspace_alignment_threshold] = string(subspace_alignment_threshold)
    report.metadata[:scaling_change_factor_threshold] =
        string(scaling_change_factor_threshold)
    report.metadata[:left_nullspace_support_relative] =
        string(left_nullspace_support_relative)
    report.metadata[:right_nullspace_support_relative] =
        string(right_nullspace_support_relative)
    report.metadata[:expected_mode_count] = string(length(expected_modes))
    report.metadata[:expected_mode_span_alignment_threshold] =
        string(expected_mode_span_alignment_threshold)
    report.metadata[:expected_mode_span_rank_relative_tolerance] =
        string(expected_mode_span_rank_relative_tolerance)
    isempty(evaluations) && return report
    reference_variables = evaluations[1].point.variables
    reference_rows = evaluations[1].constraint_sources
    if any(evaluation.point.variables != reference_variables for evaluation in evaluations) ||
       any(evaluation.constraint_sources != reference_rows for evaluation in evaluations)
        push!(report, Finding(:jacobian_rank_persistence_coordinate_mismatch;
            severity = SeverityInfo, domain = RepresentationalIssue,
            basis = StructuralProof, confidence = ConfidenceCertain,
            observation = "Jacobian evaluations do not share one ordered variable and constraint-row scope.",
            why_it_matters = "Rank and nullspace persistence require the same coordinates and rows at every explicitly supplied point.",
            evidence = [Evidence("Jacobian persistence alignment"; details = [
                "evaluation_count" => length(evaluations),
            ])],
            suggested_actions = ["Evaluate the same ordered variable coordinates and scalar constraint rows at every point."],
        ))
        return report
    end
    estimates = JacobianRankEstimate{T}[
        jacobian_rank_estimate(
            evaluation;
            relative_tolerance = tolerance,
            max_dense_entries = max_dense_entries,
            compute_vectors = true,
        ) for evaluation in evaluations
    ]
    candidates = findall(estimate -> estimate.available, estimates)
    report.metadata[:available_evaluation_count] = string(length(candidates))
    if length(candidates) < minimum_evaluations
        push!(report, Finding(:jacobian_rank_persistence_unavailable;
            severity = SeverityInfo, domain = NumericalIssue,
            basis = NumericalObservation, confidence = ConfidenceHigh,
            observation = "Only $(length(candidates)) supplied evaluation(s) have an available dense Jacobian rank estimate.",
            why_it_matters = "Cross-point rank persistence cannot be assessed when derivatives are incomplete, non-finite, or exceed the explicit dense guard.",
            evidence = [Evidence("Jacobian persistence availability"; details = [
                "evaluation_count" => length(evaluations),
                "available_evaluation_count" => length(candidates),
                "minimum_evaluations" => minimum_evaluations,
            ])],
            suggested_actions = ["Resolve derivative availability or increase the explicit dense rank guard if appropriate."],
        ))
        return report
    end
    available_estimates = estimates[candidates]
    scaling_report = analyze_jacobian_scaling_persistence(
        evaluations[candidates];
        minimum_evaluations = minimum_evaluations,
        change_factor_threshold = scaling_change_factor_threshold,
    )
    append!(report.findings, scaling_report.findings)
    for (key, value) in scaling_report.metadata
        key == :stage && continue
        report.metadata[Symbol("scaling_", key)] = value
    end
    ranks = [estimate.rank for estimate in available_estimates]
    nullities = [estimate.right_nullity for estimate in available_estimates]
    left_nullities = [estimate.left_nullity for estimate in available_estimates]
    labels = join((evaluations[index].point.label for index in candidates), ",")
    report.metadata[:available_point_labels] = labels
    report.metadata[:observed_ranks] = join(ranks, ",")
    report.metadata[:observed_right_nullities] = join(nullities, ",")
    report.metadata[:observed_left_nullities] = join(left_nullities, ",")
    if !all(==(first(ranks)), ranks)
        provenance_report = analyze_jacobian_derivative_provenance_persistence(
            evaluations[candidates]; minimum_evaluations = minimum_evaluations,
        )
        append!(report.findings, provenance_report.findings)
        for (key, value) in provenance_report.metadata
            key == :stage && continue
            report.metadata[Symbol("derivative_provenance_", key)] = value
        end
        push!(report, Finding(:jacobian_rank_not_persistent;
            severity = SeverityWarning, domain = NumericalIssue,
            basis = LocalInference, confidence = ConfidenceHigh,
            observation = "Local Jacobian rank changes across $(length(available_estimates)) explicitly supplied points.",
            why_it_matters = "The apparent degeneracy is operating-point-dependent, numerically threshold-sensitive, or evaluated under changing derivative behavior; it should not be treated as a persistent gauge without further evidence.",
            evidence = [Evidence("Jacobian rank persistence"; details = [
                "point_labels" => labels,
                "ranks" => join(ranks, ","),
                "right_nullities" => join(nullities, ","),
                "relative_tolerance" => tolerance,
            ])],
            affected = EntityRef[EntityRef(:variable, variable.value) for variable in reference_variables],
            suggested_actions = ["Compare derivative scales, domains, and active constraints at the supplied points."],
        ))
        return report
    end
    if first(left_nullities) == 0
        push!(report, Finding(:jacobian_left_nullspace_absent_persistent;
            severity = SeverityInfo, domain = NumericalIssue,
            basis = NumericalObservation, confidence = ConfidenceHigh,
            observation = "The local Jacobian rank is unchanged across $(length(available_estimates)) explicitly supplied points, with no left-null direction at the selected tolerance.",
            why_it_matters = "This is repeated local row-rank evidence, not a global independence certificate.",
            evidence = [Evidence("Jacobian left-nullspace persistence"; details = [
                "point_labels" => labels,
                "rank" => first(ranks),
                "left_nullity" => 0,
                "relative_tolerance" => tolerance,
            ])],
        ))
    else
        left_support = Set{Int}()
        for estimate in available_estimates
            magnitudes = vec(maximum(abs, estimate.left_nullspace; dims = 2))
            maximum_magnitude = maximum(magnitudes; init = zero(T))
            iszero(maximum_magnitude) && continue
            union!(left_support, findall(
                magnitude -> magnitude >= T(left_nullspace_support_relative) * maximum_magnitude,
                magnitudes,
            ))
        end
        left_support_positions = sort!(collect(left_support))
        minimum_left_cosine = one(T)
        for left in eachindex(available_estimates), right in (left + 1):length(available_estimates)
            cosines = svdvals(transpose(available_estimates[left].left_nullspace) *
                              available_estimates[right].left_nullspace)
            minimum_left_cosine = min(
                minimum_left_cosine,
                isempty(cosines) ? zero(T) : minimum(cosines),
            )
        end
        left_persistent = all(==(first(left_nullities)), left_nullities) &&
                          minimum_left_cosine >= convert(T, subspace_alignment_threshold)
        report.metadata[:minimum_left_nullspace_principal_cosine] =
            string(minimum_left_cosine)
        push!(report, Finding(
            left_persistent ? :jacobian_left_nullspace_persistent :
                              :jacobian_left_nullspace_not_persistent;
            severity = left_persistent ? SeverityInfo : SeverityWarning,
            domain = NumericalIssue,
            basis = LocalInference,
            confidence = ConfidenceHigh,
            observation = left_persistent ?
                          "The same-dimensional local Jacobian left-nullspace is aligned across $(length(available_estimates)) explicitly supplied points." :
                          "Local Jacobian rank is unchanged, but the left-nullspace is not consistently aligned across $(length(available_estimates)) explicitly supplied points.",
            why_it_matters = left_persistent ?
                             "Repeated dependent-equation geometry is more consistent with persistent local row dependence than a one-point cancellation, but it does not prove redundancy or an IIS." :
                             "Changing left-nullspace geometry can indicate operating-point dependence or numerical sensitivity even when estimated rank is unchanged.",
            evidence = [Evidence("Jacobian left-nullspace persistence"; details = [
                "point_labels" => labels,
                "rank" => first(ranks),
                "left_nullities" => join(left_nullities, ","),
                "minimum_principal_cosine" => minimum_left_cosine,
                "alignment_threshold" => subspace_alignment_threshold,
                "support_relative" => left_nullspace_support_relative,
                "support_rows" => join(left_support_positions, ","),
            ])],
            affected = EntityRef[reference_rows[index] for index in left_support_positions],
            suggested_actions = left_persistent ?
                                ["Inspect the persistent constraint combination together with structural matching and duplicate-expression evidence."] :
                                ["Inspect row scaling, derivative domains, and active geometry at each point before attributing a changing dependency."],
        ))
    end
    if first(nullities) == 0
        push!(report, Finding(:jacobian_rank_persistent;
            severity = SeverityInfo, domain = NumericalIssue,
            basis = NumericalObservation, confidence = ConfidenceHigh,
            observation = "The local Jacobian rank is unchanged across $(length(available_estimates)) explicitly supplied points, with no right-null direction at the selected tolerance.",
            why_it_matters = "This is repeated local rank evidence, not a global nonsingularity certificate.",
            evidence = [Evidence("Jacobian rank persistence"; details = [
                "point_labels" => labels,
                "rank" => first(ranks),
                "right_nullity" => 0,
                "relative_tolerance" => tolerance,
            ])],
        ))
        return report
    end
    minimum_cosine = one(T)
    for left in eachindex(available_estimates), right in (left + 1):length(available_estimates)
        cosines = svdvals(transpose(available_estimates[left].right_nullspace) *
                          available_estimates[right].right_nullspace)
        minimum_cosine = min(minimum_cosine, isempty(cosines) ? zero(T) : minimum(cosines))
    end
    persistent = all(==(first(nullities)), nullities) &&
                 minimum_cosine >= convert(T, subspace_alignment_threshold)
    right_support = Set{Int}()
    for estimate in available_estimates
        magnitudes = vec(maximum(abs, estimate.right_nullspace; dims = 2))
        maximum_magnitude = maximum(magnitudes; init = zero(T))
        iszero(maximum_magnitude) && continue
        union!(right_support, findall(
            magnitude -> magnitude >= T(right_nullspace_support_relative) * maximum_magnitude,
            magnitudes,
        ))
    end
    right_support_positions = sort!(collect(right_support))
    report.metadata[:minimum_right_nullspace_principal_cosine] = string(minimum_cosine)
    push!(report, Finding(
        persistent ? :jacobian_right_nullspace_persistent :
                     :jacobian_right_nullspace_not_persistent;
        severity = persistent ? SeverityInfo : SeverityWarning,
        domain = NumericalIssue,
        basis = LocalInference,
        confidence = ConfidenceHigh,
        observation = persistent ?
                      "The same-dimensional local Jacobian right-nullspace is aligned across $(length(available_estimates)) explicitly supplied points." :
                      "Local Jacobian rank is unchanged, but the right-nullspace is not consistently aligned across $(length(available_estimates)) explicitly supplied points.",
        why_it_matters = persistent ?
                         "Repeated local nullspace geometry is more consistent with a persistent structural or representational freedom than a one-point derivative cancellation, but it does not establish a physical cause." :
                         "Changing nullspace geometry can indicate operating-point dependence or numerical sensitivity even when the estimated rank is unchanged.",
        evidence = [Evidence("Jacobian right-nullspace persistence"; details = [
            "point_labels" => labels,
            "rank" => first(ranks),
            "right_nullities" => join(nullities, ","),
            "minimum_principal_cosine" => minimum_cosine,
            "alignment_threshold" => subspace_alignment_threshold,
            "support_relative" => right_nullspace_support_relative,
            "support_variables" => join(right_support_positions, ","),
        ])],
        affected = EntityRef[
            EntityRef(:variable, reference_variables[index].value)
            for index in right_support_positions
        ],
        suggested_actions = persistent ?
                            ["Compare the persistent subspace with expected-mode declarations and component metadata."] :
                            ["Inspect nullspace fingerprints, derivative scaling, and active geometry at each point."],
    ))
    if persistent && !isempty(expected_modes)
        point_columns = Dict(
            variable => column for (column, variable) in enumerate(reference_variables)
        )
        mode_tolerance = convert(T, expected_mode_residual_tolerance)
        for mode in expected_modes
            direction = zeros(T, length(reference_variables))
            missing_variables = Int[]
            for (variable, coefficient) in zip(mode.variables, mode.direction)
                column = get(point_columns, variable, 0)
                if iszero(column)
                    push!(missing_variables, variable.value)
                else
                    direction[column] += convert(T, coefficient)
                end
            end
            if !isempty(missing_variables) || iszero(norm(direction))
                push!(report, Finding(:persistent_jacobian_expected_mode_unaligned;
                    severity = SeverityInfo, domain = RepresentationalIssue,
                    basis = StructuralProof, confidence = ConfidenceCertain,
                    observation = "Expected nullspace mode :$(mode.name) cannot be aligned with the common persistence coordinates.",
                    why_it_matters = "A persistent-mode comparison requires every declared coordinate to be present at every point.",
                    evidence = [Evidence("Persistent Jacobian expected-mode alignment"; details = [
                        "mode" => mode.name,
                        "unaligned_variable_indices" => join(missing_variables, ","),
                    ])],
                    suggested_actions = ["Declare the mode in the common evaluation-coordinate scope."],
                ))
                continue
            end
            normalized = direction / norm(direction)
            residuals = T[
                norm(normalized - estimate.right_nullspace *
                     (transpose(estimate.right_nullspace) * normalized)) for
                estimate in available_estimates
            ]
            observed = all(residual -> residual <= mode_tolerance, residuals)
            push!(report, Finding(
                observed ? :persistent_jacobian_expected_mode_observed :
                           :persistent_jacobian_expected_mode_not_observed;
                severity = SeverityInfo,
                domain = RepresentationalIssue,
                basis = observed ? PhysicalExpectation : LocalInference,
                confidence = ConfidenceHigh,
                observation = observed ?
                              "Declared expected mode :$(mode.name) aligns with the persistent local Jacobian right-nullspace at every supplied point." :
                              "Declared expected mode :$(mode.name) does not align with the local Jacobian right-nullspace at every supplied point.",
                why_it_matters = observed ?
                                 "This supports the declared interpretation across the supplied points, but does not prove a physical gauge or global invariance." :
                                 "The declaration may be fixed or rotated by the formulation or operating point, or may not match the model coordinates.",
                evidence = [Evidence("Persistent Jacobian expected-mode comparison"; details = [
                    "mode" => mode.name,
                    "point_labels" => labels,
                    "projection_residuals" => join(residuals, ","),
                    "tolerance" => mode_tolerance,
                    "description" => mode.description,
                ])],
                affected = EntityRef[EntityRef(:variable, variable.value) for variable in mode.variables],
                suggested_actions = observed ?
                                    ["Retain the declaration and compare it with component and physical metadata."] :
                                    ["Inspect the supplied points and declaration before treating the mode as expected."],
            ))
        end
        _append_persistent_jacobian_expected_mode_span_findings!(
            report,
            expected_modes,
            reference_variables,
            available_estimates,
            labels;
            alignment_threshold = expected_mode_span_alignment_threshold,
            mode_rank_relative_tolerance = expected_mode_span_rank_relative_tolerance,
        )
    end
    sort!(report.findings; by = finding -> (-Int(finding.severity), string(finding.code)))
    return report
end

"""
    analyze_jacobian_rank_persistence(model, points; cache = EvaluationCache(), kwargs...)

Evaluate one model at explicitly supplied points, then compare the resulting
Jacobian rank evidence. This convenience method does not generate or modify
points and preserves the supplied labels in report evidence.
"""
function analyze_jacobian_rank_persistence(
    model::MOI.ModelLike,
    points::AbstractVector{<:EvaluationPoint};
    cache::EvaluationCache = EvaluationCache(),
    relative_step::Union{Nothing,Real} = nothing,
    kwargs...,
)
    evaluations = [
        isnothing(relative_step) ? evaluate_numerical(model, point; cache = cache) :
        evaluate_numerical(model, point; cache = cache, relative_step = relative_step)
        for point in points
    ]
    return analyze_jacobian_rank_persistence(evaluations; kwargs...)
end

"""
    analyze_reduced_hessian_persistence(snapshots; ...)

Compare caller-supplied local reduced-Hessian flat subspaces across explicitly
chosen points. The screen uses principal-angle alignment, so arbitrary signs
or rotations within a degenerate flat subspace do not change the result.
"""
function analyze_reduced_hessian_persistence(
    snapshots::AbstractVector{<:ReducedHessianSnapshot{T}};
    minimum_snapshots::Integer = 2,
    subspace_alignment_threshold::Real = 0.98,
    flat_support_relative_tolerance::Real = 0.1,
    multiplier_relative_tolerance::Real = sqrt(eps(T)),
    scaling_change_factor_threshold::Real = 10,
    spectral_scale_change_factor_threshold::Real = 10,
    expected_modes::AbstractVector{<:ExpectedNullspaceMode} = ExpectedNullspaceMode[],
    expected_mode_alignment_threshold::Real = 0.98,
    expected_mode_rank_relative_tolerance::Real = sqrt(eps(T)),
) where {T<:AbstractFloat}
    minimum_snapshots >= 2 ||
        throw(ArgumentError("minimum_snapshots must be at least two"))
    zero(T) <= subspace_alignment_threshold <= one(T) ||
        throw(ArgumentError("subspace_alignment_threshold must lie in [0, 1]"))
    zero(T) < flat_support_relative_tolerance <= one(T) ||
        throw(ArgumentError("flat_support_relative_tolerance must lie in (0, 1]"))
    multiplier_relative_tolerance >= zero(T) ||
        throw(ArgumentError("multiplier_relative_tolerance must be nonnegative"))
    scaling_change_factor_threshold >= one(T) ||
        throw(ArgumentError("scaling_change_factor_threshold must be at least one"))
    spectral_scale_change_factor_threshold >= one(T) ||
        throw(ArgumentError(
            "spectral_scale_change_factor_threshold must be at least one",
        ))
    zero(T) <= expected_mode_alignment_threshold <= one(T) ||
        throw(ArgumentError("expected_mode_alignment_threshold must lie in [0, 1]"))
    expected_mode_rank_relative_tolerance >= zero(T) ||
        throw(ArgumentError("expected_mode_rank_relative_tolerance must be nonnegative"))
    report = DiagnosticReport()
    report.metadata[:stage] = "reduced_hessian_persistence"
    report.metadata[:snapshot_count] = string(length(snapshots))
    report.metadata[:minimum_snapshots] = string(minimum_snapshots)
    report.metadata[:subspace_alignment_threshold] = string(subspace_alignment_threshold)
    isempty(snapshots) && return report
    reference_variables = snapshots[1].evaluation.point.variables
    if any(snapshot.evaluation.point.variables != reference_variables for snapshot in snapshots)
        push!(report, Finding(
            :reduced_hessian_flat_persistence_coordinate_mismatch;
            severity = SeverityInfo,
            domain = RepresentationalIssue,
            basis = StructuralProof,
            confidence = ConfidenceCertain,
            observation = "Reduced-Hessian snapshots do not share one evaluation-coordinate ordering.",
            why_it_matters = "Flat-direction persistence cannot be compared across different coordinate scopes or orderings.",
            evidence = [Evidence("Reduced-Hessian snapshot alignment"; details = [
                "snapshot_count" => length(snapshots),
            ])],
            suggested_actions = [
                "Evaluate the same ordered variable coordinates at every point before requesting persistence analysis.",
            ],
        ))
        return report
    end
    candidates = [
        snapshot for snapshot in snapshots
        if snapshot.analysis.available && snapshot.analysis.zero_eigenvalues > 0
    ]
    report.metadata[:flat_snapshot_count] = string(length(candidates))
    if length(candidates) < minimum_snapshots
        push!(report, Finding(
            :reduced_hessian_flat_persistence_unavailable;
            severity = SeverityInfo,
            domain = NumericalIssue,
            basis = NumericalObservation,
            confidence = ConfidenceHigh,
            observation = "Only $(length(candidates)) supplied snapshot(s) have an available nonempty reduced-Hessian flat subspace.",
            why_it_matters = "Persistence requires repeated local flat-direction evidence; absent or unavailable curvature is not evidence of stability.",
            evidence = [Evidence("Reduced-Hessian persistence availability"; details = [
                "snapshot_count" => length(snapshots),
                "flat_snapshot_count" => length(candidates),
                "minimum_snapshots" => minimum_snapshots,
            ])],
            suggested_actions = [
                "Supply at least two complete reduced-Hessian analyses with flat directions at explicitly selected nearby points.",
            ],
        ))
        return report
    end
    subspaces = [_flat_reduced_hessian_subspace(snapshot.analysis) for snapshot in candidates]
    dimensions = size.(subspaces, 2)
    same_dimension = all(==(first(dimensions)), dimensions)
    pairwise_alignments = T[]
    if same_dimension
        for left in eachindex(subspaces), right in (left + 1):length(subspaces)
            append!(pairwise_alignments, svdvals(transpose(subspaces[left]) * subspaces[right]))
        end
    end
    minimum_alignment = isempty(pairwise_alignments) ? zero(T) : minimum(pairwise_alignments)
    persistent = same_dimension &&
                 minimum_alignment >= convert(T, subspace_alignment_threshold)
    labels = join((snapshot.evaluation.point.label for snapshot in candidates), ",")
    evidence = [Evidence("Reduced-Hessian flat-subspace persistence"; details = [
        "point_labels" => labels,
        "flat_dimensions" => join(dimensions, ","),
        "minimum_principal_cosine" => minimum_alignment,
        "alignment_threshold" => subspace_alignment_threshold,
    ])]
    push!(report, Finding(
        persistent ? :reduced_hessian_flat_subspace_persistent :
                     :reduced_hessian_flat_subspace_not_persistent;
        severity = SeverityInfo,
        domain = NumericalIssue,
        basis = HeuristicInterpretation,
        confidence = ConfidenceMedium,
        observation = persistent ?
                      "The same-dimensional reduced-Hessian flat subspace is aligned across $(length(candidates)) explicitly supplied points." :
                      "The reduced-Hessian flat subspace is not consistently aligned across $(length(candidates)) explicitly supplied points.",
        why_it_matters = persistent ?
                         "Repeated local geometry is more consistent with a structural or persistent weak-curvature mode than a one-point artifact, but it does not establish a physical cause." :
                         "A changing flat subspace can indicate operating-point dependence, active-set changes, or numerical sensitivity; it does not by itself rule out a meaningful physical mode.",
        evidence = evidence,
        affected = EntityRef[
            EntityRef(:variable, variable.value) for variable in reference_variables
        ],
        suggested_actions = persistent ?
                            ["Compare the persistent subspace with plugin-declared modes and nearby active-set fingerprints."] :
                            ["Inspect changes in active rows, scaling, and operating point before interpreting the flat directions."],
    ))
    _append_flat_support_persistence_findings!(
        report,
        snapshots,
        candidates;
        support_relative_tolerance = flat_support_relative_tolerance,
    )
    _append_reduced_hessian_active_row_persistence_findings!(report, candidates)
    _append_reduced_hessian_active_jacobian_persistence_findings!(report, candidates)
    _append_reduced_hessian_multiplier_persistence_findings!(
        report,
        candidates;
        relative_tolerance = multiplier_relative_tolerance,
    )
    _append_reduced_hessian_jacobian_scaling_persistence_findings!(
        report,
        candidates;
        change_factor_threshold = scaling_change_factor_threshold,
    )
    _append_reduced_hessian_spectral_scale_persistence_findings!(
        report,
        candidates;
        change_factor_threshold = spectral_scale_change_factor_threshold,
    )
    if persistent
        _append_persistent_flat_expected_mode_findings!(
            report,
            snapshots,
            expected_modes;
            alignment_threshold = expected_mode_alignment_threshold,
            mode_rank_relative_tolerance = expected_mode_rank_relative_tolerance,
        )
    end
    sort!(report.findings; by = finding -> (-Int(finding.severity), string(finding.code)))
    return report
end

"""
    analyze_reduced_hessian_persistence(model, snapshots; ...)

Extend cross-point flat-subspace persistence with a syntactic-incidence
classification of the persistent mode's support, plus optional declared
component-metadata overlap. Neither result infers domain semantics.
"""
function analyze_reduced_hessian_persistence(
    model::MOI.ModelLike,
    snapshots::AbstractVector{<:ReducedHessianSnapshot{T}};
    structural_support_relative_tolerance::Real = 0.1,
    components::AbstractVector{<:ComponentMetadata} = component_metadata(model),
    expected_modes = nothing,
    include_port_topology_modes::Bool = true,
    kwargs...,
) where {T<:AbstractFloat}
    zero(T) < structural_support_relative_tolerance <= one(T) ||
        throw(ArgumentError(
            "structural_support_relative_tolerance must lie in (0, 1]",
        ))
    resolved_expected_modes = isnothing(expected_modes) ?
                              (isempty(snapshots) ? ExpectedNullspaceMode[] :
                               expected_nullspace_modes(
                                   model, first(snapshots).evaluation,
                               )) : expected_modes
    resolved_expected_modes isa AbstractVector{<:ExpectedNullspaceMode} ||
        throw(ArgumentError("expected_modes must be a vector of ExpectedNullspaceMode values"))
    port_modes = include_port_topology_modes ? port_expected_nullspace_modes(
        component_port_metadata(model),
        component_port_nullspace_modes(model),
        component_port_connections(model),
        component_port_coordinate_maps(model),
    ) : ExpectedNullspaceMode[]
    port_summary = port_expected_nullspace_summary(port_modes)
    all_expected_modes = vcat(resolved_expected_modes, port_modes)
    report = analyze_reduced_hessian_persistence(
        snapshots;
        expected_modes = all_expected_modes,
        kwargs...,
    )
    report.metadata[:persistent_flat_declared_expected_mode_count] =
        string(length(resolved_expected_modes))
    report.metadata[:persistent_flat_port_expected_mode_count] =
        string(length(port_modes))
    report.metadata[:persistent_flat_port_expected_independent_rank] =
        string(port_summary.rank)
    report.metadata[:persistent_flat_port_expected_relative_tolerance] =
        string(port_summary.relative_tolerance)
    report.metadata[:persistent_flat_port_component_expected_mode_count] =
        string(count(==(:component), port_summary.candidate_origins))
    report.metadata[:persistent_flat_port_topology_expected_mode_count] =
        string(count(==(:topology), port_summary.candidate_origins))
    any(finding -> finding.code == :reduced_hessian_flat_subspace_persistent,
        report.findings) || return report
    _append_persistent_flat_component_metadata_findings!(
        report,
        snapshots,
        components;
        support_relative_tolerance = structural_support_relative_tolerance,
    )
    graph = incidence_graph(model)
    if !graph.complete
        push!(report, Finding(
            :reduced_hessian_persistent_flat_structural_scope_unavailable;
            severity = SeverityInfo,
            domain = RepresentationalIssue,
            basis = StructuralProof,
            confidence = ConfidenceCertain,
            observation = "The persistent flat subspace cannot be scoped to structural components because incidence is incomplete.",
            why_it_matters = "Missing symbolic edges can make a localized mode appear to span unrelated components.",
            evidence = [Evidence("Persistent flat-mode structural scope"; details = [
                "opaque_source_count" => length(graph.opaque_sources),
            ])],
            suggested_actions = [
                "Resolve opaque or unsupported expressions before interpreting structural component scope.",
            ],
        ))
        return report
    end
    support_variables = _persistent_flat_support_variables(
        snapshots, structural_support_relative_tolerance,
    )
    graph_positions = Dict(
        record.index => position for (position, record) in enumerate(graph.variables)
    )
    variable_positions = [get(graph_positions, variable, 0) for variable in support_variables]
    if any(iszero, variable_positions)
        push!(report, Finding(
            :reduced_hessian_persistent_flat_structural_scope_unaligned;
            severity = SeverityInfo,
            domain = RepresentationalIssue,
            basis = StructuralProof,
            confidence = ConfidenceCertain,
            observation = "Persistent flat-direction support cannot be aligned with every model incidence variable.",
            why_it_matters = "A structural-component classification requires the same variable scope in the evaluation and model graph.",
            evidence = [Evidence("Persistent flat-mode coordinate alignment"; details = [
                "support_variable_count" => length(support_variables),
            ])],
            suggested_actions = [
                "Evaluate all variables in the model incidence scope before requesting structural flat-mode classification.",
            ],
        ))
        return report
    end
    component_by_position = Dict{Int,Int}()
    structural_components = connected_components(graph)
    for (number, component) in enumerate(structural_components), position in component.variable_positions
        component_by_position[position] = number
    end
    component_numbers = unique(get(component_by_position, position, 0) for position in variable_positions)
    if any(iszero, component_numbers)
        return report
    end
    component_labels = join(sort(component_numbers), ",")
    localized = length(component_numbers) == 1
    push!(report, Finding(
        localized ? :reduced_hessian_persistent_flat_structurally_localized :
                    :reduced_hessian_persistent_flat_spans_components;
        severity = SeverityInfo,
        domain = RepresentationalIssue,
        basis = StructuralProof,
        confidence = ConfidenceCertain,
        observation = localized ?
                      "The persistent flat subspace is materially supported within structural component $(only(component_numbers))." :
                      "The persistent flat subspace materially spans $(length(component_numbers)) structural incidence components.",
        why_it_matters = localized ?
                         "A localized persistent mode supports component-focused debugging, but does not establish why that component is weakly constrained." :
                         "A spanning persistent mode can reflect a missing coupling equation or coordinated freedom, but incidence alone cannot distinguish them.",
        evidence = [Evidence("Persistent flat-mode structural scope"; details = [
            "support_relative_tolerance" => structural_support_relative_tolerance,
            "support_variable_count" => length(support_variables),
            "structural_components" => component_labels,
        ])],
        affected = EntityRef[
            EntityRef(:variable, variable.value) for variable in support_variables
        ],
        suggested_actions = localized ?
                            ["Inspect the affected component's constraints, scaling, and domain metadata."] :
                            ["Inspect missing couplings and compare the mode with domain-declared expected freedoms."],
    ))
    sort!(report.findings; by = finding -> (-Int(finding.severity), string(finding.code)))
    return report
end

"""
    analyze_reduced_hessian(evaluation, hessian; active_rows, ...)

Turn an explicit reduced-Hessian calculation into explainable local findings.
`active_rows` is required: feasibility values alone do not establish an active
set or a multiplier convention.
"""
function analyze_reduced_hessian(
    evaluation::NumericalEvaluation{T},
    hessian::HessianEvaluation;
    active_rows::AbstractVector{<:Integer},
    condition_threshold::Real = 1.0e10,
    flat_direction_support_relative_tolerance::Real = 0.1,
    flat_direction_compact_max_variables::Integer = 8,
    expected_modes::AbstractVector{<:ExpectedNullspaceMode} = ExpectedNullspaceMode[],
    expected_mode_residual_tolerance::Real = sqrt(eps(T)),
    kwargs...,
) where {T<:AbstractFloat}
    condition_threshold > 1 ||
        throw(ArgumentError("condition_threshold must be greater than one"))
    zero(flat_direction_support_relative_tolerance) <
    flat_direction_support_relative_tolerance <= one(flat_direction_support_relative_tolerance) ||
        throw(ArgumentError(
            "flat_direction_support_relative_tolerance must lie in (0, 1]",
        ))
    flat_direction_compact_max_variables > 0 ||
        throw(ArgumentError("flat_direction_compact_max_variables must be positive"))
    analysis = reduced_hessian_analysis(
        evaluation,
        hessian;
        active_rows = active_rows,
        kwargs...,
    )
    report = DiagnosticReport()
    report.metadata[:stage] = "reduced_hessian"
    report.metadata[:evaluation_point_label] = evaluation.point.label
    report.metadata[:reduced_hessian_available] = string(analysis.available)
    if !analysis.available
        push!(
            report,
            Finding(
                :reduced_hessian_analysis_unavailable;
                severity = SeverityInfo,
                domain = NumericalIssue,
                basis = NumericalObservation,
                confidence = ConfidenceCertain,
                observation = "Reduced-Hessian analysis is unavailable at point \"$(evaluation.point.label)\".",
                why_it_matters = "A second-order conclusion requires a complete Hessian and explicitly usable active-row Jacobian.",
                evidence = [
                    _point_evidence(evaluation.point),
                    Evidence(
                        "Reduced-Hessian availability";
                        details = [
                            "active_rows" => join(analysis.active_rows, ","),
                            "reason" => analysis.reason,
                        ],
                    ),
                ],
                suggested_actions = [
                    "Supply complete derivative sources, explicit multipliers, and the intended active rows.",
                ],
            ),
        )
        return report
    end
    evidence = [
        _point_evidence(evaluation.point),
        Evidence(
            "Reduced Hessian spectrum";
            details = [
                "active_rows" => join(analysis.active_rows, ","),
                "jacobian_rank" => analysis.jacobian_rank,
                "tangent_dimension" => analysis.tangent_dimension,
                "jacobian_threshold" => analysis.jacobian_threshold,
                "eigenvalue_threshold" => analysis.eigenvalue_threshold,
                "positive_eigenvalues" => analysis.positive_eigenvalues,
                "negative_eigenvalues" => analysis.negative_eigenvalues,
                "zero_eigenvalues" => analysis.zero_eigenvalues,
                "condition_estimate" => analysis.condition_estimate,
            ],
        ),
    ]
    if analysis.negative_eigenvalues > 0
        push!(
            report,
            Finding(
                :reduced_hessian_negative_curvature;
                severity = SeverityWarning,
                domain = NumericalIssue,
                basis = LocalInference,
                confidence = ConfidenceHigh,
                observation = "The reduced Hessian has $(analysis.negative_eigenvalues) negative-curvature tangent direction(s).",
                why_it_matters = "At the supplied point, multipliers, and active rows, this is incompatible with a strict local minimum under the selected tangent approximation.",
                evidence = evidence,
                suggested_actions = [
                    "Verify multiplier signs and the intended active rows before interpreting this as a model defect.",
                    "Inspect the reported tangent basis and repeat around the operating point.",
                ],
            ),
        )
    end
    if analysis.zero_eigenvalues > 0
        push!(
            report,
            Finding(
                :reduced_hessian_flat_directions;
                severity = SeverityWarning,
                domain = NumericalIssue,
                basis = LocalInference,
                confidence = ConfidenceHigh,
                observation = "The reduced Hessian has $(analysis.zero_eigenvalues) near-flat tangent direction(s) under the recorded eigenvalue threshold.",
                why_it_matters = "Flat second-order directions can reflect symmetry, weak identifiability, non-unique solutions, or scale-sensitive curvature.",
                evidence = evidence,
                suggested_actions = [
                    "Compare the tangent directions with expected gauges and physical invariances.",
                    "Re-evaluate with documented coordinate scaling and nearby points.",
                ],
            ),
        )
        for index in eachindex(analysis.eigenvalues)
            abs(analysis.eigenvalues[index]) <= analysis.eigenvalue_threshold || continue
            direction = analysis.tangent_basis * analysis.reduced_eigenvectors[:, index]
            length(direction) >= 2 || continue
            direction_norm = norm(direction)
            iszero(direction_norm) && continue
            correlation = abs(sum(direction)) /
                          (sqrt(eltype(direction)(length(direction))) * direction_norm)
            if correlation >= eltype(direction)(0.98)
                push!(report, Finding(
                    :reduced_hessian_candidate_uniform_flat_direction;
                    severity = SeverityInfo,
                    domain = RepresentationalIssue,
                    basis = HeuristicInterpretation,
                    confidence = ConfidenceMedium,
                    observation = "A near-flat reduced-Hessian direction is nearly uniform across all $(length(direction)) tangent coordinates.",
                    why_it_matters = "This resembles a common-coordinate flat mode or symmetry, but coordinate units and model semantics are required before calling it an expected gauge.",
                    evidence = vcat(evidence, [Evidence("Flat reduced-Hessian direction"; details = [
                        "reduced_eigenvalue_index" => index,
                        "eigenvalue" => analysis.eigenvalues[index],
                        "uniform_shift_correlation" => correlation,
                    ])]),
                    affected = EntityRef[
                        EntityRef(:variable, variable.value) for variable in evaluation.point.variables
                    ],
                    suggested_actions = [
                        "Compare this direction with declared expected modes and active-set tangent fingerprints.",
                        "Re-evaluate after a small operating-point perturbation before assigning a symmetry interpretation.",
                    ],
                ))
            end
            maximum_magnitude = maximum(abs, direction)
            support = findall(abs(value) >=
                              flat_direction_support_relative_tolerance * maximum_magnitude
                              for value in direction)
            1 <= length(support) < length(direction) &&
                length(support) <= flat_direction_compact_max_variables || continue
            push!(report, Finding(
                :reduced_hessian_candidate_compact_flat_direction;
                severity = SeverityInfo,
                domain = RepresentationalIssue,
                basis = HeuristicInterpretation,
                confidence = ConfidenceMedium,
                observation = "A near-flat reduced-Hessian direction has material support on $(length(support)) of $(length(direction)) evaluated coordinates.",
                why_it_matters = "A localized flat mode can indicate weak identifiability or a small unconstrained subsystem, but coordinate scaling and model semantics are required before assigning a cause.",
                evidence = vcat(evidence, [Evidence("Flat reduced-Hessian direction"; details = [
                    "reduced_eigenvalue_index" => index,
                    "eigenvalue" => analysis.eigenvalues[index],
                    "support_relative_tolerance" => flat_direction_support_relative_tolerance,
                    "support_coordinate_count" => length(support),
                    "support_coordinates" => join(support, ","),
                ])]),
                affected = EntityRef[
                    EntityRef(:variable, evaluation.point.variables[column].value)
                    for column in support
                ],
                suggested_actions = [
                    "Inspect the listed variables and their incident constraints for a localized missing equation or weakly identified subsystem.",
                    "Repeat at nearby points and under documented coordinate scaling before assigning a physical interpretation.",
                ],
            ))
        end
    elseif !isnothing(analysis.condition_estimate) &&
           analysis.condition_estimate >= condition_threshold
        push!(
            report,
            Finding(
                :ill_conditioned_reduced_hessian;
                severity = SeverityWarning,
                domain = NumericalIssue,
                basis = NumericalObservation,
                confidence = ConfidenceHigh,
                observation = "The positive reduced-Hessian spectrum has condition estimate $(analysis.condition_estimate).",
                why_it_matters = "The local curvature is positive but highly anisotropic, which can make Newton steps and second-order conclusions scale-sensitive.",
                evidence = vcat(
                    evidence,
                    [Evidence("Conditioning threshold"; details = ["threshold" => condition_threshold])],
                ),
                suggested_actions = [
                    "Review coordinate scaling and physical bases before treating this as intrinsic weak curvature.",
                ],
            ),
        )
    end
    append!(report.findings, _reduced_hessian_expected_mode_findings(
        evaluation,
        analysis,
        expected_modes;
        residual_tolerance = expected_mode_residual_tolerance,
    ))
    sort!(report.findings; by = finding -> (-Int(finding.severity), string(finding.code)))
    return report
end

function analyze_numerical(
    model::MOI.ModelLike,
    values::Union{
        AbstractVector{<:Real},
        AbstractDict{MOI.VariableIndex,<:Real},
    };
    label::AbstractString = "user",
    kwargs...,
)
    return analyze_numerical(
        model,
        evaluation_point(model, values; label = label);
        kwargs...,
    )
end
