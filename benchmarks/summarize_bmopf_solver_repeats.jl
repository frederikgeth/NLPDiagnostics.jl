#!/usr/bin/env julia

"""Summarize repeated BMOPF solver-option sweep manifests.

The report aligns configuration/case observations across explicitly supplied
sweep manifests. It reports termination, iteration, objective, and numerical
readiness recurrence, but deliberately does not rank configurations or infer
causality from a repeated iteration delta.
"""

include(joinpath(@__DIR__, "common.jl"))
using .NLPDiagnosticsBenchmarkCommon

function _dict(value)
    value isa AbstractDict ? Dict{String,Any}(string(k) => v for (k, v) in value) : Dict{String,Any}()
end

function _number(value)
    value isa Real && isfinite(Float64(value)) && return Float64(value)
    value isa AbstractString || return nothing
    parsed = tryparse(Float64, strip(String(value)))
    parsed isa Real && isfinite(parsed) ? Float64(parsed) : nothing
end

function _int(value)
    number = _number(value)
    isnothing(number) ? 0 : Int(round(number))
end

function _delta(left, right)
    l, r = _number(left), _number(right)
    isnothing(l) || isnothing(r) ? nothing : r - l
end

function _summary_path(entry)
    path = get(entry, "summary_file", nothing)
    isnothing(path) && return nothing
    absolute = abspath(String(path))
    isfile(absolute) ? absolute : nothing
end

function _case_name(case)
    String(get(case, "name", get(case, "snapshot", get(case, "relative", "unknown"))))
end

function _numerical(case)
    raw = _dict(get(case, "numerical_profile", nothing))
    metadata = _dict(get(raw, "metadata", nothing))
    codes = _dict(get(case, "numerical_finding_codes", get(raw, "finding_code_counts", Dict())))
    dense_available = lowercase(String(get(metadata, "jacobian_rank_available", "false"))) == "true"
    sparse_available = lowercase(String(get(metadata, "sparse_qr_rank_available", "false"))) == "true"
    Dict(
        "available" => !isempty(raw),
        "readiness" => !isempty(raw) ?
            (sparse_available && dense_available ? "dense_and_sparse_available" :
             sparse_available ? "sparse_available_dense_unavailable" :
             dense_available ? "dense_available_sparse_unavailable" : "rank_unavailable") : "unavailable",
        "dense_rank_available" => dense_available,
        "sparse_qr_available" => sparse_available,
        "sparse_qr_rank" => sparse_available ? _number(get(metadata, "sparse_qr_rank", nothing)) : nothing,
        "sparse_qr_condition_proxy" => sparse_available ? _number(get(metadata, "sparse_qr_condition_proxy", nothing)) : nothing,
        "rank_max_dense_entries" => get(metadata, "rank_max_dense_entries", nothing),
        "finding_codes" => codes,
    )
end

function _semantic(case)
    families = _dict(get(case, "solver_rank_semantic_family_counts", nothing))
    profile = get(case, "bmopf_profile", nothing)
    context = get(case, "bmopf_context_profile", nothing)
    context_codes = _dict(get(case, "bmopf_context_finding_codes", nothing))
    available = profile isa AbstractDict || context isa AbstractDict || !isempty(families)
    finding_codes = Dict{String,Any}()
    merge!(finding_codes, _dict(get(case, "bmopf_profile_finding_codes", nothing)))
    merge!(finding_codes, context_codes)
    Dict(
        "available" => available,
        "family_counts" => families,
        "profile_finding_codes" => _dict(get(case, "bmopf_profile_finding_codes", nothing)),
        "context_finding_codes" => context_codes,
        "finding_codes" => finding_codes,
    )
end

