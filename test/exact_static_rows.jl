module ExactStaticRowTests
using Test
import MathOptInterface as MOI
import NLPDiagnostics as ND

const AF = MOI.ScalarAffineFunction{Float64}
const AT = MOI.ScalarAffineTerm
const QF = MOI.ScalarQuadraticFunction{Float64}
const QT = MOI.ScalarQuadraticTerm
const x, y = MOI.VariableIndex(1), MOI.VariableIndex(2)
row(f, set, i=1) = ND.ConstraintRecord(MOI.ConstraintIndex{typeof(f),typeof(set)}(i), f, set, "")
newmodel() = MOI.Utilities.UniversalFallback(MOI.Utilities.Model{Float64}())
exact(v) = Rational{BigInt}(v)

@testset "Exact affine normalization separates feasible nonparallel rows" begin
    huge, tiny = floatmax(Float64), nextfloat(0.0)
    # Rounded normalization loses both y coefficients. The exact rows intersect.
    model = newmodel()
    variables = MOI.add_variables(model, 2)
    for (coefficient, rhs) in ((tiny, 0.0), (2tiny, 1.0))
        f = AF([AT(huge, variables[1]), AT(coefficient, variables[2])], 0.0)
        MOI.add_constraint(model, f, MOI.EqualTo(rhs))
    end
    witness = Dict(variables[1] => -inv(exact(huge)), variables[2] => inv(exact(tiny)))
    snapshot = ND.snapshot(model)
    for constraint in snapshot.constraints
        @test ND._exact_fixed_polynomial_value(constraint.function_value, witness) == constraint.set_value.value
    end
    report = ND.analyze_static(model)
    @test isempty(ND.findings(report; code=:inconsistent_parallel_affine_equalities))
    @test isempty(ND.findings(report; code=:proportional_affine_equality_constraints))
    relations = ND._affine_equality_normalized_relation.(snapshot.constraints)
    @test first(relations[1]) != first(relations[2])
    @test last(first(relations[1])[2]) == exact(tiny)/exact(huge)

    # Underflow also must not make distinct half-spaces parallel or dominated.
    inequalities = newmodel(); u,v = MOI.add_variables(inequalities, 2)
    for (coefficient, rhs) in ((tiny, 0.0), (2tiny, -1.0))
        MOI.add_constraint(inequalities, AF([AT(huge,u), AT(coefficient,v)], 0.0), MOI.LessThan(rhs))
    end
    inequalities_report = ND.analyze_static(inequalities)
    @test isempty(ND.findings(inequalities_report; code=:dominated_affine_inequality))
    @test isempty(ND.findings(inequalities_report; code=:proportional_affine_inequality_constraints))

    # Distinct large normalized bounds must not collapse to the same infinity.
    f = AF([AT(tiny,x)], 0.0)
    for set in (MOI.EqualTo, MOI.LessThan, MOI.GreaterThan)
        normalize = set == MOI.EqualTo ? ND._affine_equality_normalized_relation : ND._affine_inequality_normalized_relation
        a, b = normalize(row(f,set(1.0))), normalize(row(f,set(2.0)))
        @test last(a) != last(b)
        @test isfinite(last(a)) && isfinite(last(b))
    end
end

@testset "Exact row fingerprints preserve cancellation and signed scaling" begin
    terms = [AT(1e16,x), AT(1.0,x), AT(-1e16,x)]
    reference = AF([AT(1.0,x)], 0.0)
    zero = AF(AT{Float64}[], 0.0)
    for order in ([1,2,3], [3,2,1], [1,3,2])
        f = AF(terms[order], 0.0)
        @test ND._fingerprint(f) == ND._fingerprint(reference)
        @test ND._fingerprint(f) != ND._fingerprint(zero)
        @test ND._affine_equality_normalized_relation(row(f, MOI.EqualTo(1.0))) ==
              ND._affine_equality_normalized_relation(row(reference, MOI.EqualTo(1.0)))
        q = QF([QT(c,x,y) for c in (1e16, 1.0, -1e16)][order], AT{Float64}[], 0.0)
        @test ND._fingerprint(q) == ND._fingerprint(QF([QT(1.0,y,x)], AT{Float64}[], 0.0))
        @test ND._fingerprint(q) != ND._fingerprint(QF(QT{Float64}[], AT{Float64}[], 0.0))
    end
    positive = AF([AT(3.0,x), AT(7.0,y)], 5.0)
    negative = AF([AT(-6.0,x), AT(-14.0,y)], -10.0)
    @test ND._affine_equality_normalized_relation(row(positive,MOI.EqualTo(8.0))) ==
          ND._affine_equality_normalized_relation(row(negative,MOI.EqualTo(-16.0)))
    @test ND._affine_inequality_normalized_relation(row(positive,MOI.LessThan(8.0))) ==
          ND._affine_inequality_normalized_relation(row(negative,MOI.GreaterThan(-16.0)))
    @test first(ND._affine_inequality_normalized_relation(row(positive,MOI.LessThan(8.0)))) !=
          first(ND._affine_inequality_normalized_relation(row(negative,MOI.LessThan(-16.0))))

    # Unsupported coefficients, constants, and RHSs must abstain before arithmetic.
    for bad in (NaN, Inf, -Inf), location in (:coefficient, :constant, :rhs)
        f = AF([AT(location == :coefficient ? bad : 1.0, x)], location == :constant ? bad : 0.0)
        rhs = location == :rhs ? bad : 1.0
        @test isnothing(ND._affine_equality_normalized_relation(row(f,MOI.EqualTo(rhs))))
        @test isnothing(ND._affine_inequality_normalized_relation(row(f,MOI.LessThan(rhs))))
        @test isnothing(ND._affine_inequality_normalized_relation(row(f,MOI.GreaterThan(rhs))))
    end
