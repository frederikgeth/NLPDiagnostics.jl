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

const _RUNNER_VERSION = "bmopf-combined-mv-lv-feasibility-start-transfer-v1"

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
    for (bus, terminals) in initialization
        terminals isa AbstractDict || continue
        for (terminal, values_by_name) in terminals
            values_by_name isa AbstractDict || continue
            key = (String(bus), String(terminal))
            haskey(vars[:vr], key) && haskey(vars[:vi], key) || (skipped += 1; continue)
            haskey(values_by_name, "vr_init") && haskey(values_by_name, "vi_init") ||
                (skipped += 1; continue)
            base = get(voltage_bases, String(bus), 1.0)
            isfinite(base) && base > 0.0 || (skipped += 1; continue)
            vr = Float64(values_by_name["vr_init"]) / base
            vi = Float64(values_by_name["vi_init"]) / base
            isfinite(vr) && isfinite(vi) || (skipped += 1; continue)
            JuMP.set_start_value(vars[:vr][key], vr)
            JuMP.set_start_value(vars[:vi][key], vi)
            applied += 1
        end
    end
    return (; applied, skipped)
end

function _hard_run(network, initialization, label; transfer, max_iter, max_cpu_seconds)
    started = time()
    context = BMOPFTools.build_opf_model(
        deepcopy(network);
        optimizer = Ipopt.Optimizer,
        scaling_policy = BMOPFTools.OpfScaling(:classic; power_base = 1.0e6),
        add_objective = true,
    )
    BMOPFTools.enforce_kcl!(context)
    model = BMOPFTools.opf_model(context)
    transfer_counts = transfer ? _apply_voltage_initialization!(context, initialization) :
        (; applied = 0, skipped = 0)
    JuMP.set_optimizer_attribute(model, "max_iter", max_iter)
    JuMP.set_optimizer_attribute(model, "max_cpu_time", max_cpu_seconds)
    solve_started = time()
    timed = @timed JuMP.optimize!(model)
    return Dict{String,Any}(
        "label" => label,
        "transfer_applied" => transfer,
        "transferred_voltage_start_count" => transfer_counts.applied,
        "transferred_voltage_start_skipped_count" => transfer_counts.skipped,
        "termination_status" => string(JuMP.termination_status(model)),
        "primal_status" => string(JuMP.primal_status(model)),
        "dual_status" => string(JuMP.dual_status(model)),
        "result_count" => JuMP.result_count(model),
        "solve_seconds" => time() - solve_started,
        "solve_allocated_bytes" => timed.bytes,
        "solve_gc_seconds" => timed.gctime,
        "objective_value" => try JuMP.objective_value(model) catch; nothing end,
        "wall_seconds" => time() - started,
    )
end

function main()
    input_path = _network_path()
    isfile(input_path) || error("combined MV/LV DSS case is missing: $input_path")
    max_iter = _env_int("NLPDIAGNOSTICS_COMBINED_MV_LV_TRANSFER_MAX_ITER", 50)
    max_cpu_seconds = _env_float(
        "NLPDIAGNOSTICS_COMBINED_MV_LV_TRANSFER_MAX_CPU_SECONDS", 60.0,
    )
    output = abspath(get(
        ENV,
        "NLPDIAGNOSTICS_COMBINED_MV_LV_TRANSFER_OUTPUT",
        joinpath(@__DIR__, "..", "work", "bmopf-combined-mv-lv-feasibility-start-transfer.json"),
    ))

    started = time()
    network = BMOPFTools.from_dss(input_path)
    warnings = get(get(network, "_meta", Dict{String,Any}()), "powerio_warnings", Any[])
    relaxed = _relaxed_initialization(network, max_iter, max_cpu_seconds)
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
        "relaxed_initialization" => Dict(
            "termination_status" => get(relaxed, "termination_status", nothing),
            "relaxed_feasible" => get(relaxed, "feasible", nothing),
            "total_slack_magnitude_A" => get(relaxed, "total_slack_magnitude_A", nothing),
            "initialization_bus_count" => length(initialization),
        ),
        "records" => [native, transferred],
        "memory_observation" => "@timed solve allocation bytes and GC time are process-local allocation telemetry, not allocator-level peak memory.",
        "interpretation" => "The feasibility-relaxed voltage state is transferred into the hard OPF voltage starts and compared with the native hard-OPF start under identical budgets. Termination remains bounded evidence; nonzero relaxed KCL slack and iteration-limited hard statuses do not establish hard feasibility or a production scaling policy.",
        "next_action" => "Add fresh-child allocator peak telemetry and expose a stable BMOPFTools voltage-start transfer API if this initialization is retained.",
        "wall_seconds" => time() - started,
    )
    write_json(output, payload)
    println("wrote combined MV/LV feasibility-start transfer to $output")
    return payload
end

if abspath(PROGRAM_FILE) == abspath(@__FILE__)
    main()
end
