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

Set `NLPDIAGNOSTICS_BMOPF_CAPTURE_POINTS=true` to retain primal callback
vectors and serialize current-law probes. `NLPDIAGNOSTICS_BMOPF_TRACE_PROBE_MAX_POINTS`
limits the selected iterate snapshots (zero means unlimited), while
`NLPDIAGNOSTICS_BMOPF_TRACE_PROBE_PHASE` optionally selects `regular`,
`restoration`, or `robust` callbacks.
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

const _RUNNER_VERSION = "bmopf-solver-trace-v8"
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

function _trace_probe_phase()
    raw = lowercase(strip(get(ENV, "NLPDIAGNOSTICS_BMOPF_TRACE_PROBE_PHASE", "")))
    isempty(raw) && return nothing
    raw in ("regular", "restoration", "robust") || error(
        "NLPDIAGNOSTICS_BMOPF_TRACE_PROBE_PHASE must be regular, restoration, robust, or empty",
    )
    return Symbol(raw)
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

"""Convert benchmark evidence to strict JSON without hiding non-finite values.

Diagnostic reports may legitimately contain NaN/Inf when a derivative or
solver callback failed. JSON cannot encode those values portably, so they are
serialized as `null`; the surrounding finding/status metadata remains intact
and the summarizers treat null as unavailable rather than finite evidence.
"""
function _json_safe(value)
    value isa AbstractFloat && !isfinite(value) && return nothing
    value isa AbstractDict && return Dict(
        string(key) => _json_safe(item) for (key, item) in value
    )
    value isa NamedTuple && return Dict(
        string(key) => _json_safe(getfield(value, key)) for key in keys(value)
    )
    value isa Tuple && return [_json_safe(item) for item in value]
    value isa AbstractArray && return [_json_safe(item) for item in value]
    return value
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

function _schema_warning_field(message)
    match_result = match(r"`([^`]+)`", String(message))
    isnothing(match_result) ? nothing : String(match_result.captures[1])
end

function _schema_warning_scope(message)
    token = split(String(message), ' '; limit = 2)[1]
    token = replace(token, ':' => "")
    isempty(token) ? nothing : token
end

function _schema_warning_impact(field)
    field = String(field)
    field == "units" && return "representational"
    field == "model" && return "device_semantics"
    field in ("angle", "basekv", "kv", "phases", "vmaxpu", "vminpu") &&
        return "physical_or_operating_point"
    return "unknown"
end

function _schema_warning_policy(field)
    field = String(field)
    field == "units" && return Dict{String,Any}(
        "status" => "intentionally_unsupported",
        "impact" => "representational",
        "physical_readiness_blocking" => false,
        "action" => "Retain source units as provenance; do not infer physical units from the BMOPF record.",
    )
    field == "model" && return Dict{String,Any}(
        "status" => "unsupported_device_semantics",
        "impact" => "device_semantics",
        "physical_readiness_blocking" => true,
        "action" => "Map the source device model into an explicit BMOPF component or plugin contract.",
    )
    field in ("angle", "basekv", "kv", "phases", "vmaxpu", "vminpu") &&
        return Dict{String,Any}(
            "status" => "unsupported_physical_metadata",
            "impact" => "physical_or_operating_point",
            "physical_readiness_blocking" => true,
            "action" => "Preserve and map this field before interpreting physical modes, limits, or operating-point evidence.",
        )
    return Dict{String,Any}(
        "status" => "unclassified_drop",
        "impact" => "unknown",
        "physical_readiness_blocking" => true,
        "action" => "Add an explicit source-to-BMOPF field policy before using the affected record.",
    )
end

