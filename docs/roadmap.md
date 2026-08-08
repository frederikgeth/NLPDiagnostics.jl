# Development roadmap

This roadmap orders work by the evidence needed for later claims. A numerical
or physical interpretation should not be implemented before the structural and
evaluation layers can expose its supporting evidence.

## 2026 architecture review: consolidate and calibrate

The project remains correctly motivated and its main architectural decisions
remain sound. In particular, the MOI-native core, optional solver and domain
extensions, non-mutating default, and separation of mathematical, structural,
numerical, local, physical, and heuristic evidence should be preserved.

The project has nevertheless crossed an important phase boundary. The generic
core and the BMOPF research extension now contain enough diagnostic breadth to
exercise the original vision. The main risk is no longer missing features. It
is drawing conclusions from numerical kernels, operating points, or domain
metadata that have not yet been calibrated well enough. Until the trust gates
below are met, NLPDiagnostics should be described as an advanced research
prototype rather than a reference diagnostic tool.

The next development phase therefore prioritizes, in order:

1. numerical-kernel validation and certificates;
2. evaluation-point and derivative provenance;
3. solver-event correlation at captured iterates;
4. physically labelled BMOPF calibration cases; and
5. API, source, test, and benchmark consolidation.

New finding families should be added only when they close a documented gap in
one of these tracks and arrive with a truth-labelled calibration case.

### Status at the review boundary

The implementation is substantially ahead of the original milestones in
feature breadth:

- the static, expression, structural, numerical, active-set, degeneracy,
  initialization, elastic-feasibility, and postmortem layers all have working
  implementations;
- Ipopt, MadNLP, PowerModels, and BMOPFTools integrations exist behind optional
  extension boundaries;
- the finding model consistently preserves evidence basis, confidence, issue
  domain, affected entities, and suggested actions;
- guarded dense analysis, sparse structural matching, sparse QR rank screens,
  iterative null-direction probes, expected physical modes, and persistence
  comparisons are available; and
- the default package test suite passes 1,549 tests at this review boundary.

The remaining gap is scientific validation rather than raw capability. In
particular:

- guarded dense SVD is a useful small-problem oracle, but sparse QR pivot
  thresholds and iterative probes are not yet independently calibrated rank or
  nullity certificates;
- the current inverse-free small-direction iteration must never be interpreted
  as proving a nullspace when it has not converged or lacks a residual/error
  certificate;
- an observed structural rank is a term-rank statement about the supplied
  sparsity pattern, not a proof of local or algebraic rank;
- active-set LICQ, MFCQ, multiplier, and reduced-Hessian findings remain local
  to the selected active set, scaling, multipliers, and operating point;
- recent BMOPFTools initialization points are incomplete for the sampled BMOPF
  cases, while synthetic zero points are suitable only for software smoke
  tests and must not support physical conclusions; and
- the public and internal surface has grown large enough that further feature
  accumulation would make review, testing, and API stabilization harder.

### Trust gate A: numerical rank and nullspace calibration

Treat this as the highest-priority numerical-algebra work.

- Define a typed `RankPolicy` carrying absolute and relative tolerances,
  scaling, matrix norm, backend, and provenance. Reports must expose the exact
  policy rather than reconstruct it from loosely related metadata strings.
- Retain dense SVD as the guarded reference backend for small matrices. Promote
  the existing sparse `qr` path into a documented rank-revealing backend that
  preserves column permutations, diagonal/pivot policy, residuals, and
  conditioning evidence. Julia's SuiteSparseQR-backed factorization is the
  preferred first backend; a different optional backend is needed only if its
  required evidence cannot be recovered through the public interface.
- Use MOI `:JacVec` capabilities where available so large-model probes need not
  materialize a second Jacobian representation. Preserve whether products were
  evaluator-provided or derived from stored sparse entries.
- Replace or supplement the inverse-free normal-operator iteration with a
  standard operator method built on Golub--Kahan bidiagonalization, such as
  LSMR/LSQR or a vetted smallest-singular-triplet routine. Do not form `J'J`
  explicitly.
- Every candidate right mode `v` must report `norm(J*v)`, `norm(v)`, the matrix
  norm estimate, and a dimensionless backward-error measure. Left modes must
  report the analogous `norm(J'*u)` evidence.
- A claimed subspace must report orthogonality loss, individual residuals,
  principal-angle stability across repeated seeds or points, and the assumed
  nullity. Non-convergence produces coverage evidence, not a degeneracy
  finding.
- Add tolerance and row/column-scaling sweeps. A mode that appears only under a
  narrow arbitrary threshold is classified as tolerance-sensitive numerical
  evidence.

Exit criteria:

- dense SVD, sparse RRQR, and operator backends agree on a curated small-matrix
  corpus whenever their stated tolerances imply the same numerical rank;
- disagreements are reproduced and reported as evidence rather than resolved
  by silently choosing one backend;
- the corpus includes exact deficiencies, nearly dependent rows and columns,
  badly scaled full-rank matrices, rectangular systems, cancellation-induced
  zero derivatives, clustered small singular values, and known left and right
  nullspaces;
- false rank-deficiency findings are measured on ill-conditioned but full-rank
  cases; and
- large-model runs have explicit work and memory guards and never densify an
  unbounded BMOPF network matrix.

First implementation increment: `RankPolicy` now types backend, scaling,
relative and absolute tolerance, matrix norm, work guard, vector policy, and
provenance. The SuiteSparseQR-backed path preserves row/column permutations
and, under a separate dense-evidence guard, a relative factorization residual.
Iterative left/right candidates now carry dimensionless backward residuals,
and a 91-assertion calibration corpus covers exact, rectangular, zero,
clustered, ill-conditioned, scale-sensitive, and absolute-threshold cases.
This does not complete the gate: a standard Golub--Kahan operator backend,
MOI `:JacVec` integration, broader adversarial matrices, and calibrated
false-positive/false-negative summaries remain outstanding.

### Trust gate B: evaluation-point and derivative provenance

No numerical or physical result is more trustworthy than its evaluation point.

- Make point provenance a required typed field with at least `initialization`,
  `completed_initialization`, `solver_iterate`, `solver_result`, `perturbed`,
  and `synthetic_smoke` categories.
- Implement a documented initialization-completion policy that fills only
  values justified by model bounds, plugin semantics, or an explicit user
  policy. Never silently replace missing starts with zero.
- Record feasibility, active-set selection, derivative source, derivative
  fallback, scaling, and model/source hashes beside every numerical snapshot.
- Cross-check evaluator Jacobians and Hessians against directional products or
  finite differences on small, domain-safe calibration cases. A finite-
  difference disagreement near a nonsmooth point or domain boundary is not by
  itself proof that automatic derivatives are wrong.
- Add an optional NLPModels adapter after the MOI path is stable. MOI remains
  canonical; the adapter broadens access to solver-oriented derivative APIs,
  counters, Jacobian-vector products, Hessian-vector products, and established
  test models.

Exit criteria:

- every persisted numerical report identifies exactly how its point was
  obtained and whether all required variables were present;
- synthetic-zero reports cannot acquire physical confidence through a plugin;
- the BMOPF smoke corpus has either complete physical starts or saved feasible
  solver points for each case used in scientific comparisons; and
- derivative cross-checks distinguish implementation defects, finite-
  difference truncation/cancellation, nondifferentiability, and domain failure.

First implementation increment: every `EvaluationPoint` now carries typed
origin, source, completeness, and metadata. Model starts, completed BMOPF
starts, saved results, Ipopt callback iterates, and BMOPF coordinate probes are
tagged at capture time; persisted profile and trace data retain the tag.
Synthetic profile cases also promote default user provenance from their
explicit `:synthetic` tag. Numerical reports limit point-local physical
findings from synthetic, artificially completed, or incomplete points to
low-confidence heuristic evidence. This establishes the confidence boundary,
but the gate remains open until completion policies stop using unjustified
fallback values, model/source hashes are retained, derivative cross-checks are
calibrated, and the BMOPF scientific corpus has trusted operating points.

Second implementation increment: model snapshots, explicit points, and
evaluator derivative paths now carry stable SHA-256 fingerprints into
numerical, profile, trace, and point-serialization records. An opt-in
deterministic directional Jacobian cross-check compares recorded products with
central finite differences, classifies mismatches as local numerical evidence,
and preserves domain-limited perturbations as unavailable evidence. This is an
early calibration tool; it does not yet establish derivative correctness across
operator boundaries or replace a Jacobian-vector-product backend.

