# Calibration results

This document records bounded empirical results that have passed the current
artifact/readiness checks. It is not a leaderboard and does not convert local
solver behavior into a physical diagnosis.

## 2026-08-23: typed BMOPFTools capability boundaries

The BMOPFTools terminal-current, passive-network map, and terminal-attachment
reports now preserve their existing counts and findings while exposing typed
capability records through `report_data`. The terminal-attachment adapter emits
stable code, category, stage, and reason fields when one or more attachment
ports cannot be mapped to registered bus-voltage coordinates. Extension syntax
parses in the known local environment; runtime qualification remains dependent
on the active BMOPFTools checkout. The serializer also preserves adapter-
specific dependency categories and stages, as exercised by the BMOPFTools
differentiability and MadNLP capture capability reports.

Solver-result analysis now emits typed records when a complete public primal
vector is unavailable or a solver-postmortem adapter cannot be read. The
existing findings and metadata remain intact; local contracts distinguish the
capability boundary from the dependency boundary.

Active-set second-order analysis now serializes multiplier-recovery work-guard
unavailability with a typed numerical record, while preserving the existing
unavailable finding. The bounded local guard case confirms the record without
promoting any reduced-Hessian or KKT interpretation.

The scalar active-set report also serializes MFCQ screen unavailability when
the equality-Jacobian work guard prevents the screen. This remains numerical
capability evidence only; it does not classify MFCQ or establish a constraint
qualification failure.

Coupled-set Robinson qualification now preserves an explicit typed capability
record when generic geometry is unsupported or incomplete. The combined
active-set report carries the record without promoting a cone qualification or
physical interpretation.

Active-set structural matching now exposes typed capability records when
callback/NLP-block rows cannot be aligned with ordinary scalar incidence
nodes. The dependent Dulmage–Mendelsohn partition boundary is typed
separately, while the existing representational finding and conservative
withholding of matching-based conclusions remain unchanged. The regression
case passes locally; this is alignment/provenance evidence, not a structural
or physical conclusion.

Reduced-Hessian analysis now serializes dense-work-guard unavailability with a
typed numerical record in both the direct report and active-set second-order
wrapper. Existing findings and legacy metadata remain unchanged. The bounded
local guard passes; this is numerical capability evidence, not a curvature or
second-order optimality claim.

Structural-to-numerical rank comparison now serializes dense-work-guard
unavailability in the degeneracy report with a typed numerical record. The
existing conservative finding remains intact and no nullspace or physical
interpretation is promoted.

Iterative right-nullspace, left-nullspace, and spectrum probes now serialize
incomplete-Jacobian unavailability with typed numerical records. Existing
probe findings remain unchanged; no candidate nullspace, dependency, or
spectral interpretation is promoted when the sparse operator is unavailable.

The main numerical report now types dense Jacobian-rank, sparse-pattern, and
unscaled/scaled sparse-QR backend unavailability. Guarded and incomplete-row
local cases preserve their existing rank findings and reasons; no rank-loss
interpretation is promoted from an unavailable backend.

Sparse-QR nullspace extraction now serializes input/factor-fill and basis
storage guard failures with a typed numerical record. The local guard case
passes without promoting a nullspace, rank, or physical interpretation.

Sparse-QR nullspace dense calibration now serializes guarded dense-oracle
unavailability with a typed numerical record. The local dense-work guard
passes without promoting sparse/dense agreement or disagreement.

Sparse-QR nullspace persistence now serializes cross-point extraction
unavailability with a typed numerical record. The bounded repeated-point guard
passes without promoting rank or subspace persistence.

Restarted and harmonic smallest-singular dense calibrations, together with the
independent backend crosscheck, now serialize guarded candidate/oracle
unavailability with typed numerical records. Bounded local guards pass without
promoting candidate agreement, disagreement, or convergence conclusions.

Golub--Kahan Ritz probing, multi-seed coverage, guarded dense calibration, and
restarted candidate analysis now serialize numerical unavailability with typed
records. Empty-row and bounded-storage local guards pass without promoting a
candidate span, nullspace, or dense-oracle conclusion.

Jacobian rank tolerance sweeps and cross-point condition persistence now expose
typed numerical records when dense work or finite multi-point estimates are
unavailable. Guarded local cases preserve their existing findings without
promoting rank sensitivity or conditioning conclusions.

Jacobian scaling, derivative-provenance, and rank-persistence reports now expose
typed numerical records for insufficient point coverage or unavailable dense
rank estimates. Existing cross-point observations remain unchanged and are not
promoted to formulation or physical claims.

Row-family Jacobian perturbations now serialize a typed numerical boundary when
the baseline or retained-family dense rank path is unavailable. Sparse-pattern
fallback findings remain available, while the local guard case makes no rank or
causal attribution claim.

Iterative right- and left-null candidate persistence now serialize typed
numerical records when too few finite probes are available for comparison. The
existing finite-budget persistence semantics remain unchanged; no nullspace or
physical conclusion is promoted.

Reduced-Hessian flat-subspace persistence now serializes a typed numerical
record when too few complete snapshots contain nonempty flat directions. The
existing conservative persistence and expected-mode semantics remain intact.

Reduced-Hessian multiplier persistence now serializes a typed numerical record
when a retained snapshot lacks a complete row-aligned multiplier vector. The
existing multiplier persistence findings remain unchanged; no multiplier
uniqueness or KKT conclusion is promoted.

Selected active-row Jacobian rank analysis now emits the same typed numerical
boundary when its dense-work guard is exceeded. The local contract keeps this
as a capability limitation rather than a rank-loss conclusion.

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

## 2026-08-11: cross-backend smallest-direction adversarial calibration

Status: **software-qualified candidate method; adverse numerical controls
retained**.

The restarted locally optimal block tracker, the independent zero-target
harmonic Golub--Kahan tracker, and their dense-free comparison were evaluated
through `benchmarks/calibrate_restarted_smallest_singular.jl` on ten
deterministic dense-oracle cases. The emitted schema is
`smallest-singular-cross-backend-calibration-v2`; all expected relations
matched.

For the restarted tracker the relations were:

- four ordinary dense agreements: separated diagonal, clustered smallest pair,
  rotated planted spectrum, and a rectangular right nullspace;
- two agreements with a deliberately non-unique dense target subspace: a
  repeated smallest singular value when requesting one direction, and the zero
  operator;
- two expected unconverged results: an insufficient one-iteration budget and
  the badly scaled full-rank matrix `diag(1e8, 1, 1e-8)`; and
- one expected false-convergence control on the 6-by-6 Hilbert matrix; and
- one numerically unresolved dense target for the rotated planted nullspace,
  whose computed dense singular values are below the Float64 resolution floor
  implied by the full spectrum.

The Hilbert result is the most important outcome. The normal-residual and
successive-subspace policy converged to a stationary candidate near `3.62e-6`,
while dense SVD reported a smallest singular value near `1.08e-7`. The
target-local value error exceeds the declared oracle comparison tolerance.
Thus internal convergence is demonstrably insufficient to claim
smallest-singular coverage. The public report preserves this as
`singular_value_disagreement`.

The harmonic tracker has five ordinary agreements, two non-unique-subspace
agreements, one intentionally unconverged insufficient-budget result, and two
numerically unresolved dense targets. Most importantly, its two-step,
thick-restarted Hilbert run reaches the dense value near `1.08e-7`, turning the
required restarted false-convergence case into an ordinary harmonic agreement.
This is the first measured independent-backend recovery rather than merely a
second implementation with the same failure.

The badly scaled control stopped the restarted engine at
`trial_subspace_stagnation` with a candidate
near `2.96e7`, rather than misreporting the dense `1e-8` direction. This is an
honest coverage failure caused by squared-spectrum and finite-precision trial
space loss. The harmonic engine converges under its global-scale residual
policy, but the dense target is explicitly classified as numerically
unresolved instead of agreement. This is scaling evidence, not validation of
the harmonic value.

The dense-free crosscheck reports seven agreements, the required Hilbert value
disagreement, one restarted-unconverged scaled control, and one
both-unconverged insufficient-budget control. These results qualify the
crosscheck for guarded BMOPF profiling as candidate evidence. They do not
qualify either backend as a rank oracle. Explicit row/column scaling is now
covered below; the remaining calibration expansion is randomized rectangular
and cancellation-induced nonlinear derivatives, a third extraction path, and
BMOPF repeated-point stability.

Regression coverage now includes 46 restarted-oracle assertions, 46
harmonic-oracle assertions, 33 cross-backend assertions, 143 general rank
calibration assertions, and 60 fingerprint/combined-API assertions. The full
extension-environment target passes 1,595 assertions, including the
Ipopt, MadNLP, PowerModels, and 312-assertion staged BMOPFTools adapter blocks.

## 2026-08-11: first BMOPF cross-backend and dense-oracle checkpoints

Status: **development calibration; useful negative and arbitration evidence,
not a physical diagnosis**.

The independent smallest-direction crosscheck was integrated into the guarded
multiconductor smoke path and exercised on grounded-neutral,
free-neutral-return, delta-load, unbalanced-line, and wye-delta-transformer
fixtures. Dense work was disabled, candidate dimension was two, and the work
policy used 100 restarted iterations plus 10 harmonic cycles of six steps.
All five product paths were available at both the BMOPF completed-start point
and the explicit zero probe. Four fixtures had both engines unconverged; only
the transformer's restarted engine converged. The relation classes were
identical across the two point policies. This is stable coverage failure, not
evidence that the points have the same low-singular geometry.

A fixed-revision two-fixture work-budget comparison increased the restarted
budget from 100 to 500 and the harmonic budget from 6-by-10 to 8-by-50. It
passed environment, point, fixture, dimension, and distinct-policy gates. The
harmonic engine gained convergence on both fixtures, while the restarted engine
gained none. Grounded-neutral changed from `both_unconverged` to
`restarted_unconverged`. The transformer changed from
`harmonic_unconverged` to `singular_value_disagreement`; its converged candidate
values differed by roughly 99.9 percent and its minimum cross-backend principal
cosine was approximately 0.20. Internal convergence therefore remains
insufficient for coverage.

Guarded dense SVD then arbitrated the two small matrices (1,972 and 2,754 dense
entries). Grounded-neutral was full column rank, 34 of 34, with a repeated
smallest singular value near `0.0180344057874866`. The harmonic backend matched
both values to about `1e-11` relative error and had essentially unit subspace
alignment. The restarted backend remained unconverged; its two dense-relative
errors were approximately `0.026` and `9.40`. This is a positive harmonic case
and a measured restarted miss.

The transformer Jacobian had 51 rows, 54 columns, and estimated rank 48. Its
right nullity under the dense threshold is therefore six, while rectangularity
alone guarantees at least three. The original dimension-two request was below
that structural lower bound and sampled a non-unique part of the zero target
space. Both engines were consistent with the first two exact dense zeros under
the declared global tolerance, despite poor mutual subspace alignment. This
motivated the new structural candidate-dimension guard.

Repeating the transformer at dimension six exposed a harder boundary. Dense
SVD returned `0, 0, 0, 3.53e-15, 3.87e-13, 4.02e-12`; the last three targets are
below the Float64 spectrum-resolution floor for this matrix. Both finite-search
engines reported internal convergence, but restarted candidate values were
roughly `0.038`--`0.376` and harmonic values roughly `9e-6`--`1.4e-4`.
Accordingly both guarded oracle comparisons classified the dense target as
numerically unresolved rather than agreement or disagreement. The rank-48
screen is tolerance-local evidence of three additional near dependencies; it
is not yet a trustworthy six-dimensional numerical or physical nullspace.

These checkpoints changed the immediate priority. The scaling intervention is
now recorded below; repeated-point stability and a method that can resolve or
honestly bound clustered near-zero targets on wide matrices remain. The harmonic backend is already useful on the
full-rank grounded case, but neither engine is a general BMOPF rank oracle.
PowerIO/BMOPFTools source-schema warnings also remain active, so no direction
from this campaign receives a physical label.

