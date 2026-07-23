"""
A differentiability requirement imposed by a nonlinear primitive.

`order == 1` refers to the first derivative and `order == 2` to the
second derivative. `argument == 0` means the requirement concerns a
relationship between multiple arguments rather than one argument alone.
"""
struct OperatorDerivativeRequirement
    order::Int
    argument::Int
    assessment::DomainAssessment
    requirement::String
    enclosure::IntervalEnclosure
end

"""
A static or exact-point differentiability issue at one expression node.
"""
struct ExpressionDerivativeIssue
    path::ExpressionNodePath
    operator::Symbol
    order::Int
    argument::Int
    assessment::DomainAssessment
    requirement::String
    enclosure::IntervalEnclosure
    variables::Vector{MOI.VariableIndex}
end

function _interval_intersection(
    left::IntervalEnclosure,
    right::IntervalEnclosure,
)
    left.valid && right.valid || return _invalid_interval()
    lower = max(left.lower, right.lower)
    upper = min(left.upper, right.upper)
    lower <= upper || return _invalid_interval()
    return IntervalEnclosure(
        lower,
        upper,
        true,
        left.informative && right.informative,
    )
end

function _tie_assessment(
    left::IntervalEnclosure,
    right::IntervalEnclosure,
)
    overlap = _interval_intersection(left, right)
    overlap.valid || return DomainSafe, overlap
    if left.lower == left.upper == right.lower == right.upper
        return DomainProvenViolation, overlap
    end
    return DomainPossibleViolation, overlap
end

function _contains_periodic_point(
    interval::IntervalEnclosure,
    offset::Real,
    period::Real,
)
    interval.valid || return false
    (!isfinite(interval.lower) || !isfinite(interval.upper)) && return true
    first_index = ceil((interval.lower - offset) / period)
    last_index = floor((interval.upper - offset) / period)
    return first_index <= last_index
end

function _periodic_singularity_assessment(
    interval::IntervalEnclosure,
    offset::Real,
    period::Real,
)
    _contains_periodic_point(interval, offset, period) || return DomainSafe
    # Floating-point approximations of π are not exact symbolic poles.
    # Preserve this as a possible singularity until numerical probing observes
    # the actual value and derivative behavior.
    return DomainPossibleViolation
end

function _endpoint_assessment(
    interval::IntervalEnclosure,
    endpoints,
)
    interval.valid || return DomainSafe
    found = any(endpoint -> interval.lower <= endpoint <= interval.upper, endpoints)
    found || return DomainSafe
    if interval.lower == interval.upper &&
       any(endpoint -> interval.lower == endpoint, endpoints)
        return DomainProvenViolation
    end
    return DomainPossibleViolation
end

function _joint_zero_assessment(intervals)
    all(_contains_zero, intervals) || return DomainSafe
    all(interval -> interval.lower == interval.upper == 0.0, intervals) &&
        return DomainProvenViolation
    return DomainPossibleViolation
end

function _derivative_requirement(
    order,
    argument,
    assessment,
    requirement,
    enclosure,
)
    return OperatorDerivativeRequirement(
        order,
        argument,
        assessment,
        requirement,
        enclosure,
    )
end

