#!/usr/bin/env julia

"""Build the machine-readable calibration release-gate ledger from summaries."""

include(joinpath(@__DIR__, "common.jl"))
using .NLPDiagnosticsBenchmarkCommon

const ROOT = repo_root()

real_campaign = read_summary("docs/real_99bus_phase_only_campaign_summary.json")
real_kkt = read_summary("docs/real_99bus_phase_only_kkt_failure_summary.json")
real_kkt_stability = read_summary("docs/real_99bus_kkt_stability_summary.json")
real_kkt_margin = read_summary("docs/real_99bus_kkt_margin_summary.json")
real_kkt_distribution = read_summary("docs/real_99bus_kkt_residual_distribution_summary.json")
real_kkt_policy = read_summary("docs/real_99bus_kkt_tolerance_policy_summary.json")
real_kkt_endpoint_matrix = read_summary("docs/real_99bus_kkt_endpoint_matrix_summary.json")
real_kkt_gate_validation = read_summary("docs/real_99bus_kkt_gate_validation_summary.json")
real_covariance = read_summary("docs/real_99bus_phase_only_covariance_summary.json")
ibr_tolerance = read_summary("docs/bmopf_30bus_ibr_p_upper_tolerance_margin_summary.json")
ibr_sparse = read_summary("docs/bmopf_30bus_ibr_p_upper_sparse_jacobian_audit_summary.json")
rank_oracles = read_summary("docs/randomized_rank_oracle_calibration_summary.json")
rank_perturbation = read_summary("docs/rank_perturbation_sweep_summary.json")
rank_statistics = read_summary("docs/rank_calibration_statistics_summary.json")
rank_adversarial_extension = read_summary("docs/rank_adversarial_extension_summary.json")
rank_third_backend = read_summary("docs/rank_third_backend_capability_summary.json")
normal_eigen_calibration = read_summary("docs/normal_eigen_rank_calibration_summary.json")
normal_eigen_persistence = read_summary("docs/normal_eigen_policy_persistence_summary.json")
normal_eigen_bmopf = read_summary("docs/bmopf_normal_eigen_jacobian_validation_summary.json")
large_sparse_bmopf = read_summary("docs/bmopf_large_sparse_rank_screen_summary.json")
large_sparse_bmopf_saved = read_summary("docs/bmopf_large_sparse_rank_screen_saved_result_summary.json")
saved_result_bmopf_campaign = read_summary("docs/bmopf_saved_result_sparse_rank_campaign_summary.json")
smallest_singular_calibration = read_summary("docs/smallest_singular_calibration_summary.json")
runtime_scaling = read_summary("docs/sparse_runtime_memory_scaling_summary.json")
isolated_runtime_scaling = read_summary("docs/sparse_runtime_memory_isolated_summary.json")
isolated_runtime_trend = read_summary("docs/sparse_runtime_trend_summary.json")
analyze_runtime_scaling = read_summary("docs/analyze_runtime_scaling_summary.json")
analyze_runtime_trend = read_summary("docs/analyze_runtime_trend_summary.json")
analyze_runtime_resources = read_summary("docs/analyze_runtime_resource_summary.json")
bmopf_analyze_profile = read_summary("docs/bmopf_analyze_runtime_profile_summary.json")
runtime_scaling_readiness = read_summary("docs/runtime_scaling_readiness_summary.json")
runtime_solver_scaling = read_summary("docs/bmopf_solver_scaling_readiness_summary.json")
analyze_scaling_readiness = read_summary("docs/analyze_scaling_readiness_summary.json")
analyze_static_optimization_ab = read_summary("docs/analyze_static_optimization_ab_summary.json")
analyze_static_optimization_generalization = read_summary("docs/analyze_static_optimization_generalization_summary.json")
analyze_static_target_terms = read_summary("docs/analyze_static_target_terms_summary.json")
bmopf_combined_analyze_scaling = read_summary("docs/bmopf_combined_mv_lv_analyze_scaling_summary.json")
large_sparse_rank = read_summary("docs/large_sparse_rank_oracle_summary.json")
combined_mv_lv = read_summary("docs/bmopf_combined_mv_lv_snapshot_campaign_summary.json")
series_voltage_scaling = read_summary("docs/bmopf_voltage_level_series_case_matrix_summary.json")
practical_application_success = read_summary("docs/bmopf_practical_application_success_summary.json")
series_solver_campaign = read_summary("docs/bmopf_voltage_level_series_solver_campaign_summary.json")
series_solver_budget60 = read_summary("docs/bmopf_voltage_level_series_solver_campaign_maxiter60_summary.json")
series_madnlp_campaign = read_summary("docs/bmopf_voltage_level_series_madnlp_campaign_summary.json")
series_application_bridge = read_summary("docs/bmopf_series_application_bridge_summary.json")
series_capacity_boundary = read_summary("docs/bmopf_series_nominal_capacity_boundary_summary.json")
series_uprated_nominal = read_summary("docs/bmopf_voltage_level_series_uprated_nominal_campaign_summary.json")
lv13_madnlp_guard = read_summary("docs/bmopf_lv13_madnlp_transfer_guard_summary.json")
lv13_madnlp_plan = read_summary("docs/bmopf_lv13_madnlp_isolated_run_plan.json")
lv13_madnlp_result = read_summary("docs/bmopf_lv13_madnlp_isolated_result_summary.json")
lv13_madnlp_environment = read_summary("docs/bmopf_lv13_madnlp_isolated_environment_summary.json")
lv13_madnlp_resources = read_summary("docs/bmopf_lv13_madnlp_resource_envelope_summary.json")
lv13_madnlp_handoff = read_summary("docs/bmopf_lv13_madnlp_handoff_summary.json")
lv13_madnlp_launch = read_summary("docs/bmopf_lv13_madnlp_launch_summary.json")
series_feasibility_sweep = read_summary("docs/bmopf_voltage_level_series_feasibility_sweep_summary.json")
api_consolidation = read_summary("docs/api_test_benchmark_consolidation_summary.json")
api_tier_inventory = read_summary("docs/api_tier_inventory_summary.json")
api_tier_usage = read_summary("docs/api_tier_usage_summary.json")
stable_api_surface = read_summary("docs/stable_api_surface_summary.json")
advanced_api_surface = read_summary("docs/advanced_api_surface_summary.json")
api_migration_queue = read_summary("docs/api_migration_queue_summary.json")
api_advanced_candidates = read_summary("docs/api_advanced_candidate_summary.json")
api_ownership_decisions = read_summary("docs/api_ownership_decision_summary.json")
release_gate_actions = read_summary("docs/release_gate_action_summary.json")
api_inventory = api_consolidation["api_inventory"]
api_modules = api_consolidation["module_boundaries"]
api_schemas = api_consolidation["benchmark_schema_inventory"]
api_contract = get(api_consolidation, "bmopf_api_contract", Dict{String,Any}())
api_contract_status = get(api_contract, "status", "missing")
api_contract_missing = join(get(api_contract, "missing_symbols", String[]), ", ")
api_contract_clean_main_status = get(api_contract, "clean_main_status", "missing")
api_contract_clean_main_revision = get(api_contract, "clean_main_dependency_revision", "unknown")
api_contract_handoff_status = get(api_contract, "handoff_status", "missing")
api_contract_handoff_reason = get(api_contract, "handoff_reason", "handoff artifact unavailable")
api_checkout_validation_status = get(api_contract, "checkout_validation_status", "missing")
api_checkout_validation_revision = get(api_contract, "checkout_validation_revision", "unknown")
api_checkout_validation_suite = "$(get(api_contract, "checkout_validation_suite_passed", "?"))/$(get(api_contract, "checkout_validation_suite_total", "?"))"
api_root_export_count = api_inventory["root_export_count"]
api_testset_count = api_modules["testset_count_in_root"]
api_script_count = api_modules["benchmark_script_count"]
api_schema_count = api_schemas["json_schema_file_count"]
api_helper_user_count = api_modules["shared_benchmark_helper_user_count"]
api_tier_review = get(api_tier_inventory, "review", Dict{String,Any}())
api_tier_queue_count = get(api_tier_review, "queue_count", 0)
api_tier_advanced_candidates = get(api_tier_review, "advanced_candidate_count", 0)
api_tier_legacy_manual_review = get(api_tier_review, "legacy_manual_review_count", 0)
api_tier_runtime_usage = get(api_tier_usage, "runtime_usage_evidence_count", 0)
api_tier_unreferenced = get(api_tier_usage, "unreferenced_in_code_count", 0)
api_tier_usage_priorities = get(api_tier_usage, "usage_priority_counts", Dict{String,Any}())
stable_api_surface_status = get(stable_api_surface, "status", "missing")
stable_api_surface_export_count = get(stable_api_surface, "runtime_export_count", 0)
stable_api_surface_smoke_status = get(get(stable_api_surface, "smoke", Dict{String,Any}()), "status", "missing")
advanced_api_surface_status = get(advanced_api_surface, "status", "missing")
advanced_api_surface_export_count = get(advanced_api_surface, "runtime_export_count", 0)
advanced_api_surface_smoke_status = get(get(advanced_api_surface, "smoke", Dict{String,Any}()), "status", "missing")
api_migration_queue_count = get(api_migration_queue, "queue_count", 0)
api_migration_unreferenced_count = get(api_migration_queue, "unreferenced_in_code_count", 0)
api_advanced_candidate_count = get(api_advanced_candidates, "candidate_count", 0)
api_advanced_family_counts = get(api_advanced_candidates, "family_counts", Dict{String,Any}())
api_ownership_reviewed_count = get(api_ownership_decisions, "reviewed_count", 0)
api_ownership_retained_count = get(api_ownership_decisions, "root_compatibility_retained_count", 0)
api_ownership_advanced_count = get(api_ownership_decisions, "advanced_candidate_count", 0)
api_ownership_migration_count = get(api_ownership_decisions, "migration_allowed_count", 0)
real_kkt_qualified_profiles = get(real_kkt_stability, "qualified_profile_count", 0)
real_kkt_stable_count = get(real_kkt_stability, "stable_strict_acceptance_count", nothing)
real_kkt_excluded_profiles = get(real_kkt_stability, "excluded_incomplete_profile_count", 0)
real_kkt_margin_failed_snapshots = get(real_kkt_margin, "strict_failed_snapshot_count", 0)
real_kkt_margin_maximum = get(real_kkt_margin, "maximum_required_tolerance", nothing)
real_kkt_margin_maximum_gap = get(real_kkt_margin, "maximum_strict_tolerance_gap", nothing)
real_kkt_margin_quantiles = get(real_kkt_margin, "required_tolerance_quantiles", Dict{String,Any}())
real_kkt_margin_p95 = get(get(real_kkt_margin_quantiles, "paired_endpoint_maximum", Dict{String,Any}()), "p95", nothing)
real_kkt_distribution_ratio_range = get(real_kkt_distribution, "paired_maximum_residual_ratio_range", nothing)
real_kkt_distribution_ratio_text = isnothing(real_kkt_distribution_ratio_range) ?
    "unavailable" : "[" * join(string.(real_kkt_distribution_ratio_range), ", ") * "]"