## 2026-08-11: transformer diagonal-scaling intervention

Status: **controlled numerical intervention; scaling changes search behavior
but does not resolve the dense target**.

The 51-by-54 wye-delta transformer was repeated at the same completed BMOPF
start, candidate dimension six, 500 restarted iterations, 50 harmonic cycles
of eight steps, and the same two-million-entry basis guard. The baseline and
row-column summaries have matching environment and point fingerprints; the
comparison identifies `scaling` as the only numerical-policy difference.

Without scaling, both engines reported internal convergence but disagreed:
restarted values were approximately `0.038`--`0.376`, harmonic values were
approximately `9e-6`--`1.4e-4`, and the minimum principal cosine was `0.016`.
Direct residuals after auditing the same directions against the original
Jacobian were about `7e-7`--`7e-6` for restarted and `2e-10`--`2e-9` for
harmonic.

One-pass row-column scaling used row factors from about `2.48e-5` to `1` and
column factors from about `0.568` to `4.03e4`. It produced a much more aligned
scaled candidate span (minimum principal cosine about `0.990`), but the
restarted engine hit its 500-iteration limit and the final direction still had
a near-unit backend value difference. After mapping candidates back to the
original coordinates, the first four directions from both engines had
roundoff-level direct residuals. The remaining restarted direction reached
about `5.9e-8`; the two remaining harmonic directions reached about `2.1e-12`
and `3.6e-12`.

This is useful algorithm evidence, but not a solved rank problem. Guarded dense
SVD still classified both the unscaled and row-column-scaled six-value targets
as numerically unresolved. Scaling moved the target values and substantially
changed the search metric; it did not make those values directly comparable or
turn the local rank-48 screen into a certificate. The next method-development
step is an extraction path that avoids the squared normal spectrum, followed by
same-point repeats and nearby trusted-point tests. Physical fingerprinting of
the six-dimensional cluster remains premature.

The corresponding artifacts are
`/private/tmp/nlpdiag-bmopf-transformer-scaling-audit-none-v1/summary.json`,
`/private/tmp/nlpdiag-bmopf-transformer-scaling-audit-row_column-v1/summary.json`,
and the comparison and validation records in the latter directory. Validation
reported no errors; remaining warnings concern source-schema readiness and the
intentionally unresolved/inconclusive numerical relations.

## 2026-08-11: transformer sparse-QR nullspace arbitration

Status: **third backend resolves the local six-dimensional numerical subspace
on this representative case; physical interpretation remains blocked**.

The same 51-by-54 wye-delta transformer and completed BMOPF start were analyzed
with rank-revealing SuiteSparseQR in unscaled and one-pass row-column-scaled
coordinates. Both runs estimated rank 48 and right nullity six. Both agreed
with guarded dense SVD on dimension and mapped subspace: minimum principal
cosines were `0.9999999999999999` and `0.9999999999999998`, respectively, and
the dense threshold was not classified as ambiguous. Direct residuals against
the original Jacobian serialized as zero for all six orthonormal directions.

The factor remained modest on this fixture: 232 input nonzeros, 334 unscaled
factor nonzeros (fill ratio about `1.440`), and 338 scaled factor nonzeros (fill
ratio about `1.457`). The controlled comparison found scaling as the only
policy difference, no rank/nullity or dense-relation change, and no residual
change at recorded precision. Campaign validation reported zero errors. Its six
warnings are duplicated source-schema readiness warnings from the two input
summaries; they are unrelated to QR algebra but prevent physical labels for the
six directions.

This result resolves the earlier question of whether the transformer cluster
was merely an artifact of the two iterative normal-product trackers: on this
point, an independent direct sparse factorization and dense SVD recover the same
six-dimensional local numerical nullspace. It does not prove exact rank,
pointwise persistence, or a transformer/neutral/delta physical mechanism. The
next trust gate is repetition at identical and nearby trusted points, followed
by component-coordinate projection of only the persistent directions. The
artifacts are
`/private/tmp/nlpdiag-bmopf-transformer-sparseqr-none-v1/multiconductor-summary.json`
and
`/private/tmp/nlpdiag-bmopf-transformer-sparseqr-row-column-v1/sparse-qr-nullspace-comparison.json`.

## 2026-08-11: transformer persistence and representational explanation

Status: **the six-dimensional nullspace is persistent but is explained by
unused load-current coordinates, not by the declared voltage-port modes**.

The row-column sparse-QR experiment was repeated three times at identical
coordinates and at symmetric deterministic relative radii `1e-8` and `1e-6`.
All seven evaluations returned rank 48 and right nullity six. All 21 pairwise
minimum principal cosines were `1.0`, including every distinct-point pair, and
the maximum direct original-Jacobian residual serialized as zero. This rules
out basis sign/rotation effects and materially weakens a one-point derivative
cancellation explanation over the tested neighborhood.

Basis-invariant coordinate leverage localizes the entire span to six variables:
`crd_ld1_2`, `cid_ld1_2`, `crd_ld2_2`, `cid_ld2_2`, `crd_ld3_2`, and
`cid_ld3_2`. Each contributes one sixth of the nullspace energy. Generic static
analysis independently proves that these variables occur in no objective or
non-domain constraint, and numerical scaling reports identify the same six
zero Jacobian columns. The BMOPF adapter therefore emits
`bmopf_sparse_qr_persistent_nullspace_explained_by_disconnected_variables` and
classifies the mechanism as representational compiled-coordinate freedom.

Eight projected component/topology candidates span six independent voltage
directions, but they do not explain this current-coordinate nullspace: the
maximum candidate residual is `1.0` and the unexplained energy fraction is
approximately `1.0`. This is not a physical contradiction. Physical presence
and absence remain blocked because source fields `vmaxpu` and `vminpu` are not
restored by the current PowerIO-to-BMOPF schema contract. The actionable next
step is to inspect inactive load-terminal current allocation in BMOPFTools and
then rerun the campaign after unused coordinates are removed, fixed, or
explicitly constrained. The final raw artifact is
`/private/tmp/nlpdiag-bmopf-transformer-sparseqr-persistence-v4/wye-delta-transformer.json`.

## 2026-08-11: transformer inactive-coordinate intervention

Status: **the diagnosed right nullspace disappears after correcting the
BMOPFTools two-terminal load-current allocation**.

The persistence/localization evidence identified a precise construction seam:
each phase-to-phase `SINGLE_PHASE` load declared two complex current
coordinates, while its constitutive equations and KCL used only the first.
BMOPFTools now declares one complex branch current for this topology, and its
result writer uses the same two-terminal voltage difference. NLPDiagnostics
represents the branch current with terminal incidence `[+1, -1]` and the
corresponding least-squares terminal-to-model map `[0.5, -0.5]`; the port
contract therefore retains both physical terminals without inventing a second
model coordinate.

The controlled rerun reduced the staged transformer from 54 to 48 variables
while retaining 51 scalar constraint rows. Sparse QR returned rank 48 and right
nullity zero at all three identical-coordinate repeats and all four symmetric
nearby probes. Guarded dense SVD agreed with the no-nullspace result. The six
static `disconnected_variable` findings and the six zero-Jacobian columns both
disappeared. All twelve current ports remained dimensionally aligned; the six
single-phase load real/imaginary maps now have one model row, two terminal
columns, and rank one.

This is a useful end-to-end diagnostic result: repeated numerical geometry
localized a formulation artifact, independent static evidence explained it,
and a narrow model-construction correction removed exactly the predicted six
degrees of freedom without changing the equation count. It is not evidence
that every remaining physical mode declaration is absent. `vmaxpu` and
`vminpu` are still lost at the PowerIO/BMOPF schema boundary, so physical
presence/absence labels remain blocked. The post-intervention artifacts are
`/private/tmp/nlpdiag-bmopf-transformer-sparseqr-persistence-v5/wye-delta-transformer.json`,
`multiconductor-summary.json`, and `validation.json` in the same directory.

## 2026-08-11: five-fixture persistence and initialization baseline

Status: **local rank evidence is stable; initialization and source-schema
readiness, rather than right-nullspace degeneracy, are the immediate observed
boundaries**.

The same unscaled sparse-QR policy was applied to grounded-neutral,
free-neutral-return, delta-load, ZIP-load, and unbalanced-three-phase-line at
the BMOPFTools start completed with zeros. Each case used three identical-point
evaluations and four symmetric nearby probes at relative radii `1e-8` and
`1e-6`. All five completed under the 250,000-entry dense guard.

Every case was full column rank in all seven evaluations. The dimensions and
ranks were 58-by-34/34, 58-by-34/34, 62-by-38/38, 80-by-44/44, and
62-by-38/38, respectively. Guarded dense SVD agreed with sparse QR on zero
right nullity in every case, and sparse-factor residuals were between roughly
`8.15e-17` and `9.80e-17`. The recorded sparse-QR condition proxies ranged
from about `2.67` to `83.92`; these are moderate local factorization screens,
not condition-number certificates. No evaluation, derivative, or expression
numeric-risk issue was recorded at these points.

The numerical report's eight zero-Jacobian rows per fixture were also
crosschecked against local activity. All 40 rows are inactive; none enters the
selected active set. Direct model inspection identifies them as current-
magnitude quadratic inequalities of the form
`a * (current_real^2 + current_imag^2) <= 1`, evaluated at the zero-current
completion. Their gradients therefore vanish at the center while they retain
unit slack. They are not active-set singularities. The paired duplicate-limit
rows remain a separate static redundancy observation and may still be worth
deduplicating for formulation economy.

Initialization is the recurring adverse pattern. BMOPFTools supplied a partial
voltage start and the campaign filled all missing current coordinates with
zero. All five starts violated constraints: 31 violations in total. Maximum
violations were `0.015`, `0.015`, `0.02`, `1.0`, and `0.02` in the fixture
order above. ZIP is therefore the clearest next initialization calibration
case. Its order-one violation should not be confused with ill-conditioning or
rank deficiency; it is evidence about the completed start.

All cases also report locally tangent-not-observed declared source common-mode
candidates. That absence is not yet physical evidence because PowerIO/BMOPF
restoration still drops fields including `vminpu`, `vmaxpu`, `kv`, `phases`,
and voltage-source metadata. Campaign validation has no errors and four
warnings: infeasible initialization plus the three source-schema readiness
warnings. Artifacts are under
`/private/tmp/nlpdiag-bmopf-five-fixture-persistence-v1`.

The new formulation-intervention artifact was also exercised on the historical
transformer pre/post summaries. It records the exact expected delta: six fewer
variables, unchanged row count and rank, six fewer persistent right-nullspace
dimensions, six fewer disconnected coordinates, and dense-SVD corroboration.
It correctly withholds controlled/causal readiness because the historical
baseline used row-column scaling while the candidate used no scaling, and the
old summaries predate BMOPFTools source-state provenance. The evidence remains
strong local diagnosis, but a publication-grade causal artifact requires two
policy-matched runs from isolated source revisions.

## 2026-08-11: five-fixture feasible-point calibration

Status: **matched local point-policy evidence; physical interpretation remains
schema-blocked**.

The grounded-neutral, free-neutral-return, delta-load, ZIP-load, and
unbalanced-three-phase-line fixtures were rerun under identical source,
numerical, dense-budget, repeat, and nearby-probe policies. The baseline used
BMOPFTools' partial voltage start with explicit zero completion. The candidate
attached Ipopt to the same objective-free feasibility formulation, initialized
it from that completed start, and extracted the public solver-result point.
The environment fingerprints match.

All five solves terminated `LOCALLY_SOLVED` with public primal status
`FEASIBLE_POINT`. The baseline had 31 feasibility violations in total; the
candidate had none. Maximum violation changed from `0.015`, `0.015`, `0.02`,
`1.0`, and `0.02` to zero for grounded-neutral, free-neutral-return,
delta-load, ZIP-load, and the unbalanced line, respectively. This confirms that
the ZIP order-one observation was a completed-start pathology rather than
evidence of rank deficiency.