"""
    operator_derivative_requirements(
        Val(operator),
        original_arguments,
        argument_intervals,
    )

Return conditions for finite classical first and second derivatives of a
nonlinear primitive. Custom operator packages may extend this function.

Value-domain conditions that are identical to derivative-domain conditions,
such as `log(x)` requiring `x > 0`, remain owned by
`operator_domain_requirements` and are not duplicated here.
"""
function operator_derivative_requirements(
    operator::Val,
    original_arguments,
    intervals::Vector{IntervalEnclosure},
)
    head = _operator_symbol(operator)
    requirements = OperatorDerivativeRequirement[]
    isempty(intervals) && return requirements
    value = intervals[1]
    if head == :sqrt
        assessment = _lower_domain_assessment(value, 0.0; strict = true)
        for order in 1:2
            push!(
                requirements,
                _derivative_requirement(
                    order,
                    1,
                    assessment,
                    "argument > 0 for a finite derivative",
                    value,
                ),
            )
        end
    elseif head == :cbrt
        assessment = _nonzero_domain_assessment(value)
        for order in 1:2
            push!(
                requirements,
                _derivative_requirement(
                    order,
                    1,
                    assessment,
                    "argument ≠ 0 for a finite derivative",
                    value,
                ),
            )
        end
    elseif head == :abs || head == :sign
        push!(
            requirements,
            _derivative_requirement(
                1,
                1,
                _nonzero_domain_assessment(value),
                "argument ≠ 0 for classical differentiability",
                value,
            ),
        )
    elseif head in (:asin, :acos, :asind, :acosd)
        assessment = _endpoint_assessment(value, (-1.0, 1.0))
        for order in 1:2
            push!(
                requirements,
                _derivative_requirement(
                    order,
                    1,
                    assessment,
                    "|argument| < 1 for a finite derivative",
                    value,
                ),
            )
        end
    elseif head in (:asec, :acsc, :asecd, :acscd)
        assessment = _endpoint_assessment(value, (-1.0, 1.0))
        for order in 1:2
            push!(
                requirements,
                _derivative_requirement(
                    order,
                    1,
                    assessment,
                    "|argument| > 1 for a finite derivative",
                    value,
                ),
            )
        end
    elseif head == :acosh
        assessment = _endpoint_assessment(value, (1.0,))
        for order in 1:2
            push!(
                requirements,
                _derivative_requirement(
                    order,
                    1,
                    assessment,
                    "argument > 1 for a finite derivative",
                    value,
                ),
            )
        end
    elseif head == :asech
        assessment = _endpoint_assessment(value, (0.0, 1.0))
        for order in 1:2
            push!(
                requirements,
                _derivative_requirement(
                    order,
                    1,
                    assessment,
                    "0 < argument < 1 for a finite derivative",
                    value,
                ),
            )
        end
    elseif head == :acsch
        assessment = _nonzero_domain_assessment(value)
        for order in 1:2
            push!(
                requirements,
                _derivative_requirement(
                    order,
                    1,
                    assessment,
                    "argument ≠ 0 for a finite derivative",
                    value,
                ),
            )
        end
    elseif head in (:tan, :sec)
        assessment =
            _periodic_singularity_assessment(value, pi / 2, pi)
        push!(
            requirements,
            _derivative_requirement(
                1,
                1,
                assessment,
                "cos(argument) ≠ 0",
                value,
            ),
        )
    elseif head in (:csc, :cot)
        assessment = _periodic_singularity_assessment(value, 0.0, pi)
        push!(
            requirements,
            _derivative_requirement(
                1,
                1,
                assessment,
                "sin(argument) ≠ 0",
                value,
            ),
        )
    elseif head in (:tand, :secd)
        assessment =
            _periodic_singularity_assessment(value, 90.0, 180.0)
        push!(
            requirements,
            _derivative_requirement(
                1,
                1,
                assessment,
                "cosd(argument) ≠ 0",
                value,
            ),
        )
    elseif head in (:cscd, :cotd)
        assessment =
            _periodic_singularity_assessment(value, 0.0, 180.0)
        push!(
            requirements,
            _derivative_requirement(
                1,
                1,
                assessment,
                "sind(argument) ≠ 0",
                value,
            ),
        )
    elseif head == :^ && length(intervals) == 2
        exponent = original_arguments[2]
        if exponent isa Real && !isinteger(exponent)
            exponent_value = Float64(exponent)
            if 0.0 < exponent_value < 1.0
                push!(
                    requirements,
                    _derivative_requirement(
                        1,
                        1,
                        _lower_domain_assessment(
                            intervals[1],
                            0.0;
                            strict = true,
                        ),
                        "base > 0 for a finite first derivative",
                        intervals[1],
                    ),
                )
            end
            if 0.0 < exponent_value < 2.0
                push!(
                    requirements,
                    _derivative_requirement(
                        2,
                        1,
                        _lower_domain_assessment(
                            intervals[1],
                            0.0;
                            strict = true,
                        ),
                        "base > 0 for a finite second derivative",
                        intervals[1],
                    ),
                )
            end
        elseif !(exponent isa Real)
            push!(
                requirements,
                _derivative_requirement(
                    1,
                    1,
                    _lower_domain_assessment(
                        intervals[1],
                        0.0;
                        strict = true,
                    ),
                    "base > 0 when differentiating a variable exponent",
                    intervals[1],
                ),
            )
        end
    elseif head in (:min, :max) && length(intervals) > 1
        assessment = DomainSafe
        overlap = _invalid_interval()
        for left in 1:(length(intervals)-1)
            for right in (left+1):length(intervals)
                pair_assessment, pair_overlap =
                    _tie_assessment(intervals[left], intervals[right])
                if pair_assessment > assessment
                    assessment = pair_assessment
                    overlap = pair_overlap
                end
            end
        end
        push!(
            requirements,
            _derivative_requirement(
                1,
                0,
                assessment,
                "a unique active argument for differentiability",
                overlap,
            ),
        )
    elseif head == :atan && length(intervals) == 2
        assessment = _joint_zero_assessment(intervals)
        push!(
            requirements,
            _derivative_requirement(
                1,
                0,
                assessment,
                "the two arguments must not both be zero",
                _interval_intersection(intervals[1], intervals[2]),
            ),
        )
    end
    return requirements
