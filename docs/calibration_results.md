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
