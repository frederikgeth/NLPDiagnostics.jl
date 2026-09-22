# Tutorial: your first diagnosis

This tutorial investigates a tiny inconsistent JuMP model. The aim is to learn
the workflow: predict, observe, interpret, intervene, and compare.

!!! note "Learning goals"
    After this tutorial, you can identify a proof-backed contradiction, inspect
    its evidence basis, and test a one-change repair without relying on a solver.

    **Prerequisites:** basic JuMP variables and constraints. **Time:** about 10
    minutes. **Artifact:** before-and-after diagnostic reports.

## Question and prediction

Can one scalar variable satisfy both ``x \ge 10`` and ``x \le 5``? Before
running anything, predict that the feasible set is empty for a mathematical
reason. No solver behaviour is needed to establish it.

## Build and inspect

```@example first_diagnosis
using JuMP, NLPDiagnostics

model = Model()
@variable(model, x)
@constraint(model, lower, x >= 10)
@constraint(model, upper, x <= 5)

report = analyze(model)
codes = Set(finding.code for finding in report)
@assert :inconsistent_affine_implied_variable_bounds in codes
print(text_report(report))
```

The report may contain several views of the same underlying model. The
one-variable bound analysis proves an empty implied interval. Structural
findings may also observe that no equality determines `x`; that fact is true,
but it is not the cause of this contradiction.

Inspect the specific finding:

```@example first_diagnosis
contradiction = only(findings(
    report;
    code = :inconsistent_affine_implied_variable_bounds,
))
@assert contradiction.basis == MathematicalProof
(
    observation = contradiction.observation,
    affected_entities = contradiction.affected,
    suggested_actions = contradiction.suggested_actions,
)
```

`MathematicalProof` means the conclusion follows from the supported represented
model data. It does not mean that source-data intent, units, or the physical
meaning of the bound has been verified.

## Make one intervention

Suppose the upper bound was a transcription error and the intended value was
15. Rebuild that single input and rerun the same analysis:

```@example first_diagnosis
repaired = Model()
@variable(repaired, y)
@constraint(repaired, y >= 10)
@constraint(repaired, y <= 15)

repaired_report = analyze(repaired)
@assert isempty(findings(repaired_report; severity = SeverityError))
print(text_report(repaired_report))
```

The error disappears as predicted. This is evidence that the contradictory
bounds caused the static inconsistency. In a real investigation, justify the
new bound from an authoritative source record; the diagnostic cannot decide
which bound reflects the intended system.

## Exercise

Replace the upper bound with `x <= 10`. Predict the outcome before running the
analysis. Is the variable infeasible, merely bounded, or fixed? Inspect the
finding basis and affected entities, then explain what the result does and does
not establish about a larger model containing this variable.

!!! tip "Hint"
    An interval with identical lower and upper endpoints is nonempty. Look for
    a finding that distinguishes a fixed variable from an inconsistent one.

!!! info "Expected observations"
    The two inequalities fix ``x`` at 10, so the contradiction disappears. The
    result establishes the implied value in this represented scalar block; it
    does not establish feasibility of unrelated constraints in a larger model.
