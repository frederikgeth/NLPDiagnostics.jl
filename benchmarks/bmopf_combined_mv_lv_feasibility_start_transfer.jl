#!/usr/bin/env julia

"""Transfer a feasibility-relaxed voltage state into a hard full-case OPF.

The relaxed solve is used only as a start-value experiment.  The staged
BMOPFTools context currently exposes its live voltage ledger as an extension
implementation detail, so this benchmark records the transfer as experimental
evidence rather than treating it as a stable public API contract.
"""

using BMOPFTools
using JuMP
using Ipopt

include(joinpath(@__DIR__, "common.jl"))
using .NLPDiagnosticsBenchmarkCommon: write_json

const _RUNNER_VERSION = "bmopf-combined-mv-lv-feasibility-start-transfer-v2"

struct _VoltageStartTransferValidationError
    code::Symbol
    bus::String
    terminal::String
end

struct _VoltageStartTransferReport
    applied::Int
    skipped::Int
    validation_errors::Vector{_VoltageStartTransferValidationError}
end

function _validation_error_payload(report::_VoltageStartTransferReport)
    return [Dict{String,Any}(
        "code" => String(error.code),
        "bus" => error.bus,
        "terminal" => error.terminal,
    ) for error in report.validation_errors]
end

# Darwin exposes current allocator counters for the default malloc zone.  The
# process-level child runner records the outer envelope; these helpers add
# stage attribution without treating current bytes as a peak measurement.
struct _StageMallocStatistics
    blocks_in_use::Csize_t
    size_in_use::Csize_t
    max_size_in_use::Csize_t
    size_allocated::Csize_t
end

function _stage_allocator_snapshot()
    Sys.isapple() || return nothing
    try
        zone = ccall(:malloc_default_zone, Ptr{Cvoid}, ())
        stats = Ref(_StageMallocStatistics(0, 0, 0, 0))
        ccall(:malloc_zone_statistics, Cvoid,
            (Ptr{Cvoid}, Ref{_StageMallocStatistics}), zone, stats)
        value = stats[]
        return Dict{String,Any}(
            "available" => true,
            "blocks_in_use" => Int(value.blocks_in_use),
            "size_in_use_bytes" => Int(value.size_in_use),
            "size_allocated_bytes" => Int(value.size_allocated),
            "max_size_in_use_bytes" => Int(value.max_size_in_use),
            "peak_field_available" => value.max_size_in_use > 0,
        )
    catch error
        return Dict{String,Any}(
            "available" => false,
            "error_type" => string(typeof(error)),
            "error" => sprint(showerror, error),
        )
    end
end

function _stage_allocator_delta(before, after)
    available = before isa AbstractDict && after isa AbstractDict &&
        get(before, "available", false) && get(after, "available", false)
    return Dict{String,Any}(
        "available" => available,
        "before" => before,
        "after" => after,
        "size_in_use_delta_bytes" => available ?
            get(after, "size_in_use_bytes", 0) - get(before, "size_in_use_bytes", 0) : nothing,
        "size_allocated_delta_bytes" => available ?
            get(after, "size_allocated_bytes", 0) - get(before, "size_allocated_bytes", 0) : nothing,
        "peak_available" => available &&
            get(after, "peak_field_available", false),
    )
end

function _env_int(name, default; minimum = 1)
    value = try parse(Int, get(ENV, name, string(default)))
    catch
        error("$name must be an integer")
    end
    value >= minimum || error("$name must be at least $minimum")
    return value
end

function _env_float(name, default; minimum = 0.1)
    value = try parse(Float64, get(ENV, name, string(default)))
    catch
        error("$name must be a number")
    end
    isfinite(value) && value >= minimum || error("$name must be finite and at least $minimum")
    return value
end

function _network_path()
    override = strip(get(ENV, "NLPDIAGNOSTICS_COMBINED_MV_LV_DSS", ""))
    return isempty(override) ?
        joinpath(pkgdir(BMOPFTools), "test", "data", "Master.dss") : abspath(override)
end

function _scale_loads!(network, multiplier)
    loads = get(network, "load", Dict{String,Any}())
    for load in values(loads)
        load isa AbstractDict || continue
        for field in ("p_nom", "q_nom")
            values = get(load, field, nothing)
            values isa AbstractVector || continue
            load[field] = [multiplier * Float64(value) for value in values]
        end
    end
    return network
end

function _warning_codes(warnings)
    codes = Set{String}()
    for warning in warnings
        if warning isa AbstractDict
            push!(codes, string(get(warning, "code", "unknown")))
        elseif warning isa AbstractString
            matched = match(r"^([A-Z0-9_.-]+):", String(warning))
            push!(codes, isnothing(matched) ? "unknown" : String(matched.captures[1]))
        end
    end
    return sort!(collect(codes))
