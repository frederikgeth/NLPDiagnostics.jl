# Initial architecture

This document records decisions that should remain stable as implementation
details evolve.

## Domain component metadata

Optional domain plugins may extend `component_metadata(model)` to return
`ComponentMetadata` records. Each record carries a stable component type and
ID, optional variable-coordinate and constraint scopes, optional units, optional
expected rank, and serializable metadata. The
generic core does not infer these semantics from variable names. A future
PowerModels extension should use this hook with `expected_nullspace_modes` to
declare electrical references, ports, and expected physical gauges.
Plugins may additionally extend `component_port_metadata(model)` with typed
`ComponentPortMetadata` records. A record names component and port identities,
terminal and mode coordinates, an inspectable connection matrix, and optional
MOI variable scope. The generic core validates only representation dimensions
and identities: voltage/current semantics, complex-coordinate conventions, and
physical rank expectations remain with the plugin.
Combined analysis records `component_port_metadata_count` and validates
duplicate port keys, stale variable scopes, non-finite connection coefficients,
and terminal/mode dimension mismatches as representational findings.
It also reports zero and rank-deficient declared connection maps. A deficient
map is not a generic error: it may express a hidden or intentionally disconnected
mode, whose physical interpretation must be declared by the plugin.
Plugins can declare those expected terminal- or mode-space freedoms with
`component_port_nullspace_modes(model)`. Combined analysis compares each
declared direction to its connection map and reports agreement or mismatch;
this is port-level consistency evidence, not network-level observability.
Plugins may declare topology with `component_port_connections(model)`, returning
directed `PortConnectionMetadata` maps from source-terminal to
destination-terminal coordinates. Combined analysis validates endpoint ports,
matrix dimensions, finiteness, and duplicate directed links. It does not infer
connections from labels or claim that a declared map represents physical flow.
The same declarations produce a generic undirected port-topology view with
isolated-port and disconnected-island findings. These are structural facts
about declared maps, not electrical-islanding or observability conclusions.
`port_topology_nullspace(ports, connections)` additionally assembles the
declared equations `destination - map * source = 0` in terminal coordinates.
Its nullspace is an expected topology-level freedom of the declarations, not a
model-variable or physically classified network nullspace.
Combined analysis reports its rank and nullity as
`component_port_topology_expected_nullspace` only when all declarations are
valid. Plugins remain responsible for mapping this terminal-coordinate basis to
model coordinates and for any physical classification.
`component_port_coordinate_maps(model)` supplies the missing explicit bridge
from terminal coordinates to selected MOI variables through `PortCoordinateMap`.
The generic core never assumes that a port variable scope is terminal-ordered;
plugins must declare this map before topology nullspace directions can be
compared with model-coordinate modes. Combined analysis validates the port
identity, terminal/variable dimensions, finite coefficients, and model-variable
scope first; it reports these as representational metadata findings, without
claiming that a coordinate convention is physically correct.
When maps are supplied, the package projects the declared terminal topology
nullspace into model coordinates and checks agreement where several port maps
refer to one variable. The resulting directions are only candidate expected
modes. Their agreement with a Jacobian nullspace, and any OPF interpretation,
remain separate numerical and plugin responsibilities.
`port_topology_expected_nullspace_modes` reduces the visible projected span to
independent `port_topology_candidate_mode_*` declarations. Degeneracy analysis
compares those candidates with an observed local Jacobian right nullspace by
default, but retains their representational provenance and never upgrades that
comparison into an electrical interpretation.
`component_port_coordinate_semantics(model)` separately declares whether a
port's terminals represent voltage, current, power, angle, or a plugin-defined generic
quantity, together with their representation and units. Combined analysis
reports duplicate or unaligned declarations and records when a semantics
declaration has no `PortCoordinateMap`; physical meaning without that bridge is
not treated as numerical model-coordinate evidence. For non-generic quantities,
an omitted unit convention is retained as a structural declaration but reported
as insufficient evidence for physical scaling or tolerance interpretation.
When maps make several terminal declarations share an MOI variable, their
quantity, representation, and unit conventions must agree. A disagreement is
reported as representational metadata conflict before any numerical scaling or
nullspace interpretation is attempted.
Component-coordinate and mapped port-coordinate declarations are checked across
the same bridge as well. This prevents a plugin from labelling a model variable
as, for example, an angle at component level and a voltage at terminal level
without an explicit transformed-coordinate convention.
Only ports incident to at least one declared connection contribute topology
candidates: an isolated port is reported structurally, but its unconstrained
terminal coordinates are not silently treated as an expected model gauge.
Terminal-space `PortNullspaceMode` declarations can also be projected through
their matching coordinate map as `component_port_candidate_mode_*` candidates.
Mode-space declarations are kept at port level until a plugin explicitly adds a
mode-to-variable convention.
When component and connected-topology candidates coincide in model coordinates,
combined analysis reports the overlap explicitly. This prevents provenance-rich
metadata from being mistaken for multiple independent expected freedoms.
The same candidate declarations are also screened against the selected active
Jacobian. This makes it explicit when active bounds or inequalities remove a
topology candidate, without conflating that local result with generic LICQ or
physical feasibility claims.
Model-aware reduced-Hessian persistence analysis also includes these candidates
when it compares a persistent flat subspace with declared expected modes. This
is still a cross-point numerical alignment screen, not a conclusion that a
topology declaration explains second-order degeneracy.
Combined analysis records `component_metadata_count` and reports
`duplicate_component_metadata` when a plugin supplies the same component type
and ID more than once. It also reports malformed empty identities or units and
negative expected ranks, even if a plugin bypassed the public convenience
constructor. These are representational facts, not claims about the model's
physical feasibility. When a component declares its variable scope, combined
analysis also validates that the coordinates and constraints exist in the
analyzed model and that its expected rank cannot exceed either declared scope
dimension. At an explicit evaluation point, `analyze_component_ranks` aligns
both scopes to the evaluated Jacobian and reports an expected-versus-observed
rank mismatch as numerical evidence with representational interpretation. It
does not assign a physical cause to that mismatch.
Plugins may separately declare `component_coordinate_semantics(model)` with
`ComponentCoordinateSemantics` records. These label selected model coordinates
as voltage, current, power, angle, or generic quantities, with an explicit
representation and unit convention. Combined analysis checks that the declared
variables exist and, when matching `ComponentMetadata` supplies a nonempty
variable scope, that one such scope covers the semantics declaration. This is a
representational consistency check—not evidence that the coordinates have the
claimed physical meaning. Missing units for non-generic quantities are reported
as insufficient evidence for physical scaling and tolerance interpretation.
If several declarations share a model coordinate but disagree on quantity,
representation, or units, combined analysis reports a representational conflict
before any physical scaling interpretation is attempted. Identical declarations
may intentionally share a coordinate; differing declarations require an
explicit transformed-coordinate model or a plugin-level explanation.

