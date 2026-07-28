function _activity_evidence(summary::ConstraintFeasibilitySummary, activity::ConstraintActivity)
    return Evidence(
        "Constraint feasibility and activity";
        details = [
            "row" => activity.row,
            "classification" => activity.classification,
            "value" => activity.value,
            "lower" => activity.lower,
            "upper" => activity.upper,
            "lower_margin" => activity.lower_margin,
            "upper_margin" => activity.upper_margin,
            "feasibility_violation" => activity.feasibility_violation,
            "feasibility_tolerance" => summary.feasibility_tolerance,
            "active_tolerance" => summary.active_tolerance,
        ],
    )
end

function _active_left_nullspace_fingerprints(
    evaluation::NumericalEvaluation{T},
    selected_rows::Vector{Int},
    estimate::JacobianRankEstimate{T};
    support_relative::Real = 0.1,
) where {T<:AbstractFloat}
    estimate.available || return Finding[]
    estimate.left_nullity > 0 || return Finding[]
    relative = convert(T, support_relative)
    zero(T) < relative <= one(T) || throw(ArgumentError(
        "active nullspace support_relative must lie in (0, 1]",
    ))
    findings = Finding[]
    for vector_index in axes(estimate.left_nullspace, 2)
        vector = view(estimate.left_nullspace, :, vector_index)
        magnitude = maximum(abs, vector; init = zero(T))
        iszero(magnitude) && continue
        local_support = findall(value -> abs(value) >= relative * magnitude, vector)
        length(local_support) == 2 || continue
        rows = selected_rows[local_support]
        weights = abs.(vector[local_support]) ./ magnitude
        push!(findings, Finding(:active_candidate_two_row_dependence;
            severity = SeverityWarning,
            domain = NumericalIssue,
            basis = HeuristicInterpretation,
            confidence = ConfidenceMedium,
            observation = "A left-null vector of the selected active Jacobian is concentrated on active rows $(rows[1]) and $(rows[2]).",
            why_it_matters = "This resembles a pair of locally dependent active gradients, but can still arise from point-specific derivative cancellation or activity selection.",
            evidence = [
                _point_evidence(evaluation.point),
                Evidence("Active-set left-nullspace fingerprint"; details = [
                    "vector_index" => vector_index,
                    "active_rows" => join(rows, ","),
                    "relative_support_threshold" => relative,
                    "normalized_support_magnitudes" => join(weights, ","),
                ]),
            ],
            affected = EntityRef[evaluation.constraint_sources[row] for row in rows],
            suggested_actions = [
                "Compare these rows with duplicate-expression and structural matching findings.",
                "Repeat at nearby points and under varied activity tolerances before treating them as redundant equations.",
            ],
        ))
    end
    for vector_index in axes(estimate.left_nullspace, 2)
        vector = view(estimate.left_nullspace, :, vector_index)
        magnitude = maximum(abs, vector; init = zero(T))
        iszero(magnitude) && continue
        local_support = findall(value -> abs(value) >= relative * magnitude, vector)
        3 <= length(local_support) <= 8 || continue
        rows = selected_rows[local_support]
        weights = abs.(vector[local_support]) ./ magnitude
        push!(findings, Finding(:active_candidate_multirow_dependence;
            severity = SeverityWarning,
            domain = NumericalIssue,
            basis = HeuristicInterpretation,
            confidence = ConfidenceMedium,
            observation = "A left-null vector of the selected active Jacobian has compact support on $(length(rows)) active rows.",
            why_it_matters = "This resembles a locally dependent active constraint cluster, but can still reflect point-specific derivative cancellation or the chosen activity threshold.",
            evidence = [
                _point_evidence(evaluation.point),
                Evidence("Active-set left-nullspace fingerprint"; details = [
                    "vector_index" => vector_index,
                    "active_rows" => join(rows, ","),
                    "relative_support_threshold" => relative,
                    "normalized_support_magnitudes" => join(weights, ","),
                ]),
            ],
            affected = EntityRef[evaluation.constraint_sources[row] for row in rows],
            suggested_actions = [
                "Inspect this row cluster for redundant balances, duplicated equations, or an intended aggregate constraint.",
                "Repeat at nearby points and under varied activity tolerances before treating the cluster as structurally redundant.",
            ],
        ))
    end
    return findings
end

function _active_right_nullspace_fingerprints(
    evaluation::NumericalEvaluation{T},
    estimate::JacobianRankEstimate{T};
    support_relative::Real = 0.1,
    uniform_shift_correlation::Real = 0.98,
) where {T<:AbstractFloat}
    estimate.available || return Finding[]
    estimate.right_nullity > 0 || return Finding[]
    relative = convert(T, support_relative)
    correlation_threshold = convert(T, uniform_shift_correlation)
    zero(T) < relative <= one(T) || throw(ArgumentError(
        "active nullspace support_relative must lie in (0, 1]",
    ))
    zero(T) <= correlation_threshold <= one(T) || throw(ArgumentError(
        "active nullspace uniform_shift_correlation must lie in [0, 1]",
    ))
    findings = Finding[]
    for vector_index in axes(estimate.right_nullspace, 2)
        vector = view(estimate.right_nullspace, :, vector_index)
        magnitude = maximum(abs, vector; init = zero(T))
        iszero(magnitude) && continue
        local_support = findall(value -> abs(value) >= relative * magnitude, vector)
        correlation = abs(sum(vector)) / (sqrt(T(length(vector))) * norm(vector))
        length(vector) >= 2 && length(local_support) == length(vector) &&
        correlation >= correlation_threshold || continue
        push!(findings, Finding(:active_candidate_uniform_tangent_shift;
            severity = SeverityInfo,
            domain = RepresentationalIssue,
            basis = HeuristicInterpretation,
            confidence = ConfidenceMedium,
            observation = "A right-null vector of the selected active Jacobian is nearly uniform across all $(length(vector)) evaluated coordinates.",
            why_it_matters = "This resembles a common-coordinate tangent shift or gauge freedom, but coordinate units and model semantics are required before assigning a physical interpretation.",
            evidence = [
                _point_evidence(evaluation.point),
                Evidence("Active-set right-nullspace fingerprint"; details = [
                    "vector_index" => vector_index,
                    "uniform_shift_correlation" => correlation,
                    "relative_support_threshold" => relative,
                ]),
            ],
            affected = EntityRef[
                EntityRef(:variable, variable.value) for variable in evaluation.point.variables
            ],
            suggested_actions = [
                "Confirm that the affected coordinates share units and admit a meaningful common reference direction.",
                "Declare an expected gauge through a domain plugin before treating this mode as benign.",
            ],
        ))
    end
    return findings
