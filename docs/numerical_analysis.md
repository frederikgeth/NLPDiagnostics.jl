# Numerical evaluation, rank, and curvature

The numerical layer records local evidence at an explicit
`EvaluationPoint`. It does not infer global properties from one evaluation and
does not modify the source model.

## Evaluation points

An evaluation point contains:

- the exact `MOI.VariableIndex` order;
- values converted to a common floating-point type; and
- a user-visible label such as `"initialization"` or `"failed iterate 17"`; and
- typed provenance recording its origin, source, completeness, and optional
  policy metadata.

The order must equal `MOI.ListOfVariableIndices`. This matters because an
`AbstractNLPEvaluator` defines its callback coordinates in precisely that
order.

```julia
provenance = EvaluationPointProvenance(
    InitializationPoint;
    source = "application initialization policy",
)
point = evaluation_point(
    model,
    [1.0, 2.0];
    label = "initialization",
    provenance = provenance,
)
evaluation = evaluate_numerical(model, point)
summary = jacobian_scale_summary(evaluation)
report = analyze(model; point = point)
```

When a point has already been evaluated—such as a captured solver iterate or a
deliberately constructed derivative-provenance probe—use
`analyze_numerical(model, evaluation)`. This overload never re-evaluates the
model; all numerical findings are tied to the supplied evaluation object.

A dictionary keyed by `MOI.VariableIndex` may be used instead of an ordered
vector. Missing variables are rejected.

The built-in origins distinguish user points, model starts, artificially
completed starts, captured solver iterates, solver results, perturbations, and
synthetic smoke points. Initialization and solver adapters assign these types
at capture time. A `ProfileCase` carrying the explicit `:synthetic` tag also
converts an otherwise default user point to `SyntheticSmokePoint` provenance,
so persisted corpus data cannot disguise a constructed point as user input.

Point provenance limits interpretation as well as documenting it. Numerical
reports expose the kind, source, and completeness in metadata and evidence.
When a point is synthetic, artificially completed, or incomplete, any
point-local physical finding is reduced to low-confidence heuristic evidence
and the report records `physical_interpretation_limited_by_point_provenance`.
This guard does not reject the numerical observation; it prevents a convenient
coordinate vector from being mistaken for a physically meaningful operating
state.

For benchmark aggregation, `select_trusted_evaluation_points(points)` provides
an explicit default policy: only complete, finite `SolverIteratePoint` and
`SolverResultPoint` values are selected. User, initialization, perturbed,
synthetic, incomplete, and non-finite points remain in the returned rejection
list with reasons and fingerprints. Callers can widen `allowed_kinds` when a
campaign has a documented policy for another provenance class.
Serialized `ProfileCase` records include the same `point_trust` object, so
campaign validators can gate interpretation directly from benchmark artifacts.

Every model, evaluation point, and numerical evaluator source also receives a
stable SHA-256 fingerprint. `model_fingerprint(model)` is based on the copied
public MOI snapshot; `evaluation_point_fingerprint(point)` includes coordinate
order, values, label, and typed provenance; and
`evaluation_source_fingerprint(evaluation)` includes capabilities, derivative
methods, and captured failures. These are identity and reproducibility
records, not cryptographic claims about the physical model.

## Capability adapters

`evaluator_capabilities(model)` discovers three public MOI numerical sources:

| Source | Values | First derivatives |
|---|---|---|
| Ordinary MOI functions | `MOI.Utilities.eval_variables` | exact affine/quadratic derivatives, otherwise finite differences |
| `MOI.NLPBlockData` | evaluator callbacks | exact when `:Grad` or `:Jac` is advertised |
| `MOI.VectorNonlinearOracle` | oracle callback | exact sparse oracle Jacobian |

Only advertised `AbstractNLPEvaluator` features are requested during
`MOI.initialize`. Value evaluation is always available by the MOI evaluator
contract. An oracle Jacobian is currently composed into model coordinates only
when the oracle input is `MOI.VectorOfVariables`; other input functions produce
explicit unavailable evidence.

Ordinary symbolic derivatives are labeled
`central_finite_difference`. If one side is outside the function domain, the
adapter attempts a one-sided difference. A row is marked partial when no
difference can be formed for an incident variable.

`analyze_numerical` keeps this provenance explicit for the entire evaluated
Jacobian: `mixed_jacobian_derivative_provenance` identifies mixed row methods,
`finite_difference_jacobian_derivatives` identifies complete finite-difference
rows, and `partial_finite_difference_jacobian_derivatives` warns that some
finite-difference coordinates are unavailable. Its metadata provides stable
aggregate method counts for profiling (`jacobian_derivative_method_count`,
`jacobian_derivative_row_method_counts`, and complete/partial
finite-difference row counts). These findings are separate from active-set
provenance because global numerical rank and scaling can use rows that are not
currently active.
`NumericalEvaluation.objective_gradient_method` independently records the
objective derivative path (`:exact_symbolic`, constructed nonlinear AD,
evaluator callback, finite difference, partial finite difference, or
unavailable). Numerical reports retain it in `objective_gradient_method` and
flag complete or partial finite-difference objective gradients before their
stationarity implications are interpreted.

## Failures and non-finite values

Callback exceptions are captured as `EvaluationFailure` values. They do not
abort evaluation of unrelated sources. Reports distinguish:

- exact-point operator-domain violations;
- non-finite objective and constraint values;
- non-finite objective-gradient entries;
- non-finite raw Jacobian entries; and
- unavailable numerical evidence.

Exact-point domain findings use the same extensible operator rules as static
interval analysis, but with every variable interval fixed to the point value.
They are kept separate from static bound-based findings.

Exact-point derivative-domain and floating-point range checks are also run.
Thus a valid value with a singular derivative, such as `sqrt(0)`, is not
mistaken for a safe NLP evaluation point.

`analyze_initialization` can additionally run any explicit iterative sparse
right-nullspace, left-nullspace, or spectrum probe against a complete set of
`VariablePrimalStart` values. These are opt-in through the same
`iterative_*_probe_dimension` keywords used by `analyze`. Missing starts still
stop before numerical probing; the debugger never invents values merely to run
a large-model screen.

## Directional Jacobian cross-checks

`analyze_jacobian_directional_crosscheck(model, evaluation)` compares recorded
Jacobian products with central finite differences of nearby constraint values.
It uses deterministic coordinate and dense directions and labels both
perturbed sides as `PerturbedPoint` provenance. The check is opt-in because it
requires additional model evaluations:

```julia
crosscheck = analyze_jacobian_directional_crosscheck(
    model,
    evaluation;
    direction_count = 3,
    relative_step = cbrt(eps(Float64)),
)
```

`jacobian_directional_crosscheck_mismatch` is local numerical evidence, not a
diagnosis of an automatic-differentiation defect. Truncation, cancellation,
nonsmoothness, and domain crossings are competing explanations. The separate
`jacobian_directional_crosscheck_domain_limited` finding records unavailable
perturbed sides without filling them with zeros. The combined `analyze` and
`profile_case` entry points expose the same check through their explicit
`check_jacobian_directional_crosscheck` switch and tolerance keywords.
When an MOI NLP evaluator advertises `:JacVec`, the check also compares its
direct product with the stored sparse Jacobian product. Its availability and
source are retained in report metadata; an unavailable product is never
silently reconstructed as a certified operator result.

`analyze_objective_gradient_directional_crosscheck(model, evaluation)` applies
the same evidence discipline to the objective gradient. It compares
`dot(∇f, d)` with central differences of the objective value, and reports
`objective_gradient_directional_crosscheck_unavailable` when the objective or
its gradient is missing, non-finite, or domain-limited. The combined and
profile APIs expose this through `check_objective_gradient_directional_crosscheck`.

`analyze_hessian_vector_crosscheck(model, hessian)` applies the same local
calibration to the Hessian of the Lagrangian. It compares the stored Hessian
product with central differences of the Lagrangian gradient and, when the
NLPBlock advertises `:HessVec` and the supplied multipliers belong to that
block, compares the direct MOI product as well:

```julia
hessian = evaluate_lagrangian_hessian(
    model,
    evaluation.point;
    objective_weight = 1.0,
    constraint_multipliers = multipliers,
)
hessian_check = analyze_hessian_vector_crosscheck(model, hessian)
```

The `hessian_vector_crosscheck_mismatch` and
`hessian_vector_crosscheck_domain_limited` findings preserve the same
distinction between local inconsistency and unavailable evidence. The
combined and profile APIs expose this through
`check_hessian_vector_crosscheck`; dense finite-difference Hessians remain
guarded by `hessian_vector_crosscheck_max_finite_difference_variables`.

