module IslandCapacityCertificate
include("verified_solver_acceptance.jl")
const V=VerifiedSolverAcceptance
const T=V.T
const E=T.ECC
const PM=E.PM
export island_capacity_certificate, solve_with_island_preflight

function components(data)
    adjacency=Dict(parse(Int,id)=>Int[] for (id,b) in data["bus"] if b["bus_type"]!=4)
    for b in values(data["branch"])
        b["br_status"]==1 || continue
        f=Int(b["f_bus"]);t=Int(b["t_bus"])
        push!(adjacency[f],t);push!(adjacency[t],f)
    end
    remaining=Set(keys(adjacency));groups=Vector{Int}[]
    while !isempty(remaining)
        queue=[minimum(remaining)];delete!(remaining,first(queue));group=Int[]
        while !isempty(queue)
            v=popfirst!(queue);push!(group,v)
            for w in adjacency[v]
                if w in remaining;delete!(remaining,w);push!(queue,w);end
            end
        end
        push!(groups,sort!(group))
    end
    groups
end
function project(data,buses)
    d=E.CMC.materialize(deepcopy(data));members=Set(buses)
    filter!(p->parse(Int,p.first) in members,d["bus"])
    for (kind,field) in (("load","load_bus"),("gen","gen_bus"),("shunt","shunt_bus"))
        filter!(p->Int(p.second[field]) in members,d[kind])
    end
    filter!(p->Int(p.second["f_bus"]) in members && Int(p.second["t_bus"]) in members,d["branch"])
    d
end
"""Exact named-variable/row multiset inclusion; never infer algebraic equivalence."""
function signature_subset(part,whole)
    issubset(Set(part.variables),Set(whole.variables)) || return false
    counts=Dict{String,Int}()
    for r in whole.rows;counts[r]=get(counts,r,0)+1;end
    for r in part.rows
        get(counts,r,0)>0 || return false
        counts[r]-=1
    end
    true
end
function constant_contradiction(model,tau)
    witnesses=Any[]
    for (row,p) in E.equality_rows(model)
        all(isempty,keys(p)) || continue
        residual=get(p,(),zero(E.Q))
        abs(residual)>tau || continue
        push!(witnesses,(row=row,residual_exact=string(residual),margin_exact=string(abs(residual)-tau)))
    end
    sort!(witnesses;by=w->w.row)
end
"""
Sufficient tolerance-aware contradiction in any AC-connected island. Rebuilt
island rows must be an exact named-coordinate multiset subset of the original
backend. Constant equalities are checked directly, without shape-based selection.
No claim of feasibility follows from aggregate adequacy in every island.
"""
function island_capacity_certificate(pm,data;absolute_tolerance=1e-6)
    try
        tau=T.tolerance(absolute_tolerance)
        contract=E.CMC.checked_capacity_preflight(pm,data)
        contract.available || return (available=false,status="unavailable",reason=contract.reason)
        whole=E.CMC.model_signature(pm.model)
        results=Any[]
        for buses in components(data)
            result=try
                d=project(data,buses)
                part=PM.instantiate_model(d,PM.ACPPowerModel,PM.build_opf)
                signature=E.CMC.model_signature(part.model)
                signature_subset(signature,whole) || error("projected island equations or bounds are not a subset of the original backend")
                witnesses=constant_contradiction(part.model,tau)
                if !isempty(witnesses)
                    (available=true,status="certified_infeasible_within_tolerances",basis="constant_encoded_equalities",
                        witnesses=witnesses,matched_subset_rows=length(signature.rows))
                else
                    capacity=T.tolerant_capacity_certificate(part,d;contract=:absolute_unscaled,
                        equality_tolerance=tau,generator_bound_tolerance=tau,voltage_bound_tolerance=tau)
                    (available=capacity.available,status=capacity.status,basis="island_encoded_capacity",
                        capacity=capacity,matched_subset_rows=length(signature.rows))
                end
            catch e
                e isa InterruptException && rethrow()
                (available=false,status="unavailable",reason=sprint(showerror,e))
            end
            push!(results,(buses=buses,result=result))
        end
        proven=any(r->r.result.status=="certified_infeasible_within_tolerances",results)
        complete=all(r->r.result.available,results)
        (available=proven || complete,status=proven ? "certified_infeasible_within_tolerances" : complete ? "not_ruled_out" : "unavailable",
            contract_digest=contract.contract_digest,absolute_tolerance_exact=string(tau),islands=results,
            limitation="A sufficient contradiction in verified original rows. Partial unavailability is retained. No feasibility, solver acceptance, source-unit correctness, or optimality claim. Post-evaluation experimental follow-up.")
    catch e
        e isa InterruptException && rethrow()
        (available=false,status="unavailable",reason=sprint(showerror,e))
    end
end
"""Reject certified island contradictions before solving; otherwise use the frozen verified workflow."""
function solve_with_island_preflight(pm,data;absolute_tolerance=1e-6)
    preflight=island_capacity_certificate(pm,data;absolute_tolerance)
    if !preflight.available
        return (available=false,status="preflight_unavailable",preflight=preflight,solver_invoked=false)
    elseif preflight.status=="certified_infeasible_within_tolerances"
        return (available=true,status="rejected_by_island_certificate",preflight=preflight,solver_invoked=false)
    end
    solved=V.solve_and_verify(pm,data;absolute_tolerance)
    (available=solved.available,status=solved.status,preflight=preflight,solve=solved,
        solver_workflow_invoked=true)
end

end
