# Structural analysis semantics

NLPDiagnostics distinguishes the declared incidence graph from the structural
equation graph used for matching.

For scalar affine and quadratic functions, duplicate terms are combined before
incidence is formed. Thus exact cancellations such as `x - x` or cancelling
quadratic monomials do not create false variable dependencies. Nonlinear
expression support remains syntactic and deliberately does not attempt general
symbolic simplification. One safe direct nonlinear identity is recognized:
`x - x` for the same bare MOI variable is folded to zero. This intentionally
does not simplify repeated nonlinear subexpressions, which could conceal an
operator-domain requirement. Likewise, a product containing a literal zero is
folded only when every remaining operand is a bare variable or constant; this
does not erase a nested expression such as `0 * log(x)`.

When a direct `x / x` node uses a variable whose declared scalar domain proves
it is nonzero, the pass reports `nonzero_self_division_identity`. It does not
rewrite the model or claim the surrounding row is feasible; it exposes a
proven constant subexpression that can otherwise look like a sensitivity.
When that self-division is the whole supported scalar constraint function, the
same proof can classify its set relation as
`redundant_nonzero_self_division_constraint` or
`infeasible_nonzero_self_division_constraint`.
At an objective root, it is reported as
`constant_nonzero_self_division_objective`, proving that the objective is one
on its declared domain without rewriting the original formulation.

When declared scalar bounds resolve the sign of a direct `abs(x)` argument,
the pass reports `sign_resolved_absolute_value` and its affine replacement
(`x` or `-x`). This is a mathematical identity, but a zero-inclusive bound is
still called out as a potentially nonsmooth boundary in the original form.
At a direct root constraint, `abs(x) = 0` (including a zero-width interval)
is reported as `absolute_zero_implies_fixed_variable`, proving `x = 0` without
silently substituting it.
Likewise, `x^2 = 0` yields `square_zero_implies_fixed_variable`, while a
direct square constrained strictly below zero yields the infeasibility proof
`infeasible_negative_square_constraint`.
The same exact-zero reasoning covers `sqrt(x) = 0`, reported as
`square_root_zero_implies_fixed_variable`.
For a positive level, sign-resolving bounds additionally yield
`sign_resolved_square_level_set`, proving the corresponding positive or
negative root without altering the model.

Direct two-argument `min(x, c)` and `max(x, c)` nodes are similarly reported
as `bound_resolved_minmax_expression` when declared scalar bounds select the
variable or constant branch everywhere. If the constant branch is the complete
scalar constraint function, its set membership is additionally proven as
`redundant_bound_resolved_minmax_constraint` or
`infeasible_bound_resolved_minmax_constraint`.
At an objective root with a constant selected branch, the same proof yields
`constant_bound_resolved_minmax_objective`.

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

Supported scalar affine equality rows are additionally normalized by their
first nonzero coefficient. Distinct rows that define the same equality up to a
nonzero scalar are reported as `proportional_affine_equality_constraints`.
This is static redundancy evidence, separate from exact duplicate constraints.
Supported scalar affine `LessThan` and `GreaterThan` rows are likewise
converted to a common oriented half-space before normalization. Equivalent
half-spaces are reported as `proportional_affine_inequality_constraints`; an
opposite orientation is deliberately not grouped.

For rows with the same oriented normal but different right-hand sides, the
loosest half-space is mathematically implied by the tightest one and is
reported as `dominated_affine_inequality`. This check does not compare
opposite orientations: together, those form a slab and may both be necessary.
It does, however, prove `inconsistent_opposing_affine_inequalities` when the
two sides impose an empty slab. This works for any supported affine dimension,
including unbounded multi-variable expressions.

The same normalized-direction layer compares affine equalities with parallel
half-spaces and with other parallel equalities. It proves
`inconsistent_affine_equality_halfspace` when an equality lies outside a
parallel bound, and `inconsistent_parallel_affine_equalities` when equalities
require different values of the same affine expression.

## Fully fixed affine rows

