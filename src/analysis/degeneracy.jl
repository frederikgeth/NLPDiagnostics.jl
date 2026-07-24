_entity_row_key(reference::EntityRef) =
    (reference.kind, reference.index, reference.subindex)

"""
    expected_nullspace_modes(model, evaluation)

Extension hook for domain packages. Return named expected right-nullspace
directions in model variable coordinates. The generic default declares no
physical or representational gauges.
"""
expected_nullspace_modes(model::MOI.ModelLike, evaluation::NumericalEvaluation) =
    ExpectedNullspaceMode[]

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

"""
    nullspace_fingerprints(comparison; ...)

Extract a small set of conservative, inspectable local nullspace patterns.
Currently recognized patterns are a near-uniform right-null vector (candidate
common-coordinate shift) and a two-row left-null vector (candidate pairwise
equation dependence).
"""
function nullspace_fingerprints(
    comparison::StructuralNumericalComparison{T};
    support_relative::Real = 0.1,
    uniform_shift_correlation::Real = 0.98,
) where {T<:AbstractFloat}
    comparison.available || return NullspaceFingerprint{T}[]
    relative = convert(T, support_relative)
    correlation_threshold = convert(T, uniform_shift_correlation)
    zero(T) < relative <= one(T) ||
        throw(ArgumentError("support_relative must lie in (0, 1]"))
    zero(T) <= correlation_threshold <= one(T) ||
        throw(ArgumentError("uniform_shift_correlation must lie in [0, 1]"))
    estimate = something(comparison.estimate)
    fingerprints = NullspaceFingerprint{T}[]
    for vector_index in axes(estimate.right_nullspace, 2)
        vector = view(estimate.right_nullspace, :, vector_index)
        maximum_magnitude = maximum(abs, vector; init = zero(T))
        iszero(maximum_magnitude) && continue
        local_support = findall(value -> abs(value) >= relative * maximum_magnitude, vector)
        support = comparison.free_variable_columns[local_support]
        correlation = abs(sum(vector)) / (sqrt(T(length(vector))) * norm(vector))
        if length(vector) >= 2 && length(local_support) == length(vector) &&
           correlation >= correlation_threshold
            push!(
                fingerprints,
                NullspaceFingerprint{T}(
                    :right,
                    vector_index,
                    :candidate_uniform_coordinate_shift,
                    support,
                    correlation,
                ),
            )
        end
    end
    for vector_index in axes(estimate.left_nullspace, 2)
        vector = view(estimate.left_nullspace, :, vector_index)
        maximum_magnitude = maximum(abs, vector; init = zero(T))
        iszero(maximum_magnitude) && continue
        local_support = findall(value -> abs(value) >= relative * maximum_magnitude, vector)
        length(local_support) == 2 || continue
        push!(
            fingerprints,
            NullspaceFingerprint{T}(
                :left,
                vector_index,
                :candidate_two_row_equation_dependence,
                comparison.equality_rows[local_support],
                one(T),
            ),
        )
    end
    return fingerprints
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