Sparse QR reported ranks 34, 34, 38, 44, and 38 with zero right nullity at the
solved points. Guarded dense SVD agreed in all five cases. Three identical-point
repeats and four symmetric nearby probes per fixture retained the same rank and
nullity. Rank did not change between completed-start and solved points. No
active or inactive zero-Jacobian rows remained at the solved points; the eight
inactive stationary current-limit rows seen per fixture at zero current were
therefore point-local derivative geometry, not structural zero rows.

The unscaled sparse-QR condition proxy changed from approximately `83.92` to
`83.89` (grounded neutral), `2.67` to `4.31` (free neutral), `11.08` to `11.31`
(delta), `10.36` to `12.10` (ZIP), and `12.43` to `16.53` (unbalanced line).
These shifts show that the proxy is meaningfully operating-point dependent.
They do not establish condition numbers or solver difficulty, and the absolute
values must not be compared across formulations as physical scaling scores.

The matched comparison passed its point, environment, port-map, mode-policy,
numerical-profile, feasibility-profile, and solved-point readiness gates. The
campaign validator reports only the expected infeasible-baseline warning and
duplicated source-schema warnings. Physical presence/absence conclusions remain
blocked because `vminpu` and `vmaxpu` are not preserved across the current
PowerIO/BMOPF boundary. Artifacts are under
`/private/tmp/nlpdiag-bmopf-five-fixture-start-v2` and
`/private/tmp/nlpdiag-bmopf-five-fixture-ipopt-result-v1`.

## 2026-08-11: source-behavior contract and stationary-row calibration

Status: **source-fidelity gate cleared on the five small fixtures; production
constraints remain unchanged**.

The source-schema trace established that PowerIO/BMOPFTools already retained
OpenDSS `vminpu` and `vmaxpu` values as normalized per-load behavior
observations. They are load-law domain thresholds, not bus voltage bounds. The
mapping ledger now records both fields as `mapped_with_contract`, targets the
preserved source-behavior record, and explicitly states
`active_in_original_model=false`. Raw conversion warnings remain in provenance
but no longer generate physical-metadata-loss findings when an explicit mapping
or behavior contract covers the affected field.

The matched five-fixture campaigns were repeated from the corrected source
tree. Every fixture mapped `angle`, `basekv`, `kv`, `model`, `phases`,
`vminpu`, and `vmaxpu`; the ZIP fixture additionally mapped `zipv`. There were
no unresolved blocking fields and zero physical-metadata warnings. Both
`source_schema_mapping_complete` and `physical_metadata_complete` are true.
Campaign validation contains zero errors and one warning, which is solely the
known infeasible completed-start baseline. Accounted raw source warnings are
retained as information.

The new generic stationary-quadratic classifier independently recognized all
40 zero-Jacobian rows at the completed starts as inactive positive-diagonal
quadratic rows—eight per fixture. None was active or violated. At the five
feasible Ipopt result points, all 40 stationary classifications disappeared.
The matched comparison records elimination in every fixture. The classifier
uses the actual coefficients and scalar level and reports the inferred radius;
it does not assume a right-hand side near one.

Artifacts are under `/private/tmp/nlpdiag-bmopf-five-fixture-start-v3` and
`/private/tmp/nlpdiag-bmopf-five-fixture-ipopt-result-v2`.

## 2026-08-11: seeded rank oracles and first sparse-only 99-bus profiles

The deterministic randomized corpus contains 27 records over seeds 11, 29,
and 47. Eighteen hard controls cover tall full-column-rank matrices, wide
matrices with planted right nullity three, twenty-decade diagonal scaling,
row-column equilibration, and a nonlinear cancellation Jacobian at and near
its rank-changing point. Dense SVD and SuiteSparseQR matched every hard
expectation.

The remaining nine records plant singular values around three explicit
relative thresholds. Four produce different dense-SVD and sparse-QR ranks
under the same nominal tolerance. These are successful adverse controls: QR
pivots and singular values have different finite-precision semantics, so a
clustered threshold does not define a unique backend-independent numerical
rank. The artifact is
`/private/tmp/nlpdiag-randomized-rank-oracles.json`.

The first medium sparse-only campaign profiled one 99-bus LN and one 99-bus LG
snapshot at mapped SI saved-result points. Each staged Jacobian has 2,208 rows,
1,968 columns, 12,886 stored nonzeros, and 4,345,344 possible dense entries.
Dense rank was disabled. Both unscaled and row-column-scaled SuiteSparseQR
retained all 1,968 columns. The unscaled factors contained 25,572 nonzeros for
LN and 25,605 for LG, with fill ratios 1.984 and 1.987. The corresponding
retained-pivot spread proxies were 183.1 and 37.6.

The strongest preliminary contrast is row scaling: the LN positive row norms
span approximately `3.55e9`, versus `6.28e7` for LG. This is a local numerical
observation, not a condition number or explanation of solver behavior. Both
profiles still contain 96 central-finite-difference rows, BMOPFTools withholds
an unqualified differentiability claim, and the result files contain 784
`cr_to`/`ci_to` records that do not correspond to independent staged-model
coordinates. All 1,968 registered model coordinates were nevertheless mapped
without fallback. Artifacts are under
`/private/tmp/nlpdiag-bmopf-99bus-sparse-v1`.

## 2026-08-11: crosschecked multi-time 99-bus profiles

Six fresh-process profiles covered 99-bus LN and LG snapshots at t01, t12, and
t24 using mapped SI saved results. Every case mapped all 1,968 staged
coordinates without fallback. Each result also contained 784 `cr_to`/`ci_to`
records; these are now retained under the declared derived line-to-current
projection contract rather than reported as unresolved model coordinates.

All 96 central-finite-difference rows per case were selected by provenance and
tested in three deterministic dense directions. The 1,728 total row-direction
comparisons had zero mismatches and zero domain-limited evaluations. This
supports use of the assembled Jacobians for the present local rank/scaling
comparison, while not proving differentiability away from the tested points.

Unscaled and row/column-scaled SuiteSparseQR both retained all 1,968 columns in
all six cases. Fill ratios stayed between 1.984 and 1.994. Unscaled
retained-pivot spread proxies varied strongly with time: LN was approximately
183, 5,327, and 902; LG was approximately 37.6, 5,300, and 900. After
row/column scaling, all six proxies lay between 22.48 and 25.02. The stable
scaled range and invariant rank are evidence for strong coordinate-scale
sensitivity, not a time-varying structural degeneracy. The generic
large-row-spread finding appeared at t01 but not t12/t24, so the midday proxy
spike cannot be explained solely by the global row-norm ratio; family and pivot
attribution is the next diagnostic step.

Each isolated child completed inside the 600-second and 4-GiB RSS budgets.
Peak observed RSS ranged from about 2.60 to 2.69 GiB, which is acceptable for
this bounded experiment but too high to extrapolate casually to 538-bus
profiles. BMOPFTools retained four exact qualifications per case, including
nonconvex/local-solution semantics, absence of LICQ/KKT/second-order
certification, active-set locality for 288 inequalities, and
`OPTIMIZE_NOT_CALLED` on the reconstructed staged model.

Artifacts are under `/private/tmp/nlpdiag-bmopf-99bus-multitime-v2`; the
consolidated gate record is `medium_profile_summary.json`.

## 2026-08-12: objective-bearing BMOPF magnitude scaling (pre-correction)

This section records the original campaign for provenance. Its transformer
native-start stratum predates the initialization-covariance correction below;
use the corrected full cross-solver matrix for current quantitative results.

The first start-stratified magnitude-only campaign completed 120 Ipopt solves:
two compact objective-bearing case classes, four policies, three physical-start
strata, and five fresh models per cell. Every stratum independently passed
common-start physical covariance, intervention classification, semantic
row/column geometry, objective-bearing endpoint covariance, physical KKT
acceptance, stable provenance, and matched comparison coverage. All solves were
locally optimal and none entered restoration.

Across 15 observations per policy/case, callback-record ranges were 12--13
(classic), 11--12 (lower local bases), 13--14 (aggressive high bases), and 18
(SI) for the unbalanced three-phase fixture. The wye-delta transformer ranges
were 17--18, 15--16, 18--25, and 19--21. Replicates within each start stratum
were identical at the captured-work level; the ranges are therefore caused by
the start strata, not process noise.

The result supports three bounded conclusions: SI scaling is numerically poor
on these fixtures; moderate local bases are promising; and aggressive bases
can interact strongly with initialization through transformer equations. It
also falsifies the idea that minimizing one global initial-Jacobian condition
proxy is sufficient: the lower local-base transformer policy did less solver
work despite a worse proxy than classic. This motivates family-resolved and
trace-resolved scaling objectives.

The reproducible artifact is
`work/bmopf-stratified-scaling-campaign.json`. It is a local ignored research
artifact (about 55 MiB), not a source-controlled golden file. The runner also
writes a compact summary beside it (about 62 KiB) without discarding the full
evidence record.

## 2026-08-12: trace-resolved transformer mechanism pilot

A bounded 16-solve campaign added eight event-preserving Jacobian-family
snapshots to each Ipopt trace: four magnitude policies, native and seed-11
physical starts, and two fresh replicates. All trace interpretations qualified
with complete BMOPFTools row/column registry coverage. The work ranges were
16 records for the lower local bases, 17--18 for classic, 18--22 for the
aggressive high bases, and 21 for SI.

SI's selected transformer current-coupling column spread reached about 6,351,
and its voltage-column median moved from 1 to about 19.6, while the apparent
power-circle rows remained around `1e-5`. The aggressive high-base policy
instead concentrated growth in transformer-coil power columns; its selected
reactive-power spread reached about 17.6. At the perturbed start, positive
Ipopt regularization appeared twice for classic (maximum about 267) and twice
for the aggressive policy (maximum about 26,667), but not for the lower-base
or SI policies. The absence of regularization did not prevent SI from taking
more iterations, so these mechanisms must remain separate evidence channels.

Ipopt's public callback exposes no factorization count/time, inertia, pivot,
fill, or backward-error statistics. The artifact records that absence and
labels regularization as a proxy. MadNLP's callback does expose cumulative
linear-solver time, factorization/backsolve counts, and evaluation counts; the
adapter's monotonicity and coverage contracts are regression-tested; the full
default MadNLP BMOPF campaign remains outstanding.

## 2026-08-12: first MadNLP scaling-portability pilot

The solver-parametric runner completed 16 transformer solves with MadNLP: four
policies, native and seed-11 physical starts, and two fresh replicates. Every
stratum campaign qualified, all endpoints passed the same physical KKT
contract, and callback work was deterministic within each policy/start cell.
Record ranges were 16--17 for classic, 16--17 for the lower local bases,
19--21 for the aggressive high bases, and 20 for SI.

MadNLP's cumulative callback counters were complete and monotone. On native
first replicates the policies used 16, 17, 19, and 20 factorizations in the
same order. On the perturbed start, classic used 23 factorizations for 17
callback rows and the aggressive policy 33 for 21; their maximum
regularizations were about 267 and 71,111. Lower-base used 16 factorizations
and SI 20 without positive regularization. This confirms that callback count,
regularization, and factorization work are distinct measures. The reported
linear-solver times were below one millisecond and are not stable enough for a
performance conclusion on this small fixture.

Artifacts are `work/bmopf-madnlp-portability-pilot.json` and its compact
`-summary.json` companion. The bounded pilot is not a substitute for the
default five-repeat, three-stratum, two-case protocol.

## 2026-08-12: initialization scaling covariance

