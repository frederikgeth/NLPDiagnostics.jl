# Power-system repair pilot: development results

The first five-variant run completed on 11 September 2026. It establishes an
executable evidence path from injected incident to independently checked scripted
repair. It does **not** establish autonomous diagnosis, human repair benefit,
held-out generalization, or production readiness.

The environment pins Julia 1.12.6, PowerModels 0.21.6, JuMP 1.31.1, Ipopt 1.15.0,
MOI 1.52.0, and JSON 1.6.1. The three-bus fixture has three AC branches and one
HVDC link. See the [environment and fixture provenance](../benchmarks/environments/power_repair_pilot/README.md).
Baseline and repaired solutions satisfy the independent checks to `1e-6` p.u.
or radians; the largest baseline residual is approximately `1.10e-8`.

## Initial outcomes before tolerance-aware severity

Diagnostics run before solving each modified model. Static and initialization
checks see only its backend and starts; defect labels and inverse patches are
kept out of diagnostic input. Numerical degeneracy and component-rank checks
are disabled in this first slice. Error-level findings are ranked by code then
affected identities; warnings and informational findings remain advisory.
This deliberately simple ordering is a baseline, not a validated ranking policy.

| Variant | Error-level findings | Explicit localization rank | Modified solve | Independent interpretation |
|---|---:|---:|---|---|
| Clean | 1 | Not applicable | Locally solved | Passes intended physical checks |
| Contradictory voltage bounds | 3 | 2 | Invalid model | Returned point fails modified bounds |
| Omitted reference equation | 1 | None credited | Locally solved | Connected AC graph admits a uniform angle shift; physical flows stay unchanged |
| Out-of-bounds voltage start | 10 | 10 | Locally solved | Solver recovers; direct start diagnosis is buried beneath residual findings |
| Second per-unit conversion of active load | 2 | None credited | Locally solved | Passes altered model, fails intended network with **1.089 p.u.** active-power imbalance |

The scored top-three localization count is **1/4** injected defects. Direct
localization occurs somewhere in the list for **2/4**. No explicit unit or gauge
classifier is scored in this slice: their expected-code lists are empty, and
generic residuals receive no root-cause credit. These are coverage gaps under
this configuration, not evidence that every available library mode fails.
There are **0/5** empty error lists and **0/5** unavailable analyses.
Stage exceptions are recorded as unavailable, separately from abstention.

The clean case's one error-level finding reports exact bound excursions near
`1e-8` (and a tiny reference-angle excursion). These are real exact inequalities,
not disproved mathematical findings. JuMP and the physical checker accept the
point at `1e-6`. Therefore this is an **actionability/tolerance mismatch**, not a
measured rate of false mathematical claims. All five starts inherit the same
baseline numerical excursions; this shared artifact is retained and disclosed.

All **4/4** scripted inverse patches restore original data and starts and pass
independent physical checks after rebuilding and solving. The harness supplies
the inverse patches from known injected truth; the diagnostics propose none.
Human repair time is null. Even an invalid-model solver result may contain
primal values, so physical residuals and termination status are reported separately.
Gauge evidence includes invariance under a uniform 0.3-radian shift and failure
of that shifted point against the original reference equation.

## Follow-up: tolerance-aware severity, 11 September 2026

The same pinned fixture, starts, solver settings, diagnostic configuration, and
ranking policy were rerun after changing initialization bound severity. Exact
coordinate excursions at or below `feasibility_tolerance` retain their proof
evidence but become informational. Larger excursions remain errors; separate
domain errors are unaffected. Threshold comparisons use exact represented values.

| Variant | Error-level findings after change | Explicit localization rank |
|---|---:|---:|
| Clean | 0 | Not applicable |
| Contradictory voltage bounds | 2 | 2 |
| Omitted reference equation | 0 | None credited |
| Out-of-bounds voltage start | 10 | 10 |
| Second per-unit conversion of active load | 1 | None credited |

The clean case retains its exact bound finding as informational. Top-three
localization remains **1/4**, scripted verified repairs **4/4**, and unavailable
analyses **0/5**. Empty error lists are now **2/5**, comprising the clean control
and the omitted-reference variant; the latter remains an unresolved detection
gap. This change removes the observed reporting mismatch without improving the
localization metric.

## Follow-up: explicit priority policy, 11 September 2026

