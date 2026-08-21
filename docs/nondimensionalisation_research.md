# Nondimensionalisation and block-scaling research programme

This document is the living research record for scaling experiments in
NLPDiagnostics.jl and BMOPFTools.jl. It records hypotheses before implementation,
the evidence required to accept or reject them, negative results, and the boundary
between a useful implementation feature and a defensible scientific contribution.

The document is intentionally updated when an idea fails. A failed hypothesis is
not removed or rewritten as success: it is retained with the case, numerical
policy, evidence, and reason for rejection. This prevents repeated dead ends and
keeps the eventual publication claims auditable.

## Research question

Can physically and algebraically justified local scaling and complex block
transformations improve the reliability or efficiency of nonlinear power-system
algorithms, while preserving the physical problem and making the mechanism of any
improvement measurable?

The project does not assume that one strategy is universally best. It seeks to
identify which layer changed and which mechanism explains an observed result:

1. physical nondimensionalisation of variables and parameters;
2. residual or constraint scaling;
3. objective scaling;
4. solver-internal NLP scaling;
5. KKT linear-system equilibration or preconditioning;
6. complex/block coordinate rotation; or
7. formulation- or relaxation-strength changes.

These layers must not be merged into one "conditioning score".

## Candidate novelty ledger

| Candidate contribution | Current status | Required evidence before promotion |
|---|---|---|
| Semantic, per-residual-block physical scaling for multiconductor NLP models | Hypothesis | Complete scale contracts; physical covariance; matched solver campaigns; robustness across operating points and case families |
| Block-linear covariance for real representations of complex scalings | Implemented; small truth gate | Extend set/formulation coverage, side-specific complementarity, and BMOPFTools semantic-block declarations |
| Separation of physical scaling, algebraic equilibration, and algorithm-aware rotation | Strong conceptual candidate | Demonstrate experimentally that the three mechanisms produce distinguishable signatures and outcomes |
| Complex rotations as a way to improve the exact full-Jacobian 2-norm condition number | Rejected for complete unit-magnitude orthogonal transformations | Retain the singular-value invariance proof and regression tests; apparent counterexamples indicate an incomplete transformation or measurement issue |
| Complex rotations for block decoupling and preconditioner design | Hypothesis | Invariant full singular spectrum together with reduced declared cross-block coupling and improved matched algorithmic work |
| Complex rotations for QC-relaxation tightening | Literature-supported; implementation not yet calibrated here | Reproduce global rotations, then compare per-line rotations and intersections using gap, envelope, work, and model-size evidence |
| Robust multi-point scaling instead of initialization-only Jacobian scaling | Hypothesis | Out-of-sample points, perturbations, time snapshots, clipping sensitivity, and solver comparisons |
| Evidence-first scaling benchmark protocol for nonlinear models | Strong infrastructure candidate | Reusable artifacts, transformation proofs, physical stopping semantics, paired campaigns, and false-positive/negative calibration |

Statuses are `hypothesis`, `design target`, `implemented`, `calibrated`,
`supported`, `rejected`, or `inconclusive`. "Novel" and "publishable" are not
statuses. They are conclusions drawn only after literature comparison and the
promotion gates below.

## Mathematical invariants and proof obligations

Every scaling strategy declares whether it is intended to preserve the exact
mathematical problem, change solver coordinates, change a numerical algorithm,
or change an approximation.

For a real residual pair `r` and an orthogonal representation `R` of a
unit-magnitude complex scalar,

```text
r_rot = R * r
J_rot = R * J
J_rot' * J_rot = J' * J.
```

Thus complete orthogonal residual rotations preserve the singular values of the
full Jacobian in the Euclidean norm. Block-diagonal per-bus or per-device
orthogonal transformations preserve the same invariant. A result that claims a
better full-Jacobian 2-norm condition number from phase alone must fail the
truth gate until the discrepancy is explained.

This does not imply algorithmic irrelevance. Orthogonal rotations can alter
componentwise norms, block coupling, sparse pivot choices, fill, finite-precision
cancellation, solver scaling, merit/filter behavior, and approximate
preconditioners. They also change representation-dependent relaxation envelopes.
Those effects require distinct metrics and distinct claims.

Set semantics constrain allowed residual transformations:

- zero equalities permit nonsingular mixing when the entire block is transformed;
- circles and second-order cones admit appropriate orthogonal symmetries;
- scalar intervals and rectangular `P/Q` boxes do not remain independent boxes
  after a general rotation; and
- unsupported coupled-set transformations are unavailable, never approximated as
  diagonal scaling.

## Strategy families to evaluate

### Physical magnitude policies

- SI coordinates;
- classic per-unit coordinates;
- global power-base sweeps;
- compatible voltage-zone bases;
- local device-rating bases; and
- semantic bus, port, branch, converter, and controller residual bases.

Current, impedance, and admittance bases must remain dimensionally compatible
with voltage and power bases. Independent bases are allowed only when the engine
equations contain the corresponding conversion coefficients explicitly.

### Algebraic policies

- fixed row normalization at a declared point;
- projected row normalization after variable scaling;
- robust multi-point row normalization using a declared aggregation rule;
- Ruiz-style row/column equilibration; and
- KKT-aware scaling or preconditioning.

Initialization-only policies are not presumed to generalize. Multi-point policies
must identify calibration and held-out points. Scale factors must record clipping,
floors, ceilings, and update frequency.

### Complex and block policies

- global complex rotation;
- voltage-zone, bus, device, and port rotations;
- rotations selected to minimize a declared off-block coupling measure;
- magnitude-plus-phase block scaling; and
- relaxation-specific global and per-line rotations.

Magnitude and phase effects are isolated before they are combined.

## Experiment ladder

Experiments advance only when the preceding gate passes.

1. **Transformation truth.** Map the same physical point and compare variables,
   functions, sets, violations, objective, derivatives, and physical parameters.
2. **Local optimality covariance.** Compare active sets, multipliers,
   stationarity, complementarity, Hessian-of-the-Lagrangian, reduced curvature,
   and KKT structure in common physical coordinates.