function _integrity_preflight(network)
    findings = BMOPFTools.Finding[]
    summary = BMOPFTools.integrity_check(network, findings)
    metadata = network isa AbstractDict ? get(network, "_meta", Dict()) : Dict()
    raw_warnings = metadata isa AbstractDict ?
        get(metadata, "powerio_warnings", Any[]) : Any[]
    raw_warnings isa AbstractVector || (raw_warnings = Any[raw_warnings])
    warning_messages = String[String(value) for value in raw_warnings]
    warning_fields = String[field for message in warning_messages for field in
        (_schema_warning_field(message),) if !isnothing(field)]
    warning_scopes = String[scope for message in warning_messages for scope in
        (_schema_warning_scope(message),) if !isnothing(scope)]
    warning_impacts = String[_schema_warning_impact(field) for field in warning_fields]
    warning_policies = Dict{String,Any}[_schema_warning_policy(field) for field in warning_fields]
    physical_warning_count = count(get(policy, "physical_readiness_blocking", true)
                                   for policy in warning_policies)
    field_policies = Dict{String,Any}()
    for (field, policy) in zip(warning_fields, warning_policies)
        field_policies[field] = policy
    end
    return Dict{String,Any}(
        "error_count" => count(f -> f.severity == BMOPFTools.ERROR, findings),
        "warning_count" => count(f -> f.severity == BMOPFTools.WARNING, findings),
        "finding_count" => length(findings),
        "blocking" => any(f -> f.severity == BMOPFTools.ERROR, findings),
        "source_schema_warning_count" => length(warning_messages),
        "source_schema_warnings" => warning_messages,
        "source_schema_warning_fields" => warning_fields,
        "source_schema_warning_scopes" => warning_scopes,
        "source_schema_warning_impacts" => warning_impacts,
        "source_schema_warning_policies" => warning_policies,
        "source_schema_field_policies" => field_policies,
        "physical_metadata_warning_count" => physical_warning_count,
        "summary" => summary,
        "findings" => [Dict(
            "severity" => string(f.severity), "code" => f.code,
            "section" => string(f.section), "component_type" => string(f.component_type),
            "component_id" => f.component_id, "message" => f.message,
            "detail" => f.detail,
        ) for f in findings],
    )
end

