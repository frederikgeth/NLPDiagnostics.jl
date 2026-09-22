# Independent partial diagnostics

The current CLI uses [Power diagnostics v2](power_diagnostics_v2.md). The module
example below is the historical frozen implementation, retained for replay.

This post-evaluation facade runs source-load comparison and model-contract matching
independently. A model-scope refusal no longer prevents the source check from being
attempted. The frozen implementations and their 11/14 and 4/8 failures are unchanged.

```julia
include("benchmarks/power_repair_pilot/partial_power_diagnostics.jl")
using .PartialPowerDiagnostics
report = diagnose_partial(pm, data, reference)
text = markdown_partial(report)
```

The reference is the existing hash-pinned `SourceLoadReference`. Rebase declarations
and tolerances have the same meaning as in the source-aware workflow. Alternatively:

```sh
julia --startup-file=no --compiled-modules=no --project=benchmarks/environments/power_repair_pilot benchmarks/run_partial_power_report.jl input.json source.m EXPECTED_SOURCE_SHA256 output-directory
```

An optional fifth argument declares the target base. The new driver preserves
model-build errors and still attempts the source comparison against supplied data.
It refuses to overwrite nonempty output. The old driver remains frozen for replay.

## Acceptance and interpretation

- Both contracts available and source-consistent: invoke the unchanged island and
  verified-solver workflow. No prerequisite or tolerance is weakened.
- Model matched, source mismatch/unavailable: stop as before, with no solver call.
- Model unavailable: retain the independent source result and return `partial_results`.
  The model-contract reason and source reason are separately reported. No solver
  workflow is invoked, even if source comparison passes.

When model correspondence is unavailable, source findings concern **supplied data
only**, not a verified representation of the actual backend. The report marks
`model_binding_verified=false` and labels such findings accordingly. A source
mismatch in this state is not a model-infeasibility proof. Unknown source contracts
are not guessed or relaxed merely to produce a useful-looking result.

On the exposed case7 probes, DC lines still make model matching unavailable. The
source check is now attempted: it independently refuses inactive load records for
clean/reactive/zero-capacity inputs, and identifies the changed hash in the stale-
reference probe. Thus this change exposes two independent scope limitations; it
does not claim that case7's unit error has been diagnosed.

A separate controlled scope probe uses otherwise supported case6 load data with a
DC-collection marker and no model. Its source corruption is reported, explicitly
unbound to any backend. The marker is a scope test, not a valid DC-equipment model.
A supported clean case6 still reaches verified acceptance, and its unit mutation
is still stopped before solving.

Run `test/partial_power_diagnostics_contracts.jl` in the pinned project. Evidence
is saved under `work/partial-power-diagnostics/`. This is experimental development
on exposed cases, not a rescore or fresh validation. The engineer study remains
prepared, not run; actual incidents and reviewers are still unavailable.

Validation: **41 targeted assertions passed**, including all four freeze guards.
The standalone CLI also produced a report retaining both the unsupported-DC reason
and the stale-source hash reason. Its Markdown and adjacent JSON were inspected.
The original failed gates are preserved, and no human study has been performed.
