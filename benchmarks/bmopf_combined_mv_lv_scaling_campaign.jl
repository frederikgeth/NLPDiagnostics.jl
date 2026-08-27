#!/usr/bin/env julia

"""Run a bounded solver campaign on BMOPFTools' combined MV/LV source case.

The full case is intentionally size guarded.  Each policy is built through
BMOPFTools, receives the same native start lifecycle, and is solved only when
the configured variable and time budgets permit it.  A size-guarded record is
evidence about campaign readiness, not a failed solve and not a policy score.

Environment controls:

  * `NLPDIAGNOSTICS_COMBINED_MV_LV_DSS` (default BMOPFTools `test/data/Master.dss`)
  * `NLPDIAGNOSTICS_COMBINED_MV_LV_MAX_VARIABLES` (default `5000`)
  * `NLPDIAGNOSTICS_COMBINED_MV_LV_MAX_ITER` (default `25`)
  * `NLPDIAGNOSTICS_COMBINED_MV_LV_MAX_CPU_SECONDS` (default `60`)
  * `NLPDIAGNOSTICS_COMBINED_MV_LV_SCALING_CAMPAIGN_OUTPUT` (default under `work/`)
"""

using NLPDiagnostics
using BMOPFTools
using JuMP
using Ipopt
import MathOptInterface as MOI

include(joinpath(@__DIR__, "benchmark_environment.jl"))
include(joinpath(@__DIR__, "common.jl"))
using .NLPDiagnosticsBenchmarkCommon: write_json

const _RUNNER_VERSION = "bmopf-combined-mv-lv-scaling-campaign-v1"

function _env_int(name, default; minimum = 0)
    value = try
        parse(Int, get(ENV, name, string(default)))
    catch
        error("$name must be an integer")
    end
    value >= minimum || error("$name must be at least $minimum")
    return value
end

function _env_float(name, default; minimum = 0.0)
    value = try
        parse(Float64, get(ENV, name, string(default)))
    catch
        error("$name must be a number")
    end
    isfinite(value) && value >= minimum || error("$name must be finite and at least $minimum")
    return value
end

function _json_safe(value)
    value isa AbstractFloat && !isfinite(value) && return nothing
    value isa AbstractDict && return Dict(string(key) => _json_safe(item) for (key, item) in value)
    value isa NamedTuple && return Dict(string(key) => _json_safe(getfield(value, key)) for key in keys(value))
    value isa Tuple && return [_json_safe(item) for item in value]
    value isa AbstractArray && return [_json_safe(item) for item in value]
    return value
end

function _warning_codes(warnings)
    codes = Set{String}()
    for warning in warnings
        if warning isa AbstractDict
            push!(codes, string(get(warning, "code", "unknown")))
        elseif warning isa AbstractString
            match_result = match(r"^([A-Z0-9_.-]+):", String(warning))
            push!(codes, isnothing(match_result) ? "unknown" : String(match_result.captures[1]))
        end
    end
    return sort!(collect(codes))
end

function _input_path()
    override = strip(get(ENV, "NLPDIAGNOSTICS_COMBINED_MV_LV_DSS", ""))
    return isempty(override) ?
        joinpath(pkgdir(BMOPFTools), "test", "data", "Master.dss") : abspath(override)
end

function _policy_data(policy, bases)
    bases === nothing && return Dict{String,Any}(
        "policy" => BMOPFTools.opf_scaling_policy_data(policy),
        "voltage_base_values" => Any[],
        "power_base_values" => Any[],
        "coordinate_bases_available" => false,
    )
    return Dict{String,Any}(
        "policy" => BMOPFTools.opf_scaling_policy_data(policy),
        "voltage_base_values" => sort!(unique(round.(collect(values(bases.v_base)); digits = 4))),
        "power_base_values" => sort!(unique(collect(values(bases.s_base_bus)))),
        "coordinate_bases_available" => true,
    )
end

function _contract_data(context)
    try
        contract = BMOPFTools.opf_transformer_scaling_contract_data(context)
        return Dict{String,Any}(
            "available" => get(contract, "available", nothing),
            "proposal_admissible" => get(contract, "proposal_admissible", nothing),
            "applied_to_model" => get(contract, "applied_to_model", nothing),
            "interface_count" => length(get(contract, "interfaces", Any[])),
        )
    catch error
        return Dict{String,Any}("status" => "unavailable", "error" => sprint(showerror, error))
    end
