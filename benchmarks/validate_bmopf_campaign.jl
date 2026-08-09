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

function _dict(value)
    value isa AbstractDict || return Dict{String,Any}()
    return Dict{String,Any}(String(key) => item for (key, item) in value)
end

function _count_map(value)
    result = Dict{String,Int}()
    value isa AbstractDict || return result
    for (key, item) in value
        count = _int(item, 0)
        count >= 0 && (result[String(key)] = count)
    end
    return result
end

function _metric_value(value; field = "maximum")
    value isa AbstractDict && return _int(get(value, field, 0), 0)
    return _int(value, 0)
end

function _metric_sample_count(value)
    value isa AbstractDict && return max(0, _int(get(value, "sample_count", 0), 0))
    return 0
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
    trusted_points = get(summary, "trusted_point_selection_counts", nothing)
    trusted_point_ready = true
    if trusted_points isa AbstractDict
        selected_trusted = _int(get(trusted_points,
            "profile_cases_with_selected_trusted_points", 0))
        missing_trust_metadata = _int(get(trusted_points,
            "profile_cases_missing_selection_metadata", 0))
        trusted_point_ready = profile_cases == 0 ||
                             (selected_trusted == profile_cases && missing_trust_metadata == 0)
        !trusted_point_ready && push!(findings, _finding(
            "trusted_solver_point_coverage_incomplete", "warning",
            "Not every profiled case has a selected complete solver-iterate or solver-result point.",
            Dict("profile_case_count" => profile_cases,
                 "profile_cases_with_selected_trusted_points" => selected_trusted,
                 "profile_cases_missing_selection_metadata" => missing_trust_metadata),
            suggested_action = "Use complete solver iterates/results for physical or cross-case claims, or retain the campaign as initialization-scoped evidence."
        ))
    end
    catalog_cases = _int(get(summary, "result_field_catalog_case_count", 0))
    registry = get(summary, "constraint_registry_coverage_counts", nothing)
    registry_cases = registry isa AbstractDict ?
                     _int(get(registry, "cases_with_coverage", 0)) : 0
    registry_rows = registry isa AbstractDict ?
                    _int(get(registry, "constraint_row_count_total", 0)) : 0
    registry_registered = registry isa AbstractDict ?
                          _int(get(registry, "registered_constraint_row_count_total", 0)) : 0
    registry_unregistered = registry isa AbstractDict ?
                            _int(get(registry, "unregistered_constraint_row_count_total", 0)) : 0
    attribution = get(summary, "feasibility_field_attribution_counts", nothing)
    attribution_cases = attribution isa AbstractDict ?
                        _int(get(attribution, "cases_with_attribution", 0)) : 0
    attribution_unsupported = attribution isa AbstractDict ?
                              _int(get(attribution, "unsupported_row_count_total", 0)) : 0
    has_registry_evidence = registry_cases > 0
    semantic_registered = has_registry_evidence ? registry_registered :
        (attribution isa AbstractDict ?
         _int(get(attribution, "registered_constraint_row_count_total", 0)) : 0)
    semantic_unregistered = has_registry_evidence ? registry_unregistered :
        (attribution isa AbstractDict ?
         _int(get(attribution, "unregistered_constraint_row_count_total", 0)) : 0)
    semantic_model_rows = has_registry_evidence ? registry_rows :
        (attribution isa AbstractDict ?
         _int(get(attribution, "model_constraint_row_count_total", 0)) : 0)
    semantic_model_registered = has_registry_evidence ? registry_registered :
        (attribution isa AbstractDict ?
         _int(get(attribution, "model_registered_constraint_row_count_total", 0)) : 0)
    semantic_model_unregistered = has_registry_evidence ? registry_unregistered :
        (attribution isa AbstractDict ?
         _int(get(attribution, "model_unregistered_constraint_row_count_total", 0)) : 0)
    catalog_ready = profile_cases == 0 || catalog_cases >= profile_cases
    attribution_ready = profile_cases == 0 || attribution_cases >= profile_cases
    registry_ready = profile_cases == 0 || registry_cases == 0 ||
                     registry_cases >= profile_cases
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
    !registry_ready && push!(findings, _finding(
        "constraint_registry_coverage_missing", "warning",
        "Only part of the profile campaign carries the standalone all-row constraint-registry report.",
        Dict("profile_case_count" => profile_cases,
             "registry_coverage_case_count" => registry_cases);
        suggested_action = "Regenerate the mixed campaign so every profile carries bmopf_constraint_registry_coverage before making whole-campaign semantic claims."
    ))
    attribution_unsupported > 0 && push!(findings, _finding(
        "feasibility_field_attribution_support_incomplete", "warning",
        "Some violated rows have no usable Jacobian support entry for family attribution.",
        Dict("unsupported_row_count_total" => attribution_unsupported);
        suggested_action = "Inspect derivative failures and preserve the attribution's derivative-method provenance before assigning family meaning."
    ))
    semantic_ready = profile_cases == 0 ||
                     (has_registry_evidence ? registry_cases >= profile_cases :
                      attribution_cases >= profile_cases)
    semantic_unregistered > 0 && push!(findings, _finding(
        "constraint_semantic_registry_boundary", "warning",
        has_registry_evidence ?
        "Some evaluated rows are not represented by a registered BMOPFTools constraint key." :
        "Some violated rows are not represented by a registered BMOPFTools constraint key.",
        Dict("registered_constraint_row_count_total" => semantic_registered,
             "unregistered_constraint_row_count_total" => semantic_unregistered);
        suggested_action = "Treat registered semantic labels as authoritative only for those rows; add public constraint registrations before assigning device-level physical meaning to the remainder."
    ))
    semantic_model_unregistered > 0 && push!(findings, _finding(
        "constraint_semantic_registry_model_boundary", "warning",
        "The evaluated model contains scalar constraint rows without a registered BMOPFTools semantic key.",
        Dict("model_constraint_row_count_total" => semantic_model_rows,
             "model_registered_constraint_row_count_total" => semantic_model_registered,
             "model_unregistered_constraint_row_count_total" => semantic_model_unregistered),
        suggested_action = "Use the registered-family counts for scoped interpretation and extend BMOPFTools registrations before making whole-model device claims."
    ))
    semantic_model_ready = profile_cases == 0 ||
                           (semantic_model_rows > 0 && semantic_model_unregistered == 0)

    readiness = Dict{String,Any}(
        "generic_observations" => errors == 0 && integrity_errors == 0 &&
                                  case_count > 0 && environment isa AbstractString && !isempty(environment),
        "saved_result_interpretation" => saved_model_ready,
        "saved_result_full_export_interpretation" => saved_export_ready,
        "dense_rank_interpretation" => dense_ready,
        "physical_component_rank_interpretation" => physical_ready,
        "result_field_catalog" => catalog_ready,
        "feasibility_field_attribution" => attribution_ready,
        "trusted_solver_point_coverage" => trusted_point_ready,
        "constraint_semantic_attribution" => semantic_ready,
        "constraint_semantic_registry_model_coverage" => semantic_model_ready,
    )
    perturbation_corpus = get(summary, "perturbation_corpus", nothing)
    if perturbation_corpus isa AbstractDict
        perturbation_report = _validate_perturbation_corpus(path, perturbation_corpus)
        readiness["perturbation_corpus"] = get(
            get(perturbation_report, "readiness", Dict()), "corpus_observations", false,
        )
        append!(findings, get(perturbation_report, "findings", Any[]))
    end
    if haskey(summary, "family_perturbation_status_counts") ||
       haskey(summary, "family_perturbations_enabled")
        perturbation_status = get(summary, "family_perturbation_status_counts", Dict())
        perturbation_status isa AbstractDict || (perturbation_status = Dict())
        variant_count = sum(_int(value) for value in values(perturbation_status))
        variant_errors = _int(get(perturbation_status, "error", 0))
        raw_enabled = get(summary, "family_perturbations_enabled", false)
        enabled = raw_enabled === true ||
            lowercase(string(raw_enabled)) in ("true", "1", "yes", "on")
        if enabled && variant_count == 0
            push!(findings, _finding("family_perturbation_empty", "warning",
                "Family perturbations were enabled but no variant records were completed.",
                Dict("status_counts" => perturbation_status);
                suggested_action = "Inspect the per-case solver-trace records and child-process timeout evidence."))
        end
        variant_errors > 0 && push!(findings, _finding(
            "family_perturbation_variant_errors", "warning",
            "Some model-level family perturbation variants ended with execution errors.",
            Dict("error_variant_count" => variant_errors,
                 "status_counts" => perturbation_status);
            suggested_action = "Treat family comparisons as partial until the failed variants are inspected or explicitly excluded."))
        readiness["model_family_perturbation"] = enabled &&
            variant_count > 0 && variant_errors == 0
        readiness["model_family_perturbation_variant_count"] = variant_count
    end

    return Dict{String,Any}(
        "summary_path" => path,
        "case_count" => case_count,
        "error_case_count" => errors,
        "skipped_case_count" => skipped,
        "readiness" => readiness,
        "findings" => findings,
    )
end

"""Validate typed Volt-var/Volt-watt evidence without interpreting it as a score.

Controller observations are deliberately treated as a separate trust gate. A
campaign with no controller devices has *missing* coverage, not a clean result;
proxy voltage semantics are useful but remain conditional evidence.
"""
function _validate_controller_report(path, report; scope = "controller_report")
    findings = Any[]
    observations = max(0, _int(get(report, "observation_count", 0), 0))
    statuses = _count_map(get(report, "status_counts", Dict()))
    semantics = _count_map(get(report, "monitor_semantics_counts", Dict()))
    finite = get(statuses, "finite", 0)
    nonfinite = sum(value for (key, value) in statuses
                    if lowercase(key) in ("nonfinite", "non_finite", "nan", "infinite", "nonfinite_status"); init = 0)
    invalid = sum(value for (key, value) in statuses
                  if lowercase(key) in ("invalid_profile", "invalid", "undefined"); init = 0)
    exact = get(semantics, "exact_public_monitored_voltage", 0)
    proxy = get(semantics, "terminal_pair_magnitude_proxy", 0)
    unknown_semantics = max(0, observations - exact - proxy)
    equation_residual_violations = _int(
        get(report, "equation_residual_violation_count", 0), 0,
    )
    cap_violations = _int(get(report, "cap_violation_count", 0), 0)
    registry = get(report, "semantic_row_registry", Dict())
    registry isa AbstractDict || (registry = Dict())
    registry_status = String(get(registry, "status", "unavailable"))
    unmatched_registry = _int(get(registry, "unmatched_violation_count", 0), 0)

    observations == 0 && push!(findings, _finding(
        "controller_curve_coverage_missing", "warning",
        "No typed controller-curve observations were retained for this report.",
        Dict("scope" => scope, "observation_count" => observations,
             "report_path" => path);
        suggested_action = "Confirm that the selected case contains controller devices and that operating-point capture was enabled."
    ))
    nonfinite > 0 && push!(findings, _finding(
        "controller_curve_nonfinite_observations", "error",
        "Some controller-curve observations have non-finite numerical status.",
        Dict("scope" => scope, "nonfinite_observation_count" => nonfinite,
             "status_counts" => statuses);
        suggested_action = "Inspect the associated operating point and curve parameters before trusting derivative or solver-trace interpretations."
    ))
    invalid > 0 && push!(findings, _finding(
        "controller_curve_invalid_profiles", "warning",
        "Some controller curves were classified as invalid profiles.",
        Dict("scope" => scope, "invalid_profile_count" => invalid,
             "status_counts" => statuses);
        suggested_action = "Check breakpoint ordering, smoothing parameters, and device-base metadata."
    ))
    proxy > 0 && push!(findings, _finding(
        "controller_curve_proxy_monitoring", "warning",
        "Some controller observations use a terminal-pair voltage proxy rather than an exact public monitored-voltage field.",
        Dict("scope" => scope, "proxy_observation_count" => proxy,
             "exact_observation_count" => exact, "monitor_semantics_counts" => semantics);
        suggested_action = "Use proxy observations for numerical triage only until the public monitored-voltage mapping is verified."
    ))
    unknown_semantics > 0 && push!(findings, _finding(
        "controller_curve_monitor_coverage_unknown", "warning",
        "Some controller observations do not declare their voltage-monitor semantics.",
        Dict("scope" => scope, "unknown_semantics_count" => unknown_semantics,
             "monitor_semantics_counts" => semantics);
        suggested_action = "Regenerate the report with the typed controller observation schema."
    ))
    finite < observations && observations > 0 && nonfinite == 0 && push!(findings, _finding(
        "controller_curve_status_coverage_incomplete", "warning",
        "Not every retained controller observation has finite status.",
        Dict("scope" => scope, "observation_count" => observations,
             "finite_observation_count" => finite, "status_counts" => statuses);
        suggested_action = "Treat controller evidence as conditional until every observation has an explicit finite or diagnosed status."
    ))
    equation_residual_violations > 0 && push!(findings, _finding(
        "controller_curve_equation_residuals_exceed_tolerance", "warning",
        "Some device-level Volt-var equation residuals exceed the declared controller tolerance.",
        Dict("scope" => scope,
             "equation_residual_violation_count" => equation_residual_violations,
             "affected_components" => get(report,
                 "equation_residual_violation_components", Dict()),
             "residual_tolerance" => get(report, "residual_tolerance", nothing));
        suggested_action = "Inspect the affected device and exact constraint metadata before interpreting the controller slope or solver residual."
    ))
    cap_violations > 0 && push!(findings, _finding(
        "controller_curve_cap_violations", "warning",
        "Some device-level Volt-watt cap residuals are positive beyond the configured tolerance.",
        Dict("scope" => scope, "cap_violation_count" => cap_violations,
             "affected_components" => get(report, "cap_violation_components", Dict()),
             "residual_tolerance" => get(report, "residual_tolerance", nothing));
        suggested_action = "Inspect the affected device's active-power base, cap reference, and registered Volt-watt inequality."
    ))
    observations > 0 && registry_status == "unavailable" && push!(findings, _finding(
        "controller_curve_registry_unavailable", "warning",
        "Controller observations are present but no semantic-row registry was retained.",
        Dict("scope" => scope, "observation_count" => observations);
        suggested_action = "Regenerate the persistence/profile campaign with BMOPFTools semantic-row capture enabled."
    ))
    unmatched_registry > 0 && push!(findings, _finding(
        "controller_curve_registry_boundary", "warning",
        "Some controller residuals do not match a registered semantic row.",
        Dict("scope" => scope, "unmatched_violation_count" => unmatched_registry,
             "components_by_status" => get(registry, "components_by_status", Dict()));
        suggested_action = "Inspect the affected device/family crosswalk before assigning physical meaning to the residual."
    ))

    readiness = Dict{String,Any}(
        "observations_available" => observations > 0,
        "finite_observations" => observations > 0 && nonfinite == 0 && finite == observations,
        "exact_monitor_coverage" => observations > 0 && exact == observations,
        "proxy_monitoring_only" => observations > 0 && proxy == observations,
        "invalid_profiles_absent" => invalid == 0,
    )
    return Dict{String,Any}(
        "summary_path" => path,
        "scope" => scope,
        "observation_count" => observations,
        "status_counts" => statuses,
        "monitor_semantics_counts" => semantics,
        "equation_residual_violation_count" => equation_residual_violations,
        "cap_violation_count" => cap_violations,
        "semantic_row_registry" => registry,
        "equation_residual_violation_components" => get(report,
            "equation_residual_violation_components", Dict()),
        "cap_violation_components" => get(report,
            "cap_violation_components", Dict()),
        "readiness" => readiness,
        "findings" => findings,
    )
