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
const _CALIBRATION_METRICS = Dict(
    "numerical" => (
        "jacobian_rank_available", "jacobian_rank",
        "sparse_qr_rank_available", "sparse_qr_rank",
        "sparse_jacobian_pattern_rank_upper_bound",
        "dense_sparse_qr_unscaled_rank_agree",
        "sparse_qr_condition_proxy", "jacobian_rank_relative_tolerance",
    ),
    "active_set" => (
        "active_row_count", "active_jacobian_rank_available",
        "active_jacobian_rank",
        "active_structural_matching_cardinality",
        "active_dm_underdetermined_row_count",
        "active_dm_underdetermined_variable_count",
        "active_dm_overdetermined_row_count",
        "active_dm_overdetermined_variable_count",
        "mfcq_equality_jacobian_rank", "active_multiplier_unique",
    ),
    "degeneracy" => (
        "structural_numerical_comparison_available",
        "aligned_numerical_rank", "structural_matching_rank",
        "generic_nullspace_fingerprint_count",
        "declared_expected_nullspace_mode_count",
        "port_expected_nullspace_mode_count",
    ),
)

const _ROW_FAMILY_SCALE_METRICS = (
    "component_family", "row_count", "finite_positive_row_count",
    "zero_row_count", "nonfinite_row_count", "unavailable_row_count",
    "combined_nonzero_entry_count", "smallest_positive_row_norm",
    "row_norm_q25", "row_norm_median", "row_norm_q75",
    "largest_finite_row_norm", "row_scale_ratio",
    "owns_global_smallest_positive_row_norm",
    "owns_global_largest_finite_row_norm",
)

const _ROW_FAMILY_GLOBAL_SCALE_METRICS = (
    "row_count", "family_count", "smallest_positive_row_norm",
    "largest_finite_row_norm", "row_scale_ratio",
    "global_minimum_families", "global_maximum_families",
    "unclassified_family_count",
)

function _metric_available(stage, key, metadata)
    if stage == "numerical" && key in (
        "jacobian_rank", "dense_sparse_qr_unscaled_rank_agree",
        "jacobian_rank_relative_tolerance",
    )
        return get(metadata, "jacobian_rank_available", "false") == "true"
    elseif stage == "numerical" && key in (
        "sparse_qr_rank", "sparse_qr_condition_proxy",
    )
        return get(metadata, "sparse_qr_rank_available", "false") == "true"
    elseif stage == "active_set" && key in (
        "active_jacobian_rank", "mfcq_equality_jacobian_rank",
    )
        return get(metadata, "active_jacobian_rank_available", "false") == "true"
    elseif stage == "degeneracy" && key in (
        "aligned_numerical_rank", "generic_nullspace_fingerprint_count",
    )
        return get(
            metadata, "structural_numerical_comparison_available", "false",
        ) == "true"
    end
    return true
end

_dict(value) = value isa AbstractDict ?
    Dict{String,Any}(string(key) => item for (key, item) in value) :
    Dict{String,Any}()

function _int(value, default = 0)
    value isa Integer && return Int(value)
    value isa Number && return Int(value)
    value isa AbstractString || return default
    return something(tryparse(Int, value), default)
end

function _float(value)
    value isa Bool && return nothing
    value isa Number && return Float64(value)
    value isa AbstractString || return nothing
    return tryparse(Float64, value)
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

function _stage_metrics(record)
    profile = _dict(get(record, "profile", nothing))
    generic = _dict(get(profile, "profile", nothing))
    reports = _dict(get(generic, "reports", nothing))
    result = Dict{String,Any}()
    for (stage, keys) in _CALIBRATION_METRICS
        metadata = _metadata(get(reports, stage, nothing))
        result[stage] = Dict{String,Any}(
            key => metadata[key] for key in keys
            if haskey(metadata, key) && _metric_available(stage, key, metadata)
        )
    end
    return result
end

function _row_family_scale_metrics(record)
    profile = _dict(get(record, "profile", nothing))
    attribution = _dict(get(
        profile, "bmopf_jacobian_row_family_scale_attribution", nothing,
    ))
    isempty(attribution) && return Dict{String,Any}()
    families = Dict{String,Any}()
    for (family, raw) in _dict(get(attribution, "families", nothing))
        data = _dict(raw)
        families[family] = Dict{String,Any}(
            key => data[key] for key in _ROW_FAMILY_SCALE_METRICS
            if haskey(data, key)
        )
    end
    global_metrics = Dict{String,Any}(
        key => attribution[key] for key in _ROW_FAMILY_GLOBAL_SCALE_METRICS
        if haskey(attribution, key)
    )
    return Dict{String,Any}(
        "report_version" => get(attribution, "report_version", nothing),
        "label_source" => get(attribution, "label_source", nothing),
        "component_family_source" =>
            get(attribution, "component_family_source", nothing),
        "global" => global_metrics,
        "families" => families,
    )
end

