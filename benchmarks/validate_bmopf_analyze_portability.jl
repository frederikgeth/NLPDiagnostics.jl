#!/usr/bin/env julia

"""Validate and optionally compare isolated BMOPFTools analyze summaries."""

using JSON

include(joinpath(@__DIR__, "common.jl"))
using .NLPDiagnosticsBenchmarkCommon

const EXPECTED_SCHEMA = "nlpdiagnostics-bmopf-analyze-runtime-isolated-v1"
const DEFAULT_SUMMARY = joinpath(repo_root(), "docs", "bmopf_analyze_runtime_isolated_summary.json")

function load_summary(path::AbstractString)
    value = read_summary(abspath(path); root = "/")
    value isa AbstractDict || error("summary must be a JSON object: $path")
    return value
end

function dict(value)
    value isa AbstractDict ? Dict{String,Any}(String(key) => item for (key, item) in value) : Dict{String,Any}()
end

function case_map(summary)
    result = Dict{String,Any}()
    for raw in get(summary, "case_summaries", Any[])
        item = dict(raw)
        name = String(get(item, "case", ""))
        isempty(name) || (result[name] = item)
    end
    return result
end

function records_by_case(summary)
    result = Dict{String,Vector{Any}}()
    for raw in get(summary, "records", Any[])
        item = dict(raw)
        case = String(get(item, "case", ""))
        isempty(case) && continue
        push!(get!(result, case, Any[]), item)
    end
    return result
end

function local_validation(summary)
    source = dict(get(summary, "source", nothing))
    environment = dict(get(summary, "environment", nothing))
    cases = case_map(summary)
    records = records_by_case(summary)
    errors = String[]
    warnings = String[]
    get(summary, "schema_version", nothing) == EXPECTED_SCHEMA || push!(errors, "schema_version_mismatch")
    get(source, "isolated_process_per_case_and_repetition", false) === true || push!(errors, "isolated_process_provenance_missing")
    get(source, "warmup", false) === true || push!(errors, "warmup_policy_missing")
    get(source, "max_variables", nothing) isa Integer || push!(errors, "variable_guard_missing")
    for field in ("julia_version", "os", "architecture", "git_revision")
        haskey(environment, field) || push!(errors, "environment_$(field)_missing")
    end
    isempty(cases) && push!(errors, "case_summaries_empty")
    for (case, summary_case) in cases
        rows = get(records, case, Any[])
        expected_records = get(source, "repetitions", 0)
        length(rows) == expected_records || push!(errors, "$(case)_record_count_mismatch")
        measured = filter(row -> get(row, "status", "") == "measured", rows)
        guarded = filter(row -> get(row, "status", "") == "skipped_size_guard", rows)
        if !isempty(measured)
            get(summary_case, "stable_across_repetitions", false) === true || push!(errors, "$(case)_stability_failed")
            all(get(row, "isolated_process", false) === true for row in measured) || push!(errors, "$(case)_isolated_flag_missing")
        elseif isempty(guarded)
            push!(warnings, "$(case)_has_no_measured_or_guarded_records")
        end
    end
    Dict{String,Any}(
        "status" => isempty(errors) ? "valid" : "invalid",
        "errors" => errors,
        "warnings" => warnings,
        "case_count" => length(cases),
        "record_count" => length(get(summary, "records", Any[])),
        "measured_count" => get(summary, "measured_count", 0),
        "environment" => environment,
        "source" => source,
    )
end

function compatibility(baseline, current, baseline_validation, current_validation)
    left_source = baseline_validation["source"]
    right_source = current_validation["source"]
    left_env = baseline_validation["environment"]
    right_env = current_validation["environment"]
    mismatches = Dict{String,Any}()
    for field in ("cases", "max_variables", "repetitions", "warmup")
        get(left_source, field, nothing) == get(right_source, field, nothing) ||
            (mismatches[field] = Dict("baseline" => get(left_source, field, nothing), "current" => get(right_source, field, nothing)))
    end
    baseline_cases = sort!(collect(keys(case_map(baseline))))
    current_cases = sort!(collect(keys(case_map(current))))
    baseline_cases == current_cases || (mismatches["case_summaries"] = Dict("baseline" => baseline_cases, "current" => current_cases))
    environment_distinct = any(get(left_env, field, nothing) != get(right_env, field, nothing)
                               for field in ("julia_version", "os", "architecture", "git_revision", "active_project"))
    status = !isempty(mismatches) ? "incompatible" : environment_distinct ? "cross_environment_candidate" : "same_environment"
    Dict{String,Any}(
        "status" => status,
        "mismatches" => mismatches,
        "environment_distinct" => environment_distinct,
        "semantic_comparison" => semantic_comparison(baseline, current),
        "resource_comparison" => resource_comparison(baseline, current),
        "interpretation" => "Compatibility checks establish comparable workload and guard provenance; they do not establish portable performance or allocator behavior.",
    )
end

