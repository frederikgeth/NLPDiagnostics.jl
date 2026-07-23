# Stage 1 analyses make no calls to user functions or derivative evaluators.
mutable struct _BoundState
    lower::Vector{Tuple{Float64,EntityRef}}
    upper::Vector{Tuple{Float64,EntityRef}}
end

_BoundState() = _BoundState(Tuple{Float64,EntityRef}[], Tuple{Float64,EntityRef}[])

function _record_bounds!(
    state::_BoundState,
    set_value,
    reference::EntityRef,
)
    if set_value isa MOI.GreaterThan
        push!(state.lower, (Float64(set_value.lower), reference))
    elseif set_value isa MOI.LessThan
        push!(state.upper, (Float64(set_value.upper), reference))
    elseif set_value isa MOI.EqualTo
        value = Float64(set_value.value)
        push!(state.lower, (value, reference))
        push!(state.upper, (value, reference))
    elseif set_value isa MOI.Interval
        push!(state.lower, (Float64(set_value.lower), reference))
        push!(state.upper, (Float64(set_value.upper), reference))
    end
    return
end

function _bound_states(model::ModelSnapshot)
    states = Dict(record.index => _BoundState() for record in model.variables)
    for constraint in model.constraints
        constraint.function_value isa MOI.VariableIndex || continue
        state = get!(states, constraint.function_value, _BoundState())
        _record_bounds!(state, constraint.set_value, _constraint_ref(constraint))
    end
    return states
end

function _analyze_bounds!(report::DiagnosticReport, model::ModelSnapshot)
    records = Dict(record.index => record for record in model.variables)
    for (variable, state) in _bound_states(model)
        record = records[variable]
        variable_ref = _variable_ref(record)
        lower = isempty(state.lower) ? -Inf : maximum(first, state.lower)
        upper = isempty(state.upper) ? Inf : minimum(first, state.upper)
        bound_refs = EntityRef[last(item) for item in vcat(state.lower, state.upper)]

        if lower > upper
            push!(
                report,
                Finding(
                    :inconsistent_variable_bounds;
                    severity = SeverityError,
                    domain = MathematicalIssue,
                    basis = MathematicalProof,
                    confidence = ConfidenceCertain,
                    observation = "Variable $(_display_name(record)) has lower bound $lower above upper bound $upper.",
                    why_it_matters = "No value of this variable can satisfy all of its bounds, so the model is infeasible.",
                    evidence = [
                        Evidence(
                            "Intersection of the recorded bounds is empty";
                            details = ["effective_lower" => lower, "effective_upper" => upper],
                        ),
                    ],
                    suggested_actions = [
                        "Inspect the bound sources and correct the contradictory value.",
                        "Check unit conversions and parameter data used to construct bounds.",
                    ],
                    affected = vcat([variable_ref], bound_refs),
                ),
            )
        elseif isfinite(lower) && lower == upper
            push!(
                report,
                Finding(
                    :fixed_variable;
                    severity = SeverityInfo,
                    domain = RepresentationalIssue,
                    basis = MathematicalProof,
                    confidence = ConfidenceCertain,
                    observation = "Variable $(_display_name(record)) is fixed at $lower.",
                    why_it_matters = "Fixed variables are valid, but unexpected fixing can remove a degree of freedom or conceal conflicting data.",
                    evidence = [
                        Evidence(
                            "Effective lower and upper bounds are equal";
                            details = ["value" => lower],
                        ),
                    ],
                    suggested_actions = [
                        "Confirm that the variable is intentionally fixed.",
                    ],
                    affected = vcat([variable_ref], bound_refs),
                ),
            )
        end

        if length(state.lower) > 1 || length(state.upper) > 1
            push!(
                report,
                Finding(
                    :multiple_variable_bounds;
                    severity = SeverityInfo,
                    domain = RepresentationalIssue,
                    basis = StructuralProof,
                    confidence = ConfidenceCertain,
                    observation = "Variable $(_display_name(record)) receives bounds from multiple constraints.",
                    why_it_matters = "Layered bounds may be intentional, but redundant or unexpectedly stronger bounds often indicate duplicated model construction.",
                    evidence = [
                        Evidence(
                            "Multiple bound sources were found";
                            details = [
                                "lower_sources" => length(state.lower),
                                "upper_sources" => length(state.upper),
                            ],
                        ),
                    ],
                    suggested_actions = [
                        "Inspect each bound source and retain layered bounds only when they are intentional.",
                    ],
                    affected = vcat([variable_ref], bound_refs),
                ),
            )
        end
    end
    return
end

_display_name(record::VariableRecord) =
    isnothing(record.name) ? "v$(record.index.value)" : "'$(record.name)'"

