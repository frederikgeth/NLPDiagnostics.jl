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
    summary = Dict{String,Any}(
        "report_version" => "bmopf-result-policy-matrix-summary-v1",
        "matrix_index" => matrix_path,
        "output_root" => output_root,
        "policy_count" => length(all_entries),
        "successful_policy_count" => length(entries),
        "failed_policy_count" => length(all_entries) - length(entries),
        "pair_count" => length(pairs),
        "pairs" => pairs,
        "interpretation" => "Pairwise evidence aggregation only; derivative, feasibility, scaling, and representational deltas remain policy-specific observations rather than a score.",
    )
    write(output_path, JSON.json(summary))
    println("wrote BMOPF result-policy matrix summary to $output_path")
end

main()
