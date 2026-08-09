#!/usr/bin/env julia

"""Compare paired BMOPF smoke summaries with different tangent scopes.

The comparison is deliberately local and evidence-oriented. It reports which
fixtures changed dense rank or expected-mode status when fixed/reference
coordinates were retained, but never calls that change a physical diagnosis.
"""

using JSON

_dict(value) = value isa AbstractDict ?
    Dict{String,Any}(String(key) => item for (key, item) in value) : Dict{String,Any}()
_int(value, default = 0) = try Int(value) catch; default end

function _load(path)
    value = JSON.parsefile(path)
    value isa AbstractDict || error("summary must contain a JSON object: $path")
    return _dict(value)
end

function _cases(summary)
    Dict{String,Dict{String,Any}}(
        String(get(_dict(item), "name", "unknown")) => _dict(item)
        for item in get(summary, "cases", Any[])
        if item isa AbstractDict
    )
end

function _policy(summary, key, default = "unknown")
    cases = get(summary, "cases", Any[])
    first_case = isempty(cases) ? Dict{String,Any}() : _dict(first(cases))
    return String(get(summary, key, get(first_case, key, default)))
end

function _mode(case)
    raw = _dict(get(case, "physical_mode_comparison", nothing))
    return Dict{String,Any}(
        "status" => String(get(raw, "status", "unavailable")),
        "rank_available" => get(raw, "jacobian_rank_available", false) === true,
        "rank" => _int(get(raw, "jacobian_rank", 0)),
        "expected" => _int(get(raw, "expected_mode_count", 0)),
        "observed" => _int(get(raw, "observed_mode_count", 0)),
        "not_observed" => _int(get(raw, "not_observed_mode_count", 0)),
        "unaligned" => _int(get(raw, "unaligned_mode_count", 0)),
        "projected_observed" => _int(get(raw, "projected_observed_mode_count", 0)),
        "projected_not_observed" => _int(get(raw, "projected_not_observed_mode_count", 0)),
        "tangent_observed" => _int(get(raw, "tangent_observed_mode_count", 0)),
        "tangent_not_observed" => _int(get(raw, "tangent_not_observed_mode_count", 0)),
        "tangent_rows" => get(raw, "tangent_rows", Any[]),
        "tangent_policy_variable_count" => _int(
            get(case, "expected_mode_tangent_policy_variable_count", 0),
        ),
    )
end

function _difference(left, right)
    return Dict{String,Any}(
        "rank" => right["rank"] - left["rank"],
        "observed" => right["observed"] - left["observed"],
        "not_observed" => right["not_observed"] - left["not_observed"],
        "unaligned" => right["unaligned"] - left["unaligned"],
        "projected_observed" => right["projected_observed"] - left["projected_observed"],
        "projected_not_observed" => right["projected_not_observed"] - left["projected_not_observed"],
        "tangent_observed" => right["tangent_observed"] - left["tangent_observed"],
        "tangent_not_observed" => right["tangent_not_observed"] - left["tangent_not_observed"],
    )
end