The same cross-check layer now covers objective gradients. Combined and profile
analysis can independently compare `∇f` directional products with nearby
objective values, preserving missing or non-finite sides as domain-limited
evidence. This closes the first-value/first-derivative calibration loop for
small cases. MOI `:JacVec` is now requested when advertised and directly
compared against stored sparse products. Hessian-of-the-Lagrangian products now
have an opt-in cross-check against finite differences of the Lagrangian
gradient and, where representable, direct MOI `:HessVec` products. These are
still local consistency observations; multi-scale, truth-labelled boundary
statistics now have a deterministic scale-sweep summary that distinguishes
scale-persistent disagreement from truncation- or domain-sensitive behavior.
Truth-labelled boundary statistics and solver-iterate coverage remain the next
numerical-kernel items.

### Trust gate C: solver-consistent local optimality and postmortem evidence

The package should explain solver behaviour by correlating model evidence with
algorithm events, not merely by parsing termination strings.

- Bind captured iterates to objective, infeasibility, complementarity,
  Jacobian rank/scaling, active-set, multiplier, and reduced-Hessian snapshots
  when the solver exposes enough state.
- For Ipopt, correlate restoration entry, rejected steps, barrier updates,
  inertia correction, and Hessian regularization with the local model evidence.
  Preserve unavailable events explicitly when the public callback/log does not
  expose them.
- Keep equality-tangent curvature, inferred-active-inequality curvature, and
  solver KKT inertia as separate evidence channels. Document multiplier sign
  conventions and the effect of objective/constraint scaling.
- Distinguish weakly active constraints from strongly active constraints when
  multiplier and nearby-point evidence supports that distinction. Do not turn
  a single thresholded active-set snapshot into a global classification.
- Construct paired formulations whose Jacobians are similarly conditioned but
  reduced Hessians, inertia corrections, or globalization behaviour differ.

Exit criteria:

- at least one controlled case reproduces each of restoration caused by domain
  or feasibility difficulty, regularization associated with poor reduced
  curvature, derivative-check failure, and scaling-sensitive termination;
- the report can identify what is observed directly from the solver, what is
  recomputed by NLPDiagnostics, and what is inferred by correlation; and
- the same formulation is profiled with at least two solver configurations so
  formulation, derivative-evaluation, linear-solver, and globalization effects
  are not conflated.

### Trust gate D: BMOPF physical calibration

BMOPF should now be used as a labelled scientific validation corpus, not merely
as a source of increasingly many fingerprints.

- Freeze a small, reviewable ladder of cases before expanding the corpus:
  grounded and floating wye, delta circulation, missing or duplicate reference,
  neutral island, ideal transformer redundancy, zero-impedance branch,
  current-source cutset, voltage-source loop, sequence ambiguity, controller
  conflict, and a stressed voltage-collapse family.
- For every case, record the expected structural rank, expected physical
  nullspace, parameter-dependent exceptions, admissible operating-point
  region, and the finding codes that should and should not appear.
- Preserve source-file hashes and transformations from asset data through
  PowerIO/BMOPFTools to JuMP/MOI. A source-schema warning, a representational
  transformation, a physical inconsistency, and a numerical observation must
  remain separate facts.
- Compare expected port/component modes with observed local modes using
  residuals and principal angles. A name or topology match alone is not enough
  to classify an observed numerical vector as physical.
- Add formulation pairs such as IVR/SVR/SVP where possible, with positive-
  sequence and deliberately poor initializations, sequence/angle constraints,
  and multiple power bases.

Exit criteria:

- the labelled small corpus has reviewed expected outcomes and zero unexplained
  high-confidence false positives;
- perturbing a known defect changes the intended finding and leaves unrelated
  findings stable within documented tolerance;
- physical conclusions use complete starts or solver points, never only the
  synthetic zero policy; and
- dense methods are confined to explicitly small blocks while sparse/operator
  methods handle the large cases.

### Trust gate E: codebase and API consolidation

This track should run in parallel with the scientific calibration work.

- Split the root module, BMOPFTools extension, monolithic test file, and large
  benchmark validator by responsibility while preserving behaviour.
- Define a deliberately small stable API. Put low-level numerical records,
  plugin construction hooks, benchmark machinery, and research-only probes in
  documented advanced or experimental namespaces rather than exporting every
  symbol from the root module.
- Replace internal stringly typed metadata with typed records and enums where
  the schema is controlled by NLPDiagnostics. Convert to string-keyed data only
  at JSON/report boundaries and retain schema versions.
- Centralize repeated benchmark parsing, policy, hashing, and summary helpers.
- Audit broad `catch` boundaries. Expected capability failures should return a
  typed unavailable reason; unexpected exceptions should retain exception type
  and context and must not be silently converted to `nothing`.
- Add CI for supported Julia versions, package tests, extension-specific
  environments, formatting, documentation examples, and quality checks such as
  Aqua and targeted JET runs. The default test target currently does not cover
  the Ipopt or MadNLP extensions and must not be presented as doing so.
- Resolve the project manifest after dependency/compatibility changes and keep
  reproducible benchmark environments separate from the minimal package test
  environment.

Exit criteria:

- package, Ipopt, MadNLP, PowerModels, and BMOPFTools test jobs have explicit
  dependency environments and pass independently;
- public examples are executed in CI;
- experimental APIs and finding-code stability policy are documented;
- no unguarded dense conversion remains on a large-model path; and
- benchmark artifacts declare schema, package versions, source hashes, point
  provenance, solver options, and numerical policies.

### Calibration release gate

After trust gates A--E, publish a first calibration report rather than adding
another broad feature layer. It should include:

- a machine-readable truth table for synthetic and BMOPF cases;
- false-positive, false-negative, unavailable, and tolerance-sensitive counts
  by finding family;
- dense/sparse/operator rank agreement and residual distributions;
- repeated-run and repeated-point stability;
- runtime, allocation, and peak-memory scaling; and
- case studies connecting solver events to mathematical, numerical, physical,
  or representational causes.

Only after this release gate should automatic reformulation or mutating
presolve become a major workstream. The first version should produce a
reversible *reformulation plan* with proof obligations, source-to-transformed
entity mappings, and postsolve reconstruction. It must remain opt-in and must
not weaken the package's diagnostic-first identity.

### Scope discipline for the next phase

Do now:

- sparse RRQR and operator-product calibration;
- complete and typed operating-point provenance;
- solver-event/model-evidence correlation;
- truth-labelled BMOPF cases and expected-mode validation;
- modularization, API tiers, benchmark schemas, and extension CI.

Defer:

- additional domain-specific fingerprints without a failing calibration case;
- automatic numerical scores or a single model-health grade;
- large-corpus physical claims before the small truth corpus is reliable; and
- automatic model modification before reversible mappings and proof
  obligations exist.

Do not do:

- report an unconverged iterative candidate as a nullspace or rank result;
- interpret a synthetic-zero smoke point as a representative operating point;
- infer physical causation from variable names or topology alone;
- run unguarded dense analysis on large multiconductor models; or
- erase disagreement between structural, numerical, physical, and solver
  evidence by collapsing them into one conclusion.

