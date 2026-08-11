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
| Block-linear covariance for real representations of complex scalings | Design target | Exact variable, residual, set, derivative, multiplier, Hessian, and KKT transformation tests with negative controls |
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

1. Introduce a generic semantic block-linear scaling map, with diagonal scaling
   as its one-dimensional special case.
2. Add set-transform contracts and covariance for multipliers, stationarity,
   complementarity, Hessians, and KKT systems.
3. Extend BMOPFTools metadata with paired residual blocks and local physical
   ratings without inferring semantics from JuMP names.
4. Build small line, transformer, delta/wye, neutral, and converter truth cases.
5. Run magnitude-only fixed-policy experiments.
6. Run phase-only singular-invariance and block-coupling experiments.
7. Run combined and matched solver experiments only after those gates pass.
8. Treat QC/RQC/TRQC experiments as a separate approximation-strength study.

## Current publication boundary

The most credible prospective contribution is currently the evidence framework:
semantic block scaling with exact physical/KKT covariance, paired with experiments
that distinguish physical nondimensionalisation, algebraic equilibration,
algorithm-aware complex rotation, and relaxation changes.

No claim is yet made that local bases improve solver performance, that one policy
dominates classic per-unit, or that complex rotations improve exact NLP
conditioning. Those remain experimental questions.
