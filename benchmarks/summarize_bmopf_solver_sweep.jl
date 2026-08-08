#!/usr/bin/env julia

"""
Summarize a `sweep_bmopf_solver_options.jl` run.

The output is a comparison matrix, not a score: each configuration is kept
with its effective options, status, solver-log evidence, objective alignment,
and semantic row-family scaling evidence relative to the baseline.
"""

using JSON

function _as_dict(value)
    value isa AbstractDict ? Dict{String,Any}(string(k) => v for (k, v) in value) : Dict{String,Any}()
end

function _as_number(value)
    value isa Real && isfinite(Float64(value)) ? Float64(value) : nothing
end

function _delta(left, right)
    l, r = _as_number(left), _as_number(right)
    isnothing(l) || isnothing(r) ? nothing : r - l
end

function _ratio(left, right)
    l, r = _as_number(left), _as_number(right)
    isnothing(l) || isnothing(r) || l == 0 ? nothing : r / l
end

function _relative_difference(left, right)
    l, r = _as_number(left), _as_number(right)
    isnothing(l) || isnothing(r) ? nothing : abs(r - l) / max(1.0, abs(l), abs(r))
end

function _case_map(summary)
    result = Dict{String,Any}()
    for case in get(summary, "cases", Any[])
        case isa AbstractDict || continue
        key = String(get(case, "name", get(case, "snapshot", get(case, "relative", "unknown"))))
        result[key] = case
    end
    result
end

function _successful(case)
    status = String(get(case, "status", "unknown"))
    termination = lowercase(String(get(case, "termination", "")))
    status == "ok" && termination in ("locally_optimal", "optimal", "solved", "success")
end

function _family_scaling(case)
    raw = _as_dict(get(case, "bmopf_jacobian_row_family_scaling_experiment", nothing))
    families = _as_dict(get(raw, "families", nothing))
    result = Dict{String,Any}()
    for (family, raw_entry) in families
        entry = _as_dict(raw_entry)
        result[String(family)] = Dict{String,Any}(
            "available" => get(entry, "available", false),
            "condition_proxy_ratio" => get(entry, "condition_proxy_ratio", nothing),
            "rank_delta" => get(entry, "rank_delta", nothing),
            "baseline_condition_proxy" => get(entry, "baseline_condition_proxy", nothing),
            "scaled_condition_proxy" => get(entry, "scaled_condition_proxy", nothing),
            "minimum_scale_factor" => get(entry, "minimum_scale_factor", nothing),
            "maximum_scale_factor" => get(entry, "maximum_scale_factor", nothing),
        )
    end
    return Dict{String,Any}(
        "available" => get(raw, "available", false),
        "families" => result,
    )
end

function _case_observation(case)
    trace = _as_dict(get(case, "trace", nothing))
    log = _as_dict(get(case, "solver_log_iterations", nothing))
    family = _family_scaling(case)
    return Dict{String,Any}(
        "name" => get(case, "name", nothing),
        "status" => get(case, "status", nothing),
        "termination" => get(case, "termination", nothing),
        "successful" => _successful(case),
        "iteration_count" => get(case, "iteration_count", nothing),
        "trace" => Dict(
            "record_count" => get(trace, "record_count", nothing),
            "final_iteration" => get(trace, "final_iteration", nothing),
            "final_objective" => get(trace, "final_objective", nothing),
            "final_primal_infeasibility" => get(trace, "final_primal_infeasibility", nothing),
            "final_dual_infeasibility" => get(trace, "final_dual_infeasibility", nothing),
        ),
        "solver_log" => Dict(
            "available" => get(case, "solver_log_available", false),
            "record_count" => get(log, "record_count", nothing),
            "final_iteration" => get(log, "final_iteration", nothing),
            "final_primal_infeasibility" => get(log, "final_primal_infeasibility", nothing),
            "final_dual_infeasibility" => get(log, "final_dual_infeasibility", nothing),
            "finding_codes" => get(case, "solver_log_finding_codes", Dict()),
        ),
        "solver_result_finding_codes" => get(case, "solver_result_finding_codes", Dict()),
        "failure_categories" => get(case, "failure_categories", Any[]),
        "family_scaling" => family,
    )
end