The detailed sections below remain the implementation ledger. When they
conflict with this review, the trust-gated priorities above take precedence.

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
- Point-local controlled Jacobian row-family perturbations are implemented.
  They remove one labelled row family at a time from the recorded linearization,
  recompute guarded rank/nullity estimates, and retain the removed rows,
  scaling, tolerance, and availability guard as evidence. This is deliberately
  not a model deletion or re-solve and cannot by itself establish causality.

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
The BMOPFTools staged adapter now provides an attachment-level port slice:
native device terminal maps and line endpoints are represented as explicit
component-to-bus ports with rectangular voltage coordinate maps, semantics,
and finite embedding matrices. Fixed- and n-winding transformer winding
attachments are covered as well. Rectangular current ports for lines, native
devices, switches, and transformers are now exposed from the public current-key
registry with explicit maps, unit semantics, and coverage reports; omitted
neutral current coordinates are represented as shorter registered ports. This
is deliberately not a constitutive or network-equality model. Physical
expected port-mode declarations (common mode, neutral, delta, and transformer
vector-group semantics) are now partially implemented: explicit-neutral WYE and
DELTA terminal ports expose named common-mode expectations and semantic
categories, with opt-in projection into `bmopf_analyze_opf` for comparison
against numerical nullspaces. These remain physical expectations and do not
claim a network gauge. Transformer vector-group labels, delta orientation,
ratio/tap evidence, and phase-shift coverage warnings are now retained by the
constitutive-map adapter. Fixed-transformer phase-aware real-block maps now
apply declared complex phase rotations, while the original separated maps
remain available as structural incidence evidence. The first current-side
contract now wraps BMOPFTools' public passive Ybus as an SI `I = YV` map and
reports p.u. conversion boundaries explicitly; an opt-in `basis=:model` path
now applies complete public bus voltage/current bases. The declared
attachment graph now has an inspectable connected-component assembly summary;
disconnected groups remain representational evidence. Static nonlinear-current
fingerprints now classify public device metadata, including zero-voltage and
unknown-differentiability hazards. Public load equations now also have guarded
operating-point probes from explicit staged points or saved result dictionaries,
including local current-Jacobian scale/conditioning and separate zero-voltage
and non-finite coverage findings. Static generator and IBR fingerprints now
retain the generator bilinear voltage/current law and conservatively classify
public constant-power-factor, voltage-droop, power-sharing, and box-dispatch
profiles. Multi-point operating-point persistence is exposed for aligned load
probes, reporting status transitions, derivative-scale changes, conditioning
changes, and partial coverage without treating unavailable probes as zeros.
The public generator/IBR bilinear power maps are now evaluated at saved-result
and explicit-point coordinates, with observed P/Q, saved-result equation
residuals, and voltage/current-to-power derivative fingerprints. Captured
Ipopt primal iterates can now be selected by phase/budget and passed through
the same probes with solver labels and persistence evidence; metric-only
MadNLP traces remain explicitly unavailable for coordinate diagnostics. Public
Volt-var/Volt-watt profiles now also receive stable softplus/ReLU-sum
operating-point fingerprints (normalized output, local slope, smoothing width,
and breakpoint proximity). The adapter now resolves public PG/PN/PP monitored
voltages and per-phase/average aggregation from bus coordinates, retaining an
exact-versus-proxy coverage label and benchmark-level curve/status aggregates.
Controller residuals for public Volt-var/Volt-watt profiles are now recorded
when declared device bases are available; remaining work is optional
domain-specific monitor maps for nonstandard controllers and richer benchmark
aggregation. Persistence now compares controller status, monitor-coverage, and
local slope changes across explicit snapshots and captured traces, with the
solver-trace summarizer retaining those categories separately. The
`ControllerCurveOperatingPointObservation` record now provides a stable typed
consumer boundary for profile-level observations, including monitor semantics,
normalized output, local slope, breakpoint distance, device base, and residual
evidence. The draft-corpus runner now persists these records and summarizes
controller-rich BMOPF cases by family, status, and monitor-coverage semantics.
The generic
`PortConstitutiveMap` contract and BMOPFTools adapter are now implemented for
device WYE/DELTA coil incidence, fixed-transformer ideal winding coupling, and
n-winding per-winding coil incidence. These maps preserve vector-group and
ratio/tap metadata while remaining distinct from topology connections.

