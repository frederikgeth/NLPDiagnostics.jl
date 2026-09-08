# Scientific review and recovery plan

Reviewed 5 September 2026, at commit `00d38626284cd9713b9a7416b46c139e6dca3e65`.

**Recommendation: continue the project, narrow its product scope, and make the next milestone trustworthy diagnosis of a small set of OPF failures. Suspend feature expansion until the correctness defects below are fixed.** The useful foundation is the MOI ingestion boundary, explicit operating points, physical entity mapping, and evidence-preserving comparisons. The present implementation cannot yet sustain all of its proof, provenance, and resource-guard contracts.

This is a targeted scientific and implementation review, not an exhaustive verification of every numerical kernel or a certification of the physical models. I inspected the core ingestion, interval/static analyses, numerical identity and caching, rank and curvature paths, component mapping, selected extensions, tests, CI, and scientific release artifacts. I checked relevant claims against primary documentation. Saved power-system campaigns were inspected, not rerun. No package implementation or existing release threshold was changed.

## What was verified

The local full-extension regression command completed with exit code zero and **5,383 passing assertions across 42 printed test summaries**:

```sh
julia --startup-file=no --compiled-modules=no --project=work/benchmark-environment test/runtests.jl
```

Julia 1.12.6 and the existing local benchmark environment were used. This is not verification of every CI platform or supported dependency version. Fifteen warning records were emitted; several concern intentional physical fixtures. The complete output is retained in [regression-output.txt](/Users/uqfgeth/Documents/GitHub/NLPDiagnostics.jl/reviews/2026-09-05/regression-output.txt).

The independent, bounded [reproduction script](/Users/uqfgeth/Documents/GitHub/NLPDiagnostics.jl/reviews/2026-09-05/reproduce.jl) completed six probe groups with 19 assertions. **Those assertions confirm existing bugs; they are not evidence of correct behavior.** Its [output](/Users/uqfgeth/Documents/GitHub/NLPDiagnostics.jl/reviews/2026-09-05/reproduction-output.txt) records the counterexamples. Run it with:

```sh
julia --startup-file=no --compiled-modules=no --project=. reviews/2026-09-05/reproduce.jl
```

Compiled modules were disabled because the sandbox did not permit writes to the user's Julia precompile cache. No dependency installation or manifest update was needed.

## Correctness fixes, in priority order

All P1 items below should block promotion of the affected feature as reliable. They do not imply every existing result is wrong. P2 items follow once the trust boundary is repaired.

### 1. P1: floating-point observations become false mathematical proofs

**Reproduced.** Fix `x = y = 1` and impose `1 + 10^16*x - 10^16*y = 1`. This model is feasible; all constants and its solution are exactly representable. Fixed-expression evaluation accumulates the constant first, loses it through floating-point cancellation, and returns zero. `analyze` emits `infeasible_fixed_affine_constraint` with `MathematicalProof` and `ConfidenceCertain`.

The same contract problem affects interval arithmetic. Adding `[10^16,10^16]` and `[1,1]` returns `[10^16,10^16]`, which excludes the exact result `10000000000000001`. An interval that does not enclose the real result cannot support rigorous domain exclusion or safe bound tightening.

Locations: [fixed affine evaluation](/Users/uqfgeth/Documents/GitHub/NLPDiagnostics.jl/src/analysis/static.jl:351), [fixed-expression classification](/Users/uqfgeth/Documents/GitHub/NLPDiagnostics.jl/src/analysis/static.jl:611), [interval addition](/Users/uqfgeth/Documents/GitHub/NLPDiagnostics.jl/src/analysis/domains.jl:694), and [affine propagation](/Users/uqfgeth/Documents/GitHub/NLPDiagnostics.jl/src/analysis/static.jl:2930).

**Fix:** immediately restrict proof labels to certified paths. For affine/quadratic data, exact rational arithmetic on the represented coefficients is a possible bounded oracle. For nonlinear enclosures, use validated outward-rounded operations, or report a numerical/heuristic observation with an explicit uncertainty boundary. Higher precision alone is not a general enclosure certificate. Audit coefficient combination, proportional-row normalization, fixed substitution, inverse-function propagation, and completing-the-square logic as one proof-producing surface. Ordinary comparisons of already stored bounds can remain proofs when their premises are satisfied.

