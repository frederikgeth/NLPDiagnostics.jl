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
    isempty(_canonical_affine_terms(value.terms)) || return (false, nothing, nothing)
    return (true, value.constant, nothing)
end

function _constant_value(value::MOI.ScalarQuadraticFunction)
    isempty(_canonical_affine_terms(value.affine_terms)) || return (false, nothing, nothing)
    isempty(_canonical_quadratic_terms(value.quadratic_terms)) || return (false, nothing, nothing)
    return (true, value.constant, nothing)
end

function _constant_value(value::MOI.ScalarNonlinearFunction)
    _is_direct_variable_cancellation(value) && return (true, 0, nothing)
    _is_direct_zero_product(value) && return (true, 0, nothing)
    values = Any[]
    for argument in value.args
        is_constant, result, exception = _constant_value(argument)
        exception === nothing || return (true, nothing, exception)
        is_constant || return (false, nothing, nothing)
        push!(values, result)
    end
    try
        return (true, fixed_operator_value(Val(value.head), values), nothing)
    catch exception
        return (true, nothing, exception)
    end
end

_constant_value(value) = (false, nothing, nothing)

"""Evaluate a supported scalar expression after exact fixed-value substitution."""
_fixed_expression_value(value::Real, _) = (true, value, nothing)

function _fixed_expression_value(
    value::MOI.VariableIndex,
    fixed_values::Dict{MOI.VariableIndex,Any},
)
    haskey(fixed_values, value) || return (false, nothing, nothing)
    return (true, fixed_values[value], nothing)
end

function _fixed_expression_value(
    value::MOI.ScalarAffineFunction,
    fixed_values::Dict{MOI.VariableIndex,Any},
)
    result = value.constant
    for (variable, coefficient) in _canonical_affine_terms(value.terms)
        is_fixed, variable_value, exception = _fixed_expression_value(variable, fixed_values)
        exception === nothing || return (true, nothing, exception)
        is_fixed || return (false, nothing, nothing)
        result += coefficient * variable_value
    end
    return (true, result, nothing)
end

function _fixed_expression_value(
    value::MOI.ScalarQuadraticFunction,
    fixed_values::Dict{MOI.VariableIndex,Any},
)
    affine = MOI.ScalarAffineFunction(value.affine_terms, value.constant)
    is_fixed, result, exception = _fixed_expression_value(affine, fixed_values)
    exception === nothing || return (true, nothing, exception)
    is_fixed || return (false, nothing, nothing)
    for (variables, raw_coefficient) in _canonical_quadratic_terms(value.quadratic_terms)
        variable_1, variable_2 = variables
        left_fixed, left, exception = _fixed_expression_value(variable_1, fixed_values)
        exception === nothing || return (true, nothing, exception)
        right_fixed, right, exception = _fixed_expression_value(variable_2, fixed_values)
        exception === nothing || return (true, nothing, exception)
        left_fixed && right_fixed || return (false, nothing, nothing)
        coefficient = variable_1 == variable_2 ? raw_coefficient / 2 : raw_coefficient
        result += coefficient * left * right
    end
    return (true, result, nothing)
end

function _fixed_expression_value(
    value::MOI.ScalarNonlinearFunction,
    fixed_values::Dict{MOI.VariableIndex,Any},
)
    values = Any[]
    for argument in value.args
        is_fixed, result, exception = _fixed_expression_value(argument, fixed_values)
        exception === nothing || return (true, nothing, exception)
        is_fixed || return (false, nothing, nothing)
        push!(values, result)
    end
    try
        return (true, fixed_operator_value(Val(value.head), values), nothing)
    catch exception
        return (true, nothing, exception)
    end
end

_fixed_expression_value(value, _) = (false, nothing, nothing)

"""
    fixed_operator_value(Val(:operator), values)

Evaluate a nonlinear operator after every argument has been proven fixed.
Packages may extend this hook for custom MOI nonlinear operators. The generic
method covers standard scalar primitives used by NLPDiagnostics.
"""
function fixed_operator_value(operator::Val, values::Vector{Any})
    return _apply_constant_operator(typeof(operator).parameters[1], values)
end

function _apply_constant_operator(head::Symbol, values::Vector{Any})
    stable_softplus(value) =
        value > zero(value) ? value + log1p(exp(-value)) : log1p(exp(value))
    stable_logistic(value) =
        value >= zero(value) ? inv(one(value) + exp(-value)) : exp(value) / (one(value) + exp(value))
    head == :+ && return +(values...)
    head == :- && return -(values...)
    head == :* && return *(values...)
    head == :/ && return /(values...)
    head == :^ && return ^(values...)
    head == :inv && return inv(only(values))
    head == :sqrt && return sqrt(only(values))
    head == :log && return log(only(values))
    head == :log10 && return log10(only(values))
    head == :log2 && return log2(only(values))
    head == :log1p && return log1p(only(values))
    head == :exp && return exp(only(values))
    head == :exp2 && return exp2(only(values))
    head == :expm1 && return expm1(only(values))
    head in (:log1pexp, :log1exp, :softplus) && return stable_softplus(only(values))
    head == :logistic && return stable_logistic(only(values))
    head == :sin && return sin(only(values))
    head == :cos && return cos(only(values))
    head == :tan && return tan(only(values))
    head == :sind && return sind(only(values))
    head == :cosd && return cosd(only(values))
    head == :tand && return tand(only(values))
    head == :sinh && return sinh(only(values))
    head == :cosh && return cosh(only(values))
    head == :tanh && return tanh(only(values))
    head == :asin && return asin(only(values))
    head == :acos && return acos(only(values))
    head == :atan && return atan(only(values))
    head == :asind && return asind(only(values))
    head == :acosd && return acosd(only(values))
    head == :atand && return atand(only(values))
    head == :asinh && return asinh(only(values))
    head == :acosh && return acosh(only(values))
    head == :atanh && return atanh(only(values))
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

