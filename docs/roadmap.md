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
- Conservative circular/ellipsoidal equality analysis for exact positive
  diagonal quadratic forms (including affine shifts): proven negative- and
  zero-level consequences, plus configurable non-unit radius and semiaxis
  normalization hints; exact upper bounds below (or equal to) a positive
  diagonal quadratic minimum also produce infeasibility (or implicit-fixing)
  proofs, while higher finite upper levels yield per-coordinate implied bounds.
  Those implied bounds are cross-checked against declared scalar bounds for
  additional infeasibility proofs, including exact-minimum and zero-radius
  implied centers, and zero-level diagonal ellipsoid centers.
  Positive-radius circular equalities also yield exact coordinate intervals
  and scalar-bound conflict proofs; the same holds for positive-level
  diagonal ellipsoidal equalities.
  Zero-radius and zero-level equalities also report their exact nonregular
  implicit-fixing geometry, so singular local Jacobians are not mistaken for
  free coordinates. Minimum-level positive-diagonal upper bounds likewise
  report their zero-gradient active-inequality nonregularity.
  The same upper-bound implications apply to
  recognized nonlinear positive-diagonal expressions. The circular slice also recognizes the
  exact positive diagonal `sum(aᵢ*xᵢ^2 + bᵢ*xᵢ) + c == d`
  nonlinear-expression spelling, including isotropic-circle and ellipsoid
  cases, so this evidence is not restricted to MOI quadratic-function
  representation. Cross terms remain deliberately unclassified by this exact
  positive-diagonal slice.
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
  implementations. A deterministic sparse calibration ladder now provides the
  repeatable harness; collecting and interpreting large-machine observations
  remains future work.

## Next: numerical rank and derivative refinement

The explicit constraint-residual scaling foundation is implemented. Plugins
declare nominal scales on scalar or supported coupled residual sources; the
core compares set-relative violations rather than raw function values, validates
ordinary sources structurally, retains evaluator NLP sources as runtime-only,
and reports coverage limits. Supported coupled margins include SOC, norm, PSD,
power, exponential, geometric-mean, relative-entropy, log-determinant, and
root-determinant families. Plugin-supplied residual conventions remain future
work for coupled geometries outside this generic coverage.

- Sparse nonzero-pattern rank upper bounds and sparse-QR diagonal-pivot rank
  estimates alongside guarded dense SVD, plus explicit iterative sparse
  candidate right-null-direction and block-subspace probes, plus an explicit
  heuristic spectral-spread probe. Production-scale sparse-conditioning
  estimates and independently certified nullity remain future work.
- Generic conic feasibility/boundary evidence for SOC, rotated SOC, vector
  norm, spectral-norm, nuclear-norm, real/Hermitian/scaled packed and square PSD feasibility, including scaled Hermitian coordinates, plus packed/square and scaled packed log-/root-determinant, power, exponential, geometric-mean, and
  relative-entropy cones, including explicit nonsmooth apex, axis, tie, and
  repeated-leading-singular-value labels plus smooth-boundary tangent hooks;
  smooth normals can be mapped through complete vector-function Jacobians for
  cone-aware local evidence. A separately labeled Robinson-style qualification
  screen now uses complete smooth mapped normals and a checked convex-hull
  common-descent witness; it does not change scalar LICQ/MFCQ or multiplier
  semantics. General coupled-set and plugin-supplied active-set semantics
  remain future work.
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
scalar variable bounds are opt-in. It also has conservative SOC/rotated-SOC
and norm-epigraph, power-coordinate, exponential/relative-entropy epigraph,
and geometric-mean hypograph leading-coordinate shifts plus packed real/Hermitian-PSD spectral
shifts (including scaled packed and square real PSD), together with packed
log-/root-determinant hypograph shifts that do
not relax their strict matrix domain. Plans retain supported, unsupported, and
excluded rows plus exact slack counts, while auxiliary results map slack values
back to source constraints and distinguish raw from weighted relaxation.

Next auxiliary work:

- wider multi-branch domain handling for remaining nonlinear operators; and
- solver-specific certificate provenance for conflict output.

Branch-sensitive guards are now explicitly reported when a generic guard would
have to select one of multiple admissible branches (for example, reciprocal or
inverse-hyperbolic domains crossing zero). The core records this as
representational evidence and does not silently strengthen the model. Future
work is an opt-in, plugin-declared branch convention rather than automatic
branch selection.

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
scalar-affine one-sided domain guards from conditions that need a domain plugin or
reformulation. Explicit opt-in guarded auxiliary construction now supports
those materializable `log`/`log1p`/`log1mexp`/`sqrt` cases plus sign-confined reciprocal,
division, and negative-power domains, and records its chosen margin.
It also handles closed inverse-trigonometric intervals and `acosh`/`atanh`;
the generic core continues to leave periodic and multi-branch domains explicit
rather than choosing a branch, except for a finite interval that ends at one
identified periodic singularity, where it can safely move that endpoint inward.
Stable expression fingerprints now also produce non-mutating reformulation
plans with explicit registration requirements for custom stable primitives,
including a domain-preserving `log1mexp` candidate for `log(1 - exp(x))`.
The guarded auxiliary layer also materializes the scalar-affine relational
domain `a - b ≥ ε` for `logdiffexp(a, b)` as one inspectable guard rather than
two independent argument bounds.

