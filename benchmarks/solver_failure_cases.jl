#!/usr/bin/env julia

"""
Run small, intentionally problematic JuMP models through Ipopt and/or MadNLP.

The harness records the intended signal separately from the observed solver
termination. A solver is allowed to classify a case differently; that result
is evidence for follow-up, not a failed benchmark assertion.
"""

using NLPDiagnostics
using JuMP
using Ipopt
using JSON

import MathOptInterface as MOI

const _MADNLP_AVAILABLE = try
    @eval import MadNLP
    true
catch
    false
end

include(joinpath(@__DIR__, "benchmark_environment.jl"))

const _CASES = [
    (
        name = "iteration-limit",
        expected_signal = "resource_limit",
        description = "A deliberately tiny iteration budget on a smooth scalar NLP.",
        options = ("max_iter" => 1,),
    ),
    (
        name = "infeasible-bounds",
        expected_signal = "infeasibility_or_restoration",
        description = "Conflicting scalar bounds should expose infeasibility handling.",
        options = ("max_iter" => 50,),
    ),
    (
        name = "invalid-log-domain",
        expected_signal = "invalid_number_or_domain",
        description = "The initial point violates log(x)'s mathematical domain.",
        options = ("max_iter" => 50,),
    ),
    (
        name = "restoration-candidate",
        expected_signal = "restoration_or_infeasibility",
        description = "Contradictory nonlinear equalities force feasibility restoration.",
        options = ("max_iter" => 50,),
    ),
]

function _env_list(name, defaults)
    selected = filter(!isempty, strip.(split(get(ENV, name, ""), ',')))
    isempty(selected) && return defaults
    return String[selected...]
end

function _solver_list()
    selected = lowercase.(_env_list("NLPDIAGNOSTICS_FAILURE_SOLVERS", ["ipopt"]))
    all(solver -> solver in ("ipopt", "madnlp"), selected) ||
        error("NLPDIAGNOSTICS_FAILURE_SOLVERS must contain only ipopt or madnlp")
    "madnlp" in selected && !_MADNLP_AVAILABLE &&
        error("MadNLP was requested but is unavailable in the active environment")
    return unique(selected)
end

function _solver_optimizer(solver)
    return solver == "ipopt" ? Ipopt.Optimizer : MadNLP.Optimizer
end

function _set_options(model, options)
    for (key, value) in options
        JuMP.set_optimizer_attribute(model, key, value)
    end
    return model
end

function _env_truthy(name, default = true)
    value = lowercase(strip(get(ENV, name, default ? "true" : "false")))
    value in ("1", "true", "yes", "on") && return true
    value in ("0", "false", "no", "off") && return false
    error("$name must be a boolean value (true/false), got '$value'")
end

function _solver_log_path(output_dir, solver, case)
    return joinpath(output_dir, "$(solver)__$(case.name).log")
end

"""Configure a solver-owned log file when the backend exposes one.

The file is deliberately configured through solver options rather than by
redirecting Julia's global stdout/stderr. This keeps concurrent benchmark
processes isolated and preserves the solver's own severity filtering.
"""
function _configure_solver_log!(model, solver, path)
    _env_truthy("NLPDIAGNOSTICS_FAILURE_CAPTURE_LOGS", true) || return nothing
    mkpath(dirname(path))
    try
        JuMP.set_optimizer_attribute(model, "output_file", path)
        # Ipopt uses an integer file verbosity; MadNLP accepts its LogLevels
        # enum through the same MOI attribute interface. INFO is intentionally
        # sufficient for termination/restoration markers without trace noise.
        if solver == "ipopt"
            JuMP.set_optimizer_attribute(model, "file_print_level", 5)
        else
            # MadNLP's option parser expects the public LogLevels enum rather
            # than the display string "INFO".
            JuMP.set_optimizer_attribute(model, "file_print_level", MadNLP.INFO)
        end
        return nothing
    catch error
        return sprint(showerror, error)
    end
end

function _build_case(name, solver)
    model = JuMP.Model(_solver_optimizer(solver))
    JuMP.set_silent(model)
    if name == "iteration-limit"
        @variable(model, x)
        @constraint(model, x >= -100.0)
        @NLobjective(model, Min, (x - 10.0)^2)
        JuMP.set_start_value(x, -50.0)
    elseif name == "infeasible-bounds"
        @variable(model, x)
        @constraint(model, x >= 1.0)
        @constraint(model, x <= 0.0)
        @NLobjective(model, Min, x^2)
        JuMP.set_start_value(x, 0.5)
    elseif name == "invalid-log-domain"
        @variable(model, x)
        @NLobjective(model, Min, log(x) + (x - 1.0)^2)
        JuMP.set_start_value(x, -1.0)
    elseif name == "restoration-candidate"
        # Keep at least as many variables as equality rows so the solver can
        # enter restoration instead of rejecting the model as TOO_FEW_DOF.
        # The two concentric circles are still mathematically contradictory.
        @variable(model, x)
        @variable(model, y)
        @constraint(model, x^2 + y^2 == 1.0)
        @constraint(model, x^2 + y^2 == 2.0)
        @NLobjective(model, Min, (x - 1.0)^2 + y^2)
        JuMP.set_start_value(x, 1.0)
        JuMP.set_start_value(y, 0.0)
    else
        error("unknown failure case '$name'")
    end
    return model
end

function _truncate(text, limit = 100_000)
    length(text) <= limit && return text
    return text[1:limit] * "\n...[truncated]..."
end