function _analyze_disconnected_variables!(
    report::DiagnosticReport,
    model::ModelSnapshot,
    graph::IncidenceGraph,
)
    objective_support = isnothing(model.objective) ?
                        VariableSupport() :
                        variable_support(model.objective.function_value)
    if !objective_support.complete || !graph.complete
        unsupported_types = sort!(
            unique!(
                vcat(
                    graph.unsupported_types,
                    objective_support.unsupported_types,
                ),
            ),
        )
        affected = EntityRef[]
        for row in graph.constraint_nodes
            variable_support(row.function_value).complete && continue
            push!(
                affected,
                _constraint_ref(row.constraint; row = row.row),
            )
        end
        push!(
            report,
            Finding(
                :variable_incidence_analysis_unavailable;
                severity = SeverityInfo,
                domain = RepresentationalIssue,
                basis = StructuralProof,
                confidence = ConfidenceCertain,
                observation = "Disconnected-variable analysis was skipped because complete symbolic incidence is unavailable for a model source or function type.",
                why_it_matters = "Reporting disconnected variables without complete incidence information could create false positives.",
                evidence = [
                    Evidence(
                        "Opaque sources or unsupported function types were encountered";
                        details = [
                            "types" => join(sort!(unsupported_types), ", "),
                        ],
                    ),
                ],
                suggested_actions = [
                    "Provide an expression graph or register variable extraction support for the listed source.",
                ],
                affected = affected,
            ),
        )
        return
    end

    used = Set(objective_support.variables)
    for (position, constraints) in enumerate(graph.variable_to_constraints)
        isempty(constraints) && continue
        push!(used, graph.variables[position].index)
    end
    for record in model.variables
        record.index in used && continue
        push!(
            report,
            Finding(
                :disconnected_variable;
                severity = SeverityWarning,
                domain = RepresentationalIssue,
                basis = StructuralProof,
                confidence = ConfidenceCertain,
                observation = "Variable $(_display_name(record)) does not occur in the objective or any non-domain constraint.",
                why_it_matters = "The variable cannot affect the modeled equations or objective and may represent an omitted equation or unused declaration.",
                evidence = [
                    Evidence("No incidence edge was found for this variable"),
                ],
                suggested_actions = [
                    "Remove the variable if it is unused.",
                    "Otherwise, inspect model construction for a missing constraint or objective term.",
                ],
                affected = [_variable_ref(record)],
            ),
        )
    end
    return
end

_constant_value(value::Real) = (true, value, nothing)
_constant_value(value::MOI.VariableIndex) = (false, nothing, nothing)

function _constant_value(value::MOI.ScalarAffineFunction)
    all(term -> iszero(term.coefficient), value.terms) ||
        return (false, nothing, nothing)
    return (true, value.constant, nothing)
end

function _constant_value(value::MOI.ScalarQuadraticFunction)
    all(term -> iszero(term.coefficient), value.affine_terms) ||
        return (false, nothing, nothing)
    all(term -> iszero(term.coefficient), value.quadratic_terms) ||
        return (false, nothing, nothing)
    return (true, value.constant, nothing)
end

function _constant_value(value::MOI.ScalarNonlinearFunction)
    values = Any[]
    for argument in value.args
        is_constant, result, exception = _constant_value(argument)
        exception === nothing || return (true, nothing, exception)
        is_constant || return (false, nothing, nothing)
        push!(values, result)
    end
    try
        return (true, _apply_constant_operator(value.head, values), nothing)
    catch exception
        return (true, nothing, exception)
    end
end

_constant_value(value) = (false, nothing, nothing)

function _apply_constant_operator(head::Symbol, values::Vector{Any})
    head == :+ && return +(values...)
    head == :- && return -(values...)
    head == :* && return *(values...)
    head == :/ && return /(values...)
    head == :^ && return ^(values...)
    head == :sqrt && return sqrt(only(values))
    head == :log && return log(only(values))
    head == :log10 && return log10(only(values))
    head == :exp && return exp(only(values))
    head == :sin && return sin(only(values))
    head == :cos && return cos(only(values))
    head == :tan && return tan(only(values))
    head == :abs && return abs(only(values))
    head == :min && return min(values...)
    head == :max && return max(values...)
    throw(ArgumentError("constant evaluation does not support operator :$head"))
end

_satisfies(value, set::MOI.LessThan) = value <= set.upper
_satisfies(value, set::MOI.GreaterThan) = value >= set.lower
_satisfies(value, set::MOI.EqualTo) = value == set.value
_satisfies(value, set::MOI.Interval) = set.lower <= value <= set.upper
_satisfies(value, set) = nothing

