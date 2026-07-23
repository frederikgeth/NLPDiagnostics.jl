@enum DomainAssessment::UInt8 begin
    DomainSafe = 0
    DomainPossibleViolation = 1
    DomainProvenViolation = 2
end

"""
A conservative interval enclosure derived from declared variable domains.

`valid == false` means the source variable bounds were already inconsistent.
`informative == false` means an unsupported operation widened the enclosure to
the full real line.
"""
struct IntervalEnclosure
    lower::Real
    upper::Real
    valid::Bool
    informative::Bool
end

IntervalEnclosure(lower::Real, upper::Real) =
    IntervalEnclosure(lower, upper, true, true)

_full_interval(; informative::Bool = false) =
    IntervalEnclosure(-Inf, Inf, true, informative)

_invalid_interval() = IntervalEnclosure(Inf, -Inf, false, false)

"""
A normalized path to an expression node inside an objective or constraint.

`arguments` contains one-based nonlinear argument indices from the source
root. Vector constraint rows are represented by `source.subindex`.
"""
struct ExpressionNodePath
    source::EntityRef
    arguments::Vector{Int}
end

struct ExpressionDomainIssue
    path::ExpressionNodePath
    operator::Symbol
    argument::Int
    assessment::DomainAssessment
    requirement::String
    enclosure::IntervalEnclosure
    variables::Vector{MOI.VariableIndex}
end

function Base.show(io::IO, path::ExpressionNodePath)
    source = if path.source.kind == :objective
        "objective"
    elseif isnothing(path.source.subindex)
        "constraint[$(path.source.index)]"
    else
        "constraint[$(path.source.index)]/row[$(path.source.subindex)]"
    end
    print(io, source)
    for argument in path.arguments
        print(io, "/arg[$argument]")
    end
    return
end

_path_string(path::ExpressionNodePath) = sprint(show, path)

function _domain_variable_intervals(model::ModelSnapshot)
    intervals = Dict(
        record.index => _full_interval(informative = true) for
        record in model.variables
    )
    for constraint in model.constraints
        variable = constraint.function_value
        variable isa MOI.VariableIndex || continue
        current = intervals[variable]
        set_value = constraint.set_value
        candidate = if set_value isa MOI.Parameter
            set_value.value isa Real || continue
            IntervalEnclosure(set_value.value, set_value.value)
        elseif set_value isa MOI.EqualTo
            IntervalEnclosure(set_value.value, set_value.value)
        elseif set_value isa MOI.Interval
            IntervalEnclosure(set_value.lower, set_value.upper)
        elseif set_value isa MOI.GreaterThan
            IntervalEnclosure(set_value.lower, Inf)
        elseif set_value isa MOI.LessThan
            IntervalEnclosure(-Inf, set_value.upper)
        elseif set_value isa MOI.ZeroOne
            IntervalEnclosure(0.0, 1.0)
        elseif set_value isa MOI.Semicontinuous ||
               set_value isa MOI.Semiinteger
            IntervalEnclosure(
                min(0.0, set_value.lower),
                max(0.0, set_value.upper),
            )
        else
            continue
        end
        lower = max(current.lower, candidate.lower)
        upper = min(current.upper, candidate.upper)
        intervals[variable] = lower <= upper ?
                              IntervalEnclosure(
            lower,
            upper,
            true,
            current.informative && candidate.informative,
        ) : _invalid_interval()
    end
    return intervals
end

function _interval_add(
    left::IntervalEnclosure,
    right::IntervalEnclosure,
)
    left.valid && right.valid || return _invalid_interval()
    lower = left.lower + right.lower
    upper = left.upper + right.upper
    (isnan(lower) || isnan(upper)) && return _full_interval()
    return IntervalEnclosure(
        lower,
        upper,
        true,
        left.informative && right.informative,
    )
end

