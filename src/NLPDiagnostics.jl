module NLPDiagnostics

# Keep the generic core dependent on public MathOptInterface APIs only.

import MathOptInterface as MOI
using LinearAlgebra
using SparseArrays

include("reports/types.jl")
include("reports/text.jl")
include("ir/model_snapshot.jl")
include("ir/expression_support.jl")
include("ir/structural_roles.jl")
include("ir/incidence_graph.jl")
include("numerics/types.jl")
include("numerics/evaluator.jl")
include("numerics/degeneracy.jl")
include("numerics/hessian.jl")
include("numerics/activity.jl")
include("analysis/matching.jl")
include("reports/structural_graph.jl")
include("analysis/domains.jl")
include("analysis/derivatives.jl")
include("analysis/expressions.jl")
include("analysis/static.jl")
include("analysis/structure.jl")
include("analysis/numerical.jl")
include("analysis/activity.jl")
include("analysis/degeneracy.jl")
include("analysis/profiling.jl")
include("analysis/postmortem.jl")
include("analysis/initialization.jl")

export Confidence
export ConfidenceCertain, ConfidenceHigh, ConfidenceLow, ConfidenceMedium
export ConstraintRole
export ConstraintActivity
export ConstraintFeasibilitySummary
export CoupledSetActivity
export CoupledSetTangentEvidence
export CoupledSetQualificationScreen
export CoupledSetMappedTangent
export CoupledSetFeasibilitySummary
export ComponentMetadata
export ComponentPortMetadata
export PortNullspaceMode
export PortNullspaceModeSemantics
export PortConnectionMetadata
export PortTopologyNullspace
export PortCoordinateMap
export PortCoordinateSemantics
export ComponentCoordinateSemantics
export PortTopologyCoordinateProjection
export PortExpectedNullspaceSummary
export port_topology_expected_nullspace_modes
export port_component_expected_nullspace_modes
export port_expected_nullspace_modes
export port_expected_nullspace_summary
export ElasticFeasibilityPlan
export ElasticRelaxation
export ElasticFeasibilityModel
export ElasticRelaxationValue
export ElasticFeasibilitySolve
export ElasticSubsetProbe
export ElasticSubsetSearch
export ElasticSubsetEnsemble
export ElasticMinimumRelaxationSearch
export SolverConflictResult
export ElasticDomainGuard
export ElasticDomainGuardPlan
export ActiveSetStructuralMatching
export ActiveSetStructuralDecomposition
export CoupledConstraint, EqualityConstraint, FreeConstraint
export InequalityConstraint, OpaqueConstraint
export DiagnosticReport
export DomainAssessment
export DomainPossibleViolation, DomainProvenViolation, DomainSafe
export DulmageMendelsohnBlock
export DulmageMendelsohnPartition
export EntityRef
export entity_data
export Evidence
export evidence_data
export EvidenceBasis
export EvaluationCache
export EvaluationFailure
export EvaluationPoint
export EvaluatorCapabilities
export ExpressionDomainIssue
export ExpressionDerivativeIssue
export ExpressionNumericalRisk
export StableReformulationCandidate
export StableReformulationPlan
export ExpressionNodePath
export Finding
export finding_data
export findings
export finding_code_counts
export IncidenceGraph
export IssueDomain
export IntervalEnclosure
export JacobianEntry
export JacobianRankEstimate
export SparseJacobianPatternEstimate
export SparseQRRankEstimate
export IterativeNullspaceEstimate
export IterativeNullspaceSubspaceEstimate
export IterativeJacobianSpectrumEstimate
export JacobianScaleSummary
export HessianEntry
export HessianEvaluation
export NumericalEvaluation
export evaluation_call_statistics
export MFCQScreen
export MultiplierRecovery
export NullspaceFingerprint
export ExpectedNullspaceMode
export ReducedHessianAnalysis
export ReducedHessianSnapshot
export OperatorDomainRequirement
export OperatorDerivativeRequirement
export ProfileCase
export ProfileAggregate
export profile_aggregate_data
export profile_comparison_data
export markdown_profile_aggregate
export markdown_profile_comparison
export ProfileResult
export profile_result_data
export ProfileTimingSummary
export ProfileAllocationSummary
export ProfileFindingStability
export ProfileExpectedEvidenceSummary
export ProfileStageComparison
export ProfileFindingComparison
export ProfileNumericalComparison
export ProfileComparison
export ProfileNumericalSummary
export SolverPostmortem
export SolverLogObservation
export SolverIterationRecord
export SolverIterationSegment
export SolverIterationSummary
export IterationPointBinding
export MathematicalIssue, NumericalIssue, PhysicalIssue, RepresentationalIssue
export MathematicalProof, NumericalObservation, PhysicalExpectation
export markdown_report
export LocalInference, HeuristicInterpretation, StructuralProof
export Severity
export report_data
export SeverityError, SeverityInfo, SeverityWarning
export StructuralComponent
export StructuralConstraintNode
export StructuralGraphData
export StructuralGraphEdge
export StructuralMatching
export StructuralNumericalComparison
export StructuralVariableNode
export VariableSupport
export VariableRole
export VariableDomain
export DiscreteVariable, FixedVariable, FreeVariable, InfeasibleVariableDomain, InvalidVariableDomain, ParameterVariable
export analyze
export analyze_domains
export domain_interval_data
export analyze_derivatives
export analyze_degeneracy
export analyze_expressions
export stable_reformulation_plan
export analyze_stable_reformulation_plan
export analyze_initialization
export analyze_numerical
export analyze_jacobian_rank_persistence
export analyze_jacobian_scaling_persistence
export analyze_jacobian_derivative_provenance_persistence
export analyze_jacobian_rank_tolerance_sweep
export analyze_jacobian_condition_persistence
export analyze_reduced_hessian
export analyze_reduced_hessian_persistence
export analyze_active_set
export analyze_active_set_second_order
export analyze_component_ranks
export analyze_component_rank_persistence
export elastic_feasibility_plan
export analyze_elastic_feasibility_plan
export build_elastic_feasibility_model
export elastic_relaxation_values
export elastic_objective_value
export analyze_elastic_relaxations
export solve_elastic_feasibility!
export local_elastic_subset_search
export analyze_local_elastic_subset_search
export local_elastic_subset_ensemble
export analyze_local_elastic_subset_ensemble
export minimum_elastic_relaxation_search
export analyze_minimum_elastic_relaxation_search
export compute_solver_conflict!
export analyze_solver_conflict
export analyze_solver_conflict_crosscheck
export elastic_domain_guard_plan
export analyze_elastic_domain_guard_plan
export analyze_static
export analyze_structure
export analyze_postmortem
export analyze_postmortem_log_consistency
export analyze_solver_log
export analyze_solver_iterations
export analyze_iteration_points
export profile_case
export profile_case_repeated
export profile_cases_repeated
export profile_synthetic_sparse_ladder
export compare_profiles
export synthetic_sparse_profile_corpus
export synthetic_stability_profile_corpus
export profile_synthetic_stability_corpus
export synthetic_derivative_boundary_profile_corpus
export profile_synthetic_derivative_boundary_corpus
export synthetic_float32_derivative_overflow_profile_corpus
export synthetic_coupled_cone_profile_corpus
export synthetic_quadratic_geometry_profile_corpus
export profile_synthetic_quadratic_geometry_corpus
export profile_synthetic_float32_derivative_overflow_corpus
export profile_synthetic_coupled_cone_corpus
export solver_postmortem
export solver_log_observations
export solver_iteration_records
export solver_iteration_segments
export solver_iteration_summary
export bind_iteration_points
export connected_components
export constraint_role
export dulmage_mendelsohn
export domain_issues
export derivative_issues
export evaluation_point
export evaluate_numerical
export evaluate_lagrangian_hessian
export evaluator_capabilities
export expression_numerical_risks
export fixed_operator_value
export incidence_graph
export initialization_point
export is_coordinatewise_set
export matching_cardinality
export maximum_matching
export jacobian_scale_summary
export jacobian_rank_estimate
export sparse_jacobian_pattern_estimate
export sparse_qr_rank_estimate
export iterative_right_nullspace_estimate
export iterative_right_nullspace_subspace_estimate
export iterative_left_nullspace_subspace_estimate
export iterative_jacobian_spectrum_estimate
export analyze_iterative_right_nullspace_probe
export analyze_iterative_left_nullspace_probe
export analyze_iterative_jacobian_spectrum_probe
export analyze_iterative_right_nullspace_persistence
export analyze_iterative_left_nullspace_persistence
export constraint_feasibility_summary
export coupled_set_feasibility_summary
export coupled_set_activity
export coupled_set_tangent_evidence
export coupled_set_qualification_screen
export coupled_set_mapped_tangents
export analyze_coupled_set_qualification
export active_constraint_rows
export active_set_matching
export active_set_structural_decomposition
export mfcq_screen
export recover_stationarity_multipliers
export nullspace_fingerprints
export expected_nullspace_modes
export component_metadata
export component_coordinate_semantics
export analyze_component_coordinate_scales
export ComponentConstraintScaleSemantics
export analyze_component_constraint_scales
export component_constraint_scale_semantics
export powermodels_component_metadata
export powermodels_capability_report
export powermodels_reference_bus_report
export powermodels_variable_indices
export powermodels_angle_gauge_modes
export powermodels_jump_model
export powermodels_analyze_degeneracy
export powermodels_analyze_active_set
export powermodels_analyze_reduced_hessian_persistence
export powermodels_analyze_jacobian_rank_persistence
export powermodels_analyze_component_rank_persistence
export component_port_metadata
export component_port_nullspace_modes
export component_port_nullspace_mode_semantics
export component_port_connections
export component_port_coordinate_maps
export component_port_coordinate_semantics
export port_topology_nullspace
export structural_numerical_comparison
export reduced_hessian_analysis
export operator_domain_requirements
export operator_derivative_requirements
export operator_interval
export snapshot
export structural_graph_data
export structural_graph_dot
export structural_graph_text
export variable_support
export variable_roles
export variable_domains
export well_determined_blocks

function _component_metadata_findings(
    items::AbstractVector{<:ComponentMetadata};
    model_variables::Union{Nothing,AbstractVector{MOI.VariableIndex}} = nothing,
    model_constraints::Union{Nothing,AbstractVector{EntityRef}} = nothing,
)
    report = DiagnosticReport()
    component_keys = [(item.component_type, item.component_id) for item in items]
    duplicate_keys = unique([key for key in component_keys if count(==(key), component_keys) > 1])
    for (component_type, component_id) in duplicate_keys
        push!(report, Finding(:duplicate_component_metadata;
            severity = SeverityWarning, domain = RepresentationalIssue,
            basis = StructuralProof, confidence = ConfidenceCertain,
            observation = "Component metadata declares $(component_type) '$component_id' more than once.",
            why_it_matters = "Ambiguous component identity can invalidate plugin-supplied rank, unit, and expected-nullspace interpretations.",
            evidence = [Evidence("Duplicate plugin component key"; details = ["component_type" => component_type, "component_id" => component_id])],
            suggested_actions = ["Provide one metadata record per stable component type and ID."],
        ))
    end
    known_variables = isnothing(model_variables) ? nothing : Set(model_variables)
    known_constraint_indices = isnothing(model_constraints) ? nothing :
        Set(item.index for item in model_constraints if item.kind == :constraint)
    for item in items
        if isempty(String(item.component_type)) || isempty(strip(item.component_id))
            push!(report, Finding(:invalid_component_metadata_identity;
                severity = SeverityError, domain = RepresentationalIssue,
                basis = StructuralProof, confidence = ConfidenceCertain,
                observation = "Component metadata has an empty component type or ID.",
                why_it_matters = "Plugin component declarations need stable identities before their physical interpretation can be inspected or compared.",
                evidence = [Evidence("Invalid plugin component identity"; details = ["component_type" => item.component_type, "component_id" => item.component_id])],
                suggested_actions = ["Declare a nonempty stable component type and component ID."],
            ))
        end
        invalid_units = [key for (key, value) in item.units if
            isempty(String(key)) || isempty(strip(value))]
        if !isempty(invalid_units)
            push!(report, Finding(:invalid_component_metadata_units;
                severity = SeverityWarning, domain = RepresentationalIssue,
                basis = StructuralProof, confidence = ConfidenceCertain,
                observation = "Component metadata has $(length(invalid_units)) empty unit declaration(s).",
                why_it_matters = "Empty unit declarations make physical scaling and tolerance interpretation ambiguous.",
                evidence = [Evidence("Invalid plugin unit declarations"; details = ["component_type" => item.component_type, "component_id" => item.component_id, "unit_fields" => join(string.(invalid_units), ",")])],
                suggested_actions = ["Use nonempty unit field names and unit labels, or omit units that are not known."],
            ))
        end
        if !isnothing(item.expected_rank) && item.expected_rank < 0
            push!(report, Finding(:invalid_component_metadata_expected_rank;
                severity = SeverityError, domain = RepresentationalIssue,
                basis = StructuralProof, confidence = ConfidenceCertain,
                observation = "Component metadata declares negative expected rank $(item.expected_rank).",
                why_it_matters = "Expected rank must be nonnegative before a plugin can compare it with structural or numerical rank evidence.",
                evidence = [Evidence("Invalid plugin expected rank"; details = ["component_type" => item.component_type, "component_id" => item.component_id, "expected_rank" => item.expected_rank])],
                suggested_actions = ["Declare a nonnegative expected rank or omit it when unknown."],
            ))
        end
        duplicate_variables = unique([
            variable for variable in item.variables if count(==(variable), item.variables) > 1
        ])
        if !isempty(duplicate_variables)
            push!(report, Finding(:component_metadata_duplicate_variables;
                severity = SeverityWarning, domain = RepresentationalIssue,
                basis = StructuralProof, confidence = ConfidenceCertain,
                observation = "Component metadata for $(item.component_type) '$(item.component_id)' repeats $(length(duplicate_variables)) variable coordinate(s).",
                why_it_matters = "A repeated coordinate makes a plugin-declared component scope ambiguous.",
                evidence = [Evidence("Duplicate plugin component coordinates"; details = ["variables" => join((variable.value for variable in duplicate_variables), ",")])],
                affected = [EntityRef(:variable, variable.value) for variable in duplicate_variables],
                suggested_actions = ["Declare each component variable coordinate at most once."],
            ))
        end
        if !isnothing(known_variables)
            unknown_variables = [variable for variable in item.variables if !(variable in known_variables)]
            if !isempty(unknown_variables)
                push!(report, Finding(:component_metadata_unknown_variable;
                    severity = SeverityError, domain = RepresentationalIssue,
                    basis = StructuralProof, confidence = ConfidenceCertain,
                    observation = "Component metadata for $(item.component_type) '$(item.component_id)' references $(length(unknown_variables)) variable coordinate(s) absent from the model.",
                    why_it_matters = "A plugin scope cannot support expected-rank or nullspace interpretation when it references another model or stale indices.",
                    evidence = [Evidence("Unknown plugin component coordinates"; details = ["variables" => join((variable.value for variable in unknown_variables), ",")])],
                    affected = [EntityRef(:variable, variable.value) for variable in unknown_variables],
                    suggested_actions = ["Rebuild metadata after model construction and use only variables from the analyzed model."],
                ))
            end
        end
        # Expected rank is a statement about a declared Jacobian block. A
        # missing variable or equation side therefore has rank ceiling zero;
        # do not discard that zero while validating malformed plugin input.
        scope_rank_bound = min(
            length(unique(item.variables)),
            length(unique((item.index, item.subindex) for item in item.constraints)),
        )
        if !isnothing(item.expected_rank) &&
           item.expected_rank > scope_rank_bound
            push!(report, Finding(:component_metadata_expected_rank_exceeds_scope;
                severity = SeverityError, domain = RepresentationalIssue,
                basis = StructuralProof, confidence = ConfidenceCertain,
                observation = "Component metadata declares expected rank $(item.expected_rank) over only $(length(unique(item.variables))) variable coordinate(s).",
                why_it_matters = "A rank in a declared variable-coordinate scope cannot exceed that scope dimension.",
                evidence = [Evidence("Incompatible plugin expected rank and scope"; details = ["expected_rank" => item.expected_rank, "scope_dimension" => length(unique(item.variables))])],
                affected = [EntityRef(:variable, variable.value) for variable in unique(item.variables)],
                suggested_actions = ["Correct the expected rank or declare the full component variable scope."],
            ))
        end
        constraint_keys = [(constraint.index, constraint.subindex) for constraint in item.constraints]
        duplicate_constraints = unique([key for key in constraint_keys if count(==(key), constraint_keys) > 1])
        if !isempty(duplicate_constraints)
            push!(report, Finding(:component_metadata_duplicate_constraints;
                severity = SeverityWarning, domain = RepresentationalIssue,
                basis = StructuralProof, confidence = ConfidenceCertain,
                observation = "Component metadata for $(item.component_type) '$(item.component_id)' repeats $(length(duplicate_constraints)) constraint reference(s).",
                why_it_matters = "A repeated constraint makes a plugin-declared component equation scope ambiguous.",
                evidence = [Evidence("Duplicate plugin component constraints"; details = ["constraints" => join((key[1] for key in duplicate_constraints), ",")])],
                affected = [EntityRef(:constraint, key[1]; subindex = key[2]) for key in duplicate_constraints],
                suggested_actions = ["Declare each component constraint reference at most once."],
            ))
        end
        invalid_kinds = [constraint for constraint in item.constraints if constraint.kind != :constraint]
        if !isempty(invalid_kinds)
            push!(report, Finding(:invalid_component_metadata_constraint_reference;
                severity = SeverityError, domain = RepresentationalIssue,
                basis = StructuralProof, confidence = ConfidenceCertain,
                observation = "Component metadata for $(item.component_type) '$(item.component_id)' includes non-constraint references in its constraint scope.",
                why_it_matters = "Expected-rank equation scopes must use constraint references.",
                evidence = [Evidence("Invalid plugin component constraint scope")],
                affected = invalid_kinds,
                suggested_actions = ["Use EntityRef(:constraint, index) entries for component constraints."],
            ))
        end
        if !isnothing(known_constraint_indices)
            unknown_constraints = [constraint for constraint in item.constraints if
                constraint.kind != :constraint || !(constraint.index in known_constraint_indices)]
            if !isempty(unknown_constraints)
                push!(report, Finding(:component_metadata_unknown_constraint;
                    severity = SeverityError, domain = RepresentationalIssue,
                    basis = StructuralProof, confidence = ConfidenceCertain,
                    observation = "Component metadata for $(item.component_type) '$(item.component_id)' references $(length(unknown_constraints)) constraint(s) absent from the model.",
                    why_it_matters = "A plugin equation scope cannot support structural rank interpretation when it references another model or stale indices.",
                    evidence = [Evidence("Unknown plugin component constraints")],
                    affected = unknown_constraints,
                    suggested_actions = ["Rebuild metadata after model construction and use constraints from the analyzed model."],
                ))
            end
        end
    end
    return report
end

function _component_coordinate_semantics_findings(
    items::AbstractVector{<:ComponentCoordinateSemantics},
    model_variables::AbstractVector{MOI.VariableIndex},
    ; components::AbstractVector{<:ComponentMetadata} = ComponentMetadata[],
)
    report = DiagnosticReport()
    known = Set(model_variables)
    semantic_keys = [(item.component_type, item.component_id, Tuple(item.variables)) for item in items]
    for key in unique([key for key in semantic_keys if count(==(key), semantic_keys) > 1])
        push!(report, Finding(:duplicate_component_coordinate_semantics;
            severity = SeverityWarning, domain = RepresentationalIssue,
            basis = StructuralProof, confidence = ConfidenceCertain,
            observation = "Component coordinate semantics declares the same component variable scope more than once.",
            why_it_matters = "Competing quantity or representation declarations make physical interpretation ambiguous.",
            evidence = [Evidence("Duplicate component coordinate semantics"; details = ["component_type" => key[1], "component_id" => key[2], "variable_count" => length(key[3])])],
            affected = [EntityRef(:variable, variable.value) for variable in key[3]],
            suggested_actions = ["Provide one coordinate semantics declaration per component variable scope."],
        ))
    end
    variables_to_items = Dict{MOI.VariableIndex,Vector{ComponentCoordinateSemantics}}()
    for item in items, variable in item.variables
        push!(get!(variables_to_items, variable, ComponentCoordinateSemantics[]), item)
    end
    for variable in sort!(collect(keys(variables_to_items)); by = index -> index.value)
        declarations = variables_to_items[variable]
        signatures = unique([
            (
                item.quantity,
                item.representation,
                Tuple(sort!(collect(item.units); by = first)),
                item.nominal_scale,
            )
            for item in declarations
        ])
        length(signatures) <= 1 && continue
        component_labels = sort!(unique([
            "$(item.component_type):$(item.component_id)" for item in declarations
        ]))
        descriptions = sort!(unique([
            "$(signature[1])/$(signature[2])" *
            (isempty(signature[3]) ? "" : " [" * join(("$(first(unit))=$(last(unit))" for unit in signature[3]), ", ") * "]") *
            (isnothing(signature[4]) ? "" : " nominal_scale=$(signature[4])")
            for signature in signatures
        ]))
        push!(report, Finding(:component_coordinate_semantics_variable_conflict;
            severity = SeverityWarning, domain = RepresentationalIssue,
            basis = StructuralProof, confidence = ConfidenceCertain,
            observation = "Model variable $(variable.value) has $(length(signatures)) incompatible component-coordinate semantics declarations.",
            why_it_matters = "A shared coordinate cannot be given a single physical-scaling or tolerance interpretation until the plugin explains the competing declarations.",
            evidence = [Evidence("Conflicting component coordinate semantics"; details = [
                "variable" => variable.value,
                "components" => join(component_labels, ", "),
                "semantics" => join(descriptions, " | "),
            ])],
            affected = [EntityRef(:variable, variable.value)],
            suggested_actions = ["Use one quantity, representation, and unit convention for this shared coordinate, or split it into explicitly transformed model variables."],
        ))
    end
    for item in items
        unknown = [variable for variable in item.variables if !(variable in known)]
        isempty(unknown) || push!(report, Finding(:component_coordinate_semantics_unknown_variable;
            severity = SeverityError, domain = RepresentationalIssue,
            basis = StructuralProof, confidence = ConfidenceCertain,
            observation = "Component coordinate semantics references $(length(unknown)) variable(s) absent from the model.",
            why_it_matters = "A stale coordinate declaration cannot support numerical or physical interpretation.",
            evidence = [Evidence("Component coordinate semantics scope")],
            affected = [EntityRef(:variable, variable.value) for variable in unknown],
            suggested_actions = ["Rebuild coordinate semantics after model construction."],
        ))
        matching_scopes = [
            Set(component.variables) for component in components if
            component.component_type == item.component_type &&
            component.component_id == item.component_id && !isempty(component.variables)
        ]
        if !isempty(matching_scopes) && !any(scope -> all(variable in scope for variable in item.variables), matching_scopes)
            push!(report, Finding(:component_coordinate_semantics_scope_outside_component;
                severity = SeverityError, domain = RepresentationalIssue,
                basis = StructuralProof, confidence = ConfidenceCertain,
                observation = "Component coordinate semantics for $(item.component_type) '$(item.component_id)' declares coordinates outside every matching component variable scope.",
                why_it_matters = "A component-level physical interpretation must not silently extend beyond the component coordinates declared by the same plugin.",
                evidence = [Evidence("Component coordinate semantics scope mismatch"; details = [
                    "semantic_variable_count" => length(item.variables),
                    "declared_component_scope_count" => length(matching_scopes),
                    "declared_component_scope_sizes" => join(length.(matching_scopes), ","),
                ])],
                affected = [EntityRef(:variable, variable.value) for variable in item.variables],
                suggested_actions = ["Align the coordinate semantics variables with one declared ComponentMetadata scope, or split the declaration by component."],
            ))
        end
        if item.quantity != :generic && isempty(item.units)
            push!(report, Finding(:component_coordinate_semantics_units_unspecified;
                severity = SeverityInfo, domain = RepresentationalIssue,
                basis = StructuralProof, confidence = ConfidenceCertain,
                observation = "Declared $(item.quantity) component coordinates have no unit convention.",
                why_it_matters = "The coordinate scope is structurally usable, but physical scaling and tolerance interpretation remain unavailable.",
                evidence = [Evidence("Component coordinate semantics units"; details = ["component_type" => item.component_type, "component_id" => item.component_id, "quantity" => item.quantity])],
                affected = [EntityRef(:variable, variable.value) for variable in item.variables],
                suggested_actions = ["Declare a unit convention such as rad, p.u., kV, A, or MVA before requesting physical scaling interpretation."],
            ))
        end
    end
    return report
end

"""
    analyze_component_coordinate_scales(model, point; mismatch_factor = 1e3)

Compare an explicit evaluation point with optional plugin-declared nominal
coordinate scales. A reported mismatch is local numerical evidence about the
declared coordinate convention, not a physical-limit or feasibility claim.
"""
function analyze_component_coordinate_scales(
    semantics::AbstractVector{<:ComponentCoordinateSemantics},
    point::EvaluationPoint;
    mismatch_factor::Real = 1.0e3,
)
    mismatch_factor > 1 && isfinite(mismatch_factor) || throw(ArgumentError(
        "mismatch_factor must be finite and greater than one",
    ))
    report = DiagnosticReport()
    report.metadata[:stage] = "component_coordinate_scales"
    report.metadata[:component_coordinate_scale_mismatch_factor] = string(mismatch_factor)
    declared = [item for item in semantics if !isnothing(item.nominal_scale)]
    report.metadata[:component_coordinate_nominal_scale_declaration_count] = string(length(declared))
    values = Dict(zip(point.variables, point.values))
    checked = 0
    direct_checks = Dict{MOI.VariableIndex,Vector{ComponentCoordinateSemantics}}()
    for item in declared, variable in item.variables
        haskey(values, variable) || continue
        checked += 1
        push!(get!(direct_checks, variable, ComponentCoordinateSemantics[]), item)
    end
    for variable in sort!(collect(Base.keys(direct_checks)); by = index -> index.value)
        groups = Vector{Vector{ComponentCoordinateSemantics}}()
        for item in direct_checks[variable]
            group_index = findfirst(group -> isapprox(
                something(item.nominal_scale), something(first(group).nominal_scale);
                rtol = sqrt(eps(Float64)), atol = 0.0,
            ), groups)
            isnothing(group_index) ? push!(groups, [item]) : push!(groups[group_index], item)
        end
        sort!(groups; by = group -> something(first(group).nominal_scale))
        for group in groups
            nominal = something(first(group).nominal_scale)
            value = values[variable]
            ratio = abs(value) / nominal
            (ratio > mismatch_factor || (!iszero(value) && ratio < inv(mismatch_factor))) || continue
            direction = ratio > mismatch_factor ? "larger" : "smaller"
            components = join(sort!(unique([
                "$(item.component_type):$(item.component_id)" for item in group
            ])), ", ")
            quantities = join(sort!(unique(string(item.quantity) for item in group)), ", ")
            representations = join(sort!(unique(string(item.representation) for item in group)), ", ")
            push!(report, Finding(:component_coordinate_nominal_scale_mismatch;
                severity = SeverityWarning, domain = NumericalIssue,
                basis = LocalInference, confidence = ConfidenceHigh,
                observation = "Component coordinate v$(variable.value) is $(direction) than its declared nominal scale by a factor of $(ratio).",
                why_it_matters = "A large value-to-nominal-scale separation can make derivative magnitudes, solver tolerances, and physical-unit interpretation sensitive to coordinate scaling; zero is intentionally not classified because it can be a valid operating value.",
                evidence = [Evidence("Declared component coordinate scale"; details = [
                    "components" => components,
                    "quantities" => quantities,
                    "representations" => representations,
                    "value" => value,
                    "nominal_scale" => nominal,
                    "absolute_value_to_nominal_scale_ratio" => ratio,
                    "mismatch_factor" => mismatch_factor,
                ])],
                affected = [EntityRef(:variable, variable.value)],
                suggested_actions = ["Check the declared nominal scale and coordinate units, then compare Jacobian column scaling at the same point before rescaling the formulation."],
            ))
        end
    end
    report.metadata[:component_coordinate_nominal_scale_checked_variable_count] = string(checked)
    return report
end

"""Compare declared nominal scales with public-MOI set-relative scalar violations."""
function analyze_component_constraint_scales(
    semantics::AbstractVector{<:ComponentConstraintScaleSemantics},
    summary::ConstraintFeasibilitySummary{T};
    mismatch_factor::Real = 1.0e3,
) where {T<:AbstractFloat}
    mismatch_factor > 1 && isfinite(mismatch_factor) || throw(ArgumentError(
        "mismatch_factor must be finite and greater than one",
    ))
    report = DiagnosticReport()
    report.metadata[:stage] = "component_constraint_scales"
    report.metadata[:component_constraint_scale_declaration_count] = string(length(semantics))
    report.metadata[:component_constraint_scale_source_count] = string(sum(
        (length(item.constraints) for item in semantics); init = 0,
    ))
    declarations_by_source = Dict{Tuple{Symbol,Int,Union{Nothing,Int}},Vector{ComponentConstraintScaleSemantics}}()
    for item in semantics, source in item.constraints
        push!(get!(declarations_by_source, _entity_row_key(source),
                   ComponentConstraintScaleSemantics[]), item)
    end
    for key in sort!(collect(Base.keys(declarations_by_source));
                     by = key -> (string(key[1]), key[2], something(key[3], 0)))
        declarations = declarations_by_source[key]
        length(declarations) <= 1 && continue
        reference = first(declarations).nominal_scale
        all(item -> isapprox(item.nominal_scale, reference;
                              rtol = sqrt(eps(Float64)), atol = 0.0),
            declarations) && continue
        components = join(sort!(unique([
            "$(item.component_type):$(item.component_id)=$(item.nominal_scale)"
            for item in declarations
        ])), ", ")
        push!(report, Finding(:component_constraint_nominal_scale_conflict;
            severity = SeverityWarning, domain = RepresentationalIssue,
            basis = StructuralProof, confidence = ConfidenceCertain,
            observation = "Constraint $(key[2]) has incompatible component residual-scale declarations.",
            why_it_matters = "One scalar set-relative residual cannot receive a single physical tolerance interpretation when component declarations use different nominal scales.",
            evidence = [Evidence("Component constraint-scale declarations";
                details = ["constraint" => key[2], "declarations" => components])],
            affected = [EntityRef(key[1], key[2]; subindex = key[3])],
            suggested_actions = ["Align nominal residual scales or split the shared constraint into explicitly transformed component rows."],
        ))
    end
    activities = Dict(_entity_row_key(item.source) => item for item in summary.activities)
    checked = 0
    unavailable = 0
    missing_source = 0
    unavailable_residual = 0
    reported = Set{Tuple{Symbol,Int,Union{Nothing,Int},Float64}}()
    for item in semantics, source in item.constraints
        activity = get(activities, _entity_row_key(source), nothing)
        if isnothing(activity)
            unavailable += 1
            missing_source += 1
            continue
        elseif isnothing(activity.feasibility_violation)
            unavailable += 1
            unavailable_residual += 1
            continue
        end
        checked += 1
        violation = activity.feasibility_violation
        ratio = violation / item.nominal_scale
        ratio > mismatch_factor || continue
        report_key = (_entity_row_key(source)..., item.nominal_scale)
        report_key in reported && continue
        push!(reported, report_key)
        declarations = join(sort!(unique([
            "$(candidate.component_type):$(candidate.component_id)" for candidate in
            get(declarations_by_source, _entity_row_key(source), ComponentConstraintScaleSemantics[]) if
            isapprox(candidate.nominal_scale, item.nominal_scale;
                     rtol = sqrt(eps(Float64)), atol = 0.0)
        ])), ", ")
        push!(report, Finding(:component_constraint_nominal_scale_mismatch;
            severity = SeverityWarning, domain = NumericalIssue,
            basis = LocalInference, confidence = ConfidenceHigh,
            observation = "Constraint $(source.index) violation exceeds its declared nominal residual scale by a factor of $(ratio).",
            why_it_matters = "This is a set-relative scalar violation, not a raw constraint-function value or a solver feasibility certificate.",
            evidence = [Evidence("Declared constraint residual scale"; details = [
                "components" => declarations, "quantity" => item.quantity, "violation" => violation,
                "nominal_scale" => item.nominal_scale, "ratio" => ratio,
            ])], affected = [source],
            suggested_actions = ["Check the declared residual scale and compare it with the solver's feasibility tolerance."],
        ))
    end
    report.metadata[:component_constraint_scale_checked_count] = string(checked)
    report.metadata[:component_constraint_scale_unavailable_count] = string(unavailable)
    report.metadata[:component_constraint_scale_missing_source_count] = string(missing_source)
    report.metadata[:component_constraint_scale_unavailable_residual_count] = string(unavailable_residual)
    unavailable == 0 || push!(report, Finding(:component_constraint_scale_alignment_unavailable;
        severity = SeverityInfo, domain = RepresentationalIssue,
        basis = StructuralProof, confidence = ConfidenceCertain,
        observation = "$(unavailable) declared component constraint scale(s) could not be aligned with a scalar set-relative evaluation row.",
        why_it_matters = "The generic core withholds residual-scale interpretation for stale references, failed evaluations, and coupled or opaque sets rather than comparing a nominal scale with a raw function value.",
        evidence = [Evidence("Constraint-scale row alignment"; details = [
            "unavailable_count" => unavailable,
            "evaluated_scalar_row_count" => length(summary.activities),
        ])],
        suggested_actions = ["Use evaluated scalar constraint-row references, or provide a geometry-specific residual convention in a domain plugin."],
    ))
    sort!(report.findings; by = finding -> (-Int(finding.severity), string(finding.code)))
    return report
