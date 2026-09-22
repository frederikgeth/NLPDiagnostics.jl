using Test, JSON, SHA
include("../benchmarks/power_repair_pilot/partial_power_diagnostics.jl")
using .PartialPowerDiagnostics
const P=PartialPowerDiagnostics
const E=P.E
const ROOT_PARTIAL=normpath(joinpath(@__DIR__,".."))
const freeze=JSON.parsefile(joinpath(ROOT_PARTIAL,"docs","integrated_report_freeze.json"))
ref(n)=P.S.SourceLoadReference(joinpath(ROOT_PARTIAL,"test","fixtures","power_report_$n.m"),freeze["file_sha256"]["test/fixtures/power_report_$n.m"])
input(n,v)=E.CMC.materialize(JSON.parsefile(joinpath(ROOT_PARTIAL,"work","frozen-integrated-report-validation",n,v,"input.json")))
build(d)=E.PM.instantiate_model(E.CMC.materialize(d),E.PM.ACPPowerModel,E.PM.build_opf)
results=Dict{String,Any}()
@testset "Independent checks retain their own failures" begin
    for variant in ("clean","reactive_units","stale_source","zero_capacity")
        d=input("case7_tplgy",variant)
        reference=variant=="stale_source" ? P.S.SourceLoadReference(joinpath(ROOT_PARTIAL,"work","frozen-integrated-report-validation","case7_tplgy",variant,"changed_source.m"),ref("case7_tplgy").sha256) : ref("case7_tplgy")
        r=diagnose_partial(build(d),d,reference)
        results[variant]=r
        @test r["status"]=="partial_results"
        @test !r["model_binding_verified"]
        @test r["stages"][1]["status"]=="unavailable"
        @test r["stages"][2]["status"]=="unavailable"
        reason=r["stages"][2]["reason"]
        @test occursin(variant=="stale_source" ? "hash" : "status changes",reason)
        @test r["stages"][4]["status"]=="not_run"
    end
end
@testset "Useful source evidence cannot imply backend acceptance" begin
    d=input("case6","reactive_units")
    # Scope probe: a DC collection blocks this model contract. Source premises
    # are unchanged; source comparison should still identify altered qd totals.
    d["dcline"]=Dict("probe"=>Dict())
    r=diagnose_partial(nothing,d,ref("case6"))
    results["source_mismatch_unsupported_model"]=r
    @test r["status"]=="partial_results"
    @test r["stages"][2]["status"]=="source_mismatch"
    @test !isempty(r["findings"])
    @test all(f->f["binding"]=="supplied_data_only",r["findings"])
    @test occursin("supplied data",markdown_partial(r))
    @test r["evidence"]["solver_invoked"]==false
    clean=input("case6","clean")
    r=diagnose_partial(nothing,clean,ref("case6"))
    @test r["status"]=="partial_results"
    @test r["stages"][2]["status"]=="source_consistent"
    @test !r["model_binding_verified"]
    accepted=diagnose_partial(build(clean),clean,ref("case6"))
    results["supported_clean"]=accepted
    @test accepted["status"]=="accepted_primal_point"
    @test accepted["model_binding_verified"]
    mismatch=input("case6","reactive_units")
    rejected=diagnose_partial(build(mismatch),mismatch,ref("case6"))
    @test rejected["status"]=="rejected_by_source_mismatch"
    @test rejected["evidence"]["solver_invoked"]==false
end
@testset "All frozen runs retained" begin
    for n in ("power_repair_case9_freeze","power_repair_case14_freeze","power_workflow_validation_freeze","integrated_report_freeze")
        f=JSON.parsefile(joinpath(ROOT_PARTIAL,"docs","$n.json"))
        @test all(bytes2hex(sha256(read(joinpath(ROOT_PARTIAL,p))))==h for (p,h) in f["file_sha256"])
    end
end
out=joinpath(ROOT_PARTIAL,"work","partial-power-diagnostics");mkpath(out)
write(joinpath(out,"summary.json"),JSON.json(Dict("schema_version"=>"partial-power-diagnostics-v1","results"=>results)))
write(joinpath(out,"report.json"),JSON.json(results["stale_source"]))
write(joinpath(out,"report.md"),markdown_partial(results["stale_source"]))
