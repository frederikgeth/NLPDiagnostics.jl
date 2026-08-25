# Calibration release report

This report is generated from `docs/calibration_release_gate_summary.json`. It separates bounded evidence from release blockers and does not promote local observations into causal or physical claims.

## Release status

- Project phase: `consolidate_and_calibrate`
- Release ready: `false`
- Blocking gates: `5`

## Gate ledger

| Gate | Status | Blocking |
| --- | --- | --- |
| `30bus_ibr_bounded_calibration` | PASS | `false` |
| `real_99bus_solver_completion` | PASS | `false` |
| `real_99bus_physical_kkt` | PARTIAL | `true` |
| `real_99bus_covariance` | PASS | `false` |
| `numerical_rank_false_positive_negative_statistics` | PARTIAL | `true` |
| `runtime_memory_scaling` | PARTIAL | `true` |
| `analyze_runtime_scaling` | PARTIAL | `true` |
| `combined_mv_lv_scaling_start_robustness` | PASS | `false` |
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

Physical KKT is available on all six runs but only 2/6 reference and 2/6 phase-only endpoints pass the strict 1e-5 gate. The joined stability ledger has 14 complete solver-floor-qualified profiles (excluding 6 incomplete profiles), and strict acceptance remains stable at 2/6 across those profiles; failure localization is complete. The per-snapshot margin ledger records 4 strict-failing snapshots and a maximum required tolerance of 1.141720164003029e-5 (gap 1.4172016400302888e-6); it quantifies the boundary without relaxing the gate. The paired residual-distribution ledger shows reference/phase-only maximum-residual ratios of [0.9999998824400804, 1.0000001437911095], so the observed strict failures are not explained by a material phase-only residual inflation in this saved campaign.

Evidence:
- [`docs/real_99bus_phase_only_campaign_summary.json`](docs/real_99bus_phase_only_campaign_summary.json)
- [`docs/real_99bus_phase_only_kkt_failure_summary.json`](docs/real_99bus_phase_only_kkt_failure_summary.json)
- [`docs/real_99bus_kkt_stability_summary.json`](docs/real_99bus_kkt_stability_summary.json)
- [`docs/real_99bus_kkt_margin_summary.json`](docs/real_99bus_kkt_margin_summary.json)
- [`docs/real_99bus_kkt_residual_distribution_summary.json`](docs/real_99bus_kkt_residual_distribution_summary.json)

### `PASS` — `real_99bus_covariance`

All six phase-only transformations pass the seven available covariance checks and scalar-set transport; physical rank and inequality-multiplier covariance remain unavailable or out of scope.

Evidence:
- [`docs/real_99bus_phase_only_covariance_summary.json`](docs/real_99bus_phase_only_covariance_summary.json)

### `PARTIAL` — `numerical_rank_false_positive_negative_statistics`

The aggregate rank-statistics ledger now joins 43 complete hard controls with 0 mismatches and 0 unavailable results, plus 24 threshold-sensitive controls with 9 backend disagreements. This includes the seeded randomized and controlled perturbation corpora; disagreements remain tolerance evidence. A guarded sparse-only extension contributes 20 records with 0 sparse mismatches while intentionally disabling dense SVD. Broader adversarial and cross-backend statistics remain open.

Evidence:
- [`docs/randomized_rank_oracle_calibration_summary.json`](docs/randomized_rank_oracle_calibration_summary.json)
- [`docs/large_sparse_rank_oracle_summary.json`](docs/large_sparse_rank_oracle_summary.json)
- [`docs/rank_perturbation_sweep_summary.json`](docs/rank_perturbation_sweep_summary.json)
- [`docs/rank_calibration_statistics_summary.json`](docs/rank_calibration_statistics_summary.json)

### `PARTIAL` — `runtime_memory_scaling`

