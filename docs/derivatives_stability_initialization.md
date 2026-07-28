# Derivative domains, numerical fingerprints, and initialization

Real-valued function domains and finite-derivative domains are different
contracts. NLPDiagnostics reports them separately.

For example:

| Primitive | Finite value | Finite first derivative | Finite second derivative |
|---|---|---|---|
| `log(x)` | `x > 0` | same as value domain | same as value domain |
| `log1p(x)` | `x > -1` | same as value domain | same as value domain |
| `log1mexp(x)` | `x < 0` | same as value domain | same as value domain |
| `logdiffexp(a, b)` | `a > b` | same as value domain | same as value domain |
| `sqrt(x)` | `x >= 0` | `x > 0` | `x > 0` |
| `cbrt(x)` | all real `x` | `x != 0` | `x != 0` |
| `abs(x)` | all real `x` | not classically differentiable at zero | not analyzed after a first-order failure |
| `asin(x)`, `acos(x)` | `-1 <= x <= 1` | `-1 < x < 1` | `-1 < x < 1` |
| `x^p`, `0 < p < 1` | `x >= 0` | `x > 0` | `x > 0` |
| `x^p`, `1 < p < 2` | `x >= 0` | finite at zero | second derivative requires `x > 0` |

The first and second derivative checks matter because gradient-based solvers
may evaluate a valid function value and still receive an infinite,
discontinuous, or implementation-defined derivative.

`operator_derivative_requirements(Val(operator), arguments, intervals)` is a
public extension hook for user-defined operators. Value-domain requirements
that are identical to derivative requirements are not duplicated. Thus
`log(x)` continues to produce a value-domain finding, whereas `sqrt(0)`
produces a distinct derivative-domain finding.

Primitive nondifferentiability is reported at the expression node. An
enclosing expression can occasionally cancel it, such as a specially
constructed composition involving `abs`. NLPDiagnostics does not claim that a
primitive-node finding proves the full expression is nonsmooth after all
possible algebraic simplifications.

## Floating-point range checks

`analyze_expressions` evaluates conservative primitive ranges against an
explicit floating-point type. The default is `Float64`.

Current range fingerprints include:

- overflow and underflow-to-zero for `exp`, `exp2`, and `expm1`;
- overflow for `sinh` and `cosh`; and
- exact-point variants of the same risks.

The numeric type is evidence. For example, `exp(100)` is finite in `Float64`
but overflows in `Float32`.

For logarithmic primitives with a strict real domain, exact-point expression
analysis also emits a heuristic derivative-amplification warning when the
positive domain margin is at most `sqrt(eps(T))`: `x` for `log(x)`, `1 + x`
for `log1p(x)`, `-x` for `log1mexp(x)`, and `a - b` for
`logdiffexp(a, b)`. This also catches a fragile composite whose outer `log`
has a near-zero positive argument. It is not a domain violation—the value is
still valid—but it makes the rapidly growing local derivative and numeric type
explicit.
The same point-local warning covers `sqrt(x)` near zero and reciprocal factors
(`inv(x)` or a division denominator) near their nonzero boundary. These retain
their existing exact derivative-domain errors at the boundary itself; the new
warning describes large but finite derivatives strictly inside the domain.
For a non-integer `x^p` with positive base near zero, the evidence includes
both derivative orders because the exponent determines which one is amplified:
for example, `0 < p < 1` affects both, while `1 < p < 2` can leave the first
derivative finite but make the second derivative large.
The finding includes stable estimates of the local first- and second-derivative
magnitudes (the maximum first derivative across `a` and `b` for
`logdiffexp`); an infinite estimate is useful floating-point evidence, not a
claim that the mathematical derivative is undefined.

These are numerical representation findings, not mathematical domain
failures. Underflow can be harmless in some applications, but in an NLP model
it can also create an artificial zero derivative or flat objective direction.

## Stable-expression fingerprints

The expression scanner recognizes common mathematically reasonable but
floating-point-fragile compositions:

| Fingerprint | Suggested primitive or reformulation |
|---|---|
| `log(1 + x)` | `log1p(x)` |
| `log(1 - x)` | `log1p(-x)` |
| `exp(x) - 1` | `expm1(x)` |
| `log(exp(x))` | `x`, when equivalent real semantics are intended |
| `log(1 + exp(x))` | stable softplus / `log1pexp` |
| `log1p(exp(x))` | stable softplus / `log1pexp` |
| `log(1 - exp(x))`, `log1p(-exp(x))` | branch-aware `log1mexp` (`x < 0`) |
| `log(exp(a) - exp(b))` | branch-aware `logdiffexp` (`a > b`) |
| `log(cosh(x))` | overflow-safe `logcosh` |
| `log(sum(exp(xᵢ)))` | max-shifted `logsumexp` |
| `1 / (1 + exp(-x))`, `exp(x) / (1 + exp(x))` | sign-aware stable logistic |
| `1 / (1 + exp(x))` | sign-aware `logistic(-x)` |

For softplus, a stable scalar implementation is:

```julia
max(x, zero(x)) + log1p(exp(-abs(x)))
```

`log1pexp` is the common Julia name; `log1exp` and `softplus` are also
recognized as stable custom-operator heads for interval propagation. Fixed-value
static evaluation additionally recognizes `log1mexp`, `logdiffexp`, `logcosh`,
and `logsumexp` with stable formulas. These operators are not necessarily built
into MOI and may need to be registered by the modeling package. In particular,
registration must supply correct values and derivatives; a static fixed-value
evaluator does not make a custom head available to a solver's AD pipeline.

Fingerprints are warnings rather than algebraic rewrites. NLPDiagnostics never
changes the model, and user-defined operator semantics may prevent an
apparently obvious replacement.

## Initialization analysis

`initialization_point(model)` reads `MOI.VariablePrimalStart` in exact MOI
variable order. It returns `nothing` unless every variable has a real start;
missing values are never replaced implicitly.

```julia
initial_report = analyze_initialization(model)

# Or include it in the combined report:
report = analyze(model; check_initialization = true)
```

A complete initialization is checked for:

- variable-bound violations;
- non-fixed variables exactly on finite bounds;
- value-domain violations;
- derivative-domain violations;
- strict-domain derivative-amplification warnings for stable `log1mexp` and
  `logdiffexp` operators near their boundaries;
- overflow, underflow, and non-finite values or derivatives; and
- Jacobian zero sensitivities and scaling spread;
- scalar-bound constraint feasibility violations and interior margins; and
- active-row LICQ evidence plus a conservative MFCQ common-descent screen.

This is an exact-point analysis. It does not imply that a solver will evaluate
the unchanged start: solvers may project bound starts into the interior,
modify slacks, or apply their own initialization procedures.

The generic core understands scalar lower/upper/equality bounds. Coupled cones,
device semantics, strict interior rules, and solver-specific initialization
transformations remain plugin or solver-extension work.
