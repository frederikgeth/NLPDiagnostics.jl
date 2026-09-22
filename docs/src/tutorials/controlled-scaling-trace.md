# Tutorial: controlled scaling and solver traces

!!! note "Learning goals"
    After this tutorial, you can design a one-change scaling experiment,
    measure point-local Jacobian row scales, retain an Ipopt callback trace,
    and separate native solver telemetry from independently evaluated physical
    residuals.

    **Prerequisites:** JuMP, basic NLP constraints, and the [research
    workflow](../research-workflow.md). **Time:** about 20 minutes. **Artifact:**
    paired diagnostic and solver-trace records for two equivalent NLPs.

Scaling experiments are persuasive only when the changed factor is explicit.
This tutorial compares

```math
10^8(xy-1)=0, \qquad x-y=0
```

with

```math
xy-1=0, \qquad x-y=0.
```

Multiplying an equality by a nonzero constant preserves its feasible set. The
objective, variables, starting point, Ipopt version, and solver options remain
fixed. The experiment changes one row multiplier.

## Freeze the question and prediction

Both models minimize

```math
(x-1)^2 + (y-1)^2
```

from ``(x,y)=(2,0.5)``. At that point ``xy-1=0`` and ``x-y=1.5``. Predict that:

1. the multiplier will change the local Jacobian row-scale spread;
2. both runs will reach the same physical solution within a declared tolerance;
3. the retained iteration traces may differ; and
4. one pair of traces will support a local observation rather than a general
   claim about Ipopt or scaling.

The complete script and experiment record are available at
[`examples/controlled_scaling_solver_trace.jl`](https://github.com/frederikgeth/NLPDiagnostics.jl/blob/main/examples/controlled_scaling_solver_trace.jl)
and
[`examples/controlled_scaling_solver_trace.toml`](https://github.com/frederikgeth/NLPDiagnostics.jl/blob/main/examples/controlled_scaling_solver_trace.toml).

The script sets Ipopt's `nlp_scaling_method` to `none` for both runs. This makes
the model-level intervention visible instead of combining it with a changing
solver scaling policy. That setting belongs to this experiment record; it is
not a general recommendation.

## Run the paired experiment

```@example controlled_scaling
using NLPDiagnostics

example_path = joinpath(
    pkgdir(NLPDiagnostics),
    "examples",
    "controlled_scaling_solver_trace.jl",
)
include(example_path)
comparison = run_controlled_scaling_solver_trace()
nothing
```

The helper evaluates both models at the shared start before solving. Inspect
the row infinity norms and their positive finite spread:

```@example controlled_scaling
(
    ill_scaled = (
        row_norms = comparison.ill_scaled.scale_summary.row_norms,
        row_scale_ratio = comparison.ill_scaled.scale_summary.row_scale_ratio,
    ),
    normalized = (
        row_norms = comparison.normalized.scale_summary.row_norms,
        row_scale_ratio = comparison.normalized.scale_summary.row_scale_ratio,
    ),
)
```

The exact row order follows the public MOI representation. The comparison uses
the maximum and minimum positive row norms, so its conclusion does not depend
on display order. The large-spread finding appears only in the multiplied
model under the tutorial's declared ``10^6`` screening threshold:

```@example controlled_scaling
ill_codes = Set(finding.code for finding in comparison.ill_scaled.numerical_report)
normalized_codes = Set(finding.code for finding in comparison.normalized.numerical_report)

@assert :large_jacobian_row_scale_spread in ill_codes
@assert :large_jacobian_row_scale_spread ∉ normalized_codes
(ill_scaled = ill_codes, normalized = normalized_codes)
```

This is point-local derivative evidence. It does not establish a global
condition number or predict a solver outcome by itself.

## Read the solver trace with its coordinate semantics

`ipopt_profile_with_iteration_trace!` installs Ipopt's public intermediate
callback, solves the model, and retains the callback records together with a
profile of the final public solver result. Each captured primal point carries
`SolverIteratePoint` provenance. The serialized record also labels the
coordinate convention of every principal metric:

```@example controlled_scaling
first_record = first(comparison.ill_scaled.trace_data["records"])
(
    schema = comparison.ill_scaled.trace_data["schema_version"],
    captured_records = comparison.ill_scaled.trace_data["record_count"],
    captured_points = comparison.ill_scaled.trace_data["binding_count"],
    metric_semantics = first_record["metric_semantics"],
)
```

The objective is labelled in original model coordinates. Ipopt's primal and
dual infeasibility columns are labelled in solver-scaled coordinates, and its
barrier parameter is solver-defined. Preserve those labels when exporting a
trace. A native infeasibility column should not be subtracted from a physical
OPF residual unless an explicit coordinate and tolerance translation has been
established.

Now compare descriptive trace facts:

```@example controlled_scaling
trace_comparison = (
    ill_scaled = (
        records = comparison.ill_scaled.trace_summary.record_count,
        final_iteration = comparison.ill_scaled.trace_summary.final_iteration,
        line_search_trials = comparison.ill_scaled.total_line_search_trials,
    ),
    normalized = (
        records = comparison.normalized.trace_summary.record_count,
        final_iteration = comparison.normalized.trace_summary.final_iteration,
        line_search_trials = comparison.normalized.total_line_search_trials,
    ),
)
@assert trace_comparison.ill_scaled.records > 0
@assert trace_comparison.normalized.records > 0
trace_comparison
```

These values describe the runs produced by the pinned documentation
environment. They can change with the solver, linear algebra library, options,
platform, or start. Record counts and line-search trials are useful response
variables for a controlled campaign; they are not a solver-quality score.

## Compare the endpoint in shared physical coordinates

The equality multiplier disappears when the endpoints are mapped back to the
unscaled equations:

```@example controlled_scaling
@assert comparison.maximum_endpoint_difference < 1.0e-7
@assert maximum(abs, values(comparison.ill_scaled.endpoint_physical_residuals)) < 1.0e-7
@assert maximum(abs, values(comparison.normalized.endpoint_physical_residuals)) < 1.0e-7

(
    ill_scaled_endpoint = comparison.ill_scaled.endpoint,
    normalized_endpoint = comparison.normalized.endpoint,
    maximum_endpoint_difference = comparison.maximum_endpoint_difference,
    objective_difference = comparison.objective_difference,
)
```

The supported conclusion is narrow: the intervention reduced the measured
start-point row-scale spread, the recorded Ipopt trajectories differed, and
both runs reached matching physical endpoints within the declared tolerance.
The experiment does not establish that normalization always reduces work or
that the multiplied formulation is mathematically wrong.

## Exercise

Repeat the experiment for multipliers ``10^2``, ``10^4``, ``10^6``, and
``10^8``. Keep the start and solver policy fixed. Store, for each multiplier,
the row-scale ratio, termination status, trace record count, total line-search
trials, endpoint residuals, environment fingerprint, and package versions.
Decide before running which observations would count against the prediction.

!!! tip "Hint"
    Treat the multiplier as the independent variable. Plot trace observations
    only after checking endpoint agreement and metric semantics. A monotone
    trend across this small sweep remains evidence for this fixture and
    environment.