"""Evaluate supported scalar expressions whose variables are all statically fixed."""
function _analyze_fixed_expression_constraints!(
    report::DiagnosticReport,
    model::ModelSnapshot,
)
    domains = Dict(domain.variable => domain for domain in variable_domains(model))
    records = Dict(record.index => record for record in model.variables)
    for constraint in model.constraints
        _is_variable_domain_constraint(constraint) && continue
        function_value = constraint.function_value
        support = variable_support(function_value)
        support.complete && !isempty(support.variables) || continue
        fixed_values = Dict{MOI.VariableIndex,Any}()
        for variable in support.variables
            domain = get(domains, variable, nothing)
            isnothing(domain) && break
            !isnothing(domain.lower) && !isnothing(domain.upper) &&
                domain.lower == domain.upper || break
            fixed_values[variable] = domain.lower
        end
        length(fixed_values) == length(support.variables) || continue
        is_fixed, value, exception = _fixed_expression_value(function_value, fixed_values)
        is_fixed || continue
        reference = _constraint_ref(constraint)
        variable_references = [_variable_ref(records[variable]) for variable in support.variables]
        if exception !== nothing &&
           (exception isa DomainError || exception isa DivideError)
            push!(report, Finding(
                :fixed_expression_domain_violation;
                severity = SeverityError,
                domain = MathematicalIssue,
                basis = MathematicalProof,
                confidence = ConfidenceCertain,
                observation = "Constraint $(reference.index) has an operator-domain failure after substituting its fixed variables.",
                why_it_matters = "The fixed values are the only allowed values of every expression variable, so the expression cannot be evaluated over the reals in any feasible point.",
                evidence = [Evidence("Fixed-value expression evaluation failed";
                    details = ["exception" => nameof(typeof(exception)),
                               "message" => sprint(showerror, exception)],
                )],
                suggested_actions = ["Correct the fixed values or the operator domain expression."],
                affected = vcat(variable_references, [reference]),
            ))
            continue
        end
        if exception !== nothing
            push!(report, Finding(
                :fixed_expression_evaluation_unavailable;
                severity = SeverityInfo,
                domain = RepresentationalIssue,
                basis = StructuralProof,
                confidence = ConfidenceCertain,
                observation = "Constraint $(reference.index) has only fixed expression variables, but its operator cannot be evaluated by the registered fixed-value evaluator.",
                why_it_matters = "The fixed values could make the constraint redundant or infeasible, but NLPDiagnostics deliberately makes no claim without an exact operator evaluation.",
                evidence = [Evidence("Fixed-value expression evaluation is unavailable";
                    details = ["exception" => nameof(typeof(exception)),
                               "message" => sprint(showerror, exception)],
                )],
                suggested_actions = ["Extend fixed_operator_value for this custom operator.",
                                     "Or provide a plugin that supplies an exact fixed-value evaluator."],
                affected = vcat(variable_references, [reference]),
            ))
            continue
        end
        if value isa AbstractFloat && !isfinite(value)
            push!(report, Finding(
                :fixed_expression_nonfinite_evaluation;
                severity = SeverityWarning,
                domain = NumericalIssue,
                basis = NumericalObservation,
                confidence = ConfidenceCertain,
                observation = "Constraint $(reference.index) evaluates to a non-finite floating-point value after fixed-variable substitution.",
                why_it_matters = "The mathematical expression may be defined, but this numeric representation cannot safely evaluate it; derivative and feasibility checks may fail before a solver can proceed.",
                evidence = [Evidence("Fixed-value floating-point evaluation";
                    details = ["evaluated_value" => value,
                               "set" => constraint.set_value],
                )],
                suggested_actions = ["Use a stable equivalent expression or rescale the model.",
                                     "Check whether the fixed data are outside the intended floating-point range."],
                affected = vcat(variable_references, [reference]),
            ))
            continue
        end
        satisfied = _satisfies(value, constraint.set_value)
        isnothing(satisfied) && continue
        is_affine = function_value isa MOI.ScalarAffineFunction
        expression_label = is_affine ? "Affine constraint" : "Constraint"
        redundant_code = is_affine ? :redundant_fixed_affine_constraint :
                                    :redundant_fixed_expression_constraint
        infeasible_code = is_affine ? :infeasible_fixed_affine_constraint :
                                     :infeasible_fixed_expression_constraint
        if satisfied
            push!(report, Finding(
                redundant_code;
                severity = SeverityInfo,
                domain = RepresentationalIssue,
                basis = MathematicalProof,
                confidence = ConfidenceCertain,
                observation = "$expression_label $(reference.index) is already satisfied because every variable in its supported expression is fixed.",
                why_it_matters = "The expression contributes no remaining degree-of-freedom restriction and may be intentional bookkeeping or evidence of unexpected over-fixing.",
                evidence = [Evidence("Substitution of effective fixed variable values";
                    details = ["evaluated_value" => value,
                               "set" => constraint.set_value,
                               "fixed_variable_count" => length(variable_references)],
                )],
                suggested_actions = ["Confirm that the fixed variables and retained row are intentional.",
                                     "Remove or annotate the row if it is only redundant bookkeeping."],
                affected = vcat(variable_references, [reference]),
            ))
        else
            push!(report, Finding(
                infeasible_code;
                severity = SeverityError,
                domain = MathematicalIssue,
                basis = MathematicalProof,
                confidence = ConfidenceCertain,
                observation = "$expression_label $(reference.index) is violated by the only values allowed for every variable in its supported expression.",
                why_it_matters = "All variables in this expression are fixed, so the violated constraint proves that the model is infeasible.",
                evidence = [Evidence("Substitution of effective fixed variable values";
                    details = ["evaluated_value" => value,
                               "set" => constraint.set_value,
                               "fixed_variable_count" => length(variable_references)],
                )],
                suggested_actions = ["Correct the fixed values or the affine row right-hand side.",
                                     "Check whether parameter data unintentionally fixed all expression variables."],
                affected = vcat(variable_references, [reference]),
            ))
        end
    end
    return
end

"""Report an objective whose supported variables are all statically fixed."""
function _analyze_fixed_objective!(
    report::DiagnosticReport,
    model::ModelSnapshot,
)
    isnothing(model.objective) && return
    objective = model.objective
    support = variable_support(objective.function_value)
    support.complete && !isempty(support.variables) || return
    domains = Dict(domain.variable => domain for domain in variable_domains(model))
    records = Dict(record.index => record for record in model.variables)
    fixed_values = Dict{MOI.VariableIndex,Any}()
    for variable in support.variables
        domain = get(domains, variable, nothing)
        isnothing(domain) && return
        !isnothing(domain.lower) && !isnothing(domain.upper) &&
            domain.lower == domain.upper || return
        fixed_values[variable] = domain.lower
    end
    is_fixed, value, exception =
        _fixed_expression_value(objective.function_value, fixed_values)
    is_fixed || return
    objective_reference = EntityRef(
        :objective,
        1;
        function_type = string(typeof(objective.function_value)),
    )
    affected = vcat(
        [_variable_ref(records[variable]) for variable in support.variables],
        [objective_reference],
    )
    if exception !== nothing && (exception isa DomainError || exception isa DivideError)
        push!(report, Finding(
            :fixed_objective_domain_violation;
            severity = SeverityError,
            domain = MathematicalIssue,
            basis = MathematicalProof,
            confidence = ConfidenceCertain,
            observation = "The objective has an operator-domain failure after substituting all of its fixed variables.",
            why_it_matters = "Every objective variable is fixed at this invalid expression input, so no feasible optimization point has a real-valued objective.",
            evidence = [Evidence("Fixed-value objective evaluation failed";
                details = ["exception" => nameof(typeof(exception)),
                           "message" => sprint(showerror, exception)],
            )],
            suggested_actions = ["Correct the fixed values or the objective operator domain."],
            affected = affected,
        ))
    elseif exception !== nothing
        push!(report, Finding(
            :fixed_objective_evaluation_unavailable;
            severity = SeverityInfo,
            domain = RepresentationalIssue,
            basis = StructuralProof,
            confidence = ConfidenceCertain,
            observation = "Every objective variable is fixed, but its operator cannot be evaluated by the registered fixed-value evaluator.",
            why_it_matters = "The objective may be constant, but NLPDiagnostics deliberately does not infer its value without an exact evaluator.",
            evidence = [Evidence("Fixed-value objective evaluation is unavailable";
                details = ["exception" => nameof(typeof(exception)),
                           "message" => sprint(showerror, exception)],
            )],
            suggested_actions = ["Extend fixed_operator_value for this custom objective operator."],
            affected = affected,
        ))
    elseif value isa AbstractFloat && !isfinite(value)
        push!(report, Finding(
            :fixed_objective_nonfinite_evaluation;
            severity = SeverityWarning,
            domain = NumericalIssue,
            basis = NumericalObservation,
            confidence = ConfidenceCertain,
            observation = "The objective evaluates to a non-finite floating-point value after fixed-variable substitution.",
            why_it_matters = "The mathematical objective may be defined, but this numeric representation cannot provide a reliable objective or derivative value.",
            evidence = [Evidence("Fixed-value objective floating-point evaluation";
                details = ["evaluated_value" => value],
            )],
            suggested_actions = ["Use a stable equivalent objective expression or rescale fixed data."],
            affected = affected,
        ))
    else
        sense = objective.sense == MOI.MAX_SENSE ? "maximization" : "minimization"
        push!(report, Finding(
            :fixed_objective;
            severity = SeverityInfo,
            domain = RepresentationalIssue,
            basis = MathematicalProof,
            confidence = ConfidenceCertain,
            observation = "The $sense objective is fixed at $value because every variable in its supported expression is fixed.",
            why_it_matters = "The objective cannot distinguish feasible points; any remaining task is feasibility rather than optimization, and unexpected fixing can conceal a lost degree of freedom.",
            evidence = [Evidence("Substitution of effective fixed objective variables";
                details = ["objective_value" => value,
                           "fixed_variable_count" => length(support.variables),
                           "sense" => objective.sense],
            )],
            suggested_actions = ["Confirm that all objective variables are intentionally fixed.",
                                 "Use a feasibility workflow if no objective freedom is intended."],
            affected = affected,
        ))
    end
    return