function _compare_case(base, candidate)
    bt = _as_dict(get(base, "trace", nothing))
    ct = _as_dict(get(candidate, "trace", nothing))
    bl = _as_dict(get(base, "solver_log", nothing))
    cl = _as_dict(get(candidate, "solver_log", nothing))
    base_objective = get(bt, "final_objective", nothing)
    candidate_objective = get(ct, "final_objective", nothing)
    objective_difference = _relative_difference(base_objective, candidate_objective)
    objective_alignment = isnothing(objective_difference) ? "unavailable" :
        (objective_difference <= 1.0e-6 ? "aligned" : "different_convention_or_solution")
    base_family = _as_dict(get(base, "family_scaling", nothing))
    candidate_family = _as_dict(get(candidate, "family_scaling", nothing))
    family_comparisons = Dict{String,Any}[]
    family_names = sort!(collect(union(keys(_as_dict(get(base_family, "families", nothing))),
                                  keys(_as_dict(get(candidate_family, "families", nothing))))))
    for family in family_names
        b = _as_dict(get(_as_dict(get(base_family, "families", nothing)), family, nothing))
        c = _as_dict(get(_as_dict(get(candidate_family, "families", nothing)), family, nothing))
        push!(family_comparisons, Dict{String,Any}(
            "family" => family,
            "baseline" => b,
            "candidate" => c,
            "condition_proxy_ratio_delta" => _delta(get(b, "condition_proxy_ratio", nothing), get(c, "condition_proxy_ratio", nothing)),
            "rank_delta_difference" => _delta(get(b, "rank_delta", nothing), get(c, "rank_delta", nothing)),
        ))
    end
    return Dict{String,Any}(
        "name" => get(candidate, "name", nothing),
        "baseline_status" => get(base, "status", nothing),
        "candidate_status" => get(candidate, "status", nothing),
        "baseline_termination" => get(base, "termination", nothing),
        "candidate_termination" => get(candidate, "termination", nothing),
        "baseline_successful" => get(base, "successful", false),
        "candidate_successful" => get(candidate, "successful", false),
        "iteration_count" => Dict(
            "baseline" => get(bt, "record_count", nothing),
            "candidate" => get(ct, "record_count", nothing),
            "delta_candidate_minus_baseline" => _delta(get(bt, "record_count", nothing), get(ct, "record_count", nothing)),
        ),
        "solver_log_iteration_count" => Dict(
            "baseline" => get(bl, "record_count", nothing),
            "candidate" => get(cl, "record_count", nothing),
            "delta_candidate_minus_baseline" => _delta(get(bl, "record_count", nothing), get(cl, "record_count", nothing)),
        ),
        "final_primal_infeasibility" => Dict(
            "baseline" => get(bl, "final_primal_infeasibility", get(bt, "final_primal_infeasibility", nothing)),
            "candidate" => get(cl, "final_primal_infeasibility", get(ct, "final_primal_infeasibility", nothing)),
            "delta_candidate_minus_baseline" => _delta(
                get(bl, "final_primal_infeasibility", get(bt, "final_primal_infeasibility", nothing)),
                get(cl, "final_primal_infeasibility", get(ct, "final_primal_infeasibility", nothing)),
            ),
            "ratio_candidate_over_baseline" => _ratio(
                get(bl, "final_primal_infeasibility", get(bt, "final_primal_infeasibility", nothing)),
                get(cl, "final_primal_infeasibility", get(ct, "final_primal_infeasibility", nothing)),
            ),
        ),
        "final_dual_infeasibility" => Dict(
            "baseline" => get(bl, "final_dual_infeasibility", get(bt, "final_dual_infeasibility", nothing)),
            "candidate" => get(cl, "final_dual_infeasibility", get(ct, "final_dual_infeasibility", nothing)),
            "delta_candidate_minus_baseline" => _delta(
                get(bl, "final_dual_infeasibility", get(bt, "final_dual_infeasibility", nothing)),
                get(cl, "final_dual_infeasibility", get(ct, "final_dual_infeasibility", nothing)),
            ),
            "ratio_candidate_over_baseline" => _ratio(
                get(bl, "final_dual_infeasibility", get(bt, "final_dual_infeasibility", nothing)),
                get(cl, "final_dual_infeasibility", get(ct, "final_dual_infeasibility", nothing)),
            ),
        ),
        "objective" => Dict(
            "baseline" => base_objective,
            "candidate" => candidate_objective,
            "relative_difference" => objective_difference,
            "alignment" => objective_alignment,
        ),
        "candidate_finding_codes" => get(candidate, "solver_result_finding_codes", Dict()),
        "candidate_log_finding_codes" => get(get(candidate, "solver_log", Dict()), "finding_codes", Dict()),
        "family_scaling" => family_comparisons,
    )
end

