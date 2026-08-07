# BMOPFTools staged-OPF extension

`NLPDiagnostics` integrates with BMOPFTools in two layers.

- `bmopf_terminal_report(net)` translates BMOPFTools' public terminal and
  grounding analysis into physical findings. It does not claim that a compiled
  JuMP model has a corresponding Jacobian nullspace.
- Staged-OPF entry points use BMOPFTools' public model, network, lifecycle,
  base, and semantic-registry APIs. They do not inspect private builder state
  or infer component semantics from variable names.

## Terminal coordinates and bases

For staged IVR models, `bmopf_terminal_port_metadata`,
`bmopf_terminal_port_coordinate_maps`, and
`bmopf_terminal_port_coordinate_semantics` declare one real and one imaginary
bus-voltage port. SI coordinates are labelled `V`. Per-unit coordinates are
labelled `p.u.` with model-coordinate nominal scale one.

The staged adapter also exposes explicit component-to-bus attachment ports for
native device terminal maps and line endpoints. Use
`bmopf_terminal_port_connections(context)` to inspect the finite terminal-order
embeddings. These declarations describe shared coordinate ownership only; they
do not equate the two ends of a line or transformer and do not replace their
constitutive equations. Fixed- and n-winding transformer winding attachments
are included as separate ports. Current-coordinate declarations are available
through `bmopf_terminal_current_port_metadata(context)`,
`bmopf_terminal_current_port_coordinate_maps(context)`, and
`bmopf_terminal_current_port_coordinate_semantics(context)`. They use the
public BMOPFTools current-key registry and deliberately expose only registered
conductor coordinates; use `bmopf_terminal_current_port_report(context)` to
inspect coverage. Assembly evidence is available through
`bmopf_terminal_port_assembly(context)` and
`bmopf_terminal_port_assembly_report(context)`. This graph groups declared
component instances by attachment connections and reports disconnected groups
as structural evidence; it does not decide whether an island is physically
valid or whether a skipped port is a modelling error. The adapter also declares conservative component-level
common-mode expectations for explicit-neutral WYE ports and DELTA ports. Inspect
them with `bmopf_terminal_port_nullspace_modes(context)` and
`bmopf_terminal_port_nullspace_mode_report(context)`. These are physical
expectations, not proof of a compiled-model gauge; pass
`include_port_physical_modes = true` to `bmopf_analyze_opf` to compare their
projected directions with observed Jacobian nullspaces. Constitutive current
maps remain separate adapter work.

Constitutive voltage maps are available separately from topology connections:
`bmopf_terminal_constitutive_maps(context)` returns labeled linear maps for
device WYE/DELTA coil incidence, fixed-transformer ideal winding coupling, and
n-winding coil incidence. The maps retain ratio, tap, delta-roll, winding, and
configuration metadata and are not silently treated as endpoint equalities.
Declared vector-group phase shifts are preserved as metadata; the report emits
an explicit representational warning when a nonzero shift is present because
the current separated real/imaginary maps do not apply complex phase rotation.
`bmopf_terminal_constitutive_map_report(context)` checks their dimensions and
finite coefficients. For fixed transformers, use
`bmopf_terminal_complex_constitutive_maps(context)` for a phase-aware real block
map over the ordered ports `[from_real, from_imag, to_real, to_imag]`; its
report validates the block dimensions and finite-coefficient contract while
retaining exact structural rank as metadata.

The passive network current contract is exposed through
`bmopf_passive_network_current_maps(context)`. It wraps the public
`BMOPFTools.ybus_passive` result as a real block `I = YV` map for lines,
shunts, capacitors, and passive transformer elements. The map is SI A/V
evidence and deliberately excludes nonlinear load, generator, and IBR current
laws. On p.u. staged models the report emits a unit-basis warning until an
explicit bus/current-base conversion is supplied. Request
`basis=:model` (or `:pu`) to apply the public per-bus voltage/current bases;
missing or invalid bases produce a finding rather than a partial conversion.

Static nonlinear-current fingerprints are available through
`bmopf_current_law_fingerprints(context)` and
`bmopf_current_law_report(context)`. Public load models are classified as
constant-power/current/impedance, ZIP, or exponential; generators are marked
as dispatch-power current laws; shunts/capacitors as linear admittances; and
IBR controls are classified conservatively from any public control profile.
Exact IBR equations remain plugin-owned. Constant-power and dispatch-power
families carry a mathematically grounded zero-voltage singularity warning.
Unknown differentiability is retained as an explicit finding rather than
being inferred from variable names.

Generator fingerprints now retain the public bilinear
`P/Q = (V_r,V_i)·(I_r,I_i)` dispatch equation and configuration. IBRs are
refined from their public control-profile metadata: constant-PF laws,
voltage-droop laws, power-sharing profiles, and box-dispatch fallbacks are
classified separately, with topology, profile, breakpoint, and differentiability
evidence retained. This is a law-family classification; it does not claim that
the full plugin control implementation is available to the generic core.

Operating-point probes are available through
`bmopf_current_law_operating_point_probes(context, source)` and
`bmopf_current_law_operating_point_report(context, source)`. `source` may be a
complete `EvaluationPoint` in staged model coordinates or a saved BMOPF result
dictionary. For public load models, the adapter evaluates the documented
constant-power/current/impedance, ZIP, and exponential laws and estimates the
local real 2-by-2 current Jacobian by a guarded central difference. Missing
terminal coordinates, zero-voltage evaluations, non-finite currents, and
amplified local derivatives are reported separately. This is numerical
evidence at the supplied point; it does not replace the static fingerprint and
does not claim that plugin-owned controller derivatives are smooth. Generator
and IBR records now also use the public bilinear power equations
`P = dVᵣ·Iᵣ + dVᵢ·Iᵢ` and `Q = dVᵢ·Iᵣ − dVᵣ·Iᵢ`: probes retain observed P/Q,
saved-result equation residuals, and a 2-by-4 voltage/current-to-power
derivative fingerprint. Constant-power-factor IBRs also retain the local
power-factor equation residual when the profile is valid. Missing current
coordinates remain explicit coverage evidence rather than being treated as
zero. Voltage-droop profiles also receive a controller-curve fingerprint:
the public Volt-var/Volt-watt breakpoint schema is validated, its normalized
softplus value and local slope are evaluated with the same stable
`log1pexp`/logistic semantics as BMOPFTools, and the nearest-breakpoint
distance and smoothing width are retained. The adapter now resolves the public
monitored-voltage reference (`PG`, `PN`, or `PP`, including `_AVERAGED`) from
the saved or staged rectangular bus coordinates, and records whether the
measurement is exact public monitor coverage or a terminal-pair proxy. Legacy
IBR-level `voltage_aggregation` overrides are preserved. The benchmark contract
also aggregates curve families, statuses, breakpoint-proximity counts, and
monitor-coverage semantics per case. When the public device base is available,
probes additionally report device-base-scaled Volt-var equality residuals and
Volt-watt cap violations; reports distinguish these numerical observations
from static profile validation.

Downstream tooling can consume typed observations directly with
`bmopf_controller_curve_operating_point_observations(context, source)`. Each
`ControllerCurveOperatingPointObservation` carries the curve family, monitor
semantics, normalized output, local slope, breakpoint distance, device base,
and equality/cap evidence without requiring consumers to parse metadata keys.
The draft-corpus runner stores these observations inside each profile record
and the corpus summarizer aggregates their family, status, and exact-versus-
proxy coverage counts, so controller-rich cases can be compared without
re-running model inspection.
`summarize_bmopf_controller_campaign.jl` adds descriptive slope,
breakpoint-distance, residual, and per-component persistence summaries for
saved-result campaigns; its output deliberately keeps coverage and numerical
variation separate from any physical interpretation.

