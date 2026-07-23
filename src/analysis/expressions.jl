"""
One numerically risky expression pattern or primitive range.
"""
struct ExpressionNumericalRisk
    path::ExpressionNodePath
    code::Symbol
    assessment::DomainAssessment
    observation::String
    why_it_matters::String
    evidence::Vector{Pair{String,String}}
    suggested_actions::Vector{String}
    variables::Vector{MOI.VariableIndex}
end

_is_one(value) = value isa Real && value == one(value)
_is_minus_one(value) = value isa Real && value == -one(value)
_is_head(value, head) =
    value isa MOI.ScalarNonlinearFunction && value.head == head

function _addition_other_than_one(value)
    _is_head(value, :+) || return nothing
    length(value.args) == 2 || return nothing
    _is_one(value.args[1]) && return value.args[2]
    _is_one(value.args[2]) && return value.args[1]
    return nothing
end

function _negative_argument(value)
    _is_head(value, :-) || return nothing
    length(value.args) == 1 && return value.args[1]
    return nothing
end

function _risk_assessment_above(interval, threshold)
    interval.valid || return DomainSafe
    interval.lower > threshold && return DomainProvenViolation
    interval.upper > threshold && return DomainPossibleViolation
    return DomainSafe
end

function _risk_assessment_below(interval, threshold)
    interval.valid || return DomainSafe
    interval.upper < threshold && return DomainProvenViolation
    interval.lower < threshold && return DomainPossibleViolation
    return DomainSafe
end

function _push_expression_risk!(
    risks,
    source,
    path,
    value,
    code,
    assessment,
    observation,
    why_it_matters,
    evidence,
    actions,
)
    assessment == DomainSafe && return
    support = variable_support(value)
    push!(
        risks,
        ExpressionNumericalRisk(
            ExpressionNodePath(source, copy(path)),
            code,
            assessment,
            observation,
            why_it_matters,
            Pair{String,String}[
                string(first(item)) => string(last(item)) for item in evidence
            ],
            String.(actions),
            support.variables,
        ),
    )
    return
end

function _primitive_range_risks!(
    risks,
    value::MOI.ScalarNonlinearFunction,
    source,
    path,
    intervals,
    ::Type{T},
) where {T<:AbstractFloat}
    isempty(intervals) && return
    head = value.head
    input = intervals[1]
    if head in (:exp, :expm1)
        overflow_threshold = log(floatmax(T))
        zero_threshold = log(nextfloat(zero(T)))
        assessment = _risk_assessment_above(input, overflow_threshold)
        _push_expression_risk!(
            risks,
            source,
            path,
            value,
            :exponential_overflow_risk,
            assessment,
            "$(head) may overflow for the declared argument range.",
            "Overflow produces non-finite values and derivatives before an NLP solver can form a reliable step.",
            [
                "operator" => head,
                "argument_interval" => "[$(input.lower), $(input.upper)]",
                "numeric_type" => T,
                "overflow_threshold" => overflow_threshold,
            ],
            [
                "Tighten the argument range if mathematically valid.",
                "Use a stable composite primitive when the exponential is only an intermediate quantity.",
            ],
        )
        assessment = _risk_assessment_below(input, zero_threshold)
        _push_expression_risk!(
            risks,
            source,
            path,
            value,
            :exponential_underflow_risk,
            assessment,
            "$(head) may underflow to a numerically flat value for the declared argument range.",
            "A value or derivative rounded to zero can create artificial flat directions and misleading local scaling.",
            [
                "operator" => head,
                "argument_interval" => "[$(input.lower), $(input.upper)]",
                "numeric_type" => T,
                "zero_threshold" => zero_threshold,
            ],
            [
                "Rescale the argument or use a stable composite primitive.",
                "Probe derivatives at representative initial and solution points.",
            ],
        )
    elseif head == :exp2
        overflow_threshold = log2(floatmax(T))
        zero_threshold = log2(nextfloat(zero(T)))
        for (code, assessment, threshold, description) in (
            (
                :exponential_overflow_risk,
                _risk_assessment_above(input, overflow_threshold),
                overflow_threshold,
                "overflow",
            ),
            (
                :exponential_underflow_risk,
                _risk_assessment_below(input, zero_threshold),
                zero_threshold,
                "underflow",
            ),
        )
            _push_expression_risk!(
                risks,
                source,
                path,
                value,
                code,
                assessment,
                "exp2 may $description for the declared argument range.",
                "Non-finite or numerically flat exponential values can corrupt derivative and scaling evidence.",
                [
                    "operator" => head,
                    "argument_interval" =>
                        "[$(input.lower), $(input.upper)]",
                    "numeric_type" => T,
                    "threshold" => threshold,
                ],
                ["Rescale the argument or use a stable composite primitive."],
            )
        end
    elseif head in (:sinh, :cosh)
        overflow_threshold = log(floatmax(T)) + log(T(2))
        absolute_lower = _contains_zero(input) ?
                         zero(input.lower) :
                         min(abs(input.lower), abs(input.upper))
        assessment = _risk_assessment_above(
            IntervalEnclosure(
                absolute_lower,
                max(abs(input.lower), abs(input.upper)),
                input.valid,
                input.informative,
            ),
            overflow_threshold,
        )
        _push_expression_risk!(
            risks,
            source,
            path,
            value,
            :hyperbolic_overflow_risk,
            assessment,
            "$(head) may overflow for the declared argument range.",
            "Hyperbolic values and derivatives grow exponentially and can become non-finite.",
            [
                "operator" => head,
                "argument_interval" => "[$(input.lower), $(input.upper)]",
                "numeric_type" => T,
                "absolute_overflow_threshold" => overflow_threshold,
            ],
            ["Rescale the argument or reformulate the expression."],
        )
    end
    return