end

"""Validate plugin-declared constraint-scale sources against a model snapshot."""
function _component_constraint_scale_semantics_findings(
    semantics::AbstractVector{<:ComponentConstraintScaleSemantics},
    model_constraints::AbstractVector{<:EntityRef},
)
    report = DiagnosticReport()
    known = Set(reference.index for reference in model_constraints if reference.kind == :constraint)
    unknown = EntityRef[]
    nlp_rows = EntityRef[]
    for item in semantics, source in item.constraints
        if source.kind == :constraint
            source.index in known || push!(unknown, source)
        elseif source.kind == :nlp_constraint
            push!(nlp_rows, source)
        end
    end
    if !isempty(unknown)
        push!(report, Finding(:component_constraint_scale_unknown_source;
            severity = SeverityError, domain = RepresentationalIssue,
            basis = StructuralProof, confidence = ConfidenceCertain,
            observation = "Constraint-scale metadata references $(length(unknown)) ordinary MOI constraint source(s) absent from the analyzed model.",
            why_it_matters = "A stale source cannot receive a structural residual-scale interpretation or be aligned reliably at an evaluation point.",
            evidence = [Evidence("Constraint-scale snapshot scope"; details = [
                "unknown_constraint_indices" => join(sort!(unique(source.index for source in unknown)), ","),
            ])],
            affected = unique(unknown),
            suggested_actions = ["Rebuild constraint-scale declarations from the analyzed model's current MOI constraint indices."],
        ))
    end
    if !isempty(nlp_rows)
        push!(report, Finding(:component_constraint_scale_nlp_source_runtime_only;
            severity = SeverityInfo, domain = RepresentationalIssue,
            basis = StructuralProof, confidence = ConfidenceCertain,
            observation = "$(length(nlp_rows)) constraint-scale declaration(s) reference evaluator-provided NLP rows that are validated only at numerical evaluation time.",
            why_it_matters = "NLP evaluator rows are not ordinary snapshot constraints, so the static layer retains their runtime-only provenance rather than claiming model-scope validation.",
            evidence = [Evidence("Constraint-scale NLP source scope"; details = [
                "nlp_row_indices" => join(sort!(unique(source.index for source in nlp_rows)), ","),
            ])],
            affected = unique(nlp_rows),
            suggested_actions = ["Supply an evaluation point to align these rows, or use ordinary MOI constraint sources when static scope validation is required."],
        ))
    end
    report.metadata[:component_constraint_scale_unknown_source_count] = string(length(unknown))
    report.metadata[:component_constraint_scale_nlp_runtime_source_count] = string(length(nlp_rows))
    return report
end

"""Run all generic scalar, coupled, and snapshot-scope constraint-scale checks."""
function analyze_component_constraint_scales(
    model::MOI.ModelLike,
    evaluation::NumericalEvaluation{T};
    mismatch_factor::Real = 1.0e3,
    feasibility_tolerance::Real = sqrt(eps(T)),
    active_tolerance::Real = sqrt(eps(T)),
) where {T<:AbstractFloat}
    semantics = component_constraint_scale_semantics(model)
    scalar_summary = constraint_feasibility_summary(
        model, evaluation;
        feasibility_tolerance = feasibility_tolerance,
        active_tolerance = active_tolerance,
    )
    coupled_summary = coupled_set_feasibility_summary(
        model, evaluation;
        feasibility_tolerance = feasibility_tolerance,
        active_tolerance = active_tolerance,
    )
    scalar_report = analyze_component_constraint_scales(
        semantics, scalar_summary; mismatch_factor = mismatch_factor,
    )
    coupled_report = analyze_component_constraint_scales(
        semantics, coupled_summary; mismatch_factor = mismatch_factor,
    )
    model_snapshot = snapshot(model)
    scope_report = _component_constraint_scale_semantics_findings(
        semantics, [_constraint_ref(record) for record in model_snapshot.constraints],
    )
    report = DiagnosticReport()
    append!(report.findings, scalar_report.findings)
    append!(report.findings, coupled_report.findings)
    append!(report.findings, scope_report.findings)
    for source in (scalar_report, coupled_report, scope_report)
        for (key, value) in source.metadata
            key == :stage && continue
            report.metadata[key] = value
        end
    end
    report.metadata[:stage] = "component_constraint_scales"
    sort!(report.findings; by = finding -> (-Int(finding.severity), string(finding.code)))
    return report
end

"""Evaluate a point, then run all generic constraint residual-scale checks."""
function analyze_component_constraint_scales(
    model::MOI.ModelLike,
    point::EvaluationPoint;
    cache::EvaluationCache = EvaluationCache(),
    relative_step::Real = cbrt(eps(eltype(point.values))),
    kwargs...,
)
    evaluation = evaluate_numerical(
        model, point;
        cache = cache,
        relative_step = relative_step,
    )
    return analyze_component_constraint_scales(model, evaluation; kwargs...)
end

"""Compare declared scales with supported SOC-family feasibility violations."""
function analyze_component_constraint_scales(
    semantics::AbstractVector{<:ComponentConstraintScaleSemantics},
    summary::CoupledSetFeasibilitySummary{T};
    mismatch_factor::Real = 1.0e3,
) where {T<:AbstractFloat}
    mismatch_factor > 1 && isfinite(mismatch_factor) || throw(ArgumentError(
        "mismatch_factor must be finite and greater than one",
    ))
    report = DiagnosticReport()
    report.metadata[:stage] = "component_constraint_scales"
    report.metadata[:component_coupled_constraint_scale_declaration_count] = string(length(semantics))
    report.metadata[:component_coupled_constraint_scale_source_count] = string(sum(
        (length(item.constraints) for item in semantics); init = 0,
    ))
    declarations_by_source = Dict{Tuple{Symbol,Int,Union{Nothing,Int}},Vector{ComponentConstraintScaleSemantics}}()
    for item in semantics, source in item.constraints
        push!(get!(declarations_by_source, _entity_row_key(source),
                   ComponentConstraintScaleSemantics[]), item)
    end
    for key in sort!(collect(Base.keys(declarations_by_source));
                     by = key -> (string(key[1]), key[2], something(key[3], 0)))
        declarations = declarations_by_source[key]
        length(declarations) <= 1 && continue
        reference = first(declarations).nominal_scale
        all(item -> isapprox(item.nominal_scale, reference;
                              rtol = sqrt(eps(Float64)), atol = 0.0), declarations) && continue
        labels = join(sort!(unique([
            "$(item.component_type):$(item.component_id)=$(item.nominal_scale)"
            for item in declarations
        ])), ", ")
        push!(report, Finding(:component_coupled_constraint_nominal_scale_conflict;
            severity = SeverityWarning, domain = RepresentationalIssue,
            basis = StructuralProof, confidence = ConfidenceCertain,
            observation = "Coupled constraint $(key[2]) has incompatible component residual-scale declarations.",
            why_it_matters = "One coupled feasibility margin cannot have a single physical tolerance interpretation when component declarations use different nominal scales.",
            evidence = [Evidence("Component coupled constraint-scale declarations";
                details = ["constraint" => key[2], "declarations" => labels])],
            affected = [EntityRef(key[1], key[2]; subindex = key[3])],
            suggested_actions = ["Align nominal residual scales or provide explicitly transformed component-level residual conventions."],
        ))
    end
    activities = Dict(_entity_row_key(item.source) => item for item in summary.activities)
    checked = 0
    unavailable = 0
    missing_source = 0
    unsupported_geometry = 0
    unavailable_residual = 0
    reported = Set{Tuple{Symbol,Int,Union{Nothing,Int},Float64}}()
    for item in semantics, source in item.constraints
        activity = get(activities, _entity_row_key(source), nothing)
        if isnothing(activity)
            unavailable += 1
            missing_source += 1
            continue
        elseif !(activity.set_kind in (
            :second_order_cone, :rotated_second_order_cone,
            :norm_one_cone, :norm_infinity_cone, :norm_cone,
            :norm_spectral_cone, :norm_nuclear_cone,
            :positive_semidefinite_cone_triangle,
            :scaled_positive_semidefinite_cone_triangle,
            :positive_semidefinite_cone_square,
            :hermitian_positive_semidefinite_cone_triangle,
            :scaled_hermitian_positive_semidefinite_cone_triangle,
            :power_cone, :dual_power_cone,
            :exponential_cone, :dual_exponential_cone,
            :geometric_mean_cone, :relative_entropy_cone,
            :logdet_cone_triangle, :logdet_cone_square,
            :scaled_logdet_cone_triangle,
            :rootdet_cone_triangle, :rootdet_cone_square,
            :scaled_rootdet_cone_triangle,
        ))
            unavailable += 1
            unsupported_geometry += 1
            continue
        elseif isnothing(activity.feasibility_violation)
            unavailable += 1
            unavailable_residual += 1
            continue
        end
        checked += 1
        ratio = activity.feasibility_violation / item.nominal_scale
        ratio > mismatch_factor || continue
        report_key = (_entity_row_key(source)..., item.nominal_scale)
        report_key in reported && continue
        push!(reported, report_key)
        declarations = join(sort!(unique([
            "$(candidate.component_type):$(candidate.component_id)" for candidate in
            get(declarations_by_source, _entity_row_key(source), ComponentConstraintScaleSemantics[]) if
            isapprox(candidate.nominal_scale, item.nominal_scale;
                     rtol = sqrt(eps(Float64)), atol = 0.0)
        ])), ", ")
        push!(report, Finding(:component_coupled_constraint_nominal_scale_mismatch;
            severity = SeverityWarning, domain = NumericalIssue,
            basis = LocalInference, confidence = ConfidenceHigh,
            observation = "$(activity.set_kind) constraint $(source.index) violation exceeds its declared nominal residual scale by a factor of $(ratio).",
            why_it_matters = "This uses the generic cone feasibility margin, not a raw vector-function value.",
            evidence = [Evidence("Declared coupled constraint residual scale"; details = ["components" => declarations, "violation" => activity.feasibility_violation, "nominal_scale" => item.nominal_scale, "ratio" => ratio])],
            affected = [source],
            suggested_actions = ["Check the declared cone residual scale and compare it with solver feasibility tolerances."],
        ))
    end
    report.metadata[:component_coupled_constraint_scale_checked_count] = string(checked)
    report.metadata[:component_coupled_constraint_scale_unavailable_count] = string(unavailable)
    report.metadata[:component_coupled_constraint_scale_missing_source_count] = string(missing_source)
    report.metadata[:component_coupled_constraint_scale_unsupported_geometry_count] = string(unsupported_geometry)
    report.metadata[:component_coupled_constraint_scale_unavailable_residual_count] = string(unavailable_residual)
    report.metadata[:component_coupled_constraint_scale_supported_geometry_count] = string(checked + unavailable_residual)
    unavailable == 0 || push!(report, Finding(:component_coupled_constraint_scale_alignment_unavailable;
        severity = SeverityInfo, domain = RepresentationalIssue,
        basis = StructuralProof, confidence = ConfidenceCertain,
        observation = "$(unavailable) declared component constraint scale(s) could not be aligned with a supported coupled-set feasibility margin.",
        why_it_matters = "The generic core does not compare a nominal residual scale with a raw vector-function value when the coupled-set geometry is unavailable or unsupported.",
        evidence = [Evidence("Coupled constraint-scale alignment"; details = [
            "unavailable_count" => unavailable,
            "evaluated_coupled_set_count" => length(summary.activities),
        ])],
        suggested_actions = ["Use a supported coupled-set source or provide an explicit geometry-specific residual convention in a domain plugin."],
    ))
    sort!(report.findings; by = finding -> (-Int(finding.severity), string(finding.code)))
    return report
end

function analyze_component_coordinate_scales(
    model::MOI.ModelLike,
    point::EvaluationPoint;
    kwargs...,
)
    report = analyze_component_coordinate_scales(
        component_coordinate_semantics(model), point; kwargs...,
    )
    port_report = _port_coordinate_scale_findings(
        component_port_coordinate_semantics(model),
        component_port_coordinate_maps(model),
        point;
        kwargs...,
    )
    append!(report.findings, port_report.findings)
    for (key, value) in port_report.metadata
        key == :stage && continue
        report.metadata[key] = value
    end
    sort!(report.findings; by = finding -> (-Int(finding.severity), string(finding.code)))
    return report
end

"""Compare declared port nominal scales only through simple explicit coordinate maps."""
function _port_coordinate_scale_findings(
    semantics::AbstractVector{<:PortCoordinateSemantics},
    coordinate_maps::AbstractVector{<:PortCoordinateMap},
    point::EvaluationPoint;
    mismatch_factor::Real = 1.0e3,
)
    mismatch_factor > 1 && isfinite(mismatch_factor) || throw(ArgumentError(
        "mismatch_factor must be finite and greater than one",
    ))
    report = DiagnosticReport()
    report.metadata[:component_port_nominal_scale_declaration_count] = string(count(
        item -> !isnothing(item.nominal_scale), semantics,
    ))
    values = Dict(zip(point.variables, point.values))
    maps_by_key = Dict{Tuple{Symbol,String,String},Vector{PortCoordinateMap}}()
    for map in coordinate_maps
        key = (map.component_type, map.component_id, map.port_id)
        push!(get!(maps_by_key, key, PortCoordinateMap[]), map)
    end
    checked = 0
    unavailable = 0
    direct_checks = Dict{MOI.VariableIndex,Vector{Tuple{PortCoordinateSemantics,Int,Float64,Float64}}}()
    for item in semantics
        isnothing(item.nominal_scale) && continue
        key = (item.component_type, item.component_id, item.port_id)
        maps = get(maps_by_key, key, PortCoordinateMap[])
        if isempty(maps)
            unavailable += 1
            continue
        end
        for map in maps
            for (row, variable) in enumerate(map.variables)
                haskey(values, variable) || continue
                nonzero = findall(value -> !iszero(value), view(map.terminal_to_variable, row, :))
                if length(nonzero) != 1
                    unavailable += 1
                    continue
                end
                nominal = abs(map.terminal_to_variable[row, only(nonzero)]) *
                          something(item.nominal_scale)
                isfinite(nominal) && nominal > 0 || (unavailable += 1; continue)
                checked += 1
                push!(get!(direct_checks, variable,
                          Tuple{PortCoordinateSemantics,Int,Float64,Float64}[]),
                      (item, only(nonzero),
                       Float64(map.terminal_to_variable[row, only(nonzero)]), Float64(nominal)))
            end
        end
    end
    for variable in sort!(collect(Base.keys(direct_checks)); by = index -> index.value)
        groups = Vector{Vector{Tuple{PortCoordinateSemantics,Int,Float64,Float64}}}()
        for check in direct_checks[variable]
            group_index = findfirst(group -> isapprox(
                check[4], first(group)[4]; rtol = sqrt(eps(Float64)), atol = 0.0,
            ), groups)
            isnothing(group_index) ? push!(groups, [check]) : push!(groups[group_index], check)
        end
        sort!(groups; by = group -> first(group)[4])
        for group in groups
            nominal = first(group)[4]
            value = values[variable]
            ratio = abs(value) / nominal
            (ratio > mismatch_factor || (!iszero(value) && ratio < inv(mismatch_factor))) || continue
            direction = ratio > mismatch_factor ? "larger" : "smaller"
            declarations = join(sort!(unique([
                "$(item.component_type):$(item.component_id):$(item.port_id)" for
                (item, _, _, _) in group
            ])), ", ")
            terminal_coordinates = join(sort!(unique(string(terminal) for
                (_, terminal, _, _) in group)), ", ")
            coefficients = join(sort!(unique(string(coefficient) for
                (_, _, coefficient, _) in group)), ", ")
            push!(report, Finding(:component_port_nominal_scale_mismatch;
                severity = SeverityWarning, domain = NumericalIssue,
                basis = LocalInference, confidence = ConfidenceHigh,
                observation = "Mapped port coordinate v$(variable.value) is $(direction) than its declared nominal scale by a factor of $(ratio).",
                why_it_matters = "This comparison uses explicit one-terminal-coordinate maps and is local numerical scale evidence, not a physical-limit claim.",
                evidence = [Evidence("Declared port coordinate scale"; details = [
                    "ports" => declarations,
                    "terminal_coordinates" => terminal_coordinates,
                    "terminal_to_variable_coefficients" => coefficients,
                    "value" => value,
                    "nominal_scale" => nominal,
                    "absolute_value_to_nominal_scale_ratio" => ratio,
                    "mismatch_factor" => mismatch_factor,
                ])],
                affected = [EntityRef(:variable, variable.value)],
                suggested_actions = ["Check the declared terminal scale and map coefficient, then inspect Jacobian scaling at this point before rescaling."],
            ))
        end
    end
    report.metadata[:component_port_nominal_scale_checked_variable_count] = string(checked)
    report.metadata[:component_port_nominal_scale_projection_unavailable_count] = string(unavailable)
    unavailable == 0 || push!(report, Finding(:component_port_nominal_scale_projection_unavailable;
        severity = SeverityInfo, domain = RepresentationalIssue,
        basis = StructuralProof, confidence = ConfidenceCertain,
        observation = "$(unavailable) nominal-scale port declaration(s) lack a directly usable one-terminal-coordinate map.",
        why_it_matters = "The generic core will not assign a scalar physical scale without an explicit map, or after a mixed terminal-coordinate transformation.",
        evidence = [Evidence("Port nominal-scale mapping"; details = ["unavailable_coordinate_count" => unavailable])],
        suggested_actions = ["Declare a one-coordinate map for direct scale comparison, or implement a domain-specific transformed-scale rule."],
    ))
    return report
end

function _component_port_metadata_findings(
    items::AbstractVector{<:ComponentPortMetadata};
    model_variables::Union{Nothing,AbstractVector{MOI.VariableIndex}} = nothing,
)
    report = DiagnosticReport()
    keys = [(item.component_type, item.component_id, item.port_id) for item in items]
    duplicate_keys = unique([key for key in keys if count(==(key), keys) > 1])
    for (component_type, component_id, port_id) in duplicate_keys
        push!(report, Finding(:duplicate_component_port_metadata;
            severity = SeverityWarning, domain = RepresentationalIssue,
            basis = StructuralProof, confidence = ConfidenceCertain,
            observation = "Port metadata declares $(component_type) '$component_id' port '$port_id' more than once.",
            why_it_matters = "Ambiguous port identity makes connection-map and terminal-mode interpretation unreliable.",
            evidence = [Evidence("Duplicate plugin port key"; details = ["component_type" => component_type, "component_id" => component_id, "port_id" => port_id])],
            suggested_actions = ["Provide one metadata record per stable component type, ID, and port ID."],
        ))
    end
    known_variables = isnothing(model_variables) ? nothing : Set(model_variables)
    for item in items
        expected_size = (length(item.terminal_labels), length(item.mode_labels))
        if size(item.connection_matrix) != expected_size
            push!(report, Finding(:component_port_metadata_connection_dimension_mismatch;
                severity = SeverityError, domain = RepresentationalIssue,
                basis = StructuralProof, confidence = ConfidenceCertain,
                observation = "Port metadata connection matrix has size $(size(item.connection_matrix)) but declared terminal/mode labels require $expected_size.",
                why_it_matters = "A dimension-mismatched connection map cannot be interpreted or composed safely.",
                evidence = [Evidence("Plugin port connection dimensions"; details = ["component_type" => item.component_type, "component_id" => item.component_id, "port_id" => item.port_id])],
                suggested_actions = ["Align connection-matrix rows with terminal labels and columns with mode labels."],
            ))
        end
        if !all(isfinite, item.connection_matrix)
            push!(report, Finding(:component_port_metadata_nonfinite_connection;
                severity = SeverityError, domain = RepresentationalIssue,
                basis = StructuralProof, confidence = ConfidenceCertain,
                observation = "Port metadata connection matrix contains non-finite coefficients.",
                why_it_matters = "Non-finite connection coefficients cannot support inspectable terminal-mode analysis.",
                evidence = [Evidence("Plugin port connection coefficients"; details = ["component_type" => item.component_type, "component_id" => item.component_id, "port_id" => item.port_id])],
                suggested_actions = ["Declare finite connection-matrix coefficients or omit the port until they are available."],
            ))
        else
            singular_values = svdvals(item.connection_matrix)
            scale = maximum(singular_values; init = zero(eltype(item.connection_matrix)))
            threshold = sqrt(eps(eltype(item.connection_matrix))) * scale
            connection_rank = count(value -> value > threshold, singular_values)
            maximum_rank = min(size(item.connection_matrix)...)
            if iszero(connection_rank)
                push!(report, Finding(:component_port_metadata_zero_connection_map;
                    severity = SeverityWarning, domain = RepresentationalIssue,
                    basis = StructuralProof, confidence = ConfidenceCertain,
                    observation = "Port metadata declares an all-zero connection map.",
                    why_it_matters = "A zero map exposes no declared terminal mode, which can indicate incomplete metadata or an intentionally disconnected port.",
                    evidence = [Evidence("Plugin port connection rank"; details = ["component_type" => item.component_type, "component_id" => item.component_id, "port_id" => item.port_id, "rank" => connection_rank, "maximum_rank" => maximum_rank])],
                    suggested_actions = ["Confirm that the port is intentionally disconnected or provide its finite connection map."],
                ))
            elseif connection_rank < maximum_rank
                push!(report, Finding(:component_port_metadata_connection_rank_deficient;
                    severity = SeverityInfo, domain = RepresentationalIssue,
                    basis = NumericalObservation, confidence = ConfidenceHigh,
                    observation = "Port metadata connection map has rank $connection_rank below its maximum possible rank $maximum_rank.",
                    why_it_matters = "The declaration contains terminal or mode directions that are not connected by this map. That may be an expected hidden mode, but its semantics must come from the plugin.",
                    evidence = [Evidence("Plugin port connection rank"; details = ["component_type" => item.component_type, "component_id" => item.component_id, "port_id" => item.port_id, "rank" => connection_rank, "maximum_rank" => maximum_rank, "threshold" => threshold])],
                    suggested_actions = ["Declare expected hidden modes or connection semantics before interpreting this rank deficiency physically."],
                ))
            end
        end
        duplicate_variables = unique([variable for variable in item.variables if count(==(variable), item.variables) > 1])
        if !isempty(duplicate_variables)
            push!(report, Finding(:component_port_metadata_duplicate_variables;
                severity = SeverityWarning, domain = RepresentationalIssue,
                basis = StructuralProof, confidence = ConfidenceCertain,
                observation = "Port metadata repeats $(length(duplicate_variables)) variable coordinate(s).",
                why_it_matters = "Repeated port coordinates make the declared scope ambiguous.",
                evidence = [Evidence("Duplicate plugin port coordinates")],
                affected = [EntityRef(:variable, variable.value) for variable in duplicate_variables],
                suggested_actions = ["Declare each port variable coordinate at most once."],
            ))
        end
        if !isnothing(known_variables)
            unknown_variables = [variable for variable in item.variables if !(variable in known_variables)]
            if !isempty(unknown_variables)
                push!(report, Finding(:component_port_metadata_unknown_variable;
                    severity = SeverityError, domain = RepresentationalIssue,
                    basis = StructuralProof, confidence = ConfidenceCertain,
                    observation = "Port metadata references $(length(unknown_variables)) variable coordinate(s) absent from the model.",
                    why_it_matters = "A stale port scope cannot be aligned with an analyzed model's coordinate system.",
                    evidence = [Evidence("Unknown plugin port coordinates")],
                    affected = [EntityRef(:variable, variable.value) for variable in unknown_variables],
                    suggested_actions = ["Rebuild port metadata after model construction."],
                ))
            end
        end
    end
    return report
end

function _component_port_nullspace_mode_findings(
    ports::AbstractVector{<:ComponentPortMetadata},
    modes::AbstractVector{<:PortNullspaceMode};
    relative_tolerance::Real = sqrt(eps(Float64)),
)
    report = DiagnosticReport()
    port_by_key = Dict(
        (port.component_type, port.component_id, port.port_id) => port for port in ports
    )
    named_mode_keys = [
        ((mode.component_type, mode.component_id, mode.port_id), mode.name)
        for mode in modes if !isnothing(mode.name)
    ]
    for key in unique([key for key in named_mode_keys if count(==(key), named_mode_keys) > 1])
        push!(report, Finding(:component_port_expected_nullspace_mode_duplicate_name;
            severity = SeverityWarning, domain = RepresentationalIssue,
            basis = StructuralProof, confidence = ConfidenceCertain,
            observation = "Component-port metadata declares the named null mode :$(key[2]) more than once for one port.",
            why_it_matters = "A named mode is intended to provide stable plugin provenance, so reuse on one port makes candidate identity ambiguous.",
            evidence = [Evidence("Duplicate component-port null-mode name"; details = [
                "component_type" => key[1][1], "component_id" => key[1][2],
                "port_id" => key[1][3], "mode_name" => key[2],
            ])],
            suggested_actions = ["Use a distinct stable name for each declared null direction on this port."],
        ))
    end
    for mode in modes
        key = (mode.component_type, mode.component_id, mode.port_id)
        port = get(port_by_key, key, nothing)
        if isnothing(port)
            push!(report, Finding(:component_port_expected_nullspace_mode_unaligned;
                severity = SeverityInfo, domain = RepresentationalIssue,
                basis = StructuralProof, confidence = ConfidenceCertain,
                observation = "Declared port nullspace mode cannot be aligned with a declared component port.",
                why_it_matters = "A connection-map nullspace comparison requires a stable component and port identity.",
                evidence = [Evidence("Declared port nullspace mode"; details = ["component_type" => mode.component_type, "component_id" => mode.component_id, "port_id" => mode.port_id, "mode_name" => something(mode.name, ""), "space" => mode.space])],
                suggested_actions = ["Declare the corresponding component port or correct the mode identity."],
            ))
            continue
        end
        expected_dimension = mode.space == :terminal ?
                             length(port.terminal_labels) : length(port.mode_labels)
        if length(mode.direction) != expected_dimension
            push!(report, Finding(:component_port_expected_nullspace_mode_dimension_mismatch;
                severity = SeverityError, domain = RepresentationalIssue,
                basis = StructuralProof, confidence = ConfidenceCertain,
                observation = "Declared $(mode.space)-space port null mode has dimension $(length(mode.direction)), but the port map expects $expected_dimension.",
                why_it_matters = "A direction can only be compared with a connection map in its declared coordinate space.",
                evidence = [Evidence("Declared port nullspace mode dimensions"; details = ["component_type" => mode.component_type, "component_id" => mode.component_id, "port_id" => mode.port_id, "mode_name" => something(mode.name, "")])],
                suggested_actions = ["Use one direction entry per declared terminal or mode label."],
            ))
            continue
        end
        T = eltype(port.connection_matrix)
        direction = T.(mode.direction)
        residual = mode.space == :terminal ?
                   norm(transpose(port.connection_matrix) * direction) :
                   norm(port.connection_matrix * direction)
        threshold = convert(T, relative_tolerance) *
                    max(one(T), norm(port.connection_matrix) * norm(direction))
        observed = residual <= threshold
        push!(report, Finding(
            observed ? :component_port_expected_nullspace_mode_observed :
                       :component_port_expected_nullspace_mode_not_observed;
            severity = SeverityInfo, domain = RepresentationalIssue,
            basis = observed ? PhysicalExpectation : LocalInference,
            confidence = observed ? ConfidenceHigh : ConfidenceMedium,
            observation = observed ?
                          "Declared $(mode.space)-space null mode is consistent with the component port connection map." :
                          "Declared $(mode.space)-space null mode is not consistent with the component port connection map.",
            why_it_matters = observed ?
                             "The declared hidden mode agrees with this plugin-supplied map, without validating its physical interpretation or network assembly." :
                             "A mismatch can reflect stale metadata, a connection convention error, or an intentionally operating-point-dependent declaration.",
            evidence = [Evidence("Component port nullspace comparison"; details = ["component_type" => mode.component_type, "component_id" => mode.component_id, "port_id" => mode.port_id, "mode_name" => something(mode.name, ""), "space" => mode.space, "residual_norm" => residual, "threshold" => threshold, "description" => mode.description])],
            suggested_actions = observed ?
                                ["Retain the declaration as port-level expected-mode evidence and compare it with network-level observed modes later."] :
                                ["Check terminal/mode ordering and connection conventions before changing the declared physical interpretation."],
        ))
    end
    return report
end

