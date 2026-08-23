#!/usr/bin/env julia

# Build an evidence-preserving corpus fingerprint report from one or more
# campaign summaries. This is deliberately descriptive: frequencies are
# coverage-normalized observations, not a model quality score.
#
# julia --project=. benchmarks/corpus_fingerprint_report.jl \
#     campaign-a/summary.json campaign-b/summary.json [fingerprints.json]

Base.include(@__MODULE__, joinpath(@__DIR__, "common.jl"))
using .NLPDiagnosticsBenchmarkCommon: read_summary, write_json
using JSON

function _load(path)
    isfile(path) || error("summary file is missing: $path")
    data = read_summary(path; root = "/")
    data isa AbstractDict || error("summary must be a JSON object: $path")
    return data
end

_num(x) = x isa Number && isfinite(Float64(x)) ? Float64(x) : nothing

function _case_counts(summary)
    cases = get(summary, "cases", Any[])
    successful = count(c -> c isa AbstractDict && get(c, "status", "") == "ok", cases)
    profile = count(c -> c isa AbstractDict && get(c, "status", "") == "ok" &&
                        get(c, "analysis_mode", "profile") != "structural", cases)
    structural = count(c -> c isa AbstractDict && get(c, "status", "") == "ok" &&
                           get(c, "analysis_mode", "profile") == "structural", cases)
    return Dict(
        "total" => length(cases),
        "successful" => successful,
        "profile_successes" => profile,
        "structural_successes" => structural,
        "errors" => Int(get(summary, "error_case_count", 0)),
        "skipped" => Int(get(summary, "skipped_case_count", 0)),
    )
end

function _case_size_summary(summary)
    rows = Dict{String,Any}[]
    for case in get(summary, "cases", Any[])
        case isa AbstractDict || continue
        variables = _num(get(case, "model_variable_count", nothing))
        constraints = _num(get(case, "scalar_constraint_row_count",
                               get(case, "model_constraint_count", nothing)))
        (isnothing(variables) && isnothing(constraints)) && continue
        push!(rows, Dict(
            "name" => get(case, "name", get(case, "snapshot", "?")),
            "status" => get(case, "status", "unknown"),
            "analysis_mode" => get(case, "analysis_mode", "profile"),
            "variables" => variables,
            "constraints" => constraints,
            "dense_rank_analysis_eligible" => get(case, "dense_rank_analysis_eligible", nothing),
        ))
    end
    return rows
end

function _merge_counts!(target, source)
    source isa AbstractDict || return target
    for (key, value) in source
        n = _num(value)
        isnothing(n) && continue
        target[String(key)] = get(target, String(key), 0.0) + n
    end
    return target
end

function _rates(counts, denominator)
    denominator > 0 || return Dict(String(key) => Dict("count" => value, "rate" => nothing)
                                    for (key, value) in sort!(collect(counts); by = first))
    return Dict(
        String(key) => Dict("count" => value, "rate" => value / denominator)
        for (key, value) in sort!(collect(counts); by = first)
    )
end

function _campaign(path, summary)
    cases = _case_counts(summary)
    codes = Dict{String,Float64}()
    _merge_counts!(codes, get(summary, "aggregate_generic_finding_codes", nothing))
    _merge_counts!(codes, get(summary, "aggregate_context_finding_codes", nothing))
    _merge_counts!(codes, get(summary, "aggregate_initialization_finding_codes", nothing))
    attributes = Dict{String,Dict{String,Float64}}()
    for (section, key) in (("generic", "aggregate_generic_finding_attributes"),
                           ("context", "aggregate_context_finding_attributes"),
                           ("initialization", "aggregate_initialization_finding_attributes"))
        section_counts = Dict{String,Float64}()
        for (field, values) in get(summary, key, Dict{String,Any}())
            for (value, count) in values
                section_counts["$(field):$(value)"] = get(section_counts, "$(field):$(value)", 0.0) + Float64(count)
            end
        end
        attributes[section] = section_counts
    end
    return Dict{String,Any}(
        "source" => abspath(path),
        "runner_version" => get(summary, "runner_version", nothing),
        "environment_fingerprint" => get(summary, "environment_fingerprint", nothing),
        "root" => get(summary, "benchmark_root", get(summary, "fixture_root", nothing)),
        "case_counts" => cases,
        "case_sizes" => _case_size_summary(summary),
        "dense_rank_case_counts" => get(summary, "dense_rank_case_counts", nothing),
        "integrity_preflight_case_counts" => get(summary, "integrity_preflight_case_counts", nothing),
        "finding_code_counts" => codes,
        "finding_code_rates_per_success" => _rates(codes, cases["successful"]),
        "finding_attributes" => attributes,
        "finding_attribute_rates_per_success" => Dict(
            section => _rates(values, cases["successful"])
            for (section, values) in attributes
        ),
    )
end

function _cross_campaign(campaigns)
    codes = Dict{String,Dict{String,Any}}()
    domains = Dict{String,Dict{String,Any}}()
    for campaign in campaigns
        label = basename(dirname(campaign["source"]))
        denominator = campaign["case_counts"]["successful"]
        for (code, count) in campaign["finding_code_counts"]
            entry = get!(codes, code, Dict("campaigns" => 0, "case_observations" => 0.0, "campaign_labels" => String[]))
            entry["case_observations"] += count
            push!(entry["campaign_labels"], label)
            entry["maximum_rate"] = max(get(entry, "maximum_rate", 0.0), denominator > 0 ? count / denominator : 0.0)
        end
        for attribute_counts in Base.values(campaign["finding_attributes"])
            for (attribute, count) in attribute_counts
                entry = get!(domains, attribute, Dict("campaigns" => 0, "observations" => 0.0, "campaign_labels" => String[]))
                entry["observations"] += count
                push!(entry["campaign_labels"], label)
            end
        end
    end
    for entries in (codes, domains)
        for entry in values(entries)
            entry["campaign_labels"] = sort!(unique(entry["campaign_labels"]))
            entry["campaigns"] = length(entry["campaign_labels"])
        end
    end
    return Dict(
        "recurring_finding_codes" => Dict(key => codes[key] for key in sort!(collect(keys(codes)))),
        "recurring_finding_attributes" => Dict(key => domains[key] for key in sort!(collect(keys(domains)))),
    )
end

function main()
    length(ARGS) >= 2 || error(
        "usage: corpus_fingerprint_report.jl campaign-a/summary.json campaign-b/summary.json [fingerprints.json]",
    )
    paths = ARGS
    output = nothing
    if length(ARGS) >= 3
        paths = ARGS[1:end-1]
        output = last(ARGS)
    end
    campaigns = [_campaign(path, _load(path)) for path in paths]
    report = Dict(
        "campaign_count" => length(campaigns),
        "campaigns" => campaigns,
        "cross_campaign" => _cross_campaign(campaigns),
    )
    if isnothing(output)
        println(JSON.json(report))
    else
        write_json(output, report)
        println("wrote ", output)
    end
end

main()