end

function _active_expected_nullspace_mode_findings(
    evaluation::NumericalEvaluation{T},
    selected_rows::Vector{Int},
    modes::AbstractVector{<:ExpectedNullspaceMode};
    residual_tolerance::Real = sqrt(eps(T)),
) where {T<:AbstractFloat}
    isempty(selected_rows) && return Finding[]
    tolerance = convert(T, residual_tolerance)
    tolerance >= zero(T) || throw(ArgumentError(
        "active expected-mode residual_tolerance must be nonnegative",
    ))
    column_by_variable = Dict(
        variable => column for (column, variable) in enumerate(evaluation.point.variables)
    )
    selected_by_row = Dict(row => position for (position, row) in enumerate(selected_rows))
    findings = Finding[]
    for mode in modes
        columns = [get(column_by_variable, variable, 0) for variable in mode.variables]
        if any(iszero, columns)
            push!(findings, Finding(:active_expected_nullspace_mode_unaligned;
                severity = SeverityInfo, domain = RepresentationalIssue,
                basis = StructuralProof, confidence = ConfidenceCertain,
                observation = "Expected active-set nullspace mode $(mode.name) cannot be aligned with the evaluation coordinates.",
                why_it_matters = "No active tangent comparison is valid when a declared mode omits or references unavailable variables.",
                evidence = [Evidence("Active expected-nullspace declaration"; details = ["mode" => mode.name, "description" => mode.description])],
                suggested_actions = ["Declare the mode in the current evaluation-point variable coordinates."],
            ))
            continue
        end
        direction = zeros(T, length(evaluation.point.variables))
        for (column, value) in zip(columns, mode.direction)
            direction[column] += convert(T, value)
        end
        residual = zeros(T, length(selected_rows))
        for entry in evaluation.jacobian_entries
            position = get(selected_by_row, entry.row, 0)
            iszero(position) && continue
            residual[position] += entry.value * direction[entry.column]
        end
        residual_norm = norm(residual)
        direction_norm = norm(direction)
        observed = residual_norm <= tolerance * max(one(T), direction_norm)
        affected = EntityRef[
            EntityRef(:variable, variable.value) for variable in mode.variables
        ]
        push!(findings, Finding(
            observed ? :active_expected_nullspace_mode_observed :
                       :active_expected_nullspace_mode_not_observed;
            severity = SeverityInfo,
            domain = RepresentationalIssue,
            basis = observed ? PhysicalExpectation : LocalInference,
            confidence = observed ? ConfidenceHigh : ConfidenceMedium,
            observation = observed ?
                          "Declared mode $(mode.name) is tangent to the selected active Jacobian at this point." :
                          "Declared mode $(mode.name) is not tangent to the selected active Jacobian at this point.",
            why_it_matters = observed ?
                             "The observed active-set geometry is consistent with the declared expected mode, but this does not validate the model's physical semantics." :
                             "An expected gauge can be removed by active constraints or fail to appear at this operating point; this is local evidence, not a plugin error.",
            evidence = [
                _point_evidence(evaluation.point),
                Evidence("Active expected-nullspace comparison"; details = [
                    "mode" => mode.name,
                    "description" => mode.description,
                    "selected_rows" => join(selected_rows, ","),
                    "residual_norm" => residual_norm,
                    "residual_tolerance" => tolerance,
                ]),
            ],
            affected = affected,
            suggested_actions = observed ?
                                ["Retain the declaration as expected-mode evidence and confirm its units and domain semantics."] :
                                ["Inspect the active constraints and operating point before changing the expected-mode declaration."],
        ))
    end
    return findings
end

function _active_expected_nullspace_span_findings(
    evaluation::NumericalEvaluation{T},
    selected_rows::Vector{Int},
    estimate::JacobianRankEstimate{T},
    modes::AbstractVector{<:ExpectedNullspaceMode};
    residual_tolerance::Real = sqrt(eps(T)),
) where {T<:AbstractFloat}
    (estimate.available && !isempty(selected_rows) && !isempty(modes)) || return Finding[]
    tolerance = convert(T, residual_tolerance)
    tolerance >= zero(T) || throw(ArgumentError(
        "active expected-mode residual_tolerance must be nonnegative",
    ))
    column_by_variable = Dict(
        variable => column for (column, variable) in enumerate(evaluation.point.variables)
    )
    selected_by_row = Dict(row => position for (position, row) in enumerate(selected_rows))
    directions = Vector{Vector{T}}()
    names = Symbol[]
    all_tangent = true
    for mode in modes
        columns = [get(column_by_variable, variable, 0) for variable in mode.variables]
        any(iszero, columns) && continue
        direction = zeros(T, length(evaluation.point.variables))
        for (column, value) in zip(columns, mode.direction)
            direction[column] += convert(T, value)
        end
        residual = zeros(T, length(selected_rows))
        for entry in evaluation.jacobian_entries
            position = get(selected_by_row, entry.row, 0)
            iszero(position) && continue
            residual[position] += entry.value * direction[entry.column]
        end
        norm(residual) <= tolerance * max(one(T), norm(direction)) || (all_tangent = false)
        push!(directions, direction)
        push!(names, mode.name)
    end
    isempty(directions) && return Finding[]
    matrix = hcat(directions...)
    factorization = svd(matrix)
    scale = isempty(factorization.S) ? one(T) : maximum(factorization.S)
    declared_rank = count(value -> value > tolerance * max(one(T), scale), factorization.S)
    findings = Finding[]
    if declared_rank < length(directions)
        push!(findings, Finding(:active_expected_nullspace_mode_declarations_dependent;
            severity = SeverityInfo, domain = RepresentationalIssue,
            basis = NumericalObservation, confidence = ConfidenceHigh,
            observation = "$(length(directions)) declared active expected modes span only $declared_rank independent direction(s).",
            why_it_matters = "Dependent declarations can overstate the expected active tangent dimension and obscure additional observed freedom.",
            evidence = [Evidence("Active expected-nullspace span"; details = ["modes" => join(names, ","), "declared_count" => length(directions), "declared_rank" => declared_rank, "tolerance" => tolerance])],
            suggested_actions = ["Remove duplicate mode declarations or combine them into an independent basis."],
        ))
    end
    if all_tangent && estimate.right_nullity > declared_rank
        push!(findings, Finding(:active_undeclared_tangent_directions;
            severity = SeverityWarning, domain = NumericalIssue,
            basis = LocalInference, confidence = ConfidenceHigh,
            observation = "The selected active Jacobian has right nullity $(estimate.right_nullity), exceeding the declared active-mode span rank $declared_rank.",
            why_it_matters = "Additional local active tangent directions remain unexplained by the declared modes; they may be missing gauges, unconstrained coordinates, or point-specific rank loss.",
            evidence = [
                _point_evidence(evaluation.point),
                Evidence("Active expected-nullspace span"; details = ["modes" => join(names, ","), "declared_rank" => declared_rank, "observed_right_nullity" => estimate.right_nullity]),
            ],
            affected = EntityRef[
                EntityRef(:variable, variable.value) for variable in evaluation.point.variables
            ],
            suggested_actions = ["Inspect the extra right-nullspace directions and declare only physically or representationally expected modes."],
        ))
    end
    return findings