The pilot now saves two orderings of the same error findings: an alphabetical
baseline and `power-repair-priority-v1`. The latter prioritizes recognized
code/basis pairs for proven contradictory bounds, then direct initialization
evidence, then other errors, and finally numerical feasibility residuals.
Unknown code/basis pairs receive no special promotion. Each priority has an
explanation. Ties use code, affected identities, and complete serialized evidence.
All findings and duplicates are retained; evidence and severity are unchanged.

| Variant with explicit localization | Alphabetical rank | Priority rank |
|---|---:|---:|
| Contradictory voltage bounds | 2 | 1 |
| Out-of-bounds voltage start | 10 | 1 |

Top-three localization is **2/4**, versus **1/4** for the saved baseline on the
same findings. Localization anywhere remains **2/4**: this is a presentation
improvement, not new defect detection. Clean error cases remain **0/1**, empty
error lists **2/5**, unavailable analyses **0/5**, and scripted verified repairs
**4/4**. Unit-error and omitted-reference localization remain unresolved.

The policy was chosen after inspecting this development corpus. It is a review
heuristic, not a causal certificate or held-out result. Freeze this version before
evaluating unseen incidents, including cases where residuals are the most useful
evidence. The generic library renderers are unchanged; this policy is currently
confined to the pilot. Generated replay artifacts now contain both rankings and
their paired localization metrics.

## Follow-up: separate gauge configuration, 11 September 2026

`connected-acp-uniform-shift-v1` evaluates the same uniform-angle candidate on
every variant, using connected ACP topology and public angle-variable indices.
It saves the local degeneracy report, candidate coordinates, adapter-generated
candidate count, reference metadata, runtime, and availability separately from
the ranked diagnostics. Incident labels and inverse patches are not inputs.

| Variant | Explicit uniform-angle candidate |
|---|---|
| Clean | Not observed in the local nullspace |
| Contradictory voltage bounds | Not observed |
| Omitted reference equation | Observed |
| Out-of-bounds voltage start | Not observed |
| Second per-unit conversion of active load | Not observed |

All five comparisons completed. The omitted-reference case is the only positive
result (**1/1 injected omission**, **0/4 positives on the other variants**).
These are development counts, not population detection rates. The library
labels the observed mode `PhysicalExpectation`; this is candidate-supported
local evidence, not a mathematical certificate of global symmetry or proof
that a particular equation was omitted. The independent 0.3-radian shift check
remains separate physical evidence for this injected case.

The adapter produced **one automatic candidate in every variant**, and reference
metadata reported one declared reference bus in every variant. Thus the initial
concern that metadata would suppress this fixture's candidate did not occur.
Neither a reference declaration nor the mere existence of a candidate determines
whether the model equations anchor the angle; the numerical comparison matters.

This experiment leaves the ranking metric at **2/4** and scripted repairs at
**4/4**. It does not merge gauge evidence into error severity or claim a new
autonomous repair. Missing starts, unsupported formulations/topology, unavailable
comparisons, and coordinates outside the free scope have explicit outcomes.
The next application gap is unit provenance, followed by unseen-network testing.

The verified run passed **109 pilot assertions**. Its complete artifacts are in
`work/power-repair-pilot-gauge-verified/`; the generic library source was unchanged
in this batch, so the previous full-suite baseline remains 7,560 assertions.

## Follow-up: source load lineage, 11 September 2026

`pilot-load-lineage-v1` independently reads the pinned numeric MATPOWER bus table
and records source rows, bus identities, MW/MVAr units, and baseMVA. It verifies
the ledger against the source hash and contents before comparing each mapped
load P/Q value with a single per-unit conversion. This workflow receives source
information unavailable to model-only diagnostics; its results are separate.

The only mismatch is `power_units`, localized to **bus 1, load 1, active power**:
the source contains **110 MW**, the expected value is **1.1 p.u.**, and the model
contains **0.011 p.u.** The observed/expected ratio is **0.01**. This is consistent
with the injected second division, but source disagreement alone does not prove
which operation caused it or whether an operator intended a changed load.
The other four variants are source-consistent, and every repaired load agrees
with the recorded source. The checks use an explicit numerical tolerance;
agreement is not an exact arithmetic or physical feasibility certificate.

Missing metadata/mappings, split loads, changed bases/status, altered ledgers,
unsupported source units, and nonfinite values yield unavailable results. An
intentional source change requires updated lineage. The reader supports this
hash-pinned numeric fixture only; it is not a general MATPOWER program parser.