function _analyze_constant_constraints!(
    report::DiagnosticReport,
    model::ModelSnapshot,
)
    for constraint in model.constraints
        support = variable_support(constraint.function_value)
        support.complete || continue
        isempty(support.variables) || continue
        is_constant, value, exception = _constant_value(constraint.function_value)
        is_constant || continue
        reference = _constraint_ref(constraint)

        if exception !== nothing &&
           (exception isa DomainError || exception isa DivideError)
            push!(
                report,
                Finding(
                    :constant_domain_violation;
                    severity = SeverityError,
                    domain = MathematicalIssue,
                    basis = MathematicalProof,
                    confidence = ConfidenceCertain,
                    observation = "A constant expression in constraint $(reference.index) is outside an operator domain.",
                    why_it_matters = "The expression cannot be evaluated over the real numbers, independently of the solver or starting point.",
                    evidence = [
                        Evidence(
                            "Constant evaluation failed";
                            details = [
                                "exception" => nameof(typeof(exception)),
                                "message" => sprint(showerror, exception),
                            ],
                        ),
                    ],
                    suggested_actions = [
                        "Correct the constant data or the expression domain.",
                    ],
                    affected = [reference],
                ),
            )
            continue
        end

        exception === nothing || continue
        satisfied = _satisfies(value, constraint.set_value)
        satisfied === nothing && continue
        if satisfied
            push!(
                report,
                Finding(
                    :redundant_constant_constraint;
                    severity = SeverityInfo,
                    domain = RepresentationalIssue,
                    basis = MathematicalProof,
                    confidence = ConfidenceCertain,
                    observation = "Constraint $(reference.index) is constant and always satisfied.",
                    why_it_matters = "The constraint has no effect on the feasible set and may indicate a lost variable dependency.",
                    evidence = [
                        Evidence(
                            "The constant belongs to the constraint set";
                            details = [
                                "value" => value,
                                "set" => constraint.set_value,
                            ],
                        ),
                    ],
                    suggested_actions = [
                        "Remove it if intentional, or inspect expression construction for a missing variable.",
                    ],
                    affected = [reference],
                ),
            )
        else
            push!(
                report,
                Finding(
                    :infeasible_constant_constraint;
                    severity = SeverityError,
                    domain = MathematicalIssue,
                    basis = MathematicalProof,
                    confidence = ConfidenceCertain,
                    observation = "Constraint $(reference.index) is constant and cannot be satisfied.",
                    why_it_matters = "This single constraint proves that the model is infeasible.",
                    evidence = [
                        Evidence(
                            "The constant does not belong to the constraint set";
                            details = [
                                "value" => value,
                                "set" => constraint.set_value,
                            ],
                        ),
                    ],
                    suggested_actions = [
                        "Correct the constant data, set, or omitted variable dependency.",
                    ],
                    affected = [reference],
                ),
            )
        end
    end
    return
end

_fingerprint(value::Real) = "number($(repr(value)))"
_fingerprint(value::MOI.VariableIndex) = "variable($(value.value))"

function _fingerprint(value::MOI.ScalarAffineFunction)
    coefficients = Dict{Int,Any}()
    for term in value.terms
        coefficients[term.variable.value] =
            get(coefficients, term.variable.value, zero(term.coefficient)) +
            term.coefficient
    end
    terms = sort!(
        filter(term -> !iszero(last(term)), collect(coefficients));
        by = first,
    )
    return "affine($(repr(value.constant));$(repr(terms)))"
end

function _fingerprint(value::MOI.ScalarQuadraticFunction)
    affine = _fingerprint(
        MOI.ScalarAffineFunction(value.affine_terms, value.constant),
    )
    coefficients = Dict{Tuple{Int,Int},Any}()
    for term in value.quadratic_terms
        key = minmax(term.variable_1.value, term.variable_2.value)
        coefficients[key] =
            get(coefficients, key, zero(term.coefficient)) + term.coefficient
    end
    terms = sort!(
        filter(term -> !iszero(last(term)), collect(coefficients));
        by = first,
    )
    return "quadratic($affine;$(repr(terms)))"
end

function _fingerprint(value::MOI.ScalarNonlinearFunction)
    arguments = join((_fingerprint(argument) for argument in value.args), ",")
    return "nonlinear($(value.head);$arguments)"
end

_fingerprint(value) = repr(value)
_constraint_fingerprint(record::ConstraintRecord) =
    _fingerprint(record.function_value) * "::" * repr(record.set_value)

