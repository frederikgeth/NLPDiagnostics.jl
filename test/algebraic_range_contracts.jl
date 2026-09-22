module AlgebraicRangeContractTests
using Test
import MathOptInterface as MOI
import NLPDiagnostics as ND
function report(operator, level; binary=false)
    m = MOI.Utilities.UniversalFallback(MOI.Utilities.Model{Float64}())
    xs = MOI.add_variables(m, binary ? 2 : 1)
    MOI.add_constraint(m, MOI.ScalarNonlinearFunction(operator, Any[xs...]), MOI.EqualTo(level))
    return ND.analyze_static(m)
end
has(r, code) = any(f -> f.code == code, r.findings)
@testset "Rounded transcendental references are not exact identities" begin
    for (op, level) in ((:asin, pi/2), (:asin, -pi/2), (:acos, Float64(pi)),
                        (:asec, Float64(pi)), (:acsc, pi/2), (:acsc, -pi/2))
        r = report(op, level)
        @test !has(r, :inverse_trigonometric_endpoint_implies_fixed_variable)
        @test !has(r, :inconsistent_inverse_trigonometric_endpoint_variable_bound)
    end
    for op in (:softplus, :log1pexp, :log1exp, :log1mexp)
        r = report(op, op == :log1mexp ? -log(2.0) : log(2.0))
        @test !has(r, :elementary_reference_level_implies_fixed_variable)
    end
    for level in (Float64(pi), pi/2, -pi/2)
        @test !has(report(:atan, level; binary=true), :atan2_axis_angle_implies_fixed_variable)
    end
    @test has(report(:atan, 0.0; binary=true), :atan2_axis_angle_implies_fixed_variable)
    @test has(report(:acos, 0.0), :inverse_trigonometric_endpoint_implies_fixed_variable)
    @test has(report(:asind, 90.0), :inverse_trigonometric_endpoint_implies_fixed_variable)
    @test has(report(:exp, 1.0), :elementary_reference_level_implies_fixed_variable)
end
@testset "Radian output bounds use rational outer enclosures" begin
    for level in (pi/2, -pi/2)
        @test !has(report(:atan, level), :infeasible_unary_operator_range_constraint)
    end
    for level in (Float64(pi), -Float64(pi))
        @test !has(report(:atan, level; binary=true), :infeasible_atan2_principal_range_constraint)
    end
    for (op, level) in ((:atan, 2.0), (:asin, -2.0), (:acos, 4.0), (:asec, 4.0), (:acsc, 2.0))
        r = report(op, level)
        f = only(filter(f -> f.code == :infeasible_unary_operator_range_constraint, r.findings))
        @test f.basis == ND.MathematicalProof
        @test haskey(Dict(f.evidence[1].details), "range_enclosure")
    end
    @test has(report(:atan, 4.0; binary=true), :infeasible_atan2_principal_range_constraint)
end
@testset "Square roots remain symbolic unless exactly representable" begin
    for level in (2.0, 4.0, Inf)
        m = MOI.Utilities.UniversalFallback(MOI.Utilities.Model{Float64}())
        x = MOI.add_variable(m)
        MOI.add_constraint(m, x, MOI.GreaterThan(0.0))
        MOI.add_constraint(m, MOI.ScalarNonlinearFunction(:^, Any[x, 2]), MOI.EqualTo(level))
        r = ND.analyze_static(m)
        fs = filter(f -> f.code == :sign_resolved_square_level_set, r.findings)
        if isinf(level)
            @test isempty(fs)
        else
            d = Dict(only(fs).evidence[1].details)
            @test haskey(d, "implied_value") == (level == 4.0)
            @test d["root_enclosure_certified"] == "true"
            lo, hi = ND._exact_sqrt_bounds(Rational{BigInt}(level))
            @test lo^2 <= level <= hi^2
            @test (lo == hi) == (level == 4.0)
        end
    end
end

end