"""Validate opaque plugin semantic labels against named port-mode declarations."""
function _component_port_nullspace_mode_semantic_findings(
    modes::AbstractVector{<:PortNullspaceMode},
    semantics::AbstractVector{<:PortNullspaceModeSemantics},
)
    report = DiagnosticReport()
    mode_keys = Set(
        ((mode.component_type, mode.component_id, mode.port_id), mode.name)
        for mode in modes if !isnothing(mode.name)
    )
    semantic_keys = [
        ((item.component_type, item.component_id, item.port_id), item.mode_name)
        for item in semantics
    ]
    aligned = 0
    unaligned = 0
    for key in unique([key for key in semantic_keys if count(==(key), semantic_keys) > 1])
        push!(report, Finding(:component_port_nullspace_mode_semantics_duplicate;
            severity = SeverityWarning, domain = RepresentationalIssue,
            basis = StructuralProof, confidence = ConfidenceCertain,
            observation = "Plugin metadata assigns more than one semantic record to named port mode :$(key[2]) on one port.",
            why_it_matters = "Semantic labels are opaque to the generic core, but duplicate records make plugin provenance ambiguous.",
            evidence = [Evidence("Duplicate port-mode semantic label"; details = [
                "component_type" => key[1][1], "component_id" => key[1][2],
                "port_id" => key[1][3], "mode_name" => key[2],
            ])],
            suggested_actions = ["Keep one semantic record per named null mode and place any aliases in its description."],
        ))
    end
    for item in semantics
        key = ((item.component_type, item.component_id, item.port_id), item.mode_name)
        if key in mode_keys
            aligned += 1
            push!(report, Finding(:component_port_nullspace_mode_semantics_declared;
                severity = SeverityInfo, domain = RepresentationalIssue,
                basis = StructuralProof, confidence = ConfidenceHigh,
                observation = "Plugin declares opaque semantic category :$(item.category) for named port mode :$(item.mode_name).",
                why_it_matters = "The label provides inspectable plugin provenance beside generic structural and numerical evidence, without making the category a generic physical classification.",
                evidence = [Evidence("Declared port-mode semantic label"; details = [
                    "component_type" => item.component_type, "component_id" => item.component_id,
                    "port_id" => item.port_id, "mode_name" => item.mode_name,
                    "category" => item.category, "description" => item.description,
                ])],
                suggested_actions = ["Use the domain plugin to interpret this category together with the recorded generic evidence."],
            ))
            continue
        end
        unaligned += 1
        push!(report, Finding(:component_port_nullspace_mode_semantics_unaligned;
            severity = SeverityWarning, domain = RepresentationalIssue,
            basis = StructuralProof, confidence = ConfidenceHigh,
            observation = "Plugin semantic category :$(item.category) references named port mode :$(item.mode_name), but that mode is not declared on the same port.",
            why_it_matters = "The generic core cannot associate an opaque physical label with structural or numerical evidence unless its named direction exists.",
            evidence = [Evidence("Unaligned port-mode semantic label"; details = [
                "component_type" => item.component_type, "component_id" => item.component_id,
                "port_id" => item.port_id, "mode_name" => item.mode_name,
                "category" => item.category, "description" => item.description,
            ])],
            suggested_actions = ["Declare the matching named PortNullspaceMode, or correct the semantic record's component, port, and name."],
        ))
    end
    report.metadata[:component_port_nullspace_mode_semantics_aligned_count] = string(aligned)
    report.metadata[:component_port_nullspace_mode_semantics_unaligned_count] = string(unaligned)
    return report
end

"""Report whether declared component terminal modes have an explicit model-coordinate image."""
function _component_port_mode_coordinate_projection_findings(
    ports::AbstractVector{<:ComponentPortMetadata},
    modes::AbstractVector{<:PortNullspaceMode},
    coordinate_maps::AbstractVector{<:PortCoordinateMap};
    relative_tolerance::Real = sqrt(eps(Float64)),
)
    report = DiagnosticReport()
    port_by_key = Dict(
        (port.component_type, port.component_id, port.port_id) => port for port in ports
    )
    map_by_key = Dict(
        (map.component_type, map.component_id, map.port_id) => map for map in coordinate_maps
    )
    for mode in modes
        key = (mode.component_type, mode.component_id, mode.port_id)
        if mode.space != :terminal
            push!(report, Finding(:component_port_mode_coordinate_projection_unavailable;
                severity = SeverityInfo, domain = RepresentationalIssue,
                basis = StructuralProof, confidence = ConfidenceCertain,
                observation = "Declared mode-space component-port null direction has no generic model-coordinate projection.",
                why_it_matters = "The generic port contract maps terminal coordinates only; inferring a mode-to-variable convention would make the evidence non-inspectable.",
                evidence = [Evidence("Component port mode-coordinate projection"; details = ["component_type" => mode.component_type, "component_id" => mode.component_id, "port_id" => mode.port_id, "space" => mode.space])],
                suggested_actions = ["Add a plugin-specific mode-to-variable convention if this internal mode should be compared with numerical model nullspaces."],
            ))
            continue
        end
        port, map = get(port_by_key, key, nothing), get(map_by_key, key, nothing)
        if isnothing(port) || isnothing(map)
            push!(report, Finding(:component_port_mode_coordinate_projection_unavailable;
                severity = SeverityInfo, domain = RepresentationalIssue,
                basis = StructuralProof, confidence = ConfidenceCertain,
                observation = "Declared terminal-space component-port null direction has no aligned terminal-to-variable map.",
                why_it_matters = "A port-level direction cannot be compared with a Jacobian until its model-variable coordinates are declared.",
                evidence = [Evidence("Component port mode-coordinate projection"; details = ["component_type" => mode.component_type, "component_id" => mode.component_id, "port_id" => mode.port_id, "space" => mode.space])],
                suggested_actions = ["Declare one finite, dimension-aligned PortCoordinateMap for this terminal port."],
            ))
            continue
        end
        valid_dimensions = length(mode.direction) == length(port.terminal_labels) &&
                           size(map.terminal_to_variable) ==
                           (length(map.variables), length(port.terminal_labels))
        (valid_dimensions && all(isfinite, map.terminal_to_variable)) || continue
        projected = map.terminal_to_variable * mode.direction
        threshold = relative_tolerance * max(1.0, norm(mode.direction))
        visible = norm(projected) > threshold
        push!(report, Finding(
            visible ? :component_port_mode_coordinate_projection_available :
                      :component_port_mode_hidden_from_model_coordinates;
            severity = SeverityInfo, domain = RepresentationalIssue,
            basis = StructuralProof, confidence = ConfidenceHigh,
            observation = visible ?
                          "Declared terminal-space component-port null direction projects into $(length(map.variables)) model coordinate(s)." :
                          "Declared terminal-space component-port null direction is hidden by the supplied model-coordinate map.",
            why_it_matters = visible ?
                             "The direction is eligible for later local Jacobian and active-set comparisons, without validating its physical interpretation." :
                             "A port-level hidden direction must not be treated as a model-variable gauge when its declared coordinate image is zero.",
            evidence = [Evidence("Component port mode-coordinate projection"; details = ["component_type" => mode.component_type, "component_id" => mode.component_id, "port_id" => mode.port_id, "projected_norm" => norm(projected), "visibility_threshold" => threshold])],
            affected = [EntityRef(:variable, variable.value) for variable in map.variables],
            suggested_actions = visible ?
                                ["Compare this candidate against local numerical nullspaces at relevant evaluation points."] :
                                ["Document the direction as intentionally internal, or supply a different coordinate convention if it should be observable."],
        ))
    end
    return report
end

function _component_port_connection_findings(
    ports::AbstractVector{<:ComponentPortMetadata},
    connections::AbstractVector{<:PortConnectionMetadata},
)
    report = DiagnosticReport()
    port_by_key = Dict(
        (port.component_type, port.component_id, port.port_id) => port for port in ports
    )
    keys = [
        ((item.from_component_type, item.from_component_id, item.from_port_id),
         (item.to_component_type, item.to_component_id, item.to_port_id))
        for item in connections
    ]
    for key in unique([key for key in keys if count(==(key), keys) > 1])
        push!(report, Finding(:duplicate_component_port_connection;
            severity = SeverityWarning, domain = RepresentationalIssue,
            basis = StructuralProof, confidence = ConfidenceCertain,
            observation = "Port connection metadata declares the same directed endpoint pair more than once.",
            why_it_matters = "Duplicate directed maps make compositional port topology ambiguous.",
            evidence = [Evidence("Duplicate plugin port connection"; details = ["from" => join(string.(key[1]), ":"), "to" => join(string.(key[2]), ":")])],
            suggested_actions = ["Provide one directed map per source and destination port pair."],
        ))
    end
    for item in connections
        from_key = (item.from_component_type, item.from_component_id, item.from_port_id)
        to_key = (item.to_component_type, item.to_component_id, item.to_port_id)
        from_port = get(port_by_key, from_key, nothing)
        to_port = get(port_by_key, to_key, nothing)
        if isnothing(from_port) || isnothing(to_port)
            push!(report, Finding(:component_port_connection_unaligned;
                severity = SeverityError, domain = RepresentationalIssue,
                basis = StructuralProof, confidence = ConfidenceCertain,
                observation = "Port connection metadata references a source or destination port that was not declared.",
                why_it_matters = "A network connection map cannot be composed without both named port declarations.",
                evidence = [Evidence("Plugin port connection endpoints"; details = ["from" => join(string.(from_key), ":"), "to" => join(string.(to_key), ":")])],
                suggested_actions = ["Declare both endpoint ports with component_port_metadata before declaring their connection."],
            ))
            continue
        end
        expected_size = (length(to_port.terminal_labels), length(from_port.terminal_labels))
        if size(item.connection_matrix) != expected_size
            push!(report, Finding(:component_port_connection_dimension_mismatch;
                severity = SeverityError, domain = RepresentationalIssue,
                basis = StructuralProof, confidence = ConfidenceCertain,
                observation = "Port connection matrix has size $(size(item.connection_matrix)) but endpoint terminal scopes require $expected_size.",
                why_it_matters = "A dimension-mismatched connection map cannot compose the declared terminal coordinates.",
                evidence = [Evidence("Plugin port connection dimensions"; details = ["from" => join(string.(from_key), ":"), "to" => join(string.(to_key), ":")])],
                suggested_actions = ["Use destination-terminal rows and source-terminal columns in the declared connection map."],
            ))
        end
        if !all(isfinite, item.connection_matrix)
            push!(report, Finding(:component_port_connection_nonfinite;
                severity = SeverityError, domain = RepresentationalIssue,
                basis = StructuralProof, confidence = ConfidenceCertain,
                observation = "Port connection metadata contains non-finite coefficients.",
                why_it_matters = "Non-finite connection coefficients prevent inspectable topology composition.",
                evidence = [Evidence("Plugin port connection coefficients")],
                suggested_actions = ["Declare finite connection-map coefficients."],
            ))
        end
    end
    return report
end

"""Validate plugin-declared terminal-to-model-coordinate maps without inferring physics."""
function _component_port_coordinate_map_findings(
    ports::AbstractVector{<:ComponentPortMetadata},
    maps::AbstractVector{<:PortCoordinateMap};
    model_variables::Union{Nothing,AbstractVector{MOI.VariableIndex}} = nothing,
)
    report = DiagnosticReport()
    port_by_key = Dict(
        (port.component_type, port.component_id, port.port_id) => port for port in ports
    )
    keys = [(item.component_type, item.component_id, item.port_id) for item in maps]
    for key in unique([key for key in keys if count(==(key), keys) > 1])
        push!(report, Finding(:duplicate_component_port_coordinate_map;
            severity = SeverityWarning, domain = RepresentationalIssue,
            basis = StructuralProof, confidence = ConfidenceCertain,
            observation = "Port coordinate metadata declares $(key[1]) '$(key[2])' port '$(key[3])' more than once.",
            why_it_matters = "More than one terminal-to-variable convention for a port makes any projected topology mode ambiguous.",
            evidence = [Evidence("Duplicate plugin port coordinate map"; details = ["component_type" => key[1], "component_id" => key[2], "port_id" => key[3]])],
            suggested_actions = ["Provide one terminal-to-variable map per stable component port."],
        ))
    end
    known_variables = isnothing(model_variables) ? nothing : Set(model_variables)
    for item in maps
        key = (item.component_type, item.component_id, item.port_id)
        port = get(port_by_key, key, nothing)
        if isnothing(port)
            push!(report, Finding(:component_port_coordinate_map_unaligned;
                severity = SeverityError, domain = RepresentationalIssue,
                basis = StructuralProof, confidence = ConfidenceCertain,
                observation = "A terminal-to-variable map references a component port that was not declared.",
                why_it_matters = "The terminal-coordinate dimension and ordering cannot be inspected without the corresponding port declaration.",
                evidence = [Evidence("Plugin port coordinate-map endpoint"; details = ["component_type" => item.component_type, "component_id" => item.component_id, "port_id" => item.port_id])],
                suggested_actions = ["Declare the component port with component_port_metadata before mapping it to model variables."],
            ))
        elseif size(item.terminal_to_variable) != (length(item.variables), length(port.terminal_labels))
            expected = (length(item.variables), length(port.terminal_labels))
            push!(report, Finding(:component_port_coordinate_map_dimension_mismatch;
                severity = SeverityError, domain = RepresentationalIssue,
                basis = StructuralProof, confidence = ConfidenceCertain,
                observation = "A terminal-to-variable map has size $(size(item.terminal_to_variable)) but its variable and terminal scopes require $expected.",
                why_it_matters = "A projected port direction is only meaningful when map rows are model variables and columns are the declared terminal coordinates.",
                evidence = [Evidence("Plugin port coordinate-map dimensions"; details = ["component_type" => item.component_type, "component_id" => item.component_id, "port_id" => item.port_id])],
                suggested_actions = ["Use one row per declared model variable and one column per declared terminal label."],
            ))
        end
        if !all(isfinite, item.terminal_to_variable)
            push!(report, Finding(:component_port_coordinate_map_nonfinite;
                severity = SeverityError, domain = RepresentationalIssue,
                basis = StructuralProof, confidence = ConfidenceCertain,
                observation = "A terminal-to-variable map contains non-finite coefficients.",
                why_it_matters = "Non-finite coefficients cannot be used to project topology directions into model coordinates.",
                evidence = [Evidence("Plugin port coordinate-map coefficients"; details = ["component_type" => item.component_type, "component_id" => item.component_id, "port_id" => item.port_id])],
                suggested_actions = ["Declare finite terminal-to-variable coefficients."],
            ))
        end
        duplicate_variables = unique([variable for variable in item.variables if count(==(variable), item.variables) > 1])
        if !isempty(duplicate_variables)
            push!(report, Finding(:component_port_coordinate_map_duplicate_variables;
                severity = SeverityWarning, domain = RepresentationalIssue,
                basis = StructuralProof, confidence = ConfidenceCertain,
                observation = "A terminal-to-variable map repeats $(length(duplicate_variables)) model coordinate(s).",
                why_it_matters = "Repeated rows leave the intended coordinate convention ambiguous.",
                evidence = [Evidence("Duplicate plugin port coordinate-map variables")],
                affected = [EntityRef(:variable, variable.value) for variable in duplicate_variables],
                suggested_actions = ["Declare each mapped model variable at most once per port."],
            ))
        end
        if !isnothing(known_variables)
            unknown_variables = [variable for variable in item.variables if !(variable in known_variables)]
            if !isempty(unknown_variables)
                push!(report, Finding(:component_port_coordinate_map_unknown_variable;
                    severity = SeverityError, domain = RepresentationalIssue,
                    basis = StructuralProof, confidence = ConfidenceCertain,
                    observation = "A terminal-to-variable map references $(length(unknown_variables)) model coordinate(s) absent from the model.",
                    why_it_matters = "A stale coordinate map cannot be compared with numerical model modes.",
                    evidence = [Evidence("Unknown plugin port coordinate-map variables")],
                    affected = [EntityRef(:variable, variable.value) for variable in unknown_variables],
                    suggested_actions = ["Rebuild coordinate maps after model construction."],
                ))
            end
        end
    end
    return report
end

function _component_port_coordinate_semantics_findings(
    ports::AbstractVector{<:ComponentPortMetadata},
    semantics::AbstractVector{<:PortCoordinateSemantics},
    coordinate_maps::AbstractVector{<:PortCoordinateMap} = PortCoordinateMap[],
)
    report = DiagnosticReport()
    port_keys = Set((port.component_type, port.component_id, port.port_id) for port in ports)
    semantic_keys = [(item.component_type, item.component_id, item.port_id) for item in semantics]
    for key in unique([key for key in semantic_keys if count(==(key), semantic_keys) > 1])
        push!(report, Finding(:duplicate_component_port_coordinate_semantics;
            severity = SeverityWarning, domain = RepresentationalIssue,
            basis = StructuralProof, confidence = ConfidenceCertain,
            observation = "Port coordinate semantics declares $(key[1]) '$(key[2])' port '$(key[3])' more than once.",
            why_it_matters = "Competing quantity or representation declarations make later physical interpretation ambiguous.",
            evidence = [Evidence("Duplicate port coordinate semantics")],
            suggested_actions = ["Provide one semantics declaration per stable component port."],
        ))
    end
    maps_by_key = Dict{Tuple{Symbol,String,String},Vector{PortCoordinateMap}}()
    for map in coordinate_maps
        key = (map.component_type, map.component_id, map.port_id)
        push!(get!(maps_by_key, key, PortCoordinateMap[]), map)
    end
    variables_to_semantics = Dict{MOI.VariableIndex,Vector{PortCoordinateSemantics}}()
    for item in semantics
        key = (item.component_type, item.component_id, item.port_id)
        for map in get(maps_by_key, key, PortCoordinateMap[]), variable in map.variables
            push!(get!(variables_to_semantics, variable, PortCoordinateSemantics[]), item)
        end
    end
    for variable in sort!(collect(Base.keys(variables_to_semantics)); by = index -> index.value)
        declarations = variables_to_semantics[variable]
        signatures = unique([
            (item.quantity, item.representation, Tuple(sort!(collect(item.units); by = first)))
            for item in declarations
        ])
        length(signatures) <= 1 && continue
        port_labels = sort!(unique([
            "$(item.component_type):$(item.component_id):$(item.port_id)" for item in declarations
        ]))
        descriptions = sort!(unique([
            "$(signature[1])/$(signature[2])" *
            (isempty(signature[3]) ? "" : " [" * join(("$(first(unit))=$(last(unit))" for unit in signature[3]), ", ") * "]")
            for signature in signatures
        ]))
        push!(report, Finding(:component_port_coordinate_semantics_variable_conflict;
            severity = SeverityWarning, domain = RepresentationalIssue,
            basis = StructuralProof, confidence = ConfidenceCertain,
            observation = "Model variable $(variable.value) has $(length(signatures)) incompatible port-coordinate semantics declarations.",
            why_it_matters = "A shared terminal-to-model coordinate cannot receive one physical-scaling or tolerance interpretation until the plugin resolves the competing declarations.",
            evidence = [Evidence("Conflicting port coordinate semantics"; details = [
                "variable" => variable.value,
                "ports" => join(port_labels, ", "),
                "semantics" => join(descriptions, " | "),
            ])],
            affected = [EntityRef(:variable, variable.value)],
            suggested_actions = ["Use one quantity, representation, and unit convention for this shared coordinate, or introduce an explicit transformation between terminal and model coordinates."],
        ))
    end
    effective_scales = Dict{MOI.VariableIndex,Vector{Tuple{PortCoordinateSemantics,Float64}}}()
    for item in semantics
        isnothing(item.nominal_scale) && continue
        key = (item.component_type, item.component_id, item.port_id)
        for map in get(maps_by_key, key, PortCoordinateMap[]), (row, variable) in enumerate(map.variables)
            nonzero = findall(value -> !iszero(value), view(map.terminal_to_variable, row, :))
            length(nonzero) == 1 || continue
            scale = abs(map.terminal_to_variable[row, only(nonzero)]) *
                    something(item.nominal_scale)
            isfinite(scale) && scale > 0 || continue
            push!(get!(effective_scales, variable, Tuple{PortCoordinateSemantics,Float64}[]),
                  (item, Float64(scale)))
        end
    end
    for variable in sort!(collect(Base.keys(effective_scales)); by = index -> index.value)
        declarations = effective_scales[variable]
        length(declarations) > 1 || continue
        reference = first(declarations)[2]
        all(item -> isapprox(item[2], reference; rtol = sqrt(eps(Float64)), atol = 0.0), declarations) && continue
        labels = join(sort!(unique([
            "$(item.component_type):$(item.component_id):$(item.port_id)=$(scale)" for
            (item, scale) in declarations
        ])), ", ")
        push!(report, Finding(:component_port_coordinate_nominal_scale_conflict;
            severity = SeverityWarning, domain = RepresentationalIssue,
            basis = StructuralProof, confidence = ConfidenceCertain,
            observation = "Model variable $(variable.value) receives incompatible effective nominal scales from mapped port declarations.",
            why_it_matters = "A shared model coordinate cannot have one physical scaling or tolerance interpretation when explicit port maps imply different coordinate scales.",
            evidence = [Evidence("Mapped port nominal scales"; details = [
                "variable" => variable.value,
                "effective_scales" => labels,
            ])],
            affected = [EntityRef(:variable, variable.value)],
            suggested_actions = ["Align port nominal scales after map coefficients, or split the shared model coordinate with an explicit transformation."],
        ))
    end
    for item in semantics
        isnothing(item.nominal_scale) && continue
        key = (item.component_type, item.component_id, item.port_id)
        mixed_rows = Tuple{PortCoordinateMap,Int}[]
        for map in get(maps_by_key, key, PortCoordinateMap[]), row in axes(map.terminal_to_variable, 1)
            nonzero = findall(value -> !iszero(value), view(map.terminal_to_variable, row, :))
            length(nonzero) == 1 || push!(mixed_rows, (map, row))
        end
        isempty(mixed_rows) && continue
        rows = join(sort!(unique([
            "v$(map.variables[row].value)" for (map, row) in mixed_rows
        ])), ", ")
        push!(report, Finding(:component_port_coordinate_nominal_scale_mixed_projection;
            severity = SeverityInfo, domain = RepresentationalIssue,
            basis = StructuralProof, confidence = ConfidenceCertain,
            observation = "Port nominal scale for $(item.component_type) '$(item.component_id)' port '$(item.port_id)' cannot be generically projected onto $(length(mixed_rows)) mixed terminal-to-model coordinate row(s).",
            why_it_matters = "A scalar terminal scale does not determine a scalar scale for a mixed-coordinate transformation without a domain-specific norm or coordinate convention.",
            evidence = [Evidence("Port nominal-scale map projection"; details = [
                "component_type" => item.component_type,
                "component_id" => item.component_id,
                "port_id" => item.port_id,
                "nominal_scale" => something(item.nominal_scale),
                "model_variables" => rows,
            ])],
            affected = [EntityRef(:variable, map.variables[row].value) for (map, row) in mixed_rows],
            suggested_actions = ["Declare direct terminal-coordinate maps for generic scale checks, or implement a domain-specific transformed-scale rule."],
        ))
    end
    for item in semantics
        key = (item.component_type, item.component_id, item.port_id)
        key in port_keys || push!(report, Finding(:component_port_coordinate_semantics_unaligned;
            severity = SeverityError, domain = RepresentationalIssue,
            basis = StructuralProof, confidence = ConfidenceCertain,
            observation = "Port coordinate semantics references a component port that was not declared.",
            why_it_matters = "A physical coordinate convention cannot be checked or composed without a matching port identity.",
            evidence = [Evidence("Port coordinate semantics endpoint"; details = ["component_type" => item.component_type, "component_id" => item.component_id, "port_id" => item.port_id])],
            suggested_actions = ["Declare the component port before attaching coordinate semantics."],
        ))
        haskey(maps_by_key, key) ||
            push!(report, Finding(:component_port_coordinate_semantics_unmapped;
                severity = SeverityInfo, domain = RepresentationalIssue,
                basis = StructuralProof, confidence = ConfidenceCertain,
                observation = "Declared $(item.quantity) port semantics has no terminal-to-model-coordinate map.",
                why_it_matters = "Physical coordinate meaning cannot be compared with numerical model modes until the plugin declares its MOI-variable bridge.",
                evidence = [Evidence("Port coordinate semantics mapping"; details = ["component_type" => item.component_type, "component_id" => item.component_id, "port_id" => item.port_id, "quantity" => item.quantity, "representation" => item.representation])],
                suggested_actions = ["Add a PortCoordinateMap when this terminal convention should participate in model-coordinate diagnostics."],
            ))
        if item.quantity != :generic && isempty(item.units)
            push!(report, Finding(:component_port_coordinate_semantics_units_unspecified;
                severity = SeverityInfo, domain = RepresentationalIssue,
                basis = StructuralProof, confidence = ConfidenceCertain,
                observation = "Declared $(item.quantity) port semantics has no unit convention.",
                why_it_matters = "The terminal coordinates remain structurally usable, but scaling and tolerance interpretations cannot be related to physical units.",
                evidence = [Evidence("Port coordinate semantics units"; details = ["component_type" => item.component_type, "component_id" => item.component_id, "port_id" => item.port_id, "quantity" => item.quantity])],
                suggested_actions = ["Declare a unit convention such as p.u., kV, A, or MVA before requesting physical scaling interpretation."],
            ))
        end
    end
    return report
end

"""Validate agreement between component-coordinate and mapped port-coordinate semantics."""
function _component_port_coordinate_semantics_cross_layer_findings(
    component_semantics::AbstractVector{<:ComponentCoordinateSemantics},
    port_semantics::AbstractVector{<:PortCoordinateSemantics},
    coordinate_maps::AbstractVector{<:PortCoordinateMap} = PortCoordinateMap[],
)
    report = DiagnosticReport()
    component_by_variable = Dict{MOI.VariableIndex,Vector{ComponentCoordinateSemantics}}()
    for item in component_semantics, variable in item.variables
        push!(get!(component_by_variable, variable, ComponentCoordinateSemantics[]), item)
    end
    maps_by_key = Dict{Tuple{Symbol,String,String},Vector{PortCoordinateMap}}()
    for map in coordinate_maps
        key = (map.component_type, map.component_id, map.port_id)
        push!(get!(maps_by_key, key, PortCoordinateMap[]), map)
    end
    ports_by_variable = Dict{MOI.VariableIndex,Vector{PortCoordinateSemantics}}()
    port_scales_by_variable = Dict{MOI.VariableIndex,Vector{Tuple{PortCoordinateSemantics,Union{Nothing,Float64}}}}()
    for item in port_semantics
        key = (item.component_type, item.component_id, item.port_id)
        for map in get(maps_by_key, key, PortCoordinateMap[]), (row, variable) in enumerate(map.variables)
            push!(get!(ports_by_variable, variable, PortCoordinateSemantics[]), item)
            nonzero = findall(value -> !iszero(value), view(map.terminal_to_variable, row, :))
            length(nonzero) == 1 || continue
            scale = isnothing(item.nominal_scale) ? nothing :
                    abs(map.terminal_to_variable[row, only(nonzero)]) *
                    something(item.nominal_scale)
            !isnothing(scale) && (!isfinite(scale) || scale <= 0) && continue
            push!(get!(port_scales_by_variable, variable,
                      Tuple{PortCoordinateSemantics,Union{Nothing,Float64}}[]),
                  (item, isnothing(scale) ? nothing : Float64(scale)))
        end
    end
    shared_variables = sort!(collect(intersect(
        Set(Base.keys(component_by_variable)), Set(Base.keys(ports_by_variable)),
    )); by = index -> index.value)
    for variable in shared_variables
        component_declarations = component_by_variable[variable]
        port_declarations = ports_by_variable[variable]
        signatures = unique(vcat(
            [(item.quantity, item.representation, Tuple(sort!(collect(item.units); by = first)))
             for item in component_declarations],
            [(item.quantity, item.representation, Tuple(sort!(collect(item.units); by = first)))
             for item in port_declarations],
        ))
        length(signatures) <= 1 && continue
        component_labels = sort!(unique([
            "$(item.component_type):$(item.component_id)" for item in component_declarations
        ]))
        port_labels = sort!(unique([
            "$(item.component_type):$(item.component_id):$(item.port_id)" for item in port_declarations
        ]))
        descriptions = sort!(unique([
            "$(signature[1])/$(signature[2])" *
            (isempty(signature[3]) ? "" : " [" * join(("$(first(unit))=$(last(unit))" for unit in signature[3]), ", ") * "]")
            for signature in signatures
        ]))
        push!(report, Finding(:component_port_coordinate_semantics_cross_layer_conflict;
            severity = SeverityWarning, domain = RepresentationalIssue,
            basis = StructuralProof, confidence = ConfidenceCertain,
            observation = "Model variable $(variable.value) has incompatible component- and port-coordinate semantics declarations.",
            why_it_matters = "A terminal map is an explicit bridge to model coordinates, so inconsistent labels across that bridge make physical scaling and tolerance interpretation ambiguous.",
            evidence = [Evidence("Cross-layer coordinate semantics conflict"; details = [
                "variable" => variable.value,
                "components" => join(component_labels, ", "),
                "ports" => join(port_labels, ", "),
                "semantics" => join(descriptions, " | "),
            ])],
            affected = [EntityRef(:variable, variable.value)],
            suggested_actions = ["Align the component and port quantity, representation, and unit declarations, or introduce an explicit transformed coordinate."],
        ))
    end
    scale_shared_variables = sort!(collect(intersect(
        Set(Base.keys(component_by_variable)), Set(Base.keys(port_scales_by_variable)),
    )); by = index -> index.value)
    for variable in scale_shared_variables
        component_declarations = component_by_variable[variable]
        port_declarations = port_scales_by_variable[variable]
        # An omitted component scale is intentionally not interpreted as a
        # conflicting physical declaration. Plugins may add a port scale
        # incrementally; warn only once the component layer makes an explicit
        # comparison possible.
        any(!isnothing, (item.nominal_scale for item in component_declarations)) || continue
        scales = Union{Nothing,Float64}[item.nominal_scale for item in component_declarations]
        append!(scales, Union{Nothing,Float64}[scale for (_, scale) in port_declarations])
        reference = first(scales)
        compatible = !isnothing(reference) && all(scale ->
            !isnothing(scale) && isapprox(scale, reference; rtol = sqrt(eps(Float64)), atol = 0.0),
            scales,
        )
        compatible && continue
        labels = String[
            "component $(item.component_type):$(item.component_id)=$(something(item.nominal_scale, "unspecified"))"
            for item in component_declarations
        ]
        append!(labels, [
            "port $(item.component_type):$(item.component_id):$(item.port_id)=$(something(scale, "unspecified"))"
            for (item, scale) in port_declarations
        ])
        push!(report, Finding(:component_port_coordinate_nominal_scale_cross_layer_conflict;
            severity = SeverityWarning, domain = RepresentationalIssue,
            basis = StructuralProof, confidence = ConfidenceCertain,
            observation = "Model variable $(variable.value) has incompatible component and map-adjusted port nominal-scale declarations.",
            why_it_matters = "A direct terminal map bridges these declarations to one model coordinate, so incompatible or omitted nominal scales leave its physical scaling and tolerance interpretation ambiguous.",
            evidence = [Evidence("Cross-layer nominal-scale conflict"; details = [
                "variable" => variable.value,
                "nominal_scales" => join(sort!(unique(labels)), " | "),
            ])],
            affected = [EntityRef(:variable, variable.value)],
            suggested_actions = ["Align the component nominal scale with the map-adjusted port scale, or declare an explicit transformed-coordinate convention."],
        ))
    end
    return report
end

