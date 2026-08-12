# NLPDiagnostics.jl

> Advanced research prototype: public APIs and finding codes may evolve, and
> numerical or physical interpretations remain subject to documented
> calibration gates.

NLPDiagnostics.jl is an evidence-first, solver-independent debugger for
nonlinear optimization models expressed through JuMP and
MathOptInterface (MOI).

It also serves as an experimental measurement platform for numerical-method
development. Its job is to separate observations from hypotheses, preserve the
evidence needed to test those hypotheses, and compare controlled interventions.
It does not assign a single model-health score, silently rewrite a model, or
claim a physical cause from one local numerical observation.

The package is in a consolidation-and-calibration phase. The current implementation takes a
read-only snapshot through the public MOI model API and reports:

- inconsistent, repeated, and fixing variable bounds;
- satisfied and infeasible constant constraints;
- exact canonical duplicate affine, quadratic, and nonlinear constraints; and
- variables disconnected from the objective and non-domain constraints;
- set-aware variable–constraint incidence graphs; and
- disconnected structural equation components;
- free/fixed/parameter variable and equality/inequality constraint roles;
- deterministic equality matching and unmatched-node findings; and
- Dulmage–Mendelsohn partitions and irreducible well-determined blocks;
- renderer-neutral graph data; and
- deterministic terminal and Graphviz DOT graph output;
- expression-node provenance and conservative interval propagation; and
- proven/possible nonlinear operator-domain findings;
- explicit point-tagged objective, constraint, gradient, and Jacobian probing;
- `NLPBlock` and nonlinear-oracle capability adapters;
- operating-point domain and non-finite evaluation findings; and
- Jacobian row/column scale summaries;
- semantic block-linear physical covariance for diagonal and complex-pair
  transformations, with explicit set contracts, orthogonal singular-value
  invariance checks, and guarded multiplier/stationarity/Hessian/KKT mapping;
- round-trip-certified transport of one physical state between scaling
  policies, with distinct transported-point provenance;
- serializable native solver-trace plus physical-endpoint artifacts that keep
  coordinate semantics separate instead of comparing unlike residuals;
- score-free matched scaling-run comparisons gated by physical covariance,
  endpoint KKT acceptance, native metric semantics, and semantic row/column
  family coverage;
- repeated scaling-campaign aggregation with common-start covariance,
  provenance, termination, and negative-control gates, plus a dedicated small
  BMOPF magnitude-only campaign runner;
- explicit classification of identity, positive magnitude, phase-like
  orthogonal, combined, and general linear coordinate interventions, while
  reserving physical complex-phase claims for domain metadata;
- per-residual physical feasibility, per-coordinate stationarity, and
  scalar-side complementarity contracts using point-verified public MOI
  solver duals, with coupled-cone dual transforms kept explicitly unavailable;
- BMOPFTools-backed authoritative real/imaginary and active/reactive block
  maps, including local rating provenance, singleton coverage, and positive
  plus changed-physics covariance controls, with registry-family attribution
  of physical KKT residuals;
- guarded local Jacobian rank, conditioning, and nullspace evidence; and
- checked sparse/MOI Jacobian product operators with explicit product
  provenance for large-model numerical-method experiments; and
- opt-in single- and deterministic multi-seed Golub--Kahan Ritz projections
  with direct lifted residual, orthogonality, cross-seed principal-angle, and
  guarded dense-oracle calibration evidence; and
- an opt-in restarted locally optimal smallest-direction candidate tracker
  with convergence histories, matrix-free normal products, and explicit
  adversarial dense-oracle disagreement evidence; and
- an independent thick-restarted zero-target harmonic Golub--Kahan candidate
  tracker, projected-metric diagnostics, target-local dense calibration, and a
  dense-free cross-backend value/subspace check; and
- controlled row/column scaling interventions for that crosscheck, with
  transformed-coordinate labels and mapped residual audits against the
  original Jacobian; and
- a guarded rank-revealing SuiteSparseQR nullspace construction with direct
  original-Jacobian residuals, factor-fill evidence, and small-case dense-SVD
  subspace calibration; and
- identical- and nearby-point sparse-QR persistence checks using principal
  angles, basis-invariant coordinate leverage, plugin coordinate groups, and
  explicit physical-readiness gates; and
- controlled formulation-intervention comparisons with fixture, numerical-
  policy, dependency-source, dimension, rank, nullity, and support gates; and
- explicit Hessian-of-the-Lagrangian and reduced-Hessian curvature tools;
- reproducible solver-independent formulation profile cases; and
- finite first- and second-derivative domain checks;
- overflow, underflow, and stable-expression fingerprints; and
- explicit MOI initialization analysis without invented default starts.
- optional Ipopt/MadNLP iteration-trace capture through public solver callbacks.

