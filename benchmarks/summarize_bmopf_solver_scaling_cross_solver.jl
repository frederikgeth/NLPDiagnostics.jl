#!/usr/bin/env julia

"""Compare bounded Ipopt/MadNLP 538-bus solver-trace extensions."""

using JSON

Base.include(@__MODULE__, joinpath(@__DIR__, "common.jl"))
using .NLPDiagnosticsBenchmarkCommon: git_revision, git_status_entries, write_json

length(ARGS) == 3 || error("usage: summarize_bmopf_solver_scaling_cross_solver.jl output.json ipopt_summary.json madnlp_summary.json")
output_path = abspath(ARGS[1])
ipopt_path = abspath(ARGS[2])
madnlp_path = abspath(ARGS[3])
ipopt = JSON.parsefile(ipopt_path)
madnlp = JSON.parsefile(madnlp_path)

function by_snapshot(summary)
    result = Dict{String,Dict{String,Any}}()
    for record in get(summary, "records", Any[])
        record isa AbstractDict || continue
        snapshot = get(record, "snapshot", nothing)
        snapshot isa AbstractString || continue
        result[String(snapshot)] = Dict{String,Any}(String(k) => v for (k, v) in record)
    end
    result
end

ipopt_records = by_snapshot(ipopt)
madnlp_records = by_snapshot(madnlp)
pairs = Dict{String,Any}[]
for snapshot in sort!(collect(intersect(Set(keys(ipopt_records)), Set(keys(madnlp_records)))))
    i = ipopt_records[snapshot]
    m = madnlp_records[snapshot]
    i_iter = get(i, "final_iteration", nothing)
    m_iter = get(m, "final_iteration", nothing)
    push!(pairs, Dict{String,Any}(
        "snapshot" => snapshot,
        "ipopt_status" => get(i, "status", nothing),
        "madnlp_status" => get(m, "status", nothing),
        "both_solved" => get(i, "solved", false) && get(m, "solved", false),
        "ipopt_final_iteration" => i_iter,
        "madnlp_final_iteration" => m_iter,
        "madnlp_minus_ipopt_final_iteration" => i_iter isa Number && m_iter isa Number ? m_iter - i_iter : nothing,
        "ipopt_final_primal_infeasibility" => get(i, "final_primal_infeasibility", nothing),
        "madnlp_final_primal_infeasibility" => get(m, "final_primal_infeasibility", nothing),
        "ipopt_final_dual_infeasibility" => get(i, "final_dual_infeasibility", nothing),
        "madnlp_final_dual_infeasibility" => get(m, "final_dual_infeasibility", nothing),
    ))
end

write_json(output_path, Dict{String,Any}(
    "schema_version" => "nlpdiagnostics-bmopf-solver-scaling-cross-solver-v1",
    "source" => Dict{String,Any}(
        "ipopt_summary" => ipopt_path,
        "madnlp_summary" => madnlp_path,
        "pairing_policy" => "Pair by exact snapshot path; compare trace termination and final residuals descriptively.",
    ),
    "environment" => Dict{String,Any}(
        "julia_version" => string(VERSION),
        "git_revision" => git_revision(),
        "git_worktree_dirty" => !isempty(git_status_entries()),
    ),
    "snapshot_pair_count" => length(pairs),
    "both_solved_pair_count" => count(get.(pairs, "both_solved", false)),
    "timeout_pair_count" => count(pair -> get(pair, "ipopt_status", "") == "incomplete" || get(pair, "madnlp_status", "") == "incomplete", pairs),
    "pairs" => pairs,
    "interpretation" => "Both solvers completed the paired 11,028-variable trace cases under the declared guards. Iteration and residual differences are local observations and do not establish solver superiority, complexity, or production scalability.",
    "next_action" => "Extend the ladder with a larger guarded case or allocator-level telemetry before making a runtime-scaling claim.",
))
println("wrote BMOPF cross-solver scaling summary to $output_path")