3. **Numerical mechanism.** Measure row/column distributions, rank-policy
   stability, singular invariants, block coupling, pivots, fill, inertia,
   regularization, and linear-solve work.
4. **Matched nonlinear solves.** Hold the physical start, stopping semantics,
   solver version, linear solver, limits, and unrelated options fixed. Run model
   scaling with solver-internal scaling both disabled and explicitly controlled.
5. **Robustness.** Repeat across time points, feasible perturbations, starts,
   case strata, and resource budgets. Separate calibration from held-out cases.
6. **Algorithm intervention.** Change the numerical method predicted to benefit
   from the measured mechanism and test that prediction.

Relaxation experiments use a parallel ladder but compare bound quality, envelope
error, node count, work, and formulation size rather than treating the relaxation
as an equivalent exact NLP.

## Evidence recorded for every experiment

Every machine-readable experiment artifact should include:

- hypothesis identifier and predicted mechanism;
- source case, formulation, time point, and physical-state identity;
- scaling policy type, parameters, provenance, and semantic coverage;
- calibration points and held-out points;
- transformation class and proof obligations;
- unsupported variables, residuals, sets, or derivative rows;
- solver and linear-algebra versions and complete relevant options;
- physical and solver-coordinate tolerance semantics;
- derivative provenance and numerical rank policy;
- elapsed time, memory, factorization work, iterations, restoration and
  regularization events; and
- positive, negative, unavailable, and contradictory evidence.

No composite model-health or scaling score is used. Policies are compared using
paired evidence and Pareto summaries. A smaller condition proxy is an observation,
not proof of a better nonlinear method.

## Claim-promotion gates

A proposed contribution can be described as supported only after it has:

1. passed exact covariance or been explicitly classified as a changed
   formulation/algorithm;
2. passed positive and negative truth-labelled controls;
3. reproduced across more than one operating point and case family;
4. survived tolerance, clipping, and rank-policy sensitivity checks;
5. produced mechanism evidence, not only runtime correlation;
6. been tested with solver-internal scaling controlled;
7. reported failures, timeouts, and unavailable evidence; and
8. been compared with the closest published and solver-native baselines.

A publishable claim additionally needs a frozen benchmark protocol, held-out
cases, effect sizes with uncertainty, resource accounting, and a literature
review showing that the mechanism or evidence framework is not already standard.

## Dead-end and negative-result protocol

When a strategy fails, record:

- the original prediction;
- the smallest reproducing case;
- whether truth, covariance, numerical-mechanism, solver, or robustness evidence
  failed;
- whether the result rejects the mechanism or only the implementation;
- the policy and dependency versions; and
- the decision to reject, revise, or retain the strategy as inconclusive.

Regression tests should preserve mathematical dead ends that are likely to recur.
Examples include singular-value invariance under complete orthogonal rotations,
incorrect rotation of rectangular inequality sets, and false improvement caused
by comparing different physical starts or stopping tolerances.

## Immediate implementation sequence

1. **Implemented:** introduce a generic semantic block-linear scaling map, with
   diagonal scaling as its one-dimensional special case.
2. **Substantially implemented:** add set-transform contracts and covariance
   for multipliers, stationarity, Hessians, and KKT systems. Zero equalities,
   positive-diagonal boxes, and conformal Euclidean balls are covered. Public
   solver endpoint duals now close scalar-side complementarity; general
   coupled-cone dual transforms remain open.
3. **Implemented for native pairs:** BMOPFTools metadata exposes paired
   coordinate/residual blocks and selected local physical ratings without
   inferring semantics from JuMP names. Nonzero equality sets remain scalar
   bounds rather than being falsely treated as origin residuals.
4. **Implemented for five engine-backed formulation classes:** validate a
   classic-versus-custom policy through the engine declarations for line/load,
   single-phase transformer, unbalanced wye-delta transformer, three-winding
   transformer, and an AC/DC converter tie. Every class has a changed-physics
   negative control.
5. **Implemented for the small line/load truth case:** solve once and transport
   the shared physical state through SI, classic, and two custom policies.
6. **Implemented for scalar-bound endpoints:** physical primal, stationarity,
   dual-feasibility, and complementarity acceptance are explicit and tied to a
   point-verified public MOI dual snapshot.
7. **Implemented for two compact objective-bearing case classes:** run
   magnitude-only fixed-policy experiments with repeated, physically matched
   start strata.
8. Run phase-only singular-invariance and block-coupling experiments.
9. **Implemented for magnitude-only Ipopt experiments:** run combined and
   matched solver experiments only after those gates pass.
10. Treat QC/RQC/TRQC experiments as a separate approximation-strength study.

## Current publication boundary

The most credible prospective contribution is currently the evidence framework:
semantic block scaling with exact physical/KKT covariance, paired with experiments
that distinguish physical nondimensionalisation, algebraic equilibration,
algorithm-aware complex rotation, and relaxation changes.

No claim is yet made that local bases improve solver performance, that one policy
dominates classic per-unit, or that complex rotations improve exact NLP
conditioning. Those remain experimental questions.

The first block-covariance truth fixture now validates arbitrarily positioned
two-coordinate variable and residual rotations, objective scaling, sparse
Jacobian covariance, multiplier inverse-transpose mapping, stationarity,
Hessian-of-the-Lagrangian covariance, and the physical saddle-point KKT matrix.
It also retains three negative/coverage controls: incorrect multipliers fail,
rotated scalar boxes are unavailable, and non-orthogonal magnitude blocks do not
claim singular-value invariance. This promotes the transformation machinery to
implemented status, not the scaling-performance hypotheses.

The first engine-backed fixture now closes the same gate through BMOPFTools'
public `OpfSemanticBlock` registry. Classic 1 MVA per-unit and custom 500 V /
200 kVA coordinates agree in common physical block coordinates for points,
constraint functions, sets, violations, and sparse Jacobians. A changed line
resistance fails the Jacobian gate. Load nominal apparent power is preserved as
a provenance-bearing candidate reference scale; it is not silently applied as
a row scaling. This is the first end-to-end evidence that local ratings can be
studied without confusing a unit conversion, a model mutation, and an
algebraic equilibration policy.

