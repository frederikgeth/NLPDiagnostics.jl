@enum VariableRole::UInt8 begin
    FreeVariable = 0
    FixedVariable = 1
    ParameterVariable = 2
    InfeasibleVariableDomain = 3
    InvalidVariableDomain = 4
    DiscreteVariable = 5
end

@enum ConstraintRole::UInt8 begin
    EqualityConstraint = 0
    InequalityConstraint = 1
    FreeConstraint = 2
    CoupledConstraint = 3
    OpaqueConstraint = 4
end

"""Intersection of supported scalar variable-domain declarations."""
struct VariableDomain
    variable::MOI.VariableIndex
    lower::Union{Nothing,Real}
    upper::Union{Nothing,Real}
    lower_sources::Vector{EntityRef}
    upper_sources::Vector{EntityRef}
    effective_lower_sources::Vector{EntityRef}
    effective_upper_sources::Vector{EntityRef}
    is_parameter::Bool
end

function variable_domains(model::ModelSnapshot)
    lower = Dict(record.index => Tuple{Real,EntityRef}[] for record in model.variables)
    upper = Dict(record.index => Tuple{Real,EntityRef}[] for record in model.variables)
    parameters = Set{MOI.VariableIndex}()
    for constraint in model.constraints
        variable = constraint.function_value
        variable isa MOI.VariableIndex || continue
        set_value = constraint.set_value
        if set_value isa MOI.Parameter
            push!(parameters, variable)
            value = set_value.value
            push!(lower[variable], (value, _constraint_ref(constraint)))
            push!(upper[variable], (value, _constraint_ref(constraint)))
        elseif set_value isa MOI.EqualTo
            value = set_value.value
            push!(lower[variable], (value, _constraint_ref(constraint)))
            push!(upper[variable], (value, _constraint_ref(constraint)))
        elseif set_value isa MOI.Interval
            push!(lower[variable], (set_value.lower, _constraint_ref(constraint)))
            push!(upper[variable], (set_value.upper, _constraint_ref(constraint)))
        elseif set_value isa MOI.GreaterThan
            push!(lower[variable], (set_value.lower, _constraint_ref(constraint)))
        elseif set_value isa MOI.LessThan
            push!(upper[variable], (set_value.upper, _constraint_ref(constraint)))
        elseif set_value isa MOI.ZeroOne
            reference = _constraint_ref(constraint)
            push!(lower[variable], (0.0, reference))
            push!(upper[variable], (1.0, reference))
        end
    end
    return [begin
        lower_entries, upper_entries = lower[record.index], upper[record.index]
        effective_lower = isempty(lower_entries) ? nothing : maximum(first, lower_entries)
        effective_upper = isempty(upper_entries) ? nothing : minimum(first, upper_entries)
        VariableDomain(
            record.index, effective_lower, effective_upper,
            EntityRef[last(item) for item in lower_entries],
            EntityRef[last(item) for item in upper_entries],
            isnothing(effective_lower) ? EntityRef[] :
                EntityRef[last(item) for item in lower_entries if first(item) == effective_lower],
            isnothing(effective_upper) ? EntityRef[] :
                EntityRef[last(item) for item in upper_entries if first(item) == effective_upper],
            record.index in parameters,
        )
    end for record in model.variables]
end

variable_domains(model::MOI.ModelLike) = variable_domains(snapshot(model))

"""
    variable_roles(snapshot::ModelSnapshot)

Classify variables for structural equation analysis. A variable fixed by the
intersection of simple scalar bounds is not treated as a structural unknown.
"""
function variable_roles(model::ModelSnapshot)
    discrete_variables = Set{MOI.VariableIndex}(
        constraint.function_value for constraint in model.constraints if
        constraint.function_value isa MOI.VariableIndex &&
        constraint.set_value isa Union{MOI.Integer,MOI.ZeroOne}
    )
    roles = VariableRole[]
    for domain in variable_domains(model)
        has_nan = (!isnothing(domain.lower) && domain.lower isa AbstractFloat && isnan(domain.lower)) ||
                  (!isnothing(domain.upper) && domain.upper isa AbstractFloat && isnan(domain.upper))
        role = if has_nan
            InvalidVariableDomain
        elseif !isnothing(domain.lower) && !isnothing(domain.upper) &&
               domain.lower > domain.upper
            InfeasibleVariableDomain
        elseif domain.is_parameter
            ParameterVariable
        elseif !isnothing(domain.lower) && !isnothing(domain.upper) &&
               domain.lower == domain.upper
            FixedVariable
        elseif domain.variable in discrete_variables
            DiscreteVariable
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
