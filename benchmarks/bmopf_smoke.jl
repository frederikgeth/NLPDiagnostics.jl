#!/usr/bin/env julia

# Run with a BMOPFTools environment that provides JuMP, Ipopt, and PowerIO:
#
# NLPDIAGNOSTICS_BMOPF_FIXTURE_ROOT=/path/to/BMOPFTools.jl/test/data/pf_comparison \
#   julia --project=. benchmarks/bmopf_smoke.jl
#
# This script builds and KCL-finalizes fresh contexts but never calls optimize!.
# Dense rank/SVD stages are guarded by NLPDIAGNOSTICS_BMOPF_RANK_MAX_DENSE_ENTRIES
# (250_000 by default). Set it to 0 to disable every dense rank stage.

using NLPDiagnostics
using BMOPFTools
using JuMP
using Ipopt # together with JuMP, activates BMOPFTools' public staged OPF extension
using JSON

const _SMOKE_FIXTURES = [
    (
        name = "grounded-neutral",
        file = "pf_1ph_perfectneutral.dss",
        description = "Single-phase phase-neutral load with an exactly grounded load neutral.",
        tags = [:smoke, :grounding, :single_phase],
    ),
    (
        name = "free-neutral-return",
        file = "pf_1ph_freeneutral.dss",
        description = "Single-phase phase-neutral load whose return path is through the feeder neutral.",
        tags = [:smoke, :grounding, :neutral],
    ),
    (
        name = "delta-load",
        file = "pf_delta_load.dss",
        description = "Unbalanced three-phase delta load on a grounded four-wire feeder.",
        tags = [:smoke, :delta, :multiconductor],
    ),
    (
        name = "unbalanced-three-phase-line",
        file = "pf_3ph_line.dss",
        description = "Unbalanced grounded four-wire three-phase feeder.",
        tags = [:smoke, :multiconductor, :unbalanced],
    ),
    (
        name = "wye-delta-transformer",
        file = "pf_yd_xfmr.dss",
        description = "Transformer connection semantics and mixed terminal topology.",
        tags = [:smoke, :transformer, :multiconductor],
    ),
]

function _benchmark_case(spec, context, point_policy::String)
    point = if point_policy == "initialization"
        candidate = NLPDiagnostics.bmopf_initialization_point(context)
        isnothing(candidate) && error(
            "$(spec.name): staged model has incomplete starts; rerun with " *
            "NLPDIAGNOSTICS_BMOPF_POINT_POLICY=zero for an explicitly synthetic probe",
        )
        candidate
    elseif point_policy == "bmopf_start_values"
        NLPDiagnostics.bmopf_start_completion_point(context;
            missing_value = 0.0,
            label = "bmopf-engine-starts-plus-zero-completion",
        )
    elseif point_policy == "zero"
        NLPDiagnostics.bmopf_coordinate_probe_point(context)
    else
        error("unknown NLPDIAGNOSTICS_BMOPF_POINT_POLICY='$point_policy' (use initialization, bmopf_start_values, or zero)")
    end
    return NLPDiagnostics.ProfileCase(spec.name, point;
        description = spec.description,
        task = "BMOPFTools real-fixture smoke benchmark",
        formulation = "BMOPF IVR",
        initialization = point_policy,
        scale = "per-unit",
        tags = spec.tags,
        metadata = Dict(
            "fixture" => spec.file,
            "point_policy" => point_policy,
            "point_provenance" => point_policy == "bmopf_start_values" ?
                                  "BMOPFTools voltage starts with explicit zero completion for missing coordinates" : point_policy,
        ),
    )
end

function _dense_entry_limit()
    raw = get(ENV, "NLPDIAGNOSTICS_BMOPF_RANK_MAX_DENSE_ENTRIES", "250000")
    limit = try
        parse(Int, raw)
    catch
        error("NLPDIAGNOSTICS_BMOPF_RANK_MAX_DENSE_ENTRIES must be a nonnegative integer, got '$raw'")
    end
    limit >= 0 || error("NLPDIAGNOSTICS_BMOPF_RANK_MAX_DENSE_ENTRIES must be nonnegative")
    return limit
end