The smoke benchmark now records the multiconductor contract alongside solver-
independent profiling evidence: voltage/current port coverage, physical-mode
declarations, constitutive-map ranks, and independent adapter findings. The
test suite also includes broken attachment and malformed-map fixtures, so
coverage failures are retained as representational evidence rather than being
silently converted into physical diagnoses.

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
The depot-safe `run_benchmark.jl` launcher now constructs child argv
explicitly and extracts Julia 1.12 process failures through the current
`procs` field, so multi-argument benchmark scripts and nonzero child exits
remain reproducible on current Julia releases.
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
The option-sweep orchestrator now launches isolated trace campaigns with
explicit solver attributes and aggregates termination categories, making
restoration, slow-progress, numerical-failure, and resource-limit behavior
inspectable across controlled configurations.
The BMOPF trace runner now has opt-in solver-owned log capture, preserving raw
marker and structured-iteration evidence beside callback traces; its
summarizer reports log availability, observation counts, and finding-code
distributions without reconstructing iterates from text.
The controlled `solver_failure_cases.jl` harness now supplies small
solver-independent postmortem regression models for iteration limits,
infeasibility, invalid domains, and restoration candidates; its summarizer
keeps intended signals separate from observed solver classifications. The
harness configures solver-owned log files when supported, accepts externally
captured logs through `NLPDIAGNOSTICS_FAILURE_LOG_DIR`, and stores raw marker,
structured-iteration, and postmortem/log-consistency evidence together. Log
capture remains optional evidence: it does not reconstruct iterates or turn a
restoration message into an infeasibility certificate.
Subprocess isolation around native solver exits is now implemented. The
dependency-light `launch_solver_failure_cases.jl` launcher preserves each
child's exit status, partial process log, and an explicit per-child timeout;
timed-out MadNLP starts or restoration cases remain `process_timeout` evidence
rather than being silently dropped. A matching
`launch_bmopf_solver_trace.jl` launcher isolates one BMOPF snapshot per child
while retaining solver-owned logs and completed JSON records. The direct
harnesses remain available as in-process, low-overhead smoke tests.
The `launch_bmopf_solver_matrix.jl` launcher now runs the same snapshot set
through Ipopt and MadNLP in separate evidence directories, with per-pair
timeouts and a parent manifest. The existing summary/comparison tools can
therefore compare termination, iteration, residual, objective-convention, and
solver-log evidence without mixing process-startup failures into solver
outcomes.
`summarize_bmopf_solver_matrix.jl` now materializes missing per-solver
summaries and pairwise comparison artifacts from that manifest, retaining
summary or comparison subprocess failures as explicit campaign evidence.
The matrix launcher and summarizer also propagate controlled model-level
family perturbations. `family_perturbation_matrix` aligns each completed
solver/case/family variant with its baseline, retaining termination and
iteration deltas, local sparse-rank evidence, variant errors, and descriptive
repeatability counts. These no-op family replacements are deliberately
incomplete formulations for sensitivity experiments, not physical
counterfactuals or causal proofs.
Repeated perturbation matrices now carry explicit run identifiers and
replicate indices. The repeat summarizer checks baseline termination
consistency before reporting repeated variant changes, so solver instability is
not silently attributed to the formulation. This is the minimum provenance
layer required before learning from multi-snapshot BMOPF profiling campaigns.
The corpus summarizer now aggregates multiple repeat outputs by family and
case, retaining iteration-delta distributions, sparse-rank recurrence, and
solver agreement/disagreement. This creates a descriptive evidence layer for
the first benchmark-learning campaigns without turning formulation omissions
into causal or physical scores.
Cross-solver alignment now compares baseline and variant termination sets,
iteration-direction signatures, and repeatability labels for the same
case/family pair. Distinct disagreement categories are retained so solver
dependence is visible rather than averaged into a single effect.
Corpus perturbation reports now emit structured findings with severity,
confidence, evidence, and suggested actions. Recurring sparse-pattern effects
are marked as local numerical observations, while solver-dependent termination
and iteration behavior is explicitly surfaced as conditional evidence.
The combined BMOPF campaign report can now retain these corpus perturbation
findings in a separate namespace, keeping benchmark-derived evidence distinct
from generic structural and solver-result fingerprints.
An evidence-ledger summarizer now normalizes findings from corpus, validation,
repeat, and campaign reports while preserving source paths, confidence,
severity, and recurrence identities. This provides a stable input for future
benchmark regression and learning workflows without collapsing evidence into a
score.
Ledger comparison now classifies identities as new, resolved, persistent, or
distribution-changed, preserving the source paths and evidence behind each
transition. This is the first regression-oriented layer for comparing future
BMOPF campaigns safely.
Comparisons now also gate on campaign provenance: selected cases, solvers,
families, environment fingerprints, and available analysis budgets are
compared explicitly. Missing or incompatible provenance is reported as
conditional evidence rather than a silent regression. New ledgers also emit a
canonical campaign-provenance object and hash fingerprint, so future
provenance fields cannot silently bypass the compatibility gate.
An initial three-snapshot, two-replicate Ipopt smoke produced six completed
`load` variants with zero baseline inconsistencies, stable termination across
replicates, and recurring local sparse-pattern effects. This is useful
profiling evidence, but remains solver- and family-scoped until cross-solver
and larger-corpus campaigns are run.
`summarize_bmopf_campaign.jl` combines those solver summaries with one or more
structural/profile corpus summaries while preserving source-specific evidence
and emitting aggregate recurring-fingerprint counts.
The corpus runner now has explicit, provenance-bearing time-series selectors
for 30-, 538-, and 99-bus LN/LG snapshots. A corrected 30-bus structural sweep
covered all 50 snapshots (704 variables, 844 scalar rows each) with zero
errors; a preceding full-corpus structural sweep covered all 150 snapshots
without dense rank materialization. The benchmark stack and core package
regression suite remain green (1,541 tests), using the depot-safe launcher when
the host Julia depot is read-only.
Saved-result profiling now accepts the corpus' explicit `:pu` convention in
addition to SI and model coordinates, and the corpus runner preserves the
adapter's unit-fingerprint report. Across 50 30-bus snapshots, SI inputs gave
zero generic feasibility violations and zero unit-scale warnings; interpreting
the adjacent `_result_pu.json` files as homogeneous model coordinates produced
20,250 feasibility-violation findings and 50 scale warnings (median voltage
magnitude about 228). This is a useful mixed-unit fingerprint, not a solver
failure: the data's per-unit label does not describe every exported field.
The field-level `compare_bmopf_saved_result_units.jl` report now compares
paired SI/PU leaves directly, preserving ratio distributions by exported field
family instead of forcing a global conversion. The corpus runner also exposes
BMOPFTools' floating-neutral candidate modes behind an explicit opt-in flag;
candidate directions remain physical expectations and are never promoted to
generic nullspace claims automatically.
The first saved-result 538-bus profile also completes: one 11,028-variable /
12,538-row case mapped all staged coordinates with dense rank skipped. Its
dominant numerical limitation was `active_set_block_rank_unavailable` (2,424
block observations), alongside a large Jacobian row-scale spread; these are
recorded as analysis-availability and scaling evidence, not as a blanket claim
that the 538-bus model is singular.
The saved-result adapter now also accepts a field-level unit policy, retained
in mapping/report metadata and benchmark fingerprints. This supports mixed
exports without pretending that a global `:pu` suffix is a homogeneous
numerical convention. The next benchmark ticket is to run paired SI/PU
campaigns with policies derived from the field-ratio report, then compare
feasibility and derivative fingerprints under those declared policies.
The policy-aware profile comparator is now available. On the first 30-bus
paired probe, applying `bus_voltage=si` alone to the PU export did not restore
the SI feasibility fingerprint (it added 419 violations), while declaring all
mapped exported families as SI restored zero feasibility delta for that case.
This is evidence that the remaining mismatch is in current/power-family
semantics rather than a single voltage conversion, and motivates broader
paired campaigns before any automatic policy inference is attempted.
An isolated policy-matrix launcher now runs the baseline SI/PU choices and
explicit correction probes in separate child processes. On the first 30-bus
case, the `pu_all_si` policy matched the SI feasibility fingerprint exactly
(zero violation delta), while `pu_bus_si` alone did not. This gives us a
reproducible experiment harness for the next phase: derive field policies from
larger paired campaigns and inspect derivative/rank changes without conflating
process or cache failures with numerical findings.
The policy-matrix summarizer now runs all pairwise comparisons and retains
Jacobian-rank availability, sparse-QR rank, derivative-provenance codes, and
scale-finding deltas alongside feasibility changes. This is the benchmark
boundary needed before testing policy hypotheses on the larger 99- and
538-bus cases.
Those larger probes are now complete with dense rank disabled: one 99-bus LN
case and one 538-bus LN case both ran successfully under SI and `pu_all_si`.
Each had zero feasibility-violation delta and identical Jacobian/sparse-QR
rank fingerprints; the corrected policy reduced the total finding count by
one and removed one row-scale warning. This supports treating the current
issue as result-export unit semantics rather than a model-size-dependent rank
failure, while leaving the remaining per-family policy inference empirical.
The saved-result persistence harness now maps multiple time points into one
staged context. On five 30-bus LN points with dense rank enabled, local
Jacobian rank remained persistent with no right-null direction at the selected
tolerance, while left-nullspace alignment was not persistent and row/column
scale spread changed materially. This is the first time-series fingerprint
separating stable local rank from changing residual geometry; the same harness
records explicit availability when dense analysis is budgeted out on larger
models.
The guarded 538-bus two-point persistence run mapped all 11,028 coordinates at
both points and reported rank persistence as unavailable under the zero dense
budget, preserving the large-model analysis boundary without silently reducing
the model or fabricating a nullspace conclusion.
The persistence harness now retains per-point active-set reports as well. On
the five-point 30-bus dense run, active rows ranged from 620 to 732 (mean
642.4), with LICQ/MFCQ, active-DM, and active-feasibility fingerprints kept
separate from the persistent equality-Jacobian rank result.
Active-set summaries now also retain row-scope intersection, union, and
transition counts. The five-point 30-bus run had 620 rows common to every
point, 732 rows in the union, and one active-set transition, making the change
in active geometry inspectable without turning it into a stability score.
The guarded 538-bus two-point run mapped all 22,056 point coordinates with no
fallbacks; 10,120 active rows were common to both points, with 11,330 in the
union and one transition. Its 3,934 block-rank-unavailable observations and
909 active-feasibility findings remain explicit availability/numerical evidence
rather than a claim of global rank deficiency.
The unified BMOPF campaign summary now accepts persistence summaries through
`NLPDIAGNOSTICS_BMOPF_PERSISTENCE_SUMMARIES`, aggregating rank/nullspace/scale
fingerprints while keeping persistence availability separate from solver and
corpus finding counts.
BMOPFTools component-rank persistence now reports expected-rank declaration
coverage explicitly. Current registry-family metadata declares zero physical
expected ranks, so the persistence result remains an availability boundary,
not a fabricated full-rank or rank-loss conclusion.
The public `bmopf_component_rank_capability_report(context)` API exposes the
same boundary as a standalone, inspectable report with an explicit
`bmopf_component_expected_rank_unavailable` finding, without changing the
existing profile report's finding set.
Saved-result persistence artifacts now retain that capability report beside
the numerical component-persistence report, and the persistence/campaign
summarizers aggregate its finding codes separately from rank fingerprints.
Saved-result persistence now also retains typed Volt-var/Volt-watt observations
for every mapped time point and exposes controller status, monitor-coverage,
and slope-change findings in the persistence summary. This keeps controller
transitions aligned with the same time-series evidence used for rank and active
set persistence.
The controller campaign summarizer now reports family/status/coverage counts,
breakpoint-distance and residual distributions, and per-component slope-change
evidence without a composite score. Initial five-point 30-bus comparisons show
stable exact coverage and finite statuses in both LN and LG populations, but
substantially different slope ranges; this is a useful numerical fingerprint,
not yet a physical diagnosis.
Ipopt solver traces with captured primal points now retain the same typed
controller observations per selected iterate. A bounded four-iterate LG trace
produced 224 exact observations across both curve families, finite statuses,
and 21 local-slope-change findings; its maximum Volt-var equality residual was
reported separately as iterate-feasibility evidence.
The solver-trace comparison now aligns these controller summaries across runs.
On matched LG traces, per-unit and model-native coordinates preserved exact
coverage, family counts, and slope-change counts, while slope and breakpoint
scales changed with the coordinate convention; iteration and residual deltas
remain separate solver evidence.
The ordinary BMOPF profile context now also carries declaration coverage and
capability-finding counts as metadata, without flattening the standalone
capability finding into the existing context finding set.
Serialized profile records now carry those counts as a typed capability
object, and the smoke summarizer aggregates them separately from context
finding codes and numerical fingerprints.
The capability screen is now also available in the generic core and through
the PowerModels adapter, so plugin-specific reports share the same declaration
boundary and finding semantics.
Generic point-local and cross-point component-rank reports now carry the same
coverage metadata even when every declared component matches numerically; an
undeclared component therefore remains visible as an availability boundary,
not as an inferred full-rank result.
The new `validate_bmopf_campaign.jl` gate checks case errors, integrity
preflight, saved-result mapping completeness, dense-rank availability,
component-rank capability, environment provenance, and paired-policy alignment
without converting those checks into a quality score.
It also checks bounded solver-matrix summaries, keeping successful solver
termination, paired trace availability, and conditional physical evidence as
separate readiness gates.
The full-corpus validation phase now attributes unresolved saved-result records
by exported family, preserving the difference between a stable schema boundary
and a case-specific mapping failure.
The first 50-case 30-bus LN/LG policy sweep also showed why this gate matters:
the three-case representative agreement did not generalize, with 14 paired
cases and 187 aggregate feasibility violations differing under `pu_all_si`.
This is now treated as an empirical unit/formulation hypothesis, not as a
validated equivalence claim.
The follow-up same-file isolation matrix separates the effects: on the SI file,
`si` and `pu_all_si` are identical; on the PU file, `pu` versus `pu_all_si`
changes the feasibility fingerprint in all 14 affected snapshots (5,483 fewer
violations under `pu_all_si`). The remaining policy work is therefore to
document the mixed export convention and identify which field families require
SI conversion, rather than comparing filename suffixes alone.
The affected-snapshot field-ratio report also narrows the hypothesis: mapped
bus, line-current, load-current, voltage-source, and IBR families are near the
same exported scale, while derived `line/s_through` is consistently about
`10^-6` of its SI counterpart and a few ground/shadow-price fields are mixed.
This argues against attributing the policy delta to `ibr/pg` without further
evidence.
The adapter now serializes a versioned result-field catalog and a separate
feasibility-field attribution report. On the affected PU cohort, `pu` produced
5,670 attributed violated rows across the 14 cases, spanning bus voltage,
line current, load current, IBR current, and IBR power support; `pu_all_si`
produced 187 rows, all supported by IBR power coordinates. The report remains
explicitly non-causal: it identifies Jacobian support families, not a proven
source-field defect.
The instance-level extension makes that evidence inspectable without parsing
variable names: the 187 `pu_all_si` rows involve the IBR power records of all
28 `pv_*` devices in the cohort, whereas the `pu` rows are dominated by the
bus-voltage support at bus `79` (3,248 row attributions) plus the surrounding
network current/load supports. Both campaigns report the same BMOPFTools power
base (`1e6`), so this observation does not by itself identify a bad base or a
causal IBR field error. It does establish the next benchmark boundary: inspect
the per-device P/Q residuals and the exact constraint metadata before making a
physical interpretation.
The next semantic layer now uses BMOPFTools' public constraint registry. KCL
rows are labelled by their registered `kcl_r`/`kcl_i` family and bus-terminal
instance; device and operational-limit rows that the engine has not registered
remain explicitly `unregistered_constraint`. Campaign summaries and validation
preserve this registry boundary, so a benchmark can distinguish “the violated
row is semantically identified” from “the row only has numerical Jacobian
support.”
In the current 30-bus saved-result smoke pair, all 405 `pu` and all 17
`pu_all_si` violations are still unregistered rows; this is an honest result,
not a failed attribution. It identifies the next BMOPFTools integration task:
register the device-limit and IBR P/Q constraint families before treating those
rows as physical component diagnoses.
In parallel, the attribution now emits component candidates from variable
support (`bus/…`, `line/…`, `load/…`, `ibr/…`, and related families). This gives
the debugger a useful localization layer immediately while stronger engine-side
constraint registrations are developed; candidate components are always
reported as support evidence rather than causal diagnoses.
The first engine-side registration slice is now implemented on the
`codex/nlpdiagnostics-constraint-registrations` BMOPFTools branch: IBR phase
P/Q bounds, Volt-Watt/Volt-Var laws, apparent-power circles, auxiliary P/Q
links, and native load P/Q equations are registered with stable semantic keys.
On the affected saved-result case, this raises semantic coverage from 0 to
280/405 violated rows for the `pu` policy; the corrected `pu_all_si` case is
17/17 semantically identified, with `ibr_power_circle` accounting for 11 rows.
Source/generator bound registration and line apparent-power registration are
now wired through the same public registry for cases that declare those
devices or ratings. Switch voltage-coupling/current/apparent-power rows and
line angle bounds now use the same registry. A public
`BMOPFTools.register_opf_constraint!` helper also makes custom model-hook
registration explicit and collision-checked; hooks that do not use it remain
an intentional `unregistered_constraint` boundary.

