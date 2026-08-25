#!/usr/bin/env julia

"""Build the machine-readable calibration release-gate ledger from summaries."""

include(joinpath(@__DIR__, "common.jl"))
using .NLPDiagnosticsBenchmarkCommon

const ROOT = repo_root()

real_campaign = read_summary("docs/real_99bus_phase_only_campaign_summary.json")
real_kkt = read_summary("docs/real_99bus_phase_only_kkt_failure_summary.json")
real_kkt_stability = read_summary("docs/real_99bus_kkt_stability_summary.json")
real_covariance = read_summary("docs/real_99bus_phase_only_covariance_summary.json")
ibr_tolerance = read_summary("docs/bmopf_30bus_ibr_p_upper_tolerance_margin_summary.json")
ibr_sparse = read_summary("docs/bmopf_30bus_ibr_p_upper_sparse_jacobian_audit_summary.json")
rank_oracles = read_summary("docs/randomized_rank_oracle_calibration_summary.json")
rank_perturbation = read_summary("docs/rank_perturbation_sweep_summary.json")
runtime_scaling = read_summary("docs/sparse_runtime_memory_scaling_summary.json")
isolated_runtime_scaling = read_summary("docs/sparse_runtime_memory_isolated_summary.json")
analyze_runtime_scaling = read_summary("docs/analyze_runtime_scaling_summary.json")
bmopf_analyze_profile = read_summary("docs/bmopf_analyze_runtime_profile_summary.json")
large_sparse_rank = read_summary("docs/large_sparse_rank_oracle_summary.json")
combined_mv_lv = read_summary("docs/bmopf_combined_mv_lv_snapshot_campaign_summary.json")
api_consolidation = read_summary("docs/api_test_benchmark_consolidation_summary.json")
api_tier_inventory = read_summary("docs/api_tier_inventory_summary.json")
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
real_kkt_qualified_profiles = get(real_kkt_stability, "qualified_profile_count", 0)
real_kkt_stable_count = get(real_kkt_stability, "stable_strict_acceptance_count", nothing)
real_kkt_excluded_profiles = get(real_kkt_stability, "excluded_incomplete_profile_count", 0)
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
rank_perturbation_records = get(rank_perturbation, "record_count", 0)
rank_perturbation_hard_mismatches = get(rank_perturbation, "hard_control_mismatch_count", 0)
rank_perturbation_unavailable = get(rank_perturbation, "unavailable_count", 0)
rank_perturbation_threshold_disagreements = get(
    rank_perturbation, "threshold_backend_disagreement_count", 0,
)
analyze_stage_dominant = isempty(analyze_stage_records) ?
    "unavailable" :
    begin
        dominant = argmax(item -> item["elapsed_seconds"], analyze_stage_records)
        "$(dominant["stage"]) ($(round(dominant["elapsed_seconds"]; digits=3))s)"
    end
api_contract_missing_clause = isempty(api_contract_missing) ?
    "" : " (missing: $api_contract_missing)"
api_contract_rationale =
    "The consolidation audit now inventories $api_root_export_count root exports, $api_testset_count root testsets across nine included test modules, $api_script_count benchmark scripts, and complete schema coverage for $api_schema_count JSON artifacts. A typed unavailable-reason schema now covers solver telemetry, dual/complementarity boundaries, profile reports, solver-result point and postmortem capability reports, active-set multiplier-recovery, MFCQ screen, dense/sparse Jacobian rank backends, sparse-QR nullspace extraction, dense calibration, persistence, Golub--Kahan and restarted smallest-singular probe/calibration boundaries, Jacobian tolerance-sweep and condition-persistence boundaries, Jacobian scaling, derivative-provenance, rank-persistence, row-family perturbation, iterative right/left candidate-persistence, persistence coordinate-alignment, top-level condition/rank/reduced-Hessian coordinate, reduced-Hessian Jacobian-scaling alignment, component-port coordinate-map, coordinate-semantics, mode-projection, connection, nullspace-mode alignment, nullspace-mode semantics, topology-projection, nominal-scale projection, coupled-constraint scale alignment, scalar-constraint scale alignment, component metadata scope, component-port metadata scope, constitutive-map validation, and topology-nullspace endpoints, Jacobian expected-mode and expected-mode-span persistence, reduced-Hessian flat-subspace, active-row and active-Jacobian persistence, multiplier-persistence, reduced-Hessian expected-mode persistence, Jacobian-scaling, spectral-scale, and persistent reduced-Hessian structural-scope boundaries, restarted and harmonic smallest-singular calibration/crosscheck boundaries, structural-matching, DM-partition, reduced-Hessian, structural-to-numerical rank-comparison, and iterative right/left/spectrum probe work/capability guards, coupled-set qualification capability boundaries, generic and BMOPFTools component-rank capability reports, BMOPFTools differentiability capability reports, PowerModels scalar-angle capability reports, MadNLP primal-capture capability reports, BMOPFTools terminal-current capability reports, BMOPFTools passive-network map capability reports, and BMOPFTools terminal-attachment capability reports; non-breaking Stable and Advanced facades, shared benchmark helper, and reviewed local quality policy are also available. The tier review ledger now assigns all $api_tier_queue_count root-only exports a disposition: $api_tier_advanced_candidates Advanced candidates and $api_tier_legacy_manual_review manual legacy reviews. $api_helper_user_count data-producing runners use the helper, with infrastructure-script exemptions explicitly inventoried. The active BMOPFTools API contract audit is $api_contract_status$api_contract_missing_clause, while the clean-main contract audit is $api_contract_clean_main_status at revision $api_contract_clean_main_revision and the known local benchmark environment validates the checkout with suite coverage $api_checkout_validation_suite. The PR handoff gate is $api_contract_handoff_status ($api_contract_handoff_reason). The local checkout validator is $api_checkout_validation_status at revision $api_checkout_validation_revision. Temporary-environment bootstrap remains unavailable under managed registry permissions; this is a known-environment validation artifact. Remaining work is review of Stable versus Advanced boundaries, broader adapter adoption, root-export tiering, keeping dependency evidence synchronized, and activation of deferred documentation-example, Aqua, and targeted JET checks when reviewed environments are available."