function _row_family_scale(case, summary_directory = nothing)
    raw = _dict(get(case, "bmopf_jacobian_row_family_scale_attribution", nothing))
    # A solver-trace summary already contains the compact normalized form
    # (row_scale_ratio/family extrema at the top level), whereas a raw result
    # record stores the same values under `global`.  Accept both envelopes so
    # policy comparisons do not silently discard available attribution.
    if haskey(raw, "row_scale_ratio")
        return Dict(
            "available" => get(raw, "available", true),
            "row_scale_ratio" => _number(get(raw, "row_scale_ratio", nothing)),
            "global_minimum_families" => get(raw, "global_minimum_families", Any[]),
            "global_maximum_families" => get(raw, "global_maximum_families", Any[]),
        )
    end
    if isempty(_dict(get(raw, "global", nothing))) && summary_directory !== nothing
        result_file = get(case, "result_file", nothing)
        if result_file isa AbstractString
            record_path = joinpath(summary_directory, String(result_file))
            if isfile(record_path)
                try
                    record = read_summary(record_path; root = "/")
                    profile = _dict(get(record, "profile", nothing))
                    raw = _dict(get(profile,
                        "bmopf_jacobian_row_family_scale_attribution", nothing))
                catch
                    raw = Dict{String,Any}()
                end
            end
        end
    end
    global_metrics = _dict(get(raw, "global", nothing))
    Dict(
        "available" => !isempty(raw),
        "row_scale_ratio" => _number(get(global_metrics, "row_scale_ratio", nothing)),
        "global_minimum_families" => get(global_metrics, "global_minimum_families", Any[]),
        "global_maximum_families" => get(global_metrics, "global_maximum_families", Any[]),
    )
end

function _observation(case, manifest_index, label, summary_directory = nothing)
    trace = _dict(get(case, "trace", nothing))
    log = _dict(get(case, "solver_log", get(case, "solver_log_iterations", nothing)))
    numerical = _numerical(case)
    semantic = _semantic(case)
    row_family_scale = _row_family_scale(case, summary_directory)
    termination = String(get(case, "termination", "unknown"))
    Dict{String,Any}(
        "manifest_index" => manifest_index,
        "configuration" => label,
        "name" => _case_name(case),
        "status" => get(case, "status", nothing),
        "termination" => termination,
        "successful" => get(case, "successful", false),
        "solver_termination_successful" => termination in ("locally_optimal", "optimal", "solved", "success"),
        "iteration_count" => get(trace, "record_count", get(case, "iteration_count", nothing)),
        "solver_log_iteration_count" => get(log, "record_count", nothing),
        "final_primal_infeasibility" => get(log, "final_primal_infeasibility",
            get(trace, "final_primal_infeasibility", nothing)),
        "final_dual_infeasibility" => get(log, "final_dual_infeasibility",
            get(trace, "final_dual_infeasibility", nothing)),
        "objective" => get(trace, "final_objective", nothing),
        "numerical" => numerical,
        "row_family_scale" => row_family_scale,
        "semantic" => semantic,
        "environment_fingerprint" => get(case, "environment_fingerprint", nothing),
    )
end

function _stable(values)
    cleaned = [value for value in values if !isnothing(value)]
    !isempty(cleaned) && length(unique(string.(cleaned))) == 1
end

function _range(values)
    numbers = [_number(value) for value in values]
    numbers = [value for value in numbers if !isnothing(value)]
    isempty(numbers) ? Dict{String,Any}("available" => false) :
        Dict{String,Any}("available" => true, "minimum" => minimum(numbers),
            "maximum" => maximum(numbers), "spread" => maximum(numbers) - minimum(numbers))
end

function _stable_numeric(values; relative_tolerance = 1.0e-10)
    numbers = [_number(value) for value in values]
    numbers = [value for value in numbers if !isnothing(value)]
    isempty(numbers) && return false
    spread = maximum(numbers) - minimum(numbers)
    scale = max(1.0, maximum(abs, numbers))
    spread <= relative_tolerance * scale
end

function _stable_delta_by_case(rows, key)
    grouped = Dict{String,Vector{Any}}()
    for row in rows
        name = String(get(row, "name", "unknown"))
        delta = _dict(get(row, "delta", nothing))
        push!(get!(grouped, name, Any[]), get(delta, key, nothing))
    end
    isempty(grouped) && return false
    all(_stable_numeric(values) for values in values(grouped))
