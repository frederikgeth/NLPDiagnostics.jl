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

    @testset "explicit structural roles" begin
        model = new_model()
        free = MOI.add_variable(model)
        fixed = MOI.add_variable(model)
        MOI.add_constraint(model, fixed, MOI.EqualTo(2.0))
        parameter, _ = MOI.add_constrained_variable(
            model,
            MOI.Parameter(3.0),
        )
        infeasible = MOI.add_variable(model)
        MOI.add_constraint(model, infeasible, MOI.GreaterThan(2.0))
        MOI.add_constraint(model, infeasible, MOI.LessThan(1.0))
        F = MOI.ScalarAffineFunction{Float64}
        T = MOI.ScalarAffineTerm{Float64}
        MOI.add_constraint(
            model,
            F([T(1.0, free), T(1.0, fixed)], 0.0),
            MOI.EqualTo(0.0),
        )
        MOI.add_constraint(
            model,
            F([T(1.0, free)], 0.0),
            MOI.LessThan(1.0),
        )
        MOI.add_constraint(
            model,
            MOI.VectorOfVariables([free, parameter]),
            MOI.SecondOrderCone(2),
        )

        graph = NLPDiagnostics.incidence_graph(model)
        @test graph.variable_roles == [
            NLPDiagnostics.FreeVariable,
            NLPDiagnostics.FixedVariable,
            NLPDiagnostics.ParameterVariable,
            NLPDiagnostics.InfeasibleVariableDomain,
        ]
        roles = [node.role for node in graph.constraint_nodes]
        @test count(==(NLPDiagnostics.EqualityConstraint), roles) == 1
        @test count(==(NLPDiagnostics.InequalityConstraint), roles) == 1
        @test count(==(NLPDiagnostics.CoupledConstraint), roles) == 1
    end

    @testset "semicontinuous equal endpoints are not fixed" begin
        model = new_model()
        x = MOI.add_variable(model)
        MOI.add_constraint(model, x, MOI.Semicontinuous(2.0, 2.0))
        graph = NLPDiagnostics.incidence_graph(model)
        @test only(graph.variable_roles) == NLPDiagnostics.FreeVariable
        report = NLPDiagnostics.analyze(model)
        @test isempty(findings(report, :fixed_variable))
    end

    @testset "underdetermined equality matching and DM partition" begin
        model = new_model()
        x, y = MOI.add_variables(model, 2)
        MOI.set(model, MOI.VariableName(), x, "x")
        MOI.set(model, MOI.VariableName(), y, "y")
        F = MOI.ScalarAffineFunction{Float64}
        T = MOI.ScalarAffineTerm{Float64}
        MOI.add_constraint(
            model,
            F([T(1.0, x), T(1.0, y)], 0.0),
            MOI.EqualTo(0.0),
        )

        graph = NLPDiagnostics.incidence_graph(model)
        matching = NLPDiagnostics.maximum_matching(graph)
        @test matching.complete
        @test NLPDiagnostics.matching_cardinality(matching) == 1
        @test matching.variable_match == [1, 0]
        @test matching.constraint_match == [1]
        partition = NLPDiagnostics.dulmage_mendelsohn(
            graph;
            matching = matching,
        )
        @test partition.complete
        @test partition.underdetermined_variables == [1, 2]
        @test partition.underdetermined_constraints == [1]
        @test isempty(partition.well_determined_variables)
        @test isempty(partition.overdetermined_constraints)

        report = NLPDiagnostics.analyze(model)
        @test length(findings(report, :unmatched_structural_variables)) == 1
        @test length(findings(report, :underdetermined_equality_partition)) == 1
        @test report.metadata[:structural_matching_cardinality] == "1"
    end

    @testset "matching uses augmenting paths" begin
        model = new_model()
        x, y = MOI.add_variables(model, 2)
        F = MOI.ScalarAffineFunction{Float64}
        T = MOI.ScalarAffineTerm{Float64}
        MOI.add_constraint(
            model,
            F([T(1.0, x), T(1.0, y)], 0.0),
            MOI.EqualTo(0.0),
        )
        MOI.add_constraint(
            model,
            F([T(1.0, x)], 0.0),
            MOI.EqualTo(1.0),
        )
        matching = NLPDiagnostics.maximum_matching(model)
        @test NLPDiagnostics.matching_cardinality(matching) == 2
        @test matching.variable_match == [2, 1]
        @test matching.constraint_match == [2, 1]
    end

    @testset "well-determined irreducible blocks" begin
        F = MOI.ScalarAffineFunction{Float64}
        T = MOI.ScalarAffineTerm{Float64}

        diagonal = new_model()
        x, y = MOI.add_variables(diagonal, 2)
        MOI.set(diagonal, MOI.VariableName(), x, "x")
        MOI.set(diagonal, MOI.VariableName(), y, "y")
        MOI.add_constraint(
            diagonal,
            F([T(1.0, x)], 0.0),
            MOI.EqualTo(0.0),
        )
        MOI.add_constraint(
            diagonal,
            F([T(1.0, y)], 0.0),
            MOI.EqualTo(0.0),
        )
        diagonal_graph = NLPDiagnostics.incidence_graph(diagonal)
        diagonal_blocks = NLPDiagnostics.well_determined_blocks(
            diagonal_graph,
        )
        @test length(diagonal_blocks) == 2
        @test [block.variable_positions for block in diagonal_blocks] ==
              [[1], [2]]
        @test [block.constraint_positions for block in diagonal_blocks] ==
              [[1], [2]]
        diagonal_report = NLPDiagnostics.analyze(diagonal)
        @test length(
            findings(
                diagonal_report,
                :multiple_well_determined_blocks,
            ),
        ) == 1

        triangular = new_model()
        x, y = MOI.add_variables(triangular, 2)
        MOI.add_constraint(
            triangular,
            F([T(1.0, x)], 0.0),
            MOI.EqualTo(0.0),
        )
        MOI.add_constraint(
            triangular,
            F([T(1.0, x), T(1.0, y)], 0.0),
            MOI.EqualTo(0.0),
        )
        triangular_blocks = NLPDiagnostics.well_determined_blocks(
            triangular,
        )
        @test [block.constraint_positions for block in triangular_blocks] ==
              [[1], [2]]

        irreducible = new_model()
        x, y = MOI.add_variables(irreducible, 2)
        MOI.add_constraint(
            irreducible,
            F([T(1.0, x), T(1.0, y)], 0.0),
            MOI.EqualTo(0.0),
        )
        MOI.add_constraint(
            irreducible,
            F([T(2.0, x), T(3.0, y)], 0.0),
            MOI.EqualTo(0.0),
        )
        irreducible_blocks = NLPDiagnostics.well_determined_blocks(
            irreducible,
        )
        @test length(irreducible_blocks) == 1
        @test only(irreducible_blocks).variable_positions == [1, 2]
        @test only(irreducible_blocks).constraint_positions == [1, 2]
    end

    @testset "stable structural graph export" begin
        model = new_model()
        x, y = MOI.add_variables(model, 2)
        MOI.set(model, MOI.VariableName(), x, "source")
        MOI.set(model, MOI.VariableName(), y, "state")
        F = MOI.ScalarAffineFunction{Float64}
        T = MOI.ScalarAffineTerm{Float64}
        first_constraint = MOI.add_constraint(
            model,
            F([T(1.0, x)], 0.0),
            MOI.EqualTo(0.0),
        )
        MOI.set(
            model,
            MOI.ConstraintName(),
            first_constraint,
            "reference",
        )
        MOI.add_constraint(
            model,
            F([T(1.0, x), T(1.0, y)], 0.0),
            MOI.EqualTo(0.0),
        )

        data = NLPDiagnostics.structural_graph_data(model)
        @test data.complete
        @test length(data.variables) == 2
        @test length(data.constraints) == 2
        @test length(data.edges) == 3
        @test [node.dm_region for node in data.variables] == [:well, :well]
        @test [node.block for node in data.variables] == [1, 2]
        @test count(edge -> edge.matched, data.edges) == 2

        text = NLPDiagnostics.structural_graph_text(data)
        @test occursin("Structural graph with 2 variables", text)
        @test occursin("source", text)
        @test occursin("reference", text)
        @test occursin("[matched]", text)

        dot = NLPDiagnostics.structural_graph_dot(data)
        @test startswith(dot, "graph NLPDiagnostics {")
        @test occursin("v1 -- c1", dot)
        @test occursin("penwidth=2.5", dot)
        @test occursin("DM=well", dot)
    end

    @testset "overdetermined equality matching and DM partition" begin
        model = new_model()
        x = MOI.add_variable(model)
        MOI.set(model, MOI.VariableName(), x, "x")
        F = MOI.ScalarAffineFunction{Float64}
        T = MOI.ScalarAffineTerm{Float64}
        f = F([T(1.0, x)], 0.0)
        MOI.add_constraint(model, f, MOI.EqualTo(0.0))
        MOI.add_constraint(model, f, MOI.EqualTo(1.0))

        graph = NLPDiagnostics.incidence_graph(model)
        matching = NLPDiagnostics.maximum_matching(graph)
        @test NLPDiagnostics.matching_cardinality(matching) == 1
        @test matching.variable_match == [1]
        @test matching.constraint_match == [1, 0]
        partition = NLPDiagnostics.dulmage_mendelsohn(
            graph;
            matching = matching,
        )
        @test partition.overdetermined_variables == [1]
        @test partition.overdetermined_constraints == [1, 2]
        @test isempty(partition.well_determined_constraints)
        @test isempty(partition.underdetermined_variables)

        report = NLPDiagnostics.analyze(model)
        @test length(findings(report, :unmatched_structural_equations)) == 1
        @test length(findings(report, :overdetermined_equality_partition)) == 1
    end

    @testset "fixed variables are excluded from matching" begin
        model = new_model()
        x, y = MOI.add_variables(model, 2)
        MOI.add_constraint(model, x, MOI.EqualTo(2.0))
        F = MOI.ScalarAffineFunction{Float64}
        T = MOI.ScalarAffineTerm{Float64}
        MOI.add_constraint(
            model,
            F([T(1.0, x), T(1.0, y)], 0.0),
            MOI.EqualTo(0.0),
        )

        graph = NLPDiagnostics.incidence_graph(model)
        matching = NLPDiagnostics.maximum_matching(graph)
        @test matching.eligible_variable_positions == [2]
        @test NLPDiagnostics.matching_cardinality(matching) == 1
        @test matching.variable_match == [0, 1]
        partition = NLPDiagnostics.dulmage_mendelsohn(graph)
        @test partition.well_determined_variables == [2]
        @test partition.well_determined_constraints == [1]
        report = NLPDiagnostics.analyze(model)
        @test isempty(findings(report, :unmatched_structural_variables))
        @test isempty(findings(report, :unmatched_structural_equations))
    end

    @testset "inequalities are excluded from default matching" begin
        model = new_model()
        x = MOI.add_variable(model)
        F = MOI.ScalarAffineFunction{Float64}
        T = MOI.ScalarAffineTerm{Float64}
        MOI.add_constraint(
            model,
            F([T(1.0, x)], 0.0),
            MOI.LessThan(1.0),
        )
        graph = NLPDiagnostics.incidence_graph(model)
        @test only(graph.constraint_nodes).role ==
              NLPDiagnostics.InequalityConstraint
        matching = NLPDiagnostics.maximum_matching(graph)
        @test isempty(matching.eligible_constraint_positions)
        @test matching.eligible_variable_positions == [1]
        report = NLPDiagnostics.analyze(model)
        finding = only(findings(report, :unmatched_structural_variables))
        @test evidence_details(finding)["scope"] ==
              "free variables and equality nodes only"
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
        @test NLPDiagnostics.maximum_matching(model) isa
              NLPDiagnostics.StructuralMatching
        @test NLPDiagnostics.dulmage_mendelsohn(model) isa
              NLPDiagnostics.DulmageMendelsohnPartition
        @test NLPDiagnostics.well_determined_blocks(model) isa
              Vector{NLPDiagnostics.DulmageMendelsohnBlock}
        @test NLPDiagnostics.structural_graph_data(model) isa
              NLPDiagnostics.StructuralGraphData
        @test occursin(
            "Structural graph",
            NLPDiagnostics.structural_graph_text(model),
        )
        @test startswith(
            NLPDiagnostics.structural_graph_dot(model),
            "graph NLPDiagnostics {",
        )
    end

    @testset "text report" begin
        report = NLPDiagnostics.DiagnosticReport()
        text = sprint(show, MIME"text/plain"(), report)
        @test occursin("0 findings", text)
    end
end
