#!/usr/bin/env julia

"""Compare bounded smallest-direction crosschecks at the same BMOPF point."""

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

function _case_map(summary)
    result = Dict{String,Any}()
    for raw in get(summary, "cases", Any[])
        case = _dict(raw)
        name = String(get(case, "name", ""))
        isempty(name) || (result[name] = case)
    end
    return result
end

_crosscheck(case) = _dict(get(case,
    "smallest_singular_backend_crosscheck", nothing))

function _maximum_difference(crosscheck)
    values = Float64[]
    for raw in get(crosscheck, "relative_value_differences", Any[])
        value = _float(raw)
        isnothing(value) || push!(values, value)
    end
    return isempty(values) ? nothing : maximum(values)
end

function _delta(left, right)
    left_value, right_value = _float(left), _float(right)
    isnothing(left_value) || isnothing(right_value) ? nothing :
        right_value - left_value
end

function _work_policy(summary)
    Dict{String,Any}(
        "dimension" => _int(get(summary,
            "smallest_singular_backend_crosscheck_dimension", 0)),
        "restarted_iterations" => _int(get(summary,
            "smallest_singular_backend_crosscheck_restarted_iterations", 0)),
        "restarted_alignment_threshold" => _float(get(summary,
            "smallest_singular_backend_crosscheck_restarted_alignment_threshold", nothing)),
        "harmonic_steps_per_seed" => _int(get(summary,
            "smallest_singular_backend_crosscheck_harmonic_steps_per_seed", 0)),
        "harmonic_cycles" => _int(get(summary,
            "smallest_singular_backend_crosscheck_harmonic_cycles", 0)),
        "harmonic_alignment_threshold" => _float(get(summary,
            "smallest_singular_backend_crosscheck_harmonic_alignment_threshold", nothing)),
        "max_basis_entries" => _int(get(summary,
            "smallest_singular_backend_crosscheck_max_basis_entries", 0)),
        "scaling" => string(get(summary,
            "smallest_singular_backend_crosscheck_scaling", "none")),
    )
end

