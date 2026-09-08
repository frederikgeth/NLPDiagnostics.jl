@enum DomainAssessment::UInt8 begin
    DomainSafe = 0
    DomainPossibleViolation = 1
    DomainProvenViolation = 2
end

"""
An interval estimate with explicit enclosure certification.

`valid` describes consistency and `informative` describes range information;
neither implies `certified`. Historical two/four-argument constructors produce
uncertified estimates. Use the `certified` keyword only when the endpoints are
validated bounds on the real expression (including all upstream assumptions).
"""
struct IntervalEnclosure
    lower::Real
    upper::Real
    valid::Bool
    informative::Bool
    certified::Bool
end

IntervalEnclosure(lower::Real, upper::Real; certified::Bool = false) =
    IntervalEnclosure(lower, upper, true, true, certified)
IntervalEnclosure(lower::Real, upper::Real, valid::Bool, informative::Bool) =
    IntervalEnclosure(lower, upper, valid, informative, false)

function _declared_interval(lower::Real, upper::Real)
    supported(x) = !isnothing(_exact_real_value(x)) || isinf(x)
    certified = supported(lower) && supported(upper) && lower != Inf && upper != -Inf
    return IntervalEnclosure(lower, upper, lower <= upper, true, certified)
end

_full_interval(; informative::Bool = false, certified::Bool = true) =
    IntervalEnclosure(-Inf, Inf, true, informative, certified)
_invalid_interval(; certified::Bool = true) =
    IntervalEnclosure(Inf, -Inf, false, false, certified)

# Uncertified endpoints must not restrict the real values admitted by a consumer.
# Keep the missing certificate visible even after widening to the full line.
_certified_interval(value::IntervalEnclosure) =
    value.certified ? value : _full_interval(certified = false)
_with_interval_certification(value::IntervalEnclosure, certified::Bool) =
    IntervalEnclosure(value.lower, value.upper, value.valid, value.informative, certified)

function _estimated_operator_interval(operator, arguments, originals)
    result = operator_interval(operator, arguments, originals)
    return _with_interval_certification(result,
        result.certified && all(value -> value.certified, arguments))
end
_checked_operator_interval(operator, arguments, originals) =
    _certified_interval(_estimated_operator_interval(operator, arguments, originals))

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

function _tighten_domain_interval!(intervals, variable, lower::Real, upper::Real;
    certified::Bool = false)
    current = intervals[variable]
    current.valid || return false
    tightened_lower = max(current.lower, lower)
    tightened_upper = min(current.upper, upper)
    # An uninformative proposal must not revoke an existing certificate.
    tightened_lower == current.lower && tightened_upper == current.upper && return false
    intervals[variable] = tightened_lower <= tightened_upper ?
                          IntervalEnclosure(
        tightened_lower,
        tightened_upper,
        true,
        current.informative,
        current.certified && certified,
    ) : _invalid_interval(certified = current.certified && certified)
    updated = intervals[variable]
    return updated.lower != current.lower || updated.upper != current.upper ||
           updated.valid != current.valid
end

function _record_domain_interval_origin!(
    origins,
    variable,
    origin::Symbol,
    constraint_id::Union{Nothing,AbstractString} = nothing,
)
    isnothing(origins) && return
    origin_rows = get!(origins, variable, Dict{Symbol,Set{String}}())
    rows = get!(origin_rows, origin, Set{String}())
    !isnothing(constraint_id) && push!(rows, String(constraint_id))
    return
end

"""A type-qualified MOI constraint ID, avoiding raw-index ambiguity."""
_domain_constraint_origin_id(constraint::ConstraintRecord) =
    "$(typeof(constraint.function_value))/$(typeof(constraint.set_value))#$(constraint.index.value)"

"""Render deterministic origin-category and source-row evidence for an interval."""
function _domain_interval_origin_summary(origins, variable)
    categories = get(origins, variable, Dict{Symbol,Set{String}}())
    isempty(categories) && return ""
    return join(
        [
            "$(category):$(join(sort!(collect(rows)), ","))" for
            (category, rows) in sort!(collect(categories); by = first)
        ],
        ";",
    )
end

"""Propagate exact coordinate intervals from recognized positive diagonal geometry."""
function _propagate_diagonal_quadratic_geometry_intervals!(
    intervals,
    model;
    origins = nothing,
)
    for constraint in model.constraints
        equality = _positive_diagonal_quadratic_equality(
            constraint.function_value,
            constraint.set_value,
        )
        isnothing(equality) && (equality = _nonlinear_positive_diagonal_equality(
            constraint.function_value,
            constraint.set_value,
        ))
        if !isnothing(equality) && equality.effective_level >= 0 &&
           all(value -> value >= 0 && isfinite(value), equality.axis_squared)
            for (variable, center, axis_squared) in
                zip(equality.variables, equality.centers, equality.axis_squared)
                radius = sqrt(axis_squared)
                _tighten_domain_interval!(
                    intervals, variable, center - radius, center + radius,
                ) && _record_domain_interval_origin!(
                    origins, variable, :diagonal_quadratic_geometry,
                    _domain_constraint_origin_id(constraint),
                )
            end
            continue
        end

        set_value = constraint.set_value
        upper = if set_value isa MOI.LessThan
            Float64(set_value.upper)
        elseif set_value isa MOI.Interval
            Float64(set_value.upper)
        else
            continue
        end
        minimum = _positive_diagonal_quadratic_minimum(constraint.function_value)
        isnothing(minimum) && (minimum = _nonlinear_positive_diagonal_minimum(
            constraint.function_value,
        ))
        isnothing(minimum) && continue
        isfinite(upper) && isfinite(minimum.minimum_value) &&
            upper >= minimum.minimum_value || continue
        for (variable, coefficient, center) in
            zip(minimum.variables, minimum.coefficients, minimum.centers)
            axis_squared = minimum.axis_squared_multiplier *
                           (upper - minimum.minimum_value) / coefficient
            axis_squared >= 0 && isfinite(axis_squared) || continue
            radius = sqrt(axis_squared)
            _tighten_domain_interval!(
                intervals, variable, center - radius, center + radius,
            ) && _record_domain_interval_origin!(
                origins, variable, :diagonal_quadratic_geometry,
                _domain_constraint_origin_id(constraint),
            )
        end
    end
    return
end

"""Return the finite or one-sided interval represented by a scalar row set."""
function _domain_scalar_set_interval(set_value)
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

"""Combine repeated affine terms and discard exact zero coefficients."""
function _domain_affine_coefficients(function_value::MOI.ScalarAffineFunction)
    coefficients = Dict{MOI.VariableIndex,Real}()
    for term in function_value.terms
        coefficient = _exact_real_value(term.coefficient)
        # Never discard a nonfinite term and infer a bound from the remaining row.
        isnothing(coefficient) && return nothing
        coefficients[term.variable] = get(coefficients, term.variable, 0) + coefficient
    end
    filter!(entry -> !iszero(last(entry)), coefficients)
    return coefficients