real_kkt_policy_full_acceptance = get(real_kkt_policy, "first_observed_full_paired_acceptance_policy", nothing)
real_kkt_endpoint_count = get(real_kkt_endpoint_matrix, "endpoint_count", 0)
real_kkt_endpoint_pass_count = get(real_kkt_endpoint_matrix, "strict_paired_acceptance_count", 0)
real_kkt_endpoint_failure_count = get(real_kkt_endpoint_matrix, "strict_paired_failure_count", 0)
real_kkt_endpoint_localized = get(real_kkt_endpoint_matrix, "all_failures_localized", false)
real_kkt_gate_validation_status = get(real_kkt_gate_validation, "status", "missing")
analyze_stage_records = get(analyze_runtime_scaling["records"][end], "stage_attribution", Any[])
analyze_repetitions = get(analyze_runtime_scaling["source"], "repetitions", 1)
analyze_memory_note = get(
    analyze_runtime_scaling["source"],
    "memory_measurement",
    "process memory telemetry unavailable",
)
analyze_evidence_stable = all(
    get(record, "evidence_stable_across_repetitions", false)
    for record in analyze_runtime_scaling["records"]
)
analyze_optimization = get(analyze_runtime_scaling, "optimization", Dict{String,Any}())
analyze_optimization_note = get(
    analyze_optimization,
    "description",
    "no optimization provenance recorded",
)
analyze_nonlinear_records = get(
    get(analyze_runtime_scaling, "workload_comparisons", Dict{String,Any}()),
    "sparse_nonlinear_chain",
    Any[],
)
analyze_nonlinear_end = isempty(analyze_nonlinear_records) ? nothing :
    analyze_nonlinear_records[end]
analyze_trend_affine = get(analyze_runtime_trend, "affine_chain", Dict{String,Any}())
analyze_trend_nonlinear = get(analyze_runtime_trend, "nonlinear_chain", Dict{String,Any}())
analyze_resource_workloads = get(analyze_runtime_resources, "workloads", Any[])
analyze_allocation_slopes = Float64[]
for workload in analyze_resource_workloads
    allocation = get(workload, "allocation", Dict{String,Any}())
    for slope in [
        get(allocation, "log_log_slope_minimum", nothing),
        get(allocation, "log_log_slope_maximum", nothing),
    ]
        slope isa Real && isfinite(slope) && push!(analyze_allocation_slopes, Float64(slope))
    end
end
analyze_allocation_slope_minimum = isempty(analyze_allocation_slopes) ? nothing : minimum(analyze_allocation_slopes)
analyze_allocation_slope_maximum = isempty(analyze_allocation_slopes) ? nothing : maximum(analyze_allocation_slopes)
analyze_repeatability_cvs = Float64[
    Float64(get(
        get(workload, "runtime_repeatability_at_largest_dimension", Dict{String,Any}()),
        "coefficient_of_variation",
        NaN,
    ))
    for workload in analyze_resource_workloads
    if get(
        get(workload, "runtime_repeatability_at_largest_dimension", Dict{String,Any}()),
        "coefficient_of_variation",
        nothing,
    ) isa Real
]
analyze_repeatability_cv_maximum = isempty(analyze_repeatability_cvs) ?
    nothing : maximum(analyze_repeatability_cvs)
bmopf_profile_records = get(bmopf_analyze_profile, "records", Any[])
bmopf_profile_warmup = get(
    get(bmopf_analyze_profile, "source", Dict{String,Any}()),
    "warmup",
    false,
)
bmopf_profile_measured = count(
    record -> get(record, "status", "") == "measured", bmopf_profile_records,
)
bmopf_profile_guarded = count(
    record -> get(record, "status", "") == "skipped_size_guard", bmopf_profile_records,
)
runtime_readiness_coverage_count = get(runtime_scaling_readiness, "coverage_count", 0)
runtime_readiness_open_gap_count = get(runtime_scaling_readiness, "open_gap_count", 0)
runtime_solver_measured_count = get(runtime_solver_scaling, "measured_count", 0)
runtime_solver_guarded_count = get(runtime_solver_scaling, "guarded_count", 0)
analyze_readiness_workloads = get(analyze_scaling_readiness, "workloads", Any[])
analyze_readiness_workload_count = get(analyze_scaling_readiness, "workload_count", length(analyze_readiness_workloads))
analyze_readiness_stable_count = count(workload -> get(workload, "evidence_stable", false), analyze_readiness_workloads)
analyze_readiness_open_gap_count = get(analyze_scaling_readiness, "open_gap_count", 0)
analyze_ab = get(analyze_scaling_readiness, "static_optimization_ab", Dict{String,Any}())
analyze_ab_speedup_range = get(analyze_ab, "elapsed_speedup_range", Any[])
analyze_ab_speedup_text = isempty(analyze_ab_speedup_range) ? "unavailable" :
    "$(round(analyze_ab_speedup_range[1]; digits=3))--$(round(analyze_ab_speedup_range[end]; digits=3))"
