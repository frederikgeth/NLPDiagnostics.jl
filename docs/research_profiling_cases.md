# Research profiling cases from the attached OPF papers

This note translates two attached papers into proposed NLPDiagnostics
profiling cases:

1. F. Geth, A. C. Chapman, R. Heidari, and J. Clark,
   *Considerations and design goals for unbalanced optimal power flow
   benchmarks*, Electric Power Systems Research 235 (2024) 110646.
2. F. Geth, F. Pacaud, and R. Heidari,
   *Solving Three-Phase Distribution OPF with Nonlinear Programming*,
   PSCC 2026 preprint.

The papers support a matrix of profiling cases rather than a single OPF test.
Each profile should preserve the physical task while varying one modeling,
initialization, scaling, or algorithmic decision.

## Proposed profile matrix

| Profile | Controlled variation | Generic core evidence | Plugin interpretation |
|---|---|---|---|
| Reference and gauge | no angle reference, one angle, three angles, fully fixed phasor | structural unmatched variables, right nullspace, dependent equalities | global angle gauge and voltage-source degrees of freedom |
| Sequence initialization | positive, negative, and zero phase rotation | exact-point values, feasibility margins, Jacobian/Hessian changes | positive-, negative-, and zero-sequence fingerprints |
| Angle/sequence constraints | absent, direct angle-difference, sequence bounds | active-set structure and constraint dependence | operational phase order and observability |
| Formulation family | IVR, SVR, SVP for the same network/task | dimensions, sparsity, evaluation time, derivative method, rank, reduced Hessian | formulation semantics |
| Power-base sweep | distribution-scale through transmission-scale bases | row/column scales, KKT tolerance semantics, objective consistency | per-unit bases and physical units |
| Low impedance | ideal connection versus decreasing positive impedance | coefficient spread, Jacobian condition, near-null modes | switch or ideal-link semantics |
| Missing-phase padding | native conductor count versus padded matrices and zero-current equations | fixed/unused variables, redundant rows, graph size, solve profile | absent terminals and component port rank |
| Degree-two buses | original series branches versus merged equivalent | graph pattern, redundant state coordinates, conditioning | topology-preserving network reduction |
| Generator symmetry | colocated equal-cost resources, reactive circulation | flat objective directions and reduced-Hessian nullspace | generator sharing/circulating reactive power |
| Balanced-data symmetry | balanced versus perturbed phase data | repeated expression/data fingerprints and nullspace multiplicity | expected phase permutation or sequence symmetry |
| Delta/wye alternatives | delta, grounded wye, neutral wye, floating wye | different structural ranks and nullspaces | star-point visibility and physical equivalence |
| Kron-reduction metadata | physical three-wire versus reduced four-wire data | representational ambiguity finding | valid neutral-current bounds and connection rules |

## Quantitative regression targets

The attached examples provide useful qualitative and quantitative anchors:

- Padding a 2-by-2 impedance representation to 3-by-3 increased one reported
  solve from roughly 1.43 seconds and 22 iterations to roughly 128 seconds and
  590 iterations. The profiler should explain the extra variables and
  equations before comparing timing.
- A small nonzero impedance substitution increased the reported Ipopt
  iteration count from 12 to 16 in one radial-network example. A sweep toward
  zero is a direct near-singularity profile.
- In the PSCC formulation comparison, the IVR reduced Hessian had a reported
  condition near `1e14`, with a smallest eigenvalue around `1.5e-8`, despite an
  equality-Jacobian smallest singular value around `1.8e-2`. This is a key
  case where "Jacobian rank looks acceptable" must not be confused with
  second-order well-conditioning.
- SVP used fewer variables than IVR in the selected example but incurred
  materially more automatic-differentiation and linear-system cost. Model
  dimension alone is therefore an inadequate complexity proxy.
- Power bases above the distribution-scale reference changed objective
  accuracy despite nominally identical stopping tolerances. Reports should
  retain physical units, scaling transformations, and solver tolerance
  semantics together.
- Zero or negative phase-rotation initialization combined with some
  voltage-source models produced the highest failure counts, whereas a
  positive-sequence start plus angle or sequence constraints was robust. This
  motivates initialization families as first-class benchmark parameters.

These numbers should be used as behavioral anchors, not hard-coded package
thresholds.

## Synthetic sparse calibration corpus

