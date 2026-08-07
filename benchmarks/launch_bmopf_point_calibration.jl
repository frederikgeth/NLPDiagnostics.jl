#!/usr/bin/env julia

"""Run repeated BMOPF profiles at model starts and saved solver points.

This launcher is deliberately narrower than the saved-result unit-policy
matrix. Its purpose is to distinguish repeatability at one evaluation point
from persistence across evaluation points. Each child is an ordinary
`bmopf_draft_corpus.jl` run, so model construction, trust metadata, registry
coverage, and dense-work guards remain identical to the normal corpus path.

The default policies are `engine_start,saved_si,saved_pu`, with two repeated
children per policy. Override them with
`NLPDIAGNOSTICS_BMOPF_CALIBRATION_POINTS` and
`NLPDIAGNOSTICS_BMOPF_CALIBRATION_REPETITIONS`. Dense numerical algebra is
disabled by default; opt in with the ordinary
`NLPDIAGNOSTICS_BMOPF_RANK_MAX_DENSE_ENTRIES` variable.
"""

using JSON

const _CALIBRATION_POINTS = Dict{String,NamedTuple}(
    "engine_start" => (
        point_policy = "bmopf_start_values", result_units = nothing,
        result_field_units = "", result_suffix = nothing,
    ),
    "saved_si" => (
        point_policy = "saved_result", result_units = "si",
        result_field_units = "", result_suffix = "_result_si.json",
    ),
    "saved_pu" => (
        point_policy = "saved_result", result_units = "pu",
        result_field_units = "", result_suffix = "_result_pu.json",
    ),
)

function _positive_integer(name, default)
    raw = get(ENV, name, string(default))
    value = tryparse(Int, raw)
    isnothing(value) && error("$name must be an integer, got '$raw'")
    value > 0 || error("$name must be positive, got $value")
    return value
end

function _positive_seconds(name, default)
    raw = get(ENV, name, string(default))
    value = tryparse(Float64, raw)
    isnothing(value) && error("$name must be numeric, got '$raw'")
    value > 0 || error("$name must be positive, got $value")
    return value
end

function _selected_points()
    raw = filter(!isempty, strip.(split(get(
        ENV, "NLPDIAGNOSTICS_BMOPF_CALIBRATION_POINTS",
        "engine_start,saved_si,saved_pu",
    ), ',')))
    isempty(raw) && error("point calibration selected no evaluation policies")
    unknown = setdiff(raw, collect(keys(_CALIBRATION_POINTS)))
    isempty(unknown) || error(
        "unknown calibration points $(join(unknown, ", ")); supported points are " *
        join(sort!(collect(keys(_CALIBRATION_POINTS))), ", "),
    )
    return unique(raw)
end

function _wait_for_process(process, timeout_seconds)
    deadline = time() + timeout_seconds
    while Base.process_running(process) && time() < deadline
        sleep(0.1)
    end
    timed_out = Base.process_running(process)
    if timed_out
        try
            Base.kill(process, Base.SIGTERM)
        catch
            Base.kill(process)
        end
        grace_deadline = time() + min(10.0, max(1.0, timeout_seconds / 20))
        while Base.process_running(process) && time() < grace_deadline
            sleep(0.1)
        end
        Base.process_running(process) && try
            Base.kill(process, Base.SIGKILL)
        catch
            Base.kill(process)
        end
    end
    wait_error = nothing
    try
        wait(process)
    catch error
        wait_error = sprint(showerror, error)
    end
    exit_code = timed_out ? nothing : try
        process.exitcode
    catch
        nothing
    end
    return timed_out, exit_code, wait_error
end

function _child_environment(root, output_dir, specification)
    child = copy(ENV)
    repository_root = normpath(joinpath(@__DIR__, ".."))
    child["JULIA_LOAD_PATH"] = string(
        repository_root, ':', get(child, "JULIA_LOAD_PATH", "@"),
    )
    child["NLPDIAGNOSTICS_BMOPF_BENCHMARK_ROOT"] = root
    child["NLPDIAGNOSTICS_BMOPF_OUTPUT_DIR"] = output_dir
    child["NLPDIAGNOSTICS_BMOPF_POINT_POLICY"] = specification.point_policy
    child["NLPDIAGNOSTICS_BMOPF_ANALYSIS_MODE"] = "profile"
    child["NLPDIAGNOSTICS_BMOPF_FORCE"] = "true"
    haskey(child, "NLPDIAGNOSTICS_BMOPF_RANK_MAX_DENSE_ENTRIES") ||
        (child["NLPDIAGNOSTICS_BMOPF_RANK_MAX_DENSE_ENTRIES"] = "0")
    if isnothing(specification.result_units)
        for key in (
            "NLPDIAGNOSTICS_BMOPF_RESULT_UNITS",
            "NLPDIAGNOSTICS_BMOPF_RESULT_FIELD_UNITS",
            "NLPDIAGNOSTICS_BMOPF_RESULT_SUFFIX",
        )
            pop!(child, key, nothing)
        end
    else
        child["NLPDIAGNOSTICS_BMOPF_RESULT_UNITS"] = specification.result_units
        child["NLPDIAGNOSTICS_BMOPF_RESULT_FIELD_UNITS"] =
            specification.result_field_units
        child["NLPDIAGNOSTICS_BMOPF_RESULT_SUFFIX"] =
            specification.result_suffix
    end
    return child
