#!/usr/bin/env julia

"""Summarize the deterministic restarted/harmonic smallest-mode corpus."""

include(joinpath(@__DIR__, "common.jl"))
using .NLPDiagnosticsBenchmarkCommon

const ROOT = repo_root()
const INPUT = "work/restarted-smallest-singular-calibration.json"
const OUTPUT = abspath(isempty(ARGS) ?
    joinpath(ROOT, "docs", "smallest_singular_calibration_summary.json") : ARGS[1])

calibration = read_summary(INPUT)
records = get(calibration, "records", Any[])
length(records) == 10 || error("expected 10 smallest-singular calibration cases")
get(calibration, "all_expectations_matched", false) ||
    error("smallest-singular calibration expectations did not match")

crosscheck_counts = get(calibration, "crosscheck_relation_counts", Dict{String,Any}())
crosscheck_adverse_count = sum(
    value for (key, value) in crosscheck_counts if key != "agreement"
)

case_rows = [
    Dict{String,Any}(
        "name" => record["name"],
        "expected_relation" => record["expected_relation"],
        "restarted_relation" => record["relation"],
        "harmonic_relation" => record["harmonic_relation"],
        "crosscheck_relation" => record["crosscheck_relation"],
        "expectation_matched" => record["expectation_matched"],
        "harmonic_expectation_matched" => record["harmonic_expectation_matched"],
        "crosscheck_expectation_matched" => record["crosscheck_expectation_matched"],
        "restarted_converged" => record["converged"],
        "harmonic_converged" => record["harmonic_converged"],
    )
    for record in records
]

write_json(OUTPUT, Dict{String,Any}(
    "schema_version" => "nlpdiagnostics-smallest-singular-calibration-v1",
    "source" => Dict(
        "runner" => "benchmarks/summarize_smallest_singular_calibration.jl",
        "calibration_artifact" => INPUT,
        "policy" => "Adverse and unresolved relations are retained as calibration evidence; no candidate is promoted to a rank certificate.",
    ),
    "environment" => Dict(
        "julia_version" => string(VERSION),
        "active_project" => Base.active_project(),
        "git_revision" => git_revision(),
        "git_worktree_dirty" => !isempty(git_status_entries()),
    ),
    "case_count" => length(records),
    "all_expectations_matched" => get(calibration, "all_expectations_matched", false),
    "restarted_relation_counts" => get(calibration, "relation_counts", Dict{String,Any}()),
    "harmonic_relation_counts" => get(calibration, "harmonic_relation_counts", Dict{String,Any}()),
    "dense_free_crosscheck" => Dict(
        "relation_counts" => crosscheck_counts,
        "agreement_count" => get(crosscheck_counts, "agreement", 0),
        "adverse_relation_count" => crosscheck_adverse_count,
        "adverse_relations" => sort!(collect(setdiff(
            collect(keys(crosscheck_counts)), ["agreement"],
        ))),
    ),
    "cases" => case_rows,
    "interpretation" => Dict(
        "claim" => "The ten-case corpus makes restarted, harmonic, and dense-free crosscheck relations auditable, including expected nonconvergence and disagreement controls.",
        "does_not_establish" => [
            "a mathematical rank certificate",
            "universal convergence or tolerance behavior",
            "physical interpretation of any candidate direction",
        ],
    ),
))
println("wrote smallest-singular calibration summary to $OUTPUT")
