# Development roadmap

This roadmap orders work by the evidence needed for later claims. A numerical
or physical interpretation should not be implemented before the structural and
evaluation layers can expose its supporting evidence.

The roadmap tracks implementation order. The separate
[`nondimensionalisation_research.md`](nondimensionalisation_research.md) is the
living scientific ledger for flexible physical bases, residual-block scaling,
and complex transformations. It retains hypotheses, invariants, rejected ideas,
experiment protocols, and the current publication boundary as results evolve.

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

### Immediate execution sequence after the review

The next major increments are deliberately narrower than the historical
feature roadmap:

1. preserve solver telemetry and its scaling semantics end to end;
2. repair the solver-option campaign so every profile is a distinct,
   controlled intervention and initialization is separated from later
   trajectory behavior;
3. replace loosely related numerical keywords with typed, serializable policy
   objects and add extension-enabled CI lanes;
4. complete the operator-based nullspace backend and validate it against the
   guarded dense reference corpus; and
5. run a truth-labelled BMOPF calibration matrix before promoting any new
   physical classifier.

The first increment is implemented: Ipopt callback traces now retain barrier
parameter, step norm, regularization size, dual step, and line-search trials;
MadNLP retains the corresponding publicly available barrier, regularization,
and dual-step quantities. Every record carries explicit metric-coordinate
semantics, and serialized traces report telemetry coverage instead of making
missing columns indistinguishable from zero.

The second increment is also implemented at the harness level. The default
Ipopt profiles now use three distinct explicit option sets. Summary schema v3
separates the first captured callback residual, subsequent peak,
phase-conditioned post-first peaks, and final captured residual. A shared
initial iterate can therefore no longer make two
different solver trajectories appear identical merely because the global
maximum occurred at iteration zero.
Evidence-ledger promotion now has a matching negative-result gate: trajectory
stability is recorded only for a distinct-option v3 campaign with complete
manifest, baseline-pair, and row-family trajectory coverage. Historical
schemas become legacy smoke observations and incomplete v3 runs become explicit
coverage observations.

The typed-policy part of the third increment now has a working end-to-end AC
truth gate. BMOPFTools has explicit SI, classic per-unit, and custom consistent
per-unit policy types, validates topology/base compatibility, and records the
effective policy in research provenance. NLPDiagnostics maps public BMOPFTools
semantic variable and constraint keys to physical scales, transforms scalar
sets and violations as well as functions and derivatives, and blocks geometry
comparison when coverage or covariance is incomplete. A small classic-versus-
custom fixture passes every physical gate, while a changed physical line
coefficient is rejected. Remaining before corpus-wide comparative scaling
claims are trusted: extract side-specific endpoint duals, complete physical
complementarity/KKT acceptance, and run matched solver campaigns under those
contracts. Transformer/n-winding/DC coverage and four-policy shared-state
transport are completed in the later checkpoints below.

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
- the extension-enabled package test suite contains more than 1,500 assertions
  at this review boundary.

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

Current status (2026-08-11): `RankPolicy`, guarded dense SVD, SuiteSparseQR,
backward residuals, and the calibration corpus are implemented. A typed local
Jacobian operator now preserves `:assembled_sparse` versus
`:hybrid_moi_jacvec` provenance. The hybrid path uses public MOI forward and
transpose products only after a deterministic consistency screen against the
assembled entries; incomplete/non-finite rows are unavailable and callback
disagreement falls back explicitly. Existing right, left, and spectrum probes
now use this boundary and publish their operator source. A fully
reorthogonalized Golub--Kahan Ritz projection is also implemented on that
boundary. It publishes recurrence coefficients, projection residual,
left/right orthogonality loss, lifted primal/dual Ritz residuals,
dimensionless backward errors, and directly screened projected-null
candidates. A deterministic multi-seed layer now retains each seed's raw
projection, consolidates only directly screened candidates, audits the
consolidated basis against the full operator, compares nonempty seed subspaces
by principal cosines, and enforces a pre-allocation basis-storage guard. A
typed dense-SVD oracle comparison records misses, over-capture, equal-dimension
subspace disagreement, and agreement under an explicit `RankPolicy`.

On the current five-matrix exact/rectangular/clustered/zero corpus, a six-seed
full-column budget reproduces all five dense right-nullspace dimensions and
aligns every nonempty candidate span. The deliberate one-step negative control
misses three of four rank-deficient cases; the zero operator is recovered from
the independent starts. This measured failure is retained as a regression
test and prevents absence of a candidate from becoming a full-rank claim.
An independent smallest-singular candidate backend is now implemented. It uses
Golub--Kahan-generated right trial spaces, a zero-target harmonic generalized
projection, thick restart, projected-metric diagnostics, and direct
physical-coordinate audits. None of the current operator probes is a rank
certificate.

The operator boundary, finite Golub--Kahan projection, deterministic multi-seed
coverage layer, and first dense-oracle disagreement table are therefore
complete. A restarted locally optimal block candidate tracker is now also
implemented. It uses only `J*v` and `J'*u`, retains value, normal-residual,
backward-error, and subspace-alignment histories, and distinguishes repeated
dense target subspaces from alignment failures. It does not assemble `J'J`, but
its Rayleigh--Ritz search still inherits the squared normal spectrum.

The first executable adversarial corpus contains ten cases. Five have ordinary
dense agreement, two have agreement with explicitly non-unique target
subspaces, two are expected unconverged controls, and one is an expected dense
singular-value disagreement. The disagreement is scientifically important: on
the 6-by-6 Hilbert matrix the tracker meets its internal stationarity policy at
approximately `3.62e-6`, while dense SVD reports approximately `1.08e-7`.
The badly scaled `diag(1e8, 1, 1e-8)` case stagnates rather than inventing a
small direction. These are retained regression outcomes.

The harmonic backend recovers the dense smallest singular direction on the
6-by-6 Hilbert false-convergence control where the normal-operator tracker does
not. A typed dense-free crosscheck now distinguishes backend nonconvergence,
value disagreement, subspace disagreement, and agreement. The ten-case v2
artifact records seven cross-backend agreements plus three required adverse
relations. Guarded dense comparison also distinguishes unresolved targets
below a Float64 spectrum-resolution floor and uses target-local errors for
resolved nonzero singular values.

The remaining numerical-algebra items are corpus and method work: cancellation
at sampled nonlinear points, randomized rectangular matrices, repeated-point
scaling stability, and BMOPF sparse-product campaign summaries. A third vetted backend
(Jacobi--Davidson SVD or an LSMR/LSQR-class extraction) remains desirable, but
is no longer the blocker for beginning guarded large-model profiling. All
operator backends remain candidate screens until miss, disagreement, and
stability tables are populated.

The first BMOPF bridge is now implemented. The multiconductor smoke runner can
opt into the restarted/harmonic dense-free crosscheck with explicit iteration,
cycle, and basis-storage budgets. Per-case artifacts retain availability,
backend convergence, relation, value differences, and principal-angle evidence;
the smoke summary, validator, and point-policy comparison expose separate
availability and agreement gates. Dense analysis remains disabled independently.
An environment- and point-compatible work-budget comparator separately counts
convergence and agreement gains/losses, so increasing numerical work is not
confounded with changing initialization.
Small fixtures can additionally request two guarded dense-oracle comparisons,
with the candidate convergence alignment policy kept distinct from the oracle
subspace-alignment policy. This is the arbitration path for converged backend
disagreement; it remains disabled for large BMOPF decks.

The first BMOPF checkpoint is complete. At a fixed completed-start point,
raising the bounded work policy made the harmonic engine converge on both a
grounded-neutral and wye-delta representative, but did not improve restarted
convergence. Dense SVD validated the harmonic result on the full-rank grounded
case and exposed the restarted miss. The 51-by-54 transformer is qualitatively
different: its thresholded rank is 48, rectangularity guarantees three right
null directions, and three additional singular values lie between roughly
`1e-15` and `4e-12`. A dimension-two request was structurally underdimensioned;
a dimension-six request reached internally converged candidates but neither
engine resolved the dense low-end cluster. The scaling intervention described
in the checkpoint below is now complete; repeated-point stability and a third
extraction method remain next.
Physical fingerprinting remains downstream of those results and of source-
schema readiness.
The immediate experimental step is a bounded five-fixture start-versus-zero
campaign, followed by repeated-point and scaling-policy runs. Those runs must
measure relation stability and backend miss/disagreement rates before any
candidate direction is given a physical label.

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
and the 143-assertion core rank calibration block plus the 27-assertion
multi-seed oracle block cover exact, rectangular, zero,
clustered, ill-conditioned, scale-sensitive, absolute-threshold, and
Golub--Kahan residual cases. MOI `:JacVec` integration and the first standard
projection backend are complete. The independent harmonic backend and typed
dense-free crosscheck are also complete. This does not complete the gate:
broader adversarial matrices, nonlinear cancellation cases, a third vetted
backend, repeated-point scaling persistence, and cross-backend corpus-level
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

First CI increment: `.github/workflows/ci.yml` now separates the generic
package matrix from isolated Ipopt/MadNLP and PowerModels/BMOPFTools extension
jobs. The BMOPFTools lane develops the authoritative repository explicitly,
rather than relying on a developer's local path. This closes the configuration
ambiguity, but the gate remains open until the workflow has passed on GitHub
and formatting, documentation examples, Aqua, and targeted JET checks have
their own reviewed policies.

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

Source-schema fidelity is now a first-class BMOPF diagnostic rather than a
benchmark-only counter. `bmopf_source_schema_report(context)` reads the
PowerIO conversion record and emits aggregate, renderer-neutral findings for
physical/operating-point metadata loss, device-semantic loss, intentional
representational loss, and unclassified drops. The report preserves the
source path, affected fields/scopes, policy status, and original warning
messages, so direct callers inherit the same physical-readiness boundary as
the campaign summaries.

A live delta-load smoke check through the updated BMOPFTools engine now
contains the report in both the context profile and physical-mode analysis:
17 conversion warnings are exposed as 15 physical/device-semantic blockers
and 2 representational losses, with the original DSS source path retained.

The BMOPFTools conversion boundary now also preserves a provenance-only field
inventory extracted from PowerIO `extras` records. The live delta-load report
sees nine source-only fields and eight warning fields with provenance; it
explicitly keeps `restoration_ready = false` because provenance is not the
same as an active BMOPF mapping. An optional `powerio_source_mapped_fields`
record is reserved for plugin-owned mappings and is reported separately from
the historical conversion warnings.

The smoke summarizer and validator now carry this distinction to campaign
readiness: source-report availability, provenance coverage, mapped-field
coverage, and unmapped blocking fields are separate gates. The current
delta-load validation is therefore `warn` for the specific mapping gap, while
preserving the numerical and provenance evidence for follow-up work.

The first explicit mappings are now exercised by the live converter: `kv` is
audited against `load.v_nom`, `phases` against the load terminal structure,
and `basekv`/`angle` against the voltage-source magnitude/angle after their
documented unit and phase-sequence transforms. The live source-model contract
also maps OpenDSS `model=ideal` to BMOPF's fixed-voltage boundary, while load
model codes are mapped to the corresponding BMOPF constitutive law. The
remaining delta-load blocking fields are `vminpu` and `vmaxpu`; they remain
unmapped as bus bounds on purpose, so this batch closes the
provenance-to-mapping audit trail without claiming physical readiness.

The BMOPFTools regression suite now checks this contract directly, including
scope inventories and metadata survival through a BMOPF JSON round trip. The
suite also records the expected broken/optional cases separately from actual
failures, so missing optional solver integrations do not masquerade as core
conversion regressions.

The mapping record is now a complete warning-field ledger: mapped entries are
listed alongside explicit `unmapped` entries with impact, blocking status, and
reason. This makes `vminpu` and `vmaxpu` visible as deliberate semantic gaps
rather than silent omissions, while `units` remains explicitly non-blocking
representational metadata.

The ledger now supports scope-level partial mappings. OpenDSS ZIP loads map
their model code and `zipv` coefficients into BMOPF `model`/ZIP fields, while
the voltage-source `model=ideal` is recognized as the fixed-voltage-boundary
contract represented by BMOPF; unsupported source models would remain
unmapped. The aggregate model field is therefore mapped for the current
fixtures.

The smoke campaign now includes a dedicated `zip-load` fixture. Its live
profile maps `zipv` completely and reports only `vminpu` and `vmaxpu` as
blocking source-schema gaps, demonstrating that the campaign distinguishes
load-model fidelity from voltage-behavior limits.

The source-semantic report now preserves normalized observations for every
fixture: ordered `vminpu`/`vmaxpu` load thresholds are recorded as
load-behavior evidence (never as BMOPF bus bounds), and `model=ideal` source
records carry the explicit fixed-voltage-boundary contract. These observations
make the next physical-readiness step measurable without silently changing the
optimization model.

The next boundary is explicit in retained metadata rather than another
BMOPFTools public function. NLPDiagnostics decodes an observation-only contract
and an opt-in non-mutating terminal-voltage-ratio plan with topology and
nominal-voltage context. No candidate is added to the original JuMP/BMOPF model;
materialization remains a deliberate auxiliary-problem decision for a later
plugin or benchmark stage.

That auxiliary boundary is now implemented for staged BMOPF contexts:
`bmopf_source_behavior_auxiliary_model` builds a separate JuMP model with
explicit real/imaginary terminal-voltage variables and squared-magnitude lower
and upper rows. The six-fixture campaign materializes 14 constraint pairs,
records zero mutations of the original models, and keeps the validator at
`warn` only for the still-unmapped source fields. Solving and interpreting
these auxiliary problems remains opt-in; their rows are diagnostic candidates,
not new constraints in the production formulation. The typed report path now
evaluates each materialized threshold at the profile point and records any
domain violation as a finding. An optimizer can be supplied separately to
solve the isolated model, with unavailable solver state kept distinct from
model infeasibility.

