#!/usr/bin/env julia

"""Run a matched-start solver campaign on a bounded MV+LV source snapshot.

The authoritative BMOPFTools combined case is assembled from its MV21 feeder
and one LV feeder by flattening the source component files into a temporary DSS
entry point. This keeps the source components and warning ledger visible while
avoiding the 56k-variable full-case solver run. The campaign compares classic,
SI, and explicit two-level MV/LV bases descriptively; it does not rank policies.

Environment controls:

  * `NLPDIAGNOSTICS_COMBINED_MV_LV_SNAPSHOT_FEEDER` (default `LV1_14bus`)
  * `NLPDIAGNOSTICS_COMBINED_MV_LV_SNAPSHOT_REPEATS` (default `2`, minimum `2`)
  * `NLPDIAGNOSTICS_COMBINED_MV_LV_SNAPSHOT_MAX_ITER` (default `25`)
  * `NLPDIAGNOSTICS_COMBINED_MV_LV_SNAPSHOT_MAX_VARIABLES` (default `5000`)
  * `NLPDIAGNOSTICS_COMBINED_MV_LV_SNAPSHOT_SOLVER` (default `ipopt`; `madnlp` supported when installed)
  * `NLPDIAGNOSTICS_COMBINED_MV_LV_SNAPSHOT_OUTPUT` (default under `work/`)
"""

using NLPDiagnostics
using BMOPFTools
using JuMP
using Ipopt
using SHA
import MathOptInterface as MOI

const _MADNLP_AVAILABLE = try
    @eval import MadNLP
    true
catch
    false
end

include(joinpath(@__DIR__, "bmopf_magnitude_scaling_campaign.jl"))

const _SNAPSHOT_RUNNER_VERSION = "bmopf-combined-mv-lv-snapshot-campaign-v1"

function _snapshot_env_int(name, default; minimum = 0)
    value = try parse(Int, get(ENV, name, string(default)))
    catch; error("$name must be an integer") end
    value >= minimum || error("$name must be at least $minimum")
    return value
end

function _snapshot_json_safe(value)
    value isa AbstractFloat && !isfinite(value) && return nothing
    value isa AbstractDict && return Dict(string(key) => _snapshot_json_safe(item) for (key, item) in value)
    value isa NamedTuple && return Dict(string(key) => _snapshot_json_safe(getfield(value, key)) for key in keys(value))
    value isa Tuple && return [_snapshot_json_safe(item) for item in value]
    value isa AbstractArray && return [_snapshot_json_safe(item) for item in value]
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

function _data_root()
    configured = strip(get(ENV, "NLPDIAGNOSTICS_BMOPF_DATA_ROOT", ""))
    return isempty(configured) ? joinpath(pkgdir(BMOPFTools), "test", "data") : abspath(configured)
end

function _feeder_name()
    feeder = strip(get(ENV, "NLPDIAGNOSTICS_COMBINED_MV_LV_SNAPSHOT_FEEDER", "LV1_14bus"))
    occursin(r"^LV[0-9]+_[0-9]+bus$", feeder) ||
        error("feeder must match LV<number>_<number>bus")
    isdir(joinpath(_data_root(), "LV", feeder)) || error("unknown LV feeder: $feeder")
    return feeder
end

function _source_files(data_root, feeder)
    mv = joinpath(data_root, "MV", "MV21_328bus")
    lv = joinpath(data_root, "LV", feeder)
    names = ["Linecodes.dss", "lines.dss", "Loads.dss", "Transformers.dss",
             "Switches.dss", "Groundings.dss"]
    files = vcat([joinpath(mv, name) for name in names], [joinpath(lv, name) for name in names])
    all(isfile, files) || error("snapshot source components are incomplete for $feeder")
    return files
end

function _solver_config()
    name = lowercase(strip(get(ENV, "NLPDIAGNOSTICS_COMBINED_MV_LV_SNAPSHOT_SOLVER", "ipopt")))
    name in ("ipopt", "madnlp") || error("snapshot solver must be ipopt or madnlp")
    name == "madnlp" && !_MADNLP_AVAILABLE && error("MadNLP is unavailable in the active benchmark environment")
    return name == "ipopt" ? (Ipopt.Optimizer, :ipopt) : (MadNLP.Optimizer, :madnlp)