function _interval_scale(value::IntervalEnclosure, coefficient::Real)
    value.valid || return _invalid_interval()
    coefficient_value = coefficient
    iszero(coefficient_value) && return IntervalEnclosure(0.0, 0.0)
    isfinite(coefficient_value) || return _full_interval()
    if coefficient_value > 0
        return IntervalEnclosure(
            coefficient_value * value.lower,
            coefficient_value * value.upper,
            true,
            value.informative,
        )
    end
    return IntervalEnclosure(
        coefficient_value * value.upper,
        coefficient_value * value.lower,
        true,
        value.informative,
    )
end

function _interval_multiply(
    left::IntervalEnclosure,
    right::IntervalEnclosure,
)
    left.valid && right.valid || return _invalid_interval()
    if left.lower == left.upper == 0.0 ||
       right.lower == right.upper == 0.0
        return IntervalEnclosure(0.0, 0.0)
    end
    products = Real[
        left.lower * right.lower,
        left.lower * right.upper,
        left.upper * right.lower,
        left.upper * right.upper,
    ]
    any(isnan, products) && return _full_interval()
    return IntervalEnclosure(
        minimum(products),
        maximum(products),
        true,
        left.informative && right.informative,
    )
end

_contains_zero(value::IntervalEnclosure) =
    value.valid && value.lower <= 0.0 <= value.upper

function _interval_reciprocal(value::IntervalEnclosure)
    value.valid || return _invalid_interval()
    _contains_zero(value) && return _full_interval()
    endpoints = (inv(value.lower), inv(value.upper))
    return IntervalEnclosure(
        min(endpoints...),
        max(endpoints...),
        true,
        value.informative,
    )
end

function _interval_integer_power(value::IntervalEnclosure, exponent::Int)
    value.valid || return _invalid_interval()
    iszero(exponent) && return IntervalEnclosure(1.0, 1.0)
    if exponent < 0
        _contains_zero(value) && return _full_interval()
        return _interval_reciprocal(
            _interval_integer_power(value, -exponent),
        )
    end
    if iseven(exponent)
        lower = _contains_zero(value) ?
                0.0 :
                min(abs(value.lower)^exponent, abs(value.upper)^exponent)
        upper = max(abs(value.lower)^exponent, abs(value.upper)^exponent)
        return IntervalEnclosure(
            lower,
            upper,
            true,
            value.informative,
        )
    end
    return IntervalEnclosure(
        value.lower^exponent,
        value.upper^exponent,
        true,
        value.informative,
    )
end

function _interval_affine(
    value::MOI.ScalarAffineFunction,
    variable_intervals,
)
    result = IntervalEnclosure(value.constant, value.constant)
    for term in value.terms
        iszero(term.coefficient) && continue
        variable_interval = get(
            variable_intervals,
            term.variable,
            _full_interval(),
        )
        result = _interval_add(
            result,
            _interval_scale(variable_interval, term.coefficient),
        )
    end
    return result
end

function _interval_quadratic(
    value::MOI.ScalarQuadraticFunction,
    variable_intervals,
)
    affine = MOI.ScalarAffineFunction(
        value.affine_terms,
        value.constant,
    )
    result = _interval_affine(affine, variable_intervals)
    for term in value.quadratic_terms
        iszero(term.coefficient) && continue
        left = get(
            variable_intervals,
            term.variable_1,
            _full_interval(),
        )
        right = get(
            variable_intervals,
            term.variable_2,
            _full_interval(),
        )
        product, coefficient = if term.variable_1 == term.variable_2
            (
                _interval_integer_power(left, 2),
                term.coefficient / 2,
            )
        else
            (
                _interval_multiply(left, right),
                term.coefficient,
            )
        end
        result = _interval_add(
            result,
            _interval_scale(
                product,
                coefficient,
            ),
        )
    end
    return result
end

function _base_interval(value, variable_intervals)
    if value isa Real
        return IntervalEnclosure(value, value)
    elseif value isa MOI.VariableIndex
        return get(variable_intervals, value, _full_interval())
    elseif value isa MOI.ScalarAffineFunction
        return _interval_affine(value, variable_intervals)
    elseif value isa MOI.ScalarQuadraticFunction
        return _interval_quadratic(value, variable_intervals)
    end
    return _full_interval()
