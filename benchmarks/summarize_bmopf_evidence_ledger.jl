#!/usr/bin/env julia

"""Normalize BMOPF campaign findings into a source-aware evidence ledger.

The ledger is intentionally descriptive: it preserves every finding record,
its source report, confidence, and evidence while adding recurrence counts.
It never turns recurrence into a model-quality score.
"""

using JSON
using SHA

function _load(path)
    isfile(path) || error("missing evidence report: $path")
    value = JSON.parsefile(path)
    value isa AbstractDict || error("evidence report is not a JSON object: $path")
    value
end

function _dict(value)
    value isa AbstractDict || return Dict{String,Any}()
    Dict{String,Any}(string(k) => v for (k, v) in value)
end

function _count!(dict, key)
    key = String(key)
    dict[key] = get(dict, key, 0) + 1
end

function _bool(value)
    value === true && return true
    value === false && return false
    value isa AbstractString && return lowercase(strip(String(value))) in ("true", "1", "yes")
    return false
end

function _int(value, default = 0)
    value isa Integer && return Int(value)
    value isa Number && isfinite(Float64(value)) && return Int(value)
    try
        parse(Int, String(value))
    catch
        default
    end
end

function _string_list(value)
    value === nothing && return String[]
    value isa AbstractString && return filter(!isempty, strip.(split(value, ',')))
    value isa AbstractVector && return filter(!isempty, String[
        item isa AbstractString ? String(item) :
        item isa AbstractDict ? String(get(
            item, "name", get(item, "case", get(item, "snapshot", "")),
        )) :
        string(item) for item in value
    ])
    return [String(value)]
end

function _source_type(report)
    runner_version = String(get(report, "runner_version", ""))
    report_version = String(get(report, "report_version", ""))
    version = isempty(runner_version) ? report_version : runner_version
    startswith(version, "bmopf-perturbation-corpus-") && return "perturbation_corpus"
    startswith(version, "bmopf-campaign-validation-") && return "campaign_validation"
    occursin("solver-matrix", lowercase(version)) && return "solver_matrix"
    startswith(version, "bmopf-campaign-summary-") && return "campaign_summary"
    startswith(version, "bmopf-perturbation-repeats-") && return "perturbation_repeats"
    startswith(version, "bmopf-solver-repeats-") && return "solver_repeats"
    startswith(version, "bmopf-solver-trace-") && return "solver_trace"
    startswith(version, "bmopf-multiconductor-smoke-summary-") && return "multiconductor_smoke"
    startswith(version, "bmopf-multiconductor-probe-comparison-") && return "multiconductor_probe_comparison"
    startswith(version, "bmopf-multiconductor-point-comparison-") && return "multiconductor_point_comparison"
    startswith(version, "nlpdiagnostics-operator-fingerprint-summary-") && return "operator_fingerprint"
    startswith(version, "bmopf-controller-campaign-") && return "controller_campaign"
    startswith(version, "bmopf-saved-result-persistence-") && return "saved_result_persistence"
    startswith(version, "bmopf-persistence-summary-") && return "saved_result_persistence_summary"
    startswith(version, "bmopf-saved-result-profile-comparison-") && return "saved_result_profile_comparison"
    startswith(version, "bmopf-result-policy-matrix-summary-") && return "result_policy_matrix"
    startswith(version, "bmopf-solver-option-perturbation-") && return "solver_option_perturbation"
    startswith(version, "bmopf-point-calibration-") && return "point_calibration"
    startswith(version, "bmopf-evidence-ledger-comparison-") && return "evidence_ledger_comparison"
    startswith(version, "bmopf-evidence-ledger-") && return "evidence_ledger"
    return "unknown"
end

