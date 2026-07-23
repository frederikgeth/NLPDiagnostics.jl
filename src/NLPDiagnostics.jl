module NLPDiagnostics

# Keep the generic core dependent on public MathOptInterface APIs only.

import MathOptInterface as MOI

include("reports/types.jl")
include("reports/text.jl")
include("ir/model_snapshot.jl")
include("ir/expression_support.jl")
include("ir/structural_roles.jl")
include("ir/incidence_graph.jl")
include("analysis/matching.jl")
include("reports/structural_graph.jl")
include("analysis/static.jl")
include("analysis/structure.jl")

export Confidence
export ConfidenceCertain, ConfidenceHigh, ConfidenceLow, ConfidenceMedium
export ConstraintRole
export CoupledConstraint, EqualityConstraint, FreeConstraint
export InequalityConstraint, OpaqueConstraint
export DiagnosticReport
export DulmageMendelsohnBlock
export DulmageMendelsohnPartition
export EntityRef
export Evidence
export EvidenceBasis
export Finding
export IncidenceGraph
export IssueDomain
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
export StructuralVariableNode
export VariableSupport
export VariableRole
export FixedVariable, FreeVariable, InfeasibleVariableDomain, ParameterVariable
export analyze
export analyze_static
export analyze_structure
export connected_components
export constraint_role
export dulmage_mendelsohn
export incidence_graph
export is_coordinatewise_set
export matching_cardinality
export maximum_matching
export snapshot
export structural_graph_data
export structural_graph_dot
export structural_graph_text
export variable_support
export variable_roles
export well_determined_blocks

"""
    analyze(model::MOI.ModelLike)

Run the solver-independent analyses currently implemented by NLPDiagnostics.

Run all implemented solver-independent analysis stages.
"""
function analyze(model::MOI.ModelLike)
    model_snapshot = snapshot(model)
    graph = incidence_graph(model_snapshot)
    report = analyze_static(model_snapshot; graph = graph)
    structural_report = analyze_structure(
        model_snapshot;
        graph = graph,
    )
    append!(report.findings, structural_report.findings)
    merge!(report.metadata, structural_report.metadata)
    report.metadata[:stages] = "static,structural"
    sort!(
        report.findings;
        by = finding -> (-Int(finding.severity), string(finding.code)),
    )
    return report
end

end
