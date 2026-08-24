function _directional_crosscheck_directions(
    ::Type{T}, dimension::Integer, count::Integer;
    policy::Symbol = :coordinate_then_dense,
) where {T<:AbstractFloat}
    dimension > 0 || return Vector{Vector{T}}()
    count > 0 || throw(ArgumentError("directional cross-check count must be positive"))
    policy in (:coordinate_then_dense, :dense_deterministic) ||
        throw(ArgumentError(
            "direction policy must be :coordinate_then_dense or :dense_deterministic",
        ))
    directions = Vector{Vector{T}}()
    if policy == :coordinate_then_dense
        for column in 1:min(dimension, count)
            direction = zeros(T, dimension)
            direction[column] = one(T)
            push!(directions, direction)
        end
    end
    while length(directions) < count
        direction_index = length(directions) + 1
        direction = policy == :coordinate_then_dense ? T[
            isodd(index + length(directions)) ? one(T) : -one(T)
            for index in 1:dimension
        ] : T[
            sin(T(index * (direction_index + 1))) +
            cos(T((index + 2) * (2 * direction_index + 1)))
            for index in 1:dimension
        ]
        norm(direction) > zero(T) || throw(ArgumentError(
            "deterministic direction construction produced a zero vector",
        ))
        direction ./= norm(direction)
        push!(directions, direction)
    end
    return directions
end

"""Evaluate scalar constraint values without constructing any derivatives."""
function _directional_crosscheck_constraint_values(
    model::MOI.ModelLike,
    point::EvaluationPoint{T},
) where {T<:AbstractFloat}
    point.variables == MOI.get(model, MOI.ListOfVariableIndices()) ||
        throw(ArgumentError(
            "evaluation-point variable order does not match ListOfVariableIndices",
        ))
    model_snapshot = snapshot(model)
    lookup = _point_lookup(point)
    values = Union{Missing,T}[]
    sources = EntityRef[]
    failures = EvaluationFailure[]

    functions, ordinary_sources = _ordinary_rows(model_snapshot)
    for (function_value, source) in zip(functions, ordinary_sources)
        raw = _safe_value(
            model, function_value, lookup, source, :constraint_value, failures,
        )
        push!(values, _convert_value(T, raw))
        push!(sources, source)
    end

    block = _optional_nlp_block(model)
    if !isnothing(block)
        evaluator = block.evaluator
        capability = evaluator_capabilities(evaluator)
        try
            MOI.initialize(evaluator, copy(capability.requested_features))
            block_values = zeros(T, length(block.constraint_bounds))
            MOI.eval_constraint(evaluator, block_values, copy(point.values))
            append!(values, block_values)
        catch exception
            append!(values, fill(missing, length(block.constraint_bounds)))
            push!(failures, EvaluationFailure(
                :constraint_value,
                :nlp_block,
                EntityRef(:nlp_block, 1; function_type = string(typeof(evaluator))),
                string(typeof(exception)),
                sprint(showerror, exception),
            ))
        end
        append!(sources, [
            _nlp_constraint_ref(row, evaluator)
            for row in eachindex(block.constraint_bounds)
        ])
    end

    for constraint in model_snapshot.constraints
        set = constraint.set_value
        set isa MOI.VectorNonlinearOracle || continue
        source = _constraint_ref(constraint)
        inputs = try
            MOI.Utilities.eval_variables(
                variable -> lookup[variable], model, constraint.function_value,
            )
        catch exception
            push!(failures, EvaluationFailure(
                :oracle_input, :nonlinear_oracle, source,
                string(typeof(exception)), sprint(showerror, exception),
            ))
            append!(values, fill(missing, set.output_dimension))
            append!(sources, [
                _constraint_ref(constraint; row)
                for row in 1:set.output_dimension
            ])
            continue
        end
        oracle_values = zeros(T, set.output_dimension)
        try
            set.eval_f(oracle_values, copy(inputs))
            append!(values, oracle_values)
        catch exception
            append!(values, fill(missing, set.output_dimension))
            push!(failures, EvaluationFailure(
                :constraint_value, :nonlinear_oracle, source,
                string(typeof(exception)), sprint(showerror, exception),
            ))
        end
        append!(sources, [
            _constraint_ref(constraint; row)
            for row in 1:set.output_dimension
        ])
    end
    return (constraint_values = values, constraint_sources = sources,
            failures = failures)
end

function _directional_crosscheck_point(
    point::EvaluationPoint{T},
    direction::AbstractVector{T},
    step::T,
    direction_index::Integer,
    side::Symbol,
    source::AbstractString = "Jacobian directional derivative cross-check",
) where {T<:AbstractFloat}
    values = point.values .+ (side == :plus ? step : -step) .* direction
    return EvaluationPoint(
        point.variables,
        values;
        label = "$(point.label)-directional-crosscheck-$(direction_index)-$(side)",
        provenance = EvaluationPointProvenance(
            PerturbedPoint;
            source = source,
            complete = true,
            metadata = Dict(
                "direction_index" => direction_index,
                "side" => side,
                "step" => step,
                "base_point_fingerprint" => evaluation_point_fingerprint(point),
            ),
        ),
    )
end

"""Return the value when it is finite and numerically available."""
function _finite_crosscheck_value(value)
    return value isa Real && isfinite(value) ? value : nothing
end

"""Build common metadata for a directional derivative cross-check report."""
function _directional_crosscheck_report(
    stage::AbstractString,
    model::MOI.ModelLike,
    evaluation::NumericalEvaluation,
    direction_count::Integer,
    relative_step::Real,
    absolute_tolerance::Real,
    relative_tolerance::Real,
)
    report = DiagnosticReport()
    report.metadata[:stage] = stage
    report.metadata[:model_fingerprint] = model_fingerprint(model)
    report.metadata[:evaluation_point_fingerprint] =
        evaluation_point_fingerprint(evaluation.point)
    report.metadata[:evaluation_source_fingerprint] =
        evaluation_source_fingerprint(evaluation)
    report.metadata[:direction_count_requested] = string(direction_count)
    report.metadata[:relative_step] = string(relative_step)
    report.metadata[:absolute_tolerance] = string(absolute_tolerance)
    report.metadata[:relative_tolerance] = string(relative_tolerance)
    return report
end

function _directional_crosscheck_jacobian(evaluation::NumericalEvaluation{T}) where {T<:AbstractFloat}
    row_count = length(evaluation.constraint_sources)
    column_count = length(evaluation.point.variables)
    matrix = zeros(T, row_count, column_count)
    for entry in evaluation.jacobian_entries
        1 <= entry.row <= row_count || continue
        1 <= entry.column <= column_count || continue
        matrix[entry.row, entry.column] += entry.value
    end
    unavailable = Set(
        row for (row, method) in enumerate(evaluation.jacobian_row_methods) if
        method in (:unavailable, :partial_central_finite_difference)
    )
    return matrix, unavailable
end

function _try_nlp_jacobian_product(
    model::MOI.ModelLike,
    point::EvaluationPoint{T},
    direction::AbstractVector{T},
) where {T<:AbstractFloat}
    block = _optional_nlp_block(model)
    isnothing(block) && return nothing, "no NLPBlock"
    capability = evaluator_capabilities(block.evaluator)
    :JacVec in capability.available_features ||
        return nothing, "NLP evaluator does not advertise :JacVec"
    try
        MOI.initialize(block.evaluator, copy(capability.requested_features))
        values = zeros(T, length(block.constraint_bounds))
        MOI.eval_constraint_jacobian_product(
            block.evaluator,
            values,
            copy(point.values),
            copy(direction),
        )
        return values, "MOI.eval_constraint_jacobian_product"
    catch exception
        return nothing, sprint(showerror, exception)
    end
end

