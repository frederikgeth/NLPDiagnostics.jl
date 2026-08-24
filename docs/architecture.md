# Architecture

This document records decisions that should remain stable as implementation
details evolve.

The normative package mission and present scope are in
[`mission_and_scope.md`](mission_and_scope.md). The architecture supports two
closely related uses: an evidence-first model debugger and an experimental
measurement platform for numerical-method development.

## Current phase boundary

The project has enough feature breadth to exercise the original vision. Its
current phase is consolidation and calibration, not unrestricted addition of
new finding families. Work should strengthen the following chain:

1. preserve a measurement with explicit provenance and coordinate semantics;
2. compare it with a truth-labelled case or a controlled intervention;
3. state the narrowest interpretation supported by that comparison; and
4. render the evidence needed for another researcher to challenge it.

This leads to three architectural layers that must remain separable:

- measurement artifacts: expressions, points, derivative products, solver
  telemetry, structural graphs, and domain metadata;
- comparison artifacts: tolerances, normalization, reference backends,
  repeated points, and controlled perturbations; and
- diagnostic interpretations: findings whose confidence and issue domain are
  bounded by the first two layers.

A renderer may combine these layers for presentation, but a finding must never
be the only surviving copy of the measurement that produced it.

## Domain component metadata

Optional domain plugins may extend `component_metadata(model)` to return
`ComponentMetadata` records. Each record carries a stable component type and
ID, optional variable-coordinate and constraint scopes, optional units, optional
expected rank, and serializable metadata. The
generic core does not infer these semantics from variable names. A future
PowerModels extension should use this hook with `expected_nullspace_modes` to
declare electrical references, ports, and expected physical gauges.
`component_rank_capability_report(components)` makes the declaration boundary
explicit before any numerical comparison: it reports declared, unavailable,
and coverage counts and emits an informational representational finding only
for components without an expected rank.
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

Generic equality-Jacobian nullspace fingerprints also report concentrated local
right-null directions. A single-coordinate direction identifies a coordinate
that is locally free to first order; a compact multi-coordinate direction
localizes a small affected subsystem. Both are heuristic numerical evidence,
not a diagnosis of a missing equation, a physical gauge, or a physical mode.
They complement, rather than replace, expected-mode declarations and
component-rank metadata.