function _read_summary(entry)
    path = get(entry, "summary_file", nothing)
    isnothing(path) || !isfile(String(path)) ? nothing : JSON.parsefile(String(path))
end

function main()
    length(ARGS) in (1, 2) || error("usage: summarize_bmopf_solver_sweep.jl <sweep-manifest.json> [sweep-summary.json]")
    manifest_path = abspath(ARGS[1])
    manifest = JSON.parsefile(manifest_path)
    entries = get(manifest, "configurations", Any[])
    isempty(entries) && error("sweep manifest contains no configurations")
    baseline_label = get(ENV, "NLPDIAGNOSTICS_BMOPF_SWEEP_BASELINE", "baseline")
    baseline_index = findfirst(entry -> String(get(entry, "label", "")) == baseline_label, entries)
    isnothing(baseline_index) && (baseline_index = firstindex(entries))
    configurations = Dict{String,Any}[]
    maps = Dict{String,Any}[]
    for entry in entries
        entry isa AbstractDict || continue
        summary = _read_summary(entry)
        case_map = isnothing(summary) ? Dict{String,Any}() : _case_map(summary)
        push!(maps, case_map)
        push!(configurations, Dict{String,Any}(
            "label" => get(entry, "label", nothing),
            "options" => get(entry, "options", nothing),
            "common_options" => get(entry, "common_options", nothing),
            "effective_options" => get(entry, "effective_options", nothing),
            "status" => get(entry, "status", nothing),
            "summary_file" => get(entry, "summary_file", nothing),
            "environment_fingerprint" => isnothing(summary) ? get(entry, "environment_fingerprint", nothing) : get(summary, "environment_fingerprint", nothing),
            "status_counts" => isnothing(summary) ? get(entry, "status_counts", Dict()) : get(summary, "status_counts", Dict()),
            "failure_category_counts" => isnothing(summary) ? get(entry, "failure_category_counts", Dict()) : get(summary, "failure_category_counts", Dict()),
            "profile_completeness" => isnothing(summary) ? get(entry, "profile_completeness", Dict()) : get(summary, "profile_completeness", Dict()),
            "case_count" => length(case_map),
            "summary_available" => !isnothing(summary),
        ))
    end
    base_map = maps[baseline_index]
    comparisons = Dict{String,Any}[]
    for (index, config) in enumerate(configurations)
        index == baseline_index && continue
        candidate_map = maps[index]
        names = sort!(collect(union(keys(base_map), keys(candidate_map))))
        rows = Dict{String,Any}[]
        for name in names
            if !haskey(base_map, name) || !haskey(candidate_map, name)
                push!(rows, Dict("name" => name, "status" => "missing_on_one_side",
                                 "baseline_present" => haskey(base_map, name),
                                 "candidate_present" => haskey(candidate_map, name)))
            else
                push!(rows, _compare_case(_case_observation(base_map[name]), _case_observation(candidate_map[name])))
            end
        end
        push!(comparisons, Dict{String,Any}(
            "baseline_label" => configurations[baseline_index]["label"],
            "candidate_label" => config["label"],
            "case_count" => length(rows),
            "comparisons" => rows,
        ))
    end
    common_names = isempty(maps) ? String[] : foldl((left, right) -> intersect(left, collect(keys(right))), maps; init = collect(keys(maps[1])))
    fingerprints = [get(config, "environment_fingerprint", nothing) for config in configurations]
    payload = Dict{String,Any}(
        "report_version" => "bmopf-solver-sweep-v1",
        "manifest" => manifest_path,
        "baseline_label" => configurations[baseline_index]["label"],
        "solver" => get(manifest, "solver", nothing),
        "benchmark_root" => get(manifest, "benchmark_root", nothing),
        "common_solver_options" => get(manifest, "common_solver_options", ""),
        "environment_fingerprints_match" => !isempty(fingerprints) && all(fingerprint -> fingerprint == fingerprints[1], fingerprints),
        "configuration_count" => length(configurations),
        "configurations" => configurations,
        "case_matrix" => Dict(
            "baseline_case_count" => length(base_map),
            "common_case_count" => length(common_names),
            "common_case_names" => sort!(String.(common_names)),
            "complete" => all(length(map) == length(base_map) for map in maps),
        ),
        "comparisons" => comparisons,
    )
    output_path = length(ARGS) == 2 ? abspath(ARGS[2]) : joinpath(dirname(manifest_path), "sweep_summary.json")
    write(output_path, JSON.json(payload))
    println("wrote solver sweep summary to $output_path")
end

main()