end

function _lower_domain_assessment(
    enclosure::IntervalEnclosure,
    threshold::Real;
    strict::Bool,
)
    enclosure.valid || return DomainSafe
    if strict
        enclosure.upper <= threshold && return DomainProvenViolation
        enclosure.lower <= threshold && return DomainPossibleViolation
    else
        enclosure.upper < threshold && return DomainProvenViolation
        enclosure.lower < threshold && return DomainPossibleViolation
    end
    return DomainSafe
end

function _nonzero_domain_assessment(enclosure::IntervalEnclosure)
    enclosure.valid || return DomainSafe
    enclosure.lower == enclosure.upper == 0.0 &&
        return DomainProvenViolation
    _contains_zero(enclosure) && return DomainPossibleViolation
    return DomainSafe
end

function _push_domain_issue!(
    issues::Vector{ExpressionDomainIssue},
    source::EntityRef,
    operator_path::Vector{Int},
    operator::Symbol,
    argument::Int,
    assessment::DomainAssessment,
    requirement::String,
    enclosure::IntervalEnclosure,
    argument_value,
)
    assessment == DomainSafe && return
    support = variable_support(argument_value)
    push!(
        issues,
        ExpressionDomainIssue(
            ExpressionNodePath(source, copy(operator_path)),
            operator,
            argument,
            assessment,
            requirement,
            enclosure,
            support.variables,
        ),
    )
    return
end

function _operator_symbol(operator::Val)
    return typeof(operator).parameters[1]
end

