#!/usr/bin/env julia

"""Compare paired BMOPF saved-result profile campaigns.

The two directories should contain records produced by
`bmopf_draft_corpus.jl` over the same snapshots, typically an SI campaign and
a PU campaign (possibly with an explicit field-level policy). This tool keeps
the comparison evidence-oriented: it reports finding-code deltas, mapping
coverage, unit fingerprints, feasibility violations, and scale warnings. It
does not collapse these observations into a score or claim that one campaign
is physically correct.

Usage:

    julia benchmarks/compare_bmopf_saved_result_profiles.jl \
        /path/to/si-results /path/to/pu-results [output.json]

Set `NLPDIAGNOSTICS_BMOPF_UNIT_RATIO_REPORT` to the output of
`compare_bmopf_saved_result_units.jl` to retain the field-ratio evidence that
motivated the policy comparison.
"""

using JSON
using Statistics

const _EXCLUDED = Set(("summary.json", "index.json", "campaign_manifest.json"))
const _SCALE_CODES = Set((
    "large_jacobian_row_scale_spread",
    "large_jacobian_column_scale_spread",
    "component_port_nominal_scale_mismatch",
    "component_coordinate_scale_mismatch",
    "bmopf_saved_result_unit_scale_suspicious",
))

function _load(path)
    isfile(path) || error("JSON record is missing: $path")
    value = JSON.parsefile(path)
    value isa AbstractDict || error("JSON record is not an object: $path")
    return value
end

function _record_paths(directory)
    isdir(directory) || error("campaign directory does not exist: $directory")
    paths = Dict{String,String}()
    for entry in readdir(directory)
        entry in _EXCLUDED || endswith(entry, ".json") || continue
        path = joinpath(directory, entry)
        isfile(path) || continue
        record = try _load(path) catch; nothing end
        record isa AbstractDict || continue
        get(record, "status", "ok") == "error" && continue
        snapshot = get(record, "snapshot", nothing)
        snapshot isa AbstractString || continue
        paths[String(snapshot)] = path
    end
    return paths
end

function _finding_code_counts(findings)
    counts = Dict{String,Int}()
    findings isa AbstractVector || return counts
    for finding in findings
        finding isa AbstractDict || continue
        code = get(finding, "code", nothing)
        code isa AbstractString || continue
        counts[String(code)] = get(counts, String(code), 0) + 1
    end
    return counts
end

function _append_report_findings!(destination, report)
    report isa AbstractDict || return destination
    append!(destination, get(report, "findings", Any[]))
    return destination
end

function _profile_evidence(record)
    profile = get(record, "profile", nothing)
    profile isa AbstractDict || return Dict(
        "generic" => Any[], "context" => Any[], "initialization" => Any[],
        "mapping" => Any[], "all" => Any[],
    )
    generic = Any[]
    context = Any[]
    initialization = Any[]
    mapping = Any[]
    generic_profile = get(get(profile, "profile", Dict()), "reports", Dict())
    generic_profile isa AbstractDict || (generic_profile = Dict())
    for report in values(generic_profile)
        _append_report_findings!(generic, report)
    end
    _append_report_findings!(context, get(profile, "bmopf_context_report", nothing))
    _append_report_findings!(initialization, get(profile, "bmopf_initialization_report", nothing))
    _append_report_findings!(mapping, get(profile, "bmopf_saved_result_mapping_report", nothing))
    all = vcat(generic, context, initialization, mapping)
    return Dict(
        "generic" => generic,
        "context" => context,
        "initialization" => initialization,
        "mapping" => mapping,
        "all" => all,
    )
end

function _metadata(record, report_key)
    profile = get(record, "profile", Dict())
    report = get(profile, report_key, Dict())
    metadata = get(report, "metadata", Dict())
    return metadata isa AbstractDict ? metadata : Dict()
end

function _int_or_nothing(value)
    value isa Integer && return Int(value)
    value isa AbstractString || return nothing
    try parse(Int, value) catch; nothing end
end

function _float_or_nothing(value)
    value isa Number && isfinite(Float64(value)) && return Float64(value)
    value isa AbstractString || return nothing
    try
        parsed = parse(Float64, value)
        isfinite(parsed) ? parsed : nothing
    catch
        nothing
    end
end

function _policy_metadata(record)
    mapping = _metadata(record, "bmopf_saved_result_mapping_report")
    context = _metadata(record, "bmopf_context_report")
    return Dict(
        "result_units" => get(mapping, "bmopf_saved_result_units",
                              get(context, "bmopf_saved_result_units", nothing)),
        "field_units" => get(mapping, "bmopf_saved_result_field_units",
                              get(context, "bmopf_saved_result_field_units", nothing)),
        "unit_fingerprint_median_coordinate_magnitude" => _float_or_nothing(
            get(mapping, "bmopf_saved_result_unit_fingerprint_median_coordinate_magnitude", nothing),
        ),
        "mapped_registered_coordinate_fraction" => _float_or_nothing(
            get(mapping, "bmopf_saved_result_registered_coordinate_fraction", nothing),
        ),
        "mapped_coordinate_count" => _int_or_nothing(
            get(mapping, "bmopf_saved_result_mapped_coordinate_count", nothing),
        ),
        "fallback_coordinate_count" => _int_or_nothing(
            get(mapping, "bmopf_saved_result_fallback_coordinate_count", nothing),
        ),
    )
end