## Degeneracy framework

Numerical nullspaces are compared with structural results before any
plugin-supplied expected-gauge interpretation. Implemented generic
classifications include structurally expected local nullspaces and unexpected
local rank loss, candidate common-coordinate shifts, and candidate two-row
equation dependencies, plus compact and single-coordinate local freedoms. Next
classifications:

- expected coordinate gauge declarations and observed-nullspace comparison
  (implemented, including declared-span dimension checks);
- component expected-rank comparison and matching local right-nullity evidence
  (implemented; the generic core deliberately leaves physical mode
  fingerprinting to plugins), plus cross-point component-rank persistence
  and component-local right-nullspace persistence evidence for explicitly
  supplied evaluations, including optional component-scope expected-mode
  comparison;
- cross-point equality-Jacobian rank and right-nullspace persistence screens
  (implemented for explicitly supplied, coordinate-aligned evaluations,
  including expected-mode comparison at every supplied point);
- initialization analysis includes the generic point-local degeneracy pass for
  a complete explicit start (implemented; it remains opt-out and does not
  generate or alter starts), plus optional component expected-rank comparison
  at that start;
- active-set nullspace classification beyond structural/numerical tangent
  comparisons, compact dependence, uniform shifts, and declared-mode spans;
- richer flat reduced-Hessian direction fingerprints beyond uniform,
  compact-support, declared-mode consistency, and cross-point persistence
  checks, including generic structural component scope and declared component
  metadata overlap, persistent expected-mode span comparisons, and
  stable-versus-changing flat-support, active-row, and active-Jacobian rank
  fingerprints, plus opt-in multiplier-representative and Jacobian-scaling
  persistence, and direct reduced-Hessian spectral-scale persistence; and
- unknown local equality-Jacobian mode (implemented).

PowerModels and multiconductor semantics follow only after these generic
interfaces are stable. The optional PowerModels `0.21` public-reference first
slice is now implemented: it enumerates standard component metadata, preserves
per-unit labels and public scalar `:va` MOI scopes, reports reference-bus
cardinality per network and declared island, and provides explicit angle-mode
candidate entry points for generic degeneracy, active-set, and reduced-Hessian
persistence analysis. It does not inspect private PowerModels fields, parse
variable names, infer actual reference constraints, or declare multiconductor
ports. Those formulation-specific and physical-semantic layers remain future
work; see `docs/powermodels_extension.md`.
The concrete multiconductor declaration boundary is recorded in
`docs/multiconductor_extension.md`. It now includes optional component- and
port-coordinate nominal scales: direct terminal maps yield map-adjusted
point-local scale checks and static shared-coordinate consistency checks, while
mixed maps remain explicitly unavailable to generic scalar scaling.

The first BMOPFTools staged-OPF adapter is also implemented. It translates
public terminal/grounding evidence, validates registered rectangular terminal
voltage coordinates, preserves SI versus per-unit coordinate semantics and
physical base evidence, audits lifecycle and semantic-registry coverage, and
offers opt-in floating-neutral candidates to local degeneracy, active-set, and
cross-point persistence analyses. These candidates remain physical
expectations rather than automatic gauge claims; see `docs/bmopf_extension.md`.
`bmopf_profile_case` now provides the first reproducible real-context benchmark
record: it retains generic profile timings separately from BMOPFTools terminal,
port, lifecycle, registry, component, and initialization evidence. Curating
real feeder cases and collecting large-machine observations is the next step;
the context-level harness does not invoke a solver, while
`bmopf_build_and_profile` can explicitly construct and KCL-finalize a fresh
staged context from a caller-owned copied network before profiling it.
The corpus summarizer now also aggregates per-stage diagnostic wall-clock and
allocation observations across successful profile records, while preserving
structural-only campaigns as a separate zero-profile population. These are
machine- and configuration-dependent measurements, intended to guide benchmark
selection and stage budgets rather than serve as performance scores.
The first live corpus checks now cover a 30-bus LN profile (704 variables,
844 scalar rows; dense rank intentionally skipped) and a 538-bus LN structural
pass (11,028 variables, 12,538 scalar rows; no point evaluation or dense rank).
The 30-bus evidence mix was predominantly representational and numerical,
while the large structural pass recovered repeated implied-bound and duplicate-
expression patterns without attempting dense analysis.
The BMOPF context profile now also includes BMOPFTools' public differentiability
audit by default, preserving engine annotations and local readiness
qualifications next to generic derivative evidence. This remains an engine-owned
qualification report, not a proof of LICQ, KKT nonsingularity, or global
smoothness.
Campaign summaries can now be compared with an evidence-preserving command
that reports case-status changes, finding-count deltas, stage timing changes,
dense-rank availability, and saved-result mapping changes without reducing them
to a single score.
Corpus-wide fingerprint reports now extend this to multiple campaigns, with
case-size normalization and recurring finding-code plus evidence-attribute
coverage across mathematical, numerical, structural, and representational
observations.
Benchmark runners now record Julia/package versions, machine metadata, the
NLPDiagnostics revision, and an environment fingerprint that participates in
resume matching. A read-only preflight command reports missing required solver
dependencies before a campaign is launched.
An explicit local bootstrap helper now develops the sibling BMOPFTools checkout
and instantiates/precompiles the benchmark stack in the ignored
`work/benchmark-environment` project, keeping the solver-independent package
environment unchanged.
An opt-in `bmopf_solver_trace.jl` runner now covers the complementary live-solve
workflow for selected small snapshots: it records Ipopt/MadNLP callback traces,
the final-result profile, BMOPFTools context evidence, and environment
provenance in one JSON artifact, while a variable-count guard records skips
instead of launching large solves.
The companion trace summarizer aggregates phase/segment counts, residual
endpoints, solver-result findings, and BMOPF context findings while preserving
the raw per-case records for inspection.
An evidence-preserving comparison command now aligns selected Ipopt/MadNLP
summaries, exposes objective-convention disagreements and residual deltas, and
keeps environment mismatches explicit instead of producing a solver score.