end

"""Report a symbolic objective that is constant before considering variable bounds."""
function _analyze_constant_objective!(
    report::DiagnosticReport,
    model::ModelSnapshot,
)
    isnothing(model.objective) && return
    objective = model.objective
    support = variable_support(objective.function_value)
    support.complete && isempty(support.variables) || return
    is_constant, value, exception = _constant_value(objective.function_value)
    is_constant || return
    objective_reference = EntityRef(
        :objective,
        1;
        function_type = string(typeof(objective.function_value)),
    )
    if exception !== nothing && (exception isa DomainError || exception isa DivideError)
        push!(report, Finding(
            :constant_objective_domain_violation;
            severity = SeverityError,
            domain = MathematicalIssue,
            basis = MathematicalProof,
            confidence = ConfidenceCertain,
            observation = "The variable-free objective is outside an operator domain.",
            why_it_matters = "The optimization problem has no real-valued objective, independently of feasibility constraints or solver initialization.",
            evidence = [Evidence("Constant objective evaluation failed";
                details = ["exception" => nameof(typeof(exception)),
                           "message" => sprint(showerror, exception)],
            )],
            suggested_actions = ["Correct the constant objective expression or its data."],
            affected = [objective_reference],
        ))
    elseif exception !== nothing
        push!(report, Finding(
            :constant_objective_evaluation_unavailable;
            severity = SeverityInfo,
            domain = RepresentationalIssue,
            basis = StructuralProof,
            confidence = ConfidenceCertain,
            observation = "The objective has no variable support, but its operator cannot be evaluated by the registered fixed-value evaluator.",
            why_it_matters = "The objective may be constant, but NLPDiagnostics deliberately does not infer its value without an exact evaluator.",
            evidence = [Evidence("Constant objective evaluation is unavailable";
                details = ["exception" => nameof(typeof(exception)),
                           "message" => sprint(showerror, exception)],
            )],
            suggested_actions = ["Extend fixed_operator_value for this custom objective operator."],
            affected = [objective_reference],
        ))
    elseif value isa AbstractFloat && !isfinite(value)
        push!(report, Finding(
            :constant_objective_nonfinite_evaluation;
            severity = SeverityWarning,
            domain = NumericalIssue,
            basis = NumericalObservation,
            confidence = ConfidenceCertain,
            observation = "The variable-free objective evaluates to a non-finite floating-point value.",
            why_it_matters = "The objective contains no decision dependence, but its numeric representation cannot provide a reliable value to a solver.",
            evidence = [Evidence("Constant objective floating-point evaluation";
                details = ["evaluated_value" => value],
            )],
            suggested_actions = ["Use a stable equivalent expression or rescale the constant data."],
            affected = [objective_reference],
        ))
    else
        sense = objective.sense == MOI.MAX_SENSE ? "maximization" : "minimization"
        push!(report, Finding(
            :constant_objective;
            severity = SeverityInfo,
            domain = RepresentationalIssue,
            basis = MathematicalProof,
            confidence = ConfidenceCertain,
            observation = "The $sense objective is the constant value $value and has no decision-variable dependence.",
            why_it_matters = "The model is a feasibility problem from the objective's perspective; an unintended constant objective often indicates a missing variable term or parameter substitution error.",
            evidence = [Evidence("Variable-free objective expression";
                details = ["objective_value" => value,
                           "sense" => objective.sense],
            )],
            suggested_actions = ["Confirm that a feasibility objective is intended.",
                                 "Otherwise, inspect objective construction for a missing decision-variable term."],
            affected = [objective_reference],
        ))
    end
    return
end

"""Return the variable/domain pair for a direct self-division proven nonzero."""
function _proven_nonzero_self_division(value, domains)
    value isa MOI.ScalarNonlinearFunction || return nothing
    value.head == :/ && length(value.args) == 2 &&
        value.args[1] isa MOI.VariableIndex && value.args[1] == value.args[2] ||
        return nothing
    variable = value.args[1]
    domain = get(domains, variable, nothing)
    isnothing(domain) && return nothing
    ((!isnothing(domain.lower) && domain.lower > 0) ||
     (!isnothing(domain.upper) && domain.upper < 0)) || return nothing
    return variable, domain
end

"""Report direct ``x / x`` nodes that are constant on a proven nonzero domain."""
function _analyze_nonzero_self_division!(
    report::DiagnosticReport,
    value,
    source::EntityRef,
    path::Vector{Int},
    domains,
    records,
)
    value isa MOI.ScalarNonlinearFunction || return
    identity = _proven_nonzero_self_division(value, domains)
    if !isnothing(identity)
        variable, domain = identity
        path_label = isempty(path) ? "root" : join(path, "/")
        push!(report, Finding(
                :nonzero_self_division_identity;
                severity = SeverityInfo,
                domain = RepresentationalIssue,
                basis = MathematicalProof,
                confidence = ConfidenceCertain,
                observation = "Expression $path_label is x / x for a variable whose declared domain excludes zero, so it is identically one.",
                why_it_matters = "This syntactically variable expression has no value sensitivity on its declared domain and can create a flat objective term or redundant constraint contribution.",
                evidence = [Evidence("Declared nonzero scalar domain";
                    details = ["lower" => domain.lower,
                               "upper" => domain.upper,
                               "expression_path" => path_label],
                )],
                suggested_actions = ["Replace the identity with one only when preserving the original expression is not needed for provenance.",
                                     "Inspect the surrounding objective or constraint for an unintended lost dependency."],
                affected = [source, _variable_ref(records[variable])],
        ))
    end
    for (argument_index, argument) in enumerate(value.args)
        _analyze_nonzero_self_division!(
            report,
            argument,
            source,
            vcat(path, argument_index),
            domains,
            records,
        )
    end
    return
end

function _analyze_nonzero_self_divisions!(
    report::DiagnosticReport,
    model::ModelSnapshot,
)
    domains = Dict(domain.variable => domain for domain in variable_domains(model))
    records = Dict(record.index => record for record in model.variables)
    if !isnothing(model.objective)
        objective = model.objective
        identity = _proven_nonzero_self_division(objective.function_value, domains)
        if !isnothing(identity)
            variable, domain = identity
            objective_reference = EntityRef(
                :objective,
                1;
                function_type = string(typeof(objective.function_value)),
            )
            push!(report, Finding(
                :constant_nonzero_self_division_objective;
                severity = SeverityInfo,
                domain = RepresentationalIssue,
                basis = MathematicalProof,
                confidence = ConfidenceCertain,
                observation = "The objective is x / x for a variable whose declared domain excludes zero, so it is identically one.",
                why_it_matters = "This syntactically variable objective has no optimization preference on its declared domain; any remaining task is feasibility rather than objective-driven optimization.",
                evidence = [Evidence("Nonzero self-division substituted at the objective root";
                    details = ["value" => 1,
                               "lower" => domain.lower,
                               "upper" => domain.upper,
                               "sense" => objective.sense],
                )],
                suggested_actions = ["Replace the identity objective with a feasibility objective if that is intended.",
                                     "Otherwise inspect the objective for a lost dependency or accidental self-division."],
                affected = [objective_reference, _variable_ref(records[variable])],
            ))
        end
        _analyze_nonzero_self_division!(
            report,
            objective.function_value,
            EntityRef(:objective, 1; function_type = string(typeof(objective.function_value))),
            Int[],
            domains,
            records,
        )
    end
    for constraint in model.constraints
        identity = _proven_nonzero_self_division(constraint.function_value, domains)
        if !isnothing(identity)
            variable, domain = identity
            reference = _constraint_ref(constraint)
            satisfied = _satisfies(one(domain.lower isa Nothing ? domain.upper : domain.lower), constraint.set_value)
            if !isnothing(satisfied)
                code = satisfied ? :redundant_nonzero_self_division_constraint :
                                   :infeasible_nonzero_self_division_constraint
                push!(report, Finding(
                    code;
                    severity = satisfied ? SeverityInfo : SeverityError,
                    domain = satisfied ? RepresentationalIssue : MathematicalIssue,
                    basis = MathematicalProof,
                    confidence = ConfidenceCertain,
                    observation = satisfied ?
                        "Constraint $(reference.index) is satisfied because its nonzero self-division expression is identically one." :
                        "Constraint $(reference.index) cannot be satisfied because its nonzero self-division expression is identically one.",
                    why_it_matters = satisfied ?
                        "This row adds no restriction beyond the declared nonzero domain of its variable." :
                        "The declared nonzero domain makes the expression exactly one, so this one constraint proves infeasibility.",
                    evidence = [Evidence("Nonzero self-division substituted at the constraint root";
                        details = ["value" => 1,
                                   "lower" => domain.lower,
                                   "upper" => domain.upper,
                                   "set" => constraint.set_value],
                    )],
                    suggested_actions = satisfied ?
                        ["Remove or annotate the identity constraint if it is only bookkeeping."] :
                        ["Correct the constraint set or the intended self-division expression."],
                    affected = [reference, _variable_ref(records[variable])],
                ))
            end
        end
        _analyze_nonzero_self_division!(
            report,
            constraint.function_value,
            _constraint_ref(constraint),
            Int[],
            domains,
            records,
        )
    end
    return