function _analyze_duplicate_constraints!(
    report::DiagnosticReport,
    model::ModelSnapshot,
)
    groups = Dict{String,Vector{ConstraintRecord}}()
    for constraint in model.constraints
        _is_variable_domain_constraint(constraint) && continue
        push!(
            get!(groups, _constraint_fingerprint(constraint), ConstraintRecord[]),
            constraint,
        )
    end
    for constraints in values(groups)
        length(constraints) > 1 || continue
        references = _constraint_ref.(constraints)
        indices = join((reference.index for reference in references), ", ")
        push!(
            report,
            Finding(
                :duplicate_constraint;
                severity = SeverityWarning,
                domain = RepresentationalIssue,
                basis = StructuralProof,
                confidence = ConfidenceCertain,
                observation = "Constraints $indices have identical canonical functions and sets.",
                why_it_matters = "Duplicate equations can create dependent Jacobian rows and non-unique multipliers.",
                evidence = [
                    Evidence(
                        "Exact canonical duplicates were found";
                        details = ["count" => length(constraints)],
                    ),
                ],
                suggested_actions = [
                    "Remove accidental duplicates.",
                    "If intentional, annotate or reformulate them before interpreting multiplier degeneracy.",
                ],
                affected = references,
            ),
        )
    end
    return
end

function _unit_circle_radius_squared(function_value, set_value)
    function_value isa MOI.ScalarQuadraticFunction || return nothing
    set_value isa MOI.EqualTo || return nothing
    isempty(function_value.affine_terms) || return nothing
    coefficients = Float64[]
    variables = MOI.VariableIndex[]
    for term in function_value.quadratic_terms
        term.variable_1 == term.variable_2 || return nothing
        coefficient = Float64(term.coefficient)
        coefficient > 0 || return nothing
        push!(coefficients, coefficient)
        push!(variables, term.variable_1)
    end
    length(coefficients) >= 2 || return nothing
    length(unique(variables)) == length(variables) || return nothing
    all(coefficient -> coefficient == first(coefficients), coefficients) ||
        return nothing
    # MOI's diagonal quadratic coefficient represents coefficient / 2 * x^2.
    radius_squared =
        2 * (Float64(set_value.value) - Float64(function_value.constant)) /
        first(coefficients)
    radius_squared > 0 || return nothing
    return radius_squared, variables
end

function _analyze_circular_normalization!(
    report::DiagnosticReport,
    model::ModelSnapshot;
    unit_radius_tolerance::Real = 1.0e-6,
)
    records = Dict(record.index => record for record in model.variables)
    for constraint in model.constraints
        result = _unit_circle_radius_squared(
            constraint.function_value,
            constraint.set_value,
        )
        isnothing(result) && continue
        radius_squared, variables = result
        isapprox(radius_squared, 1.0; rtol = unit_radius_tolerance, atol = unit_radius_tolerance) &&
            continue
        radius = sqrt(radius_squared)
        affected = [_constraint_ref(constraint)]
        append!(
            affected,
            [_variable_ref(records[variable]) for variable in variables],
        )
        push!(
            report,
            Finding(
                :nonunit_circular_constraint_radius;
                severity = SeverityInfo,
                domain = RepresentationalIssue,
                basis = HeuristicInterpretation,
                confidence = ConfidenceMedium,
                observation = "An unshifted circular equality has inferred radius $radius (radius squared $radius_squared), rather than approximately one.",
                why_it_matters = "This is mathematically valid, but non-unit radii can obscure per-unit assumptions and alter derivative and tolerance scales.",
                evidence = [
                    Evidence(
                        "Recognized isotropic quadratic equality";
                        details = [
                            "variable_count" => length(variables),
                            "radius" => radius,
                            "radius_squared" => radius_squared,
                            "unit_radius_tolerance" => unit_radius_tolerance,
                        ],
                    ),
                ],
                suggested_actions = [
                    "Confirm that the radius carries intended physical units rather than an omitted normalization.",
                    "If a unit-circle formulation was intended, rescale the coordinates and document the resulting tolerance semantics.",
                ],
                affected = affected,
            ),
        )
    end
    return
end

function analyze_static(
    model::ModelSnapshot;
    graph::IncidenceGraph = incidence_graph(model),
)
    report = DiagnosticReport()
    report.metadata[:stage] = "static"
    report.metadata[:model_name] =
        isnothing(model.model_name) ? "" : model.model_name
    report.metadata[:variable_count] = string(length(model.variables))
    report.metadata[:constraint_count] = string(length(model.constraints))

    _analyze_bounds!(report, model)
    _analyze_constant_constraints!(report, model)
    _analyze_duplicate_constraints!(report, model)
    _analyze_circular_normalization!(report, model)
    _analyze_disconnected_variables!(report, model, graph)
    sort!(
        report.findings;
        by = finding -> (-Int(finding.severity), string(finding.code)),
    )
    return report
end

analyze_static(model::MOI.ModelLike) = analyze_static(snapshot(model))
