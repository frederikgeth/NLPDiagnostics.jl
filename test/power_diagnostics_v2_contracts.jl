module PowerDiagnosticsV2Contracts
using Test, JSON, SHA
include("../benchmarks/power_diagnostics_v2.jl")
using .PowerDiagnosticsV2
const P = PowerDiagnosticsV2
const E = P.E
const FIX = joinpath(@__DIR__, "fixtures", "status_provenance")
const ROOT = normpath(joinpath(@__DIR__, ".."))
const MANIFEST = JSON.parsefile(joinpath(FIX, "source_manifest.json"))
const REFERENCE = SourceLoadReference(joinpath(FIX, "source.m"), MANIFEST["source_sha256"])
const REVISION = SourceRevision(MANIFEST)

function fixture()
    data = E.PM.parse_file(joinpath(FIX, "source.m"))
    data["load"] = E.CMC.materialize(JSON.parsefile(joinpath(FIX, "model_load_blueprint.json")))
    contract = E.CMC.materialize(JSON.parsefile(joinpath(FIX, "reference_contract.json")))
    return data, contract
end
build(data) = E.PM.instantiate_model(data, E.PM.ACPPowerModel, E.PM.build_opf)
event(before, after, id) = Dict("load_id"=>"1", "from"=>before, "to"=>after,
    "event_id"=>id, "reason"=>"synthetic regression", "evidence_ref"=>"unverified test record")

@testset "Version 2 rejects invalid contracts through the complete report path" begin
    for variant in (:undeclared_disconnect, :omitted_record, :stale_hash, :wrong_allocation, :stale_revision, :missing_revision)
        data, contract = fixture()
        revision = REVISION
        variant == :undeclared_disconnect && (data["load"]["1"]["status"] = 0)
        variant == :omitted_record && delete!(data["load"], "2")
        variant == :stale_hash && (contract["source_sha256"] = repeat("0", 64))
        variant == :wrong_allocation && (contract["nominal_loads"]["1"]["pd_mw"] = 19)
        variant == :stale_revision && (contract["source_revision"] = "synthetic-load-r0")
        variant == :missing_revision && (revision = nothing)
        report = diagnose_with_load_status(build(data), data, REFERENCE, contract; revision)
        @test report["schema_version"] == "power-diagnostic-report-v2"
        @test report["status"] == "source_contract_unavailable"
        @test report["model_binding_verified"]
        @test isnothing(report["stages"][1]["reason"])
        @test report["stages"][2]["status"] == "unavailable"
        @test !isempty(report["stages"][2]["reason"])
        @test report["evidence"]["solver_invoked"] === false
        @test all(s["status"] == "not_run" for s in report["stages"][3:end])
        @test JSON.parse(JSON.json(report))["stages"][1]["reason"] === nothing
        @test occursin(report["stages"][2]["reason"], markdown_report(report))
    end
end

@testset "Revision selection is independent of the submitted contract" begin
    data, contract = fixture()
    @test check_load_status_contract(data, REFERENCE, contract; revision=REVISION).status == "source_consistent"
    other_hash = SourceRevision(repeat("1", 64), REVISION.current_revision)
    @test !check_load_status_contract(data, REFERENCE, contract; revision=other_hash).available
    @test_throws ArgumentError SourceRevision("invalid", "r1")
    @test_throws ArgumentError SourceRevision(REFERENCE.sha256, " ")
    @test !check_load_status_contract(data, REFERENCE, nothing; revision=REVISION).available
    # Equal bytes alone do not authorize changing the selected current label.
    contract["source_revision"] = "explicitly-revised-r2"
    @test !check_load_status_contract(data, REFERENCE, contract; revision=REVISION).available
    revised = SourceRevision(REFERENCE.sha256, "explicitly-revised-r2")
    @test check_load_status_contract(data, REFERENCE, contract; revision=revised).available
    data["load"]["1"]["status"] = 0
    push!(contract["events"], event(1, 0, "off"))
    result = check_load_status_contract(data, REFERENCE, contract; revision=revised)
    @test result.disabled_load_ids == ["1"]
    contract["events"][1]["reason"] = "changed later"
    @test result.switching_events[1]["reason"] == "synthetic regression"
