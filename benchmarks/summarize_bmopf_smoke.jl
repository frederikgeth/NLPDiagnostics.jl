#!/usr/bin/env julia

# Summarize JSON records emitted by bmopf_smoke.jl or bmopf_draft_corpus.jl:
#
# julia --project=. benchmarks/summarize_bmopf_smoke.jl /path/to/bmopf-smoke-results

Base.include(@__MODULE__, joinpath(@__DIR__, "common.jl"))
using .NLPDiagnosticsBenchmarkCommon: read_summary, write_json

function _int(value, default = 0)
    value isa Integer && return Int(value)
    value isa Number && return Int(value)
    value isa AbstractString || return default
    try
        return parse(Int, value)
    catch
        return default
    end
end

function _count_codes(reports)
    counts = Dict{String,Int}()
    for report in values(reports)
        for finding in report["findings"]
            code = finding["code"]
            counts[code] = get(counts, code, 0) + 1
        end
    end
    return Dict(key => counts[key] for key in sort!(collect(keys(counts))))
end

function _count_finding_field(reports, field)
    counts = Dict{String,Int}()
    for report in values(reports)
        for finding in report["findings"]
            value = get(finding, field, nothing)
            value === nothing && continue
            key = String(value)
            counts[key] = get(counts, key, 0) + 1
        end
    end
    return Dict(key => counts[key] for key in sort!(collect(keys(counts))))
end

function _finding_attributes(reports)
    return Dict(
        "severity" => _count_finding_field(reports, "severity"),
        "domain" => _count_finding_field(reports, "domain"),
        "confidence" => _count_finding_field(reports, "confidence"),
        "basis" => _count_finding_field(reports, "basis"),
    )
end

_sorted_counts(counts) = Dict(key => counts[key] for key in sort!(collect(keys(counts))))

function _parse_count_map(value)
    result = Dict{String,Int}()
    if value isa AbstractDict
        for (key, raw) in value
            try
                result[String(key)] = Int(raw)
            catch
            end
        end
        return result
    end
    value isa AbstractString || return result
    for item in filter(!isempty, split(value, ','))
        parts = split(item, '='; limit = 2)
        length(parts) == 2 || continue
        try
            result[String(strip(parts[1]))] = parse(Int, strip(parts[2]))
        catch
        end
    end
    return result
end

function _collect_numeric_metrics!(destination, metrics)
    metrics isa AbstractDict || return destination
    for (key, value) in metrics
        value isa Number || continue
        isfinite(Float64(value)) || continue
        bucket = get!(destination, String(key), Float64[])
        push!(bucket, Float64(value))
    end
    return destination
end

function _metric_summaries(metrics)
    return Dict(
        key => Dict(
            "sample_count" => length(values),
            "minimum" => minimum(values),
            "mean" => sum(values) / length(values),
            "maximum" => maximum(values),
        ) for (key, values) in sort!(collect(metrics); by = first) if !isempty(values)
    )
end

function _report_counts(report)
    isnothing(report) && return Dict{String,Int}()
    return _count_codes(Dict("report" => report))
end

function _index_root(index)
    if haskey(index, "fixture_root")
        return ("fixture_root", index["fixture_root"])
    elseif haskey(index, "benchmark_root")
        return ("benchmark_root", index["benchmark_root"])
    end
    return ("source_root", nothing)
end

