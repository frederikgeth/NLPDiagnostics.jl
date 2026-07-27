# Stage 1 analyses make no calls to user functions or derivative evaluators.

function _analyze_bounds!(report::DiagnosticReport, model::ModelSnapshot)
    records = Dict(record.index => record for record in model.variables)
    for domain in variable_domains(model)
        record = records[domain.variable]
        variable_ref = _variable_ref(record)
        lower, upper = domain.lower, domain.upper
        bound_refs = vcat(domain.lower_sources, domain.upper_sources)

        has_nan_bound = (!isnothing(lower) && lower isa AbstractFloat && isnan(lower)) ||
                        (!isnothing(upper) && upper isa AbstractFloat && isnan(upper))
        if has_nan_bound
            push!(report, Finding(
                :nan_variable_bound;
                severity = SeverityError,
                domain = MathematicalIssue,
                basis = MathematicalProof,
                confidence = ConfidenceCertain,
                observation = "Variable $(_display_name(record)) has a NaN effective bound.",
                why_it_matters = "NaN does not define an ordered domain endpoint, so bound-based feasibility and structural-role conclusions are invalid.",
                evidence = [Evidence("Effective scalar-bound intersection";
                    details = ["effective_lower" => lower, "effective_upper" => upper],
                )],
                suggested_actions = ["Trace the bound data source and replace NaN with a valid finite value or an intentional unbounded side."],
                affected = vcat([variable_ref], bound_refs),
            ))
        elseif !isnothing(lower) && !isnothing(upper) && lower > upper
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
        elseif !isnothing(lower) && !isnothing(upper) && lower == upper
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

        if length(domain.lower_sources) > 1 || length(domain.upper_sources) > 1
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
                            "lower_sources" => length(domain.lower_sources),
                            "upper_sources" => length(domain.upper_sources),
                            "effective_lower_sources" => length(domain.effective_lower_sources),
                            "effective_upper_sources" => length(domain.effective_upper_sources),
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
        shadowed_lower = setdiff(domain.lower_sources, domain.effective_lower_sources)
        shadowed_upper = setdiff(domain.upper_sources, domain.effective_upper_sources)
        if !isempty(shadowed_lower) || !isempty(shadowed_upper)
            push!(report, Finding(
                :dominated_variable_bound;
                severity = SeverityInfo,
                domain = RepresentationalIssue,
                basis = MathematicalProof,
                confidence = ConfidenceCertain,
                observation = "Variable $(_display_name(record)) has $(length(shadowed_lower) + length(shadowed_upper)) scalar bound source(s) dominated by a stricter bound.",
                why_it_matters = "The dominated bound does not change the current scalar domain intersection; it may be intentional documentation, but can also conceal duplicated or stale data.",
                evidence = [Evidence(
                    "Effective scalar-bound intersection";
                    details = ["effective_lower" => lower, "effective_upper" => upper,
                               "shadowed_lower_sources" => length(shadowed_lower),
                               "shadowed_upper_sources" => length(shadowed_upper)],
                )],
                suggested_actions = ["Retain dominated bounds only when their separate provenance is useful to the model reader."],
                affected = vcat([variable_ref], shadowed_lower, shadowed_upper),
            ))
        end
    end
    return
end

function _analyze_disjunctive_variable_domains!(report::DiagnosticReport, model::ModelSnapshot)
    records = Dict(record.index => record for record in model.variables)
    for constraint in model.constraints
        variable = constraint.function_value
        variable isa MOI.VariableIndex || continue
        set_value = constraint.set_value
        set_value isa Union{MOI.Semicontinuous,MOI.Semiinteger} || continue
        record = records[variable]
        push!(report, Finding(
            :disjunctive_variable_domain;
            severity = SeverityInfo,
            domain = RepresentationalIssue,
            basis = StructuralProof,
            confidence = ConfidenceCertain,
            observation = "Variable $(_display_name(record)) has a $(set_value isa MOI.Semicontinuous ? "semicontinuous" : "semiinteger") domain.",
            why_it_matters = "Its finite endpoints do not form an ordinary interval because zero remains feasible; generic scalar-bound and free-variable reasoning deliberately do not collapse this disjunction.",
            evidence = [Evidence("Declared MOI variable domain";
                details = ["set" => typeof(set_value), "lower" => set_value.lower, "upper" => set_value.upper],
            )],
            suggested_actions = ["Use a mixed-integer-aware plugin or solver workflow when interpreting structural freedom."],
            affected = [_variable_ref(record), _constraint_ref(constraint)],
        ))
    end
    return
end