"""
    analyze_jacobian_directional_crosscheck(model, evaluation; kwargs...)

Compare recorded Jacobian products against central finite differences of the
constraint values at deterministic perturbation directions. This is an
independent local consistency screen, not a proof that either derivative path
is correct. Domain failures, non-finite values, and unavailable rows are
retained as explicit limitations rather than converted into zero derivatives.
"""
function analyze_jacobian_directional_crosscheck(
    model::MOI.ModelLike,
    evaluation::NumericalEvaluation{T};
    direction_count::Integer = min(3, max(length(evaluation.point.variables), 1)),
    relative_step::Real = cbrt(eps(T)),
    absolute_tolerance::Real = zero(T),
    relative_tolerance::Real = sqrt(eps(T)),
    row_indices::Union{Nothing,AbstractVector{<:Integer}} = nothing,
    direction_policy::Symbol = :coordinate_then_dense,
    cache::EvaluationCache = EvaluationCache(),
) where {T<:AbstractFloat}
    direction_count > 0 || throw(ArgumentError("direction_count must be positive"))
    relative_step > 0 || throw(ArgumentError("relative_step must be positive"))
    absolute_tolerance >= 0 || throw(ArgumentError("absolute_tolerance must be nonnegative"))
    relative_tolerance >= 0 || throw(ArgumentError("relative_tolerance must be nonnegative"))
    _validate_evaluation_variable_order(model, evaluation)
    direction_policy in (:coordinate_then_dense, :dense_deterministic) ||
        throw(ArgumentError(
            "direction_policy must be :coordinate_then_dense or :dense_deterministic",
        ))

    report = _directional_crosscheck_report(
        "jacobian_directional_crosscheck",
        model,
        evaluation,
        direction_count,
        relative_step,
        absolute_tolerance,
        relative_tolerance,
    )

    row_count = length(evaluation.constraint_sources)
    if row_count == 0
        push!(report, Finding(
            :jacobian_directional_crosscheck_unavailable;
            severity = SeverityInfo,
            domain = RepresentationalIssue,
            basis = NumericalObservation,
            confidence = ConfidenceCertain,
            observation = "No scalar constraint rows are available for a Jacobian directional cross-check.",
            why_it_matters = "A constraint Jacobian consistency check requires at least one evaluated scalar row.",
            evidence = [_point_evidence(evaluation.point)],
            suggested_actions = ["Use the objective-gradient cross-check path or supply a model with scalar constraint rows."],
        ))
        report.metadata[:directions_tested] = "0"
        return report
    end

    selected_rows = if isnothing(row_indices)
        collect(1:row_count)
    else
        unique(Int.(row_indices))
    end
    all(row -> 1 <= row <= row_count, selected_rows) ||
        throw(ArgumentError("row_indices must lie in 1:$row_count"))
    sort!(selected_rows)
    report.metadata[:row_selection] =
        isnothing(row_indices) ? "all" : "explicit"
    report.metadata[:selected_row_count] = string(length(selected_rows))
    report.metadata[:selected_rows] = join(selected_rows, ",")
    selected_method_counts = Dict{Symbol,Int}()
    for row in selected_rows
        method = evaluation.jacobian_row_methods[row]
        selected_method_counts[method] = get(selected_method_counts, method, 0) + 1
    end
    report.metadata[:selected_row_method_counts] = join((
        "$(method)=$(count)" for (method, count) in
        sort!(collect(selected_method_counts); by = pair -> string(first(pair)))
    ), ",")
    report.metadata[:direction_policy] = string(direction_policy)
    if isempty(selected_rows)
        push!(report, Finding(
            :jacobian_directional_crosscheck_no_selected_rows;
            severity = SeverityInfo,
            domain = RepresentationalIssue,
            basis = NumericalObservation,
            confidence = ConfidenceCertain,
            observation = "No Jacobian rows matched the requested directional cross-check selection.",
            why_it_matters = "An empty targeted audit provides no derivative-consistency evidence.",
            evidence = [_point_evidence(evaluation.point)],
            suggested_actions = [
                "Inspect the recorded Jacobian row-method counts and select a nonempty provenance class.",
            ],
        ))
        report.metadata[:directions_tested] = "0"
        report.metadata[:constraint_directional_comparisons] = "0"
        return report
    end

    jacobian, unavailable_rows = _directional_crosscheck_jacobian(evaluation)
    nlp_rows = findall(source -> source.kind == :nlp_constraint, evaluation.constraint_sources)
    nlp_jacvec_advertised = !isnothing(_optional_nlp_block(model)) && any(
        :JacVec in capability.available_features for capability in evaluator_capabilities(model)
    )
    report.metadata[:jacvec_available] = string(nlp_jacvec_advertised)
    scale = max(one(T), maximum(abs, evaluation.point.values; init = zero(T)))
    step = convert(T, relative_step) * scale
    directions = _directional_crosscheck_directions(
        T, length(evaluation.point.variables), direction_count;
        policy = direction_policy,
    )
    mismatches = NamedTuple[]
    domain_limited = NamedTuple[]
    jacvec_sources = Set{String}()
    tested = 0

    for (direction_index, direction) in enumerate(directions)
        plus = nothing
        minus = nothing
        try
            plus = _directional_crosscheck_constraint_values(
                model,
                _directional_crosscheck_point(
                    evaluation.point, direction, step, direction_index, :plus,
                ),
            )
            minus = _directional_crosscheck_constraint_values(
                model,
                _directional_crosscheck_point(
                    evaluation.point, direction, step, direction_index, :minus,
                ),
            )
        catch exception
            push!(domain_limited, (direction = direction_index, row = 0, reason = sprint(showerror, exception)))
            continue
        end
        jacvec, jacvec_source = _try_nlp_jacobian_product(model, evaluation.point, direction)
        push!(jacvec_sources, jacvec_source)
        plus.constraint_sources == evaluation.constraint_sources &&
            minus.constraint_sources == evaluation.constraint_sources || begin
            push!(domain_limited, (
                direction = direction_index,
                row = 0,
                reason = "constraint-value row order changed under perturbation",
            ))
            continue
        end
        for row in selected_rows
            row in unavailable_rows && continue
            plus_value = plus.constraint_values[row]
            minus_value = minus.constraint_values[row]
            if !(plus_value isa Real && minus_value isa Real && isfinite(plus_value) && isfinite(minus_value))
                push!(domain_limited, (direction = direction_index, row = row, reason = "non-finite or unavailable perturbed constraint value"))
                continue
            end
            predicted = dot(view(jacobian, row, :), direction)
            finite_difference = (plus_value - minus_value) / (2 * step)
            isfinite(predicted) && isfinite(finite_difference) || begin
                push!(domain_limited, (direction = direction_index, row = row, reason = "non-finite directional derivative"))
                continue
            end
            tested += 1
            error = abs(predicted - finite_difference)
            scale_value = max(one(T), abs(predicted), abs(finite_difference))
            tolerance = convert(T, absolute_tolerance) +
                        convert(T, relative_tolerance) * scale_value
            error > tolerance && push!(mismatches, (
                direction = direction_index,
                row = row,
                predicted = predicted,
                finite_difference = finite_difference,
                absolute_error = error,
                relative_error = error / scale_value,
                tolerance = tolerance,
            ))
            if !isnothing(jacvec) && row in nlp_rows
                local_row = findfirst(==(row), nlp_rows)
                jacvec_error = abs(jacvec[local_row] - predicted)
                jacvec_scale = max(one(T), abs(jacvec[local_row]), abs(predicted))
                jacvec_tolerance = convert(T, absolute_tolerance) +
                                   convert(T, relative_tolerance) * jacvec_scale
                jacvec_error > jacvec_tolerance && push!(mismatches, (
                    direction = direction_index,
                    row = row,
                    predicted = jacvec[local_row],
                    finite_difference = predicted,
                    absolute_error = jacvec_error,
                    relative_error = jacvec_error / jacvec_scale,
                    tolerance = jacvec_tolerance,
                ))
            end
        end
    end

    report.metadata[:directions_tested] = string(length(directions))
    report.metadata[:constraint_directional_comparisons] = string(tested)
    report.metadata[:mismatch_count] = string(length(mismatches))
    report.metadata[:domain_limited_count] = string(length(domain_limited))
    report.metadata[:jacobian_unavailable_row_count] = string(length(unavailable_rows))
    report.metadata[:jacvec_sources] = join(sort!(collect(jacvec_sources)), ",")
    report.metadata[:maximum_relative_error] = isempty(mismatches) ? "0.0" :
        string(maximum(item.relative_error for item in mismatches))

    if !isempty(mismatches)
        affected = EntityRef[
            evaluation.constraint_sources[item.row] for item in mismatches if item.row > 0
        ]
        push!(report, Finding(
            :jacobian_directional_crosscheck_mismatch;
            severity = SeverityWarning,
            domain = NumericalIssue,
            basis = NumericalObservation,
            confidence = ConfidenceMedium,
            observation = "$(length(mismatches)) Jacobian directional product(s) disagree with central finite differences beyond the declared tolerance.",
            why_it_matters = "The recorded derivative path and nearby constraint values are locally inconsistent. This can reflect an implementation defect, finite-difference truncation or cancellation, a nonsmooth point, or a perturbation crossing an operator domain boundary.",
            evidence = [
                _point_evidence(evaluation.point),
                Evidence("Directional Jacobian cross-check residuals"; details = [
                    "comparison_count" => tested,
                    "mismatch_count" => length(mismatches),
                    "worst_cases" => join((
                        "direction=$(item.direction),row=$(item.row),error=$(item.absolute_error),relative=$(item.relative_error),tolerance=$(item.tolerance)" for item in mismatches[1:min(end, 8)]
                    ), ";"),
                    "jacobian_row_methods" => join(string.(evaluation.jacobian_row_methods), ","),
                ]),
            ],
            suggested_actions = [
                "Repeat with a smaller and larger perturbation step to separate truncation, cancellation, and genuine derivative disagreement.",
                "Inspect operator-domain and nonsmooth findings at both perturbed points before attributing the mismatch to automatic differentiation.",
                "Compare the evaluator derivative source and any finite-difference fallback recorded in the numerical provenance.",
            ],
            affected = unique(affected),
        ))
    elseif tested > 0
        push!(report, Finding(
            :jacobian_directional_crosscheck_consistent;
            severity = SeverityInfo,
            domain = NumericalIssue,
            basis = NumericalObservation,
            confidence = ConfidenceMedium,
            observation = "All $tested tested Jacobian directional products agree with central finite differences within the declared tolerance.",
            why_it_matters = "This is local consistency evidence for the recorded derivative path at the supplied point; it does not prove global differentiability or derivative correctness away from the tested directions.",
            evidence = [_point_evidence(evaluation.point)],
            suggested_actions = ["Repeat across representative solver iterates and domain-safe perturbation scales before relying on the derivative path globally."],
        ))
    end
    if !isempty(domain_limited)
        push!(report, Finding(
            :jacobian_directional_crosscheck_domain_limited;
            severity = SeverityInfo,
            domain = NumericalIssue,
            basis = NumericalObservation,
            confidence = ConfidenceCertain,
            observation = "$(length(domain_limited)) directional Jacobian comparisons were unavailable because a perturbed evaluation was non-finite, failed, or crossed an operator domain boundary.",
            why_it_matters = "A missing finite-difference side cannot be interpreted as a zero derivative or as evidence against the recorded Jacobian.",
            evidence = [Evidence("Directional cross-check availability"; details = [
                "limited_cases" => join((
                    "direction=$(item.direction),row=$(item.row),reason=$(item.reason)" for item in domain_limited[1:min(end, 12)]
                ), ";"),
                "base_point_fingerprint" => evaluation_point_fingerprint(evaluation.point),
            ])],
            suggested_actions = [
                "Choose a complete point with domain margin or reduce the perturbation step.",
                "Retain the limitation as evidence rather than filling the missing side with a synthetic value.",
            ],
        ))
    end
    sort!(report.findings; by = finding -> (-Int(finding.severity), string(finding.code)))
    return report