function _row_family_scaling_experiment_metrics(record)
    profile = _dict(get(record, "profile", nothing))
    experiment = _dict(get(
        profile, "bmopf_jacobian_row_family_scaling_experiment", nothing,
    ))
    isempty(experiment) && return Dict{String,Any}()
    return Dict{String,Any}(
        "report_version" => get(experiment, "report_version", nothing),
        "label_source" => get(experiment, "label_source", nothing),
        "global" => Dict{String,Any}(
            key => experiment[key] for key in (
                "baseline_available", "baseline_rank",
                "baseline_condition_proxy", "relative_tolerance",
                "scaling_intervention",
            ) if haskey(experiment, key)
        ),
        "families" => _dict(get(experiment, "families", nothing)),
    )
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
        "model_variable_count" => get(record, "model_variable_count", nothing),
        "scalar_constraint_row_count" =>
            get(record, "scalar_constraint_row_count", nothing),
        "child_elapsed_seconds" => get(entry, "elapsed_seconds", nothing),
        "child_attempt" => _int(get(entry, "attempt", 1), 1),
        "previous_attempts" => get(entry, "previous_attempts", Any[]),
        "stage_signatures" => _stage_signatures(record),
        "stage_metrics" => _stage_metrics(record),
        "row_family_scale_metrics" => _row_family_scale_metrics(record),
        "row_family_scaling_experiment_metrics" =>
            _row_family_scaling_experiment_metrics(record),
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

function _metric_changes(baseline, candidate)
    baseline = _dict(baseline)
    candidate = _dict(candidate)
    result = Dict{String,Any}()
    for stage in sort!(collect(union(keys(baseline), keys(candidate))))
        left = _dict(get(baseline, stage, nothing))
        right = _dict(get(candidate, stage, nothing))
        changes = Dict{String,Any}()
        stable = Dict{String,Any}()
        for metric in sort!(collect(union(keys(left), keys(right))))
            before = get(left, metric, nothing)
            after = get(right, metric, nothing)
            if before == after
                stable[metric] = before
                continue
            end
            changes[metric] = Dict(
                "baseline_value" => before,
                "candidate_value" => after,
            )
        end
        result[stage] = Dict(
            "classification" => stage in _POINT_INVARIANT_STAGES ?
                "point_invariant" : stage in _POINT_LOCAL_STAGES ?
                "point_local" : "auxiliary",
            "identical" => isempty(changes),
            "changes" => changes,
            "stable" => stable,
        )
    end
    return result
end

function _value_changes(baseline, candidate)
    baseline = _dict(baseline)
    candidate = _dict(candidate)
    changes = Dict{String,Any}()
    stable = Dict{String,Any}()
    for metric in sort!(collect(union(keys(baseline), keys(candidate))))
        before = get(baseline, metric, nothing)
        after = get(candidate, metric, nothing)
        if before == after
            stable[metric] = before
        else
            changes[metric] = Dict(
                "baseline_value" => before,
                "candidate_value" => after,
            )
        end
    end
    return Dict{String,Any}(
        "identical" => isempty(changes),
        "changes" => changes,
        "stable" => stable,
    )
end

function _row_family_scale_changes(baseline, candidate)
    baseline = _dict(baseline)
    candidate = _dict(candidate)
    left_families = _dict(get(baseline, "families", nothing))
    right_families = _dict(get(candidate, "families", nothing))
    families = Dict{String,Any}()
    for family in sort!(collect(union(keys(left_families), keys(right_families))))
        families[family] = _value_changes(
            get(left_families, family, Dict()),
            get(right_families, family, Dict()),
        )
    end
    global_changes = _value_changes(
        get(baseline, "global", Dict()), get(candidate, "global", Dict()),
    )
    return Dict{String,Any}(
        "available" => !isempty(baseline) && !isempty(candidate),
        "baseline_report_version" => get(baseline, "report_version", nothing),
        "candidate_report_version" => get(candidate, "report_version", nothing),
        "label_source_agrees" =>
            get(baseline, "label_source", nothing) ==
            get(candidate, "label_source", nothing),
        "component_family_source_agrees" =>
            get(baseline, "component_family_source", nothing) ==
            get(candidate, "component_family_source", nothing),
        "identical" => get(global_changes, "identical", false) === true &&
            all(data -> get(data, "identical", false) === true,
                values(families)),
        "global" => global_changes,
        "families" => families,
    )
end

function _all_equal(values)
    isempty(values) && return false
    first_value = first(values)
    return all(value -> value == first_value, values)
end

function _case_stratum(case_name, observations)
    snapshot = String(get(first(observations), "snapshot", case_name))
    matched = match(r"(?:^|/)(\d+)bus_(LN|LG)(?:/|$)", snapshot)
    bus_count = isnothing(matched) ? nothing : tryparse(Int, matched.captures[1])
    connection = isnothing(matched) ? "unknown" : matched.captures[2]
    label = isnothing(bus_count) ? "unclassified" : "$(bus_count)bus_$(connection)"
    return Dict{String,Any}(
        "label" => label,
        "bus_count" => bus_count,
        "connection" => connection,
        "model_variable_count" => _int(get(
            first(observations), "model_variable_count", 0,
        )),
        "scalar_constraint_row_count" => _int(get(
            first(observations), "scalar_constraint_row_count", 0,
        )),
        "jacobian_dense_entry_count" => _int(get(
            first(observations), "jacobian_dense_entry_count", 0,
        )),
    )
