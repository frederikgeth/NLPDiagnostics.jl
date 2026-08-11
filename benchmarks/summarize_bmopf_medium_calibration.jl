#!/usr/bin/env julia

"""Summarize isolated medium BMOPF saved-result profiles.

The input is a directory produced by `launch_bmopf_point_calibration.jl`.
Unlike the broad smoke summary, this artifact keeps the gates needed before a
medium-model numerical observation may be promoted: point coverage, saved
result projection, derivative provenance and crosscheck, sparse-QR resources,
scaling policy, and BMOPFTools differentiability qualifications.
"""

using JSON

_dict(value) = value isa AbstractDict ?
    Dict{String,Any}(string(key) => item for (key, item) in value) :
    Dict{String,Any}()

function _number(value)
    value isa Number && return Float64(value)
    value isa AbstractString || return nothing
    return tryparse(Float64, value)
end

function _integer(value)
    number = _number(value)
    isnothing(number) && return nothing
    return Int(round(number))
end

function _boolean(value)
    value isa Bool && return value
    value isa AbstractString || return nothing
    lowered = lowercase(value)
    lowered == "true" && return true
    lowered == "false" && return false
    return nothing
end

function _finding_detail(report, code, key)
    report isa AbstractDict || return nothing
    for finding in get(report, "findings", Any[])
        String(get(finding, "code", "")) == code || continue
        for evidence in get(finding, "evidence", Any[])
            details = _dict(get(evidence, "details", Dict()))
            haskey(details, key) && return details[key]
        end
    end
    return nothing
end

function _has_finding(report, code)
    report isa AbstractDict || return false
    return any(
        finding -> String(get(finding, "code", "")) == code,
        get(report, "findings", Any[]),
    )
end

function _case_record(run, child_case)
    output_directory = String(get(run, "output_directory", ""))
    result_file = String(get(child_case, "result_file", ""))
    if isempty(output_directory) || isempty(result_file)
        return Dict{String,Any}()
    end
    path = joinpath(output_directory, result_file)
    isfile(path) || return Dict{String,Any}()
    return _dict(JSON.parsefile(path))
end