end

function _bound_value(model, variable, lower_bound::Bool)
    try
        reference = JuMP.VariableRef(model, variable)
        available = lower_bound ? JuMP.has_lower_bound(reference) : JuMP.has_upper_bound(reference)
        available || return nothing
        value = lower_bound ? JuMP.lower_bound(reference) : JuMP.upper_bound(reference)
        return isfinite(Float64(value)) ? Float64(value) : nothing
    catch
        return nothing
    end
end

function _bound_aware_missing_value(model, variable)
    lower = _bound_value(model, variable, true)
    upper = _bound_value(model, variable, false)
    if (isnothing(lower) || lower <= 0.0) && (isnothing(upper) || upper >= 0.0)
        return 0.0
    elseif !isnothing(lower) && !isnothing(upper)
        return (lower + upper) / 2.0
    elseif !isnothing(lower)
        return lower > 0.0 ? lower : 0.0
    elseif !isnothing(upper)
        return upper < 0.0 ? upper : 0.0
    end
    return 0.0
end

function _apply_start!(model, point)
    backend = JuMP.backend(model)
    applied = 0
    bound_aware = 0
    filled_indices = split(
        String(get(point.provenance.metadata, "filled_variable_indices", "")), ',',
    )
    missing = Set{Int}(parse.(Int, filter(!isempty, filled_indices)))
    for (variable, value) in zip(point.variables, point.values)
        applied_value = if variable.value in missing
            bound_aware += 1
            _bound_aware_missing_value(model, variable)
        else
            Float64(value)
        end
        MOI.set(backend, MOI.VariablePrimalStart(), variable, applied_value)
        applied += 1
    end
    return (; applied, bound_aware)
end

function _solve_policy(network, policy, label; max_variables, max_iter, max_cpu_seconds)
    started = time()
    context = BMOPFTools.build_opf_model(
        deepcopy(network);
        optimizer = Ipopt.Optimizer,
        scaling_policy = policy,
        add_objective = true,
    )
    BMOPFTools.enforce_kcl!(context)
    model = BMOPFTools.opf_model(context)
    backend = JuMP.backend(model)
    variable_count = length(MOI.get(backend, MOI.ListOfVariableIndices()))
    bases = BMOPFTools.opf_bases(context)
    record = Dict{String,Any}(
        "label" => label,
        "status" => "not_started",
        "model_variable_count" => variable_count,
        "policy" => _policy_data(policy, bases),
        "transformer_contract" => _contract_data(context),
        "max_variables" => max_variables,
        "max_iter" => max_iter,
        "max_cpu_seconds" => max_cpu_seconds,
        "build_seconds" => time() - started,
    )
    if variable_count > max_variables
        record["status"] = "skipped_solver_size_guard"
        record["skip_reason"] = "model_variable_count_exceeds_budget"
        record["wall_seconds"] = time() - started
        return (; record, bases)
    end

    start_point = try
        NLPDiagnostics.bmopf_start_completion_point(context; missing_value = 0.0, label = "$label-start")
    catch error
        record["start_point_status"] = "unavailable"
        record["start_point_error"] = sprint(showerror, error)
        nothing
    end
    if start_point !== nothing
        record["start_point_status"] = "available"
        try
            applied = _apply_start!(model, start_point)
            record["start_values_applied_count"] = applied.applied
            record["start_values_bound_aware_count"] = applied.bound_aware
            record["start_completion_policy"] = "native_starts_plus_bound_aware_missing_values"
            record["start_point_applied"] = true
        catch error
            record["start_point_applied"] = false
            record["start_point_apply_error"] = sprint(showerror, error)
        end
    end
    JuMP.set_optimizer_attribute(model, "max_iter", max_iter)
    JuMP.set_optimizer_attribute(model, "max_cpu_time", max_cpu_seconds)
    solve_started = time()
    try
        JuMP.optimize!(model)
        record["status"] = "solved_or_bounded"
        record["termination_status"] = string(JuMP.termination_status(model))
        record["primal_status"] = string(JuMP.primal_status(model))
        record["dual_status"] = string(JuMP.dual_status(model))
        record["result_count"] = JuMP.result_count(model)
        record["solve_seconds"] = time() - solve_started
        record["objective_value"] = try JuMP.objective_value(model) catch; nothing end
        result_point = try NLPDiagnostics.solver_result_point(model) catch; nothing end
        if result_point isa NLPDiagnostics.EvaluationPoint
            record["result_point_status"] = "available"
            record["result_point_fingerprint"] = NLPDiagnostics.evaluation_point_fingerprint(result_point)
        else
            record["result_point_status"] = "unavailable"
        end
    catch error
        record["status"] = "solver_error"
        record["error"] = sprint(showerror, error, catch_backtrace())
        record["solve_seconds"] = time() - solve_started
    end
    record["wall_seconds"] = time() - started
    return (; record, bases)
