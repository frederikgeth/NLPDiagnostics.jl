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

function _float(value)
    value isa Number && isfinite(Float64(value)) && return Float64(value)
    try
        parsed = parse(Float64, String(value))
        return isfinite(parsed) ? parsed : nothing
    catch
        return nothing
    end
end

_bool(value) = value === true ||
    (value isa AbstractString && lowercase(strip(String(value))) in
        ("true", "1", "yes"))

function _finding_detail_values(report, code::AbstractString,
                                field::AbstractString)
    values = Float64[]
    for raw_finding in get(report, "findings", Any[])
        finding = _as_dict(raw_finding)
        String(get(finding, "code", "")) == code || continue
        evidence = get(finding, "evidence", Any[])
        evidence isa AbstractVector || continue
        for raw_item in evidence
            item = _as_dict(raw_item)
            details = _as_dict(get(item, "details", nothing))
            value = _float(get(details, field, nothing))
            isnothing(value) || push!(values, value)
        end
    end
    return values
end

function _integer_list(value)
    value isa AbstractVector && return Int[_int(item) for item in value]
    value isa AbstractString || return Int[]
    return Int[_int(token) for token in split(value, ',')
        if !isempty(strip(token))]
end

function _finding_detail_integer_values(report, code::AbstractString,
                                        field::AbstractString)
    values = Int[]
    for raw_finding in get(report, "findings", Any[])
        finding = _as_dict(raw_finding)
        String(get(finding, "code", "")) == code || continue
        evidence = get(finding, "evidence", Any[])
        evidence isa AbstractVector || continue
        for raw_item in evidence
            details = _as_dict(get(_as_dict(raw_item), "details", nothing))
            append!(values, _integer_list(get(details, field, "")))
        end
    end
    return sort!(unique(values))
end

