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
public MOI function. Nonlinear support is syntactic: no algebraic cancellation
is attempted.

Packages defining custom `MOI.AbstractFunction` types may extend this function.
The fallback is deliberately incomplete rather than assuming an unknown
function contains no variables.
"""
variable_support(value::Real) = VariableSupport()

variable_support(value::MOI.VariableIndex) =
    VariableSupport(MOI.VariableIndex[value])

function variable_support(value::MOI.ScalarAffineFunction)
    variables = MOI.VariableIndex[
        term.variable for term in value.terms if !iszero(term.coefficient)
    ]
    return VariableSupport(variables)
end

function variable_support(value::MOI.ScalarQuadraticFunction)
    variables = MOI.VariableIndex[
        term.variable for
        term in value.affine_terms if !iszero(term.coefficient)
    ]
    for term in value.quadratic_terms
        iszero(term.coefficient) && continue
        push!(variables, term.variable_1)
        push!(variables, term.variable_2)
    end
    return VariableSupport(variables)
end

function variable_support(value::MOI.ScalarNonlinearFunction)
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
