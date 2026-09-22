using JuMP
using NLPDiagnostics
using NLPDiagnostics.Advanced

function build_rank_example()
    model = Model()
    @variable(model, x)
    @constraint(model, x^2 == 1.0)
    return (; model, x)
end

function rank_at(
    model,
    value;
    absolute_tolerance,
    label = "x=$(value)",
)
    point = evaluation_point(model, [value]; label)
    evaluation = evaluate_numerical(model, point)
    estimate = jacobian_rank_estimate(
        evaluation;
        relative_tolerance = 1.0e-12,
        absolute_tolerance,
        provenance = :pedagogical_example,
    )
    derivative = only(evaluation.jacobian_entries).value
    return (; point, evaluation, estimate, derivative)
end

function run_rank_at_a_point_example()
    example = build_rank_example()
    return (
        stationary = rank_at(
            example.model,
            0.0;
            absolute_tolerance = 0.0,
            label = "stationary infeasible point",
        ),
        near_strict = rank_at(
            example.model,
            1.0e-8;
            absolute_tolerance = 1.0e-10,
            label = "near-stationary point, strict policy",
        ),
        near_loose = rank_at(
            example.model,
            1.0e-8;
            absolute_tolerance = 1.0e-6,
            label = "near-stationary point, loose policy",
        ),
        solution = rank_at(
            example.model,
            1.0;
            absolute_tolerance = 1.0e-10,
            label = "feasible solution",
        ),
    )
end

if abspath(PROGRAM_FILE) == @__FILE__
    results = run_rank_at_a_point_example()
    @assert results.stationary.estimate.rank == 0
    @assert results.stationary.estimate.right_nullity == 1
    @assert results.near_strict.estimate.rank == 1
    @assert results.near_loose.estimate.rank == 0
    @assert results.solution.estimate.rank == 1
    display((
        stationary_rank = results.stationary.estimate.rank,
        near_strict_rank = results.near_strict.estimate.rank,
        near_loose_rank = results.near_loose.estimate.rank,
        solution_rank = results.solution.estimate.rank,
    ))
end
