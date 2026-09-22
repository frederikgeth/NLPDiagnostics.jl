# Range and endpoint proof contract

Audited 11 September 2026 against the package's real-valued primitive semantics.
The claims below are necessary conditions on defined real evaluations, not
claims that the rest of a model is feasible or that floating-point evaluation
will produce the exact mathematical value. Custom primitives must honor their
registered semantics; this audit does not certify arbitrary callback code.

`test/range_semantic_contracts.jl` specifies attainable and excluded outputs
independently of the implementation lookup tables. Earlier
`range_premise_contracts.jl` and `algebraic_range_contracts.jl` cover malformed
sets, irrational references, and enclosing square-root arithmetic.

## Range derivations and witnesses

| Operators | Mathematical justification | Attainable output witness |
|---|---|---|
| exp, exp2 | Positive on every finite real argument; zero is only a limiting value. | 1 at input 0. |
| softplus, log1pexp, log1exp | Package semantics are log(1+exp(x)), strictly positive. | 1 at log(exp(1)-1). |
| expm1 | exp(x)-1 is strictly greater than -1. | 0 at 0. |
| log1mexp | On x<0, 0<1-exp(x)<1, hence its logarithm is strictly negative. | -1 at log(1-exp(-1)). |
| logistic | 1/(1+exp(-x)) lies strictly between 0 and 1. | 1/2 at 0. |
| tanh | (exp(2x)-1)/(exp(2x)+1) lies strictly between -1 and 1. | 0 at 0. |
| cosh, sech, logcosh | With t=exp(x)>0, t+1/t>=2, with equality only at t=1. Thus cosh>=1, 0<sech<=1, logcosh>=0. | 1, 1, and 0 respectively at 0. |
| abs, square, sqrt | Nonnegative; zero has the unique real preimage zero. | 0 at 0. |
| acosh, asech | Principal acosh is nonnegative; asech(x)=acosh(1/x) on 0<x<=1. | 0 at 1. |
| sin, cos, sind, cosd | The unit-circle identity bounds each coordinate by 1 in magnitude. | 1 at pi/2, 0, 90, and 0 respectively. |
| asin, acos, atan | Principal inverse ranges lie in [-pi/2,pi/2], [0,pi], and (-pi/2,pi/2). | 0 at 0, 1, and 0 respectively. |
| asec, acsc | Principal acos(1/x) and asin(1/x), for abs(x)>=1; inverse cosecant cannot return zero. | asec(1)=0; acsc(1/sin(1))=1 because 0<1<pi/2. |
| asind, acosd, asecd, acscd, atand | Corresponding principal inverse ranges in degrees; atan endpoints remain open. | 90, 180, 180, 90, 0 at inputs 1, -1, -1, 1, 0. |
| sec, csc, secd, cscd | Reciprocals of nonzero circle coordinates have magnitude at least 1. | 1 at inputs 0, pi/2, 0, 90. |
| csch, acsch, acoth | Each has nonzero output on its real domain. | csch(asinh(1))=1, acsch(1/sinh(1))=1, acoth(coth(1))=1. |
| coth | For real x!=0, cosh(x)^2-sinh(x)^2=1 gives abs(coth(x))>1. | 2 at log(3)/2. |
| sign | The real codomain is exactly {-1,0,1}. | Each output at the same input. |
| atan(y,x) | A defined principal angle lies within [-pi,pi]. | 0 on the positive x-axis. |

Radian checks intentionally use outer rational enclosures from pi<22/7.
The enclosure endpoints are not asserted to be attained. Rounded pi or pi/2
cannot establish an exact endpoint identity or exclusion. The reciprocal
rules supply additional necessary exclusions, not a complete domain solver.

## Unique preimages

The endpoint tests cover every retained entry, in equality and degenerate
interval form, including compatible bounds, both directions of conflicting
bounds, invalid premises, wider intervals, and nested arguments.

- acos(1)=asec(1)=0. In degrees, asin/acsc at +/-90 have preimages +/-1;
  acos/asec at 0 and 180 have preimages 1 and -1. Uniqueness follows from the
  principal inverse definitions and reciprocal substitution.
- sinh, asinh, tanh, atanh vanish only at zero. The strict exponential
  monotonicity and inverse definitions establish uniqueness. The cosh,
  sech, and logcosh extrema above uniquely require zero. acosh and asech
  output zero uniquely at input one.
- exp(x)=1, expm1(x)=0, log1p(x)=0, logistic(x)=1/2, and cbrt(x)=0
  uniquely require x=0. log(x)=0 uniquely requires x=1. These follow from
  injectivity and the defining identities, not rounded reference evaluation.
- abs(x)=0, sqrt(x)=0, x^2=0, and sign(x)=0 uniquely require x=0.
- x^2=L>0 has the two symbolic roots +/-sqrt(L). Only validated scalar sign
  bounds select a branch. The roots need not both survive other constraints.
  Numeric root evidence requires a perfect rational square; otherwise certified
  rational enclosures accompany the symbolic expression.
- atan(y,x)=0 requires y=0 and x>=0 as a necessary condition. On the ordinary
  defined real domain x>0; allowing the origin in the reported necessary
  condition is conservative and does not assert its mathematical definedness.
  No other rounded axis angle supplies an exact fixing implication.

## Limits and emitted findings

The 11 inventory producers cover zero/positive square findings, discrete sign
range/fixing, exponential exclusions, reciprocal trigonometric/hyperbolic
exclusions, unary enclosures, atan2 range/axis implications, and inverse,
hyperbolic, and elementary endpoint implications and bound conflicts.
Malformed scalar sets do not supply these proofs. Unsupported sets and nested
endpoint arguments cause abstention. Rational bound evidence preserves type.

These contracts justify retaining these finding families with scoped tests.
They do not certify floating-point primitive implementations, establish useful
recall on power-system incidents, or remove the need for the remaining audits.