end

function _ipopt_hook(max_iter, max_cpu_seconds)
    return context -> begin
        JuMP.set_attribute(context.model, "max_iter", max_iter)
        JuMP.set_attribute(context.model, "max_cpu_time", max_cpu_seconds)
    end
end

function _relaxed_initialization(network, max_iter, max_cpu_seconds)
    result = BMOPFTools.solve_feasibility_opf(
        network;
        scaling_policy = BMOPFTools.OpfScaling(:classic; power_base = 1.0e6),
        model_hook! = _ipopt_hook(max_iter, max_cpu_seconds),
        verbose = false,
    )
    return result
end

function _apply_voltage_initialization!(context, initialization)
    # `vars` is intentionally isolated here: this is the one implementation
    # detail that prevents the transfer from being advertised as stable API.
    vars = getfield(context, :vars)
    bases = BMOPFTools.opf_bases(context)
    voltage_bases = bases === nothing ? Dict{String,Float64}() : bases.v_base
    applied = 0
    skipped = 0
    validation_errors = _VoltageStartTransferValidationError[]
    function skip!(code, bus, terminal)
        skipped += 1
        push!(validation_errors, _VoltageStartTransferValidationError(
            code, String(bus), String(terminal),
        ))
    end
    for (bus, terminals) in initialization
        bus_name = String(bus)
        if !(terminals isa AbstractDict)
            skip!(:invalid_bus_payload, bus_name, "")
            continue
        end
        for (terminal, values_by_name) in terminals
            terminal_name = String(terminal)
            if !(values_by_name isa AbstractDict)
                skip!(:invalid_terminal_payload, bus_name, terminal_name)
                continue
            end
            key = (bus_name, terminal_name)
            if !(haskey(vars[:vr], key) && haskey(vars[:vi], key))
                skip!(:unknown_bus_terminal, bus_name, terminal_name)
                continue
            end
            if !(haskey(values_by_name, "vr_init") && haskey(values_by_name, "vi_init"))
                skip!(:missing_rectangular_start, bus_name, terminal_name)
                continue
            end
            base = get(voltage_bases, bus_name, 1.0)
            if !(isfinite(base) && base > 0.0)
                skip!(:invalid_voltage_base, bus_name, terminal_name)
                continue
            end
            vr, vi = try
                Float64(values_by_name["vr_init"]) / base,
                Float64(values_by_name["vi_init"]) / base
            catch
                skip!(:non_numeric_phasor, bus_name, terminal_name)
                continue
            end
            if !(isfinite(vr) && isfinite(vi))
                skip!(:nonfinite_phasor, bus_name, terminal_name)
                continue
            end
            JuMP.set_start_value(vars[:vr][key], vr)
            JuMP.set_start_value(vars[:vi][key], vi)
            applied += 1
        end
    end
    return _VoltageStartTransferReport(applied, skipped, validation_errors)
end

function _hard_run(network, initialization, label; transfer, max_iter, max_cpu_seconds)
    started = time()
    build_before = _stage_allocator_snapshot()
    context = BMOPFTools.build_opf_model(
        deepcopy(network);
        optimizer = Ipopt.Optimizer,
        scaling_policy = BMOPFTools.OpfScaling(:classic; power_base = 1.0e6),
        add_objective = true,
    )
    build_after = _stage_allocator_snapshot()
    BMOPFTools.enforce_kcl!(context)
    model = BMOPFTools.opf_model(context)
    start_before = _stage_allocator_snapshot()
    transfer_report = transfer ? _apply_voltage_initialization!(context, initialization) :
        _VoltageStartTransferReport(0, 0, _VoltageStartTransferValidationError[])
    start_after = _stage_allocator_snapshot()
    JuMP.set_optimizer_attribute(model, "max_iter", max_iter)
    JuMP.set_optimizer_attribute(model, "max_cpu_time", max_cpu_seconds)
    solve_started = time()
    solve_before = _stage_allocator_snapshot()
    timed = @timed JuMP.optimize!(model)
    solve_after = _stage_allocator_snapshot()
    return Dict{String,Any}(
        "label" => label,
        "transfer_applied" => transfer,
        "transferred_voltage_start_count" => transfer_report.applied,
        "transferred_voltage_start_skipped_count" => transfer_report.skipped,
        "transferred_voltage_start_validation_error_count" => length(transfer_report.validation_errors),
        "transferred_voltage_start_validation_errors" => _validation_error_payload(transfer_report),
        "termination_status" => string(JuMP.termination_status(model)),
        "primal_status" => string(JuMP.primal_status(model)),
        "dual_status" => string(JuMP.dual_status(model)),
        "result_count" => JuMP.result_count(model),
        "solve_seconds" => time() - solve_started,
        "solve_allocated_bytes" => timed.bytes,
        "solve_gc_seconds" => timed.gctime,
        "objective_value" => try JuMP.objective_value(model) catch; nothing end,
        "wall_seconds" => time() - started,
        "allocator_stage_telemetry" => Dict(
            "model_build" => _stage_allocator_delta(build_before, build_after),
            "start_application" => _stage_allocator_delta(start_before, start_after),
            "solve" => _stage_allocator_delta(solve_before, solve_after),
        ),
    )