The transformer slice is now in place as well: native YY, center-tap, Yd/Dy,
autotransformer, and open-delta regulator coil apparent-power rows and current
thermal limits are registered, together with the principal voltage/current
coupling equations. N-winding coil limits use the same stable key scheme. The
remaining transformer work is deeper equation-family coverage for specialized
internal branches, not a loss of device identity.

The smoke summarizer now reports both violated-row attribution and whole-model
constraint-registry coverage. The latter counts every evaluated scalar row and
its registered/unregistered family split, so a feasible saved point cannot make
registry gaps disappear. The validator exposes this as a separate readiness
gate (`constraint_semantic_registry_model_coverage`) and keeps partial coverage
as a warning rather than a score.
An earlier regenerated 30-bus saved-result smoke case reported 604 of 844 rows
registered. After adding construction-time KCL, line-KVL, voltage-reference,
and monitored-magnitude keys, the fresh isolated trace reports 844 of 844 rows
registered. Both artifacts remain useful: the first records the former API
boundary, while the latter proves its closure for this specific formulation.

BMOPFTools semantic row maps now feed the generic point-local Jacobian
row-family perturbation screen. Solver-trace records retain the resulting
report and summaries aggregate rank-effect, no-rank-effect, and unavailable
families separately. This provides a controlled linearized experiment for
prioritizing equation families before attempting a more expensive build- or
solver-level perturbation; it remains numerical/local evidence rather than a
causal model diagnosis.

The solver-trace benchmark now also supports opt-in model-level family
perturbations. Each variant rebuilds the network with one BMOPFTools native
device family replaced by an explicit no-op builder, re-enforces KCL, and
solves independently under a bounded iteration budget. Variant status,
termination, iteration count, solver options, and the resulting numerical
profile are retained beside the baseline. This is a formulation perturbation,
not a physical counterfactual: omitting a family changes the model and can
create an intentionally incomplete network. It is therefore suitable for
causal *testing of the formulation fingerprint*, not for interpreting the
variant as a valid engineering model.

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

The BMOPF solver-trace campaign now has opt-in solver-owned log capture with
raw marker evidence and structured iteration summaries. Ipopt annotations are
parsed without discarding rows, while residual headings are excluded from
reported-infeasibility markers. The summary retains log availability, parsed
iteration/segment counts, final and minimum printed residuals, and log finding
codes separately from solver-result and BMOPFTools context evidence. A
depot-safe `run_benchmark.jl` launcher provides a writable compiled-cache
overlay for restricted environments, and the generic failure harness uses the
same provenance-preserving pattern.
The isolated solver-trace launcher now propagates the child environment
fingerprint, solver options, unit convention, and capture flags into both the
case records and the top-level index, so postmortem summaries can be validated
for reproducibility rather than treated as anonymous solver output.
The first three 30-bus Ipopt traces (two LN points and one LG point) all reached
`locally_optimal` in 17--19 iterations, while retaining persistent local rank
loss, zero-Jacobian-row evidence, and compact-coordinate nullspace candidates.
This is an initial profiling observation, not a claim that the cases are
mathematically defective; the next step is to correlate these fingerprints with
registered equation families and repeat them under MadNLP or controlled model
perturbations.
Solver-trace records now retain a row-to-semantic-family map, and the trace
summarizer reports family counts for rank/nullspace findings. On the 30-bus LN
case, the Ipopt two-row dependence maps to `ibr_p_lower`/`ibr_p_upper`, while
the persistent rank-loss fingerprint spans KCL, IBR power-link/circle/limit,
load-equation, and unregistered families. A dense final-point MadNLP run also
reached `locally_optimal` and reproduced a rank-loss fingerprint across the
same broad family groups, although MadNLP's public callback does not expose
primal iterate bindings. This is cross-solver evidence of a formulation-wide
fingerprint, not a causal diagnosis.
As a first controlled scaling perturbation, the same Ipopt case was rebuilt in
SI/model-native coordinates. It still reached `locally_optimal` (15 versus 17
per-unit iterations), retained the same KCL/IBR/load/unregistered rank-loss
families, and introduced a large-row-scale-spread finding. The changed
iteration count and scale warning are numerical observations; the repeated
family fingerprint is stronger evidence that the underlying degeneracy is not
created solely by the per-unit coordinate choice.