The smoke campaign now supports a controlled solver-backed auxiliary policy.
`NLPDIAGNOSTICS_BMOPF_SOURCE_BEHAVIOR_SOLVER=none` preserves the default
solver-independent run, while `=ipopt` solves only the isolated auxiliary
model. Solver name, attributes, termination status, feasibility, and result
count are serialized per fixture and aggregated separately from the production
BMOPF profile. A bounded ZIP campaign solved its auxiliary model locally with
Ipopt (`max_iter=5`) without mutating the production model; this is now the
baseline for comparing source-domain evidence against solver behavior.

The production solver-trace runner now records the same comparison at its
trusted result point. Trace summaries aggregate classifications and validation
distinguishes a feasible result outside the source domain from a solver failure
that is merely aligned with a threshold violation. This closes the evidence
loop without treating endpoint observations as proof of causality.

The runner also accepts `NLPDIAGNOSTICS_BMOPF_INPUT_FORMAT=dss`, preserving the
PowerIO source contract through a real solve. On the ZIP fixture, the paired
campaign retained three source-behavior candidates and three isolated
constraint pairs; the bounded Ipopt endpoint exceeded all three `vmaxpu`
thresholds while stopping at an iteration limit. The resulting classification
is `solver_failure_aligned_with_source_domain_violation`, explicitly a follow-up
hypothesis rather than a causal diagnosis.

The new source-solver matrix launcher makes budget dependence explicit. A
three-fixture, two-budget run found stable `solver_success_outside_source_domain`
classifications for the grounded-neutral and delta-load decks, while the ZIP
deck changed from `solver_failure_aligned_with_source_domain_violation` at
`max_iter=5` to `solver_success_outside_source_domain` at `max_iter=25`.
That change is exactly the kind of endpoint-versus-formulation distinction the
debugger must preserve.

The expanded six-case rerun completed all cases successfully. Across the
campaign, `angle`, `basekv`, `kv`, and `phases` mapped in all six cases, while
`zipv` mapped in the ZIP case; the remaining blocking counts are six each for
`vminpu` and `vmaxpu`. The validator remains `warn` for that explicit
semantic gap, with no campaign build or integrity failures.

The smoke runner now preserves a byte-for-byte source snapshot for every
fixture, recording a relative copy path, SHA-256 digest, byte count, and line
count in the result and index. The six-fixture rerun preserved all sources, so
future field-mapping work can be audited against the exact input deck.

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
condition-proxy increases by itself. At that stage, the next empirical target
was to run the same semantic attribution on those cases, identify their
minimum-row families, and intervene only on recurrent candidates before
moving to solver/KKT traces; the 99- and 538-bus campaigns below now close that
target.

The repeated 99-bus LN/LG campaign has now refined that conclusion. Eight
observations passed every readiness gate with zero family-scale or intervention
drift. At the saved LN point the 48 `ibr_power_circle` rows own both global
extremes, spanning about `3.14e-9` to `11.14` within that one family. Normalizing
only those rows preserves rank 1,968 but reduces the sparse-QR pivot proxy from
about 183.07 to 36.79 (ratio 0.201), close to the LG and engine-start scale. At
the saved LG point the circle rows own only the lower extreme; the same
intervention preserves rank and changes the proxy from about 37.64 to 36.75
(ratio 0.976).

This LN/LG contrast is exact across repetitions and supplies a formulation-
local numerical explanation for the earlier 99-bus asymmetry. It still does
not prove a physical defect or predict solver convergence: the intervention
acts on a recorded constraint Jacobian, not the complete KKT system or solver
tolerance semantics. That stage's next target was the 538-bus LN/LG pair,
followed by a solver-trace experiment that applies an explicitly documented
constraint-scaling policy and checks residual and iteration consequences; both
are now recorded below.

The 538-bus LN/LG extension is now readiness-cleared with eight dense-disabled
observations (two repetitions at engine start and saved SI for each variant).
All same-point fingerprints, findings, curated metrics, row-family attribution,
and intervention reports repeated exactly; registry coverage and trusted saved
points were complete, and the validator emitted only the expected informational
notice that point-local findings changed. Both 11,028-variable cases mapped all
12,538 rows and retained full sparse-QR rank. At the saved point, the 302
`ibr_power_circle` rows own both global row-norm extremes: the LG range is
approximately `4.60e-9` to `17.42`, and the LN range is `3.45e-9` to `42.95`.
Normalizing only that family leaves rank unchanged and reduces the pivot proxy
from about `251.99` to `34.67` in LG (ratio `0.138`) and from `616.75` to
`34.80` in LN (ratio `0.056`). The intervention was unavailable at engine
start for the correct reason—all circle rows were zero there—and available at
both saved points with the same direction and no rank change. This is now
trusted empirical scale evidence, while remaining a recorded-linearization
intervention rather than a physical or KKT proof.

A bounded Ipopt solver-trace campaign now records the same semantic attribution
and opt-in row-family intervention at the final solver-result point. The two
99-bus cases both solved locally in 19 Ipopt iterations with no restoration
attempt, and the parsed logs reached final primal infeasibility below `7e-16`
and dual infeasibility below `2e-13`. The saved LN result again assigns both
row-scale extremes to `ibr_power_circle` (within-family ratio about `1.54e4`),
while the LG result assigns the minimum to that family and the maximum to the
voltage-magnitude definition family. The LN-only recorded-Jacobian intervention
reduces the proxy from about `183.05` to `36.82` (ratio `0.201`), whereas LG
changes from `37.64` to `37.36` (ratio `0.993`); rank is unchanged in both.
These are correlated final-point observations, not causal solver evidence: the
trace currently does not rescale Ipopt's KKT system or rerun the solve under
the intervention. The next major item is therefore an actual solver option A/B
experiment that changes constraint scaling while preserving residual and
termination semantics, followed by a repeated 538-bus solver trace so that
the numerical attribution and solver behavior can be compared on the same
trusted points; that A/B experiment is reported immediately below.

The first actual solver-scaling A/B campaign is now complete on the 99-bus
LN/LG pair. Three isolated Ipopt configurations shared one environment and
captured logs, callback points, semantic row attribution, and the recorded
`ibr_power_circle` intervention. The default configuration solved both cases
in 20 iterations. Setting `nlp_scaling_method=none` remained locally optimal
but required 29 LN and 28 LG iterations; tightening
`nlp_scaling_max_gradient=10.0` required 17 iterations for both. Final
objectives stayed aligned with the baseline (relative differences below
`4e-7`), and all printed primal residuals were below `7e-16`; dual residuals
remained finite. The family intervention continued to preserve rank 1,968 and
the LN/LG proxy contrast in every configuration, so the solver option changes
altered iteration behavior without changing the underlying semantic diagnosis.
This is genuine solver-level evidence for scaling sensitivity, but only on one
snapshot per formulation; the bounded 538-bus follow-up below was the next
campaign.

The bounded 538-bus follow-up now supplies the first large-case solver-level
contrast. With `max_iter=40`, default Ipopt scaling solved LN in 25 iterations
and LG in 20, with final printed primal residuals below `5e-14` and dual
residuals below `1.3e-11`. The otherwise identical
`nlp_scaling_method=none` runs reached the iteration limit on both cases
(41 trace records), with printed primal residuals around `8e-3`, dual
residuals of `2.0e9` (LN) and `8.7e8` (LG), and explicit
`solver_termination_limit`, residual-stagnation, regression, and imbalance
findings. The final objectives are intentionally not aligned because the
no-scaling runs did not solve the model. This is strong solver-level evidence
that Ipopt's internal scaling is materially important for these 538-bus
formulations, while the semantic row-family attribution remains a separate
diagnostic: the failed runs ended at different, non-solution points. The next
step is repeated bounded A/B runs and a controlled 538-bus matrix including a
tighter scaling cap, so the solver effect can be separated from run-to-run
variation.

The sweep campaign now has a first-class aggregation artifact rather than
requiring pairwise inspection. `summarize_bmopf_solver_sweep.jl` reads the
orchestrator manifest, retains common and effective solver options, verifies
environment-fingerprint and case-matrix completeness, and emits one comparison
row per configuration and case. Objective alignment is reported as
`aligned`, `different_convention_or_solution`, or `unavailable`; residual and
iteration changes remain raw deltas/ratios; and family scaling intervention
ratios/rank changes remain attached to their evidence. This makes a multi-option
campaign auditable without collapsing it into a performance score. The 99-bus
campaign produces a complete two-case matrix with matching fingerprints for all
three configurations.

A direct follow-up with the same 538-bus solver bound exposed an important
readiness limitation: the Ipopt log can reach `EXIT: Optimal Solution Found`
while the subsequent full profile serialization is still resource-limited and
does not write a case result. Those partial directories are deliberately not
counted as solver evidence. The engineering response was an incremental
checkpoint path and an explicit `profile_incomplete_after_solver` status, so a
successful solver termination cannot be confused with a complete diagnostic
observation; its implementation is recorded below.

That readiness item is now implemented. Each solver-trace case writes a
checkpoint through `started`, `solver_complete`, `profile_started`, and
`complete`; the isolated launcher carries it into `index.json`; and the
summarizer classifies a missing result after solver completion as
`profile_incomplete_after_solver`, with separate profile-completeness counts.
A synthetic partial record and a size-guarded 538-bus launcher run both pass
through this path. The next large-case work can therefore distinguish solver
behavior from diagnostic-profile resource failure without discarding the
campaign provenance.

Staged profiling is now available through
`NLPDIAGNOSTICS_BMOPF_PROFILE_MAX_VARIABLES`. When a case exceeds the explicit
profile budget, the runner uses the lightweight solver-only callback path and
writes `ok_solver_trace_profile_skipped`, retaining iteration records, solver
logs, termination evidence, and checkpoint provenance while marking the
semantic/rank profile as `profile_skipped_resource_budget`. A real 30-bus run
validated this mode with 19 trace records and final logged primal/dual
infeasibilities of approximately `3.3e-16` and `4.3e-14`. The summarizer keeps
these records in `solver_trace_case_count` but not `successful_case_count`, so
solver evidence and full diagnostic readiness remain distinct.

The stage is also explicitly selectable with
`NLPDIAGNOSTICS_BMOPF_PROFILE_STAGE=trace|context|numerical|full`, so a campaign
can request solver-only capture, BMOPF semantic/context diagnostics, or a
bounded solver-result numerical profile independently of model size. A
validated 30-bus context-stage run retained 19 solver records
and 26 `component_port_nominal_scale_mismatch` context findings without a
generic Jacobian/rank profile. Both the requested stage and budget/skip reason
are retained in the case, launcher, and sweep records.

The corrected v4 multiconductor option campaign is now complete on the
free-neutral and delta fixtures. All 24 cells passed artifact, trajectory, and
model-semantic invariance gates under one solve-time content fingerprint. The
free-neutral case was stable. The zero-start delta case distinguished monotone
from adaptive barrier behavior at five iterations, including small but
material-under-policy KCL/line-voltage trajectory changes; the difference
disappeared by 25 iterations, and the two adaptive globalizations agreed.
This is now a useful bounded solver-method profiling case.

The same campaign exposed a higher-priority multiconductor metadata gap: the
balanced delta case's near-zero neutral coordinates inherited the port-wide
1 p.u. phase scale. That gap is now closed. Ordered
`PortTerminalCoordinateSemantics` overrides the port scale per terminal,
explicit ground references carry zero targets and tolerances, and ungrounded
neutrals carry no phase-scale assumption. Generic map projection validates the
ordering and reports expected-value violations separately. BMOPFTools tests
cover grounded-zero, grounded-nonzero, near-zero floating-neutral, and
materially displaced floating-neutral controls; no variable-name or generic
near-zero suppression is used. A fresh 25-iteration monotone/native-start delta
run checked 42 terminal scales and eight ground-reference values, retained 12
intentionally unscaled neutral mappings, and emitted neither of the scale or
expected-value mismatch codes.

That full v4 regression matrix is now repeated from one frozen development-tree
state. All 24 observations, 16 baseline comparisons, and eight direct
adaptive-profile comparisons passed their artifact, trace, pairing, and
multiconductor semantic gates under one environment fingerprint. Neither
terminal mismatch code occurred anywhere, scale projection remained available,
and no model-semantic contract changed. The earlier numerical behavior was
preserved: the five-step monotone/zero-start delta cell alone remained
failure-classified, both adaptive profiles resolved it, all profiles agreed by
25 iterations, and the adaptive profiles were mutually identical. The small
zero-start delta KCL/line-voltage trajectory differences also reproduced. This
closes the terminal-semantics regression item.

The next multiconductor trust item is no longer another metadata layer. It is
to compare plugin-declared visible/hidden port modes with observed Jacobian
candidate subspaces at physically justified solver-result or captured-iterate
points, first on truth-labelled small fixtures and then on sparse-guarded BMOPF
cases. Dense SVD remains the small-fixture oracle; the new multi-seed
Golub--Kahan layer may supply candidates on larger cases only after its broader
adversarial calibration table is populated.

The bounded numerical stage is now validated as well. On the same 30-bus LN
case it retained 19 solver records and emitted numerical findings for finite
difference derivative provenance and mixed Jacobian provenance; sparse QR rank
was available at 704 while the dense rank estimate was explicitly unavailable
under the configured entry budget. This is the intended evidence distinction:
the stage reports what was computed, rather than implying that a skipped dense
rank is a nonsingular result.
The fresh runner artifact also records the 250,000-entry budget and its
environment-variable provenance, and closes the staged checkpoint as
`complete`; the trace summarizer reports no failure category for this
resource-bounded numerical run.

