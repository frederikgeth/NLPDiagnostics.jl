#!/usr/bin/env julia

"""Compare two source-aware BMOPF evidence ledgers.

The comparison reports finding identities that are new, resolved, persistent,
or changed in severity/confidence. It intentionally does not rank campaigns.
"""

using JSON

function _load(path)
    isfile(path) || error("missing evidence ledger: $path")
    value = JSON.parsefile(path)
    value isa AbstractDict || error("ledger is not a JSON object: $path")
    value
end

function _dict(value)
    value isa AbstractDict || return Dict{String,Any}()
    Dict{String,Any}(string(k) => v for (k, v) in value)
end

function _finding(code, severity, observation, evidence, suggested_action)
    Dict{String,Any}(
        "code" => code, "severity" => severity,
        "confidence" => "comparative", "category" => "evidence_regression",
        "observation" => observation, "evidence" => evidence,
        "suggested_action" => suggested_action,
    )
end

function _same(a, b)
    a == b
end

function _provenance_sets(ledger, field)
    campaign = _dict(get(ledger, "campaign_provenance", nothing))
    if haskey(campaign, field)
        return sort!(unique(String.(campaign[field])))
    end
    values = String[]
    for source_raw in get(ledger, "source_reports", Any[])
        source = _dict(source_raw)
        provenance = _dict(get(source, "provenance", nothing))
        for value in get(provenance, field, Any[])
            push!(values, String(value))
        end
    end
    sort!(unique(values))
end

function _provenance_budgets(ledger)
    campaign = _dict(get(ledger, "campaign_provenance", nothing))
    if haskey(campaign, "analysis_budgets")
        return sort!(unique(String.(campaign["analysis_budgets"])))
    end
    values = String[]
    for source_raw in get(ledger, "source_reports", Any[])
        source = _dict(source_raw)
        provenance = _dict(get(source, "provenance", nothing))
        budget = get(provenance, "analysis_budget", nothing)
        budget isa AbstractDict && push!(values, JSON.json(budget))
    end
    sort!(unique(values))
end

function _compatibility(baseline, current)
    mismatches = Dict{String,Any}()
    unknown = String[]
    for field in ("cases", "solvers", "families")
        left = _provenance_sets(baseline, field)
        right = _provenance_sets(current, field)
        if isempty(left) || isempty(right)
            push!(unknown, field)
        elseif left != right
            mismatches[field] = Dict("baseline" => left, "current" => right)
        end
    end
    left_env = _provenance_sets(baseline, "environment_fingerprints")
    right_env = _provenance_sets(current, "environment_fingerprints")
    if isempty(left_env) || isempty(right_env)
        push!(unknown, "environment_fingerprints")
    elseif left_env != right_env
        mismatches["environment_fingerprints"] = Dict("baseline" => left_env, "current" => right_env)
    end
    left_budget = _provenance_budgets(baseline)
    right_budget = _provenance_budgets(current)
    if isempty(left_budget) || isempty(right_budget)
        push!(unknown, "analysis_budgets")
    elseif left_budget != right_budget
        mismatches["analysis_budgets"] = Dict("baseline" => left_budget, "current" => right_budget)
    end
    left_fingerprint = get(_dict(get(baseline, "campaign_provenance", nothing)), "campaign_fingerprint", nothing)
    right_fingerprint = get(_dict(get(current, "campaign_provenance", nothing)), "campaign_fingerprint", nothing)
    if !(left_fingerprint isa AbstractString && right_fingerprint isa AbstractString)
        push!(unknown, "campaign_fingerprint")
    elseif left_fingerprint != right_fingerprint && isempty(mismatches)
        # Keep this explicit even when future provenance fields are added but
        # are not yet represented by a named compatibility check.
        mismatches["campaign_fingerprint"] = Dict("baseline" => left_fingerprint, "current" => right_fingerprint)
    end
    status = !isempty(mismatches) ? "incompatible" : !isempty(unknown) ? "unknown" : "compatible"
    return Dict{String,Any}(
        "status" => status, "mismatches" => mismatches,
        "unknown_fields" => unknown,
        "interpretation" => "Compatibility gates indicate whether finding transitions are comparable; they do not establish causality.",
    )
end

