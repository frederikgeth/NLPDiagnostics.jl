# The snapshot owns copied public model data and never mutates the source model.
struct VariableRecord
    index::MOI.VariableIndex
    name::Union{Nothing,String}
end

struct ConstraintRecord
    index::Any
    function_value::Any
    set_value::Any
    name::Union{Nothing,String}
end

struct ObjectiveRecord
    sense::MOI.OptimizationSense
    function_value::Any
end

"""
An immutable diagnostic view of the public MOI model data.

The snapshot prevents analyses from silently modifying the user's model and
provides one ingestion boundary for JuMP models, MOI caches, and optimizers.
"""
struct ModelSnapshot
    variables::Vector{VariableRecord}
    constraints::Vector{ConstraintRecord}
    objective::Union{Nothing,ObjectiveRecord}
    model_name::Union{Nothing,String}
    opaque_sources::Vector{String}
end

function _optional_get(model, attribute)
    try
        value = MOI.get(model, attribute)
        return isempty(value) ? nothing : String(value)
    catch
        return nothing
    end
end

function snapshot(model::MOI.ModelLike)
    nlp_block = try
        MOI.get(model, MOI.NLPBlock())
    catch
        nothing
    end
    opaque_sources = isnothing(nlp_block) ?
                     String[] :
                     ["MOI.NLPBlockData{$(typeof(nlp_block.evaluator))}"]
    variables = VariableRecord[]
    for variable in MOI.get(model, MOI.ListOfVariableIndices())
        name = _optional_get(model, MOI.VariableName(), variable)
        push!(variables, VariableRecord(variable, name))
    end

    constraints = ConstraintRecord[]
    for (F, S) in MOI.get(model, MOI.ListOfConstraintTypesPresent())
        attribute = MOI.ListOfConstraintIndices{F,S}()
        for index in MOI.get(model, attribute)
            function_value = deepcopy(MOI.get(model, MOI.ConstraintFunction(), index))
            set_value = deepcopy(MOI.get(model, MOI.ConstraintSet(), index))
            name = _optional_get(model, MOI.ConstraintName(), index)
            push!(
                constraints,
                ConstraintRecord(index, function_value, set_value, name),
            )
        end
    end

    sense = MOI.get(model, MOI.ObjectiveSense())
    objective = if sense == MOI.FEASIBILITY_SENSE ||
                   (!isnothing(nlp_block) && nlp_block.has_objective)
        nothing
    else
        # An NLPBlock objective overrides the ordinary objective and some
        # imported callback models do not store an ordinary objective at all.
        # Keep the symbolic snapshot optional; the numerical adapter reads the
        # NLPBlock separately from the source model.
        try
            F = MOI.get(model, MOI.ObjectiveFunctionType())
            function_value =
                deepcopy(MOI.get(model, MOI.ObjectiveFunction{F}()))
            ObjectiveRecord(sense, function_value)
        catch exception
            push!(
                opaque_sources,
                "MOI.ObjectiveFunction(unavailable: $(typeof(exception)))",
            )
            nothing
        end
    end

    model_name = _optional_get(model, MOI.Name())
    return ModelSnapshot(
        variables,
        constraints,
        objective,
        model_name,
        opaque_sources,
    )
end

function _optional_get(model, attribute, index)
    try
        value = MOI.get(model, attribute, index)
        return isempty(value) ? nothing : String(value)
    catch
        return nothing
    end
end

_variable_ref(record::VariableRecord) =
    EntityRef(:variable, record.index.value; name = record.name)

function _constraint_ref(
    record::ConstraintRecord;
    row::Union{Nothing,Integer} = nothing,
)
    return EntityRef(
        :constraint,
        record.index.value;
        subindex = row,
        name = record.name,
        function_type = string(typeof(record.function_value)),
        set_type = string(typeof(record.set_value)),
    )
end
