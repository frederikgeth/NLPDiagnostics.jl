# Intentionally broken models are the primary regression-test style.
using Test

import JuMP
import MathOptInterface as MOI
import NLPDiagnostics

const MOIU = MOI.Utilities

mutable struct TestNLPEvaluator <: MOI.AbstractNLPEvaluator
    initialize_count::Int
    requested::Vector{Symbol}
end

TestNLPEvaluator() = TestNLPEvaluator(0, Symbol[])

MOI.features_available(::TestNLPEvaluator) = [:Grad, :Jac, :Hess]

function MOI.initialize(evaluator::TestNLPEvaluator, requested::Vector{Symbol})
    evaluator.initialize_count += 1
    evaluator.requested = copy(requested)
    return
end

MOI.eval_objective(::TestNLPEvaluator, x) = x[1]^2 + x[2]

function MOI.eval_objective_gradient(::TestNLPEvaluator, gradient, x)
    gradient .= [2 * x[1], 1]
    return
end

function MOI.eval_constraint(::TestNLPEvaluator, values, x)
    values .= [x[1] + x[2], x[2]^2]
    return
end

MOI.jacobian_structure(::TestNLPEvaluator) =
    [(1, 1), (1, 1), (1, 2), (2, 2)]

function MOI.eval_constraint_jacobian(::TestNLPEvaluator, values, x)
    # The two (1, 1) entries are additive and deliberately duplicated.
    values .= [0.25, 0.75, 1.0, 2 * x[2]]
    return
end

MOI.hessian_lagrangian_structure(::TestNLPEvaluator) =
    [(1, 1), (2, 2), (2, 2)]

function MOI.eval_hessian_lagrangian(::TestNLPEvaluator, values, x, sigma, mu)
    # The two (2, 2) entries are additive, as permitted by MOI.
    values .= [2 * sigma, mu[2], mu[2]]
    return
end

function new_model()
    return MOIU.UniversalFallback(MOIU.Model{Float64}())
end

function findings(report, code)
    return filter(finding -> finding.code == code, report.findings)
end

function evidence_details(finding)
    return Dict(finding.evidence[1].details)
end

function NLPDiagnostics.operator_interval(
    ::Val{:positive_output},
    arguments::Vector{NLPDiagnostics.IntervalEnclosure},
    original_arguments,
)
    return NLPDiagnostics.IntervalEnclosure(1.0, Inf, true, true)
end

function NLPDiagnostics.operator_domain_requirements(
    ::Val{:positive_only},
    original_arguments,
    intervals::Vector{NLPDiagnostics.IntervalEnclosure},
)
    interval = intervals[1]
    assessment = if interval.upper <= 0
        NLPDiagnostics.DomainProvenViolation
    elseif interval.lower <= 0
        NLPDiagnostics.DomainPossibleViolation
    else
        NLPDiagnostics.DomainSafe
    end
    return [
        NLPDiagnostics.OperatorDomainRequirement(
            1,
            assessment,
            "argument > 0 for positive_only",
        ),
    ]
end

function NLPDiagnostics.operator_derivative_requirements(
    ::Val{:positive_derivative_only},
    original_arguments,
    intervals::Vector{NLPDiagnostics.IntervalEnclosure},
)
    interval = intervals[1]
    assessment = if interval.upper <= 0
        NLPDiagnostics.DomainProvenViolation
    elseif interval.lower <= 0
        NLPDiagnostics.DomainPossibleViolation
    else
        NLPDiagnostics.DomainSafe
    end
    return [
        NLPDiagnostics.OperatorDerivativeRequirement(
            1,
            1,
            assessment,
            "argument > 0 for the registered derivative",
            interval,
        ),
    ]
end

