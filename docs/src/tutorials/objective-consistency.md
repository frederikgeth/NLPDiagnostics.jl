# Objective consistency and applicable gaps

A solver-reported objective and the objective obtained by evaluating the
returned variables answer related but distinct questions. Comparing them can
detect a stale point, scaling convention, sign change, offset, barrier term, or
reporting-time mismatch. A primal-dual gap requires additional mathematical
structure and must not be inferred merely because two objective-like numbers
are available.

## Compare a solver result with the represented objective

Start with a small continuous affine problem. The explicit tolerances are part
of the experiment record:

```@example objective_consistency
using Ipopt
using JuMP
using NLPDiagnostics.Stable

affine = Model(Ipopt.Optimizer)
set_silent(affine)
@variable(affine, x >= 1)
@objective(affine, Min, x)
optimize!(affine)

affine_result = objective_consistency_summary(
    affine;
    absolute_tolerance = 1.0e-7,
    relative_tolerance = 1.0e-7,
    feasibility_tolerance = 1.0e-7,
    stationarity_tolerance = 1.0e-7,
    dual_tolerance = 1.0e-7,
    gap_absolute_tolerance = 1.0e-7,
    gap_relative_tolerance = 1.0e-7,
)

@assert affine_result.comparison_available
@assert affine_result.consistent
(
    solver = affine_result.solver_objective_value,
    reevaluated = affine_result.reevaluated_objective_value,
    difference = affine_result.absolute_difference,
    threshold = affine_result.consistency_threshold,
)
```

The re-evaluation uses the represented MOI objective at the exact public
`VariablePrimal` point. It does not reuse the solver's objective value. The
summary retains the point fingerprint and `SolverResultPoint` provenance so a
saved comparison cannot silently drift to another result.

## Read an applicable affine gap

This model has a scalar affine objective, scalar affine rows, continuous
variables, and public row duals. NLPDiagnostics checks the prerequisites before
assembling a dual objective:

```@example objective_consistency
@assert affine_result.gap_available
(
    basis = affine_result.gap_basis,
    primal = affine_result.reevaluated_objective_value,
    dual = affine_result.dual_objective_value,
    gap = affine_result.primal_dual_gap,
    gap_threshold = affine_result.gap_threshold,
    passed = affine_result.gap_passed,
    dual_status = affine_result.dual_status,
    primal_violation = affine_result.maximum_primal_violation,
    stationarity_residual = affine_result.maximum_stationarity_residual,
    dual_violation = affine_result.maximum_dual_violation,
)
```

Small negative gaps can occur when a returned point lies just outside a bound
within the selected feasibility tolerance. The pass rule therefore requires
the signed gap to be no smaller than the negative threshold and its magnitude
to remain within that threshold. Record the feasibility, stationarity, dual,
and gap tolerances together; changing one changes the claim.

The affine gap is numerical evidence for the represented model. It does not
establish exact optimality, multiplier uniqueness, or equivalence with an
internally scaled or barrier-augmented solver problem.

## Keep nonlinear gap claims unavailable

Now solve a nonlinear objective:

```@example objective_consistency
nonlinear = Model(Ipopt.Optimizer)
set_silent(nonlinear)
@variable(nonlinear, z, start = 0.0)
@objective(nonlinear, Min, (z - 2)^2)
optimize!(nonlinear)

nonlinear_result = objective_consistency_summary(
    nonlinear;
    absolute_tolerance = 1.0e-7,
    relative_tolerance = 1.0e-7,
)

@assert nonlinear_result.comparison_available
@assert nonlinear_result.consistent
@assert !nonlinear_result.gap_available
(
    comparison = nonlinear_result.consistent,
    gap_available = nonlinear_result.gap_available,
    reason = nonlinear_result.gap_reason,
)
```

The objective comparison remains useful: it checks whether the public solver
value matches the returned point. The generic library does not manufacture a
global dual bound for this nonlinear program, so the gap has a typed
unavailable reason. Local stationarity or Hessian evidence answers a different
question.

## Construct a controlled mismatch

For a test fixture, keep the endpoint fixed and perturb only the reported
objective:

```@example objective_consistency
nonlinear_evaluation = evaluate_numerical(
    nonlinear,
    nonlinear_result.point,
)
controlled_mismatch = objective_consistency_summary(
    nonlinear,
    nonlinear_evaluation;
    solver_objective_value =
        nonlinear_result.solver_objective_value + 0.01,
    solver_objective_source = :controlled_teaching_fixture,
    absolute_tolerance = 1.0e-7,
    relative_tolerance = 1.0e-7,
)

@assert !controlled_mismatch.consistent
report = objective_consistency_report(controlled_mismatch)
[
    string(finding.code) for finding in report
]
```

This intervention does not claim that Ipopt returned the altered value. It
demonstrates how the report separates an objective mismatch from the expected
nonlinear-gap abstention.

Serialize the typed result at the artifact boundary:

```@example objective_consistency
record = objective_consistency_summary_data(affine_result)
@assert record["schema_version"] ==
        "nlpdiagnostics-objective-consistency-summary-v1"
@assert record["comparison_unavailable_reason"] === nothing
@assert record["gap_unavailable_reason"] === nothing
sort!(collect(keys(record)))
```

The runnable version is `examples/objective_consistency.jl`. The objective
re-evaluation idea follows the model-debugging initiative and [HiGHS.jl issue
#223](https://github.com/jump-dev/HiGHS.jl/issues/223); NLPDiagnostics adds the
exact-point provenance and explicit gap-applicability boundary.
