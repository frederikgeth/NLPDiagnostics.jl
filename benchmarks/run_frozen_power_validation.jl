using JSON, SHA, Dates, Test
include(joinpath(@__DIR__, "common.jl"))
using .NLPDiagnosticsBenchmarkCommon
const ROOT_FRESH=repo_root()
const PLAN_PATH=joinpath(ROOT_FRESH,"docs","power_workflow_validation_freeze.json")
const PLAN=JSON.parsefile(PLAN_PATH)
const PLAN_SHA=bytes2hex(sha256(read(PLAN_PATH)))
function guard()
    bytes2hex(sha256(read(PLAN_PATH)))==PLAN_SHA || error("freeze plan changed")
    for (p,h) in PLAN["file_sha256"]
        bytes2hex(sha256(read(joinpath(ROOT_FRESH,p))))==h || error("frozen input changed: $p")
    end
end
guard()
include("power_repair_pilot/verified_solver_acceptance.jl")
using .VerifiedSolverAcceptance
const V=VerifiedSolverAcceptance
const E=V.E
const PM=E.PM
const OUT=joinpath(ROOT_FRESH,"work","frozen-power-workflow-validation")
isdir(OUT) && !isempty(readdir(OUT)) && error("refusing to overwrite frozen evaluation artifacts")
mkpath(OUT)
const VARIANTS=["clean","zero_capacity","marginal_shortage","isolated_load","load_units","valid_rebase","unsupported_storage"]

function mutate(original,kind)
    d=deepcopy(original);truth=Dict{String,Any}("kind"=>kind)
    if kind in ("zero_capacity","marginal_shortage")
        demand=sum(E.Q(l["pd"]) for l in values(d["load"]) if l["status"]==1)
        for g in values(d["gen"])
            g["gen_status"]==1 || continue
            g["pmax"]=0.0;g["pmin"]=min(g["pmin"],0.0)
        end
        if kind=="marginal_shortage"
            id=first(sort!([k for (k,g) in d["gen"] if g["gen_status"]==1];by=x->parse(Int,x)))
            d["gen"][id]["pmax"]=Float64(demand)-1e-8
        end
        cap=sum(E.Q(g["pmax"]) for g in values(d["gen"]) if g["gen_status"]==1)
        truth["source_capacity_gap_exact_pu"]=string(demand-cap)
        truth["positive_source_gap"]=demand>cap
    elseif kind=="isolated_load"
        genbus=Set(Int(g["gen_bus"]) for g in values(d["gen"]) if g["gen_status"]==1)
        candidates=sort!(unique([Int(l["load_bus"]) for l in values(d["load"]) if l["status"]==1 && l["pd"]>0 && !(Int(l["load_bus"]) in genbus)]))
        bus=first(candidates)
        removed=String[]
        for (id,b) in d["branch"]
            if b["br_status"]==1 && bus in (Int(b["f_bus"]),Int(b["t_bus"]))
                b["br_status"]=0;push!(removed,id)
            end
        end
        demand=sum(E.Q(l["pd"]) for l in values(d["load"]) if l["status"]==1 && Int(l["load_bus"])==bus)
        truth["isolated_bus"]=bus;truth["removed_branches"]=sort!(removed)
        truth["island_demand_exact_pu"]=string(demand)
        truth["isolated_unsupplied_load"]=demand>0 && !(bus in genbus) && all(b["br_status"]!=1 || !(bus in (Int(b["f_bus"]),Int(b["t_bus"]))) for b in values(d["branch"]))
    elseif kind=="load_units"
        for l in values(d["load"]);l["pd"]/=d["baseMVA"];end
        truth["source_intent_mismatch"]=any(l["pd"]!=original["load"][id]["pd"] for (id,l) in d["load"])
        truth["meaning"]="Already per-unit active loads divided by baseMVA a second time; mathematical feasibility does not detect source intent."
    elseif kind=="valid_rebase"
        # PowerModels mixed-unit conversion leaves branch impedance/admittance
        # in per unit, so those coordinates need an explicit base transformation.
        PM.make_mixed_units!(d)
        d["baseMVA"]*=2
        for b in values(d["branch"])
            for k in ("br_r","br_x");b[k]*=2;end
            for k in ("g_fr","g_to","b_fr","b_to");b[k]/=2;end
        end
        PM.make_per_unit!(d)
        truth["base_ratio"]=2
        truth["physical_load_preserved"]=all(isapprox(l["pd"]*d["baseMVA"],original["load"][id]["pd"]*original["baseMVA"];atol=1e-10,rtol=1e-12) for (id,l) in d["load"])
        truth["impedance_rebased"]=all(b["br_r"]==2*original["branch"][id]["br_r"] && b["br_x"]==2*original["branch"][id]["br_x"] for (id,b) in d["branch"])
    elseif kind=="unsupported_storage"
        bus=minimum(parse.(Int,collect(keys(d["bus"]))))
        d["storage"]=Dict("1"=>Dict("index"=>1,"storage_bus"=>bus,"status"=>1,
            "ps"=>0.0,"qs"=>0.0,"energy"=>0.0,"energy_rating"=>1.0,"charge_rating"=>1.0,"discharge_rating"=>1.0,
            "charge_efficiency"=>1.0,"discharge_efficiency"=>1.0,"thermal_rating"=>1.0,"qmin"=>-1.0,"qmax"=>1.0,
            "r"=>0.0,"x"=>0.0,"p_loss"=>0.0,"q_loss"=>0.0))
        truth["unsupported_component_present"]=true
    end
    d,truth
