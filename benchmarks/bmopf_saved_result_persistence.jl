#!/usr/bin/env julia

"""Cross-point persistence probe for saved BMOPF results.

One staged context is built from the first selected snapshot; saved results from
the remaining snapshots are mapped into that same ordered MOI coordinate space.
The resulting points are passed to Jacobian-rank and component-rank persistence
analysis. No solve is performed and no point is generated or completed.
"""

using NLPDiagnostics
using BMOPFTools
using JuMP
using Ipopt
using JSON

include(joinpath(@__DIR__, "benchmark_environment.jl"))

const _DEFAULT_CASES = [
    "ENWLsnapshots/30bus_LN/30bus_LN_t01_0800.bmopf.json",
    "ENWLsnapshots/30bus_LN/30bus_LN_t02_0830.bmopf.json",
    "ENWLsnapshots/30bus_LN/30bus_LN_t03_0900.bmopf.json",
    "ENWLsnapshots/30bus_LN/30bus_LN_t04_0930.bmopf.json",
    "ENWLsnapshots/30bus_LN/30bus_LN_t05_1000.bmopf.json",
]

function _cases(root)
    selected = filter(!isempty, strip.(split(get(
        ENV, "NLPDIAGNOSTICS_BMOPF_PERSISTENCE_CASES", "",
    ), ',')))
    cases = isempty(selected) ? _DEFAULT_CASES : selected
    for relative in cases
        isabspath(relative) && error("persistence cases must be relative to benchmark root")
        isfile(joinpath(root, relative)) || error("persistence snapshot is missing: $(joinpath(root, relative))")
        endswith(relative, ".bmopf.json") || error("persistence case is not a .bmopf.json snapshot: $relative")
    end
    return cases
end

function _field_units()
    raw = strip(get(ENV, "NLPDIAGNOSTICS_BMOPF_RESULT_FIELD_UNITS", ""))
    isempty(raw) && return Dict{Symbol,Symbol}()
    result = Dict{Symbol,Symbol}()
    for token in filter(!isempty, strip.(split(raw, ',')))
        parts = occursin('=', token) ? split(token, '='; limit = 2) : split(token, ':'; limit = 2)
        length(parts) == 2 || error("field-unit entries must use family=unit: $token")
        family = Symbol(lowercase(strip(parts[1])))
        unit = Symbol(lowercase(strip(parts[2])))
        unit in (:si, :pu, :model) || error("field-unit value must be si, pu, or model: $token")
        result[family] = unit
    end
    return result
end

function _case_name(relative)
    replace(replace(relative, '/' => "__"), ".bmopf.json" => "")
end

function main()
    root = abspath(get(ENV, "NLPDIAGNOSTICS_BMOPF_BENCHMARK_ROOT", ""))
    isempty(root) && error("Set NLPDIAGNOSTICS_BMOPF_BENCHMARK_ROOT first")
    isdir(root) || error("benchmark root does not exist: $root")
    selected = _cases(root)
    length(selected) >= 2 || error("persistence analysis requires at least two snapshots")
    result_units = Symbol(lowercase(get(ENV, "NLPDIAGNOSTICS_BMOPF_RESULT_UNITS", "si")))
    result_units in (:si, :pu, :model) || error("NLPDIAGNOSTICS_BMOPF_RESULT_UNITS must be si, pu, or model")
    field_units = _field_units()
    output_path = abspath(get(ENV, "NLPDIAGNOSTICS_BMOPF_PERSISTENCE_OUTPUT",
                              joinpath(pwd(), "bmopf-saved-result-persistence.json")))
    rank_limit = try parse(Int, get(ENV, "NLPDIAGNOSTICS_BMOPF_PERSISTENCE_MAX_DENSE_ENTRIES", "0"))
    catch
        error("NLPDIAGNOSTICS_BMOPF_PERSISTENCE_MAX_DENSE_ENTRIES must be an integer")
    end
    rank_limit >= 0 || error("persistence dense-entry limit must be nonnegative")
    network = BMOPFTools.parse_bmopf(joinpath(root, first(selected)))
    context = BMOPFTools.build_opf_model(deepcopy(network); add_objective = false)
    BMOPFTools.enforce_kcl!(context)
    mappings = Any[]
    points = NLPDiagnostics.EvaluationPoint[]
    for relative in selected
        result_path = replace(joinpath(root, relative), ".bmopf.json" => "_result_$(result_units).json")
        isfile(result_path) || error("saved result is missing: $result_path")
        saved = NLPDiagnostics.bmopf_saved_result_profile_case(
            _case_name(relative), context, BMOPFTools.read_result(result_path);
            result_units = result_units,
            field_units = field_units,
            fallback_value = 0.0,
            metadata = Dict{String,Any}("saved_result_path" => abspath(result_path)),
        )
        push!(mappings, Dict(
            "snapshot" => relative,
            "mapping_report" => NLPDiagnostics.report_data(saved.mapping_report),
            "mapped_coordinate_count" => saved.mapping.mapped_coordinate_count,
            "fallback_coordinate_count" => saved.mapping.fallback_coordinate_count,
        ))
        push!(points, saved.mapping.point)
    end
    rank_report = NLPDiagnostics.bmopf_analyze_jacobian_rank_persistence(
        context, points; max_dense_entries = rank_limit,
    )
    component_report = NLPDiagnostics.bmopf_analyze_component_rank_persistence(
        context, points; max_dense_entries = rank_limit,
    )
    report = Dict{String,Any}(
        "report_version" => "bmopf-saved-result-persistence-v1",
        "benchmark_root" => root,
        "snapshots" => selected,
        "result_units" => string(result_units),
        "result_field_units" => isempty(field_units) ? "" : join(("$(key)=$(value)" for (key, value) in sort!(collect(field_units); by = first)), ","),
        "dense_rank_max_entries" => rank_limit,
        "model_variable_count" => length(points[1].variables),
        "mapping" => mappings,
        "jacobian_rank_persistence" => NLPDiagnostics.report_data(rank_report),
        "component_rank_persistence" => NLPDiagnostics.report_data(component_report),
        "interpretation" => "Cross-point numerical persistence evidence only; persistent rank or nullspace patterns do not establish a physical cause.",
    )
    write(output_path, JSON.json(report))
    println("wrote BMOPF saved-result persistence report to $output_path")
end

main()
