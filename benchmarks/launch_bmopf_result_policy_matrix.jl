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

function _run_policy(script, project, root, output_root, name, spec, timeout_seconds, result_suffixes)
    output_dir = joinpath(output_root, name)
    mkpath(output_dir)
    child_env = copy(ENV)
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
    end
    wait(process)
    result_code = timed_out ? nothing : process.exitcode
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
        "status" => timed_out ? "process_timeout" : result_code == 0 ? "ok" : "process_exit",
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
    for name in _selected_policies()
        entry = _run_policy(script, project, root, output_root, name, _POLICIES[name], timeout_seconds, result_suffixes)
        push!(entries, entry)
        println("$name: $(entry["status"]) timeout=$(entry["process_timeout"])")
    end
    manifest = Dict{String,Any}(
        "runner_version" => "bmopf-result-policy-matrix-v2",
        "benchmark_root" => root,
        "output_root" => output_root,
        "child_timeout_seconds" => timeout_seconds,
        "policy_result_suffix_overrides" => result_suffixes,
        "policies" => entries,
        "cases" => get(ENV, "NLPDIAGNOSTICS_BMOPF_CASES", ""),
        "case_selection" => get(ENV, "NLPDIAGNOSTICS_BMOPF_CASE_SELECTION", ""),
    )
    write(joinpath(output_root, "matrix_index.json"), JSON.json(manifest))
    println("wrote BMOPF result-policy matrix manifest to $(joinpath(output_root, "matrix_index.json"))")
end

main()