The native-start audit found a cross-voltage-level bug in the BMOPFTools OPF
warm start: the source voltage magnitude was used at every bus, so the SI
wye-delta fixture placed its nominal 415 V side near 6.35 kV. The per-unit
models concealed much of this because their transformed levels were near order
one. BMOPFTools now uses level-aware nominal magnitudes plus its existing
wye/delta phase propagation. Native SI, classic, and local-base starts agree in
physical coordinates to roughly `3.4e-13` on both retained fixtures.

With the correction, the bounded Ipopt transformer ranges improved to
13--14/14--15/16--18/19--21 records for
moderate/classic/aggressive/SI. MadNLP changed to
13--14/13--15/15--18/19--22. The exact small-sample ranges should not be
overinterpreted, but two conclusions survive: physical initialization is a
material experimental control, and SI/aggressive policies remain worse after
that control is repaired.

The corrected pilot artifacts are
`work/bmopf-invariant-start-ipopt-pilot.json` and
`work/bmopf-invariant-start-madnlp-pilot.json`, each with a compact summary.

## 2026-08-12: corrected full cross-solver scaling matrix

The initialization-covariance fix has now been exercised on the full matched
protocol for both Ipopt and MadNLP: two compact objective-bearing cases, four
magnitude policies, one native and two deterministically perturbed physical
start strata, and five fresh replicates per cell. All 240 solves terminated
locally optimally. Every native-initialization covariance, transported-start
covariance, physical endpoint, provenance, and comparison-coverage gate passed.

Callback-record ranges were:

| Solver / case | Classic | Moderate local | Aggressive local | SI |
| --- | ---: | ---: | ---: | ---: |
| Ipopt, unbalanced 3-phase | 12--13 | 11--12 | 13--14 | 18 |
| Ipopt, wye-delta transformer | 14--15 | 13--14 | 16--26 | 19--21 |
| MadNLP, unbalanced 3-phase | 12--13 | 11--12 | 13--14 | 17--18 |
| MadNLP, wye-delta transformer | 13--15 | 13--14 | 15--26 | 19--22 |

The MadNLP factorization ranges add evidence that callback counts alone hide
important work. On the transformer they were 13--21 (classic), 13--14
(moderate), 15--39 (aggressive), and 19--22 (SI). Backsolve ranges were
14--15, exactly 14, 17--30, and 19--22 respectively. Sub-millisecond linear
solver times are retained but remain too small for timing claims.

These results support a bounded, cross-solver conclusion: the scaling signal
survives physically invariant initialization, moderate local bases are the
best candidate among the four tested policies, raw SI coordinates are
consistently costly, and aggressive bases are not robust to start perturbation
on transformer equations. They do not establish universal policy superiority
or a causal mechanism inside either factorization.

The corrected full artifacts are
`work/bmopf-stratified-ipopt-invariant-start-scaling-campaign.json` and
`work/bmopf-stratified-madnlp-scaling-campaign.json`, each with a compact
`-summary.json` companion.

## 2026-08-12: compositional transformer initialization qualification

A chained Yd/Dy fixture with a nonzero source angle now verifies generated
phasors from SI and classic per-unit coordinates against the same ideal winding
relations. Both engine transports report maximum normalized physics residuals
of approximately `1.6e-12`, and the complete NLPDiagnostics initialization
covariance gate passes for physical coordinates, constraint functions and sets,
residuals, and Jacobian.

The first run was correctly withheld: 12 dynamically created transformer
coil-power variables were not yet present in the public registry before KCL
finalization, so the semantic covariance map was incomplete. Publishing those
variables immediately after device-physics construction fixed the evidence
contract; no numerical tolerance was relaxed. This is an instrumentation
result, not evidence that either scaling policy is superior.

BMOPFTools' focused transformer-start suite now exercises actual-parent-phase
single-phase laterals, centre-tap polarity, chained Yd/Dy phase shifts,
n-winding `delta_roll`, and SI/per-unit physical covariance. Zigzag is recorded
as unsupported because no schema-level connection matrix yet exists.

## 2026-08-12: qualified MadNLP P/V base-allocation mechanism

The three-zone, three-converter `2^4` MadNLP campaign has been rerun with an
explicit fixed-variable multiplier representative. The public solver
multipliers remain retained and fail stationarity on fixed source-voltage
coordinates. Completing only 13 scalar fixed-equality multipliers reduces the
maximum residual from about `1.5` to `5.6e-8`; the free-coordinate residual was
already at that scale. This is evidence about a valid alternative KKT
representative, not about multiplier uniqueness or MadNLP's internal
elimination semantics.

Both P/V start strata now qualify. All 68 fresh solves terminate locally
optimally, all public/completed multiplier pairs are retained, all completed
representatives pass the physical endpoint gate, and all linear-work and
factorial geometry responses are complete. Raising only the AC-zone-2 base has
the clearest cross-start direction: mean factorization effects are `-2.25` and
`-1.625`, backsolve effects are `-1.25` and `-3.0`, and Jacobian/Hessian
evaluation effects are `-1.25` and `-2.5`. The sub-millisecond time effects
share the sign but are not used as performance evidence.

Droop sharing remains unqualified. The native stratum has 30 accepted endpoints
plus two local-infeasibility and two iteration-limit results; the perturbed
stratum has 26 accepted endpoints plus four of each failure class. Multiplier
completion is available for the solved endpoints but does not alter
termination. No factorial contrast spanning those mixed endpoint classes is a
scaling claim.

The bounded real-feeder matrix described here is now complete for the first
30-bus LN case; the result and its remaining limits are recorded below.

## 2026-08-22: qualified 30-bus LN feeder scaling interaction

The feeder-embedded runner completed the first bounded 30-bus LN case with
classic, all-low, AC-zone-2-high-only, all-high, and interaction-control
policies. Both native and deterministically perturbed physical-start strata
were run with fresh Ipopt and MadNLP replicates. Every endpoint, covariance,
repeatability, sparse-work, provenance, and solver-attribution gate passed;
dense decomposition remained disabled.

Relative to the all-low anchor, AC-zone-2-high-only reduced Ipopt callback
records and line-search trials at the native start, and reduced MadNLP callback
records, backsolves, and derivative evaluations with unchanged factorization
count. At the perturbed start the direction reversed: Ipopt required 58 more
records, 243 more line-search trials, and 24 positive-regularization records;
MadNLP required 64 more records, 108 more factorizations, 205 more backsolves,
and 64 more Jacobian/Hessian evaluations. All endpoints still passed the
physical acceptance contract.

This is evidence of a scaling--initialization interaction, not evidence that a
high or low AC-zone base is universally better. The changing families are
currently localized to DC branch thermal and IBR power-circle rows, with
`q_ibr`, `p_ibr`, and DC branch-current columns prominent. More intermediate
trace points and perturbation directions are required before assigning
causality. The held-out 30-bus LG follow-up is recorded below; 99-bus
promotion remains premature.

## 2026-08-22: held-out 30-bus LG feeder confirms start sensitivity

The same bounded runner and five-policy contract completed the held-out
`30bus_LG_t01_0800` feeder for Ipopt and MadNLP. Native and one deterministic
nearby-start stratum each used two fresh repeats per policy. All 20 runs per
solver passed endpoint acceptance, covariance, repeatability, provenance,
sparse-work, and solver-attribution gates; the dense decomposition budget
remained zero. The fixture has 756 variables, 925 constraints, 7,335 stored
Jacobian entries, and an 880,200-entry trace-evaluation upper bound.

Relative to the all-low anchor, AC-zone-2-high-only is favorable at the native
start: Ipopt changes from 25 to 21 callback records and from 27 to 22
line-search trials; MadNLP changes from 28 to 23 records, 31 to 25
factorizations, 32 to 27 backsolves, and 28 to 23 Jacobian evaluations. At the
nearby start the direction reverses: Ipopt changes from 28 to 86 records, 34
to 277 line-search trials, and 0 to 24 positive-regularization records;
MadNLP changes from 35 to 94 records, 35 to 137 factorizations, 42 to 161
backsolves, and 35 to 94 Jacobian evaluations. Every endpoint remains
physically accepted.

This held-out topology therefore reproduces the qualified LN conclusion:
the observed effect is a scaling--initialization interaction, not a universal
base-selection rule. The result still has one perturbation direction and one
30-bus topology; more directions, intermediate Ipopt trace points, and the
phase-only orthogonal control are required before mechanism or 99-bus claims.
The compact machine-readable extract is tracked at
`docs/calibration_summary.json`; the full run and its summary remain in the
local review artifact directory. This held-out run used Julia 1.12.6 with a
temporary copy of the known benchmark environment and BMOPFTools
`8f121216065bcd692f18444836c7c80149e5cf4a` (the current research checkout does
not yet expose the `OpfScaling` API required by this runner); the dependency
revision is recorded in the summary fingerprint.

## 2026-08-22: second LG perturbation direction resolves Ipopt trajectory families

The held-out LG protocol was repeated for a second deterministic perturbation
seed (`17`) with Ipopt, two fresh repeats per policy, and twelve selected trace
points. All endpoint, covariance, repeatability, provenance, sparse-work, and
trace-attribution gates passed. Relative to the all-low anchor, the
AC-zone-2-high-only policy changed from 29 to 46 callback records, 38 to 64
line-search trials, and 0 to 18 positive-regularization records. The first
perturbation direction (seed `11`) changed those quantities from 28 to 86,
34 to 277, and 0 to 24 respectively. The native-start response remains the
same 25-to-21 records and 27-to-22 line-search reduction.

The second direction repeats the sign reversal without relying on the original
seed. Its selected trajectories repeatedly identify DC branch power/current
thermal and IBR power-circle rows, with `q_ibr`, `p_ibr`, `vi`, `idc_conv`,
`u_ibr`, and `ci_fr` among the largest moving columns. This is qualified
trace-family attribution, not a causal factorization claim; Ipopt does not
expose factorization counts or pivot/fill telemetry. The extension is therefore
still an Ipopt-only perturbation result; MadNLP remains qualified for seed 11.

The compact two-direction record is tracked at
`docs/calibration_perturbation_summary.json`. The next increment is the
phase-only orthogonal control with magnitudes held fixed.

## 2026-08-22: phase-only orthogonal algebraic control

The new `benchmarks/phase_only_orthogonal_control.jl` runner isolates the
phase-like intervention on a four-coordinate, two-block truth fixture. The
declared relation is classified as `phase_only`; covariance and semantic
geometry gates pass with dense decomposition disabled. The reference and
candidate Jacobians retain identical singular values to a maximum absolute
difference of `1.33e-15`, while a nonzero cross-block coupling norm of
`0.883176` remains present after rotation.

This is the required algebraic control: complete orthogonal blocks preserve
the spectrum without erasing coupling. No solver is run by design, and the
result records solver work as unavailable. It therefore establishes neither
electrical phase semantics for arbitrary plugin blocks nor any solver-work or
wall-time effect. A matched Ipopt phase-only campaign with magnitude bases
held fixed is the next empirical step. The compact result is tracked at
`docs/phase_only_control_summary.json`.

## 2026-08-22: matched phase-only Ipopt truth-fixture campaign

The matched `benchmarks/phase_only_ipopt_campaign.jl` protocol now runs two
fresh reference solves and two fresh phase-only solves on the same two-block
quadratic truth fixture. Magnitude bases and objective scale are held fixed;
the candidate rotates only the declared variable and equality blocks. All four
runs terminate `LOCALLY_SOLVED`, and the intervention, endpoint-covariance,
and geometry gates pass.

The reference and phase-only policies each use two callback records, one total
line-search trial, and no positive regularization records per repeat. The
matched work difference is therefore zero for every retained metric on this
fixture. This is a useful negative control: the orthogonal intervention does
not manufacture a solver-work difference when the problem is algebraically
equivalent. It is not evidence of global phase-policy superiority or nonlinear
feeder behavior. The compact result is tracked at
`docs/phase_only_ipopt_campaign_summary.json`; the next phase-only step is a
nonlinear truth fixture with the same fixed-magnitude contract.

## 2026-08-22: nonlinear phase-only Ipopt promotion

