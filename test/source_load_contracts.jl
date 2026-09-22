using Test, JSON, SHA
include("../benchmarks/power_repair_pilot/source_load_contract.jl")
using .SourceLoadContract
const S=SourceLoadContract
const E=S.E
const ROOT_SOURCE=normpath(joinpath(@__DIR__,".."))
const freeze=JSON.parsefile(joinpath(ROOT_SOURCE,"docs","power_workflow_validation_freeze.json"))
reference(n)=SourceLoadReference(joinpath(ROOT_SOURCE,"test","fixtures","power_repair_$n.m"),freeze["file_sha256"]["test/fixtures/power_repair_$n.m"])
load_input(n,v)=E.CMC.materialize(JSON.parsefile(joinpath(ROOT_SOURCE,"work","frozen-power-workflow-validation",n,v,"input.json")))
build_source(d)=E.PM.instantiate_model(E.CMC.materialize(d),E.PM.ACPPowerModel,E.PM.build_opf)
results=Dict{String,Any}()
@testset "Physical source loads and declared rebasing" begin
    @test S.decimal("1.25e2")==125
    @test S.decimal("-0.001")==-1//1000
    @test_throws ErrorException S.decimal("NaN")
    for n in ("case24","case30")
        ref=reference(n)
        clean=load_input(n,"clean")
        @test check_source_loads(clean,ref).status=="source_consistent"
        corrupted=load_input(n,"load_units")
        mismatch=check_source_loads(corrupted,ref)
        results["$n/unit_mismatch"]=mismatch
        @test mismatch.available && mismatch.status=="source_mismatch"
        @test any(c->c.field=="pd" && c.mismatch,mismatch.checks)
        @test all(c->c.field!="qd" || !c.mismatch,mismatch.checks)
        flow=solve_with_source_contract(build_source(corrupted),corrupted,ref)
        results["$n/rejected_workflow"]=flow
        @test flow.status=="rejected_by_source_mismatch"
        @test !flow.solver_invoked
        rebased=load_input(n,"valid_rebase")
        @test check_source_loads(rebased,ref).status=="unavailable"
        @test check_source_loads(rebased,ref;rebase_to=200).status=="source_consistent"
        @test check_source_loads(rebased,ref;rebase_to=300).status=="unavailable"
        wrong=deepcopy(clean);wrong["baseMVA"]=200.0
        @test check_source_loads(wrong,ref;rebase_to=200).status=="source_mismatch"
        # The check is per bus: splitting one record without changing its total is allowed.
        split=deepcopy(clean);id=first(sort!(collect(keys(split["load"]))))
        extra=deepcopy(split["load"][id]);extra["index"]=999
        for field in ("pd","qd");split["load"][id][field]/=2;extra[field]/=2;end
        split["load"]["999"]=extra
        @test check_source_loads(split,ref).status=="source_consistent"
        split["load"][id]["status"]=0
        @test check_source_loads(split,ref).status=="unavailable"
        @test check_source_loads(clean,ref;physical_tolerance=-1).status=="unavailable"
        bad=deepcopy(clean);bad["load"][id]["qd"]=NaN
        @test check_source_loads(bad,ref).status=="unavailable"
    end
end
@testset "Pinned reference identity and revised source selection" begin
    d=load_input("case30","clean");ref=reference("case30")
    mktempdir() do dir
        p=joinpath(dir,"source.m");write(p,read(ref.path))
        @test check_source_loads(d,SourceLoadReference(p,ref.sha256)).status=="source_consistent"
        write(p,read(p,String)*"\n% changed reference bytes\n")
        @test check_source_loads(d,SourceLoadReference(p,ref.sha256)).status=="unavailable"
        # A new, explicitly selected hash records a revised reference; it is not inferred.
        newref=SourceLoadReference(p,bytes2hex(sha256(read(p))))
        @test check_source_loads(d,newref).status=="source_consistent"
    end
    @test solve_with_source_contract(build_source(d),load_input("case30","load_units"),ref).status=="model_contract_unavailable"
    rebase=load_input("case30","valid_rebase")
    flow=solve_with_source_contract(build_source(rebase),rebase,ref;rebase_to=200)
    results["rebased_workflow"]=flow
    @test flow.status=="accepted_primal_point"
end
@testset "Actual source revision and exact comparison boundaries" begin
    mktempdir() do dir
        p=joinpath(dir,"loads.m")
        text="mpc.baseMVA = 100; mpc.bus = [1 1 10 2 0 0 1 1 0 110 1 1.1 0.9;];"
        write(p,text)
        ref=SourceLoadReference(p,bytes2hex(sha256(read(p))))
        d=Dict("per_unit"=>true,"baseMVA"=>100,"bus"=>Dict("1"=>Dict()),
            "load"=>Dict("1"=>Dict{String,Any}("status"=>1,"load_bus"=>1,"pd"=>1//10,"qd"=>1//50)))
        @test check_source_loads(d,ref).status=="source_consistent"
        tau=big(1)//10^8
        d["load"]["1"]["pd"]=(10+tau)/100
        @test check_source_loads(d,ref;physical_tolerance=tau).status=="source_consistent"
        d["load"]["1"]["pd"]=(10+2*tau)/100
        @test check_source_loads(d,ref;physical_tolerance=tau).status=="source_mismatch"
        d["load"]["1"]["pd"]=1//10
        write(p,replace(text,"1 1 10 2"=>"1 1 20 2"))
        @test check_source_loads(d,ref).status=="unavailable"
        revised=SourceLoadReference(p,bytes2hex(sha256(read(p))))
        @test check_source_loads(d,revised).status=="source_mismatch"
        d["load"]["1"]["pd"]=1//5
        @test check_source_loads(d,revised).status=="source_consistent"
        d["load"]["1"]["qd"]=3//100
        @test check_source_loads(d,revised).status=="source_mismatch"
    end
end
@testset "Frozen evaluations retained" begin
    for name in ("power_repair_case9_freeze","power_repair_case14_freeze","power_workflow_validation_freeze")
        f=JSON.parsefile(joinpath(ROOT_SOURCE,"docs","$name.json"))
        @test all(bytes2hex(sha256(read(joinpath(ROOT_SOURCE,p))))==h for (p,h) in f["file_sha256"])
    end
end
out=joinpath(ROOT_SOURCE,"work","source-load-followup");mkpath(out)
open(joinpath(out,"summary.json"),"w") do io
    JSON.print(io,Dict("schema_version"=>"source-load-followup-v1","scope"=>"Post-evaluation reference-aware follow-up on exposed cases; no revised frozen score", "results"=>results,"source_sha256"=>bytes2hex(sha256(read(joinpath(ROOT_SOURCE,"benchmarks","power_repair_pilot","source_load_contract.jl"))))),2)
end
