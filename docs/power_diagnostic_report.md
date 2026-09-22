# Consolidated experimental power diagnostic report

This page describes the historical frozen facade. New work should use
[Power diagnostics v2](power_diagnostics_v2.md), which fixes nullable-stage
reporting and supports explicit revision selection.

The report provides one entry point to source-load comparison, island preflight,
and verified solver acceptance. It writes a readable `report.md` beside a complete
`report.json`. This is an experimental facade over the existing checks; it adds
no new mathematical detection capability and does not revise the frozen 11/14 result.

## Run on saved model data

Use the committed pinned pilot environment:

```sh
julia --startup-file=no --compiled-modules=no --project=benchmarks/environments/power_repair_pilot benchmarks/run_power_diagnostic_report.jl input.json source.m EXPECTED_SOURCE_SHA256 report-directory
```

Replace the hash with the expected identity of an independently selected source
record. The input must be parsed PowerModels JSON, not a raw MATPOWER file. A fifth
argument declares a target power base, for example `200`, when the input was
consistently rebased. The command refuses to overwrite a nonempty report directory.
It records the input hash, source hash when verified, and reporter implementation
hash. Solver invocation remains conditional on the earlier checks passing.

For an existing model:

```julia
include("benchmarks/power_repair_pilot/power_diagnostic_report.jl")
using .PowerDiagnosticReport
reference = PowerDiagnosticReport.S.SourceLoadReference(source_path, expected_hash)
report = diagnose_power_model(pm, data, reference; rebase_to=nothing)
text = markdown_report(report)
```

`summarize_workflow(result)` formats an existing source-aware workflow result
without solving again. It is a formatter of recorded evidence, not an independent
proof checker. An acceptance label without the required available source, island,
solver, and returned-point evidence is reported as `invalid_evidence`.

## Read the outcomes correctly

| Report outcome | Meaning |
| --- | --- |
| Source mismatch | Per-bus loads disagree with the selected source; this is not mathematical infeasibility or identification of a specific conversion bug. |
| Certified contradiction | A verified subset cannot satisfy the declared absolute tolerances. The affected island and proof basis are listed. |
| Returned point verified | The point satisfies the tested primal tolerance contract and the solver reported local success. No exact-feasibility, optimality, or security claim follows. |
| Returned point violated | The returned point violates a checked constraint. This alone does not prove the model infeasible. |
| Inconclusive/unavailable | No acceptance claim; inspect the stage reason and retained evidence. |
| Not run | An earlier stage stopped the workflow. This is neither a successful check nor an unavailable attempted analysis. |

The Markdown report shows stage outcomes/reasons, affected buses, approximate
source/model loads and differences, and a suggested inspection step. Numeric
values displayed there use eight significant digits; JSON retains exact rational
values, tolerances, full row enclosures, proof evidence, and solver status/settings.
For threshold decisions, use the exact evidence rather than the rounded display.

Load provenance still excludes generator/branch-unit verification and does not
authenticate the source's engineering intent. The report does not automatically
repair or update input models. This interface remains outside the stable API.

## Validation and examples

```sh
julia --startup-file=no --compiled-modules=no --project=benchmarks/environments/power_repair_pilot test/power_diagnostic_report_contracts.jl
```

Contracts exercise existing accepted and source-mismatch evidence, missing or
contradictory acceptance evidence, not-run versus unavailable stages, and an
end-to-end island contradiction. The standalone CLI is also exercised on the
exposed case30 unit-corruption input. Example outputs:

- `work/power-diagnostic-report/report.md`: isolated-load contradiction.
- `work/power-diagnostic-source-report/report.md`: source mismatch.

All three original evaluation freezes remain unchanged. The examples are
post-evaluation development cases, not fresh validation or measured repair benefit.
