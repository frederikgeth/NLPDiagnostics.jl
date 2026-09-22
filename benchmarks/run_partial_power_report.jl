using JSON, SHA
include(joinpath(@__DIR__, "common.jl"))
using .NLPDiagnosticsBenchmarkCommon
include("power_diagnostics_v2.jl")
using .PowerDiagnosticsV2
const P=PowerDiagnosticsV2
length(ARGS) in (4,5) || error("Usage: input.json source.m expected_source_sha256 output_directory [declared_rebase_to]")
input,source,expected_hash,output=ARGS[1:4]
!isdir(output) || isempty(readdir(output)) || error("refusing to overwrite a nonempty report directory")
data=JSON.parsefile(input)
reference=P.S.SourceLoadReference(abspath(source),expected_hash)
rebase=length(ARGS)==5 ? parse(Float64,ARGS[5]) : nothing
build_error=nothing
pm=try
    P.E.PM.instantiate_model(P.E.CMC.materialize(data),P.E.PM.ACPPowerModel,P.E.PM.build_opf)
catch e
    e isa InterruptException && rethrow()
    global build_error=sprint(showerror,e)
    nothing
end
report=diagnose_partial(pm,data,reference;rebase_to=rebase)
report["build_error"]=build_error
report["input_sha256"]=bytes2hex(sha256(read(input)))
write_json(joinpath(output,"report.json"),report)
write(joinpath(output,"report.md"),markdown_report(report))
println(report["headline"]," — ",abspath(joinpath(output,"report.md")))
