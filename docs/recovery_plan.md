# Correctness recovery plan

## Current implementation boundary — 21 September 2026

The [version 2 power workflow](power_diagnostics_v2.md) now consolidates independent
source/model checks, explicit selected-revision validation, and the unchanged
island/returned-point verification path. Nullable stage schemas preserve invalid
contract reasons. New self-contained regression and CLI tests use checked-in
inputs; the original frozen implementations and failed evaluations are retained.

The full-extension environment now pins Julia 1.12.6, BMOPFTools commit
`b5e050dff579c9a0c3e69c1e1ad11d0b748f2482`, PowerIO 0.11.1, and the resolved
dependency graph. CI has a separate power-workflow lane. The environment preflight
checks package loadability and dependency source identity. Rank summary schema v3
uses per-record, class-specific backend accounting and withdraws the unsupported
pooled confidence bounds. The bounded numerical-rank policy is now accepted with
current defaults retained; threshold-sensitive backend disagreements remain visible,
and the decision authorizes no algebraic-rank or physical-cause claim.

Next application work requires separately prepared source-backed incidents and a
new frozen evaluation. The human study remains prepared, not run. Structural and
opaque-callback proof scope, equipment provenance, and measured repair benefit
remain separate obligations. The chronology below records historical states;
earlier “next” items are not a second active priority queue.

Incident-evaluation preparation now includes a standard-library Python
[intake validator and freeze verifier](../studies/power_diagnostic_pilot/intake/README.md).
It requires source/model/log evidence, permission and independent-preparation
declarations, resolution support, a separate scoring key, and an evaluation plan.
It checks hashes, baseline completeness and byte-identical private-answer leakage;
the freeze binds declared materials and the v2 workflow/environment selection.
Twelve artificial contract tests pass, with CI coverage in the workflow lane.
No incident collection has been frozen and no evaluation has been run. Acquiring
independently prepared records remains the next external dependency; the checker
does not authenticate their declarations or replace scientific review.

Validation: the pinned full-extension suite passed **7,601 assertions across
90 printed testsets** on Julia 1.12.6. The power-workflow lane passed **303
assertions** from a separate source snapshot with no `work/` directory, including
the existing encoded-capacity/tolerance/point-verification contracts and new
report/CLI regressions. The focused rank-accounting tests passed **36 assertions**
(also included in the full suite). Package-load/source preflight, local quality,
proof-inventory scope, whitespace checks, and all five freeze inventories passed.
The development bootstrap's joint dependency resolution also repaired a copy of
the formerly incompatible manifest. A focused child-process check confirmed use
of the active environment instead of the ignored local benchmark directory.

Local final suites used `--startup-file=no --compiled-modules=existing`; the
workflow was additionally checked with compiled modules disabled before adding
the unchanged mathematical contract suites. GitHub Actions is configured but
was not run remotely. These are regression results on exposed development
fixtures, not new held-out or engineer-efficacy results. Logs:
`/tmp/nlpdiag-full-implementation-tests-final.log`,
`/tmp/nlpdiag-clean-workflow-tests-final.log`, and
`/tmp/nlpdiag-implementation-quality.json`.

This is the active implementation sequence following the [5 September scientific
review](../reviews/2026-09-05/report.md).
The older roadmap remains a historical implementation and experiment ledger.
New finding families and numerical backends are deferred while this sequence
is completed.

## First implementation batch: scientific contracts

Implemented changes, with behavioral regressions in
[scientific_contracts.jl](../test/scientific_contracts.jl):

- Finite, fully fixed affine and quadratic expressions are evaluated using exact
  rational arithmetic on their represented coefficients. Repeated coefficients
  in the shared support canonicalizer no longer lose dependencies through
  floating-point cancellation. Quadratic diagonal terms retain MOI's factor of
  one half.
- Fixed nonlinear numerical evaluations use numerical evidence labels, including
  `fixed_expression_numerically_satisfied` and
  `fixed_expression_numerical_violation`. Numerical domain exceptions at fixed
  values no longer claim real-domain infeasibility proofs.
- Component rank, persistence, and scalar/coupled scale attribution use
  function/set-qualified equation identity. Display names do not affect row
  identity. Legacy references are accepted only when the available row scope
  resolves them uniquely; ambiguous references yield unavailable evidence.
- Cache keys distinguish numeric type and the point's complete provenance.
- Captured numerical evaluations bind to the originating model object and its
  public description. Model-aware analysis rejects a changed description or a
  different model. Historical manual constructors remain available, with their
  model binding explicitly unverified in numerical reports.
- Public model fingerprint version 2 includes objective sense and NLPBlock
  bounds, row count, and objective flag. It does not certify opaque callback code
  or mutable captured callback state.
- Rank-only dense analysis computes singular values without full singular-vector
  factors. Dense rank admission includes requested factors and identity outputs.
  Reduced-Hessian analysis extracts selected sparse rows before densifying and
  avoids a full left factor for tall active Jacobians.

This batch does **not** close the entire proof or reproducibility audit. In
particular, general nonlinear interval propagation still uses arithmetic that
has not been certified to enclose every real result. Other static proof-producing
paths also remain under review. Existing `MathematicalProof` labels outside the
certified fixed-polynomial path must not be taken as a blanket validation of the
library's arithmetic. The original review reproducer records historical bugs;
the current regression suite asserts the corrected contracts.

## Second implementation batch: exact interval and affine arithmetic

The interval kernel now preserves exact represented endpoint values for
addition, scaling, multiplication, reciprocal, and integer powers within its
explicit work limit. It retains rational results when Float64 would round them,
handles infinite limits without `0 * Inf` contamination, and widens unsupported
inputs to the full real line. Quadratic diagonal coefficients are divided by
two exactly before interval scaling, including subnormal coefficients.

Domain-state affine propagation, single-variable affine isolation, and the
one-pass/fixed-point report paths share exact coefficient combination and bound
isolation. Nonfinite coefficients cause abstention instead of disappearing from
the row. Cached and uncached propagation use the same arithmetic contract.

The new
[arithmetic regressions](../test/certified_interval_arithmetic.jl)
cover the review's non-enclosure counterexample, exact rational reference
results, finite overflow and underflow, integer boundaries, coefficient order,
feasible cancellation, genuine inconsistency, and numerical domain errors in
mathematically valid expressions.

This certifies the arithmetic operations **given enclosing input intervals**;
it does not certify the entire nonlinear propagation graph. The third batch
below prevents uncertified inputs from silently passing through this boundary.

## Third implementation batch: propagate certificates and preserve uncertainty

- `IntervalEnclosure.certified` is explicit. Legacy constructors produce
  estimates; extensions must opt in only after validating their enclosures.
- Arithmetic propagates certification. Domain/derivative consumers widen
  uncertified intermediate ranges and retain possible/unknown findings, including
  at explicit points. Uncertainty does not become a proof or disappear because
  the sampled coordinates are known.
- Proof-producing analyses use declared bounds and certified propagation.
  General geometric and inverse-function estimates remain visible in
  `domain_interval_data` but are excluded from that path. Exact algebraic
  inverses and reference identities retain useful certified implications.
- Initialization retains certified bound violations while reporting rounded
  quadratic-geometry exclusions as numerical observations under explicitly
  numerical finding codes.
- Numerical risk fingerprints retain approximate range information with
  numerical/heuristic evidence. This preserves useful warnings without giving
  those estimates mathematical authority.

Tests now distinguish approximate range accuracy from admissibility as proof
evidence. This intentionally increases possible/unknown results for nonlinear
chains until validated range rules restore coverage. It does not yet complete
the separate audit of direct static geometric, constant-expression, or
proportional-row proof producers.

## Fourth implementation batch: exact static row comparison and constant evidence

- Polynomial duplicate/reused-expression fingerprints combine finite represented
  coefficients exactly. Unsupported inputs retain their original syntax.
- Affine equality and half-space normalization uses exact rational coefficient
  sums, ratios, and right-hand-side differences. Nonfinite inputs cause
  abstention. The shared comparison layer protects proportionality, dominance,
  parallel equality contradictions, and opposing half-space contradictions.
- Variable-free nonlinear evaluations no longer assert exact values or prove
  infeasibility from numerical values or exceptions. Exact represented
  polynomial constants and direct syntactic zero identities retain proofs.
