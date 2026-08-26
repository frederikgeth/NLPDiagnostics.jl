#!/usr/bin/env julia

"""Aggregate numerical-rank calibration statistics across saved corpora.

The source campaigns already preserve their own construction and backend
provenance. This ledger joins their declared hard-control and threshold-
sensitivity counts without treating dense-unavailable large sparse cases as
false positives or false negatives.
"""

include(joinpath(@__DIR__, "common.jl"))
using .NLPDiagnosticsBenchmarkCommon

const ROOT = repo_root()
const OUTPUT = abspath(isempty(ARGS) ?
    joinpath(ROOT, "docs", "rank_calibration_statistics_summary.json") : ARGS[1])
const SEEDED_ARTIFACT = "docs/randomized_rank_oracle_calibration_summary.json"
const LARGE_SPARSE_ARTIFACT = "docs/large_sparse_rank_oracle_summary.json"
const PERTURBATION_ARTIFACT = "docs/rank_perturbation_sweep_summary.json"
const ADVERSARIAL_EXTENSION_ARTIFACT = "docs/rank_adversarial_extension_summary.json"
const THIRD_BACKEND_ARTIFACT = "docs/rank_third_backend_capability_summary.json"
const NORMAL_EIGEN_ARTIFACT = "docs/normal_eigen_rank_calibration_summary.json"
const NORMAL_EIGEN_PERSISTENCE_ARTIFACT = "docs/normal_eigen_policy_persistence_summary.json"
const NORMAL_EIGEN_BMOPF_ARTIFACT = "docs/bmopf_normal_eigen_jacobian_validation_summary.json"
const LARGE_SPARSE_BMOPF_ARTIFACT = "docs/bmopf_large_sparse_rank_screen_summary.json"
const LARGE_SPARSE_BMOPF_SAVED_ARTIFACT = "docs/bmopf_large_sparse_rank_screen_saved_result_summary.json"

seeded = read_summary(SEEDED_ARTIFACT)
large_sparse = read_summary(LARGE_SPARSE_ARTIFACT)
perturbation = read_summary(PERTURBATION_ARTIFACT)
adversarial_extension = read_summary(ADVERSARIAL_EXTENSION_ARTIFACT)
third_backend = read_summary(THIRD_BACKEND_ARTIFACT)
normal_eigen = read_summary(NORMAL_EIGEN_ARTIFACT)
normal_eigen_persistence = read_summary(NORMAL_EIGEN_PERSISTENCE_ARTIFACT)
normal_eigen_bmopf = read_summary(NORMAL_EIGEN_BMOPF_ARTIFACT)
large_sparse_bmopf = read_summary(LARGE_SPARSE_BMOPF_ARTIFACT)
large_sparse_bmopf_saved = read_summary(LARGE_SPARSE_BMOPF_SAVED_ARTIFACT)
seeded_hard = get(seeded, "hard_controls", Dict{String,Any}())
seeded_threshold = get(seeded, "threshold_controls", Dict{String,Any}())
large_by_case = get(large_sparse, "by_case", Dict{String,Any}())

hard_control_records = [
    get(seeded_hard, "record_count", 0),
    get(perturbation, "hard_control_count", 0),
    get(adversarial_extension, "hard_control_count", 0),
]
threshold_records = [
    get(seeded_threshold, "record_count", 0),
    get(perturbation, "threshold_sensitive_count", 0),
    get(adversarial_extension, "threshold_sensitive_count", 0),
]
hard_control_mismatches = [
    get(seeded_hard, "false_positive_count", 0) + get(seeded_hard, "false_negative_count", 0),
    get(perturbation, "hard_control_mismatch_count", 0),
    get(adversarial_extension, "hard_control_mismatch_count", 0),
]
hard_control_unavailable = [
    get(seeded_hard, "dense_unavailable_count", 0) + get(seeded_hard, "sparse_unavailable_count", 0),
    get(perturbation, "unavailable_count", 0),
    get(adversarial_extension, "unavailable_count", 0),
]
threshold_disagreements = [
    get(seeded_threshold, "backend_disagreement_count", 0),
    get(perturbation, "threshold_backend_disagreement_count", 0),
    get(adversarial_extension, "threshold_backend_disagreement_count", 0),
]
large_sparse_records = get(large_sparse, "record_count", 0)
large_sparse_unavailable = get(large_sparse, "sparse_unavailable_count", 0)
large_sparse_mismatches = get(large_sparse, "sparse_mismatch_count", 0)

