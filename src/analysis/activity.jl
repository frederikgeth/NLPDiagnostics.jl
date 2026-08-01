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

function _active_derivative_provenance_findings(
    evaluation::NumericalEvaluation,
    selected_rows::Vector{Int},
)
    isempty(selected_rows) && return Finding[]
    methods = evaluation.jacobian_row_methods[selected_rows]
    unique_methods = sort!(unique!(copy(methods)); by = string)
    sources = evaluation.constraint_sources[selected_rows]
    findings = Finding[]
    if length(unique_methods) > 1
        push!(findings, Finding(
            :active_set_mixed_derivative_provenance;
            severity = SeverityInfo,
            domain = RepresentationalIssue,
            basis = NumericalObservation,
            confidence = ConfidenceHigh,
            observation = "The selected active Jacobian combines $(length(unique_methods)) derivative methods across $(length(selected_rows)) row(s).",
            why_it_matters = "LICQ, MFCQ, multiplier recovery, and nullspace conclusions are all point-local numerical results. Mixed derivative paths can have different accuracy, sparsity, and failure semantics, particularly near close rank thresholds.",
            evidence = [
                _point_evidence(evaluation.point),
                Evidence("Active-set derivative provenance"; details = [
                    "active_rows" => join(selected_rows, ","),
                    "methods" => join(unique_methods, ","),
                    "row_methods" => join(methods, ","),
                ]),
            ],
            affected = copy(sources),
            suggested_actions = [
                "Compare the conclusion using one verified derivative path when it is consequential.",
                "Inspect derivative provenance before interpreting marginal rank or multiplier evidence.",
            ],
        ))
    end
    finite_difference_positions = findall(==(:central_finite_difference), methods)
    if !isempty(finite_difference_positions)
        rows = selected_rows[finite_difference_positions]
        push!(findings, Finding(
            :active_set_finite_difference_derivatives;
            severity = SeverityInfo,
            domain = NumericalIssue,
            basis = NumericalObservation,
            confidence = ConfidenceHigh,
            observation = "The selected active Jacobian uses complete central finite-difference derivatives for $(length(rows)) row(s).",
            why_it_matters = "Active-set rank, qualification, multiplier, and nullspace observations for these rows depend on the finite-difference step and evaluation stability. This is derivative provenance, not a model defect.",
            evidence = [
                _point_evidence(evaluation.point),
                Evidence("Active-set derivative provenance"; details = [
                    "finite_difference_rows" => join(rows, ","),
                    "methods" => join(methods, ","),
                ]),
            ],
            affected = EntityRef[
                evaluation.constraint_sources[row] for row in rows
            ],
            suggested_actions = [
                "Vary the finite-difference step and compare the active-set conclusion.",
                "Provide exact or automatic-differentiation derivatives when possible.",
            ],
        ))
    end
    partial_positions = findall(==(:partial_central_finite_difference), methods)
    if !isempty(partial_positions)
        rows = selected_rows[partial_positions]
        push!(findings, Finding(
            :active_set_partial_finite_difference_derivatives;
            severity = SeverityWarning,
            domain = NumericalIssue,
            basis = NumericalObservation,
            confidence = ConfidenceHigh,
            observation = "The selected active Jacobian has incomplete central finite-difference derivatives for $(length(rows)) row(s).",
            why_it_matters = "Missing derivative coordinates must not be treated as zeros; active-set rank and KKT-style conclusions can be unavailable or incomplete for this point.",
            evidence = [
                _point_evidence(evaluation.point),
                Evidence("Active-set derivative provenance"; details = [
                    "partial_finite_difference_rows" => join(rows, ","),
                    "methods" => join(methods, ","),
                ]),
            ],
            affected = EntityRef[
                evaluation.constraint_sources[row] for row in rows
            ],
            suggested_actions = [
                "Resolve the derivative-domain or finite-difference step failure before interpreting active-set geometry.",
                "Provide exact or automatic-differentiation derivatives when possible.",
            ],
        ))
    end
    return findings
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
    for vector_index in axes(estimate.right_nullspace, 2)
        vector = view(estimate.right_nullspace, :, vector_index)
        magnitude = maximum(abs, vector; init = zero(T))
        iszero(magnitude) && continue
        local_support = findall(value -> abs(value) >= relative * magnitude, vector)
        length(local_support) == 1 || continue
        variable = only(evaluation.point.variables[local_support])
        push!(findings, Finding(
            :active_candidate_single_coordinate_tangent_direction;
            severity = SeverityWarning,
            domain = NumericalIssue,
            basis = HeuristicInterpretation,
            confidence = ConfidenceMedium,
            observation = "A right-null vector of the selected active Jacobian is concentrated on variable $(variable.value).",
            why_it_matters = "This coordinate is locally free to first order under the selected active rows. It can indicate an unmatched structural degree of freedom, a stationary nonlinear derivative, or a derivative-evaluation artifact; it is not a proof of any one cause.",
            evidence = [
                _point_evidence(evaluation.point),
                Evidence("Active-set right-nullspace fingerprint"; details = [
                    "vector_index" => vector_index,
                    "variable" => variable.value,
                    "relative_support_threshold" => relative,
                    "normalized_support_magnitude" => one(T),
                ]),
            ],
            affected = [EntityRef(:variable, variable.value)],
            suggested_actions = [
                "Compare this coordinate with active structural matching and zero-sensitivity evidence.",
                "Inspect the derivative at nearby points before classifying it as a missing equation or expected gauge.",
            ],
        ))
    end
    for vector_index in axes(estimate.right_nullspace, 2)
        vector = view(estimate.right_nullspace, :, vector_index)
        magnitude = maximum(abs, vector; init = zero(T))
        iszero(magnitude) && continue
        local_support = findall(value -> abs(value) >= relative * magnitude, vector)
        2 <= length(local_support) <= min(8, length(vector) - 1) || continue
        support_variables = evaluation.point.variables[local_support]
        weights = abs.(vector[local_support]) ./ magnitude
        push!(findings, Finding(
            :active_candidate_compact_tangent_direction;
            severity = SeverityInfo,
            domain = NumericalIssue,
            basis = HeuristicInterpretation,
            confidence = ConfidenceMedium,
            observation = "A right-null vector of the selected active Jacobian is concentrated on $(length(support_variables)) of $(length(vector)) evaluated coordinates.",
            why_it_matters = "This compact local tangent direction can help localize an unexpected degree of freedom, weakly identified subsystem, or point-specific derivative cancellation. It is not proof of a missing equation or a physical gauge.",
            evidence = [
                _point_evidence(evaluation.point),
                Evidence("Active-set right-nullspace fingerprint"; details = [
                    "vector_index" => vector_index,
                    "variables" => join((variable.value for variable in support_variables), ","),
                    "normalized_support_magnitudes" => join(weights, ","),
                    "relative_support_threshold" => relative,
                ]),
            ],
            affected = EntityRef[
                EntityRef(:variable, variable.value) for variable in support_variables
            ],
            suggested_actions = [
                "Inspect the supported variables together with active-row and structural matching evidence.",
                "Compare nearby points and declared expected modes before assigning a physical interpretation.",
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
    if all_tangent && declared_rank > 0 && estimate.right_nullity > 0
        declared_basis = factorization.U[:, 1:declared_rank]
        residuals = T[]
        for vector_index in axes(estimate.right_nullspace, 2)
            vector = view(estimate.right_nullspace, :, vector_index)
            projection = declared_basis * (transpose(declared_basis) * vector)
            push!(residuals, norm(vector - projection))
        end
        residual_threshold = tolerance
        uncovered = findall(residual -> residual > residual_threshold, residuals)
        if !isempty(uncovered)
            push!(findings, Finding(
                :active_expected_nullspace_span_does_not_cover_observed;
                severity = SeverityWarning,
                domain = NumericalIssue,
                basis = LocalInference,
                confidence = ConfidenceHigh,
                observation = "The declared active expected-mode span does not cover $(length(uncovered)) of $(estimate.right_nullity) observed active nullspace direction(s).",
                why_it_matters = "Individually tangent declarations can still omit observed tangent freedom or span a different subspace. This is point-local numerical evidence, not a refutation of the declarations' physical meaning.",
                evidence = [
                    _point_evidence(evaluation.point),
                    Evidence("Active expected-versus-observed nullspace span"; details = [
                        "modes" => join(names, ","),
                        "declared_span_rank" => declared_rank,
                        "observed_right_nullity" => estimate.right_nullity,
                        "uncovered_vector_indices" => join(uncovered, ","),
                        "projection_residuals" => join(residuals, ","),
                        "residual_tolerance" => residual_threshold,
                    ]),
                ],
                affected = EntityRef[
                    EntityRef(:variable, variable.value) for variable in
                    evaluation.point.variables
                ],
                suggested_actions = [
                    "Inspect compact and single-coordinate active tangent fingerprints for the uncovered directions.",
                    "Add only independently justified expected modes after checking active constraints and nearby points.",
                ],
            ))
        end
    end
    if all_tangent && declared_rank > estimate.right_nullity
        push!(findings, Finding(
            :active_expected_nullspace_span_exceeds_observed;
            severity = SeverityInfo,
            domain = RepresentationalIssue,
            basis = LocalInference,
            confidence = ConfidenceMedium,
            observation = "The declared active expected-mode span has rank $declared_rank, exceeding observed active right nullity $(estimate.right_nullity).",
            why_it_matters = "The declared directions passed the mode-residual check but are not compatible with the numerical nullity under the rank threshold. This usually reflects tolerance semantics, derivative accuracy, or an overbroad declaration rather than a physical conclusion.",
            evidence = [
                _point_evidence(evaluation.point),
                Evidence("Active expected-versus-observed nullspace span"; details = [
                    "modes" => join(names, ","),
                    "declared_span_rank" => declared_rank,
                    "observed_right_nullity" => estimate.right_nullity,
                    "residual_tolerance" => tolerance,
                ]),
            ],
            affected = EntityRef[
                EntityRef(:variable, variable.value) for variable in
                evaluation.point.variables
            ],
            suggested_actions = [
                "Compare expected-mode and numerical-rank tolerances before changing the declaration.",
                "Inspect derivative provenance and active constraints at nearby points.",
            ],
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
    mfcq_support_relative::Real,
    multiplier_support_relative::Real,
)
    0 < mfcq_support_relative <= 1 || throw(ArgumentError(
        "mfcq_support_relative must lie in (0, 1]",
    ))
    0 < multiplier_support_relative <= 1 || throw(ArgumentError(
        "multiplier_support_relative must lie in (0, 1]",
    ))
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
        direction_magnitude = maximum(abs, mfcq.direction; init = zero(eltype(
            mfcq.direction,
        )))
        direction_support = iszero(direction_magnitude) ? Int[] :
                            findall(value -> abs(value) >=
                mfcq_support_relative * direction_magnitude,
                mfcq.direction)
        support_variables = evaluation.point.variables[direction_support]
        normalized_direction = iszero(direction_magnitude) ?
                               eltype(mfcq.direction)[] :
                               abs.(mfcq.direction[direction_support]) ./ direction_magnitude
        maximum_weight = maximum(mfcq.failure_witness_weights; init = zero(eltype(
            mfcq.failure_witness_weights,
        )))
        witness_support = iszero(maximum_weight) ? Int[] : findall(
            weight -> weight >= mfcq_support_relative * maximum_weight,
            mfcq.failure_witness_weights,
        )
        witness_rows = mfcq.inequality_rows[witness_support]
        witness_weights = mfcq.failure_witness_weights[witness_support]
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
                            "equality_derivative_methods" => join(
                                sort(unique(string.(evaluation.jacobian_row_methods[
                                    mfcq.equality_rows,
                                ]))),
                                ",",
                            ),
                            "inequality_derivative_methods" => join(
                                sort(unique(string.(evaluation.jacobian_row_methods[
                                    unique(mfcq.inequality_rows),
                                ]))),
                                ",",
                            ),
                            "largest_directional_derivative" => mfcq.largest_active_inequality_directional_derivative,
                            "material_direction_variables" =>
                                join((variable.value for variable in support_variables), ","),
                            "normalized_direction_magnitudes" =>
                                join(normalized_direction, ","),
                            "relative_support_threshold" => mfcq_support_relative,
                            "convex_hull_weights" =>
                                join(mfcq.failure_witness_weights, ","),
                            "convex_hull_weight_sum" =>
                                sum(mfcq.failure_witness_weights),
                            "material_witness_rows" => join(witness_rows, ","),
                            "material_witness_weights" => join(witness_weights, ","),
                            "projected_gradient_scale" =>
                                mfcq.failure_witness_projected_gradient_scale,
                            "effective_witness_tolerance" =>
                                mfcq.failure_witness_effective_tolerance,
                            "witness_iterations" => mfcq.failure_witness_iterations,
                            "witness_converged" => mfcq.failure_witness_converged,
                        ],
                    ),
                ],
                suggested_actions = [
                    "Treat this as point-local evidence and verify it with a solver or domain-specific feasibility analysis when consequential.",
                ],
                affected = vcat(
                    affected,
                    EntityRef[EntityRef(:variable, variable.value) for
                              variable in support_variables],
                ),
            ),
        )
    end
    if mfcq.available && mfcq.failure_witness_found
        maximum_weight = maximum(mfcq.failure_witness_weights; init = zero(eltype(
            mfcq.failure_witness_weights,
        )))
        support = findall(
            weight -> weight >= mfcq_support_relative * maximum_weight,
            mfcq.failure_witness_weights,
        )
        support_rows = mfcq.inequality_rows[support]
        support_weights = mfcq.failure_witness_weights[support]
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
                            "equality_derivative_methods" => join(
                                sort(unique(string.(evaluation.jacobian_row_methods[
                                    mfcq.equality_rows,
                                ]))),
                                ",",
                            ),
                            "inequality_derivative_methods" => join(
                                sort(unique(string.(evaluation.jacobian_row_methods[
                                    unique(mfcq.inequality_rows),
                                ]))),
                                ",",
                            ),
                            "witness_weights" => join(mfcq.failure_witness_weights, ","),
                            "witness_weight_sum" => sum(mfcq.failure_witness_weights),
                            "material_support_rows" => join(support_rows, ","),
                            "material_support_weights" => join(support_weights, ","),
                            "relative_support_threshold" => mfcq_support_relative,
                            "witness_residual" => mfcq.failure_witness_residual,
                            "projected_gradient_scale" =>
                                mfcq.failure_witness_projected_gradient_scale,
                            "effective_witness_tolerance" =>
                                mfcq.failure_witness_effective_tolerance,
                            "witness_iterations" => mfcq.failure_witness_iterations,
                            "witness_converged" => mfcq.failure_witness_converged,
                        ],
                    ),
                ],
                suggested_actions = [
                    "Inspect opposing or dependent active inequality gradients and vary the documented activity tolerance.",
                    "Repeat with exact derivatives or a solver-specific constraint qualification check before treating this as conclusive.",
                ],
                affected = EntityRef[
                    evaluation.constraint_sources[row] for row in unique(support_rows)
                ],
            ),
        )
    end
    if !mfcq.available
        push!(findings, Finding(
            :mfcq_screen_unavailable;
            severity = SeverityInfo,
            domain = NumericalIssue,
            basis = NumericalObservation,
            confidence = ConfidenceHigh,
            observation = "The MFCQ screen is unavailable for the selected active rows.",
            why_it_matters = "No common-descent or no-descent conclusion is made when the equality-tangent calculation lacks complete finite derivative evidence.",
            evidence = [
                _point_evidence(evaluation.point),
                Evidence("MFCQ screen availability"; details = [
                    "equality_rows" => join(mfcq.equality_rows, ","),
                    "inequality_rows" => join(mfcq.inequality_rows, ","),
                    "equality_jacobian_rank" => mfcq.equality_jacobian_rank,
                    "equality_jacobian_threshold" => mfcq.equality_jacobian_threshold,
                    "reason" => mfcq.reason,
                ]),
            ],
            affected = affected,
            suggested_actions = [
                "Resolve the equality-Jacobian derivative failure before interpreting constraint qualification.",
            ],
        ))
    elseif mfcq.reason == "equality Jacobian is rank deficient"
        push!(findings, Finding(
            :mfcq_equality_jacobian_rank_deficient;
            severity = SeverityWarning,
            domain = NumericalIssue,
            basis = NumericalObservation,
            confidence = ConfidenceHigh,
            observation = "The selected equality Jacobian is rank deficient, so the equality-independence condition of MFCQ fails at this point under the recorded rank tolerance.",
            why_it_matters = "MFCQ requires linearly independent equality gradients before any common-descent inequality test is relevant. This is local derivative evidence, not an exact symbolic certificate.",
            evidence = [
                _point_evidence(evaluation.point),
                Evidence("MFCQ equality-gradient rank"; details = [
                    "equality_rows" => join(mfcq.equality_rows, ","),
                    "inequality_rows" => join(mfcq.inequality_rows, ","),
                    "equality_jacobian_rank" => mfcq.equality_jacobian_rank,
                    "equality_jacobian_threshold" => mfcq.equality_jacobian_threshold,
                    "equality_derivative_methods" => join(
                        sort(unique(string.(evaluation.jacobian_row_methods[
                            mfcq.equality_rows,
                        ]))),
                        ",",
                    ),
                    "reason" => mfcq.reason,
                ]),
            ],
            affected = EntityRef[
                evaluation.constraint_sources[row] for row in mfcq.equality_rows
            ],
            suggested_actions = [
                "Inspect dependent equality gradients and compare the selected rows with structural matching and duplicate-expression findings.",
                "Vary the documented rank tolerance and repeat with exact derivatives before treating the local rank loss as formulation-level degeneracy.",
            ],
        ))
    elseif !mfcq.direction_found && !mfcq.failure_witness_found
        push!(findings, Finding(
            :mfcq_screen_inconclusive;
            severity = SeverityInfo,
            domain = NumericalIssue,
            basis = NumericalObservation,
            confidence = ConfidenceHigh,
            observation = "The MFCQ screen found neither a strict common-descent direction nor a numerical no-common-descent witness.",
            why_it_matters = "The selected active geometry is unresolved under the recorded numerical tolerance and iteration budget. This is not evidence either for or against MFCQ.",
            evidence = [
                _point_evidence(evaluation.point),
                Evidence("MFCQ inconclusive screen"; details = [
                    "equality_rows" => join(mfcq.equality_rows, ","),
                    "inequality_rows" => join(mfcq.inequality_rows, ","),
                    "reason" => mfcq.reason,
                    "largest_directional_derivative" =>
                        mfcq.largest_active_inequality_directional_derivative,
                    "witness_residual" => mfcq.failure_witness_residual,
                    "projected_gradient_scale" =>
                        mfcq.failure_witness_projected_gradient_scale,
                    "effective_witness_tolerance" =>
                        mfcq.failure_witness_effective_tolerance,
                    "witness_iterations" => mfcq.failure_witness_iterations,
                    "witness_converged" => mfcq.failure_witness_converged,
                ]),
            ],
            affected = affected,
            suggested_actions = [
                "Increase the explicit MFCQ witness iteration budget and compare the result.",
                "Check derivative scaling and repeat at nearby points before assigning a constraint-qualification cause.",
            ],
        ))
    end
    if recovery.available && !recovery.unique
        multiplier_magnitude = maximum(abs, recovery.multipliers; init = zero(eltype(
            recovery.multipliers,
        )))
        multiplier_support = iszero(multiplier_magnitude) ? Int[] :
                             findall(
            value -> abs(value) >= multiplier_support_relative * multiplier_magnitude,
            recovery.multipliers,
        )
        support_rows = recovery.rows[multiplier_support]
        support_sides = recovery.sides[multiplier_support]
        support_multipliers = recovery.multipliers[multiplier_support]
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
                        "minimum_norm_multipliers" => join(recovery.multipliers, ","),
                        "material_support_rows" => join(support_rows, ","),
                        "material_support_sides" => join(support_sides, ","),
                        "material_support_multipliers" => join(support_multipliers, ","),
                        "relative_support_threshold" => multiplier_support_relative,
                        "objective_gradient_method" =>
                            evaluation.objective_gradient_method,
                        "stationarity_residual_norm" => recovery.stationarity_residual_norm,
                        "feasible_point" => recovery.feasible_point,
                    ]),
                ],
                suggested_actions = [
                    "Inspect dependent active gradients and compare with the LICQ result.",
                    "Treat returned multiplier values as one minimum-norm representative only.",
                ],
                affected = EntityRef[
                    evaluation.constraint_sources[row] for row in unique(support_rows)
                ],
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
                evidence = [
                    _point_evidence(evaluation.point),
                    Evidence("Local stationarity derivative provenance"; details = [
                        "objective_gradient_method" =>
                            evaluation.objective_gradient_method,
                    ]),
                ],
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
        violating = findall(
            index -> recovery.sides[index] != :equality &&
                     recovery.multipliers[index] < -dual_tolerance,
            eachindex(recovery.multipliers),
        )
        violating_rows = recovery.rows[violating]
        violating_sides = recovery.sides[violating]
        violating_multipliers = recovery.multipliers[violating]
        material_violation = recovery.inequality_dual_violation
        material_violating = findall(
            index -> recovery.sides[index] != :equality &&
                     recovery.multipliers[index] <
                     -multiplier_support_relative * material_violation,
            eachindex(recovery.multipliers),
        )
        material_violating_rows = recovery.rows[material_violating]
        material_violating_sides = recovery.sides[material_violating]
        material_violating_multipliers = recovery.multipliers[material_violating]
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
                        "violating_rows" => join(violating_rows, ","),
                        "violating_sides" => join(violating_sides, ","),
                        "violating_multipliers" => join(violating_multipliers, ","),
                        "material_violating_rows" => join(material_violating_rows, ","),
                        "material_violating_sides" => join(material_violating_sides, ","),
                        "material_violating_multipliers" =>
                            join(material_violating_multipliers, ","),
                        "relative_support_threshold" => multiplier_support_relative,
                        "objective_gradient_method" =>
                            evaluation.objective_gradient_method,
                        "stationarity_residual_norm" => recovery.stationarity_residual_norm,
                    ]),
                ],
                suggested_actions = [
                    "Check whether the point is stationary and whether the selected active sides use the intended sign convention.",
                    "Treat the least-squares multipliers as diagnostics, not solver dual values.",
                ],
                affected = EntityRef[
                    evaluation.constraint_sources[row] for row in unique(violating_rows)
                ],
            ),
        )
    end
    if recovery.available &&
       !isnothing(recovery.complementarity_residual) &&
       recovery.complementarity_residual >
       dual_tolerance * summary.active_tolerance
        activities_by_row = Dict(activity.row => activity for activity in summary.activities)
        complementarity_rows = Int[]
        complementarity_sides = Symbol[]
        complementarity_multipliers = eltype(recovery.multipliers)[]
        complementarity_margins = eltype(recovery.multipliers)[]
        complementarity_products = eltype(recovery.multipliers)[]
        for (row, side, multiplier) in zip(
            recovery.rows, recovery.sides, recovery.multipliers,
        )
            side == :equality && continue
            activity = activities_by_row[row]
            margin = side == :lower ? activity.lower_margin : activity.upper_margin
            isnothing(margin) && continue
            product = abs(multiplier * margin)
            product >= multiplier_support_relative *
                       recovery.complementarity_residual || continue
            push!(complementarity_rows, row)
            push!(complementarity_sides, side)
            push!(complementarity_multipliers, multiplier)
            push!(complementarity_margins, margin)
            push!(complementarity_products, product)
        end
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
                evidence = [
                    _point_evidence(evaluation.point),
                    Evidence("Local multiplier complementarity screen"; details = [
                        "rows" => join(complementarity_rows, ","),
                        "sides" => join(complementarity_sides, ","),
                        "multipliers" => join(complementarity_multipliers, ","),
                        "margins" => join(complementarity_margins, ","),
                        "products" => join(complementarity_products, ","),
                        "relative_support_threshold" => multiplier_support_relative,
                        "objective_gradient_method" =>
                            evaluation.objective_gradient_method,
                    ]),
                ],
                suggested_actions = [
                    "Tighten or vary the active-set tolerance and inspect the corresponding bound margins.",
                ],
                affected = EntityRef[
                    evaluation.constraint_sources[row] for row in unique(complementarity_rows)
                ],
            ),
        )
    end
    return findings
