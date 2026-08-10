#!/usr/bin/env julia

"""Compare source-preserving solver matrices across initialization policies."""

using JSON

function _dict(value)
    value isa AbstractDict ? Dict{String,Any}(string(k) => v for (k, v) in value) : Dict{String,Any}()
end

function _key(entry)
    return string(get(entry, "case", "unknown"), "|max_iter=", get(entry, "budget", "unknown"))
end

function _entry_map(matrix)
    result = Dict{String,Any}()
    for raw in get(matrix, "entries", Any[])
        entry = _dict(raw)
        isempty(entry) || (result[_key(entry)] = entry)
    end
    return result
end

function _policy(matrix, entries, path)
    configured = get(matrix, "initialization_policy", nothing)
    configured isa AbstractString && !isempty(configured) && return String(configured)
    for entry in values(entries)
        value = get(entry, "initialization_policy", nothing)
        value isa AbstractString && return String(value)
    end
    return basename(path)
end

function _view(entry)
    initialization = _dict(get(entry, "initialization", nothing))
    derivative = _dict(get(entry, "endpoint_derivative", nothing))
    return Dict{String,Any}(
        "status" => get(entry, "status", "unknown"),
        "classification" => get(entry, "classification", "unavailable"),
        "comparison_status" => get(entry, "comparison_status", "unavailable"),
        "coordinate_alignment_available" => get(entry,
            "coordinate_alignment_available", false),
        "initialization_policy" => get(entry, "initialization_policy", nothing),
        "initialization_status" => get(entry, "initialization_status", "unavailable"),
        "finite_start_count" => get(entry, "initialization_finite_start_count", nothing),
        "missing_start_count" => get(entry, "initialization_missing_start_count", nothing),
        "endpoint_derivative_status" => get(entry,
            "endpoint_derivative_status", "unavailable"),
        "endpoint_derivative_fingerprint" => get(entry,
            "endpoint_derivative_fingerprint", get(derivative, "fingerprint", nothing)),
        "endpoint_derivative_entry_count" => get(entry,
            "endpoint_derivative_entry_count", get(derivative, "jacobian_entry_count", nothing)),
        "row_family_scale_attribution" => get(entry,
            "endpoint_derivative_row_family_scale_attribution",
            get(derivative, "row_family_scale_attribution", nothing)),
        "active_set_summary" => get(entry, "endpoint_active_set_summary",
            get(derivative, "active_set_summary", nothing)),
        "row_family_residual_trace" => get(entry,
            "row_family_residual_trace", nothing),
        "trace" => _trace_view(entry),
        "validation_finding_codes" => get(entry, "validation_finding_codes", Any[]),
    )
end

function _int_set(value)
    value isa AbstractVector || return Set{Int}()
    return Set(Int(item) for item in value if item isa Number)
end

