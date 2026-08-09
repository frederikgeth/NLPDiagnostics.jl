#!/usr/bin/env julia

"""Compare two BMOPF multiconductor point-policy summaries.

The comparison is deliberately point-local. It reports contract, physical-mode,
and iterative-probe changes without promoting them to physical or rank claims.
"""

using JSON

_dict(value) = value isa AbstractDict ?
    Dict{String,Any}(String(k) => v for (k, v) in value) : Dict{String,Any}()

function _load(path)
    isfile(path) || error("missing multiconductor point summary: $path")
    value = JSON.parsefile(path)
    value isa AbstractDict || error("summary is not a JSON object: $path")
    value
end

function _bool(value)
    value === true && return true
    value === false && return false
    value isa AbstractString && return lowercase(strip(String(value))) in ("true", "1", "yes")
    return false
end

function _int(value, default = 0)
    value isa Integer && return Int(value)
    value isa Number && isfinite(Float64(value)) && return Int(value)
    try parse(Int, String(value)) catch; default end
end

function _float(value)
    value isa Number && isfinite(Float64(value)) && return Float64(value)
    try
        parsed = parse(Float64, String(value))
        isfinite(parsed) ? parsed : nothing
    catch
        nothing
    end
end

function _case_map(summary)
    result = Dict{String,Any}()
    for raw in get(summary, "cases", Any[])
        case = _dict(raw)
        name = String(get(case, "name", ""))
        isempty(name) || (result[name] = case)
    end
    result
end

function _contract(case)
    raw = _dict(get(case, "multiconductor_contract", nothing))
    fields = (
        "voltage_port_count", "current_port_count", "constitutive_map_count",
        "complex_constitutive_map_count", "physical_mode_count",
        "voltage_coordinate_map_count", "current_coordinate_map_count",
        "voltage_coordinate_alignment", "current_coordinate_alignment",
        "port_assembly_component_count", "port_assembly_connected_component_count",
    )
    Dict(key => get(raw, key, nothing) for key in fields)
end

function _modes(case)
    raw = _dict(get(case, "physical_mode_comparison", nothing))
    Dict(
        "status" => get(raw, "status", "unavailable"),
        "expected_mode_count" => _int(get(raw, "expected_mode_count", 0)),
        "observed_mode_count" => _int(get(raw, "observed_mode_count", 0)),
        "unaligned_mode_count" => _int(get(raw, "unaligned_mode_count", 0)),
        "not_observed_mode_count" => _int(get(raw, "not_observed_mode_count", 0)),
        "partial_alignment_mode_count" => _int(get(raw, "partial_alignment_mode_count", 0)),
        "jacobian_rank_available" => _bool(get(raw, "jacobian_rank_available", false)),
        "dense_guard_allows" => _bool(get(raw, "dense_guard_allows", false)),
        "jacobian_rank" => _int(get(raw, "jacobian_rank", 0)),
        "sparse_qr_rank" => _int(get(raw, "sparse_qr_rank", 0)),
    )
end

function _alignment(contract, key)
    raw = _dict(get(contract, key, nothing))
    Dict(
        "port_count" => _int(get(raw, "port_count", 0)),
        "map_count" => _int(get(raw, "map_count", 0)),
        "aligned_port_count" => _int(get(raw, "aligned_port_count", 0)),
        "missing_map_count" => _int(get(raw, "missing_map_count", 0)),
        "dimension_mismatch_count" => _int(get(raw, "dimension_mismatch_count", 0)),
        "nonfinite_map_count" => _int(get(raw, "nonfinite_map_count", 0)),
        "status_counts" => _dict(get(raw, "status_counts", nothing)),
    )
end

function _port_map_alignment_status(voltage, current)
    all(get(view, key, 0) == 0 for view in (voltage, current) for key in
        ("missing_map_count", "dimension_mismatch_count", "nonfinite_map_count")) ||
        return "port_map_boundary"
    voltage["port_count"] > 0 && current["port_count"] > 0 &&
        voltage["aligned_port_count"] == voltage["port_count"] &&
        current["aligned_port_count"] == current["port_count"] &&
        return "port_maps_complete"
    return "port_map_unavailable"