end

"""
    analyze_objective_gradient_directional_crosscheck(model, evaluation; kwargs...)

Compare a recorded objective gradient with central finite differences of the
objective value at deterministic perturbation directions. This remains a
local numerical consistency screen: finite-difference cancellation,
nonsmoothness, and objective-domain failures are retained as competing
explanations for a mismatch.
"""
function analyze_objective_gradient_directional_crosscheck(
    model::MOI.ModelLike,
    evaluation::NumericalEvaluation{T};
    direction_count::Integer = min(3, max(length(evaluation.point.variables), 1)),
    relative_step::Real = cbrt(eps(T)),
    absolute_tolerance::Real = zero(T),
    relative_tolerance::Real = sqrt(eps(T)),
    cache::EvaluationCache = EvaluationCache(),
) where {T<:AbstractFloat}
    direction_count > 0 || throw(ArgumentError("direction_count must be positive"))
    relative_step > 0 || throw(ArgumentError("relative_step must be positive"))
    absolute_tolerance >= 0 || throw(ArgumentError("absolute_tolerance must be nonnegative"))
    relative_tolerance >= 0 || throw(ArgumentError("relative_tolerance must be nonnegative"))
    _validate_evaluation_variable_order(model, evaluation)
    report = _directional_crosscheck_report(
        "objective_gradient_directional_crosscheck",
        model,
        evaluation,
        direction_count,
        relative_step,
        absolute_tolerance,
        relative_tolerance,
    )

    if isempty(evaluation.objective_gradient) ||
       any(value -> ismissing(value) || !isfinite(value), evaluation.objective_gradient) ||
       isnothing(_finite_crosscheck_value(evaluation.objective_value))
        push!(report, Finding(
            :objective_gradient_directional_crosscheck_unavailable;
            severity = SeverityInfo,
            domain = RepresentationalIssue,
            basis = NumericalObservation,
            confidence = ConfidenceCertain,
            observation = "The objective value or complete finite objective gradient is unavailable at the supplied point.",
            why_it_matters = "A directional objective-gradient cross-check cannot distinguish derivative accuracy from a missing or non-finite base objective.",
            evidence = [_point_evidence(evaluation.point), Evidence("Objective derivative availability"; details = [
                "objective_gradient_method" => evaluation.objective_gradient_method,
                "objective_value_available" => !isnothing(_finite_crosscheck_value(evaluation.objective_value)),
            ])],
            suggested_actions = ["Resolve objective evaluation and derivative-domain failures before requesting a gradient cross-check."],
        ))
        report.metadata[:directions_tested] = "0"
        report.metadata[:objective_directional_comparisons] = "0"
        return report
    end

    scale = max(one(T), maximum(abs, evaluation.point.values; init = zero(T)))
    step = convert(T, relative_step) * scale
    directions = _directional_crosscheck_directions(T, length(evaluation.point.variables), direction_count)
    mismatches = NamedTuple[]
    domain_limited = NamedTuple[]
    tested = 0
    for (direction_index, direction) in enumerate(directions)
        plus = nothing
        minus = nothing
        try
            plus = evaluate_numerical(
                model,
                _directional_crosscheck_point(
                    evaluation.point,
                    direction,
                    step,
                    direction_index,
                    :plus,
                    "Objective-gradient directional derivative cross-check",
                );
                cache = cache,
                relative_step = relative_step,
            )
            minus = evaluate_numerical(
                model,
                _directional_crosscheck_point(
                    evaluation.point,
                    direction,
                    step,
                    direction_index,
                    :minus,
                    "Objective-gradient directional derivative cross-check",
                );
                cache = cache,
                relative_step = relative_step,
            )
        catch exception
            push!(domain_limited, (direction = direction_index, reason = sprint(showerror, exception)))
            continue
        end
        plus_value = _finite_crosscheck_value(plus.objective_value)
        minus_value = _finite_crosscheck_value(minus.objective_value)
        if isnothing(plus_value) || isnothing(minus_value)
            push!(domain_limited, (direction = direction_index, reason = "non-finite or unavailable perturbed objective value"))
            continue
        end
        predicted = dot(evaluation.objective_gradient, direction)
        finite_difference = (plus_value - minus_value) / (2 * step)
        if !isfinite(predicted) || !isfinite(finite_difference)
            push!(domain_limited, (direction = direction_index, reason = "non-finite objective directional derivative"))
            continue
        end
        tested += 1
        error = abs(predicted - finite_difference)
        scale_value = max(one(T), abs(predicted), abs(finite_difference))
        tolerance = convert(T, absolute_tolerance) +
                    convert(T, relative_tolerance) * scale_value
        error > tolerance && push!(mismatches, (
            direction = direction_index,
            predicted = predicted,
            finite_difference = finite_difference,
            absolute_error = error,
            relative_error = error / scale_value,
            tolerance = tolerance,
        ))
    end
    report.metadata[:directions_tested] = string(length(directions))
    report.metadata[:objective_directional_comparisons] = string(tested)
    report.metadata[:mismatch_count] = string(length(mismatches))
    report.metadata[:domain_limited_count] = string(length(domain_limited))
    report.metadata[:maximum_relative_error] = isempty(mismatches) ? "0.0" :
        string(maximum(item.relative_error for item in mismatches))
    if !isempty(mismatches)
        push!(report, Finding(
            :objective_gradient_directional_crosscheck_mismatch;
            severity = SeverityWarning,
            domain = NumericalIssue,
            basis = NumericalObservation,
            confidence = ConfidenceMedium,
            observation = "$(length(mismatches)) objective-gradient directional product(s) disagree with central finite differences beyond the declared tolerance.",
            why_it_matters = "The objective derivative path and nearby objective values are locally inconsistent. This can reflect implementation error, finite-difference truncation or cancellation, a nonsmooth objective, or a domain/range boundary.",
            evidence = [
                _point_evidence(evaluation.point),
                Evidence("Directional objective-gradient cross-check residuals"; details = [
                    "comparison_count" => tested,
                    "mismatch_count" => length(mismatches),
                    "worst_cases" => join((
                        "direction=$(item.direction),error=$(item.absolute_error),relative=$(item.relative_error),tolerance=$(item.tolerance)" for item in mismatches[1:min(end, 8)]
                    ), ";"),
                    "objective_gradient_method" => evaluation.objective_gradient_method,
                ]),
            ],
            suggested_actions = [
                "Repeat with multiple perturbation scales and inspect objective-domain findings at both perturbed points.",
                "Compare the objective derivative source with an independently constructed derivative or solver callback.",
            ],
        ))
    elseif tested > 0
        push!(report, Finding(
            :objective_gradient_directional_crosscheck_consistent;
            severity = SeverityInfo,
            domain = NumericalIssue,
            basis = NumericalObservation,
            confidence = ConfidenceMedium,
            observation = "All $tested tested objective-gradient directional products agree with central finite differences within the declared tolerance.",
            why_it_matters = "This is local consistency evidence for the recorded objective derivative path at the supplied point, not a global derivative certificate.",
            evidence = [_point_evidence(evaluation.point)],
            suggested_actions = ["Repeat across representative solver iterates and safe perturbation scales before relying on the gradient globally."],
        ))
    end
    if !isempty(domain_limited)
        push!(report, Finding(
            :objective_gradient_directional_crosscheck_domain_limited;
            severity = SeverityInfo,
            domain = NumericalIssue,
            basis = NumericalObservation,
            confidence = ConfidenceCertain,
            observation = "$(length(domain_limited)) objective-gradient comparisons were unavailable because a perturbed objective evaluation was non-finite or failed.",
            why_it_matters = "A missing finite-difference side cannot be interpreted as a zero directional derivative or as evidence against the recorded gradient.",
            evidence = [Evidence("Objective cross-check availability"; details = [
                "limited_cases" => join((
                    "direction=$(item.direction),reason=$(item.reason)" for item in domain_limited[1:min(end, 12)]
                ), ";"),
                "base_point_fingerprint" => evaluation_point_fingerprint(evaluation.point),
            ])],
            suggested_actions = ["Choose a point with objective-domain margin or reduce the perturbation step."],
        ))
    end
    sort!(report.findings; by = finding -> (-Int(finding.severity), string(finding.code)))
    return report
