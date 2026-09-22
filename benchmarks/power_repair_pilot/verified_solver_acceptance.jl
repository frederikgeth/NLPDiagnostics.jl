module VerifiedSolverAcceptance
include("tolerant_capacity_certificate.jl")
using .TolerantCapacityCertificate
import Ipopt
const T=TolerantCapacityCertificate
const E=T.ECC
const Q=E.Q
const MOI=E.MOI
const JuMP=E.JuMP
export verify_primal_point, solve_and_verify

plus(a,b)=(a[1]+b[1],a[2]+b[2])
function times(a,b)
    endpoints=(a[1]*b[1],a[1]*b[2],a[2]*b[1],a[2]*b[2])
    (minimum(endpoints),maximum(endpoints))
end
"""Exact rational Taylor enclosure. Refuse large arguments; no floating trig."""
function trig_enclosure(kind,x::Q)
    kind in ("sin","cos") || error("unsupported trigonometric function")
    abs(x)<=16 || error("trigonometric argument outside verified range [-16,16]")
    term=kind=="sin" ? x : one(Q)
    total=term
    for k in 1:63
        a=kind=="sin" ? 2*k : 2*k-1
        term*=-x*x/(a*(a+1))
        total+=term
    end
    # Both polynomials are the degree-127 Taylor polynomial (zero terms
    # included). The derivative of order 128 has magnitude at most one.
    remainder=abs(x)^128/factorial(big(128))
    (max(-one(Q),total-remainder),min(one(Q),total+remainder))
end
function atom_enclosure(key,point,cache)
    get!(cache,key) do
        parts=split(key,":")
        if length(parts)==2 && parts[1]=="v"
            x=point[MOI.VariableIndex(parse(Int,parts[2]))]
            return (x,x)
        end
        length(parts)==5 && parts[2]==parts[4]=="v" || error("unsupported polynomial atom")
        x=point[MOI.VariableIndex(parse(Int,parts[3]))]-point[MOI.VariableIndex(parse(Int,parts[5]))]
        trig_enclosure(parts[1],x)
    end
end
function evaluate(p,point,cache=Dict{String,Tuple{Q,Q}}())
    result=(zero(Q),zero(Q))
    for (monomial,coefficient) in p
        value=(coefficient,coefficient)
        for key in monomial;value=times(value,atom_enclosure(key,point,cache));end
        result=plus(result,value)
    end
    result
end
function classify(interval,set,tau)
    lower=set isa MOI.EqualTo ? E.exact(set.value) : set isa MOI.GreaterThan ? E.exact(set.lower) : set isa MOI.Interval ? E.exact(set.lower) : nothing
    upper=set isa MOI.EqualTo ? E.exact(set.value) : set isa MOI.LessThan ? E.exact(set.upper) : set isa MOI.Interval ? E.exact(set.upper) : nothing
    set isa Union{MOI.EqualTo,MOI.GreaterThan,MOI.LessThan,MOI.Interval} || error("unsupported set")
    lo,hi=interval
    lo<=hi || error("invalid enclosure")
    if (!isnothing(lower) && hi<lower-tau) || (!isnothing(upper) && lo>upper+tau)
        return "violated"
    elseif (isnothing(lower) || lo>=lower-tau) && (isnothing(upper) || hi<=upper+tau)
        return "satisfied"
    end
    "inconclusive"