function _provenance(report)
    cases = _string_list(get(report, "cases", get(report, "case_summaries", Any[])))
    solvers = _string_list(get(report, "solvers", Any[]))
    families = _string_list(get(report, "family_perturbation_families", Any[]))
    evaluation_points = _string_list(get(report, "points", Any[]))
    configurations = String[]
    for configuration in get(report, "configurations", Any[])
        configuration isa AbstractDict || continue
        label = get(configuration, "label", nothing)
        label === nothing || push!(configurations, String(label))
        for case in get(configuration, "cases", Any[])
            case isa AbstractDict || continue
            name = get(case, "name", nothing)
            name === nothing || push!(cases, String(name))
        end
    end
    for comparison in get(report, "comparisons", Any[])
        comparison isa AbstractDict || continue
        name = get(comparison, "name", nothing)
        name === nothing || push!(cases, String(name))
    end
    by_family = _dict(get(report, "by_family", nothing))
    if isempty(cases) && !isempty(by_family)
        cases = unique(vcat([_string_list(get(_dict(value), "cases", Any[])) for value in values(by_family)]...))
    end
    if isempty(solvers) && !isempty(by_family)
        solvers = unique(vcat([_string_list(get(_dict(value), "solvers", Any[])) for value in values(by_family)]...))
    end
    isempty(families) && !isempty(by_family) && (families = String.(collect(keys(by_family))))
    environment_fingerprints = String[]
    value = get(report, "environment_fingerprint", nothing)
    value isa AbstractString && push!(environment_fingerprints, value)
    for fingerprint in get(report, "environment_fingerprints", Any[])
        fingerprint isa AbstractString && push!(environment_fingerprints, fingerprint)
    end
    for summary_raw in values(_dict(get(report, "solver_summaries", nothing)))
        summary = _dict(summary_raw)
        fingerprint = get(summary, "environment_fingerprint", nothing)
        fingerprint isa AbstractString && push!(environment_fingerprints, fingerprint)
    end
    return Dict{String,Any}(
        "cases" => sort!(unique(cases)), "solvers" => sort!(unique(solvers)),
        "families" => sort!(unique(families)),
        "evaluation_points" => sort!(unique(evaluation_points)),
        "configurations" => sort!(unique(configurations)),
        "environment_fingerprints" => sort!(unique(environment_fingerprints)),
        "readiness" => get(report, "readiness", nothing),
        "analysis_budget" => Dict(
            "rank_max_dense_entries" => get(report, "rank_max_dense_entries", nothing),
            "dense_rank_case_counts" => get(report, "dense_rank_case_counts", nothing),
            "replicate_count" => get(
                report, "replicate_count", get(report, "repetitions", nothing),
            ),
            "family_perturbation_max_iter" => get(report, "family_perturbation_max_iter", nothing),
            "child_timeout_seconds" => get(report, "child_timeout_seconds", nothing),
            "capture_logs" => get(report, "capture_logs", nothing),
            "capture_points" => get(report, "capture_points", nothing),
        ),
    )
end

function _source_metadata(report)
    aggregate = _dict(get(report, "aggregate", nothing))
    haskey(aggregate, "source_schema_warning_count") || return Dict{String,Any}()
    return Dict{String,Any}(
        "source_snapshot_case_count" => get(aggregate, "source_snapshot_case_count", 0),
        "source_schema_warning_count" => get(aggregate, "source_schema_warning_count", 0),
        "source_schema_warning_field_counts" => get(aggregate, "source_schema_warning_field_counts", Dict()),
        "source_schema_warning_scope_counts" => get(aggregate, "source_schema_warning_scope_counts", Dict()),
        "source_schema_warning_impact_counts" => get(aggregate, "source_schema_warning_impact_counts", Dict()),
        "source_schema_warning_policy_status_counts" => get(aggregate, "source_schema_warning_policy_status_counts", Dict()),
        "source_schema_field_policies" => get(aggregate, "source_schema_field_policies", Dict()),
        "source_schema_warning_fixture_counts" => get(aggregate, "source_schema_warning_fixture_counts", Dict()),
        "source_schema_warning_message_counts" => get(aggregate, "source_schema_warning_message_counts", Dict()),
        "physical_metadata_warning_count" => get(aggregate, "physical_metadata_warning_count", 0),
    )
end

"""Convert nested JSON-compatible values to a deterministic representation."""
function _canonical(value)
    value isa AbstractDict && return Dict(
        String(key) => _canonical(value[key]) for key in sort!(collect(keys(value)); by = string)
    )
    value isa AbstractVector && return [_canonical(item) for item in value]
    return value
end

function _campaign_provenance(source_types)
    cases = String[]
    solvers = String[]
    families = String[]
    evaluation_points = String[]
    configurations = String[]
    environments = String[]
    budgets = Any[]
    for source in source_types
        provenance = _dict(get(source, "provenance", nothing))
        append!(cases, _string_list(get(provenance, "cases", Any[])))
        append!(solvers, _string_list(get(provenance, "solvers", Any[])))
        append!(families, _string_list(get(provenance, "families", Any[])))
        append!(evaluation_points, _string_list(get(
            provenance, "evaluation_points", Any[],
        )))
        append!(configurations, _string_list(get(
            provenance, "configurations", Any[],
        )))
        append!(environments, _string_list(get(provenance, "environment_fingerprints", Any[])))
        budget = get(provenance, "analysis_budget", nothing)
        budget isa AbstractDict && push!(budgets, _canonical(budget))
    end
    unique_budgets = unique(JSON.json.(budgets))
    canonical = Dict{String,Any}(
        "cases" => sort!(unique(cases)),
        "solvers" => sort!(unique(solvers)),
        "families" => sort!(unique(families)),
        "evaluation_points" => sort!(unique(evaluation_points)),
        "configurations" => sort!(unique(configurations)),
        "environment_fingerprints" => sort!(unique(environments)),
        "analysis_budgets" => sort!(unique_budgets),
    )
    fingerprint = bytes2hex(SHA.sha256(codeunits(JSON.json(_canonical(canonical)))))
    canonical["campaign_fingerprint"] = fingerprint
    return canonical