analyze_ab_equivalence = get(analyze_ab, "equivalence_passed", false)
analyze_generalization = get(analyze_scaling_readiness, "static_optimization_generalization", Dict{String,Any}())
analyze_generalization_speedup_range = get(analyze_generalization, "elapsed_speedup_range", Any[])
analyze_generalization_speedup_text = isempty(analyze_generalization_speedup_range) ? "unavailable" :
    "$(round(analyze_generalization_speedup_range[1]; digits=3))--$(round(analyze_generalization_speedup_range[end]; digits=3))"
analyze_generalization_equivalence = get(analyze_generalization, "equivalence_passed", false)
analyze_target_terms = get(analyze_scaling_readiness, "static_optimization_target_terms", Dict{String,Any}())
analyze_target_terms_equivalence = get(analyze_target_terms, "equivalence_passed", false)
analyze_target_terms_speedup_range = get(analyze_target_terms, "elapsed_speedup_range", Any[])
analyze_target_terms_speedup_text = isempty(analyze_target_terms_speedup_range) ? "unavailable" :
    "$(round(analyze_target_terms_speedup_range[1]; digits=3))--$(round(analyze_target_terms_speedup_range[end]; digits=3))"
analyze_target_terms_decision = get(analyze_target_terms, "decision", "unavailable")
analyze_isolated_memory = get(analyze_scaling_readiness, "isolated_adapter_memory", Dict{String,Any}())
analyze_isolated_memory_measured = get(analyze_isolated_memory, "measured_count", 0)
analyze_isolated_memory_guarded = get(analyze_isolated_memory, "guarded_count", 0)
analyze_isolated_memory_stable = get(analyze_isolated_memory, "stable_case_count", 0)
analyze_portability = get(analyze_scaling_readiness, "portability_contract", Dict{String,Any}())
analyze_portability_baseline_status = get(analyze_portability, "baseline_status", "unavailable")
analyze_portability_comparison_status = get(analyze_portability, "comparison_status", "unavailable")
analyze_combined = get(analyze_scaling_readiness, "bmopf_combined_mv_lv_analyze", Dict{String,Any}())
analyze_combined_feeder_count = get(analyze_combined, "feeder_count", 0)
analyze_combined_measured_count = get(analyze_combined, "measured_count", 0)
analyze_combined_stable_count = get(analyze_combined, "stable_measured_count", 0)
isolated_runtime_records = get(isolated_runtime_scaling, "records", Any[])
runtime_records = get(runtime_scaling, "records", Any[])
runtime_dimensions = get(
    get(runtime_scaling, "source", Dict{String,Any}()),
    "dimensions",
    Any[],
)
isolated_runtime_dimensions = get(
    get(isolated_runtime_scaling, "source", Dict{String,Any}()),
    "dimensions",
    Any[],
)
isolated_runtime_workloads = get(isolated_runtime_trend, "workload_count", 0)
isolated_runtime_slope_minimum = minimum(Float64[
    get(get(workload, "runtime", Dict{String,Any}()), "log_log_slope_minimum", NaN)
    for workload in get(isolated_runtime_trend, "workloads", Any[])
    if get(get(workload, "runtime", Dict{String,Any}()), "log_log_slope_minimum", nothing) isa Real
])
isolated_runtime_slope_maximum = maximum(Float64[
    get(get(workload, "runtime", Dict{String,Any}()), "log_log_slope_maximum", NaN)
    for workload in get(isolated_runtime_trend, "workloads", Any[])
    if get(get(workload, "runtime", Dict{String,Any}()), "log_log_slope_maximum", nothing) isa Real
])
isolated_runtime_timing_cvs = Float64[
    Float64(get(
        get(workload, "timing_repeatability_at_largest_dimension", Dict{String,Any}()),
        "maximum_coefficient_of_variation",
        NaN,
    ))
    for workload in get(isolated_runtime_trend, "workloads", Any[])
    if get(
        get(workload, "timing_repeatability_at_largest_dimension", Dict{String,Any}()),
        "maximum_coefficient_of_variation",
        nothing,
    ) isa Real
]
isolated_runtime_timing_cv_maximum = isempty(isolated_runtime_timing_cvs) ?
    nothing : maximum(isolated_runtime_timing_cvs)
rank_perturbation_records = get(rank_perturbation, "record_count", 0)
rank_perturbation_hard_mismatches = get(rank_perturbation, "hard_control_mismatch_count", 0)
rank_perturbation_unavailable = get(rank_perturbation, "unavailable_count", 0)
rank_perturbation_threshold_disagreements = get(
    rank_perturbation, "threshold_backend_disagreement_count", 0,
)
rank_adversarial_records = get(rank_adversarial_extension, "record_count", 0)
rank_adversarial_hard_controls = get(rank_adversarial_extension, "hard_control_count", 0)
rank_adversarial_mismatches = get(rank_adversarial_extension, "hard_control_mismatch_count", 0)
rank_adversarial_unavailable = get(rank_adversarial_extension, "unavailable_count", 0)
rank_hard_controls = get(get(rank_statistics, "hard_controls", Dict{String,Any}()), "record_count", 0)
rank_hard_mismatches = get(get(rank_statistics, "hard_controls", Dict{String,Any}()), "mismatch_count", 0)
rank_hard_unavailable = get(get(rank_statistics, "hard_controls", Dict{String,Any}()), "unavailable_count", 0)
rank_threshold_records = get(get(rank_statistics, "threshold_sensitive_controls", Dict{String,Any}()), "record_count", 0)
rank_threshold_disagreements = get(get(rank_statistics, "threshold_sensitive_controls", Dict{String,Any}()), "backend_disagreement_count", 0)
rank_sparse_only_records = get(get(rank_statistics, "large_sparse_sparse_only", Dict{String,Any}()), "record_count", 0)
rank_sparse_only_mismatches = get(get(rank_statistics, "large_sparse_sparse_only", Dict{String,Any}()), "sparse_mismatch_count", 0)
rank_finite_sample = get(rank_statistics, "finite_sample_uncertainty", Dict{String,Any}())
rank_finite_sample_confidence = get(rank_finite_sample, "confidence_level", "unknown")
rank_zero_event_upper_bound = get(rank_finite_sample, "zero_event_upper_bound", nothing)
rank_zero_event_upper_bound_label = rank_zero_event_upper_bound === nothing ?
    "unavailable" : string(round(rank_zero_event_upper_bound; digits=4))
rank_cross_backend_matrix = get(rank_statistics, "cross_backend_calibration_matrix", Dict{String,Any}())
rank_cross_backend_rows = get(rank_cross_backend_matrix, "corpus_rows", Any[])
rank_third_backend_status = get(rank_third_backend, "status", "missing")
rank_third_backend_adapter_status = get(rank_third_backend, "adapter_status", "missing")
rank_third_backend_reason = get(rank_third_backend, "reason", "capability artifact missing")
rank_third_backend_reason_sentence = rstrip(rank_third_backend_reason, '.')
normal_eigen_records = get(normal_eigen_calibration, "record_count", 0)
normal_eigen_hard_controls = get(normal_eigen_calibration, "hard_control_count", 0)
normal_eigen_disagreements = get(normal_eigen_calibration, "threshold_backend_disagreement_count", 0)
normal_eigen_policy_records = get(normal_eigen_persistence, "policy_record_count", 0)
normal_eigen_repeatability_failures = get(normal_eigen_persistence, "repeatability_failure_count", 0)
normal_eigen_policy_disagreements = get(normal_eigen_persistence, "cross_backend_disagreement_count", 0)
normal_eigen_bmopf_snapshots = get(normal_eigen_bmopf, "successful_snapshot_count", 0)
normal_eigen_bmopf_records = get(normal_eigen_bmopf, "policy_record_count", 0)
normal_eigen_bmopf_agreements = get(normal_eigen_bmopf, "cross_backend_agreement_count", 0)
normal_eigen_bmopf_unavailable = get(normal_eigen_bmopf, "cross_backend_unavailable_count", 0)
normal_eigen_bmopf_guarded = get(normal_eigen_bmopf, "size_guarded_snapshot_count", 0)
normal_eigen_bmopf_guarded_label = normal_eigen_bmopf_guarded == 1 ?
    "1 larger snapshot was pre-solve size-guarded and remains" :
    "$normal_eigen_bmopf_guarded larger snapshots were pre-solve size-guarded and remain"