The fixed-magnitude phase-only protocol now runs on a nonlinear four-equation
truth fixture containing squared magnitudes, a sine term, and bilinear
coupling. Two fresh reference and two fresh phase-only Ipopt solves all
terminate `LOCALLY_SOLVED`; intervention, endpoint-covariance, and geometry
gates pass.

Both policies use nine callback records, twelve total line-search trials, and
no positive regularization records per repeat. The matched work difference is
zero on this nonlinear fixture as well. This extends the algebraic negative
control without turning it into a universal performance claim. Feeder,
transformer, and controller-rich nonlinear cases remain future work. The
compact result is tracked at
`docs/phase_only_nonlinear_ipopt_campaign_summary.json`.

## 2026-08-22: controller-rich phase-only Ipopt promotion

The fixed-magnitude phase-only protocol now includes a smooth droop-like
active-power/voltage coupling equation. Two fresh reference and two fresh
phase-only Ipopt solves all terminate `LOCALLY_SOLVED`; intervention,
endpoint-covariance, and geometry gates pass.

Both policies use eight callback records, eleven total line-search trials, and
no positive regularization records per repeat. The matched work difference is
zero here as well. This is evidence that the phase-only contract remains a
valid negative control in the presence of controller-like nonlinear coupling,
not evidence about full BMOPF droop semantics or global policy superiority.
The compact result is tracked at
`docs/phase_only_controller_ipopt_campaign_summary.json`.

## 2026-08-22: transformer phase-only Ipopt promotion

The fixed-magnitude protocol now covers a two-winding transformer truth
fixture with nonlinear primary/secondary magnitude equations, a 0.1 turns
ratio, and a 0.18-radian winding phase shift. Two fresh reference and two
fresh phase-only Ipopt solves all terminate `LOCALLY_SOLVED`; intervention,
endpoint-covariance, and geometry gates pass.

The reference uses ten callback records and eleven line-search trials per
repeat. The phase-only policy uses nine records and ten line-search trials,
with no positive regularization in either policy. This is a bounded
transformer association, not a universal recommendation: full connection
matrices, winding-local bases, and wall-time portability remain outside this
fixture. The compact result is tracked at
`docs/phase_only_transformer_ipopt_campaign_summary.json`.

## 2026-08-22: feeder phase-only Ipopt promotion

The fixed-magnitude protocol now covers a three-bus radial feeder truth
fixture with nonlinear voltage-magnitude equations and declared branch-drop
projections. Two fresh reference and two fresh phase-only Ipopt solves all
terminate `LOCALLY_SOLVED`; intervention, endpoint-covariance, and geometry
gates pass.

The reference uses seven callback records and six line-search trials per
repeat. The phase-only policy uses nine records and twelve line-search trials,
with no positive regularization in either policy. The extra work is retained
as a negative control rather than a recommendation: this bounded feeder
fixture does not establish global policy superiority, wall-time portability,
or full network semantics. The compact result is tracked at
`docs/phase_only_feeder_ipopt_campaign_summary.json`.

## 2026-08-23: Read-only local quality baseline

`benchmarks/check_local_quality.jl` now provides a local, non-CI quality
baseline covering whitespace, API-tier/list consistency, JSON schema coverage,
and release-gate shape. The known local run reports `ready=true` without
installing packages or mutating repository artifacts.

## 2026-08-23: Stable API runtime smoke

The Stable-tier contract now has an MOI-only runtime smoke covering model
snapshotting, explicit-point evaluation, solver-neutral analysis, and report
serialization. It does not require Ipopt, MadNLP, or BMOPFTools and makes no
solver-quality claim.

## 2026-08-23: Legacy root-export inventory

The API-tier artifact now includes the complete list of 530 root-only exports,
making the non-Stable legacy tier directly reviewable instead of count-only.
This is compatibility-policy evidence and does not deprecate or remove any
root export.

## 2026-08-23: API stability policy artifact

`docs/api_stability.md` now records the compatibility boundary for the 16-name
Stable facade, the research-only Advanced facade, and legacy root exports. The
policy is mirrored in `docs/api_tier_inventory_summary.json` and does not
promote root-only names or numerical behavior to release-stable status.

## 2026-08-23: Generic report unavailable-reason collection

`report_data` now emits a typed `unavailable_reasons` collection for legacy
`*_available`/`*_reason` metadata pairs and suffix-only
`*_unavailable_reason` fields while preserving the original metadata verbatim.
Focused serializer probes and the local regression suite pass. This is
report-boundary schema evidence, not a capability-availability or solver
quality claim.

## 2026-08-23: Typed solver-dual unavailable boundaries

Solver-dual snapshots, fixed-variable dual completion, and complementarity
reports now preserve their historical `reason` strings while also emitting
typed unavailable records with stable codes, categories, stages, and schema
versions. The solver-dual regression cases pass locally. This is
capability/provenance evidence, not KKT or solver-quality qualification.

## 2026-08-23: Typed solver-telemetry unavailable boundary

Solver linear telemetry now preserves its historical factorization-numerics
`reason` string while also emitting a typed unavailable record with stable code,
category, stage, and schema-version fields. The local regression suite passes;
this is capability-boundary evidence, not factorization telemetry or solver
quality evidence.

## 2026-08-23: Stable API facade contract

The new `NLPDiagnostics.Stable` facade defines a deliberately small
16-export surface for model snapshots, numerical evaluations, solver-neutral
analysis, findings, evidence, and report serialization. The focused facade
contract test passes in the known local benchmark environment. The tier audit
records 544 root exports, 16 Stable exports (15 root overlaps), and 14
Advanced/root overlaps; this is an adoption boundary, not a claim that all
legacy root exports are release-stable.

## 2026-08-23: AC/DC campaign helper migration

The AC/DC base-grid, feeder-policy, multi-converter, and MadNLP
multi-converter campaign writers now use qualified shared
`benchmarks/common.jl` JSON writes, including the feeder checkpoint path. The
consolidation audit now recognizes both imported and qualified helper usage;
the inventory reaches 104 shared-helper runners. All AC/DC campaign files pass
local include/syntax checks. A bounded AC/DC scaling launch reaches the known
active BMOPFTools `OpfScaling` contract boundary (`UndefVarError`), so no AC/DC
scaling or solver qualification was promoted.

## 2026-08-23: Stratified scaling campaign helper migration

The magnitude-scaling, objective-bearing stratified-scaling, and MadNLP
stratified campaign writers now use the shared `benchmarks/common.jl` JSON
writer for their full and compact artifacts. All three scripts pass local
include/syntax checks. A bounded magnitude-campaign launch reaches the known
active BMOPFTools `OpfScaling` contract boundary (`UndefVarError`), so no
scaling or solver qualification was promoted. This is consolidation and
dependency-boundary evidence only.

## 2026-08-23: Perturbation-repeat launcher helper migration

The repeated BMOPF perturbation launcher now uses the shared
`benchmarks/common.jl` JSON writer for its repeat manifest. A bounded
single-replicate run completed the parent orchestration and summary steps for
one 30-bus LN matrix launch with status `ok`; the child matrix retained an
explicit `process_exit` record from the sandboxed Julia precompile-lock
permission boundary. This validates repeat-level provenance and failure
preservation, but it is process-environment evidence rather than solver-matrix
qualification.

## 2026-08-23: Solver-option sweep helper migration

The solver-option sweep now uses the shared `benchmarks/common.jl` JSON writer
for its incremental manifest. A bounded baseline configuration completed one
30-bus LN case with two Ipopt iterations and status `ok`; trace profiling was
intentionally skipped by the selected stage. This is controlled option-harness
evidence, not a solver-policy ranking.

## 2026-08-23: Tangent-policy calibration launcher helper migration

The paired tangent-policy calibration launcher now uses the shared
`benchmarks/common.jl` JSON writer for its manifest. A bounded `delta-load`
zero-probe campaign completed under `none` and `fixed` policies; environment,
point-policy, free-coordinate-policy, and paired-case compatibility all
passed. Dense rank was intentionally unavailable at budget 0, so no
non-qualifying comparison was promoted.

## 2026-08-23: Source-preserving solver-matrix helper migration

The source-preserving DSS solver matrix now uses the shared
`benchmarks/common.jl` JSON writer for its matrix manifest. A bounded run
completed one `pf_zip_3ph.dss` case at `max_iter=1` with status `ok`,
classification `solver_failure_not_explained_by_source_domain_thresholds`, and
all source-contract, coordinate-alignment, auxiliary-model, derivative,
row-family, and completion readiness gates passing.

## 2026-08-23: Isolated solver-failure launcher hardening

The isolated solver-failure launcher now uses the shared
`benchmarks/common.jl` JSON writer and bounds child-timeout cleanup with a grace
period plus `SIGKILL` fallback. A one-case bounded run wrote durable
`process_timeout` evidence instead of hanging the parent. This is process
telemetry, not a solver-quality claim.

## 2026-08-23: Solver-option perturbation launcher helper migration

The source-preserving solver-option perturbation launcher now uses the shared
`benchmarks/common.jl` JSON writer for atomic manifests. A bounded local run
retained one `runner_error` entry because the selected DSS deck was absent from
the configured BMOPFDraftData root. This is an input-corpus boundary, not an
option-result claim.

## 2026-08-23: Solver-matrix launcher helper migration

The solver-by-snapshot BMOPF matrix launcher now uses the shared
`benchmarks/common.jl` JSON writer for per-solver indexes and incremental matrix
manifests. A bounded local run wrote one Ipopt entry with explicit
`process_exit` status and no timeout because the child hit the sandboxed Julia
precompile-lock permission boundary before loading the trace runner. No
solver-matrix qualification is promoted from this launcher run.

## 2026-08-23: Result-policy matrix launcher helper migration

The saved-result policy-matrix launcher now uses the shared
`benchmarks/common.jl` JSON writer for incremental manifests. A bounded local
run wrote one explicit `process_exit` policy record because its child hit the
sandboxed Julia precompile-lock permission boundary before loading the corpus
runner. No policy qualification is promoted from this launcher run.

## 2026-08-23: Point-calibration launcher helper migration

The repeated BMOPF point-calibration launcher now uses the shared
`benchmarks/common.jl` JSON writer for incremental manifests. A bounded local
run wrote one explicit `process_exit` record because its child hit the sandboxed
Julia precompile-lock permission boundary before loading the corpus runner. No
calibration qualification is promoted from this launcher run.

## 2026-08-23: Benchmark environment helper migration

The read-only benchmark environment preflight now uses the shared
`benchmarks/common.jl` JSON-string serializer. The known environment check
passed with JuMP, Ipopt, and BMOPFTools required; PowerModels, MadNLP, and
PowerIO optional; and the PowerIO C ABI available.

## 2026-08-23: Structural/family omission correlator helper migration

The structural/family omission correlator now uses the shared
`benchmarks/common.jl` JSON writer. A bounded matching-key control joined one
structural row to load and IBR variants, passed all readiness checks, and
retained one endpoint/load-sensitivity co-occurrence with an explicit
non-causal interpretation.

## 2026-08-23: Sparse-QR comparison helper migration

The sparse-QR nullspace comparison now uses the shared
`benchmarks/common.jl` JSON writer. A bounded paired-policy control held the
environment and point policy fixed, varied scaling only, and reported one
available pair with dense calibration available, no rank change, and no
findings. This is harness-level numerical evidence, not corpus qualification.

## 2026-08-23: Isolated solver-trace launcher helper migration

The isolated BMOPF solver-trace launcher now uses the shared
`benchmarks/common.jl` JSON writer for its incremental index writes. A bounded
local launcher run wrote an explicit child `process_exit` record because the
child hit the sandboxed Julia precompile-lock permission boundary before loading
the trace runner. This is environment evidence only; the direct trace runner's
successful local telemetry remains the qualification boundary.

## 2026-08-23: Solver-failure helper migration

