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

"""One exact-real-semantics rewrite suggested by an expression fingerprint."""
struct StableReformulationCandidate
    source::EntityRef
    path::ExpressionNodePath
    fingerprint::Symbol
    replacement::Symbol
    replacement_description::String
    requires_registered_operator::Bool
    variables::Vector{MOI.VariableIndex}
end

"""Inspectable, non-mutating stable-reformulation suggestions."""
struct StableReformulationPlan
    candidates::Vector{StableReformulationCandidate}
    numeric_type::DataType
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

function _subtraction_from_one(value)
    _is_head(value, :-) || return nothing
    length(value.args) == 2 || return nothing
    _is_one(value.args[1]) && return value.args[2]
    return nothing
end

function _addition_terms(value)
    _is_head(value, :+) || return Any[value]
    terms = Any[]
    for argument in value.args
        append!(terms, _addition_terms(argument))
    end
    return terms
end

function _logsumexp_terms(value)
    terms = _addition_terms(value)
    length(terms) >= 2 && all(term -> _is_head(term, :exp), terms) || return nothing
    return terms
end

function _logdiffexp_terms(value)
    _is_head(value, :-) || return nothing
    length(value.args) == 2 || return nothing
    all(term -> _is_head(term, :exp), value.args) || return nothing
    return value.args
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

function _strict_log_margin_derivative_estimates(
    margin::Real;
    logdiffexp::Bool = false,
    numeric_type::Type{T} = Float64,
) where {T<:AbstractFloat}
    # For m > 0, `-expm1(-m)` computes 1 - exp(-m) without cancellation.
    # The result is intentionally allowed to be Inf: that is meaningful
    # floating-point evidence for a derivative that cannot be represented.
    typed_margin = T(margin)
    denominator = -expm1(-typed_margin)
    exponential = exp(-typed_margin)
    first = logdiffexp ? inv(denominator) : exponential / denominator
    second = exponential / denominator^2
    return first, second
end

function _strict_positive_margin_derivative_estimates(
    margin::Real,
    ::Type{T};
    multiplier::Real = 1.0,
) where {T<:AbstractFloat}
    typed_margin = T(margin)
    typed_multiplier = T(multiplier)
    return typed_multiplier / typed_margin, typed_multiplier / typed_margin^2
end

function _strict_nonzero_margin(interval::IntervalEnclosure)
    !interval.valid && return nothing
    interval.lower > 0.0 && return interval.lower
    interval.upper < 0.0 && return -interval.upper
    return nothing
end

function _reciprocal_derivative_estimates(
    margin::Real,
    ::Type{T},
) where {T<:AbstractFloat}
    reciprocal = inv(T(margin))
    return reciprocal^2, 2 * reciprocal^3
end

function _inverse_reciprocal_hyperbolic_derivative_estimates(
    margin::Real,
    ::Type{T},
) where {T<:AbstractFloat}
    reciprocal = inv(T(margin))
    # asech(x) and acsch(x) have leading derivative magnitude 1 / |x|
    # and second-derivative magnitude 1 / |x|^2 near zero.
    return reciprocal, reciprocal^2
end

function _sqrt_derivative_estimates(
    margin::Real,
    ::Type{T},
) where {T<:AbstractFloat}
    root = sqrt(T(margin))
    return inv(2 * root), inv(4 * root^3)
end

function _power_derivative_estimates(
    margin::Real,
    exponent::Real,
    ::Type{T},
) where {T<:AbstractFloat}
    typed_margin = T(margin)
    typed_exponent = T(exponent)
    first = abs(typed_exponent) * typed_margin^(typed_exponent - one(T))
    second = abs(typed_exponent * (typed_exponent - one(T))) *
             typed_margin^(typed_exponent - T(2))
    return first, second
end

function _periodic_derivative_estimates(
    operator::Symbol,
    argument::Real,
    ::Type{T},
) where {T<:AbstractFloat}
    degree = operator in (:tand, :secd, :cscd, :cotd)
    sine, cosine = degree ?
                   (sind(T(argument)), cosd(T(argument))) :
                   sincos(T(argument))
    first_scale = degree ? T(pi / 180) : one(T)
    second_scale = first_scale^2
    if operator in (:tan, :tand)
        secant = inv(cosine)
        return abs(first_scale * secant^2),
               abs(second_scale * 2 * secant^2 * (sine / cosine)), abs(cosine)
    elseif operator in (:sec, :secd)
        secant = inv(cosine)
        tangent = sine / cosine
        return abs(first_scale * secant * tangent),
               abs(second_scale * secant * (tangent^2 + secant^2)), abs(cosine)
    elseif operator in (:csc, :cscd)
        cosecant = inv(sine)
        cotangent = cosine / sine
        return abs(first_scale * cosecant * cotangent),
               abs(second_scale * cosecant * (cotangent^2 + cosecant^2)), abs(sine)
    elseif operator in (:cot, :cotd)
        cosecant = inv(sine)
        cotangent = cosine / sine
        return abs(first_scale * cosecant^2),
               abs(second_scale * 2 * cosecant^2 * cotangent), abs(sine)
    end
    throw(ArgumentError("unsupported periodic derivative operator $operator"))
end

function _inverse_boundary_derivative_estimates(
    operator::Symbol,
    argument::Real,
    ::Type{T},
) where {T<:AbstractFloat}
    value = T(argument)
    if operator in (:asin, :acos, :asind, :acosd)
        denominator_squared = one(T) - value^2
        degree_scale = operator in (:asind, :acosd) ? T(180 / pi) : one(T)
        return degree_scale * inv(sqrt(denominator_squared)),
               degree_scale * abs(value) / denominator_squared^(T(3) / T(2))
    elseif operator in (:atanh, :acoth)
        denominator = operator == :atanh ? one(T) - value^2 : value^2 - one(T)
        return inv(denominator), 2 * abs(value) / denominator^2
    elseif operator == :acosh
        denominator = value^2 - one(T)
        return inv(sqrt(denominator)), value / denominator^(T(3) / T(2))
    elseif operator in (:asec, :acsc, :asecd, :acscd)
        magnitude = abs(value)
        denominator = magnitude^2 - one(T)
        degree_scale = operator in (:asecd, :acscd) ? T(180 / pi) : one(T)
        first = degree_scale / (magnitude * sqrt(denominator))
        second = degree_scale * (2 * magnitude^2 - one(T)) /
                 (magnitude^2 * denominator^(T(3) / T(2)))
        return abs(first), abs(second)
    end
    throw(ArgumentError("unsupported inverse-boundary derivative operator $operator"))
end

