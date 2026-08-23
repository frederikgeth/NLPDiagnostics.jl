#!/usr/bin/env julia

"""Summarize the deterministic operator/domain fingerprint corpus."""

Base.include(@__MODULE__, joinpath(@__DIR__, "common.jl"))
using .NLPDiagnosticsBenchmarkCommon: read_summary, write_json

function _load(path)
    isfile(path) || error("missing operator fingerprint report: $path")
    value = read_summary(path; root = "/")
    value isa AbstractDict || error("operator fingerprint report is not a JSON object")
    value
end

function _dict(value)
    value isa AbstractDict || return Dict{String,Any}()
    Dict{String,Any}(String(k) => v for (k, v) in value)
end

function _int(value, default = 0)
    value isa Integer && return Int(value)
    value isa Number && isfinite(Float64(value)) && return Int(value)
    value isa AbstractString || return default
    try parse(Int, value) catch; default end
end

function _stage_codes(stage)
    stage = _dict(stage)
    codes = _dict(get(stage, "finding_codes", nothing))
    Dict(String(k) => _int(v) for (k, v) in codes)
end

function _stage_findings(stage)
    stage = _dict(stage)
    value = get(stage, "findings", Any[])
    value isa AbstractVector ? value : Any[]
end

function main()
    length(ARGS) >= 1 || error(
        "usage: summarize_operator_fingerprint.jl operator-fingerprint.json [summary.json]",
    )
    input_path = abspath(first(ARGS))
    output_path = length(ARGS) >= 2 ? abspath(ARGS[2]) :
        joinpath(dirname(input_path), "operator_fingerprint_summary.json")
    raw = _load(input_path)
    cases = get(raw, "cases", Any[])
    cases isa AbstractVector || (cases = Any[])
    stage_names = ("static", "expression_numerical", "initialization")
    stage_case_counts = Dict{String,Int}(stage => 0 for stage in stage_names)
    stage_finding_code_counts = Dict{String,Dict{String,Int}}(
        stage => Dict{String,Int}() for stage in stage_names
    )
    aggregate_codes = Dict{String,Int}()
    case_summaries = Any[]
    findings = Any[]
    for case_raw in cases
        case = _dict(case_raw)
        name = String(get(case, "name", "unknown"))
        status = String(get(case, "status", "unknown"))
        summary = Dict{String,Any}("name" => name, "status" => status)
        status == "ok" || begin
            summary["error"] = get(case, "error", nothing)
            push!(case_summaries, summary)
            continue
        end
        for stage in stage_names
            haskey(case, stage) || continue
            stage_case_counts[stage] += 1
            codes = _stage_codes(case[stage])
            summary["$(stage)_finding_codes"] = codes
            for (code, count) in codes
                aggregate_codes[code] = get(aggregate_codes, code, 0) + count
                bucket = stage_finding_code_counts[stage]
                bucket[code] = get(bucket, code, 0) + count
            end
            for finding_raw in _stage_findings(case[stage])
                finding = _dict(finding_raw)
                code = String(get(finding, "code", "unknown"))
                push!(findings, Dict{String,Any}(
                    "code" => code,
                    "severity" => get(finding, "severity", "unknown"),
                    "confidence" => get(finding, "confidence", "unknown"),
                    "domain" => get(finding, "domain", "unknown"),
                    "basis" => get(finding, "basis", "unknown"),
                    "observation" => get(finding, "observation", nothing),
                    "why_it_matters" => get(finding, "why_it_matters", nothing),
                    "suggested_actions" => get(finding, "suggested_actions", Any[]),
                    "case" => name,
                    "stage" => stage,
                    "evidence" => get(finding, "evidence", Any[]),
                    "affected" => get(finding, "affected", Any[]),
                ))
            end
        end
        push!(case_summaries, summary)
    end
    successful = count(get(_dict(case), "status", "") == "ok" for case in cases)
    errors = length(cases) - successful
    readiness = Dict{String,Any}(
        "cases_available" => !isempty(cases),
        "all_cases_successful" => !isempty(cases) && errors == 0,
        "static_stage_complete" => stage_case_counts["static"] == successful,
        "expression_stage_complete" => stage_case_counts["expression_numerical"] == successful,
        "initialization_stage_complete" => stage_case_counts["initialization"] == successful,
    )
    payload = Dict{String,Any}(
        "report_version" => "nlpdiagnostics-operator-fingerprint-summary-v1",
        "source_report" => input_path,
        "case_count" => length(cases),
        "successful_case_count" => successful,
        "error_case_count" => errors,
        "stage_case_counts" => stage_case_counts,
        "stage_finding_code_counts" => stage_finding_code_counts,
        "finding_code_counts" => Dict(k => aggregate_codes[k] for k in sort!(collect(keys(aggregate_codes)))),
        "case_summaries" => case_summaries,
        "findings" => findings,
        "readiness" => readiness,
        "interpretation" => "Summary and trust gates for static operator/domain observations; findings are evidence and not a model-quality score.",
    )
    write_json(output_path, payload)
    println("wrote operator fingerprint summary to $output_path")
end

main()
