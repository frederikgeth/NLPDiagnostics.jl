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

seeded = read_summary(SEEDED_ARTIFACT)
large_sparse = read_summary(LARGE_SPARSE_ARTIFACT)
perturbation = read_summary(PERTURBATION_ARTIFACT)
seeded_hard = get(seeded, "hard_controls", Dict{String,Any}())
seeded_threshold = get(seeded, "threshold_controls", Dict{String,Any}())
large_by_case = get(large_sparse, "by_case", Dict{String,Any}())

hard_control_records = [
    get(seeded_hard, "record_count", 0),
    get(perturbation, "hard_control_count", 0),
]
threshold_records = [
    get(seeded_threshold, "record_count", 0),
    get(perturbation, "threshold_sensitive_count", 0),
]
hard_control_mismatches = [
    get(seeded_hard, "false_positive_count", 0) + get(seeded_hard, "false_negative_count", 0),
    get(perturbation, "hard_control_mismatch_count", 0),
]
hard_control_unavailable = [
    get(seeded_hard, "dense_unavailable_count", 0) + get(seeded_hard, "sparse_unavailable_count", 0),
    get(perturbation, "unavailable_count", 0),
]
threshold_disagreements = [
    get(seeded_threshold, "backend_disagreement_count", 0),
    get(perturbation, "threshold_backend_disagreement_count", 0),
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

write_json(OUTPUT, Dict{String,Any}(
    "schema_version" => "nlpdiagnostics-rank-calibration-statistics-v1",
    "source" => Dict(
        "runner" => "benchmarks/summarize_rank_calibration_statistics.jl",
        "seeded_artifact" => SEEDED_ARTIFACT,
        "large_sparse_artifact" => LARGE_SPARSE_ARTIFACT,
        "perturbation_artifact" => PERTURBATION_ARTIFACT,
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
        ),
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
