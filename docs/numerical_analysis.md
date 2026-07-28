# Numerical evaluation, rank, and curvature

The numerical layer records local evidence at an explicit
`EvaluationPoint`. It does not infer global properties from one evaluation and
does not modify the source model.

## Evaluation points

An evaluation point contains:

- the exact `MOI.VariableIndex` order;
- values converted to a common floating-point type; and
- a user-visible label such as `"initialization"` or `"failed iterate 17"`.

The order must equal `MOI.ListOfVariableIndices`. This matters because an
`AbstractNLPEvaluator` defines its callback coordinates in precisely that
order.

```julia
point = evaluation_point(model, [1.0, 2.0]; label = "initialization")
evaluation = evaluate_numerical(model, point)
summary = jacobian_scale_summary(evaluation)
report = analyze(model; point = point)
```

A dictionary keyed by `MOI.VariableIndex` may be used instead of an ordered
vector. Missing variables are rejected.

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

`analyze_numerical` compares both unscaled and row/column-normalized estimates.
It reports a numerical rank deficiency only when rank is below
`min(rows, columns)`; an expected rectangular right nullspace alone is not a
deficiency. When rank changes after normalization, the report calls this
scale-sensitive evidence rather than a mathematical degeneracy.

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

`recover_stationarity_multipliers` additionally computes a minimum-norm
least-squares multiplier representative for those explicit active sides,
respecting the MOI objective sense and lower/upper sign convention. It reports
the local stationarity residual and whether the active-gradient system makes
the representative non-unique. This is diagnostic evidence, not a solver dual
solution or an economic interpretation. It also reports the recovered
inequality-sign violation and bound-margin complementarity residual; these are
local consistency screens for this representative, not KKT certificates.

`active_set_matching` is a separate, explicitly point-local structural view.
It matches free variables to only the aligned equality and selected near-active
scalar inequality rows. Its activity selection is numerical evidence, whereas
the matching conclusion is structural for that selected pattern. Callback and
coupled-set rows that cannot be aligned remain visible as unmapped rows rather
than being silently omitted.

Second-order and rotated-second-order cones additionally receive generic
vector-set feasibility and boundary reports through
`coupled_set_feasibility_summary`. A cone boundary remains coupled geometry:
the generic core does not turn it into scalar active rows for LICQ, MFCQ, or
multiplier recovery. Other coupled sets remain plugin extension points through
`coupled_set_activity(set, source, values, feasibility_tolerance,
active_tolerance)`, which may return a `CoupledSetActivity` or `nothing`.
For SOC apex and rotated-SOC axis boundaries, the report additionally labels
the boundary as nonsmooth. This is a geometric fact that strengthens the case
against scalar active-row reductions; it does not supply a cone multiplier or
a full conic constraint qualification screen.
At smooth SOC and rotated-SOC boundaries, `coupled_set_tangent_evidence`
provides an output-coordinate boundary normal. Plugins may extend the same
hook for other coupled sets. These normals remain coupled-set evidence and are
never silently inserted into scalar LICQ, MFCQ, or multiplier calculations.
For aligned vector outputs, the generic active-set report also maps a smooth
boundary normal through the vector-function Jacobian and records its
model-coordinate gradient. A zero mapped gradient is reported as local
stationarity evidence, not treated as a regular scalar cone tangent.

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
`profile_case(model, case)` runs the generic numerical, active-set, and
degeneracy stages without invoking a solver. Its `ProfileResult` retains the
reports, cache hits/misses, derivative-row-method and capability-source counts,
wall-clock time by stage, and per-evaluation callback statistics. Exact NLP
evaluator initialization/value/gradient/Jacobian calls and oracle
value/Jacobian calls are counted separately; ordinary MOI work is recorded as
one symbolic-stage measurement.

Stage timings include Julia compilation and allocation effects unless callers
warm up a comparable case first. They are useful profiling evidence, not a
portable solver-performance benchmark.

`profile_case_repeated(model, case; repetitions = 3, warmup = true)` performs
independent runs with fresh caches, discards the optional warm-up measurement,
and returns minimum, mean, maximum, and population standard deviation for each
stage. It also returns per-stage diagnostic-code occurrence fractions, making
stable versus intermittent findings explicit across retained runs. Its
`numerical_summary` separately aggregates available finite Jacobian rank,
sparse-QR rank, and sparse-QR pivot-proxy observations. Each metric records
both retained-run count and available-value count, so unavailable diagnostics
are never silently averaged as zeros. These summaries describe local observed
variation; they are not statistical confidence intervals.

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

### MadNLP extension

