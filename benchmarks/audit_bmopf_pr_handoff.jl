#!/usr/bin/env julia

"""Audit whether the active BMOPFTools checkout matches validated clean main."""

using JSON

include(joinpath(@__DIR__, "common.jl"))
using .NLPDiagnosticsBenchmarkCommon

const ROOT = repo_root()
const OUTPUT = abspath(isempty(ARGS) ?
    joinpath(ROOT, "docs", "bmopf_pr_handoff_summary.json") : ARGS[1])
const ACTIVE_CONTRACT_PATH = abspath(get(
    ENV,
    "NLPDIAGNOSTICS_BMOPF_ACTIVE_CONTRACT",
    joinpath(ROOT, "docs", "bmopf_api_contract_summary.json"),
))
const CLEAN_MAIN_CONTRACT_PATH = abspath(get(
    ENV,
    "NLPDIAGNOSTICS_BMOPF_CLEAN_MAIN_CONTRACT",
    joinpath(ROOT, "docs", "bmopf_api_contract_clean_main_summary.json"),
))

function artifact_label(path::AbstractString)
    startswith(path, ROOT * "/") ? relpath(path, ROOT) : path
end

function load_or_missing(path::AbstractString)
    isfile(path) ? JSON.parsefile(path) : Dict{String,Any}(
        "status" => "missing",
        "reason" => "artifact is absent",
    )
end

function contract_field(artifact, field, default)
    get(get(artifact, "contract", Dict{String,Any}()), field, default)
end

function dependency_field(artifact, field, default)
    get(get(artifact, "dependency", Dict{String,Any}()), field, default)
end

active = load_or_missing(ACTIVE_CONTRACT_PATH)
clean_main = load_or_missing(CLEAN_MAIN_CONTRACT_PATH)
active_status = get(active, "status", "missing")
clean_main_status = get(clean_main, "status", "missing")
active_revision = dependency_field(active, "git_revision", nothing)
clean_main_revision = dependency_field(clean_main, "git_revision", nothing)
active_branch = dependency_field(active, "git_branch", nothing)
clean_main_branch = dependency_field(clean_main, "git_branch", nothing)
active_missing = contract_field(active, "missing_symbols", String[])
clean_main_missing = contract_field(clean_main, "missing_symbols", String[])
revision_match = !isnothing(active_revision) && active_revision == clean_main_revision
handoff_passed = active_status == "pass" &&
                 clean_main_status == "pass" &&
                 revision_match &&
                 isempty(active_missing) &&
                 isempty(clean_main_missing)

reason = if handoff_passed
    "the active BMOPFTools checkout matches the validated clean-main contract"
elseif clean_main_status != "pass"
    "the tracked clean-main contract evidence is not passing"
elseif active_status != "pass"
    "the active BMOPFTools checkout does not satisfy the consumed API contract"
elseif !revision_match
    "the active BMOPFTools revision differs from the validated clean-main revision"
else
    "the contract artifacts contain unresolved missing symbols"
end

summary = Dict{String,Any}(
    "schema_version" => "nlpdiagnostics-bmopf-pr-handoff-v1",
    "status" => handoff_passed ? "pass" : "blocked",
    "handoff_passed" => handoff_passed,
    "reason" => reason,
    "active_contract" => Dict{String,Any}(
        "artifact" => artifact_label(ACTIVE_CONTRACT_PATH),
        "status" => active_status,
        "branch" => active_branch,
        "revision" => active_revision,
        "missing_symbols" => active_missing,
    ),
    "validated_clean_main_contract" => Dict{String,Any}(
        "artifact" => artifact_label(CLEAN_MAIN_CONTRACT_PATH),
        "status" => clean_main_status,
        "branch" => clean_main_branch,
        "revision" => clean_main_revision,
        "missing_symbols" => clean_main_missing,
    ),
    "revision_match" => revision_match,
    "qualification" => Dict{String,Any}(
        "claim" => "dependency handoff readiness for a BMOPFTools PR",
        "does_not_establish" => [
            "semantic correctness of every BMOPFTools result",
            "solver convergence or physical KKT acceptance",
            "remote branch publication or pull-request review",
        ],
    ),
)

write_json(OUTPUT, summary)
println("wrote BMOPFTools PR handoff audit to $OUTPUT")
handoff_passed || exit(1)
