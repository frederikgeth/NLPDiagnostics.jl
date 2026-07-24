module NLPDiagnostics

# Keep the generic core dependent on public MathOptInterface APIs only.

import MathOptInterface as MOI
using LinearAlgebra

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
export ExpressionNodePath
export Finding
export IncidenceGraph
export IssueDomain
export IntervalEnclosure
export JacobianEntry
export JacobianRankEstimate
export SparseJacobianPatternEstimate
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
export ProfileFindingStability
export SolverPostmortem
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
export FixedVariable, FreeVariable, InfeasibleVariableDomain, ParameterVariable
export analyze
export analyze_domains
export analyze_derivatives
export analyze_degeneracy
export analyze_expressions
export analyze_initialization
export analyze_numerical
export analyze_reduced_hessian
export analyze_active_set
export analyze_active_set_second_order
export analyze_static
export analyze_structure
export analyze_postmortem
export profile_case
export profile_case_repeated
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
export incidence_graph
export initialization_point
export is_coordinatewise_set
export matching_cardinality
export maximum_matching
export jacobian_scale_summary
export jacobian_rank_estimate
export sparse_jacobian_pattern_estimate
export constraint_feasibility_summary
export coupled_set_feasibility_summary
export coupled_set_activity
export active_constraint_rows
export active_set_matching
export mfcq_screen
export recover_stationarity_multipliers
export nullspace_fingerprints
export expected_nullspace_modes
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
export well_determined_blocks

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
