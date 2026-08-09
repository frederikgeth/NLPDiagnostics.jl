#!/usr/bin/env julia

"""Summarize BMOPF multiconductor smoke records without scoring them."""

using JSON

_as_dict(value) = value isa AbstractDict ?
    Dict{String,Any}(string(k) => v for (k, v) in value) : Dict{String,Any}()

function _int(value, default = 0)
    value isa Integer && return Int(value)
    value isa Number && isfinite(Float64(value)) && return Int(value)
    try
        return parse(Int, String(value))
    catch
        return default
    end
end

function _float_list(value)
    value isa AbstractVector && return Float64[
        Float64(item) for item in value if item isa Number && isfinite(Float64(item))
    ]
    value isa AbstractString || return Float64[]
    isempty(strip(value)) && return Float64[]
    result = Float64[]
    for token in split(value, ',')
        parsed = try parse(Float64, strip(token)) catch; NaN end
        isfinite(parsed) && push!(result, parsed)
    end
    return result
end

function _schema_warning_field(message)
    match_result = match(r"`([^`]+)`", String(message))
    isnothing(match_result) ? nothing : String(match_result.captures[1])
end

function _schema_warning_scope(message)
    token = split(String(message), ' '; limit = 2)[1]
    token = replace(token, ':' => "")
    isempty(token) ? nothing : token
end

function _schema_warning_impact(field)
    field = String(field)
    field == "units" && return "representational"
    field == "model" && return "device_semantics"
    field in ("angle", "basekv", "kv", "phases", "vmaxpu", "vminpu") &&
        return "physical_or_operating_point"
    return "unknown"
end

function _schema_warning_policy(field)
    field = String(field)
    field == "units" && return Dict{String,Any}(
        "status" => "intentionally_unsupported",
        "impact" => "representational",
        "physical_readiness_blocking" => false,
        "action" => "Retain source units as provenance; do not infer physical units from the BMOPF record.",
    )
    field == "model" && return Dict{String,Any}(
        "status" => "unsupported_device_semantics",
        "impact" => "device_semantics",
        "physical_readiness_blocking" => true,
        "action" => "Map the source device model into an explicit BMOPF component or plugin contract.",
    )
    field in ("angle", "basekv", "kv", "phases", "vmaxpu", "vminpu") && return Dict{String,Any}(
        "status" => "unsupported_physical_metadata",
        "impact" => "physical_or_operating_point",
        "physical_readiness_blocking" => true,
        "action" => "Preserve and map this field before interpreting physical modes, limits, or operating-point evidence.",
    )
    return Dict{String,Any}(
        "status" => "unclassified_drop",
        "impact" => "unknown",
        "physical_readiness_blocking" => true,
        "action" => "Add an explicit source-to-BMOPF field policy before using the affected record.",
    )
end

function _load(path)
    isfile(path) || error("missing smoke report: $path")
    value = JSON.parsefile(path)
    value isa AbstractDict || error("smoke report is not a JSON object: $path")
    return value
end

function _contract_view(contract)
    contract = _as_dict(contract)
    scalar_keys = (
        "voltage_port_count", "voltage_coordinate_map_count", "voltage_connection_count",
        "current_port_count", "current_coordinate_map_count", "current_law_fingerprint_count",
        "current_law_operating_point_probe_count", "constitutive_map_count",
        "complex_constitutive_map_count", "physical_mode_count",
        "passive_network_current_map_count", "passive_network_current_model_map_count",
        "port_assembly_component_count", "port_assembly_connected_component_count",
        "current_skipped_count", "controller_curve_observation_count",
    )
    result = Dict{String,Any}()
    for key in scalar_keys
        haskey(contract, key) && (result[key] = contract[key])
    end
    for key in ("current_law_families", "current_law_operating_point_statuses",
                "physical_mode_categories", "controller_curve_families",
                "controller_curve_statuses")
        haskey(contract, key) && (result[key] = contract[key])
    end
    for key in ("voltage_coordinate_alignment", "current_coordinate_alignment",
                "physical_mode_projections")
        haskey(contract, key) && (result[key] = contract[key])
    end
    finding_count = 0
    for key in ("voltage_report_finding_count", "port_assembly_finding_count",
                "current_report_finding_count", "current_law_finding_count",
                "current_law_operating_point_finding_count",
                "constitutive_map_finding_count", "complex_constitutive_map_finding_count",
                "physical_mode_finding_count", "passive_network_current_map_finding_count",
                "passive_network_current_model_map_finding_count")
        finding_count += _int(get(contract, key, 0))
    end
    result["contract_finding_count"] = finding_count
    return result
