# Tutorial: numerical rank at a point

!!! note "Learning goals"
    After this tutorial, you can explain why numerical rank belongs to a
    particular point and tolerance policy, inspect a right-null direction, and
    separate a local derivative observation from a feasibility claim.

    **Prerequisites:** basic derivatives and the [rank and gauges](../concepts/rank-and-gauges.md)
    concept page. **Time:** about 15 minutes. **Artifact:** a four-point rank
    comparison with explicit tolerances.

Consider the equality

```math
x^2 = 1.
```

Its Jacobian is the one-entry matrix ``[2x]``. At ``x=0`` that entry vanishes,
while at either solution it does not. Predict the rank at ``x=0`` and ``x=1``
before running the example.

## Build the smallest useful experiment

The complete script is available as
[`examples/numerical_rank_at_a_point.jl`](https://github.com/frederikgeth/NLPDiagnostics.jl/blob/main/examples/numerical_rank_at_a_point.jl).
The tutorial executes the same file so the downloadable example and published
lesson cannot silently diverge.

```@example numerical_rank
using NLPDiagnostics

example_path = joinpath(
    pkgdir(NLPDiagnostics),
    "examples",
    "numerical_rank_at_a_point.jl",
)
include(example_path)
results = run_rank_at_a_point_example()
nothing
```

Each case creates a labelled [`EvaluationPoint`](@ref), evaluates the model at
that point, and passes the resulting numerical evidence to the Advanced
facade's [`jacobian_rank_estimate`](@ref NLPDiagnostics.jacobian_rank_estimate).
The point label and tolerance are therefore part of the result, rather than
hidden notebook state.

## Compare an infeasible stationary point with a solution

```@example numerical_rank
stationary = results.stationary
solution = results.solution

@assert stationary.derivative == 0.0
@assert stationary.estimate.rank == 0
@assert stationary.estimate.right_nullity == 1
@assert solution.derivative == 2.0
@assert solution.estimate.rank == 1

(
    stationary = (
        point = stationary.point.label,
        derivative = stationary.derivative,
        rank = stationary.estimate.rank,
        right_nullity = stationary.estimate.right_nullity,
    ),
    solution = (
        point = solution.point.label,
        derivative = solution.derivative,
        rank = solution.estimate.rank,
        right_nullity = solution.estimate.right_nullity,
    ),
)
```

The zero derivative at ``x=0`` creates a local null direction. It does not show
that the equation has a degree of freedom at a solution: ``x=0`` violates
``x^2=1``. At the feasible point ``x=1``, the same row has rank one.

That distinction matters in OPF. A null vector computed at an arbitrary or
infeasible initialization can suggest a hypothesis, but it cannot by itself
establish a gauge or solution degeneracy.

## Make the tolerance visible

At ``x=10^{-8}``, the Jacobian entry is ``2\times10^{-8}``. Compare two
absolute thresholds while holding the model and point fixed:

```@example numerical_rank
strict = results.near_strict
loose = results.near_loose

@assert strict.derivative == loose.derivative == 2.0e-8
@assert strict.estimate.rank == 1
@assert loose.estimate.rank == 0

(
    derivative = strict.derivative,
    strict = (
        absolute_threshold = strict.estimate.absolute_threshold,
        rank = strict.estimate.rank,
    ),
    loose = (
        absolute_threshold = loose.estimate.absolute_threshold,
        rank = loose.estimate.rank,
    ),
)
```

The two ranks answer different declared numerical questions. Neither should be
reported without its point, scaling policy, and threshold. For research use,
also retain the singular values and perturb the point or scaling to test whether
the conclusion persists.

## What the experiment establishes

For this represented equation, the Jacobian rank changes with the evaluation
point and can change with the absolute threshold near a small derivative. The
experiment does not establish infeasibility, uniqueness, or a physical gauge.
Those claims require additional mathematical or domain evidence.

## Exercise

Evaluate the same model at ``x=-1`` and ``x=10^{-5}``. Before running it,
predict the derivative, rank, and right nullity under absolute thresholds
``10^{-6}`` and ``10^{-4}``.

!!! tip "Hint"
    Keep the relative tolerance fixed. Change only the point or the absolute
    tolerance, and record which one changed in each comparison.

!!! info "Expected observations"
    At ``x=-1``, the derivative is ``-2`` and the Jacobian has rank one. At
    ``x=10^{-5}``, its magnitude is ``2\times10^{-5}``, so the stricter absolute
    threshold retains rank one while the looser threshold reports rank zero.
    Explain why neither observation makes the near-zero point feasible.
