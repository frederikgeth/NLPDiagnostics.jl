# Power-system repair pilot protocol

Status: development harness executed, 11 September 2026. The five variants now
run in `benchmarks/run_power_repair_pilot.jl` with a dedicated pinned environment
and independent AC/DC physical checks. See [development results](power_system_repair_pilot_results.md)
and the [run instructions](../benchmarks/environments/power_repair_pilot/README.md).
Scripted inverse patches measure harness recovery only; human repair benefit,
held-out transfer, and operational effectiveness remain unmeasured.

## First runnable slice

The implementation uses the vendored PowerModels 0.21.6 ACP `case3.m` fixture
(three AC buses plus one HVDC link). Before generating variants, pin the package versions,
input-file SHA-256, model construction options, solver settings, units, and
baseline feasibility checks. Do not assume that a file path pins its contents.
This small development case is for checking the harness, not measuring transfer.

| Variant | Deliberate change | Independent truth and repair check |
|---|---|---|
| Clean control | None | Independently evaluate power balance, voltage and equipment limits at the accepted baseline point. Record actionable warnings, including incorrect ones. |
| Voltage-bound contradiction | Set a selected bus lower voltage bound above its upper bound | Compare original bus limits with generated bounds; restore the original bound and verify the model data match the baseline. |
| Missing angle reference | Remove the reference-angle fixing in the supported formulation | Verify graph connectivity and demonstrate invariance under a uniform angle shift; restore exactly the original reference. Do not call gauge freedom physical infeasibility. |
| Invalid voltage start | Place one initial voltage outside its declared bound | Compare the supplied start with the declared bound independently; repair only the start, keeping every physical parameter and constraint unchanged. |
| Inconsistent power units | Convert one load without the corresponding unit/base conversion | Verify the raw datum and base-unit conversion against the pinned baseline; restore it. A solver may successfully solve the wrong physical problem. Abstention is preferable to an invented diagnosis. |

Keep the defect site and repair metadata hidden from diagnostic input. Save
original, modified, and repaired data plus exact patches. A repaired solve counts
only when the original physical constraints and units are independently checked.
For a gauge repair, compare angle differences and physical flows, not absolute
angles. Do not require identical local objective values as a universal repair
criterion in a nonconvex problem; report objective and residual differences.

## Evaluation record

Each record needs: network hash, incident-family ID, clean/defective truth,
physical component and typed source-row IDs, input/model/solver versions,
point provenance, diagnostic settings, ordered findings, elapsed times,
proposed patch, applied patch, independent physical checks, and outcome.
Classify outcomes separately as correct diagnosis, incorrect diagnosis,
abstention, unavailable analysis, unsuccessful repair, and verified repair.

Use solver logs plus JuMP feasibility reporting as the baseline workflow.
Both workflows receive the same data and starts. Record Julia loading/compilation
separately from warmed diagnostic runtime. Counterbalance workflow order in a
human repair study; an automated scripted inverse patch measures harness
correctness and cannot establish human time-to-repair benefit.

Report counts with explicit denominators:

- Localization among the first three findings / all eligible defective cases;
  abstentions remain in the denominator. Also report conditional localization
  among cases with an actionable diagnosis.
- Clean cases with any false actionable warning / all clean cases, plus the
  total number of false actionable warnings.
- Abstentions and unavailable analyses / all attempted cases, separately.
- Verified repairs / all defective cases; show failed and unattempted repairs.
- Time to verified repair with failures/timeouts retained, not discarded from
  averages. Measure human repair time only in an actual observed repair study.
- Diagnostic elapsed time and memory alongside the baseline workflow cost.

This development slice is deterministic coverage; do not interpret its counts
as population error rates or manufacture confidence intervals from repeated
solver runs on the same incident.

## Transfer and release gate

Select and freeze whole unseen networks and at least one unseen incident family
before tuning report ranking. Require both balanced and unbalanced formulations;
verify phase/neutral and unit conventions explicitly when selecting the latter.
The existing BMOPF feeder artifacts are candidates for integration, not automatic
held-out cases: prior use in development must be recorded. Acquire externally
reported incidents with independently documented intended behavior before
claiming real-world effectiveness.

First milestone: all development variants execute with independent truth and
repair checks and complete outcome records. Then predeclare acceptance thresholds
for false actionable warnings, localization, repair benefit, and overhead before
running held-out evaluation. No effectiveness claim follows merely from a solver
success status or an increase in the number of findings.