For calibration cases, `analyze_derivative_crosscheck_scale_sweep` repeats
the enabled checks over a caller-supplied list of perturbation scales. A
scale-persistent mismatch is reported separately from a scale-sensitive one;
the latter is often evidence of cancellation, truncation, nonsmoothness, or a
domain boundary rather than a single implementation defect.

## Sparse derivative semantics

`NumericalEvaluation.jacobian_entries` retains the sparse entries exactly as
the source returned them, including duplicates. MOI defines duplicate
derivative positions additively.

`jacobian_scale_summary` first sums duplicates and then computes row and column
infinity norms. It records:

- every row and column norm;
- zero rows and columns;
- rows and columns containing non-finite entries;
- smallest positive and largest finite norms; and
- their scale ratios.

Zero-row and zero-column findings are local inferences. In particular, a zero
derivative at one point does not prove structural disconnection or global
redundancy. Zero columns are not reported when any row derivative is
unavailable or partial.

## Guarded rank and nullspace estimates

`jacobian_rank_estimate(evaluation)` combines duplicate entries and uses a
dense SVD only when the complete Jacobian fits the explicit dense-work guard.
It records the point, scaling mode, relative and absolute thresholds, singular
values, rank, left/right nullities, and nullspace bases in original model
coordinates. It never turns an unavailable derivative row into a zero row.
`RankPolicy` is the typed form of these numerical semantics. It records the
backend, scaling, relative and absolute tolerance, residual-normalization norm,
dense-work guard, null-vector policy, and provenance. Pass it positionally to
`jacobian_rank_estimate` or `sparse_qr_rank_estimate`; the historical keyword
forms construct an equivalent policy and remain supported. The combined
`analyze` entry point exposes the same controls as `rank_relative_tolerance`,
`rank_absolute_tolerance`, `rank_matrix_norm`, and `rank_max_dense_entries`.

`analyze_numerical` compares both unscaled and row/column-normalized estimates.
It reports a numerical rank deficiency only when rank is below
`min(rows, columns)`; an expected rectangular right nullspace alone is not a
deficiency. When rank changes after normalization, the report calls this
scale-sensitive evidence rather than a mathematical degeneracy.

`analyze_jacobian_rank_persistence` compares both right-nullspace and
left-nullspace geometry across explicit points. Persistent right directions can
indicate recurring free-coordinate geometry; persistent left directions screen
for recurring dependent-equation combinations. Its left-nullspace finding
localizes material constraint rows with `left_nullspace_support_relative`.
Neither establishes a physical gauge, redundancy, or an IIS.

`sparse_jacobian_pattern_estimate(evaluation)` applies maximum matching to the
combined observed nonzero pattern without forming a dense matrix. Its term rank
is only an upper bound on numerical rank: a deficient bound proves local
deficiency of that observed pattern, but a full bound does not establish
numerical full rank, conditioning, or nullspaces.

## Ordinary nonlinear first derivatives

For public `MOI.ScalarNonlinearFunction` expressions, the generic evaluator
constructs an ephemeral `MOI.Nonlinear.Evaluator` with
`SparseReverseMode` and requests `:Grad`. Objective gradients and scalar
constraint rows obtained this way are labeled
`:exact_constructed_nonlinear_ad`; affine and quadratic derivatives retain the
separate `:exact_symbolic` label. If construction or AD evaluation is
unavailable (for example, an unsupported custom operator), the evaluator uses
the existing explicitly labeled finite-difference fallback instead.

## Hessian and reduced-Hessian evidence

`evaluate_lagrangian_hessian` evaluates the Hessian of an explicit weighted
objective and constraint combination. `NLPBlock` and nonlinear-oracle `:Hess`
callbacks are exact when available; ordinary MOI functions use a clearly
labeled, guarded finite-difference fallback. Raw Hessian entries retain MOI's
additive duplicate semantics.

`reduced_hessian_analysis` projects this Hessian onto the nullspace of caller-
supplied `active_rows`. It deliberately does not infer activity or multipliers
from residuals. `analyze_reduced_hessian` reports negative curvature, flat
directions, and poor positive-curvature conditioning as local evidence.

`analyze_active_set_second_order` is the convenience path for a point-local
probe: it selects scalar active rows, recovers a least-squares multiplier
representative, evaluates the corresponding Lagrangian Hessian, and reports
the reduced spectrum. Its report preserves unavailable or non-unique
multiplier evidence rather than claiming a KKT certificate.

## Feasibility and active-set evidence

`constraint_feasibility_summary(model, evaluation)` aligns evaluated scalar
rows with public MOI bounds and records residual margins, violation, and
near-bound activity. It supports scalar bounds and coordinate-wise product
sets, including `MOI.Zeros`, orthant sets, `MOI.Reals`, and
`MOI.HyperRectangle`; a different lower/upper pair is retained for every
rectangle coordinate. `active_constraint_rows` includes all equalities and
only feasible near-active inequality sides; both feasibility and activity
tolerances are explicit parameters.

`analyze_active_set` uses those selected rows for a local LICQ rank check. Its
MFCQ screen can report either a found common equality-tangent descent direction
or a numerical no-common-descent witness: nonnegative weights whose convex
combination of active inequality gradients is nearly zero in the equality
tangent space. The latter is evidence against MFCQ for the selected rows, not
an exact constraint-qualification proof. A failed screen without either result
remains inconclusive. Coupled and plugin-defined sets remain visible as
activity-semantics-unavailable evidence until a plugin provides the correct
interpretation.
The common-descent candidate is the negative minimum-norm convex-hull point of
the projected active inequality gradients, followed by an explicit strict
directional check. This avoids treating an unweighted gradient sum as decisive
when otherwise compatible inequality gradients have very different scales.
Successful common-descent findings retain the convex-hull weights, their
materially weighted active rows, and the witness scale/tolerance/iteration
provenance, so the direction is inspectable rather than a bare boolean.
Both common-descent and no-common-descent findings also retain the derivative
methods for their equality and inequality rows, together with the convex-hull
weight sum for direct witness-normalization checks.
If neither result can be obtained, `mfcq_screen_inconclusive` records that the
screen made no MFCQ claim; derivative unavailability instead produces
`mfcq_screen_unavailable`. The active-set API exposes
`mfcq_strict_tolerance`, `mfcq_witness_tolerance`, and
`mfcq_witness_relative_tolerance`, and `mfcq_witness_max_iterations`, recording
each in report metadata alongside the screen reason so a numerical witness can
be reproduced or deliberately refined. The witness tolerance is
`absolute + relative * largest projected-gradient norm`; the relative term
defaults to zero to preserve the existing absolute-tolerance behavior and must
be selected explicitly when row units or scales warrant it.
An equality-Jacobian rank loss is not treated as inconclusive: it produces
`mfcq_equality_jacobian_rank_deficient`, because equality-gradient independence
is itself part of MFCQ. The result remains a local numerical observation under
the recorded rank tolerance. Both the equality rank and threshold are also
available as `mfcq_equality_jacobian_rank` and
`mfcq_equality_jacobian_threshold` metadata.
The separate `mfcq_witness_converged` metadata distinguishes completion of the
convex-hull iteration from the stronger no-common-descent witness conclusion.
For every attempted inequality witness, report metadata retains the observed
projected-gradient scale, effective witness tolerance, and iteration count;
the corresponding witness or inconclusive finding carries the same evidence.
An inconclusive screen separately records whether the deterministic
minimum-norm convex-hull iteration budget was exhausted or it converged without
meeting either directional threshold.
Before interpreting those numerical conclusions, the report records
`active_set_mixed_derivative_provenance` when selected rows combine derivative
methods and `active_set_finite_difference_derivatives` when any selected row
uses complete central finite differences. An incomplete finite-difference row
is separately reported as `active_set_partial_finite_difference_derivatives`.
These findings cover the complete selected active Jacobian—not only a
well-determined DM block—so LICQ, MFCQ, multiplier, and nullspace evidence all
retain the derivative path that produced them.
The active-set metadata also exposes deterministic aggregate method counts:
`active_derivative_method_count`, `active_derivative_row_method_counts`,
`active_central_finite_difference_row_count`, and
`active_partial_finite_difference_row_count`. These are intended for profiling
and regression comparison; row-level provenance remains in the findings.
The no-common-descent finding additionally identifies the materially weighted
inequality rows (relative weight at least `1e-3` of the largest witness
weight), so the numerical witness can be inspected without treating tiny
iterative weights as explanatory support.
Likewise, a found common-descent direction identifies its materially supported
model coordinates at the same relative threshold; this remains a local
numerical construction rather than an exact MFCQ certificate.
The cutoff is configurable through `mfcq_support_relative` (default `1e-3`)
and is recorded in active-set metadata; it changes only displayed explanatory
support, never the underlying witness or MFCQ screen.

