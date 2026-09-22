# Pinned power-system repair pilot

From the repository root, with Julia 1.12.6:

```sh
julia --project=benchmarks/environments/power_repair_pilot -e 'using Pkg; Pkg.instantiate()'
julia --startup-file=no --project=benchmarks/environments/power_repair_pilot benchmarks/run_power_repair_pilot.jl
julia --startup-file=no --project=benchmarks/environments/power_repair_pilot test/power_repair_physics.jl
julia --startup-file=no --project=benchmarks/environments/power_repair_pilot test/power_repair_pilot_contracts.jl
```

The integration test also executes the full pilot. Default output is
`work/power-repair-pilot`; pass another output directory as the sole argument.
Reruns overwrite that directory's pilot artifacts. Dependency installation needs
network access unless packages/artifacts are already cached. For sandboxed runs,
a writable first entry in `JULIA_DEPOT_PATH` can precede an existing package cache.
The recorded development run disabled compiled modules; timings include JIT
compilation and are not representative service latency measurements.

`Manifest.toml` pins dependencies; its sole path dependency is NLPDiagnostics at
`../../..`, the current repository. Each run saves source SHA-256 hashes so local
library changes are identifiable. Replay requires the corresponding source files,
not just this manifest. Do not resolve or update the environment during a comparison.
The runner requires Julia 1.12.6 and this active project.

The fixture is an unchanged copy of `test/data/matpower/case3.m` from PowerModels
0.21.6 (package tree `863958f4515bed67df261d694a8b414f8c603af2`). It is stored as
`test/fixtures/power_repair_case3.m`, with the upstream license alongside it.
SHA-256: `d2173e913ab554dd4fe6cfdcf17bcc5d3f882b769bcdfc37470cb273f0df507b`.
PowerModels parsing selects bus 1 as the reference because the raw fixture has
none. The omitted-reference variant changes model construction after parsing.

Artifacts contain the raw fixture, parsed original/modified/repaired data, starts,
patches, raw reports, ranked findings, solver logs/statuses, JuMP feasibility
reports, independent physical residuals, runtime/allocation observations, package
versions, and source hashes. Copies of the project and manifest in the output
are provenance snapshots; run using the environment in the repository because
its relative path dependency is resolved there. Unused nonfinite MATPOWER
extension values are serialized as `nonfinite_literal` objects, not JSON numbers.
Replay parses the raw MATPOWER fixture rather than treating those objects as numbers.

The checker covers this fixture's AC branch admittances, bus balances, shunts,
voltage/generator/branch limits, reference angles, and HVDC terminal limits/losses.
It explicitly refuses storage and switches. This is not a general validation
certificate for all PowerModels formulations, optimality, or operational security.

The `power-repair-priority-v1` ranking policy sorts error findings by recognized
code/basis pairs: proven contradictory bounds, direct initialization evidence,
other errors, then numerical feasibility residuals. Findings within each group
use deterministic code/identity/evidence ordering. Reports preserve the alphabetical
baseline, the prioritized list, and per-rank reasons; summaries score both lists
against the same incident truth. No findings, affected identities, or proof bases
are changed. Informational and warning findings remain in the raw reports.
This policy was developed using these cases and is not validated on held-out
incidents. A high priority is a review suggestion, not a causal certificate.

A separate `connected-acp-uniform-shift-v1` experiment writes
`gauge_diagnostics.json` for every variant. It checks the same explicit uniform
angle candidate against the local Jacobian, using public scalar angle indices
and connected ACP topology. It also saves the adapter's automatic candidate
count and the data-level reference-bus report. The candidate does not depend on
the incident label or on whether metadata declares a reference bus. Missing
starts and unsupported topology/formulations are unavailable, with reasons.
A mode outside the free-coordinate scope is reported separately from a tested
mode that was not observed. An observed mode is local numerical evidence, not
proof of global symmetry or a missing reference equation. Gauge findings are
not added to the priority-policy score, so paired ranking comparisons stay fixed.