For multiple explicit snapshots, use
`bmopf_current_law_operating_point_persistence(context, sources)`. It aligns
component, law-family, terminal-pair, and subload identities, then reports
domain-status transitions and large changes in local derivative scale or
conditioning. Missing probes remain partial-coverage findings; they are never
treated as zero derivatives. Persistence is comparative numerical evidence,
not a global condition bound or a physical failure certificate.
The saved-result persistence harness also preserves typed controller
observations at every mapped time point and reports controller status,
monitor-coverage, and slope-change findings alongside rank and active-set
persistence.

For solver callbacks that captured primal vectors, use
`bmopf_current_law_operating_point_trace(context, trace)`. The helper selects
captured `IterationPointBinding`s by phase and an optional deterministic
`max_points` budget, runs the same operating-point probes, and retains the
solver iteration labels beside each snapshot. It also returns a persistence
report across the selected iterates. Metric-only traces (including the current
MadNLP callback path) remain in the source trace but produce an explicit
coverage finding; no iterate is reconstructed from log text. The boundary is
inspectable directly with `madnlp_primal_capture_capability()`, which records
why the current public callback is metric-only and what evidence is needed
before coordinate capture can be enabled.

With `NLPDIAGNOSTICS_BMOPF_CAPTURE_POINTS=true`, the solver-trace runner also
stores typed controller observations for each selected primal iterate. The
solver-trace summarizer keeps their family, status, monitor semantics, slope,
breakpoint, and residual distributions beside the solver-phase summary.
`compare_bmopf_solver_traces.jl` now aligns those controller summaries between
two traces, so solver iteration differences can be read separately from
coordinate-scale differences in controller slopes and breakpoint distances.

The solver-trace summarizer also retains controller-curve persistence evidence:
status transitions, exact/proxy monitor-coverage transitions, slope changes,
and associated finding codes are summarized separately from generic solver
iteration counts.

The physical bus voltage base remains declaration evidence
(`physical_voltage_base_V` and the semantics description); it is deliberately
not substituted for the p.u. coordinate scale. This distinction prevents a
230 V physical base from being misread as a nominal model value of 230. Use
`bmopf_terminal_port_coordinate_scale_report(context, point)` to compare
directly mapped terminal coordinates at a point.

## Physical candidates versus observed modes

`bmopf_floating_neutral_candidate_modes(context)` emits real and imaginary
uniform rectangular-voltage shifts only for BMOPFTools explicit floating-neutral
components. These are `PhysicalExpectation`s, not a claim that any formulation
has a gauge: source equations, fixed coordinates, controls, and KCL equations
may remove the direction.

All numerical entry points keep these candidates opt-in through
`include_floating_neutral_candidates=false` by default. When enabled, the
candidate provenance is appended to the generic numerical report and the
generic core compares it with the supplied local numerical evidence.

```julia
point = NLPDiagnostics.EvaluationPoint(variables, values)
report = NLPDiagnostics.bmopf_analyze_degeneracy(
    context, point; include_floating_neutral_candidates = true,
)
```

Available staged numerical entry points are:

- `bmopf_initialization_point(context; ...)` and
  `bmopf_analyze_initialization(context; ...)`;
- `bmopf_analyze_degeneracy(context, point; ...)`;
- `bmopf_analyze_active_set(context, point; ...)`;
- `bmopf_analyze_jacobian_rank_persistence(context, points; ...)`;
- `bmopf_analyze_component_rank_persistence(context, points; ...)`; and
- `bmopf_analyze_reduced_hessian_persistence(context, snapshots; ...)`.

Use `bmopf_component_rank_capability_report(context)` to inspect that
component-rank boundary directly. It reports how many plugin component
families declare a physically justified expected rank, and emits an explicit
informational finding when the declarations are absent. This keeps a missing
plugin capability distinct from an observed numerical rank deficiency.

The component-rank path records expected-rank declaration coverage in its
metadata. BMOPFTools registry families currently expose coordinate semantics
but no physical expected-rank declarations, so component-rank persistence is
reported as unavailable rather than silently interpreted as zero rank loss.

`bmopf_analyze_initialization` reads exact `VariablePrimalStart` values and
never invents, fills, or modifies them. The other entry points evaluate only
caller-supplied points or snapshots. None solve, alter, or initialize the
BMOPFTools model.

## Reproducible benchmark records

Build a real staged context with BMOPFTools, then supply an explicit
`ProfileCase` with the exact MOI-coordinate point to inspect:

```julia
context = BMOPFTools.build_opf_model(network; add_objective = false)
model = BMOPFTools.opf_model(context)
point = NLPDiagnostics.initialization_point(model)
case = NLPDiagnostics.ProfileCase("initial", point;
    task = "feeder smoke test", formulation = "BMOPF IVR",
    scale = "per-unit",
)
result = NLPDiagnostics.bmopf_profile_case(context, case)
data = NLPDiagnostics.profile_result_data(result)
```

`BMOPFProfileResult.profile` retains generic profile findings and timings.
`context_report` retains BMOPFTools physical and representational evidence;
`initialization_report` is retained separately. BMOPF-only time and allocation
observations are separate from generic numerical-stage timings, so benchmark
comparisons do not conflate the two.
Serialized profile records also expose a typed
`bmopf_component_rank_capability` object with declaration counts, coverage, and
capability-finding count, so campaign tools need not parse string metadata.
The context report also records component expected-rank coverage and the
standalone capability-finding count as metadata. The explicit finding remains
available through `bmopf_component_rank_capability_report(context)` without
being duplicated in the existing profile finding set.
`bmopf_result_field_catalog()` exposes the adapter-owned mapping from saved
export families to physical quantities, public BMOPFTools bases, and registered
model-key families. Profiled saved-result benchmark records also carry
`bmopf_constraint_feasibility_field_attribution`, which reports the registered
families in each violated row's evaluated Jacobian support. This is structural
support evidence, not a claim that one field family caused the violation.
The same report now checks BMOPFTools' registered `:constraint` keys. Registered
rows receive a semantic family and instance (for example `kcl_r/(bus,terminal)`)
in `constraint_support`; rows without a public registration are explicitly
labelled `unregistered_constraint`. This is an intentional API boundary: the
adapter never infers device or physical meaning from JuMP variable names. The
serialized metadata separates registered and unregistered violated-row counts
and aggregates both constraint families and instances. Each row also carries
component candidates derived from those registered variable families (for
example `bus/79` or `ibr/pv_2`); these are localization evidence, not a claim
that a candidate component caused the residual.
The BMOPFTools adapter now registers IBR phase constraints under stable families
such as `ibr_p_lower`, `ibr_p_upper`, `ibr_q_volt_var`, `ibr_power_circle`, and
`ibr_power_link_p/q`. This makes the IBR power-policy findings directly
inspectable. Bus voltage/angle/sequence limits and line current thermal cones
are also registered when those limits are present; custom model-hook equations
remain an explicit registration boundary.
By default, `bmopf_profile_case` also appends BMOPFTools' public
`opf_differentiability_report` to `context_report`. This preserves engine-owned
nonsmooth-operator, dynamic-branch, unsupported-parameter, active-set, and
readiness qualifications alongside generic derivative findings. Set
`include_differentiability=false` only when deliberately measuring a narrower
context stage; omitting it does not make the formulation differentiable.

