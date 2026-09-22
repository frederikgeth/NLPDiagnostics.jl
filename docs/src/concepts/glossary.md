# Glossary and notation

**Affected entity** — A variable, constraint, expression node, component, or
other model object to which a finding refers.

**Basis** — The kind of evidence supporting a finding, such as mathematical
proof, structural proof, numerical observation, physical expectation, local
inference, or heuristic interpretation.

**Capability** — Evidence that a model, evaluator, solver, or extension can
expose a requested quantity. Missing capability is reported as unavailable.

**Confidence** — Confidence in the stated finding at its declared scope. It does
not enlarge a local result into a global one.

**Controlled intervention** — An explicit change to one proposed mechanism,
compared with a declared baseline while other relevant inputs are held fixed.

**Coordinate convention** — The ordering, representation, and scaling used for
model variables or residuals. Physical and solver-scaled coordinates are not
interchangeable.

**Diagnostic report** — A typed collection of findings plus metadata. Rendered
text and Markdown are views of this record.

**Evaluation point** — An ordered value for every MOI variable, with a label and
provenance. Numerical conclusions are local to this point.

**Evidence** — Inspectable details supporting an observation. Evidence should
survive serialization independently of prose rendering.

**Finding code** — A machine-readable identifier for one finding family. See
the [finding-code reference](../reference/finding-codes.md).

**Gauge** — A domain-justified invariance, such as a uniform angle shift in an
unreferenced connected AC network. A numerical null vector alone is not a gauge.

**Incidence graph** — A graph connecting variables to constraints in which they
occur. It records structural dependence, not coefficient magnitude.

**Initialization** — Start values explicitly attached to the model. Missing
values are not silently replaced unless a separately documented policy does so.

**Issue domain** — Whether a finding concerns mathematical, numerical, physical,
or representational behaviour.

**Local rank** — Numerical matrix rank at an explicit point, under a recorded
tolerance and scaling policy.

**Model snapshot** — A read-only description copied through public MOI APIs for
analysis. It is distinct from the source files and from solver-internal state.

**Nullspace direction** — A vector with a small direct residual under a specified
matrix, point, norm, and tolerance. Its physical interpretation requires more
evidence.

**Per-unit base** — A declared base used to normalize a physical quantity. A
change of base must be propagated consistently through data, coordinates, and
comparisons.

**Point provenance** — Where an evaluation point came from: user input, model
start, solver iterate, solver result, perturbation, transported state, or
synthetic probe, together with completeness and policy metadata.

**Represented model** — The functions, sets, bounds, objective, and metadata
actually available through the model API. It may differ from source intent.

**Source intent** — What the original data or model author intended to represent.
It requires source records and cannot be inferred solely from a model snapshot.

**Structural matching** — A maximum matching between eligible variables and
equality rows. It describes the incidence pattern and does not compute numerical
rank.

**Tolerance policy** — Recorded absolute/relative thresholds, matrix norm,
scaling, and work limits used to classify numerical evidence.

**Unavailable reason** — A typed record explaining why requested evidence was
not obtained. Unavailable does not mean that the corresponding problem is absent.

**Verified returned point** — A solver result whose represented model quantities
have been recomputed and checked under an explicit acceptance policy. It is not
an operational-safety certificate.

## Common notation

- ``x``: model-coordinate vector.
- ``c(x)``: constraint function or stacked constraint rows.
- ``J(x)``: Jacobian of selected rows at ``x``.
- ``v``: candidate right-null direction, checked through ``J(x)v``.
- ``\sigma_{\min}``: smallest singular value under the stated coordinate scaling.
- ``\tau``: a numerical classification tolerance; always report its definition.
