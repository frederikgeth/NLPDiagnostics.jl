module BoundInputContractTests
using Test
import MathOptInterface as MOI
import NLPDiagnostics as ND
const x = MOI.VariableIndex(1)
function snap(sets...)
    rows = [ND.ConstraintRecord(MOI.ConstraintIndex{MOI.VariableIndex,typeof(s)}(i),x,s,nothing)
            for (i,s) in enumerate(sets)]
    ND.ModelSnapshot([ND.VariableRecord(x,nothing)],rows,nothing,nothing,String[])
end
has(r,c)=any(f->f.code==c,r.findings)
const false_codes=(:fixed_variable,:dominated_variable_bound,:empty_discrete_variable_domain,
                   :nonintegral_discrete_fixed_value,:inconsistent_variable_bounds)
@testset "Invalid endpoints do not become scalar or discrete proofs" begin
    for bad in (MOI.EqualTo(Inf),MOI.EqualTo(-Inf),MOI.GreaterThan(Inf),
                MOI.LessThan(-Inf),MOI.Parameter(Inf),MOI.GreaterThan(NaN),
                MOI.Interval(NaN,2.0)), discrete in (nothing,MOI.Integer(),MOI.ZeroOne())
        m=isnothing(discrete) ? snap(bad) : snap(bad,discrete)
        r=ND.analyze_static(m)
        @test only(ND.variable_roles(m))==ND.InvalidVariableDomain
        @test has(r,:invalid_variable_bound) || has(r,:nan_variable_bound)
        @test all(c->!has(r,c),false_codes)
    end
    # A valid stronger bound must not hide unsupported endpoint premises.
    for sets in ((MOI.GreaterThan(pi),MOI.GreaterThan(4.0)),
                 (MOI.GreaterThan(NaN),MOI.GreaterThan(4.0)))
        m=snap(sets...);r=ND.analyze_static(m)
        @test only(ND.variable_roles(m))==ND.InvalidVariableDomain
        @test !has(r,:dominated_variable_bound)
    end
end
@testset "Finite bounds and exact discrete witnesses remain supported" begin
    for discrete in (MOI.Integer(),MOI.ZeroOne())
        r=ND.analyze_static(snap(discrete,MOI.Interval(0.1,0.9)))
        @test has(r,:empty_discrete_variable_domain)
        @test has(ND.analyze_static(snap(discrete,MOI.EqualTo(0.5))),:nonintegral_discrete_fixed_value)
        @test !has(ND.analyze_static(snap(discrete,MOI.Interval(-Inf,Inf))),:empty_discrete_variable_domain)
    end
    for set in (MOI.GreaterThan(-Inf),MOI.LessThan(Inf),MOI.Interval(-Inf,Inf))
        m=snap(set)
        @test only(ND.variable_roles(m))==ND.FreeVariable
        @test !has(ND.analyze_static(m),:invalid_variable_bound)
    end
    @test has(ND.analyze_static(snap(MOI.Interval(2.0,1.0))),:inconsistent_variable_bounds)
    @test only(ND.variable_roles(snap(MOI.Interval(2.0,1.0))))==ND.InfeasibleVariableDomain
    @test has(ND.analyze_static(snap(MOI.EqualTo(2.0))),:fixed_variable)
    @test has(ND.analyze_static(snap(MOI.GreaterThan(1.0),MOI.GreaterThan(2.0))),:dominated_variable_bound)
    @test has(ND.analyze_static(snap(MOI.GreaterThan(2.0),MOI.GreaterThan(2.0))),:multiple_variable_bounds)
    @test !has(ND.analyze_static(snap(MOI.GreaterThan(2.0),MOI.GreaterThan(2.0))),:dominated_variable_bound)
    n=big(10)^100
    for (lo,hi,empty) in ((n+1//3,n+2//3,true),(n-1//3,n+1//3,false),
                          (-n-2//3,-n-1//3,true),(-n-1//3,-n+1//3,false))
        r=ND.analyze_static(snap(MOI.Integer(),MOI.Interval(lo,hi)))
        @test has(r,:empty_discrete_variable_domain)==empty
        if !empty
            witness=lo>0 ? n : -n
            @test lo <= witness <= hi
        end
    end
    # Mixed numeric evidence must retain the exact rational endpoint.
    r=ND.analyze_static(snap(MOI.GreaterThan(big(1)//3),MOI.LessThan(0.0)))
    f=only(filter(f->f.code==:inconsistent_variable_bounds,r.findings))
    @test Dict(f.evidence[1].details)["effective_lower"]=="1//3"
end
end
