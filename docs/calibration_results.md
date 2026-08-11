# Calibration results

This document records bounded empirical results that have passed the current
artifact/readiness checks. It is not a leaderboard and does not convert local
solver behavior into a physical diagnosis.

## 2026-08-10: corrected Ipopt option campaign

Status: **design-qualified, provenance-limited development result**.

The campaign used BMOPFTools' `pf_zip_3ph.dss` and `pf_yd_xfmr.dss` fixtures,
iteration budgets 5 and 25, native and all-zero start policies, and three
explicit distinct option profiles:

- monotone barrier baseline;
- adaptive barrier with objective/constraint filter globalization; and
- adaptive barrier with never-monotone-mode globalization.

Public Ipopt callback points and sparse BMOPFTools row-family residuals were
captured. Dense analysis was not enabled. The environment used Julia 1.12.6,
JuMP 1.31.1, Ipopt 1.15.0, MadNLP 0.10.1, BMOPFTools 0.1.0, and the
NLPDiagnostics development tree at revision `1cf257f`.

### Readiness

All 24 observations and 16 baseline comparisons completed. All non-baseline
observations had a matched same-case, same-budget, same-start baseline. Every
row-family residual trace was available and nonempty. Eight direct comparisons
between the two adaptive profiles were also available.

### Observations

- Neither adaptive profile changed restoration presence, the endpoint residual
  failure signature, the first-captured family residual, the global family
  peak, or any post-first family trajectory relative to the monotone baseline.
- The largest raw family-statistic difference was approximately `6.04e-11` in
  the zero-start transformer's real-voltage family. It remained below the
  declared combined tolerance (`1e-10` absolute and `1e-8` relative).
- Both adaptive profiles changed the native-start transformer's five-iteration
  classification from a bounded solver failure to source-domain consistency.
  The family trajectories and endpoint residual signature did not change.
- At 25 iterations the transformer classifications agreed. The adaptive traces
  used one fewer callback record with the native start and two fewer with the
  zero start.
- The zero-start ZIP fixture retained one restoration callback and the endpoint
  residual failure signature under every option profile and both budgets. The
  native-start ZIP fixture did not reproduce that restoration signature.
- The two adaptive globalization profiles were identical on every recorded
  classification, phase, trace-length, endpoint-signature, and family-trajectory
  comparison in this bounded fixture set.

These results support two narrow conclusions. First, the observed ZIP failure
signature is initialization-sensitive and persists across these barrier-policy
changes. Second, the transformer's short-budget classification is
algorithm-sensitive without a corresponding material row-family residual
change. They do not identify a defective formulation family or establish that
the two adaptive globalizations are generally equivalent.

### Provenance limitation

The run occurred on a modified development checkout. Its original solve-time
environment schema recorded the Git revision but predated dirty-tree content
fingerprinting. The aggregation step records that the checkout was dirty, but
cannot reconstruct the exact source state at the start of every child solve.
Consequently this result can guide development and validates the corrected
pipeline, but it should be repeated from a fixed clean revision before use in a
publication or release calibration table. Subsequent benchmark environments
record a content fingerprint for dirty tracked and untracked source state.

## 2026-08-11: multiconductor option campaign

Status: **design-qualified, fixed-development-tree result**.

The v4 campaign used BMOPFTools' `pf_1ph_freeneutral.dss` and
`pf_delta_load.dss` fixtures, iteration budgets 5 and 25, native and all-zero
initialization policies, and the same three distinct monotone/adaptive Ipopt
profiles as the corrected campaign above. It used the `context` stage,
captured public iterate points and named row-family residuals, and disabled
dense-rank work. Every child solve used Git revision `1cf257f` with the same
dirty-tree content fingerprint
`d06b95b9deac4471e04621ec20889def40b929cf00d41cf7020ab9a6c44003da`.

### Readiness

All 24 observations, 16 same-case/same-budget/same-start baseline comparisons,
and eight direct adaptive-profile comparisons completed. All residual traces
were available and nonempty. Model variable counts, structural BMOPF context
metadata, and source behavior contracts were complete and invariant in every
paired comparison. The multiconductor semantic gate therefore passed with zero
contract changes. Endpoint-conditioned context finding codes remained separate
outcomes and changed in two comparisons.

