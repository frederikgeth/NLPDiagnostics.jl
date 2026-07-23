_entity_row_key(reference::EntityRef) =
    (reference.kind, reference.index, reference.subindex)

function _selected_jacobian_submatrix_evaluation(
    evaluation::NumericalEvaluation{T},
    rows::Vector{Int},
    columns::Vector{Int},
) where {T<:AbstractFloat}
    row_positions = Dict(row => position for (position, row) in enumerate(rows))
    column_positions =
        Dict(column => position for (position, column) in enumerate(columns))
    entries = JacobianEntry{T}[
        JacobianEntry{T}(
            row_positions[entry.row],
            column_positions[entry.column],
            entry.value,
        ) for entry in evaluation.jacobian_entries if
        haskey(row_positions, entry.row) && haskey(column_positions, entry.column)
    ]
    point = EvaluationPoint(
        evaluation.point.variables[columns],
        evaluation.point.values[columns];
        label = evaluation.point.label,
    )
    return NumericalEvaluation{T}(
        point,
        nothing,
        nothing,
        Union{Missing,T}[],
        evaluation.constraint_values[rows],
        evaluation.constraint_sources[rows],
        entries,
        evaluation.jacobian_row_methods[rows],
        evaluation.capabilities,
        evaluation.failures,
    )
end

function _unavailable_structural_numerical_comparison(
    evaluation::NumericalEvaluation{T},
    reason::AbstractString,
) where {T<:AbstractFloat}
    return StructuralNumericalComparison{T}(
        false,
        String(reason),
        evaluation.point,
        0, 0, 0, 0, 0, 0, Int[], Int[], nothing,
    )
end

"""
    structural_numerical_comparison(model, evaluation; ...)

Compare equality-pattern matching against a local Jacobian restricted to the
same free variables and alignable ordinary equality rows. A numerical rank
below matching cardinality is an unexpected *local* loss relative to the
generic structural pattern; it is not automatically a physical gauge.
"""
function structural_numerical_comparison(
    model::MOI.ModelLike,
    evaluation::NumericalEvaluation{T};
    relative_tolerance::Real =
        max(length(evaluation.point.variables), 1) * eps(T),
    max_dense_entries::Integer = 4_000_000,
) where {T<:AbstractFloat}
    graph = incidence_graph(model)
    graph.complete || return _unavailable_structural_numerical_comparison(
        evaluation,
        "structural equality incidence is incomplete",
    )
    matching = maximum_matching(graph)
    matching.complete || return _unavailable_structural_numerical_comparison(
        evaluation,
        "structural matching is unavailable",
    )
    numerical_rows = Dict(
        _entity_row_key(source) => row for
        (row, source) in enumerate(evaluation.constraint_sources)
    )
    selected_rows = Int[]
    for position in matching.eligible_constraint_positions
        node = graph.constraint_nodes[position]
        reference = _constraint_ref(node.constraint; row = node.row)
        row = get(numerical_rows, _entity_row_key(reference), 0)
        iszero(row) && return _unavailable_structural_numerical_comparison(
            evaluation,
            "could not align structural equality node $(reference.index) with an evaluated row",
        )
        push!(selected_rows, row)
    end
    variable_columns = Int[]
    point_columns = Dict(
        variable => column for
        (column, variable) in enumerate(evaluation.point.variables)
    )
    for position in matching.eligible_variable_positions
        variable = graph.variables[position].index
        column = get(point_columns, variable, 0)
        iszero(column) && return _unavailable_structural_numerical_comparison(
            evaluation,
            "could not align free structural variable $(variable.value) with the evaluation point",
        )
        push!(variable_columns, column)
    end
    selected_evaluation = _selected_jacobian_submatrix_evaluation(
        evaluation,
        selected_rows,
        variable_columns,
    )
    estimate = jacobian_rank_estimate(
        selected_evaluation;
        relative_tolerance = relative_tolerance,
        max_dense_entries = max_dense_entries,
    )
    estimate.available || return StructuralNumericalComparison{T}(
        false,
        estimate.reason,
        evaluation.point,
        matching_cardinality(matching),
        length(variable_columns) - matching_cardinality(matching),
        length(selected_rows) - matching_cardinality(matching),
        0, 0, 0,
        selected_rows,
        variable_columns,
        estimate,
    )
    structural_rank = matching_cardinality(matching)
    return StructuralNumericalComparison{T}(
        true,
        nothing,
        evaluation.point,
        structural_rank,
        length(variable_columns) - structural_rank,
        length(selected_rows) - structural_rank,
        estimate.rank,
        estimate.right_nullity,
        estimate.left_nullity,
        selected_rows,
        variable_columns,
        estimate,
    )
