# Expression-domain analysis

Expression-domain analysis is static. It traverses public
`ScalarNonlinearFunction` trees and never calls user functions or derivative
evaluators.

## Expression provenance

Each issue contains an `ExpressionNodePath` with:

- an objective or constraint `EntityRef`;
- a vector constraint row, when applicable; and
- one-based nonlinear argument indices from the source root.

For example, `constraint[3]/row[2]/arg[1]` identifies a nested operator without
depending on JuMP internals or variable-name parsing.

## Interval enclosures

`IntervalEnclosure` stores a lower and upper bound, validity, information status,
and an explicit `certified` flag. Initial variable
enclosures come from:

- `GreaterThan`, `LessThan`, `Interval`, and `EqualTo`;
- MOI `Parameter`;
- `ZeroOne`; and
- the interval hull of semicontinuous and semiinteger domains.

Affine and quadratic expressions are propagated directly. Supported nonlinear
range rules include arithmetic, integer powers, square root, logarithms,
exponential, absolute value, and trigonometric range estimates. Unknown
operators return the full real enclosure.

The implementation preserves `Real` bound types rather than converting all
bounds to `Float64`.

### Arithmetic certification boundary

Addition, scaling, multiplication, reciprocal, and bounded integer powers now
operate exactly on finite represented integer, rational, and floating-point
endpoints. Results remain rational when Float64 cannot represent them exactly.
This handles cancellation, subnormal products, and results beyond floating-point
range without silently narrowing an interval. Infinite endpoints are treated as
limits. Unsupported inputs and reciprocal intervals containing zero widen to
the full real line. Integer powers outside `[-1024, 1024]` also widen to bound
exact-integer work.

The guarantee is conditional on the input intervals actually enclosing their
expressions. The `valid` and `informative` fields are **not certification flags**.
The historical two- and four-argument constructors create uncertified estimates.
An extension may explicitly assert a validated enclosure with
`IntervalEnclosure(lower, upper; certified=true)`. That assertion must cover the
real expression and all premises, not just the arithmetic storing the endpoints.

Exact arithmetic preserves input certification. Built-in transcendental range
estimates remain uncertified. Domain and derivative scans widen uncertified
intermediate estimates to unknown ranges and cannot use them to prove a
violation or silently discharge a domain requirement. This also applies to
custom operator results and explicit operating points.

Proof-producing bound analysis uses declared bounds, exact affine propagation,
absolute-value/min/max implications, and a small whitelist of exact inverse
rules. These include square/cube inverses and reference cases such as
`log(x) >= 0` and `cosh(x) <= 1`. General inverse-function and quadratic-geometry
estimates are excluded from this path. `domain_interval_data` retains those
estimates with `certified=false`; they are not safe bounds to apply to a model.
Numerical risk analysis may still use them as numerical or heuristic evidence.

Single-variable affine isolation and multi-variable affine propagation use exact
represented coefficients and declared bounds, including repeated coefficient
sums and division. Unsupported or nonfinite coefficients make these paths
abstain; they are never silently removed from a row. Arithmetic does not recover
terms lost by an upstream modeling layer before the public MOI snapshot is read.

The tests in
[certified_interval_arithmetic.jl](/Users/uqfgeth/Documents/GitHub/NLPDiagnostics.jl/test/certified_interval_arithmetic.jl)
exercise these specific guarantees with independent rational references and
feasible/infeasible controls.

## Finding semantics

A proven domain violation requires a certified enclosure wholly outside the
required operator domain. Uncertified chains produce possible/unknown findings,
including `operating_point_domain_unknown` and
`operating_point_derivative_domain_unknown`. Actual numerical evaluation
failures remain separate findings. Other static proof-producing families,
including direct geometric and normalized-row analysis, remain under review in the
[recovery plan](/Users/uqfgeth/Documents/GitHub/NLPDiagnostics.jl/docs/recovery_plan.md).

A possible violation means the enclosure intersects an invalid region. It does
not prove that an invalid value is reachable: ordinary interval arithmetic can
lose correlations, as in repeated occurrences of the same variable. Possible
violations are therefore labeled heuristic interval inferences. Confidence is
reduced when an unsupported operator made the enclosure uninformative.

Current domain rules include:

| Operator | Requirement |
|---|---|
| `log`, `log2`, `log10` | argument greater than zero |
| `log1p` | argument greater than negative one |
| `sqrt` | argument nonnegative |
| `asin`, `acos` and degree variants | argument in `[-1, 1]` |
| `asec`, `acsc` and degree variants | absolute argument at least one |
| `acosh` | argument at least one |
| `atanh` | argument strictly between negative and positive one |
| `asech` | argument in `(0, 1]` |
| `acsch` | argument nonzero |
| `acoth` | absolute argument greater than one |
| tangent/secant families | avoid periodic cosine zeros |
| cotangent/cosecant families | avoid periodic sine zeros |
| division and `inv` | denominator/argument nonzero |
| negative integer power | base nonzero |
| non-integer power | base nonnegative |
| negative fractional power | base strictly positive |

Function-value domains are distinct from finite-derivative domains. For
example, `sqrt(0)` is a valid value but has a singular first derivative. See
[`derivatives_stability_initialization.md`](derivatives_stability_initialization.md)
for the separate derivative contract and numerical fingerprints.

Constant constraint expressions remain handled by the existing constant
analysis to avoid duplicate findings. General nonlinear constant evaluations
are numerical observations, including operator-domain exceptions; they do not
certify real-domain infeasibility. Constant objectives and constant invalid
subexpressions inside nonconstant sources are handled by the domain layer.

## Extension hooks

Packages registering custom nonlinear operators may implement:

```julia
NLPDiagnostics.operator_interval(
    ::Val{:my_operator},
    argument_intervals::Vector{NLPDiagnostics.IntervalEnclosure},
    original_arguments,
)
```

and:

```julia
NLPDiagnostics.operator_domain_requirements(
    ::Val{:my_operator},
    original_arguments,
    argument_intervals,
)
```

The second method returns `OperatorDomainRequirement` objects. Extensions must
assert `certified=true` only for validated enclosures. Uncertified estimates
remain usable by numerical risk checks but cannot support mathematical proofs.

## Current limits

- Selected constraint equations tighten analysis-only intervals; the model is
  unchanged. General nonlinear tightening remains numerical evidence only.
- Interval propagation is not correlation-aware.
- Operating-point violations are available when an explicit evaluation or
  initialization point is supplied.
- User-defined operators are opaque until an extension supplies rules.
- The domain rules describe Julia/MOI real-valued evaluation semantics, not
  complex-valued extensions.
