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
        provenance = EvaluationPointProvenance(
            InitializationPoint;
            source = "MOI.VariablePrimalStart",
            complete = true,
        ),
    )
end

function _initialization_bound_findings(
    model_snapshot::ModelSnapshot,
    point::EvaluationPoint;
    feasibility_tolerance::Real = 0,
)
    isfinite(feasibility_tolerance) && feasibility_tolerance >= 0 ||
        throw(ArgumentError("feasibility_tolerance must be finite and nonnegative"))
    exact_tolerance = _exact_real_value(feasibility_tolerance)
    isnothing(exact_tolerance) && throw(ArgumentError("unsupported feasibility_tolerance representation"))
    findings = Finding[]
    intervals, interval_origins = _domain_variable_interval_state(model_snapshot; certified_only = true)
    records = Dict(record.index => record for record in model_snapshot.variables)
    violations = MOI.VariableIndex[]
    sub_tolerance = MOI.VariableIndex[]
    boundary = MOI.VariableIndex[]
    nonfinite = MOI.VariableIndex[]
    details = Pair{String,String}[]
    sub_tolerance_details = Pair{String,String}[]
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
        if !isfinite(value)
            push!(nonfinite, variable)
            continue
        end
        interval = _certified_interval(intervals[variable])
        interval.valid || continue
        if value < interval.lower || value > interval.upper
            # Compare exact represented numbers: floating subtraction can round
            # an excursion across the severity threshold. Unsupported exact
            # conversions conservatively retain error severity.
            endpoint = value < interval.lower ? interval.lower : interval.upper
            exact_value = _exact_real_value(value)
            exact_endpoint = _exact_real_value(endpoint)
            within_tolerance = !isnothing(exact_value) && !isnothing(exact_endpoint) &&
                abs(exact_value - exact_endpoint) <= exact_tolerance
            push!(within_tolerance ? sub_tolerance : violations, variable)
            push!(
                within_tolerance ? sub_tolerance_details : details,
                "v$(variable.value)" =>
                    "value=$value, bounds=[$(interval.lower), $(interval.upper)], origins=$(_domain_interval_origin_summary(interval_origins, variable))",
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
    if !isempty(nonfinite)
        push!(findings, Finding(:initialization_nonfinite_value;
            severity = SeverityError, domain = NumericalIssue,
            basis = NumericalObservation, confidence = ConfidenceCertain,
            observation = "$(length(nonfinite)) initial values are NaN or infinite.",
            why_it_matters = "These values are not finite real starting coordinates; they cannot establish a real-point bound violation or feasibility certificate.",
            evidence = [_point_evidence(point)],
            affected = [_variable_ref(records[v]) for v in nonfinite],
            suggested_actions = ["Supply finite initial values before interpreting point diagnostics."],
        ))
    end
    for (group, group_details, severity) in (
        (violations, details, SeverityError),
        (sub_tolerance, sub_tolerance_details, SeverityInfo),
    )
        isempty(group) && continue
        push!(
            findings,
            Finding(
                :initialization_violates_variable_bounds;
                severity = severity,
                domain = MathematicalIssue,
                basis = MathematicalProof,
                confidence = ConfidenceCertain,
                observation = "$(length(group)) initial variable values violate statically implied variable intervals.",
                why_it_matters = severity == SeverityInfo ?
                    "These exact bound excursions are at or below the absolute feasibility tolerance in each variable's coordinates. Informational severity does not make the point mathematically feasible or expression-domain safe; inspect domain findings separately." :
                    "The supplied initialization is outside a mathematically proven coordinate interval derived from declared bounds and supported static rows by more than the absolute feasibility tolerance (or the comparison is unsupported), so it may be rejected, projected, or cause invalid expression evaluations.",
                evidence = [
                    _point_evidence(point),
                    Evidence(
                        "Initial values outside statically implied variable intervals";
                        details = vcat(group_details, [
                            "absolute_feasibility_tolerance" => string(feasibility_tolerance),
                            "severity_policy" => "exact coordinate excursion; error above tolerance, informational at or below tolerance",
                        ]),
                    ),
                ],
                suggested_actions = severity == SeverityInfo ? [
                    "Inspect exact-point domain and derivative findings before using this start.",
                    "Review the reported absolute tolerance in this variable's units; any start adjustment should respect model semantics.",
                ] : [
                    "Correct the initial values, declared bounds, or source rows that imply the interval.",
                    "Re-run exact-point domain and derivative checks after correction.",
                ],
                affected = EntityRef[
                    _variable_ref(records[variable]) for
                    variable in group
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
                observation = "$(length(boundary)) non-fixed variables start exactly on a finite statically implied interval boundary.",
                why_it_matters = "Interior-point methods generally move constrained variables into the interior, and implied boundaries can coincide with singular primitive derivatives such as sqrt at zero.",
                evidence = [
                    _point_evidence(point),
                    Evidence(
                        "Variables initialized on finite statically implied interval boundaries";
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

function _initialization_constraint_margin_findings(
    summary::ConstraintFeasibilitySummary,
)
    near_boundary = filter(
        activity -> activity.classification in
                    (:active_lower, :active_upper, :active_lower_upper),
        summary.activities,
    )
    isempty(near_boundary) && return Finding[]
    margins = String[]
    for activity in near_boundary
        if activity.classification == :active_lower
            push!(margins, "row $(activity.row): lower margin=$(activity.lower_margin)")
        elseif activity.classification == :active_upper
            push!(margins, "row $(activity.row): upper margin=$(activity.upper_margin)")
        else
            push!(margins, "row $(activity.row): both finite margins are near zero")
        end
    end
    return Finding[
        Finding(
            :initialization_near_constraint_boundary;
            severity = SeverityWarning,
            domain = NumericalIssue,
            basis = LocalInference,
            confidence = ConfidenceHigh,
            observation = "$(length(near_boundary)) inequality constraint row(s) start within the active-set tolerance of a finite boundary.",
            why_it_matters = "Boundary starts can immediately create an active set, leave little feasibility-restoration room, and make solver behavior sensitive to initialization perturbations.",
            evidence = [
                _point_evidence(summary.point),
                Evidence(
                    "Initialization constraint margins";
                    details = [
                        "rows" => join((activity.row for activity in near_boundary), ","),
                        "margins" => join(margins, "; "),
                        "active_tolerance" => summary.active_tolerance,
                    ],
                ),
            ],
            suggested_actions = [
                "Use an interior start where the model and solver semantics permit it.",
                "If the boundary is intentional, inspect the active-set LICQ finding at the same point.",
            ],
            affected = EntityRef[activity.source for activity in near_boundary],
        ),
    ]
end

"""Certify coordinate exclusions of a supplied start, without claiming model infeasibility."""
function _initialization_quadratic_geometry_findings(model_snapshot, point; equality::Bool)
    values = Dict(zip(point.variables, point.values))
    records = Dict(record.index => record for record in model_snapshot.variables)
    findings = Finding[]
    for constraint in model_snapshot.constraints
        result = if equality
            geometry = _positive_diagonal_quadratic_equality(constraint.function_value, constraint.set_value)
            isnothing(geometry) && (geometry = _nonlinear_positive_diagonal_equality(
                constraint.function_value, constraint.set_value))
            geometry
        else
            set = constraint.set_value
            set isa Union{MOI.LessThan,MOI.Interval} || continue
            upper = _exact_real_value(set.upper)
            isnothing(upper) && continue
            minimum = _positive_diagonal_quadratic_minimum(constraint.function_value)
            isnothing(minimum) && (minimum = _nonlinear_positive_diagonal_minimum(constraint.function_value))
            isnothing(minimum) && continue
            _diagonal_equality_from_minimum(minimum, upper, string(nameof(typeof(constraint.function_value))))
        end
        isnothing(result) && continue
        result.effective_level >= 0 || continue
        violated = MOI.VariableIndex[]
        details = Pair{String,Any}[
            "interval_certified" => true,
            "comparison" => "exact_squared_distance",
            "source_constraint" => _domain_constraint_origin_id(constraint),
            "center" => result.centers,
            "axis_squared" => result.axis_squared,
            "representation" => result.representation,
        ]
        for (variable, center, radius_squared) in zip(result.variables, result.centers, result.axis_squared)
            value = values[variable]
            lower_conflict, upper_conflict = _quadratic_coordinate_conflicts(
                (lower = value, upper = value), center, radius_squared)
            lower_conflict || upper_conflict || continue
            lower, upper = _quadratic_coordinate_bounds(center, radius_squared)
            push!(violated, variable)
            push!(details, "v$(variable.value)" =>
                "value=$value, center=$center, radius_squared=$radius_squared, enclosing_interval=[$lower, $upper]")
        end
        isempty(violated) && continue
        push!(findings, Finding(
            equality ? :initialization_diagonal_quadratic_equality_bound_violation : :initialization_diagonal_quadratic_bound_violation;
            severity = SeverityError,
            domain = MathematicalIssue,
            basis = MathematicalProof,
            confidence = ConfidenceCertain,
            observation = "$(length(violated)) initial coordinate value(s) violate an exact squared-distance restriction from quadratic constraint $(constraint.index.value).",
            why_it_matters = "The supplied start cannot satisfy this row. This proves exclusion of that start, not infeasibility of the model; the displayed outward interval is supporting enclosure evidence.",
            evidence = [_point_evidence(point), Evidence("Certified quadratic initialization exclusion"; details)],
            suggested_actions = ["Choose a start satisfying the row's coordinate restrictions, then check the full original constraint residual.",
                                 "Check the source row's level and units if the intended start was excluded."],
            affected = vcat([_constraint_ref(constraint)], [_variable_ref(records[v]) for v in violated]),
        ))
    end
    return findings
end

_initialization_diagonal_quadratic_bound_findings(model_snapshot::ModelSnapshot, point::EvaluationPoint) =
    _initialization_quadratic_geometry_findings(model_snapshot, point; equality = false)
_initialization_diagonal_quadratic_equality_bound_findings(model_snapshot::ModelSnapshot, point::EvaluationPoint) =
    _initialization_quadratic_geometry_findings(model_snapshot, point; equality = true)

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
    strict_domain_proximity_threshold::Union{Nothing,Real} = nothing,
    scale_ratio_threshold::Real = 1.0e6,
    component_scale_mismatch_factor::Real = 1.0e3,
    feasibility_tolerance::Real = sqrt(eps(Float64)),
    active_tolerance::Real = sqrt(eps(Float64)),
    check_degeneracy::Bool = true,
    expected_modes::Union{Nothing,AbstractVector{<:ExpectedNullspaceMode}} = nothing,
    check_component_ranks::Bool = true,
    components::AbstractVector{<:ComponentMetadata} = component_metadata(model),
    component_rank_relative_tolerance::Union{Nothing,Real} = nothing,
    component_rank_max_dense_entries::Integer = 4_000_000,
    degeneracy_nullspace_support_relative::Real = 0.1,
    degeneracy_nullspace_uniform_shift_correlation::Real = 0.98,
    degeneracy_nullspace_max_compact_support::Integer = 8,
    iterative_right_nullspace_probe_dimension::Union{Nothing,Integer} = nothing,
    iterative_right_nullspace_probe_iterations::Integer = 100,
    iterative_right_nullspace_probe_convergence_tolerance::Real = sqrt(eps(Float64)),
    iterative_right_nullspace_probe_residual_relative_tolerance::Real = sqrt(eps(Float64)),
    iterative_right_nullspace_probe_support_relative::Real = 0.1,
    iterative_left_nullspace_probe_dimension::Union{Nothing,Integer} = nothing,
    iterative_left_nullspace_probe_iterations::Integer = 100,
    iterative_left_nullspace_probe_convergence_tolerance::Real = sqrt(eps(Float64)),
    iterative_left_nullspace_probe_residual_relative_tolerance::Real = sqrt(eps(Float64)),
    iterative_left_nullspace_probe_support_relative::Real = 0.1,
    iterative_spectrum_probe_dimension::Union{Nothing,Integer} = nothing,
    iterative_spectrum_probe_iterations::Integer = 100,
    iterative_spectrum_probe_convergence_tolerance::Real = sqrt(eps(Float64)),
    iterative_spectrum_probe_spread_threshold::Real = 1.0e6,
    jacobian_rank_tolerance_sweep_tolerances::Union{Nothing,AbstractVector{<:Real}} = nothing,
    jacobian_rank_tolerance_sweep_scaling::Symbol = :none,
    jacobian_rank_tolerance_sweep_max_dense_entries::Integer = 4_000_000,
    coupled_qualification_strict_tolerance::Union{Nothing,Real} = nothing,
    coupled_qualification_max_iterations::Integer = 1_000,
)
    isfinite(feasibility_tolerance) && feasibility_tolerance >= 0 ||
        throw(ArgumentError("feasibility_tolerance must be finite and nonnegative"))
    variables = MOI.get(model, MOI.ListOfVariableIndices())
    starts = [_variable_start(model, variable) for variable in variables]
    missing_positions = findall(isnothing, starts)
    report = DiagnosticReport()
    report.metadata[:stage] = "initialization"
    report.metadata[:initialization_bound_absolute_tolerance] = string(feasibility_tolerance)
    report.metadata[:initialization_variable_count] = string(length(variables))
    report.metadata[:initialization_iterative_right_probe_requested] =
        string(!isnothing(iterative_right_nullspace_probe_dimension))
    report.metadata[:initialization_iterative_left_probe_requested] =
        string(!isnothing(iterative_left_nullspace_probe_dimension))
    report.metadata[:initialization_iterative_spectrum_probe_requested] =
        string(!isnothing(iterative_spectrum_probe_dimension))
    report.metadata[:initialization_jacobian_rank_tolerance_sweep_requested] =
        string(!isnothing(jacobian_rank_tolerance_sweep_tolerances))
    report.metadata[:coupled_qualification_max_iterations] =
        string(coupled_qualification_max_iterations)
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
        component_scale_mismatch_factor = component_scale_mismatch_factor,
        numeric_type = selected_numeric_type,
        strict_domain_proximity_threshold = strict_domain_proximity_threshold,
    )
    append!(report.findings, numerical.findings)
    merge!(report.metadata, numerical.metadata)
    report.metadata[:stage] = "initialization"
    evaluation = evaluate_numerical(model, point; cache = cache)
    if !isnothing(jacobian_rank_tolerance_sweep_tolerances)
        sweep_report = analyze_jacobian_rank_tolerance_sweep(
            evaluation;
            relative_tolerances = jacobian_rank_tolerance_sweep_tolerances,
            scaling = jacobian_rank_tolerance_sweep_scaling,
            max_dense_entries = jacobian_rank_tolerance_sweep_max_dense_entries,
        )
        append!(report.findings, sweep_report.findings)
        merge!(report.metadata, sweep_report.metadata)
    end
    if !isnothing(iterative_right_nullspace_probe_dimension)
        probe_report = analyze_iterative_right_nullspace_probe(
            evaluation;
            probe_dimension = iterative_right_nullspace_probe_dimension,
            iterations = iterative_right_nullspace_probe_iterations,
            convergence_tolerance = iterative_right_nullspace_probe_convergence_tolerance,
            residual_relative_tolerance = iterative_right_nullspace_probe_residual_relative_tolerance,
            support_relative = iterative_right_nullspace_probe_support_relative,
        )
        append!(report.findings, probe_report.findings)
        merge!(report.metadata, probe_report.metadata)
    end
    if !isnothing(iterative_left_nullspace_probe_dimension)
        probe_report = analyze_iterative_left_nullspace_probe(
            evaluation;
            probe_dimension = iterative_left_nullspace_probe_dimension,
            iterations = iterative_left_nullspace_probe_iterations,
            convergence_tolerance = iterative_left_nullspace_probe_convergence_tolerance,
            residual_relative_tolerance = iterative_left_nullspace_probe_residual_relative_tolerance,
            support_relative = iterative_left_nullspace_probe_support_relative,
        )
        append!(report.findings, probe_report.findings)
        merge!(report.metadata, probe_report.metadata)
    end
    if !isnothing(iterative_spectrum_probe_dimension)
        probe_report = analyze_iterative_jacobian_spectrum_probe(
            evaluation;
            probe_dimension = iterative_spectrum_probe_dimension,
            iterations = iterative_spectrum_probe_iterations,
            convergence_tolerance = iterative_spectrum_probe_convergence_tolerance,
            spectral_spread_threshold = iterative_spectrum_probe_spread_threshold,
        )
        append!(report.findings, probe_report.findings)
        merge!(report.metadata, probe_report.metadata)
    end
    if check_degeneracy
        degeneracy_keywords = (
            nullspace_support_relative = degeneracy_nullspace_support_relative,
            nullspace_uniform_shift_correlation =
                degeneracy_nullspace_uniform_shift_correlation,
            nullspace_max_compact_support = degeneracy_nullspace_max_compact_support,
        )
        degeneracy_report = isnothing(expected_modes) ?
                            analyze_degeneracy(model, evaluation; degeneracy_keywords...) :
                            analyze_degeneracy(
            model,
            evaluation;
            degeneracy_keywords...,
            expected_modes = expected_modes,
        )
        append!(report.findings, degeneracy_report.findings)
        merge!(report.metadata, degeneracy_report.metadata)
    end
    if check_component_ranks
        component_rank_report = analyze_component_ranks(
            model,
            evaluation;
            components = components,
            relative_tolerance = isnothing(component_rank_relative_tolerance) ?
                                 max(length(evaluation.point.variables), 1) *
                                 eps(eltype(evaluation.point.values)) :
                                 component_rank_relative_tolerance,
            max_dense_entries = component_rank_max_dense_entries,
        )
        append!(report.findings, component_rank_report.findings)
        merge!(report.metadata, component_rank_report.metadata)
    end
    summary = constraint_feasibility_summary(
        model,
        evaluation;
        feasibility_tolerance = feasibility_tolerance,
        active_tolerance = active_tolerance,
    )
    active_report = analyze_active_set(
        model,
        evaluation;
        feasibility_tolerance = feasibility_tolerance,
        active_tolerance = active_tolerance,
        coupled_qualification_strict_tolerance =
            isnothing(coupled_qualification_strict_tolerance) ?
            sqrt(eps(eltype(evaluation.point.values))) :
            coupled_qualification_strict_tolerance,
        coupled_qualification_max_iterations = coupled_qualification_max_iterations,
    )
    append!(report.findings, active_report.findings)
    append!(report.findings, _initialization_constraint_margin_findings(summary))
    merge!(report.metadata, active_report.metadata)
    report.metadata[:initialization_constraint_activity_complete] =
        string(summary.complete)
    report.metadata[:initialization_active_row_count] =
        string(length(active_constraint_rows(summary)))
    report.metadata[:initialization_degeneracy_checked] = string(check_degeneracy)
    report.metadata[:initialization_component_ranks_checked] =
        string(check_component_ranks)
    report.metadata[:stage] = "initialization"
    append!(
        report.findings,
        _initialization_bound_findings(snapshot(model), point;
            feasibility_tolerance = feasibility_tolerance),
    )
    append!(
        report.findings,
        _initialization_diagonal_quadratic_bound_findings(snapshot(model), point),
    )
    append!(
        report.findings,
        _initialization_diagonal_quadratic_equality_bound_findings(
            snapshot(model),
            point,
        ),
    )
    sort!(
        report.findings;
        by = finding -> (-Int(finding.severity), string(finding.code)),
    )
    return report
end