end

function _active_set_findings(
    evaluation::NumericalEvaluation,
    summary::ConstraintFeasibilitySummary,
    selected_rows::Vector{Int},
    estimate::JacobianRankEstimate,
    mfcq::MFCQScreen,
    recovery::MultiplierRecovery,
)
    findings = Finding[]
    for activity in summary.activities
        activity.classification == :violated || continue
        push!(
            findings,
            Finding(
                :constraint_feasibility_violation;
                severity = SeverityError,
                domain = MathematicalIssue,
                basis = MathematicalProof,
                confidence = ConfidenceCertain,
                observation = "Constraint row $(activity.row) violates its recorded scalar bound by $(activity.feasibility_violation) at point \"$(evaluation.point.label)\".",
                why_it_matters = "The supplied point is infeasible under the stated feasibility tolerance, so KKT-style active-set conclusions must be treated as diagnostic probes rather than a feasible-point certificate.",
                evidence = [_point_evidence(evaluation.point), _activity_evidence(summary, activity)],
                suggested_actions = [
                    "Inspect the residual, units, and declared set for this row.",
                    "Use a feasibility-restoration or elastic diagnostic before interpreting multipliers.",
                ],
                affected = [activity.source],
            ),
        )
    end
    opaque = filter(activity -> activity.classification == :opaque_set, summary.activities)
    if !isempty(opaque)
        push!(
            findings,
            Finding(
                :constraint_activity_semantics_unavailable;
                severity = SeverityInfo,
                domain = RepresentationalIssue,
                basis = StructuralProof,
                confidence = ConfidenceCertain,
                observation = "Generic scalar feasibility/activity semantics are unavailable for $(length(opaque)) evaluated row(s).",
                why_it_matters = "Coupled or plugin-defined sets cannot be safely converted into scalar active inequalities by the generic core.",
                evidence = [
                    _point_evidence(evaluation.point),
                    Evidence(
                        "Rows without generic scalar bounds";
                        details = ["rows" => join((activity.row for activity in opaque), ",")],
                    ),
                ],
                suggested_actions = [
                    "Use a domain plugin to provide activity semantics for this set type.",
                ],
                affected = EntityRef[activity.source for activity in opaque],
            ),
        )
    end
    affected = EntityRef[evaluation.constraint_sources[row] for row in selected_rows]
    if !estimate.available
        push!(
            findings,
            Finding(
                :active_constraint_rank_analysis_unavailable;
                severity = SeverityInfo,
                domain = NumericalIssue,
                basis = NumericalObservation,
                confidence = ConfidenceCertain,
                observation = "LICQ-style rank analysis is unavailable for the selected active rows.",
                why_it_matters = "Incomplete or non-finite derivative evidence cannot establish active-constraint independence.",
                evidence = [
                    _point_evidence(evaluation.point),
                    Evidence(
                        "Active-row rank availability";
                        details = [
                            "rows" => join(selected_rows, ","),
                            "reason" => estimate.reason,
                        ],
                    ),
                ],
                suggested_actions = [
                    "Resolve derivative failures before interpreting active-set degeneracy.",
                ],
                affected = affected,
            ),
        )
    elseif estimate.rank < length(selected_rows)
        push!(
            findings,
            Finding(
                :active_constraint_licq_failure;
                severity = SeverityWarning,
                domain = NumericalIssue,
                basis = NumericalObservation,
                confidence = ConfidenceHigh,
                observation = "The selected active Jacobian has rank $(estimate.rank) for $(length(selected_rows)) selected rows.",
                why_it_matters = "Dependent active gradients violate LICQ at this point and can lead to non-unique multipliers or unstable SQP/interior-point steps.",
                evidence = [
                    _point_evidence(evaluation.point),
                    _rank_evidence(estimate),
                    Evidence(
                        "Explicit active-set selector";
                        details = [
                            "rows" => join(selected_rows, ","),
                            "feasibility_tolerance" => summary.feasibility_tolerance,
                            "active_tolerance" => summary.active_tolerance,
                        ],
                    ),
                ],
                suggested_actions = [
                    "Inspect dependent active constraints and compare them with structural duplicate or matching findings.",
                    "Vary the documented activity tolerance before treating this as a scale-independent degeneracy.",
                ],
                affected = affected,
            ),
        )
    end
    if mfcq.available && mfcq.direction_found && !isempty(mfcq.inequality_rows)
        push!(
            findings,
            Finding(
                :mfcq_common_descent_direction_found;
                severity = SeverityInfo,
                domain = NumericalIssue,
                basis = LocalInference,
                confidence = ConfidenceMedium,
                observation = "A simple equality-tangent direction strictly decreases all $(length(mfcq.inequality_rows)) selected active inequality sides.",
                why_it_matters = "This is positive local evidence for MFCQ, but not a substitute for a full exact feasibility certificate.",
                evidence = [
                    _point_evidence(evaluation.point),
                    Evidence(
                        "Conservative MFCQ screen";
                        details = [
                            "equality_rows" => join(mfcq.equality_rows, ","),
                            "inequality_rows" => join(mfcq.inequality_rows, ","),
                            "largest_directional_derivative" => mfcq.largest_active_inequality_directional_derivative,
                        ],
                    ),
                ],
                suggested_actions = [
                    "Treat this as point-local evidence and verify it with a solver or domain-specific feasibility analysis when consequential.",
                ],
                affected = affected,
            ),
        )
    end
    if mfcq.available && mfcq.failure_witness_found
        push!(
            findings,
            Finding(
                :mfcq_no_common_descent_witness;
                severity = SeverityWarning,
                domain = NumericalIssue,
                basis = NumericalObservation,
                confidence = ConfidenceHigh,
                observation = "A nonnegative convex combination of the $(length(mfcq.inequality_rows)) selected active inequality gradients has equality-tangent residual $(mfcq.failure_witness_residual).",
                why_it_matters = "This is numerical evidence against a common strict descent direction for the selected active rows. It can indicate MFCQ failure, but remains dependent on derivative accuracy, row selection, and the recorded tolerance.",
                evidence = [
                    _point_evidence(evaluation.point),
                    Evidence(
                        "MFCQ no-common-descent witness";
                        details = [
                            "equality_rows" => join(mfcq.equality_rows, ","),
                            "inequality_rows" => join(mfcq.inequality_rows, ","),
                            "witness_weights" => join(mfcq.failure_witness_weights, ","),
                            "witness_residual" => mfcq.failure_witness_residual,
                        ],
                    ),
                ],
                suggested_actions = [
                    "Inspect opposing or dependent active inequality gradients and vary the documented activity tolerance.",
                    "Repeat with exact derivatives or a solver-specific constraint qualification check before treating this as conclusive.",
                ],
                affected = affected,
            ),
        )
    end
    if recovery.available && !recovery.unique
        push!(
            findings,
            Finding(
                :nonunique_active_multipliers;
                severity = SeverityWarning,
                domain = NumericalIssue,
                basis = LocalInference,
                confidence = ConfidenceHigh,
                observation = "The selected active-gradient system has rank $(recovery.active_gradient_rank) for $(length(recovery.rows)) multiplier sides.",
                why_it_matters = "The recovered stationarity multipliers are not unique at this point; dual values should not be interpreted as a unique economic or physical signal.",
                evidence = [
                    _point_evidence(evaluation.point),
                    Evidence("Local multiplier recovery"; details = [
                        "rows" => join(recovery.rows, ","),
                        "sides" => join(recovery.sides, ","),
                        "stationarity_residual_norm" => recovery.stationarity_residual_norm,
                        "feasible_point" => recovery.feasible_point,
                    ]),
                ],
                suggested_actions = [
                    "Inspect dependent active gradients and compare with the LICQ result.",
                    "Treat returned multiplier values as one minimum-norm representative only.",
                ],
                affected = EntityRef[evaluation.constraint_sources[row] for row in unique(recovery.rows)],
            ),
        )
    elseif recovery.available && !isnothing(recovery.stationarity_residual_norm) &&
           recovery.stationarity_residual_norm > sqrt(eps(eltype(evaluation.point.values)))
        push!(
            findings,
            Finding(
                :large_local_stationarity_residual;
                severity = SeverityInfo,
                domain = NumericalIssue,
                basis = NumericalObservation,
                confidence = ConfidenceHigh,
                observation = "Least-squares active-set multiplier recovery leaves stationarity residual norm $(recovery.stationarity_residual_norm).",
                why_it_matters = "The selected sides and objective gradient do not satisfy local first-order stationarity to the default numerical scale.",
                evidence = [_point_evidence(evaluation.point)],
                suggested_actions = [
                    "Check whether this is an infeasible or nonstationary probe point before interpreting multipliers.",
                ],
            ),
        )
    end
    dual_tolerance = sqrt(eps(eltype(evaluation.point.values)))
    if recovery.available &&
       !isnothing(recovery.inequality_dual_violation) &&
       recovery.inequality_dual_violation > dual_tolerance
        push!(
            findings,
            Finding(
                :recovered_active_multiplier_sign_violation;
                severity = SeverityInfo,
                domain = NumericalIssue,
                basis = LocalInference,
                confidence = ConfidenceHigh,
                observation = "The recovered active inequality multipliers have nonnegativity violation $(recovery.inequality_dual_violation).",
                why_it_matters = "This minimum-norm stationarity representative is not dual feasible for the selected inequality sides, so the probe is not locally KKT-consistent.",
                evidence = [
                    _point_evidence(evaluation.point),
                    Evidence("Local multiplier sign screen"; details = [
                        "dual_violation" => recovery.inequality_dual_violation,
                        "tolerance" => dual_tolerance,
                        "stationarity_residual_norm" => recovery.stationarity_residual_norm,
                    ]),
                ],
                suggested_actions = [
                    "Check whether the point is stationary and whether the selected active sides use the intended sign convention.",
                    "Treat the least-squares multipliers as diagnostics, not solver dual values.",
                ],
                affected = EntityRef[evaluation.constraint_sources[row] for row in unique(recovery.rows)],
            ),
        )
    end
    if recovery.available &&
       !isnothing(recovery.complementarity_residual) &&
       recovery.complementarity_residual >
       dual_tolerance * summary.active_tolerance
        push!(
            findings,
            Finding(
                :recovered_active_multiplier_complementarity_residual;
                severity = SeverityInfo,
                domain = NumericalIssue,
                basis = LocalInference,
                confidence = ConfidenceHigh,
                observation = "The recovered active multipliers have complementarity residual $(recovery.complementarity_residual).",
                why_it_matters = "The activity tolerance and multiplier scale leave a non-negligible local complementarity mismatch.",
                evidence = [_point_evidence(evaluation.point)],
                suggested_actions = [
                    "Tighten or vary the active-set tolerance and inspect the corresponding bound margins.",
                ],
                affected = EntityRef[evaluation.constraint_sources[row] for row in unique(recovery.rows)],
            ),
        )
    end
    return findings
