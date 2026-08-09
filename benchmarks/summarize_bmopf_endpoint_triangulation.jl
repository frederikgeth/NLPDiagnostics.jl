#!/usr/bin/env julia

"""Join solver endpoint evidence with trusted BMOPF point calibration.

The report is deliberately descriptive. It classifies semantic findings at a
solver endpoint as successful-endpoint or endpoint-conditioned, and compares
their finding-code maps with the engine-start and saved-SI calibration points.
It does not rank policies or infer causality.

Usage:
    julia summarize_bmopf_endpoint_triangulation.jl calibration.json solver.json ...

Additional calibration summaries can be supplied with the comma-separated
`NLPDIAGNOSTICS_BMOPF_TRIANGULATION_CALIBRATIONS` environment variable.

Set `NLPDIAGNOSTICS_BMOPF_TRIANGULATION_OUTPUT` to choose the output path.
"""

using JSON

_dict(value) = value isa AbstractDict ?
    Dict{String,Any}(String(k) => v for (k, v) in value) : Dict{String,Any}()

function _number(value)
    value isa Bool && return nothing
    value isa Real && isfinite(Float64(value)) && return Float64(value)
    value isa AbstractString || return nothing
    parsed = tryparse(Float64, strip(String(value)))
    parsed isa Real && isfinite(parsed) ? Float64(parsed) : nothing
end

function _slug(value)
    text = replace(String(value), r"\.bmopf\.json$" => "")
    replace(text, r"[^A-Za-z0-9_.-]+" => "__")
end

function _successful_termination(value)
    lowercase(String(value)) in ("locally_optimal", "optimal", "solved", "success")
end

function _finding_codes(record)
    profile = _dict(get(record, "profile", nothing))
    context = _dict(get(profile, "bmopf_context_report", nothing))
    codes = _dict(get(context, "finding_code_counts", nothing))
    isempty(codes) || return codes
    generic = _dict(get(profile, "profile", nothing))
    reports = _dict(get(generic, "reports", nothing))
    result = Dict{String,Any}()
    for report in values(reports)
        raw = _dict(report)
        for (code, count) in _dict(get(raw, "finding_code_counts", nothing))
            result[code] = get(result, code, 0) + count
        end
    end
    return result
end

function _calibration_points(calibration)
    points = Dict{String,Dict{String,Any}}()
    for raw_case in get(calibration, "cases", Any[])
        raw_case isa AbstractDict || continue
        case = _dict(raw_case)
        name = String(get(case, "case", get(case, "name", "unknown")))
        point_map = Dict{String,Any}()
        for raw_observation in get(case, "observations", Any[])
            raw_observation isa AbstractDict || continue
            observation = _dict(raw_observation)
            point = String(get(observation, "point", get(observation, "point_label", "unknown")))
            record_path = get(observation, "record_path", nothing)
            codes = Dict{String,Any}()
            if record_path isa AbstractString && isfile(record_path)
                try
                    codes = _finding_codes(JSON.parsefile(record_path))
                catch
                    codes = Dict{String,Any}()
                end
            end
            entry = get!(point_map, point, Dict{String,Any}(
                "fingerprints" => String[], "finding_codes" => Any[],
                "replicates" => 0,
            ))
            entry["replicates"] += 1
            fingerprint = get(observation, "point_fingerprint", nothing)
            fingerprint isa AbstractString && push!(entry["fingerprints"], String(fingerprint))
            push!(entry["finding_codes"], codes)
        end
        points[_slug(name)] = Dict(
            "name" => name, "points" => point_map,
            "readiness" => _dict(get(calibration, "readiness", nothing)),
            "trusted_saved_point_available" => get(case, "trusted_saved_point_available", false),
        )
    end
    return points
end

function _solver_case(raw_case, source, configuration = nothing)
    case = _dict(raw_case)
    name = String(get(case, "name", get(case, "snapshot", get(case, "source_snapshot", "unknown"))))
    termination = String(get(case, "termination", "unknown"))
    context_codes = _dict(get(case, "bmopf_context_finding_codes", nothing))
    profile_codes = _dict(get(case, "bmopf_profile_finding_codes", nothing))
    codes = Dict{String,Any}()
    merge!(codes, profile_codes)
    merge!(codes, context_codes)
    trace = _dict(get(case, "trace", nothing))
    return Dict{String,Any}(
        "source" => source,
        "configuration" => configuration,
        "name" => name,
        "case_key" => _slug(name),
        "status" => get(case, "status", nothing),
        "termination" => termination,
        "successful_endpoint" => _successful_termination(termination),
        "endpoint_conditioned" => !_successful_termination(termination) && !isempty(codes),
        "finding_codes" => codes,
        "iteration_count" => get(case, "iteration_count", get(trace, "record_count", nothing)),
        "final_primal_infeasibility" => get(trace, "final_primal_infeasibility", nothing),
        "final_dual_infeasibility" => get(trace, "final_dual_infeasibility", nothing),
        "environment_fingerprint" => get(case, "environment_fingerprint", nothing),
    )
end

