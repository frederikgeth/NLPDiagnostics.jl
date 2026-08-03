#!/usr/bin/env julia

"""
Size-guarded BMOPF solver-trace benchmark.

This runner is deliberately separate from `bmopf_draft_corpus.jl`: the corpus
runner is safe for large structural campaigns, while this script opts into a
real solve and callback capture only for selected small cases. It records the
solver trace, the final-result profile, BMOPFTools context evidence, and the
benchmark environment in one JSON record per case.

Example:

NLPDIAGNOSTICS_BMOPF_BENCHMARK_ROOT=/path/to/BMOPFDraftData/benchmarks \
NLPDIAGNOSTICS_BMOPF_CASES=ENWLsnapshots/30bus_LN/30bus_LN_t01_0800.bmopf.json \
julia --project=work/benchmark-environment benchmarks/bmopf_solver_trace.jl
"""

using NLPDiagnostics
using BMOPFTools
using JuMP
using Ipopt
using JSON
using SHA
import MathOptInterface as MOI

const _MADNLP_AVAILABLE = try
    @eval import MadNLP
    true
catch
    false
end

include(joinpath(@__DIR__, "benchmark_environment.jl"))

const _RUNNER_VERSION = "bmopf-solver-trace-v2"
const _DEFAULT_CASES = [
    "ENWLsnapshots/30bus_LN/30bus_LN_t01_0800.bmopf.json",
]

function _env_flag(name; default = false)
    raw = lowercase(strip(get(ENV, name, default ? "true" : "false")))
    raw in ("1", "true", "yes", "on") && return true
    raw in ("0", "false", "no", "off") && return false
    error("$name must be a boolean (true/false), got '$raw'")
end

function _env_int(name, default)
    value = try
        parse(Int, get(ENV, name, string(default)))
    catch
        error("$name must be an integer")
    end
    value >= 0 || error("$name must be nonnegative")
    return value
end

function _option_value(raw::AbstractString)
    value = strip(raw)
    lowercase(value) in ("true", "false") && return lowercase(value) == "true"
    try
        return parse(Int, value)
    catch
    end
    try
        return parse(Float64, value)
    catch
        return value
    end
end

function _solver_options()
    raw = strip(get(ENV, "NLPDIAGNOSTICS_BMOPF_SOLVER_OPTIONS", ""))
    isempty(raw) && return Dict{String,Any}()
    options = Dict{String,Any}()
    for item in split(raw, ',')
        pair = split(item, '='; limit = 2)
        length(pair) == 2 || error(
            "NLPDIAGNOSTICS_BMOPF_SOLVER_OPTIONS entries must be key=value, got '$item'",
        )
        key = strip(pair[1])
        isempty(key) && error("solver option keys must not be empty")
        options[key] = _option_value(pair[2])
    end
    return options
end

function _sha256_file(path)
    return bytes2hex(SHA.sha256(read(path)))
end

function _solver_name()
    name = lowercase(strip(get(ENV, "NLPDIAGNOSTICS_BMOPF_SOLVER", "ipopt")))
    name in ("ipopt", "madnlp") || error(
        "NLPDIAGNOSTICS_BMOPF_SOLVER must be ipopt or madnlp, got '$name'",
    )
    name == "madnlp" && !_MADNLP_AVAILABLE && throw(ArgumentError(
        "MadNLP is required for NLPDIAGNOSTICS_BMOPF_SOLVER=madnlp in the selected environment",
    ))
    return name
end

function _solver_optimizer(name)
    return name == "ipopt" ? Ipopt.Optimizer : MadNLP.Optimizer
end

function _selected_cases(root)
    selected = filter(!isempty, strip.(split(
        get(ENV, "NLPDIAGNOSTICS_BMOPF_CASES", ""), ',';
    )))
    cases = isempty(selected) ? _DEFAULT_CASES : selected
    for relative in cases
        isabspath(relative) && error("case selections must be relative to the benchmark root")
        endswith(relative, ".bmopf.json") || error("case is not a .bmopf.json snapshot: $relative")
        isfile(joinpath(root, relative)) || error("selected snapshot is missing: $(joinpath(root, relative))")
    end
    return cases
end