end

"""Report affine objective rays through variables absent from every model row."""
function _analyze_unconstrained_affine_objective_rays!(
    report::DiagnosticReport,
    model::ModelSnapshot,
)
    isnothing(model.objective) && return
    objective = model.objective
    objective_terms, quadratic_variables = if objective.function_value isa MOI.VariableIndex
        ([(objective.function_value, 1)], Set{MOI.VariableIndex}())
    elseif objective.function_value isa MOI.ScalarAffineFunction
        (_canonical_affine_terms(objective.function_value.terms), Set{MOI.VariableIndex}())
    elseif objective.function_value isa MOI.ScalarQuadraticFunction
        quadratic_variables = Set{MOI.VariableIndex}()
        for (variables, _) in _canonical_quadratic_terms(
            objective.function_value.quadratic_terms,
        )
            union!(quadratic_variables, variables)
        end
        (
            _canonical_affine_terms(objective.function_value.affine_terms),
            quadratic_variables,
        )
    else
        return
    end
    isempty(objective_terms) && return
    constrained_variables = Set{MOI.VariableIndex}()
    for constraint in model.constraints
        _is_variable_domain_constraint(constraint) && continue
        constraint_role(constraint.set_value) == FreeConstraint && continue
        support = variable_support(constraint.function_value)
        support.complete || return
        union!(constrained_variables, support.variables)
    end
    domains = Dict(domain.variable => domain for domain in variable_domains(model))
    records = Dict(record.index => record for record in model.variables)
    objective_reference = EntityRef(
        :objective,
        1;
        function_type = string(typeof(objective.function_value)),
    )
    for (variable, coefficient) in objective_terms
        variable in quadratic_variables && continue
        variable in constrained_variables && continue
        domain = domains[variable]
        decreasing_direction, missing_bound = if objective.sense == MOI.MIN_SENSE
            coefficient > 0 ? ("negative", :lower) : ("positive", :upper)
        else
            coefficient > 0 ? ("positive", :upper) : ("negative", :lower)
        end
        bound_missing = missing_bound == :lower ? isnothing(domain.lower) :
                        isnothing(domain.upper)
        bound_missing || continue
        record = records[variable]
        push!(report, Finding(
            :unconstrained_affine_objective_ray;
            severity = SeverityWarning,
            domain = MathematicalIssue,
            basis = MathematicalProof,
            confidence = ConfidenceCertain,
            observation = "Variable $(_display_name(record)) is absent from every restrictive constraint and can move without bound in the $decreasing_direction direction to improve the affine objective.",
            why_it_matters = "If the remaining model is feasible, this variable supplies an objective ray and the optimization problem is unbounded in the requested sense.",
            evidence = [Evidence("Disconnected affine objective direction";
                details = ["coefficient" => coefficient,
                           "sense" => objective.sense,
                           "missing_bound" => missing_bound],
            )],
            suggested_actions = ["Add the intended constraint or an appropriate bound for this objective variable.",
                                 "If the ray is intentional, use a formulation or solver workflow that handles the resulting unbounded objective."],
            affected = [_variable_ref(record), objective_reference],
        ))
    end
    return
end

"""Report curvature-driven objective rays through disconnected quadratic variables."""
function _analyze_unconstrained_quadratic_objective_rays!(
    report::DiagnosticReport,
    model::ModelSnapshot,
)
    isnothing(model.objective) && return
    objective = model.objective
    objective.function_value isa MOI.ScalarQuadraticFunction || return
    constrained_variables = Set{MOI.VariableIndex}()
    for constraint in model.constraints
        _is_variable_domain_constraint(constraint) && continue
        constraint_role(constraint.set_value) == FreeConstraint && continue
        support = variable_support(constraint.function_value)
        support.complete || return
        union!(constrained_variables, support.variables)
    end
    domains = Dict(domain.variable => domain for domain in variable_domains(model))
    records = Dict(record.index => record for record in model.variables)
    objective_reference = EntityRef(
        :objective,
        1;
        function_type = string(typeof(objective.function_value)),
    )
    for (variables, coefficient) in
        _canonical_quadratic_terms(objective.function_value.quadratic_terms)
        variable_1, variable_2 = variables
        variable_1 == variable_2 || continue
        variable_1 in constrained_variables && continue
        improving_curvature = objective.sense == MOI.MIN_SENSE ?
                              coefficient < 0 : coefficient > 0
        improving_curvature || continue
        domain = domains[variable_1]
        missing_directions = String[]
        isnothing(domain.lower) && push!(missing_directions, "negative")
        isnothing(domain.upper) && push!(missing_directions, "positive")
        isempty(missing_directions) && continue
        record = records[variable_1]
        push!(report, Finding(
            :unconstrained_quadratic_objective_ray;
            severity = SeverityWarning,
            domain = MathematicalIssue,
            basis = MathematicalProof,
            confidence = ConfidenceCertain,
            observation = "Variable $(_display_name(record)) is absent from every restrictive constraint and has $(objective.sense == MOI.MIN_SENSE ? "negative" : "positive") objective curvature along an unbounded direction.",
            why_it_matters = "Holding all other variables fixed, the diagonal quadratic term drives the objective indefinitely in the requested sense; if the remaining model is feasible, this is an unbounded objective ray.",
            evidence = [Evidence("Disconnected diagonal quadratic objective term";
                details = ["raw_diagonal_coefficient" => coefficient,
                           "polynomial_coefficient" => coefficient / 2,
                           "sense" => objective.sense,
                           "unbounded_directions" => join(missing_directions, ",")],
            )],
            suggested_actions = ["Add the intended constraint or finite bound for this objective variable.",
                                 "Inspect the curvature sign and optimization sense for a possible modeling error."],
            affected = [_variable_ref(record), objective_reference],
        ))
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

"""Return a normalized affine equality as ``a' * x == b``."""
function _affine_equality_normalized_relation(record::ConstraintRecord)
    function_value = record.function_value
    function_value isa MOI.ScalarAffineFunction || return nothing
    set_value = record.set_value
    right_hand_side = if set_value isa MOI.EqualTo
        set_value.value
    elseif set_value isa MOI.Interval && set_value.lower == set_value.upper
        set_value.lower
    else
        return nothing
    end
    coefficients = Dict{Int,Any}()
    for term in function_value.terms
        coefficients[term.variable.value] = get(
            coefficients,
            term.variable.value,
            zero(term.coefficient),
        ) + term.coefficient
    end
    terms = sort!(
        filter(term -> !iszero(last(term)), collect(coefficients));
        by = first,
    )
    isempty(terms) && return nothing
    scale = first(terms)[2]
    normalized_terms = [(variable, coefficient / scale) for (variable, coefficient) in terms]
    normalized_value = (right_hand_side - function_value.constant) / scale
    iszero(normalized_value) && (normalized_value = zero(normalized_value))
    normalized_value isa AbstractFloat && isnan(normalized_value) && return nothing
    return normalized_terms, normalized_value
