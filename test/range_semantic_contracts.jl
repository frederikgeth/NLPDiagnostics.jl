module RangeSemanticContractTests
using Test
import MathOptInterface as MOI
import NLPDiagnostics as ND
struct UnknownScalarSet <: MOI.AbstractScalarSet end
const x,y=MOI.VariableIndex(1),MOI.VariableIndex(2)
function report(op,set; bounds=Any[], binary=false, nested=false)
    args=op==:^ ? Any[x,2] : binary ? Any[x,y] : Any[x]
    nested && (args[1]=MOI.ScalarNonlinearFunction(:+,Any[x,1]))
    f=MOI.ScalarNonlinearFunction(op,args)
    row(v,s,i)=ND.ConstraintRecord(MOI.ConstraintIndex{typeof(v),typeof(s)}(i),v,s,nothing)
    rows=ND.ConstraintRecord[row(f,set,1)]
    for (v,s) in bounds;push!(rows,row(v,s,length(rows)+1));end
    m=ND.ModelSnapshot([ND.VariableRecord(x,nothing),ND.VariableRecord(y,nothing)],rows,nothing,nothing,String[])
    ND.analyze_static(m)
end
has(r,c)=any(f->f.code==c,r.findings)
const unary=:infeasible_unary_operator_range_constraint
const trig=:infeasible_reciprocal_trigonometric_range_constraint
const hyper=:infeasible_reciprocal_hyperbolic_range_constraint
# Independently specified attainable and excluded outputs; mathematical
# justifications and exact/symbolic preimages are in docs/range_semantic_audit.md.
const cases=[
 (:exp,1.0,0.0,:infeasible_nonpositive_exponential_constraint),
 (:exp2,1.0,0.0,unary),(:softplus,1.0,0.0,unary),(:log1pexp,1.0,0.0,unary),(:log1exp,1.0,0.0,unary),
 (:expm1,0.0,-1.0,unary),(:log1mexp,-1.0,0.0,unary),(:logistic,0.5,1.0,unary),
 (:tanh,0.0,1.0,unary),(:sech,1.0,0.0,unary),(:abs,0.0,-1.0,unary),
 (:sqrt,0.0,-1.0,:infeasible_negative_square_root_constraint),(:^,0.0,-1.0,:infeasible_negative_square_constraint),
 (:acosh,0.0,-1.0,unary),(:asech,0.0,-1.0,unary),(:logcosh,0.0,-1.0,unary),(:cosh,1.0,0.0,unary),
 (:sin,1.0,2.0,unary),(:cos,1.0,2.0,unary),(:sind,1.0,2.0,unary),(:cosd,1.0,2.0,unary),
 (:asin,0.0,2.0,unary),(:acos,0.0,4.0,unary),(:asec,0.0,4.0,unary),(:acsc,1.0,2.0,unary),(:atan,0.0,2.0,unary),
 (:asind,90.0,91.0,unary),(:acosd,180.0,181.0,unary),(:asecd,180.0,181.0,unary),
 (:acscd,90.0,91.0,unary),(:atand,0.0,90.0,unary),
 (:sec,1.0,0.0,trig),(:csc,1.0,0.0,trig),(:secd,1.0,0.0,trig),(:cscd,1.0,0.0,trig),
 (:acsc,1.0,0.0,trig),(:acscd,90.0,0.0,trig),
 (:csch,1.0,0.0,hyper),(:acsch,1.0,0.0,hyper),(:acoth,1.0,0.0,hyper),(:coth,2.0,1.0,hyper),
 (:sign,1.0,0.5,:infeasible_sign_range_constraint)]
@testset "Analytic output witnesses and exclusions cover every retained primitive" begin
    for (op,valid,invalid,code) in cases, constructor in (MOI.EqualTo,v->MOI.Interval(v,v))
        @test !has(report(op,constructor(valid)),code)
        r=report(op,constructor(invalid))
        @test has(r,code)
        @test only(filter(f->f.code==code,r.findings)).basis==ND.MathematicalProof
        @test !has(report(op,UnknownScalarSet()),code)
    end
    for level in (-4.0,4.0)
        @test has(report(:atan,MOI.EqualTo(level);binary=true),:infeasible_atan2_principal_range_constraint)
    end
    for level in (0.0,Float64(pi),-Float64(pi))
        @test !has(report(:atan,MOI.EqualTo(level);binary=true),:infeasible_atan2_principal_range_constraint)
    end
    # Half-lines and intervals that touch a closed endpoint remain feasible.
    @test !has(report(:sin,MOI.GreaterThan(1.0)),unary)
    @test has(report(:tanh,MOI.GreaterThan(1.0)),unary)
    @test has(report(:logistic,MOI.LessThan(0.0)),unary)
    @test !has(report(:sec,MOI.Interval(-1.0,1.0)),trig)
    @test has(report(:coth,MOI.Interval(-1.0,1.0)),hyper)
