using Test
using JuMP

import NLPDiagnostics

const _advanced_convexity = NLPDiagnostics.Advanced

@testset "seeded convexity counterexamples and controls" begin
    model = Model()
    @variable(model, x)
    @objective(model, Min, -x^2)
    result = _advanced_convexity.convexity_counterexample_campaign(
        model; lower = [-1.0], upper = [1.0], seed = 19,
        pairs = 12, claim = :convex,
    )
    @test result.available
    @test result.conclusion == :counterexample_found
    @test length(result.trials) == 12
    trial = result.trials[result.witness_index]
    @test trial.status == :counterexample
    @test trial.violation > trial.threshold
    @test trial.mixed ≈ result.weight .* trial.left .+
        (1 - result.weight) .* trial.right
    @test trial.mixed_value - trial.chord_value ≈ trial.violation
    @test result.model_fingerprint != ""
    @test _advanced_convexity.convexity_counterexample_campaign_data(result)[
        "trials"][result.witness_index]["left"] == trial.left
    @test only(_advanced_convexity.convexity_counterexample_campaign_report(
        result).findings).code == :convexity_counterexample_observed

    replay = _advanced_convexity.convexity_counterexample_campaign(
        model; lower = [-1.0], upper = [1.0], seed = 19,
        pairs = 12, claim = :convex,
    )
    @test [item.left for item in replay.trials] ==
        [item.left for item in result.trials]
    @test replay.witness_index == result.witness_index

    suppressed = _advanced_convexity.convexity_counterexample_campaign(
        model; lower = [-1.0], upper = [1.0], seed = 19,
        pairs = 12, claim = :convex, absolute_tolerance = 10.0,
    )
    @test suppressed.conclusion == :not_observed

    convex = Model()
    @variable(convex, y)
    @objective(convex, Min, y^2)
    control = _advanced_convexity.convexity_counterexample_campaign(
        convex; lower = [-1.0], upper = [1.0], seed = 19,
        pairs = 12, claim = :convex,
    )
    @test control.conclusion == :not_observed
    @test isnothing(control.witness_index)
    @test only(_advanced_convexity.convexity_counterexample_campaign_report(
        control).findings).code == :convexity_counterexample_not_observed
    concave_claim = _advanced_convexity.convexity_counterexample_campaign(
        convex; lower = [-1.0], upper = [1.0], seed = 19,
        pairs = 12, claim = :concave,
    )
    @test concave_claim.conclusion == :counterexample_found

    row_model = Model()
    @variable(row_model, z)
    @constraint(row_model, curved_row, z^2 <= 1)
    row_result = _advanced_convexity.convexity_counterexample_campaign(
        row_model; lower = [-1.0], upper = [1.0], row = 1,
        claim = :concave, seed = 19, pairs = 12,
    )
    @test row_result.conclusion == :counterexample_found
    @test row_result.source.name == "curved_row"
end

@testset "convexity campaign domain and availability boundaries" begin
    restricted = Model()
    @variable(restricted, x)
    @objective(restricted, Min, log(x))
    invalid = _advanced_convexity.convexity_counterexample_campaign(
        restricted; lower = [-1.0], upper = [1.0], seed = 2,
    )
    @test !invalid.available
    @test invalid.conclusion == :unavailable
    @test occursin("domain", invalid.reason)
    @test isempty(invalid.trials)
    @test only(_advanced_convexity.convexity_counterexample_campaign_report(
        invalid).findings).code == :convexity_campaign_unavailable

    valid = _advanced_convexity.convexity_counterexample_campaign(
        restricted; lower = [1.0], upper = [2.0], seed = 2,
        pairs = 12,
    )
    @test valid.available
    @test valid.conclusion == :counterexample_found
    @test valid.domain_basis == :certified_coordinate_box

    bounded = Model()
    @variable(bounded, y >= 0)
    @objective(bounded, Min, y^2)
    outside = _advanced_convexity.convexity_counterexample_campaign(
        bounded; lower = [-1.0], upper = [1.0], seed = 2,
    )
    @test !outside.available
    @test occursin("coordinate interval", outside.reason)

    empty = Model()
    @variable(empty, q)
    no_objective = _advanced_convexity.convexity_counterexample_campaign(
        empty; lower = [0.0], upper = [1.0],
    )
    @test !no_objective.available
    @test occursin("no ordinary scalar objective", no_objective.reason)

    overflowing = Model()
    @variable(overflowing, t)
    @objective(overflowing, Min, exp(t))
    incomplete = _advanced_convexity.convexity_counterexample_campaign(
        overflowing; lower = [710.0], upper = [711.0], seed = 2,
        pairs = 4,
    )
    @test incomplete.available
    @test incomplete.conclusion == :inconclusive
    @test all(trial -> trial.status == :evaluation_unavailable,
        incomplete.trials)
    @test only(_advanced_convexity.convexity_counterexample_campaign_report(
        incomplete).findings).code == :convexity_campaign_inconclusive

    @test_throws ArgumentError _advanced_convexity.convexity_counterexample_campaign(
        restricted; lower = [1.0], upper = [2.0], pairs = 0,
    )
    @test_throws ArgumentError _advanced_convexity.convexity_counterexample_campaign(
        restricted; lower = [1.0], upper = [2.0], claim = :unknown,
    )
    @test_throws ArgumentError _advanced_convexity.convexity_counterexample_campaign(
        restricted; lower = [1.0], upper = [2.0], weight = 1.0,
    )
    @test_throws DimensionMismatch _advanced_convexity.convexity_counterexample_campaign(
        restricted; lower = [1.0, 2.0], upper = [2.0],
    )
end
