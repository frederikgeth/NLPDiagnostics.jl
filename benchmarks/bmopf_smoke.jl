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
using LinearAlgebra
using SHA

include(joinpath(@__DIR__, "benchmark_environment.jl"))

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
        name = "zip-load",
        file = "pf_zip_3ph.dss",
        description = "Three-phase ZIP load with explicit voltage-dependent load coefficients.",
        tags = [:smoke, :zip, :multiconductor, :load_model],
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

function _optional_positive_integer(name::AbstractString; default = 0)
    raw = get(ENV, name, string(default))
    value = try
        parse(Int, raw)
    catch
        error("$name must be a nonnegative integer, got '$raw'")
    end
    value >= 0 || error("$name must be nonnegative, got '$raw'")
    return iszero(value) ? nothing : value
end

function _expected_mode_free_coordinate_policy()
    raw = lowercase(strip(get(
        ENV,
        "NLPDIAGNOSTICS_BMOPF_EXPECTED_MODE_FREE_COORDINATE_POLICY",
        "project_free",
    )))
    raw in ("strict", "project_free", "project") || error(
        "NLPDIAGNOSTICS_BMOPF_EXPECTED_MODE_FREE_COORDINATE_POLICY must be strict or project_free",
    )
    return raw == "strict" ? :strict : :project_free
end

function _expected_mode_tangent_policy(context)
    raw = lowercase(strip(get(
        ENV,
        "NLPDIAGNOSTICS_BMOPF_EXPECTED_MODE_TANGENT_POLICY",
        "fixed",
    )))
    raw in ("none", "fixed") || error(
        "NLPDIAGNOSTICS_BMOPF_EXPECTED_MODE_TANGENT_POLICY must be none or fixed",
    )
    raw == "none" && return nothing
    return NLPDiagnostics.bmopf_expected_mode_tangent_policy(context)
end

_as_dict(value) = value isa AbstractDict ?
    Dict{String,Any}(String(k) => v for (k, v) in value) : Dict{String,Any}()

function _source_behavior_auxiliary_data(auxiliary)
    return Dict{String,Any}(
        "status" => get(auxiliary, "status", "unknown"),
        "variable_count" => get(auxiliary, "variable_count", 0),
        "constraint_pair_count" => get(auxiliary, "constraint_pair_count", 0),
        "original_model_variable_count" => get(auxiliary,
            "original_model_variable_count", 0),
        "original_model_mutated" => get(auxiliary, "original_model_mutated", true),
        "records" => [Dict{String,Any}(String(k) => v for (k, v) in record)
                      for record in get(auxiliary, "records", Any[])
                      if record isa AbstractDict],
    )
end

function _source_behavior_solver_policy()
    raw = lowercase(strip(get(
        ENV, "NLPDIAGNOSTICS_BMOPF_SOURCE_BEHAVIOR_SOLVER", "none",
    )))
    raw in ("none", "ipopt") || error(
        "NLPDIAGNOSTICS_BMOPF_SOURCE_BEHAVIOR_SOLVER must be none or ipopt",
    )
    return raw
end

function _source_behavior_solver_attributes()
    attributes = Dict{String,Any}(
        "max_iter" => _optional_positive_integer(
            "NLPDIAGNOSTICS_BMOPF_SOURCE_BEHAVIOR_MAX_ITER"; default = 100,
        ),
    )
    filter!(pair -> !isnothing(pair.second), attributes)
    raw_tol = strip(get(ENV, "NLPDIAGNOSTICS_BMOPF_SOURCE_BEHAVIOR_TOL", ""))
    if !isempty(raw_tol)
        tol = try parse(Float64, raw_tol) catch
            error("NLPDIAGNOSTICS_BMOPF_SOURCE_BEHAVIOR_TOL must be a finite number")
        end
        isfinite(tol) && tol > 0.0 || error(
            "NLPDIAGNOSTICS_BMOPF_SOURCE_BEHAVIOR_TOL must be positive and finite",
        )
        attributes["tol"] = tol
    end
    return attributes
end

