using Test, JSON, SHA
include("frozen_artifact_integrity.jl")
using .FrozenArtifactIntegrity: frozen_files_match
include("../benchmarks/power_repair_pilot/encoded_capacity_certificate.jl")
using .EncodedCapacityCertificate
const ECC=EncodedCapacityCertificate
const Q=ECC.Q
const PM=ECC.PM
const MOI=ECC.MOI
const JuMP=ECC.JuMP
const ROOT_ENCODED=normpath(joinpath(@__DIR__,".."))
q(x)=Q(x)
@testset "Exact encoded loss bounds and expression semantics" begin
    for r in (q(0),q(1),q(2),big(1)//big(10)^100,q(big(2)^2048))
        lo,hi=ECC.sqrt_bounds(r)
        @test 0<=lo<=hi
        @test lo^2<=r<=hi^2
    end
    @test ECC.loss_bound(q(1),q(1),q(-2),q(0),q(1),q(1))==0
    @test ECC.loss_bound(q(1),q(1),q(0),q(2),q(1),q(1))==0
    @test ECC.loss_bound(q(2),q(2),q(1),q(1),q(2),q(3))==0
    eps=big(1)//big(2)^60
    # Actual negative loss at x=y=1, angle=0: exact passivity cannot be assumed.
    lb=ECC.loss_bound(q(1),q(1),-2-eps,q(0),q(1),q(1))
    @test lb<=-eps
    @test lb>-2*eps
    @test eps/2+lb<=0 # A positive data shortage alone is insufficient.
    @test 2*eps+lb>0
    @test ECC.loss_bound(q(0),q(0),q(3),q(4),q(2),q(3))==-30
    @test_throws ErrorException ECC.loss_bound(q(-1),q(1),q(0),q(0),q(1),q(1))
    x=MOI.VariableIndex(1);y=MOI.VariableIndex(2)
    diag=MOI.ScalarQuadraticFunction([MOI.ScalarQuadraticTerm(6.0,x,x)],MOI.ScalarAffineTerm{Float64}[],0.0)
    @test ECC.polynomial(diag)==ECC.Poly(("v:1","v:1")=>q(3))
    minus=MOI.ScalarNonlinearFunction(:-,Any[x,y])
    reverse=MOI.ScalarNonlinearFunction(:-,Any[y,x])
    sin1=ECC.polynomial(MOI.ScalarNonlinearFunction(:sin,Any[minus]))
    sin2=ECC.polynomial(MOI.ScalarNonlinearFunction(:sin,Any[reverse]))
    @test isempty(ECC.add(sin1,sin2))
    @test ECC.polynomial(MOI.ScalarNonlinearFunction(:cos,Any[minus]))==ECC.polynomial(MOI.ScalarNonlinearFunction(:cos,Any[reverse]))
    @test_throws ErrorException ECC.polynomial(MOI.ScalarNonlinearFunction(:sin,Any[x]))
    @test_throws ErrorException ECC.polynomial(MOI.ScalarNonlinearFunction(:/,Any[x,y]))
    @test_throws ErrorException ECC.polynomial(MOI.ScalarNonlinearFunction(:^,Any[x,0.5]))
end
build_encoded(d)=PM.instantiate_model(ECC.CMC.materialize(d),PM.ACPPowerModel,PM.build_opf)
results=Dict{String,Any}()
@testset "Backend-derived capacity follow-up on exposed networks" begin
    for name in ("case9","case14")
        data=PM.parse_file(joinpath(ROOT_ENCODED,"test","fixtures","power_repair_$name.m"))
        clean=encoded_capacity_certificate(build_encoded(data),data)
        results["$(name)_clean"]=clean
        @test clean.available
        @test clean.status=="not_ruled_out"
        for g in values(data["gen"])
            g["pmax"]=0.0;g["pmin"]=min(g["pmin"],0.0)
        end
        pm=build_encoded(data)
        shortage=encoded_capacity_certificate(pm,data)
        results["$(name)_shortage"]=shortage
        @test shortage.available
        @test shortage.status=="certified_infeasible"
        @test length(shortage.branches)==length(data["branch"])
        @test length(shortage.balances)==length(data["bus"])
        for v in JuMP.all_variables(pm.model);JuMP.set_start_value(v,0.0);end
        @test encoded_capacity_certificate(pm,data)==shortage
        # Tampering with adapter metadata must not change coordinate evidence.
        PM.var(pm)[:pg]=Dict{Int,Any}()
        @test encoded_capacity_certificate(pm,data)==shortage
        backend=JuMP.backend(pm.model)
        F=MOI.ScalarNonlinearFunction;S=MOI.EqualTo{Float64}
        row=first(MOI.get(backend,MOI.ListOfConstraintIndices{F,S}()))
        MOI.delete(backend,row)
        @test encoded_capacity_certificate(pm,data).status=="unavailable"
    end
    # Multiple loads at one bus exercise builder aggregation rounding.
    data=PM.parse_file(joinpath(ROOT_ENCODED,"test","fixtures","power_repair_case14.m"))
    for l in values(data["load"]);l["pd"]=0.0;end
    id=first(sort!(collect(keys(data["load"])))); l=data["load"][id];l["pd"]=0.1
    extra=deepcopy(l);extra["pd"]=0.2;extra["index"]=999
    data["load"]["999"]=extra
    for g in values(data["gen"]);g["pmax"]=0.0;g["pmin"]=min(g["pmin"],0.0);end
    result=encoded_capacity_certificate(build_encoded(data),data)
    results["rounded_bus_aggregation"]=result
    @test result.status=="certified_infeasible"
    @test result.demand_exact_pu==string(q(0.1+0.2))
    @test result.demand_exact_pu!=string(q(0.1)+q(0.2))
    # Exercise nonzero phase shift and off-nominal tap through actual row extraction.
    data["branch"]["1"]["shift"]=0.1
    data["branch"]["1"]["tap"]=0.97
    shifted=encoded_capacity_certificate(build_encoded(data),data)
    results["shifted_transformer"]=shifted
    @test shifted.available
    @test shifted.status=="certified_infeasible"
    br=only(filter(b->b.branch=="1",shifted.branches))
    @test br.coefficients_exact[4]!="0//1"
    @test startswith(shifted.aggregate_loss_lower_exact_pu,"-")
    # The encoded negative-loss allowance exceeds this positive source shortage.
    # A sufficient-condition checker must abstain from an infeasibility claim.
    for load in values(data["load"]);load["pd"]=0.0;end
    data["load"][id]["pd"]=1e-18
    marginal=encoded_capacity_certificate(build_encoded(data),data)
    results["marginal_inside_loss_allowance"]=marginal
    @test marginal.available
    @test marginal.status=="not_ruled_out"
    @test ECC.CMC.PowerCapacityPreflight.capacity_preflight(data;contract=:closed_acp_fixed_load).status=="capacity_shortage"
    data["storage"]=Dict("1"=>Dict())
    @test encoded_capacity_certificate(nothing,data).status=="unavailable"
end
@testset "Original frozen evaluations remain intact" begin
    for name in ("case9","case14")
        freeze_path=joinpath(ROOT_ENCODED,"docs","power_repair_$(name)_freeze.json")
        @test frozen_files_match(ROOT_ENCODED,freeze_path)
    end
end
out=joinpath(get(ENV,"NLPDIAGNOSTICS_TEST_OUTPUT_ROOT",joinpath(ROOT_ENCODED,"work")),"encoded-capacity-followup");mkpath(out)
open(joinpath(out,"summary.json"),"w") do io
    JSON.print(io,Dict("schema_version"=>"encoded-capacity-followup-v1","scope"=>"Post-evaluation development on exposed case9/case14; exact-real encoded-equation certificate, zero solver tolerance", "results"=>results,
        "source_sha256"=>Dict(p=>bytes2hex(sha256(read(joinpath(ROOT_ENCODED,p)))) for p in ("benchmarks/power_repair_pilot/encoded_capacity_certificate.jl","benchmarks/power_repair_pilot/capacity_model_contract.jl","benchmarks/power_repair_pilot/capacity_preflight.jl","test/encoded_capacity_certificate_contracts.jl"))),2)
end