function _nullspace_fingerprint_findings(
    comparison::StructuralNumericalComparison,
    evaluation::NumericalEvaluation,
    fingerprints::Vector{<:NullspaceFingerprint} = nullspace_fingerprints(comparison),
)
    comparison.available || return Finding[]
    findings = Finding[]
    for fingerprint in fingerprints
        if fingerprint.kind == :candidate_uniform_coordinate_shift
            affected = EntityRef[
                EntityRef(:variable, comparison.point.variables[column].value) for
                column in fingerprint.support
            ]
            push!(
                findings,
                Finding(
                    :candidate_uniform_coordinate_shift_null_mode;
                    severity = SeverityInfo,
                    domain = RepresentationalIssue,
                    basis = HeuristicInterpretation,
                    confidence = ConfidenceMedium,
                    observation = "A local right-null vector is nearly uniform across $(length(fingerprint.support)) aligned free coordinates.",
                    why_it_matters = "This resembles a common-coordinate shift, but variable units and model semantics are required before it can be called an expected physical or reference gauge.",
                    evidence = [
                        _point_evidence(comparison.point),
                        Evidence(
                            "Nullspace fingerprint";
                            details = [
                                "side" => fingerprint.side,
                                "vector_index" => fingerprint.vector_index,
                                "support_columns" => join(fingerprint.support, ","),
                                "uniform_shift_correlation" => fingerprint.score,
                            ],
                        ),
                    ],
                    suggested_actions = [
                        "Confirm that the affected coordinates share units and represent a meaningful common reference direction.",
                        "Use a domain plugin to declare an expected gauge before suppressing the mode.",
                    ],
                    affected = affected,
                ),
            )
        elseif fingerprint.kind == :candidate_two_row_equation_dependence
            affected = EntityRef[
                evaluation.constraint_sources[row] for row in fingerprint.support
            ]
            push!(
                findings,
                Finding(
                    :candidate_two_row_equation_dependence;
                    severity = SeverityWarning,
                    domain = NumericalIssue,
                    basis = HeuristicInterpretation,
                    confidence = ConfidenceMedium,
                    observation = "A local left-null vector is concentrated on two equality rows with nearly balanced magnitudes.",
                    why_it_matters = "This resembles a pair of locally dependent equations, but it may be caused by a point-specific derivative cancellation rather than a duplicate model row.",
                    evidence = [
                        _point_evidence(comparison.point),
                        Evidence(
                            "Nullspace fingerprint";
                            details = [
                                "side" => fingerprint.side,
                                "vector_index" => fingerprint.vector_index,
                                "support_rows" => join(fingerprint.support, ","),
                            "support_concentration" => fingerprint.score,
                            ],
                        ),
                    ],
                    suggested_actions = [
                        "Compare the two rows with exact duplicate-expression findings and repeat at nearby points.",
                    ],
                    affected = affected,
                ),
            )
        end
    end
    return findings
end

function _unknown_local_degeneracy_findings(
    comparison::StructuralNumericalComparison,
    fingerprints::Vector{<:NullspaceFingerprint},
)
    comparison.available || return Finding[]
    comparison.numerical_rank < comparison.structural_matching_rank || return Finding[]
    isempty(fingerprints) || return Finding[]
    return Finding[Finding(
        :unknown_local_degeneracy_mode;
        severity = SeverityWarning,
        domain = NumericalIssue,
        basis = LocalInference,
        confidence = ConfidenceHigh,
        observation = "Additional local rank loss is observed, but no generic nullspace fingerprint matches the aligned equality-Jacobian mode.",
        why_it_matters = "The rank loss needs model or domain semantics before it can be classified as a gauge, dependent equation, coordinate artifact, or physical mode.",
        evidence = [
            _point_evidence(comparison.point),
            Evidence("Unclassified local nullspace"; details = [
                "structural_matching_rank" => comparison.structural_matching_rank,
                "numerical_rank" => comparison.numerical_rank,
                "right_nullity" => comparison.numerical_right_nullity,
                "left_nullity" => comparison.numerical_left_nullity,
                "matched_generic_fingerprints" => 0,
            ]),
        ],
        suggested_actions = [
            "Inspect the recorded nullspace vectors and repeat at nearby valid points.",
            "Add domain metadata or a plugin classifier before assigning a physical interpretation.",
        ],
    )]
end