end

function _append_findings!(records, report, path, scope, findings)
    findings isa AbstractVector || return
    source_type = _source_type(report)
    for finding_raw in findings
        finding = _dict(finding_raw)
        code = String(get(finding, "code", "unknown"))
        evidence = get(finding, "evidence", Dict())
        evidence_dict = _dict(evidence)
        identity_hint = get(evidence_dict, "family", get(evidence_dict, "case_family", nothing))
        identity = isnothing(identity_hint) ? code : "$code|$(String(identity_hint))"
        push!(records, Dict{String,Any}(
            "identity" => identity,
            "code" => code,
            "record_kind" => "finding",
            "source_path" => path,
            "source_type" => source_type,
            "scope" => scope,
            "severity" => get(finding, "severity", "unknown"),
            "confidence" => get(finding, "confidence", "unknown"),
            "basis" => get(finding, "basis", nothing),
            "domain" => get(finding, "domain", nothing),
            "category" => get(finding, "category", nothing),
            "observation" => get(finding, "observation", nothing),
            "evidence" => evidence,
            "suggested_action" => get(finding, "suggested_action", nothing),
        ))
    end
end

function _append_evidence_record!(records, report, path, identity, code, scope;
                                  observation, evidence, confidence = "numerical",
                                  domain = "numerical")
    push!(records, Dict{String,Any}(
        "identity" => identity,
        "code" => code,
        "record_kind" => "evidence",
        "source_path" => path,
        "source_type" => _source_type(report),
        "scope" => scope,
        "severity" => "info",
        "confidence" => confidence,
        "basis" => "repeated_campaign_evidence",
        "domain" => domain,
        "category" => "recurrence",
        "observation" => observation,
        "evidence" => evidence,
        "suggested_action" => nothing,
    ))
end

function _append_solver_repeat_evidence!(records, report, path)
    for raw_configuration in get(report, "configurations", Any[])
        configuration = _dict(raw_configuration)
        label = String(get(configuration, "label", "unknown"))
        for raw_case in get(configuration, "cases", Any[])
            case = _dict(raw_case)
            recurrence = _dict(get(case, "recurrence", nothing))
            available = get(recurrence, "row_family_scale_available", false) === true
            stable = get(recurrence, "row_family_scale_ratio_stable", false) === true
            available && stable || continue
            name = String(get(case, "name", "unknown"))
            _append_evidence_record!(records, report, path,
                "solver_repeat_row_family_scale_recurrence|$label|$name",
                "solver_repeat_row_family_scale_recurrence",
                "configuration_recurrence";
                observation = "Row-family derivative-scale attribution recurred across repeats.",
                evidence = Dict("configuration" => label, "case" => name,
                    "recurrence" => recurrence))
        end
    end
    for raw_comparison in get(report, "comparisons", Any[])
        comparison = _dict(raw_comparison)
        label = String(get(comparison, "candidate_label", "unknown"))
        summary = _dict(get(comparison, "summary", nothing))
        row_range = _dict(get(summary, "row_family_scale_ratio_delta_range", nothing))
        available = get(row_range, "available", false) === true
        stable = get(summary, "row_family_scale_ratio_delta_stable", false) === true
        available && stable || continue
        _append_evidence_record!(records, report, path,
            "solver_repeat_row_family_delta_recurrence|$label",
            "solver_repeat_row_family_delta_recurrence",
            "paired_policy_recurrence";
            observation = "The paired row-family scale delta recurred case-by-case across repeats.",
            evidence = Dict("candidate" => label, "summary" => summary))
    end
end

function _append_dense_rank_evidence!(records, report, path)
    source_type = _source_type(report)
    source_type == "solver_trace" || return
    for raw_case in get(report, "cases", Any[])
        case = _dict(raw_case)
        numerical = _dict(get(case, "numerical_profile", nothing))
        metadata = _dict(get(numerical, "metadata", nothing))
        dense = _bool(get(metadata, "jacobian_rank_available", false))
        sparse = _bool(get(metadata, "sparse_qr_rank_available", false))
        agree = _bool(get(metadata, "dense_sparse_qr_unscaled_rank_agree", false))
        dense && sparse && agree || continue
        name = String(get(case, "name", "unknown"))
        _append_evidence_record!(records, report, path,
            "dense_sparse_rank_agreement|$name",
            "dense_sparse_rank_agreement", "dense_checkpoint";
            observation = "Dense and sparse unscaled QR rank agree for this checkpoint.",
            evidence = Dict("case" => name,
                "dense_rank" => get(metadata, "jacobian_rank", nothing),
                "sparse_rank" => get(metadata, "sparse_qr_rank", nothing),
                "rank_max_dense_entries" => get(metadata, "rank_max_dense_entries", nothing)))
    end
