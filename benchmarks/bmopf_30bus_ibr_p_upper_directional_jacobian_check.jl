#!/usr/bin/env julia

"""Compare `ibr_p_upper` finite differences with analytic Jacobian directions."""

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
    all(relative -> isfile(joinpath(root, relative)), cases) || error("one or more selected snapshots are missing")
    return cases
end

function descriptor_family(labels, index, key)
    descriptor = get(labels, index, get(labels, string(index), Dict()))
    descriptor isa AbstractDict ? string(get(descriptor, key, get(descriptor, "family_label", "unclassified"))) : string(descriptor)
end

function perturbation_point(point, columns, delta, sign, label)
    values = copy(point.values)
    for column in columns
        values[column] += sign * delta
    end
    return NLPDiagnostics.EvaluationPoint(
        point.variables,
        values;
        label,
        provenance=NLPDiagnostics.EvaluationPointProvenance(
            NLPDiagnostics.PerturbedPoint;
            source="bmopf_ibr_p_upper_directional_jacobian_check",
            complete=true,
            metadata=Dict("delta" => string(delta), "sign" => string(sign)),
        ),
    )
end

function run_case(root, relative, delta, max_iter)
    network = BMOPFTools.parse_bmopf(joinpath(root, relative))
    context = BMOPFTools.build_opf_model(deepcopy(network); optimizer=Ipopt.Optimizer, add_objective=true)
    BMOPFTools.enforce_kcl!(context)
    model = BMOPFTools.opf_model(context)
    JuMP.set_silent(model)
    JuMP.set_optimizer_attribute(model, "max_iter", max_iter)
    JuMP.optimize!(model)
    point = NLPDiagnostics.solver_result_point(model; label="30bus-directional-jacobian-result")
    point isa NLPDiagnostics.EvaluationPoint || error("solver result point unavailable")
    backend = JuMP.backend(model)
    evaluation = NLPDiagnostics.evaluate_numerical(backend, point)
    row_labels = NLPDiagnostics.bmopf_constraint_semantic_row_map(context, evaluation)
    column_labels = NLPDiagnostics.bmopf_variable_semantic_column_map(context, evaluation)
    target_rows = findall(row -> descriptor_family(row_labels, row, "constraint_family") == "ibr_p_upper", eachindex(evaluation.constraint_values))
    isempty(target_rows) && error("ibr_p_upper rows unavailable")
    families = ("cri", "cii")
    target_columns = Dict(
        family => findall(column -> descriptor_family(column_labels, column, "variable_family") == family, eachindex(point.values))
        for family in families
    )
    target_set = Set(target_rows)
    analytic = Dict(family => zeros(Float64, length(target_rows)) for family in families)
    row_position = Dict(row => index for (index, row) in enumerate(target_rows))
    for entry in evaluation.jacobian_entries
        entry.row in target_set || continue
        family = descriptor_family(column_labels, entry.column, "variable_family")
        family in families || continue
        analytic[family][row_position[entry.row]] += Float64(entry.value)
    end
    base = Float64.(evaluation.constraint_values[target_rows])
    reports = Dict{String,Any}[]
    for family in families
        columns = target_columns[family]
        plus = NLPDiagnostics.evaluate_numerical(backend, perturbation_point(point, columns, delta, 1.0, "jacobian-$family-plus"))
        minus = NLPDiagnostics.evaluate_numerical(backend, perturbation_point(point, columns, delta, -1.0, "jacobian-$family-minus"))
        central = (Float64.(plus.constraint_values[target_rows]) .- Float64.(minus.constraint_values[target_rows])) ./ (2 * delta)
        difference = central .- analytic[family]
        push!(reports, Dict{String,Any}(
            "family" => family,
            "perturbed_column_count" => length(columns),
            "analytic_directional_slope_range" => [minimum(analytic[family]), maximum(analytic[family])],
            "finite_difference_slope_range" => [minimum(central), maximum(central)],
            "maximum_absolute_slope_difference" => maximum(abs.(difference)),
            "maximum_relative_slope_difference" => maximum(abs.(difference) ./ max.(1.0, abs.(analytic[family]))),
        ))
    end
    return Dict{String,Any}(
        "snapshot" => relative,
        "termination_status" => string(JuMP.termination_status(model)),
        "target_row_count" => length(target_rows),
        "target_row_value_range" => [minimum(base), maximum(base)],
        "reports" => reports,
        "qualification" => "analytic-versus-finite-difference primal derivative check; not a KKT, conditioning, or causal certificate",
    )
end

root = abspath(get(ENV, "NLPDIAGNOSTICS_BMOPF_BENCHMARK_ROOT", DEFAULT_ROOT))
isdir(root) || error("benchmark root does not exist: $root")
delta = parse(Float64, get(ENV, "NLPDIAGNOSTICS_BMOPF_30BUS_DIRECTIONAL_JACOBIAN_DELTA", "1e-6"))
delta > 0 || error("directional delta must be positive")
max_iter = parse(Int, get(ENV, "NLPDIAGNOSTICS_BMOPF_DIRECTIONAL_MAX_ITER", "80"))
max_iter > 0 || error("max_iter must be positive")
results = Dict{String,Any}[]
for relative in selected_cases(root)
    try
        push!(results, run_case(root, relative, delta, max_iter))
    catch error
        push!(results, Dict{String,Any}("snapshot" => relative, "error" => sprint(showerror, error)))
    end
end
output = abspath(get(ENV, "NLPDIAGNOSTICS_BMOPF_30BUS_DIRECTIONAL_JACOBIAN_OUTPUT", joinpath(@__DIR__, "..", "work", "bmopf-30bus-ibr-p-upper-directional-jacobian-check.json")))
mkpath(dirname(output))
write_json(output, Dict(
    "schema_version" => "nlpdiagnostics-bmopf-30bus-ibr-p-upper-directional-jacobian-check-v1",
    "source" => Dict(
        "runner" => basename(@__FILE__),
        "local_environment" => abspath(joinpath(@__DIR__, "..", "work", "benchmark-environment")),
        "solver" => "Ipopt",
        "delta" => delta,
        "max_iter" => max_iter,
        "row_family" => "ibr_p_upper",
    ),
    "cases" => results,
))
println("wrote 30-bus IBR upper directional Jacobian check to $output")