function _finding_summary(record)
    evidence = _profile_evidence(record)
    by_domain = Dict{String,Any}()
    for domain in ("generic", "context", "initialization", "mapping")
        counts = _finding_code_counts(evidence[domain])
        by_domain[domain] = Dict(code => counts[code] for code in sort!(collect(keys(counts))))
    end
    all_counts = _finding_code_counts(evidence["all"])
    feasibility = get(all_counts, "constraint_feasibility_violation", 0)
    scale_counts = Dict(code => get(all_counts, code, 0) for code in sort!(collect(_SCALE_CODES)))
    return Dict(
        "finding_code_counts_by_domain" => by_domain,
        "finding_code_counts" => Dict(code => all_counts[code] for code in sort!(collect(keys(all_counts)))),
        "constraint_feasibility_violation_count" => feasibility,
        "scale_finding_counts" => scale_counts,
        "total_finding_count" => length(evidence["all"]),
    )
end

function _delta_map(left, right)
    keys_union = union(keys(left), keys(right))
    return Dict(String(key) => Int(get(right, key, 0)) - Int(get(left, key, 0))
                for key in sort!(collect(keys_union); by = String)
                if get(left, key, 0) != get(right, key, 0))
end

function _case_comparison(snapshot, left, right)
    left_summary = _finding_summary(left)
    right_summary = _finding_summary(right)
    left_policy = _policy_metadata(left)
    right_policy = _policy_metadata(right)
    left_codes = left_summary["finding_code_counts"]
    right_codes = right_summary["finding_code_counts"]
    return Dict(
        "snapshot" => snapshot,
        "left_campaign_fingerprint" => get(left, "campaign_fingerprint", nothing),
        "right_campaign_fingerprint" => get(right, "campaign_fingerprint", nothing),
        "left_policy" => left_policy,
        "right_policy" => right_policy,
        "left_summary" => left_summary,
        "right_summary" => right_summary,
        "finding_count_delta_right_minus_left" => right_summary["total_finding_count"] - left_summary["total_finding_count"],
        "feasibility_violation_delta_right_minus_left" => right_summary["constraint_feasibility_violation_count"] - left_summary["constraint_feasibility_violation_count"],
        "scale_finding_delta_right_minus_left" => _delta_map(left_summary["scale_finding_counts"], right_summary["scale_finding_counts"]),
        "finding_code_delta_right_minus_left" => _delta_map(left_codes, right_codes),
    )
end

function _aggregate_cases(cases)
    total = Dict{String,Int}()
    for case in cases
        for (code, delta) in case["finding_code_delta_right_minus_left"]
            total[code] = get(total, code, 0) + Int(delta)
        end
    end
    return Dict(code => total[code] for code in sort!(collect(keys(total))))
end

function main()
    length(ARGS) in (2, 3) || error(
        "usage: compare_bmopf_saved_result_profiles.jl left-campaign right-campaign [output.json]",
    )
    left_dir = abspath(ARGS[1])
    right_dir = abspath(ARGS[2])
    output_path = length(ARGS) == 3 ? abspath(ARGS[3]) :
        joinpath(pwd(), "bmopf-saved-result-profile-comparison.json")
    left_paths = _record_paths(left_dir)
    right_paths = _record_paths(right_dir)
    snapshots = sort!(collect(intersect(keys(left_paths), keys(right_paths))))
    missing_left = sort!(collect(setdiff(keys(right_paths), keys(left_paths))))
    missing_right = sort!(collect(setdiff(keys(left_paths), keys(right_paths))))
    comparisons = Any[]
    errors = Any[]
    for snapshot in snapshots
        left = try _load(left_paths[snapshot]) catch error
            push!(errors, Dict("snapshot" => snapshot, "side" => "left", "error" => sprint(showerror, error)))
            continue
        end
        right = try _load(right_paths[snapshot]) catch error
            push!(errors, Dict("snapshot" => snapshot, "side" => "right", "error" => sprint(showerror, error)))
            continue
        end
        push!(comparisons, _case_comparison(snapshot, left, right))
    end
    left_index = isfile(joinpath(left_dir, "index.json")) ? _load(joinpath(left_dir, "index.json")) : Dict()
    right_index = isfile(joinpath(right_dir, "index.json")) ? _load(joinpath(right_dir, "index.json")) : Dict()
    ratio_path = get(ENV, "NLPDIAGNOSTICS_BMOPF_UNIT_RATIO_REPORT", "")
    ratio_report = isempty(ratio_path) ? nothing : _load(abspath(ratio_path))
    report = Dict(
        "report_version" => "bmopf-saved-result-profile-comparison-v1",
        "left_campaign" => Dict("directory" => left_dir, "runner_version" => get(left_index, "runner_version", nothing), "result_units" => get(left_index, "result_units", nothing), "result_field_units" => get(left_index, "result_field_units", nothing)),
        "right_campaign" => Dict("directory" => right_dir, "runner_version" => get(right_index, "runner_version", nothing), "result_units" => get(right_index, "result_units", nothing), "result_field_units" => get(right_index, "result_field_units", nothing)),
        "paired_case_count" => length(comparisons),
        "missing_left_case_count" => length(missing_left),
        "missing_right_case_count" => length(missing_right),
        "missing_left_cases" => missing_left,
        "missing_right_cases" => missing_right,
        "comparison_error_count" => length(errors),
        "comparison_errors" => errors,
        "aggregate_finding_code_delta_right_minus_left" => _aggregate_cases(comparisons),
        "cases" => comparisons,
        "unit_ratio_report_path" => isempty(ratio_path) ? nothing : abspath(ratio_path),
        "unit_ratio_report" => ratio_report,
        "interpretation" => "Paired evidence comparison only. Positive deltas mean more right-campaign findings; this is not a quality score and does not certify either unit policy.",
    )
    write(output_path, JSON.json(report))
    println("wrote BMOPF saved-result profile comparison to $output_path")
end

main()
