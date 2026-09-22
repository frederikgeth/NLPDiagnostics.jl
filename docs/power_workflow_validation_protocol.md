# Frozen workflow validation protocol

This run evaluates transfer of the existing experimental certificate and verified
solver-acceptance workflow to public PowerModels case24 and case30 fixtures. Before
selection, a filename search found no case24/case30 references in project tests,
benchmarks, or docs (excluding JSON summaries). Only fixture headers were inspected
before this protocol; no diagnostic or solver outcomes were inspected. This is new
to this workflow, not blinded data or proof of absence from model training.

Fixtures are copied unchanged from PowerModels 0.21.6's installed test collection,
with the distribution license alongside each file. Their headers retain pglib-opf
attribution. Raw fixture hashes, Julia sources, pinned environment, this protocol,
and the executable harness are frozen before the first evaluation. Parser warnings
and input normalization are retained in the run log and parsed inputs are saved.
No fixture replacement, threshold adjustment, repair, or policy tuning is allowed
within this run. A compatibility failure is a result. Any follow-up must be labeled
post-evaluation and preserve this record.

## Cases and predetermined criteria

Both networks receive the same seven variants, evaluated at absolute unscaled
true-residual/bound tolerance `1e-6`. Solver settings and verification rules are
those in the frozen `verified_solver_acceptance.jl` helper.

| Variant | Predetermined transformation and criterion |
| --- | --- |
| Clean | Unchanged parsed data; require `accepted_primal_point`. |
| Zero capacity | All active generator pmax set to zero, pmin lowered to at most zero; require tolerance-aware contradiction and no accepted point. |
| Marginal shortage | As above, except the lowest-ID active generator gets `Float64(exact total demand)-1e-8` capacity; require positive exact source gap and certificate `not_ruled_out`. No feasible-point claim is expected. |
| Isolated load | Choose the lowest-ID positive-load bus without active generation and disable all incident AC branches; require an island shortage certificate. Aggregate-only checking may miss this. |
| Load-unit corruption | Divide already-per-unit active loads by baseMVA again; require workflow rejection of the point. A mathematically valid altered model may pass, exposing the lack of source-intent verification. |
| Consistent rebasing | Double baseMVA using mixed/per-unit conversion, explicitly double branch r/x and halve branch admittances; require acceptance and preserved physical loads/rebased impedances. No raw-data intent change is introduced. |
| Unsupported storage | Add an active storage component; require explicit unsupported-storage unavailability, not a false pass or infeasibility claim. |

There are **14 per-network criteria**. Island and source-unit criteria deliberately
probe desired practical coverage beyond aggregate capacity and mathematical primal
verification. Their failures must not be called false mathematical certificates.
Conversely, a point passing its altered model is not evidence that a unit error was
found. The count is a heterogeneous acceptance gate, not an accuracy percentage or
proof of general usefulness. Rejection of the unit variant is only an alert proxy,
not correct root-cause localization.

Truth evidence uses exact source capacity sums, explicit disconnected-bus topology,
and known input transformations. The passive closed-model data check is saved as
premise evidence. No truth label is supplied to the diagnostic implementation.
Rebasing uses the existing PowerModels conversion plus explicit impedance changes;
load/impedance checks are not an independently proved full-model equivalence test.

## Execution and retention

Run `benchmarks/run_frozen_power_validation.jl` in the committed pinned pilot
project. The driver verifies every frozen hash before running, between cases, and
after completion. It refuses to overwrite a nonempty evaluation directory. Each
case saves transformed inputs, their hashes, truth evidence, full workflow results,
and elapsed time under `work/frozen-power-workflow-validation/`. Exceptions and
unavailable outcomes remain in the denominator. The final evaluation stores each
criterion separately from harness integrity assertions: passing the harness does
not mean passing the evaluation.

These are constructed incidents, without human repair measurements. Following this
run, these fixtures become exposed development data. No stable-API promotion or
automatic repair is authorized by a passing count alone.