The next trust-gate increment is complete: typed controller evidence is now
validated as its own campaign dimension and carried into the evidence ledger.
Validation distinguishes missing controller coverage, non-finite/invalid
observations, exact versus proxy monitored-voltage semantics, and solver-trace
status/coverage/slope transitions. The matched 30-bus LG Ipopt traces retain
224 finite observations on each coordinate convention and expose 21 slope
transitions as explicit local numerical findings. This makes the benchmark
artifacts ready for the next phase: repeated LN/LG and solver-policy profiling,
with controller transitions correlated against residuals, coordinate units,
and registered equation families.
Trace summaries now retain iteration-level transition pairs: controller local
slope, breakpoint distance, and controller equation residual changes are stored
next to solver primal/dual infeasibility changes and trace phase. The validator
reports how many pairs contain both controller and solver deltas, while leaving
the interpretation explicitly associational. This is the evidence boundary
needed before comparing larger LN/LG corpora or solver policies.
The controller consistency layer is now implemented: persistence and trace
summaries count device-level Volt-var equation residuals and Volt-watt cap
violations against the declared controller tolerance, retaining affected
component/family keys. The five-point LN/LG persistence pair has no such
violations, while the model-native LG trace shows six Volt-var exceedances on
six IBR curves. The next interpretation step is to compare these localized
residuals against registered constraint rows and repeated solver-policy traces;
they remain coordinate-conditioned numerical evidence, not a physical verdict.
Trace-level controller violations now cross-reference the BMOPFTools semantic
row map by device and curve family. In the model-native LG trace, two of six
Volt-var residual-bearing curves match registered `ibr_q_volt_var` rows; four
have no matching registered row. This establishes the next BMOPFTools
registration/benchmark boundary while preserving the distinction between a
numerical residual and a physical diagnosis.
Paired trace comparisons now carry registry-coverage views for both policies.
In the matched LG coordinate comparison, the per-unit side has no residual
crosswalk entries, while the model-native side has two registered and four
unmatched Volt-var curves. This makes semantic coverage a first-class policy
comparison dimension alongside slope, breakpoint, and solver-residual changes.
Solver-matrix summaries now aggregate the same registry crosswalk across all
paired solver cases, preserving per-side status counts and unmatched component
identities. This is the campaign-level boundary needed before scaling the
comparison to broader LN/LG and solver-policy corpora.
The saved-result policy matrix now preserves controller evidence as well:
exact/proxy coverage, status and monitor-semantics counts, family counts,
local slope and breakpoint-distance statistics, equation-residual exceedances,
and cap violations are retained per case and aggregated across policy pairs.
When a saved-result record lacks the BMOPFTools semantic-row registry, the
matrix reports registry coverage as unavailable at this layer; it does not
guess whether a residual maps to a physical equation. Validation and the
evidence ledger retain these policy findings as conditional numerical
observations.
Persistence summaries expose the same aggregate controller fingerprint across
time points, so policy comparisons and persistence reports now share one
coverage/residual vocabulary before solver-trace evidence is introduced.
The draft-corpus saved-result profile path now captures the BMOPFTools scalar
constraint semantic-row map. New policy runs can therefore classify residual
crosswalks as registered or unmatched; legacy records remain explicitly
unavailable. This is the bridge from numerical controller evidence to the
engine-side registration boundary without assigning physical causality.
The persistence path now captures the same map from its staged context, so
multi-point LN/LG reports can distinguish registered and unmatched controller
residuals before policy or solver comparisons are generalized.
Policy-matrix summaries now combine child provenance with pairwise controller
evidence and expose readiness flags for successful children, complete indexes,
compatible environments, paired coverage, and controller observation coverage.
The first registry-aware 30-bus LN/LG SI-versus-PU run completed with both
children successful, complete indexes, and one shared environment fingerprint.
Both paired snapshots retained 56 finite exact controller observations. The PU
side showed 28 Volt-var residual exceedances and 28 Volt-watt cap exceedances
per snapshot, versus zero on the SI side; across the two cases, 24 violating
observations cross-referenced registered rows and 88 were unmatched. These are
coordinate-conditioned numerical and registry observations, not yet a causal
claim about the export or formulation.
The four-policy extension localizes the controller fingerprint: `pu_all_si`
matches SI with zero controller residual/cap deltas on both snapshots, while
`pu_bus_si` removes all LG violations and leaves five LN Volt-var residual
exceedances (three unmatched and two registered). Plain PU retains the full
56-residual/cap delta across the pair. This is controlled evidence that the
broad field-unit policy, rather than bus-voltage conversion alone, removes the
observed controller discrepancy; it remains a formulation/export hypothesis
until field-level attribution and additional cases confirm it.
The next four time points reinforce the pattern: `pu_all_si` again has zero
controller deltas, while `pu_bus_si` adds 112 Volt-watt cap exceedances and 14
Volt-var residual exceedances across LN/LG t02--t03. The residuals concentrate
in LN t03 (14 residuals; the combined violations have eight registered and 34
unmatched crosswalk observations),
whereas the cap discrepancy persists on all four snapshots. Plain PU retains
the full 28-per-snapshot residual/cap pattern. Across all six selected
snapshots, broad field conversion remains the only tested policy matching SI
for these controller checks.
The paired SI/PU field-ratio report for the same snapshots shows why the
policy matrix must remain field-aware: `line/s_through` is approximately
1e-6 in PU/SI magnitude, while `ibr/pg`, `ibr/cri`, and `ibr/cii` are mixed
scale families. The ratio evidence is retained beside the policy matrix; it
does not by itself identify which exported field is wrong.
The policy-matrix launcher now carries child-index provenance into its
manifest: resolved unit policies, child case-status counts, environment
fingerprints, and index availability are validated before pairwise evidence is
trusted. This closes the process-level gap between an apparently successful
policy child and a comparable saved-result campaign.
The next scale-up, a four-policy matrix on one 99-bus LN and one 99-bus LG
snapshot (dense rank disabled), completed with four successful children, a
complete child index, and one shared environment fingerprint. `pu_all_si`
again matched SI for controller residual/cap counts, while plain PU added 96
residual and 96 cap violations across the pair. `pu_bus_si` removed the cap
delta but retained 43 equation-residual violations, so bus-voltage conversion
alone is not sufficient on this larger pair. These are repeatable numerical
observations under the saved-result tolerance policy; the validation report
keeps them as warnings rather than causal conclusions.
The 99-bus registry crosswalk was available for all 24 controller snapshots,
but 498 violating observations were unmatched and 207 matched registered
semantic rows. That boundary is now visible in the evidence ledger and must be
resolved or narrowed before assigning component-level physical meaning.
The paired field-ratio report adds a scale fingerprint: `line/s_through` is
approximately 1e-6 in PU/SI magnitude, while `ibr/pg`, `ibr/cri`, and `ibr/cii`
remain mixed-scale; `opt_profile/min_active_multiplier` is roughly
3.1e-3--4.5e-3 and `max_shadow_price` is about 2.0--2.4. These ratios are
observations for attribution, not a unit-convention verdict.
The bounded 538-bus follow-up is now complete: the timed-out `pu_all_si` child
was rerun with a larger explicit budget, producing four successful children,
complete indexes, and a shared environment fingerprint. The full matrix
validation is warning-only because the semantic crosswalk remains incomplete.
Across the LN/LG pair, plain PU adds 604 residual and 604 cap violations,
`pu_bus_si` removes the cap delta but leaves 402 residual violations, and
`pu_all_si` matches SI for both controller counts. These are larger-case
numerical observations with a clearly recorded registry boundary, not causal
proof about the formulation.
The corresponding 538-bus ratio report shows `line/s_through` near 1e-6,
mixed-scale line-current and IBR families, and much larger policy-dependent
shadow-price/multiplier ratios; dense rank remains intentionally unavailable.

The first paired solver-policy trace matrix is also complete on a 30-bus LN
snapshot: Ipopt and MadNLP both terminated successfully under one environment
fingerprint (19 versus 21 iterations, aligned final objective and residual
scales). Ipopt supplied 16 controller callback snapshots with 58 Volt-var
residual exceedances; MadNLP's public callback supplied solver metrics but no
primal iterate bindings, so its controller snapshot side is explicitly
unavailable. The solver matrix summary now carries child-index and comparison
readiness gates, while validation preserves this asymmetry as a warning.
Repeating the same matrix on matched 30-bus LN/LG snapshots produced four
successful children under the same fingerprint: Ipopt used 19 iterations on
each case, while MadNLP used 21 (LN) and 22 (LG). Final objectives remained
aligned to relative differences below 4e-9. Ipopt retained 58 Volt-var
residual exceedances on each case; MadNLP remained metric-only, so the
solver-policy result is a repeatable trace observation with asymmetric
controller coverage, not evidence that one solver is better.

The multiconductor fixture path is now trust-gated as its own campaign. A
five-fixture BMOPFTools/OpenDSS smoke run completed with dense analysis
disabled, all port/current/constitutive contracts available, and 14 physical
mode declarations. Neutral and delta fixtures expose `common_mode`; the
wye-delta case also exposes `delta_common_mode` and a phase-aware complex
constitutive map. The source loader retained 67 schema warnings about dropped
OpenDSS fields, which are now preserved in the records and surfaced as a
warning rather than silently disappearing.

