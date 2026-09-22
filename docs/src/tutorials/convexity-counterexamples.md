# Tutorial: find a convexity counterexample

!!! note "Learning goals"
    After this tutorial, you can replay a numerical Jensen-inequality
    counterexample, distinguish it from a local Hessian observation, and
    explain why a campaign with no witness is inconclusive. **Prerequisites:**
    basic convexity and [evidence and claims](../concepts/evidence.md).
    **Time:** about 15 minutes. **Artifact:** a seeded, serialized point-pair
    campaign.

For a convex scalar function on a convex domain, every two points ``a,b`` and
weight ``0<\lambda<1`` must satisfy

```math
f(\lambda a+(1-\lambda)b)
\leq \lambda f(a)+(1-\lambda)f(b).
```

One violation is a counterexample to that claim. A finite search that finds
none is not a proof. For concavity, reverse the inequality.

## Search a declared box

Use ``f(x)=x^4-x^2`` on ``[-1,1]``. Its second derivative,
``12x^2-2``, is negative near zero and positive near either end. A Hessian
at one point therefore describes only local curvature. The complete script is
[`examples/convexity_counterexamples.jl`](https://github.com/frederikgeth/NLPDiagnostics.jl/blob/main/examples/convexity_counterexamples.jl).

```@example convexity_campaign
using NLPDiagnostics
using NLPDiagnostics.Advanced

include(joinpath(
    pkgdir(NLPDiagnostics), "examples", "convexity_counterexamples.jl",
))
results = run_convexity_counterexample_example()
campaign = results.witness
trial = campaign.trials[campaign.witness_index]

@assert campaign.conclusion == :counterexample_found
(
    source = campaign.source.kind,
    seed = campaign.seed,
    points = (trial.left, trial.right, trial.mixed),
    values = (trial.left_value, trial.right_value, trial.mixed_value),
    chord = trial.chord_value,
    violation = trial.violation,
    threshold = trial.threshold,
)
```

The campaign draws 64 point pairs from the stated coordinate box using the
recorded seed and tests their midpoint. It retains every sampled coordinate
and value. `violation > threshold` is required before a trial becomes a
counterexample. The threshold combines the declared absolute and relative
policies; change either only as a recorded intervention.

The box is checked against statically certified coordinate bounds, and the
selected expression's operator domains must be certified throughout it. This
is a statement about the scalar **function on that box**, not about feasibility
or convexity of the model's constraint set.

## Compare a control and an abstention

The same seeded campaign on ``y^2`` observes no convexity violation. That is
the expected control result, but it does not certify convexity. A logarithm
on a box crossing zero cannot be admitted as a real-domain campaign:

```@example convexity_campaign
@assert results.control.conclusion == :not_observed
@assert results.invalid_box.conclusion == :unavailable
(
    control = results.control.conclusion,
    control_pairs = length(results.control.trials),
    invalid = results.invalid_box.conclusion,
    invalid_reason = results.invalid_box.reason,
)
```

The campaign also records incomplete function evaluations. If some pairs
cannot be evaluated and no witness is found, its conclusion is
`:inconclusive`. A valid witness remains reportable even when another sampled
pair failed.

## Save evidence for replay

```@example convexity_campaign
payload = convexity_counterexample_campaign_data(campaign)
report = convexity_counterexample_campaign_report(campaign)

@assert only(report.findings).code == :convexity_counterexample_observed
@assert payload["trials"][campaign.witness_index]["violation"] ==
    trial.violation
(
    finding = only(report.findings).code,
    model_fingerprint = payload["model_fingerprint"],
    requested_pairs = payload["requested_pairs"],
    completed_pairs = payload["completed_pairs"],
)
```

The payload stores the model fingerprint, box, seed, tolerance, source row or
objective, all sampled values, and the witness index. Replay those explicit
points with an independent evaluation before making a strong scientific claim.
For a selected scalar constraint row, the test concerns its function; choose
`:convex` or `:concave` to match the property being investigated. The result
does not automatically classify the feasible set.

This experiment follows the model-debugging direction in the
[JuMP initiative](https://github.com/jump-dev/JuMP.jl/issues/3664) and the
counterexample style linked there from
[CVXPY Analyzer](https://github.com/cvxpy/cvxpyanalyzer/blob/master/analyzer/convexity_checker.py).
The [prior-art page](../reference/prior-art.md) explains the relationship.

## Exercise

Run the campaign on ``\log(x)`` over ``[1,2]`` under both `:convex` and
`:concave` claims. Then change the box to ``[-1,2]``. Predict which runs find
a witness, find none, or abstain before running them.

!!! info "Expected observations"
    The positive box can produce a counterexample to convexity because
    logarithm is strictly concave; the concavity campaign observes no
    violation. The box crossing zero is unavailable because the real domain
    is not certified throughout the box. Neither finite no-witness result is
    a global proof.