function _trace_view(entry)
    summary_path = get(entry, "summary_path", nothing)
    summary_path isa AbstractString && isfile(summary_path) ||
        return Dict{String,Any}("status" => "unavailable")
    try
        summary = JSON.parsefile(summary_path)
        cases = get(summary, "cases", Any[])
        case = isempty(cases) ? Dict{String,Any}() : _dict(first(cases))
        result_file = get(case, "result_file", nothing)
        result_file isa AbstractString || return Dict{String,Any}("status" => "unavailable")
        result_path = joinpath(dirname(summary_path), result_file)
        isfile(result_path) || return Dict{String,Any}("status" => "unavailable")
        record = JSON.parsefile(result_path)
        trace = _dict(get(record, "iteration_trace", nothing))
        raw_records = get(trace, "records", Any[])
        records = [Dict{String,Any}(
            "iteration" => get(_dict(raw), "iteration", nothing),
            "phase" => get(_dict(raw), "phase", nothing),
            "objective" => get(_dict(raw), "objective", nothing),
            "primal_infeasibility" => get(_dict(raw), "primal_infeasibility", nothing),
            "dual_infeasibility" => get(_dict(raw), "dual_infeasibility", nothing),
            "primal_step" => get(_dict(raw), "primal_step", nothing),
        ) for raw in raw_records if raw isa AbstractDict]
        primal = [Float64(row["primal_infeasibility"]) for row in records
                  if row["primal_infeasibility"] isa Real &&
                  isfinite(Float64(row["primal_infeasibility"]))]
        dual = [Float64(row["dual_infeasibility"]) for row in records
                if row["dual_infeasibility"] isa Real &&
                isfinite(Float64(row["dual_infeasibility"]))]
        phases = Dict{String,Int}()
        for row in records
            phase = String(get(row, "phase", "unknown"))
            phases[phase] = get(phases, phase, 0) + 1
        end
        increase_count(values) = count(index -> index > 1 &&
            values[index] > values[index - 1] * (1.0 + 1.0e-12), eachindex(values))
        return Dict{String,Any}(
            "status" => "available",
            "record_count" => length(records),
            "phase_counts" => phases,
            "restoration_record_count" => get(phases, "restoration", 0),
            "primal_increase_count" => increase_count(primal),
            "dual_increase_count" => increase_count(dual),
            "minimum_primal_infeasibility" => isempty(primal) ? nothing : minimum(primal),
            "minimum_dual_infeasibility" => isempty(dual) ? nothing : minimum(dual),
            "final_primal_infeasibility" => isempty(primal) ? nothing : last(primal),
            "final_dual_infeasibility" => isempty(dual) ? nothing : last(dual),
            "trajectory" => records,
        )
    catch error
        return Dict{String,Any}("status" => "error", "error" => sprint(showerror, error))
    end
end

function _row_family_residual_view(raw)
    trace = _dict(raw)
    rows = get(trace, "rows", Any[])
    rows isa AbstractVector || (rows = Any[])
    peak = Dict{String,Float64}()
    final = Dict{String,Float64}()
    first_values = Dict{String,Float64}()
    series = Dict{String,Vector{Tuple{Int,String,Float64}}}()
    for (position, raw_row) in enumerate(rows)
        row = _dict(raw_row)
        families = _dict(get(row, "families", nothing))
        for (family, raw_data) in families
            data = _dict(raw_data)
            value = get(data, "max_feasibility_violation", nothing)
            value isa Real && isfinite(Float64(value)) || continue
            numeric = Float64(value)
            peak[family] = max(get(peak, family, 0.0), numeric)
            position == 1 && (first_values[family] = numeric)
            position == length(rows) && (final[family] = numeric)
            push!(get!(series, family, Tuple{Int,String,Float64}[]),
                (position, String(get(row, "phase", "unknown")), numeric))
        end
    end
    trends = Dict{String,String}()
    for (family, values) in series
        maximum_value = maximum(value[3] for value in values)
        final_value = get(final, family, 0.0)
        restoration_only = all(value -> value[2] == "restoration", values)
        peak_position = values[argmax(last.(values))][1]
        if maximum_value <= 1.0e-12
            trends[family] = "inactive_or_below_tolerance"
        elseif restoration_only
            trends[family] = "restoration_only"
        elseif length(values) >= max(2, cld(length(rows), 2)) &&
            final_value >= 0.5 * maximum_value
            trends[family] = "persistent"
        elseif peak_position < length(rows) && final_value < 0.5 * maximum_value
            trends[family] = "transient"
        else
            trends[family] = "mixed"
        end
    end
    return Dict{String,Any}(
        "status" => get(trace, "status", "unavailable"),
        "binding_count" => get(trace, "binding_count", 0),
        "captured_row_count" => get(trace, "captured_row_count", 0),
        "family_peak_max_feasibility_violation" => peak,
        "family_first_max_feasibility_violation" => first_values,
        "family_final_max_feasibility_violation" => final,
        "family_residual_trend" => trends,
        "global_peak_max_feasibility_violation" => isempty(peak) ? nothing : maximum(values(peak)),
    )