const FINITE_SAMPLE_CONFIDENCE_LEVEL = 0.95

"""One-sided exact binomial upper bound when zero events are observed."""
function zero_event_upper_bound(sample_count::Integer, confidence_level::Real)
    sample_count > 0 || return 1.0
    alpha = 1 - confidence_level
    return 1 - alpha^(1 / sample_count)
end

hard_control_count = sum(hard_control_records)
finite_sample_zero_event_upper_bound = zero_event_upper_bound(
    hard_control_count,
    FINITE_SAMPLE_CONFIDENCE_LEVEL,
)

rate(count::Integer, total::Integer) = total == 0 ? nothing : count / total
corpus_rows = [
    Dict{String,Any}(
        "corpus" => "seeded_randomized",
        "hard_control_count" => hard_control_records[1],
        "hard_mismatch_count" => hard_control_mismatches[1],
        "hard_unavailable_count" => hard_control_unavailable[1],
        "hard_mismatch_rate" => rate(hard_control_mismatches[1], hard_control_records[1]),
        "threshold_sensitive_count" => threshold_records[1],
        "threshold_backend_disagreement_count" => threshold_disagreements[1],
        "threshold_disagreement_rate" => rate(threshold_disagreements[1], threshold_records[1]),
        "coverage_class" => "dense_and_sparse",
    ),
    Dict{String,Any}(
        "corpus" => "controlled_perturbation",
        "hard_control_count" => hard_control_records[2],
        "hard_mismatch_count" => hard_control_mismatches[2],
        "hard_unavailable_count" => hard_control_unavailable[2],
        "hard_mismatch_rate" => rate(hard_control_mismatches[2], hard_control_records[2]),
        "threshold_sensitive_count" => threshold_records[2],
        "threshold_backend_disagreement_count" => threshold_disagreements[2],
        "threshold_disagreement_rate" => rate(threshold_disagreements[2], threshold_records[2]),
        "coverage_class" => "dense_and_sparse",
    ),
    Dict{String,Any}(
        "corpus" => "large_sparse",
        "hard_control_count" => 0,
        "hard_mismatch_count" => large_sparse_mismatches,
        "hard_unavailable_count" => large_sparse_unavailable,
        "hard_mismatch_rate" => nothing,
        "threshold_sensitive_count" => 0,
        "threshold_backend_disagreement_count" => 0,
        "threshold_disagreement_rate" => nothing,
        "sparse_only_record_count" => large_sparse_records,
        "sparse_only_match_count" => large_sparse_records - large_sparse_unavailable - large_sparse_mismatches,
        "dense_unavailable_count" => get(large_sparse, "dense_unavailable_count", 0),
        "coverage_class" => "sparse_only",
    ),
    Dict{String,Any}(
        "corpus" => "deterministic_adversarial_extension",
        "hard_control_count" => hard_control_records[3],
        "hard_mismatch_count" => hard_control_mismatches[3],
        "hard_unavailable_count" => hard_control_unavailable[3],
        "hard_mismatch_rate" => rate(hard_control_mismatches[3], hard_control_records[3]),
        "threshold_sensitive_count" => threshold_records[3],
        "threshold_backend_disagreement_count" => threshold_disagreements[3],
        "threshold_disagreement_rate" => rate(threshold_disagreements[3], threshold_records[3]),
        "coverage_class" => "dense_and_sparse",
    ),
]

