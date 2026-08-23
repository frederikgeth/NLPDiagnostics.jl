#!/usr/bin/env julia

"""Summarize saved real 99-bus phase-only covariance evidence."""

Base.include(@__MODULE__, joinpath(@__DIR__, "common.jl"))
using .NLPDiagnosticsBenchmarkCommon: read_summary, write_json

function metric(covariance, group, field)
    get(get(covariance, "metrics", Dict()), group, Dict()) |> report -> get(report, field, nothing)
end

input = abspath(get(
    ENV,
    "NLPDIAGNOSTICS_REAL_99BUS_CAMPAIGN_INPUT",
    joinpath(@__DIR__, "..", "work", "real-99bus-phase-only-campaign.json"),
))
isfile(input) || error("campaign artifact does not exist: $input")
campaign = read_summary(input; root = "/")
runs = get(campaign, "runs", Any[])
run_summaries = Dict{String,Any}[]
for run in runs
    covariance = get(get(run, "phase_only", Dict()), "covariance", Dict())
    push!(run_summaries, Dict{String,Any}(
        "snapshot" => get(run, "snapshot", nothing),
        "available" => get(covariance, "available", false),
        "equivalence_gate_passed" => get(covariance, "equivalence_gate_passed", false),
        "overall_covariant" => get(covariance, "overall_covariant", false),
        "passed_available_check_count" => get(covariance, "passed_available_check_count", nothing),
        "set_transform_gate_passed" => get(get(covariance, "phase_only_set_transform", Dict()), "acceptance_passed", false),
        "objective_value_max_abs_difference" => metric(covariance, "objective_value", "maximum_absolute_difference"),
        "objective_gradient_max_abs_difference" => metric(covariance, "objective_gradient", "maximum_absolute_difference"),
        "constraint_residual_max_abs_difference" => metric(covariance, "constraint_residuals", "maximum_absolute_difference"),
        "physical_point_max_abs_difference" => metric(covariance, "physical_point", "maximum_absolute_difference"),
        "physical_jacobian_max_abs_difference" => metric(covariance, "physical_jacobian", "maximum_absolute_difference"),
        "physical_jacobian_max_relative_difference" => metric(covariance, "physical_jacobian", "maximum_relative_difference"),
        "physical_jacobian_passed" => metric(covariance, "physical_jacobian", "passed"),
        "physical_jacobian_exact_sparse_support_agrees" => metric(covariance, "physical_jacobian", "exact_sparse_support_agrees"),
        "physical_rank_available" => get(get(get(covariance, "metrics", Dict()), "physical_jacobian", Dict()), "physical_rank_available", false),
        "physical_rank_reason" => get(get(get(covariance, "metrics", Dict()), "physical_jacobian", Dict()), "physical_rank_reason", nothing),
        "physical_solver_kkt_accepted" => get(get(get(run, "phase_only", Dict()), "physical_solver_kkt", Dict()), "acceptance_passed", nothing),
    ))
end
finite_values(field) = Float64[Float64(run[field]) for run in run_summaries if run[field] isa Real]
summary = Dict{String,Any}(
    "run_count" => length(run_summaries),
    "covariance_available_count" => count(run -> run["available"] === true, run_summaries),
    "equivalence_gate_passed_count" => count(run -> run["equivalence_gate_passed"] === true, run_summaries),
    "overall_covariant_count" => count(run -> run["overall_covariant"] === true, run_summaries),
    "set_transform_gate_passed_count" => count(run -> run["set_transform_gate_passed"] === true, run_summaries),
    "seven_check_pass_count" => count(run -> run["passed_available_check_count"] == 7, run_summaries),
    "physical_rank_available_count" => count(run -> run["physical_rank_available"] === true, run_summaries),
    "maximum_objective_value_difference" => maximum(finite_values("objective_value_max_abs_difference")),
    "maximum_objective_gradient_difference" => maximum(finite_values("objective_gradient_max_abs_difference")),
    "maximum_constraint_residual_difference" => maximum(finite_values("constraint_residual_max_abs_difference")),
    "maximum_physical_point_difference" => maximum(finite_values("physical_point_max_abs_difference")),
    "maximum_physical_jacobian_difference" => maximum(finite_values("physical_jacobian_max_abs_difference")),
    "maximum_physical_jacobian_relative_difference" => maximum(finite_values("physical_jacobian_max_relative_difference")),
    "qualification" => "same-point coordinate, scalar-set, objective, residual, and semantic Jacobian covariance evidence; not inequality-multiplier covariance, physical rank certification, solver merit, or global optimality",
)
output = abspath(get(
    ENV,
    "NLPDIAGNOSTICS_REAL_99BUS_COVARIANCE_SUMMARY_OUTPUT",
    joinpath(@__DIR__, "..", "work", "real-99bus-phase-only-covariance-summary.json"),
))
mkpath(dirname(output))
write_json(output, Dict(
    "schema_version" => "nlpdiagnostics-real-99bus-phase-only-covariance-summary-v1",
    "source" => Dict(
        "runner" => basename(@__FILE__),
        "campaign_artifact" => input,
        "covariance_report_version" => "bmopf-phase-only-covariance-v1",
        "relative_tolerance" => 1.0e-7,
        "absolute_tolerance" => 1.0e-8,
    ),
    "summary" => summary,
    "runs" => run_summaries,
))
println("wrote real 99-bus covariance summary to $output")
