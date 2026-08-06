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
    return Dict{String,Any}(
        "voltage_port_count" => length(voltage_ports),
        "voltage_coordinate_map_count" => length(voltage_maps),
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
        "current_report_finding_count" => length(current_report.findings),
        "current_skipped_count" => parse(Int, current_report.metadata[:bmopf_terminal_current_port_skipped_count]),
        "physical_mode_count" => length(physical_modes),
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
    dense_entry_limit = _dense_entry_limit()
    environment = _benchmark_environment()
    environment_fingerprint = _benchmark_environment_fingerprint(environment)

    for spec in fixtures
        path = joinpath(root, spec.file)
        result_path = joinpath(output_dir, "$(spec.name).json")
        preflight = nothing
        try
            isfile(path) || error("fixture is missing: $path")
            network = BMOPFTools.from_dss(path)
            preflight = _bmopf_integrity_preflight(network)
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
            multiconductor_contract = _multiconductor_contract_data(
                run.context; operating_source = run.result.profile.evaluation.point,
            )
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
                "integrity_preflight" => preflight,
                "tags" => string.(spec.tags),
                "environment_fingerprint" => environment_fingerprint,
                "point_policy" => point_policy,
                "model_variable_count" => variable_count,
                "scalar_constraint_row_count" => constraint_row_count,
                "jacobian_dense_entry_count" => jacobian_entries,
                "rank_max_dense_entries" => dense_entry_limit,
                "dense_rank_analysis_eligible" => jacobian_entries <= dense_entry_limit,
                "multiconductor_contract" => multiconductor_contract,
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
                "multiconductor_contract" => multiconductor_contract,
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
                "integrity_preflight" => preflight,
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
        "environment" => environment,
        "environment_fingerprint" => environment_fingerprint,
        "rank_max_dense_entries" => dense_entry_limit,
        "cases" => index,
    )))
    println("wrote evidence records to $output_dir")
end

main()