`analyze_jacobian_rank_persistence` provides the analogous explicit
cross-point screen for first-order geometry. It requires callers to supply
evaluations with identical ordered variables and scalar constraint rows, then
compares rank and, when present, the right-nullspace using principal-angle
alignment. A persistent local nullspace is still numerical evidence rather
than proof of a physical gauge; a changing rank or span is evidence against
treating a one-point mode as persistent.
The model-and-points convenience method evaluates only the caller-supplied
points; it never perturbs, generates, or writes an initialization.
Initialization analysis runs the same generic first-order degeneracy comparison
at a complete supplied start by default. This makes stationary derivative loss
and localized nullspace fingerprints visible before a solve; callers can turn
that screen off explicitly when only domain, feasibility, and active-set
evidence is wanted.
The same pass can compare optional plugin-supplied component expected ranks
with the start-point Jacobian. A mismatch remains local numerical evidence with
representational context; it is not an assertion that a component's physical
model is invalid.
`analyze_component_rank_persistence` extends that comparison across explicitly
supplied evaluations. It separates changing component rank from persistent
agreement or persistent mismatch with a declaration, while retaining the
component scope, labels, ranks, and tolerance as evidence. When the declaration
implies component-local right-nullity, it also compares the local nullspace
subspaces using principal-angle alignment. Persistent local geometry still does
not identify a physical mode without domain metadata. Optional expected-mode
declarations whose coordinates lie entirely in that component scope can be
tested against the persistent local subspace, preserving every point's
projection residual instead of inferring a mode from component names.
Optional `ExpectedNullspaceMode` declarations are tested against every
available persistent subspace, retaining all projection residuals. This
supports a plugin's expectation without silently turning it into a physical
certificate.
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
Where a map row contains exactly one terminal coordinate, a port nominal scale
is adjusted by that map coefficient and compared with component-coordinate
nominal scales on the same model variable. A scale omitted on either side, or
an incompatible explicit scale, is a representational scale conflict; mixed
coordinate maps remain explicitly outside this generic scalar comparison.
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
rank mismatch as numerical evidence with representational interpretation. When
the declared rank deliberately leaves local coordinate freedom, it separately
reports the matching right-nullity as an informational observation. That only
confirms the declared local dimension: it does not identify a physical mode,
prove a network-wide gauge, or assign a physical cause to either outcome.
Plugins may separately declare `component_coordinate_semantics(model)` with
`ComponentCoordinateSemantics` records. These label selected model coordinates
as voltage, current, power, angle, or generic quantities, with an explicit
representation and unit convention. Combined analysis checks that the declared
variables exist and, when matching `ComponentMetadata` supplies a nonempty
variable scope, that one such scope covers the semantics declaration. This is a
representational consistency check—not evidence that the coordinates have the
claimed physical meaning. Missing units for non-generic quantities are reported
as insufficient evidence for physical scaling and tolerance interpretation.
Plugins may additionally declare a positive `nominal_scale` on
`ComponentCoordinateSemantics`. `analyze_component_coordinate_scales` compares
that declaration with an explicit point and reports a large nonzero
value-to-scale mismatch as local numerical evidence; it never infers a scale
from a unit label or classifies a zero coordinate as physically anomalous.
The prior positional `ComponentCoordinateSemantics` construction remains
compatible and leaves `nominal_scale` unset.
`analyze_numerical` includes this check automatically whenever a plugin has
declared nominal scales, with an explicit configurable mismatch factor.
Compatible overlapping declarations at one model coordinate are consolidated
into one point-local scale finding, with every contributing component retained
as evidence; conflicting scales remain separately visible as metadata issues.
If several declarations share a model coordinate but disagree on quantity,
representation, units, or nominal scale, combined analysis reports a representational conflict
before any physical scaling interpretation is attempted. Identical declarations
may intentionally share a coordinate; differing declarations require an
explicit transformed-coordinate model or a plugin-level explanation.

## Planned constraint-residual scale boundary

Variable-coordinate scales alone cannot give solver-tolerance semantics: a
constraint function value is not generally its feasibility residual. The
`ComponentConstraintScaleSemantics` API therefore declares a positive nominal *residual* scale
against explicit scalar constraint-row references, rather than infer one from
the constraint's units or function expression. The generic core must first
compute the signed/equality residual with respect to the MOI set, then compare
that residual with the declared scale through
`analyze_component_constraint_scales`.
Declarations accept only ordinary MOI `:constraint` and evaluator-provided
`:nlp_constraint` source references; variables and unrelated entities are
rejected at construction time.

