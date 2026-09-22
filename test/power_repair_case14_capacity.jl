using JSON, SHA, Test
const CAP_ROOT=normpath(joinpath(@__DIR__,".."))
const CAP_PLAN_PATH=joinpath(CAP_ROOT,"docs","power_repair_case14_freeze.json")
const CAP_PLAN=JSON.parsefile(CAP_PLAN_PATH)
const CAP_PLAN_SHA=bytes2hex(sha256(read(CAP_PLAN_PATH)))
function verify_capacity_freeze()
    for (path,sha) in CAP_PLAN["file_sha256"]
        bytes2hex(sha256(read(joinpath(CAP_ROOT,path))))==sha || error("frozen input changed: $path")
    end
    bytes2hex(sha256(read(CAP_PLAN_PATH)))==CAP_PLAN_SHA || error("capacity plan changed")
end
# Independent data-level witness for a closed passive ACP network.
function capacity_witness(data)
    for kind in ("dcline","storage","switch")
        isempty(get(data,kind,Dict())) || error("unsupported external/device power: $kind")
    end
    data["per_unit"]===true || error("per-unit data required")
    finite_nonnegative(v)=v isa Real && isfinite(v) && v>=0
    for l in values(data["load"])
        l["status"]==0 && continue
        finite_nonnegative(l["pd"]) || error("negative or invalid load")
    end
    for s in values(data["shunt"])
        s["status"]==0 && continue
        finite_nonnegative(s["gs"]) || error("active-power producing shunt")
    end
    for b in values(data["branch"])
        b["br_status"]==0 && continue
        all(finite_nonnegative(b[k]) for k in ("br_r","g_fr","g_to")) || error("nonpassive branch")
        isfinite(b["br_x"]) && !iszero(complex(b["br_r"],b["br_x"])) || error("invalid series impedance")
        isfinite(b["tap"]) && b["tap"]>0 && isfinite(b["shift"]) || error("invalid transformer")
    end
    exact(v)=isfinite(v) ? Rational{BigInt}(v) : error("nonfinite power")
    demand=sum((exact(l["pd"]) for l in values(data["load"]) if l["status"]!=0);init=big(0)//1)
    capacity=sum((exact(g["pmax"]) for g in values(data["gen"]) if g["gen_status"]!=0);init=big(0)//1)
    Dict("demand_exact_pu"=>string(demand),"capacity_exact_pu"=>string(capacity),
        "gap_exact_pu"=>string(demand-capacity),"shortage"=>demand>capacity,
        "scope"=>"closed passive ACP data; nonnegative loads and shunt conductance, passive branches, no DC/storage/switch power",
        "argument"=>"Summed active-power balance requires generation = load + nonnegative losses; generation cannot exceed summed pmax.")
end
verify_capacity_freeze()
include("power_repair_case9_validation.jl")
verify_capacity_freeze()
cap_out=joinpath(CAP_ROOT,"work","power-repair-case14-capacity")
mkpath(cap_out)
cap_data=Pilot.PM.parse_file(joinpath(CAP_ROOT,CAP_PLAN["fixture"]))
cap_base=Pilot.build(cap_data)
cap_solve=Pilot.solve!(cap_base,joinpath(cap_out,"baseline-ipopt.log"))
cap_checks=Pilot.checked_physics(cap_data,get(cap_solve,"solution",nothing))
Pilot.save(joinpath(cap_out,"baseline.json"),Dict("solve"=>cap_solve,"physical_checks"=>cap_checks))
cap_checks["passed"] || error("case14 baseline physical check failed; evaluation not retuned")
cap_point=Pilot.pointmap(cap_base)
Pilot.save(joinpath(cap_out,"original_data.json"),cap_data)
Pilot.save(joinpath(cap_out,"original_point.json"),cap_point)
cap_records=Any[]
for id in ("clean","shortage_inherited_start","shortage_bounded_start")
    println("Capacity variant: ",id)
    dir=joinpath(cap_out,id);mkpath(dir)
    modified=deepcopy(cap_data);patches=Any[]
    if id!="clean"
        for gid in sort!(collect(keys(modified["gen"]));by=x->parse(Int,x))
            g=modified["gen"][gid];g["gen_status"]==0 && continue
            for (field,new) in (("pmax",0.0),("pmin",min(g["pmin"],0.0)))
                push!(patches,Dict("gen"=>gid,"field"=>field,"before"=>g[field],"after"=>new));g[field]=new
            end
        end
    end
    pm=Pilot.build(modified);initial=copy(cap_point)
    if id=="shortage_bounded_start"
        for gid in keys(modified["gen"])
            modified["gen"][gid]["gen_status"]==0 && continue
            v=Pilot.PM.var(pm,:pg,parse(Int,gid));initial[Pilot.JuMP.name(v)]=0.0
        end
    end
    Pilot.starts!(pm,initial)
    diag=Pilot.diagnose(pm)
    # Truth is computed after diagnostics and is never supplied to them.
    witness=capacity_witness(modified)
    solved=Pilot.solve!(pm,joinpath(dir,"modified-ipopt.log"))
    physical=Pilot.checked_physics(modified,get(solved,"solution",nothing))
    restored=deepcopy(modified)
    for patch in patches;restored["gen"][patch["gen"]][patch["field"]]=patch["before"];end
    isequal(restored,cap_data) || error("repair did not restore source")
    repaired=Pilot.build(restored);Pilot.starts!(repaired,cap_point)
    repair=Pilot.solve!(repaired,joinpath(dir,"repair-ipopt.log"))
    repair_physical=Pilot.checked_physics(cap_data,get(repair,"solution",nothing))
    static_errors=filter(f->f["severity"]=="error",diag["static"]["findings"])
    record=Dict("id"=>id,"witness"=>witness,"diagnostics"=>diag,"modified_solve"=>solved,
        "modified_physical_checks"=>physical,"static_error_count"=>length(static_errors),
        "ranked_error_count"=>length(diag["ranked_actionable"]),"repair_solve"=>repair,
        "repair_physical_checks"=>repair_physical,"repair_input_restored"=>isequal(restored,cap_data),
        "repair_source"=>"scripted inverse patches and original starts; no human/autonomous repair claim")
    for (file,value) in (("modified_data",modified),("modified_point",initial),("patches",patches),
                         ("repaired_data",restored),("repaired_point",cap_point),("record",record))
        Pilot.save(joinpath(dir,file*".json"),value)
    end
    push!(cap_records,record)
end
verify_capacity_freeze()
cap_byid=Dict(r["id"]=>r for r in cap_records)
criteria=Dict("clean_no_errors"=>cap_byid["clean"]["ranked_error_count"]==0,
    "both_shortages_certified"=>all(cap_byid[id]["witness"]["shortage"] for id in ("shortage_inherited_start","shortage_bounded_start")),
    "both_shortages_rejected_physically"=>all(cap_byid[id]["modified_physical_checks"]["available"] && !cap_byid[id]["modified_physical_checks"]["passed"] for id in ("shortage_inherited_start","shortage_bounded_start")),
    "all_repairs_verified"=>all(r["repair_physical_checks"]["passed"] for r in cap_records),
    "bounded_shortage_static_error"=>cap_byid["shortage_bounded_start"]["static_error_count"]>0,
    "diagnostics_available"=>all(r["diagnostics"]["available"] for r in cap_records))
Pilot.save(joinpath(cap_out,"evaluation.json"),Dict("schema_version"=>"power-repair-capacity-evaluation-v1",
    "plan_sha256"=>CAP_PLAN_SHA,"criteria"=>criteria,"criteria_met"=>all(values(criteria)),
    "records"=>cap_records,"human_repair_time"=>nothing,
    "interpretation"=>"new injected capacity family on case14; misses are retained; not a real incident or blind field study"))
@testset "Capacity witness and evaluation integrity" begin
    @test !capacity_witness(cap_data)["shortage"]
    for r in cap_records
        @test r["repair_input_restored"]
        @test r["witness"]["shortage"]==(r["id"]!="clean")
    end
    hostile=deepcopy(cap_data);first(values(hostile["branch"]))["br_r"]=-0.01
    @test_throws ErrorException capacity_witness(hostile)
    hostile=deepcopy(cap_data);first(values(hostile["load"]))["pd"]=-1.0
    @test_throws ErrorException capacity_witness(hostile)
    @test Set(keys(criteria))==Set(CAP_PLAN["acceptance_criteria_ids"])
end
println("Capacity evaluation criteria: ",criteria)