function resource_comparison(baseline, current)
    metrics = (
        "parse_allocated_bytes",
        "build_allocated_bytes",
        "kcl_allocated_bytes",
        "analyze_allocated_bytes",
        "process_maxrss_increment_bytes",
    )
    function measured_map(summary)
        result = Dict{String,Any}()
        for raw in get(summary, "records", Any[])
            record = dict(raw)
            get(record, "status", "") == "measured" || continue
            key = "$(get(record, "case", ""))#$(get(record, "repetition", ""))"
            result[key] = record
        end
        result
    end
    left = measured_map(baseline)
    right = measured_map(current)
    rows = Dict{String,Any}[]
    for key in sort!(collect(intersect(Set(keys(left)), Set(keys(right)))))
        metric_values = Dict{String,Any}()
        for metric in metrics
            baseline_value = get(left[key], metric, nothing)
            current_value = get(right[key], metric, nothing)
            if baseline_value isa Real && current_value isa Real
                metric_values[metric] = Dict(
                    "baseline" => baseline_value,
                    "current" => current_value,
                    "delta" => current_value - baseline_value,
                )
            end
        end
        push!(rows, Dict("key" => key, "metrics" => metric_values))
    end
    differing = count(row -> any(get(value, "delta", 0) != 0 for value in values(row["metrics"])), rows)
    Dict{String,Any}(
        "status" => isempty(rows) ? "unavailable" : "descriptive_only",
        "compared_metrics" => collect(metrics),
        "matched_record_count" => length(rows),
        "records_with_nonzero_differences" => differing,
        "records" => rows,
        "interpretation" => "Allocation and process high-water differences are descriptive local observations; they do not establish portable performance or allocator-level peak memory.",
    )
end

function semantic_comparison(baseline, current)
    fields = ("status", "variable_count", "constraint_count", "analyze_finding_count", "analyze_finding_code_counts")
    function measured_map(summary)
        result = Dict{String,Any}()
        for raw in get(summary, "records", Any[])
            record = dict(raw)
            get(record, "status", "") == "measured" || continue
            key = "$(get(record, "case", ""))#$(get(record, "repetition", ""))"
            result[key] = record
        end
        result
    end
    left = measured_map(baseline)
    right = measured_map(current)
    keys_match = sort!(collect(keys(left))) == sort!(collect(keys(right)))
    mismatches = Dict{String,Any}[]
    for key in sort!(collect(intersect(Set(keys(left)), Set(keys(right)))))
        differing = Dict{String,Any}()
        for field in fields
            get(left[key], field, nothing) == get(right[key], field, nothing) ||
                (differing[field] = Dict("baseline" => get(left[key], field, nothing), "current" => get(right[key], field, nothing)))
        end
        isempty(differing) || push!(mismatches, Dict("key" => key, "fields" => differing))
    end
    Dict{String,Any}(
        "status" => keys_match && isempty(mismatches) ? "semantics_match" : "semantic_mismatch",
        "baseline_measured_record_count" => length(left),
        "current_measured_record_count" => length(right),
        "matched_record_count" => length(intersect(Set(keys(left)), Set(keys(right)))),
        "record_key_sets_match" => keys_match,
        "mismatch_count" => length(mismatches),
        "mismatches" => mismatches,
        "compared_fields" => collect(fields),
    )
end

length(ARGS) in 0:3 || error("usage: validate_bmopf_analyze_portability.jl [summary.json] [comparison.json] [output.json]")
baseline_path = isempty(ARGS) ? DEFAULT_SUMMARY : abspath(ARGS[1])
comparison_path = length(ARGS) >= 2 ? abspath(ARGS[2]) : nothing
output_path = length(ARGS) == 3 ? abspath(ARGS[3]) :
    joinpath(repo_root(), "docs", "bmopf_analyze_portability_summary.json")
baseline = load_summary(baseline_path)
baseline_validation = local_validation(baseline)
comparison = nothing
if !isnothing(comparison_path)
    current = load_summary(comparison_path)
    current_validation = local_validation(current)
    comparison = compatibility(baseline, current, baseline_validation, current_validation)
end
status_entries = git_status_entries()
write_json(output_path, Dict{String,Any}(
    "schema_version" => "nlpdiagnostics-bmopf-analyze-portability-v1",
    "source" => Dict(
        "runner" => "benchmarks/validate_bmopf_analyze_portability.jl",
        "baseline_summary" => baseline_path,
        "comparison_summary" => comparison_path,
        "comparison_required_for_portable_claim" => true,
    ),
    "environment" => Dict(
        "julia_version" => string(VERSION),
        "active_project" => Base.active_project(),
        "git_revision" => git_revision(),
        "git_worktree_dirty" => !isempty(status_entries),
    ),
    "baseline_validation" => baseline_validation,
    "comparison" => comparison,
    "portable_evidence_status" => isnothing(comparison) ? "open_comparison_not_supplied" :
        comparison["status"] == "cross_environment_candidate" ? "candidate_requires_review" : "open",
    "interpretation" => Dict(
        "claim" => "The validator makes isolated analyze portability prerequisites machine-checkable.",
        "does_not_establish" => [
            "portable runtime or allocator-level memory behavior",
            "cross-environment equivalence without a supplied comparison summary",
        ],
    ),
))
println("wrote BMOPFTools analyze portability summary to $output_path")