- Zero-product folding rejects nonfinite constants, so `0 * Inf` and `0 * NaN`
  cannot erase variable dependencies or manufacture a certified zero.
- Regression tests include a feasible pair of nonparallel equations whose
  Float64-normalized coefficients coincide, extreme normalized bounds,
  coefficient permutations, signed scaling, nonfinite inputs, genuine
  contradictions, and rounding-induced constant evaluation failures.

## Fifth implementation batch: certified static quadratic geometry

- Completed-square centers, minimum levels, and squared axes now use exact
  rational arithmetic for finite represented MOI diagonal quadratics and
  recognized nonlinear polynomial trees. MOI's diagonal factor of one half is
  preserved; repeated polynomial coefficients are combined exactly.
- Static coordinate-bound findings use outward square-root enclosures built
  from integer square roots. Declared-bound conflicts use exact squared-distance
  comparisons, including when the displayed enclosure is slightly wider.
- Nonfinite or unsupported geometry inputs cause abstention. Numerical radius
  estimates remain separate from proof evidence and avoid premature Float64
  overflow or underflow before taking the square root.
- Geometry evidence preserves each numeric value's type before serialization;
  mixed floating bounds cannot promote exact rational centers to rounded
  BigFloat values.
- Regressions cover feasible positive levels rounded to zero by the former
  code, coefficient permutations, overflow, subnormal scales, independently
  checked square-completion identities, enclosing endpoints, and genuine
  negative/zero-level controls.

Domain and initialization geometry integration remains separate: those paths
retain numerical enclosures and their existing conservative certification
policy. This batch does not validate every static proof family.

One adversarial regression is
`x^2 + y^2 + 2e8*x + 2*y + 1e16 == 0`. Its exact completed form is
`(x + 1e8)^2 + (y + 1)^2 == 1`. The former Float64 calculation lost the unit
level and falsely fixed both coordinates to the center. The point
`x = -1e8, y = 0` is an exact feasible witness, including with the bound `y >= 0`.
This is an arithmetic regression, not a measured real-world repair result.

## Sixth implementation batch: geometry integration and provenance

- Certified quadratic coordinate enclosures now participate in domain
  propagation. Exact positive lower bounds can discharge domain warnings;
  zero-level geometry can establish genuine domain violations.
- Affine propagation retains upstream origin categories and type-qualified
  source-row identities alongside its own row provenance. The retained origins
  describe contributing premises, not necessarily a minimal explanation.
- Initialization geometry uses exact squared-distance exclusions, with source
  row, center, squared-axis, and enclosure evidence. The finding codes are now
  `initialization_diagonal_quadratic_bound_violation` and
  `initialization_diagonal_quadratic_equality_bound_violation`. They prove only
  that the supplied start violates a necessary coordinate restriction.
- Regression tests cover propagation through affine rows, declared-bound
  intersections, uncertainty preservation, zero levels, irrational radii,
  boundary points, and the earlier feasible cancellation witness.

## Seventh implementation batch: objective-ray proof premises

- Both objective-ray families require a finite polynomial, minimization or
  maximization sense, and a constraint description without opaque sources.
  Nonfinite constants, affine terms, or quadratic terms cause abstention.
- Variable domains are checked explicitly. Unsupported scalar sets and
  semicontinuous/semiinteger domains no longer masquerade as unrestricted
  variables. Malformed and contradictory scalar bounds block affected variables;
  correctly oriented infinite endpoints behave like absent bounds.
- Integer variables retain conditional unboundedness conclusions via integer
  sequences. Evidence identifies the domain path and feasibility scope.
- Quadratic coefficient evidence preserves the exact MOI half factor, including
  subnormal coefficients. Tests include finite-data and opaque-source controls,
  bounded disjunctive domains, unknown scalar sets, genuine improving sequences, and nonfinite
  cross terms.

### Eighth correctness batch: irrational references and range boundaries

- Rounded π, π/2, and log(2) no longer trigger exact coordinate or
  inverse-function fixing proofs. Exact zero and degree-angle identities remain.
- Radian inverse-trigonometric and atan2 output checks use closed rational
  outer enclosures justified by π < 22/7. This intentionally loses exclusions
  close to the true endpoints; narrower claims require validated enclosures.
- Positive square equalities preserve irrational roots symbolically and report
  certified rational root bounds. Numeric fixed values appear only for exact
  rational roots. Nonfinite positive levels do not produce root implications.
- Evidence calls output bounds enclosures, and square-branch explanations allow
  other constraints to remove a branch. Consumers of the affected range evidence
  must use `range_enclosure` instead of `operator_range`; irrational square roots
  have `selected_root` and root bounds instead of a numeric `implied_value`.

### Ninth correctness batch: branch and self-division premises

- Min/max, direct self-division, and absolute-value sign identities now inspect
  every supported scalar-bound declaration before using the intersection.
  NaN, unsupported endpoint types, incorrectly oriented infinities, and
  contradictory bound intersections cause these identity rules to abstain.
- Min/max requires a finite, exactly represented branch constant. The guard
  applies to nested expressions, objective roots, and constraint roots.
- Identity-based row satisfaction uses exact represented values and validated
  scalar sets; NaN targets no longer become infeasibility proofs through a
  false comparison. Properly oriented infinite row endpoints remain supported.
- Additional unknown or discrete restrictions do not invalidate an independent
  valid scalar-bound implication. These rules prove identities on that bound
  domain, not existence of a feasible point or permission to discard the bounds.
- Explanations retain possible nonsmooth derivative conventions at min/max ties
  and make the bound premises of self-division contradictions explicit.

### Tenth correctness batch: finite inventory and range premises

The [proof inventory](proof_audit_inventory.md) enumerates 44 producer functions
with 84 explicit proof-label references. It assigns retain/fix/demote decisions
and records open work; the scope check is
`python3 benchmarks/audit_proof_inventory.py`. These are scoped audit decisions,
not a claim that every retained function has been exhaustively certified.

Direct sign, exponential, square/root, reciprocal-trigonometric/hyperbolic,
and general unary/atan2 range paths now reject malformed scalar sets before
claiming exclusions. Endpoint-bound conflict rules use validated declared bounds;
independent endpoint implications remain available where their exact identity
holds. New tests distinguish malformed inputs from genuine contradictions.

The [power-system pilot protocol](power_system_repair_pilot.md) fixes the first
development variants, independent truth/repair checks, baseline workflow,
metric denominators, and transfer requirements. This is a protocol, not a
completed repair corpus or effectiveness result.

### Eleventh correctness batch: numerical activity evidence

The four activity/gradient producers marked for demotion in the finite inventory
now report computed residuals, cone-boundary classifications, normals, and
nonzero mapped gradients as `NumericalObservation`. A computed zero gradient
retains `LocalInference`, with explicit cancellation/underflow qualifications.
Symbolic derivative construction does not upgrade its finite-precision evaluation
to a mathematical certificate. Existing finding codes are unchanged.

The [inventory](proof_audit_inventory.md) preserves these four producers as
zero-reference demotion records. Its check fails if a proof label reappears.
There are now 40 active producers with 80 explicit proof references: 23 retain
rows with scoped coverage and 17 open fix/audit rows. This closes the four
planned demotions, not the remaining mathematical audits.

New regressions include an exactly feasible cancellation example whose computed
residual violates the row, genuine numerical violations, cone boundary/apex
activity, symbolic and finite-difference gradients, unavailable derivative rows,
zero-gradient local inference, and renderer-neutral evidence serialization.

### Twelfth correctness batch: scalar and discrete bound inputs

Scalar bound diagnostics and structural variable roles inspect every declaration
before trusting the effective intersection. NaN inputs retain their diagnostic;
infinite equality values, incorrectly oriented infinities, and unsupported
endpoint types produce `invalid_variable_bound` with structural evidence.
They do not produce fixed-variable, bound-dominance, or discrete-infeasibility
proofs. Properly oriented infinite sides remain valid unbounded domains.

Finite contradictory bounds still prove infeasibility. Integer interval checks
use exact represented rationals and BigInt ceiling/floor, with large positive
and negative witness controls. Mixed numeric evidence preserves exact rational
endpoints. The two inventory rows now have scoped regression coverage, leaving
15 fix/audit rows open, 25 retain rows, and four completed demotions.

### Thirteenth correctness batch: grouped range and endpoint audit

