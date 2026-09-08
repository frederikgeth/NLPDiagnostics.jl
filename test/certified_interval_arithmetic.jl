module CertifiedIntervalArithmeticTests

using Test
import MathOptInterface as MOI
import NLPDiagnostics as ND

const I = ND.IntervalEnclosure
exact(x) = Rational{BigInt}(x)
contains(interval, x) = interval.valid && interval.lower <= x <= interval.upper
newmodel() = MOI.Utilities.UniversalFallback(MOI.Utilities.Model{Float64}())

@testset "Exact interval kernel contains represented-data oracles" begin
    # Independent rational references, including cancellation, subnormals,
    # overflow-sized results, and machine-integer overflow boundaries.
    values = Real[0.0, -0.0, 1.0, -3.0, 0.1, 1e16, nextfloat(0.0),
        floatmax(Float64), -floatmax(Float64), typemax(Int), typemin(Int), Float32(0.1)]
    for a in values, b in values
        x, y = I(a, a), I(b, b)
        @test contains(ND._interval_add(x, y), exact(a) + exact(b))
        @test contains(ND._interval_multiply(x, y), exact(a) * exact(b))
        @test contains(ND._interval_scale(x, b), exact(a) * exact(b))
    end
    for a in values
        iszero(a) && continue
        @test contains(ND._interval_reciprocal(I(a, a)), inv(exact(a)))
        for n in (-3, -2, -1, 0, 1, 2, 3, 8)
            @test contains(ND._interval_integer_power(I(a, a), n), exact(a)^n)
        end
    end
    for (a, b) in ((-3.0, 2.0), (0.1, 1.0), (-2.0, -0.1))
        x = I(a, b)
        samples = [exact(a), (exact(a) + exact(b)) / 2, exact(b)]
        for n in (2, 3, 4), sample in samples
            @test contains(ND._interval_integer_power(x, n), sample^n)
        end
        for (c, d) in ((-5.0, 3.0), (0.1, 2.0))
            result = ND._interval_multiply(x, I(c, d))
            for left in samples, right in (exact(c), exact(d))
                @test contains(result, left * right)
            end
        end
    end
    cancellation = ND._interval_add(I(1e16, 1e16), I(1, 1))
    @test cancellation.lower == cancellation.upper == big(10)^16 + 1
    @test ND._interval_add(cancellation, I(-1e16, -1e16)).lower == 1

    # Unbounded endpoints are limits. 0*Inf must not fabricate NaN bounds.
    @test ND._interval_multiply(I(0, 0), I(-Inf, Inf)).lower == 0
    product = ND._interval_multiply(I(-Inf, 0), I(0, Inf))
    @test product.lower == -Inf && product.upper == 0
    reciprocal = ND._interval_reciprocal(I(2, Inf))
    @test reciprocal.lower == 0 && reciprocal.upper == 0.5
    for result in (ND._interval_reciprocal(I(-1, 1)),
                   ND._interval_add(I(NaN, NaN), I(0, 0)),
                   ND._interval_scale(I(1, 1), Inf),
                   ND._interval_add(I(Inf, Inf), I(0, 0)),
                   ND._interval_add(I(pi, pi), I(0, 0)),
                   ND._interval_integer_power(I(2, 2), typemin(Int)),
                   ND._interval_integer_power(I(2, 2), 1025))
        @test result.lower == -Inf && result.upper == Inf && !result.informative
    end
    @test !ND._interval_add(ND._invalid_interval(), I(0, 0)).valid
end