end

function _append_solver_option_evidence!(records, report, path)
    _source_type(report) == "solver_option_perturbation" || return
    readiness = _dict(get(report, "readiness", nothing))
    get(readiness, "all_matrix_files_present", false) === true || return
    get(readiness, "baseline_comparisons_available", false) === true || return
    comparisons = [_dict(item) for item in get(report, "comparisons_vs_baseline", Any[])]
    isempty(comparisons) && return
    report_version = String(get(report, "report_version", "unknown"))
    schema_ready = (startswith(report_version, "bmopf-solver-option-perturbation-v3") ||
        startswith(report_version, "bmopf-solver-option-perturbation-v4")) &&
        get(readiness, "distinct_option_sets_declared", false) === true
    if !schema_ready
        _append_evidence_record!(records, report, path,
            "solver_option_legacy_smoke_observation|$(length(comparisons))",
            "solver_option_legacy_smoke_observation", "option_perturbation_smoke";
            confidence = "heuristic",
            observation = "The option campaign predates the distinct-intervention and post-first-trajectory trust gates; it is retained as pipeline smoke evidence only.",
            evidence = Dict(
                "comparison_count" => length(comparisons),
                "report_version" => report_version,
                "readiness" => readiness,
            ))
        return
    end
    coverage_ready = get(readiness, "all_manifest_entries_completed", false) === true &&
        get(readiness, "manifest_entry_count_complete", false) === true &&
        get(readiness, "all_nonbaseline_observations_compared", false) === true &&
        get(readiness, "all_row_family_residual_traces_available", false) === true &&
        get(readiness, "all_row_family_trajectories_nonempty", false) === true &&
        get(readiness, "trajectory_comparisons_available", false) === true
    if !coverage_ready
        _append_evidence_record!(records, report, path,
            "solver_option_incomplete_trajectory_observation|$(length(comparisons))",
            "solver_option_incomplete_trajectory_observation",
            "option_perturbation_coverage";
            confidence = "numerical",
            observation = "The corrected option campaign has incomplete trajectory coverage and cannot support a stability conclusion.",
            evidence = Dict(
                "comparison_count" => length(comparisons),
                "report_version" => report_version,
                "readiness" => readiness,
            ))
        return
    end
    multiconductor_scope = get(report, "campaign_scope", "generic") == "multiconductor"
    semantic_ready = get(readiness, "model_semantic_contracts_available", false) === true &&
        get(readiness, "model_semantic_invariance", false) === true
    if multiconductor_scope && !semantic_ready
        _append_evidence_record!(records, report, path,
            "solver_option_multiconductor_semantic_gate_failed|$(length(comparisons))",
            "solver_option_multiconductor_semantic_gate_failed",
            "option_perturbation_semantic_control";
            confidence = "structural",
            domain = "representational",
            observation = "The multiconductor option campaign did not preserve a complete, invariant model-semantic contract across paired cells, so solver-response stability is not promoted.",
            evidence = Dict(
                "comparison_count" => length(comparisons),
                "readiness" => readiness,
            ))
        return
    end
    if multiconductor_scope
        _append_evidence_record!(records, report, path,
            "solver_option_multiconductor_semantic_invariance|$(length(comparisons))",
            "solver_option_multiconductor_semantic_invariance",
            "option_perturbation_semantic_control";
            confidence = "structural",
            domain = "representational",
            observation = "Model size, structural BMOPF context metadata, and source behavior contracts were invariant across every paired multiconductor option cell.",
            evidence = Dict(
                "comparison_count" => length(comparisons),
                "readiness" => readiness,
            ))
    end
    residual_changes = count(item ->
        get(item, "row_family_trajectory_changed", false) === true, comparisons)
    global_peak_changes = count(item ->
        get(item, "row_family_global_peak_changed", false) === true, comparisons)
    first_captured_changes = count(item ->
        get(item, "row_family_first_captured_changed", false) === true, comparisons)
    restoration_changes = count(item -> get(item, "restoration_signature_changed", false) === true, comparisons)
    classification_changes = count(item -> get(item, "classification_changed", false) === true, comparisons)
    context_finding_changes = count(item ->
        get(item, "bmopf_context_finding_codes_changed", false) === true,
        comparisons,
    )
    code = residual_changes == 0 ?
        "solver_option_row_family_trajectory_stability" :
        "solver_option_row_family_trajectory_changes"
    _append_evidence_record!(records, report, path,
        "$code|$(length(comparisons))", code, "option_perturbation_comparison";
        confidence = "numerical",
        observation = residual_changes == 0 ?
            "Named row-family post-first trajectories remained materially stable under the distinct bounded solver-option perturbations." :
            "At least one named row-family post-first trajectory changed materially under the distinct bounded solver-option perturbations.",
        evidence = Dict("comparison_count" => length(comparisons),
            "trajectory_change_count" => residual_changes,
            "global_peak_change_count" => global_peak_changes,
            "first_captured_change_count" => first_captured_changes,
            "restoration_signature_change_count" => restoration_changes,
            "classification_change_count" => classification_changes,
            "bmopf_context_finding_code_change_count" => context_finding_changes,
            "residual_comparison_tolerance" => get(report,
                "residual_comparison_tolerance", nothing),
            "experimental_design" => get(report, "experimental_design", nothing),
            "readiness" => readiness))
    classification_changes > 0 && _append_evidence_record!(records, report, path,
        "solver_option_classification_sensitivity|$classification_changes",
        "solver_option_classification_sensitivity", "option_perturbation_comparison";
        confidence = "local",
        observation = "A bounded solver-option perturbation changed at least one endpoint classification while the formulation and initialization policy were held fixed.",
        evidence = Dict("comparison_count" => length(comparisons),
            "classification_change_count" => classification_changes,
            "restoration_signature_change_count" => restoration_changes,
            "trajectory_change_count" => residual_changes,
            "global_peak_change_count" => global_peak_changes,
            "first_captured_change_count" => first_captured_changes))
    context_finding_changes > 0 && _append_evidence_record!(records, report, path,
        "solver_option_bmopf_context_sensitivity|$context_finding_changes",
        "solver_option_bmopf_context_sensitivity",
        "option_perturbation_context_comparison";
        confidence = "local",
        domain = "physical_interpretation_boundary",
        observation = "At least one bounded solver-option perturbation changed the BMOPF context finding-code distribution at its selected endpoint.",
        evidence = Dict(
            "comparison_count" => length(comparisons),
            "context_finding_code_change_count" => context_finding_changes,
            "model_semantic_contract_change_count" => count(item ->
                get(item, "model_semantic_contract_changed", false) === true,
                comparisons,
            ),
        ))
    pairwise = [_dict(item) for item in get(
        report, "comparisons_between_perturbations", Any[],
    )]
    get(readiness, "between_perturbation_comparisons_available", false) === true || return
    isempty(pairwise) && return
    pair_trajectory_changes = count(item ->
        get(item, "row_family_trajectory_changed", false) === true, pairwise)
    pair_classification_changes = count(item ->
        get(item, "classification_changed", false) === true, pairwise)
    pair_trace_length_changes = count(item -> begin
        delta = get(item, "trace_record_count_delta", nothing)
        delta isa Number && delta != 0
    end, pairwise)
    pair_code = pair_trajectory_changes == 0 && pair_classification_changes == 0 &&
        pair_trace_length_changes == 0 ?
        "solver_option_perturbation_pair_stability" :
        "solver_option_perturbation_pair_sensitivity"
    _append_evidence_record!(records, report, path,
        "$pair_code|$(length(pairwise))", pair_code,
        "between_perturbation_comparison";
        confidence = "numerical",
        observation = pair_code == "solver_option_perturbation_pair_stability" ?
            "The non-baseline option profiles produced no material measured differences in the bounded paired campaign." :
            "The non-baseline option profiles differed on at least one measured bounded-campaign outcome.",
        evidence = Dict(
            "comparison_count" => length(pairwise),
            "trajectory_change_count" => pair_trajectory_changes,
            "classification_change_count" => pair_classification_changes,
            "trace_length_change_count" => pair_trace_length_changes,
            "profile_pairs" => sort!(unique([
                "$(get(item, "reference_profile", "unknown"))=>$(get(item, "candidate_profile", "unknown"))"
                for item in pairwise
            ])),
        ))
