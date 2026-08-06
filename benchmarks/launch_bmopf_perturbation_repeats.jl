#!/usr/bin/env julia

"""Run repeated, isolated BMOPF perturbation matrices.

Each replicate receives its own matrix directory and explicit run identifier.
The child matrix launcher remains responsible for solver/case isolation; this
layer adds repeat provenance and preserves timeout/process evidence.
"""

using JSON

function _int_env(name, default)
    value = try parse(Int, get(ENV, name, string(default)))
    catch; error("$name must be an integer") end
    value > 0 || error("$name must be positive")
    value
end

function _timeout_env(name, default)
    value = try parse(Float64, get(ENV, name, string(default)))
    catch; error("$name must be numeric") end
    value > 0 || error("$name must be positive")
    value
end

function _run_bounded(command, environment, log_path, timeout_seconds)
    process = open(log_path, "w+") do io
        run(pipeline(setenv(command, environment), stdout = io, stderr = io); wait = false)
    end
    deadline = time() + timeout_seconds
    timed_out = false
    while Base.process_running(process) && time() < deadline
        sleep(0.1)
    end
    if Base.process_running(process)
        timed_out = true
        try Base.kill(process, Base.SIGTERM) catch; Base.kill(process) end
        grace = time() + min(10.0, max(1.0, timeout_seconds / 20))
        while Base.process_running(process) && time() < grace
            sleep(0.1)
        end
        if Base.process_running(process)
            try Base.kill(process, Base.SIGKILL) catch; end
        end
    end
    wait(process)
    return (timed_out = timed_out, exit_code = timed_out ? nothing : process.exitcode)
end

function main()
    root = get(ENV, "NLPDIAGNOSTICS_BMOPF_BENCHMARK_ROOT", "")
    isempty(root) && error("Set NLPDIAGNOSTICS_BMOPF_BENCHMARK_ROOT first")
    isdir(root) || error("benchmark root does not exist: $root")
    output_root = abspath(get(ENV, "NLPDIAGNOSTICS_BMOPF_REPEAT_OUTPUT_DIR",
                              joinpath(pwd(), "bmopf-perturbation-repeats")))
    mkpath(output_root)
    replicates = _int_env("NLPDIAGNOSTICS_BMOPF_REPLICATES", 2)
    timeout_seconds = _timeout_env("NLPDIAGNOSTICS_BMOPF_REPEAT_TIMEOUT_SECONDS", 1800)
    project_raw = get(ENV, "NLPDIAGNOSTICS_BENCHMARK_PROJECT", "")
    project = isempty(project_raw) ? Base.active_project() : abspath(project_raw)
    matrix_script = abspath(joinpath(@__DIR__, "launch_bmopf_solver_matrix.jl"))
    summary_script = abspath(joinpath(@__DIR__, "summarize_bmopf_solver_matrix.jl"))
    julia = Base.julia_cmd()
    entries = Dict{String,Any}[]
    for replicate in 1:replicates
        run_id = "repeat_$(lpad(replicate, 2, '0'))"
        matrix_dir = joinpath(output_root, run_id)
        mkpath(matrix_dir)
        environment = copy(ENV)
        environment["NLPDIAGNOSTICS_BMOPF_MATRIX_OUTPUT_DIR"] = matrix_dir
        environment["NLPDIAGNOSTICS_BMOPF_RUN_ID"] = run_id
        environment["NLPDIAGNOSTICS_BMOPF_REPLICATE_INDEX"] = string(replicate)
        matrix_command = isnothing(project) ?
            `$julia --startup-file=no $matrix_script` :
            `$julia --startup-file=no --project=$project $matrix_script`
        process_log = joinpath(matrix_dir, "repeat.process.log")
        result = _run_bounded(matrix_command, environment, process_log, timeout_seconds)
        matrix_index = joinpath(matrix_dir, "matrix_index.json")
        matrix_summary = joinpath(matrix_dir, "matrix_summary.json")
        status = result.timed_out ? "process_timeout" : (result.exit_code == 0 ? "ok" : "process_exit")
        summary_error = nothing
        if status == "ok" && isfile(matrix_index)
            summary_command = isnothing(project) ?
                `$julia --startup-file=no $summary_script $matrix_dir $matrix_summary` :
                `$julia --startup-file=no --project=$project $summary_script $matrix_dir $matrix_summary`
            try
                run(setenv(summary_command, environment))
            catch error
                status = "summary_error"
                summary_error = sprint(showerror, error)
            end
        end
        entry = Dict{String,Any}(
            "run_id" => run_id, "replicate_index" => replicate,
            "status" => status, "matrix_directory" => matrix_dir,
            "matrix_index" => isfile(matrix_index) ? matrix_index : nothing,
            "matrix_summary" => isfile(matrix_summary) ? matrix_summary : nothing,
            "process_log" => process_log,
            "process_timeout" => result.timed_out,
            "process_exit_code" => result.exit_code,
        )
        !isnothing(summary_error) && (entry["summary_error"] = summary_error)
        push!(entries, entry)
        println("$run_id: $status")
    end
    write(joinpath(output_root, "repeat_index.json"), JSON.json(Dict(
        "runner_version" => "bmopf-perturbation-repeats-v1",
        "benchmark_root" => abspath(root),
        "replicate_count" => replicates,
        "repeat_timeout_seconds" => timeout_seconds,
        "solvers" => get(ENV, "NLPDIAGNOSTICS_BMOPF_SOLVERS", "ipopt,madnlp"),
        "cases" => get(ENV, "NLPDIAGNOSTICS_BMOPF_CASES", ""),
        "family_perturbations_enabled" => get(ENV, "NLPDIAGNOSTICS_BMOPF_RUN_FAMILY_PERTURBATIONS", "false"),
        "family_perturbation_families" => get(ENV, "NLPDIAGNOSTICS_BMOPF_PERTURBATION_FAMILIES", ""),
        "environment" => Dict("julia_version" => string(VERSION),
                               "julia_executable" => string(Base.julia_cmd()),
                               "project" => project),
        "entries" => entries,
    )))
    println("wrote repeated BMOPF perturbation manifest to $(joinpath(output_root, "repeat_index.json"))")
end

main()
