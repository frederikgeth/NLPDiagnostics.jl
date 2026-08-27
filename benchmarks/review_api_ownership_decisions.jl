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
const PRIOR_OUTPUT = "docs/api_ownership_decision_summary.json"
const NEXT_BATCH_LABEL = "next_bounded_batch_2026-08-27_tranche_10"
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
    "bmopf_phase_only_transform_plan" => Dict(
        "decision" => "advanced_candidate_review",
        "namespace_target" => "Advanced",
        "rationale" => "Phase-only transformation planning is BMOPFTools campaign orchestration; keep it Advanced until cross-case intervention semantics are stable.",
    ),
    "bmopf_result_field_catalog" => Dict(
        "decision" => "advanced_candidate_review",
        "namespace_target" => "Advanced",
        "rationale" => "BMOPFTools result-field catalogs describe adapter-specific solver output; defer promotion until result schemas and ownership are versioned.",
    ),
    "bmopf_saved_result_profile_case" => Dict(
        "decision" => "advanced_candidate_review",
        "namespace_target" => "Advanced",
        "rationale" => "Saved solver-result profile cases are reproducibility artifacts for BMOPFTools campaigns; retain Advanced ownership while persistence contracts evolve.",
    ),
    "bmopf_scaling_intervention_classification" => Dict(
        "decision" => "advanced_candidate_review",
        "namespace_target" => "Advanced",
        "rationale" => "Scaling intervention classification is a research diagnostic derived from BMOPF experiments; keep it outside the root compatibility surface.",
    ),
    "bmopf_source_behavior_auxiliary_model" => Dict(
        "decision" => "advanced_candidate_review",
        "namespace_target" => "Advanced",
        "rationale" => "Auxiliary source-behavior modeling is extension-specific experiment support; defer namespace migration until its adapter contract is stable.",
    ),
    "bmopf_transport_scaling_point" => Dict(
        "decision" => "advanced_candidate_review",
        "namespace_target" => "Advanced",
        "rationale" => "Transport scaling points are workload-specific inputs used by BMOPFTools campaigns; retain Advanced ownership while point semantics mature.",
    ),
    "port_expected_nullspace_summary" => Dict(
        "decision" => "advanced_candidate_review",
        "namespace_target" => "Advanced",
        "rationale" => "Port-extension nullspace summaries are research-facing structural evidence; keep them Advanced pending a stable port contract.",
    ),
    "bmopf_analyze_active_set" => Dict(
        "decision" => "advanced_candidate_review",
        "namespace_target" => "Advanced",
        "rationale" => "BMOPFTools active-set analysis is adapter-specific solver diagnostics; defer any root promotion until its result ownership is explicit.",
    ),
    "bmopf_analyze_component_rank_persistence" => Dict(
        "decision" => "advanced_candidate_review",
        "namespace_target" => "Advanced",
        "rationale" => "Component-rank persistence analysis belongs to the BMOPFTools research surface; retain Advanced ownership while capability semantics evolve.",
    ),
    "bmopf_analyze_jacobian_rank_persistence" => Dict(
        "decision" => "advanced_candidate_review",
        "namespace_target" => "Advanced",
        "rationale" => "Jacobian-rank persistence analysis is an adapter-level diagnostic and should remain Advanced until backend and schema contracts settle.",
    ),
    "bmopf_analyze_jacobian_row_family_perturbations" => Dict(
        "decision" => "advanced_candidate_review",
        "namespace_target" => "Advanced",
        "rationale" => "Row-family perturbation analysis is experiment-specific BMOPFTools evidence; keep it Advanced pending a stable perturbation interface.",
    ),
    "bmopf_analyze_opf" => Dict(
        "decision" => "advanced_candidate_review",
        "namespace_target" => "Advanced",
        "rationale" => "BMOPFTools OPF analysis orchestration is integration-facing rather than a core evaluator primitive; retain Advanced ownership pending facade review.",
    ),
    "bmopf_analyze_sparse_qr_nullspace_persistence" => Dict(
        "decision" => "advanced_candidate_review",
        "namespace_target" => "Advanced",
        "rationale" => "Sparse-QR nullspace persistence is backend- and adapter-specific evidence; keep it Advanced until capability and unavailable-reason contracts stabilize.",
    ),
    "bmopf_component_rank_capability_report" => Dict(
        "decision" => "advanced_candidate_review",
        "namespace_target" => "Advanced",
        "rationale" => "Component-rank capability reports describe BMOPFTools backend coverage; defer promotion while capability boundaries remain under review.",
    ),
    "bmopf_current_law_fingerprints" => Dict(
        "decision" => "advanced_candidate_review",
        "namespace_target" => "Advanced",
        "rationale" => "Current-law fingerprints are BMOPFTools domain evidence records; retain Advanced ownership until their cross-case schema is versioned.",
    ),
    "bmopf_current_law_operating_point_persistence" => Dict(
        "decision" => "advanced_candidate_review",
        "namespace_target" => "Advanced",
        "rationale" => "Operating-point current-law persistence is an extension-specific reproducibility artifact; keep it Advanced pending stable persistence semantics.",
    ),
    "bmopf_current_law_operating_point_probes" => Dict(
        "decision" => "advanced_candidate_review",
        "namespace_target" => "Advanced",
        "rationale" => "Current-law operating-point probes are BMOPFTools experiment inputs; retain Advanced ownership while probe semantics and persistence evolve.",
    ),
    "bmopf_current_law_operating_point_report" => Dict(
        "decision" => "advanced_candidate_review",
        "namespace_target" => "Advanced",
        "rationale" => "Operating-point current-law reports are adapter-specific evidence artifacts; defer promotion until report schemas are versioned.",
    ),
    "bmopf_current_law_operating_point_trace" => Dict(
        "decision" => "advanced_candidate_review",
        "namespace_target" => "Advanced",
        "rationale" => "Current-law operating-point traces belong to the BMOPFTools research surface; keep them Advanced pending stable trace ownership.",
    ),
    "bmopf_current_law_report" => Dict(
        "decision" => "advanced_candidate_review",
        "namespace_target" => "Advanced",
        "rationale" => "Current-law reports are domain-specific BMOPFTools outputs rather than core evaluator contracts; retain Advanced ownership while schemas mature.",
    ),
    "bmopf_expected_mode_tangent_policy" => Dict(
        "decision" => "advanced_candidate_review",
        "namespace_target" => "Advanced",
        "rationale" => "Expected-mode tangent policy is an experiment-specific structural-analysis policy; keep it Advanced until backend semantics stabilize.",
    ),
    "bmopf_initialization_scaling_covariance_report" => Dict(
        "decision" => "advanced_candidate_review",
        "namespace_target" => "Advanced",
        "rationale" => "Initialization scaling covariance is BMOPFTools campaign evidence; defer any root migration until its cross-case report contract is stable.",
    ),
    "bmopf_iteration_trace_jacobian_family_geometry_data" => Dict(
        "decision" => "advanced_candidate_review",
        "namespace_target" => "Advanced",
        "rationale" => "Iteration-trace Jacobian-family geometry data is adapter-specific research output; retain Advanced ownership pending a stable schema.",
    ),
    "bmopf_passive_network_current_map_report" => Dict(
        "decision" => "advanced_candidate_review",
        "namespace_target" => "Advanced",
        "rationale" => "Passive-network current-map reports depend on BMOPFTools network semantics; keep them Advanced while adapter ownership is finalized.",
    ),
    "bmopf_passive_network_current_maps" => Dict(
        "decision" => "advanced_candidate_review",
        "namespace_target" => "Advanced",
        "rationale" => "Passive-network current maps are BMOPFTools domain artifacts and not core evaluator primitives; defer promotion until their contract is versioned.",
    ),
    "bmopf_phase_only_endpoint" => Dict(
        "decision" => "advanced_candidate_review",
        "namespace_target" => "Advanced",
        "rationale" => "Phase-only endpoints are campaign-specific solver records; retain Advanced ownership while intervention and endpoint schemas evolve.",
    ),
    "bmopf_phase_only_model_rebuild_report" => Dict(
        "decision" => "advanced_candidate_review",
        "namespace_target" => "Advanced",
        "rationale" => "Phase-only model-rebuild reports are adapter-specific provenance artifacts; keep them Advanced pending stable rebuild semantics.",
    ),
    "bmopf_phase_only_rebuild_model" => Dict(
        "decision" => "advanced_candidate_review",
        "namespace_target" => "Advanced",
        "rationale" => "Phase-only model rebuilding is BMOPFTools campaign orchestration rather than a core API; defer namespace migration until its facade is explicit.",
    ),
    "bmopf_phase_only_solve_model" => Dict(
        "decision" => "advanced_candidate_review",
        "namespace_target" => "Advanced",
        "rationale" => "Phase-only solve orchestration is extension-specific and solver-facing; retain Advanced ownership while solve-result contracts mature.",
    ),
    "bmopf_physical_feasibility_report" => Dict(
        "decision" => "advanced_candidate_review",
        "namespace_target" => "Advanced",
        "rationale" => "Physical-feasibility reports are BMOPFTools domain evidence; keep them Advanced until endpoint semantics and schemas are stable.",
    ),
    "bmopf_profile_case" => Dict(
        "decision" => "advanced_candidate_review",
        "namespace_target" => "Advanced",
        "rationale" => "BMOPFTools profile cases are workload-specific reproducibility records; defer promotion pending stable persistence and ownership contracts.",
    ),
    "bmopf_result_mapping_report" => Dict(
        "decision" => "advanced_candidate_review",
        "namespace_target" => "Advanced",
        "rationale" => "Result-mapping reports are adapter-owned integration artifacts; retain Advanced ownership while solver-result mappings evolve.",
    ),
)

