#!/usr/bin/env julia

"""Classify rank-backend disagreements without resolving tolerance policy."""

using JSON

Base.include(@__MODULE__, joinpath(@__DIR__, "common.jl"))
using .NLPDiagnosticsBenchmarkCommon: git_revision, git_status_entries, read_summary, write_json

const ROOT = abspath(joinpath(@__DIR__, ".."))
const OUTPUT = abspath(isempty(ARGS) ? joinpath(ROOT, "docs", "rank_threshold_disagreement_summary.json") : ARGS[1])

randomized = read_summary("docs/randomized_rank_oracle_calibration_summary.json")
perturbation = read_summary("docs/rank_perturbation_sweep_summary.json")
adversarial = read_summary("docs/rank_adversarial_extension_summary.json")
statistics = read_summary("docs/rank_calibration_statistics_summary.json")

randomized_threshold = get(randomized, "threshold_controls", Dict{String,Any}())
rows = Dict{String,Any}[
    Dict{String,Any}(
        "corpus" => "seeded_randomized",
        "record_count" => get(randomized_threshold, "record_count", 0),
        "threshold_sensitive_count" => get(randomized_threshold, "record_count", 0),
        "backend_agreement_count" => get(randomized_threshold, "backend_agreement_count", 0),
        "backend_disagreement_count" => get(randomized_threshold, "backend_disagreement_count", 0),
        "unavailable_count" => 0,
        "disagreement_names" => get(randomized_threshold, "disagreements", Any[]),
        "classification" => "threshold_policy_sensitivity",
    ),
]
for (name, summary) in (("controlled_perturbation", perturbation), ("deterministic_adversarial_extension", adversarial))
    push!(rows, Dict{String,Any}(
        "corpus" => name,
        "record_count" => get(summary, "record_count", 0),
        "threshold_sensitive_count" => get(summary, "threshold_sensitive_count", 0),
        "backend_agreement_count" => get(summary, "record_count", 0) - get(summary, "threshold_backend_disagreement_count", 0) - get(summary, "unavailable_count", 0),
        "backend_disagreement_count" => get(summary, "threshold_backend_disagreement_count", 0),
        "unavailable_count" => get(summary, "unavailable_count", 0),
        "disagreement_names" => get(summary, "threshold_backend_disagreement_names", Any[]),
        "classification" => get(summary, "threshold_backend_disagreement_count", 0) > 0 ? "threshold_policy_sensitivity" : "no_disagreement_observed",
    ))
end

hard_controls = get(statistics, "hard_controls", Dict{String,Any}())
threshold_controls = get(statistics, "threshold_sensitive_controls", Dict{String,Any}())
write_json(OUTPUT, Dict{String,Any}(
    "schema_version" => "nlpdiagnostics-rank-threshold-disagreement-v1",
    "source" => Dict{String,Any}(
        "summarizer" => "benchmarks/summarize_rank_threshold_disagreements.jl",
        "inputs" => [
            "docs/randomized_rank_oracle_calibration_summary.json",
            "docs/rank_perturbation_sweep_summary.json",
            "docs/rank_adversarial_extension_summary.json",
            "docs/rank_calibration_statistics_summary.json",
        ],
    ),
    "environment" => Dict{String,Any}(
        "julia_version" => string(VERSION),
        "git_revision" => git_revision(),
        "git_worktree_dirty" => !isempty(git_status_entries()),
    ),
    "corpus_count" => length(rows),
    "rows" => rows,
    "hard_control_count" => get(hard_controls, "record_count", 0),
    "hard_control_mismatch_count" => get(hard_controls, "mismatch_count", 0),
    "hard_control_unavailable_count" => get(hard_controls, "unavailable_count", 0),
    "threshold_sensitive_count" => get(threshold_controls, "record_count", 0),
    "threshold_backend_disagreement_count" => get(threshold_controls, "backend_disagreement_count", 0),
    "threshold_backend_agreement_count" => get(threshold_controls, "backend_agreement_count", 0),
    "classification" => "All observed disagreements are retained as threshold-policy sensitivity. No hard-control mismatch or unavailable backend is reclassified as a disagreement, and no tolerance is changed by this ledger.",
    "next_action" => "Review the threshold-sensitive corpus and either document the declared policy boundary or add a vetted independent backend before release.",
))
println("wrote rank threshold disagreement summary to $OUTPUT")