For a fresh, non-mutating real-network benchmark, use the staged builder
through `bmopf_build_and_profile`. The callback is deliberately responsible for
making the point only after the context assigns MOI variable indices:

```julia
run = NLPDiagnostics.bmopf_build_and_profile(network, context -> begin
    model = BMOPFTools.opf_model(context)
    point = NLPDiagnostics.initialization_point(model)
    isnothing(point) && error("benchmark requires complete explicit starts")
    NLPDiagnostics.ProfileCase("feeder-initial" , point;
        task = "real feeder smoke test", formulation = "BMOPF IVR", scale = "p.u.",
    )
end; build_kwargs = (add_objective = false,))

data = NLPDiagnostics.profile_result_data(run.result)
```

The returned `run` keeps the staged context for inspection and records build
and KCL-finalization seconds/allocations separately. KCL is finalized by
default; set `finalize_kcl=false` only when deliberately profiling a partial
builder state. `network` is deep-copied unless
`copy_network=false` is explicitly requested.

`benchmarks/bmopf_smoke.jl` is an opt-in five-fixture starter corpus for the
BMOPFTools `pf_comparison` OpenDSS data. It exercises grounded and free neutral
returns, an unbalanced four-wire feeder, a delta load, and a wye-delta
transformer. Set `NLPDIAGNOSTICS_BMOPF_FIXTURE_ROOT` to the corresponding
BMOPFTools fixture directory before running it. Its output is deliberately a
compact discovery summary and it writes one full JSON evidence record per case
plus `index.json`. Set `NLPDIAGNOSTICS_BMOPF_OUTPUT_DIR` to choose the output
directory; failures are retained as case-level JSON records so one failed build
does not hide the remaining corpus.
Set `NLPDIAGNOSTICS_BMOPF_CASES` to a comma-separated subset such as
`delta-load,wye-delta-transformer` when iterating on one diagnosis.
The default `NLPDIAGNOSTICS_BMOPF_POINT_POLICY=initialization` requires complete
caller-provided starts. Set it to `zero` only to use the explicit synthetic
zero-coordinate probe; that probe never writes starts and must not be
interpreted as a physically meaningful voltage initialization.
Run `benchmarks/summarize_bmopf_smoke.jl <output-directory>` after a corpus
execution to produce `summary.json`, including point-policy provenance and
per-case/aggregate finding-code counts. The summary also aggregates the
multiconductor contract block: port/map/mode counts, adapter finding cases,
physical-mode category coverage, and constitutive-map rank statistics. Missing
contract blocks are tolerated so older smoke records remain readable.

Each smoke record also contains a `multiconductor_contract` block with
voltage/current port counts, attachment coverage, physical-mode categories,
constitutive-map counts/ranks (including phase-aware complex transformer
blocks), and independent adapter finding counts. This is structural metadata
only; the smoke runner does not materialize dense Jacobians for this contract
block.
The five-fixture run is also summarized by
`benchmarks/summarize_bmopf_multiconductor_smoke.jl` and passed through the
campaign trust gate. All five fixtures completed with dense analysis explicitly
disabled, 14 physical-mode declarations, and 52 adapter-level contract
findings. Neutral and delta fixtures expose `common_mode`; the wye-delta
transformer additionally exposes `delta_common_mode` and one phase-aware
complex constitutive map. The source loader retained 67 PowerIO schema
warnings about fields dropped from the BMOPF schema, so the validator reports
a warning even though BMOPFTools integrity preflight has no blocking errors.

Both BMOPF runners record the scalar model dimensions and the product of
variables and scalar constraint rows. Their dense rank/SVD analyses are guarded
by `NLPDIAGNOSTICS_BMOPF_RANK_MAX_DENSE_ENTRIES`, which defaults to `250000`.
If a Jacobian exceeds that size, the generic reports retain structural and
row/column evidence but skip dense materialization. Set the variable to `0` to
skip every dense rank stage explicitly. This is the intended default safeguard
for large feeder benchmarks, not a claim that no numerical diagnosis is
possible.

`benchmarks/bmopf_draft_corpus.jl` reads the `.bmopf.json` snapshots in the
BMOPFDraftData benchmark repository using BMOPFTools' public `parse_bmopf`
interface. By default it selects two 30-bus representatives; it never sweeps
the repository implicitly. Select individual snapshots through
`NLPDIAGNOSTICS_BMOPF_CASES`, relative to
`NLPDIAGNOSTICS_BMOPF_BENCHMARK_ROOT`. For example, a large snapshot can be
run without dense rank materialization:

For repeatable time-series selections, set
`NLPDIAGNOSTICS_BMOPF_CASE_SELECTION` to `30bus`, `30bus_ln`, `30bus_lg`,
`538bus`, `538bus_ln`, `538bus_lg`, `99bus`, `99bus_ln`, or `99bus_lg`.
The unsuffixed selector includes both LN and LG snapshots; the suffixed forms
select one formulation. Selectors discover and sort snapshots under the
benchmark root; explicit `NLPDIAGNOSTICS_BMOPF_CASES` takes precedence.

```sh
NLPDIAGNOSTICS_BMOPF_BENCHMARK_ROOT=/path/to/BMOPFDraftData/benchmarks \
NLPDIAGNOSTICS_BMOPF_CASES=ENWLsnapshots/538bus_LG/538bus_LG_t01_0800.bmopf.json \
NLPDIAGNOSTICS_BMOPF_POINT_POLICY=zero \
NLPDIAGNOSTICS_BMOPF_RANK_MAX_DENSE_ENTRIES=0 \
julia --project=. benchmarks/bmopf_draft_corpus.jl
```

As with the smoke runner, `zero` is an explicit synthetic coordinate probe;
its findings must not be interpreted as a physically meaningful voltage state.

For opt-in live solver evidence, use `benchmarks/bmopf_solver_trace.jl`. It
builds one selected snapshot with an objective, enforces KCL, solves through
the public Ipopt or MadNLP callback adapter, and writes the frozen iteration
trace together with the final-result profile and BMOPFTools context profile.
The runner defaults to one 30-bus case and refuses to solve models above
`NLPDIAGNOSTICS_BMOPF_SOLVE_MAX_VARIABLES` (2,000 by default), recording a
size-guard skip rather than silently launching a large solve. Example:

```sh
NLPDIAGNOSTICS_BMOPF_BENCHMARK_ROOT=/path/to/BMOPFDraftData/benchmarks \
NLPDIAGNOSTICS_BMOPF_CASES=ENWLsnapshots/30bus_LN/30bus_LN_t01_0800.bmopf.json \
NLPDIAGNOSTICS_BMOPF_SOLVER=ipopt \
julia --project=work/benchmark-environment benchmarks/bmopf_solver_trace.jl
```

On systems where the default Julia depot is read-only or has stale compiled
cache locks, use the depot-safe launcher instead:

```sh
julia benchmarks/run_benchmark.jl benchmarks/bmopf_solver_trace.jl
```

It keeps the selected benchmark project and existing package sources visible,
but places compiled caches and package locks in a writable temporary overlay.
Set `NLPDIAGNOSTICS_BENCHMARK_DEPOT` to make that overlay persistent.

