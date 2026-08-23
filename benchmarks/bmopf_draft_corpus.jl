#!/usr/bin/env julia

# Size-aware runner for BMOPF JSON benchmark snapshots. This script deliberately
# defaults to two 30-bus representatives. Pass NLPDIAGNOSTICS_BMOPF_CASES with
# comma-separated relative paths to select another snapshot, including a 538-bus
# case. Dense rank/SVD stages are skipped once the Jacobian entry count exceeds
# NLPDIAGNOSTICS_BMOPF_RANK_MAX_DENSE_ENTRIES (250_000 by default). Sparse QR
# is independently bounded by NLPDIAGNOSTICS_BMOPF_SPARSE_QR_MAX_INPUT_NONZEROS
# and NLPDIAGNOSTICS_BMOPF_SPARSE_QR_MAX_FACTOR_NONZEROS. A breached budget is
# retained as an explicit unavailable/resource-guard finding. Set
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
# Set NLPDIAGNOSTICS_BMOPF_RESULT_UNITS=pu to consume the corpus' adjacent
# `_result_pu.json` files; `model` remains an alias for already-scaled values.
# For mixed exports, override individual families with
# NLPDIAGNOSTICS_BMOPF_RESULT_FIELD_UNITS=bus_voltage=si,line_current=pu.
# Set NLPDIAGNOSTICS_BMOPF_RESUME=true to reuse only matching successful
# records. Set NLPDIAGNOSTICS_BMOPF_FORCE=true to rerun selected cases.
# Set NLPDIAGNOSTICS_BMOPF_CROSSCHECK_FINITE_DIFFERENCE_ROWS=true to compare
# finite-difference-provenance rows against deterministic dense-direction
# central differences of perturbed constraint values.

using NLPDiagnostics
using BMOPFTools
using JuMP
using Ipopt # activates BMOPFTools' public staged OPF extension
using JSON
using SHA

Base.include(@__MODULE__, joinpath(@__DIR__, "common.jl"))
using .NLPDiagnosticsBenchmarkCommon: write_json

include(joinpath(@__DIR__, "benchmark_environment.jl"))

const _RUNNER_VERSION = "bmopf-draft-corpus-v12"

const _DEFAULT_CASES = [
    "ENWLsnapshots/30bus_LN/30bus_LN_t01_0800.bmopf.json",
    "ENWLsnapshots/30bus_LG/30bus_LG_t01_0800.bmopf.json",
]

function _family_scaling_experiment_families()
    raw = get(ENV, "NLPDIAGNOSTICS_BMOPF_FAMILY_SCALING_EXPERIMENTS", "")
    return unique(filter(!isempty, strip.(split(raw, ','))))
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

function _nonnegative_env_int(name, default)
    raw = get(ENV, name, string(default))
    value = try
        parse(Int, raw)
    catch
        error("$name must be a nonnegative integer, got '$raw'")
    end
    value >= 0 || error("$name must be nonnegative")
    return value
end

function _positive_env_float(name, default)
    raw = get(ENV, name, string(default))
    value = try
        parse(Float64, raw)
    catch
        error("$name must be a positive finite number, got '$raw'")
    end
    isfinite(value) && value > 0.0 ||
        error("$name must be a positive finite number")
    return value
end

function _saved_result_path(snapshot_path, result_units)
    suffix = get(ENV, "NLPDIAGNOSTICS_BMOPF_RESULT_SUFFIX", "_result_$(result_units).json")
    endswith(suffix, ".json") || error("NLPDIAGNOSTICS_BMOPF_RESULT_SUFFIX must end in .json")
    path = replace(snapshot_path, ".bmopf.json" => suffix)
    isfile(path) || error("saved-result policy requested, but no result file exists at $path")
    return path
end

