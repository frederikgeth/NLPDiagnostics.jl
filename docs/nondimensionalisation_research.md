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
conversion at both transformer interfaces. The proposal is correctly marked
not model-experiment-ready because BMOPFTools has not yet stamped those local
base coefficients. This negative readiness result is a feature: it prevents
solver-work claims before the coordinate transformation exists.