```julia
import MathOptInterface as MOI
using NLPDiagnostics

model = MOI.Utilities.UniversalFallback(MOI.Utilities.Model{Float64}())
x = MOI.add_variable(model)
MOI.add_constraint(model, x, MOI.GreaterThan(10.0))
MOI.add_constraint(model, x, MOI.LessThan(5.0))

report = analyze(model)
display(report)
```

JuMP models can be analyzed directly when JuMP is loaded:

```julia
using JuMP
using NLPDiagnostics

model = Model()
@variable(model, x >= 0)
@constraint(model, sin(x) <= 1)

report = analyze(model)
```

Numerical analysis is opt-in because every conclusion is local to an explicit
point:

```julia
point = evaluation_point(model, [0.5]; label = "initialization")
report = analyze(model; point = point)

# Reuse a captured evaluation without probing the model again:
report = analyze(model; evaluation = evaluation)

# Or inspect complete MOI/JuMP start values:
initial_report = analyze(model; check_initialization = true)
```

When the optional solver extensions are loaded, a solve can return an
evidence-preserving iteration trace in one call:

```julia
using Ipopt
trace = ipopt_optimize_with_iteration_trace!(model; capture_points = true)
```

`madnlp_optimize_with_iteration_trace!` provides the analogous MadNLP helper;
MadNLP captures solver metrics and phase labels but does not fabricate primal
points when its callback API does not expose them.
For a combined artifact, `ipopt_profile_with_iteration_trace!` and
`madnlp_profile_with_iteration_trace!` return a `SolverTraceProfileRun` with
both the frozen trace and the final solver-result profile; it can be exported
with `profile_result_data`.
Iteration records retain available barrier, step, regularization, and line-search
telemetry and explicitly label the coordinate/scaling convention of solver
metrics. Unknown conventions remain unknown rather than being inferred.

Each finding separately records:

- what was observed and why it matters;
- severity;
- mathematical, numerical, physical, or representational domain;
- mathematical, structural, physical, numerical, local, or heuristic evidence;
- confidence;
- inspectable evidence and affected model entities; and
- suggested actions.

NLPDiagnostics never modifies the source model.

See [`docs/mission_and_scope.md`](docs/mission_and_scope.md) for the package
mission, evidence contract, present non-goals, and definition of done for a new
finding family. See [`docs/architecture.md`](docs/architecture.md) for the
stable design decisions, and
[`docs/moi_nonlinear_api.md`](docs/moi_nonlinear_api.md) for the public MOI
capability survey.

The ordered implementation plan is maintained in
[`docs/roadmap.md`](docs/roadmap.md).
The evolving hypotheses, invariants, negative-result protocol, experiment
ladder, and publication boundary for flexible nondimensionalisation and complex
block scaling are maintained in
[`docs/nondimensionalisation_research.md`](docs/nondimensionalisation_research.md).
The executable objective-bearing scaling protocol is
[`benchmarks/bmopf_stratified_scaling_campaign.jl`](benchmarks/bmopf_stratified_scaling_campaign.jl):
it uses repeated fresh models and matched physical-start strata, and reports
qualified evidence ranges without assigning a policy score.
Captured Ipopt iterates can additionally be summarized as BMOPFTools
registry-qualified Jacobian row/column-family trajectories; solver
factorization telemetry remains explicitly solver-capability dependent.
The companion
[`benchmarks/bmopf_stratified_madnlp_campaign.jl`](benchmarks/bmopf_stratified_madnlp_campaign.jl)
runs the same physical experiment contract with MadNLP and retains its public
cumulative factorization and backsolve evidence.
The package, solver-extension, domain-extension, and scientific-calibration
test boundaries are documented in [`docs/testing.md`](docs/testing.md).
Bounded empirical results and their trust limitations are recorded in
[`docs/calibration_results.md`](docs/calibration_results.md).
Structural matching semantics are documented in
[`docs/structural_analysis.md`](docs/structural_analysis.md).
Expression-domain evidence semantics and extension hooks are documented in
[`docs/expression_domains.md`](docs/expression_domains.md).
Numerical capability, cache, and scaling semantics are documented in
[`docs/numerical_analysis.md`](docs/numerical_analysis.md).
Derivative domains, stable expressions, and initialization are documented in
[`docs/derivatives_stability_initialization.md`](docs/derivatives_stability_initialization.md).
Profiling cases derived from the attached OPF papers are recorded in
[`docs/research_profiling_cases.md`](docs/research_profiling_cases.md).
