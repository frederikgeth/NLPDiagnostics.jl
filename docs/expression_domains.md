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

`IntervalEnclosure` stores a conservative lower and upper bound, validity, and
whether all traversed operators had informative range rules. Initial variable
enclosures come from:

- `GreaterThan`, `LessThan`, `Interval`, and `EqualTo`;
- MOI `Parameter`;
- `ZeroOne`; and
- the interval hull of semicontinuous and semiinteger domains.

Affine and quadratic expressions are propagated directly. Supported nonlinear
range rules include arithmetic, integer powers, square root, logarithms,
exponential, absolute value, and conservative trigonometric ranges. Unknown
operators return the full real enclosure.

The implementation preserves `Real` bound types rather than converting all
bounds to `Float64`.

## Finding semantics

A proven violation means the entire conservative enclosure lies outside the
required operator domain. Because the actual range is contained in the
enclosure, this is a mathematical proof.

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
analysis to avoid duplicate findings. Constant objectives and constant invalid
subexpressions inside nonconstant sources are handled by the domain layer.

## Extension hooks

Packages registering custom nonlinear operators may implement:

```julia
NLPDiagnostics.operator_interval(
    ::Val{:my_operator},
    argument_intervals,
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
return conservative enclosures; an unsound range could create a false proven
violation downstream.

## Current limits

- Constraint equations are not used for bound tightening.
- Interval propagation is not correlation-aware.
- Operating-point violations are available when an explicit evaluation or
  initialization point is supplied.
- User-defined operators are opaque until an extension supplies rules.
- The domain rules describe Julia/MOI real-valued evaluation semantics, not
  complex-valued extensions.