The formulation-breadth gate now covers four additional small engine-backed
cases. It distinguishes transformer-side voltage and current units, referred
n-winding ampere-turn and leakage residuals, delta/wye incidence, coil-power
auxiliaries, AC/DC converter power balance, resistive-versus-ideal DC branch
residual units, and DC KCL. Positive two-norm limits are recorded as normalized
dimensionless rows because BMOPFTools stamps `(a/limit)^2+(b/limit)^2 <= 1`;
their underlying coordinates retain physical current or power units. Treating
those rows as current-squared or power-squared was a representational error
found by constraint-set covariance and is now a regression-tested dead end.

All four new classic-versus-custom comparisons pass point,
constraint-function, set, violation, and sparse physical-Jacobian covariance.
A 20% change to the relevant transformer winding or DC-line resistance fails
the Jacobian gate. This expands confidence in the comparison machinery, but it
still does not show that any scaling policy improves a solver.

### Shared physical states and stopping semantics

`transport_scaling_point` is the experiment boundary for holding the physical
state fixed while changing model coordinates. It converts the source point to
declared physical semantic coordinates, aligns keys, applies the target inverse
map, and checks the reconstructed physical state. Its output is intentionally a
`TransportedPoint`, not a target `SolverResultPoint`. A scaling experiment must
still evaluate that point in the target model and pass physical covariance.

The first solved-state experiment uses one Ipopt endpoint from the classic
per-unit line/load fixture and transports it to SI plus two custom policies.
All four coordinate systems agree on physical residuals and sparse physical
Jacobians within the declared tolerances. This is necessary reproducibility
evidence, not evidence that any policy is faster or more robust.

Stopping tolerances are dimensional contracts, not solver-option aliases.
`physical_feasibility_report` accepts per-residual or per-block tolerances; its
BMOPFTools adapter can expand them from physical quantities. It never computes
a maximum across unlike voltage, current, power, and squared-residual units.
`physical_stationarity_report` likewise requires tolerances per physical
variable coordinate and an explicit model-coordinate multiplier
representative.

The complete physical KKT endpoint report now reads a public solver dual only
after verifying that the derivative evaluation and selected primal result are
the same point. MOI greater-than and less-than signs determine lower and upper
sides exactly; interval constraints retain a documented minimum-support sign
split of the aggregate dual rather than an activity-tolerance guess. Positive
diagonal residual maps transform each side's slack and multiplier inversely,
so their product is invariant. Rotated boxes and general coupled cones remain
unavailable pending a full dual-cone contract.

Matched solver campaigns must retain both layers:

1. native solver options and native scaled residual traces; and
2. an independently evaluated physical endpoint contract with declared units,
   tolerances, multiplier source, and coverage.

Only the second layer makes endpoint quality comparable across coordinate
policies. Identical Ipopt or MadNLP tolerance strings do not.

This pairing is now implemented by `solver_trace_physical_endpoint_data` and
the attributed BMOPF wrapper `bmopf_solver_trace_physical_endpoint_data`.
BMOPF family maxima make it possible to ask which equation or variable family
controls physical endpoint quality. They remain attribution, not causality:
the experimental design must still vary one scaling intervention at a time.

The next instrumentation gate is now implemented. The declared relation
between two semantic maps is classified independently of solver behavior, and
the matched-run artifact refuses qualification unless that observed algebraic
class agrees with the experimental intervention. This makes magnitude-only and
phase-only hypotheses falsifiable at the coordinate-map boundary before any
iteration count is inspected.

Family-resolved Jacobian geometry is retained on both axes. Consequently, a
candidate policy can be evaluated as a mechanism chain rather than a scalar
score:

1. the coordinate intervention has the intended algebraic class;
2. physical point, sets, residuals, and Jacobian pass covariance;
3. named equation and variable families exhibit the predicted local geometry
   change;
4. solver-native work changes under compatible telemetry semantics; and
5. both endpoints satisfy the same physical KKT contract.

Publication claims should follow that chain. A lower iteration count without
steps 1--3 and 5 is merely an observed solver run. A better local family norm
without step 4 is a mechanistic hypothesis, not an algorithmic improvement.

### First magnitude-only pilot

The first repeated pilot now passes the complete chain on the small line/load
truth fixture. Two fresh Ipopt runs were made for classic 1 MVA per-unit, SI,
local 500 V / 200 kVA, and local 1500 V / 5 MVA coordinates. All runs used the
same transported physical start, reached accepted physical KKT endpoints, and
were repeatable at the captured-work level. Provenance mismatch and omitted
intervention-evidence controls were both rejected.

The local-base policies were close to classic geometry and required the same
four callback records and three line-search trials. SI increased the local
condition proxy by roughly 384 times, increased both norm spreads by 1000
times, and reproducibly required one additional callback record and one
additional line-search trial. This is consistent with the proposed mechanism,
but the sample is deliberately too small for a solver-performance claim.

The pilot also found an important endpoint-design correction. Exact covariance
of residual vectors near zero rejected SI and the high-base policy because
their dimensional residuals differed by about `1.74e-4`, even though both
endpoints passed the same declared 1-unit physical feasibility contract and
their points and Jacobians agreed. Endpoint equivalence now requires the same
complete tolerance contract and accepted KKT endpoints while preserving the
raw residual difference as non-gating evidence. Same-point covariance remains
strict and unchanged.

### Objective-bearing, start-stratified magnitude campaign

The original results in this subsection predate the native-initialization
covariance correction. They remain useful as an audit trail, but the corrected
full cross-solver results below supersede their transformer work ranges.

The next campaign has now cleared the intended small-case evidence gate. It
uses an unbalanced three-phase line/load problem with cheaper local wye
generation and a two-voltage-level wye-delta transformer problem with cheaper
local delta generation. Thus objective value and gradient covariance are
exercised alongside the physical point, constraint functions, sets, Jacobian,
and KKT endpoint contracts.

