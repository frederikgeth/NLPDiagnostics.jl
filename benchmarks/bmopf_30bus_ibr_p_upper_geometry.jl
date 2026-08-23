#!/usr/bin/env julia

"""Report endpoint Jacobian geometry for the 30-bus `ibr_p_upper` rows."""

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

function descriptor_family(labels, index, key)
    descriptor = get(labels, index, get(labels, string(index), Dict()))
    descriptor isa AbstractDict ?
        string(get(descriptor, key, get(descriptor, "family_label", "unclassified"))) :
        string(descriptor)
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
    point = NLPDiagnostics.solver_result_point(model; label="30bus-ibr-geometry-result")
    point isa NLPDiagnostics.EvaluationPoint || error("solver result point unavailable")
    evaluation = NLPDiagnostics.evaluate_numerical(JuMP.backend(model), point)
    row_labels = NLPDiagnostics.bmopf_constraint_semantic_row_map(context, evaluation)
    column_labels = NLPDiagnostics.bmopf_variable_semantic_column_map(context, evaluation)
    row_families = [
        descriptor_family(row_labels, row, "constraint_family")
        for row in eachindex(evaluation.constraint_values)
    ]
    target_rows = findall(==("ibr_p_upper"), row_families)
    isempty(target_rows) && error("ibr_p_upper rows unavailable")
    row_max_abs = Dict(row => 0.0 for row in target_rows)
    row_nonzero = Dict(row => 0 for row in target_rows)
    column_family_abs_sum = Dict{String,Float64}()
    column_family_nonzero = Dict{String,Int}()
    for entry in evaluation.jacobian_entries
        entry.row in target_rows || continue
        magnitude = abs(Float64(entry.value))
        row_max_abs[entry.row] = max(row_max_abs[entry.row], magnitude)
        if !iszero(entry.value)
            row_nonzero[entry.row] += 1
            family = descriptor_family(column_labels, entry.column, "variable_family")
            column_family_abs_sum[family] = get(column_family_abs_sum, family, 0.0) + magnitude
            column_family_nonzero[family] = get(column_family_nonzero, family, 0) + 1
        end
    end
    row_geometry = NLPDiagnostics.bmopf_jacobian_row_family_scale_attribution(
        context, evaluation,
    )
    target_geometry = get(get(row_geometry, "families", Dict()), "ibr_p_upper", Dict())
    quantity_tolerances = Dict(
        quantity => 1.0 for quantity in unique(
            NLPDiagnostics.bmopf_diagonal_scaling_map(context, evaluation)["constraint_quantities"],
        )
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
    target_violations = Float64[
        Float64(get(value, "violation", NaN))
        for (key, value) in residuals
        if occursin("ibr_p_upper", string(key)) && get(value, "violation", nothing) isa Real
    ]
    ordered_columns = sort!(collect(keys(column_family_abs_sum));
        by = family -> (-column_family_abs_sum[family], family))
    return Dict{String,Any}(
        "snapshot" => relative,
        "termination_status" => string(JuMP.termination_status(model)),
        "physical_kkt_acceptance_passed" => get(kkt, "acceptance_passed", nothing),
        "target_row_count" => length(target_rows),
        "target_row_indices" => target_rows,
        "target_row_value_range" => [
            minimum(Float64.(evaluation.constraint_values[target_rows])),
            maximum(Float64.(evaluation.constraint_values[target_rows])),
        ],
        "target_physical_violation_max" => isempty(target_violations) ? nothing : maximum(target_violations),
        "target_row_nonzero_entry_count_range" => [
            minimum(values(row_nonzero)), maximum(values(row_nonzero)),
        ],
        "target_row_max_abs_jacobian_range" => [
            minimum(values(row_max_abs)), maximum(values(row_max_abs)),
        ],
        "target_row_geometry" => target_geometry,
        "top_column_families_by_abs_jacobian_sum" => [
            Dict{String,Any}(
                "family" => family,
                "absolute_jacobian_sum" => column_family_abs_sum[family],
                "nonzero_entry_count" => column_family_nonzero[family],
            ) for family in first(ordered_columns, min(length(ordered_columns), 8))
        ],
    )
end

root = abspath(get(ENV, "NLPDIAGNOSTICS_BMOPF_BENCHMARK_ROOT", DEFAULT_ROOT))
isdir(root) || error("benchmark root does not exist: $root")
max_iter = parse(Int, get(ENV, "NLPDIAGNOSTICS_BMOPF_30BUS_GEOMETRY_MAX_ITER", "80"))
max_iter > 0 || error("max_iter must be positive")
results = Dict{String,Any}[]
for relative in selected_cases(root)
    try
        push!(results, run_case(root, relative, max_iter))
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
    "NLPDIAGNOSTICS_BMOPF_30BUS_GEOMETRY_OUTPUT",
    joinpath(@__DIR__, "..", "work", "bmopf-30bus-ibr-p-upper-geometry.json"),
))
mkpath(dirname(output))
write_json(output, Dict(
    "schema_version" => "nlpdiagnostics-bmopf-30bus-ibr-p-upper-geometry-v1",
    "source" => Dict(
        "runner" => basename(@__FILE__),
        "local_environment" => abspath(joinpath(@__DIR__, "..", "work", "benchmark-environment")),
        "solver" => "Ipopt",
        "max_iter" => max_iter,
        "row_family" => "ibr_p_upper",
        "interpretation" => "endpoint Jacobian geometry; not causal conditioning evidence",
    ),
    "cases" => results,
))
println("wrote 30-bus IBR upper geometry to $output")