end

function _affine_equality_normalized_fingerprint(record::ConstraintRecord)
    relation = _affine_equality_normalized_relation(record)
    isnothing(relation) && return nothing
    direction, value = relation
    return "normalized_affine_equality($(repr(value));$(repr(direction)))"
end

"""Return an oriented affine half-space as a normalized direction and bound.

The returned relation is ``a' * x <= b``.  Positive scalar multiples have the
same direction and comparable bounds; negative multiples deliberately retain
the opposite direction because they define the other side of a slab.
"""
function _affine_inequality_normalized_relation(record::ConstraintRecord)
    function_value = record.function_value
    function_value isa MOI.ScalarAffineFunction || return nothing
    set_value = record.set_value
    orientation, right_hand_side = if set_value isa MOI.LessThan
        one(set_value.upper), set_value.upper
    elseif set_value isa MOI.GreaterThan
        -one(set_value.lower), set_value.lower
    else
        return nothing
    end
    coefficients = Dict{Int,Any}()
    for term in function_value.terms
        coefficients[term.variable.value] = get(
            coefficients,
            term.variable.value,
            zero(term.coefficient),
        ) + orientation * term.coefficient
    end
    terms = sort!(
        filter(term -> !iszero(last(term)), collect(coefficients));
        by = first,
    )
    isempty(terms) && return nothing
    scale = abs(first(terms)[2])
    normalized_terms = [(variable, coefficient / scale) for (variable, coefficient) in terms]
    normalized_bound = orientation * (right_hand_side - function_value.constant) / scale
    iszero(normalized_bound) && (normalized_bound = zero(normalized_bound))
    normalized_bound isa AbstractFloat && isnan(normalized_bound) && return nothing
    return normalized_terms, normalized_bound
end

function _affine_inequality_normalized_fingerprint(record::ConstraintRecord)
    relation = _affine_inequality_normalized_relation(record)
    isnothing(relation) && return nothing
    direction, bound = relation
    return "normalized_affine_inequality($(repr(bound));$(repr(direction)))"
end

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

"""Find distinct affine equality rows that differ only by a nonzero scalar."""
function _analyze_proportional_affine_equalities!(
    report::DiagnosticReport,
    model::ModelSnapshot,
)
    groups = Dict{String,Vector{ConstraintRecord}}()
    for constraint in model.constraints
        fingerprint = _affine_equality_normalized_fingerprint(constraint)
        isnothing(fingerprint) && continue
        push!(get!(groups, fingerprint, ConstraintRecord[]), constraint)
    end
    for constraints in values(groups)
        length(constraints) > 1 || continue
        # Exact duplicates already receive the more specific duplicate finding.
        length(unique(_constraint_fingerprint(constraint) for constraint in constraints)) > 1 ||
            continue
        references = _constraint_ref.(constraints)
        indices = join((reference.index for reference in references), ", ")
        push!(report, Finding(
            :proportional_affine_equality_constraints;
            severity = SeverityWarning,
            domain = RepresentationalIssue,
            basis = StructuralProof,
            confidence = ConfidenceCertain,
            observation = "Affine equality constraints $indices define the same canonical equation up to nonzero scalar scaling.",
            why_it_matters = "Proportional equality rows are mathematically redundant and can create dependent Jacobian rows, non-unique multipliers, and scaling-sensitive linear algebra.",
            evidence = [Evidence("Normalized affine equality relation";
                details = ["constraint_count" => length(constraints)],
            )],
            suggested_actions = ["Retain at most one equation unless the separate provenance is intentional.",
                                 "If retained, compare row scaling before interpreting solver or multiplier behavior."],
            affected = references,
        ))
    end
    return
end

"""Find distinct affine inequalities that define the same half-space."""
function _analyze_proportional_affine_inequalities!(
    report::DiagnosticReport,
    model::ModelSnapshot,
)
    groups = Dict{String,Vector{ConstraintRecord}}()
    for constraint in model.constraints
        fingerprint = _affine_inequality_normalized_fingerprint(constraint)
        isnothing(fingerprint) && continue
        push!(get!(groups, fingerprint, ConstraintRecord[]), constraint)
    end
    for constraints in values(groups)
        length(constraints) > 1 || continue
        length(unique(_constraint_fingerprint(constraint) for constraint in constraints)) > 1 ||
            continue
        references = _constraint_ref.(constraints)
        indices = join((reference.index for reference in references), ", ")
        push!(report, Finding(
            :proportional_affine_inequality_constraints;
            severity = SeverityInfo,
            domain = RepresentationalIssue,
            basis = StructuralProof,
            confidence = ConfidenceCertain,
            observation = "Affine inequality constraints $indices define the same canonical half-space up to positive scalar scaling.",
            why_it_matters = "These constraints are redundant and can distort row counts, multiplier interpretation, and scaling without restricting the feasible region further.",
            evidence = [Evidence("Normalized affine inequality relation";
                details = ["constraint_count" => length(constraints)],
            )],
            suggested_actions = ["Retain one inequality unless the separate provenance is intentional."],
            affected = references,
        ))
    end
    return
end

"""Find affine half-spaces made redundant by a stricter parallel half-space."""
function _analyze_dominated_affine_inequalities!(
    report::DiagnosticReport,
    model::ModelSnapshot,
)
    groups = Dict{String,Vector{Tuple{Any,ConstraintRecord}}}()
    for constraint in model.constraints
        relation = _affine_inequality_normalized_relation(constraint)
        isnothing(relation) && continue
        direction, bound = relation
        push!(
            get!(groups, repr(direction), Tuple{Any,ConstraintRecord}[]),
            (bound, constraint),
        )
    end
    for rows in values(groups)
        length(rows) > 1 || continue
        tightest_bound = minimum(first(row) for row in rows)
        tightest = [constraint for (bound, constraint) in rows if bound == tightest_bound]
        dominated = [constraint for (bound, constraint) in rows if bound > tightest_bound]
        isempty(dominated) && continue
        tightest_references = _constraint_ref.(tightest)
        dominated_references = _constraint_ref.(dominated)
        tightest_indices = join((reference.index for reference in tightest_references), ", ")
        dominated_indices = join((reference.index for reference in dominated_references), ", ")
        push!(report, Finding(
            :dominated_affine_inequality;
            severity = SeverityInfo,
            domain = RepresentationalIssue,
            basis = MathematicalProof,
            confidence = ConfidenceCertain,
            observation = "Affine inequality constraints $dominated_indices are implied by tighter parallel half-space constraint(s) $tightest_indices.",
            why_it_matters = "The dominated inequalities do not restrict the feasible region further, but they can obscure model intent and add redundant rows or multipliers.",
            evidence = [Evidence("Normalized oriented affine half-space";
                details = ["tightest_normalized_bound" => tightest_bound,
                           "dominated_constraint_count" => length(dominated)],
            )],
            suggested_actions = ["Retain the looser inequality only when its separate provenance is useful.",
                                 "Compare the parallel rows' units and scaling if both were expected to bind."],
            affected = vcat(tightest_references, dominated_references),
        ))
    end
    return
end