end
const endpoints=[
 (:acos,0.0,1.0,:inverse_trigonometric),(:asec,0.0,1.0,:inverse_trigonometric),
 (:asind,-90.0,-1.0,:inverse_trigonometric),(:asind,90.0,1.0,:inverse_trigonometric),
 (:acosd,0.0,1.0,:inverse_trigonometric),(:acosd,180.0,-1.0,:inverse_trigonometric),
 (:asecd,0.0,1.0,:inverse_trigonometric),(:asecd,180.0,-1.0,:inverse_trigonometric),
 (:acscd,-90.0,-1.0,:inverse_trigonometric),(:acscd,90.0,1.0,:inverse_trigonometric),
 (:sinh,0.0,0.0,:hyperbolic),(:asinh,0.0,0.0,:hyperbolic),(:tanh,0.0,0.0,:hyperbolic),
 (:atanh,0.0,0.0,:hyperbolic),(:cosh,1.0,0.0,:hyperbolic),(:sech,1.0,0.0,:hyperbolic),
 (:logcosh,0.0,0.0,:hyperbolic),(:acosh,0.0,1.0,:hyperbolic),(:asech,0.0,1.0,:hyperbolic),
 (:exp,1.0,0.0,:elementary_reference_level),(:expm1,0.0,0.0,:elementary_reference_level),
 (:log,0.0,1.0,:elementary_reference_level),(:log1p,0.0,0.0,:elementary_reference_level),
 (:logistic,0.5,0.0,:elementary_reference_level),(:cbrt,0.0,0.0,:elementary_reference_level)]
@testset "Exact reference preimages retain only supported bound conflicts" begin
    for (op,level,root,family) in endpoints
        prefix=family==:elementary_reference_level ? string(family) : string(family)*"_endpoint"
        fixed=Symbol(prefix*"_implies_fixed_variable")
        conflict=Symbol("inconsistent_"*prefix*"_variable_bound")
        r=report(op,MOI.EqualTo(level);bounds=[(x,MOI.EqualTo(root))])
        @test has(r,fixed)
        @test !has(r,conflict)
        @test Dict(only(filter(f->f.code==fixed,r.findings)).evidence[1].details)["implied_value"]==string(root)
        @test has(report(op,MOI.Interval(level,level);bounds=[(x,MOI.GreaterThan(root+1))]),conflict)
        @test has(report(op,MOI.EqualTo(level);bounds=[(x,MOI.LessThan(root-1))]),conflict)
        @test !has(report(op,MOI.EqualTo(level);bounds=[(x,MOI.GreaterThan(Inf))]),conflict)
        @test !has(report(op,MOI.EqualTo(level);nested=true),fixed)
        @test !has(report(op,MOI.Interval(level-0.25,level+0.25)),fixed)
    end
    r=report(:exp,MOI.EqualTo(1.0);bounds=[(x,MOI.GreaterThan(big(1)//3)),(x,MOI.LessThan(1.0))])
    f=only(filter(f->f.code==:inconsistent_elementary_reference_level_variable_bound,r.findings))
    @test Dict(f.evidence[1].details)["declared_lower"]=="1//3"
end
@testset "Square and axis premises have independent positive and negative controls" begin
    for op in (:abs,:sqrt,:^,:sign)
        code=op==:abs ? :absolute_zero_implies_fixed_variable : op==:sqrt ? :square_root_zero_implies_fixed_variable : op==:^ ? :square_zero_implies_fixed_variable : :sign_zero_implies_fixed_variable
        @test has(report(op,MOI.EqualTo(0.0)),code)
        @test !has(report(op,MOI.EqualTo(1.0)),code)
    end
    for bound in (MOI.GreaterThan(Inf),MOI.LessThan(-Inf),MOI.Interval(2.0,1.0),MOI.GreaterThan(NaN))
        r=report(:^,MOI.EqualTo(4.0);bounds=[(x,bound)])
        @test !has(r,:sign_resolved_square_level_set)
        @test has(r,:positive_square_level_set)
    end
    for (bound,root) in ((MOI.GreaterThan(0.0),"2.0"),(MOI.LessThan(0.0),"-2.0"))
        r=report(:^,MOI.EqualTo(4.0);bounds=[(x,bound)])
        f=only(filter(f->f.code==:sign_resolved_square_level_set,r.findings))
        @test Dict(f.evidence[1].details)["implied_value"]==root
    end
    @test has(report(:atan,MOI.EqualTo(0.0);binary=true),:atan2_axis_angle_implies_fixed_variable)
    @test has(report(:atan,MOI.EqualTo(0.0);binary=true,bounds=[(x,MOI.GreaterThan(1.0))]),:inconsistent_atan2_axis_angle_variable_bound)
    @test has(report(:atan,MOI.EqualTo(0.0);binary=true,bounds=[(y,MOI.LessThan(-1.0))]),:inconsistent_atan2_axis_angle_sign_bound)
    @test !has(report(:atan,MOI.EqualTo(0.0);binary=true,bounds=[(y,MOI.GreaterThan(1.0))]),:inconsistent_atan2_axis_angle_sign_bound)
end
end