## Solver postmortem foundation

`SolverPostmortem` is a solver-neutral record for a solver name, normalized
termination symbol, optional raw status, iteration count, residuals,
complementarity, restoration outcome, and textual metadata.
`analyze_postmortem` turns this into evidence-first findings without claiming
that a solver's termination proves feasibility, infeasibility, optimality, or
a physical cause. Future Ipopt and MadNLP extensions should translate their
native results into this record while retaining the raw status and relevant
metadata.

The read-only `solver_result_point(model; result_index = 1)` boundary now
requires a complete public MOI `VariablePrimal` vector and never fills missing
coordinates. `analyze_solver_result` combines that point with an explicitly
supplied or optional solver-extension postmortem, then runs the ordinary
analysis pipeline. Missing result coordinates and missing postmortem adapters
are retained as representational findings rather than being confused with a
solver or mathematical diagnosis. It never calls `optimize!`, changes starts,
or alters the optimizer.

`profile_solver_result` builds the corresponding `ProfileCase` and serializable
profile automatically, while retaining postmortem evidence in a separate
`result_report`. Its `profile_kwargs` expose numerical budgets and its
`case_kwargs` preserve task/formulation/scale provenance.
When `solver_log` is supplied, the same result report also retains raw marker,
structured iteration, and postmortem/log-consistency evidence; log parsing is
never treated as a feasibility or optimality certificate.
Profile captures also compare a finite solver-reported objective with the
recomputed objective at the retained primal point, labeling disagreement as
numerical/representational evidence rather than as a KKT or optimality claim.
They can additionally accept explicit `IterationPointBinding` records;
captured-iterate numerical, feasibility, and persistence evidence is retained
in the same result report, while raw log text remains non-reconstructive.

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
available. Their opt-out local degeneracy screen makes captured stationary rank
loss and nullspace fingerprints visible, and their optional component-rank
screen compares plugin declarations with the supplied iterate Jacobian, without
interpreting log text as a certificate. Within each explicit non-restarted log
segment, captured points also receive a cross-point Jacobian rank/nullspace
persistence screen. Trace-level feasibility and objective disagreement across
multiple bound points is reported conservatively. Future work is solver-specific
iterate capture rather than reconstructing points from raw text.
The solver-independent capture boundary is now explicit: callback adapters can
append `SolverIterationRecord` values to an `IterationTraceCapture`, attach
complete `EvaluationPoint` values when available, and freeze a segmented
`SolverIterationTrace`. Trace data is serializable, restart boundaries remain
visible, and `profile_solver_result(...; iteration_trace = trace)` carries the
capture provenance into the result report. Ipopt/MadNLP-specific callback
adapters remain optional extensions; the core still never reconstructs points
from printed log text. The Ipopt extension now implements this boundary through
its public `CallbackFunction`, including optional `CallbackVariablePrimal`
point capture and explicit restoration-phase labels. MadNLP callback capture
now implements its public `AbstractUserCallback`/`intermediate_callback`
boundary, capturing solver metrics and explicit phase labels while intentionally
leaving primal-point bindings unavailable.
MadNLP callback objectives are unpacked through its public callback accessor,
avoiding false cross-solver objective mismatches caused solely by internal
objective scaling; the raw solver-result objective remains the comparison
reference.
Both solver extensions also expose one-call solve helpers:
`ipopt_optimize_with_iteration_trace!` installs the Ipopt callback (optionally
capturing callback primal points), solves, and returns a frozen trace, while
`madnlp_optimize_with_iteration_trace!` performs the analogous metric-only
MadNLP workflow. These are convenience boundaries; the underlying capture
objects remain available for multi-phase or custom solve workflows.
The solver-independent `profile_solver_with_iteration_trace!` helper now
accepts a caller-supplied trace solve function and returns a
`SolverTraceProfileRun`. Ipopt and MadNLP provide convenience wrappers that
solve, profile the final public MOI result, and serialize the trace alongside
the profile, making benchmark records directly inspectable without coupling
the core to a solver.
