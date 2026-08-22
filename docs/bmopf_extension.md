# BMOPFTools staged-OPF extension

`NLPDiagnostics` integrates with BMOPFTools in two layers.

- `bmopf_terminal_report(net)` translates BMOPFTools' public terminal and
  grounding analysis into physical findings. It does not claim that a compiled
  JuMP model has a corresponding Jacobian nullspace.
- Staged-OPF entry points use BMOPFTools' public model, network, lifecycle,
  base, and semantic-registry APIs. They do not inspect private builder state
  or infer component semantics from variable names.

The scaling adapter also consumes BMOPFTools' semantic coordinate and residual
blocks. It currently has engine-verified physical contracts for ordinary AC
line/load models, single-phase and wye-delta transformers, general n-winding
transformers, and an AC/DC converter tie. Transformer coil-power auxiliaries
created during constraint construction receive stable public registry keys;
they are not recovered from generated JuMP names. Normalized thermal and
apparent-power rows are explicitly dimensionless even though their coordinate
blocks retain current or power units. `bmopf_block_scaling_covariance_report`
requires complete point, set, residual, and sparse-Jacobian agreement before it
labels two policies physically equivalent.

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

`benchmarks/bmopf_smoke.jl` is an opt-in six-fixture starter corpus for the
BMOPFTools `pf_comparison` OpenDSS data. It exercises grounded and free neutral
returns, an unbalanced four-wire feeder, a delta load, a ZIP load, and a
wye-delta transformer. Set `NLPDIAGNOSTICS_BMOPF_FIXTURE_ROOT` to the corresponding
BMOPFTools fixture directory before running it. Its output is deliberately a
compact discovery summary and it writes one full JSON evidence record per case
plus `index.json`. Set `NLPDIAGNOSTICS_BMOPF_OUTPUT_DIR` to choose the output
directory; failures are retained as case-level JSON records so one failed build
does not hide the remaining corpus.
Set `NLPDIAGNOSTICS_BMOPF_CASES` to a comma-separated subset such as
`delta-load,wye-delta-transformer` when iterating on one diagnosis.

BMOPFTools two-terminal `SINGLE_PHASE` loads expose one complex branch-current
coordinate, not one coordinate per terminal. The BMOPF extension preserves the
two terminal semantics with connection incidence `[+1, -1]`; its coordinate
map back to the model variable is `[0.5, -0.5]`. Consequently, a phase-to-phase
load remains a two-terminal port while contributing only one independent real
and one independent imaginary current coordinate. Treat any additional
disconnected current coordinate for this topology as a representational
construction defect, not as a physical circulation mode.

The default `NLPDIAGNOSTICS_BMOPF_POINT_POLICY=initialization` requires complete
caller-provided starts. Set it to `zero` only to use the explicit synthetic
zero-coordinate probe; that probe never writes starts and must not be
interpreted as a physically meaningful voltage initialization.
Set it to `bmopf_start_values` for BMOPFTools' partial voltage initialization
completed by explicit zeros, or to `ipopt_result` for a public Ipopt result
point obtained from that same completed start. The latter keeps
`add_objective=false`, so the solved-point calibration changes the evaluation
point and solver attachment without changing the feasibility formulation.
Each case records solver name, option values, elapsed time, termination,
primal/dual status, result count, start and result fingerprints, and point
availability. The bounded solve is controlled by
`NLPDIAGNOSTICS_BMOPF_POINT_SOLVER_MAX_ITERATIONS` (default `500`) and
`NLPDIAGNOSTICS_BMOPF_POINT_SOLVER_TOLERANCE` (default `1e-8`). A result point
is calibration evidence only when extraction succeeds and the public primal
status is `FEASIBLE_POINT`.
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

The smoke runner also exposes the independent dense-free smallest-direction
crosscheck as an opt-in calibration stage. Set
`NLPDIAGNOSTICS_BMOPF_SMALLEST_CROSSCHECK_DIMENSION` to a positive candidate
dimension; zero or an unset value disables it. Its bounded work controls are
`NLPDIAGNOSTICS_BMOPF_SMALLEST_CROSSCHECK_RESTARTED_ITERATIONS` (default 50),
`NLPDIAGNOSTICS_BMOPF_SMALLEST_CROSSCHECK_HARMONIC_STEPS_PER_SEED` (6),
`NLPDIAGNOSTICS_BMOPF_SMALLEST_CROSSCHECK_HARMONIC_CYCLES` (8), and
`NLPDIAGNOSTICS_BMOPF_SMALLEST_CROSSCHECK_MAX_BASIS_ENTRIES` (1,000,000).
This stage uses Jacobian products and remains independent of the dense-entry
budget. Each case records availability, convergence of both engines, their
classified relation, relative candidate-value differences, and principal-angle
evidence. The aggregate summary and campaign validator distinguish unavailable
work, backend nonconvergence, and actual value/subspace disagreement. Agreement
is candidate-screen evidence; it is not a rank or nullity certificate.

For small representative fixtures only, set
`NLPDIAGNOSTICS_BMOPF_SMALLEST_CROSSCHECK_DENSE_CALIBRATION=true` together
with a positive `NLPDIAGNOSTICS_BMOPF_RANK_MAX_DENSE_ENTRIES`. The profile then
runs guarded dense-SVD comparisons for both candidate engines under the same
search budgets and records each engine's oracle relation, dense target values,
relative value errors, and principal-angle evidence. The dense-entry guard is
checked independently for each calibration; requesting this option never
authorizes unbounded densification.

`benchmarks/compare_bmopf_multiconductor_points.jl` carries the same evidence
across point policies. It reports availability, convergence, relation changes,
candidate-value-difference changes, and principal-angle changes only when the
underlying evidence exists. Keep candidate dimension and work budgets fixed
when using this comparison to study initialization sensitivity.

For same-point work-budget calibration, use
`benchmarks/compare_bmopf_multiconductor_crosschecks.jl`. It requires compatible
environment fingerprints, identical point policies, aligned candidate
dimensions, and distinct recorded work policies. The artifact counts restarted
and harmonic convergence gains/losses, agreement gains/losses, and relation
changes while retaining per-case value-difference and principal-angle deltas.
This is the appropriate comparison for deciding whether an unconverged BMOPF
screen merely needs more bounded work; it still does not establish rank.

The smoke runner also exposes the rank-revealing sparse-QR nullspace path. Set
`NLPDIAGNOSTICS_BMOPF_SPARSE_QR_NULLSPACE=true`; select `none`, `row`, `column`,
or `row_column` with
`NLPDIAGNOSTICS_BMOPF_SPARSE_QR_NULLSPACE_SCALING`. Resource controls are
`NLPDIAGNOSTICS_BMOPF_SPARSE_QR_NULLSPACE_MAX_INPUT_NONZEROS`,
`NLPDIAGNOSTICS_BMOPF_SPARSE_QR_NULLSPACE_MAX_FACTOR_NONZEROS`, and
`NLPDIAGNOSTICS_BMOPF_SPARSE_QR_NULLSPACE_MAX_ENTRIES`. Small representative
fixtures may additionally set
`NLPDIAGNOSTICS_BMOPF_SPARSE_QR_NULLSPACE_DENSE_CALIBRATION=true`; this still
obeys `NLPDIAGNOSTICS_BMOPF_RANK_MAX_DENSE_ENTRIES`.

The multiconductor summary records QR rank/nullity, direct original-coordinate
residuals, orthogonality, fill, and the dense-oracle relation. Use
`benchmarks/compare_bmopf_sparse_qr_nullspaces.jl` for a same-point comparison
of two explicit policies. It checks fixture, environment, and point alignment
and retains rank/nullity, residual, fill, and dense-subspace deltas. Different
scalings define different pivot metrics, so stable rank and mapped-subspace
agreement are the relevant intervention evidence; raw scaled pivots are not
physical conditioning improvements.

For persistence experiments, set
`NLPDIAGNOSTICS_BMOPF_SPARSE_QR_PERSISTENCE_REPEAT_COUNT` to zero or at least
two and provide optional symmetric relative radii through
`NLPDIAGNOSTICS_BMOPF_SPARSE_QR_PERSISTENCE_RADII`, for example
`1e-8,1e-6`. The deterministic direction is selected by
`NLPDIAGNOSTICS_BMOPF_SPARSE_QR_PERSISTENCE_DIRECTION_SEED`; coordinates use
`max(abs(x), 1)` as their perturbation scale. These points carry
`PerturbedPoint` provenance and are not claimed feasible, trusted solver
iterates, or alternate solutions. The alignment gate is controlled by
`NLPDIAGNOSTICS_BMOPF_SPARSE_QR_PERSISTENCE_ALIGNMENT_THRESHOLD`.

The BMOPFTools adapter projects declared component-port and topology candidates
into model coordinates, groups persistent leverage by explicit voltage/current
port maps, and consults the source-schema restoration gate before emitting any
physical interpretation. It also crosschecks persistent support with generic
`disconnected_variable` facts. Thus unused compiled coordinates can be
classified as representational freedoms even when they numerically dominate a
nullspace that was initially suspected to be physical.

For a pre/post formulation change, use
`benchmarks/compare_bmopf_formulation_interventions.jl`. The comparator pairs
fixtures by name and source SHA-256, requires identical evaluation-point,
sparse-QR, and repeat/nearby policies, and records variable/row/rank/nullity
and disconnected-support deltas. It distinguishes an available numerical
comparison from a causal-ready intervention. The latter additionally requires
two distinct clean BMOPFTools revisions; a dirty checkout or an unrecorded
dependency revision remains useful development evidence but cannot support a
causal claim.

