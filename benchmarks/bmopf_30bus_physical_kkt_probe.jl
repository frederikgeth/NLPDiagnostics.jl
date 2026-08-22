#!/usr/bin/env julia

"""Run a bounded physical-KKT probe on selected 30-bus BMOPF snapshots."""

using BMOPFTools
using Ipopt
using JuMP
using JSON
using NLPDiagnostics

const DEFAULT_ROOT = "/Users/uqfgeth/Documents/GitHub/BMOPFDraftData/benchmarks"
const DEFAULT_CASES = [
    "ENWLsnapshots/30bus_LN/30bus_LN_t01_0800.bmopf.json",
    "ENWLsnapshots/30bus_LN/30bus_LN_t13_1400.bmopf.json",
    "ENWLsnapshots/30bus_LG/30bus_LG_t01_0800.bmopf.json",
    "ENWLsnapshots/30bus_LG/30bus_LG_t13_1400.bmopf.json",
]

function selected_cases(root)
    raw = filter(!isempty, strip.(split(
        get(ENV, "NLPDIAGNOSTICS_BMOPF_30BUS_KKT_CASES", ""), ',';
    )))
    cases = isempty(raw) ? DEFAULT_CASES : raw
    for relative in cases
        isfile(joinpath(root, relative)) || error("snapshot is missing: $relative")
    end
    return cases
end

function safe_value(callback)
    try
        return callback()
    catch
        return nothing
    end
end

function complementarity_tolerances()
    raw = get(
        ENV,
        "NLPDIAGNOSTICS_BMOPF_30BUS_KKT_COMPLEMENTARITY_TOLERANCES",
        "1.0e-5,1.05e-5,1.1e-5,1.2e-5",
    )
    values = sort!(unique(parse.(Float64, filter(!isempty, strip.(split(raw, ','))))))
    isempty(values) && error("complementarity tolerance list must not be empty")
    all(value -> isfinite(value) && value >= 0, values) ||
        error("complementarity tolerances must be finite and nonnegative")
    return values
end

function kkt_report(context, model, evaluation, quantity_tolerances, complementarity_tolerance)
    return NLPDiagnostics.bmopf_physical_solver_kkt_report(
        context,
        model,
        evaluation;
        semantic_blocks=false,
        quantity_feasibility_absolute_tolerances=quantity_tolerances,
        stationarity_default_absolute_tolerance=1.0e-5,
        dual_default_absolute_tolerance=1.0e-5,
        complementarity_default_absolute_tolerance=complementarity_tolerance,
    )
end

function complementarity_tolerance_record(report, tolerance)
    complementarity = get(report, "complementarity", Dict())
    sides = get(complementarity, "sides", Dict())
    attribution = get(
        get(get(report, "semantic_attribution", Dict()), "complementarity", Dict()),
        "records",
        Dict(),
    )
    failed_sides = sort!(String[
        string(key) for (key, side) in pairs(sides)
        if !(get(side, "complementarity_residual", nothing) isa Real) ||
            !isfinite(Float64(get(side, "complementarity_residual", NaN))) ||
            Float64(get(side, "complementarity_residual", NaN)) > tolerance
    ])
    failed_constraint_families = sort!(unique(String[
        string(get(get(attribution, key, Dict()), "constraint_family", "unknown"))
        for key in failed_sides
    ]))
    failed_side_metrics = Dict{String,Any}()
    for key in failed_sides
        side = get(sides, key, Dict())
        failed_side_metrics[key] = Dict{String,Any}(
            field => get(side, field, nothing)
            for field in (
                "physical_slack",
                "model_slack",
                "physical_multiplier",
                "model_multiplier",
                "complementarity_residual",
                "residual_scale",
            )
        )
    end
    return Dict{String,Any}(
        "physical_kkt_acceptance_passed" => get(
            report, "acceptance_passed", nothing,
        ),
        "complementarity_acceptance_passed" => get(
            complementarity, "acceptance_passed", nothing,
        ),
        "passed_side_count" => get(
            complementarity, "passed_side_count", nothing,
        ),
        "failed_side_count" => length(failed_sides),
        "failed_sides" => failed_sides,
        "failed_constraint_families" => failed_constraint_families,
        "failed_side_metrics" => failed_side_metrics,
    )
end