end

function _probe(case)
    raw = _dict(get(case, "iterative_right_nullspace_probe", nothing))
    Dict(
        "requested_dimension" => _int(get(raw, "requested_dimension", 0)),
        "available" => _bool(get(raw, "available", false)),
        "converged" => _bool(get(raw, "converged", false)),
        "candidate_count" => _int(get(raw, "candidate_count", 0)),
        "no_small_residual_count" => _int(get(raw, "no_small_residual_count", 0)),
    )
end

function _delta(left, right)
    l, r = _float(left), _float(right)
    isnothing(l) || isnothing(r) ? nothing : r - l
end

function _alignment_status(left_modes, right_modes)
    left_modes["jacobian_rank_available"] && right_modes["jacobian_rank_available"] ||
        return "rank_unavailable"
    left_modes["unaligned_mode_count"] == 0 && right_modes["unaligned_mode_count"] == 0 &&
        return "aligned"
    return "coordinate_alignment_boundary"
end

function main()
    length(ARGS) in (2, 3) || error(
        "usage: compare_bmopf_multiconductor_points.jl baseline-summary.json candidate-summary.json [comparison.json]",
    )
    baseline_path, candidate_path = abspath.(ARGS[1:2])
    output_path = length(ARGS) == 3 ? abspath(ARGS[3]) :
        joinpath(dirname(candidate_path), "multiconductor_point_comparison.json")
    baseline, candidate = _load(baseline_path), _load(candidate_path)
    baseline_cases, candidate_cases = _case_map(baseline), _case_map(candidate)
    names = sort!(collect(intersect(Set(keys(baseline_cases)), Set(keys(candidate_cases)))))
    missing_baseline = sort!(collect(setdiff(Set(keys(candidate_cases)), Set(keys(baseline_cases)))))
    missing_candidate = sort!(collect(setdiff(Set(keys(baseline_cases)), Set(keys(candidate_cases)))))
    baseline_cases_raw = get(baseline, "cases", Any[])
    candidate_cases_raw = get(candidate, "cases", Any[])
    baseline_first_case = isempty(baseline_cases_raw) ? Dict{String,Any}() :
        _dict(first(baseline_cases_raw))
    candidate_first_case = isempty(candidate_cases_raw) ? Dict{String,Any}() :
        _dict(first(candidate_cases_raw))
    baseline_policy = get(baseline, "point_policy",
        get(baseline_first_case, "point_policy", "unknown"))
    candidate_policy = get(candidate, "point_policy",
        get(candidate_first_case, "point_policy", "unknown"))
    baseline_dense_budget = _int(get(baseline, "rank_max_dense_entries",
        get(baseline_first_case, "rank_max_dense_entries", 0)))
    candidate_dense_budget = _int(get(candidate, "rank_max_dense_entries",
        get(candidate_first_case, "rank_max_dense_entries", 0)))
    paired = Any[]
    for name in names
        left, right = baseline_cases[name], candidate_cases[name]
        left_contract, right_contract = _contract(left), _contract(right)
        left_voltage_alignment = _alignment(left_contract, "voltage_coordinate_alignment")
        right_voltage_alignment = _alignment(right_contract, "voltage_coordinate_alignment")
        left_current_alignment = _alignment(left_contract, "current_coordinate_alignment")
        right_current_alignment = _alignment(right_contract, "current_coordinate_alignment")
        left_modes, right_modes = _modes(left), _modes(right)
        left_probe, right_probe = _probe(left), _probe(right)
        alignment_status = _alignment_status(left_modes, right_modes)
        port_map_status = _port_map_alignment_status(left_voltage_alignment, left_current_alignment)
        candidate_port_map_status = _port_map_alignment_status(right_voltage_alignment, right_current_alignment)
        dense_rank_changed = left_modes["jacobian_rank_available"] &&
            right_modes["jacobian_rank_available"] &&
            left_modes["jacobian_rank"] != right_modes["jacobian_rank"]
        push!(paired, Dict{String,Any}(
            "name" => name,
            "baseline_status" => get(left, "status", "unknown"),
            "candidate_status" => get(right, "status", "unknown"),
            "status_changed" => get(left, "status", nothing) != get(right, "status", nothing),
            "baseline_contract" => left_contract,
            "candidate_contract" => right_contract,
            "contract_changed" => left_contract != right_contract,
            "baseline_voltage_alignment" => left_voltage_alignment,
            "candidate_voltage_alignment" => right_voltage_alignment,
            "voltage_alignment_changed" => left_voltage_alignment != right_voltage_alignment,
            "baseline_current_alignment" => left_current_alignment,
            "candidate_current_alignment" => right_current_alignment,
            "current_alignment_changed" => left_current_alignment != right_current_alignment,
            "baseline_port_map_alignment_status" => port_map_status,
            "candidate_port_map_alignment_status" => candidate_port_map_status,
            "port_map_alignment_changed" => port_map_status != candidate_port_map_status,
            "baseline_modes" => left_modes,
            "candidate_modes" => right_modes,
            "mode_status_changed" => left_modes["status"] != right_modes["status"],
            "dense_rank_availability_changed" => left_modes["jacobian_rank_available"] != right_modes["jacobian_rank_available"],
            "dense_rank_changed" => dense_rank_changed,
            "alignment_status" => alignment_status,
            "rank_change_classification" => dense_rank_changed ?
                (alignment_status == "aligned" ? "coordinate_aligned_rank_change" :
                 port_map_status == "port_maps_complete" ? "mode_semantics_alignment_ambiguous" :
                 "alignment_ambiguous") :
                "rank_stable",
            "mode_observed_count_delta" => _delta(
                left_modes["observed_mode_count"], right_modes["observed_mode_count"],
            ),
            "baseline_probe" => left_probe,
            "candidate_probe" => right_probe,
            "probe_convergence_changed" => left_probe["converged"] != right_probe["converged"],
            "probe_candidate_count_delta" => right_probe["candidate_count"] - left_probe["candidate_count"],
        ))
    end
    same_environment = get(baseline, "environment_fingerprint", nothing) ==
                       get(candidate, "environment_fingerprint", nothing)
    successful_overlap = count(row -> row["baseline_status"] == "ok" &&
        row["candidate_status"] == "ok", paired)
    dense_overlap = count(row -> row["baseline_status"] == "ok" &&
        row["candidate_status"] == "ok" &&
        row["baseline_modes"]["jacobian_rank_available"] &&
        row["candidate_modes"]["jacobian_rank_available"], paired)
    dense_rank_changes = count(row -> row["dense_rank_changed"], paired)
    alignment_blocked = count(row -> row["alignment_status"] == "coordinate_alignment_boundary", paired)
    alignment_available = count(row -> row["alignment_status"] == "aligned", paired)
    port_map_complete = count(row -> row["baseline_port_map_alignment_status"] == "port_maps_complete" &&
        row["candidate_port_map_alignment_status"] == "port_maps_complete", paired)
    findings = Any[]
    isempty(missing_baseline) && isempty(missing_candidate) || push!(findings, Dict(
        "code" => "multiconductor_point_case_coverage_mismatch", "severity" => "warning",
        "observation" => "The point-policy summaries do not cover the same fixtures.",
        "evidence" => Dict("missing_from_baseline" => missing_baseline,
                           "missing_from_candidate" => missing_candidate),
        "suggested_action" => "Compare only explicitly paired fixture names.",
    ))
    same_environment || push!(findings, Dict(
        "code" => "multiconductor_point_environment_mismatch", "severity" => "warning",
        "observation" => "The point-policy summaries were produced under different environments.",
        "evidence" => Dict("baseline_environment" => get(baseline, "environment_fingerprint", nothing),
                           "candidate_environment" => get(candidate, "environment_fingerprint", nothing)),
        "suggested_action" => "Align Julia, BMOPFTools, PowerIO, and fixture provenance first.",
    ))
    baseline_policy == candidate_policy && push!(findings, Dict(
        "code" => "multiconductor_point_policy_not_distinct", "severity" => "warning",
        "observation" => "Both summaries report the same point policy.",
        "evidence" => Dict("point_policy" => baseline_policy),
        "suggested_action" => "Select distinct evaluation-point policies for comparison.",
    ))
    successful_overlap == 0 && push!(findings, Dict(
        "code" => "multiconductor_point_successful_overlap_empty", "severity" => "warning",
        "observation" => "The paired point policies have no fixture successful at both points.",
        "evidence" => Dict("paired_case_count" => length(paired),
                           "successful_case_overlap" => successful_overlap),
        "suggested_action" => "Use an explicit completion or synthetic probe policy when initialization starts are incomplete; do not infer point-local physical changes from failed builds.",
    ))
    (baseline_dense_budget > 0 || candidate_dense_budget > 0) && dense_overlap == 0 &&
        push!(findings, Dict(
            "code" => "multiconductor_point_dense_rank_overlap_empty", "severity" => "warning",
            "observation" => "A dense-rank budget was requested, but no paired fixture has dense rank evidence at both points.",
            "evidence" => Dict("baseline_dense_budget" => baseline_dense_budget,
                               "candidate_dense_budget" => candidate_dense_budget,
                               "dense_rank_pair_available" => dense_overlap),
            "suggested_action" => "Restrict dense checkpoints to small fixtures and retain explicit dense-rank availability in both summaries.",
        ))
    ambiguous_rank_changes = count(row -> row["rank_change_classification"] in
        ("alignment_ambiguous", "mode_semantics_alignment_ambiguous"), paired)
    ambiguous_rank_changes > 0 && push!(findings, Dict(
        "code" => "multiconductor_point_rank_alignment_ambiguous", "severity" => "warning",
        "observation" => "Dense rank changed for a paired fixture whose declared physical modes are not coordinate-aligned; terminal port maps may still be complete.",
        "evidence" => Dict("ambiguous_rank_change_count" => ambiguous_rank_changes,
                           "dense_rank_change_count" => dense_rank_changes,
                           "alignment_blocked_case_count" => alignment_blocked),
        "suggested_action" => "Inspect terminal-to-model coordinate maps and source metadata before interpreting the rank change as a physical mode or formulation defect.",
    ))
    readiness = Dict{String,Any}(
        "paired_case_coverage" => isempty(missing_baseline) && isempty(missing_candidate) && !isempty(paired),
        "environment_compatible" => same_environment,
        "distinct_point_policies" => baseline_policy != candidate_policy,
        "comparison_available" => !isempty(paired) && same_environment &&
            baseline_policy != candidate_policy && isempty(missing_baseline) &&
            isempty(missing_candidate) && successful_overlap > 0,
        "successful_case_overlap" => successful_overlap,
        "baseline_dense_budget" => baseline_dense_budget,
        "candidate_dense_budget" => candidate_dense_budget,
        "dense_rank_pair_available" => dense_overlap,
        "dense_rank_change_count" => dense_rank_changes,
        "alignment_pair_available" => alignment_available == dense_overlap && dense_overlap > 0,
        "alignment_blocked_case_count" => alignment_blocked,
        "aligned_case_count" => alignment_available,
        "port_map_alignment_pair_complete" => port_map_complete == dense_overlap && dense_overlap > 0,
        "port_map_complete_case_count" => port_map_complete,
        "ambiguous_rank_change_count" => ambiguous_rank_changes,
    )
    payload = Dict{String,Any}(
        "report_version" => "bmopf-multiconductor-point-comparison-v1",
        "baseline_summary" => baseline_path, "candidate_summary" => candidate_path,
        "baseline_point_policy" => baseline_policy, "candidate_point_policy" => candidate_policy,
        "paired_case_count" => length(paired), "missing_from_baseline" => missing_baseline,
        "missing_from_candidate" => missing_candidate, "comparisons" => paired,
        "readiness" => readiness, "findings" => findings,
        "interpretation" => "Point-policy comparison is local and representational evidence; changes are not physical certificates or solver-quality scores.",
    )
    write(output_path, JSON.json(payload))
    println("wrote multiconductor point comparison to $output_path")
end

main()