end

function _recurrence(observations)
    terminations = [get(observation, "termination", nothing) for observation in observations]
    statuses = [get(observation, "status", nothing) for observation in observations]
    numerical = [_dict(get(observation, "numerical", nothing)) for observation in observations]
    row_family_scale = [_dict(get(observation, "row_family_scale", nothing)) for observation in observations]
    ranks = [get(entry, "sparse_qr_rank", nothing) for entry in numerical]
    condition_proxies = [get(entry, "sparse_qr_condition_proxy", nothing) for entry in numerical]
    row_scale_ratios = [get(entry, "row_scale_ratio", nothing) for entry in row_family_scale]
    readiness = [get(entry, "readiness", nothing) for entry in numerical]
    semantic = [_dict(get(observation, "semantic", nothing)) for observation in observations]
    semantic_available = [get(entry, "available", false) for entry in semantic]
    semantic_codes = [get(entry, "finding_codes", Dict()) for entry in semantic]
    Dict(
        "observation_count" => length(observations),
        "termination_values" => sort!(unique(String.(filter(!isnothing, terminations)))),
        "status_values" => sort!(unique(String.(filter(!isnothing, statuses)))),
        "termination_stable" => _stable(terminations),
        "status_stable" => _stable(statuses),
        "iteration_range" => _range(get.(observations, "iteration_count", nothing)),
        "solver_log_iteration_range" => _range(get.(observations, "solver_log_iteration_count", nothing)),
        "objective_range" => _range(get.(observations, "objective", nothing)),
        "final_primal_residual_range" => _range(get.(observations, "final_primal_infeasibility", nothing)),
        "final_dual_residual_range" => _range(get.(observations, "final_dual_infeasibility", nothing)),
        "sparse_qr_rank_range" => _range(ranks),
        "sparse_qr_rank_stable" => _stable(ranks),
        "sparse_qr_condition_proxy_range" => _range(condition_proxies),
        "sparse_qr_condition_proxy_stable" => _stable(condition_proxies),
        "row_family_scale_available" => any(get(entry, "available", false) for entry in row_family_scale),
        "row_family_scale_ratio_range" => _range(row_scale_ratios),
        "row_family_scale_ratio_stable" => _stable(row_scale_ratios),
        "numerical_readiness_values" => sort!(unique(String.(filter(!isnothing, readiness)))),
        "numerical_readiness_stable" => _stable(readiness),
        "semantic_profile_available" => any(identity, semantic_available),
        "semantic_profile_available_stable" => _stable(semantic_available),
        "semantic_family_count_range" => _range([length(_dict(get(entry, "family_counts", nothing))) for entry in semantic]),
        "semantic_finding_codes_stable" => _stable(semantic_codes),
        "environment_fingerprint_values" => sort!(unique(String.(filter(!isnothing,
            get.(observations, "environment_fingerprint", nothing))))),
    )
end

