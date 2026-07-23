# MOI nonlinear API notes

Status: initial capability survey for the generic core.

These notes capture the public interfaces relevant to NLPDiagnostics. They are
based on MathOptInterface 1.51 and JuMP 1.31 and should be rechecked when the
lower MOI compatibility bound changes.

## Model-level symbolic information

`MOI.ModelLike` exposes the function and set of every ordinary constraint
through `ConstraintFunction` and `ConstraintSet`. The nonlinear function types
are:

- `MOI.ScalarNonlinearFunction(head, args)`, a recursive symbolic tree; and
- `MOI.VectorNonlinearFunction(rows)`, a vector of scalar nonlinear trees.

A scalar nonlinear argument may be a real constant, `VariableIndex`,
`ScalarAffineFunction`, `ScalarQuadraticFunction`, or another
`ScalarNonlinearFunction`. The model's
`ListOfSupportedNonlinearOperators` reports operator heads understood by the
model. User-defined operators are registered with the `UserDefinedFunction`
attribute.

This view is sufficient for expression traversal, exact dependency analysis,
operator-domain rules, structural fingerprints, and graph construction. It is
also the right stable boundary for current JuMP models.

MOI's standard form is extensible. A third-party `AbstractFunction` may appear.
An analysis must therefore either have an extractor for that type or emit an
explicit capability finding. It must not assume that an unknown function has no
variables.

## `MOI.Nonlinear` expression representation

`MOI.Nonlinear.Model` stores nonlinear expressions as typed linear tapes.
`Nonlinear.Expression` separates nodes and values, while each node records its
type, parent, and an index into the appropriate value or operator table. Parent
links and topological ordering avoid allocating a child vector per node.

This representation is useful when NLPDiagnostics constructs an evaluator, but
the generic intermediate representation should not expose MOI's tape as its
own public format. A normalized NLPDiagnostics expression DAG needs additional
fields for source entity, inferred domain, units, plugin metadata, and
normalization provenance.

## Evaluator information

An `MOI.AbstractNLPEvaluator` always provides objective and constraint values
after initialization. `MOI.features_available(evaluator)` may additionally
advertise:

| Feature | Public operations |
|---|---|
| `:Grad` | objective gradient |
| `:Jac` | constraint gradient, Jacobian structure and values |
| `:JacVec` | Jacobian and transposed-Jacobian products |
| `:Hess` | Hessian-of-the-Lagrangian structure and values |
| `:HessVec` | Hessian-of-the-Lagrangian products |
| `:ExprGraph` | objective and constraint expressions as Julia `Expr`s |

`MOI.initialize` must be called with the requested supported features before
evaluation. The evaluator's variable order is exactly
`ListOfVariableIndices`; nonlinear model copies must not reorder it.

`MOI.NLPBlockData` packages an evaluator, nonlinear constraint bounds, and an
objective-presence flag. It remains important for imported `.nl`/`.mof.json`
models and solver-facing callback paths. Ordinary scalar and vector nonlinear
functions should remain the preferred static representation when present.

An evaluator adapter for NLPDiagnostics should:

1. record the exact available/requested feature set;
2. initialize once for the union of requested features;
3. preserve the evaluator's variable order;
4. attach every value or derivative to its evaluation point;
5. retain sparsity structures and duplicate-entry semantics; and
6. turn evaluation exceptions and non-finite values into evidence, not crashes.

## Nonlinear oracle sets

Recent MOI releases also provide `VectorNonlinearOracle`, a set whose callbacks
define values, Jacobian values, and optionally Hessian-of-the-Lagrangian values.
The constrained function supplies the oracle inputs. This cannot be analyzed
symbolically like a `ScalarNonlinearFunction`; it needs a capability adapter and
should be reported as opaque when a requested symbolic analysis is unavailable.

## Consequences for the package

- Static ingestion is a public-MOI model snapshot.
- Expression analysis handles scalar and vector nonlinear function trees.
- Evaluator and oracle access is capability-based.
- JuMP support is a thin package extension calling `JuMP.backend`.
- No analysis may infer absence from unavailable information.

Official references:

- [MOI nonlinear overview](https://jump.dev/MathOptInterface.jl/stable/submodules/Nonlinear/overview/)
- [MOI nonlinear evaluator reference](https://jump.dev/JuMP.jl/stable/moi/reference/nonlinear/)
- [MOI standard-form functions](https://jump.dev/MathOptInterface.jl/stable/reference/standard_form/)
- [MOI model API](https://jump.dev/MathOptInterface.jl/stable/manual/models/)
