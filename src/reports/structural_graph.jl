struct StructuralVariableNode
    position::Int
    model_index::Int
    name::Union{Nothing,String}
    role::VariableRole
    dm_region::Symbol
    block::Union{Nothing,Int}
end

struct StructuralConstraintNode
    position::Int
    model_index::Int
    row::Union{Nothing,Int}
    name::Union{Nothing,String}
    role::ConstraintRole
    dm_region::Symbol
    block::Union{Nothing,Int}
    function_type::String
    set_type::String
end

struct StructuralGraphEdge
    variable_position::Int
    constraint_position::Int
    matched::Bool
end

"""
A stable, renderer-neutral export of structural graph data.

Positions are local to the export and correspond to the source
`IncidenceGraph`. MOI constraint indices are retained as metadata because they
are not globally unique across function/set types.
"""
struct StructuralGraphData
    variables::Vector{StructuralVariableNode}
    constraints::Vector{StructuralConstraintNode}
    edges::Vector{StructuralGraphEdge}
    complete::Bool
end

function _dm_region_maps(
    graph::IncidenceGraph,
    partition::DulmageMendelsohnPartition,
)
    variable_regions = fill(:excluded, length(graph.variables))
    constraint_regions = fill(:excluded, length(graph.constraint_nodes))
    if !partition.complete
        variable_regions[partition.matching.eligible_variable_positions] .=
            :unknown
        constraint_regions[
            partition.matching.eligible_constraint_positions
        ] .= :unknown
        return variable_regions, constraint_regions
    end
    variable_regions[partition.underdetermined_variables] .= :under
    variable_regions[partition.well_determined_variables] .= :well
    variable_regions[partition.overdetermined_variables] .= :over
    constraint_regions[partition.underdetermined_constraints] .= :under
    constraint_regions[partition.well_determined_constraints] .= :well
    constraint_regions[partition.overdetermined_constraints] .= :over
    return variable_regions, constraint_regions
end

"""
    structural_graph_data(graph::IncidenceGraph) -> StructuralGraphData

Annotate incidence nodes and edges with structural roles, matching state, DM
regions, and well-determined block numbers.
"""
function structural_graph_data(
    graph::IncidenceGraph;
    matching::StructuralMatching = maximum_matching(graph),
    partition::DulmageMendelsohnPartition = dulmage_mendelsohn(
        graph;
        matching = matching,
    ),
    blocks::Vector{DulmageMendelsohnBlock} = well_determined_blocks(
        graph;
        partition = partition,
    ),
)
    variable_regions, constraint_regions =
        _dm_region_maps(graph, partition)
    variable_blocks = Dict{Int,Int}()
    constraint_blocks = Dict{Int,Int}()
    for (block_number, block) in enumerate(blocks)
        for position in block.variable_positions
            variable_blocks[position] = block_number
        end
        for position in block.constraint_positions
            constraint_blocks[position] = block_number
        end
    end

    variables = StructuralVariableNode[]
    for (position, record) in enumerate(graph.variables)
        push!(
            variables,
            StructuralVariableNode(
                position,
                record.index.value,
                record.name,
                graph.variable_roles[position],
                variable_regions[position],
                get(variable_blocks, position, nothing),
            ),
        )
    end
    constraints = StructuralConstraintNode[]
    for (position, node) in enumerate(graph.constraint_nodes)
        push!(
            constraints,
            StructuralConstraintNode(
                position,
                node.constraint.index.value,
                node.row,
                node.constraint.name,
                node.role,
                constraint_regions[position],
                get(constraint_blocks, position, nothing),
                string(typeof(node.constraint.function_value)),
                string(typeof(node.constraint.set_value)),
            ),
        )
    end
    edges = StructuralGraphEdge[]
    for (constraint_position, variable_positions) in
        enumerate(graph.constraint_to_variables)
        for variable_position in variable_positions
            push!(
                edges,
                StructuralGraphEdge(
                    variable_position,
                    constraint_position,
                    matching.complete &&
                    matching.variable_match[variable_position] ==
                    constraint_position,
                ),
            )
        end
    end
    sort!(
        edges;
        by = edge -> (
            edge.variable_position,
            edge.constraint_position,
        ),
    )
    return StructuralGraphData(
        variables,
        constraints,
        edges,
        graph.complete && matching.complete && partition.complete,
    )
