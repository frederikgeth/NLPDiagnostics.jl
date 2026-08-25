#!/usr/bin/env julia

"""Record a bounded manual review of high-impact root-only API names.

The ledger is intentionally decision-only: it does not edit exports, move
symbols, or deprecate compatibility paths. The selected names are the most
referenced runtime/test/benchmark surface plus a bounded batch of BMOPF
extension candidates.
"""

include(joinpath(@__DIR__, "common.jl"))
using .NLPDiagnosticsBenchmarkCommon

const ROOT = repo_root()
const INPUT = "docs/api_tier_usage_summary.json"
const OUTPUT = abspath(isempty(ARGS) ?
    joinpath(ROOT, "docs", "api_ownership_decision_summary.json") : ARGS[1])

const REVIEW_DECISIONS = Dict{String,Dict{String,Any}}(
    "snapshot" => Dict(
        "decision" => "retain_root_compatibility",
        "namespace_target" => "root",
        "rationale" => "Core model-boundary constructor with broad test and benchmark usage; retain until a versioned compatibility plan exists.",
    ),
    "evaluate_numerical" => Dict(
        "decision" => "retain_root_compatibility",
        "namespace_target" => "root",
        "rationale" => "Core numerical evaluation entry point used across tests and adapters; moving it would create a broad compatibility break.",
    ),
    "findings" => Dict(
        "decision" => "retain_root_compatibility",
        "namespace_target" => "root",
        "rationale" => "Report inspection helper used throughout regression assertions; retain as a compatibility surface.",
    ),
    "EvaluationPoint" => Dict(
        "decision" => "retain_root_compatibility",
        "namespace_target" => "root",
        "rationale" => "Public point type appears in model, numerical, and test contracts; no safe namespace-only migration is established.",
    ),
    "EntityRef" => Dict(
        "decision" => "retain_root_compatibility",
        "namespace_target" => "root",
        "rationale" => "Shared report identity type used by multiple subsystems; preserve root identity while the API is pre-1.0.",
    ),
    "solver_result_point" => Dict(
        "decision" => "retain_root_compatibility",
        "namespace_target" => "root",
        "rationale" => "Solver-result provenance boundary is consumed by adapters and tests; retain until solver extension ownership is reviewed.",
    ),
    "Finding" => Dict(
        "decision" => "retain_root_compatibility",
        "namespace_target" => "root",
        "rationale" => "Primary diagnostic record type with broad downstream construction and inspection; compatibility takes precedence over tier cleanup.",
    ),
    "NumericalEvaluation" => Dict(
        "decision" => "retain_root_compatibility",
        "namespace_target" => "root",
        "rationale" => "Central evaluator contract used by rank, activity, and adapter paths; no migration without a coordinated type-identity plan.",
    ),
    "DiagnosticReport" => Dict(
        "decision" => "retain_root_compatibility",
        "namespace_target" => "root",
        "rationale" => "Top-level report container used by all analysis entry points; root identity is part of the current compatibility contract.",
    ),
    "evaluation_point_fingerprint" => Dict(
        "decision" => "retain_root_compatibility",
        "namespace_target" => "root",
        "rationale" => "Provenance helper is used by reproducibility and cross-check ledgers; retain while artifact schemas remain v1-compatible.",
    ),
    "Evidence" => Dict(
        "decision" => "retain_root_compatibility",
        "namespace_target" => "root",
        "rationale" => "Evidence record is shared by renderer-neutral reports and tests; do not split ownership without a report-schema review.",
    ),
    "bmopf_start_completion_point" => Dict(
        "decision" => "advanced_candidate_review",
        "namespace_target" => "Advanced",
        "rationale" => "BMOPFTools-specific lifecycle helper is a plausible Advanced candidate, but adapter ownership and compatibility still require explicit review.",
    ),
    "JacobianEntry" => Dict(
        "decision" => "retain_root_compatibility",
        "namespace_target" => "root",
        "rationale" => "Sparse derivative entry type is constructed directly by numerical and adapter paths; retain root identity for evaluator compatibility.",
    ),
    "EvaluationPointProvenance" => Dict(
        "decision" => "retain_root_compatibility",
        "namespace_target" => "root",
        "rationale" => "Point provenance participates in reproducibility contracts and report schemas; no namespace-only move is safe yet.",
    ),
    "finding_code_counts" => Dict(
        "decision" => "retain_root_compatibility",
        "namespace_target" => "root",
        "rationale" => "Diagnostic aggregation helper is used by benchmark and regression ledgers; preserve its current root entry point.",
    ),
    "EvaluationCache" => Dict(
        "decision" => "retain_root_compatibility",
        "namespace_target" => "root",
        "rationale" => "Evaluator cache type is coupled to numerical evaluation lifecycle; defer migration until cache ownership is documented.",
    ),
    "EvaluationFailure" => Dict(
        "decision" => "retain_root_compatibility",
        "namespace_target" => "root",
        "rationale" => "Failure record crosses evaluator and report boundaries; retain root compatibility while schemas remain pre-1.0.",
    ),
    "bmopf_constraint_semantic_row_map" => Dict(
        "decision" => "advanced_candidate_review",
        "namespace_target" => "Advanced",
        "rationale" => "BMOPFTools registry adapter is research-facing and a plausible Advanced candidate, but ownership and adapter stability are not yet finalized.",
    ),
    "bmopf_diagonal_scaling_map" => Dict(
        "decision" => "advanced_candidate_review",
        "namespace_target" => "Advanced",
        "rationale" => "BMOPFTools scaling adapter belongs in the research namespace pending a stable semantic contract and compatibility review.",
    ),
    "ipopt_profile_with_iteration_trace!" => Dict(
        "decision" => "retain_root_compatibility",
        "namespace_target" => "root",
        "rationale" => "Solver instrumentation entry point is consumed by trace campaigns; defer tier migration until solver-extension ownership is reviewed.",
    ),
    "report_data" => Dict(
        "decision" => "retain_root_compatibility",
        "namespace_target" => "root",
        "rationale" => "Renderer-neutral serialization boundary is used by all report families; preserve root compatibility while schemas evolve.",
    ),
    "SemanticBlockScalingMap" => Dict(
        "decision" => "retain_root_compatibility",
        "namespace_target" => "root",
        "rationale" => "Generic scaling-map type is shared by core and adapter reports; retain root identity until the type-tier plan is explicit.",
    ),
    "bmopf_physical_solver_kkt_report" => Dict(
        "decision" => "advanced_candidate_review",
        "namespace_target" => "Advanced",
        "rationale" => "BMOPFTools physical-KKT adapter is research-facing and should remain an Advanced candidate until endpoint semantics are stabilized.",
    ),
    "incidence_graph" => Dict(
        "decision" => "retain_root_compatibility",
        "namespace_target" => "root",
        "rationale" => "Structural graph helper is used by analysis and tests; preserve root access while graph API ownership remains broad.",
    ),
    "bmopf_jacobian_row_family_scale_attribution" => Dict(
        "decision" => "advanced_candidate_review",
        "namespace_target" => "Advanced",
        "rationale" => "BMOPFTools row-family attribution is an experiment-facing diagnostic; keep it as an Advanced candidate until scaling semantics are versioned.",
    ),
    "bmopf_initialization_point" => Dict(
        "decision" => "advanced_candidate_review",
        "namespace_target" => "Advanced",
        "rationale" => "BMOPFTools initialization record is solver-workload specific; defer any namespace move until adapter ownership and serialization are stable.",
    ),
    "bmopf_jacobian_row_family_scaling_experiment" => Dict(
        "decision" => "advanced_candidate_review",
        "namespace_target" => "Advanced",
        "rationale" => "Scaling experiment orchestration belongs to the research-facing extension surface; retain compatibility while the experiment contract matures.",
    ),
    "bmopf_variable_semantic_column_map" => Dict(
        "decision" => "advanced_candidate_review",
        "namespace_target" => "Advanced",
        "rationale" => "BMOPFTools variable-semantic mapping is adapter-owned and not a core evaluator primitive; review it under the Advanced namespace boundary.",
    ),
    "bmopf_controller_curve_operating_point_observations" => Dict(
        "decision" => "advanced_candidate_review",
        "namespace_target" => "Advanced",
        "rationale" => "Controller-curve observations are workload-specific evidence records; keep them Advanced until their schema is stable across solver cases.",
    ),
    "bmopf_block_scaling_covariance_report" => Dict(
        "decision" => "advanced_candidate_review",
        "namespace_target" => "Advanced",
        "rationale" => "Block-scaling covariance is a research diagnostic derived from BMOPFTools experiments; do not promote it to the root compatibility surface.",
    ),
    "bmopf_constraint_feasibility_field_attribution" => Dict(
        "decision" => "advanced_candidate_review",
        "namespace_target" => "Advanced",
        "rationale" => "Constraint-feasibility attribution depends on BMOPF semantic fields; retain it as an Advanced candidate pending a stable adapter contract.",
    ),
    "bmopf_acdc_scaling_contract_data" => Dict(
        "decision" => "advanced_candidate_review",
        "namespace_target" => "Advanced",
        "rationale" => "AC/DC scaling contract data is extension-specific and experimental; keep ownership in Advanced until cross-case compatibility is demonstrated.",
    ),
    "bmopf_block_scaling_coordinate_geometry_report" => Dict(
        "decision" => "advanced_candidate_review",
        "namespace_target" => "Advanced",
        "rationale" => "Coordinate-geometry scaling reports are BMOPFTools research artifacts; defer namespace migration until report schemas and consumers settle.",
    ),
    "bmopf_build_and_profile" => Dict(
        "decision" => "advanced_candidate_review",
        "namespace_target" => "Advanced",
        "rationale" => "BMOPFTools build/profile orchestration is an integration workflow rather than a core evaluator API; keep it Advanced pending a stable facade.",
    ),
    "bmopf_constraint_registry_coverage_report" => Dict(
        "decision" => "advanced_candidate_review",
        "namespace_target" => "Advanced",
        "rationale" => "Constraint-registry coverage is adapter-specific evidence and should remain Advanced until registry ownership is finalized.",
    ),
    "bmopf_coordinate_probe_point" => Dict(
        "decision" => "advanced_candidate_review",
        "namespace_target" => "Advanced",
        "rationale" => "Coordinate probe points are experiment inputs tied to BMOPFTools scaling campaigns; retain Advanced ownership while the probe schema evolves.",
    ),
)