Benchmark environments now retain source states for both NLPDiagnostics and
BMOPFTools: Git revision, dirty flag, and a fingerprint of tracked and
untracked changes. Multiconductor summaries also retain compact
`numerical_profile` and `initialization_profile` records per fixture. These
include the sparse-QR condition proxy and factorization residual, evaluation
and derivative issue counts, start-point provenance, feasibility-violation
count, and maximum violation. The condition proxy is a factorization-local
screen, not a normwise condition-number estimate.

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
benchmark scorecard. The trace option parser preserves string attributes as
ordinary `String` values and promotes Ipopt real-valued options such as `tol`
and `nlp_scaling_max_gradient` to `Float64`; this avoids confusing an option
typing failure with a solver numerical failure. A common
`NLPDIAGNOSTICS_BMOPF_SOLVER_OPTIONS` value is merged into every sweep
configuration, while per-configuration keys override it; this makes bounded
iteration/time policies explicit and reproducible.
The sweep manifest is persisted after each configuration as well as at normal
completion, so a native child failure leaves earlier configuration provenance
available for review.
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
For a complete option sweep, run
`benchmarks/summarize_bmopf_solver_sweep.jl <sweep-manifest.json>`. The resulting
`sweep_summary.json` keeps the effective option string for every configuration,
checks environment and case-matrix completeness, and compares each candidate
to the declared baseline. It preserves per-case iteration deltas, printed
primal/dual residuals, objective alignment, solver finding codes, and
row-family scaling-proxy/rank changes; it intentionally emits no composite
solver score.
Each case also writes a small `<case>.checkpoint.json` progress marker. Its
phases (`started`, `solver_complete`, `profile_started`, `complete`, or
`error`) make a resource-limited post-solve run inspectable; a solver log that
reaches an optimal exit without a `complete` marker is not treated as a
complete diagnostic record. The isolated launcher propagates that marker into
the index, and the trace summarizer classifies a missing result after
`solver_complete` or `profile_started` as `profile_incomplete_after_solver`,
with separate profile-completeness counts.
For large cases, set `NLPDIAGNOSTICS_BMOPF_PROFILE_MAX_VARIABLES` to an explicit
profile budget. Cases above that limit use the solver-only trace path and are
written with status `ok_solver_trace_profile_skipped`; their solver/log/trace
evidence remains available, while the expensive BMOPF semantic and rank
profile is recorded as `profile_skipped_resource_budget` rather than being
silently inferred as clean.
Row-family residual capture depends on bound solver-iterate points. The source
matrix launcher therefore rejects
`NLPDIAGNOSTICS_BMOPF_SOURCE_SOLVER_CAPTURE_ROW_RESIDUALS=true` unless
`NLPDIAGNOSTICS_BMOPF_SOURCE_SOLVER_CAPTURE_POINTS=true` is also explicit.

For a paired multiconductor option campaign, set
`NLPDIAGNOSTICS_BMOPF_OPTION_CAMPAIGN_SCOPE=multiconductor` and use
`benchmarks/launch_bmopf_solver_option_perturbations.jl`, followed by
`benchmarks/summarize_bmopf_solver_option_perturbations.jl`. Use the `context`
profile stage and keep the dense rank budget at zero for the first pass. The v4
summary retains model variable count, structural BMOPF context metadata, and
the source behavior contract as a per-cell semantic fingerprint. Context
finding counts are retained separately because some findings are conditioned
on the solver endpoint and are therefore outcomes rather than model-build
invariants. A multiconductor
stability observation is promotable only when those contracts are complete and
invariant across every same-case, same-budget, same-initialization comparison.
This gate detects harness or model-build drift; it does not prove that the
source semantics themselves are correct.
Set `NLPDIAGNOSTICS_BMOPF_PROFILE_STAGE=trace` to request the solver-only
stage, `context` to add BMOPF semantic/context diagnostics, or `numerical` to
evaluate and analyze the solver-result Jacobian under the configured dense
entry budget. The default stage remains `full`; stage selection and budget
decisions are retained in the case record and sweep metadata.
The sweep summarizer promotes numerical-stage records into a separate
`numerical` comparison block. It reports dense-rank and sparse-QR availability,
raw rank deltas, rank-readiness transitions, and new/removed numerical finding
codes. Its top-level `numerical_stage_coverage` counts available reports,
sparse-QR reports, dense-rank reports, explicit dense-budget unavailability,
stage/readiness distributions, and finding-code recurrence. A missing dense
rank is therefore visible as an availability boundary and is never compared as
zero rank or folded into a solver score.
For repeated policy campaigns, pass two or more sweep manifests to
`benchmarks/summarize_bmopf_solver_repeats.jl`. It aligns configuration/case
records by manifest index, summarizes termination/status/iteration and sparse
rank recurrence, and reports paired candidate-minus-baseline deltas. It also
retains numerical-readiness transitions and environment fingerprints, so a
solver-policy effect is only described as repeated when the same explicitly
identified configuration/case pairs were observed more than once.
For staged (`trace`, `context`, or `numerical`) records, termination is taken
from the solver-owned log marker when a full solver postmortem is intentionally
not materialized. This preserves `locally_optimal`, iteration-limit, and
restoration evidence without pretending that the lightweight stage provides a
full result profile.
For large models this is the recommended first pass: use `trace` for repeated
solver-policy experiments, inspect termination and residual evidence, and only
enable sparse numerical profiling in a separately budgeted campaign.
Repeat comparisons also retain final primal/dual residual deltas and semantic
family availability. A trace-only campaign therefore can show a repeatable
solver/residual effect while explicitly reporting that equation-family
correlation is unavailable until a context-stage profile is run.
Context-stage repeats additionally compare finding-code identities. Differences
at iteration-limit points should be read as endpoint-conditioned observations;
they are not evidence that component metadata or physical scales changed.

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

The subsequent fixture-diversity pass applies an exact JuMP-constraint-index
cross-check to constant-impedance and constant-current ZIP loads, all existing
two-winding transformer subtype fixtures, a three-winding transformer, and both
shared-bus and resistive-branch DC converter networks. These fixtures now have
zero unregistered native rows. The added semantic families cover load-voltage
auxiliary definitions and bounds, n-winding ampere-turn and leakage equations,
DC branch/port/control/KCL equations, IBR current and DC-link limits, and native
variable bounds. The rare-path pass additionally covers DC droop, explicit DC
sources and loads, oriented DC voltage bands, transformer thermal and
apparent-power auxiliaries, and switch thermal auxiliaries. Late current-box
bounds are synchronized into the registry before KCL finalization. This remains
fixture-local evidence; each new formulation and caller extension still needs
its own coverage report.

Use `bmopf_constraint_registry_coverage_report(context, evaluation)` when the
coverage result itself must be persisted as diagnostic evidence. The report is
informational when every evaluated row is registered and a representational
warning otherwise. It gives exact uncovered row numbers and optional JuMP names
but does not infer semantics or ownership from those names. A plugin constraint
becomes semantically attributable only after the plugin registers it through
the public BMOPFTools API. Corpus and solver-trace benchmark artifacts now store
this report under `bmopf_constraint_registry_coverage`; smoke and campaign
summaries prefer it over the older feasibility-attribution coverage counters.

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

For the staged IVR formulation, exported line `cr_to`/`ci_to` values are
derived result records rather than additional model coordinates when the
public registry owns the corresponding from-side current pair. The adapter now
records this as an explicit projection contract, with projected record counts
and contract text. It does not count those records as unresolved mapping loss.
This contract says only why no coordinate is expected; checking whether the
derived export is numerically consistent with the mapped state remains a
separate residual task.

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

For an explicit repeatability and point-persistence calibration, run
`benchmarks/launch_bmopf_point_calibration.jl`. By default it profiles the
engine start, the adjacent SI saved result, and the adjacent PU saved result
twice each in isolated Julia processes. Select a smaller policy set with
`NLPDIAGNOSTICS_BMOPF_CALIBRATION_POINTS=engine_start,saved_si`, set the repeat
count with `NLPDIAGNOSTICS_BMOPF_CALIBRATION_REPETITIONS`, and use the ordinary
BMOPF case selectors. Dense rank analysis defaults to disabled in this launcher.

Run `benchmarks/summarize_bmopf_point_calibration.jl
<calibration_index.json>` to compare exact finding identities. Static,
expression, and reformulation reports are checked as point-invariant stages;
numerical, active-set, and degeneracy changes are reported as local evidence.
The summary retains repeated point fingerprints, registry coverage, saved-result
mapping completeness, provenance, environment fingerprints, and the dense-work
budget. Pass its output to `benchmarks/validate_bmopf_campaign.jl` before using
the observations in the evidence ledger. A stable local finding is empirical
persistence across the sampled points, not a global or physical proof.
Same-point readiness requires both one exact point fingerprint and identical
finding identities in every report stage across repetitions.
For multi-case runs, the summary also derives LN/LG bus-count strata and emits
`cross_case_change_recurrence`. Each entry preserves the exact finding identity,
stage classification, affected cases and strata, count direction, and aggregate
delta. Recurrence remains descriptive evidence and is never converted into a
model-quality score.
Curated numerical metrics are calibrated separately from finding identities.
The report retains full-Jacobian rank and sparse-QR agreement, active-set rank
and DM dimensions, equality-rank/MFCQ metadata, and aligned degeneracy ranks.
It requires exact same-point metric recurrence and reports recurring
start-to-saved transitions under `cross_case_metric_change_recurrence`.
Unchanged metrics are retained separately under
`cross_case_metric_persistence`, so stable full-Jacobian rank evidence does not
disappear merely because only deltas are findings.
Metric extraction is capability-gated. For example, a stored rank sentinel is
excluded when `jacobian_rank_available=false`; the availability flag itself is
retained. This prevents a skipped dense analysis from being reported as a
rank-zero observation.