function _analyze_discrete_variables!(report::DiagnosticReport, model::ModelSnapshot)
    records = Dict(record.index => record for record in model.variables)
    domains = Dict(domain.variable => domain for domain in variable_domains(model))
    for constraint in model.constraints
        variable = constraint.function_value
        variable isa MOI.VariableIndex || continue
        constraint.set_value isa Union{MOI.Integer,MOI.ZeroOne} || continue
        record = records[variable]
        push!(report, Finding(:discrete_variable_domain;
            severity = SeverityInfo, domain = RepresentationalIssue,
            basis = StructuralProof, confidence = ConfidenceCertain,
            observation = "Variable $(_display_name(record)) has a $(constraint.set_value isa MOI.ZeroOne ? "binary" : "integer") domain.",
            why_it_matters = "Continuous Jacobian matching does not treat a discrete variable as a local continuous degree of freedom.",
            evidence = [Evidence("Declared MOI integrality set"; details = ["set" => typeof(constraint.set_value)])],
            suggested_actions = ["Use a MINLP-aware solver or plugin when interpreting this variable's discrete search semantics."],
            affected = [_variable_ref(record), _constraint_ref(constraint)],
        ))
        domain = domains[variable]
        empty_discrete_domain = if isnothing(domain.lower) || isnothing(domain.upper)
            false
        elseif constraint.set_value isa MOI.ZeroOne
            !(domain.lower <= 0 <= domain.upper || domain.lower <= 1 <= domain.upper)
        else
            ceil(domain.lower) > floor(domain.upper)
        end
        if empty_discrete_domain
            push!(report, Finding(:empty_discrete_variable_domain;
                severity = SeverityError, domain = MathematicalIssue,
                basis = MathematicalProof, confidence = ConfidenceCertain,
                observation = "Discrete variable $(_display_name(record)) has no admissible value in its effective scalar interval [$((domain.lower)), $((domain.upper))].",
                why_it_matters = "The continuous bounds exclude every value allowed by the integer or binary declaration.",
                evidence = [Evidence("Intersection of scalar and discrete domains";
                    details = ["lower" => domain.lower, "upper" => domain.upper,
                               "set" => typeof(constraint.set_value)],
                )],
                suggested_actions = ["Relax the scalar bounds or correct the discrete declaration."],
                affected = [_variable_ref(record), _constraint_ref(constraint)],
            ))
        end
        fixed_value = !isnothing(domain.lower) && !isnothing(domain.upper) &&
                      domain.lower == domain.upper ? domain.lower : nothing
        invalid_fixed_value = if isnothing(fixed_value)
            false
        elseif constraint.set_value isa MOI.ZeroOne
            fixed_value != 0 && fixed_value != 1
        else
            !isinteger(fixed_value)
        end
        invalid_fixed_value || continue
        push!(report, Finding(:nonintegral_discrete_fixed_value;
            severity = SeverityError, domain = MathematicalIssue,
            basis = MathematicalProof, confidence = ConfidenceCertain,
            observation = "Discrete variable $(_display_name(record)) is fixed at $fixed_value, outside its declared discrete domain.",
            why_it_matters = "No value can satisfy both the fixed scalar domain and the declared integer or binary requirement.",
            evidence = [Evidence("Intersection of fixed and discrete declarations";
                details = ["fixed_value" => fixed_value, "set" => typeof(constraint.set_value)],
            )],
            suggested_actions = ["Correct the fixed value or remove the incompatible discrete declaration."],
            affected = [_variable_ref(record), _constraint_ref(constraint)],
        ))
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

function _scalar_set_interval(set_value)
    if set_value isa MOI.EqualTo
        return set_value.value, set_value.value
    elseif set_value isa MOI.LessThan
        return nothing, set_value.upper
    elseif set_value isa MOI.GreaterThan
        return set_value.lower, nothing
    elseif set_value isa MOI.Interval
        return set_value.lower, set_value.upper
    end
    return nothing
end

function _interval_contains(outer, inner)
    outer_lower, outer_upper = outer
    inner_lower, inner_upper = inner
    lower_contains = isnothing(outer_lower) ||
                     (!isnothing(inner_lower) && outer_lower <= inner_lower)
    upper_contains = isnothing(outer_upper) ||
                     (!isnothing(inner_upper) && outer_upper >= inner_upper)
    return lower_contains && upper_contains
end