function _case_row(run, child_case, record)
    profile = _dict(get(record, "profile", Dict()))
    serialized_profile = _dict(get(profile, "profile", Dict()))
    reports = _dict(get(serialized_profile, "reports", Dict()))
    numerical_report = _dict(get(reports, "numerical", Dict()))
    numerical = _dict(get(numerical_report, "metadata", Dict()))
    context = _dict(get(profile, "bmopf_context_report", Dict()))
    context_metadata = _dict(get(context, "metadata", Dict()))
    mapping = _dict(get(profile, "bmopf_saved_result_mapping_report", Dict()))
    mapping_metadata = _dict(get(mapping, "metadata", Dict()))
    snapshot = String(get(record, "snapshot", get(child_case, "snapshot", "")))
    formulation = occursin("/99bus_LG/", snapshot) ? "LG" :
                  occursin("/99bus_LN/", snapshot) ? "LN" : "unknown"
    time_match = match(r"_t(\d+)_", snapshot)
    time_index = isnothing(time_match) ? nothing : parse(Int, only(time_match.captures))
    method_counts = String(get(
        numerical, "jacobian_derivative_row_method_counts", "",
    ))
    fd_count = 0
    for token in split(method_counts, ',')
        parts = split(token, '='; limit = 2)
        length(parts) == 2 || continue
        occursin("finite_difference", parts[1]) || continue
        parsed = tryparse(Int, parts[2])
        isnothing(parsed) || (fd_count += parsed)
    end
    projected = _integer(get(
        mapping_metadata, "bmopf_saved_result_projected_record_count", 0,
    ))
    qualifications = String(get(
        context_metadata, "bmopf_opf_differentiability_qualifications", "",
    ))
    row = Dict{String,Any}(
        "snapshot" => snapshot,
        "formulation" => formulation,
        "time_index" => time_index,
        "status" => get(child_case, "status", get(run, "status", "unknown")),
        "model_variable_count" => get(record, "model_variable_count", nothing),
        "constraint_row_count" => get(record, "scalar_constraint_row_count", nothing),
        "jacobian_dense_entry_count" => get(record, "jacobian_dense_entry_count", nothing),
        "finite_difference_row_count" => fd_count,
        "jacobian_row_method_counts" => method_counts,
        "crosscheck_selected_row_count" => _integer(get(numerical, "selected_row_count", 0)),
        "crosscheck_comparison_count" => _integer(get(numerical, "constraint_directional_comparisons", 0)),
        "crosscheck_mismatch_count" => _integer(get(numerical, "mismatch_count", 0)),
        "crosscheck_domain_limited_count" => _integer(get(numerical, "domain_limited_count", 0)),
        "crosscheck_direction_policy" => get(numerical, "direction_policy", nothing),
        "sparse_qr_rank_available" => _boolean(get(numerical, "sparse_qr_rank_available", nothing)),
        "sparse_qr_rank" => _integer(get(numerical, "sparse_qr_rank", nothing)),
        "scaled_sparse_qr_rank_available" => _boolean(get(numerical, "scaled_sparse_qr_rank_available", nothing)),
        "scaled_sparse_qr_rank" => _integer(get(numerical, "sparse_qr_row_column_rank", nothing)),
        "sparse_qr_condition_proxy" => _number(get(numerical, "sparse_qr_condition_proxy", nothing)),
        "scaled_sparse_qr_condition_proxy" => _number(get(numerical, "scaled_sparse_qr_condition_proxy", nothing)),
        "sparse_qr_fill_ratio" => _number(get(numerical, "sparse_qr_fill_ratio", nothing)),
        "scaled_sparse_qr_fill_ratio" => _number(get(numerical, "scaled_sparse_qr_fill_ratio", nothing)),
        "jacobian_row_scale_ratio" => _number(_finding_detail(
            numerical_report, "large_jacobian_row_scale_spread", "ratio",
        )),
        "jacobian_row_scale_spread_flagged" => _has_finding(
            numerical_report, "large_jacobian_row_scale_spread",
        ),
        "mapped_coordinate_count" => _integer(get(mapping_metadata, "bmopf_saved_result_mapped_coordinate_count", nothing)),
        "fallback_coordinate_count" => _integer(get(mapping_metadata, "bmopf_saved_result_fallback_coordinate_count", nothing)),
        "projected_saved_record_count" => projected,
        "projection_contracts" => get(mapping_metadata, "bmopf_saved_result_projection_contracts", ""),
        "unresolved_saved_families" => get(mapping_metadata, "bmopf_saved_result_unresolved_families", ""),
        "differentiability_ready" => _boolean(get(context_metadata, "bmopf_opf_differentiability_ready", nothing)),
        "differentiability_qualification_count" => _integer(get(context_metadata, "bmopf_opf_differentiability_qualification_count", 0)),
        "differentiability_qualifications" => isempty(qualifications) ? String[] : split(qualifications, " || "),
        "elapsed_seconds" => get(run, "elapsed_seconds", nothing),
        "maximum_observed_rss_kib" => get(run, "maximum_observed_rss_kib", nothing),
        "rss_monitor_available" => get(run, "rss_monitor_available", nothing),
    )
    variable_count = _integer(row["model_variable_count"])
    row["rank_gate_passed"] = !isnothing(variable_count) &&
        row["sparse_qr_rank_available"] === true &&
        row["scaled_sparse_qr_rank_available"] === true &&
        row["sparse_qr_rank"] == variable_count &&
        row["scaled_sparse_qr_rank"] == variable_count
    row["derivative_gate_passed"] = fd_count == 0 || (
        row["crosscheck_selected_row_count"] == fd_count &&
        row["crosscheck_comparison_count"] isa Integer &&
        row["crosscheck_comparison_count"] > 0 &&
        row["crosscheck_mismatch_count"] == 0 &&
        row["crosscheck_domain_limited_count"] == 0
    )
    row["point_gate_passed"] = row["fallback_coordinate_count"] == 0 &&
        isempty(String(row["unresolved_saved_families"]))
    row["numerical_interpretation_gate_passed"] =
        row["status"] == "ok" && row["rank_gate_passed"] &&
        row["derivative_gate_passed"] && row["point_gate_passed"]
    return row
