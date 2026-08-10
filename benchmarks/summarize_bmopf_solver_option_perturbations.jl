#!/usr/bin/env julia

"""Summarize bounded solver-option perturbation matrices."""

using JSON

_dict(value) = value isa AbstractDict ? Dict{String,Any}(string(k) => v for (k, v) in value) : Dict{String,Any}()

function _row_peak(trace)
    peak = Dict{String,Float64}()
    for raw_row in get(_dict(trace), "rows", Any[])
        for (family, raw_family) in _dict(get(_dict(raw_row), "families", nothing))
            value = get(_dict(raw_family), "max_feasibility_violation", nothing)
            value isa Number && isfinite(Float64(value)) &&
                (peak[family] = max(get(peak, family, 0.0), Float64(value)))
        end
    end
    return [Dict{String,Any}("family" => family, "peak" => value)
            for (family, value) in first(sort!(collect(peak); by = pair -> (-pair.second, pair.first)),
                min(length(peak), 5))]
end

function _record(entry, profile, options, policy)
    summary_path = get(entry, "summary_path", nothing)
    summary_path isa AbstractString && isfile(summary_path) || return nothing
    summary = JSON.parsefile(summary_path)
    cases = get(summary, "cases", Any[])
    isempty(cases) && return nothing
    case = _dict(first(cases))
    trace = _dict(get(case, "trace", nothing))
    residual = _dict(get(case, "row_family_residual_trace", nothing))
    phases = _dict(get(trace, "phase_counts", nothing))
    final_primal = get(trace, "final_primal_infeasibility", nothing)
    final_dual = get(trace, "final_dual_infeasibility", nothing)
    endpoint_failure = (final_primal isa Number && abs(Float64(final_primal)) > 1.0e-6) ||
        (final_dual isa Number && abs(Float64(final_dual)) > 1.0e-6)
    return Dict{String,Any}(
        "key" => string(get(entry, "case", get(case, "snapshot", "unknown")),
            "|max_iter=", get(entry, "budget", "unknown")),
        "case" => get(entry, "case", get(case, "snapshot", "unknown")),
        "budget" => get(entry, "budget", nothing),
        "profile" => profile,
        "options" => options,
        "initialization_policy" => policy,
        "classification" => get(entry, "classification", "unavailable"),
        "trace_record_count" => get(trace, "record_count", nothing),
        "phase_counts" => phases,
        "restoration_record_count" => get(phases, "restoration", 0),
        "final_primal_infeasibility" => final_primal,
        "final_dual_infeasibility" => final_dual,
        "endpoint_residual_failure_signature" => endpoint_failure,
        "row_family_residual_status" => get(residual, "status", "unavailable"),
        "largest_family_peak_residuals" => _row_peak(residual),
    )
end

function main()
    length(ARGS) in (1, 2) || error(
        "usage: summarize_bmopf_solver_option_perturbations.jl <manifest.json> [output.json]",
    )
    manifest_path = abspath(ARGS[1])
    output_path = length(ARGS) == 2 ? abspath(ARGS[2]) :
        joinpath(dirname(manifest_path), "option_perturbation_summary.json")
    manifest = JSON.parsefile(manifest_path)
    observations = Dict{String,Any}[]
    missing = String[]
    for raw_entry in get(manifest, "entries", Any[])
        entry = _dict(raw_entry)
        matrix_path = get(entry, "matrix_path", nothing)
        matrix_path isa AbstractString && isfile(matrix_path) || begin
            push!(missing, String(get(entry, "label", "unknown")))
            continue
        end
        matrix = JSON.parsefile(matrix_path)
        for raw_matrix_entry in get(matrix, "entries", Any[])
            matrix_entry = _dict(raw_matrix_entry)
            row = _record(matrix_entry, get(entry, "profile", "unknown"),
                get(entry, "options", ""), get(entry, "initialization_policy", "unknown"))
            isnothing(row) ? push!(missing, String(get(entry, "label", "unknown"))) : push!(observations, row)
        end
    end
    baseline = Dict{Tuple{String,String,String},Dict{String,Any}}()
    for observation in observations
        observation["profile"] == "baseline" || continue
        baseline[(observation["case"], string(observation["budget"]),
            observation["initialization_policy"])] = observation
    end
    comparisons = Dict{String,Any}[]
    for observation in observations
        observation["profile"] == "baseline" && continue
        base = get(baseline, (observation["case"], string(observation["budget"]),
            observation["initialization_policy"]), nothing)
        isnothing(base) && continue
        push!(comparisons, Dict{String,Any}(
            "key" => observation["key"],
            "profile" => observation["profile"],
            "initialization_policy" => observation["initialization_policy"],
            "classification_changed" => observation["classification"] != base["classification"],
            "restoration_signature_changed" => observation["restoration_record_count"] !=
                base["restoration_record_count"],
            "endpoint_residual_signature_changed" => observation[
                "endpoint_residual_failure_signature"] != base[
                "endpoint_residual_failure_signature"],
            "trace_record_count_delta" => observation["trace_record_count"] isa Number &&
                base["trace_record_count"] isa Number ? observation["trace_record_count"] -
                base["trace_record_count"] : nothing,
            "baseline" => base,
            "perturbed" => observation,
        ))
    end
    output = Dict{String,Any}(
        "report_version" => "bmopf-solver-option-perturbation-v1",
        "manifest" => manifest_path,
        "observations" => observations,
        "comparisons_vs_baseline" => comparisons,
        "missing_records" => unique(missing),
        "readiness" => Dict{String,Any}(
            "all_matrix_files_present" => isempty(missing),
            "observation_count_positive" => !isempty(observations),
            "baseline_comparisons_available" => !isempty(comparisons),
        ),
        "interpretation" =>
            "Option perturbations test persistence of observed signatures under controlled solver changes; they do not establish causality or formulation correctness.",
    )
    write(output_path, JSON.json(output))
    println("wrote solver-option perturbation summary to $output_path")
end

main()