end

function _is_control_line(line)
    value = lowercase(strip(line))
    isempty(value) || startswith(value, "!") || startswith(value, "//") ||
        startswith(value, "clear") || startswith(value, "new circuit") ||
        startswith(value, "set ") || startswith(value, "redirect") ||
        startswith(value, "batchedit") || startswith(value, "solve") ||
        startswith(value, "export")
end

function _flatten_snapshot(data_root, feeder, output)
    files = _source_files(data_root, feeder)
    mkpath(dirname(output))
    open(output, "w") do io
        println(io, "clear")
        println(io, "new circuit.nlpdiagnostics_mv_lv_$feeder angle=-30.0 basekv=11.0 phases=3 bus1=B1726 model=ideal")
        println(io, "set defaultbasefrequency=50.0")
        println(io, "set basefrequency=50.0")
        for path in files
            println(io, "! source: ", path)
            for line in eachline(path)
                _is_control_line(line) && continue
                println(io, line)
            end
        end
    end
    return files
end

function _policy_factories(network)
    anchor = _build_context(network, BMOPFTools.OpfScaling(:classic; power_base = 1.0e6);
        add_objective = true)
    bases = BMOPFTools.opf_bases(anchor)
    voltage_bases = Dict(String(bus) => Float64(value) for (bus, value) in bases.v_base)
    power_bases = Dict(bus => (value > 1_000.0 ? 1.0e6 : 1.0e5)
                       for (bus, value) in voltage_bases)
    return [
        ("classic_1mva", () -> BMOPFTools.OpfScaling(:classic; power_base = 1.0e6)),
        ("si_units", () -> BMOPFTools.OpfScaling(:si)),
        ("combined_mv_lv_local", () -> BMOPFTools.OpfScaling(
            name = :combined_mv_lv_local,
            voltage_bases = copy(voltage_bases),
            power_bases = copy(power_bases),
        )),
    ], anchor
end

