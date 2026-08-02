#!/usr/bin/env julia

# Size-aware runner for BMOPF JSON benchmark snapshots. This script deliberately
# defaults to two 30-bus representatives. Pass NLPDIAGNOSTICS_BMOPF_CASES with
# comma-separated relative paths to select another snapshot, including a 538-bus
# case. Dense rank/SVD stages are skipped once the Jacobian entry count exceeds
# NLPDIAGNOSTICS_BMOPF_RANK_MAX_DENSE_ENTRIES (250_000 by default). Set
# NLPDIAGNOSTICS_BMOPF_ANALYSIS_MODE=structural for static/structural evidence
# only: it requests no point evaluation or derivative analysis.
#
# NLPDIAGNOSTICS_BMOPF_BENCHMARK_ROOT=/path/to/BMOPFDraftData/benchmarks \
#   NLPDIAGNOSTICS_BMOPF_POINT_POLICY=zero \
#   julia --project=. benchmarks/bmopf_draft_corpus.jl
#
# Use NLPDIAGNOSTICS_BMOPF_POINT_POLICY=saved_result to profile an adjacent
# saved result. It defaults to `<snapshot>_result_si.json`; record a different
# numerical convention explicitly with NLPDIAGNOSTICS_BMOPF_RESULT_UNITS and
# NLPDIAGNOSTICS_BMOPF_RESULT_SUFFIX.

using NLPDiagnostics
using BMOPFTools
using JuMP
using Ipopt # activates BMOPFTools' public staged OPF extension
using JSON

const _DEFAULT_CASES = [
    "ENWLsnapshots/30bus_LN/30bus_LN_t01_0800.bmopf.json",
    "ENWLsnapshots/30bus_LG/30bus_LG_t01_0800.bmopf.json",
]

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

function _saved_result_path(snapshot_path, result_units)
    suffix = get(ENV, "NLPDIAGNOSTICS_BMOPF_RESULT_SUFFIX", "_result_$(result_units).json")
    endswith(suffix, ".json") || error("NLPDIAGNOSTICS_BMOPF_RESULT_SUFFIX must end in .json")
    path = replace(snapshot_path, ".bmopf.json" => suffix)
    isfile(path) || error("saved-result policy requested, but no result file exists at $path")
    return path
end

function _case_point(name, context, point_policy, snapshot_path)
    point, provenance, metadata = if point_policy == "initialization"
        candidate = NLPDiagnostics.bmopf_initialization_point(context)
        isnothing(candidate) && error(
            "$name: staged model has incomplete starts; rerun with " *
            "NLPDIAGNOSTICS_BMOPF_POINT_POLICY=zero for a synthetic coordinate probe",
        )
        candidate, point_policy, Dict{String,Any}()
    elseif point_policy == "bmopf_start_values"
        NLPDiagnostics.bmopf_start_completion_point(context;
            missing_value = 0.0,
            label = "bmopf-engine-starts-plus-zero-completion",
        ), "BMOPFTools voltage starts with explicit zero completion for missing coordinates", Dict{String,Any}()
    elseif point_policy == "saved_result"
        result_units = Symbol(lowercase(get(ENV, "NLPDIAGNOSTICS_BMOPF_RESULT_UNITS", "si")))
        result_units in (:si, :model) || error("NLPDIAGNOSTICS_BMOPF_RESULT_UNITS must be si or model")
        path = _saved_result_path(snapshot_path, result_units)
        mapped = NLPDiagnostics.bmopf_result_voltage_point(context, BMOPFTools.read_result(path);
            result_units = result_units,
            label = "bmopf-saved-result-partial-probe",
        )
        mapped.point,
        "saved BMOPF result with explicit fallback for unmapped coordinates",
        Dict{String,Any}(
            "saved_result_path" => abspath(path),
            "saved_result_units" => string(result_units),
            "mapped_coordinate_count" => mapped.mapped_coordinate_count,
            "fallback_coordinate_count" => mapped.fallback_coordinate_count,
            "registered_coordinate_count" => mapped.registered_coordinate_count,
            "mapped_registered_coordinate_fraction" => mapped.mapped_registered_coordinate_fraction,
            "mapped_coordinate_counts_by_family" => mapped.mapped_coordinate_counts_by_family,
            "unresolved_saved_coordinate_counts_by_family" => mapped.unresolved_saved_coordinate_counts_by_family,
        )
    elseif point_policy == "zero"
        NLPDiagnostics.bmopf_coordinate_probe_point(context; label = "bmopf-draft-zero-coordinate-probe"), point_policy, Dict{String,Any}()
    else
        error("unknown NLPDIAGNOSTICS_BMOPF_POINT_POLICY='$point_policy' (use initialization, bmopf_start_values, saved_result, or zero)")
    end
    profile_metadata = Dict{String,Any}(
        "point_policy" => point_policy,
        "point_provenance" => provenance,
    )
    merge!(profile_metadata, metadata)
    return NLPDiagnostics.ProfileCase(name, point;
        description = "BMOPF draft-data snapshot; point policy=$point_policy",
        task = "BMOPF draft-corpus diagnostic benchmark",
        formulation = "BMOPF IVR",
        initialization = point_policy,
        scale = "as declared by BMOPF snapshot",
        tags = [:bmopf, :draft_corpus, :multiconductor],
        metadata = profile_metadata,
    )