When `MadNLP` is loaded, the same `solver_postmortem` entry point recognizes
its MOI optimizer. The extension records public MOI statuses, barrier
iterations, objective value, solve time, and MadNLP's raw status string. It
does not inspect MadNLP internals to infer residuals or restoration history;
only the raw `Restoration Failed` status records unsuccessful restoration.

## Raw solver-log evidence

`solver_log_observations(log)` retains the original line number and text for a
small set of explicit generic markers: restoration failure, invalid-number
text, infeasibility text, termination limits, and selected numerical-failure
phrases. `analyze_solver_log(solver, log)` groups these lines into findings.
It does not parse iteration tables, reconstruct residuals, or treat log text as
a proof of infeasibility or optimality. Future solver extensions can add
structured log parsers while preserving these raw, inspectable evidence lines.

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
`analyze_solver_iterations(solver, log)` reports a final recorded residual and
an optional residual-regression heuristic. These are log-column observations,
not independently recomputed KKT residuals or convergence certificates.

## Bound iteration points

`bind_iteration_points(records, points)` connects a parsed row to a caller-
supplied `EvaluationPoint`; it never reconstructs an iterate from log text.
`analyze_iteration_points(model, bindings)` runs numerical diagnostics at each
bound point and compares the log's primal-infeasibility column against three
recomputed quantities: scalar-bound violation, coupled-set violation, and
their maximum. A large mismatch is representational evidence, since solvers
may use different scaling or feasibility semantics; it is not a solver-error
claim. When an objective is available, it also compares the logged objective
with the model objective at the supplied point. Potential barrier, penalty,
scaling, and point-alignment differences remain evidence rather than an
assumption that the log column is the unmodified model objective.

Across two or more bound points, `analyze_iteration_points` additionally emits
a heuristic trace-disagreement finding only when logged primal infeasibility
falls by more than the configured factor while recomputed feasibility rises by
more than that factor. This can reveal misaligned point capture, scaling, or
semantics, but does not attribute the cause.

For non-feasibility objective senses, it also reports a trace disagreement when
the logged objective improves in the declared optimization direction while the
recomputed model objective moves meaningfully in the opposite direction. This
is a point-alignment and objective-semantics heuristic, not a statement about
solver correctness or objective quality.

## Sparse QR rank estimate

`sparse_qr_rank_estimate(evaluation)` uses sparse QR diagonal pivots to give a
local rank estimate without forming the dense Jacobian required by the guarded
SVD path. Its threshold and pivots are retained explicitly. It is a numerical
estimate, not a nullspace calculation or a proof of exact rank; the sparse
pattern matching estimate remains the separate structural upper bound.
When the dense SVD is unavailable, a deficient sparse-QR estimate is reported
as `sparse_qr_jacobian_rank_deficiency` with medium confidence; it is never
presented as an exact rank proof.
The numerical report also compares unscaled and row-column-scaled sparse-QR
ranks. A disagreement produces `sparse_qr_rank_scaling_sensitivity`, which is
evidence that pivot-threshold semantics depend on scaling, not a diagnosis of
structural degeneracy.
When dense SVD is unavailable, an extreme retained-pivot ratio can also emit
`sparse_qr_pivot_scale_spread`. This is intentionally a heuristic pivot-scale
warning, not a numerical condition estimate.

## Iterative sparse null-direction probe

`iterative_right_nullspace_estimate(evaluation)` is an explicit, opt-in
sparse-matvec probe for one candidate right direction with a small Jacobian
residual. It uses normalized shifted `J'J` products and records both the
returned residual and whether its direction iteration stabilized. It does not
claim a nullspace, its dimension, or exact rank: use the guarded dense SVD when
such a local numerical statement is required. The deterministic seed makes the
candidate reproducible, while its residual keeps the evidence inspectable.
`iterative_right_nullspace_subspace_estimate(evaluation, dimension)` provides
the analogous block probe when several candidate directions are useful; it
returns orthonormal columns and a residual for each column. Neither API is
used implicitly by `analyze_numerical`, because a requested candidate subspace
must not be confused with an inferred nullity.

`iterative_jacobian_spectrum_estimate` combines a normal-operator power scale
with the block probe's small-direction residuals. Its reported spectral spreads
are screening proxies only—not condition estimates or singular-value bounds—so
they remain opt-in and are never emitted as automatic conditioning findings.

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
`analyze_active_set(...; expected_modes = ...)` also checks each declared
`ExpectedNullspaceMode` directly against the selected active Jacobian. An
observed result is consistency with a plugin declaration at one point, while a
non-observed result can mean that active constraints removed the mode; neither
result validates or disproves the underlying physical interpretation.
When declared modes are individually tangent, their independent span is also
compared with the active right nullity. A larger observed nullity produces
`active_undeclared_tangent_directions`; dependent declarations are separately
reported as `active_expected_nullspace_mode_declarations_dependent`.
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