### Observations

- The free-neutral fixture was stable across every option profile, budget, and
  initialization policy on classification, restoration, endpoint signature,
  named family trajectories, and BMOPF context finding codes. Its final printed
  primal infeasibility was approximately `6.70e-9`; the campaign does not turn
  that local solver-scaled value into a physical tolerance claim.
- Native-start delta runs were classification- and family-trajectory-stable.
  Both adaptive profiles used one fewer captured callback than the monotone
  baseline.
- With the all-zero start and a five-iteration budget, the monotone delta run
  was classified as a solver failure not explained by source-domain thresholds;
  both adaptive runs were source-domain consistent. The monotone final dual
  infeasibility was approximately `1.50e-9`, versus approximately `9.99e-15`
  for both adaptive profiles. At 25 iterations all three profiles were
  source-domain consistent.
- The adaptive zero-start delta trajectories differed from monotone in the
  real KCL and real/imaginary line-voltage-drop families. Their post-first peak
  differences were approximately `5.57e-10`, `3.89e-10`, and `-6.43e-10` in
  raw model coordinates. They exceed the campaign's absolute noise screen but
  are still very small and have no cross-family physical normalization; they
  are numerical trajectory evidence, not evidence of defective KCL or line
  equations.
- The two adaptive globalization profiles were identical on every recorded
  comparison. No run entered restoration.

The narrow conclusion is that this delta fixture has a short-budget,
initialization-conditioned response to monotone versus adaptive barrier
strategy. The effect disappears with a larger iteration budget, so it is more
useful as a solver-method profiling case than as evidence of a mathematical
model error.

### Scale-semantics limitation learned from the fixture

Every delta endpoint reported two `component_port_nominal_scale_mismatch`
findings on `vr_lb_n` and `vi_lb_n`. These are the load-bus neutral rectangular
coordinates, which remain free model variables but converge near zero in the
balanced delta case. The current adapter assigns one scalar 1 p.u. nominal
scale to the entire voltage port, so it cannot distinguish energized phase
coordinates from neutral/common-mode coordinates whose expected operating
magnitude may be near zero. These warnings must not be interpreted as harmful
variable scaling. Port metadata needs terminal-role-specific nominal scales
or an explicit “reference/expected-zero” convention before this finding family
is calibration-qualified for multiconductor models.

This campaign ran from one content-fingerprinted development tree but not a
clean commit. It is suitable for directing implementation and selecting future
solver experiments; release or publication claims should repeat it from a
clean tagged revision.

## 2026-08-11: terminal semantics and Golub--Kahan software calibration

Status: **software-qualified; bounded benchmark confirmation complete**.

The multiconductor port contract now distinguishes phase, neutral, and ground
reference coordinates through ordered terminal declarations. Unit tests cover
both grounded and floating neutrals: an explicit ground must satisfy its zero
target within the declared model-coordinate tolerance, while a floating
neutral is allowed to be either near zero or materially displaced without
inheriting the phase-voltage nominal scale.

A fresh 25-iteration monotone/native-start run of `pf_delta_load.dss` completed
as `solver_and_source_domain_consistent`. Its context report checked 42 mapped
terminal scales and eight explicit ground-reference values, retained 12
intentionally unscaled neutral coordinate mappings, and reported zero scale
projection failures. Neither `component_port_nominal_scale_mismatch` nor
`component_port_expected_coordinate_value_mismatch` was present. This confirms
the original two false positives are removed in the motivating fixture.

The full 24-cell v4 option matrix has now also been repeated from one frozen
development-tree state. All 24 observations, 16 baseline comparisons, and eight
direct adaptive-profile comparisons passed artifact, trajectory, and
multiconductor semantic-readiness gates. Every observation used environment
fingerprint
`7e93b6daade2aefb51527005ca67c4126c9751730ed5fc95266326c9641d1238`
at Git revision `3a8cd230ceb8c7d93a9b58872f03b919196bd822`, with dirty-tree diff
fingerprint
`45acc7916c0a788d9576ca23cb42c04119008980c5cdeaa0f38ac182e6e5d888`.
There were zero model-semantic contract changes and zero occurrences of either
terminal scale or expected-value mismatch code. The free-neutral fixture
checked 32 mapped scales and eight ground values while retaining 14
intentionally unscaled coordinates; the delta fixture checked 42 scales and
eight ground values while retaining 12 intentionally unscaled coordinates.
Neither fixture had a scale-projection failure.

