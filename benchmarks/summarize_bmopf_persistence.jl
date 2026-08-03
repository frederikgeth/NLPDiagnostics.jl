#!/usr/bin/env julia

"""Summarize one or more `bmopf_saved_result_persistence.jl` reports.

The output keeps availability separate from observed persistence. A report with
no dense rank budget contributes an availability fingerprint, not a claim that
rank changed.

Usage:

    julia benchmarks/summarize_bmopf_persistence.jl output.json report1.json report2.json ...
"""

using JSON

function _load(path)
    isfile(path) || error("persistence report is missing: $path")
    value = JSON.parsefile(path)
    value isa AbstractDict || error("persistence report is not a JSON object: $path")
    return value
end

function _count_codes(report)
    counts = Dict{String,Int}()
    findings = get(report, "findings", Any[])
    findings isa AbstractVector || return counts
    for finding in findings
        finding isa AbstractDict || continue
        code = get(finding, "code", nothing)
        code isa AbstractString || continue
        counts[String(code)] = get(counts, String(code), 0) + 1
    end
    return Dict(code => counts[code] for code in sort!(collect(keys(counts))))
end

function _metadata(report)
    metadata = get(report, "metadata", Dict())
    return metadata isa AbstractDict ? metadata : Dict()
end

function _int(value)
    value isa Integer && return Int(value)
    value isa AbstractString || return nothing
    try parse(Int, value) catch; nothing end
end

function _mapping_summary(report)
    records = get(report, "mapping", Any[])
    mapped = 0
    fallback = 0
    fractions = Float64[]
    for record in records
        record isa AbstractDict || continue
        mapped += Int(get(record, "mapped_coordinate_count", 0))
        fallback += Int(get(record, "fallback_coordinate_count", 0))
        mapping_report = get(record, "mapping_report", Dict())
        metadata = _metadata(mapping_report)
        raw = get(metadata, "bmopf_saved_result_registered_coordinate_fraction", nothing)
        value = try parse(Float64, raw) catch; nothing end
        value isa Real && isfinite(value) && push!(fractions, value)
    end
    return Dict(
        "point_count" => length(records),
        "mapped_coordinate_count_total" => mapped,
        "fallback_coordinate_count_total" => fallback,
        "registered_coordinate_fraction_minimum" => isempty(fractions) ? nothing : minimum(fractions),
        "registered_coordinate_fraction_mean" => isempty(fractions) ? nothing : sum(fractions) / length(fractions),
        "registered_coordinate_fraction_maximum" => isempty(fractions) ? nothing : maximum(fractions),
    )
end

function _active_set_summary(report)
    records = get(report, "active_set_reports", Any[])
    records isa AbstractVector || return Dict("point_count" => 0)
    code_counts = Dict{String,Int}()
    active_rows = Int[]
    row_sets = Set{Int}[]
    for record in records
        record isa AbstractDict || continue
        nested = get(record, "report", Dict())
        metadata = _metadata(nested)
        raw_rows = get(metadata, "active_row_count", nothing)
        value = _int(raw_rows)
        value isa Int && push!(active_rows, value)
        raw_set = get(metadata, "active_rows", "")
        parsed_set = Set{Int}()
        if raw_set isa AbstractString
            for token in filter(!isempty, split(raw_set, ','))
                parsed = _int(strip(token))
                parsed isa Int && push!(parsed_set, parsed)
            end
        end
        push!(row_sets, parsed_set)
        for (code, count) in _count_codes(nested)
            code_counts[code] = get(code_counts, code, 0) + count
        end
    end
    common_rows = isempty(row_sets) ? Set{Int}() : foldl(intersect, row_sets)
    union_rows = isempty(row_sets) ? Set{Int}() : foldl(union, row_sets)
    transition_count = sum(
        row_sets[index] != row_sets[index - 1] for index in 2:length(row_sets)
    )
    return Dict(
        "point_count" => length(records),
        "active_row_count_minimum" => isempty(active_rows) ? nothing : minimum(active_rows),
        "active_row_count_mean" => isempty(active_rows) ? nothing : sum(active_rows) / length(active_rows),
        "active_row_count_maximum" => isempty(active_rows) ? nothing : maximum(active_rows),
        "active_row_intersection_count" => length(common_rows),
        "active_row_union_count" => length(union_rows),
        "active_row_transition_count" => transition_count,
        "finding_code_counts" => Dict(code => code_counts[code] for code in sort!(collect(keys(code_counts)))),
    )
end

function _report_view(report, key)
    value = get(report, key, Dict())
    value isa AbstractDict || return Dict{String,Any}()
    metadata = _metadata(value)
    return Dict{String,Any}(
        "metadata" => Dict(string(k) => v for (k, v) in metadata),
        "finding_code_counts" => _count_codes(value),
    )
end

function _persistence_view(path)
    report = _load(path)
    jacobian = get(report, "jacobian_rank_persistence", Dict())
    component = get(report, "component_rank_persistence", Dict())
    component_capability = get(report, "component_rank_capability", Dict())
    jacobian_codes = _count_codes(jacobian)
    capability_codes = _count_codes(component_capability)
    return Dict{String,Any}(
        "report_path" => path,
        "benchmark_root" => get(report, "benchmark_root", nothing),
        "snapshot_count" => length(get(report, "snapshots", Any[])),
        "snapshots" => get(report, "snapshots", Any[]),
        "result_units" => get(report, "result_units", nothing),
        "result_field_units" => get(report, "result_field_units", nothing),
        "dense_rank_max_entries" => get(report, "dense_rank_max_entries", nothing),
        "model_variable_count" => get(report, "model_variable_count", nothing),
        "mapping" => _mapping_summary(report),
        "active_set" => _active_set_summary(report),
        "jacobian" => _report_view(report, "jacobian_rank_persistence"),
        "component" => _report_view(report, "component_rank_persistence"),
        "component_rank_capability" => _report_view(report, "component_rank_capability"),
        "component_rank_capability_finding_code_counts" => capability_codes,
        "observed_fingerprints" => Dict(
            "rank_persistent" => get(jacobian_codes, "jacobian_rank_persistent", 0),
            "rank_changing" => get(jacobian_codes, "jacobian_rank_changing", 0),
            "rank_unavailable" => get(jacobian_codes, "jacobian_rank_persistence_unavailable", 0),
            "right_nullspace_persistent" => get(jacobian_codes, "jacobian_right_nullspace_persistent", 0),
            "right_nullspace_not_persistent" => get(jacobian_codes, "jacobian_right_nullspace_not_persistent", 0),
            "left_nullspace_persistent" => get(jacobian_codes, "jacobian_left_nullspace_persistent", 0),
            "left_nullspace_not_persistent" => get(jacobian_codes, "jacobian_left_nullspace_not_persistent", 0),
            "scaling_changing" => get(jacobian_codes, "jacobian_scaling_changing", 0),
        ),
    )
end

function main()
    length(ARGS) >= 2 || error("usage: summarize_bmopf_persistence.jl output.json report1.json report2.json ...")
    output_path = abspath(first(ARGS))
    reports = [_persistence_view(abspath(path)) for path in ARGS[2:end]]
    write(output_path, JSON.json(Dict(
        "report_version" => "bmopf-persistence-summary-v1",
        "report_count" => length(reports),
        "reports" => reports,
        "interpretation" => "Availability, persistence, nullspace alignment, and scaling observations remain separately attributable; unavailable rank is not rank change.",
    )))
    println("wrote BMOPF persistence summary to $output_path")
end

main()