All 11 remaining range/endpoint producers have scoped coverage in
`test/range_semantic_contracts.jl`, supported by the earlier premise and
irrational-reference regressions. [Analytic justifications](range_semantic_audit.md)
state operator definitions, attainable witnesses, necessary exclusions, unique
preimages, and the conservative interpretation of atan2's zero-axis condition.
The test tables are specified independently of the implementation lookup tables.

Positive-square sign selection now rejects malformed domain premises while
preserving the equation's independent two-branch implication. Endpoint and
axis evidence uses type-preserving containers so mixed bounds cannot round
exact rational values. The finite inventory now has 36 retain rows with scoped
coverage, four completed demotions, and four open fix/audit rows: reused
expressions, initialization bounds, stable reformulations, and elastic domain
guard plan reporting. These are not claims of floating-point evaluation accuracy.

### Fourteenth correctness batch: final inventoried producers

Reused-expression proofs now use typed structural keys for supported finite
polynomials/nonlinear trees and validate every row set. Display/repr fallbacks
are not equality certificates. Exact rational intersection evidence preserves
its type. This assumes deterministic mathematical expression semantics;
arbitrary callback behavior is not certified.

Initialization bound proofs require finite represented point coordinates;
NaN/infinite starts get `initialization_nonfinite_value` numerical evidence.
Stable-reformulation and elastic-guard plan reports are heuristic: public plan
records alone do not certify equivalence or revalidate source-model premises.
Existing finding codes are preserved. In particular, the historical
`elastic_proven_domain_guard_violation` code records the plan's claimed
assessment; its report basis is heuristic and evidence explicitly says
`assessment_revalidated=false`.

The finite inventory now has 38 retain rows with scoped tests, six completed
demotions, and zero open rows. This is closure of the explicit-label audit scope,
not a library-wide correctness theorem or completion of the recovery initiative.

## Next: reproducibility and application validation

1. Maintain the pinned pilot environment and extend source identity through
   derived evaluations, Hessians, physical maps, and persistent artifacts.
   Define an explicit producer-version contract for opaque callbacks;
   public-description matching alone cannot verify them.
2. Validate the conditional capacity preflight and conservative backend matcher
   beyond exposed case14. Bound rounding effects in actual physical equations
   before claiming unconditional backend infeasibility.
   Extend load lineage to updates/rebasing and
   equipment units, and test further networks and incident families.
   The pilot's exact-bound severity mismatch has been addressed;
   broader unit-aware actionability still requires evaluation.
   Freeze changes before held-out evaluation and measure human repair benefit.
   Scripted inverse patches and solver success do not establish repair usefulness.
3. Maintain the finite proof inventory and its regression contracts. Expand the
   audit for changed producers, structural claims, and callback semantics; do
   not infer certification from a label or a scope-check script.
4. Restore additional certified nonlinear range coverage only where pilot cases
   justify it. Use validated outward rounding or exact rules. Preserve numerical
   evaluation errors alongside mathematical evidence when they disagree.

Release decisions require both reproducible evidence and measured application
outcomes. Zero open rows in the current lexical inventory is not that exit gate.

## Then: consolidate the supported workflow

- Correct statistical aggregation using per-record truth and class-specific
  denominators. Separate deterministic coverage from statistical inference.
- Share model snapshots and domain state within one analysis. Bound propagation
  by work performed, expose incomplete propagation, and measure overhead after
  arithmetic semantics are correct.
- Keep inexpensive preflight, explicit-point numerical checks, and expensive
  research probes distinct in the supported interface and documentation.
- Retain historical research artifacts, but stop treating additional iterative
  backends, complex-scaling campaigns, or API ownership summaries as release
  prerequisites for the debugger.

## Application gate: power-system defects and verified repairs

Build a small corpus covering model construction, evaluation/initialization, and
failed or suspicious solves. Include clean controls, version-pinned balanced
and unbalanced networks, and external incidents. Hold out whole networks and
incident families. Preserve the intended physical problem when assessing a
repair.

Report correct localization among the first three issues, false actionable
warnings, abstentions, time to verified repair, and diagnostic overhead against
ordinary solver logs plus JuMP feasibility reporting. A successful solve or
another summary artifact is not sufficient to pass this gate.

## Validation commands

```sh
julia --startup-file=no --compiled-modules=no --project=. test/scientific_contracts.jl
julia --startup-file=no --compiled-modules=no --project=. test/certified_interval_arithmetic.jl
julia --startup-file=no --compiled-modules=no --project=. test/interval_certification.jl
julia --startup-file=no --compiled-modules=no --project=. test/exact_static_rows.jl
julia --startup-file=no --compiled-modules=no --project=. test/certified_quadratic_geometry.jl
julia --startup-file=no --compiled-modules=no --project=. test/certified_geometry_integration.jl
julia --startup-file=no --compiled-modules=no --project=. test/objective_ray_contracts.jl
julia --startup-file=no --compiled-modules=no --project=. test/algebraic_range_contracts.jl
julia --startup-file=no --compiled-modules=no --project=. test/branch_identity_contracts.jl
julia --startup-file=no --compiled-modules=no --project=. test/range_premise_contracts.jl
julia --startup-file=no --compiled-modules=no --project=. test/activity_evidence_contracts.jl
julia --startup-file=no --compiled-modules=no --project=. test/bound_input_contracts.jl
julia --startup-file=no --compiled-modules=no --project=. test/range_semantic_contracts.jl
julia --startup-file=no --compiled-modules=no --project=. test/final_producer_contracts.jl
python3 benchmarks/audit_proof_inventory.py
julia --startup-file=no --project=. -e 'using Pkg; Pkg.test()'
git diff --check
```

The full optional solver/domain suite can also be run with
`--project=work/benchmark-environment test/runtests.jl`, provided that environment
matches the versions required by its local path dependencies. The repository's
test target does not include every optional adapter.

The existing local quality and consolidation checks remain supplementary
contract checks; they do not certify scientific correctness.

### Validation of this batch — 8 September 2026

The complete optional solver/domain suite passed: **5,462 assertions across
48 top-level testsets**, including 78 new scientific-contract assertions.
This includes Ipopt, MadNLP, PowerModels, and the BMOPFTools scaling and staged
OPF adapters. The local quality check and API/test/benchmark consolidation audit
also passed, as did `git diff --check`.

The run used Julia 1.12.6 with `--startup-file=no --compiled-modules=no` and a
temporary copy of the benchmark environment. Its current BMOPFTools checkout
(`72e6cec2`) requires PowerIO 0.11, while the checked-in benchmark manifest
references PowerIO 0.7.3. The temporary environment selected the already
installed PowerIO 0.11.0; repository dependency files and sibling checkouts
were unchanged. The final full-run log is `/tmp/nlpdiag-refactor-final.log`.

### Validation of the second batch — 8 September 2026

The same complete optional solver/domain suite passed **6,091 assertions across
51 top-level testsets**, including all **629 new arithmetic assertions**.
Five additional mixed-infinite/BigFloat checks also passed. The local quality
check and `git diff --check` passed. The dependency setup is the same temporary
compatible environment described above; dependency files remain unchanged.
The full-run log is `/tmp/nlpdiag-interval-full.log`.

The coefficient-permutation regressions deliberately construct the original
snapshot data: `MOI.Utilities.Model` was observed to round duplicate terms on
insertion, before this package can inspect them. Separate end-to-end tests use
models whose represented coefficients survive insertion. This distinguishes an
upstream information-loss boundary from the arithmetic repaired here.

### Validation of the third batch — 8 September 2026

The complete optional solver/domain suite passed **6,174 assertions across
54 top-level testsets**, including **60 new interval-certification assertions**.
The focused core suite passed all 1,825 assertions. The local quality check and
`git diff --check` also passed. The run used the same temporary compatible
environment described above; repository dependency files remain unchanged.
The full-run log is `/tmp/nlpdiag-cert-full-final.log`, and the quality summary
is `/tmp/nlpdiag-cert-quality.json`.

These checks establish the tested certificate-propagation contracts, not global
scientific correctness. Direct static proof producers for constants,
proportionality, and geometric identities remain the next audit target.

### Validation of the fourth batch — 8 September 2026

The complete optional solver/domain suite passed **6,263 assertions across
58 top-level testsets**, including **89 new static-row and constant-evaluation
assertions** and all 1,825 core assertions. The local quality check and
`git diff --check` passed. The temporary compatible environment is unchanged;
repository dependency files and sibling checkouts were not modified.