The initial slice supports only rows whose scalar residual semantics are
already explicit in MOI (`EqualTo`, `LessThan`, `GreaterThan`, and interval
rows). Coupled cone residuals and transformed multi-row norms must remain
unavailable until their geometry-specific residual convention is declared. It
is exposed through `component_constraint_scale_semantics(model)` and included
automatically by numerical analysis. Scope validation beyond evaluation-row
alignment remains future work.
`analyze_component_constraint_scales(model, evaluation)` is the public
combined entry point: it joins scalar, coupled, and snapshot-scope evidence
without requiring a plugin to assemble summaries itself.
`analyze_component_constraint_scales(model, point)` evaluates the point first
and has the same non-mutating behavior; a model with no declarations reports
zero evidence rather than failing.
Combined reports retain both the count of declarations and the count of source
rows referenced by those declarations, so absent metadata is distinguishable
from a multi-row declaration that happened not to trigger a finding.
Residual-scale reports separately count stale source references, aligned rows
without an available scalar residual, and (for coupled sets) unsupported
geometry. These are representational coverage limits, not feasibility claims.
Coupled reports also retain the count of declarations aligned with a supported
generic geometry, including rows whose margin exists but is numerically
unavailable.
Active-set analysis additionally supports the generic feasibility margins for
second-order, rotated-second-order, and norm-family cones. Other coupled-set
geometries remain unavailable until their residual conventions are explicit.
The same report is included by standalone coupled-set qualification analysis.
Coverage also includes PSD, power, exponential, geometric-mean,
relative-entropy, log-determinant, and root-determinant margins whenever the
generic coupled feasibility layer supplies a finite violation.
This preserves the distinction between a numerical observation, a plugin's
physical scaling convention, and a solver's own tolerance semantics.

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
coordinate. The same leading-coordinate construction supports norm-one,
norm-infinity, generic norm, spectral-norm, and nuclear-norm epigraph cones.
Packed log- and root-determinant cones receive a hypograph shift instead:
the slack is subtracted from their leading `t` coordinate. This repairs only
the scalar determinant inequality; strict positive-definite domain failures
remain explicit and unrelaxed. Their scaled packed variants are supported by
the same construction. The auxiliary model uses MOI's solver-free
`UniversalFallback` container so supported public scaled representations are
preserved during copying. Square-form log- and root-determinant cones use the
same `t - s` hypograph shift, preserving their embedded symmetry equations.
For rotated cones this is a conservative relaxation construction, not a
canonical cone-distance measure. Packed real PSD cones are supported by
one nonnegative spectral-shift slack added to every diagonal coordinate,
corresponding to `X + sI ⪰ 0`. This is an interpretable uniform eigenvalue
repair, not a canonical cone-distance measure. The same construction supports
scaled packed real PSD coordinates because their diagonal entries are not
scaled, and square PSD coordinates by shifting only matrix diagonal entries.
Other coupled/vector sets remain explicitly unsupported.
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
`analyze_elastic_feasibility_plan(model)` is a non-mutating convenience entry
point for the coverage report; callers that need to retain or edit the exact
scope can still create `elastic_feasibility_plan(model)` explicitly.
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
The result also records the copied source variable and constraint counts, so
conflict findings retain their model-scope provenance without depending on
copied solver indices.
`analyze_solver_conflict_crosscheck` compares definite solver memberships with
one local elastic reduction, an order-consensus set, or bounded minimum
relaxation supports. It reports overlap as stronger prioritization evidence and
different memberships as diagnostic context. It deliberately does not choose a
winner: the mechanisms use different auxiliary constructions and neither
becomes ground truth by disagreement alone.
For supported vector cones, the auxiliary uses only monotone coordinate shifts
whose effect is explicit in the native cone representation: SOC and norm cones
receive an epigraph shift; exponential and dual-exponential cones receive a
shift in their third (epigraph) coordinate; relative entropy receives a shift
in its leading upper-bound coordinate; and geometric mean receives a negative
shift in its leading hypograph coordinate. These shifts do not relax the
strict positive coordinates required by exponential or relative-entropy
semantics. Packed real and Hermitian PSD cones (including their scaled packed
representations) receive the spectral shift `X + sI`; imaginary coordinates
remain unchanged. A power cone receives `x+s, y+s, z`; its dual receives
`u+αs, v+(1-α)s, w`, so the two normalized positive coordinates grow by the
same slack. These are explicit auxiliary geometries, not a scale-invariant
distance to the cone. Other cones whose safe generic relaxation would require
a branch or a non-coordinate reformulation remain unsupported.
Whenever a solved or caller-populated elastic auxiliary has positive slack,
`analyze_elastic_relaxations` records this geometry alongside the raw and
weighted slack. This keeps “which row moved” separate from “which coordinate
or matrix direction was expanded.”
`elastic_domain_guard_plan` is the corresponding pre-solve boundary for
nonlinear operator domains. It reuses the static domain analysis, restricted to
the selected elastic rows, and makes each condition inspectable before any
guarded formulation is constructed. It currently recognizes when a direct
scalar-affine argument to `log`, `log1p`, `log2`, `log10`, `log1mexp`, or
`sqrt` could be given an explicit one-sided domain guard. Other operators and
non-affine arguments remain visible as nonmaterializable rather than being
silently approximated.
`analyze_elastic_domain_guard_plan(model)` provides the same pre-solve report
in one non-mutating call; the explicit plan remains available for callers that
need to inspect or retain individual guard records.
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
Branch-confined `asech`, `acsch`, `acoth`, `asec`, and `acsc` domains are also
materialized when the declared interval already identifies the admissible
branch; the generic builder never splits or selects a branch for a crossing
interval.
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
`findings(report; ...)`, `finding_code_counts(report)`, and
`finding_family_data(report)` provide the matching typed query surface for
interactive and programmatic consumers. `report_data(report)["findings"]`
continues to contain every per-entity record; the additive
`report_data(report)["finding_families"]` collection is a compact summary keyed
by finding code and classification for renderers that need to aggregate
repetitive findings.
`markdown_report(report)` provides a deterministic human-facing rendering that
retains every finding's evidence, actions, and affected entities.
The terminal-oriented `text_report(report)` and the default `text/plain`
renderer show errors and warnings individually, summarize informational
families, and report any explicit `maximum_findings` truncation. They do not
alter the report or its renderer-neutral data.