end

function _active_matching_findings(
    model::MOI.ModelLike,
    evaluation::NumericalEvaluation,
    active_matching::ActiveSetStructuralMatching,
)
    if !active_matching.complete
        affected = EntityRef[
            evaluation.constraint_sources[row] for row in active_matching.unmapped_rows
        ]
        return Finding[Finding(
            :active_set_structural_matching_unavailable;
            severity = SeverityInfo,
            domain = RepresentationalIssue,
            basis = LocalInference,
            confidence = ConfidenceHigh,
            observation = "The selected active-set rows cannot be fully aligned with scalar active-set structural nodes$(isnothing(active_matching.reason) ? "." : ": $(active_matching.reason).")",
            why_it_matters = "No active-set matching, structural overdetermination, or structural-versus-numerical tangent conclusion is issued outside the aligned scope.",
            evidence = [
                _point_evidence(evaluation.point),
                Evidence("Active-set structural alignment"; details = [
                    "selected_activity_rows" => join(active_matching.selected_rows, ","),
                    "aligned_activity_rows" => join(active_matching.aligned_rows, ","),
                    "aligned_constraint_nodes" => length(active_matching.selected_constraint_positions),
                    "unmapped_activity_rows" => join(active_matching.unmapped_rows, ","),
                    "reason" => something(active_matching.reason, "unknown alignment limitation"),
                ]),
            ],
            suggested_actions = ["Inspect the unmapped activity rows or provide a plugin-specific structural mapping before interpreting active-set matching."],
            affected = affected,
        )]
    end
    matching = active_matching.matching
    cardinality = matching_cardinality(matching)
    selected_count = length(active_matching.selected_constraint_positions)
    graph = incidence_graph(model; include_variable_domains = true)
    partition = dulmage_mendelsohn(graph; matching = matching)
    blocks = partition.complete ?
             well_determined_blocks(graph; partition = partition) :
             DulmageMendelsohnBlock[]
    findings = Finding[]
    affected_rows = EntityRef[
        evaluation.constraint_sources[row] for row in active_matching.selected_rows
    ]
    evidence = [
        _point_evidence(evaluation.point),
        Evidence("Active-set structural matching"; details = [
            "selected_activity_rows" => join(active_matching.selected_rows, ","),
            "aligned_activity_rows" => join(active_matching.aligned_rows, ","),
            "aligned_constraint_nodes" => selected_count,
            "excluded_nonfree_variable_domain_rows" =>
                length(active_matching.selected_rows) - selected_count,
            "eligible_free_variables" => length(matching.eligible_variable_positions),
            "matching_cardinality" => cardinality,
            "scope" => "only selected ordinary scalar rows; domain rows for non-free variables are excluded; activity is point-local",
        ]),
    ]
    if cardinality < selected_count
        push!(findings, Finding(
            :active_set_structural_overdetermination;
            severity = SeverityWarning,
            domain = MathematicalIssue,
            basis = LocalInference,
            confidence = ConfidenceHigh,
            observation = "The selected active-set incidence pattern matches only $cardinality of $selected_count aligned scalar equation row(s) to free variables.",
            why_it_matters = "After the point-local activity selection, this structural deficiency is consistent with redundant active equations and the LICQ or multiplier non-uniqueness diagnostics.",
            evidence = evidence,
            suggested_actions = [
                "Inspect the selected rows for duplicate or dependent active equations.",
                "Compare this structural screen with the local Jacobian-rank and multiplier-recovery evidence.",
            ],
            affected = affected_rows,
        ))
    end
    if cardinality < length(matching.eligible_variable_positions)
        unmatched = EntityRef[
            _variable_ref(graph.variables[position]) for position in
            matching.eligible_variable_positions if iszero(matching.variable_match[position])
        ]
        push!(findings, Finding(
            :active_set_structural_underdetermination;
            severity = SeverityInfo,
            domain = MathematicalIssue,
            basis = LocalInference,
            confidence = ConfidenceHigh,
            observation = "The selected active-set incidence pattern leaves $(length(unmatched)) eligible free variable(s) unmatched after a maximum matching of cardinality $cardinality.",
            why_it_matters = "This point-local structural freedom can be an intended gauge, an inactive constraint, or a missing equation; numerical tangent analysis is needed to determine whether it persists locally.",
            evidence = evidence,
            suggested_actions = [
                "Inspect unmatched free variables and compare with declared expected modes.",
                "Compare this screen with local Jacobian nullspace and active-set rank evidence.",
            ],
            affected = vcat(affected_rows, unmatched),
        ))
    end
    if partition.complete &&
       (!isempty(partition.underdetermined_variables) ||
        !isempty(partition.underdetermined_constraints))
        region_variables = _variable_position_labels(
            graph, partition.underdetermined_variables,
        )
        region_constraints = _constraint_position_labels(
            graph, partition.underdetermined_constraints,
        )
        push!(findings, Finding(
            :active_set_dm_underdetermined_region;
            severity = SeverityInfo,
            domain = MathematicalIssue,
            basis = LocalInference,
            confidence = ConfidenceHigh,
            observation = "The active-set matching identifies an underdetermined Dulmage–Mendelsohn region with $(length(partition.underdetermined_variables)) free variable(s) and $(length(partition.underdetermined_constraints)) selected row(s).",
            why_it_matters = "The alternating region identifies the coupled scope of the point-local structural freedom; it is more informative than a single unmatched endpoint, but remains conditional on the numerically selected active set.",
            evidence = vcat(evidence, [Evidence("Active-set underdetermined region"; details = [
                "variables" => join(region_variables, ", "),
                "selected_rows" => join(region_constraints, ", "),
            ])]),
            suggested_actions = [
                "Inspect this coupled region for a missing equation, gauge declaration, or inactive constraint.",
                "Compare its variables with the numerical active tangent nullspace.",
            ],
            affected = _structural_affected(
                graph,
                partition.underdetermined_variables,
                partition.underdetermined_constraints,
            ),
        ))
    end
    if partition.complete &&
       (!isempty(partition.overdetermined_variables) ||
        length(partition.overdetermined_constraints) >
        length([position for position in matching.eligible_constraint_positions if
                iszero(matching.constraint_match[position])]))
        region_variables = _variable_position_labels(
            graph, partition.overdetermined_variables,
        )
        region_constraints = _constraint_position_labels(
            graph, partition.overdetermined_constraints,
        )
        push!(findings, Finding(
            :active_set_dm_overdetermined_region;
            severity = SeverityWarning,
            domain = MathematicalIssue,
            basis = LocalInference,
            confidence = ConfidenceHigh,
            observation = "The active-set matching identifies an overdetermined Dulmage–Mendelsohn region with $(length(partition.overdetermined_variables)) free variable(s) and $(length(partition.overdetermined_constraints)) selected row(s).",
            why_it_matters = "The alternating region identifies the coupled scope of structurally competing active rows; numerical dependence and inconsistency still require Jacobian and feasibility evidence.",
            evidence = vcat(evidence, [Evidence("Active-set overdetermined region"; details = [
                "variables" => join(region_variables, ", "),
                "selected_rows" => join(region_constraints, ", "),
            ])]),
            suggested_actions = [
                "Inspect this coupled region for duplicate or redundant active rows.",
                "Compare it with LICQ, multiplier-uniqueness, and feasibility diagnostics.",
            ],
            affected = _structural_affected(
                graph,
                partition.overdetermined_variables,
                partition.overdetermined_constraints,
            ),
        ))
    end
    if length(blocks) > 1
        descriptions = String[]
        affected = EntityRef[]
        for (number, block) in enumerate(blocks)
            variables = _variable_position_labels(graph, block.variable_positions)
            constraints = _constraint_position_labels(graph, block.constraint_positions)
            push!(descriptions,
                "block $number: variables={$(join(variables, ", "))}; selected_rows={$(join(constraints, ", "))}",
            )
            append!(affected, _structural_affected(
                graph, block.variable_positions, block.constraint_positions,
            ))
        end
        unique!(affected)
        push!(findings, Finding(
            :active_set_dm_well_determined_blocks;
            severity = SeverityInfo,
            domain = MathematicalIssue,
            basis = LocalInference,
            confidence = ConfidenceHigh,
            observation = "The selected active-set pattern decomposes into $(length(blocks)) irreducible well-determined blocks.",
            why_it_matters = "Within this activity selection, the blocks provide an inspectable local coupling decomposition for debugging and scaling. It does not prove that objective curvature, inactive rows, or future active-set changes remain block-separable.",
            evidence = vcat(evidence, [Evidence("Active-set well-determined blocks"; details = [
                "block_count" => length(blocks),
                "blocks" => join(descriptions, " | "),
            ])]),
            suggested_actions = [
                "Inspect the smallest or poorly scaled block first when diagnosing local solver behavior.",
                "Compare the block decomposition across nearby active sets before using it for reformulation.",
            ],
            affected = affected,
        ))
    end
    return findings
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
        evaluation, active_matching.aligned_rows, columns,
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
            "aligned_activity_row_count" => length(active_matching.aligned_rows),
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
    elseif observed_nullity < structural_nullity
        push!(findings, Finding(:active_structural_numerical_pattern_inconsistency;
            severity = SeverityWarning, domain = RepresentationalIssue,
            basis = NumericalObservation, confidence = ConfidenceHigh,
            observation = "The active-set numerical tangent nullity $observed_nullity is smaller than the structural prediction $structural_nullity.",
            why_it_matters = "For the same aligned rows and free-variable columns, a Jacobian rank cannot exceed the maximum rank allowed by its structural incidence pattern. This indicates an extraction, alignment, or derivative-pattern inconsistency rather than a mathematical resolution of structural freedom.",
            evidence = evidence,
            affected = affected,
            suggested_actions = [
                "Inspect the row and variable alignment recorded in the evidence.",
                "Check custom-function derivative sparsity and any model-to-MOI bridge transformations.",
            ],
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

function _active_well_determined_block_rank_findings(
    model::MOI.ModelLike,
    evaluation::NumericalEvaluation{T},
    active_matching::ActiveSetStructuralMatching;
    rank_relative_tolerance::Real,
    rank_max_dense_entries::Integer,
    condition_threshold::Real,
    scale_ratio_threshold::Real,
    nullspace_support_relative::Real,
) where {T<:AbstractFloat}
    active_matching.complete || return Finding[]
    graph = incidence_graph(model; include_variable_domains = true)
    partition = dulmage_mendelsohn(
        graph; matching = active_matching.matching,
    )
    blocks = well_determined_blocks(graph; partition = partition)
    length(blocks) > 1 || return Finding[]

    node_positions = Dict(
        _constraint_node_key(node) => position for
        (position, node) in enumerate(graph.constraint_nodes)
    )
    row_by_node = Dict{Int,Int}()
    for row in active_matching.aligned_rows
        position = get(
            node_positions, _entity_ref_key(evaluation.constraint_sources[row]), 0,
        )
        iszero(position) || (row_by_node[position] = row)
    end
    column_by_variable = Dict(
        variable => column for (column, variable) in enumerate(evaluation.point.variables)
    )
    findings = Finding[]
    for (number, block) in enumerate(blocks)
        rows = [get(row_by_node, position, 0) for position in block.constraint_positions]
        variables = MOI.VariableIndex[
            graph.variables[position].index for position in block.variable_positions
        ]
        columns = [get(column_by_variable, variable, 0) for variable in variables]
        if any(iszero, rows) || any(iszero, columns)
            push!(findings, Finding(
                :active_set_block_rank_unavailable;
                severity = SeverityInfo,
                domain = RepresentationalIssue,
                basis = NumericalObservation,
                confidence = ConfidenceHigh,
                observation = "Active-set block $number cannot be fully aligned with numerical Jacobian rows and columns.",
                why_it_matters = "No block-local numerical rank conclusion is made without exactly the structural rows and variables that define the block.",
                evidence = [_point_evidence(evaluation.point)],
                affected = _structural_affected(
                    graph, block.variable_positions, block.constraint_positions,
                ),
                suggested_actions = [
                    "Evaluate every block variable and inspect the selected-row alignment.",
                ],
            ))
            continue
        end
        block_evaluation = _selected_jacobian_submatrix_evaluation(
            evaluation, rows, columns,
        )
        derivative_methods = sort!(unique!(copy(block_evaluation.jacobian_row_methods));
            by = string,
        )
        if length(derivative_methods) > 1
            push!(findings, Finding(
                :active_set_well_determined_block_mixed_derivative_provenance;
                severity = SeverityInfo,
                domain = RepresentationalIssue,
                basis = NumericalObservation,
                confidence = ConfidenceHigh,
                observation = "Active-set block $number combines $(length(derivative_methods)) derivative methods across its selected rows.",
                why_it_matters = "The methods may have different accuracy, sparsity, and failure semantics. This is not an error, but it should remain explicit when interpreting a marginal local rank or conditioning result.",
                evidence = [
                    _point_evidence(evaluation.point),
                    Evidence("Active-set block derivative provenance"; details = [
                        "block" => number,
                        "methods" => join(derivative_methods, ","),
                    ]),
                ],
                affected = _structural_affected(
                    graph, block.variable_positions, block.constraint_positions,
                ),
                suggested_actions = [
                    "Inspect derivative-method provenance before comparing close rank thresholds across blocks.",
                    "Prefer one verified derivative path when reproducing a marginal diagnostic.",
                ],
            ))
        end
        finite_difference_rows = findall(
            ==(:central_finite_difference), block_evaluation.jacobian_row_methods,
        )
        if !isempty(finite_difference_rows)
            push!(findings, Finding(
                :active_set_well_determined_block_finite_difference_derivatives;
                severity = SeverityInfo,
                domain = NumericalIssue,
                basis = NumericalObservation,
                confidence = ConfidenceHigh,
                observation = "Active-set block $number uses complete central finite-difference derivatives for $(length(finite_difference_rows)) selected row(s).",
                why_it_matters = "Local rank, conditioning, and scaling observations for those rows depend on the finite-difference step and evaluation stability. They should be checked against exact or AD derivatives before diagnosing a subtle degeneracy.",
                evidence = [
                    _point_evidence(evaluation.point),
                    Evidence("Active-set block derivative provenance"; details = [
                        "block" => number,
                        "finite_difference_rows" => join(finite_difference_rows, ","),
                        "methods" => join(block_evaluation.jacobian_row_methods, ","),
                    ]),
                ],
                affected = _structural_affected(
                    graph, block.variable_positions, block.constraint_positions,
                ),
                suggested_actions = [
                    "Vary the finite-difference step and compare the local rank conclusion.",
                    "Provide exact or automatic-differentiation derivatives when possible.",
                ],
            ))
        end
        scale_summary = jacobian_scale_summary(block_evaluation)
        if !isempty(scale_summary.zero_rows) || !isempty(scale_summary.zero_columns)
            zero_row_labels = String[
                _constraint_member_label(
                    graph.constraint_nodes[block.constraint_positions[position]],
                ) for position in scale_summary.zero_rows
            ]
            zero_column_labels = String[
                _variable_member_label(
                    graph.variables[block.variable_positions[position]],
                ) for position in scale_summary.zero_columns
            ]
            push!(findings, Finding(
                :active_set_well_determined_block_zero_sensitivities;
                severity = SeverityWarning,
                domain = NumericalIssue,
                basis = NumericalObservation,
                confidence = ConfidenceHigh,
                observation = "Active-set block $number has $(length(scale_summary.zero_rows)) zero Jacobian row(s) and $(length(scale_summary.zero_columns)) zero Jacobian column(s).",
                why_it_matters = "A structurally present active equation or coordinate is locally invisible to first-order linearization. This can arise at stationary nonlinear expressions, derivative cancellation, or an incomplete derivative source.",
                evidence = [
                    _point_evidence(evaluation.point),
                    Evidence("Active-set block zero sensitivities"; details = [
                        "block" => number,
                        "zero_rows" => join(zero_row_labels, ", "),
                        "zero_columns" => join(zero_column_labels, ", "),
                        "derivative_methods" =>
                            join(block_evaluation.jacobian_row_methods, ","),
                    ]),
                ],
                affected = _structural_affected(
                    graph, block.variable_positions, block.constraint_positions,
                ),
                suggested_actions = [
                    "Inspect the expression and derivative at this operating point.",
                    "Compare nearby points and second-order evidence before calling the row redundant.",
                ],
            ))
        end
        if (!isnothing(scale_summary.row_scale_ratio) &&
            scale_summary.row_scale_ratio >= scale_ratio_threshold) ||
           (!isnothing(scale_summary.column_scale_ratio) &&
            scale_summary.column_scale_ratio >= scale_ratio_threshold)
            row_labels = String[
                _constraint_member_label(graph.constraint_nodes[position]) for
                position in block.constraint_positions
            ]
            column_labels = String[
                _variable_member_label(graph.variables[position]) for
                position in block.variable_positions
            ]
            row_positive = findall(norm -> isfinite(norm) && norm > zero(norm),
                scale_summary.row_norms)
            column_positive = findall(norm -> isfinite(norm) && norm > zero(norm),
                scale_summary.column_norms)
            row_smallest = isempty(row_positive) ? nothing :
                           row_positive[argmin(scale_summary.row_norms[row_positive])]
            row_largest = isempty(row_positive) ? nothing :
                          row_positive[argmax(scale_summary.row_norms[row_positive])]
            column_smallest = isempty(column_positive) ? nothing :
                              column_positive[argmin(scale_summary.column_norms[column_positive])]
            column_largest = isempty(column_positive) ? nothing :
                             column_positive[argmax(scale_summary.column_norms[column_positive])]
            push!(findings, Finding(
                :active_set_well_determined_block_scale_spread;
                severity = SeverityWarning,
                domain = NumericalIssue,
                basis = NumericalObservation,
                confidence = ConfidenceHigh,
                observation = "Active-set block $number has large local Jacobian $(scale_summary.norm)-norm scale spread.",
                why_it_matters = "Constraint-row and variable-column derivative scales inside one coupled block can distort local step computation and feasibility/tolerance semantics even when global averages hide the issue.",
                evidence = [
                    _point_evidence(evaluation.point),
                    Evidence("Active-set block scale summary"; details = [
                        "block" => number,
                        "row_scale_ratio" => scale_summary.row_scale_ratio,
                        "column_scale_ratio" => scale_summary.column_scale_ratio,
                        "smallest_positive_row" =>
                            isnothing(row_smallest) ? "unavailable" : row_labels[row_smallest],
                        "largest_finite_row" =>
                            isnothing(row_largest) ? "unavailable" : row_labels[row_largest],
                        "smallest_positive_column" =>
                            isnothing(column_smallest) ? "unavailable" : column_labels[column_smallest],
                        "largest_finite_column" =>
                            isnothing(column_largest) ? "unavailable" : column_labels[column_largest],
                        "threshold" => scale_ratio_threshold,
                    ]),
                ],
                affected = _structural_affected(
                    graph, block.variable_positions, block.constraint_positions,
                ),
                suggested_actions = [
                    "Inspect constraint units and characteristic residual magnitudes within this block.",
                    "Inspect coordinate units and choose explicit scaling with documented tolerance semantics.",
                ],
            ))
        end
        estimate = jacobian_rank_estimate(
            block_evaluation;
            relative_tolerance = rank_relative_tolerance,
            max_dense_entries = rank_max_dense_entries,
            compute_vectors = false,
        )
        estimate.available || begin
            push!(findings, Finding(
                :active_set_block_rank_unavailable;
                severity = SeverityInfo,
                domain = NumericalIssue,
                basis = NumericalObservation,
                confidence = ConfidenceHigh,
                observation = "Numerical rank estimation is unavailable for active-set block $number.",
                why_it_matters = "The structurally well-determined block cannot yet be checked for local derivative rank loss.",
                evidence = [
                    _point_evidence(evaluation.point),
                    Evidence("Active-set block rank"; details = [
                        "block" => number,
                        "reason" => estimate.reason,
                    ]),
                ],
                affected = _structural_affected(
                    graph, block.variable_positions, block.constraint_positions,
                ),
                suggested_actions = [
                    "Resolve derivative availability or adjust the documented rank guard.",
                ],
            ))
            continue
        end
        if estimate.rank < length(columns)
            scaled = jacobian_rank_estimate(
                _selected_jacobian_submatrix_evaluation(evaluation, rows, columns);
                scaling = :row_column,
                relative_tolerance = rank_relative_tolerance,
                max_dense_entries = rank_max_dense_entries,
                compute_vectors = false,
            )
            scaling_resolves_rank = scaled.available &&
                                    scaled.rank == length(columns)
            push!(findings, Finding(
                scaling_resolves_rank ?
                :active_set_well_determined_block_rank_scaling_sensitive :
                :active_set_well_determined_block_rank_loss;
                severity = SeverityWarning,
                domain = NumericalIssue,
                basis = NumericalObservation,
                confidence = ConfidenceHigh,
                observation = scaling_resolves_rank ?
                              "Structurally well-determined active-set block $number has unscaled numerical Jacobian rank $(estimate.rank), but row/column scaling gives full rank $(scaled.rank)." :
                              "Structurally well-determined active-set block $number has numerical Jacobian rank $(estimate.rank) for $(length(columns)) variables.",
                why_it_matters = scaling_resolves_rank ?
                                 "The local rank conclusion depends on scaling and tolerance semantics. This is not robust evidence of a mathematical degree of freedom or physical singularity." :
                                 "This localizes active rank loss to an otherwise square structural block, consistent with derivative cancellation, a singular operating point, poor coordinates, or a physical bifurcation.",
                evidence = [
                    _point_evidence(evaluation.point),
                    Evidence("Active-set block rank"; details = [
                        "block" => number,
                        "row_count" => length(rows),
                        "variable_count" => length(columns),
                        "numerical_rank" => estimate.rank,
                        "numerical_right_nullity" => estimate.right_nullity,
                        "row_column_scaled_rank" =>
                            scaled.available ? scaled.rank : "unavailable",
                    ]),
                ],
                affected = _structural_affected(
                    graph, block.variable_positions, block.constraint_positions,
                ),
                suggested_actions = [
                    scaling_resolves_rank ?
                    "Record explicit scaling and tolerance semantics before interpreting this rank loss." :
                    "Inspect this block's derivative scale and nullspace directions at nearby points.",
                    scaling_resolves_rank ?
                    "Compare unscaled and scaled singular spectra before treating the direction as a gauge." :
                    "Compare with primitive-domain and expected-mode diagnostics before assigning a physical cause.",
                ],
            ))
            if !scaling_resolves_rank
                vector_estimate = jacobian_rank_estimate(
                    block_evaluation;
                    relative_tolerance = rank_relative_tolerance,
                    max_dense_entries = rank_max_dense_entries,
                    compute_vectors = true,
                )
                for vector_index in axes(vector_estimate.right_nullspace, 2)
                    vector = view(vector_estimate.right_nullspace, :, vector_index)
                    magnitude = maximum(abs, vector; init = zero(T))
                    iszero(magnitude) && continue
                    support = findall(value -> abs(value) >=
                        T(nullspace_support_relative) * magnitude, vector)
                    support_variables = variables[support]
                    support_weights = abs.(vector[support]) ./ magnitude
                    push!(findings, Finding(
                        :active_set_well_determined_block_nullspace_support;
                        severity = SeverityInfo,
                        domain = NumericalIssue,
                        basis = NumericalObservation,
                        confidence = ConfidenceHigh,
                        observation = "A locally rank-deficient active-set block $number has right-null direction $vector_index supported on $(length(support_variables)) coordinate(s).",
                        why_it_matters = "The support localizes the observed loss of derivative rank within a structurally square block. It may reflect cancellation, poor coordinates, a singular operating point, or an expected mode; it is not classified automatically.",
                        evidence = [
                            _point_evidence(evaluation.point),
                            Evidence("Active-set block right-nullspace support"; details = [
                                "block" => number,
                                "vector_index" => vector_index,
                                "support_variables" => join(
                                    (_variable_member_label(graph.variables[
                                        block.variable_positions[position]
                                    ]) for position in support), ", ",
                                ),
                                "normalized_support_magnitudes" =>
                                    join(support_weights, ","),
                                "relative_support_threshold" => nullspace_support_relative,
                            ]),
                        ],
                        affected = vcat(
                            _structural_affected(
                                graph, Int[], block.constraint_positions,
                            ),
                            EntityRef[EntityRef(:variable, variable.value) for
                                      variable in support_variables],
                        ),
                        suggested_actions = [
                            "Compare this support with expected modes and primitive-domain diagnostics.",
                            "Re-evaluate nearby points before assigning a physical interpretation.",
                        ],
                    ))
                end
            end
            continue
        end
        isnothing(estimate.condition_estimate) && continue
        estimate.condition_estimate < condition_threshold && continue
        scaled = jacobian_rank_estimate(
            _selected_jacobian_submatrix_evaluation(evaluation, rows, columns);
            scaling = :row_column,
            relative_tolerance = rank_relative_tolerance,
            max_dense_entries = rank_max_dense_entries,
            compute_vectors = false,
        )
        scaled_condition = scaled.available ? scaled.condition_estimate : nothing
        scaling_resolves = !isnothing(scaled_condition) &&
                           scaled.rank == length(columns) &&
                           scaled_condition < condition_threshold
        push!(findings, Finding(
            scaling_resolves ?
            :active_set_well_determined_block_conditioning_scaling_sensitive :
            :active_set_well_determined_block_ill_conditioned;
            severity = SeverityWarning,
            domain = NumericalIssue,
            basis = NumericalObservation,
            confidence = ConfidenceHigh,
            observation = scaling_resolves ?
                          "Full-rank active-set block $number has unscaled Jacobian condition estimate $(estimate.condition_estimate), but row/column scaling reduces it to $scaled_condition." :
                          "Full-rank active-set block $number has unscaled Jacobian condition estimate $(estimate.condition_estimate), exceeding $condition_threshold.",
            why_it_matters = scaling_resolves ?
                             "The block's conditioning is strongly scale-sensitive. This is numerical evidence about coordinates or units, not intrinsic rank loss or a physical singularity." :
                             "This local block is structurally determined but remains poorly conditioned after the available scaling comparison. It may produce fragile Newton/KKT steps; this still does not establish a modeling error or physical singularity.",
            evidence = [
                _point_evidence(evaluation.point),
                Evidence("Active-set block conditioning"; details = [
                    "block" => number,
                    "unscaled_condition_estimate" => estimate.condition_estimate,
                    "row_column_scaled_condition_estimate" => scaled_condition,
                    "row_column_scaled_rank" => scaled.available ? scaled.rank : "unavailable",
                    "threshold" => condition_threshold,
                    "row_count" => length(rows),
                    "variable_count" => length(columns),
                ]),
            ],
            affected = _structural_affected(
                graph, block.variable_positions, block.constraint_positions,
            ),
            suggested_actions = [
                "Inspect units, coordinate scaling, and coefficient magnitudes in this block.",
                scaling_resolves ?
                "Use explicit, documented scaling and preserve the corresponding tolerance semantics." :
                "Compare nearby points and formulation alternatives before attributing the issue to intrinsic physics.",
            ],
        ))
    end
    return findings
end

function _active_overdetermined_region_left_nullspace_findings(
    model::MOI.ModelLike,
    evaluation::NumericalEvaluation{T},
    active_matching::ActiveSetStructuralMatching;
    rank_relative_tolerance::Real,
    rank_max_dense_entries::Integer,
    nullspace_support_relative::Real,
) where {T<:AbstractFloat}
    active_matching.complete || return Finding[]
    graph = incidence_graph(model; include_variable_domains = true)
    partition = dulmage_mendelsohn(graph; matching = active_matching.matching)
    partition.complete && !isempty(partition.overdetermined_constraints) ||
        return Finding[]
    node_positions = Dict(
        _constraint_node_key(node) => position for
        (position, node) in enumerate(graph.constraint_nodes)
    )
    row_by_node = Dict{Int,Int}()
    for row in active_matching.aligned_rows
        position = get(
            node_positions, _entity_ref_key(evaluation.constraint_sources[row]), 0,
        )
        iszero(position) || (row_by_node[position] = row)
    end
    rows = [get(row_by_node, position, 0) for position in
            partition.overdetermined_constraints]
    variables = MOI.VariableIndex[
        graph.variables[position].index for position in
        partition.overdetermined_variables
    ]
    column_by_variable = Dict(
        variable => column for (column, variable) in enumerate(evaluation.point.variables)
    )
    columns = [get(column_by_variable, variable, 0) for variable in variables]
    (any(iszero, rows) || any(iszero, columns)) && return Finding[]
    estimate = jacobian_rank_estimate(
        _selected_jacobian_submatrix_evaluation(evaluation, rows, columns);
        relative_tolerance = rank_relative_tolerance,
        max_dense_entries = rank_max_dense_entries,
        compute_vectors = true,
    )
    estimate.available && estimate.left_nullity > 0 || return Finding[]
    findings = Finding[]
    structural_rank = count(
        !iszero,
        active_matching.matching.constraint_match[
            partition.overdetermined_constraints
        ],
    )
    structural_left_nullity = length(rows) - structural_rank
    if estimate.left_nullity > structural_left_nullity
        push!(findings, Finding(
            :active_set_dm_overdetermined_region_additional_left_nullity;
            severity = SeverityWarning,
            domain = NumericalIssue,
            basis = NumericalObservation,
            confidence = ConfidenceHigh,
            observation = "Active-set overdetermined region has numerical left nullity $(estimate.left_nullity), exceeding structural left nullity $structural_left_nullity.",
            why_it_matters = "The selected pattern already contains structurally competing rows, but the local Jacobian has additional dependence within the same region. This can be caused by derivative cancellation, a singular operating point, or scale-sensitive rank classification.",
            evidence = [
                _point_evidence(evaluation.point),
                Evidence("Active-set overdetermined-region rank comparison"; details = [
                    "structural_matching_rank" => structural_rank,
                    "structural_left_nullity" => structural_left_nullity,
                    "numerical_rank" => estimate.rank,
                    "numerical_left_nullity" => estimate.left_nullity,
                ]),
            ],
            affected = _structural_affected(
                graph,
                partition.overdetermined_variables,
                partition.overdetermined_constraints,
            ),
            suggested_actions = [
                "Inspect derivative values and left-nullspace support in this region.",
                "Compare nearby points and scaling before treating all rows as redundant.",
            ],
        ))
    end
    for vector_index in axes(estimate.left_nullspace, 2)
        vector = view(estimate.left_nullspace, :, vector_index)
        magnitude = maximum(abs, vector; init = zero(T))
        iszero(magnitude) && continue
        support = findall(value -> abs(value) >=
            T(nullspace_support_relative) * magnitude, vector)
        support_rows = rows[support]
        weights = abs.(vector[support]) ./ magnitude
        push!(findings, Finding(
            :active_set_dm_overdetermined_region_left_nullspace_support;
            severity = SeverityWarning,
            domain = NumericalIssue,
            basis = NumericalObservation,
            confidence = ConfidenceHigh,
            observation = "Active-set overdetermined region has left-null direction $vector_index supported on $(length(support_rows)) selected row(s).",
            why_it_matters = "This localizes numerically dependent active gradients inside the structurally overdetermined region. It can reflect redundancy, derivative cancellation, or the chosen active-set tolerance; it is not an infeasibility proof.",
            evidence = [
                _point_evidence(evaluation.point),
                Evidence("Active-set overdetermined-region left-nullspace support"; details = [
                    "vector_index" => vector_index,
                    "active_rows" => join(support_rows, ","),
                    "normalized_support_magnitudes" => join(weights, ","),
                    "relative_support_threshold" => nullspace_support_relative,
                ]),
            ],
            affected = EntityRef[
                evaluation.constraint_sources[row] for row in support_rows
            ],
            suggested_actions = [
                "Compare this row cluster with duplicate-expression and multiplier-uniqueness evidence.",
                "Vary the active tolerance and re-evaluate nearby points before treating the rows as redundant.",
            ],
        ))
    end
    return findings
end

function _active_underdetermined_region_right_nullspace_findings(
    model::MOI.ModelLike,
    evaluation::NumericalEvaluation{T},
    active_matching::ActiveSetStructuralMatching;
    rank_relative_tolerance::Real,
    rank_max_dense_entries::Integer,
    nullspace_support_relative::Real,
) where {T<:AbstractFloat}
    active_matching.complete || return Finding[]
    graph = incidence_graph(model; include_variable_domains = true)
    partition = dulmage_mendelsohn(graph; matching = active_matching.matching)
    partition.complete && !isempty(partition.underdetermined_variables) ||
        return Finding[]
    node_positions = Dict(
        _constraint_node_key(node) => position for
        (position, node) in enumerate(graph.constraint_nodes)
    )
    row_by_node = Dict{Int,Int}()
    for row in active_matching.aligned_rows
        position = get(
            node_positions, _entity_ref_key(evaluation.constraint_sources[row]), 0,
        )
        iszero(position) || (row_by_node[position] = row)
    end
    rows = [get(row_by_node, position, 0) for position in
            partition.underdetermined_constraints]
    variables = MOI.VariableIndex[
        graph.variables[position].index for position in
        partition.underdetermined_variables
    ]
    column_by_variable = Dict(
        variable => column for (column, variable) in enumerate(evaluation.point.variables)
    )
    columns = [get(column_by_variable, variable, 0) for variable in variables]
    (any(iszero, rows) || any(iszero, columns)) && return Finding[]
    estimate = jacobian_rank_estimate(
        _selected_jacobian_submatrix_evaluation(evaluation, rows, columns);
        relative_tolerance = rank_relative_tolerance,
        max_dense_entries = rank_max_dense_entries,
        compute_vectors = true,
    )
    estimate.available && estimate.right_nullity > 0 || return Finding[]
    findings = Finding[]
    structural_rank = count(
        !iszero,
        active_matching.matching.constraint_match[
            partition.underdetermined_constraints
        ],
    )
    structural_nullity = length(variables) - structural_rank
    if estimate.right_nullity > structural_nullity
        push!(findings, Finding(
            :active_set_dm_underdetermined_region_additional_rank_loss;
            severity = SeverityWarning,
            domain = NumericalIssue,
            basis = NumericalObservation,
            confidence = ConfidenceHigh,
            observation = "Active-set underdetermined region has numerical right nullity $(estimate.right_nullity), exceeding structural nullity $structural_nullity.",
            why_it_matters = "The selected incidence pattern already predicts structural freedom, but the local Jacobian loses additional rank within the same region. This can indicate derivative cancellation, a singular operating point, poor coordinates, or a physical singularity.",
            evidence = [
                _point_evidence(evaluation.point),
                Evidence("Active-set underdetermined-region rank comparison"; details = [
                    "structural_matching_rank" => structural_rank,
                    "structural_right_nullity" => structural_nullity,
                    "numerical_rank" => estimate.rank,
                    "numerical_right_nullity" => estimate.right_nullity,
                ]),
            ],
            affected = _structural_affected(
                graph,
                partition.underdetermined_variables,
                partition.underdetermined_constraints,
            ),
            suggested_actions = [
                "Inspect local nullspace support and derivative values in this region.",
                "Compare nearby points and scaling before assigning a physical cause.",
            ],
        ))
    end
    for vector_index in axes(estimate.right_nullspace, 2)
        vector = view(estimate.right_nullspace, :, vector_index)
        magnitude = maximum(abs, vector; init = zero(T))
        iszero(magnitude) && continue
        support = findall(value -> abs(value) >=
            T(nullspace_support_relative) * magnitude, vector)
        support_variables = variables[support]
        weights = abs.(vector[support]) ./ magnitude
        push!(findings, Finding(
            :active_set_dm_underdetermined_region_right_nullspace_support;
            severity = SeverityInfo,
            domain = NumericalIssue,
            basis = NumericalObservation,
            confidence = ConfidenceHigh,
            observation = "Active-set underdetermined region has right-null direction $vector_index supported on $(length(support_variables)) coordinate(s).",
            why_it_matters = "This localizes the observed tangent freedom within the structurally underdetermined region. It can be an intended gauge, inactive equation, missing equation, or a point-specific derivative effect; semantics are required to classify it.",
            evidence = [
                _point_evidence(evaluation.point),
                Evidence("Active-set underdetermined-region right-nullspace support"; details = [
                    "vector_index" => vector_index,
                    "variables" => join((variable.value for variable in support_variables), ","),
                    "normalized_support_magnitudes" => join(weights, ","),
                    "relative_support_threshold" => nullspace_support_relative,
                ]),
            ],
            affected = EntityRef[
                EntityRef(:variable, variable.value) for variable in support_variables
            ],
            suggested_actions = [
                "Compare this support with declared expected modes and domain metadata.",
                "Inspect whether a local inactive or missing equation should constrain these coordinates.",
            ],
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
    elseif activity.set_kind == :norm_one_cone
        return any(abs(value) <= tolerance for value in numeric[2:end])
    elseif activity.set_kind == :norm_infinity_cone
        magnitudes = abs.(numeric[2:end])
        maximum_magnitude = maximum(magnitudes)
        return maximum_magnitude <= tolerance ||
               count(value -> abs(value - maximum_magnitude) <= tolerance, magnitudes) > 1
    elseif activity.set_kind == :norm_cone_one
        return any(abs(value) <= tolerance for value in numeric[2:end])
    elseif activity.set_kind == :norm_cone_infinity
        magnitudes = abs.(numeric[2:end])
        maximum_magnitude = maximum(magnitudes)
        return maximum_magnitude <= tolerance ||
               count(value -> abs(value - maximum_magnitude) <= tolerance, magnitudes) > 1
    elseif activity.set_kind == :norm_cone
        return all(abs(value) <= tolerance for value in numeric[2:end])
    elseif activity.set_kind == :norm_spectral_cone
        return !isnothing(activity.reason)
    elseif activity.set_kind == :norm_nuclear_cone
        return !isnothing(activity.reason)
    elseif activity.set_kind == :positive_semidefinite_cone_triangle
        return !isnothing(activity.reason)
    elseif activity.set_kind == :scaled_positive_semidefinite_cone_triangle
        return !isnothing(activity.reason)
    elseif activity.set_kind == :positive_semidefinite_cone_square
        return false
    elseif activity.set_kind == :hermitian_positive_semidefinite_cone_triangle
        return !isnothing(activity.reason)
    elseif activity.set_kind == :scaled_hermitian_positive_semidefinite_cone_triangle
        return !isnothing(activity.reason)
    elseif activity.set_kind == :rootdet_cone_triangle
        return !isnothing(activity.reason)
    elseif activity.set_kind == :scaled_rootdet_cone_triangle
        return !isnothing(activity.reason)
    elseif activity.set_kind in (:power_cone, :dual_power_cone)
        return numeric[1] <= tolerance || numeric[2] <= tolerance ||
               abs(numeric[3]) <= tolerance
    elseif activity.set_kind == :geometric_mean_cone
        return any(value -> value <= tolerance, numeric[2:end])
    elseif activity.set_kind == :relative_entropy_cone
        component_count = (length(numeric) - 1) ÷ 2
        return any(value -> value <= tolerance, numeric[2:end]) || component_count < 1
    end
    return false
end

function _coupled_set_findings(summary::CoupledSetFeasibilitySummary)
    findings = Finding[]
    for activity in summary.activities
        if activity.classification == :unavailable
            unsupported = activity.set_kind == :unsupported_coupled_set
            push!(findings, Finding(
                unsupported ? :coupled_set_semantics_unavailable :
                              :coupled_set_activity_unavailable;
                severity = SeverityInfo,
                domain = unsupported ? RepresentationalIssue : NumericalIssue,
                basis = unsupported ? StructuralProof : NumericalObservation,
                confidence = unsupported ? ConfidenceCertain : ConfidenceHigh,
                observation = unsupported ?
                              "The $(activity.source.set_type) coupled set has no generic feasibility or boundary semantics." :
                              "Coupled-set feasibility or boundary activity is unavailable at this point for $(activity.set_kind).",
                why_it_matters = unsupported ?
                                 "The generic core will not silently scalarize or guess the geometry of an unsupported vector set." :
                                 "No feasibility, smoothness, or qualification conclusion should be drawn from incomplete coupled-set numerical evidence.",
                evidence = [Evidence("Coupled-set availability"; details = [
                    "set_kind" => activity.set_kind,
                    "set_type" => activity.source.set_type,
                    "classification" => activity.classification,
                    "reason" => activity.reason,
                ])],
                affected = [activity.source],
                suggested_actions = unsupported ?
                                    ["Provide a domain-plugin coupled-set activity and tangent hook for this set, or inspect it with a cone-aware solver."] :
                                    ["Resolve missing, non-finite, or out-of-domain vector values before interpreting this coupled constraint."],
            ))
            continue
        end
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
                               (!isnothing(activity.reason) ?
                                "The $(activity.set_kind) constraint is on a boundary (margin $(activity.margin)) whose generic tangent semantics are unavailable." :
                                "The $(activity.set_kind) constraint is on its smooth cone boundary (margin $(activity.margin)).")),
                why_it_matters = violated ?
                                  "The evaluated point is outside this coupled set." :
                                  (nonsmooth_boundary ?
                                   "The cone has no unique scalar boundary normal at this point, so scalar active-row reductions are especially misleading." :
                                   (!isnothing(activity.reason) ?
                                    "The cone boundary includes representation-level geometry that the generic core intentionally does not collapse into one scalar normal." :
                                    "Cone-boundary activity is vector-set geometry and is intentionally not converted into scalar active rows by the generic core.")),
                evidence = [Evidence("Coupled-set feasibility"; details = [
                    "set_kind" => activity.set_kind,
                    "margin" => activity.margin,
                    "feasibility_violation" => activity.feasibility_violation,
                    "feasibility_tolerance" => summary.feasibility_tolerance,
                    "active_tolerance" => summary.active_tolerance,
                    "reason" => activity.reason,
                ])],
                suggested_actions = violated ?
                                    ["Inspect the vector components and use a cone-aware feasibility restoration diagnostic."] :
                                    (nonsmooth_boundary ?
                                     ["Avoid scalarizing this apex or axis boundary; use a cone-aware solver or plugin for tangent interpretation."] :
                                     ["Use a cone-aware solver or plugin before interpreting this boundary as scalar active constraints."]),
                affected = [activity.source],
            ),
        )
        if !violated && !nonsmooth_boundary && !isnothing(activity.reason)
            push!(findings, Finding(
                :coupled_set_boundary_tangent_semantics_unavailable;
                severity = SeverityInfo,
                domain = RepresentationalIssue,
                basis = StructuralProof,
                confidence = ConfidenceCertain,
                observation = "The $(activity.set_kind) boundary has no generic single-normal tangent interpretation.",
                why_it_matters = "Feasibility is known, but the square PSD representation also imposes symmetry equations. Collapsing its geometry to one normal would hide those coupled equalities.",
                evidence = [Evidence("Coupled-set tangent availability"; details = [
                    "set_kind" => activity.set_kind,
                    "reason" => activity.reason,
                ])],
                affected = [activity.source],
                suggested_actions = [
                    "Use the packed-triangle PSD representation or a semidefinite-aware plugin when local qualification geometry is required.",
                ],
            ))
        end
    end
    return findings
end

function _active_coupled_set_scope_findings(summary::CoupledSetFeasibilitySummary)
    relevant = CoupledSetActivity[
        activity for activity in summary.activities if
        activity.classification in (:boundary, :violated, :unavailable)
    ]
    isempty(relevant) && return Finding[]
    sources = EntityRef[activity.source for activity in relevant]
    return [Finding(:scalar_active_set_excludes_coupled_sets;
        severity = SeverityInfo,
        domain = RepresentationalIssue,
        basis = StructuralProof,
        confidence = ConfidenceCertain,
        observation = "Scalar LICQ, MFCQ, and multiplier recovery exclude $(length(relevant)) coupled-set constraint(s) at this point.",
        why_it_matters = "The scalar active-set conclusions remain valid only for aligned ordinary scalar rows. Coupled constraints require the separate cone-aware feasibility and qualification evidence included in this report.",
        evidence = [Evidence("Coupled-set exclusion from scalar active set"; details = [
            "coupled_constraint_count" => length(relevant),
            "sources" => join(("$(source.index):$(source.set_type)" for source in sources), ","),
            "classifications" => join((activity.classification for activity in relevant), ","),
        ])],
        affected = sources,
        suggested_actions = [
            "Use the coupled-set Robinson-CQ findings for supported smooth boundaries.",
            "Do not interpret scalar MFCQ or multiplier recovery as a full conic KKT certificate.",
        ],
    )]
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

"""Whether a vector-output row belongs to the referenced parent constraint."""
function _is_coupled_set_output_row(source::EntityRef, parent::EntityRef)
    return source.kind == parent.kind && source.index == parent.index &&
           source.name == parent.name &&
           source.function_type == parent.function_type &&
           source.set_type == parent.set_type && !isnothing(source.subindex)
end

function _coupled_set_tangent_gradient_findings(
    evaluation::NumericalEvaluation{T},
    summary::CoupledSetFeasibilitySummary{T},
) where {T<:AbstractFloat}
    findings = Finding[]
    for tangent in summary.tangents
        rows = [
            row for (row, source) in enumerate(evaluation.constraint_sources)
            if _is_coupled_set_output_row(source, tangent.source)
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
        derivative_methods = sort(unique(string.(evaluation.jacobian_row_methods[rows])))
        finite_difference_gradient = any(
            method in ("central_finite_difference", "partial_central_finite_difference")
            for method in derivative_methods
        )
        push!(findings, Finding(
            zero_gradient ? :coupled_set_smooth_boundary_tangent_gradient_zero :
                            :coupled_set_smooth_boundary_tangent_gradient_available;
            severity = zero_gradient ? SeverityWarning : SeverityInfo,
            domain = zero_gradient || finite_difference_gradient ? NumericalIssue :
                     RepresentationalIssue,
            basis = zero_gradient ? LocalInference :
                    (finite_difference_gradient ? NumericalObservation : MathematicalProof),
            confidence = finite_difference_gradient ? ConfidenceMedium : ConfidenceHigh,
            observation = zero_gradient ?
                          "The smooth $(tangent.set_kind) boundary normal maps to a zero model-coordinate gradient at this point." :
                          "The smooth $(tangent.set_kind) boundary normal maps to a nonzero model-coordinate gradient at this point.",
            why_it_matters = zero_gradient ?
                             "The coupled constraint is locally stationary in the model coordinates, so even a smooth cone boundary does not supply a regular scalar tangent screen here." :
                             "The gradient is usable as cone-aware local geometry, but it is intentionally not folded into generic scalar LICQ, MFCQ, or multiplier recovery.",
            evidence = [Evidence("Coupled-set tangent gradient"; details = [
                "set_kind" => tangent.set_kind,
                "vector_rows" => join(rows, ","),
                "derivative_methods" => join(derivative_methods, ","),
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
    coupled_set_mapped_tangents(evaluation, summary)

Map each smooth coupled-set output normal through fully available vector-row
derivatives. Omitted tangents are deliberately not interpreted: callers that
need unavailable-reason findings should use `analyze_active_set`.
"""
function coupled_set_mapped_tangents(
    evaluation::NumericalEvaluation{T},
    summary::CoupledSetFeasibilitySummary{T},
) where {T<:AbstractFloat}
    evaluation.point == summary.point ||
        throw(ArgumentError("evaluation and coupled-set summary points differ"))
    mapped = CoupledSetMappedTangent{T}[]
    for tangent in summary.tangents
        rows = [
            row for (row, source) in enumerate(evaluation.constraint_sources)
            if _is_coupled_set_output_row(source, tangent.source)
        ]
        sort!(rows; by = row -> something(evaluation.constraint_sources[row].subindex))
        length(rows) == length(tangent.normal) || continue
        any(row > length(evaluation.jacobian_row_methods) ||
            evaluation.jacobian_row_methods[row] in
            (:unavailable, :partial_central_finite_difference) for row in rows) && continue
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
        complete || continue
        push!(mapped, CoupledSetMappedTangent(
            tangent.source, tangent.set_kind, rows, gradient,
            evaluation.jacobian_row_methods[rows],
        ))
    end
    return mapped
end

function coupled_set_qualification_screen(
    evaluation::NumericalEvaluation{T},
    summary::CoupledSetFeasibilitySummary{T},
    ;
    strict_tolerance::Real = sqrt(eps(T)),
    max_iterations::Integer = 1_000,
) where {T<:AbstractFloat}
    evaluation.point == summary.point ||
        throw(ArgumentError("evaluation and coupled-set summary points differ"))
    strict = convert(T, strict_tolerance)
    strict > zero(T) || throw(ArgumentError("strict_tolerance must be positive"))
    max_iterations > 0 || throw(ArgumentError("max_iterations must be positive"))
    sources = EntityRef[tangent.source for tangent in summary.tangents]
    mapped = coupled_set_mapped_tangents(evaluation, summary)
    isempty(sources) && return CoupledSetQualificationScreen{T}(
        false,
        let unavailable_reasons = unique(String[
            activity.reason for activity in summary.activities if
            activity.classification == :unavailable && !isnothing(activity.reason)
        ])
            isempty(unavailable_reasons) ?
            "no smooth coupled-set boundary tangent is available at this point" :
            "no smooth coupled-set boundary tangent is available; " *
            join(unavailable_reasons, "; ")
        end,
        evaluation.point, sources, false,
        zeros(T, length(evaluation.point.variables)),
        T[], zeros(T, length(evaluation.point.variables)), nothing, nothing, 0, false, Symbol[],
    )
    length(mapped) == length(sources) || return CoupledSetQualificationScreen{T}(
        false, "not every smooth coupled-set boundary tangent has a complete mapped gradient",
        evaluation.point, sources, false,
        zeros(T, length(evaluation.point.variables)),
        T[], zeros(T, length(evaluation.point.variables)), nothing, nothing, 0, false,
        unique(reduce(vcat, (tangent.derivative_methods for tangent in mapped); init = Symbol[])),
    )
    gradients = reduce(vcat, (permutedims(tangent.gradient) for tangent in mapped))
    gradient_scale = maximum(
        (norm(view(gradients, row, :)) for row in axes(gradients, 1));
        init = zero(T),
    )
    tolerance = strict * max(one(T), gradient_scale)
    methods = unique(reduce(
        vcat, (tangent.derivative_methods for tangent in mapped); init = Symbol[],
    ))
    weights, residual, converged, iterations = _minimum_norm_convex_combination(
        gradients;
        max_iterations = max_iterations,
        convergence_tolerance = tolerance,
    )
    normal_combination = transpose(gradients) * weights
    converged || return CoupledSetQualificationScreen{T}(
        false, "minimum-norm cone-normal screen did not converge within its iteration budget",
        evaluation.point, sources, false,
        zeros(T, length(evaluation.point.variables)),
        weights, normal_combination, residual, tolerance, iterations, false, methods,
    )
    magnitude = norm(normal_combination)
    if !isnothing(residual) && residual <= tolerance
        return CoupledSetQualificationScreen{T}(
            true, "mapped smooth-boundary normals have a numerical zero convex-hull combination", evaluation.point,
            sources, false, zeros(T, length(evaluation.point.variables)),
            weights, normal_combination, residual, tolerance, iterations, true, methods,
        )
    end
    iszero(magnitude) && return CoupledSetQualificationScreen{T}(
        false, "minimum-norm cone-normal screen produced a zero direction without a completed zero-combination witness",
        evaluation.point, sources, false,
        zeros(T, length(evaluation.point.variables)),
        weights, normal_combination, residual, tolerance, iterations, true, methods,
    )
    direction = -normal_combination ./ magnitude
    maximum(gradients * direction) < -tolerance || return CoupledSetQualificationScreen{T}(
        false, "cone-normal convex-hull candidate did not pass the strict common-descent check",
        evaluation.point, sources, false,
        zeros(T, length(evaluation.point.variables)),
        weights, normal_combination, residual, tolerance, iterations, true, methods,
    )
    return CoupledSetQualificationScreen{T}(
        true, nothing, evaluation.point, sources, true, direction,
        weights, normal_combination, residual, tolerance, iterations, true, methods,
    )
end

function analyze_coupled_set_qualification(
    evaluation::NumericalEvaluation{T};
    summary::CoupledSetFeasibilitySummary{T},
    strict_tolerance::Real = sqrt(eps(T)),
    max_iterations::Integer = 1_000,
) where {T<:AbstractFloat}
    screen = coupled_set_qualification_screen(
        evaluation, summary;
        strict_tolerance = strict_tolerance,
        max_iterations = max_iterations,
    )
    report = DiagnosticReport()
    append!(report.findings, _coupled_set_findings(summary))
    append!(report.findings, _coupled_set_tangent_findings(summary))
    append!(report.findings, _coupled_set_tangent_gradient_findings(
        evaluation, summary,
    ))
    report.metadata[:stage] = "coupled_set_qualification"
    report.metadata[:evaluation_point_label] = evaluation.point.label
    report.metadata[:coupled_activity_count] = string(length(summary.activities))
    report.metadata[:coupled_activity_complete] = string(summary.complete)
    report.metadata[:coupled_activity_reason] = string(summary.reason)
    report.metadata[:coupled_unavailable_activity_count] = string(count(
        activity -> activity.classification == :unavailable, summary.activities,
    ))
    report.metadata[:coupled_qualification_available] = string(screen.available)
    report.metadata[:coupled_robinson_regular] = string(screen.robinson_regular)
    report.metadata[:coupled_tangent_source_count] = string(length(screen.tangent_sources))
    report.metadata[:coupled_normal_combination_residual] =
        string(screen.combination_residual)
    report.metadata[:coupled_normal_combination_tolerance] = string(screen.tolerance)
    report.metadata[:coupled_normal_combination_iterations] = string(screen.iterations)
    report.metadata[:coupled_normal_combination_converged] = string(screen.converged)
    report.metadata[:coupled_derivative_methods] = join(screen.derivative_methods, ",")
    finite_difference_geometry = :central_finite_difference in screen.derivative_methods
    report.metadata[:coupled_qualification_uses_finite_differences] =
        string(finite_difference_geometry)
    report.metadata[:coupled_qualification_strict_tolerance] = string(strict_tolerance)
    report.metadata[:coupled_qualification_max_iterations] = string(max_iterations)
    code = screen.available && screen.robinson_regular ?
           :coupled_set_robinson_cq_regular :
           screen.available ? :coupled_set_robinson_cq_nonregular :
           :coupled_set_robinson_cq_unavailable
    push!(report, Finding(code;
        # An unavailable conservative screen is an evidence limitation, not a
        # model defect. A completed screen with a zero mapped normal is the
        # case that warrants a warning.
        severity = screen.robinson_regular || !screen.available ?
                   SeverityInfo : SeverityWarning,
        domain = NumericalIssue,
        basis = screen.robinson_regular && !finite_difference_geometry ?
                LocalInference : NumericalObservation,
        confidence = finite_difference_geometry ? ConfidenceMedium : ConfidenceHigh,
        observation = screen.robinson_regular ?
                      (finite_difference_geometry ?
                       "Finite-difference vector derivatives yield a nonzero minimum-norm normal combination and a numerical Robinson-CQ interior-direction witness." :
                       "The smooth coupled boundaries have a nonzero minimum-norm normal combination and a local Robinson-CQ interior-direction witness.") :
                      "Coupled-set Robinson-CQ is $(screen.available ? "nonregular" : "unavailable") at this point.",
        why_it_matters = "This cone-aware result is local and does not alter scalar LICQ/MFCQ or multiplier recovery.",
        evidence = [Evidence("Coupled-set Robinson-CQ screen"; details = [
            "reason" => screen.reason,
            "tangent_source_count" => length(screen.tangent_sources),
            "normal_combination_weights" => join(screen.normal_weights, ","),
            "normal_combination" => join(screen.normal_combination, ","),
            "normal_combination_residual" => screen.combination_residual,
            "normal_combination_tolerance" => screen.tolerance,
            "normal_combination_iterations" => screen.iterations,
            "normal_combination_converged" => screen.converged,
            "derivative_methods" => join(screen.derivative_methods, ","),
            "uses_finite_differences" => finite_difference_geometry,
        ])],
        affected = screen.tangent_sources,
        suggested_actions = ["Inspect the mapped tangent gradients and the local witness direction before drawing KKT conclusions."],
    ))
    if screen.available && !screen.robinson_regular &&
       length(screen.tangent_sources) > 1
        weight_scale = maximum(abs, screen.normal_weights; init = zero(T))
        support_threshold = sqrt(eps(T)) * weight_scale
        support_positions = findall(weight -> abs(weight) > support_threshold,
                                    screen.normal_weights)
        support_sources = screen.tangent_sources[support_positions]
        report.metadata[:coupled_dependent_normal_support_count] =
            string(length(support_sources))
        push!(report, Finding(:coupled_set_dependent_boundary_normals;
            severity = SeverityWarning,
            domain = NumericalIssue,
            basis = NumericalObservation,
            confidence = finite_difference_geometry ? ConfidenceMedium : ConfidenceHigh,
            observation = "$(length(support_sources)) smooth coupled-set boundary normal(s) have a positive numerical dependence at this point.",
            why_it_matters = "A nonnegative combination of the mapped normals is numerically zero, so the screen cannot find a common strict interior direction. This is a cone-aware active-set degeneracy fingerprint, not scalar LICQ evidence.",
            evidence = [Evidence("Dependent coupled boundary normals"; details = [
                "support_positions" => join(support_positions, ","),
                "support_weights" => join(screen.normal_weights[support_positions], ","),
                "support_threshold" => support_threshold,
                "normal_combination_residual" => screen.combination_residual,
                "derivative_methods" => join(screen.derivative_methods, ","),
            ])],
            affected = support_sources,
            suggested_actions = [
                "Inspect the listed cone boundaries for duplicated, opposing, or otherwise dependent local geometry.",
                "Check whether the dependence is an intended physical coupling or a redundant formulation.",
            ],
        ))
    end
    return report
end

"""Build the coupled-set summary, then produce its qualification report."""
function analyze_coupled_set_qualification(
    model::MOI.ModelLike,
    evaluation::NumericalEvaluation{T};
    feasibility_tolerance::Real = sqrt(eps(T)),
    active_tolerance::Real = sqrt(eps(T)),
    strict_tolerance::Real = sqrt(eps(T)),
    max_iterations::Integer = 1_000,
    component_scale_mismatch_factor::Real = 1.0e3,
) where {T<:AbstractFloat}
    summary = coupled_set_feasibility_summary(
        model, evaluation;
        feasibility_tolerance = feasibility_tolerance,
        active_tolerance = active_tolerance,
    )
    report = analyze_coupled_set_qualification(
        evaluation;
        summary = summary,
        strict_tolerance = strict_tolerance,
        max_iterations = max_iterations,
    )
    scale_report = analyze_component_constraint_scales(
        component_constraint_scale_semantics(model), summary;
        mismatch_factor = component_scale_mismatch_factor,
    )
    append!(report.findings, scale_report.findings)
    for (key, value) in scale_report.metadata
        key == :stage && continue
        report.metadata[key] = value
    end
    sort!(report.findings; by = finding -> (-Int(finding.severity), string(finding.code)))
    return report
end

"""
    analyze_coupled_set_qualification(model, point; cache, relative_step, ...)

Evaluate a point and produce the separate cone-aware qualification report.
This convenience path preserves the point label on every resulting finding.
"""
function analyze_coupled_set_qualification(
    model::MOI.ModelLike,
    point::EvaluationPoint;
    cache::EvaluationCache = EvaluationCache(),
    relative_step::Real = cbrt(eps(eltype(point.values))),
    kwargs...,
)
    evaluation = evaluate_numerical(
        model, point;
        cache = cache,
        relative_step = relative_step,
    )
    return analyze_coupled_set_qualification(model, evaluation; kwargs...)
end

"""Evaluate `values` and produce the separate cone-aware qualification report."""
function analyze_coupled_set_qualification(
    model::MOI.ModelLike,
    values::Union{AbstractVector{<:Real},AbstractDict{MOI.VariableIndex,<:Real}};
    label::AbstractString = "user",
    kwargs...,
)
    return analyze_coupled_set_qualification(
        model,
        evaluation_point(model, values; label = label);
        kwargs...,
    )
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
    block_condition_threshold::Real = 1.0e10,
    block_scale_ratio_threshold::Real = 1.0e6,
    mfcq_strict_tolerance::Real = sqrt(eps(T)),
    mfcq_witness_tolerance::Real = sqrt(eps(T)),
    mfcq_witness_relative_tolerance::Real = 0.0,
    mfcq_witness_max_iterations::Integer = 1_000,
    coupled_qualification_strict_tolerance::Real = sqrt(eps(T)),
    coupled_qualification_max_iterations::Integer = 1_000,
    component_scale_mismatch_factor::Real = 1.0e3,
    mfcq_support_relative::Real = 1.0e-3,
    multiplier_support_relative::Real = 1.0e-3,
    nullspace_support_relative::Real = 0.1,
    expected_modes::AbstractVector{<:ExpectedNullspaceMode} =
        expected_nullspace_modes(model, evaluation),
    include_port_topology_modes::Bool = true,
    expected_mode_residual_tolerance::Real = sqrt(eps(T)),
) where {T<:AbstractFloat}
    _validate_evaluation_variable_order(model, evaluation)
    block_condition_threshold > 1 ||
        throw(ArgumentError("block_condition_threshold must be greater than one"))
    block_scale_ratio_threshold > 1 ||
        throw(ArgumentError("block_scale_ratio_threshold must be greater than one"))
    0 < mfcq_support_relative <= 1 ||
        throw(ArgumentError("mfcq_support_relative must lie in (0, 1]"))
    0 < multiplier_support_relative <= 1 ||
        throw(ArgumentError("multiplier_support_relative must lie in (0, 1]"))
    0 < nullspace_support_relative <= 1 ||
        throw(ArgumentError("nullspace_support_relative must lie in (0, 1]"))
    port_modes = include_port_topology_modes ? port_expected_nullspace_modes(
        component_port_metadata(model),
        component_port_nullspace_modes(model),
        component_port_connections(model),
        component_port_coordinate_maps(model),
    ) : ExpectedNullspaceMode[]
    port_summary = port_expected_nullspace_summary(port_modes)
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
        witness_tolerance = mfcq_witness_tolerance,
        witness_relative_tolerance = mfcq_witness_relative_tolerance,
        witness_max_iterations = mfcq_witness_max_iterations,
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
    active_decomposition = active_set_structural_decomposition(
        model, active_matching,
    )
    coupled_summary = coupled_set_feasibility_summary(
        model,
        evaluation;
        feasibility_tolerance = feasibility_tolerance,
        active_tolerance = active_tolerance,
    )
    report = DiagnosticReport()
    append!(report.findings, _active_derivative_provenance_findings(
        evaluation, selected_rows,
    ))
    append!(report.findings, _active_set_findings(
        evaluation, summary, selected_rows, estimate, mfcq, recovery,
        mfcq_support_relative, multiplier_support_relative,
    ))
    append!(report.findings, _active_left_nullspace_fingerprints(
        evaluation, selected_rows, estimate;
        support_relative = nullspace_support_relative,
    ))
    append!(report.findings, _active_right_nullspace_fingerprints(
        evaluation, estimate; support_relative = nullspace_support_relative,
    ))
    append!(report.findings, _active_expected_nullspace_mode_findings(
        evaluation, selected_rows, all_expected_modes;
        residual_tolerance = expected_mode_residual_tolerance,
    ))
    append!(report.findings, _active_expected_nullspace_span_findings(
        evaluation, selected_rows, estimate, all_expected_modes;
        residual_tolerance = expected_mode_residual_tolerance,
    ))
    append!(report.findings, _active_matching_findings(model, evaluation, active_matching))
    append!(report.findings, _active_well_determined_block_rank_findings(
        model, evaluation, active_matching;
        rank_relative_tolerance = rank_relative_tolerance,
        rank_max_dense_entries = rank_max_dense_entries,
        condition_threshold = block_condition_threshold,
        scale_ratio_threshold = block_scale_ratio_threshold,
        nullspace_support_relative = nullspace_support_relative,
    ))
    append!(report.findings, _active_overdetermined_region_left_nullspace_findings(
        model, evaluation, active_matching;
        rank_relative_tolerance = rank_relative_tolerance,
        rank_max_dense_entries = rank_max_dense_entries,
        nullspace_support_relative = nullspace_support_relative,
    ))
    append!(report.findings, _active_underdetermined_region_right_nullspace_findings(
        model, evaluation, active_matching;
        rank_relative_tolerance = rank_relative_tolerance,
        rank_max_dense_entries = rank_max_dense_entries,
        nullspace_support_relative = nullspace_support_relative,
    ))
    append!(report.findings, _active_structural_numerical_tangent_findings(
        model, evaluation, active_matching;
        rank_relative_tolerance = rank_relative_tolerance,
        rank_max_dense_entries = rank_max_dense_entries,
    ))
    # Coupled-set qualification is deliberately separate from scalar LICQ and
    # MFCQ. Include its conservative result only when the model actually has a
    # coupled constraint, avoiding irrelevant evidence-limit findings for
    # scalar-only NLPs.
    if !isempty(coupled_summary.activities)
        coupled_scale_report = analyze_component_constraint_scales(
            component_constraint_scale_semantics(model), coupled_summary;
            mismatch_factor = component_scale_mismatch_factor,
        )
        append!(report.findings, coupled_scale_report.findings)
        for (key, value) in coupled_scale_report.metadata
            key == :stage && continue
            report.metadata[key] = value
        end
        coupled_qualification_report = analyze_coupled_set_qualification(
            evaluation;
            summary = coupled_summary,
            strict_tolerance = coupled_qualification_strict_tolerance,
            max_iterations = coupled_qualification_max_iterations,
        )
        append!(report.findings, coupled_qualification_report.findings)
        append!(report.findings, _active_coupled_set_scope_findings(coupled_summary))
        report.metadata[:coupled_qualification_available] =
            coupled_qualification_report.metadata[:coupled_qualification_available]
        report.metadata[:coupled_robinson_regular] =
            coupled_qualification_report.metadata[:coupled_robinson_regular]
    end
    report.metadata[:stage] = "active_set"
    report.metadata[:evaluation_point_label] = evaluation.point.label
    report.metadata[:active_rows] = join(selected_rows, ",")
    report.metadata[:active_row_count] = string(length(selected_rows))
    active_methods = evaluation.jacobian_row_methods[selected_rows]
    active_method_counts = Dict{Symbol,Int}()
    for method in active_methods
        active_method_counts[method] = get(active_method_counts, method, 0) + 1
    end
    active_method_pairs = sort!(collect(active_method_counts); by = pair -> string(pair[1]))
    report.metadata[:active_derivative_method_count] =
        string(length(active_method_counts))
    report.metadata[:active_derivative_row_method_counts] = join(
        ("$(method)=$(count)" for (method, count) in active_method_pairs), ",",
    )
    report.metadata[:active_central_finite_difference_row_count] = string(get(
        active_method_counts, :central_finite_difference, 0,
    ))
    report.metadata[:active_partial_finite_difference_row_count] = string(get(
        active_method_counts, :partial_central_finite_difference, 0,
    ))
    report.metadata[:active_jacobian_rank] = string(estimate.rank)
    report.metadata[:active_jacobian_rank_available] = string(estimate.available)
    report.metadata[:active_structural_matching_available] = string(active_matching.complete)
    report.metadata[:active_structural_matching_cardinality] =
        string(matching_cardinality(active_matching.matching))
    report.metadata[:active_structural_aligned_row_count] =
        string(length(active_matching.aligned_rows))
    report.metadata[:active_dm_partition_available] =
        string(!isnothing(active_decomposition.partition))
    report.metadata[:active_dm_well_determined_block_count] =
        string(length(active_decomposition.well_determined_blocks))
    if !isnothing(active_decomposition.partition)
        partition = active_decomposition.partition
        report.metadata[:active_dm_underdetermined_variable_count] =
            string(length(partition.underdetermined_variables))
        report.metadata[:active_dm_underdetermined_row_count] =
            string(length(partition.underdetermined_constraints))
        report.metadata[:active_dm_well_determined_variable_count] =
            string(length(partition.well_determined_variables))
        report.metadata[:active_dm_well_determined_row_count] =
            string(length(partition.well_determined_constraints))
        report.metadata[:active_dm_overdetermined_variable_count] =
            string(length(partition.overdetermined_variables))
        report.metadata[:active_dm_overdetermined_row_count] =
            string(length(partition.overdetermined_constraints))
    end
    report.metadata[:active_expected_nullspace_mode_count] = string(length(expected_modes))
    report.metadata[:active_port_expected_nullspace_mode_count] =
        string(length(port_modes))
    report.metadata[:active_port_expected_nullspace_independent_rank] =
        string(port_summary.rank)
    report.metadata[:active_port_expected_nullspace_relative_tolerance] =
        string(port_summary.relative_tolerance)
    report.metadata[:active_port_component_expected_nullspace_mode_count] =
        string(count(==(:component), port_summary.candidate_origins))
    report.metadata[:active_port_topology_expected_nullspace_mode_count] =
        string(count(==(:topology), port_summary.candidate_origins))
    report.metadata[:active_structural_unmapped_row_count] =
        string(length(active_matching.unmapped_rows))
    report.metadata[:supported_coupled_set_count] = string(length(coupled_summary.activities))
    report.metadata[:mfcq_screen_available] = string(mfcq.available)
    report.metadata[:mfcq_screen_reason] = string(mfcq.reason)
    report.metadata[:mfcq_equality_jacobian_rank] =
        string(mfcq.equality_jacobian_rank)
    report.metadata[:mfcq_equality_jacobian_threshold] =
        string(mfcq.equality_jacobian_threshold)
    report.metadata[:mfcq_common_descent_direction_found] = string(mfcq.direction_found)
    report.metadata[:mfcq_no_common_descent_witness_found] =
        string(mfcq.failure_witness_found)
    report.metadata[:mfcq_no_common_descent_witness_residual] =
        string(mfcq.failure_witness_residual)
    report.metadata[:mfcq_witness_projected_gradient_scale] =
        string(mfcq.failure_witness_projected_gradient_scale)
    report.metadata[:mfcq_witness_effective_tolerance] =
        string(mfcq.failure_witness_effective_tolerance)
    report.metadata[:mfcq_witness_iterations] =
        string(mfcq.failure_witness_iterations)
    report.metadata[:mfcq_witness_converged] =
        string(mfcq.failure_witness_converged)
    report.metadata[:mfcq_strict_tolerance] = string(mfcq_strict_tolerance)
    report.metadata[:mfcq_witness_tolerance] = string(mfcq_witness_tolerance)
    report.metadata[:mfcq_witness_relative_tolerance] =
        string(mfcq_witness_relative_tolerance)
    report.metadata[:mfcq_witness_max_iterations] =
        string(mfcq_witness_max_iterations)
    report.metadata[:mfcq_support_relative] = string(mfcq_support_relative)
    report.metadata[:multiplier_support_relative] =
        string(multiplier_support_relative)
    report.metadata[:nullspace_support_relative] = string(nullspace_support_relative)
    report.metadata[:multiplier_recovery_available] = string(recovery.available)
    report.metadata[:active_multiplier_unique] = string(recovery.unique)
    report.metadata[:active_multiplier_inequality_dual_violation] =
        string(recovery.inequality_dual_violation)
    report.metadata[:active_multiplier_complementarity_residual] =
        string(recovery.complementarity_residual)
    report.metadata[:objective_gradient_method] =
        string(evaluation.objective_gradient_method)
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
    _validate_evaluation_variable_order(model, evaluation)
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
    hessian_methods = sort!(unique!(copy(hessian.methods)); by = string)
    if :finite_difference_function_values in hessian_methods
        push!(report, Finding(
            :active_set_second_order_finite_difference_hessian;
            severity = SeverityInfo,
            domain = NumericalIssue,
            basis = NumericalObservation,
            confidence = ConfidenceHigh,
            observation = "The active-set Lagrangian Hessian uses finite differences of function values.",
            why_it_matters = "Reduced-Hessian inertia and flat-direction observations depend on the second-difference step and function-evaluation stability. This is provenance, not a curvature conclusion.",
            evidence = [
                _point_evidence(evaluation.point),
                Evidence("Active-set second-order derivative provenance"; details = [
                    "hessian_methods" => join(hessian.methods, ","),
                    "hessian_relative_step" => hessian_relative_step,
                    "objective_gradient_method" =>
                        evaluation.objective_gradient_method,
                ]),
            ],
            suggested_actions = [
                "Vary the Hessian finite-difference step and compare reduced-curvature conclusions.",
                "Use an exact or automatic-differentiation Hessian callback when available.",
            ],
        ))
    end
    if length(hessian_methods) > 1
        push!(report, Finding(
            :active_set_second_order_mixed_hessian_provenance;
            severity = SeverityInfo,
            domain = RepresentationalIssue,
            basis = NumericalObservation,
            confidence = ConfidenceHigh,
            observation = "The active-set Lagrangian Hessian combines $(length(hessian_methods)) derivative methods.",
            why_it_matters = "Mixed Hessian paths can have different accuracy and failure semantics. Marginal reduced-Hessian inertia should retain that provenance.",
            evidence = [
                _point_evidence(evaluation.point),
                Evidence("Active-set second-order derivative provenance"; details = [
                    "hessian_methods" => join(hessian_methods, ","),
                    "objective_gradient_method" =>
                        evaluation.objective_gradient_method,
                ]),
            ],
            suggested_actions = [
                "Compare consequential curvature conclusions with one verified Hessian path.",
            ],
        ))
    end
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
