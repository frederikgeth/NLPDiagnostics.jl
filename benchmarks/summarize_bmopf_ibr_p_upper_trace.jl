#!/usr/bin/env julia

"""
Summarize `ibr_p_upper` feasibility trajectories from BMOPF trace artifacts.

The input artifacts are produced by `benchmarks/bmopf_solver_trace.jl` with
callback point capture. This report preserves the selected iteration sequence
for one registry family without re-solving the model or interpreting the
trajectory as a KKT or causal certificate.

Example:

NLPDIAGNOSTICS_BMOPF_TRACE_ARTIFACTS=/tmp/ln-t01.json,/tmp/ln-t13.json \\
NLPDIAGNOSTICS_BMOPF_IBR_TRACE_OUTPUT=work/bmopf-ibr-p-upper-trace.json \\
julia --startup-file=no benchmarks/summarize_bmopf_ibr_p_upper_trace.jl
"""

Base.include(@__MODULE__, joinpath(@__DIR__, "common.jl"))
using .NLPDiagnosticsBenchmarkCommon: read_summary, write_json

function _artifact_paths()
    raw = get(ENV, "NLPDIAGNOSTICS_BMOPF_TRACE_ARTIFACTS", "")
    paths = filter(!isempty, strip.(split(raw, ',')))
    isempty(paths) && error("NLPDIAGNOSTICS_BMOPF_TRACE_ARTIFACTS must not be empty")
    all(isfile, paths) || error("one or more trace artifacts do not exist")
    return paths
end

function _finite_float(value)
    value isa Real || return nothing
    converted = Float64(value)
    return isfinite(converted) ? converted : nothing
end

function _trajectory(payload)
    trace = get(payload, "row_family_residual_trace", Dict())
    rows = get(trace, "rows", Any[])
    sequence = Dict{String,Any}[]
    for row in rows
        families = get(row, "families", Dict())
        family = get(families, "ibr_p_upper", nothing)
        family isa AbstractDict || continue
        residual = _finite_float(get(family, "max_feasibility_violation", nothing))
        residual === nothing && continue
        iteration = get(row, "iteration", nothing)
        iteration isa Integer || continue
        push!(sequence, Dict{String,Any}(
            "iteration" => Int(iteration),
            "max_feasibility_violation" => residual,
        ))
    end
    sort!(sequence; by = item -> item["iteration"])
    return sequence
end

function _summarize(path)
    payload = read_summary(path; root = "/")
    sequence = _trajectory(payload)
    positive = filter(item -> item["max_feasibility_violation"] > 0, sequence)
    isempty(sequence) && error("trace artifact has no usable ibr_p_upper rows: $path")
    peak = maximum(item["max_feasibility_violation"] for item in sequence)
    endpoint = last(sequence)["max_feasibility_violation"]
    return Dict{String,Any}(
        "snapshot" => get(payload, "snapshot", basename(path)),
        "solver" => get(payload, "solver", nothing),
        "trace_record_count" => get(
            get(payload, "iteration_trace", Dict()), "record_count", nothing,
        ),
        "row_residual_record_count" => length(sequence),
        "positive_iteration_count" => length(positive),
        "first_positive_iteration" => isempty(positive) ? nothing : first(positive)["iteration"],
        "last_positive_iteration" => isempty(positive) ? nothing : last(positive)["iteration"],
        "peak_residual" => peak,
        "endpoint_residual" => endpoint,
        "endpoint_to_peak_ratio" => peak == 0 ? nothing : endpoint / peak,
        "positive_trajectory" => positive,
    )
end

artifacts = _artifact_paths()
cases = [_summarize(path) for path in artifacts]
output = abspath(get(
    ENV,
    "NLPDIAGNOSTICS_BMOPF_IBR_TRACE_OUTPUT",
    joinpath(@__DIR__, "..", "work", "bmopf-ibr-p-upper-trace-summary.json"),
))
mkpath(dirname(output))
write_json(output, Dict(
    "schema_version" => "nlpdiagnostics-bmopf-ibr-p-upper-trace-summary-v1",
    "source" => Dict(
        "runner" => basename(@__FILE__),
        "trace_runner" => "benchmarks/bmopf_solver_trace.jl",
        "family" => "ibr_p_upper",
        "interpretation" =>
            "point-local feasibility trajectory; not a KKT, optimality, or causal certificate",
    ),
    "cases" => cases,
))
println("wrote ibr_p_upper trace summary to $output")
