# Status-provenance validation: 4/9 criteria met, gate failed

The status-aware workflow was frozen across 82 files before nine scenarios on a
new original synthetic two-bus model. Physical reference records, model-load
blueprints, and the revision manifest were written separately before model
construction. They were not authored by independent engineers and are not real
operational records. No implementation, scenario, or criterion changed during the
run, and all nine input/contract/report bundles are retained.

| Scenario | Outcome | Criterion |
| --- | --- | --- |
| Baseline | Verified primal point | Pass |
| Reconnection | Verified primal point after declared off/on chain | Pass |
| Undeclared disconnection | Report-construction exception | Fail |
| Omitted nominal record | Report-construction exception | Fail |
| Stale source hash | Report-construction exception | Fail |
| Stale revision label | Verified primal point; label not rejected | Fail |
| Wrong nominal allocation | Report-construction exception | Fail |
| Valid rebasing | Verified primal point | Pass |
| Unverified evidence reference | Report explicitly disclaims authenticated authorization | Mechanical wording criterion passes |

This heterogeneous count is not accuracy or human repair benefit. No failed case
was excluded or retrospectively rescored.

## Confirmed report-construction bug

A separate read-only trace after evaluation confirmed that the four invalid
contracts are correctly rejected by `check_load_status_contract`, with these reasons:

- Unexplained status: model status lacks matching switching history.
- Omission: load records are missing, added, or ambiguously mapped.
- Stale hash: switching contract refers to a different source.
- Wrong allocation: nominal allocation changed for load 1/pd.

The subsequent report construction fails. When every initial stage dictionary has
string-valued fields, the stage collection becomes `Vector{Dict{String,String}}`.
Inserting the matched-model stage, whose reason is `nothing`, tries to convert that
value to `String` and throws a `MethodError`. The evaluation catches and records
`validation_unavailable`, but the useful source-contract rejection is obscured.
This is a report-schema/type bug, not evidence that the invalid contract passed or
that an infeasible model was certified feasible. It is the next implementation
priority: explicitly support nullable stage fields and exercise this path end to end.

The trace is recorded in `/tmp/nlpdiag-status-diagnosis.log`. It does not alter the
original reports, count, or frozen source files.

## Revision-label limitation

The selected source's bytes match their expected hash, but the ledger revision
label was changed from the independently prepared manifest's r1 to r0. The helper
requires a nonempty label; it has no authoritative label-to-source registry input.
Consequently the stale-label criterion fails. This is missing metadata verification,
not a hash failure or a demonstrated change in physical source data.

A future contract should either validate revision IDs against an explicit selected
mapping or clearly treat the label as an unvalidated annotation. It must not guess
which label is authoritative or imply that matching bytes authenticate a revision
or operator approval.

## Interpretation boundary

The unverified-evidence scenario passes only a mechanical wording/schema criterion:
the report says the event ledger is caller-selected and not authenticated
 authorization, and does not assert an `authorization_verified` field. Its returned
point is still mathematically verified within tolerance. This demonstrates the
separation of those claims, not that reviewers understand it or that the declared
switching is authorized. Human interpretation review remains **not run** because
no incidents or reviewers are available. The engineer-study preparation package
remains unchanged.

## Evidence and validation

- Protocol: `docs/status_provenance_validation_protocol.md`.
- Freeze: `docs/status_provenance_freeze.json`.
- Source records: `test/fixtures/status_provenance/`.
- Driver: `benchmarks/run_frozen_status_validation.jl`.
- Results: `work/frozen-status-provenance-validation/evaluation.json` and per-case
  inputs, contracts, and Markdown/JSON reports.
- Run log: `/tmp/nlpdiag-status-validation.log`.

All five freeze inventories and all nine input/contract hash pairs were independently
verified. Four harness integrity assertions passed, separately from the failed
capability gate. Local quality, proof-inventory scope, and whitespace checks passed.
Core source was unchanged; the last full-suite baseline remains 7,560 assertions
and was not rerun for this harness. Earlier 11/14 and 4/8 failures are preserved.
Any fixes belong to a labeled follow-up, not a revised version of this evaluation.
