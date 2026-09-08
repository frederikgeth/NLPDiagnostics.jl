module IntervalCertificationTests
using Test
import MathOptInterface as MOI
import NLPDiagnostics as ND
const I=ND.IntervalEnclosure
cert(a,b) = I(a,b; certified=true)
newmodel() = MOI.Utilities.UniversalFallback(MOI.Utilities.Model{Float64}())

# Extensions must assert a validated enclosure explicitly. Legacy results are
# estimates; even a singleton must not be mistaken for an exact evaluation.
ND.operator_interval(::Val{:uncertified_test_range}, args::Vector{ND.IntervalEnclosure}, originals) = I(-1.0,-1.0)
ND.operator_interval(::Val{:certified_test_range}, args::Vector{ND.IntervalEnclosure}, originals) = cert(-1.0,-1.0)

@testset "Enclosure certificates survive arithmetic and extension boundaries" begin
    @test !I(1,1).certified
    @test !I(1,1,true,true).certified
    @test cert(1,1).certified
    @test only(ND.operator_domain_requirements(Val(:log), Any[1], [I(-1,-1)])).assessment == ND.DomainPossibleViolation
    @test only(ND.operator_domain_requirements(Val(:log), Any[1], [cert(-1,-1)])).assessment == ND.DomainProvenViolation
    a,b=cert(1,2),cert(3,4)
    for result in (ND._interval_add(a,b), ND._interval_scale(a,-2),
                   ND._interval_multiply(a,b), ND._interval_reciprocal(a),
                   ND._interval_integer_power(a,3))
        @test result.certified
    end
    unknown=I(1,2)
    for result in (ND._interval_add(unknown,b), ND._interval_scale(unknown,-2),
                   ND._interval_multiply(a,unknown), ND._interval_reciprocal(unknown),
                   ND._interval_integer_power(unknown,3))
        @test !result.certified
    end
    for head in (:exp,:log,:sqrt,:sin,:cosh)
        result=ND.operator_interval(Val(head),[cert(1,2)],Any[1])
        @test !result.certified
        @test !ND._interval_add(result,cert(0,0)).certified
    end
    for head in (:abs,:sign)
        @test ND.operator_interval(Val(head),[cert(-2,1)],Any[1]).certified
        @test !ND.operator_interval(Val(head),[I(-2,1)],Any[1]).certified
    end
    for head in (:min,:max)
        @test ND.operator_interval(Val(head),[a,b],Any[1,2]).certified
        @test !ND.operator_interval(Val(head),[a,unknown],Any[1,2]).certified
    end
    @test ND.operator_interval(Val(:abs),[cert(typemin(Int),typemin(Int))],Any[1]).lower == -big(typemin(Int))
    for valid in (true,false)
        view=ND._certified_interval(I(-1,-1,valid,true))
        @test view.valid && view.lower == -Inf && view.upper == Inf && !view.certified
    end
    for (head,expected) in ((:uncertified_test_range,false),(:certified_test_range,true))
        model=newmodel(); x=MOI.add_variable(model)
        f=MOI.ScalarNonlinearFunction(:log,Any[MOI.ScalarNonlinearFunction(head,Any[x])])
        MOI.add_constraint(model,f,MOI.EqualTo(0.0))
        report=ND.analyze_domains(model)
        @test !isempty(ND.findings(report; code=:proven_expression_domain_violation)) == expected
        @test !isempty(ND.findings(report; code=:possible_expression_domain_violation)) == !expected
    end
end