function _paired_delta(baseline, candidate)
    bn = _dict(get(baseline, "numerical", nothing))
    cn = _dict(get(candidate, "numerical", nothing))
    bs = _dict(get(baseline, "semantic", nothing))
    cs = _dict(get(candidate, "semantic", nothing))
    br = _dict(get(baseline, "row_family_scale", nothing))
    cr = _dict(get(candidate, "row_family_scale", nothing))
    Dict(
        "manifest_index" => get(candidate, "manifest_index", nothing),
        "baseline_status" => get(baseline, "status", nothing),
        "candidate_status" => get(candidate, "status", nothing),
        "baseline_termination" => get(baseline, "termination", nothing),
        "candidate_termination" => get(candidate, "termination", nothing),
        "termination_changed" => get(baseline, "termination", nothing) != get(candidate, "termination", nothing),
        "iteration_delta_candidate_minus_baseline" => _delta(
            get(baseline, "iteration_count", nothing), get(candidate, "iteration_count", nothing)),
        "solver_log_iteration_delta_candidate_minus_baseline" => _delta(
            get(baseline, "solver_log_iteration_count", nothing), get(candidate, "solver_log_iteration_count", nothing)),
        "final_primal_residual_delta_candidate_minus_baseline" => _delta(
            get(baseline, "final_primal_infeasibility", nothing), get(candidate, "final_primal_infeasibility", nothing)),
        "final_dual_residual_delta_candidate_minus_baseline" => _delta(
            get(baseline, "final_dual_infeasibility", nothing), get(candidate, "final_dual_infeasibility", nothing)),
        "sparse_qr_rank_delta_candidate_minus_baseline" => _delta(
            get(bn, "sparse_qr_rank", nothing), get(cn, "sparse_qr_rank", nothing)),
        "sparse_qr_condition_proxy_delta_candidate_minus_baseline" => _delta(
            get(bn, "sparse_qr_condition_proxy", nothing),
            get(cn, "sparse_qr_condition_proxy", nothing)),
        "row_family_scale_ratio_delta_candidate_minus_baseline" => _delta(
            get(br, "row_scale_ratio", nothing), get(cr, "row_scale_ratio", nothing)),
        "numerical_readiness_changed" => get(bn, "readiness", nothing) != get(cn, "readiness", nothing),
        "semantic_profile_availability_changed" => get(bs, "available", false) != get(cs, "available", false),
        "semantic_family_counts_changed" => get(bs, "family_counts", Dict()) != get(cs, "family_counts", Dict()),
        "semantic_finding_codes_changed" => get(bs, "finding_codes", Dict()) != get(cs, "finding_codes", Dict()),
    )
end

function _pair_summary(rows)
    deltas = [row["delta"] for row in rows if haskey(row, "delta")]
    iteration_deltas = [get(delta, "iteration_delta_candidate_minus_baseline", nothing) for delta in deltas]
    term_changes = [get(delta, "termination_changed", false) for delta in deltas]
    condition_proxy_deltas = [get(
        delta, "sparse_qr_condition_proxy_delta_candidate_minus_baseline", nothing,
    ) for delta in deltas]
    row_family_deltas = [get(
        delta, "row_family_scale_ratio_delta_candidate_minus_baseline", nothing,
    ) for delta in deltas]
    Dict(
        "paired_replicate_count" => length(deltas),
        "termination_change_count" => count(identity, term_changes),
        "termination_change_stable" => !isempty(term_changes) && length(unique(term_changes)) == 1,
        "iteration_delta_range" => _range(iteration_deltas),
        "iteration_delta_sign_values" => sort!(unique(sign(_number(value)) for value in iteration_deltas if !isnothing(_number(value)))),
        "sparse_qr_rank_delta_range" => _range([get(delta, "sparse_qr_rank_delta_candidate_minus_baseline", nothing) for delta in deltas]),
        "sparse_qr_condition_proxy_delta_range" => _range(condition_proxy_deltas),
        "sparse_qr_condition_proxy_delta_stable" => _stable_delta_by_case(
            rows, "sparse_qr_condition_proxy_delta_candidate_minus_baseline",
        ),
        "row_family_scale_ratio_delta_range" => _range(row_family_deltas),
        "row_family_scale_ratio_delta_stable" => _stable_delta_by_case(
            rows, "row_family_scale_ratio_delta_candidate_minus_baseline",
        ),
        "final_primal_residual_delta_range" => _range([get(delta, "final_primal_residual_delta_candidate_minus_baseline", nothing) for delta in deltas]),
        "final_dual_residual_delta_range" => _range([get(delta, "final_dual_residual_delta_candidate_minus_baseline", nothing) for delta in deltas]),
        "numerical_readiness_change_count" => count(delta -> get(delta, "numerical_readiness_changed", false), deltas),
        "semantic_profile_availability_change_count" => count(delta -> get(delta, "semantic_profile_availability_changed", false), deltas),
        "semantic_family_change_count" => count(delta -> get(delta, "semantic_family_counts_changed", false), deltas),
        "semantic_finding_change_count" => count(delta -> get(delta, "semantic_finding_codes_changed", false), deltas),
        "paired_observations" => deltas,
    )