"""
    port_topology_coordinate_projection(ports, connections, coordinate_maps; ...)

Project a plugin-declared terminal-coordinate topology nullspace through explicit
terminal-to-model-variable maps. Repeated declarations for one model variable
must agree on every topology-nullspace direction. The result is candidate
expected model-coordinate freedom only: it does not establish a physical gauge
or compare the candidate with an observed Jacobian nullspace.
"""
function port_topology_coordinate_projection(
    ports::AbstractVector{<:ComponentPortMetadata{T}},
    connections::AbstractVector{<:PortConnectionMetadata{T}},
    coordinate_maps::AbstractVector{<:PortCoordinateMap{T}};
    relative_tolerance::Real = sqrt(eps(T)),
) where {T<:AbstractFloat}
    topology = port_topology_nullspace(
        ports, connections; relative_tolerance = relative_tolerance,
    )
    empty_projection(reason) = PortTopologyCoordinateProjection{T}(
        false, reason, MOI.VariableIndex[], topology, zeros(T, 0, 0), zero(T),
    )
    topology.available || return empty_projection(something(topology.reason, "topology unavailable"))
    port_by_key = Dict(
        (port.component_type, port.component_id, port.port_id) => port for port in ports
    )
    offset_by_key = Dict{Tuple{Symbol,String,String},Int}()
    offset = 0
    for port in ports
        key = (port.component_type, port.component_id, port.port_id)
        offset_by_key[key] = offset + 1
        offset += length(port.terminal_labels)
    end
    rows_by_variable = Dict{MOI.VariableIndex,Vector{Vector{T}}}()
    seen_port_keys = Set{Tuple{Symbol,String,String}}()
    for map in coordinate_maps
        key = (map.component_type, map.component_id, map.port_id)
        haskey(port_by_key, key) || return empty_projection("coordinate map endpoint is not a declared port")
        key in seen_port_keys && return empty_projection("duplicate coordinate map for one port")
        push!(seen_port_keys, key)
        port = port_by_key[key]
        size(map.terminal_to_variable) == (length(map.variables), length(port.terminal_labels)) ||
            return empty_projection("coordinate-map dimensions do not match its port")
        all(isfinite, map.terminal_to_variable) ||
            return empty_projection("coordinate map contains non-finite coefficients")
        start = offset_by_key[key]
        for (row, variable) in enumerate(map.variables)
            lifted = zeros(T, offset)
            lifted[start:(start + length(port.terminal_labels) - 1)] .= map.terminal_to_variable[row, :]
            push!(get!(rows_by_variable, variable, Vector{Vector{T}}()), lifted)
        end
    end
    variables = sort!(collect(keys(rows_by_variable)); by = variable -> variable.value)
    projected = zeros(T, length(variables), size(topology.nullspace, 2))
    maximum_residual = zero(T)
    threshold = convert(T, relative_tolerance)
    for (row, variable) in enumerate(variables)
        candidates = [vec(transpose(lifted) * topology.nullspace) for lifted in rows_by_variable[variable]]
        reference = first(candidates)
        projected[row, :] .= reference
        for candidate in Iterators.drop(candidates, 1)
            residual = norm(candidate - reference)
            maximum_residual = max(maximum_residual, residual)
            residual <= threshold * max(one(T), norm(reference), norm(candidate)) ||
                return PortTopologyCoordinateProjection{T}(
                    false, "coordinate maps for one model variable disagree on topology directions",
                    variables, topology, zeros(T, 0, 0), maximum_residual,
                )
        end
    end
    return PortTopologyCoordinateProjection{T}(
        true, nothing, variables, topology, projected, maximum_residual,
    )
end

function _component_port_topology_coordinate_projection_findings(
    ports::AbstractVector{<:ComponentPortMetadata{T}},
    connections::AbstractVector{<:PortConnectionMetadata{T}},
    coordinate_maps::AbstractVector{<:PortCoordinateMap{T}};
    relative_tolerance::Real = sqrt(eps(T)),
) where {T<:AbstractFloat}
    report = DiagnosticReport()
    isempty(coordinate_maps) && return report
    projection = port_topology_coordinate_projection(
        ports, connections, coordinate_maps; relative_tolerance = relative_tolerance,
    )
    report.metadata[:component_port_topology_model_projection_available] = string(projection.available)
    if !projection.available
        push!(report, Finding(:component_port_topology_model_projection_unavailable;
            severity = SeverityInfo, domain = RepresentationalIssue,
            basis = StructuralProof, confidence = ConfidenceCertain,
            observation = "Declared terminal topology modes cannot be projected into model coordinates: $(projection.reason).",
            why_it_matters = "The generic debugger must not compare terminal-space topology modes with a Jacobian until their coordinate convention is explicit and consistent.",
            evidence = [Evidence("Port topology coordinate projection"; details = ["reason" => projection.reason])],
            suggested_actions = ["Provide one finite, dimension-aligned coordinate map per declared port and reconcile repeated model-variable mappings."],
        ))
        return report
    end
    singular_values = svdvals(projection.projected_nullspace)
    scale = maximum(singular_values; init = zero(T))
    projected_rank = count(value -> value > convert(T, relative_tolerance) * max(one(T), scale), singular_values)
    terminal_nullity = size(projection.topology.nullspace, 2)
    report.metadata[:component_port_topology_model_projection_rank] = string(projected_rank)
    report.metadata[:component_port_topology_model_projection_nullity] = string(terminal_nullity)
    push!(report, Finding(:component_port_topology_model_projection_available;
        severity = SeverityInfo, domain = RepresentationalIssue,
        basis = StructuralProof, confidence = ConfidenceHigh,
        observation = "Declared topology has $terminal_nullity terminal-space null direction(s), projected into $(length(projection.variables)) model coordinate(s) with rank $projected_rank.",
        why_it_matters = "This supplies inspectable candidate directions for later comparison with numerical model nullspaces; it does not classify them physically.",
        evidence = [Evidence("Port topology coordinate projection"; details = ["terminal_nullity" => terminal_nullity, "projected_rank" => projected_rank, "variables" => length(projection.variables), "consistency_residual" => projection.consistency_residual])],
        affected = [EntityRef(:variable, variable.value) for variable in projection.variables],
        suggested_actions = ["Compare these candidate coordinates with an evaluated Jacobian nullspace only after checking the plugin's physical convention."],
    ))
    if projected_rank < terminal_nullity
        push!(report, Finding(:component_port_topology_mode_hidden_from_model_coordinates;
            severity = SeverityInfo, domain = RepresentationalIssue,
            basis = StructuralProof, confidence = ConfidenceHigh,
            observation = "At least $(terminal_nullity - projected_rank) declared terminal-space topology mode(s) are not visible through the supplied model-coordinate maps.",
            why_it_matters = "A terminal nullspace can contain internal or omitted directions that must not be treated as model-variable gauges.",
            evidence = [Evidence("Port topology projection rank"; details = ["terminal_nullity" => terminal_nullity, "projected_rank" => projected_rank])],
            suggested_actions = ["Declare additional model-coordinate maps if these directions should be observable, or document them as intentionally hidden port modes."],
        ))
    end
    return report
end

# The generic hook returns an unparameterized empty vector. It intentionally
# means that no plugin has opted into a terminal-to-model-coordinate convention.
function _component_port_topology_coordinate_projection_findings(
    ports::AbstractVector{<:ComponentPortMetadata},
    connections::AbstractVector{<:PortConnectionMetadata},
    coordinate_maps::AbstractVector{<:PortCoordinateMap},
)
    isempty(coordinate_maps) || throw(ArgumentError(
        "port metadata, connections, and coordinate maps must use one floating-point type",
    ))
    return DiagnosticReport()
end

"""
    port_topology_expected_nullspace_modes(ports, connections, coordinate_maps; ...)

Convert independent, nonzero projected topology directions into generic
`ExpectedNullspaceMode` declarations. The generated names deliberately say
`port_topology_candidate_mode_*`: they are representational candidates derived
from declared maps, not assertions of a physical gauge.
"""
function port_topology_expected_nullspace_modes(
    ports::AbstractVector{<:ComponentPortMetadata{T}},
    connections::AbstractVector{<:PortConnectionMetadata{T}},
    coordinate_maps::AbstractVector{<:PortCoordinateMap{T}};
    relative_tolerance::Real = sqrt(eps(T)),
) where {T<:AbstractFloat}
    isempty(coordinate_maps) && return ExpectedNullspaceMode{T}[]
    isempty(connections) && return ExpectedNullspaceMode{T}[]
    connected_keys = Set{Tuple{Symbol,String,String}}()
    for connection in connections
        push!(connected_keys, (
            connection.from_component_type, connection.from_component_id,
            connection.from_port_id,
        ))
        push!(connected_keys, (
            connection.to_component_type, connection.to_component_id,
            connection.to_port_id,
        ))
    end
    connected_ports = [port for port in ports if
                       (port.component_type, port.component_id, port.port_id) in connected_keys]
    connected_maps = [map for map in coordinate_maps if
                      (map.component_type, map.component_id, map.port_id) in connected_keys]
    isempty(connected_maps) && return ExpectedNullspaceMode{T}[]
    projection = port_topology_coordinate_projection(
        connected_ports, connections, connected_maps;
        relative_tolerance = relative_tolerance,
    )
    projection.available || return ExpectedNullspaceMode{T}[]
    matrix = projection.projected_nullspace
    isempty(matrix) && return ExpectedNullspaceMode{T}[]
    decomposition = svd(matrix; full = false)
    scale = maximum(decomposition.S; init = zero(T))
    threshold = convert(T, relative_tolerance) * max(one(T), scale)
    rank = count(value -> value > threshold, decomposition.S)
    scope = join(sort([
        "$(key[1]):$(key[2]):$(key[3])" for key in projection.topology.port_keys
    ]), ", ")
    return ExpectedNullspaceMode{T}[
        ExpectedNullspaceMode(
            Symbol("port_topology_candidate_mode_", index),
            projection.variables,
            decomposition.U[:, index];
            description = "Candidate expected mode projected from declared connected-port topology maps over port scope [$scope] (terminal nullity $(size(projection.topology.nullspace, 2))).",
        ) for index in 1:rank
    ]
end

"""
    port_component_expected_nullspace_modes(ports, port_modes, coordinate_maps)

Map plugin-declared **terminal-space** component-port null directions into MOI
variables. Mode-space declarations are intentionally excluded: the generic
contract has no mode-to-variable map, and guessing one would hide a plugin
convention behind numerical evidence.
"""
function port_component_expected_nullspace_modes(
    ports::AbstractVector{<:ComponentPortMetadata{T}},
    port_modes::AbstractVector{<:PortNullspaceMode{T}},
    coordinate_maps::AbstractVector{<:PortCoordinateMap{T}},
) where {T<:AbstractFloat}
    port_by_key = Dict(
        (port.component_type, port.component_id, port.port_id) => port for port in ports
    )
    map_by_key = Dict(
        (map.component_type, map.component_id, map.port_id) => map for map in coordinate_maps
    )
    result = ExpectedNullspaceMode{T}[]
    ordinal_by_key = Dict{Tuple{Symbol,String,String},Int}()
    named_occurrence_by_key = Dict{Tuple{Symbol,String,String,Symbol},Int}()
    for mode in port_modes
        mode.space == :terminal || continue
        key = (mode.component_type, mode.component_id, mode.port_id)
        port = get(port_by_key, key, nothing)
        map = get(map_by_key, key, nothing)
        (isnothing(port) || isnothing(map)) && continue
        length(mode.direction) == length(port.terminal_labels) || continue
        size(map.terminal_to_variable) == (length(map.variables), length(port.terminal_labels)) || continue
        all(isfinite, map.terminal_to_variable) || continue
        direction = map.terminal_to_variable * mode.direction
        iszero(norm(direction)) && continue
        ordinal = get(ordinal_by_key, key, 0) + 1
        ordinal_by_key[key] = ordinal
        identifier = if isnothing(mode.name)
            Symbol(string(ordinal))
        else
            named_key = (key..., mode.name)
            occurrence = get(named_occurrence_by_key, named_key, 0) + 1
            named_occurrence_by_key[named_key] = occurrence
            occurrence == 1 ? mode.name : Symbol(mode.name, "_", occurrence)
        end
        push!(result, ExpectedNullspaceMode(
            Symbol(
                "component_port_candidate_mode_", mode.component_type, "_",
                mode.component_id, "_", mode.port_id, "_", identifier,
            ),
            map.variables,
            direction;
            description = isempty(mode.description) ?
                          (isnothing(mode.name) ?
                           "Candidate expected mode projected from a declared terminal-space component-port null direction." :
                           "Candidate expected mode projected from declared component-port mode :$(mode.name).") :
                          "Candidate expected mode projected from component-port declaration: $(mode.description)",
        ))
    end
    return result
end

function port_component_expected_nullspace_modes(
    ports::AbstractVector{<:ComponentPortMetadata},
    port_modes::AbstractVector{<:PortNullspaceMode},
    coordinate_maps::AbstractVector{<:PortCoordinateMap},
)
    (isempty(port_modes) || isempty(coordinate_maps)) && return ExpectedNullspaceMode[]
    throw(ArgumentError(
        "port metadata, port modes, and coordinate maps must use one floating-point type",
    ))
end

"""Combine declared component-port and declared topology candidate mode projections."""
function port_expected_nullspace_modes(
    ports::AbstractVector{<:ComponentPortMetadata{T}},
    port_modes::AbstractVector{<:PortNullspaceMode{T}},
    connections::AbstractVector{<:PortConnectionMetadata{T}},
    coordinate_maps::AbstractVector{<:PortCoordinateMap{T}},
) where {T<:AbstractFloat}
    return vcat(
        port_component_expected_nullspace_modes(ports, port_modes, coordinate_maps),
        port_topology_expected_nullspace_modes(ports, connections, coordinate_maps),
    )
end

"""Identify near-identical component- and topology-derived candidate directions."""
function _port_expected_mode_overlap_findings(
    modes::AbstractVector{<:ExpectedNullspaceMode};
    alignment_tolerance::Real = 1 - sqrt(eps(Float64)),
)
    zero(alignment_tolerance) <= alignment_tolerance <= one(alignment_tolerance) ||
        throw(ArgumentError("alignment_tolerance must lie in [0, 1]"))
    report = DiagnosticReport()
    component_modes = [mode for mode in modes if
                       _port_expected_mode_origin(mode) == :component]
    topology_modes = [mode for mode in modes if
                      _port_expected_mode_origin(mode) == :topology]
    for component_mode in component_modes, topology_mode in topology_modes
        variables = sort!(unique(vcat(component_mode.variables, topology_mode.variables));
                          by = variable -> variable.value)
        component_direction = zeros(Float64, length(variables))
        topology_direction = zeros(Float64, length(variables))
        position = Dict(variable => index for (index, variable) in enumerate(variables))
        for (variable, value) in zip(component_mode.variables, component_mode.direction)
            component_direction[position[variable]] += value
        end
        for (variable, value) in zip(topology_mode.variables, topology_mode.direction)
            topology_direction[position[variable]] += value
        end
        alignment = abs(dot(component_direction, topology_direction)) /
                    (norm(component_direction) * norm(topology_direction))
        alignment >= alignment_tolerance || continue
        push!(report, Finding(:port_expected_nullspace_candidate_overlap;
            severity = SeverityInfo, domain = RepresentationalIssue,
            basis = StructuralProof, confidence = ConfidenceHigh,
            observation = "A component-port candidate and a topology candidate are nearly the same declared model-coordinate direction.",
            why_it_matters = "The sources are complementary evidence, but treating both as independent expected modes would overstate the declared nullspace dimension.",
            evidence = [Evidence("Port expected-mode overlap"; details = ["component_mode" => component_mode.name, "topology_mode" => topology_mode.name, "absolute_cosine" => alignment, "alignment_tolerance" => alignment_tolerance])],
            affected = [EntityRef(:variable, variable.value) for variable in variables],
            suggested_actions = ["Retain both provenance records if useful, but count their shared direction only once when declaring expected nullity."],
        ))
    end
    return report
end

function _port_expected_mode_origin(mode::ExpectedNullspaceMode)
    startswith(string(mode.name), "component_port_candidate_mode_") && return :component
    startswith(string(mode.name), "port_topology_candidate_mode_") && return :topology
    return :unknown
end

"""
    port_expected_nullspace_summary(modes; relative_tolerance)

Return the model-coordinate matrix and independent span of projected port
expected-mode candidates. This is declaration-level structural evidence; it
does not compare the candidates with a Jacobian or assign physical semantics.
"""
function port_expected_nullspace_summary(
    modes::AbstractVector{<:ExpectedNullspaceMode};
    relative_tolerance::Real = sqrt(eps(Float64)),
)
    isfinite(relative_tolerance) && relative_tolerance >= 0 ||
        throw(ArgumentError("relative_tolerance must be finite and nonnegative"))
    isempty(modes) && return PortExpectedNullspaceSummary{Float64}(
        MOI.VariableIndex[], Symbol[], Symbol[], String[], zeros(Float64, 0, 0), 0,
        Float64(relative_tolerance),
    )
    T = float(promote_type((eltype(mode.direction) for mode in modes)...))
    variables = sort!(unique(vcat((mode.variables for mode in modes)...));
                      by = variable -> variable.value)
    positions = Dict(variable => position for (position, variable) in enumerate(variables))
    directions = zeros(T, length(variables), length(modes))
    for (column, mode) in enumerate(modes)
        for (variable, value) in zip(mode.variables, mode.direction)
            directions[positions[variable], column] += T(value)
        end
    end
    singular_values = svdvals(directions)
    scale = maximum(singular_values; init = zero(T))
    tolerance = T(relative_tolerance)
    rank = count(value -> value > tolerance * max(one(T), scale), singular_values)
    return PortExpectedNullspaceSummary{T}(
        variables, Symbol[mode.name for mode in modes],
        Symbol[_port_expected_mode_origin(mode) for mode in modes],
        String[mode.description for mode in modes],
        directions, rank, tolerance,
    )
end

"""
Identify dependent projected port candidates while retaining every declaration.

The individual component and topology declarations remain useful provenance,
so this check deliberately reports their collective span rather than silently
deduplicating them. It is a structural property of plugin-supplied coordinate
maps, not numerical evidence about the model Jacobian.
"""
function _port_expected_mode_span_findings(
    modes::AbstractVector{<:ExpectedNullspaceMode};
    relative_tolerance::Real = sqrt(eps(Float64)),
)
    summary = port_expected_nullspace_summary(modes;
        relative_tolerance = relative_tolerance,
    )
    report = DiagnosticReport()
    report.metadata[:port_expected_nullspace_candidate_span_count] =
        string(length(summary.candidate_names))
    report.metadata[:port_expected_nullspace_candidate_span_rank] = string(summary.rank)
    report.metadata[:port_expected_nullspace_candidate_span_relative_tolerance] =
        string(summary.relative_tolerance)
    summary.rank == length(modes) && return report
    push!(report, Finding(:port_expected_nullspace_candidate_span_dependent;
        severity = SeverityInfo, domain = RepresentationalIssue,
        basis = StructuralProof, confidence = ConfidenceHigh,
        observation = "$(length(modes)) projected port expected-mode candidate(s) span only $(summary.rank) independent model-coordinate direction(s).",
        why_it_matters = "The declarations retain distinct provenance, but their count must not be interpreted as an independent expected-nullity count before comparison with a numerical Jacobian.",
        evidence = [Evidence("Projected port expected-mode span"; details = [
            "candidate_modes" => join(string.(summary.candidate_names), ","),
            "candidate_descriptions" => join(summary.candidate_descriptions, " | "),
            "candidate_count" => length(modes),
            "independent_rank" => summary.rank,
            "relative_tolerance" => summary.relative_tolerance,
        ])],
        affected = [EntityRef(:variable, variable.value) for variable in summary.variables],
        suggested_actions = ["Retain each declaration for provenance, but interpret their shared span as $(summary.rank) expected direction(s).", "Inspect port maps and mode declarations if the dependency was unintended."],
    ))
    return report
end

function port_expected_nullspace_modes(
    ports::AbstractVector{<:ComponentPortMetadata},
    port_modes::AbstractVector{<:PortNullspaceMode},
    connections::AbstractVector{<:PortConnectionMetadata},
    coordinate_maps::AbstractVector{<:PortCoordinateMap},
)
    isempty(coordinate_maps) && return ExpectedNullspaceMode[]
    # Generic extension hooks use unparameterized empty vectors. Preserve
    # valid port/map declarations when a plugin simply has no connections or
    # no component-level modes, by materializing the matching typed empties.
    T = eltype(first(coordinate_maps).terminal_to_variable)
    typed_ports = ComponentPortMetadata{T}[ports...]
    typed_maps = PortCoordinateMap{T}[coordinate_maps...]
    typed_connections = isempty(connections) ? PortConnectionMetadata{T}[] : connections
    typed_modes = isempty(port_modes) ? PortNullspaceMode{T}[] : port_modes
    if typed_connections isa AbstractVector{<:PortConnectionMetadata{T}} &&
       typed_modes isa AbstractVector{<:PortNullspaceMode{T}}
        return port_expected_nullspace_modes(
            typed_ports, typed_modes, typed_connections, typed_maps,
        )
    end
    throw(ArgumentError(
        "port metadata, modes, connections, and coordinate maps must use one floating-point type",
    ))
end

"""Build a projected expected-mode summary directly from port declarations."""
function port_expected_nullspace_summary(
    ports::AbstractVector{<:ComponentPortMetadata},
    port_modes::AbstractVector{<:PortNullspaceMode},
    connections::AbstractVector{<:PortConnectionMetadata},
    coordinate_maps::AbstractVector{<:PortCoordinateMap};
    kwargs...,
)
    return port_expected_nullspace_summary(
        port_expected_nullspace_modes(ports, port_modes, connections, coordinate_maps);
        kwargs...,
    )
end

function port_topology_expected_nullspace_modes(
    ports::AbstractVector{<:ComponentPortMetadata},
    connections::AbstractVector{<:PortConnectionMetadata},
    coordinate_maps::AbstractVector{<:PortCoordinateMap};
    kwargs...,
)
    isempty(coordinate_maps) && return ExpectedNullspaceMode[]
    T = eltype(first(coordinate_maps).terminal_to_variable)
    if isempty(connections)
        return port_topology_expected_nullspace_modes(
            ComponentPortMetadata{T}[ports...], PortConnectionMetadata{T}[],
            PortCoordinateMap{T}[coordinate_maps...];
            kwargs...,
        )
    end
    throw(ArgumentError(
        "port metadata, connections, and coordinate maps must use one floating-point type",
    ))
end

"""
    port_topology_nullspace(ports, connections; relative_tolerance = sqrt(eps(T)))

Assemble equations `destination - connection_matrix * source = 0` in declared
terminal coordinates and return their numerical nullspace. This is a statement
about plugin-declared maps only; it is not a physical network observability or
model-coordinate nullspace calculation.
"""
function port_topology_nullspace(
    ports::AbstractVector{<:ComponentPortMetadata{T}},
    connections::AbstractVector{<:PortConnectionMetadata{T}};
    relative_tolerance::Real = sqrt(eps(T)),
) where {T<:AbstractFloat}
    tolerance = convert(T, relative_tolerance)
    tolerance >= zero(T) || throw(ArgumentError("relative_tolerance must be nonnegative"))
    keys = [(port.component_type, port.component_id, port.port_id) for port in ports]
    offsets = Dict{Tuple{Symbol,String,String},Int}()
    coordinate_count = 0
    for (key, port) in zip(keys, ports)
        haskey(offsets, key) && return PortTopologyNullspace{T}(
            false, "duplicate port identity", keys, zeros(T, 0, 0), 0, zeros(T, 0, 0),
        )
        offsets[key] = coordinate_count + 1
        coordinate_count += length(port.terminal_labels)
    end
    by_key = Dict(key => port for (key, port) in zip(keys, ports))
    row_count = 0
    for connection in connections
        to_key = (connection.to_component_type, connection.to_component_id, connection.to_port_id)
        row_count += haskey(by_key, to_key) ? length(by_key[to_key].terminal_labels) : 0
    end
    matrix = zeros(T, row_count, coordinate_count)
    row_offset = 0
    for connection in connections
        from_key = (connection.from_component_type, connection.from_component_id, connection.from_port_id)
        to_key = (connection.to_component_type, connection.to_component_id, connection.to_port_id)
        (haskey(by_key, from_key) && haskey(by_key, to_key)) || return PortTopologyNullspace{T}(
            false, "connection endpoint is not a declared port", keys, zeros(T, 0, 0), 0, zeros(T, 0, 0),
        )
        from_port, to_port = by_key[from_key], by_key[to_key]
        expected_size = (length(to_port.terminal_labels), length(from_port.terminal_labels))
        size(connection.connection_matrix) == expected_size || return PortTopologyNullspace{T}(
            false, "connection matrix dimensions do not match endpoint terminals", keys, zeros(T, 0, 0), 0, zeros(T, 0, 0),
        )
        all(isfinite, connection.connection_matrix) || return PortTopologyNullspace{T}(
            false, "connection matrix contains non-finite coefficients", keys, zeros(T, 0, 0), 0, zeros(T, 0, 0),
        )
        rows = (row_offset + 1):(row_offset + expected_size[1])
        from_columns = offsets[from_key]:(offsets[from_key] + expected_size[2] - 1)
        to_columns = offsets[to_key]:(offsets[to_key] + expected_size[1] - 1)
        matrix[rows, from_columns] .-= connection.connection_matrix
        matrix[rows, to_columns] .+= Matrix{T}(I, expected_size[1], expected_size[1])
        row_offset += expected_size[1]
    end
    factorization = svd(matrix; full = true)
    scale = maximum(factorization.S; init = zero(T))
    rank = count(value -> value > tolerance * scale, factorization.S)
    nullspace = Matrix(factorization.V[:, (rank + 1):coordinate_count])
    return PortTopologyNullspace{T}(true, nothing, keys, matrix, rank, nullspace)
end

function _component_port_topology_nullspace_findings(
    ports::AbstractVector{<:ComponentPortMetadata{T}},
    connections::AbstractVector{<:PortConnectionMetadata{T}},
) where {T<:AbstractFloat}
    report = DiagnosticReport()
    analysis = port_topology_nullspace(ports, connections)
    report.metadata[:component_port_topology_nullspace_available] = string(analysis.available)
    report.metadata[:component_port_topology_rank] = string(analysis.rank)
    report.metadata[:component_port_topology_nullity] = string(size(analysis.nullspace, 2))
    if !analysis.available
        push!(report, Finding(:component_port_topology_nullspace_unavailable;
            severity = SeverityInfo, domain = RepresentationalIssue,
            basis = StructuralProof, confidence = ConfidenceCertain,
            observation = "Declared port-topology nullspace assembly is unavailable: $(analysis.reason).",
            why_it_matters = "Invalid declared connection maps must not be partially assembled into expected network freedom evidence.",
            evidence = [Evidence("Declared port topology nullspace availability")],
            suggested_actions = ["Resolve declared port and connection-map validation findings before requesting topology nullspace interpretation."],
        ))
    elseif size(analysis.nullspace, 2) > 0
        push!(report, Finding(:component_port_topology_expected_nullspace;
            severity = SeverityInfo, domain = RepresentationalIssue,
            basis = StructuralProof, confidence = ConfidenceCertain,
            observation = "Declared port topology has $(size(analysis.nullspace, 2)) terminal-coordinate null direction(s).",
            why_it_matters = "This is expected freedom of the declared connection equations. A plugin must map it to model or physical coordinates before comparing it with observed model nullspaces.",
            evidence = [Evidence("Declared port topology nullspace"; details = ["port_count" => length(analysis.port_keys), "connection_equation_count" => size(analysis.connection_matrix, 1), "rank" => analysis.rank, "nullity" => size(analysis.nullspace, 2)])],
            suggested_actions = ["Map these terminal-coordinate directions through plugin-declared model coordinates before assigning a physical gauge interpretation."],
        ))
    end
    return report
end

function _component_port_topology_nullspace_findings(
    ports::AbstractVector{<:ComponentPortMetadata},
    connections::AbstractVector{<:PortConnectionMetadata},
)
    isempty(ports) && isempty(connections) || throw(ArgumentError(
        "port topology declarations must use one concrete floating-point metadata type",
    ))
    report = DiagnosticReport()
    report.metadata[:component_port_topology_nullspace_available] = "true"
    report.metadata[:component_port_topology_rank] = "0"
    report.metadata[:component_port_topology_nullity] = "0"
    return report
end

function _component_port_topology_findings(
    ports::AbstractVector{<:ComponentPortMetadata},
    connections::AbstractVector{<:PortConnectionMetadata},
)
    report = DiagnosticReport()
    keys = [(port.component_type, port.component_id, port.port_id) for port in ports]
    key_set = Set(keys)
    adjacency = Dict(key => Set{typeof(key)}() for key in keys)
    for connection in connections
        from = (connection.from_component_type, connection.from_component_id, connection.from_port_id)
        to = (connection.to_component_type, connection.to_component_id, connection.to_port_id)
        from in key_set && to in key_set || continue
        push!(adjacency[from], to)
        push!(adjacency[to], from)
    end
    isolated = [key for key in keys if isempty(adjacency[key])]
    if !isempty(isolated)
        push!(report, Finding(:component_port_topology_isolated_port;
            severity = SeverityInfo, domain = RepresentationalIssue,
            basis = StructuralProof, confidence = ConfidenceCertain,
            observation = "Declared port topology contains $(length(isolated)) isolated port(s).",
            why_it_matters = "An isolated declared port can be intentional, but it may also expose missing connection metadata or an unassembled subsystem.",
            evidence = [Evidence("Declared port topology"; details = ["isolated_ports" => join((join(string.(key), ":") for key in isolated), ",")])],
            suggested_actions = ["Confirm that each isolated port is intentionally external or declare its explicit port connection."],
        ))
    end
    visited = Set{eltype(keys)}()
    components = Vector{Vector{eltype(keys)}}()
    for start in keys
        start in visited && continue
        component = eltype(keys)[]
        stack = [start]
        push!(visited, start)
        while !isempty(stack)
            current = pop!(stack)
            push!(component, current)
            for neighbor in adjacency[current]
                neighbor in visited && continue
                push!(visited, neighbor)
                push!(stack, neighbor)
            end
        end
        push!(components, component)
    end
    nontrivial = [component for component in components if length(component) > 1]
    if length(nontrivial) > 1
        push!(report, Finding(:component_port_topology_disconnected_islands;
            severity = SeverityInfo, domain = RepresentationalIssue,
            basis = StructuralProof, confidence = ConfidenceCertain,
            observation = "Declared port topology contains $(length(nontrivial)) disconnected nontrivial connection-map islands.",
            why_it_matters = "Separate declared port islands may be intentional, but unexpected separation can reveal missing topology metadata or unassembled subsystems.",
            evidence = [Evidence("Declared port topology"; details = ["component_sizes" => join(length.(nontrivial), ",")])],
            suggested_actions = ["Inspect whether the separated port islands are intentional before attaching network-level semantics."],
        ))
    end
    return report
end