The separate `pilot-load-lineage-v1` workflow reads the hash-pinned fixture's
numeric bus table independently of PowerModels' per-unit conversion. It records
source rows, bus IDs, MW/MVAr declarations, and source baseMVA in
`source_load_ledger.json`. Every variant receives the same source ledger, with
no incident label or inverse patch. The checker verifies the ledger contents
against the pinned source before comparing mapped load P/Q values after one
division by baseMVA. The numerical consistency tolerance is
`1e-12 + 1e-10 * abs(expected_per_unit)` for each field.

Per-variant `load_lineage.json` reports expected/observed values, source rows,
residuals, and observed-to-expected ratios. A mismatch means disagreement with
the recorded source; it does not prove a particular unit bug or determine whether
an operator intended a load change. Intentional changes require updated source
lineage. Missing mappings, split loads, changed power bases/status, nonfinite
values, unsupported units, or an altered ledger yield unavailable results.
The reader supports only this pinned numeric fixture, not arbitrary MATPOWER
programs. This source-aware workflow has more input information than the generic
model-only diagnostics and is therefore reported separately from their ranking
score. Repaired load lineage is also checked against the original source.

For the frozen next-network evaluation, run:

```sh
julia --startup-file=no --project=benchmarks/environments/power_repair_pilot test/power_repair_case9_validation.jl
```

`docs/power_repair_case9_freeze.json` fixes 47 source, environment, fixture, and
test files by SHA-256, plus the selection rules and acceptance criteria. The
runner checks these hashes before and after execution. It first runs all case3
contracts, then applies the same perturbations and diagnostic policies to the
vendored PowerModels 0.21.6 case9 fixture. Its upstream license is stored alongside
the fixture. Case9 SHA-256 is
`a82d8af848130edcba2161c10ea8b0102e89685c7315f7359001f2b7df8742dc`.

The frozen load-lineage policy is case3-only, so case9 source checks are explicitly
unavailable. They are not supplied with case3 source values. The new network uses
the same injected incident families; it is not a blind incident study. Results
and each acceptance criterion go to `work/power-repair-case9-validation/`.
A missed criterion is an evaluation result, not a reason to retune or replace
the case. Changes to frozen files require a separately identified evaluation;
do not silently refresh this plan and call the result the original frozen run.
The hashes verify matching files, not an external preregistration timestamp;
retain the matching checkout for replay.

A separate frozen incident-family test uses case14:

```sh
julia --startup-file=no --project=benchmarks/environments/power_repair_pilot test/power_repair_case14_capacity.jl
```

This first reruns the existing case3/case9 contracts, then compares clean,
aggregate-capacity-shortage with inherited starts, and the same shortage with
active generator starts reset to zero. Every active generator gets `pmax=0`
and `pmin=min(original pmin,0)`. An independent exact capacity witness checks
closed passive ACP assumptions before asserting demand exceeds available power.
It is adjudication evidence and is never supplied to the diagnostics. Unsupported
witness assumptions stop the evaluation rather than silently proving a shortage.

`docs/power_repair_case14_freeze.json` pins 50 files and six criteria before the
case14 run. The prior case9 freeze is preserved. Artifacts are written to
`work/power-repair-case14-capacity/`. A missing static error on the bounded-start
shortage is a recorded diagnostic miss; a static error, if present, is only an
alert metric, not automatic root-cause localization. Solver failure alone is
not counted as an independently checked physical violation. This is a deliberately
severe synthetic capacity loss, not a measured field outage or human repair study.
The case14 fixture comes from PowerModels 0.21.6 with its license alongside it;
SHA-256 is `85e4969b9e7dcbe62689819dce8fa8a2dd8c7d5bb489de9323a28694e42c0090`.

The post-evaluation capacity preflight is a separate experimental data check:

```sh
julia --startup-file=no --project=benchmarks/environments/power_repair_pilot test/capacity_preflight_followup.jl
```

This needs the saved case14 evaluation artifacts. It preserves and verifies the
old freeze, writes `work/capacity-preflight-followup/summary.json`, and retains the
original failed acceptance result. The reusable helper is
`benchmarks/power_repair_pilot/capacity_preflight.jl`:

```julia
include("benchmarks/power_repair_pilot/capacity_preflight.jl")
using .PowerCapacityPreflight
result = capacity_preflight(data; contract=:closed_acp_fixed_load)
```

The caller must declare standard closed ACP balance equations, fixed unsheddable
loads, and complete source data. The helper checks supported active components,
bus references, finite quantities, consistent generator limits, nonnegative active
loads/conductance, and passive finite branch/transformer parameters. DC, storage,
switch, and candidate-branch collections are unsupported. Exact rational totals
produce `capacity_shortage` only when demand exceeds the aggregate active-power
upper bound. `not_ruled_out` does not certify feasibility, island adequacy,
reactive/voltage support, or security. Unsupported/invalid premises produce
`unavailable` with a reason. Backend equations are not inspected, so the result
is conditional on the declared contract. This is not yet a stable library API.

The experimental source-to-backend matcher is exercised with:

```sh
julia --startup-file=no --project=benchmarks/environments/power_repair_pilot test/capacity_model_contracts.jl
```

It uses exposed case14 artifacts and writes
`work/capacity-model-contract-followup/summary.json`. To use it directly:

```julia
include("benchmarks/power_repair_pilot/capacity_model_contract.jl")
using .CapacityModelContract
result = checked_capacity_preflight(pm, data)
```

The helper rebuilds standard `PowerModels.ACPPowerModel`/`build_opf` constraints
from the supplied data, then compares the complete supported scalar-row multiset
and named variable set against the actual JuMP backend. Exact numeric keys avoid
string-display collisions; row order and affine-term order do not matter.
Duplicate/empty variable names, missing/changed rows, unsupported functions/sets,
opaque NLP blocks, registered callbacks, or unsupported source precision produce
unavailable results. Starts and objective are excluded from this feasibility-scope
comparison. Equivalent formulations with different supported representations may
also be unavailable: this is a conservative matcher, not an equivalence prover.

A match verifies agreement with the standard Float64 builder, conditional on its
semantics. It does not certify passivity of rounded expanded equations or upgrade
the data-level capacity condition into an unconditional backend-infeasibility
certificate. It also cannot verify real-world source intent. Both original frozen
evaluations remain unchanged; this matcher is post-evaluation experimental work.

A separate experimental checker now derives a sufficient infeasibility condition
from the encoded rows and explicit bounds, including a rational lower bound on
losses allowed by rounded coefficients:

```julia
include("benchmarks/power_repair_pilot/encoded_capacity_certificate.jl")
using .EncodedCapacityCertificate
result = encoded_capacity_certificate(pm, data)
```

Its statuses are `certified_infeasible`, `not_ruled_out`, and `unavailable`.
Certification is for exact real satisfaction, with zero feasibility tolerance;
it is not a certificate about an optimizer's numerical stopping tolerances or
real-world input intent. See [the proof and scope](../../../docs/encoded_capacity_certificate.md).
Run the standalone contracts with:

```sh
julia --startup-file=no --compiled-modules=no --project=benchmarks/environments/power_repair_pilot test/encoded_capacity_certificate_contracts.jl
```

They use checked-in exposed fixtures and write
`work/encoded-capacity-followup/summary.json`. The original frozen evaluations
remain unchanged. This checker is outside the stable diagnostics API.

The follow-up `tolerant_capacity_certificate` accounts for caller-declared
absolute unscaled true-residual tolerances, generator bound relaxation, and
voltage bound relaxation. See [the contract and derivation](../../../docs/tolerant_capacity_certificate.md).
It does not infer these bounds from solver settings. Run its standalone contracts:

```sh
julia --startup-file=no --compiled-modules=no --project=benchmarks/environments/power_repair_pilot test/tolerant_capacity_certificate_contracts.jl
```

Results are written to `work/tolerant-capacity-followup/summary.json`.

The experimental `solve_and_verify` follow-up defines acceptance through a
rational enclosure check of every supported original constraint at the returned
point. It also records explicit solver settings and the tolerance-aware capacity
certificate. See [verified acceptance](../../../docs/verified_solver_acceptance.md).
This is a separate workflow; the frozen pilot runner is unchanged.

