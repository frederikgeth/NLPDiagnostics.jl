#!/usr/bin/env julia

"""Run all pairwise comparisons in a BMOPF result-policy matrix.

Usage:

    julia --project=work/benchmark-environment \
      benchmarks/summarize_bmopf_result_policy_matrix.jl \
      /path/to/matrix_index.json [output.json]

The pairwise artifacts are retained under the matrix directory and the final
JSON keeps policy provenance, process status, derivative fingerprints, and
finding deltas together.
"""

using JSON

function _load(path)
    isfile(path) || error("missing JSON file: $path")
    return JSON.parsefile(path)
end

function _run_comparison(script, project, left, right, output)
    julia = Base.julia_cmd()
    command = `$julia --startup-file=no --project=$project $script $left $right $output`
    run(command)
    return _load(output)
end

function _int(value)
    value isa Integer && return Int(value)
    value isa Number && isfinite(Float64(value)) && return Int(value)
    return 0
end

function _controller_matrix_summary(pairs)
    aggregate = Dict{String,Int}()
    transition_cases = Any[]
    available_pairs = 0
    registry_statuses = Dict{String,Int}()
    registry_violation_statuses = Dict{String,Int}()
    paired_case_count = 0
    controller_observation_case_count = 0
    registry_boundary_case_count = 0
    for pair in pairs
        pair isa AbstractDict || continue
        controller = get(pair, "controller_curve_policy_matrix", Dict())
        controller isa AbstractDict || continue
        case_count = _int(get(controller, "case_count", 0))
        paired_case_count += case_count
        available_cases = _int(get(controller, "available_case_count", 0))
        controller_observation_case_count += available_cases
        available_pairs += available_cases > 0
        boundaries = get(controller, "registry_boundary_cases", Any[])
        boundaries isa AbstractVector && (registry_boundary_case_count += length(boundaries))
        for (key, value) in get(controller, "aggregate_count_deltas", Dict())
            value isa Number || continue
            aggregate[String(key)] = get(aggregate, String(key), 0) + Int(value)
        end
        for record in get(controller, "transition_cases", Any[])
            record isa AbstractDict || continue
            push!(transition_cases, Dict(
                "left_policy" => get(pair, "left_policy_name", nothing),
                "right_policy" => get(pair, "right_policy_name", nothing),
                "snapshot" => get(record, "snapshot", nothing),
                "status_count_delta_right_minus_left" => get(record, "status_count_delta_right_minus_left", Dict()),
                "monitor_semantics_count_delta_right_minus_left" => get(record, "monitor_semantics_count_delta_right_minus_left", Dict()),
                "family_count_delta_right_minus_left" => get(record, "family_count_delta_right_minus_left", Dict()),
            ))
        end
        for (status, count) in get(controller, "registry_status_counts", Dict())
            count isa Number || continue
            registry_statuses[String(status)] = get(registry_statuses, String(status), 0) + Int(count)
        end
        for (status, count) in get(controller, "registry_violation_status_counts", Dict())
            count isa Number || continue
            registry_violation_statuses[String(status)] =
                get(registry_violation_statuses, String(status), 0) + Int(count)
        end
    end
    return Dict{String,Any}(
        "paired_case_count" => paired_case_count,
        "controller_observation_case_count" => controller_observation_case_count,
        "pair_with_controller_cases_count" => available_pairs,
        "aggregate_count_deltas" => aggregate,
        "transition_case_count" => length(transition_cases),
        "transition_cases" => transition_cases,
        "registry_status_counts" => registry_statuses,
        "registry_violation_status_counts" => registry_violation_statuses,
        "registry_boundary_case_count" => registry_boundary_case_count,
    )
end

