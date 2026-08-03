#!/usr/bin/env julia

"""Compare two `summarize_bmopf_solver_trace.jl` outputs without a score."""

using JSON

function _as_dict(value)
    return value isa AbstractDict ? Dict{String,Any}(string(k) => v for (k, v) in value) : Dict{String,Any}()
end

function _delta(left, right)
    left isa Real && right isa Real || return nothing
    return Float64(right) - Float64(left)
end

function _ratio(left, right)
    left isa Real && right isa Real && left != 0 || return nothing
    return Float64(right) / Float64(left)
end

function _relative_difference(left, right)
    left isa Real && right isa Real || return nothing
    return abs(Float64(right) - Float64(left)) /
           max(1.0, abs(Float64(left)), abs(Float64(right)))
end

function _case_map(summary)
    return Dict(String(get(case, "name", "unknown")) => case
                for case in get(summary, "cases", Any[]))
end

function _compare_case(left, right)
    left_trace = _as_dict(get(left, "trace", nothing))
    right_trace = _as_dict(get(right, "trace", nothing))
    left_codes = _as_dict(get(left, "solver_result_finding_codes", nothing))
    right_codes = _as_dict(get(right, "solver_result_finding_codes", nothing))
    bmopf_left = _as_dict(get(left, "bmopf_context_finding_codes", nothing))
    bmopf_right = _as_dict(get(right, "bmopf_context_finding_codes", nothing))
    left_log = _as_dict(get(left, "solver_log_iterations", nothing))
    right_log = _as_dict(get(right, "solver_log_iterations", nothing))
    return Dict{String,Any}(
        "status" => Dict("left" => get(left, "status", nothing), "right" => get(right, "status", nothing)),
        "conventions" => Dict(
            "solver_options" => Dict("left" => get(left, "solver_options", nothing), "right" => get(right, "solver_options", nothing)),
            "per_unit" => Dict("left" => get(left, "per_unit", nothing), "right" => get(right, "per_unit", nothing)),
            "model_coordinate_units" => Dict("left" => get(left, "model_coordinate_units", nothing), "right" => get(right, "model_coordinate_units", nothing)),
            "solver_objective_convention" => Dict("left" => get(left, "solver_objective_convention", nothing), "right" => get(right, "solver_objective_convention", nothing)),
            "objective_comparison_reference" => Dict("left" => get(left, "objective_comparison_reference", nothing), "right" => get(right, "objective_comparison_reference", nothing)),
        ),
        "model_variable_count" => Dict("left" => get(left, "model_variable_count", nothing), "right" => get(right, "model_variable_count", nothing)),
        "trace" => Dict(
            "record_count" => Dict("left" => get(left_trace, "record_count", nothing), "right" => get(right_trace, "record_count", nothing),
                                    "delta_right_minus_left" => _delta(get(left_trace, "record_count", nothing), get(right_trace, "record_count", nothing))),
            "segment_count" => Dict("left" => get(left_trace, "segment_count", nothing), "right" => get(right_trace, "segment_count", nothing)),
            "binding_count" => Dict("left" => get(left_trace, "binding_count", nothing), "right" => get(right_trace, "binding_count", nothing)),
            "final_objective" => Dict("left" => get(left_trace, "final_objective", nothing), "right" => get(right_trace, "final_objective", nothing),
                                       "delta_right_minus_left" => _delta(get(left_trace, "final_objective", nothing), get(right_trace, "final_objective", nothing)),
                                       "ratio_right_over_left" => _ratio(get(left_trace, "final_objective", nothing), get(right_trace, "final_objective", nothing)),
                                       "relative_difference" => _relative_difference(get(left_trace, "final_objective", nothing), get(right_trace, "final_objective", nothing)),
                                       "alignment" => begin
                                           difference = _relative_difference(get(left_trace, "final_objective", nothing), get(right_trace, "final_objective", nothing))
                                           isnothing(difference) ? "unavailable" :
                                               (difference <= 1.0e-6 ? "aligned" : "different_convention_or_solution")
                                       end),
            "final_primal_infeasibility" => Dict("left" => get(left_trace, "final_primal_infeasibility", nothing), "right" => get(right_trace, "final_primal_infeasibility", nothing)),
            "final_dual_infeasibility" => Dict("left" => get(left_trace, "final_dual_infeasibility", nothing), "right" => get(right_trace, "final_dual_infeasibility", nothing)),
            "phase_counts" => Dict("left" => get(left_trace, "phase_counts", Dict()), "right" => get(right_trace, "phase_counts", Dict())),
        ),
        "solver_log" => Dict(
            "available" => Dict(
                "left" => get(left, "solver_log_available", false),
                "right" => get(right, "solver_log_available", false),
            ),
            "finding_codes" => Dict(
                "left" => get(left, "solver_log_finding_codes", Dict()),
                "right" => get(right, "solver_log_finding_codes", Dict()),
            ),
            "iteration_count" => Dict(
                "left" => get(left_log, "record_count", nothing),
                "right" => get(right_log, "record_count", nothing),
                "delta_right_minus_left" => _delta(
                    get(left_log, "record_count", nothing),
                    get(right_log, "record_count", nothing),
                ),
            ),
            "segment_count" => Dict(
                "left" => get(left_log, "segment_count", nothing),
                "right" => get(right_log, "segment_count", nothing),
            ),
            "final_primal_infeasibility" => Dict(
                "left" => get(left_log, "final_primal_infeasibility", nothing),
                "right" => get(right_log, "final_primal_infeasibility", nothing),
            ),
            "final_dual_infeasibility" => Dict(
                "left" => get(left_log, "final_dual_infeasibility", nothing),
                "right" => get(right_log, "final_dual_infeasibility", nothing),
            ),
        ),
        "solver_result_finding_codes" => Dict("left" => left_codes, "right" => right_codes),
        "bmopf_context_finding_codes" => Dict("left" => bmopf_left, "right" => bmopf_right),
    )
