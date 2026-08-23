#!/usr/bin/env julia

"""Check local `ibr_p_upper` directional responses across finite-difference deltas."""

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

function selected_deltas()
    raw = get(ENV, "NLPDIAGNOSTICS_BMOPF_30BUS_DIRECTIONAL_DELTAS", "1e-5,1e-6,1e-7")
    deltas = sort!(unique(parse.(Float64, filter(!isempty, strip.(split(raw, ','))))), rev=true)
    isempty(deltas) && error("directional delta list must not be empty")
    all(isfinite, deltas) && all(>(0), deltas) || error("directional deltas must be finite and positive")
    return deltas
end

function family_label(labels, index)
    descriptor = get(labels, index, get(labels, string(index), Dict()))
    descriptor isa AbstractDict ?
        string(get(descriptor, "variable_family", get(descriptor, "family_label", "unclassified"))) :
        string(descriptor)
end

function row_family(labels, index)
    descriptor = get(labels, index, get(labels, string(index), Dict()))
    descriptor isa AbstractDict ? string(get(descriptor, "constraint_family", "unclassified")) : string(descriptor)
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
            source="bmopf_ibr_p_upper_directional_delta_matrix",
            complete=true,
            metadata=Dict("delta" => string(delta), "sign" => string(sign)),
        ),
    )
end

function directional_measure(backend, point, target_rows, columns, base, delta, family)
    plus_point = perturbation_point(point, columns, delta, 1.0, "delta-$family-plus")
    minus_point = perturbation_point(point, columns, delta, -1.0, "delta-$family-minus")
    plus = NLPDiagnostics.evaluate_numerical(backend, plus_point)
    minus = NLPDiagnostics.evaluate_numerical(backend, minus_point)
    plus_values = Float64.(plus.constraint_values[target_rows])
    minus_values = Float64.(minus.constraint_values[target_rows])
    central = (plus_values .- minus_values) ./ (2 * delta)
    symmetry = plus_values .+ minus_values .- 2 .* base
    return Dict{String,Any}(
        "family" => family,
        "delta" => delta,
        "perturbed_column_count" => length(columns),
        "central_slope_range" => [minimum(central), maximum(central)],
        "central_slope_abs_range" => [minimum(abs.(central)), maximum(abs.(central))],
        "maximum_absolute_response" => max(
            maximum(abs.(plus_values .- base)),
            maximum(abs.(minus_values .- base)),
        ),
        "maximum_absolute_symmetry_error" => maximum(abs.(symmetry)),
    )
end

function run_case(root, relative, deltas, max_iter)
    network = BMOPFTools.parse_bmopf(joinpath(root, relative))
    context = BMOPFTools.build_opf_model(
        deepcopy(network); optimizer=Ipopt.Optimizer, add_objective=true,
    )
    BMOPFTools.enforce_kcl!(context)
    model = BMOPFTools.opf_model(context)
    JuMP.set_silent(model)
    JuMP.set_optimizer_attribute(model, "max_iter", max_iter)
    JuMP.optimize!(model)
    point = NLPDiagnostics.solver_result_point(model; label="30bus-directional-delta-result")
    point isa NLPDiagnostics.EvaluationPoint || error("solver result point unavailable")
    backend = JuMP.backend(model)
    evaluation = NLPDiagnostics.evaluate_numerical(backend, point)
    row_labels = NLPDiagnostics.bmopf_constraint_semantic_row_map(context, evaluation)
    column_labels = NLPDiagnostics.bmopf_variable_semantic_column_map(context, evaluation)
    target_rows = findall(
        row -> row_family(row_labels, row) == "ibr_p_upper",
        eachindex(evaluation.constraint_values),
    )
    isempty(target_rows) && error("ibr_p_upper rows unavailable")
    target_columns = Dict(
        family => findall(
            column -> family_label(column_labels, column) == family,
            eachindex(point.values),
        ) for family in ("cri", "cii")
    )
    base = Float64.(evaluation.constraint_values[target_rows])
    measures = Dict{String,Any}[]
    for delta in deltas, family in ("cri", "cii")
        push!(measures, directional_measure(
            backend, point, target_rows, target_columns[family], base, delta, family,
        ))
    end
    return Dict{String,Any}(
        "snapshot" => relative,
        "termination_status" => string(JuMP.termination_status(model)),
        "target_row_count" => length(target_rows),
        "target_row_value_range" => [minimum(base), maximum(base)],
        "measures" => measures,
        "qualification" => "finite-difference primal response only; not a KKT, conditioning, or causal certificate",
    )
end

root = abspath(get(ENV, "NLPDIAGNOSTICS_BMOPF_BENCHMARK_ROOT", DEFAULT_ROOT))
isdir(root) || error("benchmark root does not exist: $root")
deltas = selected_deltas()
max_iter = parse(Int, get(ENV, "NLPDIAGNOSTICS_BMOPF_30BUS_DIRECTIONAL_MAX_ITER", "80"))
max_iter > 0 || error("max_iter must be positive")
results = Dict{String,Any}[]
for relative in selected_cases(root)
    try
        push!(results, run_case(root, relative, deltas, max_iter))
    catch error
        push!(results, Dict{String,Any}("snapshot" => relative, "error" => sprint(showerror, error)))
    end
end
output = abspath(get(
    ENV,
    "NLPDIAGNOSTICS_BMOPF_30BUS_DIRECTIONAL_DELTA_OUTPUT",
    joinpath(@__DIR__, "..", "work", "bmopf-30bus-ibr-p-upper-directional-delta-matrix.json"),
))
mkpath(dirname(output))
write_json(output, Dict(
    "schema_version" => "nlpdiagnostics-bmopf-30bus-ibr-p-upper-directional-delta-matrix-v1",
    "source" => Dict(
        "runner" => basename(@__FILE__),
        "local_environment" => abspath(joinpath(@__DIR__, "..", "work", "benchmark-environment")),
        "solver" => "Ipopt",
        "deltas" => deltas,
        "max_iter" => max_iter,
        "row_family" => "ibr_p_upper",
    ),
    "cases" => results,
))
println("wrote 30-bus IBR upper directional delta matrix to $output")