end

"""Exact represented-data affine isolation; unsupported inputs abstain."""
function _exact_affine_bound(bound, offset, coefficient)
    values = _exact_real_value.((bound, offset, coefficient))
    any(isnothing, values) && return nothing
    iszero(values[3]) && return nothing
    return _compact_interval_endpoint((values[1] - values[2]) / values[3])
end

"""Propagate bounded scalar-affine row implications into analysis-only intervals."""
function _propagate_scalar_affine_intervals!(intervals, model; origins = nothing)
    # A Jacobi-style bounded fixed point avoids order-dependent conclusions and
    # cannot become an unbounded presolver loop. A chain can reach each of the
    # model's variables in at most this many useful passes.
    max_passes = max(length(model.variables), 1)
    for _ in 1:max_passes
        previous = copy(intervals)
        candidates = Dict{MOI.VariableIndex,Vector{Tuple{Real,Real,String}}}()
        for constraint in model.constraints
            function_value = constraint.function_value
            function_value isa MOI.ScalarAffineFunction || continue
            row_interval = _domain_scalar_set_interval(constraint.set_value)
            isnothing(row_interval) && continue
            row_lower, row_upper = row_interval
            (isnothing(row_lower) || row_lower isa Real && isfinite(row_lower)) || continue
            (isnothing(row_upper) || row_upper isa Real && isfinite(row_upper)) || continue
            coefficients = _domain_affine_coefficients(function_value)
            (isnothing(coefficients) || isempty(coefficients)) && continue
            function_value.constant isa Real && isfinite(function_value.constant) || continue
            for (target, coefficient) in coefficients
                others = _declared_interval(function_value.constant, function_value.constant)
                for (variable, other_coefficient) in coefficients
                    variable == target && continue
                    other_interval = get(previous, variable, _full_interval())
                    others = _interval_add(
                        others,
                        _interval_scale(other_interval, other_coefficient),
                    )
                end
                others.certified && others.valid && isfinite(others.lower) && isfinite(others.upper) || continue
                lower = -Inf
                upper = Inf
                if !isnothing(row_lower)
                    candidate = _exact_affine_bound(row_lower, others.upper, coefficient)
                    isnothing(candidate) && continue
                    coefficient > 0 ? (lower = candidate) : (upper = candidate)
                end
                if !isnothing(row_upper)
                    candidate = _exact_affine_bound(row_upper, others.lower, coefficient)
                    isnothing(candidate) && continue
                    coefficient > 0 ? (upper = candidate) : (lower = candidate)
                end
                isfinite(lower) || (lower = -Inf)
                isfinite(upper) || (upper = Inf)
                (lower == -Inf && upper == Inf) && continue
                push!(
                    get!(candidates, target, Tuple{Real,Real,String}[]),
                    (lower, upper, _domain_constraint_origin_id(constraint)),
                )
            end
        end
        changed = false
        for (variable, bounds) in candidates
            lower = maximum(first.(bounds))
            upper = minimum(bound -> bound[2], bounds)
            current = intervals[variable]
            prior_lower, prior_upper = current.lower, current.upper
            tightened = _tighten_domain_interval!(intervals, variable, lower, upper; certified = true)
            updated = intervals[variable]
            changed |= tightened
            tightened && _record_domain_interval_origin!(
                origins, variable, :scalar_affine_propagation,
                # Every candidate contributing to this batch is retained: the
                # final interval is their intersection.
                first(bounds)[3],
            )
            if tightened
                for (_, _, source_index) in bounds[2:end]
                    _record_domain_interval_origin!(
                        origins, variable, :scalar_affine_propagation, source_index,
                    )
                end
            end
        end
        !changed && break
    end
    return
end

