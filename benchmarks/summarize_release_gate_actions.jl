#!/usr/bin/env julia

"""Turn the blocking release gates into an explicit execution ledger.

This ledger orders work and records closure conditions; it never changes gate
status or infers readiness from a partial result.
"""

include(joinpath(@__DIR__, "common.jl"))
using .NLPDiagnosticsBenchmarkCommon

const ROOT = repo_root()
const INPUT = "docs/calibration_release_gate_summary.json"
const OUTPUT = abspath(isempty(ARGS) ?
    joinpath(ROOT, "docs", "release_gate_action_summary.json") : ARGS[1])

const ACTIONS = Dict{String,Dict{String,Any}}(
    "numerical_rank_false_positive_negative_statistics" => Dict(
        "priority" => 1,
        "next_deliverable" => "Extend the balanced 538-bus PU/SI sweep to t21/t22 and verify continued full SI mapping coverage.",
        "closure_condition" => "Hard-control false-positive/false-negative and unavailable statistics are complete across the declared corpus, and backend disagreements are classified rather than silently resolved.",
        "dependency" => "None; this is the highest-priority numerical-algebra track.",
    ),
    "real_99bus_physical_kkt" => Dict(
        "priority" => 2,
        "next_deliverable" => "Extend trusted real-99-bus endpoint coverage and localize the remaining ibr_p_upper strict-KKT boundary.",
        "closure_condition" => "The strict 1e-5 physical-KKT gate is accepted on the declared paired endpoint corpus, or a reviewed release decision explicitly records why the gate changes.",
        "dependency" => "Preserve solver-point provenance, covariance evidence, and strict tolerance semantics while extending the corpus.",
    ),
    "runtime_memory_scaling" => Dict(
        "priority" => 3,
        "next_deliverable" => "Add guarded OPF-solver scaling and allocator-level peak-memory evidence beyond the synthetic sparse ladder.",
        "closure_condition" => "Solver-workload scaling and peak-memory measurements are repeatable under explicit size and process guards, or remain explicitly unavailable with a reviewed release boundary.",
        "dependency" => "Use isolated child processes and retain resource skips; do not extrapolate synthetic sparse behavior.",
    ),
    "analyze_runtime_scaling" => Dict(
        "priority" => 4,
        "next_deliverable" => "Run the isolated analyze portability validator against a second reviewed environment with allocator-level peak telemetry.",
        "closure_condition" => "The broader workload campaign has stable findings, stage/resource attribution, and documented portability limits; optimization candidates are either supported by repeated A/B evidence or explicitly not promoted.",
        "dependency" => "Keep the public API unchanged and preserve repeatability and memory provenance.",
    ),
    "api_test_benchmark_consolidation" => Dict(
        "priority" => 5,
        "next_deliverable" => "Review root-only legacy ownership and migrate only explicitly approved Stable/Advanced symbols.",
        "closure_condition" => "Every root-only export has a reviewed ownership or migration decision, and helper/schema/test consolidation remains reproducible in the known environment.",
        "dependency" => "Usage and candidate batches are triage evidence only; no automatic promotion or removal is allowed.",
    ),
)

gate_summary = read_summary(INPUT)
gates = get(gate_summary, "gates", Any[])
blocking = filter(gate -> get(gate, "blocking", false), gates)
isempty(blocking) && error("release gate summary has no blocking gates")

rows = Dict{String,Any}[]
for gate in blocking
    id = gate["id"]
    haskey(ACTIONS, id) || error("no action mapping for blocking gate $id")
    action = ACTIONS[id]
    push!(rows, merge(
        Dict{String,Any}(
            "id" => id,
            "status" => gate["status"],
            "blocking" => gate["blocking"],
            "evidence" => gate["evidence"],
        ), action,
    ))
end
sort!(rows; by = row -> row["priority"])

write_json(OUTPUT, Dict{String,Any}(
    "schema_version" => "nlpdiagnostics-release-gate-actions-v1",
    "source" => Dict(
        "runner" => "benchmarks/summarize_release_gate_actions.jl",
        "gate_summary" => INPUT,
        "policy" => "Actions sequence work only; this artifact never changes gate status or release readiness.",
    ),
    "environment" => Dict(
        "julia_version" => string(VERSION),
        "active_project" => Base.active_project(),
        "git_revision" => git_revision(),
        "git_worktree_dirty" => !isempty(git_status_entries()),
    ),
    "blocking_gate_count" => length(rows),
    "all_blocking_gates_mapped" => length(rows) == get(gate_summary, "blocking_gate_count", 0),
    "recommended_order" => [row["id"] for row in rows],
    "actions" => rows,
    "interpretation" => Dict(
        "claim" => "Each current blocking gate has an explicit next deliverable and closure condition ordered by roadmap priority.",
        "does_not_establish" => [
            "release readiness",
            "that a closure condition has been satisfied",
            "permission to relax a numerical or physical gate",
        ],
    ),
))
println("wrote release-gate action summary to $OUTPUT")