end

function _active_matching_findings(
    evaluation::NumericalEvaluation,
    active_matching::ActiveSetStructuralMatching,
)
    active_matching.complete || return Finding[]
    matching = active_matching.matching
    cardinality = matching_cardinality(matching)
    selected_count = length(active_matching.selected_constraint_positions)
    cardinality == selected_count && return Finding[]
    affected = EntityRef[
        evaluation.constraint_sources[row] for row in active_matching.selected_rows
    ]
    return Finding[Finding(
        :active_set_structural_overdetermination;
        severity = SeverityWarning,
        domain = MathematicalIssue,
        basis = LocalInference,
        confidence = ConfidenceHigh,
        observation = "The selected active-set incidence pattern matches only $cardinality of $selected_count aligned scalar equation row(s) to free variables.",
        why_it_matters = "After the point-local activity selection, this structural deficiency is consistent with redundant active equations and the LICQ or multiplier non-uniqueness diagnostics.",
        evidence = [
            _point_evidence(evaluation.point),
            Evidence("Active-set structural matching"; details = [
                "selected_activity_rows" => join(active_matching.selected_rows, ","),
                "aligned_constraint_nodes" => selected_count,
                "eligible_free_variables" => length(matching.eligible_variable_positions),
                "matching_cardinality" => cardinality,
                "scope" => "only selected ordinary scalar rows; activity is point-local",
            ]),
        ],
        suggested_actions = [
            "Inspect the selected rows for duplicate or dependent active equations.",
            "Compare this structural screen with the local Jacobian-rank and multiplier-recovery evidence.",
        ],
        affected = affected,
    )]