For each case, four magnitude-only policies were run from three physical-start
strata (the native completed start and deterministic bounded perturbations with
seeds 11 and 29), with five fresh models per policy and stratum. BMOPFTools'
semantic registry transported each anchor point to every coordinate system.
All 120 solves terminated locally optimally; every common-start covariance,
physical endpoint, intervention, semantic-geometry, and matched-comparison gate
passed, and no run entered restoration.

The retained callback-record ranges were:

| Case | Classic 1 MVA | Local 0.65 V / 0.25 S | Local 1.5 V / 10 S | SI |
| --- | ---: | ---: | ---: | ---: |
| Three-phase line/load/generator | 12--13 | 11--12 | 13--14 | 18 |
| Wye-delta transformer/load/generator | 17--18 | 15--16 | 18--25 | 19--21 |

Here `V` and `S` denote factors relative to BMOPFTools' authoritative classic
voltage bases and each case's declared reference apparent power, not physical
units. The same ordering holds for line-search trials after subtracting one.
These are descriptive observations on two truth fixtures, not a ranking.

Three mechanism lessons are already credible enough to guide the next design:

1. raw SI coordinates create extreme global Jacobian norm-spread and condition
   proxies and consistently cost more work than classic per-unit on both cases;
2. the smaller local voltage/power bases reduced Ipopt work even though some
   global norm-spread or condition proxies became worse, so no single scalar
   geometry statistic is an adequate scaling objective; and
3. the aggressive high-power-base policy was strongly initialization-sensitive
   on the transformer (18--25 records), showing why matched physical-start
   strata are necessary before a policy is called robust.

The first pilot also calibrated two distinct contracts. Exact same-start
covariance remains at `1e-6` absolute and `1e-8` relative. Independently solved
endpoints use an explicitly declared `0.1` physical absolute / `2e-5` relative
neighborhood plus accepted KKT contracts; the maximum observed endpoint
coordinate difference in the rejected tighter pilot was about `0.063` physical
voltage units. Physical complementarity uses `1e-4`; the tighter `1e-5` screen
rejected otherwise accepted endpoints only through active-generator products
of roughly `3e-5`--`5e-5`. These sensitivity results are evidence for the
chosen campaign contract, not a change to Ipopt's `1e-8` stopping tolerance.

The experiment is reproducible through
`benchmarks/bmopf_stratified_scaling_campaign.jl`; its default artifact is
`work/bmopf-stratified-scaling-campaign.json`, with a compact inspectable
companion at `work/bmopf-stratified-scaling-campaign-summary.json`.

### Trace-resolved transformer pilot

The next mechanism layer is now executable. A bounded rerun used the
wye-delta transformer fixture, four policies, native and seed-11 physical
starts, two fresh replicates, and eight event-preserving Jacobian snapshots per
solve. All 16 runs had complete BMOPFTools registry coverage and qualified
row/column-family trajectories. The callback ranges reproduced the larger
campaign: 16 records for the lower-base policy, 17--18 for classic, 18--22 for
the aggressive high-base policy, and 21 for SI.

The family evidence explains why a single global condition proxy is
insufficient. In SI coordinates, transformer current-coupling columns reached
a within-family spread of about 6,351 and voltage-column median norms moved
from 1 to about 19.6, while transformer apparent-power-circle row norms were
around `1e-5`. The lower-base policy kept the inspected column-family spreads
near 1--2.1 and required the least work. The aggressive high-base policy kept
most current and voltage families near order one but grew transformer-coil
power columns strongly: the selected reactive-power family spread reached
about 17.6 and its endpoint median norm about 18.7.

Initialization adds a distinct signal. At the perturbed start, classic had two
positive regularization callback rows with a maximum of about 267, whereas the
aggressive high-base policy had two with a maximum of about 26,667. The
lower-base and SI runs had none. Thus regularization is neither interchangeable
with the global Jacobian proxy nor sufficient to explain SI's extra work. This
is association at captured iterates, not factorization causality: Ipopt does
not expose factorization count, inertia, pivots, fill, or linear-solver time
through its public callback.

The pilot also changed the measurement protocol. Uniform trace subsampling
could miss an early regularization event; bounded selection now preserves
solver events and only uses uniform points for the remaining budget. The full
pilot artifact is `work/bmopf-trace-geometry-pilot.json`; its compact companion
retains trajectories and telemetry summaries but omits individual Jacobian
snapshots.

### First MadNLP portability pilot

`benchmarks/bmopf_stratified_madnlp_campaign.jl` now runs the same
objective-bearing matched-start design with MadNLP. A bounded transformer run
used four policies, native and seed-11 strata, and two fresh replicates: all 16
solves terminated locally optimally, passed common-start and endpoint gates,
and were deterministic within each cell. Callback records were 16--17 for
classic, 16--17 for the lower-base policy, 19--21 for the aggressive policy,
and 20 for SI. This broadly reproduces the Ipopt ordering while showing that a
one-iteration classic/lower-base distinction is not portable evidence.

MadNLP adds a genuinely different evidence layer. Native-start first
replicates ended with 16, 17, 19, and 20 cumulative factorizations for classic,
lower-base, aggressive, and SI respectively. At the perturbed start, classic
used 23 factorizations for 17 callback records and the aggressive policy used
33 for 21; their maximum regularization sizes were about 267 and 71,111.
Lower-base used 16 factorizations and SI 20 with no positive regularization.
These counters show extra linear-system work that iteration counts conceal.
Sub-millisecond linear-solver timings are retained but are too small and noisy
for policy ranking in this fixture.

This is a solver-portability pilot, not the full default matrix. The next trust
step is the five-repeat, three-stratum, two-case MadNLP campaign. Trace-resolved
Jacobian geometry remains unavailable because MadNLP's public callback does
not expose primal iterate coordinates; the same-start geometry and physical
endpoint contracts remain available independently.

### Initialization covariance correction

