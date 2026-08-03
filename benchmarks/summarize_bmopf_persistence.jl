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
    jacobian_codes = _count_codes(jacobian)
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
        "jacobian" => _report_view(report, "jacobian_rank_persistence"),
        "component" => _report_view(report, "component_rank_persistence"),
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