end

function _case_record(root, entry)
    entry = _as_dict(entry)
    result_file = get(entry, "result_file", nothing)
    result_file isa AbstractString || return Dict{String,Any}(
        "name" => get(entry, "name", "unknown"),
        "status" => get(entry, "status", "unknown"),
        "error" => "result_file is unavailable",
    )
    path = joinpath(root, result_file)
    record = isfile(path) ? _load(path) : Dict{String,Any}()
    source_snapshot = _as_dict(get(record, "source_snapshot", get(entry, "source_snapshot", nothing)))
    preflight = _as_dict(get(record, "integrity_preflight", nothing))
    source_warning_values = get(preflight, "source_schema_warnings", Any[])
    source_warning_values isa AbstractVector || (source_warning_values = Any[source_warning_values])
    source_warning_messages = String[String(value) for value in source_warning_values]
    source_warning_fields = String[field for value in source_warning_messages for field in
        (_schema_warning_field(value),) if !isnothing(field)]
    source_warning_scopes = String[scope for value in source_warning_messages for scope in
        (_schema_warning_scope(value),) if !isnothing(scope)]
    source_warning_impacts = String[_schema_warning_impact(field) for field in source_warning_fields]
    source_warning_policies = Dict{String,Any}[_schema_warning_policy(field) for field in source_warning_fields]
    contract = _contract_view(get(record, "multiconductor_contract", nothing))
    physical_mode_projection_matches = _as_dict(
        get(record, "physical_mode_projection_matches", nothing),
    )
    !isempty(physical_mode_projection_matches) &&
        (contract["physical_mode_projection_matches"] = physical_mode_projection_matches)
    mode_analysis = _as_dict(get(record, "physical_mode_analysis", nothing))
    mode_metadata = _as_dict(get(mode_analysis, "metadata", nothing))
    mode_codes = _as_dict(get(mode_analysis, "finding_code_counts", nothing))
    mode_int(code) = _int(get(mode_codes, code, 0))
    dense_limit = _int(get(entry, "rank_max_dense_entries", get(record, "rank_max_dense_entries", 0)))
    dense_entries = _int(get(entry, "jacobian_dense_entry_count", get(record, "jacobian_dense_entry_count", 0)))
    dense_guard_allows = dense_limit > 0 && dense_entries <= dense_limit
    mode_rank_available = dense_guard_allows &&
                          lowercase(string(get(mode_metadata, "jacobian_rank_available", "false"))) == "true"
    mode_jacobian_rank = _int(get(mode_metadata, "jacobian_rank", 0))
    expected_modes = _int(get(mode_metadata, "bmopf_port_physical_modes_applied", 0))
    observed_modes = mode_int("expected_nullspace_mode_observed") +
                     mode_int("component_port_nullspace_mode_observed")
    unaligned_modes = mode_int("expected_nullspace_mode_unaligned") +
                      mode_int("component_port_nullspace_mode_unaligned")
    not_observed_modes = mode_int("expected_nullspace_mode_not_observed") +
                         mode_int("component_port_nullspace_mode_not_observed")
    partial_modes = mode_int("expected_nullspace_mode_partial_alignment")
    mode_status = if isempty(mode_analysis)
        "unavailable"
    elseif !mode_rank_available
        "rank_unavailable"
    elseif unaligned_modes > 0
        "coordinate_alignment_boundary"
    elseif observed_modes > 0
        "observed"
    elseif not_observed_modes > 0
        "not_observed"
    else
        "no_comparison_finding"
    end
    profile = _as_dict(get(record, "profile", nothing))
    profile_body = _as_dict(get(profile, "profile", nothing))
    reports = _as_dict(get(profile_body, "reports", nothing))
    numerical = _as_dict(get(reports, "numerical", nothing))
    numerical_metadata = _as_dict(get(numerical, "metadata", nothing))
    probe_requested = _int(get(entry, "iterative_right_nullspace_probe_dimension",
                               get(record, "iterative_right_nullspace_probe_dimension", 0)))
    probe_iterations = _int(get(entry, "iterative_right_nullspace_probe_iterations",
                               get(record, "iterative_right_nullspace_probe_iterations", 0)))
    probe_available = lowercase(string(get(numerical_metadata, "iterative_probe_available", "false"))) == "true"
    probe_converged = lowercase(string(get(numerical_metadata, "iterative_probe_converged", "false"))) == "true"
    probe_candidate_count = _int(get(numerical, "finding_code_counts", Dict()) isa AbstractDict ?
        get(get(numerical, "finding_code_counts", Dict()), "iterative_jacobian_candidate_small_residual_direction", 0) : 0)
    probe_no_small_residual_count = _int(get(get(numerical, "finding_code_counts", Dict()),
        "iterative_jacobian_no_small_residual_direction", 0))
    probe_unavailable_count = _int(get(get(numerical, "finding_code_counts", Dict()),
        "iterative_jacobian_nullspace_probe_unavailable", 0))
    probe_residual_norms = _float_list(get(numerical_metadata, "iterative_probe_residual_norms", ""))
    probe_residual_scale = try
        parsed = parse(Float64, String(get(numerical_metadata, "iterative_probe_residual_scale", "NaN")))
        isfinite(parsed) ? parsed : nothing
    catch
        nothing
    end
    return Dict{String,Any}(
        "name" => get(entry, "name", "unknown"),
        "fixture" => get(record, "fixture", nothing),
        "status" => get(entry, "status", get(record, "status", "unknown")),
        "result_file" => result_file,
        "source_snapshot" => source_snapshot,
        "model_variable_count" => get(record, "model_variable_count", nothing),
        "scalar_constraint_row_count" => get(record, "scalar_constraint_row_count", nothing),
        "jacobian_dense_entry_count" => get(record, "jacobian_dense_entry_count", nothing),
        "rank_max_dense_entries" => get(record, "rank_max_dense_entries", nothing),
        "dense_rank_analysis_eligible" => get(record, "dense_rank_analysis_eligible", nothing),
        "integrity_preflight" => Dict(
            "error_count" => _int(get(preflight, "error_count", 0)),
            "warning_count" => _int(get(preflight, "warning_count", 0)),
            "source_schema_warning_count" => _int(get(preflight, "source_schema_warning_count", 0)),
            "blocking" => get(preflight, "blocking", false),
            "source_schema_warning_messages" => source_warning_messages,
            "source_schema_warning_fields" => source_warning_fields,
            "source_schema_warning_scopes" => source_warning_scopes,
            "source_schema_warning_impacts" => source_warning_impacts,
            "source_schema_warning_policies" => source_warning_policies,
        ),
        "multiconductor_contract" => contract,
        "physical_mode_comparison" => Dict(
            "status" => mode_status,
            "expected_mode_count" => expected_modes,
            "observed_mode_count" => observed_modes,
            "unaligned_mode_count" => unaligned_modes,
            "not_observed_mode_count" => not_observed_modes,
            "partial_alignment_mode_count" => partial_modes,
            "jacobian_rank_available" => mode_rank_available,
            "jacobian_rank" => mode_jacobian_rank,
            "sparse_qr_rank" => _int(get(numerical_metadata, "sparse_qr_rank", 0)),
            "dense_guard_allows" => dense_guard_allows,
            "finding_code_counts" => mode_codes,
        ),
        "iterative_right_nullspace_probe" => Dict(
            "requested_dimension" => probe_requested,
            "iterations" => probe_iterations,
            "available" => probe_requested > 0 && probe_available,
            "converged" => probe_requested > 0 && probe_converged,
            "candidate_count" => probe_candidate_count,
            "no_small_residual_count" => probe_no_small_residual_count,
            "residual_norms" => probe_residual_norms,
            "residual_scale" => probe_residual_scale,
            "unavailable_finding_count" => probe_unavailable_count,
        ),
    )