end

function _active_structural_numerical_tangent_findings(
    model::MOI.ModelLike,
    evaluation::NumericalEvaluation{T},
    active_matching::ActiveSetStructuralMatching;
    rank_relative_tolerance::Real,
    rank_max_dense_entries::Integer,
) where {T<:AbstractFloat}
    active_matching.complete || return Finding[]
    graph = incidence_graph(model)
    free_variables = MOI.VariableIndex[
        graph.variables[position].index for position in
        active_matching.matching.eligible_variable_positions
    ]
    columns_by_variable = Dict(
        variable => column for (column, variable) in enumerate(evaluation.point.variables)
    )
    columns = [get(columns_by_variable, variable, 0) for variable in free_variables]
    any(iszero, columns) && return Finding[Finding(
        :active_tangent_structural_numerical_comparison_unavailable;
        severity = SeverityInfo, domain = RepresentationalIssue,
        basis = NumericalObservation, confidence = ConfidenceHigh,
        observation = "Active-set structural free variables cannot be aligned with every evaluation coordinate.",
        why_it_matters = "No structural-versus-numerical tangent-nullity comparison is made for a mismatched coordinate scope.",
        evidence = [Evidence("Active tangent coordinate alignment"; details = ["free_variable_count" => length(free_variables)])],
        suggested_actions = ["Evaluate all free model variables in the active-set point."],
    )]
    selected = _selected_jacobian_submatrix_evaluation(
        evaluation, active_matching.selected_rows, columns,
    )
    estimate = jacobian_rank_estimate(selected;
        relative_tolerance = rank_relative_tolerance,
        max_dense_entries = rank_max_dense_entries,
        compute_vectors = false,
    )
    estimate.available || return Finding[Finding(
        :active_tangent_structural_numerical_comparison_unavailable;
        severity = SeverityInfo, domain = NumericalIssue,
        basis = NumericalObservation, confidence = ConfidenceHigh,
        observation = "Active-set structural/numerical tangent comparison is unavailable.",
        why_it_matters = "Incomplete, non-finite, or guarded-out derivatives cannot establish local tangent nullity.",
        evidence = [Evidence("Active tangent rank estimate"; details = ["reason" => estimate.reason])],
        suggested_actions = ["Resolve derivative availability or adjust the documented rank guard before interpreting active tangent freedom."],
    )]
    structural_nullity = length(columns) - matching_cardinality(active_matching.matching)
    observed_nullity = estimate.right_nullity
    affected = EntityRef[
        EntityRef(:variable, variable.value) for variable in free_variables
    ]
    evidence = [
        _point_evidence(evaluation.point),
        Evidence("Active structural/numerical tangent comparison"; details = [
            "free_variable_count" => length(columns),
            "structural_matching_rank" => matching_cardinality(active_matching.matching),
            "structural_right_nullity" => structural_nullity,
            "numerical_rank" => estimate.rank,
            "numerical_right_nullity" => observed_nullity,
        ]),
    ]
    findings = Finding[]
    if structural_nullity > 0 && observed_nullity == structural_nullity
        push!(findings, Finding(:active_structurally_expected_tangent_nullspace;
            severity = SeverityInfo, domain = MathematicalIssue,
            basis = LocalInference, confidence = ConfidenceHigh,
            observation = "The active-set structural matching predicts $structural_nullity tangent degree(s) of freedom, matching the local numerical nullity.",
            why_it_matters = "The observed active tangent freedom is structurally expected in this aligned scope; semantics are still needed to classify it as an intended gauge or missing equation.",
            evidence = evidence,
            affected = affected,
            suggested_actions = ["Interpret the tangent directions using expected-mode declarations or domain metadata."],
        ))
    elseif observed_nullity > structural_nullity
        push!(findings, Finding(:active_unexpected_local_tangent_rank_loss;
            severity = SeverityWarning, domain = NumericalIssue,
            basis = LocalInference, confidence = ConfidenceHigh,
            observation = "The active-set numerical tangent nullity $observed_nullity exceeds the structural prediction $structural_nullity.",
            why_it_matters = "Additional local rank loss can indicate dependent active gradients, derivative cancellation, poor coordinates, or a physical singularity.",
            evidence = evidence,
            affected = affected,
            suggested_actions = ["Inspect active nullspace fingerprints, scaling, and nearby points before assigning a physical cause."],
        ))
    end
    return findings
end

function _coupled_set_boundary_is_nonsmooth(
    activity::CoupledSetActivity{T},
    tolerance::T,
) where {T<:AbstractFloat}
    activity.classification == :boundary || return false
    any(ismissing, activity.values) && return false
    numeric = T[value::T for value in activity.values]
    all(isfinite, numeric) || return false
    if activity.set_kind == :second_order_cone
        return abs(numeric[1]) <= tolerance &&
               norm(numeric[2:end]) <= tolerance
    elseif activity.set_kind == :rotated_second_order_cone
        return abs(numeric[1]) <= tolerance || abs(numeric[2]) <= tolerance
    end
    return false
end

function _coupled_set_findings(summary::CoupledSetFeasibilitySummary)
    findings = Finding[]
    for activity in summary.activities
        activity.classification in (:violated, :boundary) || continue
        violated = activity.classification == :violated
        nonsmooth_boundary = !violated && _coupled_set_boundary_is_nonsmooth(
            activity, summary.active_tolerance,
        )
        push!(
            findings,
            Finding(
                violated ? :coupled_set_feasibility_violation :
                (nonsmooth_boundary ? :coupled_set_nonsmooth_boundary_active :
                 :coupled_set_boundary_active);
                severity = violated ? SeverityError : SeverityInfo,
                domain = MathematicalIssue,
                basis = MathematicalProof,
                confidence = ConfidenceCertain,
                observation = violated ?
                              "The $(activity.set_kind) constraint has feasibility residual $(activity.feasibility_violation)." :
                              (nonsmooth_boundary ?
                               "The $(activity.set_kind) constraint is on a nonsmooth cone boundary (margin $(activity.margin))." :
                               "The $(activity.set_kind) constraint is on its smooth cone boundary (margin $(activity.margin))."),
                why_it_matters = violated ?
                                  "The evaluated point is outside this coupled set." :
                                  (nonsmooth_boundary ?
                                   "The cone has no unique scalar boundary normal at this point, so scalar active-row reductions are especially misleading." :
                                   "Cone-boundary activity is vector-set geometry and is intentionally not converted into scalar active rows by the generic core."),
                evidence = [Evidence("Coupled-set feasibility"; details = [
                    "set_kind" => activity.set_kind,
                    "margin" => activity.margin,
                    "feasibility_violation" => activity.feasibility_violation,
                    "feasibility_tolerance" => summary.feasibility_tolerance,
                    "active_tolerance" => summary.active_tolerance,
                ])],
                suggested_actions = violated ?
                                    ["Inspect the vector components and use a cone-aware feasibility restoration diagnostic."] :
                                    (nonsmooth_boundary ?
                                     ["Avoid scalarizing this apex or axis boundary; use a cone-aware solver or plugin for tangent interpretation."] :
                                     ["Use a cone-aware solver or plugin before interpreting this boundary as scalar active constraints."]),
                affected = [activity.source],
            ),
        )
    end
    return findings