end

function analyze_objective_gradient_directional_crosscheck(
    model::MOI.ModelLike,
    point::EvaluationPoint{T};
    cache::EvaluationCache = EvaluationCache(),
    relative_step::Real = cbrt(eps(T)),
    kwargs...,
) where {T<:AbstractFloat}
    evaluation = evaluate_numerical(model, point; cache = cache, relative_step = relative_step)
    return analyze_objective_gradient_directional_crosscheck(
        model,
        evaluation;
        cache = cache,
        relative_step = relative_step,
        kwargs...,
    )
end

"""
    analyze_nonsmoothness(model, evaluation; ...)

Run bounded directional derivative consistency checks and classify their
evidence conservatively. A mismatch can indicate nonsmoothness, domain
crossing, finite-difference error, or an implementation defect; a consistent
screen does not prove differentiability away from the tested point.
"""
function analyze_nonsmoothness(
    model::MOI.ModelLike,
    evaluation::NumericalEvaluation{T};
    direction_count::Integer = min(3, max(length(evaluation.point.variables), 1)),
    relative_step::Real = cbrt(eps(T)),
    absolute_tolerance::Real = zero(T),
    relative_tolerance::Real = sqrt(eps(T)),
    check_jacobian::Bool = true,
    check_objective::Bool = true,
    cache::EvaluationCache = EvaluationCache(),
) where {T<:AbstractFloat}
    check_jacobian || check_objective || throw(ArgumentError(
        "at least one nonsmoothness derivative check must be enabled",
    ))
    report = DiagnosticReport()
    report.metadata[:stage] = "nonsmoothness"
    report.metadata[:nonsmoothness_direction_count] = string(direction_count)
    report.metadata[:nonsmoothness_relative_step] = string(relative_step)
    report.metadata[:nonsmoothness_check_jacobian] = string(check_jacobian)
    report.metadata[:nonsmoothness_check_objective] = string(check_objective)
    jacobian_report = check_jacobian ? analyze_jacobian_directional_crosscheck(
        model,
        evaluation;
        direction_count,
        relative_step,
        absolute_tolerance,
        relative_tolerance,
        cache,
    ) : nothing
    objective_report = check_objective ? analyze_objective_gradient_directional_crosscheck(
        model,
        evaluation;
        direction_count,
        relative_step,
        absolute_tolerance,
        relative_tolerance,
        cache,
    ) : nothing
    mismatch_count = 0
    domain_limited_count = 0
    comparison_count = 0
    if !isnothing(jacobian_report)
        parsed = tryparse(Int, string(get(jacobian_report.metadata, :mismatch_count, "0")))
        mismatch_count += isnothing(parsed) ? 0 : parsed
        parsed = tryparse(Int, string(get(jacobian_report.metadata, :domain_limited_count, "0")))
        domain_limited_count += isnothing(parsed) ? 0 : parsed
        parsed = tryparse(Int, string(get(jacobian_report.metadata, :constraint_directional_comparisons, "0")))
        comparison_count += isnothing(parsed) ? 0 : parsed
    end
    if !isnothing(objective_report)
        parsed = tryparse(Int, string(get(objective_report.metadata, :mismatch_count, "0")))
        mismatch_count += isnothing(parsed) ? 0 : parsed
        parsed = tryparse(Int, string(get(objective_report.metadata, :domain_limited_count, "0")))
        domain_limited_count += isnothing(parsed) ? 0 : parsed
        parsed = tryparse(Int, string(get(objective_report.metadata, :objective_directional_comparisons, "0")))
        comparison_count += isnothing(parsed) ? 0 : parsed
    end
    methods = vcat(
        check_jacobian ? string.(evaluation.jacobian_row_methods) : String[],
        check_objective ? [string(evaluation.objective_gradient_method)] : String[],
    )
    finite_difference_evidence = count(method -> method in
        ("central_finite_difference", "partial_central_finite_difference"), methods)
    report.metadata[:nonsmoothness_mismatch_count] = string(mismatch_count)
    report.metadata[:nonsmoothness_domain_limited_count] = string(domain_limited_count)
    report.metadata[:nonsmoothness_comparison_count] = string(comparison_count)
    report.metadata[:nonsmoothness_finite_difference_evidence_count] = string(finite_difference_evidence)
    status = mismatch_count > 0 ? :possible_nonsmoothness_or_derivative_inconsistency :
             domain_limited_count > 0 ? :inconclusive_domain_limited :
             :no_nonsmoothness_inconsistency_observed
    report.metadata[:nonsmoothness_status] = string(status)
    evidence = [
        _point_evidence(evaluation.point),
        Evidence("Nonsmoothness directional screen"; details = [
            "status" => status,
            "comparison_count" => comparison_count,
            "mismatch_count" => mismatch_count,
            "domain_limited_count" => domain_limited_count,
            "finite_difference_evidence_count" => finite_difference_evidence,
            "relative_step" => relative_step,
            "relative_tolerance" => relative_tolerance,
            "derivative_methods" => join(methods, ","),
        ]),
    ]
    if status == :possible_nonsmoothness_or_derivative_inconsistency
        push!(report, Finding(:possible_nonsmoothness;
            severity = SeverityWarning,
            domain = NumericalIssue,
            basis = NumericalObservation,
            confidence = ConfidenceMedium,
            observation = "$(mismatch_count) directional derivative comparison(s) disagree beyond tolerance at the supplied point.",
            why_it_matters = "The mismatch is compatible with a nonsmooth point, domain crossing, finite-difference error, or derivative implementation defect; it is not a nonsmoothness proof.",
            evidence,
            suggested_actions = [
                "Repeat at multiple perturbation scales and nearby valid points.",
                "Inspect operator-domain findings and derivative provenance before attributing the mismatch to nonsmoothness.",
            ],
        ))
    elseif status == :inconclusive_domain_limited
        push!(report, Finding(:nonsmoothness_screen_inconclusive;
            severity = SeverityInfo,
            domain = NumericalIssue,
            basis = NumericalObservation,
            confidence = ConfidenceCertain,
            observation = "The nonsmoothness screen is inconclusive because $(domain_limited_count) perturbed derivative comparison(s) were domain-limited or unavailable.",
            why_it_matters = "Missing perturbed values cannot distinguish smoothness from a domain boundary or unavailable derivative evidence.",
            evidence,
            suggested_actions = ["Repeat at a point with more domain margin or use a smaller perturbation step."],
        ))
    else
        push!(report, Finding(:no_nonsmoothness_inconsistency_observed;
            severity = SeverityInfo,
            domain = NumericalIssue,
            basis = NumericalObservation,
            confidence = ConfidenceMedium,
            observation = "All $(comparison_count) tested directional derivative comparison(s) agree within tolerance at the supplied point.",
            why_it_matters = "This is local consistency evidence only; it does not prove differentiability globally or away from the tested directions.",
            evidence,
            suggested_actions = ["Repeat across representative points and perturbation scales before relying on a smooth derivative model globally."],
        ))
    end
    _apply_point_provenance_guard!(report, evaluation.point)
    sort!(report.findings; by = finding -> (-Int(finding.severity), string(finding.code)))
    return report
