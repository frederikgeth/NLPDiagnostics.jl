#!/usr/bin/env julia

"""Compare two trust-gated multiconductor iterative-probe summaries."""

using JSON

include(joinpath(@__DIR__, "common.jl"))
using .NLPDiagnosticsBenchmarkCommon

function _load(path)
    value = read_summary(abspath(path); root = "/")
    value isa AbstractDict || error("summary is not a JSON object: $path")
    value
end

_dict(value) = value isa AbstractDict ? Dict{String,Any}(String(k) => v for (k, v) in value) : Dict{String,Any}()
_int(value, default = 0) = value isa Integer ? Int(value) : try parse(Int, String(value)) catch; default end

function _case_map(summary)
    result = Dict{String,Any}()
    for raw in get(summary, "cases", Any[])
        case = _dict(raw)
        name = String(get(case, "name", ""))
        isempty(name) || (result[name] = case)
    end
    result
end

function _probe(case)
    _dict(get(case, "iterative_right_nullspace_probe", nothing))
end

function _finite_min(values)
    values isa AbstractVector || return nothing
    finite = Float64[value for value in values if value isa Number && isfinite(Float64(value))]
    isempty(finite) ? nothing : minimum(finite)
end

function main()
    length(ARGS) in (2, 3) || error(
        "usage: compare_bmopf_multiconductor_probes.jl baseline-summary.json candidate-summary.json [comparison.json]",
    )
    baseline_path, candidate_path = abspath.(ARGS[1:2])
    output_path = length(ARGS) == 3 ? abspath(ARGS[3]) :
        joinpath(dirname(candidate_path), "multiconductor_probe_comparison.json")
    baseline = _load(baseline_path)
    candidate = _load(candidate_path)
    baseline_cases = _case_map(baseline)
    candidate_cases = _case_map(candidate)
    names = sort!(collect(intersect(Set(keys(baseline_cases)), Set(keys(candidate_cases)))))
    missing_baseline = sort!(collect(setdiff(Set(keys(candidate_cases)), Set(keys(baseline_cases)))))
    missing_candidate = sort!(collect(setdiff(Set(keys(baseline_cases)), Set(keys(candidate_cases)))))
    paired = Any[]
    dimension_aligned = true
    for name in names
        left = _probe(baseline_cases[name])
        right = _probe(candidate_cases[name])
        left_dimension = _int(get(left, "requested_dimension", 0))
        right_dimension = _int(get(right, "requested_dimension", 0))
        dimension_aligned &= left_dimension == right_dimension
        left_min = _finite_min(get(left, "residual_norms", Any[]))
        right_min = _finite_min(get(right, "residual_norms", Any[]))
        push!(paired, Dict{String,Any}(
            "name" => name,
            "baseline" => left,
            "candidate" => right,
            "dimension_aligned" => left_dimension == right_dimension,
            "convergence_delta" => Int(get(right, "converged", false) === true) -
                                    Int(get(left, "converged", false) === true),
            "candidate_count_delta" => _int(get(right, "candidate_count", 0)) -
                                        _int(get(left, "candidate_count", 0)),
            "minimum_residual_norm_delta" => isnothing(left_min) || isnothing(right_min) ?
                nothing : right_min - left_min,
        ))
    end
    same_environment = get(baseline, "environment_fingerprint", nothing) ==
                       get(candidate, "environment_fingerprint", nothing)
    findings = Any[]
    isempty(missing_baseline) && isempty(missing_candidate) || push!(findings, Dict(
        "code" => "multiconductor_probe_case_coverage_mismatch",
        "severity" => "warning",
        "observation" => "The two iterative-probe summaries do not cover the same fixture names.",
        "evidence" => Dict("missing_from_baseline" => missing_baseline,
                           "missing_from_candidate" => missing_candidate),
        "suggested_action" => "Compare probe settings only on explicitly paired fixtures.",
    ))
    same_environment || push!(findings, Dict(
        "code" => "multiconductor_probe_environment_mismatch",
        "severity" => "warning",
        "observation" => "The iterative-probe summaries were produced under different environment fingerprints.",
        "evidence" => Dict("baseline_environment" => get(baseline, "environment_fingerprint", nothing),
                           "candidate_environment" => get(candidate, "environment_fingerprint", nothing)),
        "suggested_action" => "Align Julia, package, BMOPFTools, and fixture environments before interpreting probe deltas.",
    ))
    dimension_aligned || push!(findings, Dict(
        "code" => "multiconductor_probe_dimension_mismatch",
        "severity" => "warning",
        "observation" => "The paired iterative probes requested different subspace dimensions.",
        "evidence" => Dict("paired_case_count" => length(paired)),
        "suggested_action" => "Keep probe dimension fixed when comparing convergence or residual changes.",
    ))
    readiness = Dict{String,Any}(
        "paired_case_coverage" => isempty(missing_baseline) && isempty(missing_candidate) && !isempty(paired),
        "environment_compatible" => same_environment,
        "probe_dimension_aligned" => dimension_aligned,
        "comparison_available" => !isempty(paired) && same_environment && dimension_aligned &&
                                   isempty(missing_baseline) && isempty(missing_candidate),
    )
    payload = Dict{String,Any}(
        "report_version" => "bmopf-multiconductor-probe-comparison-v1",
        "baseline_summary" => baseline_path,
        "candidate_summary" => candidate_path,
        "paired_case_count" => length(paired),
        "missing_from_baseline" => missing_baseline,
        "missing_from_candidate" => missing_candidate,
        "comparisons" => paired,
        "readiness" => readiness,
        "findings" => findings,
        "interpretation" => "Iterative-probe comparison only; convergence and residual changes are numerical observations, not rank or physical-gauge certificates.",
    )
    write_json(output_path, payload)
    println("wrote multiconductor probe comparison to $output_path")
end

main()
