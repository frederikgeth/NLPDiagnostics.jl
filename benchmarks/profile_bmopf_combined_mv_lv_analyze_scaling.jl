#!/usr/bin/env julia

"""Profile point-free analyze on guarded BMOPFTools combined MV+LV feeders.

PowerIO warning counts are retained as source provenance rather than treated as
analysis failures.
"""

using NLPDiagnostics
using BMOPFTools
using JuMP
using Ipopt

include(joinpath(@__DIR__, "common.jl"))
using .NLPDiagnosticsBenchmarkCommon

const ROOT = repo_root()
const OUTPUT = abspath(isempty(ARGS) ?
    joinpath(ROOT, "docs", "bmopf_combined_mv_lv_analyze_scaling_summary.json") : ARGS[1])

function selected_feeders()
    raw = strip(get(
        ENV,
        "NLPDIAGNOSTICS_BMOPF_COMBINED_MV_LV_ANALYZE_FEEDERS",
        "LV1_14bus,LV13_58bus,LV3_55bus,LV32_100bus",
    ))
    feeders = unique(filter(!isempty, strip.(split(raw, ','))))
    isempty(feeders) && error("combined MV+LV feeder list must not be empty")
    all(occursin.(r"^LV[0-9]+_[0-9]+bus$", feeders)) ||
        error("combined MV+LV feeders must match LV<number>_<number>bus")
    return feeders
end

function positive_integer(name::AbstractString, default::Int)
    value = try parse(Int, get(ENV, name, string(default)))
    catch; error("$name must be a positive integer") end
    value > 0 || error("$name must be a positive integer")
    return value
end

function data_root()
    configured = strip(get(ENV, "NLPDIAGNOSTICS_BMOPF_DATA_ROOT", ""))
    return isempty(configured) ? joinpath(pkgdir(BMOPFTools), "test", "data") : abspath(configured)
end

function source_files(root::AbstractString, feeder::AbstractString)
    mv = joinpath(root, "MV", "MV21_328bus")
    lv = joinpath(root, "LV", feeder)
    names = ["Linecodes.dss", "lines.dss", "Loads.dss", "Transformers.dss", "Switches.dss", "Groundings.dss"]
    files = vcat([joinpath(mv, name) for name in names], [joinpath(lv, name) for name in names])
    all(isfile, files) || error("combined MV+LV source components are incomplete for $feeder")
    return files
end

function is_control_line(line::AbstractString)
    value = lowercase(strip(line))
    isempty(value) || startswith(value, "!") || startswith(value, "//") ||
        startswith(value, "clear") || startswith(value, "new circuit") ||
        startswith(value, "set ") || startswith(value, "redirect") ||
        startswith(value, "batchedit") || startswith(value, "solve") || startswith(value, "export")
end

function flatten_snapshot(root::AbstractString, feeder::AbstractString, output::AbstractString)
    files = source_files(root, feeder)
    mkpath(dirname(output))
    open(output, "w") do io
        println(io, "clear")
        println(io, "new circuit.nlpdiagnostics_mv_lv_$feeder angle=-30.0 basekv=11.0 phases=3 bus1=B1726 model=ideal")
        println(io, "set defaultbasefrequency=50.0")
        println(io, "set basefrequency=50.0")
        for path in files
            println(io, "! source: ", path)
            for line in eachline(path)
                is_control_line(line) && continue
                println(io, line)
            end
        end
    end
    return files
end

function warning_count(network)
    metadata = get(network, "_meta", Dict{String,Any}())
    warnings = get(metadata, "powerio_warnings", Any[])
    return warnings isa AbstractVector ? length(warnings) : 0
end

function policy_factories(network)
    anchor = BMOPFTools.build_opf_model(
        deepcopy(network);
        optimizer = Ipopt.Optimizer,
        scaling_policy = BMOPFTools.OpfScaling(:classic; power_base = 1.0e6),
        add_objective = true,
    )
    BMOPFTools.enforce_kcl!(anchor)
    bases = BMOPFTools.opf_bases(anchor)
    voltage_bases = Dict(String(bus) => Float64(value) for (bus, value) in bases.v_base)
    power_bases = Dict(bus => (value > 1_000.0 ? 1.0e6 : 1.0e5) for (bus, value) in voltage_bases)
    return [
        ("classic_1mva", () -> BMOPFTools.OpfScaling(:classic; power_base = 1.0e6)),
        ("si_units", () -> BMOPFTools.OpfScaling(:si)),
        ("combined_mv_lv_local", () -> BMOPFTools.OpfScaling(
            name = :combined_mv_lv_local,
            voltage_bases = copy(voltage_bases),
            power_bases = copy(power_bases),
        )),
    ]
end

function policy_data(policy, context)
    bases = BMOPFTools.opf_bases(context)
    bases === nothing && return Dict{String,Any}(
        "policy" => BMOPFTools.opf_scaling_policy_data(policy),
        "coordinate_bases_available" => false,
    )
    return Dict{String,Any}(
        "policy" => BMOPFTools.opf_scaling_policy_data(policy),
        "coordinate_bases_available" => true,
        "voltage_base_count" => length(bases.v_base),
        "voltage_base_values" => sort!(unique(round.(collect(values(bases.v_base)); digits = 4))),
        "power_base_values" => sort!(unique(collect(values(bases.s_base_bus)))),
    )
end

