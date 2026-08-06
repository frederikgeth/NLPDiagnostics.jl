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
    semantic_registered = attribution isa AbstractDict ?
                          _int(get(attribution, "registered_constraint_row_count_total", 0)) : 0
    semantic_unregistered = attribution isa AbstractDict ?
                            _int(get(attribution, "unregistered_constraint_row_count_total", 0)) : 0
    semantic_model_rows = attribution isa AbstractDict ?
                          _int(get(attribution, "model_constraint_row_count_total", 0)) : 0
    semantic_model_registered = attribution isa AbstractDict ?
                                _int(get(attribution, "model_registered_constraint_row_count_total", 0)) : 0
    semantic_model_unregistered = attribution isa AbstractDict ?
                                  _int(get(attribution, "model_unregistered_constraint_row_count_total", 0)) : 0
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
    semantic_ready = profile_cases == 0 || attribution_cases >= profile_cases
    semantic_unregistered > 0 && push!(findings, _finding(
        "constraint_semantic_registry_boundary", "warning",
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
    return Dict{String,Any}(
        "summary_path" => path,
        "solver_count" => solver_count,
        "successful_solver_count" => successful,
        "paired_comparison_count" => comparison_count,
        "readiness" => Dict(
            "solver_matrix_success" => solver_count > 0 && successful == solver_count,
            "solver_matrix_alignment" => comparison_count > 0,
            "family_perturbation_matrix" => get(family_readiness, "matrix_available", false),
            "family_perturbation_repeatability" => get(family_readiness, "repeatability_observed", false),
        ),
        "family_perturbation" => family_readiness,
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

function main()
    length(ARGS) >= 2 || error("usage: validate_bmopf_campaign.jl output.json summary1.json ...")
    output_path = abspath(first(ARGS))
    campaign_reports = Any[]
    comparison_reports = Any[]
    solver_matrix_reports = Any[]
    repeat_reports = Any[]
    perturbation_corpus_reports = Any[]
    evidence_ledger_reports = Any[]
    evidence_ledger_comparison_reports = Any[]
    all_findings = Any[]
    environments = Any[]
    for raw_path in ARGS[2:end]
        path = abspath(raw_path)
        summary = _load(path)
        if startswith(String(get(summary, "runner_version", "")), "bmopf-evidence-ledger-comparison-")
            report = _validate_evidence_ledger_comparison(path, summary)
            push!(evidence_ledger_comparison_reports, report)
        elseif startswith(String(get(summary, "runner_version", "")), "bmopf-evidence-ledger-")
            report = _validate_evidence_ledger(path, summary)
            push!(evidence_ledger_reports, report)
        elseif startswith(String(get(summary, "runner_version", "")), "bmopf-perturbation-corpus-")
            report = _validate_perturbation_corpus(path, summary)
            push!(perturbation_corpus_reports, report)
        elseif haskey(summary, "repeat_index") && haskey(summary, "by_pair")
            report = _validate_repeat_summary(path, summary)
            push!(repeat_reports, report)
        elseif haskey(summary, "solver_summaries") && haskey(summary, "comparisons")
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
