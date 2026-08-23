#!/usr/bin/env julia

"""Launch each solver-failure case in a fresh Julia process.

This launcher intentionally imports only JSON. The heavy JuMP/solver packages
are loaded by the child, so a native solver exit cannot take down the campaign
parent or prevent already-written case records from being summarized.
"""

using JSON

Base.include(@__MODULE__, joinpath(@__DIR__, "common.jl"))
using .NLPDiagnosticsBenchmarkCommon: write_json

const _CASES = ("iteration-limit", "infeasible-bounds", "invalid-log-domain",
                "restoration-candidate")
const _EXPECTED_SIGNALS = Dict(
    "iteration-limit" => "resource_limit",
    "infeasible-bounds" => "infeasibility_or_restoration",
    "invalid-log-domain" => "invalid_number_or_domain",
    "restoration-candidate" => "restoration_or_infeasibility",
)

function _env_list(name, defaults)
    selected = filter(!isempty, strip.(split(get(ENV, name, ""), ',')))
    isempty(selected) && return collect(defaults)
    return String[selected...]
end

function _timeout_seconds()
    value = try
        parse(Float64, get(ENV, "NLPDIAGNOSTICS_FAILURE_CHILD_TIMEOUT_SECONDS", "180"))
    catch
        error("NLPDIAGNOSTICS_FAILURE_CHILD_TIMEOUT_SECONDS must be numeric")
    end
    value > 0 || error("NLPDIAGNOSTICS_FAILURE_CHILD_TIMEOUT_SECONDS must be positive")
    return value
end

function _run_child(script, project, output_dir, solver, case, timeout_seconds)
    child_env = copy(ENV)
    child_env["NLPDIAGNOSTICS_FAILURE_CHILD"] = "true"
    child_env["NLPDIAGNOSTICS_FAILURE_ISOLATE_CASES"] = "false"
    child_env["NLPDIAGNOSTICS_FAILURE_CASES"] = case
    child_env["NLPDIAGNOSTICS_FAILURE_SOLVERS"] = solver
    child_env["NLPDIAGNOSTICS_FAILURE_OUTPUT_DIR"] = output_dir
    process_log = joinpath(output_dir, "$(solver)__$(case).process.log")
    julia = Base.julia_cmd()
    command = isnothing(project) ?
        `$julia --startup-file=no $script` :
        `$julia --startup-file=no --project=$project $script`
    process = open(process_log, "w+") do io
        run(pipeline(setenv(command, child_env), stdout = io, stderr = io); wait = false)
    end
    deadline = time() + timeout_seconds
    timed_out = false
    while Base.process_running(process) && time() < deadline
        sleep(0.1)
    end
    if Base.process_running(process)
        timed_out = true
        try
            Base.kill(process, Base.SIGTERM)
        catch
            Base.kill(process)
        end
        grace_deadline = time() + min(10.0, max(1.0, timeout_seconds / 20))
        while Base.process_running(process) && time() < grace_deadline
            sleep(0.1)
        end
        if Base.process_running(process)
            try
                Base.kill(process, Base.SIGKILL)
            catch
            end
        end
    end
    wait(process)
    exit_code = timed_out ? nothing : process.exitcode
    result_file = "$(solver)__$(case).json"
    result_path = joinpath(output_dir, result_file)
    if isfile(result_path)
        record = JSON.parsefile(result_path)
        return Dict{String,Any}(
            "case" => case,
            "solver" => solver,
            "result_file" => result_file,
            "status" => get(record, "status", "unknown"),
            "expected_signal" => get(record, "expected_signal", "unspecified"),
            "observed_termination" => get(record, "observed_termination", "unknown"),
            "observed_category" => get(record, "observed_category", "unknown"),
            "process_exit_code" => exit_code,
            "process_timeout" => timed_out,
        )
    end
    return Dict{String,Any}(
        "case" => case,
        "solver" => solver,
        "result_file" => nothing,
        "status" => timed_out ? "process_timeout" : "process_exit",
        "expected_signal" => get(_EXPECTED_SIGNALS, case, "unspecified"),
        "observed_termination" => timed_out ? "process_timeout" : "process_exit",
        "observed_category" => timed_out ? "process_timeout" : "process_exit",
        "process_exit_code" => exit_code,
        "process_timeout" => timed_out,
        "process_log" => basename(process_log),
    )
end

function main()
    output_dir = abspath(get(ENV, "NLPDIAGNOSTICS_FAILURE_OUTPUT_DIR",
                             joinpath(pwd(), "solver-failure-results")))
    mkpath(output_dir)
    solvers = lowercase.(_env_list("NLPDIAGNOSTICS_FAILURE_SOLVERS", ("ipopt",)))
    all(solver -> solver in ("ipopt", "madnlp"), solvers) ||
        error("NLPDIAGNOSTICS_FAILURE_SOLVERS must contain only ipopt or madnlp")
    selected = _env_list("NLPDIAGNOSTICS_FAILURE_CASES", _CASES)
    all(case -> case in _CASES, selected) || error("unknown failure case selection")
    script = abspath(joinpath(@__DIR__, "solver_failure_cases.jl"))
    project = Base.active_project()
    timeout_seconds = _timeout_seconds()
    index = Dict{String,Any}[]
    for solver in unique(solvers), case in selected
        push!(index, _run_child(script, project, output_dir, solver, case, timeout_seconds))
    end
    environment = Dict{String,Any}(
        "launcher" => "launch_solver_failure_cases.jl",
        "julia_version" => string(VERSION),
        "julia_executable" => string(Base.julia_cmd()),
    )
    # A successful child writes the richer package/machine fingerprint. Keep
    # it when available without importing any solver package in this parent.
    for entry in index
        file = get(entry, "result_file", nothing)
        file isa AbstractString || continue
        child_index = joinpath(output_dir, "index.json")
        if isfile(child_index)
            parsed = JSON.parsefile(child_index)
            environment = get(parsed, "environment", environment)
            break
        end
    end
    write_json(joinpath(output_dir, "index.json"), Dict(
        "runner_version" => "solver-failure-cases-v2",
        "child_timeout_seconds" => timeout_seconds,
        "environment" => environment,
        "solvers" => unique(solvers),
        "cases" => index,
    ))
    println("wrote isolated solver-failure evidence to $output_dir")
end

main()