The generic operator/domain fingerprint smoke corpus is now executable through
`benchmarks/operator_fingerprint_smoke.jl`. It covers negative-tail
`log1exp`, invalid `log`, ratio-based `atan`, `atan2` branch cuts, non-unit
circular equalities, and partially guarded `logdiffexp`. Each case is checked
at the static, numerical-expression, and explicit-initialization stages. The
resulting artifact (`/private/tmp/nlpdiag-operator-fingerprint-smoke.json`)
records six successful cases, including softplus value/derivative underflow,
operating-point domain/nonfinite evaluations, `atan` denominator and branch
risks, the non-unit radius fingerprint, and initialization boundary findings.
This is a deterministic regression corpus for operator semantics; its
findings remain evidence, not a model-quality score.

The corpus now has a first-class normalization and trust gate through
`benchmarks/summarize_operator_fingerprint.jl` and the campaign validator.
The normalized six-case report is complete across static, expression, and
initialization stages, validates with zero errors and zero warnings, and can
be added to the source-aware evidence ledger as `operator_fingerprint`.

The multiconductor smoke path now runs the BMOPFTools physical-mode analysis
explicitly. Five zero-dense-budget fixtures produced five structural mode
analyses and 14 declared physical modes, while the summary correctly marks
local expected-versus-observed comparison as unavailable because the dense
Jacobian budget is disabled. A one-fixture 5,000-entry dense run demonstrates
the complementary boundary: numerical rank is available, but two declared
wye common-mode directions cannot yet be aligned to the free model-coordinate
scope. This is retained as a coordinate-mapping warning, not misclassified as
an absent physical mode.

The generic expected-mode comparison now reports partial-alignment details
before emitting the unaligned boundary: aligned and dropped coordinate counts,
coefficient norms, and the aligned fraction are preserved as evidence. This
makes fixed-coordinate restrictions inspectable without silently projecting a
physical mode and calling the projection an observed gauge.

The multiconductor smoke runner now exposes an opt-in sparse iterative
right-nullspace probe (`NLPDIAGNOSTICS_BMOPF_ITERATIVE_RIGHT_PROBE_DIMENSION`
and an iteration budget). A five-fixture run with dimension 2 and 30
iterations completed all probes without dense rank work: all probes were
available, none converged within the budget, and none produced a small-
residual candidate. This is useful negative evidence about the selected
operating points, not a nullspace certificate.

Probe summaries can now be compared with
`benchmarks/compare_bmopf_multiconductor_probes.jl`, including fixture
coverage, environment and dimension compatibility, convergence changes, and
minimum residual deltas. Comparing the five-fixture 30-iteration and
200-iteration campaigns is fully paired and trust-valid: none of the probes
converged, but minimum residual norms decreased on every fixture (roughly
0.04--0.45 in the recorded residual scale). This is a reproducible sparse
numerical trend, not evidence of rank loss or a physical nullspace.

Source-schema warnings are now attributable by fixture, scope, field, and
message rather than only counted. In the
five-fixture smoke corpus, the 67 retained warnings are concentrated in
`load` records (44), `voltage source` records (15), and line/linecode records
(4 each); the most frequent dropped fields are `kv`, `phases`, `vmaxpu`, and
`vminpu` (11 each). The validator and evidence ledger preserve the complete
fixture, field, scope, and message maps, so these representational losses can
be reviewed separately from numerical probe behavior.

The same warnings now have an impact classification and a physical-metadata
readiness gate. In this corpus, 8 warnings are units-only
`representational` losses, while 54 are `physical_or_operating_point` and 5
are `device_semantics` losses. The campaign consequently remains numerically
usable for contract and probe observations but is not marked ready for
physical interpretation until those source fields are restored or explicitly
accounted for.

The report now carries a field-policy crosswalk as well: units are explicitly
classified as intentionally unsupported provenance, while model fields are
unsupported device semantics and voltage/topology fields are unsupported
physical metadata. This turns the warning into an implementation queue rather
than an undifferentiated import defect.

The smoke runner now preserves a byte-for-byte source snapshot for every
fixture, recording a relative copy path, SHA-256 digest, byte count, and line
count in the result and index. The five-fixture rerun preserved all sources,
so future field-mapping work can be audited against the exact input deck.

Solver-iterate correlation now exposes the same point-level trust boundary at
the row level: every bound iteration records its point fingerprint, provenance
kind/source, and completeness in report metadata, and serialized trace
bindings retain those fields. This makes benchmark aggregation able to
quarantine synthetic or incomplete points without reopening nested records.
The next campaign item is to use these fields in an explicit trusted-point
selector before making physical or cross-case claims.

The first trusted-point selector is now available in the generic core. Its
default policy admits only complete, finite solver-iterate and solver-result
points, while retaining all rejected points and reasons for audit. This is a
selection boundary, not a claim that a solver point is physically correct;
campaigns still need their own operating-point and metadata readiness gates.

The solver-trace campaign now reports that boundary explicitly for every
successful case: final solver-result coverage is separated from optional
callback-iterate coverage, and the validator exposes both readiness states.
Trace records are also written through a strict JSON sanitization boundary, so
NaN/Inf observations become unavailable values rather than preventing the
entire benchmark record from being saved. This preserves failure evidence and
the exact input deck is retained with a digest, byte count, and line count.
This allows the next campaign pass to use actual solver points instead of
silently falling back to initialization-scoped profiles.

The solver-trace preflight now carries the same source-schema impact policy as
the multiconductor smoke campaign. Units-only losses remain representational,
while dropped device semantics and voltage/topology fields block the physical
metadata gate. Trace summaries aggregate those fields, scopes, impacts, and
policy statuses, and validation reports `physical_metadata_complete`
separately from numerical and point-provenance readiness.

The isolated trace launcher now injects the in-place package load path into
child processes and preserves child wait errors. A campaign containing only
size-guard skips is no longer vacuously considered solver-ready: validation
requires at least one successful solver-result profile before numerical
interpretation begins.
Campaign manifests are now written after each child, so a later native solver
exit cannot erase completed cases from the index.
Solver-trace summaries now retain child-process health even when a native exit
occurs before a result JSON exists: exit codes, timeout and wait-error counts,
and preserved process-log coverage are reported separately. Validation exposes
`solver_process_health` and emits an explicit process-exit finding, so a crash
or forced termination cannot be mistaken for an ordinary solver termination.
The saved-result SI/PU policy matrix now applies the same operational boundary:
each policy child inherits the in-place package load path, wait failures are
retained, and the matrix manifest is written after every policy. Its summary
and validator expose `policy_process_health`, so a partial unit-policy matrix
cannot be interpreted as a complete paired comparison merely because earlier
children finished.
The Ipopt/MadNLP solver matrix now follows the same boundary. Solver children
inherit the local checkout, per-solver indexes and the top-level matrix
manifest are written incrementally, and native wait/timeout evidence is
retained. Matrix readiness requires successful solver children, healthy
process status, and trusted solver-result coverage for every solver; an absent
MadNLP result cannot be treated as a comparison with an empty trace.

The controller semantic-row gap was traced to an MOI identity bug in the
adapter: `ConstraintIndex.value` is unique only within a function/set type,
but the registry map previously keyed constraints by that integer alone. The
map now includes function and set types and carries them in serialized row
evidence. A fresh 30-bus trace maps all 28 Volt-var and all 28 Volt-watt rows;
the short trace's 11 controller violations all crosswalk to registered rows.
The engine registry has since been extended at construction time for AC KCL,
line KVL, source/ground voltage references, monitored-voltage magnitude
definitions and bounds, and the native device equations and limits already
covered by the staged builders. The regenerated 30-bus LN trace now maps all
844 scalar rows to public semantic keys (844 registered, zero unregistered):
240 KCL rows, 232 line-voltage-drop rows, 112 monitored-voltage rows, 280
device/control rows, and 8 voltage-reference rows. This is a proven coverage
fact for that formulation and fixture, not yet a universal claim for DC,
custom-hook, or less frequently exercised auxiliary formulations.

The first fixture-diversity pass is now complete. All-row identity audits cover
constant-impedance and constant-current ZIP auxiliaries, every existing
two-winding transformer subtype fixture, the three-winding formulation, and
shared-bus plus resistive-branch DC converter grids. The audit exposed genuine
construction-time gaps in load magnitude auxiliaries, n-winding ampere-turn and
leakage equations, DC branch/port/control/KCL equations, and IBR current/DC-link
limits; those rows now receive typed keys when constructed. Native variable
lower and upper bounds are registered uniformly as well. Every JuMP constraint
in these fixtures now cross-checks against a public registry identity.

