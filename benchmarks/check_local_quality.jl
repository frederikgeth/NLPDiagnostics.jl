#!/usr/bin/env julia

"""Run the repository's read-only local quality baseline.

This runner does not install packages, invoke CI, or rewrite generated
artifacts. It checks whitespace, API-tier inventory consistency, consolidation
schema coverage, release-gate shape, and the reviewed local quality policy in
the known local environment.
"""

include(joinpath(@__DIR__, "common.jl"))
using .NLPDiagnosticsBenchmarkCommon

const ROOT = repo_root()
const OUTPUT = abspath(isempty(ARGS) ?
    joinpath("/tmp", "nlpdiagnostics-local-quality.json") : ARGS[1])

function _git_diff_check()
    try
        output = read(`git -C $ROOT diff --check`, String)
        return (passed = true, detail = output)
    catch error
        return (passed = false, detail = sprint(showerror, error))
    end
end

function _check_api_tiers()
    summary = read_summary("docs/api_tier_inventory_summary.json")
    counts = get(summary, "counts", Dict{String,Any}())
    stable = get(summary, "stable_facade", Dict{String,Any}())
    legacy = get(summary, "legacy_root_exports", Any[])
    policy = get(summary, "policy", Dict{String,Any}())
    checks = Dict{String,Any}(
        "stable_export_count_matches" =>
            get(counts, "stable_export_count", -1) ==
            length(get(stable, "exports", Any[])),
        "legacy_root_count_matches" =>
            get(counts, "root_only_count", -1) == length(legacy),
        "policy_review_artifact_present" => isfile(joinpath(
            ROOT, get(policy, "review_artifact", ""),
        )),
    )
    return checks
end

function _check_consolidation()
    summary = read_summary("docs/api_test_benchmark_consolidation_summary.json")
    boundaries = get(summary, "module_boundaries", Dict{String,Any}())
    schemas = get(summary, "benchmark_schema_inventory", Dict{String,Any}())
    benchmark_files = filter(
        path -> basename(path) != "common.jl",
        recursive_files(joinpath(ROOT, "benchmarks"), ".jl"),
    )
    actual_non_helpers = sort([
        relpath(path, ROOT) for path in benchmark_files
        if !occursin("using .NLPDiagnosticsBenchmarkCommon", read_text(path)) &&
           !occursin("NLPDiagnosticsBenchmarkCommon.", read_text(path))
    ])
    recorded_exemptions = sort([
        String(get(entry, "path", ""))
        for entry in get(boundaries, "shared_benchmark_helper_exemptions", Any[])
        if entry isa AbstractDict
    ])
    return Dict{String,Any}(
        "helper_count_matches_inventory" =>
            get(boundaries, "shared_benchmark_helper_user_count", -1) ==
            length(get(boundaries, "shared_benchmark_helper_users", Any[])),
        "helper_exemptions_match_inventory" =>
            actual_non_helpers == recorded_exemptions,
        "unclassified_non_helper_paths_absent" =>
            isempty(get(boundaries, "unclassified_non_helper_benchmark_paths", Any[])),
        "schema_errors_absent" => isempty(get(schemas, "schema_errors", Any[])),
        "json_without_schema_absent" =>
            get(schemas, "json_without_schema_count", -1) == 0,
    )
end

function _check_release_gate()
    summary = read_summary("docs/calibration_release_gate_summary.json")
    return Dict{String,Any}(
        "release_ready_field_present" => haskey(summary, "release_ready"),
        "blocking_gate_count_present" =>
            get(summary, "blocking_gate_count", nothing) isa Integer,
    )
end

function _check_quality_policy()
    policy = read_summary("docs/quality_policy.json")
    checks = get(policy, "checks", Any[])
    expected = Set([
        "diff_whitespace",
        "package_regression",
        "consolidation_inventory",
        "local_quality_baseline",
        "documentation_examples",
        "aqua",
        "jet",
    ])
    actual = Set(String(get(check, "id", "")) for check in checks if check isa AbstractDict)
    active_valid = all(
        get(check, "status", nothing) == "active" &&
        get(check, "command", nothing) isa AbstractString &&
        !isempty(get(check, "command", ""))
        for check in checks if check isa AbstractDict && get(check, "status", nothing) == "active"
    )
    deferred_valid = all(
        get(check, "status", nothing) == "deferred" &&
        get(check, "command", nothing) === nothing &&
        get(check, "reason", nothing) isa AbstractString &&
        !isempty(get(check, "reason", ""))
        for check in checks if check isa AbstractDict && get(check, "status", nothing) == "deferred"
    )
    return Dict{String,Any}(
        "schema_version_present" => haskey(policy, "schema_version"),
        "scope_is_local" => get(policy, "scope", nothing) == "known_local_environment",
        "ci_execution_explicitly_false" => get(policy, "ci_execution", nothing) === false,
        "expected_check_ids_match" => actual == expected,
        "active_checks_have_commands" => active_valid,
        "deferred_checks_have_reasons" => deferred_valid,
    )
end

function main()
    diff_check = _git_diff_check()
    checks = Dict{String,Any}(
        "git_diff_check" => diff_check.passed,
        "api_tiers" => _check_api_tiers(),
        "consolidation" => _check_consolidation(),
        "release_gate_shape" => _check_release_gate(),
        "quality_policy" => _check_quality_policy(),
    )
    function all_passed(value)
        value isa Bool && return value
        value isa AbstractDict && return all(all_passed, values(value))
        return true
    end
    result = Dict{String,Any}(
        "schema_version" => "nlpdiagnostics-local-quality-v1",
        "repository" => ROOT,
        "git_revision" => git_revision(ROOT),
        "git_branch" => git_branch(ROOT),
        "git_status_entries" => git_status_entries(ROOT),
        "checks" => checks,
        "ready" => all_passed(checks),
        "interpretation" =>
            "read-only local quality baseline; does not replace CI or scientific calibration",
    )
    write_json(OUTPUT, result)
    println("local_quality_ready=$(result["ready"])")
    println("wrote local quality summary to $OUTPUT")
    result["ready"] || exit(1)
end

main()
