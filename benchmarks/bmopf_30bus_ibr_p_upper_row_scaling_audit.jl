#!/usr/bin/env julia

"""Audit model-to-physical scaling for each 30-bus `ibr_p_upper` row."""

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

function descriptor_family(labels, index, key)
    descriptor = get(labels, index, get(labels, string(index), Dict()))
    descriptor isa AbstractDict ? string(get(descriptor, key, get(descriptor, "family_label", "unclassified"))) : string(descriptor)
end

function run_case(root, relative, max_iter)
    network = BMOPFTools.parse_bmopf(joinpath(root, relative))
    context = BMOPFTools.build_opf_model(deepcopy(network); optimizer=Ipopt.Optimizer, add_objective=true)
    BMOPFTools.enforce_kcl!(context)
    model = BMOPFTools.opf_model(context)
    JuMP.set_silent(model)
    JuMP.set_optimizer_attribute(model, "max_iter", max_iter)
    JuMP.optimize!(model)
    point = NLPDiagnostics.solver_result_point(model; label="30bus-row-scaling-result")
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
    scales = scaling["map"].constraint_scales
    quantity_tolerances = Dict(quantity => 1.0 for quantity in unique(scaling["constraint_quantities"]))
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
    sides = get(get(kkt, "complementarity", Dict()), "sides", Dict())
    side_by_row = Dict{Int,Any}()
    for side in values(sides)
        row = get(side, "row", nothing)
        string(get(side, "side", "")) == "upper" && row isa Integer && (side_by_row[Int(row)] = side)
    end
    rows = Dict{String,Any}[]
    for row in target_rows
        value = Float64(evaluation.constraint_values[row])
        scale = Float64(scales[row])
        bound = get(side_bounds, (row, "upper"), nothing)
        bound isa Real || error("upper bound unavailable for target row $row")
        expected_model_slack = Float64(bound) - value
        expected_physical_slack = expected_model_slack * scale
        side = get(side_by_row, row, Dict())
        reported_model_slack = get(side, "model_slack", nothing)
        reported_physical_slack = get(side, "physical_slack", nothing)
        push!(rows, Dict{String,Any}(
            "row" => row,
            "value" => value,
            "bound" => bound,
            "scale" => scale,
            "expected_model_slack" => expected_model_slack,
            "expected_physical_slack" => expected_physical_slack,
            "reported_model_slack" => reported_model_slack,
            "reported_physical_slack" => reported_physical_slack,
            "model_slack_difference" => reported_model_slack isa Real ? Float64(reported_model_slack) - expected_model_slack : nothing,
            "physical_slack_difference" => reported_physical_slack isa Real ? Float64(reported_physical_slack) - expected_physical_slack : nothing,
            "complementarity_residual" => get(side, "complementarity_residual", nothing),
        ))
    end
    finite_physical = Float64[abs(Float64(row["expected_physical_slack"])) for row in rows]
    finite_bounds = Float64[Float64(row["bound"]) for row in rows]
    finite_scales = Float64[Float64(row["scale"]) for row in rows]
    model_differences = Float64[abs(Float64(row["model_slack_difference"])) for row in rows if row["model_slack_difference"] isa Real]
    physical_differences = Float64[abs(Float64(row["physical_slack_difference"])) for row in rows if row["physical_slack_difference"] isa Real]
    return Dict{String,Any}(
        "snapshot" => relative,
        "termination_status" => string(JuMP.termination_status(model)),
        "physical_kkt_acceptance_passed" => get(kkt, "acceptance_passed", nothing),
        "target_row_count" => length(rows),
        "bound_range" => [minimum(finite_bounds), maximum(finite_bounds)],
        "scale_range" => [minimum(finite_scales), maximum(finite_scales)],
        "physical_violation_range" => [minimum(finite_physical), maximum(finite_physical)],
        "maximum_model_slack_difference" => isempty(model_differences) ? nothing : maximum(model_differences),
        "maximum_physical_slack_difference" => isempty(physical_differences) ? nothing : maximum(physical_differences),
        "rows" => rows,
        "qualification" => "row-level model-to-physical scaling audit; not a KKT, conditioning, or causal certificate",
    )
end

root = abspath(get(ENV, "NLPDIAGNOSTICS_BMOPF_BENCHMARK_ROOT", DEFAULT_ROOT))
isdir(root) || error("benchmark root does not exist: $root")
max_iter = parse(Int, get(ENV, "NLPDIAGNOSTICS_BMOPF_ROW_SCALING_MAX_ITER", "80"))
max_iter > 0 || error("max_iter must be positive")
results = Dict{String,Any}[]
for relative in selected_cases(root)
    try
        push!(results, run_case(root, relative, max_iter))
    catch error
        push!(results, Dict{String,Any}("snapshot" => relative, "error" => sprint(showerror, error)))
    end
end
output = abspath(get(ENV, "NLPDIAGNOSTICS_BMOPF_ROW_SCALING_OUTPUT", joinpath(@__DIR__, "..", "work", "bmopf-30bus-ibr-p-upper-row-scaling-audit.json")))
mkpath(dirname(output))
write(output, JSON.json(Dict(
    "schema_version" => "nlpdiagnostics-bmopf-30bus-ibr-p-upper-row-scaling-audit-v1",
    "source" => Dict(
        "runner" => basename(@__FILE__),
        "local_environment" => abspath(joinpath(@__DIR__, "..", "work", "benchmark-environment")),
        "solver" => "Ipopt",
        "max_iter" => max_iter,
        "row_family" => "ibr_p_upper",
        "upper_bound_source" => "solver_dual_snapshot",
    ),
    "cases" => results,
)))
println("wrote 30-bus IBR upper row scaling audit to $output")
