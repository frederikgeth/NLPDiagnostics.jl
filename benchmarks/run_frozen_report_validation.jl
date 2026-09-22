using JSON, SHA, Test
include(joinpath(@__DIR__, "common.jl"))
using .NLPDiagnosticsBenchmarkCommon
const ROOT_REPORT_VALIDATION=repo_root()
const PLAN_FILE=joinpath(ROOT_REPORT_VALIDATION,"docs","integrated_report_freeze.json")
const PLAN=JSON.parsefile(PLAN_FILE)
const PLAN_HASH=bytes2hex(sha256(read(PLAN_FILE)))
function guard()
    bytes2hex(sha256(read(PLAN_FILE)))==PLAN_HASH || error("plan changed")
    for (p,h) in PLAN["file_sha256"]
        bytes2hex(sha256(read(joinpath(ROOT_REPORT_VALIDATION,p))))==h || error("frozen file changed: $p")
    end
end
guard()
include("power_repair_pilot/power_diagnostic_report.jl")
using .PowerDiagnosticReport
const R=PowerDiagnosticReport
const E=R.S.E
const OUT=joinpath(ROOT_REPORT_VALIDATION,"work","frozen-integrated-report-validation")
!isdir(OUT) || isempty(readdir(OUT)) || error("refusing to overwrite existing evaluation")
mkpath(OUT)
criteria=Dict{String,Bool}();records=Dict{String,Any}()
for name in PLAN["networks"]
    path=joinpath(ROOT_REPORT_VALIDATION,"test","fixtures","power_report_$name.m")
    expected_hash=PLAN["file_sha256"]["test/fixtures/power_report_$name.m"]
    parsed=try E.PM.parse_file(path) catch e; e isa InterruptException && rethrow();(error=sprint(showerror,e),) end
    for variant in ("clean","reactive_units","stale_source","zero_capacity")
        guard();dir=joinpath(OUT,name,variant);mkpath(dir)
        report=nothing;input_hash=nothing
        try
            parsed isa AbstractDict || error(parsed.error)
            data=deepcopy(parsed)
            if variant=="reactive_units"
                for l in values(data["load"]);l["qd"]/=data["baseMVA"];end
            elseif variant=="zero_capacity"
                for g in values(data["gen"])
                    g["gen_status"]==1 || continue
                    g["pmax"]=0.0;g["pmin"]=min(g["pmin"],0.0)
                end
            end
            source_path=path
            if variant=="stale_source"
                source_path=joinpath(dir,"changed_source.m")
                write(source_path,read(path,String)*"\n% stale-reference probe\n")
            end
            write_json(joinpath(dir,"input.json"),data)
            input_hash=bytes2hex(sha256(read(joinpath(dir,"input.json"))))
            ref=R.S.SourceLoadReference(source_path,expected_hash)
            pm=E.PM.instantiate_model(data,E.PM.ACPPowerModel,E.PM.build_opf)
            report=diagnose_power_model(pm,data,ref)
        catch e
            e isa InterruptException && rethrow()
            report=summarize_workflow((available=false,status="model_build_unavailable",reason=sprint(showerror,e)))
        end
        report["input_sha256"]=input_hash
        write_json(joinpath(dir,"report.json"),report)
        write(joinpath(dir,"report.md"),markdown_report(report))
        records["$name/$variant"]=report
        criteria["$name/$variant"]=variant=="clean" ? report["status"]=="accepted_primal_point" :
            variant=="reactive_units" ? report["status"]=="rejected_by_source_mismatch" && any(f->f["kind"]=="source_mismatch" && f["field"]=="qd",report["findings"]) :
            variant=="stale_source" ? report["status"]=="source_contract_unavailable" && occursin("hash",something(report["reason"],"")) :
            report["status"]=="rejected_by_island_certificate"
        guard();println(name,"/",variant," => ",report["status"]);flush(stdout)
    end
end
write_json(joinpath(OUT,"evaluation.json"),Dict("schema_version"=>"integrated-report-validation-v1",
    "plan_sha256"=>PLAN_HASH,"criteria"=>criteria,"passed"=>count(values(criteria)),"total"=>length(criteria),
    "criteria_met"=>all(values(criteria)),"human_study_performed"=>false))
@testset "Evaluation integrity is separate from capability acceptance" begin
    @test length(records)==8
    @test Set(keys(criteria))==Set(PLAN["criteria_ids"])
    @test all(!isnothing(r["input_sha256"]) for r in values(records))
    @test all(haskey(r,"evidence") for r in values(records))
    guard();@test true
end
println("Criteria met: ",count(values(criteria)),"/",length(criteria))