Current profile records also contain
`bmopf_jacobian_row_family_scale_attribution`. This is built from the public
BMOPFTools constraint registry and the evaluated Jacobian, never from JuMP
constraint or variable names. For every declared equation family it retains
the row count, combined sparse-entry count, zero/non-finite/unavailable counts,
row infinity-norm quartiles and extrema, within-family spread, and whether the
family owns either global row-scale extreme. A small explicit mapping groups
known public constraint-family prefixes into component families; unknown
families remain `unclassified` instead of being guessed.

The v2 point-calibration summary requires exact same-point recurrence of this
evidence and compares it across points. Exact value transitions are stored in
`cross_case_row_family_scale_recurrence`; a second direction-based aggregation
groups unequal numeric transitions by constraint family and metric under
`cross_case_row_family_scale_direction_recurrence`. Unchanged evidence is kept
in `cross_case_row_family_scale_persistence`. These reports attribute row-scale
observations, not a sparse-QR condition proxy or solver failure: a family that
owns the smallest derivative row is not automatically the cause of an ill-
conditioned KKT system.

For a controlled follow-up, set
`NLPDIAGNOSTICS_BMOPF_FAMILY_SCALING_EXPERIMENTS` to a comma-separated list of
public constraint families. The runner then normalizes only the finite nonzero
rows of each named family to unit infinity norm in a copy of the recorded
Jacobian and repeats sparse QR. It retains the baseline/scaled rank, pivot-
spread proxy, ratio, and applied factor range. Zero families are explicitly
unavailable rather than assigned artificial factors. The intervention is
fingerprinted and resume-compatible, and repeated calibration requires exact
same-point recurrence. `cross_case_row_family_scaling_experiment_summary`
aggregates availability, rank changes, and pivot-proxy direction. This is a
linearization experiment only: it does not rescale the model, KKT system,
constraint residuals, or solver tolerances.

When `NLPDIAGNOSTICS_BMOPF_CASES` names several cases, the launcher isolates
each case in its own child process and output directory. Timeouts and crashes
therefore qualify only that case, point policy, and repetition; completed
evidence from the rest of the stratum remains available to the summarizer.
Set `NLPDIAGNOSTICS_BMOPF_CALIBRATION_RESUME=true` to reuse successful isolated
children from an existing manifest and rerun only failed or missing children.
The launcher rejects a resume when the root, project, policies, repetition
count, case selection, dense-entry budget, or requested family-scaling
experiment differs; the timeout may be
increased for retries. A normal process exit is reusable only when its child
index exists, contains at least one case, and every case status is `ok`.
Each child records elapsed wall time, its attempt number, and prior failed
attempts. Attempt logs use distinct filenames so a successful retry cannot
erase the timeout or exception evidence that motivated it.

Solver-trace campaigns apply the same boundary to their final solver result
and to optional callback iterates. Metric-only traces remain valid when
callback coordinates were not requested, while physical or cross-case claims
require one complete finite solver-result point for every successful case.
The trace runner also sanitizes NaN/Inf values at its JSON boundary, retaining
the associated failure metadata instead of dropping the entire benchmark
record.
When `NLPDIAGNOSTICS_BMOPF_FAMILY_SCALING_EXPERIMENTS` is set for a solver
trace, the final serialized case record contains both
`bmopf_jacobian_row_family_scale_attribution` and
`bmopf_jacobian_row_family_scaling_experiment`. The latter is deliberately a
recorded-linearization intervention: it reports baseline/scaled sparse-QR
rank and pivot proxy plus the applied factor range, but it does not modify the
Ipopt run. Solver-log iteration counts, termination, residual evidence, and
the semantic Jacobian reports must therefore be interpreted as correlated
observations rather than a causal scaling experiment. The isolated launcher
copies the requested family list into `index.json`; the trace summarizer copies
it into `summary.json`, retains compact per-case attribution/intervention
records, and reports coverage, rank-change, and pivot-proxy direction counts.
The trace preflight also classifies source-schema losses using the same policy
as the multiconductor campaign: representational unit losses are retained as
context, while device-semantic and physical/operating-point losses block the
`physical_metadata_complete` readiness gate until explicitly mapped.

## Controlled nondimensionalisation experiments

BMOPFTools now exposes one stable `OpfScaling` factory and a versioned
`OpfDiagnosticSchema`; the concrete engine policy types remain implementation
details. The custom scaling form accepts an explicit power base and a complete
compatible AC voltage-base map, while deriving
current, impedance, and admittance bases from dimensional identities. It does
not yet represent arbitrary independent voltage/current/power bases; those
would require scale coefficients in the engine equations. The effective policy
is retained in BMOPFTools research provenance, so campaign records can identify
the actual coordinate system rather than infer it from `per_unit=true`.

The generic `DiagonalScalingMap`, `scaling_covariance_report`, and
`scaling_coordinate_geometry_report` form the first trust gate for comparing
two policies. They align variables and scalar constraint rows by semantic keys;
map points, constraint functions, scalar sets, feasibility violations,
objectives, gradients, and Jacobians to common physical units; and report
coverage separately from tolerance agreement. Incomplete derivative rows or
missing scalar-bound semantics are unavailable, never zero-filled. Dense
rank and singular-value work remains guarded by `max_dense_entries`; physical
Jacobian covariance uses semantic-keyed combined sparse entries and remains
available when dense work is disabled.

`bmopf_diagonal_scaling_map` derives the declarations from BMOPFTools' public
variable and constraint registries. It does not parse JuMP names. Every alias
for a model variable must agree on quantity and physical scale, every evaluated
scalar row must have a unique registered key, and every set must admit a scalar
bound representation. Unsupported variables and rows are returned explicitly;
an incomplete adapter cannot produce a covariance or geometry verdict.

`bmopf_scaling_covariance_report` applies the full same-point gate.
`bmopf_scaling_coordinate_geometry_report` then compares raw solver-coordinate
row/column spreads, zero patterns, rank, and a guarded condition proxy. The
latter deliberately reports observations instead of a score. A policy with a
smaller local proxy has not thereby been shown to converge faster or more
robustly.

`bmopf_transport_scaling_point` holds the physical state fixed while changing
coordinates. It uses the complete public semantic map, returns a round-trip
certificate, and labels the target coordinates as `TransportedPoint`; callers
must evaluate that point in the target model before claiming feasibility or
covariance. `bmopf_physical_feasibility_report` then applies exact block,
residual, or declared-quantity tolerances in physical residual coordinates.
Missing tolerance coverage fails acceptance, and the report explicitly does
not equate solver-internal scaled tolerances with physical tolerances.

`bmopf_physical_solver_kkt_report` closes the scalar-bound endpoint contract
for a solved BMOPF model. It builds the authoritative physical map, verifies
that the numerical evaluation matches the selected public solver result, and
reports physical feasibility, stationarity, dual feasibility, and
complementarity. Feasibility tolerances may be expanded by BMOPFTools residual
quantity. Stationarity, dual, and complementarity tolerances stay explicit
because their compound units also depend on objective semantics. Setting
`semantic_blocks=false` selects the exact positive-diagonal scalar-side route;
coupled blocks require a supported full dual/set transformation contract.

The report also contains `semantic_attribution`. Primal residual blocks are
mapped to public BMOPFTools constraint families, stationarity coordinates to
public variable families, and complementarity sides to their exact scalar-row
families. Each family retains record counts, pass/fail coverage, and maxima for
the relevant residuals. A transformed block spanning several registry
families receives an explicit `mixed[...]` label. Unregistered rows remain
visible but make `interpretation_qualified=false`.

`bmopf_solver_trace_physical_endpoint_data` combines this attributed endpoint
with the unchanged native solver trace and generic solver-result profile. It is
the preferred artifact for matched nondimensionalisation runs. The native
trace and physical endpoint are not numerically equated; the artifact records
their different roles and the fact that the last callback row can precede the
public final result.

`bmopf_iteration_trace_jacobian_family_geometry_data` applies the same public
registry ownership to captured solver iterates. Each selected snapshot retains
row- and column-family geometry, native callback metrics, and its point
fingerprint; trajectory summaries retain first, last, minimum, maximum, and
positive spread over the selected rows. Interpretation requires complete
snapshot evaluation and complete BMOPFTools row/column registry coverage.
Because callback coordinates are required, this path is presently available
for the Ipopt adapter and explicitly unavailable for metric-only MadNLP traces.

`bmopf_voltage_initialization_invariants_data` inspects generated rectangular
voltage starts in both model and physical coordinates. It checks zero explicit
neutrals and, only on three-phase buses with an explicit reference, equal phase
magnitudes and pairwise 120-degree separation. Delta and split-phase buses are
not forced through that wye-pattern assumption. The report is pattern evidence,
not an initial-feasibility claim. When the engine exposes the versioned
`opf_diagnostic_schema`, the same artifact also carries the network-wide
phasor-transport equation counts, per-family residuals, unsupported transformer
subtypes, and a separately qualified transport gate. This is the appropriate
evidence for multi-voltage transformer chains, single-phase laterals,
centre-tapped secondaries, and WYE/DELTA vector-group shifts; a balanced-wye
pattern check cannot establish any of those relations.

`bmopf_initialization_scaling_covariance_report` independently reads each
policy's generated start and compares the complete physical point, functions,
sets, residuals, and Jacobian through authoritative semantic maps. Campaigns
can now require this gate separately from common-start transport. The two gates
answer different questions: whether the engine's native initialization is
coordinate-invariant, and whether an experimental stratum was transported
identically. Set `require_phasor_transport=true` for transformer-rich campaigns;
then both contexts must report an applied transport solve, no unsupported
transformer subtype, and a residual below `transport_residual_tolerance`.
Zigzag is presently a representation gap in BMOPFTools, so it must remain an
explicitly unsupported connection until schema-level connection matrices and
their matching OPF equations exist.

