# Initial architecture

This document records decisions that should remain stable as implementation
details evolve.

## Stable boundary

The generic core consumes `MOI.ModelLike` through public attributes:

- variables and their metadata;
- objective function and sense;
- constraint functions, sets, and metadata; and
- where available, `MOI.NLPBlockData` evaluator capabilities.

It must not depend on JuMP's internal data structures. JuMP-specific
conveniences may be added without making JuMP the analysis boundary.

Modern MOI has two useful nonlinear views:

1. `MOI.ScalarNonlinearFunction` is the symbolic tree used by the regular model
   API. It composes constants, variable indices, affine functions, quadratic
   functions, and nested nonlinear functions.
2. `MOI.Nonlinear.Evaluator` implements `MOI.AbstractNLPEvaluator`. Depending on
   its initialized features, it exposes expression graphs, objective and
   constraint values, gradients, Jacobian structure and values, Jacobian-vector
   products, Hessian information, and Hessian-vector products.

The symbolic model view is the default static-analysis input. Evaluator
features are capabilities: numerical stages must ask which features are
available and explain when an analysis cannot be performed.

## Intermediate representations

The first `ModelSnapshot` is deliberately small. It makes a read-only copy of
public functions and sets, records opaque callback sources, and normalizes
entity references for reports. An `NLPBlock` that has not supplied an
expression graph makes symbolic incidence incomplete; it must never cause a
false disconnected-variable conclusion. Planned layers are:

```text
MOI.ModelLike
    -> ModelSnapshot              public model entities and metadata
    -> ExpressionIR              normalized expression DAG and domains
    -> IncidenceGraph            variables, constraints, components
    -> EvaluationCache           point-tagged f, c, gradient, J, H data
    -> ExpressionRisks           derivative domains and numeric fingerprints
    -> Analysis-specific views   active set, nullspaces, reduced Hessian
```

An evaluation cache entry includes the source model identity, explicit cache
generation, evaluation point, numeric type, finite-difference configuration,
and success/failure evidence. MOI has no generic model mutation counter, so a
caller must clear a reused cache after changing the model. Values computed at
different points are never silently combined.

## Report semantics

A finding has four independent classification axes:

| Axis | Examples |
|---|---|
| Severity | info, warning, error |
| Issue domain | mathematical, numerical, physical, representational |
| Evidence basis | mathematical proof, structural proof, physical expectation, numerical observation, local inference, heuristic interpretation |
| Confidence | low, medium, high, certain |

This avoids treating “physical” or “numerical” as confidence levels. Plugins
may contribute physical evidence, but the generic core owns the report schema.

## Static-analysis scope

The first implementation intentionally detects exact or canonical facts. It
does not claim algebraic equivalence of arbitrary nonlinear expressions.
Likewise, a disconnected variable means no incidence in the objective or a
non-domain constraint; bounds and integrality alone do not count as incidence.

## Next slices

1. Add expression-domain propagation with evidence pointing to expression
   nodes and bound assumptions. **Implemented for the initial generic operator
   set.**
2. Build the variable–constraint bipartite graph and connected components.
   **Implemented.**
3. Classify scalar constraint rows, then implement maximum matching and
   Dulmage–Mendelsohn decomposition without
   assigning numerical-rank meaning to structural rank. **Initial three-way
   partition and irreducible well-determined blocks implemented.**
4. Add an evaluator capability adapter and point-tagged numerical cache.
   **Implemented for symbolic functions, `NLPBlock`, and
   `VectorNonlinearOracle`.**
5. Report Jacobian row/column norms and rank estimates with method, threshold,
   scale, and evaluation point. **Infinity-norm scale summaries implemented;
   rank estimates remain next.**
6. Separate primitive value domains, finite derivative domains, and
   floating-point range/fingerprint risks. **Initial implementation complete.**
7. Introduce `DegeneracyHypothesis` to compare observed nullspaces with expected
   gauges supplied by plugins.

PowerModels and multiconductor semantics should begin only after these generic
interfaces have tests and extension points.
