module CertifiedGeometryIntegrationTests
using Test
import MathOptInterface as MOI
import NLPDiagnostics as ND
newmodel() = MOI.Utilities.UniversalFallback(MOI.Utilities.Model{Float64}())
const QT = MOI.ScalarQuadraticTerm
const AT = MOI.ScalarAffineTerm
function circle(; level=1.0, equality=true)
    model=newmodel(); x,y=MOI.add_variables(model,2)
    f=MOI.ScalarQuadraticFunction([QT(2.0,x,x),QT(2.0,y,y)],[AT(-4.0,x)],4.0)
    ci=MOI.add_constraint(model,f,equality ? MOI.EqualTo(level) : MOI.LessThan(level))
    return model,x,y,ci
end

@testset "Certified geometry propagates domain safety and source provenance" begin
    for equality in (true,false)
        model,x,y,ci=circle(;equality)
        z=MOI.add_variable(model)
        affine=MOI.add_constraint(model,MOI.ScalarAffineFunction([AT(1.0,z),AT(-1.0,x)],0.0),MOI.EqualTo(4.0))
        MOI.add_constraint(model,MOI.ScalarNonlinearFunction(:log,Any[z]),MOI.LessThan(10.0))
        snapshot=ND.snapshot(model)
        bounds,origins=ND._domain_variable_interval_state(snapshot;certified_only=true)
        @test bounds[x].certified && bounds[x].lower == 1 && bounds[x].upper == 3
        @test bounds[z].certified && bounds[z].lower == 5 && bounds[z].upper == 7
        geometry_row=only(filter(r -> r.index == ci,snapshot.constraints))
        affine_row=only(filter(r -> r.index == affine,snapshot.constraints))
        @test ND._domain_constraint_origin_id(geometry_row) in origins[z][:diagonal_quadratic_geometry]
        @test ND._domain_constraint_origin_id(affine_row) in origins[z][:scalar_affine_propagation]
        @test isempty(ND.domain_issues(model))
        @test all(row -> row["certified"],ND.domain_interval_data(model))
        # A declared bound tightens the geometry but neither premise disappears.
        declared=MOI.add_constraint(model,x,MOI.GreaterThan(1.5))
        snapshot=ND.snapshot(model)
        bounds,origins=ND._domain_variable_interval_state(snapshot;certified_only=true)
        @test bounds[z].lower == 5.5 && bounds[z].certified
        declared_row=only(filter(r -> r.index == declared,snapshot.constraints))
        @test ND._domain_constraint_origin_id(declared_row) in origins[z][:declared_variable_bounds]
        finding=only(ND._initialization_bound_findings(snapshot,ND.evaluation_point(model,[2.0,0.0,5.0])))
        @test finding.basis == ND.MathematicalProof
        @test occursin(ND._domain_constraint_origin_id(geometry_row),Dict(finding.evidence[2].details)["v$(z.value)"])
    end
    # An approximate inverse may narrow the raw view, but cannot replace a
    # certified geometry interval in the proof-only view.
    model,x,y,_=circle()
    MOI.add_constraint(model,MOI.ScalarNonlinearFunction(:exp,Any[x]),MOI.GreaterThan(exp(2.5)))
    snapshot=ND.snapshot(model)
    raw,_=ND._domain_variable_interval_state(snapshot)
    safe,_=ND._domain_variable_interval_state(snapshot;certified_only=true)
    @test !raw[x].certified && raw[x].lower > 2
    @test safe[x].certified && safe[x].lower == 1 && safe[x].upper == 3
end

@testset "Certified geometry resolves zero domains without false point fixing" begin
    for level in (0.0,1.0)
        model,x,y,_=circle(;level)
        bounds=ND._domain_variable_intervals(ND.snapshot(model))
        @test bounds[x].certified && bounds[y].certified
        @test bounds[x].lower == 2-sqrt(level) && bounds[x].upper == 2+sqrt(level)
        MOI.add_constraint(model,MOI.ScalarNonlinearFunction(:log,Any[y]),MOI.LessThan(10.0))
        report=ND.analyze_domains(model)
        code=level == 0 ? :proven_expression_domain_violation : :possible_expression_domain_violation
        @test length(ND.findings(report;code)) == 1
    end
    # The cancellation regression retains the exact feasible witness when used
    # by propagation and initialization, not just by the static recognizer.
    model=newmodel(); x,y=MOI.add_variables(model,2)
    f=MOI.ScalarQuadraticFunction([QT(2.0,x,x),QT(2.0,y,y)],[AT(2e8,x),AT(2.0,y)],1e16)
    MOI.add_constraint(model,f,MOI.EqualTo(0.0))
    MOI.add_constraint(model,y,MOI.GreaterThan(0.0))
    snapshot=ND.snapshot(model); bounds=ND._domain_variable_intervals(snapshot)
    @test bounds[y].valid && bounds[y].lower == bounds[y].upper == 0
    point=ND.evaluation_point(model,[-1e8,0.0])
    @test isempty(ND._initialization_bound_findings(snapshot,point))
    @test isempty(ND._initialization_diagonal_quadratic_equality_bound_findings(snapshot,point))
end

@testset "Initialization uses exact exclusions with explicit scope" begin
    for equality in (true,false), level in (0.0,1.0,2.0)
        model,x,y,ci=circle(;level,equality)
        snapshot=ND.snapshot(model)
        analyze=equality ? ND._initialization_diagonal_quadratic_equality_bound_findings : ND._initialization_diagonal_quadratic_bound_findings
        # Far outside is a certified exclusion even for irrational radii.
        finding=only(analyze(snapshot,ND.evaluation_point(model,[5.0,0.0])))
        @test finding.basis == ND.MathematicalProof
        details=Dict(finding.evidence[2].details)
        @test details["interval_certified"] == "true"
        @test details["comparison"] == "exact_squared_distance"
        @test details["source_constraint"] == ND._domain_constraint_origin_id(only(snapshot.constraints))
        @test occursin("not infeasibility of the model",finding.why_it_matters)
        # Passing coordinate restrictions does not certify full-row feasibility.
        @test isempty(analyze(snapshot,ND.evaluation_point(model,[2.0,0.0])))
    end
    model,x,y,_=circle()
    snapshot=ND.snapshot(model)
    @test isempty(ND._initialization_diagonal_quadratic_equality_bound_findings(snapshot,ND.evaluation_point(model,[3.0,0.0])))
    @test length(ND._initialization_diagonal_quadratic_equality_bound_findings(snapshot,ND.evaluation_point(model,[nextfloat(3.0),0.0]))) == 1
end
end
