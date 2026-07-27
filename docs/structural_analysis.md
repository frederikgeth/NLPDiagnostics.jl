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
- `InvalidVariableDomain` has an invalid scalar endpoint, such as NaN, and is
  excluded from structural matching without claiming infeasibility.
- `DiscreteVariable` has an MOI `Integer` or `ZeroOne` declaration and is
  excluded from continuous Jacobian matching.

Static analysis additionally proves infeasibility when a discrete variable is
fixed outside its discrete domain, such as a binary variable fixed to `0.5`.
It also proves infeasibility when an interval contains no admissible discrete
value, such as a binary variable restricted to `[0.1, 0.9]`.

Semicontinuous and semiinteger endpoints are not ordinary lower and upper
bounds because zero remains in their domains. Static analysis reports these as
`disjunctive_variable_domain` findings rather than collapsing them into a
continuous interval.

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

## Reused scalar expressions

Static analysis canonicalizes supported scalar affine, quadratic, and
nonlinear expression trees. Exact function-and-set duplicates are reported as
`duplicate_constraint`. When the same canonical scalar expression appears with
different supported scalar sets, it is reported as
`reused_constraint_expression`; paired bounds can be intentional, so this is
representational evidence. If the intersection of those scalar sets is empty,
`inconsistent_reused_expression_sets` is a mathematical proof of infeasibility
for that shared expression. A set implied by the intersection of all the other
sets is reported as `dominated_reused_expression_set`; this is a proven local
redundancy fact, not an instruction to silently remove it.

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
well-determined partition into irreducible square blocks contracts each matched
variable–equation pair, computes strongly connected components, and returns
the blocks in dependency order. These blocks describe structural sparsity, not
numerical nonsingularity.

## Graph export

`structural_graph_data` returns renderer-neutral variables, constraint nodes,
and edges annotated with:

- structural role;
- DM region;
- well-determined block number; and
- matching membership.

`structural_graph_text` provides a deterministic terminal representation.
`structural_graph_dot` returns Graphviz DOT without invoking Graphviz or
writing files. MOI constraint indices are metadata rather than node IDs because
constraint indices are not globally unique across function/set types.
## Variable-domain intersections

`variable_domains(model)` exposes the intersection of supported scalar
variable-bound declarations. It preserves declared numeric endpoint types,
uses `nothing` for an unbounded side, and records both all declared bound
sources and the source(s) attaining each effective endpoint. Structural roles
are then derived from this object: fixed, parameter, infeasible intersection,
or invalid domain. In particular, a NaN endpoint is `InvalidVariableDomain`,
not a free variable or a proof of infeasibility.
