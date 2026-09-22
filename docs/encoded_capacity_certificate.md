# Experimental certificate for encoded ACP capacity shortages

`benchmarks/power_repair_pilot/encoded_capacity_certificate.jl` checks a sufficient
condition for **exact-real infeasibility of the actual encoded constraints**.
It is a post-evaluation experiment, outside the stable API. It leaves the original
case9 and case14 evaluations, including the case14 static-detection failure, intact.
A successful source-to-builder match alone is insufficient for this conclusion.

## Scope and proof

The existing conservative matcher first checks the complete supported backend row
multiset against a standard ACP model rebuilt from the supplied data. Unsupported
components, representations, callbacks, precision, or mismatches return
`unavailable`. A second fresh build supplies named coordinates; the certificate
does not trust mutable adapter variable dictionaries.

The certificate reads equality rows and explicit variable bounds from the actual
backend. Finite encoded coefficients are converted to exact rational values.
Supported arithmetic is expanded exactly, including MOI's doubled diagonal
quadratic convention. Angle differences are canonicalized using the exact
identities `cos(-t) = cos(t)` and `sin(-t) = -sin(t)`. Other trigonometric arguments
are unsupported. Expansion has size and depth limits.

Selected bus equations have outgoing active flows minus active generation, a
nonnegative fixed constant, and nonnegative voltage-square shunt terms. Selected
branch equations express each terminal's active flow in the supported ACP form.
The code sums the bus equations and subtracts the terminal equations, then checks
exact cancellation of all remaining terms against the extracted branch losses,
shunts, generation, and constant. Demand comes from the encoded bus constants,
including any rounding during load aggregation, rather than a source-data sum.
Generation capacity comes from explicit backend bounds.

For each branch the extracted terminal sum is

```
L = A*x² + B*y² + C*x*y*cos(t) + D*x*y*sin(t),
0 ≤ x ≤ U, 0 ≤ y ≤ V, A ≥ 0, B ≥ 0.
```

Cauchy–Schwarz and the arithmetic–geometric mean inequality give

```
L ≥ (2*sqrt(A*B) - sqrt(C²+D²))*x*y.
```

If `C²+D² ≤ 4*A*B`, the lower bound is exactly zero. Otherwise integer square
roots produce rational dyadic enclosures: `r_hi ≥ sqrt(C²+D²)` and
`s_lo ≤ sqrt(A*B)`. Consequently

```
L ≥ -max(0, r_hi - 2*s_lo)*U*V.
```

The enclosure uses a fixed 128-bit fractional denominator and exact integer
arithmetic. It need not be tight to be sound. Extremely small or ill-scaled
coefficients may yield a conservative inconclusive result. There is no assumed
exact passivity of rounded expanded coefficients and no floating-point square
root in the proof arithmetic.

Let `D_encoded` be the sum of encoded demand constants, `P_upper` the sum of
encoded generator upper bounds, and `L_lower` the sum of branch lower bounds.
The aggregate equation requires zero, but its left-hand side is at least

```
margin = D_encoded - P_upper + L_lower.
```

A strictly positive exact margin proves contradiction. Equality or a negative
margin yields `not_ruled_out`, never feasibility. Unsupported or ambiguous row
extraction yields `unavailable`. Shunt terms can be dropped because their encoded
coefficients are nonnegative and real squares are nonnegative.

## Interpretation and limitations

`certified_infeasible` concerns exact real satisfaction of the recorded equations
and bounds. It does **not** certify infeasibility at an optimizer's positive
feasibility tolerance, floating-point residual evaluation, real-world data intent,
optimality, or operational security. Solver-tolerance certification would need to
account for every contributing row and bound relaxation. A non-shortage result
says nothing about island adequacy, voltage, or reactive feasibility.

The prototype is a sufficient-condition checker, not an independently verified
proof kernel. Its mathematics and implementation require continued review before
promotion to the library's mathematical-proof producers. The core proof inventory
is unchanged because this helper produces no core diagnostic findings.

## Reproduction

From the repository root, in the pinned pilot environment:

```sh
julia --startup-file=no --compiled-modules=no --project=benchmarks/environments/power_repair_pilot test/encoded_capacity_certificate_contracts.jl
```

The test uses checked-in case9/case14 fixtures directly and writes
`work/encoded-capacity-followup/summary.json`, containing exact coefficients,
row references, bounds, margins, contract digests, and source hashes. These
networks are already exposed development data; this is not fresh validation or
evidence of human repair benefit. The original freeze hashes are checked without
being refreshed.

## Development observations

The exposed case9 and case14 zero-capacity variants produce positive exact
contradiction margins of approximately 2.70 and 2.59 p.u.; their clean controls
are not ruled out. An added two-load example records the builder's rounded bus
sum `Float64(0.1 + 0.2)`, which differs from the exact sum of the two input floats.

An off-nominal transformer with a 0.1-radian phase shift and 0.97 tap produces a
negative aggregate loss allowance of approximately `-2.47267e-16` p.u. A 0.3-p.u.
shortage clears that allowance. A `1e-18`-p.u. positive source shortage must remain
`not_ruled_out`; this is conservatism of the sufficient condition, not evidence
that the marginal model is feasible. These are constructed development examples.

PowerModels parser normalization (including case14 angle-limit tightening and a
bus-type update) is retained in the test log. Conclusions apply to the instantiated
backend, not unmodified raw MATPOWER semantics.