end

function main()
    length(ARGS) in (2, 3) || error(
        "usage: compare_bmopf_solver_traces.jl <left-summary.json> <right-summary.json> [comparison.json]",
    )
    left_path, right_path = abspath.(ARGS[1:2])
    left = JSON.parsefile(left_path)
    right = JSON.parsefile(right_path)
    left_cases = _case_map(left)
    right_cases = _case_map(right)
    names = sort!(collect(union(keys(left_cases), keys(right_cases))))
    comparisons = Dict{String,Any}[]
    for name in names
        if !haskey(left_cases, name) || !haskey(right_cases, name)
            push!(comparisons, Dict("name" => name, "status" => "missing_on_one_side",
                                    "left_present" => haskey(left_cases, name),
                                    "right_present" => haskey(right_cases, name)))
        else
            push!(comparisons, Dict("name" => name,
                                    "comparison" => _compare_case(left_cases[name], right_cases[name])))
        end
    end
    output_path = length(ARGS) == 3 ? abspath(ARGS[3]) : joinpath(dirname(left_path), "solver_trace_comparison.json")
    payload = Dict{String,Any}(
        "left_summary" => left_path,
        "right_summary" => right_path,
        "left_solver" => get(left, "solver", nothing),
        "right_solver" => get(right, "solver", nothing),
        "environment_fingerprint" => Dict(
            "left" => get(left, "environment_fingerprint", nothing),
            "right" => get(right, "environment_fingerprint", nothing),
            "match" => get(left, "environment_fingerprint", nothing) == get(right, "environment_fingerprint", nothing),
        ),
        "case_count" => length(comparisons),
        "comparisons" => comparisons,
    )
    write(output_path, JSON.json(payload))
    println("wrote solver-trace comparison to $output_path")
end

main()
