#!/usr/bin/env julia

"""Compare sparse-QR nullspace evidence under two controlled policies."""

using JSON

_dict(value) = value isa AbstractDict ?
    Dict{String,Any}(String(key) => item for (key, item) in value) :
    Dict{String,Any}()

function _load(path)
    isfile(path) || error("missing multiconductor summary: $path")
    value = JSON.parsefile(path)
    value isa AbstractDict || error("summary is not a JSON object: $path")
    return value
end

function _int(value, default = 0)
    value isa Integer && return Int(value)
    value isa Number && isfinite(Float64(value)) && return Int(value)
    try parse(Int, String(value)) catch; default end
end

function _float(value)
    value isa Number && isfinite(Float64(value)) && return Float64(value)
    try
        parsed = parse(Float64, String(value))
        isfinite(parsed) ? parsed : nothing
    catch
        nothing
    end
end

function _float_list(value)
    value isa AbstractVector || return Float64[]
    result = Float64[]
    for item in value
        parsed = _float(item)
        isnothing(parsed) || push!(result, parsed)
    end
    return result
end

_delta(left, right) = begin
    left_value, right_value = _float(left), _float(right)
    isnothing(left_value) || isnothing(right_value) ? nothing :
        right_value - left_value
end

function _case_map(summary)
    result = Dict{String,Any}()
    for raw in get(summary, "cases", Any[])
        case = _dict(raw)
        name = String(get(case, "name", ""))
        isempty(name) || (result[name] = case)
    end
    return result
end

_estimate(case) = _dict(get(case, "sparse_qr_nullspace", nothing))

function _policy(summary)
    return Dict{String,Any}(
        "scaling" => String(get(summary, "sparse_qr_nullspace_scaling", "none")),
        "max_input_nonzeros" => _int(get(summary,
            "sparse_qr_nullspace_max_input_nonzeros", 0)),
        "max_factor_nonzeros" => _int(get(summary,
            "sparse_qr_nullspace_max_factor_nonzeros", 0)),
        "max_nullspace_entries" => _int(get(summary,
            "sparse_qr_nullspace_max_entries", 0)),
        "dense_calibration" => get(summary,
            "sparse_qr_nullspace_dense_calibration", false) === true,
    )
end

function _maximum_residual(estimate)
    values = _float_list(get(estimate, "relative_residuals", Any[]))
    return isempty(values) ? nothing : maximum(values)
end

