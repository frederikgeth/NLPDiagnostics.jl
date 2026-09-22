module PowerDiagnosticsCLIContracts
using Test
include("../benchmarks/run_power_diagnostics_v2.jl")

@testset "Version 2 CLI writes rejected-input evidence without overwriting" begin
    fixtures = joinpath(@__DIR__, "fixtures", "status_provenance")
    data = P.E.PM.parse_file(joinpath(fixtures, "source.m"))
    data["load"] = P.E.CMC.materialize(JSON.parsefile(joinpath(fixtures, "model_load_blueprint.json")))
    manifest = JSON.parsefile(joinpath(fixtures, "source_manifest.json"))
    contract = JSON.parsefile(joinpath(fixtures, "reference_contract.json"))
    contract["source_revision"] = "stale-revision"
    mktempdir() do directory
        input = joinpath(directory, "input.json")
        contract_path = joinpath(directory, "contract.json")
        output = joinpath(directory, "report")
        write_json(input, data)
        write_json(contract_path, contract)
        args = [input, joinpath(fixtures, "source.m"), manifest["source_sha256"], output,
            contract_path, joinpath(fixtures, "source_manifest.json")]
        report = main(args)
        @test report["status"] == "source_contract_unavailable"
        saved = JSON.parsefile(joinpath(output, "report.json"))
        @test saved["schema_version"] == "power-diagnostic-report-v2"
        @test saved["evidence"]["solver_invoked"] === false
        @test saved["input_sha256"] == bytes2hex(sha256(read(input)))
        @test saved["contract_sha256"] == bytes2hex(sha256(read(contract_path)))
        @test occursin("selected manifest", read(joinpath(output, "report.md"), String))
        @test_throws ErrorException main(args)
        @test JSON.parsefile(joinpath(output, "report.json")) == saved
    end
end
end
