function _summarize_members(items::Vector{String}; limit::Int = 12)
    length(items) <= limit && return join(items, ", ")
    visible = join(items[1:limit], ", ")
    return "$visible, … ($(length(items) - limit) more)"
end

function _variable_member_label(record::VariableRecord)
    return isnothing(record.name) ? "v$(record.index.value)" : record.name
end

function _constraint_member_label(row::ConstraintNodeRecord)
    base = isnothing(row.constraint.name) ?
           "c$(row.constraint.index.value)" :
           row.constraint.name
    return isnothing(row.row) ? base : "$base[$(row.row)]"
end

function _component_description(
    graph::IncidenceGraph,
    component::StructuralComponent,
    number::Int,
)
    variables = String[
        _variable_member_label(graph.variables[position]) for
        position in component.variable_positions
    ]
    constraints = String[
        _constraint_member_label(graph.constraint_nodes[position]) for
        position in component.constraint_positions
    ]
    return "component $number: variables={$(_summarize_members(variables))}; " *
           "constraint_nodes={$(_summarize_members(constraints))}"
end

function _component_affected(
    graph::IncidenceGraph,
    components::Vector{StructuralComponent},
)
    affected = EntityRef[]
    for component in components
        for position in component.variable_positions
            push!(affected, _variable_ref(graph.variables[position]))
        end
        for position in component.constraint_positions
            row = graph.constraint_nodes[position]
            push!(
                affected,
                _constraint_ref(row.constraint; row = row.row),
            )
        end
    end
    return affected
end

function _objective_component_coupling(
    model::ModelSnapshot,
    graph::IncidenceGraph,
    components::Vector{StructuralComponent},
)
    isnothing(model.objective) && return "false"
    support = variable_support(model.objective.function_value)
    support.complete || return "unknown"
    variable_positions = Dict(
        record.index => position for
        (position, record) in enumerate(graph.variables)
    )
    component_by_variable = Dict{Int,Int}()
    for (component_number, component) in enumerate(components)
        for position in component.variable_positions
            component_by_variable[position] = component_number
        end
    end
    touched_components = Set{Int}()
    for variable in support.variables
        position = get(variable_positions, variable, 0)
        iszero(position) && continue
        component_number = get(component_by_variable, position, 0)
        iszero(component_number) || push!(touched_components, component_number)
    end
    return string(length(touched_components) > 1)
end

"""
    analyze_structure(snapshot; graph = incidence_graph(snapshot))

Report facts derived from the variable–constraint incidence graph. This stage
does not assign numerical-rank meaning to structural decompositions.
"""
function analyze_structure(
    model::ModelSnapshot;
    graph::IncidenceGraph = incidence_graph(model),
)
    report = DiagnosticReport()
    report.metadata[:incidence_complete] = string(graph.complete)
    report.metadata[:incidence_edge_count] = string(
        sum(length, graph.constraint_to_variables; init = 0),
    )
    report.metadata[:constraint_node_count] =
        string(length(graph.constraint_nodes))

    if !graph.complete
        push!(
            report,
            Finding(
                :structural_component_analysis_unavailable;
                severity = SeverityInfo,
                domain = RepresentationalIssue,
                basis = StructuralProof,
                confidence = ConfidenceCertain,
                observation = "Connected-component analysis was skipped because the incidence graph is incomplete.",
                why_it_matters = "Missing incidence edges could split one real component into several apparent components.",
                evidence = [
                    Evidence(
                        "No variable extractor is registered for every function type";
                        details = [
                            "types" => join(graph.unsupported_types, ", "),
                        ],
                    ),
                ],
                suggested_actions = [
                    "Extend variable_support for the listed MOI function types.",
                ],
            ),
        )
        return report
    end

    components = connected_components(graph)
    nontrivial_components = filter(
        component ->
            !isempty(component.variable_positions) &&
            !isempty(component.constraint_positions),
        components,
    )
    isolated_variables = count(
        component ->
            length(component.variable_positions) == 1 &&
            isempty(component.constraint_positions),
        components,
    )
    isolated_constraints = count(
        component ->
            isempty(component.variable_positions) &&
            length(component.constraint_positions) == 1,
        components,
    )
    report.metadata[:structural_component_count] =
        string(length(nontrivial_components))
    report.metadata[:isolated_variable_count] = string(isolated_variables)
    report.metadata[:isolated_constraint_node_count] =
        string(isolated_constraints)

    length(nontrivial_components) > 1 || return report
    sizes = join(
        (
            "$(length(component.variable_positions))v/$(length(component.constraint_positions))c" for
            component in nontrivial_components
        ),
        ", ",
    )
    descriptions = join(
        (
            _component_description(graph, component, number) for
            (number, component) in enumerate(nontrivial_components)
        ),
        " | ",
    )
    objective_coupling = _objective_component_coupling(
        model,
        graph,
        nontrivial_components,
    )
    push!(
        report,
        Finding(
            :multiple_constraint_components;
            severity = SeverityInfo,
            domain = RepresentationalIssue,
            basis = StructuralProof,
            confidence = ConfidenceCertain,
            observation = "The constraint incidence graph contains $(length(nontrivial_components)) disconnected nontrivial components.",
            why_it_matters = "Independent equation subsystems may be intentional, but unexpected separation often reveals a missing coupling constraint or supports component-wise diagnosis.",
            evidence = [
                Evidence(
                    "Connected components were computed from declared syntactic incidence";
                    details = [
                        "component_sizes" => sizes,
                        "component_members" => descriptions,
                        "objective_couples_components" => objective_coupling,
                    ],
                ),
            ],
            suggested_actions = [
                "Confirm that each disconnected equation subsystem is intentional.",
                "Inspect missing coupling equations if the separation is unexpected.",
                objective_coupling == "true" ?
                "Treat the subsystems as constraint-separable but not objective-separable." :
                "Consider analyzing the components independently.",
            ],
            affected = _component_affected(graph, nontrivial_components),
        ),
    )
    return report
end

analyze_structure(model::MOI.ModelLike) = analyze_structure(snapshot(model))
