#!/usr/bin/env julia

"""Validate BMOPF benchmark trust gates without reducing findings to a score.

The validator consumes one or more JSON summaries produced by the existing
BMOPF corpus, persistence, policy-comparison, or campaign summarizers. It
checks reproducibility and evidence availability, then reports separate
readiness gates for generic observations, saved-result interpretation, dense
rank interpretation, paired-policy alignment, and physical component-rank
interpretation.

Usage:

    julia benchmarks/validate_bmopf_campaign.jl output.json summary1.json ...
"""

using JSON

function _load(path)
    isfile(path) || error("benchmark summary is missing: $path")
    value = JSON.parsefile(path)
    value isa AbstractDict || error("benchmark summary is not a JSON object: $path")
    return value
end

function _int(value, default = 0)
    value isa Integer && return Int(value)
    value isa Number && isfinite(Float64(value)) && return Int(value)
    value isa AbstractString || return default
    try parse(Int, value) catch; default end
end

function _float(value)
    value isa Number && isfinite(Float64(value)) && return Float64(value)
    value isa AbstractString || return nothing
    try
        parsed = parse(Float64, value)
        isfinite(parsed) ? parsed : nothing
    catch
        nothing
    end
end

function _finding(code, severity, observation, evidence; suggested_action = nothing)
    result = Dict{String,Any}(
        "code" => code,
        "severity" => severity,
        "observation" => observation,
        "evidence" => evidence,
    )
    !isnothing(suggested_action) && (result["suggested_action"] = suggested_action)
    return result
end