`bmopf_transformer_scaling_contract_data` is the pre-mutation contract for
local transformer-side voltage and power bases. It delegates topology and
connection ownership to BMOPFTools, then reports galvanic-zone consistency,
per-interface voltage/current/power conversion factors, symmetric conversion
ranges, and the identity error in `V_base*I_base=S_base`. Two readiness flags
are intentionally distinct:

- `comparison_ready` means the proposal is complete and algebraically
  self-consistent;
- `model_experiment_ready` means the current engine has actually applied that
  proposal to its equations.

A local-power-base proposal can therefore be useful for designing the next
intervention while remaining ineligible for solver-performance comparison.
This prevents a table of attractive bases from being mistaken for a changed,
covariance-qualified NLP.

BMOPFTools now provides a qualified executable slice through
`OpfScaling(...; power_bases=...)`: power bases may differ across isolated `single_phase`,
`wye_delta`, and `delta_wye` transformers and must remain constant inside each
galvanic zone. For such a context, `applied_to_model` and
`model_experiment_ready` are true. The adapter uses bus- and winding-local power
bases for variables, residual sets, and Jacobian transformations; using the
legacy system base here was a detected covariance failure, not a harmless
reporting approximation.

The Yd/Dy extension is connection-aware rather than a scalar repetition of YY:
the delta terminal-current incidence uses `S_delta/S_wye`, delta-arm leakage
referral uses its reciprocal, and wye-coil ratings and starts use the wye-side
base. A chained 10 MVA → 1 MVA → 100 kVA fixture passes physical point,
constraint-function, residual-set, and physical-Jacobian covariance at the
native transported initialization.

The center-tap slice covers both engine formulations. For nonzero leakage star
arms, BMOPFTools transforms the fixed 5×5 primitive between primary and
secondary current coordinates; its normalized matrix is legitimately
nonsymmetric while the dimensional primitive remains reciprocal. Zero-arm and
free-tap cases use the explicit T model with `S_primary/S_secondary` in
ampere-turn balance. Unequal-leg 40:1 fixtures pass exact PF and OPF endpoint
equivalence plus physical point, function, residual-set, and Jacobian
covariance. The explicit path's current-box limits are MOI variable bounds;
BMOPFTools exposes them under public component constraint keys, so the physical
map retains equation-level provenance. An unregistered bound still makes the
map unavailable rather than being silently inferred.

The n-winding slice uses winding 1 as the common referred-current coordinate.
Each winding `k` enters ampere-turn balance and every ZB column through
`N_k(S_k/S_1)I_k`; the ZB matrix remains scaled once by the winding-1 impedance
base. Winding-local shunts, current limits, power limits, result recovery, and
diagnostic scales remain attached to their owning winding. A loaded three-port
fixture with nonzero full ZB coupling, magnetising shunt, asymmetric phases,
and a 50:1 base spread passes exact PF/OPF endpoints and the complete
initialization/function/set/physical-Jacobian covariance gate.

`bmopf_acdc_scaling_contract_data` now qualifies native lossless AC/DC
crossings independently of transformer crossings. It reports each converter's
AC and DC voltage/current/power bases, the expected and stamped
`S_ac/S_dc` coefficient, controller-mode coverage, and the symmetric range of
coordinate conversion factors. The semantic adapter assigns converter balance
rows to the DC power coordinate, droop rows to the owning AC-bus power
coordinate, DC source-power variables to `S_dc`, and positive normalized DC
thermal rows to a dimensionless residual. A two-converter/two-zone fixture
passes the complete native-start covariance gate under both P/V and droop/V
control. `comparison_ready` does not claim improved solver work and does not
cover converter losses or custom formulation hooks.

Galvanically continuous regulators are now qualified under a stricter
invariant. `single_phase_autotransformer` and `open_delta_regulator` interfaces
must retain one voltage base and one power base because a common bushing or
straight-through phase is a literal shared conductor. The adapter exposes
`galvanic_voltage_compatibility_passed`, the count of galvanic interfaces, and
the count requiring an unsupported shared-conductor voltage conversion. Loaded
fixed-tap endpoints and fixed/free-tap physical Jacobians covary between SI and
normalized coordinates; a proposed voltage-base jump is not comparison-ready.

The first truth-labelled integration fixture compares classic 1 MVA per-unit
coordinates with a custom 500 V / 200 kVA policy. All physical-coordinate,
function, set, violation, and Jacobian checks pass. The custom coordinates
change both raw row and column spreads from 1 to 2 and raise the local dense
condition proxy from about 14.2 to 20.0. This is useful precisely because it is
not a predetermined win for custom bases: the gate establishes that the
geometry difference comes from coordinates, while the geometry report leaves
solver merit unresolved. A negative control changes one physical line
resistance and is rejected through the physical-Jacobian check despite complete
semantic alignment.

This remains a local covariance test, not a full model-equivalence certificate.
The current contract covers the AC bus, line, switch, source, load, generator,
ground, supported IBR, transformer/n-winding, and exercised DC converter/network
families. The formulation breadth is regression-tested separately. A solved
line/load fixture now transports one classic-per-unit Ipopt endpoint to SI and
two custom policies; all four pass physical residual, Jacobian, and local-rank
covariance. Before attributing solver behavior to scaling, campaigns must still
hold perturbations and physical endpoint KKT criteria fixed. Scalar-side
solver dual and complementarity semantics are now implemented; general
coupled-cone dual transformations remain outside the current contract.

### Authoritative semantic block covariance

BMOPFTools now declares native paired coordinates and residuals through its
public `OpfSemanticBlock` registry. `bmopf_semantic_block_scaling_map` consumes
those declarations and assembles a complete `SemanticBlockScalingMap`; model
coordinates not covered by a valid declaration remain explicit singleton
blocks. The adapter reports applied and skipped declarations, singleton
coverage, and local reference-scale provenance. It never groups coordinates by
JuMP names.

The registry is lifecycle-aware. BMOPFTools registers native blocks lazily only
after KCL finalisation, so a pre-KCL context is reported as unavailable rather
than being mistaken for a model with no semantics. The adapter preserves the
engine's `schema_capabilities` (including `lifecycle`,
`semantic_blocks_available`, and `semantic_blocks_registered`) in the scaling
map; downstream analyses should require the availability flag before making
coverage claims.

`bmopf_block_scaling_covariance_report` applies the common-physical-coordinate
gate to the declared blocks, while
`bmopf_block_scaling_coordinate_geometry_report` compares raw local geometry
only after that gate passes. The first line/load truth fixture applies ten
two-coordinate variable blocks and eight two-row residual blocks. It passes
classic-versus-custom covariance and rejects a changed line resistance.

For BMOPFTools revisions that predate the versioned `opf_diagnostic_schema`
wrapper, the adapter now consumes the public `opf_semantic_blocks` registry
directly and labels the resulting capability as a compatibility path. This
preserves the declared block transforms and scalar fallback coverage without
claiming the newer schema metadata. Real-network campaigns should still record
the BMOPFTools revision and distinguish semantic-map readiness from a solver
run in transformed coordinates.

`bmopf_phase_only_transform_plan` is the reusable preflight boundary for that
next step. It creates a non-mutating candidate map, applies a deterministic
two-coordinate rotation schedule, classifies the intervention, and reports
rotated-block coverage. It intentionally returns
`solver_transform_applied=false` and `solver_campaign_ready=false`: the current
BMOPFTools/JuMP surface has no model-rebuild hook for eliminating the original
coordinates and restamping nonlinear expressions in the rotated basis.

Residual-set semantics are deliberately exact. KCL and other equations whose
actual JuMP sets are equality to zero use `ZeroEqualitySetContract`. Source
voltage and load power equations with nonzero equality values use
`ScalarBoundsSetContract`. Rotating the latter would produce a coupled affine
set; until that image is represented explicitly, the generic block gate marks
it unavailable rather than treating it as a zero residual or a rotated box.

Local physical ratings in the engine declaration (currently including
per-phase load nominal apparent power and supported IBR nameplate power) are
candidate nondimensionalisation references with sources. They do not alter the
model-to-SI map. This separation lets experiments ask whether a device-local
row reference improves numerical work while the physical covariance gate
continues to test that the mathematical model is unchanged.

The same evidence is available directly from a staged context through
`NLPDiagnostics.bmopf_source_schema_report(context)`. It is attached to both
the BMOPF context profile and `bmopf_analyze_opf` report, with aggregate
findings and metadata for the source path, dropped fields/scopes, policy
statuses, and original conversion messages. This keeps source-fidelity
limitations visible even when a user is not running the benchmark harness.

BMOPFTools retains a compact inventory of source fields found in PowerIO
`extras` records. NLPDiagnostics reports provenance coverage, explicit mapping
contracts, and unresolved blocking fields separately. A raw PowerIO conversion
warning therefore remains inspectable even when a later mapping or behavior
contract accounts for the field; only unresolved blocking fields prevent
physical-schema readiness.

The current BMOPFTools boundary also emits mapping evidence for fields that
are demonstrably represented in the staged network: `kv` → `load.v_nom`,
`phases` → `load.terminal_map/configuration`, and `basekv`/`angle` → voltage
source magnitude/angle with explicit transforms. Load ZIP `model`/`zipv`
fields are mapped into BMOPF load model coefficients when the staged load
contains those fields; a source-side `model=ideal` is mapped by the fixed
voltage-boundary capability contract. Unsupported source models remain
unmapped. `vminpu` and `vmaxpu` are mapped with a source-behavior contract,
not into production-model bus bounds.