end

function _coupled_set_tangent_findings(summary::CoupledSetFeasibilitySummary)
    return [Finding(
        :coupled_set_smooth_boundary_tangent_available;
        severity = SeverityInfo,
        domain = NumericalIssue,
        basis = MathematicalProof,
        confidence = ConfidenceCertain,
        observation = "A smooth $(tangent.set_kind) boundary normal is available in vector-function coordinates.",
        why_it_matters = "This supports cone-aware local interpretation, but remains coupled-set geometry rather than a scalar LICQ/MFCQ row.",
        evidence = [Evidence("Coupled-set tangent evidence"; details = [
            "set_kind" => tangent.set_kind,
            "normal_dimension" => length(tangent.normal),
            "normal" => join(tangent.normal, ","),
            "description" => tangent.description,
        ])],
        affected = [tangent.source],
        suggested_actions = [
            "Use the normal only with cone-aware tangent or KKT analysis; do not treat it as an automatically selected scalar active row.",
        ],
    ) for tangent in summary.tangents]
end

function _coupled_set_tangent_gradient_findings(
    evaluation::NumericalEvaluation{T},
    summary::CoupledSetFeasibilitySummary{T},
) where {T<:AbstractFloat}
    findings = Finding[]
    for tangent in summary.tangents
        rows = [
            row for (row, source) in enumerate(evaluation.constraint_sources)
            if source.kind == :constraint && source.index == tangent.source.index &&
               !isnothing(source.subindex)
        ]
        sort!(rows; by = row -> something(evaluation.constraint_sources[row].subindex))
        if length(rows) != length(tangent.normal)
            push!(findings, Finding(
                :coupled_set_boundary_tangent_gradient_unavailable;
                severity = SeverityInfo,
                domain = RepresentationalIssue,
                basis = StructuralProof,
                confidence = ConfidenceCertain,
                observation = "The $(tangent.set_kind) boundary normal cannot be aligned with all evaluated vector-function rows.",
                why_it_matters = "A model-coordinate cone tangent gradient requires the same ordered vector outputs as the declared normal.",
                evidence = [Evidence("Coupled-set tangent gradient alignment"; details = [
                    "set_kind" => tangent.set_kind,
                    "normal_dimension" => length(tangent.normal),
                    "aligned_row_count" => length(rows),
                ])],
                affected = [tangent.source],
                suggested_actions = [
                    "Evaluate every vector output row of the coupled constraint before requesting cone tangent interpretation.",
                ],
            ))
            continue
        end
        if any(
            row > length(evaluation.jacobian_row_methods) ||
            evaluation.jacobian_row_methods[row] in
            (:unavailable, :partial_central_finite_difference)
            for row in rows
        )
            push!(findings, Finding(
                :coupled_set_boundary_tangent_gradient_unavailable;
                severity = SeverityInfo,
                domain = NumericalIssue,
                basis = NumericalObservation,
                confidence = ConfidenceHigh,
                observation = "The $(tangent.set_kind) boundary tangent gradient requires incomplete vector-function derivative rows.",
                why_it_matters = "Missing derivative rows must not be treated as zero cone-tangent sensitivities.",
                evidence = [Evidence("Coupled-set tangent gradient availability"; details = [
                    "set_kind" => tangent.set_kind,
                    "rows" => join(rows, ","),
                ])],
                affected = [tangent.source],
                suggested_actions = [
                    "Supply complete vector-function derivatives before interpreting the coupled-set boundary tangent.",
                ],
            ))
            continue
        end
        position_by_row = Dict(row => position for (position, row) in enumerate(rows))
        gradient = zeros(T, length(evaluation.point.variables))
        complete = true
        for entry in evaluation.jacobian_entries
            position = get(position_by_row, entry.row, 0)
            iszero(position) && continue
            if !isfinite(entry.value)
                complete = false
                break
            end
            gradient[entry.column] += tangent.normal[position] * entry.value
        end
        if !complete
            push!(findings, Finding(
                :coupled_set_boundary_tangent_gradient_unavailable;
                severity = SeverityInfo,
                domain = NumericalIssue,
                basis = NumericalObservation,
                confidence = ConfidenceHigh,
                observation = "The $(tangent.set_kind) boundary tangent gradient contains non-finite derivative evidence.",
                why_it_matters = "A finite model-coordinate cone tangent gradient cannot be formed from non-finite Jacobian entries.",
                evidence = [Evidence("Coupled-set tangent gradient availability"; details = [
                    "set_kind" => tangent.set_kind,
                ])],
                affected = [tangent.source],
                suggested_actions = [
                    "Resolve derivative-domain failures before interpreting the coupled-set boundary tangent.",
                ],
            ))
            continue
        end
        gradient_norm = norm(gradient)
        support = findall(value -> !iszero(value), gradient)
        zero_gradient = iszero(gradient_norm)
        push!(findings, Finding(
            zero_gradient ? :coupled_set_smooth_boundary_tangent_gradient_zero :
                            :coupled_set_smooth_boundary_tangent_gradient_available;
            severity = zero_gradient ? SeverityWarning : SeverityInfo,
            domain = zero_gradient ? NumericalIssue : RepresentationalIssue,
            basis = zero_gradient ? LocalInference : MathematicalProof,
            confidence = ConfidenceHigh,
            observation = zero_gradient ?
                          "The smooth $(tangent.set_kind) boundary normal maps to a zero model-coordinate gradient at this point." :
                          "The smooth $(tangent.set_kind) boundary normal maps to a nonzero model-coordinate gradient at this point.",
            why_it_matters = zero_gradient ?
                             "The coupled constraint is locally stationary in the model coordinates, so even a smooth cone boundary does not supply a regular scalar tangent screen here." :
                             "The gradient is usable as cone-aware local geometry, but it is intentionally not folded into generic scalar LICQ, MFCQ, or multiplier recovery.",
            evidence = [Evidence("Coupled-set tangent gradient"; details = [
                "set_kind" => tangent.set_kind,
                "gradient_norm" => gradient_norm,
                "support_coordinate_count" => length(support),
            ])],
            affected = isempty(support) ? [tangent.source] : EntityRef[
                EntityRef(:variable, evaluation.point.variables[column].value)
                for column in support
            ],
            suggested_actions = zero_gradient ?
                                ["Inspect the vector-function Jacobian and nearby points before treating this cone boundary as regular."] :
                                ["Use a cone-aware solver or plugin for tangent/KKT interpretation; retain this gradient as local geometry evidence."],
        ))
    end
    return findings
