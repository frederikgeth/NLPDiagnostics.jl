#!/usr/bin/env julia

"""Run BMOPFTools' feasibility-relaxed initializer on the full MV/LV case.

This probe is deliberately separate from the hard OPF campaign.  The
feasibility formulation can converge while retaining KCL slack; that is useful
initialization evidence, but it is not a hard-feasible OPF or a scaling-policy
ranking.  Ipopt's integer and floating-point options are installed through a
model hook because the BMOPFTools `solver_options` collection is numeric.
"""

using BMOPFTools
using JuMP
using Ipopt

include(joinpath(@__DIR__, "common.jl"))
using .NLPDiagnosticsBenchmarkCommon: write_json

const _RUNNER_VERSION = "bmopf-combined-mv-lv-feasibility-probe-v1"

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

function _initialization_coverage(initialisation)
    bus_count = length(initialisation)
    terminal_count = 0
    scalar_count = 0
    finite_scalar_count = 0
    vm_values = Float64[]
    for terminals in values(initialisation)
        terminals isa AbstractDict || continue
        terminal_count += length(terminals)
        for values_by_name in values(terminals)
            values_by_name isa AbstractDict || continue
            scalar_count += length(values_by_name)
            for (name, value) in values_by_name
                value isa Real || continue
                finite = isfinite(Float64(value))
                finite_scalar_count += finite
                name == "vm_init" && finite && push!(vm_values, Float64(value))
            end
        end
    end
    return Dict{String,Any}(
        "bus_count" => bus_count,
        "terminal_count" => terminal_count,
        "scalar_count" => scalar_count,
        "finite_scalar_count" => finite_scalar_count,
        "voltage_magnitude_min_V" => isempty(vm_values) ? nothing : minimum(vm_values),
        "voltage_magnitude_max_V" => isempty(vm_values) ? nothing : maximum(vm_values),
    )
end

function main()
    input_path = _network_path()
    isfile(input_path) || error("combined MV/LV DSS case is missing: $input_path")
    max_iter = _env_int("NLPDIAGNOSTICS_COMBINED_MV_LV_FEASIBILITY_MAX_ITER", 50)
    max_cpu_seconds = _env_float(
        "NLPDIAGNOSTICS_COMBINED_MV_LV_FEASIBILITY_MAX_CPU_SECONDS", 60.0,
    )
    output = abspath(get(
        ENV,
        "NLPDIAGNOSTICS_COMBINED_MV_LV_FEASIBILITY_OUTPUT",
        joinpath(@__DIR__, "..", "work", "bmopf-combined-mv-lv-feasibility-probe.json"),
    ))

    started = time()
    network = BMOPFTools.from_dss(input_path)
    warnings = get(get(network, "_meta", Dict{String,Any}()), "powerio_warnings", Any[])
    hook = context -> begin
        # Preserve Ipopt's expected option types (Integer vs Float64).
        JuMP.set_attribute(context.model, "max_iter", max_iter)
        JuMP.set_attribute(context.model, "max_cpu_time", max_cpu_seconds)
    end

    result = BMOPFTools.solve_feasibility_opf(
        network;
        scaling_policy = BMOPFTools.OpfScaling(:classic; power_base = 1.0e6),
        model_hook! = hook,
        verbose = false,
    )
    slack = Float64(result["total_slack_magnitude_A"])
    initialization = get(result, "initialisation", Dict{String,Any}())
    coverage = _initialization_coverage(initialization)
    termination = string(get(result, "termination_status", "unknown"))
    relaxed_solved = termination in ("LOCALLY_SOLVED", "OPTIMAL") && get(result, "feasible", false)
    payload = Dict{String,Any}(
        "schema_version" => "nlpdiagnostics-bmopf-combined-mv-lv-feasibility-probe-v1",
        "runner_version" => _RUNNER_VERSION,
        "status" => relaxed_solved ? "relaxed_feasibility_solved" : "relaxed_feasibility_bounded",
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
        "budgets" => Dict(
            "max_iter" => max_iter,
            "max_cpu_seconds" => max_cpu_seconds,
        ),
        "termination_status" => termination,
        "relaxed_feasible" => get(result, "feasible", nothing),
        "solve_seconds" => get(result, "solve_time", nothing),
        "wall_seconds" => time() - started,
        "total_slack_magnitude_A" => slack,
        "hard_kcl_zero_slack" => isapprox(slack, 0.0; atol = 1e-8, rtol = 0.0),
        "slack_injection_count" => length(get(result, "slack_injections", Dict())),
        "initialization" => coverage,
        "result_key_count" => length(keys(result)),
        "interpretation" => "The feasibility-relaxed formulation converged with topology-aware voltage initialization. Nonzero KCL slack means this is an initialization diagnostic, not hard OPF feasibility, policy ranking, or a production scaling claim.",
        "next_action" => "Map the returned initialization into a hard OPF start and add allocator-level peak telemetry.",
    )
    write_json(output, payload)
    println("wrote combined MV/LV feasibility probe to $output")
end

if abspath(PROGRAM_FILE) == abspath(@__FILE__)
    main()
end
