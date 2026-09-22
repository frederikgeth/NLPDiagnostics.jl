module BranchIdentityContractTests
using Test
import MathOptInterface as MOI
import NLPDiagnostics as ND
struct AdditionalRestriction <: MOI.AbstractScalarSet end
const identity_codes = Set((:nonzero_self_division_identity,
    :constant_nonzero_self_division_objective, :redundant_nonzero_self_division_constraint,
    :infeasible_nonzero_self_division_constraint, :sign_resolved_absolute_value,
    :bound_resolved_minmax_expression, :constant_bound_resolved_minmax_objective,
    :redundant_bound_resolved_minmax_constraint, :infeasible_bound_resolved_minmax_constraint))
function model_report(op; bound=MOI.GreaterThan(2.0), constant=1.0, target=MOI.EqualTo(1.0), extra=nothing, nested=false)
    m = MOI.Utilities.UniversalFallback(MOI.Utilities.Model{Float64}())
    x = MOI.add_variable(m)
    MOI.add_constraint(m, x, bound)
    isnothing(extra) || MOI.add_constraint(m, x, extra)
    args = op == :/ ? Any[x,x] : op == :abs ? Any[x] : Any[x,constant]
    f = MOI.ScalarNonlinearFunction(op, args)
    nested && (f = MOI.ScalarNonlinearFunction(:+, Any[f, 3.0]))
    MOI.add_constraint(m, f, target)
    MOI.set(m, MOI.ObjectiveSense(), MOI.MIN_SENSE)
    MOI.set(m, MOI.ObjectiveFunction{typeof(f)}(), f)
    return ND.analyze_static(m)
end
has(r, code) = any(f -> f.code == code, r.findings)
@testset "Branch identities abstain on malformed premises" begin
    for op in (:/, :abs, :min, :max), bad in
        (MOI.GreaterThan(Inf), MOI.LessThan(-Inf), MOI.GreaterThan(NaN),
         MOI.Interval(3.0,2.0), MOI.EqualTo(Inf))
        r = model_report(op; bound=bad)
        @test !any(f -> f.code in identity_codes, r.findings)
    end
    for op in (:/, :abs, :min, :max)
        r = model_report(op; extra=MOI.LessThan(-1.0))
        @test !any(f -> f.code in identity_codes, r.findings)
    end
    for op in (:min, :max), constant in (Inf, -Inf, NaN), nested in (false,true)
        r = model_report(op; constant, nested)
        @test !any(f -> f.code in identity_codes, r.findings)
    end
    for op in (:/, :min), target in (MOI.EqualTo(NaN), MOI.EqualTo(Inf), MOI.Interval(2.0,1.0))
        r = model_report(op; target)
        @test !has(r, :infeasible_nonzero_self_division_constraint)
        @test !has(r, :infeasible_bound_resolved_minmax_constraint)
    end
end
@testset "Valid branch identities retain exact controls" begin
    for bound in (MOI.GreaterThan(nextfloat(0.0)), MOI.LessThan(-nextfloat(0.0))), nested in (false,true)
        r = model_report(:/; bound, nested)
        @test has(r, :nonzero_self_division_identity)
        @test has(r, :constant_nonzero_self_division_objective) == !nested
    end
    for bound in (MOI.GreaterThan(0.0), MOI.Interval(-1.0,1.0))
        @test !has(model_report(:/; bound), :nonzero_self_division_identity)
    end
    for (op,bound) in ((:min,MOI.GreaterThan(2.0)), (:max,MOI.LessThan(0.0)))
        for extra in (nothing, MOI.Integer(), AdditionalRestriction(), op == :min ? MOI.LessThan(Inf) : MOI.GreaterThan(-Inf))
            r = model_report(op; bound, extra)
            @test has(r, :constant_bound_resolved_minmax_objective)
            @test has(r, :redundant_bound_resolved_minmax_constraint)
        end
        @test has(model_report(op; bound, target=MOI.EqualTo(2.0)), :infeasible_bound_resolved_minmax_constraint)
    end
    for op in (:min,:max)
        @test has(model_report(op; bound=MOI.EqualTo(1.0)), :bound_resolved_minmax_expression)
    end
    @test has(model_report(:/; target=MOI.EqualTo(2.0)), :infeasible_nonzero_self_division_constraint)
    @test has(model_report(:/; target=MOI.Interval(-Inf,Inf)), :redundant_nonzero_self_division_constraint)
    # Exact comparison must distinguish a rational just above a rounded endpoint.
    boundary = big(1)//3
    @test ND._identity_satisfies(boundary, MOI.LessThan(Float64(boundary))) === false
    @test ND._identity_satisfies(boundary, MOI.GreaterThan(Float64(boundary))) === true
end
end