end

function main()
    length(ARGS) >= 2 || error(
        "usage: compare_bmopf_source_solver_matrices.jl <native.json> <policy.json> [policy.json ...] [output.json]",
    )
    paths = abspath.(ARGS)
    output_path = endswith(lowercase(paths[end]), ".json") && length(paths) >= 3 ? pop!(paths) :
        joinpath(pwd(), "source_solver_matrix_policy_comparison.json")
    matrices = [JSON.parsefile(path) for path in paths]
    maps = [_entry_map(matrix) for matrix in matrices]
    policies = [_policy(matrix, map, path) for (matrix, map, path) in zip(matrices, maps, paths)]
    grid_keys = sort!(collect(union((Base.keys(map) for map in maps)...)))
    rows = Dict{String,Any}[]
    for key in grid_keys
        by_policy = Dict{String,Any}()
        for (policy, map) in zip(policies, maps)
            by_policy[policy] = haskey(map, key) ? _view(map[key]) : Dict{String,Any}(
                "status" => "missing",
            )
        end
        derivatives = [get(view, "endpoint_derivative_fingerprint", nothing)
                       for view in values(by_policy)]
        available_derivatives = filter(value -> value isa AbstractString &&
            !isempty(value), derivatives)
        classifications = [get(view, "classification", "unavailable")
                           for view in values(by_policy)]
        family_scales = [_dict(get(view, "row_family_scale_attribution", nothing))
                         for view in values(by_policy)]
        family_scale_views = [get(scale, "families", Dict{String,Any}())
                              for scale in family_scales]
        family_scale_fingerprint = [JSON.json(view) for view in family_scale_views]
        baseline_policy = first(policies)
        baseline_view = _dict(get(by_policy, baseline_policy, nothing))
        baseline_active = _dict(get(baseline_view, "active_set_summary", nothing))
        active_set_deltas = Dict{String,Any}()
        for policy in policies
            view = _dict(get(by_policy, policy, nothing))
            active = _dict(get(view, "active_set_summary", nothing))
            active_set_deltas[policy] = Dict{String,Any}(
                "active_row_symmetric_difference_count" => length(
                    symdiff(_int_set(get(baseline_active, "active_rows", Any[])),
                        _int_set(get(active, "active_rows", Any[])))),
                "violated_row_symmetric_difference_count" => length(
                    symdiff(_int_set(get(baseline_active, "violated_rows", Any[])),
                        _int_set(get(active, "violated_rows", Any[])))),
                "active_row_count_delta" => get(active, "active_row_count", nothing) isa Number &&
                    get(baseline_active, "active_row_count", nothing) isa Number ?
                    get(active, "active_row_count", 0) - get(baseline_active, "active_row_count", 0) : nothing,
                "maximum_feasibility_violation_delta" => get(active,
                    "maximum_feasibility_violation", nothing) isa Number &&
                    get(baseline_active, "maximum_feasibility_violation", nothing) isa Number ?
                    get(active, "maximum_feasibility_violation", 0) -
                    get(baseline_active, "maximum_feasibility_violation", 0) : nothing,
            )
        end
        active_set_changed = any(policy -> begin
            delta = active_set_deltas[policy]
            policy != baseline_policy && (
                get(delta, "active_row_symmetric_difference_count", 0) > 0 ||
                get(delta, "violated_row_symmetric_difference_count", 0) > 0 ||
                get(delta, "active_row_count_delta", 0) != 0 ||
                abs(Float64(get(delta, "maximum_feasibility_violation_delta", 0.0))) > 1.0e-8
            )
        end, policies)
        family_extrema = Dict{String,Any}()
        for policy in policies
            view = _dict(get(by_policy, policy, nothing))
            scale = _dict(get(view, "row_family_scale_attribution", nothing))
            family_extrema[policy] = Dict{String,Any}(
                "global_minimum_families" => get(scale, "global_minimum_families", Any[]),
                "global_maximum_families" => get(scale, "global_maximum_families", Any[]),
                "smallest_positive_row_norm" => get(scale, "smallest_positive_row_norm", nothing),
                "largest_finite_row_norm" => get(scale, "largest_finite_row_norm", nothing),
            )
        end
        traces = [_dict(get(view, "trace", nothing)) for view in values(by_policy)]
        trace_fingerprints = [JSON.json(trace) for trace in traces]
        row_family_residual_views = Dict(policy => _row_family_residual_view(
            get(_dict(get(by_policy, policy, nothing)),
                "row_family_residual_trace", nothing),
        ) for policy in policies)
        residual_fingerprints = [JSON.json(view) for view in values(row_family_residual_views)]
        push!(rows, Dict{String,Any}(
            "key" => key,
            "case" => first(split(key, "|max_iter=")),
            "policies" => by_policy,
            "classification_set" => unique(classifications),
            "classification_changed" => length(unique(classifications)) > 1,
            "endpoint_derivative_fingerprint_set" => unique(available_derivatives),
            "endpoint_derivative_changed" => length(unique(available_derivatives)) > 1,
            "endpoint_derivative_comparable" => length(available_derivatives) == length(policies),
            "row_family_scale_available" => all(scale -> !isempty(scale), family_scale_views),
            "row_family_scale_changed" => length(unique(family_scale_fingerprint)) > 1,
            "active_set_changed" => active_set_changed,
            "active_set_deltas_vs_baseline" => active_set_deltas,
            "row_family_scale_extrema" => family_extrema,
            "trace_changed" => length(unique(trace_fingerprints)) > 1,
            "trace_by_policy" => Dict(policy => _dict(get(by_policy, policy, nothing))["trace"]
                for policy in policies),
            "row_family_residual_changed" => length(unique(residual_fingerprints)) > 1,
            "row_family_residual_by_policy" => row_family_residual_views,
        ))
    end
    same_grid = all(matrix -> Set(_key.(_dict.(get(matrix, "entries", Any[])))) ==
        Set(grid_keys), matrices)
    readiness = Dict{String,Any}(
        "all_policy_matrices_present" => all(isfile, paths),
        "same_case_budget_grid" => same_grid,
        "all_rows_present" => all(row -> all(policy ->
            get(_dict(get(row, "policies", nothing))[policy], "status", "missing") != "missing",
            policies), rows),
        "all_source_comparisons_available" => all(row -> all(policy ->
            get(_dict(get(row, "policies", nothing))[policy], "comparison_status", "unavailable") == "available",
            policies), rows),
        "all_coordinate_alignments_available" => all(row -> all(policy ->
            get(_dict(get(row, "policies", nothing))[policy], "coordinate_alignment_available", false),
            policies), rows),
        "all_initialization_metadata_available" => all(row -> all(policy ->
            get(_dict(get(row, "policies", nothing))[policy], "initialization_status", "unavailable") != "unavailable",
            policies), rows),
        "all_endpoint_derivatives_comparable" => all(row ->
            get(row, "endpoint_derivative_comparable", false), rows),
        "all_row_family_scales_available" => all(row ->
            get(row, "row_family_scale_available", false), rows),
        "all_row_family_residual_traces_available" => all(row -> all(policy ->
            get(_dict(get(_dict(get(row, "policies", nothing))[policy],
                "row_family_residual_trace", nothing)), "status", "unavailable") in
                ("available", "partial"), policies), rows),
    )
    payload = Dict{String,Any}(
        "comparison_version" => "bmopf-source-solver-policy-comparison-v1",
        "input_matrices" => paths,
        "policies" => policies,
        "rows" => rows,
        "readiness" => readiness,
        "classification_change_count" => count(row ->
            get(row, "classification_changed", false), rows),
        "endpoint_derivative_change_count" => count(row ->
            get(row, "endpoint_derivative_changed", false), rows),
    )
    write(output_path, JSON.json(payload))
    println("wrote source-solver policy comparison to $output_path")
end

main()
