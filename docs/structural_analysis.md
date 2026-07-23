# Structural analysis semantics

NLPDiagnostics distinguishes the declared incidence graph from the structural
equation graph used for matching.

## Incidence graph

Every non-domain constraint is represented by a constraint node:

- scalar functions contribute one node;
- vector functions in coordinate-wise product sets contribute one node per
  scalar row; and
- vector functions in coupled sets contribute one conservative block node.

This preserves set semantics. For example, the rows of `Zeros(n)` are
independent equality equations, while the coordinates of a second-order cone
must not be split into independent constraints.

Custom set packages may extend `is_coordinatewise_set` and `constraint_role`.
The default behavior is conservative.

## Variable roles

The equality graph treats only `FreeVariable` nodes as unknowns.

- `FixedVariable` is fixed by the intersection of ordinary scalar bounds.
- `ParameterVariable` uses the MOI `Parameter` set.
- `InfeasibleVariableDomain` has contradictory ordinary scalar bounds.

Semicontinuous and semiinteger endpoints are not ordinary lower and upper
bounds because zero remains in their domains.

## Constraint roles

Only `EqualityConstraint` nodes enter the default matching.

- scalar `EqualTo`, zero-width `Interval`, and rows of `Zeros` are equalities;
- scalar inequalities, nonnegative/nonpositive rows, and nonzero-width
  intervals are inequalities;
- `Reals` rows are free;
- non-product vector sets are coupled blocks; and
- unsupported scalar relations are opaque.

An evaluated active-set view may later promote locally active inequalities into
a separate matching. The static view never assumes they are active.

## Matching

`maximum_matching` computes a deterministic maximum-cardinality matching using
augmenting paths. The result reports graph positions and uses zero for
unmatched or ineligible vertices.

An unmatched free variable proves only that the declared equality pattern is
structurally underdetermined. An objective or active inequality may still
select a local solution. An unmatched equality node proves structural
overdetermination of the equality pattern, not numerical dependence or
infeasibility.

## Dulmage–Mendelsohn partition

`dulmage_mendelsohn` uses alternating reachability from unmatched variables and
unmatched equations to construct:

- an underdetermined partition;
- a well-determined partition; and
- an overdetermined partition.

This is the initial three-way DM partition. Decomposition of the
well-determined partition into irreducible square blocks is still pending.
