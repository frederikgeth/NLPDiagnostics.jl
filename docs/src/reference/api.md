# Stable API reference

New application code should prefer the deliberately small
`NLPDiagnostics.Stable` facade. Its 27 exports cover the solver-neutral path
from a represented model or explicit numerical point to typed findings and
renderer-neutral data. The facade is additive-only during the current release
cycle; the exact policy and executable surface audit are recorded in the
repository [API stability policy](https://github.com/frederikgeth/NLPDiagnostics.jl/blob/main/docs/api_stability.md).

```@example stable_inventory
using NLPDiagnostics
using NLPDiagnostics.Stable

expected = Set((
    :ModelSnapshot,
    :DiagnosticReport,
    :Finding,
    :Evidence,
    :Severity,
    :EvaluationPoint,
    :EvaluationPointKind,
    :EvaluationPointProvenance,
    :NumericalEvaluation,
    :HessianDensitySummary,
    :CoefficientRange,
    :CoefficientProfile,
    :ModelSummary,
    :snapshot,
    :evaluate_numerical,
    :analyze,
    :findings,
    :finding_data,
    :evidence_data,
    :report_data,
    :coefficient_range_data,
    :coefficient_profile,
    :coefficient_profile_data,
    :model_summary,
    :model_summary_data,
    :hessian_density_summary,
    :hessian_density_summary_data,
))
@assert setdiff(Set(names(NLPDiagnostics.Stable)), Set((:Stable,))) == expected
length(expected)
```

The root bindings remain aliases of the Stable objects during consolidation.
Root-only exports are legacy or research-facing unless the stability policy
explicitly promotes them.

## Typical workflow

Use `analyze` for the default read-only diagnostic pass, filter by durable
finding code, and serialize only at the presentation or storage boundary:

```@example stable_workflow
using JuMP
using NLPDiagnostics.Stable

model = Model()
@variable(model, x)
@constraint(model, x >= 10)
@constraint(model, x <= 5)

model_snapshot = snapshot(model)
report = analyze(model)
contradictions = findings(
    report;
    code = :inconsistent_affine_implied_variable_bounds,
)
payload = report_data(report)

@assert model_snapshot isa ModelSnapshot
@assert report isa DiagnosticReport
@assert only(contradictions) isa Finding
@assert haskey(payload, "findings")
(
    variables = length(model_snapshot.variables),
    contradictions = length(contradictions),
    serialized_findings = length(payload["findings"]),
)
```

`analyze` never solves or mutates the model. Its keyword surface includes
opt-in research checks; record every nondefault policy and tolerance with the
experiment.

## Explicit numerical points

Numerical evidence belongs to an exact variable order, coordinate vector, and
provenance record. Construct the point explicitly, then evaluate the same
model representation:

```@example stable_point
using JuMP
import MathOptInterface as MOI
using NLPDiagnostics.Stable

model = Model()
@variable(model, z)
@objective(model, Min, (z - 2)^2)
@constraint(model, z^2 >= 1)

variables = MOI.get(JuMP.backend(model), MOI.ListOfVariableIndices())
provenance = EvaluationPointProvenance(
    source = "stable-api-reference",
    metadata = Dict("purpose" => "documented point evaluation"),
)
point = EvaluationPoint(
    variables,
    [1.5];
    label = "candidate",
    provenance = provenance,
)
evaluation = evaluate_numerical(model, point)

@assert evaluation isa NumericalEvaluation
@assert evaluation.point === point
(
    label = evaluation.point.label,
    objective = evaluation.objective_value,
    constraint_rows = length(evaluation.constraint_values),
    failures = length(evaluation.failures),
)
```

The constructor defaults to user-supplied, complete provenance. Other point
kinds are used by initialization, solver-result, solver-iterate, perturbation,
and transport workflows. Point kind states are data returned in provenance;
helpers for producing specialized points currently remain in the root or
research-facing API.

## Types

| Export | Role |
|:--|:--|
| `ModelSnapshot` | Immutable copy of public MOI model data used for read-only analysis. |
| `DiagnosticReport` | Iterable collection of typed findings plus run metadata. |
| `Finding` | Classified observation, evidence, affected entities, and actions. |
| `Evidence` | Renderer-neutral evidence summary with printable details. |
| `Severity` | Practical consequence level, independent of confidence or evidence basis. |
| `EvaluationPoint` | Ordered numerical coordinates with a label and provenance. |
| `EvaluationPointKind` | Typed origin category for a numerical point. |
| `EvaluationPointProvenance` | Origin, completeness, and metadata for a point. |
| `NumericalEvaluation` | Values and derivatives observed at one exact point. |
| `HessianDensitySummary` | Declared or candidate Hessian structure compared with numerical nonzeros at one point and tolerance. |
| `CoefficientRange` | Magnitude counts and span for one explicitly defined static coefficient family. |
| `CoefficientProfile` | Static algebraic ranges, linear-matrix density, coverage limits, and observations. |
| `ModelSummary` | Compact model inventory, fingerprint provenance, bridge observability, and coefficient profile. |

```@docs
NLPDiagnostics.ModelSnapshot
NLPDiagnostics.DiagnosticReport
NLPDiagnostics.Finding
NLPDiagnostics.Evidence
NLPDiagnostics.Severity
NLPDiagnostics.EvaluationPoint
NLPDiagnostics.EvaluationPointKind
NLPDiagnostics.EvaluationPointProvenance
NLPDiagnostics.NumericalEvaluation
NLPDiagnostics.HessianDensitySummary
NLPDiagnostics.CoefficientRange
NLPDiagnostics.CoefficientProfile
NLPDiagnostics.ModelSummary
```

## Model ingestion and analysis

```@docs
NLPDiagnostics.snapshot
NLPDiagnostics.evaluate_numerical
NLPDiagnostics.analyze
NLPDiagnostics.coefficient_profile
NLPDiagnostics.model_summary
NLPDiagnostics.hessian_density_summary
```

`snapshot` records public represented data and opaque-source markers. It does
not claim that callback internals, source-file intent, units, or physical
semantics have been recovered. `evaluate_numerical` returns missing values and
typed failures when evidence is unavailable instead of filling it with a guess.

## Filtering and serialization

```@docs
NLPDiagnostics.findings
NLPDiagnostics.finding_data
NLPDiagnostics.evidence_data
NLPDiagnostics.report_data
NLPDiagnostics.coefficient_range_data
NLPDiagnostics.coefficient_profile_data
NLPDiagnostics.model_summary_data
NLPDiagnostics.hessian_density_summary_data
```

The `*_data` functions return dictionaries and arrays containing plain
renderer-neutral values. They are the supported boundary for JSON, experiment
artifacts, web views, or downstream tables. The typed objects remain the better
boundary for analysis code because their classification axes cannot be confused
with display strings.

```@example stable_serialization
using JuMP
using NLPDiagnostics.Stable

model = Model()
@variable(model, x)
report = analyze(model)
finding = first(report)
finding_record = finding_data(finding)
evidence_records = evidence_data.(finding.evidence)

@assert finding_record["code"] == string(finding.code)
@assert length(evidence_records) == length(finding.evidence)
(
    finding_keys = sort!(collect(keys(finding_record))),
    evidence_count = length(evidence_records),
)
```

## Research-facing APIs

`NLPDiagnostics.Advanced` contains a small explicit facade for profiling,
rank-policy, and unavailable-capability experiments. It carries no Stable-tier
compatibility guarantee. Solver traces, detailed scaling maps, physical KKT
contracts, power-system adapters, and the broader historical root namespace
remain research-facing while their ownership and contracts are reviewed.

```@docs
NLPDiagnostics.jacobian_rank_estimate
```
