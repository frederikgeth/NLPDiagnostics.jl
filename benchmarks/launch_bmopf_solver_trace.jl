#!/usr/bin/env julia

"""Run selected BMOPF solver-trace cases in isolated child processes.

The parent imports only JSON and launches one case at a time. This keeps a
native solver exit, package load failure, or per-case exception from hiding
completed records for the other snapshots. Child JSON and solver-owned logs
remain in the shared output directory; the parent adds process status and
stdout/stderr evidence to `index.json`.
"""

using JSON

function _selected_cases()
    raw = filter(!isempty, strip.(split(
        get(ENV, "NLPDIAGNOSTICS_BMOPF_CASES", ""), ',';
    )))
    isempty(raw) && return String[
        "ENWLsnapshots/30bus_LN/30bus_LN_t01_0800.bmopf.json",
    ]
    return String[raw...]
end

function _case_name(relative)
    return replace(replace(relative, '/' => "__"), ".bmopf.json" => "")
end

function _timeout_seconds()
    value = try
        parse(Float64, get(ENV, "NLPDIAGNOSTICS_BMOPF_CHILD_TIMEOUT_SECONDS", "900"))
    catch
        error("NLPDIAGNOSTICS_BMOPF_CHILD_TIMEOUT_SECONDS must be numeric")
    end
    value > 0 || error("NLPDIAGNOSTICS_BMOPF_CHILD_TIMEOUT_SECONDS must be positive")
    return value
end

function _run_child(script, project, output_dir, relative, timeout_seconds)
    child_env = copy(ENV)
    child_env["NLPDIAGNOSTICS_BMOPF_CASES"] = relative
    child_env["NLPDIAGNOSTICS_BMOPF_OUTPUT_DIR"] = output_dir
    process_log = joinpath(output_dir, "$(_case_name(relative)).process.log")
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
        # A Julia child can be inside native solver/JIT code when the timeout
        # fires and may not service SIGTERM promptly.  Do not let the parent
        # block forever in `wait(process)`: give it a short grace period, then
        # escalate to SIGKILL and retain the timeout evidence in the index.
        grace_deadline = time() + min(10.0, max(1.0, timeout_seconds / 20))
        while Base.process_running(process) && time() < grace_deadline
            sleep(0.1)
        end
        if Base.process_running(process)
            try
                Base.kill(process, Base.SIGKILL)
            catch
                Base.kill(process)
            end
        end
    end
    wait(process)
    exit_code = timed_out ? nothing : process.exitcode
    result_file = "$(_case_name(relative)).json"
    result_path = joinpath(output_dir, result_file)
    if isfile(result_path)
        record = JSON.parsefile(result_path)
        return Dict{String,Any}(
            "name" => _case_name(relative),
            "snapshot" => relative,
            "result_file" => result_file,
            "status" => get(record, "status", "unknown"),
            "solver" => get(record, "solver", get(ENV, "NLPDIAGNOSTICS_BMOPF_SOLVER", "unknown")),
            "environment_fingerprint" => get(record, "environment_fingerprint", nothing),
            "solver_options" => get(record, "solver_options", Dict()),
            "per_unit" => get(record, "per_unit", nothing),
            "capture_points" => get(record, "capture_points", nothing),
            "capture_logs" => get(record, "capture_logs", nothing),
            "family_perturbations_enabled" => get(record, "family_perturbations_enabled", nothing),
            "family_perturbation_families" => get(record, "family_perturbation_families", Any[]),
            "family_perturbation_max_iter" => get(record, "family_perturbation_max_iter", nothing),
            "process_exit_code" => exit_code,
            "process_log" => basename(process_log),
            "process_timeout" => timed_out,
        )
    end
    return Dict{String,Any}(
        "name" => _case_name(relative),
        "snapshot" => relative,
        "result_file" => nothing,
        "status" => "process_exit",
        "solver" => get(ENV, "NLPDIAGNOSTICS_BMOPF_SOLVER", "unknown"),
        "process_exit_code" => exit_code,
        "process_log" => basename(process_log),
        "process_timeout" => timed_out,
    )
end

function main()
    root = get(ENV, "NLPDIAGNOSTICS_BMOPF_BENCHMARK_ROOT", "")
    isempty(root) && error("Set NLPDIAGNOSTICS_BMOPF_BENCHMARK_ROOT first")
    isdir(root) || error("benchmark root does not exist: $root")
    output_dir = abspath(get(
        ENV, "NLPDIAGNOSTICS_BMOPF_OUTPUT_DIR",
        joinpath(pwd(), "bmopf-solver-trace-isolated-results"),
    ))
    mkpath(output_dir)
    script = abspath(joinpath(@__DIR__, "bmopf_solver_trace.jl"))
    timeout_seconds = _timeout_seconds()
    project = get(ENV, "NLPDIAGNOSTICS_BENCHMARK_PROJECT", "")
    project = isempty(project) ? Base.active_project() : abspath(project)
    entries = Dict{String,Any}[]
    for relative in _selected_cases()
        isabspath(relative) && error("case selections must be relative to the benchmark root")
        endswith(relative, ".bmopf.json") || error("case is not a .bmopf.json snapshot: $relative")
        isfile(joinpath(root, relative)) || error("selected snapshot is missing: $(joinpath(root, relative))")
        push!(entries, _run_child(script, project, output_dir, relative, timeout_seconds))
        println("$(entries[end]["name"]): $(entries[end]["status"]) exit=$(entries[end]["process_exit_code"])")
    end
    write(joinpath(output_dir, "index.json"), JSON.json(Dict(
        "runner_version" => "bmopf-solver-trace-isolated-v1",
        "child_timeout_seconds" => timeout_seconds,
        "benchmark_root" => abspath(root),
        "solver" => get(ENV, "NLPDIAGNOSTICS_BMOPF_SOLVER", "unknown"),
        "environment_fingerprint" => isempty(entries) ? nothing :
            get(first(entries), "environment_fingerprint", nothing),
        "solver_options" => isempty(entries) ? Dict() :
            get(first(entries), "solver_options", Dict()),
        "capture_points" => get(ENV, "NLPDIAGNOSTICS_BMOPF_CAPTURE_POINTS", "false"),
        "capture_logs" => get(ENV, "NLPDIAGNOSTICS_BMOPF_CAPTURE_LOGS", "false"),
        "family_perturbations_enabled" => get(
            ENV, "NLPDIAGNOSTICS_BMOPF_RUN_FAMILY_PERTURBATIONS", "false",
        ),
        "family_perturbation_families" => get(
            ENV, "NLPDIAGNOSTICS_BMOPF_PERTURBATION_FAMILIES", "",
        ),
        "family_perturbation_max_iter" => get(
            ENV, "NLPDIAGNOSTICS_BMOPF_PERTURBATION_MAX_ITER", "100",
        ),
        "environment" => Dict(
            "julia_version" => string(VERSION),
            "julia_executable" => string(Base.julia_cmd()),
            "project" => project,
        ),
        "cases" => entries,
    )))
    println("wrote isolated BMOPF solver-trace evidence to $output_dir")
end

main()