The intentionally problematic solver-case harness now uses the shared
`benchmarks/common.jl` JSON writer for per-case records and the aggregate index.
A local Ipopt run completed all four cases and retained observed resource-limit,
infeasible, and numerical-failure categories. These outcomes are diagnostic
telemetry, not solver-quality claims.

## 2026-08-23: Restarted smallest-singular calibration helper migration

The deterministic restarted smallest-singular calibration now uses the shared
`benchmarks/common.jl` JSON writer while retaining its atomic temporary-file
replacement. A local run completed all 10 cases with every expected relation
matched, including agreement, non-unique-subspace, unresolved, and adverse
controls. This is numerical-method calibration evidence, not a rank certificate.

## 2026-08-23: Operator fingerprint helper migration

The deterministic operator/domain fingerprint smoke now uses the shared
`benchmarks/common.jl` JSON writer. A local run completed all six cases and
retained aggregate domain, derivative, rank, and initialization finding codes.
These fingerprints describe numerical and representational risks; they are not
solver or model-quality scores.

## 2026-08-23: Draft-corpus helper migration

The size-aware BMOPF draft-corpus runner now uses the shared
`benchmarks/common.jl` JSON writer for campaign manifests, per-case records,
and the aggregate index. A bounded structural-only run completed both default
30-bus representatives, each with 704 variables, 844 rows, and 265 structural
findings. These are structural observations, not physical or causal claims.

## 2026-08-23: Solver-trace helper migration

The size-guarded BMOPF solver-trace runner now uses the shared
`benchmarks/common.jl` JSON writer for trace records, checkpoints, and the
aggregate index while retaining its strict non-finite-value normalization. A
bounded known-environment run captured one 30-bus LN Ipopt trace with 19 solver
iterations and wrote an `ok_solver_trace_profile_skipped` evidence record. This
is solver-event telemetry evidence, not a physical or causal claim.

## 2026-08-23: Saved-result persistence helper migration

The cross-point BMOPF persistence probe now uses the shared
`benchmarks/common.jl` JSON writer. A bounded known-environment run mapped two
30-bus LN snapshots into one model coordinate space and wrote both mapping and
controller-curve snapshot records. This remains cross-point numerical
persistence evidence; it does not establish a physical cause.

## 2026-08-23: BMOPF smoke helper migration

The bounded BMOPF smoke runner now uses the shared
`benchmarks/common.jl` JSON writer for per-fixture records and the aggregate
index. A known-environment smoke wrote all six fixture records; each retained
an explicit `error` status because default staged starts were incomplete. The
runner's synthetic zero-point policy remains a separate probe boundary, so no
success claim is promoted from this run.

## 2026-08-23: AC/DC scaling campaign helper migration

The objective-bearing AC/DC scaling campaign now uses the shared
`benchmarks/common.jl` JSON writer for both full and compact outputs. Its local
launch is blocked by the active BMOPFTools checkout missing `OpfScaling`, which
is the same dependency-contract gap recorded by the release gate. No campaign
qualification is promoted from this blocked run.

## 2026-08-23: 30-bus IBR directional-probe helper migration

The dominant-current-coordinate `ibr_p_upper` directional probe now uses the
shared `benchmarks/common.jl` JSON writer. A local smoke on one 30-bus LN
snapshot completed without an error and retained the directional-report
availability boundary explicitly. This remains a primal response probe, not a
KKT, conditioning, or causal certificate.

## 2026-08-23: 30-bus physical-KKT probe helper migration

The bounded 30-bus physical-KKT probe now uses the shared
`benchmarks/common.jl` JSON writer. A local smoke on one LN snapshot completed
without an error and evaluated four complementarity tolerances, while keeping
physical-KKT availability and acceptance explicitly separate. This remains a
gate measurement, not a causal solver or formulation diagnosis.

## 2026-08-23: 30-bus IBR budget-matrix helper migration

The `ibr_p_upper` four-budget max-iteration matrix now uses the shared
`benchmarks/common.jl` JSON writer. A local smoke on one 30-bus LN snapshot
completed all four budgets (`10`, `20`, `40`, and `80`) without an error. This
remains controlled solver-behavior evidence, not a claim that a particular
budget is universally appropriate.

## 2026-08-23: 30-bus IBR option-matrix helper migration

The `ibr_p_upper` four-policy Ipopt option matrix now uses the shared
`benchmarks/common.jl` JSON writer. A local smoke on one 30-bus LN snapshot
completed all four policies (`baseline`, `tight_tolerance`,
`monotone_barrier`, and `scaling_none`) without an error. This remains
controlled solver-behavior evidence, not an automatic option recommendation.

## 2026-08-23: 30-bus IBR initialization-matrix helper migration

The `ibr_p_upper` four-policy initialization matrix now uses the shared
`benchmarks/common.jl` JSON writer. A local smoke on one 30-bus LN snapshot
completed all four policies (`none`, `bmopf`, `bmopf_zero_completion`, and
`zero`) without an error. This remains controlled solver-behavior evidence,
not an automatic initialization recommendation.

## 2026-08-23: 30-bus IBR geometry helper migration

The `ibr_p_upper` endpoint-Jacobian geometry audit now uses the shared
`benchmarks/common.jl` JSON writer. A local smoke on one 30-bus LN snapshot
completed without an error and covered 28 target rows. Physical KKT
availability remains separately reported from geometry, preserving the
interpretation boundary.

## 2026-08-23: 30-bus IBR directional-delta helper migration

The `ibr_p_upper` finite-difference directional-delta matrix now uses the
shared `benchmarks/common.jl` JSON writer. A local smoke on one 30-bus LN
snapshot completed without an error, covering 28 target rows with six delta
measures. This remains a primal response audit, not a KKT, conditioning, or
causal certificate.

## 2026-08-23: 30-bus IBR directional-Jacobian helper migration

The `ibr_p_upper` analytic-versus-finite-difference directional Jacobian check
now uses the shared `benchmarks/common.jl` JSON writer. A local smoke on one
30-bus LN snapshot completed without an error, covering 28 target rows with
two directional reports. This remains a primal derivative audit, not a KKT,
conditioning, or causal certificate.

## 2026-08-23: 30-bus IBR sparse-Jacobian helper migration

The `ibr_p_upper` sparse single-column Jacobian audit now uses the shared
`benchmarks/common.jl` JSON writer. A local smoke on one 30-bus LN snapshot
completed without an error, covering 28 target rows and 168 nonzero entries.
This is a primal derivative audit, not a KKT, conditioning, or causal
certificate.

## 2026-08-23: 30-bus IBR row-scaling helper migration

The `ibr_p_upper` row-level model-to-physical scaling audit now uses the
shared `benchmarks/common.jl` JSON writer. A local smoke on one 30-bus LN
snapshot completed without an error and reported zero maximum model-to-
physical slack difference. This is a scaling audit, not a KKT, conditioning,
or causal certificate.

## 2026-08-23: 30-bus IBR bound-regime helper migration

The `ibr_p_upper` bound-regime ledger now uses the shared
`benchmarks/common.jl` JSON writer. A local smoke on one 30-bus LN snapshot
recorded 28 zero-bound rows, with strict complementarity passing 0/28 and
physical gaps around `-9.98e-3`. This remains localization evidence, not a
causal solver or formulation diagnosis.

## 2026-08-23: 30-bus IBR tolerance-margin helper migration

The per-row `ibr_p_upper` tolerance-margin ledger now uses the shared
`benchmarks/common.jl` JSON writer. A local smoke on one 30-bus LN snapshot
reported a required complementarity tolerance of `1.049343932476267e-5`,
sharpening the `1e-5` boundary without turning it into a solver or formulation
causal claim.

## 2026-08-23: real 99-bus tolerance matrix helper migration

The real 99-bus phase-only tolerance/budget matrix now uses the shared
`benchmarks/common.jl` JSON writer and supports bounded case selection for
local smoke runs. The baseline-tolerance smoke produced a report with all six
phase-only runs locally solved, six solver-floor-calibrated acceptances, and
strict physical KKT acceptance of 2/6. This remains tolerance-sensitivity
evidence, not an automatic policy or physical acceptance claim.

## 2026-08-23: real 99-bus structured perturbation matrix helper migration

The real 99-bus phase-only block-structured perturbation matrix now uses the
shared `benchmarks/common.jl` JSON writer and supports bounded case selection
for local smoke runs. The completed-baseline smoke produced a report with all
six phase-only runs locally solved, six solver-floor-calibrated acceptances,
and strict physical KKT acceptance of 2/6. This remains block-perturbation
sensitivity evidence, not a causal or automatic policy claim.

## 2026-08-23: real 99-bus perturbation matrix helper migration

The real 99-bus phase-only bounded-start perturbation matrix now uses the
shared `benchmarks/common.jl` JSON writer and supports bounded case selection
for local smoke runs. The completed-baseline smoke produced a report with all
six phase-only runs locally solved, six solver-floor-calibrated acceptances,
and strict physical KKT acceptance of 2/6. This remains perturbation-sensitivity
evidence, not a causal or automatic policy claim.

## 2026-08-23: real 99-bus option matrix helper migration

The real 99-bus phase-only solver-option matrix now uses the shared
`benchmarks/common.jl` JSON writer and supports bounded case selection for
local smoke runs. The baseline-option smoke produced a report with all six
phase-only runs locally solved, six solver-floor-calibrated acceptances, and
strict physical KKT acceptance of 2/6. This remains option-sensitivity
evidence, not automatic policy selection or physical acceptance.

## 2026-08-23: real 99-bus initialization matrix helper migration

The real 99-bus phase-only initialization matrix now uses the shared
`benchmarks/common.jl` JSON writer. A bounded local smoke selected the
completed-start case and produced a report with all six phase-only runs
locally solved, six solver-floor-calibrated acceptances, and strict physical
KKT acceptance of 2/6. The matrix remains sensitivity evidence, not an
automatic start-policy selection or a physical acceptance claim.

## 2026-08-23: real 99-bus phase-only campaign helper migration

The bounded matched reference/phase-only campaign now uses the shared
`benchmarks/common.jl` JSON writer. Its local smoke run completed all six
snapshot pairs, with six phase-only covariance passes and six solver-floor-
calibrated acceptances. Strict physical KKT acceptance remains 2/6 for both
policies, so the absolute physical gate and solver-campaign release claim
remain open.

## 2026-08-23: real 99-bus readiness helper migration

The real ENWL 99-bus readiness probe now uses the shared
`benchmarks/common.jl` JSON writer. Its local smoke run parsed all six selected
LN/LG snapshots, found all six saved SI results `LOCALLY_SOLVED`, passed the
phase-only semantic-map gate, and confirmed non-mutating model-copy readiness.
The transformed-coordinate solver hook remains unavailable, so this
increment does not promote a real-network solver claim.

## 2026-08-23: feeder phase-only Ipopt campaign helper migration

The matched two-policy, two-replicate feeder phase-only Ipopt campaign now
uses the shared `benchmarks/common.jl` JSON writer. Its local smoke run
classified the intervention as `phase_only`, passed endpoint-covariance and
geometry gates, and reported all four endpoints as `LOCALLY_SOLVED`. This is
bounded feeder-fixture evidence and does not establish full network semantics,
policy superiority, or wall-time portability.

## 2026-08-23: transformer phase-only Ipopt campaign helper migration

The matched two-policy, two-replicate transformer phase-only Ipopt campaign
now uses the shared `benchmarks/common.jl` JSON writer. Its local smoke run
classified the intervention as `phase_only`, passed endpoint-covariance and
geometry gates, and reported all four endpoints as `LOCALLY_SOLVED`. This is
bounded transformer-fixture evidence and does not establish full connection-
matrix semantics, policy superiority, or wall-time portability.

## 2026-08-23: controller-rich phase-only Ipopt campaign helper migration

