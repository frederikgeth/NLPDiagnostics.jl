using JSON, Test
include("capacity_preflight_contracts.jl")
include("../benchmarks/run_capacity_preflight_followup.jl")
@testset "Post-evaluation capacity evidence" begin
    summary=JSON.parsefile(joinpath(output,"summary.json"))
    @test !summary["frozen_criteria_met"]
    @test length(summary["records"])==3
    for r in summary["records"]
        expected=r["id"]=="clean" ? "not_ruled_out" : "capacity_shortage"
        @test r["preflight"]["status"]==expected
        @test r["preflight"]["gap_exact_pu"]==r["frozen_capacity_witness"]["gap_exact_pu"]
        @test r["repaired_preflight"]["status"]=="not_ruled_out"
        @test r["frozen_static_error_count"]==0
    end
end
