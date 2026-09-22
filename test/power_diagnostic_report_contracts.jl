using Test, JSON, SHA
include("../benchmarks/power_repair_pilot/power_diagnostic_report.jl")
using .PowerDiagnosticReport
const R=PowerDiagnosticReport
const ROOT_REPORT=normpath(joinpath(@__DIR__,".."))
source=JSON.parsefile(joinpath(ROOT_REPORT,"work","source-load-followup","summary.json"))["results"]
@testset "Report preserves scientific distinctions" begin
    accepted=summarize_workflow(source["rebased_workflow"])
    @test accepted["status"]=="accepted_primal_point"
    @test accepted["checked_rows"]>0
    @test accepted["stages"][1]["status"]=="source_consistent"
    @test accepted["stages"][2]["status"]=="not_ruled_out"
    @test accepted["stages"][4]["status"]=="satisfied"
    mismatch=summarize_workflow(source["case30/rejected_workflow"])
    @test mismatch["status"]=="rejected_by_source_mismatch"
    @test !isempty(mismatch["findings"])
    @test all(f->f["kind"]=="source_mismatch",mismatch["findings"])
    @test mismatch["stages"][2]["status"]=="not_run"
    @test mismatch["stages"][3]["status"]=="not_run"
    @test summarize_workflow((status="accepted_primal_point",))["status"]=="invalid_evidence"
    missing=summarize_workflow((status="source_contract_unavailable",lineage=(status="unavailable",reason="changed source bytes")))
    @test missing["reason"]=="changed source bytes"
    @test missing["stages"][1]["status"]=="unavailable"
    @test missing["stages"][2]["status"]=="not_run"
    @test occursin("report.json",markdown_report(mismatch))
    @test occursin("not exact feasibility",markdown_report(accepted))
    @test occursin("difference",markdown_report(mismatch))
    broken=deepcopy(source["rebased_workflow"]);broken["workflow"]["solve"]["verification"]["available"]=false
    @test summarize_workflow(broken)["status"]=="invalid_evidence"
end
@testset "End-to-end island report" begin
    d=R.S.E.CMC.materialize(JSON.parsefile(joinpath(ROOT_REPORT,"work","frozen-power-workflow-validation","case30","isolated_load","input.json")))
    path=joinpath(ROOT_REPORT,"test","fixtures","power_repair_case30.m")
    freeze=JSON.parsefile(joinpath(ROOT_REPORT,"docs","power_workflow_validation_freeze.json"))
    ref=R.S.SourceLoadReference(path,freeze["file_sha256"]["test/fixtures/power_repair_case30.m"])
    pm=R.S.E.PM.instantiate_model(d,R.S.E.PM.ACPPowerModel,R.S.E.PM.build_opf)
    report=diagnose_power_model(pm,d,ref)
    @test report["status"]=="rejected_by_island_certificate"
    @test report["stages"][1]["status"]=="source_consistent"
    @test report["stages"][3]["status"]=="not_run"
    @test any(f->f["kind"]=="certified_contradiction" && f["buses"]==[3],report["findings"])
    out=joinpath(ROOT_REPORT,"work","power-diagnostic-report");mkpath(out)
    write(joinpath(out,"report.json"),JSON.json(report))
    write(joinpath(out,"report.md"),markdown_report(report))
end
@testset "Frozen evaluations unchanged" begin
    for name in ("power_repair_case9_freeze","power_repair_case14_freeze","power_workflow_validation_freeze")
        freeze=JSON.parsefile(joinpath(ROOT_REPORT,"docs","$name.json"))
        @test all(bytes2hex(sha256(read(joinpath(ROOT_REPORT,p))))==h for (p,h) in freeze["file_sha256"])
    end
end