Set `NLPDIAGNOSTICS_BMOPF_SOLVER=madnlp` only when MadNLP is installed in the
selected benchmark environment. `NLPDIAGNOSTICS_BMOPF_CAPTURE_POINTS=true`
enables Ipopt callback primal vectors; leave it false for a compact metrics
trace. This solve runner is intentionally separate from the structural corpus
runner so large-case campaigns cannot acquire a solver workload implicitly.
Set `NLPDIAGNOSTICS_BMOPF_CAPTURE_LOGS=true` to also configure the solver-owned
`output_file` and retain raw marker/iteration evidence beside the callback
trace. Log capture is opt-in because solver output can be large; the summary
reports how many cases supplied log evidence and which log findings occurred.
Structured log summaries also retain the parsed iteration count, segment count,
final iteration, and final printed primal/dual residuals. Residual headings
such as Ipopt's `Dual infeasibility` are not treated as infeasibility outcome
markers, and Ipopt row suffixes are retained while their numeric fields are
parsed.
For multi-case campaigns where a native solver exit must not affect the other
snapshots, use `benchmarks/launch_bmopf_solver_trace.jl`; it launches one
snapshot per child process and preserves a per-case process log and exit code.
`NLPDIAGNOSTICS_BMOPF_CHILD_TIMEOUT_SECONDS` bounds each child (900 seconds by
default), and timed-out cases remain explicit in the parent index rather than
being treated as successful or failed solves.
For a cross-solver matrix, use
`benchmarks/launch_bmopf_solver_matrix.jl` with
`NLPDIAGNOSTICS_BMOPF_SOLVERS=ipopt,madnlp`. It creates separate solver
directories and a `matrix_index.json`; summarize each directory independently,
then compare them with `compare_bmopf_solver_traces.jl`. This keeps solver
startup timeouts, objective conventions, log evidence, and environment
fingerprints visible instead of collapsing them into a benchmark score.
For repeatability experiments, use
`benchmarks/launch_bmopf_perturbation_repeats.jl` with
`NLPDIAGNOSTICS_BMOPF_REPLICATES=2` (or more). Each replicate receives a
stable `run_id` and `replicate_index`, its own matrix directory, and a bounded
process log. Run
`benchmarks/summarize_bmopf_perturbation_repeats.jl <repeat-output>` to align
solver/case/family variants across replicates. The report separately exposes
baseline termination inconsistency and repeated variant changes; a repeated
change is evidence of an observed pattern, not a causal or physical claim.
To aggregate several repeat outputs across a selected corpus, run
`benchmarks/summarize_bmopf_perturbation_corpus.jl <repeat-summary-1.json>
<repeat-summary-2.json> [corpus-summary.json]`. It reports family recurrence,
iteration-delta distributions, sparse-rank observation counts, and
solver-agreement/disagreement per case and family. It now aligns baseline
terminations, variant terminations, iteration-direction changes, and
repeatability signatures for each solver pair. Solver disagreement is retained
as evidence rather than averaged away. The corpus output also emits structured
findings with severity, confidence, evidence, and suggested actions for
recurring sparse effects and solver-dependent outcomes.
`summarize_bmopf_solver_matrix.jl <matrix-output>` automates that final step:
it creates missing per-solver summaries, writes pairwise comparison artifacts,
and records any summary/comparison subprocess error in `matrix_summary.json`.
For a controlled model-level perturbation matrix, set
`NLPDIAGNOSTICS_BMOPF_RUN_FAMILY_PERTURBATIONS=true` together with a bounded
`NLPDIAGNOSTICS_BMOPF_PERTURBATION_FAMILIES` list and run the same launcher.
The matrix manifest propagates those settings and
`matrix_summary.json` adds `family_perturbation_matrix`, including each
solver/case/family pair, termination and iteration deltas, sparse/local rank
evidence, and descriptive repeatability counts. These variants replace a
native family builder with a no-op and rebuild KCL; they are intentionally
incomplete formulations for sensitivity experiments, not valid physical
models or causal proofs. Keep the list small and use a separate output
directory when collecting this evidence.
Use `summarize_bmopf_campaign.jl <corpus-summary.json> <matrix-summary.json>`
to combine corpus and solver evidence. Set
`NLPDIAGNOSTICS_BMOPF_ADDITIONAL_CORPUS_SUMMARIES` to a comma-separated list
of additional corpus summaries; their structural, context, integrity, and
generic fingerprints are aggregated while each source remains separate.
Set `NLPDIAGNOSTICS_BMOPF_PERTURBATION_SUMMARIES` to one or more outputs from
`summarize_bmopf_perturbation_corpus.jl` to retain corpus-level perturbation
findings in the combined campaign report. They remain in a separate
`perturbation_corpus` namespace and are not merged into generic or solver
finding counts.
For a normalized, source-aware view over these reports, run
`benchmarks/summarize_bmopf_evidence_ledger.jl report1.json report2.json
[ledger.json]`. The ledger preserves each finding record and adds stable
identities, source counts, severity/confidence distributions, and recurrence
across source reports. It is an evidence index, not a score.
Compare two ledgers with
`benchmarks/compare_bmopf_evidence_ledgers.jl baseline-ledger.json
current-ledger.json [comparison.json]`. The comparison classifies finding
identities as new, resolved, persistent, or distribution-changed and retains
the source paths behind each transition. It also checks case, solver, family,
environment, and selected analysis-budget provenance; incompatible ledgers are
flagged as conditional comparisons rather than silently treated as regressions.
Each new ledger also emits a canonical `campaign_provenance` object and
SHA-256 `campaign_fingerprint`. The fingerprint includes selected cases,
solvers, perturbation families, environment fingerprints, and analysis-budget
values. Missing provenance is reported as unknown; it is never silently
treated as compatible.
Set `NLPDIAGNOSTICS_BMOPF_PERSISTENCE_SUMMARIES` to one or more comma-separated
outputs from `summarize_bmopf_persistence.jl` to include cross-point rank,
nullspace, scaling, mapping, and availability fingerprints in the same
campaign report. Persistence sources remain separate from solver and corpus
finding counts.
Use `NLPDIAGNOSTICS_BMOPF_SOLVER_OPTIONS=max_iter=500,tol=1e-8` for explicit
solver attributes and `NLPDIAGNOSTICS_BMOPF_PER_UNIT=false` to reproduce a
model-native/SI build. Both choices, along with the solver objective convention
and objective-comparison reference, are retained in each JSON record. MadNLP
callback objectives are unscaled before capture so they can be compared with
the recomputed MOI objective; this does not reinterpret the solver's dual or
constraint-residual scaling.
For controlled option campaigns, use
`benchmarks/sweep_bmopf_solver_options.jl`. Set
`NLPDIAGNOSTICS_BMOPF_SWEEP='baseline:;tight_tol:max_iter=500,tol=1e-8;short_limit:max_iter=25'`;
each configuration receives its own evidence directory and summary. The
summary classifies explicit `slow_progress`, `restoration_failed`,
`numerical_failure`, `resource_limit`, and successful terminations while
retaining raw records. This is a diagnostic campaign tool, not a solver
benchmark scorecard.
Run `benchmarks/summarize_bmopf_solver_trace.jl <output-directory>` to produce
`summary.json` with status counts, trace phase/segment statistics, final and
minimum printed residuals, and separate solver-result/BMOPF finding-code
counts. The summary preserves evidence distributions and does not turn
iteration counts or residuals into a single performance score.
Compare two such summaries with
`benchmarks/compare_bmopf_solver_traces.jl ipopt/summary.json
madnlp/summary.json`. The comparison reports iteration, phase, residual, and
objective deltas, marks objective alignment as unavailable/aligned or
`different_convention_or_solution`, and preserves environment-fingerprint
mismatches explicitly rather than attributing them to solver quality. When
logs were captured, it also compares log availability, finding-code sets,
parsed iteration/segment counts, and final printed residuals.

