#!/usr/bin/env julia

"""Combine structural-corpus and solver-matrix summaries.

This is a reporting layer only. It never merges finding severities into a
score and keeps structural, solver-result, context, and log fingerprints in
separate namespaces.
"""

using JSON

function _load(path)
    isfile(path) || error("summary file is missing: $path")
    value = JSON.parsefile(path)
    value isa AbstractDict || error("summary must be a JSON object: $path")
    return value
end

function _structural_view(summary)
    return Dict{String,Any}(
        "summary_path" => nothing,
        "runner_version" => get(summary, "runner_version", nothing),
        "analysis_mode" => get(summary, "analysis_mode", nothing),
        "point_policy" => get(summary, "point_policy", nothing),
        "result_units" => get(summary, "result_units", nothing),
        "result_field_units" => get(summary, "result_field_units", nothing),
        "include_floating_neutral_candidates" => get(summary, "include_floating_neutral_candidates", nothing),
        "floating_neutral_candidate_counts" => get(summary, "floating_neutral_candidate_counts", Dict()),
        "case_selection" => get(summary, "case_selection", nothing),
        "saved_result_mapping_case_counts" => get(summary, "saved_result_mapping_case_counts", Dict()),
        "rank_max_dense_entries" => get(summary, "rank_max_dense_entries", nothing),
        "case_count" => length(get(summary, "cases", Any[])),
        "profile_case_count" => get(summary, "profile_case_count", 0),
        "skipped_case_count" => get(summary, "skipped_case_count", 0),
        "error_case_count" => get(summary, "error_case_count", 0),
        "dense_rank_case_counts" => get(summary, "dense_rank_case_counts", Dict()),
        "integrity_preflight_case_counts" => get(summary, "integrity_preflight_case_counts", Dict()),
        "aggregate_generic_finding_codes" => get(summary, "aggregate_generic_finding_codes", Dict()),
        "aggregate_context_finding_codes" => get(summary, "aggregate_context_finding_codes", Dict()),
        "aggregate_initialization_finding_codes" => get(summary, "aggregate_initialization_finding_codes", Dict()),
        "aggregate_integrity_finding_codes" => get(summary, "aggregate_integrity_finding_codes", Dict()),
    )
end

function _solver_view(summary)
    return Dict{String,Any}(
        "summary_path" => nothing,
        "runner_version" => get(summary, "runner_version", nothing),
        "solver" => get(summary, "solver", nothing),
        "environment_fingerprint" => get(summary, "environment_fingerprint", nothing),
        "status_counts" => get(summary, "status_counts", Dict()),
        "successful_case_count" => get(summary, "successful_case_count", 0),
        "iteration_count_total" => get(summary, "iteration_count_total", 0),
        "failure_category_counts" => get(summary, "failure_category_counts", Dict()),
        "solver_result_finding_codes" => get(summary, "solver_result_finding_codes", Dict()),
        "bmopf_context_finding_codes" => get(summary, "bmopf_context_finding_codes", Dict()),
        "solver_log_finding_codes" => get(summary, "solver_log_finding_codes", Dict()),
        "solver_log_evidence_case_count" => get(summary, "solver_log_evidence_case_count", 0),
        "solver_log_iteration_count" => get(summary, "solver_log_iteration_count", 0),
    )
end

function _persistence_view(summary)
    reports = get(summary, "reports", Any[])
    reports isa AbstractVector || (reports = Any[])
    observed = Dict{String,Int}()
    availability = Dict{String,Int}()
    for report in reports
        report isa AbstractDict || continue
        fingerprints = get(report, "observed_fingerprints", Dict())
        fingerprints isa AbstractDict || continue
        for (key, value) in fingerprints
            value isa Number || continue
            observed[String(key)] = get(observed, String(key), 0) + Int(value)
        end
        dense = get(report, "dense_rank_max_entries", nothing)
        label = dense == 0 ? "dense_disabled" : "dense_enabled_or_unbounded"
        availability[label] = get(availability, label, 0) + 1
    end
    return Dict{String,Any}(
        "summary_path" => nothing,
        "report_version" => get(summary, "report_version", nothing),
        "report_count" => get(summary, "report_count", length(reports)),
        "reports" => reports,
        "observed_fingerprint_totals" => Dict(key => observed[key] for key in sort!(collect(keys(observed)))),
        "dense_budget_case_counts" => Dict(key => availability[key] for key in sort!(collect(keys(availability)))),
    )
end

function _merge_code_maps(summaries, field)
    merged = Dict{String,Int}()
    for summary in summaries
        codes = get(summary, field, Dict())
        codes isa AbstractDict || continue
        for (code, count) in codes
            count isa Number || continue
            merged[String(code)] = get(merged, String(code), 0) + Int(count)
        end
    end
    return Dict(code => merged[code] for code in sort!(collect(keys(merged))))
end

