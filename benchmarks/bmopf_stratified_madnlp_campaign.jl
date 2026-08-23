#!/usr/bin/env julia

"""Run the objective-bearing stratified BMOPF scaling protocol with MadNLP.

This is the solver-portability companion to
`bmopf_stratified_scaling_campaign.jl`. MadNLP's public callback supplies
cumulative factorization, backsolve, linear-solver time, derivative-evaluation,
and iterative-refinement counters, but no primal iterate coordinates. The
campaign therefore retains matched physical starts and endpoint contracts but
does not claim trace-resolved Jacobian geometry.

Environment controls mirror the Ipopt runner, using the prefix
`NLPDIAGNOSTICS_MADNLP_STRATIFIED_`.
"""

include(joinpath(@__DIR__, "bmopf_stratified_scaling_campaign.jl"))

using MadNLP

const _MADNLP_STRATIFIED_RUNNER_VERSION =
    "bmopf-stratified-madnlp-scaling-campaign-v1"

function madnlp_stratified_main()
    repeats = _env_int(
        "NLPDIAGNOSTICS_MADNLP_STRATIFIED_REPEATS", 5; minimum=2,
    )
    seeds = _parse_seeds(get(
        ENV, "NLPDIAGNOSTICS_MADNLP_STRATIFIED_SEEDS", "11,29",
    ))
    relative_perturbation = _env_float(
        "NLPDIAGNOSTICS_MADNLP_STRATIFIED_PERTURBATION",
        0.01;
        positive=true,
    )
    cases = _selected_cases(get(
        ENV,
        "NLPDIAGNOSTICS_MADNLP_STRATIFIED_CASES",
        "three_phase,transformer",
    ))
    max_iter = _env_int(
        "NLPDIAGNOSTICS_MADNLP_STRATIFIED_MAX_ITER", 150; minimum=1,
    )
    solver_tolerance = _env_float(
        "NLPDIAGNOSTICS_MADNLP_STRATIFIED_TOL", 1.0e-8; positive=true,
    )
    output = abspath(get(
        ENV,
        "NLPDIAGNOSTICS_MADNLP_STRATIFIED_OUTPUT",
        joinpath(
            @__DIR__,
            "..",
            "work",
            "bmopf-stratified-madnlp-scaling-campaign.json",
        ),
    ))
    campaign = run_stratified_campaign(;
        repeats,
        seeds,
        relative_perturbation,
        cases,
        max_iter,
        solver_tolerance,
        optimizer=MadNLP.Optimizer,
        solver=:madnlp,
        solver_name="MadNLP",
        capture_points=false,
        trace_geometry=false,
        runner_version=_MADNLP_STRATIFIED_RUNNER_VERSION,
    )
    mkpath(dirname(output))
    NLPDiagnosticsBenchmarkCommon.write_json(output, _json_safe(campaign))
    stem, extension = splitext(output)
    summary_output = stem * "-summary" * extension
    NLPDiagnosticsBenchmarkCommon.write_json(
        summary_output, _json_safe(_compact_stratified_campaign(campaign)),
    )
    println("wrote MadNLP stratified campaign to $output")
    println("wrote compact campaign summary to $summary_output")
    qualified = campaign["campaign_qualified"]
    println("campaign_qualified=$qualified")
    for record in campaign["cases"]
        case_campaign = record["campaign"]
        case_name = record["case"]
        case_qualified = case_campaign["campaign_qualified"]
        stratum_count = case_campaign["stratum_count"]
        println(
            "$case_name: qualified=$case_qualified " *
            "strata=$stratum_count",
        )
        for (policy, summary) in sort!(
            collect(case_campaign["policies"]); by=first,
        )
            records = summary["record_count_range"]
            minimum_records = get(records, "minimum", nothing)
            maximum_records = get(records, "maximum", nothing)
            println(
                "  $policy records=$minimum_records..$maximum_records",
            )
        end
    end
end

if abspath(PROGRAM_FILE) == abspath(@__FILE__)
    madnlp_stratified_main()
end
