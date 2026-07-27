# Development roadmap

This roadmap orders work by the evidence needed for later claims. A numerical
or physical interpretation should not be implemented before the structural and
evaluation layers can expose its supporting evidence.

## Implemented foundation

- Public `MOI.ModelLike` snapshot boundary with optional direct JuMP support.
- Evidence-first findings with independent severity, issue domain, evidence
  basis, and confidence.
- Static checks for bounds, fixed variables, constant constraints, constant
  domain failures, exact duplicate constraints, repeated-expression scalar-set
  intersections, proportional/dominated affine relations, contradictory
  affine half-space/equality combinations, fully fixed and variable-free
  affine/quadratic/nonlinear expressions and objectives with stable and
  extensible primitive evaluation, exact affine/quadratic term-cancellation
  normalization, conditional unconstrained affine/quadratic-objective rays, one-variable implied bounds, bounded multi-variable affine
  interval propagation, sign-resolved absolute values, bound-resolved min/max
  branches, direct absolute/square/square-root zero implications, square-range infeasibility
  proofs, sign-resolved square levels, and disconnected variables.
- Reusable variable-support extraction for scalar and vector MOI functions.
- Variable–constraint bipartite graph with scalar rows for coordinate-wise
  product sets and block vertices for coupled vector sets.
- Exact connected components, including vector-row identity, coupled-set
  semantics, and explicit handling of incomplete function support.
- Explicit free/fixed/parameter/infeasible variable roles and
  equality/inequality/free/coupled/opaque constraint roles.
- Deterministic maximum-cardinality equality matching.
- Unmatched free-variable and equality-node findings.
- Initial under-, well-, and over-determined Dulmage–Mendelsohn partition.
- Irreducible square blocks for the well-determined partition.
- Renderer-neutral structural graph data with deterministic text and Graphviz
  DOT renderers.
- Normalized expression-node paths with objective, constraint, and vector-row
  provenance.
- Conservative interval propagation from declared variable domains.
- Proven and possible domain findings for logarithms, square roots, division,
  inverse, and integer/fractional powers.
- Extension hooks for custom operator ranges and domain requirements.
- Explicit numerical evaluation points with stable MOI variable ordering.
- Capability discovery for symbolic functions, `AbstractNLPEvaluator`, and
  `VectorNonlinearOracle` sources.
- Point-tagged value, objective-gradient, and sparse-Jacobian cache.
- Exception-safe callback probing and non-finite numerical findings.
- Operating-point domain findings distinct from static interval conclusions.
- Jacobian row/column infinity norms, zero sensitivities, and scale-spread
  findings with duplicate sparse entries combined additively.
- Guarded dense-SVD Jacobian rank, conditioning, and left/right nullspace
  estimates with explicit scaling and threshold evidence.
- Sparse nonzero-pattern matching rank upper bounds that can prove some
  large-model local deficiencies without dense factorization.
- Constructed MOI reverse-mode AD for ordinary scalar nonlinear first
  derivatives, with labeled finite-difference fallback.
- Exact callback and labeled finite-difference Hessian-of-the-Lagrangian
  evaluation, plus explicit-active-row reduced-Hessian inertia checks.
- Scalar and coordinate-wise product-bound feasibility margins, explicit
  active-row selection, local LICQ rank checks, and conservative MFCQ
  common-descent witnesses.
- Structural-to-numerical equality-rank comparison that distinguishes expected
  structural rectangular freedom from additional local rank loss.
- Conservative non-unit circular-equality normalization hints for exact
  unshifted isotropic quadratic forms.
- Separate first- and second-derivative domain requirements with custom
  operator extension hooks.
- Inverse trigonometric, hyperbolic, and periodic primitive-domain coverage.
- Floating-point overflow/underflow checks parameterized by numeric type.
- Stable-expression fingerprints for `log1p`, `expm1`, softplus, and logistic
  formulations.
- Complete MOI initialization-point ingestion without implicit default values.
- Initialization bound, value-domain, derivative-domain, non-finite, and
  scaling checks.
- Research profiling matrix derived from unbalanced OPF benchmarking and
  three-phase formulation studies.
- Solver-independent postmortem records that preserve native termination,
  residual, restoration, and iteration evidence for future solver extensions.

## Next: structural refinement

- Separately labeled active-set matching after numerical evaluation, restricted
  to aligned ordinary scalar rows and with unmapped rows kept explicit.
- Replace simple fixed-variable classification with a richer variable-domain
  intersection abstraction for non-`Float64` coefficient types (implemented
  for supported scalar variable-bound sets, including source provenance and
  explicit invalid-domain handling).
- Benchmark the prototype matching and strongly connected-component
  algorithms on large sparse models before treating them as production-scale
  implementations.

## Next: numerical rank and derivative refinement

- Sparse nonzero-pattern rank upper bounds and sparse-QR diagonal-pivot rank
  estimates alongside guarded dense SVD, plus explicit iterative sparse
  candidate right-null-direction and block-subspace probes, plus an explicit
  heuristic spectral-spread probe. Production-scale sparse-conditioning
  estimates and independently certified nullity remain future work.
- Generic SOC and rotated-SOC feasibility/boundary evidence; general coupled-
  set and plugin-supplied active-set semantics.