`recover_stationarity_multipliers` additionally computes a minimum-norm
least-squares multiplier representative for those explicit active sides,
respecting the MOI objective sense and lower/upper sign convention. It reports
the local stationarity residual and whether the active-gradient system makes
the representative non-unique. This is diagnostic evidence, not a solver dual
solution or an economic interpretation. It also reports the recovered
inequality-sign violation and bound-margin complementarity residual; these are
local consistency screens for this representative, not KKT certificates.
For a non-unique system, the finding records the complete minimum-norm
representative plus materially supported rows/sides (relative magnitude at
least `multiplier_support_relative` of the largest multiplier), while retaining the fact that other
representatives exist.
If an inequality-sign screen fails, the finding also identifies the violating
rows, lower/upper sides, and recovered multiplier values, plus the materially
large violation subset rather than assigning the failure to every active side.
The complementarity screen likewise identifies materially contributing rows,
sides, multipliers, active margins, and products, retaining the selected
activity tolerance rather than treating a near-active side as exactly active.
`multiplier_support_relative` defaults to `1e-3` and is recorded in active-set
metadata. It controls only these explanatory support subsets, never multiplier
recovery, dual-feasibility screening, or complementarity residuals.
Multiplier uniqueness, stationarity-residual, sign, and complementarity
findings also record the objective-gradient derivative method that supplied
their objective term, so finite-difference objective evidence is not mistaken
for an exact KKT-style probe.

`active_set_matching` is a separate, explicitly point-local structural view.
It matches free variables to only the aligned equality and selected near-active
scalar inequality rows. Direct `VariableIndex` constraints are MOI
variable-domain declarations. Rows for a fixed, parameter, discrete, or other
non-free variable are intentionally excluded from this free-variable matching
scope (and remain visible in report evidence). An active one-sided bound of a
free variable instead contributes a native one-variable row in the
active-set-only structural graph. Its activity selection is numerical evidence,
whereas the matching conclusion is structural for that selected pattern.
The structural-versus-numerical tangent comparison uses precisely those aligned
rows and free-variable columns; it does not quietly reintroduce excluded domain
declarations into its numerical rank estimate.
If the numerical rank exceeds the maximum rank permitted by that aligned
incidence pattern, the package reports
`active_structural_numerical_pattern_inconsistency` as a representational
warning. It is evidence of an extraction, alignment, or derivative-pattern
problem—not evidence that a structural degree of freedom has disappeared.
Callback and coupled-set rows that cannot be aligned remain visible as unmapped
rows rather than being silently omitted. An incomplete alignment emits
`active_set_structural_matching_unavailable`; the generic core then withholds
matching-based overdetermination and structural-versus-numerical tangent
claims rather than silently narrowing their scope.
`active_set_structural_decomposition(model, evaluation, summary)` exposes the
same matching together with its DM partition and irreducible well-determined
blocks for plugins and advanced inspection. If alignment is incomplete, its
partition is explicitly `nothing` while the matching retains the reason and
unmapped rows. Point, value-vector/dictionary, and evaluation overloads build
the activity summary with explicit feasibility and activity tolerances.
Pass the decomposition to `structural_graph_data(model, decomposition)` to
obtain the renderer-neutral active-set graph with matching, DM-region, and
block annotations; `structural_graph_text` and `structural_graph_dot` accept
the same `(model, decomposition)` pair for direct inspection and visualization.
`analyze_active_set` also records availability plus active DM-region and block
counts in report metadata, giving profiling code a stable aggregate interface
without parsing rendered graphs or finding prose.
When alignment is complete, the same local matching reports both selected-row
overdetermination and unmatched eligible free variables as active-set structural
underdetermination. Neither result is a numerical-nullspace proof; the latter
may represent an intended gauge, inactive equation, or missing equation.
Where an alternating-path Dulmage–Mendelsohn region is larger than its unmatched
endpoint, `active_set_dm_underdetermined_region` or
`active_set_dm_overdetermined_region` reports its coupled variables and rows.
These are local structural regions conditioned on activity selection, not
global structural proofs or numerical dependence certificates.
`active_set_dm_underdetermined_region_right_nullspace_support` analogously
identifies the materially participating coordinates of observed tangent freedom
within an underdetermined region. It does not decide whether that freedom is a
gauge, a missing equation, or a point-specific effect.
If numerical nullity exceeds the structural prediction in that same region,
`active_set_dm_underdetermined_region_additional_rank_loss` localizes the
additional point-local derivative loss without reclassifying the baseline
structural freedom.
When the selected Jacobian is numerically dependent within such an overdetermined
region, `active_set_dm_overdetermined_region_left_nullspace_support` identifies
the materially participating active rows. This is local numerical evidence of
dependent gradients, not an infeasibility certificate.
`active_set_dm_overdetermined_region_additional_left_nullity` separately flags
left nullity beyond the structural competition already implied by that region.
It localizes extra derivative dependence without treating the baseline
overdetermination itself as a numerical failure.
When the well-determined selected pattern decomposes into several irreducible
blocks, `active_set_dm_well_determined_blocks` exposes that local coupling
decomposition. It is useful for inspection and profiling, but does not claim
that objective curvature or future active sets stay block-separable.
For a multi-block active set, each square block is also checked against its
own numerical Jacobian. `active_set_well_determined_block_rank_loss` localizes
derivative rank loss to a structurally well-determined block; it is a numerical
observation, not by itself a proof of a physical singularity.
If that rank loss disappears under row/column scaling, the package instead
reports `active_set_well_determined_block_rank_scaling_sensitive`: the rank
classification depends on scaling and tolerance semantics and must not be
treated as robust degeneracy evidence.
For rank loss that persists, `active_set_well_determined_block_nullspace_support`
lists the materially supported coordinates of each local right-null direction.
This is a numerical localization aid, not an automatic gauge or physical-mode
classification. The same relative cutoff governs displayed support for global
active left/right-nullspace fingerprints and the active DM under/overdetermined
region findings. It is configurable through `nullspace_support_relative`
(default `0.1`) and recorded in active-set metadata. Changing it changes only
the explanatory support labels, not ranks, nullities, or the nullspace vectors.
Even when the block remains full rank,
`active_set_well_determined_block_ill_conditioned` reports an excessive
unscaled dense-SVD condition estimate. The configurable
`block_condition_threshold` (default `1e10`) preserves the distinction between
scaling-sensitive numerical evidence and a structural rank claim.
When row/column scaling reduces the condition estimate below that threshold,
the finding is instead
`active_set_well_determined_block_conditioning_scaling_sensitive`: the evidence
points to coordinate or unit semantics, not an intrinsic local singularity.
`active_set_well_determined_block_scale_spread` separately records excessive
row and/or column infinity-norm spread within one coupled active block, using
the configurable `block_scale_ratio_threshold` (default `1e6`). This pinpoints
the constraint and coordinate scope of a scaling problem without calling it
rank loss. Its evidence identifies the smallest and largest positive row and
column norms within the block, so the reported ratio remains actionable.
If a block's otherwise complete derivatives use central finite differences,
`active_set_well_determined_block_finite_difference_derivatives` records that
provenance before its rank or conditioning conclusions are interpreted.
`active_set_well_determined_block_mixed_derivative_provenance` similarly makes
mixed exact, AD, callback, or finite-difference row methods explicit without
claiming that the combination is invalid.
For the active-set second-order probe,
`active_set_second_order_finite_difference_hessian` records when the
Lagrangian Hessian comes from finite differences of function values;
`active_set_second_order_mixed_hessian_provenance` records mixed Hessian
sources. Both retain the Hessian step and objective-gradient method where
applicable, before reduced-Hessian inertia is interpreted.
`active_set_well_determined_block_zero_sensitivities` identifies zero rows or
columns in a selected structurally square block, separating stationary
first-order behavior from a purely structural missing-equation diagnosis.

