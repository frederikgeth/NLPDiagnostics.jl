#!/usr/bin/env julia

"""Compare two BMOPF multiconductor point-policy summaries.

The comparison is deliberately point-local. It reports contract, physical-mode,
iterative-probe, and independent smallest-direction crosscheck changes without
promoting them to physical or rank claims.
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
        "physical_mode_projections", "physical_mode_projection_matches",
        "port_assembly_component_count", "port_assembly_connected_component_count",
    )
    Dict(key => get(raw, key, nothing) for key in fields)
end

function _structural_contract(contract)
    excluded = Set(("voltage_coordinate_alignment", "current_coordinate_alignment",
                    "physical_mode_projections", "physical_mode_projection_matches"))
    Dict(key => value for (key, value) in contract if !(key in excluded))
end

function _mode_projections(contract)
    raw = _dict(get(contract, "physical_mode_projections", nothing))
    counts = _dict(get(raw, "status_counts", nothing))
    Dict(
        "mode_count" => _int(get(raw, "mode_count", 0)),
        "visible_count" => _int(get(raw, "visible_count", get(counts, "visible", 0))),
        "hidden_count" => _int(get(raw, "hidden_count", get(counts, "hidden", 0))),
        "unrepresented_count" => _int(get(raw, "unrepresented_count", get(counts, "unrepresented", 0))),
        "status_counts" => counts,
        "rows" => get(raw, "rows", Any[]),
    )
end

function _mode_matches(contract)
    raw = _dict(get(contract, "physical_mode_projection_matches", nothing))
    counts = _dict(get(raw, "status_counts", nothing))
    Dict(
        "mode_count" => _int(get(raw, "mode_count", 0)),
        "observed_count" => _int(get(raw, "observed_count", get(counts, "observed", 0))),
        "not_observed_count" => _int(get(raw, "not_observed_count", get(counts, "not_observed", 0))),
        "outside_free_coordinates_count" => _int(get(raw, "outside_free_coordinates_count", get(counts, "outside_free_coordinates", 0))),
        "partial_alignment_count" => _int(get(raw, "partial_alignment_count", get(counts, "partial_alignment", 0))),
        "projected_observed_count" => _int(get(raw, "projected_observed_count", get(counts, "projected_observed", 0))),
        "projected_not_observed_count" => _int(get(raw, "projected_not_observed_count", get(counts, "projected_not_observed", 0))),
        "tangent_observed_count" => _int(get(raw, "tangent_observed_count", get(counts, "tangent_observed", 0))),
        "tangent_not_observed_count" => _int(get(raw, "tangent_not_observed_count", get(counts, "tangent_not_observed", 0))),
        "projection_policies" => sort!(unique(String(get(row, "projection_policy", "strict"))
            for row in get(raw, "rows", Any[]))),
        "status_counts" => counts,
        "rows" => get(raw, "rows", Any[]),
    )
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
        "tangent_observed_mode_count" => _int(get(raw, "tangent_observed_mode_count", 0)),
        "tangent_not_observed_mode_count" => _int(get(raw, "tangent_not_observed_mode_count", 0)),
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

function _smallest_crosscheck(case)
    raw = _dict(get(case, "smallest_singular_backend_crosscheck", nothing))
    differences = Float64[]
    for value in get(raw, "relative_value_differences", Any[])
        parsed = _float(value)
        isnothing(parsed) || push!(differences, parsed)
    end
    Dict(
        "requested_dimension" => _int(get(raw, "requested_dimension", 0)),
        "available" => _bool(get(raw, "available", false)),
        "relation" => String(get(raw, "relation", "not_requested")),
        "restarted_converged" => _bool(get(raw, "restarted_converged", false)),
        "harmonic_converged" => _bool(get(raw, "harmonic_converged", false)),
        "maximum_relative_value_difference" =>
            (isempty(differences) ? nothing : maximum(differences)),
        "minimum_principal_cosine" =>
            _float(get(raw, "minimum_principal_cosine", nothing)),
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
    baseline_mode_policy = get(baseline, "expected_mode_free_coordinate_policy",
        get(baseline_first_case, "expected_mode_free_coordinate_policy", "unknown"))
    candidate_mode_policy = get(candidate, "expected_mode_free_coordinate_policy",
        get(candidate_first_case, "expected_mode_free_coordinate_policy", "unknown"))
    baseline_tangent_policy = get(baseline, "expected_mode_tangent_policy",
        get(baseline_first_case, "expected_mode_tangent_policy", "unknown"))
    candidate_tangent_policy = get(candidate, "expected_mode_tangent_policy",
        get(candidate_first_case, "expected_mode_tangent_policy", "unknown"))
    baseline_dense_budget = _int(get(baseline, "rank_max_dense_entries",
        get(baseline_first_case, "rank_max_dense_entries", 0)))
    candidate_dense_budget = _int(get(candidate, "rank_max_dense_entries",
        get(candidate_first_case, "rank_max_dense_entries", 0)))
    paired = Any[]
    for name in names
        left, right = baseline_cases[name], candidate_cases[name]
        left_contract, right_contract = _contract(left), _contract(right)
        left_structural_contract, right_structural_contract =
            _structural_contract(left_contract), _structural_contract(right_contract)
        left_mode_projections = _mode_projections(left_contract)
        right_mode_projections = _mode_projections(right_contract)
        left_mode_matches = _mode_matches(left_contract)
        right_mode_matches = _mode_matches(right_contract)
        left_voltage_alignment = _alignment(left_contract, "voltage_coordinate_alignment")
        right_voltage_alignment = _alignment(right_contract, "voltage_coordinate_alignment")
        left_current_alignment = _alignment(left_contract, "current_coordinate_alignment")
        right_current_alignment = _alignment(right_contract, "current_coordinate_alignment")
        left_modes, right_modes = _modes(left), _modes(right)
        left_probe, right_probe = _probe(left), _probe(right)
        left_crosscheck, right_crosscheck =
            _smallest_crosscheck(left), _smallest_crosscheck(right)
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
            "contract_changed" => left_structural_contract != right_structural_contract,
            "baseline_voltage_alignment" => left_voltage_alignment,
            "candidate_voltage_alignment" => right_voltage_alignment,
            "voltage_alignment_changed" => left_voltage_alignment != right_voltage_alignment,
            "baseline_current_alignment" => left_current_alignment,
            "candidate_current_alignment" => right_current_alignment,
            "current_alignment_changed" => left_current_alignment != right_current_alignment,
            "baseline_mode_projections" => left_mode_projections,
            "candidate_mode_projections" => right_mode_projections,
            "mode_projection_status_changed" => left_mode_projections["status_counts"] != right_mode_projections["status_counts"],
            "baseline_mode_matches" => left_mode_matches,
            "candidate_mode_matches" => right_mode_matches,
            "mode_match_status_changed" => left_mode_matches["status_counts"] != right_mode_matches["status_counts"],
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
            "baseline_smallest_crosscheck" => left_crosscheck,
            "candidate_smallest_crosscheck" => right_crosscheck,
            "smallest_crosscheck_dimension_aligned" =>
                left_crosscheck["requested_dimension"] ==
                right_crosscheck["requested_dimension"],
            "smallest_crosscheck_availability_changed" =>
                left_crosscheck["available"] != right_crosscheck["available"],
            "smallest_crosscheck_relation_changed" =>
                left_crosscheck["relation"] != right_crosscheck["relation"],
            "smallest_crosscheck_restarted_convergence_changed" =>
                left_crosscheck["restarted_converged"] !=
                right_crosscheck["restarted_converged"],
            "smallest_crosscheck_harmonic_convergence_changed" =>
                left_crosscheck["harmonic_converged"] !=
                right_crosscheck["harmonic_converged"],
            "smallest_crosscheck_maximum_relative_value_difference_delta" => _delta(
                left_crosscheck["maximum_relative_value_difference"],
                right_crosscheck["maximum_relative_value_difference"],
            ),
            "smallest_crosscheck_minimum_principal_cosine_delta" => _delta(
                left_crosscheck["minimum_principal_cosine"],
                right_crosscheck["minimum_principal_cosine"],
            ),
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
    mode_projection_available = count(row -> row["baseline_mode_projections"]["mode_count"] > 0 &&
        row["candidate_mode_projections"]["mode_count"] > 0, paired)
    mode_projection_status_changes = count(row -> row["mode_projection_status_changed"], paired)
    mode_match_available = count(row -> row["baseline_mode_matches"]["mode_count"] > 0 &&
        row["candidate_mode_matches"]["mode_count"] > 0, paired)
    mode_match_status_changes = count(row -> row["mode_match_status_changed"], paired)
    crosscheck_requested_overlap = count(row ->
        row["baseline_smallest_crosscheck"]["requested_dimension"] > 0 &&
        row["candidate_smallest_crosscheck"]["requested_dimension"] > 0, paired)
    crosscheck_available_overlap = count(row ->
        row["baseline_smallest_crosscheck"]["available"] &&
        row["candidate_smallest_crosscheck"]["available"], paired)
    crosscheck_dimension_aligned = count(row ->
        row["smallest_crosscheck_dimension_aligned"], paired)
    crosscheck_relation_changes = count(row ->
        row["smallest_crosscheck_relation_changed"] &&
        row["baseline_smallest_crosscheck"]["available"] &&
        row["candidate_smallest_crosscheck"]["available"], paired)
    crosscheck_convergence_changes = count(row ->
        row["smallest_crosscheck_restarted_convergence_changed"] ||
        row["smallest_crosscheck_harmonic_convergence_changed"], paired)
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
    baseline_mode_policy == candidate_mode_policy || push!(findings, Dict(
        "code" => "multiconductor_point_mode_projection_policy_mismatch", "severity" => "warning",
        "observation" => "The paired summaries used different expected-mode free-coordinate projection policies.",
        "evidence" => Dict("baseline_policy" => baseline_mode_policy,
                           "candidate_policy" => candidate_mode_policy),
        "suggested_action" => "Use the same strict or project_free mode policy before comparing point-local mode statuses.",
    ))
    baseline_tangent_policy == candidate_tangent_policy || push!(findings, Dict(
        "code" => "multiconductor_point_mode_tangent_policy_mismatch", "severity" => "warning",
        "observation" => "The paired summaries used different plugin-specific expected-mode tangent policies.",
        "evidence" => Dict("baseline_policy" => baseline_tangent_policy,
                           "candidate_policy" => candidate_tangent_policy),
        "suggested_action" => "Use the same tangent-coordinate scope before comparing local expected-mode statuses.",
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
    crosscheck_requested_overlap > crosscheck_available_overlap && push!(findings, Dict(
        "code" => "multiconductor_point_smallest_crosscheck_overlap_incomplete",
        "severity" => "warning",
        "observation" => "The smallest-direction backend crosscheck was requested at both points but was not available for every paired fixture.",
        "evidence" => Dict("requested_pair_count" => crosscheck_requested_overlap,
                           "available_pair_count" => crosscheck_available_overlap),
        "suggested_action" => "Inspect the product-path and basis-guard evidence before comparing point-local candidate relations.",
    ))
    crosscheck_relation_changes > 0 && push!(findings, Dict(
        "code" => "multiconductor_point_smallest_crosscheck_relation_changed",
        "severity" => "info",
        "observation" => "One or more paired fixtures changed independent-backend relation across evaluation points.",
        "evidence" => Dict("relation_change_count" => crosscheck_relation_changes,
                           "convergence_change_count" => crosscheck_convergence_changes),
        "suggested_action" => "Inspect convergence flags, value differences, and principal-angle evidence before attributing the change to model geometry.",
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
        "mode_projection_pair_available" => mode_projection_available == dense_overlap && dense_overlap > 0,
        "mode_projection_available_case_count" => mode_projection_available,
        "mode_projection_status_change_count" => mode_projection_status_changes,
        "mode_match_pair_available" => mode_match_available == dense_overlap && dense_overlap > 0,
        "mode_match_available_case_count" => mode_match_available,
        "mode_match_status_change_count" => mode_match_status_changes,
        "mode_projection_policy_compatible" => baseline_mode_policy == candidate_mode_policy,
        "baseline_mode_projection_policy" => baseline_mode_policy,
        "candidate_mode_projection_policy" => candidate_mode_policy,
        "mode_tangent_policy_compatible" => baseline_tangent_policy == candidate_tangent_policy,
        "baseline_mode_tangent_policy" => baseline_tangent_policy,
        "candidate_mode_tangent_policy" => candidate_tangent_policy,
        "ambiguous_rank_change_count" => ambiguous_rank_changes,
        "smallest_crosscheck_requested_pair_count" => crosscheck_requested_overlap,
        "smallest_crosscheck_available_pair_count" => crosscheck_available_overlap,
        "smallest_crosscheck_pair_available" => crosscheck_requested_overlap == 0 ||
            crosscheck_available_overlap == crosscheck_requested_overlap,
        "smallest_crosscheck_dimension_aligned" =>
            crosscheck_dimension_aligned == length(paired),
        "smallest_crosscheck_relation_change_count" => crosscheck_relation_changes,
        "smallest_crosscheck_convergence_change_count" =>
            crosscheck_convergence_changes,
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