function _expected_nullspace_mode_findings(
    comparison::StructuralNumericalComparison{T},
    modes::AbstractVector{<:ExpectedNullspaceMode};
    residual_tolerance::Real = sqrt(eps(T)),
) where {T<:AbstractFloat}
    comparison.available || return Finding[]
    tolerance = convert(T, residual_tolerance)
    tolerance >= zero(T) ||
        throw(ArgumentError("residual_tolerance must be nonnegative"))
    point_columns = Dict(
        variable => column for
        (column, variable) in enumerate(comparison.point.variables)
    )
    local_columns = Dict(
        column => local_position for
        (local_position, column) in enumerate(comparison.free_variable_columns)
    )
    estimate = something(comparison.estimate)
    findings = Finding[]
    for mode in modes
        direction = zeros(T, length(comparison.free_variable_columns))
        unavailable_variables = Int[]
        for (variable, coefficient) in zip(mode.variables, mode.direction)
            column = get(point_columns, variable, 0)
            local_column = get(local_columns, column, 0)
            if iszero(local_column)
                push!(unavailable_variables, variable.value)
            else
                direction[local_column] += convert(T, coefficient)
            end
        end
        if !isempty(unavailable_variables) || iszero(norm(direction))
            push!(
                findings,
                Finding(
                    :expected_nullspace_mode_unaligned;
                    severity = SeverityInfo,
                    domain = RepresentationalIssue,
                    basis = StructuralProof,
                    confidence = ConfidenceCertain,
                    observation = "Expected nullspace mode :$(mode.name) cannot be aligned with the free coordinates used by the local comparison.",
                    why_it_matters = "The debugger cannot compare a declared gauge with the observed nullspace unless their variable coordinates agree.",
                    evidence = [Evidence("Expected nullspace alignment"; details = [
                        "mode" => mode.name,
                        "unaligned_variable_indices" => join(unavailable_variables, ","),
                    ])],
                    suggested_actions = [
                        "Declare the mode in free evaluation-point coordinates or provide plugin-specific alignment logic.",
                    ],
                ),
            )
            continue
        end
        normalized = direction / norm(direction)
        residual = if size(estimate.right_nullspace, 2) == 0
            one(T)
        else
            norm(normalized - estimate.right_nullspace * (
                transpose(estimate.right_nullspace) * normalized
            ))
        end
        affected = EntityRef[
            EntityRef(:variable, variable.value) for variable in mode.variables
        ]
        if residual <= tolerance
            push!(
                findings,
                Finding(
                    :expected_nullspace_mode_observed;
                    severity = SeverityInfo,
                    domain = RepresentationalIssue,
                    basis = PhysicalExpectation,
                    confidence = ConfidenceHigh,
                    observation = "Declared expected nullspace mode :$(mode.name) aligns with the observed local right nullspace.",
                    why_it_matters = "This supports, but does not prove, the plugin or caller's interpretation of the local freedom as an expected gauge or invariance.",
                    evidence = [Evidence("Expected-nullspace comparison"; details = [
                        "mode" => mode.name,
                        "projection_residual" => residual,
                        "tolerance" => tolerance,
                        "description" => mode.description,
                    ])],
                    suggested_actions = [
                        "Retain the declaration and verify it across relevant operating points and formulations.",
                    ],
                    affected = affected,
                ),
            )
        else
            push!(
                findings,
                Finding(
                    :expected_nullspace_mode_not_observed;
                    severity = SeverityInfo,
                    domain = RepresentationalIssue,
                    basis = LocalInference,
                    confidence = ConfidenceHigh,
                    observation = "Declared expected nullspace mode :$(mode.name) does not align with the observed local right nullspace.",
                    why_it_matters = "The mode may be fixed by this formulation or operating point, or the declaration may not match the model coordinates.",
                    evidence = [Evidence("Expected-nullspace comparison"; details = [
                        "mode" => mode.name,
                        "projection_residual" => residual,
                        "tolerance" => tolerance,
                        "description" => mode.description,
                    ])],
                    suggested_actions = [
                        "Check references, active constraints, and plugin assumptions before treating the missing mode as an error.",
                    ],
                    affected = affected,
                ),
            )
        end
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
    expected_modes::AbstractVector{<:ExpectedNullspaceMode} =
        expected_nullspace_modes(model, evaluation),
    expected_mode_residual_tolerance::Real =
        sqrt(eps(eltype(evaluation.point.values))),
    kwargs...,
)
    comparison = structural_numerical_comparison(model, evaluation; kwargs...)
    fingerprints = nullspace_fingerprints(comparison)
    report = DiagnosticReport()
    append!(report.findings, _structural_numerical_findings(comparison))
    append!(report.findings, _nullspace_fingerprint_findings(comparison, evaluation, fingerprints))
    append!(report.findings, _unknown_local_degeneracy_findings(comparison, fingerprints))
    append!(
        report.findings,
        _expected_nullspace_mode_findings(
            comparison,
            expected_modes;
            residual_tolerance = expected_mode_residual_tolerance,
        ),
    )
    report.metadata[:stage] = "degeneracy"
    report.metadata[:evaluation_point_label] = evaluation.point.label
    report.metadata[:structural_numerical_comparison_available] =
        string(comparison.available)
    report.metadata[:structural_matching_rank] =
        string(comparison.structural_matching_rank)
    report.metadata[:aligned_numerical_rank] = string(comparison.numerical_rank)
    report.metadata[:generic_nullspace_fingerprint_count] = string(length(fingerprints))
    report.metadata[:declared_expected_nullspace_mode_count] = string(length(expected_modes))
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