function main()
    length(ARGS) in (2, 3) || error(
        "usage: compare_bmopf_tangent_policies.jl baseline-summary.json candidate-summary.json [output.json]",
    )
    baseline_path, candidate_path = abspath.(ARGS[1:2])
    output_path = length(ARGS) == 3 ? abspath(ARGS[3]) :
        joinpath(dirname(candidate_path), "tangent_policy_comparison.json")
    baseline, candidate = _load(baseline_path), _load(candidate_path)
    baseline_cases, candidate_cases = _cases(baseline), _cases(candidate)
    names = sort!(collect(intersect(Set(keys(baseline_cases)), Set(keys(candidate_cases)))))
    missing_baseline = sort!(collect(setdiff(Set(keys(candidate_cases)), Set(keys(baseline_cases)))))
    missing_candidate = sort!(collect(setdiff(Set(keys(baseline_cases)), Set(keys(candidate_cases)))))
    baseline_policy = _policy(baseline, "expected_mode_tangent_policy")
    candidate_policy = _policy(candidate, "expected_mode_tangent_policy")
    baseline_free_policy = _policy(baseline, "expected_mode_free_coordinate_policy")
    candidate_free_policy = _policy(candidate, "expected_mode_free_coordinate_policy")
    paired = Dict{String,Any}[]
    for name in names
        left, right = _mode(baseline_cases[name]), _mode(candidate_cases[name])
        rank_pair = left["rank_available"] && right["rank_available"]
        status_changed = left["status"] != right["status"]
        rank_changed = rank_pair && left["rank"] != right["rank"]
        mode_changed = status_changed || any(
            left[key] != right[key] for key in
            ("observed", "not_observed", "unaligned", "projected_observed",
             "projected_not_observed", "tangent_observed", "tangent_not_observed")
        )
        classification = if !rank_pair && !status_changed
            "unavailable"
        elseif rank_changed
            "rank_changed_under_tangent_scope"
        elseif mode_changed
            "mode_status_changed_under_tangent_scope"
        else
            "stable_under_tangent_scope"
        end
        push!(paired, Dict{String,Any}(
            "name" => name,
            "baseline" => left,
            "candidate" => right,
            "delta_candidate_minus_baseline" => _difference(left, right),
            "rank_changed" => rank_changed,
            "mode_status_changed" => mode_changed,
            "classification" => classification,
        ))
    end
    environment_compatible = get(baseline, "environment_fingerprint", nothing) ==
                             get(candidate, "environment_fingerprint", nothing)
    point_compatible = get(baseline, "point_policy", nothing) ==
                       get(candidate, "point_policy", nothing)
    free_policy_compatible = baseline_free_policy == candidate_free_policy
    dense_pairs = count(item -> item["baseline"]["rank_available"] &&
        item["candidate"]["rank_available"], paired)
    rank_changes = count(item -> item["rank_changed"], paired)
    mode_changes = count(item -> item["mode_status_changed"], paired)
    findings = Any[]
    isempty(missing_baseline) && isempty(missing_candidate) || push!(findings, Dict(
        "code" => "tangent_policy_case_coverage_mismatch", "severity" => "warning",
        "observation" => "The tangent-policy summaries do not cover the same fixtures.",
        "evidence" => Dict("missing_from_baseline" => missing_baseline,
                           "missing_from_candidate" => missing_candidate),
        "suggested_action" => "Rerun both policies with the same fixture selection.",
    ))
    environment_compatible || push!(findings, Dict(
        "code" => "tangent_policy_environment_mismatch", "severity" => "warning",
        "observation" => "The paired summaries were produced under different environments.",
        "evidence" => Dict("baseline_environment" => get(baseline, "environment_fingerprint", nothing),
                           "candidate_environment" => get(candidate, "environment_fingerprint", nothing)),
        "suggested_action" => "Align Julia, NLPDiagnostics, BMOPFTools, PowerIO, and fixture provenance.",
    ))
    point_compatible || push!(findings, Dict(
        "code" => "tangent_policy_point_policy_mismatch", "severity" => "warning",
        "observation" => "The tangent-policy summaries use different evaluation-point policies.",
        "evidence" => Dict("baseline_point_policy" => get(baseline, "point_policy", "unknown"),
                           "candidate_point_policy" => get(candidate, "point_policy", "unknown")),
        "suggested_action" => "Use the same point policy so only the coordinate scope changes.",
    ))
    free_policy_compatible || push!(findings, Dict(
        "code" => "tangent_policy_free_scope_mismatch", "severity" => "warning",
        "observation" => "The paired summaries use different generic free-coordinate policies.",
        "evidence" => Dict("baseline_policy" => baseline_free_policy,
                           "candidate_policy" => candidate_free_policy),
        "suggested_action" => "Hold the generic free-coordinate policy constant while calibrating the tangent scope.",
    ))
    baseline_policy == candidate_policy && push!(findings, Dict(
        "code" => "tangent_policy_not_distinct", "severity" => "warning",
        "observation" => "Both summaries use the same tangent policy, so no scope calibration was performed.",
        "evidence" => Dict("policy" => baseline_policy),
        "suggested_action" => "Compare none against the explicit fixed/reference tangent scope.",
    ))
    rank_changes > 0 && push!(findings, Dict(
        "code" => "tangent_policy_rank_change_observed", "severity" => "info",
        "observation" => "Dense local Jacobian rank changed when the tangent scope was altered.",
        "evidence" => Dict("rank_change_case_count" => rank_changes,
                           "dense_pair_count" => dense_pairs),
        "suggested_action" => "Inspect per-fixture coordinate support and row provenance; this is not a physical diagnosis.",
    ))
    mode_changes > 0 && push!(findings, Dict(
        "code" => "tangent_policy_mode_status_change_observed", "severity" => "info",
        "observation" => "Expected-mode status changed when the tangent scope was altered.",
        "evidence" => Dict("mode_status_change_case_count" => mode_changes),
        "suggested_action" => "Review residuals and retained variable indices before promoting the result to plugin semantics.",
    ))
    payload = Dict{String,Any}(
        "report_version" => "bmopf-tangent-policy-comparison-v1",
        "baseline_summary" => baseline_path,
        "candidate_summary" => candidate_path,
        "baseline_tangent_policy" => baseline_policy,
        "candidate_tangent_policy" => candidate_policy,
        "baseline_free_coordinate_policy" => baseline_free_policy,
        "candidate_free_coordinate_policy" => candidate_free_policy,
        "paired_case_count" => length(paired),
        "missing_from_baseline" => missing_baseline,
        "missing_from_candidate" => missing_candidate,
        "paired_cases" => paired,
        "readiness" => Dict(
            "paired_case_coverage" => !isempty(paired) && isempty(missing_baseline) && isempty(missing_candidate),
            "environment_compatible" => environment_compatible,
            "point_policy_compatible" => point_compatible,
            "free_coordinate_policy_compatible" => free_policy_compatible,
            "distinct_tangent_policies" => baseline_policy != candidate_policy,
            "dense_rank_pair_count" => dense_pairs,
            "comparison_available" => !isempty(paired) && environment_compatible &&
                point_compatible && free_policy_compatible &&
                baseline_policy != candidate_policy && dense_pairs > 0,
        ),
        "findings" => findings,
        "interpretation" => "Tangent-policy calibration is paired local evidence. It does not certify a physical gauge, formulation quality, or solver behavior.",
    )
    write(output_path, JSON.json(payload))
    println("wrote BMOPF tangent-policy comparison to $output_path")
end

main()