end

function _validate_controller_campaign(path, summary)
    findings = Any[]
    reports = get(summary, "reports", Any[])
    reports isa AbstractVector || (reports = Any[])
    report_views = Any[]
    for (index, raw_report) in enumerate(reports)
        report = raw_report isa AbstractDict ? raw_report : Dict{String,Any}()
        view = _validate_controller_report(path, report; scope = "report_$index")
        push!(report_views, view)
        append!(findings, view["findings"])
    end
    isempty(reports) && push!(findings, _finding(
        "controller_curve_campaign_empty", "warning",
        "The controller campaign summary contains no report records.",
        Dict("summary_path" => path);
        suggested_action = "Provide at least one saved-result or trace report with typed controller snapshots."
    ))
    return Dict{String,Any}(
        "summary_path" => path,
        "report_count" => length(reports),
        "reports" => report_views,
        "readiness" => Dict(
            "controller_curve_observations" => !isempty(reports) && all(
                get(get(view, "readiness", Dict()), "observations_available", false)
                for view in report_views),
            "controller_curve_finite_observations" => !isempty(reports) && all(
                get(get(view, "readiness", Dict()), "finite_observations", false)
                for view in report_views),
            "controller_curve_exact_monitor_coverage" => !isempty(reports) && all(
                get(get(view, "readiness", Dict()), "exact_monitor_coverage", false)
                for view in report_views),
        ),
        "findings" => findings,
    )
end

function _controller_snapshot_summary(summary)
    observations = 0
    statuses = Dict{String,Int}()
    semantics = Dict{String,Int}()
    equation_residual_violations = 0
    cap_violations = 0
    snapshots = get(summary, "controller_curve_snapshots", Any[])
    snapshots isa AbstractVector || (snapshots = Any[])
    for raw_snapshot in snapshots
        snapshot = raw_snapshot isa AbstractDict ? raw_snapshot : Dict{String,Any}()
        raw_observations = get(snapshot, "observations", Any[])
        raw_observations isa AbstractVector || continue
        for raw_observation in raw_observations
            observation = raw_observation isa AbstractDict ? raw_observation : Dict{String,Any}()
            observations += 1
            status = get(observation, "status", nothing)
            status === nothing || (key = String(status); statuses[key] = get(statuses, key, 0) + 1)
            semantics_value = get(observation, "monitor_semantics", nothing)
            semantics_value === nothing || begin
                key = String(semantics_value)
                semantics[key] = get(semantics, key, 0) + 1
            end
            metadata = get(observation, "metadata", Dict())
            metadata isa AbstractDict || (metadata = Dict())
            tolerance = try
                parse(Float64, String(get(metadata, "controller_residual_tolerance", "1.0e-6")))
            catch
                1.0e-6
            end
            residual = _float(get(observation, "equation_residual", nothing))
            !isnothing(residual) && abs(residual) > tolerance &&
                (equation_residual_violations += 1)
            cap = _float(get(observation, "cap_violation", nothing))
            !isnothing(cap) && cap > tolerance && (cap_violations += 1)
        end
    end
    return Dict{String,Any}(
        "observation_count" => observations,
        "status_counts" => statuses,
        "monitor_semantics_counts" => semantics,
        "equation_residual_violation_count" => equation_residual_violations,
        "cap_violation_count" => cap_violations,
    )
end

function _validate_solver_trace(path, summary)
    findings = Any[]
    successful_cases = _int(get(summary, "successful_case_count", 0))
    process_health = get(summary, "process_health_counts", nothing)
    runner_version = lowercase(String(get(summary, "runner_version", "")))
    isolated_runner = occursin("isolated", runner_version)
    process_health_ready = false
    if process_health isa AbstractDict
        process_exits = _int(get(process_health, "process_exit_case_count", 0))
        process_timeouts = _int(get(process_health, "process_timeout_case_count", 0))
        wait_errors = _int(get(process_health, "process_wait_error_case_count", 0))
        nonzero_exits = _int(get(process_health, "nonzero_process_exit_case_count", 0))
        process_health_ready = process_exits == 0 && process_timeouts == 0 &&
                               wait_errors == 0 && nonzero_exits == 0
        process_exits > 0 && push!(findings, _finding(
            "solver_trace_process_exit", "error",
            "One or more isolated solver children terminated before producing a result profile.",
            Dict("process_exit_case_count" => process_exits,
                 "nonzero_process_exit_case_count" => nonzero_exits,
                 "process_log_case_count" => _int(get(process_health, "process_log_case_count", 0))),
            suggested_action = "Inspect the preserved per-case process logs and reduce the case/trace scope before attributing numerical meaning to the campaign."
        ))
        process_timeouts > 0 && push!(findings, _finding(
            "solver_trace_process_timeout", "error",
            "One or more solver children exceeded the configured isolation timeout.",
            Dict("process_timeout_case_count" => process_timeouts),
            suggested_action = "Treat the affected cases as incomplete and inspect native solver output before increasing the timeout."
        ))
        wait_errors > 0 && push!(findings, _finding(
            "solver_trace_process_wait_error", "error",
            "The launcher could not obtain a normal exit status for one or more solver children.",
            Dict("process_wait_error_case_count" => wait_errors),
            suggested_action = "Inspect the process log and launcher index; a native crash or forced termination may have occurred."
        ))
    elseif isolated_runner
        push!(findings, _finding(
            "solver_trace_process_health_missing", "warning",
            "The solver-trace summary does not contain isolated child-process health fields.",
            Dict("summary_path" => path),
            suggested_action = "Regenerate the campaign with the isolated launcher or current solver-trace summarizer."
        ))
    else
        # In-process traces predate the isolated launcher and have no child
        # process boundary to validate.  Keep their solver evidence usable,
        # while making the absence of launcher health explicit in the summary
        # schema rather than treating it as a solver failure.
        process_health_ready = true
    end
    successful_cases == 0 && push!(findings, _finding(
        "solver_trace_no_successful_cases", "warning",
        "The solver-trace campaign contains no successful solver-result profiles.",
        Dict("summary_path" => path,
             "status_counts" => get(summary, "status_counts", Dict()));
        suggested_action = "Treat the campaign as build/guard evidence only; lower the size guard or resolve solver/process failures before interpreting numerical behavior."
    ))
    trusted_points = get(summary, "trusted_point_selection_counts", nothing)
    trusted_result_cases = 0
    incomplete_result_cases = 0
    missing_result_trust = 0
    trusted_iterate_bindings = 0
    incomplete_iterate_bindings = 0
    nonfinite_iterate_bindings = 0
    if trusted_points isa AbstractDict
        trusted_result_cases = _int(get(trusted_points,
            "successful_cases_with_trusted_solver_result_points", 0))
        incomplete_result_cases = _int(get(trusted_points,
            "successful_cases_with_incomplete_solver_result_points", 0))
        missing_result_trust = _int(get(trusted_points,
            "successful_cases_missing_solver_result_trust_metadata", 0))
        trusted_iterate_bindings = _int(get(trusted_points,
            "trusted_solver_iterate_binding_count", 0))
        incomplete_iterate_bindings = _int(get(trusted_points,
            "incomplete_solver_iterate_binding_count", 0))
        nonfinite_iterate_bindings = _int(get(trusted_points,
            "nonfinite_solver_iterate_binding_count", 0))
    else
        push!(findings, _finding(
            "trusted_solver_result_point_coverage_missing", "warning",
            "The solver-trace summary does not contain the trusted-point coverage fields.",
            Dict("summary_path" => path);
            suggested_action = "Regenerate solver-trace summaries with the current point-provenance schema."
        ))
    end
    trusted_result_ready = successful_cases == 0 ||
                           (trusted_result_cases == successful_cases &&
                            incomplete_result_cases == 0 && missing_result_trust == 0)
    !trusted_result_ready && push!(findings, _finding(
        "trusted_solver_result_point_coverage_incomplete", "warning",
        "Not every successful solver-trace case has one complete finite solver-result point selected by the trust policy.",
        Dict("successful_case_count" => successful_cases,
             "successful_cases_with_trusted_solver_result_points" => trusted_result_cases,
             "successful_cases_with_incomplete_solver_result_points" => incomplete_result_cases,
             "successful_cases_missing_solver_result_trust_metadata" => missing_result_trust);
        suggested_action = "Regenerate the trace campaign with the current serializer, and do not use older or incomplete result records for physical or cross-case claims."
    ))
    endpoint_conditioned_cases = Any[]
    for raw_case in get(summary, "cases", Any[])
        raw_case isa AbstractDict || continue
        termination = lowercase(String(get(raw_case, "termination", "")))
        termination in ("iteration_limit", "time_limit", "resource_limit",
                        "restoration_failed") || continue
        semantic_codes = Dict{String,Any}()
        merge!(semantic_codes, _dict(get(raw_case,
            "bmopf_profile_finding_codes", nothing)))
        merge!(semantic_codes, _dict(get(raw_case,
            "bmopf_context_finding_codes", nothing)))
        isempty(semantic_codes) && continue
        push!(endpoint_conditioned_cases, Dict(
            "snapshot" => get(raw_case, "snapshot", get(raw_case, "name", nothing)),
            "termination" => termination,
            "status" => get(raw_case, "status", nothing),
            "finding_codes" => semantic_codes,
        ))
    end
    !isempty(endpoint_conditioned_cases) && push!(findings, _finding(
        "solver_trace_endpoint_conditioned_semantics", "info",
        "Semantic findings were evaluated at solver endpoints that did not reach a successful termination.",
        Dict("summary_path" => path,
             "endpoint_conditioned_case_count" => length(endpoint_conditioned_cases),
             "cases" => endpoint_conditioned_cases);
        suggested_action = "Repeat the policy with a sufficient iteration/time budget or compare it with a trusted saved point before assigning formulation meaning."
    ))
    nonfinite_iterate_bindings > 0 && push!(findings, _finding(
        "trusted_solver_iterate_nonfinite", "error",
        "The solver trace contains callback points with non-finite coordinates.",
        Dict("nonfinite_solver_iterate_binding_count" => nonfinite_iterate_bindings);
        suggested_action = "Exclude the affected iterate snapshots and inspect the solver callback state before interpreting trace transitions."
    ))
    incomplete_iterate_bindings > 0 && push!(findings, _finding(
        "trusted_solver_iterate_coverage_incomplete", "warning",
        "Some solver-iterate bindings are incomplete under the point provenance policy.",
        Dict("incomplete_solver_iterate_binding_count" => incomplete_iterate_bindings);
        suggested_action = "Use only complete finite callback points for point-local diagnostics; metric-only trace evidence may still be retained."
    ))
    source_snapshots = get(summary, "source_snapshot_counts", nothing)
    source_snapshot_ready = false
    if source_snapshots isa AbstractDict
        preserved = _int(get(source_snapshots,
            "successful_cases_with_preserved_source_snapshot", 0))
        missing = _int(get(source_snapshots,
            "successful_cases_missing_source_snapshot", 0))
        source_snapshot_ready = successful_cases == 0 ||
                                (preserved == successful_cases && missing == 0)
        !source_snapshot_ready && push!(findings, _finding(
            "solver_trace_source_snapshot_coverage_incomplete", "warning",
            "Some successful solver-trace cases do not preserve the exact input deck used for the run.",
            Dict("successful_case_count" => successful_cases,
                 "successful_cases_with_preserved_source_snapshot" => preserved,
                 "successful_cases_missing_source_snapshot" => missing);
            suggested_action = "Regenerate the trace campaign with source snapshots enabled before making source-dependent physical claims."
        ))
    else
        push!(findings, _finding(
            "solver_trace_source_snapshot_coverage_missing", "warning",
            "The solver-trace summary does not contain source-snapshot coverage fields.",
            Dict("summary_path" => path);
            suggested_action = "Regenerate solver-trace summaries with the current reproducibility schema."
        ))
    end
    schema_coverage = get(summary, "source_schema_coverage", nothing)
    physical_metadata_ready = false
    if schema_coverage isa AbstractDict
        physical_warning_count = _int(get(schema_coverage,
            "physical_metadata_warning_count", 0))
        complete_cases = _int(get(schema_coverage,
            "successful_cases_with_complete_physical_metadata", 0))
        incomplete_cases = _int(get(schema_coverage,
            "successful_cases_with_incomplete_physical_metadata", 0))
        missing_schema_cases = _int(get(schema_coverage,
            "successful_cases_missing_physical_metadata_schema", 0))
        physical_metadata_ready = successful_cases == 0 ||
                                  (complete_cases == successful_cases &&
                                   incomplete_cases == 0 && missing_schema_cases == 0 &&
                                   physical_warning_count == 0)
        !physical_metadata_ready && push!(findings, _finding(
            "solver_trace_physical_metadata_incomplete", "warning",
            "Some successful solver-trace cases retain dropped or unsupported physical/device metadata.",
            Dict("successful_case_count" => successful_cases,
                 "physical_metadata_warning_count" => physical_warning_count,
                 "successful_cases_with_complete_physical_metadata" => complete_cases,
                 "successful_cases_with_incomplete_physical_metadata" => incomplete_cases,
                 "successful_cases_missing_physical_metadata_schema" => missing_schema_cases,
                 "source_schema_warning_impact_counts" => get(schema_coverage,
                     "source_schema_warning_impact_counts", Dict()),
                 "source_schema_warning_policy_status_counts" => get(schema_coverage,
                     "source_schema_warning_policy_status_counts", Dict()));
            suggested_action = "Restore or explicitly map the affected source fields before interpreting physical modes, limits, or operating-point behavior."
        ))
    else
        push!(findings, _finding(
            "solver_trace_physical_metadata_coverage_missing", "warning",
            "The solver-trace summary does not contain physical-metadata coverage fields.",
            Dict("summary_path" => path);
            suggested_action = "Regenerate solver-trace summaries with the current source-schema policy.")
        )
    end
    observation_summary = get(summary, "controller_curve_trace_observation_counts", nothing)
    status_counts = _count_map(get(summary, "controller_curve_trace_status_counts", Dict()))
    semantics = _count_map(get(summary, "controller_curve_trace_monitor_semantics_counts", Dict()))
    observation_count = _metric_value(observation_summary; field = "maximum")
    nonfinite = sum(value for (key, value) in status_counts
                    if lowercase(key) in ("nonfinite", "non_finite", "nan", "infinite", "nonfinite_status"); init = 0)
    status_changes = _metric_value(get(summary, "controller_curve_trace_status_changes", 0))
    coverage_changes = _metric_value(get(summary, "controller_curve_trace_coverage_changes", 0))
    slope_changes = _metric_value(get(summary, "controller_curve_trace_slope_changes", 0))
    equation_residual_violations = _metric_value(
        get(summary, "controller_curve_trace_equation_residual_violation_counts", 0),
    )
    cap_violations = _metric_value(
        get(summary, "controller_curve_trace_cap_violation_counts", 0),
    )
    crosswalk = get(summary,
        "controller_curve_trace_violation_registry_crosswalk", Dict())
    crosswalk isa AbstractDict || (crosswalk = Dict())
    unregistered_components = String[]
    unavailable_components = String[]
    for (component, raw_entry) in crosswalk
        raw_entry isa AbstractDict || continue
        status = String(get(raw_entry, "status", "unknown"))
        status == "unregistered" || status == "not_found" ?
            push!(unregistered_components, String(component)) : nothing
        status == "unavailable" && push!(unavailable_components, String(component))
    end
    transition_records = get(summary, "controller_curve_trace_transition_metrics", Any[])
    transition_records isa AbstractVector || (transition_records = Any[])
    transitions = Any[]
    for raw_case in transition_records
        raw_case isa AbstractDict || continue
        for raw_transition in get(raw_case, "transitions", Any[])
            raw_transition isa AbstractDict && push!(transitions, raw_transition)
        end
    end
    residual_aligned = count(transition ->
        ((_float(get(transition, "local_slope_mean_delta", nothing)) !== nothing) &&
         (_float(get(transition, "solver_primal_infeasibility_delta", nothing)) !== nothing ||
          _float(get(transition, "solver_dual_infeasibility_delta", nothing)) !== nothing)),
        transitions,
    )
    conventions = String[]
    for raw_case in get(summary, "cases", Any[])
        raw_case isa AbstractDict || continue
        units = get(raw_case, "model_coordinate_units", nothing)
        units === nothing || push!(conventions, String(units))
    end
    conventions = sort!(unique(conventions))
    observation_count == 0 && push!(findings, _finding(
        "controller_curve_trace_coverage_missing", "warning",
        "The solver trace contains no retained typed controller observations.",
        Dict("summary_path" => path, "observation_counts" => observation_summary);
        suggested_action = "Enable controller operating-point capture for selected trace bindings."
    ))
    nonfinite > 0 && push!(findings, _finding(
        "controller_curve_trace_nonfinite_observations", "error",
        "The solver trace contains non-finite typed controller observations.",
        Dict("summary_path" => path, "nonfinite_observation_count" => nonfinite,
             "status_counts" => status_counts);
        suggested_action = "Do not compare trace transitions until the offending operating points are diagnosed."
    ))
    status_changes > 0 && push!(findings, _finding(
        "controller_curve_trace_status_transition", "warning",
        "Controller curve status changed across solver-trace snapshots.",
        Dict("summary_path" => path, "status_change_summary" => get(summary, "controller_curve_trace_status_changes", nothing),
             "finding_codes" => get(summary, "controller_curve_trace_finding_codes", Dict()));
        suggested_action = "Inspect the corresponding iteration/phase snapshots; a transition is numerical evidence, not a physical diagnosis."
    ))
    coverage_changes > 0 && push!(findings, _finding(
        "controller_curve_trace_coverage_transition", "warning",
        "Controller monitor coverage changed across solver-trace snapshots.",
        Dict("summary_path" => path, "coverage_change_summary" => get(summary, "controller_curve_trace_coverage_changes", nothing),
             "monitor_semantics_counts" => semantics);
        suggested_action = "Check whether the trace crossed a device activation or mapping boundary."
    ))
    slope_changes > 0 && push!(findings, _finding(
        "controller_curve_trace_slope_transition", "info",
        "Controller local slopes changed materially across solver-trace snapshots.",
        Dict("summary_path" => path, "slope_change_summary" => get(summary, "controller_curve_trace_slope_changes", nothing),
             "finding_codes" => get(summary, "controller_curve_trace_finding_codes", Dict()));
        suggested_action = "Compare slope transitions with breakpoint distance and solver residuals before attributing convergence effects."
    ))
    equation_residual_violations > 0 && push!(findings, _finding(
        "controller_curve_trace_equation_residuals_exceed_tolerance", "warning",
        "The solver trace contains device-level Volt-var residuals beyond the declared controller tolerance.",
        Dict("summary_path" => path,
             "equation_residual_violation_count" => equation_residual_violations,
             "affected_components" => get(summary,
                 "controller_curve_trace_equation_residual_violation_components", Dict()));
        suggested_action = "Inspect the affected trace snapshots and exact device constraint metadata."
    ))
    cap_violations > 0 && push!(findings, _finding(
        "controller_curve_trace_cap_violations", "warning",
        "The solver trace contains positive Volt-watt cap residuals beyond tolerance.",
        Dict("summary_path" => path, "cap_violation_count" => cap_violations,
             "affected_components" => get(summary,
                 "controller_curve_trace_cap_violation_components", Dict()));
        suggested_action = "Check active-power bases and registered Volt-watt inequality semantics before interpreting solver behavior."
    ))
    !isempty(unregistered_components) && push!(findings, _finding(
        "controller_curve_violation_registry_boundary", "warning",
        "Some localized controller residuals do not map to a registered BMOPFTools constraint row.",
        Dict("summary_path" => path,
             "unregistered_or_unmatched_components" => sort!(unregistered_components),
             "registry_crosswalk" => crosswalk);
        suggested_action = "Extend or verify BMOPFTools constraint registrations before assigning a physical equation-level interpretation."
    ))
    !isempty(unavailable_components) && push!(findings, _finding(
        "controller_curve_violation_registry_unavailable", "warning",
        "Localized controller residuals are present, but semantic row metadata was unavailable for the trace.",
        Dict("summary_path" => path,
             "components" => sort!(unavailable_components));
        suggested_action = "Retain the residual as numerical evidence and rerun with the semantic-row map enabled."
    ))
    !isempty(transitions) && push!(findings, _finding(
        "controller_curve_trace_residual_alignment", "info",
        "Controller transition records retain paired solver residual deltas for local correlation inspection.",
        Dict("summary_path" => path, "transition_count" => length(transitions),
             "transitions_with_slope_and_solver_residual_deltas" => residual_aligned,
             "coordinate_conventions" => conventions);
        suggested_action = "Inspect transition-level pairs; aligned changes are numerical association evidence, not a causal solver diagnosis."
    ))
    length(conventions) > 1 && push!(findings, _finding(
        "controller_curve_trace_coordinate_conventions_mixed", "warning",
        "A solver-trace summary mixes model coordinate conventions across cases.",
        Dict("summary_path" => path, "model_coordinate_units" => conventions);
        suggested_action = "Compare controller slopes and residuals only after grouping traces by coordinate convention."
    ))
    return Dict{String,Any}(
        "summary_path" => path,
        "observation_count" => observation_count,
        "status_counts" => status_counts,
        "monitor_semantics_counts" => semantics,
        "coordinate_conventions" => conventions,
        "transition_count" => length(transitions),
        "residual_aligned_transition_count" => residual_aligned,
        "equation_residual_violation_count" => equation_residual_violations,
        "cap_violation_count" => cap_violations,
        "violation_registry_crosswalk" => crosswalk,
        "trusted_point_selection_counts" => trusted_points,
        "transition_summaries" => Dict(
            "status" => get(summary, "controller_curve_trace_status_changes", nothing),
            "coverage" => get(summary, "controller_curve_trace_coverage_changes", nothing),
            "slope" => get(summary, "controller_curve_trace_slope_changes", nothing),
        ),
        "readiness" => Dict(
            "controller_curve_trace_observations" => observation_count > 0,
            "controller_curve_trace_finite_observations" => observation_count > 0 && nonfinite == 0,
            "trusted_solver_result_point_coverage" => trusted_result_ready,
            "solver_semantics_endpoint_trust" => isempty(endpoint_conditioned_cases),
            "trusted_solver_iterate_observations" => trusted_iterate_bindings > 0,
            "trusted_solver_iterate_finite" => nonfinite_iterate_bindings == 0,
            "source_snapshot_coverage" => source_snapshot_ready,
            "physical_metadata_complete" => physical_metadata_ready,
            "solver_result_observations" => successful_cases > 0,
            "solver_process_health" => process_health_ready,
        ),
        "findings" => findings,
    )
