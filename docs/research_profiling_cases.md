# Research profiling cases from the attached OPF papers

This note translates two attached papers into proposed NLPDiagnostics
profiling cases:

1. F. Geth, A. C. Chapman, R. Heidari, and J. Clark,
   *Considerations and design goals for unbalanced optimal power flow
   benchmarks*, Electric Power Systems Research 235 (2024) 110646.
2. F. Geth, F. Pacaud, and R. Heidari,
   *Solving Three-Phase Distribution OPF with Nonlinear Programming*,
   PSCC 2026 preprint.

The papers support a matrix of profiling cases rather than a single OPF test.
Each profile should preserve the physical task while varying one modeling,
initialization, scaling, or algorithmic decision.

## Proposed profile matrix

| Profile | Controlled variation | Generic core evidence | Plugin interpretation |
|---|---|---|---|
| Reference and gauge | no angle reference, one angle, three angles, fully fixed phasor | structural unmatched variables, right nullspace, dependent equalities | global angle gauge and voltage-source degrees of freedom |
| Sequence initialization | positive, negative, and zero phase rotation | exact-point values, feasibility margins, Jacobian/Hessian changes | positive-, negative-, and zero-sequence fingerprints |
| Angle/sequence constraints | absent, direct angle-difference, sequence bounds | active-set structure and constraint dependence | operational phase order and observability |
| Formulation family | IVR, SVR, SVP for the same network/task | dimensions, sparsity, evaluation time, derivative method, rank, reduced Hessian | formulation semantics |
| Power-base sweep | distribution-scale through transmission-scale bases | row/column scales, KKT tolerance semantics, objective consistency | per-unit bases and physical units |
| Low impedance | ideal connection versus decreasing positive impedance | coefficient spread, Jacobian condition, near-null modes | switch or ideal-link semantics |
| Missing-phase padding | native conductor count versus padded matrices and zero-current equations | fixed/unused variables, redundant rows, graph size, solve profile | absent terminals and component port rank |
| Degree-two buses | original series branches versus merged equivalent | graph pattern, redundant state coordinates, conditioning | topology-preserving network reduction |
| Generator symmetry | colocated equal-cost resources, reactive circulation | flat objective directions and reduced-Hessian nullspace | generator sharing/circulating reactive power |
| Balanced-data symmetry | balanced versus perturbed phase data | repeated expression/data fingerprints and nullspace multiplicity | expected phase permutation or sequence symmetry |
| Delta/wye alternatives | delta, grounded wye, neutral wye, floating wye | different structural ranks and nullspaces | star-point visibility and physical equivalence |
| Kron-reduction metadata | physical three-wire versus reduced four-wire data | representational ambiguity finding | valid neutral-current bounds and connection rules |

## Quantitative regression targets

The attached examples provide useful qualitative and quantitative anchors:

- Padding a 2-by-2 impedance representation to 3-by-3 increased one reported
  solve from roughly 1.43 seconds and 22 iterations to roughly 128 seconds and
  590 iterations. The profiler should explain the extra variables and
  equations before comparing timing.
- A small nonzero impedance substitution increased the reported Ipopt
  iteration count from 12 to 16 in one radial-network example. A sweep toward
  zero is a direct near-singularity profile.
- In the PSCC formulation comparison, the IVR reduced Hessian had a reported
  condition near `1e14`, with a smallest eigenvalue around `1.5e-8`, despite an
  equality-Jacobian smallest singular value around `1.8e-2`. This is a key
  case where "Jacobian rank looks acceptable" must not be confused with
  second-order well-conditioning.
- SVP used fewer variables than IVR in the selected example but incurred
  materially more automatic-differentiation and linear-system cost. Model
  dimension alone is therefore an inadequate complexity proxy.
- Power bases above the distribution-scale reference changed objective
  accuracy despite nominally identical stopping tolerances. Reports should
  retain physical units, scaling transformations, and solver tolerance
  semantics together.
- Zero or negative phase-rotation initialization combined with some
  voltage-source models produced the highest failure counts, whereas a
  positive-sequence start plus angle or sequence constraints was robust. This
  motivates initialization families as first-class benchmark parameters.

These numbers should be used as behavioral anchors, not hard-coded package
thresholds.

## Core versus plugin ownership

The generic core can own:

- expression and derivative evaluation cost;
- structural decomposition;
- exact-point initialization checks;
- Jacobian/Hessian scales, ranks, and nullspaces;
- repeated or nearly repeated algebraic structure;
- model dimensions and sparsity;
- solver-independent evaluation failures; and
- comparisons between labeled formulations of the same task.

An OPF or multiconductor plugin should own:

- component terminals and ports;
- expected conductor count and connection matrices;
- voltage angle reference semantics;
- positive/negative/zero-sequence interpretation;
- expected gauges and star-point modes;
- per-unit bases and physical units;
- ideal switch, transformer, grounding, and regulator semantics; and
- whether a Kron or delta/wye transformation preserves the intended physical
  task.

This division follows the papers' separation between engineering data, task,
formulation, and solver layers.

## Suggested implementation order

1. Add dense rank and nullspace estimates for small profiling models, always
   recording scale, method, threshold, and point.
2. Add Hessian and reduced-Hessian adapters to reproduce the IVR versus
   SVR/SVP second-order contrast.
3. Use the implemented `ProfileCase` and `profile_case` runner to retain
   formulation, initialization, scale, solver-label, expected-evidence, cache,
   timing, and derivative-provenance data for each case. Timings are local
   runtime observations and should be collected after warm-up before comparing
   formulations.
4. Add true per-callback invocation counters by source and derivative feature.
5. Connect PMDlab and the open unbalanced benchmark data through an optional
   PowerModelsDistribution extension.
6. Add component metadata and expected-nullspace assembly before attempting
   automatic physical classification.