"""Preserve the exact input deck used by a solver-trace case."""
function _preserve_source_snapshot(
    path::AbstractString,
    output_dir::AbstractString,
    name::AbstractString,
)
    source_dir = joinpath(output_dir, "source")
    mkpath(source_dir)
    target = joinpath(source_dir, "$(name)-$(basename(path))")
    cp(path, target; force = true)
    bytes = read(target)
    return Dict{String,Any}(
        "preserved" => true,
        "source_path" => abspath(path),
        "copy_path" => relpath(target, output_dir),
        "sha256" => bytes2hex(SHA.sha256(bytes)),
        "size_bytes" => length(bytes),
        "line_count" => count(==(UInt8('\n')), bytes) +
                        (isempty(bytes) || last(bytes) == UInt8('\n') ? 0 : 1),
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

function _perturbation_families()
    enabled = _env_flag("NLPDIAGNOSTICS_BMOPF_RUN_FAMILY_PERTURBATIONS")
    enabled || return Symbol[]
    raw = filter(!isempty, strip.(split(
        get(ENV, "NLPDIAGNOSTICS_BMOPF_PERTURBATION_FAMILIES",
            "load,generator,ibr,shunt,capacitor,grounding"), ',';
    )))
    families = Symbol.(lowercase.(raw))
    isempty(families) && error(
        "NLPDIAGNOSTICS_BMOPF_PERTURBATION_FAMILIES must not be empty when family perturbations are enabled",
    )
    return unique(families)
end

function _family_omission_build_spec(family::Symbol)
    builder = BMOPFTools.OpfDeviceBuilder(
        :nlpdiagnostics_family_perturbation,
        (context, ids) -> nothing,
    )
    return BMOPFTools.OpfBuildSpec(
        family_builders = Dict(family => builder),
    )
end

function _family_perturbation_record(
    network, family::Symbol, solver_name, per_unit, solver_options,
    capture_points, max_variables, dense_entry_limit, perturbation_max_iter,
)
    started = time()
    try
        build_timing = @timed BMOPFTools.build_opf_model(network;
            optimizer = _solver_optimizer(solver_name), add_objective = true,
            per_unit = per_unit,
            build_spec = _family_omission_build_spec(family),
        )
        context = build_timing.value
        kcl_timing = @timed BMOPFTools.enforce_kcl!(context)
        model = BMOPFTools.opf_model(context)
        perturbation_options = copy(solver_options)
        haskey(perturbation_options, "max_iter") ||
            (perturbation_options["max_iter"] = perturbation_max_iter)
        _apply_solver_options(model, perturbation_options)
        backend = JuMP.backend(model)
        variable_count = length(MOI.get(backend, MOI.ListOfVariableIndices()))
        if variable_count > max_variables
            return Dict{String,Any}(
                "status" => "skipped_solver_size_guard",
                "family" => string(family),
                "perturbation_mode" => "replace_native_family_builder_with_noop",
                "perturbation_scope" => "all_components_in_family",
                "model_variable_count" => variable_count,
                "max_solver_variables" => max_variables,
                "build_seconds" => build_timing.time,
                "kcl_seconds" => kcl_timing.time,
                "wall_seconds" => time() - started,
            )
        end
        run = _solve_with_trace(model, solver_name; capture_points)
        record = Dict{String,Any}(
            "status" => "ok",
            "family" => string(family),
            "perturbation_mode" => "replace_native_family_builder_with_noop",
            "perturbation_scope" => "all_components_in_family",
            "kcl_rebuilt_after_perturbation" => true,
            "model_variable_count" => variable_count,
            "build_seconds" => build_timing.time,
            "build_allocations" => build_timing.bytes,
            "kcl_seconds" => kcl_timing.time,
            "kcl_allocations" => kcl_timing.bytes,
            "wall_seconds" => time() - started,
            "solver_options" => perturbation_options,
            "iteration_trace" => NLPDiagnostics.iteration_trace_data(run.trace),
            "solver_profile" => NLPDiagnostics.profile_result_data(run),
        )
        if !isnothing(run.result.case)
            bmopf = NLPDiagnostics.bmopf_profile_case(context, run.result.case;
                include_initialization = false,
                rank_max_dense_entries = dense_entry_limit,
                jacobian_rank_tolerance_sweep_max_dense_entries = dense_entry_limit,
            )
            record["bmopf_profile"] = NLPDiagnostics.profile_result_data(bmopf)
            evaluation = run.result.profile.evaluation
            record["bmopf_constraint_semantic_rows"] =
                NLPDiagnostics.bmopf_constraint_semantic_row_map(context, evaluation)
            record["bmopf_row_family_perturbation_report"] =
                NLPDiagnostics.report_data(
                    NLPDiagnostics.bmopf_analyze_jacobian_row_family_perturbations(
                        context, evaluation; max_dense_entries = dense_entry_limit,
                    ),
                )
        else
            record["bmopf_profile"] = nothing
        end
        return record
    catch error
        return Dict{String,Any}(
            "status" => "error",
            "family" => string(family),
            "perturbation_mode" => "replace_native_family_builder_with_noop",
            "perturbation_scope" => "all_components_in_family",
            "wall_seconds" => time() - started,
            "error" => sprint(showerror, error, catch_backtrace()),
        )
    end
end

function _truncate_log(text, limit = 100_000)
    length(text) <= limit && return text
    return text[1:limit] * "\n...[truncated]..."
end

function _configure_solver_log!(model, solver_name, path)
    _env_flag("NLPDIAGNOSTICS_BMOPF_CAPTURE_LOGS") || return nothing
    mkpath(dirname(path))
    try
        JuMP.set_optimizer_attribute(model, "output_file", path)
        if solver_name == "ipopt"
            JuMP.set_optimizer_attribute(model, "file_print_level", 5)
        else
            JuMP.set_optimizer_attribute(model, "file_print_level", MadNLP.INFO)
        end
        return nothing
    catch error
        return sprint(showerror, error)
    end
end

function _solver_log_evidence(solver_name, path)
    isfile(path) || return nothing
    text = read(path, String)
    isempty(strip(text)) && return nothing
    return Dict{String,Any}(
        "path" => path,
        "source" => "solver_output_file",
        "text" => _truncate_log(text),
        "raw" => NLPDiagnostics.report_data(
            NLPDiagnostics.analyze_solver_log(solver_name, text),
        ),
        "iterations" => NLPDiagnostics.report_data(
            NLPDiagnostics.analyze_solver_iterations(solver_name, text),
        ),
    )
end

function _case_record(root, relative, solver_name, output_dir, max_variables,
                      capture_points, dense_entry_limit, environment_fingerprint,
                      solver_options, per_unit, perturbation_max_iter)
    path = joinpath(root, relative)
    name = replace(replace(relative, '/' => "__"), ".bmopf.json" => "")
    result_path = joinpath(output_dir, "$name.json")
    solver_log_path = joinpath(output_dir, "$name.log")
    capture_logs = _env_flag("NLPDIAGNOSTICS_BMOPF_CAPTURE_LOGS")
    sweep_label = get(ENV, "NLPDIAGNOSTICS_BMOPF_SWEEP_LABEL", "")
    run_id = get(ENV, "NLPDIAGNOSTICS_BMOPF_RUN_ID", "default")
    replicate_index = get(ENV, "NLPDIAGNOSTICS_BMOPF_REPLICATE_INDEX", "1")
    preflight = nothing
    source_snapshot = Dict{String,Any}(
        "preserved" => false, "source_path" => abspath(path),
    )
    log_configuration_error = nothing
    try
        source_snapshot = _preserve_source_snapshot(path, output_dir, name)
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
        log_configuration_error = _configure_solver_log!(
            model, solver_name, solver_log_path,
        )
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
                "capture_points" => capture_points,
                "capture_logs" => capture_logs,
                "sweep_label" => sweep_label,
                "run_id" => run_id,
                "replicate_index" => replicate_index,
                "capture_logs" => capture_logs,
                "integrity_preflight" => preflight,
                "source_snapshot" => source_snapshot,
                "solver_log_path" => solver_log_path,
                "solver_log_configuration_error" => log_configuration_error,
            )
            write(result_path, JSON.json(_json_safe(payload)))
            return Dict{String,Any}("name" => name, "snapshot" => relative,
                "status" => payload["status"], "result_file" => basename(result_path),
                "model_variable_count" => variable_count,
                "source_snapshot" => source_snapshot)
        end
        run = _solve_with_trace(model, solver_name; capture_points)
        trace_probe_max_points = _env_int(
            "NLPDIAGNOSTICS_BMOPF_TRACE_PROBE_MAX_POINTS", 32,
        )
        trace_probe_max_points == 0 && (trace_probe_max_points = nothing)
        current_law_trace_data = if capture_points || solver_name == "madnlp"
            current_law_trace = NLPDiagnostics.bmopf_current_law_operating_point_trace(
                context, run.trace;
                phase = _trace_probe_phase(), max_points = trace_probe_max_points,
            )
            serialized_trace = NLPDiagnostics.current_law_operating_point_trace_data(current_law_trace)
            if capture_points && !isempty(current_law_trace.bindings)
                controller_curve_snapshots = Any[]
                for binding in current_law_trace.bindings
                    point = binding.point
                    observations = NLPDiagnostics.bmopf_controller_curve_operating_point_observations(
                        context, point; result_units = :model,
                    )
                    push!(controller_curve_snapshots, Dict{String,Any}(
                        "iteration" => binding.record.iteration,
                        "phase" => string(binding.record.phase),
                        "segment" => binding.segment,
                        "label" => binding.point.label,
                        "observation_count" => length(observations),
                        "observations" => NLPDiagnostics.controller_curve_operating_point_observation_data(observations),
                    ))
                end
                serialized_trace["controller_curve_snapshots"] = controller_curve_snapshots
            end
            serialized_trace
        else
            nothing
        end
        solver_log_evidence = capture_logs ?
            _solver_log_evidence(solver_name, solver_log_path) : nothing
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
            serialized = NLPDiagnostics.profile_result_data(bmopf)
            serialized["bmopf_constraint_semantic_rows"] =
                NLPDiagnostics.bmopf_constraint_semantic_row_map(
                    context, run.result.profile.evaluation,
                )
            serialized["bmopf_constraint_registry_coverage"] =
                NLPDiagnostics.report_data(
                    NLPDiagnostics.bmopf_constraint_registry_coverage_report(
                        context, run.result.profile.evaluation,
                    ),
                )
            serialized["bmopf_row_family_perturbation_report"] =
                NLPDiagnostics.report_data(
                    NLPDiagnostics.bmopf_analyze_jacobian_row_family_perturbations(
                        context, run.result.profile.evaluation;
                        max_dense_entries = dense_entry_limit,
                    ),
                )
            serialized
        end
        perturbation_families = _perturbation_families()
        family_perturbations = isempty(perturbation_families) ?
            Dict{String,Any}[] : [
                _family_perturbation_record(
                    network, family, solver_name, per_unit, solver_options,
                    capture_points, max_variables, dense_entry_limit,
                    perturbation_max_iter,
                ) for family in perturbation_families
            ]
        payload = Dict{String,Any}(
            "status" => "ok", "snapshot" => relative,
            "snapshot_path" => abspath(path), "solver" => solver_name,
            "environment_fingerprint" => environment_fingerprint,
            "solver_options" => solver_options,
            "per_unit" => per_unit,
            "capture_points" => capture_points,
            "capture_logs" => capture_logs,
            "sweep_label" => sweep_label,
            "run_id" => run_id,
            "replicate_index" => replicate_index,
            "model_coordinate_units" => per_unit ? "per-unit" : "SI/model-native",
            "solver_objective_convention" => solver_name == "madnlp" ?
                "unscaled model objective via MadNLP.unpack_obj" :
                "Ipopt callback objective in model units",
            "objective_comparison_reference" => "recomputed MOI model objective",
            "bmopf_extracted_result_convention" => "BMOPFTools public result units (typically SI)",
            "capture_points" => capture_points,
            "capture_logs" => capture_logs,
            "model_variable_count" => variable_count,
            "run_id" => run_id, "replicate_index" => replicate_index,
            "build_seconds" => build_timing.time,
            "build_allocations" => build_timing.bytes,
            "kcl_seconds" => kcl_timing.time,
            "kcl_allocations" => kcl_timing.bytes,
            "integrity_preflight" => preflight,
            "source_snapshot" => source_snapshot,
            "iteration_trace" => trace_data,
            "current_law_trace" => current_law_trace_data,
            "solver_profile" => solver_data,
            "bmopf_profile" => bmopf_data,
            "family_perturbations" => family_perturbations,
            "family_perturbations_enabled" => !isempty(perturbation_families),
            "family_perturbation_families" => string.(perturbation_families),
            "family_perturbation_max_iter" => perturbation_max_iter,
            "solver_result_constraint_row_count" => isnothing(run.result.profile) ?
                nothing : length(run.result.profile.evaluation.constraint_sources),
            "solver_log_evidence" => solver_log_evidence,
            "solver_log_path" => solver_log_path,
            "solver_log_configuration_error" => log_configuration_error,
        )
        write(result_path, JSON.json(_json_safe(payload)))
        return Dict{String,Any}(
            "name" => name, "snapshot" => relative, "status" => "ok",
            "result_file" => basename(result_path), "solver" => solver_name,
            "model_variable_count" => variable_count,
            "iteration_count" => length(run.trace.records),
            "build_seconds" => build_timing.time, "kcl_seconds" => kcl_timing.time,
            "solver_log_available" => !isnothing(solver_log_evidence),
            "source_snapshot" => source_snapshot,
        )
    catch error
        message = sprint(showerror, error, catch_backtrace())
        payload = Dict{String,Any}(
            "status" => "error", "snapshot" => relative,
            "snapshot_path" => abspath(path), "solver" => solver_name,
            "environment_fingerprint" => environment_fingerprint,
            "solver_options" => solver_options,
            "per_unit" => per_unit,
            "capture_points" => capture_points,
            "sweep_label" => sweep_label,
            "run_id" => run_id,
            "replicate_index" => replicate_index,
            "capture_logs" => capture_logs,
            "error" => message, "integrity_preflight" => preflight,
            "source_snapshot" => source_snapshot,
            "solver_log_evidence" => capture_logs ?
                _solver_log_evidence(solver_name, solver_log_path) : nothing,
            "solver_log_path" => solver_log_path,
            "solver_log_configuration_error" => log_configuration_error,
        )
        write(result_path, JSON.json(_json_safe(payload)))
        return Dict{String,Any}(
            "name" => name, "snapshot" => relative, "status" => "error",
            "result_file" => basename(result_path), "error" => message,
            "source_snapshot" => source_snapshot,
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
    perturbation_max_iter = _env_int(
        "NLPDIAGNOSTICS_BMOPF_PERTURBATION_MAX_ITER", 100,
    )
    capture_points = _env_flag("NLPDIAGNOSTICS_BMOPF_CAPTURE_POINTS")
    per_unit = _env_flag("NLPDIAGNOSTICS_BMOPF_PER_UNIT"; default = true)
    perturbation_families = _perturbation_families()
    solver_options = _solver_options()
    environment = _benchmark_environment()
    environment_fingerprint = _benchmark_environment_fingerprint(environment)
    sweep_label = get(ENV, "NLPDIAGNOSTICS_BMOPF_SWEEP_LABEL", "")
    run_id = get(ENV, "NLPDIAGNOSTICS_BMOPF_RUN_ID", "default")
    replicate_index = get(ENV, "NLPDIAGNOSTICS_BMOPF_REPLICATE_INDEX", "1")
    cases = _selected_cases(root)
    index = Dict{String,Any}[]
    for relative in cases
        entry = _case_record(root, relative, solver_name, output_dir,
            max_variables, capture_points, dense_entry_limit,
            environment_fingerprint, solver_options, per_unit,
            perturbation_max_iter)
        entry["environment_fingerprint"] = environment_fingerprint
        entry["solver_options"] = solver_options
        entry["per_unit"] = per_unit
        entry["family_perturbations_enabled"] = !isempty(perturbation_families)
        entry["family_perturbation_families"] = string.(perturbation_families)
        entry["sweep_label"] = sweep_label
        entry["run_id"] = run_id
        entry["replicate_index"] = replicate_index
        push!(index, entry)
        println("$(entry["name"]): $(entry["status"]) solver=$solver_name " *
            "iterations=$(get(entry, "iteration_count", "n/a"))")
    end
    write(joinpath(output_dir, "index.json"), JSON.json(Dict(
        "runner_version" => _RUNNER_VERSION,
        "benchmark_root" => abspath(root), "solver" => solver_name,
        "capture_points" => capture_points,
        "trace_probe_max_points" => get(ENV, "NLPDIAGNOSTICS_BMOPF_TRACE_PROBE_MAX_POINTS", "32"),
        "trace_probe_phase" => get(ENV, "NLPDIAGNOSTICS_BMOPF_TRACE_PROBE_PHASE", ""),
        "capture_logs" => _env_flag("NLPDIAGNOSTICS_BMOPF_CAPTURE_LOGS"),
        "solver_options" => solver_options,
        "per_unit" => per_unit,
        "family_perturbations_enabled" => !isempty(perturbation_families),
        "family_perturbation_families" => string.(perturbation_families),
        "family_perturbation_max_iter" => perturbation_max_iter,
        "max_solver_variables" => max_variables,
        "rank_max_dense_entries" => dense_entry_limit,
        "environment" => environment,
        "environment_fingerprint" => environment_fingerprint,
        "sweep_label" => sweep_label,
        "run_id" => run_id,
        "replicate_index" => replicate_index,
        "cases" => index,
    )))
    println("wrote solver-trace evidence to $output_dir")
end

main()