The final full-run log is `/tmp/nlpdiag-static-verified.log`; the quality summary
is `/tmp/nlpdiag-static-quality-final.json`. Four existing evidence-format
expectations were updated from decimal strings to exact rational strings.
The tests preserve genuine redundancy and contradiction controls while
rejecting rounding-induced proof claims. Direct quadratic-geometry proof
producers remain unaudited; passing this suite does not close that gap.

### Validation of the fifth batch — 8 September 2026

The complete optional solver/domain suite passed **6,401 assertions across
62 top-level testsets**, including **138 new quadratic-geometry assertions**
and all 1,825 core assertions. The local quality check and `git diff --check`
also passed. The temporary compatible environment is unchanged; repository
dependency files and sibling checkouts were not modified.

The final full-run log is `/tmp/nlpdiag-geometry-verified.log`; the quality
summary is `/tmp/nlpdiag-geometry-quality-final.json`. Existing evidence tests
now expect exact rational centers and levels. The serialization regression
also verifies that mixed numeric evidence does not round the exact center
`1//3` or minimum `-1//3`. Remaining proof-family audits and integration into
domain/initialization propagation are listed above.

### Validation of the sixth batch — 8 September 2026

The complete optional solver/domain suite passed **6,468 assertions across
65 top-level testsets**, including **69 new integration assertions** and all
1,823 core assertions. Two obsolete, vacuously true assertions about possible
issues were removed when their preceding checks were changed to require domain
safety. The local quality check and `git diff --check` passed.

The compatible temporary environment is unchanged; repository dependency files
and sibling checkouts were not modified. The full-run log is
`/tmp/nlpdiag-integration-full.log`; the quality summary is
`/tmp/nlpdiag-integration-quality.json`. Remaining objective-ray and algebraic
proof audits are still required before claiming library-wide certification.

### Validation of the seventh batch — 8 September 2026

The complete optional solver/domain suite passed **6,546 assertions across
68 top-level testsets**, including **78 new objective-ray assertions** and all
1,823 core assertions. The local quality check and `git diff --check` passed.
The same compatible temporary environment was used; repository dependency
files and sibling checkouts remain unchanged.

The full-run log is `/tmp/nlpdiag-rays-full.log`; the quality summary is
`/tmp/nlpdiag-rays-quality.json`. Remaining algebraic identity and output-range
proof families still need their own audits; this does not establish global
scientific correctness or completeness of unboundedness detection.

### Validation of the eighth batch — 8 September 2026

The complete optional solver/domain suite passed **6,579 assertions across
71 top-level testsets**, including **47 new reference/range/root assertions**
and all 1,809 core assertions. Fourteen old assertions treating rounded
transcendental reference values as exact identities were replaced by explicit
abstention regressions; exact reference and genuine contradiction controls remain.
The local quality check and `git diff --check` passed.

The same compatible temporary environment was used. The full-run log is
`/tmp/nlpdiag-range-full.log`; the quality summary is
`/tmp/nlpdiag-range-quality.json`. Remaining direct algebraic proof producers,
including min/max branch premises and self-division, still need audits.
This batch does not certify all nonlinear primitives or establish real-world
power-system effectiveness; the application calibration gates remain required.

### Validation of the ninth batch — 8 September 2026

The complete optional solver/domain suite passed **6,661 assertions across
73 top-level testsets**, including **82 new branch-identity assertions** and
all 1,809 core assertions. The local quality check and `git diff --check`
passed. No existing assertion expectations were removed in this batch.

The same compatible temporary environment was used, with no repository
dependency changes. The full-run log is `/tmp/nlpdiag-branch-full.log`; the
quality summary is `/tmp/nlpdiag-branch-quality.json`. The next audit target is
remaining direct range and endpoint rules: in particular, the `sign(x)` range
rule still uses unchecked scalar-set comparisons. This validation covers the
branch/self-division contract, not all proof producers or application usefulness.

### Validation of the tenth batch — 11 September 2026

The complete optional solver/domain suite passed **6,735 assertions across
75 top-level testsets**, including **74 new range/endpoint-premise assertions**
and all 1,809 core assertions. No existing assertion expectations were removed.
The local quality check, proof-inventory scope check, and `git diff --check`
passed. The temporary compatible environment and repository dependencies are
unchanged. Logs: `/tmp/nlpdiag-inventory-full.log` and
`/tmp/nlpdiag-inventory-quality.json`.

The inventory records 23 retain decisions with scoped test coverage, 17 open
fix/audit decisions, and 4 open demotion decisions. Numerical activity findings
are the next priority. The pilot protocol is written, but its executable corpus,
repair measurements, and held-out application evaluation remain outstanding.

### Validation of the eleventh batch — 11 September 2026

The complete optional solver/domain suite passed **6,771 assertions across
77 top-level testsets**, including **36 new numerical-activity evidence assertions**
and all 1,809 core assertions. One existing gradient-basis expectation was
updated from MathematicalProof to NumericalObservation. The local quality check,
proof-inventory scope check, four simulated proof-label reintroduction controls,
and `git diff --check` passed. The compatible temporary environment is unchanged.

Logs: `/tmp/nlpdiag-activity-full.log` and `/tmp/nlpdiag-activity-quality.json`.
The four planned demotions are complete; 17 fix/audit rows remain open. Next are
scalar/discrete bound validation, including infinite fixed-value claims and
NaN-driven discrete-domain conclusions. The power-system pilot remains a protocol
awaiting an executable corpus and measured repair outcomes.

### Validation of the twelfth batch — 11 September 2026

The complete optional solver/domain suite passed **6,863 assertions across
79 top-level testsets**, including **92 new scalar/discrete-bound assertions**
and all 1,809 core assertions. No existing assertion expectations were removed.
The local quality check, proof-inventory scope check, and `git diff --check`
passed. The compatible temporary environment is unchanged.

Logs: `/tmp/nlpdiag-bounds-full.log` and `/tmp/nlpdiag-bounds-quality.json`.
The inventory now has 25 retain rows with scoped coverage, 15 open fix/audit
rows, and four completed demotions. Remaining work covers range/endpoint
semantics, reused expressions, and plan/report producers; the power-system
repair pilot still requires implementation and measured outcomes.

### Validation of the thirteenth batch — 11 September 2026

The complete optional solver/domain suite passed **7,432 assertions across
82 top-level testsets**, including **569 new range/endpoint semantic assertions**
and all 1,809 core assertions. No existing assertion expectations were removed.
The local quality check, proof-inventory scope check, and `git diff --check`
passed. The compatible temporary environment is unchanged.

Logs: `/tmp/nlpdiag-semantics-full.log` and `/tmp/nlpdiag-semantics-quality.json`.
The inventory has 36 retain rows with scoped coverage, four completed demotions,
and four open producer audits. Reproducibility and application validation remain
separate work; this batch does not establish power-system repair effectiveness.

### Validation of the fourteenth batch — 11 September 2026

The complete optional solver/domain suite passed **7,477 assertions across
85 top-level testsets**, including **45 new final-producer assertions** and all
1,809 core assertions. No existing assertion expectations were removed.
The local quality check, proof-inventory scope check, all six simulated
proof-label reintroduction controls, and `git diff --check` passed.
The compatible temporary environment is unchanged.

Logs: `/tmp/nlpdiag-finalproducers-full.log` and
`/tmp/nlpdiag-finalproducers-quality.json`. All 44 inventoried functions now have
a disposition: 38 retain rows with scoped tests and six completed demotions.
There are zero open rows in this explicit-label inventory. Reproducibility,
structural/callback scope, and measured power-system repair usefulness remain
separate obligations; this is not a library-wide correctness certificate.

### Executable power-system repair pilot — 11 September 2026

Added a dedicated environment pinned to Julia 1.12.6 and exact direct dependency
versions, an unchanged licensed PowerModels case3 fixture with a checked SHA-256,
and five clean/defective variants. The runner saves original/modified/repaired
data and starts, patches, raw findings, unavailable-stage reasons, solver logs,
JuMP feasibility, independent AC/DC physical residuals, and source/package identity.
The independent checker uses complex-voltage equations and refuses unsupported
storage/switch models. See [development results](power_system_repair_pilot_results.md)
for scope, scoring rules, and limitations.