function _amplification_assessment(
    exact_margin::Bool,
    derivatives::Real...,
)
    return exact_margin && any(value -> !isfinite(value), derivatives) ?
           DomainProvenViolation : DomainPossibleViolation
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
    strict_domain_proximity_threshold,
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
    elseif head == :logistic
        # In the positive tail, 1 + exp(-x) can round to exactly one long
        # before exp(-x) underflows. The resulting floating-point value is 1,
        # although real logistic(x) remains strictly below one.
        one_saturation_threshold = -log(eps(T) / T(2))
        zero_saturation_threshold = log(nextfloat(zero(T)))
        value_assessment = if input.valid &&
                              (input.lower > one_saturation_threshold ||
                               input.upper < zero_saturation_threshold)
            DomainProvenViolation
        elseif input.valid &&
               (input.upper > one_saturation_threshold ||
                input.lower < zero_saturation_threshold)
            DomainPossibleViolation
        else
            DomainSafe
        end
        _push_expression_risk!(
            risks,
            source,
            path,
            value,
            :logistic_value_saturation_risk,
            value_assessment,
            "logistic may round to an endpoint value for the declared argument range.",
            "The real logistic range is the open interval (0, 1), but floating-point saturation can create an artificial zero or one and falsely satisfy an endpoint row.",
            [
                "operator" => head,
                "argument_interval" => "[$(input.lower), $(input.upper)]",
                "numeric_type" => T,
                "one_saturation_threshold" => one_saturation_threshold,
                "zero_saturation_threshold" => zero_saturation_threshold,
            ],
            [
                "Avoid treating a rounded logistic endpoint as an exact real value.",
                "Rescale the argument or use an interior tolerance that reflects the intended mathematical semantics.",
            ],
        )
        # A sign-aware value implementation prevents overflow, but the true
        # derivative σ(x)(1-σ(x)) still has an exp(-abs(x)) leading factor.
        # Beyond this threshold it can round to zero even while σ(x) is finite.
        derivative_zero_threshold = -log(nextfloat(zero(T)))
        assessment = if input.valid &&
                        (input.lower > derivative_zero_threshold ||
                         input.upper < -derivative_zero_threshold)
            DomainProvenViolation
        elseif input.valid &&
               (input.upper > derivative_zero_threshold ||
                input.lower < -derivative_zero_threshold)
            DomainPossibleViolation
        else
            DomainSafe
        end
        _push_expression_risk!(
            risks,
            source,
            path,
            value,
            :logistic_derivative_underflow_risk,
            assessment,
            "logistic may have a derivative rounded to zero for the declared argument range.",
            "A bounded, finite logistic value can still become numerically flat, creating artificial zero Jacobian entries and misleading local rank or scaling evidence.",
            [
                "operator" => head,
                "argument_interval" => "[$(input.lower), $(input.upper)]",
                "numeric_type" => T,
                "absolute_derivative_underflow_threshold" => derivative_zero_threshold,
            ],
            [
                "Rescale or reparameterize the logistic argument when its saturated tail is not intentional.",
                "Inspect derivative magnitudes at initialization and solution points before interpreting zero sensitivities structurally.",
            ],
        )
    elseif head == :tanh
        # tanh(x) approaches ±1 exponentially. Floating-point arithmetic can
        # round it to an endpoint even though the real range remains open.
        endpoint_saturation_threshold =
            (log(T(4)) - log(eps(T))) / T(2)
        value_assessment = if input.valid &&
                              (input.lower > endpoint_saturation_threshold ||
                               input.upper < -endpoint_saturation_threshold)
            DomainProvenViolation
        elseif input.valid &&
               (input.upper > endpoint_saturation_threshold ||
                input.lower < -endpoint_saturation_threshold)
            DomainPossibleViolation
        else
            DomainSafe
        end
        _push_expression_risk!(
            risks,
            source,
            path,
            value,
            :tanh_value_saturation_risk,
            value_assessment,
            "tanh may round to an endpoint value for the declared argument range.",
            "The real tanh range is the open interval (-1, 1), but floating-point saturation can create an artificial ±1 and falsely satisfy an endpoint row.",
            [
                "operator" => head,
                "argument_interval" => "[$(input.lower), $(input.upper)]",
                "numeric_type" => T,
                "absolute_endpoint_saturation_threshold" => endpoint_saturation_threshold,
            ],
            [
                "Avoid treating a rounded tanh endpoint as an exact real value.",
                "Rescale the argument or use interior tolerance semantics that reflect the intended mathematical range.",
            ],
        )
        # tanh'(x) = sech(x)^2 ≈ 4exp(-2abs(x)) in either saturated tail.
        derivative_zero_threshold =
            (log(T(4)) - log(nextfloat(zero(T)))) / T(2)
        assessment = if input.valid &&
                        (input.lower > derivative_zero_threshold ||
                         input.upper < -derivative_zero_threshold)
            DomainProvenViolation
        elseif input.valid &&
               (input.upper > derivative_zero_threshold ||
                input.lower < -derivative_zero_threshold)
            DomainPossibleViolation
        else
            DomainSafe
        end
        _push_expression_risk!(
            risks,
            source,
            path,
            value,
            :tanh_derivative_underflow_risk,
            assessment,
            "tanh may have a derivative rounded to zero for the declared argument range.",
            "A bounded, finite tanh value can still become numerically flat, creating artificial zero Jacobian entries and misleading local rank or scaling evidence.",
            [
                "operator" => head,
                "argument_interval" => "[$(input.lower), $(input.upper)]",
                "numeric_type" => T,
                "absolute_derivative_underflow_threshold" => derivative_zero_threshold,
            ],
            [
                "Rescale or reparameterize the tanh argument when saturated tails are not intentional.",
                "Inspect derivative magnitudes at initialization and solution points before interpreting zero sensitivities structurally.",
            ],
        )
    elseif head == :logcosh
        # d²/dx² log(cosh(x)) = sech(x)^2 ≈ 4exp(-2abs(x)).
        curvature_zero_threshold =
            (log(T(4)) - log(nextfloat(zero(T)))) / T(2)
        assessment = if input.valid &&
                        (input.lower > curvature_zero_threshold ||
                         input.upper < -curvature_zero_threshold)
            DomainProvenViolation
        elseif input.valid &&
               (input.upper > curvature_zero_threshold ||
                input.lower < -curvature_zero_threshold)
            DomainPossibleViolation
        else
            DomainSafe
        end
        _push_expression_risk!(
            risks,
            source,
            path,
            value,
            :logcosh_curvature_underflow_risk,
            assessment,
            "logcosh may have a second derivative rounded to zero for the declared argument range.",
            "The stable value and first derivative remain finite in the tail, but a numerically flat Hessian can conceal curvature and distort second-order conditioning evidence.",
            [
                "operator" => head,
                "argument_interval" => "[$(input.lower), $(input.upper)]",
                "numeric_type" => T,
                "absolute_curvature_underflow_threshold" => curvature_zero_threshold,
            ],
            [
                "Rescale or reparameterize the logcosh argument when saturated tails are not intentional.",
                "Compare reduced-Hessian evidence across appropriately scaled nearby points before classifying a flat direction.",
            ],
        )
    elseif head == :sech
        # sech(x) ≈ 2exp(-abs(x)) in either tail. A stable evaluation delays
        # but cannot eliminate eventual underflow to an artificial zero.
        value_zero_threshold = log(T(2)) - log(nextfloat(zero(T)))
        assessment = if input.valid &&
                        (input.lower > value_zero_threshold ||
                         input.upper < -value_zero_threshold)
            DomainProvenViolation
        elseif input.valid &&
               (input.upper > value_zero_threshold ||
                input.lower < -value_zero_threshold)
            DomainPossibleViolation
        else
            DomainSafe
        end
        _push_expression_risk!(
            risks,
            source,
            path,
            value,
            :sech_value_underflow_risk,
            assessment,
            "sech may underflow to a floating-point zero for the declared argument range.",
            "The real sech function is strictly positive, so a rounded zero can create a false apparent feasible value, flat derivatives, or misleading exact-range behavior.",
            [
                "operator" => head,
                "argument_interval" => "[$(input.lower), $(input.upper)]",
                "numeric_type" => T,
                "absolute_underflow_threshold" => value_zero_threshold,
            ],
            [
                "Rescale or reparameterize the sech argument when its tail is not intentional.",
                "Avoid interpreting a floating-point zero as a real sech root; compare with exact range and derivative diagnostics.",
            ],
        )
    elseif head in (:softplus, :log1pexp, :log1exp)
        # The stable value formula avoids positive-tail overflow, while its
        # derivative is logistic(x) and hence has an exp(x) negative-tail
        # leading factor.
        value_zero_threshold = log(nextfloat(zero(T)))
        value_assessment = _risk_assessment_below(input, value_zero_threshold)
        _push_expression_risk!(
            risks,
            source,
            path,
            value,
            :softplus_value_underflow_risk,
            value_assessment,
            "$(head) may underflow to a floating-point zero for the declared argument range.",
            "The real softplus range is strictly positive, but a rounded zero can falsely satisfy a nonpositive row or conceal a small but nonzero contribution.",
            [
                "operator" => head,
                "argument_interval" => "[$(input.lower), $(input.upper)]",
                "numeric_type" => T,
                "value_underflow_threshold" => value_zero_threshold,
            ],
            [
                "Avoid treating a rounded softplus zero as an exact real value.",
                "Rescale the argument or use tolerance semantics that preserve the intended positive-output condition.",
            ],
        )
        derivative_zero_threshold = log(nextfloat(zero(T)))
        assessment = _risk_assessment_below(input, derivative_zero_threshold)
        _push_expression_risk!(
            risks,
            source,
            path,
            value,
            :softplus_derivative_underflow_risk,
            assessment,
            "$(head) may have a derivative rounded to zero for the declared argument range.",
            "A stable softplus value can remain finite while its negative-tail derivative underflows, creating artificial flat Jacobian entries and misleading local rank or scaling evidence.",
            [
                "operator" => head,
                "argument_interval" => "[$(input.lower), $(input.upper)]",
                "numeric_type" => T,
                "derivative_underflow_threshold" => derivative_zero_threshold,
            ],
            [
                "Rescale or reparameterize the softplus argument when saturated negative tails are not intentional.",
                "Inspect derivative magnitudes at initialization and solution points before interpreting zero sensitivities structurally.",
            ],
        )
    elseif head in (:sin, :cos, :tan, :sec, :csc, :cot,
                    :sind, :cosd, :tand, :secd, :cscd, :cotd) &&
           input.valid && isfinite(input.lower) && isfinite(input.upper)
        # Match the conservative periodic interval guard: beyond this scale
        # the floating-point coordinate can lose enough phase resolution that
        # an enclosure or derivative should not imply precise periodic phase.
        phase_resolution_threshold = T(1.0e12)
        absolute_magnitude = max(abs(input.lower), abs(input.upper))
        assessment = absolute_magnitude > phase_resolution_threshold ?
                     (input.lower == input.upper ?
                      DomainProvenViolation : DomainPossibleViolation) :
                     DomainSafe
        _push_expression_risk!(
            risks,
            source,
            path,
            value,
            :periodic_argument_reduction_risk,
            assessment,
            "$(head) is evaluated at a very large finite periodic argument.",
            "Floating-point phase reduction can lose meaningful angular resolution at this scale, so function and derivative values may be dominated by representation rather than the intended physical phase.",
            [
                "operator" => head,
                "argument_interval" => "[$(input.lower), $(input.upper)]",
                "absolute_argument_magnitude" => absolute_magnitude,
                "phase_resolution_threshold" => phase_resolution_threshold,
                "numeric_type" => T,
            ],
            [
                "Reduce periodic arguments using a well-scaled reference angle when the model semantics allow it.",
                "Inspect units and phase conventions before interpreting derivative or residual changes at this magnitude.",
            ],
        )
    elseif head == :atan && length(intervals) == 2 &&
           all(interval -> interval.valid && interval.lower == interval.upper &&
                           isfinite(interval.lower), intervals)
        y, x = intervals
        radius = hypot(T(y.lower), T(x.lower))
        proximity_threshold = T(strict_domain_proximity_threshold)
        if !iszero(radius) && radius <= proximity_threshold
            first_derivative = inv(radius)
            second_derivative = inv(radius^2)
            _push_expression_risk!(
                risks,
                source,
                path,
                value,
                :atan2_derivative_amplification,
                _amplification_assessment(true, first_derivative, second_derivative),
                "atan(y, x) is evaluated very close to its joint derivative singularity at (0, 0).",
                "The angle remains defined away from the exact origin, but its gradient and Hessian scale as inverse powers of the coordinate radius and can dominate local scaling.",
                [
                    "operator" => head,
                    "y_argument" => y.lower,
                    "x_argument" => x.lower,
                    "coordinate_radius" => radius,
                    "estimated_first_derivative_magnitude" => first_derivative,
                    "estimated_second_derivative_magnitude" => second_derivative,
                    "proximity_threshold" => proximity_threshold,
                    "numeric_type" => T,
                ],
                [
                    "Use coordinates with a meaningful nonzero magnitude margin when the angle is differentiated.",
                    "Inspect initialization and active-set derivative scaling before attributing rank loss to a physical gauge.",
                ],
            )
        end
    elseif head in (:atan, :atand) && length(intervals) == 1 && input.valid &&
           isfinite(input.lower) && isfinite(input.upper)
        endpoint_saturation_threshold = if head == :atan
            inv(eps(T))
        else
            T(180) / (T(pi) * (eps(T(90)) / T(2)))
        end
        absolute_magnitude = max(abs(input.lower), abs(input.upper))
        assessment = absolute_magnitude > endpoint_saturation_threshold ?
                     (input.lower == input.upper ?
                      DomainProvenViolation : DomainPossibleViolation) :
                     DomainSafe
        endpoint_label = head == :atan ? "±π/2" : "±90°"
        _push_expression_risk!(
            risks,
            source,
            path,
            value,
            :arctangent_endpoint_saturation_risk,
            assessment,
            "$(head) may round to its $endpoint_label endpoint for the declared argument range.",
            "The real one-argument arctangent range is open at its limiting angles, but a very large finite ratio can round to an endpoint and falsely satisfy an endpoint row.",
            [
                "operator" => head,
                "argument_interval" => "[$(input.lower), $(input.upper)]",
                "absolute_argument_magnitude" => absolute_magnitude,
                "endpoint_saturation_threshold" => endpoint_saturation_threshold,
                "endpoint" => endpoint_label,
                "numeric_type" => T,
            ],
            [
                "Avoid treating a rounded limiting angle as an exact real arctangent endpoint.",
                "Use a quadrant-aware two-argument atan(y, x) formulation when the angle arises from coordinates.",
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
    elseif head == :sqrt
        proximity_threshold = strict_domain_proximity_threshold
        if input.valid && input.lower > 0.0
            strict_margin = input.lower
            if strict_margin <= proximity_threshold
                first_derivative, second_derivative =
                    _sqrt_derivative_estimates(strict_margin, T)
                _push_expression_risk!(
                    risks,
                    source,
                    path,
                    value,
                    :strict_domain_derivative_amplification,
                    _amplification_assessment(
                        input.lower == input.upper,
                        first_derivative, second_derivative,
                    ),
                    "sqrt is evaluated very close to its derivative boundary at zero.",
                    "The value remains defined, but the first and second derivatives grow as inverse powers of sqrt(x) and can dominate local scaling.",
                    [
                        "operator" => head,
                        "argument_interval" => "[$(input.lower), $(input.upper)]",
                        "strict_margin" => strict_margin,
                        "estimated_first_derivative_magnitude" => first_derivative,
                        "estimated_second_derivative_magnitude" => second_derivative,
                        "numeric_type" => T,
                        "proximity_threshold" => proximity_threshold,
                    ],
                    [
                        "Choose an initialization farther from zero when the model semantics allow it.",
                        "Inspect derivative-domain and Jacobian scaling findings at the same point.",
                    ],
                )
            end
        end
    elseif head == :inv || (head == :/ && length(intervals) == 2)
        denominator = head == :inv ? input : intervals[2]
        strict_margin = _strict_nonzero_margin(denominator)
        proximity_threshold = strict_domain_proximity_threshold
        if !isnothing(strict_margin) && strict_margin <= proximity_threshold
            first_derivative, second_derivative =
                _reciprocal_derivative_estimates(strict_margin, T)
            _push_expression_risk!(
                risks,
                source,
                path,
                value,
                :strict_domain_derivative_amplification,
                _amplification_assessment(
                    denominator.lower == denominator.upper,
                    first_derivative, second_derivative,
                ),
                "$(head == :inv ? "inv" : "division") is evaluated very close to a nonzero denominator boundary.",
                "The value remains defined, but the reciprocal derivative factor grows as inverse powers of the denominator and can dominate local scaling.",
                [
                    "operator" => head,
                    "denominator_interval" => "[$(denominator.lower), $(denominator.upper)]",
                    "strict_margin" => strict_margin,
                    "estimated_reciprocal_first_derivative_magnitude" => first_derivative,
                    "estimated_reciprocal_second_derivative_magnitude" => second_derivative,
                    "numeric_type" => T,
                    "proximity_threshold" => proximity_threshold,
                ],
                [
                    "Choose an initialization with a larger nonzero denominator margin when the model semantics allow it.",
                    "Inspect derivative-domain and Jacobian scaling findings at the same point.",
                ],
            )
        end
    elseif head in (:csch, :coth)
        strict_margin = _strict_nonzero_margin(input)
        proximity_threshold = strict_domain_proximity_threshold
        if !isnothing(strict_margin) && strict_margin <= proximity_threshold
            # Both primitives have the reciprocal leading term 1/x near zero.
            # These estimates intentionally describe the singular scaling, not
            # an exact derivative formula away from zero.
            first_derivative, second_derivative =
                _reciprocal_derivative_estimates(strict_margin, T)
            _push_expression_risk!(
                risks,
                source,
                path,
                value,
                :strict_domain_derivative_amplification,
                _amplification_assessment(
                    input.lower == input.upper,
                    first_derivative,
                    second_derivative,
                ),
                "$(head) is evaluated very close to its zero singularity.",
                "The value remains defined, but csch and coth have reciprocal leading behavior near zero, so their derivatives can dominate local scaling.",
                [
                    "operator" => head,
                    "argument_interval" => "[$(input.lower), $(input.upper)]",
                    "strict_margin" => strict_margin,
                    "estimated_first_derivative_magnitude" => first_derivative,
                    "estimated_second_derivative_magnitude" => second_derivative,
                    "numeric_type" => T,
                    "proximity_threshold" => proximity_threshold,
                ],
                [
                    "Choose an initialization farther from zero when the model semantics allow it.",
                    "Inspect derivative-domain and Jacobian scaling findings at the same point.",
                ],
            )
        end
    elseif head in (:asech, :acsch)
        strict_margin = head == :asech ?
                        (input.valid && input.lower > 0.0 ? input.lower : nothing) :
                        _strict_nonzero_margin(input)
        proximity_threshold = strict_domain_proximity_threshold
        if !isnothing(strict_margin) && strict_margin <= proximity_threshold
            first_derivative, second_derivative =
                _inverse_reciprocal_hyperbolic_derivative_estimates(
                    strict_margin, T,
                )
            _push_expression_risk!(
                risks,
                source,
                path,
                value,
                :strict_domain_derivative_amplification,
                _amplification_assessment(
                    input.lower == input.upper,
                    first_derivative,
                    second_derivative,
                ),
                "$(head) is evaluated very close to its zero boundary.",
                "The value remains defined, but inverse reciprocal-hyperbolic derivatives have inverse-power leading behavior near zero and can dominate local scaling.",
                [
                    "operator" => head,
                    "argument_interval" => "[$(input.lower), $(input.upper)]",
                    "strict_margin" => strict_margin,
                    "estimated_first_derivative_magnitude" => first_derivative,
                    "estimated_second_derivative_magnitude" => second_derivative,
                    "numeric_type" => T,
                    "proximity_threshold" => proximity_threshold,
                ],
                [
                    "Choose an initialization farther from zero when the model semantics allow it.",
                    "Inspect derivative-domain and Jacobian scaling findings at the same point.",
                ],
            )
        end
    elseif head in (:asin, :acos, :asind, :acosd, :atanh, :acoth, :acosh,
                    :asec, :acsc, :asecd, :acscd) && input.valid &&
           input.lower == input.upper && isfinite(input.lower)
        argument = input.lower
        strict_margin = if head in (:asin, :acos, :asind, :acosd, :atanh)
            abs(argument) < 1.0 ? 1.0 - abs(argument) : nothing
        elseif head == :acoth
            abs(argument) > 1.0 ? abs(argument) - 1.0 : nothing
        elseif head in (:asec, :acsc, :asecd, :acscd)
            abs(argument) > 1.0 ? abs(argument) - 1.0 : nothing
        else
            argument > 1.0 ? argument - 1.0 : nothing
        end
        proximity_threshold = strict_domain_proximity_threshold
        if !isnothing(strict_margin) && strict_margin <= proximity_threshold
            first_derivative, second_derivative =
                _inverse_boundary_derivative_estimates(head, argument, T)
            boundary = head == :acosh ? "1" : "±1"
            _push_expression_risk!(
                risks,
                source,
                path,
                value,
                :strict_domain_derivative_amplification,
                _amplification_assessment(
                    input.lower == input.upper,
                    first_derivative, second_derivative,
                ),
                "$(head) is evaluated very close to its finite derivative boundary.",
                "The value remains defined, but the first and second derivatives grow rapidly near the $boundary boundary and can dominate local scaling.",
                [
                    "operator" => head,
                    "argument" => argument,
                    "strict_margin" => strict_margin,
                    "boundary" => boundary,
                    "estimated_first_derivative_magnitude" => first_derivative,
                    "estimated_second_derivative_magnitude" => second_derivative,
                    "numeric_type" => T,
                    "proximity_threshold" => proximity_threshold,
                ],
                [
                    "Choose an initialization farther from the finite derivative boundary when the model semantics allow it.",
                    "Inspect derivative-domain and Jacobian scaling findings at the same point.",
                ],
            )
        end
    elseif head in (:tan, :sec, :csc, :cot, :tand, :secd, :cscd, :cotd) && input.valid &&
           input.lower == input.upper && isfinite(input.lower)
        proximity_threshold = strict_domain_proximity_threshold
        first_derivative, second_derivative, denominator_magnitude =
            _periodic_derivative_estimates(head, input.lower, T)
        if denominator_magnitude <= proximity_threshold
            denominator_name = head in (:tan, :sec, :tand, :secd) ?
                               (head in (:tand, :secd) ? "cosd(argument)" : "cos(argument)") :
                               (head in (:cscd, :cotd) ? "sind(argument)" : "sin(argument)")
            _push_expression_risk!(
                risks,
                source,
                path,
                value,
                :strict_domain_derivative_amplification,
                _amplification_assessment(
                    true, first_derivative, second_derivative,
                ),
                "$(head) is evaluated close to a periodic singularity.",
                "The value may still be finite at the floating-point argument, but reciprocal trigonometric derivative factors can dominate local scaling near a zero of $denominator_name.",
                [
                    "operator" => head,
                    "argument" => input.lower,
                    "denominator" => denominator_name,
                    "denominator_magnitude" => denominator_magnitude,
                    "estimated_first_derivative_magnitude" => first_derivative,
                    "estimated_second_derivative_magnitude" => second_derivative,
                    "numeric_type" => T,
                    "proximity_threshold" => proximity_threshold,
                ],
                [
                    "Choose an initialization away from the periodic singularity when the model semantics allow it.",
                    "Inspect derivative-domain and Jacobian scaling findings at the same point.",
                ],
            )
        end
    elseif head == :^ && length(intervals) == 2 && value.args[2] isa Real
        exponent = Float64(value.args[2])
        proximity_threshold = strict_domain_proximity_threshold
        integer_exponent = isinteger(value.args[2])
        strict_margin = if integer_exponent && exponent < 0.0
            _strict_nonzero_margin(input)
        elseif !integer_exponent && input.valid && input.lower > 0.0 && exponent < 2.0
            input.lower
        else
            nothing
        end
        if !isnothing(strict_margin) && strict_margin <= proximity_threshold
            first_derivative, second_derivative =
                _power_derivative_estimates(strict_margin, exponent, T)
            base_requirement = integer_exponent ? "nonzero base" : "positive base"
            _push_expression_risk!(
                risks,
                source,
                path,
                value,
                :strict_domain_derivative_amplification,
                _amplification_assessment(
                    input.lower == input.upper,
                    first_derivative, second_derivative,
                ),
                "A power is evaluated close to its $base_requirement boundary.",
                "Depending on the exponent, its first derivative, second derivative, or both grow as inverse powers of the base and can dominate local scaling.",
                [
                    "operator" => head,
                    "base_interval" => "[$(input.lower), $(input.upper)]",
                    "exponent" => exponent,
                    "base_requirement" => base_requirement,
                    "strict_margin" => strict_margin,
                    "estimated_first_derivative_magnitude" => first_derivative,
                    "estimated_second_derivative_magnitude" => second_derivative,
                    "numeric_type" => T,
                    "proximity_threshold" => proximity_threshold,
                ],
                [
                    "Choose an initialization with a larger positive-base margin when the model semantics allow it.",
                    "Inspect derivative-domain and reduced-Hessian evidence at the same point.",
                ],
            )
        end
    elseif head in (:log, :log2, :log10)
        proximity_threshold = strict_domain_proximity_threshold
        if input.valid && input.lower > 0.0
            strict_margin = input.lower
            if strict_margin <= proximity_threshold
                multiplier = head == :log ? 1.0 : inv(log(head == :log2 ? 2.0 : 10.0))
                first_derivative, second_derivative =
                    _strict_positive_margin_derivative_estimates(
                        strict_margin, T; multiplier = multiplier,
                    )
                _push_expression_risk!(
                    risks,
                    source,
                    path,
                    value,
                    :strict_domain_derivative_amplification,
                    _amplification_assessment(
                        input.lower == input.upper,
                        first_derivative, second_derivative,
                    ),
                    "$(head) is evaluated very close to its strict domain boundary.",
                    "The value remains defined, but its first and second derivatives grow as reciprocal powers of the positive argument and can dominate local scaling.",
                    [
                        "operator" => head,
                        "argument_interval" => "[$(input.lower), $(input.upper)]",
                        "strict_margin" => strict_margin,
                        "estimated_first_derivative_magnitude" => first_derivative,
                        "estimated_second_derivative_magnitude" => second_derivative,
                        "numeric_type" => T,
                        "proximity_threshold" => proximity_threshold,
                    ],
                    [
                        "Choose an initialization with a larger positive argument margin when the model semantics allow it.",
                        "Inspect Jacobian row and column scales at the same point.",
                    ],
                )
            end
        end
    elseif head == :log1p
        proximity_threshold = strict_domain_proximity_threshold
        if input.valid && input.lower > -1.0
            strict_margin = 1.0 + input.lower
            if strict_margin <= proximity_threshold
                first_derivative, second_derivative =
                    _strict_positive_margin_derivative_estimates(strict_margin, T)
                _push_expression_risk!(
                    risks,
                    source,
                    path,
                    value,
                    :strict_domain_derivative_amplification,
                    _amplification_assessment(
                        input.lower == input.upper,
                        first_derivative, second_derivative,
                    ),
                    "log1p is evaluated very close to its strict domain boundary.",
                    "The value remains defined, but its first and second derivatives grow as reciprocal powers of 1 + x and can dominate local scaling.",
                    [
                        "operator" => head,
                        "argument_interval" => "[$(input.lower), $(input.upper)]",
                        "strict_margin" => strict_margin,
                        "estimated_first_derivative_magnitude" => first_derivative,
                        "estimated_second_derivative_magnitude" => second_derivative,
                        "numeric_type" => T,
                        "proximity_threshold" => proximity_threshold,
                    ],
                    [
                        "Choose an initialization with a larger 1 + x margin when the model semantics allow it.",
                        "Inspect Jacobian row and column scales at the same point.",
                    ],
                )
            end
        end
    elseif head == :log1mexp
        # The value domain is x < 0. Even strictly inside it, the derivative
        # grows like 1 / abs(x) as x approaches zero from below.
        proximity_threshold = strict_domain_proximity_threshold
        tail_zero_threshold = log(nextfloat(zero(T)))
        tail_assessment = _risk_assessment_below(input, tail_zero_threshold)
        _push_expression_risk!(
            risks,
            source,
            path,
            value,
            :log1mexp_value_saturation_risk,
            tail_assessment,
            "log1mexp may round to a floating-point zero for the declared argument range.",
            "The real log1mexp output is strictly negative, but an underflowed exp(x) can make the value and its derivative appear exactly zero and falsely satisfy an endpoint row.",
            [
                "operator" => head,
                "argument_interval" => "[$(input.lower), $(input.upper)]",
                "numeric_type" => T,
                "tail_underflow_threshold" => tail_zero_threshold,
            ],
            [
                "Avoid treating a rounded log1mexp zero as an exact real value.",
                "Rescale the argument or preserve small-tail contributions explicitly when they are semantically important.",
            ],
        )
        if input.valid && input.upper < 0.0
            strict_margin = -input.upper
            if strict_margin <= proximity_threshold
                first_derivative, second_derivative =
                    _strict_log_margin_derivative_estimates(
                        strict_margin; numeric_type = T,
                    )
                _push_expression_risk!(
                    risks,
                    source,
                    path,
                    value,
                    :strict_domain_derivative_amplification,
                    _amplification_assessment(
                        input.lower == input.upper,
                        first_derivative, second_derivative,
                    ),
                    "log1mexp is evaluated very close to its strict domain boundary.",
                    "The value remains defined, but its derivative grows rapidly as the argument approaches zero from below and can dominate local Jacobian scaling.",
                    [
                        "operator" => head,
                        "argument_interval" => "[$(input.lower), $(input.upper)]",
                        "strict_margin" => strict_margin,
                        "estimated_first_derivative_magnitude" => first_derivative,
                        "estimated_second_derivative_magnitude" => second_derivative,
                        "numeric_type" => T,
                        "proximity_threshold" => proximity_threshold,
                    ],
                    [
                        "Choose an initialization with a larger strict-domain margin when the model semantics allow it.",
                        "Inspect Jacobian row and column scales at the same point.",
                    ],
                )
            end
        end
    elseif head == :logdiffexp && length(intervals) == 2
        difference = _interval_add(intervals[1], _interval_scale(intervals[2], -1.0))
        tail_underflow_threshold = -log(nextfloat(zero(T)))
        tail_assessment = _risk_assessment_above(difference, tail_underflow_threshold)
        _push_expression_risk!(
            risks,
            source,
            path,
            value,
            :logdiffexp_subtrahend_derivative_underflow_risk,
            tail_assessment,
            "logdiffexp may lose sensitivity to its second argument for the declared a - b range.",
            "When a - b is extremely large, the derivative with respect to b behaves like exp(b - a) and can underflow to zero even though the real expression still depends on b.",
            [
                "operator" => head,
                "difference_interval" => "[$(difference.lower), $(difference.upper)]",
                "numeric_type" => T,
                "subtrahend_derivative_underflow_threshold" => tail_underflow_threshold,
            ],
            [
                "Rescale or reparameterize a - b when small sensitivity to b is not intentional.",
                "Inspect Jacobian columns before treating the b coordinate as structurally disconnected.",
            ],
        )
        proximity_threshold = strict_domain_proximity_threshold
        if difference.valid && difference.lower > 0.0
            strict_margin = difference.lower
            if strict_margin <= proximity_threshold
                first_derivative, second_derivative =
                    _strict_log_margin_derivative_estimates(
                        strict_margin; logdiffexp = true, numeric_type = T,
                    )
                _push_expression_risk!(
                    risks,
                    source,
                    path,
                    value,
                    :strict_domain_derivative_amplification,
                    _amplification_assessment(
                        difference.lower == difference.upper,
                        first_derivative, second_derivative,
                    ),
                    "logdiffexp is evaluated very close to its strict a > b domain boundary.",
                    "The value remains defined, but derivatives with respect to a and b grow rapidly as a - b approaches zero from above and can dominate local Jacobian scaling.",
                    [
                        "operator" => head,
                        "difference_interval" => "[$(difference.lower), $(difference.upper)]",
                        "strict_margin" => strict_margin,
                        "estimated_maximum_first_derivative_magnitude" => first_derivative,
                        "estimated_second_derivative_magnitude" => second_derivative,
                        "numeric_type" => T,
                        "proximity_threshold" => proximity_threshold,
                    ],
                    [
                        "Choose an initialization with a larger a - b margin when the model semantics allow it.",
                        "Inspect Jacobian row and column scales at the same point.",
                    ],
                )
            end
        end
    elseif head == :logsumexp && length(intervals) >= 2 &&
           all(interval -> interval.valid && isfinite(interval.lower) &&
                           isfinite(interval.upper), intervals)
        derivative_underflow_threshold = -log(nextfloat(zero(T)))
        for subordinate_index in eachindex(intervals)
            dominant_lower = maximum(
                intervals[index].lower for index in eachindex(intervals) if index != subordinate_index
            )
            guaranteed_gap = dominant_lower - intervals[subordinate_index].upper
            guaranteed_gap > derivative_underflow_threshold || continue
            _push_expression_risk!(
                risks,
                source,
                path,
                value,
                :logsumexp_term_derivative_underflow_risk,
                DomainProvenViolation,
                "logsumexp may lose sensitivity to argument $subordinate_index for the declared argument ranges.",
                "A max-shifted logsumexp value remains stable, but this term's softmax derivative is bounded above by exp(-gap) and can underflow to zero when another term is guaranteed to dominate it.",
                [
                    "operator" => head,
                    "subordinate_argument_index" => subordinate_index,
                    "subordinate_interval" => "[$(intervals[subordinate_index].lower), $(intervals[subordinate_index].upper)]",
                    "dominant_lower_bound" => dominant_lower,
                    "guaranteed_dominance_gap" => guaranteed_gap,
                    "derivative_underflow_threshold" => derivative_underflow_threshold,
                    "numeric_type" => T,
                ],
                [
                    "Rescale or center logsumexp arguments when the dominated term should retain numerical influence.",
                    "Inspect Jacobian columns before treating the dominated coordinate as structurally disconnected.",
                ],
            )
        end
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
        logsumexp_terms = _logsumexp_terms(argument)
        logdiffexp_terms = _logdiffexp_terms(argument)
        if _is_head(argument, :cosh)
            _push_expression_risk!(
                risks,
                source,
                path,
                value,
                :unstable_logcosh_expression,
                DomainPossibleViolation,
                "The expression computes log(cosh(x)) explicitly.",
                "The composite value is well defined for real x, but the intermediate cosh can overflow for large magnitude arguments.",
                ["pattern" => "log(cosh(x))"],
                [
                    "Use a stable logcosh implementation based on abs(x) + log1p(exp(-2abs(x))) - log(2).",
                ],
            )
        elseif !isnothing(logsumexp_terms)
            term_count = length(logsumexp_terms)
            _push_expression_risk!(
                risks,
                source,
                path,
                value,
                :unstable_logsumexp_expression,
                DomainPossibleViolation,
                "The expression computes a $(term_count)-term log-sum-exp explicitly.",
                "Either intermediate exponential can overflow even when the final log-sum-exp value is well scaled.",
                ["pattern" => "log(sum(exp(term)))", "term_count" => term_count],
                [
                    "Use a stable logsumexp implementation based on a max-shift before exponentiation.",
                ],
            )
        elseif !isnothing(logdiffexp_terms)
            _push_expression_risk!(
                risks,
                source,
                path,
                value,
                :unstable_logdiffexp_expression,
                DomainPossibleViolation,
                "The expression computes log(exp(a) - exp(b)) explicitly.",
                "The exponential difference can overflow or lose significant digits when a and b are close, even where the final log-difference is well scaled.",
                ["pattern" => "log(exp(a) - exp(b))", "real_domain" => "a > b"],
                [
                    "Use a stable branch-aware logdiffexp implementation, and retain the explicit real-domain requirement a > b.",
                ],
            )
        elseif _is_head(argument, :exp)
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
            difference = _subtraction_from_one(argument)
            other = _addition_other_than_one(argument)
            if !isnothing(difference) && _is_head(difference, :exp)
                _push_expression_risk!(
                    risks,
                    source,
                    path,
                    value,
                    :log_one_minus_exp_cancellation_risk,
                    DomainPossibleViolation,
                    "The expression computes log(1 - exp(x)) explicitly.",
                    "For x close to zero from below, subtracting exp(x) from one loses significant digits and rounding can push the logarithm argument outside its domain.",
                    ["pattern" => "log(1 - exp(x))"],
                    [
                        "Use a stable branch-aware log1mexp implementation, and retain the explicit real-domain requirement x < 0.",
                    ],
                )
            elseif !isnothing(difference) && !isempty(variable_support(difference).variables)
                _push_expression_risk!(
                    risks,
                    source,
                    path,
                    value,
                    :log_one_minus_cancellation_risk,
                    DomainPossibleViolation,
                    "The expression computes log(1 - x) explicitly.",
                    "For x close to zero, forming 1 - x can lose significant digits before the logarithm is evaluated.",
                    ["pattern" => "log(1 - x)"],
                    ["Use log1p(-x) to preserve accuracy near zero."],
                )
            elseif !isnothing(other) && _is_head(other, :exp)
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
    elseif head == :log1p && length(value.args) == 1
        argument = only(value.args)
        if _is_head(argument, :exp)
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
        elseif !isnothing(_negative_argument(argument)) &&
               _is_head(_negative_argument(argument), :exp)
            _push_expression_risk!(
                risks,
                source,
                path,
                value,
                :log_one_minus_exp_cancellation_risk,
                DomainPossibleViolation,
                "The expression computes log1p(-exp(x)) explicitly.",
                "The outer log1p avoids one subtraction, but exp(x) can still round to one near x = 0 from below and make the strict logarithm domain numerically fragile.",
                ["pattern" => "log1p(-exp(x))"],
                [
                    "Use a stable branch-aware log1mexp implementation, and retain the explicit real-domain requirement x < 0.",
                ],
            )
        end
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
        elseif _is_one(numerator) && !isnothing(other) && _is_head(other, :exp)
            _push_expression_risk!(
                risks,
                source,
                path,
                value,
                :unstable_complementary_logistic_expression,
                DomainPossibleViolation,
                "The expression computes a complementary logistic function as 1 / (1 + exp(x)).",
                "The intermediate exponential can overflow for large positive x even though the final value is bounded.",
                ["pattern" => "1 / (1 + exp(x))"],
                [
                    "Use a sign-aware stable logistic implementation as logistic(-x).",
                ],
            )
        elseif _is_head(numerator, :exp) && !isnothing(other) &&
               _fingerprint(numerator) == _fingerprint(other)
            _push_expression_risk!(
                risks,
                source,
                path,
                value,
                :unstable_logistic_expression,
                DomainPossibleViolation,
                "The expression implements a logistic function as exp(x) / (1 + exp(x)).",
                "The intermediate exponential can overflow for large positive x even though the logistic value is bounded.",
                ["pattern" => "exp(x) / (1 + exp(x))"],
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
    strict_domain_proximity_threshold,
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
                strict_domain_proximity_threshold,
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
        strict_domain_proximity_threshold,
    )
    _composition_fingerprint_risks!(risks, value, source, path)
    return operator_interval(Val(value.head), intervals, value.args)
end

function _expression_numerical_risks(
    model::ModelSnapshot,
    variable_intervals;
    numeric_type::Type{<:AbstractFloat},
    strict_domain_proximity_threshold::Real = sqrt(eps(numeric_type)),
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
            strict_domain_proximity_threshold,
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
                strict_domain_proximity_threshold,
            )
        end
    end
    return risks
end

function expression_numerical_risks(
    model::ModelSnapshot;
    numeric_type::Type{<:AbstractFloat} = Float64,
    strict_domain_proximity_threshold::Real = sqrt(eps(numeric_type)),
)
    return _expression_numerical_risks(
        model,
        _domain_variable_intervals(model);
        numeric_type = numeric_type,
        strict_domain_proximity_threshold = strict_domain_proximity_threshold,
    )
end

function _stable_reformulation_candidate(risk::ExpressionNumericalRisk)
    replacement = if risk.code == :avoidable_log_exp_composition
        (:identity, "replace log(exp(x)) with x under real-valued semantics", false)
    elseif risk.code == :log_one_plus_cancellation_risk
        (:log1p, "replace log(1 + x) with log1p(x)", false)
    elseif risk.code == :log_one_minus_cancellation_risk
        (:log1p, "replace log(1 - x) with log1p(-x)", false)
    elseif risk.code == :exp_minus_one_cancellation_risk
        (:expm1, "replace exp(x) - 1 with expm1(x)", false)
    elseif risk.code == :log_one_minus_exp_cancellation_risk
        (:log1mexp, "replace log(1 - exp(x)) with a registered branch-aware stable log1mexp operator", true)
    elseif risk.code == :unstable_logcosh_expression
        (:logcosh, "replace log(cosh(x)) with a registered overflow-safe logcosh operator", true)
    elseif risk.code == :unstable_logsumexp_expression
        (:logsumexp, "replace log(exp(a) + exp(b)) with a registered max-shifted logsumexp operator", true)
    elseif risk.code == :unstable_logdiffexp_expression
        (:logdiffexp, "replace log(exp(a) - exp(b)) with a registered branch-aware stable logdiffexp operator", true)
    elseif risk.code == :unstable_softplus_expression
        (:log1pexp, "replace the composite softplus with a registered stable log1pexp/softplus operator", true)
    elseif risk.code == :unstable_logistic_expression
        (:logistic, "replace the composite logistic expression with a registered sign-aware logistic operator", true)
    elseif risk.code == :unstable_complementary_logistic_expression
        (:logistic, "replace 1 / (1 + exp(x)) with a registered sign-aware logistic(-x) operator", true)
    else
        return nothing
    end
    return StableReformulationCandidate(
        risk.path.source,
        risk.path,
        risk.code,
        replacement[1],
        replacement[2],
        replacement[3],
        copy(risk.variables),
    )
end

"""
    stable_reformulation_plan(model; numeric_type = Float64)

Return exact-real-semantics rewrite candidates detected from compositional
numerical fingerprints. The plan never edits a model. Candidates that name
`log1pexp`, `log1mexp`, `logcosh`, `logsumexp`, and `logistic` require compatible registered nonlinear
operators.
"""
function stable_reformulation_plan(
    model::ModelSnapshot;
    numeric_type::Type{<:AbstractFloat} = Float64,
)
    candidates = StableReformulationCandidate[]
    for risk in expression_numerical_risks(model; numeric_type = numeric_type)
        candidate = _stable_reformulation_candidate(risk)
        isnothing(candidate) || push!(candidates, candidate)
    end
    return StableReformulationPlan(candidates, numeric_type)
end

function stable_reformulation_plan(
    model::MOI.ModelLike;
    numeric_type::Type{<:AbstractFloat} = Float64,
)
    return stable_reformulation_plan(snapshot(model); numeric_type = numeric_type)
end

"""Turn stable-reformulation candidates into evidence-first, non-mutating findings."""
function analyze_stable_reformulation_plan(plan::StableReformulationPlan)
    report = DiagnosticReport()
    report.metadata[:stage] = "stable_reformulation_plan"
    report.metadata[:stable_reformulation_count] = string(length(plan.candidates))
    report.metadata[:stable_reformulation_numeric_type] = string(plan.numeric_type)
    for candidate in plan.candidates
        registration = candidate.requires_registered_operator ?
                       "The replacement requires a registered nonlinear operator with the stated stable semantics." :
                       "The replacement is available as a standard scalar primitive or direct expression simplification."
        push!(report, Finding(:stable_reformulation_candidate;
            severity = SeverityInfo,
            domain = NumericalIssue,
            basis = MathematicalProof,
            confidence = ConfidenceCertain,
            observation = "The $(candidate.fingerprint) fingerprint has an exact-real-semantics rewrite to $(candidate.replacement).",
            why_it_matters = "$(candidate.replacement_description); $registration",
            evidence = [Evidence("Stable reformulation fingerprint"; details = ["path" => _path_string(candidate.path), "fingerprint" => candidate.fingerprint, "replacement" => candidate.replacement, "requires_registered_operator" => candidate.requires_registered_operator])],
            affected = [candidate.source],
            suggested_actions = candidate.requires_registered_operator ?
                                ["Register and test the stable operator with the chosen solver stack before replacing the expression."] :
                                ["Apply and independently test the algebraically equivalent rewrite; NLPDiagnostics does not modify the source model."],
        ))
    end
    return report
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
    interval_origins = nothing,
)
    at_point = !isnothing(point)
    nonfinite_derivative_estimate =
        risk.code == :strict_domain_derivative_amplification &&
        risk.assessment == DomainProvenViolation
    affected = EntityRef[risk.path.source]
    for variable in risk.variables
        haskey(variable_records, variable) || continue
        push!(affected, _variable_ref(variable_records[variable]))
    end
    support_origins = isnothing(interval_origins) ? "" : join(
        [
            "v$(variable.value)=$(_domain_interval_origin_summary(interval_origins, variable))" for
            variable in sort!(copy(risk.variables); by = variable -> variable.value)
        ],
        ";",
    )
    evidence = Evidence[
        Evidence(
            "Expression numerical fingerprint";
            details = vcat(
                [
                    "path" => _path_string(risk.path),
                    "assessment" => risk.assessment,
                    "support_interval_origins" => support_origins,
                ],
                risk.evidence,
            ),
        ),
    ]
    isnothing(point) || pushfirst!(evidence, _point_evidence(point))
    return Finding(
        at_point ? Symbol("operating_point_", risk.code) : risk.code;
        severity = nonfinite_derivative_estimate ? SeverityError :
                   risk.assessment == DomainProvenViolation &&
                   risk.code != :exponential_underflow_risk ?
                   SeverityError :
                   SeverityWarning,
        domain = NumericalIssue,
        basis = nonfinite_derivative_estimate ?
                NumericalObservation :
                risk.assessment == DomainProvenViolation ?
                LocalInference :
                HeuristicInterpretation,
        confidence = nonfinite_derivative_estimate ?
                     ConfidenceHigh :
                     risk.assessment == DomainProvenViolation ?
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
    strict_domain_proximity_threshold::Union{Nothing,Real} = nothing,
)
    selected_numeric_type = if !isnothing(numeric_type)
        numeric_type
    elseif !isnothing(point)
        eltype(point.values)
    else
        Float64
    end
    threshold = isnothing(strict_domain_proximity_threshold) ?
                sqrt(eps(selected_numeric_type)) :
                strict_domain_proximity_threshold
    isfinite(threshold) && threshold > 0 || throw(ArgumentError(
        "strict_domain_proximity_threshold must be finite and positive",
    ))
    intervals, interval_origins = if isnothing(point)
        _domain_variable_interval_state(model)
    else
        Dict(
            variable => IntervalEnclosure(value, value, true, true) for
            (variable, value) in zip(point.variables, point.values)
        ), nothing
    end
    risks = _expression_numerical_risks(
        model,
        intervals;
        numeric_type = selected_numeric_type,
        strict_domain_proximity_threshold = threshold,
    )
    if !isnothing(point)
        # Composition fingerprints do not depend on the point and are already
        # part of static analysis. Exact-point analysis focuses on primitive
        # range failures.
        risks = filter(
            risk ->
                (risk.code in (
                    :exponential_overflow_risk,
                    :exponential_underflow_risk,
                    :hyperbolic_overflow_risk,
                    :logistic_value_saturation_risk,
                    :logistic_derivative_underflow_risk,
                    :tanh_value_saturation_risk,
                    :tanh_derivative_underflow_risk,
                    :logcosh_curvature_underflow_risk,
                    :sech_value_underflow_risk,
                    :softplus_value_underflow_risk,
                    :softplus_derivative_underflow_risk,
                    :log1mexp_value_saturation_risk,
                    :logdiffexp_subtrahend_derivative_underflow_risk,
                    :logsumexp_term_derivative_underflow_risk,
                    :periodic_argument_reduction_risk,
                    :atan2_derivative_amplification,
                    :arctangent_endpoint_saturation_risk,
                ) && risk.assessment == DomainProvenViolation) ||
                risk.code in (
                    :strict_domain_derivative_amplification,
                    :atan2_derivative_amplification,
                ),
            risks,
        )
    end
    report = DiagnosticReport()
    records = Dict(record.index => record for record in model.variables)
    for risk in risks
        push!(
            report,
            _expression_risk_finding(
                risk,
                records;
                point = point,
                interval_origins = interval_origins,
            ),
        )
    end
    report.metadata[:expression_numerical_risk_count] =
        string(length(risks))
    report.metadata[:expression_numeric_type] =
        string(selected_numeric_type)
    report.metadata[:strict_domain_proximity_threshold] = string(threshold)
    return report
end

function analyze_expressions(
    model::MOI.ModelLike;
    point::Union{Nothing,EvaluationPoint} = nothing,
    numeric_type::Union{Nothing,Type{<:AbstractFloat}} = nothing,
    strict_domain_proximity_threshold::Union{Nothing,Real} = nothing,
)
    return analyze_expressions(
        snapshot(model);
        point = point,
        numeric_type = numeric_type,
        strict_domain_proximity_threshold = strict_domain_proximity_threshold,
    )
end
