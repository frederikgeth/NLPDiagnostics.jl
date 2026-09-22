# Declared load-status history

New work should use [Power diagnostics v2](power_diagnostics_v2.md), with a
separately selected revision manifest. The API below describes the historical
frozen implementation, whose revision label is not validated against a manifest.

This experimental follow-up allows explicitly documented load switching while
preserving nominal source demand. It does not authenticate operator authorization
or infer that switching occurred. Existing frozen implementations and failed
evaluations are unchanged.

```julia
include("benchmarks/power_repair_pilot/load_status_contract.jl")
using .LoadStatusContract
lineage = check_load_status_contract(data, reference, contract)
report = diagnose_with_load_status(pm, data, reference, contract)
```

`reference` remains a selected `SourceLoadReference` with an expected file hash.
The contract is an independently selected record with these fields:

```json
{
  "source_sha256": "EXPECTED_SOURCE_SHA256",
  "source_revision": "engineering-source-revision-id",
  "nominal_loads": {
    "3": {"bus": 6, "pd_mw": 100, "qd_mvar": 50}
  },
  "events": [
    {
      "event_id": "disconnect-3",
      "load_id": "3",
      "from": 1,
      "to": 0,
      "reason": "Reason for the declared disconnection",
      "evidence_ref": "Reference to the approved change record"
    }
  ]
}
```

The example is schematic: `nominal_loads` must contain every model load ID, not
only switched records. Never manufacture this baseline or its evidence references
from the suspect current model to make it pass. The synthetic test fixtures do
construct known baselines for testing; they are not real engineering authorizations.

## Rules

Every nominal record starts active. The ordered event ledger must use unique
nonempty event IDs, known load IDs, integer 0/1 statuses, nonempty reasons, and
nonempty evidence references. Every `from` value must equal the preceding state,
and every event must change state. Reconnection therefore requires a prior
disconnection and an explicit 0-to-1 event. The final state must equal the input's
load status. The contract's source hash must match the selected reference, whose
bytes are checked by the source reader; a nonempty revision label is also required.

All nominal records remain present when switched off. Added/deleted records,
changed bus mapping, and altered nominal MW/MVAr amounts are unavailable under
this contract. Per-record physical amounts must agree with the declared allocation,
and its per-bus sums must still agree with the selected nominal source table.
This prevents a switch event from excusing an omitted or zeroed nominal load.
The existing physical comparison tolerance and explicit rebase rules apply.

The ledger is validated for consistency, not authenticity. Its evidence references
are recorded but not fetched or verified. The source hash pins bytes, while its
revision label and load allocation remain caller-selected declarations. Source
records containing only aggregated bus loads do not independently establish a
particular allocation among split load IDs.

## Report and solver scope

Source comparison is explicitly labeled **nominal loads before declared switching**,
with nominal per-record values, event history, and disabled IDs retained. It must
not be interpreted as agreement of currently active demand with an all-active
source. The model still uses the actual final statuses.

Model matching remains independent. DC lines and other unsupported model features
remain unavailable even when switching provenance is consistent. No solver is
invoked on partial results. With both contracts satisfied, the unchanged island
and verified-solver path applies; status provenance cannot weaken its prerequisites.

## Tests and evidence

```sh
julia --startup-file=no --compiled-modules=no --project=benchmarks/environments/power_repair_pilot test/load_status_contracts.jl
```

The exposed case7 inactive record is tested with an explicitly synthetic disconnect
ledger. Tests cover a reconnect chain, unexplained statuses, omitted records,
changed allocation/bus mapping, duplicate event IDs, missing reasons, stale source
identity, strict status types, partial model scope, and supported clean acceptance.
Artifacts are under `work/load-status-followup/`. No real operator record is
asserted, and no frozen score is retrospectively revised. The engineer study remains
prepared, not run, pending incidents and participants.

The follow-up passes **28 assertions**, including evidence-snapshot independence
from later caller edits. An independent replay of the saved event chain reproduces
the declared inactive load IDs. The example report distinguishes nominal-source
consistency from the still-unavailable DC model contract. All four frozen evaluations
remain intact, and a supported clean control still reaches verified acceptance.
