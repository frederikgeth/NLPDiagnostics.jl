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
7. Run magnitude-only fixed-policy experiments.
8. Run phase-only singular-invariance and block-coupling experiments.
9. Run combined and matched solver experiments only after those gates pass.
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
