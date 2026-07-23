module NLPDiagnostics

# Keep the generic core dependent on public MathOptInterface APIs only.

import MathOptInterface as MOI

include("reports/types.jl")
include("reports/text.jl")
include("ir/model_snapshot.jl")
include("analysis/static.jl")

export Confidence
export ConfidenceCertain, ConfidenceHigh, ConfidenceLow, ConfidenceMedium
export DiagnosticReport
export EntityRef
export Evidence
export EvidenceBasis
export Finding
export IssueDomain
export MathematicalIssue, NumericalIssue, PhysicalIssue, RepresentationalIssue
export MathematicalProof, NumericalObservation, PhysicalExpectation
export LocalInference, HeuristicInterpretation, StructuralProof
export Severity
export SeverityError, SeverityInfo, SeverityWarning
export analyze
export analyze_static
export snapshot

"""
    analyze(model::MOI.ModelLike)

Run the solver-independent analyses currently implemented by NLPDiagnostics.

The first release contains static analyses only. Later stages will be added
without changing the evidence-first report format.
"""
analyze(model::MOI.ModelLike) = analyze_static(snapshot(model))

end