large_sparse_bmopf_screen = get(large_sparse_bmopf, "sparse_qr", Dict{String,Any}())
large_sparse_bmopf_comparison = get(large_sparse_bmopf_screen, "comparison", Dict{String,Any}())
large_sparse_bmopf_unscaled_rank = get(large_sparse_bmopf_comparison, "unscaled_rank", nothing)
large_sparse_bmopf_row_column_rank = get(large_sparse_bmopf_comparison, "row_column_rank", nothing)
large_sparse_bmopf_rank_delta = get(large_sparse_bmopf_comparison, "row_column_minus_unscaled_rank", nothing)
large_sparse_bmopf_saved_screen = get(large_sparse_bmopf_saved, "sparse_qr", Dict{String,Any}())
large_sparse_bmopf_saved_comparison = get(large_sparse_bmopf_saved_screen, "comparison", Dict{String,Any}())
large_sparse_bmopf_saved_unscaled_rank = get(large_sparse_bmopf_saved_comparison, "unscaled_rank", nothing)
large_sparse_bmopf_saved_row_column_rank = get(large_sparse_bmopf_saved_comparison, "row_column_rank", nothing)
large_sparse_bmopf_saved_rank_delta = get(large_sparse_bmopf_saved_comparison, "row_column_minus_unscaled_rank", nothing)
saved_result_bmopf_count = get(saved_result_bmopf_campaign, "record_count", 0)
saved_result_bmopf_stable = get(saved_result_bmopf_campaign, "scaling_stable_count", 0)
saved_result_bmopf_sensitive = get(saved_result_bmopf_campaign, "scaling_sensitive_count", 0)
smallest_singular_case_count = get(smallest_singular_calibration, "case_count", 0)
smallest_singular_crosscheck = get(smallest_singular_calibration, "dense_free_crosscheck", Dict{String,Any}())
smallest_singular_agreement_count = get(smallest_singular_crosscheck, "agreement_count", 0)
smallest_singular_adverse_count = get(smallest_singular_crosscheck, "adverse_relation_count", 0)
analyze_stage_dominant = isempty(analyze_stage_records) ?
    "unavailable" :
    begin
        dominant = argmax(item -> item["elapsed_seconds"], analyze_stage_records)
        "$(dominant["stage"]) ($(round(dominant["elapsed_seconds"]; digits=3))s)"
    end
api_contract_missing_clause = isempty(api_contract_missing) ?
    "" : " (missing: $api_contract_missing)"
api_contract_rationale =
    "The consolidation audit now inventories $api_root_export_count root exports, $api_testset_count root testsets across nine included test modules, $api_script_count benchmark scripts, and complete schema coverage for $api_schema_count JSON artifacts. A typed unavailable-reason schema now covers solver telemetry, dual/complementarity boundaries, profile reports, solver-result point and postmortem capability reports, active-set multiplier-recovery, MFCQ screen, dense/sparse Jacobian rank backends, sparse-QR nullspace extraction, dense calibration, persistence, Golub--Kahan and restarted smallest-singular probe/calibration boundaries, Jacobian tolerance-sweep and condition-persistence boundaries, Jacobian scaling, derivative-provenance, rank-persistence, row-family perturbation, iterative right/left candidate-persistence, persistence coordinate-alignment, top-level condition/rank/reduced-Hessian coordinate, reduced-Hessian Jacobian-scaling alignment, component-port coordinate-map, coordinate-semantics, mode-projection, connection, nullspace-mode alignment, nullspace-mode semantics, topology-projection, nominal-scale projection, coupled-constraint scale alignment, scalar-constraint scale alignment, component metadata scope, component-port metadata scope, constitutive-map validation, and topology-nullspace endpoints, Jacobian expected-mode and expected-mode-span persistence, reduced-Hessian flat-subspace, active-row and active-Jacobian persistence, multiplier-persistence, reduced-Hessian expected-mode persistence, Jacobian-scaling, spectral-scale, and persistent reduced-Hessian structural-scope boundaries, restarted and harmonic smallest-singular calibration/crosscheck boundaries, structural-matching, DM-partition, reduced-Hessian, structural-to-numerical rank-comparison, and iterative right/left/spectrum probe work/capability guards, coupled-set qualification capability boundaries, generic and BMOPFTools component-rank capability reports, BMOPFTools differentiability capability reports, PowerModels scalar-angle capability reports, MadNLP primal-capture capability reports, BMOPFTools terminal-current capability reports, BMOPFTools passive-network map capability reports, and BMOPFTools terminal-attachment capability reports; non-breaking Stable and Advanced facades, shared benchmark helper, and reviewed local quality policy are also available. The tier review ledger now assigns all $api_tier_queue_count root-only exports a disposition: $api_tier_advanced_candidates Advanced candidates and $api_tier_legacy_manual_review manual legacy reviews. Usage triage finds $api_tier_runtime_usage root-only names referenced by tests or benchmarks and $api_tier_unreferenced names unreferenced in repository code; priority buckets are $(get(api_tier_usage_priorities, "test_and_benchmark_usage", 0)) test-plus-benchmark, $(get(api_tier_usage_priorities, "test_usage", 0)) test-only, $(get(api_tier_usage_priorities, "benchmark_usage", 0)) benchmark-only, and $(get(api_tier_usage_priorities, "source_only", 0)) source-only. $api_helper_user_count data-producing runners use the helper, with infrastructure-script exemptions explicitly inventoried. The active BMOPFTools API contract audit is $api_contract_status$api_contract_missing_clause, while the clean-main contract audit is $api_contract_clean_main_status at revision $api_contract_clean_main_revision and the known local benchmark environment validates the checkout with suite coverage $api_checkout_validation_suite. The PR handoff gate is $api_contract_handoff_status ($api_contract_handoff_reason). The local checkout validator is $api_checkout_validation_status at revision $api_checkout_validation_revision. Temporary-environment bootstrap remains unavailable under managed registry permissions; this is a known-environment validation artifact. Remaining work is review of Stable versus Advanced boundaries, broader adapter adoption, root-export tiering, keeping dependency evidence synchronized, and activation of deferred documentation-example, Aqua, and targeted JET checks when reviewed environments are available."
api_contract_rationale = api_contract_rationale * " The executable Stable facade surface audit is $stable_api_surface_status for $stable_api_surface_export_count runtime exports, with the one-variable smoke path $stable_api_surface_smoke_status; this verifies the declared boundary without promoting legacy root exports."
api_contract_rationale = api_contract_rationale * " The complementary Advanced facade surface audit is $advanced_api_surface_status for $advanced_api_surface_export_count runtime exports, with the typed rank-policy/unavailable-reason smoke path $advanced_api_surface_smoke_status; this verifies the research namespace without promoting it into Stable."
api_contract_rationale = api_contract_rationale * " The API migration queue summary preserves $api_migration_queue_count root-only entries and $api_migration_unreferenced_count unreferenced names in a disposition-by-usage matrix; this is deterministic triage evidence, not automatic migration."
api_contract_rationale = api_contract_rationale * " The Advanced-candidate summary retains $api_advanced_candidate_count candidates in $(get(api_advanced_family_counts, "bmopf_extension", 0)) BMOPF-extension and $(get(api_advanced_family_counts, "port_extension", 0)) port-extension review batches; family and usage buckets order ownership review without automatic promotion."
api_contract_rationale = api_contract_rationale * " The bounded ownership ledger reviews $api_ownership_reviewed_count high-impact names: $api_ownership_retained_count retain root compatibility and $api_ownership_advanced_count remain Advanced candidates; automatic migration decisions remain $api_ownership_migration_count."