end

function _run_child(script, project, root, output_root, point_name,
                    specification, replicate, timeout_seconds)
    output_dir = joinpath(output_root, point_name, "replicate_$(replicate)")
    mkpath(output_dir)
    process_log = joinpath(output_dir, "calibration.process.log")
    command = `$(Base.julia_cmd()) --startup-file=no --project=$project $script`
    process = open(process_log, "w+") do io
        run(pipeline(
            setenv(command, _child_environment(root, output_dir, specification)),
            stdout = io, stderr = io,
        ); wait = false)
    end
    timed_out, exit_code, wait_error =
        _wait_for_process(process, timeout_seconds)
    index_path = joinpath(output_dir, "index.json")
    index = if isfile(index_path)
        try
            value = JSON.parsefile(index_path)
            value isa AbstractDict ? value : Dict{String,Any}()
        catch
            Dict{String,Any}()
        end
    else
        Dict{String,Any}()
    end
    cases = get(index, "cases", Any[])
    cases isa AbstractVector || (cases = Any[])
    statuses = Dict{String,Int}()
    for case in cases
        case isa AbstractDict || continue
        status = String(get(case, "status", "unknown"))
        statuses[status] = get(statuses, status, 0) + 1
    end
    status = timed_out ? "process_timeout" :
        (!isnothing(wait_error) || exit_code != 0 ? "process_exit" : "ok")
    return Dict{String,Any}(
        "point" => point_name,
        "replicate" => replicate,
        "point_policy" => specification.point_policy,
        "result_units" => specification.result_units,
        "result_field_units" => specification.result_field_units,
        "result_suffix" => specification.result_suffix,
        "output_directory" => output_dir,
        "process_log" => basename(process_log),
        "process_timeout" => timed_out,
        "process_exit_code" => exit_code,
        "process_wait_error" => wait_error,
        "status" => status,
        "child_index_available" => !isempty(index),
        "child_runner_version" => get(index, "runner_version", nothing),
        "child_environment_fingerprint" =>
            get(index, "environment_fingerprint", nothing),
        "child_case_count" => length(cases),
        "child_status_counts" => statuses,
        "rank_max_dense_entries" =>
            get(index, "rank_max_dense_entries", nothing),
    )
end

function _manifest(root, output_root, project, points, repetitions,
                   timeout_seconds, entries)
    return Dict{String,Any}(
        "runner_version" => "bmopf-point-calibration-launcher-v1",
        "benchmark_root" => root,
        "output_root" => output_root,
        "project" => project,
        "points" => points,
        "repetitions" => repetitions,
        "child_timeout_seconds" => timeout_seconds,
        "rank_max_dense_entries" => get(
            ENV, "NLPDIAGNOSTICS_BMOPF_RANK_MAX_DENSE_ENTRIES", "0",
        ),
        "cases" => get(ENV, "NLPDIAGNOSTICS_BMOPF_CASES", ""),
        "case_selection" => get(
            ENV, "NLPDIAGNOSTICS_BMOPF_CASE_SELECTION", "",
        ),
        "environment_fingerprints" => sort!(unique(filter(
            value -> value isa AbstractString && !isempty(value),
            [get(entry, "child_environment_fingerprint", nothing)
             for entry in entries],
        ))),
        "runs" => entries,
    )
end

function main()
    root = get(ENV, "NLPDIAGNOSTICS_BMOPF_BENCHMARK_ROOT", "")
    isempty(root) && error("Set NLPDIAGNOSTICS_BMOPF_BENCHMARK_ROOT first")
    root = abspath(root)
    isdir(root) || error("benchmark root does not exist: $root")
    output_root = abspath(get(
        ENV, "NLPDIAGNOSTICS_BMOPF_CALIBRATION_OUTPUT_DIR",
        joinpath(pwd(), "bmopf-point-calibration-results"),
    ))
    mkpath(output_root)
    project = get(ENV, "NLPDIAGNOSTICS_BENCHMARK_PROJECT", "")
    project = isempty(project) ? Base.active_project() : abspath(project)
    points = _selected_points()
    repetitions = _positive_integer(
        "NLPDIAGNOSTICS_BMOPF_CALIBRATION_REPETITIONS", 2,
    )
    timeout_seconds = _positive_seconds(
        "NLPDIAGNOSTICS_BMOPF_CALIBRATION_TIMEOUT_SECONDS", 900,
    )
    script = abspath(joinpath(@__DIR__, "bmopf_draft_corpus.jl"))
    entries = Dict{String,Any}[]
    manifest_path = joinpath(output_root, "calibration_index.json")
    for point in points, replicate in 1:repetitions
        entry = _run_child(
            script, project, root, output_root, point,
            _CALIBRATION_POINTS[point], replicate, timeout_seconds,
        )
        push!(entries, entry)
        write(manifest_path, JSON.json(_manifest(
            root, output_root, project, points, repetitions,
            timeout_seconds, entries,
        )))
        println("$point replicate $replicate: $(entry["status"])")
    end
    write(manifest_path, JSON.json(_manifest(
        root, output_root, project, points, repetitions,
        timeout_seconds, entries,
    )))
    println("wrote BMOPF point-calibration manifest to $manifest_path")
end

main()