Before choosing a draft-corpus campaign, run
`benchmarks/inventory_bmopf_draft_corpus.jl`. It only parses BMOPF JSON and
records file sizes plus top-level schema-component counts; it neither builds a
JuMP model nor evaluates derivatives. The inventory's coarse counts are
selection metadata, explicitly not a numerical-complexity estimate. This makes
the 30-bus/538-bus distinction inspectable before a campaign is launched.

`benchmarks/summarize_bmopf_smoke.jl` accepts output directories from either
BMOPF runner despite its historical name. Its `summary.json` reports how many
successful cases were dense-rank eligible, skipped by the configured size
policy, structurally screened without numerical work, or from an older record
with unknown eligibility. A skipped dense stage
therefore cannot be mistaken for clean rank evidence during cross-case review.
It also aggregates integrity-preflight error/warning cases and stable
BMOPFTools integrity codes across both successful and failed records. For
profiled cases it additionally aggregates finding severity, domain, confidence,
and evidence-basis distributions, making it possible to see whether a corpus
is dominated by mathematical proofs, numerical observations, or
representational warnings.
For successful profile cases it also aggregates per-stage wall-clock seconds
and allocated bytes (sample count, minimum, mean, and maximum). These are
observations of the diagnostic pipeline, not solver performance scores or
cross-machine benchmarks.

Run `benchmarks/check_benchmark_environment.jl` before a campaign. It is
read-only and reports the active Julia project plus required JuMP, Ipopt, and
BMOPFTools availability (with PowerModels, PowerIO, and MadNLP shown as
optional). It also reports the selected PowerIO C ABI path and whether the
library exists. It
exits nonzero when a required package is missing, so a campaign cannot be
mistaken for a successful run with an incomplete environment.
If the local environment is incomplete, the explicit opt-in
`benchmarks/bootstrap_benchmark_environment.jl` helper creates the ignored
`work/benchmark-environment` project, develops the NLPDiagnostics and sibling
BMOPFTools checkouts into it, instantiates test dependencies (including
PowerIO and MadNLP), and precompiles them. Run preflight and benchmarks with
`--project=work/benchmark-environment`; the library's solver-independent
`Project.toml` remains unchanged.

Both BMOPF runners run BMOPFTools' integrity preflight immediately after
loading a network. Its findings (including stable codes such as
`E.INT.LINE_DIM_MISMATCH`) are preserved in each JSON evidence record, even
when model construction fails. This keeps upstream schema/fixture problems
inspectable and distinct from NLPDiagnostics numerical failures.

Use `benchmarks/compare_bmopf_summaries.jl baseline/summary.json
candidate/summary.json [comparison.json]` to compare two campaign summaries.
The comparison retains case-status changes, finding-code count deltas, stage
timing deltas/ratios, dense-rank availability, and saved-result mapping
changes. Missing stages and unavailable metrics remain `null`; no aggregate
score is synthesized.

For a corpus-wide view, use
`benchmarks/corpus_fingerprint_report.jl campaign-a/summary.json
campaign-b/summary.json [fingerprints.json]`. The report retains each
campaign's case sizes, availability, environment fingerprint, finding-code
counts, and severity/domain/confidence/basis distributions. Its cross-campaign
section identifies recurring codes and evidence attributes without collapsing
them into a quality score.

The draft-corpus runner writes `campaign_manifest.json` with a runner version,
snapshot SHA-256, and campaign fingerprint for every selected case. Set
`NLPDIAGNOSTICS_BMOPF_RESUME=true` to reuse only a matching successful record;
the snapshot bytes, saved-result bytes (when selected), point policy, analysis
mode, and dense-entry budget must all agree. Set
`NLPDIAGNOSTICS_BMOPF_FORCE=true` to rerun the selected cases. Cached cases are
reported as `skipped` in `index.json` and `summary.json`, never as fresh
diagnostic successes.
The manifest and index also retain Julia/package versions, machine metadata,
the NLPDiagnostics git revision, and a reproducibility fingerprint. The
fingerprint participates in resume matching, so changing code or package
versions cannot silently reuse stale evidence.

For a large-network first pass, set
`NLPDIAGNOSTICS_BMOPF_ANALYSIS_MODE=structural` when running
`bmopf_draft_corpus.jl`. This uses the public
`bmopf_build_and_analyze_opf(network; ...)` entry point: it builds and
KCL-finalizes a copied context, then collects generic static/expression/
structural evidence and BMOPF terminal, lifecycle, registry, and component
evidence. It does not create an evaluation point, evaluate derivatives,
materialize a Jacobian, or compute any rank. Its records say
`derivative_evaluation_requested=false` and `dense_rank_analysis_eligible=false`
to distinguish this intentional scope from a size-skipped numerical stage.

BMOPFTools' public `set_opf_start_values!` stage is available for a later,
explicit benchmark policy based on the engine's voltage-start heuristic. Use
`bmopf_set_start_values!(context)` to invoke it intentionally. It mutates only
staged start values and never solves; it may initialize only a subset of model
coordinates. `bmopf_start_completion_point(context; missing_value = 0.0)`
constructs a non-mutating complete point from those exact starts and an
explicit fallback for the remainder. The draft and smoke runners expose this
mixed policy through
`NLPDIAGNOSTICS_BMOPF_POINT_POLICY=bmopf_start_values`. It is not invoked by
NLPDiagnostics automatically: a generated start is an initialization policy
that must be recorded and chosen by the caller, not a neutral observation of
the original model.

The fused BMOPFTools `build_opf_model` recipe already runs its voltage-start
stage. It may still leave non-voltage coordinates without explicit starts, so
the runners' `bmopf_start_values` policy uses the explicit zero-completion
constructor and labels the point accordingly. It must be interpreted as a
mixed engine-start/default-zero probe, never as a physically feasible state or
as the model's observed complete initialization. Run the retained
initialization report to see the original missing-start evidence.
The `missing_value` keyword is required: this API has no implicit fill value.
Its provenance records the fill value, number of filled coordinates, and their
MOI variable indices. The resulting `CompletedInitializationPoint` remains
subject to the physical-confidence guard even when all coordinates are finite.
`bmopf_set_start_values!` is for callers using BMOPFTools' lower-level staged
construction before that stage has run. The optional `prepare_context` callback
in `bmopf_build_and_profile` and `bmopf_build_and_analyze_opf` is a generic
post-build/pre-KCL hook; callers must use only lifecycle stages legal at that
point.

`bmopf_result_voltage_point(context, result; result_units = :si)` maps public
rectangular bus-voltage records plus line, load, generator, voltage-source,
IBR, switch, and ground current records. `result_units=:si` converts physical values through
public per-bus voltage/current bases; `result_units=:pu` and `:model` accept
already-scaled coordinates. The function returns mapped, registered,
unresolved, and fallback counts by semantic family. Coordinates not represented
in the result retain an
explicit fallback, so the point remains a partial-result probe rather than a
claim that the saved solution fully specifies every control or auxiliary
coordinate.

Because BMOPF result files can be mixed-unit exports, callers may override the
global default per semantic family with `field_units`, for example
`field_units = Dict(:bus_voltage => :si, :line_current => :pu,
:ibr_power => :model)`. Supported families are `bus_voltage`, `line_current`,
`load_current`, `generator_current`, `generator_power`, `source_current`,
`ibr_current`, `ibr_power`, `switch_current`, and `ground_current`; omitted
families inherit `result_units`. The normalized
policy is retained in the mapping and report metadata, so the unit convention
used by a numerical probe is inspectable rather than inferred from a filename.