function _result_field_units()
    raw = strip(get(ENV, "NLPDIAGNOSTICS_BMOPF_RESULT_FIELD_UNITS", ""))
    isempty(raw) && return Dict{Symbol,Symbol}()
    units = Dict{Symbol,Symbol}()
    for item in split(raw, ',')
        token = strip(item)
        isempty(token) && continue
        parts = occursin('=', token) ? split(token, '='; limit = 2) : split(token, ':'; limit = 2)
        length(parts) == 2 || error("NLPDIAGNOSTICS_BMOPF_RESULT_FIELD_UNITS entries must use family=unit, got '$token'")
        family = Symbol(lowercase(strip(parts[1])))
        unit = Symbol(lowercase(strip(parts[2])))
        unit in (:si, :pu, :model) || error("NLPDIAGNOSTICS_BMOPF_RESULT_FIELD_UNITS unit must be si, pu, or model, got '$unit'")
        family in (:bus_voltage, :line_current, :load_current, :generator_current, :generator_power, :source_current,
                   :ibr_current, :ibr_power, :switch_current, :ground_current) ||
            error("unknown NLPDIAGNOSTICS_BMOPF_RESULT_FIELD_UNITS family '$family'")
        haskey(units, family) && error("duplicate NLPDIAGNOSTICS_BMOPF_RESULT_FIELD_UNITS family '$family'")
        units[family] = unit
    end
    return units
end

function _case_point(name, context, point_policy, snapshot_path; mapping_sink = nothing)
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
        result_units in (:si, :pu, :model) || error("NLPDIAGNOSTICS_BMOPF_RESULT_UNITS must be si, pu, or model")
        field_units = _result_field_units()
        path = _saved_result_path(snapshot_path, result_units)
        saved = NLPDiagnostics.bmopf_saved_result_profile_case(
            name, context, BMOPFTools.read_result(path);
            result_units = result_units,
            field_units = field_units,
            label = "bmopf-saved-result-partial-probe",
            description = "BMOPF draft-data snapshot; point policy=$point_policy",
            task = "BMOPF draft-corpus diagnostic benchmark",
            formulation = "BMOPF IVR",
            scale = "as declared by BMOPF snapshot",
            tags = [:bmopf, :draft_corpus, :multiconductor, :saved_result],
            metadata = Dict{String,Any}(
                "saved_result_path" => abspath(path),
                "saved_result_field_units" => join(("$(key)=$(value)" for (key, value) in sort!(collect(field_units); by = first)), ","),
            ),
        )
        # Preserve the full adapter return, not only the raw mapping. The
        # mapping report also carries the unit fingerprint and any
        # representational qualification that a benchmark summary must retain.
        !isnothing(mapping_sink) && (mapping_sink[] = saved)
        return saved.case
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
    selection = lowercase(strip(get(ENV, "NLPDIAGNOSTICS_BMOPF_CASE_SELECTION", "")))
    if isempty(selected) && !isempty(selection)
        prefixes = if selection == "30bus"
            ["ENWLsnapshots/30bus_LN/", "ENWLsnapshots/30bus_LG/"]
        elseif selection == "30bus_ln"
            ["ENWLsnapshots/30bus_LN/"]
        elseif selection == "30bus_lg"
            ["ENWLsnapshots/30bus_LG/"]
        elseif selection == "538bus"
            ["ENWLsnapshots/538bus_LN/", "ENWLsnapshots/538bus_LG/"]
        elseif selection == "538bus_ln"
            ["ENWLsnapshots/538bus_LN/"]
        elseif selection == "538bus_lg"
            ["ENWLsnapshots/538bus_LG/"]
        elseif selection == "99bus"
            ["ENWLsnapshots/99bus_LN/", "ENWLsnapshots/99bus_LG/"]
        elseif selection == "99bus_ln"
            ["ENWLsnapshots/99bus_LN/"]
        elseif selection == "99bus_lg"
            ["ENWLsnapshots/99bus_LG/"]
        else
            error("unknown NLPDIAGNOSTICS_BMOPF_CASE_SELECTION='$selection' " *
                  "(use 30bus[_ln|_lg], 538bus[_ln|_lg], or 99bus[_ln|_lg])")
        end
        discovered = String[]
        for (directory, _, files) in walkdir(joinpath(root, "ENWLsnapshots"))
            for file in files
                endswith(file, ".bmopf.json") || continue
                relative = relpath(joinpath(directory, file), root)
                any(startswith(relative, prefix) for prefix in prefixes) || continue
                push!(discovered, relative)
            end
        end
        cases = sort!(discovered)
        isempty(cases) && error("NLPDIAGNOSTICS_BMOPF_CASE_SELECTION='$selection' found no snapshots")
    else
        cases = isempty(selected) ? _DEFAULT_CASES : selected
    end
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

