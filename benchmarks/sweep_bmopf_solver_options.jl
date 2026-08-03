#!/usr/bin/env julia

"""
Run a reproducible option sweep over `bmopf_solver_trace.jl`.

The sweep is intentionally an orchestration layer: each configuration gets an
isolated output directory and the existing size guard, trace capture policy,
and environment fingerprint remain authoritative.

Configure entries as `label:key=value,key=value;label2:key=value`. The default
is `baseline:;tight_tol:max_iter=500,tol=1e-8;short_limit:max_iter=25`.
"""

using JSON
using NLPDiagnostics
using BMOPFTools
using JuMP
using Ipopt

include(joinpath(@__DIR__, "benchmark_environment.jl"))

function _parse_sweep()
    raw = get(ENV, "NLPDIAGNOSTICS_BMOPF_SWEEP",
              "baseline:;tight_tol:max_iter=500,tol=1e-8;short_limit:max_iter=25")
    specs = NamedTuple{(:label, :options),Tuple{String,String}}[]
    for item in split(raw, ';')
        isempty(strip(item)) && continue
        pair = split(item, ':'; limit = 2)
        length(pair) == 2 || error("sweep entries must be label:options, got '$item'")
        label = strip(pair[1])
        options = strip(pair[2])
        occursin(r"^[A-Za-z0-9_-]+$", label) || error(
            "sweep labels must contain only letters, digits, '_' or '-', got '$label'",
        )
        push!(specs, (label = label, options = options))
    end
    isempty(specs) && error("NLPDIAGNOSTICS_BMOPF_SWEEP selected no configurations")
    length(unique(spec.label for spec in specs)) == length(specs) ||
        error("sweep labels must be unique")
    return specs
end

function _run(command, environment)
    run(setenv(command, environment))
    return true
end

function main()
    root = get(ENV, "NLPDIAGNOSTICS_BMOPF_BENCHMARK_ROOT", "")
    isempty(root) && error("Set NLPDIAGNOSTICS_BMOPF_BENCHMARK_ROOT first")
    isdir(root) || error("benchmark root does not exist: $root")
    output_root = abspath(get(ENV, "NLPDIAGNOSTICS_BMOPF_SWEEP_OUTPUT_DIR",
                              joinpath(pwd(), "bmopf-solver-sweeps")))
    mkpath(output_root)
    project = something(Base.active_project(), pwd())
    runner = joinpath(@__DIR__, "bmopf_solver_trace.jl")
    summarizer = joinpath(@__DIR__, "summarize_bmopf_solver_trace.jl")
    julia = Base.julia_cmd()
    base_environment = copy(ENV)
    entries = Dict{String,Any}[]
    for spec in _parse_sweep()
        case_output = joinpath(output_root, spec.label)
        mkpath(case_output)
        environment = copy(base_environment)
        environment["NLPDIAGNOSTICS_BMOPF_OUTPUT_DIR"] = case_output
        environment["NLPDIAGNOSTICS_BMOPF_SOLVER_OPTIONS"] = spec.options
        environment["NLPDIAGNOSTICS_BMOPF_SWEEP_LABEL"] = spec.label
        runner_command = `$julia --project=$project $runner`
        status = "ok"
        error_text = nothing
        try
            _run(runner_command, environment)
        catch error
            status = "runner_error"
            error_text = sprint(showerror, error)
        end
        summary_path = joinpath(case_output, "summary.json")
        if status == "ok"
            try
                _run(`$julia --project=$project $summarizer $case_output`, environment)
            catch error
                status = "summary_error"
                error_text = sprint(showerror, error)
            end
        end
        entry = Dict{String,Any}(
            "label" => spec.label,
            "options" => spec.options,
            "status" => status,
            "output_directory" => case_output,
            "summary_file" => isfile(summary_path) ? summary_path : nothing,
        )
        !isnothing(error_text) && (entry["error"] = error_text)
        if isfile(summary_path)
            summary = JSON.parsefile(summary_path)
            entry["status_counts"] = get(summary, "status_counts", Dict())
            entry["failure_category_counts"] = get(summary, "failure_category_counts", Dict())
            entry["environment_fingerprint"] = get(summary, "environment_fingerprint", nothing)
        end
        push!(entries, entry)
        println("$(spec.label): $status")
    end
    environment = _benchmark_environment()
    write(joinpath(output_root, "sweep_manifest.json"), JSON.json(Dict(
        "runner" => "bmopf_solver_trace.jl",
        "summary_runner" => "summarize_bmopf_solver_trace.jl",
        "benchmark_root" => abspath(root),
        "solver" => get(ENV, "NLPDIAGNOSTICS_BMOPF_SOLVER", "ipopt"),
        "cases" => get(ENV, "NLPDIAGNOSTICS_BMOPF_CASES", ""),
        "capture_points" => get(ENV, "NLPDIAGNOSTICS_BMOPF_CAPTURE_POINTS", "false"),
        "environment" => environment,
        "configurations" => entries,
    )))
    println("wrote option-sweep manifest to $(joinpath(output_root, "sweep_manifest.json"))")
end

main()
