# Standalone integration test; use the pinned pilot environment.
using Test, JSON
include("../benchmarks/run_power_repair_pilot.jl")
const Pilot=PowerRepairPilot
@testset "Pilot serialization and unavailable evidence" begin
    @test Pilot.digest(Dict("b"=>2,"a"=>1))==Pilot.digest(Dict("a"=>1,"b"=>2))
    @test JSON.parse(Pilot.canonical([NaN,Inf,-Inf]))==[
        Dict("nonfinite_literal"=>"NaN"),Dict("nonfinite_literal"=>"Inf"),Dict("nonfinite_literal"=>"-Inf")]
    failed=Pilot.diagnostic_stage(()->error("injected unavailable stage"))
    @test !failed["available"]
    @test occursin("injected unavailable stage",failed["reason"])
    @test isempty(failed["report"]["findings"])
    @test Pilot.diagnostic_stage(()->Dict("findings"=>[]))["available"]
    @test_throws InterruptException Pilot.diagnostic_stage(()->throw(InterruptException()))
    @test Pilot.filehash(Pilot.FIXTURE)==Pilot.FIXTURE_SHA
    unavailable=Pilot.gauge_diagnostics(nothing)
    @test !unavailable["available"]
    @test unavailable["outcome"]=="unavailable"
    @test occursin("requires ACP",unavailable["reason"])
end
output=isempty(ARGS) ? joinpath(Pilot.ROOT,"work","power-repair-pilot") : abspath(only(ARGS))
@testset "Source load lineage is independent and fails closed" begin
    ledger=Pilot.source_load_ledger()
    data=Dict("per_unit"=>true,"baseMVA"=>ledger["base_mva"],"load"=>Dict(
        bus=>Dict("load_bus"=>parse(Int,bus),"status"=>1,
            "pd"=>row["pd_mw"]/ledger["base_mva"],"qd"=>row["qd_mvar"]/ledger["base_mva"])
        for (bus,row) in ledger["buses"]))
    @test Pilot.check_load_lineage(data,ledger)["outcome"]=="source_consistent"
    @test length(Pilot.check_load_lineage(data,ledger)["checks"])==6
    for (field,value) in (("pd",0.011),("qd",0.0),("pd",-1.1))
        changed=deepcopy(data);changed["load"]["1"][field]=value
        result=Pilot.check_load_lineage(changed,ledger)
        @test result["outcome"]=="source_mismatch"
        @test only(result["mismatches"])["field"]==field
        @test only(result["mismatches"])["bus_id"]=="1"
    end
    for invalid in (NaN,Inf,-Inf)
        changed=deepcopy(data);changed["load"]["1"]["pd"]=invalid
        @test Pilot.check_load_lineage(changed,ledger)["outcome"]=="unavailable"
    end
    for key in ("per_unit","baseMVA")
        changed=deepcopy(data);delete!(changed,key)
        @test !Pilot.check_load_lineage(changed,ledger)["available"]
    end
    changed=deepcopy(data);changed["baseMVA"]=200.0
    @test Pilot.check_load_lineage(changed,ledger)["outcome"]=="unavailable"
    changed=deepcopy(data);changed["load"]["extra"]=deepcopy(changed["load"]["1"])
    @test Pilot.check_load_lineage(changed,ledger)["outcome"]=="unavailable"
    changed=deepcopy(data);delete!(changed["load"],"1")
    @test Pilot.check_load_lineage(changed,ledger)["outcome"]=="unavailable"
    forged=deepcopy(ledger);forged["buses"]["1"]["pd_mw"]=1.1
    @test Pilot.check_load_lineage(data,forged)["outcome"]=="unavailable"
    forged=deepcopy(ledger);forged["power_units"]["pd"]="kW"
    @test Pilot.check_load_lineage(data,forged)["outcome"]=="unavailable"
    changed=deepcopy(data);changed["load"]["1"]["pd"]+=1e-12
    @test Pilot.check_load_lineage(changed,ledger)["outcome"]=="source_consistent"