function _validate_campaign(path, summary)
    findings = Any[]
    errors = _int(get(summary, "error_case_count", 0))
    skipped = _int(get(summary, "skipped_case_count", 0))
    case_count = length(get(summary, "cases", Any[]))
    integrity = get(summary, "integrity_preflight_case_counts", Dict())
    integrity_errors = _int(get(integrity, "cases_with_errors", 0))
    environment = get(summary, "environment_fingerprint", nothing)
    if errors > 0
        push!(findings, _finding("campaign_case_errors", "error",
            "$errors benchmark case(s) ended with an execution error.",
            Dict("error_case_count" => errors);
            suggested_action = "Inspect the per-case records before interpreting aggregate findings."))
    end
    if integrity_errors > 0
        push!(findings, _finding("integrity_preflight_errors", "error",
            "$integrity_errors case(s) failed BMOPFTools integrity preflight.",
            Dict("cases_with_errors" => integrity_errors);
            suggested_action = "Resolve input integrity errors or exclude those cases explicitly."))
    end
    skipped > 0 && push!(findings, _finding("campaign_cases_skipped", "warning",
        "$skipped benchmark case(s) were skipped and do not contribute observations.",
        Dict("skipped_case_count" => skipped)))
    if case_count == 0
        push!(findings, _finding("campaign_empty", "warning",
            "The summary contains no case records.", Dict("summary_path" => path);
            suggested_action = "Run at least one explicitly selected BMOPF case."))
    end
    if !(environment isa AbstractString) || isempty(environment)
        push!(findings, _finding("environment_fingerprint_missing", "warning",
            "The campaign has no environment fingerprint.", Dict("summary_path" => path);
            suggested_action = "Use the provenance-aware BMOPF runner and preserve its environment metadata."))
    end

    mapping = get(summary, "saved_result_mapping_case_counts", Dict())
    saved_cases = _int(get(mapping, "saved_result_cases", 0))
    fallback = _int(get(mapping, "fallback_coordinate_count", 0))
    fraction = _float(get(mapping, "mapping_fraction_minimum", nothing))
    unmapped_registered = _int(get(mapping, "unmapped_registered_coordinate_count", 0))
    unresolved_records = _int(get(mapping, "unresolved_saved_record_count", 0))
    unresolved_families = get(mapping, "unresolved_record_family_counts", Dict())
    mapping_warnings = _int(get(mapping, "mapping_warning_case_count", 0))
    saved_model_ready = saved_cases == 0 ||
                        (fallback == 0 && unmapped_registered == 0 &&
                         !isnothing(fraction) && fraction >= 1.0)
    saved_export_ready = saved_model_ready && unresolved_records == 0
    if saved_cases > 0 && !saved_model_ready
        push!(findings, _finding("saved_result_mapping_incomplete", "error",
            "Saved-result observations are not fully mapped into model coordinates.",
            Dict("saved_result_cases" => saved_cases,
                 "fallback_coordinate_count" => fallback,
                 "unmapped_registered_coordinate_count" => unmapped_registered,
                 "mapping_fraction_minimum" => fraction);
            suggested_action = "Do not interpret saved-result feasibility or derivative fingerprints until mapping coverage is complete."))
    end
    unresolved_records > 0 && push!(findings, _finding("saved_result_unresolved_records", "warning",
        "Saved-result files contain records outside the mapped model-coordinate schema.",
        Dict("unresolved_saved_record_count" => unresolved_records,
             "unresolved_record_family_counts" => unresolved_families,
             "saved_result_cases" => saved_cases);
        suggested_action = "Treat mapped model-coordinate evidence as scoped; inspect the field-level mapping report before making whole-export claims."))
    mapping_warnings > 0 && push!(findings, _finding("saved_result_mapping_warnings", "warning",
        "The saved-result campaign contains adapter mapping warnings.",
        Dict("mapping_warning_case_count" => mapping_warnings)))

    dense = get(summary, "dense_rank_case_counts", Dict())
    dense_eligible = _int(get(dense, "eligible", 0))
    dense_unknown = _int(get(dense, "unknown", 0))
    dense_unknown > 0 && push!(findings, _finding("dense_rank_availability_unknown", "warning",
        "Some cases do not state whether dense rank analysis was available.",
        Dict("unknown_case_count" => dense_unknown);
        suggested_action = "Preserve the size guard and explicit dense-rank availability fields in the campaign output."))
    dense_ready = dense_eligible > 0
    !dense_ready && push!(findings, _finding("dense_rank_not_available", "warning",
        "No case in this campaign has an eligible dense-rank evaluation.",
        Dict("dense_rank_case_counts" => dense)))

    capability = get(summary, "component_rank_capability_counts", nothing)
    physical_ready = false
    if capability isa AbstractDict
        capability_cases = _int(get(capability, "profile_cases_with_capability_data", 0))
        unavailable = _int(get(capability, "expected_rank_unavailable_count_total", 0))
        physical_ready = capability_cases > 0 && unavailable == 0
        unavailable > 0 && push!(findings, _finding("component_expected_rank_unavailable", "warning",
            "Physical component-rank interpretation is unavailable for some components.",
            Dict("expected_rank_unavailable_count_total" => unavailable,
                 "profile_cases_with_capability_data" => capability_cases);
            suggested_action = "Add justified plugin-owned expected-rank or expected-mode declarations before assigning physical meaning."))
    else
        push!(findings, _finding("component_rank_capability_missing", "warning",
            "The campaign summary does not contain component-rank capability data.",
            Dict("summary_path" => path);
            suggested_action = "Regenerate profiles with the current serialized benchmark schema."))
    end

    profile_cases = _int(get(summary, "profile_case_count", 0))
    catalog_cases = _int(get(summary, "result_field_catalog_case_count", 0))
    attribution = get(summary, "feasibility_field_attribution_counts", nothing)
    attribution_cases = attribution isa AbstractDict ?
                        _int(get(attribution, "cases_with_attribution", 0)) : 0
    attribution_unsupported = attribution isa AbstractDict ?
                              _int(get(attribution, "unsupported_row_count_total", 0)) : 0
    catalog_ready = profile_cases == 0 || catalog_cases >= profile_cases
    attribution_ready = profile_cases == 0 || attribution_cases >= profile_cases
    !catalog_ready && push!(findings, _finding("result_field_catalog_missing", "warning",
        "Some profile cases do not carry the explicit BMOPF result-field catalog.",
        Dict("profile_case_count" => profile_cases,
             "catalog_case_count" => catalog_cases);
        suggested_action = "Regenerate profiles with the field-catalog-aware BMOPF adapter."
    ))
    !attribution_ready && push!(findings, _finding(
        "feasibility_field_attribution_missing", "warning",
        "Some profile cases do not carry BMOPF feasibility-field attribution.",
        Dict("profile_case_count" => profile_cases,
             "attribution_case_count" => attribution_cases);
        suggested_action = "Regenerate profiles with field-attribution enabled before comparing policy feasibility deltas."
    ))
    attribution_unsupported > 0 && push!(findings, _finding(
        "feasibility_field_attribution_support_incomplete", "warning",
        "Some violated rows have no usable Jacobian support entry for family attribution.",
        Dict("unsupported_row_count_total" => attribution_unsupported);
        suggested_action = "Inspect derivative failures and preserve the attribution's derivative-method provenance before assigning family meaning."
    ))

    return Dict{String,Any}(
        "summary_path" => path,
        "case_count" => case_count,
        "error_case_count" => errors,
        "skipped_case_count" => skipped,
        "readiness" => Dict(
            "generic_observations" => errors == 0 && integrity_errors == 0 &&
                                      case_count > 0 && environment isa AbstractString && !isempty(environment),
            "saved_result_interpretation" => saved_model_ready,
            "saved_result_full_export_interpretation" => saved_export_ready,
            "dense_rank_interpretation" => dense_ready,
            "physical_component_rank_interpretation" => physical_ready,
            "result_field_catalog" => catalog_ready,
            "feasibility_field_attribution" => attribution_ready,
        ),
        "findings" => findings,
    )
