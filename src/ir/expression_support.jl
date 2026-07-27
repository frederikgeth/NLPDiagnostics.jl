"""
    VariableSupport

The decision-variable support extracted from an MOI function.

`complete == false` means at least one expression node had no registered
extractor. Analyses must not interpret the returned variables as the complete
support in that case.
"""
struct VariableSupport
    variables::Vector{MOI.VariableIndex}
    complete::Bool
    unsupported_types::Vector{String}
end

function VariableSupport(
    variables = MOI.VariableIndex[];
    complete::Bool = true,
    unsupported_types::AbstractVector{<:AbstractString} = String[],
)
    normalized_variables = sort!(unique!(collect(variables)); by = x -> x.value)
    normalized_types = sort!(unique!(String.(unsupported_types)))
    return VariableSupport(normalized_variables, complete, normalized_types)
end

function _merge_supports(supports)
    variables = MOI.VariableIndex[]
    unsupported_types = String[]
    complete = true
    for support in supports
        append!(variables, support.variables)
        append!(unsupported_types, support.unsupported_types)
        complete &= support.complete
    end
    return VariableSupport(
        variables;
        complete = complete,
        unsupported_types = unsupported_types,
    )
end

"""
    variable_support(function_value) -> VariableSupport

Return the variables that occur with structurally nonzero coefficients in a
public MOI function. Affine and quadratic terms are first combined exactly by
their MOI variable monomial, so duplicate terms that cancel do not create
spurious incidence. Nonlinear support remains syntactic: no algebraic
cancellation is attempted.

Packages defining custom `MOI.AbstractFunction` types may extend this function.
The fallback is deliberately incomplete rather than assuming an unknown
function contains no variables.
"""
variable_support(value::Real) = VariableSupport()

variable_support(value::MOI.VariableIndex) =
    VariableSupport(MOI.VariableIndex[value])

"""Combine duplicate affine terms and remove exact zero coefficients."""
function _canonical_affine_terms(terms)
    coefficients = Dict{MOI.VariableIndex,Any}()
    for term in terms
        coefficients[term.variable] = get(
            coefficients,
            term.variable,
            zero(term.coefficient),
        ) + term.coefficient
    end
    return sort!(
        filter(term -> !iszero(last(term)), collect(coefficients));
        by = term -> first(term).value,
    )
end

"""Combine duplicate symmetric quadratic monomials and remove exact zeros."""
function _canonical_quadratic_terms(terms)
    coefficients = Dict{Tuple{MOI.VariableIndex,MOI.VariableIndex},Any}()
    for term in terms
        key = term.variable_1.value <= term.variable_2.value ?
              (term.variable_1, term.variable_2) :
              (term.variable_2, term.variable_1)
        coefficients[key] = get(coefficients, key, zero(term.coefficient)) +
                            term.coefficient
    end
    return sort!(
        filter(term -> !iszero(last(term)), collect(coefficients));
        by = term -> (first(term)[1].value, first(term)[2].value),
    )
end

function variable_support(value::MOI.ScalarAffineFunction)
    variables = MOI.VariableIndex[first(term) for term in _canonical_affine_terms(value.terms)]
    return VariableSupport(variables)
end

function variable_support(value::MOI.ScalarQuadraticFunction)
    variables = MOI.VariableIndex[first(term) for term in _canonical_affine_terms(value.affine_terms)]
    for (variables_in_term, _) in _canonical_quadratic_terms(value.quadratic_terms)
        push!(variables, variables_in_term[1])
        push!(variables, variables_in_term[2])
    end
    return VariableSupport(variables)
end

"""Whether a nonlinear node is the safe direct variable identity ``x - x``."""
function _is_direct_variable_cancellation(value::MOI.ScalarNonlinearFunction)
    value.head == :- && length(value.args) == 2 || return false
    left, right = value.args
    return left isa MOI.VariableIndex && left == right
end

"""Whether a product is safely zero without suppressing a nested operator."""
function _is_direct_zero_product(value::MOI.ScalarNonlinearFunction)
    value.head == :* || return false
    all(argument -> argument isa Union{Real,MOI.VariableIndex}, value.args) ||
        return false
    return any(argument -> argument isa Real && iszero(argument), value.args)
end

function variable_support(value::MOI.ScalarNonlinearFunction)
    (_is_direct_variable_cancellation(value) || _is_direct_zero_product(value)) &&
        return VariableSupport()
    return _merge_supports(variable_support(argument) for argument in value.args)
end

function variable_support(value::MOI.AbstractVectorFunction)
    scalar_functions = try
        MOI.Utilities.scalarize(value)
    catch
        return VariableSupport(
            ;
            complete = false,
            unsupported_types = [string(typeof(value))],
        )
    end
    return _merge_supports(variable_support(row) for row in scalar_functions)
end

function variable_support(value)
    return VariableSupport(
        ;
        complete = false,
        unsupported_types = [string(typeof(value))],
    )
end
