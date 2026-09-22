using JSON, SHA, Test
include(joinpath(@__DIR__, "common.jl"))
using .NLPDiagnosticsBenchmarkCommon
const ROOT_STATUS_VALIDATION=repo_root()
const PLAN_PATH=joinpath(ROOT_STATUS_VALIDATION,"docs","status_provenance_freeze.json")
const PLAN=JSON.parsefile(PLAN_PATH)
const PLAN_SHA=bytes2hex(sha256(read(PLAN_PATH)))
function guard()
    bytes2hex(sha256(read(PLAN_PATH)))==PLAN_SHA || error("plan changed")
    for (p,h) in PLAN["file_sha256"]
        bytes2hex(sha256(read(joinpath(ROOT_STATUS_VALIDATION,p))))==h || error("frozen input changed: $p")
    end
end
guard()
include("power_repair_pilot/load_status_contract.jl")
using .LoadStatusContract
const L=LoadStatusContract
const E=L.E
const FIX=joinpath(ROOT_STATUS_VALIDATION,"test","fixtures","status_provenance")
const OUT=joinpath(ROOT_STATUS_VALIDATION,"work","frozen-status-provenance-validation")
!isdir(OUT) || isempty(readdir(OUT)) || error("refusing overwrite")
mkpath(OUT)
const SOURCE=JSON.parsefile(joinpath(FIX,"source_manifest.json"))
const REFERENCE=L.S.SourceLoadReference(joinpath(FIX,"source.m"),SOURCE["source_sha256"])
function event(id,from,to,key; evidence="synthetic-event-record")
    Dict("load_id"=>id,"from"=>from,"to"=>to,"event_id"=>key,"reason"=>"declared synthetic study transition","evidence_ref"=>evidence)
end
records=Dict{String,Any}();criteria=Dict{String,Bool}()
for name in PLAN["scenarios"]
    guard();dir=joinpath(OUT,name);mkpath(dir)
    report=nothing;input_hash=nothing;contract_hash=nothing
    try
        data=E.PM.parse_file(joinpath(FIX,"source.m"))
        data["load"]=E.CMC.materialize(JSON.parsefile(joinpath(FIX,"model_load_blueprint.json")))
        contract=E.CMC.materialize(JSON.parsefile(joinpath(FIX,"reference_contract.json")))
        rebase=nothing
        if name=="reconnection"
            push!(contract["events"],event("1",1,0,"off"),event("1",0,1,"on"))
        elseif name=="undeclared_disconnection"
            data["load"]["1"]["status"]=0
        elseif name=="omitted_record"
            delete!(data["load"],"2")
        elseif name=="stale_hash"
            contract["source_sha256"]=repeat("0",64)
        elseif name=="stale_revision_label"
            contract["source_revision"]="synthetic-load-r0"
        elseif name=="wrong_allocation"
            contract["nominal_loads"]["1"]["pd_mw"]=19
            contract["nominal_loads"]["2"]["pd_mw"]=11
        elseif name=="valid_rebase"
            E.PM.make_mixed_units!(data);data["baseMVA"]=200.0
            for b in values(data["branch"])
                for k in ("br_r","br_x");b[k]*=2;end
                for k in ("g_fr","g_to","b_fr","b_to");b[k]/=2;end
            end
            E.PM.make_per_unit!(data);rebase=200
        elseif name=="unverified_evidence_reference"
            data["load"]["1"]["status"]=0
            push!(contract["events"],event("1",1,0,"off";evidence="unverified-approval-claim"))
        end
        write_json(joinpath(dir,"input.json"),data);write_json(joinpath(dir,"contract.json"),contract)
        input_hash=bytes2hex(sha256(read(joinpath(dir,"input.json"))))
        contract_hash=bytes2hex(sha256(read(joinpath(dir,"contract.json"))))
        pm=E.PM.instantiate_model(data,E.PM.ACPPowerModel,E.PM.build_opf)
        report=diagnose_with_load_status(pm,data,REFERENCE,contract;rebase_to=rebase)
    catch e
        e isa InterruptException && rethrow()
        report=L.P.R.summarize_workflow((available=false,status="validation_unavailable",reason=sprint(showerror,e)))
        report["model_binding_verified"]=false
    end
    report["input_sha256"]=input_hash;report["contract_sha256"]=contract_hash
    write_json(joinpath(dir,"report.json"),report)
    write(joinpath(dir,"report.md"),L.P.markdown_partial(report))
    records[name]=report
    criteria[name]=if name in ("baseline","reconnection","valid_rebase")
        report["status"]=="accepted_primal_point"
    elseif name=="unverified_evidence_reference"
        # Mechanical interpretation boundary only: no human-comprehension claim.
        occursin("not authenticated",join(report["limits"]," ")) && !haskey(report,"authorization_verified")
    else
        report["status"]=="source_contract_unavailable"
    end
    guard();println(name," => ",report["status"],"; criterion=",criteria[name]);flush(stdout)
end
write_json(joinpath(OUT,"evaluation.json"),Dict("schema_version"=>"status-provenance-evaluation-v1",
    "plan_sha256"=>PLAN_SHA,"criteria"=>criteria,"passed"=>count(values(criteria)),"total"=>length(criteria),
    "criteria_met"=>all(values(criteria)),"human_interpretation_review"=>"not_run"))
@testset "Frozen status evaluation integrity" begin
    @test Set(keys(records))==Set(PLAN["scenarios"])
    @test all(!isnothing(r["input_sha256"]) && !isnothing(r["contract_sha256"]) for r in values(records))
    @test all(haskey(r,"limits") for r in values(records))
    guard();@test true
end
println("Criteria: ",count(values(criteria)),"/",length(criteria))
