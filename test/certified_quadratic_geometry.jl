module CertifiedQuadraticGeometryTests
using Test
import MathOptInterface as MOI
import NLPDiagnostics as ND
const QT = MOI.ScalarQuadraticTerm
const AT = MOI.ScalarAffineTerm
const QF = MOI.ScalarQuadraticFunction
const x,y = MOI.VariableIndex(1), MOI.VariableIndex(2)
exact(v) = Rational{BigInt}(v)
newmodel() = MOI.Utilities.UniversalFallback(MOI.Utilities.Model{Float64}())
quad(q, b, c) = QF([QT(q[1],x,x),QT(q[2],y,y)], [AT(b[1],x),AT(b[2],y)],c)
nl(head, args...) = MOI.ScalarNonlinearFunction(head, Any[args...])

@testset "Exact completed squares preserve feasible positive levels" begin
    # x^2 + y^2 + 2e8*x + 2*y + 1e16 = (x+1e8)^2 + (y+1)^2 - 1.
    # Float64 completion rounds the minimum to zero and incorrectly fixes y=-1.
    f = quad([2.0,2.0],[2e8,2.0],1e16)
    minimum = ND._positive_diagonal_quadratic_minimum(f)
    @test minimum.minimum_value == -1
    @test minimum.centers == [-100000000,-1]
    equality = ND._positive_diagonal_quadratic_equality(f,MOI.EqualTo(0.0))
    @test equality.effective_level == 1
    @test equality.axis_squared == [1,1]
    @test ND._exact_fixed_polynomial_value(f,Dict(x=>exact(-1e8),y=>exact(0))) == 0
    for set in (MOI.EqualTo(0.0), MOI.LessThan(0.0))
        model = newmodel(); MOI.add_variables(model,2)
        MOI.add_constraint(model,f,set)
        MOI.add_constraint(model,y,MOI.GreaterThan(0.0))
        report = ND.analyze_static(model)
        for code in (:zero_radius_circular_constraint,
                     :minimum_level_diagonal_quadratic_constraint,
                     :inconsistent_zero_radius_circular_variable_bound,
                     :inconsistent_diagonal_quadratic_minimum_variable_bound)
            @test isempty(ND.findings(report;code))
        end
    end

    # Equivalent recognized nonlinear polynomial also requires exact sums.
    g = nl(:+,nl(:^,x,2),nl(:^,y,2),nl(:*,2e8,x),nl(:*,2.0,y),1e16)
    nonlinear = ND._nonlinear_positive_diagonal_minimum(g)
    @test nonlinear.minimum_value == -1
    @test nonlinear.centers == minimum.centers
    @test ND._nonlinear_positive_diagonal_equality(g,MOI.EqualTo(0.0)).axis_squared == [1,1]
end