The run passed **149 pilot assertions**, including 22 isolated lineage contracts
and complete diagnostic, gauge, source, and physical repair checks. Model-only
top-three localization remains **2/4**, clean errors **0/1**, and scripted verified
repairs **4/4**. Verified artifacts are in
`work/power-repair-pilot-lineage-verified/`. Core source is unchanged, so the last
full-suite baseline remains 7,560 assertions. These development results need
unseen networks and incidents before any effectiveness claim.

## Frozen next-network evaluation: case9, 11 September 2026

The [evaluation freeze](power_repair_case9_freeze.json) recorded 47 file hashes,
selection rules, and eight acceptance criteria before executing case9. The
driver checked the hashes before and after execution and reran all case3
contracts first. No diagnostic, ranking, gauge, or tolerance rule was changed
after observing case9 outcomes. The harness was parameterized for a supplied
fixture/hash before the freeze; source lineage remains case3-only.

| Case9 outcome | Result |
|---|---|
| Clean error cases | 0/1 |
| Top-three localization, prioritized / alphabetical | 2/4 / 1/4 |
| Bad-start diagnosis rank, prioritized / alphabetical | 1 / 6 |
| Contradictory-bound rank, prioritized / alphabetical | 1 / 2 |
| Base diagnostic unavailable cases | 0/5 |
| Gauge shift observed | Omitted reference only; 1/1 omission, 0/4 other variants |
| Independently verified scripted repairs | 4/4 |
| Source-lineage unavailable cases | 5/5, as predeclared for the unsupported fixture |

All eight frozen criteria passed. **167 assertions passed**: 149 existing pilot
contracts plus 18 evaluation-integrity checks. Metric criteria are stored as
outcomes, separately from assertions about harness integrity, so a future missed
criterion cannot be hidden by treating it as a broken test fixture. The matching
freeze digest, criteria, solver logs, raw findings, physical checks, and paired
rankings are in `work/power-repair-case9-validation/`.

This is one additional standard public network with the same injected incident
families. The filename search found no prior case9 use in the searched repository
paths; that is not proof of global non-exposure or blinded evaluation. It is
evidence of transfer under these controls, not real-world effectiveness or human
repair benefit. Case9 is now exposed and must be treated as development data for
any future tuning. Future claims require other networks and new incident families.
The freeze is a local, reviewable artifact, not an external preregistration.

## Frozen new-family evaluation: case14 capacity shortage, 11 September 2026

The [capacity freeze](power_repair_case14_freeze.json) preserves the case9 policy
hashes and adds a new-to-pilot network and incident family. The clean control is
compared with all active generator `pmax` values set to zero (and `pmin` capped
at zero), first with inherited starts and then with generator active-power starts
reset to zero. Other coordinates keep baseline starts. This deliberately severe
synthetic shortage is not a representative outage sample.

The independent witness sums demand and generator capacity exactly as rational
representations of the input numbers. It checks nonnegative active load/shunt
conductance, passive branch impedances and transformers, and absence of external
DC/storage/switch power. Under these closed passive ACP assumptions, summed
generation must cover demand plus nonnegative losses. Both altered models have
zero capacity against approximately **2.59 p.u. (259 MW)** demand. This witness
is adjudication evidence and is not supplied to the diagnostic engine.

| Case14 variant | Static errors | Ranked errors | Modified solver status | Independent physical result |
|---|---:|---:|---|---|
| Clean | 0 | 0 | Locally solved | Pass |
| Shortage, inherited starts | 0 | 5 | Locally infeasible | Fails; maximum residual about 0.942 p.u. |
| Shortage, generator starts reset | 0 | 5 | Locally infeasible | Fails; maximum residual about 0.942 p.u. |

**Five of six frozen criteria passed.** The missed criterion was a static error
on the shortage with generator starts reset. The dynamic findings are one
initialization-bound finding and four numerical constraint residuals. In the
reset-start case, the bound finding concerns an implied branch-flow restriction,
not a generator start outside its declared bounds. Thus resetting generator
starts does not remove all point defects, and these local findings do not by
themselves establish that no start can repair the model's capacity shortage.

Both scripted shortage repairs restore original data/starts and pass independent
physical checks; the clean control does too. All analyses complete. **177 harness
assertions passed** (the previous 167 plus ten witness/integrity checks), while the
evaluation's acceptance result is **false**. Test success does not erase the
diagnostic miss. The frozen files remain unchanged. Artifacts and the failed
criterion are in `work/power-repair-case14-capacity/`.

PowerModels normalizes the input during parsing, including angle-bound tightening
and a bus-type correction; warnings are retained in the run log. Physical checks
use the saved parsed network, not a claimed exact equivalent of the raw MATPOWER
file. This case is now exposed development data. A follow-up capacity preflight
must be labeled as a post-evaluation change, with fresh cases for transfer testing.

