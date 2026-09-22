@testset "bounds expressed as affine constraints" begin
    model = MOI.Utilities.Model{Float64}()
    x, y = MOI.add_variables(model, 2)
    F = MOI.ScalarAffineFunction{Float64}
    T = MOI.ScalarAffineTerm{Float64}

    MOI.add_constraint(
        model,
        F([T(2.0, x)], 1.0),
        MOI.LessThan(9.0),
    )
    MOI.add_constraint(
        model,
        F([T(-2.0, x)], 1.0),
        MOI.LessThan(5.0),
    )
    MOI.add_constraint(
        model,
        F([T(3.0, y)], -1.0),
        MOI.EqualTo(5.0),
    )
    MOI.add_constraint(
        model,
        F([T(-2.0, y)], 2.0),
        MOI.Interval(-6.0, 4.0),
    )
    # A direct variable-in-set bound is already represented as a bound.
    MOI.add_constraint(model, x, MOI.GreaterThan(-10.0))
    # A two-variable row is not equivalent to a bound on either variable.
    MOI.add_constraint(
        model,
        F([T(1.0, x), T(1.0, y)], 0.0),
        MOI.LessThan(10.0),
    )

    constraint_types_before = MOI.get(model, MOI.ListOfConstraintTypesPresent())
    constraint_count_before = sum(
        MOI.get(model, MOI.NumberOfConstraints{F,S}())
        for (F, S) in constraint_types_before
    )
    report = NLPDiagnostics.analyze_static(model)
    lint = NLPDiagnostics.findings(report; code = :bound_expressed_as_constraint)

    @test length(lint) == 4
    @test report.metadata[:bound_expressed_as_constraint_count] == "4"
    @test all(finding -> finding.severity == NLPDiagnostics.SeverityInfo, lint)
    @test all(finding -> finding.domain == NLPDiagnostics.RepresentationalIssue, lint)
    @test all(finding -> finding.basis == NLPDiagnostics.MathematicalProof, lint)
    @test all(finding -> finding.confidence == NLPDiagnostics.ConfidenceCertain, lint)
    @test all(finding -> count(ref -> ref.kind == :constraint, finding.affected) == 1, lint)
    @test all(finding -> count(ref -> ref.kind == :variable, finding.affected) == 1, lint)

    details = [Dict(finding.evidence[1].details) for finding in lint]
    by_bound = Dict(detail["equivalent_bound"] => detail for detail in details)
    @test Set(keys(by_bound)) == Set([
        "LessThan(4.0)",
        "GreaterThan(-2.0)",
        "EqualTo(2.0)",
        "Interval(-1.0, 4.0)",
    ])
    @test by_bound["LessThan(4.0)"]["translated_lower"] == "nothing"
    @test by_bound["LessThan(4.0)"]["translated_upper"] == "4.0"
    @test all(
        details -> details["preserves_scalar_feasible_set"] == "true",
        values(by_bound),
    )

    @test MOI.get(model, MOI.ListOfConstraintTypesPresent()) == constraint_types_before
    @test sum(
        MOI.get(model, MOI.NumberOfConstraints{F,S}())
        for (F, S) in constraint_types_before
    ) == constraint_count_before
end

@testset "bound-row lint abstains without an exact finite bound" begin
    model = MOI.Utilities.Model{Float64}()
    x = MOI.add_variable(model)
    F = MOI.ScalarAffineFunction{Float64}
    T = MOI.ScalarAffineTerm{Float64}

    # Duplicate terms cancel exactly, leaving no variable to isolate.
    MOI.add_constraint(
        model,
        F([T(1.0, x), T(-1.0, x)], 0.0),
        MOI.LessThan(1.0),
    )
    # An entirely unbounded interval does not define a finite bound.
    MOI.add_constraint(
        model,
        F([T(1.0, x)], 0.0),
        MOI.Interval(-Inf, Inf),
    )

    report = NLPDiagnostics.analyze_static(model)
    @test isempty(NLPDiagnostics.findings(
        report;
        code = :bound_expressed_as_constraint,
    ))
    @test report.metadata[:bound_expressed_as_constraint_count] == "0"
end