end
@testset "Priority rules preserve evidence and abstain on unknown code/basis pairs" begin
    finding(code,basis;severity="error",index=1,detail="")=Dict(
        "code"=>code,"basis"=>basis,"severity"=>severity,
        "affected"=>[Dict("kind"=>"variable","index"=>index)],"detail"=>detail)
    bounds=finding("inconsistent_variable_bounds","mathematical_proof")
    start=finding("initialization_violates_variable_bounds","mathematical_proof")
    residual=finding("constraint_feasibility_violation","numerical_observation")
    unknown=finding("aaa_unknown_error","mathematical_proof")
    nonfinite=finding("initialization_nonfinite_value","numerical_observation")
    advisory=finding("inconsistent_variable_bounds","mathematical_proof";severity="info")
    inputs=[residual,unknown,advisory,start,bounds,nonfinite]
    before=deepcopy(inputs)
    baseline,ranked=Pilot.rank_findings(inputs)
    @test inputs==before
    @test first(ranked)==bounds
    @test findfirst(==(start),ranked)<findfirst(==(residual),ranked)
    @test findfirst(==(nonfinite),ranked)<findfirst(==(unknown),ranked)
    @test last(ranked)==residual
    @test !(advisory in ranked)
    @test length(ranked)==5
    @test sort(Pilot.canonical.(ranked))==sort(Pilot.canonical.(baseline))
    @test Pilot.rank_findings(reverse(inputs))==(baseline,ranked)
    for code in ("inconsistent_variable_bounds","initialization_violates_variable_bounds",
                 "initialization_nonfinite_value","constraint_feasibility_violation")
        @test first(Pilot.priority_class(finding(code,"heuristic_interpretation")))==2
    end
    @test first(Pilot.priority_class(unknown))==2
    @test Pilot.rank_findings([advisory])==([],[])
    # Equal affected identities still have deterministic evidence ordering.
    duplicate=deepcopy(start);alternative=deepcopy(start);alternative["detail"]="other witness"
    tied=[duplicate,alternative,start]
    @test Pilot.rank_findings(tied)==Pilot.rank_findings(reverse(tied))
    @test length(last(Pilot.rank_findings(tied)))==3
end
summary=Pilot.run(output;load_seconds=(time_ns()-PILOT_LOAD_START)/1e9)
@testset "Pilot independent repair evidence" begin
    @test length(summary["records"])==5
    @test summary["diagnostic_unavailable_cases"]==0
    @test summary["verified_scripted_repairs"]==Dict("numerator"=>4,"denominator"=>4)
    @test summary["human_repair_time"]===nothing
    records=Dict(r["id"]=>r for r in summary["records"])
    @test summary["ranking_policy"]==Pilot.RANKING_POLICY
    @test summary["baseline_localization_top3"]==Dict("numerator"=>1,"denominator"=>4)
    @test summary["localization_top3"]==Dict("numerator"=>2,"denominator"=>4)
    @test records["voltage_start"]["localization_rank"]==1
    @test records["voltage_start"]["baseline_localization_rank"]==10
    @test records["voltage_bound"]["localization_rank"]==1
    @test records["clean"]["actionable_count"]==0
    @test summary["gauge_configuration"]=="connected-acp-uniform-shift-v1; separate from ranked findings"
    @test records["missing_reference"]["gauge_diagnostics"]["outcome"]=="local_shift_observed"
    for id in ("clean","voltage_bound","voltage_start","power_units")
        @test records[id]["gauge_diagnostics"]["outcome"]=="local_shift_not_observed"
    end
    observed=filter(f->f["code"]=="expected_nullspace_mode_observed",
        records["missing_reference"]["gauge_diagnostics"]["report"]["findings"])
    @test length(observed)==1
    @test only(observed)["basis"]=="physical_expectation"
    for r in values(records)
        @test r["load_lineage"]["available"]
        @test r["load_lineage"]["outcome"]==(r["id"]=="power_units" ? "source_mismatch" : "source_consistent")
        @test r["repaired_load_lineage"]["outcome"]=="source_consistent"
        gauge=r["gauge_diagnostics"]
        @test gauge["available"]
        @test gauge["report"]["automatic_candidate_count"]==1
        @test any(f->f["code"]=="powermodels_reference_bus_unique",
            gauge["report"]["reference_metadata_report"]["findings"])
        @test gauge["report"]["candidate"]["coefficients"]==ones(3)
        diagnostics=JSON.parsefile(joinpath(output,r["id"],"diagnostics.json"))
        @test sort(Pilot.canonical.(diagnostics["ranked_actionable"]))==
            sort(Pilot.canonical.(diagnostics["baseline_ranked_actionable"]))
        @test length(diagnostics["ranking_reasons"])==r["actionable_count"]
        @test r["proposed_patch"]===nothing
        @test r["repair_input_restored"]
        @test r["original_data_sha256"]==r["repaired_data_sha256"]
        @test r["repair_physical_checks"]["passed"]
        @test r["repair_solve"]["jump_feasibility"]["violation_count"]==0
    end
    @test records["clean"]["intended_physical_checks"]["passed"]
    @test !records["voltage_bound"]["modified_physical_checks"]["passed"]
    @test records["power_units"]["modified_physical_checks"]["passed"]
    mismatch=only(records["power_units"]["load_lineage"]["mismatches"])
    @test mismatch["field"]=="pd"
    @test mismatch["bus_id"]=="1"
    @test mismatch["observed_to_expected_ratio"]≈0.01
    @test !records["power_units"]["intended_physical_checks"]["passed"]
    @test records["missing_reference"]["truth"]["ac_graph_connected"]
    @test records["missing_reference"]["truth"]["uniform_shift_physical_checks"]["passed"]
    @test records["missing_reference"]["truth"]["shift_violates_original_reference"]
end