end

function main()
    input_path = _input_path()
    isfile(input_path) || error("combined MV/LV DSS case is missing: $input_path")
    max_variables = _env_int("NLPDIAGNOSTICS_COMBINED_MV_LV_MAX_VARIABLES", 5000)
    max_iter = _env_int("NLPDIAGNOSTICS_COMBINED_MV_LV_MAX_ITER", 25; minimum = 1)
    max_cpu_seconds = _env_float("NLPDIAGNOSTICS_COMBINED_MV_LV_MAX_CPU_SECONDS", 60.0; minimum = 0.1)
    network = BMOPFTools.from_dss(input_path)
    warnings = get(get(network, "_meta", Dict{String,Any}()), "powerio_warnings", Any[])

    classic_policy = BMOPFTools.OpfScaling(:classic; power_base = 1.0e6)
    classic_result = _solve_policy(network, classic_policy, "classic";
        max_variables, max_iter, max_cpu_seconds)
    voltage_bases = Dict(
        String(bus) => Float64(value)
        for (bus, value) in classic_result.bases.v_base
    )
    power_bases = Dict(bus => (value > 1_000.0 ? 1.0e6 : 1.0e5)
                       for (bus, value) in voltage_bases)
    local_policy = BMOPFTools.OpfScaling(
        name = :combined_mv_lv_local,
        voltage_bases = voltage_bases,
        power_bases = power_bases,
    )
    records = [
        classic_result.record,
        _solve_policy(network, local_policy, "combined_mv_lv_local";
            max_variables, max_iter, max_cpu_seconds).record,
        _solve_policy(network, BMOPFTools.OpfScaling(:si), "si";
            max_variables, max_iter, max_cpu_seconds).record,
    ]
    output = abspath(get(
        ENV,
        "NLPDIAGNOSTICS_COMBINED_MV_LV_SCALING_CAMPAIGN_OUTPUT",
        joinpath(@__DIR__, "..", "work", "bmopf-combined-mv-lv-scaling-campaign.json"),
    ))
    mkpath(dirname(output))
    payload = Dict{String,Any}(
        "schema_version" => "nlpdiagnostics-bmopf-combined-mv-lv-scaling-campaign-v1",
        "runner_version" => _RUNNER_VERSION,
        "status" => all(get(record, "status", "") == "solved_or_bounded" for record in records) ?
            "bounded_solver_campaign_complete" : "bounded_solver_campaign_partial",
        "input" => Dict(
            "path" => input_path,
            "source_warning_count" => length(warnings),
            "source_warning_codes" => _warning_codes(warnings),
        ),
        "network_shape" => Dict(
            "bus_count" => length(get(network, "bus", Dict())),
            "line_count" => length(get(network, "line", Dict())),
            "load_count" => length(get(network, "load", Dict())),
        ),
        "budgets" => Dict(
            "max_variables" => max_variables,
            "max_iter" => max_iter,
            "max_cpu_seconds" => max_cpu_seconds,
        ),
        "records" => records,
        "qualification" => Dict(
            "interpretation" => "bounded descriptive solver evidence; no policy score or universal scaling rule",
            "next_gate" => "repeat selected combined MV/LV snapshots with matched starts and MadNLP when available",
            "solver_work_claim_supported" => any(get(record, "status", "") == "solved_or_bounded" for record in records),
        ),
    )
    write_json(output, _json_safe(payload))
    println("wrote combined MV/LV scaling campaign to $output")
end

if abspath(PROGRAM_FILE) == abspath(@__FILE__)
    main()
end