The matched two-policy, two-replicate controller-rich phase-only Ipopt
campaign now uses the shared `benchmarks/common.jl` JSON writer. Its local
smoke run classified the intervention as `phase_only`, passed endpoint-
covariance and geometry gates, and reported all four endpoints as
`LOCALLY_SOLVED`. The campaign remains a bounded smooth controller fixture,
not a claim about full BMOPF droop-controller semantics or policy superiority.

## 2026-08-23: nonlinear phase-only Ipopt campaign helper migration

The matched two-policy, two-replicate nonlinear phase-only Ipopt campaign now
uses the shared `benchmarks/common.jl` JSON writer. Its local smoke run
classified the intervention as `phase_only`, passed endpoint-covariance and
geometry gates, and reported all four endpoints as `LOCALLY_SOLVED`. This is
bounded fixture evidence and does not establish global policy superiority or
wall-time portability.

## 2026-08-23: matched phase-only Ipopt campaign helper migration

The matched two-policy, two-replicate phase-only Ipopt campaign now uses the
shared `benchmarks/common.jl` JSON writer. Its local smoke run produced four
accepted endpoints, classified the intervention as `phase_only`, and passed
the endpoint-covariance and geometry gates. This remains bounded fixture
evidence and does not establish global policy superiority or wall-time
portability.

## 2026-08-23: phase-only orthogonal control helper migration

The bounded algebraic phase-only control now uses the shared
`benchmarks/common.jl` JSON writer. Its local smoke run classified the
intervention as `phase_only` and passed the covariance, geometry, and
singular-value invariance gates. Solver work remains explicitly withheld by
design, preserving the control's role as a structural and numerical control
rather than a performance campaign.

## 2026-08-23: bounded 99-bus phase-only campaign helper migration

The bounded three-snapshot phase-only 99-bus feeder campaign now uses the
shared `benchmarks/common.jl` JSON writer. Its local smoke run completed all
six Ipopt solves as `LOCALLY_SOLVED`; covariance, geometry, and endpoint gates
passed for light, nominal, and heavy snapshots. The migration preserves the
surrogate-fixture qualification boundaries and does not broaden its network or
policy claims.

## 2026-08-23: phase-only campaign comparison helper migration

The reproducible phase-only campaign comparison now uses the shared
`benchmarks/common.jl` summary reader and JSON writer. Its local smoke run
retains the six campaign rows, six gate-qualified campaigns, five locally
solved campaigns, and five comparable solver-work records. The migration is
consolidation-only: the comparison findings and qualification boundaries are
unchanged.

## 2026-08-22: phase-only campaign comparison

The six tracked phase-only summaries now have a reproducible comparison
report. All six pass their declared intervention, endpoint-covariance, and
geometry gates; five solver campaigns also report locally solved endpoints.
Among the campaigns with matched work records, quadratic, nonlinear, and
controller-rich fixtures are unchanged, the transformer fixture is lower by
one callback record and one line-search trial, and the feeder fixture is higher
by two callback records and six line-search trials. The algebraic control
withholds solver work by design. This contrast is evidence for bounded
fixture-specific behavior, not a policy recommendation. The executable
comparison is `benchmarks/phase_only_campaign_comparison.jl` and the compact
report is tracked at `docs/phase_only_campaign_comparison_summary.json`.

## 2026-08-22: bounded 99-bus snapshot promotion

The fixed-magnitude protocol now has a bounded 99-bus feeder surrogate
campaign with light, nominal, and heavy load-scale snapshots. All six local
Ipopt solves terminate `LOCALLY_SOLVED`; every snapshot passes the
intervention, endpoint-covariance, and geometry gates. Reference and phase-only
policies each use four callback records and three line-search trials per
snapshot, with no work difference.

This is a 99-bus surrogate with declared radial branch-drop projections, not a
claim about a full production feeder model. Full network semantics, wall-time
portability, and automatic-policy safety remain outside the fixture. The
executable protocol is `benchmarks/phase_only_99bus_snapshot_campaign.jl` and
the compact result is tracked at
`docs/phase_only_99bus_snapshot_campaign_summary.json`.

## 2026-08-22: real 99-bus readiness gate

The local BMOPF corpus contains six selected ENWL 99-bus snapshots spanning
three LN and three LG times. All six parse with zero blocking integrity
findings and have saved SI results marked `LOCALLY_SOLVED`. The compatibility
path now consumes the current public `BMOPFTools.opf_semantic_blocks` registry:
the semantic-map probe passes on all six selected LN/LG snapshots, each with
1,968 variables, 2,208 constraints, 936 paired variable blocks, zero skipped
declarations, and a `phase_only` intervention classification. This is a
matrix-wide map contract, not a solver result. The phase-only solver campaign
is still not run on this real network because a transformed-coordinate
BMOPFTools runner has not yet been implemented. The readiness runner now uses
the reusable `bmopf_phase_only_transform_plan` preflight, which records 936
rotated variable blocks per snapshot while explicitly reporting that no solver
transformation was applied. It records file hashes, provenance, and this scope at
`docs/real_99bus_readiness_summary.json`; it does not
substitute surrogate results for the real-network solver claim.
The accompanying rebuild-capability report inventories 96 nonlinear, 432
quadratic, and 1,576 affine constraints, 104 variable-domain constraints, and
a quadratic objective per snapshot; these are the remaining implementation
requirements for a genuine transformed-coordinate solve.
The non-mutating MOI rebuild copy now succeeds for all six snapshots with
1,968 target variables and 2,208 target constraints; it is not yet attached
to an optimizer. Inverse-rotation starts are copied successfully, but the
artifact carries no solver evidence.

## 2026-08-22: real 99-bus transformed-coordinate solver campaign

This section supersedes the readiness-only solver statement above. The bounded
campaign now runs matched reference and phase-only Ipopt solves on all six
selected real ENWL 99-bus snapshots. All twelve solves terminate
`LOCALLY_SOLVED`, with six source endpoints recovered and six phase-only
endpoints rebuilt from complete starts.

The strict physical KKT gate is available on every run but passes only 2/6
reference and 2/6 phase-only endpoints at complementarity tolerance `1e-5`.
The saved failure-localization report shows identical failed-side keys, counts,
and family attribution between reference and phase-only runs: four snapshots
fail only on `ibr_p_upper`, while both t13 snapshots pass. This is localization
evidence, not a formulation or solver-causality diagnosis.

The phase-only covariance gate passes all seven available checks on all six
snapshots, including scalar-set transport, point/objective/residual agreement,
and semantic Jacobian comparison. Physical rank remains unavailable because
dense rank is disabled, and inequality-multiplier covariance remains outside
the covariance report. The machine-readable release-gate ledger is
`docs/calibration_release_gate_summary.json`.

## 2026-08-24: solver-iterate persistence integration

The postmortem path now forwards the nonsmoothness and weak-activity
persistence selectors from `analyze` to `analyze_iteration_points`. The
screens run independently within each captured trace segment, retain iteration
provenance, and expose per-screen segment counters in metadata. Segments with
fewer than the requested minimum number of evaluations are skipped without
manufacturing a persistence claim.

## 2026-08-24: composable analysis policies

`analyze` now accepts additive `RankPolicy`, `ProbePolicy`, and `CheckPolicy`
objects. The policy layer groups dense-rank semantics, opt-in probe selectors,
and top-level boolean checks while preserving the existing keyword interface;
policy provenance is retained in report metadata. This is an API ergonomics
increment and does not change the underlying numerical evidence semantics.

## 2026-08-24: objective-versus-Jacobian scaling screen

The numerical layer now provides an opt-in point-local comparison of finite
objective-gradient magnitude against positive Jacobian column scales. Complete
comparisons emit a summary or mismatch finding; incomplete objective or
Jacobian derivatives emit explicit unavailable evidence. This is a
normalization screen, not a global conditioning or solver-quality claim.

## 2026-08-24: local convexity and curvature screen

The numerical layer now provides `analyze_convexity` and the opt-in
`analyze(...; check_convexity=true)` path. The screen classifies the complete
local Hessian spectrum using positive, negative, and near-zero eigenvalue
counts, while preserving typed unavailable evidence when finite curvature
evidence cannot be formed. The convenience path uses the objective Hessian
with zero constraint multipliers; this is deliberately a point-local
curvature observation rather than a global convexity or second-order
optimality certificate.

## 2026-08-24: local degrees-of-freedom screen

The numerical layer now provides `analyze_degrees_of_freedom` and the opt-in
`analyze(...; check_degrees_of_freedom=true)` path. It compares structural
equality matching with observed local Jacobian right-nullity and records both
counts, rank, row/variable scope, and typed unavailable evidence. The result
is explicitly limited to the aligned equality view at one point; it is not a
global feasible-set dimension or physical-gauge classification.

## 2026-08-24: nonsmoothness and weak-activity screens

The numerical layer now provides opt-in `analyze_nonsmoothness` and
`analyze_weak_activity` paths. The nonsmoothness screen aggregates bounded
central-difference directional checks and reports possible nonsmoothness only
as a competing explanation for derivative disagreement. The weak-activity
screen reports supported scalar inequalities in an explicit margin band above
the active tolerance. Neither path makes a global differentiability, active-
set, multiplier, or KKT claim.

## 2026-08-24: nonsmoothness and weak-activity persistence

The new persistence APIs compare the opt-in screens across explicitly supplied
nearby points or captured iterates. They require stable variable/row ordering,
preserve coordinate mismatches and unavailable point-local evidence, and
distinguish persistent from point-specific classifications. Repeated local
evidence remains descriptive rather than a global differentiability,
active-set, multiplier, or KKT certificate.

## 2026-08-24: finding-family and terminal-renderer consolidation

Renderer-neutral report data now retains every finding record while adding
deterministic family summaries keyed by finding code and classification. The
terminal `text_report` path and default `text/plain` display show errors and
warnings individually, summarize informational families, and make explicit
`maximum_findings` truncation visible. Markdown rendering remains an
all-findings view. The local renderer regression and full suite remain the
authoritative checks; this increment changes presentation only, not analysis
semantics or finding provenance.

Scalar constraint-scale alignment now serializes typed capability unavailability
when a declared scale lacks an evaluated source row or residual. Existing scalar
mismatch findings remain unchanged.

Component metadata scope validation now serializes typed input unavailability
when plugin declarations reference variables or constraints absent from the
analyzed model. Existing detailed stale-reference findings remain unchanged.

Component-port metadata scope validation now serializes typed input
unavailability when port declarations reference variables absent from the
analyzed model. Existing detailed stale-port findings remain unchanged.

The BMOPFTools PR branch `codex/source-schema-fidelity-main` is now based on
main commit `8f121216` at `74f90763`. Its contract audit passes all required
symbols and schema runtime checks, and the local BMOPFTools suite reports 5,162
passed tests with 33 conditional/broken tests and no failures. The handoff gate
remains revision-blocked until the branch is merged into BMOPFTools main.

The public `analyze(model)` scaling campaign is now tracked separately from the
synthetic sparse-kernel ladder. Its affine-chain records capture elapsed time,
allocations, finding counts, and the five-pass propagation limit; this is
measurement evidence only and leaves stage attribution and optimization open.

The reduced-Hessian persistence slice now also serializes typed numerical
unavailability for Jacobian scaling and spectral-scale comparisons when
non-finite derivative or eigenvalue evidence prevents a safe change-factor
calculation. Finite inputs retain the existing persistent/changing findings.

Reduced-Hessian active-row and active-Jacobian persistence now also serialize
typed input unavailability when retained snapshots use different constraint-row
source orderings. The existing alignment findings remain available for human
diagnosis without implying a rank or active-set conclusion.

Jacobian expected-mode and expected-mode-span persistence now serialize typed
input unavailability when declared variables fall outside the common
persistence coordinate scope. Existing alignment and observed/not-observed
findings remain unchanged.

Persistent reduced-Hessian structural scoping now serializes typed domain or
input unavailability when incidence is incomplete or support coordinates are
not represented in the model graph. No component-localization conclusion is
promoted in these guarded cases.

