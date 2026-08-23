#!/usr/bin/env julia

"""Summarize `solver_failure_cases.jl` evidence without asserting expected outcomes."""

Base.include(@__MODULE__, joinpath(@__DIR__, "common.jl"))
using .NLPDiagnosticsBenchmarkCommon: read_summary, write_json

function _count_codes(report)
    counts = Dict{String,Int}()
    report isa AbstractDict || return counts
    for finding in get(report, "findings", Any[])
        code = String(get(finding, "code", "unknown"))
        counts[code] = get(counts, code, 0) + 1
    end
    return counts
end

function _merge!(target, source)
    for (key, value) in source
        target[key] = get(target, key, 0) + value
    end
    return target
end

function main()
    length(ARGS) in (1, 2) || error(
        "usage: summarize_solver_failure_cases.jl <output-directory> [summary.json]",
    )
    output_dir = abspath(ARGS[1])
    index_path = joinpath(output_dir, "index.json")
    isfile(index_path) || error("missing index.json in $output_dir")
    index = read_summary(index_path; root = "/")
    records = Dict{String,Any}[]
    observed_categories = Dict{String,Int}()
    terminations = Dict{String,Int}()
    expected_signals = Dict{String,Int}()
    finding_codes = Dict{String,Int}()
    log_evidence_case_count = 0
    log_observation_count = 0
    log_conflicting_marker_count = 0
    for entry in get(index, "cases", Any[])
        file = get(entry, "result_file", nothing)
        record = if file isa AbstractString && isfile(joinpath(output_dir, file))
            read_summary(joinpath(output_dir, file); root = "/")
        else
            # Preserve an isolated child that exited before writing its case
            # JSON. The index still contains its expected signal, process
            # status, exit code, and any completed log path.
            Dict{String,Any}(String(key) => value for (key, value) in entry)
        end
        category = String(get(record, "observed_category", "unknown"))
        termination = String(get(record, "observed_termination", "unknown"))
        expected = String(get(record, "expected_signal", "unspecified"))
        observed_categories[category] = get(observed_categories, category, 0) + 1
        terminations[termination] = get(terminations, termination, 0) + 1
        expected_signals[expected] = get(expected_signals, expected, 0) + 1
        postmortem = get(record, "postmortem", nothing)
        result_report = postmortem isa AbstractDict ?
            get(postmortem, "result_report", nothing) : nothing
        codes = _count_codes(result_report)
        log_correlation = get(record, "log_correlation", nothing)
        _merge!(codes, _count_codes(log_correlation))
        _merge!(finding_codes, codes)
        log_evidence = get(record, "log_evidence", nothing)
        log_available = log_evidence isa AbstractDict
        log_available && (log_evidence_case_count += 1)
        if log_available
            raw = get(log_evidence, "raw", nothing)
            raw_metadata = raw isa AbstractDict ? get(raw, "metadata", nothing) : nothing
            if raw_metadata isa AbstractDict
                log_observation_count += try
                    parse(Int, String(get(raw_metadata, "recognized_log_observation_count", "0")))
                catch
                    0
                end
            end
            profile_metadata = log_correlation isa AbstractDict ?
                get(log_correlation, "metadata", nothing) : nothing
            if profile_metadata isa AbstractDict
                log_conflicting_marker_count += try
                    parse(Int, String(get(
                        profile_metadata,
                        "postmortem_log_consistency_postmortem_log_conflicting_marker_count",
                        "0",
                    )))
                catch
                    0
                end
            end
        end
        trace = get(record, "trace", nothing)
        push!(records, Dict{String,Any}(
            "case" => get(record, "case", get(entry, "case", "unknown")),
            "solver" => get(record, "solver", get(entry, "solver", "unknown")),
            "expected_signal" => expected,
            "observed_termination" => termination,
            "observed_category" => category,
            "status" => get(record, "status", get(entry, "status", "unknown")),
            "process_exit_code" => get(record, "process_exit_code", get(entry, "process_exit_code", nothing)),
            "process_timeout" => get(record, "process_timeout", get(entry, "process_timeout", false)),
            "process_log" => get(record, "process_log", get(entry, "process_log", nothing)),
            "trace_record_count" => trace isa AbstractDict ? get(trace, "record_count", nothing) : nothing,
            "trace_segment_count" => trace isa AbstractDict ? get(trace, "segment_count", nothing) : nothing,
            "postmortem_finding_codes" => codes,
            "log_evidence_available" => log_available,
            "log_correlation_available" => log_correlation isa AbstractDict,
            "log_source" => get(record, "log_source", "unavailable"),
            "log_observation_count" => log_available ? get(
                get(get(log_evidence, "raw", Dict{String,Any}()),
                    "metadata", Dict{String,Any}()),
                "recognized_log_observation_count", "0",
            ) : nothing,
            "postmortem_log_conflicting_marker_count" => log_correlation isa AbstractDict ? get(
                    get(log_correlation, "metadata", Dict{String,Any}()),
                    "postmortem_log_consistency_postmortem_log_conflicting_marker_count",
                    "0",
                ) : nothing,
        ))
    end
    output_path = length(ARGS) == 2 ? abspath(ARGS[2]) : joinpath(output_dir, "summary.json")
    write_json(output_path, Dict(
        "runner_version" => get(index, "runner_version", nothing),
        "environment" => get(index, "environment", nothing),
        "solvers" => get(index, "solvers", nothing),
        "child_timeout_seconds" => get(index, "child_timeout_seconds", nothing),
        "expected_signal_counts" => expected_signals,
        "observed_category_counts" => observed_categories,
        "termination_counts" => terminations,
        "postmortem_finding_codes" => finding_codes,
        "log_evidence_case_count" => log_evidence_case_count,
        "log_observation_count" => log_observation_count,
        "postmortem_log_conflicting_marker_count" => log_conflicting_marker_count,
        "records" => records,
    ))
    println("wrote solver-failure summary to $output_path")
end

main()