function _env_flag(name; default = false)
    raw = lowercase(strip(get(ENV, name, default ? "true" : "false")))
    raw in ("1", "true", "yes", "on") && return true
    raw in ("0", "false", "no", "off") && return false
    error("$name must be a boolean (true/false), got '$raw'")
end

function _controller_curve_profile_data(context, point)
    observations = NLPDiagnostics.bmopf_controller_curve_operating_point_observations(
        context, point; result_units = :model,
    )
    families = sort!(collect(Set(string(observation.curve_family) for observation in observations)))
    statuses = sort!(collect(Set(string(observation.status) for observation in observations)))
    semantics = sort!(collect(Set(string(observation.monitor_semantics) for observation in observations)))
    exact_count = count(
        observation -> observation.monitor_semantics == :exact_public_monitored_voltage,
        observations,
    )
    proxy_count = count(
        observation -> observation.monitor_semantics == :terminal_pair_magnitude_proxy,
        observations,
    )
    return Dict{String,Any}(
        "observations" => NLPDiagnostics.controller_curve_operating_point_observation_data(observations),
        "observation_count" => length(observations),
        "families" => families,
        "statuses" => statuses,
        "monitor_semantics" => semantics,
        "exact_monitor_count" => exact_count,
        "proxy_monitor_count" => proxy_count,
        "equation_residual_count" => count(observation -> !isnothing(observation.equation_residual), observations),
        "cap_violation_count" => count(
            observation -> !isnothing(observation.cap_violation) && observation.cap_violation > 0.0,
            observations,
        ),
    )
end

function _bmopf_integrity_preflight(network)
    findings = BMOPFTools.Finding[]
    result = BMOPFTools.integrity_check(network, findings)
    return Dict{String,Any}(
        "error_count" => count(f -> f.severity == BMOPFTools.ERROR, findings),
        "warning_count" => count(f -> f.severity == BMOPFTools.WARNING, findings),
        "finding_count" => length(findings),
        "blocking" => any(f -> f.severity == BMOPFTools.ERROR, findings),
        "findings" => [Dict{String,Any}(
            "severity" => string(f.severity), "code" => f.code,
            "section" => string(f.section), "component_type" => string(f.component_type),
            "component_id" => f.component_id, "message" => f.message,
            "detail" => f.detail,
        ) for f in findings],
        "summary" => result,
    )
end

function _sha256_file(path)
    return bytes2hex(SHA.sha256(read(path)))
end