end

function _range(rows, key)
    values = Float64[]
    for row in rows
        value = get(row, key, nothing)
        value isa Number && isfinite(Float64(value)) && push!(values, Float64(value))
    end
    return isempty(values) ? nothing : Dict(
        "minimum" => minimum(values), "maximum" => maximum(values),
    )
end

function main()
    length(ARGS) in (1, 2) || error(
        "usage: summarize_bmopf_medium_calibration.jl <calibration-dir> [output.json]",
    )
    root = abspath(ARGS[1])
    index_path = joinpath(root, "calibration_index.json")
    isfile(index_path) || error("calibration index is missing: $index_path")
    output_path = length(ARGS) == 2 ? abspath(ARGS[2]) :
                  joinpath(root, "medium_profile_summary.json")
    index = _dict(JSON.parsefile(index_path))
    rows = Dict{String,Any}[]
    for raw_run in get(index, "runs", Any[])
        run = _dict(raw_run)
        output_directory = String(get(run, "output_directory", ""))
        child_index_path = joinpath(output_directory, "index.json")
        isfile(child_index_path) || continue
        child_index = _dict(JSON.parsefile(child_index_path))
        for raw_case in get(child_index, "cases", Any[])
            child_case = _dict(raw_case)
            record = _case_record(run, child_case)
            isempty(record) && continue
            push!(rows, _case_row(run, child_case, record))
        end
    end
    formulation_summary = Dict{String,Any}()
    for formulation in sort!(unique(String(row["formulation"]) for row in rows))
        selected = filter(row -> row["formulation"] == formulation, rows)
        formulation_summary[formulation] = Dict(
            "case_count" => length(selected),
            "interpretation_gate_pass_count" => count(
                row -> row["numerical_interpretation_gate_passed"], selected,
            ),
            "condition_proxy_range" => _range(selected, "sparse_qr_condition_proxy"),
            "scaled_condition_proxy_range" => _range(selected, "scaled_sparse_qr_condition_proxy"),
            "row_scale_ratio_range" => _range(selected, "jacobian_row_scale_ratio"),
            "fill_ratio_range" => _range(selected, "sparse_qr_fill_ratio"),
        )
    end
    payload = Dict{String,Any}(
        "summary_version" => "bmopf-medium-profile-summary-v1",
        "calibration_index" => index_path,
        "runner_version" => get(index, "runner_version", nothing),
        "rss_limit_enabled" => get(index, "rss_limit_enabled", false),
        "max_rss_kib_budget" => get(index, "max_rss_kib_budget", nothing),
        "case_count" => length(rows),
        "interpretation_gate_pass_count" => count(
            row -> row["numerical_interpretation_gate_passed"], rows,
        ),
        "process_timeout_count" => count(
            run -> get(run, "process_timeout", false) === true,
            get(index, "runs", Any[]),
        ),
        "process_memory_limit_count" => count(
            run -> get(run, "process_memory_limit_exceeded", false) === true,
            get(index, "runs", Any[]),
        ),
        "formulations" => formulation_summary,
        "cases" => rows,
        "interpretation" => "Passing gates support local, point-specific numerical comparisons across the retained scaling policies. They do not establish global optimality, physical-mode identity, LICQ, second-order sufficiency, or solver-independent difficulty.",
    )
    write(output_path, JSON.json(payload))
    println("wrote medium BMOPF calibration summary to $output_path")
end

main()
