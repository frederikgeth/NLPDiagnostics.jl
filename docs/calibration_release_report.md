# Calibration release report

This report is generated from `docs/calibration_release_gate_summary.json`. It separates bounded evidence from release blockers and does not promote local observations into causal or physical claims.

## Release status

- Project phase: `consolidate_and_calibrate`
- Release ready: `false`
- Blocking gates: `4`

## Gate ledger

| Gate | Status | Blocking |
| --- | --- | --- |
| `30bus_ibr_bounded_calibration` | PASS | `false` |
| `real_99bus_solver_completion` | PASS | `false` |
| `real_99bus_physical_kkt` | PARTIAL | `true` |
| `real_99bus_covariance` | PASS | `false` |
| `numerical_rank_false_positive_negative_statistics` | PARTIAL | `true` |
| `runtime_memory_scaling` | PARTIAL | `true` |
| `api_test_benchmark_consolidation` | PARTIAL | `true` |

## Evidence and blockers

### `PASS` — `30bus_ibr_bounded_calibration`

Bounded 30-bus IBR evidence now covers endpoint, trajectory, options, initialization, geometry, derivatives, scaling, bounds, and tolerance margins; it remains research-qualified rather than causal.

Evidence:
- [`docs/bmopf_30bus_ibr_p_upper_tolerance_margin_summary.json`](docs/bmopf_30bus_ibr_p_upper_tolerance_margin_summary.json)
- [`docs/bmopf_30bus_ibr_p_upper_sparse_jacobian_audit_summary.json`](docs/bmopf_30bus_ibr_p_upper_sparse_jacobian_audit_summary.json)

### `PASS` — `real_99bus_solver_completion`

All six reference and phase-only real 99-bus runs are locally solved in the bounded campaign.

Evidence:
- [`docs/real_99bus_phase_only_campaign_summary.json`](docs/real_99bus_phase_only_campaign_summary.json)

### `PARTIAL` — `real_99bus_physical_kkt`

Physical KKT is available on all six runs but only 2/6 reference and 2/6 phase-only endpoints pass the strict 1e-5 gate; failure localization is complete.

Evidence:
- [`docs/real_99bus_phase_only_campaign_summary.json`](docs/real_99bus_phase_only_campaign_summary.json)
- [`docs/real_99bus_phase_only_kkt_failure_summary.json`](docs/real_99bus_phase_only_kkt_failure_summary.json)

### `PASS` — `real_99bus_covariance`

All six phase-only transformations pass the seven available covariance checks and scalar-set transport; physical rank and inequality-multiplier covariance remain unavailable or out of scope.

Evidence:
- [`docs/real_99bus_phase_only_covariance_summary.json`](docs/real_99bus_phase_only_covariance_summary.json)

### `PARTIAL` — `numerical_rank_false_positive_negative_statistics`

The seeded 27-record corpus has zero hard-control false positives, false negatives, or unavailable backend results, with four expected threshold-cluster disagreements. A guarded 20-record sparse corpus at dimensions 128--1024 adds zero sparse mismatches or unavailable results while intentionally disabling dense SVD; broader adversarial and cross-backend statistics remain open.

Evidence:
- [`docs/randomized_rank_oracle_calibration_summary.json`](docs/randomized_rank_oracle_calibration_summary.json)
- [`docs/large_sparse_rank_oracle_summary.json`](docs/large_sparse_rank_oracle_summary.json)

### `PARTIAL` — `runtime_memory_scaling`

The synthetic sparse ladder now provides 12 warm-up-aware runtime/allocation records across four dimensions; process high-water marks are retained descriptively, but OPF-solver scaling and isolated peak-memory measurements remain open.

Evidence:
- [`docs/sparse_runtime_memory_scaling_summary.json`](docs/sparse_runtime_memory_scaling_summary.json)

### `PARTIAL` — `api_test_benchmark_consolidation`

The consolidation audit now inventories 539 root exports, 113 root testsets across nine included test modules, 109 benchmark scripts, and complete schema coverage for 49 JSON artifacts. A typed unavailable-reason schema now covers solver telemetry, dual/complementarity boundaries, profile reports, solver-result point and postmortem capability reports, active-set multiplier-recovery, MFCQ screen, and Jacobian-rank work guards, generic and BMOPFTools component-rank capability reports, BMOPFTools differentiability capability reports, PowerModels scalar-angle capability reports, MadNLP primal-capture capability reports, BMOPFTools terminal-current capability reports, BMOPFTools passive-network map capability reports, and BMOPFTools terminal-attachment capability reports; non-breaking Stable and Advanced facades, shared benchmark helper, and reviewed local quality policy are also available. 106 data-producing runners use the helper, with infrastructure-script exemptions explicitly inventoried. The active BMOPFTools API contract audit is fail (missing: OpfDiagnosticSchema, opf_diagnostic_schema), while the clean-main contract audit is pass at revision 8f121216065bcd692f18444836c7c80149e5cf4a and the full local suite passes 1634/1634 there. The PR handoff gate is blocked (the active BMOPFTools checkout does not satisfy the consumed API contract). The isolated checkout validator is pass at revision 8f121216065bcd692f18444836c7c80149e5cf4a with suite coverage 1634/1634. Remaining work is review of Stable versus Advanced boundaries, broader adapter adoption, root-export tiering, keeping dependency evidence synchronized, and activation of deferred documentation-example, Aqua, and targeted JET checks when reviewed environments are available.

Evidence:
- [`docs/api_test_benchmark_consolidation_summary.json`](docs/api_test_benchmark_consolidation_summary.json)
- [`docs/bmopf_api_contract_summary.json`](docs/bmopf_api_contract_summary.json)
- [`docs/bmopf_api_contract_clean_main_summary.json`](docs/bmopf_api_contract_clean_main_summary.json)
- [`docs/bmopf_pr_handoff_summary.json`](docs/bmopf_pr_handoff_summary.json)
- [`docs/bmopf_checkout_validation_summary.json`](docs/bmopf_checkout_validation_summary.json)

## Review boundary

A partial or blocked gate is not a failed scientific result; it marks evidence that is unavailable, incomplete, or not yet release-qualified.

