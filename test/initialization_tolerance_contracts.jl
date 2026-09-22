module InitializationToleranceContractTests
using Test
import MathOptInterface as MOI
import NLPDiagnostics as ND
const x=MOI.VariableIndex(1)
function bound_findings(value,set,tolerance)
    row=ND.ConstraintRecord(MOI.ConstraintIndex{MOI.VariableIndex,typeof(set)}(1),x,set,nothing)
    snapshot=ND.ModelSnapshot([ND.VariableRecord(x,nothing)],[row],nothing,nothing,String[])
    ND._initialization_bound_findings(snapshot,ND.EvaluationPoint([x],[value]);feasibility_tolerance=tolerance)
end
@testset "Exact initialization evidence and tolerance-aware severity" begin
    for set in (MOI.GreaterThan(0.0),MOI.LessThan(0.0),MOI.EqualTo(0.0)),
        excursion in (prevfloat(0.125),0.125,nextfloat(0.125))
        value=set isa MOI.GreaterThan ? -excursion : excursion
        f=only(bound_findings(value,set,0.125))
        @test f.code==:initialization_violates_variable_bounds
        @test f.basis==ND.MathematicalProof
        @test f.severity==(excursion<=0.125 ? ND.SeverityInfo : ND.SeverityError)
        @test Dict(f.evidence[2].details)["absolute_feasibility_tolerance"]=="0.125"
    end
    @test only(bound_findings(-nextfloat(0.0),MOI.GreaterThan(0.0),0)).severity==ND.SeverityError
    @test isempty(bound_findings(0.0,MOI.EqualTo(0.0),1e-6))
    # Floating subtraction rounds this exact excursion down to the tolerance.
    @test 1.0-(-eps()/4)==1.0
    @test only(bound_findings(1.0,MOI.LessThan(-eps()/4),1.0)).severity==ND.SeverityError
    for tolerance in (-1.0,NaN,Inf,-Inf)
        @test_throws ArgumentError bound_findings(1.0,MOI.LessThan(0.0),tolerance)
        @test_throws ArgumentError ND.analyze_initialization(MOI.Utilities.Model{Float64}();feasibility_tolerance=tolerance)
    end
    for value in (NaN,Inf,-Inf)
        f=only(bound_findings(value,MOI.LessThan(0.0),1.0))
        @test f.code==:initialization_nonfinite_value
        @test f.severity==ND.SeverityError
        @test f.basis==ND.NumericalObservation
    end
    # Mixed groups preserve separate affected identities and exact evidence.
    model=MOI.Utilities.UniversalFallback(MOI.Utilities.Model{Float64}())
    a,b=MOI.add_variables(model,2)
    for (v,start) in ((a,-1e-8),(b,-0.2))
        MOI.add_constraint(model,v,MOI.GreaterThan(0.0))
        MOI.set(model,MOI.VariablePrimalStart(),v,start)
    end
    report=ND.analyze_initialization(model;feasibility_tolerance=1e-6,
        check_degeneracy=false,check_component_ranks=false)
    fs=filter(f->f.code==:initialization_violates_variable_bounds,report.findings)
    @test length(fs)==2
    @test Set(f.severity for f in fs)==Set([ND.SeverityError,ND.SeverityInfo])
    @test report.metadata[:initialization_bound_absolute_tolerance]=="1.0e-6"
    @test all(f->length(f.affected)==1,fs)
    @test all(f->f.basis==ND.MathematicalProof,fs)
    @test only(only(filter(f->f.severity==ND.SeverityInfo,fs)).affected).index==a.value
    @test only(only(filter(f->f.severity==ND.SeverityError,fs)).affected).index==b.value
    # Tiny negative starts remain unsafe for log even when bound severity is info.
    model2=MOI.Utilities.UniversalFallback(MOI.Utilities.Model{Float64}())
    c=MOI.add_variable(model2)
    MOI.add_constraint(model2,c,MOI.GreaterThan(0.0))
    MOI.set(model2,MOI.VariablePrimalStart(),c,-1e-8)
    MOI.add_constraint(model2,MOI.ScalarNonlinearFunction(:log,Any[c]),MOI.LessThan(1.0))
    report2=ND.analyze_initialization(model2;feasibility_tolerance=1e-6,
        check_degeneracy=false,check_component_ranks=false)
    @test any(f->f.severity==ND.SeverityError && f.code!=:initialization_violates_variable_bounds,report2.findings)
end
end