end

function _append_multiconductor_point_evidence!(records, report, path)
    _source_type(report) == "multiconductor_point_comparison" || return
    readiness = _dict(get(report, "readiness", nothing))
    get(readiness, "comparison_available", false) === true || return
    comparisons = get(report, "comparisons", Any[])
    isempty(comparisons) && return
    contract_changes = count(item -> get(_dict(item), "contract_changed", false), comparisons)
    mode_changes = count(item -> get(_dict(item), "mode_status_changed", false), comparisons)
    probe_changes = count(item -> get(_dict(item), "probe_convergence_changed", false), comparisons)
    code = contract_changes == 0 && mode_changes == 0 && probe_changes == 0 ?
        "multiconductor_point_policy_contract_stability" :
        "multiconductor_point_policy_local_changes"
    _append_evidence_record!(records, report, path,
        "$code|$(get(report, "baseline_point_policy", "unknown"))|$(get(report, "candidate_point_policy", "unknown"))",
        code, "point_policy_comparison";
        observation = code == "multiconductor_point_policy_contract_stability" ?
            "Port contracts, physical-mode statuses, and probe convergence were unchanged across the paired point policies." :
            "At least one port, mode, or probe observation changed across the paired point policies.",
        evidence = Dict("readiness" => readiness, "contract_change_count" => contract_changes,
            "mode_status_change_count" => mode_changes, "probe_convergence_change_count" => probe_changes))
    projection_pairs = count(item -> begin
        row = _dict(item)
        _int(get(_dict(get(row, "baseline_mode_projections", nothing)), "mode_count", 0)) > 0 &&
        _int(get(_dict(get(row, "candidate_mode_projections", nothing)), "mode_count", 0)) > 0
    end, comparisons)
    projection_changes = count(item -> get(_dict(item), "mode_projection_status_changed", false), comparisons)
    projection_pairs > 0 && _append_evidence_record!(records, report, path,
        "multiconductor_point_mode_projection_visibility|$(get(report, "baseline_point_policy", "unknown"))|$(get(report, "candidate_point_policy", "unknown"))",
        "multiconductor_point_mode_projection_visibility", "mode_coordinate_projection";
        confidence = "structural",
        domain = "physical_interpretation_boundary",
        observation = "Per-component physical-mode projections were available for the paired point comparison.",
        evidence = Dict("projection_pair_count" => projection_pairs,
            "projection_status_change_count" => projection_changes))
    match_pairs = count(item -> begin
        row = _dict(item)
        _int(get(_dict(get(row, "baseline_mode_matches", nothing)), "mode_count", 0)) > 0 &&
        _int(get(_dict(get(row, "candidate_mode_matches", nothing)), "mode_count", 0)) > 0
    end, comparisons)
    match_changes = count(item -> get(_dict(item), "mode_match_status_changed", false), comparisons)
    projected_observed = sum(
        _int(get(_dict(get(_dict(item), "baseline_mode_matches", nothing)),
                "projected_observed_count", 0)) +
        _int(get(_dict(get(_dict(item), "candidate_mode_matches", nothing)),
                "projected_observed_count", 0))
        for item in comparisons
    )
    projected_not_observed = sum(
        _int(get(_dict(get(_dict(item), "baseline_mode_matches", nothing)),
                "projected_not_observed_count", 0)) +
        _int(get(_dict(get(_dict(item), "candidate_mode_matches", nothing)),
                "projected_not_observed_count", 0))
        for item in comparisons
    )
    tangent_observed = sum(
        _int(get(_dict(get(_dict(item), "baseline_mode_matches", nothing)),
                "tangent_observed_count", 0)) +
        _int(get(_dict(get(_dict(item), "candidate_mode_matches", nothing)),
                "tangent_observed_count", 0))
        for item in comparisons
    )
    tangent_not_observed = sum(
        _int(get(_dict(get(_dict(item), "baseline_mode_matches", nothing)),
                "tangent_not_observed_count", 0)) +
        _int(get(_dict(get(_dict(item), "candidate_mode_matches", nothing)),
                "tangent_not_observed_count", 0))
        for item in comparisons
    )
    match_pairs > 0 && _append_evidence_record!(records, report, path,
        "multiconductor_point_mode_jacobian_match|$(get(report, "baseline_point_policy", "unknown"))|$(get(report, "candidate_point_policy", "unknown"))",
        "multiconductor_point_mode_jacobian_match", "mode_jacobian_comparison";
        confidence = "local",
        domain = "physical_interpretation_boundary",
        observation = "Visible component-mode candidates were compared with local observed-Jacobian nullspace evidence.",
        evidence = Dict("match_pair_count" => match_pairs,
            "match_status_change_count" => match_changes,
            "projected_observed_count_across_points" => projected_observed,
            "projected_not_observed_count_across_points" => projected_not_observed,
            "baseline_projection_policy" => get(readiness,
                "baseline_mode_projection_policy", "unknown"),
            "candidate_projection_policy" => get(readiness,
                "candidate_mode_projection_policy", "unknown"),
            "tangent_observed_count_across_points" => tangent_observed,
            "tangent_not_observed_count_across_points" => tangent_not_observed,
            "baseline_tangent_policy" => get(readiness,
                "baseline_mode_tangent_policy", "unknown"),
            "candidate_tangent_policy" => get(readiness,
                "candidate_mode_tangent_policy", "unknown")))
    voltage_alignment_changes = count(item -> get(_dict(item), "voltage_alignment_changed", false), comparisons)
    current_alignment_changes = count(item -> get(_dict(item), "current_alignment_changed", false), comparisons)
    voltage_alignment_missing = sum(
        _int(get(_dict(get(_dict(item), "baseline_voltage_alignment", nothing)), "missing_map_count", 0))
        for item in comparisons
    )
    current_alignment_missing = sum(
        _int(get(_dict(get(_dict(item), "baseline_current_alignment", nothing)), "missing_map_count", 0))
        for item in comparisons
    )
    (voltage_alignment_changes > 0 || current_alignment_changes > 0 ||
     voltage_alignment_missing > 0 || current_alignment_missing > 0) &&
        _append_evidence_record!(records, report, path,
            "multiconductor_point_port_alignment_coverage|$(get(report, "baseline_point_policy", "unknown"))|$(get(report, "candidate_point_policy", "unknown"))",
            "multiconductor_point_port_alignment_coverage", "coordinate_alignment_gate";
            confidence = "structural",
            domain = "physical_interpretation_boundary",
            observation = "Point-policy comparison exposed a change or gap in terminal-to-model coordinate-map coverage.",
            evidence = Dict("voltage_alignment_change_count" => voltage_alignment_changes,
                "current_alignment_change_count" => current_alignment_changes,
                "baseline_voltage_missing_map_count" => voltage_alignment_missing,
                "baseline_current_missing_map_count" => current_alignment_missing))
    _bool(get(readiness, "port_map_alignment_pair_complete", false)) ||
        _append_evidence_record!(records, report, path,
            "multiconductor_point_port_map_alignment_incomplete|$(get(report, "baseline_point_policy", "unknown"))|$(get(report, "candidate_point_policy", "unknown"))",
            "multiconductor_point_port_map_alignment_incomplete", "coordinate_alignment_gate";
            confidence = "structural",
            domain = "physical_interpretation_boundary",
            observation = "The paired point comparison lacks complete terminal-port coordinate-map coverage.",
            evidence = Dict("readiness" => readiness))
    dense_pairs = _int(get(readiness, "dense_rank_pair_available", 0))
    dense_pairs > 0 || return
    dense_changes = _int(get(readiness, "dense_rank_change_count", 0))
    _append_evidence_record!(records, report, path,
        "multiconductor_point_dense_rank_checkpoint|$(get(report, "baseline_point_policy", "unknown"))|$(get(report, "candidate_point_policy", "unknown"))",
        "multiconductor_point_dense_rank_checkpoint", "dense_point_checkpoint";
        observation = dense_changes == 0 ?
            "Dense rank evidence was available at both point policies with no paired rank changes." :
            "Dense rank evidence was available at both point policies and changed for at least one paired fixture.",
        evidence = Dict("readiness" => readiness, "dense_rank_pair_available" => dense_pairs,
            "dense_rank_change_count" => dense_changes))
    ambiguous = _int(get(readiness, "ambiguous_rank_change_count", 0))
    ambiguous > 0 || return
    _append_evidence_record!(records, report, path,
        "multiconductor_point_rank_alignment_boundary|$(get(report, "baseline_point_policy", "unknown"))|$(get(report, "candidate_point_policy", "unknown"))",
        "multiconductor_point_rank_alignment_boundary", "coordinate_alignment_gate";
        confidence = "local",
        domain = "physical_interpretation_boundary",
        observation = "Point-local dense-rank changes are present, but the paired physical-mode declarations are not coordinate-aligned.",
        evidence = Dict("readiness" => readiness,
            "ambiguous_rank_change_count" => ambiguous))
