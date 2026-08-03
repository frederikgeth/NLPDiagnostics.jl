#!/usr/bin/env julia

# Summarize JSON records emitted by bmopf_smoke.jl or bmopf_draft_corpus.jl:
#
# julia --project=. benchmarks/summarize_bmopf_smoke.jl /path/to/bmopf-smoke-results

using JSON

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
    index = JSON.parsefile(index_path)
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
    integrity_finding_cases = 0
    dense_eligible_cases = 0
    dense_skipped_cases = 0
    dense_not_requested_cases = 0
    dense_unknown_cases = 0
    saved_result_cases = 0
    saved_result_fallback_coordinates = 0
    saved_result_unresolved_records = 0
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
    floating_neutral_candidate_cases = 0
    floating_neutral_candidate_modes = 0
    aggregate_stage_seconds = Dict{String,Vector{Float64}}()
    aggregate_stage_allocations = Dict{String,Vector{Float64}}()
    for entry in index["cases"]
        record_path = joinpath(output_dir, entry["result_file"])
        record = JSON.parsefile(record_path)
        summary = Dict{String,Any}(entry)
        preflight = get(record, "integrity_preflight", nothing)
        if preflight isa AbstractDict
            errors = Int(get(preflight, "error_count", 0))
            warnings = Int(get(preflight, "warning_count", 0))
            integrity_error_cases += errors > 0
            integrity_warning_cases += warnings > 0
            integrity_finding_cases += Int(get(preflight, "finding_count", 0)) > 0
            summary["integrity_preflight"] = Dict(
                "error_count" => errors,
                "warning_count" => warnings,
                "finding_count" => Int(get(preflight, "finding_count", 0)),
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
                if any(startswith(code, "bmopf_saved_result_") for code in mapping_codes if
                       code != "bmopf_saved_result_mapping_coverage")
                    saved_result_mapping_warning_cases += 1
                end
                saved_result_cases += 1
                saved_result_fallback_coordinates += fallback
                saved_result_unregistered_model_coordinates += parse(Int, metadata["bmopf_saved_result_unregistered_model_coordinate_count"])
                saved_result_unmapped_registered_coordinates += parse(Int, metadata["bmopf_saved_result_unmapped_registered_coordinate_count"])
                for finding in saved_mapping["findings"]
                    finding["code"] == "bmopf_saved_result_unresolved_records" || continue
                    details = Dict(finding["evidence"][1]["details"])
                    counts = get(details, "counts_by_family", "")
                    for item in filter(!isempty, split(counts, ','))
                        saved_result_unresolved_records += parse(Int, split(item, '='; limit = 2)[2])
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
        "resume" => get(index, "resume", false),
        "force" => get(index, "force", false),
        "profile_case_count" => profile_case_count,
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
        ),
        "aggregate_integrity_finding_codes" => _sorted_counts(aggregate_integrity),
    )
    summary_path = joinpath(output_dir, "summary.json")
    write(summary_path, JSON.json(summary))
    for case in cases
        name = case["name"]
        status = case["status"]
        policy = get(case, "point_policy", "")
        println("$name: $status", isempty(policy) ? "" : " point=$policy")
    end
    println("wrote $summary_path")
end

main()
