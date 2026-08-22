#!/usr/bin/env julia

"""Measure per-row complementarity tolerance margins for 30-bus IBR rows."""

using NLPDiagnostics
using BMOPFTools
using JuMP
using Ipopt
using JSON

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
    all(relative -> isfile(joinpath(root, relative)), cases) || error("one or more selected snapshots are missing")
    return cases
end

function selected_tolerances()
    raw = get(ENV, "NLPDIAGNOSTICS_BMOPF_30BUS_TOLERANCE_MARGIN_VALUES", "1e-5,1.01e-5,1.05e-5,1.1e-5")
    values = sort!(unique(parse.(Float64, filter(!isempty, strip.(split(raw, ','))))))
    isempty(values) && error("tolerance list must not be empty")
    all(isfinite, values) && all(>=(0), values) || error("tolerances must be finite and nonnegative")
    return values
end

function descriptor_family(labels, index, key)
    descriptor = get(labels, index, get(labels, string(index), Dict()))
    descriptor isa AbstractDict ? string(get(descriptor, key, get(descriptor, "family_label", "unclassified"))) : string(descriptor)
end

function run_case(root, relative, max_iter, tolerances, zero_tolerance)
    network = BMOPFTools.parse_bmopf(joinpath(root, relative))
    context = BMOPFTools.build_opf_model(deepcopy(network); optimizer=Ipopt.Optimizer, add_objective=true)
    BMOPFTools.enforce_kcl!(context)
    model = BMOPFTools.opf_model(context)
    JuMP.set_silent(model)
    JuMP.set_optimizer_attribute(model, "max_iter", max_iter)
    JuMP.optimize!(model)
    point = NLPDiagnostics.solver_result_point(model; label="30bus-tolerance-margin-result")
    point isa NLPDiagnostics.EvaluationPoint || error("solver result point unavailable")
    evaluation = NLPDiagnostics.evaluate_numerical(JuMP.backend(model), point)
    dual_snapshot = NLPDiagnostics.solver_dual_snapshot(model, evaluation)
    side_bounds = Dict{Tuple{Int,String},Any}()
    for side in dual_snapshot.sides
        side_bounds[(side.row, string(side.side))] = side.bound
    end
    row_labels = NLPDiagnostics.bmopf_constraint_semantic_row_map(context, evaluation)
    target_rows = findall(row -> descriptor_family(row_labels, row, "constraint_family") == "ibr_p_upper", eachindex(evaluation.constraint_values))
    isempty(target_rows) && error("ibr_p_upper rows unavailable")
    scaling = NLPDiagnostics.bmopf_diagonal_scaling_map(context, evaluation)
    quantity_tolerances = Dict(quantity => 1.0 for quantity in unique(scaling["constraint_quantities"]))
    kkt = NLPDiagnostics.bmopf_physical_solver_kkt_report(
        context, model, evaluation;
        semantic_blocks=false,
        quantity_feasibility_absolute_tolerances=quantity_tolerances,
        stationarity_default_absolute_tolerance=1.0e-5,
        dual_default_absolute_tolerance=1.0e-5,
        complementarity_default_absolute_tolerance=first(tolerances),
    )
    sides = get(get(kkt, "complementarity", Dict()), "sides", Dict())
    side_by_row = Dict{Int,Any}()
    for side in values(sides)
        row = get(side, "row", nothing)
        string(get(side, "side", "")) == "upper" && row isa Integer && (side_by_row[Int(row)] = side)
    end
    rows = Dict{String,Any}[]
    for row in target_rows
        side = get(side_by_row, row, Dict())
        residual = get(side, "complementarity_residual", nothing)
        residual isa Real || error("complementarity residual unavailable for target row $row")
        bound = get(side_bounds, (row, "upper"), nothing)
        bound isa Real || error("upper bound unavailable for target row $row")
        push!(rows, Dict{String,Any}(
            "row" => row,
            "bound_regime" => abs(Float64(bound)) <= zero_tolerance ? "zero_bound" : "positive_bound",
            "bound" => Float64(bound),
            "complementarity_residual" => Float64(residual),
            "margin_at_1e-5" => 1.0e-5 - Float64(residual),
        ))
    end
    tolerance_curve = Dict{String,Any}()
    for tolerance in tolerances
        passed = filter(row -> row["complementarity_residual"] <= tolerance, rows)
        by_regime = Dict{String,Int}()
        for current in ("zero_bound", "positive_bound")
            by_regime[current] = count(row -> row["bound_regime"] == current && row["complementarity_residual"] <= tolerance, rows)
        end
        tolerance_curve[string(tolerance)] = Dict{String,Any}(
            "passed_row_count" => length(passed),
            "failed_row_count" => length(rows) - length(passed),
            "passed_row_count_by_bound_regime" => by_regime,
        )
    end
    residuals = Float64[row["complementarity_residual"] for row in rows]
    margins = Float64[row["margin_at_1e-5"] for row in rows]
    return Dict{String,Any}(
        "snapshot" => relative,
        "termination_status" => string(JuMP.termination_status(model)),
        "physical_kkt_acceptance_passed_at_first_tolerance" => get(kkt, "acceptance_passed", nothing),
        "target_row_count" => length(rows),
        "complementarity_residual_range" => [minimum(residuals), maximum(residuals)],
        "margin_at_1e-5_range" => [minimum(margins), maximum(margins)],
        "required_tolerance_max" => maximum(residuals),
        "tolerance_curve" => tolerance_curve,
        "rows" => rows,
        "qualification" => "per-row tolerance margin ledger; not a causal explanation",
    )
end

root = abspath(get(ENV, "NLPDIAGNOSTICS_BMOPF_BENCHMARK_ROOT", DEFAULT_ROOT))
isdir(root) || error("benchmark root does not exist: $root")
max_iter = parse(Int, get(ENV, "NLPDIAGNOSTICS_BMOPF_TOLERANCE_MARGIN_MAX_ITER", "80"))
zero_tolerance = parse(Float64, get(ENV, "NLPDIAGNOSTICS_BMOPF_TOLERANCE_MARGIN_ZERO_TOLERANCE", "1e-12"))
tolerances = selected_tolerances()
max_iter > 0 || error("max_iter must be positive")
zero_tolerance >= 0 || error("zero tolerance must be nonnegative")
results = Dict{String,Any}[]
for relative in selected_cases(root)
    try
        push!(results, run_case(root, relative, max_iter, tolerances, zero_tolerance))
    catch error
        push!(results, Dict{String,Any}("snapshot" => relative, "error" => sprint(showerror, error)))
    end
end
output = abspath(get(ENV, "NLPDIAGNOSTICS_BMOPF_TOLERANCE_MARGIN_OUTPUT", joinpath(@__DIR__, "..", "work", "bmopf-30bus-ibr-p-upper-tolerance-margin.json")))
mkpath(dirname(output))
write(output, JSON.json(Dict(
    "schema_version" => "nlpdiagnostics-bmopf-30bus-ibr-p-upper-tolerance-margin-v1",
    "source" => Dict(
        "runner" => basename(@__FILE__),
        "local_environment" => abspath(joinpath(@__DIR__, "..", "work", "benchmark-environment")),
        "solver" => "Ipopt",
        "max_iter" => max_iter,
        "tolerances" => tolerances,
        "zero_bound_tolerance" => zero_tolerance,
        "row_family" => "ibr_p_upper",
    ),
    "cases" => results,
)))
println("wrote 30-bus IBR upper tolerance margin to $output")