Second-order, rotated-second-order, norm-one, norm-infinity, spectral-norm,
nuclear-norm, real and Hermitian packed positive-semidefinite, power,
dual-power, packed log-determinant, exponential, dual-exponential, geometric-mean, and
packed root-determinant, and relative-entropy cones
receive generic vector-set feasibility and boundary reports through
`coupled_set_feasibility_summary`. A cone boundary remains coupled geometry:
the generic core does not turn it into scalar active rows for LICQ, MFCQ, or
multiplier recovery. Other coupled sets remain plugin extension points through
`coupled_set_activity(set, source, values, feasibility_tolerance,
active_tolerance)`, which may return a `CoupledSetActivity` or `nothing`.
An unrecognized coupled set now emits `coupled_set_semantics_unavailable`
instead of disappearing from active-set evidence; a recognized set whose point
activity cannot be evaluated emits `coupled_set_activity_unavailable`. Both
findings retain an explicit reason, such as missing semantics, an unsupported
closure branch, or a non-finite range calculation.
`CoupledSetFeasibilitySummary.complete` and `reason` aggregate this status for
the full coupled-set activity screen.
When those conditions prevent a smooth tangent, the coupled-set
Robinson-CQ unavailable finding retains the same reason instead of merely
reporting an absent tangent.
For SOC apex, rotated-SOC axis, norm-one zero-coordinate, norm-infinity
maximum-tie, spectral-norm repeated-leading-singular-value boundary,
nuclear-norm rank-deficient boundary, real or Hermitian PSD
repeated-zero-eigenvalue boundary, rank-deficient root-determinant boundary,
and power/dual-power-cone axis
boundaries, the report additionally labels the boundary as
nonsmooth. This is a geometric fact that strengthens the case against scalar
active-row reductions; it does not supply a cone multiplier or a full conic
constraint qualification screen.
At smooth SOC, rotated-SOC, norm-one, unique-maximum norm-infinity,
strictly-positive power/dual-power-cone, and positive-`y` exponential-cone
or negative-`u` dual-exponential-cone, and positive-coordinate geometric-mean
or strictly positive relative-entropy, differentiable finite-`p` generic
norm-cone boundaries, spectral-norm boundaries with a simple nonzero leading
singular value, nuclear-norm boundaries at a full-rank matrix, and real or
Hermitian packed PSD boundaries with a simple zero minimum eigenvalue,
and packed log-determinant boundaries with a positive scale and a
well-separated positive-definite matrix, and packed root-determinant
boundaries at a positive-definite matrix,
`coupled_set_tangent_evidence`
provides an output-coordinate boundary normal. Plugins may extend the same
hook for other coupled sets. These normals remain coupled-set evidence and are
never silently inserted into scalar LICQ, MFCQ, or multiplier calculations.
The scaled packed PSD representation is also supported. Its √2 off-diagonal
coordinate transformation is applied to both feasibility reconstruction and
the returned tangent normal, so it is not silently treated as ordinary packed
PSD coordinates.
Scaled packed log- and root-determinant cones reuse the same coordinate map:
their scalar entries remain unchanged and only packed off-diagonals are
unscaled for feasibility, then rescaled by the chain rule for reported
normals.
Scaled packed Hermitian PSD cones apply this transformation to both real and
imaginary off-diagonal coordinates. This keeps complex-coordinate feasibility
and tangent evidence distinct from the real packed representation.
Square-form PSD cones additionally receive feasibility checks for both matrix
symmetry and the minimum eigenvalue of the symmetric part. Their boundary
normal is deliberately withheld: the MOI square representation embeds
symmetry equalities, so a single PSD-eigenvalue normal would omit essential
coupled geometry. The report emits
`coupled_set_boundary_tangent_semantics_unavailable` and recommends the
packed-triangle form or a semidefinite-aware plugin for local qualification.
The packed log-determinant cone is evaluated through an eigenvalue log-sum,
avoiding a direct determinant calculation. A nonpositive scale or a matrix
outside the positive-definite domain emits an availability finding rather than
an invented residual or derivative; this deliberately carries through to
initialization diagnostics.
Even on the positive-definite slice, an active log-determinant boundary whose
smallest eigenvalue is within the active tolerance of zero withholds the
tangent and emits `coupled_set_boundary_tangent_semantics_unavailable`. This
avoids presenting an arbitrarily amplified inverse-matrix derivative as robust
local geometry.
Square-form log-determinant cones additionally check their embedded symmetry
equalities. On a feasible boundary they retain the same explicit
single-normal-semantics limitation as square PSD cones, while an asymmetric
matrix is a proven set violation.
Square-form root-determinant cones follow the same symmetry-aware feasibility
policy; positive-semidefiniteness and the root-determinant epigraph are checked
together, without hiding the embedded symmetry equalities in a single tangent.
The packed root-determinant cone accepts rank-deficient feasible matrices, but
labels a rank-deficient active boundary as nonsmooth and withholds its tangent.
The generic exponential and dual-exponential slices deliberately leave their
respective nonpositive-`y` and nonnegative-`u` closure branches unavailable
rather than inferring a tangent or feasibility semantics from a limiting
representation.
The relative-entropy slice likewise leaves zero `v` or `w` coordinates
unavailable; its generic tangent is only claimed where every logarithmic ratio
is finite and differentiable.
For aligned vector outputs, the generic active-set report also maps a smooth
boundary normal through the vector-function Jacobian and records its
model-coordinate gradient together with the aligned derivative methods. A zero mapped gradient is reported as local
stationarity evidence, not treated as a regular scalar cone tangent.
When those vector rows use finite differences, the mapped gradient is retained
as a numerical observation rather than a mathematical proof.
`coupled_set_qualification_screen(evaluation, summary)` provides a deliberately
separate, local Robinson-CQ screen for completely mapped smooth cone
boundaries. It never substitutes a scalar LICQ/MFCQ conclusion.
`coupled_set_qualification_screen(model, evaluation; ...)` is the convenience
overload that first constructs the coupled-set feasibility summary. Both
overloads expose `strict_tolerance` and `max_iterations`; the report retains
the effective scale-aware tolerance and actual iteration/convergence result.
`analyze_coupled_set_qualification(model, values; label = "initialization")`
is the corresponding one-step diagnostic entry point; it evaluates the model
at the labeled point before generating the report.
When a caller has already built `coupled_set_feasibility_summary`, the
summary-based `analyze_coupled_set_qualification(evaluation; summary = ...)`
overload reuses exactly that activity evidence instead of rebuilding it. Both
qualification report paths include coupled feasibility, smoothness, mapped
gradient, and qualification findings; the standalone stage is not a bare
Boolean CQ result.
When an active-set report contains boundary, violated, or unavailable coupled
sets, `scalar_active_set_excludes_coupled_sets` makes explicit that scalar
LICQ/MFCQ and multiplier recovery did not include them. This is scope evidence,
not a claim that the scalar screen diagnosed the full conic KKT system.
Top-level `analyze(...; check_active_set = true)` also forwards
`coupled_qualification_strict_tolerance` and
`coupled_qualification_max_iterations` to this screen.
Use `analyze(...; check_coupled_set_qualification = true)` to run this
cone-aware stage without the broader scalar active-set analysis. When both
flags are set, the active-set stage supplies the coupled findings once.
The same controls apply to `analyze_initialization` and to top-level
`analyze(...; check_initialization = true)`, so initialization-point cone
geometry uses the same reproducible qualification settings.
When the optional JuMP extension is loaded, these coupled-set summary, screen,
and report entry points forward directly to `JuMP.backend(model)`; they do not
depend on variable-name parsing or JuMP-specific cone interpretation.
`coupled_set_mapped_tangents(evaluation, summary)` exposes only smooth
boundaries whose ordered vector rows, derivative methods, and finite mapped
normal gradients are complete. It is the reusable numerical input for the
Robinson-CQ screen; unavailable mappings are intentionally omitted. For every
complete smooth boundary, the screen maps its outward normal into model
coordinates and finds the minimum-norm point in the convex hull of those
gradients. A nonzero point with a checked common-descent direction is local
regularity evidence; a numerical zero convex-hull combination is local
nonregularity evidence. Incomplete mappings, nonconvergence, and nonsmooth
apex/axis cases remain explicitly unavailable rather than being folded into
scalar MFCQ. When any mapped normal uses finite-difference derivatives, even a
successful common-descent result is labeled a numerical observation with
reduced confidence rather than a local inference from exact geometry.
For multiple smooth boundaries, a completed numerical zero convex-hull
combination also produces a `coupled_set_dependent_boundary_normals` finding,
with the materially weighted sources and weights retained as a cone-aware
active-set degeneracy fingerprint.

## Structural versus numerical degeneracy

`structural_numerical_comparison` aligns ordinary equality rows and free
variables with the equality-incidence matching view, then compares its
structural matching rank with a local Jacobian rank estimate. It classifies:

- rank agreement with a structurally expected rectangular nullspace;
- rank agreement without a structural nullspace; and
- additional local rank loss relative to the structural pattern.

The final category is a local numerical inference, not a declaration of a
physical gauge. Opaque callback rows, incomplete structural support, and
unmatched coordinate systems make the comparison unavailable rather than
forcing an interpretation. `analyze_degeneracy` exposes this generic first
classification and is available from `analyze(...; check_degeneracy = true)`.
`analyze_degeneracy` also accepts the explicit iterative right-nullspace,
left-nullspace, and spectrum probe keywords. These append finite-budget sparse
screening evidence to the focused degeneracy report without changing its dense
or structural classifications.

The same stage adds two deliberately weak but inspectable fingerprints:

- a near-uniform right-null vector across aligned free coordinates, reported
  as a candidate common-coordinate shift; and
