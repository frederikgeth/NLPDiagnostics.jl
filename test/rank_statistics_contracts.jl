module RankStatisticsContracts
using Test, JSON
include("../benchmarks/rank_statistics.jl")
using .RankCalibrationStatistics

function row(name, expected, dense, sparse; hard=true)
    Dict{String,Any}("name"=>name, "rows"=>3, "columns"=>3,
        "policy_expected_rank"=>expected, "hard_expectation"=>hard,
        "dense_available"=>!isnothing(dense), "dense_rank"=>dense,
        "sparse_available"=>!isnothing(sparse), "sparse_rank"=>sparse)
end

@testset "Rank class denominators, abstentions, and per-corpus errors" begin
    corpora = Dict(
        "seeded" => [row("full", 3, 2, 3), row("deficient", 2, 3, 2)],
        "perturbation" => [row("full", 3, nothing, 2), row("deficient", 2, 1, nothing)],
        "adversarial" => [row("deficient", 1, 1, 3), row("threshold", 2, 3, 2; hard=false)],
    )
    result = summarize_records(corpora)
    hard = result["hard_controls"]
    @test hard["record_count"] == 5
    @test hard["truth_positive_count"] == 3
    @test hard["truth_negative_count"] == 2
    @test hard["false_positive_count"] == 2
    @test hard["false_negative_count"] == 2
    @test hard["mismatch_count"] == 5 # includes the 2 -> 1 exact-rank error
    @test hard["unavailable_count"] == 2
    @test hard["dense_sparse_complete_count"] == 3
    @test hard["agreement_count"] == 0
    dense = hard["backends"]["dense"]
    sparse = hard["backends"]["sparse"]
    @test dense["false_positive_rate_among_available"] == 1
    @test dense["false_negative_rate_among_available"] == 1/3
    @test sparse["false_positive_rate_among_available"] == 1/2
    @test sparse["false_negative_rate_among_available"] == 1/2
    @test dense["unavailable_negative_count"] == 1
    @test sparse["unavailable_positive_count"] == 1
    @test result["threshold_sensitive_controls"]["backend_disagreement_count"] == 1
    @test !result["finite_sample_uncertainty"]["available"]
    @test isnothing(result["finite_sample_uncertainty"]["zero_event_upper_bound"])
    for name in keys(corpora)
        @test result["by_corpus"][name]["hard_controls"]["mismatch_count"] > 0
    end
    duplicate = deepcopy(corpora)
    push!(duplicate["seeded"], duplicate["seeded"][1])
    @test_throws ArgumentError summarize_records(duplicate)
    bad = row("bad", 3, 4, 3)
    @test_throws ArgumentError summarize_records(Dict("bad"=>[bad]))
    absent = summarize_records(Dict("empty"=>[row("absent", 3, nothing, nothing)]))
    @test absent["hard_controls"]["unavailable_count"] == 1
    @test isnothing(absent["hard_controls"]["backends"]["dense"]["false_positive_rate_among_available"])
    @test absent["hard_controls"]["agreement_count"] == 0
end

@testset "Saved corpora derive counts from records" begin
    root = normpath(joinpath(@__DIR__, "..", "docs"))
    corpora = Dict(
        "seeded_randomized" => JSON.parsefile(joinpath(root, "randomized_rank_oracle_records.json"))["records"],
        "controlled_perturbation" => JSON.parsefile(joinpath(root, "rank_perturbation_sweep_summary.json"))["records"],
        "deterministic_adversarial_extension" => JSON.parsefile(joinpath(root, "rank_adversarial_extension_summary.json"))["records"],
    )
    result = summarize_records(corpora)
    @test result["hard_controls"]["record_count"] == 49
    @test result["hard_controls"]["agreement_count"] == 49
    @test result["threshold_sensitive_controls"]["record_count"] == 26
    @test result["threshold_sensitive_controls"]["backend_disagreement_count"] == 9
    # Each source corpus contributes both class denominators and its failures.
    for name in keys(corpora)
        mutated = deepcopy(corpora)
        record = first(r for r in mutated[name] if r["hard_expectation"] &&
            r["policy_expected_rank"] == min(r["rows"], r["columns"]))
        record["dense_rank"] -= 1
        @test summarize_records(mutated)["hard_controls"]["false_positive_count"] == 1
        record["dense_available"] = false
        @test summarize_records(mutated)["hard_controls"]["unavailable_count"] == 1
    end
end
end