"""Prove conflicts among parallel affine equalities and parallel half-spaces."""
function _analyze_affine_equality_halfspace_consistency!(
    report::DiagnosticReport,
    model::ModelSnapshot,
)
    equalities = Dict{String,Vector{Tuple{Any,ConstraintRecord}}}()
    halfspaces = Dict{String,Vector{Tuple{Bool,Any,ConstraintRecord}}}()
    for constraint in model.constraints
        equality = _affine_equality_normalized_relation(constraint)
        if !isnothing(equality)
            direction, value = equality
            push!(
                get!(equalities, repr(direction), Tuple{Any,ConstraintRecord}[]),
                (value, constraint),
            )
            continue
        end
        inequality = _affine_inequality_normalized_relation(constraint)
        isnothing(inequality) && continue
        direction, bound = inequality
        # Equality normalization fixes the first nonzero coefficient to +1.
        is_upper = first(direction)[2] > zero(first(direction)[2])
        canonical_direction = is_upper ? direction :
                              [(variable, -coefficient) for (variable, coefficient) in direction]
        push!(
            get!(halfspaces, repr(canonical_direction), Tuple{Bool,Any,ConstraintRecord}[]),
            (is_upper, bound, constraint),
        )
    end
    for (direction, rows) in equalities
        values = first.(rows)
        minimum_value, maximum_value = minimum(values), maximum(values)
        if minimum_value < maximum_value
            lower_references = _constraint_ref.([constraint for (value, constraint) in rows if value == minimum_value])
            upper_references = _constraint_ref.([constraint for (value, constraint) in rows if value == maximum_value])
            push!(report, Finding(
                :inconsistent_parallel_affine_equalities;
                severity = SeverityError,
                domain = MathematicalIssue,
                basis = MathematicalProof,
                confidence = ConfidenceCertain,
                observation = "Parallel affine equality constraints require the same normalized expression to equal both $minimum_value and $maximum_value.",
                why_it_matters = "No point can satisfy distinct values of the same affine expression, so the model is infeasible.",
                evidence = [Evidence("Normalized parallel affine equalities";
                    details = ["minimum_normalized_value" => minimum_value,
                               "maximum_normalized_value" => maximum_value],
                )],
                suggested_actions = ["Correct one equality right-hand side or its sign convention.",
                                     "Check duplicated balance equations and parameter units."],
                affected = vcat(lower_references, upper_references),
            ))
        end
        bounds = get(halfspaces, direction, Tuple{Bool,Any,ConstraintRecord}[])
        isempty(bounds) && continue
        upper_rows = [(bound, constraint) for (is_upper, bound, constraint) in bounds if is_upper]
        lower_rows = [(-bound, constraint) for (is_upper, bound, constraint) in bounds if !is_upper]
        upper = isempty(upper_rows) ? nothing : minimum(first(row) for row in upper_rows)
        lower = isempty(lower_rows) ? nothing : maximum(first(row) for row in lower_rows)
        incompatible = [
            (value, constraint) for (value, constraint) in rows
            if (!isnothing(upper) && value > upper) || (!isnothing(lower) && value < lower)
        ]
        isempty(incompatible) && continue
        upper_references = isnothing(upper) ? EntityRef[] :
            _constraint_ref.([constraint for (bound, constraint) in upper_rows if bound == upper])
        lower_references = isnothing(lower) ? EntityRef[] :
            _constraint_ref.([constraint for (bound, constraint) in lower_rows if bound == lower])
        equality_references = _constraint_ref.(last.(incompatible))
        push!(report, Finding(
            :inconsistent_affine_equality_halfspace;
            severity = SeverityError,
            domain = MathematicalIssue,
            basis = MathematicalProof,
            confidence = ConfidenceCertain,
            observation = "Affine equality constraints fix a normalized expression outside the interval allowed by parallel affine half-space constraints.",
            why_it_matters = "The equality and half-space requirements have an empty intersection, so the model is infeasible independently of other constraints.",
            evidence = [Evidence("Normalized equality and parallel half-space intersection";
                details = ["normalized_lower" => lower,
                           "normalized_upper" => upper,
                           "incompatible_equality_count" => length(incompatible)],
            )],
            suggested_actions = ["Correct the equality value or the conflicting inequality bound.",
                                 "Check sign conventions, units, and duplicated balance or limit equations."],
            affected = vcat(equality_references, lower_references, upper_references),
        ))
    end
    return
end

"""Prove an empty slab when opposing parallel affine half-spaces conflict."""
function _analyze_inconsistent_opposing_affine_inequalities!(
    report::DiagnosticReport,
    model::ModelSnapshot,
)
    # Each group uses an arbitrary but deterministic direction.  A row in the
    # reverse direction contributes a lower, rather than an upper, bound to
    # that shared scalar affine expression.
    groups = Dict{String,Vector{Tuple{Bool,Any,ConstraintRecord}}}()
    for constraint in model.constraints
        relation = _affine_inequality_normalized_relation(constraint)
        isnothing(relation) && continue
        direction, bound = relation
        reverse_direction = [(variable, -coefficient) for (variable, coefficient) in direction]
        direction_key, reverse_key = repr(direction), repr(reverse_direction)
        canonical_key = min(direction_key, reverse_key)
        is_upper = direction_key == canonical_key
        push!(
            get!(groups, canonical_key, Tuple{Bool,Any,ConstraintRecord}[]),
            (is_upper, bound, constraint),
        )
    end
    for rows in values(groups)
        upper_rows = [(bound, constraint) for (is_upper, bound, constraint) in rows if is_upper]
        lower_rows = [(-bound, constraint) for (is_upper, bound, constraint) in rows if !is_upper]
        isempty(upper_rows) && continue
        isempty(lower_rows) && continue
        upper = minimum(first(row) for row in upper_rows)
        lower = maximum(first(row) for row in lower_rows)
        lower > upper || continue
        upper_references = _constraint_ref.([constraint for (bound, constraint) in upper_rows if bound == upper])
        lower_references = _constraint_ref.([constraint for (bound, constraint) in lower_rows if bound == lower])
        push!(report, Finding(
            :inconsistent_opposing_affine_inequalities;
            severity = SeverityError,
            domain = MathematicalIssue,
            basis = MathematicalProof,
            confidence = ConfidenceCertain,
            observation = "Opposing parallel affine inequalities impose incompatible normalized bounds $lower <= a'x <= $upper.",
            why_it_matters = "No point can satisfy the conflicting affine half-spaces, so the model is infeasible independently of all other constraints.",
            evidence = [Evidence("Intersection of opposing normalized affine half-spaces";
                details = ["normalized_lower" => lower,
                           "normalized_upper" => upper,
                           "lower_source_count" => length(lower_references),
                           "upper_source_count" => length(upper_references)],
            )],
            suggested_actions = ["Correct one of the opposing right-hand sides or its sign convention.",
                                 "Check unit conversions and duplicated physical limits that constrain the same affine quantity."],
            affected = vcat(lower_references, upper_references),
        ))
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

function _single_variable_affine_interval(
    function_value::MOI.ScalarAffineFunction,
    set_value,
)
    interval = _scalar_set_interval(set_value)
    isnothing(interval) && return nothing
    coefficients = Dict{MOI.VariableIndex,Any}()
    for term in function_value.terms
        coefficients[term.variable] = get(
            coefficients,
            term.variable,
            zero(term.coefficient),
        ) + term.coefficient
    end
    nonzero_terms = filter(term -> !iszero(last(term)), collect(coefficients))
    length(nonzero_terms) == 1 || return nothing
    variable, coefficient = only(nonzero_terms)
    iszero(coefficient) && return nothing
    lower, upper = interval
    translated_lower = isnothing(lower) ? nothing :
                       (lower - function_value.constant) / coefficient
    translated_upper = isnothing(upper) ? nothing :
                       (upper - function_value.constant) / coefficient
    if coefficient < 0
        translated_lower, translated_upper = translated_upper, translated_lower
    end
    return variable, translated_lower, translated_upper
end

