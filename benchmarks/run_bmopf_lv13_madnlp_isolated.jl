#!/usr/bin/env julia

"""Guarded launcher for the approved LV13 MadNLP isolated run.

The default invocation is a dry run.  Set
`NLPDIAGNOSTICS_LV13_MADNLP_EXECUTE=true` only in an explicitly approved
process; the launcher rechecks free memory and enforces the declared timeout.
Memory remains an external-envelope responsibility and is never inferred from
this process-level check.
"""

include(joinpath(@__DIR__, "common.jl"))
using .NLPDiagnosticsBenchmarkCommon

const ROOT = repo_root()
const OUTPUT = abspath(get(
    ENV,
    "NLPDIAGNOSTICS_LV13_MADNLP_LAUNCH_OUTPUT",
    joinpath(ROOT, "docs", "bmopf_lv13_madnlp_launch_summary.json"),
))

plan = read_summary("docs/bmopf_lv13_madnlp_isolated_run_plan.json")
environment = read_summary("docs/bmopf_lv13_madnlp_isolated_environment_summary.json")
resources = read_summary("docs/bmopf_lv13_madnlp_resource_envelope_summary.json")
envelope = get(plan, "resource_envelope", Dict{String,Any}())
execution = get(plan, "execution", Dict{String,Any}())
command_environment = get(execution, "environment", Dict{String,Any}())
runner = joinpath(ROOT, String(get(execution, "runner_script", "")))
project = joinpath(ROOT, "work", "benchmark-environment")
requested_timeout = Int(get(envelope, "timeout_seconds", 0))
required_memory_mb = Int(get(envelope, "memory_limit_mb", 0))
execute = lowercase(strip(get(ENV, "NLPDIAGNOSTICS_LV13_MADNLP_EXECUTE", "false"))) in
    ("1", "true", "yes")
wait_seconds = try
    max(0, parse(Int, get(ENV, "NLPDIAGNOSTICS_LV13_MADNLP_WAIT_SECONDS", "0")))
catch
    error("NLPDIAGNOSTICS_LV13_MADNLP_WAIT_SECONDS must be an integer")
end
total_memory_mb = try Int(fld(Sys.total_memory(), 1_048_576)) catch; nothing end

function _free_memory_mb()
    try
        return Int(fld(Sys.free_memory(), 1_048_576))
    catch
        return nothing
    end
end

free_memory_mb = _free_memory_mb()
wait_deadline = time() + wait_seconds
if execute && !(free_memory_mb isa Number && free_memory_mb >= required_memory_mb)
    while wait_seconds > 0 && time() < wait_deadline
        sleep(min(1.0, max(0.0, wait_deadline - time())))
        global free_memory_mb = _free_memory_mb()
        free_memory_mb isa Number && free_memory_mb >= required_memory_mb && break
    end
end
memory_ready = free_memory_mb isa Number && free_memory_mb >= required_memory_mb
command = get(execution, "command", "")
launch_status = !execute ? "approval_required" :
    !memory_ready ? "blocked_current_memory_pressure" :
    !isfile(runner) ? "runner_missing" :
    !isdir(project) ? "benchmark_project_missing" :
    "ready_to_launch"
exit_code = nothing
elapsed_seconds = nothing
if launch_status == "ready_to_launch"
    julia = Base.julia_cmd()
    command = `$julia --compiled-modules=no --startup-file=no --project=$project $runner`
    child_environment = copy(ENV)
    for (key, value) in command_environment
        child_environment[String(key)] = String(value)
    end
    started = time()
    process = run(setenv(command, child_environment), wait=false)
    deadline = started + requested_timeout
    while process_running(process) && time() < deadline
        sleep(1.0)
    end
    elapsed_seconds = time() - started
    if process_running(process)
        kill(process)
        try wait(process) catch; end
        launch_status = "timed_out"
    else
        wait(process)
        exit_code = process.exitcode
        launch_status = exit_code == 0 ? "completed" : "failed"
    end
end

write_json(OUTPUT, Dict{String,Any}(
    "schema_version" => "nlpdiagnostics-bmopf-lv13-madnlp-launch-v1",
    "runner" => "benchmarks/run_bmopf_lv13_madnlp_isolated.jl",
    "status" => launch_status,
    "approval" => Dict(
        "execute_requested" => execute,
        "wait_seconds_requested" => wait_seconds,
        "approval_variable" => "NLPDIAGNOSTICS_LV13_MADNLP_EXECUTE",
    ),
    "preflight" => Dict(
        "environment_status" => get(environment, "status", "missing"),
        "resource_status" => get(resources, "status", "missing"),
        "total_memory_mb" => total_memory_mb,
        "free_memory_mb_at_launch_check" => free_memory_mb,
        "required_memory_mb" => required_memory_mb,
        "memory_ready" => memory_ready,
    ),
    "execution" => Dict(
        "command" => command,
        "runner_script" => get(execution, "runner_script", nothing),
        "timeout_seconds" => requested_timeout,
        "elapsed_seconds" => elapsed_seconds,
        "exit_code" => exit_code,
        "result_output" => get(execution, "output", nothing),
    ),
    "qualification" => Dict(
        "claim" => launch_status == "completed" ?
            "the approved isolated LV13 MadNLP process completed and produced a candidate result artifact" :
            "the guarded LV13 MadNLP launcher recorded an explicit preflight or process outcome",
        "does_not_establish" => [
            "memory reservation or solver-result qualification",
            "physical endpoint or cross-policy acceptance before the result validator passes",
        ],
        "next_action" => launch_status in ("approval_required", "blocked_current_memory_pressure") ?
            "reduce memory pressure and rerun with explicit approval when the declared envelope is available" :
            "run the isolated-result validator against the emitted result artifact",
    ),
))
println("wrote LV13 MadNLP launch summary to $OUTPUT")