end

"""
    analyze_active_set(model, evaluation; ...)

Evaluate bound residuals, select equality and near-active inequality rows with
explicit tolerances, then run local LICQ and conservative MFCQ screens.
"""
function analyze_active_set(
    model::MOI.ModelLike,
    evaluation::NumericalEvaluation{T};
    feasibility_tolerance::Real = sqrt(eps(T)),
    active_tolerance::Real = sqrt(eps(T)),
    rank_relative_tolerance::Real =
        max(length(evaluation.point.variables), 1) * eps(T),
    rank_max_dense_entries::Integer = 4_000_000,
    mfcq_strict_tolerance::Real = sqrt(eps(T)),
    expected_modes::AbstractVector{<:ExpectedNullspaceMode} =
        expected_nullspace_modes(model, evaluation),
    include_port_topology_modes::Bool = true,
    expected_mode_residual_tolerance::Real = sqrt(eps(T)),
) where {T<:AbstractFloat}
    port_modes = include_port_topology_modes ? port_expected_nullspace_modes(
        component_port_metadata(model),
        component_port_nullspace_modes(model),
        component_port_connections(model),
        component_port_coordinate_maps(model),
    ) : ExpectedNullspaceMode[]
    all_expected_modes = vcat(expected_modes, port_modes)
    summary = constraint_feasibility_summary(
        model,
        evaluation;
        feasibility_tolerance = feasibility_tolerance,
        active_tolerance = active_tolerance,
    )
    selected_rows = active_constraint_rows(summary)
    estimate = jacobian_rank_estimate(
        _selected_jacobian_evaluation(evaluation, selected_rows);
        relative_tolerance = rank_relative_tolerance,
        max_dense_entries = rank_max_dense_entries,
    )
    mfcq = mfcq_screen(
        evaluation,
        summary;
        strict_tolerance = mfcq_strict_tolerance,
        rank_relative_tolerance = rank_relative_tolerance,
        max_dense_entries = rank_max_dense_entries,
    )
    recovery = recover_stationarity_multipliers(
        model,
        evaluation,
        summary;
        rank_relative_tolerance = rank_relative_tolerance,
        max_dense_entries = rank_max_dense_entries,
    )
    active_matching = active_set_matching(model, evaluation, summary)
    coupled_summary = coupled_set_feasibility_summary(
        model,
        evaluation;
        feasibility_tolerance = feasibility_tolerance,
        active_tolerance = active_tolerance,
    )
    report = DiagnosticReport()
    append!(report.findings, _active_set_findings(evaluation, summary, selected_rows, estimate, mfcq, recovery))
    append!(report.findings, _active_left_nullspace_fingerprints(evaluation, selected_rows, estimate))
    append!(report.findings, _active_right_nullspace_fingerprints(evaluation, estimate))
    append!(report.findings, _active_expected_nullspace_mode_findings(
        evaluation, selected_rows, all_expected_modes;
        residual_tolerance = expected_mode_residual_tolerance,
    ))
    append!(report.findings, _active_expected_nullspace_span_findings(
        evaluation, selected_rows, estimate, all_expected_modes;
        residual_tolerance = expected_mode_residual_tolerance,
    ))
    append!(report.findings, _active_matching_findings(evaluation, active_matching))
    append!(report.findings, _active_structural_numerical_tangent_findings(
        model, evaluation, active_matching;
        rank_relative_tolerance = rank_relative_tolerance,
        rank_max_dense_entries = rank_max_dense_entries,
    ))
    append!(report.findings, _coupled_set_findings(coupled_summary))
    append!(report.findings, _coupled_set_tangent_findings(coupled_summary))
    append!(report.findings, _coupled_set_tangent_gradient_findings(
        evaluation, coupled_summary,
    ))
    report.metadata[:stage] = "active_set"
    report.metadata[:evaluation_point_label] = evaluation.point.label
    report.metadata[:active_rows] = join(selected_rows, ",")
    report.metadata[:active_row_count] = string(length(selected_rows))
    report.metadata[:active_jacobian_rank] = string(estimate.rank)
    report.metadata[:active_jacobian_rank_available] = string(estimate.available)
    report.metadata[:active_structural_matching_available] = string(active_matching.complete)
    report.metadata[:active_structural_matching_cardinality] =
        string(matching_cardinality(active_matching.matching))
    report.metadata[:active_expected_nullspace_mode_count] = string(length(expected_modes))
    report.metadata[:active_port_expected_nullspace_mode_count] =
        string(length(port_modes))
    report.metadata[:active_port_component_expected_nullspace_mode_count] = string(count(
        mode -> startswith(string(mode.name), "component_port_candidate_mode_"), port_modes,
    ))
    report.metadata[:active_port_topology_expected_nullspace_mode_count] = string(count(
        mode -> startswith(string(mode.name), "port_topology_candidate_mode_"), port_modes,
    ))
    report.metadata[:active_structural_unmapped_row_count] =
        string(length(active_matching.unmapped_rows))
    report.metadata[:supported_coupled_set_count] = string(length(coupled_summary.activities))
    report.metadata[:mfcq_screen_available] = string(mfcq.available)
    report.metadata[:mfcq_common_descent_direction_found] = string(mfcq.direction_found)
    report.metadata[:mfcq_no_common_descent_witness_found] =
        string(mfcq.failure_witness_found)
    report.metadata[:mfcq_no_common_descent_witness_residual] =
        string(mfcq.failure_witness_residual)
    report.metadata[:multiplier_recovery_available] = string(recovery.available)
    report.metadata[:active_multiplier_unique] = string(recovery.unique)
    report.metadata[:active_multiplier_inequality_dual_violation] =
        string(recovery.inequality_dual_violation)
    report.metadata[:active_multiplier_complementarity_residual] =
        string(recovery.complementarity_residual)
    sort!(report.findings; by = finding -> (-Int(finding.severity), string(finding.code)))
    return report