The option-sweep orchestrator now writes its manifest after every completed
configuration, not only at normal shutdown. A two-configuration size-guarded
smoke confirmed that the first configuration remains recoverable even when a
later child does not return. This closes the campaign-level provenance gap;
the remaining large-case bottleneck is post-solve profile resource usage, not
loss of the sweep record.

Saved-result component matching is now exact as well (`pv_1` no longer matches
`pv_10`). A fresh one-case SI/PU matrix reports 56 registered controller
violation crosswalks and zero registry-boundary cases. Its remaining warning
is the actual SI/PU controller-residual delta, now separated from registry
ambiguity.

Numerical-stage sweep comparison is now first-class. The option-sweep summary
retains per-case sparse-QR versus dense-rank availability, raw rank changes,
rank-readiness transitions, and finding-code deltas, with explicit provenance
for dense-budget limitations. Its aggregate coverage separates unavailable
reports from sparse-ready and dense-ready reports and counts stage/readiness
distributions. This is the next trust boundary for paired profiling: solver
option changes can now be compared for numerical readiness without interpreting
missing dense rank as a singular Jacobian or as a successful numerical check.

Repeated solver-policy comparison is now explicit as well. The new
`summarize_bmopf_solver_repeats.jl` aligns repeated sweep manifests by
configuration, case, and replicate index; reports stable termination/status,
iteration ranges and direction signatures; and carries sparse-rank and
numerical-readiness recurrence. It keeps incompatible or incomplete pairs
visible instead of treating a single successful A/B run as repeatable solver
evidence. The next empirical ticket is to run two identical 538-bus trace
manifests containing baseline, no-scaling, and a bounded scaling-cap policy.

Two identical three-policy numerical sweeps on the 30-bus LN fixture now pass
that repeatability gate. Both replicates had the same environment fingerprint,
locally optimal termination, sparse QR rank 704, and
`sparse_available_dense_unavailable` readiness. Relative to baseline,
`nlp_scaling_none` consistently added 2 iterations and the bounded
`nlp_scaling_low` policy consistently removed 2; both effects had zero
iteration spread across the two replicates. This is repeatable solver-policy
evidence on one small fixture, not yet a general scaling recommendation.

The repeated 538-bus LN/LG trace campaign is now complete with the same three
policies and `max_iter=40`, while dense profiling remained disabled. Across two
manifests, baseline reached `locally_optimal` in 25 LN and 20 LG iterations;
no-scaling reached `iteration_limit` in both cases (41 records each) on both
replicates. The bounded scaling cap preserved `locally_optimal`, with LN at 19
iterations (six fewer than baseline) and LG at 21 (one more), consistently in
both replicates. This is strong repeatable solver-level evidence that Ipopt's
scaling policy matters on this larger formulation, but the cap's direction is
case-dependent and must not be promoted to a universal recommendation.
The repeat summarizer now correlates these policy changes with printed residuals:
the no-scaling policy increased final primal residuals by about `8.3e-3`--`8.6e-3`
and dual residuals by `8.65e8`--`2.01e9`, while the bounded cap changed them only
at approximately `1e-14` primal and `1e-11` dual scale. Trace-only runs report
semantic-family availability as unavailable rather than inventing a stable
family fingerprint; a separate context-stage campaign is required before
linking the solver effect to BMOPF equation families.

That context-stage campaign is now complete and repeated. Baseline and the
bounded cap reproduced the same context finding identities on both LN/LG cases:
the port nominal-scale mismatch findings were stable across both replicates.
No-scaling reached iteration limits and repeatedly replaced that pattern with a
small set of port-scale findings plus `bmopf_opf_differentiability_not_ready`
(four paired policy changes across two cases and two replicates). This is
endpoint-conditioned semantic correlation: the solver policy changes the point
at which context is evaluated, but does not establish that the underlying
component metadata changed. The next step is to compare these context findings
with a trusted saved point or a successful no-scaling solve under a larger
iteration budget before assigning formulation meaning.

The endpoint-separation gate is now complete on the 538-bus LN/LG pair. The
point-calibration launcher ran two repetitions at both `engine_start` and
trusted `saved_si` points (eight children total), with dense rank disabled and
all children successful. Every case mapped all 12,538 registered rows, repeated
its point fingerprint and sparse-QR rank (`11,028`), and retained complete
row-family attribution. Point-invariant stages (static, expressions,
reformulation, BMOPF initialization, and generic degeneracy) were identical
across points; only point-local numerical and active-set findings changed.
The saved-point row-scale spread is dominated by the declared `ibr_power_circle`
family: approximately `3.78e9` for LG and `1.25e10` for LN, while the engine
start has zero derivatives for those rows. This is strong, repeatable evidence
that the large spread and associated numerical findings are operating-point
effects, not structural changes. It remains an empirical local observation,
not a proof of solver causality or physical ill-conditioning.

The next major ticket is solver-result triangulation: join this trusted
start/saved comparison with the repeated Ipopt trace and context campaigns,
then run a larger-iteration no-scaling policy only where the trace ended at an
iteration limit. The objective is to test whether endpoint-conditioned findings
persist at a successful no-scaling solution before making any formulation
recommendation.

The successful-endpoint gate has now been tested on a stratified corpus: the
30-, 99-, and 538-bus LN/LG `t01_0800` cases. With dense algebra disabled, a
single no-scaling policy (`max_iter=300`) reached successful termination on all
six cases (21/21 iterations at 30-bus, 29/28 at 99-bus, and 131/85 at 538-bus).
The endpoint-triangulation report joined separate trusted start/SI calibration
campaigns and classified all six solver endpoints as matching their saved-SI
semantic finding maps. There were no endpoint-conditioned cases in this
successful corpus run. This is the first cross-size evidence that the earlier
iteration-limit semantic changes were not formulation changes.

`benchmarks/summarize_bmopf_endpoint_triangulation.jl` now accepts multiple
trusted calibration summaries through
`NLPDIAGNOSTICS_BMOPF_TRIANGULATION_CALIBRATIONS`, preserving per-case
matching, termination, residual, and endpoint-trust evidence. The next major
ticket is repeated-policy triangulation on this stratified set (baseline,
bounded scaling, and no-scaling) so that successful endpoint persistence and
iteration-limit warnings are summarized together rather than inspected by
hand.

Solver-result triangulation is now complete for the 538-bus LN/LG pair. A
no-scaling run with `max_iter=100` reached `locally_optimal` on LG in 85
iterations, with final printed primal/dual infeasibilities of about
`2.5e-14`/`5.0e-12`. Its context findings returned exactly to the baseline
fingerprint (`207` port-scale findings). LN still hit the iteration limit at
100 iterations, so the budget was extended to 300; it then reached
`locally_optimal` in 131 iterations with residuals about `1.0e-15`/`5.7e-13`
and exactly the baseline context fingerprint (`163` port-scale findings).
The differentiability finding and the small port-scale finding set seen at the
40-iteration no-scaling endpoint therefore disappear once the solver reaches
a successful endpoint. This is repeatable evidence that those earlier changes
were endpoint artifacts, not formulation or metadata changes.

The practical trust rule is now explicit: interpret solver-policy semantic
differences only after either (a) the policy reaches a successful endpoint, or
(b) the comparison is labelled iteration-limit/endpoint-conditioned. The next
major item is to generalize this successful-endpoint triangulation to a small
stratified BMOPF corpus and then add automated paired-trace/context persistence
checks to the campaign validator.

The repeated three-policy stratified campaign is now complete. Two identical
sweeps covered the six 30/99/538-bus LN/LG cases with baseline, the bounded
`nlp_scaling_max_gradient=10` policy, and no-scaling at `max_iter=300`. All 36
policy/case observations reached `locally_optimal`, and every policy/case
semantic fingerprint was identical across the two repetitions. Relative to
baseline, bounded scaling changed iterations by -6 to +1; no-scaling changed
them by +2 to +106, with the largest increases on the 538-bus cases. The
paired repeat summary recorded zero termination changes and zero semantic
finding changes for both candidates. Endpoint triangulation classified all 18
policy/case results as matching trusted saved-SI semantics.

This is strong empirical evidence that scaling policy affects solver work
while the successful endpoint semantics remain stable on this corpus. It is
not a universal solver recommendation: no-scaling required a much larger
budget on 538-bus LN/LG, and all conclusions remain tied to the captured
environment, options, and snapshots.

The next major item is to extend the same repeated policy matrix to numerical
stage profiles (sparse rank, row-family scale, and condition proxy), retaining
the context-stage endpoint gate rather than conflating solver effort with
Jacobian evidence.

A controlled dense checkpoint on the 30-bus LN/LG pair also passed. With an
explicit one-million-entry budget, all three policies produced dense rank 704,
sparse rank 704, and `dense_sparse_qr_unscaled_rank_agree=true` for both cases.
The earlier 250k budget correctly remained sparse-only, demonstrating that the
budget guard is active rather than silently allocating dense matrices. Dense
agreement is therefore established only for this small fixture; the 99/538-bus
campaigns remain sparse-only by design.

The next major item is row-family attribution across the repeated numerical
matrix, using the same dense/sparse budget provenance and endpoint-trust labels.

The repeated numerical-stage matrix is now complete for the same six cases and
three policies. Every one of the 36 observations retained sparse QR rank with
`sparse_available_dense_unavailable` readiness; ranks were invariant at 704
(30-bus), 1,968 (99-bus), and 11,028 (538-bus). Relative to baseline, both
candidate policies had zero sparse-rank changes and zero numerical-readiness
changes. The repeat summarizer now also retains sparse-QR condition-proxy
ranges and policy deltas; the observed paired deltas were small compared with
the absolute proxies (bounded scaling within about `5e-4`, no-scaling within
about `5.4e-5` in this campaign). Dense rank remains explicitly unavailable,
so these are sparse numerical observations rather than full rank proofs.

The next major item is row-family numerical attribution across the same policy
matrix, followed by a controlled dense run only on the 30-bus fixtures. This
will test whether policy-dependent condition-proxy movement is concentrated in
known equation families without risking dense allocation on the large cases.

Row-family attribution is now carried through the solver-trace numerical stage.
The sparse path reuses its trusted solver-result evaluation and writes a compact
`bmopf_profile` envelope plus the explicit top-level attribution field, without
constructing the full resource-heavy BMOPF profile. A six-case checkpoint
(30/99/538-bus LN/LG, baseline) produced attribution for all four 30/99-bus
cases; the 538-bus pair produced attribution after raising the explicit solve
guard to 20,000 variables. Global row-scale ratios ranged from about `2.8e3` to
`5.9e4`; `ibr_power_circle` was the smallest positive family in every case,
while line voltage-drop or voltage-magnitude-definition families supplied the
largest rows depending on the case. These are point-local derivative-scale
observations, not causal conditioning claims. The solver-trace summarizer now
accepts the compact numerical envelope and reports coverage and family metrics.

The next major item is to rerun the repeated three-policy numerical matrix with
this attribution enabled, then compare family-level ratio deltas against the
sparse-QR condition-proxy deltas. Keep the dense checkpoint restricted to the
30-bus fixtures and preserve explicit solve/rank budget provenance.

That policy matrix has now been rerun once for all six cases. Attribution was
available in all 18 observations. Relative to baseline, bounded scaling
increased the global row-scale ratio by about 2.0--2.3% (absolute deltas
`62.5`--`1198.5`), while no-scaling decreased it by about 0.2--0.35% (absolute
deltas `-5.8`--`-206.1`). The smallest-positive family remained
`ibr_power_circle` in every observation, and the identity of the largest family
was stable within each case. The repeat summarizer now consumes the normalized
case envelope correctly and reports these paired deltas alongside sparse-QR
condition-proxy changes. This is useful policy-sensitive derivative-scale
evidence, but it still does not establish causality or physical ill-conditioning.

The row-family matrix has now been repeated independently. All three policies
had stable row-family ratios, sparse ranks, condition proxies, and numerical
readiness across the two runs. Both paired policy deltas were stable case by
case: bounded scaling remained positive (`62.5`--`1198.5`), while no-scaling
remained negative (`-5.8`--`-206.1`). Semantic finding changes and readiness
changes were both zero. `validate_bmopf_campaign.jl` now recognizes
`bmopf-solver-repeats-v1` reports and emits an explicit readiness gate for
configuration attribution availability, per-case recurrence, paired-delta
availability, and paired-delta recurrence. The resulting validation report
passes with no warnings.

The next major item is a bounded dense row-family checkpoint on the 30-bus
fixtures under the same two-repeat policy protocol, followed by a compact
family-level evidence ledger entry. Large 99/538-bus cases remain sparse-only.

The dense 30-bus checkpoint is complete for baseline, bounded scaling, and
no-scaling. Both LN and LG cases reported dense rank 704, sparse rank 704, and
explicit `dense_sparse_qr_unscaled_rank_agree=true`; row-family attribution was
available in all six observations. The dense budget therefore confirms the
sparse rank on this small fixture while preserving the large-case sparse-only
boundary. The next major item is to promote the repeat/dense evidence into the
evidence ledger and begin controlled multiconductor profiling, keeping generic
solver diagnostics separate from BMOPFTools domain interpretation.

The evidence ledger now ingests solver-repeat recurrence records and dense/sparse
rank-agreement checkpoints as explicit `record_kind = "evidence"` entries. A
combined ledger built from the two-repeat policy report, dense 30-bus summary,
and multiconductor smoke summary retained 26 source-aware records without
collapsing them into a score.