end
function outcome(d,kind)
    try
        # Unsupported equipment is refused at the workflow's scope check.
        pm=kind=="unsupported_storage" ? nothing : PM.instantiate_model(d,PM.ACPPowerModel,PM.build_opf)
        solve_and_verify(pm,d;absolute_tolerance=1e-6)
    catch e
        e isa InterruptException && rethrow()
        (available=false,status="unavailable",reason=sprint(showerror,e))
    end
end
records=Dict{String,Any}();criteria=Dict{String,Bool}()
for name in PLAN["networks"]
    println("Starting frozen network ",name);flush(stdout)
    parsed=try
        PM.parse_file(joinpath(ROOT_FRESH,"test","fixtures","power_repair_$name.m"))
    catch e
        e isa InterruptException && rethrow()
        (parse_error=sprint(showerror,e),)
    end
    for kind in VARIANTS
        guard();id="$name/$kind";dir=joinpath(OUT,name,kind);mkpath(dir)
        started=time_ns()
        truth=Dict{String,Any}();result=nothing;input_hash=nothing
        try
            parsed isa AbstractDict || error(parsed.parse_error)
            d,truth=mutate(parsed,kind)
            write_json(joinpath(dir,"input.json"),d)
            input_hash=bytes2hex(sha256(read(joinpath(dir,"input.json"))))
            # Data check is truth-premise evidence, not fed into ranking or tuning.
            truth["source_scope_check"]=V.T.ECC.CMC.PowerCapacityPreflight.capacity_preflight(d;contract=:closed_acp_fixed_load)
            result=outcome(d,kind)
        catch e
            e isa InterruptException && rethrow()
            result=(available=false,status="unavailable",reason=sprint(showerror,e))
        end
        record=Dict("id"=>id,"truth"=>truth,"result"=>result,"input_sha256"=>input_hash,"seconds"=>(time_ns()-started)/1e9)
        write_json(joinpath(dir,"record.json"),record)
        # Read serialized evidence to avoid different NamedTuple/JSON access paths.
        records[id]=JSON.parsefile(joinpath(dir,"record.json"))
        guard();println(id," => ",result.status);flush(stdout)
    end
    r(k)=records["$name/$k"]["result"]
    cs(k)=get(get(r(k),"certificate",Dict()),"status","")
    criteria["$name/clean_accepted"]=r("clean")["status"]=="accepted_primal_point"
    criteria["$name/zero_capacity_certified"]=cs("zero_capacity")=="certified_infeasible_within_tolerances" && r("zero_capacity")["status"]!="accepted_primal_point"
    criteria["$name/marginal_not_overclaimed"]=cs("marginal_shortage")=="not_ruled_out" && get(records["$name/marginal_shortage"]["truth"],"positive_source_gap",false)
    criteria["$name/island_shortage_certified"]=cs("isolated_load")=="certified_infeasible_within_tolerances" && get(records["$name/isolated_load"]["truth"],"isolated_unsupplied_load",false)
    criteria["$name/unit_corruption_rejected"]=r("load_units")["status"] in ("primal_violated","primal_inconclusive") && get(records["$name/load_units"]["truth"],"source_intent_mismatch",false)
    criteria["$name/rebase_accepted"]=r("valid_rebase")["status"]=="accepted_primal_point" && get(records["$name/valid_rebase"]["truth"],"physical_load_preserved",false) && get(records["$name/valid_rebase"]["truth"],"impedance_rebased",false)
    criteria["$name/storage_explicitly_unavailable"]=r("unsupported_storage")["status"]=="unavailable" && occursin("unsupported device collection: storage",get(r("unsupported_storage"),"reason",""))
end
guard()
write_json(joinpath(OUT,"evaluation.json"),Dict("schema_version"=>"frozen-power-workflow-validation-v1",
    "plan_sha256"=>PLAN_SHA,"criteria"=>criteria,"criteria_met"=>all(values(criteria)),
    "passed"=>count(values(criteria)),"total"=>length(criteria),"completed_utc"=>string(now(UTC)),
    "interpretation"=>"Frozen development-transfer evaluation, not blinded validation or engineer repair benefit. Failed criteria and unavailable cases are retained."))
@testset "Frozen evaluation integrity, not acceptance" begin
    @test length(records)==14
    @test Set(keys(criteria))==Set(PLAN["acceptance_criteria_ids"])
    @test all(haskey(r,"result") && haskey(r,"truth") for r in values(records))
    @test all(get(r,"input_sha256",nothing)!==nothing for r in values(records))
    guard();@test true
end
println("Evaluation passed ",count(values(criteria)),"/",length(criteria)," criteria; accepted=",all(values(criteria)))