`bmopf_result_mapping_report(mapping)` turns that exact coverage record into
representational findings. A fallback is deliberately a warning about the
benchmark point's provenance, not a claim of model infeasibility or a solver
failure. It further distinguishes registered coordinates absent from the saved
mapping from staged model coordinates that have no public semantic registry
key at all. The draft-corpus runner stores this report alongside the profile, and
the corpus summarizer totals saved-result cases, fallback coordinates, and
unresolved records across the campaign.
For a draft-corpus saved-result profile, the same findings are also appended to
the standard BMOPF context report, so a consumer that reads only the ordinary
context evidence cannot accidentally ignore point-provenance qualifications.

For application code, `bmopf_saved_result_profile_case(name, context, result;
...)` is the corresponding public constructor. It returns the `ProfileCase`,
its exact mapping record, and the coverage report together, so a caller can
pass `item.case` to `bmopf_profile_case` while retaining the qualification
without reimplementing benchmark-runner policy.
`bmopf_profile_saved_result(context, name, result; ...)` is the one-step form
for an already-built staged context: it profiles `item.case` and appends the
mapping report to the regular BMOPF context evidence automatically.

When the staged context is per-unit, saved-result construction also records a
coarse voltage-unit fingerprint. A converted median coordinate magnitude
outside `[0.05, 20]` is a heuristic scaling warning, not a physical-voltage
violation. It is intended to catch a mismatched `result_units` choice before
derivative tolerances and scaling findings are interpreted.

The registry audit also groups unregistered variables by their raw JuMP
construction labels (for example, repeated `umag` auxiliaries). These groups
are deliberately display-only representational provenance: they do not infer a
device type from a variable name, but they make an engine registry gap
inspectable enough to decide whether a stable public key should be added.

BMOPFTools now registers IBR active/reactive apparent-power auxiliaries and
monitored voltage-magnitude auxiliaries with explicit IBR, phase, reference,
and controller identity. NLPDiagnostics treats those as power and voltage
component semantics respectively. The saved-result adapter maps the power
auxiliaries from public `pg/qg` result fields and reconstructs monitored
magnitudes from saved rectangular voltages using the engine-declared neutral
labels and key reference mode. A missing or ambiguous declared reference is
left unmapped; the adapter never guesses from terminal or variable names.

The same public constraint registry now covers AC KCL, line real/imaginary KVL,
ground and source voltage references, monitored-voltage magnitude definitions
and nonnegative bounds, native load real/reactive power equations
(`load_power_real`/`load_power_imag`), source P/Q bounds, generator P/Q bounds,
line current thermal cones, and line apparent-power links/circles when those
declarations are present in the network. Constraint keys retain the device,
bus/terminal, phase, winding, or line-end index as appropriate, so a violated
row can be attributed to an engine equation or operational limit without
relying on a JuMP construction name. Custom model hooks can publish the same evidence with
`BMOPFTools.register_opf_constraint!(ctx, family, index, cref)`; hooks that do
not do so remain explicitly `unregistered_constraint`.

Transformer and n-winding builders use the registry for coil apparent-power
links/circles, current thermal limits, and the principal voltage/current
coupling rows. Keys include transformer id, side/winding, and phase index;
specialized internal branches that are not yet individually named remain
visible as ordinary unregistered rows rather than being guessed from JuMP
construction order.

Benchmark summaries preserve two distinct coverage measures: violated rows
with semantic labels, and all evaluated scalar constraint rows with labels.
The model-wide measure is emitted as `model_constraint_row_count_total`, with
registered/unregistered totals and a family map. This prevents a feasible
saved point from hiding registry gaps and is surfaced by the campaign validator
as `constraint_semantic_registry_model_coverage`.
Solver-trace records additionally retain `bmopf_constraint_semantic_rows`, a
row-number-to-family/index map for the evaluated point. The solver-trace
summarizer uses it to correlate rank-loss, nullspace, and zero-Jacobian-row
evidence with registered equation families without guessing from JuMP names.
Rows also retain the JuMP construction name when one exists, strictly as
debugging provenance; semantic classification continues to come only from the
public BMOPFTools key.

On the regenerated 30-bus LN controller fixture, this map covers all 844 scalar
rows: 240 KCL, 232 line KVL, 112 monitored-voltage definition/bound, 280 native
device/control, and 8 voltage-reference rows. Other formulations remain subject
to the model-wide coverage gate; this fixture result is not generalized to
custom hooks, DC models, or an untested transformer subtype.

The adapter accepts `result_units=:si` for physical SI values and
`result_units=:pu` (or the backward-compatible `:model`) for already-scaled
per-unit/model coordinates. The draft corpus runner exposes this adapter as
`NLPDIAGNOSTICS_BMOPF_POINT_POLICY=saved_result`. By default it reads the
adjacent `_result_si.json` file. Set
`NLPDIAGNOSTICS_BMOPF_RESULT_UNITS=pu` to select the adjacent `_result_pu.json`
files, or use `NLPDIAGNOSTICS_BMOPF_RESULT_SUFFIX=...` for another explicit
schema. Its JSON record persists the mapping coverage and exact result path,
making any fallback visible in a benchmark comparison. The smoke summarizer
also aggregates unresolved saved-result records by exported family, so a
repeated `ci_to`/`cr_to` boundary is distinguishable from case-specific loss.

To inspect whether the SI and PU files themselves use a consistent convention,
run `benchmarks/compare_bmopf_saved_result_units.jl <benchmark-root>`. It
compares paired numeric leaves and reports observed `PU / SI` magnitude ratios
by exported field family. This is an evidence report, not a conversion rule:
the 30-bus snapshots, for example, keep bus-voltage magnitudes near ratio one
but scale `line/s_through` by roughly `1e-6`, while several auxiliary families
are mixed. Use this before treating a result suffix as a homogeneous model-unit
declaration.

The corpus runner accepts the same explicit policy through
`NLPDIAGNOSTICS_BMOPF_RESULT_FIELD_UNITS`, using comma-separated
`family=unit` entries (for example
`bus_voltage=si,line_current=pu,ibr_power=model`). The policy is included in
case fingerprints and saved-result metadata, so changing it cannot silently
reuse an incompatible cached profile.

To compare the numerical consequences of two saved-result policies, run
`benchmarks/compare_bmopf_saved_result_profiles.jl <left-campaign>
<right-campaign> [output.json]`. It aligns records by snapshot and reports
per-case and aggregate deltas for finding codes, constraint-feasibility
violations, scale warnings, mapping coverage, and the unit fingerprint. Set
`NLPDIAGNOSTICS_BMOPF_UNIT_RATIO_REPORT` to the paired SI/PU leaf comparison so
the motivating field-ratio evidence is retained beside the profile comparison.
Positive deltas mean the right campaign produced more findings; this is not a
quality score and does not certify either policy.