The first controlled multiconductor BMOPFTools smoke campaign also completed on
five local fixtures using explicit BMOPF start completion, dense analysis
disabled, and a four-dimensional iterative right-nullspace probe. All five
cases built successfully, retained port contracts, and exposed the probe. The
campaign correctly remained physically non-ready: source schema losses were
reported and dense rank-based expected/observed mode comparison was unavailable.
Those are capability boundaries, not solver failures. The next major item is to
add a second multiconductor point policy and compare port/mode evidence across
points before making any physical interpretation.

The point-policy comparison is now implemented. The explicit BMOPF-start versus
zero-coordinate policies covered all five fixtures successfully; port-contract
fields, physical-mode statuses, and iterative-probe convergence were unchanged.
The engine-initialization policy was also tested and failed all five fixtures
because the staged contexts have incomplete starts. That failure is now retained
as a point-policy readiness finding rather than silently treated as a physical
difference. The comparison utility requires paired successful cases before it
admits point-local evidence into the ledger.

The next major item is a dense-budget multiconductor point comparison on the
smallest fixtures, so terminal-mode evidence can be tested only after the
source-schema and coordinate-alignment gates are explicit.

The bounded dense point checkpoint is now complete on all five local
multiconductor fixtures (roughly 2,000--2,800 Jacobian entries per fixture)
using a 10,000-entry budget. Both BMOPF-start and zero-coordinate policies
reached successful builds, and dense rank was available for every paired
fixture. Port contracts, mode-status classifications, and probe availability
remained unchanged, while two fixtures changed dense Jacobian rank between
points (delta-load: 38 to 36; wye-delta-transformer: 48 to 42). The comparison
and ledger retain these as point-local numerical observations. They are not
physical-mode conclusions: all five cases still have coordinate-alignment
boundaries and source-schema losses affecting physical readiness. The next
major item is explicit coordinate-alignment diagnostics for these dense-rank
changes, followed by a repeat after source metadata is restored.

The dense-rank changes are now classified against the coordinate gate. Both
changed fixtures are `alignment_ambiguous`: every paired fixture reports a
coordinate-alignment boundary, so the rank deltas cannot yet be attributed to
an observed physical mode or a formulation defect. The comparison validator
and ledger retain this boundary as local evidence rather than suppressing the
rank change. The next major item is to expose a compact per-port alignment
coverage report (including missing/partial terminal maps) and use it to guide
the BMOPFTools source-metadata restoration work.

The per-port alignment report is now present in each multiconductor contract.
For the dense checkpoint, all five fixtures had complete voltage and current
terminal maps (18/18 voltage ports and 10/10 current ports for the delta-load
case), with no missing, dimension-mismatched, or nonfinite maps. The remaining
boundary is therefore narrower: the port maps are structurally complete, but
the declared physical-mode semantics are not yet aligned to model coordinates.
The next major item is to expose those mode-to-coordinate projections per
component and use them to separate hidden, visible, and unrepresented modes.

Per-component mode projections are now serialized for the dense checkpoint.
All five fixtures expose paired projection records; the declared source
common-mode directions are visible in model coordinates (two visible modes for
the grounded-neutral case), with no hidden or unrepresented projection in
this corpus. Projection visibility is stable between BMOPF-start and zero
points. This does not make the modes observed: the numerical comparison still
reports coordinate-alignment boundaries. The next major item is to compare
these visible candidate directions against observed Jacobian nullspace vectors,
preserving component and variable support in the match evidence.

The first candidate-to-Jacobian match checkpoint is now complete. All five
fixtures have paired match records and stable status across BMOPF-start and
zero points. No candidate was classified as observed: 12 modes lie outside
the free-coordinate Jacobian scope, while the wye-delta transformer has two
additional visible delta modes classified as locally not observed (residuals
about 0.577). This is a useful semantic result, not a failure: the current
reference/fixed-coordinate treatment prevents a physical gauge claim. The
next major item is a controlled free-coordinate projection policy so visible
candidates can be compared without silently dropping fixed components.

The controlled free-coordinate policy is now implemented. The default :strict
policy preserves the original alignment gate. The opt-in :project_free policy
compares only the represented free component while retaining fixed and missing
coordinates, coefficient norms, variable indices, projection residuals, and
policy identity in the finding evidence. Projected matches are deliberately
classified as local representational evidence rather than physical observations.
BMOPF smoke, point comparison, validation, and evidence-ledger paths now record
the policy and projected-match counts. The next major item is to add a
plugin-specific tangent policy for reference and grounding coordinates, so a
projected candidate can be compared against the physically admissible tangent
space rather than only the generic free-variable scope.

The generic tangent-policy boundary is now implemented. An
`ExpectedNullspaceTangentPolicy` names an explicit coordinate scope and
metadata; `analyze_degeneracy` retains those columns in the local Jacobian
comparison and labels matches as local tangent evidence. No bounds or model
constraints are changed. The BMOPFTools extension can construct a default
`bmopf_fixed_reference_grounding` scope from staged fixed-variable roles, and
the smoke, comparison, validation, and ledger paths serialize its identity.
The next major item is empirical calibration: run paired BMOPF campaigns with
and without the tangent scope, inspect residual and rank changes, and add
fixture-specific declarations only where the staged engine semantics justify
them.

A reproducible calibration path is now available. `launch_bmopf_tangent_calibration.jl`
runs the same smoke fixtures and point policy under `none` and `fixed` scopes,
serializes both summaries, and invokes
`compare_bmopf_tangent_policies.jl`. The comparison reports per-fixture rank,
mode-status, and tangent-observation deltas with explicit environment and point
compatibility gates. It treats changes as local calibration evidence rather than
physical conclusions. The next item is to run this campaign on the small BMOPF
fixture set, inspect retained-variable support, and promote only validated
reference/grounding declarations into the multiconductor plugin.

The five-fixture zero-point calibration is complete. All five paired dense
comparisons were available and retained the same rank under `none` and `fixed`:
delta-load 36, free-neutral-return 34, grounded-neutral 34,
unbalanced-three-phase-line 38, and wye-delta-transformer 42. Every fixture
changed only its mode-coordinate classification: 12 modes moved from outside
the generic free scope to tangent-comparable in the first four cases, and six
transformer modes did so in the last. All 14 tangent-comparable modes were
locally not observed. This supports the representational value of the policy,
but the corpus still carries 59 physical/source-schema warnings, so no
fixture-specific physical declaration is promoted yet.

The first bounded calibration run used the `delta-load` fixture at the zero
coordinate probe with a 10,000-entry dense budget. Both scopes built
successfully and retained rank 36. Without the scope, two visible modes were
outside the free-coordinate comparison; with the fixed scope, both became
comparable and were classified locally as tangent-not-observed. This is the
intended representational effect, not a rank or physical conclusion. The run
also retained 17 source-schema warnings, including physical metadata losses,
so the fixture is not yet suitable for promoting a physical declaration.

The calibration summaries now retain each tangent-mode row with its mode name,
policy identity, residual, tolerance, and declaration description, together
with the retained-coordinate count. This makes the source-restoration step
auditable at fixture level instead of relying on aggregate counts.

The first source-preserving solver matrix exposed and corrected an important
coordinate-boundary defect. Staged BMOPF contexts normalize source nominal
voltages during construction; comparing those model-coordinate values directly
with source volts produced spurious ratios near 200--240. The source-trace path
now captures the pre-build source contract, records both physical and
model-coordinate nominals, and applies the declared voltage base before
classifying a threshold. A corrected DSS smoke trace reports a 0.919 p.u.
load ratio for the one-phase perfect-neutral fixture, within its `[0, 2]`
source domain. The next major item is to rerun the full six-fixture budget
matrix through this corrected gate, then resume source-metadata restoration and
multiconductor physical-mode calibration only from unit-aligned evidence.

That corrected six-fixture matrix is now complete for `max_iter = 5` and `25`.
All 12 pairs completed with source-contract, non-mutating auxiliary-model,
comparison, and coordinate-alignment coverage. The one-phase, delta-load, and
three-phase-line fixtures were consistent with their source voltage domains at
both budgets. ZIP and wye-delta-transformer failures at five iterations were
not explained by source thresholds, and both became source-domain-consistent at
25 iterations. Thus the earlier threshold-aligned failures were entirely due
to the volts-versus-per-unit reporting defect; the remaining budget dependence
is a solver-endpoint observation that should be investigated through
initialization, derivatives, and formulation scaling. The next major item is
now controlled initialization/point perturbation on those two cases, not adding
source voltage bounds.

The first controlled family-omission matrix is complete for ZIP and
wye-delta-transformer at both budgets, with `load` and `ibr` variants present in
all four pairs. At `max_iter=5`, omitting the load family reached a local
optimum for both cases, while omitting IBR remained iteration-limited. At
`max_iter=25`, both variants reached local optima. This is repeatable
solver-sensitivity evidence that load-family equations/constraints deserve
priority in the next derivative and initialization audit; it is not proof that
the production load formulation is wrong, because omission changes the model.
The perturbation report also records family-level Jacobian rank effects and
retains the production baseline separately. The next item is to compare these
omission signals against explicit start policies and derivative fingerprints on
the unchanged model.

Initialization provenance is now part of every source-preserving solver trace
and matrix entry. The trace supports four explicit policies: preserve native
BMOPFTools starts, all-zero starts, BMOPF starts, and BMOPF starts with zero
completion for missing coordinates. It records whether the policy was applied,
how many finite starts were present/installed, how many coordinates remained
missing, and the completed-point
fingerprint when one exists. A one-case ZIP pilot with all-zero starts completed
with 44/44 finite starts and retained the same source-domain classification as
the native-BMOPFTools-start five-iteration run. This is only a policy/provenance
checkpoint; a paired budgeted matrix is still required before attributing any
termination change to initialization. The launcher also now survives cases
with no family-perturbation records instead of aborting while reducing an empty
status collection. The next major item is a paired `none`/`zero`/`bmopf` matrix
on ZIP and wye-delta-transformer, followed by derivative-fingerprint comparison
at the same endpoint.

The first all-zero-start matrix is now complete for ZIP and wye-delta-transformer
at both budgets. All four pairs applied finite starts to every coordinate and
passed source-contract, coordinate-alignment, auxiliary non-mutation, and
comparison readiness. The wye-delta case retained the same five-versus-25
budget transition as the default policy. ZIP remained source-domain-unexplained
at both budgets under zero starts, whereas the default policy became consistent
at 25; this is a concrete initialization-sensitive endpoint observation, not a
formulation diagnosis. The BMOPF-start-plus-zero-completion pilot also now
works against the staged lifecycle and records a completed-start fingerprint.
Trace comparison tooling retains initialization policy and fingerprint fields
so the next matrix can compare endpoint derivatives under compatible point
provenance.

The endpoint derivative checkpoint is now implemented as an opt-in trace stage.
On the zero-start ZIP pilot it evaluated 245 finite Jacobian entries with a
stable evaluator-source fingerprint and retained both the endpoint point
fingerprint and sparse value digest. This provides the missing bridge between
initialization sensitivity and derivative evidence without pretending to
estimate rank or conditioning. The next major item is a paired derivative
fingerprint matrix for default versus zero/BMOPF-completed starts, with point
compatibility and solver-budget gates kept explicit.

The initialization semantics audit also found that the native BMOPFTools build
does not populate every coordinate: the ZIP trace had 14 finite native starts
and 30 missing coordinates. The all-zero policy supplied 44/44 starts. This is
why the baseline is now explicitly called `none`/native-default rather than
“uninitialized”; future comparisons must report both policy identity and start
coverage before interpreting endpoint differences.

The paired policy/derivative matrix is now complete for ZIP and
wye-delta-transformer at budgets 5 and 25. All 12 policy/case/budget records
passed the source-contract, coordinate-alignment, initialization, and endpoint
derivative gates. Native defaults and BMOPF-start-plus-zero-completion produced
the same endpoint derivative fingerprints on all four pairs; all-zero starts
produced different fingerprints on all four. The only classification change was
ZIP at budget 25: native/default and BMOPF-completed starts were
source-domain-consistent, while all-zero starts remained an unexplained solver
endpoint failure. This is strong local initialization sensitivity evidence, not
a proof of a formulation defect. The next major item is to inspect the
fingerprint deltas structurally—row-family magnitudes, residuals, and active-set
state—before broadening the benchmark corpus.

The structural attribution hook is now implemented. Endpoint derivative records
can carry BMOPFTools row-family scale attribution; the ZIP pilot exposed 21
families, with KCL rows owning the largest finite row norms and load-power
imaginary rows owning the smallest positive norm. This is the first concrete
bridge from an initialization-induced endpoint fingerprint to named formulation
families. A full three-policy attribution matrix remains the next run before
making any family-level diagnosis.

Active-set endpoint summaries are now included alongside the row-family data.
The zero-start ZIP pilot exposed 27 selected active rows, 17 violated rows, and
a maximum feasibility violation of 1.0 at the five-iteration endpoint. These
records make solver-endpoint geometry inspectable without conflating an
incomplete iterate with a physical infeasibility certificate. The next run is
the full three-policy row-family and active-set matrix, followed by matched
family-level deltas.

That full structural matrix is now complete. All 12 records passed every
readiness gate. Native defaults and BMOPF-completed starts matched exactly in
active-row sets, violation counts, and row-family extrema across both fixtures
and budgets. Zero starts changed the ZIP active geometry at both budgets: 17
rows moved from the native active set, 17 rows became violated, and the maximum
feasibility violation increased to 1.0. Its smallest positive row norm moved
from the line-thermal family (0.722) to `load_power_imag` (0.001196), while KCL
remained the largest-scale family. The transformer retained the same active-row
set and zero violations under all policies, although its detailed row-family
scales still changed. This localizes the current sensitivity signal to ZIP's
load/endpoint geometry rather than a generic transformer or source-contract
effect. The next major item is to correlate these deltas with solver iteration
residuals and family-omission results before testing larger cases.

