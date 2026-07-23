# Derivative domains, numerical fingerprints, and initialization

Real-valued function domains and finite-derivative domains are different
contracts. NLPDiagnostics reports them separately.

For example:

| Primitive | Finite value | Finite first derivative | Finite second derivative |
|---|---|---|---|
| `log(x)` | `x > 0` | same as value domain | same as value domain |
| `log1p(x)` | `x > -1` | same as value domain | same as value domain |
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

These are numerical representation findings, not mathematical domain
failures. Underflow can be harmless in some applications, but in an NLP model
it can also create an artificial zero derivative or flat objective direction.

## Stable-expression fingerprints

The expression scanner recognizes common mathematically reasonable but
floating-point-fragile compositions:

| Fingerprint | Suggested primitive or reformulation |
|---|---|
| `log(1 + x)` | `log1p(x)` |
| `exp(x) - 1` | `expm1(x)` |
| `log(exp(x))` | `x`, when equivalent real semantics are intended |
| `log(1 + exp(x))` | stable softplus / `log1pexp` |
| `log1p(exp(x))` | stable softplus / `log1pexp` |
| `1 / (1 + exp(-x))` | sign-aware stable logistic |

For softplus, a stable scalar implementation is:

```julia
max(x, zero(x)) + log1p(exp(-abs(x)))
```

`log1pexp` is the common Julia name; `log1exp` and `softplus` are also
recognized as stable custom-operator heads for interval propagation. These
operators are not necessarily built into MOI and may need to be registered by
the modeling package.

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