The scaling study now treats initialization as part of the coordinate contract,
not as an uncontrolled solver detail. The intended invariant is exactly the
physical one: equal phase magnitudes and 120-degree separation on balanced
three-phase wye buses, zero explicit neutral, and transformer/split-phase
relationships owned by the component model. Only the rectangular model
magnitude changes with the bus voltage base.

An audit found that the standard BMOPFTools OPF start stage previously applied
the source magnitude to every non-grounded bus. Single-voltage-level cases were
unaffected, and per-unit transformer cases could conceal the error because
their transformed voltage levels were order one, but the SI wye-delta fixture
initialized the nominal 415 V side near 6.35 kV. BMOPFTools now uses its
level-aware nominal-voltage propagation and existing wye/delta phase-shift
override for the standard OPF path. Independent native starts across SI,
classic, and both local-base policies now agree in physical coordinates within
about `3.4e-13` on the retained transformer fixture.

The campaign qualification contract now requires native-initialization
covariance in addition to transported-common-start covariance. This prevents a
scaling policy from receiving a physically different engine warm start and
having the resulting solver-work change misattributed to numerical scaling.
Canonical phase-pattern checks remain a separate optional gate because delta,
split-phase, explicitly unbalanced, and source-declared angle patterns have
different physical semantics.

Rerunning the bounded transformer pilots with the corrected initialization
reduced work for every policy while preserving the broad scaling result. Ipopt
record ranges became 13--14 for moderate local bases, 14--15 for classic,
16--18 for aggressive high bases, and 19--21 for SI. MadNLP ranges became
13--14, 13--15, 15--18, and 19--22 respectively. Thus initialization was a
material confounder, but it does not explain away the disadvantage of SI or
aggressive scaling.

### Full cross-solver result after initialization correction

The complete matched matrices now contain 120 qualified solves per solver.
Their agreement is stronger than the earlier pilots: both Ipopt and MadNLP
place the moderate local policy at the lowest or tied-lowest callback work on
both retained cases, SI well above classic, and the aggressive policy between
classic and SI on the unbalanced line case but highly start-sensitive on the
wye-delta transformer. The corrected transformer record ranges are 13--14,
14--15, 16--26, and 19--21 for Ipopt and 13--14, 13--15, 15--26, and 19--22
for MadNLP, ordered as moderate/classic/aggressive/SI.

MadNLP's factorization counters sharpen the interpretation. The transformer
aggressive policy needed as many as 39 factorizations and 30 backsolves for 26
callback records, whereas the moderate policy stayed within 13--14
factorizations and exactly 14 backsolves. SI required more iterations than the
moderate policy but did not show the same excess-factorization pattern. Thus
at least two mechanisms are present: persistently poor coordinate geometry in
SI, and start-dependent linear-system interventions under aggressive scaling.

This is the first result that can reasonably guide the next algorithm-design
experiment, because mathematical problem, physical start, endpoint acceptance,
solver environment, and replicate structure are controlled. The next
intervention should be phase-only: apply orthogonal two-coordinate rotations to
declared complex semantic blocks while holding every magnitude base fixed.
Orthogonal rotations must preserve singular values in exact arithmetic, so
they form a strong falsification/control experiment for any claimed benefit of
complex scaling. Only after that control should magnitude-plus-phase policies
be compared on centre-tap, regulator, floating-neutral, delta-circulation, and
larger sparse feeder cases.

## Transformer transport is part of the scaling contract

The multi-voltage audit exposed a distinction that the initial scaling design
did not state strongly enough. Three contracts must be tested independently:

1. **coordinate consistency** — voltage and current bases on each winding make
   the transformed winding/KCL equations mathematically equivalent;
2. **residual scaling** — each voltage, ampere-turn, power-link, and nameplate
   row is presented to the solver at a useful magnitude; and
3. **initialization covariance** — the same physical phasor, including vector
   group, winding polarity, phase subset, and terminal permutation, is generated
   under every coordinate policy.

BMOPFTools now implements the third contract with one sparse complex transport
system in per-bus nominal-voltage coordinates. The system uses source/ground
anchors, galvanic conductor maps, single-phase winding pairs, anti-series
centre-tap windings, Yd/Dy relations, open-delta regulators, and general
WYE/DELTA n-winding coil incidence including `delta_roll`. This handles a
single-phase branch taken from (for example) phase B even when its downstream
terminal is named `1`; phase identity comes from the port map, not the label.
Yd/Dy current seeds are computed after the global voltage transport so a local
post-pass cannot overwrite the compositional solution.

The engine exposes equation counts and maximum normalized residuals by
relation family through `opf_initialization_data`. NLPDiagnostics carries that
evidence in its voltage-start report and can require it with
`require_phasor_transport=true` in native-start covariance comparisons. A new
SI-versus-classic chained Yd/Dy test passes the complete physical model,
function, residual, and Jacobian covariance gate; both transport solves have
maximum normalized residual near `1.6e-12`. This is evidence for the represented
connections, not for arbitrary transformer vector groups.

### Consequence for local power bases

A single global power base makes current continuity easy because
`I_B=S_B/V_B` changes only with the voltage base. Allowing genuinely local
power bases is more ambitious: a physical winding current represented on two
different local current bases requires explicit conversion coefficients in
ampere-turn and terminal-injection equations. Likewise, a power-link row and a
KCL row need not share the same desirable residual base. The next design should
therefore treat scaling as declared linear maps on semantic variable and
residual blocks, rather than pretending that one modified per-unit data copy is
sufficient.

The falsification sequence is:

1. retain the current physical-covariance and phasor-transport gates;
2. vary transformer-side power/current bases while stamping all conversion
   coefficients explicitly;
3. compare per-equation-family Jacobian geometry and physical KKT endpoints;
4. test centre-tap, open-delta regulator, n-winding delta, and phase-subset
   fixtures before large feeders; and
5. only then combine magnitude maps with complex/phase rotations.

Zigzag remains outside the present BMOPF representation. It cannot be made
trustworthy by another terminal-name heuristic: the schema needs an explicit
winding-to-terminal connection matrix, which must be shared by model stamping,
base propagation, initialization, and diagnostic expected-nullspace assembly.

### Implemented proposal contract