The structural comparison now includes the full solver iteration trace. The
zero-start ZIP runs entered restoration immediately and ended at the budget
with primal residual 1 and dual residual approximately 999, while native and
BMOPF-completed starts followed the regular convergent trajectory. The
transformer had the same endpoint active geometry under all policies; zero
starts only added transient residual increases. This separates a true
initialization-sensitive solver trajectory from a row-scale change that does
not alter endpoint geometry.

`benchmarks/correlate_bmopf_structural_family_omission.jl` now joins that
comparison to the family-omission campaign. In the bounded four-row matrix,
load-family omission was sensitive on all rows and co-occurred with the two
ZIP endpoint changes; IBR omission was not sensitive and never co-occurred.
This is a useful prioritization signal for a deeper load-family investigation,
not a causal or physical diagnosis. The generated JSON preserves the evidence
and readiness gates. The next major item is row-family residual attribution
over a wider, sparse-first BMOPF corpus, with dense/rank analyses restricted
to the small fixtures.

The first sparse-first corpus checkpoint now covers BMOPFTools' 14-, 55-, and
223-bus LV decks. Source contracts and auxiliary non-mutation checks passed
for all three. The 14- and 55-bus cases reached the existing resource-budget
profile boundary; the 223-bus case was stopped explicitly by the 2,000-variable
solver guard (3,784 variables). A new
`benchmarks/summarize_bmopf_sparse_corpus.jl` report records these as planned
coverage boundaries rather than solver failures. This confirms that the
benchmark harness can scale its evidence policy without silently attempting
dense analysis on large models. The next major item is to add sparse Jacobian
row-family residual attribution to these guarded campaigns and then compare
it against the small-fixture endpoint evidence.

The sparse numerical-profile path is now exercised on the 14- and 55-bus LV
decks with a zero dense-rank budget. Both campaigns passed source and
coordinate readiness and retained 27 named row families. The native and
zero-start policies stayed source-domain-consistent, but their trajectories
changed: the 55-bus zero-start run used 13 trace records versus 5 natively,
while the 14-bus run retained four records with a different final primal
residual. Row-family extrema also moved for the 14-bus case (the smallest
family changed from `switch_current_thermal` to `line_current_thermal`). These
are numerical/initialization observations, not physical diagnoses. The next
step is to retain sparse row residuals—not only row norms—so trajectory changes
can be attributed to families without requiring dense matrices.

That residual-retention step is now implemented. With public Ipopt callback
points enabled, each captured iterate can carry per-family maximum and L2
feasibility residuals plus active/violated row counts. In the paired 14-/55-bus
campaign, zero starts raised the global peak feasibility residual from roughly
0.87 to 1.73 and expanded the 55-bus captured trajectory from 5 to 13 points.
The largest early residuals were transformer-voltage families, while load and
KCL families remained separately visible. This is the first trajectory-level
family attribution, still explicitly numerical and local. The next item is to
add residual trend classification (persistent, transient, or restoration-only)
and validate it against solver phase changes on the ZIP/transformer fixtures.

The first trend classifier is now included in the policy comparison. It uses
only captured family residual series and solver phase labels, and emits
descriptive `persistent`, `transient`, `restoration_only`, `mixed`, or
`inactive_or_below_tolerance` tags. These are intentionally heuristic trend
summaries. The next validation is to exercise them on the ZIP/transformer
fixture matrix, where restoration behavior is already independently visible.

The restoration validation is now in place. On the zero-start ZIP fixture, the
residual-aware trace reproduced one regular and one restoration callback at
both budgets, with final primal/dual residuals of 1 and approximately 999.
The validator correctly labels this as `restoration_with_persistent_family`:
the phase is real, but the residual families span both callbacks rather than
being restoration-only. Native ZIP and both transformer policies had no
restoration phase and were labelled `aligned_no_restoration`. This is the
intended conservative result: a phase/family consistency check, not a causal
claim about which formulation component caused restoration.

The bounded restoration campaign report is now implemented. Across the
residual-aware ZIP/transformer grid it records eight policy observations, two
restoration observations, and two restoration/endpoint-residual
co-occurrences. Both co-occurrences are the zero-start ZIP runs; the
transformer has no restoration signature. The report also retains the largest
family peaks, showing ZIP voltage-drop/load-voltage families at the failed
endpoint while keeping transformer KCL peaks visible as separate transient
evidence. This is the correct stopping point for generic restoration claims:
the next major item is to add solver-option and budget perturbations to test
whether these signatures persist under controlled algorithmic changes.

The first option-persistence campaign is complete on ZIP, with baseline,
adaptive-barrier, and monotone-barrier profiles crossed with native and
zero-completion starts at five and 25 iterations. All 12 matrices completed
and all eight perturbation-vs-baseline comparisons were available. The
restoration signature was invariant: zero-start ZIP retained one restoration
record and the large endpoint residual signature under both barrier profiles,
while native starts retained no restoration record. No classification or trace
length changed in this bounded campaign. This strengthens the interpretation
from “option-specific artifact” toward “initialization-sensitive local
signature,” but it is still not a causal or physical proof. The next item is
to cross the same option profiles with the transformer fixture and a broader
budget grid.

That cross-fixture option campaign is now complete. Baseline, adaptive-barrier,
and monotone-barrier profiles were crossed with native and all-zero starts for
the wye-delta transformer at budgets 5, 25, and 50: 18 matrix records and 12
same-policy perturbation comparisons passed the artifact/readiness gates. The
transformer retained no restoration records under any profile, start policy, or
budget. Monotone-barrier was classification-stable; adaptive-barrier changed
only the native five-iteration classification from a bounded solver failure to
source-domain consistency, while leaving the regular phase signature and
endpoint residual signature unchanged. At larger budgets the classifications
converged across profiles; adaptive also shortened the captured trace by one
record (native) or two records (zero start), which is algorithmic trajectory
evidence rather than a formulation diagnosis. This establishes that the ZIP
restoration signal is not reproduced by the transformer fixture, while keeping
option sensitivity visible as a separate, bounded numerical observation. The
next major item is to run the same residual-aware option cross on the transformer
and ZIP fixtures, so family-level residual persistence—not just phase and
classification—can be compared under algorithmic perturbations.

**Post-review correction.** The historical option runs above remain useful as
pipeline smoke tests, but they do not satisfy the current experimental-design
gate. Ipopt's default barrier strategy made the empty `baseline` profile and
the explicit `monotone` profile equivalent, so those were not three distinct
interventions. In addition, the old family comparison used the maximum over the
entire captured trace; a common iteration-zero residual could hide differences
later in the trajectory. These results must not be cited as calibrated evidence
of option robustness. The current launcher rejects duplicate option sets, and the v3
summary separates first-captured, subsequent, phase-conditioned, and final residuals.
The ZIP/transformer and multiconductor campaigns should be rerun under that
schema before their negative sensitivity results are trusted.

Under the historical schema, the residual-aware option cross completed for ZIP and the transformer,
with all three option profiles, both initialization policies, and budgets 5 and
25: 24 observations and 16 perturbation-vs-baseline comparisons passed every
readiness gate. No comparison changed restoration presence or any named
row-family peak beyond the explicit combined tolerance (absolute `1e-10`,
relative `1e-8`); machine-scale differences are therefore not promoted to
findings. The only classification change was the transformer native five-step
adaptive-barrier case, matching the trace-only campaign. Adaptive reduced the
captured transformer trace length at 25 iterations, but did not change the
material family-residual signature. This is retained as smoke evidence rather
than a validated negative result: it does not yet establish that the option
sensitivity is only phase/classification-level. The next major item is to expose this tolerance-aware
family comparison in the renderer/evidence ledger and then repeat it on a small
multiconductor benchmark before scaling to larger BMOPF decks.

The tolerance-aware family comparison is now exposed in the evidence ledger.
Option summaries are recognized as a first-class source type and emit separate
records for material row-family residual stability and local classification
sensitivity. On the completed residual campaign this produced one numerical
stability record and one local sensitivity record: the named family residuals
were stable, while one transformer five-step adaptive case changed endpoint
classification. The next major item is the small multiconductor option/residual
benchmark, using the BMOPFTools engine and port-family semantics before any
large-corpus campaign.

The corrected v3 ZIP/transformer campaign is now complete: 24 observations,
16 matched baseline comparisons, and eight direct adaptive-profile comparisons
passed the manifest, pairing, and trajectory-coverage gates. No option changed
restoration presence, endpoint residual-failure status, first-captured family
residuals, global family peaks, or post-first family trajectories. The largest
raw family-statistic delta was approximately `6.04e-11`, below the declared
combined tolerance. Both adaptive profiles changed only the native-start
transformer's five-iteration classification and shortened its 25-iteration
trace; their direct paired observations were otherwise identical. The
zero-start ZIP restoration/endpoint signature persisted across all profiles.
This is now valid bounded numerical evidence, not the earlier duplicate-profile
smoke result. Because the solve-time schema predated dirty-tree content
fingerprinting and the run used a modified checkout, it remains a development
calibration result that must be repeated on a fixed clean revision before
publication. Full details are in `docs/calibration_results.md`.

## 2026-08-11 numerical-algebra checkpoint: scaling intervention complete

The generic profile and BMOPF campaign paths now share the dense-rank policy's
diagonal scaling semantics, preserve factor and coordinate evidence, and map
column-scaled directions back for a direct original-Jacobian audit. On the
transformer, row-column scaling greatly improved mutual span alignment and
exposed four roundoff-level mapped directions, but did not make the six-value
dense target numerically resolvable and caused the restarted tracker to exhaust
its work budget. Scaling is therefore an experimental control, not the
resolution.

The next ordered numerical-algebra items are:

1. add a third smallest-singular extraction path that avoids forming or
   iterating solely on the squared normal spectrum;
2. add mapped-candidate alignment against the original guarded dense subspace,
   while retaining an explicit unresolved-target classification;
3. repeat baseline and scaling policies at identical and nearby trusted points
   to separate deterministic algorithm behavior from operating-point
   sensitivity; and
4. expand the oracle corpus with randomized rectangular and nonlinear
   cancellation cases before promoting any backend to a default diagnostic.

Physical mode fingerprinting remains downstream of these gates and of the
PowerIO/BMOPFTools source-schema readiness work.

## 2026-08-11 numerical-algebra checkpoint: third backend complete

The initial rank-revealing sparse-QR backend is now implemented end to end. It
constructs free-column nullspace vectors from SuiteSparseQR, maps scaled
directions into original coordinates, audits direct `Jv` residuals, records
orthogonality and fill, supports guarded dense-SVD subspace calibration, and is
integrated into generic profiles, BMOPF summaries, controlled comparisons, and
campaign validation. Focused adversarial tests cover wide, tall, zero,
ill-scaled, guarded, and dense-calibrated cases; the complete package suite has
1,600 passing assertions at this checkpoint.

On the 51-by-54 transformer at the completed start, unscaled and row-column
policies both give rank 48/nullity six and agree with dense SVD at minimum
principal cosine above `0.9999999999999998`. This is trustworthy local
numerical-subspace evidence for this point, while source-schema warnings and
the absence of persistence evidence still block a physical classification.

The next ordered major items are:

1. add deterministic same-point repeats and nearby-point perturbations for the
   sparse-QR subspace, comparing principal angles rather than arbitrary basis
   columns;
2. project persistent numerical directions through plugin-owned component and
   port coordinate maps, retaining unexplained residual energy and refusing a
   physical label when source-schema coverage is incomplete;
3. expand the small dense-oracle corpus with randomized rectangular matrices,
   clustered threshold cases, and nonlinear cancellation Jacobians; and
4. add symbolic fill estimates or stricter case-selection heuristics before
   enabling sparse QR on larger feeders, because the factor-fill guard is
   necessarily evaluated after numeric factorization.

The iterative restarted/harmonic engines remain useful scalable probes, but
the sparse-QR result shows that their disagreement on this transformer was a
search-resolution problem, not evidence against the six-dimensional local
nullspace.

## 2026-08-11 numerical-algebra checkpoint: persistence and localization complete

Sparse-QR persistence now distinguishes identical-coordinate repeatability
from nearby-point stability, retains all pairwise point distances and principal
cosines, and requires direct residual support. Persistent spans are localized
through basis-invariant coordinate leverage and plugin-owned voltage/current
port groups. Expected-mode projection retains both unexplained nullspace energy
and a source-schema readiness boundary.

On the transformer, the rank-48/nullity-six span is exactly stable over three
repeats and four symmetric nearby probes. It is supported entirely on six
structurally disconnected load-current coordinates, so the leading diagnosis
has changed from “unclassified transformer nullspace” to “representational
inactive-coordinate freedom.” Declared voltage-port candidates are orthogonal
to this freedom, and their physical interpretation remains blocked by source
schema gaps.

The next major items are now:

1. inspect BMOPFTools' load-terminal allocation contract and determine whether
   inactive conductor current coordinates should be omitted, fixed, or linked;
2. add a regression fixture for that representational defect and rerun the
   persistence campaign on a corrected staged model;
3. repeat sparse-QR persistence on the grounded-neutral, free-neutral, delta,
   ZIP, and three-phase-line representatives to separate recurring adapter
   patterns from transformer-specific behavior; and