end

function main()
    length(ARGS) in (1, 2) || error(
        "usage: summarize_bmopf_multiconductor_smoke.jl smoke-index.json [summary.json]",
    )
    index_path = abspath(first(ARGS))
    index = _load(index_path)
    root = dirname(index_path)
    output_path = length(ARGS) == 2 ? abspath(ARGS[2]) : joinpath(root, "summary.json")
    entries = get(index, "cases", Any[])
    entries isa AbstractVector || (entries = Any[])
    cases = [_case_record(root, entry) for entry in entries]
    status_counts = Dict{String,Int}()
    integrity_errors = 0
    integrity_warnings = 0
    source_schema_warnings = 0
    source_snapshot_cases = 0
    source_warning_message_counts = Dict{String,Int}()
    source_warning_field_counts = Dict{String,Int}()
    source_warning_scope_counts = Dict{String,Int}()
    source_warning_impact_counts = Dict{String,Int}()
    source_warning_policy_status_counts = Dict{String,Int}()
    source_schema_field_policies = Dict{String,Any}()
    source_warning_fixture_counts = Dict{String,Any}()
    physical_metadata_warning_count = 0
    contract_available = 0
    physical_mode_count = 0
    contract_finding_count = 0
    mode_analysis_cases = 0
    mode_rank_available_cases = 0
    expected_mode_count = 0
    observed_mode_count = 0
    unaligned_mode_count = 0
    not_observed_mode_count = 0
    partial_alignment_mode_count = 0
    iterative_probe_requested_cases = 0
    iterative_probe_available_cases = 0
    iterative_probe_converged_cases = 0
    iterative_probe_candidate_count = 0
    iterative_probe_unavailable_count = 0
    iterative_probe_no_small_residual_count = 0
    mode_status_counts = Dict{String,Int}()
    mode_projection_cases = 0
    mode_projection_visible_count = 0
    mode_projection_hidden_count = 0
    mode_projection_unrepresented_count = 0
    mode_match_cases = 0
    mode_match_observed_count = 0
    mode_match_not_observed_count = 0
    mode_match_outside_free_count = 0
    mode_match_partial_count = 0
    mode_match_projected_observed_count = 0
    mode_match_projected_not_observed_count = 0
    for case in cases
        status = String(get(case, "status", "unknown"))
        status_counts[status] = get(status_counts, status, 0) + 1
        preflight = _as_dict(get(case, "integrity_preflight", nothing))
        integrity_errors += _int(get(preflight, "error_count", 0))
        integrity_warnings += _int(get(preflight, "warning_count", 0))
        source_schema_warnings += _int(get(preflight, "source_schema_warning_count", 0))
        snapshot = _as_dict(get(case, "source_snapshot", nothing))
        get(snapshot, "preserved", false) === true && (source_snapshot_cases += 1)
        fixture_key = String(get(case, "name", "unknown"))
        fixture_profile = get!(source_warning_fixture_counts, fixture_key, Dict{String,Any}(
            "warning_count" => 0,
            "field_counts" => Dict{String,Int}(),
            "scope_counts" => Dict{String,Int}(),
            "message_counts" => Dict{String,Int}(),
            "impact_counts" => Dict{String,Int}(),
            "policy_status_counts" => Dict{String,Int}(),
        ))
        fixture_profile["warning_count"] += _int(get(preflight, "source_schema_warning_count", 0))
        for message in get(preflight, "source_schema_warning_messages", Any[])
            key = String(message)
            source_warning_message_counts[key] = get(source_warning_message_counts, key, 0) + 1
            message_counts = fixture_profile["message_counts"]
            message_counts[key] = get(message_counts, key, 0) + 1
        end
        for field in get(preflight, "source_schema_warning_fields", Any[])
            key = String(field)
            source_warning_field_counts[key] = get(source_warning_field_counts, key, 0) + 1
            field_counts = fixture_profile["field_counts"]
            field_counts[key] = get(field_counts, key, 0) + 1
        end
        for scope in get(preflight, "source_schema_warning_scopes", Any[])
            key = String(scope)
            source_warning_scope_counts[key] = get(source_warning_scope_counts, key, 0) + 1
            scope_counts = fixture_profile["scope_counts"]
            scope_counts[key] = get(scope_counts, key, 0) + 1
        end
        for impact in get(preflight, "source_schema_warning_impacts", Any[])
            key = String(impact)
            source_warning_impact_counts[key] = get(source_warning_impact_counts, key, 0) + 1
            impact_counts = fixture_profile["impact_counts"]
            impact_counts[key] = get(impact_counts, key, 0) + 1
            key != "representational" && (physical_metadata_warning_count += 1)
        end
        for policy in get(preflight, "source_schema_warning_policies", Any[])
            policy_dict = _as_dict(policy)
            status_key = String(get(policy_dict, "status", "unknown"))
            source_warning_policy_status_counts[status_key] =
                get(source_warning_policy_status_counts, status_key, 0) + 1
            policy_counts = fixture_profile["policy_status_counts"]
            policy_counts[status_key] = get(policy_counts, status_key, 0) + 1
        end
        for (field, policy) in zip(get(preflight, "source_schema_warning_fields", Any[]),
                                   get(preflight, "source_schema_warning_policies", Any[]))
            source_schema_field_policies[String(field)] = policy
        end
        contract = _as_dict(get(case, "multiconductor_contract", nothing))
        !isempty(contract) && (contract_available += 1)
        physical_mode_count += _int(get(contract, "physical_mode_count", 0))
        mode_projection = _as_dict(get(contract, "physical_mode_projections", nothing))
        if _int(get(mode_projection, "mode_count", 0)) > 0
            mode_projection_cases += 1
            mode_projection_visible_count += _int(get(mode_projection, "visible_count", 0))
            mode_projection_hidden_count += _int(get(mode_projection, "hidden_count", 0))
            mode_projection_unrepresented_count += _int(get(mode_projection, "unrepresented_count", 0))
        end
        mode_matches = _as_dict(get(contract, "physical_mode_projection_matches", nothing))
        if _int(get(mode_matches, "mode_count", 0)) > 0
            mode_match_cases += 1
            mode_match_observed_count += _int(get(mode_matches, "observed_count", 0))
            mode_match_not_observed_count += _int(get(mode_matches, "not_observed_count", 0))
            mode_match_outside_free_count += _int(get(mode_matches, "outside_free_coordinates_count", 0))
            mode_match_partial_count += _int(get(mode_matches, "partial_alignment_count", 0))
            mode_match_projected_observed_count += _int(get(mode_matches, "projected_observed_count", 0))
            mode_match_projected_not_observed_count += _int(get(mode_matches, "projected_not_observed_count", 0))
        end
        contract_finding_count += _int(get(contract, "contract_finding_count", 0))
        comparison = _as_dict(get(case, "physical_mode_comparison", nothing))
        if !isempty(comparison)
            mode_analysis_cases += 1
            status = String(get(comparison, "status", "unknown"))
            mode_status_counts[status] = get(mode_status_counts, status, 0) + 1
            mode_rank_available_cases += get(comparison, "jacobian_rank_available", false) === true ? 1 : 0
            expected_mode_count += _int(get(comparison, "expected_mode_count", 0))
            observed_mode_count += _int(get(comparison, "observed_mode_count", 0))
            unaligned_mode_count += _int(get(comparison, "unaligned_mode_count", 0))
            not_observed_mode_count += _int(get(comparison, "not_observed_mode_count", 0))
            partial_alignment_mode_count += _int(get(comparison, "partial_alignment_mode_count", 0))
        end
        probe = _as_dict(get(case, "iterative_right_nullspace_probe", nothing))
        requested_dimension = _int(get(probe, "requested_dimension", 0))
        if requested_dimension > 0
            iterative_probe_requested_cases += 1
            get(probe, "available", false) === true && (iterative_probe_available_cases += 1)
            get(probe, "converged", false) === true && (iterative_probe_converged_cases += 1)
            iterative_probe_candidate_count += _int(get(probe, "candidate_count", 0))
            iterative_probe_unavailable_count += _int(get(probe, "unavailable_finding_count", 0))
            iterative_probe_no_small_residual_count += _int(get(probe, "no_small_residual_count", 0))
        end
    end
    successful = get(status_counts, "ok", 0)
    findings = Any[]
    integrity_errors > 0 && push!(findings, Dict(
        "code" => "multiconductor_integrity_errors",
        "severity" => "error",
        "observation" => "One or more multiconductor smoke fixtures reported blocking integrity findings.",
        "evidence" => Dict("integrity_error_count" => integrity_errors),
        "suggested_action" => "Inspect the fixture preflight findings before interpreting port or nullspace evidence.",
    ))
    integrity_warnings > 0 && push!(findings, Dict(
        "code" => "multiconductor_integrity_warnings",
        "severity" => "warning",
        "observation" => "The source fixtures contain representational or import warnings.",
        "evidence" => Dict("integrity_warning_count" => integrity_warnings),
        "suggested_action" => "Review PowerIO/BMOPFTools import warnings before assigning physical meaning to a fixture result.",
    ))
    source_snapshot_cases < successful && push!(findings, Dict(
        "code" => "multiconductor_source_snapshot_missing",
        "severity" => "warning",
        "observation" => "Not every successful fixture has a preserved source snapshot for follow-up field mapping.",
        "evidence" => Dict("successful_case_count" => successful,
                           "source_snapshot_case_count" => source_snapshot_cases),
        "suggested_action" => "Rerun the smoke campaign with source preservation enabled before investigating schema losses.",
    ))
    source_schema_warnings > 0 && push!(findings, Dict(
        "code" => "multiconductor_source_schema_warnings",
        "severity" => "warning",
        "observation" => "The source loader dropped or could not represent some fixture fields.",
        "evidence" => Dict("source_schema_warning_count" => source_schema_warnings,
                           "field_counts" => source_warning_field_counts,
                           "scope_counts" => source_warning_scope_counts,
                           "impact_counts" => source_warning_impact_counts,
                           "policy_status_counts" => source_warning_policy_status_counts,
                           "field_policies" => source_schema_field_policies,
                           "message_counts" => source_warning_message_counts,
                           "fixture_counts" => source_warning_fixture_counts),
        "suggested_action" => "Inspect the retained source-schema warning details before treating fixture metadata as complete.",
    ))
    physical_metadata_warning_count > 0 && push!(findings, Dict(
        "code" => "multiconductor_physical_schema_loss",
        "severity" => "warning",
        "observation" => "One or more dropped source fields may change device semantics, topology, or operating-point interpretation.",
        "evidence" => Dict("physical_metadata_warning_count" => physical_metadata_warning_count,
                           "impact_counts" => source_warning_impact_counts,
                           "fixture_counts" => source_warning_fixture_counts),
        "suggested_action" => "Restore the affected source fields or prove that the BMOPF model does not depend on them before assigning physical meaning to numerical findings.",
    ))
    contract_available < successful && push!(findings, Dict(
        "code" => "multiconductor_contract_unavailable",
        "severity" => "warning",
        "observation" => "Not every successful fixture produced a multiconductor contract.",
        "evidence" => Dict("successful_case_count" => successful,
                           "contract_case_count" => contract_available),
        "suggested_action" => "Treat port, constitutive-map, and expected-mode coverage as incomplete.",
    ))
    mode_analysis_cases < successful && push!(findings, Dict(
        "code" => "multiconductor_expected_mode_analysis_unavailable",
        "severity" => "warning",
        "observation" => "Not every successful fixture produced an expected-versus-observed physical-mode analysis.",
        "evidence" => Dict("successful_case_count" => successful,
                           "mode_analysis_case_count" => mode_analysis_cases),
        "suggested_action" => "Run the BMOPF physical-mode analysis for every selected fixture before comparing nullspace semantics.",
    ))
    mode_projection_cases < successful && push!(findings, Dict(
        "code" => "multiconductor_mode_projection_unavailable",
        "severity" => "warning",
        "observation" => "Per-component physical-mode projection evidence is unavailable for one or more successful fixtures.",
        "evidence" => Dict("successful_case_count" => successful,
                           "mode_projection_case_count" => mode_projection_cases),
        "suggested_action" => "Retain the mode as unrepresented until its terminal-to-model projection is explicitly declared.",
    ))
    mode_analysis_cases > mode_rank_available_cases && push!(findings, Dict(
        "code" => "multiconductor_expected_mode_rank_unavailable",
        "severity" => "warning",
        "observation" => "Expected physical modes were declared, but local numerical rank/nullspace evidence was unavailable for some fixtures.",
        "evidence" => Dict("mode_analysis_case_count" => mode_analysis_cases,
                           "jacobian_rank_available_case_count" => mode_rank_available_cases,
                           "status_counts" => mode_status_counts),
        "suggested_action" => "Increase the explicit dense-analysis budget only for small fixtures, or retain the comparison as unavailable.",
    ))
    unaligned_mode_count > 0 && push!(findings, Dict(
        "code" => "multiconductor_expected_mode_coordinate_boundary",
        "severity" => "warning",
        "observation" => "One or more declared physical modes could not be aligned with the free model coordinates used by the local comparison.",
        "evidence" => Dict("unaligned_mode_count" => unaligned_mode_count,
                           "status_counts" => mode_status_counts),
        "suggested_action" => "Inspect the terminal-to-model coordinate maps before interpreting a mode as absent or unexpected.",
    ))
    iterative_probe_requested_cases > iterative_probe_available_cases && push!(findings, Dict(
        "code" => "multiconductor_iterative_probe_unavailable",
        "severity" => "warning",
        "observation" => "The requested sparse iterative right-nullspace probe was unavailable for one or more fixtures.",
        "evidence" => Dict("requested_case_count" => iterative_probe_requested_cases,
                           "available_case_count" => iterative_probe_available_cases,
                           "unavailable_finding_count" => iterative_probe_unavailable_count),
        "suggested_action" => "Inspect sparse Jacobian provenance and probe failure reasons before interpreting candidate directions.",
    ))
    iterative_probe_requested_cases > iterative_probe_converged_cases &&
        iterative_probe_requested_cases == iterative_probe_available_cases && push!(findings, Dict(
            "code" => "multiconductor_iterative_probe_not_converged",
            "severity" => "info",
            "observation" => "The sparse iterative right-nullspace probe was available but did not converge for every requested fixture.",
            "evidence" => Dict("requested_case_count" => iterative_probe_requested_cases,
                               "available_case_count" => iterative_probe_available_cases,
                               "converged_case_count" => iterative_probe_converged_cases),
            "suggested_action" => "Treat candidate residuals as incomplete numerical evidence and vary the iteration budget before interpreting a direction.",
        ))
    payload = Dict{String,Any}(
        "report_version" => "bmopf-multiconductor-smoke-summary-v1",
        "index_path" => index_path,
        "fixture_root" => get(index, "fixture_root", nothing),
        "environment_fingerprint" => get(index, "environment_fingerprint", nothing),
        "point_policy" => get(index, "point_policy", nothing),
        "rank_max_dense_entries" => get(index, "rank_max_dense_entries", nothing),
        "case_count" => length(cases),
        "status_counts" => status_counts,
        "cases" => cases,
        "aggregate" => Dict(
            "successful_case_count" => successful,
            "integrity_error_count" => integrity_errors,
            "integrity_warning_count" => integrity_warnings,
            "source_schema_warning_count" => source_schema_warnings,
            "source_snapshot_case_count" => source_snapshot_cases,
            "source_schema_warning_message_counts" => source_warning_message_counts,
            "source_schema_warning_field_counts" => source_warning_field_counts,
            "source_schema_warning_scope_counts" => source_warning_scope_counts,
            "source_schema_warning_impact_counts" => source_warning_impact_counts,
            "source_schema_warning_policy_status_counts" => source_warning_policy_status_counts,
            "source_schema_field_policies" => source_schema_field_policies,
            "source_schema_warning_fixture_counts" => source_warning_fixture_counts,
            "physical_metadata_warning_count" => physical_metadata_warning_count,
            "contract_case_count" => contract_available,
            "physical_mode_count" => physical_mode_count,
            "contract_finding_count" => contract_finding_count,
            "physical_mode_analysis_case_count" => mode_analysis_cases,
            "physical_mode_projection_case_count" => mode_projection_cases,
            "physical_mode_projection_visible_count" => mode_projection_visible_count,
            "physical_mode_projection_hidden_count" => mode_projection_hidden_count,
            "physical_mode_projection_unrepresented_count" => mode_projection_unrepresented_count,
            "physical_mode_match_case_count" => mode_match_cases,
            "physical_mode_match_observed_count" => mode_match_observed_count,
            "physical_mode_match_not_observed_count" => mode_match_not_observed_count,
            "physical_mode_match_outside_free_coordinate_count" => mode_match_outside_free_count,
            "physical_mode_match_partial_alignment_count" => mode_match_partial_count,
            "physical_mode_match_projected_observed_count" =>
                mode_match_projected_observed_count,
            "physical_mode_match_projected_not_observed_count" =>
                mode_match_projected_not_observed_count,
            "physical_mode_rank_available_case_count" => mode_rank_available_cases,
            "expected_physical_mode_count" => expected_mode_count,
            "observed_physical_mode_count" => observed_mode_count,
            "unaligned_physical_mode_count" => unaligned_mode_count,
            "not_observed_physical_mode_count" => not_observed_mode_count,
            "partial_alignment_physical_mode_count" => partial_alignment_mode_count,
            "iterative_probe_requested_case_count" => iterative_probe_requested_cases,
            "iterative_probe_available_case_count" => iterative_probe_available_cases,
            "iterative_probe_converged_case_count" => iterative_probe_converged_cases,
            "iterative_probe_candidate_count" => iterative_probe_candidate_count,
            "iterative_probe_unavailable_finding_count" => iterative_probe_unavailable_count,
            "iterative_probe_no_small_residual_finding_count" => iterative_probe_no_small_residual_count,
            "physical_mode_comparison_status_counts" => mode_status_counts,
        ),
        "readiness" => Dict(
            "all_cases_successful" => !isempty(cases) && successful == length(cases),
            "dense_budget_explicit" => all(haskey(case, "rank_max_dense_entries") for case in cases),
            "port_contract_available" => successful > 0 && contract_available == successful,
            "integrity_preflight_clear" => integrity_errors == 0,
            "source_fixtures_preserved" => successful > 0 && source_snapshot_cases == successful,
            "physical_metadata_complete" => physical_metadata_warning_count == 0,
            "physical_mode_observations_available" => physical_mode_count > 0,
            "physical_mode_analysis_available" => successful > 0 && mode_analysis_cases == successful,
            "mode_projection_observations_available" => successful > 0 &&
                mode_projection_cases == successful,
            "mode_jacobian_match_observations_available" => successful > 0 &&
                mode_match_cases == successful,
            "mode_free_coordinate_projection_policy" => get(index,
                "expected_mode_free_coordinate_policy", "unknown"),
            "dense_physical_mode_rank_complete" => successful > 0 &&
                mode_analysis_cases == successful && mode_rank_available_cases == successful,
            "expected_observed_mode_comparison" => successful > 0 &&
                mode_analysis_cases == successful && mode_rank_available_cases == successful &&
                unaligned_mode_count == 0,
            "iterative_right_nullspace_probe" => iterative_probe_requested_cases == 0 ||
                iterative_probe_requested_cases == iterative_probe_available_cases,
        ),
        "findings" => findings,
        "interpretation" => "Multiconductor contract aggregation only; port maps and physical modes are evidence records, not solver-independent physical certificates.",
    )
    write(output_path, JSON.json(payload))
    println("wrote BMOPF multiconductor smoke summary to $output_path")
end

main()
