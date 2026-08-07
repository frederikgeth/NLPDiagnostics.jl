#!/usr/bin/env julia

"""Summarize repeated BMOPF profiles across explicit evaluation-point policies.

The output does not assign a stability score. It records exact finding-identity
count changes, repeatability at one policy, persistence across policies,
evaluation-point provenance, saved-result mapping coverage, registry coverage,
and the dense-analysis budget used by every child.
"""

using JSON

const _POINT_INVARIANT_STAGES = Set(("static", "expressions", "reformulation"))
const _POINT_LOCAL_STAGES = Set(("numerical", "active_set", "degeneracy"))

_dict(value) = value isa AbstractDict ?
    Dict{String,Any}(string(key) => item for (key, item) in value) :
    Dict{String,Any}()

function _int(value, default = 0)
    value isa Integer && return Int(value)
    value isa Number && return Int(value)
    value isa AbstractString || return default
    return something(tryparse(Int, value), default)
end

function _load(path)
    isfile(path) || error("missing point-calibration artifact: $path")
    value = JSON.parsefile(path)
    value isa AbstractDict || error("point-calibration artifact is not an object: $path")
    return value
end

function _finding_identity(finding)
    finding = _dict(finding)
    return join((
        String(get(finding, "code", "unknown")),
        String(get(finding, "severity", "unknown")),
        String(get(finding, "confidence", "unknown")),
        String(get(finding, "basis", "unknown")),
        String(get(finding, "domain", "unknown")),
    ), '|')
end

function _signature(report)
    counts = Dict{String,Int}()
    for finding in get(_dict(report), "findings", Any[])
        identity = _finding_identity(finding)
        counts[identity] = get(counts, identity, 0) + 1
    end
    return Dict(key => counts[key] for key in sort!(collect(keys(counts))))
end

function _stage_signatures(record)
    profile = _dict(get(record, "profile", nothing))
    generic = _dict(get(profile, "profile", nothing))
    reports = _dict(get(generic, "reports", nothing))
    result = Dict{String,Any}(
        stage => _signature(report) for (stage, report) in reports
    )
    initialization = get(profile, "bmopf_initialization_report", nothing)
    initialization isa AbstractDict &&
        (result["bmopf_initialization"] = _signature(initialization))
    return Dict(key => result[key] for key in sort!(collect(keys(result))))
end

function _metadata(report)
    report isa AbstractDict || return Dict{String,Any}()
    return _dict(get(report, "metadata", nothing))
end

