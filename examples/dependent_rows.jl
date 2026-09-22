using JuMP
using NLPDiagnostics
using NLPDiagnostics.Advanced

function run_dependent_rows_example()
    model = Model()
    @variable(model, x)
    @variable(model, y)
    @constraint(model, balance, x + y == 1)
    @constraint(model, difference, x - y == 0)
    @constraint(model, redundant_x, 2x == 1)

    point = evaluation_point(model, [0.5, 0.5]; label = "feasible teaching point")
    evaluation = evaluate_numerical(model, point)
    result = dependent_row_localization(
        evaluation;
        relative_tolerance = 1.0e-10,
        absolute_tolerance = 1.0e-12,
        provenance = :pedagogical_example,
    )
    @assert result.available && result.dependent === true
    @assert result.irreducible_under_policy
    @assert length(result.rows) == 3
    @assert result.deletion_ranks == [2, 2, 2]
    @assert result.relative_residual < 1.0e-12
    return (; model, evaluation, result,
        report = dependent_row_localization_report(result))
end

if abspath(PROGRAM_FILE) == @__FILE__
    example = run_dependent_rows_example()
    println(dependent_row_localization_data(example.result))
end