The first item in that falsification sequence is now executable.
`opf_transformer_scaling_contract_data` partitions the staged BMOPF network
into galvanically continuous zones, rejects within-zone power-base variation,
and derives `I_base=S_base/V_base` plus exact side-to-side conversion ratios for
every represented transformer interface. NLPDiagnostics wraps it with
`bmopf_transformer_scaling_contract_data`, summarizes conversion ranges by
physical quantity and subtype, and keeps algebraic `comparison_ready` separate
from `model_experiment_ready`.

On the chained Yd/Dy truth fixture, the proposed 10 MVA / 1 MVA / 100 kVA zone
bases are algebraically admissible and require explicit current and power
conversion at both transformer interfaces. The proposal was initially marked
not model-experiment-ready while the required connection coefficients were
absent. That negative readiness result served its purpose: it prevented
solver-work claims before the coordinate transformation existed.

### Executable isolated-transformer slices

`ZonePerUnitScaling` now executes the same idea across an isolated
single-phase transformer. It stores `S_base(bus)`, derives local current and
impedance bases, stamps the `S_from/S_to` factor into ampere-turn balance and
the reciprocal factor into cross-side leakage referral, and applies local
power conversion to devices, ratings, costs, losses, and result extraction.

The truth fixture uses 1 MVA on a 2.4 kV primary and 25 kVA on a 240 V
secondary—a 40:1 power-coordinate change. SI, classic per-unit, and zone-local
models agree on solved physical voltages, source/load powers, losses, and OPF
objective. NLPDiagnostics also passes the same-start physical point,
constraint-function, residual-set, Jacobian-support/rank, and physical-Jacobian
covariance gate. During this test the adapter's remaining system-power-base
assumption was exposed by a 0.975 relative derivative/set discrepancy and was
replaced with bus/winding-local semantic scales.

The second executable slice covers both Yd and Dy orientations. In normalized
connection coordinates, delta terminal currents require
`f_I=S_delta/S_wye`, while delta-arm leakage referred into the wye-current
voltage-drop equation requires the reciprocal `f_Z=S_wye/S_delta`. Wye-coil
nameplates and current initialization use `S_wye`. These are not optional
equilibration heuristics: together they are the coordinate representation of
the original power-conservative connection matrix.

Separate Yd and Dy endpoint fixtures with a 40:1 zone-base change agree with SI
on physical bus voltages, source power, and transformer real/reactive losses.
The chained 10 MVA / 1 MVA / 100 kVA fixture additionally passes native-start
physical point, constraint-function, residual-set, and physical-Jacobian
covariance. This is evidence of equivalence, not evidence of better
conditioning.

The third executable slice covers center-tap transformers. This case provides
an important distinction between physical reciprocity and coordinate symmetry.
The fixed 5×5 primitive is reciprocal in dimensional voltage/current units, but
after primary and secondary currents use different power bases its normalized
matrix is generally nonsymmetric. BMOPFTools constructs an intermediate
primary-power primitive, applies reciprocal impedance/admittance conversions,
and row-transforms the secondary currents. The explicit T model instead exposes
the same `S_primary/S_secondary` factor in ampere-turn balance.

Two unequal-leg fixtures exercise the nonzero-arm primitive and zero-primary-arm
T-model paths at a 40:1 power-base change. Both pass exact PF voltage, winding
current, source-power and loss equivalence, physical OPF objective equivalence,
and the complete native-start derivative/set covariance gate. The T-model gate
also covers all 16 real/imaginary current-box rows, which BMOPFTools publishes
under component constraint keys. Unregistered bounds remain a hard coverage
failure. This is the first multi-port result in the study and is a useful
template for n-winding matrix scaling.

The fourth executable slice generalizes that idea to an arbitrary winding-list
port model. With winding 1 as reference, physical ampere-turn balance becomes
`sum_k N_k (S_k/S_1) I_k = 0` in model coordinates. The same factor multiplies
each referred-current column of the full ZB leakage matrix, while ZB itself is
divided once by the winding-1 impedance base. This preserves the original
multi-port operator without inventing pairwise transformer copies or changing
its physical rank.

The executable oracle uses three independently based WYE ports, nonzero full
ZB coupling, a winding-2 magnetising branch, current and apparent-power limits,
and asymmetric phase loads across a 50:1 base range. SI and zone-local models
agree on PF/OPF endpoints, winding currents, bus voltages, losses, objective,
initialization, residual sets, and the physical Jacobian. Existing independent
WYE/DELTA incidence and `delta_roll` tests cover the connection maps; a loaded
floating-delta endpoint is intentionally not used as a numerical equality
oracle because its common-mode gauge is non-unique.

The sixth executable slice qualifies distinct AC and DC power coordinates for
native lossless converters. Converter `c` at AC bus `b` is stamped as
`U_dc,pu I_dc,pu = (S_ac(b)/S_dc) P_ac,pu`. Power-reference and droop-output
coordinates remain local to the converter's AC bus, while setpoint, deadband,
and droop voltage arguments use the DC voltage base. A two-converter fixture
with independent AC factors 50 and 5 passes SI/local physical point,
constraint-function, set, residual, and physical-Jacobian covariance for both
P/V and droop/V control pairs. This establishes coordinate covariance, not
better conditioning; lossy and custom converter builders remain unqualified.

The fifth executable slice closes the regulator boundary without pretending
that it is an isolating transformer boundary. A single-phase autotransformer
shares a common bushing and an open-delta bank has a straight-through phase.
Consequently both voltage and power bases must remain constant across the two
bus records; the tap is dimensionless and changes a winding equation, not the
coordinate system of the shared copper conductor. The public proposal audit
now rejects a voltage-base jump even when `V_base*I_base=S_base` holds
algebraically, because that identity alone does not preserve the bond-voltage
row.

Loaded fixed-tap single-phase and open-delta fixtures pass SI/normalized PF
endpoint covariance, including all winding and bond currents. Fixed and free
tap variants pass complete initialization, constraint-function, residual-set,
and physical-Jacobian covariance in NLPDiagnostics. Negative controls reject
both voltage-base and power-base jumps before construction. This is a useful
negative design result: galvanic devices should be treated as interiors of a
scaling zone, not as opportunities for more local bases.