end

function _extract_records(report, path)
    records = Dict{String,Any}[]
    _append_findings!(records, report, path, "top_level", get(report, "findings", Any[]))
    corpus = get(report, "perturbation_corpus", nothing)
    corpus isa AbstractDict && _append_findings!(records, corpus, path, "perturbation_corpus", get(corpus, "findings", Any[]))
    for (index, item_raw) in enumerate(get(report, "campaign_reports", Any[]))
        item = _dict(item_raw)
        _append_findings!(records, report, path, "campaign_report_$index", get(item, "findings", Any[]))
        structured = get(item, "structured_findings", Any[])
        _append_findings!(records, report, path, "campaign_report_$(index)_structured", structured)
    end
    for (index, item_raw) in enumerate(get(report, "perturbation_repeat_reports", Any[]))
        item = _dict(item_raw)
        _append_findings!(records, report, path, "repeat_report_$index", get(item, "findings", Any[]))
        _append_findings!(records, report, path, "repeat_report_$(index)_structured", get(item, "structured_findings", Any[]))
    end
    for (index, item_raw) in enumerate(get(report, "controller_reports", Any[]))
        item = _dict(item_raw)
        _append_findings!(records, report, path, "controller_report_$index", get(item, "findings", Any[]))
        for (nested_index, nested_raw) in enumerate(get(item, "reports", Any[]))
            nested = _dict(nested_raw)
            _append_findings!(records, report, path,
                "controller_report_$(index)_nested_$nested_index", get(nested, "findings", Any[]))
        end
    end
    for (index, item_raw) in enumerate(get(report, "solver_trace_reports", Any[]))
        item = _dict(item_raw)
        _append_findings!(records, report, path, "solver_trace_report_$index", get(item, "findings", Any[]))
    end
    if _source_type(report) == "solver_repeats"
        _append_solver_repeat_evidence!(records, report, path)
    end
    _append_dense_rank_evidence!(records, report, path)
    _append_solver_option_evidence!(records, report, path)
    _append_multiconductor_point_evidence!(records, report, path)
    for (index, item_raw) in enumerate(get(report, "trace_comparison_reports", Any[]))
        item = _dict(item_raw)
        _append_findings!(records, report, path, "trace_comparison_report_$index", get(item, "findings", Any[]))
    end
    for (index, item_raw) in enumerate(get(report, "policy_matrix_reports", Any[]))
        item = _dict(item_raw)
        _append_findings!(records, report, path, "policy_matrix_report_$index", get(item, "findings", Any[]))
    end
    # Validation currently stores policy-matrix validation alongside comparison
    # reports; retain the scope explicitly when the source report is a policy
    # matrix so its findings remain distinguishable in the ledger.
    if startswith(String(get(report, "report_version", "")), "bmopf-result-policy-matrix-summary-")
        _append_findings!(records, report, path, "policy_matrix_summary", get(report, "findings", Any[]))
    end
    return records
