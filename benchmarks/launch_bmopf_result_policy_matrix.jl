#!/usr/bin/env julia

"""Run saved-result BMOPF profiles under a small explicit unit-policy matrix.

Each policy is isolated in a child Julia process and receives its own output
directory. This makes unit-policy failures distinguishable from model-profile
failures and leaves durable records for
`compare_bmopf_saved_result_profiles.jl`.

The default matrix is `si,pu,pu_bus_si,pu_all_si`. Select a subset with
`NLPDIAGNOSTICS_BMOPF_POLICY_MATRIX`, and use the ordinary corpus environment
variables to choose cases, dense-rank limits, and timeouts. To isolate a unit
conversion policy from the saved-file choice, override suffixes with
`NLPDIAGNOSTICS_BMOPF_POLICY_RESULT_SUFFIXES=name=_result_foo.json,...`.
"""

using JSON

Base.include(@__MODULE__, joinpath(@__DIR__, "common.jl"))
using .NLPDiagnosticsBenchmarkCommon: write_json

const _ALL_SI = "bus_voltage=si,line_current=si,load_current=si,generator_current=si,generator_power=si,source_current=si,ibr_current=si,ibr_power=si,switch_current=si,ground_current=si"
const _POLICIES = Dict{String,NamedTuple}(
    "si" => (result_units = "si", field_units = ""),
    "pu" => (result_units = "pu", field_units = ""),
    "pu_bus_si" => (result_units = "pu", field_units = "bus_voltage=si"),
    "pu_all_si" => (result_units = "pu", field_units = _ALL_SI),
)

function _result_suffixes()
    raw = strip(get(ENV, "NLPDIAGNOSTICS_BMOPF_POLICY_RESULT_SUFFIXES", ""))
    isempty(raw) && return Dict{String,String}()
    suffixes = Dict{String,String}()
    for token in split(raw, ',')
        item = strip(token)
        isempty(item) && continue
        parts = split(item, '='; limit = 2)
        length(parts) == 2 || error(
            "NLPDIAGNOSTICS_BMOPF_POLICY_RESULT_SUFFIXES entries must use name=suffix.json, got '$item'",
        )
        name = strip(parts[1])
        suffix = strip(parts[2])
        haskey(_POLICIES, name) || error("unknown policy in result suffix override: '$name'")
        endswith(suffix, ".json") || error("result suffix for '$name' must end in .json")
        isempty(suffix) && error("result suffix for '$name' must not be empty")
        haskey(suffixes, name) && error("duplicate result suffix override for '$name'")
        suffixes[name] = suffix
    end
    return suffixes
end

function _timeout_seconds()
    value = try parse(Float64, get(ENV, "NLPDIAGNOSTICS_BMOPF_POLICY_TIMEOUT_SECONDS", "900"))
    catch
        error("NLPDIAGNOSTICS_BMOPF_POLICY_TIMEOUT_SECONDS must be numeric")
    end
    value > 0 || error("NLPDIAGNOSTICS_BMOPF_POLICY_TIMEOUT_SECONDS must be positive")
    return value
end

function _selected_policies()
    raw = filter(!isempty, strip.(split(get(
        ENV, "NLPDIAGNOSTICS_BMOPF_POLICY_MATRIX", "si,pu,pu_bus_si,pu_all_si",
    ), ',')))
    isempty(raw) && error("NLPDIAGNOSTICS_BMOPF_POLICY_MATRIX selected no policies")
    all(name -> haskey(_POLICIES, name), raw) || error(
        "unknown policy; supported policies are $(join(sort!(collect(keys(_POLICIES))), ", "))",
    )
    return unique(raw)
end

function _manifest(root, output_root, project, timeout_seconds, result_suffixes, entries)
    return Dict(
        "runner_version" => "bmopf-result-policy-matrix-v4",
        "benchmark_root" => root,
        "output_root" => output_root,
        "child_timeout_seconds" => timeout_seconds,
        "policy_result_suffix_overrides" => result_suffixes,
        "policies" => entries,
        "environment_fingerprints" => sort!(unique(filter(value -> value isa AbstractString,
            [get(entry, "child_environment_fingerprint", nothing) for entry in entries]))),
        "cases" => get(ENV, "NLPDIAGNOSTICS_BMOPF_CASES", ""),
        "case_selection" => get(ENV, "NLPDIAGNOSTICS_BMOPF_CASE_SELECTION", ""),
        "environment" => Dict(
            "julia_version" => string(VERSION),
            "julia_executable" => string(Base.julia_cmd()),
            "project" => project,
            "local_package_load_path" => normpath(joinpath(@__DIR__, "..")),
        ),
    )
end

