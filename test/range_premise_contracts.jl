module RangePremiseContractTests
using Test
import MathOptInterface as MOI
import NLPDiagnostics as ND
function analyze(op, target; bound=nothing, binary=false)
    m = MOI.Utilities.UniversalFallback(MOI.Utilities.Model{Float64}())
    xs = MOI.add_variables(m, binary ? 2 : 1)
    isnothing(bound) || MOI.add_constraint(m, xs[1], bound)
    args = op == :^ ? Any[xs[1],2] : Any[xs...]
    MOI.add_constraint(m, MOI.ScalarNonlinearFunction(op,args),target)
    return ND.analyze_static(m)
end
const range_codes = Set((:infeasible_sign_range_constraint, :sign_zero_implies_fixed_variable,
    :infeasible_nonpositive_exponential_constraint, :infeasible_negative_square_constraint,
    :infeasible_negative_square_root_constraint, :infeasible_unary_operator_range_constraint,
    :infeasible_reciprocal_trigonometric_range_constraint, :infeasible_reciprocal_hyperbolic_range_constraint,
    :infeasible_atan2_principal_range_constraint))
has(r,c) = any(f -> f.code == c,r.findings)
@testset "Direct range rules reject malformed scalar sets" begin
    for op in (:sign,:exp,:sqrt,:^,:sin,:sec,:coth,:acsc,:acsch),
        target in (MOI.EqualTo(NaN),MOI.EqualTo(Inf),MOI.LessThan(-Inf),
                   MOI.Interval(NaN,-2.0),MOI.Interval(2.0,-2.0))
        @test !any(f -> f.code in range_codes,analyze(op,target).findings)
    end
    @test !has(analyze(:atan,MOI.Interval(4.0,-4.0);binary=true),:infeasible_atan2_principal_range_constraint)
    for (op,level,code) in ((:sign,0.5,:infeasible_sign_range_constraint),
        (:exp,0.0,:infeasible_nonpositive_exponential_constraint),
        (:sqrt,-1.0,:infeasible_negative_square_root_constraint),
        (:^,-1.0,:infeasible_negative_square_constraint),
        (:sin,2.0,:infeasible_unary_operator_range_constraint),
        (:sec,0.5,:infeasible_reciprocal_trigonometric_range_constraint),
        (:coth,1.0,:infeasible_reciprocal_hyperbolic_range_constraint))
        @test has(analyze(op,MOI.EqualTo(level)),code)
    end
    for level in (-1.0,0.0,1.0)
        @test !has(analyze(:sign,MOI.EqualTo(level)),:infeasible_sign_range_constraint)
    end
    @test has(analyze(:sign,MOI.EqualTo(0.0)),:sign_zero_implies_fixed_variable)
    @test !has(analyze(:sign,MOI.Interval(-Inf,Inf)),:infeasible_sign_range_constraint)
end
@testset "Endpoint contradictions require valid bound premises" begin
    for (op,level,code) in ((:acos,0.0,:inconsistent_inverse_trigonometric_endpoint_variable_bound),
        (:cosh,1.0,:inconsistent_hyperbolic_endpoint_variable_bound),
        (:exp,1.0,:inconsistent_elementary_reference_level_variable_bound),
        (:atan,0.0,:inconsistent_atan2_axis_angle_variable_bound))
        for bound in (MOI.GreaterThan(Inf),MOI.LessThan(-Inf),MOI.Interval(3.0,2.0))
            @test !has(analyze(op,MOI.EqualTo(level);bound,binary=op==:atan),code)
        end
        @test has(analyze(op,MOI.EqualTo(level);bound=MOI.GreaterThan(2.0),binary=op==:atan),code)
    end
end
end
