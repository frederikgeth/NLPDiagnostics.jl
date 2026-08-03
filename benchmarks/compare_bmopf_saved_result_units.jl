#!/usr/bin/env julia

"""Compare paired BMOPF SI and PU result files field by field.

This is deliberately separate from the point mapper. BMOPF result files can
carry a per-unit suffix while exporting some fields in physical units. The
comparison reports observed `PU / SI` magnitude ratios by semantic field family
without deciding that either file is the correct model point.

Usage:

    julia benchmarks/compare_bmopf_saved_result_units.jl \
        /path/to/BMOPFDraftData/benchmarks [output.json]

Use `NLPDIAGNOSTICS_BMOPF_CASE_SELECTION` or the explicit
`NLPDIAGNOSTICS_BMOPF_CASES` environment variable to select snapshots.
"""

using JSON
using Statistics

const _DEFAULT_CASES = [
    "ENWLsnapshots/30bus_LN/30bus_LN_t01_0800.bmopf.json",
    "ENWLsnapshots/30bus_LG/30bus_LG_t01_0800.bmopf.json",
]

_finite_number(value) = value isa Number && isfinite(Float64(value))

function _selection_prefixes(selection)
    selection == "30bus" && return ["ENWLsnapshots/30bus_LN/", "ENWLsnapshots/30bus_LG/"]
    selection == "30bus_ln" && return ["ENWLsnapshots/30bus_LN/"]
    selection == "30bus_lg" && return ["ENWLsnapshots/30bus_LG/"]
    selection == "538bus" && return ["ENWLsnapshots/538bus_LN/", "ENWLsnapshots/538bus_LG/"]
    selection == "538bus_ln" && return ["ENWLsnapshots/538bus_LN/"]
    selection == "538bus_lg" && return ["ENWLsnapshots/538bus_LG/"]
    selection == "99bus" && return ["ENWLsnapshots/99bus_LN/", "ENWLsnapshots/99bus_LG/"]
    selection == "99bus_ln" && return ["ENWLsnapshots/99bus_LN/"]
    selection == "99bus_lg" && return ["ENWLsnapshots/99bus_LG/"]
    error("unknown NLPDIAGNOSTICS_BMOPF_CASE_SELECTION='$selection'")
end

function _selected_cases(root)
    explicit = filter(!isempty, strip.(split(get(ENV, "NLPDIAGNOSTICS_BMOPF_CASES", ""), ',')))
    selection = lowercase(strip(get(ENV, "NLPDIAGNOSTICS_BMOPF_CASE_SELECTION", "")))
    cases = if !isempty(explicit)
        explicit
    elseif isempty(selection)
        _DEFAULT_CASES
    else
        prefixes = _selection_prefixes(selection)
        discovered = String[]
        for (directory, _, files) in walkdir(joinpath(root, "ENWLsnapshots"))
            for file in files
                endswith(file, ".bmopf.json") || continue
                relative = relpath(joinpath(directory, file), root)
                any(startswith(relative, prefix) for prefix in prefixes) || continue
                push!(discovered, relative)
            end
        end
        sort!(discovered)
    end
    isempty(cases) && error("no BMOPF snapshots selected")
    for relative in cases
        isabspath(relative) && error("case selections must be relative to the benchmark root")
        endswith(relative, ".bmopf.json") || error("case is not a .bmopf.json snapshot: $relative")
        isfile(joinpath(root, relative)) || error("selected snapshot is missing: $(joinpath(root, relative))")
    end
    return cases
end

function _family(path)
    isempty(path) && return "<root>"
    root = first(path)
    leaf = last(path)
    root == leaf ? root : "$root/$leaf"
end

function _new_stats()
    return Dict{String,Any}(
        "ratios" => Float64[],
        "numeric_pair_count" => 0,
        "zero_pair_count" => 0,
        "missing_pair_count" => 0,
    )
end

function _record_missing!(stats, path)
    family = _family(path)
    entry = get!(stats, family, _new_stats())
    entry["missing_pair_count"] += 1
    return nothing
end

function _walk_pair!(si, pu, path, stats)
    if si isa AbstractDict && pu isa AbstractDict
        keys_union = sort!(String[string(key) for key in union(keys(si), keys(pu))])
        for key in keys_union
            _walk_pair!(get(si, key, nothing), get(pu, key, nothing), [path; key], stats)
        end
        return nothing
    end
    family = _family(path)
    if !_finite_number(si) || !_finite_number(pu)
        _record_missing!(stats, path)
        return nothing
    end
    entry = get!(stats, family, _new_stats())
    entry["numeric_pair_count"] += 1
    a = abs(Float64(si))
    b = abs(Float64(pu))
    if a <= eps(Float64) || b <= eps(Float64)
        entry["zero_pair_count"] += 1
    else
        push!(entry["ratios"], b / a)
    end
    return nothing