"""Return exact input bounds implied by a supported monotone unary range."""
function _monotone_unary_input_bounds(head::Symbol, lower, upper)
    # log1mexp(x) = log(1 - exp(x)) is strictly decreasing on x < 0.
    # Its inverse is the same stable primitive applied to the output value.
    if head == :log1mexp
        input_lower = -Inf
        input_upper = Inf
        !isnothing(lower) && lower < 0 &&
            (input_upper = _stable_log1mexp_value(lower))
        !isnothing(upper) && upper < 0 &&
            (input_lower = _stable_log1mexp_value(upper))
        isfinite(input_lower) || (input_lower = -Inf)
        isfinite(input_upper) || (input_upper = Inf)
        input_lower <= input_upper || return nothing
        return input_lower, input_upper
    end
    if head in (:softplus, :log1pexp, :log1exp)
        # log(exp(y) - 1) = y + log(1 - exp(-y)); the latter form is
        # stable at both small and large positive y values.
        inverse = value -> value + _stable_log1mexp_value(-value)
        input_lower = -Inf
        input_upper = Inf
        !isnothing(lower) && lower > 0 &&
            (input_lower = inverse(lower))
        !isnothing(upper) && upper > 0 &&
            (input_upper = inverse(upper))
        isfinite(input_lower) || (input_lower = -Inf)
        isfinite(input_upper) || (input_upper = Inf)
        input_lower <= input_upper || return nothing
        return input_lower, input_upper
    end
    if head == :logistic
        # logit(y) = log(y) - log1p(-y), evaluated only on the open range.
        inverse = value -> log(value) - log1p(-value)
        input_lower = -Inf
        input_upper = Inf
        !isnothing(lower) && 0 < lower < 1 &&
            (input_lower = inverse(lower))
        !isnothing(upper) && 0 < upper < 1 &&
            (input_upper = inverse(upper))
        isfinite(input_lower) || (input_lower = -Inf)
        isfinite(input_upper) || (input_upper = Inf)
        input_lower <= input_upper || return nothing
        return input_lower, input_upper
    end
    if head == :tanh
        # atanh(y) = (log1p(y) - log1p(-y)) / 2 on the open range.
        inverse = value -> (log1p(value) - log1p(-value)) / 2
        input_lower = -Inf
        input_upper = Inf
        !isnothing(lower) && -1 < lower < 1 &&
            (input_lower = inverse(lower))
        !isnothing(upper) && -1 < upper < 1 &&
            (input_upper = inverse(upper))
        isfinite(input_lower) || (input_lower = -Inf)
        isfinite(input_upper) || (input_upper = Inf)
        input_lower <= input_upper || return nothing
        return input_lower, input_upper
    end
    if head == :acosh
        input_lower = -Inf
        input_upper = Inf
        !isnothing(lower) && lower > 0 &&
            (input_lower = cosh(lower))
        !isnothing(upper) && upper >= 0 &&
            (input_upper = cosh(upper))
        isfinite(input_lower) || (input_lower = -Inf)
        isfinite(input_upper) || (input_upper = Inf)
        input_lower <= input_upper || return nothing
        return input_lower, input_upper
    end
    if head == :atan
        input_lower = -Inf
        input_upper = Inf
        !isnothing(lower) && -pi / 2 < lower < pi / 2 &&
            (input_lower = tan(lower))
        !isnothing(upper) && -pi / 2 < upper < pi / 2 &&
            (input_upper = tan(upper))
        isfinite(input_lower) || (input_lower = -Inf)
        isfinite(input_upper) || (input_upper = Inf)
        input_lower <= input_upper || return nothing
        return input_lower, input_upper
    end
    if head in (:asin, :asind, :atand)
        lower_limit, upper_limit, inverse = if head == :asin
            (-pi / 2, pi / 2, sin)
        elseif head == :asind
            (-90.0, 90.0, sind)
        else
            (-90.0, 90.0, tand)
        end
        input_lower = -Inf
        input_upper = Inf
        !isnothing(lower) && lower_limit <= lower <= upper_limit &&
            (input_lower = inverse(lower))
        !isnothing(upper) && lower_limit <= upper <= upper_limit &&
            (input_upper = inverse(upper))
        isfinite(input_lower) || (input_lower = -Inf)
        isfinite(input_upper) || (input_upper = Inf)
        input_lower <= input_upper || return nothing
        return input_lower, input_upper
    end
    if head in (:acos, :acosd)
        lower_limit, upper_limit, inverse = head == :acos ?
            (0.0, pi, cos) : (0.0, 180.0, cosd)
        # acos is decreasing: a lower output bound gives an upper input bound.
        input_lower = -Inf
        input_upper = Inf
        !isnothing(lower) && lower_limit <= lower <= upper_limit &&
            (input_upper = inverse(lower))
        !isnothing(upper) && lower_limit <= upper <= upper_limit &&
            (input_lower = inverse(upper))
        isfinite(input_lower) || (input_lower = -Inf)
        isfinite(input_upper) || (input_upper = Inf)
        input_lower <= input_upper || return nothing
        return input_lower, input_upper
    end
    inverse = if head == :log
        exp
    elseif head == :log10
        value -> 10.0^value
    elseif head == :log2
        value -> 2.0^value
    elseif head == :log1p
        expm1
    elseif head == :exp
        log
    elseif head == :exp2
        log2
    elseif head == :expm1
        log1p
    elseif head == :sqrt
        value -> value^2
    elseif head == :cbrt
        value -> value^3
    elseif head == :sinh
        asinh
    elseif head == :asinh
        sinh
    elseif head == :atanh
        tanh
    else
        return nothing
    end
    input_lower = -Inf
    input_upper = Inf
    if head in (:exp, :exp2)
        !isnothing(lower) && lower > 0 && (input_lower = inverse(lower))
        !isnothing(upper) && upper > 0 && (input_upper = inverse(upper))
    elseif head == :expm1
        !isnothing(lower) && lower > -1 && (input_lower = inverse(lower))
        !isnothing(upper) && upper > -1 && (input_upper = inverse(upper))
    elseif head == :sqrt
        !isnothing(lower) && lower > 0 && (input_lower = inverse(lower))
        !isnothing(upper) && upper >= 0 && (input_upper = inverse(upper))
    else
        !isnothing(lower) && (input_lower = inverse(lower))
        !isnothing(upper) && (input_upper = inverse(upper))
    end
    isfinite(input_lower) || (input_lower = -Inf)
    isfinite(input_upper) || (input_upper = Inf)
    input_lower <= input_upper || return nothing
    return input_lower, input_upper
end

# Only algebraic inverses and exact reference values are admitted here. A
# missing side remains unbounded; an unknown numeric inverse is never rounded
# into a certified premise.
function _certified_monotone_unary_input_bounds(head, lower, upper)
    function inverse(value)
        exact = _exact_real_value(value)
        isnothing(exact) && return nothing
        head == :sqrt && exact >= 0 && return _compact_interval_endpoint(exact^2)
        head == :cbrt && return _compact_interval_endpoint(exact^3)
        head in (:log, :log2, :log10) && iszero(exact) && return 1.0
        head in (:exp, :exp2) && exact == 1 && return 0.0
        head in (:log1p, :expm1, :sinh, :asinh, :tanh, :atanh, :atan, :atand,
                 :asin, :asind) && iszero(exact) && return 0.0
        return nothing
    end
    low = isnothing(lower) ? nothing : inverse(lower)
    high = isnothing(upper) ? nothing : inverse(upper)
    (isnothing(low) && isnothing(high)) && return nothing
    return something(low, -Inf), something(high, Inf)
end

"""Propagate direct, supported monotone unary nonlinear rows to their input."""
function _propagate_monotone_unary_intervals!(intervals, model; origins = nothing, certified_only::Bool = false)
    max_passes = max(length(model.variables), 1)
    for _ in 1:max_passes
        candidates = Dict{MOI.VariableIndex,Vector{Tuple{Real,Real,String}}}()
        for constraint in model.constraints
            function_value = constraint.function_value
            function_value isa MOI.ScalarNonlinearFunction || continue
            length(function_value.args) == 1 || continue
            variable = only(function_value.args)
            variable isa MOI.VariableIndex || continue
            row_interval = _domain_scalar_set_interval(constraint.set_value)
            isnothing(row_interval) && continue
            lower, upper = row_interval
            (isnothing(lower) || lower isa Real && isfinite(lower)) || continue
            (isnothing(upper) || upper isa Real && isfinite(upper)) || continue
            bounds = certified_only ?
                _certified_monotone_unary_input_bounds(function_value.head, lower, upper) :
                _monotone_unary_input_bounds(function_value.head, lower, upper)
            isnothing(bounds) && continue
            push!(
                get!(candidates, variable, Tuple{Real,Real,String}[]),
                (bounds[1], bounds[2], _domain_constraint_origin_id(constraint)),
            )
        end
        changed = false
        for (variable, bounds) in candidates
            lower = maximum(first.(bounds))
            upper = minimum(bound -> bound[2], bounds)
            current = intervals[variable]
            prior_lower, prior_upper = current.lower, current.upper
            tightened = _tighten_domain_interval!(intervals, variable, lower, upper; certified = certified_only)
            updated = intervals[variable]
            changed |= tightened
            tightened && _record_domain_interval_origin!(
                origins, variable, :monotone_unary_inversion, first(bounds)[3],
            )
            if tightened
                for (_, _, source_index) in bounds[2:end]
                    _record_domain_interval_origin!(
                        origins, variable, :monotone_unary_inversion, source_index,
                    )
                end
            end
        end
        !changed && break
    end
    return
