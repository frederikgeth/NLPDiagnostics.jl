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

function _structural_affected(
    graph::IncidenceGraph,
    variable_positions::Vector{Int},
    constraint_positions::Vector{Int},
)
    affected = EntityRef[
        _variable_ref(graph.variables[position]) for
        position in variable_positions
    ]
    for position in constraint_positions
        node = graph.constraint_nodes[position]
        push!(
            affected,
            _constraint_ref(node.constraint; row = node.row),
        )
    end
    return affected
end

function _variable_position_labels(
    graph::IncidenceGraph,
    positions::Vector{Int},
)
    return String[
        _variable_member_label(graph.variables[position]) for
        position in positions
    ]
end

function _constraint_position_labels(
    graph::IncidenceGraph,
    positions::Vector{Int},
)
    return String[
        _constraint_member_label(graph.constraint_nodes[position]) for
        position in positions
    ]
end

function _analyze_matching!(
    report::DiagnosticReport,
    graph::IncidenceGraph,
)
    matching = maximum_matching(graph)
    matching.complete || return
    unmatched_variables = Int[
        position for position in matching.eligible_variable_positions if
        iszero(matching.variable_match[position])
    ]
    unmatched_constraints = Int[
        position for position in matching.eligible_constraint_positions if
        iszero(matching.constraint_match[position])
    ]
    cardinality = matching_cardinality(matching)
    report.metadata[:free_structural_variable_count] =
        string(length(matching.eligible_variable_positions))
    report.metadata[:equality_constraint_node_count] =
        string(length(matching.eligible_constraint_positions))
    report.metadata[:structural_matching_cardinality] = string(cardinality)
    report.metadata[:unmatched_structural_variable_count] =
        string(length(unmatched_variables))
    report.metadata[:unmatched_structural_equation_count] =
        string(length(unmatched_constraints))

    if !isempty(unmatched_variables)
        labels = _variable_position_labels(graph, unmatched_variables)
        push!(
            report,
            Finding(
                :unmatched_structural_variables;
                severity = SeverityWarning,
                domain = MathematicalIssue,
                basis = StructuralProof,
                confidence = ConfidenceCertain,
                observation = "$(length(unmatched_variables)) free variable$(length(unmatched_variables) == 1 ? " is" : "s are") unmatched by the equality-constraint pattern.",
                why_it_matters = "This proves structural underdetermination of the equality graph, although an active inequality or objective term may still select a local solution.",
                evidence = [
                    Evidence(
                        "A deterministic maximum-cardinality matching left free variables unmatched";
                        details = [
                            "matching_cardinality" => cardinality,
                            "eligible_free_variables" =>
                                length(matching.eligible_variable_positions),
                            "eligible_equality_nodes" =>
                                length(matching.eligible_constraint_positions),
                            "unmatched_variables" => join(labels, ", "),
                            "scope" =>
                                "free variables and equality nodes only",
                        ],
                    ),
                ],
                suggested_actions = [
                    "Inspect the unmatched variables for missing equality equations or an intended gauge freedom.",
                    "If inequalities are expected to determine these variables, repeat the analysis with an evaluated active-set view once available.",
                ],
                affected = _structural_affected(
                    graph,
                    unmatched_variables,
                    Int[],
                ),
            ),
        )
    end

    if !isempty(unmatched_constraints)
        labels = _constraint_position_labels(graph, unmatched_constraints)
        push!(
            report,
            Finding(
                :unmatched_structural_equations;
                severity = SeverityWarning,
                domain = MathematicalIssue,
                basis = StructuralProof,
                confidence = ConfidenceCertain,
                observation = "$(length(unmatched_constraints)) equality constraint node$(length(unmatched_constraints) == 1 ? " is" : "s are") unmatched to free variables.",
                why_it_matters = "This proves structural overdetermination of the equality graph and may indicate redundant equations or consistency conditions on fixed data.",
                evidence = [
                    Evidence(
                        "A deterministic maximum-cardinality matching left equality nodes unmatched";
                        details = [
                            "matching_cardinality" => cardinality,
                            "eligible_free_variables" =>
                                length(matching.eligible_variable_positions),
                            "eligible_equality_nodes" =>
                                length(matching.eligible_constraint_positions),
                            "unmatched_equations" => join(labels, ", "),
                            "scope" =>
                                "free variables and equality nodes only",
                        ],
                    ),
                ],
                suggested_actions = [
                    "Inspect the unmatched equations for duplicates, redundant physics, or inconsistent fixed data.",
                ],
                affected = _structural_affected(
                    graph,
                    Int[],
                    unmatched_constraints,
                ),
            ),
        )
    end

    partition = dulmage_mendelsohn(graph; matching = matching)
    partition.complete || return
    report.metadata[:dm_underdetermined_variable_count] =
        string(length(partition.underdetermined_variables))
    report.metadata[:dm_underdetermined_equation_count] =
        string(length(partition.underdetermined_constraints))
    report.metadata[:dm_well_determined_variable_count] =
        string(length(partition.well_determined_variables))
    report.metadata[:dm_well_determined_equation_count] =
        string(length(partition.well_determined_constraints))
    report.metadata[:dm_overdetermined_variable_count] =
        string(length(partition.overdetermined_variables))
    report.metadata[:dm_overdetermined_equation_count] =
        string(length(partition.overdetermined_constraints))

    if !isempty(partition.underdetermined_variables)
        push!(
            report,
            Finding(
                :underdetermined_equality_partition;
                severity = SeverityWarning,
                domain = MathematicalIssue,
                basis = StructuralProof,
                confidence = ConfidenceCertain,
                observation = "The equality graph has an underdetermined Dulmage–Mendelsohn partition with $(length(partition.underdetermined_variables)) variables and $(length(partition.underdetermined_constraints)) equations.",
                why_it_matters = "Every maximum matching leaves a degree-of-freedom pattern in this partition; the result is structural and does not yet classify its physical meaning.",
                evidence = [
                    Evidence(
                        "Alternating reachability from unmatched free variables";
                        details = [
                            "variables" => join(
                                _variable_position_labels(
                                    graph,
                                    partition.underdetermined_variables,
                                ),
                                ", ",
                            ),
                            "equations" => join(
                                _constraint_position_labels(
                                    graph,
                                    partition.underdetermined_constraints,
                                ),
                                ", ",
                            ),
                        ],
                    ),
                ],
                suggested_actions = [
                    "Classify this partition as an expected gauge, missing equation, or intended degree of freedom.",
                ],
                affected = _structural_affected(
                    graph,
                    partition.underdetermined_variables,
                    partition.underdetermined_constraints,
                ),
            ),
        )
    end

    if !isempty(partition.overdetermined_constraints)
        push!(
            report,
            Finding(
                :overdetermined_equality_partition;
                severity = SeverityWarning,
                domain = MathematicalIssue,
                basis = StructuralProof,
                confidence = ConfidenceCertain,
                observation = "The equality graph has an overdetermined Dulmage–Mendelsohn partition with $(length(partition.overdetermined_variables)) variables and $(length(partition.overdetermined_constraints)) equations.",
                why_it_matters = "Every maximum matching leaves an excess-equation pattern in this partition; numerical dependence or infeasibility must be checked separately.",
                evidence = [
                    Evidence(
                        "Alternating reachability from unmatched equality nodes";
                        details = [
                            "variables" => join(
                                _variable_position_labels(
                                    graph,
                                    partition.overdetermined_variables,
                                ),
                                ", ",
                            ),
                            "equations" => join(
                                _constraint_position_labels(
                                    graph,
                                    partition.overdetermined_constraints,
                                ),
                                ", ",
                            ),
                        ],
                    ),
                ],
                suggested_actions = [
                    "Inspect this partition for redundant equations or fixed-data consistency conditions.",
                ],
                affected = _structural_affected(
                    graph,
                    partition.overdetermined_variables,
                    partition.overdetermined_constraints,
                ),
            ),
        )
    end
    return
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
    for role in instances(VariableRole)
        report.metadata[Symbol("variable_role_", lowercase(string(role)))] =
            string(count(==(role), graph.variable_roles))
    end
    constraint_roles = [node.role for node in graph.constraint_nodes]
    for role in instances(ConstraintRole)
        report.metadata[Symbol("constraint_role_", lowercase(string(role)))] =
            string(count(==(role), constraint_roles))
    end

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

    _analyze_matching!(report, graph)

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
