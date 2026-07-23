@enum VariableRole::UInt8 begin
    FreeVariable = 0
    FixedVariable = 1
    ParameterVariable = 2
    InfeasibleVariableDomain = 3
end

@enum ConstraintRole::UInt8 begin
    EqualityConstraint = 0
    InequalityConstraint = 1
    FreeConstraint = 2
    CoupledConstraint = 3
    OpaqueConstraint = 4
end

function _simple_variable_intervals(model::ModelSnapshot)
    lower = Dict(record.index => -Inf for record in model.variables)
    upper = Dict(record.index => Inf for record in model.variables)
    parameters = Set{MOI.VariableIndex}()
    for constraint in model.constraints
        variable = constraint.function_value
        variable isa MOI.VariableIndex || continue
        set_value = constraint.set_value
        if set_value isa MOI.Parameter
            push!(parameters, variable)
            lower[variable] = max(lower[variable], Float64(set_value.value))
            upper[variable] = min(upper[variable], Float64(set_value.value))
        elseif set_value isa MOI.EqualTo
            value = Float64(set_value.value)
            lower[variable] = max(lower[variable], value)
            upper[variable] = min(upper[variable], value)
        elseif set_value isa MOI.Interval
            lower[variable] = max(lower[variable], Float64(set_value.lower))
            upper[variable] = min(upper[variable], Float64(set_value.upper))
        elseif set_value isa MOI.GreaterThan
            lower[variable] = max(lower[variable], Float64(set_value.lower))
        elseif set_value isa MOI.LessThan
            upper[variable] = min(upper[variable], Float64(set_value.upper))
        end
    end
    return lower, upper, parameters
end

"""
    variable_roles(snapshot::ModelSnapshot)

Classify variables for structural equation analysis. A variable fixed by the
intersection of simple scalar bounds is not treated as a structural unknown.
"""
function variable_roles(model::ModelSnapshot)
    lower, upper, parameters = _simple_variable_intervals(model)
    roles = VariableRole[]
    for record in model.variables
        variable = record.index
        role = if variable in parameters
            ParameterVariable
        elseif lower[variable] > upper[variable]
            InfeasibleVariableDomain
        elseif isfinite(lower[variable]) && lower[variable] == upper[variable]
            FixedVariable
        else
            FreeVariable
        end
        push!(roles, role)
    end
    return roles
end

variable_roles(model::MOI.ModelLike) = variable_roles(snapshot(model))

"""
    constraint_role(set_value; row = nothing) -> ConstraintRole

Classify a constraint node for structural equation matching. Packages defining
custom MOI sets may extend this function.
"""
function constraint_role(
    set_value;
    row::Union{Nothing,Int} = nothing,
)
    set_value isa MOI.EqualTo && return EqualityConstraint
    if set_value isa MOI.Interval
        return set_value.lower == set_value.upper ?
               EqualityConstraint :
               InequalityConstraint
    end
    if set_value isa MOI.LessThan || set_value isa MOI.GreaterThan
        return InequalityConstraint
    end
    set_value isa MOI.Zeros && return EqualityConstraint
    if set_value isa MOI.Nonnegatives || set_value isa MOI.Nonpositives
        return InequalityConstraint
    end
    set_value isa MOI.Reals && return FreeConstraint
    if set_value isa MOI.HyperRectangle
        isnothing(row) && return OpaqueConstraint
        return set_value.lower[row] == set_value.upper[row] ?
               EqualityConstraint :
               InequalityConstraint
    end
    set_value isa MOI.AbstractVectorSet && return CoupledConstraint
    return OpaqueConstraint
end