@testset "Approximate tightening does not replace certified declared bounds" begin
    model=newmodel(); x=MOI.add_variable(model)
    MOI.add_constraint(model,x,MOI.Interval(-1.0,1.0))
    MOI.add_constraint(model,MOI.ScalarNonlinearFunction(:exp,Any[x]),MOI.GreaterThan(exp(0.5)))
    raw=only(ND.domain_interval_data(model))
    @test raw["lower"] > 0 && !raw["certified"]
    safe=ND._domain_variable_intervals(ND.snapshot(model))[x]
    @test safe.certified && safe.lower == -1 && safe.upper == 1
    for (value,violates) in ((0.0,false),(2.0,true))
        point=ND.evaluation_point(model,[value])
        findings=ND._initialization_bound_findings(ND.snapshot(model),point)
        @test any(f -> f.code == :initialization_violates_variable_bounds,findings) == violates
    end
    # Exact affine bounds remain certified and usable by initialization checks.
    affine=newmodel(); y=MOI.add_variable(affine)
    MOI.add_constraint(affine,MOI.ScalarAffineFunction([MOI.ScalarAffineTerm(2.0,y)],0.0),MOI.LessThan(2.0))
    @test only(ND.domain_interval_data(affine))["certified"]
    @test !isempty(ND._initialization_bound_findings(ND.snapshot(affine), ND.evaluation_point(affine,[2.0])))

    # Exact reference inverses retain proofs without calling a rounded inverse.
    for (head, set, expected) in ((:log, MOI.GreaterThan(0.0), 1.0),
                                  (:sqrt, MOI.GreaterThan(2.0), 4.0),
                                  (:cbrt, MOI.GreaterThan(2.0), 8.0))
        reference=newmodel(); z=MOI.add_variable(reference)
        MOI.add_constraint(reference,MOI.ScalarNonlinearFunction(head,Any[z]),set)
        bound=ND._domain_variable_intervals(ND.snapshot(reference))[z]
        @test bound.certified && bound.lower == expected
    end
    for (head, upper) in ((:cosh,1.0),(:logcosh,0.0))
        reference=newmodel(); z=MOI.add_variable(reference)
        MOI.add_constraint(reference,MOI.ScalarNonlinearFunction(head,Any[z]),MOI.LessThan(upper))
        bound=ND._domain_variable_intervals(ND.snapshot(reference))[z]
        @test bound.certified && bound.lower == bound.upper == 0.0
    end
end

@testset "Uncertified nonlinear chains retain uncertainty at explicit points" begin
    model=newmodel(); x=MOI.add_variable(model)
    MOI.add_constraint(model,x,MOI.EqualTo(nextfloat(0.0)))
    diff=MOI.ScalarNonlinearFunction(:-,Any[MOI.ScalarNonlinearFunction(:exp,Any[x]),1.0])
    f=MOI.ScalarNonlinearFunction(:log,Any[diff])
    MOI.add_constraint(model,f,MOI.LessThan(0.0))
    MOI.add_constraint(model,MOI.ScalarNonlinearFunction(:sqrt,Any[diff]),MOI.LessThan(1.0))
    report=ND.analyze_domains(model)
    @test isempty(ND.findings(report; code=:proven_expression_domain_violation))
    @test !isempty(ND.findings(report; code=:possible_expression_domain_violation))
    point=ND.evaluation_point(model,[nextfloat(0.0)])
    numerical=ND.analyze_numerical(model,ND.evaluate_numerical(model,point))
    @test isempty(ND.findings(numerical; code=:operating_point_domain_violation))
    @test !isempty(ND.findings(numerical; code=:operating_point_domain_unknown))
    @test !isempty(ND.findings(numerical; code=:nonfinite_constraint_value))
    derivatives=ND.analyze_derivatives(model; point)
    @test isempty(ND.findings(derivatives; code=:operating_point_derivative_violation))
    unknowns=ND.findings(derivatives; code=:operating_point_derivative_domain_unknown)
    @test !isempty(unknowns)
    @test all(f -> f.basis != ND.MathematicalProof, unknowns)

    # A directly invalid certified argument must still produce a proof.
    direct=newmodel(); y=MOI.add_variable(direct)
    MOI.add_constraint(direct,y,MOI.EqualTo(-1.0))
    MOI.add_constraint(direct,MOI.ScalarNonlinearFunction(:log,Any[y]),MOI.LessThan(10.0))
    @test only(ND.findings(ND.analyze_domains(direct); code=:proven_expression_domain_violation)).basis == ND.MathematicalProof
end
end