"""Report exact variable-interval implications of supported one-variable affine rows."""
function _analyze_affine_implied_variable_bounds!(
    report::DiagnosticReport,
    model::ModelSnapshot,
)
    implications = Dict{MOI.VariableIndex,Vector{Tuple{Any,Any,ConstraintRecord}}}()
    for constraint in model.constraints
        function_value = constraint.function_value
        function_value isa MOI.ScalarAffineFunction || continue
        implied = _single_variable_affine_interval(function_value, constraint.set_value)
        isnothing(implied) && continue
        variable, lower, upper = implied
        push!(get!(implications, variable, Tuple{Any,Any,ConstraintRecord}[]),
              (lower, upper, constraint))
    end
    records = Dict(record.index => record for record in model.variables)
    domains = Dict(domain.variable => domain for domain in variable_domains(model))
    for (variable, rows) in implications
        declared = domains[variable]
        lowers = Any[lower for (lower, _, _) in rows if !isnothing(lower)]
        uppers = Any[upper for (_, upper, _) in rows if !isnothing(upper)]
        !isnothing(declared.lower) && push!(lowers, declared.lower)
        !isnothing(declared.upper) && push!(uppers, declared.upper)
        lower = isempty(lowers) ? nothing : maximum(lowers)
        upper = isempty(uppers) ? nothing : minimum(uppers)
        record = records[variable]
        references = vcat(
            [_variable_ref(record)],
            _constraint_ref.([row[3] for row in rows]),
        )
        if !isnothing(lower) && !isnothing(upper) && lower > upper
            push!(report, Finding(
                :inconsistent_affine_implied_variable_bounds;
                severity = SeverityError,
                domain = MathematicalIssue,
                basis = MathematicalProof,
                confidence = ConfidenceCertain,
                observation = "One-variable affine constraints and declared bounds imply an empty interval [$lower, $upper] for variable $(_display_name(record)).",
                why_it_matters = "These exact scalar implications cannot be simultaneously satisfied, so the model is infeasible.",
                evidence = [Evidence("Affine implied-variable interval";
                    details = ["variable_index" => variable.value,
                               "effective_lower" => lower,
                               "effective_upper" => upper,
                               "affine_constraint_count" => length(rows)],
                )],
                suggested_actions = ["Inspect the one-variable affine rows, signs, constants, and variable-bound data."],
                affected = references,
            ))
        else
            push!(report, Finding(
                :affine_implied_variable_bound;
                severity = SeverityInfo,
                domain = RepresentationalIssue,
                basis = MathematicalProof,
                confidence = ConfidenceCertain,
                observation = "One-variable affine constraints imply variable $(_display_name(record)) lies in [$lower, $upper].",
                why_it_matters = "This exact derived interval can reveal hidden scaling, redundant bound construction, or safe presolve tightening opportunities without modifying the model.",
                evidence = [Evidence("Affine implied-variable interval";
                    details = ["variable_index" => variable.value,
                               "implied_lower" => lower,
                               "implied_upper" => upper,
                               "declared_lower" => declared.lower,
                               "declared_upper" => declared.upper,
                               "affine_constraint_count" => length(rows)],
                )],
                suggested_actions = ["Compare this derived interval with intended units and explicit variable bounds before applying any manual tightening."],
                affected = references,
            ))
        end
    end
    return
end

function _combined_affine_coefficients(function_value::MOI.ScalarAffineFunction)
    coefficients = Dict{MOI.VariableIndex,Any}()
    for term in function_value.terms
        coefficients[term.variable] = get(
            coefficients,
            term.variable,
            zero(term.coefficient),
        ) + term.coefficient
    end
    return filter(term -> !iszero(last(term)), coefficients)
end

function _other_affine_interval(
    coefficients,
    target::MOI.VariableIndex,
    constant,
    domains,
)
    lower, upper = constant, constant
    for (variable, coefficient) in coefficients
        variable == target && continue
        domain = get(domains, variable, nothing)
        isnothing(domain) && return nothing
        domain_lower = domain isa Tuple ? domain[1] : domain.lower
        domain_upper = domain isa Tuple ? domain[2] : domain.upper
        isnothing(domain_lower) && return nothing
        isnothing(domain_upper) && return nothing
        isfinite(domain_lower) && isfinite(domain_upper) || return nothing
        if coefficient > 0
            lower += coefficient * domain_lower
            upper += coefficient * domain_upper
        else
            lower += coefficient * domain_upper
            upper += coefficient * domain_lower
        end
    end
    return lower, upper
end

"""One-pass, report-only bound propagation through supported multi-variable affine rows."""
function _analyze_affine_interval_propagation!(
    report::DiagnosticReport,
    model::ModelSnapshot,
)
    domains = Dict(domain.variable => domain for domain in variable_domains(model))
    implications = Dict{MOI.VariableIndex,Vector{Tuple{Any,Any,ConstraintRecord}}}()
    for constraint in model.constraints
        function_value = constraint.function_value
        function_value isa MOI.ScalarAffineFunction || continue
        interval = _scalar_set_interval(constraint.set_value)
        isnothing(interval) && continue
        coefficients = _combined_affine_coefficients(function_value)
        length(coefficients) >= 2 || continue
        row_lower, row_upper = interval
        for (variable, coefficient) in coefficients
            others = _other_affine_interval(
                coefficients,
                variable,
                function_value.constant,
                domains,
            )
            isnothing(others) && continue
            others_lower, others_upper = others
            implied_lower = nothing
            implied_upper = nothing
            if !isnothing(row_lower)
                candidate = (row_lower - others_upper) / coefficient
                coefficient > 0 ? (implied_lower = candidate) : (implied_upper = candidate)
            end
            if !isnothing(row_upper)
                candidate = (row_upper - others_lower) / coefficient
                coefficient > 0 ? (implied_upper = candidate) : (implied_lower = candidate)
            end
            push!(get!(implications, variable, Tuple{Any,Any,ConstraintRecord}[]),
                  (implied_lower, implied_upper, constraint))
        end
    end
    records = Dict(record.index => record for record in model.variables)
    for (variable, rows) in implications
        domain = domains[variable]
        lowers = Any[lower for (lower, _, _) in rows if !isnothing(lower)]
        uppers = Any[upper for (_, upper, _) in rows if !isnothing(upper)]
        !isnothing(domain.lower) && push!(lowers, domain.lower)
        !isnothing(domain.upper) && push!(uppers, domain.upper)
        lower = isempty(lowers) ? nothing : maximum(lowers)
        upper = isempty(uppers) ? nothing : minimum(uppers)
        record = records[variable]
        references = vcat(
            [_variable_ref(record)],
            _constraint_ref.([row[3] for row in rows]),
        )
        if !isnothing(lower) && !isnothing(upper) && lower > upper
            push!(report, Finding(
                :inconsistent_affine_interval_propagation;
                severity = SeverityError,
                domain = MathematicalIssue,
                basis = MathematicalProof,
                confidence = ConfidenceCertain,
                observation = "Declared bounds and one-pass affine interval propagation imply an empty interval [$lower, $upper] for variable $(_display_name(record)).",
                why_it_matters = "Every propagated bound follows exactly from a scalar affine row and the declared bounds of its other variables, so the combined interval is infeasible.",
                evidence = [Evidence("One-pass affine interval propagation";
                    details = ["variable_index" => variable.value,
                               "effective_lower" => lower,
                               "effective_upper" => upper,
                               "source_row_count" => length(rows)],
                )],
                suggested_actions = ["Inspect the affine row coefficients and the declared bounds used for propagation."],
                affected = references,
            ))
        else
            tightened_lower = !isnothing(lower) &&
                              (isnothing(domain.lower) || lower > domain.lower)
            tightened_upper = !isnothing(upper) &&
                              (isnothing(domain.upper) || upper < domain.upper)
            (tightened_lower || tightened_upper) || continue
            push!(report, Finding(
                :affine_interval_propagated_variable_bound;
                severity = SeverityInfo,
                domain = RepresentationalIssue,
                basis = MathematicalProof,
                confidence = ConfidenceCertain,
                observation = "One-pass affine interval propagation tightens the derived interval for variable $(_display_name(record)) to [$lower, $upper].",
                why_it_matters = "This is a safe presolve implication from declared bounds, but the debugger leaves the model unchanged and does not iterate the propagation automatically.",
                evidence = [Evidence("One-pass affine interval propagation";
                    details = ["variable_index" => variable.value,
                               "derived_lower" => lower,
                               "derived_upper" => upper,
                               "declared_lower" => domain.lower,
                               "declared_upper" => domain.upper,
                               "source_row_count" => length(rows)],
                )],
                suggested_actions = ["Review the derived interval and its units before applying manual bounds or a separate presolve workflow."],
                affected = references,
            ))
        end
    end
    return
end

