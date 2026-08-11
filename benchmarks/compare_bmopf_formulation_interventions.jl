#!/usr/bin/env julia

"""Compare multiconductor numerical evidence across a formulation intervention.

Usage:

    julia benchmarks/compare_bmopf_formulation_interventions.jl \
        baseline-summary.json candidate-summary.json intervention-label \
        [comparison.json]

This report deliberately separates an observed pre/post change from a causal
claim.  Causal interpretation requires matching fixtures and numerical
policies plus clean, distinct BMOPFTools source revisions on both sides.
"""

using JSON

_dict(value) = value isa AbstractDict ?
    Dict{String,Any}(String(key) => item for (key, item) in value) :
    Dict{String,Any}()

function _load(path)
    isfile(path) || error("missing multiconductor summary: $path")
    value = JSON.parsefile(path)
    value isa AbstractDict || error("summary is not a JSON object: $path")
    return _dict(value)
end

function _int(value, default = 0)
    value isa Integer && return Int(value)
    value isa Number && isfinite(Float64(value)) && return Int(value)
    try parse(Int, String(value)) catch; default end
end

_bool(value) = value === true || lowercase(string(value)) == "true"

function _case_map(summary)
    result = Dict{String,Dict{String,Any}}()
    for raw in get(summary, "cases", Any[])
        case = _dict(raw)
        name = String(get(case, "name", ""))
        isempty(name) || (result[name] = case)
    end
    return result
end

function _environment(summary)
    environment = _dict(get(summary, "environment", nothing))
    !isempty(environment) && return environment
    index_path = get(summary, "index_path", nothing)
    if index_path isa AbstractString && isfile(index_path)
        index = _load(index_path)
        return _dict(get(index, "environment", nothing))
    end
    return Dict{String,Any}()
end

function _source_state(environment, package_name)
    states = _dict(get(environment, "package_source_states", nothing))
    return _dict(get(states, package_name, nothing))
end

function _source_identity(state)
    return (
        get(state, "git_revision", nothing),
        get(state, "git_dirty", nothing),
        get(state, "git_diff_fingerprint", nothing),
    )
end

function _sparse_qr_policy(summary)
    return Dict{String,Any}(
        "scaling" => String(get(summary, "sparse_qr_nullspace_scaling", "none")),
        "max_input_nonzeros" => get(summary,
            "sparse_qr_nullspace_max_input_nonzeros", nothing),
        "max_factor_nonzeros" => get(summary,
            "sparse_qr_nullspace_max_factor_nonzeros", nothing),
        "max_nullspace_entries" => get(summary,
            "sparse_qr_nullspace_max_entries", nothing),
        "dense_calibration" => _bool(get(summary,
            "sparse_qr_nullspace_dense_calibration", false)),
    )
end

function _persistence_policy(summary)
    return Dict{String,Any}(
        "repeat_count" => _int(get(summary,
            "sparse_qr_nullspace_persistence_repeat_count", 0)),
        "radii" => get(summary,
            "sparse_qr_nullspace_persistence_radii", Any[]),
        "direction_seed" => _int(get(summary,
            "sparse_qr_nullspace_persistence_direction_seed", 0)),
        "alignment_threshold" => get(summary,
            "sparse_qr_nullspace_persistence_alignment_threshold", nothing),
    )
end

function _fixture_sha(case)
    snapshot = _dict(get(case, "source_snapshot", nothing))
    return get(snapshot, "sha256", nothing)
end

function _persistent_evidence(persistence)
    return _bool(get(persistence, "available", false)) &&
        _bool(get(persistence, "rank_stable", false)) &&
        _bool(get(persistence, "subspace_persistent", false)) &&
        _bool(get(persistence, "residual_supported", false))
end

function _finding(code, severity, observation, evidence, action)
    return Dict{String,Any}(
        "code" => code,
        "severity" => severity,
        "confidence" => severity == "info" ? "numerical" : "structural",
        "observation" => observation,
        "evidence" => evidence,
        "suggested_action" => action,
    )
end