4. expand randomized rectangular, clustered-threshold, and nonlinear
   cancellation oracle cases before considering sparse QR for broader feeders.

Physical gauge classification should resume only after representational
nullspaces are removed and source-schema readiness is explicit.

## 2026-08-11 cross-package checkpoint: diagnosed freedom removed

The first persistence-driven formulation intervention is complete. The six
transformer directions were traced to unused second current coordinates on
three two-terminal `SINGLE_PHASE` loads. BMOPFTools now allocates one complex
branch current per such load and reports it against the two-terminal voltage
difference. NLPDiagnostics exposes that coordinate through a two-terminal
`[+1, -1]` incidence map instead of an identity map over two artificial model
coordinates.

The post-intervention transformer has 48 variables and 51 scalar rows. Sparse
QR and dense SVD agree on rank 48/right-nullity zero, repeated over three exact
copies and four nearby probes. The prior disconnected-variable and zero-column
evidence is absent, while all current-port alignment checks pass. Campaign
validation has no errors; its remaining warnings are exclusively the known
source-schema readiness boundary.

The next ordered major items are:

1. run the same sparse-QR repeat/nearby-point policy on the other five small
   BMOPF fixtures and classify recurring representational versus numerical
   patterns before expanding case size;
2. add an explicit formulation-intervention comparison artifact so pre/post
   dimension, rank, nullity, disconnected support, and source revision are
   reviewed as one controlled evidence record;
3. restore or contractually classify the remaining `vminpu`/`vmaxpu` source
   fields so absence of declared physical modes can eventually be interpreted;
4. extend randomized rectangular, clustered-threshold, and nonlinear
   cancellation oracles, including no-nullspace cases, before changing sparse
   QR from opt-in calibration to a broader default; and
5. only then launch medium BMOPF decks under explicit nonzero/fill budgets and
   retain skipped cases as resource-bound evidence.

This keeps the project on its intended path: numerical routines identify and
localize a mechanism, structural analysis supplies independent evidence, and
domain semantics determine whether the mechanism is representational or
physical. Solver-method conclusions remain downstream of controlled point,
formulation, and algorithm interventions.

## 2026-08-11 campaign-evidence checkpoint: small-fixture baseline complete

The remaining five small BMOPF fixtures now have a uniform sparse-QR
repeat/nearby baseline. All five are full column rank across seven evaluations,
dense SVD agrees on zero right nullity, and direct factorization residuals are
at roundoff scale. There is no recurring representational nullspace analogous
to the corrected transformer defect in this small set.

Campaign provenance now fingerprints the loaded NLPDiagnostics and BMOPFTools
source trees, and a first-class formulation-intervention report records
dimension, rank, nullity, disconnected support, fixture identity, numerical
policy, and source revision together. The historical transformer comparison
reproduces the expected six-coordinate removal but deliberately fails the
causal gate because its old runs changed QR scaling and did not record
BMOPFTools source state.

The main recurring observation is instead initialization: partial BMOPFTools
starts completed with zero currents violate constraints in all five cases, with
an order-one maximum violation on ZIP. Numerical evaluations and exact
derivatives remain finite, and the largest recorded sparse-QR condition proxy
is about 84. Source-schema loss still blocks physical presence/absence claims.

The recurring zero-Jacobian rows have now been classified: all 40 are inactive
current-magnitude circle rows evaluated at zero current, with no active
stationary row. They do not explain solver difficulty at this point; their
duplicate pairs remain a formulation-economy issue.

The next ordered major items are:

1. run a point-policy calibration on ZIP and the other small fixtures using a
   physics-informed or solved feasible point, then compare rank, active-set,
   feasibility, and conditioning evidence against zero completion;
2. restore or contractually classify `vminpu`/`vmaxpu` and the remaining
   voltage/load source semantics before interpreting absent physical modes;
3. add randomized rectangular, clustered-threshold, and nonlinear-cancellation
   oracle cases, including full-column-rank controls; and
4. add a generic cross-stage finding that distinguishes inactive stationary
   circle rows from active stationary constraints without suppressing the raw
   zero-gradient evidence; and
5. after those gates, profile selected medium BMOPF decks with sparse-only
   budgets and retain factor-fill/resource skips as first-class evidence.

This reorders the near-term emphasis from finding more nullspaces to separating
start-point pathology, harmless compiled rows, source-schema loss, and genuine
numerical geometry.

## 2026-08-11 feasible-point checkpoint: initialization separated from geometry

The five-fixture solved-point campaign closes the first item above. All five
Ipopt runs produced public feasible result points, all 31 completed-start
violations disappeared, sparse QR and guarded dense SVD retained full column
rank, and rank/nullity stayed fixed across repeated and nearby evaluations.
The stationary current-limit rows at zero current disappeared at solved points,
confirming a point-local derivative effect. Sparse-QR condition proxies moved
without rank changes, which is exactly the distinction the diagnostic pipeline
must preserve: feasibility, local derivative scale, and degeneracy are separate
observations.

The next ordered major items are:

1. restore or explicitly contract `vminpu`/`vmaxpu` at the PowerIO/BMOPF
   boundary, then repeat the small solved-point campaign before promoting any
   physical-mode absence result;
2. implement a generic cross-stage finding for active versus inactive
   stationary circular/quadratic rows, retaining the raw zero-gradient evidence
   and recognizing non-unit radii/scales rather than assuming a unit circle;
3. expand dense-oracle calibration with seeded randomized rectangular,
   clustered-threshold, and nonlinear-cancellation Jacobians, including
   full-column-rank negative controls and tolerance/scaling sweeps;
4. launch selected medium BMOPF fixtures with sparse-only nonzero/fill/work
   budgets, solver-result point provenance, and explicit resource skips; and
5. correlate solver traces with row-family derivative scales only after the
   preceding point and schema gates, so numerical-method conclusions are tied
   to repeatable mechanisms rather than endpoint anecdotes.

This is still the right direction. The generic core is no longer short of
features; the main work is converting local observations into calibrated,
cross-checked evidence and withholding physical labels when domain provenance
is incomplete.

## 2026-08-11 schema and stationary-row checkpoint

The first two items above are complete. `vminpu`/`vmaxpu` are now recognized as
preserved non-mutating load-behavior contracts rather than lost metadata or
production bus bounds. The five-fixture rerun has complete source-schema and
physical-metadata readiness with no unresolved blocking fields.

Generic numerical analysis now classifies recognized stationary
positive-diagonal quadratic rows as inactive, active, or violated and records
the true quadratic level/radius. The small BMOPF baseline contains 40 inactive
rows and zero active/violated rows; all 40 disappear at feasible solver-result
points. This replaces a campaign-specific interpretation with reusable generic
evidence.

The next ordered major items are now:

1. expand dense-oracle calibration with seeded randomized rectangular,
   clustered-threshold, scaling-sensitive, and nonlinear-cancellation
   Jacobians, including full-rank negative controls;
2. select medium BMOPF cases using explicit Jacobian-nonzero, sparse-factor
   fill, memory, and solver-work budgets, preserving every resource skip;
3. repeat selected medium cases across solved points and controlled scaling
   policies before interpreting condition-proxy or solver-trace changes; and
4. begin physical mode fingerprinting only for cases whose source contract,
   terminal maps, point provenance, numerical rank crosschecks, and persistence
   gates all pass.

## 2026-08-11 randomized-oracle and medium sparse checkpoint

The randomized rank-oracle gate and first medium sparse gate are complete.
All 18 away-from-threshold hard controls pass across three seeds. Four of nine
clustered-threshold cases deliberately expose dense-SVD/sparse-QR disagreement,
confirming that reports must preserve backend-specific threshold evidence
rather than merge ranks into one apparent fact.

Sparse-QR rank estimation now has explicit input-nonzero and realized-factor
nonzero budgets. Both limits, observed nonzeros, fill, and skip reasons flow
through numerical metadata and BMOPF campaign fingerprints. The first 99-bus
LN/LG pair stayed far below the selected 200k input and one-million-factor
budgets and required no dense algebra. Both were locally full column rank under
unscaled and row-column QR policies, but LN showed materially larger row-scale
and pivot-spread proxies.

The next ordered major items are:

1. eliminate or independently crosscheck the 96 finite-difference rows so the
   99-bus rank and scaling observations do not depend on one derivative path;
2. classify the extra saved-result `cr_to`/`ci_to` records as an explicit
   result-schema projection contract and expose the four BMOPFTools
   differentiability qualifications in the campaign summary;
3. repeat the 99-bus LN/LG pair across at least three time points and a
   controlled row/column scaling grid, preserving rank, pivots, fill, row
   families, and point feasibility;
4. add process-level elapsed-time and memory limits around large isolated
   benchmark children, because a post-factorization fill cap is not a hard
   memory bound; and
5. only after those gates, correlate persistent scale families with Ipopt and
   MadNLP traces and begin expected-versus-observed physical mode
   fingerprinting.

## 2026-08-11 crosschecked multi-time medium checkpoint

The five gates above are now implemented and exercised for the bounded 99-bus
tier. Jacobian directional crosschecks can select rows by derivative
provenance and use deterministic dense directions without rebuilding a full
Jacobian at each perturbation. Across LN/LG at t01, t12, and t24, all 96
finite-difference rows passed 288 comparisons per case with zero mismatch or
domain loss.

Saved-result `cr_to`/`ci_to` records are now covered by an explicit derived
output projection contract: 784 records per case are projected, while all
1,968 staged coordinates map with no fallback or unresolved family. The exact
four BMOPFTools differentiability qualifications are persisted as evidence,
not reduced to a readiness boolean or count.

All six sparse Jacobians remain full column rank under unscaled and
row/column-scaled SuiteSparseQR, with fill ratios below 2.0. Unscaled
retained-pivot proxies vary from about 37.6 to 5,327 across time and
formulation, whereas the scaled proxies stay in the narrow 22.48--25.02 range.
That is repeatable evidence of scale-sensitive numerical geometry, not
time-varying structural rank. The midday proxy spike occurs without the
generic large-row-norm-spread finding, so a single global scaling ratio is not
an adequate explanation.

The point-calibration launcher now enforces per-child elapsed-time limits and
an optional polled RSS ceiling, while recording monitor availability and peak
RSS. All six children completed inside 600 seconds and 4 GiB; observed peaks
were about 2.60--2.69 GiB. The consolidated artifact applies explicit point,
derivative, rank, and resource gates, and all six pass for local numerical
comparison. It deliberately does not promote BMOPFTools differentiability
readiness: the reconstructed staged models report `OPTIMIZE_NOT_CALLED`.

The next ordered major items are:

1. attribute the 96 finite-difference rows to semantic constraint and operator
   families, replace fallback derivatives where BMOPFTools can expose exact
   formulas, and retain the crosscheck as a regression oracle;
2. explain the t12 unscaled pivot-spread spike with row-family, column-family,
   permutation, and retained-pivot attribution rather than another aggregate
   condition score;
3. run matched Ipopt and MadNLP traces at t01/t12/t24 under declared solver
   scaling policies, correlating iteration, restoration, KKT, and active-set
   events with the attributed scale mechanisms;
4. reduce campaign memory/serialization pressure before attempting the
   538-bus tier, retaining an explicit resource skip when the predicted sparse
   work or RSS budget is unsafe; and
5. begin expected-versus-observed physical-mode fingerprints only at solver
   endpoints whose source, mapping, derivative, active-set, and KKT evidence
   passes. Full column rank at these saved points is not by itself a proof that
   no physical gauge or collapse mode exists.

## 2026-08-11 physical scaling-covariance checkpoint

The first nondimensionalisation trust gate is now complete for a supported
small AC formulation. Generic covariance includes semantic coordinate
alignment, constraint-function values, scalar sets and bounds, physical
feasibility violations, objectives, gradients, and Jacobians. The stricter
equivalence gate requires all model-defining local checks except the optional
objective checks. A separate coordinate-geometry report exposes raw row/column
spread and an optional guarded condition proxy only after that gate and complete
point provenance pass. Physical Jacobian covariance now compares semantic
combined sparse entries, so disabling dense rank/SVD work does not disable the
equivalence gate.

The BMOPFTools adapter derives scales from public registry keys and declared
bases; it does not infer families from JuMP names. Classic 1 MVA per-unit and a
custom 500 V / 200 kVA policy pass all 21 integration checks at the same
physical completed-start point. Their raw geometry differs materially, while a
line-resistance negative control is rejected by the physical-Jacobian gate.
This establishes that the mechanism can distinguish a coordinate intervention
from a changed physical model on the labelled fixture.

The next ordered major items are:

1. solve or import one feasible physical state, map it into at least SI,
   classic, and two custom policies, and repeat covariance, active-set, rank,
   and local geometry checks at that shared state;
2. define physical semantics for solver feasibility, complementarity, and KKT
   tolerances so matched Ipopt/MadNLP traces compare equivalent stopping tests,
   not merely identical option strings;
3. **Completed for the current truth fixtures:** explicit scale contracts now
   cover transformer and n-winding coordinates/residuals plus the AC/DC
   converter and DC-network families exercised by the converter-tie fixture.
   Single-phase, wye-delta, n-winding, and converter cases each have a positive
   covariance test and a changed-resistance negative control;
4. add semantic row/column-family attribution to the now sparse-capable
   coordinate-geometry summary, preserving unavailable dense spectral evidence;
   and
5. only after these gates, run the multi-time 99-bus policy matrix and judge
   strategies from paired work, restoration, KKT, and robustness evidence.

The project is therefore ready to *design* flexible-base experiments and learn
from small truth-labelled cases. It is not yet ready to rank policies on the
large multiconductor corpus: the remaining work is concentrated in shared
feasible-point mapping, stopping-test semantics, and formulation-family
coverage rather than another generic diagnostic feature wave.

