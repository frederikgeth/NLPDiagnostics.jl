# Power diagnostics, version 2

The current experimental entry point is `benchmarks/power_diagnostics_v2.jl`.
It consolidates independent source/model checks, optional switching provenance,
island capacity certificates, and verified returned-point acceptance. The
mathematical checkers remain unchanged. This is outside `NLPDiagnostics.Stable`.

```julia
include("benchmarks/power_diagnostics_v2.jl")
using .PowerDiagnosticsV2

reference = SourceLoadReference("selected_source.m", expected_source_sha256)
report = diagnose_power_model(pm, data, reference)
println(markdown_report(report))

# For a switching ledger, select the expected revision independently of the
# submitted contract. Do not build this selection from that contract's label.
revision = SourceRevision(selected_manifest)
report = diagnose_with_load_status(pm, data, reference, contract; revision)
```

`selected_manifest` has `source_sha256` and `current_revision` string fields.
The expected hash must match the selected source reference, and the contract's
`source_revision` must match the selected current revision. Missing or conflicting
selection produces `source_contract_unavailable` before a solver is invoked.
The existing source-byte, nominal-allocation, switching-chain, and backend checks
still apply. Matching a caller-selected manifest does not authenticate source
intent, an operator, or the ledger's evidence references.

The report schema is `power-diagnostic-report-v2`. Every stage has a string `name`,
a string `status`, and a nullable string `reason`, regardless of the outcomes in
the current run. Invalid source contracts therefore retain their rejection reason
even when a matched model has a null reason. Model-scope failures preserve
independent source results with `supplied_data_only` binding. Neither a partial
report nor a revision match bypasses the original acceptance prerequisites.

Run the CLI using the pinned pilot environment:

```sh
julia --startup-file=no --project=benchmarks/environments/power_repair_pilot \
  benchmarks/run_power_diagnostics_v2.jl \
  input.json source.m EXPECTED_SHA256 output-directory

# Switching provenance:
julia --startup-file=no --project=benchmarks/environments/power_repair_pilot \
  benchmarks/run_power_diagnostics_v2.jl \
  input.json source.m EXPECTED_SHA256 output-directory contract.json revision-manifest.json
```

The switching command accepts an optional final declared rebase value. The
existing `run_partial_power_report.jl` CLI also uses version 2 and retains its
optional rebase argument for source-only reports. Outputs are Markdown and JSON;
nonempty output directories are refused. Input, contract, and selected manifest
file hashes are recorded where applicable.

## Validation and historical evidence

```sh
julia --startup-file=no --project=benchmarks/environments/power_repair_pilot \
  test/power_workflow_runtests.jl
```

This lane builds models from checked-in fixtures and uses temporary directories
for CLI outputs. It does not require saved `work/` artifacts. It exercises the
existing encoded-capacity, absolute-tolerance, and rational point-verification
contracts with their outputs redirected into temporary directories, together with
old failure cases end to end, missing/mismatched revision selection, partial
source results, clean acceptance, reconnection, rebasing, capacity rejection,
JSON/Markdown output, and overwrite protection. It also checks all five original
freeze inventories. CI runs it separately from the generic library suite.

The original modules in `benchmarks/power_repair_pilot/` and frozen drivers remain
historical replay implementations, including their documented reporting defect.
Their 11/14, 4/8, and 4/9 failed evaluations are unchanged. Passing version 2
regressions on these exposed fixtures is development evidence, not a rescored
evaluation or held-out result.

The next application milestone requires separately prepared source-backed
incidents and a frozen evaluation of the new version. Report localization,
actionable false warnings, abstentions, and diagnostic overhead. Engineer repair
time requires actual participants and incident records; the study remains
prepared, not run. DC support, equipment-wide provenance, opaque callback
identity, and general operational-security claims remain outside this workflow.

Use the [incident intake and freeze workflow](../studies/power_diagnostic_pilot/intake/README.md)
to check independently prepared records and preserve their materials, evaluation
plan, and workflow bytes before generating reports. The empty templates cannot
be frozen. Intake validation is preparation, not an evaluation result.
