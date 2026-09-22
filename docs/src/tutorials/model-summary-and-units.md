# Inspect a model before solving

This tutorial builds the same one-bus balance in two coordinate systems. The
first model uses MW throughout. The second stores generation in MW and imports
in W. Both are mathematically coherent, but the mixed-coordinate model exposes
a million-to-one span in its linear constraint matrix.

The point is not that every large span is an error. The point is to discover
the span before a solver status makes it tempting to invent an explanation.

## Build a coherent model

```@example summary_units
using JuMP
using NLPDiagnostics.Stable

function build_balance_model(; mixed_coordinates::Bool)
    model = Model()
    if mixed_coordinates
        @variable(model, 0 <= generation_mw <= 100)
        @variable(model, 0 <= import_w <= 100e6)
        @constraint(model, 1e6 * generation_mw + import_w == 100e6)
        @objective(model, Min, 50 * generation_mw + 1e-4 * import_w)
    else
        @variable(model, 0 <= generation_mw <= 100)
        @variable(model, 0 <= import_mw <= 100)
        @constraint(model, generation_mw + import_mw == 100)
        @objective(model, Min, 50 * generation_mw + 100 * import_mw)
    end
    return model
end

coherent_model = build_balance_model(mixed_coordinates = false)
coherent = model_summary(coherent_model)
coherent
```

`model_summary` is read-only. It records variable and constraint counts,
represented MOI function-in-set types, objective metadata, a deterministic
model fingerprint, and a static coefficient profile. The fingerprint identifies
the represented public model data; it is not a claim that two physically
equivalent formulations are identical.

Inspect the matrix range directly:

```@example summary_units
coherent_matrix = coherent.coefficient_profile.linear_matrix
(
    minimum = coherent_matrix.minimum_nonzero_magnitude,
    maximum = coherent_matrix.maximum_magnitude,
    span = coherent_matrix.span_ratio,
    density = coherent.coefficient_profile.linear_matrix_density,
)
```

Zero coefficients are counted separately and excluded from the magnitude
span. The density describes the exposed **linear coefficient matrix**. It is
not nonlinear Jacobian density.

## Change only the coordinate convention

```@example summary_units
mixed_model = build_balance_model(mixed_coordinates = true)
mixed = model_summary(mixed_model)
mixed_matrix = mixed.coefficient_profile.linear_matrix

@assert coherent_matrix.span_ratio == 1.0
@assert mixed_matrix.span_ratio == 1.0e6
(
    minimum = mixed_matrix.minimum_nonzero_magnitude,
    maximum = mixed_matrix.maximum_magnitude,
    span = mixed_matrix.span_ratio,
    observations = mixed.coefficient_profile.observations,
)
```

This observation supports a narrow claim: the exposed linear row contains
coefficients six orders of magnitude apart. It does not establish that the
model is wrong or that a solver will fail. In this example, the variable names
and explicit conversion explain the span. If both variables had been described
as MW, the same output would be a useful prompt to inspect a unit conversion.

The objective profile also deserves its own interpretation. A cost coefficient
on a W variable is expected to differ from the coefficient on the equivalent
MW variable. Compare coefficients only after recording what each coordinate
means.

## Know what the profile cannot see

Static coefficients are well defined for affine and quadratic MOI functions.
They are not generally well defined for an arbitrary nonlinear expression or
an opaque callback. NLPDiagnostics records that coverage boundary:

```@example summary_units
import MathOptInterface as MOI

opaque_model = MOI.Utilities.UniversalFallback(MOI.Utilities.Model{Float64}())
x = MOI.add_variable(opaque_model)
MOI.add_constraint(
    opaque_model,
    MOI.ScalarNonlinearFunction(:*, Any[1e9, x]),
    MOI.EqualTo(1.0),
)
opaque = coefficient_profile(opaque_model)
@assert opaque.opaque_constraint_count == 1
@assert opaque.linear_matrix.total_count == 0
opaque.observations
```

Do not reinterpret the `1e9` literal as a static matrix coefficient. Evaluate
the nonlinear Jacobian at a named point and inspect
`jacobian_scale_summary` when the research question concerns local derivative
scales. The [controlled scaling and solver-trace
tutorial](controlled-scaling-trace.md) demonstrates that next step.

## Save a renderer-neutral record

```@example summary_units
record = model_summary_data(mixed)
@assert record["schema_version"] == "nlpdiagnostics-model-summary-v1"
@assert record["coefficient_profile"]["schema_version"] ==
        "nlpdiagnostics-coefficient-profile-v1"
sort!(collect(keys(record)))
```

Save this record with the formulation revision, unit convention, solver
settings, and experimental hypothesis. The runnable version is
`examples/model_summary_and_units.jl`.
