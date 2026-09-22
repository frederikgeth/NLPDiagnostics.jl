# Structural and numerical Hessian density

A nonlinear solver normally asks for a Hessian sparsity pattern before it asks
for values. A position can belong to that pattern and still evaluate to zero at
a particular point. This tutorial keeps those two facts separate.

## Use a point-dependent Hessian

Consider the objective

```math
f(x,y) = (xy)^2 = x^2y^2.
```

Its Hessian is

```math
\nabla^2 f(x,y) =
\begin{bmatrix}
2y^2 & 4xy \\
4xy & 2x^2
\end{bmatrix}.
```

All three lower-triangular positions can be nonzero, so they belong to the
structural pattern. At ``(x,y)=(0,1)``, only the first diagonal entry is
numerically nonzero.

```@example hessian_density
using JuMP
using NLPDiagnostics.Stable

model = Model()
@variable(model, x)
@variable(model, y)
@objective(model, Min, (x * y)^2)

axis = hessian_density_summary(
    model,
    [0.0, 1.0];
    label = "axis point",
)
(
    methods = axis.methods,
    provenance = axis.structure_provenance,
    structural_entries = axis.structural_entry_count,
    numerical_nonzeros = axis.numerical_nonzero_count,
    structural_density = axis.structural_lower_triangle_density,
    numerical_density = axis.numerical_lower_triangle_density,
)
```

For this supported ordinary nonlinear expression, NLPDiagnostics constructs a
public MOI nonlinear evaluator and uses its sparse reverse-mode Hessian. The
reported structure is therefore derivative structure, rather than a pattern
inferred from values.

## Change the point, not the expression

At ``(1,1)``, every structural position is numerically nonzero:

```@example hessian_density
interior = hessian_density_summary(
    model,
    [1.0, 1.0];
    label = "interior point",
)

@assert axis.structural_entry_count == interior.structural_entry_count == 3
@assert axis.numerical_nonzero_count == 1
@assert interior.numerical_nonzero_count == 3
(
    axis = axis.numerical_lower_triangle_density,
    interior = interior.numerical_lower_triangle_density,
)
```

The structural density did not change because the expression did not change.
The numerical density changed because the evaluation point did. This is common
in OPF: products and trigonometric couplings can vanish at a flat start and
become nonzero along a solver trajectory.

## Read the denominator

MOI Hessian callbacks use one triangle of a symmetric matrix. The summary
therefore reports both conventions:

```@example hessian_density
(
    lower_triangle_slots = axis.lower_triangle_slot_count,
    structural_lower_triangle_density = axis.structural_lower_triangle_density,
    numerical_lower_triangle_density = axis.numerical_lower_triangle_density,
    structural_symmetric_density = axis.structural_symmetric_density,
    numerical_symmetric_density = axis.numerical_symmetric_density,
)
```

For two variables, the lower triangle has three slots. Expanding its one
off-diagonal position produces four full-matrix slots. Recording the convention
prevents two correct density numbers from appearing to disagree.

## Record the numerical-zero policy

Numerical nonzeros satisfy

```math
|H_{ij}| > \tau_{abs} + \tau_{rel}\max_{k,l}|H_{kl}|.
```

The defaults are zero absolute tolerance and `sqrt(eps(Float64))` relative
tolerance. They are a recorded classification policy, not a solver tolerance:

```@example hessian_density
(
    absolute_tolerance = axis.absolute_tolerance,
    relative_tolerance = axis.relative_tolerance,
    threshold = axis.numerical_zero_threshold,
    fraction_of_structure = axis.numerical_fraction_of_structure,
)
```

Repeat the summary over independently meaningful points before drawing a
reformulation conclusion. A zero at one start does not establish that an entry
is identically zero or safe to remove. If a structurally dense block remains
numerically sparse across a controlled point campaign, inspect the algebra and
solver linear-algebra cost before testing a reformulation.

The selected Lagrangian also matters. Objective weight and constraint
multipliers determine which second derivatives are combined. The summary and
its serialized record retain those inputs so two density measurements can be
compared against the same selected Lagrangian.

## Preserve provenance and coverage limits

Exact NLP callbacks, nonlinear-oracle callbacks, and constructed AD expose
declared derivative structure. A function-value finite-difference fallback
evaluates a dense lower-triangular candidate and is labelled
`finite_difference_dense_candidate`. An incomplete Hessian retains its partial
counts and an explicit observation instead of presenting them as full-model
coverage.

Serialize the summary without parsing display text:

```@example hessian_density
record = hessian_density_summary_data(axis)
@assert record["schema_version"] ==
        "nlpdiagnostics-hessian-density-summary-v1"
@assert record["point"]["label"] == "axis point"
@assert record["objective_weight"] == 1.0
@assert isempty(record["constraint_multipliers"])
@assert isempty(record["failures"])
sort!(collect(keys(record)))
```

This distinction follows the motivation in [MathOptInterface issue
#2527](https://github.com/jump-dev/MathOptInterface.jl/issues/2527) and the
broader [JuMP model-debugging
initiative](https://github.com/jump-dev/JuMP.jl/issues/3664). The runnable
version is `examples/hessian_density.jl`.
