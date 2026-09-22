# Run with the pinned pilot project. The existing case3 contracts run first.
using JSON, SHA, Test
const VALIDATION_ROOT=normpath(joinpath(@__DIR__,".."))
const FREEZE_PATH=joinpath(VALIDATION_ROOT,"docs","power_repair_case9_freeze.json")
const FROZEN_PLAN=JSON.parsefile(FREEZE_PATH)
const FROZEN_PLAN_SHA=bytes2hex(sha256(read(FREEZE_PATH)))
function verify_frozen_inputs()
    for (path,expected) in FROZEN_PLAN["file_sha256"]
        bytes2hex(sha256(read(joinpath(VALIDATION_ROOT,path))))==expected || error("frozen input changed: $path")
    end
    bytes2hex(sha256(read(FREEZE_PATH)))==FROZEN_PLAN_SHA || error("evaluation plan changed")
end
verify_frozen_inputs()
include("power_repair_pilot_contracts.jl")
verify_frozen_inputs()
validation_output=joinpath(VALIDATION_ROOT,"work","power-repair-case9-validation")
result=Pilot.run(validation_output;
    fixture=joinpath(VALIDATION_ROOT,FROZEN_PLAN["fixture"]),
    fixture_sha=FROZEN_PLAN["fixture_sha256"],
    scope="case9 new-to-pilot network; frozen policies, reused injected families; not a blind incident study")
verify_frozen_inputs()
records9=Dict(r["id"]=>r for r in result["records"])
criteria=Dict(
    "no_clean_errors"=>result["clean_actionable_error_count"]==0,
    "top3_at_least_two"=>result["localization_top3"]["numerator"]>=2,
    "ranking_gain_at_least_one"=>result["localization_top3"]["numerator"]-result["baseline_localization_top3"]["numerator"]>=1,
    "all_scripted_repairs_verified"=>result["verified_scripted_repairs"]["numerator"]==4,
    "diagnostics_available"=>result["diagnostic_unavailable_cases"]==0,
    "missing_reference_shift_observed"=>records9["missing_reference"]["gauge_diagnostics"]["outcome"]=="local_shift_observed",
    "other_shifts_not_observed"=>all(records9[id]["gauge_diagnostics"]["outcome"]=="local_shift_not_observed"
        for id in ("clean","voltage_bound","voltage_start","power_units")),
    "unsupported_lineage_explicit"=>all(r["load_lineage"]["outcome"]=="unavailable" for r in values(records9)))
Pilot.save(joinpath(validation_output,"evaluation.json"),Dict(
    "schema_version"=>"power-repair-case9-evaluation-v1","plan_sha256"=>FROZEN_PLAN_SHA,
    "criteria"=>criteria,"criteria_met"=>all(values(criteria)),
    "interpretation"=>"frozen development-transfer gate; failure is a result, not permission to tune or exclude the case"))
@testset "Case9 evaluation evidence integrity" begin
    @test length(records9)==5
    @test Set(keys(criteria))==Set(FROZEN_PLAN["acceptance_criteria_ids"])
    for r in values(records9)
        @test r["original_data_sha256"]==r["repaired_data_sha256"]
        @test r["repair_input_restored"]
        @test r["load_lineage"]["outcome"]=="unavailable"
    end
    @test result["human_repair_time"]===nothing
end
println("Frozen case9 evaluation criteria: ",criteria)
