#!/usr/bin/env julia

# Summarize JSON records emitted by bmopf_smoke.jl:
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
    for entry in index["cases"]
        record_path = joinpath(output_dir, entry["result_file"])
        record = JSON.parsefile(record_path)
        summary = Dict{String,Any}(entry)
        if entry["status"] == "ok"
            profile = record["profile"]
            generic = _count_codes(profile["profile"]["reports"])
            context = _count_codes(Dict("context" => profile["bmopf_context_report"]))
            initialization = _count_codes(Dict(
                "initialization" => profile["bmopf_initialization_report"],
            ))
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
            summary["generic_finding_codes"] = generic
            summary["context_finding_codes"] = context
            summary["initialization_finding_codes"] = initialization
        end
        push!(cases, summary)
    end
    summary = Dict{String,Any}(
        "fixture_root" => index["fixture_root"],
        "cases" => cases,
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
