#!/usr/bin/env julia

"""Summarize a sparse-first source-preserving BMOPF corpus campaign."""

using JSON

_dict(value) = value isa AbstractDict ? Dict{String,Any}(string(k) => v for (k, v) in value) : Dict{String,Any}()

function _case_view(entry)
    case = _dict(entry)
    return Dict{String,Any}(
        "case" => get(case, "case", "unknown"),
        "budget" => get(case, "budget", nothing),
        "status" => get(case, "status", "unknown"),
        "classification" => get(case, "classification", "unavailable"),
        "case_status" => get(case, "case_status", "unknown"),
        "checkpoint_phase" => get(case, "checkpoint_phase", "unknown"),
        "model_variable_count" => get(case, "model_variable_count", nothing),
        "max_solver_variables" => get(case, "max_solver_variables", nothing),
        "solver_trace_status" => get(case, "solver_trace_status", "unknown"),
        "initialization_policy" => get(case, "initialization_policy", nothing),
        "finite_start_count" => get(case, "initialization_finite_start_count", nothing),
        "missing_start_count" => get(case, "initialization_missing_start_count", nothing),
        "endpoint_derivative_status" => get(case, "endpoint_derivative_status", "unavailable"),
        "source_contract_case_count" => get(case, "source_domain_contract_case_count", 0),
        "auxiliary_mutation_case_count" => get(case,
            "source_behavior_auxiliary_mutation_case_count", 0),
        "validation_finding_codes" => get(case, "validation_finding_codes", Any[]),
    )
end

function main()
    length(ARGS) in (1, 2) || error(
        "usage: summarize_bmopf_sparse_corpus.jl <matrix.json> [output.json]",
    )
    matrix_path = abspath(ARGS[1])
    output_path = length(ARGS) == 2 ? abspath(ARGS[2]) :
        joinpath(dirname(matrix_path), "sparse_corpus_summary.json")
    matrix = JSON.parsefile(matrix_path)
    rows = [_case_view(raw) for raw in get(matrix, "entries", Any[])]
    variable_counts = [Int(row["model_variable_count"]) for row in rows
                       if row["model_variable_count"] isa Number]
    phases = Dict{String,Int}()
    for row in rows
        phase = String(row["checkpoint_phase"])
        phases[phase] = get(phases, phase, 0) + 1
    end
    source_ready = all(row -> row["source_contract_case_count"] isa Number &&
        row["source_contract_case_count"] > 0, rows)
    nonmutating = all(row -> row["auxiliary_mutation_case_count"] isa Number &&
        row["auxiliary_mutation_case_count"] == 0, rows)
    guard_rows = filter(row -> row["classification"] == "solver_size_guard_skipped", rows)
    resource_rows = filter(row -> row["checkpoint_phase"] == "profile_skipped_resource_budget", rows)
    payload = Dict{String,Any}(
        "summary_version" => "bmopf-sparse-corpus-summary-v1",
        "matrix" => matrix_path,
        "profile_stage" => get(matrix, "profile_stage", "unknown"),
        "profile_max_variables" => get(matrix, "profile_max_variables", nothing),
        "rank_max_dense_entries" => get(matrix, "rank_max_dense_entries", nothing),
        "rows" => rows,
        "checkpoint_phase_counts" => phases,
        "model_variable_count_min" => isempty(variable_counts) ? nothing : minimum(variable_counts),
        "model_variable_count_max" => isempty(variable_counts) ? nothing : maximum(variable_counts),
        "resource_profile_skipped_count" => length(resource_rows),
        "solver_size_guard_skipped_count" => length(guard_rows),
        "trace_or_dense_endpoint_available_count" => count(row ->
            row["solver_trace_status"] in ("ok_solver_trace", "ok_solver_trace_numerical_profile",
                "ok_solver_trace_profile_skipped") &&
            row["classification"] != "solver_size_guard_skipped", rows),
        "readiness" => Dict{String,Any}(
            "all_campaign_rows_completed" => !isempty(rows) && all(row ->
                row["status"] == "ok", rows),
            "all_source_contracts_available" => source_ready,
            "all_auxiliary_models_non_mutating" => nonmutating,
            "large_models_stopped_before_dense_solver_work" => all(row ->
                !(row["model_variable_count"] isa Number && row["model_variable_count"] > 2000) ||
                row["classification"] == "solver_size_guard_skipped", rows),
            "initialization_provenance_available" => all(row ->
                row["initialization_policy"] isa AbstractString, rows),
        ),
        "interpretation" =>
            "This is sparse-first campaign coverage. Resource-budget and size-guard outcomes are explicit boundaries, not solver failures; dense rank and endpoint derivative conclusions require a separate small-fixture campaign.",
    )
    write(output_path, JSON.json(payload))
    println("wrote sparse-first BMOPF corpus summary to $output_path")
end

main()