queue = read_summary(INPUT)["queue"]
prior_rows = if isfile(joinpath(ROOT, PRIOR_OUTPUT))
    prior = read_summary(PRIOR_OUTPUT)
    get(prior, "rows", Any[])
else
    Any[]
end
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

# Preserve the prior reviewed ledger so each invocation advances the queue
# instead of re-selecting the same bounded tranche.
reviewed_names = Set(row["name"] for row in rows)
for prior in prior_rows
    name = get(prior, "name", "")
    isempty(name) || name in reviewed_names || (push!(rows, prior); push!(reviewed_names, name))
end
sort!(rows; by = row -> row["name"])

# Continue the review in a deterministic, bounded tranche.  The proposal is a
# disposition review only: no export is promoted, moved, deprecated, or
# removed.  Priority follows observed repository usage, then reference count,
# so the next tranche is reproducible as the queue evolves.
baseline_reviewed_names = Set(row["name"] for row in rows)
priority_order = Dict(
    "test_and_benchmark_usage" => 1,
    "test_usage" => 2,
    "benchmark_usage" => 3,
    "source_only" => 4,
)
remaining = filter(row -> !(row["name"] in reviewed_names), queue)
sort!(remaining; by = row -> (
    get(priority_order, row["usage_priority"], typemax(Int)),
    -Int(get(row, "code_file_count", 0)),
    row["name"],
))
next_batch = first(remaining, min(24, length(remaining)))
for source in next_batch
    name = source["name"]
    advanced = source["proposed_disposition"] == "advanced_candidate"
    decision = advanced ? Dict{String,Any}(
        "decision" => "advanced_candidate_review",
        "namespace_target" => "Advanced",
        "rationale" => "Bounded next-tranche review identifies this extension as a research-facing candidate; retain compatibility until ownership, schema, and type-identity contracts are explicitly approved.",
    ) : Dict{String,Any}(
        "decision" => "retain_root_compatibility",
        "namespace_target" => "root",
        "rationale" => "Bounded next-tranche review retains this legacy export at root until an explicit compatibility and migration plan is approved.",
    )
    push!(rows, merge(
        Dict{String,Any}(
            "name" => name,
            "usage_priority" => source["usage_priority"],
            "code_file_count" => source["code_file_count"],
            "has_runtime_usage_evidence" => source["has_runtime_usage_evidence"],
            "proposed_disposition" => source["proposed_disposition"],
            "migration_allowed" => false,
            "review_status" => "reviewed_local_next_batch",
            "review_batch" => NEXT_BATCH_LABEL,
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
        "prior_output" => PRIOR_OUTPUT,
        "selection_policy" => "Previously reviewed high-impact names plus prior ledger rows and the next 24 unreviewed queue entries ordered by usage priority, reference count, and name; this bounded review does not represent the full queue.",
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
    "batch_summary" => Dict{String,Any}(
        "prior_reviewed_count" => length(baseline_reviewed_names),
        "next_batch_count" => length(next_batch),
        "next_batch_reviewed_count" => count(row -> get(row, "review_batch", "") == NEXT_BATCH_LABEL, rows),
        "next_batch_advanced_candidate_count" => count(row -> get(row, "review_batch", "") == NEXT_BATCH_LABEL && row["decision"] == "advanced_candidate_review", rows),
        "next_batch_root_compatibility_count" => count(row -> get(row, "review_batch", "") == NEXT_BATCH_LABEL && row["decision"] == "retain_root_compatibility", rows),
    ),
    "rows" => rows,
    "next_actions" => [
        "Review the remaining root-only queue in similarly bounded batches.",
        "Approve any namespace move only with an explicit compatibility and type-identity plan.",
        "Keep Stable and Advanced facades unchanged until ownership review is complete.",
    ],
    "interpretation" => Dict{String,Any}(
        "claim" => "$(length(rows)) root-only names now have explicit local ownership decisions; all remain non-migrating compatibility decisions except $(count(row -> row["decision"] == "advanced_candidate_review", rows)) Advanced candidate reviews.",
        "does_not_establish" => [
            "a complete review of all root-only exports",
            "permission to remove or deprecate root symbols",
            "Stable or Advanced namespace compatibility for future releases",
        ],
    ),
))

println("wrote API ownership decision summary to $OUTPUT")