end

function _validate_trace_comparison(path, comparison)
    findings = Any[]
    records = get(comparison, "comparisons", Any[])
    records isa AbstractVector || (records = Any[])
    compared = 0
    for raw_record in records
        raw_record isa AbstractDict || continue
        nested = get(raw_record, "comparison", Dict())
        nested isa AbstractDict || continue
        trace = get(nested, "controller_curve_trace", Dict())
        trace isa AbstractDict || continue
        compared += 1
        available = _dict(get(trace, "available", Dict()))
        left_available = get(available, "left", false) === true
        right_available = get(available, "right", false) === true
        (!left_available || !right_available) && push!(findings, _finding(
            "controller_curve_trace_comparison_coverage_missing", "warning",
            "A paired solver-trace comparison is missing controller observations on one side.",
            Dict("case" => get(raw_record, "name", nothing), "available" => available);
            suggested_action = "Compare traces only after enabling the same controller capture policy on both sides."
        ))
        counts = _dict(get(trace, "observation_count", Dict()))
        left_count = _int(get(counts, "left", 0), 0)
        right_count = _int(get(counts, "right", 0), 0)
        left_available && right_available && left_count != right_count && push!(findings, _finding(
            "controller_curve_trace_comparison_observation_mismatch", "warning",
            "Paired traces retained different numbers of controller observations.",
            Dict("case" => get(raw_record, "name", nothing), "left_count" => left_count,
                 "right_count" => right_count);
            suggested_action = "Align selected trace bindings before interpreting scale or transition differences."
        ))
        slope = _dict(get(trace, "slope_changes", Dict()))
        coverage = _dict(get(trace, "coverage_changes", Dict()))
        status = _dict(get(trace, "status_changes", Dict()))
        any(_int(get(map, side, 0), 0) > 0 for map in (slope, coverage, status) for side in ("left", "right")) && push!(findings, _finding(
            "controller_curve_trace_comparison_transition", "info",
            "A paired solver-trace comparison contains controller status, coverage, or slope transitions.",
            Dict("case" => get(raw_record, "name", nothing), "status_changes" => status,
                 "coverage_changes" => coverage, "slope_changes" => slope);
            suggested_action = "Keep transition evidence paired with coordinate-unit conventions and residual traces."
        ))
        registry = get(trace, "violation_registry", Dict())
        registry isa AbstractDict || (registry = Dict())
        registry_statuses = Dict{String,Any}()
        registry_boundaries = Dict{String,Any}()
        for side in ("left", "right")
            side_view = get(registry, side, Dict())
            side_view isa AbstractDict || (side_view = Dict())
            registry_statuses[side] = get(side_view, "status_counts", Dict())
            components = get(side_view, "components_by_status", Dict())
            components isa AbstractDict || (components = Dict())
            boundary_components = vcat(
                get(components, "unregistered", Any[]),
                get(components, "not_found", Any[]),
            )
            !isempty(boundary_components) && (registry_boundaries[side] = boundary_components)
        end
        left_registry = _dict(get(registry_statuses, "left", Dict()))
        right_registry = _dict(get(registry_statuses, "right", Dict()))
        left_registry != right_registry && push!(findings, _finding(
            "controller_curve_trace_registry_coverage_difference", "warning",
            "Paired traces have different controller-to-constraint registry coverage.",
            Dict("case" => get(raw_record, "name", nothing),
                 "left_status_counts" => left_registry,
                 "right_status_counts" => right_registry,
                 "boundary_components" => registry_boundaries);
            suggested_action = "Align semantic-row registration and coordinate conventions before interpreting policy-dependent residual differences."
        ))
        !isempty(registry_boundaries) && push!(findings, _finding(
            "controller_curve_trace_registry_boundary", "warning",
            "A paired trace contains controller residuals without matching registered constraint rows.",
            Dict("case" => get(raw_record, "name", nothing),
                 "boundary_components" => registry_boundaries);
            suggested_action = "Treat unmatched controller residuals as numerical evidence until the engine-side registry is extended."
        ))
    end
    compared == 0 && push!(findings, _finding(
        "controller_curve_trace_comparison_missing", "warning",
        "The solver-trace comparison contains no controller comparison records.",
        Dict("summary_path" => path);
        suggested_action = "Regenerate paired traces with typed controller snapshots enabled."
    ))
    return Dict{String,Any}(
        "summary_path" => path,
        "comparison_count" => compared,
        "readiness" => Dict("controller_curve_trace_comparison" => compared > 0),
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
    controller_cases = 0
    controller_available_cases = 0
    controller_coverage_mismatch = 0
    controller_residual_delta = 0
    controller_cap_delta = 0
    controller_registry_unavailable = 0
    controller_registry_boundary = 0
    for case in cases
        case isa AbstractDict || continue
        left_controller = get(case, "left_controller_curve", nothing)
        right_controller = get(case, "right_controller_curve", nothing)
        left_controller isa AbstractDict && right_controller isa AbstractDict || continue
        controller_cases += 1
        (get(left_controller, "available", false) === true ||
         get(right_controller, "available", false) === true) && (controller_available_cases += 1)
        for key in ("observation_count", "exact_monitor_count", "proxy_monitor_count",
                    "finite_observation_count", "nonfinite_observation_count")
            _int(get(left_controller, key, 0)) != _int(get(right_controller, key, 0)) &&
                (controller_coverage_mismatch += 1; break)
        end
        controller_residual_delta += abs(_int(get(get(case, "controller_curve_delta_right_minus_left", Dict()),
                                                  "equation_residual_violation_count_delta_right_minus_left", 0)))
        controller_cap_delta += abs(_int(get(get(case, "controller_curve_delta_right_minus_left", Dict()),
                                              "cap_violation_count_delta_right_minus_left", 0)))
        for side in ("left", "right")
            controller = side == "left" ? left_controller : right_controller
            registry = get(controller, "registry", Dict())
            String(get(registry, "status", "unavailable")) == "unavailable" && (controller_registry_unavailable += 1)
            status_counts = get(registry, "status_counts", Dict())
            status_counts isa AbstractDict || (status_counts = Dict())
            controller_registry_boundary += sum(_int(value, 0) for value in values(status_counts)
                                                if _int(value, 0) > 0; init = 0)
        end
    end
    controller_cases > 0 && controller_available_cases == 0 && push!(findings, _finding(
        "saved_result_controller_coverage_missing", "warning",
        "Paired saved-result policies contain no typed controller observations.",
        Dict("summary_path" => path, "controller_case_count" => controller_cases);
        suggested_action = "Regenerate the saved-result profiles with controller operating-point capture enabled."
    ))
    controller_cases > 0 && controller_coverage_mismatch > 0 && push!(findings, _finding(
        "saved_result_controller_coverage_difference", "warning",
        "Paired saved-result policies retained different controller observation coverage.",
        Dict("summary_path" => path, "case_count" => controller_cases,
             "coverage_mismatch_case_count" => controller_coverage_mismatch);
        suggested_action = "Align controller capture and monitor semantics before interpreting policy-dependent residual or slope deltas."
    ))
    controller_cases > 0 && (controller_residual_delta > 0 || controller_cap_delta > 0) && push!(findings, _finding(
        "saved_result_controller_violation_delta", "warning",
        "Paired saved-result policies have different controller equation-residual or cap-violation counts.",
        Dict("summary_path" => path, "controller_case_count" => controller_cases,
             "absolute_residual_violation_delta" => controller_residual_delta,
             "absolute_cap_violation_delta" => controller_cap_delta);
        suggested_action = "Inspect per-case controller residuals, tolerances, and field-unit attribution; this is policy evidence, not a quality score."
    ))
    controller_registry_unavailable > 0 && push!(findings, _finding(
        "saved_result_controller_registry_unavailable", "warning",
        "Some saved-result controller residuals cannot be cross-referenced to semantic constraint rows.",
        Dict("summary_path" => path, "unavailable_side_count" => controller_registry_unavailable);
        suggested_action = "Regenerate the saved-result corpus with semantic-row capture enabled before interpreting controller residuals physically."
    ))
    controller_registry_boundary > 0 && push!(findings, _finding(
        "saved_result_controller_registry_boundary", "warning",
        "Some saved-result controller residuals have no matching registered semantic row.",
        Dict("summary_path" => path, "unmatched_violation_count" => controller_registry_boundary);
        suggested_action = "Inspect the affected component/family crosswalk and extend BMOPFTools registration where appropriate."
    ))
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

function _validate_policy_matrix(path, matrix)
    findings = Any[]
    pairs = get(matrix, "pairs", Any[])
    pairs isa AbstractVector || (pairs = Any[])
    provenance = get(matrix, "policy_provenance", Dict())
    provenance isa AbstractDict || (provenance = Dict())
    process_health = get(provenance, "process_health", nothing)
    policy_process_health = false
    if process_health isa AbstractDict
        timeouts = _int(get(process_health, "process_timeout_count", 0))
        exits = _int(get(process_health, "process_exit_count", 0))
        wait_errors = _int(get(process_health, "process_wait_error_count", 0))
        policy_process_health = timeouts == 0 && exits == 0 && wait_errors == 0
        (timeouts > 0 || exits > 0 || wait_errors > 0) && push!(findings, _finding(
            "policy_matrix_process_health_failed", "error",
            "One or more unit-policy children timed out or terminated abnormally.",
            Dict("process_health" => process_health);
            suggested_action = "Inspect each policy process log and rerun the incomplete policies before comparing unit-policy deltas."
        ))
    else
        push!(findings, _finding(
            "policy_matrix_process_health_missing", "warning",
            "The policy-matrix summary does not contain child-process health fields.",
            Dict("summary_path" => path);
            suggested_action = "Regenerate the matrix with the current isolated policy launcher and summarizer."
        ))
    end
    status_counts = get(provenance, "status_counts", Dict())
    status_counts isa AbstractDict || (status_counts = Dict())
    failed_children = sum(_int(value, 0) for (status, value) in status_counts
                          if String(status) != "ok"; init = 0)
    missing_indexes = get(provenance, "missing_child_indexes", Any[])
    missing_indexes isa AbstractVector || (missing_indexes = Any[])
    failed_children > 0 && push!(findings, _finding(
        "policy_matrix_child_process_failed", "error",
        "One or more policy children did not complete successfully.",
        Dict("status_counts" => status_counts);
        suggested_action = "Inspect child process logs and rerun failed policy children before interpreting pairwise deltas."
    ))
    !isempty(missing_indexes) && push!(findings, _finding(
        "policy_matrix_child_index_missing", "warning",
        "One or more policy children have no readable corpus index.",
        Dict("missing_child_indexes" => missing_indexes);
        suggested_action = "Treat the matrix as incomplete until every successful child has a case index."
    ))
    environments = get(provenance, "environment_fingerprints", Any[])
    environments isa AbstractVector || (environments = Any[])
    unique_environments = unique(filter(value -> value isa AbstractString && !isempty(value), environments))
    length(unique_environments) > 1 && push!(findings, _finding(
        "policy_matrix_environment_mismatch", "warning",
        "Policy children were produced under different environment fingerprints.",
        Dict("environment_fingerprints" => unique_environments);
        suggested_action = "Align Julia, package, solver, and BMOPFTools revisions before attributing policy deltas to units."
    ))
    successful = 0
    comparison_errors = 0
    controller_matrix = get(matrix, "controller_curve_policy_matrix", Dict())
    controller_matrix isa AbstractDict || (controller_matrix = Dict())
    for pair in pairs
        pair isa AbstractDict || continue
        if get(pair, "status", "ok") == "comparison_error"
            comparison_errors += 1
            push!(findings, _finding("policy_matrix_comparison_error", "error",
                "A saved-result policy-matrix pair could not be compared.",
                Dict("left_policy" => get(pair, "left_policy_name", nothing),
                     "right_policy" => get(pair, "right_policy_name", nothing),
                     "error" => get(pair, "error", nothing))))
            continue
        end
        successful += 1
        pair_cases = get(pair, "cases", Any[])
        pair_cases isa AbstractVector || (pair_cases = Any[])
        local_controller = get(pair, "controller_curve_policy_matrix", Dict())
        local_controller isa AbstractDict || continue
        residual_delta = _int(get(get(local_controller, "aggregate_count_deltas", Dict()),
                                  "equation_residual_violation_count_delta_right_minus_left", 0))
        cap_delta = _int(get(get(local_controller, "aggregate_count_deltas", Dict()),
                             "cap_violation_count_delta_right_minus_left", 0))
        (residual_delta != 0 || cap_delta != 0) && push!(findings, _finding(
            "policy_matrix_controller_violation_delta", "warning",
            "A saved-result policy pair changes controller residual or cap-violation counts.",
            Dict("left_policy" => get(pair, "left_policy_name", nothing),
                 "right_policy" => get(pair, "right_policy_name", nothing),
                 "equation_residual_violation_delta" => residual_delta,
                 "cap_violation_delta" => cap_delta);
            suggested_action = "Inspect the paired case records and tolerance metadata before treating the policy delta as a formulation effect."
        ))
    end
    isempty(pairs) && push!(findings, _finding("policy_matrix_empty", "warning",
        "The saved-result policy matrix contains no pairwise comparisons.",
        Dict("summary_path" => path)))
    controller_cases = _int(get(controller_matrix, "controller_observation_case_count", 0))
    controller_cases == 0 && push!(findings, _finding("policy_matrix_controller_curve_empty", "warning",
        "The saved-result policy matrix contains no paired controller observations.",
        Dict("summary_path" => path);
        suggested_action = "Regenerate policy profiles with typed controller observations enabled."
    ))
    registry_statuses = get(controller_matrix, "registry_status_counts", Dict())
    registry_statuses isa AbstractDict || (registry_statuses = Dict())
    registry_violation_statuses = get(controller_matrix, "registry_violation_status_counts", Dict())
    registry_violation_statuses isa AbstractDict || (registry_violation_statuses = Dict())
    unavailable_registry = _int(get(registry_statuses, "unavailable", 0), 0)
    boundary_registry = _int(get(registry_violation_statuses, "not_found", 0), 0) +
                        _int(get(registry_violation_statuses, "unregistered", 0), 0) +
                        _int(get(controller_matrix, "registry_boundary_case_count", 0), 0)
    unavailable_registry > 0 && push!(findings, _finding(
        "policy_matrix_controller_registry_unavailable", "warning",
        "Some saved-result policy children do not carry a semantic-row registry.",
        Dict("registry_status_counts" => registry_statuses);
        suggested_action = "Regenerate the policy matrix after enabling saved-result semantic-row capture."
    ))
    boundary_registry > 0 && push!(findings, _finding(
        "policy_matrix_controller_registry_boundary", "warning",
        "Some policy-matrix controller residuals are unmatched to registered semantic rows.",
        Dict("registry_status_counts" => registry_statuses,
             "registry_violation_status_counts" => registry_violation_statuses,
             "registry_boundary_case_count" => get(controller_matrix, "registry_boundary_case_count", 0));
        suggested_action = "Inspect the component/family crosswalk before assigning physical meaning to the policy delta."
    ))
    return Dict{String,Any}(
        "summary_path" => path,
        "pair_count" => length(pairs),
        "successful_pair_count" => successful,
        "comparison_error_count" => comparison_errors,
        "controller_curve_policy_matrix" => Dict(
            "paired_case_count" => _int(get(controller_matrix, "paired_case_count", 0)),
            "controller_observation_case_count" => controller_cases,
            "registry_status_counts" => get(controller_matrix, "registry_status_counts", Dict()),
            "registry_violation_status_counts" => get(controller_matrix, "registry_violation_status_counts", Dict()),
            "registry_boundary_case_count" => get(controller_matrix, "registry_boundary_case_count", 0),
        ),
        "readiness" => Dict("policy_matrix_alignment" => !isempty(pairs) && comparison_errors == 0,
                            "controller_curve_policy_matrix" => controller_cases > 0,
                            "policy_process_health" => policy_process_health),
        "findings" => findings,
    )
end

function _validate_policy_matrix_manifest(path, manifest)
    findings = Any[]
    policies = get(manifest, "policies", Any[])
    policies isa AbstractVector || (policies = Any[])
    successful = 0
    missing_indexes = 0
    for policy in policies
        policy isa AbstractDict || continue
        name = get(policy, "policy", nothing)
        status = String(get(policy, "status", "unknown"))
        if status == "ok"
            successful += 1
        else
            push!(findings, _finding("policy_matrix_child_process_failed", "error",
                "A saved-result policy child process did not complete successfully.",
                Dict("policy" => name, "status" => status,
                     "process_exit_code" => get(policy, "process_exit_code", nothing),
                     "process_timeout" => get(policy, "process_timeout", nothing));
                suggested_action = "Inspect the child process log and rerun the affected policy before comparing policy evidence."
            ))
        end
        available = get(policy, "child_index_available", false) === true
        !available && (missing_indexes += 1)
        !available && push!(findings, _finding("policy_matrix_child_index_missing", "warning",
            "A policy child did not produce a readable corpus index.",
            Dict("policy" => name, "output_directory" => get(policy, "output_directory", nothing));
            suggested_action = "Treat the policy result as incomplete until its child index and case statuses are available."
        ))
        available && _int(get(policy, "child_case_count", 0), 0) == 0 && push!(findings,
            _finding("policy_matrix_child_cases_empty", "warning",
                "A policy child index contains no case records.",
                Dict("policy" => name, "output_directory" => get(policy, "output_directory", nothing));
                suggested_action = "Check case selectors and benchmark-root provenance before interpreting the matrix."
            ))
    end
    fingerprints = get(manifest, "environment_fingerprints", Any[])
    fingerprints isa AbstractVector || (fingerprints = Any[])
    unique_fingerprints = unique(filter(value -> value isa AbstractString && !isempty(value), fingerprints))
    length(unique_fingerprints) > 1 && push!(findings, _finding(
        "policy_matrix_environment_mismatch", "warning",
        "Policy children were produced under different environment fingerprints.",
        Dict("environment_fingerprints" => unique_fingerprints);
        suggested_action = "Align Julia, package, solver, and BMOPFTools revisions before attributing policy deltas to exported units."
    ))
    isempty(policies) && push!(findings, _finding("policy_matrix_policies_empty", "error",
        "The policy-matrix manifest contains no selected policies.", Dict("summary_path" => path)))
    return Dict{String,Any}(
        "summary_path" => path,
        "policy_count" => length(policies),
        "successful_policy_count" => successful,
        "missing_child_index_count" => missing_indexes,
        "environment_fingerprints" => unique_fingerprints,
        "readiness" => Dict("policy_children_successful" => !isempty(policies) && successful == length(policies),
                            "child_indexes_available" => !isempty(policies) && missing_indexes == 0,
                            "environment_compatible" => length(unique_fingerprints) <= 1),
        "findings" => findings,
    )
end

function _validate_point_calibration(path, summary)
    findings = Any[]
    case_count = _int(get(summary, "case_count", 0))
    observation_count = _int(get(summary, "observation_count", 0))
    run_failures = _int(get(summary, "run_failure_count", 0))
    trusted_saved = _int(get(summary, "trusted_saved_case_count", 0))
    invariant_repeat = _int(get(
        summary, "point_invariant_repeat_failure_count", 0,
    ))
    same_point_repeat = _int(get(
        summary, "same_point_repeat_failure_count", invariant_repeat,
    ))
    same_point_metric_repeat = _int(get(
        summary, "same_point_metric_repeat_failure_count", 0,
    ))
    same_point_row_family_scale_repeat = _int(get(
        summary, "same_point_row_family_scale_repeat_failure_count", 0,
    ))
    row_family_scale_missing = _int(get(
        summary, "row_family_scale_missing_observation_count", 0,
    ))
    row_family_scaling_experiment_missing = _int(get(
        summary, "row_family_scaling_experiment_missing_observation_count", 0,
    ))
    same_point_row_family_scaling_experiment_repeat = _int(get(
        summary,
        "same_point_row_family_scaling_experiment_repeat_failure_count", 0,
    ))
    point_fingerprint_repeat = _int(get(
        summary, "point_fingerprint_repeat_failure_count", 0,
    ))
    invariant_cross_point = _int(get(
        summary, "point_invariant_cross_point_change_count", 0,
    ))
    local_cross_point = _int(get(
        summary, "point_local_cross_point_change_count", 0,
    ))
    registry_complete = get(summary, "registry_complete", false) === true
    environments = get(summary, "environment_fingerprints", Any[])
    environments isa AbstractVector || (environments = Any[])
    run_failures > 0 && push!(findings, _finding(
        "point_calibration_child_failure", "error",
        "Point calibration contains failed child runs or failed case records.",
        Dict("run_failure_count" => run_failures);
        suggested_action = "Repair and rerun failed children before interpreting recurrence or point persistence."
    ))
    case_count == 0 && push!(findings, _finding(
        "point_calibration_cases_empty", "error",
        "Point calibration contains no aligned cases.",
        Dict("observation_count" => observation_count);
        suggested_action = "Check the benchmark root and case selectors, then regenerate the calibration campaign."
    ))
    length(unique(environments)) > 1 && push!(findings, _finding(
        "point_calibration_environment_mismatch", "warning",
        "Point calibration combines more than one environment fingerprint.",
        Dict("environment_fingerprints" => environments);
        suggested_action = "Align Julia and package revisions before attributing changes to evaluation points."
    ))
    !registry_complete && push!(findings, _finding(
        "point_calibration_registry_incomplete", "warning",
        "At least one calibrated observation lacks complete semantic row coverage.",
        Dict("observation_count" => observation_count);
        suggested_action = "Resolve uncovered rows before interpreting persistence by equation family."
    ))
    invariant_repeat > 0 && push!(findings, _finding(
        "point_calibration_repeatability_failure", "warning",
        "Nominally point-invariant stages changed across repeated runs.",
        Dict("changed_stage_count" => invariant_repeat);
        suggested_action = "Inspect randomized probes, ordering, and environment provenance before trusting recurrence."
    ))
    same_point_repeat > invariant_repeat && push!(findings, _finding(
        "point_calibration_same_point_finding_drift", "warning",
        "Point-local or auxiliary report stages changed across repeated runs at one exact point.",
        Dict("changed_stage_count" => same_point_repeat,
             "point_invariant_changed_stage_count" => invariant_repeat);
        suggested_action = "Resolve nondeterminism before interpreting same-point recurrence."
    ))
    same_point_metric_repeat > 0 && push!(findings, _finding(
        "point_calibration_same_point_metric_drift", "warning",
        "Curated numerical metrics changed across repeated runs at one exact point.",
        Dict("changed_stage_count" => same_point_metric_repeat);
        suggested_action = "Resolve rank-tolerance or numerical-library variability before interpreting metric persistence."
    ))
    row_family_scale_missing > 0 && push!(findings, _finding(
        "point_calibration_row_family_scale_attribution_missing", "warning",
        "Some calibrated observations lack semantic Jacobian row-family scale attribution.",
        Dict("missing_observation_count" => row_family_scale_missing,
             "observation_count" => observation_count);
        suggested_action = "Regenerate those profiles before attributing global scaling changes to equation families."
    ))
    same_point_row_family_scale_repeat > 0 && push!(findings, _finding(
        "point_calibration_same_point_row_family_scale_drift", "warning",
        "Semantic Jacobian row-family scale evidence changed at one exact repeated point.",
        Dict("changed_policy_count" => same_point_row_family_scale_repeat);
        suggested_action = "Resolve derivative or ordering nondeterminism before interpreting family-level scale changes."
    ))
    row_family_scaling_experiment_missing > 0 && push!(findings, _finding(
        "point_calibration_row_family_scaling_experiment_missing", "warning",
        "A requested controlled row-family scaling experiment is missing from some observations.",
        Dict("missing_observation_count" =>
                 row_family_scaling_experiment_missing,
             "observation_count" => observation_count);
        suggested_action = "Regenerate the missing observations with the same explicit family list before comparing interventions."
    ))
    same_point_row_family_scaling_experiment_repeat > 0 &&
        push!(findings, _finding(
            "point_calibration_same_point_row_family_scaling_experiment_drift",
            "warning",
            "A controlled row-family scaling experiment changed at one exact repeated point.",
            Dict("changed_policy_count" =>
                     same_point_row_family_scaling_experiment_repeat);
            suggested_action = "Resolve sparse-factorization or derivative nondeterminism before interpreting the intervention."
        ))
    point_fingerprint_repeat > 0 && push!(findings, _finding(
        "point_calibration_point_fingerprint_drift", "error",
        "Repeated observations for one policy did not use one exact evaluation point.",
        Dict("changed_policy_count" => point_fingerprint_repeat);
        suggested_action = "Align saved-result and initialization point sources before comparing findings."
    ))
    invariant_cross_point > 0 && push!(findings, _finding(
        "point_calibration_invariant_stage_changed", "warning",
        "Nominally point-invariant stages changed across evaluation points.",
        Dict("changed_stage_count" => invariant_cross_point);
        suggested_action = "Remove hidden point dependence or reclassify the affected stage before calling its findings structural."
    ))
    local_cross_point > 0 && push!(findings, _finding(
        "point_calibration_local_finding_changed", "info",
        "Point-local findings changed across calibrated evaluation points.",
        Dict("changed_stage_count" => local_cross_point);
        suggested_action = "Retain these as local numerical observations and inspect the exact finding-identity deltas."
    ))
    trusted_saved < case_count && push!(findings, _finding(
        "point_calibration_trusted_saved_point_missing", "warning",
        "Some calibrated cases lack a completely mapped saved solver point.",
        Dict("case_count" => case_count,
             "trusted_saved_case_count" => trusted_saved);
        suggested_action = "Add complete saved solver results before making physical persistence claims."
    ))
    readiness = get(summary, "readiness", Dict())
    readiness isa AbstractDict || (readiness = Dict())
    return Dict{String,Any}(
        "summary_path" => path,
        "case_count" => case_count,
        "observation_count" => observation_count,
        "run_failure_count" => run_failures,
        "trusted_saved_case_count" => trusted_saved,
        "point_invariant_repeat_failure_count" => invariant_repeat,
        "same_point_repeat_failure_count" => same_point_repeat,
        "same_point_metric_repeat_failure_count" => same_point_metric_repeat,
        "same_point_row_family_scale_repeat_failure_count" =>
            same_point_row_family_scale_repeat,
        "row_family_scale_missing_observation_count" =>
            row_family_scale_missing,
        "row_family_scaling_experiment_missing_observation_count" =>
            row_family_scaling_experiment_missing,
        "same_point_row_family_scaling_experiment_repeat_failure_count" =>
            same_point_row_family_scaling_experiment_repeat,
        "point_fingerprint_repeat_failure_count" => point_fingerprint_repeat,
        "point_invariant_cross_point_change_count" => invariant_cross_point,
        "point_local_cross_point_change_count" => local_cross_point,
        "readiness" => readiness,
        "findings" => findings,
    )
end

function _validate_solver_matrix(path, matrix)
    findings = Any[]
    process_health = get(matrix, "process_health", nothing)
    solver_process_health = false
    if process_health isa AbstractDict
        timeouts = _int(get(process_health, "process_timeout_count", 0))
        exits = _int(get(process_health, "process_exit_count", 0))
        wait_errors = _int(get(process_health, "process_wait_error_count", 0))
        nonzero = _int(get(process_health, "nonzero_process_exit_count", 0))
        solver_process_health = timeouts == 0 && exits == 0 && wait_errors == 0 && nonzero == 0
        !solver_process_health && push!(findings, _finding(
            "solver_matrix_process_health_failed", "error",
            "One or more solver-matrix children timed out or terminated abnormally.",
            Dict("process_health" => process_health);
            suggested_action = "Inspect per-solver process logs and rerun incomplete solver/snapshot pairs before interpreting comparisons."
        ))
    else
        push!(findings, _finding(
            "solver_matrix_process_health_missing", "warning",
            "The solver-matrix summary does not contain child-process health fields.",
            Dict("summary_path" => path);
            suggested_action = "Regenerate the matrix with the current isolated solver launcher and summarizer."
        ))
    end
    solver_summaries = get(matrix, "solver_summaries", Dict())
    solver_count = length(solver_summaries)
    successful = 0
    trusted_solver_results = 0
    for (solver, summary) in solver_summaries
        statuses = get(summary, "status_counts", Dict())
        ok = _int(get(statuses, "ok", 0))
        successful += ok > 0
        ok == 0 && push!(findings, _finding("solver_matrix_no_success", "error",
            "Solver $(solver) produced no successful case in the matrix.",
            Dict("solver" => String(solver), "status_counts" => statuses)))
        trust = get(summary, "trusted_point_selection_counts", nothing)
        if trust isa AbstractDict
            trusted = _int(get(trust, "successful_cases_with_trusted_solver_result_points", 0))
            incomplete = _int(get(trust, "successful_cases_with_incomplete_solver_result_points", 0))
            missing = _int(get(trust, "successful_cases_missing_solver_result_trust_metadata", 0))
            ok > 0 && trusted == ok && incomplete == 0 && missing == 0 &&
                (trusted_solver_results += 1)
        end
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
    family_matrix = get(matrix, "family_perturbation_matrix", nothing)
    family_readiness = Dict{String,Any}()
    if family_matrix isa AbstractDict || haskey(matrix, "family_perturbations_enabled")
        family_matrix = family_matrix isa AbstractDict ? family_matrix : Dict{String,Any}()
        raw_enabled = get(matrix, "family_perturbations_enabled", false)
        enabled = raw_enabled === true || lowercase(string(raw_enabled)) in ("true", "1", "yes", "on")
        variants = _int(get(family_matrix, "variant_count", 0))
        status_counts = get(family_matrix, "status_counts", Dict())
        status_counts isa AbstractDict || (status_counts = Dict())
        variant_errors = _int(get(status_counts, "error", 0))
        families = get(family_matrix, "by_family", Dict())
        family_count = families isa AbstractDict ? length(families) : 0
        enabled && variants == 0 && push!(findings, _finding(
            "solver_matrix_family_perturbation_empty", "warning",
            "Family perturbations were enabled in the solver matrix but no paired variants were summarized.",
            Dict("variant_count" => variants, "status_counts" => status_counts);
            suggested_action = "Inspect child records and per-solver summaries before interpreting matrix evidence."
        ))
        variant_errors > 0 && push!(findings, _finding(
            "solver_matrix_family_perturbation_errors", "warning",
            "Some family-perturbation variants ended with execution errors.",
            Dict("error_variant_count" => variant_errors, "status_counts" => status_counts);
            suggested_action = "Treat the matrix perturbation evidence as partial until failed variants are explained."
        ))
        repeatability = get(family_matrix, "repeatability", Dict())
        repeatability isa AbstractDict || (repeatability = Dict())
        repeated_families = count(value -> _int(get(value, "observations", 0)) >= 2,
                                  values(repeatability))
        family_readiness["enabled"] = enabled
        family_readiness["variant_count"] = variants
        family_readiness["family_count"] = family_count
        family_readiness["repeatable_family_count"] = repeated_families
        family_readiness["matrix_available"] = enabled && variants > 0 && variant_errors == 0
        family_readiness["repeatability_observed"] = repeated_families > 0
    end
    controller_matrix = get(matrix, "controller_curve_matrix", nothing)
    controller_readiness = Dict{String,Any}()
    if controller_matrix isa AbstractDict
        paired_cases = _int(get(controller_matrix, "paired_case_count", 0), 0)
        status_counts = get(controller_matrix, "registry_status_counts", Dict())
        status_counts isa AbstractDict || (status_counts = Dict())
        unmatched = get(controller_matrix, "unmatched_component_counts", Dict())
        unmatched isa AbstractDict || (unmatched = Dict())
        has_unmatched = any(!isempty(get(unmatched, side, Dict())) for side in ("left", "right"))
        paired_cases == 0 && push!(findings, _finding(
            "solver_matrix_controller_curve_empty", "warning",
            "The solver matrix contains no paired controller-trace records.",
            Dict("controller_curve_matrix" => controller_matrix);
            suggested_action = "Enable typed controller snapshots for comparable solver-matrix traces."
        ))
        has_unmatched && push!(findings, _finding(
            "solver_matrix_controller_registry_boundary", "warning",
            "Some solver-matrix controller residuals have no matching registered semantic row.",
            Dict("unmatched_component_counts" => unmatched,
                 "registry_status_counts" => status_counts);
            suggested_action = "Keep matrix conclusions conditional until the affected controller families are registered."
        ))
        controller_readiness["paired_case_count"] = paired_cases
        controller_readiness["registry_boundary_present"] = has_unmatched
        controller_readiness["controller_matrix_available"] = paired_cases > 0
    end
    return Dict{String,Any}(
        "summary_path" => path,
        "solver_count" => solver_count,
        "successful_solver_count" => successful,
        "paired_comparison_count" => comparison_count,
        "readiness" => Dict(
            "solver_matrix_success" => solver_count > 0 && successful == solver_count,
            "solver_matrix_alignment" => comparison_count > 0,
            "solver_process_health" => solver_process_health,
            "trusted_solver_result_points" => solver_count > 0 && trusted_solver_results == solver_count,
            "family_perturbation_matrix" => get(family_readiness, "matrix_available", false),
            "family_perturbation_repeatability" => get(family_readiness, "repeatability_observed", false),
        ),
        "family_perturbation" => family_readiness,
        "controller_curve_matrix" => controller_readiness,
        "findings" => findings,
    )
end

function _validate_multiconductor_smoke(path, summary)
    findings = Any[]
    readiness = get(summary, "readiness", Dict())
    readiness isa AbstractDict || (readiness = Dict())
    get(readiness, "all_cases_successful", false) === true || push!(findings,
        _finding("multiconductor_smoke_incomplete", "error",
            "The multiconductor smoke summary does not contain successful records for every selected fixture.",
            Dict("summary_path" => path, "readiness" => readiness);
            suggested_action = "Inspect the fixture index and rerun failed or missing multiconductor cases."))
    get(readiness, "dense_budget_explicit", false) === true || push!(findings,
        _finding("multiconductor_smoke_dense_budget_missing", "warning",
            "The multiconductor smoke summary does not record an explicit dense-analysis budget.",
            Dict("summary_path" => path);
            suggested_action = "Record the dense rank budget before comparing fixture-level numerical evidence."))
    dense_budget = _int(get(summary, "rank_max_dense_entries", 0))
    dense_budget > 0 && get(readiness, "dense_physical_mode_rank_complete", false) !== true && push!(findings,
        _finding("multiconductor_smoke_dense_mode_rank_incomplete", "warning",
            "A positive dense budget was requested, but dense physical-mode rank evidence is incomplete across the successful fixtures.",
            Dict("summary_path" => path, "rank_max_dense_entries" => dense_budget,
                 "physical_mode_rank_available_case_count" => get(get(summary, "aggregate", Dict()), "physical_mode_rank_available_case_count", 0),
                 "successful_case_count" => get(get(summary, "aggregate", Dict()), "successful_case_count", 0));
            suggested_action = "Restrict the dense checkpoint to fixtures within budget, or retain the campaign as sparse-only evidence."))
    get(readiness, "source_fixtures_preserved", false) === true || push!(findings,
        _finding("multiconductor_source_snapshot_missing", "warning",
            "The campaign does not preserve every source fixture for follow-up schema mapping.",
            Dict("summary_path" => path,
                 "source_snapshot_case_count" => get(get(summary, "aggregate", Dict()), "source_snapshot_case_count", 0),
                 "successful_case_count" => get(get(summary, "aggregate", Dict()), "successful_case_count", 0));
            suggested_action = "Rerun the smoke campaign with source snapshots preserved before interpreting schema-loss findings."))
    get(readiness, "source_schema_context_report_available", false) === true || push!(findings,
        _finding("multiconductor_source_schema_report_missing", "warning",
            "The campaign does not contain the structured BMOPF source-schema report for every successful fixture.",
            Dict("summary_path" => path,
                 "source_schema_context_report_case_count" => get(get(summary, "aggregate", Dict()),
                     "source_schema_context_report_case_count", 0),
                 "successful_case_count" => get(get(summary, "aggregate", Dict()),
                     "successful_case_count", 0));
            suggested_action = "Regenerate the smoke campaign with the current BMOPF source-schema report enabled."))
    get(readiness, "source_schema_provenance_available", false) === true || push!(findings,
        _finding("multiconductor_source_schema_provenance_missing", "warning",
            "The campaign does not preserve a source-only metadata inventory for every successful fixture.",
            Dict("summary_path" => path,
                 "source_schema_provenance_case_count" => get(get(summary, "aggregate", Dict()),
                     "source_schema_provenance_case_count", 0),
                 "successful_case_count" => get(get(summary, "aggregate", Dict()),
                     "successful_case_count", 0));
            suggested_action = "Retain the PowerIO source metadata inventory before attempting physical-field restoration."))
    get(readiness, "source_schema_semantic_observations_available", false) === true || push!(findings,
        _finding("multiconductor_source_schema_semantic_observations_missing", "warning",
            "The campaign lacks normalized observations for load voltage-behavior thresholds or voltage-source model contracts.",
            Dict("summary_path" => path,
                 "source_schema_threshold_observation_case_count" => get(get(summary, "aggregate", Dict()),
                     "source_schema_threshold_observation_case_count", 0),
                 "source_schema_source_model_contract_case_count" => get(get(summary, "aggregate", Dict()),
                     "source_schema_source_model_contract_case_count", 0));
            suggested_action = "Regenerate the campaign with source semantic observations enabled before interpreting voltage-model fidelity."))
    get(readiness, "source_schema_behavior_contract_available", false) === true || push!(findings,
        _finding("multiconductor_source_schema_behavior_contract_missing", "warning",
            "The campaign lacks the explicit non-mutating contract for load voltage-behavior thresholds.",
            Dict("summary_path" => path,
                 "source_schema_behavior_contract_case_count" => get(get(summary, "aggregate", Dict()),
                     "source_schema_behavior_contract_case_count", 0),
                 "source_schema_behavior_candidate_count" => get(get(summary, "aggregate", Dict()),
                     "source_schema_behavior_candidate_count", 0));
            suggested_action = "Expose the source behavior contract before planning auxiliary voltage-ratio constraints."))
    get(readiness, "source_behavior_auxiliary_available", false) === true || push!(findings,
        _finding("multiconductor_source_behavior_auxiliary_unavailable", "warning",
            "The campaign does not contain a complete non-mutating auxiliary-model materialization record.",
            Dict("summary_path" => path,
                 "source_behavior_auxiliary_case_count" => get(get(summary, "aggregate", Dict()),
                     "source_behavior_auxiliary_case_count", 0),
                 "source_behavior_auxiliary_materialized_pair_count" => get(get(summary, "aggregate", Dict()),
                     "source_behavior_auxiliary_materialized_pair_count", 0),
                 "source_behavior_auxiliary_mutation_case_count" => get(get(summary, "aggregate", Dict()),
                     "source_behavior_auxiliary_mutation_case_count", 0));
            suggested_action = "Build the auxiliary model separately and verify that the original BMOPF model is unchanged."))
    get(readiness, "source_behavior_report_available", false) === true || push!(findings,
        _finding("multiconductor_source_behavior_report_unavailable", "warning",
            "The campaign contains source-behavior candidates but not a complete point-wise threshold report for every successful fixture.",
            Dict("summary_path" => path,
                 "source_behavior_report_case_count" => get(get(summary, "aggregate", Dict()),
                     "source_behavior_report_case_count", 0),
                 "source_behavior_report_row_count" => get(get(summary, "aggregate", Dict()),
                     "source_behavior_report_row_count", 0),
                 "source_behavior_report_finding_count" => get(get(summary, "aggregate", Dict()),
                     "source_behavior_report_finding_count", 0));
            suggested_action = "Regenerate the campaign with the typed operating point and source-behavior report preserved."))
    get(readiness, "source_behavior_auxiliary_solve_complete", false) === true || push!(findings,
        _finding("multiconductor_source_behavior_auxiliary_solve_unavailable", "warning",
            "A solver-backed source-behavior campaign was requested, but one or more auxiliary solves were unavailable.",
            Dict("summary_path" => path,
                 "source_behavior_solver" => get(summary, "source_behavior_solver", "unknown"),
                 "source_behavior_auxiliary_solve_status_counts" =>
                     get(get(summary, "aggregate", Dict()),
                         "source_behavior_auxiliary_solve_status_counts", Dict()),
                 "source_behavior_auxiliary_solve_unavailable_case_count" =>
                     get(get(summary, "aggregate", Dict()),
                         "source_behavior_auxiliary_solve_unavailable_case_count", 0));
            suggested_action = "Inspect the solver environment or rerun with source-behavior solver policy none for observation-only evidence."))
    get(readiness, "source_schema_mapping_complete", false) === true || push!(findings,
        _finding("multiconductor_source_schema_mapping_incomplete", "warning",
            "Source-only metadata is preserved, but blocking fields are not yet covered by explicit BMOPF mappings.",
            Dict("summary_path" => path,
                 "source_schema_unmapped_blocking_field_counts" => get(get(summary, "aggregate", Dict()),
                     "source_schema_unmapped_blocking_field_counts", Dict()),
                 "source_schema_mapping_ready_case_count" => get(get(summary, "aggregate", Dict()),
                     "source_schema_mapping_ready_case_count", 0));
            suggested_action = "Implement and validate explicit source-to-BMOPF mappings before promoting physical tangent declarations."))
    get(readiness, "port_contract_available", false) === true || push!(findings,
        _finding("multiconductor_smoke_contract_unavailable", "warning",
            "One or more successful fixtures lack a multiconductor port contract.",
            Dict("summary_path" => path);
            suggested_action = "Treat port maps, constitutive maps, and physical-mode counts as incomplete."))
    get(readiness, "integrity_preflight_clear", false) === true || push!(findings,
        _finding("multiconductor_smoke_integrity_error", "error",
            "The multiconductor smoke campaign contains blocking source-integrity findings.",
            Dict("summary_path" => path);
            suggested_action = "Resolve source/import integrity findings before interpreting physical modes."))
    get(readiness, "physical_metadata_complete", false) === true || begin
        aggregate = get(summary, "aggregate", Dict())
        push!(findings, _finding(
            "multiconductor_physical_schema_loss", "warning",
            "Dropped source fields may change physical, device-semantic, or operating-point interpretation.",
            Dict("summary_path" => path,
                 "physical_metadata_warning_count" => get(aggregate, "physical_metadata_warning_count", 0),
                 "impact_counts" => get(aggregate, "source_schema_warning_impact_counts", Dict()),
                 "policy_status_counts" => get(aggregate, "source_schema_warning_policy_status_counts", Dict()),
                 "field_policies" => get(aggregate, "source_schema_field_policies", Dict()),
                 "fixture_counts" => get(aggregate, "source_schema_warning_fixture_counts", Dict()));
            suggested_action = "Restore or explicitly account for affected source fields before treating numerical findings as physical conclusions.",
        ))
    end
    get(readiness, "physical_mode_analysis_available", false) === true || push!(findings,
        _finding("multiconductor_expected_mode_analysis_unavailable", "warning",
            "Expected-versus-observed physical-mode analysis is not available for every successful fixture.",
            Dict("summary_path" => path);
            suggested_action = "Run the physical-mode analysis for every selected fixture before comparing nullspace semantics."))
    get(readiness, "mode_projection_observations_available", false) === true || push!(findings,
        _finding("multiconductor_mode_projection_unavailable", "warning",
            "Per-component physical-mode projection evidence is unavailable for one or more successful fixtures.",
            Dict("summary_path" => path,
                 "physical_mode_projection_case_count" => get(get(summary, "aggregate", Dict()), "physical_mode_projection_case_count", 0),
                 "successful_case_count" => get(get(summary, "aggregate", Dict()), "successful_case_count", 0));
            suggested_action = "Retain the mode as unrepresented until its terminal-to-model projection is explicitly declared."))
    get(readiness, "mode_jacobian_match_observations_available", false) === true || push!(findings,
        _finding("multiconductor_mode_jacobian_match_unavailable", "warning",
            "Per-component physical-mode versus observed-Jacobian match evidence is unavailable for one or more successful fixtures.",
            Dict("summary_path" => path,
                 "physical_mode_match_case_count" => get(get(summary, "aggregate", Dict()), "physical_mode_match_case_count", 0),
                 "successful_case_count" => get(get(summary, "aggregate", Dict()), "successful_case_count", 0));
            suggested_action = "Retain visible modes as candidates until their local Jacobian comparison is serialized."))
    mode_projection_policy = get(readiness,
        "mode_free_coordinate_projection_policy", "unknown")
    mode_projection_policy in ("strict", "project_free") || push!(findings,
        _finding("multiconductor_mode_projection_policy_unavailable", "warning",
            "The campaign does not record an explicit expected-mode free-coordinate policy.",
            Dict("summary_path" => path,
                 "mode_free_coordinate_projection_policy" => mode_projection_policy);
            suggested_action = "Record either strict or project_free policy before comparing fixed/reference components."))
    mode_tangent_policy = get(readiness, "mode_tangent_policy", "unknown")
    mode_tangent_policy in ("none", "fixed", "bmopf_fixed_reference_grounding") || push!(findings,
        _finding("multiconductor_mode_tangent_policy_unavailable", "warning",
            "The campaign does not record a recognized plugin-specific expected-mode tangent policy.",
            Dict("summary_path" => path,
                 "mode_tangent_policy" => mode_tangent_policy);
            suggested_action = "Record the BMOPF tangent scope explicitly, or set it to none when the plugin policy is intentionally disabled."))
    get(readiness, "expected_observed_mode_comparison", false) === true || push!(findings,
        _finding("multiconductor_expected_mode_comparison_unavailable", "warning",
            "The multiconductor campaign does not have complete coordinate-aligned local numerical evidence for its declared physical modes.",
            Dict("summary_path" => path,
                 "physical_mode_comparison_status_counts" => get(get(summary, "aggregate", Dict()), "physical_mode_comparison_status_counts", Dict()),
                 "partial_alignment_mode_count" => get(get(summary, "aggregate", Dict()), "partial_alignment_physical_mode_count", 0));
            suggested_action = "Treat declared physical modes as plugin expectations; inspect coordinate alignment and dense-rank availability before calling them observed or absent."))
    if haskey(readiness, "iterative_right_nullspace_probe") &&
       get(readiness, "iterative_right_nullspace_probe", false) !== true
        aggregate = get(summary, "aggregate", Dict())
        push!(findings, _finding(
            "multiconductor_iterative_probe_unavailable", "warning",
            "A requested sparse iterative right-nullspace probe was unavailable for one or more fixtures.",
            Dict("summary_path" => path,
                 "requested_case_count" => get(aggregate, "iterative_probe_requested_case_count", 0),
                 "available_case_count" => get(aggregate, "iterative_probe_available_case_count", 0));
            suggested_action = "Inspect sparse Jacobian provenance and probe failure reasons before interpreting candidate directions.",
        ))
    end
    aggregate = get(summary, "aggregate", Dict())
    aggregate isa AbstractDict || (aggregate = Dict())
    _int(get(aggregate, "source_schema_warning_count", 0)) > 0 && push!(findings,
        _finding("multiconductor_smoke_source_schema_warning", "warning",
            "The source loader dropped or could not represent fields in one or more fixtures.",
            Dict("summary_path" => path,
                 "source_schema_warning_count" => get(aggregate, "source_schema_warning_count", 0),
                 "field_counts" => get(aggregate, "source_schema_warning_field_counts", Dict()),
                 "scope_counts" => get(aggregate, "source_schema_warning_scope_counts", Dict()),
                 "impact_counts" => get(aggregate, "source_schema_warning_impact_counts", Dict()),
                 "policy_status_counts" => get(aggregate, "source_schema_warning_policy_status_counts", Dict()),
                 "field_policies" => get(aggregate, "source_schema_field_policies", Dict()),
                 "fixture_counts" => get(aggregate, "source_schema_warning_fixture_counts", Dict()),
                 "message_counts" => get(aggregate, "source_schema_warning_message_counts", Dict()));
            suggested_action = "Inspect the retained source-schema warnings before assigning physical meaning to fixture metadata."))
    return Dict{String,Any}(
        "summary_path" => path,
        "case_count" => _int(get(summary, "case_count", 0)),
        "aggregate" => get(summary, "aggregate", Dict()),
        "readiness" => readiness,
        "findings" => findings,
    )
end

function _validate_multiconductor_probe_comparison(path, summary)
    findings = Any[]
    readiness = get(summary, "readiness", Dict())
    readiness isa AbstractDict || (readiness = Dict())
    paired = _int(get(summary, "paired_case_count", 0))
    paired == 0 && push!(findings, _finding(
        "multiconductor_probe_comparison_empty", "warning",
        "The iterative-probe comparison contains no paired fixtures.",
        Dict("summary_path" => path);
        suggested_action = "Compare summaries with explicit common fixture names."
    ))
    get(readiness, "paired_case_coverage", false) === true || push!(findings, _finding(
        "multiconductor_probe_case_coverage_mismatch", "warning",
        "The iterative-probe comparison does not cover the same fixture set on both sides.",
        Dict("summary_path" => path);
        suggested_action = "Treat only explicitly paired fixtures as comparable."
    ))
    get(readiness, "environment_compatible", false) === true || push!(findings, _finding(
        "multiconductor_probe_environment_mismatch", "warning",
        "The iterative-probe summaries have incompatible environment fingerprints.",
        Dict("summary_path" => path);
        suggested_action = "Align the package, Julia, BMOPFTools, and fixture environments before interpreting probe deltas."
    ))
    get(readiness, "probe_dimension_aligned", false) === true || push!(findings, _finding(
        "multiconductor_probe_dimension_mismatch", "warning",
        "The paired iterative probes requested different subspace dimensions.",
        Dict("summary_path" => path);
        suggested_action = "Keep probe dimension fixed when comparing convergence or residual changes."
    ))
    return Dict{String,Any}(
        "summary_path" => path,
        "paired_case_count" => paired,
        "readiness" => readiness,
        "findings" => findings,
    )
end

function _validate_multiconductor_point_comparison(path, summary)
    findings = Any[]
    readiness = get(summary, "readiness", Dict())
    readiness isa AbstractDict || (readiness = Dict())
    paired = _int(get(summary, "paired_case_count", 0))
    paired == 0 && push!(findings, _finding(
        "multiconductor_point_comparison_empty", "warning",
        "The point-policy comparison contains no paired fixtures.",
        Dict("summary_path" => path);
        suggested_action = "Compare summaries with explicit common fixture names."
    ))
    get(readiness, "paired_case_coverage", false) === true || push!(findings, _finding(
        "multiconductor_point_case_coverage_mismatch", "warning",
        "The point-policy comparison does not cover the same fixture set on both sides.",
        Dict("summary_path" => path);
        suggested_action = "Treat only explicitly paired fixtures as comparable."
    ))
    get(readiness, "environment_compatible", false) === true || push!(findings, _finding(
        "multiconductor_point_environment_mismatch", "warning",
        "The point-policy summaries have incompatible environment fingerprints.",
        Dict("summary_path" => path);
        suggested_action = "Align Julia, BMOPFTools, PowerIO, and fixture environments first."
    ))
    get(readiness, "distinct_point_policies", false) === true || push!(findings, _finding(
        "multiconductor_point_policy_not_distinct", "warning",
        "The point-policy comparison uses the same policy on both sides.",
        Dict("summary_path" => path);
        suggested_action = "Select distinct evaluation-point policies."
    ))
    overlap = _int(get(readiness, "successful_case_overlap", 0))
    overlap == 0 && push!(findings, _finding(
        "multiconductor_point_successful_overlap_empty", "warning",
        "No fixture was successful at both evaluation points.",
        Dict("summary_path" => path, "paired_case_count" => paired);
        suggested_action = "Use an explicit completion or synthetic policy before interpreting point-local changes."
    ))
    dense_budget = max(
        _int(get(readiness, "baseline_dense_budget", 0)),
        _int(get(readiness, "candidate_dense_budget", 0)),
    )
    dense_overlap = _int(get(readiness, "dense_rank_pair_available", 0))
    dense_budget > 0 && dense_overlap == 0 && push!(findings, _finding(
        "multiconductor_point_dense_rank_overlap_empty", "warning",
        "A dense-rank budget was requested, but no paired fixture has dense rank evidence at both points.",
        Dict("summary_path" => path, "dense_budget" => dense_budget,
             "dense_rank_pair_available" => dense_overlap);
        suggested_action = "Restrict dense checkpoints to small fixtures and preserve dense-rank availability on both sides."
    ))
    ambiguous_rank_changes = _int(get(readiness, "ambiguous_rank_change_count", 0))
    ambiguous_rank_changes > 0 && push!(findings, _finding(
        "multiconductor_point_rank_alignment_ambiguous", "warning",
        "Dense rank changed for paired fixtures whose declared physical modes are not coordinate-aligned; terminal port maps may still be complete.",
        Dict("summary_path" => path,
             "ambiguous_rank_change_count" => ambiguous_rank_changes,
             "alignment_blocked_case_count" => get(readiness, "alignment_blocked_case_count", 0));
        suggested_action = "Inspect terminal-to-model coordinate maps and source metadata before interpreting the rank change as a physical or formulation defect."
    ))
    dense_overlap > 0 && get(readiness, "port_map_alignment_pair_complete", false) !== true && push!(findings,
        _finding("multiconductor_point_port_map_alignment_incomplete", "warning",
            "The paired dense point comparison does not have complete terminal-port coordinate-map coverage on both sides.",
            Dict("summary_path" => path,
                 "dense_rank_pair_available" => dense_overlap,
                 "port_map_complete_case_count" => get(readiness, "port_map_complete_case_count", 0));
            suggested_action = "Restore or explicitly map missing terminal coordinates before interpreting point-local rank changes."
    ))
    dense_overlap > 0 && get(readiness, "mode_projection_pair_available", false) !== true && push!(findings,
        _finding("multiconductor_point_mode_projection_unavailable", "warning",
            "The paired dense point comparison lacks per-component physical-mode projection evidence.",
            Dict("summary_path" => path,
                 "dense_rank_pair_available" => dense_overlap,
                 "mode_projection_available_case_count" => get(readiness, "mode_projection_available_case_count", 0));
            suggested_action = "Declare and serialize per-component terminal-mode projections before interpreting rank changes."))
    dense_overlap > 0 && get(readiness, "mode_match_pair_available", false) !== true && push!(findings,
        _finding("multiconductor_point_mode_jacobian_match_unavailable", "warning",
            "The paired dense point comparison lacks per-component mode-to-Jacobian match evidence.",
            Dict("summary_path" => path,
                 "dense_rank_pair_available" => dense_overlap,
                 "mode_match_available_case_count" => get(readiness, "mode_match_available_case_count", 0));
            suggested_action = "Serialize the local expected-mode comparison before interpreting candidate visibility as an observed gauge."
    ))
    return Dict{String,Any}(
        "summary_path" => path, "paired_case_count" => paired,
        "readiness" => readiness, "findings" => findings,
    )
end

function _validate_operator_fingerprint(path, summary)
    findings = Any[]
    readiness = get(summary, "readiness", Dict())
    readiness isa AbstractDict || (readiness = Dict())
    case_count = _int(get(summary, "case_count", 0))
    successful = _int(get(summary, "successful_case_count", 0))
    errors = _int(get(summary, "error_case_count", 0))
    case_count == 0 && push!(findings, _finding(
        "operator_fingerprint_empty", "error",
        "The operator fingerprint summary contains no cases.",
        Dict("summary_path" => path);
        suggested_action = "Run the deterministic operator fingerprint corpus before interpreting its aggregate findings."
    ))
    errors > 0 && push!(findings, _finding(
        "operator_fingerprint_case_errors", "error",
        "One or more operator fingerprint cases failed during analysis.",
        Dict("case_count" => case_count, "successful_case_count" => successful,
             "error_case_count" => errors);
        suggested_action = "Inspect failed cases and do not treat aggregate operator evidence as complete."
    ))
    successful == case_count || push!(findings, _finding(
        "operator_fingerprint_incomplete", "error",
        "Not every selected operator fingerprint case completed successfully.",
        Dict("case_count" => case_count, "successful_case_count" => successful);
        suggested_action = "Rerun the missing or failed cases with the same package environment."
    ))
    for (stage, label) in (("static_stage_complete", "static"),
                           ("expression_stage_complete", "expression"),
                           ("initialization_stage_complete", "initialization"))
        get(readiness, stage, false) === true || push!(findings, _finding(
            "operator_fingerprint_$(label)_stage_incomplete", "warning",
            "The operator fingerprint summary does not contain a complete $(label) stage for every successful case.",
            Dict("summary_path" => path, "readiness" => readiness);
            suggested_action = "Preserve all three stages before comparing operator fingerprints across models."
        ))
    end
    return Dict{String,Any}(
        "summary_path" => path,
        "case_count" => case_count,
        "successful_case_count" => successful,
        "finding_code_counts" => get(summary, "finding_code_counts", Dict()),
        "readiness" => readiness,
        "findings" => findings,
    )
end

function _validate_repeat_summary(path, summary)
    findings = Any[]
    observations = _int(get(summary, "observation_count", 0))
    artifact_errors = get(summary, "artifact_errors", Any[])
    artifact_errors isa AbstractVector || (artifact_errors = Any[])
    baseline_inconsistency = _int(get(summary, "baseline_inconsistency_count", 0))
    repeatable = _int(get(summary, "repeatable_termination_change_count", 0))
    observations == 0 && push!(findings, _finding(
        "perturbation_repeat_summary_empty", "warning",
        "The repeat summary contains no completed family-perturbation observations.",
        Dict("summary_path" => path);
        suggested_action = "Run at least two explicitly identified replicates and preserve their matrix summaries."
    ))
    !isempty(artifact_errors) && push!(findings, _finding(
        "perturbation_repeat_artifact_errors", "warning",
        "One or more repeat artifacts are missing or failed before summarization.",
        Dict("artifact_error_count" => length(artifact_errors), "artifacts" => artifact_errors);
        suggested_action = "Inspect per-replicate process logs before generalizing repeatability."
    ))
    baseline_inconsistency > 0 && push!(findings, _finding(
        "perturbation_repeat_baseline_inconsistent", "warning",
        "Some solver/case/family pairs changed baseline termination across replicates.",
        Dict("baseline_inconsistency_count" => baseline_inconsistency);
        suggested_action = "Treat variant deltas as conditional on solver baseline behavior until the baseline is stabilized."
    ))
    repeat_count = _int(get(summary, "replicate_count", 0))
    stable_pairs = _int(get(summary, "stable_termination_pair_count", 0))
    readiness = Dict{String,Any}(
        "repeat_artifacts_complete" => isempty(artifact_errors) && observations > 0,
        "baseline_consistency" => baseline_inconsistency == 0,
        "repeatability_observed" => repeat_count >= 2 && (repeatable > 0 || stable_pairs > 0),
        "stable_termination_pair_count" => stable_pairs,
        "replicate_count" => repeat_count,
        "observation_count" => observations,
    )
    return Dict{String,Any}(
        "summary_path" => path,
        "readiness" => readiness,
        "baseline_inconsistency_count" => baseline_inconsistency,
        "repeatable_termination_change_count" => repeatable,
        "findings" => findings,
    )
end

function _validate_perturbation_corpus(path, summary)
    findings = Any[]
    pairs = _int(get(summary, "pair_count", 0))
    families = _int(get(summary, "family_count", 0))
    source_errors = _int(get(summary, "source_error_count", 0))
    disagreements = _int(get(summary, "solver_disagreement_count", 0))
    baseline_disagreements = _int(get(summary, "baseline_solver_disagreement_count", 0))
    variant_disagreements = _int(get(summary, "variant_termination_disagreement_count", 0))
    direction_disagreements = _int(get(summary, "iteration_direction_disagreement_count", 0))
    repeatability_unavailable = _int(get(summary, "repeatability_unavailable_count", 0))
    pairs == 0 && push!(findings, _finding(
        "perturbation_corpus_empty", "warning",
        "The corpus summary contains no solver/case/family pairs.",
        Dict("summary_path" => path);
        suggested_action = "Select multiple completed repeat summaries before interpreting recurrence."
    ))
    source_errors > 0 && push!(findings, _finding(
        "perturbation_corpus_source_errors", "warning",
        "Some source repeat summaries contain missing or failed artifacts.",
        Dict("source_error_count" => source_errors);
        suggested_action = "Inspect the source repeat manifests and process logs."
    ))
    disagreements > 0 && push!(findings, _finding(
        "perturbation_corpus_solver_disagreement", "warning",
        "Solvers disagree on repeated perturbation behavior for some case/family pairs.",
        Dict("solver_disagreement_count" => disagreements);
        suggested_action = "Keep solver-specific evidence separate and avoid treating disagreement as a physical conclusion."
    ))
    baseline_disagreements > 0 && push!(findings, _finding(
        "perturbation_corpus_baseline_solver_disagreement", "warning",
        "Solvers produced different baseline termination signatures for some case/family pairs.",
        Dict("baseline_solver_disagreement_count" => baseline_disagreements);
        suggested_action = "Keep solver-specific baselines separate before attributing variant deltas to the formulation."
    ))
    variant_disagreements > 0 && push!(findings, _finding(
        "perturbation_corpus_variant_solver_disagreement", "warning",
        "Solvers produced different variant termination signatures for some case/family pairs.",
        Dict("variant_termination_disagreement_count" => variant_disagreements);
        suggested_action = "Inspect per-solver traces and residual evidence; do not average variant outcomes."
    ))
    direction_disagreements > 0 && push!(findings, _finding(
        "perturbation_corpus_iteration_direction_disagreement", "warning",
        "Solvers disagree on the direction of iteration-count change for some case/family pairs.",
        Dict("iteration_direction_disagreement_count" => direction_disagreements);
        suggested_action = "Report solver-specific iteration sensitivity rather than a solver-independent effect."
    ))
    return Dict{String,Any}(
        "summary_path" => path,
        "pair_count" => pairs, "family_count" => families,
        "structured_findings" => get(summary, "findings", Any[]),
        "readiness" => Dict(
            "corpus_observations" => pairs > 0 && families > 0 && source_errors == 0,
            "solver_agreement_available" => _int(get(summary, "solver_agreement_pair_count", 0)) > 0,
            "solver_disagreement_free" => disagreements == 0,
            "repeatability_available_pair_count" => max(
                0, _int(get(summary, "solver_agreement_pair_count", 0)) - repeatability_unavailable,
            ),
            "baseline_solver_alignment" => baseline_disagreements == 0,
            "variant_solver_alignment" => variant_disagreements == 0,
            "iteration_direction_alignment" => direction_disagreements == 0,
        ),
        "findings" => findings,
    )
end

function _validate_evidence_ledger(path, ledger)
    findings = Any[]
    sources = _int(get(ledger, "source_count", 0))
    records = _int(get(ledger, "finding_count", 0))
    identities = _int(get(ledger, "identity_count", 0))
    sources == 0 && push!(findings, _finding(
        "evidence_ledger_no_sources", "warning",
        "The evidence ledger contains no source reports.", Dict("summary_path" => path);
        suggested_action = "Provide corpus, validation, or campaign reports explicitly."
    ))
    records == 0 && push!(findings, _finding(
        "evidence_ledger_empty", "warning",
        "The evidence ledger contains no findings.", Dict("summary_path" => path);
        suggested_action = "Treat an empty ledger as absence of recorded findings, not proof of a clean model."
    ))
    return Dict{String,Any}(
        "summary_path" => path,
        "source_count" => sources, "finding_count" => records,
        "identity_count" => identities,
        "readiness" => Dict("ledger_available" => sources > 0,
                            "findings_available" => records > 0),
        "findings" => findings,
    )
end

function _validate_evidence_ledger_comparison(path, comparison)
    findings = Any[]
    identities = _int(get(comparison, "identity_count", 0))
    changed = _int(get(comparison, "distribution_changed_count", 0))
    compatibility = get(comparison, "compatibility", Dict())
    compatibility isa AbstractDict || (compatibility = Dict())
    compatibility_status = String(get(compatibility, "status", "unknown"))
    identities == 0 && push!(findings, _finding(
        "evidence_ledger_comparison_empty", "warning",
        "The ledger comparison contains no finding identities.", Dict("summary_path" => path);
        suggested_action = "Compare ledgers produced from comparable campaigns."
    ))
    changed > 0 && push!(findings, _finding(
        "evidence_ledger_distribution_changes", "warning",
        "Some persistent finding identities changed severity or confidence distributions.",
        Dict("distribution_changed_count" => changed);
        suggested_action = "Inspect source-level evidence before attributing changes to the model or solver."
    ))
    compatibility_status == "incompatible" && push!(findings, _finding(
        "evidence_ledger_campaign_incompatible", "warning",
        "The compared ledgers have incompatible campaign provenance.",
        compatibility;
        suggested_action = "Compare ledgers only after aligning selected cases, solvers, families, and environment fingerprints."
    ))
    compatibility_status == "unknown" && push!(findings, _finding(
        "evidence_ledger_campaign_compatibility_unknown", "info",
        "Some ledger compatibility fields are unavailable.",
        compatibility;
        suggested_action = "Regenerate ledgers with explicit provenance metadata."
    ))
    return Dict{String,Any}(
        "summary_path" => path, "identity_count" => identities,
        "readiness" => Dict("comparison_available" => identities > 0,
                            "distribution_stability" => changed == 0,
                            "campaign_compatibility" => compatibility_status == "compatible"),
        "findings" => findings,
    )
end

function _validate_solver_repeat_summary(path, summary)
    findings = Any[]
    configurations = get(summary, "configurations", Any[])
    comparisons = get(summary, "comparisons", Any[])
    isempty(configurations) && push!(findings, _finding(
        "solver_repeat_configuration_empty", "warning",
        "The solver-repeat summary contains no configuration observations.",
        Dict("summary_path" => path);
        suggested_action = "Provide completed solver-trace summaries for each policy."
    ))
    configuration_row_scale_ready = true
    configuration_row_scale_repeatable = true
    for raw_configuration in configurations
        raw_configuration isa AbstractDict || continue
        label = String(get(raw_configuration, "label", "unknown"))
        for raw_case in get(raw_configuration, "cases", Any[])
            raw_case isa AbstractDict || continue
            recurrence = get(raw_case, "recurrence", Dict())
            recurrence isa AbstractDict || (recurrence = Dict())
            available = get(recurrence, "row_family_scale_available", false) === true
            stable = get(recurrence, "row_family_scale_ratio_stable", false) === true
            configuration_row_scale_ready &= available
            configuration_row_scale_repeatable &= available && stable
            !available && push!(findings, _finding(
                "solver_repeat_row_family_scale_unavailable", "warning",
                "A repeated solver configuration has no row-family scale attribution.",
                Dict("summary_path" => path, "configuration" => label,
                     "case" => get(raw_case, "name", "unknown"));
                suggested_action = "Rerun the numerical stage with the compact BMOPF attribution enabled."
            ))
            available && !stable && push!(findings, _finding(
                "solver_repeat_row_family_scale_not_stable", "warning",
                "Row-family scale ratios differ across repeats for a configuration/case.",
                Dict("summary_path" => path, "configuration" => label,
                     "case" => get(raw_case, "name", "unknown"));
                suggested_action = "Inspect endpoint, environment, and solver trace provenance before interpreting policy effects."
            ))
        end
    end
    paired_row_scale_ready = true
    paired_row_scale_repeatable = true
    semantic_changes = 0
    numerical_readiness_changes = 0
    for raw_comparison in comparisons
        raw_comparison isa AbstractDict || continue
        candidate = String(get(raw_comparison, "candidate_label", "unknown"))
        comparison = get(raw_comparison, "summary", Dict())
        comparison isa AbstractDict || (comparison = Dict())
        paired = _int(get(comparison, "paired_replicate_count", 0))
        paired > 0 || push!(findings, _finding(
            "solver_repeat_paired_observations_empty", "warning",
            "A solver-policy comparison has no paired repeat observations.",
            Dict("summary_path" => path, "candidate" => candidate);
            suggested_action = "Use manifests with the same configuration labels in each repeat."
        ))
        row_range = get(comparison, "row_family_scale_ratio_delta_range", Dict())
        row_range isa AbstractDict || (row_range = Dict())
        row_available = get(row_range, "available", false) === true
        row_stable = get(comparison, "row_family_scale_ratio_delta_stable", false) === true
        paired_row_scale_ready &= row_available
        paired_row_scale_repeatable &= row_available && row_stable
        !row_available && paired > 0 && push!(findings, _finding(
            "solver_repeat_row_family_delta_unavailable", "warning",
            "A paired solver-policy comparison has no row-family scale delta evidence.",
            Dict("summary_path" => path, "candidate" => candidate);
            suggested_action = "Retain the row-family attribution envelope in each numerical-stage summary."
        ))
        row_available && !row_stable && push!(findings, _finding(
            "solver_repeat_row_family_delta_not_stable", "warning",
            "A paired row-family scale delta is not stable across repeats.",
            Dict("summary_path" => path, "candidate" => candidate);
            suggested_action = "Treat the policy delta as provisional and inspect endpoint reproducibility."
        ))
        semantic_changes += _int(get(comparison, "semantic_finding_change_count", 0))
        numerical_readiness_changes += _int(get(comparison, "numerical_readiness_change_count", 0))
    end
    semantic_changes > 0 && push!(findings, _finding(
        "solver_repeat_semantic_finding_changes", "warning",
        "Repeated solver-policy comparisons changed semantic finding codes.",
        Dict("summary_path" => path, "change_count" => semantic_changes);
        suggested_action = "Apply endpoint triangulation before promoting the change to a formulation-level claim."
    ))
    numerical_readiness_changes > 0 && push!(findings, _finding(
        "solver_repeat_numerical_readiness_changes", "warning",
        "Repeated solver-policy comparisons changed numerical readiness.",
        Dict("summary_path" => path, "change_count" => numerical_readiness_changes);
        suggested_action = "Inspect dense/sparse budgets and evaluation-point provenance."
    ))
    return Dict{String,Any}(
        "summary_path" => path,
        "readiness" => Dict(
            "configuration_row_family_scale_available" => configuration_row_scale_ready,
            "configuration_row_family_scale_repeatable" => configuration_row_scale_repeatable,
            "paired_row_family_delta_available" => paired_row_scale_ready,
            "paired_row_family_delta_repeatable" => paired_row_scale_repeatable,
            "semantic_finding_changes" => semantic_changes,
            "numerical_readiness_changes" => numerical_readiness_changes,
        ),
        "findings" => findings,
    )
end

function main()
    length(ARGS) >= 2 || error("usage: validate_bmopf_campaign.jl output.json summary1.json ...")
    output_path = abspath(first(ARGS))
    campaign_reports = Any[]
    comparison_reports = Any[]
    policy_matrix_reports = Any[]
    point_calibration_reports = Any[]
    solver_matrix_reports = Any[]
    controller_reports = Any[]
    solver_trace_reports = Any[]
    trace_comparison_reports = Any[]
    multiconductor_reports = Any[]
    multiconductor_probe_comparisons = Any[]
    multiconductor_point_comparisons = Any[]
    operator_reports = Any[]
    repeat_reports = Any[]
    solver_repeat_reports = Any[]
    perturbation_corpus_reports = Any[]
    evidence_ledger_reports = Any[]
    evidence_ledger_comparison_reports = Any[]
    all_findings = Any[]
    environments = Any[]
    for raw_path in ARGS[2:end]
        path = abspath(raw_path)
        summary = _load(path)
        runner_version = something(get(summary, "runner_version", nothing), "")
        report_version = something(get(summary, "report_version", nothing), "")
        if startswith(runner_version, "bmopf-evidence-ledger-comparison-")
            report = _validate_evidence_ledger_comparison(path, summary)
            push!(evidence_ledger_comparison_reports, report)
        elseif startswith(runner_version, "bmopf-evidence-ledger-")
            report = _validate_evidence_ledger(path, summary)
            push!(evidence_ledger_reports, report)
        elseif startswith(report_version, "bmopf-controller-campaign-summary-")
            report = _validate_controller_campaign(path, summary)
            push!(controller_reports, report)
        elseif startswith(report_version, "bmopf-saved-result-persistence-") &&
               haskey(summary, "controller_curve_snapshots")
            controller_summary = _controller_snapshot_summary(summary)
            report = _validate_controller_report(path, controller_summary;
                scope = "saved_result_controller_snapshots")
            push!(controller_reports, report)
        elseif startswith(runner_version, "bmopf-solver-trace-")
            report = _validate_solver_trace(path, summary)
            push!(solver_trace_reports, report)
        elseif haskey(summary, "comparisons") && any(
            raw -> raw isa AbstractDict &&
                get(raw, "comparison", nothing) isa AbstractDict &&
                haskey(get(raw, "comparison", Dict()), "controller_curve_trace"),
            get(summary, "comparisons", Any[]),
        )
            report = _validate_trace_comparison(path, summary)
            push!(trace_comparison_reports, report)
        elseif startswith(runner_version, "bmopf-perturbation-corpus-")
            report = _validate_perturbation_corpus(path, summary)
            push!(perturbation_corpus_reports, report)
        elseif startswith(report_version, "bmopf-multiconductor-smoke-summary-")
            report = _validate_multiconductor_smoke(path, summary)
            push!(multiconductor_reports, report)
        elseif startswith(report_version, "bmopf-multiconductor-probe-comparison-")
            report = _validate_multiconductor_probe_comparison(path, summary)
            push!(multiconductor_probe_comparisons, report)
        elseif startswith(report_version, "bmopf-multiconductor-point-comparison-")
            report = _validate_multiconductor_point_comparison(path, summary)
            push!(multiconductor_point_comparisons, report)
        elseif startswith(report_version, "nlpdiagnostics-operator-fingerprint-summary-")
            report = _validate_operator_fingerprint(path, summary)
            push!(operator_reports, report)
        elseif startswith(report_version, "bmopf-solver-repeats-")
            report = _validate_solver_repeat_summary(path, summary)
            push!(solver_repeat_reports, report)
        elseif haskey(summary, "repeat_index") && haskey(summary, "by_pair")
            report = _validate_repeat_summary(path, summary)
            push!(repeat_reports, report)
        elseif haskey(summary, "solver_summaries") && haskey(summary, "comparisons")
            report = _validate_solver_matrix(path, summary)
            push!(solver_matrix_reports, report)
        elseif startswith(report_version, "bmopf-result-policy-matrix-summary-")
            report = _validate_policy_matrix(path, summary)
            push!(policy_matrix_reports, report)
        elseif startswith(report_version, "bmopf-point-calibration-")
            report = _validate_point_calibration(path, summary)
            push!(point_calibration_reports, report)
        elseif startswith(runner_version, "bmopf-result-policy-matrix-")
            report = _validate_policy_matrix_manifest(path, summary)
            push!(policy_matrix_reports, report)
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
        "policy_matrix_reports" => policy_matrix_reports,
        "point_calibration_reports" => point_calibration_reports,
        "solver_matrix_reports" => solver_matrix_reports,
        "controller_reports" => controller_reports,
        "solver_trace_reports" => solver_trace_reports,
        "trace_comparison_reports" => trace_comparison_reports,
        "multiconductor_reports" => multiconductor_reports,
        "multiconductor_probe_comparisons" => multiconductor_probe_comparisons,
        "multiconductor_point_comparisons" => multiconductor_point_comparisons,
        "operator_reports" => operator_reports,
        "solver_repeat_reports" => solver_repeat_reports,
        "perturbation_repeat_reports" => repeat_reports,
        "perturbation_corpus_reports" => perturbation_corpus_reports,
        "evidence_ledger_reports" => evidence_ledger_reports,
        "evidence_ledger_comparison_reports" => evidence_ledger_comparison_reports,
        "findings" => all_findings,
        "interpretation" => "Trust-gate validation only; warnings identify unavailable or conditional evidence and are not model-quality scores.",
    )
    write(output_path, JSON.json(payload))
    println("wrote BMOPF campaign validation report to $output_path")
end

main()
