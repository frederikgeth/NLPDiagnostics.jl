#!/usr/bin/env julia

"""Summarize repeated BMOPF perturbation matrices.

The output distinguishes baseline instability from variant effects. Repeated
termination or iteration changes are reported as observations only; no score
or causal claim is inferred.
"""

using JSON

function _load(path)
    isfile(path) || error("missing repeat artifact: $path")
    value = JSON.parsefile(path)
    value isa AbstractDict || error("repeat artifact is not a JSON object: $path")
    value
end

function _dict(value)
    value isa AbstractDict || return Dict{String,Any}()
    Dict{String,Any}(string(k) => v for (k, v) in value)
end

function _int(value, default = 0)
    value isa Integer && return Int(value)
    value isa Number && return Int(value)
    value isa AbstractString || return default
    try parse(Int, value) catch; default end
end

function _push_count!(dict, key)
    key = String(key)
    dict[key] = get(dict, key, 0) + 1
end

function main()
    length(ARGS) in (1, 2) || error(
        "usage: summarize_bmopf_perturbation_repeats.jl <repeat-output> [summary.json]",
    )
    root = abspath(ARGS[1])
    index_path = joinpath(root, "repeat_index.json")
    index = _load(index_path)
    observations = Dict{String,Any}[]
    pair_groups = Dict{String,Vector{Dict{String,Any}}}()
    artifact_errors = Dict{String,Any}[]
    environment_fingerprints = String[]
    for entry_raw in get(index, "entries", Any[])
        entry = _dict(entry_raw)
        run_id = String(get(entry, "run_id", "unknown"))
        summary_path = get(entry, "matrix_summary", nothing)
        if !(summary_path isa AbstractString) || !isfile(summary_path)
            push!(artifact_errors, Dict("run_id" => run_id,
                                        "status" => get(entry, "status", "missing_summary"),
                                        "path" => summary_path))
            continue
        end
        matrix = _dict(_load(summary_path))
        for summary_raw in values(_dict(get(matrix, "solver_summaries", nothing)))
            fingerprint = get(_dict(summary_raw), "environment_fingerprint", nothing)
            fingerprint isa AbstractString && push!(environment_fingerprints, fingerprint)
        end
        family_matrix = _dict(get(matrix, "family_perturbation_matrix", nothing))
        for variant_raw in get(family_matrix, "variants", Any[])
            variant = _dict(variant_raw)
            solver = String(get(variant, "solver", "unknown"))
            case = String(get(variant, "case", "unknown"))
            family = String(get(variant, "family", "unknown"))
            observation = Dict{String,Any}(variant)
            observation["run_id"] = run_id
            observation["replicate_index"] = get(entry, "replicate_index", nothing)
            observation["matrix_summary"] = summary_path
            push!(observations, observation)
            key = join((solver, case, family), "|")
            push!(get!(pair_groups, key, Dict{String,Any}[]), observation)
        end
    end
    by_pair = Dict{String,Any}()
    by_family = Dict{String,Any}()
    baseline_inconsistency_count = 0
    repeatable_change_count = 0
    stable_pair_count = 0
    for (key, group) in pair_groups
        baselines = unique(String(get(item, "baseline_termination", "unknown")) for item in group)
        changes = [_dict(item)["termination_changed_vs_baseline"] for item in group
                   if haskey(item, "termination_changed_vs_baseline")]
        changed_count = count(value -> value === true, changes)
        baseline_consistent = length(baselines) <= 1
        baseline_consistent || (baseline_inconsistency_count += 1)
        repeatable = length(group) >= 2 && baseline_consistent &&
                     !isempty(changes) && changed_count == length(changes)
        stable = length(group) >= 2 && baseline_consistent &&
                 !isempty(changes) && changed_count == 0
        repeatable && (repeatable_change_count += 1)
        stable && (stable_pair_count += 1)
        by_pair[key] = Dict{String,Any}(
            "solver" => first(split(key, '|')), "case" => split(key, '|')[2],
            "family" => split(key, '|')[3], "replicate_count" => length(group),
            "baseline_terminations" => baselines,
            "baseline_consistent" => baseline_consistent,
            "variant_status_counts" => Dict(String(status) => count(item -> get(item, "status", nothing) == status, group)
                                             for status in unique(get(item, "status", "unknown") for item in group)),
            "termination_change_count" => changed_count,
            "repeatable_termination_change" => repeatable,
            "repeatable_termination_stability" => stable,
            "observations" => group,
        )
        family = split(key, '|')[3]
        aggregate = get!(by_family, family, Dict{String,Any}(
            "pair_count" => 0, "replicate_observation_count" => 0,
            "baseline_inconsistency_count" => 0, "repeatable_pair_count" => 0,
            "stable_pair_count" => 0,
            "termination_change_count" => 0,
        ))
        aggregate["pair_count"] += 1
        aggregate["replicate_observation_count"] += length(group)
        !baseline_consistent && (aggregate["baseline_inconsistency_count"] += 1)
        repeatable && (aggregate["repeatable_pair_count"] += 1)
        stable && (aggregate["stable_pair_count"] += 1)
        aggregate["termination_change_count"] += changed_count
    end
    output_path = length(ARGS) == 2 ? abspath(ARGS[2]) : joinpath(root, "repeat_summary.json")
    write(output_path, JSON.json(Dict(
        "runner_version" => get(index, "runner_version", nothing),
        "repeat_index" => index_path,
        "benchmark_root" => get(index, "benchmark_root", nothing),
        "replicate_count" => get(index, "replicate_count", nothing),
        "family_perturbation_families" => get(index, "family_perturbation_families", Any[]),
        "environment_fingerprints" => sort!(unique(environment_fingerprints)),
        "observation_count" => length(observations),
        "artifact_errors" => artifact_errors,
        "baseline_inconsistency_count" => baseline_inconsistency_count,
        "repeatable_termination_change_count" => repeatable_change_count,
        "stable_termination_pair_count" => stable_pair_count,
        "by_family" => by_family,
        "by_pair" => by_pair,
        "interpretation" => "Repeated observations expose baseline consistency and variant sensitivity; incomplete family omissions remain formulation experiments, not causal or physical proofs.",
    )))
    println("wrote repeated BMOPF perturbation summary to $output_path")
end

main()
