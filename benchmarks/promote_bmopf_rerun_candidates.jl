#!/usr/bin/env julia

"""Promote validated SI candidates with an explicit, backup-first action.

This script is intentionally opt-in. It validates every candidate again,
backs up the existing canonical file, copies the candidate into the corpus,
and writes a promotion manifest under the backup root.

Usage:

    julia benchmarks/promote_bmopf_rerun_candidates.jl \
        quality-summary.json candidate-root corpus-root backup-root --confirm
"""

using JSON
using SHA

Base.include(@__MODULE__, joinpath(@__DIR__, "common.jl"))
using .NLPDiagnosticsBenchmarkCommon: git_revision, write_json

length(ARGS) == 5 && ARGS[end] == "--confirm" || error(
    "usage: promote_bmopf_rerun_candidates.jl quality-summary.json candidate-root corpus-root backup-root --confirm",
)
quality_path = abspath(ARGS[1])
candidate_root = abspath(ARGS[2])
corpus_root = abspath(ARGS[3])
backup_root = abspath(ARGS[4])
isfile(quality_path) || error("quality summary is missing: $quality_path")
isdir(candidate_root) || error("candidate root is missing: $candidate_root")
isdir(corpus_root) || error("corpus root is missing: $corpus_root")
quality = JSON.parsefile(quality_path)
boundary = get(get(quality, "release_boundary", Dict()), "excluded_records", Any[])
boundary isa AbstractVector || error("quality release boundary is not an array")
isempty(boundary) && error("quality summary has no excluded endpoints to promote")

function _candidate_path(root, snapshot, units)
    replace(joinpath(root, String(snapshot)), ".bmopf.json" => "_result_$(units).json")
end

function _validate(path)
    isfile(path) || error("candidate result is missing: $path")
    value = JSON.parsefile(path; allownan = true)
    value isa AbstractDict || error("candidate result is not an object: $path")
    nonfinite = Ref(0)
    function walk(item)
        item isa Bool && return
        if item isa Number
            item isa AbstractFloat && !isfinite(item) && (nonfinite[] += 1)
        elseif item isa AbstractDict
            foreach(walk, values(item))
        elseif item isa AbstractVector
            foreach(walk, item)
        end
    end
    walk(value)
    get(value, "termination_status", nothing) == "LOCALLY_SOLVED" ||
        error("candidate is not LOCALLY_SOLVED: $path")
    get(value, "feasible", nothing) === true || error("candidate is not feasible: $path")
    nonfinite[] == 0 || error("candidate contains non-finite values: $path")
    return value
end

mkpath(backup_root)
records = Dict{String,Any}[]
for entry in boundary
    entry isa AbstractDict || continue
    snapshot = String(get(entry, "snapshot", ""))
    units = String(get(entry, "result_units", "si"))
    relative = replace(snapshot, ".bmopf.json" => "_result_$(units).json")
    candidate_path = _candidate_path(candidate_root, snapshot, units)
    target_path = joinpath(corpus_root, relative)
    backup_path = joinpath(backup_root, relative)
    candidate = _validate(candidate_path)
    isfile(target_path) || error("canonical result is missing: $target_path")
    mkpath(dirname(backup_path))
    cp(target_path, backup_path; force = true)
    before_hash = bytes2hex(SHA.sha256(read(target_path)))
    cp(candidate_path, target_path; force = true)
    after_hash = bytes2hex(SHA.sha256(read(target_path)))
    push!(records, Dict{String,Any}(
        "snapshot" => snapshot,
        "result_units" => units,
        "candidate_path" => candidate_path,
        "target_path" => target_path,
        "backup_path" => backup_path,
        "canonical_sha256_before" => before_hash,
        "candidate_sha256" => bytes2hex(SHA.sha256(read(candidate_path))),
        "canonical_sha256_after" => after_hash,
        "termination_status" => get(candidate, "termination_status", nothing),
        "feasible" => get(candidate, "feasible", nothing),
    ))
end

manifest_path = joinpath(backup_root, "promotion_manifest.json")
write_json(manifest_path, Dict{String,Any}(
    "schema_version" => "nlpdiagnostics-bmopf-rerun-promotion-v1",
    "quality_summary" => quality_path,
    "candidate_root" => candidate_root,
    "corpus_root" => corpus_root,
    "backup_root" => backup_root,
    "git_revision" => git_revision(),
    "candidate_count" => length(records),
    "records" => records,
    "interpretation" => "Promotion was explicitly confirmed; original canonical files are recoverable from backup_root. Re-run the saved-result quality and sparse-rank audits before making physical endpoint claims.",
))
println("promoted $(length(records)) BMOPF rerun candidates; manifest=$manifest_path")