Measured development outcomes: top-three explicit localization **1/4**, direct
localization anywhere **2/4**, no empty error lists **0/5**, and no unavailable
analyses **0/5**. The clean model has one exact-bound error finding from numerical
excursions below the physical feasibility tolerance: a practical severity mismatch,
not a disproved mathematical inequality. The wrong-unit variant solves its altered
model but fails intended-network balance by **1.089 p.u.** All **4/4 scripted inverse
patches** restore inputs and pass independent physical checks; no autonomous or
human repair result is claimed.

Validation: 17 analytic physical-check assertions and 44 serialization/integration
assertions (including a complete pilot rerun), local quality, proof-inventory
scope, and whitespace checks. The core library was unchanged in this batch;
the previous full-suite baseline remains 7,477 assertions, not a new full-suite
run. The analytic physical tests are also included in the normal test entry point.
Logs: `/tmp/nlpdiag-pilot-physics.log`, `/tmp/nlpdiag-pilot-contracts.log`, and
`/tmp/nlpdiag-pilot-quality.json`. Generated replay evidence is in
`work/power-repair-pilot/` and is ignored by Git.

Next priorities are tolerance-aware actionability, causal ranking, and unit/reference
provenance. Broader held-out networks, real incident records, human repair benefit,
and callback/derived-evaluation provenance remain unfinished.

### Tolerance-aware initialization bound severity — 11 September 2026

Exact initialization interval violations retain their mathematical proof basis
and existing finding code. Excursions at or below the declared absolute
`feasibility_tolerance` now have informational severity; larger excursions remain
errors. Exact represented-number comparisons avoid rounding across that threshold.
Mixed cases produce separate affected-variable groups. Evidence and metadata expose
the tolerance. Nonfinite starts and separate expression-domain errors remain errors;
a tolerance does not certify mathematical feasibility or domain safety.

The unchanged five-variant pilot now has **0/1 clean error cases**, retaining the
clean point's exact bound evidence as informational. Top-three localization remains
**1/4** and independently verified scripted repairs **4/4**. Empty error lists are
**2/5** (clean plus omitted reference); unavailable analyses remain **0/5**. The
missing-reference detection gap and poor bad-start ranking remain unresolved.
See the follow-up table in [pilot results](power_system_repair_pilot_results.md).

The full regression run exposed three stale fixed inventory-count assertions
following the pilot addition. These now check actual benchmark paths, helper
coverage, and schema-bearing artifacts instead of frozen counts. No scientific
assertion was removed or relaxed.

Validation: the full optional solver/domain suite passed **7,560 assertions across
87 top-level testsets**, including **65 new tolerance assertions**, the 17 pilot
physical-check assertions, and all 1,809 core assertions. The standalone pilot
rerun passed all 44 serialization/integration assertions. Local quality,
proof-inventory scope, source-hash consistency, and `git diff --check` passed.
Logs: `/tmp/nlpdiag-tolerance-full.log`, `/tmp/nlpdiag-tolerance-pilot.log`, and
`/tmp/nlpdiag-tolerance-quality.json`. Next implementation priority is direct-cause
ranking, evaluated separately from this severity change.

### Pilot priority policy — 11 September 2026

Added `power-repair-priority-v1`, a pilot-only review heuristic using explicit
code/basis pairs. It places proven contradictory bounds and direct initialization
evidence ahead of numerical residuals. Unknown pairs get no special promotion.
The original error findings, their evidence, and duplicates are preserved. Each
run saves the alphabetical baseline, prioritized ordering, per-rank reasons,
and paired localization metrics on the same findings.

The bad-start diagnosis moved from rank **10 to 1**, and contradictory bounds
from **2 to 1**. Top-three localization improved from **1/4 to 2/4**; localization
anywhere remains **2/4**. Clean error cases remain **0/1**, unavailable analyses
**0/5**, and scripted verified repairs **4/4**. This is development-corpus tuning,
not new detection, a causal certificate, or held-out effectiveness. The generic
library renderers are unchanged. Freeze the policy before unseen-case evaluation.

Validation: **78 standalone pilot assertions passed**, including 17 synthetic
ranking contracts and the complete five-variant run. Local quality, proof-inventory
scope, source-hash consistency, and `git diff --check` passed. Core source and its
tests were unchanged; the last full-suite baseline remains **7,560 assertions**.
Logs: `/tmp/nlpdiag-ranking-pilot.log` and `/tmp/nlpdiag-ranking-quality.json`.
Next work is unit/reference provenance and a separate gauge-check configuration,
followed by frozen held-out evaluation and observed human repair benefit.

### Separate gauge configuration — 11 September 2026

Added `connected-acp-uniform-shift-v1` to the pilot. Every variant receives the
same explicit angle-shift candidate from connected ACP topology and public
scalar-angle coordinates. Local degeneracy evidence, candidate mapping,
reference metadata, automatic candidate count, timing, and availability are
saved separately from ranked diagnostics. Unsupported inputs have an explicit
unavailable result; unaligned and tested-but-unobserved modes are distinct.

The local shift is observed only in the omitted-reference model (**1/1 omission,
0/4 other variants**). All comparisons complete. The observed library finding
has `PhysicalExpectation` basis, not `MathematicalProof`. The adapter actually
produces one automatic candidate on every variant of this fixture, despite all
five declaring one reference bus; the earlier concern about suppressed candidate
generation did not occur here. Reference metadata and candidate presence are
not substitutes for testing the model equations.

Validation: **109 standalone pilot assertions passed**, including the complete
five-variant rerun, explicit unsupported-input handling, observed/unobserved
controls, reference metadata, and unchanged paired ranking and repair outcomes.
Top-three ranking remains **2/4**, clean error cases **0/1**, and independently
verified scripted repairs **4/4**. Local quality, proof-inventory scope, source
hashes, and `git diff --check` passed. Core library source was unchanged; the last
full-suite baseline remains **7,560 assertions**, not a new full-suite run.

Verified artifacts: `work/power-repair-pilot-gauge-verified/`.
Logs: `/tmp/nlpdiag-gauge-verified.log` and `/tmp/nlpdiag-gauge-quality.json`.
These results establish local numerical separation on a development fixture,
not general missing-reference detection or autonomous repair. Unit provenance
and unseen-network/incident evaluation remain next.

### Source-aware load lineage — 11 September 2026

Added a separate `pilot-load-lineage-v1` workflow. A narrow reader extracts source
MW/MVAr and bus-row identities from the hash-pinned numeric MATPOWER fixture,
independently of PowerModels' per-unit conversion. The checker verifies the
ledger against the original source, then compares mapped load values after one
division by baseMVA. Evidence includes expected/actual values, residuals, declared
tolerance, source rows, and ratios. Incident labels and inverse patches are not
inputs. Missing or unsupported lineage is unavailable, not silently consistent.

Only the injected unit variant disagrees with source: bus 1 active load is
**0.011 p.u. instead of 1.1 p.u. from 110 MW**, ratio **0.01**. The other four
variants agree; all repaired loads agree. This localizes source inconsistency,
not an independently proven conversion operation or intended operator demand.
The source-aware workflow gets more information than generic diagnostics and
is scored separately. Model-only ranking remains **2/4**, clean errors **0/1**,
and independently verified scripted repairs **4/4**.

Validation: **149 pilot assertions passed**, including 22 isolated lineage
contracts and a complete five-variant rerun. Local quality, proof-inventory
scope, source hashes, and `git diff --check` passed. The core library was unchanged;
the last full-suite baseline remains **7,560 assertions**. Artifacts are in
`work/power-repair-pilot-lineage-verified/`; logs are
`/tmp/nlpdiag-lineage-verified.log` and `/tmp/nlpdiag-lineage-quality.json`.

Next: freeze these development policies and evaluate unseen networks/incidents.
Expand lineage to legitimate source updates, aggregation/rebasing, and equipment
units with explicit contracts. Human repair benefit remains unmeasured.

### Frozen case9 transfer evaluation — 11 September 2026

Selected the PowerModels 0.21.6 case9 fixture after a repository filename search
found no prior use in the searched paths. Recorded selection rules, eight
acceptance criteria, and hashes of 47 source/environment/fixture/test files in
`docs/power_repair_case9_freeze.json` before case9 execution. Added only fixture
parameterization to the harness; the diagnostic, priority, gauge, and tolerance
policies were unchanged. The case3-only source checker remains explicitly
unavailable on case9. Freeze guards run before and after evaluation.