function main()
    data_root = _data_root()
    feeder = _feeder_name()
    repeats = _snapshot_env_int("NLPDIAGNOSTICS_COMBINED_MV_LV_SNAPSHOT_REPEATS", 2; minimum = 2)
    max_iter = _snapshot_env_int("NLPDIAGNOSTICS_COMBINED_MV_LV_SNAPSHOT_MAX_ITER", 25; minimum = 1)
    max_variables = _snapshot_env_int("NLPDIAGNOSTICS_COMBINED_MV_LV_SNAPSHOT_MAX_VARIABLES", 5000; minimum = 1)
    solver_name = lowercase(strip(get(ENV, "NLPDIAGNOSTICS_COMBINED_MV_LV_SNAPSHOT_SOLVER", "ipopt")))
    optimizer, solver = _solver_config()
    output = abspath(get(
        ENV,
        "NLPDIAGNOSTICS_COMBINED_MV_LV_SNAPSHOT_OUTPUT",
        joinpath(@__DIR__, "..", "work", "bmopf-combined-mv-lv-snapshot-$feeder.json"),
    ))
    snapshot_path = replace(output, ".json" => ".dss")
    source_files = _flatten_snapshot(data_root, feeder, snapshot_path)
    network = BMOPFTools.from_dss(snapshot_path)
    policies, anchor_context = _policy_factories(network)
    backend = JuMP.backend(BMOPFTools.opf_model(anchor_context))
    variable_count = length(MOI.get(backend, MOI.ListOfVariableIndices()))
    source_warnings = get(get(network, "_meta", Dict{String,Any}()), "powerio_warnings", Any[])
    records = Dict{String,Any}[]
    comparisons = Dict{String,Any}[]
    campaign = nothing
    if variable_count <= max_variables
        anchor_evaluation = _schema_evaluation(anchor_context, "combined-mv-lv-$feeder-anchor")
        environment = _benchmark_environment()
        fingerprint = _benchmark_environment_fingerprint(environment)
        private_runs = Dict{Tuple{String,Int},Any}()
        for (policy_name, factory) in policies
            for replicate in 1:repeats
                public_record, private_record = _run_policy(
                    network, policy_name, factory(), replicate,
                    anchor_context, anchor_evaluation, fingerprint;
                    max_iter,
                    solver_tolerance = 1.0e-8,
                    add_objective = true,
                    optimizer,
                    solver,
                    max_dense_entries = 0,
                )
                push!(records, public_record)
                private_runs[(policy_name, replicate)] = private_record
            end
        end
        reference = first(policies)[1]
        push!(comparisons, _matched_comparison(
            reference, 1, private_runs[(reference, 1)],
            reference, 2, private_runs[(reference, 2)];
            baseline_repeat = true,
            max_dense_entries = 0,
        ))
        for (policy_name, _) in policies[2:end]
            for replicate in 1:repeats
                push!(comparisons, _matched_comparison(
                    reference, replicate, private_runs[(reference, replicate)],
                    policy_name, replicate, private_runs[(policy_name, replicate)];
                    max_dense_entries = 0,
                ))
            end
        end
        campaign = NLPDiagnostics.scaling_solver_experiment_campaign_data(
            records, comparisons;
            reference_policy = reference,
            minimum_repeats = repeats,
            metadata = Dict(
                "runner_version" => _SNAPSHOT_RUNNER_VERSION,
                "case" => "combined-mv-lv-$feeder",
                "solver" => uppercasefirst(solver_name),
                "max_iter" => max_iter,
            ),
        )
    end
    payload = Dict{String,Any}(
        "schema_version" => "nlpdiagnostics-bmopf-combined-mv-lv-snapshot-campaign-v1",
        "runner_version" => _SNAPSHOT_RUNNER_VERSION,
        "status" => variable_count <= max_variables ? "matched_$(solver_name)_campaign_complete" : "snapshot_size_guarded",
        "snapshot" => Dict(
            "feeder" => feeder,
            "generated_dss" => snapshot_path,
            "source_files" => [Dict("path" => path, "sha256" => bytes2hex(sha256(read(path)))) for path in source_files],
            "network_shape" => Dict(
                "bus_count" => length(get(network, "bus", Dict())),
                "line_count" => length(get(network, "line", Dict())),
                "load_count" => length(get(network, "load", Dict())),
                "transformer_count" => sum(length(value) for value in values(get(network, "transformer", Dict())) if value isa AbstractDict),
                "switch_count" => length(get(network, "switch", Dict())),
                "model_variable_count" => variable_count,
            ),
            "source_warning_count" => length(source_warnings),
            "source_warning_codes" => _warning_codes(source_warnings),
        ),
        "budgets" => Dict("repeats" => repeats, "max_iter" => max_iter, "max_variables" => max_variables),
        "records" => records,
        "comparisons" => comparisons,
        "campaign" => campaign,
        "endpoint_gates" => campaign === nothing ? Dict{String,Any}(
            "status" => "unavailable",
            "reason" => "snapshot_size_guarded",
        ) : Dict{String,Any}(
            "all_physical_endpoints_accepted" => get(campaign["gates"], "all_physical_endpoints_accepted", false),
            "all_comparisons_qualified" => get(campaign["gates"], "all_comparisons_qualified", false),
            "comparison_coverage_complete" => get(campaign["gates"], "comparison_coverage_complete", false),
            "terminations_stable_within_policy" => get(campaign["gates"], "terminations_stable_within_policy", false),
        ),
        "qualification" => Dict(
            "interpretation" => "matched-start $(uppercasefirst(solver_name)) evidence is descriptive; no policy score or universal rule",
            "madnlp_campaign_pending" => solver_name == "ipopt",
            "source_provenance_preserved" => true,
        ),
    )
    mkpath(dirname(output))
    write_json(output, _snapshot_json_safe(payload))
    println("wrote combined MV/LV snapshot campaign to $output")
end

if abspath(PROGRAM_FILE) == abspath(@__FILE__)
    main()
end