function NLPDiagnostics.coupled_set_activity(
    ::MOI.ExponentialCone,
    source::NLPDiagnostics.EntityRef,
    values::Vector{Union{Missing,T}},
    feasibility::T,
    active::T,
) where {T<:AbstractFloat}
    return NLPDiagnostics.CoupledSetActivity{T}(
        source,
        :test_exponential_cone,
        values,
        one(T),
        zero(T),
        false,
        :interior,
    )
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

    @testset "proven, possible, and safe logarithm domains" begin
        proven_model = new_model()
        x = MOI.add_variable(proven_model)
        MOI.set(proven_model, MOI.VariableName(), x, "x")
        MOI.add_constraint(proven_model, x, MOI.LessThan(-1.0))
        log_x = MOI.ScalarNonlinearFunction(:log, Any[x])
        MOI.add_constraint(proven_model, log_x, MOI.LessThan(0.0))
        proven_report = NLPDiagnostics.analyze(proven_model)
        proven = only(
            findings(
                proven_report,
                :proven_expression_domain_violation,
            ),
        )
        @test proven.severity == NLPDiagnostics.SeverityError
        @test evidence_details(proven)["argument_interval"] ==
              "[-Inf, -1.0]"
        @test proven_report.metadata[:proven_domain_violation_count] == "1"

        possible_model = new_model()
        x = MOI.add_variable(possible_model)
        MOI.add_constraint(possible_model, x, MOI.Interval(-1.0, 2.0))
        log_x = MOI.ScalarNonlinearFunction(:log, Any[x])
        MOI.add_constraint(possible_model, log_x, MOI.LessThan(0.0))
        possible = only(
            findings(
                NLPDiagnostics.analyze(possible_model),
                :possible_expression_domain_violation,
            ),
        )
        @test possible.basis == NLPDiagnostics.HeuristicInterpretation
        @test possible.confidence == NLPDiagnostics.ConfidenceHigh
        @test evidence_details(possible)["required_domain"] ==
              "argument > 0"

        safe_model = new_model()
        x = MOI.add_variable(safe_model)
        MOI.add_constraint(safe_model, x, MOI.GreaterThan(1.0))
        log_x = MOI.ScalarNonlinearFunction(:log, Any[x])
        MOI.add_constraint(safe_model, log_x, MOI.LessThan(1.0))
        @test isempty(NLPDiagnostics.domain_issues(safe_model))
    end

    @testset "square root and quadratic interval propagation" begin
        possible_model = new_model()
        x = MOI.add_variable(possible_model)
        MOI.add_constraint(possible_model, x, MOI.Interval(-1.0, 4.0))
        sqrt_x = MOI.ScalarNonlinearFunction(:sqrt, Any[x])
        MOI.add_constraint(possible_model, sqrt_x, MOI.LessThan(3.0))
        issue = only(NLPDiagnostics.domain_issues(possible_model))
        @test issue.assessment == NLPDiagnostics.DomainPossibleViolation
        @test issue.requirement == "argument ≥ 0"

        proven_model = new_model()
        x = MOI.add_variable(proven_model)
        MOI.add_constraint(proven_model, x, MOI.LessThan(-1.0))
        sqrt_x = MOI.ScalarNonlinearFunction(:sqrt, Any[x])
        MOI.add_constraint(proven_model, sqrt_x, MOI.LessThan(0.0))
        @test only(NLPDiagnostics.domain_issues(proven_model)).assessment ==
              NLPDiagnostics.DomainProvenViolation

        quadratic_model = new_model()
        x = MOI.add_variable(quadratic_model)
        MOI.add_constraint(quadratic_model, x, MOI.Interval(-1.0, 1.0))
        Q = MOI.ScalarQuadraticTerm{Float64}
        quadratic = MOI.ScalarQuadraticFunction(
            [Q(2.0, x, x)],
            MOI.ScalarAffineTerm{Float64}[],
            0.0,
        )
        sqrt_x_squared = MOI.ScalarNonlinearFunction(
            :sqrt,
            Any[quadratic],
        )
        MOI.add_constraint(
            quadratic_model,
            sqrt_x_squared,
            MOI.LessThan(2.0),
        )
        @test isempty(NLPDiagnostics.domain_issues(quadratic_model))
    end

    @testset "division and inverse domains" begin
        proven_model = new_model()
        x, denominator = MOI.add_variables(proven_model, 2)
        MOI.add_constraint(
            proven_model,
            denominator,
            MOI.EqualTo(0.0),
        )
        quotient = MOI.ScalarNonlinearFunction(
            :/,
            Any[x, denominator],
        )
        MOI.add_constraint(proven_model, quotient, MOI.LessThan(1.0))
        issue = only(NLPDiagnostics.domain_issues(proven_model))
        @test issue.assessment == NLPDiagnostics.DomainProvenViolation
        @test issue.argument == 2
        @test issue.requirement == "denominator ≠ 0"

        possible_model = new_model()
        denominator = MOI.add_variable(possible_model)
        MOI.add_constraint(
            possible_model,
            denominator,
            MOI.Interval(-1.0, 1.0),
        )
        inverse = MOI.ScalarNonlinearFunction(:inv, Any[denominator])
        MOI.add_constraint(possible_model, inverse, MOI.LessThan(1.0))
        issue = only(NLPDiagnostics.domain_issues(possible_model))
        @test issue.assessment == NLPDiagnostics.DomainPossibleViolation
    end

    @testset "integer and fractional power domains" begin
        fractional_model = new_model()
        x = MOI.add_variable(fractional_model)
        MOI.add_constraint(fractional_model, x, MOI.LessThan(-1.0))
        root = MOI.ScalarNonlinearFunction(:^, Any[x, 0.5])
        MOI.add_constraint(fractional_model, root, MOI.LessThan(1.0))
        fractional_issue = only(
            NLPDiagnostics.domain_issues(fractional_model),
        )
        @test fractional_issue.assessment ==
              NLPDiagnostics.DomainProvenViolation
        @test fractional_issue.requirement ==
              "base ≥ 0 for a non-integer exponent"

        negative_model = new_model()
        x = MOI.add_variable(negative_model)
        MOI.add_constraint(negative_model, x, MOI.EqualTo(0.0))
        reciprocal = MOI.ScalarNonlinearFunction(:^, Any[x, -1])
        MOI.add_constraint(negative_model, reciprocal, MOI.LessThan(1.0))
        negative_issue = only(
            NLPDiagnostics.domain_issues(negative_model),
        )
        @test negative_issue.assessment ==
              NLPDiagnostics.DomainProvenViolation
        @test occursin("negative integer", negative_issue.requirement)

        integer_model = new_model()
        x = MOI.add_variable(integer_model)
        MOI.add_constraint(integer_model, x, MOI.Interval(-2.0, 2.0))
        square = MOI.ScalarNonlinearFunction(:^, Any[x, 2])
        MOI.add_constraint(integer_model, square, MOI.LessThan(4.0))
        @test isempty(NLPDiagnostics.domain_issues(integer_model))
    end

    @testset "expression paths and vector-row provenance" begin
        nested_model = new_model()
        x, y = MOI.add_variables(nested_model, 2)
        MOI.add_constraint(nested_model, y, MOI.LessThan(-1.0))
        log_y = MOI.ScalarNonlinearFunction(:log, Any[y])
        expression = MOI.ScalarNonlinearFunction(:+, Any[x, log_y])
        MOI.add_constraint(nested_model, expression, MOI.LessThan(0.0))
        nested_issue = only(NLPDiagnostics.domain_issues(nested_model))
        @test nested_issue.path.arguments == [2]
        @test occursin("/arg[2]", sprint(show, nested_issue.path))

        vector_model = new_model()
        x, y = MOI.add_variables(vector_model, 2)
        MOI.add_constraint(vector_model, x, MOI.LessThan(-1.0))
        MOI.add_constraint(vector_model, y, MOI.Interval(-1.0, 1.0))
        rows = MOI.VectorNonlinearFunction(
            [
                MOI.ScalarNonlinearFunction(:log, Any[x]),
                MOI.ScalarNonlinearFunction(:sqrt, Any[y]),
            ],
        )
        MOI.add_constraint(vector_model, rows, MOI.Nonpositives(2))
        issues = NLPDiagnostics.domain_issues(vector_model)
        @test length(issues) == 2
        @test [issue.path.source.subindex for issue in issues] == [1, 2]
        @test [issue.assessment for issue in issues] == [
            NLPDiagnostics.DomainProvenViolation,
            NLPDiagnostics.DomainPossibleViolation,
        ]
    end

    @testset "constant objective and constraint domain handling" begin
        objective_model = new_model()
        bad_objective = MOI.ScalarNonlinearFunction(:log, Any[-1.0])
        MOI.set(objective_model, MOI.ObjectiveSense(), MOI.MIN_SENSE)
        MOI.set(
            objective_model,
            MOI.ObjectiveFunction{MOI.ScalarNonlinearFunction}(),
            bad_objective,
        )
        issue = only(NLPDiagnostics.domain_issues(objective_model))
        @test issue.path.source.kind == :objective
        @test issue.assessment == NLPDiagnostics.DomainProvenViolation

        constraint_model = new_model()
        bad_constraint = MOI.ScalarNonlinearFunction(:log, Any[-1.0])
        MOI.add_constraint(
            constraint_model,
            bad_constraint,
            MOI.LessThan(0.0),
        )
        report = NLPDiagnostics.analyze(constraint_model)
        @test length(findings(report, :constant_domain_violation)) == 1
        @test isempty(
            findings(report, :proven_expression_domain_violation),
        )
    end

    @testset "custom operator domain extension hooks" begin
        range_model = new_model()
        x = MOI.add_variable(range_model)
        positive = MOI.ScalarNonlinearFunction(
            :positive_output,
            Any[x],
        )
        log_positive = MOI.ScalarNonlinearFunction(:log, Any[positive])
        MOI.add_constraint(range_model, log_positive, MOI.LessThan(2.0))
        @test isempty(NLPDiagnostics.domain_issues(range_model))

        domain_model = new_model()
        x = MOI.add_variable(domain_model)
        MOI.add_constraint(domain_model, x, MOI.LessThan(-1.0))
        positive_only = MOI.ScalarNonlinearFunction(
            :positive_only,
            Any[x],
        )
        MOI.add_constraint(domain_model, positive_only, MOI.LessThan(2.0))
        issue = only(NLPDiagnostics.domain_issues(domain_model))
        @test issue.assessment == NLPDiagnostics.DomainProvenViolation
        @test issue.requirement == "argument > 0 for positive_only"

        opaque_model = new_model()
        x = MOI.add_variable(opaque_model)
        opaque = MOI.ScalarNonlinearFunction(:opaque_range, Any[x])
        log_opaque = MOI.ScalarNonlinearFunction(:log, Any[opaque])
        MOI.add_constraint(opaque_model, log_opaque, MOI.LessThan(2.0))
        finding = only(
            findings(
                NLPDiagnostics.analyze(opaque_model),
                :possible_expression_domain_violation,
            ),
        )
        @test finding.confidence == NLPDiagnostics.ConfidenceMedium
        @test evidence_details(finding)["interval_informative"] == "false"
    end

    @testset "domain intervals preserve non-Float64 bounds" begin
        model = MOIU.UniversalFallback(MOIU.Model{BigFloat}())
        x = MOI.add_variable(model)
        lower = big"1e-1000"
        MOI.add_constraint(model, x, MOI.GreaterThan(lower))
        log_x = MOI.ScalarNonlinearFunction(:log, Any[x])
        MOI.add_constraint(model, log_x, MOI.LessThan(big"1.0"))
        @test isempty(NLPDiagnostics.domain_issues(model))
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
        JuMP.set_start_value(x, 0.5)
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
        point = NLPDiagnostics.evaluation_point(
            model,
            [0.5];
            label = "JuMP point",
        )
        numerical = NLPDiagnostics.evaluate_numerical(model, point)
        @test numerical.point == point
        @test !isempty(numerical.constraint_values)
        @test NLPDiagnostics.initialization_point(model) !== nothing
        @test NLPDiagnostics.analyze_initialization(model) isa
              NLPDiagnostics.DiagnosticReport
    end

    @testset "evaluation points preserve variable order" begin
        model = new_model()
        x, y = MOI.add_variables(model, 2)
        point = NLPDiagnostics.evaluation_point(
            model,
            Dict(y => 3.0, x => 2.0);
            label = "initial",
        )
        @test point.variables == [x, y]
        @test point.values == [2.0, 3.0]
        @test point.label == "initial"
        @test_throws DimensionMismatch NLPDiagnostics.EvaluationPoint(
            [x],
            [1.0, 2.0],
        )
        @test_throws ArgumentError NLPDiagnostics.evaluation_point(
            model,
            Dict(x => 2.0),
        )
    end

    @testset "symbolic values finite differences cache and scaling" begin
        model = new_model()
        x, y = MOI.add_variables(model, 2)
        objective = MOI.ScalarNonlinearFunction(
            :+,
            Any[
                MOI.ScalarNonlinearFunction(:^, Any[x, 2]),
                y,
            ],
        )
        MOI.set(model, MOI.ObjectiveSense(), MOI.MIN_SENSE)
        MOI.set(
            model,
            MOI.ObjectiveFunction{MOI.ScalarNonlinearFunction}(),
            objective,
        )
        F = MOI.ScalarAffineFunction{Float64}
        T = MOI.ScalarAffineTerm{Float64}
        MOI.add_constraint(
            model,
            F([T(1.0e-6, x)], 0.0),
            MOI.EqualTo(0.0),
        )
        MOI.add_constraint(
            model,
            F([T(1.0e6, y)], 0.0),
            MOI.EqualTo(0.0),
        )
        point = NLPDiagnostics.evaluation_point(
            model,
            [2.0, 3.0];
            label = "scaling probe",
        )
        cache = NLPDiagnostics.EvaluationCache()
        evaluation =
            NLPDiagnostics.evaluate_numerical(model, point; cache = cache)
        @test evaluation.objective_value ≈ 7.0
        @test evaluation.objective_gradient ≈ [4.0, 1.0] rtol = 1.0e-5
        @test evaluation.constraint_values ≈ [2.0e-6, 3.0e6]
        @test evaluation.jacobian_row_methods == fill(:exact_symbolic, 2)
        summary = NLPDiagnostics.jacobian_scale_summary(evaluation)
        @test summary.row_norms ≈ [1.0e-6, 1.0e6] rtol = 1.0e-5
        @test summary.column_norms ≈ [1.0e-6, 1.0e6] rtol = 1.0e-5
        @test summary.row_scale_ratio ≈ 1.0e12 rtol = 1.0e-4
        @test summary.column_scale_ratio ≈ 1.0e12 rtol = 1.0e-4
        @test cache.misses == 1
        @test cache.hits == 0
        NLPDiagnostics.evaluate_numerical(model, point; cache = cache)
        @test cache.hits == 1
        @test cache.misses == 1
        generation = cache.generation
        empty!(cache)
        @test cache.generation == generation + 1
        @test isempty(cache.entries)

        report = NLPDiagnostics.analyze_numerical(
            model,
            point;
            cache = cache,
        )
        @test length(findings(report, :large_jacobian_row_scale_spread)) ==
              1
        @test length(findings(report, :large_jacobian_column_scale_spread)) ==
              1
        @test report.metadata[:evaluation_point_label] == "scaling probe"
        combined = NLPDiagnostics.analyze(model; point = point, cache = cache)
        @test combined.metadata[:stages] ==
              "static,domains,derivatives,expressions,structural,numerical"
    end

    @testset "constructed MOI nonlinear evaluator supplies exact first derivatives" begin
        model = new_model()
        x = MOI.add_variable(model)
        objective = MOI.ScalarNonlinearFunction(:sin, Any[x])
        constraint = MOI.ScalarNonlinearFunction(:exp, Any[x])
        MOI.set(model, MOI.ObjectiveSense(), MOI.MIN_SENSE)
        MOI.set(
            model,
            MOI.ObjectiveFunction{MOI.ScalarNonlinearFunction}(),
            objective,
        )
        MOI.add_constraint(model, constraint, MOI.EqualTo(0.0))
        evaluation = NLPDiagnostics.evaluate_numerical(
            model,
            [0.3];
            # Deliberately too coarse for the former finite-difference path.
            relative_step = 0.1,
        )
        @test evaluation.objective_gradient ≈ [cos(0.3)] atol = 1.0e-12
        @test evaluation.jacobian_row_methods == [:exact_constructed_nonlinear_ad]
        @test only(evaluation.jacobian_entries).value ≈ exp(0.3) atol = 1.0e-12
        @test evaluation.call_statistics[:constructed_nlp_initialize][1] == 2
        @test evaluation.call_statistics[:constructed_nlp_objective_gradient][1] == 2
    end

    @testset "zero Jacobian rows and columns are local inferences" begin
        model = new_model()
        x, y = MOI.add_variables(model, 2)
        square = MOI.ScalarNonlinearFunction(:^, Any[x, 2])
        MOI.add_constraint(model, square, MOI.EqualTo(0.0))
        report = NLPDiagnostics.analyze_numerical(
            model,
            [0.0, 1.0];
            label = "stationary point",
        )
        row_finding = only(findings(report, :zero_jacobian_rows))
        column_finding = only(findings(report, :zero_jacobian_columns))
        @test row_finding.basis == NLPDiagnostics.LocalInference
        @test column_finding.basis == NLPDiagnostics.LocalInference
        @test Dict(row_finding.evidence[2].details)["rows"] == "1"
        @test Dict(column_finding.evidence[2].details)["columns"] == "1,2"
    end

    @testset "exact quadratic derivatives use MOI diagonal semantics" begin
        model = new_model()
        x, y = MOI.add_variables(model, 2)
        Q = MOI.ScalarQuadraticFunction{Float64}
        QT = MOI.ScalarQuadraticTerm{Float64}
        quadratic = Q(
            [
                QT(2.0, x, x),
                QT(3.0, x, y),
            ],
            MOI.ScalarAffineTerm{Float64}[],
            0.0,
        )
        MOI.add_constraint(model, quadratic, MOI.EqualTo(0.0))
        evaluation = NLPDiagnostics.evaluate_numerical(model, [2.0, 4.0])
        @test evaluation.constraint_values == [28.0]
        @test evaluation.jacobian_row_methods == [:exact_symbolic]
        @test [entry.value for entry in evaluation.jacobian_entries] ==
              [16.0, 6.0]
    end

    @testset "guarded Jacobian rank distinguishes scale from deficiency" begin
        model = new_model()
        x, y = MOI.add_variables(model, 2)
        F = MOI.ScalarAffineFunction{Float64}
        T = MOI.ScalarAffineTerm{Float64}
        MOI.add_constraint(model, F([T(1.0, x), T(1.0, y)], 0.0), MOI.EqualTo(0.0))
        MOI.add_constraint(model, F([T(2.0, x), T(2.0, y)], 0.0), MOI.EqualTo(0.0))
        evaluation = NLPDiagnostics.evaluate_numerical(model, [0.0, 0.0])
        estimate = NLPDiagnostics.jacobian_rank_estimate(evaluation)
        @test estimate.available
        @test estimate.rank == 1
        @test estimate.left_nullity == 1
        @test estimate.right_nullity == 1
        @test maximum(abs, [1.0 1.0; 2.0 2.0] * estimate.right_nullspace) < 1.0e-10
        report = NLPDiagnostics.analyze_numerical(model, [0.0, 0.0])
        @test length(findings(report, :numerical_jacobian_rank_deficiency)) == 1
        sparse = NLPDiagnostics.sparse_jacobian_pattern_estimate(evaluation)
        @test sparse.available
        # Pattern matching cannot see the numerical dependence of two
        # proportional rows, but it can prove a zero-column deficiency.
        @test sparse.rank_upper_bound == 2

        zero_column_model = new_model()
        r, s = MOI.add_variables(zero_column_model, 2)
        zero_column_function = F([T(1.0, r)], 0.0)
        MOI.add_constraint(
            zero_column_model,
            zero_column_function,
            MOI.EqualTo(0.0),
        )
        MOI.add_constraint(
            zero_column_model,
            zero_column_function,
            MOI.EqualTo(0.0),
        )
        zero_column_evaluation = NLPDiagnostics.evaluate_numerical(
            zero_column_model,
            [0.0, 0.0],
        )
        zero_column_bound = NLPDiagnostics.sparse_jacobian_pattern_estimate(
            zero_column_evaluation,
        )
        @test zero_column_bound.rank_upper_bound == 1
        guarded_report = NLPDiagnostics.analyze_numerical(
            zero_column_model,
            [0.0, 0.0];
            rank_max_dense_entries = 1,
        )
        @test !parse(Bool, guarded_report.metadata[:jacobian_rank_available])
        @test length(
            findings(guarded_report, :sparse_jacobian_pattern_rank_deficiency),
        ) == 1

        scaled_model = new_model()
        a, b = MOI.add_variables(scaled_model, 2)
        MOI.add_constraint(scaled_model, a, MOI.EqualTo(0.0))
        MOI.add_constraint(
            scaled_model,
            MOI.ScalarAffineFunction([T(1.0e-10, b)], 0.0),
            MOI.EqualTo(0.0),
        )
        scaled_evaluation = NLPDiagnostics.evaluate_numerical(scaled_model, [0.0, 0.0])
        unscaled = NLPDiagnostics.jacobian_rank_estimate(
            scaled_evaluation;
            relative_tolerance = 1.0e-6,
        )
        normalized = NLPDiagnostics.jacobian_rank_estimate(
            scaled_evaluation;
            scaling = :row_column,
            relative_tolerance = 1.0e-6,
        )
        @test unscaled.rank == 1
        @test normalized.rank == 2
        scaled_report = NLPDiagnostics.analyze_numerical(
            scaled_model,
            [0.0, 0.0];
            rank_relative_tolerance = 1.0e-6,
        )
        @test length(findings(scaled_report, :jacobian_rank_scaling_sensitive)) == 1
    end

    @testset "structural and numerical rank comparison stays nonphysical" begin
        underdetermined = new_model()
        x, y = MOI.add_variables(underdetermined, 2)
        F = MOI.ScalarAffineFunction{Float64}
        T = MOI.ScalarAffineTerm{Float64}
        MOI.add_constraint(
            underdetermined,
            F([T(1.0, x), T(-1.0, y)], 0.0),
            MOI.EqualTo(0.0),
        )
        expected = NLPDiagnostics.structural_numerical_comparison(
            underdetermined,
            [0.0, 0.0],
        )
        @test expected.available
        @test expected.structural_matching_rank == 1
        @test expected.structural_right_nullity == 1
        @test expected.numerical_rank == 1
        report = NLPDiagnostics.analyze_degeneracy(underdetermined, [0.0, 0.0])
        @test length(findings(report, :structurally_expected_local_nullspace)) == 1
        @test length(
            findings(report, :candidate_uniform_coordinate_shift_null_mode),
        ) == 1
        common_shift = NLPDiagnostics.ExpectedNullspaceMode(
            :common_shift,
            [x, y],
            [1.0, 1.0];
            description = "common reference-coordinate shift",
        )
        expected_mode_report = NLPDiagnostics.analyze_degeneracy(
            underdetermined,
            [0.0, 0.0];
            expected_modes = [common_shift],
        )
        @test length(
            findings(expected_mode_report, :expected_nullspace_mode_observed),
        ) == 1
        fixed_difference = NLPDiagnostics.ExpectedNullspaceMode(
            :fixed_difference,
            [x, y],
            [1.0, -1.0],
        )
        mismatch_report = NLPDiagnostics.analyze_degeneracy(
            underdetermined,
            [0.0, 0.0];
            expected_modes = [fixed_difference],
        )
        @test length(
            findings(mismatch_report, :expected_nullspace_mode_not_observed),
        ) == 1

        stationary = new_model()
        z = MOI.add_variable(stationary)
        MOI.add_constraint(
            stationary,
            MOI.ScalarNonlinearFunction(:^, Any[z, 2]),
            MOI.EqualTo(0.0),
        )
        local_loss = NLPDiagnostics.analyze_degeneracy(stationary, [0.0])
        finding = only(findings(local_loss, :unexpected_local_rank_loss))
        @test finding.domain == NLPDiagnostics.NumericalIssue
        @test finding.basis == NLPDiagnostics.LocalInference
        @test length(findings(local_loss, :unknown_local_degeneracy_mode)) == 1
        @test local_loss.metadata[:generic_nullspace_fingerprint_count] == "0"
        combined = NLPDiagnostics.analyze(
            stationary;
            point = NLPDiagnostics.evaluation_point(stationary, [0.0]),
            check_degeneracy = true,
        )
        @test occursin("degeneracy", combined.metadata[:stages])

        duplicate_rows = new_model()
        q = MOI.add_variable(duplicate_rows)
        q_expression = F([T(1.0, q)], 0.0)
        twice_q_expression = F([T(2.0, q)], 0.0)
        MOI.add_constraint(duplicate_rows, q_expression, MOI.EqualTo(0.0))
        MOI.add_constraint(duplicate_rows, twice_q_expression, MOI.EqualTo(0.0))
        dependency = NLPDiagnostics.analyze_degeneracy(duplicate_rows, [0.0])
        @test length(
            findings(dependency, :candidate_two_row_equation_dependence),
        ) == 1
        @test isempty(findings(dependency, :unknown_local_degeneracy_mode))
    end

    @testset "profile cases retain formulation evidence and provenance" begin
        model = new_model()
        x = MOI.add_variable(model)
        MOI.add_constraint(model, x, MOI.EqualTo(0.0))
        point = NLPDiagnostics.evaluation_point(
            model,
            [0.0];
            label = "flat start",
        )
        case = NLPDiagnostics.ProfileCase(
            "unit equality",
            point;
            formulation = "toy-affine",
            initialization = "flat start",
            scale = "unit",
            solver = "Ipopt",
            expected_evidence = [:structural_numerical_rank_agreement],
            tags = [:regression, :profile],
            metadata = Dict("network" => "none"),
        )
        cache = NLPDiagnostics.EvaluationCache()
        result = NLPDiagnostics.profile_case(model, case; cache = cache)
        @test result.case.name == "unit equality"
        @test result.case.formulation == "toy-affine"
        @test result.case.solver == "Ipopt"
        @test result.case.metadata["network"] == "none"
        @test result.evaluation.point == point
        @test result.callback_statistics[:symbolic_stage][1] == 1
        @test result.derivative_row_method_counts[:exact_symbolic] == 1
        @test result.capability_source_counts[:symbolic] == 1
        @test result.cache_misses == 1
        @test result.cache_hits >= 1
        @test all(value -> value >= 0.0, values(result.stage_seconds))
        @test length(
            findings(result.degeneracy_report, :structural_numerical_rank_agreement),
        ) == 1
        aggregate = NLPDiagnostics.profile_case_repeated(
            model,
            case;
            repetitions = 2,
            warmup = true,
        )
        @test aggregate.warmup_performed
        @test length(aggregate.runs) == 2
        evaluation_timing = aggregate.stage_timing[:evaluation]
        @test evaluation_timing.sample_count == 2
        @test evaluation_timing.minimum <= evaluation_timing.mean <=
              evaluation_timing.maximum
        @test evaluation_timing.standard_deviation >= 0.0
        stable_rank = only(filter(
            item -> item.stage == :degeneracy &&
                    item.code == :structural_numerical_rank_agreement,
            aggregate.finding_stability,
        ))
        @test stable_rank.occurrence_count == 2
        @test stable_rank.fraction == 1.0
        @test_throws ArgumentError NLPDiagnostics.profile_case_repeated(
            model,
            case;
            repetitions = 0,
        )
    end

    @testset "explicit activity, LICQ, and MFCQ screens" begin
        model = new_model()
        x, y = MOI.add_variables(model, 2)
        MOI.add_constraint(model, x, MOI.EqualTo(0.0))
        MOI.add_constraint(model, y, MOI.GreaterThan(0.0))
        evaluation = NLPDiagnostics.evaluate_numerical(
            model,
            [0.0, 1.0e-8];
            relative_step = 1.0e-6,
        )
        summary = NLPDiagnostics.constraint_feasibility_summary(
            model,
            evaluation;
            feasibility_tolerance = 1.0e-7,
            active_tolerance = 1.0e-7,
        )
        @test summary.complete
        @test [activity.classification for activity in summary.activities] ==
              [:equality, :active_lower]
        @test NLPDiagnostics.active_constraint_rows(summary) == [1, 2]
        screen = NLPDiagnostics.mfcq_screen(
            evaluation,
            summary;
            strict_tolerance = 1.0e-10,
        )
        @test screen.available
        @test screen.direction_found
        report = NLPDiagnostics.analyze_active_set(
            model,
            evaluation;
            feasibility_tolerance = 1.0e-7,
            active_tolerance = 1.0e-7,
            mfcq_strict_tolerance = 1.0e-10,
        )
        @test isempty(findings(report, :active_constraint_licq_failure))
        @test length(findings(report, :mfcq_common_descent_direction_found)) == 1
        combined = NLPDiagnostics.analyze(
            model;
            point = evaluation.point,
            check_active_set = true,
        )
        @test occursin("active_set", combined.metadata[:stages])

        infeasible = NLPDiagnostics.analyze_active_set(
            model,
            [0.0, -0.1];
            feasibility_tolerance = 1.0e-7,
            active_tolerance = 1.0e-7,
        )
        @test length(findings(infeasible, :constraint_feasibility_violation)) == 1

        dependent = new_model()
        z = MOI.add_variable(dependent)
        F = MOI.ScalarAffineFunction{Float64}
        T = MOI.ScalarAffineTerm{Float64}
        z_expression = F([T(1.0, z)], 0.0)
        MOI.add_constraint(dependent, z_expression, MOI.EqualTo(0.0))
        MOI.add_constraint(dependent, z_expression, MOI.GreaterThan(0.0))
        dependent_report = NLPDiagnostics.analyze_active_set(
            dependent,
            [0.0];
            active_tolerance = 1.0e-7,
        )
        @test length(findings(dependent_report, :active_constraint_licq_failure)) == 1

        dual_model = new_model()
        d = MOI.add_variable(dual_model)
        F = MOI.ScalarAffineFunction{Float64}
        T = MOI.ScalarAffineTerm{Float64}
        expression = F([T(1.0, d)], 0.0)
        MOI.set(dual_model, MOI.ObjectiveSense(), MOI.MIN_SENSE)
        MOI.set(dual_model, MOI.ObjectiveFunction{F}(), expression)
        MOI.add_constraint(dual_model, expression, MOI.EqualTo(1.0))
        MOI.add_constraint(dual_model, expression, MOI.GreaterThan(1.0))
        dual_evaluation = NLPDiagnostics.evaluate_numerical(dual_model, [1.0])
        dual_summary = NLPDiagnostics.constraint_feasibility_summary(dual_model, dual_evaluation)
        recovery = NLPDiagnostics.recover_stationarity_multipliers(
            dual_model,
            dual_evaluation,
            dual_summary,
        )
        @test recovery.available
        @test !recovery.unique
        @test recovery.stationarity_residual_norm ≈ 0.0 atol = 1.0e-12
        active_matching = NLPDiagnostics.active_set_matching(
            dual_model,
            dual_evaluation,
            dual_summary,
        )
        @test active_matching.complete
        @test active_matching.selected_rows == [1, 2]
        @test NLPDiagnostics.matching_cardinality(active_matching.matching) == 1
        dual_report = NLPDiagnostics.analyze_active_set(dual_model, dual_evaluation)
        @test length(findings(dual_report, :nonunique_active_multipliers)) == 1
        @test length(
            findings(dual_report, :active_set_structural_overdetermination),
        ) == 1
        @test dual_report.metadata[:active_structural_matching_cardinality] == "1"

        sign_model = new_model()
        sign_variable = MOI.add_variable(sign_model)
        sign_expression = F([T(-1.0, sign_variable)], 0.0)
        MOI.set(sign_model, MOI.ObjectiveSense(), MOI.MIN_SENSE)
        MOI.set(sign_model, MOI.ObjectiveFunction{F}(), sign_expression)
        MOI.add_constraint(sign_model, sign_variable, MOI.GreaterThan(0.0))
        sign_evaluation = NLPDiagnostics.evaluate_numerical(sign_model, [0.0])
        sign_summary = NLPDiagnostics.constraint_feasibility_summary(
            sign_model,
            sign_evaluation,
        )
        sign_recovery = NLPDiagnostics.recover_stationarity_multipliers(
            sign_model,
            sign_evaluation,
            sign_summary,
        )
        @test sign_recovery.inequality_dual_violation ≈ 1.0
        @test sign_recovery.complementarity_residual ≈ 0.0
        sign_report = NLPDiagnostics.analyze_active_set(sign_model, sign_evaluation)
        @test length(
            findings(sign_report, :recovered_active_multiplier_sign_violation),
        ) == 1

        rectangle_model = new_model()
        r1, r2 = MOI.add_variables(rectangle_model, 2)
        MOI.add_constraint(
            rectangle_model,
            MOI.VectorOfVariables([r1, r2]),
            MOI.HyperRectangle([0.0, 1.0], [1.0, 2.0]),
        )
        rectangle_evaluation = NLPDiagnostics.evaluate_numerical(
            rectangle_model,
            [0.0, 1.5],
        )
        rectangle_summary = NLPDiagnostics.constraint_feasibility_summary(
            rectangle_model,
            rectangle_evaluation;
            active_tolerance = 1.0e-7,
        )
        @test rectangle_summary.complete
        @test [activity.classification for activity in rectangle_summary.activities] ==
              [:active_lower, :interior]
        @test NLPDiagnostics.active_constraint_rows(rectangle_summary) == [1]

        cone_model = new_model()
        cone_t, cone_x = MOI.add_variables(cone_model, 2)
        MOI.add_constraint(
            cone_model,
            MOI.VectorOfVariables([cone_t, cone_x]),
            MOI.SecondOrderCone(2),
        )
        cone_evaluation = NLPDiagnostics.evaluate_numerical(cone_model, [1.0, 1.0])
        cone_summary = NLPDiagnostics.coupled_set_feasibility_summary(
            cone_model,
            cone_evaluation,
        )
        @test length(cone_summary.activities) == 1
        @test only(cone_summary.activities).classification == :boundary
        cone_report = NLPDiagnostics.analyze_active_set(cone_model, cone_evaluation)
        @test length(findings(cone_report, :coupled_set_boundary_active)) == 1
        outside_cone = NLPDiagnostics.analyze_active_set(cone_model, [0.0, 1.0])
        @test length(findings(outside_cone, :coupled_set_feasibility_violation)) == 1

        plugin_cone_model = new_model()
        e1, e2, e3 = MOI.add_variables(plugin_cone_model, 3)
        MOI.add_constraint(
            plugin_cone_model,
            MOI.VectorOfVariables([e1, e2, e3]),
            MOI.ExponentialCone(),
        )
        plugin_cone_evaluation = NLPDiagnostics.evaluate_numerical(
            plugin_cone_model,
            [0.0, 1.0, 1.0],
        )
        plugin_cone_summary = NLPDiagnostics.coupled_set_feasibility_summary(
            plugin_cone_model,
            plugin_cone_evaluation,
        )
        @test only(plugin_cone_summary.activities).set_kind == :test_exponential_cone
    end

    @testset "finite-difference and reduced Hessian evidence" begin
        model = new_model()
        x, y = MOI.add_variables(model, 2)
        Q = MOI.ScalarQuadraticFunction{Float64}
        QT = MOI.ScalarQuadraticTerm{Float64}
        objective = Q(
            [QT(2.0, x, x), QT(6.0, y, y)],
            MOI.ScalarAffineTerm{Float64}[],
            0.0,
        )
        MOI.set(model, MOI.ObjectiveSense(), MOI.MIN_SENSE)
        MOI.set(model, MOI.ObjectiveFunction{Q}(), objective)
        hessian = NLPDiagnostics.evaluate_lagrangian_hessian(model, [1.0, 2.0])
        @test hessian.complete
        @test hessian.methods == [:finite_difference_function_values]
        combined = NLPDiagnostics._combined_hessian_matrix(hessian)
        @test combined[1, 1] ≈ 2.0 rtol = 1.0e-6
        @test combined[2, 2] ≈ 6.0 rtol = 1.0e-6

        constrained = new_model()
        u, v, w = MOI.add_variables(constrained, 3)
        MOI.add_constraint(constrained, u, MOI.EqualTo(0.0))
        evaluation = NLPDiagnostics.evaluate_numerical(constrained, [0.0, 0.0, 0.0])
        exact_hessian = NLPDiagnostics.HessianEvaluation(
            evaluation.point,
            1.0,
            [0.0],
            NLPDiagnostics.HessianEntry{Float64}[
                NLPDiagnostics.HessianEntry(1, 1, 1.0),
                NLPDiagnostics.HessianEntry(2, 2, 1.0),
                NLPDiagnostics.HessianEntry(3, 3, 1.0e-12),
            ],
            [:test_exact],
            true,
            NLPDiagnostics.EvaluationFailure[],
        )
        reduced = NLPDiagnostics.reduced_hessian_analysis(
            evaluation,
            exact_hessian;
            active_rows = [1],
        )
        @test reduced.available
        @test reduced.tangent_dimension == 2
        @test reduced.positive_eigenvalues == 2
        @test reduced.condition_estimate ≈ 1.0e12
        report = NLPDiagnostics.analyze_reduced_hessian(
            evaluation,
            exact_hessian;
            active_rows = [1],
        )
        @test length(findings(report, :ill_conditioned_reduced_hessian)) == 1

        flat_model = new_model()
        flat_variable = MOI.add_variable(flat_model)
        flat_objective = MOI.ScalarAffineFunction(
            [MOI.ScalarAffineTerm(1.0, flat_variable)],
            0.0,
        )
        MOI.set(flat_model, MOI.ObjectiveSense(), MOI.MIN_SENSE)
        MOI.set(
            flat_model,
            MOI.ObjectiveFunction{typeof(flat_objective)}(),
            flat_objective,
        )
        flat_evaluation = NLPDiagnostics.evaluate_numerical(flat_model, [0.0])
        flat_report = NLPDiagnostics.analyze_active_set_second_order(
            flat_model,
            flat_evaluation,
        )
        @test flat_report.metadata[:second_order_reduced_hessian_available] == "true"
        @test length(findings(flat_report, :reduced_hessian_flat_directions)) == 1
    end

    @testset "non-unit circular equalities are explicit scaling hints" begin
        model = new_model()
        x, y = MOI.add_variables(model, 2)
        Q = MOI.ScalarQuadraticFunction{Float64}
        QT = MOI.ScalarQuadraticTerm{Float64}
        circle = Q(
            [QT(2.0, x, x), QT(2.0, y, y)],
            MOI.ScalarAffineTerm{Float64}[],
            0.0,
        )
        MOI.add_constraint(model, circle, MOI.EqualTo(4.0))
        finding = only(findings(NLPDiagnostics.analyze_static(model), :nonunit_circular_constraint_radius))
        @test finding.domain == NLPDiagnostics.RepresentationalIssue
        @test finding.basis == NLPDiagnostics.HeuristicInterpretation
        @test Dict(finding.evidence[1].details)["radius"] == "2.0"
    end

    @testset "operating-point domain failures are captured" begin
        model = new_model()
        x = MOI.add_variable(model)
        MOI.add_constraint(
            model,
            MOI.ScalarNonlinearFunction(:log, Any[x]),
            MOI.EqualTo(0.0),
        )
        evaluation = NLPDiagnostics.evaluate_numerical(
            model,
            [-1.0];
            label = "invalid start",
        )
        @test isnan(only(evaluation.constraint_values))
        report = NLPDiagnostics.analyze_numerical(
            model,
            [-1.0];
            label = "invalid start",
        )
        finding =
            first(findings(report, :operating_point_domain_violation))
        @test finding.domain == NLPDiagnostics.MathematicalIssue
        @test finding.basis == NLPDiagnostics.MathematicalProof
        @test finding.confidence == NLPDiagnostics.ConfidenceCertain
    end

    @testset "non-finite values and derivatives remain evidence" begin
        model = new_model()
        x = MOI.add_variable(model)
        explosive = MOI.ScalarNonlinearFunction(:exp, Any[x])
        MOI.set(model, MOI.ObjectiveSense(), MOI.MIN_SENSE)
        MOI.set(
            model,
            MOI.ObjectiveFunction{MOI.ScalarNonlinearFunction}(),
            explosive,
        )
        report = NLPDiagnostics.analyze_numerical(
            model,
            [1000.0];
            label = "overflow probe",
        )
        @test length(findings(report, :nonfinite_objective_value)) == 1
        @test length(findings(report, :nonfinite_objective_gradient)) == 1
    end

    @testset "NLPBlock exact evaluator capabilities and duplicates" begin
        model = new_model()
        MOI.add_variables(model, 2)
        MOI.set(model, MOI.ObjectiveSense(), MOI.MIN_SENSE)
        evaluator = TestNLPEvaluator()
        block = MOI.NLPBlockData(
            MOI.NLPBoundsPair.([0.0, 0.0], [0.0, 0.0]),
            evaluator,
            true,
        )
        MOI.set(model, MOI.NLPBlock(), block)
        capabilities = NLPDiagnostics.evaluator_capabilities(model)
        nlp_capability =
            only(filter(capability -> capability.source == :nlp_block, capabilities))
        @test nlp_capability.available_features == [:Grad, :Jac, :Hess]
        @test nlp_capability.requested_features == [:Grad, :Jac]

        cache = NLPDiagnostics.EvaluationCache()
        point = NLPDiagnostics.evaluation_point(
            model,
            [2.0, 3.0];
            label = "callback point",
        )
        evaluation =
            NLPDiagnostics.evaluate_numerical(model, point; cache = cache)
        @test evaluation.objective_value == 7.0
        @test evaluation.objective_gradient == [4.0, 1.0]
        @test evaluation.constraint_values == [5.0, 9.0]
        @test length(evaluation.jacobian_entries) == 4
        @test evaluation.jacobian_row_methods ==
              fill(:exact_nlp_evaluator, 2)
        summary = NLPDiagnostics.jacobian_scale_summary(evaluation)
        @test summary.row_norms == [1.0, 6.0]
        @test summary.column_norms == [1.0, 6.0]
        @test evaluator.initialize_count == 1
        callback_statistics = NLPDiagnostics.evaluation_call_statistics(evaluation)
        @test callback_statistics[:nlp_initialize][1] == 1
        @test callback_statistics[:nlp_objective_value][1] == 1
        @test callback_statistics[:nlp_objective_gradient][1] == 1
        @test callback_statistics[:nlp_constraint_value][1] == 1
        @test callback_statistics[:nlp_constraint_jacobian][1] == 1
        NLPDiagnostics.evaluate_numerical(model, point; cache = cache)
        @test evaluator.initialize_count == 1
        static_report = NLPDiagnostics.analyze(model)
        @test isempty(findings(static_report, :disconnected_variable))
        @test length(
            findings(
                static_report,
                :variable_incidence_analysis_unavailable,
            ),
        ) == 1
        nan_report = NLPDiagnostics.analyze_numerical(
            model,
            [NaN, 3.0];
            label = "non-finite callback probe",
        )
        @test length(
            findings(nan_report, :nonfinite_objective_gradient),
        ) == 1
        hessian = NLPDiagnostics.evaluate_lagrangian_hessian(
            model,
            point;
            constraint_multipliers = [0.0, 3.0],
        )
        @test hessian.complete
        @test hessian.methods == [:exact_nlp_evaluator]
        @test evaluator.initialize_count == 4
        combined = NLPDiagnostics._combined_hessian_matrix(hessian)
        @test combined == [2.0 0.0; 0.0 6.0]
    end

    @testset "VectorNonlinearOracle value and exact Jacobian adapter" begin
        model = new_model()
        x, y = MOI.add_variables(model, 2)
        oracle = MOI.VectorNonlinearOracle(;
            dimension = 2,
            l = [0.0],
            u = [0.0],
            eval_f = (output, input) -> begin
                output[1] = input[1] * input[2]
                return
            end,
            jacobian_structure = [(1, 1), (1, 2)],
            eval_jacobian = (output, input) -> begin
                output[1] = input[2]
                output[2] = input[1]
                return
            end,
        )
        MOI.add_constraint(model, MOI.VectorOfVariables([x, y]), oracle)
        capabilities = NLPDiagnostics.evaluator_capabilities(model)
        @test any(
            capability -> capability.source == :nonlinear_oracle,
            capabilities,
        )
        evaluation = NLPDiagnostics.evaluate_numerical(
            model,
            [2.0, 3.0];
            label = "oracle point",
        )
        @test evaluation.constraint_values == [6.0]
        @test evaluation.jacobian_row_methods == [:exact_nonlinear_oracle]
        @test [entry.value for entry in evaluation.jacobian_entries] ==
              [3.0, 2.0]
        @test NLPDiagnostics.jacobian_scale_summary(evaluation).row_norms ==
              [3.0]
        callback_statistics = NLPDiagnostics.evaluation_call_statistics(evaluation)
        @test callback_statistics[:oracle_constraint_value][1] == 1
        @test callback_statistics[:oracle_constraint_jacobian][1] == 1
    end

    @testset "function-value and derivative domains remain distinct" begin
        model = new_model()
        x = MOI.add_variable(model)
        MOI.add_constraint(model, x, MOI.Interval(0.0, 1.0))
        root = MOI.ScalarNonlinearFunction(:sqrt, Any[x])
        MOI.add_constraint(model, root, MOI.LessThan(2.0))
        @test isempty(
            findings(
                NLPDiagnostics.analyze_domains(model),
                :possible_expression_domain_violation,
            ),
        )
        derivative_report = NLPDiagnostics.analyze_derivatives(model)
        possible =
            findings(derivative_report, :possible_derivative_domain_violation)
        @test length(possible) == 2
        @test sort(
            parse.(
                Int,
                [
                    Dict(finding.evidence[1].details)["derivative_order"] for
                    finding in possible
                ],
            ),
        ) == [1, 2]

        point = NLPDiagnostics.evaluation_point(
            model,
            [0.0];
            label = "sqrt boundary",
        )
        point_report =
            NLPDiagnostics.analyze_derivatives(model; point = point)
        @test length(
            findings(point_report, :operating_point_derivative_violation),
        ) == 2
        @test all(
            finding ->
                finding.basis == NLPDiagnostics.MathematicalProof &&
                    finding.confidence == NLPDiagnostics.ConfidenceCertain,
            findings(
                point_report,
                :operating_point_derivative_violation,
            ),
        )
    end

    @testset "nonsmooth and fractional-power derivative fingerprints" begin
        absolute_model = new_model()
        x = MOI.add_variable(absolute_model)
        MOI.add_constraint(absolute_model, x, MOI.EqualTo(0.0))
        MOI.add_constraint(
            absolute_model,
            MOI.ScalarNonlinearFunction(:abs, Any[x]),
            MOI.LessThan(1.0),
        )
        absolute_finding = only(
            findings(
                NLPDiagnostics.analyze_derivatives(absolute_model),
                :proven_derivative_domain_violation,
            ),
        )
        @test Dict(absolute_finding.evidence[1].details)["derivative_order"] ==
              "1"

        power_model = new_model()
        y = MOI.add_variable(power_model)
        MOI.add_constraint(power_model, y, MOI.Interval(0.0, 1.0))
        MOI.add_constraint(
            power_model,
            MOI.ScalarNonlinearFunction(:^, Any[y, 1.5]),
            MOI.LessThan(1.0),
        )
        power_issues = NLPDiagnostics.derivative_issues(power_model)
        @test length(power_issues) == 1
        @test only(power_issues).order == 2
        @test only(power_issues).assessment ==
              NLPDiagnostics.DomainPossibleViolation
    end

    @testset "inverse trigonometric value and derivative boundaries" begin
        invalid_model = new_model()
        x = MOI.add_variable(invalid_model)
        MOI.add_constraint(invalid_model, x, MOI.EqualTo(2.0))
        MOI.add_constraint(
            invalid_model,
            MOI.ScalarNonlinearFunction(:asin, Any[x]),
            MOI.LessThan(2.0),
        )
        @test length(
            findings(
                NLPDiagnostics.analyze_domains(invalid_model),
                :proven_expression_domain_violation,
            ),
        ) == 1

        boundary_model = new_model()
        y = MOI.add_variable(boundary_model)
        MOI.add_constraint(boundary_model, y, MOI.EqualTo(1.0))
        MOI.add_constraint(
            boundary_model,
            MOI.ScalarNonlinearFunction(:asin, Any[y]),
            MOI.LessThan(2.0),
        )
        @test isempty(NLPDiagnostics.domain_issues(boundary_model))
        derivative_issues =
            NLPDiagnostics.derivative_issues(boundary_model)
        @test length(derivative_issues) == 2
        @test all(
            issue ->
                issue.assessment ==
                NLPDiagnostics.DomainProvenViolation,
            derivative_issues,
        )
    end

    @testset "custom derivative-domain extension hook" begin
        model = new_model()
        x = MOI.add_variable(model)
        MOI.add_constraint(model, x, MOI.EqualTo(-1.0))
        custom = MOI.ScalarNonlinearFunction(
            :positive_derivative_only,
            Any[x],
        )
        MOI.add_constraint(model, custom, MOI.LessThan(0.0))
        issue = only(NLPDiagnostics.derivative_issues(model))
        @test issue.operator == :positive_derivative_only
        @test issue.assessment == NLPDiagnostics.DomainProvenViolation
    end

    @testset "stable-expression fingerprints" begin
        model = new_model()
        x = MOI.add_variable(model)
        exp_x = MOI.ScalarNonlinearFunction(:exp, Any[x])
        softplus = MOI.ScalarNonlinearFunction(
            :log,
            Any[MOI.ScalarNonlinearFunction(:+, Any[1.0, exp_x])],
        )
        log_one_plus = MOI.ScalarNonlinearFunction(
            :log,
            Any[MOI.ScalarNonlinearFunction(:+, Any[1.0, x])],
        )
        exp_minus_one =
            MOI.ScalarNonlinearFunction(:-, Any[exp_x, 1.0])
        logistic = MOI.ScalarNonlinearFunction(
            :/,
            Any[
                1.0,
                MOI.ScalarNonlinearFunction(
                    :+,
                    Any[
                        1.0,
                        MOI.ScalarNonlinearFunction(
                            :exp,
                            Any[
                                MOI.ScalarNonlinearFunction(
                                    :-,
                                    Any[x],
                                ),
                            ],
                        ),
                    ],
                ),
            ],
        )
        for expression in
            (softplus, log_one_plus, exp_minus_one, logistic)
            MOI.add_constraint(model, expression, MOI.LessThan(1.0e6))
        end
        report = NLPDiagnostics.analyze_expressions(model)
        @test length(findings(report, :unstable_softplus_expression)) == 1
        @test length(findings(report, :log_one_plus_cancellation_risk)) ==
              1
        @test length(findings(report, :exp_minus_one_cancellation_risk)) ==
              1
        @test length(findings(report, :unstable_logistic_expression)) == 1
        @test !isempty(findings(report, :exponential_overflow_risk))
        @test !isempty(findings(report, :exponential_underflow_risk))

        stable_model = new_model()
        z = MOI.add_variable(stable_model)
        stable = MOI.ScalarNonlinearFunction(:log1pexp, Any[z])
        MOI.add_constraint(stable_model, stable, MOI.LessThan(1.0e6))
        @test isempty(
            findings(
                NLPDiagnostics.analyze_expressions(stable_model),
                :unstable_softplus_expression,
            ),
        )
    end

    @testset "numeric type controls overflow fingerprints" begin
        model = new_model()
        x = MOI.add_variable(model)
        MOI.add_constraint(model, x, MOI.EqualTo(100.0))
        MOI.add_constraint(
            model,
            MOI.ScalarNonlinearFunction(:exp, Any[x]),
            MOI.LessThan(Inf),
        )
        float64_report =
            NLPDiagnostics.analyze_expressions(model; numeric_type = Float64)
        float32_report =
            NLPDiagnostics.analyze_expressions(model; numeric_type = Float32)
        @test isempty(
            findings(float64_report, :exponential_overflow_risk),
        )
        finding =
            only(findings(float32_report, :exponential_overflow_risk))
        @test finding.severity == NLPDiagnostics.SeverityError
        @test Dict(finding.evidence[1].details)["numeric_type"] ==
              "Float32"
    end

    @testset "initialization analysis is explicit and complete" begin
        incomplete = new_model()
        x, y = MOI.add_variables(incomplete, 2)
        MOI.set(incomplete, MOI.VariablePrimalStart(), x, 1.0)
        @test NLPDiagnostics.initialization_point(incomplete) === nothing
        incomplete_report =
            NLPDiagnostics.analyze_initialization(incomplete)
        @test length(
            findings(
                incomplete_report,
                :incomplete_variable_initialization,
            ),
        ) == 1
        @test incomplete_report.metadata[:missing_initial_value_count] ==
              "1"

        boundary = new_model()
        z = MOI.add_variable(boundary)
        MOI.add_constraint(boundary, z, MOI.GreaterThan(0.0))
        MOI.add_constraint(
            boundary,
            MOI.ScalarNonlinearFunction(:sqrt, Any[z]),
            MOI.LessThan(2.0),
        )
        MOI.set(boundary, MOI.VariablePrimalStart(), z, 0.0)
        point = NLPDiagnostics.initialization_point(boundary)
        @test point !== nothing
        @test point.label == "initialization"
        boundary_report =
            NLPDiagnostics.analyze_initialization(boundary)
        @test length(
            findings(boundary_report, :initialization_on_variable_bound),
        ) == 1
        @test length(
            findings(
                boundary_report,
                :operating_point_derivative_violation,
            ),
        ) == 2
        @test length(
            findings(
                boundary_report,
                :initialization_near_constraint_boundary,
            ),
        ) == 1
        @test boundary_report.metadata[:initialization_active_row_count] == "1"

        invalid = new_model()
        w = MOI.add_variable(invalid)
        MOI.add_constraint(invalid, w, MOI.GreaterThan(0.0))
        MOI.set(invalid, MOI.VariablePrimalStart(), w, -1.0)
        invalid_report = NLPDiagnostics.analyze_initialization(invalid)
        @test length(
            findings(
                invalid_report,
                :initialization_violates_variable_bounds,
            ),
        ) == 1
        @test length(
            findings(invalid_report, :constraint_feasibility_violation),
        ) == 1
        combined =
            NLPDiagnostics.analyze(boundary; check_initialization = true)
        @test endswith(combined.metadata[:stages], ",initialization")
    end

    @testset "text report" begin
        report = NLPDiagnostics.DiagnosticReport()
        text = sprint(show, MIME"text/plain"(), report)
        @test occursin("0 findings", text)
    end

    @testset "solver-independent postmortem evidence" begin
        postmortem = NLPDiagnostics.SolverPostmortem(
            "TestSolver",
            :locally_infeasible;
            raw_status = "restoration failed",
            iterations = 20,
            primal_residual = 1e-2,
            dual_residual = 2e-2,
            complementarity = 3e-2,
            restoration_attempted = true,
            restoration_succeeded = false,
        )
        report = NLPDiagnostics.analyze_postmortem(
            postmortem;
            residual_tolerance = 1e-4,
        )
        @test length(
            findings(report, :solver_reported_infeasibility),
        ) == 1
        @test length(
            findings(report, :solver_restoration_unsuccessful),
        ) == 1
        @test length(findings(report, :large_solver_residual)) == 3
        @test report.metadata[:solver] == "TestSolver"
        @test report.metadata[:termination] == "locally_infeasible"

        limit_report = NLPDiagnostics.analyze_postmortem(
            NLPDiagnostics.SolverPostmortem("TestSolver", :iteration_limit),
        )
        @test length(findings(limit_report, :solver_termination_limit)) == 1

        unconfigured_jump_model = JuMP.Model()
        @test_throws ArgumentError NLPDiagnostics.solver_postmortem(
            unconfigured_jump_model,
        )
    end

    @testset "raw solver log evidence" begin
        log = """
        iter 0
        Restoration Failed
        Invalid number in NLP Jacobian detected.
        Converged to a point of local infeasibility.
        Maximum Number of Iterations Exceeded.
        """
        observations = NLPDiagnostics.solver_log_observations(log)
        @test [observation.category for observation in observations] == [
            :restoration_failed,
            :invalid_number,
            :reported_infeasibility,
            :termination_limit,
        ]
        report = NLPDiagnostics.analyze_solver_log(
            "TestSolver",
            log;
            max_evidence_lines = 1,
        )
        @test length(findings(report, :solver_log_restoration_failure)) == 1
        @test length(findings(report, :solver_log_invalid_number)) == 1
        @test length(findings(report, :solver_log_reported_infeasibility)) == 1
        @test length(findings(report, :solver_log_termination_limit)) == 1
        @test report.metadata[:recognized_log_observation_count] == "4"
        @test evidence_details(
            only(findings(report, :solver_log_restoration_failure)),
        )["line"] == "2"
        @test_throws ArgumentError NLPDiagnostics.analyze_solver_log(
            "TestSolver",
            log;
            max_evidence_lines = 0,
        )
    end

    @testset "structured solver iteration evidence" begin
        ipopt_log = """
        iter    objective    inf_pr   inf_du lg(mu)  ||d||  lg(rg) alpha_du alpha_pr  ls
           0  1.0e+00 1.0e+00 2.0e+00  -1.0 0.0e+00    -  0.0e+00 0.0e+00   0
           1r 2.0e+00 1.0e-02 3.0e-02  -2.0 1.0e+00    -  1.0e+00 1.0e+00   1
        """
        records = NLPDiagnostics.solver_iteration_records(ipopt_log)
        @test length(records) == 2
        @test records[2].format == :ipopt
        @test records[2].phase == :annotated
        @test records[2].primal_step == 1.0

        madnlp_log = """
        iter    objective    inf_pr   inf_du inf_compl lg(mu) lg(rg) alpha_pr ir ls
           0  1.0e+00 1.0e+00 2.0e+00 3.0e+00 -1.0 0.0 0.0 0 0
           1  2.0e+00 2.0e+01 3.0e+01 4.0e+00 -2.0 0.0 1.0 0 1
        """
        @test only(NLPDiagnostics.solver_iteration_records(madnlp_log)[2:2]).complementarity == 4.0
        report = NLPDiagnostics.analyze_solver_iterations("Ipopt", ipopt_log; residual_tolerance = 1e-3)
        @test length(findings(report, :solver_iteration_large_final_residual)) == 1
    end
end