All eight criteria passed: clean errors **0/1**, prioritized top-three localization
**2/4** versus alphabetical **1/4**, diagnostics unavailable **0/5**, gauge shift
observed only for the omitted reference, and independently verified scripted
repairs **4/4**. Bad-start rank is **1 versus 6**; contradictory-bound rank is
**1 versus 2**. Source-lineage unavailability is **5/5**, as predeclared.

Validation: **167 assertions passed** (149 development contracts plus 18 case9
integrity checks). Local quality, proof-inventory scope, freeze hashes, and
`git diff --check` passed. The core library was unchanged; the last full-suite
baseline remains **7,560 assertions**. Artifacts:
`work/power-repair-case9-validation/`. Logs:
`/tmp/nlpdiag-case9-validation.log` and `/tmp/nlpdiag-case9-quality.json`.

This is a new-to-pilot standard network using familiar injected incident families,
not a blind incident study or proof of operational usefulness. Case9 is now
exposed development data. Next evaluation must add genuinely new incident families
and other networks; user-observed repair benefit and broad source lineage remain
unfinished. Do not refresh the existing freeze to disguise policy changes.

### Frozen case14 capacity-family evaluation — 11 September 2026

Preserved the original case9 freeze and added a 50-file capacity evaluation
freeze before executing case14. The new incident sets all active generation
capacity to zero, with inherited and generator-bounded starts. An independent
exact aggregate witness checks closed passive ACP assumptions and proves the
capacity shortfall (approximately 2.59 p.u., or 259 MW). The diagnostic engine
does not receive this witness.

**Five of six acceptance criteria passed; the evaluation is not accepted.**
Both shortages have zero static errors and five ranked point errors. Resetting
generator starts leaves a valid implied branch-flow bound finding plus four
constraint residuals; these are not a global capacity-infeasibility diagnosis.
Both modified solver points fail independent physical checks. Both scripted
shortage repairs, plus the clean control, pass. No policy was tuned after seeing
the miss. The parsed-network corrections are retained in logs and saved data.

Validation: **177 harness assertions passed** (149 case3, 18 case9, 10 new
capacity witness/integrity assertions). This is separate from the failed
acceptance criterion. Local quality, proof-inventory scope, both freeze guards,
and `git diff --check` passed. Core source was unchanged; the last full-suite
baseline remains **7,560 assertions**. Artifacts:
`work/power-repair-case14-capacity/`. Logs:
`/tmp/nlpdiag-capacity-validation.log` and `/tmp/nlpdiag-capacity-quality.json`.

Next priority: a clearly scoped power-capacity preflight with explicit physical
assumptions, separating impossible models from bad starts. Any change is a
post-evaluation follow-up; case14 is now development data. Human repair benefit,
real incident records, and broader pipeline/source provenance remain unmeasured.

### Conditional capacity preflight follow-up — 11 September 2026

Implemented a separate experimental capacity data check requiring an explicit
closed-ACP, fixed-unsheddable-load contract. It validates supported components,
active bus references, finite values, consistent generator bounds, nonnegative
active loads/conductance, and passive branch/transformer parameters. Exact
rational totals produce `capacity_shortage`, `not_ruled_out`, or `unavailable`.
It does not inspect backend equations; any shortage conclusion is conditional
on the caller's declared contract. Aggregate adequacy never certifies feasibility.

The exposed case14 clean and repaired data are not ruled out; both shortage
variants are flagged independently of their starts. The original frozen failure
is retained, both case9/case14 freezes remain valid, and the old diagnostics are
unchanged. This is post-evaluation development with extra domain information,
not a held-out improvement claim or a stable public API.

Validation: **53 targeted assertions passed** (39 analytic/input contracts and
14 follow-up evidence checks), including near-threshold exact comparison,
finite-input aggregate overflow, unsupported devices, nonpassive data, and an
isolated-load example that must not become a feasibility claim. Local quality,
proof-inventory scope, freeze consistency, and `git diff --check` passed. Core
source was unchanged; the last full-suite baseline remains **7,560 assertions**.
Artifacts: `work/capacity-preflight-followup/`. Logs:
`/tmp/nlpdiag-preflight-followup.log` and `/tmp/nlpdiag-preflight-quality.json`.

Next: test transfer of the conditional preflight and verify its equation/source
contract before integration. Real incident records, operator repair benefit,
per-island adequacy, and broader source provenance remain unfinished.

### Conservative backend contract matcher — 11 September 2026

Added `checked_capacity_preflight(pm, data)` as a separate experimental helper.
It rebuilds standard ACP OPF constraints and checks the actual backend's named
variable set and supported scalar-row multiset using exact numeric keys. Deleted
or changed equations/bounds, unsupported functions/sets, opaque NLP blocks,
registered callbacks, ambiguous names, and unsupported source precision return
unavailable. It deliberately ignores starts/objective and does not infer broader
algebraic equivalence. Merely matching `pm.data` cannot satisfy this check.

The exposed case14 clean and shortage models match their supplied data. Tests
reject a deleted row, a changed coefficient with unchanged row count, an altered
capacity limit, callbacks, name ambiguity, and mismatched source data. Changing
starts preserves the model-level conditional result. **20 targeted assertions
passed**, along with local quality, proof-inventory scope, both old freeze checks,
and `git diff --check`. Core source was unchanged; the last full-suite baseline
remains **7,560 assertions**. Artifacts:
`work/capacity-model-contract-followup/`. Logs:
`/tmp/nlpdiag-model-contract.log` and `/tmp/nlpdiag-model-contract-quality.json`.

Matching a Float64 builder does not certify passivity of its rounded expanded
coefficients or the real-world meaning of its input. The capacity conclusion
remains conditional. Next work must bound this numerical/physical contract gap
before claiming unconditional backend infeasibility, and evaluate further networks.
Both original frozen evaluations remain intact; this is post-evaluation development.

### Encoded-equation capacity certificate — 11 September 2026

Added a separate experimental checker that extracts actual ACP equality rows and
explicit bounds after the conservative backend contract match. Exact rational
normalization verifies aggregate cancellation, reads encoded bus-demand constants
and generator limits, and bounds each branch's possible negative loss using its
rounded coefficients and voltage bounds. Integer square-root enclosures avoid
assuming exact passivity or relying on floating-point proof arithmetic.

A positive exact contradiction margin produces `certified_infeasible` for exact
real satisfaction of the encoded constraints, with zero feasibility tolerance.
Nonpositive margins are `not_ruled_out`; unsupported/ambiguous extraction is
`unavailable`. The checker uses fresh source-derived named coordinates rather
than mutable adapter variable dictionaries. It remains outside the stable API and
does not add a core mathematical-proof producer. The proof and limitations are
in `docs/encoded_capacity_certificate.md`.

Exposed case9/case14 zero-capacity variants have positive margins of approximately
2.70/2.59 p.u.; clean controls are not ruled out. A shifted transformer exposes an
approximately 2.47e-16-p.u. negative-loss allowance. The marginal positive
1e-18-p.u. source shortage is deliberately inconclusive. Encoded bus aggregation
rounding, MOI diagonal conventions, trigonometric orientation, altered metadata,
missing equations, starts, and unsupported devices have dedicated contracts.

Next: account explicitly for solver feasibility tolerances, then freeze the
checker and evaluate fresh networks/incident families. Consolidation into a usable
workflow and independently measured engineer repair benefit remain unfinished.

Validation: **56 targeted assertions passed**, including both original freeze
guards. A separate Python rational-arithmetic replay verified all **118 recorded
branch bounds and seven aggregate decisions**, using a squared inequality rather
than the implementation's square-root-enclosure calculation. Local quality,
proof-inventory scope, and `git diff --check` passed. Core source was unchanged;
the last full-suite baseline remains **7,560 assertions**, not rerun for this
experimental helper. Artifacts: `work/encoded-capacity-followup/summary.json`.
Logs: `/tmp/nlpdiag-encoded-capacity.log`, `/tmp/nlpdiag-encoded-quality.json`.

### Absolute-tolerance capacity certificate — 11 September 2026