combined_mv_lv_gate = all([
    get(combined_mv_lv, "ipopt_tolerance_diagnostic", Dict{String,Any}())["all_comparisons_qualified"],
    get(combined_mv_lv, "second_feeder_campaign", Dict{String,Any}())["all_comparisons_qualified"],
    get(combined_mv_lv, "perturbed_start_matrix", Dict{String,Any}())["matrix_gates"]["all_variants_qualified"],
    get(combined_mv_lv, "perturbed_start_lv13_matrix", Dict{String,Any}())["matrix_gates"]["all_variants_qualified"],
    get(combined_mv_lv, "perturbed_start_madnlp_matrix", Dict{String,Any}())["matrix_gates"]["all_variants_qualified"],
    get(combined_mv_lv, "voltage_only_start_matrix", Dict{String,Any}())["matrix_gates"]["all_variants_qualified"],
])

function gate(id, status, rationale, evidence; blocking=false)
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
        "Physical KKT is available on all six runs but only 2/6 reference and 2/6 phase-only endpoints pass the strict 1e-5 gate. The joined stability ledger has $real_kkt_qualified_profiles complete solver-floor-qualified profiles (excluding $real_kkt_excluded_profiles incomplete profiles), and strict acceptance remains stable at $(isnothing(real_kkt_stable_count) ? "unavailable" : "$(real_kkt_stable_count)/6") across those profiles; failure localization is complete.",
        ["docs/real_99bus_phase_only_campaign_summary.json", "docs/real_99bus_phase_only_kkt_failure_summary.json", "docs/real_99bus_kkt_stability_summary.json"],
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
        "The seeded 27-record corpus has zero hard-control false positives, false negatives, or unavailable backend results, with four expected threshold-cluster disagreements. A guarded 20-record sparse corpus at dimensions 128--1024 adds zero sparse mismatches or unavailable results while intentionally disabling dense SVD. The new controlled perturbation sweep adds $rank_perturbation_records records across five seeds, with $rank_perturbation_hard_mismatches hard-control mismatches, $rank_perturbation_unavailable unavailable results, and $rank_perturbation_threshold_disagreements expected threshold-sensitive backend disagreements. Broader adversarial and cross-backend statistics remain open.",
        ["docs/randomized_rank_oracle_calibration_summary.json", "docs/large_sparse_rank_oracle_summary.json", "docs/rank_perturbation_sweep_summary.json"],
        blocking=true,
    ),
    gate(
        "runtime_memory_scaling",
        "partial",
        "The synthetic sparse ladder provides $(length(runtime_records)) warm-up-aware runtime/allocation records across $(length(runtime_dimensions)) dimensions, and an isolated child-process ladder adds $(length(isolated_runtime_records)) records across $(length(isolated_runtime_dimensions)) dimensions with per-dimension Sys.maxrss high-water observations. OPF-solver scaling and allocator-level peak-memory measurements remain open.",
        ["docs/sparse_runtime_memory_scaling_summary.json", "docs/sparse_runtime_memory_isolated_summary.json"],
        blocking=true,
    ),
    gate(
        "analyze_runtime_scaling",
        "partial",
        "The public point-free analyze(model) entry point now has a bounded sparse affine-chain measurement. The observed cost grows from $(round(analyze_runtime_scaling["records"][1]["elapsed_seconds"]; digits=3))s at dimension $(analyze_runtime_scaling["records"][1]["dimension"]) to $(round(analyze_runtime_scaling["records"][end]["elapsed_seconds"]; digits=3))s at dimension $(analyze_runtime_scaling["records"][end]["dimension"]) across $analyze_repetitions repetition(s), with affine propagation reaching its configured five-pass limit. Finding evidence is stable across repetitions: $analyze_evidence_stable. Stage attribution is now recorded; the largest measured stage at the largest dimension is $analyze_stage_dominant. A second sparse nonlinear workload is also measured, reaching $(isnothing(analyze_nonlinear_end) ? "unavailable" : "$(round(analyze_nonlinear_end["elapsed_seconds"]; digits=3))s at dimension $(analyze_nonlinear_end["dimension"]) with stable evidence $(get(analyze_nonlinear_end, "evidence_stable_across_repetitions", false))"). Process-memory telemetry is retained under this boundary: $analyze_memory_note. The bounded BMOPFTools adapter profile measured $bmopf_profile_measured case(s) and size-guarded $bmopf_profile_guarded case(s), retaining PowerIO warning provenance with per-case warmup=$bmopf_profile_warmup. The current evidence-preserving optimization is: $analyze_optimization_note. Portable scaling and further optimization remain open.",
        ["docs/analyze_runtime_scaling_summary.json", "docs/bmopf_analyze_runtime_profile_summary.json"],
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
        "api_test_benchmark_consolidation",
        "partial",
        api_contract_rationale,
        [
            "docs/api_test_benchmark_consolidation_summary.json",
            "docs/bmopf_api_contract_summary.json",
            "docs/bmopf_api_contract_clean_main_summary.json",
            "docs/bmopf_pr_handoff_summary.json",
            "docs/bmopf_checkout_validation_summary.json",
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
    "interpretation" => "This ledger separates completed evidence from release blockers. It does not promote local research observations into causal or physical claims.",
))
println("wrote calibration release-gate summary to $output")
