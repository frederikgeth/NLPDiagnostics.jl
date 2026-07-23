function _variable_start(model::MOI.ModelLike, variable)
    try
        value = MOI.get(model, MOI.VariablePrimalStart(), variable)
        return value isa Real ? value : nothing
    catch
        return nothing
    end
end

"""
    initialization_point(model; label = "initialization")

Return a complete point from `MOI.VariablePrimalStart`, or `nothing` if any
variable has no real start value. Missing starts are never silently replaced.
"""
function initialization_point(
    model::MOI.ModelLike;
    label::AbstractString = "initialization",
)
    variables = MOI.get(model, MOI.ListOfVariableIndices())
    values = [_variable_start(model, variable) for variable in variables]
    any(isnothing, values) && return nothing
    return EvaluationPoint(
        variables,
        Real[something(value) for value in values];
        label = label,
    )
end

function _initialization_bound_findings(
    model_snapshot::ModelSnapshot,
    point::EvaluationPoint,
)
    findings = Finding[]
    intervals = _domain_variable_intervals(model_snapshot)
    records = Dict(record.index => record for record in model_snapshot.variables)
    violations = MOI.VariableIndex[]
    boundary = MOI.VariableIndex[]
    details = Pair{String,String}[]
    disjunctive_variables = Set{MOI.VariableIndex}()
    for constraint in model_snapshot.constraints
        variable = constraint.function_value
        variable isa MOI.VariableIndex || continue
        if constraint.set_value isa MOI.ZeroOne ||
           constraint.set_value isa MOI.Integer ||
           constraint.set_value isa MOI.Semicontinuous ||
           constraint.set_value isa MOI.Semiinteger
            push!(disjunctive_variables, variable)
        end
    end
    for (variable, value) in zip(point.variables, point.values)
        interval = intervals[variable]
        interval.valid || continue
        if value < interval.lower || value > interval.upper
            push!(violations, variable)
            push!(
                details,
                "v$(variable.value)" =>
                    "value=$value, bounds=[$(interval.lower), $(interval.upper)]",
            )
        elseif !(variable in disjunctive_variables) &&
               interval.lower != interval.upper &&
               (
            (isfinite(interval.lower) && value == interval.lower) ||
            (isfinite(interval.upper) && value == interval.upper)
        )
            push!(boundary, variable)
        end
    end
    if !isempty(violations)
        push!(
            findings,
            Finding(
                :initialization_violates_variable_bounds;
                severity = SeverityError,
                domain = MathematicalIssue,
                basis = MathematicalProof,
                confidence = ConfidenceCertain,
                observation = "$(length(violations)) initial variable values violate their declared bound intersections.",
                why_it_matters = "The supplied initialization is not a point in the declared variable domain and may be rejected, projected, or cause invalid expression evaluations.",
                evidence = [
                    _point_evidence(point),
                    Evidence(
                        "Initial values outside variable bounds";
                        details = details,
                    ),
                ],
                suggested_actions = [
                    "Correct the initial values or the declared bounds.",
                    "Re-run exact-point domain and derivative checks after correction.",
                ],
                affected = EntityRef[
                    _variable_ref(records[variable]) for
                    variable in violations
                ],
            ),
        )
    end
    if !isempty(boundary)
        push!(
            findings,
            Finding(
                :initialization_on_variable_bound;
                severity = SeverityWarning,
                domain = NumericalIssue,
                basis = LocalInference,
                confidence = ConfidenceHigh,
                observation = "$(length(boundary)) non-fixed variables start exactly on a finite bound.",
                why_it_matters = "Interior-point methods generally move bound-constrained variables into the interior, and boundary points can coincide with singular primitive derivatives such as sqrt at zero.",
                evidence = [
                    _point_evidence(point),
                    Evidence(
                        "Variables initialized on finite bounds";
                        details = [
                            "variables" =>
                                join((variable.value for variable in boundary), ","),
                        ],
                    ),
                ],
                suggested_actions = [
                    "Use an interior initial value when compatible with the model semantics.",
                    "Inspect any operating-point derivative-domain findings at the same variables.",
                ],
                affected = EntityRef[
                    _variable_ref(records[variable]) for
                    variable in boundary
                ],
            ),
        )
    end
    return findings
end

"""
    analyze_initialization(model; cache = EvaluationCache())

Inspect MOI variable starts. A complete start is evaluated using the same
value, operator-domain, derivative-domain, fingerprint, and scaling machinery
as any other explicit point.
"""
function analyze_initialization(
    model::MOI.ModelLike;
    cache::EvaluationCache = EvaluationCache(),
    numeric_type::Union{Nothing,Type{<:AbstractFloat}} = nothing,
    scale_ratio_threshold::Real = 1.0e6,
)
    variables = MOI.get(model, MOI.ListOfVariableIndices())
    starts = [_variable_start(model, variable) for variable in variables]
    missing_positions = findall(isnothing, starts)
    report = DiagnosticReport()
    report.metadata[:stage] = "initialization"
    report.metadata[:initialization_variable_count] = string(length(variables))
    report.metadata[:missing_initial_value_count] =
        string(length(missing_positions))
    if !isempty(missing_positions)
        model_snapshot = snapshot(model)
        records =
            Dict(record.index => record for record in model_snapshot.variables)
        missing_variables = variables[missing_positions]
        push!(
            report,
            Finding(
                :incomplete_variable_initialization;
                severity = SeverityInfo,
                domain = RepresentationalIssue,
                basis = StructuralProof,
                confidence = ConfidenceCertain,
                observation = "$(length(missing_variables)) variables do not have real `VariablePrimalStart` values, so initialization probing was not run.",
                why_it_matters = "Filling missing starts implicitly would make the evaluation point ambiguous and could hide invalid or poorly scaled initialization behavior.",
                evidence = [
                    Evidence(
                        "Missing variable starts";
                        details = [
                            "variables" => join(
                                (
                                    variable.value for
                                    variable in missing_variables
                                ),
                                ",",
                            ),
                        ],
                    ),
                ],
                suggested_actions = [
                    "Provide explicit starts for every variable before requesting initialization analysis.",
                    "Alternatively construct and label an explicit EvaluationPoint.",
                ],
                affected = EntityRef[
                    _variable_ref(records[variable]) for
                    variable in missing_variables
                ],
            ),
        )
        return report
    end

    point = EvaluationPoint(
        variables,
        Real[something(value) for value in starts];
        label = "initialization",
    )
    selected_numeric_type =
        isnothing(numeric_type) ? eltype(point.values) : numeric_type
    numerical = analyze_numerical(
        model,
        point;
        cache = cache,
        scale_ratio_threshold = scale_ratio_threshold,
        numeric_type = selected_numeric_type,
    )
    append!(report.findings, numerical.findings)
    merge!(report.metadata, numerical.metadata)
    report.metadata[:stage] = "initialization"
    append!(
        report.findings,
        _initialization_bound_findings(snapshot(model), point),
    )
    sort!(
        report.findings;
        by = finding -> (-Int(finding.severity), string(finding.code)),
    )
    return report
end
