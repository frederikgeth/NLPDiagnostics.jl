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
    profile isa AbstractDict || return Dict()
    report = get(profile, report_key, Dict())
    report isa AbstractDict || return Dict()
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

const _CONTROLLER_SEMANTIC_FAMILIES = Dict(
    "volt_var" => "ibr_q_volt_var",
    "volt_watt" => "ibr_p_volt_watt",
)

function _controller_registry_crosswalk(record, observations)
    profile = get(record, "profile", Dict())
    semantic_rows = profile isa AbstractDict ?
        get(profile, "bmopf_constraint_semantic_rows", nothing) : nothing
    semantic_rows isa AbstractDict || return Dict{String,Any}(
        "status" => "unavailable",
        "reason" => "saved_result_record_has_no_semantic_row_registry",
        "status_counts" => Dict{String,Int}(),
        "components_by_status" => Dict{String,Any}(),
        "matches" => Any[],
    )
    status_counts = Dict{String,Int}()
    components_by_status = Dict{String,Vector{String}}()
    matches = Any[]
    for observation in observations
        observation isa AbstractDict || continue
        residual = _float_or_nothing(get(observation, "equation_residual", nothing))
        metadata = get(observation, "metadata", Dict())
        metadata isa AbstractDict || (metadata = Dict())
        tolerance = _float_or_nothing(get(metadata, "controller_residual_tolerance", nothing))
        cap = _float_or_nothing(get(observation, "cap_violation", nothing))
        violation = (residual isa Real && tolerance isa Real && abs(residual) > tolerance) ||
                    (cap isa Real && cap > 0)
        violation || continue
        component_id = get(observation, "component_id", nothing)
        family = get(observation, "curve_family", nothing)
        component_id isa AbstractString && family isa AbstractString || continue
        key = "ibr:$(component_id):$(family)"
        expected_family = get(_CONTROLLER_SEMANTIC_FAMILIES, String(family), nothing)
        row_matches = String[]
        if expected_family isa AbstractString
            for (row, descriptor) in semantic_rows
                descriptor isa AbstractDict || continue
                get(descriptor, "constraint_family", nothing) == expected_family || continue
                index_text = string(get(descriptor, "constraint_index", ""))
                occursin(String(component_id), index_text) && push!(row_matches, String(row))
            end
        end
        status = isempty(row_matches) ? "not_found" : "registered"
        status_counts[status] = get(status_counts, status, 0) + 1
        push!(get!(components_by_status, status, String[]), key)
        push!(matches, Dict("component" => key, "curve_family" => family,
                            "expected_constraint_family" => expected_family,
                            "status" => status, "matching_rows" => row_matches))
    end
    return Dict{String,Any}(
        "status" => "available",
        "status_counts" => Dict(k => status_counts[k] for k in sort!(collect(keys(status_counts)))),
        "components_by_status" => Dict(k => sort!(unique(components_by_status[k]))
                                         for k in sort!(collect(keys(components_by_status)))),
        "matches" => matches,
    )
end

