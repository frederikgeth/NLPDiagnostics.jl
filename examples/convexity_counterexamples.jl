using JuMP
using NLPDiagnostics.Advanced

function run_convexity_counterexample_example()
    nonconvex = Model()
    @variable(nonconvex, x)
    @objective(nonconvex, Min, x^4 - x^2)
    witness = convexity_counterexample_campaign(
        nonconvex;
        lower = [-1.0], upper = [1.0], claim = :convex,
        seed = 3664, pairs = 64, absolute_tolerance = 1.0e-9,
        relative_tolerance = 1.0e-9,
    )
    @assert witness.conclusion == :counterexample_found
    @assert !isnothing(witness.witness_index)

    convex = Model()
    @variable(convex, y)
    @objective(convex, Min, y^2)
    control = convexity_counterexample_campaign(
        convex;
        lower = [-1.0], upper = [1.0], claim = :convex,
        seed = 3664, pairs = 64,
    )
    @assert control.conclusion == :not_observed

    restricted = Model()
    @variable(restricted, z)
    @objective(restricted, Min, log(z))
    invalid_box = convexity_counterexample_campaign(
        restricted;
        lower = [-1.0], upper = [1.0], claim = :convex,
        seed = 3664, pairs = 64,
    )
    @assert invalid_box.conclusion == :unavailable
    return (; witness, control, invalid_box)
end

if abspath(PROGRAM_FILE) == @__FILE__
    results = run_convexity_counterexample_example()
    trial = results.witness.trials[results.witness.witness_index]
    println((left = trial.left, right = trial.right,
        mixed = trial.mixed, violation = trial.violation,
        threshold = trial.threshold))
end