## Post-evaluation capacity preflight, 11 September 2026

The experimental `PowerCapacityPreflight.capacity_preflight` data check now
implements the aggregate necessary condition under an explicit
`:closed_acp_fixed_load` contract. It validates component support, active bus
references, finite numbers, generator-bound consistency, nonnegative active
loads/conductance, and passive branch/transformer parameters. Exact rational
arithmetic avoids threshold rounding and aggregate overflow.

| Supplied data | Preflight result |
|---|---|
| Case14 clean | `not_ruled_out` |
| Shortage with inherited starts | `capacity_shortage` |
| Same shortage with generator starts reset | `capacity_shortage` |
| Scripted repaired data | `not_ruled_out` |

This identifies the conditional capacity shortfall independently of the start.
It consumes domain data and a caller-declared equation contract; it does not
inspect a model backend or prove that its equations implement those assumptions.
`not_ruled_out` is not feasibility: an isolated load can lack supply despite
adequate aggregate capacity, and reactive, voltage, thermal, and security limits
remain outside scope. Unsupported devices, bad mappings, nonfinite values, or
invalid premises return `unavailable` with a reason.

The old case9 and case14 freezes remain valid, and the case14 failed criterion
remains false. This is an explicitly post-evaluation follow-up on exposed data,
not a retest advertised as held-out success. Artifacts are in
`work/capacity-preflight-followup/`; the helper is experimental and separate from
the stable library API. Further transfer testing and backend/source-contract
verification are still required.

## Post-evaluation backend contract matching, 11 September 2026

`CapacityModelContract.checked_capacity_preflight(pm, data)` now rebuilds a
standard ACP OPF from supplied data and compares its supported scalar constraint
rows and named variables with the actual backend. It uses exact numeric keys,
preserves row multiplicity, and ignores starts and objective in this
feasibility-scope comparison. Unsupported representations and source precision,
opaque NLP blocks, callbacks, and ambiguous variable names are unavailable.

The exposed case14 shortage model matches and retains its conditional capacity
result. Deleting an equation, changing a coefficient without changing row count,
changing a capacity bound, or supplying mismatched data prevents a match. The
clean model matches but remains only `not_ruled_out`. **20 contract assertions
passed**, including callback/name/precision controls and start independence.
Artifacts are in `work/capacity-model-contract-followup/`.

This checks agreement with the standard Float64 builder, not the correctness of
that builder's physical semantics. In particular, exact matching of rounded
expanded coefficients does not certify their passivity. The capacity conclusion
therefore remains conditional, not a newly established unconditional backend
infeasibility certificate. Conservative representation mismatches can reject
mathematically equivalent models. This is experimental post-evaluation work;
the original frozen results remain unchanged.

## Priorities justified by this run

1. Maintain the new separation between exact bound evidence and practical error
   severity. The tolerance is absolute in each variable's coordinates, so unit
   scaling and broader domain-specific actionability still need evaluation.
   Validate the conditional capacity preflight on further networks. The new
   representation matcher closes one contract gap; bound rounding effects in
   actual physical equations before claiming unconditional backend infeasibility.
2. Evaluate the frozen priority policy on unseen incidents before adopting it in
   the general reporting workflow. Check whether deprioritizing residuals hides
   useful evidence when there is no direct input diagnosis.
3. Extend source provenance beyond the pinned load fixture, including legitimate
   operating-point updates, split loads, explicit rebasing, and equipment units.
   Keep source-aware and model-only comparisons separate.
4. Extend the separate gauge configuration to unseen networks and operating
   points, retaining explicit unavailable results. Then cover unbalanced networks,
   externally reported incidents, and an observed human repair study.

Do not add automatic model editing or claim repair success from solver status.
Do not tune to this tiny corpus and describe the result as transfer evidence.

## Validation and artifacts

The independent checker has 17 analytic acceptance/rejection assertions,
including bus balance, voltage, equipment and flow limits, reference invariance,
nonfinite values, DC losses, and unsupported storage. The standalone pilot
integration tests check serialization, unavailable stages, fixture identity,
restored inputs, solver feasibility, and independent defect/repair evidence.

Replay produces `work/power-repair-pilot/summary.json` and per-variant artifacts.
These generated files are ignored by Git; preserve that directory together with
the source files matching `source_hashes.json` when exchanging a specific run.
Counts above describe this development configuration only. They are not population
error rates, and the physical checker does not certify global optimality.