function _count_csv!(counts::Dict{String,Int}, value)
    value isa AbstractString || return counts
    for token in split(value, ',')
        key = strip(String(token))
        isempty(key) && continue
        counts[key] = get(counts, key, 0) + 1
    end
    return counts
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
    field in ("angle", "basekv", "kv", "phases", "vmaxpu", "vminpu", "zipv") &&
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
    field in ("angle", "basekv", "kv", "phases", "vmaxpu", "vminpu", "zipv") && return Dict{String,Any}(
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
    tangent_rows = Dict{String,Any}[]
    for raw_finding in get(mode_analysis, "findings", Any[])
        finding = _as_dict(raw_finding)
        code = String(get(finding, "code", ""))
        code in ("expected_nullspace_mode_tangent_observed",
                 "expected_nullspace_mode_tangent_not_observed") || continue
        evidence = get(finding, "evidence", Any[])
        evidence isa AbstractVector && !isempty(evidence) || continue
        details = _as_dict(get(_as_dict(first(evidence)), "details", nothing))
        push!(tangent_rows, Dict{String,Any}(
            "code" => code,
            "mode" => get(details, "mode", nothing),
            "tangent_policy" => get(details, "tangent_policy", nothing),
            "projection_residual" => get(details, "projection_residual", nothing),
            "tolerance" => get(details, "tolerance", nothing),
            "description" => get(details, "description", nothing),
        ))
    end
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
    projected_observed_modes =
        mode_int("expected_nullspace_mode_free_projection_observed")
    projected_not_observed_modes =
        mode_int("expected_nullspace_mode_free_projection_not_observed")
    tangent_observed_modes = mode_int("expected_nullspace_mode_tangent_observed")
    tangent_not_observed_modes = mode_int("expected_nullspace_mode_tangent_not_observed")
    mode_status = if isempty(mode_analysis)
        "unavailable"
    elseif !mode_rank_available
        "rank_unavailable"
    elseif unaligned_modes > 0
        "coordinate_alignment_boundary"
    elseif projected_observed_modes > 0 || projected_not_observed_modes > 0
        "free_coordinate_projection"
    elseif tangent_observed_modes > 0 || tangent_not_observed_modes > 0
        "plugin_tangent_scope"
    elseif observed_modes > 0
        "observed"
    elseif not_observed_modes > 0
        "not_observed"
    else
        "no_comparison_finding"
    end
    profile = _as_dict(get(record, "profile", nothing))
    context_report = _as_dict(get(profile, "bmopf_context_report", nothing))
    context_metadata = _as_dict(get(context_report, "metadata", nothing))
    source_schema_coverage = Dict{String,Any}(
        "report_available" => !isempty(context_metadata),
        "provenance_available" => lowercase(string(get(context_metadata,
            "bmopf_source_schema_provenance_available", "false"))) == "true",
        "provenance_fields" => get(context_metadata,
            "bmopf_source_schema_provenance_fields", ""),
        "provenance_warning_fields" => get(context_metadata,
            "bmopf_source_schema_provenance_warning_fields", ""),
        "provenance_field_count" => _int(get(context_metadata,
            "bmopf_source_schema_provenance_field_count", 0)),
        "provenance_warning_field_count" => _int(get(context_metadata,
            "bmopf_source_schema_provenance_warning_field_count", 0)),
        "mapped_fields" => get(context_metadata,
            "bmopf_source_schema_mapped_fields", ""),
        "mapped_field_count" => _int(get(context_metadata,
            "bmopf_source_schema_mapped_field_count", 0)),
        "mapped_warning_field_count" => _int(get(context_metadata,
            "bmopf_source_schema_mapped_warning_field_count", 0)),
        "mapping_field_statuses" => get(context_metadata,
            "bmopf_source_schema_mapping_field_statuses", ""),
        "unmapped_blocking_fields" => get(context_metadata,
            "bmopf_source_schema_unmapped_blocking_fields", ""),
        "restoration_ready" => lowercase(string(get(context_metadata,
            "bmopf_source_schema_restoration_ready", "false"))) == "true",
        "threshold_observation_count" => _int(get(context_metadata,
            "bmopf_source_schema_threshold_observation_count", 0)),
        "threshold_observation_statuses" => get(context_metadata,
            "bmopf_source_schema_threshold_observation_statuses", ""),
        "source_model_observation_count" => _int(get(context_metadata,
            "bmopf_source_schema_source_model_observation_count", 0)),
        "source_model_contract_statuses" => get(context_metadata,
            "bmopf_source_schema_source_model_contract_statuses", ""),
        "behavior_contract_available" => lowercase(string(get(context_metadata,
            "bmopf_source_schema_behavior_contract_available", "false"))) == "true",
        "behavior_contract_version" => get(context_metadata,
            "bmopf_source_schema_behavior_contract_version", ""),
        "behavior_constraint_policy" => get(context_metadata,
            "bmopf_source_schema_behavior_constraint_policy", ""),
        "behavior_candidate_count" => _int(get(context_metadata,
            "bmopf_source_schema_behavior_candidate_count", 0)),
        "behavior_eligible_candidate_count" => _int(get(context_metadata,
            "bmopf_source_schema_behavior_eligible_candidate_count", 0)),
    )
    auxiliary = _as_dict(get(record, "source_behavior_auxiliary", nothing))
    auxiliary_solve = _as_dict(get(record, "source_behavior_auxiliary_solve", nothing))
    behavior_report = _as_dict(get(record, "source_behavior_report", nothing))
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
    crosscheck_dimension = _int(get(entry,
        "smallest_singular_backend_crosscheck_dimension",
        get(record, "smallest_singular_backend_crosscheck_dimension", 0)))
    crosscheck_restarted_iterations = _int(get(entry,
        "smallest_singular_backend_crosscheck_restarted_iterations",
        get(record, "smallest_singular_backend_crosscheck_restarted_iterations", 0)))
    crosscheck_restarted_alignment_threshold = _float(get(entry,
        "smallest_singular_backend_crosscheck_restarted_alignment_threshold",
        get(record,
            "smallest_singular_backend_crosscheck_restarted_alignment_threshold",
            nothing)))
    crosscheck_harmonic_steps = _int(get(entry,
        "smallest_singular_backend_crosscheck_harmonic_steps_per_seed",
        get(record, "smallest_singular_backend_crosscheck_harmonic_steps_per_seed", 0)))
    crosscheck_harmonic_cycles = _int(get(entry,
        "smallest_singular_backend_crosscheck_harmonic_cycles",
        get(record, "smallest_singular_backend_crosscheck_harmonic_cycles", 0)))
    crosscheck_harmonic_alignment_threshold = _float(get(entry,
        "smallest_singular_backend_crosscheck_harmonic_alignment_threshold",
        get(record,
            "smallest_singular_backend_crosscheck_harmonic_alignment_threshold",
            nothing)))
    crosscheck_max_basis_entries = _int(get(entry,
        "smallest_singular_backend_crosscheck_max_basis_entries",
        get(record, "smallest_singular_backend_crosscheck_max_basis_entries", 0)))
    crosscheck_scaling = string(get(entry,
        "smallest_singular_backend_crosscheck_scaling",
        get(record, "smallest_singular_backend_crosscheck_scaling", "none")))
    crosscheck_available = lowercase(string(get(numerical_metadata,
        "smallest_singular_backend_crosscheck_available", "false"))) == "true"
    crosscheck_restarted_converged = lowercase(string(get(numerical_metadata,
        "smallest_singular_backend_crosscheck_restarted_converged", "false"))) == "true"
    crosscheck_harmonic_converged = lowercase(string(get(numerical_metadata,
        "smallest_singular_backend_crosscheck_harmonic_converged", "false"))) == "true"
    crosscheck_relation = crosscheck_dimension > 0 ? string(get(numerical_metadata,
        "smallest_singular_backend_crosscheck_relation", "unavailable")) : "not_requested"
    numerical_code_counts = _as_dict(get(numerical, "finding_code_counts", nothing))
    active_set = _as_dict(get(reports, "active_set", nothing))
    active_set_metadata = _as_dict(get(active_set, "metadata", nothing))
    active_set_code_counts = _as_dict(get(active_set, "finding_code_counts", nothing))
    feasibility_violations = _finding_detail_values(
        active_set, "constraint_feasibility_violation", "feasibility_violation")
    zero_jacobian_rows = _finding_detail_integer_values(
        numerical, "zero_jacobian_rows", "rows")
    selected_active_rows = Set(_integer_list(get(
        active_set_metadata, "active_rows", "")))
    active_zero_jacobian_rows = sort!(Int[row for row in zero_jacobian_rows
        if row in selected_active_rows])
    inactive_zero_jacobian_rows = sort!(Int[row for row in zero_jacobian_rows
        if !(row in selected_active_rows)])
    dense_calibration_requested = _bool(get(entry,
        "smallest_singular_backend_crosscheck_dense_calibration",
        get(record, "smallest_singular_backend_crosscheck_dense_calibration", false)))
    restarted_dense_available = _bool(get(numerical_metadata,
        "restarted_dense_calibration_available", false))
    harmonic_dense_available = _bool(get(numerical_metadata,
        "harmonic_dense_calibration_available", false))
    sparse_qr_nullspace_requested = _bool(get(entry,
        "sparse_qr_nullspace", get(record, "sparse_qr_nullspace", false)))
    sparse_qr_nullspace_dense_requested = _bool(get(entry,
        "sparse_qr_nullspace_dense_calibration",
        get(record, "sparse_qr_nullspace_dense_calibration", false)))
    sparse_qr_persistence_requested = _bool(get(entry,
        "sparse_qr_nullspace_persistence_requested",
        get(record, "sparse_qr_nullspace_persistence_requested", false)))
    sparse_qr_persistence_report = _as_dict(get(record,
        "sparse_qr_nullspace_persistence_report", nothing))
    sparse_qr_persistence_metadata = _as_dict(get(
        sparse_qr_persistence_report, "metadata", nothing))
    sparse_qr_persistence_findings = get(
        sparse_qr_persistence_report, "findings", Any[])
    sparse_qr_persistence_findings isa AbstractVector ||
        (sparse_qr_persistence_findings = Any[])
    return Dict{String,Any}(
        "name" => get(entry, "name", "unknown"),
        "fixture" => get(record, "fixture", nothing),
        "point_policy" => get(record, "point_policy",
            get(entry, "point_policy", nothing)),
        "point_solve" => _as_dict(get(record, "point_solve",
            get(entry, "point_solve", nothing))),
        "status" => get(entry, "status", get(record, "status", "unknown")),
        "result_file" => result_file,
        "source_behavior_solver" => get(record, "source_behavior_solver",
            get(entry, "source_behavior_solver", "none")),
        "source_behavior_solver_attributes" => get(record,
            "source_behavior_solver_attributes",
            get(entry, "source_behavior_solver_attributes", Dict{String,Any}())),
        "source_snapshot" => source_snapshot,
        "model_variable_count" => get(record, "model_variable_count", nothing),
        "scalar_constraint_row_count" => get(record, "scalar_constraint_row_count", nothing),
        "jacobian_dense_entry_count" => get(record, "jacobian_dense_entry_count", nothing),
        "rank_max_dense_entries" => get(record, "rank_max_dense_entries", nothing),
        "expected_mode_free_coordinate_policy" => get(record,
            "expected_mode_free_coordinate_policy",
            get(entry, "expected_mode_free_coordinate_policy", "unknown")),
        "expected_mode_tangent_policy" => get(record,
            "expected_mode_tangent_policy",
            get(entry, "expected_mode_tangent_policy", "unknown")),
        "expected_mode_tangent_policy_variable_count" => get(mode_metadata,
            "expected_mode_tangent_policy_variable_count", "0"),
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
        "source_schema_coverage" => source_schema_coverage,
        "source_behavior_auxiliary" => Dict(
            "status" => get(auxiliary, "status", "unavailable"),
            "variable_count" => _int(get(auxiliary, "variable_count", 0)),
            "constraint_pair_count" => _int(get(auxiliary, "constraint_pair_count", 0)),
            "original_model_variable_count" => _int(get(auxiliary,
                "original_model_variable_count", 0)),
            "original_model_mutated" => get(auxiliary, "original_model_mutated", true),
            "materialized_record_count" => count(item ->
                get(_as_dict(item), "status", "") == "materialized",
                get(auxiliary, "records", Any[])),
        ),
        "source_behavior_report" => Dict(
            "status" => get(behavior_report, "status", "unavailable"),
            "finding_count" => _int(get(behavior_report, "finding_count", 0)),
            "finding_codes" => get(behavior_report, "finding_codes", Any[]),
            "row_count" => length(get(behavior_report, "rows", Any[])),
            "auxiliary_solve_status" => get(behavior_report,
                "auxiliary_solve_status", "unknown"),
        ),
        "source_behavior_auxiliary_solve" => Dict(
            "status" => get(auxiliary_solve, "status", "not_requested"),
            "solver" => get(auxiliary_solve, "solver", "none"),
            "termination_status" => get(auxiliary_solve,
                "termination_status", "unknown"),
            "feasible" => get(auxiliary_solve, "feasible", false),
            "result_count" => _int(get(auxiliary_solve, "result_count", 0)),
            "objective_value" => get(auxiliary_solve, "objective_value", nothing),
            "error" => get(auxiliary_solve, "error", nothing),
            "original_model_variable_count_before" => get(auxiliary_solve,
                "original_model_variable_count_before", nothing),
            "original_model_variable_count_after" => get(auxiliary_solve,
                "original_model_variable_count_after", nothing),
            "original_model_mutated" => get(auxiliary_solve,
                "original_model_mutated", false),
        ),
        "multiconductor_contract" => contract,
        "physical_mode_comparison" => Dict(
            "status" => mode_status,
            "expected_mode_count" => expected_modes,
            "observed_mode_count" => observed_modes,
            "unaligned_mode_count" => unaligned_modes,
            "not_observed_mode_count" => not_observed_modes,
            "partial_alignment_mode_count" => partial_modes,
            "projected_observed_mode_count" => projected_observed_modes,
            "projected_not_observed_mode_count" => projected_not_observed_modes,
            "tangent_observed_mode_count" => tangent_observed_modes,
            "tangent_not_observed_mode_count" => tangent_not_observed_modes,
            "tangent_rows" => tangent_rows,
            "jacobian_rank_available" => mode_rank_available,
            "jacobian_rank" => mode_jacobian_rank,
            "sparse_qr_rank" => _int(get(numerical_metadata, "sparse_qr_rank", 0)),
            "dense_guard_allows" => dense_guard_allows,
            "finding_code_counts" => mode_codes,
        ),
        "numerical_profile" => Dict(
            "available" => !isempty(numerical_metadata),
            "sparse_qr_condition_proxy" => _float(get(numerical_metadata,
                "sparse_qr_condition_proxy", nothing)),
            "sparse_qr_matrix_norm" => _float(get(numerical_metadata,
                "sparse_qr_matrix_norm", nothing)),
            "sparse_qr_factorization_relative_residual" => _float(get(
                numerical_metadata, "sparse_qr_factorization_relative_residual",
                nothing)),
            "raw_jacobian_entry_count" => _int(get(numerical_metadata,
                "raw_jacobian_entry_count", 0)),
            "evaluation_failure_count" => _int(get(numerical_metadata,
                "evaluation_failure_count", 0)),
            "derivative_issue_count" => _int(get(numerical_metadata,
                "derivative_issue_count", 0)),
            "expression_numerical_risk_count" => _int(get(numerical_metadata,
                "expression_numerical_risk_count", 0)),
            "zero_jacobian_row_finding_count" => _int(get(
                numerical_code_counts, "zero_jacobian_rows", 0)),
            "zero_jacobian_row_count" => length(zero_jacobian_rows),
            "zero_jacobian_rows" => zero_jacobian_rows,
            "active_zero_jacobian_row_count" =>
                length(active_zero_jacobian_rows),
            "active_zero_jacobian_rows" => active_zero_jacobian_rows,
            "inactive_zero_jacobian_row_count" =>
                length(inactive_zero_jacobian_rows),
            "inactive_zero_jacobian_rows" => inactive_zero_jacobian_rows,
            "inactive_stationary_diagonal_quadratic_row_count" => _int(get(
                numerical_code_counts,
                "inactive_stationary_diagonal_quadratic_row", 0)),
            "active_stationary_diagonal_quadratic_row_count" => _int(get(
                numerical_code_counts,
                "active_stationary_diagonal_quadratic_row", 0)),
            "violated_stationary_diagonal_quadratic_row_count" => _int(get(
                numerical_code_counts,
                "violated_stationary_diagonal_quadratic_row", 0)),
            "finding_code_counts" => numerical_code_counts,
        ),
        "initialization_profile" => Dict(
            "available" => !isempty(active_set),
            "point_label" => get(numerical_metadata,
                "evaluation_point_label", nothing),
            "point_provenance_kind" => get(numerical_metadata,
                "evaluation_point_provenance_kind", nothing),
            "point_provenance_source" => get(numerical_metadata,
                "evaluation_point_provenance_source", nothing),
            "feasibility_violation_count" => length(feasibility_violations),
            "maximum_feasibility_violation" => isempty(feasibility_violations) ?
                0.0 : maximum(feasibility_violations),
            "finding_code_counts" => active_set_code_counts,
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
        "smallest_singular_backend_crosscheck" => Dict(
            "requested_dimension" => crosscheck_dimension,
            "restarted_iterations" => crosscheck_restarted_iterations,
            "restarted_alignment_threshold" =>
                crosscheck_restarted_alignment_threshold,
            "harmonic_steps_per_seed" => crosscheck_harmonic_steps,
            "harmonic_cycles" => crosscheck_harmonic_cycles,
            "harmonic_alignment_threshold" =>
                crosscheck_harmonic_alignment_threshold,
            "max_basis_entries" => crosscheck_max_basis_entries,
            "scaling" => crosscheck_scaling,
            "coordinate_system" => string(get(numerical_metadata,
                "smallest_singular_backend_crosscheck_coordinate_system",
                crosscheck_scaling in ("column", "row_column") ?
                    "diagonally_transformed_variables" : "original_variables")),
            "row_scaling_minimum" => _float(get(numerical_metadata,
                "smallest_singular_backend_crosscheck_row_scaling_minimum", nothing)),
            "row_scaling_maximum" => _float(get(numerical_metadata,
                "smallest_singular_backend_crosscheck_row_scaling_maximum", nothing)),
            "column_scaling_minimum" => _float(get(numerical_metadata,
                "smallest_singular_backend_crosscheck_column_scaling_minimum", nothing)),
            "column_scaling_maximum" => _float(get(numerical_metadata,
                "smallest_singular_backend_crosscheck_column_scaling_maximum", nothing)),
            "model_modified" => _bool(get(numerical_metadata,
                "smallest_singular_backend_crosscheck_model_modified", false)),
            "available" => crosscheck_dimension > 0 && crosscheck_available,
            "relation" => crosscheck_relation,
            "restarted_converged" => crosscheck_dimension > 0 &&
                crosscheck_restarted_converged,
            "harmonic_converged" => crosscheck_dimension > 0 &&
                crosscheck_harmonic_converged,
            "restarted_breakdown" => string(get(numerical_metadata,
                "smallest_singular_backend_crosscheck_restarted_breakdown",
                "unavailable")),
            "harmonic_breakdown" => string(get(numerical_metadata,
                "smallest_singular_backend_crosscheck_harmonic_breakdown",
                "unavailable")),
            "restarted_completed_iterations" => _int(get(numerical_metadata,
                "smallest_singular_backend_crosscheck_restarted_completed_iterations", 0)),
            "harmonic_completed_cycles" => _int(get(numerical_metadata,
                "smallest_singular_backend_crosscheck_harmonic_completed_cycles", 0)),
            "restarted_values" => _float_list(get(numerical_metadata,
                "smallest_singular_backend_crosscheck_restarted_values", "")),
            "harmonic_values" => _float_list(get(numerical_metadata,
                "smallest_singular_backend_crosscheck_harmonic_values", "")),
            "restarted_backward_errors" => _float_list(get(numerical_metadata,
                "smallest_singular_backend_crosscheck_restarted_backward_errors", "")),
            "harmonic_backward_errors" => _float_list(get(numerical_metadata,
                "smallest_singular_backend_crosscheck_harmonic_backward_errors", "")),
            "original_coordinate_audit_available" => _bool(get(numerical_metadata,
                "smallest_singular_backend_crosscheck_original_audit_available", false)),
            "restarted_original_relative_residuals" => _float_list(get(
                numerical_metadata,
                "smallest_singular_backend_crosscheck_restarted_original_relative_residuals",
                "")),
            "harmonic_original_relative_residuals" => _float_list(get(
                numerical_metadata,
                "smallest_singular_backend_crosscheck_harmonic_original_relative_residuals",
                "")),
            "restarted_mapped_direction_norms" => _float_list(get(
                numerical_metadata,
                "smallest_singular_backend_crosscheck_restarted_mapped_direction_norms",
                "")),
            "harmonic_mapped_direction_norms" => _float_list(get(
                numerical_metadata,
                "smallest_singular_backend_crosscheck_harmonic_mapped_direction_norms",
                "")),
            "relative_value_differences" => _float_list(get(numerical_metadata,
                "smallest_singular_backend_crosscheck_relative_value_differences", "")),
            "minimum_principal_cosine" => _float(get(numerical_metadata,
                "smallest_singular_backend_crosscheck_minimum_principal_cosine", nothing)),
            "structural_minimum_right_nullity" => _int(get(numerical_metadata,
                "smallest_singular_backend_crosscheck_structural_minimum_right_nullity", 0)),
            "dimension_covers_structural_minimum" => _bool(get(numerical_metadata,
                "smallest_singular_backend_crosscheck_dimension_covers_structural_minimum",
                true)),
            "agreement_finding_count" => _int(get(numerical_code_counts,
                "smallest_singular_backend_crosscheck_agreement", 0)),
            "inconclusive_finding_count" => _int(get(numerical_code_counts,
                "smallest_singular_backend_crosscheck_inconclusive", 0)),
            "disagreement_finding_count" => _int(get(numerical_code_counts,
                "smallest_singular_backend_crosscheck_disagreement", 0)),
            "unavailable_finding_count" => _int(get(numerical_code_counts,
                "smallest_singular_backend_crosscheck_unavailable", 0)),
            "dense_calibration" => Dict(
                "requested" => dense_calibration_requested,
                "restarted_available" => dense_calibration_requested &&
                    restarted_dense_available,
                "restarted_relation" => dense_calibration_requested ?
                    string(get(numerical_metadata,
                        "restarted_dense_calibration_relation", "unavailable")) :
                    "not_requested",
                "restarted_dense_values" => _float_list(get(numerical_metadata,
                    "restarted_dense_singular_values", "")),
                "restarted_relative_value_errors" => _float_list(get(
                    numerical_metadata,
                    "restarted_dense_relative_singular_value_errors", "")),
                "restarted_minimum_principal_cosine" => _float(get(
                    numerical_metadata,
                    "restarted_dense_minimum_principal_cosine", nothing)),
                "harmonic_available" => dense_calibration_requested &&
                    harmonic_dense_available,
                "harmonic_relation" => dense_calibration_requested ?
                    string(get(numerical_metadata,
                        "harmonic_dense_calibration_relation", "unavailable")) :
                    "not_requested",
                "harmonic_dense_values" => _float_list(get(numerical_metadata,
                    "harmonic_dense_singular_values", "")),
                "harmonic_relative_value_errors" => _float_list(get(
                    numerical_metadata,
                    "harmonic_dense_relative_singular_value_errors", "")),
                "harmonic_minimum_principal_cosine" => _float(get(
                    numerical_metadata,
                    "harmonic_dense_minimum_principal_cosine", nothing)),
            ),
        ),
        "sparse_qr_nullspace" => Dict(
            "requested" => sparse_qr_nullspace_requested,
            "scaling" => string(get(entry, "sparse_qr_nullspace_scaling",
                get(record, "sparse_qr_nullspace_scaling", "none"))),
            "available" => sparse_qr_nullspace_requested && _bool(get(
                numerical_metadata, "sparse_qr_nullspace_available", false)),
            "rank" => _int(get(numerical_metadata,
                "sparse_qr_nullspace_rank", 0)),
            "right_nullity" => _int(get(numerical_metadata,
                "sparse_qr_right_nullity", 0)),
            "absolute_threshold" => _float(get(numerical_metadata,
                "sparse_qr_nullspace_absolute_threshold", nothing)),
            "relative_residuals" => _float_list(get(numerical_metadata,
                "sparse_qr_nullspace_relative_residuals", "")),
            "orthogonality_loss" => _float(get(numerical_metadata,
                "sparse_qr_nullspace_orthogonality_loss", nothing)),
            "input_nonzeros" => _int(get(numerical_metadata,
                "sparse_qr_nullspace_input_nonzeros", 0)),
            "factor_nonzeros" => _int(get(numerical_metadata,
                "sparse_qr_nullspace_factor_nonzeros", 0)),
            "fill_ratio" => _float(get(numerical_metadata,
                "sparse_qr_nullspace_fill_ratio", nothing)),
            "dense_calibration_requested" =>
                sparse_qr_nullspace_dense_requested,
            "dense_calibration_available" =>
                sparse_qr_nullspace_dense_requested && _bool(get(
                    numerical_metadata,
                    "sparse_qr_nullspace_dense_calibration_available", false)),
            "dense_calibration_relation" =>
                sparse_qr_nullspace_dense_requested ? string(get(
                    numerical_metadata,
                    "sparse_qr_nullspace_dense_calibration_relation",
                    "unavailable")) : "not_requested",
            "dense_rank" => _int(get(numerical_metadata,
                "sparse_qr_nullspace_dense_rank", 0)),
            "dense_right_nullity" => _int(get(numerical_metadata,
                "sparse_qr_nullspace_dense_right_nullity", 0)),
            "dense_minimum_principal_cosine" => _float(get(
                numerical_metadata,
                "sparse_qr_nullspace_dense_minimum_principal_cosine", nothing)),
            "dense_threshold_ambiguous" => _bool(get(numerical_metadata,
                "sparse_qr_nullspace_dense_threshold_ambiguous", false)),
        ),
        "sparse_qr_nullspace_persistence" => Dict(
            "requested" => sparse_qr_persistence_requested,
            "available" => sparse_qr_persistence_requested && _bool(get(
                sparse_qr_persistence_metadata,
                "sparse_qr_nullspace_persistence_available", false)),
            "repeat_count" => _int(get(entry,
                "sparse_qr_nullspace_persistence_repeat_count",
                get(record, "sparse_qr_nullspace_persistence_repeat_count", 0))),
            "radii" => get(entry, "sparse_qr_nullspace_persistence_radii",
                get(record, "sparse_qr_nullspace_persistence_radii", Any[])),
            "direction_seed" => _int(get(entry,
                "sparse_qr_nullspace_persistence_direction_seed",
                get(record, "sparse_qr_nullspace_persistence_direction_seed", 0))),
            "alignment_threshold" => _float(get(
                sparse_qr_persistence_metadata,
                "sparse_qr_nullspace_persistence_alignment_threshold",
                get(entry,
                    "sparse_qr_nullspace_persistence_alignment_threshold",
                    nothing))),
            "evaluation_count" => _int(get(sparse_qr_persistence_metadata,
                "evaluation_count", 0)),
            "ranks" => [_int(value) for value in split(String(get(
                sparse_qr_persistence_metadata,
                "sparse_qr_nullspace_persistence_ranks", "")), ',')
                if !isempty(strip(value))],
            "right_nullities" => [_int(value) for value in split(String(get(
                sparse_qr_persistence_metadata,
                "sparse_qr_nullspace_persistence_right_nullities", "")), ',')
                if !isempty(strip(value))],
            "pair_relative_point_distances" => _float_list(get(
                sparse_qr_persistence_metadata,
                "sparse_qr_nullspace_persistence_pair_relative_point_distances",
                "")),
            "pair_minimum_principal_cosines" => _float_list(get(
                sparse_qr_persistence_metadata,
                "sparse_qr_nullspace_persistence_pair_minimum_principal_cosines",
                "")),
            "minimum_repeat_principal_cosine" => _float(get(
                sparse_qr_persistence_metadata,
                "sparse_qr_nullspace_persistence_minimum_repeat_principal_cosine",
                nothing)),
            "minimum_nearby_principal_cosine" => _float(get(
                sparse_qr_persistence_metadata,
                "sparse_qr_nullspace_persistence_minimum_nearby_principal_cosine",
                nothing)),
            "maximum_relative_residual" => _float(get(
                sparse_qr_persistence_metadata,
                "sparse_qr_nullspace_persistence_maximum_relative_residual",
                nothing)),
            "rank_stable" => _bool(get(sparse_qr_persistence_metadata,
                "sparse_qr_nullspace_persistence_rank_stable", false)),
            "subspace_persistent" => _bool(get(
                sparse_qr_persistence_metadata,
                "sparse_qr_nullspace_persistence_subspace_persistent", false)),
            "residual_supported" => _bool(get(sparse_qr_persistence_metadata,
                "sparse_qr_nullspace_persistence_residual_supported", false)),
            "finding_codes" => [String(get(finding, "code", "unknown"))
                for finding in sparse_qr_persistence_findings
                if finding isa AbstractDict],
            "material_variable_indices" => [_int(value) for value in split(
                String(get(sparse_qr_persistence_metadata,
                    "sparse_qr_persistent_material_variable_indices", "")), ',')
                if !isempty(strip(value))],
            "coordinate_group_energy_fractions" => String(get(
                sparse_qr_persistence_metadata,
                "sparse_qr_persistent_coordinate_group_energy_fractions", "")),
            "unmapped_coordinate_energy_fraction" => _float(get(
                sparse_qr_persistence_metadata,
                "sparse_qr_persistent_unmapped_coordinate_energy_fraction",
                nothing)),
            "expected_mode_count" => _int(get(sparse_qr_persistence_metadata,
                "sparse_qr_persistent_expected_mode_count", 0)),
            "aligned_expected_mode_count" => _int(get(
                sparse_qr_persistence_metadata,
                "sparse_qr_persistent_aligned_expected_mode_count", 0)),
            "expected_mode_span_rank" => _int(get(
                sparse_qr_persistence_metadata,
                "sparse_qr_persistent_expected_mode_span_rank", 0)),
            "expected_mode_maximum_residual" => _float(get(
                sparse_qr_persistence_metadata,
                "sparse_qr_persistent_expected_mode_maximum_residual", nothing)),
            "maximum_unexplained_energy" => _float(get(
                sparse_qr_persistence_metadata,
                "sparse_qr_persistent_expected_mode_maximum_unexplained_energy",
                nothing)),
            "expected_modes_numerically_supported" => _bool(get(
                sparse_qr_persistence_metadata,
                "sparse_qr_persistent_expected_modes_numerically_supported",
                false)),
            "expected_mode_span_explains_nullspace" => _bool(get(
                sparse_qr_persistence_metadata,
                "sparse_qr_persistent_expected_mode_span_explains_nullspace",
                false)),
            "physical_interpretation_ready" => _bool(get(
                sparse_qr_persistence_metadata,
                "sparse_qr_persistent_physical_interpretation_ready", false)),
            "physical_readiness_reason" => String(get(
                sparse_qr_persistence_metadata,
                "sparse_qr_persistent_physical_readiness_reason", "unknown")),
            "port_expected_mode_count" => _int(get(
                sparse_qr_persistence_metadata,
                "bmopf_sparse_qr_persistent_port_expected_mode_count", 0)),
            "source_schema_ready" => _bool(get(sparse_qr_persistence_metadata,
                "bmopf_sparse_qr_persistent_source_schema_ready", false)),
            "source_schema_blocking_fields" => String(get(
                sparse_qr_persistence_metadata,
                "bmopf_sparse_qr_persistent_source_schema_blocking_fields", "")),
            "disconnected_variable_count" => _int(get(
                sparse_qr_persistence_metadata,
                "bmopf_sparse_qr_persistent_disconnected_variable_count", 0)),
            "disconnected_energy_fraction" => _float(get(
                sparse_qr_persistence_metadata,
                "bmopf_sparse_qr_persistent_disconnected_energy_fraction", nothing)),
            "support_is_disconnected" => _bool(get(
                sparse_qr_persistence_metadata,
                "bmopf_sparse_qr_persistent_support_is_disconnected", false)),
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
    source_schema_context_report_cases = 0
    source_schema_provenance_cases = 0
    source_schema_provenance_field_counts = Dict{String,Int}()
    source_schema_provenance_warning_field_counts = Dict{String,Int}()
    source_schema_mapped_field_counts = Dict{String,Int}()
    source_schema_unmapped_blocking_field_counts = Dict{String,Int}()
    source_schema_mapping_ready_cases = 0
    source_schema_threshold_observation_cases = 0
    source_schema_threshold_observation_count = 0
    source_schema_threshold_status_counts = Dict{String,Int}()
    source_schema_source_model_contract_cases = 0
    source_schema_source_model_observation_count = 0
    source_schema_source_model_status_counts = Dict{String,Int}()
    source_schema_behavior_contract_cases = 0
    source_schema_behavior_candidate_count = 0
    source_schema_behavior_eligible_candidate_count = 0
    source_behavior_auxiliary_cases = 0
    source_behavior_auxiliary_materialized_pairs = 0
    source_behavior_auxiliary_mutation_cases = 0
    source_behavior_auxiliary_solve_status_counts = Dict{String,Int}()
    source_behavior_auxiliary_solve_solver_counts = Dict{String,Int}()
    source_behavior_auxiliary_solve_requested_cases = 0
    source_behavior_auxiliary_solve_feasible_cases = 0
    source_behavior_auxiliary_solve_unavailable_cases = 0
    source_behavior_auxiliary_solve_mutation_cases = 0
    source_behavior_report_cases = 0
    source_behavior_report_row_count = 0
    source_behavior_report_finding_count = 0
    source_behavior_report_finding_code_counts = Dict{String,Int}()
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
    tangent_observed_mode_count = 0
    tangent_not_observed_mode_count = 0
    tangent_policy_variable_count = 0
    iterative_probe_requested_cases = 0
    iterative_probe_available_cases = 0
    iterative_probe_converged_cases = 0
    iterative_probe_candidate_count = 0
    iterative_probe_unavailable_count = 0
    iterative_probe_no_small_residual_count = 0
    crosscheck_requested_cases = 0
    crosscheck_available_cases = 0
    crosscheck_restarted_converged_cases = 0
    crosscheck_harmonic_converged_cases = 0
    crosscheck_agreement_cases = 0
    crosscheck_inconclusive_cases = 0
    crosscheck_disagreement_cases = 0
    crosscheck_unavailable_count = 0
    crosscheck_original_audit_cases = 0
    crosscheck_relation_counts = Dict{String,Int}()
    crosscheck_underdimensioned_cases = 0
    dense_calibration_requested_cases = 0
    restarted_dense_available_cases = 0
    harmonic_dense_available_cases = 0
    restarted_dense_relation_counts = Dict{String,Int}()
    harmonic_dense_relation_counts = Dict{String,Int}()
    sparse_qr_nullspace_requested_cases = 0
    sparse_qr_nullspace_available_cases = 0
    sparse_qr_nullspace_dense_requested_cases = 0
    sparse_qr_nullspace_dense_available_cases = 0
    sparse_qr_nullspace_dense_relation_counts = Dict{String,Int}()
    sparse_qr_persistence_requested_cases = 0
    sparse_qr_persistence_available_cases = 0
    sparse_qr_persistence_repeat_requested_cases = 0
    sparse_qr_persistence_repeat_stable_cases = 0
    sparse_qr_persistence_nearby_requested_cases = 0
    sparse_qr_persistence_nearby_stable_cases = 0
    sparse_qr_persistence_rank_stable_cases = 0
    sparse_qr_persistence_residual_supported_cases = 0
    sparse_qr_persistence_finding_code_counts = Dict{String,Int}()
    sparse_qr_persistence_disconnected_explanation_cases = 0
    sparse_qr_persistence_physical_blocked_cases = 0
    sparse_qr_persistence_unexplained_cases = 0
    numerical_profile_cases = 0
    numerical_evaluation_failure_count = 0
    numerical_derivative_issue_count = 0
    numerical_expression_risk_count = 0
    maximum_sparse_qr_condition_proxy = nothing
    active_zero_jacobian_row_cases = 0
    active_zero_jacobian_row_count = 0
    inactive_zero_jacobian_row_count = 0
    inactive_stationary_diagonal_quadratic_row_count = 0
    active_stationary_diagonal_quadratic_row_count = 0
    violated_stationary_diagonal_quadratic_row_count = 0
    initialization_profile_cases = 0
    initialization_violation_cases = 0
    initialization_feasibility_violation_count = 0
    maximum_initialization_feasibility_violation = 0.0
    point_solve_requested_cases = 0
    point_solve_result_available_cases = 0
    point_solve_feasible_cases = 0
    point_solve_termination_status_counts = Dict{String,Int}()
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
        source_schema_coverage = _as_dict(get(case, "source_schema_coverage", nothing))
        auxiliary = _as_dict(get(case, "source_behavior_auxiliary", nothing))
        get(auxiliary, "status", "unavailable") != "unavailable" &&
            (source_behavior_auxiliary_cases += 1)
        source_behavior_auxiliary_materialized_pairs += _int(get(auxiliary,
            "constraint_pair_count", 0))
        get(auxiliary, "original_model_mutated", true) === true &&
            (source_behavior_auxiliary_mutation_cases += 1)
        auxiliary_solve = _as_dict(get(case, "source_behavior_auxiliary_solve", nothing))
        solve_status = string(get(auxiliary_solve, "status", "not_requested"))
        solve_solver = string(get(auxiliary_solve, "solver", "none"))
        source_behavior_auxiliary_solve_status_counts[solve_status] =
            get(source_behavior_auxiliary_solve_status_counts, solve_status, 0) + 1
        source_behavior_auxiliary_solve_solver_counts[solve_solver] =
            get(source_behavior_auxiliary_solve_solver_counts, solve_solver, 0) + 1
        solve_solver != "none" && (source_behavior_auxiliary_solve_requested_cases += 1)
        get(auxiliary_solve, "feasible", false) === true &&
            (source_behavior_auxiliary_solve_feasible_cases += 1)
        solve_status == "unavailable" &&
            (source_behavior_auxiliary_solve_unavailable_cases += 1)
        get(auxiliary_solve, "original_model_mutated", false) === true &&
            (source_behavior_auxiliary_solve_mutation_cases += 1)
        behavior_report = _as_dict(get(case, "source_behavior_report", nothing))
        get(behavior_report, "status", "unavailable") == "available" &&
            (source_behavior_report_cases += 1)
        source_behavior_report_row_count += _int(get(behavior_report, "row_count", 0))
        source_behavior_report_finding_count += _int(get(behavior_report,
            "finding_count", 0))
        for code in get(behavior_report, "finding_codes", Any[])
            code_string = string(code)
            source_behavior_report_finding_code_counts[code_string] =
                get(source_behavior_report_finding_code_counts, code_string, 0) + 1
        end
        if get(source_schema_coverage, "report_available", false) === true
            source_schema_context_report_cases += 1
            get(source_schema_coverage, "provenance_available", false) === true &&
                (source_schema_provenance_cases += 1)
            _count_csv!(source_schema_provenance_field_counts,
                get(source_schema_coverage, "provenance_fields", ""))
            _count_csv!(source_schema_provenance_warning_field_counts,
                get(source_schema_coverage, "provenance_warning_fields", ""))
            _count_csv!(source_schema_mapped_field_counts,
                get(source_schema_coverage, "mapped_fields", ""))
            _count_csv!(source_schema_unmapped_blocking_field_counts,
                get(source_schema_coverage, "unmapped_blocking_fields", ""))
            threshold_count = _int(get(source_schema_coverage,
                "threshold_observation_count", 0))
            threshold_count > 0 && (source_schema_threshold_observation_cases += 1)
            source_schema_threshold_observation_count += threshold_count
            _count_csv!(source_schema_threshold_status_counts,
                get(source_schema_coverage, "threshold_observation_statuses", ""))
            source_model_count = _int(get(source_schema_coverage,
                "source_model_observation_count", 0))
            source_model_count > 0 && (source_schema_source_model_contract_cases += 1)
            source_schema_source_model_observation_count += source_model_count
            _count_csv!(source_schema_source_model_status_counts,
                get(source_schema_coverage, "source_model_contract_statuses", ""))
            get(source_schema_coverage, "behavior_contract_available", false) === true &&
                (source_schema_behavior_contract_cases += 1)
            source_schema_behavior_candidate_count += _int(get(source_schema_coverage,
                "behavior_candidate_count", 0))
            source_schema_behavior_eligible_candidate_count += _int(get(source_schema_coverage,
                "behavior_eligible_candidate_count", 0))
            get(source_schema_coverage, "restoration_ready", false) === true &&
                (source_schema_mapping_ready_cases += 1)
        end
        snapshot = _as_dict(get(case, "source_snapshot", nothing))
        get(snapshot, "preserved", false) === true && (source_snapshot_cases += 1)
        numerical_profile = _as_dict(get(case, "numerical_profile", nothing))
        if get(numerical_profile, "available", false) === true
            numerical_profile_cases += 1
            numerical_evaluation_failure_count += _int(get(
                numerical_profile, "evaluation_failure_count", 0))
            numerical_derivative_issue_count += _int(get(
                numerical_profile, "derivative_issue_count", 0))
            numerical_expression_risk_count += _int(get(
                numerical_profile, "expression_numerical_risk_count", 0))
            active_zero_count = _int(get(numerical_profile,
                "active_zero_jacobian_row_count", 0))
            active_zero_jacobian_row_count += active_zero_count
            active_zero_count > 0 && (active_zero_jacobian_row_cases += 1)
            inactive_zero_jacobian_row_count += _int(get(numerical_profile,
                "inactive_zero_jacobian_row_count", 0))
            inactive_stationary_diagonal_quadratic_row_count += _int(get(
                numerical_profile,
                "inactive_stationary_diagonal_quadratic_row_count", 0))
            active_stationary_diagonal_quadratic_row_count += _int(get(
                numerical_profile,
                "active_stationary_diagonal_quadratic_row_count", 0))
            violated_stationary_diagonal_quadratic_row_count += _int(get(
                numerical_profile,
                "violated_stationary_diagonal_quadratic_row_count", 0))
            proxy = _float(get(numerical_profile,
                "sparse_qr_condition_proxy", nothing))
            if !isnothing(proxy)
                maximum_sparse_qr_condition_proxy =
                    isnothing(maximum_sparse_qr_condition_proxy) ? proxy :
                    max(maximum_sparse_qr_condition_proxy, proxy)
            end
        end
        initialization_profile = _as_dict(get(case,
            "initialization_profile", nothing))
        if get(initialization_profile, "available", false) === true
            initialization_profile_cases += 1
            violation_count = _int(get(initialization_profile,
                "feasibility_violation_count", 0))
            initialization_feasibility_violation_count += violation_count
            violation_count > 0 && (initialization_violation_cases += 1)
            violation = something(_float(get(initialization_profile,
                "maximum_feasibility_violation", nothing)), 0.0)
            maximum_initialization_feasibility_violation = max(
                maximum_initialization_feasibility_violation, violation)
        end
        point_solve = _as_dict(get(case, "point_solve", nothing))
        if get(point_solve, "requested", false) === true
            point_solve_requested_cases += 1
            get(point_solve, "solver_result_point_available", false) === true &&
                (point_solve_result_available_cases += 1)
            String(get(point_solve, "primal_status", "unknown")) ==
                "FEASIBLE_POINT" && (point_solve_feasible_cases += 1)
            termination = String(get(point_solve,
                "termination_status", "unknown"))
            point_solve_termination_status_counts[termination] = get(
                point_solve_termination_status_counts, termination, 0) + 1
        end
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
        mapped_fields = Set(strip(String(token)) for token in
            split(String(get(source_schema_coverage, "mapped_fields", "")), ',') if !isempty(strip(String(token))))
        for (field, impact) in zip(get(preflight, "source_schema_warning_fields", Any[]),
                                   get(preflight, "source_schema_warning_impacts", Any[]))
            key = String(impact)
            source_warning_impact_counts[key] = get(source_warning_impact_counts, key, 0) + 1
            impact_counts = fixture_profile["impact_counts"]
            impact_counts[key] = get(impact_counts, key, 0) + 1
            String(field) in mapped_fields ||
                (key != "representational" && (physical_metadata_warning_count += 1))
        end
        for policy in get(preflight, "source_schema_warning_policies", Any[])
            policy_dict = _as_dict(policy)
            status_key = String(get(policy_dict, "status", "unknown"))
            source_warning_policy_status_counts[status_key] =
                get(source_warning_policy_status_counts, status_key, 0) + 1
            policy_counts = fixture_profile["policy_status_counts"]
            policy_counts[status_key] = get(policy_counts, status_key, 0) + 1
        end
        mapping_statuses = Dict{String,String}()
        for item in split(String(get(source_schema_coverage, "mapping_field_statuses", "")), ';')
            isempty(strip(item)) && continue
            parts = split(item, "=>"; limit = 2)
            length(parts) == 2 || continue
            mapping_statuses[strip(parts[1])] = strip(parts[2])
        end
        for (field, policy) in zip(get(preflight, "source_schema_warning_fields", Any[]),
                                   get(preflight, "source_schema_warning_policies", Any[]))
            field_key = String(field)
            mapped_status = get(mapping_statuses, field_key, "")
            if !isempty(mapped_status) && mapped_status ∉ ("unmapped", "partially_mapped")
                raw_policy = _as_dict(policy)
                source_schema_field_policies[field_key] = Dict{String,Any}(
                    "impact" => get(raw_policy, "impact", "unknown"),
                    "status" => mapped_status,
                    "physical_readiness_blocking" => false,
                    "action" => "The source field is covered by an explicit BMOPF mapping contract; inspect its target and transform metadata.",
                )
            else
                source_schema_field_policies[field_key] = policy
            end
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
            tangent_observed_mode_count += _int(get(comparison, "tangent_observed_mode_count", 0))
            tangent_not_observed_mode_count += _int(get(comparison, "tangent_not_observed_mode_count", 0))
            tangent_policy_variable_count += _int(get(case,
                "expected_mode_tangent_policy_variable_count", 0))
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
        crosscheck = _as_dict(get(case,
            "smallest_singular_backend_crosscheck", nothing))
        crosscheck_dimension = _int(get(crosscheck, "requested_dimension", 0))
        if crosscheck_dimension > 0
            crosscheck_requested_cases += 1
            available = get(crosscheck, "available", false) === true
            available && (crosscheck_available_cases += 1)
            get(crosscheck, "original_coordinate_audit_available", false) === true &&
                (crosscheck_original_audit_cases += 1)
            get(crosscheck, "restarted_converged", false) === true &&
                (crosscheck_restarted_converged_cases += 1)
            get(crosscheck, "harmonic_converged", false) === true &&
                (crosscheck_harmonic_converged_cases += 1)
            relation = String(get(crosscheck, "relation", "unavailable"))
            crosscheck_relation_counts[relation] =
                get(crosscheck_relation_counts, relation, 0) + 1
            relation == "agreement" && (crosscheck_agreement_cases += 1)
            available && relation in ("both_unconverged", "restarted_unconverged",
                                      "harmonic_unconverged") &&
                (crosscheck_inconclusive_cases += 1)
            available && relation in ("singular_value_disagreement",
                                      "subspace_disagreement") &&
                (crosscheck_disagreement_cases += 1)
            crosscheck_unavailable_count += _int(get(crosscheck,
                "unavailable_finding_count", 0))
            get(crosscheck, "dimension_covers_structural_minimum", true) === false &&
                (crosscheck_underdimensioned_cases += 1)
            dense_calibration = _as_dict(get(crosscheck,
                "dense_calibration", nothing))
            if get(dense_calibration, "requested", false) === true
                dense_calibration_requested_cases += 1
                get(dense_calibration, "restarted_available", false) === true &&
                    (restarted_dense_available_cases += 1)
                get(dense_calibration, "harmonic_available", false) === true &&
                    (harmonic_dense_available_cases += 1)
                restarted_relation = String(get(dense_calibration,
                    "restarted_relation", "unavailable"))
                harmonic_relation = String(get(dense_calibration,
                    "harmonic_relation", "unavailable"))
                restarted_dense_relation_counts[restarted_relation] = get(
                    restarted_dense_relation_counts, restarted_relation, 0,
                ) + 1
                harmonic_dense_relation_counts[harmonic_relation] = get(
                    harmonic_dense_relation_counts, harmonic_relation, 0,
                ) + 1
            end
        end
        sparse_qr_nullspace = _as_dict(get(case,
            "sparse_qr_nullspace", nothing))
        if get(sparse_qr_nullspace, "requested", false) === true
            sparse_qr_nullspace_requested_cases += 1
            get(sparse_qr_nullspace, "available", false) === true &&
                (sparse_qr_nullspace_available_cases += 1)
            if get(sparse_qr_nullspace,
                "dense_calibration_requested", false) === true
                sparse_qr_nullspace_dense_requested_cases += 1
                get(sparse_qr_nullspace,
                    "dense_calibration_available", false) === true &&
                    (sparse_qr_nullspace_dense_available_cases += 1)
                relation = string(get(sparse_qr_nullspace,
                    "dense_calibration_relation", "unavailable"))
                sparse_qr_nullspace_dense_relation_counts[relation] = get(
                    sparse_qr_nullspace_dense_relation_counts, relation, 0,
                ) + 1
            end
        end
        sparse_qr_persistence = _as_dict(get(case,
            "sparse_qr_nullspace_persistence", nothing))
        if get(sparse_qr_persistence, "requested", false) === true
            sparse_qr_persistence_requested_cases += 1
            available = get(sparse_qr_persistence, "available", false) === true
            available && (sparse_qr_persistence_available_cases += 1)
            get(sparse_qr_persistence, "rank_stable", false) === true &&
                (sparse_qr_persistence_rank_stable_cases += 1)
            get(sparse_qr_persistence, "residual_supported", false) === true &&
                (sparse_qr_persistence_residual_supported_cases += 1)
            repeat_requested = _int(get(sparse_qr_persistence,
                "repeat_count", 0)) >= 2
            if repeat_requested
                sparse_qr_persistence_repeat_requested_cases += 1
                repeat_cosine = _float(get(sparse_qr_persistence,
                    "minimum_repeat_principal_cosine", nothing))
                threshold = _float(get(sparse_qr_persistence,
                    "alignment_threshold", nothing))
                !isnothing(repeat_cosine) && !isnothing(threshold) &&
                    repeat_cosine >= threshold &&
                    (sparse_qr_persistence_repeat_stable_cases += 1)
            end
            radii = get(sparse_qr_persistence, "radii", Any[])
            nearby_requested = radii isa AbstractVector && !isempty(radii)
            if nearby_requested
                sparse_qr_persistence_nearby_requested_cases += 1
                nearby_cosine = _float(get(sparse_qr_persistence,
                    "minimum_nearby_principal_cosine", nothing))
                threshold = _float(get(sparse_qr_persistence,
                    "alignment_threshold", nothing))
                get(sparse_qr_persistence, "rank_stable", false) === true &&
                    !isnothing(nearby_cosine) && !isnothing(threshold) &&
                    nearby_cosine >= threshold &&
                    (sparse_qr_persistence_nearby_stable_cases += 1)
            end
            for code in get(sparse_qr_persistence, "finding_codes", Any[])
                key = String(code)
                sparse_qr_persistence_finding_code_counts[key] = get(
                    sparse_qr_persistence_finding_code_counts, key, 0,
                ) + 1
            end
            get(sparse_qr_persistence, "support_is_disconnected", false) === true &&
                (sparse_qr_persistence_disconnected_explanation_cases += 1)
            expected_mode_count = _int(get(sparse_qr_persistence,
                "expected_mode_count", 0))
            expected_mode_count > 0 && get(sparse_qr_persistence,
                "physical_interpretation_ready", false) === false &&
                (sparse_qr_persistence_physical_blocked_cases += 1)
            expected_mode_count > 0 && get(sparse_qr_persistence,
                "expected_mode_span_explains_nullspace", true) === false &&
                (sparse_qr_persistence_unexplained_cases += 1)
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
        "severity" => physical_metadata_warning_count > 0 ? "warning" : "info",
        "observation" => physical_metadata_warning_count > 0 ?
            "The source loader emitted fidelity warnings with unresolved physical or device-semantic fields." :
            "The source loader emitted fidelity warnings, but every physical or device-semantic field is covered by an explicit mapping or behavior contract.",
        "evidence" => Dict("source_schema_warning_count" => source_schema_warnings,
                           "field_counts" => source_warning_field_counts,
                           "scope_counts" => source_warning_scope_counts,
                           "impact_counts" => source_warning_impact_counts,
                           "policy_status_counts" => source_warning_policy_status_counts,
                           "field_policies" => source_schema_field_policies,
                           "message_counts" => source_warning_message_counts,
                           "fixture_counts" => source_warning_fixture_counts),
        "suggested_action" => physical_metadata_warning_count > 0 ?
            "Inspect the retained source-schema warning details before treating fixture metadata as complete." :
            "Retain the raw warnings and mapping contract as provenance; do not reinterpret load-behavior thresholds as active bus bounds.",
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
    inactive_stationary_diagonal_quadratic_row_count > 0 && push!(findings, Dict(
        "code" => "multiconductor_inactive_stationary_diagonal_quadratic_rows",
        "severity" => "info",
        "observation" => "Zero-gradient positive-diagonal quadratic rows were recognized as strictly inactive at the selected points.",
        "evidence" => Dict(
            "row_count" => inactive_stationary_diagonal_quadratic_row_count,
            "active_row_count" => active_stationary_diagonal_quadratic_row_count,
            "violated_row_count" => violated_stationary_diagonal_quadratic_row_count,
        ),
        "suggested_action" => "Retain the local zero-gradient evidence, but do not classify these slack rows as active-set singularities.",
    ))
    active_stationary_diagonal_quadratic_row_count > 0 && push!(findings, Dict(
        "code" => "multiconductor_active_stationary_diagonal_quadratic_rows",
        "severity" => "warning",
        "observation" => "One or more active positive-diagonal quadratic rows have zero gradient at their exact center.",
        "evidence" => Dict("row_count" => active_stationary_diagonal_quadratic_row_count),
        "suggested_action" => "Inspect LICQ/MFCQ and exact minimum-level geometry before interpreting solver restoration behavior.",
    ))
    violated_stationary_diagonal_quadratic_row_count > 0 && push!(findings, Dict(
        "code" => "multiconductor_violated_stationary_diagonal_quadratic_rows",
        "severity" => "warning",
        "observation" => "One or more violated positive-diagonal quadratic rows have zero gradient at their exact center.",
        "evidence" => Dict("row_count" => violated_stationary_diagonal_quadratic_row_count),
        "suggested_action" => "Move initialization away from the stationary infeasible center or correct the quadratic level.",
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
    crosscheck_requested_cases > crosscheck_available_cases && push!(findings, Dict(
        "code" => "multiconductor_smallest_singular_crosscheck_unavailable",
        "severity" => "warning",
        "observation" => "The requested dense-free smallest-direction backend crosscheck was unavailable for one or more fixtures.",
        "evidence" => Dict("requested_case_count" => crosscheck_requested_cases,
                           "available_case_count" => crosscheck_available_cases,
                           "unavailable_finding_count" => crosscheck_unavailable_count,
                           "relation_counts" => crosscheck_relation_counts),
        "suggested_action" => "Inspect the product-path provenance and basis-entry guard; do not interpret missing backend evidence as a rank result.",
    ))
    crosscheck_underdimensioned_cases > 0 && push!(findings, Dict(
        "code" => "multiconductor_smallest_singular_crosscheck_dimension_below_structural_nullity",
        "severity" => "warning",
        "observation" => "One or more requested candidate dimensions are below the structurally unavoidable right nullity of a wide Jacobian.",
        "evidence" => Dict("requested_case_count" => crosscheck_requested_cases,
                           "underdimensioned_case_count" =>
                               crosscheck_underdimensioned_cases),
        "suggested_action" => "Request at least columns minus rows before comparing complete right-nullspace candidate spans.",
    ))
    crosscheck_inconclusive_cases > 0 && push!(findings, Dict(
        "code" => "multiconductor_smallest_singular_crosscheck_inconclusive",
        "severity" => "info",
        "observation" => "At least one bounded smallest-direction engine did not converge for one or more fixtures.",
        "evidence" => Dict("available_case_count" => crosscheck_available_cases,
                           "agreement_case_count" => crosscheck_agreement_cases,
                           "inconclusive_case_count" => crosscheck_inconclusive_cases,
                           "relation_counts" => crosscheck_relation_counts,
                           "restarted_converged_case_count" =>
                               crosscheck_restarted_converged_cases,
                           "harmonic_converged_case_count" =>
                               crosscheck_harmonic_converged_cases),
        "suggested_action" => "Treat these cases as coverage evidence and repeat with a larger explicit work budget before comparing candidate values or spans.",
    ))
    crosscheck_disagreement_cases > 0 && push!(findings, Dict(
        "code" => "multiconductor_smallest_singular_crosscheck_disagreement",
        "severity" => "warning",
        "observation" => "Converged independent sparse smallest-direction engines disagree for one or more fixtures.",
        "evidence" => Dict("available_case_count" => crosscheck_available_cases,
                           "agreement_case_count" => crosscheck_agreement_cases,
                           "inconclusive_case_count" => crosscheck_inconclusive_cases,
                           "disagreement_case_count" => crosscheck_disagreement_cases,
                           "relation_counts" => crosscheck_relation_counts,
                           "restarted_converged_case_count" =>
                               crosscheck_restarted_converged_cases,
                           "harmonic_converged_case_count" =>
                               crosscheck_harmonic_converged_cases),
        "suggested_action" => "Treat disagreement as search-budget or spectral-compression evidence, repeat under larger bounded budgets, and use dense SVD only on representative small fixtures.",
    ))
    dense_calibration_requested_cases > min(restarted_dense_available_cases,
                                             harmonic_dense_available_cases) &&
        push!(findings, Dict(
            "code" => "multiconductor_smallest_singular_dense_calibration_unavailable",
            "severity" => "warning",
            "observation" => "A requested guarded dense smallest-direction calibration was unavailable for one or both engines.",
            "evidence" => Dict("requested_case_count" =>
                                   dense_calibration_requested_cases,
                               "restarted_available_case_count" =>
                                   restarted_dense_available_cases,
                               "harmonic_available_case_count" =>
                                   harmonic_dense_available_cases),
            "suggested_action" => "Restrict the dense checkpoint to representative fixtures within the explicit entry guard.",
        ))
    sparse_qr_persistence_requested_cases >
        sparse_qr_persistence_available_cases && push!(findings, Dict(
            "code" => "multiconductor_sparse_qr_persistence_unavailable",
            "severity" => "warning",
            "observation" => "Sparse-QR nullspace persistence was unavailable for one or more requested fixtures.",
            "evidence" => Dict(
                "requested_case_count" => sparse_qr_persistence_requested_cases,
                "available_case_count" => sparse_qr_persistence_available_cases,
                "finding_code_counts" =>
                    sparse_qr_persistence_finding_code_counts,
            ),
            "suggested_action" => "Inspect coordinate alignment, derivative availability, and sparse factor guards at every persistence point.",
        ))
    sparse_qr_persistence_repeat_requested_cases >
        sparse_qr_persistence_repeat_stable_cases && push!(findings, Dict(
            "code" => "multiconductor_sparse_qr_repeatability_failure",
            "severity" => "warning",
            "observation" => "Sparse-QR nullspace spans were not repeatable at identical coordinates for one or more fixtures.",
            "evidence" => Dict(
                "repeat_requested_case_count" =>
                    sparse_qr_persistence_repeat_requested_cases,
                "repeat_stable_case_count" =>
                    sparse_qr_persistence_repeat_stable_cases,
            ),
            "suggested_action" => "Withhold nearby-point and physical interpretation until identical-point repeatability is restored.",
        ))
    sparse_qr_persistence_nearby_requested_cases >
        sparse_qr_persistence_nearby_stable_cases && push!(findings, Dict(
            "code" => "multiconductor_sparse_qr_nearby_not_persistent",
            "severity" => "warning",
            "observation" => "Sparse-QR nullspace dimension or span changed across the requested nearby points for one or more fixtures.",
            "evidence" => Dict(
                "nearby_requested_case_count" =>
                    sparse_qr_persistence_nearby_requested_cases,
                "nearby_stable_case_count" =>
                    sparse_qr_persistence_nearby_stable_cases,
                "rank_stable_case_count" =>
                    sparse_qr_persistence_rank_stable_cases,
            ),
            "suggested_action" => "Sweep smaller radii and inspect pivot thresholds and derivative provenance before assigning a persistent mode.",
        ))
    sparse_qr_persistence_requested_cases >
        sparse_qr_persistence_residual_supported_cases && push!(findings, Dict(
            "code" => "multiconductor_sparse_qr_persistence_residual_failure",
            "severity" => "warning",
            "observation" => "One or more persistence campaigns contain directions that fail the direct original-Jacobian residual gate.",
            "evidence" => Dict(
                "requested_case_count" => sparse_qr_persistence_requested_cases,
                "residual_supported_case_count" =>
                    sparse_qr_persistence_residual_supported_cases,
            ),
            "suggested_action" => "Do not project an inaccurate span into component or physical coordinates.",
        ))
    payload = Dict{String,Any}(
        "report_version" => "bmopf-multiconductor-smoke-summary-v1",
        "index_path" => index_path,
        "fixture_root" => get(index, "fixture_root", nothing),
        "environment" => get(index, "environment", Dict{String,Any}()),
        "environment_fingerprint" => get(index, "environment_fingerprint", nothing),
        "point_policy" => get(index, "point_policy", nothing),
        "point_solver_options" => get(index, "point_solver_options",
            Dict{String,Any}()),
        "source_behavior_solver" => get(index, "source_behavior_solver", "none"),
        "source_behavior_solver_attributes" => get(index,
            "source_behavior_solver_attributes", Dict{String,Any}()),
        "rank_max_dense_entries" => get(index, "rank_max_dense_entries", nothing),
        "smallest_singular_backend_crosscheck_dimension" => get(index,
            "smallest_singular_backend_crosscheck_dimension", nothing),
        "smallest_singular_backend_crosscheck_restarted_iterations" => get(index,
            "smallest_singular_backend_crosscheck_restarted_iterations", nothing),
        "smallest_singular_backend_crosscheck_restarted_alignment_threshold" => get(index,
            "smallest_singular_backend_crosscheck_restarted_alignment_threshold", nothing),
        "smallest_singular_backend_crosscheck_harmonic_steps_per_seed" => get(index,
            "smallest_singular_backend_crosscheck_harmonic_steps_per_seed", nothing),
        "smallest_singular_backend_crosscheck_harmonic_cycles" => get(index,
            "smallest_singular_backend_crosscheck_harmonic_cycles", nothing),
        "smallest_singular_backend_crosscheck_harmonic_alignment_threshold" => get(index,
            "smallest_singular_backend_crosscheck_harmonic_alignment_threshold", nothing),
        "smallest_singular_backend_crosscheck_max_basis_entries" => get(index,
            "smallest_singular_backend_crosscheck_max_basis_entries", nothing),
        "smallest_singular_backend_crosscheck_scaling" => get(index,
            "smallest_singular_backend_crosscheck_scaling", "none"),
        "smallest_singular_backend_crosscheck_dense_calibration" => get(index,
            "smallest_singular_backend_crosscheck_dense_calibration", false),
        "sparse_qr_nullspace" => get(index, "sparse_qr_nullspace", false),
        "sparse_qr_nullspace_scaling" => get(index,
            "sparse_qr_nullspace_scaling", "none"),
        "sparse_qr_nullspace_max_input_nonzeros" => get(index,
            "sparse_qr_nullspace_max_input_nonzeros", nothing),
        "sparse_qr_nullspace_max_factor_nonzeros" => get(index,
            "sparse_qr_nullspace_max_factor_nonzeros", nothing),
        "sparse_qr_nullspace_max_entries" => get(index,
            "sparse_qr_nullspace_max_entries", nothing),
        "sparse_qr_nullspace_dense_calibration" => get(index,
            "sparse_qr_nullspace_dense_calibration", false),
        "sparse_qr_nullspace_persistence_requested" => get(index,
            "sparse_qr_nullspace_persistence_requested", false),
        "sparse_qr_nullspace_persistence_repeat_count" => get(index,
            "sparse_qr_nullspace_persistence_repeat_count", 0),
        "sparse_qr_nullspace_persistence_radii" => get(index,
            "sparse_qr_nullspace_persistence_radii", Any[]),
        "sparse_qr_nullspace_persistence_direction_seed" => get(index,
            "sparse_qr_nullspace_persistence_direction_seed", 0),
        "sparse_qr_nullspace_persistence_alignment_threshold" => get(index,
            "sparse_qr_nullspace_persistence_alignment_threshold", nothing),
        "expected_mode_free_coordinate_policy" => get(index,
            "expected_mode_free_coordinate_policy", "unknown"),
        "expected_mode_tangent_policy" => get(index,
            "expected_mode_tangent_policy", "unknown"),
        "case_count" => length(cases),
        "status_counts" => status_counts,
        "cases" => cases,
        "aggregate" => Dict(
            "successful_case_count" => successful,
            "integrity_error_count" => integrity_errors,
            "integrity_warning_count" => integrity_warnings,
            "source_schema_warning_count" => source_schema_warnings,
            "numerical_profile_case_count" => numerical_profile_cases,
            "numerical_evaluation_failure_count" =>
                numerical_evaluation_failure_count,
            "numerical_derivative_issue_count" => numerical_derivative_issue_count,
            "numerical_expression_risk_count" => numerical_expression_risk_count,
            "maximum_sparse_qr_condition_proxy" =>
                maximum_sparse_qr_condition_proxy,
            "active_zero_jacobian_row_case_count" =>
                active_zero_jacobian_row_cases,
            "active_zero_jacobian_row_count" => active_zero_jacobian_row_count,
            "inactive_zero_jacobian_row_count" =>
                inactive_zero_jacobian_row_count,
            "inactive_stationary_diagonal_quadratic_row_count" =>
                inactive_stationary_diagonal_quadratic_row_count,
            "active_stationary_diagonal_quadratic_row_count" =>
                active_stationary_diagonal_quadratic_row_count,
            "violated_stationary_diagonal_quadratic_row_count" =>
                violated_stationary_diagonal_quadratic_row_count,
            "initialization_profile_case_count" => initialization_profile_cases,
            "initialization_violation_case_count" =>
                initialization_violation_cases,
            "initialization_feasibility_violation_count" =>
                initialization_feasibility_violation_count,
            "maximum_initialization_feasibility_violation" =>
                maximum_initialization_feasibility_violation,
            "point_solve_requested_case_count" => point_solve_requested_cases,
            "point_solve_result_available_case_count" =>
                point_solve_result_available_cases,
            "point_solve_feasible_case_count" => point_solve_feasible_cases,
            "point_solve_termination_status_counts" =>
                point_solve_termination_status_counts,
            "source_snapshot_case_count" => source_snapshot_cases,
            "source_schema_warning_message_counts" => source_warning_message_counts,
            "source_schema_warning_field_counts" => source_warning_field_counts,
            "source_schema_warning_scope_counts" => source_warning_scope_counts,
            "source_schema_warning_impact_counts" => source_warning_impact_counts,
            "source_schema_warning_policy_status_counts" => source_warning_policy_status_counts,
            "source_schema_field_policies" => source_schema_field_policies,
            "source_schema_warning_fixture_counts" => source_warning_fixture_counts,
            "physical_metadata_warning_count" => physical_metadata_warning_count,
            "source_schema_context_report_case_count" => source_schema_context_report_cases,
            "source_schema_provenance_case_count" => source_schema_provenance_cases,
            "source_schema_provenance_field_counts" => source_schema_provenance_field_counts,
            "source_schema_provenance_warning_field_counts" => source_schema_provenance_warning_field_counts,
            "source_schema_mapped_field_counts" => source_schema_mapped_field_counts,
            "source_schema_unmapped_blocking_field_counts" => source_schema_unmapped_blocking_field_counts,
            "source_schema_mapping_ready_case_count" => source_schema_mapping_ready_cases,
            "source_schema_threshold_observation_case_count" =>
                source_schema_threshold_observation_cases,
            "source_schema_threshold_observation_count" =>
                source_schema_threshold_observation_count,
            "source_schema_threshold_status_counts" => source_schema_threshold_status_counts,
            "source_schema_source_model_contract_case_count" =>
                source_schema_source_model_contract_cases,
            "source_schema_source_model_observation_count" =>
                source_schema_source_model_observation_count,
            "source_schema_source_model_status_counts" =>
                source_schema_source_model_status_counts,
            "source_schema_behavior_contract_case_count" =>
                source_schema_behavior_contract_cases,
            "source_schema_behavior_candidate_count" =>
                source_schema_behavior_candidate_count,
            "source_schema_behavior_eligible_candidate_count" =>
                source_schema_behavior_eligible_candidate_count,
            "source_behavior_auxiliary_case_count" => source_behavior_auxiliary_cases,
            "source_behavior_auxiliary_materialized_pair_count" =>
                source_behavior_auxiliary_materialized_pairs,
            "source_behavior_auxiliary_mutation_case_count" =>
                source_behavior_auxiliary_mutation_cases,
            "source_behavior_auxiliary_solve_status_counts" =>
                source_behavior_auxiliary_solve_status_counts,
            "source_behavior_auxiliary_solve_solver_counts" =>
                source_behavior_auxiliary_solve_solver_counts,
            "source_behavior_auxiliary_solve_requested_case_count" =>
                source_behavior_auxiliary_solve_requested_cases,
            "source_behavior_auxiliary_solve_feasible_case_count" =>
                source_behavior_auxiliary_solve_feasible_cases,
            "source_behavior_auxiliary_solve_unavailable_case_count" =>
                source_behavior_auxiliary_solve_unavailable_cases,
            "source_behavior_auxiliary_solve_mutation_case_count" =>
                source_behavior_auxiliary_solve_mutation_cases,
            "source_behavior_report_case_count" => source_behavior_report_cases,
            "source_behavior_report_row_count" => source_behavior_report_row_count,
            "source_behavior_report_finding_count" => source_behavior_report_finding_count,
            "source_behavior_report_finding_code_counts" =>
                source_behavior_report_finding_code_counts,
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
            "tangent_observed_physical_mode_count" => tangent_observed_mode_count,
            "tangent_not_observed_physical_mode_count" => tangent_not_observed_mode_count,
            "tangent_policy_variable_count_sum" => tangent_policy_variable_count,
            "iterative_probe_requested_case_count" => iterative_probe_requested_cases,
            "iterative_probe_available_case_count" => iterative_probe_available_cases,
            "iterative_probe_converged_case_count" => iterative_probe_converged_cases,
            "iterative_probe_candidate_count" => iterative_probe_candidate_count,
            "iterative_probe_unavailable_finding_count" => iterative_probe_unavailable_count,
            "iterative_probe_no_small_residual_finding_count" => iterative_probe_no_small_residual_count,
            "smallest_singular_crosscheck_requested_case_count" =>
                crosscheck_requested_cases,
            "smallest_singular_crosscheck_available_case_count" =>
                crosscheck_available_cases,
            "smallest_singular_crosscheck_original_audit_case_count" =>
                crosscheck_original_audit_cases,
            "smallest_singular_crosscheck_restarted_converged_case_count" =>
                crosscheck_restarted_converged_cases,
            "smallest_singular_crosscheck_harmonic_converged_case_count" =>
                crosscheck_harmonic_converged_cases,
            "smallest_singular_crosscheck_agreement_case_count" =>
                crosscheck_agreement_cases,
            "smallest_singular_crosscheck_inconclusive_case_count" =>
                crosscheck_inconclusive_cases,
            "smallest_singular_crosscheck_disagreement_case_count" =>
                crosscheck_disagreement_cases,
            "smallest_singular_crosscheck_unavailable_finding_count" =>
                crosscheck_unavailable_count,
            "smallest_singular_crosscheck_relation_counts" =>
                crosscheck_relation_counts,
            "smallest_singular_crosscheck_underdimensioned_case_count" =>
                crosscheck_underdimensioned_cases,
            "smallest_singular_dense_calibration_requested_case_count" =>
                dense_calibration_requested_cases,
            "restarted_smallest_singular_dense_available_case_count" =>
                restarted_dense_available_cases,
            "harmonic_smallest_singular_dense_available_case_count" =>
                harmonic_dense_available_cases,
            "restarted_smallest_singular_dense_relation_counts" =>
                restarted_dense_relation_counts,
            "harmonic_smallest_singular_dense_relation_counts" =>
                harmonic_dense_relation_counts,
            "sparse_qr_nullspace_requested_case_count" =>
                sparse_qr_nullspace_requested_cases,
            "sparse_qr_nullspace_available_case_count" =>
                sparse_qr_nullspace_available_cases,
            "sparse_qr_nullspace_dense_requested_case_count" =>
                sparse_qr_nullspace_dense_requested_cases,
            "sparse_qr_nullspace_dense_available_case_count" =>
                sparse_qr_nullspace_dense_available_cases,
            "sparse_qr_nullspace_dense_relation_counts" =>
                sparse_qr_nullspace_dense_relation_counts,
            "sparse_qr_nullspace_persistence_requested_case_count" =>
                sparse_qr_persistence_requested_cases,
            "sparse_qr_nullspace_persistence_available_case_count" =>
                sparse_qr_persistence_available_cases,
            "sparse_qr_nullspace_persistence_repeat_requested_case_count" =>
                sparse_qr_persistence_repeat_requested_cases,
            "sparse_qr_nullspace_persistence_repeat_stable_case_count" =>
                sparse_qr_persistence_repeat_stable_cases,
            "sparse_qr_nullspace_persistence_nearby_requested_case_count" =>
                sparse_qr_persistence_nearby_requested_cases,
            "sparse_qr_nullspace_persistence_nearby_stable_case_count" =>
                sparse_qr_persistence_nearby_stable_cases,
            "sparse_qr_nullspace_persistence_rank_stable_case_count" =>
                sparse_qr_persistence_rank_stable_cases,
            "sparse_qr_nullspace_persistence_residual_supported_case_count" =>
                sparse_qr_persistence_residual_supported_cases,
            "sparse_qr_nullspace_persistence_finding_code_counts" =>
                sparse_qr_persistence_finding_code_counts,
            "sparse_qr_nullspace_persistence_disconnected_explanation_case_count" =>
                sparse_qr_persistence_disconnected_explanation_cases,
            "sparse_qr_nullspace_persistence_physical_blocked_case_count" =>
                sparse_qr_persistence_physical_blocked_cases,
            "sparse_qr_nullspace_persistence_unexplained_case_count" =>
                sparse_qr_persistence_unexplained_cases,
            "physical_mode_comparison_status_counts" => mode_status_counts,
        ),
        "readiness" => Dict(
            "all_cases_successful" => !isempty(cases) && successful == length(cases),
            "dense_budget_explicit" => all(haskey(case, "rank_max_dense_entries") for case in cases),
            "port_contract_available" => successful > 0 && contract_available == successful,
            "integrity_preflight_clear" => integrity_errors == 0,
            "numerical_profile_complete" => successful > 0 &&
                numerical_profile_cases == successful,
            "numerical_evaluations_finite" =>
                numerical_evaluation_failure_count == 0,
            "derivative_evaluations_clear" =>
                numerical_derivative_issue_count == 0,
            "no_active_zero_jacobian_rows" =>
                active_zero_jacobian_row_cases == 0,
            "no_active_stationary_diagonal_quadratic_rows" =>
                active_stationary_diagonal_quadratic_row_count == 0,
            "no_violated_stationary_diagonal_quadratic_rows" =>
                violated_stationary_diagonal_quadratic_row_count == 0,
            "initialization_profile_complete" => successful > 0 &&
                initialization_profile_cases == successful,
            "initialization_feasible" => initialization_profile_cases > 0 &&
                initialization_violation_cases == 0,
            "solver_result_point_available" => point_solve_requested_cases == 0 ||
                point_solve_result_available_cases == point_solve_requested_cases,
            "solver_result_point_feasible" => point_solve_requested_cases == 0 ||
                point_solve_feasible_cases == point_solve_requested_cases,
            "source_fixtures_preserved" => successful > 0 && source_snapshot_cases == successful,
            "source_schema_context_report_available" => successful > 0 &&
                source_schema_context_report_cases == successful,
            "source_schema_provenance_available" => successful > 0 &&
                source_schema_provenance_cases == successful,
            "source_schema_mapping_complete" => successful > 0 &&
                source_schema_mapping_ready_cases == successful,
            "source_schema_semantic_observations_available" => successful > 0 &&
                source_schema_threshold_observation_cases == successful &&
                source_schema_source_model_contract_cases == successful,
            "source_schema_behavior_contract_available" => successful > 0 &&
                source_schema_behavior_contract_cases == successful,
            "source_behavior_auxiliary_available" => successful > 0 &&
                source_behavior_auxiliary_cases == successful &&
                source_behavior_auxiliary_mutation_cases == 0,
            "source_behavior_report_available" => successful > 0 &&
                source_behavior_report_cases == successful,
            "source_behavior_auxiliary_solve_complete" =>
                source_behavior_auxiliary_solve_requested_cases == 0 ||
                source_behavior_auxiliary_solve_unavailable_cases == 0,
            "source_behavior_auxiliary_solve_non_mutating" =>
                source_behavior_auxiliary_solve_mutation_cases == 0,
            "physical_metadata_complete" => physical_metadata_warning_count == 0,
            "physical_mode_observations_available" => physical_mode_count > 0,
            "physical_mode_analysis_available" => successful > 0 && mode_analysis_cases == successful,
            "mode_projection_observations_available" => successful > 0 &&
                mode_projection_cases == successful,
            "mode_jacobian_match_observations_available" => successful > 0 &&
                mode_match_cases == successful,
            "mode_free_coordinate_projection_policy" => get(index,
                "expected_mode_free_coordinate_policy", "unknown"),
            "mode_tangent_policy" => get(index,
                "expected_mode_tangent_policy", "unknown"),
            "mode_tangent_policy_available" => get(index,
                "expected_mode_tangent_policy", "none") != "none",
            "dense_physical_mode_rank_complete" => successful > 0 &&
                mode_analysis_cases == successful && mode_rank_available_cases == successful,
            "expected_observed_mode_comparison" => successful > 0 &&
                mode_analysis_cases == successful && mode_rank_available_cases == successful &&
                unaligned_mode_count == 0,
            "iterative_right_nullspace_probe" => iterative_probe_requested_cases == 0 ||
                iterative_probe_requested_cases == iterative_probe_available_cases,
            "smallest_singular_backend_crosscheck" => crosscheck_requested_cases == 0 ||
                crosscheck_requested_cases == crosscheck_available_cases,
            "smallest_singular_backend_original_coordinate_audit" =>
                crosscheck_requested_cases == 0 ||
                crosscheck_requested_cases == crosscheck_original_audit_cases,
            "smallest_singular_backend_crosscheck_dimension_covers_structural_minimum" =>
                crosscheck_underdimensioned_cases == 0,
            "smallest_singular_backend_crosscheck_agreement" =>
                crosscheck_requested_cases == 0 ||
                crosscheck_requested_cases == crosscheck_agreement_cases,
            "smallest_singular_backend_dense_calibration" =>
                dense_calibration_requested_cases == 0 ||
                (dense_calibration_requested_cases ==
                    restarted_dense_available_cases ==
                    harmonic_dense_available_cases),
            "sparse_qr_nullspace" => sparse_qr_nullspace_requested_cases == 0 ||
                sparse_qr_nullspace_requested_cases ==
                    sparse_qr_nullspace_available_cases,
            "sparse_qr_nullspace_dense_calibration" =>
                sparse_qr_nullspace_dense_requested_cases == 0 ||
                sparse_qr_nullspace_dense_requested_cases ==
                    sparse_qr_nullspace_dense_available_cases,
            "sparse_qr_nullspace_persistence" =>
                sparse_qr_persistence_requested_cases == 0 ||
                sparse_qr_persistence_requested_cases ==
                    sparse_qr_persistence_available_cases,
            "sparse_qr_nullspace_repeatability" =>
                sparse_qr_persistence_repeat_requested_cases == 0 ||
                sparse_qr_persistence_repeat_requested_cases ==
                    sparse_qr_persistence_repeat_stable_cases,
            "sparse_qr_nullspace_nearby_persistence" =>
                sparse_qr_persistence_nearby_requested_cases == 0 ||
                sparse_qr_persistence_nearby_requested_cases ==
                    sparse_qr_persistence_nearby_stable_cases,
            "sparse_qr_nullspace_persistence_residual_support" =>
                sparse_qr_persistence_requested_cases == 0 ||
                sparse_qr_persistence_requested_cases ==
                    sparse_qr_persistence_residual_supported_cases,
        ),
        "findings" => findings,
        "interpretation" => "Multiconductor contract aggregation only; port maps and physical modes are evidence records, not solver-independent physical certificates.",
    )
    write(output_path, JSON.json(payload))
    println("wrote BMOPF multiconductor smoke summary to $output_path")
end

main()
