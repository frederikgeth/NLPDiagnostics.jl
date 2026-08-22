#!/usr/bin/env julia

"""Build the machine-readable calibration release-gate ledger from summaries."""

using JSON

const ROOT = normpath(joinpath(@__DIR__, ".."))

function read_summary(relative)
    path = joinpath(ROOT, relative)
    isfile(path) || error("required summary is missing: $relative")
    return JSON.parsefile(path)
end

real_campaign = read_summary("docs/real_99bus_phase_only_campaign_summary.json")
real_kkt = read_summary("docs/real_99bus_phase_only_kkt_failure_summary.json")
real_covariance = read_summary("docs/real_99bus_phase_only_covariance_summary.json")
ibr_tolerance = read_summary("docs/bmopf_30bus_ibr_p_upper_tolerance_margin_summary.json")
ibr_sparse = read_summary("docs/bmopf_30bus_ibr_p_upper_sparse_jacobian_audit_summary.json")
rank_oracles = read_summary("docs/randomized_rank_oracle_calibration_summary.json")
runtime_scaling = read_summary("docs/sparse_runtime_memory_scaling_summary.json")
large_sparse_rank = read_summary("docs/large_sparse_rank_oracle_summary.json")
api_consolidation = read_summary("docs/api_test_benchmark_consolidation_summary.json")

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
        "The consolidation audit now inventories 510 root exports, 111 root testsets across nine included test modules, 103 benchmark scripts, and complete schema coverage for 43 JSON artifacts. A typed unavailable-reason schema and non-breaking Advanced facade are now available, while broad adapter adoption, root-export tiering, and helper centralization remain open.",
        ["docs/api_test_benchmark_consolidation_summary.json"],
        blocking=true,
    ),
]

output = abspath(get(ENV, "NLPDIAGNOSTICS_CALIBRATION_RELEASE_OUTPUT", joinpath(ROOT, "docs", "calibration_release_gate_summary.json")))
mkpath(dirname(output))
write(output, JSON.json(Dict(
    "schema_version" => "nlpdiagnostics-calibration-release-gate-summary-v1",
    "generated_by" => basename(@__FILE__),
    "project_phase" => "consolidate_and_calibrate",
    "release_ready" => all(gate -> gate["status"] == "pass", gates),
    "blocking_gate_count" => count(gate -> gate["blocking"] === true, gates),
    "gates" => gates,
    "interpretation" => "This ledger separates completed evidence from release blockers. It does not promote local research observations into causal or physical claims.",
)))
println("wrote calibration release-gate summary to $output")
