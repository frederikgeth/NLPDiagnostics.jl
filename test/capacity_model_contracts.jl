using Test, JSON, SHA
include("../benchmarks/power_repair_pilot/capacity_model_contract.jl")
using .CapacityModelContract
const CMC=CapacityModelContract
const ROOT_CONTRACT=normpath(joinpath(@__DIR__,".."))
# Exposed case14 follow-up; the old frozen evaluation is not rerun or altered.
data=JSON.parsefile(joinpath(ROOT_CONTRACT,"work","power-repair-case14-capacity","shortage_bounded_start","modified_data.json"))
build_contract(d)=CMC.PM.instantiate_model(CMC.materialize(d),CMC.PM.ACPPowerModel,CMC.PM.build_opf)
results=Dict{String,Any}()
@testset "Capacity evidence requires matching backend rows" begin
    pm=build_contract(data)
    results["matched_shortage"]=checked_capacity_preflight(pm,data)
    @test results["matched_shortage"].available
    @test results["matched_shortage"].status=="capacity_shortage"
    @test results["matched_shortage"].matched_row_count>0
    # Merely presenting matching pm.data is insufficient after deleting a row.
    backend=CMC.JuMP.backend(pm.model)
    F=CMC.MOI.ScalarAffineFunction{Float64};S=CMC.MOI.EqualTo{Float64}
    rows=CMC.MOI.get(backend,CMC.MOI.ListOfConstraintIndices{F,S}())
    @test !isempty(rows)
    CMC.MOI.delete(backend,first(rows))
    results["deleted_equation"]=checked_capacity_preflight(pm,data)
    @test !results["deleted_equation"].available
    @test results["deleted_equation"].status=="unavailable"
    pm=build_contract(data);backend=CMC.JuMP.backend(pm.model)
    row=first(CMC.MOI.get(backend,CMC.MOI.ListOfConstraintIndices{F,S}()))
    term=first(CMC.MOI.get(backend,CMC.MOI.ConstraintFunction(),row).terms)
    CMC.MOI.modify(backend,row,CMC.MOI.ScalarCoefficientChange(term.variable,term.coefficient+0.5))
    results["changed_coefficient"]=checked_capacity_preflight(pm,data)
    @test !results["changed_coefficient"].available
    @test results["changed_coefficient"].actual_row_count==results["changed_coefficient"].expected_row_count
    pm=build_contract(data)
    CMC.MOI.set(CMC.JuMP.backend(pm.model),CMC.MOI.UserDefinedFunction(:opaque_test,1),(x->x,))
    @test !checked_capacity_preflight(pm,data).available
    pm=build_contract(data)
    gen=first(sort!(collect(keys(data["gen"]));by=x->parse(Int,x)))
    v=CMC.PM.var(pm,:pg,parse(Int,gen))
    CMC.JuMP.set_upper_bound(v,1.0)
    results["changed_capacity_bound"]=checked_capacity_preflight(pm,data)
    @test !results["changed_capacity_bound"].available
    pm=build_contract(data)
    renamed=first(CMC.JuMP.all_variables(pm.model))
    CMC.JuMP.set_name(renamed,"")
    @test !checked_capacity_preflight(pm,data).available
    pm=build_contract(data)
    vars=CMC.JuMP.all_variables(pm.model)
    CMC.JuMP.set_name(vars[2],CMC.JuMP.name(vars[1]))
    @test !checked_capacity_preflight(pm,data).available
    # Starts cannot change model-level capacity infeasibility.
    pm=build_contract(data)
    for v in CMC.JuMP.all_variables(pm.model);CMC.JuMP.set_start_value(v,0.5);end
    @test checked_capacity_preflight(pm,data).status=="capacity_shortage"
    clean=JSON.parsefile(joinpath(ROOT_CONTRACT,"work","power-repair-case14-capacity","original_data.json"))
    results["matched_clean"]=checked_capacity_preflight(build_contract(clean),clean)
    @test results["matched_clean"].status=="not_ruled_out"
    @test !checked_capacity_preflight(build_contract(clean),data).available
    @test !checked_capacity_preflight(nothing,data).available
    @test_throws ErrorException CMC.function_key(CMC.MOI.ScalarNonlinearFunction(:unknown_operator,Any[1.0]),Dict())
    @test_throws ErrorException CMC.set_key(CMC.MOI.Integer())
    @test_throws ErrorException CMC.materialize(Dict("pmax"=>big(1)//3))
    @test_throws ErrorException CMC.materialize(Dict("pmax"=>big(2)^60+1))
end
out=joinpath(ROOT_CONTRACT,"work","capacity-model-contract-followup")
mkpath(out)
open(joinpath(out,"summary.json"),"w") do io
    JSON.print(io,Dict("schema_version"=>"capacity-model-contract-followup-v1",
        "scope"=>"post-evaluation standard ACP backend matching on exposed case14",
        "results"=>results,"source_sha256"=>bytes2hex(sha256(read(joinpath(@__DIR__,"..","benchmarks","power_repair_pilot","capacity_model_contract.jl"))))),2)
end
