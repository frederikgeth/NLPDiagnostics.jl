module ObjectiveRayContractTests
using Test
import MathOptInterface as MOI
import NLPDiagnostics as ND
struct UnknownDomain <: MOI.AbstractScalarSet end
newmodel() = MOI.Utilities.UniversalFallback(MOI.Utilities.Model{Float64}())
function objective_model(;quadratic=false, coefficient=-1.0, constant=0.0, sense=MOI.MIN_SENSE)
    m=newmodel(); x=MOI.add_variable(m)
    f=quadratic ? MOI.ScalarQuadraticFunction([MOI.ScalarQuadraticTerm(coefficient,x,x)],MOI.ScalarAffineTerm{Float64}[],constant) :
        MOI.ScalarAffineFunction([MOI.ScalarAffineTerm(coefficient,x)],constant)
    MOI.set(m,MOI.ObjectiveSense(),sense)
    MOI.set(m,MOI.ObjectiveFunction{typeof(f)}(),f)
    return m,x
end
function rays(m)
    report=ND.analyze_static(m)
    return [f for f in report.findings if f.code in (:unconstrained_affine_objective_ray,:unconstrained_quadratic_objective_ray)]
end
@testset "Objective-ray proofs require finite data and visible domains" begin
    for quadratic in (false,true), bad in (NaN,Inf,-Inf)
        m,_=objective_model(;quadratic,coefficient=bad)
        @test isempty(rays(m))
        m,_=objective_model(;quadratic,constant=bad)
        @test isempty(rays(m))
    end
    for quadratic in (false,true), set in (MOI.Semicontinuous(1.0,2.0),MOI.Semiinteger(1.0,2.0),UnknownDomain(),MOI.Interval(-1.0,1.0),MOI.ZeroOne())
        m,x=objective_model(;quadratic)
        MOI.add_constraint(m,x,set)
        @test isempty(rays(m))
    end
    for quadratic in (false,true), set in (MOI.GreaterThan(NaN),MOI.GreaterThan(Inf),MOI.LessThan(-Inf),MOI.Interval(2.0,1.0))
        m,x=objective_model(;quadratic)
        MOI.add_constraint(m,x,set)
        @test isempty(rays(m))
    end
    m,_=objective_model()
    captured=ND.snapshot(m)
    opaque=ND.ModelSnapshot(captured.variables,captured.constraints,captured.objective,captured.model_name,["opaque constraint callback"])
    @test isnothing(ND._objective_ray_context(opaque))
    @test isempty(rays(opaque))
    m,_=objective_model(;sense=MOI.FEASIBILITY_SENSE)
    @test isempty(rays(m))
end

@testset "Certified rays retain continuous and integer unbounded sequences" begin
    for quadratic in (false,true), integer in (false,true), sense in (MOI.MIN_SENSE,MOI.MAX_SENSE)
        coefficient=sense == MOI.MIN_SENSE ? -2.0 : 2.0
        m,x=objective_model(;quadratic,coefficient,sense)
        integer && MOI.add_constraint(m,x,MOI.Integer())
        # Explicit infinite endpoints must behave like absent scalar bounds.
        MOI.add_constraint(m,x,MOI.Interval(-Inf,Inf))
        finding=only(rays(m)); data=Dict(finding.evidence[1].details)
        @test finding.basis == ND.MathematicalProof
        @test data["finite_polynomial_certified"] == "true"
        @test data["domain_path"] == (integer ? "integer_sequence" : "continuous_ray")
        @test data["feasibility_scope"] == "conditional_on_remaining_model_feasibility"
        f=ND.snapshot(m).objective.function_value
        values=[ND._exact_fixed_polynomial_value(f,Dict(x=>big(t)//1)) for t in (1,10,100)]
        @test sense == MOI.MIN_SENSE ? all(diff(values) .< 0) : all(diff(values) .> 0)
    end
    # Unknown domains for another variable do not prohibit a genuinely
    # disconnected direction, conditional on those other restrictions being feasible.
    m,x=objective_model(); y=MOI.add_variable(m)
    MOI.add_constraint(m,y,UnknownDomain())
    @test length(rays(m)) == 1
    # But a restrictive row involving the candidate direction does prohibit it.
    MOI.add_constraint(m,MOI.ScalarAffineFunction([MOI.ScalarAffineTerm(1.0,x),MOI.ScalarAffineTerm(1.0,y)],0.0),MOI.EqualTo(0.0))
    @test isempty(rays(m))
end

@testset "Quadratic ray evidence preserves the exact MOI half coefficient" begin
    tiny=nextfloat(0.0)
    m,_=objective_model(;quadratic=true,coefficient=-tiny)
    data=Dict(only(rays(m)).evidence[1].details)
    @test data["polynomial_coefficient"] == string(-Rational{BigInt}(tiny)/2)
    @test data["polynomial_coefficient"] != "-0.0"
    # Nonfinite cross terms invalidate a proof even if the diagonal is finite.
    m,x=objective_model(;quadratic=true); y=MOI.add_variable(m)
    f=MOI.ScalarQuadraticFunction([MOI.ScalarQuadraticTerm(-2.0,x,x),MOI.ScalarQuadraticTerm(Inf,x,y)],MOI.ScalarAffineTerm{Float64}[],0.0)
    MOI.set(m,MOI.ObjectiveFunction{typeof(f)}(),f)
    @test isempty(rays(m))
end
end