function _observation(entry, case_entry, record_path, record)
    profile = _dict(get(record, "profile", nothing))
    generic = _dict(get(profile, "profile", nothing))
    case = _dict(get(generic, "case", nothing))
    point = _dict(get(case, "point", nothing))
    provenance = _dict(get(point, "provenance", nothing))
    trust = _dict(get(case, "point_trust", nothing))
    trust_metadata = _dict(get(trust, "metadata", nothing))
    registry = _metadata(get(profile, "bmopf_constraint_registry_coverage", nothing))
    mapping = _metadata(get(profile, "bmopf_saved_result_mapping_report", nothing))
    coordinate_count = _int(get(mapping, "bmopf_saved_result_coordinate_count", 0))
    saved_mapping_complete = String(get(record, "point_policy", "")) == "saved_result" &&
        String(get(provenance, "kind", "")) == "SolverResultPoint" &&
        get(provenance, "complete", false) === true &&
        _int(get(trust_metadata, "selected_count", 0)) > 0 &&
        coordinate_count > 0 &&
        _int(get(mapping, "bmopf_saved_result_fallback_coordinate_count", 0)) == 0 &&
        _int(get(mapping, "bmopf_saved_result_unmapped_registered_coordinate_count", 0)) == 0 &&
        _int(get(mapping, "bmopf_saved_result_unregistered_model_coordinate_count", 0)) == 0 &&
        _int(get(mapping, "bmopf_saved_result_mapped_coordinate_count", 0)) == coordinate_count
    return Dict{String,Any}(
        "case" => String(get(case_entry, "name", get(case_entry, "snapshot", "?"))),
        "snapshot" => get(case_entry, "snapshot", get(record, "snapshot", nothing)),
        "point" => get(entry, "point", nothing),
        "replicate" => _int(get(entry, "replicate", 0)),
        "point_policy" => get(record, "point_policy", get(entry, "point_policy", nothing)),
        "result_units" => get(entry, "result_units", nothing),
        "record_path" => record_path,
        "environment_fingerprint" => get(record, "environment_fingerprint",
            get(entry, "child_environment_fingerprint", nothing)),
        "point_fingerprint" => get(point, "fingerprint", nothing),
        "point_label" => get(point, "label", nothing),
        "point_provenance_kind" => get(provenance, "kind", nothing),
        "point_provenance_complete" => get(provenance, "complete", nothing),
        "trust_selected_count" => _int(get(trust_metadata, "selected_count", 0)),
        "trust_rejected_count" => _int(get(trust_metadata, "rejected_count", 0)),
        "saved_result_mapping_complete" => saved_mapping_complete,
        "saved_result_mapping_metadata" => mapping,
        "registry_row_count" =>
            _int(get(registry, "bmopf_constraint_registry_row_count", 0)),
        "registry_registered_row_count" =>
            _int(get(registry, "bmopf_constraint_registry_registered_row_count", 0)),
        "registry_unregistered_row_count" =>
            _int(get(registry, "bmopf_constraint_registry_unregistered_row_count", 0)),
        "registry_unregistered_rows" =>
            get(registry, "bmopf_constraint_registry_unregistered_rows", ""),
        "dense_rank_analysis_eligible" =>
            get(record, "dense_rank_analysis_eligible", nothing),
        "rank_max_dense_entries" => get(record, "rank_max_dense_entries", nothing),
        "jacobian_dense_entry_count" => get(record, "jacobian_dense_entry_count", nothing),
        "stage_signatures" => _stage_signatures(record),
    )
end

function _load_observations(manifest)
    observations = Dict{String,Any}[]
    run_failures = Dict{String,Any}[]
    for run_raw in get(manifest, "runs", Any[])
        run = _dict(run_raw)
        if String(get(run, "status", "unknown")) != "ok"
            push!(run_failures, run)
            continue
        end
        output_directory = String(get(run, "output_directory", ""))
        index_path = joinpath(output_directory, "index.json")
        if !isfile(index_path)
            failed = copy(run)
            failed["status"] = "missing_child_index"
            push!(run_failures, failed)
            continue
        end
        index = _load(index_path)
        for case_raw in get(index, "cases", Any[])
            case = _dict(case_raw)
            if String(get(case, "status", "unknown")) != "ok"
                failed = copy(run)
                failed["status"] = "child_case_$(get(case, "status", "unknown"))"
                failed["case"] = get(case, "name", get(case, "snapshot", nothing))
                push!(run_failures, failed)
                continue
            end
            result_file = String(get(case, "result_file", ""))
            record_path = joinpath(output_directory, result_file)
            push!(observations, _observation(
                run, case, record_path, _load(record_path),
            ))
        end
    end
    return observations, run_failures
end

function _signature_changes(baseline, candidate)
    baseline = _dict(baseline)
    candidate = _dict(candidate)
    changes = Dict{String,Any}()
    for identity in sort!(collect(union(keys(baseline), keys(candidate))))
        before = _int(get(baseline, identity, 0))
        after = _int(get(candidate, identity, 0))
        before == after && continue
        changes[identity] = Dict(
            "baseline_count" => before,
            "candidate_count" => after,
            "delta" => after - before,
        )
    end
    return changes
end

function _stage_changes(baseline, candidate)
    baseline = _dict(baseline)
    candidate = _dict(candidate)
    result = Dict{String,Any}()
    for stage in sort!(collect(union(keys(baseline), keys(candidate))))
        changes = _signature_changes(get(baseline, stage, Dict()),
                                     get(candidate, stage, Dict()))
        result[stage] = Dict(
            "classification" => stage in _POINT_INVARIANT_STAGES ?
                "point_invariant" : stage in _POINT_LOCAL_STAGES ?
                "point_local" : "auxiliary",
            "identical" => isempty(changes),
            "changes" => changes,
        )
    end
    return result
end

function _all_equal(values)
    isempty(values) && return false
    first_value = first(values)
    return all(value -> value == first_value, values)
