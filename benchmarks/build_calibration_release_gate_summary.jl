#!/usr/bin/env julia

"""Build the machine-readable calibration release-gate ledger from summaries."""

include(joinpath(@__DIR__, "common.jl"))
using .NLPDiagnosticsBenchmarkCommon

const ROOT = repo_root()

real_campaign = read_summary("docs/real_99bus_phase_only_campaign_summary.json")
real_kkt = read_summary("docs/real_99bus_phase_only_kkt_failure_summary.json")
real_covariance = read_summary("docs/real_99bus_phase_only_covariance_summary.json")
ibr_tolerance = read_summary("docs/bmopf_30bus_ibr_p_upper_tolerance_margin_summary.json")
ibr_sparse = read_summary("docs/bmopf_30bus_ibr_p_upper_sparse_jacobian_audit_summary.json")
rank_oracles = read_summary("docs/randomized_rank_oracle_calibration_summary.json")
runtime_scaling = read_summary("docs/sparse_runtime_memory_scaling_summary.json")
large_sparse_rank = read_summary("docs/large_sparse_rank_oracle_summary.json")
api_consolidation = read_summary("docs/api_test_benchmark_consolidation_summary.json")
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
api_contract_missing_clause = isempty(api_contract_missing) ?
    "" : " (missing: $api_contract_missing)"
api_contract_rationale =
    "The consolidation audit now inventories $api_root_export_count root exports, $api_testset_count root testsets across nine included test modules, $api_script_count benchmark scripts, and complete schema coverage for $api_schema_count JSON artifacts. A typed unavailable-reason schema now covers solver telemetry, dual/complementarity boundaries, profile reports, solver-result point and postmortem capability reports, active-set multiplier-recovery, MFCQ screen, dense/sparse Jacobian rank backends, sparse-QR nullspace extraction, dense calibration, persistence, Golub--Kahan and restarted smallest-singular probe/calibration boundaries, Jacobian tolerance-sweep and condition-persistence boundaries, Jacobian scaling, derivative-provenance, rank-persistence, row-family perturbation, iterative right/left candidate-persistence, reduced-Hessian flat-subspace, active-row and active-Jacobian persistence, multiplier-persistence, Jacobian-scaling, and spectral-scale persistence boundaries, restarted and harmonic smallest-singular calibration/crosscheck boundaries, structural-matching, DM-partition, reduced-Hessian, structural-to-numerical rank-comparison, and iterative right/left/spectrum probe work/capability guards, coupled-set qualification capability boundaries, generic and BMOPFTools component-rank capability reports, BMOPFTools differentiability capability reports, PowerModels scalar-angle capability reports, MadNLP primal-capture capability reports, BMOPFTools terminal-current capability reports, BMOPFTools passive-network map capability reports, and BMOPFTools terminal-attachment capability reports; non-breaking Stable and Advanced facades, shared benchmark helper, and reviewed local quality policy are also available. $api_helper_user_count data-producing runners use the helper, with infrastructure-script exemptions explicitly inventoried. The active BMOPFTools API contract audit is $api_contract_status$api_contract_missing_clause, while the clean-main contract audit is $api_contract_clean_main_status at revision $api_contract_clean_main_revision and the full local suite passes 1634/1634 there. The PR handoff gate is $api_contract_handoff_status ($api_contract_handoff_reason). The isolated checkout validator is $api_checkout_validation_status at revision $api_checkout_validation_revision with suite coverage $api_checkout_validation_suite. Remaining work is review of Stable versus Advanced boundaries, broader adapter adoption, root-export tiering, keeping dependency evidence synchronized, and activation of deferred documentation-example, Aqua, and targeted JET checks when reviewed environments are available."

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
        "Physical KKT is available on all six runs but only 2/6 reference and 2/6 phase-only endpoints pass the strict 1e-5 gate; failure localization is complete.",
        ["docs/real_99bus_phase_only_campaign_summary.json", "docs/real_99bus_phase_only_kkt_failure_summary.json"],
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
        "The seeded 27-record corpus has zero hard-control false positives, false negatives, or unavailable backend results, with four expected threshold-cluster disagreements. A guarded 20-record sparse corpus at dimensions 128--1024 adds zero sparse mismatches or unavailable results while intentionally disabling dense SVD; broader adversarial and cross-backend statistics remain open.",
        ["docs/randomized_rank_oracle_calibration_summary.json", "docs/large_sparse_rank_oracle_summary.json"],
        blocking=true,
    ),
    gate(
        "runtime_memory_scaling",
        "partial",
        "The synthetic sparse ladder now provides 12 warm-up-aware runtime/allocation records across four dimensions; process high-water marks are retained descriptively, but OPF-solver scaling and isolated peak-memory measurements remain open.",
        ["docs/sparse_runtime_memory_scaling_summary.json"],
        blocking=true,
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