"""
    elastic_feasibility_plan(model; relax_variable_bounds = false, selected_constraints = nothing)

Return the exact scalar-affine `<=`, `>=`, and `==` rows that a first elastic
auxiliary model may relax. This function neither modifies nor solves a model;
all other non-variable constraints remain explicitly unsupported.
"""
function elastic_feasibility_plan(
    model::MOI.ModelLike;
    relax_variable_bounds::Bool = false,
    selected_constraints::Union{Nothing,AbstractVector{EntityRef}} = nothing,
)
    model_snapshot = snapshot(model)
    relaxable = EntityRef[]
    unsupported = EntityRef[]
    excluded = EntityRef[]
    slack_count = 0
    for record in model_snapshot.constraints
        function_value = record.function_value
        set_value = record.set_value
        reference = _constraint_ref(record)
        variable_bound = relax_variable_bounds && function_value isa MOI.VariableIndex
        scalar_row = function_value isa Union{MOI.ScalarAffineFunction{Float64},MOI.ScalarQuadraticFunction{Float64},MOI.ScalarNonlinearFunction} &&
                     set_value isa Union{MOI.LessThan{Float64},MOI.GreaterThan{Float64},MOI.EqualTo{Float64}}
        vector_row = function_value isa Union{MOI.VectorOfVariables,MOI.VectorAffineFunction{Float64}} &&
                     set_value isa Union{MOI.SecondOrderCone,MOI.RotatedSecondOrderCone,MOI.NormOneCone,MOI.NormInfinityCone,MOI.NormCone,MOI.NormSpectralCone,MOI.NormNuclearCone,MOI.PowerCone,MOI.DualPowerCone,MOI.ExponentialCone,MOI.DualExponentialCone,MOI.GeometricMeanCone,MOI.RelativeEntropyCone,MOI.LogDetConeTriangle,MOI.LogDetConeSquare,MOI.RootDetConeTriangle,MOI.RootDetConeSquare,MOI.Scaled{MOI.LogDetConeTriangle},MOI.Scaled{MOI.RootDetConeTriangle},MOI.PositiveSemidefiniteConeTriangle,MOI.PositiveSemidefiniteConeSquare,MOI.Scaled{MOI.PositiveSemidefiniteConeTriangle},MOI.HermitianPositiveSemidefiniteConeTriangle,MOI.Scaled{MOI.HermitianPositiveSemidefiniteConeTriangle},MOI.Nonnegatives,MOI.Nonpositives,MOI.Zeros}
        if variable_bound || scalar_row || vector_row
            if isnothing(selected_constraints) || any(==(reference), selected_constraints)
                push!(relaxable, reference)
            slack_count += set_value isa MOI.EqualTo{Float64} ? 2 :
                           set_value isa Union{MOI.Nonnegatives,MOI.Nonpositives} ? MOI.dimension(set_value) :
                           set_value isa MOI.Zeros ? 2 * MOI.dimension(set_value) : 1
            else
                push!(excluded, reference)
            end
        else
            push!(unsupported, reference)
        end
    end
    if !isnothing(selected_constraints)
        duplicate_selected = [
            source for source in selected_constraints if
            count(==(source), selected_constraints) > 1
        ]
        isempty(duplicate_selected) || throw(ArgumentError(
            "selected elastic constraints must be unique",
        ))
        eligible = vcat(relaxable, excluded)
        unknown_selected = [
            source for source in selected_constraints if !any(==(source), eligible)
        ]
        isempty(unknown_selected) || throw(ArgumentError(
            "selected elastic constraints include $(length(unknown_selected)) row(s) outside the eligible relaxation scope",
        ))
    end
    return ElasticFeasibilityPlan(
        relaxable, unsupported, excluded, length(relaxable), slack_count,
    )
end

"""Turn an elastic-feasibility plan's coverage limits into inspectable findings."""
function analyze_elastic_feasibility_plan(plan::ElasticFeasibilityPlan)
    report = DiagnosticReport()
    report.metadata[:stage] = "elastic_feasibility_plan"
    report.metadata[:relaxation_count] = string(plan.relaxation_count)
    report.metadata[:slack_count] = string(plan.slack_count)
    report.metadata[:unsupported_constraint_count] = string(length(plan.unsupported_constraints))
    report.metadata[:excluded_constraint_count] = string(length(plan.excluded_constraints))
    if !isempty(plan.unsupported_constraints)
        push!(report, Finding(:elastic_unsupported_constraints;
            severity = SeverityInfo, domain = RepresentationalIssue,
            basis = StructuralProof, confidence = ConfidenceCertain,
            observation = "The elastic plan leaves $(length(plan.unsupported_constraints)) constraint(s) unrelaxed because their generic relaxation is not implemented.",
            why_it_matters = "A zero-slack auxiliary result would not establish feasibility of constraints excluded from the auxiliary objective.",
            evidence = [Evidence("Unsupported elastic constraints"; details = ["count" => length(plan.unsupported_constraints)])],
            affected = plan.unsupported_constraints,
            suggested_actions = ["Use a domain-specific relaxation or extend the generic auxiliary builder before interpreting global feasibility."],
        ))
    end
    if !isempty(plan.excluded_constraints)
        push!(report, Finding(:elastic_constraints_excluded;
            severity = SeverityInfo, domain = RepresentationalIssue,
            basis = StructuralProof, confidence = ConfidenceCertain,
            observation = "The elastic plan deliberately excludes $(length(plan.excluded_constraints)) eligible constraint(s).",
            why_it_matters = "This is a focused local probe, not a relaxation of every eligible row in the model.",
            evidence = [Evidence("Excluded elastic constraints"; details = ["count" => length(plan.excluded_constraints)])],
            affected = plan.excluded_constraints,
            suggested_actions = ["Include these rows for a broader restoration experiment if that matches the diagnostic question."],
        ))
    end
    return report
end

"""
    analyze_elastic_feasibility_plan(model; relax_variable_bounds = false, selected_constraints = nothing)

Build and report the non-mutating elastic-feasibility coverage plan in one
step. Use `elastic_feasibility_plan` first when the exact eligible, excluded,
and unsupported source scopes must be retained separately by the caller.
"""
function analyze_elastic_feasibility_plan(
    model::MOI.ModelLike;
    relax_variable_bounds::Bool = false,
    selected_constraints::Union{Nothing,AbstractVector{EntityRef}} = nothing,
)
    return analyze_elastic_feasibility_plan(elastic_feasibility_plan(
        model;
        relax_variable_bounds = relax_variable_bounds,
        selected_constraints = selected_constraints,
    ))
end

function _elastic_domain_argument(
    model_snapshot::ModelSnapshot,
    issue::ExpressionDomainIssue,
    argument::Integer = issue.argument,
)
    issue.path.source.kind == :constraint || return nothing
    record = findfirst(
        candidate -> _constraint_ref(candidate) == issue.path.source,
        model_snapshot.constraints,
    )
    isnothing(record) && return nothing
    expression = model_snapshot.constraints[record].function_value
    for argument_index in issue.path.arguments
        expression isa MOI.ScalarNonlinearFunction || return nothing
        argument_index <= length(expression.args) || return nothing
        expression = expression.args[argument_index]
    end
    expression isa MOI.ScalarNonlinearFunction || return nothing
    argument <= length(expression.args) || return nothing
    return expression.args[argument]
end

function _elastic_domain_guard_materialization(
    model_snapshot::ModelSnapshot,
    issue::ExpressionDomainIssue,
)
    if issue.operator == :logdiffexp
        first_argument = _elastic_domain_argument(model_snapshot, issue, 1)
        second_argument = _elastic_domain_argument(model_snapshot, issue, 2)
        (isnothing(first_argument) || isnothing(second_argument)) && return false,
            "the nonlinear arguments cannot be recovered as scalar source expressions"
        (first_argument isa Union{MOI.VariableIndex,MOI.ScalarAffineFunction{Float64}} &&
            second_argument isa Union{MOI.VariableIndex,MOI.ScalarAffineFunction{Float64}}) ||
            return false, "the strict first-argument-minus-second-argument relation is not directly scalar affine"
        return true, "the strict scalar-affine first-argument-minus-second-argument guard can be materialized explicitly"
    end
    argument = _elastic_domain_argument(model_snapshot, issue)
    isnothing(argument) && return false,
        "the nonlinear argument cannot be recovered as a scalar source expression"
    argument isa Union{MOI.VariableIndex,MOI.ScalarAffineFunction{Float64}} ||
        return false, "the argument is not a directly guardable scalar affine expression"
    if issue.operator in (:log, :log10, :log2, :log1p, :log1mexp, :sqrt) ||
       (issue.operator == :^ && startswith(issue.requirement, "base > 0"))
        direction = issue.operator == :log1mexp ? "upper" : "lower"
        return true, "a scalar affine $direction-domain guard can be materialized explicitly"
    elseif issue.operator in (:asin, :acos, :asind, :acosd)
        return true, "the closed inverse-trigonometric input interval can be materialized explicitly"
    elseif issue.operator == :acosh
        return true, "the scalar affine lower domain for acosh can be materialized explicitly"
    elseif issue.operator == :atanh
        return true, "both strict scalar affine atanh domain boundaries can be materialized explicitly"
    elseif issue.operator == :asech
        return true, "both scalar affine asech domain boundaries can be materialized explicitly"
    elseif issue.operator in (:acsch, :csch, :coth)
        if issue.enclosure.lower >= 0
            return true, "the declared interval admits only the nonnegative acsch branch, so a positive margin is explicit"
        elseif issue.enclosure.upper <= 0
            return true, "the declared interval admits only the nonpositive acsch branch, so a negative margin is explicit"
        end
        return false, "the declared interval can cross zero, so a one-branch reciprocal-hyperbolic guard would change the model"
    elseif issue.operator == :acoth
        if issue.enclosure.lower >= 1
            return true, "the declared interval admits only the positive acoth branch, so a strict lower margin is explicit"
        elseif issue.enclosure.upper <= -1
            return true, "the declared interval admits only the negative acoth branch, so a strict upper margin is explicit"
        end
        return false, "the declared interval crosses acoth domain branches, so a generic guard would choose a branch"
    elseif issue.operator in (:asec, :acsc, :asecd, :acscd)
        if issue.enclosure.lower >= 1
            return true, "the declared interval admits only the positive inverse-reciprocal branch"
        elseif issue.enclosure.upper <= -1
            return true, "the declared interval admits only the negative inverse-reciprocal branch"
        end
        return false, "the declared interval crosses inverse-reciprocal domain branches, so a generic guard would choose a branch"
    elseif issue.operator in (:tan, :sec, :csc, :cot, :tand, :secd, :cscd, :cotd)
        boundary = _elastic_periodic_endpoint_boundary(
            issue.operator,
            Float64(issue.enclosure.lower),
            Float64(issue.enclosure.upper),
        )
        isnothing(boundary) && return false,
            "the periodic domain interval crosses a singularity or does not end at one identifiable branch boundary"
        return true, "one declared interval endpoint coincides with a single periodic singularity"
    elseif issue.operator in (:inv, :/) ||
           (issue.operator == :^ && startswith(issue.requirement, "base ≠ 0"))
        if issue.enclosure.lower >= 0
            return true, "the declared interval admits only the nonnegative branch, so a positive margin is explicit"
        elseif issue.enclosure.upper <= 0
            return true, "the declared interval admits only the nonpositive branch, so a negative margin is explicit"
        end
        return false, "the declared interval can cross zero, so a one-branch guard would change the model"
    end
    return false, "no generic guard encoding is implemented for this operator"
end

function _elastic_periodic_parameters(operator::Symbol)
    if operator in (:tan, :sec)
        return (Float64(pi / 2), Float64(pi))
    elseif operator in (:csc, :cot)
        return (0.0, Float64(pi))
    elseif operator in (:tand, :secd)
        return (90.0, 180.0)
    elseif operator in (:cscd, :cotd)
        return (0.0, 180.0)
    end
    return nothing
end

function _elastic_periodic_endpoint_boundary(operator::Symbol, lower::Float64, upper::Float64)
    parameters = _elastic_periodic_parameters(operator)
    isnothing(parameters) && return nothing
    (isfinite(lower) && isfinite(upper) && lower <= upper) || return nothing
    offset, period = parameters
    first_index = ceil(Int, (lower - offset) / period)
    last_index = floor(Int, (upper - offset) / period)
    first_index <= last_index || return nothing
    first_index == last_index || return nothing
    singularity = offset + first_index * period
    endpoint_tolerance = 16 * eps(Float64) * max(1.0, abs(lower), abs(upper), abs(singularity))
    if abs(lower - singularity) <= endpoint_tolerance
        return (:lower, singularity)
    elseif abs(upper - singularity) <= endpoint_tolerance
        return (:upper, singularity)
    end
    return nothing
end

"""
    elastic_domain_guard_plan(model; relax_variable_bounds = false, selected_constraints = nothing)

Inspect domain conditions attached to the nonlinear constraints selected for an
elastic experiment. The plan does not add constraints or alter the model. It
separates conditions for which a generic scalar-affine lower-domain guard could
eventually be materialized from conditions requiring a domain-specific method.
"""
function elastic_domain_guard_plan(
    model::MOI.ModelLike;
    relax_variable_bounds::Bool = false,
    selected_constraints::Union{Nothing,AbstractVector{EntityRef}} = nothing,
)
    model_snapshot = snapshot(model)
    elastic_plan = elastic_feasibility_plan(model;
        relax_variable_bounds = relax_variable_bounds,
        selected_constraints = selected_constraints,
    )
    selected = elastic_plan.relaxable_constraints
    guards = ElasticDomainGuard[]
    nonmaterializable = ElasticDomainGuard[]
    for issue in domain_issues(model_snapshot)
        issue.path.source in selected || continue
        # `logdiffexp(a, b)` yields two static issue attachments for source
        # provenance, but its strict domain is one joint relation a - b > 0.
        issue.operator == :logdiffexp && issue.argument != 1 && continue
        materializable, reason = _elastic_domain_guard_materialization(model_snapshot, issue)
        guard = ElasticDomainGuard(
            issue.path.source,
            copy(issue.path.arguments),
            issue.operator,
            issue.argument,
            issue.requirement,
            issue.assessment == DomainProvenViolation ? :proven : :possible,
            copy(issue.variables),
            Float64(issue.enclosure.lower),
            Float64(issue.enclosure.upper),
            issue.enclosure.informative,
            materializable,
            reason,
            issue.operator == :logdiffexp ? 2 : nothing,
        )
        push!(guards, guard)
        materializable || push!(nonmaterializable, guard)
    end
    return ElasticDomainGuardPlan(guards, nonmaterializable, length(selected))
end

"""Report nonlinear-domain conditions that bound interpretation of an elastic scope."""
function analyze_elastic_domain_guard_plan(plan::ElasticDomainGuardPlan)
    report = DiagnosticReport()
    report.metadata[:stage] = "elastic_domain_guard_plan"
    report.metadata[:elastic_domain_selected_constraint_count] = string(plan.selected_constraint_count)
    report.metadata[:elastic_domain_guard_count] = string(length(plan.guards))
    report.metadata[:elastic_domain_nonmaterializable_count] = string(length(plan.nonmaterializable))
    branch_sensitive = count(guard -> !guard.materializable && occursin("branch", lowercase(guard.reason)), plan.guards)
    report.metadata[:elastic_domain_branch_sensitive_count] = string(branch_sensitive)
    for guard in plan.guards
        proven = guard.assessment == :proven
        push!(report, Finding(
            proven ? :elastic_proven_domain_guard_violation : :elastic_possible_domain_guard_violation;
            severity = proven ? SeverityError : SeverityWarning,
            domain = MathematicalIssue,
            basis = proven ? MathematicalProof : HeuristicInterpretation,
            confidence = proven ? ConfidenceCertain : ConfidenceHigh,
            observation = "An elastic-scope constraint applies $(guard.operator) at path $(join(guard.path, "/")) where $(guard.requirement).",
            why_it_matters = "Relaxing a constraint residual does not make an undefined nonlinear operator evaluable; auxiliary slack evidence is unreliable outside this operator domain.",
            evidence = [Evidence("Elastic domain guard"; details = [
                "operator" => guard.operator,
                "argument" => guard.argument,
                "related_argument" => something(guard.related_argument, "none"),
                "requirement" => guard.requirement,
                "assessment" => guard.assessment,
                "materializable" => guard.materializable,
                "reason" => guard.reason,
            ])],
            affected = [guard.source],
            suggested_actions = guard.materializable ?
                                ["Use an explicit guarded auxiliary formulation with a stated positive margin before interpreting elastic results."] :
                                ["Use a domain-specific guarded formulation or reformulation; do not infer feasibility from an unguarded elastic solve."],
        ))
        if !guard.materializable && occursin("branch", lowercase(guard.reason))
            push!(report, Finding(
                :elastic_domain_guard_branch_selection_required;
                severity = SeverityInfo,
                domain = RepresentationalIssue,
                basis = StructuralProof,
                confidence = ConfidenceCertain,
                observation = "The $(guard.operator) domain evidence spans multiple admissible branches, so no generic elastic guard was added.",
                why_it_matters = "Selecting one branch would strengthen and potentially change the model; leaving it unguarded would permit undefined operator evaluations.",
                evidence = [Evidence("Branch-sensitive elastic domain guard"; details = ["operator" => guard.operator, "reason" => guard.reason])],
                affected = [guard.source],
                suggested_actions = ["Provide a domain-specific branch declaration or reformulate the expression with an explicit discrete or branch-selection model."],
            ))
        end
    end
    return report
end

"""
    analyze_elastic_domain_guard_plan(model; relax_variable_bounds = false, selected_constraints = nothing)

Build and report the non-mutating nonlinear domain-guard plan for the selected
elastic scope. Use `elastic_domain_guard_plan` first when callers need to
retain the materializable and nonmaterializable guard records themselves.
"""
function analyze_elastic_domain_guard_plan(
    model::MOI.ModelLike;
    relax_variable_bounds::Bool = false,
    selected_constraints::Union{Nothing,AbstractVector{EntityRef}} = nothing,
)
    return analyze_elastic_domain_guard_plan(elastic_domain_guard_plan(
        model;
        relax_variable_bounds = relax_variable_bounds,
        selected_constraints = selected_constraints,
    ))
end

function _elastic_function(function_value::MOI.ScalarAffineFunction{Float64}, additions)
    return MOI.ScalarAffineFunction(vcat(copy(function_value.terms), additions), function_value.constant)
end

function _elastic_function(function_value::MOI.ScalarQuadraticFunction{Float64}, additions)
    return MOI.ScalarQuadraticFunction(
        copy(function_value.quadratic_terms),
        vcat(copy(function_value.affine_terms), additions),
        function_value.constant,
    )
end

function _elastic_function(function_value::MOI.ScalarNonlinearFunction, additions)
    arguments = Any[function_value]
    for term in additions
        if term.coefficient == 1.0
            push!(arguments, term.variable)
        else
            push!(arguments, MOI.ScalarNonlinearFunction(:*, Any[term.coefficient, term.variable]))
        end
    end
    return MOI.ScalarNonlinearFunction(:+, arguments)
end

function _elastic_domain_argument(
    model_snapshot::ModelSnapshot,
    guard::ElasticDomainGuard,
    argument::Integer = guard.argument,
)
    guard.source.kind == :constraint || return nothing
    record_index = findfirst(
        candidate -> _constraint_ref(candidate) == guard.source,
        model_snapshot.constraints,
    )
    isnothing(record_index) && return nothing
    expression = model_snapshot.constraints[record_index].function_value
    for argument_index in guard.path
        expression isa MOI.ScalarNonlinearFunction || return nothing
        argument_index <= length(expression.args) || return nothing
        expression = expression.args[argument_index]
    end
    expression isa MOI.ScalarNonlinearFunction || return nothing
    argument <= length(expression.args) || return nothing
    return expression.args[argument]
end

function _map_elastic_guard_argument(
    value::MOI.VariableIndex,
    index_map,
)
    return MOI.ScalarAffineFunction(
        [MOI.ScalarAffineTerm(1.0, index_map[value])],
        0.0,
    )
end

function _elastic_affine_difference(
    first::MOI.ScalarAffineFunction{Float64},
    second::MOI.ScalarAffineFunction{Float64},
)
    terms = copy(first.terms)
    append!(terms, MOI.ScalarAffineTerm(-term.coefficient, term.variable) for term in second.terms)
    return MOI.ScalarAffineFunction(terms, first.constant - second.constant)
end

function _map_elastic_guard_argument(
    value::MOI.ScalarAffineFunction{Float64},
    index_map,
)
    return MOI.ScalarAffineFunction(
        [MOI.ScalarAffineTerm(term.coefficient, index_map[term.variable]) for term in value.terms],
        value.constant,
    )
end

function _elastic_domain_guard_sets(guard::ElasticDomainGuard, margin::Float64)
    if guard.operator in (:log, :log10, :log2)
        return Any[MOI.GreaterThan(margin)]
    elseif guard.operator == :log1p
        return Any[MOI.GreaterThan(-1.0 + margin)]
    elseif guard.operator == :log1mexp
        return Any[MOI.LessThan(-margin)]
    elseif guard.operator == :logdiffexp
        return Any[MOI.GreaterThan(margin)]
    elseif guard.operator == :sqrt
        return Any[MOI.GreaterThan(0.0)]
    elseif guard.operator in (:asin, :acos, :asind, :acosd)
        return Any[MOI.Interval(-1.0, 1.0)]
    elseif guard.operator == :acosh
        return Any[MOI.GreaterThan(1.0)]
    elseif guard.operator == :atanh
        return Any[MOI.GreaterThan(-1.0 + margin), MOI.LessThan(1.0 - margin)]
    elseif guard.operator == :asech
        return Any[MOI.GreaterThan(margin), MOI.LessThan(1.0)]
    elseif guard.operator in (:acsch, :csch, :coth) && guard.lower >= 0
        return Any[MOI.GreaterThan(margin)]
    elseif guard.operator in (:acsch, :csch, :coth) && guard.upper <= 0
        return Any[MOI.LessThan(-margin)]
    elseif guard.operator == :acoth && guard.lower >= 1
        return Any[MOI.GreaterThan(1.0 + margin)]
    elseif guard.operator == :acoth && guard.upper <= -1
        return Any[MOI.LessThan(-1.0 - margin)]
    elseif guard.operator in (:asec, :acsc, :asecd, :acscd) && guard.lower >= 1
        return Any[MOI.GreaterThan(1.0)]
    elseif guard.operator in (:asec, :acsc, :asecd, :acscd) && guard.upper <= -1
        return Any[MOI.LessThan(-1.0)]
    elseif guard.operator in (:tan, :sec, :csc, :cot, :tand, :secd, :cscd, :cotd)
        boundary = _elastic_periodic_endpoint_boundary(
            guard.operator, guard.lower, guard.upper,
        )
        isnothing(boundary) && throw(ArgumentError(
            "no endpoint-safe periodic guard is available for $(guard.operator)",
        ))
        side, singularity = boundary
        return Any[side == :lower ? MOI.GreaterThan(singularity + margin) :
                   MOI.LessThan(singularity - margin)]
    elseif guard.operator == :^ && startswith(guard.requirement, "base > 0")
        return Any[MOI.GreaterThan(margin)]
    elseif (guard.operator in (:inv, :/) || guard.operator == :^) && guard.lower >= 0
        return Any[MOI.GreaterThan(margin)]
    elseif (guard.operator in (:inv, :/) || guard.operator == :^) && guard.upper <= 0
        return Any[MOI.LessThan(-margin)]
    end
    throw(ArgumentError("no generic elastic domain guard set for $(guard.operator)"))
end

"""
    build_elastic_feasibility_model(model; objective_norm = :l1, weights = Dict(), relax_variable_bounds = false, selected_constraints = nothing, domain_guard_margin = nothing)

Build a separate `MOI.Utilities.Model{Float64}` in which supported scalar
affine, quadratic, nonlinear, and selected vector rows receive explicit
nonnegative slacks and the objective minimizes their optionally weighted sum.
The source model is never modified or solved. Unsupported constraints are
copied unchanged and remain listed by the returned plan.
Set `domain_guard_margin` to a positive value to add explicit lower-domain
guards for materializable selected nonlinear operators; the changed auxiliary
feasible region and every applied guard remain inspectable on the result.
"""
function build_elastic_feasibility_model(
    model::MOI.ModelLike;
    objective_norm::Symbol = :l1,
    weights::AbstractDict{EntityRef,<:Real} = Dict{EntityRef,Float64}(),
    relax_variable_bounds::Bool = false,
    selected_constraints::Union{Nothing,AbstractVector{EntityRef}} = nothing,
    domain_guard_margin::Union{Nothing,Real} = nothing,
)
    objective_norm in (:l1, :linf) || throw(ArgumentError("objective_norm must be :l1 or :linf"))
    !isnothing(domain_guard_margin) &&
        (!isfinite(domain_guard_margin) || domain_guard_margin <= 0) && throw(
            ArgumentError("domain_guard_margin must be finite and positive when domain guards are enabled"),
        )
    plan = elastic_feasibility_plan(
        model;
        relax_variable_bounds = relax_variable_bounds,
        selected_constraints = selected_constraints,
    )
    unknown_weight_sources = [
        source for source in keys(weights) if !any(==(source), plan.relaxable_constraints)
    ]
    isempty(unknown_weight_sources) || throw(ArgumentError(
        "elastic weights reference $(length(unknown_weight_sources)) constraint(s) outside the selected relaxation plan",
    ))
    # UniversalFallback preserves public MOI constraint representations that
    # the lightweight utility model does not store natively (for example,
    # scaled matrix cones). This remains a solver-free auxiliary container.
    auxiliary = MOI.Utilities.UniversalFallback(MOI.Utilities.Model{Float64}())
    index_map = MOI.copy_to(auxiliary, model)
    model_snapshot = snapshot(model)
    guard_margin = isnothing(domain_guard_margin) ? nothing : Float64(domain_guard_margin)
    guard_plan = isnothing(guard_margin) ? nothing : elastic_domain_guard_plan(
        model;
        relax_variable_bounds = relax_variable_bounds,
        selected_constraints = selected_constraints,
    )
    relaxations = ElasticRelaxation[]
    relaxed_constraint_map = Dict{EntityRef,Any}()
    weighted_slacks = Tuple{MOI.VariableIndex,Float64}[]
    for record in model_snapshot.constraints
        function_value = record.function_value
        set_value = record.set_value
        reference = _constraint_ref(record)
        reference in plan.relaxable_constraints || continue
        source = reference
        weight = Float64(get(weights, source, 1.0))
        isfinite(weight) && weight > 0 ||
            throw(ArgumentError("elastic relaxation weights must be finite and positive"))
        if function_value isa Union{MOI.VectorOfVariables,MOI.VectorAffineFunction{Float64}} &&
           set_value isa Union{MOI.SecondOrderCone,MOI.RotatedSecondOrderCone,MOI.NormOneCone,MOI.NormInfinityCone,MOI.NormCone,MOI.NormSpectralCone,MOI.NormNuclearCone,MOI.PowerCone,MOI.DualPowerCone,MOI.ExponentialCone,MOI.DualExponentialCone,MOI.GeometricMeanCone,MOI.RelativeEntropyCone,MOI.LogDetConeTriangle,MOI.LogDetConeSquare,MOI.RootDetConeTriangle,MOI.RootDetConeSquare,MOI.Scaled{MOI.LogDetConeTriangle},MOI.Scaled{MOI.RootDetConeTriangle},MOI.PositiveSemidefiniteConeTriangle,MOI.PositiveSemidefiniteConeSquare,MOI.Scaled{MOI.PositiveSemidefiniteConeTriangle},MOI.HermitianPositiveSemidefiniteConeTriangle,MOI.Scaled{MOI.HermitianPositiveSemidefiniteConeTriangle},MOI.Nonnegatives,MOI.Nonpositives,MOI.Zeros}
            target = index_map[record.index]
            MOI.delete(auxiliary, target)
            terms = if function_value isa MOI.VectorOfVariables
                MOI.VectorAffineTerm{Float64}[
                    MOI.VectorAffineTerm(row, MOI.ScalarAffineTerm(1.0, variable)) for
                    (row, variable) in enumerate(function_value.variables)
                ]
            else
                copy(function_value.terms)
            end
            constants = function_value isa MOI.VectorOfVariables ?
                        zeros(Float64, length(function_value.variables)) :
                        copy(function_value.constants)
            slacks = if set_value isa Union{MOI.Nonnegatives,MOI.Nonpositives}
                MOI.add_variables(auxiliary, MOI.dimension(set_value))
            elseif set_value isa MOI.Zeros
                MOI.add_variables(auxiliary, 2 * MOI.dimension(set_value))
            else
                [MOI.add_variable(auxiliary)]
            end
            for (position, slack) in enumerate(slacks)
                if set_value isa MOI.Zeros
                    row = cld(position, 2)
                    coefficient = isodd(position) ? 1.0 : -1.0
                    push!(terms, MOI.VectorAffineTerm(row, MOI.ScalarAffineTerm(coefficient, slack)))
                elseif set_value isa Union{MOI.PositiveSemidefiniteConeTriangle,MOI.Scaled{MOI.PositiveSemidefiniteConeTriangle},MOI.HermitianPositiveSemidefiniteConeTriangle,MOI.Scaled{MOI.HermitianPositiveSemidefiniteConeTriangle}}
                    row = 1
                    side_dimension = set_value isa MOI.Scaled ? set_value.set.side_dimension :
                                     set_value.side_dimension
                    for column in 1:side_dimension, coordinate in 1:column
                        if coordinate == column
                            push!(terms, MOI.VectorAffineTerm(
                                row, MOI.ScalarAffineTerm(1.0, slack),
                            ))
                        end
                        row += 1
                    end
                elseif set_value isa MOI.PositiveSemidefiniteConeSquare
                    for diagonal in 1:set_value.side_dimension
                        row = diagonal + (diagonal - 1) * set_value.side_dimension
                        push!(terms, MOI.VectorAffineTerm(
                            row, MOI.ScalarAffineTerm(1.0, slack),
                        ))
                    end
                elseif set_value isa MOI.PowerCone
                    push!(terms, MOI.VectorAffineTerm(1, MOI.ScalarAffineTerm(1.0, slack)))
                    push!(terms, MOI.VectorAffineTerm(2, MOI.ScalarAffineTerm(1.0, slack)))
                elseif set_value isa MOI.DualPowerCone
                    exponent = Float64(set_value.exponent)
                    push!(terms, MOI.VectorAffineTerm(1, MOI.ScalarAffineTerm(exponent, slack)))
                    push!(terms, MOI.VectorAffineTerm(2, MOI.ScalarAffineTerm(1.0 - exponent, slack)))
                else
                    coordinatewise = set_value isa Union{MOI.Nonnegatives,MOI.Nonpositives}
                    target_row = coordinatewise ? position :
                                 set_value isa Union{MOI.ExponentialCone,MOI.DualExponentialCone} ? 3 : 1
                    coefficient = set_value isa Union{MOI.Nonpositives,MOI.GeometricMeanCone,MOI.LogDetConeTriangle,MOI.LogDetConeSquare,MOI.RootDetConeTriangle,MOI.RootDetConeSquare,MOI.Scaled{MOI.LogDetConeTriangle},MOI.Scaled{MOI.RootDetConeTriangle}} ? -1.0 : 1.0
                    push!(terms, MOI.VectorAffineTerm(target_row, MOI.ScalarAffineTerm(coefficient, slack)))
                end
            end
            relaxed_constraint = MOI.add_constraint(auxiliary, MOI.VectorAffineFunction(
                terms, constants,
            ), set_value)
            for slack in slacks
                MOI.add_constraint(auxiliary, slack, MOI.GreaterThan(0.0))
                push!(weighted_slacks, (slack, weight))
            end
            kind = set_value isa MOI.SecondOrderCone ? :second_order_cone :
                   set_value isa MOI.RotatedSecondOrderCone ? :rotated_second_order_cone :
                   set_value isa MOI.NormOneCone ? :norm_one_cone :
                   set_value isa MOI.NormInfinityCone ? :norm_infinity_cone :
                   set_value isa MOI.NormCone ? :norm_cone :
                   set_value isa MOI.NormSpectralCone ? :norm_spectral_cone :
                   set_value isa MOI.NormNuclearCone ? :norm_nuclear_cone :
                   set_value isa MOI.PowerCone ? :power_cone :
                   set_value isa MOI.DualPowerCone ? :dual_power_cone :
                   set_value isa MOI.ExponentialCone ? :exponential_cone :
                   set_value isa MOI.DualExponentialCone ? :dual_exponential_cone :
                   set_value isa MOI.GeometricMeanCone ? :geometric_mean_cone :
                   set_value isa MOI.RelativeEntropyCone ? :relative_entropy_cone :
                   set_value isa MOI.LogDetConeTriangle ? :logdet_cone_triangle :
                   set_value isa MOI.LogDetConeSquare ? :logdet_cone_square :
                   set_value isa MOI.RootDetConeTriangle ? :rootdet_cone_triangle :
                   set_value isa MOI.RootDetConeSquare ? :rootdet_cone_square :
                   set_value isa MOI.Scaled{MOI.LogDetConeTriangle} ? :scaled_logdet_cone_triangle :
                   set_value isa MOI.Scaled{MOI.RootDetConeTriangle} ? :scaled_rootdet_cone_triangle :
                   set_value isa MOI.PositiveSemidefiniteConeTriangle ? :positive_semidefinite_cone_triangle :
                   set_value isa MOI.PositiveSemidefiniteConeSquare ? :positive_semidefinite_cone_square :
                   set_value isa MOI.Scaled{MOI.PositiveSemidefiniteConeTriangle} ? :scaled_positive_semidefinite_cone_triangle :
                   set_value isa MOI.HermitianPositiveSemidefiniteConeTriangle ? :hermitian_positive_semidefinite_cone_triangle :
                   set_value isa MOI.Scaled{MOI.HermitianPositiveSemidefiniteConeTriangle} ? :scaled_hermitian_positive_semidefinite_cone_triangle :
                   set_value isa MOI.Nonnegatives ? :nonnegatives :
                   set_value isa MOI.Nonpositives ? :nonpositives : :zeros
            push!(relaxations, ElasticRelaxation(source, slacks, weight, kind))
            relaxed_constraint_map[source] = relaxed_constraint
            continue
        end
        variable_bound = function_value isa MOI.VariableIndex
        if function_value isa MOI.VariableIndex
            relax_variable_bounds || continue
            function_value = MOI.ScalarAffineFunction(
                [MOI.ScalarAffineTerm(1.0, function_value)],
                0.0,
            )
        end
        function_value isa Union{MOI.ScalarAffineFunction{Float64},MOI.ScalarQuadraticFunction{Float64},MOI.ScalarNonlinearFunction} || continue
        set_value isa Union{MOI.LessThan{Float64},MOI.GreaterThan{Float64},MOI.EqualTo{Float64}} || continue
        target = index_map[record.index]
        MOI.delete(auxiliary, target)
        slacks = MOI.VariableIndex[]
        if set_value isa MOI.EqualTo{Float64}
            positive, negative = MOI.add_variables(auxiliary, 2)
            append!(slacks, (positive, negative))
            relaxed = _elastic_function(function_value, [
                MOI.ScalarAffineTerm(1.0, positive),
                MOI.ScalarAffineTerm(-1.0, negative),
            ])
            relaxed_constraint = MOI.add_constraint(auxiliary, relaxed, set_value)
        else
            slack = MOI.add_variable(auxiliary)
            push!(slacks, slack)
            coefficient = set_value isa MOI.LessThan{Float64} ? -1.0 : 1.0
            relaxed = _elastic_function(
                function_value,
                [MOI.ScalarAffineTerm(coefficient, slack)],
            )
            relaxed_constraint = MOI.add_constraint(auxiliary, relaxed, set_value)
        end
        for slack in slacks
            MOI.add_constraint(auxiliary, slack, MOI.GreaterThan(0.0))
        end
        append!(weighted_slacks, (slack, weight) for slack in slacks)
        kind = if variable_bound
            :variable_bound
        elseif set_value isa MOI.EqualTo{Float64}
            :equality
        elseif set_value isa MOI.LessThan{Float64}
            :upper_bound
        else
            :lower_bound
        end
        push!(relaxations, ElasticRelaxation(source, slacks, weight, kind))
        relaxed_constraint_map[source] = relaxed_constraint
    end
    applied_domain_guards = ElasticDomainGuard[]
    if !isnothing(guard_plan)
        for guard in guard_plan.guards
            guard.materializable || continue
            argument = _elastic_domain_argument(model_snapshot, guard)
            isnothing(argument) && throw(ErrorException(
                "elastic domain guard plan/build argument mismatch",
            ))
            mapped_argument = _map_elastic_guard_argument(argument, index_map)
            if !isnothing(guard.related_argument)
                related_argument = _elastic_domain_argument(
                    model_snapshot, guard, guard.related_argument,
                )
                isnothing(related_argument) && throw(ErrorException(
                    "elastic relational domain guard plan/build argument mismatch",
                ))
                mapped_related_argument = _map_elastic_guard_argument(
                    related_argument, index_map,
                )
                mapped_argument = _elastic_affine_difference(
                    mapped_argument, mapped_related_argument,
                )
            end
            for set_value in _elastic_domain_guard_sets(guard, guard_margin)
                MOI.add_constraint(auxiliary, mapped_argument, set_value)
            end
            push!(applied_domain_guards, guard)
        end
    end
    epigraph = nothing
    objective = if objective_norm == :l1
        MOI.ScalarAffineFunction(
            MOI.ScalarAffineTerm{Float64}[
                MOI.ScalarAffineTerm(weight, slack) for (slack, weight) in weighted_slacks
            ],
            0.0,
        )
    elseif isempty(weighted_slacks)
        MOI.ScalarAffineFunction(MOI.ScalarAffineTerm{Float64}[], 0.0)
    else
        epigraph = MOI.add_variable(auxiliary)
        MOI.add_constraint(auxiliary, epigraph, MOI.GreaterThan(0.0))
        for (slack, weight) in weighted_slacks
            MOI.add_constraint(auxiliary, MOI.ScalarAffineFunction([
                MOI.ScalarAffineTerm(weight, slack),
                MOI.ScalarAffineTerm(-1.0, epigraph),
            ], 0.0), MOI.LessThan(0.0))
        end
        MOI.ScalarAffineFunction([MOI.ScalarAffineTerm(1.0, epigraph)], 0.0)
    end
    MOI.set(auxiliary, MOI.ObjectiveSense(), MOI.MIN_SENSE)
    MOI.set(auxiliary, MOI.ObjectiveFunction{MOI.ScalarAffineFunction{Float64}}(), objective)
    length(weighted_slacks) == plan.slack_count || throw(ErrorException(
        "elastic plan/build slack-count mismatch",
    ))
    source_variable_map = Dict(
        record.index => index_map[record.index] for record in model_snapshot.variables
    )
    return ElasticFeasibilityModel(
        auxiliary, plan, relaxations, source_variable_map, objective_norm, epigraph,
        relaxed_constraint_map, applied_domain_guards, guard_margin,
    )
