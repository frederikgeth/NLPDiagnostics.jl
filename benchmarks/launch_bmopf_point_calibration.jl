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

Every explicitly selected case runs in its own child process. Set
`NLPDIAGNOSTICS_BMOPF_CALIBRATION_MAX_RSS_MIB` to a positive value to poll the
child resident set and terminate it when the declared memory budget is
crossed. Zero (the default) disables the RSS limit but records that fact; the
elapsed-time limit remains active.
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

function _nonnegative_memory_mib(name, default)
    raw = get(ENV, name, string(default))
    value = tryparse(Float64, raw)
    isnothing(value) && error("$name must be numeric, got '$raw'")
    isfinite(value) && value >= 0 ||
        error("$name must be finite and nonnegative, got $value")
    return value
end

function _boolean(name, default = false)
    raw = lowercase(strip(get(ENV, name, string(default))))
    raw in ("1", "true", "yes", "on") && return true
    raw in ("0", "false", "no", "off") && return false
    error("$name must be boolean, got '$raw'")
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

function _selected_cases()
    raw = get(ENV, "NLPDIAGNOSTICS_BMOPF_CASES", "")
    cases = unique(filter(!isempty, strip.(split(raw, ','))))
    return isempty(cases) ? Union{Nothing,String}[nothing] :
           Union{Nothing,String}[String(case) for case in cases]
end

function _case_slug(case_selector)
    isnothing(case_selector) && return "selected_corpus"
    slug = replace(String(case_selector), r"\.bmopf\.json$" => "")
    return replace(slug, r"[^A-Za-z0-9_.-]+" => "__")
end

_entry_key(point, replicate, case_selector) =
    (String(point), Int(replicate), isnothing(case_selector) ? nothing : String(case_selector))

function _entry_key(entry::AbstractDict)
    return _entry_key(
        get(entry, "point", ""), get(entry, "replicate", 0),
        get(entry, "case_selector", nothing),
    )
end

function _completed_entry(entry)
    String(get(entry, "status", "")) == "ok" || return false
    output_directory = String(get(entry, "output_directory", ""))
    !isempty(output_directory) &&
        isfile(joinpath(output_directory, "index.json")) || return false
    case_count = Int(get(entry, "child_case_count", 0))
    case_count > 0 || return false
    statuses = get(entry, "child_status_counts", Dict())
    statuses isa AbstractDict || return false
    return Int(get(statuses, "ok", 0)) == case_count
end

function _attempt_record(entry)
    return Dict{String,Any}(
        "attempt" => get(entry, "attempt", 1),
        "status" => get(entry, "status", "unknown"),
        "process_timeout" => get(entry, "process_timeout", false),
        "process_memory_limit_exceeded" => get(
            entry, "process_memory_limit_exceeded", false,
        ),
        "process_exit_code" => get(entry, "process_exit_code", nothing),
        "process_wait_error" => get(entry, "process_wait_error", nothing),
        "elapsed_seconds" => get(entry, "elapsed_seconds", nothing),
        "child_timeout_seconds" => get(entry, "child_timeout_seconds", nothing),
        "max_rss_kib_budget" => get(entry, "max_rss_kib_budget", nothing),
        "maximum_observed_rss_kib" => get(
            entry, "maximum_observed_rss_kib", nothing,
        ),
        "rss_monitor_available" => get(
            entry, "rss_monitor_available", nothing,
        ),
        "process_log" => get(entry, "process_log", nothing),
    )
end

function _process_rss_kib(process)
    pid = try
        getpid(process)
    catch
        return nothing
    end
    output = try
        readchomp(ignorestatus(`ps -o rss= -p $pid`))
    catch
        return nothing
    end
    return tryparse(Int, strip(output))
end

function _terminate_process(process, timeout_seconds)
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

