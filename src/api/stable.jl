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
const HessianDensitySummary = NLPDiagnostics.HessianDensitySummary
const CoefficientRange = NLPDiagnostics.CoefficientRange
const CoefficientProfile = NLPDiagnostics.CoefficientProfile
const ModelSummary = NLPDiagnostics.ModelSummary

const snapshot = NLPDiagnostics.snapshot
const evaluate_numerical = NLPDiagnostics.evaluate_numerical
const analyze = NLPDiagnostics.analyze
const findings = NLPDiagnostics.findings
const finding_data = NLPDiagnostics.finding_data
const evidence_data = NLPDiagnostics.evidence_data
const report_data = NLPDiagnostics.report_data
const coefficient_range_data = NLPDiagnostics.coefficient_range_data
const coefficient_profile = NLPDiagnostics.coefficient_profile
const coefficient_profile_data = NLPDiagnostics.coefficient_profile_data
const model_summary = NLPDiagnostics.model_summary
const model_summary_data = NLPDiagnostics.model_summary_data
const hessian_density_summary = NLPDiagnostics.hessian_density_summary
const hessian_density_summary_data = NLPDiagnostics.hessian_density_summary_data

export ModelSnapshot
export DiagnosticReport
export Finding
export Evidence
export Severity
export EvaluationPoint
export EvaluationPointKind
export EvaluationPointProvenance
export NumericalEvaluation
export HessianDensitySummary
export CoefficientRange
export CoefficientProfile
export ModelSummary
export snapshot
export evaluate_numerical
export analyze
export findings
export finding_data
export evidence_data
export report_data
export coefficient_range_data
export coefficient_profile
export coefficient_profile_data
export model_summary
export model_summary_data
export hessian_density_summary
export hessian_density_summary_data

end
