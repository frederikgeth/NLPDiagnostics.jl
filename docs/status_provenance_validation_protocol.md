# Frozen status-provenance evaluation

This evaluation uses a new original synthetic two-bus fixture and separately
written physical reference allocation, model-load blueprint, and source manifest.
Those records are authored before constructing/checking models; the contract is
not generated from each mutated model. They are not independently authored by a
second person and are not real engineering evidence. No diagnostic outcomes inform
case selection or frozen expectations.

Freeze all current helpers, earlier freezes, this driver/protocol, and the four
fixture records before execution. Keep all failures and do not retune or replace
cases. Use existing defaults: absolute solver-contract tolerance 1e-6 and physical
source comparison tolerance 1e-8. Preserve all previous failed gates.

| Scenario | Frozen criterion |
| --- | --- |
| Baseline | Verified primal acceptance. |
| Reconnection | Ordered declared off/on events ending active; verified primal acceptance. |
| Undeclared disconnection | Status off without an event; source-contract unavailable. |
| Omitted nominal record | Delete a required load; source-contract unavailable. |
| Stale source hash | Ledger hash differs from selected source; source-contract unavailable. |
| Stale revision label | Ledger says r0 while the independently written manifest names r1; source-contract unavailable. |
| Wrong allocation | Keep aggregate demand but alter per-record nominal allocation; source-contract unavailable. |
| Valid rebase | Double base with consistent quantities/impedance changes and explicit target; verified primal acceptance. |
| Unverified evidence reference | Ledger consistency may pass, but report must explicitly disclaim authenticated authorization and must not assert an authorization_verified field. |

The revision-label criterion probes a desired provenance capability: the current
API receives the selected source hash but has no authoritative revision-registry
interface. A failure must be retained, not treated as a false mathematical
certificate or evidence that source bytes changed. The manifest is independent
truth evidence for this scenario, not silently supplied to the checker.

The final criterion is a mechanical wording/schema check, not proof that a human
will understand the distinction. Reports must distinguish nominal demand before
switching from active demand and must not present caller declarations as operator
authorization. Actual reviewer comprehension remains unmeasured because no
incidents/reviewers are available; the engineer study is prepared, not run.

Save transformed model data, selected contract, hashes, and Markdown/JSON reports
per scenario. Harness assertions check integrity, separately from the nine
capability criteria. Refuse to overwrite prior results. Cases become exposed
development data after this run; no retrospective score changes are allowed.