## Auxiliary-feasibility boundary

`elastic_feasibility_plan(model)` is the first non-mutating auxiliary-model
slice. It identifies `Float64` scalar-affine, scalar-quadratic, and scalar-nonlinear `<=`, `>=`, and `==` rows eligible for a
future elastic relaxation and retains all other non-variable constraints as
explicitly unsupported. It never changes or solves the source model. A later
`build_elastic_feasibility_model(model)` now constructs that separate initial
auxiliary model for `Float64` scalar-affine, scalar-quadratic, and scalar-nonlinear rows, using one slack for one-sided
rows and two for equalities; its objective is the sum of slacks. Unsupported
constraints are copied unchanged rather than silently relaxed. Optional,
positive per-source-row weights make the auxiliary objective a weighted slack
sum without changing the original model. Scalar variable bounds remain fixed
by default; `relax_variable_bounds = true` opts them into the same explicit
elastic treatment.
The auxiliary objective can be weighted L1 (`objective_norm = :l1`) or weighted
L∞ (`:linf`), with the latter retaining an explicit epigraph variable.
`elastic_objective_value` evaluates the configured objective from explicit
mapped slack values, without requiring a solver result; it also accepts a
solved auxiliary record and selected result index.
`VectorOfVariables` and vector-affine second-order and rotated-second-order
cones are also supported by adding one nonnegative slack to the leading cone
coordinate. For rotated cones this is a conservative relaxation construction,
not a canonical cone-distance measure. Other coupled/vector sets remain
explicitly unsupported.
`Nonnegatives` and `Nonpositives` vector rows are relaxed coordinatewise with
one nonnegative auxiliary slack per output coordinate and the appropriate
inequality direction.
`Zeros` vector rows use a positive/negative slack pair per coordinate.
Every supplied elastic weight must match a row in the selected plan; unknown
or stale references are rejected rather than silently ignored.
The plan also records the exact auxiliary slack count before a separate model
is built: one slack for scalar one-sided rows, two for scalar equalities, and
the corresponding per-coordinate construction for separable vector sets.
`selected_constraints` can limit an auxiliary probe to specific eligible rows;
the plan records other eligible rows as excluded, making a local experiment
visibly different from a full-model restoration attempt.
`analyze_elastic_feasibility_plan` reports unsupported and excluded rows before
an auxiliary model is built, so coverage limits remain explicit in reports.
The built auxiliary record includes an explicit source-to-auxiliary variable
map and source-to-relaxed-constraint map; callers never need to assume that
copied variable or replacement-constraint indices were preserved.
`solve_elastic_feasibility!` requires an explicitly supplied empty optimizer,
copies only the auxiliary model into it, and retains the auxiliary-to-solver
slack map. It never modifies or solves the source model. The same
`analyze_elastic_relaxations` interface accepts the resulting solve record and
maps its selected result back to source-row findings, retaining optimizer type
and result index as report provenance. Public solver termination and primal
status are retained as observations, not upgraded into feasibility certificates.
Solved reports also retain both the solver-reported and mapped-slack-recomputed
auxiliary objective when available; any interpretation of a discrepancy remains
solver- and formulation-dependent. A material mismatch is reported as
representational numerical evidence with an explicit agreement tolerance, not
as a solver-error claim.
`elastic_relaxation_values` and `analyze_elastic_relaxations` map explicitly
supplied solved slack values back to source rows. A positive slack is auxiliary
numerical evidence, never an IIS certificate or a single-row causal proof.
They retain both raw slack and weighted slack magnitude so a large penalty is
not mistaken for a large underlying relaxation; for L∞ the magnitude is not an
additive per-row objective contribution.
`local_elastic_subset_search` is an opt-in, greedy deletion filter over an
explicitly supplied relaxation scope and an explicitly supplied optimizer
factory. It rebuilds and solves separate auxiliary models only; it never
modifies the source. A row is removed only when hardening it still gives a
readable auxiliary primal result with objective no greater than the selected
tolerance. Its retained rows are deliberately reported as a local,
order-dependent IIS-like explanation, never as an IIS certificate or an
individual causal proof. Solver statuses are retained as provenance, while a
missing readable trial primal result conservatively prevents removal.
`local_elastic_subset_ensemble` addresses the deletion-order limitation without
hiding it. By default it runs forward and reverse orders; callers may supply
additional permutations. Its report separates rows retained in every order
(consensus local evidence) from rows retained only in some orders
(order-sensitive evidence). Neither is an IIS certificate, and both preserve
their dependence on the selected scope, weights, tolerance, and solver.
`minimum_elastic_relaxation_search` is a separate bounded enumeration of
relaxation scopes in increasing cardinality. It reports zero-residual supports
at the first successful cardinality as minimum elastic relaxation supports—not
IISes—and makes its subset budget explicit. An exhausted budget produces a
truncation finding rather than a cardinality-minimality claim.
`compute_solver_conflict!` is the optional MOI conflict boundary. It copies the
source model into an explicitly supplied empty optimizer, optionally solves the
copy, calls `MOI.compute_conflict!`, and maps solver memberships back to source
constraints. Conflict status, definite memberships, and `MAYBE_IN_CONFLICT`
memberships are retained separately. This is solver-provided evidence for the
copied model, not an independently verified IIS, infeasibility proof, or
physical diagnosis; unsupported conflict interfaces are reported explicitly.
`analyze_solver_conflict_crosscheck` compares definite solver memberships with
one local elastic reduction, an order-consensus set, or bounded minimum
relaxation supports. It reports overlap as stronger prioritization evidence and
different memberships as diagnostic context. It deliberately does not choose a
winner: the mechanisms use different auxiliary constructions and neither
becomes ground truth by disagreement alone.
`elastic_domain_guard_plan` is the corresponding pre-solve boundary for
nonlinear operator domains. It reuses the static domain analysis, restricted to
the selected elastic rows, and makes each condition inspectable before any
guarded formulation is constructed. It currently recognizes when a direct
scalar-affine argument to `log`, `log1p`, `log2`, `log10`, `log1mexp`, or
`sqrt` could be given an explicit one-sided domain guard. Other operators and
non-affine arguments remain visible as nonmaterializable rather than being
silently approximated.
An elastic residual relaxation never, by itself, makes an undefined nonlinear
operator evaluable.
`build_elastic_feasibility_model(...; domain_guard_margin = ε)` is the
explicit opt-in construction step. With finite `ε > 0`, it adds guards for
materializable `log`/`log1p`/`log1mexp` arguments before the separate auxiliary
model is solved; `sqrt` receives its closed value-domain guard. `log1mexp`
uses the strict upper guard `x ≤ -ε`. It also guards
reciprocals, division denominators, and negative-integer powers only when the
declared interval confines the argument to one sign branch. Guards are emitted
as scalar-affine rows, rather than replacement variable bounds, so they do not
collide with MOI's one-bound-per-side representation. This deliberately changes
the auxiliary feasible region, so the applied guards and margin are retained on
the auxiliary record and in elastic report metadata. The default is still
unguarded, preserving prior mathematics and requiring the caller to make that
modeling choice visibly.
`logdiffexp(a, b)` is represented as one relational guard, rather than two
independent argument bounds. When both arguments are scalar affine, the
auxiliary model materializes its strict domain as `a - b ≥ ε`; otherwise it
remains visible but nonmaterializable.
Closed inverse-trigonometric input intervals and the one-interval `acosh` /
`atanh` domains are also materialized when their arguments are scalar affine;
`atanh` uses two strict guard rows. Periodic singularity avoidance and other
genuinely multi-branch domains remain nonmaterializable in the generic core,
except for endpoint-safe intervals: when a finite declared interval ends at one
identified `tan`/`sec`/`cot`/`csc` singularity (including degree variants), an
explicit margin moves only that endpoint inward. Intervals crossing a
singularity or containing multiple branches remain visible but unmaterialized.
`stable_reformulation_plan` is a separate, non-mutating companion to numerical
fingerprinting. It turns exact-real-semantics composition fingerprints into
inspectable candidates: `log(1+x)` or `log(1-x)` to `log1p`, `exp(x)-1` to `expm1`,
`log(exp(x))` to `x`, `log(1-exp(x))` or `log1p(-exp(x))` to a branch-aware `log1mexp`, and
`log(exp(a)-exp(b))` to a branch-aware `logdiffexp`, and
softplus/logistic and complementary-logistic/`log(cosh(x))`/multi-term log-sum-exp composites to stable
registered operators. It never rewrites a model. The `log1mexp` candidate retains the real-domain
requirement `x < 0`, and `logdiffexp` retains `a > b`; neither is a domain guard.
Candidates that need `log1pexp`, `log1mexp`, `logcosh`, `logsumexp`, `logdiffexp`, or `logistic` explicitly say that a compatible nonlinear operator must first be registered and tested with the chosen solver stack.
Each relaxation is labeled by its construction (for example scalar upper
bound, equality, SOC, or rotated-SOC) so those different semantics are not
silently conflated in a report.
The same functions can read a solver-reported auxiliary result explicitly by
`result_index`; they refuse to interpret a model with no reported result.

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