end

function _scan_derivative_expression!(
    issues::Vector{ExpressionDerivativeIssue},
    value,
    source::EntityRef,
    path::Vector{Int},
    variable_intervals,
)
    !(value isa MOI.ScalarNonlinearFunction) &&
        return _base_interval(value, variable_intervals)
    argument_intervals = IntervalEnclosure[]
    for (argument_index, argument) in enumerate(value.args)
        push!(
            argument_intervals,
            _scan_derivative_expression!(
                issues,
                argument,
                source,
                vcat(path, argument_index),
                variable_intervals,
            ),
        )
    end
    for requirement in operator_derivative_requirements(
        Val(value.head),
        value.args,
        argument_intervals,
    )
        requirement.assessment == DomainSafe && continue
        support = variable_support(value)
        push!(
            issues,
            ExpressionDerivativeIssue(
                ExpressionNodePath(source, copy(path)),
                value.head,
                requirement.order,
                requirement.argument,
                requirement.assessment,
                requirement.requirement,
                requirement.enclosure,
                support.variables,
            ),
        )
    end
    return operator_interval(Val(value.head), argument_intervals, value.args)
end

function _source_derivative_issues!(
    issues,
    function_value,
    source,
    variable_intervals,
)
    support = variable_support(function_value)
    support.complete && isempty(support.variables) && return
    _scan_derivative_expression!(
        issues,
        function_value,
        source,
        Int[],
        variable_intervals,
    )
    return
end

function _derivative_issues(
    model::ModelSnapshot,
    variable_intervals,
)
    issues = ExpressionDerivativeIssue[]
    if !isnothing(model.objective)
        objective = model.objective
        _source_derivative_issues!(
            issues,
            objective.function_value,
            _objective_ref(objective.function_value),
            variable_intervals,
        )
    end
    for constraint in model.constraints
        constraint.set_value isa MOI.VectorNonlinearOracle && continue
        rows = try
            _scalar_rows(constraint.function_value)
        catch
            continue
        end
        for (row, function_value) in enumerate(rows)
            _source_derivative_issues!(
                issues,
                function_value,
                _constraint_ref(
                    constraint;
                    row = length(rows) == 1 ? nothing : row,
                ),
                variable_intervals,
            )
        end
    end
    return issues
end

