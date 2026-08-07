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
    startswith(version, "bmopf-solver-trace-") && return "solver_trace"
    startswith(version, "bmopf-multiconductor-smoke-summary-") && return "multiconductor_smoke"
    startswith(version, "bmopf-multiconductor-probe-comparison-") && return "multiconductor_probe_comparison"
    startswith(version, "nlpdiagnostics-operator-fingerprint-summary-") && return "operator_fingerprint"
    startswith(version, "bmopf-controller-campaign-") && return "controller_campaign"
    startswith(version, "bmopf-saved-result-persistence-") && return "saved_result_persistence"
    startswith(version, "bmopf-persistence-summary-") && return "saved_result_persistence_summary"
    startswith(version, "bmopf-saved-result-profile-comparison-") && return "saved_result_profile_comparison"
    startswith(version, "bmopf-result-policy-matrix-summary-") && return "result_policy_matrix"
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

main()