function main()
    length(ARGS) in (1, 2, 3) || error(
        "usage: summarize_bmopf_campaign.jl structural-summary.json [matrix-summary.json] [output.json]",
    )
    structural_path = abspath(ARGS[1])
    matrix_path = length(ARGS) >= 2 ? abspath(ARGS[2]) : nothing
    output_path = length(ARGS) == 3 ? abspath(ARGS[3]) :
        joinpath(dirname(structural_path), "campaign_summary.json")
    structural = _structural_view(_load(structural_path))
    structural["summary_path"] = structural_path
    additional_paths = filter(!isempty, strip.(split(
        get(ENV, "NLPDIAGNOSTICS_BMOPF_ADDITIONAL_CORPUS_SUMMARIES", ""), ',';
    )))
    additional_corpus = Dict{String,Any}()
    corpus_views = Any[structural]
    for raw_path in additional_paths
        path = abspath(raw_path)
        view = _structural_view(_load(path))
        view["summary_path"] = path
        additional_corpus[path] = view
        push!(corpus_views, view)
    end
    persistence_paths = filter(!isempty, strip.(split(
        get(ENV, "NLPDIAGNOSTICS_BMOPF_PERSISTENCE_SUMMARIES", ""), ',';
    )))
    persistence = nothing
    additional_persistence = Dict{String,Any}()
    persistence_views = Any[]
    for raw_path in persistence_paths
        path = abspath(raw_path)
        view = _persistence_view(_load(path))
        view["summary_path"] = path
        additional_persistence[path] = view
        push!(persistence_views, view)
    end
    !isempty(persistence_views) && (persistence = first(persistence_views))
    matrix = nothing
    solver_views = Dict{String,Any}()
    comparisons = Dict{String,Any}()
    if !isnothing(matrix_path)
        matrix_data = _load(matrix_path)
        matrix = Dict{String,Any}(
            "summary_path" => matrix_path,
            "runner_version" => get(matrix_data, "runner_version", nothing),
            "solvers" => get(matrix_data, "solvers", Any[]),
            "cases" => get(matrix_data, "cases", Any[]),
            "child_timeout_seconds" => get(matrix_data, "child_timeout_seconds", nothing),
            "summary_errors" => get(matrix_data, "summary_errors", Dict()),
        )
        for (solver, summary) in get(matrix_data, "solver_summaries", Dict())
            view = _solver_view(summary)
            view["summary_path"] = get(summary, "summary_path", nothing)
            solver_views[String(solver)] = view
        end
        comparisons = Dict{String,Any}(string(key) => value
                                       for (key, value) in get(matrix_data, "comparisons", Dict()))
    end
    context_codes = get(structural, "aggregate_context_finding_codes", Dict())
    integrity_codes = get(structural, "aggregate_integrity_finding_codes", Dict())
    solver_log_codes = Dict{String,Any}()
    solver_result_codes = Dict{String,Any}()
    for (solver, view) in solver_views
        solver_log_codes[solver] = get(view, "solver_log_finding_codes", Dict())
        solver_result_codes[solver] = get(view, "solver_result_finding_codes", Dict())
    end
    all_solver_log_codes = Dict{String,Int}()
    for codes in values(solver_log_codes)
        codes isa AbstractDict || continue
        for (code, count) in codes
            count isa Number || continue
            all_solver_log_codes[String(code)] =
                get(all_solver_log_codes, String(code), 0) + Int(count)
        end
    end
    write(output_path, JSON.json(Dict(
        "report_version" => "bmopf-campaign-summary-v1",
        "structural" => structural,
        "additional_corpus" => additional_corpus,
        "corpus_fingerprint_aggregates" => Dict(
            "aggregate_context_finding_codes" => _merge_code_maps(
                corpus_views, "aggregate_context_finding_codes",
            ),
            "aggregate_integrity_finding_codes" => _merge_code_maps(
                corpus_views, "aggregate_integrity_finding_codes",
            ),
            "aggregate_generic_finding_codes" => _merge_code_maps(
                corpus_views, "aggregate_generic_finding_codes",
            ),
        ),
        "solver_matrix" => matrix,
        "persistence" => persistence,
        "additional_persistence" => additional_persistence,
        "persistence_fingerprint_aggregates" => Dict(
            "observed_fingerprint_totals" => _merge_code_maps(
                persistence_views, "observed_fingerprint_totals",
            ),
        ),
        "solver_summaries" => solver_views,
        "pairwise_comparisons" => comparisons,
        "fingerprints" => Dict(
            "structural_context_codes" => context_codes,
            "integrity_codes" => integrity_codes,
            "solver_result_codes_by_solver" => solver_result_codes,
            "solver_log_codes_by_solver" => solver_log_codes,
            "all_solver_log_codes" => Dict(
                code => all_solver_log_codes[code]
                for code in sort!(collect(keys(all_solver_log_codes)))
            ),
        ),
        "interpretation" => "Evidence aggregation only; structural, solver-result, context, and log findings remain separately attributable.",
    )))
    println("wrote BMOPF campaign summary to $output_path")
end

main()