end

function _case_summary(case_name, by_policy, baseline_policy)
    repeatability = Dict{String,Any}()
    for (policy, observations) in sort!(collect(by_policy); by = first)
        stage_names = sort!(collect(union((
            Set(keys(_dict(get(observation, "stage_signatures", nothing))))
            for observation in observations
        )...)))
        stages = Dict{String,Any}()
        for stage in stage_names
            signatures = [get(_dict(get(observation, "stage_signatures", nothing)),
                              stage, Dict()) for observation in observations]
            stages[stage] = Dict(
                "classification" => stage in _POINT_INVARIANT_STAGES ?
                    "point_invariant" : stage in _POINT_LOCAL_STAGES ?
                    "point_local" : "auxiliary",
                "repeatable" => length(signatures) >= 2 && _all_equal(signatures),
                "available_replicate_count" => length(signatures),
            )
        end
        point_fingerprints = sort!(unique(filter(
            value -> value isa AbstractString,
            [get(observation, "point_fingerprint", nothing)
             for observation in observations],
        )))
        repeatability[policy] = Dict(
            "observation_count" => length(observations),
            "point_fingerprints" => point_fingerprints,
            "point_fingerprint_repeatable" =>
                length(observations) >= 2 && length(point_fingerprints) == 1,
            "stages" => stages,
        )
    end
    comparisons = Dict{String,Any}()
    if haskey(by_policy, baseline_policy)
        baseline = first(by_policy[baseline_policy])
        for policy in sort!(collect(keys(by_policy)))
            policy == baseline_policy && continue
            candidate = first(by_policy[policy])
            comparisons[policy] = Dict(
                "baseline_policy" => baseline_policy,
                "candidate_policy" => policy,
                "baseline_point_fingerprint" => get(baseline, "point_fingerprint", nothing),
                "candidate_point_fingerprint" => get(candidate, "point_fingerprint", nothing),
                "stage_comparisons" => _stage_changes(
                    get(baseline, "stage_signatures", Dict()),
                    get(candidate, "stage_signatures", Dict()),
                ),
            )
        end
    end
    observations = vcat(values(by_policy)...)
    return Dict{String,Any}(
        "case" => case_name,
        "policies" => sort!(collect(keys(by_policy))),
        "observation_count" => length(observations),
        "repeatability" => repeatability,
        "comparisons" => comparisons,
        "registry_complete" => all(observation ->
            _int(get(observation, "registry_row_count", 0)) > 0 &&
            _int(get(observation, "registry_registered_row_count", 0)) ==
                _int(get(observation, "registry_row_count", 0)) &&
            _int(get(observation, "registry_unregistered_row_count", 0)) == 0,
            observations),
        "trusted_saved_point_available" => any(observation ->
            get(observation, "saved_result_mapping_complete", false) === true,
            observations),
        "observations" => observations,
    )
end

function _finding(code, severity, observation, evidence; suggested_action = nothing)
    result = Dict{String,Any}(
        "code" => code,
        "severity" => severity,
        "domain" => severity == "error" ? "representational" : "numerical",
        "confidence" => "certain",
        "basis" => "observed_campaign_evidence",
        "observation" => observation,
        "evidence" => evidence,
    )
    isnothing(suggested_action) || (result["suggested_action"] = suggested_action)
    return result
end

