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
) where {T<:AbstractFloat}
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
    report = DiagnosticReport()
    append!(report.findings, _active_set_findings(evaluation, summary, selected_rows, estimate, mfcq, recovery))
    append!(report.findings, _active_matching_findings(evaluation, active_matching))
    report.metadata[:stage] = "active_set"
    report.metadata[:evaluation_point_label] = evaluation.point.label
    report.metadata[:active_rows] = join(selected_rows, ",")
    report.metadata[:active_row_count] = string(length(selected_rows))
    report.metadata[:active_jacobian_rank] = string(estimate.rank)
    report.metadata[:active_jacobian_rank_available] = string(estimate.available)
    report.metadata[:active_structural_matching_available] = string(active_matching.complete)
    report.metadata[:active_structural_matching_cardinality] =
        string(matching_cardinality(active_matching.matching))
    report.metadata[:active_structural_unmapped_row_count] =
        string(length(active_matching.unmapped_rows))
    report.metadata[:mfcq_screen_available] = string(mfcq.available)
    report.metadata[:mfcq_common_descent_direction_found] = string(mfcq.direction_found)
    report.metadata[:multiplier_recovery_available] = string(recovery.available)
    report.metadata[:active_multiplier_unique] = string(recovery.unique)
    sort!(report.findings; by = finding -> (-Int(finding.severity), string(finding.code)))
    return report
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
