using Test, JSON, SHA
include("../benchmarks/power_repair_pilot/load_status_contract.jl")
using .LoadStatusContract
const L=LoadStatusContract
const E=L.E
const ROOT_STATUS=normpath(joinpath(@__DIR__,".."))
const freeze=JSON.parsefile(joinpath(ROOT_STATUS,"docs","integrated_report_freeze.json"))
reference(n)=L.S.SourceLoadReference(joinpath(ROOT_STATUS,"test","fixtures","power_report_$n.m"),freeze["file_sha256"]["test/fixtures/power_report_$n.m"])
input(n)=E.CMC.materialize(JSON.parsefile(joinpath(ROOT_STATUS,"work","frozen-integrated-report-validation",n,"clean","input.json")))
function baseline(d,ref)
    Dict{String,Any}("source_sha256"=>ref.sha256,"source_revision"=>"synthetic-review-fixture-v1",
        "nominal_loads"=>Dict(id=>Dict("bus"=>l["load_bus"],"pd_mw"=>l["pd"]*d["baseMVA"],"qd_mvar"=>l["qd"]*d["baseMVA"]) for (id,l) in d["load"]),"events"=>Any[])
end
event(id,a,b,key)=Dict("load_id"=>id,"from"=>a,"to"=>b,"event_id"=>key,"reason"=>"synthetic switching test","evidence_ref"=>"test fixture; not a real operator authorization")
results=Dict{String,Any}()
@testset "Explicit disconnect and reconnect history" begin
    d=input("case7_tplgy");ref=reference("case7_tplgy");c=baseline(d,ref)
    @test check_load_status_contract(d,ref,c).status=="unavailable"
    push!(c["events"],event("3",1,0,"off-3"))
    r=check_load_status_contract(d,ref,c)
    results["declared_disconnect"]=r
    @test r.available && r.status=="source_consistent"
    @test r.disabled_load_ids==["3"]
    c["events"][1]["reason"]="edited after validation"
    @test r.switching_events[1]["reason"]=="synthetic switching test"
    c["events"][1]["reason"]="synthetic switching test"
    @test r.comparison_scope=="nominal_loads_before_declared_switching"
    d["load"]["3"]["status"]=1
    @test check_load_status_contract(d,ref,c).status=="unavailable"
    push!(c["events"],event("3",0,1,"on-3"))
    @test check_load_status_contract(d,ref,c).status=="source_consistent"
    @test isempty(check_load_status_contract(d,ref,c).disabled_load_ids)
    broken=deepcopy(c);broken["events"][2]["from"]=1
    @test check_load_status_contract(d,ref,broken).status=="unavailable"
    broken=deepcopy(c);broken["events"][2]["event_id"]="off-3"
    @test check_load_status_contract(d,ref,broken).status=="unavailable"
    broken=deepcopy(c);broken["events"][1]["reason"]=""
    @test check_load_status_contract(d,ref,broken).status=="unavailable"
    broken=deepcopy(c);broken["events"][1]["evidence_ref"]=""
    @test check_load_status_contract(d,ref,broken).status=="unavailable"
    broken=deepcopy(c);push!(broken["events"],event("3",1,1,"no-change"))
    @test check_load_status_contract(d,ref,broken).status=="unavailable"
    broken=deepcopy(c);broken["source_sha256"]="stale"
    @test check_load_status_contract(d,ref,broken).status=="unavailable"
    missing=deepcopy(d);delete!(missing["load"],"3")
    @test check_load_status_contract(missing,ref,c).status=="unavailable"
    moved=deepcopy(d);moved["load"]["3"]["load_bus"]=2
    @test check_load_status_contract(moved,ref,c).status=="unavailable"
    changed=deepcopy(d);changed["load"]["3"]["pd"]=0.0
    @test check_load_status_contract(changed,ref,c).status=="unavailable"
    @test_throws ErrorException L.status_value(true)
end
@testset "Switching provenance cannot authorize unsupported models" begin
    d=input("case7_tplgy");ref=reference("case7_tplgy");c=baseline(d,ref)
    push!(c["events"],event("3",1,0,"off-3"))
    pm=E.PM.instantiate_model(d,E.PM.ACPPowerModel,E.PM.build_opf)
    r=diagnose_with_load_status(pm,d,ref,c)
    results["partial_with_declared_switching"]=r
    @test r["status"]=="partial_results"
    @test r["stages"][2]["status"]=="source_consistent"
    @test r["stages"][4]["status"]=="not_run"
    @test !r["model_binding_verified"]
    @test r["evidence"]["solver_invoked"]==false
    clean=input("case6");ref6=reference("case6");c6=baseline(clean,ref6)
    pm6=E.PM.instantiate_model(clean,E.PM.ACPPowerModel,E.PM.build_opf)
    verified=diagnose_with_load_status(pm6,clean,ref6,c6)
    @test verified["status"]=="accepted_primal_point"
end
@testset "Original freezes retained" begin
    for n in ("power_repair_case9_freeze","power_repair_case14_freeze","power_workflow_validation_freeze","integrated_report_freeze")
        f=JSON.parsefile(joinpath(ROOT_STATUS,"docs","$n.json"))
        @test all(bytes2hex(sha256(read(joinpath(ROOT_STATUS,p))))==h for (p,h) in f["file_sha256"])
    end
end
out=joinpath(ROOT_STATUS,"work","load-status-followup");mkpath(out)
write(joinpath(out,"summary.json"),JSON.json(Dict("schema_version"=>"load-status-followup-v1","scope"=>"Synthetic caller-declared events, not real authorization", "results"=>results)))
write(joinpath(out,"report.json"),JSON.json(results["partial_with_declared_switching"]))
write(joinpath(out,"report.md"),L.P.markdown_partial(results["partial_with_declared_switching"]))