end

function structural_numerical_comparison(
    model::MOI.ModelLike,
    point::EvaluationPoint;
    cache::EvaluationCache = EvaluationCache(),
    kwargs...,
)
    return structural_numerical_comparison(
        model,
        evaluate_numerical(model, point; cache = cache);
        kwargs...,
    )
end

function structural_numerical_comparison(
    model::MOI.ModelLike,
    values::Union{AbstractVector{<:Real},AbstractDict{MOI.VariableIndex,<:Real}};
    label::AbstractString = "user",
    kwargs...,
)
    return structural_numerical_comparison(
        model,
        evaluation_point(model, values; label = label);
        kwargs...,
    )
end

function _structural_numerical_findings(
    comparison::StructuralNumericalComparison,
)
    findings = Finding[]
    if !comparison.available
        push!(
            findings,
            Finding(
                :structural_numerical_comparison_unavailable;
                severity = SeverityInfo,
                domain = RepresentationalIssue,
                basis = StructuralProof,
                confidence = ConfidenceCertain,
                observation = "Structural-to-numerical rank comparison is unavailable at point \"$(comparison.point.label)\".",
                why_it_matters = "The debugger cannot safely call a local nullspace expected or unexpected without aligning complete structural and numerical views.",
                evidence = [
                    _point_evidence(comparison.point),
                    Evidence(
                        "Comparison availability";
                        details = ["reason" => comparison.reason],
                    ),
                ],
                suggested_actions = [
                    "Resolve opaque structural sources or incomplete derivatives, then repeat the comparison.",
                ],
            ),
        )
        return findings
    end
    estimate = something(comparison.estimate)
    evidence = [
        _point_evidence(comparison.point),
        Evidence(
            "Structural equality matching versus local Jacobian";
            details = [
                "structural_matching_rank" => comparison.structural_matching_rank,
                "structural_right_nullity" => comparison.structural_right_nullity,
                "structural_left_nullity" => comparison.structural_left_nullity,
                "numerical_rank" => comparison.numerical_rank,
                "numerical_right_nullity" => comparison.numerical_right_nullity,
                "numerical_left_nullity" => comparison.numerical_left_nullity,
                "equality_rows" => join(comparison.equality_rows, ","),
                "free_variable_columns" => join(comparison.free_variable_columns, ","),
            ],
        ),
        _rank_evidence(estimate),
    ]
    if comparison.numerical_rank < comparison.structural_matching_rank
        push!(
            findings,
            Finding(
                :unexpected_local_rank_loss;
                severity = SeverityWarning,
                domain = NumericalIssue,
                basis = LocalInference,
                confidence = ConfidenceHigh,
                observation = "The aligned local equality Jacobian has rank $(comparison.numerical_rank), below structural matching rank $(comparison.structural_matching_rank).",
                why_it_matters = "The equality pattern admits more independent equations than are observed locally. This can arise from a stationary expression, parameter value, poor scaling, or a genuine unmodeled degeneracy.",
                evidence = evidence,
                suggested_actions = [
                    "Inspect the local nullspace vectors and repeat at nearby domain-valid points.",
                    "Do not label this mode a physical gauge until a plugin or model semantics supports that interpretation.",
                ],
            ),
        )
    elseif comparison.numerical_rank == comparison.structural_matching_rank &&
           (comparison.structural_right_nullity > 0 || comparison.structural_left_nullity > 0)
        push!(
            findings,
            Finding(
                :structurally_expected_local_nullspace;
                severity = SeverityInfo,
                domain = RepresentationalIssue,
                basis = StructuralProof,
                confidence = ConfidenceHigh,
                observation = "The local equality-Jacobian rank matches the structural matching rank, with $(comparison.numerical_right_nullity) right and $(comparison.numerical_left_nullity) left null direction(s) in the aligned view.",
                why_it_matters = "The observed rectangular freedom or excess-equation pattern is consistent with the generic equality incidence. Its physical meaning remains unclassified.",
                evidence = evidence,
                suggested_actions = [
                    "Classify the mode using model semantics or a domain plugin (for example, an expected reference gauge).",
                ],
            ),
        )
    elseif comparison.numerical_rank == comparison.structural_matching_rank
        push!(
            findings,
            Finding(
                :structural_numerical_rank_agreement;
                severity = SeverityInfo,
                domain = NumericalIssue,
                basis = NumericalObservation,
                confidence = ConfidenceHigh,
                observation = "The aligned local equality-Jacobian rank agrees with structural matching rank $(comparison.structural_matching_rank).",
                why_it_matters = "No additional local rank loss is observed in this equality view at the recorded point.",
                evidence = evidence,
                suggested_actions = [
                    "This does not rule out scaling, active-set, or second-order degeneracy; inspect those stages separately.",
                ],
            ),
        )
    else
        push!(
            findings,
            Finding(
                :structural_numerical_rank_inconsistency;
                severity = SeverityWarning,
                domain = RepresentationalIssue,
                basis = NumericalObservation,
                confidence = ConfidenceMedium,
                observation = "The local equality-Jacobian rank $(comparison.numerical_rank) exceeds structural matching rank $(comparison.structural_matching_rank).",
                why_it_matters = "This should be impossible for a fully aligned exact incidence pattern and may indicate unsupported expression semantics or an alignment defect.",
                evidence = evidence,
                suggested_actions = [
                    "Inspect expression-support and evaluator provenance before interpreting the numerical result.",
                ],
            ),
        )
    end
    return findings