end

function _validate_comparison(path, comparison)
    findings = Any[]
    missing = _int(get(comparison, "missing_left_case_count", 0)) +
              _int(get(comparison, "missing_right_case_count", 0))
    errors = _int(get(comparison, "comparison_error_count", 0))
    pairs = _int(get(comparison, "paired_case_count", 0))
    cases = get(comparison, "cases", Any[])
    nonzero_feasibility = 0
    total_feasibility_delta = 0
    maximum_feasibility_delta = 0
    for case in cases
        delta = _int(get(case, "feasibility_violation_delta_right_minus_left", 0))
        total_feasibility_delta += delta
        maximum_feasibility_delta = max(maximum_feasibility_delta, abs(delta))
        nonzero_feasibility += !iszero(delta)
    end
    missing > 0 && push!(findings, _finding("paired_cases_missing", "error",
        "The paired campaigns do not cover the same snapshot set.",
        Dict("missing_case_count" => missing);
        suggested_action = "Align case selectors and rerun both policies over the same snapshots."))
    errors > 0 && push!(findings, _finding("paired_comparison_errors", "error",
        "Some paired policy comparisons could not be computed.",
        Dict("comparison_error_count" => errors)))
    pairs == 0 && push!(findings, _finding("paired_comparison_empty", "warning",
        "No paired cases were compared.", Dict("summary_path" => path)))
    nonzero_feasibility > 0 && push!(findings, _finding(
        "paired_policy_feasibility_delta", "warning",
        "The paired policies produce different constraint-feasibility fingerprints.",
        Dict("nonzero_case_count" => nonzero_feasibility,
             "total_delta_right_minus_left" => total_feasibility_delta,
             "maximum_absolute_case_delta" => maximum_feasibility_delta);
        suggested_action = "Treat the policy comparison as an empirical formulation/unit hypothesis; inspect the affected cases and field-ratio evidence before generalizing."))
    return Dict{String,Any}(
        "summary_path" => path,
        "paired_case_count" => pairs,
        "readiness" => Dict("paired_policy_alignment" => missing == 0 && errors == 0 && pairs > 0),
        "policy_feasibility_agreement" => nonzero_feasibility == 0,
        "nonzero_feasibility_case_count" => nonzero_feasibility,
        "findings" => findings,
    )
end

