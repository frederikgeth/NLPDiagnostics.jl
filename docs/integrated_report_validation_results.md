# Integrated report validation: 4/8 criteria met, gate failed

The complete report workflow was frozen across 73 files before eight source-backed
probes on case6 and case7_tplgy. No inputs, implementation, or acceptance criteria
were changed after outcomes. All eight reports and transformed inputs are retained.

| Predetermined probe | case6 | case7_tplgy |
| --- | --- | --- |
| Clean point accepted | Pass | Fail: model scope unavailable |
| Reactive-load unit corruption reported | Pass | Fail: source check not run |
| Stale source hash refused explicitly | Pass | Fail: source check not run |
| Zero capacity certified | Pass | Fail: model scope unavailable |

Case6 returned the expected integrated outcomes: accepted primal point, rejected
source mismatch, source-contract unavailable for changed bytes, and rejected island
contradiction. Its fixture explicitly replicates case3 topology, so this is useful
multi-component integration coverage, not independent network evidence.

Every case7_tplgy probe stopped at `unsupported device collection: dcline` in the
initial model contract. That conservative refusal is consistent with the current
closed-ACP scope. However, it blocks downstream source checks even when those might
have independently checkable premises. No claim is made that those checks would
pass on case7: component-status preprocessing may create further provenance issues.
The parser warnings and full evidence are retained. This is a workflow coverage
failure, not an incorrect mathematical certificate.

The next architectural priority is to allow independent analyses to run where their
own premises hold, while keeping unavailable model checks from authorizing solver
acceptance. Do not simply bypass the DC-line refusal or claim DC support without
appropriate equations and proofs. Preserve partial results and explicit stage scope.

The 4/8 count is a heterogeneous acceptance gate, not accuracy or repair benefit.
These are public software fixtures with constructed probes. The original 11/14
failure and earlier evaluations remain unchanged. These fixtures are now exposed
workflow-development cases, and follow-up tuning must not revise this score.

## Evidence

- Freeze: `docs/integrated_report_freeze.json` (73 file hashes).
- Protocol: `docs/integrated_report_validation_protocol.md`.
- Driver: `benchmarks/run_frozen_report_validation.jl`.
- Results: `work/frozen-integrated-report-validation/evaluation.json` and eight
  per-probe Markdown/JSON reports with input files.
- Log: `/tmp/nlpdiag-integrated-validation.log`.

All four freeze inventories and all eight input hashes were independently verified.
Five harness integrity assertions passed, separately from the failed acceptance
gate. Local quality, proof-inventory scope, and whitespace checks passed. Core
source was unchanged; the last full-suite baseline remains 7,560 assertions and was
not rerun for this harness.

## Engineer study status

The user confirmed that no incident records or reviewers are currently available.
The study is **prepared, not run**. The package at
`studies/power_diagnostic_pilot/` contains a protocol, incident template, reviewer
form, and adjudication form. It requires equal source information in baseline and
report conditions, independent scoring keys, retained failures/time limits, and
explicit separation of synthetic coverage from real repair benefit. No recruitment,
participant measurements, or efficacy claims have occurred.