end

function main()
    input_path = _network_path()
    isfile(input_path) || error("combined MV/LV DSS case is missing: $input_path")
    max_iter = _env_int("NLPDIAGNOSTICS_COMBINED_MV_LV_TRANSFER_MAX_ITER", 50)
    max_cpu_seconds = _env_float(
        "NLPDIAGNOSTICS_COMBINED_MV_LV_TRANSFER_MAX_CPU_SECONDS", 60.0,
    )
    load_multiplier = _env_float(
        "NLPDIAGNOSTICS_COMBINED_MV_LV_LOAD_MULTIPLIER", 1.0; minimum = 0.01,
    )
    output = abspath(get(
        ENV,
        "NLPDIAGNOSTICS_COMBINED_MV_LV_TRANSFER_OUTPUT",
        joinpath(@__DIR__, "..", "work", "bmopf-combined-mv-lv-feasibility-start-transfer.json"),
    ))

    started = time()
    network = BMOPFTools.from_dss(input_path)
    _scale_loads!(network, load_multiplier)
    warnings = get(get(network, "_meta", Dict{String,Any}()), "powerio_warnings", Any[])
    relaxed_before = _stage_allocator_snapshot()
    relaxed = _relaxed_initialization(network, max_iter, max_cpu_seconds)
    relaxed_after = _stage_allocator_snapshot()
    initialization = get(relaxed, "initialisation", Dict{String,Any}())
    native = _hard_run(network, initialization, "native";
        transfer = false, max_iter, max_cpu_seconds)
    transferred = _hard_run(network, initialization, "feasibility_voltage_transfer";
        transfer = true, max_iter, max_cpu_seconds)
    payload = Dict{String,Any}(
        "schema_version" => "nlpdiagnostics-bmopf-combined-mv-lv-feasibility-start-transfer-v1",
        "runner_version" => _RUNNER_VERSION,
        "status" => "bounded_hard_opf_start_transfer",
        "input" => Dict(
            "path" => input_path,
            "source_warning_count" => length(warnings),
            "source_warning_codes" => _warning_codes(warnings),
        ),
        "network_shape" => Dict(
            "bus_count" => length(get(network, "bus", Dict())),
            "line_count" => length(get(network, "line", Dict())),
            "transformer_count" => length(get(network, "transformer", Dict())),
            "load_count" => length(get(network, "load", Dict())),
        ),
        "budgets" => Dict("max_iter" => max_iter, "max_cpu_seconds" => max_cpu_seconds),
        "load_multiplier" => load_multiplier,
        "relaxed_initialization" => Dict(
            "termination_status" => get(relaxed, "termination_status", nothing),
            "relaxed_feasible" => get(relaxed, "feasible", nothing),
            "total_slack_magnitude_A" => get(relaxed, "total_slack_magnitude_A", nothing),
            "initialization_bus_count" => length(initialization),
            "allocator_stage_telemetry" => _stage_allocator_delta(relaxed_before, relaxed_after),
        ),
        "records" => [native, transferred],
        "memory_observation" => "@timed solve allocation bytes plus Darwin current allocator deltas are process-local telemetry; stage deltas are attribution evidence and not allocator-level peak memory.",
        "interpretation" => "The feasibility-relaxed voltage state is transferred into the hard OPF voltage starts and compared with the native hard-OPF start under identical budgets. Termination remains bounded evidence; nonzero relaxed KCL slack and iteration-limited hard statuses do not establish hard feasibility or a production scaling policy.",
        "next_action" => "Carry the reviewed voltage-start API contract upstream; hard-OPF convergence and peak-capable allocator telemetry remain open.",
        "wall_seconds" => time() - started,
    )
    write_json(output, payload)
    println("wrote combined MV/LV feasibility-start transfer to $output")
    return payload
end

if abspath(PROGRAM_FILE) == abspath(@__FILE__)
    main()
end
