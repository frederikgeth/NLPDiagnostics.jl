# Tutorial: calibrate dependent rows on an OPF endpoint

!!! note "Learning goals"
    After this tutorial, you can select equality and active rows from public
    constraint-set evidence, compare their local ranks under one policy, and
    trace a localized pair back to its OPF model variables. **Prerequisites:**
    [locate dependent constraint rows](dependent-rows.md) and the
    [three-bus OPF investigation](three-bus-opf.md). **Time:** about 20 minutes.
    **Artifact:** a source-hashed, point-qualified row-scope comparison.

The small teaching model showed why point and activity matter. Now repeat the
method on the checked-in three-bus ACP OPF case. This is an **exposed
development fixture**, not an independently prepared incident or evidence of
diagnostic benefit on a new network. The complete script is
[`examples/opf_dependent_rows.jl`](https://github.com/frederikgeth/NLPDiagnostics.jl/blob/main/examples/opf_dependent_rows.jl).

## Preserve the source and endpoint

The script hashes the licensed MATPOWER source, builds PowerModels' ACP
formulation, solves with recorded Ipopt options, and reevaluates the returned
point through NLPDiagnostics. The source has 28 model variables and 79
evaluated scalar constraint rows under this environment.

```@example opf_dependent_rows
using JuMP, NLPDiagnostics
using NLPDiagnostics.Advanced
import MathOptInterface as MOI

include(joinpath(pkgdir(NLPDiagnostics), "examples", "opf_dependent_rows.jl"))
case = run_case3_dependent_rows()
@assert case.activity.complete
@assert count(row -> row.classification == :violated,
    case.activity.activities) == 0
(
    source_sha256 = case.source_sha256,
    solver_status = case.termination,
    point = case.endpoint.point.label,
    point_kind = case.endpoint.point.provenance.kind,
    evaluated_rows = length(case.evaluation.constraint_sources),
)
```

`activity.complete` means each evaluated scalar set received the generic
bound interpretation used here. The no-violation check uses the script's
``10^{-6}`` feasibility tolerance. A solver's feasible status and this local
check are context for the rank question; neither authenticates the network's
physical data.

## Choose the rows before interpreting rank

The script uses [`constraint_feasibility_summary`](@ref) to select rows
classified `:equality`, then adds rows classified `:active_lower`,
`:active_upper`, or `:active_lower_upper`. The latter classification uses an
explicit ``10^{-6}`` activity tolerance. Inactive and violated rows are not
silently added to the active scope.

```@example opf_dependent_rows
@assert case.equality.dependent === false
@assert case.active.irreducible_under_policy
@assert case.active_tight.irreducible_under_policy
(
    equality = (rows = length(case.equality_rows),
        rank = case.equality.selected_rank,
        dependent = case.equality.dependent),
    equality_plus_active = (rows = length(case.active_rows),
        rank = case.active.selected_rank,
        dependent = case.active.dependent),
    thresholds = (case.active.threshold, case.active_tight.threshold),
)
```

Here the 20 equality rows are independent at ``10^{-8}``. The 28-row active
scope has rank 26. Both observations belong to this exact endpoint, unscaled
Jacobian, and absolute-threshold policy. The second run holds point and scope
fixed but tightens the threshold to ``10^{-10}``.

## Inspect the minimal set and its source

```@example opf_dependent_rows
localized = [case.activity.activities[row] for row in case.active.rows]
@assert case.active.rows == case.active_tight.rows
@assert case.active.deletion_ranks == [1, 1]
@assert all(row -> row.source.index == localized[1].source.index, localized)
[(row = row.row,
    variable = name(VariableRef(case.model, MOI.VariableIndex(row.source.index))),
    set = row.source.set_type,
    lower = row.lower,
    upper = row.upper) for row in localized]
```

The localized pair is the lower and upper bound on the same public variable,
`0_pg[3]`, both at zero. Each individual row has rank one, while the pair has
rank one: the deletion check establishes inclusion-minimal dependence under
the fixed threshold. This is a useful model-representation observation, not
evidence that the physical network has a gauge or that Ipopt struggled.

The active scope has **two** missing row ranks, but the method returns **one**
minimal set. Do not report this pair as an exhaustive explanation of the
active-set rank deficit. To investigate the rest, change the declared scope
or run a separate controlled analysis and retain both policies. Also check
whether the active-set definition and feasibility tolerance are appropriate
for the scientific question before discussing a constraint qualification.

For a new case, copy the [experiment record](../reference/experiment-record.md)
and retain the source hash and license, parser/formulation versions, solver
options, complete point provenance, row classifications and margins, and the
`dependent_row_localization_data` payload for each declared scope and threshold.
An independently prepared case also needs its own source/model/log provenance;
this checked-in fixture cannot supply that evaluation evidence.

## Exercise

Remove only one of the two localized bound rows from `case.active_rows` and
rerun `dependent_row_localization` at the same endpoint and threshold. Predict
the new selected-row count and whether a dependency must remain, using the
original 28-row rank of 26. Then inspect the new localized sources. Why does
this intervention reveal another set without proving that you have enumerated
every minimal dependent set?

!!! info "Expected reasoning"
    Removing one row cannot increase exact rank, and it reduces the row count
    by one. Because the two-row bound pair has identical Jacobian rows,
    removing one leaves exact rank unchanged, so 27 rows still have at least
    one rank deficiency. Verify the fixed-threshold numerical result directly.
    The next localization depends on the revised scope and fixed numerical
    policy; it is not an enumeration certificate.