function _solver_cases(path)
    summary = JSON.parsefile(path)
    cases = Dict{String,Any}[]
    if haskey(summary, "configurations")
        for configuration in get(summary, "configurations", Any[])
            configuration isa AbstractDict || continue
            label = String(get(configuration, "label", "unknown"))
            for case_group in get(configuration, "cases", Any[])
                case_group isa AbstractDict || continue
                for observation in get(case_group, "observations", Any[])
                    observation isa AbstractDict || continue
                    entry = _solver_case(observation, path, label)
                    entry["name"] = get(case_group, "name", entry["name"])
                    entry["case_key"] = _slug(entry["name"])
                    push!(cases, entry)
                end
            end
        end
    else
        for raw_case in get(summary, "cases", Any[])
            raw_case isa AbstractDict || continue
            entry = _solver_case(raw_case, path)
            entry["configuration"] = basename(dirname(path))
            push!(cases, entry)
        end
    end
    return cases, summary
end

function _semantic_only_codes(codes)
    result = Dict{String,Any}()
    for (code, count) in _dict(codes)
        startswith(code, "bmopf_saved_result_") && continue
        code == "bmopf_opf_differentiability_not_ready" && continue
        result[code] = count
    end
    return result
end

function _point_codes(points, label)
    point = get(points, label, nothing)
    point isa AbstractDict || return Dict{String,Any}()
    observations = get(point, "finding_codes", Any[])
    isempty(observations) && return Dict{String,Any}()
    first = observations[1]
    first isa AbstractDict ? _semantic_only_codes(first) : Dict{String,Any}()
end

function _classify(entry, calibration_case)
    calibration_case isa AbstractDict || return "unmatched_case"
    points = _dict(get(calibration_case, "points", nothing))
    engine = _point_codes(points, "engine_start")
    saved = _point_codes(points, "saved_si")
    codes = _dict(get(entry, "finding_codes", nothing))
    isempty(codes) && return "no_semantic_findings"
    entry["matches_engine_start"] = !isempty(engine) && codes == engine
    entry["matches_saved_si"] = !isempty(saved) && codes == saved
    entry["calibration_engine_start_finding_codes"] = engine
    entry["calibration_saved_si_finding_codes"] = saved
    entry["semantic_classification"] = entry["endpoint_conditioned"] ?
        "endpoint_conditioned" :
        (entry["matches_engine_start"] ? "successful_matches_engine_start" :
         entry["matches_saved_si"] ? "successful_matches_saved_si" :
         entry["successful_endpoint"] ? "successful_unmatched_endpoint" : "unclassified")
    return entry["semantic_classification"]
end

function main()
    length(ARGS) >= 2 || error("usage: summarize_bmopf_endpoint_triangulation.jl calibration.json solver.json ...")
    calibration_paths = [abspath(first(ARGS))]
    append!(calibration_paths, filter(!isempty, abspath.(filter(
        !isempty, strip.(split(get(ENV,
            "NLPDIAGNOSTICS_BMOPF_TRIANGULATION_CALIBRATIONS", ""), ','))),
    )))
    all(isfile, calibration_paths) || error("missing calibration summary in $(calibration_paths)")
    calibrations = [JSON.parsefile(path) for path in calibration_paths]
    calibration = first(calibrations)
    calibration_points = Dict{String,Dict{String,Any}}()
    for item in calibrations
        merge!(calibration_points, _calibration_points(item))
    end
    entries = Dict{String,Any}[]
    solver_summaries = Any[]
    for path in abspath.(ARGS[2:end])
        isfile(path) || error("missing solver summary: $path")
        cases, summary = _solver_cases(path)
        push!(solver_summaries, Dict(
            "path" => path, "report_version" => get(summary, "report_version", nothing),
            "case_count" => length(cases),
        ))
        for entry in cases
            calibration_case = get(calibration_points, entry["case_key"], nothing)
            _classify(entry, calibration_case)
            entry["calibration_available"] = calibration_case isa AbstractDict
            push!(entries, entry)
        end
    end
    counts = Dict{String,Int}()
    for entry in entries
        classification = String(get(entry, "semantic_classification", "unmatched_case"))
        counts[classification] = get(counts, classification, 0) + 1
    end
    readiness_values = [_dict(get(item, "readiness", nothing)) for item in calibrations]
    payload = Dict{String,Any}(
        "report_version" => "bmopf-endpoint-triangulation-v1",
        "calibration_summary" => first(calibration_paths),
        "calibration_summaries" => calibration_paths,
        "solver_summaries" => solver_summaries,
        "case_count" => length(entries),
        "classification_counts" => counts,
        "trusted_point_calibration_ready" => !isempty(readiness_values) &&
            all(!isempty(readiness) && all(value == true for value in values(readiness))
                for readiness in readiness_values),
        "successful_endpoint_count" => count(entry -> get(entry, "successful_endpoint", false), entries),
        "endpoint_conditioned_count" => count(entry -> get(entry, "endpoint_conditioned", false), entries),
        "cases" => entries,
        "interpretation" => "Endpoint triangulation is empirical evidence. A successful endpoint matching a calibration point supports persistence at that point; endpoint-conditioned findings must not be promoted to formulation claims.",
    )
    output = abspath(get(ENV, "NLPDIAGNOSTICS_BMOPF_TRIANGULATION_OUTPUT",
        joinpath(dirname(first(calibration_paths)), "endpoint_triangulation_summary.json")))
    write(output, JSON.json(payload))
    println("wrote BMOPF endpoint-triangulation summary to $output")
end

main()