The top-level `analyze` entry point accepts additive `RankPolicy`,
`ProbePolicy`, and `CheckPolicy` objects. `RankPolicy` groups dense numerical
rank semantics, `ProbePolicy` groups opt-in probe selectors, and `CheckPolicy`
groups top-level boolean checks. Existing keyword arguments remain supported;
policy selectors are recorded in report metadata and provide the grouped
selection layer, so migration can be incremental.

`check_objective_jacobian_scaling=true` adds a point-local comparison of the
finite objective-gradient magnitude against the positive Jacobian column-scale
range. It reports unavailable evidence when either derivative side is
incomplete and does not make a global conditioning or solver-performance
claim.

`check_convexity=true` adds a point-local full-Hessian inertia screen. The
convenience path evaluates the objective Hessian with zero constraint
multipliers, records the positive/negative/near-zero eigenvalue counts, and
preserves unavailable evidence when a complete spectrum cannot be formed. The
result is a curvature observation at the supplied point, not a global
convexity or second-order optimality certificate; use
`analyze_reduced_hessian` or `analyze_active_set_second_order` when an explicit
tangent space and multiplier convention are part of the question.

`check_degrees_of_freedom=true` adds a bounded local first-order freedom
screen. It compares structural equality matching with observed numerical
Jacobian right-nullity in the aligned free-variable view. The result reports
structural and local counts, but does not claim the dimension of a global
feasible set or assign physical meaning to a null direction; inequalities,
bounds, nonlinear manifold geometry, and domain semantics require separate
evidence.

`analyze_nonsmoothness_persistence` and
`analyze_weak_activity_persistence` compare these point-local screens across
explicitly supplied evaluations or points. They require a stable ordered
variable/row scope and preserve changing, persistent, and unavailable states;
repeated evidence still does not become a global smoothness or active-set
certificate.

`check_nonsmoothness=true` adds bounded central-difference directional checks
for the recorded objective gradient and/or Jacobian. A mismatch is classified
as possible nonsmoothness or derivative inconsistency, because finite-
difference error, domain crossings, and implementation defects remain viable
explanations. A consistent result is local evidence only.

