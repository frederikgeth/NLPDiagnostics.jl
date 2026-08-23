#!/usr/bin/env julia

"""Run a paired BMOPF smoke campaign with two tangent-coordinate policies.

This launcher keeps fixture selection, evaluation-point policy, dense budget,
and environment identical between children. It then summarizes both runs and
produces `tangent_policy_comparison.json` for local calibration evidence.
"""

using JSON

Base.include(@__MODULE__, joinpath(@__DIR__, "common.jl"))
using .NLPDiagnosticsBenchmarkCommon: write_json

function _policies()
    values = unique(filter(!isempty, strip.(split(get(
        ENV, "NLPDIAGNOSTICS_BMOPF_TANGENT_CALIBRATION_POLICIES", "none,fixed",
    ), ','))))
    isempty(values) && error("tangent calibration selected no policies")
    all(value -> value in ("none", "fixed"), values) || error(
        "tangent calibration policies must be none or fixed",
    )
    length(values) == 2 || error(
        "tangent calibration requires two distinct policies (normally none,fixed)",
    )
    return values
end

function _project()
    raw = get(ENV, "NLPDIAGNOSTICS_BMOPF_CALIBRATION_PROJECT", "")
    isempty(strip(raw)) || return raw
    active = try Base.active_project() catch; nothing end
    return isnothing(active) ? normpath(joinpath(@__DIR__, "..")) : active
end

function _child_environment(root, output_dir, policy)
    child = copy(ENV)
    repository_root = normpath(joinpath(@__DIR__, ".."))
    child["JULIA_LOAD_PATH"] = string(
        repository_root, ':', get(child, "JULIA_LOAD_PATH", "@"),
    )
    child["NLPDIAGNOSTICS_BMOPF_FIXTURE_ROOT"] = root
    child["NLPDIAGNOSTICS_BMOPF_OUTPUT_DIR"] = output_dir
    child["NLPDIAGNOSTICS_BMOPF_EXPECTED_MODE_TANGENT_POLICY"] = policy
    return child
end

function _run_child(script, project, environment)
    compiled_modules = get(
        ENV, "NLPDIAGNOSTICS_BMOPF_TANGENT_CALIBRATION_COMPILED_MODULES", "no",
    )
    compiled_modules in ("yes", "no") || error(
        "NLPDIAGNOSTICS_BMOPF_TANGENT_CALIBRATION_COMPILED_MODULES must be yes or no",
    )
    command = `$(Base.julia_cmd()) --startup-file=no --compiled-modules=$compiled_modules --project=$project $script`
    run(setenv(command, environment))
end

function main()
    root = get(ENV, "NLPDIAGNOSTICS_BMOPF_FIXTURE_ROOT", "")
    isempty(root) && error("Set NLPDIAGNOSTICS_BMOPF_FIXTURE_ROOT first")
    root = abspath(root)
    isdir(root) || error("fixture root does not exist: $root")
    output_root = abspath(get(
        ENV, "NLPDIAGNOSTICS_BMOPF_TANGENT_CALIBRATION_OUTPUT_DIR",
        joinpath(pwd(), "bmopf-tangent-calibration-results"),
    ))
    mkpath(output_root)
    project = _project()
    smoke_script = joinpath(@__DIR__, "bmopf_smoke.jl")
    summary_script = joinpath(@__DIR__, "summarize_bmopf_multiconductor_smoke.jl")
    comparison_script = joinpath(@__DIR__, "compare_bmopf_tangent_policies.jl")
    policies = _policies()
    summary_paths = String[]
    for policy in policies
        output_dir = joinpath(output_root, policy)
        mkpath(output_dir)
        _run_child(smoke_script, project, _child_environment(root, output_dir, policy))
        index_path = joinpath(output_dir, "index.json")
        isfile(index_path) || error("smoke child did not produce $index_path")
        summary_path = joinpath(output_dir, "summary.json")
        compiled_modules = get(
            ENV, "NLPDIAGNOSTICS_BMOPF_TANGENT_CALIBRATION_COMPILED_MODULES", "no",
        )
        command = `$(Base.julia_cmd()) --startup-file=no --compiled-modules=$compiled_modules --project=$project $summary_script $index_path $summary_path`
        run(setenv(command, _child_environment(root, output_dir, policy)))
        push!(summary_paths, summary_path)
    end
    comparison_path = joinpath(output_root, "tangent_policy_comparison.json")
    compiled_modules = get(
        ENV, "NLPDIAGNOSTICS_BMOPF_TANGENT_CALIBRATION_COMPILED_MODULES", "no",
    )
    command = `$(Base.julia_cmd()) --startup-file=no --compiled-modules=$compiled_modules --project=$project $comparison_script $(summary_paths[1]) $(summary_paths[2]) $comparison_path`
    run(setenv(command, _child_environment(root, output_root, "none")))
    manifest = Dict{String,Any}(
        "report_version" => "bmopf-tangent-policy-calibration-launch-v1",
        "fixture_root" => root,
        "output_root" => output_root,
        "project" => project,
        "policies" => policies,
        "summary_paths" => summary_paths,
        "comparison_path" => comparison_path,
        "point_policy" => get(ENV, "NLPDIAGNOSTICS_BMOPF_POINT_POLICY", "initialization"),
        "rank_max_dense_entries" => get(ENV, "NLPDIAGNOSTICS_BMOPF_RANK_MAX_DENSE_ENTRIES", "250000"),
        "compiled_modules" => compiled_modules,
        "cases" => get(ENV, "NLPDIAGNOSTICS_BMOPF_CASES", ""),
        "interpretation" => "Paired tangent-policy campaign; changes remain local calibration evidence.",
    )
    manifest_path = joinpath(output_root, "calibration.json")
    write_json(manifest_path, manifest)
    println("wrote BMOPF tangent calibration manifest to $manifest_path")
end

main()