end

function _classification(median_ratio, minimum_ratio, maximum_ratio)
    isnothing(median_ratio) && return "no_nonzero_numeric_pairs"
    if maximum_ratio / max(minimum_ratio, eps(Float64)) > 100.0
        return "mixed_field_scale"
    elseif median_ratio <= 0.1
        return "pu_smaller_than_si"
    elseif median_ratio >= 10.0
        return "pu_larger_than_si"
    elseif 0.5 <= median_ratio <= 2.0
        return "same_exported_scale"
    end
    return "different_scale"
end

function _summarize_stats(stats)
    result = Dict{String,Any}()
    for family in sort!(collect(keys(stats)))
        entry = stats[family]
        ratios = entry["ratios"]
        median_ratio = isempty(ratios) ? nothing : median(ratios)
        minimum_ratio = isempty(ratios) ? nothing : minimum(ratios)
        maximum_ratio = isempty(ratios) ? nothing : maximum(ratios)
        result[family] = Dict(
            "numeric_pair_count" => entry["numeric_pair_count"],
            "zero_pair_count" => entry["zero_pair_count"],
            "missing_pair_count" => entry["missing_pair_count"],
            "nonzero_ratio_count" => length(ratios),
            "median_pu_over_si_magnitude_ratio" => median_ratio,
            "minimum_pu_over_si_magnitude_ratio" => minimum_ratio,
            "maximum_pu_over_si_magnitude_ratio" => maximum_ratio,
            "classification" => _classification(median_ratio, minimum_ratio, maximum_ratio),
        )
    end
    return result
end

function _merge_stats!(aggregate, case_stats)
    for (family, entry) in case_stats
        target = get!(aggregate, family, _new_stats())
        append!(target["ratios"], entry["ratios"])
        target["numeric_pair_count"] += entry["numeric_pair_count"]
        target["zero_pair_count"] += entry["zero_pair_count"]
        target["missing_pair_count"] += entry["missing_pair_count"]
    end
    return aggregate
end

function main()
    length(ARGS) in (1, 2) || error(
        "usage: compare_bmopf_saved_result_units.jl benchmark-root [output.json]",
    )
    root = abspath(first(ARGS))
    isdir(root) || error("benchmark root does not exist: $root")
    output_path = length(ARGS) == 2 ? abspath(ARGS[2]) :
        joinpath(pwd(), "bmopf-saved-result-unit-comparison.json")
    cases = _selected_cases(root)
    aggregate = Dict{String,Any}()
    case_records = Any[]
    missing_si = String[]
    missing_pu = String[]
    for relative in cases
        snapshot = joinpath(root, relative)
        si_path = replace(snapshot, ".bmopf.json" => "_result_si.json")
        pu_path = replace(snapshot, ".bmopf.json" => "_result_pu.json")
        isfile(si_path) || (push!(missing_si, relative); continue)
        isfile(pu_path) || (push!(missing_pu, relative); continue)
        si = JSON.parsefile(si_path)
        pu = JSON.parsefile(pu_path)
        stats = Dict{String,Any}()
        _walk_pair!(si, pu, String[], stats)
        _merge_stats!(aggregate, stats)
        push!(case_records, Dict(
            "snapshot" => relative,
            "field_families" => _summarize_stats(stats),
        ))
    end
    report = Dict(
        "report_version" => "bmopf-saved-result-unit-comparison-v1",
        "benchmark_root" => root,
        "case_selection" => get(ENV, "NLPDIAGNOSTICS_BMOPF_CASE_SELECTION", ""),
        "selected_case_count" => length(cases),
        "paired_case_count" => length(case_records),
        "missing_si_case_count" => length(missing_si),
        "missing_pu_case_count" => length(missing_pu),
        "missing_si_cases" => missing_si,
        "missing_pu_cases" => missing_pu,
        "aggregate_field_families" => _summarize_stats(aggregate),
        "cases" => case_records,
        "interpretation" => "Observed PU/SI numeric ratios only; this report does not certify a unit convention or model feasibility.",
    )
    write(output_path, JSON.json(report))
    println("wrote BMOPF saved-result unit comparison to $output_path")
end

main()