Added `tolerant_capacity_certificate` as an experimental wrapper around the
unchanged encoded-equation checker. It requires an explicit absolute-unscaled
true-residual contract and separate finite nonnegative equality, generator-bound,
and voltage-bound tolerances. The proof subtracts the weighted equality budget,
increases aggregate generation capacity, and recomputes rounded branch-loss
allowances on relaxed voltage domains. Signed voltage values are covered when a
relaxed lower bound crosses zero. Zero contradiction margins remain inconclusive.
The derivation and usage are in `docs/tolerant_capacity_certificate.md`.

**42 targeted assertions passed**: invalid contracts, exact equality/generator/
combined budget boundaries, strict comparisons around a threshold, clean controls,
and relaxed voltage domains. An independent Python rational replay verified
**65 branch bounds and six decisions**. At 1e-6 for each declared tolerance, the
exposed case9 zero-capacity example retains a 2.69997-p.u. contradiction margin.
Both frozen evaluations, proof-inventory scope, local quality, and `git diff --check`
passed. Core source and the existing encoded checker were unchanged; the last
full-suite baseline remains **7,560 assertions**, not rerun for this wrapper.
Artifacts: `work/tolerant-capacity-followup/summary.json`. Logs:
`/tmp/nlpdiag-tolerant-capacity.log`, `/tmp/nlpdiag-tolerant-quality.json`.

This certifies a declared mathematical tolerance contract, not a particular
optimizer configuration. Mapping solver acceptance to these true-residual bounds
still requires treatment of scaling, relative tests, bound relaxation, and
numerical evaluation error. No solver stopping settings are interpreted silently.
Next: establish that mapping for the pinned solver workflow, then freeze the
checker for fresh-case validation. Stable-API integration and practical repair
benefit remain unproven. Original frozen evaluations remain unchanged.

### Verified returned-point solver acceptance — 11 September 2026

Inspected the pinned Ipopt.jl status mapping and frozen runner. The old pilot's
`tol=1e-9` and separate numerical feasibility report do not bound true residual
evaluation error. Added a separate `solve_and_verify` workflow: explicit solver
settings are recorded, while acceptance requires independent rational enclosure
verification of every original supported scalar constraint at the returned point.
This establishes the absolute tolerance contract for this workflow's accepted
points without inferring a universal guarantee from Ipopt termination status.

The gate checks original unscaled equalities, inequalities, intervals, and
variable bounds. Exact coefficient/point arithmetic and degree-127 Taylor
remainders enclose trigonometric evaluation. Unsupported large angle arguments,
nonfinite or incomplete points, changed backends, and uncertain enclosures cannot
be accepted. Solver success is recorded separately; acceptance certifies primal
tolerance compliance, not optimality. Existing frozen runners and certificate
helpers are unchanged. The derivation is in `docs/verified_solver_acceptance.md`.

On exposed case9, the clean returned point passes all **184 constraints** and is
accepted after `LOCALLY_SOLVED`. The zero-capacity solve is `LOCALLY_INFEASIBLE`;
its returned point violates **27 of 184 constraints** and is rejected, consistent
with the capacity certificate. A separate exact-arithmetic replay checks all
**368 recorded enclosure/set classifications**; it does not independently
reconstruct the enclosures.

Next: freeze this complete experimental workflow and test fresh cases, then
consolidate the report and measure engineer repair benefit. Ipopt's internal
success status by itself remains uncertified. This is post-evaluation development,
outside the stable API, and does not alter the original frozen results.

Validation: **31 targeted assertions passed**, including rational trigonometric
bounds, enclosure boundary classification, cancellation missed by ordinary float
arithmetic, full row coverage, invalid/large-angle points, changed equations, and
both freeze guards. Local quality, proof-inventory scope, and `git diff --check`
passed. Core source was unchanged; the last full-suite baseline remains **7,560
assertions**, not rerun for this experimental workflow. Artifacts:
`work/verified-solver-acceptance/summary.json`. Logs:
`/tmp/nlpdiag-verified-solver.log`, `/tmp/nlpdiag-verified-quality.json`.

### Frozen workflow transfer evaluation — 11 September 2026

Selected the public PowerModels case24/case30 fixtures after a filename search
found no references in searched project tests/benchmarks/docs (excluding JSON).
Headers were inspected before selection; no diagnostic outcomes were used. Froze
62 input/code/protocol files before running seven predetermined variants on each
network. This is new-to-workflow development transfer, not blinded validation.

**11/14 capability criteria passed; the overall acceptance gate failed.** Clean,
zero-capacity, marginal-conservatism, valid-rebase, and unsupported-storage criteria
passed on both networks. Both isolated-load cases returned unavailable because
required equation selection was absent or ambiguous. The case30 unit-corruption
variant was mathematically accepted. Case24's unit variant was rejected, satisfying
an alert proxy without identifying the unit error. This count is not accuracy or
evidence of source-aware root-cause diagnosis.

No frozen code, threshold, case, or criterion was changed after outcomes. All 14
records and transformed inputs are retained. Five harness integrity assertions,
all 62 freeze hashes, both old freezes, all 14 input hashes, independently checked
isolation premises, local quality, proof-inventory scope, and `git diff --check`
passed. Core source was unchanged; the last full-suite baseline remains 7,560
assertions, not rerun for the evaluation harness.

Results and priorities: `docs/power_workflow_validation_results.md`. Freeze:
`docs/power_workflow_validation_freeze.json`. Artifacts:
`work/frozen-power-workflow-validation/`. Logs:
`/tmp/nlpdiag-frozen-workflow-validation.log`, `/tmp/nlpdiag-frozen-quality.json`.
Next priorities are constant-balance/per-island coverage and source-unit provenance,
followed by a consolidated report and engineer incident study. Preserve this failed
gate through any post-evaluation fixes; these cases are now exposed development data.

### Island/constant-balance follow-up — 11 September 2026

Added an experimental island certificate without editing any frozen implementation.
It projects each active AC-connected component, then requires its named variables
and full row multiset to be a subset of the actual original backend. Direct exact
constant-equality contradictions avoid the ambiguous selection in both exposed
isolated-load cases. Otherwise the existing tolerance-aware capacity check runs
on the verified island subset. A certified subset suffices; partial unavailability
remains explicit and no adequacy result becomes a feasibility assertion.

Both exposed case24/case30 isolated-load failures now receive constant-equality
certificates. A connected two-bus deficit is certified despite ample global
capacity. Clean, rebased, and marginal controls remain not ruled out. The new
`solve_with_island_preflight` wrapper rejects the isolated contradictions before
solving and delegates a clean control to the existing verified solver workflow,
which accepts its returned point. Source-unit provenance is still unfinished.

**44 targeted assertions passed**, including strict constant tolerance boundaries,
row multiplicities/names, changed backends, controls, the two-bus island, workflow
integration, and all three original freezes. Independent rational checks replayed
positive witness margins. Local quality, proof-inventory scope, and `git diff --check`
passed. Core source and all frozen helpers were unchanged; the last full-suite
baseline remains 7,560 assertions and was not rerun for this follow-up.
The frozen validation remains **11/14, failed**, not retrospectively rescored.

Proof and usage: `docs/island_capacity_followup.md`. Artifacts:
`work/island-capacity-followup/summary.json`. Logs:
`/tmp/nlpdiag-island-followup.log`, `/tmp/nlpdiag-island-quality.json`.
Next: connect source-unit provenance to the workflow, then consolidate its report.

### Explicit source-load provenance follow-up — 11 September 2026

Added a hash-pinned caller-selected numeric source-table contract and connected it
to the island/verified-solver workflow. It reads source decimal MW/MVAr exactly and
compares physical per-bus totals, allowing zero-load omissions and equivalent load
splitting. A changed base requires an explicit rebase target and physically matching
loads. Changed reference bytes, unsupported statuses, invalid quantities, and
backend/data disagreement remain unavailable. The reference is never silently
regenerated from the model being checked.

Both exposed case24/case30 unit mutations now produce source mismatches and stop
before solving. A consistently rebased case30 input proceeds to verified acceptance.
This is disagreement with a selected reference, not mathematical infeasibility,
proof of source intent, or identification of the exact conversion operation.
Generator/branch unit provenance and full rebasing equivalence are not checked.