end

function main()
    isempty(ARGS) && error("usage: summarize_bmopf_solver_repeats.jl <sweep-manifest.json> ...")
    manifests = [abspath(path) for path in ARGS]
    all(isfile, manifests) || error("all repeat inputs must be existing sweep manifests")
    by_configuration = Dict{String,Dict{String,Vector{Any}}}()
    manifest_records = Any[]
    for (manifest_index, manifest_path) in enumerate(manifests)
        manifest = read_summary(manifest_path; root = "/")
        entries = get(manifest, "configurations", Any[])
        push!(manifest_records, Dict(
            "manifest_index" => manifest_index, "path" => manifest_path,
            "environment_fingerprint" => get(manifest, "environment_fingerprint", nothing),
            "configuration_count" => length(entries),
        ))
        for entry in entries
            entry isa AbstractDict || continue
            label = String(get(entry, "label", "unknown"))
            summary_path = _summary_path(entry)
            isnothing(summary_path) && continue
            summary = read_summary(summary_path; root = "/")
            for case in get(summary, "cases", Any[])
                case isa AbstractDict || continue
                cases = get!(by_configuration, label, Dict{String,Vector{Any}}())
                observations = get!(cases, _case_name(case), Any[])
                push!(observations, _observation(
                    case, manifest_index, label, dirname(summary_path),
                ))
            end
        end
    end
    configurations = Dict{String,Any}[]
    for label in sort!(collect(keys(by_configuration)))
        cases = Dict{String,Any}[]
        for case_name in sort!(collect(keys(by_configuration[label])))
            observations = by_configuration[label][case_name]
            push!(cases, Dict("name" => case_name, "observations" => observations,
                "recurrence" => _recurrence(observations)))
        end
        push!(configurations, Dict("label" => label, "case_count" => length(cases), "cases" => cases))
    end
    baseline = get(ENV, "NLPDIAGNOSTICS_BMOPF_REPEAT_BASELINE", "baseline")
    comparisons = Dict{String,Any}[]
    if haskey(by_configuration, baseline)
        base_cases = by_configuration[baseline]
        for label in sort!(collect(keys(by_configuration)))
            label == baseline && continue
            rows = Dict{String,Any}[]
            for case_name in sort!(collect(intersect(keys(base_cases), keys(by_configuration[label]))))
                base_by_manifest = Dict(get(row, "manifest_index", 0) => row for row in base_cases[case_name])
                candidate_by_manifest = Dict(get(row, "manifest_index", 0) => row for row in by_configuration[label][case_name])
                for manifest_index in sort!(collect(intersect(keys(base_by_manifest), keys(candidate_by_manifest))))
                    push!(rows, Dict("name" => case_name,
                        "delta" => _paired_delta(base_by_manifest[manifest_index], candidate_by_manifest[manifest_index])))
                end
            end
            push!(comparisons, Dict("baseline_label" => baseline, "candidate_label" => label,
                "case_count" => length(rows), "summary" => _pair_summary(rows), "comparisons" => rows))
        end
    end
    payload = Dict(
        "report_version" => "bmopf-solver-repeats-v1",
        "manifest_count" => length(manifests), "manifests" => manifest_records,
        "baseline_label" => baseline, "configuration_count" => length(configurations),
        "configurations" => configurations, "comparisons" => comparisons,
        "interpretation" => "Repeated solver-policy observations are descriptive and provenance-scoped; termination, iteration, sparse-rank, and readiness recurrence are not a solver-quality score or causal proof.",
    )
    output = get(ENV, "NLPDIAGNOSTICS_BMOPF_REPEAT_OUTPUT", joinpath(dirname(manifests[1]), "solver_repeat_summary.json"))
    write_json(abspath(output), payload)
    println("wrote repeated solver-sweep summary to $(abspath(output))")
end

main()