`check_weak_activity=true` adds an explicit proximity band above the active
tolerance for supported scalar inequality rows. It reports rows that are
near, but not classified active, and does not infer multipliers, KKT status, or
activity for opaque sets.

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
logit/tanh inverse mappings, stable softplus inversion, and inverse-hyperbolic
pairs, plus the globally monotone `atan`/`tan` pair. This does not extend to
arbitrary compositions or non-monotone expressions.
The same direct-row inversion covers increasing `asin`/`asind`/`atand` and
decreasing `acos`/`acosd`, with radian and degree output ranges kept separate.
`sinh` and real `cbrt` rows are likewise inverted monotonically, including
across negative values for the odd cube-root map.
Expression-node interval evaluation also covers monotone hyperbolic and
inverse-hyperbolic primitives, while `cosh` and `logcosh` retain their
zero-aware non-monotone enclosures.
It also propagates scalar `min`/`max`, `sign`, and `cbrt` ranges, so downstream
domain checks can retain the effect of common piecewise modeling primitives.
Direct `sign` rows additionally use its discrete codomain `{−1, 0, 1}` to
prove impossible row sets and to expose the exact fixing implied by `sign(x)=0`.
Bounded logistic inputs retain stable finite output endpoints, enabling nested
domain checks such as `log(logistic(x))` without overflow-based widening.
For finite, numerically moderate phase intervals shorter than one period,
`sin`/`cos` and their degree variants retain endpoint and interior-extremum
ranges; wider or huge-angle intervals deliberately widen to `[-1, 1]`.
`tan`/`tand` retain an endpoint range only when the whole phase interval avoids
their periodic poles; an interval containing a pole is intentionally widened.
The reciprocal trigonometric aliases `sec`, `csc`, and `cot` (including degree
variants) reuse those validated sine/cosine enclosures and retain a finite range
only when the corresponding denominator is proven nonzero.
Their inverse aliases `asec` and `acsc` likewise propagate intervals only when
the input is confined to one real-domain branch (`x ≤ -1` or `x ≥ 1`), avoiding
an unjustified monotonicity claim across the excluded central interval.
The same one-branch principle applies to reciprocal hyperbolic aliases
(`sech`/`csch`/`coth` and `asech`/`acsch`/`acoth`), preserving singular-domain
evidence rather than guessing across zero or the inverse-hyperbolic boundaries.
In particular, `csch` and `coth` now declare zero as both a value-domain and
finite-derivative singularity, rather than relying on an opaque fallback.
Their disconnected real output ranges also support exact static infeasibility
proofs when a scalar row excludes every attainable value.
The bounded `sech` range `(0, 1]` is retained with its open lower endpoint, so
the static layer distinguishes unattainable zero from the valid maximum one.
The reciprocal trigonometric layer similarly distinguishes the split
`sec`/`csc` output range `(-∞, -1] ∪ [1, ∞)` and the excluded zero in the
`acsc` output range; its findings are mathematical proofs rather than sampled
domain warnings.
Exact endpoint equalities for `asin`/`acos`, `asec`/`acsc`, and their degree
variants also expose the unique implied argument value as an explicit
fixed-variable finding, without rewriting the source model. That implied value
is cross-checked against effective scalar bounds, producing a separate
infeasibility proof when an endpoint preimage is excluded.
The same evidence-first treatment covers unique hyperbolic zero and extremal
preimages, including `sinh`/`tanh` zero, `cosh`/`sech` extrema, and the zero
endpoints of `acosh` and `asech`.
Exact elementary reference-level equations likewise expose hidden fixed values:
`exp(x)=1`, `log(x)=0`, `log1p(x)=0`, `expm1(x)=0`, `logistic(x)=0.5`, and
`cbrt(x)=0` all receive bound-aware mathematical-proof findings.
The numerically stable softplus spellings `softplus`, `log1pexp`, and
`log1exp` receive the same exact `log(2)` reference-level inference, while
`log1mexp(x)=-log(2)` identifies `x=-log(2)`.
Their near-zero numerical fingerprints use the reciprocal leading behavior to
make derivative-amplification risk visible before an exact domain failure.
`acoth` receives the same finite-derivative boundary fingerprint as `atanh`,
but on the exterior branches approaching ±1.
`asech` and `acsch` also expose their near-zero inverse-power derivative
amplification while remaining value-domain valid at small nonzero arguments.
One deliberately supported non-monotone case is a direct `abs(x)` row with a
finite nonnegative upper set bound, which exactly implies the connected input
interval `-u ≤ x ≤ u`; disjunctive lower-range implications remain explicit.
The same connected-range treatment applies to `cosh(x) ≤ u` for `u ≥ 1`,
giving `|x| ≤ acosh(u)` without choosing a sign branch.
For the stable `logcosh(x)` primitive, a finite nonnegative upper row yields
the same kind of interval through a cancellation- and overflow-safe evaluation
of `acosh(exp(u))`.
Independently, direct unary rows whose scalar set excludes a primitive's real
output range are reported as mathematical infeasibility proofs. Open endpoints
are retained—for example, logistic outputs never equal zero or one—so valid
closed boundaries such as `cosh(x) = 1` are not misclassified. This includes
the radian and degree inverse-trigonometric primitives, whose different output
units and endpoint conventions are kept explicit.
Expression-domain and initialization findings retain the corresponding
interval-origin categories and source constraint indices in their evidence, so
derived range conclusions remain inspectable rather than opaque.
`domain_interval_data(model)` exposes the complete renderer-neutral set of
analysis-only coordinate intervals, including validity, informativeness, and
the same provenance, when an application needs to inspect safe implications
that did not themselves trigger a finding.
The static expression layer also flags `atan(y / x)` as a heuristic
representation fingerprint when a quadrant-aware angle may have been intended;
it recommends inspecting `atan(y, x)` support and never rewrites the model.
When the ratio denominator's static enclosure contains zero, a separate
high-confidence numerical-risk finding makes the undefined-ratio and
unbounded-derivative hazard explicit; a nonzero denominator margin suppresses
that risk finding without suppressing the representational `atan2` advice.
The two-argument form is also checked for the principal-angle branch cut
`y = 0, x < 0`: this is a representational continuity warning distinct from
the joint-origin derivative singularity.
Its Julia principal output range is additionally retained as `(-π, π]`, so a
row requiring exactly `-π` receives a mathematical infeasibility proof while
the valid `π` endpoint remains accepted.
Exact principal-axis rows at `0`, `±π/2`, and `π` also expose their implied
zero coordinate and remaining-axis sign condition as fixed-variable evidence;
the implied zero is cross-checked against declared scalar bounds for an
additional infeasibility proof, and the remaining coordinate's required axis
sign is checked too.
The two-argument Julia form is separately constant-folded and given the
conservative full-angle range `[-π, π]`; its derivative check independently
identifies the joint `(y, x) = (0, 0)` singularity.

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
   scale, and evaluation point. **Implemented with guarded dense SVD,
   sparse-pattern and sparse-QR complements, scaling comparisons, and
   inspectable left/right nullspace evidence where dense analysis is safe.**
