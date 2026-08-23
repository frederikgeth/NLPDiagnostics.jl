#!/usr/bin/env julia

"""Audit sparse `ibr_p_upper` Jacobian entries with single-column differences."""

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

function perturbation_point(point, column, delta, sign, label)
    values = copy(point.values)
    values[column] += sign * delta
    return NLPDiagnostics.EvaluationPoint(
        point.variables,
        values;
        label,
        provenance=NLPDiagnostics.EvaluationPointProvenance(
            NLPDiagnostics.PerturbedPoint;
            source="bmopf_30bus_ibr_p_upper_sparse_jacobian_audit",
            complete=true,
            metadata=Dict("delta" => string(delta), "sign" => string(sign), "column" => string(column)),
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
    point = NLPDiagnostics.solver_result_point(model; label="30bus-sparse-jacobian-result")
    point isa NLPDiagnostics.EvaluationPoint || error("solver result point unavailable")
    backend = JuMP.backend(model)
    evaluation = NLPDiagnostics.evaluate_numerical(backend, point)
    row_labels = NLPDiagnostics.bmopf_constraint_semantic_row_map(context, evaluation)
    column_labels = NLPDiagnostics.bmopf_variable_semantic_column_map(context, evaluation)
    target_rows = findall(row -> descriptor_family(row_labels, row, "constraint_family") == "ibr_p_upper", eachindex(evaluation.constraint_values))
    isempty(target_rows) && error("ibr_p_upper rows unavailable")
    target_set = Set(target_rows)
    entries = [entry for entry in evaluation.jacobian_entries if entry.row in target_set && !iszero(entry.value)]
    row_counts = Dict(row => 0 for row in target_rows)
    for entry in entries
        row_counts[entry.row] += 1
    end
    row_position = Dict(row => index for (index, row) in enumerate(target_rows))
    reports = Dict{String,Any}[]
    for entry in entries
        plus = NLPDiagnostics.evaluate_numerical(backend, perturbation_point(point, entry.column, delta, 1.0, "sparse-plus"))
        minus = NLPDiagnostics.evaluate_numerical(backend, perturbation_point(point, entry.column, delta, -1.0, "sparse-minus"))
        row_index = row_position[entry.row]
        finite_difference = (Float64(plus.constraint_values[entry.row]) - Float64(minus.constraint_values[entry.row])) / (2 * delta)
        analytic = Float64(entry.value)
        difference = finite_difference - analytic
        push!(reports, Dict{String,Any}(
            "row" => entry.row,
            "row_position" => row_index,
            "column" => entry.column,
            "variable_family" => descriptor_family(column_labels, entry.column, "variable_family"),
            "analytic_value" => analytic,
            "finite_difference_value" => finite_difference,
            "absolute_difference" => abs(difference),
            "relative_difference" => abs(difference) / max(1.0, abs(analytic)),
        ))
    end
    families = sort!(unique(string(report["variable_family"]) for report in reports))
    family_summary = Dict{String,Any}()
    for family in families
        family_reports = filter(report -> report["variable_family"] == family, reports)
        family_summary[family] = Dict{String,Any}(
            "entry_count" => length(family_reports),
            "analytic_abs_range" => [
                minimum(abs(Float64(report["analytic_value"])) for report in family_reports),
                maximum(abs(Float64(report["analytic_value"])) for report in family_reports),
            ],
            "maximum_absolute_difference" => maximum(Float64(report["absolute_difference"]) for report in family_reports),
            "maximum_relative_difference" => maximum(Float64(report["relative_difference"]) for report in family_reports),
        )
    end
    return Dict{String,Any}(
        "snapshot" => relative,
        "termination_status" => string(JuMP.termination_status(model)),
        "target_row_count" => length(target_rows),
        "target_row_nonzero_entry_count" => length(entries),
        "target_row_nonzero_entry_count_range" => [minimum(values(row_counts)), maximum(values(row_counts))],
        "family_summary" => family_summary,
        "entry_reports" => reports,
        "qualification" => "single-column primal derivative audit; not a KKT, conditioning, or causal certificate",
    )
end

root = abspath(get(ENV, "NLPDIAGNOSTICS_BMOPF_BENCHMARK_ROOT", DEFAULT_ROOT))
isdir(root) || error("benchmark root does not exist: $root")
delta = parse(Float64, get(ENV, "NLPDIAGNOSTICS_BMOPF_30BUS_SPARSE_JACOBIAN_DELTA", "1e-6"))
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
output = abspath(get(ENV, "NLPDIAGNOSTICS_BMOPF_SPARSE_JACOBIAN_OUTPUT", joinpath(@__DIR__, "..", "work", "bmopf-30bus-ibr-p-upper-sparse-jacobian-audit.json")))
mkpath(dirname(output))
write_json(output, Dict(
    "schema_version" => "nlpdiagnostics-bmopf-30bus-ibr-p-upper-sparse-jacobian-audit-v1",
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
println("wrote 30-bus IBR upper sparse Jacobian audit to $output")