- a left-null vector concentrated on two equality rows, reported as a
  candidate two-row equation dependence.

Neither fingerprint is a physical diagnosis or a reason to suppress a finding.
Their purpose is to make the nullspace evidence easier to inspect and to give
future domain plugins a stable generic input. When additional local rank loss
has no matching generic fingerprint, the debugger reports an explicit
`unknown_local_degeneracy_mode` rather than implying a physical cause.

`ExpectedNullspaceMode` lets a caller or domain plugin declare a named
right-nullspace direction in `MOI.VariableIndex` coordinates. Pass declarations
through `analyze_degeneracy(...; expected_modes = [...])`, or extend
`expected_nullspace_modes(model, evaluation)`. The generic core reports whether
the declared direction aligns with the observed local right nullspace; it does
not suppress the underlying rank or nullspace evidence. It also compares the
span of aligned declarations with the observed nullspace: dependent
declarations and observed directions outside an otherwise-aligned declared span
are reported explicitly. These are representational findings, not claims that
the remaining direction is mathematically erroneous or physically unexpected.

## Reproducible formulation profiles

`ProfileCase` records a named point together with formulation, initialization,
scale, solver-label, tags, metadata, and expected-evidence hypotheses.
`profile_case(model, case)` runs static, expression, stable-reformulation,
generic numerical, active-set, and degeneracy stages without invoking a solver.
Its `ProfileResult` retains the
reports, cache hits/misses, derivative-row-method and capability-source counts,
wall-clock time by stage, and per-evaluation callback statistics. Expression
findings such as stability fingerprints, and static structural or
representational findings, participate in repeated-profile evidence recovery
alongside numerical findings. Exact NLP
evaluator initialization/value/gradient/Jacobian calls and oracle
value/Jacobian calls are counted separately; ordinary MOI work is recorded as
one symbolic-stage measurement.
For callers that manually construct `ProfileResult`, the former positional
constructor remains available and creates empty static/expression/reformulation reports;
`profile_case` always supplies the fully populated reports.

The potentially costly iterative sparse screens stay out of this default path.
Set `iterative_right_nullspace_probe_dimension`,
`iterative_left_nullspace_probe_dimension`, and/or
`iterative_spectrum_probe_dimension` when a profile case explicitly calls for
them. The profile uses its already captured `NumericalEvaluation`, records a
separate timing/allocation stage for each requested screen, and appends the
resulting evidence to the numerical report. These remain finite-budget
candidate-dependency and spectral-spread observations; profile aggregation does
not convert them into nullity, redundancy, condition-number, or physical
claims.

Stage timings include Julia compilation and allocation effects unless callers
warm up a comparable case first. They are useful profiling evidence, not a
portable solver-performance benchmark.

`profile_case_repeated(model, case; repetitions = 3, warmup = true)` performs
independent runs with fresh caches, discards the optional warm-up measurement,
and returns minimum, mean, maximum, and population standard deviation for each
stage. It also returns per-stage diagnostic-code occurrence fractions, making
stable versus intermittent findings explicit across retained runs. Its
`numerical_summary` separately aggregates available finite Jacobian rank,
sparse-QR rank, and sparse-QR pivot-proxy observations. When a sparse probe is
explicitly requested, it also aggregates right- and left-candidate
small-residual counts, the large-spread count, and largest spectral-scale
proxy. Each metric records both
retained-run count and available-value count, so unavailable diagnostics are
never silently averaged as zeros. Probe summaries remain observations of a
finite algorithmic screen, not rank, condition-number, or physical estimates.
These summaries describe local observed variation; they are not statistical
confidence intervals.

## Cache lifetime

`EvaluationCache` stores a complete evaluation under the model object, cache
generation, evaluation point, numeric type, and finite-difference step.
Repeated requests at the same point do not reinitialize or call an evaluator.

MOI does not provide a generic model mutation counter. After changing model
functions, sets, callbacks, or operator registrations, call `empty!(cache)`
before reusing it. This clears entries and advances the cache generation.

## Solver postmortem records

`SolverPostmortem` preserves a solver's normalized termination, native status
text, iterations, residuals, complementarity, restoration outcome, and
metadata. `analyze_postmortem` reports those observations as evidence. In
particular, a reported infeasibility or numerical failure is a solver-reported
outcome, rather than a mathematical proof about the model. Solver extensions
should map native result information into this schema without discarding the
raw status.
An unknown or adapter-specific normalized termination is retained as
`solver_unclassified_termination`; it is never silently treated as a successful
or mathematical outcome.

For a single combined handoff report, pass an explicitly captured
`SolverPostmortem` as `analyze(model; postmortem = record)`. This only appends
the normalized postmortem findings; it does not query a solver or alter the
model. Postmortem metadata is namespaced with `postmortem_` so it cannot
overwrite model-analysis metadata.

The same combined entry point accepts `solver_log` plus `solver_name` and
appends both raw log markers and structured iteration-trace evidence. If a
postmortem is supplied, its solver name may be used instead; an explicitly
different `solver_name` is rejected rather than mixing evidence from two
solver runs. Log and iteration metadata use `solver_log_` and
`solver_iterations_` namespaces. `solver_log_residual_tolerance` controls the
structured trace screen only.

When both a postmortem and log are supplied, the combined report also runs
`analyze_postmortem_log_consistency`. A strongly successful normalized status
(`:optimal`, `:locally_solved`, or `:success`) paired with explicit raw failure
markers receives a medium-confidence representational warning. This catches
potentially mixed runs while preserving the possibility that a solver recovered
from an earlier phase or the supplied text is appended.
When both sources expose iterations, it also accepts either an exact final
printed iteration match or the common zero-based offset; any other discrepancy
is separately reported as a convention-or-provenance warning.
When both sources expose an objective, a large factor-based difference between
the postmortem value and final parsed row is also recorded as a scaling/timing
warning. `solver_log_objective_agreement_factor` controls that deliberately
conservative combined-report screen.

Explicit iteration-point bindings can also be appended with
`analyze(model; iteration_bindings = bindings)`. The combined report delegates
to `analyze_iteration_points`, retains its metadata under the
`iteration_points_` namespace, and does not create points from log text.
`iteration_point_relative_step` controls only evaluation of those supplied
points.

### Ipopt extension

When both `NLPDiagnostics` and `Ipopt` are loaded,
`solver_postmortem(model)` maps an Ipopt optimizer's raw application status
and public MOI result attributes into a `SolverPostmortem`. It records
barrier iterations, objective value, solve time, and MOI termination/primal/
dual statuses. Ipopt does not expose final residuals through stable public MOI
attributes, so the adapter leaves residual and complementarity fields unset.
Only the `Restoration_Failed` raw status is interpreted as an unsuccessful
restoration attempt.

With the optional JuMP extension, `solver_postmortem(jump_model)` delegates to
the currently attached optimizer. It is read-only, but the solver adapter still
operates on the actual optimizer: call it after `optimize!`, or after JuMP has
attached the optimizer. An unattached or unsupported optimizer produces an
explicit error rather than a guessed postmortem.

For live iteration evidence, `ipopt_iteration_trace_capture(model;
capture_points=false)` installs Ipopt's public `CallbackFunction` intermediate
callback and returns an `IterationTraceCapture`. Each callback row records
objective, primal/dual infeasibility, primal and dual step lengths, barrier
parameter, step norm, regularization size, line-search trial count, iteration
number, and regular or restoration phase. With `capture_points=true`, callback primal coordinates are
copied through `MOI.CallbackVariablePrimal` and retained as explicitly
captured `EvaluationPoint` bindings. No solver internals or log reconstruction
are used; call `iteration_trace(capture)` after `optimize!`.
For the common solve-and-inspect workflow, `ipopt_optimize_with_iteration_trace!(model;
capture_points=false)` installs the callback, calls `optimize!`, and returns the
frozen `SolverIterationTrace` directly. An optional `capture` keyword lets a
caller reuse a collector across controlled solve phases.
`ipopt_profile_with_iteration_trace!` goes one step further: it solves, then
profiles the final public MOI result with that trace and returns a
`SolverTraceProfileRun`. `profile_result_data` serializes the trace and profile
as separate evidence sections.

Serialized iteration traces use schema
`nlpdiagnostics-iteration-trace-v2`. Every row contains the optional telemetry
columns plus typed `metric_semantics`; the top-level `telemetry_coverage`
counts how many records actually supplied each column. Ipopt's objective is
labelled in original model coordinates, while its callback infeasibility
columns are labelled solver-scaled and its barrier quantity solver-defined.
These labels describe provenance, not accuracy, and prevent a solver-scaled
residual from being silently compared with a recomputed raw model residual.

### MadNLP extension