function main()
    length(ARGS) in (2, 3) || error(
        "usage: compare_bmopf_evidence_ledgers.jl <baseline-ledger.json> <current-ledger.json> [comparison.json]",
    )
    baseline_path, current_path = abspath.(ARGS[1:2])
    baseline = _load(baseline_path)
    current = _load(current_path)
    compatibility = _compatibility(baseline, current)
    left = _dict(get(baseline, "by_identity", nothing))
    right = _dict(get(current, "by_identity", nothing))
    identities = sort!(collect(union(keys(left), keys(right))))
    changes = Dict{String,Any}[]
    findings = Any[]
    if compatibility["status"] == "incompatible"
        push!(findings, _finding(
            "evidence_campaign_incompatible", "warning",
            "The ledgers were produced from different case, solver, family, environment, or analysis-budget selections.",
            compatibility,
            "Treat new/resolved identities as campaign-composition changes until comparable selections are restored.",
        ))
    elseif compatibility["status"] == "unknown"
        push!(findings, _finding(
            "evidence_campaign_compatibility_unknown", "info",
            "Some campaign provenance fields are unavailable, so ledger transitions are conditional.",
            compatibility,
            "Regenerate ledgers with explicit case, solver, family, and environment provenance.",
        ))
    end
    new_count = 0
    resolved_count = 0
    persistent_count = 0
    changed_count = 0
    for identity in identities
        has_left = haskey(left, identity)
        has_right = haskey(right, identity)
        status = !has_left ? "new" : !has_right ? "resolved" : "persistent"
        if status == "new"
            new_count += 1
        elseif status == "resolved"
            resolved_count += 1
        else
            persistent_count += 1
        end
        left_item = _dict(get(left, identity, nothing))
        right_item = _dict(get(right, identity, nothing))
        left_severity = get(left_item, "severity_counts", Dict())
        right_severity = get(right_item, "severity_counts", Dict())
        left_confidence = get(left_item, "confidence_counts", Dict())
        right_confidence = get(right_item, "confidence_counts", Dict())
        distributions_changed = has_left && has_right &&
            (!_same(left_severity, right_severity) || !_same(left_confidence, right_confidence))
        distributions_changed && (changed_count += 1)
        change = Dict{String,Any}(
            "identity" => identity, "code" => get(right_item, "code", get(left_item, "code", "unknown")),
            "status" => status,
            "baseline_count" => get(left_item, "count", 0),
            "current_count" => get(right_item, "count", 0),
            "count_delta" => get(right_item, "count", 0) isa Number && get(left_item, "count", 0) isa Number ?
                get(right_item, "count", 0) - get(left_item, "count", 0) : nothing,
            "baseline_source_count" => get(left_item, "source_count", 0),
            "current_source_count" => get(right_item, "source_count", 0),
            "severity_distributions_changed" => distributions_changed,
            "baseline_severity_counts" => left_severity,
            "current_severity_counts" => right_severity,
            "baseline_confidence_counts" => left_confidence,
            "current_confidence_counts" => right_confidence,
            "baseline_sources" => get(left_item, "source_paths", Any[]),
            "current_sources" => get(right_item, "source_paths", Any[]),
        )
        push!(changes, change)
        if status == "new"
            push!(findings, _finding(
                "evidence_identity_new", "info",
                "Finding identity $identity is present in the current ledger but not the baseline.",
                Dict("identity" => identity, "current_count" => get(right_item, "count", 0),
                     "current_sources" => get(right_item, "source_paths", Any[])),
                "Inspect the current finding evidence and confirm whether the campaign selection changed.",
            ))
        elseif status == "resolved"
            push!(findings, _finding(
                "evidence_identity_resolved", "info",
                "Finding identity $identity is present in the baseline but not the current ledger.",
                Dict("identity" => identity, "baseline_count" => get(left_item, "count", 0),
                     "baseline_sources" => get(left_item, "source_paths", Any[])),
                "Confirm that the current campaign retained comparable cases, solvers, and analysis budgets.",
            ))
        elseif distributions_changed
            push!(findings, _finding(
                "evidence_identity_distribution_changed", "warning",
                "Finding identity $identity persists but its severity or confidence distribution changed.",
                Dict("identity" => identity, "baseline_severity_counts" => left_severity,
                     "current_severity_counts" => right_severity,
                     "baseline_confidence_counts" => left_confidence,
                     "current_confidence_counts" => right_confidence),
                "Inspect source-level records before interpreting the change as a model or solver effect.",
            ))
        end
    end
    output_path = length(ARGS) == 3 ? abspath(ARGS[3]) :
        joinpath(dirname(current_path), "evidence_ledger_comparison.json")
    write(output_path, JSON.json(Dict(
        "runner_version" => "bmopf-evidence-ledger-comparison-v2",
        "baseline_ledger" => baseline_path, "current_ledger" => current_path,
        "baseline_source_count" => get(baseline, "source_count", 0),
        "current_source_count" => get(current, "source_count", 0),
        "compatibility" => compatibility,
        "identity_count" => length(identities), "new_count" => new_count,
        "resolved_count" => resolved_count, "persistent_count" => persistent_count,
        "distribution_changed_count" => changed_count,
        "changes" => changes, "findings" => findings,
        "interpretation" => "Ledger comparison is source- and campaign-dependent evidence, not a model-quality score or causal test.",
    )))
    println("wrote BMOPF evidence-ledger comparison to $output_path")
end

main()
