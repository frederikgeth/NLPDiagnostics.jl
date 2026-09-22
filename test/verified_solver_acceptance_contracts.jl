using Test, JSON, SHA
include("../benchmarks/power_repair_pilot/verified_solver_acceptance.jl")
using .VerifiedSolverAcceptance
const V=VerifiedSolverAcceptance
const E=V.E
const MOI=E.MOI
const ROOT_GATE=normpath(joinpath(@__DIR__,".."))
@testset "Rational evaluation and boundary classification" begin
    @test V.trig_enclosure("sin",E.Q(0))==(0,0)
    @test V.trig_enclosure("cos",E.Q(0))==(1,1)
    # Independent rational bounds from the alternating series at x=1.
    sl,sh=V.trig_enclosure("sin",E.Q(1))
    cl,ch=V.trig_enclosure("cos",E.Q(1))
    @test 5//6<sl<=sh<101//120
    @test 1//2<cl<=ch<13//24
    @test V.trig_enclosure("sin",E.Q(-1))==(-sh,-sl)
    @test V.trig_enclosure("cos",E.Q(-1))==(cl,ch)
    @test_throws ErrorException V.trig_enclosure("sin",E.Q(17))
    @test V.classify((E.Q(1),E.Q(1)),MOI.EqualTo(0.0),E.Q(1))=="satisfied"
    @test V.classify((E.Q(1),E.Q(2)),MOI.EqualTo(0.0),E.Q(1))=="inconclusive"
    @test V.classify((E.Q(2),E.Q(3)),MOI.EqualTo(0.0),E.Q(1))=="violated"
    @test V.classify((E.Q(-2),E.Q(-1)),MOI.GreaterThan(0.0),E.Q(0))=="violated"
    @test V.classify((E.Q(0),E.Q(1)),MOI.Interval(0.0,1.0),E.Q(0))=="satisfied"
    x=MOI.VariableIndex(1)
    f=MOI.ScalarNonlinearFunction(:+,Any[1e16,x,-1e16])
    @test (1e16+1.0)-1e16==0.0
    @test V.evaluate(E.polynomial(f),Dict(x=>E.Q(1)))==(1,1)
end
results=Dict{String,Any}()
@testset "Pinned solver acceptance uses original-row verification" begin
    d=E.PM.parse_file(joinpath(ROOT_GATE,"test","fixtures","power_repair_case9.m"))
    build(d)=E.PM.instantiate_model(E.CMC.materialize(d),E.PM.ACPPowerModel,E.PM.build_opf)
    pm=build(d)
    clean=solve_and_verify(pm,d)
    results["clean"]=clean
    @test clean.available
    @test clean.status=="accepted_primal_point"
    @test clean.verification.status=="satisfied"
    # Row count comes from the point gate; the encoded evidence contains only selected rows.
    @test clean.verification.checked_rows>length(clean.certificate.equality_weights)
    @test clean.verification.checked_rows==length(E.CMC.model_signature(pm.model).rows)
    point=Dict(E.JuMP.index(v)=>E.JuMP.value(v) for v in E.JuMP.all_variables(pm.model))
    pg=E.JuMP.index(E.PM.var(pm,:pg,first(keys(E.PM.ref(pm,:gen)))))
    bad=copy(point);bad[pg]+=100
    @test verify_primal_point(pm,d,bad;absolute_tolerance=1e-6).status=="violated"
    bad=copy(point);bad[pg]=NaN
    @test verify_primal_point(pm,d,bad;absolute_tolerance=1e-6).status=="unavailable"
    bad=copy(point);delete!(bad,pg)
    @test verify_primal_point(pm,d,bad;absolute_tolerance=1e-6).status=="unavailable"
    @test verify_primal_point(pm,d,point;absolute_tolerance=-1).status=="unavailable"
    bad=copy(point)
    angle=E.JuMP.index(E.PM.var(pm,:va,first(keys(E.PM.ref(pm,:bus)))))
    bad[angle]=50.0
    @test verify_primal_point(pm,d,bad;absolute_tolerance=1e-6).status=="unavailable"
    backend=E.JuMP.backend(pm.model)
    row=first(MOI.get(backend,MOI.ListOfConstraintIndices{MOI.ScalarNonlinearFunction,MOI.EqualTo{Float64}}()))
    MOI.delete(backend,row)
    @test verify_primal_point(pm,d,point;absolute_tolerance=1e-6).status=="unavailable"
    for g in values(d["gen"]);g["pmax"]=0.0;g["pmin"]=min(g["pmin"],0.0);end
    shortage=solve_and_verify(build(d),d)
    results["shortage"]=shortage
    @test shortage.available
    @test shortage.status=="primal_violated"
    @test shortage.certificate.status=="certified_infeasible_within_tolerances"
    @test shortage.verification.status=="violated"
end
@testset "Original evaluation freezes" begin
    for name in ("case9","case14")
        f=JSON.parsefile(joinpath(ROOT_GATE,"docs","power_repair_$(name)_freeze.json"))
        @test all(bytes2hex(sha256(read(joinpath(ROOT_GATE,p))))==h for (p,h) in f["file_sha256"])
    end
end
out=joinpath(get(ENV,"NLPDIAGNOSTICS_TEST_OUTPUT_ROOT",joinpath(ROOT_GATE,"work")),"verified-solver-acceptance");mkpath(out)
open(joinpath(out,"summary.json"),"w") do io
    paths=("benchmarks/power_repair_pilot/verified_solver_acceptance.jl","benchmarks/power_repair_pilot/tolerant_capacity_certificate.jl","benchmarks/power_repair_pilot/encoded_capacity_certificate.jl","test/verified_solver_acceptance_contracts.jl")
    JSON.print(io,Dict("schema_version"=>"verified-solver-acceptance-v1","scope"=>"Post-evaluation case9; independent acceptance gate on returned primal point", "results"=>results,"source_sha256"=>Dict(p=>bytes2hex(sha256(read(joinpath(ROOT_GATE,p)))) for p in paths)),2)
end