function main()
    length(ARGS) in (3, 4) || error(
        "usage: compare_bmopf_formulation_interventions.jl baseline-summary.json candidate-summary.json intervention-label [comparison.json]",
    )
    baseline_path, candidate_path = abspath.(ARGS[1:2])
    intervention_label = strip(ARGS[3])
    isempty(intervention_label) && error("intervention-label must not be empty")
    output_path = length(ARGS) == 4 ? abspath(ARGS[4]) :
        joinpath(dirname(candidate_path), "formulation_intervention_comparison.json")
    baseline, candidate = _load(baseline_path), _load(candidate_path)
    baseline_cases, candidate_cases = _case_map(baseline), _case_map(candidate)
    names = sort!(collect(intersect(Set(keys(baseline_cases)), Set(keys(candidate_cases)))))
    missing_baseline = sort!(collect(setdiff(Set(keys(candidate_cases)), Set(keys(baseline_cases)))))
    missing_candidate = sort!(collect(setdiff(Set(keys(baseline_cases)), Set(keys(candidate_cases)))))

    baseline_qr_policy, candidate_qr_policy =
        _sparse_qr_policy(baseline), _sparse_qr_policy(candidate)
    baseline_persistence_policy, candidate_persistence_policy =
        _persistence_policy(baseline), _persistence_policy(candidate)
    same_point_policy = get(baseline, "point_policy", nothing) ==
        get(candidate, "point_policy", nothing)
    same_qr_policy = baseline_qr_policy == candidate_qr_policy
    same_persistence_policy = baseline_persistence_policy == candidate_persistence_policy
    same_case_coverage = isempty(missing_baseline) && isempty(missing_candidate)

    baseline_environment, candidate_environment =
        _environment(baseline), _environment(candidate)
    baseline_source = _source_state(baseline_environment, "BMOPFTools")
    candidate_source = _source_state(candidate_environment, "BMOPFTools")
    source_provenance_available =
        _bool(get(baseline_source, "available", false)) &&
        _bool(get(candidate_source, "available", false))
    formulation_source_changed = source_provenance_available &&
        _source_identity(baseline_source) != _source_identity(candidate_source)
    isolated_formulation_revision = source_provenance_available &&
        get(baseline_source, "git_dirty", true) === false &&
        get(candidate_source, "git_dirty", true) === false &&
        get(baseline_source, "git_revision", nothing) !=
            get(candidate_source, "git_revision", nothing)

    comparisons = Any[]
    for name in names
        left, right = baseline_cases[name], candidate_cases[name]
        left_qr, right_qr = _dict(get(left, "sparse_qr_nullspace", nothing)),
            _dict(get(right, "sparse_qr_nullspace", nothing))
        left_persistence = _dict(get(left,
            "sparse_qr_nullspace_persistence", nothing))
        right_persistence = _dict(get(right,
            "sparse_qr_nullspace_persistence", nothing))
        variable_delta = _int(get(right, "model_variable_count", 0)) -
            _int(get(left, "model_variable_count", 0))
        row_delta = _int(get(right, "scalar_constraint_row_count", 0)) -
            _int(get(left, "scalar_constraint_row_count", 0))
        rank_delta = _int(get(right_qr, "rank", 0)) -
            _int(get(left_qr, "rank", 0))
        baseline_nullity = _int(get(left_qr, "right_nullity", 0))
        candidate_nullity = _int(get(right_qr, "right_nullity", 0))
        nullity_delta = candidate_nullity - baseline_nullity
        disconnected_delta = _int(get(right_persistence,
            "disconnected_variable_count", 0)) - _int(get(left_persistence,
            "disconnected_variable_count", 0))
        nullspace_removed = baseline_nullity > 0 && candidate_nullity == 0 &&
            _persistent_evidence(left_persistence) &&
            _persistent_evidence(right_persistence)
        disconnected_support_removed = _int(get(left_persistence,
            "disconnected_variable_count", 0)) > 0 &&
            _int(get(right_persistence, "disconnected_variable_count", 0)) == 0
        dimension_change_matches_removed_nullity = nullspace_removed &&
            variable_delta == -baseline_nullity && row_delta == 0 && rank_delta == 0
        dense_corroborated =
            _bool(get(left_qr, "dense_calibration_available", false)) &&
            _bool(get(right_qr, "dense_calibration_available", false)) &&
            _int(get(left_qr, "dense_right_nullity", -1)) == baseline_nullity &&
            _int(get(right_qr, "dense_right_nullity", -1)) == candidate_nullity
        classification = dimension_change_matches_removed_nullity &&
            disconnected_support_removed ?
            "disconnected_formulation_coordinates_removed" :
            nullspace_removed ? "persistent_nullspace_removed" :
            nullity_delta == 0 ? "persistent_nullity_unchanged" :
            "persistent_nullity_changed"
        push!(comparisons, Dict{String,Any}(
            "name" => name,
            "fixture_sha256_matches" => _fixture_sha(left) == _fixture_sha(right) &&
                !isnothing(_fixture_sha(left)),
            "baseline" => Dict(
                "model_variable_count" => get(left, "model_variable_count", nothing),
                "scalar_constraint_row_count" => get(left,
                    "scalar_constraint_row_count", nothing),
                "sparse_qr_nullspace" => left_qr,
                "sparse_qr_nullspace_persistence" => left_persistence,
            ),
            "candidate" => Dict(
                "model_variable_count" => get(right, "model_variable_count", nothing),
                "scalar_constraint_row_count" => get(right,
                    "scalar_constraint_row_count", nothing),
                "sparse_qr_nullspace" => right_qr,
                "sparse_qr_nullspace_persistence" => right_persistence,
            ),
            "model_variable_count_delta" => variable_delta,
            "scalar_constraint_row_count_delta" => row_delta,
            "rank_delta" => rank_delta,
            "right_nullity_delta" => nullity_delta,
            "disconnected_variable_count_delta" => disconnected_delta,
            "nullspace_removed" => nullspace_removed,
            "disconnected_support_removed" => disconnected_support_removed,
            "dimension_change_matches_removed_nullity" =>
                dimension_change_matches_removed_nullity,
            "dense_corroborated" => dense_corroborated,
            "classification" => classification,
        ))
    end

    fixture_identity_matches = !isempty(comparisons) && all(row ->
        row["fixture_sha256_matches"] === true, comparisons)
    all_estimates_available = !isempty(comparisons) && all(row ->
        _bool(get(row["baseline"]["sparse_qr_nullspace"], "available", false)) &&
        _bool(get(row["candidate"]["sparse_qr_nullspace"], "available", false)) &&
        _bool(get(row["baseline"]["sparse_qr_nullspace_persistence"], "available", false)) &&
        _bool(get(row["candidate"]["sparse_qr_nullspace_persistence"], "available", false)),
        comparisons)
    controlled = same_case_coverage && fixture_identity_matches &&
        same_point_policy && same_qr_policy && same_persistence_policy &&
        all_estimates_available
    causal_ready = controlled && formulation_source_changed &&
        isolated_formulation_revision
    removed_count = count(row -> row["nullspace_removed"] === true, comparisons)
    dimension_match_count = count(row ->
        row["dimension_change_matches_removed_nullity"] === true, comparisons)

    findings = Any[]
    same_case_coverage || push!(findings, _finding(
        "formulation_intervention_case_coverage_mismatch", "warning",
        "Baseline and candidate do not cover the same fixtures.",
        Dict("missing_from_baseline" => missing_baseline,
            "missing_from_candidate" => missing_candidate),
        "Interpret only explicitly paired fixtures."))
    fixture_identity_matches || push!(findings, _finding(
        "formulation_intervention_fixture_identity_mismatch", "warning",
        "At least one paired fixture lacks matching source bytes.",
        Dict("paired_case_count" => length(comparisons)),
        "Use identical source fixtures on both sides of the intervention."))
    same_point_policy || push!(findings, _finding(
        "formulation_intervention_point_policy_mismatch", "warning",
        "The evaluation-point policies differ.",
        Dict("baseline" => get(baseline, "point_policy", nothing),
            "candidate" => get(candidate, "point_policy", nothing)),
        "Repeat both formulations under the same point policy."))
    same_qr_policy || push!(findings, _finding(
        "formulation_intervention_sparse_qr_policy_mismatch", "warning",
        "The sparse-QR numerical policies differ.",
        Dict("baseline" => baseline_qr_policy, "candidate" => candidate_qr_policy),
        "Repeat both formulations with identical scaling and resource guards."))
    same_persistence_policy || push!(findings, _finding(
        "formulation_intervention_persistence_policy_mismatch", "warning",
        "The repeat/nearby persistence policies differ.",
        Dict("baseline" => baseline_persistence_policy,
            "candidate" => candidate_persistence_policy),
        "Use identical repeat counts, radii, seed, and alignment threshold."))
    source_provenance_available || push!(findings, _finding(
        "formulation_intervention_source_provenance_missing", "warning",
        "BMOPFTools source revisions were not captured on both sides.",
        Dict("baseline" => baseline_source, "candidate" => candidate_source),
        "Regenerate both campaigns with package source-state provenance enabled."))
    source_provenance_available && !isolated_formulation_revision &&
        push!(findings, _finding(
            "formulation_intervention_revision_not_isolated", "warning",
            "The BMOPFTools source change is dirty or does not use distinct clean revisions.",
            Dict("baseline" => baseline_source, "candidate" => candidate_source),
            "For causal attribution, compare two clean commits whose diff is the declared intervention."))
    removed_count > 0 && push!(findings, _finding(
        "formulation_intervention_persistent_nullspace_removed", "info",
        "The candidate removes a repeatable, nearby-persistent right nullspace.",
        Dict("case_count" => removed_count),
        "Inspect the paired coordinate support and dimension deltas before assigning cause."))
    dimension_match_count > 0 && push!(findings, _finding(
        "formulation_intervention_dimension_change_matches_removed_nullity", "info",
        "Removed variable coordinates exactly match the removed persistent nullity while row count and rank stay fixed.",
        Dict("case_count" => dimension_match_count),
        "Preserve this as strong local numerical evidence; use isolated revisions for a causal claim."))

    readiness = Dict{String,Any}(
        "paired_case_coverage" => !isempty(comparisons) && same_case_coverage,
        "fixture_identity_matches" => fixture_identity_matches,
        "same_point_policy" => same_point_policy,
        "same_sparse_qr_policy" => same_qr_policy,
        "same_persistence_policy" => same_persistence_policy,
        "all_estimates_available" => all_estimates_available,
        "source_provenance_available" => source_provenance_available,
        "formulation_source_changed" => formulation_source_changed,
        "isolated_formulation_revision" => isolated_formulation_revision,
        "controlled_intervention_comparison" => controlled,
        "causal_interpretation_ready" => causal_ready,
        "comparison_available" => !isempty(comparisons) && all_estimates_available,
    )
    payload = Dict{String,Any}(
        "report_version" => "bmopf-formulation-intervention-comparison-v1",
        "intervention_label" => intervention_label,
        "baseline_summary" => baseline_path,
        "candidate_summary" => candidate_path,
        "baseline_environment_fingerprint" => get(baseline,
            "environment_fingerprint", nothing),
        "candidate_environment_fingerprint" => get(candidate,
            "environment_fingerprint", nothing),
        "baseline_bmopftools_source" => baseline_source,
        "candidate_bmopftools_source" => candidate_source,
        "baseline_sparse_qr_policy" => baseline_qr_policy,
        "candidate_sparse_qr_policy" => candidate_qr_policy,
        "baseline_persistence_policy" => baseline_persistence_policy,
        "candidate_persistence_policy" => candidate_persistence_policy,
        "paired_case_count" => length(comparisons),
        "missing_from_baseline" => missing_baseline,
        "missing_from_candidate" => missing_candidate,
        "comparisons" => comparisons,
        "aggregate" => Dict(
            "persistent_nullspace_removed_case_count" => removed_count,
            "dimension_change_matches_removed_nullity_case_count" =>
                dimension_match_count,
        ),
        "readiness" => readiness,
        "findings" => findings,
        "interpretation" => "Controlled pre/post formulation evidence, not a proof of causality. A persistent nullity change is numerical evidence; causal attribution additionally requires identical fixtures and numerical policies plus an isolated, recorded source revision.",
    )
    mkpath(dirname(output_path))
    write(output_path, JSON.json(payload))
    println("wrote formulation-intervention comparison to $output_path")
end

main()