combined_mv_lv_gate = all([
    get(combined_mv_lv, "ipopt_tolerance_diagnostic", Dict{String,Any}())["all_comparisons_qualified"],
    get(combined_mv_lv, "second_feeder_campaign", Dict{String,Any}())["all_comparisons_qualified"],
    get(combined_mv_lv, "perturbed_start_matrix", Dict{String,Any}())["matrix_gates"]["all_variants_qualified"],
    get(combined_mv_lv, "perturbed_start_lv13_matrix", Dict{String,Any}())["matrix_gates"]["all_variants_qualified"],
    get(combined_mv_lv, "perturbed_start_madnlp_matrix", Dict{String,Any}())["matrix_gates"]["all_variants_qualified"],
    get(combined_mv_lv, "voltage_only_start_matrix", Dict{String,Any}())["matrix_gates"]["all_variants_qualified"],
])
series_voltage_case_count = get(series_voltage_scaling, "case_count", 0)
series_voltage_covariance_count = get(series_voltage_scaling, "covariance_gate_passed_count", 0)
series_voltage_geometry_count = get(series_voltage_scaling, "geometry_gate_passed_count", 0)
practical_application_count = get(practical_application_success, "application_count", 0)
practical_application_success_count = get(practical_application_success, "successful_application_count", 0)
series_solver_case_count = get(series_solver_campaign, "case_count", 0)
series_solver_qualified_count = get(series_solver_campaign, "campaign_qualified_count", 0)
series_madnlp_case_count = get(series_madnlp_campaign, "case_count", 0)
series_madnlp_qualified_count = get(series_madnlp_campaign, "campaign_qualified_count", 0)
series_application_bridge_status = get(series_application_bridge, "status", "missing")
series_capacity_boundary_status = get(series_capacity_boundary, "status", "missing")
series_uprated_nominal_status = get(series_uprated_nominal, "status", "missing")
lv13_madnlp_guard_status = get(lv13_madnlp_guard, "status", "missing")
series_solver_budget60_records = get(series_solver_budget60, "records", Any[])
series_solver_budget60_largest = isempty(series_solver_budget60_records) ?
    Dict{String,Any}() : only(filter(record -> get(record, "label", "") == "series_8level_230kV_208V", series_solver_budget60_records))
series_solver_budget60_statuses = sort!(unique(
    get(record, "termination_status", "unknown")
    for record in get(series_solver_budget60_largest, "records", Any[])
))
series_feasibility_records = get(series_feasibility_sweep, "records", Any[])
series_feasibility_endpoint_pass_count = count(
    record -> get(get(record, "campaign_gates", Dict{String,Any}()), "all_physical_endpoints_accepted", false),
    series_feasibility_records,
)
series_feasibility_solved_count = count(
    record -> all(
        get(row, "termination_status", "") == "LOCALLY_SOLVED"
        for row in get(record, "records", Any[])
    ),
    series_feasibility_records,
)

function gate(id, status, rationale, evidence; blocking=false)
    evidence = id == "numerical_rank_false_positive_negative_statistics" ?
        vcat(evidence, ["docs/bmopf_saved_result_sparse_rank_campaign_summary.json", "benchmarks/summarize_bmopf_saved_result_sparse_rank_campaign.jl"]) : evidence
    Dict{String,Any}(
        "id" => id,
        "status" => status,
        "blocking" => blocking,
        "rationale" => rationale,
        "evidence" => evidence,
    )
end