end

function analyze_nonsmoothness(
    model::MOI.ModelLike,
    point::EvaluationPoint{T};
    cache::EvaluationCache = EvaluationCache(),
    relative_step::Real = cbrt(eps(T)),
    kwargs...,
) where {T<:AbstractFloat}
    return analyze_nonsmoothness(
        model,
        evaluate_numerical(model, point; cache = cache, relative_step = relative_step);
        cache,
        relative_step,
        kwargs...,
    )
end

"""
    analyze_nonsmoothness_persistence(evaluations; ...)

Compare the bounded nonsmoothness screen across explicitly supplied points.
Persistent disagreement remains a possible nonsmoothness/derivative issue,
not a proof of a nonsmooth model.
"""
function analyze_nonsmoothness_persistence(
    model::MOI.ModelLike,
    evaluations::AbstractVector{<:NumericalEvaluation};
    minimum_evaluations::Integer = 2,
    kwargs...,
)
    minimum_evaluations >= 2 || throw(ArgumentError("minimum_evaluations must be at least two"))
    report = DiagnosticReport()
    report.metadata[:stage] = "nonsmoothness_persistence"
    report.metadata[:evaluation_count] = string(length(evaluations))
    report.metadata[:minimum_evaluations] = string(minimum_evaluations)
    labels = join((evaluation.point.label for evaluation in evaluations), ",")
    report.metadata[:nonsmoothness_persistence_point_labels] = labels
    if length(evaluations) < minimum_evaluations
        reason = "only $(length(evaluations)) evaluation(s) supplied; at least $(minimum_evaluations) required"
        typed_reason = unavailable_reason(
            (available = false, reason = reason);
            code = :nonsmoothness_persistence_unavailable,
            category = :numerical,
            stage = :nonsmoothness_persistence,
        )
        report.metadata[:nonsmoothness_persistence_available] = "false"
        report.metadata[:nonsmoothness_persistence_reason] = typed_reason.message
        report.metadata[:nonsmoothness_persistence_unavailable_reason] = typed_reason.message
        report.metadata[:nonsmoothness_persistence_category] = string(typed_reason.category)
        report.metadata[:nonsmoothness_persistence_stage] = string(typed_reason.stage)
        push!(report, Finding(:nonsmoothness_persistence_unavailable;
            severity = SeverityInfo, domain = NumericalIssue,
            basis = NumericalObservation, confidence = ConfidenceHigh,
            observation = "Nonsmoothness persistence is unavailable for $(length(evaluations)) supplied evaluation(s).",
            why_it_matters = "Persistence requires multiple explicitly evaluated points.",
            evidence = [Evidence("Nonsmoothness persistence availability"; details = [
                "evaluation_count" => length(evaluations),
                "minimum_evaluations" => minimum_evaluations,
            ])],
            suggested_actions = ["Supply nearby valid points or captured solver iterates."],
        ))
        return report
    end
    reference_variables = first(evaluations).point.variables
    reference_rows = first(evaluations).constraint_sources
    if any(evaluation.point.variables != reference_variables for evaluation in evaluations) ||
       any(evaluation.constraint_sources != reference_rows for evaluation in evaluations)
        reason = "supplied evaluations do not share one ordered variable and constraint-row scope"
        typed_reason = unavailable_reason(
            (available = false, reason = reason);
            code = :nonsmoothness_persistence_unavailable,
            category = :input,
            stage = :nonsmoothness_persistence,
        )
        report.metadata[:nonsmoothness_persistence_available] = "false"
        report.metadata[:nonsmoothness_persistence_reason] = typed_reason.message
        report.metadata[:nonsmoothness_persistence_unavailable_reason] = typed_reason.message
        report.metadata[:nonsmoothness_persistence_category] = string(typed_reason.category)
        report.metadata[:nonsmoothness_persistence_stage] = string(typed_reason.stage)
        push!(report, Finding(:nonsmoothness_persistence_coordinate_mismatch;
            severity = SeverityInfo, domain = RepresentationalIssue,
            basis = StructuralProof, confidence = ConfidenceCertain,
            observation = "Nonsmoothness evaluations do not share one ordered variable and constraint-row scope.",
            why_it_matters = "Cross-point directional evidence cannot be compared when coordinates or rows change.",
            evidence = [Evidence("Nonsmoothness persistence alignment"; details = [
                "evaluation_count" => length(evaluations),
                "point_labels" => labels,
            ])],
            suggested_actions = ["Evaluate the same ordered variables and scalar rows at every point."],
        ))
        return report
    end
    screens = [analyze_nonsmoothness(model, evaluation; kwargs...) for evaluation in evaluations]
    statuses = [string(screen.metadata[:nonsmoothness_status]) for screen in screens]
    mismatches = [parse(Int, string(screen.metadata[:nonsmoothness_mismatch_count])) for screen in screens]
    limited = [parse(Int, string(screen.metadata[:nonsmoothness_domain_limited_count])) for screen in screens]
    report.metadata[:nonsmoothness_persistence_available] = "true"
    report.metadata[:nonsmoothness_persistence_statuses] = join(statuses, ",")
    report.metadata[:nonsmoothness_persistence_mismatch_counts] = join(mismatches, ",")
    report.metadata[:nonsmoothness_persistence_domain_limited_counts] = join(limited, ",")
    persistent_mismatch = all(==("possible_nonsmoothness_or_derivative_inconsistency"), statuses)
    any_mismatch = any(>(0), mismatches)
    any_limited = any(>(0), limited)
    status = persistent_mismatch ? :possible_nonsmoothness_persistent :
             any_mismatch ? :possible_nonsmoothness_not_persistent :
             any_limited ? :inconclusive_domain_limited :
             :no_nonsmoothness_inconsistency_observed_persistent
    report.metadata[:nonsmoothness_persistence_classification] = string(status)
    evidence = [Evidence("Nonsmoothness persistence"; details = [
        "point_labels" => labels,
        "statuses" => join(statuses, ","),
        "mismatch_counts" => join(mismatches, ","),
        "domain_limited_counts" => join(limited, ","),
    ])]
    code = status == :possible_nonsmoothness_persistent ? :possible_nonsmoothness_persistent :
           status == :possible_nonsmoothness_not_persistent ? :possible_nonsmoothness_not_persistent :
           status == :inconclusive_domain_limited ? :nonsmoothness_persistence_inconclusive :
           :nonsmoothness_consistency_persistent
    severity = status in (:possible_nonsmoothness_persistent, :possible_nonsmoothness_not_persistent) ?
               SeverityWarning : SeverityInfo
    push!(report, Finding(code;
        severity,
        domain = severity == SeverityWarning ? NumericalIssue : RepresentationalIssue,
        basis = NumericalObservation,
        confidence = status == :inconclusive_domain_limited ? ConfidenceCertain : ConfidenceMedium,
        observation = "Nonsmoothness screen classification across $(length(evaluations)) points: $(status).",
        why_it_matters = "Cross-point consistency helps distinguish point-specific derivative behavior from repeated evidence, but does not establish global smoothness or nonsmoothness.",
        evidence,
        suggested_actions = ["Inspect point-local cross-check evidence and repeat over the operating region before changing model or solver conclusions."],
    ))
    return report