## 2026-08-11 semantic block-scaling checkpoint

The diagonal covariance boundary now has a compatible semantic block-linear
extension. Small blocks may refer to arbitrary model-vector positions, expose
semantic physical keys, and map through sparse assembled whole-model operators.
The implementation supports zero-equality mixing, positive-diagonal scalar
bounds, and conformally transformed Euclidean balls. Rotated boxes and other
unsupported coupled-set images are unavailable and block equivalence rather
than being approximated.

The first exact two-coordinate rotation fixture passes point, residual,
objective, gradient, sparse Jacobian, multiplier, stationarity,
Hessian-of-the-Lagrangian, and KKT covariance. It also confirms the expected
full-Jacobian singular-value invariance under complete orthogonal variable and
residual blocks. An incorrect multiplier fails, a rotated scalar box is
rejected by set coverage, and a non-orthogonal magnitude block does not claim
the rotation invariant. Multiplier and stationarity comparison remain
sparse-capable; dense Hessian/KKT work has an explicit entry guard.

The next ordered scaling-research items are:

1. **Completed:** expose paired real/imaginary and active/reactive residual
   blocks plus selected local ratings through BMOPFTools' public semantic
   registry, and consume them through a complete singleton-fallback adapter;
2. **Substantially completed:** small single-phase transformer, unbalanced
   wye-delta, three-winding, and AC/DC converter-tie truth fixtures now pass,
   each with a physical-parameter negative control. Dedicated centre-tap,
   regulator, floating-neutral, and delta-winding n-winding cases remain;
3. **Completed for scalar-bound solver endpoints:** add point-verified public
   MOI dual snapshots, lower/upper side data, and physical dual-feasibility and
   complementarity. Coupled-cone dual transforms remain separate work;
4. implement explicit off-block coupling measurements for declared numerical
   decompositions, keeping them separate from full-Jacobian conditioning; and
5. only then run magnitude-only and phase-only matched solver campaigns before
   combining local scales and rotations.

The line/load engine-backed truth case passes 40 checks across declaration
coverage, classic-versus-custom physical block covariance, local coordinate
geometry, and a changed-resistance negative control. BMOPFTools separately
tests declaration invariants, overlap rejection, defensive copying, correct
zero-versus-nonzero equality set contracts, and provenance serialization. The
formulation-breadth suite adds 64 checks across four further classes. The
shared feasible-state mapper and physical feasibility/stationarity contracts
are completed in the checkpoint below. Scalar-side complementarity and
solver-dual provenance are now completed in the following checkpoint. The
remaining gates are trace integration, semantic attribution, and specialist
transformer/neutral fixtures; they are not another generic map abstraction.

## 2026-08-12 shared-state and physical endpoint checkpoint

The shared feasible-state gate is now implemented and exercised. A generic
`transport_scaling_point` maps an explicit point through common physical
semantic coordinates, aligns differently ordered semantic keys, reconstructs
the target model coordinates, and retains both physical vectors plus the
maximum round-trip error. The target point has distinct `TransportedPoint`
provenance, so it is never mislabeled as a target solver result.

On the line/load truth fixture, Ipopt first obtains a feasible classic-per-unit
endpoint. The same physical state is transported into SI units and two custom
consistent-per-unit policies (200 kVA / 500 V and 5 MVA / 1.5 kV). All three
target evaluations pass point, function, set, physical violation, sparse
physical-Jacobian, and local-rank covariance. This closes the shared-state item
with an engine-backed four-policy test, not an initialization recurrence.

Physical stopping semantics are now implemented for scalar-bound endpoints at
the correct boundary:

- `physical_feasibility_report` applies residual- or block-specific absolute
  tolerances after mapping functions and sets to physical coordinates;
- the BMOPFTools wrapper can expand tolerances by declared physical quantity
  without maximizing unlike units together;
- `physical_stationarity_report` transforms an explicitly supplied row-aligned
  multiplier representative and Lagrangian residual to physical variable
  coordinates;
- the caller-supplied-multiplier overload of `physical_kkt_acceptance_report`
  still concludes only for equality-only systems; and
- `solver_dual_snapshot` plus the solver-snapshot KKT overload verify point
  identity, align public MOI duals with evaluator rows, preserve the exact MOI
  sign convention, and close physical scalar-side dual feasibility and
  complementarity.

These reports deliberately do not translate an Ipopt or MadNLP option string
into a physical guarantee. The next ordered major items are:

1. **Completed:** extract solver endpoint duals with an explicit MOI row/side
   convention, including variable bounds because they are evaluator rows;
2. **Completed for positive-diagonal scalar bounds:** implement physical
   side-specific dual feasibility and complementarity and expose a BMOPF
   endpoint adapter. Next connect these records to matched Ipopt/MadNLP trace
   artifacts and add coupled-cone dual contracts where justified;
3. add semantic row/column-family attribution to sparse-capable coordinate
   geometry and stopping residuals;
4. add centre-tap, regulator, floating-neutral, and delta-winding n-winding
   truth fixtures; and
5. only then run the multi-time 99-bus four-policy campaign and compare
   restoration, accepted steps, endpoint KKT residuals, factorization work,
   and robustness.

## 2026-08-12 solver-dual and complementarity checkpoint

The endpoint evidence boundary no longer relies on recovered active-set
multipliers. `SolverDualSnapshot` reads public MOI duals only after the selected
solver primal and the `NumericalEvaluation` agree coordinate-by-coordinate.
Ordinary scalarized constraints, variable-bound constraints, `NLPBlockDual`,
and nonlinear-oracle rows follow the evaluator's exact order. Any missing,
non-finite, or misaligned row makes the snapshot unavailable.

The conversion is explicit and regression-tested: NLPDiagnostics uses
`objective_weight*f + lambda'g`, hence `lambda = -MOI.ConstraintDual`; objective
weight is `+1` for minimization and `-1` for maximization. One-sided bounds keep
their canonical nonnegative lower/upper multiplier. An interval dual is stored
as the minimum-support sign split of the aggregate MOI value and is not called
unique.

`physical_complementarity_report` maps scalar-side slacks and multipliers
through positive diagonal residual transforms, checks independently declared
physical dual and complementarity tolerances, and records the invariant
multiplier-times-slack product. The solver-snapshot overload of
`physical_kkt_acceptance_report` now combines all four first-order gates. The
BMOPFTools adapter applies the same contract using authoritative semantic keys;
the solved line/load truth fixture passes feasibility, stationarity, dual, and
complementarity checks. Rotated boxes and general coupled cones are rejected
rather than componentwise approximated.

The next major phase is experiment instrumentation rather than more endpoint
algebra:

1. **Completed at the artifact boundary:** attach physical endpoint KKT
   evidence to retained Ipopt/MadNLP trace profiles while preserving native
   metric coordinates and refusing direct residual ratios;
2. **Completed for BMOPF endpoint residuals:** add registry-family attribution
   for primal feasibility, stationarity, dual feasibility, and
   complementarity. Coordinate-geometry column-family aggregation remains;
3. add specialist centre-tap, regulator, floating-neutral, and delta-winding
   truth fixtures, including relevant inequality controls;
4. implement only the coupled dual-cone transforms actually exercised by
   those fixtures; and
5. run magnitude-only and phase-only small campaigns before the bounded
   multi-time 99-bus policy matrix.

## 2026-08-12 trace and semantic-attribution checkpoint

`solver_trace_physical_endpoint_data` now produces one renderer-neutral
artifact containing the unchanged native iteration trace, solver-result
profile, last captured callback row, solver-dual provenance, and independent
physical endpoint KKT report. The relationship record explicitly forbids
subtracting or ratioing native and physical residuals without an additional
coordinate-and-tolerance translation. It also records that the final callback
row may precede the public solver result.

The BMOPFTools adapter adds semantic attribution from public registries. It
groups primal feasibility by constraint block families, stationarity by
variable-block families, and scalar-side dual/complementarity evidence by the
exact constraint-row family. Mixed transformed blocks stay mixed. Alignment
availability and registry coverage are separate gates, so an unregistered row
can be retained without qualifying a physical interpretation.

The line/load truth fixture now includes a loose registered current thermal
limit. Its Ipopt trace-plus-endpoint artifact passes the full physical KKT
contract and attributes inequality dual/complementarity evidence to
`line_current_thermal`. This validates the instrumentation path; it does not
show that the limit is active or that any scaling policy is preferable.

Next priorities are:

1. finish variable column-family aggregation in coordinate-geometry reports;
2. run small magnitude-only and phase-only matched Ipopt campaigns using the
   new paired artifacts;
3. add specialist centre-tap, regulator, floating-neutral, and delta-winding
   truth fixtures;
4. add coupled-cone dual transforms only for sets encountered by those
   fixtures; and
5. promote to the bounded multi-time 99-bus matrix only after repeatability
   and endpoint-coverage gates pass.

## 2026-08-12 matched scaling-experiment checkpoint

Variable-column attribution is now implemented alongside row-family
attribution. BMOPFTools diagonal and semantic-block geometry reports use the
public variable and constraint registries, report family-set agreement, and
keep registry completeness separate from the mathematical geometry gate.

`scaling_intervention_classification` now inspects the declared coordinate
relation before solver results are compared. It distinguishes identity,
positive diagonal magnitude changes, norm-preserving phase-like axis mixing,
combined magnitude/phase-like changes, and general linear transforms under an
explicit dense-work budget. Orthogonal axis mixing is not called an electrical
phase rotation without plugin semantics. The classic-versus-custom line/load
truth fixture is classified as magnitude-only.

`scaling_solver_experiment_comparison` and its BMOPF wrapper now assemble the
first score-free matched-run contract. Qualification requires:

1. the observed coordinate class to match the declared intervention;
2. physical covariance;
3. semantically qualified row/column geometry;
4. compatible native solver metric semantics;
5. accepted physical KKT endpoints on both sides; and
6. matching endpoint family sets.

Native work, family-resolved physical endpoint evidence, covariance, and local
geometry remain separate records. Physical family ratios are withheld when
covariance fails, and native solver residuals are never ratioed with physical
residuals.

The next major items are now empirical and fixture-driven:

1. run a small repeated magnitude-only Ipopt campaign (classic, SI, and two
   local-base policies) with transported common starts and the complete matched
   contract;
2. implement or isolate a genuine phase-only two-coordinate rotation policy,
   then test singular-spectrum invariance, block coupling, and solver work
   separately from magnitude changes;
3. add centre-tap, regulator, floating-neutral, and delta-winding truth
   fixtures with active inequality controls;
4. add coupled-cone dual transformations only for sets actually encountered;
   and
5. promote successful small protocols to repeated MadNLP runs and finally the
   bounded multi-time 99-bus matrix.

## 2026-08-12 first repeated magnitude-only campaign

The dedicated `bmopf_magnitude_scaling_campaign.jl` runner and generic
`scaling_solver_experiment_campaign_data` aggregate are implemented. The
campaign requires two or more fresh models per policy, transported common
physical starts, stable environment provenance, stable within-policy
termination, accepted physical KKT endpoints, complete matched comparisons,
and passing intervention/covariance/semantic gates. It reports ranges and does
not rank policies.

The first eight-solve truth-fixture campaign is fully qualified. Classic 1 MVA
per-unit, local 500 V / 200 kVA, and local 1500 V / 5 MVA each used four Ipopt
callback records and three line-search trials in both repeats. SI used five
records and four trials in both repeats. None entered restoration. The local
Jacobian condition proxies at the common start were approximately 5.11
(classic), 5.34 (500 V / 200 kVA), 5.84 (1500 V / 5 MVA), and 1964 (SI); SI
also increased row- and column-norm spreads by factors of 1000 relative to
classic. All physical endpoint and registry-family gates passed.

The pilot corrected an overstrict endpoint criterion. Same-point residual
covariance remains required when validating coordinate transformations, but it
is not a sound equivalence test for two independently solved near-zero
residual vectors. `physical_endpoint_equivalence_report` now requires physical
point/function/set/Jacobian covariance, objective covariance when applicable,
identical complete physical tolerance contracts, and accepted KKT endpoints.
The raw residual-vector difference remains visible but non-gating. This
distinction is regression-tested.

This result validates the experiment machinery, not a general scaling claim.
The next major items are:

1. promote the magnitude-only runner from the one-phase feasibility truth
   fixture to objective-bearing three-phase line/load and transformer cases;
2. add at least five repeats and randomized-but-physically-identical start
   strata before comparing policy robustness;
3. add factorization/linear-solver telemetry where Ipopt and MadNLP expose it;
4. implement a genuine phase-only semantic rotation intervention and test it
   independently; and
5. only after those gates, run the bounded 30-bus and multi-time 99-bus policy
   matrices.

## 2026-08-12 objective-bearing stratified scaling checkpoint

The first two empirical promotion items are complete. A new runner covers an
unbalanced three-phase economic dispatch fixture and a two-voltage-level
wye-delta transformer economic dispatch fixture. Four magnitude-only policies
were each run on five fresh models from a native start and two deterministic
bounded physical perturbations. The resulting 120-solve campaign qualified in
full, with accepted physical endpoints, objective covariance, no restoration,
and deterministic within-stratum work.

The lower local-base policy reduced callback records relative to classic on
both fixtures. SI required substantially more work and had extreme geometry
proxies. The aggressive high-base policy was slower and much more
start-sensitive on the transformer. These observations are sufficiently
controlled to choose follow-up experiments, but two fixtures and one solver do
not support a general performance claim.