function _source_behavior_auxiliary_solve_data(auxiliary, solver_policy, attributes)
    original_model = get(auxiliary, "original_model", nothing)
    original_count_before = get(auxiliary, "original_model_variable_count", nothing)
    original_count_after = original_model isa JuMP.Model ?
        JuMP.num_variables(original_model) : nothing
    solver_policy == "none" && return Dict{String,Any}(
        "status" => "not_requested",
        "solver" => "none",
        "feasible" => false,
        "result_count" => 0,
        "optimizer_attributes" => attributes,
        "original_model_variable_count_before" => original_count_before,
        "original_model_variable_count_after" => original_count_after,
        "original_model_mutated" => original_count_before != original_count_after,
    )
    optimizer = solver_policy == "ipopt" ? Ipopt.Optimizer : nothing
    solve = NLPDiagnostics.bmopf_source_behavior_auxiliary_solve(
        auxiliary; optimizer, optimizer_attributes = attributes,
    )
    data = Dict{String,Any}(String(key) => value for (key, value) in solve)
    data["solver"] = solver_policy
    data["optimizer_attributes"] = attributes
    data["original_model_variable_count_before"] = original_count_before
    data["original_model_variable_count_after"] = original_count_after
    data["original_model_mutated"] = original_count_before != original_count_after
    return data
end

function _source_behavior_report_data(result)
    report = get(result, :report, nothing)
    rows = get(result, :rows, Any[])
    solve = get(result, :solve, Dict{String,Any}())
    report isa NLPDiagnostics.DiagnosticReport || return Dict{String,Any}(
        "status" => "unavailable",
        "reason" => "source_behavior_report_not_materialized",
    )
    return Dict{String,Any}(
        "status" => "available",
        "finding_count" => length(report.findings),
        "finding_codes" => string.(getfield.(report.findings, :code)),
        "metadata" => Dict{String,Any}(string(key) => string(value)
                                        for (key, value) in report.metadata),
        "rows" => [Dict{String,Any}(String(key) => value for (key, value) in row)
                   for row in rows if row isa AbstractDict],
        "auxiliary_solve_status" => string(get(solve, "status", "unknown")),
    )
end

function _physical_mode_projection_matches(analysis_data, projection_data)
    projections = _as_dict(projection_data)
    projection_rows = [_as_dict(row) for row in get(projections, "rows", Any[])]
    by_expected_name = Dict{String,Dict{String,Any}}(
        String(get(row, "expected_mode_name", "")) => row for row in projection_rows
        if !isempty(String(get(row, "expected_mode_name", "")))
    )
    rows = Dict{String,Any}[]
    for raw_finding in get(_as_dict(analysis_data), "findings", Any[])
        finding = _as_dict(raw_finding)
        code = String(get(finding, "code", ""))
        code in ("expected_nullspace_mode_observed", "expected_nullspace_mode_not_observed",
                 "expected_nullspace_mode_unaligned", "expected_nullspace_mode_partial_alignment",
                 "expected_nullspace_mode_free_projection_observed",
                 "expected_nullspace_mode_free_projection_not_observed",
                 "expected_nullspace_mode_tangent_observed",
                 "expected_nullspace_mode_tangent_not_observed") || continue
        evidence = get(finding, "evidence", Any[])
        evidence isa AbstractVector && !isempty(evidence) || continue
        details = _as_dict(get(_as_dict(first(evidence)), "details", nothing))
        mode_name = String(get(details, "mode", ""))
        isempty(mode_name) && continue
        projection = get(by_expected_name, mode_name, Dict{String,Any}())
        match_status = code == "expected_nullspace_mode_observed" ? "observed" :
            code == "expected_nullspace_mode_not_observed" ? "not_observed" :
            code == "expected_nullspace_mode_free_projection_observed" ? "projected_observed" :
            code == "expected_nullspace_mode_free_projection_not_observed" ? "projected_not_observed" :
            code == "expected_nullspace_mode_tangent_observed" ? "tangent_observed" :
            code == "expected_nullspace_mode_tangent_not_observed" ? "tangent_not_observed" :
            code == "expected_nullspace_mode_partial_alignment" ? "partial_alignment" :
            "outside_free_coordinates"
        push!(rows, Dict{String,Any}(
            "expected_mode_name" => mode_name,
            "component_type" => get(projection, "component_type", nothing),
            "component_id" => get(projection, "component_id", nothing),
            "port_id" => get(projection, "port_id", nothing),
            "mode_name" => get(projection, "mode_name", nothing),
            "projection_status" => get(projection, "status", "unrepresented"),
            "jacobian_match_status" => match_status,
            "aligned_variable_count" => get(details, "aligned_variable_count", nothing),
            "unaligned_variable_count" => get(details, "unaligned_variable_count", nothing),
            "aligned_coefficient_fraction" => get(details, "aligned_coefficient_fraction", nothing),
            "projection_policy" => get(details, "projection_policy", "strict"),
            "missing_variable_indices" => get(details, "missing_variable_indices", ""),
            "nonfree_variable_indices" => get(details, "nonfree_variable_indices", ""),
            "projection_residual" => get(details, "projection_residual", nothing),
            "tolerance" => get(details, "tolerance", nothing),
            "model_variable_indices" => get(projection, "model_variable_indices", Any[]),
        ))
    end
    status_counts = Dict{String,Int}()
    for row in rows
        status = String(row["jacobian_match_status"])
        status_counts[status] = get(status_counts, status, 0) + 1
    end
    Dict{String,Any}(
        "mode_count" => length(rows),
        "rows" => rows,
        "status_counts" => status_counts,
        "observed_count" => get(status_counts, "observed", 0),
        "not_observed_count" => get(status_counts, "not_observed", 0),
        "outside_free_coordinates_count" => get(status_counts, "outside_free_coordinates", 0),
        "partial_alignment_count" => get(status_counts, "partial_alignment", 0),
        "projected_observed_count" => get(status_counts, "projected_observed", 0),
        "projected_not_observed_count" => get(status_counts, "projected_not_observed", 0),
        "tangent_observed_count" => get(status_counts, "tangent_observed", 0),
        "tangent_not_observed_count" => get(status_counts, "tangent_not_observed", 0),
    )