"""
    operator_interval(Val(operator), argument_intervals, original_arguments)

Return a conservative range enclosure for an operator. Packages registering
custom nonlinear operators may extend this function. The fallback is the full
real line.
"""
function operator_interval(
    operator::Val,
    arguments::Vector{IntervalEnclosure},
    original_arguments,
)
    head = _operator_symbol(operator)
    if head == :+
        return foldl(
            _interval_add,
            arguments;
            init = IntervalEnclosure(0.0, 0.0),
        )
    elseif head == :-
        isempty(arguments) && return _full_interval()
        length(arguments) == 1 &&
            return _interval_scale(only(arguments), -1.0)
        return foldl(
            (left, right) ->
                _interval_add(left, _interval_scale(right, -1.0)),
            arguments[2:end];
            init = arguments[1],
        )
    elseif head == :*
        return foldl(
            _interval_multiply,
            arguments;
            init = IntervalEnclosure(1.0, 1.0),
        )
    elseif head == :/
        isempty(arguments) && return _full_interval()
        return foldl(
            (left, right) ->
                _interval_multiply(left, _interval_reciprocal(right)),
            arguments[2:end];
            init = arguments[1],
        )
    elseif head == :inv
        return isempty(arguments) ?
               _full_interval() :
               _interval_reciprocal(first(arguments))
    elseif head == :sqrt
        value = only(arguments)
        value.valid || return _invalid_interval()
        value.upper < 0.0 && return _full_interval()
        return IntervalEnclosure(
            sqrt(max(0.0, value.lower)),
            sqrt(max(0.0, value.upper)),
            true,
            value.informative,
        )
    elseif head == :log || head == :log10 || head == :log2
        value = only(arguments)
        value.valid || return _invalid_interval()
        value.upper <= 0.0 && return _full_interval()
        log_function = head == :log10 ? log10 : head == :log2 ? log2 : log
        lower =
            value.lower <= 0.0 ? -Inf : log_function(value.lower)
        upper = log_function(value.upper)
        return IntervalEnclosure(
            lower,
            upper,
            true,
            value.informative,
        )
    elseif head == :log1p
        value = only(arguments)
        value.valid || return _invalid_interval()
        value.upper <= -1.0 && return _full_interval()
        lower = value.lower <= -1.0 ? -Inf : log1p(value.lower)
        upper = log1p(value.upper)
        return IntervalEnclosure(
            lower,
            upper,
            true,
            value.informative,
        )
    elseif head == :exp
        value = only(arguments)
        return IntervalEnclosure(
            exp(value.lower),
            exp(value.upper),
            value.valid,
            value.informative,
        )
    elseif head == :exp2
        value = only(arguments)
        return IntervalEnclosure(
            exp2(value.lower),
            exp2(value.upper),
            value.valid,
            value.informative,
        )
    elseif head == :expm1
        value = only(arguments)
        return IntervalEnclosure(
            expm1(value.lower),
            expm1(value.upper),
            value.valid,
            value.informative,
        )
    elseif head in (:log1pexp, :log1exp, :softplus)
        value = only(arguments)
        stable_softplus(x) =
            x > 0 ? x + log1p(exp(-x)) : log1p(exp(x))
        return IntervalEnclosure(
            stable_softplus(value.lower),
            stable_softplus(value.upper),
            value.valid,
            value.informative,
        )
    elseif head == :abs
        value = only(arguments)
        lower = _contains_zero(value) ?
                0.0 :
                min(abs(value.lower), abs(value.upper))
        return IntervalEnclosure(
            lower,
            max(abs(value.lower), abs(value.upper)),
            value.valid,
            value.informative,
        )
    elseif head == :sin || head == :cos
        return IntervalEnclosure(-1.0, 1.0, true, false)
    elseif head == :tan
        return _full_interval()
    elseif head == :^ && length(arguments) == 2
        exponent = original_arguments[2]
        integer_exponent = _integer_exponent(exponent)
        if !isnothing(integer_exponent)
            return _interval_integer_power(
                arguments[1],
                integer_exponent,
            )
        end
        if exponent isa Real && arguments[1].lower >= 0.0
            exponent_value = Float64(exponent)
            if exponent_value > 0
                return IntervalEnclosure(
                    arguments[1].lower^exponent_value,
                    arguments[1].upper^exponent_value,
                    true,
                    arguments[1].informative,
                )
            elseif exponent_value < 0 && arguments[1].lower > 0.0
                return IntervalEnclosure(
                    arguments[1].upper^exponent_value,
                    arguments[1].lower^exponent_value,
                    true,
                    arguments[1].informative,
                )
            end
        end
        return _full_interval()
    end
    return _full_interval()
end

function _integer_exponent(value)
    value isa Real || return nothing
    isinteger(value) || return nothing
    try
        return Int(value)
    catch
        return nothing
    end
end

function _bounded_domain_assessment(
    enclosure::IntervalEnclosure,
    lower::Real,
    upper::Real;
    lower_strict::Bool,
    upper_strict::Bool,
)
    enclosure.valid || return DomainSafe
    wholly_below =
        lower_strict ? enclosure.upper <= lower : enclosure.upper < lower
    wholly_above =
        upper_strict ? enclosure.lower >= upper : enclosure.lower > upper
    (wholly_below || wholly_above) && return DomainProvenViolation
    crosses_lower =
        lower_strict ? enclosure.lower <= lower : enclosure.lower < lower
    crosses_upper =
        upper_strict ? enclosure.upper >= upper : enclosure.upper > upper
    (crosses_lower || crosses_upper) && return DomainPossibleViolation
    return DomainSafe
end

function _absolute_outside_assessment(
    enclosure::IntervalEnclosure,
    threshold::Real;
    strict::Bool,
)
    enclosure.valid || return DomainSafe
    invalid_lower = strict ? -threshold : -threshold
    invalid_upper = strict ? threshold : threshold
    wholly_invalid = strict ?
                      (
        enclosure.lower >= invalid_lower &&
        enclosure.upper <= invalid_upper
    ) :
                      (
        enclosure.lower > invalid_lower &&
        enclosure.upper < invalid_upper
    )
    wholly_invalid && return DomainProvenViolation
    intersects_invalid = strict ?
                         (
        enclosure.upper >= invalid_lower &&
        enclosure.lower <= invalid_upper
    ) :
                         (
        enclosure.upper > invalid_lower &&
        enclosure.lower < invalid_upper
    )
    intersects_invalid && return DomainPossibleViolation
    return DomainSafe