The synthetic sparse ladder provides 12 warm-up-aware runtime/allocation records across 4 dimensions, and an isolated child-process ladder adds 15 records across 5 dimensions with per-dimension Sys.maxrss high-water observations. The companion trend ledger covers 3 workloads; descriptive runtime log-log slopes range from 1.381 to 1.903, with stage attribution retained per workload. OPF-solver scaling and allocator-level peak-memory measurements remain open.

Evidence:
- [`docs/sparse_runtime_memory_scaling_summary.json`](docs/sparse_runtime_memory_scaling_summary.json)
- [`docs/sparse_runtime_memory_isolated_summary.json`](docs/sparse_runtime_memory_isolated_summary.json)
- [`docs/sparse_runtime_trend_summary.json`](docs/sparse_runtime_trend_summary.json)

### `PARTIAL` — `analyze_runtime_scaling`

The public point-free analyze(model) entry point now has a bounded sparse affine-chain measurement. The observed cost grows from 0.885s at dimension 100 to 13.522s at dimension 400 across 3 repetition(s), with affine propagation reaching its configured five-pass limit. Finding evidence is stable across repetitions: true. The trend ledger records adjacent affine growth ratios [3.888, 3.931] and descriptive log-log slopes 1.959--1.975; these are bounded-fixture observations, not a complexity law. Stage attribution is now recorded; the largest measured stage at the largest dimension is static (3.507s). A second sparse nonlinear workload is also measured, reaching 0.168s at dimension 400 with stable evidence true, with trend slopes 0.988--1.007. Process-memory telemetry is retained under this boundary: Sys.maxrss process high-water mark; per-run increments are descriptive and not isolated peak-memory certificates. The bounded BMOPFTools adapter profile measured 3 case(s) and size-guarded 2 case(s), retaining PowerIO warning provenance with per-case warmup=true. The current evidence-preserving optimization is: analyze_domains reuses one propagated variable-interval state for both issue detection and interval-origin provenance. Portable scaling and further optimization remain open.

Evidence:
- [`docs/analyze_runtime_scaling_summary.json`](docs/analyze_runtime_scaling_summary.json)
- [`docs/analyze_runtime_trend_summary.json`](docs/analyze_runtime_trend_summary.json)
- [`docs/bmopf_analyze_runtime_profile_summary.json`](docs/bmopf_analyze_runtime_profile_summary.json)

### `PASS` — `combined_mv_lv_scaling_start_robustness`

The authoritative BMOPFTools combined MV+LV source now has bounded, endpoint-gated evidence across LV1_14bus and LV13_58bus. Ipopt and MadNLP matched-start campaigns pass the declared physical and cross-policy gates under tolerance 1e-10 and max_iter 10; global affine and voltage-only start matrices also pass. The evidence qualifies procedure repeatability and provenance coverage, not a universal scaling policy, solver superiority, or causal mechanism.

Evidence:
- [`docs/bmopf_combined_mv_lv_scaling_readiness_summary.json`](docs/bmopf_combined_mv_lv_scaling_readiness_summary.json)
- [`docs/bmopf_combined_mv_lv_scaling_campaign_summary.json`](docs/bmopf_combined_mv_lv_scaling_campaign_summary.json)
- [`docs/bmopf_combined_mv_lv_snapshot_campaign_summary.json`](docs/bmopf_combined_mv_lv_snapshot_campaign_summary.json)
- [`benchmarks/bmopf_combined_mv_lv_snapshot_campaign.jl`](benchmarks/bmopf_combined_mv_lv_snapshot_campaign.jl)
- [`benchmarks/bmopf_combined_mv_lv_perturbed_start_campaign.jl`](benchmarks/bmopf_combined_mv_lv_perturbed_start_campaign.jl)

### `PARTIAL` — `api_test_benchmark_consolidation`