function _controller_profile_summary(record)
    profile = get(record, "profile", Dict())
    observations = profile isa AbstractDict ?
        get(profile, "bmopf_controller_curve_observations", nothing) : nothing
    observations isa AbstractDict || return Dict{String,Any}(
        "available" => false,
        "observation_count" => 0,
        "exact_monitor_count" => 0,
        "proxy_monitor_count" => 0,
        "status_counts" => Dict{String,Int}(),
        "monitor_semantics_counts" => Dict{String,Int}(),
        "family_counts" => Dict{String,Int}(),
        "equation_residual_violation_count" => 0,
        "cap_violation_count" => 0,
        "finite_observation_count" => 0,
        "nonfinite_observation_count" => 0,
        "local_slope" => Dict("minimum" => nothing, "maximum" => nothing,
                               "mean" => nothing, "finite_count" => 0),
        "breakpoint_distance" => Dict("minimum" => nothing, "maximum" => nothing,
                                       "mean" => nothing, "finite_count" => 0),
        "registry" => Dict("status" => "unavailable", "reason" => "saved_result_record_has_no_semantic_row_registry"),
    )
    status_counts = Dict{String,Int}()
    semantics_counts = Dict{String,Int}()
    family_counts = Dict{String,Int}()
    slopes = Float64[]
    distances = Float64[]
    residual_violations = 0
    cap_violations = 0
    finite_count = 0
    nonfinite_count = 0
    residual_tolerance = nothing
    raw_observations = get(observations, "observations", Any[])
    raw_observations isa AbstractVector || (raw_observations = Any[])
    for raw in raw_observations
        raw isa AbstractDict || continue
        status = String(get(raw, "status", "unknown"))
        status_counts[status] = get(status_counts, status, 0) + 1
        semantics = get(raw, "monitor_semantics", nothing)
        semantics isa AbstractString && (semantics_counts[String(semantics)] = get(semantics_counts, String(semantics), 0) + 1)
        family = get(raw, "curve_family", nothing)
        family isa AbstractString && (family_counts[String(family)] = get(family_counts, String(family), 0) + 1)
        status == "finite" ? (finite_count += 1) : (nonfinite_count += 1)
        slope = _float_or_nothing(get(raw, "local_slope", nothing))
        slope isa Real && push!(slopes, slope)
        distance = _float_or_nothing(get(raw, "breakpoint_distance", nothing))
        distance isa Real && push!(distances, distance)
        metadata = get(raw, "metadata", Dict())
        metadata isa AbstractDict || (metadata = Dict())
        tolerance = _float_or_nothing(get(metadata, "controller_residual_tolerance", nothing))
        tolerance isa Real && (residual_tolerance = tolerance)
        residual = _float_or_nothing(get(raw, "equation_residual", nothing))
        residual isa Real && tolerance isa Real && abs(residual) > tolerance && (residual_violations += 1)
        cap = _float_or_nothing(get(raw, "cap_violation", nothing))
        cap isa Real && cap > 0 && (cap_violations += 1)
    end
    _stats(values) = isempty(values) ?
        Dict("minimum" => nothing, "maximum" => nothing, "mean" => nothing, "finite_count" => 0) :
        Dict("minimum" => minimum(values), "maximum" => maximum(values),
             "mean" => sum(values) / length(values), "finite_count" => length(values))
    registry = _controller_registry_crosswalk(record, raw_observations)
    return Dict{String,Any}(
        "available" => true,
        "observation_count" => _int_or_nothing(get(observations, "observation_count", length(raw_observations))),
        "exact_monitor_count" => _int_or_nothing(get(observations, "exact_monitor_count", 0)),
        "proxy_monitor_count" => _int_or_nothing(get(observations, "proxy_monitor_count", 0)),
        "status_counts" => Dict(code => status_counts[code] for code in sort!(collect(keys(status_counts)))),
        "monitor_semantics_counts" => Dict(code => semantics_counts[code] for code in sort!(collect(keys(semantics_counts)))),
        "family_counts" => Dict(code => family_counts[code] for code in sort!(collect(keys(family_counts)))),
        "equation_residual_violation_count" => residual_violations,
        "cap_violation_count" => cap_violations,
        "finite_observation_count" => finite_count,
        "nonfinite_observation_count" => nonfinite_count,
        "residual_tolerance" => residual_tolerance,
        "local_slope" => _stats(slopes),
        "breakpoint_distance" => _stats(distances),
        "finding_code_counts" => _finding_code_counts(get(observations, "findings", Any[])),
        "registry" => registry,
    )
end