function _integrity_preflight(network)
    findings = BMOPFTools.Finding[]
    summary = BMOPFTools.integrity_check(network, findings)
    return Dict{String,Any}(
        "error_count" => count(f -> f.severity == BMOPFTools.ERROR, findings),
        "warning_count" => count(f -> f.severity == BMOPFTools.WARNING, findings),
        "finding_count" => length(findings),
        "blocking" => any(f -> f.severity == BMOPFTools.ERROR, findings),
        "summary" => summary,
        "findings" => [Dict(
            "severity" => string(f.severity), "code" => f.code,
            "section" => string(f.section), "component_type" => string(f.component_type),
            "component_id" => f.component_id, "message" => f.message,
            "detail" => f.detail,
        ) for f in findings],
    )
end

function _solve_with_trace(model, solver_name; capture_points::Bool)
    if solver_name == "ipopt"
        return NLPDiagnostics.ipopt_profile_with_iteration_trace!(model;
            capture_points,
        )
    end
    return NLPDiagnostics.madnlp_profile_with_iteration_trace!(model)
end

function _apply_solver_options(model, options)
    for (key, value) in options
        JuMP.set_optimizer_attribute(model, key, value)
    end
    return model
end

function _case_record(root, relative, solver_name, output_dir, max_variables,
                      capture_points, dense_entry_limit, environment_fingerprint,
                      solver_options, per_unit)
    path = joinpath(root, relative)
    name = replace(replace(relative, '/' => "__"), ".bmopf.json" => "")
    result_path = joinpath(output_dir, "$name.json")
    sweep_label = get(ENV, "NLPDIAGNOSTICS_BMOPF_SWEEP_LABEL", "")
    preflight = nothing
    try
        network = BMOPFTools.parse_bmopf(path)
        preflight = _integrity_preflight(network)
        preflight["blocking"] && error("BMOPFTools integrity preflight has blocking errors")
        build_timing = @timed BMOPFTools.build_opf_model(network;
            optimizer = _solver_optimizer(solver_name), add_objective = true,
            per_unit = per_unit,
        )
        context = build_timing.value
        kcl_timing = @timed BMOPFTools.enforce_kcl!(context)
        model = BMOPFTools.opf_model(context)
        _apply_solver_options(model, solver_options)
        backend = JuMP.backend(model)
        variable_count = length(MOI.get(backend, MOI.ListOfVariableIndices()))
        if variable_count > max_variables
            payload = Dict{String,Any}(
                "status" => "skipped_solver_size_guard",
                "snapshot" => relative, "snapshot_path" => abspath(path),
                "solver" => solver_name, "model_variable_count" => variable_count,
                "max_solver_variables" => max_variables,
                "environment_fingerprint" => environment_fingerprint,
                "solver_options" => solver_options,
                "per_unit" => per_unit,
                "sweep_label" => sweep_label,
                "integrity_preflight" => preflight,
            )
            write(result_path, JSON.json(payload))
            return Dict{String,Any}("name" => name, "snapshot" => relative,
                "status" => payload["status"], "result_file" => basename(result_path),
                "model_variable_count" => variable_count)
        end
        run = _solve_with_trace(model, solver_name; capture_points)
        trace_data = NLPDiagnostics.iteration_trace_data(run.trace)
        solver_data = NLPDiagnostics.profile_result_data(run)
        bmopf_data = if isnothing(run.result.case)
            nothing
        else
            bmopf = NLPDiagnostics.bmopf_profile_case(context, run.result.case;
                include_initialization = false,
                rank_max_dense_entries = dense_entry_limit,
                jacobian_rank_tolerance_sweep_max_dense_entries = dense_entry_limit,
            )
            NLPDiagnostics.profile_result_data(bmopf)
        end
        payload = Dict{String,Any}(
            "status" => "ok", "snapshot" => relative,
            "snapshot_path" => abspath(path), "solver" => solver_name,
            "environment_fingerprint" => environment_fingerprint,
            "solver_options" => solver_options,
            "per_unit" => per_unit,
            "sweep_label" => sweep_label,
            "model_coordinate_units" => per_unit ? "per-unit" : "SI/model-native",
            "solver_objective_convention" => solver_name == "madnlp" ?
                "unscaled model objective via MadNLP.unpack_obj" :
                "Ipopt callback objective in model units",
            "objective_comparison_reference" => "recomputed MOI model objective",
            "bmopf_extracted_result_convention" => "BMOPFTools public result units (typically SI)",
            "capture_points" => capture_points,
            "model_variable_count" => variable_count,
            "build_seconds" => build_timing.time,
            "build_allocations" => build_timing.bytes,
            "kcl_seconds" => kcl_timing.time,
            "kcl_allocations" => kcl_timing.bytes,
            "integrity_preflight" => preflight,
            "iteration_trace" => trace_data,
            "solver_profile" => solver_data,
            "bmopf_profile" => bmopf_data,
            "solver_result_constraint_row_count" => isnothing(run.result.profile) ?
                nothing : length(run.result.profile.evaluation.constraint_sources),
        )
        write(result_path, JSON.json(payload))
        return Dict{String,Any}(
            "name" => name, "snapshot" => relative, "status" => "ok",
            "result_file" => basename(result_path), "solver" => solver_name,
            "model_variable_count" => variable_count,
            "iteration_count" => length(run.trace.records),
            "build_seconds" => build_timing.time, "kcl_seconds" => kcl_timing.time,
        )
    catch error
        message = sprint(showerror, error, catch_backtrace())
        payload = Dict{String,Any}(
            "status" => "error", "snapshot" => relative,
            "snapshot_path" => abspath(path), "solver" => solver_name,
            "environment_fingerprint" => environment_fingerprint,
            "solver_options" => solver_options,
            "per_unit" => per_unit,
            "sweep_label" => sweep_label,
            "error" => message, "integrity_preflight" => preflight,
        )
        write(result_path, JSON.json(payload))
        return Dict{String,Any}(
            "name" => name, "snapshot" => relative, "status" => "error",
            "result_file" => basename(result_path), "error" => message,
        )
    end