@testset "Geometry completion withstands extreme scales and coefficient order" begin
    huge, tiny = floatmax(Float64), nextfloat(0.0)
    f = quad([huge,huge],[huge,0.0],0.0)
    minimum = ND._positive_diagonal_quadratic_minimum(f)
    @test minimum.minimum_value == -exact(huge)/2
    @test minimum.centers == [-1,0]
    @test all(isfinite,minimum.centers)
    small = ND._positive_diagonal_quadratic_equality(quad([huge,huge],[0.0,0.0],0.0),MOI.EqualTo(tiny))
    @test all(r -> r == 2exact(tiny)/exact(huge) && r > 0, small.axis_squared)

    terms = [AT(1e16,x),AT(1.0,x),AT(-1e16,x)]
    for order in ([1,2,3],[3,2,1],[1,3,2])
        f = QF([QT(2.0,x,x),QT(2.0,y,y)],terms[order],0.0)
        result = ND._positive_diagonal_quadratic_minimum(f)
        @test result.centers == [-1//2,0]
        @test result.minimum_value == -1//4
        # Independent polynomial substitution at a rational point verifies the
        # completed-square identity, including MOI's diagonal factor of 1/2.
        point = Dict(x=>big(3)//7,y=>big(-5)//11)
        direct = ND._exact_fixed_polynomial_value(f,point)
        completed = result.minimum_value + sum(c*(point[v]-a)^2/2
            for (c,v,a) in zip(result.coefficients,result.variables,result.centers))
        @test direct == completed
    end
    nonlinear = nl(:+,nl(:*,huge,tiny,nl(:^,x,2)),nl(:^,y,2))
    result = ND._nonlinear_positive_diagonal_minimum(nonlinear)
    @test result.coefficients[1] == exact(huge)*exact(tiny)
    overflow_product = nl(:+,nl(:*,huge,huge,nl(:^,x,2)),nl(:^,y,2))
    @test ND._nonlinear_positive_diagonal_minimum(overflow_product).coefficients[1] == exact(huge)^2

    for bad in (Inf,-Inf,NaN)
        @test isnothing(ND._positive_diagonal_quadratic_minimum(quad([bad,2.0],[0.0,0.0],0.0)))
        @test isnothing(ND._positive_diagonal_quadratic_minimum(quad([2.0,2.0],[bad,0.0],0.0)))
        @test isnothing(ND._positive_diagonal_quadratic_minimum(quad([2.0,2.0],[0.0,0.0],bad)))
        @test isnothing(ND._nonlinear_positive_diagonal_minimum(nl(:+,nl(:*,bad,nl(:^,x,2)),nl(:^,y,2))))
        @test isnothing(ND._positive_diagonal_quadratic_equality(quad([2.0,2.0],[0.0,0.0],0.0),MOI.EqualTo(bad)))
    end
    cross = QF([QT(2.0,x,x),QT(2.0,y,y),QT(1.0,x,y)],AT{Float64}[],0.0)
    @test isnothing(ND._positive_diagonal_quadratic_minimum(cross))
    @test isnothing(ND._nonlinear_positive_diagonal_minimum(nl(:+,nl(:sin,x),nl(:^,y,2))))
end

@testset "Coordinate enclosures and exclusions use integer arithmetic" begin
    values = [big(0)//1, big(1)//9, big(2)//1, big(7)//13,
              exact(nextfloat(0.0))/exact(floatmax(Float64)),
              exact(floatmax(Float64))^2, (big(1)<<2000)//3,
              big(3)//(big(1)<<2000)]
    for value in values
        lower, upper = ND._exact_sqrt_bounds(value)
        @test lower >= 0
        @test lower^2 <= value <= upper^2
        @test lower == upper || (upper-lower)/upper <= big(1)//(big(1)<<127)
        for center in (big(0)//1, big(1)//3, (big(1)<<1000)//1)
            lo,hi = exact.(ND._quadratic_coordinate_bounds(center,value))
            @test lo <= center <= hi
            @test (center-lo)^2 >= value && (hi-center)^2 >= value
        end
    end
    @test ND._exact_sqrt_bounds(big(4)//9) == (big(2)//3,big(2)//3)
    @test ND._quadratic_radius_estimate(exact(floatmax(Float64))^2) == floatmax(Float64)
    @test ND._quadratic_radius_estimate(exact(nextfloat(0.0))^2) == nextfloat(0.0)
    @test_throws DomainError ND._exact_sqrt_bounds(big(-1)//1)

    # A bound inside the outward approximation may still be outside the exact
    # radius: decide from its squared distance, not from rounded endpoints.
    lo,hi = ND._exact_sqrt_bounds(big(2)//1)
    @test ND._quadratic_coordinate_conflicts((lower=lo,upper=nothing),0,2) == (false,false)
    @test ND._quadratic_coordinate_conflicts((lower=hi,upper=nothing),0,2) == (true,false)
    @test ND._quadratic_coordinate_conflicts((lower=nothing,upper=-hi),0,2) == (false,true)
    @test ND._quadratic_coordinate_conflicts((lower=1,upper=1),0,1) == (false,false)
end

@testset "Geometry proofs retain genuine impossible and zero-level controls" begin
    for (q, code) in (([2.0,2.0],:infeasible_negative_radius_squared_circular_constraint),
                      ([2.0,4.0],:infeasible_negative_level_diagonal_quadratic_constraint))
        model=newmodel(); MOI.add_variables(model,2)
        MOI.add_constraint(model,quad(q,[0.0,0.0],0.0),MOI.EqualTo(-1.0))
        @test only(ND.findings(ND.analyze_static(model);code)).basis == ND.MathematicalProof
    end
    for (set, code) in ((MOI.EqualTo(0.0),:zero_radius_circular_constraint),
                        (MOI.LessThan(0.0),:minimum_level_diagonal_quadratic_constraint))
        model=newmodel(); MOI.add_variables(model,2)
        MOI.add_constraint(model,quad([2.0,2.0],[0.0,0.0],0.0),set)
        @test only(ND.findings(ND.analyze_static(model);code)).basis == ND.MathematicalProof
    end
    for (q, code) in (([2.0,2.0],:inconsistent_circular_implied_variable_bound),
                      ([2.0,4.0],:inconsistent_ellipsoidal_implied_variable_bound))
        model=newmodel(); MOI.add_variables(model,2)
        MOI.add_constraint(model,quad(q,[0.0,0.0],0.0),MOI.EqualTo(2.0))
        MOI.add_constraint(model,x,MOI.GreaterThan(2.0))
        finding=only(ND.findings(ND.analyze_static(model);code))
        @test finding.basis == ND.MathematicalProof
        @test Dict(finding.evidence[1].details)["interval_certified"] == "true"
    end
    # Mixed floating bounds must not promote exact center evidence to BigFloat.
    model = newmodel(); MOI.add_variables(model,2)
    f = quad([6.0,6.0],[-2.0,0.0],0.0)
    ci = MOI.add_constraint(model,f,MOI.LessThan(0.0))
    MOI.add_constraint(model,x,MOI.GreaterThan(0.5))
    captured = ND.snapshot(model)
    # Preserve an exact rational row level at the snapshot boundary, independently
    # of what numeric types an upstream MOI backend accepts for its row sets.
    snapshot = ND.ModelSnapshot(captured.variables,
        [r.index == ci ? ND.ConstraintRecord(ci,r.function_value,MOI.LessThan(big(-1)//3),r.name) : r
         for r in captured.constraints], captured.objective, captured.model_name, captured.opaque_sources)
    report = ND.DiagnosticReport()
    ND._analyze_diagonal_quadratic_upper_bounds!(report,snapshot)
    conflict = only(ND.findings(report;code=:inconsistent_diagonal_quadratic_minimum_variable_bound))
    @test Dict(conflict.evidence[1].details)["implied_value"] == "1//3"
    @test Dict(conflict.evidence[1].details)["minimum_value"] == "-1//3"

end
end
