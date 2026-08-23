"""
Small, backward-compatible public API facade.

The root exports remain available for compatibility during consolidation, but
new application code can depend on this deliberately narrow surface. Advanced
profiling, numerical-policy, and typed-capability experiments remain under
`NLPDiagnostics.Advanced`.
"""
module Stable

import ..NLPDiagnostics

const ModelSnapshot = NLPDiagnostics.ModelSnapshot
const DiagnosticReport = NLPDiagnostics.DiagnosticReport
const Finding = NLPDiagnostics.Finding
const Evidence = NLPDiagnostics.Evidence
const Severity = NLPDiagnostics.Severity
const EvaluationPoint = NLPDiagnostics.EvaluationPoint
const EvaluationPointKind = NLPDiagnostics.EvaluationPointKind
const EvaluationPointProvenance = NLPDiagnostics.EvaluationPointProvenance
const NumericalEvaluation = NLPDiagnostics.NumericalEvaluation

const snapshot = NLPDiagnostics.snapshot
const evaluate_numerical = NLPDiagnostics.evaluate_numerical
const analyze = NLPDiagnostics.analyze
const findings = NLPDiagnostics.findings
const finding_data = NLPDiagnostics.finding_data
const evidence_data = NLPDiagnostics.evidence_data
const report_data = NLPDiagnostics.report_data

export ModelSnapshot
export DiagnosticReport
export Finding
export Evidence
export Severity
export EvaluationPoint
export EvaluationPointKind
export EvaluationPointProvenance
export NumericalEvaluation
export snapshot
export evaluate_numerical
export analyze
export findings
export finding_data
export evidence_data
export report_data

end