function main()
    length(ARGS) in (2, 3) || error(
        "usage: compare_bmopf_sparse_qr_nullspaces.jl baseline-summary.json candidate-summary.json [comparison.json]",
    )
    baseline_path, candidate_path = abspath.(ARGS[1:2])
    output_path = length(ARGS) == 3 ? abspath(ARGS[3]) :
        joinpath(dirname(candidate_path), "sparse_qr_nullspace_comparison.json")
    baseline, candidate = _load(baseline_path), _load(candidate_path)
    baseline_cases, candidate_cases = _case_map(baseline), _case_map(candidate)
    names = sort!(collect(intersect(Set(keys(baseline_cases)), Set(keys(candidate_cases)))))
    missing_baseline = sort!(collect(setdiff(Set(keys(candidate_cases)), Set(keys(baseline_cases)))))
    missing_candidate = sort!(collect(setdiff(Set(keys(baseline_cases)), Set(keys(candidate_cases)))))
    baseline_policy, candidate_policy = _policy(baseline), _policy(candidate)
    policy_difference_fields = sort!([
        key for key in union(keys(baseline_policy), keys(candidate_policy))
        if get(baseline_policy, key, nothing) != get(candidate_policy, key, nothing)
    ])
    paired = Any[]
    for name in names
        left, right = _estimate(baseline_cases[name]), _estimate(candidate_cases[name])
        left_residual, right_residual = _maximum_residual(left), _maximum_residual(right)
        push!(paired, Dict{String,Any}(
            "name" => name,
            "baseline" => left,
            "candidate" => right,
            "availability_delta" => Int(get(right, "available", false) === true) -
                Int(get(left, "available", false) === true),
            "rank_delta" => _int(get(right, "rank", 0)) -
                _int(get(left, "rank", 0)),
            "right_nullity_delta" => _int(get(right, "right_nullity", 0)) -
                _int(get(left, "right_nullity", 0)),
            "maximum_relative_residual_delta" =>
                _delta(left_residual, right_residual),
            "orthogonality_loss_delta" => _delta(
                get(left, "orthogonality_loss", nothing),
                get(right, "orthogonality_loss", nothing),
            ),
            "factor_nonzeros_delta" => _int(get(right,
                "factor_nonzeros", 0)) - _int(get(left, "factor_nonzeros", 0)),
            "fill_ratio_delta" => _delta(get(left, "fill_ratio", nothing),
                get(right, "fill_ratio", nothing)),
            "dense_relation_changed" => get(left,
                "dense_calibration_relation", "unavailable") != get(right,
                "dense_calibration_relation", "unavailable"),
            "dense_minimum_principal_cosine_delta" => _delta(get(left,
                "dense_minimum_principal_cosine", nothing), get(right,
                "dense_minimum_principal_cosine", nothing)),
        ))
    end
    same_environment = get(baseline, "environment_fingerprint", nothing) ==
        get(candidate, "environment_fingerprint", nothing)
    same_point_policy = get(baseline, "point_policy", nothing) ==
        get(candidate, "point_policy", nothing)
    same_cases = isempty(missing_baseline) && isempty(missing_candidate)
    all_available = !isempty(paired) && all(row ->
        get(row["baseline"], "available", false) === true &&
        get(row["candidate"], "available", false) === true, paired)
    dense_pair_available = !isempty(paired) && all(row ->
        get(row["baseline"], "dense_calibration_available", false) === true &&
        get(row["candidate"], "dense_calibration_available", false) === true,
        paired)
    rank_change_count = count(row -> row["rank_delta"] != 0, paired)
    relation_change_count = count(row -> row["dense_relation_changed"], paired)
    findings = Any[]
    same_cases || push!(findings, Dict{String,Any}(
        "code" => "sparse_qr_nullspace_case_coverage_mismatch",
        "severity" => "warning",
        "observation" => "The sparse-QR summaries do not cover the same fixtures.",
        "evidence" => Dict("missing_from_baseline" => missing_baseline,
            "missing_from_candidate" => missing_candidate),
        "suggested_action" => "Interpret only explicitly paired fixtures.",
    ))
    same_environment || push!(findings, Dict{String,Any}(
        "code" => "sparse_qr_nullspace_environment_mismatch",
        "severity" => "warning",
        "observation" => "The sparse-QR summaries have different environment fingerprints.",
        "evidence" => Dict("baseline" => get(baseline,
            "environment_fingerprint", nothing), "candidate" => get(candidate,
            "environment_fingerprint", nothing)),
        "suggested_action" => "Repeat both policies under the same Julia and dependency environment.",
    ))
    same_point_policy || push!(findings, Dict{String,Any}(
        "code" => "sparse_qr_nullspace_point_policy_mismatch",
        "severity" => "warning",
        "observation" => "The sparse-QR summaries use different evaluation-point policies.",
        "evidence" => Dict("baseline" => get(baseline, "point_policy", nothing),
            "candidate" => get(candidate, "point_policy", nothing)),
        "suggested_action" => "Keep the evaluation point fixed for a scaling intervention.",
    ))
    isempty(policy_difference_fields) && push!(findings, Dict{String,Any}(
        "code" => "sparse_qr_nullspace_policy_not_distinct",
        "severity" => "warning",
        "observation" => "The sparse-QR summaries record identical policies.",
        "evidence" => Dict("policy" => baseline_policy),
        "suggested_action" => "Change one explicit scaling or resource policy.",
    ))
    rank_change_count > 0 && push!(findings, Dict{String,Any}(
        "code" => "sparse_qr_nullspace_rank_policy_sensitive",
        "severity" => "warning",
        "observation" => "Sparse-QR rank changed under the controlled policy intervention.",
        "evidence" => Dict("rank_change_count" => rank_change_count),
        "suggested_action" => "Inspect pivot magnitudes, thresholds, and dense-oracle ambiguity before interpreting nullity.",
    ))
    relation_change_count > 0 && push!(findings, Dict{String,Any}(
        "code" => "sparse_qr_nullspace_dense_relation_changed",
        "severity" => "warning",
        "observation" => "The dense-oracle relation changed under the controlled policy intervention.",
        "evidence" => Dict("relation_change_count" => relation_change_count),
        "suggested_action" => "Treat the extracted subspace as policy-sensitive numerical evidence.",
    ))
    readiness = Dict{String,Any}(
        "paired_case_coverage" => !isempty(paired) && same_cases,
        "environment_compatible" => same_environment,
        "same_point_policy" => same_point_policy,
        "distinct_policy" => !isempty(policy_difference_fields),
        "policy_difference_fields" => policy_difference_fields,
        "scaling_intervention_only" => policy_difference_fields == ["scaling"],
        "all_sparse_qr_estimates_available" => all_available,
        "dense_calibration_pair_available" => dense_pair_available,
        "rank_change_count" => rank_change_count,
        "dense_relation_change_count" => relation_change_count,
        "comparison_available" => !isempty(paired) && same_cases &&
            same_environment && same_point_policy &&
            !isempty(policy_difference_fields) && all_available,
    )
    payload = Dict{String,Any}(
        "report_version" => "bmopf-sparse-qr-nullspace-comparison-v1",
        "baseline_summary" => baseline_path,
        "candidate_summary" => candidate_path,
        "baseline_policy" => baseline_policy,
        "candidate_policy" => candidate_policy,
        "point_policy" => get(baseline, "point_policy", nothing),
        "paired_case_count" => length(paired),
        "missing_from_baseline" => missing_baseline,
        "missing_from_candidate" => missing_candidate,
        "comparisons" => paired,
        "readiness" => readiness,
        "findings" => findings,
        "interpretation" => "Controlled sparse-QR policy evidence only. Stable rank and dense-subspace agreement raise confidence in the local numerical nullspace, but do not identify a physical gauge or prove exact rank.",
    )
    write(output_path, JSON.json(payload))
    println("wrote sparse-QR nullspace comparison to $output_path")
end

main()