@testset "Affine propagation preserves feasible cancellation" begin
    for order in ([1, 2, 3], [3, 2, 1], [1, 3, 2])
        model = newmodel()
        x, y = MOI.add_variables(model, 2)
        MOI.add_constraint(model, x, MOI.EqualTo(1.0))
        MOI.add_constraint(model, y, MOI.EqualTo(1.0))
        terms = [MOI.ScalarAffineTerm(1e16, x), MOI.ScalarAffineTerm(1.0, x),
            MOI.ScalarAffineTerm(-1e16, x)]
        f = MOI.ScalarAffineFunction(vcat(terms[order], [MOI.ScalarAffineTerm(1.0, y)]), 0.0)
        ci = MOI.add_constraint(model, f, MOI.EqualTo(2.0))
        # MOI.Utilities.Model itself rounds duplicate terms on insertion.
        # Exercise our IR contract with the original finite coefficient data;
        # an ingestion adapter cannot recover terms already lost upstream.
        captured = ND.snapshot(model)
        model = ND.ModelSnapshot(captured.variables,
            [row.index == ci ? ND.ConstraintRecord(ci, deepcopy(f), row.set_value, row.name) : row
             for row in captured.constraints], captured.objective,
            captured.model_name, captured.opaque_sources)
        @test ND._domain_affine_coefficients(f)[x] == 1
        @test all(row["valid"] && row["lower"] == row["upper"] == 1
            for row in ND.domain_interval_data(model))
        for (cache, targets) in ((false, false), (true, false), (true, true))
            report = ND.analyze_static(model; cache_affine_coefficients=cache,
                cache_affine_target_terms=targets)
            @test isempty(ND.findings(report; code=:inconsistent_affine_interval_propagation))
        end
    end

    model = newmodel()
    x, y = MOI.add_variables(model, 2)
    MOI.add_constraint(model, x, MOI.EqualTo(1.0))
    MOI.add_constraint(model, y, MOI.EqualTo(1.0))
    f = MOI.ScalarAffineFunction([MOI.ScalarAffineTerm(1e16, x),
        MOI.ScalarAffineTerm(-1e16, y)], 1.0)
    ci = MOI.add_constraint(model, f, MOI.EqualTo(1.0))
    @test all(row["valid"] for row in ND.domain_interval_data(model))
    @test isempty(ND.findings(ND.analyze_static(model); code=:inconsistent_affine_interval_propagation))
    MOI.set(model, MOI.ConstraintSet(), ci, MOI.EqualTo(2.0))
    @test !isempty(ND.findings(ND.analyze_static(model); code=:inconsistent_affine_interval_propagation))

    # Isolation must retain an exact nonrepresentable quotient, including 1/3.
    one = MOI.ScalarAffineFunction([MOI.ScalarAffineTerm(3.0, x)], 0.0)
    _, lower, upper = ND._single_variable_affine_interval(one, MOI.EqualTo(1.0))
    @test lower == upper == big(1)//big(3)
    @test ND._exact_affine_bound(1.0, 1e16, 1.0) == 1 - big(10)^16
    for c in (Inf, -Inf, NaN)
        bad = MOI.ScalarAffineFunction([MOI.ScalarAffineTerm(c, x),
            MOI.ScalarAffineTerm(1.0, y)], 0.0)
        @test ND._domain_affine_coefficients(bad) === nothing
        @test ND._combined_affine_coefficients(bad) === nothing
    end
end

@testset "Polynomial enclosures and numerical domain errors remain distinct" begin
    model = newmodel()
    x = MOI.add_variable(model)
    MOI.add_constraint(model, x, MOI.EqualTo(1.0))
    cancellation = MOI.ScalarNonlinearFunction(:-, Any[
        MOI.ScalarNonlinearFunction(:+, Any[1e16, x]), 1e16])
    argument = MOI.ScalarNonlinearFunction(:-, Any[cancellation, 0.5])
    root = MOI.ScalarNonlinearFunction(:sqrt, Any[argument])
    MOI.add_constraint(model, root, MOI.GreaterThan(0.0))
    @test isempty(ND.findings(ND.analyze_domains(model); code=:proven_expression_domain_violation))
    finding = only(ND.findings(ND.analyze_static(model); code=:fixed_expression_domain_violation))
    @test finding.basis == ND.NumericalObservation
    @test finding.domain == ND.NumericalIssue

    # The MOI diagonal factor 1/2 must not underflow before interval evaluation.
    tiny = nextfloat(0.0)
    quadratic = MOI.ScalarQuadraticFunction([MOI.ScalarQuadraticTerm(tiny, x, x)],
        MOI.ScalarAffineTerm{Float64}[], 0.0)
    enclosure = ND._interval_quadratic(quadratic, Dict(x => I(1, 1)))
    @test contains(enclosure, exact(tiny) / 2)
    @test enclosure.lower > 0
end

end # module