6. Separate primitive value domains, finite derivative domains, and
   floating-point range/fingerprint risks. **Initial implementation complete.**
7. Compare observed nullspaces with expected gauges supplied by plugins.
   **Implemented through expected-nullspace mode declarations, declared-span
   checks, and port-topology candidate modes; a future
   `DegeneracyHypothesis` object may package these evidence sources without
   changing their semantics.**

PowerModels and multiconductor semantics should begin only after these generic
interfaces have tests and extension points.

## Cone-aware qualification boundary

Scalar LICQ and MFCQ use selected scalar rows only. A supported smooth coupled
cone boundary (including SOC, vector-norm, simple-leading-mode spectral-norm,
full-rank nuclear-norm, and simple-zero-mode packed PSD boundaries) instead
supplies an output-space normal which can be mapped through the vector-function
Jacobian. That mapped gradient is useful local geometry, but it must not be
silently inserted into scalar row selection, multiplier recovery, or MFCQ
witnesses.

A cone-aware qualification screen implements a Robinson-style constraint
qualification for smooth conic mappings. It accepts explicit
`CoupledSetTangentEvidence` values and evaluates a separately labeled tangent
system. Its evidence retains the coupled-set source, ordered vector rows,
normal, mapped-gradient derivative provenance, and the distinction between a
smooth boundary, SOC apex, and rotated-SOC axis.
The reusable `CoupledSetMappedTangent` boundary is implemented: it retains a
smooth source, ordered vector rows, model-coordinate gradient, and derivative
methods only when the mapping is complete and finite. The Robinson-CQ screen
consumes these records rather than reconstructing Jacobian geometry from report
text: it uses a minimum-norm convex-hull screen on smooth mapped normals and
checks the resulting common descent direction. It remains a separately labeled
local inference and leaves scalar LICQ/MFCQ unchanged.