end

"""Propagate the exact connected interval implied by direct `abs(x)` upper rows."""
function _propagate_absolute_value_intervals!(intervals, model; origins = nothing)
    for constraint in model.constraints
        function_value = constraint.function_value
        function_value isa MOI.ScalarNonlinearFunction || continue
        function_value.head == :abs && length(function_value.args) == 1 || continue
        variable = only(function_value.args)
        variable isa MOI.VariableIndex || continue
        row_interval = _domain_scalar_set_interval(constraint.set_value)
        isnothing(row_interval) && continue
        _, upper = row_interval
        upper isa Real && isfinite(upper) && upper >= 0 || continue
        isnothing(_exact_real_value(upper)) && continue
        _tighten_domain_interval!(intervals, variable, -something(_exact_real_value(upper), upper), upper;
            certified = !isnothing(_exact_real_value(upper))) &&
            _record_domain_interval_origin!(
                origins, variable, :absolute_value_range,
                _domain_constraint_origin_id(constraint),
            )
    end
    return
end

"""Propagate the connected input interval implied by direct `cosh(x)` upper rows."""
function _propagate_cosh_intervals!(intervals, model; origins = nothing, certified_only::Bool = false)
    for constraint in model.constraints
        function_value = constraint.function_value
        function_value isa MOI.ScalarNonlinearFunction || continue
        function_value.head == :cosh && length(function_value.args) == 1 || continue
        variable = only(function_value.args)
        variable isa MOI.VariableIndex || continue
        row_interval = _domain_scalar_set_interval(constraint.set_value)
        isnothing(row_interval) && continue
        _, upper = row_interval
        upper isa Real && isfinite(upper) && upper >= 1 || continue
        certified_only && upper != 1 && continue
        radius = acosh(upper)
        _tighten_domain_interval!(intervals, variable, -radius, radius; certified = upper == 1) &&
            _record_domain_interval_origin!(
                origins, variable, :cosh_range,
                _domain_constraint_origin_id(constraint),
            )
    end
    return
end

"""Propagate the connected input interval implied by direct `logcosh(x)` upper rows."""
function _propagate_logcosh_intervals!(intervals, model; origins = nothing, certified_only::Bool = false)
    for constraint in model.constraints
        function_value = constraint.function_value
        function_value isa MOI.ScalarNonlinearFunction || continue
        function_value.head == :logcosh && length(function_value.args) == 1 ||
            continue
        variable = only(function_value.args)
        variable isa MOI.VariableIndex || continue
        row_interval = _domain_scalar_set_interval(constraint.set_value)
        isnothing(row_interval) && continue
        _, upper = row_interval
        upper isa Real && isfinite(upper) && upper >= 0 || continue
        # acosh(exp(u)) = u + log(1 + sqrt(1 - exp(-2u))).
        certified_only && upper != 0 && continue
        radius = upper + log1p(sqrt(-expm1(-2 * upper)))
        _tighten_domain_interval!(intervals, variable, -radius, radius; certified = upper == 0) &&
            _record_domain_interval_origin!(
                origins, variable, :logcosh_range,
                _domain_constraint_origin_id(constraint),
            )
    end
    return
end

"""Propagate exact one-sided intervals from direct variable/constant min/max rows."""
function _propagate_minmax_intervals!(intervals, model; origins = nothing)
    for constraint in model.constraints
        function_value = constraint.function_value
        function_value isa MOI.ScalarNonlinearFunction || continue
        function_value.head in (:min, :max) && length(function_value.args) == 2 ||
            continue
        left, right = function_value.args
        variable, constant = left isa MOI.VariableIndex && right isa Real ?
                             (left, right) :
                             right isa MOI.VariableIndex && left isa Real ?
                             (right, left) : (nothing, nothing)
        (isnothing(variable) || isnothing(_exact_real_value(constant))) && continue
        row_interval = _domain_scalar_set_interval(constraint.set_value)
        isnothing(row_interval) && continue
        lower, upper = row_interval
        if function_value.head == :min && lower isa Real && isfinite(lower) &&
           lower <= constant
            _tighten_domain_interval!(intervals, variable, lower, Inf; certified = !isnothing(_exact_real_value(lower))) &&
                _record_domain_interval_origin!(
                    origins, variable, :minmax_branch_interval,
                    _domain_constraint_origin_id(constraint),
                )
        elseif function_value.head == :max && upper isa Real && isfinite(upper) &&
               upper >= constant
            _tighten_domain_interval!(intervals, variable, -Inf, upper; certified = !isnothing(_exact_real_value(upper))) &&
                _record_domain_interval_origin!(
                    origins, variable, :minmax_branch_interval,
                    _domain_constraint_origin_id(constraint),
                )
        end
    end
    return
end

function _domain_variable_interval_state(model::ModelSnapshot; certified_only::Bool = false)
    intervals = Dict(
        record.index => _full_interval(informative = true) for
        record in model.variables
    )
    origins = Dict{MOI.VariableIndex,Dict{Symbol,Set{String}}}()
    for constraint in model.constraints
        variable = constraint.function_value
        variable isa MOI.VariableIndex || continue
        current = intervals[variable]
        set_value = constraint.set_value
        candidate = if set_value isa MOI.Parameter
            set_value.value isa Real || continue
            _declared_interval(set_value.value, set_value.value)
        elseif set_value isa MOI.EqualTo
            _declared_interval(set_value.value, set_value.value)
        elseif set_value isa MOI.Interval
            _declared_interval(set_value.lower, set_value.upper)
        elseif set_value isa MOI.GreaterThan
            _declared_interval(set_value.lower, Inf)
        elseif set_value isa MOI.LessThan
            _declared_interval(-Inf, set_value.upper)
        elseif set_value isa MOI.ZeroOne
            _declared_interval(0.0, 1.0)
        elseif set_value isa MOI.Semicontinuous ||
               set_value isa MOI.Semiinteger
            _declared_interval(
                min(0.0, set_value.lower),
                max(0.0, set_value.upper),
            )
        else
            continue
        end
        lower = max(current.lower, candidate.lower)
        upper = min(current.upper, candidate.upper)
        updated = lower <= upper ?
                              IntervalEnclosure(
            lower,
            upper,
            true,
            current.informative && candidate.informative,
            current.certified && candidate.certified,
        ) : _invalid_interval(certified = current.certified && candidate.certified)
        intervals[variable] = updated
        (updated.lower != current.lower || updated.upper != current.upper ||
         updated.valid != current.valid) && _record_domain_interval_origin!(
            origins, variable, :declared_variable_bounds,
            _domain_constraint_origin_id(constraint),
        )
    end
    !certified_only && _propagate_diagonal_quadratic_geometry_intervals!(intervals, model; origins = origins)
    _propagate_scalar_affine_intervals!(intervals, model; origins = origins)
    _propagate_absolute_value_intervals!(intervals, model; origins = origins)
    _propagate_cosh_intervals!(intervals, model; origins = origins, certified_only = certified_only)
    _propagate_logcosh_intervals!(intervals, model; origins = origins, certified_only = certified_only)
    _propagate_minmax_intervals!(intervals, model; origins = origins)
    _propagate_monotone_unary_intervals!(intervals, model; origins = origins, certified_only = certified_only)
    # A monotone row may have produced a new affine input bound. One final
    # bounded affine closure exposes that implication to downstream scans.
    _propagate_scalar_affine_intervals!(intervals, model; origins = origins)
    return intervals, origins
