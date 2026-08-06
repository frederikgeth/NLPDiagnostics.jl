#!/usr/bin/env julia

"""Summarize typed controller observations from one or more BMOPF campaigns.

This is descriptive evidence only. It reports coverage, statuses, residuals,
breakpoint distances, and slope variation without reducing a campaign to a
single score or inferring a physical cause.

Usage:
    julia summarize_bmopf_controller_campaign.jl output.json persistence1.json ...
"""

using JSON

function _load(path)
    isfile(path) || error("controller campaign report is missing: $path")
    value = JSON.parsefile(path)
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

function _component_summaries(observations; slope_change_factor = 10.0)
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
        ))
    end
    return summaries
end

function _summarize(path; slope_change_factor = 10.0)
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
    components = _component_summaries(observations; slope_change_factor)
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
        "slope_change_factor_threshold" => slope_change_factor,
        "component_curve_count" => length(components),
        "component_curve_slope_change_count" => count(
            summary -> summary["slope_change_observed"], components,
        ),
        "component_curves" => components,
        "persistence_finding_codes" => _finding_counts(report),
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
    reports = [_summarize(abspath(path); slope_change_factor = threshold) for path in ARGS[2:end]]
    write(output_path, JSON.json(Dict(
        "report_version" => "bmopf-controller-campaign-summary-v1",
        "report_count" => length(reports),
        "slope_change_factor_threshold" => threshold,
        "reports" => reports,
        "interpretation" => "Controller observations are local numerical evidence. Slope changes, breakpoint proximity, residuals, and coverage transitions do not by themselves establish a physical or formulation defect.",
    )))
    println("wrote BMOPF controller campaign summary to $output_path")
end

main()
