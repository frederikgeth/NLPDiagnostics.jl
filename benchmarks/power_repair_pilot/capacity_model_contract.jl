module CapacityModelContract
import JuMP, MathOptInterface as MOI, PowerModels as PM
using JSON, SHA
include("capacity_preflight.jl")
using .PowerCapacityPreflight
export checked_capacity_preflight

function materialize(data)
    if data isa AbstractDict
        all(k->k isa String,keys(data)) || error("source dictionary keys must be strings")
        return Dict{String,Any}(k=>materialize(v) for (k,v) in data)
    elseif data isa AbstractVector
        return materialize.(data)
    elseif data isa Real && !(data isa Bool)
        data isa Float64 || (data isa Integer && isfinite(Float64(data)) && Rational{BigInt}(Float64(data))==data) ||
            error("source precision outside Float64 builder contract")
    end
    data
end

number_key(x)=x isa Union{Integer,Rational,AbstractFloat} && !(x isa Bool) && isfinite(x) ?
    string(Rational{BigInt}(x)) : error("unsupported/nonfinite coefficient")
function function_key(f,names)
    f isa MOI.VariableIndex && return ["variable",names[f]]
    f isa Real && return ["number",number_key(f)]
    if f isa MOI.ScalarAffineFunction
        terms=sort!([[names[t.variable],number_key(t.coefficient)] for t in f.terms];by=JSON.json)
        return ["affine",number_key(f.constant),terms]
    elseif f isa MOI.ScalarQuadraticFunction
        affine=sort!([[names[t.variable],number_key(t.coefficient)] for t in f.affine_terms];by=JSON.json)
        quadratic=sort!([[sort([names[t.variable_1],names[t.variable_2]]),number_key(t.coefficient)] for t in f.quadratic_terms];by=JSON.json)
        return ["quadratic",number_key(f.constant),affine,quadratic]
    elseif f isa MOI.ScalarNonlinearFunction
        f.head in (:+,:-,:*,:/,:^,:sin,:cos) || error("unsupported nonlinear operator $(f.head)")
        return ["nonlinear",string(f.head),[function_key(a,names) for a in f.args]]
    end
    error("unsupported constraint function $(typeof(f))")
end
function set_key(s)
    s isa MOI.EqualTo && return ["equal",number_key(s.value)]
    s isa MOI.LessThan && return ["upper",number_key(s.upper)]
    s isa MOI.GreaterThan && return ["lower",number_key(s.lower)]
    s isa MOI.Interval && return ["interval",number_key(s.lower),number_key(s.upper)]
    error("unsupported constraint set $(typeof(s))")
end
function model_signature(model)
    backend=JuMP.backend(model)
    any(a->a isa MOI.UserDefinedFunction,MOI.get(backend,MOI.ListOfModelAttributesSet())) &&
        error("registered nonlinear callbacks are unsupported")
    block=try
        MOI.get(backend,MOI.NLPBlock())
    catch e
        e isa MOI.UnsupportedAttribute || rethrow()
        nothing
    end
    isnothing(block) || error("opaque NLPBlock is unsupported")
    variables=JuMP.all_variables(model)
    labels=JuMP.name.(variables)
    all(label->!isempty(label),labels) && length(unique(labels))==length(labels) || error("unique nonempty variable names required")
    names=Dict(JuMP.index(v)=>JuMP.name(v) for v in variables)
    rows=String[]
    for (F,S) in MOI.get(backend,MOI.ListOfConstraintTypesPresent())
        for index in MOI.get(backend,MOI.ListOfConstraintIndices{F,S}())
            push!(rows,JSON.json([function_key(MOI.get(backend,MOI.ConstraintFunction(),index),names),
                set_key(MOI.get(backend,MOI.ConstraintSet(),index))]))
        end
    end
    sort!(rows)
    (variables=sort(labels),rows=rows)
end
"""
Match a standard ACP OPF rebuilt from supplied data against the current backend.
Only supported explicit scalar functions/sets and identical named coordinates
are accepted. Objective and starts are excluded: this checks feasibility scope.
A mismatch is unavailable, not model infeasibility. Structural equivalences
outside this narrow representation are deliberately not inferred.
"""
function checked_capacity_preflight(pm,data)
    preflight=capacity_preflight(data;contract=:closed_acp_fixed_load)
    preflight.available || return (available=false,status="unavailable",reason=preflight.reason)
    try
        pm isa PM.ACPPowerModel || error("standard ACP model required")
        expected=PM.instantiate_model(materialize(data),PM.ACPPowerModel,PM.build_opf)
        actual_signature=model_signature(pm.model)
        expected_signature=model_signature(expected.model)
        if actual_signature!=expected_signature
            return (available=false,status="unavailable",reason="backend constraints or named variables differ from the source-derived standard ACP model",
                actual_row_count=length(actual_signature.rows),expected_row_count=length(expected_signature.rows))
        end
        digest=bytes2hex(sha256(JSON.json(expected_signature)))
        return (available=true,status=preflight.status,capacity_evidence=preflight,
            contract_digest=digest,matched_row_count=length(expected_signature.rows),
            interpretation="Supported row representation matches the standard Float64 ACP builder. Capacity remains conditional on physical equation semantics; this does not certify passivity of rounded expanded coefficients, backend infeasibility, feasibility, optimality, or real-world source intent.")
    catch e
        e isa InterruptException && rethrow()
        return (available=false,status="unavailable",reason=sprint(showerror,e))
    end
end
end
