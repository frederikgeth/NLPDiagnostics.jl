# Variable bounds or named rows?

A variable bound and a one-variable constraint can describe the same feasible
values. They do not necessarily play the same role in an experiment. This
tutorial shows how to recognize the equivalence and decide whether the row's
identity and dual interpretation are useful.

## Build two equivalent scalar feasible sets

The first model represents a capacity directly as a bound:

```@example bound_rows
using JuMP
using NLPDiagnostics.Stable

bound_model = Model()
@variable(bound_model, production <= 4)

bound_report = analyze(bound_model)
isempty(findings(bound_report; code = :bound_expressed_as_constraint))
```

The second model writes the same limit as a named affine row. Isolating
`production` in `2production + 1 <= 9` gives `production <= 4` exactly.

```@example bound_rows
row_model = Model()
@variable(row_model, production)
@constraint(row_model, transformer_capacity, 2production + 1 <= 9)

row_report = analyze(row_model)
finding = only(findings(row_report; code = :bound_expressed_as_constraint))
(
    code = finding.code,
    basis = finding.basis,
    domain = finding.domain,
    observation = finding.observation,
)
```

The diagnostic uses `MathematicalProof` because affine isolation establishes
the scalar feasible-set equivalence. It uses `RepresentationalIssue` and
`SeverityInfo` because neither representation is inherently an error.

Inspect the evidence rather than parsing the observation text:

```@example bound_rows
details = Dict(finding.evidence[1].details)
@assert details["coefficient"] == "2//1"
@assert details["constant"] == "0.0"
@assert details["original_set"] == "MathOptInterface.LessThan{Float64}(8.0)"
@assert details["equivalent_bound"] == "LessThan(4.0)"
details
```

JuMP has normalized the written constant into the set, so the represented row
is `2production <= 8`. The evidence records that MOI form and the resulting
bound instead of reconstructing source syntax that is no longer present.

Repeated affine terms are combined before the test. The lint abstains for
multi-variable rows, unsupported or non-finite data, and nonlinear functions.
It never rewrites the source model.

`bound_expressed_as_constraint` is a per-row representation finding. The
existing `affine_implied_variable_bound` finding aggregates supported
one-variable rows with declared bounds to describe the resulting interval.
Filter by code according to whether the research question concerns row design
or the combined variable domain.

## Decide from the meaning of the row

The two representations agree on feasible values of `production`, but they
serve different research purposes:

| Representation | Often useful when | Consequence to record |
|:--|:--|:--|
| Variable bound | The limit is part of the variable's domain. | Solvers and presolve may treat it as bound data, and bound duals are retrieved as bound constraints. |
| Named affine row | The limit represents a device, policy, or experimental quantity. | The row keeps its name and a separately attributable multiplier. |

Multiplier values also depend on normalization. For the active row
`2production + 1 <= 9`, replacing the row by `production <= 4` preserves the
feasible set but rescales the multiplier associated with the normalized
constraint. Compare duals only after recording the exact transformation and
the solver's sign convention.

In an OPF model, a one-variable row named `transformer_capacity` may carry
meaning that a generic upper-bound label loses. Conversely, an anonymous row
created only to impose a variable domain may be clearer as a bound. The finding
asks for that decision; it does not make it automatically.

## Check direction changes

A negative coefficient reverses the bound direction:

```@example bound_rows
negative_model = Model()
@variable(negative_model, reserve)
@constraint(negative_model, minimum_reserve, -2reserve + 1 <= 5)

negative_finding = only(findings(
    analyze(negative_model);
    code = :bound_expressed_as_constraint,
))
negative_details = Dict(negative_finding.evidence[1].details)
@assert negative_details["equivalent_bound"] == "GreaterThan(-2.0)"
negative_details["equivalent_bound"]
```

Before running the code, derive the translated direction and endpoint by hand.
This is a useful check on signs and units in generated OPF constraints.

The runnable version is `examples/bounds_as_constraints.jl`. Continue with
[Inspect a model before solving](model-summary-and-units.md) to compare global
coefficient ranges, then use [Controlled scaling and solver
traces](controlled-scaling-trace.md) when the question concerns evaluated
derivatives or solver behaviour.

This diagnostic follows the “bounds given as constraints” idea in the
[JuMP model-debugging initiative](https://github.com/jump-dev/JuMP.jl/issues/3664).
The [prior-art page](../reference/prior-art.md) records the broader terminology
and related projects used by NLPDiagnostics.