end

"""
    solve_elastic_feasibility!(optimizer, auxiliary)

Copy and solve a separately built elastic auxiliary model with an explicitly
provided empty optimizer. The source model is not accessed or modified.
"""
function solve_elastic_feasibility!(
    optimizer::MOI.AbstractOptimizer,
    auxiliary::ElasticFeasibilityModel,
)
    MOI.is_empty(optimizer) || throw(ArgumentError(
        "elastic auxiliary optimizer must be empty before copying the auxiliary model",
    ))
    index_map = MOI.copy_to(optimizer, auxiliary.model)
    MOI.optimize!(optimizer)
    slack_map = Dict(
        slack => index_map[slack] for relaxation in auxiliary.relaxations for
        slack in relaxation.slacks
    )
    return ElasticFeasibilitySolve(auxiliary, optimizer, slack_map)
end

"""Map caller-supplied auxiliary slack values back to original constraints."""
function elastic_relaxation_values(auxiliary::ElasticFeasibilityModel, values::AbstractDict{MOI.VariableIndex,<:Real})
    result = ElasticRelaxationValue[]
    for relaxation in auxiliary.relaxations
        slack_values = Float64[]
        for slack in relaxation.slacks
            haskey(values, slack) || throw(ArgumentError("missing value for elastic slack $(slack.value)"))
            value = Float64(values[slack])
            isfinite(value) || throw(ArgumentError("elastic slack values must be finite"))
            value >= 0 || throw(ArgumentError("elastic slack values must be nonnegative"))
            push!(slack_values, value)
        end
        total = sum(slack_values)
        push!(result, ElasticRelaxationValue(
            relaxation.source,
            slack_values,
            total,
            relaxation.weight * total,
            relaxation.kind,
        ))
    end
    return result
end

"""Evaluate the configured elastic L1 or L∞ objective from explicit slack values."""
function elastic_objective_value(
    auxiliary::ElasticFeasibilityModel,
    values::AbstractDict{MOI.VariableIndex,<:Real},
)
    observed = elastic_relaxation_values(auxiliary, values)
    weighted = [item.weighted_total for item in observed]
    return auxiliary.objective_norm == :l1 ? sum(weighted) :
           (isempty(weighted) ? 0.0 : maximum(weighted))
end

function elastic_objective_value(
    solved::ElasticFeasibilitySolve;
    result_index::Integer = 1,
)
    observed = elastic_relaxation_values(solved; result_index = result_index)
    weighted = [item.weighted_total for item in observed]
    return solved.auxiliary.objective_norm == :l1 ? sum(weighted) :
           (isempty(weighted) ? 0.0 : maximum(weighted))
end

"""Read slack primals from a solved auxiliary model and map them to source rows."""
function elastic_relaxation_values(
    auxiliary::ElasticFeasibilityModel;
    result_index::Integer = 1,
)
    result_index > 0 || throw(ArgumentError("result_index must be positive"))
    result_count = try
        MOI.get(auxiliary.model, MOI.ResultCount())
    catch error
        throw(ArgumentError(
            "elastic auxiliary model does not expose solver results: $(sprint(showerror, error))",
        ))
    end
    result_count >= result_index || throw(ArgumentError(
        "elastic auxiliary model has $result_count result(s), not result $result_index",
    ))
    values = Dict{MOI.VariableIndex,Float64}()
    for relaxation in auxiliary.relaxations, slack in relaxation.slacks
        value = try
            MOI.get(auxiliary.model, MOI.VariablePrimal(result_index), slack)
        catch error
            throw(ArgumentError(
                "elastic auxiliary result $result_index does not expose primal value for slack $(slack.value): $(sprint(showerror, error))",
            ))
        end
        value isa Real || throw(ArgumentError(
            "elastic auxiliary result $result_index does not expose a real primal value for slack $(slack.value)",
        ))
        values[slack] = Float64(value)
    end
    return elastic_relaxation_values(auxiliary, values)
end

function elastic_relaxation_values(
    solved::ElasticFeasibilitySolve;
    result_index::Integer = 1,
)
    result_index > 0 || throw(ArgumentError("result_index must be positive"))
    result_count = MOI.get(solved.optimizer, MOI.ResultCount())
    result_count >= result_index || throw(ArgumentError(
        "elastic auxiliary optimizer has $result_count result(s), not result $result_index",
    ))
    values = Dict{MOI.VariableIndex,Float64}()
    for (auxiliary_slack, solver_slack) in solved.slack_map
        value = MOI.get(solved.optimizer, MOI.VariablePrimal(result_index), solver_slack)
        value isa Real || throw(ArgumentError("elastic solver result does not expose a real slack primal"))
        values[auxiliary_slack] = Float64(value)
    end
    return elastic_relaxation_values(solved.auxiliary, values)
end

"""Describe the exact source-coordinate change made by an elastic auxiliary slack."""
function _elastic_relaxation_geometry(kind::Symbol)
    kind in (:upper_bound, :lower_bound, :equality, :variable_bound) &&
        return "scalar residual relaxation"
    kind in (:second_order_cone, :rotated_second_order_cone, :norm_one_cone,
             :norm_infinity_cone, :norm_cone, :norm_spectral_cone,
             :norm_nuclear_cone) &&
        return "leading epigraph coordinate increased by slack"
    kind in (:exponential_cone, :dual_exponential_cone) &&
        return "third exponential-cone epigraph coordinate increased by slack"
    kind == :relative_entropy_cone &&
        return "leading relative-entropy upper-bound coordinate increased by slack"
    kind in (:geometric_mean_cone, :logdet_cone_triangle, :logdet_cone_square,
             :rootdet_cone_triangle, :rootdet_cone_square,
             :scaled_logdet_cone_triangle, :scaled_rootdet_cone_triangle) &&
        return "leading hypograph coordinate decreased by slack"
    kind == :power_cone &&
        return "both positive power-cone coordinates increased by the same slack"
    kind == :dual_power_cone &&
        return "dual-power coordinates increased by α times slack and (1-α) times slack"
    kind in (:positive_semidefinite_cone_triangle,
             :scaled_positive_semidefinite_cone_triangle,
             :positive_semidefinite_cone_square,
             :hermitian_positive_semidefinite_cone_triangle,
             :scaled_hermitian_positive_semidefinite_cone_triangle) &&
        return "matrix diagonal shifted by slack (X + sI)"
    kind == :nonnegatives && return "each nonnegative coordinate increased by its slack"
    kind == :nonpositives && return "each nonpositive coordinate decreased by its slack"
    kind == :zeros && return "each zero coordinate receives signed positive/negative slacks"
    return "auxiliary relaxation geometry is not classified"
end

"""Report original rows that needed positive caller-supplied elastic slack."""
function analyze_elastic_relaxations(auxiliary::ElasticFeasibilityModel, values::AbstractDict{MOI.VariableIndex,<:Real}; tolerance::Real = sqrt(eps(Float64)))
    tolerance >= 0 || throw(ArgumentError("tolerance must be nonnegative"))
    report = DiagnosticReport()
    report.metadata[:stage] = "elastic_relaxations"
    report.metadata[:elastic_objective_norm] = string(auxiliary.objective_norm)
    report.metadata[:elastic_domain_guard_count] = string(length(auxiliary.domain_guards))
    report.metadata[:elastic_domain_guard_margin] = isnothing(auxiliary.domain_guard_margin) ?
        "disabled" : string(auxiliary.domain_guard_margin)
    observed = elastic_relaxation_values(auxiliary, values)
    report.metadata[:elastic_relaxation_count] = string(length(observed))
    positive = 0
    for item in observed
        item.total <= tolerance && continue
        positive += 1
        geometry = _elastic_relaxation_geometry(item.kind)
        push!(report, Finding(:elastic_constraint_relaxed;
            severity = SeverityWarning, domain = MathematicalIssue,
            basis = NumericalObservation, confidence = ConfidenceHigh,
            observation = "Elastic auxiliary values apply $(item.kind) relaxation to constraint $(item.source.index) with total slack $(item.total) and weighted slack magnitude $(item.weighted_total).",
            why_it_matters = "This identifies a row requiring relaxation in the supplied auxiliary point; it is not an IIS or a proof that this row alone causes infeasibility.",
            evidence = [Evidence("Elastic relaxation values"; details = ["kind" => item.kind, "geometry" => geometry, "slacks" => join(item.values, ","), "total" => item.total, "weighted_slack_magnitude" => item.weighted_total, "objective_norm" => auxiliary.objective_norm, "tolerance" => tolerance])],
            affected = [item.source],
            suggested_actions = ["Inspect this row with related bounds and constraints; compare alternative elastic objectives before assigning causality."],
        ))
    end
    report.metadata[:positive_elastic_relaxation_count] = string(positive)
    return report
end

function analyze_elastic_relaxations(
    auxiliary::ElasticFeasibilityModel;
    result_index::Integer = 1,
    tolerance::Real = sqrt(eps(Float64)),
)
    values = elastic_relaxation_values(auxiliary; result_index = result_index)
    by_slack = Dict{MOI.VariableIndex,Float64}()
    for (relaxation, observation) in zip(auxiliary.relaxations, values)
        for (slack, value) in zip(relaxation.slacks, observation.values)
            by_slack[slack] = value
        end
    end
    return analyze_elastic_relaxations(auxiliary, by_slack; tolerance = tolerance)
end

function analyze_elastic_relaxations(
    solved::ElasticFeasibilitySolve;
    result_index::Integer = 1,
    tolerance::Real = sqrt(eps(Float64)),
    objective_agreement_tolerance::Real = sqrt(eps(Float64)),
)
    objective_agreement_tolerance >= 0 || throw(
        ArgumentError("objective_agreement_tolerance must be nonnegative"),
    )
    observed = elastic_relaxation_values(solved; result_index = result_index)
    values = Dict{MOI.VariableIndex,Float64}()
    for (relaxation, observation) in zip(solved.auxiliary.relaxations, observed)
        for (slack, value) in zip(relaxation.slacks, observation.values)
            values[slack] = value
        end
    end
    report = analyze_elastic_relaxations(solved.auxiliary, values; tolerance = tolerance)
    report.metadata[:elastic_result_source] = "solver"
    report.metadata[:elastic_result_index] = string(result_index)
    report.metadata[:elastic_optimizer_type] = string(typeof(solved.optimizer))
    report.metadata[:elastic_termination_status] = try
        string(MOI.get(solved.optimizer, MOI.TerminationStatus()))
    catch error
        "unavailable: $(typeof(error))"
    end
    report.metadata[:elastic_primal_status] = try
        string(MOI.get(solved.optimizer, MOI.PrimalStatus(result_index)))
    catch error
        "unavailable: $(typeof(error))"
    end
    recomputed_objective = elastic_objective_value(solved; result_index = result_index)
    report.metadata[:elastic_recomputed_objective] = string(recomputed_objective)
    solver_objective = try
        Float64(MOI.get(solved.optimizer, MOI.ObjectiveValue(result_index)))
    catch error
        nothing
    end
    report.metadata[:elastic_solver_objective] = isnothing(solver_objective) ?
        "unavailable" : string(solver_objective)
    if !isnothing(solver_objective) && isfinite(solver_objective) &&
       abs(solver_objective - recomputed_objective) >
       objective_agreement_tolerance * max(1.0, abs(solver_objective), abs(recomputed_objective))
        push!(report, Finding(:elastic_solver_objective_mismatch;
            severity = SeverityInfo, domain = RepresentationalIssue,
            basis = NumericalObservation, confidence = ConfidenceMedium,
            observation = "The solver reports elastic objective $solver_objective, while mapped slack values recompute $recomputed_objective.",
            why_it_matters = "A mismatch can reflect solver objective reporting, copied-model mapping, or result-index semantics; it is evidence to inspect, not a solver-error claim.",
            evidence = [Evidence("Elastic objective comparison"; details = ["solver_objective" => solver_objective, "recomputed_objective" => recomputed_objective, "relative_tolerance" => objective_agreement_tolerance])],
            suggested_actions = ["Check the copied auxiliary model, objective norm, weights, and selected result index."],
        ))
    end
    return report
end

function _elastic_subset_status(optimizer::MOI.AbstractOptimizer)
    termination = try
        string(MOI.get(optimizer, MOI.TerminationStatus()))
    catch error
        "unavailable: $(typeof(error))"
    end
    primal = try
        string(MOI.get(optimizer, MOI.PrimalStatus(1)))
    catch error
        "unavailable: $(typeof(error))"
    end
    return termination, primal
end

function _elastic_subset_probe(
    model::MOI.ModelLike,
    optimizer_factory::Function,
    selected_constraints::Vector{EntityRef};
    objective_norm::Symbol,
    weights::AbstractDict{EntityRef,<:Real},
    relax_variable_bounds::Bool,
)
    auxiliary = build_elastic_feasibility_model(model;
        objective_norm = objective_norm,
        weights = weights,
        relax_variable_bounds = relax_variable_bounds,
        selected_constraints = selected_constraints,
    )
    optimizer = optimizer_factory()
    optimizer isa MOI.AbstractOptimizer || throw(ArgumentError(
        "optimizer_factory must return an MOI.AbstractOptimizer",
    ))
    solved = solve_elastic_feasibility!(optimizer, auxiliary)
    termination, primal = _elastic_subset_status(optimizer)
    objective = try
        elastic_objective_value(solved)
    catch
        nothing
    end
    return ElasticSubsetProbe(
        copy(selected_constraints), objective, !isnothing(objective), termination, primal,
    )
end

"""
    local_elastic_subset_search(model, optimizer_factory; kwargs...)

Run a greedy, order-dependent reduction of an explicitly selected elastic
scope. A candidate row is removed only when making that row hard still yields
a solved auxiliary point whose mapped slack objective is at most `tolerance`.
The returned subset is an IIS-like local explanation, not an IIS certificate:
it depends on the supplied scope, weights, norm, optimizer results, and order.
The source model is never modified.
"""
function local_elastic_subset_search(
    model::MOI.ModelLike,
    optimizer_factory::Function;
    objective_norm::Symbol = :l1,
    weights::AbstractDict{EntityRef,<:Real} = Dict{EntityRef,Float64}(),
    relax_variable_bounds::Bool = false,
    selected_constraints::Union{Nothing,AbstractVector{EntityRef}} = nothing,
    tolerance::Real = sqrt(eps(Float64)),
)
    tolerance >= 0 || throw(ArgumentError("tolerance must be nonnegative"))
    initial_plan = elastic_feasibility_plan(model;
        relax_variable_bounds = relax_variable_bounds,
        selected_constraints = selected_constraints,
    )
    initial_scope = isnothing(selected_constraints) ?
                    copy(initial_plan.relaxable_constraints) :
                    collect(selected_constraints)
    isempty(initial_scope) && throw(ArgumentError(
        "local elastic subset search requires at least one eligible selected constraint",
    ))
    baseline = _elastic_subset_probe(model, optimizer_factory, initial_scope;
        objective_norm = objective_norm,
        weights = weights,
        relax_variable_bounds = relax_variable_bounds,
    )
    baseline.has_primal_result || throw(ArgumentError(
        "baseline elastic auxiliary has no readable primal result; inspect its solver status before subset reduction",
    ))
    retained = copy(initial_scope)
    removed = EntityRef[]
    probes = ElasticSubsetProbe[]
    if baseline.objective_value > tolerance
        for candidate in initial_scope
            candidate in retained || continue
            trial_scope = [source for source in retained if source != candidate]
            trial = _elastic_subset_probe(model, optimizer_factory, trial_scope;
                objective_norm = objective_norm,
                weights = weights,
                relax_variable_bounds = relax_variable_bounds,
            )
            push!(probes, trial)
            if trial.has_primal_result && trial.objective_value <= tolerance
                filter!(source -> source != candidate, retained)
                push!(removed, candidate)
            end
        end
    else
        append!(removed, retained)
        empty!(retained)
    end
    return ElasticSubsetSearch(
        baseline, probes, retained, removed, Float64(tolerance),
    )
end

"""Turn a local elastic-subset experiment into explicitly scope-dependent findings."""
function analyze_local_elastic_subset_search(search::ElasticSubsetSearch)
    report = DiagnosticReport()
    report.metadata[:stage] = "local_elastic_subset_search"
    report.metadata[:elastic_subset_baseline_objective] = isnothing(search.baseline.objective_value) ?
        "unavailable" : string(search.baseline.objective_value)
    report.metadata[:elastic_subset_baseline_termination] = search.baseline.termination_status
    report.metadata[:elastic_subset_baseline_primal] = search.baseline.primal_status
    report.metadata[:elastic_subset_probe_count] = string(length(search.probes))
    report.metadata[:elastic_subset_retained_count] = string(length(search.retained_constraints))
    report.metadata[:elastic_subset_removed_count] = string(length(search.removed_constraints))
    report.metadata[:elastic_subset_tolerance] = string(search.tolerance)
    if isempty(search.retained_constraints)
        push!(report, Finding(:elastic_subset_no_positive_residual;
            severity = SeverityInfo, domain = MathematicalIssue,
            basis = NumericalObservation, confidence = ConfidenceHigh,
            observation = "The baseline elastic auxiliary objective is at most the selected tolerance, so this scope has no positive elastic residual at the supplied solver result.",
            why_it_matters = "No IIS-like subset is inferred from a zero elastic residual; solver status and unsupported rows remain separate evidence.",
            evidence = [Evidence("Elastic subset baseline"; details = ["objective" => search.baseline.objective_value, "tolerance" => search.tolerance, "termination_status" => search.baseline.termination_status, "primal_status" => search.baseline.primal_status])],
            suggested_actions = ["Inspect unsupported constraints and solver status before treating this as a feasibility certificate."],
        ))
    else
        push!(report, Finding(:elastic_subset_local_explanation;
            severity = SeverityWarning, domain = MathematicalIssue,
            basis = LocalInference, confidence = ConfidenceMedium,
            observation = "Greedy elastic reduction retained $(length(search.retained_constraints)) row(s) in a local positive-residual explanation.",
            why_it_matters = "The retained rows depend on the selected scope, order, weights, objective norm, and solver results; they are not an IIS or individual causal proof.",
            evidence = [Evidence("Elastic subset reduction"; details = ["baseline_objective" => search.baseline.objective_value, "retained_count" => length(search.retained_constraints), "removed_count" => length(search.removed_constraints), "probe_count" => length(search.probes), "tolerance" => search.tolerance])],
            affected = search.retained_constraints,
            suggested_actions = ["Re-run with alternate row orders, weights, and scopes; inspect retained rows together with fixed bounds and unsupported constraints."],
        ))
    end
    return report
end

"""
    local_elastic_subset_ensemble(model, optimizer_factory; orders = nothing, kwargs...)

Run local elastic subset reductions in several deletion orders. With no
explicit `orders`, the selected scope is run forward and reverse (once for a
singleton). The consensus is the intersection of retained rows; the possible
set is their union. Both remain local, solver-dependent evidence rather than
an IIS certificate.
"""
function local_elastic_subset_ensemble(
    model::MOI.ModelLike,
    optimizer_factory::Function;
    orders::Union{Nothing,AbstractVector{<:AbstractVector{EntityRef}}} = nothing,
    objective_norm::Symbol = :l1,
    weights::AbstractDict{EntityRef,<:Real} = Dict{EntityRef,Float64}(),
    relax_variable_bounds::Bool = false,
    selected_constraints::Union{Nothing,AbstractVector{EntityRef}} = nothing,
    tolerance::Real = sqrt(eps(Float64)),
)
    plan = elastic_feasibility_plan(model;
        relax_variable_bounds = relax_variable_bounds,
        selected_constraints = selected_constraints,
    )
    scope = isnothing(selected_constraints) ?
            copy(plan.relaxable_constraints) : collect(selected_constraints)
    isempty(scope) && throw(ArgumentError(
        "local elastic subset ensemble requires at least one eligible selected constraint",
    ))
    run_orders = if isnothing(orders)
        length(scope) == 1 ? [scope] : [scope, reverse(copy(scope))]
    else
        [collect(order) for order in orders]
    end
    isempty(run_orders) && throw(ArgumentError("orders must contain at least one deletion order"))
    for order in run_orders
        length(order) == length(scope) &&
        all(source -> count(==(source), order) == 1, scope) || throw(ArgumentError(
            "every deletion order must contain each selected eligible constraint exactly once",
        ))
    end
    searches = ElasticSubsetSearch[]
    for order in run_orders
        push!(searches, local_elastic_subset_search(model, optimizer_factory;
            objective_norm = objective_norm,
            weights = weights,
            relax_variable_bounds = relax_variable_bounds,
            selected_constraints = order,
            tolerance = tolerance,
        ))
    end
    consensus = [source for source in scope if all(
        search -> source in search.retained_constraints, searches,
    )]
    possible = [source for source in scope if any(
        search -> source in search.retained_constraints, searches,
    )]
    return ElasticSubsetEnsemble(searches, consensus, possible)
end

"""Report consensus and order-sensitive rows from local elastic subset reductions."""
function analyze_local_elastic_subset_ensemble(ensemble::ElasticSubsetEnsemble)
    report = DiagnosticReport()
    report.metadata[:stage] = "local_elastic_subset_ensemble"
    report.metadata[:elastic_subset_order_count] = string(length(ensemble.searches))
    report.metadata[:elastic_subset_consensus_count] = string(length(ensemble.consensus_constraints))
    report.metadata[:elastic_subset_possible_count] = string(length(ensemble.possible_constraints))
    if !isempty(ensemble.consensus_constraints)
        push!(report, Finding(:elastic_subset_order_consensus;
            severity = SeverityWarning, domain = MathematicalIssue,
            basis = LocalInference, confidence = ConfidenceMedium,
            observation = "$(length(ensemble.consensus_constraints)) row(s) were retained by every supplied local elastic deletion order.",
            why_it_matters = "Order agreement is stronger local evidence than a single greedy run, but remains dependent on scope, weights, tolerance, and solver results.",
            evidence = [Evidence("Elastic subset order ensemble"; details = ["order_count" => length(ensemble.searches), "consensus_count" => length(ensemble.consensus_constraints), "possible_count" => length(ensemble.possible_constraints)])],
            affected = ensemble.consensus_constraints,
            suggested_actions = ["Inspect these rows jointly and repeat with alternate scopes or elastic weights before assigning causality."],
        ))
    end
    order_sensitive = [source for source in ensemble.possible_constraints if
                       !(source in ensemble.consensus_constraints)]
    if !isempty(order_sensitive)
        push!(report, Finding(:elastic_subset_order_sensitive;
            severity = SeverityInfo, domain = RepresentationalIssue,
            basis = HeuristicInterpretation, confidence = ConfidenceHigh,
            observation = "$(length(order_sensitive)) row(s) are retained by some but not all supplied deletion orders.",
            why_it_matters = "Their membership is sensitive to the greedy procedure, so they should not be interpreted as a stable conflict core.",
            evidence = [Evidence("Elastic subset order ensemble"; details = ["order_count" => length(ensemble.searches), "order_sensitive_count" => length(order_sensitive)])],
            affected = order_sensitive,
            suggested_actions = ["Use the consensus rows for prioritization; vary weights or use a dedicated IIS-capable solver for stronger conclusions."],
        ))
    end
    return report
end

function _visit_elastic_subsets(
    scope::Vector{EntityRef},
    cardinality::Int,
    callback::Function,
)
    selected = EntityRef[]
    function visit(start::Int, remaining::Int)
        if remaining == 0
            return callback(copy(selected))
        end
        last_start = length(scope) - remaining + 1
        for index in start:last_start
            push!(selected, scope[index])
            stop = visit(index + 1, remaining - 1)
            pop!(selected)
            stop && return true
        end
        return false
    end
    return visit(1, cardinality)
end

