# Source-load contract follow-up

The frozen case30 unit corruption was accepted because its altered equations were
mathematically satisfied. This experimental follow-up checks a separate proposition:
whether the model's per-bus load totals agree with an explicitly selected source.
It preserves the original failed evaluation and uses its now-exposed inputs.

```julia
include("benchmarks/power_repair_pilot/source_load_contract.jl")
using .SourceLoadContract
reference = SourceLoadReference(source_path, expected_sha256)
result = solve_with_source_contract(pm, data, reference)
# For a declared, consistent change of power base:
result = solve_with_source_contract(pm, rebased_data, reference; rebase_to=200)
```

The caller supplies the expected SHA256 from their chosen reference record. The
helper reads the bytes and checks that hash on every call. It never silently updates
the hash, builds the reference from the model being checked, or guesses source intent.
A hash establishes identity with the selected bytes, not authenticity or approval
of the source. A source revision requires an explicitly selected revised reference.

## Comparison and transformations

The narrow reader extracts one numeric MATPOWER-style baseMVA and 13-column bus
table. Decimal literals are read as exact rational numbers; arbitrary source code
is not executed. The contract concerns the literal table's active MW and reactive
MVAr loads, not the semantics of executing an entire MATLAB file. Computed or
non-numeric table entries are unsupported. Comments are ignored for parsing but
remain part of the file hash.

Source and model bus IDs must match. Each active model load is assigned to its bus,
and exact rational sums of `pd*baseMVA` and `qd*baseMVA` are compared with source MW
and MVAr. A source bus with zero demand may have no model load record. Multiple load
records at one bus are allowed when their aggregate agrees. Missing nonzero loads,
wrong buses, and corrupted active or reactive totals cannot pass this comparison.
Load status changes require a revised source contract and are unavailable here.

A changed power base requires an explicit `rebase_to` value equal to the model base.
The physical-unit comparison must still pass; declaring a rebase cannot excuse
changing baseMVA without rescaling loads. Default absolute comparison tolerances
are `1e-8` MW/MVAr, recorded as exact rationals. They are separate from solver
constraint tolerances. This accommodates binary input conversion while keeping
small mismatches below that declared threshold inconclusive as to exact equality.
`source_consistent` means agreement within this tolerance, not bitwise equality.

## Workflow meaning

`solve_with_source_contract` first verifies that the supplied data describe the
actual backend using the existing conservative matcher. Source disagreement is
then returned as `rejected_by_source_mismatch`, without invoking the solver and
without claiming mathematical infeasibility. Unavailable references or unsupported
source contracts are also stopped explicitly. Consistent inputs continue through
the island preflight and existing verified solver acceptance workflow.

This checks load provenance only. It does not verify generator/branch units, prove
full rebasing equivalence, authenticate engineering intent, identify a specific
conversion operation, or establish operational safety. A feasible but wrong-intent
model can only be rejected relative to an appropriate independently selected source.
A caller selecting the corrupted model itself as its reference defeats that purpose.

## Reproduction

```sh
julia --startup-file=no --compiled-modules=no --project=benchmarks/environments/power_repair_pilot test/source_load_contracts.jl
```

The tests use hashes from the existing frozen plan for raw case24/case30 reference
fixtures and saved transformed inputs. They cover clean loads, active-load
corruption, declared/undeclared/incorrect rebasing, equivalent splits, unsupported
status changes, invalid quantities, reference-byte changes, backend/data disagreement,
and end-to-end acceptance of a legitimately rebased model. Results are saved in
`work/source-load-followup/summary.json`.

This is post-evaluation development with additional source information. It does not
retrospectively improve the frozen 11/14 score, and it is outside the stable API.

The follow-up passes **46 assertions**. Both exposed unit-corruption variants
are rejected by the source contract before solving, while the declared valid
case30 rebase reaches verified primal acceptance. Tests also cover an actual
source load revision, exact tolerance boundaries, and reactive-load corruption.
An independent replay from raw source tables and saved model inputs verifies
108 physical comparisons, including 38 mismatches. All earlier freezes remain
unchanged; these results use extra source information and are not a revised score.