When `MadNLP` is loaded, the same `solver_postmortem` entry point recognizes
its MOI optimizer. The extension records public MOI statuses, barrier
iterations, objective value, solve time, and MadNLP's raw status string. It
does not inspect MadNLP internals to infer residuals or restoration history;
only the raw `Restoration Failed` status records unsuccessful restoration.

`madnlp_iteration_trace_callback()` constructs a MadNLP
`AbstractUserCallback` for the public `intermediate_callback` option and
returns `(callback, capture)`. The callback records objective, primal/dual
infeasibility, complementarity, primal and dual step lengths, barrier
parameter, regularization size, iteration, and regular/restoration phase. The objective is unpacked through MadNLP's public callback accessor so
it remains in model objective units rather than MadNLP's internal objective
scaling. MadNLP's callback API does not provide a stable MOI primal-vector
interface, so this adapter deliberately captures metrics only; it does not
invent `EvaluationPoint`s. After `solve!` or `optimize!`, freeze the collector
with `iteration_trace(capture)`.
MadNLP callback residual, complementarity, barrier, and regularization columns
are labelled solver-defined until the adapter can document a stronger public
coordinate contract.
The one-call helper `madnlp_optimize_with_iteration_trace!(model)` performs the
same attach, solve, and freeze sequence for a JuMP or MOI MadNLP model. It
returns metric records only, preserving the callback API's explicit limitation
around primal-vector capture.

For controlled postmortem regression cases, run
`benchmarks/solver_failure_cases.jl`. It exercises deliberately limited,
infeasible, invalid-domain, and restoration-candidate models and records the
intended signal separately from the observed termination. Use
`benchmarks/summarize_solver_failure_cases.jl` to aggregate resource-limit,
infeasibility, numerical-failure, restoration, and unclassified outcomes; a
different observed category is evidence to investigate, not an assertion
failure. The harness configures the solver-owned `output_file` option by
default, so each record also contains `<solver>__<case>.log` when the backend
supports file logging. Set `NLPDIAGNOSTICS_FAILURE_CAPTURE_LOGS=false` to
disable that configuration. If logs were captured by an outer process, set
`NLPDIAGNOSTICS_FAILURE_LOG_DIR` to files named `<solver>__<case>.log`; those
files take precedence and the harness correlates their raw markers and
structured iteration rows without reconstructing logs from callback metrics.
The serialized record retains the primary solve profile beside the same
supplied log's marker, iteration, and postmortem/log-consistency reports. A
missing log is reported as missing evidence, never as evidence that no
restoration or numerical event occurred; each record identifies whether its
log source was the solver-owned file, an external file, or unavailable.
For process isolation around native solver exits, use the dependency-light
`benchmarks/launch_solver_failure_cases.jl` launcher. It keeps the parent from
loading JuMP or a solver and preserves completed logs/process statuses when a
child exits before normal JSON serialization. Set
`NLPDIAGNOSTICS_FAILURE_CHILD_TIMEOUT_SECONDS` to bound each child; timeout
records are reported explicitly as `process_timeout`, with the partial process
log retained. The direct harness remains an in-process, low-overhead smoke
test.
`madnlp_profile_with_iteration_trace!` returns the same combined
`SolverTraceProfileRun` shape, with the MadNLP metric-only trace retained next
to the final-result profile.

## Raw solver-log evidence

`solver_log_observations(log)` retains the original line number and text for a
small set of explicit generic markers: restoration-phase entry, restoration
failure, invalid-number
text, infeasibility text, termination limits, and selected numerical-failure
phrases. `analyze_solver_log(solver, log)` groups these lines into findings.
Explicit overflow and underflow text are retained as separate floating-point
range markers, not collapsed into a generic invalid-number diagnosis.
Explicit singular-matrix or rank-deficiency text is likewise retained as a
local linear-system observation, with follow-up directed to Jacobian and
active-set rank diagnostics rather than a global singularity claim.
It does not parse iteration tables, reconstruct residuals, or treat log text as
a proof of infeasibility or optimality. Future solver extensions can add
solver-specific fields while preserving these raw, inspectable evidence lines.
The separate `analyze_solver_iterations` parser handles complete Ipopt and
MadNLP iteration rows, preserves restart segments and suffix annotations, and
does not reinterpret residual headings as infeasibility outcomes.
Restoration entry and restoration failure remain separate observations: an
attempt is never upgraded to a failure or an infeasibility certificate.

## Structured iteration-log evidence

`solver_iteration_records(log)` recognizes complete numeric rows below the
documented Ipopt and MadNLP iteration headers. It retains the raw row and line
number along with objective, primal/dual infeasibility, and the columns common
to each format. Ambiguous or incomplete rows are not partially parsed.
`solver_iteration_summary(records)` separately records log-order first/final
rows, minima of the printed primal and dual columns, formats, and annotated-row
count; it returns no summary for an empty trace.
`solver_iteration_segments(records)` splits an appended or restarted trace when
the printed iteration number decreases. The final-residual regression heuristic
uses only the final segment, avoiding comparisons against an earlier logged
solve; a segment boundary is not attributed to a specific solver event.
Final-segment findings retain their start/end log lines and printed iteration
range in report metadata and evidence for trace provenance.
`analyze_solver_iterations(solver, log)` reports a final recorded residual,
an optional residual-regression heuristic, and an optional final-segment tail
stagnation heuristic. The latter requires at least three final-segment rows
that remain above the supplied tolerance and improve by less than its explicit
factor threshold. These are log-column observations, not independently
recomputed KKT residuals or convergence certificates.
When the same final window stays above tolerance and every parsed primal-step
column is below `small_primal_step_threshold`, it separately reports a stalled-
step heuristic. This does not assign a line-search or restoration cause to the
trace.
When one printed residual persistently dominates the other by an explicit
factor, the report records that primal-versus-dual imbalance as an observation
to guide follow-up diagnostics; it does not treat the column ratio as a
solver-independent KKT conclusion.
Rows with a solver-specific iteration suffix are also surfaced as annotation
evidence. Their meaning is intentionally not generalized across solvers.
The separate raw-log scanner preserves explicit solver text about reported
unboundedness and diverging iterates. Both are numerical observations of a run,
not proofs of a global objective ray, physical instability, or model failure.
Normalized solver postmortems carry the same distinction for native
`diverging_iterates` and `slow_progress` statuses, so solver extensions retain
their provenance without converting them into mathematical certificates.
Invalid-model/option and memory-limit statuses are separately retained as
representation and resource outcomes, preventing solver configuration or
capacity failures from being mislabeled as mathematical diagnoses.
Acceptable-solution, feasible-point, and interrupted statuses likewise retain
their native non-final semantics rather than being silently collapsed into
successful convergence.

## Bound iteration points

`bind_iteration_points(records, points)` connects a parsed row to a caller-
supplied `EvaluationPoint`; it never reconstructs an iterate from log text.
An ordinary integer key selects matching printed iteration numbers. For an
appended or restarted trace, `(segment, iteration)` keys select one row within
the monotone segments returned by `solver_iteration_segments(records)`, so a
reused printed iteration number cannot silently refer to the wrong run.
When a legacy integer key actually selects the same printed number in multiple
segments, `analyze_iteration_points` emits
`solver_iteration_restart_binding_ambiguous`; it preserves the bindings but
makes the representational ambiguity explicit.
`analyze_iteration_points(model, bindings)` runs numerical diagnostics at each
bound point and compares the log's primal-infeasibility column against three
recomputed quantities: scalar-bound violation, coupled-set violation, and
their maximum. A large mismatch is representational evidence, since solvers
may use different scaling or feasibility semantics; it is not a solver-error
claim. Its opt-in `iterative_*_probe_dimension` keywords run the same sparse
right-nullspace, left-nullspace, and spectrum screens independently at every
explicitly bound point. Aggregate requested/finding counts remain explicit;
the finite probes do not turn an iteration trace into a rank or redundancy
certificate. With `check_iterative_right_nullspace_persistence` or
`check_iterative_left_nullspace_persistence`, same-segment points can also be
screened for persistent candidate geometry; each requires its corresponding
probe dimension and remains separate from dense rank persistence. When an objective is available, it also compares the logged objective
with the model objective at the supplied point. Potential barrier, penalty,
scaling, and point-alignment differences remain evidence rather than an
assumption that the log column is the unmodified model objective.
Each bound row also records the point fingerprint, provenance kind/source, and
completeness in report metadata. Serialized trace bindings retain the same
fields, so benchmark summaries can quarantine synthetic or incomplete points
without reopening nested point records.

