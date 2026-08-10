# Mission and scope

NLPDiagnostics.jl is an evidence-first debugger and experimental measurement
platform for nonlinear optimization models expressed through JuMP and
MathOptInterface.

Its mission is to help model and solver developers determine whether an
observed difficulty is mathematical, structural, numerical, physical, or
representational, and to expose the evidence needed to test that explanation.
The package is not a solver, a model-health scoring system, or an automatic
model repair tool.

## Primary outcomes

NLPDiagnostics should help a user answer four progressively stronger questions:

1. **What was observed?** Bounds, expression domains, sparsity, derivative
   values, local rank evidence, solver events, and domain-plugin declarations.
2. **What might explain it?** A clearly labelled hypothesis whose evidence
   basis and confidence are visible.
3. **What evidence is missing?** An unavailable result is part of the report;
   it must not be silently replaced by an invented point, derivative, scale, or
   physical interpretation.
4. **What controlled intervention would test the hypothesis?** Examples include
   adding a reference, changing coordinates, supplying a justified start,
   rescaling one declared equation family, or changing one solver mechanism.

The fourth question is essential for numerical-method research. Correlation
between a finding and a failed solve is descriptive evidence. A repeatable,
mechanism-specific intervention that changes the predicted solver behaviour is
substantially stronger evidence.

## Evidence contract

Every diagnostic conclusion must preserve:

- the observation and why it matters;
- mathematical, structural, physical, numerical, local, or heuristic basis;
- confidence and issue domain;
- affected model entities;
- the evaluation point and derivative provenance for local evidence;
- numerical policy, scaling, tolerance, and work guards where applicable; and
- an explicit unavailable reason when the required evidence was not obtained.

Physical declarations and observed numerical modes are independent evidence
channels. Solver telemetry and recomputed model quantities are also independent
channels. Agreement may support a hypothesis; disagreement must remain visible.

## Current scope

The current research prototype includes:

- read-only static, expression, and structural analysis through public MOI APIs;
- explicit-point objective, constraint, derivative, scaling, rank, active-set,
  degeneracy, and reduced-curvature measurements;
- non-mutating auxiliary feasibility and relaxation plans;
- optional solver trace and postmortem adapters; and
- optional PowerModels and BMOPFTools physical metadata and expected-mode
  research extensions.

MOI remains the canonical model boundary. Domain semantics belong in optional
plugins, preferably declared by the authoritative domain package rather than
inferred from names. BMOPF and multiconductor analysis are calibration domains,
not reasons to weaken the generic evidence model.

## Present non-goals

Until the calibration release gate is met, NLPDiagnostics will not:

- assign a single model-health or solver-readiness score;
- claim global rank, infeasibility, observability, or physical causation from a
  single local numerical snapshot;
- treat an unconverged iterative vector as a nullspace certificate;
- treat synthetic-zero or incomplete initialization as a representative
  operating point;
- silently modify the source model; or
- recommend automatic reformulation without a reversible mapping and explicit
  proof obligations.

## Definition of done for a new finding family

A new finding family is complete only when it has:

1. a documented evidence basis and confidence ceiling;
2. at least one truth-labelled positive calibration case;
3. at least one negative control;
4. threshold and scaling sensitivity checks where numerical policy is involved;
5. an explicit unavailable path and bounded-work policy;
6. behavioral tests of the detector, not only script or text-contract tests; and
7. machine-readable expected and forbidden outcomes for calibration reporting.

New fingerprints without this evidence should remain in an experimental
namespace or a research notebook, rather than expand the stable finding catalog.

## Project phase

The project is in a **consolidate and calibrate** phase. Feature breadth is
already sufficient to exercise the original vision. The near-term priorities
are solver-event telemetry, numerical-kernel validation, trusted operating
points, truth-labelled physical cases, typed schemas, API consolidation, and
extension-specific continuous integration.

The first externally meaningful milestone is a calibration report containing
false-positive, false-negative, unavailable, tolerance-sensitive, runtime, and
memory results. Automatic presolve or reformulation work follows that milestone,
not precedes it.
