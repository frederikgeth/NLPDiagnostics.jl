using Test, JSON, SHA
include("../benchmarks/power_repair_pilot/island_capacity_certificate.jl")
using .IslandCapacityCertificate
const I=IslandCapacityCertificate
const E=I.E
const ROOT_ISLAND=normpath(joinpath(@__DIR__,".."))
build_island(d)=E.PM.instantiate_model(E.CMC.materialize(d),E.PM.ACPPowerModel,E.PM.build_opf)
results=Dict{String,Any}()
@testset "Constant contradictions and exact subset discipline" begin
    m=E.JuMP.Model()
    E.JuMP.@constraint(m,0.0==1.0)
    @test length(I.constant_contradiction(m,E.Q(0)))==1
    @test isempty(I.constant_contradiction(m,E.Q(1)))
    @test length(I.constant_contradiction(m,big(999)//1000))==1
    @test I.signature_subset((variables=["x"],rows=["a"]),(variables=["x","y"],rows=["a","b"]))
    @test !I.signature_subset((variables=["x"],rows=["a","a"]),(variables=["x"],rows=["a"]))
    @test !I.signature_subset((variables=["z"],rows=["a"]),(variables=["x"],rows=["a"]))
    @test !I.signature_subset((variables=["x"],rows=["different"]),(variables=["x"],rows=["a"]))
    @test island_capacity_certificate(nothing,nothing;absolute_tolerance=-1).status=="unavailable"
end
@testset "Follow-up on exposed isolated-load failures and controls" begin
    for network in ("case24","case30")
        base=joinpath(ROOT_ISLAND,"work","frozen-power-workflow-validation",network)
        for variant in ("isolated_load","clean","valid_rebase","marginal_shortage")
            d=E.CMC.materialize(JSON.parsefile(joinpath(base,variant,"input.json")))
            pm=build_island(d)
            r=island_capacity_certificate(pm,d)
            results["$network/$variant"]=r
            @test r.available
            @test r.status==(variant=="isolated_load" ? "certified_infeasible_within_tolerances" : "not_ruled_out")
            if variant=="isolated_load"
                @test length(r.islands)==2
                @test any(x->x.buses==[3] && x.result.basis=="constant_encoded_equalities" && !isempty(x.result.witnesses),r.islands)
                flow=solve_with_island_preflight(pm,d)
                @test flow.status=="rejected_by_island_certificate"
                @test !flow.solver_invoked
                # Input identity alone cannot justify a changed backend.
                rows=E.MOI.get(E.JuMP.backend(pm.model),E.MOI.ListOfConstraintIndices{E.MOI.ScalarAffineFunction{Float64},E.MOI.EqualTo{Float64}}())
                E.MOI.delete(E.JuMP.backend(pm.model),first(rows))
                @test island_capacity_certificate(pm,d).status=="unavailable"
            end
        end
    end
end
@testset "Connected two-bus deficit island with ample global capacity" begin
    # Exposed case30 derivative: keep branch 1 (1--2), disconnect its island
    # from the rest, and remove its active generation capacity. No constant
    # active balance at either bus: the proof must aggregate the two buses.
    d=E.CMC.materialize(JSON.parsefile(joinpath(ROOT_ISLAND,"work","frozen-power-workflow-validation","case30","clean","input.json")))
    pair=Set([Int(d["branch"]["1"]["f_bus"]),Int(d["branch"]["1"]["t_bus"])])
    for br in values(d["branch"])
        (Int(br["f_bus"]) in pair)!=(Int(br["t_bus"]) in pair) && (br["br_status"]=0)
    end
    for g in values(d["gen"])
        if Int(g["gen_bus"]) in pair;g["pmax"]=0.0;g["pmin"]=min(g["pmin"],0.0)
        else;g["pmax"]+=100.0;end
    end
    @test E.CMC.PowerCapacityPreflight.capacity_preflight(d;contract=:closed_acp_fixed_load).status=="not_ruled_out"
    r=island_capacity_certificate(build_island(d),d)
    results["two_bus_deficit"]=r
    @test r.available
    @test r.status=="certified_infeasible_within_tolerances"
    island=only(filter(x->Set(x.buses)==pair,r.islands))
    @test island.result.basis=="island_encoded_capacity"
    @test island.result.status=="certified_infeasible_within_tolerances"
    dclean=E.CMC.materialize(JSON.parsefile(joinpath(ROOT_ISLAND,"work","frozen-power-workflow-validation","case30","clean","input.json")))
    flow=solve_with_island_preflight(build_island(dclean),dclean)
    results["clean_workflow"]=flow
    @test flow.status=="accepted_primal_point"
    @test flow.solver_workflow_invoked
end
@testset "All original freezes retained" begin
    for name in ("power_repair_case9_freeze","power_repair_case14_freeze","power_workflow_validation_freeze")
        f=JSON.parsefile(joinpath(ROOT_ISLAND,"docs","$name.json"))
        @test all(bytes2hex(sha256(read(joinpath(ROOT_ISLAND,p))))==h for (p,h) in f["file_sha256"])
    end
end
out=joinpath(ROOT_ISLAND,"work","island-capacity-followup");mkpath(out)
open(joinpath(out,"summary.json"),"w") do io
    JSON.print(io,Dict("schema_version"=>"island-capacity-followup-v1","scope"=>"Post-evaluation on exposed data; original failed evaluation unchanged", "results"=>results,
        "source_sha256"=>bytes2hex(sha256(read(joinpath(ROOT_ISLAND,"benchmarks","power_repair_pilot","island_capacity_certificate.jl"))))),2)
end
