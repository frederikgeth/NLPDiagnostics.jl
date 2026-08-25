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
status = "unavailable"
reason = isempty(registered) ?
    "No reviewed third-backend adapter is registered in the known environment." :
    "Requested third backend '$registered' has no reviewed adapter in this checkout."
status_entries = git_status_entries()

write_json(OUTPUT, Dict{String,Any}(
    "schema_version" => "nlpdiagnostics-rank-third-backend-capability-v1",
    "source" => Dict{String,Any}(
        "runner" => "benchmarks/validate_rank_third_backend.jl",
        "candidate_packages" => CANDIDATE_PACKAGES,
        "registration_environment_variable" => "NLPDIAGNOSTICS_RANK_THIRD_BACKEND",
        "policy" => "A package is not promoted to a numerical backend without a reviewed adapter, semantics, and reproducible calibration campaign.",
    ),
    "environment" => Dict{String,Any}(
        "julia_version" => string(VERSION),
        "active_project" => Base.active_project(),
        "git_revision" => git_revision(),
        "git_worktree_dirty" => !isempty(status_entries),
    ),
    "status" => status,
    "adapter_status" => "not_registered",
    "registered_backend" => isempty(registered) ? nothing : registered,
    "vetted_backend_count" => 0,
    "reason" => reason,
    "candidate_packages" => probes,
    "closure_requirements" => [
        "Register a third backend adapter with explicit rank-policy semantics.",
        "Run a reproducible cross-backend calibration campaign including hard and threshold-sensitive controls.",
        "Record disagreements and unavailable results without converting them to pass/fail claims.",
    ],
    "interpretation" => Dict{String,Any}(
        "claim" => "The known environment has an explicit capability result for the third rank backend; no third-backend evidence is currently available.",
        "does_not_establish" => [
            "that candidate packages are unsuitable in every environment",
            "a universal rank error bound",
            "release readiness",
        ],
    ),
))

println("wrote rank third-backend capability summary to $OUTPUT")
