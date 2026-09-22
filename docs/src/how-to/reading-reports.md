# Reading a report

A report is a collection of typed findings. Start with errors and warnings, but
read each finding as an evidence claim rather than as an instruction to edit the
model.

```@example reading_reports
using JuMP, NLPDiagnostics

model = Model()
@variable(model, x)
@constraint(model, x >= 4)
@constraint(model, x <= 1)
report = analyze(model)

errors = findings(report; severity = SeverityError)
@assert !isempty(errors)
finding = first(errors)
(
    code = finding.code,
    basis = finding.basis,
    confidence = finding.confidence,
    affected = length(finding.affected),
)
```

For every finding, ask:

1. **Observation:** what value, relation, or pattern was found?
2. **Basis:** is it a mathematical proof, structural proof, numerical
   observation, physical expectation, local inference, or heuristic?
3. **Scope:** does it concern the model globally or only a supplied point?
4. **Provenance:** which model entities, point, tolerance, and backend produced it?
5. **Action:** what check or intervention would discriminate between explanations?

## Filtering and serialization

Filter typed reports before rendering them:

```@example reading_reports
proof_errors = findings(
    report;
    severity = SeverityError,
    basis = MathematicalProof,
)
@assert !isempty(proof_errors)
```

Use `report_data(report)` when saving or exchanging results. Use
`finding_data(finding)` and `evidence_data(evidence)` when integrating individual
records. The terminal and Markdown renderers are presentation layers; they do
not add evidence.

```@example reading_reports
serialized = report_data(report)
@assert length(serialized["findings"]) == length(report)
sort!(collect(keys(serialized)))
```

## Common reading mistakes

- A local rank estimate is not a proof of global non-identifiability.
- Failure to evaluate an expression at a supplied point is not proof that the
  model has no feasible point.
- Structural underdetermination describes an incidence pattern; numerical rank
  and physical gauge interpretation require additional evidence.
- A solver's successful termination does not by itself verify every model
  equation at the tolerances relevant to your application.
- An informational finding is retained evidence, not necessarily an action item.

When a required capability is unavailable, keep the unavailable reason in the
experiment record. Do not interpret absence of a measurement as absence of a
problem.
