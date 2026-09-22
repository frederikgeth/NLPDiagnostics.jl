# Capacity certificate with explicit tolerances

The experimental `tolerant_capacity_certificate` extends the exact encoded-equation
certificate to declared **absolute, unscaled bounds on true real residuals**. It
accounts for equality errors, generator bound relaxation, and voltage bound
relaxation together. It does not interpret an optimizer's settings automatically.

```julia
include("benchmarks/power_repair_pilot/tolerant_capacity_certificate.jl")
using .TolerantCapacityCertificate
result = tolerant_capacity_certificate(pm, data;
    contract=:absolute_unscaled,
    equality_tolerance=1e-6,
    generator_bound_tolerance=1e-6,
    voltage_bound_tolerance=1e-6)
```

These are separate tolerances: active-power rows and generator bounds are in the
encoded per-unit power coordinates; voltage bounds are in per-unit magnitude
coordinates. Missing, negative, nonfinite, Boolean, and unsupported tolerance
values produce `unavailable`. Rational inputs support exact threshold tests.

## Derivation

The [exact checker](encoded_capacity_certificate.md) extracts and verifies an
aggregate equality by adding selected bus rows and subtracting branch terminal
rows. Let the resulting coefficient of row `i` be `w_i`. Under the declared
contract, each original row residual satisfies `|r_i| ≤ tau_eq`, so

```
|sum(w_i*r_i)| ≤ B_eq = sum(abs(w_i))*tau_eq.
```

Repeated row references are combined before computing this budget. The experiment
uses a uniform equality tolerance; it does not assume a tolerance on a normalized
or arbitrarily rescaled row.

With `n_gen` selected generators, their aggregate active output is at most

```
P_relaxed = P_upper + n_gen*tau_gen.
```

Original voltage bounds satisfy `0 ≤ l ≤ x ≤ U`. After both bounds are relaxed
by `tau_vm`, `|x| ≤ U+tau_vm`, even when the relaxed lower bound is negative.
The branch loss inequality extends to signed magnitudes because

```
A*x²+B*y² ≥ 2*sqrt(A*B)*abs(x*y)
C*x*y*cos(t)+D*x*y*sin(t) ≥ -sqrt(C²+D²)*abs(x*y).
```

Thus the exact checker's rational lower-bound construction applies with absolute
upper bounds `U+tau_vm`, `V+tau_vm`. Nonnegative shunt coefficients still multiply
nonnegative squares. Let the resulting aggregate branch lower bound be
`L_relaxed`. A contradiction is certified only if the exact rational margin

```
D_encoded - P_relaxed + L_relaxed - B_eq > 0.
```

Zero and negative margins yield `not_ruled_out`; they do not establish feasibility.
Unsupported encoded models retain the exact checker's `unavailable` outcome.
The returned evidence includes original row coefficients and bounds, signed row
weights, all tolerance values, relaxed branch allowances, the residual budget,
and the final exact margin.

## Relationship to solver acceptance

`certified_infeasible_within_tolerances` excludes any real point satisfying the
selected constraints within this declared contract. Other constraints can only
further restrict the set; no relaxation accounting for them is needed for this
sufficient contradiction.

To use the result against a solver's reported acceptance, a caller must establish
that acceptance implies this contract. In particular, scaling, relative tests,
bound relaxation, and numerical residual evaluation must be bounded. If reported
residual magnitude is at most `t` and evaluation error is rigorously at most `e`,
a true-residual tolerance of at least `t+e` is needed in the same unscaled units.
This helper neither estimates `e` nor certifies that a solver option has that
meaning. It does not query solver settings or claim that the example `1e-6`
values describe any particular optimizer configuration.

## Validation and reproduction

```sh
julia --startup-file=no --compiled-modules=no --project=benchmarks/environments/power_repair_pilot test/tolerant_capacity_certificate_contracts.jl
```

Tests use exposed case9/case14 development fixtures. They exercise exact equality
and generator-budget boundaries, their combined budget, strict comparisons on
both sides of the threshold, invalid inputs, and voltage relaxation crossing
zero. The original frozen evaluation hashes remain unchanged. Artifacts are
written to `work/tolerant-capacity-followup/summary.json`. This is outside the
stable API and is not a held-out validation or a study of practical repair benefit.

The current standalone run passes **42 assertions**. An independent rational
arithmetic replay additionally checks 65 recorded branch bounds and six aggregate
decisions. In the exposed case9 zero-capacity example, setting all three declared
tolerances to `1e-6` leaves an approximately 2.69997-p.u. contradiction margin.
Equality-only, generator-only, and combined exact budget boundaries all yield
`not_ruled_out` with a zero margin.