end

function _domain_variable_intervals(model::ModelSnapshot)
    intervals, _ = _domain_variable_interval_state(model; certified_only = true)
    return Dict(variable => _certified_interval(interval) for (variable, interval) in intervals)
end

"""
    domain_interval_data(model)

Return renderer-neutral, analysis-only variable intervals used by static domain,
derivative, initialization, and numerical-fingerprint checks. Each entry
retains the interval's validity and type-qualified source provenance; this
function never adds bounds or otherwise modifies the model.
"""
function domain_interval_data(model::ModelSnapshot)
    intervals, origins = _domain_variable_interval_state(model)
    return [
        Dict{String,Any}(
            "variable_index" => record.index.value,
            "variable_name" => isnothing(record.name) ? "" : record.name,
            "lower" => intervals[record.index].lower,
            "upper" => intervals[record.index].upper,
            "valid" => intervals[record.index].valid,
            "informative" => intervals[record.index].informative,
            "certified" => intervals[record.index].certified,
            "origins" => _domain_interval_origin_summary(origins, record.index),
        ) for record in model.variables
    ]
end

domain_interval_data(model::MOI.ModelLike) = domain_interval_data(snapshot(model))

# Rational endpoints represent the exact binary input values. Compact only when
# a Float64 represents the result exactly; never round an enclosure inward.
function _compact_interval_endpoint(value::Rational{BigInt})
    compact = Float64(value)
    return isfinite(compact) && _exact_real_value(compact) == value ? compact : value
end
_compact_interval_endpoint(value) = value

function _exact_interval_bounds(value::IntervalEnclosure)
    lower = isinf(value.lower) ? value.lower : _exact_real_value(value.lower)
    upper = isinf(value.upper) ? value.upper : _exact_real_value(value.upper)
    (isnothing(lower) || isnothing(upper)) && return nothing
    # Infinite endpoints are limits, never admissible singleton real values.
    (lower == Inf || upper == -Inf || lower > upper) && return nothing
    return lower, upper
end

function _exact_interval_result(lower, upper, informative, certified)
    (isnan(lower) || isnan(upper)) && return _full_interval(certified = certified)
    return IntervalEnclosure(_compact_interval_endpoint(lower),
        _compact_interval_endpoint(upper), true, informative, certified)
end

# Handle infinite limits without converting a finite rational to floating point.
_exact_endpoint_add(a, b) = isinf(a) ? (b == -a ? NaN : a) : isinf(b) ? b : a + b
function _exact_endpoint_product(a, b)
    (iszero(a) || iszero(b)) && return big(0)//big(1)
    (isinf(a) || isinf(b)) && return sign(a) == sign(b) ? Inf : -Inf
    return a * b
end
_exact_endpoint_inverse(a) = isinf(a) ? big(0)//big(1) : inv(a)

function _interval_add(left::IntervalEnclosure, right::IntervalEnclosure)
    left.valid && right.valid || return _invalid_interval(certified = left.certified && right.certified)
    a, b = _exact_interval_bounds(left), _exact_interval_bounds(right)
    (isnothing(a) || isnothing(b)) && return _full_interval(certified = left.certified && right.certified)
    return _exact_interval_result(_exact_endpoint_add(a[1], b[1]),
        _exact_endpoint_add(a[2], b[2]), left.informative && right.informative,
        left.certified && right.certified)
end

function _interval_scale(value::IntervalEnclosure, coefficient::Real)
    value.valid || return _invalid_interval(certified = value.certified)
    exact = _exact_real_value(coefficient)
    bounds = _exact_interval_bounds(value)
    (isnothing(exact) || isnothing(bounds)) && return _full_interval(certified = value.certified)
    endpoints = [_exact_endpoint_product(exact, bound) for bound in bounds]
    return _exact_interval_result(minimum(endpoints), maximum(endpoints), value.informative, value.certified)
end

function _interval_multiply(left::IntervalEnclosure, right::IntervalEnclosure)
    left.valid && right.valid || return _invalid_interval(certified = left.certified && right.certified)
    a, b = _exact_interval_bounds(left), _exact_interval_bounds(right)
    (isnothing(a) || isnothing(b)) && return _full_interval(certified = left.certified && right.certified)
    products = [_exact_endpoint_product(x, y) for x in a for y in b]
    return _exact_interval_result(minimum(products), maximum(products),
        left.informative && right.informative, left.certified && right.certified)
end

_contains_zero(value::IntervalEnclosure) =
    value.valid && value.lower <= 0.0 <= value.upper

function _interval_reciprocal(value::IntervalEnclosure)
    value.valid || return _invalid_interval(certified = value.certified)
    bounds = _exact_interval_bounds(value)
    isnothing(bounds) && return _full_interval(certified = value.certified)
    _contains_zero(value) && return _full_interval(certified = value.certified)
    return _exact_interval_result(_exact_endpoint_inverse(bounds[2]),
        _exact_endpoint_inverse(bounds[1]), value.informative, value.certified)
end

function _interval_integer_power(value::IntervalEnclosure, exponent::Int)
    value.valid || return _invalid_interval(certified = value.certified)
    bounds = _exact_interval_bounds(value)
    isnothing(bounds) && return _full_interval(certified = value.certified)
    # Bound exact-integer work, including typemin(Int), before negation/powering.
    -1024 <= exponent <= 1024 || return _full_interval(certified = value.certified)
    iszero(exponent) && return _declared_interval(1.0, 1.0)
    if exponent < 0
        _contains_zero(value) && return _full_interval(certified = value.certified)
        return _interval_reciprocal(_interval_integer_power(value, -exponent))
    end
    endpoints = [bound^exponent for bound in bounds]
    lower = iseven(exponent) && _contains_zero(value) ? 0 : minimum(endpoints)
    return _exact_interval_result(lower, maximum(endpoints), value.informative, value.certified)
end

function _interval_affine(
    value::MOI.ScalarAffineFunction,
    variable_intervals,
)
    result = _declared_interval(value.constant, value.constant)
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
                something(_exact_real_value(term.coefficient), term.coefficient) / 2,
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
        return _declared_interval(value, value)
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
    enclosure.certified || return DomainPossibleViolation
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

