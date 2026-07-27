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
export CoupledSetFeasibilitySummary
export ComponentMetadata
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
export CoupledConstraint, EqualityConstraint, FreeConstraint
export InequalityConstraint, OpaqueConstraint
export DiagnosticReport
export DomainAssessment
export DomainPossibleViolation, DomainProvenViolation, DomainSafe
export DulmageMendelsohnBlock
export DulmageMendelsohnPartition
export EntityRef
export Evidence
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
export OperatorDomainRequirement
export OperatorDerivativeRequirement
export ProfileCase
export ProfileAggregate
export ProfileResult
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
export LocalInference, HeuristicInterpretation, StructuralProof
export Severity
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
export analyze_derivatives
export analyze_degeneracy
export analyze_expressions
export stable_reformulation_plan
export analyze_stable_reformulation_plan
export analyze_initialization
export analyze_numerical
export analyze_reduced_hessian
export analyze_active_set
export analyze_active_set_second_order
export analyze_component_ranks
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
export analyze_solver_log
export analyze_solver_iterations
export analyze_iteration_points
export profile_case
export profile_case_repeated
export profile_cases_repeated
export compare_profiles
export synthetic_sparse_profile_corpus
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
export iterative_jacobian_spectrum_estimate
export constraint_feasibility_summary
export coupled_set_feasibility_summary
export coupled_set_activity
export active_constraint_rows
export active_set_matching
export mfcq_screen
export recover_stationarity_multipliers
export nullspace_fingerprints
export expected_nullspace_modes
export component_metadata
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
        scope_rank_bound = minimum(
            filter(value -> !iszero(value), [
                length(unique(item.variables)),
                length(unique((item.index, item.subindex) for item in item.constraints)),
            ]);
            init = typemax(Int),
        )
        if scope_rank_bound != typemax(Int) && !isnothing(item.expected_rank) &&
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
                     set_value isa Union{MOI.SecondOrderCone,MOI.RotatedSecondOrderCone,MOI.Nonnegatives,MOI.Nonpositives,MOI.Zeros}
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

