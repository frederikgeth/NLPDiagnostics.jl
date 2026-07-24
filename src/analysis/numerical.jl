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

function _point_evidence(point::EvaluationPoint)
    preview_length = min(length(point.variables), 20)
    variables = point.variables[1:preview_length]
    values = point.values[1:preview_length]
    return Evidence(
        "Numerical evaluation point";
        details = [
            "label" => point.label,
            "variable_count" => length(point.variables),
            "variable_order_preview" =>
                join((variable.value for variable in variables), ","),
            "value_preview" => join(values, ","),
            "preview_truncated" =>
                preview_length < length(point.variables),
        ],
    )
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

"""
    analyze_numerical(model, point; cache, scale_ratio_threshold)

Evaluate values and first derivatives, then produce point-local numerical
findings. No model data is modified.
"""
function analyze_numerical(
    model::MOI.ModelLike,
    point::EvaluationPoint;
    cache::EvaluationCache = EvaluationCache(),
    scale_ratio_threshold::Real = 1.0e6,
    relative_step::Real = cbrt(eps(eltype(point.values))),
    numeric_type::Type{<:AbstractFloat} = eltype(point.values),
    rank_relative_tolerance::Real =
        max(length(point.variables), 1) * eps(eltype(point.values)),
    rank_max_dense_entries::Integer = 4_000_000,
    jacobian_condition_threshold::Real = 1.0e10,
)
    scale_ratio_threshold > 1 ||
        throw(ArgumentError("scale_ratio_threshold must be greater than one"))
    jacobian_condition_threshold > 1 || throw(
        ArgumentError("jacobian_condition_threshold must be greater than one"),
    )
    evaluation = evaluate_numerical(
        model,
        point;
        cache = cache,
        relative_step = relative_step,
    )
    summary = jacobian_scale_summary(evaluation)
    unscaled_rank = jacobian_rank_estimate(
        evaluation;
        scaling = :none,
        relative_tolerance = rank_relative_tolerance,
        max_dense_entries = rank_max_dense_entries,
    )
    scaled_rank = jacobian_rank_estimate(
        evaluation;
        scaling = :row_column,
        relative_tolerance = rank_relative_tolerance,
        max_dense_entries = rank_max_dense_entries,
    )
    sparse_pattern = sparse_jacobian_pattern_estimate(evaluation)
    model_snapshot = snapshot(model)
    report = DiagnosticReport()
    append!(
        report.findings,
        _operating_point_domain_findings(model_snapshot, evaluation),
    )
    append!(
        report.findings,
        _rank_findings(
            evaluation,
            unscaled_rank,
            scaled_rank;
            condition_threshold = jacobian_condition_threshold,
            sparse_pattern = sparse_pattern,
        ),
    )
    append!(report.findings, _nonfinite_value_findings(evaluation))
    append!(report.findings, _evaluation_failure_findings(evaluation))
    derivative_report =
        analyze_derivatives(model_snapshot; point = point)
    expression_report = analyze_expressions(
        model_snapshot;
        point = point,
        numeric_type = numeric_type,
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
    report.metadata[:evaluation_variable_count] =
        string(length(point.variables))
    report.metadata[:evaluated_constraint_row_count] =
        string(length(evaluation.constraint_sources))
    report.metadata[:raw_jacobian_entry_count] =
        string(length(evaluation.jacobian_entries))
    report.metadata[:evaluation_failure_count] =
        string(length(evaluation.failures))
    report.metadata[:jacobian_rank] = string(unscaled_rank.rank)
    report.metadata[:jacobian_rank_scaling] = string(unscaled_rank.scaling)
    report.metadata[:jacobian_rank_available] = string(unscaled_rank.available)
    report.metadata[:sparse_jacobian_pattern_available] =
        string(sparse_pattern.available)
    report.metadata[:sparse_jacobian_pattern_rank_upper_bound] =
        string(sparse_pattern.rank_upper_bound)
    report.metadata[:evaluation_sources] = join(
        unique(string(capability.source) for capability in evaluation.capabilities),
        ",",
    )
    merge!(report.metadata, derivative_report.metadata)
    merge!(report.metadata, expression_report.metadata)
    sort!(
        report.findings;
        by = finding -> (-Int(finding.severity), string(finding.code)),
    )
    return report
end

"""
    analyze_reduced_hessian(evaluation, hessian; active_rows, ...)

Turn an explicit reduced-Hessian calculation into explainable local findings.
`active_rows` is required: feasibility values alone do not establish an active
set or a multiplier convention.
"""
function analyze_reduced_hessian(
    evaluation::NumericalEvaluation,
    hessian::HessianEvaluation;
    active_rows::AbstractVector{<:Integer},
    condition_threshold::Real = 1.0e10,
    kwargs...,
)
    condition_threshold > 1 ||
        throw(ArgumentError("condition_threshold must be greater than one"))
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