The first two revised items are now complete at their honest public-API
boundary. Ipopt traces support event-preserving, registry-qualified Jacobian
family trajectories and explicitly report factorization telemetry as
unavailable. MadNLP traces retain cumulative linear-solver time,
factorization/backsolve, derivative-evaluation, and iterative-refinement
counters with callback timing semantics; they still cannot capture public
primal iterates for trace geometry. A 16-solve transformer pilot validated the
new path and showed that SI geometry, transformer-coil growth, and
regularization are distinct signals rather than one scalar mechanism.

The objective-bearing runner is now solver-parametric. The full corrected
MadNLP matrix has completed: two cases, three physical-start strata, four
policies, and five fresh replicates per cell (120 solves). Every native-start,
transported-start, endpoint, provenance, and matched-comparison gate passed.
The corresponding corrected Ipopt matrix also completed with the same design
and gates. This clears both the solver-portability and repeatability gates on
the retained compact fixtures.

Initialization covariance is now an independent mandatory campaign gate. A
cross-voltage-level audit found and corrected a BMOPFTools warm-start bug that
gave SI transformer models a physically different initial voltage level.
Generated starts now preserve physical magnitudes, phase relations, zero
neutrals, and wye/delta shifts across voltage-base choices. Corrected Ipopt and
MadNLP pilots still show moderate/classic policies ahead of SI/aggressive
policies, so the scaling signal survives removal of this confounder.

Across both solvers the moderate local-base policy required the least or tied
for the least callback work, SI required substantially more, and the aggressive
policy was strongly start-sensitive on the transformer. MadNLP adds a sharper
linear-algebra signal: the aggressive transformer policy used 15--39
factorizations for 15--26 callback records, while the moderate policy used
13--14 factorizations for 13--14 records. This is repeated association, not a
causal factorization-stability proof; pivot, inertia, fill, and backward-error
telemetry remain unavailable.

The revised next major items, in order, are:

1. implement a genuine phase-only two-coordinate semantic rotation and test
   singular-spectrum invariance separately from magnitude changes;
2. add centre-tap, regulator, floating-neutral, and delta-circulation fixtures,
   implementing coupled-cone dual transforms only when those cases exercise
   them; and
3. promote the surviving magnitude policies to the bounded 30-bus and
   multi-time 99-bus matrix with dense analysis disabled.

## 2026-08-12 transformer-aware initialization and scaling checkpoint

The initialization contract is now compositional across the represented
network rather than a collection of local angle overrides. BMOPFTools solves a
sparse, nominal-voltage-normalized ideal phasor transport system covering line
and switch conductor maps, off-three-phase single-phase laterals, centre taps,
Yd/Dy chains, regulators, and WYE/DELTA n-winding units. It publishes
per-equation-family residual evidence through the versioned
`opf_diagnostic_schema(ctx).initialization` contract.
NLPDiagnostics consumes this evidence and offers a mandatory phasor-transport
gate alongside physical native-start covariance.

The new chained Yd/Dy integration fixture initially found 12 unregistered
transformer coil-power auxiliaries. BMOPFTools now publishes those variables at
the device-physics stage, before KCL finalization, so a read-only diagnostic no
longer needs to mutate staged construction to obtain complete semantic maps.
The fixture now passes SI-versus-classic physical point, function, residual,
set, and Jacobian covariance with transformer transport residuals near
`1.6e-12`. Engine-focused transformer tests cover parent-phase inheritance,
split-phase polarity, chained Yd/Dy equations, `delta_roll`, and physical
SI/per-unit start invariance.

This closes initialization covariance for currently represented transformer
families. It does **not** close transformer nondimensionalisation research. The
next major items are now:

1. design explicit semantic variable/residual transforms that permit local
   power/current bases on opposite transformer windings while preserving KCL,
   ampere-turn, power-link, and nameplate equations exactly;
2. build matched centre-tap, open-delta-regulator, n-winding delta, and
   phase-subset scaling fixtures, requiring the new transport gate and complete
   endpoint covariance;
3. add an explicit connection-matrix representation for vector groups not
   expressible as WYE/DELTA incidence—starting with zigzag—before claiming
   initialization or scaling support for them;
4. run the genuine phase-only orthogonal control on those fixtures, holding
   magnitude bases fixed; and
5. promote only surviving policies to bounded sparse feeder campaigns, with
   dense decompositions disabled and solver linear-algebra telemetry retained.

### Local transformer-base contract implemented

The local-base roadmap now has a non-mutating public contract. BMOPFTools
partitions buses into galvanically continuous zones, validates that proposed
power bases are constant inside each zone, and publishes the voltage/current/
power conversion ratios required at each isolating transformer boundary.
NLPDiagnostics reports symmetric conversion ranges and separate algebraic and
model-application readiness gates.

The first four executable slices of that sequence are complete.
The zone-local `OpfScaling(...; power_bases=...)` form retains `S_base(bus)`
and derived `I/Z/Y` maps and applies
local base changes across isolated single-phase, center-tap, Yd, Dy, and
n-winding transformers. A
40:1 single-phase fixture passes SI/local solved-state, loss, objective,
initialization, constraint-set, residual, and physical-Jacobian covariance.
Yd and Dy endpoint fixtures pass SI/local voltage, source-power, and loss
equivalence; the chained 10 MVA → 1 MVA → 100 kVA fixture passes the complete
native-start covariance gate. NLPDiagnostics consumes bus/winding-local power
scales rather than the legacy scalar system base.

Center-tap qualification now covers both the fixed coupled-coil primitive and
the explicit T-model path. The 40:1 unequal-leg fixtures pass exact PF/OPF
endpoints, winding-current and loss recovery, initialization transport, and
complete physical-Jacobian covariance. The normalized primitive's expected
nonsymmetry is documented as a mixed-coordinate effect rather than a physical
nonreciprocity finding. The covariance adapter now resolves scalar MOI
variable-bound rows only through public BMOPFTools constraint keys. The explicit
T-model's 16 current-box rows exercise this registered path; anonymous bounds
remain a hard covariance-coverage failure.

N-winding qualification retains the full multi-port ZB representation. Each
winding current is converted into winding-1 coordinates by
`N_k(S_k/S_1)`, while ZB uses the winding-1 impedance base and shunts, limits,
and results use their winding-local bases. The loaded 50:1 three-port fixture
passes exact PF/OPF endpoints plus complete initialization, set, residual, and
physical-Jacobian covariance. Independent WYE/DELTA and `delta_roll` tests
continue to own connection-incidence correctness; floating-delta gauges are not
misrepresented as unique endpoint coordinates.

The Yd/Dy implementation records the key compositional rule explicitly:
delta-terminal current incidence carries `S_delta/S_wye`, delta-arm leakage
referral carries `S_wye/S_delta`, and winding ratings/starts use the side on
which their variables are defined. This is now an executable research result,
not only a proposed contract.

The regulator step is complete: galvanically continuous regulators retain one
voltage and power base; fixed/free-tap initialization, shared-conductor
currents, endpoint recovery, sets, and physical-Jacobian covariance are tested,
and coordinate jumps are rejected at the public proposal gate.

The AC/DC boundary step is now complete for native lossless converters.
BMOPFTools exposes stable AC/DC coordinate-base helpers and stamps
`U_dc I_dc=(S_ac/S_dc)P_ac`; NLPDiagnostics exposes the coefficient contract
and proves physical point/function/set/residual/Jacobian covariance on a
two-converter fixture for P, V, and droop control. The test also found and fixed
a diagnostics-only classification error for nonlinear normalized DC
power-limit rows.

The first matched AC/DC campaign is now implemented and has completed a bounded
pilot. It requires the native converter coefficient contract in addition to
the common-start, endpoint, covariance, intervention, trace, and repeatability
gates. All 32 solves qualified across P/V and droop/V control, four coordinate
policies, native and perturbed starts, and two fresh replicates. The initial
dense condition proxy did not predict the observed solver-work ordering, and
the ordering changed with controller mode and start perturbation. This is a
useful negative result for proxy-only policy selection, not a policy ranking.

The bounded `2^3` AC/DC base-allocation grid is also complete. All 72 solves
qualified across eight factorial cells plus the matched classic reference,
two controller cases, two physical starts, and two fresh replicates. Raising
the DC power base improved the initial condition proxy by 1.29--1.65 decades
in every stratum, but no solver-work effect had comparable directional
stability. Native droop/V work was identical across all eight cells despite
large geometry changes. This makes trajectory and linear-solver attribution,
not a finer blind grid, the immediate research priority.

The intermediate multi-converter step is now complete. A three-zone,
three-converter, meshed-DC fixture qualified all 136 solves in a full `2^4`
campaign. Perturbed P/V classic coordinates triggered 52 callback records, 166
line-search trials, and 39 regularized records per replicate; factorial cells
used 21--24 records and mostly no regularization. Perturbed droop sharing was
far less coordinate-sensitive. Semantic trace attribution identifies DC
thermal rows, converter power-circle rows, converter-power columns, and DC
branch-current columns as the dominant movers. Ipopt factorization telemetry is
truthfully unavailable, so this is not yet joint KKT-factorization attribution.

The matched MadNLP companion is now implemented. It completes the same 136
solves and retains cumulative factorization, backsolve, refinement,
derivative-evaluation, and linear-solver-time telemetry in every cell. The
linear-work attribution layer is qualified independently of endpoint
acceptance. The latest rerun qualifies both P/V start strata: all 68 solves are
locally solved, every factorial cell is complete, and every explicitly
completed fixed-variable multiplier representative passes. Droop remains
unqualified because 12 runs end at iteration limits or local infeasibility.

The campaign also exposed a generic `EvaluationPoint` defect: exact point
identity was non-reflexive when a coordinate was `NaN`, because vector equality
inherits IEEE `NaN != NaN`. Equality now uses exact `isequal` semantics and has
a regression oracle. A new non-corrective objective-weight consistency
diagnostic identifies the separate MadNLP endpoint issue as a coordinate-local
multiplier-representative inconsistency on fixed source-voltage coordinates
even when primal feasibility and complementarity pass. An explicit
fixed-variable dual completion now provides a second representative by changing
only scalar fixed-equality multipliers. The public snapshot and its failed KKT
report remain available. On the BMOPF fixture, completing 13 such multipliers
reduces maximum stationarity residual from about `1.5` to `5.6e-8`; all free
coordinates were already balanced. This closes the immediate representational
gate without claiming multiplier uniqueness or solver-internal semantics.

The qualified P/V factorial now supplies a first MadNLP work hypothesis:
raising the AC-zone-2 base reduces mean factorization count at both physical
starts (`-2.25` and `-1.625`) and has the same negative direction for
backsolves and derivative evaluations. The result is deliberately scoped to
the compact P/V fixture. It must survive mechanism-distinct cells and real
feeders before it can guide an automatic base policy.

The next sequence is:

1. select mechanism-distinct P/V policies from the qualified `2^4` artifact:
   classic, the all-low factorial anchor, AC-zone-2-high only, all-high, and
   one interaction control;
2. run those policies on bounded real BMOPF feeders with dense decompositions
   disabled, explicit sparse-work budgets, matched physical starts, and both
   Ipopt trajectory and MadNLP cumulative-work evidence;
3. isolate droop robustness in a controller-focused experiment that records
   termination basins and endpoint provenance before computing any scaling
   contrast;
4. add a multiplier-representative audit for fixed equalities and redundant
   active rows, keeping representative existence separate from LICQ and dual
   uniqueness claims;
5. qualify any remaining isolated transformer subtype only with its own
   connection and result-recovery oracle;
6. design an explicit converter-loss contract before extending covariance to
   efficiencies or custom converter builders; and
7. use controlled multi-point evidence—not raw Jacobian spread alone—to select
   candidates for per-constraint scaling and algorithm-design experiments.

The first item is now implemented as a bounded feeder-embedded runner. The
available ENWL data are single-zone AC feeders, so the runner preserves the
four-factor mechanism by embedding a namespaced feeder as AC zone 2 rather than
collapsing the factors. It retains five controlled policies, two physical-start
strata, fresh repeats, Ipopt trajectory evidence, MadNLP cumulative work, exact
source hashes, and explicit sparse admission budgets. Dense decompositions are
disabled throughout the entire covariance/geometry call chain.

Construction found and closed a missing physical residual scale for
`ibr_p_volt_watt`. The 30-bus LN embedded model now has complete scaling-map
coverage over 756 variables and 925 rows, including 28 Volt-Watt constraints,
and exact common-start round-trip transport. The next gate is the bounded
cross-solver solver campaign itself. Only after LN and LG endpoint,
repeatability, attribution, and cross-solver start gates pass should the
AC-zone-2 effect be compared with the compact-fixture direction or promoted to
99-bus snapshots.

The first complete LN case identified and closed two scale-up defects before
claim promotion: dense intervention classification despite sparse semantic
maps, and serialization of full numerical evaluations into a 651 MB
checkpoint. Intervention classification now uses 1,681 stored relation entries
instead of a hypothetical 1,427,161-entry dense relation. Feeder campaigns now
discard raw solve payloads after deriving gates and attribution, and write
atomic compact checkpoints per start stratum; the salvaged equivalent is
279 KB.

The corrected LN rerun now qualifies both starts and both solvers. The
AC-zone-2-high-only effect is favorable at the native start but strongly
unfavorable at the perturbed start: for example MadNLP changes from 4 fewer
iterations and 7 fewer backsolves to 64 more iterations, 108 more
factorizations, and 205 more backsolves relative to all-low. The roadmap must
therefore prioritize perturbation-direction and trajectory-mechanism analysis,
then the held-out 30-bus LG case. It must not promote a universal AC-zone-2
base rule or jump directly to 99-bus timing comparisons.