"""
    minimum_elastic_relaxation_search(model, optimizer_factory; max_subsets = 1_000, kwargs...)

Enumerate selected relaxation scopes in increasing cardinality until finding
all zero-residual scopes at the first successful cardinality, or until the
explicit `max_subsets` budget is exhausted. This identifies a minimum elastic
relaxation support under the chosen auxiliary construction, not an IIS or a
proof of original-model infeasibility.
"""
function minimum_elastic_relaxation_search(
    model::MOI.ModelLike,
    optimizer_factory::Function;
    max_subsets::Integer = 1_000,
    max_relaxations::Union{Nothing,Integer} = nothing,
    objective_norm::Symbol = :l1,
    weights::AbstractDict{EntityRef,<:Real} = Dict{EntityRef,Float64}(),
    relax_variable_bounds::Bool = false,
    selected_constraints::Union{Nothing,AbstractVector{EntityRef}} = nothing,
    tolerance::Real = sqrt(eps(Float64)),
)
    max_subsets > 0 || throw(ArgumentError("max_subsets must be positive"))
    tolerance >= 0 || throw(ArgumentError("tolerance must be nonnegative"))
    plan = elastic_feasibility_plan(model;
        relax_variable_bounds = relax_variable_bounds,
        selected_constraints = selected_constraints,
    )
    scope = isnothing(selected_constraints) ?
            copy(plan.relaxable_constraints) : collect(selected_constraints)
    maximum_size = isnothing(max_relaxations) ? length(scope) : Int(max_relaxations)
    0 <= maximum_size <= length(scope) || throw(ArgumentError(
        "max_relaxations must lie between zero and the selected eligible constraint count",
    ))
    evaluated = 0
    truncated = false
    solutions = ElasticSubsetProbe[]
    minimum_count = nothing
    for cardinality in 0:maximum_size
        stop = _visit_elastic_subsets(scope, cardinality) do subset
            if evaluated >= max_subsets
                truncated = true
                return true
            end
            probe = _elastic_subset_probe(model, optimizer_factory, subset;
                objective_norm = objective_norm,
                weights = weights,
                relax_variable_bounds = relax_variable_bounds,
            )
            evaluated += 1
            if probe.has_primal_result && probe.objective_value <= tolerance
                push!(solutions, probe)
                minimum_count = cardinality
            end
            return false
        end
        truncated && break
        !isempty(solutions) && break
        stop && break
    end
    return ElasticMinimumRelaxationSearch(
        scope, minimum_count, solutions, evaluated, truncated, Float64(tolerance),
    )
end

"""Report a bounded minimum elastic-relaxation support search without overstating it as an IIS."""
function analyze_minimum_elastic_relaxation_search(search::ElasticMinimumRelaxationSearch)
    report = DiagnosticReport()
    report.metadata[:stage] = "minimum_elastic_relaxation_search"
    report.metadata[:elastic_minimum_candidate_count] = string(length(search.candidate_constraints))
    report.metadata[:elastic_minimum_evaluated_count] = string(search.evaluated_count)
    report.metadata[:elastic_minimum_solution_count] = string(length(search.solutions))
    report.metadata[:elastic_minimum_relaxation_count] = isnothing(search.minimum_relaxation_count) ?
        "unavailable" : string(search.minimum_relaxation_count)
    report.metadata[:elastic_minimum_truncated] = string(search.truncated)
    report.metadata[:elastic_minimum_tolerance] = string(search.tolerance)
    if !isempty(search.solutions)
        affected = unique(vcat((probe.selected_constraints for probe in search.solutions)...))
        push!(report, Finding(:elastic_minimum_relaxation_support;
            severity = SeverityWarning, domain = MathematicalIssue,
            basis = LocalInference, confidence = ConfidenceMedium,
            observation = "The bounded search found $(length(search.solutions)) minimum-cardinality zero-residual elastic relaxation support(s) of size $(search.minimum_relaxation_count).",
            why_it_matters = "These supports identify rows that can be relaxed to restore the selected auxiliary scope under this norm and solver result; they are not IISes or individual causal proofs.",
            evidence = [Evidence("Minimum elastic relaxation search"; details = ["minimum_relaxation_count" => search.minimum_relaxation_count, "solution_count" => length(search.solutions), "evaluated_count" => search.evaluated_count, "truncated" => search.truncated, "tolerance" => search.tolerance])],
            affected = affected,
            suggested_actions = ["Compare alternative weights and scopes; inspect every row in each minimum support before changing the formulation."],
        ))
    elseif !search.truncated
        push!(report, Finding(:elastic_minimum_relaxation_not_found;
            severity = SeverityInfo, domain = MathematicalIssue,
            basis = NumericalObservation, confidence = ConfidenceMedium,
            observation = "No zero-residual elastic relaxation support was found in the enumerated scope.",
            why_it_matters = "This may reflect hard unsupported rows, domain guards, solver results, or the selected auxiliary construction; it is not an infeasibility certificate.",
            evidence = [Evidence("Minimum elastic relaxation search"; details = ["evaluated_count" => search.evaluated_count, "candidate_count" => length(search.candidate_constraints), "tolerance" => search.tolerance])],
            suggested_actions = ["Inspect unsupported constraints and solver statuses, or enlarge the selected scope if that matches the diagnostic question."],
        ))
    end
    if search.truncated
        push!(report, Finding(:elastic_minimum_relaxation_truncated;
            severity = SeverityInfo, domain = RepresentationalIssue,
            basis = StructuralProof, confidence = ConfidenceCertain,
            observation = "The minimum relaxation search stopped after its explicit subset-enumeration budget.",
            why_it_matters = "No claim of cardinality minimality is valid when the enumeration is incomplete.",
            evidence = [Evidence("Minimum elastic relaxation search budget"; details = ["evaluated_count" => search.evaluated_count])],
            suggested_actions = ["Increase max_subsets cautiously or use a solver with dedicated conflict/IIS support."],
        ))
    end
    return report
end

"""
    compute_solver_conflict!(optimizer, model; optimize_before_conflict = true)

Copy `model` into an explicitly supplied empty optimizer, optionally optimize
that copy, then ask the optimizer for an MOI conflict. Constraint memberships
are mapped back to source references. Neither the source model nor an existing
solver attachment is modified. Solver conflict output remains solver-provided
evidence, not a mathematical infeasibility proof.
"""
function compute_solver_conflict!(
    optimizer::MOI.AbstractOptimizer,
    model::MOI.ModelLike;
    optimize_before_conflict::Bool = true,
)
    MOI.is_empty(optimizer) || throw(ArgumentError(
        "conflict optimizer must be empty before copying the source model",
    ))
    model_snapshot = snapshot(model)
    source_variable_count = length(model_snapshot.variables)
    source_constraint_count = length(model_snapshot.constraints)
    index_map = MOI.copy_to(optimizer, model)
    optimize_before_conflict && MOI.optimize!(optimizer)
    termination = try
        string(MOI.get(optimizer, MOI.TerminationStatus()))
    catch error
        "unavailable: $(typeof(error))"
    end
    try
        MOI.compute_conflict!(optimizer)
    catch error
        return SolverConflictResult(
            string(typeof(optimizer)), optimize_before_conflict, termination,
            "unavailable", source_variable_count, source_constraint_count,
            Vector{Vector{EntityRef}}(), Vector{Vector{EntityRef}}(),
            sprint(showerror, error),
        )
    end
    status = try
        MOI.get(optimizer, MOI.ConflictStatus())
    catch error
        return SolverConflictResult(
            string(typeof(optimizer)), optimize_before_conflict, termination,
            "unavailable", source_variable_count, source_constraint_count,
            Vector{Vector{EntityRef}}(), Vector{Vector{EntityRef}}(),
            "could not read MOI.ConflictStatus: $(sprint(showerror, error))",
        )
    end
    conflict_count = try
        MOI.get(optimizer, MOI.ConflictCount())
    catch
        0
    end
    conflicts = Vector{Vector{EntityRef}}()
    maybe_conflicts = Vector{Vector{EntityRef}}()
    for conflict_index in 1:conflict_count
        members = EntityRef[]
        maybes = EntityRef[]
        for record in model_snapshot.constraints
            mapped = index_map[record.index]
            membership = try
                MOI.get(
                    optimizer, MOI.ConstraintConflictStatus(conflict_index), mapped,
                )
            catch
                nothing
            end
            membership == MOI.IN_CONFLICT && push!(members, _constraint_ref(record))
            membership == MOI.MAYBE_IN_CONFLICT && push!(maybes, _constraint_ref(record))
        end
        push!(conflicts, members)
        push!(maybe_conflicts, maybes)
    end
    return SolverConflictResult(
        string(typeof(optimizer)), optimize_before_conflict, termination,
        string(status), source_variable_count, source_constraint_count,
        conflicts, maybe_conflicts, nothing,
    )
end

"""Turn solver conflict memberships into evidence-first diagnostic findings."""
function analyze_solver_conflict(result::SolverConflictResult)
    report = DiagnosticReport()
    report.metadata[:stage] = "solver_conflict"
    report.metadata[:solver_conflict_optimizer_type] = result.optimizer_type
    report.metadata[:solver_conflict_optimized_copy] = string(result.optimize_before_conflict)
    report.metadata[:solver_conflict_termination] = result.termination_status
    report.metadata[:solver_conflict_status] = result.conflict_status
    report.metadata[:solver_conflict_source_variable_count] = string(result.source_variable_count)
    report.metadata[:solver_conflict_source_constraint_count] = string(result.source_constraint_count)
    report.metadata[:solver_conflict_count] = string(length(result.conflicts))
    if !isnothing(result.error)
        push!(report, Finding(:solver_conflict_unavailable;
            severity = SeverityInfo, domain = RepresentationalIssue,
            basis = NumericalObservation, confidence = ConfidenceHigh,
            observation = "The selected optimizer did not provide a readable MOI conflict result.",
            why_it_matters = "No conflict-based conclusion is made when the solver interface is unavailable or rejects the request.",
            evidence = [Evidence("MOI conflict interface"; details = ["optimizer_type" => result.optimizer_type, "source_variable_count" => result.source_variable_count, "source_constraint_count" => result.source_constraint_count, "error" => result.error])],
            suggested_actions = ["Use an optimizer with MOI conflict support or rely on the elastic subset analyses."],
        ))
        return report
    end
    if result.conflict_status == string(MOI.CONFLICT_FOUND)
        if isempty(result.conflicts)
            push!(report, Finding(:solver_conflict_membership_unavailable;
                severity = SeverityInfo, domain = RepresentationalIssue,
                basis = NumericalObservation, confidence = ConfidenceMedium,
                observation = "The solver reports a conflict, but no source constraint memberships were readable.",
                why_it_matters = "A conflict status without mapped memberships cannot localize the reported inconsistency.",
                evidence = [Evidence("MOI conflict status"; details = ["status" => result.conflict_status])],
                suggested_actions = ["Inspect solver-native conflict output and MOI bridge support."],
            ))
        end
        for (index, members) in enumerate(result.conflicts)
            push!(report, Finding(:solver_conflict_membership;
                severity = SeverityWarning, domain = MathematicalIssue,
                basis = NumericalObservation, confidence = ConfidenceHigh,
                observation = "The solver marked $(length(members)) source constraint(s) as participating in conflict $index.",
                why_it_matters = "This is solver-provided conflict evidence for the copied model, not an independently verified IIS or a physical-cause diagnosis.",
                evidence = [Evidence("MOI conflict membership"; details = ["conflict_index" => index, "optimizer_type" => result.optimizer_type, "termination_status" => result.termination_status, "source_variable_count" => result.source_variable_count, "source_constraint_count" => result.source_constraint_count])],
                affected = members,
                suggested_actions = ["Cross-check these rows with elastic supports and solver settings before modifying the source formulation."],
            ))
        end
        for (index, maybes) in enumerate(result.maybe_conflicts)
            isempty(maybes) && continue
            push!(report, Finding(:solver_conflict_maybe_membership;
                severity = SeverityInfo, domain = RepresentationalIssue,
                basis = NumericalObservation, confidence = ConfidenceMedium,
                observation = "The solver could not decide whether $(length(maybes)) source constraint(s) participate in conflict $index.",
                why_it_matters = "Possible memberships should not be treated as a stable conflict core.",
                evidence = [Evidence("MOI conflict maybe-membership"; details = ["conflict_index" => index])],
                affected = maybes,
                suggested_actions = ["Treat these rows as tentative and inspect solver-native conflict diagnostics."],
            ))
        end
    else
        push!(report, Finding(:solver_conflict_not_found;
            severity = SeverityInfo, domain = RepresentationalIssue,
            basis = NumericalObservation, confidence = ConfidenceHigh,
            observation = "The solver conflict interface returned status $(result.conflict_status).",
            why_it_matters = "This status is not a feasibility or infeasibility certificate for the source model.",
            evidence = [Evidence("MOI conflict status"; details = ["status" => result.conflict_status, "optimizer_type" => result.optimizer_type])],
            suggested_actions = ["Inspect the solver status and consider elastic subset searches if conflict extraction is unavailable."],
        ))
    end
    return report
end

function _solver_conflict_members(result::SolverConflictResult)
    members = EntityRef[]
    for conflict in result.conflicts
        append!(members, conflict)
    end
    return unique(members)
end

function _analyze_solver_conflict_crosscheck(
    result::SolverConflictResult,
    elastic_members::Vector{EntityRef},
    elastic_source::String,
)
    report = DiagnosticReport()
    report.metadata[:stage] = "solver_conflict_crosscheck"
    report.metadata[:solver_conflict_crosscheck_elastic_source] = elastic_source
    report.metadata[:solver_conflict_crosscheck_status] = result.conflict_status
    if !isnothing(result.error) || result.conflict_status != string(MOI.CONFLICT_FOUND)
        report.metadata[:solver_conflict_crosscheck_available] = "false"
        push!(report, Finding(:solver_conflict_crosscheck_unavailable;
            severity = SeverityInfo, domain = RepresentationalIssue,
            basis = NumericalObservation, confidence = ConfidenceHigh,
            observation = "Solver conflict memberships are unavailable for comparison with $elastic_source.",
            why_it_matters = "No agreement or disagreement is inferred without a readable solver conflict.",
            evidence = [Evidence("Conflict cross-check availability"; details = ["conflict_status" => result.conflict_status, "error" => isnothing(result.error) ? "none" : result.error])],
            suggested_actions = ["Inspect the solver conflict status or compare independent elastic analyses directly."],
        ))
        return report
    end
    conflict_members = _solver_conflict_members(result)
    overlap = [source for source in conflict_members if source in elastic_members]
    conflict_only = [source for source in conflict_members if !(source in elastic_members)]
    elastic_only = [source for source in elastic_members if !(source in conflict_members)]
    report.metadata[:solver_conflict_crosscheck_available] = "true"
    report.metadata[:solver_conflict_crosscheck_conflict_count] = string(length(conflict_members))
    report.metadata[:solver_conflict_crosscheck_elastic_count] = string(length(elastic_members))
    report.metadata[:solver_conflict_crosscheck_overlap_count] = string(length(overlap))
    if !isempty(overlap)
        push!(report, Finding(:solver_conflict_elastic_overlap;
            severity = SeverityInfo, domain = MathematicalIssue,
            basis = LocalInference, confidence = ConfidenceMedium,
            observation = "$(length(overlap)) row(s) appear in both the solver conflict and $elastic_source.",
            why_it_matters = "Agreement across independent diagnostic mechanisms can prioritize inspection, but it does not turn either result into a causal proof.",
            evidence = [Evidence("Conflict/elastic overlap"; details = ["overlap_count" => length(overlap), "solver_conflict_count" => length(conflict_members), "elastic_count" => length(elastic_members)])],
            affected = overlap,
            suggested_actions = ["Inspect the overlapping rows together with bounds, units, and domain guards."],
        ))
    end
    if !isempty(conflict_only) || !isempty(elastic_only)
        push!(report, Finding(:solver_conflict_elastic_disagreement;
            severity = SeverityInfo, domain = RepresentationalIssue,
            basis = NumericalObservation, confidence = ConfidenceHigh,
            observation = "Solver conflict and $elastic_source select different row sets.",
            why_it_matters = "The methods optimize and interpret different auxiliary problems, so disagreement is diagnostic context rather than an error in either method.",
            evidence = [Evidence("Conflict/elastic disagreement"; details = ["solver_only_count" => length(conflict_only), "elastic_only_count" => length(elastic_only), "overlap_count" => length(overlap)])],
            affected = unique(vcat(conflict_only, elastic_only)),
            suggested_actions = ["Compare scope, weights, domain guards, solver tolerances, and copied-model support before drawing conclusions."],
        ))
    end
    return report
end

function analyze_solver_conflict_crosscheck(
    result::SolverConflictResult,
    search::ElasticSubsetSearch,
)
    return _analyze_solver_conflict_crosscheck(
        result, search.retained_constraints, "a local elastic subset reduction",
    )
end

function analyze_solver_conflict_crosscheck(
    result::SolverConflictResult,
    ensemble::ElasticSubsetEnsemble,
)
    return _analyze_solver_conflict_crosscheck(
        result, ensemble.consensus_constraints, "elastic subset-order consensus",
    )
end

function analyze_solver_conflict_crosscheck(
    result::SolverConflictResult,
    search::ElasticMinimumRelaxationSearch,
)
    members = EntityRef[]
    for probe in search.solutions
        append!(members, probe.selected_constraints)
    end
    return _analyze_solver_conflict_crosscheck(
        result, unique(members), "minimum elastic relaxation supports",
    )
end

"""Compare plugin-declared component rank with an aligned local Jacobian scope."""
function analyze_component_ranks(
    model::MOI.ModelLike,
    evaluation::NumericalEvaluation{T};
    components::AbstractVector{<:ComponentMetadata} = component_metadata(model),
    relative_tolerance::Real = max(length(evaluation.point.variables), 1) * eps(T),
    max_dense_entries::Integer = 4_000_000,
) where {T<:AbstractFloat}
    report = DiagnosticReport()
    report.metadata[:stage] = "component_ranks"
    variable_columns = Dict(variable => column for (column, variable) in enumerate(evaluation.point.variables))
    row_keys = Dict(_entity_row_key(source) => row for (row, source) in enumerate(evaluation.constraint_sources))
    declared = 0
    compared = 0
    unavailable = 0
    expected_nullity_observed = 0
    unexpected_additional_nullity = 0
    unobserved_declared_nullity = 0
    for component in components
        isnothing(component.expected_rank) && continue
        (isempty(component.variables) || isempty(component.constraints)) && continue
        declared += 1
        columns = [get(variable_columns, variable, 0) for variable in component.variables]
        rows = [get(row_keys, _entity_row_key(constraint), 0) for constraint in component.constraints]
        if any(iszero, columns) || any(iszero, rows)
            unavailable += 1
            push!(report, Finding(:component_rank_comparison_unavailable;
                severity = SeverityInfo, domain = RepresentationalIssue,
                basis = NumericalObservation, confidence = ConfidenceHigh,
                observation = "Component $(component.component_type) '$(component.component_id)' cannot be aligned with all evaluated Jacobian coordinates.",
                why_it_matters = "The declared component scope and the current evaluation use different or incomplete coordinate sources.",
                evidence = [Evidence("Component rank alignment"; details = ["expected_rank" => component.expected_rank])],
                suggested_actions = ["Use scalar constraint-row references and an evaluation point containing the component variables."],
            ))
            continue
        end
        selected = _selected_jacobian_submatrix_evaluation(evaluation, rows, columns)
        estimate = jacobian_rank_estimate(selected;
            relative_tolerance = relative_tolerance,
            max_dense_entries = max_dense_entries,
            compute_vectors = false,
        )
        if !estimate.available
            unavailable += 1
            push!(report, Finding(:component_rank_comparison_unavailable;
                severity = SeverityInfo, domain = NumericalIssue,
                basis = NumericalObservation, confidence = ConfidenceHigh,
                observation = "Component $(component.component_type) '$(component.component_id)' rank estimate is unavailable.",
                why_it_matters = "No comparison is made when the scoped Jacobian is incomplete, non-finite, or exceeds the dense rank guard.",
                evidence = [Evidence("Component rank estimate"; details = ["reason" => estimate.reason, "expected_rank" => component.expected_rank])],
                suggested_actions = ["Resolve derivative availability or increase the explicit rank guard if appropriate."],
            ))
            continue
        end
        compared += 1
        expected_nullity = length(columns) - component.expected_rank
        observed_nullity = length(columns) - estimate.rank
        if estimate.rank == component.expected_rank
            # A plugin may deliberately declare a rank smaller than the number of
            # component coordinates.  Report the resulting local freedom as an
            # observation rather than treating it as an error: this confirms the
            # declared *dimension*, not the physical identity of a null mode.
            if expected_nullity > 0
                expected_nullity_observed += 1
                push!(report, Finding(:component_expected_right_nullity_observed;
                    severity = SeverityInfo, domain = RepresentationalIssue,
                    basis = NumericalObservation, confidence = ConfidenceHigh,
                    observation = "Component $(component.component_type) '$(component.component_id)' declares $(expected_nullity) local right-null direction(s), and the scoped Jacobian has the same local nullity at this point.",
                    why_it_matters = "This is consistent with the component's declared degree of freedom, but does not by itself identify the physical mode or establish a network-wide gauge.",
                    evidence = [Evidence("Scoped component Jacobian nullity"; details = ["expected_rank" => component.expected_rank, "observed_rank" => estimate.rank, "expected_right_nullity" => expected_nullity, "observed_right_nullity" => observed_nullity, "rows" => estimate.rows, "columns" => estimate.columns, "point" => evaluation.point.label])],
                    affected = vcat([EntityRef(:variable, variable.value) for variable in component.variables], component.constraints),
                    suggested_actions = ["Use domain metadata or a nullspace fingerprint to identify the mode before assigning physical meaning."],
                ))
            end
            continue
        end
        if observed_nullity > expected_nullity
            unexpected_additional_nullity += 1
            nullity_interpretation = "The scoped Jacobian has $(observed_nullity - expected_nullity) additional local right-null direction(s) beyond the declaration."
        else
            unobserved_declared_nullity += 1
            nullity_interpretation = "The scoped Jacobian is missing $(expected_nullity - observed_nullity) declared local right-null direction(s) at this point."
        end
        push!(report, Finding(:component_expected_rank_mismatch;
            severity = SeverityWarning, domain = RepresentationalIssue,
            basis = NumericalObservation, confidence = ConfidenceHigh,
            observation = "Component $(component.component_type) '$(component.component_id)' declares expected rank $(component.expected_rank), while its scoped local Jacobian rank is $(estimate.rank).",
            why_it_matters = "$(nullity_interpretation) The discrepancy may indicate a stale component declaration, an operating-point rank loss, or a domain-specific modeling issue; the generic core does not choose among them.",
            evidence = [Evidence("Scoped component Jacobian rank"; details = ["expected_rank" => component.expected_rank, "observed_rank" => estimate.rank, "expected_right_nullity" => expected_nullity, "observed_right_nullity" => observed_nullity, "right_nullity_difference" => observed_nullity - expected_nullity, "rows" => estimate.rows, "columns" => estimate.columns, "point" => evaluation.point.label])],
            affected = vcat([EntityRef(:variable, variable.value) for variable in component.variables], component.constraints),
            suggested_actions = ["Inspect the component's operating point, declared scope, and domain-plugin rank assumption."],
        ))
    end
    report.metadata[:component_rank_declared_count] = string(declared)
    report.metadata[:component_rank_comparison_count] = string(compared)
    report.metadata[:component_rank_unavailable_count] = string(unavailable)
    report.metadata[:component_rank_expected_nullity_observed_count] = string(expected_nullity_observed)
    report.metadata[:component_rank_unexpected_additional_nullity_count] = string(unexpected_additional_nullity)
    report.metadata[:component_rank_unobserved_declared_nullity_count] = string(unobserved_declared_nullity)
    return report
end

"""
    analyze_component_rank_persistence(model, evaluations; ...)

Compare optional component expected-rank declarations over explicitly supplied
local Jacobian evaluations. This reports repeated numerical rank evidence; it
does not identify the physical meaning of a component rank loss.
"""
function analyze_component_rank_persistence(
    model::MOI.ModelLike,
    evaluations::AbstractVector{<:NumericalEvaluation{T}};
    components::AbstractVector{<:ComponentMetadata} = component_metadata(model),
    minimum_evaluations::Integer = 2,
    relative_tolerance::Real = maximum((
        max(length(evaluation.point.variables), 1) for evaluation in evaluations
    ); init = 1) * eps(T),
    max_dense_entries::Integer = 4_000_000,
    subspace_alignment_threshold::Real = 0.98,
    expected_modes::AbstractVector{<:ExpectedNullspaceMode} = ExpectedNullspaceMode[],
    expected_mode_residual_tolerance::Real = sqrt(eps(T)),
) where {T<:AbstractFloat}
    minimum_evaluations >= 2 ||
        throw(ArgumentError("minimum_evaluations must be at least two"))
    tolerance = convert(T, relative_tolerance)
    tolerance >= zero(T) ||
        throw(ArgumentError("relative_tolerance must be nonnegative"))
    zero(T) <= subspace_alignment_threshold <= one(T) ||
        throw(ArgumentError("subspace_alignment_threshold must lie in [0, 1]"))
    expected_mode_residual_tolerance >= zero(T) ||
        throw(ArgumentError("expected_mode_residual_tolerance must be nonnegative"))
    report = DiagnosticReport()
    report.metadata[:stage] = "component_rank_persistence"
    report.metadata[:evaluation_count] = string(length(evaluations))
    report.metadata[:minimum_evaluations] = string(minimum_evaluations)
    report.metadata[:component_rank_persistence_declared_count] = "0"
    report.metadata[:component_rank_persistence_expected_mode_count] =
        string(length(expected_modes))
    isempty(evaluations) && return report
    declared = 0
    compared = 0
    unavailable = 0
    persistent = 0
    persistent_nullspace = 0
    changing_nullspace = 0
    changing = 0
    persistently_mismatched = 0
    for component in components
        isnothing(component.expected_rank) && continue
        (isempty(component.variables) || isempty(component.constraints)) && continue
        declared += 1
        ranks = Int[]
        estimates = JacobianRankEstimate{T}[]
        labels = String[]
        alignment_failure = nothing
        for evaluation in evaluations
            variable_columns = Dict(
                variable => column for
                (column, variable) in enumerate(evaluation.point.variables)
            )
            row_keys = Dict(
                _entity_row_key(source) => row for
                (row, source) in enumerate(evaluation.constraint_sources)
            )
            columns = [get(variable_columns, variable, 0) for variable in component.variables]
            rows = [get(row_keys, _entity_row_key(constraint), 0) for constraint in component.constraints]
            if any(iszero, columns) || any(iszero, rows)
                alignment_failure = "component scope is not fully aligned"
                break
            end
            estimate = jacobian_rank_estimate(
                _selected_jacobian_submatrix_evaluation(evaluation, rows, columns);
                relative_tolerance = tolerance,
                max_dense_entries = max_dense_entries,
                compute_vectors = true,
            )
            if !estimate.available
                alignment_failure = something(estimate.reason, "component rank estimate is unavailable")
                break
            end
            push!(ranks, estimate.rank)
            push!(estimates, estimate)
            push!(labels, evaluation.point.label)
        end
        if !isnothing(alignment_failure)
            unavailable += 1
            push!(report, Finding(:component_rank_persistence_unavailable;
                severity = SeverityInfo, domain = NumericalIssue,
                basis = NumericalObservation, confidence = ConfidenceHigh,
                observation = "Component $(component.component_type) '$(component.component_id)' cannot be compared across the supplied Jacobian evaluations.",
                why_it_matters = "A cross-point component-rank conclusion requires a complete aligned scope and available local derivatives at every compared point.",
                evidence = [Evidence("Component rank persistence availability"; details = [
                    "expected_rank" => component.expected_rank,
                    "reason" => alignment_failure,
                ])],
                affected = vcat([EntityRef(:variable, variable.value) for variable in component.variables], component.constraints),
                suggested_actions = ["Use the same component coordinates and scalar constraint rows at every point, and resolve derivative availability."],
            ))
            continue
        end
        if length(ranks) < minimum_evaluations
            unavailable += 1
            push!(report, Finding(:component_rank_persistence_unavailable;
                severity = SeverityInfo, domain = NumericalIssue,
                basis = NumericalObservation, confidence = ConfidenceHigh,
                observation = "Component $(component.component_type) '$(component.component_id)' has only $(length(ranks)) rank estimate(s) for persistence analysis.",
                why_it_matters = "Component rank persistence requires at least $(minimum_evaluations) explicitly supplied evaluations.",
                evidence = [Evidence("Component rank persistence availability"; details = [
                    "available_evaluation_count" => length(ranks),
                    "minimum_evaluations" => minimum_evaluations,
                ])],
            ))
            continue
        end
        compared += 1
        affected = vcat([EntityRef(:variable, variable.value) for variable in component.variables], component.constraints)
        details = [
            "expected_rank" => component.expected_rank,
            "point_labels" => join(labels, ","),
            "observed_ranks" => join(ranks, ","),
            "relative_tolerance" => tolerance,
        ]
        if !all(==(first(ranks)), ranks)
            changing += 1
            push!(report, Finding(:component_local_rank_not_persistent;
                severity = SeverityWarning, domain = NumericalIssue,
                basis = LocalInference, confidence = ConfidenceHigh,
                observation = "Component $(component.component_type) '$(component.component_id)' has changing scoped Jacobian rank across supplied points.",
                why_it_matters = "The component rank behavior is operating-point-dependent or threshold-sensitive, so a one-point discrepancy should not be treated as persistent.",
                evidence = [Evidence("Component rank persistence"; details = details)],
                affected = affected,
                suggested_actions = ["Compare derivative scales, active geometry, and component parameters at the supplied points."],
            ))
        elseif first(ranks) == component.expected_rank
            persistent += 1
            push!(report, Finding(:component_expected_rank_persistent;
                severity = SeverityInfo, domain = RepresentationalIssue,
                basis = NumericalObservation, confidence = ConfidenceHigh,
                observation = "Component $(component.component_type) '$(component.component_id)' matches declared rank $(component.expected_rank) at every supplied point.",
                why_it_matters = "This is repeated local agreement with the declaration, not a proof of the component's physical semantics or global rank behavior.",
                evidence = [Evidence("Component rank persistence"; details = details)],
                affected = affected,
                suggested_actions = ["Retain the declaration and compare any declared modes with cross-point nullspace evidence."],
            ))
            expected_nullity = length(component.variables) - component.expected_rank
            if expected_nullity > 0
                minimum_cosine = one(T)
                for left in eachindex(estimates), right in (left + 1):length(estimates)
                    cosines = svdvals(
                        transpose(estimates[left].right_nullspace) *
                        estimates[right].right_nullspace,
                    )
                    minimum_cosine = min(
                        minimum_cosine,
                        isempty(cosines) ? zero(T) : minimum(cosines),
                    )
                end
                nullspace_is_persistent =
                    minimum_cosine >= convert(T, subspace_alignment_threshold)
                if nullspace_is_persistent
                    persistent_nullspace += 1
                else
                    changing_nullspace += 1
                end
                push!(report, Finding(
                    nullspace_is_persistent ?
                    :component_expected_right_nullspace_persistent :
                    :component_expected_right_nullspace_not_persistent;
                    severity = nullspace_is_persistent ? SeverityInfo : SeverityWarning,
                    domain = NumericalIssue,
                    basis = LocalInference,
                    confidence = ConfidenceHigh,
                    observation = nullspace_is_persistent ?
                                  "Component $(component.component_type) '$(component.component_id)' has an aligned $(expected_nullity)-dimensional local right-nullspace across supplied points." :
                                  "Component $(component.component_type) '$(component.component_id)' has matching rank but a changing local right-nullspace across supplied points.",
                    why_it_matters = nullspace_is_persistent ?
                                     "Repeated local freedom geometry is more consistent with a persistent component-level invariance or formulation freedom, but does not identify a physical mode." :
                                     "A stable rank can hide changing local freedoms, so the component's one-point nullspace should not be treated as persistent without this comparison.",
                    evidence = [Evidence("Component right-nullspace persistence"; details = vcat(details, [
                        "expected_right_nullity" => expected_nullity,
                        "minimum_principal_cosine" => minimum_cosine,
                        "alignment_threshold" => subspace_alignment_threshold,
                    ]))],
                    affected = affected,
                    suggested_actions = nullspace_is_persistent ?
                                        ["Compare the persistent local subspace with plugin-declared modes before assigning physical meaning."] :
                                        ["Inspect component derivatives, parameters, and coordinate choices at each supplied point."],
                ))
                if nullspace_is_persistent
                    component_positions = Dict(
                        variable => position for
                        (position, variable) in enumerate(component.variables)
                    )
                    mode_tolerance = convert(T, expected_mode_residual_tolerance)
                    for mode in expected_modes
                        all(variable -> haskey(component_positions, variable), mode.variables) ||
                            continue
                        direction = zeros(T, length(component.variables))
                        for (variable, coefficient) in zip(mode.variables, mode.direction)
                            direction[component_positions[variable]] += convert(T, coefficient)
                        end
                        iszero(norm(direction)) && continue
                        normalized = direction / norm(direction)
                        residuals = T[
                            norm(normalized - estimate.right_nullspace *
                                 (transpose(estimate.right_nullspace) * normalized))
                            for estimate in estimates
                        ]
                        observed = all(residual -> residual <= mode_tolerance, residuals)
                        push!(report, Finding(
                            observed ? :component_persistent_expected_mode_observed :
                                       :component_persistent_expected_mode_not_observed;
                            severity = SeverityInfo,
                            domain = RepresentationalIssue,
                            basis = observed ? PhysicalExpectation : LocalInference,
                            confidence = ConfidenceHigh,
                            observation = observed ?
                                          "Declared mode :$(mode.name) aligns with the persistent local right-nullspace of component $(component.component_type) '$(component.component_id)'." :
                                          "Declared mode :$(mode.name) does not align with the persistent local right-nullspace of component $(component.component_type) '$(component.component_id)'.",
                            why_it_matters = observed ?
                                             "This supports the plugin's component-local interpretation across supplied points, but does not establish physical semantics or network-wide observability." :
                                             "The declaration may not describe this component-local freedom, even though the local nullspace itself persists.",
                            evidence = [Evidence("Persistent component expected-mode comparison"; details = [
                                "component_type" => component.component_type,
                                "component_id" => component.component_id,
                                "mode" => mode.name,
                                "point_labels" => join(labels, ","),
                                "projection_residuals" => join(residuals, ","),
                                "tolerance" => mode_tolerance,
                                "description" => mode.description,
                            ])],
                            affected = affected,
                            suggested_actions = observed ?
                                                ["Retain the declaration and confirm its physical meaning in the domain plugin."] :
                                                ["Inspect component coordinates and the expected-mode declaration before assigning physical meaning."],
                        ))
                    end
                end
            end
        else
            persistently_mismatched += 1
            push!(report, Finding(:component_expected_rank_persistently_mismatched;
                severity = SeverityWarning, domain = RepresentationalIssue,
                basis = NumericalObservation, confidence = ConfidenceHigh,
                observation = "Component $(component.component_type) '$(component.component_id)' has scoped rank $(first(ranks)) at every supplied point, differing from declared rank $(component.expected_rank).",
                why_it_matters = "Repeated disagreement is stronger evidence that the declaration or component formulation needs inspection than a one-point mismatch, but it remains a numerical comparison rather than a physical diagnosis.",
                evidence = [Evidence("Component rank persistence"; details = details)],
                affected = affected,
                suggested_actions = ["Inspect the declared component scope and expected rank, then compare expected modes and formulation assumptions."],
            ))
        end
    end
    report.metadata[:component_rank_persistence_declared_count] = string(declared)
    report.metadata[:component_rank_persistence_compared_count] = string(compared)
    report.metadata[:component_rank_persistence_unavailable_count] = string(unavailable)
    report.metadata[:component_rank_persistent_count] = string(persistent)
    report.metadata[:component_right_nullspace_persistent_count] =
        string(persistent_nullspace)
    report.metadata[:component_right_nullspace_changing_count] =
        string(changing_nullspace)
    report.metadata[:component_rank_changing_count] = string(changing)
    report.metadata[:component_rank_persistently_mismatched_count] = string(persistently_mismatched)
    sort!(report.findings; by = finding -> (-Int(finding.severity), string(finding.code)))
    return report