Reduced-Hessian expected-mode persistence now serializes typed input
unavailability when a declared mode uses variables outside the shared snapshot
coordinate scope. Existing expected-subspace findings remain unchanged.

Persistence coordinate mismatches now serialize typed input unavailability for
multiplier, Jacobian-scaling, and derivative-provenance comparisons. Existing
alignment findings remain available for diagnosis without implying numerical
or physical change.

Top-level Jacobian condition/rank and reduced-Hessian coordinate mismatches now
serialize typed input unavailability. Existing coordinate-mismatch findings
remain available without implying a numerical or physical conclusion.

Reduced-Hessian Jacobian-scaling persistence now serializes typed input
unavailability when retained snapshots use different constraint-row ordering.

Component-port coordinate-map validation now serializes typed input unavailability
when a terminal-to-model map references an undeclared port.

Component-port coordinate-semantics validation now serializes typed input
unavailability when semantics reference an undeclared port; unmapped semantics
remain an informational boundary.

Terminal-space component-port mode projection now serializes typed input
unavailability when a declared mode lacks its port or coordinate map; non-terminal
mode-space projection remains a capability boundary.

Component-port connection validation now serializes typed input unavailability
when a connection references an undeclared source or destination port.

Component-port nullspace-mode validation now serializes typed input
unavailability when a declared mode references an undeclared component port.

Component-port nullspace-mode semantic validation now serializes typed input
unavailability when a semantic label does not match a declared named mode.

Terminal-topology projection now serializes typed input unavailability when
coordinate-map consistency prevents projection into model coordinates.

Nominal-scale port projection now serializes typed capability unavailability when
the generic core lacks a directly supported one-terminal coordinate map.

Coupled-constraint scale alignment now serializes typed capability unavailability
when source associations or supported feasibility-margin geometry are missing.

Component-port constitutive-map validation now serializes typed input
unavailability when map identity, dimensions, equation labels, or coefficients
are invalid.

Terminal-topology nullspace assembly now serializes typed input unavailability
when declared ports or connections prevent a valid nullspace calculation.

## 2026-08-23: calibration release report

The release-gate ledger now has a generated Markdown handoff report at
`docs/calibration_release_report.md`, produced by
`benchmarks/build_calibration_release_report.jl`. The report preserves the
machine-readable status, renders all seven gate rows, links each gate to its
evidence artifacts, and makes the four blocking gates visible for review.
The local generation run succeeded. This is documentation and handoff
evidence only: `release_ready` remains `false`, and no scientific or causal
claim was promoted.

## 2026-08-23: benchmark-helper exemption audit

The consolidation audit now distinguishes data-producing runners from
infrastructure scripts. All 106 data-producing benchmark runners use
`benchmarks/common.jl`; the only three non-users are explicitly recorded as
the shared metadata library, the environment bootstrapper, and the process
launcher. The local quality baseline verifies that these exemptions match the
repository and that no unclassified non-helper runner remains. This closes
the helper-migration accounting gap without changing benchmark artifact
layouts or claiming scientific qualification.

## 2026-08-23: reviewed local quality policy

The verification boundary is now recorded in
`docs/quality_policy.json` with companion documentation in
`docs/quality_policy.md`. Four read-only checks are active locally: whitespace,
the package regression suite, consolidation inventory, and the local quality
baseline. Documentation-example execution, Aqua, and targeted JET checks are
explicitly deferred with reasons because their reviewed environments are not
configured. The policy and its shape checks pass locally; this does not claim
CI execution or scientific qualification.

## 2026-08-23: typed component-rank capability unavailability

The generic `component_rank_capability_report` and the BMOPFTools extension
report now add additive typed unavailable-reason records when a component
declaration omits `expected_rank`. Existing availability counts,
reason-compatible metadata, finding codes, and affected-entity evidence remain
intact. Renderer-neutral report data exposes the capability codes, category
`capability`, and their respective stages. A focused local serializer probe,
extension syntax parse, and the known local regression command pass; this does
not qualify observed rank or physical interpretation.

The BMOPFTools differentiability capability boundary now also emits a typed
`dependency` record when the optional engine report is not loaded, preserving
the existing unavailable finding and reason text. The extension source parses
successfully, but the active local checkout does not load the BMOPFTools
extension, so no extension runtime qualification is claimed.

The PowerModels public scalar-angle capability report now emits a typed
capability record when any network lacks public `:va` coordinates, preserving
the existing per-network findings and counts. The extension source parses
successfully, while optional PowerModels execution remains dependent on the
configured local environment.

The MadNLP primal-capture capability report now emits a typed capability record
for its unavailable primal-vector accessor while preserving the existing
metric/primal metadata and finding. The extension source parses successfully,
but MadNLP is not installed in the known environment, so no MadNLP runtime
qualification is claimed.

The BMOPFTools terminal-current port report now emits a typed capability record
when registered current coordinates cannot be mapped to model variables,
preserving the skipped-port count and existing finding. The extension source
parses successfully; runtime qualification remains dependent on the active
BMOPFTools checkout.

The BMOPFTools passive-network current-map report now emits typed capability
records for missing model-basis maps and missing public Ybus maps, preserving
the existing unit and warning/info boundaries. The extension source parses
successfully; runtime qualification remains dependent on the active checkout.

## 2026-08-22: sparse runtime/allocation scaling calibration

The deterministic sparse profiling corpus was measured at dimensions 16, 32,
64, and 128, with three retained repetitions after a warm-up run for each
dimension and case. The resulting 12 records retain per-stage wall-clock time,
allocated bytes, expected-evidence observations, and the local Julia
environment fingerprint. The compact report is
`docs/sparse_runtime_memory_scaling_summary.json`, generated by
`benchmarks/profile_sparse_runtime_memory_scaling.jl`.

These are solver-independent core profiling observations. `Sys.maxrss` is
recorded as a process high-water mark, so its incremental values are
descriptive and are not isolated per-case peak-memory measurements. OPF-solver
runtime/memory scaling and isolated peak-memory instrumentation remain open
release work.

## 2026-08-22: API/test/benchmark consolidation audit

The consolidation audit records the current engineering boundary without
changing existing result layouts: 539 unique root exports, 113 root testsets
across nine included test modules, 109 benchmark scripts, and schema versions
on all 49 JSON artifacts. It also counts 28 bare source `catch` boundaries.
The new
`UnavailableReason` type and `unavailable_reason_data` boundary serializer
provide the typed unavailable schema, and profile-result serialization now
emits typed records for guarded dense, sparse-QR, and scaled sparse-QR rank
paths without changing legacy metadata. Broad adapter adoption and
root-export tiering remain open. The non-breaking `NLPDiagnostics.Stable`
facade now exposes the deliberately small model-analysis/reporting surface,
while `NLPDiagnostics.Advanced` exposes the research-facing profiling,
rank-policy, and typed-capability APIs; broad root-export tier migration is
still open. The audit records five typed adapter call sites, including the
guarded large sparse rank campaign and profiling serialization.
Scaling-covariance unavailable metrics now also preserve their legacy reason
arrays while emitting typed capability records with stable side and stage
fields.

The shared `benchmarks/common.jl` helper now centralizes repository discovery,
summary loading, JSON writing, Git provenance, and recursive file inventory for
106 data-producing release, rank, runtime, and audit runners, plus three
explicit infrastructure exemptions; the BMOPF campaign and
evidence-ledger summarizers and comparisons, formulation-intervention,
multiconductor-point, probe, crosscheck, saved-result-unit/profile, IBR
cross-fixture, source-solver-matrix, solver-trace and solver-matrix summaries,
comparisons, repeat, option-perturbation, sweep, and restoration summarizers,
tangent-policy, solver-trace and summary comparisons,
residual-trend, checkout, and PR-handoff validators now use the shared
JSON/repository helper. The new
`benchmarks/audit_bmopf_api_contract.jl` audit extracts every BMOPFTools symbol
referenced by the JuMP extension and records the resolved dependency revision,
branch, dirty state, and runtime schema major version. Against the current `codex/source-schema-fidelity`
checkout it is intentionally failing because `OpfDiagnosticSchema` and
`opf_diagnostic_schema` are absent. The tracked clean-main artifact passes at
BMOPFTools `8f121216065bcd692f18444836c7c80149e5cf4a`, and the full local suite
passes 1634/1634 there. This is dependency-handoff evidence rather than a
scientific result. The executable `benchmarks/audit_bmopf_pr_handoff.jl` now
turns these two artifacts into an explicit blocked/pass handoff gate;
`benchmarks/validate_bmopf_checkout.jl` now bootstraps or accepts an isolated
local environment and records contract plus full-suite results. Its clean-main
validation passed 1634/1634 locally and is tracked in
`docs/bmopf_checkout_validation_summary.json`; activation of deferred
documentation-example, Aqua, and JET checks remains open.

The machine-readable inventory is
`docs/api_test_benchmark_consolidation_summary.json`, generated by
`benchmarks/audit_api_test_benchmark_consolidation.jl`. This is partial gate
evidence: the explicit API-tier inventory, stable API tiers, broad typed-unavailable adoption, migration of the
helper-exemption review, dependency handoff from the active BMOPFTools checkout, and
activation of deferred quality tools remain engineering work.

## 2026-08-22: seeded rank-oracle false-positive/false-negative calibration

The deterministic three-seed rank-oracle corpus contains 27 records: 18 hard
controls and nine deliberately threshold-clustered controls. All hard controls
match their planted expectations with zero false positives, false negatives,
backend unavailability, or dense/sparse disagreements. Four of the nine
threshold-cluster controls disagree across backends; these are retained as
expected tolerance-sensitive numerical evidence rather than failures. The
compact result is tracked at
`docs/randomized_rank_oracle_calibration_summary.json`; broader adversarial and
large-model statistics remain open.

## 2026-08-22: guarded large sparse rank-oracle calibration

The large-model extension contains 20 sparse construction controls at
dimensions 128, 256, 512, and 1024. It covers lower-bidiagonal full rank,
one planted zero direction, wide and tall rectangular identities, and an
alternating twenty-order diagonal under explicit row-column scaling. Sparse
QR was available on all 20 records and matched every planted construction
rank; no sparse false negatives, mismatches, or unavailable results were
observed.

Dense SVD was intentionally disabled with `max_dense_entries = 0` on every
record, so the report retains dense unavailability as a work-guard observation
rather than a failed comparison. The machine-readable result is
`docs/large_sparse_rank_oracle_summary.json`, generated by
`benchmarks/calibrate_large_sparse_rank_oracles.jl`. This advances large-model
coverage and now carries the typed `nlpdiagnostics-unavailable-reason-v1`
schema for each dense work-guard result, without claiming a mathematical rank
certificate or closing the broader cross-backend statistics gate.

## 2026-08-22: real 99-bus transformed-coordinate solver campaign

This section supersedes the readiness-only solver statement above. The bounded
campaign now runs matched reference and phase-only Ipopt solves on all six
selected real ENWL 99-bus snapshots. All twelve solves terminate
`LOCALLY_SOLVED`, with six source endpoints recovered and six phase-only
endpoints rebuilt from complete starts.

The strict physical KKT gate is available on every run but passes only 2/6
reference and 2/6 phase-only endpoints at complementarity tolerance `1e-5`.
The saved failure-localization report shows identical failed-side keys, counts,
and family attribution between reference and phase-only runs: four snapshots
fail only on `ibr_p_upper`, while both t13 snapshots pass. This is localization
evidence, not a formulation or solver-causality diagnosis.

The phase-only covariance gate passes all seven available checks on all six
snapshots, including scalar-set transport, point/objective/residual agreement,
and semantic Jacobian comparison. Physical rank remains unavailable because
dense rank is disabled, and inequality-multiplier covariance remains outside
the covariance report. The machine-readable release-gate ledger is
`docs/calibration_release_gate_summary.json`.