The source-semantic report also retains normalized `vminpu`/`vmaxpu` records as
load-voltage-behavior observations. They are intentionally not converted into
BMOPF bus bounds: the observation is useful for diagnosing model-domain and
initialization issues, but it does not prove that the optimization model has
those limits as active constraints. OpenDSS `model=ideal` is reported
separately as a represented fixed-voltage-boundary contract; unsupported source
models remain explicit unmapped blockers.
Their mapping status is `mapped_with_contract`, targets the preserved
`powerio_source_semantics.load_voltage_thresholds` record, and carries
`active_in_original_model=false`. This clears source-fidelity readiness while
preserving the separate question of whether a selected operating point lies
inside the source load-law domain.

NLPDiagnostics decodes this retained metadata at the plugin boundary; it does
not require BMOPFTools to expose another public source-behavior API. When an
older or experimental BMOPFTools checkout provides an equivalent helper, the
adapter accepts that contract. Planning returns non-mutating candidate
terminal-voltage-ratio constraints of the form
`vminpu <= abs(V_terminal) / v_nom <= vmaxpu`. Candidates carry their bus,
terminal map, nominal-voltage context, readiness status, and an explicit
`active_in_original_model=false` marker. This is a diagnostic planning API,
not an implicit reformulation.

For staged JuMP contexts, `NLPDiagnostics.bmopf_source_behavior_auxiliary_model`
materializes eligible candidates into a separate JuMP model. The builder uses
explicit real/imaginary terminal-voltage variables and squared-magnitude bounds,
returns primitive records alongside the auxiliary model, and records that no
constraint was added to the original BMOPF model. The smoke campaign serializes
this evidence without serializing JuMP object references.

`NLPDiagnostics.bmopf_source_behavior_report(context, point)` evaluates those
thresholds at a typed operating point and emits physical, numerical-observation
findings for below-`vminpu` or above-`vmaxpu` ratios. The report keeps the
observed ratio, source thresholds, scope, and violation magnitude in primitive
rows. Passing `solve_auxiliary=true` with an optimizer invokes the isolated
model and records its termination status; without an optimizer the solve is
explicitly reported as unavailable. Neither path mutates the production model.
The smoke runner exposes this as an explicit campaign policy through
`NLPDIAGNOSTICS_BMOPF_SOURCE_BEHAVIOR_SOLVER=none|ipopt`; optional
`NLPDIAGNOSTICS_BMOPF_SOURCE_BEHAVIOR_MAX_ITER` and
`NLPDIAGNOSTICS_BMOPF_SOURCE_BEHAVIOR_TOL` attributes are recorded alongside
each solve, so solver-backed evidence can be distinguished from observation-only
profiles.

Solver-trace records can also call
`NLPDiagnostics.bmopf_source_behavior_solver_comparison` at the trusted solver
result point. The result keeps solver termination/feasibility separate from
source-domain observations and classifies the relationship as consistent,
success-outside-domain, failure-aligned, or failure-unexplained. These are
follow-up hypotheses, not causal certificates.

When a source contract is available before staged model construction, pass it
as `source_contract = ...` to the auxiliary/report/comparison APIs. The staged
BMOPF context may normalize source nominal voltages; the adapter preserves the
source nominal in volts, derives the corresponding model-coordinate nominal
(for example, `0.999998` p.u.), and records the voltage base used for the
conversion. This prevents a volts-versus-per-unit mismatch from being reported
as a physical threshold violation.

`benchmarks/launch_bmopf_source_solver_matrix.jl` automates this paired path
over DSS fixtures and iteration budgets. It writes one trace, summary,
validation report, and process log per case/budget pair, then reports whether a
classification is stable across budgets. Matrix readiness also requires every
comparison row to carry a finite source nominal and an explicit model-coordinate
unit (`per-unit` or `SI/model-native`); a stable classification without that
gate is not admitted as physical evidence. Set
`NLPDIAGNOSTICS_BMOPF_SOURCE_SOLVER_MATRIX_REUSE=true` to rebuild the manifest
and validation summaries from completed case directories without rerunning the
solver children.

The same launcher now retains optional BMOPF family-omission perturbations
(`NLPDIAGNOSTICS_BMOPF_RUN_FAMILY_PERTURBATIONS=true`) in each matrix entry,
including per-family status, termination, iteration delta, and row-family
effects. These records are deliberately auxiliary: omission of a native family
is a sensitivity experiment, not a valid reformulation of the production
model. Enabling this mode automatically uses the full profile stage (override
with `NLPDIAGNOSTICS_BMOPF_FAMILY_PROFILE_STAGE`) so family variants are not
silently skipped by a trace-only resource policy. Matrix readiness separately
checks that every requested family variant completed.

The corrected six-fixture matrix had complete alignment coverage in all 12
case/budget pairs. One-phase, delta-load, and line fixtures were consistent at
both budgets; ZIP and wye-delta-transformer cases were source-domain-consistent
at `max_iter=25`, while their five-iteration failures were not explained by
source thresholds. This separates the original unit-boundary artifact from the
remaining endpoint/initialization behavior.

Each conversion warning is also present in the mapping ledger with an
`unmapped` status, impact classification, readiness-blocking flag, and reason.
Consequently, an absent target is an explicit policy decision rather than an
unobserved field. When a field is represented for only some component scopes,
the ledger records `partially_mapped` plus the mapped and unmapped scopes; it
does not clear the aggregate readiness gate.

The multiconductor smoke campaign includes a ZIP-load fixture so this
scope-level behavior is exercised in a complete profile, summary, and
validation path rather than only in a conversion unit test.

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

### Point calibration and endpoint separation

Use `benchmarks/launch_bmopf_point_calibration.jl` to repeat the full profile
at explicit evaluation points. The supported policies are `engine_start`,
`saved_si`, and `saved_pu`; select them with
`NLPDIAGNOSTICS_BMOPF_CALIBRATION_POINTS`, repeat with
`NLPDIAGNOSTICS_BMOPF_CALIBRATION_REPETITIONS`, and set
`NLPDIAGNOSTICS_BMOPF_RANK_MAX_DENSE_ENTRIES=0` for large cases. The launcher
writes a resumable manifest after each child. Summarize it with
`benchmarks/summarize_bmopf_point_calibration.jl`.

The v2 summary separates point-invariant stages from point-local findings,
checks exact same-point fingerprints and metric recurrence, and requires full
saved-result registry coverage before reporting persistence. A successful
comparison is evidence that a finding changes with the evaluated endpoint; it
does not by itself establish a mathematical or physical defect. On the
538-bus LN/LG calibration, all 12,538 rows were mapped at both points and the
sparse rank remained 11,028, while the saved-point `ibr_power_circle` rows
accounted for the large row-scale spread. This is the recommended gate before
interpreting solver-policy/context differences as formulation-level claims.

The endpoint-triangulation utility also accepts multiple calibration summaries
through `NLPDIAGNOSTICS_BMOPF_TRIANGULATION_CALIBRATIONS`. This supports a
stratified corpus without losing case-level provenance. In the current
30/99/538-bus LN/LG campaign, six successful no-scaling endpoints all matched
their trusted saved-SI semantic finding maps; the report therefore contains no
endpoint-conditioned cases. Use this report before treating a repeated policy
effect as a formulation-level observation.

Successful no-scaling endpoints are the next trust gate. On the 538-bus pair,
LG reached `locally_optimal` at `max_iter=100` and LN reached it at
`max_iter=300`; both reproduced the baseline context finding identities and
had residuals below `6e-12`. The earlier 40-iteration no-scaling findings
(`bmopf_opf_differentiability_not_ready` and the small port-scale subset) were
therefore endpoint-conditioned observations. Treat a policy comparison as
formulation evidence only after this successful-endpoint check, or retain an
explicit iteration-limit label in the report.

For repeated policy campaigns, use two sweep manifests with
`benchmarks/summarize_bmopf_solver_repeats.jl`, then join their summaries with
`summarize_bmopf_endpoint_triangulation.jl`. In the current 30/99/538-bus
matrix, all 36 policy/case observations were successful and repeatable, with
zero semantic finding changes across repetitions; all 18 policy/case results
matched saved-SI semantics. This separates repeatable solver-work changes from
endpoint-conditioned semantic changes before numerical-stage interpretation.

For a small dense checkpoint, set
`NLPDIAGNOSTICS_BMOPF_RANK_MAX_DENSE_ENTRIES=1000000` on the 30-bus LN/LG pair.
The current run reports dense rank 704, sparse rank 704, and explicit rank
agreement for all baseline, bounded-scaling, and no-scaling policies. Keep the
larger 99/538-bus campaigns at zero dense budget.

The numerical-stage repeat summary now retains sparse-QR condition-proxy
ranges and policy deltas in addition to sparse rank and readiness. On the
30/99/538-bus matrix, all sparse ranks were invariant and dense rank was
explicitly unavailable; condition-proxy deltas remained small relative to the
absolute proxies. Treat these as sparse numerical observations until a bounded
dense run is performed on an appropriately small fixture.

The solver-trace numerical path now preserves compact BMOPFTools row-family
scale attribution alongside the generic numerical report. It evaluates the
solver endpoint once, reuses that evaluation for both diagnostics and semantic
mapping, and records `bmopf_profile` with an explicit numerical-stage marker;
the full BMOPF profile remains budgeted out. The 30/99/538-bus LN/LG checkpoint
reported attribution on all six successful cases when the large-model solve
guard was raised explicitly. Observed global row-scale ratios were roughly
`2.8e3`--`5.9e4`, with `ibr_power_circle` consistently the smallest-positive
family. This is local derivative-scale evidence and must not be read as a
causal solver or physical diagnosis.