function _elastic_domain_argument(
    model_snapshot::ModelSnapshot,
    issue::ExpressionDomainIssue,
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
    issue.argument <= length(expression.args) || return nothing
    return expression.args[issue.argument]
end

function _elastic_domain_guard_materialization(
    model_snapshot::ModelSnapshot,
    issue::ExpressionDomainIssue,
)
    argument = _elastic_domain_argument(model_snapshot, issue)
    isnothing(argument) && return false,
        "the nonlinear argument cannot be recovered as a scalar source expression"
    argument isa Union{MOI.VariableIndex,MOI.ScalarAffineFunction{Float64}} ||
        return false, "the argument is not a directly guardable scalar affine expression"
    if issue.operator in (:log, :log10, :log2, :log1p, :sqrt) ||
       (issue.operator == :^ && startswith(issue.requirement, "base > 0"))
        return true, "a scalar affine lower-domain guard can be materialized explicitly"
    elseif issue.operator in (:asin, :acos, :asind, :acosd)
        return true, "the closed inverse-trigonometric input interval can be materialized explicitly"
    elseif issue.operator == :acosh
        return true, "the scalar affine lower domain for acosh can be materialized explicitly"
    elseif issue.operator == :atanh
        return true, "both strict scalar affine atanh domain boundaries can be materialized explicitly"
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
            evidence = [Evidence("Elastic domain guard"; details = ["operator" => guard.operator, "argument" => guard.argument, "requirement" => guard.requirement, "assessment" => guard.assessment, "materializable" => guard.materializable, "reason" => guard.reason])],
            affected = [guard.source],
            suggested_actions = guard.materializable ?
                                ["Use an explicit guarded auxiliary formulation with a stated positive margin before interpreting elastic results."] :
                                ["Use a domain-specific guarded formulation or reformulation; do not infer feasibility from an unguarded elastic solve."],
        ))
    end
    return report
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
    guard.argument <= length(expression.args) || return nothing
    return expression.args[guard.argument]
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
    elseif guard.operator == :sqrt
        return Any[MOI.GreaterThan(0.0)]
    elseif guard.operator in (:asin, :acos, :asind, :acosd)
        return Any[MOI.Interval(-1.0, 1.0)]
    elseif guard.operator == :acosh
        return Any[MOI.GreaterThan(1.0)]
    elseif guard.operator == :atanh
        return Any[MOI.GreaterThan(-1.0 + margin), MOI.LessThan(1.0 - margin)]
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
    auxiliary = MOI.Utilities.Model{Float64}()
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
           set_value isa Union{MOI.SecondOrderCone,MOI.RotatedSecondOrderCone,MOI.Nonnegatives,MOI.Nonpositives,MOI.Zeros}
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
                else
                    coordinatewise = set_value isa Union{MOI.Nonnegatives,MOI.Nonpositives}
                    target_row = coordinatewise ? position : 1
                    coefficient = set_value isa MOI.Nonpositives ? -1.0 : 1.0
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
        push!(report, Finding(:elastic_constraint_relaxed;
            severity = SeverityWarning, domain = MathematicalIssue,
            basis = NumericalObservation, confidence = ConfidenceHigh,
            observation = "Elastic auxiliary values apply $(item.kind) relaxation to constraint $(item.source.index) with total slack $(item.total) and weighted slack magnitude $(item.weighted_total).",
            why_it_matters = "This identifies a row requiring relaxation in the supplied auxiliary point; it is not an IIS or a proof that this row alone causes infeasibility.",
            evidence = [Evidence("Elastic relaxation values"; details = ["kind" => item.kind, "slacks" => join(item.values, ","), "total" => item.total, "weighted_slack_magnitude" => item.weighted_total, "objective_norm" => auxiliary.objective_norm, "tolerance" => tolerance])],
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
            "unavailable", Vector{Vector{EntityRef}}(), Vector{Vector{EntityRef}}(),
            sprint(showerror, error),
        )
    end
    status = try
        MOI.get(optimizer, MOI.ConflictStatus())
    catch error
        return SolverConflictResult(
            string(typeof(optimizer)), optimize_before_conflict, termination,
            "unavailable", Vector{Vector{EntityRef}}(), Vector{Vector{EntityRef}}(),
            "could not read MOI.ConflictStatus: $(sprint(showerror, error))",
        )
    end
    conflict_count = try
        MOI.get(optimizer, MOI.ConflictCount())
    catch
        0
    end
    model_snapshot = snapshot(model)
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
        string(status), conflicts, maybe_conflicts, nothing,
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
    report.metadata[:solver_conflict_count] = string(length(result.conflicts))
    if !isnothing(result.error)
        push!(report, Finding(:solver_conflict_unavailable;
            severity = SeverityInfo, domain = RepresentationalIssue,
            basis = NumericalObservation, confidence = ConfidenceHigh,
            observation = "The selected optimizer did not provide a readable MOI conflict result.",
            why_it_matters = "No conflict-based conclusion is made when the solver interface is unavailable or rejects the request.",
            evidence = [Evidence("MOI conflict interface"; details = ["optimizer_type" => result.optimizer_type, "error" => result.error])],
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
                evidence = [Evidence("MOI conflict membership"; details = ["conflict_index" => index, "optimizer_type" => result.optimizer_type, "termination_status" => result.termination_status])],
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
        estimate.rank == component.expected_rank && continue
        push!(report, Finding(:component_expected_rank_mismatch;
            severity = SeverityWarning, domain = RepresentationalIssue,
            basis = NumericalObservation, confidence = ConfidenceHigh,
            observation = "Component $(component.component_type) '$(component.component_id)' declares expected rank $(component.expected_rank), while its scoped local Jacobian rank is $(estimate.rank).",
            why_it_matters = "The discrepancy may indicate a stale component declaration, an operating-point rank loss, or a domain-specific modeling issue; the generic core does not choose among them.",
            evidence = [Evidence("Scoped component Jacobian rank"; details = ["expected_rank" => component.expected_rank, "observed_rank" => estimate.rank, "rows" => estimate.rows, "columns" => estimate.columns, "point" => evaluation.point.label])],
            affected = vcat([EntityRef(:variable, variable.value) for variable in component.variables], component.constraints),
            suggested_actions = ["Inspect the component's operating point, declared scope, and domain-plugin rank assumption."],
        ))
    end
    report.metadata[:component_rank_declared_count] = string(declared)
    report.metadata[:component_rank_comparison_count] = string(compared)
    report.metadata[:component_rank_unavailable_count] = string(unavailable)
    return report
end

"""
    analyze(model::MOI.ModelLike)

Run all implemented solver-independent analysis stages. Numerical analysis is
included only when an explicit `point` is provided.
"""
function analyze(
    model::MOI.ModelLike;
    point::Union{Nothing,EvaluationPoint} = nothing,
    cache::EvaluationCache = EvaluationCache(),
    scale_ratio_threshold::Real = 1.0e6,
    numeric_type::Union{Nothing,Type{<:AbstractFloat}} = nothing,
    check_initialization::Bool = false,
    check_active_set::Bool = false,
    check_degeneracy::Bool = false,
)
    declared_components = component_metadata(model)
    selected_numeric_type = if !isnothing(numeric_type)
        numeric_type
    elseif !isnothing(point)
        eltype(point.values)
    else
        Float64
    end
    model_snapshot = snapshot(model)
    graph = incidence_graph(model_snapshot)
    report = analyze_static(model_snapshot; graph = graph)
    report.metadata[:component_metadata_count] = string(length(declared_components))
    component_report = _component_metadata_findings(
        declared_components;
        model_variables = [record.index for record in model_snapshot.variables],
        model_constraints = [_constraint_ref(record) for record in model_snapshot.constraints],
    )
    append!(report.findings, component_report.findings)
    domain_report = analyze_domains(model_snapshot)
    derivative_report = analyze_derivatives(model_snapshot)
    expression_report = analyze_expressions(
        model_snapshot;
        numeric_type = selected_numeric_type,
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
    if !isnothing(point)
        numerical_report = analyze_numerical(
            model,
            point;
            cache = cache,
            scale_ratio_threshold = scale_ratio_threshold,
            numeric_type = selected_numeric_type,
        )
        append!(report.findings, numerical_report.findings)
        merge!(report.metadata, numerical_report.metadata)
        component_rank_report = analyze_component_ranks(
            model,
            evaluate_numerical(model, point; cache = cache);
            components = declared_components,
        )
        append!(report.findings, component_rank_report.findings)
        merge!(report.metadata, component_rank_report.metadata)
        stages *= ",numerical"
        if check_active_set
            active_report = analyze_active_set(model, point; cache = cache)
            append!(report.findings, active_report.findings)
            merge!(report.metadata, active_report.metadata)
            stages *= ",active_set"
        end
        if check_degeneracy
            degeneracy_report = analyze_degeneracy(model, point; cache = cache)
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
            scale_ratio_threshold = scale_ratio_threshold,
        )
        append!(report.findings, initialization_report.findings)
        merge!(report.metadata, initialization_report.metadata)
        stages *= ",initialization"
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