`synthetic_coupled_cone_profile_corpus()` also includes smooth 2-by-2
spectral- and nuclear-norm cone boundaries, plus a packed-symmetric PSD
boundary and a packed log-determinant boundary. The spectral case has a
separated leading singular value, the nuclear case is full rank, the PSD case
has a simple zero eigenvalue, and the log-determinant case uses `u = 1, X = I`.
The root-determinant case uses `t = 1, X = I`. Together they exercise
matrix-cone feasibility, normal extraction, mapped derivatives, and the
cone-aware qualification screen without attaching any physical semantics.
The scaled real PSD case additionally retains a nonzero off-diagonal
coordinate, guarding the √2 coordinate transformation used by MOI. Scaled
Hermitian coordinates are covered by focused MOI tests because the lightweight
profiling model does not natively store that set without bridges.
The corpus also includes nonsmooth matrix boundaries: tied spectral modes,
rank-deficient nuclear norm, and repeated-zero PSD eigenmodes. These provide
regression cases for degeneracy labels rather than solver convergence claims.
A near-singular logdet boundary separately profiles derivative-geometry
withholding at a mathematically feasible point.
An indefinite PSD point supplies a corresponding proven matrix-feasibility
violation case.

`synthetic_sparse_profile_corpus(; dimension = 32)` provides a deterministic
generic-core corpus that does not depend on an OPF plugin. It returns models
and aligned `ProfileCase`s for three affine sparse Jacobians:

- `sparse_banded_full_rank` validates sparse matching and QR on a banded,
  full-rank system;
- `sparse_banded_rank_deficient` duplicates a terminal row to exercise the
  sparse-QR deficiency path when dense SVD is guarded off; and
- `sparse_banded_scaled` alternates extreme diagonal scales to exercise pivot
  scale-spread and scaling-sensitivity evidence.

Run the corpus with `profile_cases_repeated(models, cases; ...)` before using
large-model timing or threshold changes as defaults. This corpus calibrates
generic algorithm behavior; OPF and multiconductor cases remain necessary for
physical interpretations.
`profile_synthetic_sparse_ladder(dimensions; ...)` runs that same corpus at
multiple explicitly selected sizes and retains a separate aggregate per size
and case. Use it to inspect sparse matching, QR availability, allocations, and
expected-evidence recovery as size grows; it deliberately does not infer a
portable runtime law or choose a production threshold.

`synthetic_stability_profile_corpus()` supplies complementary safe-point cases
for fragile `log(1-exp(x))`, `log(cosh(x))`, complementary-logistic,
log-sum-exp, and log-difference-exp compositions. They exercise both the
expression and non-mutating stable-reformulation stages added to `profile_case`;
the chosen points are finite so profile timing and derivative provenance remain
available while the static fingerprint still records the formulation risk.
`profile_synthetic_stability_corpus(; repetitions = 3, warmup = true)` runs
the whole set and returns named repeated aggregates, including expression- and
reformulation-stage timing, allocation, and expected-fingerprint recovery rates.

`synthetic_coupled_cone_profile_corpus()` provides a compact companion corpus
for the generic cone layer: smooth SOC, rotated-SOC, norm-one, and
norm-infinity boundaries, an SOC apex, and two affine-mapped SOC boundaries
with dependent mapped normals. Use
`profile_synthetic_coupled_cone_corpus(; ...)` to retain active-set timing and
expected-evidence recovery for cone feasibility, smoothness, qualification, and
dependent-normal fingerprints without requiring an OPF plugin or solver.

`synthetic_derivative_boundary_profile_corpus()` supplies finite but deliberately
near-boundary logarithmic, `sqrt`, reciprocal, signed/integer-power,
fractional-power, inverse-trigonometric/hyperbolic, and periodic cases. Its
expected evidence is the generic `strict_domain_derivative_amplification`
finding, so repeated profiles can measure whether valid-but-large derivative
conditions remain visible across changes. Run it with
`profile_synthetic_derivative_boundary_corpus(; repetitions = 3, warmup = true)`.

`synthetic_float32_derivative_overflow_profile_corpus()` complements this with
finite Float32 `sqrt` and reciprocal cases whose estimated derivative order is
not representable. Its profile findings should be error-level numerical
observations, preserving the distinction between Float64 mathematics and the
chosen floating-point implementation.