function _policy_provenance(entries)
    status_counts = Dict{String,Int}()
    environment_fingerprints = String[]
    missing_child_indexes = String[]
    policy_views = Any[]
    for entry in entries
        entry isa AbstractDict || continue
        status = String(get(entry, "status", "unknown"))
        status_counts[status] = get(status_counts, status, 0) + 1
        fingerprint = get(entry, "child_environment_fingerprint", nothing)
        fingerprint isa AbstractString && !isempty(fingerprint) && push!(environment_fingerprints, String(fingerprint))
        get(entry, "child_index_available", false) === true ||
            push!(missing_child_indexes, String(get(entry, "policy", "unknown")))
        push!(policy_views, Dict(
            "policy" => get(entry, "policy", nothing),
            "status" => status,
            "result_units" => get(entry, "result_units", nothing),
            "result_field_units" => get(entry, "result_field_units", nothing),
            "result_suffix" => get(entry, "result_suffix", nothing),
            "child_runner_version" => get(entry, "child_runner_version", nothing),
            "child_environment_fingerprint" => fingerprint,
            "child_index_available" => get(entry, "child_index_available", false),
            "child_case_count" => get(entry, "child_case_count", 0),
            "child_status_counts" => get(entry, "child_status_counts", Dict()),
        ))
    end
    return Dict{String,Any}(
        "policies" => policy_views,
        "status_counts" => status_counts,
        "environment_fingerprints" => sort!(unique(environment_fingerprints)),
        "missing_child_indexes" => sort!(unique(missing_child_indexes)),
    )
end

function main()
    length(ARGS) in (1, 2) || error(
        "usage: summarize_bmopf_result_policy_matrix.jl matrix_index.json [output.json]",
    )
    matrix_path = abspath(first(ARGS))
    matrix = _load(matrix_path)
    output_root = abspath(get(matrix, "output_root", dirname(matrix_path)))
    output_path = length(ARGS) == 2 ? abspath(ARGS[2]) :
        joinpath(output_root, "policy_matrix_summary.json")
    project = get(ENV, "NLPDIAGNOSTICS_BENCHMARK_PROJECT", "")
    project = isempty(project) ? Base.active_project() : abspath(project)
    comparator = abspath(joinpath(@__DIR__, "compare_bmopf_saved_result_profiles.jl"))
    all_entries = collect(get(matrix, "policies", Any[]))
    entries = [entry for entry in all_entries if get(entry, "status", nothing) == "ok"]
    pairs = Any[]
    for left_index in 1:length(entries), right_index in (left_index + 1):length(entries)
        left = entries[left_index]
        right = entries[right_index]
        left_dir = get(left, "output_directory", nothing)
        right_dir = get(right, "output_directory", nothing)
        left_dir isa AbstractString && right_dir isa AbstractString || continue
        left_name = String(get(left, "policy", "left"))
        right_name = String(get(right, "policy", "right"))
        pair_output = joinpath(output_root, "$(left_name)-vs-$(right_name).json")
        comparison = try
            _run_comparison(comparator, project, left_dir, right_dir, pair_output)
        catch error
            Dict{String,Any}(
                "left_policy" => left_name,
                "right_policy" => right_name,
                "status" => "comparison_error",
                "error" => sprint(showerror, error),
                "output" => pair_output,
            )
        end
        if comparison isa AbstractDict
            comparison["left_policy_name"] = left_name
            comparison["right_policy_name"] = right_name
            comparison["pair_output"] = pair_output
        end
        push!(pairs, comparison)
    end
    policy_provenance = _policy_provenance(all_entries)
    controller_matrix = _controller_matrix_summary(pairs)
    summary = Dict{String,Any}(
        "report_version" => "bmopf-result-policy-matrix-summary-v4",
        "matrix_index" => matrix_path,
        "output_root" => output_root,
        "policy_count" => length(all_entries),
        "successful_policy_count" => length(entries),
        "failed_policy_count" => length(all_entries) - length(entries),
        "pair_count" => length(pairs),
        "pairs" => pairs,
        "policy_provenance" => policy_provenance,
        "controller_curve_policy_matrix" => controller_matrix,
        "readiness" => Dict(
            # Do not let a failed child disappear from the readiness gate just
            # because pair generation filters it out of `entries`.
            "policy_children_successful" => !isempty(all_entries) && length(entries) == length(all_entries),
            "child_indexes_available" => !isempty(all_entries) &&
                                         all(get(entry, "child_index_available", false) === true for entry in all_entries),
            "policy_environment_compatible" => length(policy_provenance["environment_fingerprints"]) <= 1,
            "pairwise_comparisons_available" => !isempty(pairs),
            "controller_observations_available" => _int(get(controller_matrix, "controller_observation_case_count", 0)) > 0,
        ),
        "interpretation" => "Pairwise evidence aggregation only; derivative, feasibility, scaling, and representational deltas remain policy-specific observations rather than a score.",
    )
    write(output_path, JSON.json(summary))
    println("wrote BMOPF result-policy matrix summary to $output_path")
end

main()