"""Find repeated scalar expressions whose declared scalar sets differ."""
function _analyze_reused_constraint_expressions!(
    report::DiagnosticReport,
    model::ModelSnapshot,
)
    groups = Dict{String,Vector{ConstraintRecord}}()
    for constraint in model.constraints
        _is_variable_domain_constraint(constraint) && continue
        constraint.function_value isa MOI.AbstractScalarFunction || continue
        push!(get!(groups, _fingerprint(constraint.function_value), ConstraintRecord[]), constraint)
    end
    for constraints in values(groups)
        length(constraints) > 1 || continue
        set_fingerprints = unique(repr(constraint.set_value) for constraint in constraints)
        length(set_fingerprints) > 1 || continue
        intervals = [_scalar_set_interval(constraint.set_value) for constraint in constraints]
        all(interval -> !isnothing(interval), intervals) || continue
        lowers = Any[interval[1] for interval in intervals if !isnothing(interval[1])]
        uppers = Any[interval[2] for interval in intervals if !isnothing(interval[2])]
        lower = isempty(lowers) ? nothing : maximum(lowers)
        upper = isempty(uppers) ? nothing : minimum(uppers)
        references = _constraint_ref.(constraints)
        indices = join((reference.index for reference in references), ", ")
        if !isnothing(lower) && !isnothing(upper) && lower > upper
            push!(report, Finding(
                :inconsistent_reused_expression_sets;
                severity = SeverityError,
                domain = MathematicalIssue,
                basis = MathematicalProof,
                confidence = ConfidenceCertain,
                observation = "Constraints $indices apply incompatible scalar sets to the same canonical expression.",
                why_it_matters = "Their scalar-set intersection is empty, so no value of the shared expression can satisfy every constraint.",
                evidence = [Evidence("Intersection of scalar sets on one canonical expression";
                    details = ["effective_lower" => lower,
                               "effective_upper" => upper,
                               "constraint_count" => length(constraints)],
                )],
                suggested_actions = ["Correct the conflicting right-hand sides or remove the unintended repeated expression."],
                affected = references,
            ))
        else
            push!(report, Finding(
                :reused_constraint_expression;
                severity = SeverityInfo,
                domain = RepresentationalIssue,
                basis = StructuralProof,
                confidence = ConfidenceCertain,
                observation = "Constraints $indices reuse one canonical scalar expression with different scalar sets.",
                why_it_matters = "This may be an intentional paired or layered bound, but it also makes equation reuse and set intersection explicit for presolve and degeneracy review.",
                evidence = [Evidence("Shared canonical expression";
                    details = ["constraint_count" => length(constraints),
                               "effective_lower" => lower,
                               "effective_upper" => upper],
                )],
                suggested_actions = ["Confirm that the shared expression and separate set semantics are intentional."],
                affected = references,
            ))
            dominated = ConstraintRecord[]
            for index in eachindex(constraints)
                others = [intervals[other] for other in eachindex(intervals) if other != index]
                other_lowers = Any[
                    interval[1] for interval in others if !isnothing(interval[1])
                ]
                other_uppers = Any[
                    interval[2] for interval in others if !isnothing(interval[2])
                ]
                other_interval = (
                    isempty(other_lowers) ? nothing : maximum(other_lowers),
                    isempty(other_uppers) ? nothing : minimum(other_uppers),
                )
                _interval_contains(intervals[index], other_interval) || continue
                intervals[index] == other_interval && continue
                push!(dominated, constraints[index])
            end
            if !isempty(dominated)
                dominated_references = _constraint_ref.(dominated)
                push!(report, Finding(
                    :dominated_reused_expression_set;
                    severity = SeverityInfo,
                    domain = RepresentationalIssue,
                    basis = MathematicalProof,
                    confidence = ConfidenceCertain,
                    observation = "$(length(dominated)) scalar set(s) on a reused canonical expression are implied by the remaining set intersection.",
                    why_it_matters = "These sets do not further restrict the shared expression and may be stale, duplicated, or intentional provenance.",
                    evidence = [Evidence("Repeated-expression set intersection";
                        details = ["effective_lower" => lower,
                                   "effective_upper" => upper,
                                   "dominated_constraint_count" => length(dominated)],
                    )],
                    suggested_actions = ["Remove redundant sets when their separate provenance is not needed."],
                    affected = dominated_references,
                ))
            end
        end
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
    _analyze_disjunctive_variable_domains!(report, model)
    _analyze_discrete_variables!(report, model)
    _analyze_constant_constraints!(report, model)
    _analyze_duplicate_constraints!(report, model)
    _analyze_reused_constraint_expressions!(report, model)
    _analyze_circular_normalization!(report, model)
    _analyze_disconnected_variables!(report, model, graph)
    sort!(
        report.findings;
        by = finding -> (-Int(finding.severity), string(finding.code)),
    )
    return report
end

analyze_static(model::MOI.ModelLike) = analyze_static(snapshot(model))