end

function _recovered_constraint_multipliers(
    recovery::MultiplierRecovery{T},
    constraint_count::Integer,
) where {T}
    multipliers = zeros(T, constraint_count)
    for (row, side, multiplier) in zip(
        recovery.rows,
        recovery.sides,
        recovery.multipliers,
    )
        side == :equality && (multipliers[row] += multiplier)
        side == :lower && (multipliers[row] -= multiplier)
        side == :upper && (multipliers[row] += multiplier)
    end
    return multipliers
end

"""
    analyze_active_set_second_order(model, evaluation; ...)

Run a point-local second-order probe using explicit scalar activity selection
and the recovered least-squares multiplier representative. The result is not a
solver KKT certificate: coupled-set geometry, non-unique multipliers, and
finite-difference Hessians remain visible in the returned report.
"""
function analyze_active_set_second_order(
    model::MOI.ModelLike,
    evaluation::NumericalEvaluation{T};
    feasibility_tolerance::Real = sqrt(eps(T)),
    active_tolerance::Real = sqrt(eps(T)),
    rank_relative_tolerance::Real =
        max(length(evaluation.point.variables), 1) * eps(T),
    rank_max_dense_entries::Integer = 4_000_000,
    hessian_relative_step::Real = eps(T)^(one(T) / 4),
    hessian_max_finite_difference_variables::Integer = 100,
    expected_modes::AbstractVector{<:ExpectedNullspaceMode} =
        expected_nullspace_modes(model, evaluation),
    expected_mode_residual_tolerance::Real = sqrt(eps(T)),
    kwargs...,
) where {T<:AbstractFloat}
    summary = constraint_feasibility_summary(
        model,
        evaluation;
        feasibility_tolerance = feasibility_tolerance,
        active_tolerance = active_tolerance,
    )
    recovery = recover_stationarity_multipliers(
        model,
        evaluation,
        summary;
        rank_relative_tolerance = rank_relative_tolerance,
        max_dense_entries = rank_max_dense_entries,
    )
    report = DiagnosticReport()
    report.metadata[:stage] = "active_set_second_order"
    report.metadata[:evaluation_point_label] = evaluation.point.label
    report.metadata[:second_order_multiplier_recovery_available] =
        string(recovery.available)
    if !recovery.available
        push!(
            report,
            Finding(
                :active_set_second_order_analysis_unavailable;
                severity = SeverityInfo,
                domain = NumericalIssue,
                basis = NumericalObservation,
                confidence = ConfidenceCertain,
                observation = "Active-set second-order analysis is unavailable because multiplier recovery failed.",
                why_it_matters = "A Lagrangian reduced Hessian requires a documented objective weight and constraint-multiplier representative.",
                evidence = [
                    _point_evidence(evaluation.point),
                    Evidence("Multiplier recovery availability"; details = ["reason" => recovery.reason]),
                ],
                suggested_actions = [
                    "Resolve objective-gradient and active-Jacobian failures, then repeat the point-local probe.",
                ],
            ),
        )
        return report
    end
    active_rows = active_constraint_rows(summary)
    hessian = evaluate_lagrangian_hessian(
        model,
        evaluation.point;
        objective_weight = recovery.objective_weight,
        constraint_multipliers = _recovered_constraint_multipliers(
            recovery,
            length(evaluation.constraint_sources),
        ),
        relative_step = hessian_relative_step,
        max_finite_difference_variables = hessian_max_finite_difference_variables,
    )
    reduced_report = analyze_reduced_hessian(
        evaluation,
        hessian;
        active_rows = active_rows,
        expected_modes = expected_modes,
        expected_mode_residual_tolerance = expected_mode_residual_tolerance,
        kwargs...,
    )
    append!(report.findings, reduced_report.findings)
    report.metadata[:second_order_active_rows] = join(active_rows, ",")
    report.metadata[:second_order_multiplier_unique] = string(recovery.unique)
    report.metadata[:second_order_hessian_methods] = join(hessian.methods, ",")
    report.metadata[:second_order_reduced_hessian_available] =
        get(reduced_report.metadata, :reduced_hessian_available, "false")
    report.metadata[:second_order_expected_flat_mode_count] = string(length(expected_modes))
    if !recovery.unique
        push!(
            report,
            Finding(
                :second_order_multiplier_representative_nonunique;
                severity = SeverityInfo,
                domain = NumericalIssue,
                basis = LocalInference,
                confidence = ConfidenceHigh,
                observation = "The reduced-Hessian probe uses one minimum-norm multiplier representative from a non-unique active-gradient system.",
                why_it_matters = "Second-order curvature may depend on multiplier selection when active constraints are dependent.",
                evidence = [_point_evidence(evaluation.point)],
                suggested_actions = [
                    "Resolve active-gradient dependence before treating the reduced spectrum as unique KKT curvature.",
                ],
            ),
        )
    end
    sort!(report.findings; by = finding -> (-Int(finding.severity), string(finding.code)))
    return report
end

function analyze_active_set_second_order(
    model::MOI.ModelLike,
    point::EvaluationPoint;
    cache::EvaluationCache = EvaluationCache(),
    relative_step::Real = cbrt(eps(eltype(point.values))),
    kwargs...,
)
    return analyze_active_set_second_order(
        model,
        evaluate_numerical(model, point; cache = cache, relative_step = relative_step);
        kwargs...,
    )
end

function analyze_active_set_second_order(
    model::MOI.ModelLike,
    values::Union{AbstractVector{<:Real},AbstractDict{MOI.VariableIndex,<:Real}};
    label::AbstractString = "user",
    kwargs...,
)
    return analyze_active_set_second_order(
        model,
        evaluation_point(model, values; label = label);
        kwargs...,
    )
end

function analyze_active_set(
    model::MOI.ModelLike,
    point::EvaluationPoint;
    cache::EvaluationCache = EvaluationCache(),
    relative_step::Real = cbrt(eps(eltype(point.values))),
    kwargs...,
)
    evaluation = evaluate_numerical(
        model,
        point;
        cache = cache,
        relative_step = relative_step,
    )
    return analyze_active_set(model, evaluation; kwargs...)
end

function analyze_active_set(
    model::MOI.ModelLike,
    values::Union{AbstractVector{<:Real},AbstractDict{MOI.VariableIndex,<:Real}};
    label::AbstractString = "user",
    kwargs...,
)
    return analyze_active_set(
        model,
        evaluation_point(model, values; label = label);
        kwargs...,
    )
end