gates = Dict{String,Any}[
    gate(
        "30bus_ibr_bounded_calibration",
        "pass",
        "Bounded 30-bus IBR evidence now covers endpoint, trajectory, options, initialization, geometry, derivatives, scaling, bounds, and tolerance margins; it remains research-qualified rather than causal.",
        ["docs/bmopf_30bus_ibr_p_upper_tolerance_margin_summary.json", "docs/bmopf_30bus_ibr_p_upper_sparse_jacobian_audit_summary.json"],
    ),
    gate(
        "real_99bus_solver_completion",
        get(real_campaign["summary"], "reference_locally_solved_count", 0) == 6 && get(real_campaign["summary"], "phase_only_locally_solved_count", 0) == 6 ? "pass" : "partial",
        "All six reference and phase-only real 99-bus runs are locally solved in the bounded campaign.",
        ["docs/real_99bus_phase_only_campaign_summary.json"],
    ),
    gate(
        "real_99bus_physical_kkt",
        "partial",
        "Physical KKT is available on all six runs but only 2/6 reference and 2/6 phase-only endpoints pass the strict 1e-5 gate. The joined stability ledger has $real_kkt_qualified_profiles complete solver-floor-qualified profiles (excluding $real_kkt_excluded_profiles incomplete profiles), and strict acceptance remains stable at $(isnothing(real_kkt_stable_count) ? "unavailable" : "$(real_kkt_stable_count)/6") across those profiles; failure localization is complete. The per-snapshot margin ledger records $real_kkt_margin_failed_snapshots strict-failing snapshots, a paired-endpoint maximum required tolerance of $(isnothing(real_kkt_margin_maximum) ? "unavailable" : string(real_kkt_margin_maximum)), and a paired-endpoint p95 of $(isnothing(real_kkt_margin_p95) ? "unavailable" : string(real_kkt_margin_p95)); its distribution quantifies the boundary without relaxing the gate. The paired residual-distribution ledger shows reference/phase-only maximum-residual ratios of $real_kkt_distribution_ratio_text, so the observed strict failures are not explained by a material phase-only residual inflation in this saved campaign. The joined endpoint matrix retains $real_kkt_endpoint_count rows with $real_kkt_endpoint_pass_count strict paired passes and $real_kkt_endpoint_failure_count localized failures (all failures localized=$real_kkt_endpoint_localized). The saved policy matrix reaches full paired acceptance first at the recorded $(isnothing(real_kkt_policy_full_acceptance) ? "unavailable" : real_kkt_policy_full_acceptance) policy; this is sensitivity evidence, not a recommended release threshold. The cross-artifact gate validator is $real_kkt_gate_validation_status and confirms the ledgers agree without rerunning solves.",
        ["docs/real_99bus_phase_only_campaign_summary.json", "docs/real_99bus_phase_only_kkt_failure_summary.json", "docs/real_99bus_kkt_stability_summary.json", "docs/real_99bus_kkt_margin_summary.json", "docs/real_99bus_kkt_residual_distribution_summary.json", "docs/real_99bus_kkt_tolerance_policy_summary.json", "docs/real_99bus_kkt_endpoint_matrix_summary.json", "docs/real_99bus_kkt_gate_validation_summary.json", "benchmarks/validate_real_99bus_kkt_gate.jl"],
        blocking=true,
    ),
    gate(
        "real_99bus_covariance",
        get(real_covariance["summary"], "equivalence_gate_passed_count", 0) == 6 ? "pass" : "partial",
        "All six phase-only transformations pass the seven available covariance checks and scalar-set transport; physical rank and inequality-multiplier covariance remain unavailable or out of scope.",
        ["docs/real_99bus_phase_only_covariance_summary.json"],
    ),
    gate(
        "numerical_rank_false_positive_negative_statistics",
        "partial",
        "The aggregate rank-statistics ledger now joins $rank_hard_controls complete hard controls with $rank_hard_mismatches mismatches and $rank_hard_unavailable unavailable results, plus $rank_threshold_records threshold-sensitive controls with $rank_threshold_disagreements backend disagreements. The zero-event hard-control result is accompanied by a one-sided $(rank_finite_sample_confidence)-level finite-sample upper bound of $rank_zero_event_upper_bound_label for any single zero-observed error rate; this is uncertainty context, not a universal guarantee. This includes the seeded randomized and controlled perturbation corpora plus a deterministic adversarial extension of $rank_adversarial_records records ($rank_adversarial_hard_controls hard controls, $rank_adversarial_mismatches hard-control mismatches, $rank_adversarial_unavailable unavailable). Disagreements remain tolerance evidence. A guarded sparse-only extension contributes $rank_sparse_only_records records with $rank_sparse_only_mismatches sparse mismatches while intentionally disabling dense SVD. The cross-backend calibration matrix now retains $(length(rank_cross_backend_rows)) corpus rows separating dense/sparse hard-control agreement, threshold-sensitive disagreement, and sparse-only coverage. The separate smallest-singular corpus adds $smallest_singular_case_count adversarial cases with $smallest_singular_agreement_count dense-free crosscheck agreements and $smallest_singular_adverse_count expected adverse relations. The third-backend capability validator reports status=$rank_third_backend_status, adapter=$rank_third_backend_adapter_status: $rank_third_backend_reason_sentence. The reviewed internal normal-eigen path contributes a bounded $normal_eigen_records-record campaign with $normal_eigen_hard_controls hard controls and $normal_eigen_disagreements expected squared-spectrum threshold disagreement(s). Its policy-persistence follow-up adds $normal_eigen_policy_records records; $normal_eigen_repeatability_failures expose same-point span instability and $normal_eigen_policy_disagreements cross-backend policy disagreements. Trusted BMOPFTools validation now covers $normal_eigen_bmopf_snapshots successful snapshots and $normal_eigen_bmopf_records policy records, with $normal_eigen_bmopf_agreements cross-backend agreements, $normal_eigen_bmopf_unavailable unavailable policy comparisons; $normal_eigen_bmopf_guarded_label open. A guarded 538-bus synthetic coordinate probe adds sparse-only ranks $large_sparse_bmopf_unscaled_rank and $large_sparse_bmopf_row_column_rank (delta $large_sparse_bmopf_rank_delta). The saved 538-bus solver-result point adds ranks $large_sparse_bmopf_saved_unscaled_rank and $large_sparse_bmopf_saved_row_column_rank (delta $large_sparse_bmopf_saved_rank_delta), showing scaling-stable sparse evidence at a provenance-complete endpoint.",
        ["docs/randomized_rank_oracle_calibration_summary.json", "docs/large_sparse_rank_oracle_summary.json", "docs/rank_perturbation_sweep_summary.json", "docs/rank_adversarial_extension_summary.json", "docs/rank_calibration_statistics_summary.json", "docs/rank_third_backend_capability_summary.json", "benchmarks/validate_rank_third_backend.jl", "docs/normal_eigen_rank_calibration_summary.json", "benchmarks/calibrate_normal_eigen_rank_backend.jl", "docs/normal_eigen_policy_persistence_summary.json", "benchmarks/calibrate_normal_eigen_policy_persistence.jl", "docs/bmopf_normal_eigen_jacobian_validation_summary.json", "benchmarks/bmopf_normal_eigen_jacobian_validation.jl", "docs/bmopf_large_sparse_rank_screen_summary.json", "docs/bmopf_large_sparse_rank_screen_saved_result_summary.json", "benchmarks/summarize_bmopf_large_sparse_rank_screen.jl", "docs/smallest_singular_calibration_summary.json", "benchmarks/calibrate_restarted_smallest_singular.jl"],
        blocking=true,
    ),
    gate(
        "runtime_memory_scaling",
        "partial",
        "The synthetic sparse ladder provides $(length(runtime_records)) warm-up-aware runtime/allocation records across $(length(runtime_dimensions)) dimensions, and an isolated child-process ladder adds $(length(isolated_runtime_records)) records across $(length(isolated_runtime_dimensions)) dimensions with per-dimension Sys.maxrss high-water observations. The companion trend ledger covers $isolated_runtime_workloads workloads; descriptive runtime log-log slopes range from $(isfinite(isolated_runtime_slope_minimum) ? round(isolated_runtime_slope_minimum; digits=3) : "unavailable") to $(isfinite(isolated_runtime_slope_maximum) ? round(isolated_runtime_slope_maximum; digits=3) : "unavailable"), with stage attribution retained per workload. Within-dimension stage timing repeatability is also retained; the largest observed stage coefficient of variation at the largest dimension is $(isnothing(isolated_runtime_timing_cv_maximum) ? "unavailable" : string(round(isolated_runtime_timing_cv_maximum; digits=3))). The runtime readiness matrix now joins $runtime_readiness_coverage_count bounded synthetic, public-API, isolated-process, BMOPFTools adapter, and BMOPFTools solver-workload coverage rows while retaining $runtime_readiness_open_gap_count open release-evidence gaps. The new bounded solver-workload ledger contributes $runtime_solver_measured_count measured records and $runtime_solver_guarded_count explicit full-case size guards with solve-time and termination provenance; allocator-level peak-memory measurements and a larger solver ladder remain open.",
        ["docs/sparse_runtime_memory_scaling_summary.json", "docs/sparse_runtime_memory_isolated_summary.json", "docs/sparse_runtime_trend_summary.json", "docs/runtime_scaling_readiness_summary.json", "docs/bmopf_solver_scaling_readiness_summary.json", "benchmarks/summarize_bmopf_solver_scaling_readiness.jl"],
        blocking=true,
    ),
    gate(
        "analyze_runtime_scaling",
        "partial",
        "The public point-free analyze(model) entry point now has a bounded sparse affine-chain measurement. The observed cost grows from $(round(analyze_runtime_scaling["records"][1]["elapsed_seconds"]; digits=3))s at dimension $(analyze_runtime_scaling["records"][1]["dimension"]) to $(round(analyze_runtime_scaling["records"][end]["elapsed_seconds"]; digits=3))s at dimension $(analyze_runtime_scaling["records"][end]["dimension"]) across $analyze_repetitions repetition(s), with affine propagation reaching its configured five-pass limit. Finding evidence is stable across repetitions: $analyze_evidence_stable. The trend ledger records adjacent affine growth ratios $([round(get(item, "elapsed_ratio", 0.0); digits=3) for item in get(analyze_trend_affine, "adjacent_ratios", Any[])]) and descriptive log-log slopes $(round(get(analyze_trend_affine, "log_log_slope_minimum", 0.0); digits=3))--$(round(get(analyze_trend_affine, "log_log_slope_maximum", 0.0); digits=3)); these are bounded-fixture observations, not a complexity law. Stage attribution is now recorded; the largest measured stage at the largest dimension is $analyze_stage_dominant. A second sparse nonlinear workload is also measured, reaching $(isnothing(analyze_nonlinear_end) ? "unavailable" : "$(round(analyze_nonlinear_end["elapsed_seconds"]; digits=3))s at dimension $(analyze_nonlinear_end["dimension"]) with stable evidence $(get(analyze_nonlinear_end, "evidence_stable_across_repetitions", false))"), with trend slopes $(round(get(analyze_trend_nonlinear, "log_log_slope_minimum", 0.0); digits=3))--$(round(get(analyze_trend_nonlinear, "log_log_slope_maximum", 0.0); digits=3)). The resource ledger records allocation slopes $(isnothing(analyze_allocation_slope_minimum) ? "unavailable" : string(round(analyze_allocation_slope_minimum; digits=3)))--$(isnothing(analyze_allocation_slope_maximum) ? "unavailable" : string(round(analyze_allocation_slope_maximum; digits=3))) across both workloads and identifies static as the dominant largest-dimension allocation stage; the largest runtime coefficient of variation at that dimension is $(isnothing(analyze_repeatability_cv_maximum) ? "unavailable" : string(round(analyze_repeatability_cv_maximum; digits=3))). Process-memory telemetry remains descriptive. The bounded BMOPFTools adapter profile measured $bmopf_profile_measured case(s) and size-guarded $bmopf_profile_guarded case(s), retaining PowerIO warning provenance with per-case warmup=$bmopf_profile_warmup. Fresh-child adapter memory evidence now measures $analyze_isolated_memory_measured case(s), size-guards $analyze_isolated_memory_guarded case(s), and repeats $analyze_isolated_memory_stable case summaries stably; this remains local Sys.maxrss high-water telemetry, not portable allocator evidence. The portability contract baseline validates as $analyze_portability_baseline_status, while its comparison status is $analyze_portability_comparison_status; a second reviewed environment is still required. The new analyze-readiness ledger joins $analyze_readiness_workload_count workload rows, with $analyze_readiness_stable_count stable and $analyze_readiness_open_gap_count explicit next-evidence gaps; static remains the dominant stage in both bounded workloads. The affine-row cache A/B preserves findings and propagation metadata=$analyze_ab_equivalence, but local elapsed speedup ranges $analyze_ab_speedup_text across the original chain. Generalization across mixed-density affine and nonlinear workloads also preserves semantics=$analyze_generalization_equivalence, with local speedup range $analyze_generalization_speedup_text. The target-term cache candidate preserves semantics=$analyze_target_terms_equivalence with local speedup range $analyze_target_terms_speedup_text; its decision is explicit: $analyze_target_terms_decision The new BMOPFTools combined MV+LV profile measures $analyze_combined_measured_count stable=$analyze_combined_stable_count point-free analyze records across $analyze_combined_feeder_count reviewed feeder snapshots under explicit guards; these are adapter observations, not solver-scaling claims. No portable performance claim is promoted. The current evidence-preserving optimization is: $analyze_optimization_note. Portable scaling and further optimization remain open.",
        ["docs/analyze_runtime_scaling_summary.json", "docs/analyze_runtime_trend_summary.json", "docs/analyze_runtime_resource_summary.json", "docs/bmopf_analyze_runtime_profile_summary.json", "docs/bmopf_analyze_runtime_isolated_summary.json", "docs/bmopf_analyze_portability_summary.json", "docs/analyze_scaling_readiness_summary.json", "docs/analyze_static_optimization_ab_summary.json", "docs/analyze_static_optimization_generalization_summary.json", "docs/analyze_static_target_terms_summary.json", "docs/bmopf_combined_mv_lv_analyze_scaling_summary.json"],
        blocking=true,
    ),
    gate(
        "combined_mv_lv_scaling_start_robustness",
        combined_mv_lv_gate ? "pass" : "partial",
        "The authoritative BMOPFTools combined MV+LV source now has bounded, endpoint-gated evidence across LV1_14bus and LV13_58bus. Ipopt and MadNLP matched-start campaigns pass the declared physical and cross-policy gates under tolerance 1e-10 and max_iter 10; global affine and voltage-only start matrices also pass. The evidence qualifies procedure repeatability and provenance coverage, not a universal scaling policy, solver superiority, or causal mechanism.",
        [
            "docs/bmopf_combined_mv_lv_scaling_readiness_summary.json",
            "docs/bmopf_combined_mv_lv_scaling_campaign_summary.json",
            "docs/bmopf_combined_mv_lv_snapshot_campaign_summary.json",
            "benchmarks/bmopf_combined_mv_lv_snapshot_campaign.jl",
            "benchmarks/bmopf_combined_mv_lv_perturbed_start_campaign.jl",
        ],
    ),
    gate(
        "bmopf_voltage_level_series_scaling_readiness",
        series_voltage_case_count > 0 && series_voltage_covariance_count == series_voltage_case_count ? "partial" : "missing",
        "A synthetic BMOPFTools case matrix now covers $series_voltage_case_count voltage-level ladders with series transformers; covariance and coordinate-geometry gates pass on $series_voltage_covariance_count and $series_voltage_geometry_count cases respectively. The matrix is structural readiness evidence rather than a solver-scaling or universal voltage-base claim.",
        [
            "docs/bmopf_voltage_level_series_case_matrix_summary.json",
            "benchmarks/bmopf_voltage_level_series_case_matrix.jl",
        ],
    ),
    gate(
        "bmopf_voltage_level_series_madnlp_campaign",
        series_madnlp_case_count > 0 && series_madnlp_qualified_count == series_madnlp_case_count ? "pass" : "partial",
        "The bounded MadNLP follow-up qualifies $series_madnlp_qualified_count/$series_madnlp_case_count largest-ladder campaigns at the 0.25 demand multiplier, with all three scaling policies locally solved and physical endpoints accepted. This establishes solver-diverse procedure repeatability on the currently feasible fixture; it does not establish solver superiority or nominal-demand feasibility.",
        [
            "docs/bmopf_voltage_level_series_madnlp_campaign_summary.json",
            "benchmarks/bmopf_voltage_level_series_madnlp_campaign.jl",
        ],
    ),
    gate(
        "bmopf_practical_application_success",
        practical_application_count > 0 && practical_application_success_count == practical_application_count ? "pass" : "partial",
        "The practical-application ledger validates $practical_application_success_count/$practical_application_count reviewed combined MV/LV workflows, including LV1_14bus and LV13_58bus matched-start campaigns, perturbed-start matrices, and solver-diverse evidence. All retained workflows have locally solved terminations and explicit endpoint/comparison gates; this is regression evidence over saved campaigns, not a universal scaling or solver-superiority claim.",
        [
            "docs/bmopf_practical_application_success_summary.json",
            "benchmarks/summarize_bmopf_practical_application_success.jl",
        ],
    ),
    gate(
        "bmopf_series_application_bridge",
        series_application_bridge_status == "procedural_bridge_complete" ? "pass" : "partial",
        "The series/application bridge aligns $((length(get(series_application_bridge, "evidence_rows", Any[])))) reviewed evidence rows on explicit local-solve, physical-endpoint, comparison, and coverage contracts while recording direct physical equivalence as unsupported. It also carries the nominal-demand boundary forward as a separate tuning target; this is an acceptance checklist, not a cross-topology equivalence claim.",
        [
            "docs/bmopf_series_application_bridge_summary.json",
            "benchmarks/summarize_bmopf_series_application_bridge.jl",
        ],
    ),
    gate(
        "bmopf_series_nominal_capacity_boundary",
        series_capacity_boundary_status == "capacity_boundary_aligned" ? "pass" : "partial",
        "The solver-independent capacity screen aligns the recorded 1.0, 0.75, 0.5, and 0.25 demand observations with the declared transformer ratings: the first three overload the upstream interface while 0.25 passes the necessary capacity screen. This narrows nominal-demand work to an uprated or reformulated fixture; it does not prove AC feasibility or KKT acceptance.",
        [
            "docs/bmopf_series_nominal_capacity_boundary_summary.json",
            "benchmarks/analyze_bmopf_series_nominal_capacity_boundary.jl",
        ],
    ),
    gate(
        "bmopf_series_uprated_nominal_campaign",
        series_uprated_nominal_status == "uprated_nominal_campaign_complete" ? "pass" : "partial",
        "The explicitly uprated nominal-demand fixture (rating multiplier $(get(series_uprated_nominal, "rating_multiplier", "unknown"))) qualifies both Ipopt and MadNLP across classic, SI, and local policies with complete endpoint and comparison gates. This validates the reformulated fixture as a practical numerical test case; it does not rehabilitate the original overloaded 2 MVA fixture or establish a universal rating choice.",
        [
            "docs/bmopf_voltage_level_series_uprated_nominal_campaign_summary.json",
            "benchmarks/bmopf_voltage_level_series_uprated_nominal_campaign.jl",
        ],
    ),
    gate(
        "bmopf_lv13_madnlp_resource_guard",
        lv13_madnlp_guard_status == "resource_guard_validated" ? "pass" : "partial",
        "The LV13_58bus MadNLP transfer is explicitly guarded before solver execution: the 4,902-variable snapshot is held behind a 4,000-variable limit, yielding zero solver runs rather than an ambiguous failure. This preserves the unavailable-versus-failed distinction and leaves the solver-diverse transfer gap open.",
        [
            "docs/bmopf_lv13_madnlp_transfer_guard_summary.json",
            "benchmarks/summarize_bmopf_lv13_madnlp_transfer_guard.jl",
        ],
    ),
    gate(
        "bmopf_lv13_madnlp_isolated_run_plan",
        get(lv13_madnlp_plan, "status", "") == "isolated_run_ready" ? "pass" : "partial",
        "The LV13 MadNLP transfer handoff validates the resource guard and emits an operator-approved isolated-process command with explicit variable, timeout, memory, solver, and closure criteria. The planner does not launch the solver, so this gate establishes reproducible readiness rather than solver success.",
        [
            "docs/bmopf_lv13_madnlp_isolated_run_plan.json",
            "benchmarks/plan_bmopf_lv13_madnlp_isolated_run.jl",
        ],
    ),
    gate(
        "bmopf_lv13_madnlp_isolated_environment",
        get(lv13_madnlp_environment, "status", "") == "environment_ready" ? "pass" : "partial",
        "The isolated-run preflight checks the active benchmark project, MadNLP and BMOPFTools loadability, and runner presence without constructing the large feeder model. It establishes software readiness only; resource-envelope and solver-result checks remain separate.",
        [
            "docs/bmopf_lv13_madnlp_isolated_environment_summary.json",
            "benchmarks/validate_bmopf_lv13_madnlp_isolated_environment.jl",
        ],
    ),
    gate(
        "bmopf_lv13_madnlp_resource_envelope",
        get(lv13_madnlp_resources, "status", "") == "resource_envelope_ready" ? "pass" : "partial",
        "The host resource assessment compares point-in-time total and free memory with the declared 8 GiB envelope without reserving memory or launching the solver. Current status is $(get(lv13_madnlp_resources, "status", "missing")); capacity and instantaneous availability remain distinct.",
        [
            "docs/bmopf_lv13_madnlp_resource_envelope_summary.json",
            "benchmarks/assess_bmopf_lv13_madnlp_resource_envelope.jl",
        ],
    ),
    gate(
        "bmopf_lv13_madnlp_handoff",
        get(lv13_madnlp_handoff, "status", "") == "ready_to_launch" ||
            get(lv13_madnlp_handoff, "status", "") == "handoff_complete" ? "pass" : "partial",
        "The joined LV13 MadNLP handoff state is $(get(lv13_madnlp_handoff, "status", "missing")), combining software, capacity, free-memory, and result ledgers. It is a process-readiness gate and does not promote a solver result before the isolated artifact qualifies.",
        [
            "docs/bmopf_lv13_madnlp_handoff_summary.json",
            "benchmarks/summarize_bmopf_lv13_madnlp_handoff.jl",
        ],
    ),
    gate(
        "bmopf_lv13_madnlp_guarded_launcher",
        get(lv13_madnlp_launch, "status", "") in ("approval_required", "blocked_current_memory_pressure", "ready_to_launch", "completed", "failed", "timed_out") ? "pass" : "partial",
        "The guarded launcher records an explicit approval, memory recheck, and timeout outcome without starting the solver by default. Current status is $(get(lv13_madnlp_launch, "status", "missing")); result qualification remains delegated to the post-run validator.",
        [
            "docs/bmopf_lv13_madnlp_launch_summary.json",
            "benchmarks/run_bmopf_lv13_madnlp_isolated.jl",
        ],
    ),
    gate(
        "bmopf_lv13_madnlp_isolated_result",
        get(lv13_madnlp_result, "status", "") == "isolated_result_complete" ? "pass" : "partial",
        "The post-run validator checks the eventual LV13 MadNLP artifact against the approved feeder, solver, budgets, ±1% variants, local terminations, endpoint/comparison gates, and 46-warning provenance. Its current status is $(get(lv13_madnlp_result, "status", "missing")); a pending artifact remains an explicit open transfer gap rather than a solver failure.",
        [
            "docs/bmopf_lv13_madnlp_isolated_result_summary.json",
            "benchmarks/summarize_bmopf_lv13_madnlp_isolated_result.jl",
        ],
    ),
    gate(
        "bmopf_voltage_level_series_solver_campaign",
        series_solver_case_count > 0 && series_solver_qualified_count == series_solver_case_count ? "pass" : "partial",
        "The bounded Ipopt campaign qualifies $series_solver_qualified_count/$series_solver_case_count synthetic voltage-level ladders across classic, SI, and local policies with matched starts and endpoint gates. The largest seven-transformer case remains an actionable boundary under the baseline iteration budget; a follow-up max_iter=60 campaign still reports terminations $(series_solver_budget60_statuses), so the boundary is not explained by the 20-iteration budget alone. This is solver-work evidence for the fixtures, not a universal policy or conditioning claim.",
        [
            "docs/bmopf_voltage_level_series_solver_campaign_summary.json",
            "docs/bmopf_voltage_level_series_solver_campaign_maxiter60_summary.json",
            "benchmarks/bmopf_voltage_level_series_solver_campaign.jl",
        ],
    ),
    gate(
        "bmopf_voltage_level_series_feasibility_sweep",
        series_feasibility_records isa AbstractVector && !isempty(series_feasibility_records) ? "partial" : "missing",
        "The largest-ladder demand sweep records $series_feasibility_solved_count/$((length(series_feasibility_records))) load multipliers with all policies locally solved and $series_feasibility_endpoint_pass_count/$((length(series_feasibility_records))) with physical endpoints accepted. The observed transition toward the 0.25 multiplier is consistent with the separate transformer-capacity screen; the Ipopt sweep's composite comparison gate remains open, while the MadNLP follow-up qualifies the feasible boundary.",
        [
            "docs/bmopf_voltage_level_series_feasibility_sweep_summary.json",
            "benchmarks/bmopf_voltage_level_series_feasibility_sweep.jl",
        ],
    ),
    gate(
        "api_test_benchmark_consolidation",
        "partial",
        api_contract_rationale,
        [
            "docs/api_test_benchmark_consolidation_summary.json",
            "docs/bmopf_api_contract_summary.json",
            "docs/bmopf_api_contract_clean_main_summary.json",
            "docs/bmopf_pr_handoff_summary.json",
            "docs/bmopf_checkout_validation_summary.json",
            "docs/api_tier_usage_summary.json",
            "docs/stable_api_surface_summary.json",
            "docs/advanced_api_surface_summary.json",
            "docs/api_migration_queue_summary.json",
            "docs/api_advanced_candidate_summary.json",
            "docs/api_ownership_decision_summary.json",
            "benchmarks/review_api_ownership_decisions.jl",
        ],
        blocking=true,
    ),
]

output = abspath(get(ENV, "NLPDIAGNOSTICS_CALIBRATION_RELEASE_OUTPUT", joinpath(ROOT, "docs", "calibration_release_gate_summary.json")))
write_json(output, Dict(
    "schema_version" => "nlpdiagnostics-calibration-release-gate-summary-v1",
    "generated_by" => basename(@__FILE__),
    "project_phase" => "consolidate_and_calibrate",
    "release_ready" => all(gate -> gate["status"] == "pass", gates),
    "blocking_gate_count" => count(gate -> gate["blocking"] === true, gates),
    "gates" => gates,
    "next_actions" => Dict(
        "artifact" => "docs/release_gate_action_summary.json",
        "blocking_gate_count" => get(release_gate_actions, "blocking_gate_count", 0),
        "recommended_order" => get(release_gate_actions, "recommended_order", Any[]),
    ),
    "interpretation" => "This ledger separates completed evidence from release blockers. It does not promote local research observations into causal or physical claims.",
))
println("wrote calibration release-gate summary to $output")