end

function _composition_fingerprint_risks!(
    risks,
    value::MOI.ScalarNonlinearFunction,
    source,
    path,
)
    head = value.head
    if head == :log && length(value.args) == 1
        argument = only(value.args)
        if _is_head(argument, :exp)
            _push_expression_risk!(
                risks,
                source,
                path,
                value,
                :avoidable_log_exp_composition,
                DomainPossibleViolation,
                "The expression computes log(exp(x)) instead of x.",
                "The intermediate exponential can overflow or underflow even though the composite mathematical result is well scaled.",
                ["pattern" => "log(exp(x))"],
                [
                    "Replace the composition with its argument when the real-valued semantics are intended.",
                ],
            )
        else
            other = _addition_other_than_one(argument)
            if !isnothing(other) && _is_head(other, :exp)
                _push_expression_risk!(
                    risks,
                    source,
                    path,
                    value,
                    :unstable_softplus_expression,
                    DomainPossibleViolation,
                    "The expression implements softplus as log(1 + exp(x)).",
                    "The exponential can overflow for large positive x, while adding one loses the exponential contribution for large negative x.",
                    ["pattern" => "log(1 + exp(x))"],
                    [
                        "Use a stable log1pexp/softplus implementation based on max(x, 0) + log1p(exp(-abs(x))).",
                    ],
                )
            elseif !isnothing(other)
                _push_expression_risk!(
                    risks,
                    source,
                    path,
                    value,
                    :log_one_plus_cancellation_risk,
                    DomainPossibleViolation,
                    "The expression computes log(1 + x) explicitly.",
                    "For small x, forming 1 + x can lose significant digits before the logarithm is evaluated.",
                    ["pattern" => "log(1 + x)"],
                    ["Use log1p(x) to preserve accuracy near zero."],
                )
            end
        end
    elseif head == :log1p &&
           length(value.args) == 1 &&
           _is_head(only(value.args), :exp)
        _push_expression_risk!(
            risks,
            source,
            path,
            value,
            :unstable_softplus_expression,
            DomainPossibleViolation,
            "The expression implements softplus as log1p(exp(x)).",
            "log1p avoids cancellation near zero but the intermediate exponential can still overflow.",
            ["pattern" => "log1p(exp(x))"],
            [
                "Use a stable log1pexp/softplus implementation that does not form exp(x) for large positive x.",
            ],
        )
    elseif head == :- && length(value.args) == 2
        if _is_head(value.args[1], :exp) && _is_one(value.args[2])
            _push_expression_risk!(
                risks,
                source,
                path,
                value,
                :exp_minus_one_cancellation_risk,
                DomainPossibleViolation,
                "The expression computes exp(x) - 1 explicitly.",
                "Subtraction cancels leading digits for x close to zero.",
                ["pattern" => "exp(x) - 1"],
                ["Use expm1(x) to preserve accuracy near zero."],
            )
        end
    elseif head == :/ && length(value.args) == 2
        numerator, denominator = value.args
        other = _addition_other_than_one(denominator)
        if _is_one(numerator) &&
           !isnothing(other) &&
           _is_head(other, :exp) &&
           !isnothing(_negative_argument(only(other.args)))
            _push_expression_risk!(
                risks,
                source,
                path,
                value,
                :unstable_logistic_expression,
                DomainPossibleViolation,
                "The expression implements a logistic function as 1 / (1 + exp(-x)).",
                "The intermediate exponential can overflow for large negative x even though the logistic value is bounded.",
                ["pattern" => "1 / (1 + exp(-x))"],
                [
                    "Use a sign-aware stable logistic implementation that exponentiates the non-positive branch.",
                ],
            )
        end
    end
    return
end