end

function _case_summary(case_name, by_policy, baseline_policy)
    repeatability = Dict{String,Any}()
    for (policy, observations) in sort!(collect(by_policy); by = first)
        family_scale_metrics = [
            _dict(get(observation, "row_family_scale_metrics", nothing))
            for observation in observations
        ]
        family_scaling_experiments = [
            _dict(get(
                observation, "row_family_scaling_experiment_metrics", nothing,
            )) for observation in observations
        ]
        stage_names = sort!(collect(union((
            Set(keys(_dict(get(observation, "stage_signatures", nothing))))
            for observation in observations
        )...)))
        stages = Dict{String,Any}()
        for stage in stage_names
            signatures = [get(_dict(get(observation, "stage_signatures", nothing)),
                              stage, Dict()) for observation in observations]
            metrics = [get(_dict(get(observation, "stage_metrics", nothing)),
                           stage, Dict()) for observation in observations]
            stages[stage] = Dict(
                "classification" => stage in _POINT_INVARIANT_STAGES ?
                    "point_invariant" : stage in _POINT_LOCAL_STAGES ?
                    "point_local" : "auxiliary",
                "repeatable" => length(signatures) >= 2 && _all_equal(signatures),
                "metrics_repeatable" => length(metrics) >= 2 && _all_equal(metrics),
                "metrics" => isempty(metrics) ? Dict() : first(metrics),
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
            "child_elapsed_seconds" => [
                get(observation, "child_elapsed_seconds", nothing)
                for observation in observations
            ],
            "child_attempts" => [
                _int(get(observation, "child_attempt", 1), 1)
                for observation in observations
            ],
            "point_fingerprints" => point_fingerprints,
            "point_fingerprint_repeatable" =>
                length(observations) >= 2 && length(point_fingerprints) == 1,
            "row_family_scale_available_replicate_count" =>
                count(value -> !isempty(value), family_scale_metrics),
            "row_family_scale_repeatable" =>
                length(family_scale_metrics) >= 2 &&
                all(value -> !isempty(value), family_scale_metrics) &&
                _all_equal(family_scale_metrics),
            "row_family_scale_metrics" =>
                isempty(family_scale_metrics) ? Dict() : first(family_scale_metrics),
            "row_family_scaling_experiment_available_replicate_count" =>
                count(value -> !isempty(value), family_scaling_experiments),
            "row_family_scaling_experiment_repeatable" =>
                length(family_scaling_experiments) >= 2 &&
                all(value -> !isempty(value), family_scaling_experiments) &&
                _all_equal(family_scaling_experiments),
            "row_family_scaling_experiment_metrics" =>
                isempty(family_scaling_experiments) ? Dict() :
                first(family_scaling_experiments),
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
                "stage_metric_comparisons" => _metric_changes(
                    get(baseline, "stage_metrics", Dict()),
                    get(candidate, "stage_metrics", Dict()),
                ),
                "row_family_scale_comparison" => _row_family_scale_changes(
                    get(baseline, "row_family_scale_metrics", Dict()),
                    get(candidate, "row_family_scale_metrics", Dict()),
                ),
                "row_family_scaling_experiment_comparison" =>
                    _row_family_scale_changes(
                        get(baseline,
                            "row_family_scaling_experiment_metrics", Dict()),
                        get(candidate,
                            "row_family_scaling_experiment_metrics", Dict()),
                    ),
            )
        end
    end
    observations = vcat(values(by_policy)...)
    return Dict{String,Any}(
        "case" => case_name,
        "stratum" => _case_stratum(case_name, observations),
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

function _cross_case_change_recurrence(case_summaries)
    recurrence = Dict{String,Dict{String,Any}}()
    for case in case_summaries
        case_name = String(get(case, "case", "?"))
        stratum = String(get(
            _dict(get(case, "stratum", nothing)), "label", "unclassified",
        ))
        for (policy, comparison_raw) in _dict(get(case, "comparisons", nothing))
            comparison = _dict(comparison_raw)
            stage_comparisons = _dict(get(
                comparison, "stage_comparisons", nothing,
            ))
            for (stage, stage_raw) in stage_comparisons
                stage_data = _dict(stage_raw)
                classification = String(get(
                    stage_data, "classification", "auxiliary",
                ))
                for (identity, change_raw) in _dict(get(
                    stage_data, "changes", nothing,
                ))
                    change = _dict(change_raw)
                    key = join((String(policy), String(stage), String(identity)), '|')
                    item = get!(recurrence, key, Dict{String,Any}(
                        "candidate_policy" => String(policy),
                        "stage" => String(stage),
                        "classification" => classification,
                        "finding_identity" => String(identity),
                        "case_count" => 0,
                        "increased_case_count" => 0,
                        "decreased_case_count" => 0,
                        "baseline_count_total" => 0,
                        "candidate_count_total" => 0,
                        "delta_total" => 0,
                        "cases" => String[],
                        "stratum_case_counts" => Dict{String,Int}(),
                    ))
                    delta = _int(get(change, "delta", 0))
                    item["case_count"] += 1
                    delta > 0 && (item["increased_case_count"] += 1)
                    delta < 0 && (item["decreased_case_count"] += 1)
                    item["baseline_count_total"] +=
                        _int(get(change, "baseline_count", 0))
                    item["candidate_count_total"] +=
                        _int(get(change, "candidate_count", 0))
                    item["delta_total"] += delta
                    push!(item["cases"], case_name)
                    counts = item["stratum_case_counts"]
                    counts[stratum] = get(counts, stratum, 0) + 1
                end
            end
        end
    end
    values_sorted = collect(values(recurrence))
    sort!(values_sorted; by = item -> (
        -_int(get(item, "case_count", 0)),
        String(get(item, "candidate_policy", "")),
        String(get(item, "stage", "")),
        String(get(item, "finding_identity", "")),
    ))
    return values_sorted
end

function _cross_case_metric_change_recurrence(case_summaries)
    recurrence = Dict{String,Dict{String,Any}}()
    for case in case_summaries
        case_name = String(get(case, "case", "?"))
        stratum = String(get(
            _dict(get(case, "stratum", nothing)), "label", "unclassified",
        ))
        for (policy, comparison_raw) in _dict(get(case, "comparisons", nothing))
            comparison = _dict(comparison_raw)
            stages = _dict(get(comparison, "stage_metric_comparisons", nothing))
            for (stage, stage_raw) in stages
                stage_data = _dict(stage_raw)
                classification = String(get(
                    stage_data, "classification", "auxiliary",
                ))
                for (metric, change_raw) in _dict(get(
                    stage_data, "changes", nothing,
                ))
                    change = _dict(change_raw)
                    before = get(change, "baseline_value", nothing)
                    after = get(change, "candidate_value", nothing)
                    key = join((
                        String(policy), String(stage), String(metric),
                        JSON.json(before), JSON.json(after),
                    ), '|')
                    item = get!(recurrence, key, Dict{String,Any}(
                        "candidate_policy" => String(policy),
                        "stage" => String(stage),
                        "classification" => classification,
                        "metric" => String(metric),
                        "baseline_value" => before,
                        "candidate_value" => after,
                        "case_count" => 0,
                        "cases" => String[],
                        "stratum_case_counts" => Dict{String,Int}(),
                    ))
                    before_number = _float(before)
                    after_number = _float(after)
                    if !isnothing(before_number) && !isnothing(after_number)
                        item["numeric_delta"] = after_number - before_number
                        before_number == 0 ||
                            (item["numeric_ratio"] = after_number / before_number)
                    end
                    item["case_count"] += 1
                    push!(item["cases"], case_name)
                    counts = item["stratum_case_counts"]
                    counts[stratum] = get(counts, stratum, 0) + 1
                end
            end
        end
    end
    values_sorted = collect(values(recurrence))
    sort!(values_sorted; by = item -> (
        -_int(get(item, "case_count", 0)),
        String(get(item, "candidate_policy", "")),
        String(get(item, "stage", "")),
        String(get(item, "metric", "")),
        JSON.json(get(item, "baseline_value", nothing)),
    ))
    return values_sorted
end

function _cross_case_metric_persistence(case_summaries)
    persistence = Dict{String,Dict{String,Any}}()
    for case in case_summaries
        case_name = String(get(case, "case", "?"))
        stratum = String(get(
            _dict(get(case, "stratum", nothing)), "label", "unclassified",
        ))
        for (policy, comparison_raw) in _dict(get(case, "comparisons", nothing))
            comparison = _dict(comparison_raw)
            stages = _dict(get(comparison, "stage_metric_comparisons", nothing))
            for (stage, stage_raw) in stages
                stage_data = _dict(stage_raw)
                classification = String(get(
                    stage_data, "classification", "auxiliary",
                ))
                for (metric, value) in _dict(get(stage_data, "stable", nothing))
                    key = join((
                        String(policy), String(stage), String(metric),
                        JSON.json(value),
                    ), '|')
                    item = get!(persistence, key, Dict{String,Any}(
                        "candidate_policy" => String(policy),
                        "stage" => String(stage),
                        "classification" => classification,
                        "metric" => String(metric),
                        "value" => value,
                        "case_count" => 0,
                        "cases" => String[],
                        "stratum_case_counts" => Dict{String,Int}(),
                    ))
                    item["case_count"] += 1
                    push!(item["cases"], case_name)
                    counts = item["stratum_case_counts"]
                    counts[stratum] = get(counts, stratum, 0) + 1
                end
            end
        end
    end
    values_sorted = collect(values(persistence))
    sort!(values_sorted; by = item -> (
        -_int(get(item, "case_count", 0)),
        String(get(item, "candidate_policy", "")),
        String(get(item, "stage", "")),
        String(get(item, "metric", "")),
        JSON.json(get(item, "value", nothing)),
    ))
    return values_sorted
end

function _row_family_component_family(family_data)
    data = _dict(family_data)
    stable = _dict(get(data, "stable", nothing))
    haskey(stable, "component_family") &&
        return String(stable["component_family"])
    change = _dict(get(
        _dict(get(data, "changes", nothing)), "component_family", nothing,
    ))
    value = get(change, "candidate_value",
                get(change, "baseline_value", "unclassified"))
    return string(value)
end

function _cross_case_row_family_scale_recurrence(case_summaries)
    recurrence = Dict{String,Dict{String,Any}}()
    for case in case_summaries
        case_name = String(get(case, "case", "?"))
        stratum = String(get(
            _dict(get(case, "stratum", nothing)), "label", "unclassified",
        ))
        for (policy, comparison_raw) in _dict(get(case, "comparisons", nothing))
            comparison = _dict(comparison_raw)
            family_comparison = _dict(get(
                comparison, "row_family_scale_comparison", nothing,
            ))
            get(family_comparison, "available", false) === true || continue
            scopes = Dict{String,Any}("__global__" => get(
                family_comparison, "global", Dict(),
            ))
            merge!(scopes, _dict(get(family_comparison, "families", nothing)))
            for (family, family_raw) in scopes
                family_data = _dict(family_raw)
                component_family = family == "__global__" ? "__global__" :
                    _row_family_component_family(family_data)
                for (metric, change_raw) in _dict(get(
                    family_data, "changes", nothing,
                ))
                    change = _dict(change_raw)
                    before = get(change, "baseline_value", nothing)
                    after = get(change, "candidate_value", nothing)
                    key = join((String(policy), family, String(metric),
                                JSON.json(before), JSON.json(after)), '|')
                    item = get!(recurrence, key, Dict{String,Any}(
                        "candidate_policy" => String(policy),
                        "constraint_family" => family,
                        "component_family" => component_family,
                        "metric" => String(metric),
                        "baseline_value" => before,
                        "candidate_value" => after,
                        "case_count" => 0,
                        "cases" => String[],
                        "stratum_case_counts" => Dict{String,Int}(),
                    ))
                    before_number = _float(before)
                    after_number = _float(after)
                    if !isnothing(before_number) && !isnothing(after_number)
                        item["numeric_delta"] = after_number - before_number
                        before_number == 0 ||
                            (item["numeric_ratio"] = after_number / before_number)
                    end
                    item["case_count"] += 1
                    push!(item["cases"], case_name)
                    counts = item["stratum_case_counts"]
                    counts[stratum] = get(counts, stratum, 0) + 1
                end
            end
        end
    end
    result = collect(values(recurrence))
    sort!(result; by = item -> (
        -_int(get(item, "case_count", 0)),
        String(get(item, "candidate_policy", "")),
        String(get(item, "component_family", "")),
        String(get(item, "constraint_family", "")),
        String(get(item, "metric", "")),
    ))
    return result
end

function _cross_case_row_family_scale_direction_recurrence(case_summaries)
    recurrence = Dict{String,Dict{String,Any}}()
    for case in case_summaries
        case_name = String(get(case, "case", "?"))
        stratum = String(get(
            _dict(get(case, "stratum", nothing)), "label", "unclassified",
        ))
        for (policy, comparison_raw) in _dict(get(case, "comparisons", nothing))
            family_comparison = _dict(get(
                _dict(comparison_raw), "row_family_scale_comparison", nothing,
            ))
            get(family_comparison, "available", false) === true || continue
            scopes = Dict{String,Any}("__global__" => get(
                family_comparison, "global", Dict(),
            ))
            merge!(scopes, _dict(get(family_comparison, "families", nothing)))
            for (family, family_raw) in scopes
                family_data = _dict(family_raw)
                component_family = family == "__global__" ? "__global__" :
                    _row_family_component_family(family_data)
                for (metric, change_raw) in _dict(get(
                    family_data, "changes", nothing,
                ))
                    change = _dict(change_raw)
                    before = get(change, "baseline_value", nothing)
                    after = get(change, "candidate_value", nothing)
                    key = join((String(policy), family, String(metric)), '|')
                    item = get!(recurrence, key, Dict{String,Any}(
                        "candidate_policy" => String(policy),
                        "constraint_family" => family,
                        "component_family" => component_family,
                        "metric" => String(metric),
                        "case_count" => 0,
                        "increased_case_count" => 0,
                        "decreased_case_count" => 0,
                        "appeared_case_count" => 0,
                        "disappeared_case_count" => 0,
                        "other_change_case_count" => 0,
                        "numeric_ratios" => Float64[],
                        "cases" => String[],
                        "stratum_case_counts" => Dict{String,Int}(),
                    ))
                    before_number = _float(before)
                    after_number = _float(after)
                    if isnothing(before) && !isnothing(after)
                        item["appeared_case_count"] += 1
                    elseif !isnothing(before) && isnothing(after)
                        item["disappeared_case_count"] += 1
                    elseif !isnothing(before_number) && !isnothing(after_number)
                        after_number > before_number &&
                            (item["increased_case_count"] += 1)
                        after_number < before_number &&
                            (item["decreased_case_count"] += 1)
                        before_number != 0 && isfinite(before_number) &&
                            isfinite(after_number) && push!(
                                item["numeric_ratios"],
                                after_number / before_number,
                            )
                    else
                        item["other_change_case_count"] += 1
                    end
                    item["case_count"] += 1
                    push!(item["cases"], case_name)
                    counts = item["stratum_case_counts"]
                    counts[stratum] = get(counts, stratum, 0) + 1
                end
            end
        end
    end
    result = collect(values(recurrence))
    for item in result
        ratios = item["numeric_ratios"]
        item["minimum_numeric_ratio"] = isempty(ratios) ? nothing : minimum(ratios)
        item["maximum_numeric_ratio"] = isempty(ratios) ? nothing : maximum(ratios)
        delete!(item, "numeric_ratios")
    end
    sort!(result; by = item -> (
        -_int(get(item, "case_count", 0)),
        String(get(item, "candidate_policy", "")),
        String(get(item, "component_family", "")),
        String(get(item, "constraint_family", "")),
        String(get(item, "metric", "")),
    ))
    return result
end

function _cross_case_row_family_scale_persistence(case_summaries)
    persistence = Dict{String,Dict{String,Any}}()
    for case in case_summaries
        case_name = String(get(case, "case", "?"))
        stratum = String(get(
            _dict(get(case, "stratum", nothing)), "label", "unclassified",
        ))
        for (policy, comparison_raw) in _dict(get(case, "comparisons", nothing))
            family_comparison = _dict(get(
                _dict(comparison_raw), "row_family_scale_comparison", nothing,
            ))
            get(family_comparison, "available", false) === true || continue
            scopes = Dict{String,Any}("__global__" => get(
                family_comparison, "global", Dict(),
            ))
            merge!(scopes, _dict(get(family_comparison, "families", nothing)))
            for (family, family_raw) in scopes
                family_data = _dict(family_raw)
                component_family = family == "__global__" ? "__global__" :
                    _row_family_component_family(family_data)
                for (metric, value) in _dict(get(family_data, "stable", nothing))
                    key = join((String(policy), family, String(metric),
                                JSON.json(value)), '|')
                    item = get!(persistence, key, Dict{String,Any}(
                        "candidate_policy" => String(policy),
                        "constraint_family" => family,
                        "component_family" => component_family,
                        "metric" => String(metric),
                        "value" => value,
                        "case_count" => 0,
                        "cases" => String[],
                        "stratum_case_counts" => Dict{String,Int}(),
                    ))
                    item["case_count"] += 1
                    push!(item["cases"], case_name)
                    counts = item["stratum_case_counts"]
                    counts[stratum] = get(counts, stratum, 0) + 1
                end
            end
        end
    end
    result = collect(values(persistence))
    sort!(result; by = item -> (
        -_int(get(item, "case_count", 0)),
        String(get(item, "candidate_policy", "")),
        String(get(item, "component_family", "")),
        String(get(item, "constraint_family", "")),
        String(get(item, "metric", "")),
    ))
    return result
end

function _cross_case_row_family_scaling_experiment_summary(case_summaries)
    aggregate = Dict{String,Dict{String,Any}}()
    for case in case_summaries
        case_name = String(get(case, "case", "?"))
        stratum = String(get(
            _dict(get(case, "stratum", nothing)), "label", "unclassified",
        ))
        for (policy, repeat_raw) in _dict(get(case, "repeatability", nothing))
            experiment = _dict(get(
                _dict(repeat_raw),
                "row_family_scaling_experiment_metrics", nothing,
            ))
            for (family, result_raw) in _dict(get(
                experiment, "families", nothing,
            ))
                result = _dict(result_raw)
                key = join((String(policy), family), '|')
                item = get!(aggregate, key, Dict{String,Any}(
                    "point_policy" => String(policy),
                    "constraint_family" => family,
                    "case_count" => 0,
                    "available_case_count" => 0,
                    "unavailable_case_count" => 0,
                    "rank_changed_case_count" => 0,
                    "condition_proxy_improved_case_count" => 0,
                    "condition_proxy_worsened_case_count" => 0,
                    "condition_proxy_unchanged_case_count" => 0,
                    "condition_proxy_ratios" => Float64[],
                    "cases" => String[],
                    "stratum_case_counts" => Dict{String,Int}(),
                ))
                available = get(result, "available", false) === true
                item["case_count"] += 1
                available ? (item["available_case_count"] += 1) :
                    (item["unavailable_case_count"] += 1)
                rank_delta = _int(get(result, "rank_delta", 0))
                available && !iszero(rank_delta) &&
                    (item["rank_changed_case_count"] += 1)
                ratio = _float(get(result, "condition_proxy_ratio", nothing))
                if available && !isnothing(ratio)
                    push!(item["condition_proxy_ratios"], ratio)
                    ratio < 1 &&
                        (item["condition_proxy_improved_case_count"] += 1)
                    ratio > 1 &&
                        (item["condition_proxy_worsened_case_count"] += 1)
                    ratio == 1 &&
                        (item["condition_proxy_unchanged_case_count"] += 1)
                end
                push!(item["cases"], case_name)
                counts = item["stratum_case_counts"]
                counts[stratum] = get(counts, stratum, 0) + 1
            end
        end
    end
    result = collect(values(aggregate))
    for item in result
        ratios = item["condition_proxy_ratios"]
        item["minimum_condition_proxy_ratio"] =
            isempty(ratios) ? nothing : minimum(ratios)
        item["maximum_condition_proxy_ratio"] =
            isempty(ratios) ? nothing : maximum(ratios)
        delete!(item, "condition_proxy_ratios")
    end
    sort!(result; by = item -> (
        String(get(item, "point_policy", "")),
        String(get(item, "constraint_family", "")),
    ))
    return result
end

function _strata_summary(case_summaries)
    grouped = Dict{String,Vector{Dict{String,Any}}}()
    for case in case_summaries
        label = String(get(
            _dict(get(case, "stratum", nothing)), "label", "unclassified",
        ))
        push!(get!(grouped, label, Dict{String,Any}[]), case)
    end
    result = Dict{String,Any}()
    for (label, cases) in sort!(collect(grouped); by = first)
        invariant_changed_stages = 0
        local_changed_stages = 0
        for case in cases
            for comparison in values(_dict(get(case, "comparisons", nothing)))
                for stage in values(_dict(get(
                    comparison, "stage_comparisons", nothing,
                )))
                    get(stage, "identical", false) === true && continue
                    classification = String(get(stage, "classification", ""))
                    classification == "point_invariant" &&
                        (invariant_changed_stages += 1)
                    classification == "point_local" &&
                        (local_changed_stages += 1)
                end
            end
        end
        result[label] = Dict{String,Any}(
            "case_count" => length(cases),
            "observation_count" => sum(
                _int(get(case, "observation_count", 0)) for case in cases
            ),
            "registry_complete_case_count" => count(
                case -> get(case, "registry_complete", false) === true, cases,
            ),
            "trusted_saved_point_case_count" => count(
                case -> get(case, "trusted_saved_point_available", false) === true,
                cases,
            ),
            "point_invariant_changed_stage_count" => invariant_changed_stages,
            "point_local_changed_stage_count" => local_changed_stages,
            "model_variable_counts" => sort!(unique([
                _int(get(_dict(get(case, "stratum", nothing)),
                         "model_variable_count", 0)) for case in cases
            ])),
            "scalar_constraint_row_counts" => sort!(unique([
                _int(get(_dict(get(case, "stratum", nothing)),
                         "scalar_constraint_row_count", 0)) for case in cases
            ])),
            "jacobian_dense_entry_counts" => sort!(unique([
                _int(get(_dict(get(case, "stratum", nothing)),
                         "jacobian_dense_entry_count", 0)) for case in cases
            ])),
        )
    end
    return result
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
    same_point_metric_repeat_failures = 0
    same_point_row_family_scale_repeat_failures = 0
    same_point_row_family_scaling_experiment_repeat_failures = 0
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
                get(stage, "metrics_repeatable", false) === true ||
                    (same_point_metric_repeat_failures += 1)
            end
            _int(get(policy, "row_family_scale_available_replicate_count", 0)) >= 2 &&
                get(policy, "row_family_scale_repeatable", false) !== true &&
                (same_point_row_family_scale_repeat_failures += 1)
            _int(get(policy,
                     "row_family_scaling_experiment_available_replicate_count", 0)) >= 2 &&
                get(policy, "row_family_scaling_experiment_repeatable", false) !== true &&
                (same_point_row_family_scaling_experiment_repeat_failures += 1)
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
    cross_case_recurrence = _cross_case_change_recurrence(case_summaries)
    cross_case_metric_recurrence =
        _cross_case_metric_change_recurrence(case_summaries)
    cross_case_metric_persistence =
        _cross_case_metric_persistence(case_summaries)
    cross_case_row_family_scale_recurrence =
        _cross_case_row_family_scale_recurrence(case_summaries)
    cross_case_row_family_scale_direction_recurrence =
        _cross_case_row_family_scale_direction_recurrence(case_summaries)
    cross_case_row_family_scale_persistence =
        _cross_case_row_family_scale_persistence(case_summaries)
    cross_case_row_family_scaling_experiment_summary =
        _cross_case_row_family_scaling_experiment_summary(case_summaries)
    strata = _strata_summary(case_summaries)
    row_family_scale_missing_observation_count = count(
        observation -> isempty(_dict(get(
            observation, "row_family_scale_metrics", nothing,
        ))), observations,
    )
    family_scaling_experiments_requested = !isempty(strip(String(get(
        manifest, "family_scaling_experiments", "",
    ))))
    row_family_scaling_experiment_missing_observation_count =
        family_scaling_experiments_requested ? count(
            observation -> isempty(_dict(get(
                observation, "row_family_scaling_experiment_metrics", nothing,
            ))), observations,
        ) : 0
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
    same_point_metric_repeat_failures > 0 && push!(findings, _finding(
        "point_calibration_same_point_metric_drift", "warning",
        "Curated numerical calibration metrics changed across repeated runs at one exact point.",
        Dict("changed_stage_count" => same_point_metric_repeat_failures);
        suggested_action = "Inspect rank tolerances, ordering, and numerical-library variability before interpreting metric persistence.",
    ))
    row_family_scale_missing_observation_count > 0 && push!(findings, _finding(
        "point_calibration_row_family_scale_attribution_missing", "warning",
        "Some observations lack semantic Jacobian row-family scale attribution.",
        Dict("missing_observation_count" =>
                 row_family_scale_missing_observation_count,
             "observation_count" => length(observations));
        suggested_action = "Regenerate those profiles with the current corpus runner before attributing global scaling changes to equation families.",
    ))
    same_point_row_family_scale_repeat_failures > 0 && push!(findings, _finding(
        "point_calibration_same_point_row_family_scale_drift", "warning",
        "Semantic Jacobian row-family scale evidence changed across repeated evaluations of one exact point.",
        Dict("changed_policy_count" =>
                 same_point_row_family_scale_repeat_failures);
        suggested_action = "Resolve derivative or ordering nondeterminism before interpreting family-level scale changes.",
    ))
    row_family_scaling_experiment_missing_observation_count > 0 &&
        push!(findings, _finding(
            "point_calibration_row_family_scaling_experiment_missing", "warning",
            "A requested controlled row-family scaling experiment is missing from some observations.",
            Dict("missing_observation_count" =>
                     row_family_scaling_experiment_missing_observation_count,
                 "observation_count" => length(observations));
            suggested_action = "Regenerate the missing observations with the same explicit family list before comparing scaling interventions.",
        ))
    same_point_row_family_scaling_experiment_repeat_failures > 0 &&
        push!(findings, _finding(
            "point_calibration_same_point_row_family_scaling_experiment_drift",
            "warning",
            "A controlled row-family scaling experiment changed across repeated evaluations of one exact point.",
            Dict("changed_policy_count" =>
                     same_point_row_family_scaling_experiment_repeat_failures);
            suggested_action = "Resolve sparse-factorization or derivative nondeterminism before interpreting the intervention.",
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
        "report_version" => "bmopf-point-calibration-v2",
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
        "same_point_metric_repeat_failure_count" =>
            same_point_metric_repeat_failures,
        "same_point_row_family_scale_repeat_failure_count" =>
            same_point_row_family_scale_repeat_failures,
        "row_family_scale_missing_observation_count" =>
            row_family_scale_missing_observation_count,
        "family_scaling_experiments_requested" =>
            family_scaling_experiments_requested,
        "row_family_scaling_experiment_missing_observation_count" =>
            row_family_scaling_experiment_missing_observation_count,
        "same_point_row_family_scaling_experiment_repeat_failure_count" =>
            same_point_row_family_scaling_experiment_repeat_failures,
        "point_fingerprint_repeat_failure_count" => point_fingerprint_repeat_failures,
        "point_invariant_cross_point_change_count" => invariant_cross_point_changes,
        "point_local_cross_point_change_count" => local_cross_point_changes,
        "cases" => case_summaries,
        "strata" => strata,
        "cross_case_change_recurrence" => cross_case_recurrence,
        "cross_case_metric_change_recurrence" => cross_case_metric_recurrence,
        "cross_case_metric_persistence" => cross_case_metric_persistence,
        "cross_case_row_family_scale_recurrence" =>
            cross_case_row_family_scale_recurrence,
        "cross_case_row_family_scale_direction_recurrence" =>
            cross_case_row_family_scale_direction_recurrence,
        "cross_case_row_family_scale_persistence" =>
            cross_case_row_family_scale_persistence,
        "cross_case_row_family_scaling_experiment_summary" =>
            cross_case_row_family_scaling_experiment_summary,
        "run_failures" => run_failures,
        "readiness" => Dict(
            "child_process_health" => isempty(run_failures),
            "aligned_environment" => length(environments) <= 1,
            "complete_registry_coverage" => registry_complete,
            "repeated_observations" => repeated_available,
            "same_point_fingerprint_stability" =>
                point_fingerprint_repeat_failures == 0,
            "same_point_finding_stability" => same_point_repeat_failures == 0,
            "same_point_metric_stability" =>
                same_point_metric_repeat_failures == 0,
            "row_family_scale_attribution" =>
                row_family_scale_missing_observation_count == 0,
            "same_point_row_family_scale_stability" =>
                same_point_row_family_scale_repeat_failures == 0,
            "row_family_scaling_experiment_coverage" =>
                row_family_scaling_experiment_missing_observation_count == 0,
            "same_point_row_family_scaling_experiment_stability" =>
                same_point_row_family_scaling_experiment_repeat_failures == 0,
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
