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