`synthetic_quadratic_geometry_profile_corpus()` supplies exact non-unit circle,
shifted ellipsoid, zero-radius equality, negative-radius infeasibility, and
quadratic-implied-bound-conflict and minimum-level-inequality cases. It
calibrates recovery of static
radius/semiaxis scaling evidence, implicit fixing with its nonregular
zero-Jacobian interpretation, and infeasibility proofs
independently of a solver or OPF plugin. Its two radius-two circle cases encode
the same mathematics through MOI quadratic and nonlinear representations, so
their retained profile aggregates can be compared directly; the shifted
ellipsoid has the same representation-invariance pair. Run it with
`profile_synthetic_quadratic_geometry_corpus(; repetitions = 3, warmup = true)`.

`profile_result_data` and `profile_aggregate_data` expose retained runs,
stage summaries, expected-evidence recovery, and nested diagnostic reports as
renderer-neutral dictionaries. The package does not impose a JSON dependency;
benchmark infrastructure can serialize the data with its own chosen package.
`profile_comparison_data` provides the corresponding portable stage, finding,
and numerical-metric comparisons without assigning either formulation a score.
`markdown_profile_aggregate` provides a concise human-facing view of one
aggregate's retained runs, expected-evidence recovery, stage observations,
availability-aware numerical observations, and finding stability.
`markdown_profile_comparison` provides the corresponding human-facing stage,
finding, and numerical-metric comparison without selecting a winner.

`compare_profiles(baseline, candidate)` provides a transparent comparison of
two repeated aggregates. It retains per-stage time and allocated-byte means,
their candidate-to-baseline ratios where defined, and the occurrence rates of
all diagnostic codes observed on either side. It also compares retained
availability-aware numerical metric means (currently Jacobian rank, sparse-QR
rank, and sparse-QR condition proxy); absent finite measurements remain
unavailable. It deliberately does not assign a formulation score or declare a
winner. Set the optional `ProfileCase.task` field for formulations intended to
represent the same physical task; the comparison records whether that relation
was declared, undeclared, or explicitly different.

## Core versus plugin ownership

The generic core can own:

- expression and derivative evaluation cost;
- structural decomposition;
- exact-point initialization checks;
- Jacobian/Hessian scales, ranks, and nullspaces;
- repeated or nearly repeated algebraic structure;
- model dimensions and sparsity;
- solver-independent evaluation failures; and
- expression-stability fingerprint recovery in repeated profile runs; and
- comparisons between labeled formulations of the same task.

An OPF or multiconductor plugin should own:

- component terminals and ports;
- expected conductor count and connection matrices;
- voltage angle reference semantics;
- positive/negative/zero-sequence interpretation;
- expected gauges and star-point modes;
- per-unit bases and physical units;
- ideal switch, transformer, grounding, and regulator semantics; and
- whether a Kron or delta/wye transformation preserves the intended physical
  task.

This division follows the papers' separation between engineering data, task,
formulation, and solver layers.

## Suggested implementation order

1. Add dense rank and nullspace estimates for small profiling models, always
   recording scale, method, threshold, and point.
2. Add Hessian and reduced-Hessian adapters to reproduce the IVR versus
   SVR/SVP second-order contrast.
3. Use the implemented `ProfileCase` and `profile_case` runner to retain
formulation, initialization, scale, solver-label, expected-evidence, cache,
timing, and derivative-provenance data for each case. Timings are local
runtime observations and should be collected after warm-up before comparing
formulations. Repeated profiles also report the observed recovery rate of each
`expected_evidence` code. Those codes remain profile hypotheses: an absent or
intermittent finding calls for inspection of the point, formulation, and
evidence path rather than an automatic benchmark failure.
4. Connect PMDlab and the open unbalanced benchmark data through an optional
   PowerModelsDistribution extension.
5. Add component metadata and expected-nullspace assembly before attempting
   automatic physical classification.
## Structural-stage timing

`profile_case` separately records wall-clock and allocated-byte observations
for snapshot extraction, structural graph construction, maximum-cardinality
matching, Dulmage–Mendelsohn decomposition, static analysis, expression
fingerprinting, stable-reformulation planning, evaluation, numerical analysis,
active-set analysis, and degeneracy analysis. `profile_case_repeated` exposes
descriptive summaries in `stage_timing` and `stage_allocations`.

Both measures include Julia compilation and garbage-collector effects unless
callers warm up comparable cases. They are local scaling evidence, not
solver-performance measurements or complexity guarantees.
