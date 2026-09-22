# Island capacity follow-up

`island_capacity_certificate` is a post-evaluation response to the two isolated-load
failures in the frozen case24/case30 run. The original failure records and all
frozen code remain unchanged. The new helper is experimental and outside the
stable API.

```julia
include("benchmarks/power_repair_pilot/island_capacity_certificate.jl")
using .IslandCapacityCertificate
result = island_capacity_certificate(pm, data; absolute_tolerance=1e-6)
```

## Proof boundary

The existing source-to-backend matcher first checks the complete original model.
The helper partitions active buses by active AC-branch connectivity, projects the
supported source data onto each component, and rebuilds its ACP constraints.
Every projected named variable and every scalar row must occur in the original
backend's exact signature, with multiplicities respected. A rebuilt equation,
reference condition, or bound that does not match makes that component unavailable.
No broader algebraic equivalence or transfer of bounds is assumed.

Any point satisfying the original rows also satisfies such a verified subset in
the same named coordinates, with the same absolute unscaled tolerances. Therefore
a sufficient contradiction on a projected island proves a contradiction in the
original model. Proofs are not summed across independently matched islands;
one certified subset suffices. A positive result may coexist with explicitly
unavailable results on other islands. If none is certified and any is unavailable,
the overall result is unavailable.

Before aggregate capacity extraction, each projected equality is normalized using
exact rational arithmetic. A constant residual `c` with `abs(c)>tolerance` is a
direct contradiction, regardless of how many other constant rows have similar
shapes. Equality at the tolerance boundary is not a contradiction. This avoids the
ambiguous selection that blocked both frozen isolated-load cases. This direct
check is not limited to active balance rows, and the returned basis states that it
is a constant encoded equality rather than an aggregate capacity proof.

If no constant contradiction exists, the unchanged tolerance-aware capacity helper
checks that island's encoded balances, generator bounds, and rounded loss budget.
Surplus generation in a different island cannot offset its deficit. Unsupported
source data, inconsistent signatures, and unsupported extraction remain explicit.
`not_ruled_out` never asserts feasibility or adequate voltage/reactive support.

## Validation and limits

```sh
julia --startup-file=no --compiled-modules=no --project=benchmarks/environments/power_repair_pilot test/island_capacity_contracts.jl
```

The standalone contracts use the saved exposed frozen-run inputs, including clean,
rebased, marginal, and isolated-load variants. A separate two-bus deficit derivative
has ample global capacity and requires aggregation within the island. Tests cover
constant tolerance boundaries, missing/duplicated/renamed projected signature rows,
backend tampering, and all three old freeze guards.

Artifacts are written to `work/island-capacity-followup/summary.json`. This does not
rerun or improve the frozen 11/14 score. These networks are development data now.
No source-unit provenance or automatic repair is added. The frozen solver-acceptance
implementation remains unchanged. The new `solve_with_island_preflight(pm, data;
absolute_tolerance=1e-6)` wrapper rejects certified island contradictions before
invoking the solver, refuses unavailable preflights, and otherwise delegates to the
existing verified workflow. It does not override unavailable outcomes in that
workflow or broaden its acceptance semantics.

The follow-up passes **44 targeted assertions**. Both exposed isolated-load cases
are certified using constant equalities; the two-bus derivative uses an aggregate
island-capacity certificate despite ample global supply. Clean, rebased, and
marginal controls are not ruled out, and the clean wrapper test returns an accepted
verified primal point. All three earlier freezes remain intact. The original
11/14 failed gate is preserved and is not retrospectively rescored.