The fresh three-policy numerical checkpoint (baseline, bounded scaling, and
no-scaling) retained attribution for all 18 stratified observations. Bounded
scaling increased the global row-scale ratio by roughly 2.0--2.3%; no-scaling
decreased it by roughly 0.2--0.35%. The repeat summarizer now accepts both raw
BMOPF attribution (`global`) and normalized case-summary envelopes, so paired
policy deltas are no longer reported as unavailable when the evidence is
present. These results are descriptive and provenance-scoped.

An independent second run of the three-policy matrix reproduced the row-family
ratios, sparse ranks, condition proxies, and readiness for all six cases. The
paired bounded-scaling and no-scaling row-family deltas were stable case by
case, with zero semantic or readiness changes. The campaign validator now
recognizes solver-repeat summaries and requires both attribution availability
and recurrence before treating these policy deltas as repeatable evidence.

The bounded dense 30-bus checkpoint is also complete for all three policies and
both LN/LG cases: dense and sparse ranks agree at 704, with explicit budget
provenance and row-family attribution retained. The 99/538-bus fixtures remain
sparse-only by design. The next phase is evidence-ledger integration followed
by controlled multiconductor profiling through the BMOPFTools engine.

The evidence ledger now accepts solver-repeat recurrence and dense/sparse rank
agreement as explicit evidence records, preserving their provenance and budget
metadata. A combined ledger of the repeated policy, dense 30-bus, and
multiconductor summaries retained 26 source-aware records.

A controlled five-fixture multiconductor smoke run through BMOPFTools completed
with explicit start completion, dense analysis disabled, and an iterative
right-nullspace probe. All fixtures built and exposed port contracts and probe
data. Source-schema losses and unavailable dense physical-mode comparison were
retained as readiness boundaries; they are not treated as solver failures. The
next multiconductor step is a second point policy (engine initialization versus
explicit BMOPF completion) and a point comparison before physical conclusions.

The point-policy comparison utility now pairs multiconductor summaries by
fixture, checks environment and policy identity, and separates contract/mode/
probe changes from physical claims. BMOPF-start completion versus the explicit
zero probe covered all five fixtures successfully with unchanged contract,
mode-status, and probe-convergence observations. The raw engine-initialization
policy failed all five fixtures because starts were incomplete; this is reported
as a readiness boundary, not as a physical diagnosis. Successful overlap is
required before a point comparison is admitted as evidence.

The bounded dense checkpoint is now complete on all five small fixtures with a
10,000-entry budget. Dense rank was available at both point policies for every
paired fixture. Port contracts, mode-status classifications, and probe
availability were stable, but delta-load changed rank 38 -> 36 and the
wye-delta transformer changed 48 -> 42 between BMOPF-start and zero
coordinates. These are explicitly recorded as point-local numerical evidence;
they are not physical interpretations because the same fixtures still report
coordinate-alignment boundaries and unsupported source metadata. Larger
multiconductor campaigns should remain sparse-only unless their dense budget
is stated and the paired dense-rank gate is satisfied.

Dense-rank changes are now classified against coordinate alignment. In the
five-fixture checkpoint, all fixtures remain at the coordinate-alignment
boundary, so the two rank changes are recorded as `alignment_ambiguous`, not
as physical modes or formulation defects. The validator and evidence ledger
preserve this interpretation boundary. The next implementation step is a
per-port alignment-coverage report that identifies missing and partial
terminal maps for targeted BMOPFTools metadata restoration.

Per-component mode projections are now serialized and compared. All five
fixtures expose paired projection records; the declared source common-mode
directions are visible in model coordinates, with no hidden or unrepresented
projection in this corpus, and visibility is stable across BMOPF-start and
zero points. These remain candidate directions rather than observed
nullspaces: the numerical comparison still has coordinate-alignment
boundaries. The next step is matching visible candidates against observed
Jacobian null vectors with explicit component and variable support evidence.

The first candidate-to-Jacobian match checkpoint is complete. All five
fixtures have paired, point-stable match records. No candidate is currently
classified as observed: 12 modes are outside the free-coordinate Jacobian
scope, and the wye-delta transformer has two additional visible delta modes
classified as locally not observed (residuals near 0.577). The result is kept
as semantic evidence rather than a physical failure. The next step is a
controlled free-coordinate projection policy that preserves fixed components
instead of silently discarding them.

That policy is now available as expected_mode_free_coordinate_policy =
:strict or :project_free. :project_free records the discarded fixed or
unavailable components explicitly and emits projected local match findings
without treating them as physical gauge certificates. The BMOPF campaign
serializes the policy, projected residuals, discarded-coordinate support, and
point-to-point stability. The remaining semantic boundary is the
plugin-specific tangent space for reference and grounding coordinates.

The tangent boundary is now represented by
`ExpectedNullspaceTangentPolicy`. It retains explicitly named fixed/reference
coordinates in the local Jacobian comparison without releasing their model
domains. Findings carry the policy name and are classified as local inference,
not physical certificates. The BMOPFTools adapter exposes
`bmopf_expected_mode_tangent_policy(context; variables = :fixed)`, which
derives a conservative scope from staged fixed-variable roles. Smoke records,
point comparisons, validation, and the evidence ledger preserve this policy
identity so campaigns with different coordinate scopes cannot be compared
silently.

For paired calibration, use `launch_bmopf_tangent_calibration.jl`. It runs the
same smoke campaign with `none` and `fixed` scopes and produces a guarded
`tangent_policy_comparison.json`. The comparison requires matching fixture,
environment, and evaluation-point provenance before reporting rank or mode
changes.

In the first bounded `delta-load` calibration (zero-coordinate probe,
10,000-entry dense budget), both policies retained dense rank 36. The `none`
scope left two visible modes outside the free comparison; the fixed scope made
both comparable and classified them as locally tangent-not-observed. The same
run retained 17 source-schema warnings, including physical metadata losses, so
this result is calibration evidence rather than a physical declaration.

The five-fixture zero-point campaign preserved rank in every pair: 36, 34, 34,
38, and 42 for delta-load, free-neutral-return, grounded-neutral,
unbalanced-three-phase-line, and wye-delta-transformer respectively. The fixed
scope made all 14 visible candidate modes comparable; none was locally
observed. The campaign still contains 59 source-schema warnings with physical
impact, so the next step is metadata restoration and support inspection rather
than adding fixture-specific physical mode declarations.

Calibration summaries retain per-mode tangent rows (mode name, policy,
residual, tolerance, and description) plus the retained-coordinate count. This
is the evidence to inspect when deciding whether a fixed/reference coordinate
belongs in a future physical plugin declaration.

The per-port alignment report is now retained in each multiconductor contract.
The dense checkpoint had complete voltage and current terminal maps on all five
fixtures, with no missing, dimension-mismatched, or nonfinite maps. The
remaining boundary is specifically mode-to-coordinate semantics: structurally
complete port maps do not yet make every declared physical mode comparable to
the model Jacobian. The next step is source-metadata restoration and
fixture-level support review before promoting any physical tangent declaration.

The source-preserving solver trace now records initialization provenance before
the first Ipopt/MadNLP call. Set
`NLPDIAGNOSTICS_BMOPF_INITIALIZATION_POLICY` to `none` (the default), `zero`,
`bmopf`, or `bmopf_zero_completion`. The trace retains the policy, application
status, coordinate count, finite-start count, missing-start count, and—when
applicable—the completed start-point fingerprint and provenance. The policy
`none` preserves BMOPFTools' native starts without adding an override; the
other policies supply variable primal starts. None of these policies changes
bounds, constraints, or the source snapshot. The source-solver matrix carries the same fields and
requires initialization metadata in its readiness report. These policies are
controlled point perturbations: a changed termination or derivative fingerprint
is local initialization evidence, not proof that the unchanged formulation is
mathematically defective.
`benchmarks/compare_bmopf_solver_traces.jl` also retains the two policies'
initialization status, finite/missing counts, and point fingerprints alongside
the solver-trace comparison.

Set `NLPDIAGNOSTICS_BMOPF_CAPTURE_ENDPOINT_DERIVATIVES=true` to add an opt-in
endpoint derivative record. It evaluates the public MOI numerical interface at
the solver-result point and stores a deterministic sparse Jacobian-value
fingerprint, evaluator-source fingerprint, entry/finite-entry counts, and
finite magnitude range. This is endpoint-local numerical evidence; it is not a
rank certificate and is intentionally disabled for large trace-only campaigns.
For policy grids, `benchmarks/compare_bmopf_source_solver_matrices.jl` checks
case/budget compatibility, source comparisons, coordinate alignment,
initialization metadata, and endpoint derivative availability before reporting
classification or derivative-fingerprint changes.
When endpoint derivatives are enabled, the matrix also retains BMOPFTools row-
family scale attribution, including global extrema and per-family row norms.
Those values remain point-local scale evidence rather than condition estimates.
Endpoint records also retain scalar active-set classifications, selected active
rows, violated rows, and maximum feasibility violation; these are endpoint
geometry observations and do not replace solver KKT or rank analysis.
In the completed ZIP/transformer policy grid, native and BMOPF-completed starts
matched active geometry exactly; zero starts changed ZIP's active set and moved
its smallest row scale to the load-power-imaginary family.