NLPDiagnostics now exposes `bmopf_constraint_registry_coverage_report` as a
standalone structural gate. It reports complete coverage as formulation-local
information and uncovered rows as representational warnings with exact row and
construction-name provenance. It deliberately does not guess whether an
unregistered row came from BMOPFTools or a caller extension. Caller-added rows
should use `BMOPFTools.register_opf_constraint!`; their names remain provenance,
not semantic evidence.

The rare-builder registry pass now covers DC droop, explicit DC loads and
sources, oriented line-to-neutral and line-to-line DC voltage bands,
transformer thermal/apparent-power auxiliaries, and switch thermal auxiliaries.
That pass exposed late-added native current-box bounds which were invisible to
the original declaration-time registry; BMOPFTools now synchronizes such bounds
before KCL finalization. These fixtures have an exact all-row identity audit.

Registry coverage is now persisted as its own diagnostic report in both corpus
profiles and solver-trace BMOPF profiles. Smoke summaries aggregate its total,
registered, unregistered, and per-family row counts; campaign validation uses
that direct evidence when available and retains the feasibility-attribution
metadata only as a backward-compatible fallback. A registered caller-extension
row is serialized with complete structural coverage in the adapter tests.
Coverage remains a per-formulation gate rather than a package-wide assertion.

The next phase is empirical calibration: regenerate representative small and
medium BMOPF profiles with the coverage gate attached, establish which findings
are stable across initialization and solver points, and reserve dense rank or
nullspace claims for cases within the declared algebra budget.

That phase now has a dedicated point-calibration harness. The launcher runs
isolated, repeated profiles at the BMOPFTools engine start and at explicitly
unit-labelled saved solver results. The summarizer compares exact finding
identity counts, rather than scores, and separates stages expected to be point
invariant (`static`, `expressions`, and `reformulation`) from point-local
numerical, active-set, and degeneracy observations. It retains point and
environment fingerprints, provenance, saved-result mapping completeness,
all-row registry coverage, and the dense-analysis budget for every observation.
Campaign validation treats failed repetitions, mixed environments, uncovered
rows, invariant-stage drift, and missing fully mapped saved points as separate
readiness failures or qualifications.

The next empirical gate is therefore concrete: first establish same-point
repeatability and start-versus-saved-point persistence on a small LN/LG set with
dense algebra disabled; then repeat on a stratified medium set; only then enable
dense rank/nullspace analysis on cases whose declared Jacobian budget permits
it. Agreement of point-local findings remains observed persistence, not proof
of a global mathematical or physical property.

The first calibrated 30-bus LG case has now cleared that small-case gate. Four
isolated observations (two engine starts and two saved-SI results) had identical
environment fingerprints, complete 844/844 semantic row coverage, exact
within-point finding recurrence, and a completely mapped trusted saved point.
All point-invariant stages were unchanged across points. The active-set and
numerical stages changed in eight exact finding identities: most notably, the
saved result removed 56 feasibility violations and the zero-Jacobian-row
warning, while exposing a large row-scale-spread warning. Dense algebra stayed
disabled for the 844-by-704 Jacobian (594,176 potential dense entries). These
are local observations from one fixture, but they demonstrate that the harness
can distinguish initialization artifacts from persistent model structure.

The stratified sparse-only gate has now cleared as well. The corpus contains
24 isolated observations across 30-, 99-, and 538-bus LN/LG cases: two engine
starts and two saved-SI points per case. All six cases had exact same-point
fingerprint, finding, and curated-metric recurrence; complete semantic row
coverage; completely mapped trusted saved points; aligned environments; and no
change in any point-invariant stage. Both the summary and validator passed with
only the informational notice that point-local findings changed.

Eight exact finding changes recurred in all six strata. Saved points removed
the zero-Jacobian-row finding and 1,520 aggregate initialization feasibility
violations, introduced a large Jacobian row-scale-spread finding, and changed
the locally active structural classification from underdetermined to
overdetermined. The sparse-QR rank remained at full column rank in every case:
704 for 30-bus, 1,968 for 99-bus, and 11,028 for 538-bus. These observations
therefore do not support a whole-Jacobian rank-deficiency diagnosis.

The sparse-QR condition proxy is point-sensitive and size/connection-sensitive.
It changed only slightly on both 30-bus cases and 99-bus LG, but increased by
about 4.78x on 99-bus LN, 7.22x on 538-bus LG, and 17.68x on 538-bus LN at the
saved point. This is repeatable local numerical evidence, not yet proof of poor
physical conditioning: equation-family scaling and unit semantics must be
attributed before interpreting the LN/LG asymmetry.

The budgeted dense gate also passed on eight observations from the eligible
30-bus LN/LG pair. Dense rank and sparse QR agree at rank 704 at both starts and
saved points. The active row count changes from 676 to 732, active-Jacobian rank
from 648 to 704, equality rank used by the MFCQ screen from 620 to 676, and the
active DM view from a 556-row/584-variable underdetermined region to a
520-row/492-variable overdetermined region. The aligned equality-Jacobian rank
used by degeneracy analysis changes from 436 to 464, while structural matching
rank remains 668. These quantities describe different aligned views and must
not be substituted for the full-Jacobian rank.

The campaign also exposed an orchestration failure: grouping several cases in
one child allowed a slow case to consume the timeout and discard otherwise
valid evidence. Explicit selections are now isolated per case. Campaigns can
resume only when root, project, policies, repetitions, and case selection match;
successful children are reused, while retries retain attempt number, elapsed
time, and prior failure logs.

Equation-family scale attribution is now implemented and has passed its first
repeated calibration. The generic routine groups evaluated Jacobian rows by
caller-provided semantic labels and reports robust row infinity-norm evidence;
the BMOPFTools adapter supplies those labels only from its public constraint
registry. The corpus runner persists the evidence and the v2 calibration
summary checks same-point recurrence, exact cross-point changes, direction-
based cross-case recurrence, and stable family metrics. The validator now
requires both attribution coverage and same-point family-scale stability.

Eight fresh 30-bus LN/LG observations passed every readiness gate with zero
family-scale repeatability failures and complete 844/844 row semantics. The
line voltage-drop families retain the global largest row norm, about 4.585, at
both engine and saved points. The new large row-spread warning at the saved
point is instead attributable to the 28 `ibr_power_circle` rows. At the engine
start all 28 circle rows have zero derivatives; at the saved point they become
nonzero but extremely small. Their smallest row norm is about `2.77e-8` in LG
and `9.35e-9` in LN, producing global row-spread ratios of about `1.66e8` and
`4.90e8`, respectively. The same transition recurs in both connection
variants and is exactly repeatable at each point.

This sharpens the earlier numerical interpretation. The saved-point row-scale
warning is an operating-point effect in a declared IBR apparent-power-circle
family, while the 30-bus sparse-QR pivot proxy changes only slightly and the
full Jacobian remains full column rank. It is therefore not evidence of a
whole-Jacobian singularity, and the enormous raw row-norm ratio must not be
reported as a condition number. The next controlled experiment should rescale
only the identified circle rows in the recorded linearization and compare
sparse-QR and solver/KKT evidence; the same attribution must then be repeated
on the 99- and 538-bus cases before explaining their larger condition-proxy
changes.

The first part of that controlled experiment is now complete. A new opt-in
Jacobian intervention normalizes only explicitly named semantic row families,
with the experiment policy included in corpus fingerprints and calibration
resume checks. On eight repeated 30-bus LN/LG observations,
`ibr_power_circle` normalization was unavailable at the engine starts for the
correct reason—all 28 rows were exactly zero—and available and exactly
repeatable at both saved points. It required factors ranging from roughly
`1.27e3` to `1.07e8` in LN and `2.10e5` to `3.61e7` in LG, yet preserved rank
704 and reduced the sparse-QR pivot proxy only from about 20.764 to 20.167, a
ratio of about 0.971 in both cases.

This separates two phenomena that the earlier warning could not. The IBR
circle family causes the enormous raw row-norm spread at the saved point, but
normalizing it changes the sparse-QR proxy by less than three percent and does
not change rank. It is therefore unlikely to explain the larger 99-/538-bus
condition-proxy increases by itself. The next empirical target is to run the
same semantic attribution on those cases, identify their minimum-row families,
and intervene only on recurrent candidates before moving to solver/KKT traces.

Saved-result component matching is now exact as well (`pv_1` no longer matches
`pv_10`). A fresh one-case SI/PU matrix reports 56 registered controller
violation crosswalks and zero registry-boundary cases. Its remaining warning
is the actual SI/PU controller-residual delta, now separated from registry
ambiguity.
