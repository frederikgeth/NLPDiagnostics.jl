# Tutorial: model failure or bad start?

An NLP can be mathematically meaningful while a supplied starting point makes an
expression impossible to evaluate. This tutorial separates those claims.

## Question and prediction

Consider ``\log(x) \ge 0`` with an initial value ``x=-1``. The logarithm is
undefined at the start. Predict a point-specific domain failure. Do not yet
predict that the model itself is infeasible: values such as ``x=2`` satisfy the
constraint.

```@example initialization
using JuMP, NLPDiagnostics

model = Model()
@variable(model, x, start = -1.0)
@constraint(model, log(x) >= 0)

bad_start_report = analyze(model; check_initialization = true)
bad_codes = Set(finding.code for finding in bad_start_report)
@assert :operating_point_domain_violation in bad_codes
@assert :nonfinite_constraint_value in bad_codes
print(text_report(bad_start_report))
```

The finding names the initialization point. It establishes that this evaluation
cannot support a finite constraint value. It does not establish that every point
violates the logarithm's domain.

## Change only the start

```@example initialization
set_start_value(x, 2.0)
good_start_report = analyze(model; check_initialization = true)
good_codes = Set(finding.code for finding in good_start_report)
@assert :operating_point_domain_violation ∉ good_codes
@assert :nonfinite_constraint_value ∉ good_codes
nothing
```

The point-specific errors disappear without changing the mathematical
constraint. This supports “bad initialization” as the explanation for the
original evaluation failure.

## The model still permits invalid trial values

The declared variable has no positive lower bound, so static interval analysis
cannot prove that all admissible values lie in the logarithm's domain. Preserve
that distinction:

```@example initialization
@assert :possible_expression_domain_violation in good_codes
```

If the application independently establishes ``x \ge 0.1``, encode that model
fact and compare again:

```@example initialization
set_lower_bound(x, 0.1)
bounded_report = analyze(model; check_initialization = true)
bounded_codes = Set(finding.code for finding in bounded_report)
@assert :possible_expression_domain_violation ∉ bounded_codes
nothing
```

This second intervention changes the model domain, so it requires stronger
justification than changing a start. In OPF, analogous distinctions arise with
voltage magnitude, squared-current, logarithmic barrier, and denominator
domains.

## Exercise

Try a start of `x = 0.5`. The expression is finite, but does the constraint hold?
Compare the finding with the `x = -1` case. Explain why “finite evaluation,”
“constraint satisfaction at this point,” and “model feasibility” are three
different claims.
