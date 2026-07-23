module NLPDiagnostics

# Keep the generic core dependent on public MathOptInterface APIs only.

import MathOptInterface as MOI

include("reports/types.jl")
include("reports/text.jl")
include("ir/model_snapshot.jl")
include("ir/expression_support.jl")
include("ir/incidence_graph.jl")
include("analysis/static.jl")
include("analysis/structure.jl")

export Confidence
export ConfidenceCertain, ConfidenceHigh, ConfidenceLow, ConfidenceMedium
export DiagnosticReport
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
export VariableSupport
export analyze
export analyze_static
export analyze_structure
export connected_components
export incidence_graph
export snapshot
export variable_support

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