"""Bounded fixed-point, report-only propagation through supported affine rows."""
function _analyze_affine_interval_fixed_point!(
    report::DiagnosticReport,
    model::ModelSnapshot,
    max_passes::Integer,
)
    max_passes > 0 || throw(ArgumentError("max_affine_propagation_passes must be positive"))
    domains = Dict(domain.variable => domain for domain in variable_domains(model))
    initial = Dict(variable => (domain.lower, domain.upper) for (variable, domain) in domains)
    bounds = copy(initial)
    sources = Dict{MOI.VariableIndex,Vector{ConstraintRecord}}()
    passes = 0
    converged = false
    for pass in 1:max_passes
        passes = pass
        candidates = Dict{MOI.VariableIndex,Vector{Tuple{Any,Any,ConstraintRecord}}}()
        for constraint in model.constraints
            function_value = constraint.function_value
            function_value isa MOI.ScalarAffineFunction || continue
            interval = _scalar_set_interval(constraint.set_value)
            isnothing(interval) && continue
            coefficients = _combined_affine_coefficients(function_value)
            length(coefficients) >= 2 || continue
            row_lower, row_upper = interval
            for (variable, coefficient) in coefficients
                others = _other_affine_interval(
                    coefficients, variable, function_value.constant, bounds,
                )
                isnothing(others) && continue
                other_lower, other_upper = others
                lower = isnothing(row_lower) ? nothing :
                        (row_lower - other_upper) / coefficient
                upper = isnothing(row_upper) ? nothing :
                        (row_upper - other_lower) / coefficient
                coefficient < 0 && ((lower, upper) = (upper, lower))
                push!(get!(candidates, variable, Tuple{Any,Any,ConstraintRecord}[]),
                      (lower, upper, constraint))
            end
        end
        changed = false
        for (variable, rows) in candidates
            current_lower, current_upper = bounds[variable]
            lowers = Any[lower for (lower, _, _) in rows if !isnothing(lower)]
            uppers = Any[upper for (_, upper, _) in rows if !isnothing(upper)]
            lower = isempty(lowers) ? current_lower :
                    isnothing(current_lower) ? maximum(lowers) : max(current_lower, maximum(lowers))
            upper = isempty(uppers) ? current_upper :
                    isnothing(current_upper) ? minimum(uppers) : min(current_upper, minimum(uppers))
            changed |= lower != current_lower || upper != current_upper
            bounds[variable] = (lower, upper)
            append!(get!(sources, variable, ConstraintRecord[]), [row[3] for row in rows])
        end
        if !changed
            converged = true
            break
        end
    end
    report.metadata[:affine_interval_propagation_passes] = string(passes)
    report.metadata[:affine_interval_propagation_converged] = string(converged)
    if !converged
        push!(report, Finding(:affine_interval_propagation_limit_reached;
            severity = SeverityInfo, domain = RepresentationalIssue,
            basis = StructuralProof, confidence = ConfidenceCertain,
            observation = "Affine interval propagation reached its configured limit of $max_passes pass(es) before stabilizing.",
            why_it_matters = "Additional report-only affine tightening may be available, but the analysis intentionally stops at its documented bound rather than running an unbounded presolver loop.",
            evidence = [Evidence("Affine propagation limit"; details = [
                "completed_passes" => passes,
                "max_passes" => max_passes,
            ])],
            suggested_actions = ["Increase max_affine_propagation_passes only when further exact affine propagation is useful for diagnosis."],
        ))
    end
    records = Dict(record.index => record for record in model.variables)
    for (variable, rows) in sources
        lower, upper = bounds[variable]
        initial_lower, initial_upper = initial[variable]
        record = records[variable]
        references = vcat([_variable_ref(record)], _constraint_ref.(unique(rows)))
        if !isnothing(lower) && !isnothing(upper) && lower > upper
            push!(report, Finding(:inconsistent_affine_interval_propagation;
                severity = SeverityError, domain = MathematicalIssue,
                basis = MathematicalProof, confidence = ConfidenceCertain,
                observation = "Declared bounds and bounded affine interval propagation imply an empty interval [$lower, $upper] for variable $(_display_name(record)).",
                why_it_matters = "Every propagated bound follows exactly from a scalar affine row and bounds available in an earlier propagation pass, so the combined interval is infeasible.",
                evidence = [Evidence("Bounded affine interval propagation"; details = [
                    "variable_index" => variable.value, "effective_lower" => lower,
                    "effective_upper" => upper, "pass_count" => passes,
                    "converged" => converged,
                ])],
                suggested_actions = ["Inspect the affine row coefficients and the bounds used for propagation."],
                affected = references,
            ))
        elseif !isnothing(lower) && !isnothing(upper) && lower == upper &&
               (isnothing(initial_lower) || isnothing(initial_upper) ||
                initial_lower != lower || initial_upper != upper)
            push!(report, Finding(:affine_interval_propagated_variable_fixed;
                severity = SeverityInfo, domain = RepresentationalIssue,
                basis = MathematicalProof, confidence = ConfidenceCertain,
                observation = "Bounded affine interval propagation fixes variable $(_display_name(record)) at $lower.",
                why_it_matters = "The supported affine rows and available bounds leave exactly one value for this variable. This can expose an unexpected loss of freedom or a safe presolve substitution opportunity.",
                evidence = [Evidence("Bounded affine interval propagation"; details = [
                    "variable_index" => variable.value, "derived_value" => lower,
                    "declared_lower" => initial_lower, "declared_upper" => initial_upper,
                    "pass_count" => passes, "converged" => converged,
                ])],
                suggested_actions = ["Confirm that this derived fixing is intended before manually substituting or eliminating the variable."],
                affected = references,
            ))
        elseif (!isnothing(lower) && (isnothing(initial_lower) || lower > initial_lower)) ||
               (!isnothing(upper) && (isnothing(initial_upper) || upper < initial_upper))
            push!(report, Finding(:affine_interval_propagated_variable_bound;
                severity = SeverityInfo, domain = RepresentationalIssue,
                basis = MathematicalProof, confidence = ConfidenceCertain,
                observation = "Bounded affine interval propagation tightens the derived interval for variable $(_display_name(record)) to [$lower, $upper].",
                why_it_matters = "This is a safe presolve implication from declared bounds and earlier affine passes; the debugger leaves the model unchanged.",
                evidence = [Evidence("Bounded affine interval propagation"; details = [
                    "variable_index" => variable.value, "derived_lower" => lower,
                    "derived_upper" => upper, "declared_lower" => initial_lower,
                    "declared_upper" => initial_upper, "pass_count" => passes,
                    "converged" => converged,
                ])],
                suggested_actions = ["Review the derived interval and its units before applying manual bounds."],
                affected = references,
            ))
        end
    end
    return
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
    max_affine_propagation_passes::Integer = 5,
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
    _analyze_fixed_expression_constraints!(report, model)
    _analyze_constant_objective!(report, model)
    _analyze_fixed_objective!(report, model)
    _analyze_nonzero_self_divisions!(report, model)
    _analyze_unconstrained_affine_objective_rays!(report, model)
    _analyze_unconstrained_quadratic_objective_rays!(report, model)
    _analyze_duplicate_constraints!(report, model)
    _analyze_proportional_affine_equalities!(report, model)
    _analyze_proportional_affine_inequalities!(report, model)
    _analyze_dominated_affine_inequalities!(report, model)
    _analyze_affine_equality_halfspace_consistency!(report, model)
    _analyze_inconsistent_opposing_affine_inequalities!(report, model)
    _analyze_reused_constraint_expressions!(report, model)
    _analyze_affine_implied_variable_bounds!(report, model)
    _analyze_affine_interval_fixed_point!(
        report,
        model,
        max_affine_propagation_passes,
    )
    _analyze_circular_normalization!(report, model)
    _analyze_disconnected_variables!(report, model, graph)
    sort!(
        report.findings;
        by = finding -> (-Int(finding.severity), string(finding.code)),
    )
    return report
end

analyze_static(model::MOI.ModelLike; kwargs...) = analyze_static(snapshot(model); kwargs...)
