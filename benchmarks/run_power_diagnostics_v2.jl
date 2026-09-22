using JSON, SHA
include("common.jl")
using .NLPDiagnosticsBenchmarkCommon
include("power_diagnostics_v2.jl")
using .PowerDiagnosticsV2
const P = PowerDiagnosticsV2

function main(args)
    length(args) in (4, 6, 7) || error(
        "Usage: input.json source.m expected_source_sha256 output_directory [contract.json revision_manifest.json [declared_rebase_to]]",
    )
    input, source, expected_hash, output = args[1:4]
    !isdir(output) || isempty(readdir(output)) || error("refusing to overwrite a nonempty report directory")
    data = P.E.CMC.materialize(JSON.parsefile(input))
    reference = SourceLoadReference(abspath(source), expected_hash)
    contract = length(args) >= 6 ? JSON.parsefile(args[5]) : nothing
    revision = length(args) >= 6 ? SourceRevision(JSON.parsefile(args[6])) : nothing
    rebase = length(args) == 7 ? parse(Float64, args[7]) : nothing
    build_error = nothing
    pm = try
        P.E.PM.instantiate_model(data, P.E.PM.ACPPowerModel, P.E.PM.build_opf)
    catch exception
        exception isa InterruptException && rethrow()
        build_error = sprint(showerror, exception)
        nothing
    end
    report = diagnose_power_model(pm, data, reference;
        load_contract=contract, revision, rebase_to=rebase)
    report["build_error"] = build_error
    report["input_sha256"] = bytes2hex(sha256(read(input)))
    report["contract_sha256"] = length(args) >= 6 ? bytes2hex(sha256(read(args[5]))) : nothing
    report["revision_manifest_sha256"] = length(args) >= 6 ? bytes2hex(sha256(read(args[6]))) : nothing
    write_json(joinpath(output, "report.json"), report)
    write(joinpath(output, "report.md"), markdown_report(report))
    println(report["headline"], " — ", abspath(joinpath(output, "report.md")))
    return report
end

abspath(PROGRAM_FILE) == abspath(@__FILE__) && main(ARGS)
