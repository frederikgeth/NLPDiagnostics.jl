struct ConstraintNodeRecord
    constraint::ConstraintRecord
    row::Union{Nothing,Int}
    function_value::Any
    role::ConstraintRole
end

"""
The set-aware variable–constraint bipartite graph of a model snapshot.

Variable domain constraints such as bounds and integrality are excluded.
Vector-valued constraints in coordinate-wise product sets contribute one
vertex per scalar row. Constraints in coupled vector sets contribute one block
vertex so set semantics cannot create false separability.
"""
struct IncidenceGraph
    variables::Vector{VariableRecord}
    variable_roles::Vector{VariableRole}
    constraint_nodes::Vector{ConstraintNodeRecord}
    variable_to_constraints::Vector{Vector{Int}}
    constraint_to_variables::Vector{Vector{Int}}
    complete::Bool
    unsupported_types::Vector{String}
end

"""
A connected component of an `IncidenceGraph`.

The integer positions index `graph.variables` and `graph.constraint_nodes`.
"""
struct StructuralComponent
    variable_positions::Vector{Int}
    constraint_positions::Vector{Int}
end

_is_variable_domain_constraint(constraint::ConstraintRecord) =
    constraint.function_value isa MOI.VariableIndex

"""
    is_coordinatewise_set(set_value) -> Bool

Return whether a vector set is a Cartesian product that can be represented by
independent scalar constraint nodes. Custom MOI sets may extend this function.
The conservative fallback is `false`.
"""
is_coordinatewise_set(set_value) = false
is_coordinatewise_set(set_value::MOI.Zeros) = true
is_coordinatewise_set(set_value::MOI.Nonnegatives) = true
is_coordinatewise_set(set_value::MOI.Nonpositives) = true
is_coordinatewise_set(set_value::MOI.Reals) = true
is_coordinatewise_set(set_value::MOI.HyperRectangle) = true

function _constraint_scalar_rows(constraint::ConstraintRecord)
    function_value = constraint.function_value
    if !(function_value isa MOI.AbstractVectorFunction)
        return Tuple{Union{Nothing,Int},Any}[(nothing, function_value)], String[]
    end
    if !is_coordinatewise_set(constraint.set_value)
        return Tuple{Union{Nothing,Int},Any}[(nothing, function_value)], String[]
    end
    try
        rows = Tuple{Union{Nothing,Int},Any}[
            (row, scalar_function) for
            (row, scalar_function) in
            enumerate(MOI.Utilities.scalarize(function_value))
        ]
        return rows, String[]
    catch
        return (
            Tuple{Union{Nothing,Int},Any}[(nothing, function_value)],
            [string(typeof(function_value))],
        )
    end
end

"""
    incidence_graph(snapshot::ModelSnapshot) -> IncidenceGraph

Build the structural Jacobian pattern without evaluating model functions.
"""
function incidence_graph(model::ModelSnapshot)
    variable_positions = Dict(
        record.index => position for
        (position, record) in enumerate(model.variables)
    )
    constraint_nodes = ConstraintNodeRecord[]
    row_supports = VariableSupport[]
    unsupported_types = String[]
    complete = true

    for constraint in model.constraints
        _is_variable_domain_constraint(constraint) && continue
        scalar_rows, unsupported = _constraint_scalar_rows(constraint)
        append!(unsupported_types, unsupported)
        complete &= isempty(unsupported)
        for (row, function_value) in scalar_rows
            support = variable_support(function_value)
            push!(
                constraint_nodes,
                ConstraintNodeRecord(
                    constraint,
                    row,
                    function_value,
                    constraint_role(constraint.set_value; row = row),
                ),
            )
            push!(row_supports, support)
            complete &= support.complete
            append!(unsupported_types, support.unsupported_types)
        end
    end

    variable_to_constraints = [Int[] for _ in model.variables]
    constraint_to_variables = [Int[] for _ in constraint_nodes]
    for (constraint_position, support) in enumerate(row_supports)
        for variable in support.variables
            variable_position = get(variable_positions, variable, 0)
            if iszero(variable_position)
                complete = false
                push!(
                    unsupported_types,
                    "unlisted MathOptInterface.VariableIndex($(variable.value))",
                )
                continue
            end
            push!(
                variable_to_constraints[variable_position],
                constraint_position,
            )
            push!(
                constraint_to_variables[constraint_position],
                variable_position,
            )
        end
    end

    return IncidenceGraph(
        copy(model.variables),
        variable_roles(model),
        constraint_nodes,
        variable_to_constraints,
        constraint_to_variables,
        complete,
        sort!(unique!(unsupported_types)),
    )
end

incidence_graph(model::MOI.ModelLike) = incidence_graph(snapshot(model))

function _component_from!(
    graph::IncidenceGraph,
    start_is_variable::Bool,
    start_position::Int,
    visited_variables::BitVector,
    visited_constraints::BitVector,
)
    queue = Tuple{Bool,Int}[(start_is_variable, start_position)]
    if start_is_variable
        visited_variables[start_position] = true
    else
        visited_constraints[start_position] = true
    end
    variable_positions = Int[]
    constraint_positions = Int[]
    cursor = 1
    while cursor <= length(queue)
        is_variable, position = queue[cursor]
        cursor += 1
        if is_variable
            push!(variable_positions, position)
            for constraint_position in graph.variable_to_constraints[position]
                visited_constraints[constraint_position] && continue
                visited_constraints[constraint_position] = true
                push!(queue, (false, constraint_position))
            end
        else
            push!(constraint_positions, position)
            for variable_position in graph.constraint_to_variables[position]
                visited_variables[variable_position] && continue
                visited_variables[variable_position] = true
                push!(queue, (true, variable_position))
            end
        end
    end
    sort!(variable_positions)
    sort!(constraint_positions)
    return StructuralComponent(variable_positions, constraint_positions)
end

"""
    connected_components(graph::IncidenceGraph)

Return all bipartite connected components, including isolated variables and
constant constraint nodes.
"""
function connected_components(graph::IncidenceGraph)
    visited_variables = falses(length(graph.variables))
    visited_constraints = falses(length(graph.constraint_nodes))
    components = StructuralComponent[]

    for position in eachindex(graph.variables)
        visited_variables[position] && continue
        push!(
            components,
            _component_from!(
                graph,
                true,
                position,
                visited_variables,
                visited_constraints,
            ),
        )
    end
    for position in eachindex(graph.constraint_nodes)
        visited_constraints[position] && continue
        push!(
            components,
            _component_from!(
                graph,
                false,
                position,
                visited_variables,
                visited_constraints,
            ),
        )
    end
    return components
end