When every nonzero variable in a supported scalar affine row has equal
effective lower and upper bounds, NLPDiagnostics substitutes those values for
analysis only. It reports `redundant_fixed_affine_constraint` when the row is
already satisfied and `infeasible_fixed_affine_constraint` when it is not.
The latter is a direct mathematical infeasibility proof; neither finding
changes the model.

The same fixed-value substitution supports scalar quadratic and supported
scalar nonlinear expressions. Their satisfied/violated cases are reported as
`redundant_fixed_expression_constraint` and
`infeasible_fixed_expression_constraint`; an invalid fixed nonlinear domain
is `fixed_expression_domain_violation`. These are distinct from observations
at an initialization point because the substituted values are mathematically
required by declared bounds.

Fixed-value evaluation recognizes numerically deliberate primitives including
`log1p`, `expm1`, `log1pexp`/`log1exp`/`softplus`, `log1mexp`, `logdiffexp`,
`logcosh`, `logsumexp`, and `logistic`. The composite primitives use stable
formulas, so a fixed extreme argument does not create an artificial overflow
while the diagnostic is trying to establish a mathematical fact. This supports
static evaluation only; custom operator registration remains responsible for
solver-facing values and derivatives.
It also evaluates ordinary radian and degree-based trigonometric primitives,
including `asind` and `acosd`, consistently with the domain layer.

Custom operators can extend `fixed_operator_value(Val(:operator), values)`.
If a fully fixed expression contains an operator without such an evaluator,
the static pass reports `fixed_expression_evaluation_unavailable` rather than
guessing whether the row is feasible. A non-finite floating-point result from
a registered evaluator is separately reported as
`fixed_expression_nonfinite_evaluation`: it is a numerical observation, not
a proof that the corresponding real-valued mathematical expression is invalid.

## Fixed objectives

When every variable in the symbolic objective is fixed, the static pass reports
`fixed_objective` with its exact substituted value and optimization sense. This
is not an infeasibility claim: it states that the remaining model is a
feasibility problem rather than an objective-driven optimization problem.
Fixed objectives retain the same explicit domain-failure, unavailable-evaluator,
and non-finite floating-point distinctions as fixed constraints.

A variable-free symbolic objective is separately reported as
`constant_objective`. It can be an intentional feasibility formulation, but it
is not conflated with an objective made constant by fixing variables. Constant
objective domain, evaluator-availability, and non-finite cases are likewise
reported separately.

## Unconstrained affine objective rays

For a scalar affine objective, NLPDiagnostics identifies a variable that is
absent from every restrictive constraint (a `Reals` row is not restrictive) and unbounded in the objective-improving
direction. It reports `unconstrained_affine_objective_ray` as a mathematical
proof of an improving ray conditional on the rest of the model being feasible.
It deliberately does not turn this conditional statement into an unconditional
claim that the complete model is unbounded.

The same conditional proof applies to a disconnected diagonal quadratic
objective term with improving-sign curvature, reported as
`unconstrained_quadratic_objective_ray`. Cross terms do not invalidate this
conclusion because all other variables can be held fixed while the unbounded
quadratic direction dominates.

An affine term inside a quadratic objective still yields
`unconstrained_affine_objective_ray` when that variable appears in no quadratic
monomial. Curvature in other objective variables does not mask this separate
linear ray.

## Affine implied variable bounds

For a scalar affine row with exactly one nonzero variable coefficient,
NLPDiagnostics transforms supported scalar sets into an exact implied interval
for that variable. `affine_implied_variable_bound` retains this safe presolve
fact without changing the model. Combining these intervals with declared
variable bounds can prove `inconsistent_affine_implied_variable_bounds` when
their intersection is empty.

The static pass also performs bounded, report-only interval propagation through
supported multi-variable scalar affine rows. It starts from declared finite
bounds, then may use bounds derived in earlier passes; the default limit is
five passes and can be set with `max_affine_propagation_passes`. It reports
derived tightening as `affine_interval_propagated_variable_bound` and proves
an empty derived interval as `inconsistent_affine_interval_propagation`. It
reports a singleton derived interval as
`affine_interval_propagated_variable_fixed`. If the pass limit is reached
before stabilization, it reports `affine_interval_propagation_limit_reached`
and retains pass/convergence metadata. It never modifies the model.

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