The consolidation audit now inventories 553 root exports, 114 root testsets across nine included test modules, 125 benchmark scripts, and complete schema coverage for 66 JSON artifacts. A typed unavailable-reason schema now covers solver telemetry, dual/complementarity boundaries, profile reports, solver-result point and postmortem capability reports, active-set multiplier-recovery, MFCQ screen, dense/sparse Jacobian rank backends, sparse-QR nullspace extraction, dense calibration, persistence, Golub--Kahan and restarted smallest-singular probe/calibration boundaries, Jacobian tolerance-sweep and condition-persistence boundaries, Jacobian scaling, derivative-provenance, rank-persistence, row-family perturbation, iterative right/left candidate-persistence, persistence coordinate-alignment, top-level condition/rank/reduced-Hessian coordinate, reduced-Hessian Jacobian-scaling alignment, component-port coordinate-map, coordinate-semantics, mode-projection, connection, nullspace-mode alignment, nullspace-mode semantics, topology-projection, nominal-scale projection, coupled-constraint scale alignment, scalar-constraint scale alignment, component metadata scope, component-port metadata scope, constitutive-map validation, and topology-nullspace endpoints, Jacobian expected-mode and expected-mode-span persistence, reduced-Hessian flat-subspace, active-row and active-Jacobian persistence, multiplier-persistence, reduced-Hessian expected-mode persistence, Jacobian-scaling, spectral-scale, and persistent reduced-Hessian structural-scope boundaries, restarted and harmonic smallest-singular calibration/crosscheck boundaries, structural-matching, DM-partition, reduced-Hessian, structural-to-numerical rank-comparison, and iterative right/left/spectrum probe work/capability guards, coupled-set qualification capability boundaries, generic and BMOPFTools component-rank capability reports, BMOPFTools differentiability capability reports, PowerModels scalar-angle capability reports, MadNLP primal-capture capability reports, BMOPFTools terminal-current capability reports, BMOPFTools passive-network map capability reports, and BMOPFTools terminal-attachment capability reports; non-breaking Stable and Advanced facades, shared benchmark helper, and reviewed local quality policy are also available. The tier review ledger now assigns all 539 root-only exports a disposition: 102 Advanced candidates and 437 manual legacy reviews. Usage triage finds 423 root-only names referenced by tests or benchmarks and 4 names unreferenced in repository code; priority buckets are 133 test-plus-benchmark, 280 test-only, 10 benchmark-only, and 112 source-only. 122 data-producing runners use the helper, with infrastructure-script exemptions explicitly inventoried. The active BMOPFTools API contract audit is pass, while the clean-main contract audit is pass at revision 7a902e914b8148043aba96e0f10c34c74650b9cb and the known local benchmark environment validates the checkout with suite coverage 1801/1801. The PR handoff gate is pass (the active BMOPFTools checkout matches the validated clean-main contract). The local checkout validator is pass at revision 7a902e914b8148043aba96e0f10c34c74650b9cb. Temporary-environment bootstrap remains unavailable under managed registry permissions; this is a known-environment validation artifact. Remaining work is review of Stable versus Advanced boundaries, broader adapter adoption, root-export tiering, keeping dependency evidence synchronized, and activation of deferred documentation-example, Aqua, and targeted JET checks when reviewed environments are available.

Evidence:
- [`docs/api_test_benchmark_consolidation_summary.json`](docs/api_test_benchmark_consolidation_summary.json)
- [`docs/bmopf_api_contract_summary.json`](docs/bmopf_api_contract_summary.json)
- [`docs/bmopf_api_contract_clean_main_summary.json`](docs/bmopf_api_contract_clean_main_summary.json)
- [`docs/bmopf_pr_handoff_summary.json`](docs/bmopf_pr_handoff_summary.json)
- [`docs/bmopf_checkout_validation_summary.json`](docs/bmopf_checkout_validation_summary.json)
- [`docs/api_tier_usage_summary.json`](docs/api_tier_usage_summary.json)

## Review boundary

A partial or blocked gate is not a failed scientific result; it marks evidence that is unavailable, incomplete, or not yet release-qualified.

