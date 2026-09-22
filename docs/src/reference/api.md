# Core API

New application code should prefer the deliberately small
`NLPDiagnostics.Stable` facade. The root namespace remains available during the
pre-release consolidation phase. Point construction and presentation helpers
currently remain in the root API; their stability is described in the repository
[API policy](https://github.com/frederikgeth/NLPDiagnostics.jl/blob/main/docs/api_stability.md).

## Stable facade

The stable facade exports the report, finding, evidence, snapshot, evaluation,
analysis, filtering, and serialization types/functions needed by ordinary
consumers:

```@example stable_api
using NLPDiagnostics
using NLPDiagnostics.Stable

stable_exports = names(NLPDiagnostics.Stable)
@assert :analyze in stable_exports
@assert :report_data in stable_exports
stable_exports
```

## Analysis and points

```@docs
NLPDiagnostics.analyze
NLPDiagnostics.EvaluationPoint
NLPDiagnostics.EvaluationPointProvenance
NLPDiagnostics.evaluation_point
NLPDiagnostics.evaluate_numerical
```

## Reports and findings

```@docs
NLPDiagnostics.findings
NLPDiagnostics.report_data
NLPDiagnostics.finding_data
NLPDiagnostics.evidence_data
NLPDiagnostics.text_report
NLPDiagnostics.markdown_report
```

The keyword surface of `analyze` includes opt-in research checks. Begin with the
default analysis, then enable a check only when its evidence answers a stated
question. Record nondefault policies and tolerances with experimental results.

## Research-facing API

`NLPDiagnostics.Advanced` contains a small explicit facade for profiling,
rank-policy, and unavailable-capability experiments. It carries no Stable-tier
compatibility guarantee. The broader root namespace contains legacy and
domain-extension exports under active ownership review.

```@docs
NLPDiagnostics.jacobian_rank_estimate
```
