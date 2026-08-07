#!/usr/bin/env julia

"""Run a solver-by-snapshot BMOPF matrix with durable process evidence.

This parent imports only JSON. Each solver/snapshot pair gets its own child
Julia process and output directory, so a native exit, package failure, or
timeout cannot hide results for the remaining matrix entries. Summaries are
intentionally produced by the existing `summarize_bmopf_solver_trace.jl`
command after the matrix completes.
"""

using JSON

function _list(name, defaults)
    selected = filter(!isempty, strip.(split(get(ENV, name, ""), ',')))
    isempty(selected) && return String[defaults...]
    return String[selected...]
end

function _timeout_seconds()
    value = try
        parse(Float64, get(ENV, "NLPDIAGNOSTICS_BMOPF_MATRIX_TIMEOUT_SECONDS", "900"))
    catch
        error("NLPDIAGNOSTICS_BMOPF_MATRIX_TIMEOUT_SECONDS must be numeric")
    end
    value > 0 || error("NLPDIAGNOSTICS_BMOPF_MATRIX_TIMEOUT_SECONDS must be positive")
    return value
end

function _case_name(relative)
    return replace(replace(relative, '/' => "__"), ".bmopf.json" => "")
end

function _record_termination(record)
    solver_profile = get(record, "solver_profile", nothing)
    solver_profile isa AbstractDict || return "unknown"
    nested = get(solver_profile, "solver_profile", nothing)
    nested isa AbstractDict || return "unknown"
    postmortem = get(nested, "postmortem", nothing)
    postmortem isa AbstractDict || return "unknown"
    return get(postmortem, "termination", "unknown")
end

function _child_index(root, solver, timeout_seconds, project, entries)
    return Dict(
        "runner_version" => "bmopf-solver-matrix-child-index-v2",
        "benchmark_root" => root,
        "solver" => solver,
        "child_timeout_seconds" => timeout_seconds,
        "environment" => Dict(
            "julia_version" => string(VERSION),
            "julia_executable" => string(Base.julia_cmd()),
            "project" => project,
            "local_package_load_path" => normpath(joinpath(@__DIR__, "..")),
        ),
        "cases" => entries,
    )
end

function _matrix_index(root, output_root, project, solvers, cases, timeout_seconds, entries)
    return Dict(
        "runner_version" => "bmopf-solver-matrix-v3",
        "benchmark_root" => root,
        "output_root" => output_root,
        "solvers" => solvers,
        "cases" => cases,
        "child_timeout_seconds" => timeout_seconds,
        "capture_logs" => get(ENV, "NLPDIAGNOSTICS_BMOPF_CAPTURE_LOGS", "false"),
        "capture_points" => get(ENV, "NLPDIAGNOSTICS_BMOPF_CAPTURE_POINTS", "false"),
        "family_perturbations_enabled" => get(ENV, "NLPDIAGNOSTICS_BMOPF_RUN_FAMILY_PERTURBATIONS", "false"),
        "family_perturbation_families" => get(ENV, "NLPDIAGNOSTICS_BMOPF_PERTURBATION_FAMILIES", ""),
        "family_perturbation_max_iter" => get(ENV, "NLPDIAGNOSTICS_BMOPF_PERTURBATION_MAX_ITER", "100"),
        "run_id" => get(ENV, "NLPDIAGNOSTICS_BMOPF_RUN_ID", "default"),
        "replicate_index" => get(ENV, "NLPDIAGNOSTICS_BMOPF_REPLICATE_INDEX", "1"),
        "environment" => Dict(
            "julia_version" => string(VERSION),
            "julia_executable" => string(Base.julia_cmd()),
            "project" => project,
            "local_package_load_path" => normpath(joinpath(@__DIR__, "..")),
        ),
        "entries" => entries,
    )
end

