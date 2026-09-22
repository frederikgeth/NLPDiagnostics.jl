# NLPDiagnostics.jl

NLPDiagnostics helps you investigate nonlinear optimization models expressed
with JuMP and MathOptInterface. It records what was observed, the evidence
behind each finding, and the limits of the conclusion. It never changes your
model.

This documentation is written primarily for researchers and PhD candidates
experimenting with nonlinear programs (NLPs), optimal power flow (OPF), model
formulations, initialization, scaling, and solver behaviour.

## What question are you asking?

| Question | Begin with |
|:--|:--|
| “Why is this small model inconsistent?” | [Your first diagnosis](tutorials/first-diagnosis.md) |
| “Are my represented coefficients and units plausible?” | [Inspect a model before solving](tutorials/model-summary-and-units.md) |
| “Did the model fail, or is my starting point invalid?” | [Model failure or bad start?](tutorials/initialization.md) |
| “Is this Jacobian rank loss point- or tolerance-specific?” | [Numerical rank at a point](tutorials/numerical-rank.md) |
| “Did a scaling change alter the solver trajectory?” | [Controlled scaling and solver traces](tutorials/controlled-scaling-trace.md) |
| “Does this null direction represent an OPF gauge?” | [From NLP evidence to OPF hypotheses](tutorials/opf-hypotheses.md) |
| “Do two OPF formulations agree physically?” | [Compare OPF formulations](tutorials/controlled-opf-comparison.md) |
| “How do I investigate a complete OPF run?” | [Three-bus OPF investigation](tutorials/three-bus-opf.md) |
| “I have a solver symptom; what should I inspect?” | [Diagnostic playbook](how-to/diagnostic-playbook.md) |
| “What does this finding actually establish?” | [Evidence and claims](concepts/evidence.md) |
| “How should I structure an experiment?” | [A research workflow](research-workflow.md) |
| “Which earlier tools and terms does this build on?” | [Prior art and shared terminology](reference/prior-art.md) |

## The central habit

A solver status is an observation, not an explanation. A useful investigation
moves through four questions:

1. **What was observed?** For example, contradictory bounds, a non-finite
   expression at a supplied point, or a locally small singular value.
2. **What claim does the evidence support?** Mathematical proof, structural
   evidence, local numerical evidence, or a heuristic interpretation have
   different reach.
3. **What evidence is missing?** Unavailable evidence remains visible in a
   report instead of being replaced with a guess.
4. **Which controlled intervention tests the hypothesis?** Change one reference,
   start, scaling policy, or formulation choice and compare like with like.

```@example home
using JuMP, NLPDiagnostics

model = Model()
@variable(model, x)
@constraint(model, x >= 10)
@constraint(model, x <= 5)

report = analyze(model)
first_error = first(findings(report; severity = SeverityError))
(code = first_error.code, basis = first_error.basis)
```

The result is a mathematical contradiction in the model. It does not depend on
a solver run. By contrast, a derivative or domain failure at one point usually
supports a local numerical conclusion. The tutorials develop this distinction
through runnable examples.

If you already have a failed experiment, begin with the [diagnostic
playbook](how-to/diagnostic-playbook.md). Preserve a copy of the [experiment
record](reference/experiment-record.md) before changing starts, formulations,
scaling, or solver settings.

!!! warning "Research prototype"
    NLPDiagnostics is pre-release software. Finding codes and research-facing
    APIs may evolve. Physical interpretations and numerical thresholds remain
    subject to the documented evidence and calibration boundaries.