end

function _bmopf_integrity_preflight(network)
    findings = BMOPFTools.Finding[]
    result = BMOPFTools.integrity_check(network, findings)
    metadata = network isa AbstractDict ? get(network, "_meta", Dict()) : Dict()
    source_warnings = metadata isa AbstractDict ? get(metadata, "powerio_warnings", Any[]) : Any[]
    source_warnings isa AbstractVector || (source_warnings = Any[source_warnings])
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
        "source_schema_warning_count" => length(source_warnings),
        "source_schema_warnings" => source_warnings,
        "summary" => result,
    )
end

function _preserve_source_fixture(path::AbstractString, output_dir::AbstractString, name::AbstractString)
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
        "line_count" => count(==(UInt8('\n')), bytes) + (isempty(bytes) || last(bytes) == UInt8('\n') ? 0 : 1),
    )
end

function _multiconductor_contract_data(context; operating_source = nothing)
    voltage_ports = NLPDiagnostics.bmopf_terminal_port_metadata(context)
    voltage_maps = NLPDiagnostics.bmopf_terminal_port_coordinate_maps(context)
    voltage_connections = NLPDiagnostics.bmopf_terminal_port_connections(context)
    voltage_report = NLPDiagnostics.bmopf_terminal_port_report(context)
    port_assembly = NLPDiagnostics.bmopf_terminal_port_assembly(context)
    port_assembly_report = NLPDiagnostics.bmopf_terminal_port_assembly_report(context)
    current_laws = NLPDiagnostics.bmopf_current_law_fingerprints(context)
    current_law_report = NLPDiagnostics.bmopf_current_law_report(context)
    operating_probes = isnothing(operating_source) ?
        NLPDiagnostics.CurrentLawOperatingPointProbe[] :
        NLPDiagnostics.bmopf_current_law_operating_point_probes(context, operating_source;
            result_units = :model,
        )
    operating_report = isnothing(operating_source) ?
        NLPDiagnostics.DiagnosticReport() :
        NLPDiagnostics.bmopf_current_law_operating_point_report(context, operating_source;
            result_units = :model,
        )
    controller_curve_observations = isnothing(operating_source) ?
        NLPDiagnostics.ControllerCurveOperatingPointObservation[] :
        NLPDiagnostics.bmopf_controller_curve_operating_point_observations(
            context, operating_source; result_units = :model,
        )
    controller_curve_families = String[]
    controller_curve_statuses = String[]
    controller_curve_semantics = String[]
    controller_curve_breakpoint_proximity_count = 0
    controller_curve_invalid_profile_count = 0
    controller_curve_exact_monitor_count = 0
    controller_curve_proxy_monitor_count = 0
    controller_curve_equation_residual_count = 0
    controller_curve_cap_violation_count = 0
    for probe in operating_probes
        metadata = probe.metadata
        family = get(metadata, "controller_curve_family", nothing)
        family isa AbstractString && push!(controller_curve_families, String(family))
        status = get(metadata, "controller_curve_status", nothing)
        status isa AbstractString && begin
            push!(controller_curve_statuses, String(status))
            status == "breakpoint_proximity" && (controller_curve_breakpoint_proximity_count += 1)
            status == "invalid_profile" && (controller_curve_invalid_profile_count += 1)
        end
        semantics = get(metadata, "controller_curve_voltage_semantics", nothing)
        semantics isa AbstractString && begin
            push!(controller_curve_semantics, String(semantics))
            semantics == "exact_public_monitored_voltage" && (controller_curve_exact_monitor_count += 1)
            semantics == "terminal_pair_magnitude_proxy" && (controller_curve_proxy_monitor_count += 1)
        end
        for curve_family in ("volt_var", "volt_watt")
            prefix = "controller_curve_$(curve_family)_"
            secondary_status = get(metadata, "$(prefix)status", nothing)
            secondary_status isa AbstractString || continue
            push!(controller_curve_families, curve_family)
            push!(controller_curve_statuses, String(secondary_status))
            secondary_status == "breakpoint_proximity" && (controller_curve_breakpoint_proximity_count += 1)
            secondary_status == "invalid_profile" && (controller_curve_invalid_profile_count += 1)
            secondary_semantics = get(metadata, "$(prefix)voltage_semantics", nothing)
            secondary_semantics isa AbstractString || continue
            push!(controller_curve_semantics, String(secondary_semantics))
            secondary_semantics == "exact_public_monitored_voltage" && (controller_curve_exact_monitor_count += 1)
            secondary_semantics == "terminal_pair_magnitude_proxy" && (controller_curve_proxy_monitor_count += 1)
        end
        q_residual = try
            parse(Float64, get(metadata, "controller_curve_volt_var_equation_residual", "NaN"))
        catch
            NaN
        end
        isfinite(q_residual) && (controller_curve_equation_residual_count += 1)
        cap_violation = try
            parse(Float64, get(metadata, "controller_curve_volt_watt_cap_violation", "NaN"))
        catch
            NaN
        end
        isfinite(cap_violation) && cap_violation > 0.0 && (controller_curve_cap_violation_count += 1)
    end
    current_ports = NLPDiagnostics.bmopf_terminal_current_port_metadata(context)
    current_maps = NLPDiagnostics.bmopf_terminal_current_port_coordinate_maps(context)
    current_report = NLPDiagnostics.bmopf_terminal_current_port_report(context)
    physical_modes = NLPDiagnostics.bmopf_terminal_port_nullspace_modes(context)
    physical_mode_report = NLPDiagnostics.bmopf_terminal_port_nullspace_mode_report(context)
    constitutive_maps = NLPDiagnostics.bmopf_terminal_constitutive_maps(context)
    constitutive_report = NLPDiagnostics.bmopf_terminal_constitutive_map_report(context)
    complex_constitutive_maps = NLPDiagnostics.bmopf_terminal_complex_constitutive_maps(context)
    complex_constitutive_report = NLPDiagnostics.bmopf_terminal_complex_constitutive_map_report(context)
    passive_current_maps = NLPDiagnostics.bmopf_passive_network_current_maps(context)
    passive_current_report = NLPDiagnostics.bmopf_passive_network_current_map_report(context)
    passive_current_model_maps = NLPDiagnostics.bmopf_passive_network_current_maps(context; basis = :model)
    passive_current_model_report = NLPDiagnostics.bmopf_passive_network_current_map_report(context; basis = :model)
    function coordinate_alignment(ports, maps)
        map_by_key = Dict((map.component_type, map.component_id, map.port_id) => map for map in maps)
        rows = Dict{String,Any}[]
        for port in ports
            key = (port.component_type, port.component_id, port.port_id)
            map = get(map_by_key, key, nothing)
            expected_terminal_count = length(port.terminal_labels)
            if isnothing(map)
                push!(rows, Dict{String,Any}(
                    "component_type" => string(port.component_type),
                    "component_id" => port.component_id,
                    "port_id" => port.port_id,
                    "status" => "missing_map",
                    "expected_terminal_count" => expected_terminal_count,
                    "model_variable_count" => 0,
                ))
                continue
            end
            dimensions_ok = size(map.terminal_to_variable, 2) == expected_terminal_count &&
                            size(map.terminal_to_variable, 1) == length(map.variables)
            finite = all(isfinite, map.terminal_to_variable)
            status = !dimensions_ok ? "dimension_mismatch" : !finite ? "nonfinite" : "aligned"
            push!(rows, Dict{String,Any}(
                "component_type" => string(port.component_type),
                "component_id" => port.component_id,
                "port_id" => port.port_id,
                "status" => status,
                "expected_terminal_count" => expected_terminal_count,
                "model_variable_count" => length(map.variables),
                "map_row_count" => size(map.terminal_to_variable, 1),
                "map_column_count" => size(map.terminal_to_variable, 2),
                "map_rank" => dimensions_ok && finite ? LinearAlgebra.rank(map.terminal_to_variable) : 0,
            ))
        end
        status_counts = Dict{String,Int}()
        for row in rows
            status = String(row["status"])
            status_counts[status] = get(status_counts, status, 0) + 1
        end
        Dict{String,Any}(
            "port_count" => length(ports),
            "map_count" => length(maps),
            "rows" => rows,
            "status_counts" => status_counts,
            "aligned_port_count" => get(status_counts, "aligned", 0),
            "missing_map_count" => get(status_counts, "missing_map", 0),
            "dimension_mismatch_count" => get(status_counts, "dimension_mismatch", 0),
            "nonfinite_map_count" => get(status_counts, "nonfinite", 0),
        )
    end
    function physical_mode_projection_data(ports, modes, maps)
        port_by_key = Dict((port.component_type, port.component_id, port.port_id) => port for port in ports)
        map_by_key = Dict((map.component_type, map.component_id, map.port_id) => map for map in maps)
        rows = Dict{String,Any}[]
        for mode in modes
            key = (mode.component_type, mode.component_id, mode.port_id)
            port = get(port_by_key, key, nothing)
            map = get(map_by_key, key, nothing)
            status = "unrepresented"
            projected_norm = nothing
            support_count = 0
            variable_indices = Int[]
            reason = nothing
            if mode.space != :terminal
                reason = "mode_space_has_no_generic_terminal_projection"
            elseif isnothing(port) || isnothing(map)
                reason = "missing_port_or_coordinate_map"
            elseif length(mode.direction) != length(port.terminal_labels) ||
                   size(map.terminal_to_variable) !=
                   (length(map.variables), length(port.terminal_labels)) ||
                   !all(isfinite, map.terminal_to_variable)
                reason = "coordinate_map_dimension_or_finiteness_mismatch"
            else
                projected = map.terminal_to_variable * mode.direction
                projected_norm = norm(projected)
                threshold = sqrt(eps(Float64)) * max(1.0, norm(mode.direction))
                support = findall(value -> abs(value) > threshold, projected)
                support_count = length(support)
                variable_indices = [map.variables[index].value for index in support]
                status = projected_norm > threshold ? "visible" : "hidden"
                reason = status == "visible" ? "nonzero_model_coordinate_projection" :
                    "zero_model_coordinate_projection"
            end
            push!(rows, Dict{String,Any}(
                "component_type" => string(mode.component_type),
                "component_id" => mode.component_id,
                "port_id" => mode.port_id,
                "mode_name" => string(something(mode.name, :unnamed)),
                "expected_mode_name" => "component_port_candidate_mode_$(mode.component_type)_$(mode.component_id)_$(mode.port_id)_$(something(mode.name, :unnamed))",
                "space" => string(mode.space),
                "status" => status,
                "reason" => reason,
                "projected_norm" => projected_norm,
                "model_coordinate_support_count" => support_count,
                "model_variable_indices" => variable_indices,
            ))
        end
        status_counts = Dict{String,Int}()
        for row in rows
            status = String(row["status"])
            status_counts[status] = get(status_counts, status, 0) + 1
        end
        Dict{String,Any}(
            "mode_count" => length(rows),
            "rows" => rows,
            "status_counts" => status_counts,
            "visible_count" => get(status_counts, "visible", 0),
            "hidden_count" => get(status_counts, "hidden", 0),
            "unrepresented_count" => get(status_counts, "unrepresented", 0),
        )
    end
    voltage_alignment = coordinate_alignment(voltage_ports, voltage_maps)
    current_alignment = coordinate_alignment(current_ports, current_maps)
    physical_mode_projections = physical_mode_projection_data(
        voltage_ports, physical_modes, voltage_maps,
    )
    return Dict{String,Any}(
        "voltage_port_count" => length(voltage_ports),
        "voltage_coordinate_map_count" => length(voltage_maps),
        "voltage_coordinate_alignment" => voltage_alignment,
        "voltage_connection_count" => length(voltage_connections),
        "voltage_report_finding_count" => length(voltage_report.findings),
        "port_assembly_component_count" => port_assembly.component_count,
        "port_assembly_connected_component_count" => port_assembly.connected_component_count,
        "port_assembly_finding_count" => length(port_assembly_report.findings),
        "current_law_fingerprint_count" => length(current_laws),
        "current_law_finding_count" => length(current_law_report.findings),
        "current_law_families" => sort!(collect(Set(string(item.law_family) for item in current_laws))),
        "current_law_operating_point_probe_count" => length(operating_probes),
        "current_law_operating_point_finding_count" => length(operating_report.findings),
        "current_law_operating_point_statuses" => sort!(collect(Set(string(item.domain_status) for item in operating_probes))),
        "controller_curve_observation_count" => length(controller_curve_observations),
        "controller_curve_observations" => NLPDiagnostics.controller_curve_operating_point_observation_data(
            controller_curve_observations,
        ),
        "controller_curve_families" => sort!(collect(Set(controller_curve_families))),
        "controller_curve_statuses" => sort!(collect(Set(controller_curve_statuses))),
        "controller_curve_voltage_semantics" => sort!(collect(Set(controller_curve_semantics))),
        "controller_curve_breakpoint_proximity_count" => controller_curve_breakpoint_proximity_count,
        "controller_curve_invalid_profile_count" => controller_curve_invalid_profile_count,
        "controller_curve_exact_monitor_count" => controller_curve_exact_monitor_count,
        "controller_curve_proxy_monitor_count" => controller_curve_proxy_monitor_count,
        "controller_curve_equation_residual_count" => controller_curve_equation_residual_count,
        "controller_curve_cap_violation_count" => controller_curve_cap_violation_count,
        "current_port_count" => length(current_ports),
        "current_coordinate_map_count" => length(current_maps),
        "current_coordinate_alignment" => current_alignment,
        "current_report_finding_count" => length(current_report.findings),
        "current_skipped_count" => parse(Int, current_report.metadata[:bmopf_terminal_current_port_skipped_count]),
        "physical_mode_count" => length(physical_modes),
        "physical_mode_projections" => physical_mode_projections,
        "physical_mode_finding_count" => length(physical_mode_report.findings),
        "physical_mode_categories" => sort!(collect(Set(string(item.category) for item in
                                                         NLPDiagnostics.bmopf_terminal_port_nullspace_mode_semantics(context)))),
        "constitutive_map_count" => length(constitutive_maps),
        "constitutive_map_finding_count" => length(constitutive_report.findings),
        "constitutive_map_ranks" => [LinearAlgebra.rank(map.matrix) for map in constitutive_maps],
        "complex_constitutive_map_count" => length(complex_constitutive_maps),
        "complex_constitutive_map_finding_count" => length(complex_constitutive_report.findings),
        "complex_constitutive_map_ranks" => [LinearAlgebra.rank(map.matrix) for map in complex_constitutive_maps],
        "passive_network_current_map_count" => length(passive_current_maps),
        "passive_network_current_map_finding_count" => length(passive_current_report.findings),
        "passive_network_current_map_ranks" => [LinearAlgebra.rank(map.matrix) for map in passive_current_maps],
        "passive_network_current_model_map_count" => length(passive_current_model_maps),
        "passive_network_current_model_map_finding_count" => length(passive_current_model_report.findings),
        "passive_network_current_model_map_ranks" => [LinearAlgebra.rank(map.matrix) for map in passive_current_model_maps],
    )
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
    source_behavior_solver = _source_behavior_solver_policy()
    source_behavior_solver_attributes = _source_behavior_solver_attributes()
    dense_entry_limit = _dense_entry_limit()
    iterative_probe_dimension = _optional_positive_integer(
        "NLPDIAGNOSTICS_BMOPF_ITERATIVE_RIGHT_PROBE_DIMENSION",
    )
    iterative_probe_iterations = something(_optional_positive_integer(
        "NLPDIAGNOSTICS_BMOPF_ITERATIVE_RIGHT_PROBE_ITERATIONS";
        default = 50,
    ), 50)
    expected_mode_free_coordinate_policy = _expected_mode_free_coordinate_policy()
    environment = _benchmark_environment()
    environment_fingerprint = _benchmark_environment_fingerprint(environment)

    for spec in fixtures
        path = joinpath(root, spec.file)
        result_path = joinpath(output_dir, "$(spec.name).json")
        preflight = nothing
        source_snapshot = Dict{String,Any}("preserved" => false, "source_path" => abspath(path))
        try
            isfile(path) || error("fixture is missing: $path")
            source_snapshot = _preserve_source_fixture(path, output_dir, spec.name)
            network = BMOPFTools.from_dss(path)
            preflight = _bmopf_integrity_preflight(network)
            run = NLPDiagnostics.bmopf_build_and_profile(network,
                context -> _benchmark_case(spec, context, point_policy);
                build_kwargs = (add_objective = false,),
                profile_kwargs = (
                    include_initialization = true,
                    rank_max_dense_entries = dense_entry_limit,
                    jacobian_rank_tolerance_sweep_max_dense_entries = dense_entry_limit,
                    expected_mode_free_coordinate_policy =
                        expected_mode_free_coordinate_policy,
                    iterative_right_nullspace_probe_dimension = iterative_probe_dimension,
                    iterative_right_nullspace_probe_iterations = iterative_probe_iterations,
                ),
            )
            source_behavior_auxiliary_model =
                NLPDiagnostics.bmopf_source_behavior_auxiliary_model(run.context)
            source_behavior_auxiliary = _source_behavior_auxiliary_data(
                source_behavior_auxiliary_model,
            )
            source_behavior_auxiliary_solve = _source_behavior_auxiliary_solve_data(
                source_behavior_auxiliary_model,
                source_behavior_solver,
                source_behavior_solver_attributes,
            )
            data = NLPDiagnostics.profile_result_data(run.result)
            multiconductor_contract = _multiconductor_contract_data(
                run.context; operating_source = run.result.profile.evaluation.point,
            )
            evaluation = run.result.profile.evaluation
            source_behavior_report = _source_behavior_report_data(
                NLPDiagnostics.bmopf_source_behavior_report(
                    run.context, evaluation.point;
                    solve_auxiliary = false,
                ),
            )
            expected_mode_tangent_policy = _expected_mode_tangent_policy(run.context)
            variable_count = length(evaluation.point.variables)
            constraint_row_count = length(evaluation.constraint_sources)
            jacobian_entries = variable_count * constraint_row_count
            dense_analysis_allowed = dense_entry_limit > 0 &&
                                     jacobian_entries <= dense_entry_limit
            physical_mode_analysis = if dense_analysis_allowed
                NLPDiagnostics.bmopf_analyze_opf(
                    run.context;
                    point = evaluation.point,
                    include_port_physical_modes = true,
                    check_degeneracy = true,
                    expected_mode_free_coordinate_policy =
                        expected_mode_free_coordinate_policy,
                    expected_mode_tangent_policy = expected_mode_tangent_policy,
                    jacobian_rank_tolerance_sweep_tolerances = [sqrt(eps(Float64))],
                    jacobian_rank_tolerance_sweep_max_dense_entries = dense_entry_limit,
                )
            else
                NLPDiagnostics.bmopf_analyze_opf(
                    run.context;
                    include_port_physical_modes = true,
                )
            end
            physical_mode_analysis_data = NLPDiagnostics.report_data(
                physical_mode_analysis,
            )
            physical_mode_projection_matches = _physical_mode_projection_matches(
                physical_mode_analysis_data,
                get(multiconductor_contract, "physical_mode_projections", Dict{String,Any}()),
            )
            generic_findings = sum(length(report["findings"]) for
                report in values(data["profile"]["reports"]))
            context_findings = length(data["bmopf_context_report"]["findings"])
            payload = Dict{String,Any}(
                "fixture" => spec.file,
                "fixture_path" => abspath(path),
                "source_snapshot" => source_snapshot,
                "integrity_preflight" => preflight,
                "tags" => string.(spec.tags),
                "environment_fingerprint" => environment_fingerprint,
                "point_policy" => point_policy,
                "source_behavior_solver" => source_behavior_solver,
                "source_behavior_solver_attributes" => source_behavior_solver_attributes,
                "model_variable_count" => variable_count,
                "scalar_constraint_row_count" => constraint_row_count,
                "jacobian_dense_entry_count" => jacobian_entries,
                "rank_max_dense_entries" => dense_entry_limit,
                "iterative_right_nullspace_probe_dimension" => iterative_probe_dimension,
                "iterative_right_nullspace_probe_iterations" => iterative_probe_iterations,
                "expected_mode_free_coordinate_policy" =>
                    expected_mode_free_coordinate_policy,
                "expected_mode_tangent_policy" => isnothing(expected_mode_tangent_policy) ?
                    "none" : string(expected_mode_tangent_policy.name),
                "dense_rank_analysis_eligible" => jacobian_entries <= dense_entry_limit,
                "multiconductor_contract" => multiconductor_contract,
                "source_behavior_auxiliary" => source_behavior_auxiliary,
                "source_behavior_auxiliary_solve" => source_behavior_auxiliary_solve,
                "source_behavior_report" => source_behavior_report,
                "physical_mode_analysis" => physical_mode_analysis_data,
                "physical_mode_projection_matches" => physical_mode_projection_matches,
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
                "source_snapshot" => source_snapshot,
                "point_policy" => point_policy,
                "source_behavior_solver" => source_behavior_solver,
                "source_behavior_solver_attributes" => source_behavior_solver_attributes,
                "model_variable_count" => variable_count,
                "scalar_constraint_row_count" => constraint_row_count,
                "jacobian_dense_entry_count" => jacobian_entries,
                "rank_max_dense_entries" => dense_entry_limit,
                "iterative_right_nullspace_probe_dimension" => iterative_probe_dimension,
                "iterative_right_nullspace_probe_iterations" => iterative_probe_iterations,
                "expected_mode_tangent_policy" => isnothing(expected_mode_tangent_policy) ?
                    "none" : string(expected_mode_tangent_policy.name),
                "dense_rank_analysis_eligible" => jacobian_entries <= dense_entry_limit,
                "multiconductor_contract" => multiconductor_contract,
                "source_behavior_auxiliary" => source_behavior_auxiliary,
                "source_behavior_auxiliary_solve" => source_behavior_auxiliary_solve,
                "source_behavior_report" => source_behavior_report,
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
                "source_snapshot" => source_snapshot,
                "status" => "error", "error" => message,
                "point_policy" => point_policy,
                "source_behavior_solver" => source_behavior_solver,
                "source_behavior_solver_attributes" => source_behavior_solver_attributes,
                "rank_max_dense_entries" => dense_entry_limit,
                "iterative_right_nullspace_probe_dimension" => iterative_probe_dimension,
                "iterative_right_nullspace_probe_iterations" => iterative_probe_iterations,
                "expected_mode_tangent_policy" => "unavailable",
                "integrity_preflight" => preflight,
            )))
            push!(index, Dict(
                "name" => spec.name, "status" => "error",
                "result_file" => basename(result_path), "error" => message,
                "point_policy" => point_policy,
                "source_behavior_solver" => source_behavior_solver,
                "source_behavior_solver_attributes" => source_behavior_solver_attributes,
                "source_snapshot" => source_snapshot,
            ))
            println("$(spec.name): ERROR — $(sprint(showerror, error))")
        end
    end
    write(joinpath(output_dir, "index.json"), JSON.json(Dict(
        "fixture_root" => abspath(root),
        "environment" => environment,
        "environment_fingerprint" => environment_fingerprint,
        "point_policy" => point_policy,
        "source_behavior_solver" => source_behavior_solver,
        "source_behavior_solver_attributes" => source_behavior_solver_attributes,
        "rank_max_dense_entries" => dense_entry_limit,
        "expected_mode_free_coordinate_policy" =>
            expected_mode_free_coordinate_policy,
        "expected_mode_tangent_policy" => get(
            ENV, "NLPDIAGNOSTICS_BMOPF_EXPECTED_MODE_TANGENT_POLICY", "fixed",
        ),
        "cases" => index,
    )))
    println("wrote evidence records to $output_dir")
end

main()