end

"""
    analyze_component_rank_persistence(model, points; cache = EvaluationCache(), kwargs...)

Evaluate one model at caller-supplied points before running component-rank and
component-nullspace persistence analysis. Points are never generated or
modified by this convenience method.
"""
function analyze_component_rank_persistence(
    model::MOI.ModelLike,
    points::AbstractVector{<:EvaluationPoint};
    cache::EvaluationCache = EvaluationCache(),
    kwargs...,
)
    evaluations = [evaluate_numerical(model, point; cache = cache) for point in points]
    return analyze_component_rank_persistence(model, evaluations; kwargs...)
end

"""
    analyze(model::MOI.ModelLike)

Run all implemented solver-independent analysis stages. Numerical analysis is
included only when an explicit `point` or supplied `evaluation` is provided.
An explicitly supplied solver-neutral `postmortem` is appended as a separate
evidence stage; no solver state is queried or inferred. An explicitly supplied
`solver_log` is likewise analyzed as raw and structured trace evidence.
Caller-captured `iteration_bindings` can append point-local evidence without
reconstructing solver iterates.
The iterative sparse probe dimensions are opt-in and require an explicit point
or supplied evaluation; they add finite-budget screening stages rather than
changing rank, degeneracy, or physical classifications.
"""
function analyze(
    model::MOI.ModelLike;
    point::Union{Nothing,EvaluationPoint} = nothing,
    evaluation::Union{Nothing,NumericalEvaluation} = nothing,
    cache::EvaluationCache = EvaluationCache(),
    scale_ratio_threshold::Real = 1.0e6,
    component_scale_mismatch_factor::Real = 1.0e3,
    unit_circle_radius_tolerance::Real = 1.0e-6,
    numeric_type::Union{Nothing,Type{<:AbstractFloat}} = nothing,
    strict_domain_proximity_threshold::Union{Nothing,Real} = nothing,
    check_initialization::Bool = false,
    check_active_set::Bool = false,
    check_coupled_set_qualification::Bool = false,
    check_degeneracy::Bool = false,
    jacobian_rank_tolerance_sweep_tolerances::Union{Nothing,AbstractVector{<:Real}} = nothing,
    jacobian_rank_tolerance_sweep_scaling::Symbol = :none,
    jacobian_rank_tolerance_sweep_max_dense_entries::Integer = 4_000_000,
    iterative_right_nullspace_probe_dimension::Union{Nothing,Integer} = nothing,
    iterative_right_nullspace_probe_iterations::Integer = 100,
    iterative_right_nullspace_probe_convergence_tolerance::Real = sqrt(eps(Float64)),
    iterative_right_nullspace_probe_residual_relative_tolerance::Real = sqrt(eps(Float64)),
    iterative_right_nullspace_probe_support_relative::Real = 0.1,
    iterative_left_nullspace_probe_dimension::Union{Nothing,Integer} = nothing,
    iterative_left_nullspace_probe_iterations::Integer = 100,
    iterative_left_nullspace_probe_convergence_tolerance::Real = sqrt(eps(Float64)),
    iterative_left_nullspace_probe_residual_relative_tolerance::Real = sqrt(eps(Float64)),
    iterative_left_nullspace_probe_support_relative::Real = 0.1,
    iterative_spectrum_probe_dimension::Union{Nothing,Integer} = nothing,
    iterative_spectrum_probe_iterations::Integer = 100,
    iterative_spectrum_probe_convergence_tolerance::Real = sqrt(eps(Float64)),
    iterative_spectrum_probe_spread_threshold::Real = 1.0e6,
    check_iterative_right_nullspace_persistence::Bool = false,
    check_iterative_left_nullspace_persistence::Bool = false,
    check_iteration_jacobian_condition_persistence::Bool = false,
    iterative_probe_persistence_minimum_evaluations::Integer = 2,
    iterative_probe_persistence_alignment_threshold::Real = 0.98,
    iteration_rank_persistence_left_nullspace_support_relative::Real = 0.1,
    iteration_rank_persistence_right_nullspace_support_relative::Real = 0.1,
    iteration_rank_persistence_scaling_change_factor_threshold::Real = 100,
    iteration_rank_persistence_expected_mode_residual_tolerance::Real = sqrt(eps(Float64)),
    iteration_rank_persistence_expected_mode_span_alignment_threshold::Real = 0.98,
    iteration_rank_persistence_expected_mode_span_rank_relative_tolerance::Real = sqrt(eps(Float64)),
    iteration_condition_persistence_minimum_evaluations::Integer = 2,
    iteration_condition_persistence_relative_tolerance::Union{Nothing,Real} = nothing,
    iteration_condition_persistence_scaling::Symbol = :none,
    iteration_condition_persistence_max_dense_entries::Integer = 4_000_000,
    iteration_condition_persistence_change_factor_threshold::Real = 100,
    expected_modes::Union{Nothing,AbstractVector{<:ExpectedNullspaceMode}} = nothing,
    degeneracy_nullspace_support_relative::Real = 0.1,
    degeneracy_nullspace_uniform_shift_correlation::Real = 0.98,
    degeneracy_nullspace_max_compact_support::Integer = 8,
    coupled_qualification_strict_tolerance::Union{Nothing,Real} = nothing,
    coupled_qualification_max_iterations::Integer = 1_000,
    postmortem::Union{Nothing,SolverPostmortem} = nothing,
    solver_log::Union{Nothing,AbstractString} = nothing,
    solver_name::Union{Nothing,AbstractString} = nothing,
    solver_log_residual_tolerance::Real = 1.0e-6,
    solver_log_objective_agreement_factor::Real = 100,
    iteration_bindings::Union{Nothing,AbstractVector{<:IterationPointBinding}} = nothing,
    iteration_point_relative_step::Union{Nothing,Real} = nothing,
)
    !isnothing(point) && !isnothing(evaluation) && throw(ArgumentError(
        "provide either point or evaluation, not both",
    ))
    (!isnothing(iterative_right_nullspace_probe_dimension) ||
     !isnothing(iterative_left_nullspace_probe_dimension) ||
     !isnothing(iterative_spectrum_probe_dimension)) &&
        isnothing(point) && isnothing(evaluation) && !check_initialization &&
        isnothing(iteration_bindings) && throw(ArgumentError(
            "iterative sparse probes require an explicit point, supplied evaluation, check_initialization = true, or iteration_bindings",
        ))
    !isnothing(jacobian_rank_tolerance_sweep_tolerances) &&
        isnothing(point) && isnothing(evaluation) && !check_initialization && throw(ArgumentError(
            "jacobian rank tolerance sweep requires an explicit point or supplied evaluation",
        ))
    !isnothing(solver_log) && isnothing(solver_name) && isnothing(postmortem) &&
        throw(ArgumentError(
            "solver_log requires solver_name or a supplied postmortem",
        ))
    !isnothing(solver_name) && !isnothing(postmortem) &&
        String(solver_name) != postmortem.solver && throw(ArgumentError(
            "solver_name and postmortem solver must agree when both are supplied",
        ))
    solver_log_objective_agreement_factor > 1 || throw(ArgumentError(
        "solver_log_objective_agreement_factor must be greater than one",
    ))
    declared_components = component_metadata(model)
    declared_component_coordinate_semantics = component_coordinate_semantics(model)
    declared_component_constraint_scales = component_constraint_scale_semantics(model)
    declared_ports = component_port_metadata(model)
    declared_port_modes = component_port_nullspace_modes(model)
    declared_port_mode_semantics = component_port_nullspace_mode_semantics(model)
    declared_port_connections = component_port_connections(model)
    declared_port_coordinate_maps = component_port_coordinate_maps(model)
    declared_port_coordinate_semantics = component_port_coordinate_semantics(model)
    selected_numeric_type = if !isnothing(numeric_type)
        numeric_type
    elseif !isnothing(point)
        eltype(point.values)
    elseif !isnothing(evaluation)
        eltype(evaluation.point.values)
    else
        Float64
    end
    model_snapshot = snapshot(model)
    graph = incidence_graph(model_snapshot)
    report = analyze_static(
        model_snapshot;
        graph = graph,
        unit_circle_radius_tolerance = unit_circle_radius_tolerance,
    )
    constraint_scale_scope_report = _component_constraint_scale_semantics_findings(
        declared_component_constraint_scales,
        [_constraint_ref(record) for record in model_snapshot.constraints],
    )
    append!(report.findings, constraint_scale_scope_report.findings)
    merge!(report.metadata, constraint_scale_scope_report.metadata)
    report.metadata[:component_metadata_count] = string(length(declared_components))
    report.metadata[:component_coordinate_semantics_count] = string(length(declared_component_coordinate_semantics))
    report.metadata[:component_constraint_scale_semantics_count] = string(length(declared_component_constraint_scales))
    report.metadata[:component_constraint_scale_source_count] = string(sum(
        (length(item.constraints) for item in declared_component_constraint_scales); init = 0,
    ))
    report.metadata[:component_port_metadata_count] = string(length(declared_ports))
    report.metadata[:coupled_qualification_max_iterations] =
        string(coupled_qualification_max_iterations)
    report.metadata[:component_port_nullspace_mode_count] = string(length(declared_port_modes))
    report.metadata[:component_port_nullspace_mode_semantics_count] =
        string(length(declared_port_mode_semantics))
    report.metadata[:component_port_connection_count] = string(length(declared_port_connections))
    report.metadata[:component_port_coordinate_map_count] = string(length(declared_port_coordinate_maps))
    report.metadata[:component_port_coordinate_semantics_count] = string(length(declared_port_coordinate_semantics))
    component_report = _component_metadata_findings(
        declared_components;
        model_variables = [record.index for record in model_snapshot.variables],
        model_constraints = [_constraint_ref(record) for record in model_snapshot.constraints],
    )
    append!(report.findings, component_report.findings)
    component_semantics_report = _component_coordinate_semantics_findings(
        declared_component_coordinate_semantics,
        [record.index for record in model_snapshot.variables],
        components = declared_components,
    )
    append!(report.findings, component_semantics_report.findings)
    port_report = _component_port_metadata_findings(
        declared_ports;
        model_variables = [record.index for record in model_snapshot.variables],
    )
    append!(report.findings, port_report.findings)
    port_mode_report = _component_port_nullspace_mode_findings(
        declared_ports, declared_port_modes,
    )
    append!(report.findings, port_mode_report.findings)
    port_mode_semantic_report = _component_port_nullspace_mode_semantic_findings(
        declared_port_modes, declared_port_mode_semantics,
    )
    append!(report.findings, port_mode_semantic_report.findings)
    merge!(report.metadata, port_mode_semantic_report.metadata)
    port_connection_report = _component_port_connection_findings(
        declared_ports, declared_port_connections,
    )
    append!(report.findings, port_connection_report.findings)
    port_coordinate_map_report = _component_port_coordinate_map_findings(
        declared_ports, declared_port_coordinate_maps;
        model_variables = [record.index for record in model_snapshot.variables],
    )
    append!(report.findings, port_coordinate_map_report.findings)
    port_mode_coordinate_report = _component_port_mode_coordinate_projection_findings(
        declared_ports, declared_port_modes, declared_port_coordinate_maps,
    )
    append!(report.findings, port_mode_coordinate_report.findings)
    port_semantics_report = _component_port_coordinate_semantics_findings(
        declared_ports, declared_port_coordinate_semantics, declared_port_coordinate_maps,
    )
    append!(report.findings, port_semantics_report.findings)
    cross_layer_semantics_report = _component_port_coordinate_semantics_cross_layer_findings(
        declared_component_coordinate_semantics,
        declared_port_coordinate_semantics,
        declared_port_coordinate_maps,
    )
    append!(report.findings, cross_layer_semantics_report.findings)
    port_expected_modes = port_expected_nullspace_modes(
        declared_ports, declared_port_modes, declared_port_connections,
        declared_port_coordinate_maps,
    )
    port_overlap_report = _port_expected_mode_overlap_findings(port_expected_modes)
    append!(report.findings, port_overlap_report.findings)
    port_span_report = _port_expected_mode_span_findings(port_expected_modes)
    append!(report.findings, port_span_report.findings)
    merge!(report.metadata, port_span_report.metadata)
    report.metadata[:port_expected_nullspace_candidate_count] =
        string(length(port_expected_modes))
    port_projection_report = _component_port_topology_coordinate_projection_findings(
        declared_ports, declared_port_connections, declared_port_coordinate_maps,
    )
    append!(report.findings, port_projection_report.findings)
    merge!(report.metadata, port_projection_report.metadata)
    port_topology_report = _component_port_topology_findings(
        declared_ports, declared_port_connections,
    )
    append!(report.findings, port_topology_report.findings)
    port_nullspace_report = _component_port_topology_nullspace_findings(
        declared_ports, declared_port_connections,
    )
    append!(report.findings, port_nullspace_report.findings)
    merge!(report.metadata, port_nullspace_report.metadata)
    domain_report = analyze_domains(model_snapshot)
    derivative_report = analyze_derivatives(model_snapshot)
    expression_report = analyze_expressions(
        model_snapshot;
        numeric_type = selected_numeric_type,
        strict_domain_proximity_threshold = strict_domain_proximity_threshold,
    )
    structural_report = analyze_structure(
        model_snapshot;
        graph = graph,
    )
    append!(report.findings, domain_report.findings)
    append!(report.findings, derivative_report.findings)
    append!(report.findings, expression_report.findings)
    append!(report.findings, structural_report.findings)
    merge!(report.metadata, domain_report.metadata)
    merge!(report.metadata, derivative_report.metadata)
    merge!(report.metadata, expression_report.metadata)
    merge!(report.metadata, structural_report.metadata)
    stages = "static,domains,derivatives,expressions,structural"
    numerical_evaluation = if !isnothing(evaluation)
        evaluation
    elseif !isnothing(point)
        evaluate_numerical(model, point; cache = cache)
    else
        nothing
    end
    if !isnothing(numerical_evaluation)
        numerical_report = analyze_numerical(
            model,
            numerical_evaluation;
            scale_ratio_threshold = scale_ratio_threshold,
            component_scale_mismatch_factor = component_scale_mismatch_factor,
            numeric_type = selected_numeric_type,
            strict_domain_proximity_threshold = strict_domain_proximity_threshold,
        )
        append!(report.findings, numerical_report.findings)
        merge!(report.metadata, numerical_report.metadata)
        component_rank_report = analyze_component_ranks(
            model,
            numerical_evaluation;
            components = declared_components,
        )
        append!(report.findings, component_rank_report.findings)
        merge!(report.metadata, component_rank_report.metadata)
        stages *= ",numerical"
        if !isnothing(iterative_right_nullspace_probe_dimension)
            probe_report = analyze_iterative_right_nullspace_probe(
                numerical_evaluation;
                probe_dimension = iterative_right_nullspace_probe_dimension,
                iterations = iterative_right_nullspace_probe_iterations,
                convergence_tolerance = iterative_right_nullspace_probe_convergence_tolerance,
                residual_relative_tolerance = iterative_right_nullspace_probe_residual_relative_tolerance,
                support_relative = iterative_right_nullspace_probe_support_relative,
            )
            append!(report.findings, probe_report.findings)
            merge!(report.metadata, probe_report.metadata)
            stages *= ",iterative_right_nullspace_probe"
        end
        if !isnothing(iterative_left_nullspace_probe_dimension)
            probe_report = analyze_iterative_left_nullspace_probe(
                numerical_evaluation;
                probe_dimension = iterative_left_nullspace_probe_dimension,
                iterations = iterative_left_nullspace_probe_iterations,
                convergence_tolerance = iterative_left_nullspace_probe_convergence_tolerance,
                residual_relative_tolerance = iterative_left_nullspace_probe_residual_relative_tolerance,
                support_relative = iterative_left_nullspace_probe_support_relative,
            )
            append!(report.findings, probe_report.findings)
            merge!(report.metadata, probe_report.metadata)
            stages *= ",iterative_left_nullspace_probe"
        end
        if !isnothing(iterative_spectrum_probe_dimension)
            probe_report = analyze_iterative_jacobian_spectrum_probe(
                numerical_evaluation;
                probe_dimension = iterative_spectrum_probe_dimension,
                iterations = iterative_spectrum_probe_iterations,
                convergence_tolerance = iterative_spectrum_probe_convergence_tolerance,
                spectral_spread_threshold = iterative_spectrum_probe_spread_threshold,
            )
            append!(report.findings, probe_report.findings)
            merge!(report.metadata, probe_report.metadata)
            stages *= ",iterative_jacobian_spectrum_probe"
        end
        if !isnothing(jacobian_rank_tolerance_sweep_tolerances)
            sweep_report = analyze_jacobian_rank_tolerance_sweep(
                numerical_evaluation;
                relative_tolerances = jacobian_rank_tolerance_sweep_tolerances,
                scaling = jacobian_rank_tolerance_sweep_scaling,
                max_dense_entries = jacobian_rank_tolerance_sweep_max_dense_entries,
            )
            append!(report.findings, sweep_report.findings)
            merge!(report.metadata, sweep_report.metadata)
            stages *= ",jacobian_rank_tolerance_sweep"
        end
        if check_active_set
            coupled_strict = isnothing(coupled_qualification_strict_tolerance) ?
                             sqrt(eps(eltype(numerical_evaluation.point.values))) :
                             coupled_qualification_strict_tolerance
            active_report = analyze_active_set(
                model, numerical_evaluation;
                component_scale_mismatch_factor = component_scale_mismatch_factor,
                coupled_qualification_strict_tolerance = coupled_strict,
                coupled_qualification_max_iterations = coupled_qualification_max_iterations,
                expected_modes = isnothing(expected_modes) ?
                                 expected_nullspace_modes(model, numerical_evaluation) :
                                 expected_modes,
            )
            append!(report.findings, active_report.findings)
            merge!(report.metadata, active_report.metadata)
            stages *= ",active_set"
        elseif check_coupled_set_qualification
            coupled_strict = isnothing(coupled_qualification_strict_tolerance) ?
                             sqrt(eps(eltype(numerical_evaluation.point.values))) :
                             coupled_qualification_strict_tolerance
            coupled_report = analyze_coupled_set_qualification(
                model, numerical_evaluation;
                strict_tolerance = coupled_strict,
                max_iterations = coupled_qualification_max_iterations,
                component_scale_mismatch_factor = component_scale_mismatch_factor,
            )
            append!(report.findings, coupled_report.findings)
            merge!(report.metadata, coupled_report.metadata)
            stages *= ",coupled_set_qualification"
        end
        if check_degeneracy
            degeneracy_keywords = (
                nullspace_support_relative = degeneracy_nullspace_support_relative,
                nullspace_uniform_shift_correlation = degeneracy_nullspace_uniform_shift_correlation,
                nullspace_max_compact_support = degeneracy_nullspace_max_compact_support,
            )
            # `analyze_degeneracy` projects declared port modes itself. Keep
            # caller-declared modes separate here so a port candidate is
            # compared exactly once and retains its own provenance/count.
            degeneracy_report = isnothing(expected_modes) ?
                                analyze_degeneracy(model, numerical_evaluation; degeneracy_keywords...) :
                                analyze_degeneracy(model, numerical_evaluation;
                                                   degeneracy_keywords...,
                                                   expected_modes = expected_modes)
            append!(report.findings, degeneracy_report.findings)
            merge!(report.metadata, degeneracy_report.metadata)
            stages *= ",degeneracy"
        end
    end
    if check_initialization
        initialization_report = analyze_initialization(
            model;
            cache = cache,
            numeric_type = numeric_type,
            strict_domain_proximity_threshold = strict_domain_proximity_threshold,
            expected_modes = expected_modes,
            scale_ratio_threshold = scale_ratio_threshold,
            component_scale_mismatch_factor = component_scale_mismatch_factor,
            iterative_right_nullspace_probe_dimension =
                iterative_right_nullspace_probe_dimension,
            iterative_right_nullspace_probe_iterations =
                iterative_right_nullspace_probe_iterations,
            iterative_right_nullspace_probe_convergence_tolerance =
                iterative_right_nullspace_probe_convergence_tolerance,
            iterative_right_nullspace_probe_residual_relative_tolerance =
                iterative_right_nullspace_probe_residual_relative_tolerance,
            iterative_right_nullspace_probe_support_relative =
                iterative_right_nullspace_probe_support_relative,
            iterative_left_nullspace_probe_dimension =
                iterative_left_nullspace_probe_dimension,
            iterative_left_nullspace_probe_iterations =
                iterative_left_nullspace_probe_iterations,
            iterative_left_nullspace_probe_convergence_tolerance =
                iterative_left_nullspace_probe_convergence_tolerance,
            iterative_left_nullspace_probe_residual_relative_tolerance =
                iterative_left_nullspace_probe_residual_relative_tolerance,
            iterative_left_nullspace_probe_support_relative =
                iterative_left_nullspace_probe_support_relative,
            iterative_spectrum_probe_dimension = iterative_spectrum_probe_dimension,
            iterative_spectrum_probe_iterations = iterative_spectrum_probe_iterations,
            iterative_spectrum_probe_convergence_tolerance =
                iterative_spectrum_probe_convergence_tolerance,
            iterative_spectrum_probe_spread_threshold =
                iterative_spectrum_probe_spread_threshold,
            jacobian_rank_tolerance_sweep_tolerances =
                jacobian_rank_tolerance_sweep_tolerances,
            jacobian_rank_tolerance_sweep_scaling =
                jacobian_rank_tolerance_sweep_scaling,
            jacobian_rank_tolerance_sweep_max_dense_entries =
                jacobian_rank_tolerance_sweep_max_dense_entries,
            coupled_qualification_strict_tolerance =
                coupled_qualification_strict_tolerance,
            coupled_qualification_max_iterations = coupled_qualification_max_iterations,
        )
        append!(report.findings, initialization_report.findings)
        merge!(report.metadata, initialization_report.metadata)
        stages *= ",initialization"
    end
    if !isnothing(postmortem)
        postmortem_report = analyze_postmortem(postmortem)
        append!(report.findings, postmortem_report.findings)
        for (key, value) in postmortem_report.metadata
            report.metadata[Symbol("postmortem_", key)] = value
        end
        stages *= ",postmortem"
    end
    if !isnothing(solver_log)
        resolved_solver_name = isnothing(solver_name) ? postmortem.solver :
                               String(solver_name)
        log_report = analyze_solver_log(resolved_solver_name, solver_log)
        iteration_report = analyze_solver_iterations(
            resolved_solver_name,
            solver_log;
            residual_tolerance = solver_log_residual_tolerance,
        )
        append!(report.findings, log_report.findings)
        append!(report.findings, iteration_report.findings)
        if !isnothing(postmortem)
            consistency_report = analyze_postmortem_log_consistency(
                postmortem,
                solver_log;
                objective_agreement_factor = solver_log_objective_agreement_factor,
            )
            append!(report.findings, consistency_report.findings)
            for (key, value) in consistency_report.metadata
                report.metadata[Symbol("postmortem_log_consistency_", key)] = value
            end
            stages *= ",postmortem_log_consistency"
        end
        for (key, value) in log_report.metadata
            report.metadata[Symbol("solver_log_", key)] = value
        end
        for (key, value) in iteration_report.metadata
            report.metadata[Symbol("solver_iterations_", key)] = value
        end
        stages *= ",solver_log,solver_iterations"
    end
    if !isnothing(iteration_bindings)
        iteration_point_report = analyze_iteration_points(
            model,
            iteration_bindings;
            cache = cache,
            relative_step = iteration_point_relative_step,
            expected_modes = expected_modes,
            iterative_right_nullspace_probe_dimension =
                iterative_right_nullspace_probe_dimension,
            iterative_right_nullspace_probe_iterations =
                iterative_right_nullspace_probe_iterations,
            iterative_right_nullspace_probe_convergence_tolerance =
                iterative_right_nullspace_probe_convergence_tolerance,
            iterative_right_nullspace_probe_residual_relative_tolerance =
                iterative_right_nullspace_probe_residual_relative_tolerance,
            iterative_right_nullspace_probe_support_relative =
                iterative_right_nullspace_probe_support_relative,
            iterative_left_nullspace_probe_dimension =
                iterative_left_nullspace_probe_dimension,
            iterative_left_nullspace_probe_iterations =
                iterative_left_nullspace_probe_iterations,
            iterative_left_nullspace_probe_convergence_tolerance =
                iterative_left_nullspace_probe_convergence_tolerance,
            iterative_left_nullspace_probe_residual_relative_tolerance =
                iterative_left_nullspace_probe_residual_relative_tolerance,
            iterative_left_nullspace_probe_support_relative =
                iterative_left_nullspace_probe_support_relative,
            iterative_spectrum_probe_dimension = iterative_spectrum_probe_dimension,
            iterative_spectrum_probe_iterations = iterative_spectrum_probe_iterations,
            iterative_spectrum_probe_convergence_tolerance =
                iterative_spectrum_probe_convergence_tolerance,
            iterative_spectrum_probe_spread_threshold =
                iterative_spectrum_probe_spread_threshold,
            check_iterative_right_nullspace_persistence =
                check_iterative_right_nullspace_persistence,
            check_iterative_left_nullspace_persistence =
                check_iterative_left_nullspace_persistence,
            check_jacobian_condition_persistence =
                check_iteration_jacobian_condition_persistence,
            iterative_probe_persistence_minimum_evaluations =
                iterative_probe_persistence_minimum_evaluations,
            iterative_probe_persistence_alignment_threshold =
                iterative_probe_persistence_alignment_threshold,
            rank_persistence_left_nullspace_support_relative =
                iteration_rank_persistence_left_nullspace_support_relative,
            rank_persistence_right_nullspace_support_relative =
                iteration_rank_persistence_right_nullspace_support_relative,
            rank_persistence_scaling_change_factor_threshold =
                iteration_rank_persistence_scaling_change_factor_threshold,
            rank_persistence_expected_mode_residual_tolerance =
                iteration_rank_persistence_expected_mode_residual_tolerance,
            rank_persistence_expected_mode_span_alignment_threshold =
                iteration_rank_persistence_expected_mode_span_alignment_threshold,
            rank_persistence_expected_mode_span_rank_relative_tolerance =
                iteration_rank_persistence_expected_mode_span_rank_relative_tolerance,
            condition_persistence_minimum_evaluations =
                iteration_condition_persistence_minimum_evaluations,
            condition_persistence_relative_tolerance =
                iteration_condition_persistence_relative_tolerance,
            condition_persistence_scaling = iteration_condition_persistence_scaling,
            condition_persistence_max_dense_entries =
                iteration_condition_persistence_max_dense_entries,
            condition_persistence_change_factor_threshold =
                iteration_condition_persistence_change_factor_threshold,
        )
        append!(report.findings, iteration_point_report.findings)
        for (key, value) in iteration_point_report.metadata
            report.metadata[Symbol("iteration_points_", key)] = value
        end
        stages *= ",iteration_points"
    end
    report.metadata[:stage] = "combined"
    report.metadata[:stages] = stages
    sort!(
        report.findings;
        by = finding -> (-Int(finding.severity), string(finding.code)),
    )
    return report
end

end