end

structural_graph_data(model::MOI.ModelLike) =
    structural_graph_data(incidence_graph(model))

_export_variable_label(node::StructuralVariableNode) =
    isnothing(node.name) ? "v$(node.model_index)" : node.name

function _export_constraint_label(node::StructuralConstraintNode)
    base = isnothing(node.name) ? "c$(node.model_index)" : node.name
    return isnothing(node.row) ? base : "$base[$(node.row)]"
end

function _block_label(block::Union{Nothing,Int})
    return isnothing(block) ? "-" : string(block)
end

function Base.show(
    io::IO,
    ::MIME"text/plain",
    data::StructuralGraphData,
)
    println(
        io,
        "Structural graph with $(length(data.variables)) variables, ",
        "$(length(data.constraints)) constraint nodes, and ",
        "$(length(data.edges)) edges (complete=$(data.complete))",
    )
    println(io, "Variables:")
    for node in data.variables
        println(
            io,
            "  v$(node.position) ",
            _export_variable_label(node),
            " [role=$(node.role), dm=$(node.dm_region), block=$(_block_label(node.block))]",
        )
    end
    println(io, "Constraints:")
    for node in data.constraints
        println(
            io,
            "  c$(node.position) ",
            _export_constraint_label(node),
            " [role=$(node.role), dm=$(node.dm_region), block=$(_block_label(node.block))]",
        )
    end
    println(io, "Edges:")
    for edge in data.edges
        println(
            io,
            "  v$(edge.variable_position) -- c$(edge.constraint_position)",
            edge.matched ? " [matched]" : "",
        )
    end
    return
end

structural_graph_text(data::StructuralGraphData) =
    sprint(show, MIME"text/plain"(), data)

structural_graph_text(graph::IncidenceGraph) =
    structural_graph_text(structural_graph_data(graph))

structural_graph_text(model::MOI.ModelLike) =
    structural_graph_text(incidence_graph(model))

function _dot_escape(value)
    return replace(
        string(value),
        "\\" => "\\\\",
        "\"" => "\\\"",
        "\n" => "\\n",
    )
end

function _dm_fill(region::Symbol)
    region == :under && return "#fff2b2"
    region == :well && return "#d9f2d9"
    region == :over && return "#ffd6d6"
    region == :unknown && return "#e6d9ff"
    return "#eeeeee"
end

"""
    structural_graph_dot(data::StructuralGraphData) -> String

Render Graphviz DOT without invoking Graphviz or writing a file.
"""
function structural_graph_dot(data::StructuralGraphData)
    io = IOBuffer()
    println(io, "graph NLPDiagnostics {")
    println(io, "  rankdir=LR;")
    println(io, "  graph [label=\"NLPDiagnostics structural graph\", labelloc=t];")
    println(io, "  node [style=filled, fontname=\"Helvetica\"];")
    for node in data.variables
        label = _dot_escape(
            "$(_export_variable_label(node))\n$(node.role)\nDM=$(node.dm_region), block=$(_block_label(node.block))",
        )
        println(
            io,
            "  v$(node.position) [shape=ellipse, fillcolor=\"$(_dm_fill(node.dm_region))\", label=\"$label\"];",
        )
    end
    for node in data.constraints
        label = _dot_escape(
            "$(_export_constraint_label(node))\n$(node.role)\nDM=$(node.dm_region), block=$(_block_label(node.block))",
        )
        println(
            io,
            "  c$(node.position) [shape=box, fillcolor=\"$(_dm_fill(node.dm_region))\", label=\"$label\"];",
        )
    end
    for edge in data.edges
        attributes = edge.matched ?
                     " [color=\"#2166ac\", penwidth=2.5]" :
                     " [color=\"#888888\"]"
        println(
            io,
            "  v$(edge.variable_position) -- c$(edge.constraint_position)$attributes;",
        )
    end
    println(io, "}")
    return String(take!(io))
end

structural_graph_dot(graph::IncidenceGraph) =
    structural_graph_dot(structural_graph_data(graph))

structural_graph_dot(model::MOI.ModelLike) =
    structural_graph_dot(incidence_graph(model))