Validated interval libraries explicitly aim to enclose the real result; using such a library is preferable to maintaining a broad bespoke arithmetic implementation. [IntervalArithmetic.jl documentation](https://github.com/JuliaIntervals/IntervalArithmetic.jl)

**Acceptance:** the supplied feasible model never receives an infeasibility proof; certified interval tests contain exact rational reference results; cancellation, underflow, overflow, boundary domains, and coefficient permutations have both positive and negative controls. Preserve a warning about numerical cancellation: the model can be mathematically feasible and numerically difficult at the same time.

### 2. P1: physical component diagnostics can select the wrong equation

**Reproduced.** A variable bound and an affine equality can both have raw constraint index 1. `_entity_row_key` drops function and set types. `analyze_component_ranks` stores rows in a dictionary using this incomplete key, overwriting one row with another. In the probe, a component whose actual scoped derivative is `[1]` is reported to have rank zero.

Locations: [incomplete key](/Users/uqfgeth/Documents/GitHub/NLPDiagnostics.jl/src/analysis/degeneracy.jl:1), [component row lookup](/Users/uqfgeth/Documents/GitHub/NLPDiagnostics.jl/src/NLPDiagnostics.jl:4982), and [persistence lookup](/Users/uqfgeth/Documents/GitHub/NLPDiagnostics.jl/src/NLPDiagnostics.jl:5139). The same key also appears in component scale attribution. The structural/numerical comparison already has a more careful full-reference lookup with an unambiguous fallback; reuse that principle throughout.

MOI explicitly allows equal integer indices across different function/set types. This is an ordinary supported model shape, not an exotic malformed input. [MOI constraint identity](https://jump.dev/JuMP.jl/stable/moi/reference/constraints/#MathOptInterface.ConstraintIndex)

**Fix:** centralize type-qualified row identity, including vector subrow and model identity where needed. Reject ambiguous legacy references instead of choosing a row. Apply it to component ranks, persistence, residual/scaling attribution, and every related dictionary join.

**Acceptance:** mixed affine, quadratic, nonlinear, vector, and variable-bound constraints with colliding integer indices retain correct attribution. Missing or ambiguous mappings yield unavailable results. Renaming a constraint must not change its mathematical identity.

### 3. P1: the evaluation cache loses point provenance

**Reproduced.** Two points with identical coordinates and labels but different provenance are unequal according to `EvaluationPoint`. Nevertheless, the cache treats them as identical. Evaluating a `UserPoint` first and a `SyntheticSmokePoint` second returns the original `UserPoint` evaluation. The returned evidence no longer describes the requested point provenance.

Location: [cache key](/Users/uqfgeth/Documents/GitHub/NLPDiagnostics.jl/src/numerics/evaluator.jl:827).

This undermines a central safeguard: physical interpretations are supposed to be qualified by the provenance of the point. It also allows results to depend on cache call order.

**Fix:** include complete diagnostic point identity in the key, or cache only raw numerical arrays and wrap them in the current point's provenance on every return. Include numeric type explicitly and test it. Keep the documented requirement to invalidate caches after mutations until a stronger model-version mechanism exists.

**Acceptance:** user, solver, synthetic, and completed-initialization points preserve their own provenance in every call order; cache reuse does not change interpretation eligibility.

### 4. P1: stale evaluations are silently attached to a changed model

**Reproduced.** Evaluate `x = 0` at `x = 1`, replace the coefficient with `10^6`, then call `analyze(model; evaluation=old)`. The old residual is 1; the current residual is `10^6`. The call succeeds and stamps the report with the **current** model fingerprint.

Locations: [evaluation fields and validation](/Users/uqfgeth/Documents/GitHub/NLPDiagnostics.jl/src/numerics/types.jl:2024), [current-model fingerprint assignment](/Users/uqfgeth/Documents/GitHub/NLPDiagnostics.jl/src/analysis/numerical.jl:5968). Variable order is insufficient: the functions, sets, parameters, or objective may have changed while every variable index stays the same. Two different models can also reuse the same variable indices.

**Fix:** bind each evaluation to the captured model description/version and ordered row identities. Analysis of a captured evaluation should use that captured description or reject a mismatch with the current model. Carry the same identity through Hessians, duals, maps, and saved artifacts. Caller-supplied experimental evaluations without a verifiable source must remain explicitly unverified.

**Acceptance:** coefficient, bound, objective, parameter, callback, and row changes are rejected or reported as stale; old values are never relabelled as new-model measurements. This is separate from the documented manual `empty!(cache)` contract: the reproduction supplies an old evaluation directly and uses no shared cache.

### 5. P1 for provenance-dependent comparisons: nonlinear fingerprints omit relevant content

**Reproduced.** Changing an `NLPBlock` constraint interval from `[0,1]` to `[2,3]` leaves `model_fingerprint` unchanged. The snapshot preserves the evaluator's type as an opaque-source string, but does not incorporate those bounds in the fingerprint.

Locations: [snapshot ingestion](/Users/uqfgeth/Documents/GitHub/NLPDiagnostics.jl/src/ir/model_snapshot.jl:41), [fingerprint construction](/Users/uqfgeth/Documents/GitHub/NLPDiagnostics.jl/src/numerics/fingerprints.jl:15).

**Fix:** digest all public nonlinear block bounds, dimensions, objective flags, and available model content. For opaque evaluator code or mutable captured data, require an explicit producer version/content identifier for persistent comparison, or mark fingerprint coverage incomplete. Hashing a type name cannot identify the function computed by its instances. Treat this as a companion to fix 4; merely adding the current fingerprint to evaluations will not solve it.

**Acceptance:** changes to exposed nonlinear content change the digest; unverifiable callbacks cannot masquerade as fully fingerprinted scientific evidence.

### 6. P1: dense-work admission does not account for the requested factorization

**Reproduced.** For a `1 × 1200` Jacobian, `max_dense_entries=1200` and `compute_vectors=false` admit a computation allocating **11,887,664 bytes after warmup**. The code calls `svd(...; full=true)` regardless of the vector flag. A full right factor scales with the square of the column count, even though the input is a single row.

Location: [dense rank implementation](/Users/uqfgeth/Documents/GitHub/NLPDiagnostics.jl/src/numerics/degeneracy.jl:2848). Related code-review concern: [reduced Hessian admission](/Users/uqfgeth/Documents/GitHub/NLPDiagnostics.jl/src/numerics/hessian.jl:453) counts selected rows but subsequently materializes the full Jacobian. Empty-row identity-basis branches also need output-size guards.

The reported bytes are cumulative allocations, not a measured peak. The counterexample and source establish an admission-accounting defect; large rectangular cases can amplify it severely. Full versus reduced singular-vector storage is part of the underlying factorization contract. [LAPACK DGESDD](https://netlib.org/lapack/explore-html/df/d22/group__gesdd_ga8941e5ff50de36580dae8940015e9cb0.html)

**Fix:** use singular values only when vectors are unnecessary, compute only the requested sides otherwise, and admit work based on input, factors, outputs, and workspace. Extract selected sparse rows before densifying. A byte-oriented budget is clearer than one input-entry count.

**Acceptance:** tall, wide, empty, and selected-row cases exercise admission before allocation; disabling vectors actually avoids full vector factors. This matters before pursuing allocator telemetry on ever larger OPFs.

### 7. P2: rank error-rate uncertainty is not supported by the current aggregation

**Confirmed by code and saved artifact inspection; no new statistical campaign was run.** The rank-statistics script pools 49 hard controls from different corpora, uses that common denominator for false-positive and false-negative upper bounds, and takes the corresponding error counts only from the seeded corpus. Its saved artifact gives the same 5.93% bound for each rate.

Location: [statistical aggregation](/Users/uqfgeth/Documents/GitHub/NLPDiagnostics.jl/benchmarks/summarize_rank_calibration_statistics.jl:165).

Define the positive class first. A false-positive rate needs the truth-negative denominator; a false-negative rate needs the truth-positive denominator. Repeated policies on related matrices and deliberately selected adversarial cases do not automatically constitute independent draws from a deployment population. The binomial formula itself is valid under an appropriate sampling model; its use here does not establish those assumptions. [NIST binomial confidence intervals](https://itl.nist.gov/div898/handbook/prc/section2/prc241.htm)

**Fix:** publish deterministic corpus counts as coverage evidence. Aggregate per-record truth, predictions, and availability with explicit class denominators. Only report inferential intervals for a specified held-out sampling design, accounting for grouping by network/matrix family. Keep threshold-sensitive policy disagreement separate from detector error. Some calibration paths derive expected rank using the same SVD family being checked; identify them as consistency checks and supplement them with independently constructed algebraic truths.

**Acceptance:** a mixed positive/negative fixture yields the correct denominators; injected failures in every corpus affect the aggregate; unavailable cases remain visible; duplicated records do not silently strengthen statistical claims.

## Scientific assessment

**Several foundations are worth preserving.** The mission distinguishes observations, comparisons, interpretations, and interventions. The project explicitly rejects global conclusions from one local Jacobian, retains negative results, checks coordinate/set contracts, separates public from completed fixed-variable dual representatives, and has optional-extension CI lanes. Those are substantive strengths. The reproduced defects show where the implementation falls short of those principles.

**The current evidence demonstrates technical capability more strongly than practical diagnostic value.** The release ledger candidly remains unready. Its saved 99-bus experiment has six paired snapshots but only two strict paired KKT passes. Its 49 hard rank controls have no recorded mismatches, while 26 threshold-sensitive controls include nine backend disagreements. These are bounded findings; neither increasing the number of summary artifacts nor repeatedly solving the same fixture establishes that a user finds and fixes a defect faster.

**The two purposes should have separate deliverables.** A user-facing debugger needs reliable, actionable explanations. A numerical-method research platform needs explicit hypotheses and controlled experiments. A scaling experiment may be scientifically valuable even when it yields no product feature. Conversely, a useful missing-reference detector needs no new singular-value algorithm to justify its existence.

**Do not use rank as a proxy for everything difficult about an NLP.** Structural matching concerns a sparsity pattern. Numerical rank concerns a specified matrix, point, coordinates, and threshold. Constraint qualifications concern appropriate active gradients and tangent/cone geometry. Solver difficulty can arise from curvature, barrier terms, linear-system factorization, globalization, derivative errors, or infeasibility. A rank-deficient full constraint Jacobian is not by itself an explanation of a failed OPF. A positive reduced Hessian on an equality-nullspace restriction is not automatically an inequality-constrained optimality certificate.

**Preserve the existing rejection of phase-only improvement in the full Jacobian's Euclidean condition number.** For orthogonal changes `J_new = Q_r J Q_x`, singular values are unchanged. A solver can still respond to componentwise stopping rules, internal scaling, pivoting, sparsity, or approximate preconditioners. Study those mechanisms only with the relevant instrumentation and a predeclared prediction. The project already states this correctly in its research ledger.

**The 99-bus tolerance boundary is not the first recovery task.** Moving a gate from `10^-5` to `1.2×10^-5` because the saved points then pass would be post hoc calibration. First repair identity and attribution; then define application tolerances by residual family and units, separately define objective-normalized stationarity tolerances, and validate on new endpoints. Retain both old and revised results. A tolerance decision must express application accuracy, not an owner's preference for a green release report.

**Solver termination cannot locate a physical feasibility boundary by itself.** The combined-case 0.27/0.28 load bracket is evidence of solver outcomes under particular starts and budgets. Ipopt's local infeasibility status may indicate a local minimum of its violation problem rather than global infeasibility. Two local solvers agreeing on failure still provide no global certificate. The repository mostly acknowledges this; use “observed convergence bracket” consistently. [Ipopt termination semantics](https://coin-or.github.io/Ipopt/OUTPUT.html)

The series-transformer capacity screen is a more promising practical direction: under its explicitly constructed radial fixed-load assumptions, it identifies a rating bottleneck before another start/iteration sweep. Its formula is currently duplicated in a benchmark script. Promote it only after deriving it from authoritative network data and stating when losses, shunts, reactive compensation, controllable generation, and meshed transfers invalidate the simple screen.

## Features to retain, abandon, or defer

| Decision | Scope | Reason and condition |
| --- | --- | --- |
| Retain and harden | Bound consistency, explicit-point evaluation, feasibility residuals, finite/domain failures, structural incidence, derivative crosschecks | These answer common debugging questions and can have small independent oracles. |
| Retain and simplify | Physical component/row mapping, units and scale contracts, solver-result provenance | These are the strongest potential advantage over generic residual listings, once identity is reliable. |
| Retain as advanced tools | Bounded dense SVD, vetted sparse QR, active-gradient checks, scalar KKT residuals | Useful supporting measurements; expose matrix scope and limitations. Keep explicit abstention. |
| Abandon as a core product commitment | Maintaining multiple bespoke iterative smallest-singular/nullspace algorithms and a normal-equations “third oracle” | This creates a numerical-linear-algebra research programme. Archive experiments; use maintained backends where needed. Reopen only for a documented diagnostic case existing tools cannot handle. |
| Abandon as a release prerequisite | Broad complex-rotation, AC/DC, multiconverter, and relaxation experiments | A useful OPF debugger should not wait for every scaling research hypothesis. Retain independent research artifacts. |
| Abandon continued expansion | The catalogue of bespoke inverse-trigonometric, reciprocal-hyperbolic, endpoint, and stable-expression fingerprints | Each adds proof and maintenance obligations. Keep demonstrated high-value checks; move obscure patterns to opt-in research scope until actual user cases justify them. |
| Defer | Generic elastic minimum-support searches, order ensembles, and automated repair recommendations | Auxiliary local NLPs can be difficult and nonunique. Start with one explicit feasibility relaxation and clearly limited interpretation. |
| Defer | Physical meaning inferred from individual nullspace basis columns | A multidimensional nullspace has many equally valid bases. Use declared physical directions, projector/subspace tests, and intervention evidence. |
| Stop treating as progress milestones | Repeated ownership ledgers, source-token audits, and summaries of summaries | They can preserve contracts, but do not establish correctness or application value. Consolidate recurring analyses into parameterized runners. |

This is a recommendation about future support and investment, not an instruction to erase scientific history or immediately break users. Inventory actual external dependents before deprecation; a pre-release package need not make 539 historical root exports permanent commitments. A smaller facade that aliases the same unrestricted implementation does not itself create a smaller correctness boundary.

## How to demonstrate real-world usefulness in power systems

Choose the first user narrowly: **a JuMP-based OPF developer debugging a model that fails, stalls, or returns suspicious results.** The report should identify the relevant bus, branch, terminal, equation, and operating point; explain what was measured; and suggest one falsifiable next investigation.

Use three concrete workflows:

| Workflow | Initial defect families | Successful outcome |
| --- | --- | --- |
| Model construction/preflight | Missing island reference, incorrect terminal mapping, contradictory limits, duplicated equation, disconnected variable | Correct entity localization; a reviewed correction restores the intended model; clean controls avoid false alarms. |
| Evaluation/initialization | Invalid voltage start, wrong derivative, per-unit conversion mistake, cancellation or scale mismatch | The offending expression or physical row family is identified; an independent recomputation validates the correction. |
| Failed or suspicious solve | Violated physical limits, poorly matched starts, rating shortage, stalled restoration | Quantified physical residuals and a testable hypothesis; an explicit unavailable/inconclusive result when evidence cannot distinguish causes. |

For each incident, store the original data/model, intended equations, defect, correct repair, independent expected outcome, and raw diagnostic output. A diagnostic can correctly identify a defect even if the repaired problem still needs solver work. Conversely, a successful rerun is insufficient if the intervention changes the intended physics.

Build an initial corpus from distinct sources: selected version-pinned PGLib balanced AC-OPF cases; a few explicit-neutral/unbalanced distribution cases; and at least three naturally occurring failure incidents supplied by two users who did not implement the detectors. PGLib defines a specific AC-OPF formulation and provides reference implementations and baseline results. Match formulations before comparing. Use PowerModelsDistribution or a separately implemented physical residual checker only where device and neutral semantics align. [PGLib-OPF](https://github.com/power-grid-lib/pglib-opf), [PowerModelsDistribution paper](https://arxiv.org/abs/2004.10081)

Inject defects one at a time into known-good models, then add clean controls and realistic interacting defects. Hold out whole networks and incident families; adjacent time snapshots and alternative scalings of the same equations must not leak across the development/test split. Fix thresholds and expected outputs before inspecting the held-out results. Separate proof-producing detectors, numerical screens, and explanatory hypotheses in scoring.

Measure **correct localization among the first three reported issues, false actionable warnings per clean case, explicit abstention/coverage, time to a verified repair, and diagnostic runtime/memory**. For diagnosis efficacy, compare a workflow using solver logs plus JuMP's existing feasibility report with the same workflow augmented by NLPDiagnostics. Use matched cases and counterbalanced user order where possible. JuMP already reports pointwise constraint violations; NLPDiagnostics must add useful localization, interpretation, or experimental guidance. [JuMP feasibility report](https://jump.dev/JuMP.jl/stable/api/JuMP/#JuMP.primal_feasibility_report)

As provisional pilot gates, target zero false proof claims in the complete adversarial suite, correct top-three localization on at least 80% of held-out single-defect cases in the declared supported families, and no high-confidence physical-cause claims on inconclusive controls. Publish the numerator and denominator, abstentions, and all failures. These are proposed product gates, not estimated current accuracy or statistical guarantees. Expand only after three external incidents produce useful, independently verified diagnoses with acceptable overhead.

If scaling research continues, use a separate preregistered protocol: identical physical starts, validated inverse maps and sets, matched physical endpoint tolerances, solver-internal scaling controlled, fixed solver/linear solver versions, repeated timings, and held-out networks. Compare standard per-unit, existing solver scaling, and simple equilibration baselines before complex policies. Report failures and quality-adjusted cost, not speed on successful subsets only. Promote a policy only when it helps a specified workload without silently loosening accuracy.

## Recovery plan

The sequence below is more important than the indicative timing. A stage advances when its acceptance conditions pass.

| Stage | Work | Reviewable deliverable / exit condition |
| --- | --- | --- |
| First 1–2 weeks | Freeze new finding families; fix proof escalation, row identity, provenance, stale evaluations/fingerprints, and dense admission in small patches | Each supplied counterexample becomes a regression asserting correct behavior; existing extension tests remain green; affected historical results are marked for revalidation. |
| Next 1–2 weeks | Define the supported diagnostic contract; separate rapid preflight from expensive analysis; centralize shared interval/snapshot computation; correct statistical summaries | One short scope document and one end-to-end OPF example; no hidden expensive numerical probes; explicit resource/availability reporting. |
| Following 2–4 weeks | Build the defect corpus and independent physical checks; run the held-out pilot against ordinary debugging workflows | Versioned incident records, known repairs, localization/error/coverage tables, and external user evidence. No additional backend is required for this milestone. |
| After the pilot | Release the narrow supported workflow, or reduce scope further; reconsider only the deferred features demanded by failed supported cases | A release claim tied to demonstrated tasks and a short supported-capability table. Research campaigns receive separate milestones. |

Performance work should address an identified path: `_propagate_scalar_affine_intervals!` can run up to the variable count and rescans rows/terms; domain state is recomputed in multiple analyses. The existing saved affine-chain profile already reports about 0.885 seconds at dimension 100 versus 13.522 seconds at 400. Treat these as historical local measurements, not current portable timings. Build one shared analysis context, use a work queue or explicit visit budget, and preserve incomplete-propagation status. Optimize after the interval semantics are corrected.

CI should keep separate minimal, solver, and domain lanes. Pin a reviewed domain dependency revision for reproducible regression, with a separate allowed-to-fail or explicitly triaged upstream-compatibility lane. Add behavioral identity/proof/guard tests and executable documentation examples. Keep schema tests, but separate them from scientific validation: `test/runtests.jl` currently contains 695 `occursin` calls and 90 `Meta.parseall` calls. Those counts do not mean the remaining tests are weak; they show that a large test total mixes distinct types of evidence.

## Communication changes

The current tree contains 53,805 source lines, 11,339 extension lines, 51,243 benchmark-script lines across 207 scripts, and a 6,610-line roadmap. This is a maintenance warning for a pre-release debugger, not a defect proven by line count. The public narrative needs to become much smaller than that implementation history.

Replace the README's feature inventory with the target user, three questions the tool answers, one complete working OPF example, the supported model boundary, and how to read a finding. Its current reuse snippet references an undefined `evaluation`; make every advertised snippet executable. Replace the active roadmap with one page of ordered outcomes and move the chronology to an archive.

A finding should lead with the physical or mathematical entity, measured quantity and units, threshold/reference, evidence strength, and next investigation. Detailed provenance belongs in expandable/serialized evidence. “No issues found” must expose which checks actually ran and what was unavailable. Keep numerical severity distinct from urgency: a harmless gauge can be mathematically interesting but need no corrective action.

Rename `analyze_convexity` to communicate its actual local curvature scope. Use “numerical rank under policy …”, “observed convergence bracket”, and “local residual acceptance” wherever those are the supported conclusions. Avoid calling matching, generic Jacobian rank, or local KKT acceptance an observability, feasibility, or global-optimality certificate.

There is precedent for a guided diagnostic product: IDAES presents structural checks, numerical checks at a point, and advanced tools as stages in a workflow. The opportunity here is a trustworthy Julia/MOI implementation with particularly useful power-system attribution. General-purpose diagnostics alone should not be presented as established scientific novelty. [IDAES diagnostic workflow](https://idaes-pse.readthedocs.io/en/latest/explanations/model_diagnostics/index.html)

**The next success should be a documented user defect found correctly, explained clearly, and repaired without changing the intended problem.** A smaller, reliable tool can support strong scientific research; continuing to add research machinery while these trust defects remain will make both goals harder.