`report_data(report)` exposes the schema as renderer-neutral dictionaries:
findings retain their code, four classification axes, observation, rationale,
evidence, suggested actions, and affected entities; report metadata is emitted
with string keys. The core deliberately does not choose a JSON dependency, so
applications may serialize this stable data with their own preferred package.
`findings(report; ...)` and `finding_code_counts(report)` provide the matching
typed query surface for interactive and programmatic consumers.
`markdown_report(report)` provides a deterministic human-facing rendering that
retains every finding's evidence, actions, and affected entities.

## Static-analysis scope

The first implementation intentionally detects exact or canonical facts. It
does not claim algebraic equivalence of arbitrary nonlinear expressions.
Likewise, a disconnected variable means no incidence in the objective or a
non-domain constraint; bounds and integrality alone do not count as incidence.
Recognized exact positive-diagonal circle and ellipsoid geometry, together
with bounded scalar-affine row propagation, can contribute coordinate
intervals to expression-domain propagation. These intervals are mathematical
implications of the source rows, retained only in analysis state; the package
never writes them back to the model. Affine propagation uses a bounded,
order-independent fixed point rather than an unbounded presolver loop.
Direct unary nonlinear rows for supported monotone `log`-, `exp`-, and
`sqrt`-family primitives can likewise be inverted into input intervals,
including the decreasing stable `log1mexp` primitive and open-range logistic
logit/tanh inverse mappings. This does not extend to arbitrary compositions
or non-monotone expressions.
Independently, direct unary rows whose scalar set excludes a primitive's real
output range are reported as mathematical infeasibility proofs. Open endpoints
are retained—for example, logistic outputs never equal zero or one—so valid
closed boundaries such as `cosh(x) = 1` are not misclassified.
Expression-domain and initialization findings retain the corresponding
interval-origin categories and source constraint indices in their evidence, so
derived range conclusions remain inspectable rather than opaque.

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