function _upper_domain_assessment(
    enclosure::IntervalEnclosure,
    threshold::Real;
    strict::Bool,
)
    enclosure.certified || return DomainPossibleViolation
    enclosure.valid || return DomainSafe
    if strict
        enclosure.lower >= threshold && return DomainProvenViolation
        enclosure.upper >= threshold && return DomainPossibleViolation
    else
        enclosure.lower > threshold && return DomainProvenViolation
        enclosure.upper > threshold && return DomainPossibleViolation
    end
    return DomainSafe
end

function _nonzero_domain_assessment(enclosure::IntervalEnclosure)
    enclosure.certified || return DomainPossibleViolation
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
    !enclosure.certified && (assessment = DomainPossibleViolation)
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

_stable_log1mexp_value(x) =
    x < -log(2.0) ? log1p(-exp(x)) : log(-expm1(x))

_stable_logcosh_value(x) =
    abs(x) + log1p(exp(-2 * abs(x))) - log(2.0)

function _stable_logsumexp_values(values)
    isempty(values) && throw(ArgumentError("logsumexp requires at least one argument"))
    shift = maximum(values)
    shift == -Inf && return -Inf
    shift == Inf && return Inf
    return shift + log(sum(exp(value - shift) for value in values))
end

"""Conservatively enclose sin/cos over one finite, numerically moderate period."""
function _periodic_trig_interval(
    value::IntervalEnclosure,
    endpoint_function,
    maximum_offset::Real,
    minimum_offset::Real,
    period::Real,
)
    value.valid || return _invalid_interval()
    lower, upper = value.lower, value.upper
    # Wide, unbounded, or very-large arguments are deliberately widened. The
    # latter avoids treating floating-point argument reduction as a proof.
    (!isfinite(lower) || !isfinite(upper) || upper - lower >= period ||
     max(abs(lower), abs(upper)) > 1.0e12) && return _full_interval()
    contains_phase(offset) =
        ceil((lower - offset) / period) <= floor((upper - offset) / period)
    endpoint_lower = endpoint_function(lower)
    endpoint_upper = endpoint_function(upper)
    range_lower = min(endpoint_lower, endpoint_upper)
    range_upper = max(endpoint_lower, endpoint_upper)
    contains_phase(maximum_offset) && (range_upper = 1.0)
    contains_phase(minimum_offset) && (range_lower = -1.0)
    return IntervalEnclosure(range_lower, range_upper, true, value.informative)
end

"""Enclose tangent on one finite branch; any included pole widens the range."""
function _periodic_tangent_interval(
    value::IntervalEnclosure,
    endpoint_function,
    singular_offset::Real,
    period::Real,
)
    value.valid || return _invalid_interval()
    lower, upper = value.lower, value.upper
    (!isfinite(lower) || !isfinite(upper) ||
     max(abs(lower), abs(upper)) > 1.0e12) && return _full_interval()
    contains_pole =
        ceil((lower - singular_offset) / period) <=
        floor((upper - singular_offset) / period)
    contains_pole && return _full_interval()
    # tan is strictly increasing between adjacent poles.
    return IntervalEnclosure(
        endpoint_function(lower),
        endpoint_function(upper),
        true,
        value.informative,
    )
end

"""Enclose inverse secant/cosecant only on one valid sign branch."""
function _inverse_reciprocal_trig_interval(
    value::IntervalEnclosure,
    transform;
    increasing::Bool,
)
    value.valid || return _invalid_interval()
    # The real domain has two components. An enclosure spanning the excluded
    # interval [-1, 1] must not be treated as a monotone branch.
    (value.lower >= 1.0 || value.upper <= -1.0) || return _full_interval()
    lower_value = transform(value.lower)
    upper_value = transform(value.upper)
    return increasing ?
           IntervalEnclosure(lower_value, upper_value, true, value.informative) :
           IntervalEnclosure(upper_value, lower_value, true, value.informative)
end

"""Enclose an inverse reciprocal hyperbolic primitive on one domain branch."""
function _inverse_reciprocal_hyperbolic_interval(
    value::IntervalEnclosure,
    transform;
    lower_limit::Real,
    upper_limit::Real,
    lower_strict::Bool,
    upper_strict::Bool,
)
    value.valid || return _invalid_interval()
    lower_ok = lower_strict ? value.lower > lower_limit : value.lower >= lower_limit
    upper_ok = upper_strict ? value.upper < upper_limit : value.upper <= upper_limit
    (lower_ok && upper_ok) || return _full_interval()
    # Each supported inverse reciprocal hyperbolic primitive is decreasing on
    # its selected real-domain branch.
    return IntervalEnclosure(
        transform(value.upper), transform(value.lower), true, value.informative,
    )
end

"""
    operator_interval(Val(operator), argument_intervals, original_arguments)

Return an interval estimate and its explicit certification status. Packages
registering custom nonlinear operators may extend this function and assert
certification only for validated enclosures. The fallback is the full real line.
"""
function operator_interval(operator::Val, arguments::Vector{IntervalEnclosure}, originals)
    result = _builtin_operator_interval(operator, arguments, originals)
    exact_rule = _operator_symbol(operator) in (:abs, :min, :max, :sign) &&
        all(value -> !isnothing(_exact_interval_bounds(value)), arguments)
    return _with_interval_certification(result,
        (result.certified || exact_rule) && all(value -> value.certified, arguments))
end

