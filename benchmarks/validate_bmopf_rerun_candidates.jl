#!/usr/bin/env julia

"""Validate canonical-shaped SI result candidates before corpus promotion.

The candidate root is intentionally separate from BMOPFDraftData.  This
validator compares each excluded canonical endpoint with its candidate result,
checking solver status, feasibility, and numeric finiteness without writing to
the source corpus.

Usage:

    julia benchmarks/validate_bmopf_rerun_candidates.jl \
        quality-summary.json candidate-root output.json
"""

using JSON
using SHA

Base.include(@__MODULE__, joinpath(@__DIR__, "common.jl"))
using .NLPDiagnosticsBenchmarkCommon: git_revision, git_status_entries, write_json

length(ARGS) == 3 || error(
    "usage: validate_bmopf_rerun_candidates.jl quality-summary.json candidate-root output.json",
)
quality_path = abspath(ARGS[1])
candidate_root = abspath(ARGS[2])
output_path = abspath(ARGS[3])
isfile(quality_path) || error("quality summary is missing: $quality_path")
isdir(candidate_root) || error("candidate root is missing: $candidate_root")
quality = JSON.parsefile(quality_path)
quality isa AbstractDict || error("quality summary is not an object: $quality_path")
boundary = get(get(quality, "release_boundary", Dict()), "excluded_records", Any[])
boundary isa AbstractVector || error("quality release boundary is not an array")

function _walk_numbers(value, counts)
    if value isa Bool
        return
    elseif value isa Number
        if value isa AbstractFloat && !isfinite(value)
            counts["nonfinite_numeric_count"] += 1
        else
            counts["finite_numeric_count"] += 1
        end
    elseif value isa AbstractDict
        for item in values(value)
            _walk_numbers(item, counts)
        end
    elseif value isa AbstractVector
        for item in value
            _walk_numbers(item, counts)
        end
    end
end

function _candidate_path(snapshot, result_units)
    replace(joinpath(candidate_root, String(snapshot)), ".bmopf.json" => "_result_$(result_units).json")
end

records = Dict{String,Any}[]
for original in boundary
    original isa AbstractDict || continue
    snapshot = String(get(original, "snapshot", ""))
    units = String(get(original, "result_units", "si"))
    candidate_path = _candidate_path(snapshot, units)
    candidate = Dict{String,Any}(
        "available" => isfile(candidate_path),
        "path" => candidate_path,
        "termination_status" => nothing,
        "feasible" => nothing,
        "finite_numeric_count" => 0,
        "nonfinite_numeric_count" => 0,
        "candidate_quality" => "missing",
    )
    if isfile(candidate_path)
        parsed = JSON.parsefile(candidate_path; allownan = true)
        parsed isa AbstractDict || error("candidate result is not an object: $candidate_path")
        candidate["termination_status"] = get(parsed, "termination_status", nothing)
        candidate["feasible"] = get(parsed, "feasible", nothing)
        counts = Dict("finite_numeric_count" => 0, "nonfinite_numeric_count" => 0)
        _walk_numbers(parsed, counts)
        merge!(candidate, counts)
        candidate["sha256"] = bytes2hex(SHA.sha256(read(candidate_path)))
        candidate["candidate_quality"] =
            get(candidate, "termination_status", nothing) == "LOCALLY_SOLVED" &&
            get(candidate, "feasible", nothing) === true &&
            get(candidate, "nonfinite_numeric_count", 0) == 0 ?
            "usable_solver_endpoint" : "nonfinite_or_unsolved"
    end
    push!(records, Dict{String,Any}(
        "snapshot" => snapshot,
        "result_units" => units,
        "canonical_quality" => get(original, "endpoint_quality", nothing),
        "canonical_termination_status" => get(original, "termination_status", nothing),
        "canonical_feasible" => get(original, "feasible", nothing),
        "canonical_nonfinite_numeric_count" => get(original, "nonfinite_numeric_count", nothing),
        "candidate" => candidate,
        "promotable" => get(candidate, "candidate_quality", "") == "usable_solver_endpoint",
    ))
end

promotable_count = count(get(record, "promotable", false) === true for record in records)
payload = Dict{String,Any}(
    "schema_version" => "nlpdiagnostics-bmopf-rerun-candidate-validation-v1",
    "source" => Dict{String,Any}(
        "quality_summary" => quality_path,
        "candidate_root" => candidate_root,
        "validator" => "benchmarks/validate_bmopf_rerun_candidates.jl",
    ),
    "environment" => Dict{String,Any}(
        "git_revision" => git_revision(),
        "git_worktree_dirty" => !isempty(git_status_entries()),
    ),
    "candidate_count" => length(records),
    "candidate_available_count" => count(get(record, "candidate", Dict())["available"] === true for record in records),
    "candidate_usable_solver_endpoint_count" => promotable_count,
    "candidate_nonfinite_or_unsolved_count" => length(records) - promotable_count,
    "all_candidates_usable" => promotable_count == length(records) && !isempty(records),
    "canonical_boundary_count_before_promotion" => length(records),
    "records" => records,
    "interpretation" => "Candidates are canonical-shaped BMOPFTools SI results validated in a separate root. They are promotable only after review and an explicit copy into the source corpus; this artifact does not mutate BMOPFDraftData or close the saved-result release boundary by itself.",
)
write_json(output_path, payload)
println("wrote BMOPF rerun candidate validation to $output_path")