To connect endpoint observations with controlled formulation perturbations,
`benchmarks/correlate_bmopf_structural_family_omission.jl` joins the structural
policy comparison with the source-preserving family-omission matrix. It reports
termination/iteration sensitivity for the load and IBR families, rank-effect
counts, active-set deltas, and explicit co-occurrence flags. A co-occurrence is
only local prioritization evidence: it does not establish that omitting a
family causes the endpoint change, and it must be followed by a broader
campaign and physical review.

For larger decks, use `benchmarks/summarize_bmopf_sparse_corpus.jl` after a
source-solver matrix run. It preserves resource-budget and solver-size-guard
outcomes as explicit campaign boundaries, checks source-contract and
auxiliary-model non-mutation coverage, and prevents a skipped dense analysis
from being misread as an unavailable or failed diagnosis.

For medium-size cases, set
`NLPDIAGNOSTICS_BMOPF_SOURCE_SOLVER_PROFILE_STAGE=numerical` and pass an
explicit `NLPDIAGNOSTICS_BMOPF_SOURCE_SOLVER_RANK_MAX_DENSE_ENTRIES` budget.
The launcher then retains sparse numerical diagnostics and row-family scale
attribution without enabling the full BMOPF profile. A numerical-profile
row-family record is labelled `available_numerical_profile`, so it cannot be
silently confused with an endpoint derivative capture.

To retain trajectory evidence, pair that mode with
`NLPDIAGNOSTICS_BMOPF_SOURCE_SOLVER_CAPTURE_POINTS=true` and
`NLPDIAGNOSTICS_BMOPF_SOURCE_SOLVER_CAPTURE_ROW_RESIDUALS=true`. The trace
then evaluates only the captured public iterate points and stores per-family
maximum, L2, active-row, and violated-row summaries. The comparison utility
reports these as `row_family_residual_by_policy`; they are sparse,
point-local observations and never a causal proof. The comparison also labels
each family heuristically as `persistent`, `transient`, `restoration_only`,
`mixed`, or `inactive_or_below_tolerance`; these labels are descriptive trend
summaries, not solver-theory classifications.
`benchmarks/validate_bmopf_residual_trends.jl` checks those labels against the
captured regular/restoration phase counts and explicitly distinguishes a
restoration phase with persistent family residuals from a genuinely
restoration-only family signal.

`benchmarks/summarize_bmopf_restoration_campaign.jl` produces a bounded report
over a policy/case/budget grid. It counts restoration/endpoint-residual
co-occurrences, retains the largest family residual peaks, and records the
source-domain classification without requiring dense rank analysis.

For algorithmic persistence checks, use
`benchmarks/launch_bmopf_solver_option_perturbations.jl`. It crosses named
Ipopt option profiles with initialization policies and solver budgets while
keeping the matrix budget authoritative. The default baseline is explicit and
the launcher rejects duplicate option sets, because a solver default and an
equivalent named profile are not independent interventions. The companion
`benchmarks/summarize_bmopf_solver_option_perturbations.jl` compares each
perturbation to its same-policy baseline and reports changes in classification,
restoration records, endpoint residual signatures, and trace length.
When row-residual capture is enabled, it retains first-captured, final-captured,
post-first, post-first regular-phase, and post-first restoration-phase
statistics for every available family as
well as the legacy global peak. This separation is essential: a shared starting
point can dominate the global maximum even when later trajectories differ. The
first callback is not assumed to be identical to the caller's supplied
initialization.
Within-family changes are marked only when they exceed the configurable
absolute/relative comparison tolerance recorded in the report. That tolerance
uses raw residual coordinates; it is a noise screen, not a physical
normalization and not a basis for ranking different families.
The resulting option summary is accepted by
`benchmarks/summarize_bmopf_evidence_ledger.jl`, which emits separate
numerical evidence for post-first row-family trajectory stability and local evidence for
classification sensitivity. This keeps an algorithmic perturbation result
visible without turning it into a formulation defect claim.
The ledger emits a negative stability record only when a v3-or-later report declares
distinct option sets, every manifest entry completed, every non-baseline row
has a matched baseline, and every row-family trajectory is available and
nonempty. Older schemas are retained only as legacy smoke observations;
incomplete campaigns produce coverage evidence instead of robustness
evidence.
For v4 multiconductor scope, model-semantic contract availability and
invariance are additional mandatory gates. A failed semantic gate produces a
representational control finding and suppresses the trajectory-stability
record.
The option summary also aggregates the solve-time environment fingerprints and
records a separate summary-time environment. Git provenance distinguishes a
clean revision from modified source using a content fingerprint; it never
stores the source diff itself in the report.

## Smallest-direction scaling interventions

The smoke runner accepts
`NLPDIAGNOSTICS_BMOPF_SMALLEST_CROSSCHECK_SCALING=none|row|column|row_column`.
The selected policy, factor extrema, transformed-coordinate convention,
backend values and backward errors, and mapped original-Jacobian residuals are
retained per fixture. `compare_bmopf_multiconductor_crosschecks.jl` recognizes
a scaling-only policy change, preserves it as a controlled intervention, and
explicitly marks the two scaled spectra as not directly comparable.

The campaign validator rejects unsupported policies or any record that claims
the source model was mutated. It also requires a mapped original-coordinate
audit for requested crosschecks. This intervention changes a recorded local
linearization only; it is neither a BMOPF reformulation nor solver scaling.

## Feasible-point calibration

Use `benchmarks/compare_bmopf_multiconductor_points.jl` to compare two
environment-compatible multiconductor summaries. In addition to rank, mode,
and port-map evidence, the comparison retains feasibility-profile deltas,
sparse-QR condition-proxy deltas, active stationary-row deltas, and public
solver-result provenance. Its readiness gate requires paired numerical and
initialization profiles; an `ipopt_result` candidate additionally requires a
result point for every successful pair and feasible public primal statuses.

The first five-fixture comparison paired `bmopf_start_values` with
`ipopt_result`. All five Ipopt solves were `LOCALLY_SOLVED` with
`FEASIBLE_POINT`; all 31 completed-start violations were eliminated. Sparse QR
and guarded dense SVD agreed on full column rank at both points, and all seven
repeat/nearby evaluations per solved fixture retained zero right nullity. The
sparse-QR factor-diagonal ratio changed with the operating point, so it remains
a local conditioning screen rather than a formulation invariant. Source
`vminpu`/`vmaxpu` loss blocked physical absence claims in that historical
campaign; the later source-behavior contract checkpoint supersedes this gate.

## Sparse-only medium campaigns

`benchmarks/bmopf_draft_corpus.jl` accepts three independent work controls:

- `NLPDIAGNOSTICS_BMOPF_RANK_MAX_DENSE_ENTRIES` bounds dense SVD work;
- `NLPDIAGNOSTICS_BMOPF_SPARSE_QR_MAX_INPUT_NONZEROS` checks the combined
  sparse Jacobian before factorization; and
- `NLPDIAGNOSTICS_BMOPF_SPARSE_QR_MAX_FACTOR_NONZEROS` bounds acceptance of
  the realized SuiteSparseQR `R` factor.

All three values participate in the campaign fingerprint and are copied into
case and index records. Setting the dense limit to zero is the supported
sparse-only policy. A sparse budget breach is retained as explicit resource
evidence rather than treated as rank deficiency or a failed profile. Because
factor fill is only known after SuiteSparseQR constructs the factor, isolate
larger cases in child processes with external elapsed-time and memory guards.

`benchmarks/launch_bmopf_point_calibration.jl` provides that isolation for an
explicit case list. `NLPDIAGNOSTICS_BMOPF_CALIBRATION_TIMEOUT_SECONDS` is a
hard elapsed-time boundary. Set
`NLPDIAGNOSTICS_BMOPF_CALIBRATION_MAX_RSS_MIB` to a positive value to poll the
child resident set and terminate a child that crosses the budget. The manifest
records the budget, maximum observed RSS, and monitor availability; zero leaves
the RSS limit disabled rather than implying that memory was bounded.

Set `NLPDIAGNOSTICS_BMOPF_CROSSCHECK_FINITE_DIFFERENCE_ROWS=true` to select
Jacobian rows by finite-difference provenance and compare their recorded
products against central differences of constraint values in deterministic
dense directions. The selected rows, methods, direction policy, comparisons,
mismatches, and domain-limited probes are persisted. This is independent
whole-row perturbation evidence, not a proof of smoothness or global derivative
correctness.

The first bounded 99-bus LN/LG saved-result pair used a zero dense budget,
200,000 input-nonzero budget, and one-million-factor-nonzero budget. Both
Jacobians had 12,886 input nonzeros and about 25.6k factor nonzeros, so 99-bus
is a practical medium tier for repeated sparse experiments on this corpus.
The bounded three-time-point follow-up covered LN and LG at t01, t12, and t24.
All six cases retained full column rank under unscaled and row/column-scaled
SuiteSparseQR, with factor fill below 2.0. All 96 finite-difference rows in each
case passed three dense directions (288 comparisons per case) with no mismatch
or domain loss. Unscaled retained-pivot proxies ranged from about 37.6 to
5,327, while row/column-scaled proxies stayed between about 22.5 and 25.1.
This supports a coordinate-scaling interpretation of the proxy variation; it
does not establish a condition number or solver difficulty.

Use `benchmarks/summarize_bmopf_medium_calibration.jl` on the calibration
directory to retain these gates and exact BMOPFTools qualifications in one
artifact. BMOPFTools still withheld an unqualified differentiability claim in
this campaign because the reconstructed staged model itself was not optimized;
saved-result profiles therefore remain local equation/Jacobian evidence, not
certified solution sensitivities.

## Matched scaling-run evidence

`bmopf_variable_semantic_column_map` now labels every evaluated solver column
from the public BMOPFTools variable registry. Both diagonal and semantic-block
coordinate-geometry reports include row- and column-family comparisons plus a
separate registry-coverage gate. Mathematical geometry remains available when
a label is absent, but BMOPF interpretation is then unqualified.

