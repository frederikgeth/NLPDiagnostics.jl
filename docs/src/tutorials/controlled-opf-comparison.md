# Tutorial: compare OPF formulations in physical coordinates

!!! note "Learning goals"
    After this tutorial, you can design a controlled formulation comparison,
    map solver results into common physical coordinates, and state the narrow
    claim supported when the mapped results agree.

    **Prerequisites:** elementary AC power-flow notation and the
    [research workflow](../research-workflow.md). **Time:** about 20 minutes.
    **Artifact:** paired polar and rectangular result records for a two-bus
    teaching fixture.

Changing an OPF formulation often changes the optimization variables. Comparing
the two raw vectors then answers little: ``(v_m,v_a)`` and ``(v_r,v_i)`` are
different coordinate systems. This tutorial compares the results only after
mapping both into the rectangular voltage ``v_r + i v_i``.

## Freeze the question and prediction

The fixture has a slack voltage ``1+0i``, line susceptance ``b=10``, and a
declared load ``(p_d,q_d)=(1,0.2)``. The non-slack voltage obeys

```math
10 v_i = -p_d,
\qquad
10(v_r^2-v_r+v_i^2) = -q_d.
```

Both formulations use the same physical balance, voltage region, initial
voltage, objective, and Ipopt family. The objective is the squared physical
distance from the slack voltage. Predict that locally solved points will agree
after the polar result is mapped through ``v_r=v_m\cos(v_a)`` and
``v_i=v_m\sin(v_a)``.

This is a deliberately small teaching fixture. It has no equipment, contingency,
or operator semantics and is not a validated network study.

## Run the paired experiment

The standalone script and its experiment record are available at
[`examples/controlled_opf_formulations.jl`](https://github.com/frederikgeth/NLPDiagnostics.jl/blob/main/examples/controlled_opf_formulations.jl)
and
[`examples/controlled_opf_formulations.toml`](https://github.com/frederikgeth/NLPDiagnostics.jl/blob/main/examples/controlled_opf_formulations.toml).

```@example controlled_opf
using NLPDiagnostics
import MathOptInterface as MOI

example_path = joinpath(
    pkgdir(NLPDiagnostics),
    "examples",
    "controlled_opf_formulations.jl",
)
include(example_path)
comparison = run_controlled_opf_comparison()

@assert comparison.polar.termination in (MOI.LOCALLY_SOLVED, MOI.OPTIMAL)
@assert comparison.rectangular.termination in (MOI.LOCALLY_SOLVED, MOI.OPTIMAL)
@assert comparison.polar.primal == MOI.FEASIBLE_POINT
@assert comparison.rectangular.primal == MOI.FEASIBLE_POINT
nothing
```

Termination and primal statuses make the solver observations explicit. They do
not yet show that the two implementations represent the same physical result.

## Compare balances and mapped states

```@example controlled_opf
@assert abs(comparison.polar_residual.active) < 1.0e-8
@assert abs(comparison.polar_residual.reactive) < 1.0e-8
@assert abs(comparison.rectangular_residual.active) < 1.0e-8
@assert abs(comparison.rectangular_residual.reactive) < 1.0e-8
@assert comparison.maximum_state_difference < 1.0e-8
@assert comparison.objective_difference < 1.0e-8

(
    polar_mapped = comparison.polar_state,
    rectangular = comparison.rectangular_state,
    maximum_state_difference = comparison.maximum_state_difference,
    objective_difference = comparison.objective_difference,
)
```

The comparison uses physical voltage components and recomputes both balances in
that shared representation. It does not compare ``v_m`` directly with ``v_r``
or ``v_a`` with ``v_i``.

## Inspect both diagnostic records

```@example controlled_opf
@assert comparison.polar.error_count == 0
@assert comparison.rectangular.error_count == 0
@assert comparison.polar.result.point !== nothing
@assert comparison.rectangular.result.point !== nothing

(
    polar = (
        point = comparison.polar.result.point.label,
        diagnostic_errors = comparison.polar.error_count,
    ),
    rectangular = (
        point = comparison.rectangular.result.point.label,
        diagnostic_errors = comparison.rectangular.error_count,
    ),
)
```

Each solver result is reevaluated in its own represented model. Finding sets may
differ because formulation structure differs; equivalent physical solutions do
not require identical internal diagnostics.

## What the experiment establishes

Under the declared data, bounds, objectives, starts, solver family, and
comparison threshold, these two locally solved results map to the same physical
voltage and satisfy the same balance equations. The experiment does not
establish global optimality, equivalence for arbitrary OPF models, robustness to
initialization, or operational validity.

The checked-in TOML record names the held-constant quantities and unsupported
claims. Fill its environment and hash fields when adapting this example into a
research experiment.

## Exercise

Choose a second start for each formulation by first selecting one physical
voltage, then converting it into both coordinate systems. Repeat the comparison
without changing the model, solver options, or comparison threshold.

!!! tip "Hint"
    For a chosen ``v_r+i v_i``, use ``v_m=\sqrt{v_r^2+v_i^2}`` and
    ``v_a=\operatorname{atan}(v_i,v_r)``. Record the physical start before
    changing either model.

!!! info "Expected observations"
    If both runs converge to the same branch, mapped states, balance residuals,
    and objectives should agree within the declared threshold. A different
    termination or branch is evidence about this solver experiment; it does not
    by itself prove that one formulation is mathematically wrong.
