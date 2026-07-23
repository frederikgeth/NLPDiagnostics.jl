# Development roadmap

This roadmap orders work by the evidence needed for later claims. A numerical
or physical interpretation should not be implemented before the structural and
evaluation layers can expose its supporting evidence.

## Implemented foundation

- Public `MOI.ModelLike` snapshot boundary with optional direct JuMP support.
- Evidence-first findings with independent severity, issue domain, evidence
  basis, and confidence.
- Static checks for bounds, fixed variables, constant constraints, constant
  domain failures, exact duplicate constraints, and disconnected variables.
- Reusable variable-support extraction for scalar and vector MOI functions.
- Variable–constraint bipartite graph with scalar rows for coordinate-wise
  product sets and block vertices for coupled vector sets.
- Exact connected components, including vector-row identity, coupled-set
  semantics, and explicit handling of incomplete function support.

## Next: structural equation classification and matching

Before computing a matching, variables and constraint rows need explicit
roles. Variables must distinguish free decisions, fixed variables, and MOI
parameters. Constraint rows must distinguish:

- equality equation;
- inequality that is potentially active;
- variable-domain constraint;
- complementarity or conic relation; or
- unsupported/opaque relation.

The first Dulmage–Mendelsohn implementation should operate on equality rows by
default. A second active-set view can include inequalities selected at an
evaluation point. Reports must not silently interpret all inequalities as
simultaneously active equations.

Deliverables:

1. row-role classification with evidence from the MOI set;
2. deterministic maximum bipartite matching;
3. unmatched-variable and unmatched-equation findings;
4. under-, well-, and over-determined DM blocks;
5. intentionally broken structural test models; and
6. graph export suitable for terminal and future visual renderers.

## Then: expression domains

- Normalized expression-node paths and source provenance.
- Operator-domain rules such as `log(x)`, `sqrt(x)`, division, and fractional
  powers.
- Interval propagation from proven variable bounds.
- Distinct findings for proven violations, possible violations, and
  evaluation-point violations.
- Extension hooks for user-defined operators and domain plugins.

## Then: numerical evaluator adapter

- Capability discovery for `AbstractNLPEvaluator` and nonlinear oracle sets.
- Point-tagged cache for values, gradients, Jacobians, and Hessians.
- Non-finite value and derivative evidence.
- Jacobian row/column norms and scale summaries.
- Rank and nullspace estimates that always report method, threshold, scaling,
  and evaluation point.

## Degeneracy framework

Numerical nullspaces should be compared with structural results and
plugin-supplied expected gauges. Initial generic classifications:

- structurally underdetermined;
- expected coordinate gauge;
- unexpected local right-null mode;
- dependent active constraints;
- non-unique multiplier/left-null mode;
- flat reduced-Hessian direction; and
- unknown.

PowerModels and multiconductor semantics follow only after these generic
interfaces are stable.