function _run_policy(script, project, root, output_root, name, spec, timeout_seconds, result_suffixes)
    output_dir = joinpath(output_root, name)
    mkpath(output_dir)
    child_env = copy(ENV)
    repository_root = normpath(joinpath(@__DIR__, ".."))
    existing_load_path = get(child_env, "JULIA_LOAD_PATH", "@")
    child_env["JULIA_LOAD_PATH"] = string(repository_root, ':', existing_load_path)
    child_env["NLPDIAGNOSTICS_BMOPF_BENCHMARK_ROOT"] = root
    child_env["NLPDIAGNOSTICS_BMOPF_OUTPUT_DIR"] = output_dir
    child_env["NLPDIAGNOSTICS_BMOPF_POINT_POLICY"] = "saved_result"
    child_env["NLPDIAGNOSTICS_BMOPF_RESULT_UNITS"] = spec.result_units
    child_env["NLPDIAGNOSTICS_BMOPF_RESULT_FIELD_UNITS"] = spec.field_units
    if haskey(result_suffixes, name)
        child_env["NLPDIAGNOSTICS_BMOPF_RESULT_SUFFIX"] = result_suffixes[name]
    elseif haskey(ENV, "NLPDIAGNOSTICS_BMOPF_RESULT_SUFFIX")
        child_env["NLPDIAGNOSTICS_BMOPF_RESULT_SUFFIX"] = ENV["NLPDIAGNOSTICS_BMOPF_RESULT_SUFFIX"]
    else
        delete!(child_env, "NLPDIAGNOSTICS_BMOPF_RESULT_SUFFIX")
    end
    process_log = joinpath(output_dir, "policy.process.log")
    julia = Base.julia_cmd()
    command = `$julia --startup-file=no --project=$project $script`
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
        try Base.kill(process, Base.SIGTERM) catch; Base.kill(process) end
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
    result_code = if timed_out
        nothing
    else
        try process.exitcode catch; nothing end
    end
    child_index_path = joinpath(output_dir, "index.json")
    child_index = if isfile(child_index_path)
        try
            value = JSON.parsefile(child_index_path)
            value isa AbstractDict ? value : Dict{String,Any}()
        catch
            Dict{String,Any}()
        end
    else
        Dict{String,Any}()
    end
    child_cases = get(child_index, "cases", Any[])
    child_cases isa AbstractVector || (child_cases = Any[])
    child_statuses = Dict{String,Int}()
    for case in child_cases
        case isa AbstractDict || continue
        status = String(get(case, "status", "unknown"))
        child_statuses[status] = get(child_statuses, status, 0) + 1
    end
    return Dict{String,Any}(
        "policy" => name,
        "result_units" => spec.result_units,
        "result_field_units" => spec.field_units,
        "result_suffix" => get(result_suffixes, name,
            get(ENV, "NLPDIAGNOSTICS_BMOPF_RESULT_SUFFIX", "_result_$(spec.result_units).json")),
        "output_directory" => output_dir,
        "process_log" => basename(process_log),
        "process_timeout" => timed_out,
        "process_exit_code" => result_code,
        "process_wait_error" => wait_error,
        "status" => timed_out ? "process_timeout" :
            (!isnothing(wait_error) || result_code != 0 ? "process_exit" : "ok"),
        "child_index_available" => isfile(child_index_path) && !isempty(child_index),
        "child_runner_version" => get(child_index, "runner_version", nothing),
        "child_environment_fingerprint" => get(child_index, "environment_fingerprint", nothing),
        "child_case_count" => length(child_cases),
        "child_status_counts" => child_statuses,
        "child_result_units" => get(child_index, "result_units", nothing),
        "child_result_field_units" => get(child_index, "result_field_units", nothing),
    )
end

function main()
    root = get(ENV, "NLPDIAGNOSTICS_BMOPF_BENCHMARK_ROOT", "")
    isempty(root) && error("Set NLPDIAGNOSTICS_BMOPF_BENCHMARK_ROOT first")
    root = abspath(root)
    isdir(root) || error("benchmark root does not exist: $root")
    output_root = abspath(get(ENV, "NLPDIAGNOSTICS_BMOPF_POLICY_MATRIX_OUTPUT_DIR",
                               joinpath(pwd(), "bmopf-result-policy-matrix-results")))
    mkpath(output_root)
    project = get(ENV, "NLPDIAGNOSTICS_BENCHMARK_PROJECT", "")
    project = isempty(project) ? Base.active_project() : abspath(project)
    script = abspath(joinpath(@__DIR__, "bmopf_draft_corpus.jl"))
    timeout_seconds = _timeout_seconds()
    result_suffixes = _result_suffixes()
    entries = Dict{String,Any}[]
    index_path = joinpath(output_root, "matrix_index.json")
    for name in _selected_policies()
        entry = _run_policy(script, project, root, output_root, name, _POLICIES[name], timeout_seconds, result_suffixes)
        push!(entries, entry)
        write_json(index_path, _manifest(root, output_root, project,
            timeout_seconds, result_suffixes, entries))
        println("$name: $(entry["status"]) timeout=$(entry["process_timeout"])")
    end
    write_json(index_path, _manifest(root, output_root, project,
        timeout_seconds, result_suffixes, entries))
    println("wrote BMOPF result-policy matrix manifest to $index_path")
end

main()
