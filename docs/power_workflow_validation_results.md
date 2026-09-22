# Frozen workflow validation results

**The workflow did not meet its acceptance gate: 11 of 14 criteria passed.**
The implementation, executable protocol, pinned environment, and fixtures were
frozen across 62 files before evaluation. All 14 case variants completed with
recorded outcomes. No diagnostic code, threshold, fixture, or criterion was changed
following the results.

| Predetermined criterion | case24 | case30 |
| --- | --- | --- |
| Clean point accepted | Pass | Pass |
| Zero-capacity contradiction certified | Pass | Pass |
| Marginal shortage not overclaimed | Pass | Pass |
| Isolated-load shortage certified | **Fail: unavailable** | **Fail: unavailable** |
| Unit-corrupted point rejected | Pass: alert only | **Fail: accepted** |
| Consistently rebased point accepted | Pass | Pass |
| Storage explicitly unavailable | Pass | Pass |

This heterogeneous count is not an accuracy percentage. Some criteria check
mathematical conservatism, others desired practical coverage beyond the current
model-only scope. All fixtures are public and the incidents are constructed.
They were new to this workflow before evaluation and are now development data.

## What failed

Both island cases isolate bus 3, retaining positive load and no active generation
or connected AC branch. Saved topology and load premises were independently
checked. The source capacity preflight remains available, but encoded equation
selection returns `required equation is absent or ambiguous` before solving.
This is a coverage failure with an explicit unavailable result, not a false
infeasibility claim. Selecting balances only by a generic polynomial shape is
insufficient when multiple constant balance rows match.

The case30 unit variant divides already-per-unit active loads by baseMVA again.
It returns `LOCALLY_SOLVED`, and the independent verifier accepts its point against
the altered mathematical model. The solver and verifier have no source-intent
contract that would reject this transformation. This is a practical detection gap;
it does not invalidate verification of the equations actually provided.

Case24's same unit mutation returns `LOCALLY_INFEASIBLE` and a point with verified
violations. This meets the preregistered rejection proxy but does **not** identify
the unit error. It must not be reported as correct unit root-cause localization.
Neither network demonstrates source-aware unit diagnosis in this run.

## What transferred

Both clean and consistently rebased models return accepted primal points. Both
zero-capacity variants retain tolerance-aware contradiction certificates and their
returned points are rejected. Both marginal variants remain `not_ruled_out` by the
capacity certificate, although their solves return infeasible status and violated
points. Inconclusive capacity evidence was not promoted to feasibility. Both
storage variants are explicitly refused by the unsupported-device scope check.

The rebasing checks preserve physical active load within the frozen tolerances
and verify impedance scaling, but do not constitute a separately proved complete
model-equivalence oracle. Parser corrections and cost normalization remain in the
run log. Conclusions concern the saved parsed/transformed models, not exact raw
MATPOWER equivalence or operational security.

## Priorities after this evaluation

1. Handle infeasible constant balance rows and develop per-island capacity budgets,
   with stable equation identification and adversarial tests for ambiguous rows.
2. Connect source-unit/provenance checks to the verified model workflow. Model
   feasibility alone cannot determine whether the intended load was represented.
3. Consolidate one report that distinguishes contradiction, verified point,
   unavailable analysis, and source-intent mismatch. Keep these outcomes separate.
4. Evaluate documented incidents with engineers before claiming repair benefit.

Keep automatic repairs and stable-API promotion deferred. Any fixes are
post-evaluation work and must preserve these failures. Another transfer evaluation
requires different cases or explicitly acknowledged reuse.

## Evidence and reproduction

- Protocol: `docs/power_workflow_validation_protocol.md`.
- Freeze: `docs/power_workflow_validation_freeze.json`.
- Driver: `benchmarks/run_frozen_power_validation.jl`.
- Full results: `work/frozen-power-workflow-validation/evaluation.json` and per-case
  `input.json`/`record.json` files.
- Run log: `/tmp/nlpdiag-frozen-workflow-validation.log`.

The plan SHA256 is
`5a4b448b7c21b43ae9276732b3a8b71745e78c0910be42b2bd35d74f6cb82e96`.
All 62 frozen hashes and 14 saved input hashes were independently checked after
completion. The earlier case9/case14 freezes also remain intact. **Five harness
integrity assertions passed**, independently of the failed acceptance gate. Local
quality, proof-inventory scope, and whitespace checks passed. No core source was
changed; the last full-suite baseline remains 7,560 assertions and was not rerun
for this evaluation harness.

The driver refuses to overwrite a nonempty result directory. Reproduction belongs
in a separate checkout with the frozen inputs and an empty output directory; do
not delete or replace the original evaluation to hide failures.
