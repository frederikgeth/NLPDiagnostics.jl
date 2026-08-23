#!/usr/bin/env julia

"""Run a small, deterministic operator/domain fingerprint corpus."""

import MathOptInterface as MOI
import NLPDiagnostics
import JuMP

Base.include(@__MODULE__, joinpath(@__DIR__, "common.jl"))
using .NLPDiagnosticsBenchmarkCommon: write_json

new_model() = JuMP.backend(JuMP.Model())

function _findings(report)
    data = NLPDiagnostics.report_data(report)
    return Dict(
        "finding_codes" => get(data, "finding_code_counts", Dict()),
        "findings" => get(data, "findings", Any[]),
        "metadata" => get(data, "metadata", Dict()),
    )
end

function _set_start(model, variable, value)
    MOI.set(model, MOI.VariablePrimalStart(), variable, value)
    return variable
end

function _run_case(name, builder)
    model = builder()
    static = NLPDiagnostics.analyze_static(model)
    expressions = NLPDiagnostics.analyze_expressions(model)
    initialization = NLPDiagnostics.analyze_initialization(
        model;
        check_degeneracy = false,
        check_component_ranks = false,
        component_rank_max_dense_entries = 0,
    )
    return Dict{String,Any}(
        "name" => name,
        "status" => "ok",
        "static" => _findings(static),
        "expression_numerical" => _findings(expressions),
        "initialization" => _findings(initialization),
    )
end

function _log1exp_tail()
    model = new_model()
    x = MOI.add_variable(model)
    _set_start(model, x, -1000.0)
    MOI.add_constraint(model, x, MOI.LessThan(-1000.0))
    MOI.add_constraint(model,
        MOI.ScalarNonlinearFunction(:log1exp, Any[x]), MOI.LessThan(1.0))
    return model
end

function _log_domain()
    model = new_model()
    x = MOI.add_variable(model)
    _set_start(model, x, -1.0)
    MOI.add_constraint(model, x, MOI.LessThan(-1.0))
    MOI.add_constraint(model,
        MOI.ScalarNonlinearFunction(:log, Any[x]), MOI.LessThan(0.0))
    return model
end

function _atan_ratio()
    model = new_model()
    denominator, numerator = MOI.add_variables(model, 2)
    _set_start(model, denominator, 0.0)
    _set_start(model, numerator, 1.0)
    ratio = MOI.ScalarNonlinearFunction(:/, Any[numerator, denominator])
    MOI.add_constraint(model,
        MOI.ScalarNonlinearFunction(:atan, Any[ratio]), MOI.LessThan(2.0))
    return model
end

function _atan2_branch()
    model = new_model()
    y, x = MOI.add_variables(model, 2)
    _set_start(model, y, 0.0)
    _set_start(model, x, -1.0)
    MOI.add_constraint(model,
        MOI.ScalarNonlinearFunction(:atan, Any[y, x]), MOI.LessThan(Float64(pi)))
    return model
end

function _nonunit_circle()
    model = new_model()
    x, y = MOI.add_variables(model, 2)
    _set_start(model, x, 2.0)
    _set_start(model, y, 0.0)
    Q = MOI.ScalarQuadraticFunction{Float64}
    QT = MOI.ScalarQuadraticTerm{Float64}
    circle = Q([QT(2.0, x, x), QT(2.0, y, y)],
               MOI.ScalarAffineTerm{Float64}[], 0.0)
    MOI.add_constraint(model, circle, MOI.EqualTo(4.0))
    return model
end

function _logdiffexp_guard()
    model = new_model()
    a, b = MOI.add_variables(model, 2)
    _set_start(model, a, 1.0)
    _set_start(model, b, 1.0)
    MOI.add_constraint(model, a, MOI.GreaterThan(0.0))
    MOI.add_constraint(model,
        MOI.ScalarNonlinearFunction(:logdiffexp, Any[a, b]), MOI.LessThan(1.0))
    return model
end

function main()
    output_path = isempty(ARGS) ?
        get(ENV, "NLPDIAGNOSTICS_OPERATOR_FINGERPRINT_OUTPUT", joinpath(pwd(), "operator_fingerprint_smoke.json")) :
        abspath(first(ARGS))
    builders = [
        ("log1exp_negative_tail", _log1exp_tail),
        ("log_domain_violation", _log_domain),
        ("atan_ratio", _atan_ratio),
        ("atan2_branch_cut", _atan2_branch),
        ("nonunit_circular_constraint", _nonunit_circle),
        ("logdiffexp_partial_guard", _logdiffexp_guard),
    ]
    cases = Any[]
    for (name, builder) in builders
        try
            push!(cases, _run_case(name, builder))
        catch error
            push!(cases, Dict("name" => name, "status" => "error",
                             "error" => sprint(showerror, error, catch_backtrace())))
        end
    end
    codes = Dict{String,Int}()
    for case in cases
        case["status"] == "ok" || continue
        for stage in ("static", "expression_numerical", "initialization")
            for (code, count) in get(case[stage], "finding_codes", Dict())
                codes[String(code)] = get(codes, String(code), 0) + Int(count)
            end
        end
    end
    payload = Dict{String,Any}(
        "report_version" => "nlpdiagnostics-operator-fingerprint-smoke-v1",
        "case_count" => length(cases),
        "successful_case_count" => count(get(case, "status", "") == "ok" for case in cases),
        "cases" => cases,
        "aggregate_finding_codes" => Dict(k => codes[k] for k in sort!(collect(keys(codes)))),
        "interpretation" => "Static operator/domain fingerprints only; findings describe representational or numerical risks and are not solver or model-quality scores.",
    )
    write_json(output_path, payload)
    println("wrote operator fingerprint smoke report to $output_path")
end

main()
