#!/usr/bin/env julia

"""Correlate structural policy deltas with auxiliary family-omission evidence."""

using JSON

Base.include(@__MODULE__, joinpath(@__DIR__, "common.jl"))
using .NLPDiagnosticsBenchmarkCommon: write_json

_dict(value) = value isa AbstractDict ? Dict{String,Any}(string(k) => v for (k, v) in value) : Dict{String,Any}()
_key(entry) = string(get(entry, "case", "unknown"), "|max_iter=", get(entry, "budget", "unknown"))

function _map_entries(payload)
    result = Dict{String,Any}()
    for raw in get(payload, "entries", Any[])
        entry = _dict(raw)
        isempty(entry) || (result[_key(entry)] = entry)
    end
    return result
end

function _variant_view(raw)
    variant = _dict(raw)
    perturbation = _dict(get(variant, "row_family_perturbation", nothing))
    findings = _dict(get(perturbation, "finding_codes", nothing))
    return Dict{String,Any}(
        "status" => get(variant, "status", "unavailable"),
        "termination" => get(variant, "termination", nothing),
        "termination_changed_vs_baseline" => get(variant,
            "termination_changed_vs_baseline", false),
        "iteration_delta_vs_baseline" => get(variant,
            "iteration_delta_vs_baseline", nothing),
        "baseline_rank" => get(perturbation, "baseline_rank", nothing),
        "baseline_right_nullity" => get(perturbation, "baseline_right_nullity", nothing),
        "rank_effect_family_count" => get(perturbation,
            "rank_effect_family_count", get(findings,
                "jacobian_row_family_perturbation_rank_effect", 0)),
        "no_rank_effect_family_count" => get(perturbation,
            "no_rank_effect_family_count", get(findings,
                "jacobian_row_family_perturbation_no_rank_effect", 0)),
    )
end

function main()
    length(ARGS) in (2, 3) || error(
        "usage: correlate_bmopf_structural_family_omission.jl <structural-comparison.json> <family-matrix.json> [output.json]",
    )
    structural_path, family_path = abspath.(ARGS[1:2])
    output_path = length(ARGS) == 3 ? abspath(ARGS[3]) :
        joinpath(dirname(structural_path), "structural_family_omission_correlation.json")
    structural = JSON.parsefile(structural_path)
    family = JSON.parsefile(family_path)
    family_entries = _map_entries(family)
    rows = Dict{String,Any}[]
    for raw_row in get(structural, "rows", Any[])
        row = _dict(raw_row)
        key = String(get(row, "key", "unknown"))
        entry = get(family_entries, key, Dict{String,Any}())
        variants_raw = _dict(get(entry, "family_perturbation_by_family", nothing))
        variants = Dict{String,Any}(
            family_name => _variant_view(variant)
            for (family_name, variant) in variants_raw
        )
        structural_deltas = _dict(get(row, "active_set_deltas_vs_baseline", nothing))
        zero_delta = _dict(get(structural_deltas, "zero", nothing))
        load = _dict(get(variants, "load", nothing))
        ibr = _dict(get(variants, "ibr", nothing))
        load_sensitive = get(load, "termination_changed_vs_baseline", false) === true ||
            (get(load, "iteration_delta_vs_baseline", 0) isa Number &&
             get(load, "iteration_delta_vs_baseline", 0) != 0)
        ibr_sensitive = get(ibr, "termination_changed_vs_baseline", false) === true ||
            (get(ibr, "iteration_delta_vs_baseline", 0) isa Number &&
             get(ibr, "iteration_delta_vs_baseline", 0) != 0)
        endpoint_changed = get(row, "active_set_changed", false) === true ||
            get(row, "classification_changed", false) === true
        push!(rows, Dict{String,Any}(
            "key" => key,
            "structural" => Dict(
                "classification_changed" => get(row, "classification_changed", false),
                "active_set_changed" => get(row, "active_set_changed", false),
                "row_family_scale_changed" => get(row, "row_family_scale_changed", false),
                "zero_active_row_count_delta" => get(zero_delta, "active_row_count_delta", nothing),
                "zero_violated_row_symmetric_difference_count" => get(zero_delta,
                    "violated_row_symmetric_difference_count", nothing),
                "zero_maximum_feasibility_violation_delta" => get(zero_delta,
                    "maximum_feasibility_violation_delta", nothing),
            ),
            "family_omission" => variants,
            "load_omission_sensitive" => load_sensitive,
            "ibr_omission_sensitive" => ibr_sensitive,
            "endpoint_change_and_load_sensitivity_cooccur" => endpoint_changed && load_sensitive,
            "endpoint_change_and_ibr_sensitivity_cooccur" => endpoint_changed && ibr_sensitive,
            "interpretation" => endpoint_changed && load_sensitive ?
                "Local endpoint sensitivity co-occurs with load-family omission sensitivity; this is prioritization evidence, not causality." :
                endpoint_changed && ibr_sensitive ?
                "Local endpoint sensitivity co-occurs with IBR-family omission sensitivity; this is prioritization evidence, not causality." :
                "No co-occurrence claim is made for this pair.",
        ))
    end
    readiness = Dict{String,Any}(
        "all_structural_rows_have_family_entries" => all(row ->
            haskey(family_entries, row["key"]), rows),
        "all_requested_load_and_ibr_variants_present" => all(row ->
            haskey(row["family_omission"], "load") &&
            haskey(row["family_omission"], "ibr"), rows),
        "structural_comparison_ready" => get(structural, "readiness", Dict()) isa AbstractDict,
    )
    payload = Dict{String,Any}(
        "correlation_version" => "bmopf-structural-family-omission-correlation-v1",
        "structural_comparison" => structural_path,
        "family_matrix" => family_path,
        "rows" => rows,
        "readiness" => readiness,
        "cooccurring_load_sensitivity_count" => count(row ->
            get(row, "endpoint_change_and_load_sensitivity_cooccur", false), rows),
        "cooccurring_ibr_sensitivity_count" => count(row ->
            get(row, "endpoint_change_and_ibr_sensitivity_cooccur", false), rows),
    )
    write_json(output_path, payload)
    println("wrote structural/family-omission correlation to $output_path")
end

main()