function _controller_delta(left, right)
    delta = Dict{String,Any}()
    for key in ("observation_count", "exact_monitor_count", "proxy_monitor_count",
                "equation_residual_violation_count", "cap_violation_count",
                "finite_observation_count", "nonfinite_observation_count")
        lvalue = get(left, key, 0); rvalue = get(right, key, 0)
        lvalue isa Number && rvalue isa Number && (delta["$(key)_delta_right_minus_left"] = rvalue - lvalue)
    end
    delta["status_count_delta_right_minus_left"] = _delta_map(
        get(left, "status_counts", Dict()), get(right, "status_counts", Dict()))
    delta["monitor_semantics_count_delta_right_minus_left"] = _delta_map(
        get(left, "monitor_semantics_counts", Dict()), get(right, "monitor_semantics_counts", Dict()))
    delta["family_count_delta_right_minus_left"] = _delta_map(
        get(left, "family_counts", Dict()), get(right, "family_counts", Dict()))
    for (field, key) in (("local_slope", "mean"), ("breakpoint_distance", "mean"))
        lvalue = get(get(left, field, Dict()), key, nothing)
        rvalue = get(get(right, field, Dict()), key, nothing)
        lvalue isa Number && rvalue isa Number && (delta["$(field)_$(key)_delta_right_minus_left"] = rvalue - lvalue)
    end
    delta["finding_code_delta_right_minus_left"] = _delta_map(
        get(left, "finding_code_counts", Dict()), get(right, "finding_code_counts", Dict()))
    left_registry = get(left, "registry", Dict())
    right_registry = get(right, "registry", Dict())
    delta["registry_status"] = Dict("left" => get(left_registry, "status", "unavailable"),
                                    "right" => get(right_registry, "status", "unavailable"))
    delta["registry_status_count_delta_right_minus_left"] = _delta_map(
        get(left_registry, "status_counts", Dict()), get(right_registry, "status_counts", Dict()))
    return delta
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
    numerical_report = get(get(get(record, "profile", Dict()), "profile", Dict()),
                           "reports", Dict())
    numerical_report = numerical_report isa AbstractDict ?
                       get(numerical_report, "numerical", Dict()) : Dict()
    numerical_metadata = get(numerical_report, "metadata", Dict())
    numerical_metadata = numerical_metadata isa AbstractDict ? numerical_metadata : Dict()
    derivative_codes = _finding_code_counts(get(numerical_report, "findings", Any[]))
    derivative_fingerprint = Dict(
        "jacobian_rank_available" => get(numerical_metadata, "jacobian_rank_available", nothing),
        "jacobian_rank" => _int_or_nothing(get(numerical_metadata, "jacobian_rank", nothing)),
        "sparse_qr_rank_available" => get(numerical_metadata, "sparse_qr_rank_available", nothing),
        "sparse_qr_rank" => _int_or_nothing(get(numerical_metadata, "sparse_qr_rank", nothing)),
        "sparse_jacobian_pattern_rank_upper_bound" => _int_or_nothing(
            get(numerical_metadata, "sparse_jacobian_pattern_rank_upper_bound", nothing),
        ),
        "derivative_finding_counts" => Dict(code => derivative_codes[code]
            for code in sort!(collect(keys(derivative_codes)))
            if occursin("derivative", code) || occursin("jacobian", code) || occursin("scale", code)),
    )
    return Dict(
        "finding_code_counts_by_domain" => by_domain,
        "finding_code_counts" => Dict(code => all_counts[code] for code in sort!(collect(keys(all_counts)))),
        "constraint_feasibility_violation_count" => feasibility,
        "scale_finding_counts" => scale_counts,
        "total_finding_count" => length(evidence["all"]),
        "derivative_fingerprint" => derivative_fingerprint,
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
    left_derivative = left_summary["derivative_fingerprint"]
    right_derivative = right_summary["derivative_fingerprint"]
    left_controller = _controller_profile_summary(left)
    right_controller = _controller_profile_summary(right)
    derivative_deltas = Dict{String,Any}()
    for key in ("jacobian_rank", "sparse_qr_rank", "sparse_jacobian_pattern_rank_upper_bound")
        lvalue = get(left_derivative, key, nothing)
        rvalue = get(right_derivative, key, nothing)
        lvalue isa Number && rvalue isa Number || continue
        derivative_deltas["$(key)_delta_right_minus_left"] = rvalue - lvalue
    end
    return Dict(
        "snapshot" => snapshot,
        "left_campaign_fingerprint" => get(left, "campaign_fingerprint", nothing),
        "right_campaign_fingerprint" => get(right, "campaign_fingerprint", nothing),
        "left_policy" => left_policy,
        "right_policy" => right_policy,
        "left_summary" => left_summary,
        "right_summary" => right_summary,
        "left_result_field_catalog" => get(get(left, "profile", Dict()), "bmopf_result_field_catalog", nothing),
        "right_result_field_catalog" => get(get(right, "profile", Dict()), "bmopf_result_field_catalog", nothing),
        "left_feasibility_field_attribution" => get(get(left, "profile", Dict()), "bmopf_constraint_feasibility_field_attribution", nothing),
        "right_feasibility_field_attribution" => get(get(right, "profile", Dict()), "bmopf_constraint_feasibility_field_attribution", nothing),
        "finding_count_delta_right_minus_left" => right_summary["total_finding_count"] - left_summary["total_finding_count"],
        "feasibility_violation_delta_right_minus_left" => right_summary["constraint_feasibility_violation_count"] - left_summary["constraint_feasibility_violation_count"],
        "scale_finding_delta_right_minus_left" => _delta_map(left_summary["scale_finding_counts"], right_summary["scale_finding_counts"]),
        "derivative_fingerprint_delta" => derivative_deltas,
        "left_controller_curve" => left_controller,
        "right_controller_curve" => right_controller,
        "controller_curve_delta_right_minus_left" => _controller_delta(left_controller, right_controller),
        "finding_code_delta_right_minus_left" => _delta_map(left_codes, right_codes),
    )
end

function _aggregate_controller_cases(cases)
    totals = Dict{String,Int}()
    transitions = Any[]
    available_case_count = 0
    registry_statuses = Dict{String,Int}()
    registry_violation_statuses = Dict{String,Int}()
    registry_boundaries = Any[]
    for case in cases
        left_controller = get(case, "left_controller_curve", Dict())
        right_controller = get(case, "right_controller_curve", Dict())
        left_available = left_controller isa AbstractDict && get(left_controller, "available", false) === true
        right_available = right_controller isa AbstractDict && get(right_controller, "available", false) === true
        (left_available || right_available) && (available_case_count += 1)
        for side in ("left", "right")
            controller = side == "left" ? left_controller : right_controller
            registry = controller isa AbstractDict ? get(controller, "registry", Dict()) : Dict()
            status = String(get(registry, "status", "unavailable"))
            registry_statuses[status] = get(registry_statuses, status, 0) + 1
            status_counts = get(registry, "status_counts", Dict())
            status_counts isa AbstractDict || (status_counts = Dict())
            for (violation_status, count) in status_counts
                count isa Number || continue
                registry_violation_statuses[String(violation_status)] =
                    get(registry_violation_statuses, String(violation_status), 0) + Int(count)
            end
            any(value -> value isa Number && value > 0,
                values(status_counts)) && push!(registry_boundaries, Dict(
                    "snapshot" => get(case, "snapshot", nothing),
                    "side" => side,
                    "status_counts" => status_counts,
                    "components_by_status" => get(registry, "components_by_status", Dict()),
                ))
        end
        delta = get(case, "controller_curve_delta_right_minus_left", Dict())
        delta isa AbstractDict || continue
        for key in ("observation_count_delta_right_minus_left", "exact_monitor_count_delta_right_minus_left",
                    "proxy_monitor_count_delta_right_minus_left", "equation_residual_violation_count_delta_right_minus_left",
                    "cap_violation_count_delta_right_minus_left", "finite_observation_count_delta_right_minus_left",
                    "nonfinite_observation_count_delta_right_minus_left")
            value = get(delta, key, nothing)
            value isa Number && (totals[key] = get(totals, key, 0) + Int(value))
        end
        status = get(delta, "status_count_delta_right_minus_left", Dict())
        semantics = get(delta, "monitor_semantics_count_delta_right_minus_left", Dict())
        families = get(delta, "family_count_delta_right_minus_left", Dict())
        (!isempty(status) || !isempty(semantics) || !isempty(families)) && push!(transitions, Dict(
            "snapshot" => get(case, "snapshot", nothing),
            "status_count_delta_right_minus_left" => status,
            "monitor_semantics_count_delta_right_minus_left" => semantics,
            "family_count_delta_right_minus_left" => families,
        ))
    end
    return Dict("case_count" => length(cases),
                "available_case_count" => available_case_count,
                "missing_case_count" => length(cases) - available_case_count,
                "registry_status_counts" => registry_statuses,
                "registry_violation_status_counts" => registry_violation_statuses,
                "registry_boundary_cases" => registry_boundaries,
                "aggregate_count_deltas" => totals,
                "transition_cases" => transitions,
                "transition_case_count" => length(transitions),
                "registry_scope" => "saved_result_record")
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

function _unit_ratio_case(ratio_report, snapshot)
    ratio_report isa AbstractDict || return nothing
    for case in get(ratio_report, "cases", Any[])
        case isa AbstractDict || continue
        get(case, "snapshot", nothing) == snapshot || continue
        families = get(case, "field_families", Dict())
        families isa AbstractDict || return nothing
        outliers = Dict{String,Any}()
        for (family, entry) in families
            entry isa AbstractDict || continue
            classification = get(entry, "classification", nothing)
            classification in ("same_exported_scale", "no_nonzero_numeric_pairs") && continue
            outliers[String(family)] = Dict(
                "classification" => classification,
                "median_pu_over_si_magnitude_ratio" => get(entry, "median_pu_over_si_magnitude_ratio", nothing),
                "minimum_pu_over_si_magnitude_ratio" => get(entry, "minimum_pu_over_si_magnitude_ratio", nothing),
                "maximum_pu_over_si_magnitude_ratio" => get(entry, "maximum_pu_over_si_magnitude_ratio", nothing),
                "nonzero_ratio_count" => get(entry, "nonzero_ratio_count", 0),
            )
        end
        return Dict(
            "paired_unit_ratio_case_available" => true,
            "outlier_field_families" => outliers,
        )
    end
    return Dict("paired_unit_ratio_case_available" => false)
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
    for case in comparisons
        snapshot = get(case, "snapshot", nothing)
        snapshot isa AbstractString || continue
        case["unit_ratio_fingerprint"] = _unit_ratio_case(ratio_report, snapshot)
    end
    report = Dict(
        "report_version" => "bmopf-saved-result-profile-comparison-v4",
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
        "controller_curve_policy_matrix" => _aggregate_controller_cases(comparisons),
        "cases" => comparisons,
        "unit_ratio_report_path" => isempty(ratio_path) ? nothing : abspath(ratio_path),
        "unit_ratio_report" => ratio_report,
        "interpretation" => "Paired evidence comparison only. Positive deltas mean more right-campaign findings; this is not a quality score and does not certify either unit policy.",
    )
    write(output_path, JSON.json(report))
    println("wrote BMOPF saved-result profile comparison to $output_path")
end

main()