function main()
    length(ARGS) in (1, 2) || error(
        "usage: summarize_bmopf_point_calibration.jl calibration_index.json [summary.json]",
    )
    manifest_path = abspath(first(ARGS))
    manifest = _load(manifest_path)
    startswith(String(get(manifest, "runner_version", "")),
               "bmopf-point-calibration-launcher-") || error(
        "input is not a BMOPF point-calibration manifest",
    )
    output_path = length(ARGS) == 2 ? abspath(ARGS[2]) :
        joinpath(dirname(manifest_path), "calibration_summary.json")
    observations, run_failures = _load_observations(manifest)
    grouped = Dict{String,Dict{String,Vector{Dict{String,Any}}}}()
    for observation in observations
        case_name = String(observation["case"])
        policy = String(observation["point"])
        by_policy = get!(grouped, case_name,
            Dict{String,Vector{Dict{String,Any}}}())
        push!(get!(by_policy, policy, Dict{String,Any}[]), observation)
    end
    selected_points = String.(get(manifest, "points", Any[]))
    baseline_policy = "engine_start" in selected_points ?
        "engine_start" : isempty(selected_points) ? "" : first(selected_points)
    case_summaries = Dict{String,Any}[
        _case_summary(case_name, by_policy, baseline_policy)
        for (case_name, by_policy) in sort!(collect(grouped); by = first)
    ]
    invariant_repeat_failures = 0
    same_point_repeat_failures = 0
    point_fingerprint_repeat_failures = 0
    invariant_cross_point_changes = 0
    local_cross_point_changes = 0
    for case in case_summaries
        for policy in values(_dict(get(case, "repeatability", nothing)))
            _int(get(policy, "observation_count", 0)) >= 2 &&
                get(policy, "point_fingerprint_repeatable", false) !== true &&
                (point_fingerprint_repeat_failures += 1)
            for stage in values(_dict(get(policy, "stages", nothing)))
                _int(get(stage, "available_replicate_count", 0)) >= 2 || continue
                if get(stage, "repeatable", false) !== true
                    same_point_repeat_failures += 1
                    get(stage, "classification", "") == "point_invariant" &&
                        (invariant_repeat_failures += 1)
                end
            end
        end
        for comparison in values(_dict(get(case, "comparisons", nothing)))
            for stage in values(_dict(get(comparison, "stage_comparisons", nothing)))
                get(stage, "identical", false) === true && continue
                if get(stage, "classification", "") == "point_invariant"
                    invariant_cross_point_changes += 1
                elseif get(stage, "classification", "") == "point_local"
                    local_cross_point_changes += 1
                end
            end
        end
    end
    environments = sort!(unique(filter(
        value -> value isa AbstractString && !isempty(value),
        [get(observation, "environment_fingerprint", nothing)
         for observation in observations],
    )))
    registry_complete = !isempty(observations) && all(
        observation -> _int(get(observation, "registry_row_count", 0)) > 0 &&
                       _int(get(observation, "registry_registered_row_count", 0)) ==
                           _int(get(observation, "registry_row_count", 0)) &&
                       _int(get(observation, "registry_unregistered_row_count", 0)) == 0,
        observations,
    )
    trusted_saved_cases = count(
        case -> get(case, "trusted_saved_point_available", false) === true,
        case_summaries,
    )
    repeated_available = !isempty(case_summaries) &&
        _int(get(manifest, "repetitions", 0)) >= 2 &&
        all(case -> all(policy -> _int(get(policy, "observation_count", 0)) >= 2,
                         values(_dict(get(case, "repeatability", nothing)))),
            case_summaries)
    point_comparison_available = !isempty(case_summaries) &&
        length(selected_points) >= 2 &&
        all(case -> !isempty(_dict(get(case, "comparisons", nothing))), case_summaries)
    findings = Dict{String,Any}[]
    !isempty(run_failures) && push!(findings, _finding(
        "point_calibration_child_failure", "error",
        "Some point-calibration children or case records did not complete.",
        Dict("failure_count" => length(run_failures), "failures" => run_failures);
        suggested_action = "Inspect child process logs and rerun before comparing finding persistence.",
    ))
    length(environments) > 1 && push!(findings, _finding(
        "point_calibration_environment_mismatch", "warning",
        "Point-calibration observations were produced under different environments.",
        Dict("environment_fingerprints" => environments);
        suggested_action = "Align Julia and package revisions before attributing changes to evaluation points.",
    ))
    !registry_complete && push!(findings, _finding(
        "point_calibration_registry_incomplete", "warning",
        "At least one compared profile lacks complete all-row semantic registry coverage.",
        Dict("observation_count" => length(observations));
        suggested_action = "Resolve uncovered rows before interpreting point-dependent findings by equation family.",
    ))
    invariant_repeat_failures > 0 && push!(findings, _finding(
        "point_calibration_repeatability_failure", "warning",
        "A nominally point-invariant report stage changed across repeated runs at one point.",
        Dict("changed_stage_count" => invariant_repeat_failures);
        suggested_action = "Inspect nondeterministic ordering, randomized probes, and environment changes before trusting recurrence.",
    ))
    same_point_repeat_failures > invariant_repeat_failures && push!(findings, _finding(
        "point_calibration_same_point_finding_drift", "warning",
        "Point-local or auxiliary report stages changed across repeated runs at one exact point.",
        Dict("changed_stage_count" => same_point_repeat_failures,
             "point_invariant_changed_stage_count" => invariant_repeat_failures);
        suggested_action = "Inspect randomized probes, nondeterministic ordering, and numerical-library variability before using recurrence evidence.",
    ))
    point_fingerprint_repeat_failures > 0 && push!(findings, _finding(
        "point_calibration_point_fingerprint_drift", "error",
        "Repeated observations for one point policy did not use one exact evaluation point.",
        Dict("changed_policy_count" => point_fingerprint_repeat_failures);
        suggested_action = "Align the point source or saved-result artifact before comparing same-point findings.",
    ))
    invariant_cross_point_changes > 0 && push!(findings, _finding(
        "point_calibration_invariant_stage_changed", "warning",
        "A nominally point-invariant report stage changed when only the evaluation-point policy changed.",
        Dict("changed_stage_count" => invariant_cross_point_changes);
        suggested_action = "Review stage classification or remove hidden point dependence before treating the finding as structural.",
    ))
    local_cross_point_changes > 0 && push!(findings, _finding(
        "point_calibration_local_finding_changed", "info",
        "Point-local finding identities changed across evaluation-point policies.",
        Dict("changed_stage_count" => local_cross_point_changes);
        suggested_action = "Use the exact stage deltas as local numerical evidence; do not promote them to global model facts.",
    ))
    trusted_saved_cases < length(case_summaries) && push!(findings, _finding(
        "point_calibration_trusted_saved_point_missing", "warning",
        "Some calibrated cases lack a completely mapped saved solver point.",
        Dict("case_count" => length(case_summaries),
             "trusted_saved_case_count" => trusted_saved_cases);
        suggested_action = "Provide complete saved solver results before drawing physical conclusions from point persistence.",
    ))
    payload = Dict{String,Any}(
        "report_version" => "bmopf-point-calibration-v1",
        "manifest_path" => manifest_path,
        "benchmark_root" => get(manifest, "benchmark_root", nothing),
        "points" => selected_points,
        "repetitions" => get(manifest, "repetitions", nothing),
        "rank_max_dense_entries" => get(manifest, "rank_max_dense_entries", nothing),
        "environment_fingerprints" => environments,
        "observation_count" => length(observations),
        "case_count" => length(case_summaries),
        "run_failure_count" => length(run_failures),
        "trusted_saved_case_count" => trusted_saved_cases,
        "registry_complete" => registry_complete,
        "point_invariant_repeat_failure_count" => invariant_repeat_failures,
        "same_point_repeat_failure_count" => same_point_repeat_failures,
        "point_fingerprint_repeat_failure_count" => point_fingerprint_repeat_failures,
        "point_invariant_cross_point_change_count" => invariant_cross_point_changes,
        "point_local_cross_point_change_count" => local_cross_point_changes,
        "cases" => case_summaries,
        "run_failures" => run_failures,
        "readiness" => Dict(
            "child_process_health" => isempty(run_failures),
            "aligned_environment" => length(environments) <= 1,
            "complete_registry_coverage" => registry_complete,
            "repeated_observations" => repeated_available,
            "same_point_fingerprint_stability" =>
                point_fingerprint_repeat_failures == 0,
            "same_point_finding_stability" => same_point_repeat_failures == 0,
            "point_comparison_available" => point_comparison_available,
            "point_invariant_stage_stability" =>
                invariant_repeat_failures == 0 && invariant_cross_point_changes == 0,
            "trusted_saved_point_coverage" =>
                !isempty(case_summaries) && trusted_saved_cases == length(case_summaries),
        ),
        "findings" => findings,
        "interpretation" => "Finding recurrence and point persistence are empirical evidence. Point-local agreement is not a mathematical or physical proof.",
    )
    write(output_path, JSON.json(payload))
    println("wrote BMOPF point-calibration summary to $output_path")
end

main()
