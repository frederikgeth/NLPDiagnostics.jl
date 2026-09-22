using Test, JSON, SHA
include("frozen_artifact_integrity.jl")
using .FrozenArtifactIntegrity: frozen_files_match
include("../benchmarks/power_repair_pilot/tolerant_capacity_certificate.jl")
using .TolerantCapacityCertificate
const TCC=TolerantCapacityCertificate
const E=TCC.ECC
const ROOT_TOL=normpath(joinpath(@__DIR__,".."))
q=TCC.rational_string
build_tol(d)=E.PM.instantiate_model(E.CMC.materialize(d),E.PM.ACPPowerModel,E.PM.build_opf)
check_tol(pm,d;e=0,g=0,v=0)=tolerant_capacity_certificate(pm,d;contract=:absolute_unscaled,equality_tolerance=e,generator_bound_tolerance=g,voltage_bound_tolerance=v)
results=Dict{String,Any}()
@testset "Explicit tolerance contract" begin
    @test tolerant_capacity_certificate(nothing,nothing).status=="unavailable"
    for bad in (nothing,-1,Inf,NaN,true,"1e-6")
        @test check_tol(nothing,nothing;e=bad).status=="unavailable"
        @test check_tol(nothing,nothing;g=bad).status=="unavailable"
        @test check_tol(nothing,nothing;v=bad).status=="unavailable"
    end
end
@testset "Exact boundary and tolerance budgets on exposed case9" begin
    data=E.PM.parse_file(joinpath(ROOT_TOL,"test","fixtures","power_repair_case9.m"))
    @test check_tol(build_tol(data),data;e=1e-6,g=1e-6,v=1e-6).status=="not_ruled_out"
    for g in values(data["gen"]);g["pmax"]=0.0;g["pmin"]=min(g["pmin"],0.0);end
    pm=build_tol(data)
    zero_result=check_tol(pm,data)
    results["zero_tolerance"]=zero_result
    @test zero_result.status=="certified_infeasible_within_tolerances"
    @test zero_result.contradiction_margin_exact_pu==zero_result.encoded_evidence.contradiction_margin_exact_pu
    N=sum(abs(t.weight) for t in zero_result.equality_weights)
    @test N==9+2*9
    gap=q(zero_result.contradiction_margin_exact_pu)
    eq_boundary=check_tol(pm,data;e=gap/N)
    results["equality_boundary"]=eq_boundary
    @test eq_boundary.status=="not_ruled_out"
    @test q(eq_boundary.contradiction_margin_exact_pu)==0
    @test check_tol(pm,data;e=gap/N-gap/(100*N)).status=="certified_infeasible_within_tolerances"
    @test check_tol(pm,data;e=gap/N+gap/(100*N)).status=="not_ruled_out"
    ng=length(zero_result.encoded_evidence.generator_bounds)
    gen_boundary=check_tol(pm,data;g=gap/ng)
    results["generator_boundary"]=gen_boundary
    @test q(gen_boundary.contradiction_margin_exact_pu)==0
    @test gen_boundary.status=="not_ruled_out"
    joint=check_tol(pm,data;e=gap/(2*N),g=gap/(2*ng))
    results["joint_boundary"]=joint
    @test q(joint.contradiction_margin_exact_pu)==0
    @test joint.status=="not_ruled_out"
    small=check_tol(pm,data;e=1e-6,g=1e-6,v=1e-6)
    results["small_tolerances"]=small
    @test small.status=="certified_infeasible_within_tolerances"
    @test q(small.equality_budget_exact_pu)==N*E.Q(1e-6)
    @test q(small.relaxed_capacity_exact_pu)==ng*E.Q(1e-6)
end
@testset "Relaxed voltage domains change the rounded loss allowance" begin
    d=E.PM.parse_file(joinpath(ROOT_TOL,"test","fixtures","power_repair_case14.m"))
    for g in values(d["gen"]);g["pmax"]=0.0;g["pmin"]=min(g["pmin"],0.0);end
    d["branch"]["1"]["shift"]=0.1;d["branch"]["1"]["tap"]=0.97
    pm=build_tol(d)
    a=check_tol(pm,d);b=check_tol(pm,d;v=2)
    results["relaxed_voltage_crosses_zero"]=b
    @test a.available && b.available
    @test q(b.relaxed_loss_lower_exact_pu)<q(a.relaxed_loss_lower_exact_pu)<0
    @test q(b.contradiction_margin_exact_pu)<q(a.contradiction_margin_exact_pu)
    # Signed voltages: an exact rational unit-circle point checks the extension.
    A=B=E.Q(1);C=E.Q(3);D=E.Q(4)
    lower=E.loss_bound(A,B,C,D,E.Q(3),E.Q(2))
    for (x,y) in ((-3,2),(3,-2),(-3,-2))
        actual=A*x^2+B*y^2+C*x*y*(3//5)+D*x*y*(4//5)
        @test actual>=lower
    end
end
@testset "Frozen evaluations unchanged" begin
    for name in ("case9","case14")
        freeze_path=joinpath(ROOT_TOL,"docs","power_repair_$(name)_freeze.json")
        @test frozen_files_match(ROOT_TOL,freeze_path)
    end
end
out=joinpath(get(ENV,"NLPDIAGNOSTICS_TEST_OUTPUT_ROOT",joinpath(ROOT_TOL,"work")),"tolerant-capacity-followup");mkpath(out)
open(joinpath(out,"summary.json"),"w") do io
    paths=("benchmarks/power_repair_pilot/tolerant_capacity_certificate.jl","benchmarks/power_repair_pilot/encoded_capacity_certificate.jl","test/tolerant_capacity_certificate_contracts.jl")
    JSON.print(io,Dict("schema_version"=>"tolerant-capacity-followup-v1","scope"=>"Exposed development networks; caller-declared absolute unscaled true-residual tolerances, not solver-settings certification", "results"=>results,"source_sha256"=>Dict(p=>bytes2hex(sha256(read(joinpath(ROOT_TOL,p)))) for p in paths)),2)
end