end

function analyze_nonsmoothness_persistence(
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
    return analyze_nonsmoothness_persistence(model, evaluations; kwargs...)
end

function _crosscheck_lagrangian_gradient(
    evaluation::NumericalEvaluation{T},
    objective_weight::T,
    constraint_multipliers::AbstractVector{<:Real},
) where {T<:AbstractFloat}
    row_count = length(evaluation.constraint_sources)
    length(constraint_multipliers) == row_count ||
        return nothing, "constraint multiplier length does not match evaluated rows"
    gradient = zeros(T, length(evaluation.point.variables))
    if !iszero(objective_weight)
        length(evaluation.objective_gradient) == length(gradient) ||
            return nothing, "objective gradient length is unavailable"
        any(value -> ismissing(value) || !isfinite(value), evaluation.objective_gradient) &&
            return nothing, "objective gradient contains missing or non-finite values"
        gradient .+= objective_weight .* T.(evaluation.objective_gradient)
    end
    unavailable_rows = Set(
        row for (row, method) in enumerate(evaluation.jacobian_row_methods) if
        method == :unavailable
    )
    for row in 1:row_count
        multiplier = convert(T, constraint_multipliers[row])
        isfinite(multiplier) || return nothing, "constraint multiplier is non-finite"
        iszero(multiplier) && continue
        row in unavailable_rows &&
            return nothing, "a nonzero-multiplier Jacobian row is unavailable"
    end
    for entry in evaluation.jacobian_entries
        row = entry.row
        1 <= row <= row_count || continue
        multiplier = convert(T, constraint_multipliers[row])
        iszero(multiplier) || (gradient[entry.column] += multiplier * entry.value)
    end
    return gradient, nothing
end

function _try_nlp_hessian_vector_product(
    model::MOI.ModelLike,
    hessian::HessianEvaluation{T},
    direction::AbstractVector{T},
) where {T<:AbstractFloat}
    block = _optional_nlp_block(model)
    isnothing(block) && return nothing, "no NLPBlock"
    capability = evaluator_capabilities(block.evaluator)
    :HessVec in capability.available_features ||
        return nothing, "NLP evaluator does not advertise :HessVec"
    evaluation = evaluate_numerical(model, hessian.point)
    nlp_rows = findall(source -> source.kind == :nlp_constraint, evaluation.constraint_sources)
    length(hessian.constraint_multipliers) == length(evaluation.constraint_sources) ||
        return nothing, "Hessian multiplier rows are not aligned with the evaluation"
    non_nlp_multipliers = setdiff(1:length(hessian.constraint_multipliers), nlp_rows)
    any(!iszero, hessian.constraint_multipliers[non_nlp_multipliers]) &&
        return nothing, "non-NLP constraint multipliers cannot be represented by the NLP HessVec callback"
    if !block.has_objective && !iszero(hessian.objective_weight)
        return nothing, "the NLP block has no objective but a nonzero objective weight was supplied"
    end
    multipliers = hessian.constraint_multipliers[nlp_rows]
    sigma = block.has_objective ? hessian.objective_weight : zero(T)
    try
        MOI.initialize(block.evaluator, copy(capability.requested_features))
        values = zeros(T, length(direction))
        MOI.eval_hessian_lagrangian_product(
            block.evaluator,
            values,
            copy(hessian.point.values),
            copy(direction),
            sigma,
            T.(multipliers),
        )
        all(isfinite, values) || return nothing, "MOI HessVec returned non-finite values"
        return values, "MOI.eval_hessian_lagrangian_product"
    catch exception
        return nothing, sprint(showerror, exception)
    end
end

"""
    analyze_hessian_vector_crosscheck(model, hessian; kwargs...)

Compare a stored Hessian-of-the-Lagrangian against central finite differences
of the Lagrangian gradient. When the model's NLP evaluator advertises
`:HessVec` and the supplied multipliers represent only that block, also
compare the direct MOI product against the stored sparse Hessian product.
Unavailable or domain-limited perturbations remain explicit evidence.
"""
function analyze_hessian_vector_crosscheck(
    model::MOI.ModelLike,
    hessian::HessianEvaluation{T};
    direction_count::Integer = min(3, max(length(hessian.point.variables), 1)),
    relative_step::Real = cbrt(eps(T)),
    absolute_tolerance::Real = zero(T),
    relative_tolerance::Real = sqrt(eps(T)),
    cache::EvaluationCache = EvaluationCache(),
) where {T<:AbstractFloat}
    direction_count > 0 || throw(ArgumentError("direction_count must be positive"))
    relative_step > 0 || throw(ArgumentError("relative_step must be positive"))
    absolute_tolerance >= 0 || throw(ArgumentError("absolute_tolerance must be nonnegative"))
    relative_tolerance >= 0 || throw(ArgumentError("relative_tolerance must be nonnegative"))
    _validate_evaluation_variable_order(model, evaluate_numerical(model, hessian.point; cache = cache))
    base = evaluate_numerical(model, hessian.point; cache = cache)
    report = _directional_crosscheck_report(
        "hessian_vector_crosscheck",
        model,
        base,
        direction_count,
        relative_step,
        absolute_tolerance,
        relative_tolerance,
    )
    report.metadata[:hessian_methods] = join(string.(hessian.methods), ",")
    report.metadata[:hessian_complete] = string(hessian.complete)
    if !hessian.complete
        push!(report, Finding(
            :hessian_vector_crosscheck_unavailable;
            severity = SeverityInfo,
            domain = RepresentationalIssue,
            basis = NumericalObservation,
            confidence = ConfidenceCertain,
            observation = "The stored Hessian-of-the-Lagrangian is incomplete, so its vector products cannot be independently calibrated.",
            why_it_matters = "A partial Hessian cannot distinguish a derivative disagreement from an omitted contribution.",
            evidence = [_point_evidence(hessian.point), Evidence("Hessian availability"; details = [
                "methods" => join(string.(hessian.methods), ","),
                "failure_count" => length(hessian.failures),
            ])],
            suggested_actions = ["Resolve the recorded Hessian failures or use a point and multiplier set with complete curvature evidence."],
        ))
        report.metadata[:directions_tested] = "0"
        return report
    end
    matrix = _combined_hessian_matrix(hessian)
    directions = _directional_crosscheck_directions(T, length(hessian.point.variables), direction_count)
    mismatches = NamedTuple[]
    domain_limited = NamedTuple[]
    hessvec_sources = Set{String}()
    tested = 0
    direct_tested = 0
    for (direction_index, direction) in enumerate(directions)
        scale = max(one(T), maximum(abs, hessian.point.values; init = zero(T)))
        step = convert(T, relative_step) * scale
        plus_point = _directional_crosscheck_point(
            hessian.point, direction, step, direction_index, :plus,
            "Hessian-vector directional cross-check",
        )
        minus_point = _directional_crosscheck_point(
            hessian.point, direction, step, direction_index, :minus,
            "Hessian-vector directional cross-check",
        )
        plus = nothing
        minus = nothing
        try
            plus = evaluate_numerical(model, plus_point; cache = cache, relative_step = relative_step)
            minus = evaluate_numerical(model, minus_point; cache = cache, relative_step = relative_step)
            plus_gradient, plus_reason = _crosscheck_lagrangian_gradient(
                plus, hessian.objective_weight, hessian.constraint_multipliers,
            )
            minus_gradient, minus_reason = _crosscheck_lagrangian_gradient(
                minus, hessian.objective_weight, hessian.constraint_multipliers,
            )
            if isnothing(plus_gradient) || isnothing(minus_gradient)
                reason = isnothing(plus_gradient) ? plus_reason : minus_reason
                push!(domain_limited, (direction = direction_index, reason = reason))
            else
                finite_difference = (plus_gradient - minus_gradient) / (2 * step)
                predicted = matrix * direction
                if !all(isfinite, finite_difference) || !all(isfinite, predicted)
                    push!(domain_limited, (direction = direction_index, reason = "non-finite Hessian-vector product"))
                else
                    tested += 1
                    error = norm(predicted - finite_difference)
                    scale_value = max(one(T), norm(predicted), norm(finite_difference))
                    tolerance = convert(T, absolute_tolerance) + convert(T, relative_tolerance) * scale_value
                    error > tolerance && push!(mismatches, (
                        direction = direction_index,
                        kind = :finite_difference,
                        absolute_error = error,
                        relative_error = error / scale_value,
                        tolerance = tolerance,
                    ))
                end
            end
        catch exception
            push!(domain_limited, (direction = direction_index, reason = sprint(showerror, exception)))
        end
        direct, direct_source = _try_nlp_hessian_vector_product(model, hessian, direction)
        push!(hessvec_sources, direct_source)
        if !isnothing(direct)
            direct_tested += 1
            predicted = matrix * direction
            error = norm(direct - predicted)
            scale_value = max(one(T), norm(direct), norm(predicted))
            tolerance = convert(T, absolute_tolerance) + convert(T, relative_tolerance) * scale_value
            error > tolerance && push!(mismatches, (
                direction = direction_index,
                kind = :hessvec,
                absolute_error = error,
                relative_error = error / scale_value,
                tolerance = tolerance,
            ))
        end
    end
    report.metadata[:directions_tested] = string(length(directions))
    report.metadata[:hessian_directional_comparisons] = string(tested)
    report.metadata[:hessvec_directional_comparisons] = string(direct_tested)
    report.metadata[:mismatch_count] = string(length(mismatches))
    report.metadata[:domain_limited_count] = string(length(domain_limited))
    report.metadata[:hessvec_sources] = join(sort!(collect(hessvec_sources)), ",")
    report.metadata[:maximum_relative_error] = isempty(mismatches) ? "0.0" :
        string(maximum(item.relative_error for item in mismatches))
    if !isempty(mismatches)
        push!(report, Finding(
            :hessian_vector_crosscheck_mismatch;
            severity = SeverityWarning,
            domain = NumericalIssue,
            basis = NumericalObservation,
            confidence = ConfidenceMedium,
            observation = "$(length(mismatches)) Hessian-vector product(s) disagree with an independent local product beyond the declared tolerance.",
            why_it_matters = "The stored curvature, finite-difference Lagrangian gradient, or direct HessVec callback is locally inconsistent; this can reflect implementation error, cancellation, nonsmoothness, or a domain boundary.",
            evidence = [_point_evidence(hessian.point), Evidence("Hessian-vector residuals"; details = [
                "comparison_count" => tested,
                "hessvec_comparison_count" => direct_tested,
                "mismatch_count" => length(mismatches),
                "worst_cases" => join((
                    "direction=$(item.direction),kind=$(item.kind),error=$(item.absolute_error),relative=$(item.relative_error),tolerance=$(item.tolerance)" for item in mismatches[1:min(end, 8)]
                ), ";"),
            ])],
            suggested_actions = [
                "Repeat at multiple perturbation scales and inspect operator-domain findings at both perturbed points.",
                "Compare the stored Hessian source, multiplier ordering, and direct MOI HessVec callback independently.",
            ],
        ))
    elseif tested > 0 || direct_tested > 0
        push!(report, Finding(
            :hessian_vector_crosscheck_consistent;
            severity = SeverityInfo,
            domain = NumericalIssue,
            basis = NumericalObservation,
            confidence = ConfidenceMedium,
            observation = "All tested Hessian-vector products agree with the available independent products within the declared tolerance.",
            why_it_matters = "This is local curvature consistency evidence at the supplied point, not a global Hessian correctness certificate.",
            evidence = [_point_evidence(hessian.point)],
            suggested_actions = ["Repeat over solver iterates, multiplier representatives, and safe perturbation scales before relying on curvature interpretations."],
        ))
    end
    if !isempty(domain_limited)
        push!(report, Finding(
            :hessian_vector_crosscheck_domain_limited;
            severity = SeverityInfo,
            domain = NumericalIssue,
            basis = NumericalObservation,
            confidence = ConfidenceCertain,
            observation = "$(length(domain_limited)) Hessian-vector comparisons were unavailable because a perturbed Lagrangian gradient was incomplete, non-finite, or failed.",
            why_it_matters = "A missing perturbation side cannot be interpreted as zero curvature or as evidence against the recorded Hessian.",
            evidence = [Evidence("Hessian-vector availability"; details = [
                "limited_cases" => join((
                    "direction=$(item.direction),reason=$(item.reason)" for item in domain_limited[1:min(end, 12)]
                ), ";"),
            ])],
            suggested_actions = ["Use a complete point with domain margin or reduce the perturbation step."],
        ))
    end
    sort!(report.findings; by = finding -> (-Int(finding.severity), string(finding.code)))
    return report
end

function _crosscheck_metadata_int(report::DiagnosticReport, key::Symbol)
    value = get(report.metadata, key, "0")
    try
        return parse(Int, string(value))
    catch
        return 0
    end
end

"""
    analyze_derivative_crosscheck_scale_sweep(model, evaluation; kwargs...)

Run the enabled local derivative cross-checks at several perturbation scales
and summarize whether disagreement is scale-persistent or scale-sensitive.
This is a calibration summary, not a score and not a global derivative proof.
"""
function analyze_derivative_crosscheck_scale_sweep(
    model::MOI.ModelLike,
    evaluation::NumericalEvaluation{T};
    relative_steps::AbstractVector{<:Real} = T[eps(T)^(one(T) / 4), cbrt(eps(T)), sqrt(eps(T))],
    check_jacobian::Bool = true,
    check_objective_gradient::Bool = true,
    hessian::Union{Nothing,HessianEvaluation{T}} = nothing,
    check_hessian::Bool = !isnothing(hessian),
    direction_count::Integer = min(3, max(length(evaluation.point.variables), 1)),
    absolute_tolerance::Real = zero(T),
    relative_tolerance::Real = sqrt(eps(T)),
    cache::EvaluationCache = EvaluationCache(),
) where {T<:AbstractFloat}
    isempty(relative_steps) && throw(ArgumentError("relative_steps must not be empty"))
    all(step -> isfinite(step) && step > 0, relative_steps) ||
        throw(ArgumentError("relative_steps must be finite and positive"))
    (check_jacobian || check_objective_gradient || (check_hessian && !isnothing(hessian))) ||
        throw(ArgumentError("at least one derivative cross-check must be enabled"))
    check_hessian && isnothing(hessian) && throw(ArgumentError("check_hessian requires a supplied HessianEvaluation"))
    report = _directional_crosscheck_report(
        "derivative_crosscheck_scale_sweep",
        model,
        evaluation,
        direction_count,
        first(relative_steps),
        absolute_tolerance,
        relative_tolerance,
    )
    records = NamedTuple[]
    for step in relative_steps
        row = (scale = step, jacobian_mismatches = 0, jacobian_domain_limited = 0,
            objective_mismatches = 0, objective_domain_limited = 0,
            hessian_mismatches = 0, hessian_domain_limited = 0,
            tested = 0)
        if check_jacobian
            jacobian_report = analyze_jacobian_directional_crosscheck(
                model,
                evaluation;
                direction_count = direction_count,
                relative_step = step,
                absolute_tolerance = absolute_tolerance,
                relative_tolerance = relative_tolerance,
                cache = cache,
            )
            row = merge(row, (
                jacobian_mismatches = _crosscheck_metadata_int(jacobian_report, :mismatch_count),
                jacobian_domain_limited = _crosscheck_metadata_int(jacobian_report, :domain_limited_count),
                tested = row.tested + _crosscheck_metadata_int(jacobian_report, :constraint_directional_comparisons),
            ))
        end
        if check_objective_gradient
            objective_report = analyze_objective_gradient_directional_crosscheck(
                model,
                evaluation;
                direction_count = direction_count,
                relative_step = step,
                absolute_tolerance = absolute_tolerance,
                relative_tolerance = relative_tolerance,
                cache = cache,
            )
            row = merge(row, (
                objective_mismatches = _crosscheck_metadata_int(objective_report, :mismatch_count),
                objective_domain_limited = _crosscheck_metadata_int(objective_report, :domain_limited_count),
                tested = row.tested + _crosscheck_metadata_int(objective_report, :objective_directional_comparisons),
            ))
        end
        if check_hessian
            hessian_report = analyze_hessian_vector_crosscheck(
                model,
                hessian;
                direction_count = direction_count,
                relative_step = step,
                absolute_tolerance = absolute_tolerance,
                relative_tolerance = relative_tolerance,
                cache = cache,
            )
            row = merge(row, (
                hessian_mismatches = _crosscheck_metadata_int(hessian_report, :mismatch_count),
                hessian_domain_limited = _crosscheck_metadata_int(hessian_report, :domain_limited_count),
                tested = row.tested + _crosscheck_metadata_int(hessian_report, :hessian_directional_comparisons),
            ))
        end
        push!(records, row)
    end
    report.metadata[:scale_count] = string(length(records))
    report.metadata[:scale_values] = join(string.(getfield.(records, :scale)), ",")
    report.metadata[:scale_summary] = join((
        "scale=$(row.scale),jacobian_mismatches=$(row.jacobian_mismatches),objective_mismatches=$(row.objective_mismatches),hessian_mismatches=$(row.hessian_mismatches),domain_limited=$(row.jacobian_domain_limited + row.objective_domain_limited + row.hessian_domain_limited),tested=$(row.tested)" for row in records
    ), ";")
    total_mismatches = sum(row.jacobian_mismatches + row.objective_mismatches + row.hessian_mismatches for row in records)
    total_domain_limited = sum(row.jacobian_domain_limited + row.objective_domain_limited + row.hessian_domain_limited for row in records)
    total_tested = sum(row.tested for row in records)
    report.metadata[:mismatch_count] = string(total_mismatches)
    report.metadata[:domain_limited_count] = string(total_domain_limited)
    report.metadata[:directional_comparisons] = string(total_tested)
    if total_mismatches > 0
        persistent = all(
            row.jacobian_mismatches + row.objective_mismatches + row.hessian_mismatches > 0
            for row in records
        )
        push!(report, Finding(
            :derivative_crosscheck_scale_sensitivity;
            severity = SeverityWarning,
            domain = NumericalIssue,
            basis = NumericalObservation,
            confidence = ConfidenceMedium,
            observation = persistent ?
                "Derivative cross-check disagreement persists at every tested perturbation scale." :
                "Derivative cross-check disagreement changes across perturbation scales.",
            why_it_matters = persistent ?
                "Scale-persistent disagreement is stronger local evidence of a derivative or formulation inconsistency, although domain and nonsmooth explanations remain possible." :
                "Scale-sensitive disagreement is consistent with truncation, cancellation, nonsmoothness, or an operator boundary and should not be reduced to a single derivative defect.",
            evidence = [_point_evidence(evaluation.point), Evidence("Derivative cross-check scale summary"; details = [
                "scale_summary" => report.metadata[:scale_summary],
                "total_mismatches" => total_mismatches,
                "total_domain_limited" => total_domain_limited,
            ])],
            suggested_actions = [
                "Inspect the per-scale residuals and domain findings before changing the derivative implementation.",
                "Repeat the sweep at representative solver iterates and with a second independent derivative source.",
            ],
        ))
    elseif total_tested > 0
        push!(report, Finding(
            :derivative_crosscheck_scale_sweep_consistent;
            severity = SeverityInfo,
            domain = NumericalIssue,
            basis = NumericalObservation,
            confidence = ConfidenceMedium,
            observation = "All tested derivative products agree across the requested perturbation scales.",
            why_it_matters = "Multi-scale agreement is stronger local consistency evidence than a single step, but it remains bounded by the tested directions and point.",
            evidence = [_point_evidence(evaluation.point), Evidence("Derivative cross-check scale summary"; details = [
                "scale_summary" => report.metadata[:scale_summary],
            ])],
            suggested_actions = ["Repeat over trusted solver points before promoting the result to a benchmark-wide conclusion."],
        ))
    else
        push!(report, Finding(
            :derivative_crosscheck_scale_sweep_unavailable;
            severity = SeverityInfo,
            domain = RepresentationalIssue,
            basis = NumericalObservation,
            confidence = ConfidenceCertain,
            observation = "No finite directional derivative comparisons were available at any requested perturbation scale.",
            why_it_matters = "A scale sweep cannot classify derivative consistency without at least one complete local comparison.",
            evidence = [_point_evidence(evaluation.point)],
            suggested_actions = ["Use a complete point with domain margin and derivative provenance."],
        ))
    end
    sort!(report.findings; by = finding -> (-Int(finding.severity), string(finding.code)))
    return report
end

function analyze_jacobian_directional_crosscheck(
    model::MOI.ModelLike,
    point::EvaluationPoint{T};
    cache::EvaluationCache = EvaluationCache(),
    relative_step::Real = cbrt(eps(T)),
    kwargs...,
) where {T<:AbstractFloat}
    evaluation = evaluate_numerical(model, point; cache = cache, relative_step = relative_step)
    return analyze_jacobian_directional_crosscheck(
        model,
        evaluation;
        cache = cache,
        relative_step = relative_step,
        kwargs...,
    )
end