queue = read_summary(INPUT)["queue"]
rows = Dict{String,Any}[]
for (name, decision) in REVIEW_DECISIONS
    matches = filter(row -> get(row, "name", "") == name, queue)
    length(matches) == 1 || error("expected one queue row for reviewed name $name")
    source = only(matches)
    push!(rows, merge(
        Dict{String,Any}(
            "name" => name,
            "usage_priority" => source["usage_priority"],
            "code_file_count" => source["code_file_count"],
            "has_runtime_usage_evidence" => source["has_runtime_usage_evidence"],
            "proposed_disposition" => source["proposed_disposition"],
            "migration_allowed" => false,
            "review_status" => "reviewed_local",
        ),
        decision,
    ))
end
sort!(rows; by = row -> row["name"])
status_entries = git_status_entries()
write_json(OUTPUT, Dict{String,Any}(
    "schema_version" => "nlpdiagnostics-api-ownership-decisions-v1",
    "source" => Dict{String,Any}(
        "runner" => "benchmarks/review_api_ownership_decisions.jl",
        "input" => INPUT,
        "selection_policy" => "Highest repository-usage root-only names plus one BMOPF Advanced candidate; this bounded review does not represent the full queue.",
        "migration_policy" => "No export is moved, deprecated, or removed by this ledger.",
    ),
    "environment" => Dict{String,Any}(
        "julia_version" => string(VERSION),
        "active_project" => Base.active_project(),
        "git_revision" => git_revision(),
        "git_worktree_dirty" => !isempty(status_entries),
    ),
    "reviewed_count" => length(rows),
    "root_compatibility_retained_count" => count(row -> row["decision"] == "retain_root_compatibility", rows),
    "advanced_candidate_count" => count(row -> row["decision"] == "advanced_candidate_review", rows),
    "migration_allowed_count" => count(row -> row["migration_allowed"], rows),
    "rows" => rows,
    "next_actions" => [
        "Review the remaining root-only queue in similarly bounded batches.",
        "Approve any namespace move only with an explicit compatibility and type-identity plan.",
        "Keep Stable and Advanced facades unchanged until ownership review is complete.",
    ],
    "interpretation" => Dict{String,Any}(
        "claim" => "Thirty-six high-impact root-only names now have explicit local ownership decisions; all remain non-migrating compatibility decisions except sixteen Advanced candidate reviews.",
        "does_not_establish" => [
            "a complete review of all root-only exports",
            "permission to remove or deprecate root symbols",
            "Stable or Advanced namespace compatibility for future releases",
        ],
    ),
))

println("wrote API ownership decision summary to $OUTPUT")