function main()
    length(ARGS) in (2, 3) || error(
        "usage: compare_bmopf_multiconductor_crosschecks.jl baseline-summary.json candidate-summary.json [comparison.json]",
    )
    baseline_path, candidate_path = abspath.(ARGS[1:2])
    output_path = length(ARGS) == 3 ? abspath(ARGS[3]) :
        joinpath(dirname(candidate_path), "multiconductor_crosscheck_comparison.json")
    baseline, candidate = _load(baseline_path), _load(candidate_path)
    baseline_cases, candidate_cases = _case_map(baseline), _case_map(candidate)
    names = sort!(collect(intersect(Set(keys(baseline_cases)), Set(keys(candidate_cases)))))
    missing_baseline = sort!(collect(setdiff(Set(keys(candidate_cases)), Set(keys(baseline_cases)))))
    missing_candidate = sort!(collect(setdiff(Set(keys(baseline_cases)), Set(keys(candidate_cases)))))
    baseline_policy, candidate_policy = _work_policy(baseline), _work_policy(candidate)
    paired = Any[]
    for name in names
        left, right = _crosscheck(baseline_cases[name]), _crosscheck(candidate_cases[name])
        left_maximum, right_maximum =
            _maximum_difference(left), _maximum_difference(right)
        push!(paired, Dict{String,Any}(
            "name" => name,
            "baseline" => left,
            "candidate" => right,
            "dimension_aligned" => _int(get(left, "requested_dimension", 0)) ==
                _int(get(right, "requested_dimension", 0)),
            "availability_delta" => Int(get(right, "available", false) === true) -
                Int(get(left, "available", false) === true),
            "restarted_convergence_delta" =>
                Int(get(right, "restarted_converged", false) === true) -
                Int(get(left, "restarted_converged", false) === true),
            "harmonic_convergence_delta" =>
                Int(get(right, "harmonic_converged", false) === true) -
                Int(get(left, "harmonic_converged", false) === true),
            "relation_changed" => get(left, "relation", "unavailable") !=
                get(right, "relation", "unavailable"),
            "agreement_delta" => Int(get(right, "relation", "") == "agreement") -
                Int(get(left, "relation", "") == "agreement"),
            "maximum_relative_value_difference_delta" =>
                _delta(left_maximum, right_maximum),
            "minimum_principal_cosine_delta" => _delta(
                get(left, "minimum_principal_cosine", nothing),
                get(right, "minimum_principal_cosine", nothing),
            ),
        ))
    end
    same_environment = get(baseline, "environment_fingerprint", nothing) ==
        get(candidate, "environment_fingerprint", nothing)
    same_point_policy = get(baseline, "point_policy", nothing) ==
        get(candidate, "point_policy", nothing)
    dimension_aligned = all(row -> row["dimension_aligned"], paired)
    distinct_work_policy = baseline_policy != candidate_policy
    policy_difference_fields = sort!([
        key for key in union(keys(baseline_policy), keys(candidate_policy))
        if get(baseline_policy, key, nothing) != get(candidate_policy, key, nothing)
    ])
    scaling_intervention_only = policy_difference_fields == ["scaling"]
    comparison_kind = scaling_intervention_only ?
        "scaling_intervention" : "numerical_policy"
    same_scaling = get(baseline_policy, "scaling", "none") ==
        get(candidate_policy, "scaling", "none")
    relation_changes = count(row -> row["relation_changed"], paired)
    restarted_gains = count(row -> row["restarted_convergence_delta"] > 0, paired)
    restarted_losses = count(row -> row["restarted_convergence_delta"] < 0, paired)
    harmonic_gains = count(row -> row["harmonic_convergence_delta"] > 0, paired)
    harmonic_losses = count(row -> row["harmonic_convergence_delta"] < 0, paired)
    agreement_gains = count(row -> row["agreement_delta"] > 0, paired)
    agreement_losses = count(row -> row["agreement_delta"] < 0, paired)
    findings = Any[]
    isempty(missing_baseline) && isempty(missing_candidate) || push!(findings, Dict(
        "code" => "multiconductor_crosscheck_case_coverage_mismatch",
        "severity" => "warning",
        "observation" => "The crosscheck summaries do not cover the same fixtures.",
        "evidence" => Dict("missing_from_baseline" => missing_baseline,
                           "missing_from_candidate" => missing_candidate),
        "suggested_action" => "Interpret only explicitly paired fixtures.",
    ))
    same_environment || push!(findings, Dict(
        "code" => "multiconductor_crosscheck_environment_mismatch",
        "severity" => "warning",
        "observation" => "The crosscheck summaries have different environment fingerprints.",
        "evidence" => Dict("baseline_environment" => get(baseline,
            "environment_fingerprint", nothing), "candidate_environment" =>
            get(candidate, "environment_fingerprint", nothing)),
        "suggested_action" => "Repeat both budgets on the same source revision and dependency environment.",
    ))
    same_point_policy || push!(findings, Dict(
        "code" => "multiconductor_crosscheck_point_policy_mismatch",
        "severity" => "warning",
        "observation" => "The crosscheck summaries use different evaluation-point policies.",
        "evidence" => Dict("baseline_point_policy" => get(baseline,
            "point_policy", nothing), "candidate_point_policy" => get(candidate,
            "point_policy", nothing)),
        "suggested_action" => "Use the same evaluation point when calibrating work-budget sensitivity.",
    ))
    dimension_aligned || push!(findings, Dict(
        "code" => "multiconductor_crosscheck_dimension_mismatch",
        "severity" => "warning",
        "observation" => "The paired crosschecks request different candidate dimensions.",
        "evidence" => Dict("paired_case_count" => length(paired)),
        "suggested_action" => "Keep candidate dimension fixed when comparing search budgets.",
    ))
    distinct_work_policy || push!(findings, Dict(
        "code" => "multiconductor_crosscheck_work_policy_not_distinct",
        "severity" => "warning",
        "observation" => "The two summaries record the same crosscheck work policy.",
        "evidence" => Dict("work_policy" => baseline_policy),
        "suggested_action" => "Change an explicit iteration, cycle, basis-storage, or scaling policy.",
    ))
    same_scaling || push!(findings, Dict(
        "code" => "multiconductor_crosscheck_scaled_spectra_not_directly_comparable",
        "severity" => "info",
        "observation" => "The summaries use different Jacobian scaling metrics; their singular values are not values of the same operator.",
        "evidence" => Dict(
            "baseline_scaling" => get(baseline_policy, "scaling", "none"),
            "candidate_scaling" => get(candidate_policy, "scaling", "none"),
        ),
        "suggested_action" => "Compare convergence, coverage, and dense-oracle relations as intervention outcomes; do not interpret raw scaled singular-value changes as conditioning improvement in the original model.",
    ))
    readiness = Dict{String,Any}(
        "paired_case_coverage" => !isempty(paired) && isempty(missing_baseline) &&
            isempty(missing_candidate),
        "environment_compatible" => same_environment,
        "same_point_policy" => same_point_policy,
        "dimension_aligned" => dimension_aligned,
        "distinct_work_policy" => distinct_work_policy,
        "comparison_kind" => comparison_kind,
        "policy_difference_fields" => policy_difference_fields,
        "scaling_intervention_only" => scaling_intervention_only,
        "scaled_spectra_directly_comparable" => same_scaling,
        "comparison_available" => !isempty(paired) && same_environment &&
            same_point_policy && dimension_aligned && distinct_work_policy &&
            isempty(missing_baseline) && isempty(missing_candidate),
        "relation_change_count" => relation_changes,
        "restarted_convergence_gain_count" => restarted_gains,
        "restarted_convergence_loss_count" => restarted_losses,
        "harmonic_convergence_gain_count" => harmonic_gains,
        "harmonic_convergence_loss_count" => harmonic_losses,
        "agreement_gain_count" => agreement_gains,
        "agreement_loss_count" => agreement_losses,
    )
    payload = Dict{String,Any}(
        "report_version" => "bmopf-multiconductor-crosscheck-comparison-v1",
        "baseline_summary" => baseline_path,
        "candidate_summary" => candidate_path,
        "baseline_work_policy" => baseline_policy,
        "candidate_work_policy" => candidate_policy,
        "comparison_kind" => comparison_kind,
        "policy_difference_fields" => policy_difference_fields,
        "point_policy" => get(baseline, "point_policy", nothing),
        "paired_case_count" => length(paired),
        "missing_from_baseline" => missing_baseline,
        "missing_from_candidate" => missing_candidate,
        "comparisons" => paired,
        "readiness" => readiness,
        "findings" => findings,
        "interpretation" => scaling_intervention_only ?
            "Controlled Jacobian-scaling sensitivity evidence only; scaled-system convergence and backend-relation changes are not rank, solver-scaling, or physical-gauge certificates." :
            "Numerical-policy sensitivity evidence only; convergence gains and backend-relation changes are not rank or physical-gauge certificates.",
    )
    write(output_path, JSON.json(payload))
    println("wrote multiconductor crosscheck comparison to $output_path")
end

main()