end

struct OperatorDomainRequirement
    argument::Int
    assessment::DomainAssessment
    requirement::String
end

"""
    operator_domain_requirements(
        Val(operator),
        original_arguments,
        argument_intervals,
    )

Return domain requirements for a nonlinear operator. Custom operator packages
may add a method specialized on `Val{:operator_name}`.
"""
function operator_domain_requirements(
    operator::Val,
    original_arguments,
    argument_intervals::Vector{IntervalEnclosure},
)
    head = _operator_symbol(operator)
    requirements = OperatorDomainRequirement[]
    if head == :log || head == :log10 || head == :log2
        push!(
            requirements,
            OperatorDomainRequirement(
                1,
                _lower_domain_assessment(
                    argument_intervals[1],
                    0.0;
                    strict = true,
                ),
                "argument > 0",
            ),
        )
    elseif head == :log1p
        push!(
            requirements,
            OperatorDomainRequirement(
                1,
                _lower_domain_assessment(
                    argument_intervals[1],
                    -1.0;
                    strict = true,
                ),
                "argument > -1",
            ),
        )
    elseif head == :sqrt
        push!(
            requirements,
            OperatorDomainRequirement(
                1,
                _lower_domain_assessment(
                    argument_intervals[1],
                    0.0;
                    strict = false,
                ),
                "argument ≥ 0",
            ),
        )
    elseif head in (:asin, :acos, :asind, :acosd)
        push!(
            requirements,
            OperatorDomainRequirement(
                1,
                _bounded_domain_assessment(
                    argument_intervals[1],
                    -1.0,
                    1.0;
                    lower_strict = false,
                    upper_strict = false,
                ),
                "-1 ≤ argument ≤ 1",
            ),
        )
    elseif head in (:asec, :acsc, :asecd, :acscd)
        push!(
            requirements,
            OperatorDomainRequirement(
                1,
                _absolute_outside_assessment(
                    argument_intervals[1],
                    1.0;
                    strict = false,
                ),
                "|argument| ≥ 1",
            ),
        )
    elseif head == :acosh
        push!(
            requirements,
            OperatorDomainRequirement(
                1,
                _lower_domain_assessment(
                    argument_intervals[1],
                    1.0;
                    strict = false,
                ),
                "argument ≥ 1",
            ),
        )
    elseif head == :atanh
        push!(
            requirements,
            OperatorDomainRequirement(
                1,
                _bounded_domain_assessment(
                    argument_intervals[1],
                    -1.0,
                    1.0;
                    lower_strict = true,
                    upper_strict = true,
                ),
                "-1 < argument < 1",
            ),
        )
    elseif head == :asech
        push!(
            requirements,
            OperatorDomainRequirement(
                1,
                _bounded_domain_assessment(
                    argument_intervals[1],
                    0.0,
                    1.0;
                    lower_strict = true,
                    upper_strict = false,
                ),
                "0 < argument ≤ 1",
            ),
        )
    elseif head == :acsch
        push!(
            requirements,
            OperatorDomainRequirement(
                1,
                _nonzero_domain_assessment(argument_intervals[1]),
                "argument ≠ 0",
            ),
        )
    elseif head == :acoth
        push!(
            requirements,
            OperatorDomainRequirement(
                1,
                _absolute_outside_assessment(
                    argument_intervals[1],
                    1.0;
                    strict = true,
                ),
                "|argument| > 1",
            ),
        )
    elseif head in (:tan, :sec)
        push!(
            requirements,
            OperatorDomainRequirement(
                1,
                _periodic_singularity_assessment(
                    argument_intervals[1],
                    pi / 2,
                    pi,
                ),
                "cos(argument) ≠ 0",
            ),
        )
    elseif head in (:csc, :cot)
        push!(
            requirements,
            OperatorDomainRequirement(
                1,
                _periodic_singularity_assessment(
                    argument_intervals[1],
                    0.0,
                    pi,
                ),
                "sin(argument) ≠ 0",
            ),
        )
    elseif head in (:tand, :secd)
        push!(
            requirements,
            OperatorDomainRequirement(
                1,
                _periodic_singularity_assessment(
                    argument_intervals[1],
                    90.0,
                    180.0,
                ),
                "cosd(argument) ≠ 0",
            ),
        )
    elseif head in (:cscd, :cotd)
        push!(
            requirements,
            OperatorDomainRequirement(
                1,
                _periodic_singularity_assessment(
                    argument_intervals[1],
                    0.0,
                    180.0,
                ),
                "sind(argument) ≠ 0",
            ),
        )
    elseif head == :/ && length(argument_intervals) > 1
        for argument_index in 2:length(argument_intervals)
            push!(
                requirements,
                OperatorDomainRequirement(
                    argument_index,
                    _nonzero_domain_assessment(
                        argument_intervals[argument_index],
                    ),
                    "denominator ≠ 0",
                ),
            )
        end
    elseif head == :inv
        push!(
            requirements,
            OperatorDomainRequirement(
                1,
                _nonzero_domain_assessment(argument_intervals[1]),
                "argument ≠ 0",
            ),
        )
    elseif head == :^ && length(argument_intervals) == 2
        exponent = original_arguments[2]
        integer_exponent = _integer_exponent(exponent)
        if !isnothing(integer_exponent)
            if integer_exponent < 0
                push!(
                    requirements,
                    OperatorDomainRequirement(
                        1,
                        _nonzero_domain_assessment(argument_intervals[1]),
                        "base ≠ 0 for a negative integer exponent",
                    ),
                )
            end
        else
            strict = exponent isa Real && exponent < 0
            push!(
                requirements,
                OperatorDomainRequirement(
                    1,
                    _lower_domain_assessment(
                        argument_intervals[1],
                        0.0;
                        strict = strict,
                    ),
                    strict ?
                    "base > 0 for a negative fractional exponent" :
                    "base ≥ 0 for a non-integer exponent",
                ),
            )
        end
    end
    return requirements
