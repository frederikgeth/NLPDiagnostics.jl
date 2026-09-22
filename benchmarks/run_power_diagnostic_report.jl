using JSON, SHA
include(joinpath(@__DIR__, "common.jl"))
using .NLPDiagnosticsBenchmarkCommon
include("power_repair_pilot/power_diagnostic_report.jl")
using .PowerDiagnosticReport
const R=PowerDiagnosticReport
length(ARGS) in (4,5) || error("Usage: input.json source.m expected_source_sha256 output_directory [declared_rebase_to]")
input,source,expected_hash,output=ARGS[1:4]
!isdir(output) || isempty(readdir(output)) || error("refusing to overwrite a nonempty report directory")
data=R.S.E.CMC.materialize(JSON.parsefile(input))
reference=R.S.SourceLoadReference(abspath(source),expected_hash)
rebase=length(ARGS)==5 ? parse(Float64,ARGS[5]) : nothing
report=try
    pm=R.S.E.PM.instantiate_model(data,R.S.E.PM.ACPPowerModel,R.S.E.PM.build_opf)
    diagnose_power_model(pm,data,reference;rebase_to=rebase)
catch e
    e isa InterruptException && rethrow()
    summarize_workflow((available=false,status="model_build_unavailable",reason=sprint(showerror,e)))
end
report["input_sha256"]=bytes2hex(sha256(read(input)))
report["reporter_sha256"]=bytes2hex(sha256(read(joinpath(@__DIR__,"power_repair_pilot","power_diagnostic_report.jl"))))
write_json(joinpath(output,"report.json"),report)
write(joinpath(output,"report.md"),markdown_report(report))
println(report["headline"]," — ",abspath(joinpath(output,"report.md")))