"""
    derivative_issues(model)

Inspect where declared variable domains include points at which nonlinear
primitives lack finite classical first or second derivatives.
"""
derivative_issues(model::ModelSnapshot) =
    _derivative_issues(model, _domain_variable_intervals(model))

derivative_issues(model::MOI.ModelLike) = derivative_issues(snapshot(model))

function _derivative_issue_finding(
    issue::ExpressionDerivativeIssue,
    variable_records;
    point::Union{Nothing,EvaluationPoint} = nothing,
)
    proven = issue.assessment == DomainProvenViolation
    at_point = !isnothing(point)
    affected = EntityRef[issue.path.source]
    for variable in issue.variables
        haskey(variable_records, variable) || continue
        push!(affected, _variable_ref(variable_records[variable]))
    end
    order_name = issue.order == 1 ? "first" : "second"
    code = at_point ?
           :operating_point_derivative_violation :
           proven ?
           :proven_derivative_domain_violation :
           :possible_derivative_domain_violation
    context = at_point ?
              "at point \"$(point.label)\"" :
              "within the declared bound enclosure"
    evidence = Evidence[
        Evidence(
            "Primitive differentiability requirement";
            details = [
                "path" => _path_string(issue.path),
                "operator" => issue.operator,
                "derivative_order" => issue.order,
                "argument" => issue.argument,
                "requirement" => issue.requirement,
                "argument_interval" =>
                    "[$(issue.enclosure.lower), $(issue.enclosure.upper)]",
                "assessment" => issue.assessment,
            ],
        ),
    ]
    isnothing(point) || pushfirst!(evidence, _point_evidence(point))
    return Finding(
        code;
        severity = proven || at_point ? SeverityError : SeverityWarning,
        domain = MathematicalIssue,
        basis = proven || at_point ?
                MathematicalProof :
                HeuristicInterpretation,
        confidence = proven || at_point ?
                     ConfidenceCertain :
                     issue.enclosure.informative ?
                     ConfidenceHigh :
                     ConfidenceMedium,
        observation = "Expression $(_path_string(issue.path)) applies $(issue.operator), whose finite $order_name derivative requires $(issue.requirement), but that requirement is violated or may be violated $context.",
        why_it_matters = "Gradient- and Hessian-based NLP algorithms can receive non-finite, discontinuous, or implementation-dependent derivative values even when the function value itself is valid.",
        evidence = evidence,
        suggested_actions = [
            "Keep iterates strictly inside the differentiability domain when mathematically appropriate.",
            "Otherwise use a smooth reformulation and document its approximation semantics.",
        ],
        affected = affected,
    )
end

"""
    analyze_derivatives(model; point = nothing)

Report derivative-domain issues from declared bounds or at an exact point.
"""
function analyze_derivatives(
    model::ModelSnapshot;
    point::Union{Nothing,EvaluationPoint} = nothing,
)
    variable_intervals = isnothing(point) ?
                         _domain_variable_intervals(model) :
                         Dict(
        variable => IntervalEnclosure(value, value, true, true) for
        (variable, value) in zip(point.variables, point.values)
    )
    issues = _derivative_issues(model, variable_intervals)
    if !isnothing(point)
        issues = filter(
            issue -> issue.assessment == DomainProvenViolation,
            issues,
        )
    end
    report = DiagnosticReport()
    records = Dict(record.index => record for record in model.variables)
    for issue in issues
        push!(
            report,
            _derivative_issue_finding(issue, records; point = point),
        )
    end
    report.metadata[:derivative_issue_count] = string(length(issues))
    report.metadata[:first_derivative_issue_count] =
        string(count(issue -> issue.order == 1, issues))
    report.metadata[:second_derivative_issue_count] =
        string(count(issue -> issue.order == 2, issues))
    return report
end

function analyze_derivatives(
    model::MOI.ModelLike;
    point::Union{Nothing,EvaluationPoint} = nothing,
)
    return analyze_derivatives(snapshot(model); point = point)
end