function _termination_category(termination, exception_present)
    exception_present && return "exception"
    termination == "slow_progress" && return "slow_progress"
    termination == "restoration_failed" && return "restoration_failed"
    termination in ("numerical_failure", "invalid_number") && return "numerical_failure"
    termination in ("iteration_limit", "time_limit") && return "resource_limit"
    termination in ("infeasible", "locally_infeasible") && return "infeasible"
    termination in ("optimal", "locally_optimal") && return "successful_termination"
    return "unclassified"
end

function _log_evidence(solver, log_text)
    isempty(strip(log_text)) && return nothing
    raw = NLPDiagnostics.analyze_solver_log(solver, log_text)
    iterations = NLPDiagnostics.analyze_solver_iterations(solver, log_text)
    return Dict{String,Any}(
        "text" => _truncate(log_text),
        "raw" => NLPDiagnostics.report_data(raw),
        "iterations" => NLPDiagnostics.report_data(iterations),
    )
end

function _external_log(case, solver)
    root = get(ENV, "NLPDIAGNOSTICS_FAILURE_LOG_DIR", "")
    isempty(root) && return "", nothing
    path = joinpath(root, "$(solver)__$(case.name).log")
    isfile(path) || return "", path
    return read(path, String), path
end

function _run_case(case, solver, output_dir)
    model = nothing
    run = nothing
    caught = nothing
    configured_log_path = _solver_log_path(output_dir, solver, case)
    log_configuration_error = nothing
    try
        model = _build_case(case.name, solver)
        _set_options(model, case.options)
        log_configuration_error = _configure_solver_log!(
            model, solver, configured_log_path,
        )
        try
            run = solver == "ipopt" ?
                NLPDiagnostics.ipopt_profile_with_iteration_trace!(model) :
                NLPDiagnostics.madnlp_profile_with_iteration_trace!(model)
        catch error
            caught = error
        end
    catch error
        caught = error
    end
    # Solver-owned output files are preferred. A caller can override or supply
    # logs independently through NLPDIAGNOSTICS_FAILURE_LOG_DIR; this is useful
    # when the solve itself is run in a subprocess or on another machine.
    log_text, log_path = _external_log(case, solver)
    if isempty(strip(log_text)) && isfile(_solver_log_path(output_dir, solver, case))
        log_path = _solver_log_path(output_dir, solver, case)
        log_text = read(log_path, String)
    end
    postmortem = nothing
    if !isnothing(run)
        postmortem = run.result.postmortem
    elseif !isnothing(model)
        try
            postmortem = NLPDiagnostics.solver_postmortem(model)
        catch
        end
    end
    serialized_result = if !isnothing(run)
        NLPDiagnostics.profile_result_data(run.result)
    else
        nothing
    end
    log_correlation = if !isnothing(postmortem) && !isempty(strip(log_text))
        NLPDiagnostics.report_data(
            NLPDiagnostics.analyze_postmortem_log_consistency(postmortem, log_text),
        )
    else
        nothing
    end
    termination = isnothing(postmortem) ? "unavailable" : string(postmortem.termination)
    category = _termination_category(termination, !isnothing(caught))
    log_source = isempty(strip(log_text)) ? "unavailable" :
                 (log_path == configured_log_path ? "solver_output_file" : "external_file")
    payload = Dict{String,Any}(
        "case" => case.name,
        "description" => case.description,
        "expected_signal" => case.expected_signal,
        "solver" => solver,
        "options" => Dict(string(key) => value for (key, value) in case.options),
        "status" => isnothing(caught) ? "completed" : "exception",
        "observed_termination" => termination,
        "observed_category" => category,
        "postmortem" => serialized_result,
        "trace" => isnothing(run) ? nothing : NLPDiagnostics.iteration_trace_data(run.trace),
        "exception" => isnothing(caught) ? nothing : sprint(showerror, caught, catch_backtrace()),
        "log_evidence" => _log_evidence(solver, log_text),
        "log_correlation" => log_correlation,
        "log_source" => log_source,
        "log_path" => log_path,
        "configured_log_path" => _solver_log_path(output_dir, solver, case),
        "log_configuration_error" => log_configuration_error,
    )
    filename = "$(solver)__$(case.name).json"
    write(joinpath(output_dir, filename), JSON.json(payload))
    return Dict{String,Any}(
        "case" => case.name, "solver" => solver,
        "result_file" => filename, "status" => payload["status"],
        "expected_signal" => case.expected_signal,
        "observed_termination" => termination, "observed_category" => category,
    )
end

function _write_index(output_dir, environment, solvers, index)
    write(joinpath(output_dir, "index.json"), JSON.json(Dict(
        "runner_version" => "solver-failure-cases-v2",
        "environment" => environment,
        "solvers" => solvers,
        "cases" => index,
    )))
    return nothing
end

function _selected_cases()
    selected = _env_list("NLPDIAGNOSTICS_FAILURE_CASES", [case.name for case in _CASES])
    cases = [case for case in _CASES if case.name in selected]
    isempty(cases) && error("NLPDIAGNOSTICS_FAILURE_CASES selected no known cases")
    all(name -> name in (case.name for case in _CASES), selected) ||
        error("unknown failure case selection")
    return cases
end

function main()
    output_dir = abspath(get(ENV, "NLPDIAGNOSTICS_FAILURE_OUTPUT_DIR",
                             joinpath(pwd(), "solver-failure-results")))
    mkpath(output_dir)
    cases = _selected_cases()
    solvers = _solver_list()
    environment = _benchmark_environment()
    index = Dict{String,Any}[]
    for solver in solvers, case in cases
        push!(index, _run_case(case, solver, output_dir))
    end
    _write_index(output_dir, environment, solvers, index)
    println("wrote solver-failure evidence to $output_dir")
end

main()