Dense rank persistence also compares left-nullspace geometry. Its
`rank_persistence_left_nullspace_support_relative` control is forwarded to
`analyze_jacobian_rank_persistence` and limits the affected constraint rows to
material coordinates of the observed left-null directions. It is localization
evidence, not a declaration of a redundant constraint or an IIS.
Persistent right-nullspace evidence is localized analogously with
`right_nullspace_support_relative`: only material variable coordinates across
the observed subspaces are listed. This narrows inspection scope but does not
turn a local numerical direction into a proven gauge.

For a persistent right-nullspace, declared expected modes are checked both
individually and as one independent span. The span screen prevents multiple
plausible-looking declarations from being mistaken for a jointly observed
gauge when their combined dimension exceeds, or is misaligned with, the
observed nullspace. `expected_mode_span_alignment_threshold` and
`expected_mode_span_rank_relative_tolerance` are explicit numerical controls;
an observed span supports the declaration only locally and does not validate
its physical semantics.

`analyze_jacobian_scaling_persistence(evaluations)` is the corresponding
cross-point row/column scale screen. It reports whether finite scale-spread
ratios remain within an explicit factor and becomes unavailable rather than
comparing non-finite derivatives. `analyze_jacobian_rank_persistence` includes
this evidence automatically, so a rank change can be read alongside a separate
answer to whether derivative scaling also changed. Neither outcome identifies
the mathematical cause of a rank change.

When rank changes, `analyze_jacobian_rank_persistence` also attaches
row-level derivative-provenance persistence evidence. The standalone
`analyze_jacobian_derivative_provenance_persistence` screen compares recorded
method labels (for example, exact symbolic, AD, or finite differences) rather
than derivative values. A method change or partial derivative path can explain
why a numerical conclusion needs rechecking, but it does not establish that
the model or the solver is wrong.

For bound solver iterations, rank-persistence controls are exposed as
`rank_persistence_*` keywords on `analyze_iteration_points`; the combined
`analyze` API forwards the corresponding `iteration_rank_persistence_*`
keywords. The report records the requested left-support, scaling, and
expected-mode thresholds, preserving the tolerance semantics used to interpret
each restarted segment.
`check_jacobian_condition_persistence = true` independently adds finite-only
conditioning comparison within each segment; the combined entry point exposes
the same request as `check_iteration_jacobian_condition_persistence`. It never
compares endpoints across restarts.
Its optional `relative_step` is passed directly to the point evaluator and is
recorded in report metadata; all remaining keyword arguments configure the
numerical analysis of that captured evaluation.

Within any one monotone iteration segment containing two or more bound points,
`analyze_iteration_points` additionally emits a heuristic trace-disagreement
finding only when logged primal infeasibility falls by more than the configured
factor while recomputed feasibility rises by more than that factor. It never
compares trend endpoints across a restart boundary. This can reveal misaligned
point capture, scaling, or semantics, but does not attribute the cause.

For non-feasibility objective senses, it applies the same within-segment rule
to objective trends, reporting disagreement when the logged objective improves
in the declared optimization direction while the recomputed model objective
moves meaningfully in the opposite direction. This is a point-alignment and
objective-semantics heuristic, not a statement about solver correctness or
objective quality.

## Sparse QR rank estimate

`sparse_qr_rank_estimate(evaluation)` uses Julia's SuiteSparseQR-backed sparse
factorization to give a local rank estimate without forming the dense Jacobian
required by the guarded SVD path. Its method, row and column permutations,
threshold, pivots, matrix norm, and policy are retained explicitly. On matrices
within its separate dense-evidence guard, it also records the relative
factorization residual for the permuted `Q*R` reconstruction. Exceeding that
guard withholds only the residual; it does not densify the matrix or make the
sparse rank estimate unavailable. This is a numerical estimate, not a
nullspace calculation or a proof of exact rank; the sparse pattern matching
estimate remains the separate structural upper bound.
When the dense SVD is unavailable, a deficient sparse-QR estimate is reported
as `sparse_qr_jacobian_rank_deficiency` with medium confidence; it is never
presented as an exact rank proof.
The numerical report also compares unscaled and row-column-scaled sparse-QR
ranks. A disagreement produces `sparse_qr_rank_scaling_sensitivity`, which is
evidence that pivot-threshold semantics depend on scaling, not a diagnosis of
structural degeneracy.
When the guarded dense SVD is also available, the report cross-checks both
unscaled and row-column-scaled ranks against sparse QR. It emits
`dense_sparse_qr_rank_agreement` or `dense_sparse_qr_rank_disagreement` with
both methods' thresholds in the evidence. Agreement is stronger local
numerical support, not an exact-rank proof; disagreement is explicitly
method-sensitive evidence rather than a structural conclusion.

`analyze_jacobian_rank_tolerance_sweep(evaluation)` makes threshold sensitivity
explicit for the guarded dense-SVD estimator. It reports the supplied relative
tolerances, resulting absolute singular-value thresholds, and ranks. A stable
sweep is only stronger local numerical evidence; a changing sweep warns that
the apparent nullity is tolerance-sensitive rather than proving a formulation
defect.
The combined `analyze` entry point exposes this opt-in screen through
`jacobian_rank_tolerance_sweep_tolerances` for an explicit point or supplied
evaluation; it is never silently run as part of the default numerical stage.
With `check_initialization = true`, the same option evaluates the complete
declared start point; incomplete starts still prevent numerical probing rather
than being filled implicitly.

`analyze_jacobian_condition_persistence(evaluations)` compares finite guarded
dense-SVD condition estimates across explicit points. It is unavailable rather
than forming a ratio when any local estimate is rank-deficient, non-finite, or
blocked by the dense-work guard. Stable or changing conditioning is numerical
evidence about local linear algebra, not a global bound or a solver diagnosis.
When dense SVD is unavailable, an extreme retained-pivot ratio can also emit
`sparse_qr_pivot_scale_spread`. This is intentionally a heuristic pivot-scale
warning, not a numerical condition estimate.

## Iterative sparse null-direction probe

`jacobian_linear_operator(evaluation)` is the common product boundary for the
iterative probes. It combines additive entries into one inspectable sparse
matrix and becomes unavailable if any derivative row is incomplete or any raw
or combined entry is non-finite. `jacobian_linear_operator(model, evaluation)`
prefers public MOI `:JacVec` and transposed-Jacobian products for NLP-block rows
and uses the assembled sparse representation for all remaining rows. Before
selecting that hybrid path it compares both native products with the assembled
Jacobian on deterministic directions. A callback error or discrepancy causes
an explicit `:assembled_sparse` fallback with `native_unavailable_reason`; it
does not silently feed an inconsistent product into a nullspace probe.
`jacobian_product` and `jacobian_transpose_product` expose the selected path for
method-development experiments. This consistency screen is a representation
check, not independent proof that either derivative representation is correct;
the finite-difference directional cross-check remains the independent local
screen.

`iterative_right_nullspace_estimate(evaluation)` is an explicit, opt-in
sparse-matvec probe for one candidate right direction with a small Jacobian
residual. It uses normalized shifted `J'J` products and records both the
returned residual, the selected matrix norm, the dimensionless backward
residual `norm(J*v)/(norm(J)*norm(v))`, and whether its direction iteration
stabilized. It does not
claim a nullspace, its dimension, or exact rank: use the guarded dense SVD when
such a local numerical statement is required. The deterministic seed makes the
candidate reproducible, while its residual keeps the evidence inspectable.
`iterative_right_nullspace_subspace_estimate(evaluation, dimension)` provides
the analogous block probe when several candidate directions are useful; it
returns orthonormal columns and raw and dimensionless residuals for each
column. The left probe records `norm(J'*u)/(norm(J)*norm(u))` analogously.
Neither API is
used implicitly by `analyze_numerical`, because a requested candidate subspace
must not be confused with an inferred nullity.
`analyze_iterative_right_nullspace_probe(evaluation; ...)` is the corresponding
explicit report wrapper. It records probe budget, convergence, residual scale,
and material variable support for directions below a caller-selected residual
threshold. Its findings are candidate numerical evidence only; the wrapper
does not certify a nullspace, numerical rank, or physical mode.
Every iterative report records `operator_source`. Model-based convenience
overloads construct the hybrid operator and therefore use checked MOI products
when available; evaluation-only overloads use the assembled sparse operator.

`iterative_jacobian_spectrum_estimate` combines a normal-operator power scale
with the block probe's small-direction residuals. Its reported spectral spreads
are screening proxies only—not condition estimates or singular-value bounds—so
they remain opt-in and are never emitted as automatic conditioning findings.
`analyze_iterative_jacobian_spectrum_probe(evaluation; ...)` provides the
corresponding explicit report wrapper. It reports large spread proxies as
heuristics and retains the probe dimension, convergence, residuals, and
threshold; it never labels a proxy as a condition number.

## Active-set dependence fingerprints

