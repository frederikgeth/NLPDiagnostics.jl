#!/usr/bin/env julia

"""Run a bounded Ipopt max-iteration matrix for the 30-bus IBR upper row."""

using NLPDiagnostics
using BMOPFTools
using JuMP
using Ipopt
Base.include(@__MODULE__, joinpath(@__DIR__, "common.jl"))
using .NLPDiagnosticsBenchmarkCommon: write_json

const DEFAULT_ROOT = joinpath(@__DIR__, "..", "..", "BMOPFDraftData", "benchmarks")
const DEFAULT_CASES = [
    "ENWLsnapshots/30bus_LN/30bus_LN_t01_0800.bmopf.json",
    "ENWLsnapshots/30bus_LN/30bus_LN_t13_1400.bmopf.json",
    "ENWLsnapshots/30bus_LG/30bus_LG_t01_0800.bmopf.json",
    "ENWLsnapshots/30bus_LG/30bus_LG_t13_1400.bmopf.json",
]

function selected_cases(root)
    raw = get(ENV, "NLPDIAGNOSTICS_BMOPF_30BUS_CASES", "")
    cases = isempty(strip(raw)) ? DEFAULT_CASES : filter(!isempty, strip.(split(raw, ',')))
    all(relative -> isfile(joinpath(root, relative)), cases) ||
        error("one or more selected snapshots are missing")
    return cases
end

function iteration_budgets()
    raw = get(ENV, "NLPDIAGNOSTICS_BMOPF_30BUS_MAX_ITERS", "10,20,40,80")
    values = sort!(unique(parse.(Int, filter(!isempty, strip.(split(raw, ','))))))
    isempty(values) && error("max-iteration list must not be empty")
    all(value -> value > 0, values) || error("max-iteration budgets must be positive")
    return values
end

function max_complementarity(report)
    sides = values(get(get(report, "complementarity", Dict()), "sides", Dict()))
    residuals = Float64[
        Float64(get(side, "complementarity_residual", NaN))
        for side in sides
        if get(side, "complementarity_residual", nothing) isa Real
    ]
    isempty(residuals) ? nothing : maximum(residuals)
end

function run_case(root, relative, max_iter)
    network = BMOPFTools.parse_bmopf(joinpath(root, relative))
    context = BMOPFTools.build_opf_model(
        deepcopy(network); optimizer=Ipopt.Optimizer, add_objective=true,
    )
    BMOPFTools.enforce_kcl!(context)
    model = BMOPFTools.opf_model(context)
    JuMP.set_silent(model)
    JuMP.set_optimizer_attribute(model, "max_iter", max_iter)
    JuMP.optimize!(model)
    point = NLPDiagnostics.solver_result_point(model; label="30bus-budget-result")
    point isa NLPDiagnostics.EvaluationPoint || error("solver result point unavailable")
    evaluation = NLPDiagnostics.evaluate_numerical(JuMP.backend(model), point)
    map = NLPDiagnostics.bmopf_diagonal_scaling_map(context, evaluation)
    quantity_tolerances = Dict(
        quantity => 1.0 for quantity in unique(map["constraint_quantities"])
    )
    kkt = NLPDiagnostics.bmopf_physical_solver_kkt_report(
        context,
        model,
        evaluation;
        semantic_blocks=false,
        quantity_feasibility_absolute_tolerances=quantity_tolerances,
        stationarity_default_absolute_tolerance=1.0e-5,
        dual_default_absolute_tolerance=1.0e-5,
        complementarity_default_absolute_tolerance=1.0e-5,
    )
    residuals = get(get(kkt, "primal_feasibility", Dict()), "residuals", Dict())
    ibr_residuals = Dict(
        string(key) => get(value, "violation", nothing)
        for (key, value) in residuals
        if occursin("ibr_p_upper", string(key))
    )
    finite_ibr = Float64[value for value in values(ibr_residuals) if value isa Real]
    return Dict{String,Any}(
        "snapshot" => relative,
        "max_iter" => max_iter,
        "termination_status" => string(JuMP.termination_status(model)),
        "primal_status" => string(JuMP.primal_status(model)),
        "variable_count" => length(evaluation.point.variables),
        "physical_kkt_acceptance_passed" => get(kkt, "acceptance_passed", nothing),
        "stationarity_acceptance_passed" => get(
            get(kkt, "stationarity", Dict()), "acceptance_passed", nothing,
        ),
        "complementarity_acceptance_passed" => get(
            get(kkt, "complementarity", Dict()), "acceptance_passed", nothing,
        ),
        "maximum_complementarity_residual" => max_complementarity(kkt),
        "ibr_p_upper_residual_count" => length(ibr_residuals),
        "ibr_p_upper_physical_violation_max" =>
            isempty(finite_ibr) ? nothing : maximum(finite_ibr),
        "ibr_p_upper_physical_violation_min" =>
            isempty(finite_ibr) ? nothing : minimum(finite_ibr),
    )
end

root = abspath(get(ENV, "NLPDIAGNOSTICS_BMOPF_BENCHMARK_ROOT", DEFAULT_ROOT))
isdir(root) || error("benchmark root does not exist: $root")
budgets = iteration_budgets()
results = Dict{String,Any}[]
for relative in selected_cases(root)
    for max_iter in budgets
        try
            push!(results, run_case(root, relative, max_iter))
        catch error
            push!(results, Dict{String,Any}(
                "snapshot" => relative,
                "max_iter" => max_iter,
                "physical_kkt_available" => false,
                "error" => sprint(showerror, error),
            ))
        end
    end
end
output = abspath(get(
    ENV,
    "NLPDIAGNOSTICS_BMOPF_30BUS_BUDGET_OUTPUT",
    joinpath(@__DIR__, "..", "work", "bmopf-30bus-ibr-p-upper-budget-matrix.json"),
))
mkpath(dirname(output))
write_json(output, Dict(
    "schema_version" => "nlpdiagnostics-bmopf-30bus-ibr-p-upper-budget-matrix-v1",
    "source" => Dict(
        "runner" => basename(@__FILE__),
        "local_environment" => abspath(joinpath(@__DIR__, "..", "work", "benchmark-environment")),
        "solver" => "Ipopt",
        "budgets" => budgets,
        "quantity_tolerance" => 1.0,
        "stationarity_tolerance" => 1.0e-5,
        "dual_tolerance" => 1.0e-5,
        "complementarity_tolerance" => 1.0e-5,
    ),
    "cases" => results,
))
println("wrote 30-bus IBR upper budget matrix to $output")