write_json(OUTPUT, Dict{String,Any}(
    "schema_version" => "nlpdiagnostics-rank-calibration-statistics-v2",
    "source" => Dict(
        "runner" => "benchmarks/summarize_rank_calibration_statistics.jl",
        "seeded_artifact" => SEEDED_ARTIFACT,
        "large_sparse_artifact" => LARGE_SPARSE_ARTIFACT,
        "perturbation_artifact" => PERTURBATION_ARTIFACT,
        "adversarial_extension_artifact" => ADVERSARIAL_EXTENSION_ARTIFACT,
        "third_backend_artifact" => THIRD_BACKEND_ARTIFACT,
        "normal_eigen_artifact" => NORMAL_EIGEN_ARTIFACT,
        "normal_eigen_persistence_artifact" => NORMAL_EIGEN_PERSISTENCE_ARTIFACT,
        "normal_eigen_bmopf_artifact" => NORMAL_EIGEN_BMOPF_ARTIFACT,
        "policy" => "Declared hard controls are counted for false-positive/false-negative statistics; threshold-sensitive controls remain disagreement evidence; dense-unavailable large sparse records are sparse-only coverage.",
    ),
    "environment" => Dict(
        "julia_version" => string(VERSION),
        "active_project" => Base.active_project(),
        "git_revision" => git_revision(),
        "git_worktree_dirty" => !isempty(git_status_entries()),
    ),
    "hard_controls" => Dict(
        "record_count" => hard_control_count,
        "false_positive_count" => get(seeded_hard, "false_positive_count", 0),
        "false_negative_count" => get(seeded_hard, "false_negative_count", 0),
        "mismatch_count" => sum(hard_control_mismatches),
        "unavailable_count" => sum(hard_control_unavailable),
        "dense_sparse_complete_count" => sum(hard_control_records),
        "all_match_and_available" => sum(hard_control_mismatches) == 0 && sum(hard_control_unavailable) == 0,
        "source_record_counts" => Dict(
            "seeded_randomized" => hard_control_records[1],
            "controlled_perturbation" => hard_control_records[2],
            "deterministic_adversarial_extension" => hard_control_records[3],
        ),
    ),
    "finite_sample_uncertainty" => Dict(
        "confidence_level" => FINITE_SAMPLE_CONFIDENCE_LEVEL,
        "sample_count" => hard_control_count,
        "observed_mismatch_count" => sum(hard_control_mismatches),
        "observed_unavailable_count" => sum(hard_control_unavailable),
        "zero_event_upper_bound" => finite_sample_zero_event_upper_bound,
        "method" => "one-sided exact zero-event binomial upper bound: 1 - alpha^(1/n)",
        "rates" => Dict(
            "false_positive_rate" => Dict(
                "observed_count" => get(seeded_hard, "false_positive_count", 0),
                "upper_bound_if_zero_observed" => finite_sample_zero_event_upper_bound,
            ),
            "false_negative_rate" => Dict(
                "observed_count" => get(seeded_hard, "false_negative_count", 0),
                "upper_bound_if_zero_observed" => finite_sample_zero_event_upper_bound,
            ),
            "mismatch_rate" => Dict(
                "observed_count" => sum(hard_control_mismatches),
                "upper_bound_if_zero_observed" => finite_sample_zero_event_upper_bound,
            ),
            "unavailable_rate" => Dict(
                "observed_count" => sum(hard_control_unavailable),
                "upper_bound_if_zero_observed" => finite_sample_zero_event_upper_bound,
            ),
        ),
        "qualification" => "Finite-sample uncertainty context for this corpus, not a universal error guarantee or tolerance recommendation.",
    ),
    "threshold_sensitive_controls" => Dict(
        "record_count" => sum(threshold_records),
        "backend_disagreement_count" => sum(threshold_disagreements),
        "backend_agreement_count" => sum(threshold_records) - sum(threshold_disagreements),
        "interpretation" => "Disagreements are retained as tolerance-sensitive numerical policy evidence, not algebraic-rank failures.",
        "source_record_counts" => Dict(
            "seeded_randomized" => threshold_records[1],
            "controlled_perturbation" => threshold_records[2],
            "deterministic_adversarial_extension" => threshold_records[3],
        ),
    ),
    "cross_backend_calibration_matrix" => Dict(
        "corpus_rows" => corpus_rows,
        "hard_control_relation" => Dict(
            "dense_sparse_complete_count" => hard_control_count,
            "agreement_count" => hard_control_count - sum(hard_control_mismatches) - sum(hard_control_unavailable),
            "mismatch_count" => sum(hard_control_mismatches),
            "unavailable_count" => sum(hard_control_unavailable),
        ),
        "threshold_relation" => Dict(
            "record_count" => sum(threshold_records),
            "agreement_count" => sum(threshold_records) - sum(threshold_disagreements),
            "disagreement_count" => sum(threshold_disagreements),
        ),
        "sparse_only_relation" => Dict(
            "record_count" => large_sparse_records,
            "match_count" => large_sparse_records - large_sparse_unavailable - large_sparse_mismatches,
            "mismatch_count" => large_sparse_mismatches,
            "unavailable_count" => large_sparse_unavailable,
            "dense_unavailable_count" => get(large_sparse, "dense_unavailable_count", 0),
        ),
        "interpretation" => "Rows preserve corpus provenance and distinguish hard-control agreement, threshold-sensitive disagreement, and sparse-only coverage; no row is a universal rank certificate.",
    ),
    "third_backend_capability" => Dict(
        "status" => get(third_backend, "status", "missing"),
        "adapter_status" => get(third_backend, "adapter_status", "missing"),
        "vetted_backend_count" => get(third_backend, "vetted_backend_count", 0),
        "reason" => get(third_backend, "reason", "capability artifact missing"),
        "artifact" => THIRD_BACKEND_ARTIFACT,
        "interpretation" => "Capability evidence is kept separate from dense/sparse calibration results; package discovery does not count as vetted backend evidence.",
    ),
    "normal_eigen_calibration" => Dict(
        "status" => get(normal_eigen, "hard_controls_complete", false) ? "complete" : "partial",
        "record_count" => get(normal_eigen, "record_count", 0),
        "hard_control_count" => get(normal_eigen, "hard_control_count", 0),
        "hard_control_mismatch_count" => get(normal_eigen, "hard_control_mismatch_count", 0),
        "threshold_sensitive_count" => get(normal_eigen, "threshold_sensitive_count", 0),
        "threshold_backend_disagreement_count" => get(normal_eigen, "threshold_backend_disagreement_count", 0),
        "artifact" => NORMAL_EIGEN_ARTIFACT,
        "interpretation" => "The normal-eigen path is an experimental third backend; its squared-spectrum disagreements are retained as tolerance evidence and do not establish a production rank policy.",
    ),
    "normal_eigen_policy_persistence" => Dict(
        "case_count" => get(normal_eigen_persistence, "case_count", 0),
        "policy_record_count" => get(normal_eigen_persistence, "policy_record_count", 0),
        "repeatability_failure_count" => get(normal_eigen_persistence, "repeatability_failure_count", 0),
        "cross_backend_disagreement_count" => get(normal_eigen_persistence, "cross_backend_disagreement_count", 0),
        "unavailable_count" => get(normal_eigen_persistence, "unavailable_count", 0),
        "artifact" => NORMAL_EIGEN_PERSISTENCE_ARTIFACT,
        "interpretation" => "Repeated same-point calls and scaling-policy comparisons preserve instability as evidence; no basis-column or policy preference is promoted.",
    ),
    "normal_eigen_bmopf_validation" => Dict(
        "snapshot_count" => get(normal_eigen_bmopf, "snapshot_count", 0),
        "successful_snapshot_count" => get(normal_eigen_bmopf, "successful_snapshot_count", 0),
        "policy_record_count" => get(normal_eigen_bmopf, "policy_record_count", 0),
        "all_policy_records_available" => get(normal_eigen_bmopf, "all_policy_records_available", false),
        "cross_backend_agreement_count" => get(normal_eigen_bmopf, "cross_backend_agreement_count", 0),
        "cross_backend_disagreement_count" => get(normal_eigen_bmopf, "cross_backend_disagreement_count", 0),
        "cross_backend_unavailable_count" => get(normal_eigen_bmopf, "cross_backend_unavailable_count", 0),
        "artifact" => NORMAL_EIGEN_BMOPF_ARTIFACT,
        "interpretation" => "Trusted 30/99-bus solver-result points validate backend availability and local rank agreement under scaling policies; larger snapshots are explicitly size-guarded and no physical rank interpretation is inferred.",
    ),
    "large_sparse_bmopf_screen" => Dict(
        "snapshot" => get(large_sparse_bmopf, "snapshot", nothing),
        "model_variable_count" => get(large_sparse_bmopf, "model_variable_count", 0),
        "point_provenance_kind" => get(get(large_sparse_bmopf, "evaluation", Dict{String,Any}()), "point_provenance_kind", nothing),
        "unscaled_rank" => get(get(get(large_sparse_bmopf, "sparse_qr", Dict{String,Any}()), "comparison", Dict{String,Any}()), "unscaled_rank", nothing),
        "row_column_rank" => get(get(get(large_sparse_bmopf, "sparse_qr", Dict{String,Any}()), "comparison", Dict{String,Any}()), "row_column_rank", nothing),
        "scaling_sensitive" => get(get(get(large_sparse_bmopf, "sparse_qr", Dict{String,Any}()), "comparison", Dict{String,Any}()), "scaling_sensitive", false),
        "artifact" => LARGE_SPARSE_BMOPF_ARTIFACT,
        "interpretation" => "A guarded 538-bus synthetic coordinate probe provides sparse-only rank and fill evidence; it is not a solver endpoint or physical nullspace certificate.",
    ),
    "large_sparse_bmopf_saved_result_screen" => Dict(
        "snapshot" => get(large_sparse_bmopf_saved, "snapshot", nothing),
        "model_variable_count" => get(large_sparse_bmopf_saved, "model_variable_count", 0),
        "point_provenance_kind" => get(get(large_sparse_bmopf_saved, "evaluation", Dict{String,Any}()), "point_provenance_kind", nothing),
        "point_provenance_complete" => get(get(large_sparse_bmopf_saved, "evaluation", Dict{String,Any}()), "point_provenance_complete", false),
        "unscaled_rank" => get(get(get(large_sparse_bmopf_saved, "sparse_qr", Dict{String,Any}()), "comparison", Dict{String,Any}()), "unscaled_rank", nothing),
        "row_column_rank" => get(get(get(large_sparse_bmopf_saved, "sparse_qr", Dict{String,Any}()), "comparison", Dict{String,Any}()), "row_column_rank", nothing),
        "scaling_sensitive" => get(get(get(large_sparse_bmopf_saved, "sparse_qr", Dict{String,Any}()), "comparison", Dict{String,Any}()), "scaling_sensitive", false),
        "artifact" => LARGE_SPARSE_BMOPF_SAVED_ARTIFACT,
        "interpretation" => "A saved solver-result point on the 538-bus snapshot provides sparse-only rank evidence with complete point provenance; dense rank remains guarded.",
    ),
    "large_sparse_sparse_only" => Dict(
        "record_count" => large_sparse_records,
        "sparse_unavailable_count" => large_sparse_unavailable,
        "sparse_mismatch_count" => large_sparse_mismatches,
        "sparse_match_count" => large_sparse_records - large_sparse_unavailable - large_sparse_mismatches,
        "dense_unavailable_count" => get(large_sparse, "dense_unavailable_count", 0),
        "case_count" => length(large_by_case),
        "all_sparse_expectations_matched" => get(large_sparse, "all_sparse_expectations_matched", false),
        "interpretation" => "Sparse-only records extend dimensions and constructions while dense SVD is intentionally disabled by guard.",
    ),
    "interpretation" => Dict(
        "claim" => "Saved numerical-rank calibration corpora have explicit aggregate hard-control and threshold-sensitivity statistics.",
        "does_not_establish" => [
            "a universal tolerance choice",
            "a zero-error guarantee outside this finite calibration corpus",
            "algebraic rank for threshold-sensitive cases",
            "OPF physical interpretation or solver KKT conditioning",
        ],
    ),
))
println("wrote rank calibration statistics summary to $OUTPUT")