end

function _requested_cases(root)
    selected = filter(!isempty, strip.(split(get(ENV, "NLPDIAGNOSTICS_BMOPF_CASES", ""), ',')))
    cases = isempty(selected) ? _DEFAULT_CASES : selected
    for relative in cases
        isabspath(relative) && error("case selections must be relative to NLPDIAGNOSTICS_BMOPF_BENCHMARK_ROOT: $relative")
        endswith(relative, ".bmopf.json") || error("case selection is not a .bmopf.json snapshot: $relative")
        isfile(joinpath(root, relative)) || error("selected snapshot is missing: $(joinpath(root, relative))")
    end
    return cases
end

function _record_name(relative)
    replace(replace(relative, '/' => "__"), ".bmopf.json" => "")
end

function main()
    root = get(ENV, "NLPDIAGNOSTICS_BMOPF_BENCHMARK_ROOT", "")
    isempty(root) && error("Set NLPDIAGNOSTICS_BMOPF_BENCHMARK_ROOT to BMOPFDraftData/benchmarks")
    isdir(root) || error("benchmark root does not exist: $root")
    output_dir = get(ENV, "NLPDIAGNOSTICS_BMOPF_OUTPUT_DIR", joinpath(pwd(), "bmopf-draft-results"))
    mkpath(output_dir)
    point_policy = lowercase(get(ENV, "NLPDIAGNOSTICS_BMOPF_POINT_POLICY", "initialization"))
    analysis_mode = lowercase(get(ENV, "NLPDIAGNOSTICS_BMOPF_ANALYSIS_MODE", "profile"))
    analysis_mode in ("profile", "structural") || error(
        "unknown NLPDIAGNOSTICS_BMOPF_ANALYSIS_MODE='$analysis_mode' (use profile or structural)",
    )
    dense_entry_limit = _dense_entry_limit()
    index = Vector{Dict{String,Any}}()

    for relative in _requested_cases(root)
        path = joinpath(root, relative)
        name = _record_name(relative)
        result_path = joinpath(output_dir, "$name.json")
        try
            network = BMOPFTools.parse_bmopf(path)
            run, data, variable_count, constraint_row_count, jacobian_entries,
            generic_findings, context_findings = if analysis_mode == "profile"
                profile_run = NLPDiagnostics.bmopf_build_and_profile(network,
                    context -> _case_point(name, context, point_policy, path);
                    build_kwargs = (add_objective = false,),
                    profile_kwargs = (
                        include_initialization = true,
                        rank_max_dense_entries = dense_entry_limit,
                        jacobian_rank_tolerance_sweep_max_dense_entries = dense_entry_limit,
                    ),
                )
                profile_data = NLPDiagnostics.profile_result_data(profile_run.result)
                evaluation = profile_run.result.profile.evaluation
                variables = length(evaluation.point.variables)
                rows = length(evaluation.constraint_sources)
                findings = sum(length(report["findings"]) for report in values(profile_data["profile"]["reports"]))
                (profile_run, profile_data, variables, rows, variables * rows,
                 findings, length(profile_data["bmopf_context_report"]["findings"]))
            else
                structural_run = NLPDiagnostics.bmopf_build_and_analyze_opf(network;
                    build_kwargs = (add_objective = false,),
                )
                structural_data = NLPDiagnostics.report_data(structural_run.report)
                variables = parse(Int, structural_run.report.metadata[:variable_count])
                constraints = parse(Int, structural_run.report.metadata[:constraint_count])
                (structural_run, structural_data, variables, constraints, nothing,
                 length(structural_data["findings"]), nothing)
            end
            row_count_key = analysis_mode == "profile" ?
                            "scalar_constraint_row_count" : "model_constraint_count"
            analysis_data_key = analysis_mode == "profile" ? "profile" : "report"
            payload = Dict{String,Any}(
                "snapshot" => relative,
                "snapshot_path" => abspath(path),
                "analysis_mode" => analysis_mode,
                "point_policy" => point_policy,
                "model_variable_count" => variable_count,
                row_count_key => constraint_row_count,
                "jacobian_dense_entry_count" => jacobian_entries,
                "rank_max_dense_entries" => dense_entry_limit,
                "dense_rank_analysis_eligible" => isnothing(jacobian_entries) ? false : jacobian_entries <= dense_entry_limit,
                "derivative_evaluation_requested" => analysis_mode == "profile",
                "build_seconds" => run.build_seconds,
                "build_allocations" => run.build_allocations,
                "kcl_seconds" => run.kcl_seconds,
                "kcl_allocations" => run.kcl_allocations,
                analysis_data_key => data,
            )
            write(result_path, JSON.json(payload))
            push!(index, Dict(
                "name" => name, "snapshot" => relative, "status" => "ok",
                "result_file" => basename(result_path), "analysis_mode" => analysis_mode,
                "point_policy" => point_policy,
                "model_variable_count" => variable_count,
                row_count_key => constraint_row_count,
                "jacobian_dense_entry_count" => jacobian_entries,
                "rank_max_dense_entries" => dense_entry_limit,
                "dense_rank_analysis_eligible" => isnothing(jacobian_entries) ? false : jacobian_entries <= dense_entry_limit,
                "derivative_evaluation_requested" => analysis_mode == "profile",
                "generic_finding_count" => generic_findings,
                "context_finding_count" => context_findings,
                "build_seconds" => run.build_seconds, "kcl_seconds" => run.kcl_seconds,
            ))
            dense_status = isnothing(jacobian_entries) ? "not-requested" :
                           (jacobian_entries <= dense_entry_limit ? "enabled" : "skipped")
            println("$name: mode=$analysis_mode variables=$variable_count rows=$constraint_row_count " *
                    "dense=$dense_status " *
                    "findings=$generic_findings")
        catch error
            message = sprint(showerror, error, catch_backtrace())
            write(result_path, JSON.json(Dict(
                "snapshot" => relative, "snapshot_path" => abspath(path),
                "status" => "error", "error" => message,
            )))
            push!(index, Dict(
                "name" => name, "snapshot" => relative, "status" => "error",
                "result_file" => basename(result_path), "error" => message,
            ))
            println("$name: ERROR — $(sprint(showerror, error))")
        end
    end
    write(joinpath(output_dir, "index.json"), JSON.json(Dict(
        "benchmark_root" => abspath(root),
        "analysis_mode" => analysis_mode,
        "rank_max_dense_entries" => dense_entry_limit,
        "cases" => index,
    )))
    println("wrote evidence records to $output_dir")
end

main()