function analyze_record(model, repetitions::Int)
    warmup = @timed NLPDiagnostics.analyze(model)
    runs = Dict{String,Any}[]
    for repetition in 1:repetitions
        GC.gc()
        rss_before = Int(Sys.maxrss())
        timed = @timed NLPDiagnostics.analyze(model)
        rss_after = Int(Sys.maxrss())
        report = timed.value
        counts = NLPDiagnostics.finding_code_counts(report)
        push!(runs, Dict{String,Any}(
            "repetition" => repetition,
            "elapsed_seconds" => timed.time,
            "allocated_bytes" => timed.bytes,
            "process_maxrss_increment_bytes" => max(0, rss_after - rss_before),
            "finding_count" => length(report),
            "finding_code_counts" => Dict(string(code) => count for (code, count) in counts),
        ))
    end
    first_run = first(runs)
    stable = all(
        run["finding_count"] == first_run["finding_count"] &&
        run["finding_code_counts"] == first_run["finding_code_counts"]
        for run in runs
    )
    return Dict{String,Any}(
        "warmup_seconds" => warmup.time,
        "warmup_allocated_bytes" => warmup.bytes,
        "repetitions" => repetitions,
        "elapsed_seconds" => sum(run["elapsed_seconds"] for run in runs) / repetitions,
        "allocated_bytes" => round(Int, sum(run["allocated_bytes"] for run in runs) / repetitions),
        "finding_count" => first_run["finding_count"],
        "finding_code_counts" => first_run["finding_code_counts"],
        "evidence_stable_across_repetitions" => stable,
        "runs" => runs,
    )
end

feeders = selected_feeders()
repetitions = positive_integer("NLPDIAGNOSTICS_BMOPF_COMBINED_MV_LV_ANALYZE_REPETITIONS", 2)
max_variables = positive_integer("NLPDIAGNOSTICS_BMOPF_COMBINED_MV_LV_ANALYZE_MAX_VARIABLES", 5000)
root = data_root()
records = Dict{String,Any}[]
for feeder in feeders
    output_dss = joinpath(ROOT, "work", "bmopf-combined-mv-lv-analyze-$feeder.dss")
    flatten_snapshot(root, feeder, output_dss)
    network = BMOPFTools.from_dss(output_dss)
    source_warnings = warning_count(network)
    for (policy_name, policy_factory) in policy_factories(network)
        started = time()
        try
            context = BMOPFTools.build_opf_model(
                deepcopy(network);
                optimizer = Ipopt.Optimizer,
                scaling_policy = policy_factory(),
                add_objective = true,
            )
            BMOPFTools.enforce_kcl!(context)
            model = BMOPFTools.opf_model(context)
            snapshot = NLPDiagnostics.snapshot(model)
            variable_count = length(snapshot.variables)
            constraint_count = length(snapshot.constraints)
            base = Dict{String,Any}(
                "feeder" => feeder,
                "policy" => policy_name,
                "status" => variable_count <= max_variables ? "measured" : "skipped_size_guard",
                "variable_count" => variable_count,
                "constraint_count" => constraint_count,
                "max_variables" => max_variables,
                "source_warning_count" => source_warnings,
                "policy_data" => policy_data(policy_factory(), context),
                "wall_seconds" => time() - started,
            )
            if variable_count <= max_variables
                merge!(base, analyze_record(model, repetitions))
            else
                base["skip_reason"] = "model_variable_count_exceeds_guard"
            end
            push!(records, base)
        catch error
            push!(records, Dict{String,Any}(
                "feeder" => feeder,
                "policy" => policy_name,
                "status" => "error",
                "error_type" => string(typeof(error)),
                "error" => sprint(showerror, error),
                "wall_seconds" => time() - started,
            ))
        end
    end
end

measured = filter(record -> get(record, "status", "") == "measured", records)
status_entries = git_status_entries()
write_json(OUTPUT, Dict{String,Any}(
    "schema_version" => "nlpdiagnostics-bmopf-combined-mv-lv-analyze-scaling-v1",
    "source" => Dict(
        "runner" => "benchmarks/profile_bmopf_combined_mv_lv_analyze_scaling.jl",
        "feeders" => feeders,
        "repetitions" => repetitions,
        "max_variables" => max_variables,
        "entry_point" => "NLPDiagnostics.analyze(model)",
        "point_supplied" => false,
        "campaign_class" => "non-solving combined MV+LV snapshot profile",
    ),
    "environment" => Dict(
        "julia_version" => string(VERSION),
        "active_project" => Base.active_project(),
        "os" => string(Sys.KERNEL),
        "architecture" => string(Sys.ARCH),
        "git_revision" => git_revision(),
        "git_worktree_dirty" => !isempty(status_entries),
        "bmopftools_version" => string(Base.pkgversion(BMOPFTools)),
    ),
    "record_count" => length(records),
    "measured_count" => length(measured),
    "guarded_count" => count(record -> get(record, "status", "") == "skipped_size_guard", records),
    "stable_measured_count" => count(record -> get(record, "evidence_stable_across_repetitions", false), measured),
    "records" => records,
    "interpretation" => Dict(
        "claim" => "Bounded local point-free analyze observations on BMOPFTools-generated combined MV+LV feeder snapshots under three declared scaling policies.",
        "does_not_establish" => [
            "OPF solver runtime, convergence, or policy superiority",
            "portable complexity or memory laws",
            "behavior beyond the variable guard and reviewed feeder fixtures",
        ],
    ),
))
println("wrote BMOPFTools combined MV+LV analyze scaling summary to $OUTPUT")
