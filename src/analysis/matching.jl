"""
A deterministic maximum-cardinality matching on the structural equality graph.

Match arrays use incidence-graph positions and contain `0` for unmatched or
ineligible vertices.
"""
struct StructuralMatching
    variable_match::Vector{Int}
    constraint_match::Vector{Int}
    eligible_variable_positions::Vector{Int}
    eligible_constraint_positions::Vector{Int}
    complete::Bool
end

function _augment_constraint!(
    graph::IncidenceGraph,
    constraint_position::Int,
    eligible_variables::BitVector,
    variable_match::Vector{Int},
    constraint_match::Vector{Int},
    seen_variables::BitVector,
)
    for variable_position in
        graph.constraint_to_variables[constraint_position]
        eligible_variables[variable_position] || continue
        seen_variables[variable_position] && continue
        seen_variables[variable_position] = true
        previous_constraint = variable_match[variable_position]
        if iszero(previous_constraint) ||
           _augment_constraint!(
            graph,
            previous_constraint,
            eligible_variables,
            variable_match,
            constraint_match,
            seen_variables,
        )
            variable_match[variable_position] = constraint_position
            constraint_match[constraint_position] = variable_position
            return true
        end
    end
    return false
end

"""
    maximum_matching(graph::IncidenceGraph) -> StructuralMatching

Match free variables to equality constraint nodes. Other roles are excluded
from the default structural-equation view.
"""
function maximum_matching(graph::IncidenceGraph)
    eligible_variable_positions = findall(==(FreeVariable), graph.variable_roles)
    eligible_constraint_positions = findall(
        ==(EqualityConstraint),
        [node.role for node in graph.constraint_nodes],
    )
    variable_match = zeros(Int, length(graph.variables))
    constraint_match = zeros(Int, length(graph.constraint_nodes))
    graph.complete ||
        return StructuralMatching(
            variable_match,
            constraint_match,
            eligible_variable_positions,
            eligible_constraint_positions,
            false,
        )

    eligible_variables = falses(length(graph.variables))
    eligible_variables[eligible_variable_positions] .= true
    for constraint_position in eligible_constraint_positions
        seen_variables = falses(length(graph.variables))
        _augment_constraint!(
            graph,
            constraint_position,
            eligible_variables,
            variable_match,
            constraint_match,
            seen_variables,
        )
    end
    return StructuralMatching(
        variable_match,
        constraint_match,
        eligible_variable_positions,
        eligible_constraint_positions,
        true,
    )
end

maximum_matching(model::MOI.ModelLike) =
    maximum_matching(incidence_graph(model))

matching_cardinality(matching::StructuralMatching) =
    count(!iszero, matching.constraint_match)

"""
The three-way Dulmage–Mendelsohn partition of the eligible equality graph.

Positions refer to the source `IncidenceGraph`. Inequalities, fixed variables,
parameters, and non-equality constraint nodes do not appear in the partition.
"""
struct DulmageMendelsohnPartition
    underdetermined_variables::Vector{Int}
    underdetermined_constraints::Vector{Int}
    well_determined_variables::Vector{Int}
    well_determined_constraints::Vector{Int}
    overdetermined_variables::Vector{Int}
    overdetermined_constraints::Vector{Int}
    matching::StructuralMatching
    complete::Bool
end

function _alternating_reachability(
    graph::IncidenceGraph,
    matching::StructuralMatching,
    start_variables::Vector{Int},
    start_constraints::Vector{Int},
    direction::Symbol,
)
    eligible_variables = falses(length(graph.variables))
    eligible_constraints = falses(length(graph.constraint_nodes))
    eligible_variables[matching.eligible_variable_positions] .= true
    eligible_constraints[matching.eligible_constraint_positions] .= true
    reached_variables = falses(length(graph.variables))
    reached_constraints = falses(length(graph.constraint_nodes))
    queue = Tuple{Bool,Int}[]
    for position in start_variables
        reached_variables[position] = true
        push!(queue, (true, position))
    end
    for position in start_constraints
        reached_constraints[position] = true
        push!(queue, (false, position))
    end

    cursor = 1
    while cursor <= length(queue)
        is_variable, position = queue[cursor]
        cursor += 1
        if direction == :from_unmatched_variables
            if is_variable
                for constraint_position in graph.variable_to_constraints[position]
                    eligible_constraints[constraint_position] || continue
                    matching.variable_match[position] == constraint_position &&
                        continue
                    reached_constraints[constraint_position] && continue
                    reached_constraints[constraint_position] = true
                    push!(queue, (false, constraint_position))
                end
            else
                variable_position = matching.constraint_match[position]
                iszero(variable_position) && continue
                reached_variables[variable_position] && continue
                reached_variables[variable_position] = true
                push!(queue, (true, variable_position))
            end
        else
            if is_variable
                constraint_position = matching.variable_match[position]
                iszero(constraint_position) && continue
                reached_constraints[constraint_position] && continue
                reached_constraints[constraint_position] = true
                push!(queue, (false, constraint_position))
            else
                for variable_position in graph.constraint_to_variables[position]
                    eligible_variables[variable_position] || continue
                    matching.constraint_match[position] == variable_position &&
                        continue
                    reached_variables[variable_position] && continue
                    reached_variables[variable_position] = true
                    push!(queue, (true, variable_position))
                end
            end
        end
    end
    return findall(reached_variables), findall(reached_constraints)
end

"""
    dulmage_mendelsohn(graph; matching = maximum_matching(graph))

Compute the under-, well-, and over-determined partitions induced by a maximum
matching of free variables and equality rows.
"""
function dulmage_mendelsohn(
    graph::IncidenceGraph;
    matching::StructuralMatching = maximum_matching(graph),
)
    empty_partition = DulmageMendelsohnPartition(
        Int[],
        Int[],
        Int[],
        Int[],
        Int[],
        Int[],
        matching,
        false,
    )
    matching.complete || return empty_partition

    unmatched_variables = Int[
        position for position in matching.eligible_variable_positions if
        iszero(matching.variable_match[position])
    ]
    unmatched_constraints = Int[
        position for position in matching.eligible_constraint_positions if
        iszero(matching.constraint_match[position])
    ]
    under_variables, under_constraints = _alternating_reachability(
        graph,
        matching,
        unmatched_variables,
        Int[],
        :from_unmatched_variables,
    )
    over_variables, over_constraints = _alternating_reachability(
        graph,
        matching,
        Int[],
        unmatched_constraints,
        :from_unmatched_constraints,
    )
    under_variable_set = Set(under_variables)
    under_constraint_set = Set(under_constraints)
    over_variable_set = Set(over_variables)
    over_constraint_set = Set(over_constraints)
    well_variables = Int[
        position for position in matching.eligible_variable_positions if
        position ∉ under_variable_set && position ∉ over_variable_set
    ]
    well_constraints = Int[
        position for position in matching.eligible_constraint_positions if
        position ∉ under_constraint_set && position ∉ over_constraint_set
    ]
    return DulmageMendelsohnPartition(
        under_variables,
        under_constraints,
        well_variables,
        well_constraints,
        over_variables,
        over_constraints,
        matching,
        true,
    )
end

dulmage_mendelsohn(model::MOI.ModelLike) =
    dulmage_mendelsohn(incidence_graph(model))
