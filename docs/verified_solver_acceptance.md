# Verified acceptance in the pinned solver workflow

The experimental `solve_and_verify` workflow makes **its own primal acceptance**
imply the absolute tolerance contract used by the capacity certificate. It does
this by independently enclosing the returned point's true constraint values.
It does not reinterpret every Ipopt success status as a verified certificate.

## Why a separate acceptance check is necessary

The frozen pilot sets Ipopt `tol=1e-9`, iteration/time limits, and log options. Its
separate JuMP feasibility report uses `atol=1e-6`. These are numerical evaluations;
the pilot did not bound their error or explicitly configure all scaling and bound
relaxation choices. The original frozen runner remains unchanged.

In the installed, pinned Ipopt.jl 1.15.0 source,
`ext/IpoptMathOptInterfaceExt/MOI_wrapper.jl` maps `Solve_Succeeded` to
`LOCALLY_SOLVED`/`FEASIBLE_POINT`, and acceptable-level termination to
`ALMOST_LOCALLY_SOLVED`/`NEARLY_FEASIBLE_POINT`. A separate manually evaluated
primal-status path applies to otherwise unknown result statuses. These status
mappings do not constitute a rigorous residual enclosure. The source was inspected
locally alongside the committed pinned manifest; no universal guarantee about
solver stopping options is inferred from the mapping.

## Defined workflow

```julia
include("benchmarks/power_repair_pilot/verified_solver_acceptance.jl")
using .VerifiedSolverAcceptance
result = solve_and_verify(pm, data; absolute_tolerance=1e-6)
```

The new workflow builds the capacity certificate, solves with the following
explicit settings, then checks the original backend constraints at the returned
point:

| Setting | Value |
| --- | --- |
| `tol`, `constr_viol_tol` | `1e-9` |
| `nlp_scaling_method` | `none` |
| `bound_relax_factor` | `0.0` |
| `acceptable_iter` | `0` |
| `honor_original_bounds` | `yes` |
| `max_iter`, `max_cpu_time` | `500`, `60.0` |

The independent check is authoritative for primal acceptance. The settings alone
are never treated as the proof. Backend signatures are compared across the solve.
`accepted_primal_point` requires both `LOCALLY_SOLVED` and verification that every
original supported scalar constraint lies within the declared absolute tolerance.
A verified point with another solver termination is labeled separately. Missing
values, definite violations, interval uncertainty, and unavailable verification
cannot become accepted results. No result asserts optimality.

## Rigorous returned-point evaluation

`verify_primal_point(pm, data, point; absolute_tolerance=...)` can also be used
without solving. The point maps every backend `MOI.VariableIndex` to a supported
finite real value. Missing/extra variables and nonfinite values are unavailable.
The source-to-backend matcher must succeed before verification.

The checker expands the supported encoded expressions using exact rational
coefficients and converts returned floats to their exact rational values. All
scalar equalities, inequalities, intervals, and explicit variable bounds are
checked in their original unscaled coordinates. This includes reactive, thermal,
angle, reference, and other supported rows, beyond those used in the capacity
contradiction. Objective values are outside primal-feasibility scope.

For `sin` and `cos` of an exact angle difference `x`, a degree-127 rational Taylor
polynomial has remainder bounded by `abs(x)^128 / 128!`, since every relevant real
derivative has magnitude at most one. Intersecting this enclosure with `[-1,1]`
is valid. Interval addition and multiplication propagate the bounds through the
expanded polynomial. No floating-point transcendental result is used as proof.
Angles outside `[-16,16]` radians are explicitly unavailable, avoiding uncontrolled
cost and loose bounds; there is no uncertified argument reduction.

An enclosure entirely inside a tolerance-expanded constraint set is `satisfied`.
One disjoint from that set is `violated`. Partial overlap is `inconclusive`.
Thus acceptance implies the true mathematical residual and bound contract,
without adding a guessed evaluation-error allowance. A positive capacity
contradiction and a verified compliant point for the same backend and tolerance
are treated as inconsistent evidence, never accepted.

## Scope and reproduction

This verifies the returned point, not every point Ipopt might accept internally.
It certifies tolerance compliance, not exact feasibility, optimality, physical
input intent, operational security, or engineer repair benefit. It is an
experimental follow-up outside the stable API. The original frozen evaluations
and their failures remain unchanged.

Run from the repository root in the pinned environment:

```sh
julia --startup-file=no --compiled-modules=no --project=benchmarks/environments/power_repair_pilot test/verified_solver_acceptance_contracts.jl
```

Artifacts are written to `work/verified-solver-acceptance/summary.json`, including
solver settings/status, returned point, exact row enclosures, capacity evidence,
and source hashes. Tests use exposed case9 development data; they are not fresh
validation. The rational Taylor evaluator is also tested against independent
rational sine/cosine bounds and exact tolerance boundary examples.

In the exposed case9 follow-up, the clean solve returns `LOCALLY_SOLVED` and all
184 constraint enclosures satisfy the declared tolerance. The zero-capacity solve
returns `LOCALLY_INFEASIBLE`; its point has 27 definite violations among the same
184 rows. A separate rational-arithmetic replay validates all 368 recorded
interval/set classifications. That replay does not reconstruct the enclosures
and is not an independent proof-kernel certification.