function _case_fingerprint(
    root, relative, point_policy, analysis_mode, dense_entry_limit,
    sparse_qr_max_input_nonzeros, sparse_qr_max_factor_nonzeros,
    include_floating_neutral_candidates, family_scaling_experiment_families,
    crosscheck_finite_difference_rows, crosscheck_direction_count,
    crosscheck_relative_step,
    environment_fingerprint = _benchmark_environment_fingerprint(),
)
    snapshot_path = joinpath(root, relative)
    result_units = lowercase(get(ENV, "NLPDIAGNOSTICS_BMOPF_RESULT_UNITS", "si"))
    result_field_units = get(ENV, "NLPDIAGNOSTICS_BMOPF_RESULT_FIELD_UNITS", "")
    result_suffix = get(ENV, "NLPDIAGNOSTICS_BMOPF_RESULT_SUFFIX", "_result_$(result_units).json")
    endswith(result_suffix, ".json") || error("NLPDIAGNOSTICS_BMOPF_RESULT_SUFFIX must end in .json")
    result_path = point_policy == "saved_result" ?
                  replace(snapshot_path, ".bmopf.json" => result_suffix) : nothing
    parts = String[
        _RUNNER_VERSION,
        relative,
        _sha256_file(snapshot_path),
        point_policy,
        analysis_mode,
        string(dense_entry_limit),
        string(sparse_qr_max_input_nonzeros),
        string(sparse_qr_max_factor_nonzeros),
        string(include_floating_neutral_candidates),
        join(family_scaling_experiment_families, ","),
        string(crosscheck_finite_difference_rows),
        string(crosscheck_direction_count),
        string(crosscheck_relative_step),
        result_units,
        result_field_units,
        result_suffix,
        environment_fingerprint,
    ]
    if !isnothing(result_path) && isfile(result_path)
        push!(parts, _sha256_file(result_path))
    elseif !isnothing(result_path)
        push!(parts, "missing-result-file")
    end
    return bytes2hex(SHA.sha256(codeunits(join(parts, "\n"))))
end