function run_case(root, relative, tolerances)
    network = BMOPFTools.parse_bmopf(joinpath(root, relative))
    context = BMOPFTools.build_opf_model(
        deepcopy(network);
        optimizer=Ipopt.Optimizer,
        add_objective=true,
    )
    BMOPFTools.enforce_kcl!(context)
    model = BMOPFTools.opf_model(context)
    JuMP.set_silent(model)
    max_iter = parse(Int, get(ENV, "NLPDIAGNOSTICS_BMOPF_30BUS_KKT_MAX_ITER", "100"))
    JuMP.set_optimizer_attribute(model, "max_iter", max_iter)
    JuMP.optimize!(model)
    point = NLPDiagnostics.solver_result_point(model; label="30bus-kkt-solver-result")
    point isa NLPDiagnostics.EvaluationPoint || error("solver result point unavailable")
    evaluation = NLPDiagnostics.evaluate_numerical(JuMP.backend(model), point)
    map = NLPDiagnostics.bmopf_diagonal_scaling_map(context, evaluation)
    quantity_tolerances = Dict(
        quantity => 1.0 for quantity in unique(map["constraint_quantities"])
    )
    kkt = kkt_report(
        context, model, evaluation, quantity_tolerances, first(tolerances),
    )
    tolerance_curve = Dict{String,Any}()
    for tolerance in tolerances
        curve_report = kkt_report(
            context, model, evaluation, quantity_tolerances, tolerance,
        )
        tolerance_curve[string(tolerance)] = complementarity_tolerance_record(
            curve_report, tolerance,
        )
    end
    complementarity = get(kkt, "complementarity", Dict())
    complementarity_sides = values(get(complementarity, "sides", Dict()))
    maximum_complementarity_residual = safe_value(() -> maximum(
        Float64[
            Float64(get(side, "complementarity_residual", NaN))
            for side in complementarity_sides
            if get(side, "complementarity_residual", nothing) isa Real
        ],
    ))
    return Dict{String,Any}(
        "snapshot" => relative,
        "termination_status" => string(JuMP.termination_status(model)),
        "primal_status" => string(JuMP.primal_status(model)),
        "variable_count" => length(evaluation.point.variables),
        "physical_kkt_available" => get(kkt, "available", false),
        "physical_kkt_acceptance_passed" => get(kkt, "acceptance_passed", nothing),
        "stationarity_acceptance_passed" => get(
            get(kkt, "stationarity", Dict()), "acceptance_passed", nothing,
        ),
        "complementarity_acceptance_passed" => get(
            complementarity, "acceptance_passed", nothing,
        ),
        "complementarity_side_count" => get(complementarity, "side_count", nothing),
        "complementarity_passed_side_count" => get(
            complementarity, "passed_side_count", nothing,
        ),
        "maximum_complementarity_residual" => maximum_complementarity_residual,
        "quantity_tolerance" => 1.0,
        "stationarity_tolerance" => 1.0e-5,
        "dual_tolerance" => 1.0e-5,
        "complementarity_tolerance" => first(tolerances),
        "complementarity_acceptance_by_tolerance" => tolerance_curve,
    )
end

root = abspath(get(ENV, "NLPDIAGNOSTICS_BMOPF_BENCHMARK_ROOT", DEFAULT_ROOT))
isdir(root) || error("benchmark root does not exist: $root")
complementarity_tolerance_values = complementarity_tolerances()
results = Dict{String,Any}[]
for relative in selected_cases(root)
    try
        push!(results, run_case(root, relative, complementarity_tolerance_values))
    catch error
        push!(results, Dict{String,Any}(
            "snapshot" => relative,
            "physical_kkt_available" => false,
            "error" => sprint(showerror, error),
        ))
    end
end
output = abspath(get(
    ENV,
    "NLPDIAGNOSTICS_BMOPF_30BUS_KKT_OUTPUT",
    joinpath(@__DIR__, "..", "work", "bmopf-30bus-physical-kkt-probe.json"),
))
mkpath(dirname(output))
write(output, JSON.json(Dict(
    "schema_version" => "nlpdiagnostics-bmopf-30bus-physical-kkt-probe-v3",
    "source" => Dict(
        "runner" => basename(@__FILE__),
        "local_environment" => abspath(joinpath(@__DIR__, "..", "work", "benchmark-environment")),
        "quantity_tolerance" => 1.0,
        "stationarity_tolerance" => 1.0e-5,
        "dual_tolerance" => 1.0e-5,
        "complementarity_tolerance" => first(complementarity_tolerance_values),
        "complementarity_tolerances_evaluated" => complementarity_tolerance_values,
    ),
    "cases" => results,
)))
println("wrote 30-bus physical KKT probe to $output")