end

@testset "Exact row comparisons retain genuine contradiction and redundancy" begin
    for (rhs, code) in ((2.0,:proportional_affine_equality_constraints), (3.0,:inconsistent_parallel_affine_equalities))
        model = newmodel(); u,v = MOI.add_variables(model,2)
        MOI.add_constraint(model,AF([AT(1.0,u),AT(3.0,v)],0.0),MOI.EqualTo(1.0))
        MOI.add_constraint(model,AF([AT(2.0,u),AT(6.0,v)],0.0),MOI.EqualTo(rhs))
        @test length(ND.findings(ND.analyze_static(model);code)) == 1
    end
    # Subtraction of opposite extreme constants is also exact, without overflow.
    for scale in (nextfloat(0.0), 3.0, floatmax(Float64))
        f = AF([AT(scale,x), AT(1.0,y)], -floatmax(Float64))
        relation = ND._affine_equality_normalized_relation(row(f,MOI.EqualTo(floatmax(Float64))))
        @test last(relation) == 2exact(floatmax(Float64))/exact(scale)
        @test first(relation) == [(1,exact(1)), (2,inv(exact(scale)))]
    end
end

@testset "Variable-free numerical evaluation does not certify real values" begin
    # In real arithmetic this expression is exactly one; Float64 gives zero.
    expression = MOI.ScalarNonlinearFunction(:-, Any[
        MOI.ScalarNonlinearFunction(:+, Any[1e16, 1.0]), 1e16])
    for (rhs, code) in ((1.0, :constant_expression_numerical_violation),
                        (0.0, :constant_expression_numerically_satisfied))
        model = newmodel()
        MOI.add_constraint(model, expression, MOI.EqualTo(rhs))
        report = ND.analyze_static(model)
        @test isempty(ND.findings(report; code=:infeasible_constant_constraint))
        @test isempty(ND.findings(report; code=:redundant_constant_constraint))
        @test only(ND.findings(report; code)).basis == ND.NumericalObservation
    end
    # sqrt is defined at the exact result zero but the rounded operand is -1.
    operand = MOI.ScalarNonlinearFunction(:-, Any[expression, 1.0])
    bad_evaluation = MOI.ScalarNonlinearFunction(:sqrt, Any[operand])
    model = newmodel()
    MOI.add_constraint(model, bad_evaluation, MOI.EqualTo(0.0))
    failure = only(ND.findings(ND.analyze_static(model); code=:constant_domain_violation))
    @test failure.basis == ND.NumericalObservation
    @test failure.domain == ND.NumericalIssue

    for (f, code) in ((expression, :constant_objective),
                      (bad_evaluation, :constant_objective_domain_violation))
        objective_model = newmodel()
        MOI.set(objective_model, MOI.ObjectiveSense(), MOI.MIN_SENSE)
        MOI.set(objective_model, MOI.ObjectiveFunction{typeof(f)}(), f)
        @test only(ND.findings(ND.analyze_static(objective_model); code)).basis == ND.NumericalObservation
    end
    # Exact represented polynomial constants retain certified findings.
    for (value, code) in ((1.0,:redundant_constant_constraint), (2.0,:infeasible_constant_constraint))
        direct = newmodel()
        MOI.add_constraint(direct,AF(AT{Float64}[],value),MOI.EqualTo(1.0))
        @test only(ND.findings(ND.analyze_static(direct); code)).basis == ND.MathematicalProof
    end
    nonfinite = newmodel()
    MOI.add_constraint(nonfinite,AF(AT{Float64}[],Inf),MOI.EqualTo(1.0))
    @test isempty(ND.findings(ND.analyze_static(nonfinite); code=:infeasible_constant_constraint))
    for bad in (Inf, -Inf, NaN)
        product = MOI.ScalarNonlinearFunction(:*, Any[0.0, bad, x])
        @test !ND._is_direct_zero_product(product)
        @test ND.variable_support(product).variables == [x]
        constant_product = MOI.ScalarNonlinearFunction(:*, Any[0.0, bad])
        invalid = newmodel()
        MOI.add_constraint(invalid, constant_product, MOI.EqualTo(0.0))
        @test isempty(ND.findings(ND.analyze_static(invalid); code=:redundant_constant_constraint))
    end
end
end