function _wait_for_process(process, timeout_seconds, max_rss_kib)
    deadline = time() + timeout_seconds
    maximum_rss_kib = nothing
    rss_monitor_available = max_rss_kib > 0 ? false : nothing
    memory_limit_exceeded = false
    while Base.process_running(process) && time() < deadline
        if max_rss_kib > 0
            rss = _process_rss_kib(process)
            if !isnothing(rss)
                rss_monitor_available = true
                maximum_rss_kib = isnothing(maximum_rss_kib) ? rss :
                                  max(maximum_rss_kib, rss)
                if rss > max_rss_kib
                    memory_limit_exceeded = true
                    break
                end
            end
        end
        sleep(0.1)
    end
    timed_out = Base.process_running(process)
    if timed_out || memory_limit_exceeded
        _terminate_process(process, timeout_seconds)
    end
    wait_error = nothing
    try
        wait(process)
    catch error
        wait_error = sprint(showerror, error)
    end
    exit_code = timed_out || memory_limit_exceeded ? nothing : try
        process.exitcode
    catch
        nothing
    end
    return (
        timed_out = timed_out && !memory_limit_exceeded,
        memory_limit_exceeded = memory_limit_exceeded,
        maximum_rss_kib = maximum_rss_kib,
        rss_monitor_available = rss_monitor_available,
        exit_code = exit_code,
        wait_error = wait_error,
    )
end