For repeatable policy experiments, `benchmarks/launch_bmopf_result_policy_matrix.jl`
runs isolated `si`, `pu`, `pu_bus_si`, and `pu_all_si` child campaigns (or a
subset selected with `NLPDIAGNOSTICS_BMOPF_POLICY_MATRIX`). Its manifest keeps
the exact policy, process status, timeout, and output directory for each run.
Set `NLPDIAGNOSTICS_BMOPF_POLICY_RESULT_SUFFIXES` to override the adjacent
saved-result suffix for an individual child (for example,
`pu_all_si=_result_si.json`). This separates a conversion-policy effect from a
difference between the SI and PU files themselves.
`benchmarks/summarize_bmopf_result_policy_matrix.jl matrix_index.json` then
materializes every pairwise comparison under the matrix directory and emits a
single summary containing derivative-rank fingerprints, controller crosswalks,
and finding deltas.
The launcher manifest now records each child corpus index, case-status counts,
child environment fingerprint, and resolved result-unit policy. Validation
flags failed children, missing child indexes, empty case sets, and mixed
environments before policy deltas are interpreted.
The matrix summary now carries that provenance forward with explicit readiness
flags for child success, index completeness, environment compatibility,
pairwise coverage, and controller observations.
The same matrix has been smoke-tested on representative 99-bus and 538-bus
LN cases with dense analysis disabled; SI and `pu_all_si` produced matching
feasibility and sparse-rank fingerprints in both cases.
That agreement is not a corpus-wide conclusion: the full 30-bus LN/LG sweep
covered 50 paired snapshots and found 14 cases with nonzero feasibility deltas
(187 aggregate additional violations under `pu_all_si`). Use the paired
comparison and validation report as the evidence boundary; investigate the
affected exported fields before treating either policy as interchangeable.
Run `benchmarks/validate_bmopf_campaign.jl` on the resulting campaign or
comparison summaries before interpreting them. It reports separate readiness
gates for generic observations, saved-result mapping, dense rank, physical
component rank, and paired-policy alignment; a warning means unavailable or
conditional evidence, not a solver failure. It also validates bounded
Ipopt/MadNLP matrix summaries for successful child processes and paired trace
records. When `NLPDIAGNOSTICS_BMOPF_UNIT_RATIO_REPORT` is supplied, each paired
case also retains its nontrivial field-family ratio fingerprints, so a policy
delta can be inspected alongside the exported fields that differ in scale.
Profile records now include a `point_trust` object, and the corpus summarizer
aggregates selected/rejected trusted-point coverage. The validator exposes this
as `trusted_solver_point_coverage`; incomplete coverage remains a warning and
keeps the campaign useful for initialization-scoped numerical observations,
but blocks physical or cross-case claims that require complete solver points.

Solver-trace campaigns apply the same boundary to their final solver result
and to optional callback iterates. Metric-only traces remain valid when
callback coordinates were not requested, while physical or cross-case claims
require one complete finite solver-result point for every successful case.
The trace runner also sanitizes NaN/Inf values at its JSON boundary, retaining
the associated failure metadata instead of dropping the entire benchmark
record.
The trace preflight also classifies source-schema losses using the same policy
as the multiconductor campaign: representational unit losses are retained as
context, while device-semantic and physical/operating-point losses block the
`physical_metadata_complete` readiness gate until explicitly mapped.

The isolated solver-trace launcher makes the in-place NLPDiagnostics package
visible to BMOPFTools child processes and records native child-wait errors.
Size-guard-only campaigns therefore remain build evidence and are not treated
as successful solver observations.
The v2 launcher writes the manifest after each child, so a later native exit
cannot erase completed case records.
The trace summarizer also retains process-health evidence for children that
produce no result JSON: exit, timeout, wait-error, and process-log counts are
reported separately. The validator exposes `solver_process_health` and emits
an explicit process-exit finding, keeping native crashes distinct from solver
termination statuses.
The saved-result SI/PU policy matrix follows the same rule: children inherit
the local checkout, wait failures are preserved, and `matrix_index.json` is
updated after each policy. The policy summary and validator expose
`policy_process_health` before allowing pairwise unit-policy interpretation.
The Ipopt/MadNLP solver matrix now uses the same incremental manifests and
process-health checks. Readiness requires each solver to produce at least one
successful trusted solver-result profile; a native MadNLP exit remains an
explicit matrix failure rather than being compared as an empty solver trace.

Constraint-row semantics now key MOI constraints by integer index, function
type, and set type. This prevents unrelated constraint types with the same
integer value from overwriting one another. In the fresh 30-bus trace, all 28
Volt-var and 28 Volt-watt constraints are registered and every observed
controller violation crosswalks successfully. After the subsequent native-row
registry pass, the same fixture has 844 registered rows and zero unregistered
rows; other formulations still pass through the explicit coverage gate rather
than inheriting that result by assumption.

Saved-result controller crosswalks also match quoted component index fields,
so identifiers such as `pv_1` and `pv_10` cannot alias. The regenerated SI/PU
pair retains 56 registered violation matches with no semantic-registry
boundary; the numerical residual delta remains a policy observation.

In the first registry-aware 30-bus LN/LG SI-versus-PU run, both children
completed under one environment fingerprint and each retained 56 finite exact
controller observations. PU produced 28 Volt-var residual and 28 Volt-watt cap
exceedances per snapshot while SI produced none. The violating observations
cross-referenced 24 registered rows and left 88 unmatched across the two
snapshots. This is a numerical/registry boundary for follow-up, not evidence
that either policy is physically correct or causally responsible by itself.
Extending the same campaign to `pu_bus_si` and `pu_all_si` localized the
effect: `pu_all_si` matched SI with zero controller residual/cap deltas, while
`pu_bus_si` removed LG violations but left five LN Volt-var residual
exceedances, three unmatched and two registered. Plain PU retained the full
56-residual/cap delta across the pair. This supports a field-unit/export
hypothesis for follow-up, not a causal diagnosis.
The additional LN/LG t02--t03 campaign reinforces the distinction: `pu_all_si`
again matches SI, while `pu_bus_si` retains 112 Volt-watt cap exceedances and
14 Volt-var residual exceedances. The latter concentrate in LN t03; its
combined violations include eight registered and 34 unmatched crosswalk
observations. Plain PU retains the full 28-per-snapshot residual/cap pattern.
The paired field-ratio report for these snapshots also shows `line/s_through`
near 1e-6 in PU/SI magnitude and mixed-scale `ibr/pg`, `ibr/cri`, and `ibr/cii`
families. Those ratios are preserved beside the policy comparisons as
attribution evidence, not as a unit-convention verdict.
The next scale-up is a four-policy matrix on one 99-bus LN and one 99-bus LG
snapshot, again with dense rank disabled. All four children completed under a
single environment fingerprint and complete child indexes. Relative to SI,
plain PU added 96 controller equation-residual violations and 96 cap
violations across the pair. `pu_bus_si` removed the cap delta but retained 43
equation-residual violations, while `pu_all_si` matched SI for both controller
counts. The campaign validator reports these as policy-delta warnings, not as
proof of a formulation or export cause.
The 99-bus semantic-row crosswalk was available for all 24 controller
snapshots; 207 violating observations matched registered rows and 498 were
unmatched. The latter is an explicit representational boundary for the
multiconductor plugin rather than evidence that the unmatched rows are
physically wrong. Field ratios show `line/s_through` near 1e-6 PU/SI,
mixed-scale `ibr/pg`, `ibr/cri`, and `ibr/cii`, and policy-dependent multiplier
ratios; retain the ratio report alongside every interpretation.
The bounded 538-bus extension is now complete. The timed-out `pu_all_si`
child was rerun with a larger explicit budget; all four children now have
complete indexes and one shared environment fingerprint. Validation is
warning-only because the semantic crosswalk still has unmatched rows. Plain
PU adds 604 controller residuals and 604 cap violations relative to SI,
`pu_bus_si` removes the cap delta but leaves 402 residuals, and `pu_all_si`
matches SI for both controller counts. The ratio report retains
`line/s_through` near 1e-6, mixed line-current/IBR scales, and large
shadow-price/multiplier ratios, with dense rank intentionally skipped.

