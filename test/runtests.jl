# Intentionally broken models are the primary regression-test style.
using Test

import JuMP
import MathOptInterface as MOI
import NLPDiagnostics

const MOIU = MOI.Utilities

function new_model()
    return MOIU.UniversalFallback(MOIU.Model{Float64}())
end

function findings(report, code)
    return filter(finding -> finding.code == code, report.findings)
end

function evidence_details(finding)
    return Dict(finding.evidence[1].details)
end

@testset "NLPDiagnostics" begin
    @testset "inconsistent bounds and disconnected variable" begin
        model = new_model()
        x = MOI.add_variable(model)
        MOI.set(model, MOI.VariableName(), x, "temperature")
        MOI.add_constraint(model, x, MOI.GreaterThan(10.0))
        MOI.add_constraint(model, x, MOI.LessThan(5.0))

        report = NLPDiagnostics.analyze(model)
        @test length(findings(report, :inconsistent_variable_bounds)) == 1
        @test length(findings(report, :disconnected_variable)) == 1
        finding = only(findings(report, :inconsistent_variable_bounds))
        @test finding.basis == NLPDiagnostics.MathematicalProof
        @test finding.confidence == NLPDiagnostics.ConfidenceCertain
        @test finding.domain == NLPDiagnostics.MathematicalIssue
    end

    @testset "fixed variable" begin
        model = new_model()
        x = MOI.add_variable(model)
        MOI.add_constraint(model, x, MOI.EqualTo(2.0))
        report = NLPDiagnostics.analyze(model)
        @test length(findings(report, :fixed_variable)) == 1
    end

    @testset "constant constraints" begin
        model = new_model()
        F = MOI.ScalarAffineFunction{Float64}
        MOI.add_constraint(model, F(MOI.ScalarAffineTerm{Float64}[], 2.0), MOI.LessThan(1.0))
        MOI.add_constraint(model, F(MOI.ScalarAffineTerm{Float64}[], 0.0), MOI.LessThan(1.0))
        report = NLPDiagnostics.analyze(model)
        @test length(findings(report, :infeasible_constant_constraint)) == 1
        @test length(findings(report, :redundant_constant_constraint)) == 1
    end

    @testset "constant nonlinear domain violation" begin
        model = new_model()
        f = MOI.ScalarNonlinearFunction(:log, Any[-1.0])
        MOI.add_constraint(model, f, MOI.LessThan(0.0))
        report = NLPDiagnostics.analyze(model)
        @test length(findings(report, :constant_domain_violation)) == 1
    end

    @testset "duplicate affine constraints are canonicalized" begin
        model = new_model()
        x, y = MOI.add_variables(model, 2)
        F = MOI.ScalarAffineFunction{Float64}
        T = MOI.ScalarAffineTerm{Float64}
        f1 = F([T(2.0, x), T(3.0, y)], 1.0)
        f2 = F([T(1.0, x), T(3.0, y), T(1.0, x)], 1.0)
        MOI.add_constraint(model, f1, MOI.EqualTo(0.0))
        MOI.add_constraint(model, f2, MOI.EqualTo(0.0))
        report = NLPDiagnostics.analyze(model)
        @test length(findings(report, :duplicate_constraint)) == 1
        @test isempty(findings(report, :disconnected_variable))
    end

    @testset "objective participation connects a variable" begin
        model = new_model()
        x = MOI.add_variable(model)
        MOI.set(model, MOI.ObjectiveSense(), MOI.MIN_SENSE)
        MOI.set(model, MOI.ObjectiveFunction{MOI.VariableIndex}(), x)
        report = NLPDiagnostics.analyze(model)
        @test isempty(findings(report, :disconnected_variable))
    end

    @testset "vector nonlinear incidence" begin
        model = new_model()
        x = MOI.add_variable(model)
        row = MOI.ScalarNonlinearFunction(:sin, Any[x])
        f = MOI.VectorNonlinearFunction([row])
        MOI.add_constraint(model, f, MOI.Nonnegatives(1))
        report = NLPDiagnostics.analyze(model)
        @test isempty(findings(report, :disconnected_variable))
        @test isempty(findings(report, :variable_incidence_analysis_unavailable))
    end

    @testset "variable support ignores exact zero coefficients" begin
        model = new_model()
        x, y = MOI.add_variables(model, 2)
        F = MOI.ScalarAffineFunction{Float64}
        T = MOI.ScalarAffineTerm{Float64}
        f = F([T(0.0, x), T(1.0, y)], 0.0)
        support = NLPDiagnostics.variable_support(f)
        @test support.complete
        @test support.variables == [y]
        MOI.add_constraint(model, f, MOI.EqualTo(0.0))
        report = NLPDiagnostics.analyze(model)
        disconnected = findings(report, :disconnected_variable)
        @test length(disconnected) == 1
        @test only(disconnected).affected[1].index == x.value
    end

    @testset "constraint incidence components and objective coupling" begin
        model = new_model()
        x, y, z = MOI.add_variables(model, 3)
        MOI.set(model, MOI.VariableName(), x, "x")
        MOI.set(model, MOI.VariableName(), y, "y")
        MOI.set(model, MOI.VariableName(), z, "z")
        F = MOI.ScalarAffineFunction{Float64}
        T = MOI.ScalarAffineTerm{Float64}
        MOI.add_constraint(
            model,
            F([T(1.0, x), T(1.0, y)], 0.0),
            MOI.EqualTo(0.0),
        )
        MOI.add_constraint(
            model,
            F([T(1.0, z)], 0.0),
            MOI.EqualTo(1.0),
        )
        MOI.set(model, MOI.ObjectiveSense(), MOI.MIN_SENSE)
        MOI.set(
            model,
            MOI.ObjectiveFunction{F}(),
            F([T(1.0, x), T(1.0, z)], 0.0),
        )

        graph = NLPDiagnostics.incidence_graph(model)
        @test graph.complete
        @test length(graph.variables) == 3
        @test length(graph.constraint_nodes) == 2
        components = NLPDiagnostics.connected_components(graph)
        nontrivial = filter(
            component ->
                !isempty(component.variable_positions) &&
                !isempty(component.constraint_positions),
            components,
        )
        @test sort(
            [
                (
                    length(component.variable_positions),
                    length(component.constraint_positions),
                ) for component in nontrivial
            ],
        ) == [(1, 1), (2, 1)]

        report = NLPDiagnostics.analyze(model)
        finding = only(findings(report, :multiple_constraint_components))
        details = evidence_details(finding)
        @test details["component_sizes"] == "2v/1c, 1v/1c"
        @test details["objective_couples_components"] == "true"
        @test report.metadata[:structural_component_count] == "2"
    end

    @testset "vector constraints create scalar row vertices" begin
        model = new_model()
        x, y = MOI.add_variables(model, 2)
        T = MOI.ScalarAffineTerm{Float64}
        VT = MOI.VectorAffineTerm{Float64}
        f = MOI.VectorAffineFunction(
            [VT(1, T(1.0, x)), VT(2, T(1.0, y))],
            [0.0, 0.0],
        )
        MOI.add_constraint(model, f, MOI.Zeros(2))

        graph = NLPDiagnostics.incidence_graph(model)
        @test length(graph.constraint_nodes) == 2
        @test graph.constraint_to_variables == [[1], [2]]
        report = NLPDiagnostics.analyze(model)
        finding = only(findings(report, :multiple_constraint_components))
        constraint_refs = filter(ref -> ref.kind == :constraint, finding.affected)
        @test sort([something(ref.subindex) for ref in constraint_refs]) == [1, 2]
    end

    @testset "coupled vector sets remain block vertices" begin
        model = new_model()
        x, y = MOI.add_variables(model, 2)
        f = MOI.VectorOfVariables([x, y])
        MOI.add_constraint(model, f, MOI.SecondOrderCone(2))

        graph = NLPDiagnostics.incidence_graph(model)
        @test graph.complete
        @test length(graph.constraint_nodes) == 1
        @test graph.constraint_to_variables == [[1, 2]]
        @test isnothing(only(graph.constraint_nodes).row)
        report = NLPDiagnostics.analyze(model)
        @test isempty(findings(report, :multiple_constraint_components))
    end

    @testset "JuMP extension" begin
        model = JuMP.Model()
        JuMP.@variable(model, x >= 0)
        JuMP.@constraint(model, sin(x) <= 1)
        report = NLPDiagnostics.analyze(model)
        @test report isa NLPDiagnostics.DiagnosticReport
        @test isempty(findings(report, :disconnected_variable))
        @test NLPDiagnostics.incidence_graph(model) isa
              NLPDiagnostics.IncidenceGraph
    end

    @testset "text report" begin
        report = NLPDiagnostics.DiagnosticReport()
        text = sprint(show, MIME"text/plain"(), report)
        @test occursin("0 findings", text)
    end
end