function main()
    output_dir = isempty(ARGS) ? get(ENV, "NLPDIAGNOSTICS_BMOPF_OUTPUT_DIR", "") : first(ARGS)
    isempty(output_dir) && error(
        "Pass the bmopf-smoke-results directory or set NLPDIAGNOSTICS_BMOPF_OUTPUT_DIR",
    )
    index_path = joinpath(output_dir, "index.json")
    isfile(index_path) || error("index file is missing: $index_path")
    index = read_summary(index_path; root = "/")
    cases = Vector{Dict{String,Any}}()
    aggregate_generic = Dict{String,Int}()
    aggregate_context = Dict{String,Int}()
    aggregate_initialization = Dict{String,Int}()
    aggregate_generic_attributes = Dict{String,Dict{String,Int}}()
    aggregate_context_attributes = Dict{String,Dict{String,Int}}()
    aggregate_initialization_attributes = Dict{String,Dict{String,Int}}()
    aggregate_integrity = Dict{String,Int}()
    integrity_error_cases = 0
    integrity_warning_cases = 0
    source_schema_warning_count = 0
    integrity_finding_cases = 0
    dense_eligible_cases = 0
    dense_skipped_cases = 0
    dense_not_requested_cases = 0
    dense_unknown_cases = 0
    saved_result_cases = 0
    saved_result_fallback_coordinates = 0
    saved_result_unresolved_records = 0
    saved_result_unresolved_families = Dict{String,Int}()
    saved_result_projected_records = 0
    saved_result_projected_families = Dict{String,Int}()
    saved_result_projection_contracts = Set{String}()
    saved_result_unregistered_model_coordinates = 0
    saved_result_unmapped_registered_coordinates = 0
    saved_result_mapping_fractions = Float64[]
    saved_result_units = Dict{String,Int}()
    saved_result_field_units = Dict{String,Int}()
    saved_result_unit_scale_warning_cases = 0
    saved_result_mapping_warning_cases = 0
    skipped_cases = 0
    error_cases = 0
    profile_case_count = 0
    trusted_point_selected_cases = 0
    trusted_point_rejected_cases = 0
    trusted_point_incomplete_cases = 0
    trusted_point_missing_case_records = 0
    floating_neutral_candidate_cases = 0
    floating_neutral_candidate_modes = 0
    component_rank_capability_cases = 0
    component_rank_capability_checked_cases = 0
    component_rank_capability_components = 0
    component_rank_capability_declared = 0
    component_rank_capability_unavailable = 0
    component_rank_capability_findings = 0
    component_rank_capability_coverages = Float64[]
    feasibility_attribution_cases = 0
    feasibility_attribution_violation_rows = 0
    feasibility_attribution_unsupported_rows = 0
    feasibility_attribution_family_rows = Dict{String,Int}()
    feasibility_attribution_jacobian_methods = Dict{String,Int}()
    feasibility_attribution_constraint_families = Dict{String,Int}()
    feasibility_attribution_constraint_instances = Dict{String,Int}()
    feasibility_attribution_components = Dict{String,Int}()
    feasibility_attribution_registered_rows = 0
    feasibility_attribution_unregistered_rows = 0
    feasibility_attribution_model_rows = 0
    feasibility_attribution_model_registered_rows = 0
    feasibility_attribution_model_unregistered_rows = 0
    feasibility_attribution_model_constraint_families = Dict{String,Int}()
    registry_coverage_cases = 0
    registry_coverage_rows = 0
    registry_coverage_registered_rows = 0
    registry_coverage_unregistered_rows = 0
    registry_coverage_registered_families = Dict{String,Int}()
    result_field_catalog_cases = 0
    aggregate_stage_seconds = Dict{String,Vector{Float64}}()
    aggregate_stage_allocations = Dict{String,Vector{Float64}}()
    multiconductor_case_count = 0
    multiconductor_finding_cases = 0
    multiconductor_metric_values = Dict{String,Vector{Float64}}()
    multiconductor_constitutive_ranks = Float64[]
    multiconductor_complex_constitutive_ranks = Float64[]
    multiconductor_passive_current_ranks = Float64[]
    multiconductor_passive_current_model_ranks = Float64[]
    multiconductor_current_law_families = Dict{String,Int}()
    multiconductor_current_law_operating_statuses = Dict{String,Int}()
    multiconductor_controller_curve_families = Dict{String,Int}()
    multiconductor_controller_curve_statuses = Dict{String,Int}()
    multiconductor_controller_curve_semantics = Dict{String,Int}()
    controller_curve_profile_case_count = 0
    controller_curve_profile_observation_counts = Float64[]
    controller_curve_profile_families = Dict{String,Int}()
    controller_curve_profile_statuses = Dict{String,Int}()
    controller_curve_profile_semantics = Dict{String,Int}()
    multiconductor_physical_mode_categories = Dict{String,Int}()
    for entry in index["cases"]
        record_path = joinpath(output_dir, entry["result_file"])
        record = read_summary(record_path; root = "/")
        summary = Dict{String,Any}(entry)
        preflight = get(record, "integrity_preflight", nothing)
        if preflight isa AbstractDict
            errors = Int(get(preflight, "error_count", 0))
            warnings = Int(get(preflight, "warning_count", 0))
            integrity_error_cases += errors > 0
            integrity_warning_cases += warnings > 0
            source_schema_warning_count += Int(get(preflight, "source_schema_warning_count", 0))
            integrity_finding_cases += Int(get(preflight, "finding_count", 0)) > 0
            summary["integrity_preflight"] = Dict(
                "error_count" => errors,
                "warning_count" => warnings,
                "finding_count" => Int(get(preflight, "finding_count", 0)),
                "source_schema_warning_count" => Int(get(preflight, "source_schema_warning_count", 0)),
                "blocking" => Bool(get(preflight, "blocking", false)),
            )
            for finding in get(preflight, "findings", Any[])
                code = String(finding["code"])
                aggregate_integrity[code] = get(aggregate_integrity, code, 0) + 1
            end
        end
        if entry["status"] == "skipped"
            skipped_cases += 1
            summary["skip_reason"] = get(entry, "skip_reason", "unknown")
        elseif entry["status"] == "error"
            error_cases += 1
        elseif entry["status"] == "ok"
            analysis_mode = get(record, "analysis_mode", "profile")
            profile = get(record, "profile", nothing)
            generic, context, initialization = if analysis_mode == "structural"
                (_report_counts(record["report"]), Dict{String,Int}(), Dict{String,Int}())
            else
                profile isa AbstractDict || error(
                    "profile record is missing for non-structural case ",
                    get(entry, "name", "?"),
                )
                (_count_codes(profile["profile"]["reports"]),
                 _report_counts(profile["bmopf_context_report"]),
                 _report_counts(profile["bmopf_initialization_report"]))
            end
            for (counts, aggregate) in (
                (generic, aggregate_generic),
                (context, aggregate_context),
                (initialization, aggregate_initialization),
            )
                for (code, count) in counts
                    aggregate[code] = get(aggregate, code, 0) + count
                end
            end
            generic_attributes, context_attributes, initialization_attributes = if analysis_mode == "structural"
                (Dict{String,Any}(), Dict{String,Any}(), Dict{String,Any}())
            else
                (_finding_attributes(profile["profile"]["reports"]),
                 _finding_attributes(Dict("report" => profile["bmopf_context_report"])),
                 _finding_attributes(Dict("report" => profile["bmopf_initialization_report"])))
            end
            for (attributes, aggregate) in (
                (generic_attributes, aggregate_generic_attributes),
                (context_attributes, aggregate_context_attributes),
                (initialization_attributes, aggregate_initialization_attributes),
            )
                for (field, counts) in attributes
                    destination = get!(aggregate, field, Dict{String,Int}())
                    for (value, count) in counts
                        destination[value] = get(destination, value, 0) + count
                    end
                end
            end
            summary["point_policy"] = get(record, "point_policy", "unknown")
            summary["analysis_mode"] = analysis_mode
            summary["generic_finding_codes"] = generic
            summary["context_finding_codes"] = context
            summary["initialization_finding_codes"] = initialization
            summary["generic_finding_attributes"] = generic_attributes
            summary["context_finding_attributes"] = context_attributes
            summary["initialization_finding_attributes"] = initialization_attributes
            multiconductor_contract = get(record, "multiconductor_contract", nothing)
            if multiconductor_contract isa AbstractDict
                multiconductor_case_count += 1
                summary["multiconductor_contract"] = multiconductor_contract
                contract_finding_count = 0
                for field in (
                    "voltage_report_finding_count",
                    "port_assembly_finding_count",
                    "current_law_finding_count",
                    "current_law_operating_point_finding_count",
                    "current_report_finding_count",
                    "physical_mode_finding_count",
                    "constitutive_map_finding_count",
                    "complex_constitutive_map_finding_count",
                    "passive_network_current_map_finding_count",
                    "passive_network_current_model_map_finding_count",
                )
                    raw = get(multiconductor_contract, field, nothing)
                    raw isa Number || continue
                    count = Int(raw)
                    contract_finding_count += count
                    bucket = get!(multiconductor_metric_values, field, Float64[])
                    push!(bucket, Float64(count))
                end
                contract_finding_count > 0 && (multiconductor_finding_cases += 1)
                for field in (
                    "voltage_port_count",
                    "voltage_coordinate_map_count",
                    "voltage_connection_count",
                    "port_assembly_component_count",
                    "port_assembly_connected_component_count",
                    "current_law_fingerprint_count",
                    "current_law_operating_point_probe_count",
                    "controller_curve_observation_count",
                    "controller_curve_breakpoint_proximity_count",
                    "controller_curve_invalid_profile_count",
                    "controller_curve_exact_monitor_count",
                    "controller_curve_proxy_monitor_count",
                    "controller_curve_equation_residual_count",
                    "controller_curve_cap_violation_count",
                    "current_port_count",
                    "current_coordinate_map_count",
                    "current_skipped_count",
                    "physical_mode_count",
                    "constitutive_map_count",
                    "complex_constitutive_map_count",
                    "passive_network_current_map_count",
                    "passive_network_current_model_map_count",
                )
                    raw = get(multiconductor_contract, field, nothing)
                    raw isa Number || continue
                    bucket = get!(multiconductor_metric_values, field, Float64[])
                    push!(bucket, Float64(raw))
                end
                ranks = get(multiconductor_contract, "constitutive_map_ranks", Any[])
                if ranks isa AbstractVector
                    for rank in ranks
                        rank isa Number || continue
                        isfinite(Float64(rank)) || continue
                        push!(multiconductor_constitutive_ranks, Float64(rank))
                    end
                end
                complex_ranks = get(multiconductor_contract, "complex_constitutive_map_ranks", Any[])
                if complex_ranks isa AbstractVector
                    for rank in complex_ranks
                        rank isa Number || continue
                        isfinite(Float64(rank)) || continue
                        push!(multiconductor_complex_constitutive_ranks, Float64(rank))
                    end
                end
                passive_ranks = get(multiconductor_contract, "passive_network_current_map_ranks", Any[])
                if passive_ranks isa AbstractVector
                    for rank in passive_ranks
                        rank isa Number || continue
                        isfinite(Float64(rank)) || continue
                        push!(multiconductor_passive_current_ranks, Float64(rank))
                    end
                end
                passive_model_ranks = get(multiconductor_contract, "passive_network_current_model_map_ranks", Any[])
                if passive_model_ranks isa AbstractVector
                    for rank in passive_model_ranks
                        rank isa Number || continue
                        isfinite(Float64(rank)) || continue
                        push!(multiconductor_passive_current_model_ranks, Float64(rank))
                    end
                end
                categories = get(multiconductor_contract, "physical_mode_categories", Any[])
                if categories isa AbstractVector
                    for category in categories
                        key = String(category)
                        multiconductor_physical_mode_categories[key] =
                            get(multiconductor_physical_mode_categories, key, 0) + 1
                    end
                end
                law_families = get(multiconductor_contract, "current_law_families", Any[])
                if law_families isa AbstractVector
                    for family in law_families
                        key = String(family)
                        multiconductor_current_law_families[key] =
                            get(multiconductor_current_law_families, key, 0) + 1
                    end
                end
                operating_statuses = get(multiconductor_contract, "current_law_operating_point_statuses", Any[])
                if operating_statuses isa AbstractVector
                    for status in operating_statuses
                        key = String(status)
                        multiconductor_current_law_operating_statuses[key] =
                            get(multiconductor_current_law_operating_statuses, key, 0) + 1
                    end
                end
                curve_families = get(multiconductor_contract, "controller_curve_families", Any[])
                if curve_families isa AbstractVector
                    for family in curve_families
                        key = String(family)
                        multiconductor_controller_curve_families[key] =
                            get(multiconductor_controller_curve_families, key, 0) + 1
                    end
                end
                curve_statuses = get(multiconductor_contract, "controller_curve_statuses", Any[])
                if curve_statuses isa AbstractVector
                    for status in curve_statuses
                        key = String(status)
                        multiconductor_controller_curve_statuses[key] =
                            get(multiconductor_controller_curve_statuses, key, 0) + 1
                    end
                end
                curve_semantics = get(multiconductor_contract, "controller_curve_voltage_semantics", Any[])
                if curve_semantics isa AbstractVector
                    for semantics in curve_semantics
                        key = String(semantics)
                        multiconductor_controller_curve_semantics[key] =
                            get(multiconductor_controller_curve_semantics, key, 0) + 1
                    end
                end
            end
            report_metadata = if analysis_mode == "structural"
                get(record["report"], "metadata", Dict{String,Any}())
            else
                get(profile["bmopf_context_report"], "metadata", Dict{String,Any}())
            end
            candidate_modes = try
                parse(Int, string(get(report_metadata,
                    "bmopf_floating_neutral_candidate_mode_count", "0")))
            catch
                0
            end
            candidate_modes > 0 && (floating_neutral_candidate_cases += 1)
            floating_neutral_candidate_modes += candidate_modes
            summary["floating_neutral_candidate_mode_count"] = candidate_modes
            if analysis_mode != "structural" && haskey(record, "profile")
                profile_case_count += 1
                profile_case = get(get(profile, "profile", Dict()), "case", Dict())
                point_trust = get(profile_case, "point_trust", nothing)
                if point_trust isa AbstractDict
                    trust_metadata = get(point_trust, "metadata", Dict())
                    selected = _int(get(trust_metadata, "selected_count", 0), 0)
                    rejected = _int(get(trust_metadata, "rejected_count", 0), 0)
                    selected > 0 && (trusted_point_selected_cases += 1)
                    rejected > 0 && (trusted_point_rejected_cases += 1)
                    reasons = String(get(trust_metadata, "rejected_reasons", ""))
                    occursin("incomplete", lowercase(reasons)) &&
                        (trusted_point_incomplete_cases += 1)
                else
                    trusted_point_missing_case_records += 1
                end
                controller_curve_profile = get(profile, "bmopf_controller_curve_observations", nothing)
                if controller_curve_profile isa AbstractDict
                    controller_curve_profile_case_count += 1
                    observation_count = get(controller_curve_profile, "observation_count", nothing)
                    observation_count isa Number && push!(
                        controller_curve_profile_observation_counts,
                        Float64(observation_count),
                    )
                    for (field, destination) in (
                        ("families", controller_curve_profile_families),
                        ("statuses", controller_curve_profile_statuses),
                        ("monitor_semantics", controller_curve_profile_semantics),
                    )
                        values = get(controller_curve_profile, field, Any[])
                        values isa AbstractVector || continue
                        for value in values
                            key = String(value)
                            destination[key] = get(destination, key, 0) + 1
                        end
                    end
                end
                catalog = get(profile, "bmopf_result_field_catalog", nothing)
                catalog isa AbstractDict && (result_field_catalog_cases += 1)
                registry_coverage = get(profile,
                    "bmopf_constraint_registry_coverage", nothing)
                if registry_coverage isa AbstractDict
                    registry_coverage_cases += 1
                    metadata = get(registry_coverage, "metadata", Dict())
                    registry_coverage_rows += try
                        parse(Int, string(get(metadata,
                            "bmopf_constraint_registry_row_count", "0")))
                    catch
                        0
                    end
                    registry_coverage_registered_rows += try
                        parse(Int, string(get(metadata,
                            "bmopf_constraint_registry_registered_row_count", "0")))
                    catch
                        0
                    end
                    registry_coverage_unregistered_rows += try
                        parse(Int, string(get(metadata,
                            "bmopf_constraint_registry_unregistered_row_count", "0")))
                    catch
                        0
                    end
                    for (family, count) in _parse_count_map(get(metadata,
                        "bmopf_constraint_registry_registered_family_row_counts", ""))
                        registry_coverage_registered_families[family] =
                            get(registry_coverage_registered_families, family, 0) + count
                    end
                    summary["constraint_registry_coverage"] = registry_coverage
                end
                attribution = get(profile,
                    "bmopf_constraint_feasibility_field_attribution", nothing)
                if attribution isa AbstractDict
                    feasibility_attribution_cases += 1
                    metadata = get(attribution, "metadata", Dict())
                    feasibility_attribution_violation_rows += try
                        parse(Int, string(get(metadata,
                            "bmopf_feasibility_attribution_violation_count", "0")))
                    catch
                        0
                    end
                    feasibility_attribution_unsupported_rows += try
                        parse(Int, string(get(metadata,
                            "bmopf_feasibility_attribution_unsupported_row_count", "0")))
                    catch
                        0
                    end
                    for (family, count) in _parse_count_map(get(metadata,
                        "bmopf_feasibility_attribution_family_row_counts", ""))
                        feasibility_attribution_family_rows[family] =
                            get(feasibility_attribution_family_rows, family, 0) + count
                    end
                    for (method, count) in _parse_count_map(get(metadata,
                        "bmopf_feasibility_attribution_jacobian_method_counts", ""))
                        feasibility_attribution_jacobian_methods[method] =
                            get(feasibility_attribution_jacobian_methods, method, 0) + count
                    end
                    for (family, count) in _parse_count_map(get(metadata,
                        "bmopf_feasibility_attribution_constraint_family_row_counts", ""))
                        feasibility_attribution_constraint_families[family] =
                            get(feasibility_attribution_constraint_families, family, 0) + count
                    end
                    for (instance, count) in _parse_count_map(get(metadata,
                        "bmopf_feasibility_attribution_constraint_instance_counts", ""))
                        feasibility_attribution_constraint_instances[instance] =
                            get(feasibility_attribution_constraint_instances, instance, 0) + count
                    end
                    for (component, count) in _parse_count_map(get(metadata,
                        "bmopf_feasibility_attribution_component_candidate_counts", ""))
                        feasibility_attribution_components[component] =
                            get(feasibility_attribution_components, component, 0) + count
                    end
                    feasibility_attribution_registered_rows += try
                        parse(Int, string(get(metadata,
                            "bmopf_feasibility_attribution_registered_constraint_row_count", "0")))
                    catch
                        0
                    end
                    feasibility_attribution_unregistered_rows += try
                        parse(Int, string(get(metadata,
                            "bmopf_feasibility_attribution_unregistered_constraint_row_count", "0")))
                    catch
                        0
                    end
                    feasibility_attribution_model_rows += try
                        parse(Int, string(get(metadata,
                            "bmopf_feasibility_attribution_model_constraint_row_count", "0")))
                    catch
                        0
                    end
                    feasibility_attribution_model_registered_rows += try
                        parse(Int, string(get(metadata,
                            "bmopf_feasibility_attribution_model_registered_constraint_row_count", "0")))
                    catch
                        0
                    end
                    feasibility_attribution_model_unregistered_rows += try
                        parse(Int, string(get(metadata,
                            "bmopf_feasibility_attribution_model_unregistered_constraint_row_count", "0")))
                    catch
                        0
                    end
                    for (family, count) in _parse_count_map(get(metadata,
                        "bmopf_feasibility_attribution_model_constraint_family_row_counts", ""))
                        feasibility_attribution_model_constraint_families[family] =
                            get(feasibility_attribution_model_constraint_families, family, 0) + count
                    end
                    summary["feasibility_field_attribution"] = attribution
                end
                capability = get(profile, "bmopf_component_rank_capability", nothing)
                if capability isa AbstractDict
                    component_rank_capability_cases += 1
                    component_rank_capability_checked_cases +=
                        Bool(get(capability, "checked", false))
                    component_rank_capability_components +=
                        Int(get(capability, "component_count", 0))
                    component_rank_capability_declared +=
                        Int(get(capability, "expected_rank_declared_count", 0))
                    component_rank_capability_unavailable +=
                        Int(get(capability, "expected_rank_unavailable_count", 0))
                    component_rank_capability_findings +=
                        Int(get(capability, "finding_count", 0))
                    coverage = get(capability, "expected_rank_coverage", nothing)
                    coverage isa Number && isfinite(Float64(coverage)) &&
                        push!(component_rank_capability_coverages, Float64(coverage))
                    summary["component_rank_capability"] = capability
                end
                serialized_profile = get(record["profile"], "profile", nothing)
                if serialized_profile isa AbstractDict
                    _collect_numeric_metrics!(
                        aggregate_stage_seconds,
                        get(serialized_profile, "stage_seconds", nothing),
                    )
                    _collect_numeric_metrics!(
                        aggregate_stage_allocations,
                        get(serialized_profile, "stage_allocations", nothing),
                    )
                end
            end
            saved_mapping = profile isa AbstractDict ?
                            get(profile, "bmopf_saved_result_mapping_report", nothing) : nothing
            if !isnothing(saved_mapping)
                metadata = saved_mapping["metadata"]
                fallback = parse(Int, metadata["bmopf_saved_result_fallback_coordinate_count"])
                summary["saved_result_mapping"] = Dict(
                    "mapped_coordinate_count" => parse(Int, metadata["bmopf_saved_result_mapped_coordinate_count"]),
                    "fallback_coordinate_count" => fallback,
                    "registered_coordinate_count" => parse(Int, metadata["bmopf_saved_result_registered_coordinate_count"]),
                    "unregistered_model_coordinate_count" => parse(Int, metadata["bmopf_saved_result_unregistered_model_coordinate_count"]),
                    "unmapped_registered_coordinate_count" => parse(Int, metadata["bmopf_saved_result_unmapped_registered_coordinate_count"]),
                    "mapped_registered_coordinate_fraction" => parse(Float64, metadata["bmopf_saved_result_registered_coordinate_fraction"]),
                    "result_units" => metadata["bmopf_saved_result_units"],
                    "field_units" => get(metadata, "bmopf_saved_result_field_units", nothing),
                    "projected_saved_record_count" => _int(get(
                        metadata,
                        "bmopf_saved_result_projected_record_count",
                        0,
                    )),
                    "projected_families" => get(
                        metadata,
                        "bmopf_saved_result_projected_families",
                        "",
                    ),
                    "projection_contracts" => get(
                        metadata,
                        "bmopf_saved_result_projection_contracts",
                        "",
                    ),
                )
                fraction = parse(Float64, metadata[
                    "bmopf_saved_result_registered_coordinate_fraction",
                ])
                push!(saved_result_mapping_fractions, fraction)
                units = metadata["bmopf_saved_result_units"]
                saved_result_units[units] = get(saved_result_units, units, 0) + 1
                field_units = get(metadata, "bmopf_saved_result_field_units", nothing)
                !isnothing(field_units) && (saved_result_field_units[field_units] = get(saved_result_field_units, field_units, 0) + 1)
                mapping_codes = Set(String(finding["code"]) for finding in saved_mapping["findings"])
                if "bmopf_saved_result_unit_scale_suspicious" in mapping_codes
                    saved_result_unit_scale_warning_cases += 1
                end
                if any(
                    startswith(String(get(finding, "code", "")),
                               "bmopf_saved_result_") &&
                    String(get(finding, "severity", "")) in ("warning", "error")
                    for finding in saved_mapping["findings"]
                )
                    saved_result_mapping_warning_cases += 1
                end
                saved_result_cases += 1
                saved_result_fallback_coordinates += fallback
                saved_result_unregistered_model_coordinates += parse(Int, metadata["bmopf_saved_result_unregistered_model_coordinate_count"])
                saved_result_unmapped_registered_coordinates += parse(Int, metadata["bmopf_saved_result_unmapped_registered_coordinate_count"])
                projected_count = _int(get(
                    metadata,
                    "bmopf_saved_result_projected_record_count",
                    0,
                ))
                saved_result_projected_records += projected_count
                projected_family_string = String(get(
                    metadata,
                    "bmopf_saved_result_projected_families",
                    "",
                ))
                for family in filter(!isempty, split(projected_family_string, ','))
                    saved_result_projected_families[family] = get(
                        saved_result_projected_families, family, 0,
                    ) + 1
                end
                projection_contract = String(get(
                    metadata,
                    "bmopf_saved_result_projection_contracts",
                    "",
                ))
                isempty(projection_contract) ||
                    push!(saved_result_projection_contracts, projection_contract)
                for finding in saved_mapping["findings"]
                    finding["code"] == "bmopf_saved_result_unresolved_records" || continue
                    details = Dict(finding["evidence"][1]["details"])
                    counts = get(details, "counts_by_family", "")
                    for item in filter(!isempty, split(counts, ','))
                        parts = split(item, '='; limit = 2)
                        length(parts) == 2 || continue
                        family = String(strip(parts[1]))
                        count = parse(Int, strip(parts[2]))
                        saved_result_unresolved_records += count
                        saved_result_unresolved_families[family] =
                            get(saved_result_unresolved_families, family, 0) + count
                    end
                end
            end
            eligible = get(record, "dense_rank_analysis_eligible", nothing)
            if analysis_mode == "structural"
                dense_not_requested_cases += 1
            elseif eligible === true
                dense_eligible_cases += 1
            elseif eligible === false
                dense_skipped_cases += 1
            else
                dense_unknown_cases += 1
            end
        end
        push!(cases, summary)
    end
    root_key, root_value = _index_root(index)
    index_cases = get(index, "cases", Any[])
    first_case = isempty(index_cases) ? Dict{String,Any}() : first(index_cases)
    summary = Dict{String,Any}(
        root_key => root_value,
        "environment" => get(index, "environment", nothing),
        "environment_fingerprint" => get(index, "environment_fingerprint", nothing),
        "rank_max_dense_entries" => get(index, "rank_max_dense_entries", nothing),
        "runner_version" => get(index, "runner_version", nothing),
        "case_selection" => get(index, "case_selection", nothing),
        "analysis_mode" => get(index, "analysis_mode", get(first_case, "analysis_mode", nothing)),
        "point_policy" => get(index, "point_policy", get(first_case, "point_policy", nothing)),
        "result_units" => get(index, "result_units", nothing),
        "result_field_units" => get(index, "result_field_units", nothing),
        "include_floating_neutral_candidates" => get(index, "include_floating_neutral_candidates", nothing),
        "floating_neutral_candidate_counts" => Dict(
            "cases_with_candidates" => floating_neutral_candidate_cases,
            "candidate_mode_count" => floating_neutral_candidate_modes,
        ),
        "component_rank_capability_counts" => Dict(
            "profile_cases_with_capability_data" => component_rank_capability_cases,
            "checked_cases" => component_rank_capability_checked_cases,
            "component_count_total" => component_rank_capability_components,
            "expected_rank_declared_count_total" => component_rank_capability_declared,
            "expected_rank_unavailable_count_total" => component_rank_capability_unavailable,
            "capability_finding_count_total" => component_rank_capability_findings,
            "coverage_minimum" => isempty(component_rank_capability_coverages) ? nothing : minimum(component_rank_capability_coverages),
            "coverage_mean" => isempty(component_rank_capability_coverages) ? nothing : sum(component_rank_capability_coverages) / length(component_rank_capability_coverages),
            "coverage_maximum" => isempty(component_rank_capability_coverages) ? nothing : maximum(component_rank_capability_coverages),
        ),
        "result_field_catalog_case_count" => result_field_catalog_cases,
        "constraint_registry_coverage_counts" => Dict(
            "cases_with_coverage" => registry_coverage_cases,
            "constraint_row_count_total" => registry_coverage_rows,
            "registered_constraint_row_count_total" => registry_coverage_registered_rows,
            "unregistered_constraint_row_count_total" => registry_coverage_unregistered_rows,
            "registered_constraint_family_row_counts" =>
                _sorted_counts(registry_coverage_registered_families),
            "registered_constraint_fraction" => registry_coverage_rows == 0 ? nothing :
                registry_coverage_registered_rows / registry_coverage_rows,
        ),
        "feasibility_field_attribution_counts" => Dict(
            "cases_with_attribution" => feasibility_attribution_cases,
            "violation_row_count_total" => feasibility_attribution_violation_rows,
            "unsupported_row_count_total" => feasibility_attribution_unsupported_rows,
            "family_row_counts" => _sorted_counts(feasibility_attribution_family_rows),
            "jacobian_method_counts" => _sorted_counts(feasibility_attribution_jacobian_methods),
            "constraint_family_row_counts" => _sorted_counts(feasibility_attribution_constraint_families),
            "constraint_instance_counts" => _sorted_counts(feasibility_attribution_constraint_instances),
            "component_candidate_counts" => _sorted_counts(feasibility_attribution_components),
            "registered_constraint_row_count_total" => feasibility_attribution_registered_rows,
            "unregistered_constraint_row_count_total" => feasibility_attribution_unregistered_rows,
            "model_constraint_row_count_total" => feasibility_attribution_model_rows,
            "model_registered_constraint_row_count_total" => feasibility_attribution_model_registered_rows,
            "model_unregistered_constraint_row_count_total" => feasibility_attribution_model_unregistered_rows,
            "model_constraint_family_row_counts" => _sorted_counts(feasibility_attribution_model_constraint_families),
            "model_registered_constraint_fraction" => feasibility_attribution_model_rows == 0 ? nothing :
                feasibility_attribution_model_registered_rows / feasibility_attribution_model_rows,
        ),
        "multiconductor_contract_counts" => Dict(
            "cases_with_contract_data" => multiconductor_case_count,
            "cases_with_contract_findings" => multiconductor_finding_cases,
            "metric_summaries" => _metric_summaries(multiconductor_metric_values),
            "constitutive_map_rank_summary" => isempty(multiconductor_constitutive_ranks) ? nothing : Dict(
                "sample_count" => length(multiconductor_constitutive_ranks),
                "minimum" => minimum(multiconductor_constitutive_ranks),
                "mean" => sum(multiconductor_constitutive_ranks) / length(multiconductor_constitutive_ranks),
                "maximum" => maximum(multiconductor_constitutive_ranks),
            ),
            "complex_constitutive_map_rank_summary" => isempty(multiconductor_complex_constitutive_ranks) ? nothing : Dict(
                "sample_count" => length(multiconductor_complex_constitutive_ranks),
                "minimum" => minimum(multiconductor_complex_constitutive_ranks),
                "mean" => sum(multiconductor_complex_constitutive_ranks) / length(multiconductor_complex_constitutive_ranks),
                "maximum" => maximum(multiconductor_complex_constitutive_ranks),
            ),
            "passive_network_current_map_rank_summary" => isempty(multiconductor_passive_current_ranks) ? nothing : Dict(
                "sample_count" => length(multiconductor_passive_current_ranks),
                "minimum" => minimum(multiconductor_passive_current_ranks),
                "mean" => sum(multiconductor_passive_current_ranks) / length(multiconductor_passive_current_ranks),
                "maximum" => maximum(multiconductor_passive_current_ranks),
            ),
            "passive_network_current_model_map_rank_summary" => isempty(multiconductor_passive_current_model_ranks) ? nothing : Dict(
                "sample_count" => length(multiconductor_passive_current_model_ranks),
                "minimum" => minimum(multiconductor_passive_current_model_ranks),
                "mean" => sum(multiconductor_passive_current_model_ranks) / length(multiconductor_passive_current_model_ranks),
                "maximum" => maximum(multiconductor_passive_current_model_ranks),
            ),
            "physical_mode_category_case_counts" => _sorted_counts(multiconductor_physical_mode_categories),
            "current_law_family_case_counts" => _sorted_counts(multiconductor_current_law_families),
            "current_law_operating_point_status_case_counts" => _sorted_counts(multiconductor_current_law_operating_statuses),
            "controller_curve_family_case_counts" => _sorted_counts(multiconductor_controller_curve_families),
            "controller_curve_status_case_counts" => _sorted_counts(multiconductor_controller_curve_statuses),
            "controller_curve_voltage_semantics_case_counts" => _sorted_counts(multiconductor_controller_curve_semantics),
        ),
        "controller_curve_profile_counts" => Dict(
            "cases_with_profile_data" => controller_curve_profile_case_count,
            "observation_count_summary" => _metric_summaries(Dict(
                "observations_per_case" => controller_curve_profile_observation_counts,
            )),
            "family_case_counts" => _sorted_counts(controller_curve_profile_families),
            "status_case_counts" => _sorted_counts(controller_curve_profile_statuses),
            "monitor_semantics_case_counts" => _sorted_counts(controller_curve_profile_semantics),
        ),
        "resume" => get(index, "resume", false),
        "force" => get(index, "force", false),
        "profile_case_count" => profile_case_count,
        "trusted_point_selection_counts" => Dict(
            "profile_cases_with_selected_trusted_points" => trusted_point_selected_cases,
            "profile_cases_with_rejected_points" => trusted_point_rejected_cases,
            "profile_cases_with_incomplete_selection_metadata" => trusted_point_incomplete_cases,
            "profile_cases_missing_selection_metadata" => trusted_point_missing_case_records,
        ),
        "profile_stage_seconds" => _metric_summaries(aggregate_stage_seconds),
        "profile_stage_allocations" => _metric_summaries(aggregate_stage_allocations),
        "skipped_case_count" => skipped_cases,
        "error_case_count" => error_cases,
        "cases" => cases,
        "dense_rank_case_counts" => Dict(
            "eligible" => dense_eligible_cases,
            "skipped_by_size_policy" => dense_skipped_cases,
            "not_requested_structural" => dense_not_requested_cases,
            "unknown" => dense_unknown_cases,
        ),
        "saved_result_mapping_case_counts" => Dict(
            "saved_result_cases" => saved_result_cases,
            "fallback_coordinate_count" => saved_result_fallback_coordinates,
            "unresolved_saved_record_count" => saved_result_unresolved_records,
            "unresolved_record_family_counts" => _sorted_counts(saved_result_unresolved_families),
            "projected_saved_record_count" => saved_result_projected_records,
            "projected_family_case_counts" => _sorted_counts(saved_result_projected_families),
            "projection_contracts" => sort!(collect(saved_result_projection_contracts)),
            "unregistered_model_coordinate_count" => saved_result_unregistered_model_coordinates,
            "unmapped_registered_coordinate_count" => saved_result_unmapped_registered_coordinates,
            "mapping_fraction_minimum" => isempty(saved_result_mapping_fractions) ? nothing : minimum(saved_result_mapping_fractions),
            "mapping_fraction_mean" => isempty(saved_result_mapping_fractions) ? nothing : sum(saved_result_mapping_fractions) / length(saved_result_mapping_fractions),
            "mapping_fraction_maximum" => isempty(saved_result_mapping_fractions) ? nothing : maximum(saved_result_mapping_fractions),
            "result_units_case_counts" => _sorted_counts(saved_result_units),
            "result_field_units_policy_case_counts" => _sorted_counts(saved_result_field_units),
            "unit_scale_warning_case_count" => saved_result_unit_scale_warning_cases,
            "mapping_warning_case_count" => saved_result_mapping_warning_cases,
        ),
        "aggregate_generic_finding_codes" => _sorted_counts(aggregate_generic),
        "aggregate_context_finding_codes" => _sorted_counts(aggregate_context),
        "aggregate_initialization_finding_codes" => _sorted_counts(aggregate_initialization),
        "aggregate_generic_finding_attributes" => Dict(
            field => _sorted_counts(counts) for (field, counts) in sort!(collect(aggregate_generic_attributes); by = first)
        ),
        "aggregate_context_finding_attributes" => Dict(
            field => _sorted_counts(counts) for (field, counts) in sort!(collect(aggregate_context_attributes); by = first)
        ),
        "aggregate_initialization_finding_attributes" => Dict(
            field => _sorted_counts(counts) for (field, counts) in sort!(collect(aggregate_initialization_attributes); by = first)
        ),
        "integrity_preflight_case_counts" => Dict(
            "cases_with_errors" => integrity_error_cases,
            "cases_with_warnings" => integrity_warning_cases,
            "cases_with_findings" => integrity_finding_cases,
            "source_schema_warning_count" => source_schema_warning_count,
        ),
        "aggregate_integrity_finding_codes" => _sorted_counts(aggregate_integrity),
    )
    summary_path = joinpath(output_dir, "summary.json")
    write_json(summary_path, summary)
    for case in cases
        name = case["name"]
        status = case["status"]
        policy = get(case, "point_policy", "")
        println("$name: $status", isempty(policy) ? "" : " point=$policy")
    end
    println("wrote $summary_path")
end

main()