end

"""
    analyze_degeneracy(model, evaluation; ...)

Report the first generic degeneracy classification: structural equality-pattern
freedom versus additional local numerical rank loss.
"""
function analyze_degeneracy(
    model::MOI.ModelLike,
    evaluation::NumericalEvaluation;
    kwargs...,
)
    comparison = structural_numerical_comparison(model, evaluation; kwargs...)
    report = DiagnosticReport()
    append!(report.findings, _structural_numerical_findings(comparison))
    report.metadata[:stage] = "degeneracy"
    report.metadata[:evaluation_point_label] = evaluation.point.label
    report.metadata[:structural_numerical_comparison_available] =
        string(comparison.available)
    report.metadata[:structural_matching_rank] =
        string(comparison.structural_matching_rank)
    report.metadata[:aligned_numerical_rank] = string(comparison.numerical_rank)
    sort!(report.findings; by = finding -> (-Int(finding.severity), string(finding.code)))
    return report
end

function analyze_degeneracy(
    model::MOI.ModelLike,
    point::EvaluationPoint;
    cache::EvaluationCache = EvaluationCache(),
    kwargs...,
)
    return analyze_degeneracy(
        model,
        evaluate_numerical(model, point; cache = cache);
        kwargs...,
    )
end

function analyze_degeneracy(
    model::MOI.ModelLike,
    values::Union{AbstractVector{<:Real},AbstractDict{MOI.VariableIndex,<:Real}};
    label::AbstractString = "user",
    kwargs...,
)
    return analyze_degeneracy(
        model,
        evaluation_point(model, values; label = label);
        kwargs...,
    )
end