function main()
    root = get(ENV, "NLPDIAGNOSTICS_BMOPF_FIXTURE_ROOT", "")
    isempty(root) && error(
        "Set NLPDIAGNOSTICS_BMOPF_FIXTURE_ROOT to BMOPFTools.jl/test/data/pf_comparison",
    )
    isdir(root) || error("fixture root does not exist: $root")
    output_dir = get(ENV, "NLPDIAGNOSTICS_BMOPF_OUTPUT_DIR",
                     joinpath(pwd(), "bmopf-smoke-results"))
    mkpath(output_dir)
    index = Vector{Dict{String,Any}}()
    selected = filter(!isempty, strip.(split(
        get(ENV, "NLPDIAGNOSTICS_BMOPF_CASES", ""), ',';
    )))
    fixtures = isempty(selected) ? _SMOKE_FIXTURES : filter(
        spec -> spec.name in selected, _SMOKE_FIXTURES,
    )
    isempty(fixtures) && error(
        "NLPDIAGNOSTICS_BMOPF_CASES selected no known fixture; choices are " *
        join((spec.name for spec in _SMOKE_FIXTURES), ", "),
    )
    point_policy = lowercase(get(ENV, "NLPDIAGNOSTICS_BMOPF_POINT_POLICY", "initialization"))
    dense_entry_limit = _dense_entry_limit()

    for spec in fixtures
        path = joinpath(root, spec.file)
        result_path = joinpath(output_dir, "$(spec.name).json")
        try
            isfile(path) || error("fixture is missing: $path")
            network = BMOPFTools.from_dss(path)
            run = NLPDiagnostics.bmopf_build_and_profile(network,
                context -> _benchmark_case(spec, context, point_policy);
                build_kwargs = (add_objective = false,),
                profile_kwargs = (
                    include_initialization = true,
                    rank_max_dense_entries = dense_entry_limit,
                    jacobian_rank_tolerance_sweep_max_dense_entries = dense_entry_limit,
                ),
            )
            data = NLPDiagnostics.profile_result_data(run.result)
            evaluation = run.result.profile.evaluation
            variable_count = length(evaluation.point.variables)
            constraint_row_count = length(evaluation.constraint_sources)
            jacobian_entries = variable_count * constraint_row_count
            generic_findings = sum(length(report["findings"]) for
                report in values(data["profile"]["reports"]))
            context_findings = length(data["bmopf_context_report"]["findings"])
            payload = Dict{String,Any}(
                "fixture" => spec.file,
                "fixture_path" => abspath(path),
                "tags" => string.(spec.tags),
                "point_policy" => point_policy,
                "model_variable_count" => variable_count,
                "scalar_constraint_row_count" => constraint_row_count,
                "jacobian_dense_entry_count" => jacobian_entries,
                "rank_max_dense_entries" => dense_entry_limit,
                "dense_rank_analysis_eligible" => jacobian_entries <= dense_entry_limit,
                "build_seconds" => run.build_seconds,
                "build_allocations" => run.build_allocations,
                "kcl_seconds" => run.kcl_seconds,
                "kcl_allocations" => run.kcl_allocations,
                "profile" => data,
            )
            write(result_path, JSON.json(payload))
            push!(index, Dict(
                "name" => spec.name, "status" => "ok",
                "result_file" => basename(result_path),
                "point_policy" => point_policy,
                "model_variable_count" => variable_count,
                "scalar_constraint_row_count" => constraint_row_count,
                "jacobian_dense_entry_count" => jacobian_entries,
                "rank_max_dense_entries" => dense_entry_limit,
                "dense_rank_analysis_eligible" => jacobian_entries <= dense_entry_limit,
                "generic_finding_count" => generic_findings,
                "context_finding_count" => context_findings,
                "build_seconds" => run.build_seconds, "kcl_seconds" => run.kcl_seconds,
            ))
            println("$(spec.name): build=$(round(run.build_seconds; digits = 3))s " *
                    "kcl=$(round(run.kcl_seconds; digits = 3))s " *
                    "generic_findings=$generic_findings context_findings=$context_findings")
        catch error
            message = sprint(showerror, error, catch_backtrace())
            write(result_path, JSON.json(Dict(
                "fixture" => spec.file, "fixture_path" => abspath(path),
                "status" => "error", "error" => message,
            )))
            push!(index, Dict(
                "name" => spec.name, "status" => "error",
                "result_file" => basename(result_path), "error" => message,
            ))
            println("$(spec.name): ERROR — $(sprint(showerror, error))")
        end
    end
    write(joinpath(output_dir, "index.json"), JSON.json(Dict(
        "fixture_root" => abspath(root),
        "rank_max_dense_entries" => dense_entry_limit,
        "cases" => index,
    )))
    println("wrote evidence records to $output_dir")
end

main()
