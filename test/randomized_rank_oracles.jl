using Test

module RandomizedRankOracleBenchmark
include(joinpath(
    @__DIR__, "..", "benchmarks", "calibrate_randomized_rank_oracles.jl",
))
end

@testset "seeded randomized rank-oracle campaign" begin
    campaign = RandomizedRankOracleBenchmark.randomized_rank_oracle_campaign()
    @test campaign["report_version"] == "seeded-randomized-rank-oracles-v1"
    @test campaign["seeds"] == [11, 29, 47]
    @test campaign["record_count"] == 27
    @test campaign["hard_expectation_count"] == 18
    @test campaign["all_hard_expectations_matched"]
    @test isempty(campaign["hard_expectation_mismatches"])

    records = campaign["records"]
    for seed in campaign["seeds"]
        selected(class) = filter(record ->
            record["seed"] == seed && record["oracle_class"] == class,
            records,
        )
        @test only(selected("full_rank_negative_control"))["dense_rank"] == 8
        @test only(selected("full_rank_negative_control"))["sparse_rank"] == 8
        @test only(selected("rectangular_exact_nullity"))["dense_rank"] == 7
        @test only(selected("rectangular_exact_nullity"))["sparse_rank"] == 7
        @test only(selected("scaling_intervention"))["dense_rank"] == 8
        @test only(selected("scaling_intervention"))["sparse_rank"] == 8
        @test only(selected("nonlinear_cancellation"))["dense_rank"] == 1
        @test only(selected("nonlinear_cancellation"))["sparse_rank"] == 1
        @test only(selected("nonlinear_cancellation_negative_control"))["dense_rank"] == 2
        @test only(selected("nonlinear_cancellation_negative_control"))["sparse_rank"] == 2

        clusters = selected("threshold_cluster")
        @test length(clusters) == 3
        @test sort([record["policy_expected_rank"] for record in clusters]) == [2, 3, 4]
        @test all(!record["hard_expectation"] for record in clusters)
    end

    @test_throws ArgumentError RandomizedRankOracleBenchmark.randomized_rank_oracle_campaign(
        seeds = Int[],
    )
    @test_throws ArgumentError RandomizedRankOracleBenchmark.randomized_rank_oracle_campaign(
        seeds = [11, 11],
    )
end