### Matched AC/DC pilot

`benchmarks/bmopf_acdc_scaling_campaign.jl` turns the AC/DC covariance oracle
into a repeat- and start-stratified Ipopt experiment. The retained policies are
classic 1 MVA per unit, SI, a rating-aligned 10 kVA AC/DC allocation, and an
asymmetric allocation whose converter coefficients are 50 and 5. Both P/V and
droop/V controller cases are run from the native start and one 0.1% perturbed
physical start, with two fresh replicates per cell. Qualification requires the
AC/DC coefficient contract in addition to common-start transport, endpoint KKT
acceptance, endpoint covariance, intervention purity, telemetry semantics, and
repeatability.

The first bounded pilot qualified all 32 solves. Callback-record ranges across
both strata were 12--20 (classic), 10--24 (SI), 10--21 (rating-aligned), and
12--19 (asymmetric) for P/V control; the droop/V ranges were 6--14, 6--20,
6--19, and 6--18 respectively. Every endpoint was locally optimal and accepted
under the same physical tolerance contract.

The result rules out a simple initial-condition-number policy selector. At the
native P/V start, SI and rating-aligned coordinates used 10 records rather than
classic's 12 even though their dense local condition proxies were about
`1.0e5` and `3.8e3` times the classic proxy. At the perturbed P/V start, SI
instead needed 24 records versus classic's 20; the asymmetric policy needed 19.
For perturbed droop/V, classic needed 14 records, versus 18--20 for the three
alternatives. These are small-fixture observations, not a ranking. They make
controller mode and start perturbation mandatory strata for the next base-grid
and multi-case experiments.

### AC/DC power-base factorial

`benchmarks/bmopf_acdc_base_grid_campaign.jl` separates the two AC-zone power
bases and the DC power base in a full two-level `2^3` design. The retained
levels are 10 kVA / 1 MVA at AC zone 1, 10 kVA / 100 kVA at AC zone 2, and
10 kW / 200 kW on the DC network. The eight cells span converter coefficients
from 0.05 to 100 and are compared with classic 1 MVA coordinates. Factorial
contrasts are computed independently inside each P/V or droop/V and native or
0.1%-perturbed start stratum. Solver-count contrasts retain count units;
geometry contrasts use `log10` candidate-to-classic ratios. No contrast is
collapsed into a policy score.

The first grid run qualified all 72 fresh solves and every one of the 32
factorial cell/stratum combinations. Increasing the DC base reduced the initial
condition proxy by 1.29--1.65 decades in all four controller/start strata.
Increasing the AC-zone-2 base also reduced that proxy in all four strata, by
0.078--0.320 decades. These are robust local-geometry directions on this
fixture, not solver-performance conclusions.

Solver work did not inherit those stable directions. The AC-zone-1 main effect
on callback records ranged from +2 at the native P/V start to -1.75 at the
perturbed droop/V start; it was zero in the other two strata. Native droop/V
needed exactly six callback records and four line-search trials in every grid
cell despite condition ratios spanning more than two decades. The grid thus
provides direct evidence that coordinate geometry, controller equations, and
the current basin jointly determine solver work. It motivates trajectory- and
linear-algebra-level attribution rather than selecting bases from an initial
dense condition proxy.

### Three-zone multi-converter campaign

`benchmarks/bmopf_acdc_multiconverter_campaign.jl` is the first step beyond
the two-converter truth fixture. It couples three independently scaled AC
islands at 230 V, 400 V, and 690 V through three converters and a three-node
meshed resistive DC network. A full `2^4` design varies the three AC power bases
and the DC power base. P/V dispatch and two-converter droop sharing are retained
as separate controller cases; each is run from native and 0.1%-perturbed
physical starts with two fresh replicates. The fixture has 62 variables and
91--93 constraints. It remains an intermediate mechanism case, not a feeder-
scale benchmark.

All 136 fresh Ipopt solves qualified: physical endpoints, starts, AC/DC
coefficients, repeatability, all 16 factorial cells, and semantic-family trace
geometry passed. Native P/V used 9--10 callback records and native droop used
six. Perturbed droop remained tightly grouped at 19--20 records and 20--22
line-search trials. Perturbed P/V separated sharply: classic 1 MVA coordinates
used 52 records and 166 trials, while all 16 grid cells used 21--24 records and
20--27 trials.

The regularization evidence is more specific than the work counts. Each
classic perturbed-P/V replicate had 39 positive regularization records and a
maximum regularization of `2.13e5`. Five grid policies used regularization;
their maxima ranged from 1 to 711, while the other eleven used none. The most
mobile row families were DC branch power/current thermal rows and IBR power
circles; the most mobile column families were converter active/reactive power
and DC branch currents. These are local attribution clues, not proof that any
one family caused the regularization.

Ipopt's public callback does not expose factorization counts, backsolves,
inertia, fill, pivots, backward error, or linear-solver time. The artifact
records that capability as unavailable for every run and does not make it a
failed gate. Consequently this campaign qualifies trajectory geometry and
regularization attribution, but not joint geometry/factorization attribution.
A matched MadNLP companion can supply cumulative linear-algebra work counters,
while lacking primal iterate coordinates; cross-solver triangulation must keep
that evidence asymmetry explicit.

### Matched MadNLP linear-work companion

`benchmarks/bmopf_acdc_multiconverter_madnlp_campaign.jl` runs the identical
fixture, `2^4` cells, controller strata, physical starts, and replicates with
MadNLP. Its public callback contributes cumulative factorizations, backsolves,
linear-solver time, Jacobian/Hessian evaluations, and iterative-refinement
counts. It contributes no primal iterate coordinates. The artifact therefore
contains an explicit solver-evidence matrix: Ipopt owns trajectory geometry and
regularization; MadNLP owns cumulative linear work; neither run supplies their
same-run causal linkage.

