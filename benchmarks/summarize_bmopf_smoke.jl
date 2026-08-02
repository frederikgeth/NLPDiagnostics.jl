#!/usr/bin/env julia

# Summarize JSON records emitted by bmopf_smoke.jl or bmopf_draft_corpus.jl:
#
# julia --project=. benchmarks/summarize_bmopf_smoke.jl /path/to/bmopf-smoke-results

using JSON

function _count_codes(reports)
    counts = Dict{String,Int}()
    for report in values(reports)
        for finding in report["findings"]
            code = finding["code"]
            counts[code] = get(counts, code, 0) + 1
        end
    end
    return Dict(key => counts[key] for key in sort!(collect(keys(counts))))
end

_sorted_counts(counts) = Dict(key => counts[key] for key in sort!(collect(keys(counts))))

function _report_counts(report)
    isnothing(report) && return Dict{String,Int}()
    return _count_codes(Dict("report" => report))
end

function _index_root(index)
    if haskey(index, "fixture_root")
        return ("fixture_root", index["fixture_root"])
    elseif haskey(index, "benchmark_root")
        return ("benchmark_root", index["benchmark_root"])
    end
    return ("source_root", nothing)
end

function main()
    output_dir = isempty(ARGS) ? get(ENV, "NLPDIAGNOSTICS_BMOPF_OUTPUT_DIR", "") : first(ARGS)
    isempty(output_dir) && error(
        "Pass the bmopf-smoke-results directory or set NLPDIAGNOSTICS_BMOPF_OUTPUT_DIR",
    )
    index_path = joinpath(output_dir, "index.json")
    isfile(index_path) || error("index file is missing: $index_path")
    index = JSON.parsefile(index_path)
    cases = Vector{Dict{String,Any}}()
    aggregate_generic = Dict{String,Int}()
    aggregate_context = Dict{String,Int}()
    aggregate_initialization = Dict{String,Int}()
    dense_eligible_cases = 0
    dense_skipped_cases = 0
    dense_not_requested_cases = 0
    dense_unknown_cases = 0
    for entry in index["cases"]
        record_path = joinpath(output_dir, entry["result_file"])
        record = JSON.parsefile(record_path)
        summary = Dict{String,Any}(entry)
        if entry["status"] == "ok"
            analysis_mode = get(record, "analysis_mode", "profile")
            generic, context, initialization = if analysis_mode == "structural"
                (_report_counts(record["report"]), Dict{String,Int}(), Dict{String,Int}())
            else
                profile = record["profile"]
                (_count_codes(profile["profile"]["reports"]),
                 _report_counts(profile["bmopf_context_report"]),
                 _report_counts(profile["bmopf_initialization_report"]))
            end
            for (counts, aggregate) in (
                (generic, aggregate_generic),
                (context, aggregate_context),
                (initialization, aggregate_initialization),
            )
                for (code, count) in counts
                    aggregate[code] = get(aggregate, code, 0) + count
                end
            end
            summary["point_policy"] = get(record, "point_policy", "unknown")
            summary["analysis_mode"] = analysis_mode
            summary["generic_finding_codes"] = generic
            summary["context_finding_codes"] = context
            summary["initialization_finding_codes"] = initialization
            eligible = get(record, "dense_rank_analysis_eligible", nothing)
            if analysis_mode == "structural"
                dense_not_requested_cases += 1
            elseif eligible === true
                dense_eligible_cases += 1
            elseif eligible === false
                dense_skipped_cases += 1
            else
                dense_unknown_cases += 1
            end
        end
        push!(cases, summary)
    end
    root_key, root_value = _index_root(index)
    summary = Dict{String,Any}(
        root_key => root_value,
        "rank_max_dense_entries" => get(index, "rank_max_dense_entries", nothing),
        "cases" => cases,
        "dense_rank_case_counts" => Dict(
            "eligible" => dense_eligible_cases,
            "skipped_by_size_policy" => dense_skipped_cases,
            "not_requested_structural" => dense_not_requested_cases,
            "unknown" => dense_unknown_cases,
        ),
        "aggregate_generic_finding_codes" => _sorted_counts(aggregate_generic),
        "aggregate_context_finding_codes" => _sorted_counts(aggregate_context),
        "aggregate_initialization_finding_codes" => _sorted_counts(aggregate_initialization),
    )
    summary_path = joinpath(output_dir, "summary.json")
    write(summary_path, JSON.json(summary))
    for case in cases
        name = case["name"]
        status = case["status"]
        policy = get(case, "point_policy", "")
        println("$name: $status", isempty(policy) ? "" : " point=$policy")
    end
    println("wrote $summary_path")
end

main()