end

function _scan_domain_expression!(
    issues::Vector{ExpressionDomainIssue},
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
            _scan_domain_expression!(
                issues,
                argument,
                source,
                vcat(path, argument_index),
                variable_intervals,
            ),
        )
    end

    operator = Val(value.head)
    for requirement in operator_domain_requirements(
        operator,
        value.args,
        argument_intervals,
    )
        enclosure = argument_intervals[requirement.argument]
        _push_domain_issue!(
            issues,
            source,
            path,
            value.head,
            requirement.argument,
            requirement.assessment,
            requirement.requirement,
            enclosure,
            value.args[requirement.argument],
        )
    end
    return operator_interval(
        operator,
        argument_intervals,
        value.args,
    )
end

function _source_domain_issues!(
    issues::Vector{ExpressionDomainIssue},
    function_value,
    source::EntityRef,
    variable_intervals;
    skip_constant_source::Bool,
)
    support = variable_support(function_value)
    if skip_constant_source && support.complete && isempty(support.variables)
        return
    end
    _scan_domain_expression!(
        issues,
        function_value,
        source,
        Int[],
        variable_intervals,
    )
    return
end

"""
    domain_issues(snapshot::ModelSnapshot) -> Vector{ExpressionDomainIssue}

Inspect nonlinear expression domains without evaluating model functions.
"""
function domain_issues(model::ModelSnapshot)
    variable_intervals = _domain_variable_intervals(model)
    issues = ExpressionDomainIssue[]
    if !isnothing(model.objective)
        objective = model.objective
        source = EntityRef(
            :objective,
            1;
            function_type = string(typeof(objective.function_value)),
        )
        _source_domain_issues!(
            issues,
            objective.function_value,
            source,
            variable_intervals;
            skip_constant_source = false,
        )
    end
    for constraint in model.constraints
        function_value = constraint.function_value
        if function_value isa MOI.AbstractVectorFunction
            rows = try
                MOI.Utilities.scalarize(function_value)
            catch
                continue
            end
            for (row, scalar_function) in enumerate(rows)
                _source_domain_issues!(
                    issues,
                    scalar_function,
                    _constraint_ref(constraint; row = row),
                    variable_intervals;
                    skip_constant_source = true,
                )
            end
        else
            _source_domain_issues!(
                issues,
                function_value,
                _constraint_ref(constraint),
                variable_intervals;
                skip_constant_source = true,
            )
        end
    end
    return issues