end

function main()
    root = get(ENV, "NLPDIAGNOSTICS_BMOPF_BENCHMARK_ROOT", "")
    isempty(root) && error("Set NLPDIAGNOSTICS_BMOPF_BENCHMARK_ROOT to BMOPFDraftData/benchmarks")
    isdir(root) || error("benchmark root does not exist: $root")
    output_dir = get(ENV, "NLPDIAGNOSTICS_BMOPF_OUTPUT_DIR", joinpath(pwd(), "bmopf-solver-trace-results"))
    mkpath(output_dir)
    solver_name = _solver_name()
    max_variables = _env_int("NLPDIAGNOSTICS_BMOPF_SOLVE_MAX_VARIABLES", 2_000)
    dense_entry_limit = _env_int("NLPDIAGNOSTICS_BMOPF_RANK_MAX_DENSE_ENTRIES", 250_000)
    capture_points = _env_flag("NLPDIAGNOSTICS_BMOPF_CAPTURE_POINTS")
    per_unit = _env_flag("NLPDIAGNOSTICS_BMOPF_PER_UNIT"; default = true)
    solver_options = _solver_options()
    environment = _benchmark_environment()
    environment_fingerprint = _benchmark_environment_fingerprint(environment)
    sweep_label = get(ENV, "NLPDIAGNOSTICS_BMOPF_SWEEP_LABEL", "")
    cases = _selected_cases(root)
    index = Dict{String,Any}[]
    for relative in cases
        entry = _case_record(root, relative, solver_name, output_dir,
            max_variables, capture_points, dense_entry_limit,
            environment_fingerprint, solver_options, per_unit)
        entry["environment_fingerprint"] = environment_fingerprint
        entry["solver_options"] = solver_options
        entry["per_unit"] = per_unit
        entry["sweep_label"] = sweep_label
        push!(index, entry)
        println("$(entry["name"]): $(entry["status"]) solver=$solver_name " *
            "iterations=$(get(entry, "iteration_count", "n/a"))")
    end
    write(joinpath(output_dir, "index.json"), JSON.json(Dict(
        "runner_version" => _RUNNER_VERSION,
        "benchmark_root" => abspath(root), "solver" => solver_name,
        "capture_points" => capture_points,
        "solver_options" => solver_options,
        "per_unit" => per_unit,
        "max_solver_variables" => max_variables,
        "rank_max_dense_entries" => dense_entry_limit,
        "environment" => environment,
        "environment_fingerprint" => environment_fingerprint,
        "sweep_label" => sweep_label,
        "cases" => index,
    )))
    println("wrote solver-trace evidence to $output_dir")
end

main()