end

@testset "Partial source checks survive unsupported models and stale bytes" begin
    data, contract = fixture()
    bad_reference = SourceLoadReference(REFERENCE.path, repeat("0", 64))
    report = diagnose_partial(build(data), data, bad_reference)
    @test report["status"] == "source_contract_unavailable"
    @test report["model_binding_verified"]
    @test occursin("hash", report["reason"])
    @test occursin("hash", markdown_report(report))
    data["load"]["1"]["qd"] *= 0.01
    partial = diagnose_partial(nothing, data, REFERENCE)
    @test partial["status"] == "partial_results"
    @test !partial["model_binding_verified"]
    @test partial["stages"][2]["status"] == "source_mismatch"
    @test !isempty(partial["findings"])
    @test all(f["binding"] == "supplied_data_only" for f in partial["findings"])
    @test partial["evidence"]["solver_invoked"] === false
    @test occursin("supplied data", markdown_report(partial))
    supported = diagnose_partial(build(data), data, REFERENCE)
    @test supported["status"] == "rejected_by_source_mismatch"
    @test supported["evidence"]["solver_invoked"] === false
    mktempdir() do directory
        path = joinpath(directory, "source.m")
        write(path, read(REFERENCE.path, String) * "\n% changed bytes\n")
        @test !P.S.check_source_loads(data, SourceLoadReference(path, REFERENCE.sha256)).available
    end
end

@testset "Accepted points retain the original mathematical checks" begin
    for variant in (:baseline, :reconnect, :rebase)
        data, contract = fixture()
        rebase = nothing
        if variant == :reconnect
            append!(contract["events"], [event(1, 0, "off"), event(0, 1, "on")])
        elseif variant == :rebase
            E.PM.make_mixed_units!(data)
            data["baseMVA"] = 200.0
            for branch in values(data["branch"])
                for field in ("br_r", "br_x"); branch[field] *= 2; end
                for field in ("g_fr", "g_to", "b_fr", "b_to"); branch[field] /= 2; end
            end
            E.PM.make_per_unit!(data)
            rebase = 200
        end
        report = diagnose_with_load_status(build(data), data, REFERENCE, contract;
            revision=REVISION, rebase_to=rebase)
        @test report["status"] == "accepted_primal_point"
        @test report["checked_rows"] > 0
        @test report["stages"][5]["status"] == "satisfied"
        @test report["revision_validation"]["status"] == "matched_selected_manifest"
        @test occursin("not authenticated", markdown_report(report))
        @test !haskey(report, "authorization_verified")
    end
    data, _ = fixture()
    for generator in values(data["gen"])
        generator["pmax"] = 0.0
        generator["pmin"] = min(generator["pmin"], 0.0)
    end
    report = diagnose_power_model(build(data), data, REFERENCE)
    @test report["status"] == "rejected_by_island_certificate"
    @test !isempty(report["findings"])
    @test report["evidence"]["workflow"]["solver_invoked"] === false
    invalid = P.summarize_workflow((status="accepted_primal_point",), (available=true,))
    @test invalid["status"] == "invalid_evidence"
end

@testset "Historical frozen code and criteria remain unchanged" begin
    for name in ("power_repair_case9_freeze", "power_repair_case14_freeze",
            "power_workflow_validation_freeze", "integrated_report_freeze", "status_provenance_freeze")
        inventory = JSON.parsefile(joinpath(ROOT, "docs", name * ".json"))
        @test all(bytes2hex(sha256(read(joinpath(ROOT, path)))) == hash for
            (path, hash) in inventory["file_sha256"])
    end
end
end
