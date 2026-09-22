module FinalProducerContractTests
using Test
import MathOptInterface as MOI
import NLPDiagnostics as ND
const x=MOI.VariableIndex(1)
row(f,s,i)=ND.ConstraintRecord(MOI.ConstraintIndex{typeof(f),typeof(s)}(i),f,s,nothing)
snap(rows)=ND.ModelSnapshot([ND.VariableRecord(x,nothing)],rows,nothing,nothing,String[])
struct DisplayCollision <: MOI.AbstractScalarFunction
    value::Int
end
Base.show(io::IO,::DisplayCollision)=print(io,"same display")
function reused(fs,sets)
    r=ND.DiagnosticReport()
    ND._analyze_reused_constraint_expressions!(r,snap([row(f,s,i) for (i,(f,s)) in enumerate(zip(fs,sets))]))
    r
end
has(r,c)=any(f->f.code==c,r.findings)
const clash=:inconsistent_reused_expression_sets
const dominated=:dominated_reused_expression_set
@testset "Reuse proofs need supported expressions and valid sets" begin
    f=MOI.ScalarNonlinearFunction(:sin,Any[x])
    @test has(reused([f,f],[MOI.EqualTo(0.0),MOI.EqualTo(1.0)]),clash)
    @test has(reused([f,f],[MOI.LessThan(2.0),MOI.LessThan(1.0)]),dominated)
    @test !has(reused([f,f],[MOI.GreaterThan(0.0),MOI.LessThan(1.0)]),clash)
    for bad in (MOI.EqualTo(NaN),MOI.EqualTo(Inf),MOI.Interval(2.0,1.0))
        r=reused([f,f],[bad,MOI.EqualTo(0.0)])
        @test !has(r,clash)
        @test !has(r,dominated)
    end
    for bad in (NaN,Inf,-Inf)
        g=MOI.ScalarAffineFunction([MOI.ScalarAffineTerm(bad,x)],0.0)
        @test !has(reused([g,g],[MOI.EqualTo(0.0),MOI.EqualTo(1.0)]),clash)
    end
    @test repr(DisplayCollision(0))==repr(DisplayCollision(1))
    @test !has(reused([DisplayCollision(0),DisplayCollision(1)],[MOI.EqualTo(0.0),MOI.EqualTo(1.0)]),clash)
    r=reused([f,f],[MOI.GreaterThan(big(1)//3),MOI.LessThan(0.0)])
    @test Dict(only(r.findings).evidence[1].details)["effective_lower"]=="1//3"
    # Independent coefficient arithmetic: these are equal despite order.
    a=MOI.ScalarAffineFunction([MOI.ScalarAffineTerm(c,x) for c in (1e16,1.0,-1e16)],0.0)
    b=MOI.ScalarAffineFunction([MOI.ScalarAffineTerm(1.0,x)],0.0)
    @test sum(Rational{BigInt}.([1e16,1.0,-1e16]))==1
    @test has(reused([a,b],[MOI.EqualTo(0.0),MOI.EqualTo(1.0)]),clash)
    @test !has(reused([a,b],[MOI.GreaterThan(0.0),MOI.LessThan(1.0)]),clash)
end
@testset "Public plan records cannot manufacture proof evidence" begin
    source=ND.EntityRef(:constraint,1)
    path=ND.ExpressionNodePath(source,Int[])
    # Deliberately false candidate: the renderer has neither the source tree
    # nor a certificate, so it must not endorse this supplied description.
    candidate=ND.StableReformulationCandidate(source,path,:invented,:zero,"replace x by zero",false,[x])
    r=ND.analyze_stable_reformulation_plan(ND.StableReformulationPlan([candidate],Float64))
    @test only(r.findings).basis==ND.HeuristicInterpretation
    @test only(ND.report_data(r)["findings"])["basis"]=="heuristic_interpretation"
    for assessment in (:proven,:possible)
        guard=ND.ElasticDomainGuard(source,Int[],:log,1,"x > 0",assessment,[x],1.0,2.0,true,true,"manual",nothing)
        r=ND.analyze_elastic_domain_guard_plan(ND.ElasticDomainGuardPlan([guard],ND.ElasticDomainGuard[],1))
        @test only(r.findings).basis==ND.HeuristicInterpretation
        @test Dict(only(r.findings).evidence[1].details)["assessment_revalidated"]=="false"
        @test only(ND.report_data(r)["findings"])["basis"]=="heuristic_interpretation"
    end
    # Genuine generated candidates and guards remain visible as suggestions.
    m=MOI.Utilities.UniversalFallback(MOI.Utilities.Model{Float64}());v=MOI.add_variable(m)
    MOI.add_constraint(m,v,MOI.LessThan(-1.0))
    MOI.add_constraint(m,MOI.ScalarNonlinearFunction(:log,Any[v]),MOI.LessThan(0.0))
    r=ND.analyze_elastic_domain_guard_plan(ND.elastic_domain_guard_plan(m))
    @test has(r,:elastic_proven_domain_guard_violation)
    @test all(f->f.basis!=ND.MathematicalProof,r.findings)
end
@testset "Initialization proofs apply only to finite represented coordinates" begin
    m=snap([row(x,MOI.Interval(0.0,1.0),1)])
    for value in (NaN,Inf,-Inf)
        fs=ND._initialization_bound_findings(m,ND.EvaluationPoint([x],[value]))
        @test any(f->f.code==:initialization_nonfinite_value,fs)
        @test !any(f->f.code==:initialization_violates_variable_bounds,fs)
        @test all(f->f.basis!=ND.MathematicalProof,fs)
    end
    for value in (-1.0,2.0)
        fs=ND._initialization_bound_findings(m,ND.EvaluationPoint([x],[value]))
        @test only(fs).basis==ND.MathematicalProof
    end
    for value in (0.0,0.5,1.0)
        fs=ND._initialization_bound_findings(m,ND.EvaluationPoint([x],[value]))
        @test !any(f->f.code==:initialization_violates_variable_bounds,fs)
    end
    invalid=snap([row(x,MOI.GreaterThan(NaN),1)])
    @test !any(f->f.code==:initialization_violates_variable_bounds,
        ND._initialization_bound_findings(invalid,ND.EvaluationPoint([x],[0.0])))
    # The represented float lies strictly below the exact rational bound.
    rational=snap([row(x,MOI.GreaterThan(big(1)//3),1)])
    @test Rational{BigInt}(Float64(1/3)) < big(1)//3
    fs=ND._initialization_bound_findings(rational,ND.EvaluationPoint([x],[1/3]))
    @test any(f->f.code==:initialization_violates_variable_bounds,fs)
end
end