```sh
julia --startup-file=no --compiled-modules=no --project=benchmarks/environments/power_repair_pilot test/verified_solver_acceptance_contracts.jl
```

Its artifacts are in `work/verified-solver-acceptance/summary.json`.

The complete workflow's first frozen transfer evaluation uses public case24 and
case30 fixtures, with seven variants each. The overall acceptance gate failed
(11/14 criteria met); see [results and limitations](../../../docs/power_workflow_validation_results.md).
The frozen driver is:

```sh
julia --startup-file=no --compiled-modules=no --project=benchmarks/environments/power_repair_pilot benchmarks/run_frozen_power_validation.jl
```

It checks the freeze and refuses to overwrite nonempty
`work/frozen-power-workflow-validation/` artifacts. Reproduction should use a
separate checkout with the frozen inputs and an empty output directory.

A post-evaluation island follow-up verifies rebuilt island rows as subsets of the
original backend and checks constant contradictions before aggregate capacity.
`solve_with_island_preflight` rejects certified contradictions before solving and
otherwise delegates to the existing verified workflow. See [scope and proof](../../../docs/island_capacity_followup.md).

```sh
julia --startup-file=no --compiled-modules=no --project=benchmarks/environments/power_repair_pilot test/island_capacity_contracts.jl
```

Artifacts are in `work/island-capacity-followup/`; the frozen 11/14 result is unchanged.

The source-load follow-up compares physical per-bus MW/MVAr totals with an
explicitly selected, hash-pinned numeric source table before island/solver checks.
Declared rebasing and equivalent load splitting are supported; this is load
provenance, not a full equipment-unit audit. See [source contract and limits](../../../docs/source_load_followup.md).

```sh
julia --startup-file=no --compiled-modules=no --project=benchmarks/environments/power_repair_pilot test/source_load_contracts.jl
```

Artifacts are in `work/source-load-followup/`. The original frozen score is unchanged.

A consolidated report now exposes the full source/island/verified-solver workflow
through `benchmarks/run_power_diagnostic_report.jl`, producing readable Markdown
and full JSON evidence. See [the entry point and outcome guide](../../../docs/power_diagnostic_report.md).
It distinguishes unattempted stages from unavailable analyses and preserves the
original failed evaluation. No stable API or automated repair is introduced.

The integrated report's subsequent frozen case6/case7 topology/source evaluation
met 4/8 criteria and failed its gate. See [results](../../../docs/integrated_report_validation_results.md).
Run `benchmarks/run_frozen_report_validation.jl` only in a separate checkout with
matching frozen inputs and an empty output directory; the original evidence is
preserved. The engineer-study package is prepared under
`studies/power_diagnostic_pilot/`, but no human study has been run.

The current post-evaluation entry point for partial analyses is
`benchmarks/run_partial_power_report.jl`. It runs source comparison independently
of model-scope matching, preserving useful results and separate failure reasons
without weakening solver acceptance. See [partial diagnostics](../../../docs/partial_power_diagnostics.md).
Earlier drivers remain frozen for reproducibility. Case7's inactive-load source
limitation is still explicit; DC support has not been added.

An explicit nominal-allocation and switching-history contract is available through
`LoadStatusContract.check_load_status_contract` and `diagnose_with_load_status`.
It retains inactive nominal records and validates ordered disconnect/reconnect
steps without authenticating their evidence references. See [schema and scope](../../../docs/load_status_contract.md).
Run `test/load_status_contracts.jl` in this pinned environment; examples are saved
under `work/load-status-followup/`. The frozen scores and DC scope are unchanged.

The frozen status-provenance evaluation met 4/9 criteria and failed its gate.
It exposed a nullable-field report-construction bug and unvalidated revision labels.
See [results and retained evidence](../../../docs/status_provenance_validation_results.md).
`benchmarks/run_frozen_status_validation.jl` refuses to overwrite the original run;
reproduction requires matching frozen inputs and an empty output directory.
