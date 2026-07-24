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
MFCQ screen is deliberately conservative: it may report a found common
equality-tangent descent direction, but a failed screen is *inconclusive*, not
an MFCQ-failure claim. Coupled and plugin-defined sets remain visible as
activity-semantics-unavailable evidence until a plugin provides the correct
interpretation.

`recover_stationarity_multipliers` additionally computes a minimum-norm
least-squares multiplier representative for those explicit active sides,
respecting the MOI objective sense and lower/upper sign convention. It reports
the local stationarity residual and whether the active-gradient system makes
the representative non-unique. This is diagnostic evidence, not a solver dual
solution or an economic interpretation.

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
future domain plugins a stable generic input.

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
stage. These summaries describe local observed variation; they are not
statistical confidence intervals.

## Cache lifetime

`EvaluationCache` stores a complete evaluation under the model object, cache
generation, evaluation point, numeric type, and finite-difference step.
Repeated requests at the same point do not reinitialize or call an evaluator.

MOI does not provide a generic model mutation counter. After changing model
functions, sets, callbacks, or operator registrations, call `empty!(cache)`
before reusing it. This clears entries and advances the cache generation.

## Current limits

- Finite differences are probing evidence, not exact derivatives.
- No automatic starting-point selection is performed.
- Complete MOI variable starts can be inspected explicitly with
  `analyze_initialization`.
- Rank and Hessian diagnostics use dense guarded algorithms; sparse and
  iterative large-model methods remain future work.
- Active-set selection and multiplier recovery remain explicit user or
  solver-extension responsibilities. The generic active-set selector handles
  scalar and coordinate-wise product-bound semantics, but not coupled-set
  semantics.
- Physical scaling and expected nullspaces belong in plugins rather than this
  generic layer.