function _run_pair(script, project, root, output_root, solver, relative, timeout_seconds)
    solver_dir = joinpath(output_root, solver)
    mkpath(solver_dir)
    child_env = copy(ENV)
    repository_root = normpath(joinpath(@__DIR__, ".."))
    existing_load_path = get(child_env, "JULIA_LOAD_PATH", "@")
    child_env["JULIA_LOAD_PATH"] = string(repository_root, ':', existing_load_path)
    child_env["NLPDIAGNOSTICS_BMOPF_BENCHMARK_ROOT"] = root
    child_env["NLPDIAGNOSTICS_BMOPF_CASES"] = relative
    child_env["NLPDIAGNOSTICS_BMOPF_SOLVER"] = solver
    child_env["NLPDIAGNOSTICS_BMOPF_OUTPUT_DIR"] = solver_dir
    process_log = joinpath(solver_dir, "$(_case_name(relative)).matrix.process.log")
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
            try Base.kill(process, Base.SIGKILL) catch; Base.kill(process) end
        end
    end
    wait_error = nothing
    try
        wait(process)
    catch error
        wait_error = sprint(showerror, error)
    end
    exit_code = if timed_out
        nothing
    else
        try process.exitcode catch; nothing end
    end
    result_file = "$(_case_name(relative)).json"
    result_path = joinpath(solver_dir, result_file)
    if isfile(result_path)
        record = JSON.parsefile(result_path)
        return Dict{String,Any}(
            "solver" => solver,
            "snapshot" => relative,
            "output_directory" => solver_dir,
            "result_file" => result_file,
            "status" => get(record, "status", "unknown"),
            "termination" => _record_termination(record),
            "process_exit_code" => exit_code,
            "process_timeout" => timed_out,
            "process_wait_error" => wait_error,
            "process_log" => basename(process_log),
            "family_perturbations_enabled" => get(record, "family_perturbations_enabled", nothing),
            "family_perturbation_families" => get(record, "family_perturbation_families", Any[]),
            "family_perturbation_max_iter" => get(record, "family_perturbation_max_iter", nothing),
            "run_id" => get(record, "run_id", get(ENV, "NLPDIAGNOSTICS_BMOPF_RUN_ID", "default")),
            "replicate_index" => get(record, "replicate_index", get(ENV, "NLPDIAGNOSTICS_BMOPF_REPLICATE_INDEX", "1")),
            "environment_fingerprint" => get(record, "environment_fingerprint", nothing),
        )
    end
    return Dict{String,Any}(
        "solver" => solver,
        "snapshot" => relative,
        "output_directory" => solver_dir,
        "result_file" => nothing,
        "status" => timed_out ? "process_timeout" : "process_exit",
        "termination" => timed_out ? "process_timeout" : "process_exit",
        "process_exit_code" => exit_code,
        "process_timeout" => timed_out,
        "process_wait_error" => wait_error,
        "process_log" => basename(process_log),
        "family_perturbations_enabled" => get(ENV, "NLPDIAGNOSTICS_BMOPF_RUN_FAMILY_PERTURBATIONS", "false"),
        "family_perturbation_families" => get(ENV, "NLPDIAGNOSTICS_BMOPF_PERTURBATION_FAMILIES", ""),
        "family_perturbation_max_iter" => get(ENV, "NLPDIAGNOSTICS_BMOPF_PERTURBATION_MAX_ITER", "100"),
        "run_id" => get(ENV, "NLPDIAGNOSTICS_BMOPF_RUN_ID", "default"),
        "replicate_index" => get(ENV, "NLPDIAGNOSTICS_BMOPF_REPLICATE_INDEX", "1"),
    )
end

function main()
    root = get(ENV, "NLPDIAGNOSTICS_BMOPF_BENCHMARK_ROOT", "")
    isempty(root) && error("Set NLPDIAGNOSTICS_BMOPF_BENCHMARK_ROOT first")
    isdir(root) || error("benchmark root does not exist: $root")
    solvers = lowercase.(_list("NLPDIAGNOSTICS_BMOPF_SOLVERS", ["ipopt", "madnlp"]))
    all(solver -> solver in ("ipopt", "madnlp"), solvers) ||
        error("NLPDIAGNOSTICS_BMOPF_SOLVERS must contain only ipopt or madnlp")
    cases = _list("NLPDIAGNOSTICS_BMOPF_CASES", [
        "ENWLsnapshots/30bus_LN/30bus_LN_t01_0800.bmopf.json",
    ])
    for relative in cases
        isabspath(relative) && error("case selections must be relative to the benchmark root")
        endswith(relative, ".bmopf.json") || error("case is not a .bmopf.json snapshot: $relative")
        isfile(joinpath(root, relative)) || error("selected snapshot is missing: $(joinpath(root, relative))")
    end
    output_root = abspath(get(
        ENV, "NLPDIAGNOSTICS_BMOPF_MATRIX_OUTPUT_DIR",
        joinpath(pwd(), "bmopf-solver-matrix-results"),
    ))
    mkpath(output_root)
    script = abspath(joinpath(@__DIR__, "bmopf_solver_trace.jl"))
    project = get(ENV, "NLPDIAGNOSTICS_BENCHMARK_PROJECT", "")
    project = isempty(project) ? Base.active_project() : abspath(project)
    timeout_seconds = _timeout_seconds()
    entries = Dict{String,Any}[]
    matrix_index_path = joinpath(output_root, "matrix_index.json")
    for solver in unique(solvers), relative in cases
        entry = _run_pair(script, project, abspath(root), output_root,
                          solver, relative, timeout_seconds)
        push!(entries, entry)
        for selected_solver in unique(solvers)
            solver_entries = [item for item in entries if item["solver"] == selected_solver]
            mkpath(joinpath(output_root, selected_solver))
            write(joinpath(output_root, selected_solver, "index.json"), JSON.json(
                _child_index(abspath(root), selected_solver, timeout_seconds, project, solver_entries),
            ))
        end
        write(matrix_index_path, JSON.json(_matrix_index(abspath(root), output_root,
            project, unique(solvers), cases, timeout_seconds, entries)))
        println("$(solver)/$(_case_name(relative)): $(entry["status"]) " *
                "timeout=$(entry["process_timeout"])")
    end
    for solver in unique(solvers)
        solver_entries = [entry for entry in entries if entry["solver"] == solver]
        write(joinpath(output_root, solver, "index.json"), JSON.json(
            _child_index(abspath(root), solver, timeout_seconds, project, solver_entries),
        ))
    end
    write(matrix_index_path, JSON.json(_matrix_index(abspath(root), output_root,
        project, unique(solvers), cases, timeout_seconds, entries)))
    println("wrote BMOPF solver matrix manifest to $matrix_index_path")
end

main()
