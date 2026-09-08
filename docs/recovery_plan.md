# Correctness recovery plan

This is the active implementation sequence following the [5 September scientific
review](/Users/uqfgeth/Documents/GitHub/NLPDiagnostics.jl/reviews/2026-09-05/report.md).
The older roadmap remains a historical implementation and experiment ledger.
New finding families and numerical backends are deferred while this sequence
is completed.

## First implementation batch: scientific contracts

Implemented changes, with behavioral regressions in
[scientific_contracts.jl](/Users/uqfgeth/Documents/GitHub/NLPDiagnostics.jl/test/scientific_contracts.jl):

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
[arithmetic regressions](/Users/uqfgeth/Documents/GitHub/NLPDiagnostics.jl/test/certified_interval_arithmetic.jl)
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

## Next: complete the proof boundary

1. Audit the remaining direct static proof producers, including objective-ray
   and other algebraic identity recognizers.
   Certify their arithmetic or demote their findings; the interval guard does
   not automatically cover independent calculations in these families.
2. Restore useful certified nonlinear range coverage with validated outward
   rounding or exact rules. Do not relax certification to recover old counts.
   Integrate the certified quadratic coordinate enclosures into domain and
   initialization propagation with explicit certificate and provenance tests.
3. Retain both certified mathematical evidence and numerical evaluation errors
   when they disagree. Test feasible cancellation examples, genuinely infeasible
   controls, nonfinite inputs, coefficient permutations, and boundary domains.
4. Extend source identity through derived evaluations, Hessians, physical maps,
   and persistent artifacts. Define an explicit producer-version contract for
   opaque callbacks. Public-description matching alone cannot verify them.

Exit condition: every enabled proof-producing family has an independent oracle,
negative controls, and a verified unavailable path; the review's interval
counterexample is covered by a passing enclosure regression.

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
