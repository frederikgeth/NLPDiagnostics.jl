#!/usr/bin/env julia

"""Record whether a reviewed third numerical-rank backend is available.

Package presence alone is not treated as a backend: a candidate must have a
reviewed adapter, declared numerical semantics, and a reproducible calibration
campaign.  This validator keeps that distinction explicit in the known local
environment.
"""

include(joinpath(@__DIR__, "common.jl"))
using .NLPDiagnosticsBenchmarkCommon

const ROOT = repo_root()
const OUTPUT = abspath(isempty(ARGS) ?
    joinpath(ROOT, "docs", "rank_third_backend_capability_summary.json") : ARGS[1])
const CAMPAIGN_ARTIFACT = "docs/normal_eigen_rank_calibration_summary.json"

const CANDIDATE_PACKAGES = [
    "Arpack",
    "ArnoldiMethod",
    "IterativeSolvers",
    "Krylov",
    "TSVD",
]

function probe_package(name)
    path = try
        Base.find_package(name)
    catch error
        nothing
    end
    Dict{String,Any}(
        "package" => name,
        "available_in_active_project" => path !== nothing,
        "resolved_path" => path,
        "adapter_registered" => false,
    )
end

probes = [probe_package(name) for name in CANDIDATE_PACKAGES]
registered = get(ENV, "NLPDIAGNOSTICS_RANK_THIRD_BACKEND", "")
campaign = try
    read_summary(CAMPAIGN_ARTIFACT)
catch
    Dict{String,Any}()
end
campaign_valid = get(campaign, "schema_version", "") ==
    "nlpdiagnostics-normal-eigen-rank-calibration-v1" &&
    get(campaign, "backend", "") == "normal_eigen" &&
    get(campaign, "hard_controls_complete", false) == true
adapter_registered = campaign_valid && (isempty(registered) || registered == "normal_eigen")
status = adapter_registered ? "available_for_calibration" : "unavailable"
adapter_status = adapter_registered ? "registered_internal_normal_eigen" : "not_registered"
reason = adapter_registered ?
    "The reviewed internal normal-eigen adapter is available for bounded cross-backend calibration; its squared-spectrum limitation remains explicit." :
    (isempty(registered) ?
        "No reviewed third-backend adapter is registered in the known environment." :
        "Requested third backend '$registered' has no reviewed adapter in this checkout.")
status_entries = git_status_entries()

write_json(OUTPUT, Dict{String,Any}(
    "schema_version" => "nlpdiagnostics-rank-third-backend-capability-v1",
    "source" => Dict{String,Any}(
        "runner" => "benchmarks/validate_rank_third_backend.jl",
        "candidate_packages" => CANDIDATE_PACKAGES,
        "registration_environment_variable" => "NLPDIAGNOSTICS_RANK_THIRD_BACKEND",
        "campaign_artifact" => CAMPAIGN_ARTIFACT,
        "policy" => "A package is not promoted to a numerical backend without a reviewed adapter, semantics, and reproducible calibration campaign.",
    ),
    "environment" => Dict{String,Any}(
        "julia_version" => string(VERSION),
        "active_project" => Base.active_project(),
        "git_revision" => git_revision(),
        "git_worktree_dirty" => !isempty(status_entries),
    ),
    "status" => status,
    "adapter_status" => adapter_status,
    "registered_backend" => adapter_registered ? "normal_eigen" : (isempty(registered) ? nothing : registered),
    "vetted_backend_count" => adapter_registered ? 1 : 0,
    "reason" => reason,
    "campaign_artifact" => CAMPAIGN_ARTIFACT,
    "campaign_valid" => campaign_valid,
    "candidate_packages" => probes,
    "closure_requirements" => [
        "Retain the reviewed third backend adapter with explicit rank-policy semantics.",
        "Expand the reproducible cross-backend calibration campaign across hard, threshold-sensitive, randomized, clustered-spectrum, and sparse controls.",
        "Record disagreements and unavailable results without converting them to pass/fail claims.",
    ],
    "interpretation" => Dict{String,Any}(
        "claim" => adapter_registered ? "The known environment has an explicit reviewed internal normal-eigen adapter and bounded calibration evidence." : "The known environment has an explicit capability result for the third rank backend; no third-backend evidence is currently available.",
        "does_not_establish" => [
            "that candidate packages are unsuitable in every environment",
            "a universal rank error bound",
            "release readiness",
        ],
    ),
))

println("wrote rank third-backend capability summary to $OUTPUT")