end

domain_issues(model::MOI.ModelLike) = domain_issues(snapshot(model))

function _domain_issue_finding(
    issue::ExpressionDomainIssue,
    variable_records::Dict{MOI.VariableIndex,VariableRecord},
)
    proven = issue.assessment == DomainProvenViolation
    affected = EntityRef[issue.path.source]
    for variable in issue.variables
        haskey(variable_records, variable) || continue
        push!(affected, _variable_ref(variable_records[variable]))
    end
    interval = "[$(issue.enclosure.lower), $(issue.enclosure.upper)]"
    path = _path_string(issue.path)
    return Finding(
        proven ?
        :proven_expression_domain_violation :
        :possible_expression_domain_violation;
        severity = proven ? SeverityError : SeverityWarning,
        domain = MathematicalIssue,
        basis = proven ? MathematicalProof : HeuristicInterpretation,
        confidence = proven ?
                     ConfidenceCertain :
                     issue.enclosure.informative ?
                     ConfidenceHigh :
                     ConfidenceMedium,
        observation = proven ?
                      "Expression $path applies $(issue.operator) where every value allowed by the declared bounds violates $(issue.requirement)." :
                      "Expression $path applies $(issue.operator) where the conservative interval enclosure intersects values that violate $(issue.requirement).",
        why_it_matters = proven ?
                         "The real-valued expression is undefined throughout the current bound enclosure, independently of initialization or solver choice." :
                         "The expression may become undefined at a trial point, so line searches and derivative evaluation can fail even when the initial point is valid.",
        evidence = [
            Evidence(
                "Interval propagation at nonlinear argument $(issue.argument)";
                details = [
                    "path" => path,
                    "operator" => issue.operator,
                    "argument" => issue.argument,
                    "required_domain" => issue.requirement,
                    "argument_interval" => interval,
                    "interval_informative" => issue.enclosure.informative,
                    "assessment" => issue.assessment,
                ],
            ),
        ],
        suggested_actions = proven ?
                            [
            "Correct the bounds, data, or expression because no admissible real argument exists.",
        ] :
                            [
            "Tighten bounds to stay inside the operator domain when mathematically valid.",
            "Otherwise reformulate or choose an initialization and safeguards that respect the domain.",
        ],
        affected = affected,
    )
end

"""
    analyze_domains(snapshot::ModelSnapshot) -> DiagnosticReport

Create evidence-first findings from static expression-domain analysis.
"""
function analyze_domains(model::ModelSnapshot)
    issues = domain_issues(model)
    report = DiagnosticReport()
    report.metadata[:domain_issue_count] = string(length(issues))
    report.metadata[:proven_domain_violation_count] = string(
        count(
            issue -> issue.assessment == DomainProvenViolation,
            issues,
        ),
    )
    report.metadata[:possible_domain_violation_count] = string(
        count(
            issue -> issue.assessment == DomainPossibleViolation,
            issues,
        ),
    )
    records = Dict(record.index => record for record in model.variables)
    for issue in issues
        push!(report, _domain_issue_finding(issue, records))
    end
    return report
end

analyze_domains(model::MOI.ModelLike) = analyze_domains(snapshot(model))