When the selected active Jacobian fails its LICQ-style rank screen,
`analyze_active_set` also inspects left-nullspace vectors. A vector whose
material support is concentrated on two selected rows produces
`active_candidate_two_row_dependence`, naming those rows directly. This is a
point-local heuristic fingerprint, not proof of duplicate constraints: activity
selection and derivative cancellation can produce the same pattern.
Compact support on three through eight selected rows produces
`active_candidate_multirow_dependence`, making a small locally dependent
cluster inspectable without asserting a global redundancy proof.
A right-null vector that is nearly uniform across all evaluated coordinates
produces `active_candidate_uniform_tangent_shift`. This is a candidate
common-coordinate tangent freedom, not a physical gauge classification; units
and domain semantics remain necessary.
A right-null vector with material support on a strict, small subset of the
evaluated coordinates produces `active_candidate_compact_tangent_direction`.
It localizes a local degree of freedom or weakly identified subsystem, but does
not itself distinguish a missing equation, an expected gauge, or derivative
cancellation at the sampled point.
When the material support is one coordinate,
`active_candidate_single_coordinate_tangent_direction` instead names that
variable directly. It is a higher-priority debugging cue, but still only a
heuristic: structural freedom, a stationary nonlinear derivative, and an
incomplete derivative path can have the same local fingerprint.
`analyze_active_set(...; expected_modes = ...)` also checks each declared
`ExpectedNullspaceMode` directly against the selected active Jacobian. An
observed result is consistency with a plugin declaration at one point, while a
non-observed result can mean that active constraints removed the mode; neither
result validates or disproves the underlying physical interpretation.
When declared modes are individually tangent, their independent span is also
compared with the active right nullity. A larger observed nullity produces
`active_undeclared_tangent_directions`; dependent declarations are separately
reported as `active_expected_nullspace_mode_declarations_dependent`.
The same comparison also projects every observed active null vector onto the
declared independent span. `active_expected_nullspace_span_does_not_cover_observed`
is emitted when tangent declarations fail to cover one or more observed
directions, including equal-dimensional but differently oriented spans. It is
local numerical evidence about the selected active set, not a rejection of the
plugin's physical interpretation.
Conversely, `active_expected_nullspace_span_exceeds_observed` records a
declared independent span larger than the observed numerical nullity. Since
the declaration and rank checks can use different tolerances, this is a prompt
to inspect tolerance and derivative semantics—not a physical contradiction.
For complete active-set incidence alignment, the diagnostic also compares the
free-variable matching prediction with the numerical tangent nullity.
`active_structurally_expected_tangent_nullspace` identifies matching expected
freedom, while `active_unexpected_local_tangent_rank_loss` identifies extra
point-local loss. Multiplier recovery uses a minimum-norm SVD solve so a zero
active Jacobian remains diagnostic evidence instead of aborting the analysis.

When second-order analysis finds a near-flat reduced-Hessian eigenvector, it
also checks whether its full-coordinate tangent direction is nearly uniform.
`reduced_hessian_candidate_uniform_flat_direction` is only a local numerical
fingerprint for a possible common-coordinate flat mode: it does not establish
a physical gauge, since coordinate units and domain semantics are not present
in the generic core.
It also records `reduced_hessian_candidate_compact_flat_direction` when a
near-flat eigenvector has material support on a strict, small subset of the
evaluated coordinates. This is a heuristic pointer to a localized weakly
identified subsystem, not proof of a missing equation or a physical mode.
Plugins can instead declare `ExpectedNullspaceMode` values for
`analyze_reduced_hessian` (or the active-set second-order convenience path).
The report then records whether each declaration is an observed near-flat
tangent direction at that point. This is a consistency check—not a claim that
the declared physical interpretation, model, or reference choice is correct.
`analyze_reduced_hessian_persistence` compares explicitly supplied snapshots
at multiple points using flat-subspace principal angles. It reports persistent
or changing local flat geometry without choosing points, recomputing Hessians,
or turning repeated numerical evidence into a physical claim.
Its model-aware overload additionally maps the material support of a persistent
mode to generic incidence components, distinguishing a structurally localized
mode from one that spans components. This remains syntactic structural evidence
and does not attach electrical or other domain semantics.
When optional `ComponentMetadata` is supplied (or exposed by a plugin), the
same overload also records which declared component scopes overlap a persistent
mode. That is plugin-declared context, not validation of the metadata, expected
rank, units, or a physical interpretation.
`ExpectedNullspaceMode` declarations can also be compared as an independent
span against the persistent flat subspace. This principal-angle comparison is
stronger than a single-point directional check, while still reporting only
consistency with a declaration rather than proof of a physical gauge.
Persistence analysis also compares the material coordinate support of each
flat subspace. Stable support and changing support are reported independently
of subspace alignment, so a localized mode that migrates between variables is
not hidden by an aggregate flat-direction count.
The same screen also compares the explicitly supplied reduced-Hessian active
rows when the evaluated constraint-row identities align. This distinguishes a
changing tangent selection from curvature changes under a stable active set;
it never infers which constraints should have been active.
When those rows align, persistence analysis also compares the recorded
active-Jacobian numerical rank and tangent dimension. This provides first-order
context for changing flat curvature, while preserving the distinction between a
stable selected row set and a change in local derivative geometry.
If each supplied snapshot retains its `HessianEvaluation`, persistence analysis
also compares the row-aligned multiplier representative and objective weight.
This is opt-in evidence about the supplied representatives, not a claim that
multipliers are unique or that a dual solution has been verified.
Persistence analysis also compares finite Jacobian row and column
scale-spread ratios with an explicit change-factor threshold. This exposes
operating-point-dependent derivative scaling beside rank and curvature changes;
it is numerical evidence, not proof that a formulation is mathematically
wrong.
The retained reduced-Hessian spectra are also compared directly by maximum
absolute eigenvalue. This isolates broad curvature-magnitude changes from
flat-subspace orientation and Jacobian scaling, while remaining a local
numerical observation rather than a physical stability classification.

## Explicit iterative sparse probes

For problems beyond the dense-work guard, the iterative probes are opt-in
screens over an explicit finite iteration budget:

```julia
candidate_report = analyze_iterative_right_nullspace_probe(
    model, point; probe_dimension = 2, iterations = 200,
)
dependency_report = analyze_iterative_left_nullspace_probe(
    model, point; probe_dimension = 2, iterations = 200,
)
spectrum_report = analyze_iterative_jacobian_spectrum_probe(
    model, point; probe_dimension = 2, iterations = 200,
)
```

All three functions also accept a values vector or an already captured
`NumericalEvaluation`. Passing an evaluation avoids re-evaluating the model;
the model/point and model/values overloads only provide a non-mutating
convenience path through `evaluate_numerical`.

For a combined solver-independent report, pass any desired probe dimensions to
`analyze(model; point = point, ...)` (or supply `evaluation = evaluation`).
The requested probe stages are named explicitly in `report.metadata[:stages]`.
No probe is run by default, and requesting one without numerical evidence is
an error rather than an implicit starting-point choice.

`analyze_iterative_right_nullspace_persistence(evaluations; ...)` and
`analyze_iterative_left_nullspace_persistence(evaluations; ...)` compare the
retained candidate subspaces over explicitly chosen points using principal
cosines. They report unavailable, absent, persistent, or changed candidate
geometry, together with the material coordinate support selected by
`support_relative`. Because each subspace comes from an explicit finite probe
budget, these are not rank-persistence, redundancy, or physical-gauge
certificates.
Both also offer `(model, points; cache, relative_step, ...)` convenience
overloads, which evaluate only the supplied points and never select starts.

The right-nullspace report identifies candidate variable directions with a
small Jacobian residual and material coordinate support. The corresponding
left-nullspace report identifies candidate constraint combinations with a small
transposed-Jacobian residual and material constraint support. Neither certifies
rank, nullity, redundancy, an IIS, or a physical gauge. The spectrum report
compares a power-scale proxy with candidate small-direction residuals. Its
reported spectral spreads are heuristic screening quantities—not condition
numbers or singular-value bounds. All reports retain their requested probe
dimension, iteration budget, availability, and convergence evidence so a result
can be reproduced or discounted appropriately.

## Current limits

- Finite differences are probing evidence, not exact derivatives.
- No automatic starting-point selection is performed.
- Complete MOI variable starts can be inspected explicitly with
  `analyze_initialization`.
- Dense SVD remains the authoritative local numerical nullspace path; sparse
  QR and the opt-in iterative candidate probe complement it for larger models.
- Active-set selection and multiplier recovery remain explicit user or
  solver-extension responsibilities. The generic active-set selector handles
  scalar and coordinate-wise product-bound semantics, but not coupled-set
  semantics.
- Physical scaling and expected nullspaces belong in plugins rather than this
  generic layer.
