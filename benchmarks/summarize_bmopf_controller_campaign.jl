#!/usr/bin/env julia

"""Summarize typed controller observations from one or more BMOPF campaigns.

This is descriptive evidence only. It reports coverage, statuses, residuals,
breakpoint distances, and slope variation without reducing a campaign to a
single score or inferring a physical cause.

Usage:
    julia summarize_bmopf_controller_campaign.jl output.json persistence1.json ...
"""

Base.include(@__MODULE__, joinpath(@__DIR__, "common.jl"))
using .NLPDiagnosticsBenchmarkCommon: read_summary, write_json

function _load(path)
    isfile(path) || error("controller campaign report is missing: $path")
    value = read_summary(path; root = "/")
    value isa AbstractDict || error("controller campaign report is not an object: $path")
    return value
end

function _number(value)
    value isa Number && return isfinite(Float64(value)) ? Float64(value) : nothing
    value isa AbstractString || return nothing
    parsed = try
        parse(Float64, value)
    catch
        return nothing
    end
    return isfinite(parsed) ? parsed : nothing
end

function _violation_counts(observations; residual_tolerance = 1.0e-6)
    residual_count = 0
    cap_count = 0
    for observation in observations
        residual = _number(get(observation, "equation_residual", nothing))
        !isnothing(residual) && abs(residual) > residual_tolerance && (residual_count += 1)
        cap = _number(get(observation, "cap_violation", nothing))
        !isnothing(cap) && cap > residual_tolerance && (cap_count += 1)
    end
    return residual_count, cap_count
end

function _stats(values)
    isempty(values) && return nothing
    sorted = sort(values)
    return Dict{String,Any}(
        "sample_count" => length(values),
        "minimum" => first(sorted),
        "mean" => sum(values) / length(values),
        "maximum" => last(sorted),
    )
end

function _count_values(values)
    counts = Dict{String,Int}()
    for value in values
        key = String(value)
        counts[key] = get(counts, key, 0) + 1
    end
    return Dict(key => counts[key] for key in sort!(collect(keys(counts))))
end

function _finding_counts(report)
    counts = Dict{String,Int}()
    persistence = get(report, "controller_curve_persistence", Dict())
    persistence isa AbstractDict || return counts
    for finding in get(persistence, "findings", Any[])
        finding isa AbstractDict || continue
        code = String(get(finding, "code", "unknown"))
        counts[code] = get(counts, code, 0) + 1
    end
    return Dict(key => counts[key] for key in sort!(collect(keys(counts))))
end

const _SEMANTIC_FAMILIES = Dict("volt_var" => "ibr_q_volt_var",
                                "volt_watt" => "ibr_p_volt_watt")

function _registry_summary(report, observations; residual_tolerance = 1.0e-6)
    rows = get(report, "bmopf_constraint_semantic_rows", nothing)
    rows isa AbstractDict || return Dict("status" => "unavailable", "row_count" => 0,
        "registered_violation_count" => 0, "unmatched_violation_count" => 0,
        "components_by_status" => Dict{String,Vector{String}}())
    components = Dict{String,Vector{String}}()
    registered = 0
    unmatched = 0
    for observation in observations
        residual = _number(get(observation, "equation_residual", nothing))
        cap = _number(get(observation, "cap_violation", nothing))
        (isnothing(residual) || abs(residual) <= residual_tolerance) &&
            (isnothing(cap) || cap <= residual_tolerance) && continue
        component_id = get(observation, "component_id", nothing)
        family = get(observation, "curve_family", nothing)
        component_id isa AbstractString && family isa AbstractString || continue
        expected = get(_SEMANTIC_FAMILIES, String(family), nothing)
        matching = any(descriptor -> descriptor isa AbstractDict &&
                       get(descriptor, "constraint_family", nothing) == expected &&
                       occursin(String(component_id), string(get(descriptor, "constraint_index", ""))), values(rows))
        status = matching ? "registered" : "not_found"
        matching ? (registered += 1) : (unmatched += 1)
        push!(get!(components, status, String[]), "ibr:$(component_id):$(family)")
    end
    return Dict("status" => "available", "row_count" => length(rows),
                "registered_violation_count" => registered,
                "unmatched_violation_count" => unmatched,
                "components_by_status" => Dict(k => sort!(unique(components[k]))
                                                 for k in sort!(collect(keys(components)))))
end

function _snapshot_observations(report)
    snapshots = get(report, "controller_curve_snapshots", Any[])
    snapshots isa AbstractVector || return Any[]
    result = Any[]
    for snapshot in snapshots
        snapshot isa AbstractDict || continue
        for observation in get(snapshot, "observations", Any[])
            observation isa AbstractDict || continue
            push!(result, merge(
                Dict{String,Any}("snapshot" => get(snapshot, "snapshot", nothing)),
                Dict{String,Any}(string(key) => value for (key, value) in observation),
            ))
        end
    end
    return result
end