**46 targeted assertions passed**, including genuine revised load references,
exact comparison boundaries, reactive corruption, declared/undeclared/incorrect
rebasing, equivalent splits, invalid values, changed hashes, backend mismatch,
workflow integration, and all three original freezes. An independent Python
raw-source/input replay verified 108 physical comparisons and 38 mismatches.
Local quality, proof-inventory scope, and `git diff --check` passed. Core source
was unchanged; the last full-suite baseline remains 7,560 assertions, not rerun
for this follow-up. The original frozen **11/14 failed** result is preserved.

Usage and scope: `docs/source_load_followup.md`. Artifacts:
`work/source-load-followup/summary.json`. Logs: `/tmp/nlpdiag-source-load.log`,
`/tmp/nlpdiag-source-quality.json`. Next: consolidate the workflow into a clear
report, then evaluate further incidents with appropriate source records and engineers.

### Consolidated diagnostic report — 11 September 2026

Added one experimental facade and CLI for the existing source-load, island, and
verified-solver workflow. It produces readable Markdown and full JSON evidence,
showing source mismatches, certified subsets, returned-point compliance/violations,
stage unavailability, and unattempted stages separately. Source comparisons include
affected buses, units, displayed values/differences, and an inspection step. Exact
rational values, tolerances, original nested evidence, and solver records are kept
in JSON. Acceptance labels without the required available evidence become invalid.

**25 targeted assertions passed**, including an end-to-end island report and all
three frozen evaluations. The standalone CLI successfully generated a source-
mismatch report from exposed case30 data. Both Markdown outputs were inspected.
Local quality, proof-inventory scope, and `git diff --check` passed. Core source and
frozen helpers were unchanged; the last full-suite baseline remains 7,560 assertions
and was not rerun for this reporting layer. No detection capability or frozen score
is changed by formatting the existing evidence.

Entry point: `docs/power_diagnostic_report.md`. Example artifacts:
`work/power-diagnostic-report/report.md` and
`work/power-diagnostic-source-report/report.md`, each with adjacent full JSON.
Logs: `/tmp/nlpdiag-report-final.log`, `/tmp/nlpdiag-report-cli.log`,
`/tmp/nlpdiag-report-quality.json`. Next: evaluate the integrated report on further
source-backed incidents and with engineers; full equipment provenance, stable API,
and measured repair benefit remain unfinished.

### Integrated report transfer and engineer-study preparation — 11 September 2026

Froze the entire current workflow across 73 files and ran eight predetermined
source-backed probes on case6/case7_tplgy. Case6 is a repeated case3 topology, not
an independent network sample. **4/8 criteria passed; the gate failed.** Case6
passed clean acceptance, reactive-unit mismatch, stale-reference, and zero-capacity
probes. All case7 probes stopped at the unsupported dcline model contract, so the
source checks were not attempted. This is a coverage limitation with correct
scope refusal, not a false certificate. No retuning or case substitution occurred.

Five harness integrity assertions passed. All four freeze inventories, eight saved
input hashes, local quality, proof-inventory scope, and `git diff --check` passed.
Core source was unchanged; the last full-suite baseline remains 7,560 assertions,
not rerun for this harness. The original 11/14 failure remains unchanged. Results:
`docs/integrated_report_validation_results.md`; artifacts:
`work/frozen-integrated-report-validation/`; logs:
`/tmp/nlpdiag-integrated-validation.log`, `/tmp/nlpdiag-integrated-quality.json`.

The user confirmed there are no incident records/reviewers yet. Prepared a study
protocol, incident template, reviewer form, and independent-adjudication form in
`studies/power_diagnostic_pilot/`. The study is not run; no contacts, participant
data, repair-time measurements, or efficacy claims exist. Next software priority:
independent partial analyses with explicit scope, without weakening solver acceptance.
Real incident/reviewer availability remains required for measuring engineer benefit.

### Independent partial analysis follow-up — 12 September 2026

Added a new facade and CLI that attempt source-load comparison independently of
model-contract matching. Model-scope failures no longer hide the source result.
When correspondence with the backend is unverified, source findings are explicitly
about supplied data only; the workflow returns partial results and never invokes
the solver. Supported source-consistent inputs retain the unchanged island and
verified-solver acceptance path. Earlier frozen drivers/helpers remain untouched.

The exposed case7 probes now retain both the unsupported-DC model reason and their
independent source outcome: inactive load records are unsupported in three probes,
and the stale-reference probe reports its hash mismatch. This is not a claim of
case7 unit-error detection. A controlled scope-marker probe demonstrates that useful
source mismatches can be retained without a valid backend. A clean supported case6
still reaches verified acceptance, while its corrupted loads stop before solving.

**41 targeted assertions passed**, including all four frozen evaluations. The new
CLI produced the expected two-reason partial report; its Markdown was inspected.
Local quality, proof-inventory scope, and `git diff --check` passed. Core source was
unchanged; the last full-suite baseline remains 7,560 assertions, not rerun for this
facade. Both frozen failed gates (11/14 and 4/8) are preserved without rescoring.

Usage: `docs/partial_power_diagnostics.md`. Artifacts:
`work/partial-power-diagnostics/` and `work/partial-power-report-cli/`. Logs:
`/tmp/nlpdiag-partial.log`, `/tmp/nlpdiag-partial-cli.log`,
`/tmp/nlpdiag-partial-quality.json`. Next scope work must address explicit provenance
for load-status changes; unsupported DC models remain unavailable. The engineer
study remains prepared, not run, pending incidents and reviewers.

### Explicit load-status provenance — 12 September 2026

Added a nominal load-allocation contract tied to a selected source hash/revision,
plus ordered disconnect/reconnect events with unique IDs, reasons, and evidence
references. Final statuses must match the ledger; inactive nominal records must
remain present with unchanged allocation and bus mapping. Nominal per-bus totals
still pass the existing source/rebase comparison. Returned events are snapshots,
so later caller edits cannot change already-produced evidence. The declarations
and evidence references are not authenticated operator authorization.

The report explicitly compares nominal loads before switching and lists declared
inactive IDs. With a synthetic disconnect record, case7 now has consistent source
provenance but retains its unsupported-DC model result and does not invoke a solver.
A supported clean control retains the original verified acceptance path. No frozen
code, score, or acceptance prerequisite was changed.

**28 targeted assertions passed**: disconnect/reconnect history, unexplained states,
missing/changed records, inconsistent/no-op/duplicate events, missing reasons or
evidence references, stale identity, strict status types, evidence immutability,
workflow scope, and all four original freezes. An independent event-chain replay
matched the saved final states. Markdown output was inspected. Local quality,
proof-inventory scope, and `git diff --check` passed. Core source was unchanged;
the last full-suite baseline remains 7,560 assertions, not rerun for this helper.

Schema and usage: `docs/load_status_contract.md`. Artifacts:
`work/load-status-followup/`. Logs: `/tmp/nlpdiag-load-status.log`,
`/tmp/nlpdiag-status-quality.json`. Next: freeze the status-aware path and evaluate
additional independently prepared source/switching scenarios. Real incident review
remains pending; the engineer study is prepared, not run.

### Frozen status-provenance evaluation — 12 September 2026

Froze 82 files and ran nine predetermined scenarios on a new synthetic two-bus
fixture, with separately authored physical reference/allocation records and model
blueprints. This is not independent engineer evidence. **4/9 criteria passed; the
gate failed.** Baseline, reconnect, valid-rebase, and the mechanical non-authentication
wording criterion passed. Four invalid-contract cases hit report-construction errors;
a stale revision label was accepted despite the separately prepared manifest.

A post-run read-only trace confirmed that all four underlying contract rejections
were correct. Their reason strings were hidden when a string-only inferred stage
vector rejected a model-stage dictionary containing `nothing`. Fix nullable report
schema typing first. Revision labels currently lack authoritative identity mapping;
clarify/validate that metadata without claiming source or operator authentication.
Neither issue was patched or rescored in the frozen run.

Four harness integrity assertions, all five freezes, nine input/contract hash pairs,
local quality, proof-inventory scope, and `git diff --check` passed. Core source was
unchanged; the full-suite baseline remains 7,560 assertions and was not rerun.
Human interpretation review remains not run; the study still has no participants
or incident records. Earlier failed gates remain intact.

Results: `docs/status_provenance_validation_results.md`; artifacts:
`work/frozen-status-provenance-validation/`; logs:
`/tmp/nlpdiag-status-validation.log`, `/tmp/nlpdiag-status-diagnosis.log`,
`/tmp/nlpdiag-status-validation-quality.json`.