- Full MFCQ failure certificates; the generic core now has local recovered-
  multiplier sign/complementarity screens and a numerical no-common-descent
  witness for explicitly selected scalar active rows.
- Large-model profiling aggregates beyond timing and diagnostic-code stability
  (implemented for availability-aware numerical rank and sparse-pivot metrics,
  deterministic synthetic sparse calibration corpus and repeated batch harness,
  per-stage allocated-byte summaries, and expected-evidence recovery rates;
  transparent aggregate-to-aggregate formulation comparison including
  availability-aware numerical metrics and declared task context; broader
  memory-footprint and allocation-source attribution remain future work).

## Auxiliary feasibility foundation

The first elastic-feasibility slice is implemented. It creates a separate,
never-solved-by-default auxiliary MOI model that relaxes selected `Float64`
scalar affine, quadratic, and nonlinear rows with explicit nonnegative slacks;
scalar variable bounds are opt-in. Plans retain supported, unsupported, and
excluded rows plus exact slack counts, while auxiliary results map slack values
back to source constraints and distinguish raw from weighted relaxation.

Next auxiliary work:

- wider multi-branch domain handling for remaining nonlinear operators; and
- solver-specific certificate provenance for conflict output.

Solver-managed execution, result-status provenance, weighted L1/L∞ objectives,
and a conservative greedy local subset reduction are implemented. The subset
reduction is intentionally labeled as scope-, order-, and solver-dependent;
it is not an IIS certificate.
An order ensemble now compares forward/reverse or caller-supplied deletion
orders and distinguishes consensus rows from order-sensitive ones.
A bounded exact minimum-cardinality elastic relaxation search is also
implemented, with explicit truncation evidence instead of unbounded
enumeration.
Generic MOI solver-conflict extraction is implemented as an optional copied
model workflow, with source-mapped definite and tentative memberships. It
deliberately reports solver conflict output as evidence rather than proof.
Conflict memberships can now be cross-checked against local, order-consensus,
and minimum-support elastic evidence, retaining both agreement and disagreement.
Nonlinear domain-guard planning is also implemented: it scopes static domain
conditions to elastic rows and distinguishes directly materializable
scalar-affine lower-domain guards from conditions that need a domain plugin or
reformulation. Explicit opt-in guarded auxiliary construction now supports
those materializable `log`/`log1p`/`sqrt` cases plus sign-confined reciprocal,
division, and negative-power domains, and records its chosen margin.
It also handles closed inverse-trigonometric intervals and `acosh`/`atanh`;
the generic core continues to leave periodic and multi-branch domains explicit
rather than choosing a branch, except for a finite interval that ends at one
identified periodic singularity, where it can safely move that endpoint inward.
Stable expression fingerprints now also produce non-mutating reformulation
plans with explicit registration requirements for custom stable primitives.

## Degeneracy framework

Numerical nullspaces are compared with structural results before any
plugin-supplied expected-gauge interpretation. Implemented generic
classifications include structurally expected local nullspaces and unexpected
local rank loss, candidate common-coordinate shifts, and candidate two-row
equation dependencies. Next classifications:

- expected coordinate gauge declarations and observed-nullspace comparison
  (implemented, including declared-span dimension checks);
- active-set nullspace classification beyond compact dependence, uniform
  tangent shifts, and declared-mode span comparisons;
- flat reduced-Hessian direction (available through active-set second-order
  probing); and
- unknown local equality-Jacobian mode (implemented).

PowerModels and multiconductor semantics follow only after these generic
interfaces are stable. The dependency-free plugin boundary and first extension
slice are specified in `docs/powermodels_extension.md`.

## Solver postmortem foundation

`SolverPostmortem` is a solver-neutral record for a solver name, normalized
termination symbol, optional raw status, iteration count, residuals,
complementarity, restoration outcome, and textual metadata.
`analyze_postmortem` turns this into evidence-first findings without claiming
that a solver's termination proves feasibility, infeasibility, optimality, or
a physical cause. Future Ipopt and MadNLP extensions should translate their
native results into this record while retaining the raw status and relevant
metadata.

The Ipopt extension is implemented for a direct `Ipopt.Optimizer` and through
the optional JuMP adapter: it maps Ipopt raw statuses and public MOI result
attributes without parsing logs or depending on optimizer internals. A MadNLP
extension is also implemented with the same evidence-preserving boundary.

Generic raw solver-log evidence is implemented for explicit restoration,
infeasibility, limit, invalid-number, and selected numerical-failure markers.
It retains matching line text and numbers but does not parse solver iteration
tables or make status text into a mathematical certificate. Structured Ipopt
and MadNLP iteration-row parsing is now implemented for complete rows under
recognized headers; final residual and residual-regression findings remain
trace observations rather than KKT certificates. Parsed rows can be
correlated with explicitly supplied evaluation points, and inspectable
log-order iteration summaries retain printed residual minima and phase facts.
Decreasing printed iteration numbers create non-causal trace segments so final
residual regression evidence does not compare across appended runs.

Explicit iteration-point bindings are implemented. They run generic numerical
analysis at caller-supplied points and compare logged primal infeasibility with
recomputed scalar-bound and coupled-set violation, retaining all three values
as metadata; they also compare the logged and recomputed model objectives when
available. Trace-level feasibility and objective disagreement across multiple
bound points is reported conservatively. Future work is solver-specific iterate
capture rather than reconstructing points from raw text.