The first paired solver-policy matrix is complete on a 30-bus LN snapshot.
Ipopt and MadNLP both terminated successfully under one environment
fingerprint, requiring 19 and 21 iterations respectively, with aligned final
objective and residual scales. Ipopt supplied 16 controller callback snapshots
with 58 Volt-var residual exceedances; MadNLP's public callback supplied
solver metrics but no primal iterate bindings. The solver summary and
validator retain that asymmetry explicitly rather than treating missing
MadNLP point data as zero controller evidence.
Repeating the matrix on matched LN/LG snapshots produced four successful
children under the same fingerprint: Ipopt used 19 iterations on both cases,
while MadNLP used 21 (LN) and 22 (LG). Final objectives stayed aligned below
4e-9 relative difference. Ipopt retained 58 Volt-var residual exceedances on
each case; MadNLP remained metric-only, so these are repeatable trace
observations with asymmetric controller coverage, not a solver-quality score.

For time-series evidence on one staged formulation, use
`benchmarks/bmopf_saved_result_persistence.jl`. It maps multiple saved results
into one context and reports cross-point Jacobian-rank, nullspace-alignment,
scaling, component-rank persistence, and the component expected-rank capability
report. With a zero dense budget it records
availability limits explicitly; for a small case, increasing
`NLPDIAGNOSTICS_BMOPF_PERSISTENCE_MAX_DENSE_ENTRIES` enables the actual local
rank comparison.
The persistence summarizer retains capability findings separately from
numerical rank fingerprints, and the campaign summarizer aggregates them in a
separate capability namespace.
The guarded 538-bus two-point run mapped all 11,028 coordinates at both
points while reporting rank persistence as unavailable under the zero dense
budget, which is the intended large-model behavior.
Persistence records also include per-point active-set screens, including
active-row counts and LICQ/MFCQ, feasibility, and active-DM fingerprints. These
remain separate observations because the active set can change even when the
equality-Jacobian rank is stable.
The persistence summarizer additionally reports active-row intersection,
union, and transition counts, preserving the row-scope change explicitly.
It also aggregates typed controller observations across mapped points,
retaining exact/proxy coverage, family/status distributions, local-slope and
breakpoint-distance statistics, residual/cap exceedance counts, and the
explicit saved-result registry boundary.
Persistence runs now retain the scalar semantic-row map from the staged model;
the controller campaign summary reports registered versus unmatched residual
crosswalks alongside the time-series fingerprint.
In the guarded 538-bus two-point run, 10,120 active rows were common to both
points and 11,330 appeared in the union; dense active-block rank remained
explicitly unavailable under the large-model budget.

Set `NLPDIAGNOSTICS_BMOPF_INCLUDE_FLOATING_NEUTRAL_CANDIDATES=true` on a
structural or profile corpus run to retain BMOPFTools' explicit floating-neutral
candidate modes. These are physical expectations attached to the report; they
are not automatic claims that the observed Jacobian has those null directions.

The solver-trace runner also supports controlled model-level family
perturbations. Set `NLPDIAGNOSTICS_BMOPF_RUN_FAMILY_PERTURBATIONS=true` and
select families with
`NLPDIAGNOSTICS_BMOPF_PERTURBATION_FAMILIES=load,generator,ibr`; each selected
family is rebuilt through an explicit no-op `OpfDeviceBuilder`, KCL is then
re-enforced, and the variant is solved independently. Use
`NLPDIAGNOSTICS_BMOPF_PERTURBATION_MAX_ITER` to bound variant work. The output
retains baseline and per-family status, termination, iteration, semantic-row,
and numerical-profile evidence. These variants deliberately represent
formulation perturbations, not valid physical network models, so differences
are causal tests of the formulation fingerprint only.

Controller evidence is now part of the validation/evidence-ledger boundary.
`validate_bmopf_campaign.jl` recognizes controller campaign summaries, saved
result controller snapshots, solver-trace controller summaries, and paired
trace comparisons. It emits separate findings for missing typed coverage,
non-finite or invalid observations, proxy monitored-voltage semantics, and
status/coverage/slope transitions. Exact finite coverage is a readiness gate;
transitions remain local numerical evidence and are not treated as a physical
diagnosis. `summarize_bmopf_evidence_ledger.jl` retains these validation
findings under their controller or trace scopes, so they remain inspectable and
recurrence can be compared without turning it into a score.
Solver-trace summaries now retain transition-level records keyed by iteration
and phase, pairing controller slope, breakpoint-distance, and curve-residual
deltas with solver primal/dual infeasibility deltas. Paired trace comparisons
carry these records alongside coordinate-unit conventions; the validator emits
an informational residual-alignment finding to make the association explicit
without claiming causality.
Controller campaign and trace summaries also count device-level Volt-var
equation residuals and Volt-watt cap violations against the declared tolerance,
with affected component/family keys retained. In the current artifacts both
five-point LN/LG persistence campaigns have zero such violations, while the
model-native LG Ipopt trace has six Volt-var residual exceedances localized to
six `ibr:pv_*:volt_var` curves. This is a coordinate-conditioned numerical
observation; it is not yet evidence of a faulty device or a causal unit error.
Solver-trace controller violations now cross-reference the BMOPFTools semantic
row map by component and curve family. An older model-native LG artifact had
two of six residual-bearing curves matched to registered `ibr_q_volt_var` rows
and four unmatched; that preserved result remains a registry-coverage boundary.
Fresh traces built after the typed-MOI and engine-registry fixes must be used
before interpreting that historical mismatch as current behavior.
Paired solver-trace comparisons now summarize registry coverage on both sides.
For the matched LG coordinate comparison, the per-unit trace has no residual
crosswalk entries, while the model-native trace has two registered and four
unmatched Volt-var curves. The validator reports both the coverage difference
and the unmatched-component boundary, keeping policy comparisons explicit about
semantic coverage as well as numerical scale.
Solver-matrix summaries now aggregate these controller crosswalks across all
paired solver cases, retaining per-side registered/unmatched counts and
component identities. The same matrix validation gate flags a registry
boundary without collapsing it into a solver or model-quality score.
Saved-result policy comparisons now carry the same controller evidence
boundary. New draft-corpus profile records also retain the BMOPFTools scalar
constraint semantic-row map, allowing residual-bearing controller devices to
be cross-referenced when the registry is available. Each paired record retains
exact/proxy monitor counts, status and
monitor-semantics distributions, curve-family counts, local-slope and
breakpoint-distance summaries, equation-residual exceedances, and Volt-watt
cap violations. The policy-matrix summary aggregates these deltas and keeps
the affected transition cases. Older saved-result records without the semantic
map remain explicitly unavailable rather than being inferred.

The generic operator/domain corpus is also available independently of BMOPF
through `benchmarks/operator_fingerprint_smoke.jl`. It exercises registered
operator semantics and explicit starts for `log1exp`, `log`, `atan`, `atan2`,
non-unit circular equalities, and `logdiffexp`. Use
`benchmarks/summarize_operator_fingerprint.jl` followed by
`benchmarks/validate_bmopf_campaign.jl` to normalize and trust-gate the
result before adding it to `summarize_bmopf_evidence_ledger.jl`.
