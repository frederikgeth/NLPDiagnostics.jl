# Diagnostic playbook

Start from the symptom you observed. Each path below narrows the question; none
authorizes an automatic model change.

| Symptom | First evidence to preserve | First useful checks |
|:--|:--|:--|
| Solver reports infeasible | termination, primal status, options, source/model revision | static contradictions, source/model consistency, independent feasibility certificate |
| Restoration or line search fails | iteration log, start, first non-finite evaluation | point domains, derivative domains, start feasibility, scaling |
| Constraint or derivative is non-finite | point and expression path | operator domain, overflow/underflow, finite-difference provenance |
| Result depends on initialization | every start in common coordinates | domain and bounds at each start, matched runs, basin-sensitive geometry |
| Jacobian appears singular | point, row set, scaling, tolerance, backend | structural matching, tolerance sweep, persistence, expected modes |
| Scaling changes solver behaviour | physical model and physical start | covariance, mapped residuals, matched solver options and stopping rules |
| OPF has an angle freedom | topology, island and reference metadata | structural component, local nullspace, declared angle mode, reference intervention |
| Formulations behave differently | source, starts and result mappings | common physical quantities, formulation-specific rows, matched acceptance checks |

## Solver reports infeasible

1. Record `termination_status`, `primal_status`, solver version, all nondefault
   options, and the exact model/data revision.
2. Run the default static analysis before interpreting solver iterations.
3. Check source-to-model status, units, base values, topology, and omitted records.
4. If a mathematical contradiction is reported, inspect its affected rows and
   confirm their source meaning independently.
5. If no contradiction is proved, retain “solver reported infeasible.” Do not
   promote that status to proof that the intended physical problem is infeasible.

A solver conflict/IIS, an island-capacity certificate, and a contradictory-bound
proof answer different questions. Record which one was actually obtained.

## Restoration or line search fails

Capture the initial point and any available iterates. Analyze the earliest point
where values become non-finite. Check operator domains before tuning algorithms.
Then inspect derivative provenance and coordinate scales. A finite-difference
row crossing a domain boundary is different from an exact derivative failure.

Use one intervention at a time: a justified start, a coordinate policy, or a
solver mechanism. If several change together, the comparison cannot identify
which mechanism mattered.

## A value or derivative is non-finite

Read the expression path and point label in the finding. Ask whether the point
is a complete source start, solver iterate, result, perturbation, or synthetic
probe. Then separate:

- an argument outside a mathematical operator domain;
- overflow or underflow in a mathematically valid expression;
- a finite-difference stencil leaving the valid domain; and
- an unavailable or failing callback.

The [initialization tutorial](../tutorials/initialization.md) demonstrates why a
point failure is not model infeasibility.

## Results depend on initialization

Treat starts as experimental inputs. Give each a stable label and provenance,
map them to the same physical coordinates, and run fresh models under identical
solver settings. Report failures and time limits alongside successful runs.

Compare model quantities at the start before comparing iteration counts. A start
that violates bounds, uses different per-unit bases, or omits coordinates is not
a matched initial condition.

## The Jacobian appears singular

Record the selected rows, point, coordinate scaling, matrix norm, absolute and
relative tolerances, and backend. Then compare four independent questions:

1. Does structural matching predict an unmatched region?
2. Does numerical rank loss persist at other meaningful points?
3. Do independent rank backends and direct null-vector residuals agree?
4. Does authoritative domain metadata declare the observed direction?

See [Rank, structure, and gauges](../concepts/rank-and-gauges.md). Avoid selecting
a tolerance because it produces the desired physical interpretation.

## Scaling changes solver behaviour

Define scaling as an explicit coordinate map. Transport the same physical start,
verify round-trip mapping, and recompute residuals in common physical units.
Keep solver tolerances and stopping criteria interpretable across policies.

Iteration count alone is weak evidence: record termination, feasibility,
stationarity, complementarity where available, linear work, and unsupported
telemetry. Include a negative-control policy and repeat fresh runs when solver
or system variability matters.

## OPF has an unexpected angle freedom

Identify connected islands and the reference policy from authoritative topology
and component metadata. Compare the declared uniform-angle direction with the
observed local nullspace in model-coordinate order. Add or change a reference
only when the source/formulation contract justifies it, then check whether the
predicted freedom disappears.

A concentrated angle null vector suggests where to investigate. It does not by
itself prove an electrical gauge. Work through the [OPF hypotheses tutorial](../tutorials/opf-hypotheses.md).

## Two formulations behave differently

First establish that the formulations represent the intended same physical case.
Map starts and results to common physical coordinates and compare source records,
component status, objectives, constraints, and acceptance tolerances. Preserve
formulation-specific variables and rows rather than forcing a false one-to-one map.

Only after those gates pass should solver-work differences be attributed to the
formulation. A faster failed solve and a slower verified result are not comparable
successes.

## When to stop

Stop narrowing the diagnosis when the next claim requires evidence you do not
have. Record an unavailable reason and the smallest additional measurement that
would distinguish the remaining hypotheses. That is a valid research outcome.