function _cached_case_index(name, relative, result_file, record, fingerprint)
    return Dict{String,Any}(
        "name" => name,
        "snapshot" => relative,
        "status" => "skipped",
        "skip_reason" => "matching_cached_result",
        "result_file" => result_file,
        "analysis_mode" => get(record, "analysis_mode", "unknown"),
        "point_policy" => get(record, "point_policy", "unknown"),
        "campaign_fingerprint" => fingerprint,
        "model_variable_count" => get(record, "model_variable_count", nothing),
        "generic_finding_count" => nothing,
        "context_finding_count" => nothing,
    )
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
    sparse_qr_max_input_nonzeros = _nonnegative_env_int(
        "NLPDIAGNOSTICS_BMOPF_SPARSE_QR_MAX_INPUT_NONZEROS", 1_000_000,
    )
    sparse_qr_max_factor_nonzeros = _nonnegative_env_int(
        "NLPDIAGNOSTICS_BMOPF_SPARSE_QR_MAX_FACTOR_NONZEROS", 4_000_000,
    )
    include_floating_neutral_candidates = _env_flag(
        "NLPDIAGNOSTICS_BMOPF_INCLUDE_FLOATING_NEUTRAL_CANDIDATES";
        default = false,
    )
    family_scaling_experiment_families =
        _family_scaling_experiment_families()
    crosscheck_finite_difference_rows = _env_flag(
        "NLPDIAGNOSTICS_BMOPF_CROSSCHECK_FINITE_DIFFERENCE_ROWS";
        default = false,
    )
    crosscheck_direction_count = _nonnegative_env_int(
        "NLPDIAGNOSTICS_BMOPF_CROSSCHECK_DIRECTION_COUNT", 3,
    )
    crosscheck_relative_step = _positive_env_float(
        "NLPDIAGNOSTICS_BMOPF_CROSSCHECK_RELATIVE_STEP", cbrt(eps(Float64)),
    )
    crosscheck_finite_difference_rows && crosscheck_direction_count == 0 &&
        error("NLPDIAGNOSTICS_BMOPF_CROSSCHECK_DIRECTION_COUNT must be positive when the finite-difference row crosscheck is enabled")
    resume = _env_flag("NLPDIAGNOSTICS_BMOPF_RESUME")
    force = _env_flag("NLPDIAGNOSTICS_BMOPF_FORCE")
    force && (resume = false)
    environment = _benchmark_environment()
    environment_fingerprint = _benchmark_environment_fingerprint(environment)
    selected_cases = _requested_cases(root)
    manifest_cases = Dict{String,Any}[]
    for relative in selected_cases
        fingerprint = _case_fingerprint(
            root, relative, point_policy, analysis_mode, dense_entry_limit,
            sparse_qr_max_input_nonzeros, sparse_qr_max_factor_nonzeros,
            include_floating_neutral_candidates,
            family_scaling_experiment_families,
            crosscheck_finite_difference_rows,
            crosscheck_direction_count,
            crosscheck_relative_step,
            environment_fingerprint,
        )
        push!(manifest_cases, Dict(
            "snapshot" => relative,
            "snapshot_sha256" => _sha256_file(joinpath(root, relative)),
            "campaign_fingerprint" => fingerprint,
        ))
    end
    write_json(joinpath(output_dir, "campaign_manifest.json"), Dict(
        "runner_version" => _RUNNER_VERSION,
        "benchmark_root" => abspath(root),
        "case_selection" => get(ENV, "NLPDIAGNOSTICS_BMOPF_CASE_SELECTION", ""),
        "analysis_mode" => analysis_mode,
        "point_policy" => point_policy,
        "result_units" => lowercase(get(ENV, "NLPDIAGNOSTICS_BMOPF_RESULT_UNITS", "si")),
        "result_field_units" => get(ENV, "NLPDIAGNOSTICS_BMOPF_RESULT_FIELD_UNITS", ""),
        "include_floating_neutral_candidates" => include_floating_neutral_candidates,
        "crosscheck_finite_difference_rows" => crosscheck_finite_difference_rows,
        "crosscheck_direction_count" => crosscheck_direction_count,
        "crosscheck_relative_step" => crosscheck_relative_step,
        "crosscheck_direction_policy" => "dense_deterministic",
        "rank_max_dense_entries" => dense_entry_limit,
        "sparse_qr_max_input_nonzeros" => sparse_qr_max_input_nonzeros,
        "sparse_qr_max_factor_nonzeros" => sparse_qr_max_factor_nonzeros,
        "resume" => resume,
        "force" => force,
        "environment" => environment,
        "environment_fingerprint" => environment_fingerprint,
        "cases" => manifest_cases,
    ))
    index = Vector{Dict{String,Any}}()

    for relative in selected_cases
        path = joinpath(root, relative)
        name = _record_name(relative)
        result_path = joinpath(output_dir, "$name.json")
        fingerprint = only(item["campaign_fingerprint"] for item in manifest_cases
                           if item["snapshot"] == relative)
        if resume && !force && isfile(result_path)
            cached = try
                JSON.parsefile(result_path)
            catch
                nothing
            end
            if cached isa AbstractDict &&
               get(cached, "status", nothing) == "ok" &&
               get(cached, "campaign_fingerprint", nothing) == fingerprint
                push!(index, _cached_case_index(name, relative, basename(result_path), cached, fingerprint))
                println("$name: SKIPPED — matching cached result")
                continue
            end
        end
        preflight = nothing
        try
            network = BMOPFTools.parse_bmopf(path)
            preflight = _bmopf_integrity_preflight(network)
            run, data, variable_count, constraint_row_count, jacobian_entries,
            generic_findings, context_findings = if analysis_mode == "profile"
                mapping_sink = Ref{Any}(nothing)
                profile_run = NLPDiagnostics.bmopf_build_and_profile(network,
                    context -> _case_point(name, context, point_policy, path;
                        mapping_sink = mapping_sink,
                    );
                    build_kwargs = (add_objective = false,),
                    profile_kwargs = (
                        include_initialization = true,
                        include_floating_neutral_candidates = include_floating_neutral_candidates,
                        rank_max_dense_entries = dense_entry_limit,
                        sparse_qr_rank_max_input_nonzeros =
                            sparse_qr_max_input_nonzeros,
                        sparse_qr_rank_max_factor_nonzeros =
                            sparse_qr_max_factor_nonzeros,
                        jacobian_rank_tolerance_sweep_max_dense_entries = dense_entry_limit,
                        check_jacobian_directional_crosscheck =
                            crosscheck_finite_difference_rows,
                        jacobian_directional_crosscheck_row_methods =
                            [:central_finite_difference,
                             :partial_central_finite_difference],
                        jacobian_directional_crosscheck_direction_count =
                            crosscheck_direction_count,
                        jacobian_directional_crosscheck_relative_step =
                            crosscheck_relative_step,
                        jacobian_directional_crosscheck_direction_policy =
                            :dense_deterministic,
                    ),
                )
                saved_mapping = mapping_sink[]
                mapping = isnothing(saved_mapping) ? nothing :
                    (hasproperty(saved_mapping, :mapping) ? saved_mapping.mapping : saved_mapping)
                mapping_report = isnothing(saved_mapping) ? nothing :
                    (hasproperty(saved_mapping, :mapping_report) ?
                     saved_mapping.mapping_report :
                     NLPDiagnostics.bmopf_result_mapping_report(mapping))
                if !isnothing(mapping_report)
                    append!(profile_run.result.context_report.findings, mapping_report.findings)
                    merge!(profile_run.result.context_report.metadata, mapping_report.metadata)
                    sort!(profile_run.result.context_report.findings;
                          by = finding -> (-Int(finding.severity), string(finding.code)))
                end
                profile_data = NLPDiagnostics.profile_result_data(profile_run.result)
                controller_curve_data = _controller_curve_profile_data(
                    profile_run.context, profile_run.result.profile.evaluation.point,
                )
                profile_data["bmopf_controller_curve_observations"] = controller_curve_data
                profile_data["bmopf_constraint_feasibility_field_attribution"] =
                    NLPDiagnostics.report_data(
                        NLPDiagnostics.bmopf_constraint_feasibility_field_attribution(
                            profile_run.context, profile_run.result; mapping,
                        ),
                    )
                evaluation = profile_run.result.profile.evaluation
                profile_data["bmopf_constraint_semantic_rows"] =
                    NLPDiagnostics.bmopf_constraint_semantic_row_map(
                        profile_run.context, evaluation,
                    )
                profile_data["bmopf_jacobian_row_family_scale_attribution"] =
                    NLPDiagnostics.bmopf_jacobian_row_family_scale_attribution(
                        profile_run.context, evaluation,
                    )
                if !isempty(family_scaling_experiment_families)
                    profile_data["bmopf_jacobian_row_family_scaling_experiment"] =
                        NLPDiagnostics.bmopf_jacobian_row_family_scaling_experiment(
                            profile_run.context, evaluation;
                            families = family_scaling_experiment_families,
                        )
                end
                profile_data["bmopf_constraint_registry_coverage"] =
                    NLPDiagnostics.report_data(
                        NLPDiagnostics.bmopf_constraint_registry_coverage_report(
                            profile_run.context, evaluation,
                        ),
                    )
                variables = length(evaluation.point.variables)
                rows = length(evaluation.constraint_sources)
                findings = sum(length(report["findings"]) for report in values(profile_data["profile"]["reports"]))
                profile_data["bmopf_saved_result_mapping_report"] =
                    isnothing(mapping_report) ? nothing : NLPDiagnostics.report_data(mapping_report)
                (profile_run, profile_data, variables, rows, variables * rows,
                 findings, length(profile_data["bmopf_context_report"]["findings"]))
            else
                structural_run = NLPDiagnostics.bmopf_build_and_analyze_opf(network;
                    build_kwargs = (add_objective = false,),
                    analysis_kwargs = (include_floating_neutral_candidates = include_floating_neutral_candidates,),
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
                "campaign_fingerprint" => fingerprint,
                "environment_fingerprint" => environment_fingerprint,
                "analysis_mode" => analysis_mode,
                "point_policy" => point_policy,
                "include_floating_neutral_candidates" => include_floating_neutral_candidates,
                "crosscheck_finite_difference_rows" => crosscheck_finite_difference_rows,
                "crosscheck_direction_count" => crosscheck_direction_count,
                "crosscheck_relative_step" => crosscheck_relative_step,
                "crosscheck_direction_policy" => "dense_deterministic",
                "integrity_preflight" => preflight,
                "model_variable_count" => variable_count,
                row_count_key => constraint_row_count,
                "jacobian_dense_entry_count" => jacobian_entries,
                "rank_max_dense_entries" => dense_entry_limit,
                "sparse_qr_max_input_nonzeros" =>
                    sparse_qr_max_input_nonzeros,
                "sparse_qr_max_factor_nonzeros" =>
                    sparse_qr_max_factor_nonzeros,
                "dense_rank_analysis_eligible" => isnothing(jacobian_entries) ? false : jacobian_entries <= dense_entry_limit,
                "derivative_evaluation_requested" => analysis_mode == "profile",
                "build_seconds" => run.build_seconds,
                "build_allocations" => run.build_allocations,
                "kcl_seconds" => run.kcl_seconds,
                "kcl_allocations" => run.kcl_allocations,
                analysis_data_key => data,
            )
            write_json(result_path, payload)
            push!(index, Dict(
                "name" => name, "snapshot" => relative, "status" => "ok",
                "campaign_fingerprint" => fingerprint,
                "result_file" => basename(result_path), "analysis_mode" => analysis_mode,
                "point_policy" => point_policy,
                "crosscheck_finite_difference_rows" => crosscheck_finite_difference_rows,
                "crosscheck_direction_count" => crosscheck_direction_count,
                "crosscheck_relative_step" => crosscheck_relative_step,
                "crosscheck_direction_policy" => "dense_deterministic",
                "model_variable_count" => variable_count,
                row_count_key => constraint_row_count,
                "jacobian_dense_entry_count" => jacobian_entries,
                "rank_max_dense_entries" => dense_entry_limit,
                "sparse_qr_max_input_nonzeros" =>
                    sparse_qr_max_input_nonzeros,
                "sparse_qr_max_factor_nonzeros" =>
                    sparse_qr_max_factor_nonzeros,
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
            write_json(result_path, Dict(
                "snapshot" => relative, "snapshot_path" => abspath(path),
                "status" => "error", "error" => message,
                "integrity_preflight" => preflight,
                "campaign_fingerprint" => fingerprint,
                "environment_fingerprint" => environment_fingerprint,
            ))
            push!(index, Dict(
                "name" => name, "snapshot" => relative, "status" => "error",
                "result_file" => basename(result_path), "error" => message,
                "campaign_fingerprint" => fingerprint,
            ))
            println("$name: ERROR — $(sprint(showerror, error))")
        end
    end
    write_json(joinpath(output_dir, "index.json"), Dict(
        "benchmark_root" => abspath(root),
        "runner_version" => _RUNNER_VERSION,
        "case_selection" => get(ENV, "NLPDIAGNOSTICS_BMOPF_CASE_SELECTION", ""),
        "analysis_mode" => analysis_mode,
        "point_policy" => point_policy,
        "result_units" => lowercase(get(ENV, "NLPDIAGNOSTICS_BMOPF_RESULT_UNITS", "si")),
        "result_field_units" => get(ENV, "NLPDIAGNOSTICS_BMOPF_RESULT_FIELD_UNITS", ""),
        "include_floating_neutral_candidates" => include_floating_neutral_candidates,
        "crosscheck_finite_difference_rows" => crosscheck_finite_difference_rows,
        "crosscheck_direction_count" => crosscheck_direction_count,
        "crosscheck_relative_step" => crosscheck_relative_step,
        "crosscheck_direction_policy" => "dense_deterministic",
        "rank_max_dense_entries" => dense_entry_limit,
        "sparse_qr_max_input_nonzeros" => sparse_qr_max_input_nonzeros,
        "sparse_qr_max_factor_nonzeros" => sparse_qr_max_factor_nonzeros,
        "resume" => resume,
        "force" => force,
        "environment" => environment,
        "environment_fingerprint" => environment_fingerprint,
        "cases" => index,
    ))
    println("wrote evidence records to $output_dir")
end

main()