The first 136-solve companion retained complete linear-work telemetry in every
run, but exposed two separate endpoint questions. All 68 P/V solves were
locally solved. Droop sharing produced 56 locally solved endpoints, six local
infeasibility reports, and six iteration limits. Mean per-policy
factorizations ranged from 9--76 for P/V and 7--201 for droop; mean per-policy
backsolves reached 1,947 in the native droop stratum. These figures are
numerical observations in one environment, not performance rankings.

The P/V endpoint discrepancy has since been reduced to fixed-variable dual
recovery. MadNLP's public multipliers pass primal feasibility and
complementarity but leave a stationarity residual of about `1.5` on fixed
source-voltage coordinates. Generic linear and nonlinear controls confirm that
the public MOI path can return consistent multipliers, while the BMOPF
decomposition shows that all free coordinates are already balanced.
NLPDiagnostics now offers an explicit alternative representative that
recomputes only scalar `VariableIndex`-in-`EqualTo` multipliers from
stationarity. The original public snapshot is retained, no other multiplier is
changed, and the operation makes no claim about multiplier uniqueness or
solver-internal scaling. On the retained fixture, 13 fixed-equality
multipliers are completed, reducing the maximum stationarity residual to about
`5.6e-8` while the public report remains failed and inspectable.

With this explicit representative, both native and perturbed P/V strata now
qualify: 68/68 locally solved runs have complete linear-work telemetry,
accepted completed-multiplier endpoints, complete `2^4` cells, and passing
factorial geometry gates. Raising the AC-zone-2 base has the clearest repeated
work direction. Its high level reduces mean factorization count by `2.25` at
the native start and `1.625` at the perturbed start; it also reduces mean
backsolves by `1.25` and `3.0`, and mean Jacobian/Hessian evaluations by `1.25`
and `2.5`. The time differences have the same sign but are too small and
environment-specific to carry the claim. This is qualified evidence for the
compact P/V mechanism fixture, not a universal base-selection rule.

Droop remains deliberately unqualified: the explicit completion can audit a
locally solved endpoint, but cannot convert local infeasibility or an iteration
limit into success. Effects pooled across droop cells with different
termination classes remain descriptive only. The next experiments must
therefore separate controller robustness from coordinate effects instead of
using the P/V result to explain the droop failures.

### Feeder-embedded mechanism campaign

`benchmarks/bmopf_acdc_feeder_policy_campaign.jl` implements the next scale-up
without misrepresenting the available data. The ENWL corpus cases are real
unbalanced AC feeders, but each is one galvanic zone and contains no DC grid or
isolating transformer. Applying the four-factor AC/DC policy directly to such a
case would collapse the independent bases and destroy the experiment. Instead,
the runner embeds an unmodified, namespaced ENWL feeder as AC zone 2 of the
qualified three-converter P/V mechanism. The zone-2 converter is attached at
the feeder source bus; the feeder's own voltage source, lines, loads, IBRs, and
controller profiles remain present.

Five policies preserve the needed controls: classic 1 MVA, the all-low
factorial anchor, AC-zone-2-high only, all-high, and the AC1/AC2/DC interaction
cell. The runner crosses native and deterministically perturbed physical starts,
fresh replicates, and Ipopt/MadNLP. It admits a case only after explicit bounds
on variables, rows, stored Jacobian entries, and the upper bound on
trace-Jacobian entry evaluations pass. `max_dense_entries=0` is propagated
through initialization covariance, common-start covariance, endpoint
covariance, and geometry comparisons, so dense rank and singular spectra cannot
be enabled accidentally.

The first complete LN execution also exposed two instrumentation problems that
would have obscured the experiment. Intervention verification attempted to
materialize whole-model coordinate relations even though the declared maps are
block sparse: the hypothetical dense relation required 1,427,161 entries,
while the actual relation stores 1,681. Classification now operates on the
sparse relation and uses the dense budget only for optional determinant-sign
evidence. The same execution produced a 651 MB checkpoint because complete
per-run evaluations were serialized after they had served the qualification
gates. Feeder artifacts are now compact by construction, retain only evidence
summaries and provenance, and checkpoint atomically after every stratum. The
equivalent compact checkpoint is 279 KB.

The construction smoke exposed a previously missing semantic contract before
solving: registered `ibr_p_volt_watt` rows had no physical residual scale.
Their equation is a power inequality on both sides, so the correct residual
scale is the IBR bus power base, matching `ibr_q_volt_var`. That contract is now
implemented and independently tested. On the first 30-bus LN construction, all
756 variables and 925 rows map, including 28 Volt-Watt rows; the transported
start has zero round-trip error.

The corrected 30-bus LN campaign is now fully qualified for Ipopt and MadNLP,
at both the native and seed-11 perturbed physical starts, with two fresh runs
per policy. All physical endpoints, transformation comparisons, repeats,
solver-specific attribution, and cross-solver start fingerprints pass. The
result rejects a simple monotone reading of the compact-fixture AC-zone-2
effect. Relative to the all-low anchor, AC-zone-2-high-only reduces Ipopt
callback records by 5 and line-search trials by 6 at the native start. MadNLP
also uses 4 fewer callback records, 7 fewer backsolves, and 4 fewer
Jacobian/Hessian evaluations, with unchanged factorization count. At the
perturbed start the direction reverses strongly: Ipopt uses 58 more records,
243 more line-search trials, and 24 positive-regularization records; MadNLP uses
64 more records, 108 more factorizations, 205 more backsolves, and 64 more
Jacobian/Hessian evaluations. Every endpoint still passes.

This is evidence of a scaling--initialization interaction, not evidence that
the high or low base is universally better. The immediate scientific question
is therefore how each policy transforms the perturbation relative to active
controller, power-circle, and DC thermal geometry. The two-point Ipopt trace
already localizes the largest changing row families to DC branch thermal and
IBR power-circle constraints, with `q_ibr`, `p_ibr`, and DC branch-current
columns prominent. More intermediate trace points and additional physical
perturbation directions are needed before assigning causality. LG remains the
next held-out topology/control case; 99-bus promotion remains premature.