function _scan_expression_numerics!(
    risks,
    value,
    source,
    path,
    variable_intervals,
    numeric_type,
)
    !(value isa MOI.ScalarNonlinearFunction) &&
        return _base_interval(value, variable_intervals)
    intervals = IntervalEnclosure[]
    for (argument_index, argument) in enumerate(value.args)
        push!(
            intervals,
            _scan_expression_numerics!(
                risks,
                argument,
                source,
                vcat(path, argument_index),
                variable_intervals,
                numeric_type,
            ),
        )
    end
    _primitive_range_risks!(
        risks,
        value,
        source,
        path,
        intervals,
        numeric_type,
    )
    _composition_fingerprint_risks!(risks, value, source, path)
    return operator_interval(Val(value.head), intervals, value.args)
end

function _expression_numerical_risks(
    model::ModelSnapshot,
    variable_intervals;
    numeric_type::Type{<:AbstractFloat},
)
    risks = ExpressionNumericalRisk[]
    if !isnothing(model.objective)
        objective = model.objective
        _scan_expression_numerics!(
            risks,
            objective.function_value,
            _objective_ref(objective.function_value),
            Int[],
            variable_intervals,
            numeric_type,
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
            _scan_expression_numerics!(
                risks,
                function_value,
                _constraint_ref(
                    constraint;
                    row = length(rows) == 1 ? nothing : row,
                ),
                Int[],
                variable_intervals,
                numeric_type,
            )
        end
    end
    return risks
end

function expression_numerical_risks(
    model::ModelSnapshot;
    numeric_type::Type{<:AbstractFloat} = Float64,
)
    return _expression_numerical_risks(
        model,
        _domain_variable_intervals(model);
        numeric_type = numeric_type,
    )
end

function expression_numerical_risks(
    model::MOI.ModelLike;
    numeric_type::Type{<:AbstractFloat} = Float64,
)
    return expression_numerical_risks(
        snapshot(model);
        numeric_type = numeric_type,
    )
end

function _expression_risk_finding(
    risk::ExpressionNumericalRisk,
    variable_records;
    point::Union{Nothing,EvaluationPoint} = nothing,
)
    at_point = !isnothing(point)
    affected = EntityRef[risk.path.source]
    for variable in risk.variables
        haskey(variable_records, variable) || continue
        push!(affected, _variable_ref(variable_records[variable]))
    end
    evidence = Evidence[
        Evidence(
            "Expression numerical fingerprint";
            details = vcat(
                [
                    "path" => _path_string(risk.path),
                    "assessment" => risk.assessment,
                ],
                risk.evidence,
            ),
        ),
    ]
    isnothing(point) || pushfirst!(evidence, _point_evidence(point))
    return Finding(
        at_point ? Symbol("operating_point_", risk.code) : risk.code;
        severity = risk.assessment == DomainProvenViolation &&
                   risk.code != :exponential_underflow_risk ?
                   SeverityError :
                   SeverityWarning,
        domain = NumericalIssue,
        basis = risk.assessment == DomainProvenViolation ?
                LocalInference :
                HeuristicInterpretation,
        confidence = risk.assessment == DomainProvenViolation ?
                     ConfidenceHigh :
                     ConfidenceMedium,
        observation = risk.observation,
        why_it_matters = risk.why_it_matters,
        evidence = evidence,
        suggested_actions = risk.suggested_actions,
        affected = affected,
    )
end

function analyze_expressions(
    model::ModelSnapshot;
    point::Union{Nothing,EvaluationPoint} = nothing,
    numeric_type::Union{Nothing,Type{<:AbstractFloat}} = nothing,
)
    selected_numeric_type = if !isnothing(numeric_type)
        numeric_type
    elseif !isnothing(point)
        eltype(point.values)
    else
        Float64
    end
    intervals = isnothing(point) ?
                _domain_variable_intervals(model) :
                Dict(
        variable => IntervalEnclosure(value, value, true, true) for
        (variable, value) in zip(point.variables, point.values)
    )
    risks = _expression_numerical_risks(
        model,
        intervals;
        numeric_type = selected_numeric_type,
    )
    if !isnothing(point)
        # Composition fingerprints do not depend on the point and are already
        # part of static analysis. Exact-point analysis focuses on primitive
        # range failures.
        risks = filter(
            risk ->
                risk.code in (
                    :exponential_overflow_risk,
                    :exponential_underflow_risk,
                    :hyperbolic_overflow_risk,
                ) && risk.assessment == DomainProvenViolation,
            risks,
        )
    end
    report = DiagnosticReport()
    records = Dict(record.index => record for record in model.variables)
    for risk in risks
        push!(
            report,
            _expression_risk_finding(risk, records; point = point),
        )
    end
    report.metadata[:expression_numerical_risk_count] =
        string(length(risks))
    report.metadata[:expression_numeric_type] =
        string(selected_numeric_type)
    return report
end

function analyze_expressions(
    model::MOI.ModelLike;
    point::Union{Nothing,EvaluationPoint} = nothing,
    numeric_type::Union{Nothing,Type{<:AbstractFloat}} = nothing,
)
    return analyze_expressions(
        snapshot(model);
        point = point,
        numeric_type = numeric_type,
    )
end
