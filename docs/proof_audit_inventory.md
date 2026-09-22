# Finite mathematical-proof audit inventory

Snapshot: 11 September 2026. Decisions concern the proof label, not deletion of
useful numerical diagnostics. `retain` means preserve the tested contract;
`fix` means complete the listed audit before accepting release-wide correctness;
`demote` means replace numerical evidence's proof label, with regression tests.
An `open` decision is a release blocker and is **not yet implemented**.
`demoted` rows retain zero-count entries so the scope check catches reintroduced
proof labels. Their numerical findings remain enabled.
`scoped tests` records coverage from the recovery batches, not universal certification.

The inventory covers every explicit `MathematicalProof` reference in source
producer functions, including conditional labels. Enum/export/serialization
references are excluded. StructuralProof and dynamically constructed labels are
outside this lexical inventory; expanding to those labels is a separate audit.
A function can emit several findings, so reference counts are not finding counts.

Check scope drift with `python3 benchmarks/audit_proof_inventory.py`.
Test filenames below are under `test/`. Ordinary existing tests alone do not
close an adversarial audit. Changing a decision requires recording its premises,
independent oracle, feasible negative control, and unsupported-input behavior.

| Source | Producer | References | Decision | Status | Evidence / work remaining |
|---|---|---:|---|---|---|
| src/NLPDiagnostics.jl | `analyze_elastic_domain_guard_plan` | 0 | demote | demoted | final_producer_contracts.jl: public/manual plan records lack source-bound certificates; reports are heuristic. |
| src/analysis/activity.jl | `_active_set_findings` | 0 | demote | demoted | activity_evidence_contracts.jl: numerical residual/normal/gradient evidence; zero gradient remains LocalInference. |
| src/analysis/activity.jl | `_coupled_set_findings` | 0 | demote | demoted | activity_evidence_contracts.jl: numerical residual/normal/gradient evidence; zero gradient remains LocalInference. |
| src/analysis/activity.jl | `_coupled_set_tangent_findings` | 0 | demote | demoted | activity_evidence_contracts.jl: numerical residual/normal/gradient evidence; zero gradient remains LocalInference. |
| src/analysis/activity.jl | `_coupled_set_tangent_gradient_findings` | 0 | demote | demoted | activity_evidence_contracts.jl: numerical residual/normal/gradient evidence; zero gradient remains LocalInference. |
| src/analysis/derivatives.jl | `_derivative_issue_finding` | 1 | retain | scoped tests | interval_certification.jl |
| src/analysis/domains.jl | `_domain_issue_finding` | 1 | retain | scoped tests | interval_certification.jl |
| src/analysis/expressions.jl | `analyze_stable_reformulation_plan` | 0 | demote | demoted | final_producer_contracts.jl: public/manual plan records lack source-bound certificates; reports are heuristic. |
| src/analysis/initialization.jl | `_initialization_bound_findings` | 1 | retain | scoped tests | final_producer_contracts.jl; initialization_tolerance_contracts.jl; exact_static_rows.jl; certified_geometry_integration.jl. Finite points, typed supported expressions, validated sets, and exact evidence; tolerance changes severity only. |
| src/analysis/initialization.jl | `_initialization_quadratic_geometry_findings` | 1 | retain | scoped tests | certified_geometry_integration.jl |
| src/analysis/numerical.jl | `_operating_point_domain_findings` | 1 | retain | scoped tests | interval_certification.jl |
| src/analysis/static.jl | `_analyze_bounds!` | 4 | retain | scoped tests | bound_input_contracts.jl: declaration validation, structural roles, finite contradictions, exact integer witnesses, and evidence types. |
| src/analysis/static.jl | `_analyze_discrete_variables!` | 2 | retain | scoped tests | bound_input_contracts.jl: declaration validation, structural roles, finite contradictions, exact integer witnesses, and evidence types. |
| src/analysis/static.jl | `_analyze_constant_constraints!` | 2 | retain | scoped tests | scientific_contracts.jl; exact_static_rows.jl |
| src/analysis/static.jl | `_analyze_fixed_expression_constraints!` | 2 | retain | scoped tests | scientific_contracts.jl |
| src/analysis/static.jl | `_analyze_fixed_objective!` | 1 | retain | scoped tests | scientific_contracts.jl |
| src/analysis/static.jl | `_analyze_constant_objective!` | 1 | retain | scoped tests | exact_static_rows.jl |
| src/analysis/static.jl | `_analyze_nonzero_self_division!` | 1 | retain | scoped tests | branch_identity_contracts.jl |
| src/analysis/static.jl | `_analyze_nonzero_self_divisions!` | 2 | retain | scoped tests | branch_identity_contracts.jl |
| src/analysis/static.jl | `_analyze_unconstrained_affine_objective_rays!` | 1 | retain | scoped tests | objective_ray_contracts.jl |
| src/analysis/static.jl | `_analyze_unconstrained_quadratic_objective_rays!` | 1 | retain | scoped tests | objective_ray_contracts.jl |
| src/analysis/static.jl | `_analyze_sign_resolved_absolute_values!` | 2 | retain | scoped tests | branch_identity_contracts.jl |
| src/analysis/static.jl | `_analyze_bound_resolved_minmax!` | 2 | retain | scoped tests | branch_identity_contracts.jl |
| src/analysis/static.jl | `_analyze_absolute_zero_constraints!` | 5 | retain | scoped tests | range_semantic_contracts.jl; range_premise_contracts.jl; algebraic_range_contracts.jl. Analytic justifications: range_semantic_audit.md. |
| src/analysis/static.jl | `_analyze_sign_constraints!` | 2 | retain | scoped tests | range_semantic_contracts.jl; range_premise_contracts.jl; algebraic_range_contracts.jl. Analytic justifications: range_semantic_audit.md. |
| src/analysis/static.jl | `_analyze_exponential_range_constraints!` | 1 | retain | scoped tests | range_semantic_contracts.jl; range_premise_contracts.jl; algebraic_range_contracts.jl. Analytic justifications: range_semantic_audit.md. |
| src/analysis/static.jl | `_analyze_reciprocal_trigonometric_range_constraints!` | 1 | retain | scoped tests | range_semantic_contracts.jl; range_premise_contracts.jl; algebraic_range_contracts.jl. Analytic justifications: range_semantic_audit.md. |
| src/analysis/static.jl | `_analyze_atan2_range_constraints!` | 1 | retain | scoped tests | range_semantic_contracts.jl; range_premise_contracts.jl; algebraic_range_contracts.jl. Analytic justifications: range_semantic_audit.md. |
| src/analysis/static.jl | `_analyze_atan2_axis_angle_implications!` | 3 | retain | scoped tests | range_semantic_contracts.jl; range_premise_contracts.jl; algebraic_range_contracts.jl. Analytic justifications: range_semantic_audit.md. |
| src/analysis/static.jl | `_analyze_inverse_trigonometric_endpoint_implications!` | 2 | retain | scoped tests | range_semantic_contracts.jl; range_premise_contracts.jl; algebraic_range_contracts.jl. Analytic justifications: range_semantic_audit.md. |
| src/analysis/static.jl | `_analyze_hyperbolic_endpoint_implications!` | 2 | retain | scoped tests | range_semantic_contracts.jl; range_premise_contracts.jl; algebraic_range_contracts.jl. Analytic justifications: range_semantic_audit.md. |
| src/analysis/static.jl | `_analyze_elementary_reference_implications!` | 2 | retain | scoped tests | range_semantic_contracts.jl; range_premise_contracts.jl; algebraic_range_contracts.jl. Analytic justifications: range_semantic_audit.md. |
| src/analysis/static.jl | `_analyze_reciprocal_hyperbolic_range_constraints!` | 1 | retain | scoped tests | range_semantic_contracts.jl; range_premise_contracts.jl; algebraic_range_contracts.jl. Analytic justifications: range_semantic_audit.md. |
| src/analysis/static.jl | `_analyze_unary_operator_range_constraints!` | 1 | retain | scoped tests | range_semantic_contracts.jl; range_premise_contracts.jl; algebraic_range_contracts.jl. Analytic justifications: range_semantic_audit.md. |
| src/analysis/static.jl | `_analyze_dominated_affine_inequalities!` | 1 | retain | scoped tests | exact_static_rows.jl |
| src/analysis/static.jl | `_analyze_affine_equality_halfspace_consistency!` | 2 | retain | scoped tests | exact_static_rows.jl |
| src/analysis/static.jl | `_analyze_inconsistent_opposing_affine_inequalities!` | 1 | retain | scoped tests | exact_static_rows.jl |
| src/analysis/static.jl | `_analyze_affine_implied_variable_bounds!` | 2 | retain | scoped tests | certified_interval_arithmetic.jl |
| src/analysis/static.jl | `_analyze_affine_interval_propagation!` | 2 | retain | scoped tests | certified_interval_arithmetic.jl |
| src/analysis/static.jl | `_analyze_affine_interval_fixed_point!` | 3 | retain | scoped tests | certified_interval_arithmetic.jl |
| src/analysis/static.jl | `_analyze_reused_constraint_expressions!` | 2 | retain | scoped tests | final_producer_contracts.jl; exact_static_rows.jl; certified_geometry_integration.jl. Finite points, typed supported expressions, validated sets, and exact evidence. |
| src/analysis/static.jl | `_analyze_diagonal_quadratic_upper_bounds!` | 6 | retain | scoped tests | certified_quadratic_geometry.jl |
| src/analysis/static.jl | `_analyze_circular_normalization!` | 6 | retain | scoped tests | certified_quadratic_geometry.jl |
| src/analysis/static.jl | `_analyze_ellipsoidal_normalization!` | 6 | retain | scoped tests | certified_quadratic_geometry.jl |

## Disposition of the finite inventory

All 44 inventoried producer functions now have a disposition: 38 retain rows
with scoped tests and six completed demotions. There are no open rows in this
lexical inventory. The zero-reference demotion records are retained to catch
reintroduced proof labels.

The retained contracts and their scope are described in recovery_plan.md and
range_semantic_audit.md; cited regressions cover the repaired paths. This does
not prove every implementation path correct. StructuralProof, dynamically
constructed labels, callback semantics, and whole-pipeline provenance are not
certified by this inventory. Audit scope must expand if those surfaces change.

The next release work is reproducibility and the executable power-system repair
pilot. Do not interpret an empty audit queue or a passing test count as measured
application usefulness.