The controlled numerical signal was preserved. Exactly one observation—the
five-iteration monotone/zero-start delta run—remained failure-classified; both
adaptive profiles changed that cell to source-domain consistency. All profiles
were consistent at 25 iterations, and no run entered restoration. The two
adaptive profiles agreed on every direct comparison. Against monotone, both
adaptive profiles changed the zero-start delta KCL-real and real/imaginary
line-voltage post-first peaks at both budgets by approximately `5.57e-10`,
`3.89e-10`, and `-6.43e-10`, respectively. These are material under the
campaign's declared numerical comparison tolerance but remain unnormalized raw
model-coordinate trajectory differences, not physical defect evidence.

Two context finding-code comparisons changed because the failure-classified
five-step baseline carried `bmopf_opf_differentiability_not_ready` while the
adaptive endpoints did not. This is endpoint-conditioned evidence and was not
a semantic-contract change. The rerun therefore closes the terminal-semantics
regression gate while retaining the delta fixture as a bounded
initialization/algorithm profiling case.

The Golub--Kahan operator calibration now includes deterministic multi-seed
coverage. A six-seed full-column budget matches the guarded dense-SVD right
nullity on all five oracle cases: dependent square, rectangular
underdetermined, full-column-rank rectangular, clustered-small-plus-zero, and
zero rectangular matrices. Every nonempty consolidated span has minimum
principal cosine at least `0.99` with the dense reference. The deliberately
inadequate one-step budget misses three of the four rank-deficient cases; only
the zero operator is recovered because independent seeds directly span its
nullspace. This negative control is retained as explicit false-negative
evidence rather than hidden by a favorable default budget.

Single-projection singular values still agree on diagonal, scaled diagonal,
exactly rank-deficient, and rectangular underdetermined matrices; lifted Ritz
backward errors are directly bounded and the rectangular/right-null cases
produce full-operator residuals below `1e-12`. The complete package and local
Ipopt/MadNLP/PowerModels/BMOPFTools extension targets pass; the standalone
multi-seed oracle block has 27 assertions, the core rank block has 143, and the
BMOPFTools staged-adapter subsection has 312. This validates software contracts
and exposes one bounded miss-rate experiment. It does not yet validate
smallest-singular coverage on adversarial or large-model matrices.

## 2026-08-11: restarted smallest-direction adversarial calibration

Status: **software-qualified candidate method; adverse numerical controls
retained**.

The restarted locally optimal block tracker was evaluated through
`benchmarks/calibrate_restarted_smallest_singular.jl` on ten deterministic
dense-oracle cases. All expected relations matched:

- five ordinary dense agreements: separated diagonal, clustered smallest pair,
  rotated planted spectrum, rotated planted two-dimensional nullspace, and a
  rectangular right nullspace;
- two agreements with a deliberately non-unique dense target subspace: a
  repeated smallest singular value when requesting one direction, and the zero
  operator;
- two expected unconverged results: an insufficient one-iteration budget and
  the badly scaled full-rank matrix `diag(1e8, 1, 1e-8)`; and
- one expected false-convergence control on the 6-by-6 Hilbert matrix.

The Hilbert result is the most important outcome. The normal-residual and
successive-subspace policy converged to a stationary candidate near `3.62e-6`,
while dense SVD reported a smallest singular value near `1.08e-7`. The
scale-normalized value error was approximately `2.17e-6`, above the declared
`1e-6` oracle comparison tolerance. Thus internal convergence is demonstrably
insufficient to claim smallest-singular coverage. The public report preserves
this as `singular_value_disagreement`.

The badly scaled control stopped at `trial_subspace_stagnation` with a candidate
near `2.96e7`, rather than misreporting the dense `1e-8` direction. This is an
honest coverage failure caused by squared-spectrum and finite-precision trial
space loss. The next backend must provide independent evidence through a
harmonic Golub--Kahan, Jacobi--Davidson SVD, or vetted LSMR/LSQR-class method;
the restarted normal-operator tracker remains useful for numerical-method
experiments but is not promoted to a rank backend.