function _child_environment(root, output_dir, specification, case_selector)
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
    isnothing(case_selector) ||
        (child["NLPDIAGNOSTICS_BMOPF_CASES"] = String(case_selector))
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
                    specification, replicate, timeout_seconds, max_rss_kib,
                    case_selector, attempt)
    output_dir = joinpath(
        output_root, point_name, "replicate_$(replicate)",
        _case_slug(case_selector),
    )
    mkpath(output_dir)
    process_log = joinpath(output_dir, "calibration.attempt_$(attempt).process.log")
    command = `$(Base.julia_cmd()) --startup-file=no --project=$project $script`
    started_at = time()
    process = open(process_log, "w+") do io
        run(pipeline(
            setenv(command, _child_environment(
                root, output_dir, specification, case_selector,
            )),
            stdout = io, stderr = io,
        ); wait = false)
    end
    process_result = _wait_for_process(
        process, timeout_seconds, max_rss_kib,
    )
    elapsed_seconds = time() - started_at
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
    status = if process_result.memory_limit_exceeded
        "process_memory_limit"
    elseif process_result.timed_out
        "process_timeout"
    elseif !isnothing(process_result.wait_error) ||
           process_result.exit_code != 0
        "process_exit"
    elseif isempty(cases)
        "child_cases_empty"
    elseif get(statuses, "ok", 0) != length(cases)
        "child_case_failure"
    else
        "ok"
    end
    return Dict{String,Any}(
        "point" => point_name,
        "replicate" => replicate,
        "case_selector" => case_selector,
        "point_policy" => specification.point_policy,
        "result_units" => specification.result_units,
        "result_field_units" => specification.result_field_units,
        "result_suffix" => specification.result_suffix,
        "output_directory" => output_dir,
        "process_log" => basename(process_log),
        "process_timeout" => process_result.timed_out,
        "process_memory_limit_exceeded" =>
            process_result.memory_limit_exceeded,
        "process_exit_code" => process_result.exit_code,
        "process_wait_error" => process_result.wait_error,
        "elapsed_seconds" => elapsed_seconds,
        "child_timeout_seconds" => timeout_seconds,
        "max_rss_kib_budget" => max_rss_kib == 0 ? nothing : max_rss_kib,
        "maximum_observed_rss_kib" => process_result.maximum_rss_kib,
        "rss_monitor_available" => process_result.rss_monitor_available,
        "attempt" => attempt,
        "previous_attempts" => Any[],
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
                   timeout_seconds, max_rss_kib, case_selectors, resume,
                   entries)
    return Dict{String,Any}(
        "runner_version" => "bmopf-point-calibration-launcher-v2",
        "benchmark_root" => root,
        "output_root" => output_root,
        "project" => project,
        "points" => points,
        "repetitions" => repetitions,
        "child_timeout_seconds" => timeout_seconds,
        "max_rss_kib_budget" => max_rss_kib == 0 ? nothing : max_rss_kib,
        "rss_limit_enabled" => max_rss_kib > 0,
        "case_isolation" => !all(isnothing, case_selectors),
        "case_selectors" => case_selectors,
        "resume" => resume,
        "expected_child_count" =>
            length(points) * repetitions * length(case_selectors),
        "rank_max_dense_entries" => get(
            ENV, "NLPDIAGNOSTICS_BMOPF_RANK_MAX_DENSE_ENTRIES", "0",
        ),
        "family_scaling_experiments" => get(
            ENV, "NLPDIAGNOSTICS_BMOPF_FAMILY_SCALING_EXPERIMENTS", "",
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


function _resume_entries(manifest_path, root, project, points, repetitions,
                         case_selectors, rank_max_dense_entries,
                         max_rss_kib)
    isfile(manifest_path) || return Dict{String,Any}[]
    manifest = JSON.parsefile(manifest_path)
    manifest isa AbstractDict || error("existing calibration manifest is not an object")
    checks = (
        "benchmark_root" => root,
        "project" => project,
        "points" => points,
        "repetitions" => repetitions,
        "case_selectors" => case_selectors,
        "rank_max_dense_entries" => rank_max_dense_entries,
        "max_rss_kib_budget" => max_rss_kib == 0 ? nothing : max_rss_kib,
        "family_scaling_experiments" => get(
            ENV, "NLPDIAGNOSTICS_BMOPF_FAMILY_SCALING_EXPERIMENTS", "",
        ),
    )
    for (key, expected) in checks
        get(manifest, key, nothing) == expected || error(
            "cannot resume point calibration: existing $key does not match",
        )
    end
    expected_keys = Set(
        _entry_key(point, replicate, case_selector)
        for point in points, replicate in 1:repetitions,
            case_selector in case_selectors
    )
    entries = Dict{String,Any}[]
    for raw in get(manifest, "runs", Any[])
        raw isa AbstractDict || continue
        entry = Dict{String,Any}(String(key) => value for (key, value) in raw)
        _entry_key(entry) in expected_keys || continue
        push!(entries, entry)
    end
    return entries
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
    case_selectors = _selected_cases()
    repetitions = _positive_integer(
        "NLPDIAGNOSTICS_BMOPF_CALIBRATION_REPETITIONS", 2,
    )
    timeout_seconds = _positive_seconds(
        "NLPDIAGNOSTICS_BMOPF_CALIBRATION_TIMEOUT_SECONDS", 900,
    )
    max_rss_mib = _nonnegative_memory_mib(
        "NLPDIAGNOSTICS_BMOPF_CALIBRATION_MAX_RSS_MIB", 0,
    )
    max_rss_kib = max_rss_mib == 0 ? 0 : ceil(Int, max_rss_mib * 1024)
    resume = _boolean("NLPDIAGNOSTICS_BMOPF_CALIBRATION_RESUME", false)
    script = abspath(joinpath(@__DIR__, "bmopf_draft_corpus.jl"))
    manifest_path = joinpath(output_root, "calibration_index.json")
    entries = resume ? _resume_entries(
        manifest_path, root, project, points, repetitions, case_selectors,
        get(ENV, "NLPDIAGNOSTICS_BMOPF_RANK_MAX_DENSE_ENTRIES", "0"),
        max_rss_kib,
    ) : Dict{String,Any}[]
    for point in points, replicate in 1:repetitions, case_selector in case_selectors
        key = _entry_key(point, replicate, case_selector)
        position = findfirst(entry -> _entry_key(entry) == key, entries)
        if !isnothing(position) && _completed_entry(entries[position])
            label = isnothing(case_selector) ? "selected corpus" : case_selector
            println("$point replicate $replicate $label: resume-skip")
            continue
        end
        previous_attempts = Any[]
        attempt = 1
        if !isnothing(position)
            previous = entries[position]
            append!(previous_attempts, get(previous, "previous_attempts", Any[]))
            push!(previous_attempts, _attempt_record(previous))
            attempt = Int(get(previous, "attempt", 1)) + 1
            deleteat!(entries, position)
        end
        entry = _run_child(
            script, project, root, output_root, point,
            _CALIBRATION_POINTS[point], replicate, timeout_seconds,
            max_rss_kib, case_selector, attempt,
        )
        entry["previous_attempts"] = previous_attempts
        push!(entries, entry)
        write(manifest_path, JSON.json(_manifest(
            root, output_root, project, points, repetitions,
            timeout_seconds, max_rss_kib, case_selectors, resume, entries,
        )))
        label = isnothing(case_selector) ? "selected corpus" : case_selector
        println("$point replicate $replicate $label: $(entry["status"])")
    end
    write(manifest_path, JSON.json(_manifest(
        root, output_root, project, points, repetitions,
        timeout_seconds, max_rss_kib, case_selectors, resume, entries,
    )))
    println("wrote BMOPF point-calibration manifest to $manifest_path")
end

main()
