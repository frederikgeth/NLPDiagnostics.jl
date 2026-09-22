# Tutorial: locate dependent constraint rows

!!! note "Learning goals"
    After this tutorial, you can locate a small set of dependent Jacobian rows,
    read the one-row deletion checks, and explain why the result belongs to a
    point and tolerance policy. **Prerequisites:** [numerical rank at a
    point](numerical-rank.md). **Time:** about 15 minutes. **Artifact:** a
    source-labelled, irreducible numerical row set.

A rank estimate says how many independent rows the local Jacobian has. It
does not tell you which equations to inspect. Suppose a model contains

```math
g_1=x+y-1,\qquad g_2=x-y,\qquad g_3=2x-1.
```

The third Jacobian row is the sum of the first two. All three rows together
are dependent, but every pair is independent. Predict the set the localization
will return before running the example.

## Evaluate one named point

The complete runnable script is
[`examples/dependent_rows.jl`](https://github.com/frederikgeth/NLPDiagnostics.jl/blob/main/examples/dependent_rows.jl).
The tutorial executes that script to keep the lesson aligned with the fixture.

```@example dependent_rows
using NLPDiagnostics
using NLPDiagnostics.Advanced

include(joinpath(pkgdir(NLPDiagnostics), "examples", "dependent_rows.jl"))
example = run_dependent_rows_example()
result = example.result

@assert result.available && result.irreducible_under_policy
(
    point = result.point.label,
    source_names = [source.name for source in result.sources],
    selected_rank = result.selected_rank,
    selected_count = length(result.selected_rows),
    localized_rows = result.rows,
)
```

The example evaluates the represented JuMP model at ``(x,y)=(0.5,0.5)``.
The rows are feasible at that point, although the localization algorithm only
uses derivatives. The `sources` fields retain each original constraint name,
function type, and set type; `rows` are positions in the original numerical
evaluation.

## Check why the set is irreducible

```@example dependent_rows
@assert result.deletion_ranks == [2, 2, 2]
(
    fixed_threshold = result.threshold,
    one_row_deletion_ranks = result.deletion_ranks,
    combination = result.coefficients,
    relative_residual = result.relative_residual,
    rank_checks = result.rank_checks,
)
```

The selected three-row matrix has numerical rank two. Deleting any one row
leaves two rows of rank two under the **same fixed threshold**. The reported
coefficients give a unit-length combination of the original rows whose
Jacobian residual is near zero. This establishes an inclusion-minimal
*numerical* dependent row set under the recorded point, scaling, and tolerance.
It does not establish exact algebraic dependence in a general nonlinear model.

The terminology follows [DegeneracyHunter.jl](https://github.com/adowling2/DegeneracyHunter.jl)
and its irreducible degenerate set (IDS) work. Here the finding uses
“numerical irreducible dependent rows” because the deletion check is explicit;
the result does not claim a solver-independent or globally valid IDS.

## Read the finding and choose a scope

```@example dependent_rows
report = example.report
@assert only(report.findings).code == :numerical_irreducible_dependent_rows
payload = dependent_row_localization_data(result)
(
    finding = only(report.findings).code,
    affected = [source.name for source in only(report.findings).affected],
    serialized_threshold = payload["fixed_threshold"],
    serialized_point = payload["point"]["fingerprint"],
)
```

The default searches all represented Jacobian rows. For a constraint
qualification question, first inspect `evaluation.constraint_sources` and pass
the positions of the equalities and active inequalities you intend to study
with `rows = [...]`. An inactive inequality should not become evidence of
active-set degeneracy merely because its Jacobian is dependent on another row.
The method returns one deterministic minimal set; other dependent sets may
also exist. It stops with an explicit unavailable result when derivatives are
incomplete or the work guard is exceeded.

## Exercise

Change the third equation's right-hand side from ``1`` to ``1.1``. What
happens to the Jacobian localization at the same point? What happens to
feasibility? Then replace the third equation by ``x^2=0.25`` and compare the
Jacobian at ``x=0`` and ``x=0.5``.

!!! info "Expected observations"
    A right-hand-side change leaves the Jacobian rows and localization
    unchanged, while the three equations become inconsistent. With ``x^2``
    the derivative of the third row depends on ``x``; the local row relation
    changes with the point. Check feasibility and local rank separately.
