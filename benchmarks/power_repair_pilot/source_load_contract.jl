module SourceLoadContract
include("island_capacity_certificate.jl")
const I=IslandCapacityCertificate
const E=I.E
using SHA
export SourceLoadReference, check_source_loads, solve_with_source_contract

"""Caller-selected numeric MATPOWER bus-table reference, pinned by file hash."""
struct SourceLoadReference
    path::String
    sha256::String
end
function decimal(s)
    m=match(r"^([+-]?)(\d+)(?:\.(\d*))?(?:[eE]([+-]?\d+))?$",s)
    isnothing(m) && error("unsupported numeric literal: $s")
    fraction=something(m[3],"");exponent=parse(Int,something(m[4],"0"))-length(fraction)
    abs(exponent)<=1000 || error("source exponent outside supported range")
    value=parse(BigInt,m[2]*fraction)*(m[1]=="-" ? -1 : 1)
    exponent>=0 ? (value*big(10)^exponent)//1 : value//big(10)^(-exponent)
end
function read_reference(reference)
    bytes=read(reference.path)
    bytes2hex(sha256(bytes))==reference.sha256 || error("source bytes no longer match selected hash")
    text=replace(String(bytes),r"%[^\n]*"=>"")
    bases=collect(eachmatch(r"mpc\.baseMVA\s*=\s*([^;]+);",text))
    tables=collect(eachmatch(r"mpc\.bus\s*=\s*\[([^\]]+)\]\s*;"s,text))
    length(bases)==length(tables)==1 || error("one numeric baseMVA and bus table required")
    base=decimal(strip(only(bases)[1]));base>0 || error("positive source base required")
    buses=Dict{Int,Tuple{E.Q,E.Q}}()
    for line in split(only(tables)[1],';')
        isempty(strip(line)) && continue
        fields=decimal.(split(strip(line)))
        length(fields)==13 || error("13-column numeric bus table required")
        id=fields[1];denominator(id)==1 && id>0 || error("positive integer bus id required")
        bus=Int(id);haskey(buses,bus) && error("duplicate source bus")
        buses[bus]=(fields[3],fields[4])
    end
    isempty(buses) && error("empty source bus table")
    (base=base,buses=buses)
end
"""
Compare per-bus active/reactive load totals in physical MW/MVAr with the selected
source table. Rebased data requires an explicit target base. No source intent is
inferred from feasibility, filenames, or a guessed conversion operation.
"""
function check_source_loads(data,reference::SourceLoadReference;rebase_to=nothing,physical_tolerance=1e-8)
    try
        tolerance=I.T.tolerance(physical_tolerance)
        source=read_reference(reference)
        data["per_unit"]===true || error("per-unit data declaration required")
        base=E.exact(data["baseMVA"]);base>0 || error("positive model base required")
        if !isnothing(rebase_to)
            E.exact(rebase_to)==base || error("declared rebase target differs from model base")
        elseif base!=source.base
            error("changed power base requires an explicit rebase target")
        end
        Set(parse.(Int,collect(keys(data["bus"]))))==Set(keys(source.buses)) || error("source/model bus mapping differs")
        sums=Dict(b=>(zero(E.Q),zero(E.Q)) for b in keys(source.buses))
        ids=Dict(b=>String[] for b in keys(source.buses))
        for (id,load) in data["load"]
            load["status"]==1 || error("load status changes require a revised source contract")
            b=Int(load["load_bus"]);haskey(sums,b) || error("load maps outside source buses")
            p,q=sums[b]
            sums[b]=(p+E.exact(load["pd"])*base,q+E.exact(load["qd"])*base)
            push!(ids[b],string(id))
        end
        checks=Any[]
        for b in sort!(collect(keys(source.buses))), (i,field) in enumerate(("pd","qd"))
            expected=source.buses[b][i];actual=sums[b][i];residual=actual-expected
            push!(checks,(bus=b,load_ids=sort(ids[b]),field=field,units=i==1 ? "MW" : "MVAr",
                source_exact=string(expected),actual_exact=string(actual),residual_exact=string(residual),
                mismatch=abs(residual)>tolerance))
        end
        (available=true,status=any(c->c.mismatch,checks) ? "source_mismatch" : "source_consistent",
            source_sha256=reference.sha256,source_base_exact=string(source.base),model_base_exact=string(base),
            rebase_declared=!isnothing(rebase_to),physical_tolerance_exact=string(tolerance),checks=checks,
            limitation="Agreement with caller-selected numeric bus-table loads only. Does not authenticate intent, execute MATPOWER code, identify the conversion bug, or verify generator/branch units or full rebasing equivalence.")
    catch e
        e isa InterruptException && rethrow()
        (available=false,status="unavailable",reason=sprint(showerror,e))
    end
end
function solve_with_source_contract(pm,data,reference::SourceLoadReference;
        rebase_to=nothing,physical_tolerance=1e-8,absolute_tolerance=1e-6)
    model=E.CMC.checked_capacity_preflight(pm,data)
    model.available || return (available=false,status="model_contract_unavailable",reason=model.reason,solver_invoked=false)
    lineage=check_source_loads(data,reference;rebase_to,physical_tolerance)
    if !lineage.available
        return (available=false,status="source_contract_unavailable",lineage=lineage,solver_invoked=false)
    elseif lineage.status=="source_mismatch"
        return (available=true,status="rejected_by_source_mismatch",lineage=lineage,model_contract_digest=model.contract_digest,solver_invoked=false)
    end
    workflow=I.solve_with_island_preflight(pm,data;absolute_tolerance)
    (available=workflow.available,status=workflow.status,lineage=lineage,workflow=workflow)
end
end