function _builtin_operator_interval(
    operator::Val,
    arguments::Vector{IntervalEnclosure},
    original_arguments,
)
    head = _operator_symbol(operator)
    if head == :+
        return foldl(
            _interval_add,
            arguments;
            init = _declared_interval(0.0, 0.0),
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
            init = _declared_interval(1.0, 1.0),
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
    elseif head == :logistic && length(arguments) == 1
        value = only(arguments)
        # Preserve finite interval endpoints without overflow in exp(±x).
        stable_logistic(x) =
            x >= 0 ? inv(1 + exp(-x)) : exp(x) / (1 + exp(x))
        return IntervalEnclosure(
            stable_logistic(value.lower),
            stable_logistic(value.upper),
            value.valid,
            value.informative,
        )
    elseif head == :log1mexp
        value = only(arguments)
        value.valid || return _invalid_interval()
        value.lower >= 0.0 && return _full_interval()
        return IntervalEnclosure(
            value.upper >= 0.0 ? -Inf : _stable_log1mexp_value(value.upper),
            _stable_log1mexp_value(value.lower),
            true,
            value.informative,
        )
    elseif head == :logcosh
        value = only(arguments)
        lower_input = _contains_zero(value) ? 0.0 : min(abs(value.lower), abs(value.upper))
        upper_input = max(abs(value.lower), abs(value.upper))
        return IntervalEnclosure(
            _stable_logcosh_value(lower_input), _stable_logcosh_value(upper_input),
            value.valid, value.informative,
        )
    elseif head in (:sinh, :asinh, :tanh) && length(arguments) == 1
        value = only(arguments)
        transform = head == :sinh ? sinh : head == :asinh ? asinh : tanh
        return IntervalEnclosure(
            transform(value.lower),
            transform(value.upper),
            value.valid,
            value.informative,
        )
    elseif head == :cosh && length(arguments) == 1
        value = only(arguments)
        lower_input = _contains_zero(value) ? 0.0 : min(abs(value.lower), abs(value.upper))
        upper_input = max(abs(value.lower), abs(value.upper))
        return IntervalEnclosure(
            cosh(lower_input),
            cosh(upper_input),
            value.valid,
            value.informative,
        )
    elseif head == :acosh && length(arguments) == 1
        value = only(arguments)
        value.valid || return _invalid_interval()
        value.upper < 1.0 && return _full_interval()
        return IntervalEnclosure(
            acosh(max(1.0, value.lower)),
            acosh(value.upper),
            true,
            value.informative,
        )
    elseif head == :atanh && length(arguments) == 1
        value = only(arguments)
        value.valid || return _invalid_interval()
        (value.upper <= -1.0 || value.lower >= 1.0) && return _full_interval()
        lower = value.lower <= -1.0 ? -Inf : atanh(value.lower)
        upper = value.upper >= 1.0 ? Inf : atanh(value.upper)
        return IntervalEnclosure(lower, upper, true, value.informative)
    elseif head == :logsumexp
        isempty(arguments) && return _full_interval()
        return IntervalEnclosure(
            _stable_logsumexp_values([value.lower for value in arguments]),
            _stable_logsumexp_values([value.upper for value in arguments]),
            all(value -> value.valid, arguments),
            all(value -> value.informative, arguments),
        )
    elseif head == :logdiffexp && length(arguments) == 2
        first_value, second_value = arguments
        difference = _interval_add(first_value, _interval_scale(second_value, -1.0))
        difference.valid || return _invalid_interval()
        difference.upper <= 0.0 && return _full_interval()
        lower = difference.lower <= 0.0 ? -Inf :
                first_value.lower + _stable_log1mexp_value(second_value.upper - first_value.lower)
        upper = first_value.upper + _stable_log1mexp_value(second_value.lower - first_value.upper)
        return IntervalEnclosure(lower, upper, true,
            first_value.informative && second_value.informative)
    elseif head == :abs
        value = only(arguments)
        bounds = _exact_interval_bounds(value)
        isnothing(bounds) && return _full_interval()
        value = IntervalEnclosure(bounds[1], bounds[2], value.valid, value.informative, value.certified)
        lower = _contains_zero(value) ?
                0.0 :
                min(abs(value.lower), abs(value.upper))
        return IntervalEnclosure(
            lower,
            max(abs(value.lower), abs(value.upper)),
            value.valid,
            value.informative,
        )
    elseif head == :cbrt && length(arguments) == 1
        value = only(arguments)
        return IntervalEnclosure(
            cbrt(value.lower),
            cbrt(value.upper),
            value.valid,
            value.informative,
        )
    elseif head == :sign && length(arguments) == 1
        value = only(arguments)
        value.valid || return _invalid_interval()
        if value.lower > 0.0
            return IntervalEnclosure(1.0, 1.0, true, value.informative)
        elseif value.upper < 0.0
            return IntervalEnclosure(-1.0, -1.0, true, value.informative)
        elseif value.lower == 0.0 && value.upper == 0.0
            return IntervalEnclosure(0.0, 0.0, true, value.informative)
        elseif value.lower >= 0.0
            return IntervalEnclosure(0.0, 1.0, true, value.informative)
        elseif value.upper <= 0.0
            return IntervalEnclosure(-1.0, 0.0, true, value.informative)
        end
        return IntervalEnclosure(-1.0, 1.0, true, value.informative)
    elseif head in (:min, :max)
        isempty(arguments) && return _full_interval()
        valid = all(value -> value.valid, arguments)
        valid || return _invalid_interval()
        informative = all(value -> value.informative, arguments)
        if head == :min
            return IntervalEnclosure(
                min((value.lower for value in arguments)...),
                min((value.upper for value in arguments)...),
                true,
                informative,
            )
        end
        return IntervalEnclosure(
            max((value.lower for value in arguments)...),
            max((value.upper for value in arguments)...),
            true,
            informative,
        )
    elseif head == :atan && length(arguments) == 1
        value = only(arguments)
        return IntervalEnclosure(
            atan(value.lower),
            atan(value.upper),
            value.valid,
            value.informative,
        )
    elseif head == :atan && length(arguments) == 2
        # `atan(y, x)` is Julia's quadrant-aware two-argument arctangent.
        # A rectangle in (y, x) can straddle its branch cut, so retain the
        # complete closed range as a conservative enclosure rather than
        # applying the unary monotonicity rule to either coordinate.
        return IntervalEnclosure(
            -Float64(pi),
            Float64(pi),
            all(value -> value.valid, arguments),
            false,
        )
    elseif head in (:asin, :asind) && length(arguments) == 1
        value = only(arguments)
        value.valid || return _invalid_interval()
        (value.upper < -1.0 || value.lower > 1.0) && return _full_interval()
        inverse = head == :asin ? asin : asind
        return IntervalEnclosure(
            inverse(max(-1.0, value.lower)),
            inverse(min(1.0, value.upper)),
            true,
            value.informative,
        )
    elseif head in (:acos, :acosd) && length(arguments) == 1
        value = only(arguments)
        value.valid || return _invalid_interval()
        (value.upper < -1.0 || value.lower > 1.0) && return _full_interval()
        inverse = head == :acos ? acos : acosd
        # acos is decreasing on its real domain.
        return IntervalEnclosure(
            inverse(min(1.0, value.upper)),
            inverse(max(-1.0, value.lower)),
            true,
            value.informative,
        )
    elseif head == :atand && length(arguments) == 1
        value = only(arguments)
        return IntervalEnclosure(
            atand(value.lower),
            atand(value.upper),
            value.valid,
            value.informative,
        )
    elseif head == :sin && length(arguments) == 1
        return _periodic_trig_interval(
            only(arguments), sin, pi / 2, -pi / 2, 2pi,
        )
    elseif head == :cos && length(arguments) == 1
        return _periodic_trig_interval(
            only(arguments), cos, 0.0, pi, 2pi,
        )
    elseif head == :sind && length(arguments) == 1
        return _periodic_trig_interval(
            only(arguments), sind, 90.0, -90.0, 360.0,
        )
    elseif head == :cosd && length(arguments) == 1
        return _periodic_trig_interval(
            only(arguments), cosd, 0.0, 180.0, 360.0,
        )
    elseif head == :tan && length(arguments) == 1
        return _periodic_tangent_interval(
            only(arguments), tan, pi / 2, pi,
        )
    elseif head == :tand && length(arguments) == 1
        return _periodic_tangent_interval(
            only(arguments), tand, 90.0, 180.0,
        )
    elseif head in (:sec, :secd) && length(arguments) == 1
        cosine = operator_interval(
            Val(head == :sec ? :cos : :cosd), arguments, original_arguments,
        )
        return _interval_reciprocal(cosine)
    elseif head in (:csc, :cscd) && length(arguments) == 1
        sine = operator_interval(
            Val(head == :csc ? :sin : :sind), arguments, original_arguments,
        )
        return _interval_reciprocal(sine)
    elseif head in (:cot, :cotd) && length(arguments) == 1
        cosine = operator_interval(
            Val(head == :cot ? :cos : :cosd), arguments, original_arguments,
        )
        sine = operator_interval(
            Val(head == :cot ? :sin : :sind), arguments, original_arguments,
        )
        return _interval_multiply(cosine, _interval_reciprocal(sine))
    elseif head in (:asec, :asecd) && length(arguments) == 1
        transform = head == :asec ? value -> acos(inv(value)) :
                                      value -> acosd(inv(value))
        return _inverse_reciprocal_trig_interval(
            only(arguments), transform; increasing = true,
        )
    elseif head in (:acsc, :acscd) && length(arguments) == 1
        transform = head == :acsc ? value -> asin(inv(value)) :
                                      value -> asind(inv(value))
        return _inverse_reciprocal_trig_interval(
            only(arguments), transform; increasing = false,
        )
    elseif head == :sech && length(arguments) == 1
        cosh_value = operator_interval(Val(:cosh), arguments, original_arguments)
        return _interval_reciprocal(cosh_value)
    elseif head == :csch && length(arguments) == 1
        sinh_value = operator_interval(Val(:sinh), arguments, original_arguments)
        return _interval_reciprocal(sinh_value)
    elseif head == :coth && length(arguments) == 1
        cosh_value = operator_interval(Val(:cosh), arguments, original_arguments)
        sinh_value = operator_interval(Val(:sinh), arguments, original_arguments)
        return _interval_multiply(cosh_value, _interval_reciprocal(sinh_value))
    elseif head == :asech && length(arguments) == 1
        return _inverse_reciprocal_hyperbolic_interval(
            only(arguments), value -> acosh(inv(value));
            lower_limit = 0.0,
            upper_limit = 1.0,
            lower_strict = true,
            upper_strict = false,
        )
    elseif head == :acsch && length(arguments) == 1
        value = only(arguments)
        value.valid || return _invalid_interval()
        (value.lower > 0.0 || value.upper < 0.0) || return _full_interval()
        return _inverse_reciprocal_hyperbolic_interval(
            value, item -> asinh(inv(item));
            lower_limit = -Inf,
            upper_limit = Inf,
            lower_strict = false,
            upper_strict = false,
        )
    elseif head == :acoth && length(arguments) == 1
        value = only(arguments)
        value.valid || return _invalid_interval()
        (value.lower > 1.0 || value.upper < -1.0) || return _full_interval()
        return _inverse_reciprocal_hyperbolic_interval(
            value, item -> atanh(inv(item));
            lower_limit = -Inf,
            upper_limit = Inf,
            lower_strict = false,
            upper_strict = false,
        )
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
    enclosure.certified || return DomainPossibleViolation
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
    enclosure.certified || return DomainPossibleViolation
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
    elseif head == :log1mexp
        push!(
            requirements,
            OperatorDomainRequirement(
                1,
                _upper_domain_assessment(
                    argument_intervals[1],
                    0.0;
                    strict = true,
                ),
                "argument < 0",
            ),
        )
    elseif head == :logdiffexp && length(argument_intervals) == 2
        difference = _interval_add(
            argument_intervals[1], _interval_scale(argument_intervals[2], -1.0),
        )
        assessment = _lower_domain_assessment(difference, 0.0; strict = true)
        for argument in 1:2
            push!(
                requirements,
                OperatorDomainRequirement(
                    argument,
                    assessment,
                    "first argument > second argument",
                ),
            )
        end
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
    elseif head in (:csch, :coth)
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
        return _certified_interval(_base_interval(value, variable_intervals))

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
        enclosure = _with_interval_certification(enclosure,
            enclosure.certified && all(item -> item.certified, argument_intervals))
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
    return _checked_operator_interval(operator, argument_intervals, value.args)
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
function _domain_issues(
    model::ModelSnapshot,
    variable_intervals,
)
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

function domain_issues(model::ModelSnapshot)
    return _domain_issues(model, _domain_variable_intervals(model))
end

domain_issues(model::MOI.ModelLike) = domain_issues(snapshot(model))

function _domain_issue_finding(
    issue::ExpressionDomainIssue,
    variable_records::Dict{MOI.VariableIndex,VariableRecord},
    interval_origins = nothing,
)
    proven = issue.assessment == DomainProvenViolation && issue.enclosure.certified
    affected = EntityRef[issue.path.source]
    for variable in issue.variables
        haskey(variable_records, variable) || continue
        push!(affected, _variable_ref(variable_records[variable]))
    end
    interval = "[$(issue.enclosure.lower), $(issue.enclosure.upper)]"
    path = _path_string(issue.path)
    support_origins = isnothing(interval_origins) ? "" : join(
        [
            "v$(variable.value)=$(_domain_interval_origin_summary(interval_origins, variable))" for
            variable in sort!(copy(issue.variables); by = variable -> variable.value)
        ],
        ";",
    )
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
                      issue.enclosure.certified ?
                      "Expression $path applies $(issue.operator) where the certified enclosure intersects values that violate $(issue.requirement)." :
                      "Expression $path applies $(issue.operator), but its argument range is uncertified; satisfaction of $(issue.requirement) is unknown.",
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
                    "interval_certified" => issue.enclosure.certified,
                    "assessment" => issue.assessment,
                    "support_interval_origins" => support_origins,
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
    variable_intervals, interval_origins = _domain_variable_interval_state(model; certified_only = true)
    issues = _domain_issues(model, variable_intervals)
    report = DiagnosticReport()
    report.metadata[:interval_policy] = "certified_propagation_only"
    report.metadata[:uncertified_domain_issue_count] = string(count(issue -> !issue.enclosure.certified, issues))
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
        push!(report, _domain_issue_finding(issue, records, interval_origins))
    end
    return report
end

analyze_domains(model::MOI.ModelLike) = analyze_domains(snapshot(model))