end
"""
Verify ALL supported encoded primal constraints at a supplied finite real point.
Intervals enclose exact real values; acceptance is on original unscaled rows.
No reliance on solver status, floating residual evaluation, or relative tests.
"""
function verify_primal_point(pm,data,point;absolute_tolerance)
    try
        tau=T.tolerance(absolute_tolerance)
        contract=E.CMC.checked_capacity_preflight(pm,data)
        contract.available || return (available=false,status="unavailable",reason=contract.reason)
        backend=JuMP.backend(pm.model)
        variables=MOI.get(backend,MOI.ListOfVariableIndices())
        Set(keys(point))==Set(variables) || error("point must cover exactly the backend variables")
        exact_point=Dict(v=>E.exact(point[v]) for v in variables)
        cache=Dict{String,Tuple{Q,Q}}();rows=Any[]
        for (F,S) in MOI.get(backend,MOI.ListOfConstraintTypesPresent())
            for idx in MOI.get(backend,MOI.ListOfConstraintIndices{F,S}())
                f=MOI.get(backend,MOI.ConstraintFunction(),idx)
                s=MOI.get(backend,MOI.ConstraintSet(),idx)
                enclosure=evaluate(E.polynomial(f),exact_point,cache)
                push!(rows,(row=string(idx),status=classify(enclosure,s,tau),value_enclosure_exact=string.([enclosure...]),set=E.CMC.set_key(s)))
            end
        end
        sort!(rows;by=r->r.row)
        status=any(r->r.status=="violated",rows) ? "violated" : any(r->r.status=="inconclusive",rows) ? "inconclusive" : "satisfied"
        (available=true,status=status,absolute_tolerance_exact=string(tau),contract_digest=contract.contract_digest,
            checked_rows=length(rows),rows=rows,
            point_exact=[(variable=v.value,value=string(exact_point[v])) for v in sort(variables;by=v->v.value)],
            semantics="Every original encoded scalar constraint is checked against the absolute unscaled tolerance using rational enclosures. Satisfied is primal tolerance compliance, not optimality or source intent.")
    catch e
        e isa InterruptException && rethrow()
        (available=false,status="unavailable",reason=sprint(showerror,e))
    end
end

const SOLVER_SETTINGS=("tol"=>1e-9,"constr_viol_tol"=>1e-9,
    "nlp_scaling_method"=>"none","bound_relax_factor"=>0.0,
    "acceptable_iter"=>0,"honor_original_bounds"=>"yes",
    "max_iter"=>500,"max_cpu_time"=>60.0,"print_level"=>0)
"""Pinned experimental solve workflow. Acceptance requires independent enclosure verification."""
function solve_and_verify(pm,data;absolute_tolerance=1e-6)
    try
        VERSION==v"1.12.6" && Base.pkgversion(Ipopt)==v"1.15.0" || error("pinned Julia 1.12.6 / Ipopt.jl 1.15.0 required")
        tau=T.tolerance(absolute_tolerance)
        certificate=T.tolerant_capacity_certificate(pm,data;contract=:absolute_unscaled,
            equality_tolerance=tau,generator_bound_tolerance=tau,voltage_bound_tolerance=tau)
        certificate.available || return (available=false,status="unavailable",reason=certificate.reason)
        JuMP.set_optimizer(pm.model,JuMP.optimizer_with_attributes(Ipopt.Optimizer,SOLVER_SETTINGS...))
        JuMP.optimize!(pm.model)
        termination=JuMP.termination_status(pm.model)
        if !JuMP.has_values(pm.model)
            return (available=true,status="no_primal_point",termination=string(termination),certificate=certificate)
        end
        point=Dict(JuMP.index(v)=>JuMP.value(v) for v in JuMP.all_variables(pm.model))
        verification=verify_primal_point(pm,data,point;absolute_tolerance=tau)
        if verification.available
            verification.contract_digest==certificate.encoded_evidence.contract_digest || error("backend changed during solve")
            verification.status=="satisfied" && certificate.status=="certified_infeasible_within_tolerances" && error("inconsistent certificate and point verification")
        end
        status=!verification.available ? "verification_unavailable" : verification.status!="satisfied" ? "primal_$(verification.status)" : termination!=MOI.LOCALLY_SOLVED ? "verified_point_without_solver_success" : "accepted_primal_point"
        (available=true,status=status,termination=string(termination),solver_settings=Dict(SOLVER_SETTINGS),
            certificate=certificate,verification=verification,
            limitation="Acceptance certifies only the returned point's primal tolerance contract. Ipopt status alone remains uncertified; no claim about all solver-accepted points or optimality.")
    catch e
        e isa InterruptException && rethrow()
        (available=false,status="unavailable",reason=sprint(showerror,e))
    end
end
end
