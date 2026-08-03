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
per-case/aggregate finding-code counts.

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

Set `NLPDIAGNOSTICS_BMOPF_SOLVER=madnlp` only when MadNLP is installed in the
selected benchmark environment. `NLPDIAGNOSTICS_BMOPF_CAPTURE_POINTS=true`
enables Ipopt callback primal vectors; leave it false for a compact metrics
trace. This solve runner is intentionally separate from the structural corpus
runner so large-case campaigns cannot acquire a solver workload implicitly.
Use `NLPDIAGNOSTICS_BMOPF_SOLVER_OPTIONS=max_iter=500,tol=1e-8` for explicit
solver attributes and `NLPDIAGNOSTICS_BMOPF_PER_UNIT=false` to reproduce a
model-native/SI build. Both choices, along with the solver objective convention
and objective-comparison reference, are retained in each JSON record. MadNLP
callback objectives are unscaled before capture so they can be compared with
the recomputed MOI objective; this does not reinterpret the solver's dual or
constraint-residual scaling.
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
mismatches explicitly rather than attributing them to solver quality.

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
`bmopf_set_start_values!` is for callers using BMOPFTools' lower-level staged
construction before that stage has run. The optional `prepare_context` callback
in `bmopf_build_and_profile` and `bmopf_build_and_analyze_opf` is a generic
post-build/pre-KCL hook; callers must use only lifecycle stages legal at that
point.

`bmopf_result_voltage_point(context, result; result_units = :si)` maps public
rectangular bus-voltage records plus line, load, voltage-source, IBR, switch,
and ground current records. It converts SI values through public per-bus
voltage/current bases and returns mapped, registered, unresolved, and fallback
counts by semantic family. Coordinates not represented in the result retain an
explicit fallback, so the point remains a partial-result probe rather than a
claim that the saved solution fully specifies every control or auxiliary
coordinate.

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

The draft corpus runner exposes this adapter as
`NLPDIAGNOSTICS_BMOPF_POINT_POLICY=saved_result`. By default it reads the
adjacent `_result_si.json` file. Set `NLPDIAGNOSTICS_BMOPF_RESULT_UNITS=model`
and/or `NLPDIAGNOSTICS_BMOPF_RESULT_SUFFIX=...` only when the file's numerical
coordinates genuinely use those conventions. Its JSON record persists the
mapping coverage and exact result path, making any fallback visible in a
benchmark comparison.