function _validate_solver_matrix(path, matrix)
    findings = Any[]
    solver_summaries = get(matrix, "solver_summaries", Dict())
    solver_count = length(solver_summaries)
    successful = 0
    for (solver, summary) in solver_summaries
        statuses = get(summary, "status_counts", Dict())
        ok = _int(get(statuses, "ok", 0))
        successful += ok > 0
        ok == 0 && push!(findings, _finding("solver_matrix_no_success", "error",
            "Solver $(solver) produced no successful case in the matrix.",
            Dict("solver" => String(solver), "status_counts" => statuses)))
    end
    comparisons = get(matrix, "comparisons", Dict())
    comparison_count = 0
    for (name, comparison) in comparisons
        status = get(comparison, "status", "ok")
        status != "ok" && push!(findings, _finding("solver_matrix_comparison_error", "error",
            "Solver comparison $(name) did not complete successfully.",
            Dict("comparison" => String(name), "status" => status)))
        nested = get(comparison, "comparison", nothing)
        records = nested isa AbstractDict ?
                  _int(get(nested, "case_count", 0)) :
                  length(get(comparison, "comparisons", Any[]))
        comparison_count += records
        records == 0 && push!(findings, _finding("solver_matrix_empty_comparison", "warning",
            "Solver comparison $(name) contains no paired case records.", Dict("comparison" => String(name))))
    end
    comparison_count == 0 && push!(findings, _finding("solver_matrix_no_pairs", "warning",
        "The solver matrix has no paired comparison records.", Dict("summary_path" => path)))
    return Dict{String,Any}(
        "summary_path" => path,
        "solver_count" => solver_count,
        "successful_solver_count" => successful,
        "paired_comparison_count" => comparison_count,
        "readiness" => Dict(
            "solver_matrix_success" => solver_count > 0 && successful == solver_count,
            "solver_matrix_alignment" => comparison_count > 0,
        ),
        "findings" => findings,
    )
end

function main()
    length(ARGS) >= 2 || error("usage: validate_bmopf_campaign.jl output.json summary1.json ...")
    output_path = abspath(first(ARGS))
    campaign_reports = Any[]
    comparison_reports = Any[]
    solver_matrix_reports = Any[]
    all_findings = Any[]
    environments = Any[]
    for raw_path in ARGS[2:end]
        path = abspath(raw_path)
        summary = _load(path)
        if haskey(summary, "solver_summaries") && haskey(summary, "comparisons")
            report = _validate_solver_matrix(path, summary)
            push!(solver_matrix_reports, report)
        elseif haskey(summary, "missing_left_case_count") || haskey(summary, "paired_case_count")
            report = _validate_comparison(path, summary)
            push!(comparison_reports, report)
        else
            report = _validate_campaign(path, summary)
            push!(campaign_reports, report)
            value = get(summary, "environment_fingerprint", nothing)
            value isa AbstractString && !isempty(value) && push!(environments, value)
        end
        append!(all_findings, report["findings"])
    end
    unique_environments = unique(environments)
    length(unique_environments) > 1 && push!(all_findings, _finding(
        "environment_fingerprint_mismatch", "warning",
        "Input summaries were produced under different environment fingerprints.",
        Dict("environment_fingerprints" => unique_environments);
        suggested_action = "Compare only after explicitly treating package, Julia, solver, and machine differences as campaign context."))
    error_count = count(finding -> finding["severity"] == "error", all_findings)
    warning_count = count(finding -> finding["severity"] == "warning", all_findings)
    status = error_count > 0 ? "fail" : warning_count > 0 ? "warn" : "pass"
    payload = Dict{String,Any}(
        "report_version" => "bmopf-campaign-validation-v1",
        "status" => status,
        "error_count" => error_count,
        "warning_count" => warning_count,
        "campaign_reports" => campaign_reports,
        "comparison_reports" => comparison_reports,
        "solver_matrix_reports" => solver_matrix_reports,
        "findings" => all_findings,
        "interpretation" => "Trust-gate validation only; warnings identify unavailable or conditional evidence and are not model-quality scores.",
    )
    write(output_path, JSON.json(payload))
    println("wrote BMOPF campaign validation report to $output_path")
end

main()