end

function main()
    length(ARGS) >= 1 || error(
        "usage: summarize_bmopf_evidence_ledger.jl report.json ... [ledger.json]",
    )
    paths = abspath.(ARGS)
    output_path = nothing
    if length(paths) >= 3
        output_path = pop!(paths)
    elseif length(paths) >= 2 && endswith(last(paths), ".json")
        candidate = last(paths)
        is_output = !isfile(candidate)
        if !is_output
            try
                is_output = !haskey(_load(candidate), "runner_version")
            catch
                is_output = true
            end
        end
        is_output && (output_path = pop!(paths))
    end
    isempty(paths) && error("at least one report is required")
    output_path = something(output_path,
        joinpath(dirname(first(paths)), "bmopf_evidence_ledger.json"))
    records = Dict{String,Any}[]
    source_types = Dict{String,Any}[]
    for path in paths
        report = _load(path)
        push!(source_types, Dict("path" => path, "type" => _source_type(report),
                                "runner_version" => get(report, "runner_version", nothing),
                                "provenance" => _provenance(report),
                                "metadata" => _source_metadata(report)))
        append!(records, _extract_records(report, path))
    end
    by_identity = Dict{String,Any}()
    for record in records
        identity = String(record["identity"])
        aggregate = get!(by_identity, identity, Dict{String,Any}(
            "identity" => identity, "code" => record["code"],
            "count" => 0, "source_count" => 0, "source_paths" => String[],
            "source_types" => String[], "severity_counts" => Dict{String,Int}(),
            "confidence_counts" => Dict{String,Int}(),
            "basis_counts" => Dict{String,Int}(),
            "domain_counts" => Dict{String,Int}(), "records" => Any[],
        ))
        aggregate["count"] += 1
        path = String(record["source_path"])
        path in aggregate["source_paths"] || begin
            push!(aggregate["source_paths"], path)
            aggregate["source_count"] += 1
        end
        source_type = String(record["source_type"])
        source_type in aggregate["source_types"] || push!(aggregate["source_types"], source_type)
        _count!(aggregate["severity_counts"], record["severity"])
        _count!(aggregate["confidence_counts"], record["confidence"])
        isnothing(record["basis"]) || _count!(aggregate["basis_counts"], record["basis"])
        isnothing(record["domain"]) || _count!(aggregate["domain_counts"], record["domain"])
        push!(aggregate["records"], record)
    end
    for aggregate in values(by_identity)
        aggregate["recurs_across_sources"] = aggregate["source_count"] >= 2
    end
    campaign_provenance = _campaign_provenance(source_types)
    write(output_path, JSON.json(Dict(
        "runner_version" => "bmopf-evidence-ledger-v2",
        "source_reports" => source_types,
        "campaign_provenance" => campaign_provenance,
        "source_count" => length(source_types),
        "finding_count" => length(records),
        "identity_count" => length(by_identity),
        "recurring_identity_count" => count(value -> get(value, "recurs_across_sources", false), values(by_identity)),
        "by_identity" => by_identity,
        "records" => records,
        "interpretation" => "Source-aware finding ledger. Recurrence is descriptive evidence and is not a model-quality score or causal proof.",
    )))
    println("wrote BMOPF evidence ledger to $output_path")
end

if abspath(PROGRAM_FILE) == abspath(@__FILE__)
    main()
end