`bmopf_scaling_intervention_classification` compares authoritative semantic
block maps and records whether a policy change is identity, magnitude-only,
phase-like orthogonal, combined, or general linear. The algebraic phase-like
label is not promoted to electrical phase semantics without component
metadata.

`bmopf_scaling_solver_experiment_comparison` joins two retained
trace-plus-endpoint artifacts with the intervention, covariance, and geometry
reports. It has no aggregate score. Qualification requires the declared
intervention class, common physical model/point evidence, two accepted physical
KKT endpoints, compatible solver telemetry semantics, complete registry
coverage, and matching endpoint families. This is the contract to use for the
first small magnitude-only campaign; phase-only experiments require a genuine
rotation policy or controlled semantic-map intervention rather than a renamed
positive scale.

The executable pilot is
`benchmarks/bmopf_magnitude_scaling_campaign.jl`. It builds a fresh model for
every replicate, transports one classic-per-unit BMOPF start through physical
semantic coordinates, and compares classic 1 MVA, SI, local 500 V / 200 kVA,
and local 1500 V / 5 MVA policies. The default is two repeats and writes its
complete artifact beneath `work/`.

The first pilot completed all eight Ipopt solves with stable locally-optimal
termination, no restoration rows, complete common-start covariance, accepted
physical KKT endpoints, and passing provenance/intervention negative controls.
Classic and both local-base policies retained four callback records and three
line-search trials. SI retained five records and four trials. At the common
start, the solver-coordinate Jacobian condition proxy was approximately 5.11
for classic, 5.34 for the 500 V / 200 kVA policy, 5.84 for the 1500 V / 5 MVA
policy, and 1964 for SI. The SI row- and column-norm spreads were each 1000
times the classic spread.

This is a mechanism-validating truth fixture, not evidence that one policy is
universally faster. It has only one phase conductor, a feasibility objective,
two deterministic repeats, and a tiny Jacobian. The result does show that the
instrumentation can connect a deliberately magnitude-only coordinate change,
family-resolved geometry, and reproducible solver work without changing the
physical endpoint contract.

The objective-bearing successor is
`benchmarks/bmopf_stratified_scaling_campaign.jl`. It derives all candidate
voltage bases from `opf_bases`, so transformer ratios remain owned by
BMOPFTools; it does not reconstruct engineering semantics from variable names.
The default study crosses two compact case classes, four magnitude policies,
three deterministic physical-start strata, and five fresh replicates. Each
stratum is independently aggregated first and then passed to
`scaling_solver_experiment_stratified_campaign_data`, which refuses pooling
unless policy coverage, reference policy, environment provenance, repeat floor,
and all underlying campaign gates agree.

The first default run qualified all 120 solves. The three-phase fixture used
11--12 callback records for the lower local-base policy, 12--13 for classic,
13--14 for the aggressive high-base policy, and 18 for SI. The transformer
fixture used 15--16, 17--18, 18--25, and 19--21 respectively. All endpoints
passed the declared physical KKT contract and no restoration occurred. The
large 18--25 range for the high-base transformer policy is start sensitivity,
not repeat noise: each five-run stratum was internally deterministic.

Global Jacobian proxies must not be interpreted as a policy score. For example,
the lower local-base transformer policy reduced solver work while its condition
proxy was roughly 2.5--4.3 times classic at the retained starts. Conversely SI
produced very large norm-spread/condition proxies and more work. Family-level
geometry and trace evolution, rather than a single initial-point scalar, are
the next attribution target.

The runner writes both the full evidence artifact and a `-summary.json`
companion. The summary keeps case/stratum gates, policy ranges, and comparison
summaries while omitting repeated matrices and endpoint details; scientific
audits should retain the full artifact.

The AC/DC successor is `benchmarks/bmopf_acdc_scaling_campaign.jl`. It adds a
native converter-contract gate to the same matched-run machinery and treats P/V
versus droop/V control as separate case strata. The first bounded run qualified
32/32 solves across classic, SI, rating-aligned, and asymmetric AC/DC power
bases, with native and 0.1% perturbed starts and two fresh repeats. Solver work
changed direction with the start and controller mode: SI and the rating-aligned
policy were cheaper at the native P/V start, while classic was cheaper for the
perturbed droop case. Initial dense condition-proxy ordering did not predict
those directions. The evidence therefore supports the campaign design and
rejects proxy-only policy selection; it does not establish a best base
allocation.

The bounded successor is
`benchmarks/bmopf_acdc_base_grid_campaign.jl`. It runs a qualified full `2^3`
factorial over the two AC-zone power bases and the DC power base, preserving
controller and physical-start strata. Its first 72-solve run qualified every
cell. A higher DC base improved the initial condition proxy by 1.29--1.65
decades in every stratum, but solver work had no corresponding stable main
effect. In the native droop/V stratum all eight cells used six callback records
and four line-search trials despite more than two decades of condition-ratio
variation. This strengthens the negative result: model-coordinate geometry is
relevant evidence, but not a standalone policy-selection rule.

The next retained fixture is
`benchmarks/bmopf_acdc_multiconverter_campaign.jl`: three AC voltage zones,
three converters, and a meshed three-node DC network. Its complete `2^4`
campaign qualified 136/136 solves. At the perturbed P/V start, classic
coordinates required 52 callback records, 166 line-search trials, and 39
positive regularization records per replicate, versus 21--24 records and
20--27 trials across the factorial cells. Perturbed droop sharing instead
remained at 19--20 records. The artifact retains the dominant moving row and
column families and clearly marks Ipopt factorization telemetry as unavailable;
regularization is a solver proxy, not a factorization count.

Its matched linear-work companion is
`benchmarks/bmopf_acdc_multiconverter_madnlp_campaign.jl`. It disables
primal-point capture and trace-family geometry because MadNLP's public callback
has no stable primal-vector accessor. It instead requires complete monotone
cumulative factorization, backsolve, linear-solver-time,
derivative-evaluation, and refinement telemetry for all 16 cells. Unsupported
inertia, pivot, fill, and backward-error fields must remain explicitly
unavailable. Linear-work attribution has its own qualification gate and does
not override the shared endpoint contract.

The runner also retains `objective_weight_consistency` from the physical
stationarity report. This is a read-only representational check: it compares
the configured MOI objective weight with global and coordinate-local weights
fitted against the supplied public multiplier representative. A materially
different fitted weight is reported as a potential normalization mismatch; the
adapter never uses it to repair multipliers or to make KKT acceptance pass.
The screen does not distinguish global solver normalization from a nonunique
dual representative or redundant fixed-coordinate equations; that distinction
requires a reduced model oracle.

For solvers that eliminate fixed variables, the endpoint adapter optionally
accepts `complete_fixed_variable_duals=true`. This constructs a second
multiplier representative by enforcing stationarity only through scalar
`VariableIndex`-in-`EqualTo` rows. The returned report retains
`public_solver_multiplier_report`, records every changed row, column, original
and completed multiplier, and labels the acceptance basis explicitly. It never
changes the solver snapshot, free-coordinate stationarity, non-fixed
multipliers, primal feasibility, or termination status. An unavailable or
invalid completion falls back to the public report with a reason; it is not a
silent acceptance mechanism.

The rerun using this contract qualifies all 68 P/V cells. Public reports still
fail at the fixed source-voltage coordinates, while all 68 explicit completed
representatives pass the common endpoint gate. Droop remains unqualified due
to two local-infeasibility and two iteration-limit results at the native start,
and four of each at the perturbed start. Consequently only the P/V factorial
effects are currently suitable for scaling claims.

The feeder-scale successor is
`benchmarks/bmopf_acdc_feeder_policy_campaign.jl`. It namespaces and embeds a
selected ENWL LN or LG feeder as AC zone 2 of the retained P/V AC/DC mechanism,
then runs classic, all-low, AC2-high-only, all-high, and an interaction control
under matched starts with Ipopt and MadNLP. This embedding is explicit in the
artifact because the corpus does not contain a native multi-zone AC/DC feeder;
results must not be reported as though it did.

The runner is sparse-only. Admission limits cover variable and constraint
counts, stored Jacobian entries, and the maximum number of trace-Jacobian entry
evaluations; every covariance and geometry call receives
`max_dense_entries=0`. Ipopt retains selected semantic-family trajectories and
regularization proxies. MadNLP retains cumulative factorization/backsolve and
derivative work, plus separate public and completed multiplier reports. Case
hashes, namespacing, feeder component counts, policy roles, starts, and the
cross-solver start fingerprint gate are serialized.

Whole-model intervention verification remains sparse even when its equivalent
dense coordinate relation exceeds the configured dense-work budget. Raw
Jacobians, iterate vectors, and endpoint payloads are used to derive the gates
but are not retained in feeder campaign artifacts. Compact checkpoints are
written atomically after each start stratum and solver, preventing a long
feeder run from producing multi-gigabyte JSON or losing an entire solver block.

On the qualified 30-bus LN run, all five policies reach accepted physical
endpoints under both solvers and both starts. AC-zone-2-high-only improves
native-start work relative to all-low, but the same intervention substantially
increases Ipopt regularization/line-search work and MadNLP
factorization/backsolve work from the perturbed start. Consumers should retain
stratum-level contrasts; pooling these starts would erase the principal result.

Volt-Watt controller constraints now have a physical residual-scale contract.
`ibr_p_volt_watt` is a power inequality, so its row scale is the local IBR bus
power base. Omitting it previously made complete physical transport correctly
unavailable on ENWL cases with active PV profiles.