function _component_summaries(observations; slope_change_factor = 10.0,
                              residual_tolerance = 1.0e-6)
    grouped = Dict{String,Vector{Any}}()
    for observation in observations
        key = join((
            get(observation, "component_type", "unknown"),
            get(observation, "component_id", "unknown"),
            get(observation, "curve_family", "unknown"),
        ), ":")
        push!(get!(grouped, key, Any[]), observation)
    end
    summaries = Any[]
    for key in sort!(collect(keys(grouped)))
        group = grouped[key]
        slopes = Float64[]
        distances = Float64[]
        residuals = Float64[]
        caps = Float64[]
        for observation in group
            value = _number(get(observation, "local_slope", nothing))
            isnothing(value) || push!(slopes, value)
            value = _number(get(observation, "breakpoint_distance", nothing))
            isnothing(value) || push!(distances, value)
            value = _number(get(observation, "equation_residual", nothing))
            isnothing(value) || push!(residuals, abs(value))
            value = _number(get(observation, "cap_violation", nothing))
            isnothing(value) || push!(caps, value)
        end
        residual_violation_count, cap_violation_count = _violation_counts(
            group; residual_tolerance,
        )
        slope_ratio = if length(slopes) >= 2
            maximum(abs.(slopes)) / max(minimum(abs.(slopes)), eps(Float64))
        else
            nothing
        end
        push!(summaries, Dict{String,Any}(
            "key" => key,
            "snapshot_count" => length(group),
            "curve_family" => get(first(group), "curve_family", "unknown"),
            "slope" => _stats(slopes),
            "slope_change_factor" => slope_ratio,
            "slope_change_observed" => !isnothing(slope_ratio) && slope_ratio >= slope_change_factor,
            "breakpoint_distance" => _stats(distances),
            "absolute_equation_residual" => _stats(residuals),
            "cap_violation" => _stats(caps),
            "equation_residual_violation_count" => residual_violation_count,
            "cap_violation_count" => cap_violation_count,
        ))
    end
    return summaries
end

function _summarize(path; slope_change_factor = 10.0,
                     residual_tolerance = 1.0e-6)
    report = _load(path)
    observations = _snapshot_observations(report)
    families = [get(observation, "curve_family", "unknown") for observation in observations]
    statuses = [get(observation, "status", "unknown") for observation in observations]
    semantics = [get(observation, "monitor_semantics", "unknown") for observation in observations]
    slopes = Float64[]
    distances = Float64[]
    residuals = Float64[]
    caps = Float64[]
    for observation in observations
        for (field, destination) in (
            ("local_slope", slopes),
            ("breakpoint_distance", distances),
            ("equation_residual", residuals),
            ("cap_violation", caps),
        )
            value = _number(get(observation, field, nothing))
            isnothing(value) || push!(destination, field == "equation_residual" ? abs(value) : value)
        end
    end
    residual_violation_count, cap_violation_count = _violation_counts(
        observations; residual_tolerance,
    )
    components = _component_summaries(observations;
        slope_change_factor, residual_tolerance,
    )
    return Dict{String,Any}(
        "report_path" => path,
        "report_version" => get(report, "report_version", nothing),
        "snapshot_count" => length(get(report, "snapshots", Any[])),
        "observation_count" => length(observations),
        "family_counts" => _count_values(families),
        "status_counts" => _count_values(statuses),
        "monitor_semantics_counts" => _count_values(semantics),
        "local_slope" => _stats(slopes),
        "breakpoint_distance" => _stats(distances),
        "absolute_equation_residual" => _stats(residuals),
        "cap_violation" => _stats(caps),
        "residual_tolerance" => residual_tolerance,
        "equation_residual_violation_count" => residual_violation_count,
        "cap_violation_count" => cap_violation_count,
        "violation_component_count" => count(component ->
            component["equation_residual_violation_count"] > 0 ||
            component["cap_violation_count"] > 0, components),
        "slope_change_factor_threshold" => slope_change_factor,
        "component_curve_count" => length(components),
        "component_curve_slope_change_count" => count(
            summary -> summary["slope_change_observed"], components,
        ),
        "component_curves" => components,
        "persistence_finding_codes" => _finding_counts(report),
        "semantic_row_registry" => _registry_summary(report, observations;
            residual_tolerance),
    )
end

function main()
    length(ARGS) >= 2 || error(
        "usage: summarize_bmopf_controller_campaign.jl output.json persistence1.json ...",
    )
    output_path = abspath(first(ARGS))
    threshold = try
        parse(Float64, get(ENV, "NLPDIAGNOSTICS_CONTROLLER_SLOPE_CHANGE_FACTOR", "10.0"))
    catch
        error("NLPDIAGNOSTICS_CONTROLLER_SLOPE_CHANGE_FACTOR must be numeric")
    end
    threshold >= 1.0 || error("NLPDIAGNOSTICS_CONTROLLER_SLOPE_CHANGE_FACTOR must be at least one")
    residual_tolerance = try
        parse(Float64, get(ENV, "NLPDIAGNOSTICS_CONTROLLER_RESIDUAL_TOLERANCE", "1.0e-6"))
    catch
        error("NLPDIAGNOSTICS_CONTROLLER_RESIDUAL_TOLERANCE must be numeric")
    end
    residual_tolerance > 0.0 && isfinite(residual_tolerance) ||
        error("NLPDIAGNOSTICS_CONTROLLER_RESIDUAL_TOLERANCE must be finite and positive")
    reports = [_summarize(abspath(path);
        slope_change_factor = threshold, residual_tolerance,
    ) for path in ARGS[2:end]]
    write_json(output_path, Dict(
        "report_version" => "bmopf-controller-campaign-summary-v1",
        "report_count" => length(reports),
        "slope_change_factor_threshold" => threshold,
        "residual_tolerance" => residual_tolerance,
        "reports" => reports,
        "interpretation" => "Controller observations are local numerical evidence. Slope changes, breakpoint proximity, residuals, and coverage transitions do not by themselves establish a physical or formulation defect.",
    ))
    println("wrote BMOPF controller campaign summary to $output_path")
end

main()
