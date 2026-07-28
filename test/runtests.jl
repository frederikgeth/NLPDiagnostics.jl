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

@testset "profiling corpus input validation" begin
    point = NLPDiagnostics.EvaluationPoint(MOI.VariableIndex[], Float64[])
    first_case = NLPDiagnostics.ProfileCase("first", point)
    @test_throws ArgumentError NLPDiagnostics.profile_cases_repeated(
        MOI.ModelLike[],
        [first_case],
    )
    @test isempty(NLPDiagnostics.profile_cases_repeated(MOI.ModelLike[], NLPDiagnostics.ProfileCase[]))
    stability_models, stability_cases = NLPDiagnostics.synthetic_stability_profile_corpus()
    @test length(stability_models) == length(stability_cases) == 5
    @test [case.name for case in stability_cases] == [
        "stability_log1mexp_composite",
        "stability_logcosh_composite",
        "stability_complementary_logistic",
        "stability_logsumexp_composite",
        "stability_logdiffexp_composite",
    ]
    stability_aggregates = NLPDiagnostics.profile_synthetic_stability_corpus(
        repetitions = 1, warmup = false,
    )
    @test Set(keys(stability_aggregates)) == Set(case.name for case in stability_cases)
    for aggregate in values(stability_aggregates)
        run = only(aggregate.runs)
        @test haskey(run.stage_seconds, :static)
        @test haskey(run.stage_seconds, :expressions)
        @test haskey(run.stage_seconds, :reformulation)
        @test !isempty(run.expression_report.findings)
        @test length(findings(run.reformulation_report, :stable_reformulation_candidate)) == 1
    end
    stability_data = NLPDiagnostics.profile_aggregate_data(
        stability_aggregates["stability_log1mexp_composite"],
    )
    @test stability_data["case"]["name"] == "stability_log1mexp_composite"
    @test haskey(stability_data["stage_timing"], "expressions")
    @test only(stability_data["runs"])["reports"]["reformulation"]["metadata"]["stage"] ==
          "stable_reformulation_plan"
    stability_comparison = NLPDiagnostics.compare_profiles(
        stability_aggregates["stability_log1mexp_composite"],
        stability_aggregates["stability_logcosh_composite"],
    )
    stability_comparison_data = NLPDiagnostics.profile_comparison_data(
        stability_comparison,
    )
    @test stability_comparison_data["baseline_case"]["name"] ==
          "stability_log1mexp_composite"
    @test any(
        item -> item["stage"] == "expressions",
        stability_comparison_data["stage_comparisons"],
    )
    stability_markdown = NLPDiagnostics.markdown_profile_aggregate(
        stability_aggregates["stability_log1mexp_composite"],
    )
    @test occursin("# NLPDiagnostics profile: stability_log1mexp_composite", stability_markdown)
    @test occursin("## Expected evidence", stability_markdown)
    @test occursin("`expressions`", stability_markdown)
    stability_comparison_markdown = NLPDiagnostics.markdown_profile_comparison(
        stability_comparison,
    )
    @test occursin("# NLPDiagnostics profile comparison", stability_comparison_markdown)
    @test occursin("Baseline: `stability_log1mexp_composite`", stability_comparison_markdown)
    @test occursin("## Numerical metric comparison", stability_comparison_markdown)
    boundary_models, boundary_cases =
        NLPDiagnostics.synthetic_derivative_boundary_profile_corpus()
    @test length(boundary_models) == length(boundary_cases) == 8
    @test all(
        case -> case.expected_evidence == [:strict_domain_derivative_amplification],
        boundary_cases,
    )
    boundary_aggregates = NLPDiagnostics.profile_synthetic_derivative_boundary_corpus(
        repetitions = 1, warmup = false,
    )
    @test Set(keys(boundary_aggregates)) == Set(case.name for case in boundary_cases)
    @test all(
        aggregate -> only(aggregate.expected_evidence).fraction == 1.0,
        values(boundary_aggregates),
    )
    float32_models, float32_cases =
        NLPDiagnostics.synthetic_float32_derivative_overflow_profile_corpus()
    @test length(float32_models) == length(float32_cases) == 2
    float32_aggregates =
        NLPDiagnostics.profile_synthetic_float32_derivative_overflow_corpus(
            repetitions = 1, warmup = false,
        )
    @test all(
        aggregate -> only(aggregate.expected_evidence).fraction == 1.0,
        values(float32_aggregates),
    )
    @test all(
        aggregate -> any(
            finding -> finding.code == :strict_domain_derivative_amplification &&
                       finding.severity == NLPDiagnostics.SeverityError,
            only(aggregate.runs).expression_report.findings,
        ),
        values(float32_aggregates),
    )
    geometry_models, geometry_cases =
        NLPDiagnostics.synthetic_quadratic_geometry_profile_corpus()
    @test length(geometry_models) == length(geometry_cases) == 8
    @test [case.name for case in geometry_cases] == [
        "quadratic_nonunit_circle",
        "nonlinear_nonunit_circle",
        "quadratic_shifted_ellipsoid",
        "nonlinear_shifted_ellipsoid",
        "quadratic_zero_radius",
        "quadratic_negative_radius_squared",
        "quadratic_implied_bound_conflict",
        "quadratic_minimum_level_inequality",
    ]
    geometry_aggregates = NLPDiagnostics.profile_synthetic_quadratic_geometry_corpus(
        repetitions = 1, warmup = false,
    )
    @test all(
        aggregate -> all(item -> item.fraction == 1.0, aggregate.expected_evidence),
        values(geometry_aggregates),
    )
    @test Set(item.code for item in geometry_aggregates["quadratic_zero_radius"].expected_evidence) ==
          Set([:zero_radius_circular_constraint, :nonregular_zero_radius_quadratic_fixing])
    @test Set(item.code for item in geometry_aggregates["quadratic_minimum_level_inequality"].expected_evidence) ==
          Set([
              :minimum_level_diagonal_quadratic_constraint,
              :nonregular_minimum_level_diagonal_quadratic_inequality,
          ])
    duplicate = NLPDiagnostics.ProfileCase("first", point)
    @test_throws ArgumentError NLPDiagnostics.profile_cases_repeated(
        MOI.ModelLike[],
        [first_case, duplicate],
    )
end

@testset "renderer-neutral report data" begin
    entity = NLPDiagnostics.EntityRef(
        :constraint,
        3;
        subindex = 2,
        name = "balance",
        function_type = "ScalarNonlinearFunction",
        set_type = "EqualTo",
    )
    finding = NLPDiagnostics.Finding(
        :example;
        severity = NLPDiagnostics.SeverityWarning,
        domain = NLPDiagnostics.NumericalIssue,
        basis = NLPDiagnostics.NumericalObservation,
        confidence = NLPDiagnostics.ConfidenceHigh,
        observation = "Example finding.",
        why_it_matters = "Example evidence serialization.",
        evidence = [NLPDiagnostics.Evidence("Example"; details = ["margin" => "1e-6"])],
        suggested_actions = ["Inspect the source row."],
        affected = [entity],
    )
    report = NLPDiagnostics.DiagnosticReport([finding], Dict(:stage => "test"))
    data = NLPDiagnostics.report_data(report)
    @test data["metadata"] == Dict("stage" => "test")
    finding_data = only(data["findings"])
    @test finding_data["severity"] == "warning"
    @test finding_data["domain"] == "numerical"
    @test finding_data["basis"] == "numerical_observation"
    @test only(finding_data["evidence"])["details"] == Dict("margin" => "1e-6")
    @test only(finding_data["affected"])["subindex"] == 2
    @test NLPDiagnostics.findings(
        report;
        code = :example,
        severity = NLPDiagnostics.SeverityWarning,
        domain = NLPDiagnostics.NumericalIssue,
    ) == [finding]
    @test isempty(NLPDiagnostics.findings(report; severity = NLPDiagnostics.SeverityError))
    @test NLPDiagnostics.finding_code_counts(report) == Dict(:example => 1)
    @test data["finding_code_counts"] == Dict("example" => 1)
    markdown = NLPDiagnostics.markdown_report(report)
    @test occursin("# NLPDiagnostics report", markdown)
    @test occursin("## WARNING · numerical · `example`", markdown)
    @test occursin("### Evidence", markdown)
    @test occursin("`constraint[3/2] (balance)`", markdown)
    @test sprint(show, MIME"text/markdown"(), report) == markdown
end

@testset "component metadata plugin boundary" begin
    model = MOIU.Model{Float64}()
    @test isempty(NLPDiagnostics.component_metadata(model))
    @test isempty(NLPDiagnostics.component_port_metadata(model))
    @test NLPDiagnostics.analyze_static(model).metadata[:component_metadata_count] == "0"
    @test NLPDiagnostics.analyze(model).metadata[:component_metadata_count] == "0"
    metadata = NLPDiagnostics.ComponentMetadata(
        :line,
        "line_1";
        variables = MOI.VariableIndex[MOI.VariableIndex(1)],
        constraints = [NLPDiagnostics.EntityRef(:constraint, 1)],
        units = Dict(:voltage => "kV"),
        expected_rank = 2,
    )
    @test metadata.units[:voltage] == "kV"
    @test metadata.variables == MOI.VariableIndex[MOI.VariableIndex(1)]
    @test metadata.constraints == [NLPDiagnostics.EntityRef(:constraint, 1)]
    @test metadata.expected_rank == 2
    port = NLPDiagnostics.ComponentPortMetadata(
        :line,
        "line_1",
        "from";
        terminal_labels = ["a", "b"],
        mode_labels = ["phase_a", "phase_b"],
        variables = MOI.VariableIndex[MOI.VariableIndex(1)],
        connection_matrix = [1.0 0.0; 0.0 1.0],
        metadata = Dict("connection" => "wye"),
    )
    @test port.connection_matrix == [1.0 0.0; 0.0 1.0]
    @test port.terminal_labels == ["a", "b"]
    port_report = NLPDiagnostics._component_port_metadata_findings(
        [port]; model_variables = MOI.VariableIndex[MOI.VariableIndex(1)],
    )
    @test isempty(port_report.findings)
    malformed_port = NLPDiagnostics.ComponentPortMetadata{Float64}(
        :line, "line_1", "from", ["a"], ["a", "b"],
        MOI.VariableIndex[MOI.VariableIndex(2), MOI.VariableIndex(2)],
        reshape([NaN], 1, 1), Dict{String,String}(),
    )
    malformed_port_report = NLPDiagnostics._component_port_metadata_findings(
        [malformed_port]; model_variables = MOI.VariableIndex[MOI.VariableIndex(1)],
    )
    @test length(findings(
        malformed_port_report,
        :component_port_metadata_connection_dimension_mismatch,
    )) == 1
    @test length(findings(
        malformed_port_report,
        :component_port_metadata_nonfinite_connection,
    )) == 1
    @test length(findings(
        malformed_port_report,
        :component_port_metadata_duplicate_variables,
    )) == 1
    @test length(findings(
        malformed_port_report,
        :component_port_metadata_unknown_variable,
    )) == 1
    rank_deficient_port = NLPDiagnostics.ComponentPortMetadata(
        :transformer, "tx_1", "high";
        terminal_labels = ["a", "b"], mode_labels = ["a", "b"],
        connection_matrix = [1.0 0.0; 0.0 0.0],
    )
    rank_deficient_port_report = NLPDiagnostics._component_port_metadata_findings(
        [rank_deficient_port],
    )
    @test length(findings(
        rank_deficient_port_report,
        :component_port_metadata_connection_rank_deficient,
    )) == 1
    observed_port_mode = NLPDiagnostics.PortNullspaceMode(
        :transformer, "tx_1", "high", :mode, [0.0, 1.0],
    )
    unobserved_port_mode = NLPDiagnostics.PortNullspaceMode(
        :transformer, "tx_1", "high", :mode, [1.0, 0.0],
    )
    port_mode_report = NLPDiagnostics._component_port_nullspace_mode_findings(
        [rank_deficient_port], [observed_port_mode, unobserved_port_mode],
    )
    @test length(findings(
        port_mode_report,
        :component_port_expected_nullspace_mode_observed,
    )) == 1
    @test length(findings(
        port_mode_report,
        :component_port_expected_nullspace_mode_not_observed,
    )) == 1
    second_port = NLPDiagnostics.ComponentPortMetadata(
        :transformer, "tx_1", "low";
        terminal_labels = ["a", "b"], mode_labels = ["a", "b"],
        connection_matrix = [1.0 0.0; 0.0 1.0],
    )
    connection = NLPDiagnostics.PortConnectionMetadata(
        :transformer, "tx_1", "high", :transformer, "tx_1", "low";
        connection_matrix = [1.0 0.0; 0.0 1.0],
    )
    connection_report = NLPDiagnostics._component_port_connection_findings(
        [rank_deficient_port, second_port], [connection],
    )
    @test isempty(connection_report.findings)
    bad_connection = NLPDiagnostics.PortConnectionMetadata(
        :transformer, "tx_1", "missing", :transformer, "tx_1", "low";
        connection_matrix = reshape([1.0], 1, 1),
    )
    bad_connection_report = NLPDiagnostics._component_port_connection_findings(
        [rank_deficient_port, second_port], [bad_connection],
    )
    @test length(findings(
        bad_connection_report,
        :component_port_connection_unaligned,
    )) == 1
    isolated_port = NLPDiagnostics.ComponentPortMetadata(
        :load, "load_1", "terminal";
        terminal_labels = ["a"], mode_labels = ["a"],
        connection_matrix = reshape([1.0], 1, 1),
    )
    topology_report = NLPDiagnostics._component_port_topology_findings(
        [rank_deficient_port, second_port, isolated_port], [connection],
    )
    @test length(findings(
        topology_report,
        :component_port_topology_isolated_port,
    )) == 1
    topology_nullspace = NLPDiagnostics.port_topology_nullspace(
        [rank_deficient_port, second_port], [connection],
    )
    @test topology_nullspace.available
    @test topology_nullspace.rank == 2
    @test size(topology_nullspace.nullspace) == (4, 2)
    coordinate_map = NLPDiagnostics.PortCoordinateMap(
        :transformer, "tx_1", "high", MOI.VariableIndex[MOI.VariableIndex(1)];
        terminal_to_variable = reshape([1.0, 0.0], 1, 2),
    )
    @test size(coordinate_map.terminal_to_variable) == (1, 2)
    coordinate_map_report = NLPDiagnostics._component_port_coordinate_map_findings(
        [rank_deficient_port], [coordinate_map];
        model_variables = MOI.VariableIndex[MOI.VariableIndex(1)],
    )
    @test isempty(coordinate_map_report.findings)
    port_semantics = NLPDiagnostics.PortCoordinateSemantics(
        :transformer, "tx_1", "high";
        quantity = :voltage, representation = :polar,
        units = Dict("voltage" => "p.u."),
    )
    @test NLPDiagnostics.PortCoordinateSemantics(
        :transformer, "tx_1", "angle";
        quantity = :angle, representation = :polar,
        units = Dict("angle" => "rad"),
    ).quantity == :angle
    unmapped_semantics_report =
        NLPDiagnostics._component_port_coordinate_semantics_findings(
            [rank_deficient_port], [port_semantics],
        )
    @test length(findings(
        unmapped_semantics_report,
        :component_port_coordinate_semantics_unmapped,
    )) == 1
    mapped_semantics_report =
        NLPDiagnostics._component_port_coordinate_semantics_findings(
            [rank_deficient_port], [port_semantics], [coordinate_map],
        )
    @test isempty(mapped_semantics_report.findings)
    second_coordinate_map = NLPDiagnostics.PortCoordinateMap(
        :transformer, "tx_1", "low", MOI.VariableIndex[MOI.VariableIndex(1)];
        terminal_to_variable = reshape([1.0, 0.0], 1, 2),
    )
    conflicting_port_semantics = NLPDiagnostics.PortCoordinateSemantics(
        :transformer, "tx_1", "low";
        quantity = :current, representation = :rectangular,
        units = Dict("current" => "p.u."),
    )
    conflicting_port_semantics_report =
        NLPDiagnostics._component_port_coordinate_semantics_findings(
            [rank_deficient_port, second_port],
            [port_semantics, conflicting_port_semantics],
            [coordinate_map, second_coordinate_map],
        )
    @test length(findings(
        conflicting_port_semantics_report,
        :component_port_coordinate_semantics_variable_conflict,
    )) == 1
    cross_layer_component_semantics = NLPDiagnostics.ComponentCoordinateSemantics(
        :bus, "bus_1", MOI.VariableIndex[MOI.VariableIndex(1)];
        quantity = :angle, representation = :polar,
        units = Dict("angle" => "rad"),
    )
    component_port_semantics_report =
        NLPDiagnostics._component_port_coordinate_semantics_cross_layer_findings(
            [cross_layer_component_semantics], [port_semantics], [coordinate_map],
        )
    @test length(findings(
        component_port_semantics_report,
        :component_port_coordinate_semantics_cross_layer_conflict,
    )) == 1
    aligned_component_port_semantics = NLPDiagnostics.ComponentCoordinateSemantics(
        :bus, "bus_1", MOI.VariableIndex[MOI.VariableIndex(1)];
        quantity = :voltage, representation = :polar,
        units = Dict("voltage" => "p.u."),
    )
    @test isempty(NLPDiagnostics._component_port_coordinate_semantics_cross_layer_findings(
        [aligned_component_port_semantics], [port_semantics], [coordinate_map],
    ).findings)
    unitless_semantics = NLPDiagnostics.PortCoordinateSemantics(
        :transformer, "tx_1", "high"; quantity = :current,
    )
    unitless_semantics_report =
        NLPDiagnostics._component_port_coordinate_semantics_findings(
            [rank_deficient_port], [unitless_semantics], [coordinate_map],
        )
    @test length(findings(
        unitless_semantics_report,
        :component_port_coordinate_semantics_units_unspecified,
    )) == 1
    @test_throws ArgumentError NLPDiagnostics.PortCoordinateSemantics(
        :transformer, "tx_1", "high"; quantity = :temperature,
    )
    @test_throws ArgumentError NLPDiagnostics.PortCoordinateSemantics(
        :transformer, "tx_1", "high";
        quantity = :voltage, units = Dict("voltage" => " "),
    )
    component_angle_semantics = NLPDiagnostics.ComponentCoordinateSemantics(
        :bus, "bus_1", MOI.VariableIndex[MOI.VariableIndex(1)];
        quantity = :angle, representation = :polar,
        units = Dict("angle" => "rad"),
    )
    @test isempty(NLPDiagnostics._component_coordinate_semantics_findings(
        [component_angle_semantics], MOI.VariableIndex[MOI.VariableIndex(1)],
        components = [NLPDiagnostics.ComponentMetadata(
            :bus, "bus_1"; variables = MOI.VariableIndex[MOI.VariableIndex(1)],
        )],
    ).findings)
    duplicate_component_semantics = NLPDiagnostics.ComponentCoordinateSemantics(
        :bus, "bus_1", MOI.VariableIndex[MOI.VariableIndex(1)]; quantity = :voltage,
    )
    duplicate_component_semantics_report =
        NLPDiagnostics._component_coordinate_semantics_findings(
            [component_angle_semantics, duplicate_component_semantics],
            MOI.VariableIndex[MOI.VariableIndex(1)],
        )
    @test length(findings(
        duplicate_component_semantics_report,
        :duplicate_component_coordinate_semantics,
    )) == 1
    conflicting_component_semantics = NLPDiagnostics.ComponentCoordinateSemantics(
        :controller, "ctl_1", MOI.VariableIndex[MOI.VariableIndex(1)];
        quantity = :voltage, representation = :rectangular,
        units = Dict("voltage" => "p.u."),
    )
    conflicting_component_semantics_report =
        NLPDiagnostics._component_coordinate_semantics_findings(
            [component_angle_semantics, conflicting_component_semantics],
            MOI.VariableIndex[MOI.VariableIndex(1)],
        )
    @test length(findings(
        conflicting_component_semantics_report,
        :component_coordinate_semantics_variable_conflict,
    )) == 1
    out_of_scope_component_semantics = NLPDiagnostics.ComponentCoordinateSemantics(
        :bus, "bus_1", MOI.VariableIndex[MOI.VariableIndex(2)];
        quantity = :angle, representation = :polar, units = Dict("angle" => "rad"),
    )
    out_of_scope_component_semantics_report =
        NLPDiagnostics._component_coordinate_semantics_findings(
            [out_of_scope_component_semantics],
            MOI.VariableIndex[MOI.VariableIndex(1), MOI.VariableIndex(2)],
            components = [NLPDiagnostics.ComponentMetadata(
                :bus, "bus_1"; variables = MOI.VariableIndex[MOI.VariableIndex(1)],
            )],
        )
    @test length(findings(
        out_of_scope_component_semantics_report,
        :component_coordinate_semantics_scope_outside_component,
    )) == 1
    terminal_port_mode = NLPDiagnostics.PortNullspaceMode(
        :transformer, "tx_1", "high", :terminal, [0.0, 1.0],
    )
    visible_coordinate_map = NLPDiagnostics.PortCoordinateMap(
        :transformer, "tx_1", "high", MOI.VariableIndex[MOI.VariableIndex(1)];
        terminal_to_variable = reshape([0.0, 1.0], 1, 2),
    )
    port_mode_coordinate_report =
        NLPDiagnostics._component_port_mode_coordinate_projection_findings(
            [rank_deficient_port], [terminal_port_mode], [visible_coordinate_map],
        )
    @test length(findings(
        port_mode_coordinate_report,
        :component_port_mode_coordinate_projection_available,
    )) == 1
    component_projected_modes = NLPDiagnostics.port_component_expected_nullspace_modes(
        [rank_deficient_port], [terminal_port_mode], [visible_coordinate_map],
    )
    @test length(component_projected_modes) == 1
    @test component_projected_modes[1].name ==
          :component_port_candidate_mode_transformer_tx_1_high_1
    unaligned_coordinate_map = NLPDiagnostics.PortCoordinateMap(
        :transformer, "tx_1", "missing", MOI.VariableIndex[MOI.VariableIndex(1)];
        terminal_to_variable = reshape([1.0], 1, 1),
    )
    unaligned_coordinate_map_report = NLPDiagnostics._component_port_coordinate_map_findings(
        [rank_deficient_port], [unaligned_coordinate_map];
        model_variables = MOI.VariableIndex[MOI.VariableIndex(1)],
    )
    @test length(findings(
        unaligned_coordinate_map_report,
        :component_port_coordinate_map_unaligned,
    )) == 1
    coordinate_projection = NLPDiagnostics.port_topology_coordinate_projection(
        [rank_deficient_port, second_port], [connection],
        [coordinate_map, NLPDiagnostics.PortCoordinateMap(
            :transformer, "tx_1", "low", MOI.VariableIndex[MOI.VariableIndex(2)];
            terminal_to_variable = reshape([1.0, 0.0], 1, 2),
        )],
    )
    @test coordinate_projection.available
    @test coordinate_projection.variables == MOI.VariableIndex[MOI.VariableIndex(1), MOI.VariableIndex(2)]
    @test size(coordinate_projection.projected_nullspace) == (2, 2)
    isolated_coordinate_map = NLPDiagnostics.PortCoordinateMap(
        :load, "load_1", "terminal", MOI.VariableIndex[MOI.VariableIndex(3)];
        terminal_to_variable = reshape([1.0], 1, 1),
    )
    @test isempty(NLPDiagnostics.port_topology_expected_nullspace_modes(
        [isolated_port], NLPDiagnostics.PortConnectionMetadata{Float64}[],
        [isolated_coordinate_map],
    ))
    projected_modes = NLPDiagnostics.port_topology_expected_nullspace_modes(
        [rank_deficient_port, second_port], [connection],
        [coordinate_map, NLPDiagnostics.PortCoordinateMap(
            :transformer, "tx_1", "low", MOI.VariableIndex[MOI.VariableIndex(2)];
            terminal_to_variable = reshape([1.0, 0.0], 1, 2),
        )],
    )
    @test length(projected_modes) == 1
    @test projected_modes[1].name == :port_topology_candidate_mode_1
    coordinate_projection_report = NLPDiagnostics._component_port_topology_coordinate_projection_findings(
        [rank_deficient_port, second_port], [connection],
        [coordinate_map, NLPDiagnostics.PortCoordinateMap(
            :transformer, "tx_1", "low", MOI.VariableIndex[MOI.VariableIndex(2)];
            terminal_to_variable = reshape([1.0, 0.0], 1, 2),
        )],
    )
    @test length(findings(
        coordinate_projection_report,
        :component_port_topology_model_projection_available,
    )) == 1
    @test_throws DimensionMismatch NLPDiagnostics.PortCoordinateMap(
        :transformer, "tx_1", "high", MOI.VariableIndex[MOI.VariableIndex(1)];
        terminal_to_variable = [1.0 0.0; 0.0 1.0],
    )
    topology_nullspace_report = NLPDiagnostics._component_port_topology_nullspace_findings(
        [rank_deficient_port, second_port], [connection],
    )
    @test length(findings(
        topology_nullspace_report,
        :component_port_topology_expected_nullspace,
    )) == 1
    @test_throws DimensionMismatch NLPDiagnostics.ComponentPortMetadata(
        :line, "line_1", "bad";
        terminal_labels = ["a"], mode_labels = ["a", "b"],
        connection_matrix = [1.0],
    )
    @test_throws ArgumentError NLPDiagnostics.ComponentMetadata(Symbol(""), "line")
    @test_throws ArgumentError NLPDiagnostics.ComponentMetadata(:line, " ")
    @test_throws ArgumentError NLPDiagnostics.ComponentMetadata(:line, "bad"; expected_rank = -1)
    @test_throws ArgumentError NLPDiagnostics.ComponentMetadata(
        :line,
        "bad";
        units = Dict(Symbol("") => "kV"),
    )
    @test_throws ArgumentError NLPDiagnostics.ComponentMetadata(
        :line,
        "bad";
        variables = MOI.VariableIndex[MOI.VariableIndex(1), MOI.VariableIndex(1)],
    )
    @test_throws ArgumentError NLPDiagnostics.ComponentMetadata(
        :line,
        "bad";
        variables = MOI.VariableIndex[MOI.VariableIndex(1)],
        expected_rank = 2,
    )
    @test_throws ArgumentError NLPDiagnostics.ComponentMetadata(
        :line,
        "bad";
        constraints = [NLPDiagnostics.EntityRef(:constraint, 1)],
        expected_rank = 2,
    )
    malformed = NLPDiagnostics.ComponentMetadata[
        NLPDiagnostics.ComponentMetadata(Symbol(""), "", MOI.VariableIndex[MOI.VariableIndex(2), MOI.VariableIndex(2)], NLPDiagnostics.EntityRef[], Dict(Symbol("") => " "), -1, Dict{String,String}()),
        NLPDiagnostics.ComponentMetadata(:line, "duplicate", MOI.VariableIndex[], NLPDiagnostics.EntityRef[], Dict{Symbol,String}(), nothing, Dict{String,String}()),
        NLPDiagnostics.ComponentMetadata(:line, "duplicate", MOI.VariableIndex[], NLPDiagnostics.EntityRef[], Dict{Symbol,String}(), nothing, Dict{String,String}()),
        NLPDiagnostics.ComponentMetadata(:generator, "rank", MOI.VariableIndex[MOI.VariableIndex(3)], NLPDiagnostics.EntityRef[], Dict{Symbol,String}(), 2, Dict{String,String}()),
        NLPDiagnostics.ComponentMetadata(:branch, "constraints", MOI.VariableIndex[], [NLPDiagnostics.EntityRef(:constraint, 4), NLPDiagnostics.EntityRef(:constraint, 4), NLPDiagnostics.EntityRef(:variable, 1)], Dict{Symbol,String}(), 2, Dict{String,String}()),
    ]
    metadata_report = NLPDiagnostics._component_metadata_findings(
        malformed;
        model_variables = MOI.VariableIndex[MOI.VariableIndex(1)],
        model_constraints = [NLPDiagnostics.EntityRef(:constraint, 1)],
    )
    @test length(findings(metadata_report, :invalid_component_metadata_identity)) == 1
    @test length(findings(metadata_report, :invalid_component_metadata_units)) == 1
    @test length(findings(metadata_report, :invalid_component_metadata_expected_rank)) == 1
    @test length(findings(metadata_report, :duplicate_component_metadata)) == 1
    @test length(findings(metadata_report, :component_metadata_duplicate_variables)) == 1
    @test length(findings(metadata_report, :component_metadata_unknown_variable)) == 2
    @test length(findings(metadata_report, :component_metadata_expected_rank_exceeds_scope)) == 2
    @test length(findings(metadata_report, :component_metadata_duplicate_constraints)) == 1
    @test length(findings(metadata_report, :invalid_component_metadata_constraint_reference)) == 1
    @test length(findings(metadata_report, :component_metadata_unknown_constraint)) == 1

    rank_model = MOIU.Model{Float64}()
    x = MOI.add_variable(rank_model)
    constraint = MOI.add_constraint(rank_model, x, MOI.EqualTo(0.0))
    point = NLPDiagnostics.evaluation_point(rank_model, [0.0])
    evaluation = NLPDiagnostics.evaluate_numerical(rank_model, point)
    aligned = NLPDiagnostics.ComponentMetadata(
        :line,
        "aligned";
        variables = [x],
        constraints = [NLPDiagnostics.EntityRef(:constraint, constraint.value)],
        expected_rank = 1,
    )
    rank_report = NLPDiagnostics.analyze_component_ranks(
        rank_model,
        evaluation;
        components = [aligned],
    )
    @test rank_report.metadata[:component_rank_declared_count] == "1"
    @test rank_report.metadata[:component_rank_comparison_count] == "1"
    @test rank_report.metadata[:component_rank_unavailable_count] == "0"
    @test isempty(findings(rank_report, :component_expected_rank_mismatch))
    mismatched = NLPDiagnostics.ComponentMetadata(
        :line,
        "mismatched";
        variables = [x],
        constraints = [NLPDiagnostics.EntityRef(:constraint, constraint.value)],
        expected_rank = 0,
    )
    mismatch_report = NLPDiagnostics.analyze_component_ranks(
        rank_model,
        evaluation;
        components = [mismatched],
    )
    @test length(findings(mismatch_report, :component_expected_rank_mismatch)) == 1
end

@testset "elastic feasibility planning is non-mutating and explicit" begin
    model = MOIU.Model{Float64}()
    x, y = MOI.add_variables(model, 2)
    affine = MOI.add_constraint(
        model,
        MOI.ScalarAffineFunction([MOI.ScalarAffineTerm(1.0, x)], 0.0),
        MOI.LessThan(1.0),
    )
    nonlinear = MOI.add_constraint(
        model,
        MOI.VectorOfVariables([x, y]),
        MOI.SecondOrderCone(2),
    )
    before = length(MOI.get(model, MOI.ListOfConstraintIndices{MOI.ScalarAffineFunction{Float64},MOI.LessThan{Float64}}()))
    plan = NLPDiagnostics.elastic_feasibility_plan(model)
    @test plan.relaxation_count == 1
    @test plan.slack_count == 1
    @test only(plan.relaxable_constraints).index == affine.value
    @test only(plan.unsupported_constraints).index == nonlinear.value
    plan_report = NLPDiagnostics.analyze_elastic_feasibility_plan(plan)
    @test plan_report.metadata[:unsupported_constraint_count] == "1"
    @test length(findings(plan_report, :elastic_unsupported_constraints)) == 1
    selected_plan = NLPDiagnostics.elastic_feasibility_plan(
        model;
        selected_constraints = [only(plan.relaxable_constraints)],
    )
    @test selected_plan.relaxation_count == 1
    selected_report = NLPDiagnostics.analyze_elastic_feasibility_plan(selected_plan)
    @test selected_report.metadata[:excluded_constraint_count] == "0"
    @test_throws ArgumentError NLPDiagnostics.elastic_feasibility_plan(
        model;
        selected_constraints = [NLPDiagnostics.EntityRef(:constraint, 99)],
    )
    @test_throws ArgumentError NLPDiagnostics.elastic_feasibility_plan(
        model;
        selected_constraints = [only(plan.relaxable_constraints), only(plan.relaxable_constraints)],
    )
    focused_model = MOIU.Model{Float64}()
    u, v = MOI.add_variables(focused_model, 2)
    MOI.add_constraint(
        focused_model,
        MOI.ScalarAffineFunction([MOI.ScalarAffineTerm(1.0, u)], 0.0),
        MOI.LessThan(1.0),
    )
    MOI.add_constraint(
        focused_model,
        MOI.ScalarAffineFunction([MOI.ScalarAffineTerm(1.0, v)], 0.0),
        MOI.GreaterThan(0.0),
    )
    full_focused_plan = NLPDiagnostics.elastic_feasibility_plan(focused_model)
    focused_plan = NLPDiagnostics.elastic_feasibility_plan(
        focused_model;
        selected_constraints = [full_focused_plan.relaxable_constraints[1]],
    )
    @test focused_plan.relaxation_count == 1
    @test length(focused_plan.excluded_constraints) == 1
    @test length(findings(
        NLPDiagnostics.analyze_elastic_feasibility_plan(focused_plan),
        :elastic_constraints_excluded,
    )) == 1
    @test length(MOI.get(model, MOI.ListOfConstraintIndices{MOI.ScalarAffineFunction{Float64},MOI.LessThan{Float64}}())) == before
    auxiliary = NLPDiagnostics.build_elastic_feasibility_model(model)
    @test auxiliary.plan.relaxation_count == plan.relaxation_count
    @test length(auxiliary.relaxations) == 1
    @test length(only(auxiliary.relaxations).slacks) == 1
    @test auxiliary.source_variable_map[x] isa MOI.VariableIndex
    @test auxiliary.source_variable_map[y] isa MOI.VariableIndex
    @test haskey(auxiliary.relaxed_constraint_map, only(plan.relaxable_constraints))
    @test MOI.get(auxiliary.model, MOI.ObjectiveSense()) == MOI.MIN_SENSE
    @test length(MOI.get(auxiliary.model, MOI.ListOfVariableIndices())) == 3
    relaxation = only(auxiliary.relaxations)
    values = Dict(only(relaxation.slacks) => 0.25)
    observed = NLPDiagnostics.elastic_relaxation_values(auxiliary, values)
    @test only(observed).total == 0.25
    @test only(observed).weighted_total == 0.25
    @test only(observed).kind == :upper_bound
    @test NLPDiagnostics.elastic_objective_value(auxiliary, values) == 0.25
    report = NLPDiagnostics.analyze_elastic_relaxations(auxiliary, values)
    @test report.metadata[:positive_elastic_relaxation_count] == "1"
    relaxation_finding = only(findings(report, :elastic_constraint_relaxed))
    @test evidence_details(relaxation_finding)["weighted_slack_magnitude"] == "0.25"
    @test_throws ArgumentError NLPDiagnostics.elastic_relaxation_values(auxiliary, Dict{MOI.VariableIndex,Float64}())
    @test_throws ArgumentError NLPDiagnostics.elastic_relaxation_values(auxiliary)
    weighted = NLPDiagnostics.build_elastic_feasibility_model(
        model;
        weights = Dict(only(plan.relaxable_constraints) => 2.5),
    )
    objective = MOI.get(
        weighted.model,
        MOI.ObjectiveFunction{MOI.ScalarAffineFunction{Float64}}(),
    )
    @test only(objective.terms).coefficient == 2.5
    weighted_values = NLPDiagnostics.elastic_relaxation_values(
        weighted,
        Dict(only(only(weighted.relaxations).slacks) => 0.25),
    )
    @test only(weighted_values).weighted_total == 0.625
    @test_throws ArgumentError NLPDiagnostics.build_elastic_feasibility_model(
        model;
        weights = Dict(only(plan.relaxable_constraints) => 0.0),
    )
    linf_auxiliary = NLPDiagnostics.build_elastic_feasibility_model(
        model;
        objective_norm = :linf,
    )
    @test linf_auxiliary.objective_norm == :linf
    @test !isnothing(linf_auxiliary.epigraph_variable)
    linf_relaxation = only(linf_auxiliary.relaxations)
    @test NLPDiagnostics.elastic_objective_value(
        linf_auxiliary,
        Dict(only(linf_relaxation.slacks) => 0.4),
    ) == 0.4
    @test_throws ArgumentError NLPDiagnostics.build_elastic_feasibility_model(
        model;
        objective_norm = :unsupported,
    )
    @test_throws ArgumentError NLPDiagnostics.build_elastic_feasibility_model(
        model;
        weights = Dict(NLPDiagnostics.EntityRef(:constraint, 99) => 1.0),
    )

    equality_model = MOIU.Model{Float64}()
    z = MOI.add_variable(equality_model)
    equality = MOI.add_constraint(
        equality_model,
        MOI.ScalarAffineFunction([MOI.ScalarAffineTerm(1.0, z)], 0.0),
        MOI.EqualTo(1.0),
    )
    equality_auxiliary = NLPDiagnostics.build_elastic_feasibility_model(equality_model)
    @test equality_auxiliary.plan.slack_count == 2
    equality_relaxation = only(equality_auxiliary.relaxations)
    @test equality_relaxation.source.index == equality.value
    @test length(equality_relaxation.slacks) == 2
    equality_values = Dict(
        equality_relaxation.slacks[1] => 0.2,
        equality_relaxation.slacks[2] => 0.05,
    )
    equality_observation = only(NLPDiagnostics.elastic_relaxation_values(
        equality_auxiliary,
        equality_values,
    ))
    @test equality_observation.values == [0.2, 0.05]
    @test equality_observation.total == 0.25
    @test equality_observation.kind == :equality

    quadratic_model = MOIU.Model{Float64}()
    q = MOI.add_variable(quadratic_model)
    quadratic = MOI.add_constraint(
        quadratic_model,
        MOI.ScalarQuadraticFunction(
            [MOI.ScalarQuadraticTerm(1.0, q, q)],
            MOI.ScalarAffineTerm{Float64}[],
            0.0,
        ),
        MOI.LessThan(1.0),
    )
    quadratic_auxiliary = NLPDiagnostics.build_elastic_feasibility_model(quadratic_model)
    @test only(quadratic_auxiliary.relaxations).source.index == quadratic.value
    @test length(only(quadratic_auxiliary.relaxations).slacks) == 1

    nonlinear_model = MOIU.Model{Float64}()
    n = MOI.add_variable(nonlinear_model)
    nonlinear_constraint = MOI.add_constraint(
        nonlinear_model,
        MOI.ScalarNonlinearFunction(:sin, Any[n]),
        MOI.LessThan(1.0),
    )
    nonlinear_auxiliary = NLPDiagnostics.build_elastic_feasibility_model(nonlinear_model)
    @test only(nonlinear_auxiliary.relaxations).source.index == nonlinear_constraint.value
    @test length(only(nonlinear_auxiliary.relaxations).slacks) == 1

    cone_model = MOIU.Model{Float64}()
    t, w = MOI.add_variables(cone_model, 2)
    cone = MOI.add_constraint(cone_model, MOI.VectorOfVariables([t, w]), MOI.SecondOrderCone(2))
    cone_auxiliary = NLPDiagnostics.build_elastic_feasibility_model(cone_model)
    @test only(cone_auxiliary.relaxations).source.index == cone.value
    @test length(only(cone_auxiliary.relaxations).slacks) == 1
    @test only(cone_auxiliary.relaxations).kind == :second_order_cone

    affine_cone_model = MOIU.Model{Float64}()
    a, b = MOI.add_variables(affine_cone_model, 2)
    affine_cone = MOI.add_constraint(
        affine_cone_model,
        MOI.VectorAffineFunction(
            [
                MOI.VectorAffineTerm(1, MOI.ScalarAffineTerm(1.0, a)),
                MOI.VectorAffineTerm(2, MOI.ScalarAffineTerm(1.0, b)),
            ],
            [0.0, 0.0],
        ),
        MOI.SecondOrderCone(2),
    )
    affine_cone_auxiliary = NLPDiagnostics.build_elastic_feasibility_model(affine_cone_model)
    @test only(affine_cone_auxiliary.relaxations).source.index == affine_cone.value

    rotated_cone_model = MOIU.Model{Float64}()
    r1, r2 = MOI.add_variables(rotated_cone_model, 2)
    rotated_cone = MOI.add_constraint(
        rotated_cone_model,
        MOI.VectorOfVariables([r1, r2]),
        MOI.RotatedSecondOrderCone(2),
    )
    rotated_cone_auxiliary = NLPDiagnostics.build_elastic_feasibility_model(rotated_cone_model)
    @test only(rotated_cone_auxiliary.relaxations).source.index == rotated_cone.value

    nonnegative_model = MOIU.Model{Float64}()
    g, h = MOI.add_variables(nonnegative_model, 2)
    nonnegative = MOI.add_constraint(
        nonnegative_model,
        MOI.VectorOfVariables([g, h]),
        MOI.Nonnegatives(2),
    )
    nonnegative_auxiliary = NLPDiagnostics.build_elastic_feasibility_model(nonnegative_model)
    nonnegative_relaxation = only(nonnegative_auxiliary.relaxations)
    @test nonnegative_relaxation.source.index == nonnegative.value
    @test nonnegative_relaxation.kind == :nonnegatives
    @test length(nonnegative_relaxation.slacks) == 2

    nonpositive_model = MOIU.Model{Float64}()
    m, n = MOI.add_variables(nonpositive_model, 2)
    nonpositive = MOI.add_constraint(
        nonpositive_model,
        MOI.VectorOfVariables([m, n]),
        MOI.Nonpositives(2),
    )
    nonpositive_auxiliary = NLPDiagnostics.build_elastic_feasibility_model(nonpositive_model)
    nonpositive_relaxation = only(nonpositive_auxiliary.relaxations)
    @test nonpositive_relaxation.source.index == nonpositive.value
    @test nonpositive_relaxation.kind == :nonpositives
    @test length(nonpositive_relaxation.slacks) == 2

    zero_model = MOIU.Model{Float64}()
    p, q = MOI.add_variables(zero_model, 2)
    zeros_constraint = MOI.add_constraint(zero_model, MOI.VectorOfVariables([p, q]), MOI.Zeros(2))
    zero_auxiliary = NLPDiagnostics.build_elastic_feasibility_model(zero_model)
    zero_relaxation = only(zero_auxiliary.relaxations)
    @test zero_relaxation.source.index == zeros_constraint.value
    @test zero_relaxation.kind == :zeros
    @test length(zero_relaxation.slacks) == 4

    subset_reference = NLPDiagnostics.EntityRef(:constraint, affine.value)
    positive_subset = NLPDiagnostics.ElasticSubsetSearch(
        NLPDiagnostics.ElasticSubsetProbe(
            [subset_reference], 1.0, true, "LOCALLY_INFEASIBLE", "FEASIBLE_POINT",
        ),
        NLPDiagnostics.ElasticSubsetProbe[],
        [subset_reference],
        NLPDiagnostics.EntityRef[],
        1e-8,
    )
    subset_report = NLPDiagnostics.analyze_local_elastic_subset_search(positive_subset)
    @test length(findings(subset_report, :elastic_subset_local_explanation)) == 1
    consensus_ensemble = NLPDiagnostics.ElasticSubsetEnsemble(
        [positive_subset, positive_subset], [subset_reference], [subset_reference],
    )
    @test length(findings(
        NLPDiagnostics.analyze_local_elastic_subset_ensemble(consensus_ensemble),
        :elastic_subset_order_consensus,
    )) == 1
    sensitive_ensemble = NLPDiagnostics.ElasticSubsetEnsemble(
        [positive_subset, positive_subset], NLPDiagnostics.EntityRef[], [subset_reference],
    )
    @test length(findings(
        NLPDiagnostics.analyze_local_elastic_subset_ensemble(sensitive_ensemble),
        :elastic_subset_order_sensitive,
    )) == 1
    minimum_search = NLPDiagnostics.ElasticMinimumRelaxationSearch(
        [subset_reference], 1, [positive_subset.baseline], 3, false, 1e-8,
    )
    @test length(findings(
        NLPDiagnostics.analyze_minimum_elastic_relaxation_search(minimum_search),
        :elastic_minimum_relaxation_support,
    )) == 1
    truncated_minimum_search = NLPDiagnostics.ElasticMinimumRelaxationSearch(
        [subset_reference], nothing, NLPDiagnostics.ElasticSubsetProbe[], 2, true, 1e-8,
    )
    @test length(findings(
        NLPDiagnostics.analyze_minimum_elastic_relaxation_search(truncated_minimum_search),
        :elastic_minimum_relaxation_truncated,
    )) == 1
    conflict_model = MOIU.Model{Float64}()
    conflict_variable = MOI.add_variable(conflict_model)
    conflict_constraint = MOI.add_constraint(
        conflict_model,
        MOI.ScalarAffineFunction([MOI.ScalarAffineTerm(1.0, conflict_variable)], 0.0),
        MOI.LessThan(0.0),
    )
    conflict_optimizer = MOIU.MockOptimizer()
    conflict_optimizer.optimize! = function (mock)
        MOI.set(mock, MOI.ConflictStatus(), MOI.CONFLICT_FOUND)
        copied_constraint = only(MOI.get(
            mock,
            MOI.ListOfConstraintIndices{MOI.ScalarAffineFunction{Float64},MOI.LessThan{Float64}}(),
        ))
        MOI.set(mock, MOI.ConstraintConflictStatus(), copied_constraint, MOI.IN_CONFLICT)
    end
    conflict_result = NLPDiagnostics.compute_solver_conflict!(
        conflict_optimizer, conflict_model,
    )
    @test conflict_result.error === nothing
    @test only(only(conflict_result.conflicts)).index == conflict_constraint.value
    @test length(findings(
        NLPDiagnostics.analyze_solver_conflict(conflict_result),
        :solver_conflict_membership,
    )) == 1
    conflict_reference = NLPDiagnostics.EntityRef(:constraint, conflict_constraint.value)
    conflict_subset = NLPDiagnostics.ElasticSubsetSearch(
        NLPDiagnostics.ElasticSubsetProbe(
            [conflict_reference], 1.0, true, "LOCALLY_INFEASIBLE", "FEASIBLE_POINT",
        ),
        NLPDiagnostics.ElasticSubsetProbe[],
        [conflict_reference],
        NLPDiagnostics.EntityRef[],
        1e-8,
    )
    @test length(findings(
        NLPDiagnostics.analyze_solver_conflict_crosscheck(conflict_result, conflict_subset),
        :solver_conflict_elastic_overlap,
    )) == 1
    zero_subset = NLPDiagnostics.ElasticSubsetSearch(
        NLPDiagnostics.ElasticSubsetProbe(
            [subset_reference], 0.0, true, "OPTIMAL", "FEASIBLE_POINT",
        ),
        NLPDiagnostics.ElasticSubsetProbe[],
        NLPDiagnostics.EntityRef[],
        [subset_reference],
        1e-8,
    )
    @test length(findings(
        NLPDiagnostics.analyze_local_elastic_subset_search(zero_subset),
        :elastic_subset_no_positive_residual,
    )) == 1
    @test_throws ArgumentError NLPDiagnostics.local_elastic_subset_search(
        model, () -> nothing,
    )

    domain_guard_model = MOIU.Model{Float64}()
    guarded = MOI.add_variable(domain_guard_model)
    MOI.add_constraint(domain_guard_model, guarded, MOI.LessThan(-1.0))
    guarded_constraint = MOI.add_constraint(
        domain_guard_model,
        MOI.ScalarNonlinearFunction(:log, Any[guarded]),
        MOI.LessThan(0.0),
    )
    guard_plan = NLPDiagnostics.elastic_domain_guard_plan(domain_guard_model)
    @test guard_plan.selected_constraint_count == 1
    @test length(guard_plan.guards) == 1
    @test only(guard_plan.guards).source.index == guarded_constraint.value
    @test only(guard_plan.guards).materializable
    guard_report = NLPDiagnostics.analyze_elastic_domain_guard_plan(guard_plan)
    @test length(findings(guard_report, :elastic_proven_domain_guard_violation)) == 1
    guarded_auxiliary = NLPDiagnostics.build_elastic_feasibility_model(
        domain_guard_model;
        domain_guard_margin = 1e-6,
    )
    @test length(guarded_auxiliary.domain_guards) == 1
    @test guarded_auxiliary.domain_guard_margin == 1e-6
    mapped_guarded = guarded_auxiliary.source_variable_map[guarded]
    guard_constraints = MOI.get(
        guarded_auxiliary.model,
        MOI.ListOfConstraintIndices{MOI.ScalarAffineFunction{Float64},MOI.GreaterThan{Float64}}(),
    )
    @test any(
        index ->
            only(MOI.get(guarded_auxiliary.model, MOI.ConstraintFunction(), index).terms).variable == mapped_guarded &&
            MOI.get(guarded_auxiliary.model, MOI.ConstraintSet(), index).lower == 1e-6,
        guard_constraints,
    )
    @test_throws ArgumentError NLPDiagnostics.build_elastic_feasibility_model(
        domain_guard_model;
        domain_guard_margin = 0.0,
    )

    log1mexp_guard_model = MOIU.Model{Float64}()
    log1mexp_argument = MOI.add_variable(log1mexp_guard_model)
    MOI.add_constraint(
        log1mexp_guard_model,
        MOI.ScalarNonlinearFunction(:log1mexp, Any[log1mexp_argument]),
        MOI.LessThan(0.0),
    )
    log1mexp_plan = NLPDiagnostics.elastic_domain_guard_plan(log1mexp_guard_model)
    @test length(log1mexp_plan.guards) == 1
    @test only(log1mexp_plan.guards).materializable
    log1mexp_auxiliary = NLPDiagnostics.build_elastic_feasibility_model(
        log1mexp_guard_model;
        domain_guard_margin = 1e-5,
    )
    mapped_log1mexp = log1mexp_auxiliary.source_variable_map[log1mexp_argument]
    log1mexp_guards = MOI.get(
        log1mexp_auxiliary.model,
        MOI.ListOfConstraintIndices{MOI.ScalarAffineFunction{Float64},MOI.LessThan{Float64}}(),
    )
    @test any(
        index ->
            only(MOI.get(log1mexp_auxiliary.model, MOI.ConstraintFunction(), index).terms).variable == mapped_log1mexp &&
            MOI.get(log1mexp_auxiliary.model, MOI.ConstraintSet(), index).upper == -1e-5,
        log1mexp_guards,
    )

    logdiffexp_guard_model = MOIU.Model{Float64}()
    logdiffexp_a, logdiffexp_b = MOI.add_variables(logdiffexp_guard_model, 2)
    MOI.add_constraint(
        logdiffexp_guard_model,
        MOI.ScalarNonlinearFunction(:logdiffexp, Any[logdiffexp_a, logdiffexp_b]),
        MOI.LessThan(0.0),
    )
    logdiffexp_plan = NLPDiagnostics.elastic_domain_guard_plan(logdiffexp_guard_model)
    @test length(logdiffexp_plan.guards) == 1
    @test only(logdiffexp_plan.guards).materializable
    @test only(logdiffexp_plan.guards).related_argument == 2
    logdiffexp_guard_report = NLPDiagnostics.analyze_elastic_domain_guard_plan(
        logdiffexp_plan,
    )
    @test Dict(only(logdiffexp_guard_report.findings).evidence[1].details)["related_argument"] == "2"
    logdiffexp_auxiliary = NLPDiagnostics.build_elastic_feasibility_model(
        logdiffexp_guard_model;
        domain_guard_margin = 1e-5,
    )
    mapped_logdiffexp_a = logdiffexp_auxiliary.source_variable_map[logdiffexp_a]
    mapped_logdiffexp_b = logdiffexp_auxiliary.source_variable_map[logdiffexp_b]
    logdiffexp_guards = MOI.get(
        logdiffexp_auxiliary.model,
        MOI.ListOfConstraintIndices{MOI.ScalarAffineFunction{Float64},MOI.GreaterThan{Float64}}(),
    )
    @test any(logdiffexp_guards) do index
        function_value = MOI.get(logdiffexp_auxiliary.model, MOI.ConstraintFunction(), index)
        coefficients = Dict(term.variable => term.coefficient for term in function_value.terms)
        MOI.get(logdiffexp_auxiliary.model, MOI.ConstraintSet(), index).lower == 1e-5 &&
        get(coefficients, mapped_logdiffexp_a, 0.0) == 1.0 &&
        get(coefficients, mapped_logdiffexp_b, 0.0) == -1.0
    end

    reciprocal_guard_model = MOIU.Model{Float64}()
    reciprocal = MOI.add_variable(reciprocal_guard_model)
    MOI.add_constraint(reciprocal_guard_model, reciprocal, MOI.GreaterThan(0.0))
    MOI.add_constraint(
        reciprocal_guard_model,
        MOI.ScalarNonlinearFunction(:inv, Any[reciprocal]),
        MOI.LessThan(2.0),
    )
    reciprocal_plan = NLPDiagnostics.elastic_domain_guard_plan(reciprocal_guard_model)
    @test length(reciprocal_plan.guards) == 1
    @test only(reciprocal_plan.guards).materializable
    reciprocal_auxiliary = NLPDiagnostics.build_elastic_feasibility_model(
        reciprocal_guard_model;
        domain_guard_margin = 1e-5,
    )
    mapped_reciprocal = reciprocal_auxiliary.source_variable_map[reciprocal]
    reciprocal_guards = MOI.get(
        reciprocal_auxiliary.model,
        MOI.ListOfConstraintIndices{MOI.ScalarAffineFunction{Float64},MOI.GreaterThan{Float64}}(),
    )
    @test any(
        index ->
            only(MOI.get(reciprocal_auxiliary.model, MOI.ConstraintFunction(), index).terms).variable == mapped_reciprocal &&
            MOI.get(reciprocal_auxiliary.model, MOI.ConstraintSet(), index).lower == 1e-5,
        reciprocal_guards,
    )

    atanh_guard_model = MOIU.Model{Float64}()
    hyperbolic_argument = MOI.add_variable(atanh_guard_model)
    MOI.add_constraint(
        atanh_guard_model,
        MOI.ScalarNonlinearFunction(:atanh, Any[hyperbolic_argument]),
        MOI.LessThan(2.0),
    )
    atanh_plan = NLPDiagnostics.elastic_domain_guard_plan(atanh_guard_model)
    @test length(atanh_plan.guards) == 1
    @test only(atanh_plan.guards).materializable
    atanh_auxiliary = NLPDiagnostics.build_elastic_feasibility_model(
        atanh_guard_model;
        domain_guard_margin = 1e-5,
    )
    mapped_hyperbolic = atanh_auxiliary.source_variable_map[hyperbolic_argument]
    atanh_lower_guards = MOI.get(
        atanh_auxiliary.model,
        MOI.ListOfConstraintIndices{MOI.ScalarAffineFunction{Float64},MOI.GreaterThan{Float64}}(),
    )
    atanh_upper_guards = MOI.get(
        atanh_auxiliary.model,
        MOI.ListOfConstraintIndices{MOI.ScalarAffineFunction{Float64},MOI.LessThan{Float64}}(),
    )
    @test any(
        index ->
            only(MOI.get(atanh_auxiliary.model, MOI.ConstraintFunction(), index).terms).variable == mapped_hyperbolic &&
            MOI.get(atanh_auxiliary.model, MOI.ConstraintSet(), index).lower == -0.99999,
        atanh_lower_guards,
    )
    @test any(
        index ->
            only(MOI.get(atanh_auxiliary.model, MOI.ConstraintFunction(), index).terms).variable == mapped_hyperbolic &&
            MOI.get(atanh_auxiliary.model, MOI.ConstraintSet(), index).upper == 0.99999,
        atanh_upper_guards,
    )

    periodic_guard_model = MOIU.Model{Float64}()
    periodic_argument = MOI.add_variable(periodic_guard_model)
    MOI.add_constraint(periodic_guard_model, periodic_argument, MOI.Interval(0.0, Float64(pi / 2)))
    MOI.add_constraint(
        periodic_guard_model,
        MOI.ScalarNonlinearFunction(:tan, Any[periodic_argument]),
        MOI.LessThan(10.0),
    )
    periodic_plan = NLPDiagnostics.elastic_domain_guard_plan(periodic_guard_model)
    @test length(periodic_plan.guards) == 1
    @test only(periodic_plan.guards).materializable
    periodic_auxiliary = NLPDiagnostics.build_elastic_feasibility_model(
        periodic_guard_model;
        domain_guard_margin = 1e-5,
    )
    mapped_periodic = periodic_auxiliary.source_variable_map[periodic_argument]
    periodic_guards = MOI.get(
        periodic_auxiliary.model,
        MOI.ListOfConstraintIndices{MOI.ScalarAffineFunction{Float64},MOI.LessThan{Float64}}(),
    )
    @test any(
        index ->
            only(MOI.get(periodic_auxiliary.model, MOI.ConstraintFunction(), index).terms).variable == mapped_periodic &&
            MOI.get(periodic_auxiliary.model, MOI.ConstraintSet(), index).upper ≈ Float64(pi / 2) - 1e-5,
        periodic_guards,
    )
    crossing_periodic_model = MOIU.Model{Float64}()
    crossing_argument = MOI.add_variable(crossing_periodic_model)
    MOI.add_constraint(crossing_periodic_model, crossing_argument, MOI.Interval(-1.0, 2.0))
    MOI.add_constraint(
        crossing_periodic_model,
        MOI.ScalarNonlinearFunction(:tan, Any[crossing_argument]),
        MOI.LessThan(10.0),
    )
    crossing_plan = NLPDiagnostics.elastic_domain_guard_plan(crossing_periodic_model)
    @test length(crossing_plan.guards) == 1
    @test !only(crossing_plan.guards).materializable

    bound_model = MOIU.Model{Float64}()
    b = MOI.add_variable(bound_model)
    bound = MOI.add_constraint(bound_model, b, MOI.GreaterThan(1.0))
    @test NLPDiagnostics.elastic_feasibility_plan(bound_model).relaxation_count == 0
    bound_auxiliary = NLPDiagnostics.build_elastic_feasibility_model(
        bound_model;
        relax_variable_bounds = true,
    )
    @test only(bound_auxiliary.relaxations).source.index == bound.value
    @test length(only(bound_auxiliary.relaxations).slacks) == 1
end

@testset "synthetic sparse profiling corpus" begin
    @test_throws ArgumentError NLPDiagnostics.synthetic_sparse_profile_corpus(dimension = 1)
    models, cases = NLPDiagnostics.synthetic_sparse_profile_corpus(dimension = 3)
    @test length(models) == 3
    @test [case.name for case in cases] == [
        "sparse_banded_full_rank",
        "sparse_banded_rank_deficient",
        "sparse_banded_scaled",
    ]
    @test cases[3].metadata["scale"] == "1.0e8"
    result = NLPDiagnostics.profile_case(
        models[2],
        cases[2];
        rank_max_dense_entries = 1,
    )
    @test any(
        finding -> finding.code == :sparse_qr_jacobian_rank_deficiency,
        result.numerical_report.findings,
    )
    scaled_result = NLPDiagnostics.profile_case(
        models[3],
        cases[3];
        rank_max_dense_entries = 1,
    )
    @test any(
        finding -> finding.code == :sparse_qr_pivot_scale_spread,
        scaled_result.numerical_report.findings,
    )
    aggregates = NLPDiagnostics.profile_cases_repeated(
        models,
        cases;
        repetitions = 1,
        warmup = false,
        rank_max_dense_entries = 1,
    )
    @test sort!(collect(keys(aggregates))) == [case.name for case in cases]
    @test all(length(aggregate.runs) == 1 for aggregate in values(aggregates))
    ladder = NLPDiagnostics.profile_synthetic_sparse_ladder(
        [3, 4];
        repetitions = 1,
        warmup = false,
        rank_max_dense_entries = 1,
    )
    @test sort!(collect(keys(ladder))) == [3, 4]
    @test all(length(aggregates_by_size) == 3 for aggregates_by_size in values(ladder))
    @test_throws ArgumentError NLPDiagnostics.profile_synthetic_sparse_ladder([3, 3])
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

function NLPDiagnostics.fixed_operator_value(
    ::Val{:fixed_test_operator},
    values::Vector{Any},
)
    return only(values) + 1
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

    @testset "affine and quadratic term cancellation removes false incidence" begin
        affine_model = new_model()
        x = MOI.add_variable(affine_model)
        F = MOI.ScalarAffineFunction{Float64}
        T = MOI.ScalarAffineTerm{Float64}
        cancelled_affine = F([T(1.0, x), T(-1.0, x)], 2.0)
        MOI.add_constraint(affine_model, cancelled_affine, MOI.LessThan(1.0))
        affine_report = NLPDiagnostics.analyze_static(affine_model)
        @test length(findings(affine_report, :infeasible_constant_constraint)) == 1
        @test length(findings(affine_report, :disconnected_variable)) == 1

        quadratic_model = new_model()
        y = MOI.add_variable(quadratic_model)
        QT = MOI.ScalarQuadraticTerm{Float64}
        QF = MOI.ScalarQuadraticFunction{Float64}
        cancelled_quadratic = QF(
            QT[QT(2.0, y, y), QT(-2.0, y, y)],
            MOI.ScalarAffineTerm{Float64}[],
            0.0,
        )
        MOI.add_constraint(quadratic_model, cancelled_quadratic, MOI.EqualTo(0.0))
        quadratic_report = NLPDiagnostics.analyze_static(quadratic_model)
        @test length(findings(quadratic_report, :redundant_constant_constraint)) == 1
        @test length(findings(quadratic_report, :disconnected_variable)) == 1
    end

    @testset "direct nonlinear variable cancellation is folded conservatively" begin
        model = new_model()
        x = MOI.add_variable(model)
        cancelled = MOI.ScalarNonlinearFunction(:-, Any[x, x])
        expression = MOI.ScalarNonlinearFunction(:sin, Any[cancelled])
        MOI.add_constraint(model, expression, MOI.LessThan(-1.0))
        report = NLPDiagnostics.analyze_static(model)
        @test length(findings(report, :infeasible_constant_constraint)) == 1
        @test length(findings(report, :disconnected_variable)) == 1
    end

    @testset "direct zero products are folded without hiding nested operators" begin
        model = new_model()
        x = MOI.add_variable(model)
        zero_product = MOI.ScalarNonlinearFunction(:*, Any[0.0, x])
        MOI.add_constraint(model, zero_product, MOI.GreaterThan(1.0))
        report = NLPDiagnostics.analyze_static(model)
        @test length(findings(report, :infeasible_constant_constraint)) == 1
        @test length(findings(report, :disconnected_variable)) == 1

        guarded = new_model()
        y = MOI.add_variable(guarded)
        unsafe_operand = MOI.ScalarNonlinearFunction(:log, Any[y])
        guarded_product = MOI.ScalarNonlinearFunction(:*, Any[0.0, unsafe_operand])
        MOI.add_constraint(guarded, guarded_product, MOI.EqualTo(0.0))
        guarded_report = NLPDiagnostics.analyze_static(guarded)
        @test isempty(findings(guarded_report, :redundant_constant_constraint))
        @test isempty(findings(guarded_report, :disconnected_variable))
    end

    @testset "self division is identified only on a proven nonzero domain" begin
        model = new_model()
        x = MOI.add_variable(model)
        MOI.add_constraint(model, x, MOI.GreaterThan(1.0))
        identity = MOI.ScalarNonlinearFunction(:/, Any[x, x])
        MOI.add_constraint(model, identity, MOI.LessThan(2.0))
        report = NLPDiagnostics.analyze_static(model)
        finding = only(findings(report, :nonzero_self_division_identity))
        @test finding.basis == NLPDiagnostics.MathematicalProof
        @test evidence_details(finding)["lower"] == "1.0"
        @test length(
            findings(report, :redundant_nonzero_self_division_constraint),
        ) == 1

        infeasible = new_model()
        z = MOI.add_variable(infeasible)
        MOI.add_constraint(infeasible, z, MOI.GreaterThan(1.0))
        MOI.add_constraint(
            infeasible,
            MOI.ScalarNonlinearFunction(:/, Any[z, z]),
            MOI.LessThan(0.5),
        )
        infeasible_report = NLPDiagnostics.analyze_static(infeasible)
        @test length(
            findings(infeasible_report, :infeasible_nonzero_self_division_constraint),
        ) == 1

        uncertain = new_model()
        y = MOI.add_variable(uncertain)
        MOI.add_constraint(
            uncertain,
            MOI.ScalarNonlinearFunction(:/, Any[y, y]),
            MOI.LessThan(2.0),
        )
        uncertain_report = NLPDiagnostics.analyze_static(uncertain)
        @test isempty(findings(uncertain_report, :nonzero_self_division_identity))
    end

    @testset "root self-division objectives are proven constant" begin
        model = new_model()
        x = MOI.add_variable(model)
        MOI.add_constraint(model, x, MOI.GreaterThan(1.0))
        objective = MOI.ScalarNonlinearFunction(:/, Any[x, x])
        MOI.set(model, MOI.ObjectiveSense(), MOI.MIN_SENSE)
        MOI.set(model, MOI.ObjectiveFunction{MOI.ScalarNonlinearFunction}(), objective)
        report = NLPDiagnostics.analyze_static(model)
        constant = only(
            findings(report, :constant_nonzero_self_division_objective),
        )
        @test constant.basis == NLPDiagnostics.MathematicalProof
        @test evidence_details(constant)["value"] == "1"
    end

    @testset "absolute values are resolved only by declared sign bounds" begin
        model = new_model()
        x = MOI.add_variable(model)
        MOI.add_constraint(model, x, MOI.GreaterThan(0.0))
        MOI.add_constraint(
            model,
            MOI.ScalarNonlinearFunction(:abs, Any[x]),
            MOI.LessThan(2.0),
        )
        report = NLPDiagnostics.analyze_static(model)
        resolved = only(findings(report, :sign_resolved_absolute_value))
        @test resolved.basis == NLPDiagnostics.MathematicalProof
        @test evidence_details(resolved)["replacement"] == "x"

        uncertain = new_model()
        y = MOI.add_variable(uncertain)
        MOI.add_constraint(
            uncertain,
            MOI.ScalarNonlinearFunction(:abs, Any[y]),
            MOI.LessThan(2.0),
        )
        @test isempty(findings(
            NLPDiagnostics.analyze_static(uncertain),
            :sign_resolved_absolute_value,
        ))
    end

    @testset "absolute zero constraints imply a fixed variable" begin
        model = new_model()
        x = MOI.add_variable(model)
        absolute = MOI.ScalarNonlinearFunction(:abs, Any[x])
        MOI.add_constraint(model, absolute, MOI.EqualTo(0.0))
        report = NLPDiagnostics.analyze_static(model)
        fixed = only(findings(report, :absolute_zero_implies_fixed_variable))
        @test fixed.basis == NLPDiagnostics.MathematicalProof
        @test evidence_details(fixed)["implied_value"] == "0"

        interval_model = new_model()
        y = MOI.add_variable(interval_model)
        MOI.add_constraint(
            interval_model,
            MOI.ScalarNonlinearFunction(:abs, Any[y]),
            MOI.Interval(0.0, 0.0),
        )
        @test length(findings(
            NLPDiagnostics.analyze_static(interval_model),
            :absolute_zero_implies_fixed_variable,
        )) == 1

        square_model = new_model()
        z = MOI.add_variable(square_model)
        MOI.add_constraint(
            square_model,
            MOI.ScalarNonlinearFunction(:^, Any[z, 2.0]),
            MOI.EqualTo(0.0),
        )
        @test length(findings(
            NLPDiagnostics.analyze_static(square_model),
            :square_zero_implies_fixed_variable,
        )) == 1

        negative_square = new_model()
        w = MOI.add_variable(negative_square)
        MOI.add_constraint(
            negative_square,
            MOI.ScalarNonlinearFunction(:^, Any[w, 2.0]),
            MOI.LessThan(-1.0),
        )
        @test length(findings(
            NLPDiagnostics.analyze_static(negative_square),
            :infeasible_negative_square_constraint,
        )) == 1

        two_branch = new_model()
        q = MOI.add_variable(two_branch)
        MOI.add_constraint(
            two_branch,
            MOI.ScalarNonlinearFunction(:^, Any[q, 2.0]),
            MOI.EqualTo(4.0),
        )
        branch = only(findings(
            NLPDiagnostics.analyze_static(two_branch),
            :positive_square_level_set,
        ))
        @test evidence_details(branch)["root_magnitude"] == "2.0"

        signed_branch = new_model()
        r = MOI.add_variable(signed_branch)
        MOI.add_constraint(signed_branch, r, MOI.GreaterThan(0.0))
        MOI.add_constraint(signed_branch, MOI.ScalarNonlinearFunction(:^, Any[r, 2.0]), MOI.EqualTo(4.0))
        resolved = only(findings(NLPDiagnostics.analyze_static(signed_branch), :sign_resolved_square_level_set))
        @test evidence_details(resolved)["implied_value"] == "2.0"

        sqrt_model = new_model()
        s = MOI.add_variable(sqrt_model)
        MOI.add_constraint(sqrt_model, MOI.ScalarNonlinearFunction(:sqrt, Any[s]), MOI.EqualTo(0.0))
        @test length(findings(NLPDiagnostics.analyze_static(sqrt_model), :square_root_zero_implies_fixed_variable)) == 1

        negative_sqrt = new_model()
        u = MOI.add_variable(negative_sqrt)
        MOI.add_constraint(negative_sqrt, MOI.ScalarNonlinearFunction(:sqrt, Any[u]), MOI.LessThan(-1.0))
        @test length(findings(NLPDiagnostics.analyze_static(negative_sqrt), :infeasible_negative_square_root_constraint)) == 1

        nonpositive_exp = new_model()
        v = MOI.add_variable(nonpositive_exp)
        MOI.add_constraint(nonpositive_exp, MOI.ScalarNonlinearFunction(:exp, Any[v]), MOI.LessThan(0.0))
        @test length(findings(NLPDiagnostics.analyze_static(nonpositive_exp), :infeasible_nonpositive_exponential_constraint)) == 1

        for (operator, set_value) in [
            (:exp2, MOI.LessThan(0.0)),
            (:expm1, MOI.LessThan(-1.0)),
            (:log1mexp, MOI.GreaterThan(0.0)),
            (:logistic, MOI.EqualTo(1.0)),
            (:softplus, MOI.LessThan(0.0)),
            (:logcosh, MOI.LessThan(-0.1)),
            (:abs, MOI.LessThan(-0.1)),
            (:cosh, MOI.LessThan(0.9)),
            (:sin, MOI.GreaterThan(1.1)),
            (:cos, MOI.LessThan(-1.1)),
            (:sind, MOI.GreaterThan(1.1)),
            (:cosd, MOI.LessThan(-1.1)),
            (:tanh, MOI.GreaterThan(1.0)),
            (:asin, MOI.GreaterThan(pi / 2 + 0.1)),
            (:acos, MOI.LessThan(-0.1)),
            (:acos, MOI.GreaterThan(pi + 0.1)),
            (:atan, MOI.EqualTo(pi / 2)),
            (:asind, MOI.GreaterThan(90.1)),
            (:acosd, MOI.LessThan(-0.1)),
            (:acosd, MOI.GreaterThan(180.1)),
            (:atand, MOI.EqualTo(90.0)),
        ]
            range_model = new_model()
            range_x = MOI.add_variable(range_model)
            MOI.add_constraint(
                range_model,
                MOI.ScalarNonlinearFunction(operator, Any[range_x]),
                set_value,
            )
            range_finding = only(findings(
                NLPDiagnostics.analyze_static(range_model),
                :infeasible_unary_operator_range_constraint,
            ))
            @test range_finding.basis == NLPDiagnostics.MathematicalProof
            @test range_finding.confidence == NLPDiagnostics.ConfidenceCertain
            @test evidence_details(range_finding)["operator"] == string(operator)
        end

        boundary_cosh = new_model()
        boundary_x = MOI.add_variable(boundary_cosh)
        MOI.add_constraint(
            boundary_cosh,
            MOI.ScalarNonlinearFunction(:cosh, Any[boundary_x]),
            MOI.EqualTo(1.0),
        )
        @test isempty(findings(
            NLPDiagnostics.analyze_static(boundary_cosh),
            :infeasible_unary_operator_range_constraint,
        ))

        boundary_acos = new_model()
        boundary_acos_x = MOI.add_variable(boundary_acos)
        MOI.add_constraint(
            boundary_acos,
            MOI.ScalarNonlinearFunction(:acos, Any[boundary_acos_x]),
            MOI.Interval(0.0, Float64(pi)),
        )
        @test isempty(findings(
            NLPDiagnostics.analyze_static(boundary_acos),
            :infeasible_unary_operator_range_constraint,
        ))

        @test NLPDiagnostics.operator_interval(
            Val(:asind), [NLPDiagnostics.IntervalEnclosure(-1.0, 1.0)], Any[],
        ).lower == -90.0
        @test NLPDiagnostics.operator_interval(
            Val(:acosd), [NLPDiagnostics.IntervalEnclosure(-1.0, 1.0)], Any[],
        ).upper == 180.0
        atand_interval = NLPDiagnostics.operator_interval(
            Val(:atand), [NLPDiagnostics.IntervalEnclosure(-1.0, 1.0)], Any[],
        )
        @test atand_interval.lower == atand(-1.0)
        @test atand_interval.upper == atand(1.0)

        sinh_interval = NLPDiagnostics.operator_interval(
            Val(:sinh), [NLPDiagnostics.IntervalEnclosure(-1.0, 2.0)], Any[],
        )
        @test sinh_interval.lower == sinh(-1.0)
        @test sinh_interval.upper == sinh(2.0)
        cosh_interval = NLPDiagnostics.operator_interval(
            Val(:cosh), [NLPDiagnostics.IntervalEnclosure(-2.0, 1.0)], Any[],
        )
        @test cosh_interval.lower == 1.0
        @test cosh_interval.upper == cosh(2.0)
        atanh_interval = NLPDiagnostics.operator_interval(
            Val(:atanh), [NLPDiagnostics.IntervalEnclosure(-1.0, 0.5)], Any[],
        )
        @test atanh_interval.lower == -Inf
        @test atanh_interval.upper == atanh(0.5)
        acosh_interval = NLPDiagnostics.operator_interval(
            Val(:acosh), [NLPDiagnostics.IntervalEnclosure(0.0, 2.0)], Any[],
        )
        @test acosh_interval.lower == 0.0
        @test acosh_interval.upper == acosh(2.0)

        min_interval = NLPDiagnostics.operator_interval(
            Val(:min),
            [
                NLPDiagnostics.IntervalEnclosure(-2.0, 3.0),
                NLPDiagnostics.IntervalEnclosure(1.0, 4.0),
            ],
            Any[],
        )
        @test min_interval.lower == -2.0
        @test min_interval.upper == 3.0
        max_interval = NLPDiagnostics.operator_interval(
            Val(:max),
            [
                NLPDiagnostics.IntervalEnclosure(-2.0, 3.0),
                NLPDiagnostics.IntervalEnclosure(1.0, 4.0),
            ],
            Any[],
        )
        @test max_interval.lower == 1.0
        @test max_interval.upper == 4.0
        @test NLPDiagnostics.operator_interval(
            Val(:sign), [NLPDiagnostics.IntervalEnclosure(0.2, 1.0)], Any[],
        ).lower == 1.0
        sign_crossing = NLPDiagnostics.operator_interval(
            Val(:sign), [NLPDiagnostics.IntervalEnclosure(-1.0, 1.0)], Any[],
        )
        @test sign_crossing.lower == -1.0
        @test sign_crossing.upper == 1.0
        cbrt_interval = NLPDiagnostics.operator_interval(
            Val(:cbrt), [NLPDiagnostics.IntervalEnclosure(-8.0, 27.0)], Any[],
        )
        @test cbrt_interval.lower == -2.0
        @test cbrt_interval.upper == 3.0
        @test NLPDiagnostics.fixed_operator_value(Val(:sign), Any[-2.0]) == -1.0

        logistic_interval = NLPDiagnostics.operator_interval(
            Val(:logistic), [NLPDiagnostics.IntervalEnclosure(-2.0, 2.0)], Any[],
        )
        @test logistic_interval.lower ≈ inv(1 + exp(2.0)) atol = 1.0e-12
        @test logistic_interval.upper ≈ inv(1 + exp(-2.0)) atol = 1.0e-12

        sin_interval = NLPDiagnostics.operator_interval(
            Val(:sin), [NLPDiagnostics.IntervalEnclosure(0.1, 0.2)], Any[],
        )
        @test sin_interval.lower ≈ sin(0.1) atol = 1.0e-12
        @test sin_interval.upper ≈ sin(0.2) atol = 1.0e-12
        cos_interval = NLPDiagnostics.operator_interval(
            Val(:cos), [NLPDiagnostics.IntervalEnclosure(2.9, 3.3)], Any[],
        )
        @test cos_interval.lower == -1.0
        sind_interval = NLPDiagnostics.operator_interval(
            Val(:sind), [NLPDiagnostics.IntervalEnclosure(10.0, 20.0)], Any[],
        )
        @test sind_interval.lower ≈ sind(10.0) atol = 1.0e-12
        @test sind_interval.upper ≈ sind(20.0) atol = 1.0e-12
        tan_interval = NLPDiagnostics.operator_interval(
            Val(:tan), [NLPDiagnostics.IntervalEnclosure(0.1, 0.2)], Any[],
        )
        @test tan_interval.lower ≈ tan(0.1) atol = 1.0e-12
        @test tan_interval.upper ≈ tan(0.2) atol = 1.0e-12
        @test !NLPDiagnostics.operator_interval(
            Val(:tan), [NLPDiagnostics.IntervalEnclosure(1.4, 1.8)], Any[],
        ).informative
        sec_interval = NLPDiagnostics.operator_interval(
            Val(:sec), [NLPDiagnostics.IntervalEnclosure(0.1, 0.2)], Any[],
        )
        @test sec_interval.lower ≈ inv(cos(0.1)) atol = 1.0e-12
        @test sec_interval.upper ≈ inv(cos(0.2)) atol = 1.0e-12
        csc_interval = NLPDiagnostics.operator_interval(
            Val(:csc), [NLPDiagnostics.IntervalEnclosure(0.1, 0.2)], Any[],
        )
        @test csc_interval.lower ≈ inv(sin(0.2)) atol = 1.0e-12
        @test csc_interval.upper ≈ inv(sin(0.1)) atol = 1.0e-12
        @test NLPDiagnostics.fixed_operator_value(Val(:cot), Any[pi / 4]) ≈ 1.0
        asec_interval = NLPDiagnostics.operator_interval(
            Val(:asec), [NLPDiagnostics.IntervalEnclosure(1.0, 2.0)], Any[],
        )
        @test asec_interval.lower == 0.0
        @test asec_interval.upper ≈ acos(0.5) atol = 1.0e-12
        acsc_interval = NLPDiagnostics.operator_interval(
            Val(:acsc), [NLPDiagnostics.IntervalEnclosure(1.0, 2.0)], Any[],
        )
        @test acsc_interval.lower ≈ asin(0.5) atol = 1.0e-12
        @test acsc_interval.upper == Float64(pi) / 2
        @test !NLPDiagnostics.operator_interval(
            Val(:asec), [NLPDiagnostics.IntervalEnclosure(-2.0, 2.0)], Any[],
        ).informative
        @test NLPDiagnostics.fixed_operator_value(Val(:asecd), Any[2.0]) ≈ 60.0
        sech_interval = NLPDiagnostics.operator_interval(
            Val(:sech), [NLPDiagnostics.IntervalEnclosure(0.0, 1.0)], Any[],
        )
        @test sech_interval.lower ≈ inv(cosh(1.0)) atol = 1.0e-12
        @test sech_interval.upper == 1.0
        csch_interval = NLPDiagnostics.operator_interval(
            Val(:csch), [NLPDiagnostics.IntervalEnclosure(1.0, 2.0)], Any[],
        )
        @test csch_interval.lower ≈ inv(sinh(2.0)) atol = 1.0e-12
        @test csch_interval.upper ≈ inv(sinh(1.0)) atol = 1.0e-12
        asech_interval = NLPDiagnostics.operator_interval(
            Val(:asech), [NLPDiagnostics.IntervalEnclosure(0.5, 1.0)], Any[],
        )
        @test asech_interval.lower == 0.0
        @test asech_interval.upper ≈ acosh(2.0) atol = 1.0e-12
        @test NLPDiagnostics.fixed_operator_value(Val(:acsch), Any[2.0]) ≈ asinh(0.5)
    end

    @testset "min/max branches are resolved by declared bounds" begin
        model = new_model()
        x = MOI.add_variable(model)
        MOI.add_constraint(model, x, MOI.LessThan(1.0))
        MOI.add_constraint(
            model,
            MOI.ScalarNonlinearFunction(:min, Any[x, 2.0]),
            MOI.LessThan(3.0),
        )
        report = NLPDiagnostics.analyze_static(model)
        resolved = only(findings(report, :bound_resolved_minmax_expression))
        @test resolved.basis == NLPDiagnostics.MathematicalProof
        @test evidence_details(resolved)["replacement"] == "x"

        constant = new_model()
        y = MOI.add_variable(constant)
        MOI.add_constraint(constant, y, MOI.GreaterThan(3.0))
        MOI.add_constraint(
            constant,
            MOI.ScalarNonlinearFunction(:min, Any[y, 2.0]),
            MOI.LessThan(3.0),
        )
        constant_report = NLPDiagnostics.analyze_static(constant)
        constant_finding = only(
            findings(constant_report, :bound_resolved_minmax_expression),
        )
        @test evidence_details(constant_finding)["replacement"] == "2.0"
        @test length(
            findings(constant_report, :redundant_bound_resolved_minmax_constraint),
        ) == 1

        infeasible = new_model()
        z = MOI.add_variable(infeasible)
        MOI.add_constraint(infeasible, z, MOI.GreaterThan(3.0))
        MOI.add_constraint(
            infeasible,
            MOI.ScalarNonlinearFunction(:min, Any[z, 2.0]),
            MOI.LessThan(1.0),
        )
        infeasible_report = NLPDiagnostics.analyze_static(infeasible)
        @test length(
            findings(infeasible_report, :infeasible_bound_resolved_minmax_constraint),
        ) == 1

        objective_model = new_model()
        w = MOI.add_variable(objective_model)
        MOI.add_constraint(objective_model, w, MOI.GreaterThan(3.0))
        MOI.set(objective_model, MOI.ObjectiveSense(), MOI.MIN_SENSE)
        MOI.set(
            objective_model,
            MOI.ObjectiveFunction{MOI.ScalarNonlinearFunction}(),
            MOI.ScalarNonlinearFunction(:min, Any[w, 2.0]),
        )
        objective_report = NLPDiagnostics.analyze_static(objective_model)
        @test length(
            findings(objective_report, :constant_bound_resolved_minmax_objective),
        ) == 1
    end

    @testset "discrete sign-function rows" begin
        infeasible = new_model()
        x = MOI.add_variable(infeasible)
        MOI.add_constraint(
            infeasible,
            MOI.ScalarNonlinearFunction(:sign, Any[x]),
            MOI.EqualTo(0.5),
        )
        infeasible_finding = only(findings(
            NLPDiagnostics.analyze_static(infeasible),
            :infeasible_sign_range_constraint,
        ))
        @test infeasible_finding.basis == NLPDiagnostics.MathematicalProof
        @test infeasible_finding.confidence == NLPDiagnostics.ConfidenceCertain
        @test evidence_details(infeasible_finding)["operator_range"] == "{-1, 0, 1}"

        fixed = new_model()
        y = MOI.add_variable(fixed)
        MOI.add_constraint(
            fixed,
            MOI.ScalarNonlinearFunction(:sign, Any[y]),
            MOI.EqualTo(0.0),
        )
        fixed_finding = only(findings(
            NLPDiagnostics.analyze_static(fixed),
            :sign_zero_implies_fixed_variable,
        ))
        @test fixed_finding.basis == NLPDiagnostics.MathematicalProof
        @test isempty(findings(
            NLPDiagnostics.analyze_static(fixed),
            :infeasible_sign_range_constraint,
        ))
    end

    @testset "fully fixed affine rows are evaluated without model mutation" begin
        model = new_model()
        x, y = MOI.add_variables(model, 2)
        F = MOI.ScalarAffineFunction{Float64}
        T = MOI.ScalarAffineTerm{Float64}
        MOI.add_constraint(model, x, MOI.EqualTo(1.0))
        MOI.add_constraint(model, y, MOI.EqualTo(2.0))
        MOI.add_constraint(
            model,
            F([T(2.0, x), T(-1.0, y)], 0.0),
            MOI.EqualTo(0.0),
        )
        report = NLPDiagnostics.analyze_static(model)
        redundant = only(findings(report, :redundant_fixed_affine_constraint))
        @test redundant.basis == NLPDiagnostics.MathematicalProof
        @test evidence_details(redundant)["evaluated_value"] == "0.0"

        infeasible = new_model()
        a, b = MOI.add_variables(infeasible, 2)
        MOI.add_constraint(infeasible, a, MOI.EqualTo(1.0))
        MOI.add_constraint(infeasible, b, MOI.EqualTo(2.0))
        MOI.add_constraint(
            infeasible,
            F([T(1.0, a), T(1.0, b)], 0.0),
            MOI.LessThan(2.0),
        )
        infeasible_report = NLPDiagnostics.analyze_static(infeasible)
        @test length(findings(infeasible_report, :infeasible_fixed_affine_constraint)) == 1
    end

    @testset "fully fixed quadratic and nonlinear expressions are evaluated" begin
        model = new_model()
        x = MOI.add_variable(model)
        Q = MOI.ScalarQuadraticFunction{Float64}
        QT = MOI.ScalarQuadraticTerm{Float64}
        MOI.add_constraint(model, x, MOI.EqualTo(2.0))
        # MOI stores the diagonal coefficient as twice the polynomial coefficient.
        MOI.add_constraint(model, Q(QT[QT(2.0, x, x)], MOI.ScalarAffineTerm{Float64}[], 0.0), MOI.EqualTo(4.0))
        report = NLPDiagnostics.analyze_static(model)
        @test length(findings(report, :redundant_fixed_expression_constraint)) == 1

        nonlinear = new_model()
        y = MOI.add_variable(nonlinear)
        MOI.add_constraint(nonlinear, y, MOI.EqualTo(-1.0))
        MOI.add_constraint(
            nonlinear,
            MOI.ScalarNonlinearFunction(:log, Any[y]),
            MOI.LessThan(0.0),
        )
        nonlinear_report = NLPDiagnostics.analyze_static(nonlinear)
        @test length(findings(nonlinear_report, :fixed_expression_domain_violation)) == 1
    end

    @testset "fixed stable nonlinear primitives avoid artificial overflow" begin
        model = new_model()
        x = MOI.add_variable(model)
        MOI.add_constraint(model, x, MOI.EqualTo(1_000.0))
        MOI.add_constraint(
            model,
            MOI.ScalarNonlinearFunction(:log1pexp, Any[x]),
            MOI.EqualTo(1_000.0),
        )
        MOI.add_constraint(
            model,
            MOI.ScalarNonlinearFunction(:logistic, Any[x]),
            MOI.Interval(0.999, 1.0),
        )
        report = NLPDiagnostics.analyze_static(model)
        @test length(findings(report, :redundant_fixed_expression_constraint)) == 2
        @test isempty(findings(report, :fixed_expression_domain_violation))
    end

    @testset "fixed objectives retain feasibility-versus-optimization evidence" begin
        model = new_model()
        x = MOI.add_variable(model)
        MOI.add_constraint(model, x, MOI.EqualTo(3.0))
        F = MOI.ScalarAffineFunction{Float64}
        T = MOI.ScalarAffineTerm{Float64}
        objective = F([T(2.0, x)], 1.0)
        MOI.set(model, MOI.ObjectiveSense(), MOI.MIN_SENSE)
        MOI.set(model, MOI.ObjectiveFunction{F}(), objective)
        report = NLPDiagnostics.analyze_static(model)
        fixed = only(findings(report, :fixed_objective))
        @test fixed.basis == NLPDiagnostics.MathematicalProof
        @test evidence_details(fixed)["objective_value"] == "7.0"
    end

    @testset "constant objectives are distinguished from fixed objectives" begin
        model = new_model()
        F = MOI.ScalarAffineFunction{Float64}
        objective = F(MOI.ScalarAffineTerm{Float64}[], 4.0)
        MOI.set(model, MOI.ObjectiveSense(), MOI.MAX_SENSE)
        MOI.set(model, MOI.ObjectiveFunction{F}(), objective)
        report = NLPDiagnostics.analyze_static(model)
        constant = only(findings(report, :constant_objective))
        @test constant.basis == NLPDiagnostics.MathematicalProof
        @test evidence_details(constant)["objective_value"] == "4.0"
        @test isempty(findings(report, :fixed_objective))
    end

    @testset "disconnected affine objective variables expose conditional rays" begin
        model = new_model()
        x = MOI.add_variable(model)
        MOI.set(model, MOI.ObjectiveSense(), MOI.MIN_SENSE)
        MOI.set(model, MOI.ObjectiveFunction{MOI.VariableIndex}(), x)
        report = NLPDiagnostics.analyze_static(model)
        ray = only(findings(report, :unconstrained_affine_objective_ray))
        @test ray.basis == NLPDiagnostics.MathematicalProof
        @test evidence_details(ray)["missing_bound"] == "lower"

        bounded = new_model()
        y = MOI.add_variable(bounded)
        MOI.add_constraint(bounded, y, MOI.GreaterThan(0.0))
        MOI.set(bounded, MOI.ObjectiveSense(), MOI.MIN_SENSE)
        MOI.set(bounded, MOI.ObjectiveFunction{MOI.VariableIndex}(), y)
        bounded_report = NLPDiagnostics.analyze_static(bounded)
        @test isempty(findings(bounded_report, :unconstrained_affine_objective_ray))

        free_row = new_model()
        z = MOI.add_variable(free_row)
        MOI.add_constraint(free_row, MOI.VectorOfVariables([z]), MOI.Reals(1))
        MOI.set(free_row, MOI.ObjectiveSense(), MOI.MIN_SENSE)
        MOI.set(free_row, MOI.ObjectiveFunction{MOI.VariableIndex}(), z)
        free_row_report = NLPDiagnostics.analyze_static(free_row)
        @test length(
            findings(free_row_report, :unconstrained_affine_objective_ray),
        ) == 1
    end

    @testset "disconnected quadratic objective curvature exposes conditional rays" begin
        model = new_model()
        x = MOI.add_variable(model)
        Q = MOI.ScalarQuadraticFunction{Float64}
        QT = MOI.ScalarQuadraticTerm{Float64}
        objective = Q(QT[QT(-2.0, x, x)], MOI.ScalarAffineTerm{Float64}[], 0.0)
        MOI.set(model, MOI.ObjectiveSense(), MOI.MIN_SENSE)
        MOI.set(model, MOI.ObjectiveFunction{Q}(), objective)
        report = NLPDiagnostics.analyze_static(model)
        ray = only(findings(report, :unconstrained_quadratic_objective_ray))
        @test ray.basis == NLPDiagnostics.MathematicalProof
        @test evidence_details(ray)["polynomial_coefficient"] == "-1.0"

        bounded = new_model()
        y = MOI.add_variable(bounded)
        MOI.add_constraint(bounded, y, MOI.Interval(-1.0, 1.0))
        bounded_objective = Q(
            QT[QT(-2.0, y, y)],
            MOI.ScalarAffineTerm{Float64}[],
            0.0,
        )
        MOI.set(bounded, MOI.ObjectiveSense(), MOI.MIN_SENSE)
        MOI.set(bounded, MOI.ObjectiveFunction{Q}(), bounded_objective)
        bounded_report = NLPDiagnostics.analyze_static(bounded)
        @test isempty(findings(bounded_report, :unconstrained_quadratic_objective_ray))
    end

    @testset "quadratic objectives retain purely affine disconnected rays" begin
        model = new_model()
        x, y = MOI.add_variables(model, 2)
        Q = MOI.ScalarQuadraticFunction{Float64}
        QT = MOI.ScalarQuadraticTerm{Float64}
        T = MOI.ScalarAffineTerm{Float64}
        objective = Q(QT[QT(2.0, y, y)], T[T(1.0, x)], 0.0)
        MOI.set(model, MOI.ObjectiveSense(), MOI.MIN_SENSE)
        MOI.set(model, MOI.ObjectiveFunction{Q}(), objective)
        report = NLPDiagnostics.analyze_static(model)
        @test length(findings(report, :unconstrained_affine_objective_ray)) == 1
        @test isempty(findings(report, :unconstrained_quadratic_objective_ray))
    end

    @testset "fixed custom operator evaluation is explicit and extensible" begin
        @test NLPDiagnostics.fixed_operator_value(
            Val(:fixed_test_operator), [1.0],
        ) == 2.0
        @test isfinite(NLPDiagnostics.fixed_operator_value(
            Val(:logsumexp), [1_000.0, 999.0],
        ))
        unavailable = new_model()
        x = MOI.add_variable(unavailable)
        MOI.add_constraint(unavailable, x, MOI.EqualTo(1.0))
        MOI.add_constraint(
            unavailable,
            MOI.ScalarNonlinearFunction(:unavailable_fixed_operator, Any[x]),
            MOI.EqualTo(0.0),
        )
        unavailable_report = NLPDiagnostics.analyze_static(unavailable)
        @test length(
            findings(unavailable_report, :fixed_expression_evaluation_unavailable),
        ) == 1

        extended = new_model()
        y = MOI.add_variable(extended)
        MOI.add_constraint(extended, y, MOI.EqualTo(1.0))
        MOI.add_constraint(
            extended,
            MOI.ScalarNonlinearFunction(:fixed_test_operator, Any[y]),
            MOI.EqualTo(2.0),
        )
        extended_report = NLPDiagnostics.analyze_static(extended)
        @test length(
            findings(extended_report, :redundant_fixed_expression_constraint),
        ) == 1

        overflow = new_model()
        z = MOI.add_variable(overflow)
        MOI.add_constraint(overflow, z, MOI.EqualTo(1_000.0))
        MOI.add_constraint(
            overflow,
            MOI.ScalarNonlinearFunction(:exp, Any[z]),
            MOI.LessThan(Inf),
        )
        overflow_report = NLPDiagnostics.analyze_static(overflow)
        @test length(
            findings(overflow_report, :fixed_expression_nonfinite_evaluation),
        ) == 1
    end

    @testset "fixed degree-trigonometric primitives are evaluated exactly" begin
        model = new_model()
        x = MOI.add_variable(model)
        MOI.add_constraint(model, x, MOI.EqualTo(0.0))
        MOI.add_constraint(
            model,
            MOI.ScalarNonlinearFunction(:asind, Any[x]),
            MOI.EqualTo(0.0),
        )
        report = NLPDiagnostics.analyze_static(model)
        @test length(findings(report, :redundant_fixed_expression_constraint)) == 1
        @test isempty(findings(report, :fixed_expression_evaluation_unavailable))
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

    @testset "proportional affine equalities are structurally redundant" begin
        model = new_model()
        x, y = MOI.add_variables(model, 2)
        F = MOI.ScalarAffineFunction{Float64}
        T = MOI.ScalarAffineTerm{Float64}
        MOI.add_constraint(model, F([T(1.0, x), T(-1.0, y)], 0.0), MOI.EqualTo(0.0))
        MOI.add_constraint(model, F([T(-2.0, x), T(2.0, y)], 0.0), MOI.EqualTo(0.0))
        report = NLPDiagnostics.analyze_static(model)
        @test length(
            findings(report, :proportional_affine_equality_constraints),
        ) == 1
        @test isempty(findings(report, :duplicate_constraint))
    end

    @testset "proportional affine inequalities preserve orientation" begin
        model = new_model()
        x = MOI.add_variable(model)
        F = MOI.ScalarAffineFunction{Float64}
        T = MOI.ScalarAffineTerm{Float64}
        MOI.add_constraint(model, F([T(1.0, x)], 0.0), MOI.LessThan(1.0))
        MOI.add_constraint(model, F([T(2.0, x)], 0.0), MOI.LessThan(2.0))
        MOI.add_constraint(model, F([T(-1.0, x)], 0.0), MOI.GreaterThan(-1.0))
        report = NLPDiagnostics.analyze_static(model)
        @test length(
            findings(report, :proportional_affine_inequality_constraints),
        ) == 1
    end

    @testset "parallel affine inequalities expose dominated half-spaces" begin
        model = new_model()
        x = MOI.add_variable(model)
        F = MOI.ScalarAffineFunction{Float64}
        T = MOI.ScalarAffineTerm{Float64}
        MOI.add_constraint(model, F([T(1.0, x)], 0.0), MOI.LessThan(1.0))
        MOI.add_constraint(model, F([T(2.0, x)], 0.0), MOI.LessThan(4.0))
        # This is x >= -3, so it is the opposite half-space and must not be
        # treated as dominated by x <= 1.
        MOI.add_constraint(model, F([T(-1.0, x)], 0.0), MOI.LessThan(3.0))
        report = NLPDiagnostics.analyze_static(model)
        dominated = only(findings(report, :dominated_affine_inequality))
        @test dominated.basis == NLPDiagnostics.MathematicalProof
        @test evidence_details(dominated)["tightest_normalized_bound"] == "1.0"
        @test evidence_details(dominated)["dominated_constraint_count"] == "1"
    end

    @testset "opposing affine inequalities prove an empty multi-variable slab" begin
        model = new_model()
        x, y = MOI.add_variables(model, 2)
        F = MOI.ScalarAffineFunction{Float64}
        T = MOI.ScalarAffineTerm{Float64}
        # x + y <= 1 and x + y >= 2; neither variable has declared bounds.
        MOI.add_constraint(model, F([T(1.0, x), T(1.0, y)], 0.0), MOI.LessThan(1.0))
        MOI.add_constraint(model, F([T(-2.0, x), T(-2.0, y)], 0.0), MOI.LessThan(-4.0))
        report = NLPDiagnostics.analyze_static(model)
        inconsistent = only(
            findings(report, :inconsistent_opposing_affine_inequalities),
        )
        @test inconsistent.basis == NLPDiagnostics.MathematicalProof
        @test evidence_details(inconsistent)["normalized_lower"] == "2.0"
        @test evidence_details(inconsistent)["normalized_upper"] == "1.0"
    end

    @testset "affine equalities are checked against parallel half-spaces" begin
        model = new_model()
        x, y = MOI.add_variables(model, 2)
        F = MOI.ScalarAffineFunction{Float64}
        T = MOI.ScalarAffineTerm{Float64}
        expression = F([T(1.0, x), T(1.0, y)], 0.0)
        MOI.add_constraint(model, expression, MOI.EqualTo(2.0))
        MOI.add_constraint(model, expression, MOI.LessThan(1.0))
        report = NLPDiagnostics.analyze_static(model)
        incompatible = only(findings(report, :inconsistent_affine_equality_halfspace))
        @test incompatible.basis == NLPDiagnostics.MathematicalProof
        @test evidence_details(incompatible)["normalized_upper"] == "1.0"

        parallel = new_model()
        a, b = MOI.add_variables(parallel, 2)
        parallel_expression = F([T(1.0, a), T(-1.0, b)], 0.0)
        MOI.add_constraint(parallel, parallel_expression, MOI.EqualTo(0.0))
        MOI.add_constraint(parallel, parallel_expression, MOI.EqualTo(1.0))
        parallel_report = NLPDiagnostics.analyze_static(parallel)
        @test length(findings(parallel_report, :inconsistent_parallel_affine_equalities)) == 1
    end

    @testset "reused scalar expressions retain set-intersection evidence" begin
        model = new_model()
        x = MOI.add_variable(model)
        F = MOI.ScalarAffineFunction{Float64}
        T = MOI.ScalarAffineTerm{Float64}
        expression = F([T(2.0, x)], 1.0)
        MOI.add_constraint(model, expression, MOI.GreaterThan(0.0))
        MOI.add_constraint(model, expression, MOI.LessThan(3.0))
        report = NLPDiagnostics.analyze_static(model)
        @test length(findings(report, :reused_constraint_expression)) == 1

        dominated = new_model()
        z = MOI.add_variable(dominated)
        dominated_expression = F([T(1.0, z)], 0.0)
        MOI.add_constraint(dominated, dominated_expression, MOI.GreaterThan(0.0))
        MOI.add_constraint(dominated, dominated_expression, MOI.GreaterThan(1.0))
        MOI.add_constraint(dominated, dominated_expression, MOI.LessThan(3.0))
        dominated_report = NLPDiagnostics.analyze_static(dominated)
        @test length(
            findings(dominated_report, :dominated_reused_expression_set),
        ) == 1

        inconsistent = new_model()
        y = MOI.add_variable(inconsistent)
        inconsistent_expression = F([T(1.0, y)], 0.0)
        MOI.add_constraint(inconsistent, inconsistent_expression, MOI.GreaterThan(2.0))
        MOI.add_constraint(inconsistent, inconsistent_expression, MOI.LessThan(1.0))
        inconsistent_report = NLPDiagnostics.analyze_static(inconsistent)
        @test length(
            findings(inconsistent_report, :inconsistent_reused_expression_sets),
        ) == 1
    end

    @testset "one-variable affine rows imply bounds without model mutation" begin
        model = new_model()
        x = MOI.add_variable(model)
        F = MOI.ScalarAffineFunction{Float64}
        T = MOI.ScalarAffineTerm{Float64}
        MOI.add_constraint(model, x, MOI.GreaterThan(0.0))
        MOI.add_constraint(model, F([T(2.0, x)], 1.0), MOI.GreaterThan(5.0))
        report = NLPDiagnostics.analyze_static(model)
        implied = only(findings(report, :affine_implied_variable_bound))
        @test evidence_details(implied)["implied_lower"] == "2.0"

        inconsistent = new_model()
        y = MOI.add_variable(inconsistent)
        MOI.add_constraint(inconsistent, F([T(2.0, y)], 0.0), MOI.GreaterThan(4.0))
        MOI.add_constraint(inconsistent, F([T(-1.0, y)], 0.0), MOI.GreaterThan(-1.0))
        inconsistent_report = NLPDiagnostics.analyze_static(inconsistent)
        @test length(
            findings(
                inconsistent_report,
                :inconsistent_affine_implied_variable_bounds,
            ),
        ) == 1
    end

    @testset "multi-variable affine rows support one-pass interval propagation" begin
        model = new_model()
        x, y = MOI.add_variables(model, 2)
        F = MOI.ScalarAffineFunction{Float64}
        T = MOI.ScalarAffineTerm{Float64}
        MOI.add_constraint(model, x, MOI.Interval(0.0, 1.0))
        MOI.add_constraint(
            model,
            F([T(1.0, x), T(1.0, y)], 0.0),
            MOI.LessThan(3.0),
        )
        report = NLPDiagnostics.analyze_static(model)
        propagated = only(findings(report, :affine_interval_propagated_variable_bound))
        @test evidence_details(propagated)["derived_upper"] == "3.0"

        inconsistent = new_model()
        u, v = MOI.add_variables(inconsistent, 2)
        MOI.add_constraint(inconsistent, u, MOI.Interval(0.0, 1.0))
        MOI.add_constraint(inconsistent, v, MOI.GreaterThan(4.0))
        MOI.add_constraint(
            inconsistent,
            F([T(1.0, u), T(1.0, v)], 0.0),
            MOI.LessThan(3.0),
        )
        inconsistent_report = NLPDiagnostics.analyze_static(inconsistent)
        @test !isempty(findings(
            inconsistent_report,
            :inconsistent_affine_interval_propagation,
        ))

        chained = new_model()
        a, b, c = MOI.add_variables(chained, 3)
        MOI.add_constraint(chained, a, MOI.Interval(0.0, 1.0))
        MOI.add_constraint(
            chained,
            F([T(1.0, a), T(1.0, b)], 0.0),
            MOI.EqualTo(3.0),
        )
        MOI.add_constraint(
            chained,
            F([T(1.0, b), T(1.0, c)], 0.0),
            MOI.LessThan(4.0),
        )
        chained_report = NLPDiagnostics.analyze_static(
            chained;
            max_affine_propagation_passes = 3,
        )
        c_finding = only(filter(
            finding -> any(ref -> ref.kind == :variable && ref.index == c.value, finding.affected),
            findings(chained_report, :affine_interval_propagated_variable_bound),
        ))
        @test evidence_details(c_finding)["derived_upper"] == "2.0"
        @test evidence_details(c_finding)["pass_count"] == "3.0"
        @test chained_report.metadata[:affine_interval_propagation_converged] == "true"
        limited_report = NLPDiagnostics.analyze_static(
            chained;
            max_affine_propagation_passes = 1,
        )
        @test length(
            findings(limited_report, :affine_interval_propagation_limit_reached),
        ) == 1
        @test limited_report.metadata[:affine_interval_propagation_converged] == "false"

        fixed = new_model()
        s, t = MOI.add_variables(fixed, 2)
        MOI.add_constraint(fixed, t, MOI.EqualTo(2.0))
        MOI.add_constraint(
            fixed,
            F([T(1.0, s), T(1.0, t)], 0.0),
            MOI.EqualTo(3.0),
        )
        fixed_report = NLPDiagnostics.analyze_static(fixed)
        derived_fixed = only(findings(
            fixed_report,
            :affine_interval_propagated_variable_fixed,
        ))
        @test evidence_details(derived_fixed)["derived_value"] == "1.0"
        @test_throws ArgumentError NLPDiagnostics.analyze_static(
            chained;
            max_affine_propagation_passes = 0,
        )
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
        @test occursin(
            "v$(x.value)=declared_variable_bounds:MathOptInterface.ScalarNonlinearFunction/MathOptInterface.LessThan{Float64}#1",
            evidence_details(proven)["support_interval_origins"],
        )
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

    @testset "atan ratio formulation fingerprint" begin
        ratio_model = new_model()
        denominator, numerator = MOI.add_variables(ratio_model, 2)
        ratio = MOI.ScalarNonlinearFunction(:/, Any[numerator, denominator])
        MOI.add_constraint(
            ratio_model,
            MOI.ScalarNonlinearFunction(:atan, Any[ratio]),
            MOI.LessThan(2.0),
        )
        ratio_finding = only(findings(
            NLPDiagnostics.analyze_static(ratio_model),
            :atan_ratio_may_need_atan2,
        ))
        @test ratio_finding.domain == NLPDiagnostics.RepresentationalIssue
        @test ratio_finding.basis == NLPDiagnostics.HeuristicInterpretation
        @test ratio_finding.confidence == NLPDiagnostics.ConfidenceMedium
        @test Dict(ratio_finding.evidence[1].details)[
            "quadrant_aware_julia_convention"
        ] == "atan(y, x)"

        two_argument_model = new_model()
        x, y = MOI.add_variables(two_argument_model, 2)
        MOI.add_constraint(
            two_argument_model,
            MOI.ScalarNonlinearFunction(:atan, Any[y, x]),
            MOI.LessThan(2.0),
        )
        @test isempty(findings(
            NLPDiagnostics.analyze_static(two_argument_model),
            :atan_ratio_may_need_atan2,
        ))

        # Preserve Julia's `atan(y, x)` semantics when a two-coordinate
        # expression becomes fixed, and do not apply the unary range rule to
        # its rectangular input domain.
        @test NLPDiagnostics.fixed_operator_value(
            Val(:atan),
            Any[0.0, -1.0],
        ) == Float64(pi)
        atan2_interval = NLPDiagnostics.operator_interval(
            Val(:atan),
            [
                NLPDiagnostics.IntervalEnclosure(-1.0, 1.0),
                NLPDiagnostics.IntervalEnclosure(-1.0, 1.0),
            ],
            Any[],
        )
        @test atan2_interval.lower == -Float64(pi)
        @test atan2_interval.upper == Float64(pi)
        @test !atan2_interval.informative
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
        @test report.metadata[:sparse_qr_rank_available] == "true"
        @test report.metadata[:sparse_qr_rank] == "1"
        @test report.metadata[:sparse_qr_rank_scaling] == "none"
        @test report.metadata[:sparse_qr_row_column_rank] == "1"
        @test report.metadata[:sparse_qr_condition_proxy] == "1.0"
        sparse = NLPDiagnostics.sparse_jacobian_pattern_estimate(evaluation)
        @test sparse.available
        # Pattern matching cannot see the numerical dependence of two
        # proportional rows, but it can prove a zero-column deficiency.
        @test sparse.rank_upper_bound == 2
        sparse_qr = NLPDiagnostics.sparse_qr_rank_estimate(evaluation)
        @test sparse_qr.available
        @test sparse_qr.rank == 1
        @test sparse_qr.condition_proxy == 1.0
        scaled_sparse_qr = NLPDiagnostics.sparse_qr_rank_estimate(
            evaluation;
            scaling = :row_column,
        )
        @test scaled_sparse_qr.available
        @test scaled_sparse_qr.rank == 1
        @test scaled_sparse_qr.scaling == :row_column
        iterative_null = NLPDiagnostics.iterative_right_nullspace_estimate(
            evaluation;
            iterations = 200,
        )
        @test iterative_null.available
        @test iterative_null.residual_norm < 1.0e-6
        @test maximum(abs, [1.0 1.0; 2.0 2.0] * iterative_null.direction) <
              1.0e-6
        two_dimensional_model = new_model()
        a, b, c = MOI.add_variables(two_dimensional_model, 3)
        MOI.add_constraint(
            two_dimensional_model,
            F([T(1.0, a), T(-1.0, b)], 0.0),
            MOI.EqualTo(0.0),
        )
        two_dimensional_evaluation = NLPDiagnostics.evaluate_numerical(
            two_dimensional_model,
            [0.0, 0.0, 0.0],
        )
        iterative_subspace =
            NLPDiagnostics.iterative_right_nullspace_subspace_estimate(
                two_dimensional_evaluation,
                2;
                iterations = 200,
            )
        @test iterative_subspace.available
        @test size(iterative_subspace.directions) == (3, 2)
        @test maximum(iterative_subspace.residual_norms) < 1.0e-6
        @test maximum(abs, transpose(iterative_subspace.directions) *
                         iterative_subspace.directions - [1.0 0.0; 0.0 1.0]) <
              1.0e-10
        iterative_spectrum = NLPDiagnostics.iterative_jacobian_spectrum_estimate(
            two_dimensional_evaluation;
            probe_dimension = 2,
            iterations = 200,
        )
        @test iterative_spectrum.available
        @test iterative_spectrum.largest_singular_value_proxy ≈ sqrt(2.0) atol = 1.0e-6
        @test maximum(iterative_spectrum.candidate_small_singular_values) < 1.0e-6
        @test all(value -> value > 1.0e6, iterative_spectrum.spectral_spread_proxies)

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
        @test length(
            findings(guarded_report, :sparse_qr_jacobian_rank_deficiency),
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
        sparse_scaled_report = NLPDiagnostics.analyze_numerical(
            scaled_model,
            [0.0, 0.0];
            rank_max_dense_entries = 1,
            jacobian_condition_threshold = 1.0e5,
        )
        @test length(
            findings(sparse_scaled_report, :sparse_qr_pivot_scale_spread),
        ) == 1
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

        extra_freedom = new_model()
        a, b, c = MOI.add_variables(extra_freedom, 3)
        MOI.add_constraint(
            extra_freedom,
            F([T(1.0, a), T(-1.0, b)], 0.0),
            MOI.EqualTo(0.0),
        )
        partial_expected = NLPDiagnostics.ExpectedNullspaceMode(
            :declared_common_shift,
            [a, b],
            [1.0, 1.0],
        )
        extra_freedom_report = NLPDiagnostics.analyze_degeneracy(
            extra_freedom,
            [0.0, 0.0, 0.0];
            expected_modes = [partial_expected],
        )
        @test length(
            findings(extra_freedom_report, :undeclared_observed_nullspace_directions),
        ) == 1
        duplicate_expected_report = NLPDiagnostics.analyze_degeneracy(
            underdetermined,
            [0.0, 0.0];
            expected_modes = [common_shift, NLPDiagnostics.ExpectedNullspaceMode(
                :same_common_shift,
                [x, y],
                [-2.0, -2.0],
            )],
        )
        @test length(
            findings(
                duplicate_expected_report,
                :expected_nullspace_mode_declarations_dependent,
            ),
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
            task = "one-variable equality",
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
        @test result.case.task == "one-variable equality"
        @test result.case.solver == "Ipopt"
        @test result.case.metadata["network"] == "none"
        @test result.evaluation.point == point
        @test result.callback_statistics[:symbolic_stage][1] == 1
        @test result.derivative_row_method_counts[:exact_symbolic] == 1
        @test result.capability_source_counts[:symbolic] == 1
        @test result.cache_misses == 1
        @test result.cache_hits >= 1
        @test all(value -> value >= 0.0, values(result.stage_seconds))
        @test all(value -> value >= 0, values(result.stage_allocations))
        @test haskey(result.stage_seconds, :static)
        @test haskey(result.stage_allocations, :static)
        @test isempty(result.static_report.findings)
        @test haskey(result.stage_seconds, :expressions)
        @test haskey(result.stage_allocations, :expressions)
        @test isempty(result.expression_report.findings)
        @test haskey(result.stage_allocations, :numerical)
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
        evaluation_allocations = aggregate.stage_allocations[:evaluation]
        @test evaluation_allocations.sample_count == 2
        @test evaluation_allocations.minimum <= evaluation_allocations.mean <=
              evaluation_allocations.maximum
        @test evaluation_allocations.standard_deviation >= 0.0
        stable_rank = only(filter(
            item -> item.stage == :degeneracy &&
                    item.code == :structural_numerical_rank_agreement,
            aggregate.finding_stability,
        ))
        @test stable_rank.occurrence_count == 2
        @test stable_rank.fraction == 1.0
        expected_rank = only(aggregate.expected_evidence)
        @test expected_rank.code == :structural_numerical_rank_agreement
        @test expected_rank.occurrence_count == 2
        @test expected_rank.fraction == 1.0
        repeated_rank = only(filter(
            item -> item.metric == :jacobian_rank,
            aggregate.numerical_summary,
        ))
        @test repeated_rank.run_count == 2
        @test repeated_rank.available_count == 2
        @test repeated_rank.minimum == 1.0
        @test repeated_rank.mean == 1.0
        @test repeated_rank.maximum == 1.0
        repeated_proxy = only(filter(
            item -> item.metric == :sparse_qr_condition_proxy,
            aggregate.numerical_summary,
        ))
        @test repeated_proxy.available_count == 2
        @test repeated_proxy.minimum == 1.0
        unmet_case = NLPDiagnostics.ProfileCase(
            "unmet profile expectation",
            point;
            task = "one-variable equality",
            expected_evidence = [:never_emitted],
        )
        unmet = NLPDiagnostics.profile_case_repeated(
            model,
            unmet_case;
            repetitions = 1,
            warmup = false,
        )
        unmet_expectation = only(unmet.expected_evidence)
        @test unmet_expectation.code == :never_emitted
        @test unmet_expectation.occurrence_count == 0
        @test unmet_expectation.fraction == 0.0
        comparison = NLPDiagnostics.compare_profiles(aggregate, unmet)
        @test comparison.baseline === aggregate
        @test comparison.candidate === unmet
        @test comparison.task_relation == :declared_same_task
        @test comparison.task == "one-variable equality"
        evaluation_comparison = only(filter(
            item -> item.stage == :evaluation,
            comparison.stage_comparisons,
        ))
        @test evaluation_comparison.baseline_seconds >= 0.0
        @test evaluation_comparison.candidate_seconds >= 0.0
        @test evaluation_comparison.baseline_allocations >= 0.0
        @test evaluation_comparison.candidate_allocations >= 0.0
        @test any(
            item -> item.code == :structural_numerical_rank_agreement &&
                    item.baseline_fraction == 1.0 && item.candidate_fraction == 1.0,
            comparison.finding_comparisons,
        )
        rank_comparison = only(filter(
            item -> item.metric == :jacobian_rank,
            comparison.numerical_comparisons,
        ))
        @test rank_comparison.baseline_available_count == 2
        @test rank_comparison.candidate_available_count == 1
        @test rank_comparison.baseline_mean == 1.0
        @test rank_comparison.candidate_mean == 1.0
        @test rank_comparison.mean_difference == 0.0
        @test rank_comparison.mean_ratio == 1.0
        different_task = NLPDiagnostics.profile_case_repeated(
            model,
            NLPDiagnostics.ProfileCase("different task", point; task = "different"),
            repetitions = 1,
            warmup = false,
        )
        @test NLPDiagnostics.compare_profiles(aggregate, different_task).task_relation ==
              :declared_different_task
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

        tangent_shift = new_model()
        t1, t2 = MOI.add_variables(tangent_shift, 2)
        MOI.add_constraint(
            tangent_shift,
            MOI.ScalarAffineFunction([
                MOI.ScalarAffineTerm(1.0, t1),
                MOI.ScalarAffineTerm(-1.0, t2),
            ], 0.0),
            MOI.EqualTo(0.0),
        )
        tangent_report = NLPDiagnostics.analyze_active_set(tangent_shift, [0.0, 0.0])
        @test length(findings(
            tangent_report,
            :active_candidate_uniform_tangent_shift,
        )) == 1
        active_common_shift = NLPDiagnostics.ExpectedNullspaceMode(
            :active_common_shift,
            [t1, t2],
            [1.0, 1.0],
            description = "active common-coordinate shift",
        )
        expected_tangent_report = NLPDiagnostics.analyze_active_set(
            tangent_shift,
            [0.0, 0.0];
            expected_modes = [active_common_shift],
        )
        @test length(findings(
            expected_tangent_report,
            :active_expected_nullspace_mode_observed,
        )) == 1
        extra_tangent = new_model()
        e1, e2, e3 = MOI.add_variables(extra_tangent, 3)
        MOI.add_constraint(
            extra_tangent,
            MOI.ScalarAffineFunction([
                MOI.ScalarAffineTerm(1.0, e1),
                MOI.ScalarAffineTerm(-1.0, e2),
            ], 0.0),
            MOI.EqualTo(0.0),
        )
        declared_tangent = NLPDiagnostics.ExpectedNullspaceMode(
            :declared_tangent,
            [e1, e2],
            [1.0, 1.0],
        )
        extra_tangent_report = NLPDiagnostics.analyze_active_set(
            extra_tangent,
            [0.0, 0.0, 0.0];
            expected_modes = [declared_tangent],
        )
        @test length(findings(
            extra_tangent_report,
            :active_undeclared_tangent_directions,
        )) == 1
        @test length(findings(
            extra_tangent_report,
            :active_structurally_expected_tangent_nullspace,
        )) == 1
        active_stationary = new_model()
        stationary_variable = MOI.add_variable(active_stationary)
        MOI.add_constraint(
            active_stationary,
            MOI.ScalarNonlinearFunction(:^, Any[stationary_variable, 2]),
            MOI.EqualTo(0.0),
        )
        stationary_active_report = NLPDiagnostics.analyze_active_set(
            active_stationary,
            [0.0],
        )
        @test length(findings(
            stationary_active_report,
            :active_unexpected_local_tangent_rank_loss,
        )) == 1
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

        opposing = new_model()
        z = MOI.add_variable(opposing)
        MOI.add_constraint(opposing, z, MOI.GreaterThan(0.0))
        MOI.add_constraint(opposing, z, MOI.LessThan(0.0))
        opposing_evaluation = NLPDiagnostics.evaluate_numerical(opposing, [0.0])
        opposing_summary = NLPDiagnostics.constraint_feasibility_summary(
            opposing,
            opposing_evaluation,
        )
        opposing_screen = NLPDiagnostics.mfcq_screen(
            opposing_evaluation,
            opposing_summary;
            strict_tolerance = 1.0e-10,
        )
        @test opposing_screen.available
        @test !opposing_screen.direction_found
        @test opposing_screen.failure_witness_found
        @test opposing_screen.failure_witness_residual < 1.0e-10
        opposing_report = NLPDiagnostics.analyze_active_set(opposing, [0.0])
        @test length(findings(opposing_report, :mfcq_no_common_descent_witness)) == 1

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
        @test length(findings(
            dependent_report,
            :active_candidate_two_row_dependence,
        )) == 1

        dependent_cluster = new_model()
        p, q = MOI.add_variables(dependent_cluster, 2)
        MOI.add_constraint(dependent_cluster, p, MOI.EqualTo(0.0))
        MOI.add_constraint(dependent_cluster, q, MOI.EqualTo(0.0))
        MOI.add_constraint(
            dependent_cluster,
            MOI.ScalarAffineFunction([
                T(1.0, p),
                T(1.0, q),
            ], 0.0),
            MOI.EqualTo(0.0),
        )
        cluster_report = NLPDiagnostics.analyze_active_set(dependent_cluster, [0.0, 0.0])
        @test length(findings(
            cluster_report,
            :active_candidate_multirow_dependence,
        )) == 1

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
        @test length(findings(
            cone_report,
            :coupled_set_smooth_boundary_tangent_available,
        )) == 1
        @test length(findings(
            cone_report,
            :coupled_set_smooth_boundary_tangent_gradient_available,
        )) == 1
        cone_apex_report = NLPDiagnostics.analyze_active_set(cone_model, [0.0, 0.0])
        @test length(findings(
            cone_apex_report,
            :coupled_set_nonsmooth_boundary_active,
        )) == 1
        @test isempty(findings(
            cone_apex_report,
            :coupled_set_smooth_boundary_tangent_available,
        ))
        outside_cone = NLPDiagnostics.analyze_active_set(cone_model, [0.0, 1.0])
        @test length(findings(outside_cone, :coupled_set_feasibility_violation)) == 1

        rotated_cone_model = new_model()
        rotated_u, rotated_v, rotated_w = MOI.add_variables(rotated_cone_model, 3)
        MOI.add_constraint(
            rotated_cone_model,
            MOI.VectorOfVariables([rotated_u, rotated_v, rotated_w]),
            MOI.RotatedSecondOrderCone(3),
        )
        rotated_smooth_report = NLPDiagnostics.analyze_active_set(
            rotated_cone_model, [1.0, 1.0, sqrt(2.0)],
        )
        @test length(findings(
            rotated_smooth_report,
            :coupled_set_boundary_active,
        )) == 1
        @test length(findings(
            rotated_smooth_report,
            :coupled_set_smooth_boundary_tangent_available,
        )) == 1
        @test length(findings(
            rotated_smooth_report,
            :coupled_set_smooth_boundary_tangent_gradient_available,
        )) == 1
        rotated_axis_report = NLPDiagnostics.analyze_active_set(
            rotated_cone_model, [0.0, 1.0, 0.0],
        )
        @test length(findings(
            rotated_axis_report,
            :coupled_set_nonsmooth_boundary_active,
        )) == 1

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

        flat_shift_model = new_model()
        s1, s2 = MOI.add_variables(flat_shift_model, 2)
        flat_shift_evaluation = NLPDiagnostics.evaluate_numerical(
            flat_shift_model, [0.0, 0.0],
        )
        flat_shift_hessian = NLPDiagnostics.HessianEvaluation(
            flat_shift_evaluation.point,
            1.0,
            [0.0, 0.0],
            NLPDiagnostics.HessianEntry{Float64}[
                NLPDiagnostics.HessianEntry(1, 1, 1.0),
                NLPDiagnostics.HessianEntry(1, 2, -1.0),
                NLPDiagnostics.HessianEntry(2, 2, 1.0),
            ],
            [:test_exact],
            true,
            NLPDiagnostics.EvaluationFailure[],
        )
        flat_shift_report = NLPDiagnostics.analyze_reduced_hessian(
            flat_shift_evaluation,
            flat_shift_hessian;
            active_rows = Int[],
            expected_modes = [
                NLPDiagnostics.ExpectedNullspaceMode(
                    :common_shift,
                    [s1, s2],
                    [1.0, 1.0],
                ),
                NLPDiagnostics.ExpectedNullspaceMode(
                    :differential_shift,
                    [s1, s2],
                    [1.0, -1.0],
                ),
            ],
        )
        @test length(findings(
            flat_shift_report,
            :reduced_hessian_candidate_uniform_flat_direction,
        )) == 1
        @test length(findings(
            flat_shift_report,
            :reduced_hessian_expected_flat_mode_observed,
        )) == 1
        @test length(findings(
            flat_shift_report,
            :reduced_hessian_expected_flat_mode_not_observed,
        )) == 1

        compact_model = new_model()
        c1, c2, c3 = MOI.add_variables(compact_model, 3)
        compact_evaluation = NLPDiagnostics.evaluate_numerical(
            compact_model, [0.0, 0.0, 0.0],
        )
        compact_hessian = NLPDiagnostics.HessianEvaluation(
            compact_evaluation.point,
            1.0,
            zeros(3),
            NLPDiagnostics.HessianEntry{Float64}[
                NLPDiagnostics.HessianEntry(1, 1, 1.0),
                NLPDiagnostics.HessianEntry(1, 2, -1.0),
                NLPDiagnostics.HessianEntry(2, 2, 1.0),
                NLPDiagnostics.HessianEntry(3, 3, 2.0),
            ],
            [:test_exact],
            true,
            NLPDiagnostics.EvaluationFailure[],
        )
        compact_report = NLPDiagnostics.analyze_reduced_hessian(
            compact_evaluation,
            compact_hessian;
            active_rows = Int[],
        )
        compact_findings = findings(
            compact_report,
            :reduced_hessian_candidate_compact_flat_direction,
        )
        @test length(compact_findings) == 1
        @test length(only(compact_findings).affected) == 2

        persistent_evaluation = NLPDiagnostics.evaluate_numerical(
            compact_model, [0.01, 0.01, 0.2]; label = "nearby",
        )
        persistent_hessian = NLPDiagnostics.HessianEvaluation(
            persistent_evaluation.point,
            1.0,
            zeros(3),
            NLPDiagnostics.HessianEntry{Float64}[
                NLPDiagnostics.HessianEntry(1, 1, 1.0),
                NLPDiagnostics.HessianEntry(1, 2, -1.0),
                NLPDiagnostics.HessianEntry(2, 2, 1.0),
                NLPDiagnostics.HessianEntry(3, 3, 2.0),
            ],
            [:test_exact],
            true,
            NLPDiagnostics.EvaluationFailure[],
        )
        persistent_analysis = NLPDiagnostics.reduced_hessian_analysis(
            persistent_evaluation,
            persistent_hessian;
            active_rows = Int[],
        )
        compact_analysis = NLPDiagnostics.reduced_hessian_analysis(
            compact_evaluation,
            compact_hessian;
            active_rows = Int[],
        )
        persistence_report = NLPDiagnostics.analyze_reduced_hessian_persistence([
            NLPDiagnostics.ReducedHessianSnapshot(compact_evaluation, compact_analysis),
            NLPDiagnostics.ReducedHessianSnapshot(persistent_evaluation, persistent_analysis),
        ])
        @test length(findings(
            persistence_report,
            :reduced_hessian_flat_subspace_persistent,
        )) == 1
        expected_subspace_report = NLPDiagnostics.analyze_reduced_hessian_persistence(
            [
                NLPDiagnostics.ReducedHessianSnapshot(compact_evaluation, compact_analysis),
                NLPDiagnostics.ReducedHessianSnapshot(persistent_evaluation, persistent_analysis),
            ];
            expected_modes = [
                NLPDiagnostics.ExpectedNullspaceMode(
                    :common_shift,
                    [c1, c2],
                    [1.0, 1.0],
                ),
            ],
        )
        @test length(findings(
            expected_subspace_report,
            :reduced_hessian_persistent_expected_mode_subspace_observed,
        )) == 1
        unexpected_subspace_report = NLPDiagnostics.analyze_reduced_hessian_persistence(
            [
                NLPDiagnostics.ReducedHessianSnapshot(compact_evaluation, compact_analysis),
                NLPDiagnostics.ReducedHessianSnapshot(persistent_evaluation, persistent_analysis),
            ];
            expected_modes = [
                NLPDiagnostics.ExpectedNullspaceMode(
                    :differential_shift,
                    [c1, c2],
                    [1.0, -1.0],
                ),
            ],
        )
        @test length(findings(
            unexpected_subspace_report,
            :reduced_hessian_persistent_expected_mode_subspace_not_observed,
        )) == 1
        @test length(findings(
            persistence_report,
            :reduced_hessian_flat_support_persistent,
        )) == 1
        @test length(findings(
            persistence_report,
            :reduced_hessian_active_rows_persistent,
        )) == 1
        @test length(findings(
            persistence_report,
            :reduced_hessian_active_jacobian_rank_persistent,
        )) == 1
        spanning_report = NLPDiagnostics.analyze_reduced_hessian_persistence(
            compact_model,
            [
                NLPDiagnostics.ReducedHessianSnapshot(compact_evaluation, compact_analysis),
                NLPDiagnostics.ReducedHessianSnapshot(persistent_evaluation, persistent_analysis),
            ],
        )
        @test length(findings(
            spanning_report,
            :reduced_hessian_persistent_flat_spans_components,
        )) == 1
        linking_constraint = MOI.ScalarAffineFunction(
            [MOI.ScalarAffineTerm(1.0, c1), MOI.ScalarAffineTerm(-1.0, c2)],
            0.0,
        )
        MOI.add_constraint(compact_model, linking_constraint, MOI.EqualTo(0.0))
        localized_report = NLPDiagnostics.analyze_reduced_hessian_persistence(
            compact_model,
            [
                NLPDiagnostics.ReducedHessianSnapshot(compact_evaluation, compact_analysis),
                NLPDiagnostics.ReducedHessianSnapshot(persistent_evaluation, persistent_analysis),
            ],
        )
        @test length(findings(
            localized_report,
            :reduced_hessian_persistent_flat_structurally_localized,
        )) == 1
        component_overlap_report = NLPDiagnostics.analyze_reduced_hessian_persistence(
            compact_model,
            [
                NLPDiagnostics.ReducedHessianSnapshot(compact_evaluation, compact_analysis),
                NLPDiagnostics.ReducedHessianSnapshot(persistent_evaluation, persistent_analysis),
            ];
            components = [
                NLPDiagnostics.ComponentMetadata(
                    :test_device,
                    "local";
                    variables = [c1, c2],
                    units = Dict(:voltage => "pu"),
                ),
                NLPDiagnostics.ComponentMetadata(
                    :test_device,
                    "outside";
                    variables = [c3],
                ),
            ],
        )
        overlaps = findings(
            component_overlap_report,
            :reduced_hessian_persistent_flat_declared_component_overlap,
        )
        @test length(overlaps) == 1
        @test length(only(overlaps).affected) == 2

        changing_hessian = NLPDiagnostics.HessianEvaluation(
            persistent_evaluation.point,
            1.0,
            zeros(3),
            NLPDiagnostics.HessianEntry{Float64}[
                NLPDiagnostics.HessianEntry(1, 1, 1.0),
                NLPDiagnostics.HessianEntry(1, 2, 1.0),
                NLPDiagnostics.HessianEntry(2, 2, 1.0),
                NLPDiagnostics.HessianEntry(3, 3, 2.0),
            ],
            [:test_exact],
            true,
            NLPDiagnostics.EvaluationFailure[],
        )
        changing_analysis = NLPDiagnostics.reduced_hessian_analysis(
            persistent_evaluation,
            changing_hessian;
            active_rows = Int[],
        )
        changing_report = NLPDiagnostics.analyze_reduced_hessian_persistence([
            NLPDiagnostics.ReducedHessianSnapshot(compact_evaluation, compact_analysis),
            NLPDiagnostics.ReducedHessianSnapshot(persistent_evaluation, changing_analysis),
        ])
        @test length(findings(
            changing_report,
            :reduced_hessian_flat_subspace_not_persistent,
        )) == 1
        @test length(findings(
            changing_report,
            :reduced_hessian_flat_support_persistent,
        )) == 1

        support_changing_hessian = NLPDiagnostics.HessianEvaluation(
            persistent_evaluation.point,
            1.0,
            zeros(3),
            NLPDiagnostics.HessianEntry{Float64}[
                NLPDiagnostics.HessianEntry(1, 1, 2.0),
                NLPDiagnostics.HessianEntry(2, 2, 1.0),
                NLPDiagnostics.HessianEntry(2, 3, -1.0),
                NLPDiagnostics.HessianEntry(3, 3, 1.0),
            ],
            [:test_exact],
            true,
            NLPDiagnostics.EvaluationFailure[],
        )
        support_changing_analysis = NLPDiagnostics.reduced_hessian_analysis(
            persistent_evaluation,
            support_changing_hessian;
            active_rows = Int[],
        )
        support_changing_report = NLPDiagnostics.analyze_reduced_hessian_persistence([
            NLPDiagnostics.ReducedHessianSnapshot(compact_evaluation, compact_analysis),
            NLPDiagnostics.ReducedHessianSnapshot(
                persistent_evaluation, support_changing_analysis,
            ),
        ])
        @test length(findings(
            support_changing_report,
            :reduced_hessian_flat_support_changing,
        )) == 1

        active_model = new_model()
        a1, a2 = MOI.add_variables(active_model, 2)
        active_constraint = MOI.ScalarAffineFunction(
            [MOI.ScalarAffineTerm(1.0, a1), MOI.ScalarAffineTerm(-1.0, a2)],
            0.0,
        )
        MOI.add_constraint(active_model, active_constraint, MOI.EqualTo(0.0))
        active_evaluation_1 = NLPDiagnostics.evaluate_numerical(
            active_model, [0.0, 0.0]; label = "active",
        )
        active_evaluation_2 = NLPDiagnostics.evaluate_numerical(
            active_model, [0.01, 0.01]; label = "inactive",
        )
        active_hessian_1 = NLPDiagnostics.HessianEvaluation(
            active_evaluation_1.point,
            1.0,
            zeros(2),
            NLPDiagnostics.HessianEntry{Float64}[],
            [:test_exact],
            true,
            NLPDiagnostics.EvaluationFailure[],
        )
        active_hessian_2 = NLPDiagnostics.HessianEvaluation(
            active_evaluation_2.point,
            1.0,
            zeros(2),
            NLPDiagnostics.HessianEntry{Float64}[],
            [:test_exact],
            true,
            NLPDiagnostics.EvaluationFailure[],
        )
        active_analysis_1 = NLPDiagnostics.reduced_hessian_analysis(
            active_evaluation_1, active_hessian_1; active_rows = [1],
        )
        active_analysis_2 = NLPDiagnostics.reduced_hessian_analysis(
            active_evaluation_2, active_hessian_2; active_rows = Int[],
        )
        active_changing_report = NLPDiagnostics.analyze_reduced_hessian_persistence([
            NLPDiagnostics.ReducedHessianSnapshot(
                active_evaluation_1, active_analysis_1,
            ),
            NLPDiagnostics.ReducedHessianSnapshot(
                active_evaluation_2, active_analysis_2,
            ),
        ])
        @test length(findings(
            active_changing_report,
            :reduced_hessian_active_rows_changing,
        )) == 1
        @test length(findings(
            active_changing_report,
            :reduced_hessian_active_jacobian_rank_changing,
        )) == 1

        multiplier_hessian_1 = NLPDiagnostics.HessianEvaluation(
            active_evaluation_1.point,
            1.0,
            [1.0],
            NLPDiagnostics.HessianEntry{Float64}[],
            [:test_exact],
            true,
            NLPDiagnostics.EvaluationFailure[],
        )
        multiplier_hessian_2 = NLPDiagnostics.HessianEvaluation(
            active_evaluation_2.point,
            1.0,
            [1.0],
            NLPDiagnostics.HessianEntry{Float64}[],
            [:test_exact],
            true,
            NLPDiagnostics.EvaluationFailure[],
        )
        multiplier_analysis_1 = NLPDiagnostics.reduced_hessian_analysis(
            active_evaluation_1, multiplier_hessian_1; active_rows = [1],
        )
        multiplier_analysis_2 = NLPDiagnostics.reduced_hessian_analysis(
            active_evaluation_2, multiplier_hessian_2; active_rows = [1],
        )
        multiplier_persistent_report =
            NLPDiagnostics.analyze_reduced_hessian_persistence([
                NLPDiagnostics.ReducedHessianSnapshot(
                    active_evaluation_1,
                    multiplier_analysis_1,
                    multiplier_hessian_1,
                ),
                NLPDiagnostics.ReducedHessianSnapshot(
                    active_evaluation_2,
                    multiplier_analysis_2,
                    multiplier_hessian_2,
                ),
            ])
        @test length(findings(
            multiplier_persistent_report,
            :reduced_hessian_multiplier_representative_persistent,
        )) == 1
        multiplier_changing_hessian = NLPDiagnostics.HessianEvaluation(
            active_evaluation_2.point,
            1.0,
            [2.0],
            NLPDiagnostics.HessianEntry{Float64}[],
            [:test_exact],
            true,
            NLPDiagnostics.EvaluationFailure[],
        )
        multiplier_changing_report =
            NLPDiagnostics.analyze_reduced_hessian_persistence([
                NLPDiagnostics.ReducedHessianSnapshot(
                    active_evaluation_1,
                    multiplier_analysis_1,
                    multiplier_hessian_1,
                ),
                NLPDiagnostics.ReducedHessianSnapshot(
                    active_evaluation_2,
                    multiplier_analysis_2,
                    multiplier_changing_hessian,
                ),
            ])
        @test length(findings(
            multiplier_changing_report,
            :reduced_hessian_multiplier_representative_changing,
        )) == 1

        scaling_model = new_model()
        scale_x, scale_y = MOI.add_variables(scaling_model, 2)
        scaling_quadratic = MOI.ScalarQuadraticFunction(
            [MOI.ScalarQuadraticTerm(1.0, scale_x, scale_x)],
            MOI.ScalarAffineTerm{Float64}[],
            0.0,
        )
        scaling_affine = MOI.ScalarAffineFunction(
            [MOI.ScalarAffineTerm(1.0, scale_y)],
            0.0,
        )
        MOI.add_constraint(scaling_model, scaling_quadratic, MOI.EqualTo(0.0))
        MOI.add_constraint(scaling_model, scaling_affine, MOI.EqualTo(0.0))
        scaling_evaluation_1 = NLPDiagnostics.evaluate_numerical(
            scaling_model, [1.0, 0.0]; label = "small_scale",
        )
        scaling_evaluation_2 = NLPDiagnostics.evaluate_numerical(
            scaling_model, [100.0, 0.0]; label = "large_scale",
        )
        scaling_hessian_1 = NLPDiagnostics.HessianEvaluation(
            scaling_evaluation_1.point,
            1.0,
            [0.0, 0.0],
            NLPDiagnostics.HessianEntry{Float64}[],
            [:test_exact],
            true,
            NLPDiagnostics.EvaluationFailure[],
        )
        scaling_hessian_2 = NLPDiagnostics.HessianEvaluation(
            scaling_evaluation_2.point,
            1.0,
            [0.0, 0.0],
            NLPDiagnostics.HessianEntry{Float64}[],
            [:test_exact],
            true,
            NLPDiagnostics.EvaluationFailure[],
        )
        scaling_analysis_1 = NLPDiagnostics.reduced_hessian_analysis(
            scaling_evaluation_1, scaling_hessian_1; active_rows = Int[],
        )
        scaling_analysis_2 = NLPDiagnostics.reduced_hessian_analysis(
            scaling_evaluation_2, scaling_hessian_2; active_rows = Int[],
        )
        scaling_changing_report =
            NLPDiagnostics.analyze_reduced_hessian_persistence([
                NLPDiagnostics.ReducedHessianSnapshot(
                    scaling_evaluation_1, scaling_analysis_1,
                ),
                NLPDiagnostics.ReducedHessianSnapshot(
                    scaling_evaluation_2, scaling_analysis_2,
                ),
            ])
        @test length(findings(
            scaling_changing_report,
            :reduced_hessian_jacobian_scaling_changing,
        )) == 1

        spectral_hessian = NLPDiagnostics.HessianEvaluation(
            persistent_evaluation.point,
            1.0,
            zeros(3),
            NLPDiagnostics.HessianEntry{Float64}[
                NLPDiagnostics.HessianEntry(1, 1, 100.0),
                NLPDiagnostics.HessianEntry(1, 2, -100.0),
                NLPDiagnostics.HessianEntry(2, 2, 100.0),
                NLPDiagnostics.HessianEntry(3, 3, 200.0),
            ],
            [:test_exact],
            true,
            NLPDiagnostics.EvaluationFailure[],
        )
        spectral_analysis = NLPDiagnostics.reduced_hessian_analysis(
            persistent_evaluation, spectral_hessian; active_rows = Int[],
        )
        spectral_changing_report = NLPDiagnostics.analyze_reduced_hessian_persistence([
            NLPDiagnostics.ReducedHessianSnapshot(compact_evaluation, compact_analysis),
            NLPDiagnostics.ReducedHessianSnapshot(
                persistent_evaluation, spectral_analysis,
            ),
        ])
        @test length(findings(
            spectral_changing_report,
            :reduced_hessian_spectral_scale_changing,
        )) == 1
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

        near_unit = new_model()
        u, v = MOI.add_variables(near_unit, 2)
        near_unit_circle = Q(
            [QT(2.0, u, u), QT(2.0, v, v)],
            MOI.ScalarAffineTerm{Float64}[],
            0.0,
        )
        MOI.add_constraint(near_unit, near_unit_circle, MOI.EqualTo(1.0001))
        @test isempty(findings(
            NLPDiagnostics.analyze_static(
                near_unit;
                unit_circle_radius_tolerance = 1.0e-3,
            ),
            :nonunit_circular_constraint_radius,
        ))
        @test length(findings(
            NLPDiagnostics.analyze_static(
                near_unit;
                unit_circle_radius_tolerance = 1.0e-6,
            ),
            :nonunit_circular_constraint_radius,
        )) == 1

        nonlinear = new_model()
        u, v = MOI.add_variables(nonlinear, 2)
        sum_of_squares = MOI.ScalarNonlinearFunction(
            :+,
            Any[
                MOI.ScalarNonlinearFunction(:^, Any[u, 2]),
                MOI.ScalarNonlinearFunction(:*, Any[v, v]),
            ],
        )
        MOI.add_constraint(nonlinear, sum_of_squares, MOI.EqualTo(4.0))
        nonlinear_finding = only(findings(
            NLPDiagnostics.analyze_static(nonlinear),
            :nonunit_circular_constraint_radius,
        ))
        @test evidence_details(nonlinear_finding)["representation"] ==
              "ScalarNonlinearFunction"

        weighted_nonlinear = new_model()
        p, q = MOI.add_variables(weighted_nonlinear, 2)
        weighted_sum_of_squares = MOI.ScalarNonlinearFunction(
            :+,
            Any[
                MOI.ScalarNonlinearFunction(
                    :*,
                    Any[2.0, MOI.ScalarNonlinearFunction(:^, Any[p, 2])],
                ),
                MOI.ScalarNonlinearFunction(
                    :*,
                    Any[MOI.ScalarNonlinearFunction(:*, Any[q, q]), 2.0],
                ),
            ],
        )
        MOI.add_constraint(weighted_nonlinear, weighted_sum_of_squares, MOI.EqualTo(4.0))
        weighted_finding = only(findings(
            NLPDiagnostics.analyze_static(weighted_nonlinear),
            :nonunit_circular_constraint_radius,
        ))
        @test evidence_details(weighted_finding)["radius_squared"] == "2.0"

        nary_weighted_nonlinear = new_model()
        r, s = MOI.add_variables(nary_weighted_nonlinear, 2)
        nary_weighted_sum = MOI.ScalarNonlinearFunction(
            :+,
            Any[
                MOI.ScalarNonlinearFunction(:*, Any[2.0, r, r]),
                MOI.ScalarNonlinearFunction(:*, Any[s, 2.0, s]),
            ],
        )
        MOI.add_constraint(nary_weighted_nonlinear, nary_weighted_sum, MOI.EqualTo(4.0))
        nary_finding = only(findings(
            NLPDiagnostics.analyze_static(nary_weighted_nonlinear),
            :nonunit_circular_constraint_radius,
        ))
        @test evidence_details(nary_finding)["radius_squared"] == "2.0"

        coupled = new_model()
        m, n = MOI.add_variables(coupled, 2)
        coupled_quadratic = MOI.ScalarNonlinearFunction(
            :+,
            Any[
                MOI.ScalarNonlinearFunction(:^, Any[m, 2]),
                MOI.ScalarNonlinearFunction(:^, Any[n, 2]),
                MOI.ScalarNonlinearFunction(:*, Any[m, n]),
            ],
        )
        MOI.add_constraint(coupled, coupled_quadratic, MOI.EqualTo(4.0))
        coupled_report = NLPDiagnostics.analyze_static(coupled)
        @test isempty(findings(coupled_report, :nonunit_circular_constraint_radius))
        @test isempty(findings(coupled_report, :nonunit_ellipsoidal_constraint_axes))

        nonfinite = new_model()
        α, β = MOI.add_variables(nonfinite, 2)
        nonfinite_circle = Q(
            [QT(Inf, α, α), QT(2.0, β, β)],
            MOI.ScalarAffineTerm{Float64}[],
            0.0,
        )
        MOI.add_constraint(nonfinite, nonfinite_circle, MOI.EqualTo(4.0))
        nonfinite_report = NLPDiagnostics.analyze_static(nonfinite)
        @test isempty(findings(nonfinite_report, :nonunit_circular_constraint_radius))
        @test isempty(findings(nonfinite_report, :nonunit_ellipsoidal_constraint_axes))

        shifted_level_nonlinear = new_model()
        a, b = MOI.add_variables(shifted_level_nonlinear, 2)
        level_in_expression = MOI.ScalarNonlinearFunction(
            :-,
            Any[
                MOI.ScalarNonlinearFunction(
                    :+,
                    Any[
                        MOI.ScalarNonlinearFunction(:^, Any[a, 2]),
                        MOI.ScalarNonlinearFunction(:^, Any[b, 2]),
                    ],
                ),
                4.0,
            ],
        )
        MOI.add_constraint(shifted_level_nonlinear, level_in_expression, MOI.EqualTo(0.0))
        level_finding = only(findings(
            NLPDiagnostics.analyze_static(shifted_level_nonlinear),
            :nonunit_circular_constraint_radius,
        ))
        @test evidence_details(level_finding)["radius_squared"] == "4.0"

        bounded_circle = new_model()
        r, s = MOI.add_variables(bounded_circle, 2)
        bounded_circle_function = Q(
            [QT(2.0, r, r), QT(2.0, s, s)],
            MOI.ScalarAffineTerm{Float64}[],
            0.0,
        )
        MOI.add_constraint(bounded_circle, bounded_circle_function, MOI.EqualTo(4.0))
        MOI.add_constraint(bounded_circle, r, MOI.GreaterThan(3.0))
        circle_contradiction = only(findings(
            NLPDiagnostics.analyze_static(bounded_circle),
            :inconsistent_circular_implied_variable_bound,
        ))
        @test circle_contradiction.basis == NLPDiagnostics.MathematicalProof
        @test evidence_details(circle_contradiction)["derived_upper"] == "2.0"

        shifted_center_nonlinear = new_model()
        c, d = MOI.add_variables(shifted_center_nonlinear, 2)
        shifted_circle_expression = MOI.ScalarNonlinearFunction(
            :+,
            Any[
                MOI.ScalarNonlinearFunction(:^, Any[c, 2]),
                MOI.ScalarNonlinearFunction(:^, Any[d, 2]),
                MOI.ScalarNonlinearFunction(:*, Any[-4.0, c]),
                MOI.ScalarNonlinearFunction(:*, Any[6.0, d]),
            ],
        )
        # (c - 2)^2 + (d + 3)^2 = 4.
        MOI.add_constraint(shifted_center_nonlinear, shifted_circle_expression, MOI.EqualTo(-9.0))
        shifted_finding = only(findings(
            NLPDiagnostics.analyze_static(shifted_center_nonlinear),
            :nonunit_circular_constraint_radius,
        ))
        @test evidence_details(shifted_finding)["center"] == "[2.0, -3.0]"
        @test evidence_details(shifted_finding)["radius_squared"] == "4.0"
    end

    @testset "nonpositive circular equality levels have proven consequences" begin
        Q = MOI.ScalarQuadraticFunction{Float64}
        QT = MOI.ScalarQuadraticTerm{Float64}

        infeasible = new_model()
        x, y = MOI.add_variables(infeasible, 2)
        circle = Q(
            [QT(2.0, x, x), QT(2.0, y, y)],
            MOI.ScalarAffineTerm{Float64}[],
            0.0,
        )
        MOI.add_constraint(infeasible, circle, MOI.EqualTo(-1.0))
        negative = only(findings(
            NLPDiagnostics.analyze_static(infeasible),
            :infeasible_negative_radius_squared_circular_constraint,
        ))
        @test negative.severity == NLPDiagnostics.SeverityError
        @test negative.basis == NLPDiagnostics.MathematicalProof

        zero_radius = new_model()
        p, q = MOI.add_variables(zero_radius, 2)
        zero_circle = Q(
            [QT(2.0, p, p), QT(2.0, q, q)],
            MOI.ScalarAffineTerm{Float64}[],
            0.0,
        )
        MOI.add_constraint(zero_radius, zero_circle, MOI.EqualTo(0.0))
        zero = only(findings(
            NLPDiagnostics.analyze_static(zero_radius),
            :zero_radius_circular_constraint,
        ))
        @test zero.basis == NLPDiagnostics.MathematicalProof
        @test evidence_details(zero)["center"] == "[0.0, 0.0]"
        nonregular = only(findings(
            NLPDiagnostics.analyze_static(zero_radius),
            :nonregular_zero_radius_quadratic_fixing,
        ))
        @test nonregular.domain == NLPDiagnostics.NumericalIssue
        @test nonregular.basis == NLPDiagnostics.MathematicalProof

        zero_conflict = new_model()
        u, v = MOI.add_variables(zero_conflict, 2)
        conflicting_circle = Q(
            [QT(2.0, u, u), QT(2.0, v, v)],
            MOI.ScalarAffineTerm{Float64}[],
            0.0,
        )
        MOI.add_constraint(zero_conflict, conflicting_circle, MOI.EqualTo(0.0))
        MOI.add_constraint(zero_conflict, u, MOI.GreaterThan(1.0))
        contradiction = only(findings(
            NLPDiagnostics.analyze_static(zero_conflict),
            :inconsistent_zero_radius_circular_variable_bound,
        ))
        @test contradiction.basis == NLPDiagnostics.MathematicalProof
        @test evidence_details(contradiction)["implied_value"] == "0.0"
    end

    @testset "shifted isotropic quadratic equalities are completed statically" begin
        model = new_model()
        x, y = MOI.add_variables(model, 2)
        Q = MOI.ScalarQuadraticFunction{Float64}
        QT = MOI.ScalarQuadraticTerm{Float64}
        AT = MOI.ScalarAffineTerm{Float64}
        shifted_circle = Q(
            [QT(2.0, x, x), QT(2.0, y, y)],
            [AT(-4.0, x), AT(6.0, y)],
            0.0,
        )
        # (x - 2)^2 + (y + 3)^2 = 4.
        MOI.add_constraint(model, shifted_circle, MOI.EqualTo(-9.0))
        scaling = only(findings(
            NLPDiagnostics.analyze_static(model),
            :nonunit_circular_constraint_radius,
        ))
        @test evidence_details(scaling)["is_shifted"] == "true"
        @test evidence_details(scaling)["center"] == "[2.0, -3.0]"
        @test evidence_details(scaling)["radius_squared"] == "4.0"

        impossible = new_model()
        u, v = MOI.add_variables(impossible, 2)
        impossible_circle = Q(
            [QT(2.0, u, u), QT(2.0, v, v)],
            [AT(-4.0, u), AT(6.0, v)],
            0.0,
        )
        MOI.add_constraint(impossible, impossible_circle, MOI.EqualTo(-14.0))
        @test length(findings(
            NLPDiagnostics.analyze_static(impossible),
            :infeasible_negative_radius_squared_circular_constraint,
        )) == 1
    end

    @testset "diagonal ellipsoidal equalities expose axis scaling" begin
        model = new_model()
        x, y = MOI.add_variables(model, 2)
        Q = MOI.ScalarQuadraticFunction{Float64}
        QT = MOI.ScalarQuadraticTerm{Float64}
        AT = MOI.ScalarAffineTerm{Float64}
        ellipsoid = Q(
            [QT(2.0, x, x), QT(8.0, y, y)],
            [AT(-4.0, x), AT(8.0, y)],
            0.0,
        )
        # (x - 2)^2 + 4 * (y + 1)^2 = 4.
        MOI.add_constraint(model, ellipsoid, MOI.EqualTo(-4.0))
        scaling = only(findings(
            NLPDiagnostics.analyze_static(model),
            :nonunit_ellipsoidal_constraint_axes,
        ))
        @test evidence_details(scaling)["center"] == "[2.0, -1.0]"
        @test evidence_details(scaling)["semiaxes"] == "[2.0, 1.0]"

        impossible = new_model()
        u, v = MOI.add_variables(impossible, 2)
        impossible_ellipsoid = Q(
            [QT(2.0, u, u), QT(8.0, v, v)],
            [AT(-4.0, u), AT(8.0, v)],
            0.0,
        )
        MOI.add_constraint(impossible, impossible_ellipsoid, MOI.EqualTo(-9.0))
        @test length(findings(
            NLPDiagnostics.analyze_static(impossible),
            :infeasible_negative_level_diagonal_quadratic_constraint,
        )) == 1

        zero_level = new_model()
        p, q = MOI.add_variables(zero_level, 2)
        zero_ellipsoid = Q(
            [QT(2.0, p, p), QT(8.0, q, q)],
            [AT(-4.0, p), AT(8.0, q)],
            0.0,
        )
        MOI.add_constraint(zero_level, zero_ellipsoid, MOI.EqualTo(-8.0))
        fixed = only(findings(
            NLPDiagnostics.analyze_static(zero_level),
            :zero_level_diagonal_quadratic_constraint,
        ))
        @test fixed.basis == NLPDiagnostics.MathematicalProof
        @test evidence_details(fixed)["center"] == "[2.0, -1.0]"
        @test length(findings(
            NLPDiagnostics.analyze_static(zero_level),
            :nonregular_zero_level_diagonal_quadratic_fixing,
        )) == 1

        minimum_conflict = new_model()
        c, d = MOI.add_variables(minimum_conflict, 2)
        conflicting_minimum_bowl = Q(
            [QT(2.0, c, c), QT(8.0, d, d)],
            [AT(-4.0, c), AT(8.0, d)],
            3.0,
        )
        MOI.add_constraint(minimum_conflict, conflicting_minimum_bowl, MOI.LessThan(-5.0))
        MOI.add_constraint(minimum_conflict, c, MOI.GreaterThan(3.0))
        minimum_contradiction = only(findings(
            NLPDiagnostics.analyze_static(minimum_conflict),
            :inconsistent_diagonal_quadratic_minimum_variable_bound,
        ))
        @test minimum_contradiction.basis == NLPDiagnostics.MathematicalProof
        @test evidence_details(minimum_contradiction)["implied_value"] == "2.0"

        nonlinear = new_model()
        a, b = MOI.add_variables(nonlinear, 2)
        nonlinear_ellipsoid = MOI.ScalarNonlinearFunction(
            :+,
            Any[
                MOI.ScalarNonlinearFunction(:^, Any[a, 2]),
                MOI.ScalarNonlinearFunction(
                    :*,
                    Any[4.0, MOI.ScalarNonlinearFunction(:^, Any[b, 2])],
                ),
                MOI.ScalarNonlinearFunction(:*, Any[-4.0, a]),
                MOI.ScalarNonlinearFunction(:*, Any[8.0, b]),
            ],
        )
        # (a - 2)^2 + 4 * (b + 1)^2 = 4.
        MOI.add_constraint(nonlinear, nonlinear_ellipsoid, MOI.EqualTo(-4.0))
        nonlinear_scaling = only(findings(
            NLPDiagnostics.analyze_static(nonlinear),
            :nonunit_ellipsoidal_constraint_axes,
        ))
        @test evidence_details(nonlinear_scaling)["semiaxes"] == "[2.0, 1.0]"
        @test evidence_details(nonlinear_scaling)["representation"] ==
              "ScalarNonlinearFunction"

        bounded_ellipsoid = new_model()
        g, h = MOI.add_variables(bounded_ellipsoid, 2)
        bounded_ellipsoid_function = Q(
            [QT(2.0, g, g), QT(8.0, h, h)],
            [AT(-4.0, g), AT(8.0, h)],
            0.0,
        )
        MOI.add_constraint(bounded_ellipsoid, bounded_ellipsoid_function, MOI.EqualTo(-4.0))
        MOI.add_constraint(bounded_ellipsoid, g, MOI.GreaterThan(5.0))
        ellipsoid_contradiction = only(findings(
            NLPDiagnostics.analyze_static(bounded_ellipsoid),
            :inconsistent_ellipsoidal_implied_variable_bound,
        ))
        @test ellipsoid_contradiction.basis == NLPDiagnostics.MathematicalProof
        @test evidence_details(ellipsoid_contradiction)["derived_upper"] == "4.0"

        domain_model = new_model()
        domain_x, domain_y = MOI.add_variables(domain_model, 2)
        domain_ellipsoid = Q(
            [QT(2.0, domain_x, domain_x), QT(8.0, domain_y, domain_y)],
            [AT(-4.0, domain_x), AT(8.0, domain_y)],
            0.0,
        )
        # (x - 2)^2 + 4 * (y + 1)^2 = 1, so x ∈ [1, 3].
        MOI.add_constraint(domain_model, domain_ellipsoid, MOI.EqualTo(-7.0))
        propagated_domains = NLPDiagnostics._domain_variable_intervals(
            NLPDiagnostics.snapshot(domain_model),
        )
        @test propagated_domains[domain_x].lower == 1.0
        @test propagated_domains[domain_x].upper == 3.0

        # Geometry-derived coordinate intervals feed the generic expression
        # domain pass, but remain analysis-only: the model has no scalar bound
        # constraint on `domain_x` other than its ellipsoidal equality.
        MOI.add_constraint(
            domain_model,
            MOI.ScalarNonlinearFunction(:log, Any[domain_x]),
            MOI.LessThan(10.0),
        )
        @test isempty(NLPDiagnostics.domain_issues(domain_model))

        nonlinear_domain_model = new_model()
        nonlinear_x, nonlinear_y = MOI.add_variables(nonlinear_domain_model, 2)
        # (x - 2)^2 + 4 * (y + 1)^2 = 1, represented as a nonlinear tree.
        nonlinear_domain_ellipsoid = MOI.ScalarNonlinearFunction(
            :+,
            Any[
                MOI.ScalarNonlinearFunction(:^, Any[nonlinear_x, 2]),
                MOI.ScalarNonlinearFunction(
                    :*,
                    Any[4.0, MOI.ScalarNonlinearFunction(:^, Any[nonlinear_y, 2])],
                ),
                MOI.ScalarNonlinearFunction(:*, Any[-4.0, nonlinear_x]),
                MOI.ScalarNonlinearFunction(:*, Any[8.0, nonlinear_y]),
            ],
        )
        MOI.add_constraint(
            nonlinear_domain_model,
            nonlinear_domain_ellipsoid,
            MOI.EqualTo(-7.0),
        )
        MOI.add_constraint(
            nonlinear_domain_model,
            MOI.ScalarNonlinearFunction(:log, Any[nonlinear_x]),
            MOI.LessThan(10.0),
        )
        @test isempty(NLPDiagnostics.domain_issues(nonlinear_domain_model))

        affine_domain_model = new_model()
        affine_a, affine_b, affine_c = MOI.add_variables(affine_domain_model, 3)
        MOI.add_constraint(affine_domain_model, affine_a, MOI.Interval(0.0, 1.0))
        # The second equality becomes informative only after the first has
        # propagated b's interval; c is then strictly positive.
        MOI.add_constraint(
            affine_domain_model,
            MOI.ScalarAffineFunction(
                [MOI.ScalarAffineTerm(1.0, affine_a),
                 MOI.ScalarAffineTerm(1.0, affine_b)],
                0.0,
            ),
            MOI.EqualTo(3.0),
        )
        MOI.add_constraint(
            affine_domain_model,
            MOI.ScalarAffineFunction(
                [MOI.ScalarAffineTerm(1.0, affine_b),
                 MOI.ScalarAffineTerm(1.0, affine_c)],
                0.0,
            ),
            MOI.EqualTo(4.0),
        )
        MOI.add_constraint(
            affine_domain_model,
            MOI.ScalarNonlinearFunction(:log, Any[affine_c]),
            MOI.LessThan(10.0),
        )
        affine_domains = NLPDiagnostics._domain_variable_intervals(
            NLPDiagnostics.snapshot(affine_domain_model),
        )
        @test affine_domains[affine_b].lower == 2.0
        @test affine_domains[affine_b].upper == 3.0
        @test affine_domains[affine_c].lower == 1.0
        @test affine_domains[affine_c].upper == 2.0
        @test isempty(NLPDiagnostics.domain_issues(affine_domain_model))

        monotone_domain_model = new_model()
        monotone_x, monotone_y, monotone_z = MOI.add_variables(
            monotone_domain_model,
            3,
        )
        MOI.add_constraint(
            monotone_domain_model,
            MOI.ScalarNonlinearFunction(:log, Any[monotone_x]),
            MOI.GreaterThan(0.0),
        )
        MOI.add_constraint(
            monotone_domain_model,
            MOI.ScalarNonlinearFunction(:exp, Any[monotone_y]),
            MOI.LessThan(exp(2.0)),
        )
        MOI.add_constraint(
            monotone_domain_model,
            MOI.ScalarNonlinearFunction(:sqrt, Any[monotone_z]),
            MOI.GreaterThan(2.0),
        )
        # These downstream expressions need the input ranges inferred from
        # the monotone rows above; no direct scalar bounds are declared.
        MOI.add_constraint(
            monotone_domain_model,
            MOI.ScalarNonlinearFunction(
                :sqrt,
                Any[MOI.ScalarAffineFunction(
                    [MOI.ScalarAffineTerm(1.0, monotone_x)],
                    -0.5,
                )],
            ),
            MOI.LessThan(10.0),
        )
        MOI.add_constraint(
            monotone_domain_model,
            MOI.ScalarNonlinearFunction(
                :log,
                Any[MOI.ScalarAffineFunction(
                    [MOI.ScalarAffineTerm(-1.0, monotone_y)],
                    3.0,
                )],
            ),
            MOI.LessThan(10.0),
        )
        MOI.add_constraint(
            monotone_domain_model,
            MOI.ScalarNonlinearFunction(:log, Any[monotone_z]),
            MOI.LessThan(10.0),
        )
        monotone_domains = NLPDiagnostics._domain_variable_intervals(
            NLPDiagnostics.snapshot(monotone_domain_model),
        )
        @test monotone_domains[monotone_x].lower == 1.0
        @test monotone_domains[monotone_y].upper ≈ 2.0 atol = 1.0e-12
        @test monotone_domains[monotone_z].lower == 4.0
        @test isempty(NLPDiagnostics.domain_issues(monotone_domain_model))

        log1mexp_domain_model = new_model()
        log1mexp_x = MOI.add_variable(log1mexp_domain_model)
        MOI.add_constraint(
            log1mexp_domain_model,
            MOI.ScalarNonlinearFunction(:log1mexp, Any[log1mexp_x]),
            MOI.GreaterThan(-1.0),
        )
        # log1mexp(x) ≥ -1 implies x ≤ log(1 - exp(-1)), so -x is
        # strictly positive for the downstream square root.
        MOI.add_constraint(
            log1mexp_domain_model,
            MOI.ScalarNonlinearFunction(
                :sqrt,
                Any[MOI.ScalarNonlinearFunction(:-, Any[log1mexp_x])],
            ),
            MOI.LessThan(10.0),
        )
        log1mexp_domains = NLPDiagnostics._domain_variable_intervals(
            NLPDiagnostics.snapshot(log1mexp_domain_model),
        )
        @test log1mexp_domains[log1mexp_x].upper ≈
              log1p(-exp(-1.0)) atol = 1.0e-12
        @test isempty(NLPDiagnostics.domain_issues(log1mexp_domain_model))

        softplus_domain_model = new_model()
        softplus_x = MOI.add_variable(softplus_domain_model)
        MOI.add_constraint(
            softplus_domain_model,
            MOI.ScalarNonlinearFunction(:softplus, Any[softplus_x]),
            MOI.GreaterThan(2.0),
        )
        MOI.add_constraint(
            softplus_domain_model,
            MOI.ScalarNonlinearFunction(:log, Any[softplus_x]),
            MOI.LessThan(10.0),
        )
        softplus_domains = NLPDiagnostics._domain_variable_intervals(
            NLPDiagnostics.snapshot(softplus_domain_model),
        )
        @test softplus_domains[softplus_x].lower ≈
              2.0 + log1p(-exp(-2.0)) atol = 1.0e-12
        @test isempty(NLPDiagnostics.domain_issues(softplus_domain_model))

        logistic_domain_model = new_model()
        logistic_x = MOI.add_variable(logistic_domain_model)
        MOI.add_constraint(
            logistic_domain_model,
            MOI.ScalarNonlinearFunction(:logistic, Any[logistic_x]),
            MOI.GreaterThan(0.9),
        )
        MOI.add_constraint(
            logistic_domain_model,
            MOI.ScalarNonlinearFunction(:log, Any[logistic_x]),
            MOI.LessThan(10.0),
        )
        logistic_domains = NLPDiagnostics._domain_variable_intervals(
            NLPDiagnostics.snapshot(logistic_domain_model),
        )
        @test logistic_domains[logistic_x].lower ≈
              log(0.9) - log1p(-0.9) atol = 1.0e-12
        @test isempty(NLPDiagnostics.domain_issues(logistic_domain_model))

        tanh_domain_model = new_model()
        tanh_x = MOI.add_variable(tanh_domain_model)
        MOI.add_constraint(
            tanh_domain_model,
            MOI.ScalarNonlinearFunction(:tanh, Any[tanh_x]),
            MOI.GreaterThan(0.9),
        )
        MOI.add_constraint(
            tanh_domain_model,
            MOI.ScalarNonlinearFunction(:log, Any[tanh_x]),
            MOI.LessThan(10.0),
        )
        tanh_domains = NLPDiagnostics._domain_variable_intervals(
            NLPDiagnostics.snapshot(tanh_domain_model),
        )
        @test tanh_domains[tanh_x].lower ≈
              (log1p(0.9) - log1p(-0.9)) / 2 atol = 1.0e-12
        @test isempty(NLPDiagnostics.domain_issues(tanh_domain_model))

        atanh_domain_model = new_model()
        atanh_x = MOI.add_variable(atanh_domain_model)
        MOI.add_constraint(
            atanh_domain_model,
            MOI.ScalarNonlinearFunction(:atanh, Any[atanh_x]),
            MOI.GreaterThan(0.9),
        )
        MOI.add_constraint(
            atanh_domain_model,
            MOI.ScalarNonlinearFunction(:log, Any[atanh_x]),
            MOI.LessThan(10.0),
        )
        atanh_domains = NLPDiagnostics._domain_variable_intervals(
            NLPDiagnostics.snapshot(atanh_domain_model),
        )
        @test atanh_domains[atanh_x].lower ≈ tanh(0.9) atol = 1.0e-12
        @test isempty(filter(
            issue -> issue.operator == :log,
            NLPDiagnostics.domain_issues(atanh_domain_model),
        ))

        asinh_domain_model = new_model()
        asinh_x = MOI.add_variable(asinh_domain_model)
        MOI.add_constraint(
            asinh_domain_model,
            MOI.ScalarNonlinearFunction(:asinh, Any[asinh_x]),
            MOI.GreaterThan(1.0),
        )
        MOI.add_constraint(
            asinh_domain_model,
            MOI.ScalarNonlinearFunction(:log, Any[asinh_x]),
            MOI.LessThan(10.0),
        )
        asinh_domains = NLPDiagnostics._domain_variable_intervals(
            NLPDiagnostics.snapshot(asinh_domain_model),
        )
        @test asinh_domains[asinh_x].lower ≈ sinh(1.0) atol = 1.0e-12
        @test isempty(NLPDiagnostics.domain_issues(asinh_domain_model))

        acosh_domain_model = new_model()
        acosh_x = MOI.add_variable(acosh_domain_model)
        MOI.add_constraint(
            acosh_domain_model,
            MOI.ScalarNonlinearFunction(:acosh, Any[acosh_x]),
            MOI.GreaterThan(1.0),
        )
        MOI.add_constraint(
            acosh_domain_model,
            MOI.ScalarNonlinearFunction(:log, Any[acosh_x]),
            MOI.LessThan(10.0),
        )
        acosh_domains = NLPDiagnostics._domain_variable_intervals(
            NLPDiagnostics.snapshot(acosh_domain_model),
        )
        @test acosh_domains[acosh_x].lower ≈ cosh(1.0) atol = 1.0e-12
        @test isempty(NLPDiagnostics.domain_issues(acosh_domain_model))

        atan_domain_model = new_model()
        atan_x = MOI.add_variable(atan_domain_model)
        MOI.add_constraint(
            atan_domain_model,
            MOI.ScalarNonlinearFunction(:atan, Any[atan_x]),
            MOI.GreaterThan(1.0),
        )
        MOI.add_constraint(
            atan_domain_model,
            MOI.ScalarNonlinearFunction(:log, Any[atan_x]),
            MOI.LessThan(10.0),
        )
        atan_domains = NLPDiagnostics._domain_variable_intervals(
            NLPDiagnostics.snapshot(atan_domain_model),
        )
        @test atan_domains[atan_x].lower ≈ tan(1.0) atol = 1.0e-12
        @test isempty(NLPDiagnostics.domain_issues(atan_domain_model))

        inverse_trig_domain_model = new_model()
        asin_x, acos_x, asind_x, acosd_x, atand_x = MOI.add_variables(
            inverse_trig_domain_model, 5,
        )
        MOI.add_constraint(
            inverse_trig_domain_model,
            MOI.ScalarNonlinearFunction(:asin, Any[asin_x]),
            MOI.GreaterThan(0.5),
        )
        MOI.add_constraint(
            inverse_trig_domain_model,
            MOI.ScalarNonlinearFunction(:acos, Any[acos_x]),
            MOI.LessThan(1.0),
        )
        MOI.add_constraint(
            inverse_trig_domain_model,
            MOI.ScalarNonlinearFunction(:asind, Any[asind_x]),
            MOI.GreaterThan(30.0),
        )
        MOI.add_constraint(
            inverse_trig_domain_model,
            MOI.ScalarNonlinearFunction(:acosd, Any[acosd_x]),
            MOI.LessThan(60.0),
        )
        MOI.add_constraint(
            inverse_trig_domain_model,
            MOI.ScalarNonlinearFunction(:atand, Any[atand_x]),
            MOI.GreaterThan(45.0),
        )
        inverse_trig_domains = NLPDiagnostics._domain_variable_intervals(
            NLPDiagnostics.snapshot(inverse_trig_domain_model),
        )
        @test inverse_trig_domains[asin_x].lower ≈ sin(0.5) atol = 1.0e-12
        @test inverse_trig_domains[acos_x].lower ≈ cos(1.0) atol = 1.0e-12
        @test inverse_trig_domains[asind_x].lower ≈ 0.5 atol = 1.0e-12
        @test inverse_trig_domains[acosd_x].lower ≈ 0.5 atol = 1.0e-12
        @test inverse_trig_domains[atand_x].lower ≈ 1.0 atol = 1.0e-12

        monotone_extension_model = new_model()
        sinh_x, cbrt_x = MOI.add_variables(monotone_extension_model, 2)
        MOI.add_constraint(
            monotone_extension_model,
            MOI.ScalarNonlinearFunction(:sinh, Any[sinh_x]),
            MOI.GreaterThan(1.0),
        )
        MOI.add_constraint(
            monotone_extension_model,
            MOI.ScalarNonlinearFunction(:cbrt, Any[cbrt_x]),
            MOI.GreaterThan(2.0),
        )
        monotone_extension_domains = NLPDiagnostics._domain_variable_intervals(
            NLPDiagnostics.snapshot(monotone_extension_model),
        )
        @test monotone_extension_domains[sinh_x].lower ≈ asinh(1.0) atol = 1.0e-12
        @test monotone_extension_domains[cbrt_x].lower == 8.0

        bounded_logistic_model = new_model()
        bounded_logistic_x = MOI.add_variable(bounded_logistic_model)
        MOI.add_constraint(
            bounded_logistic_model,
            bounded_logistic_x,
            MOI.Interval(-2.0, 2.0),
        )
        MOI.add_constraint(
            bounded_logistic_model,
            MOI.ScalarNonlinearFunction(
                :log,
                Any[MOI.ScalarNonlinearFunction(:logistic, Any[bounded_logistic_x])],
            ),
            MOI.LessThan(10.0),
        )
        @test isempty(filter(
            issue -> issue.operator == :log,
            NLPDiagnostics.domain_issues(bounded_logistic_model),
        ))

        bounded_sine_model = new_model()
        bounded_sine_x = MOI.add_variable(bounded_sine_model)
        MOI.add_constraint(
            bounded_sine_model,
            bounded_sine_x,
            MOI.Interval(0.1, 0.2),
        )
        MOI.add_constraint(
            bounded_sine_model,
            MOI.ScalarNonlinearFunction(
                :log,
                Any[MOI.ScalarNonlinearFunction(:sin, Any[bounded_sine_x])],
            ),
            MOI.LessThan(10.0),
        )
        @test isempty(filter(
            issue -> issue.operator == :log,
            NLPDiagnostics.domain_issues(bounded_sine_model),
        ))

        bounded_tangent_model = new_model()
        bounded_tangent_x = MOI.add_variable(bounded_tangent_model)
        MOI.add_constraint(
            bounded_tangent_model,
            bounded_tangent_x,
            MOI.Interval(0.1, 0.2),
        )
        MOI.add_constraint(
            bounded_tangent_model,
            MOI.ScalarNonlinearFunction(
                :log,
                Any[MOI.ScalarNonlinearFunction(:tan, Any[bounded_tangent_x])],
            ),
            MOI.LessThan(10.0),
        )
        @test isempty(filter(
            issue -> issue.operator == :log,
            NLPDiagnostics.domain_issues(bounded_tangent_model),
        ))

        absolute_domain_model = new_model()
        absolute_x = MOI.add_variable(absolute_domain_model)
        MOI.add_constraint(
            absolute_domain_model,
            MOI.ScalarNonlinearFunction(:abs, Any[absolute_x]),
            MOI.EqualTo(0.0),
        )
        MOI.add_constraint(
            absolute_domain_model,
            MOI.ScalarNonlinearFunction(:log, Any[absolute_x]),
            MOI.LessThan(10.0),
        )
        absolute_domains = NLPDiagnostics._domain_variable_intervals(
            NLPDiagnostics.snapshot(absolute_domain_model),
        )
        @test absolute_domains[absolute_x].lower == 0.0
        @test absolute_domains[absolute_x].upper == 0.0
        absolute_domain_finding = only(findings(
            NLPDiagnostics.analyze_domains(absolute_domain_model),
            :proven_expression_domain_violation,
        ))
        @test occursin(
            "absolute_value_range:MathOptInterface.ScalarNonlinearFunction/MathOptInterface.EqualTo{Float64}#1",
            Dict(absolute_domain_finding.evidence[1].details)[
                "support_interval_origins"
            ],
        )

        cosh_domain_model = new_model()
        cosh_x = MOI.add_variable(cosh_domain_model)
        MOI.add_constraint(
            cosh_domain_model,
            MOI.ScalarNonlinearFunction(:cosh, Any[cosh_x]),
            MOI.EqualTo(1.0),
        )
        MOI.add_constraint(
            cosh_domain_model,
            MOI.ScalarNonlinearFunction(:log, Any[cosh_x]),
            MOI.LessThan(10.0),
        )
        cosh_domains = NLPDiagnostics._domain_variable_intervals(
            NLPDiagnostics.snapshot(cosh_domain_model),
        )
        @test cosh_domains[cosh_x].lower == 0.0
        @test cosh_domains[cosh_x].upper == 0.0
        cosh_domain_finding = only(findings(
            NLPDiagnostics.analyze_domains(cosh_domain_model),
            :proven_expression_domain_violation,
        ))
        @test occursin(
            "cosh_range:MathOptInterface.ScalarNonlinearFunction/MathOptInterface.EqualTo{Float64}#1",
            Dict(cosh_domain_finding.evidence[1].details)[
                "support_interval_origins"
            ],
        )

        logcosh_domain_model = new_model()
        logcosh_x = MOI.add_variable(logcosh_domain_model)
        MOI.add_constraint(
            logcosh_domain_model,
            MOI.ScalarNonlinearFunction(:logcosh, Any[logcosh_x]),
            MOI.EqualTo(0.0),
        )
        MOI.add_constraint(
            logcosh_domain_model,
            MOI.ScalarNonlinearFunction(:log, Any[logcosh_x]),
            MOI.LessThan(10.0),
        )
        logcosh_domains = NLPDiagnostics._domain_variable_intervals(
            NLPDiagnostics.snapshot(logcosh_domain_model),
        )
        @test logcosh_domains[logcosh_x].lower == 0.0
        @test logcosh_domains[logcosh_x].upper == 0.0
        logcosh_domain_finding = only(findings(
            NLPDiagnostics.analyze_domains(logcosh_domain_model),
            :proven_expression_domain_violation,
        ))
        @test occursin(
            "logcosh_range:MathOptInterface.ScalarNonlinearFunction/MathOptInterface.EqualTo{Float64}#1",
            Dict(logcosh_domain_finding.evidence[1].details)[
                "support_interval_origins"
            ],
        )

        minmax_domain_model = new_model()
        minmax_x, minmax_y = MOI.add_variables(minmax_domain_model, 2)
        MOI.add_constraint(
            minmax_domain_model,
            MOI.ScalarNonlinearFunction(:min, Any[minmax_x, 2.0]),
            MOI.GreaterThan(1.0),
        )
        MOI.add_constraint(
            minmax_domain_model,
            MOI.ScalarNonlinearFunction(:log, Any[minmax_x]),
            MOI.LessThan(10.0),
        )
        MOI.add_constraint(
            minmax_domain_model,
            MOI.ScalarNonlinearFunction(:max, Any[minmax_y, 0.0]),
            MOI.EqualTo(0.0),
        )
        MOI.add_constraint(
            minmax_domain_model,
            MOI.ScalarNonlinearFunction(:log, Any[minmax_y]),
            MOI.LessThan(10.0),
        )
        minmax_domains = NLPDiagnostics._domain_variable_intervals(
            NLPDiagnostics.snapshot(minmax_domain_model),
        )
        @test minmax_domains[minmax_x].lower == 1.0
        @test minmax_domains[minmax_y].upper == 0.0
        minmax_interval_data = NLPDiagnostics.domain_interval_data(
            minmax_domain_model,
        )
        minmax_x_data = only(filter(
            item -> item["variable_index"] == minmax_x.value,
            minmax_interval_data,
        ))
        @test minmax_x_data["lower"] == 1.0
        @test occursin("minmax_branch_interval", minmax_x_data["origins"])
        minmax_report = NLPDiagnostics.analyze_domains(minmax_domain_model)
        @test isempty(findings(minmax_report, :possible_expression_domain_violation))
        minmax_finding = only(findings(
            minmax_report,
            :proven_expression_domain_violation,
        ))
        @test occursin(
            "minmax_branch_interval:MathOptInterface.ScalarNonlinearFunction/MathOptInterface.EqualTo{Float64}#1",
            Dict(minmax_finding.evidence[1].details)[
                "support_interval_origins"
            ],
        )

        zero_domain_model = new_model()
        zero_x, zero_y = MOI.add_variables(zero_domain_model, 2)
        zero_domain_circle = Q(
            [QT(2.0, zero_x, zero_x), QT(2.0, zero_y, zero_y)],
            MOI.ScalarAffineTerm{Float64}[],
            0.0,
        )
        MOI.add_constraint(zero_domain_model, zero_domain_circle, MOI.EqualTo(0.0))
        zero_propagated_domains = NLPDiagnostics._domain_variable_intervals(
            NLPDiagnostics.snapshot(zero_domain_model),
        )
        @test zero_propagated_domains[zero_x].lower == 0.0
        @test zero_propagated_domains[zero_x].upper == 0.0
        MOI.add_constraint(
            zero_domain_model,
            MOI.ScalarNonlinearFunction(:log, Any[zero_x]),
            MOI.LessThan(10.0),
        )
        @test length(findings(
            NLPDiagnostics.analyze_domains(zero_domain_model),
            :proven_expression_domain_violation,
        )) == 1

        near_unit = new_model()
        near_x, near_y = MOI.add_variables(near_unit, 2)
        near_unit_ellipsoid = Q(
            [QT(2.0, near_x, near_x), QT(2.000001, near_y, near_y)],
            MOI.ScalarAffineTerm{Float64}[],
            0.0,
        )
        MOI.add_constraint(near_unit, near_unit_ellipsoid, MOI.EqualTo(1.0))
        near_report = NLPDiagnostics.analyze_static(near_unit)
        @test isempty(findings(near_report, :nonunit_ellipsoidal_constraint_axes))
        @test length(findings(near_report, :ellipsoidal_implied_variable_bound)) == 2

        zero_conflict = new_model()
        e, f = MOI.add_variables(zero_conflict, 2)
        zero_ellipsoid_conflict = Q(
            [QT(2.0, e, e), QT(8.0, f, f)],
            [AT(-4.0, e), AT(8.0, f)],
            0.0,
        )
        MOI.add_constraint(zero_conflict, zero_ellipsoid_conflict, MOI.EqualTo(-8.0))
        MOI.add_constraint(zero_conflict, e, MOI.GreaterThan(3.0))
        zero_contradiction = only(findings(
            NLPDiagnostics.analyze_static(zero_conflict),
            :inconsistent_zero_level_diagonal_quadratic_variable_bound,
        ))
        @test zero_contradiction.basis == NLPDiagnostics.MathematicalProof
        @test evidence_details(zero_contradiction)["implied_value"] == "2.0"
    end

    @testset "diagonal quadratic upper bounds expose exact minima" begin
        model = new_model()
        x, y = MOI.add_variables(model, 2)
        Q = MOI.ScalarQuadraticFunction{Float64}
        QT = MOI.ScalarQuadraticTerm{Float64}
        AT = MOI.ScalarAffineTerm{Float64}
        bowl = Q(
            [QT(2.0, x, x), QT(8.0, y, y)],
            [AT(-4.0, x), AT(8.0, y)],
            3.0,
        )
        # (x - 2)^2 + 4 * (y + 1)^2 - 5 has minimum -5.
        MOI.add_constraint(model, bowl, MOI.LessThan(-6.0))
        infeasible = only(findings(
            NLPDiagnostics.analyze_static(model),
            :infeasible_below_minimum_diagonal_quadratic_constraint,
        ))
        @test infeasible.basis == NLPDiagnostics.MathematicalProof
        @test evidence_details(infeasible)["minimum_value"] == "-5.0"

        minimum_level = new_model()
        u, v = MOI.add_variables(minimum_level, 2)
        minimum_bowl = Q(
            [QT(2.0, u, u), QT(8.0, v, v)],
            [AT(-4.0, u), AT(8.0, v)],
            3.0,
        )
        MOI.add_constraint(minimum_level, minimum_bowl, MOI.Interval(-10.0, -5.0))
        fixed = only(findings(
            NLPDiagnostics.analyze_static(minimum_level),
            :minimum_level_diagonal_quadratic_constraint,
        ))
        @test evidence_details(fixed)["center"] == "[2.0, -1.0]"
        nonregular_minimum = only(findings(
            NLPDiagnostics.analyze_static(minimum_level),
            :nonregular_minimum_level_diagonal_quadratic_inequality,
        ))
        @test nonregular_minimum.domain == NLPDiagnostics.NumericalIssue
        @test nonregular_minimum.basis == NLPDiagnostics.MathematicalProof

        bounded = new_model()
        p, q = MOI.add_variables(bounded, 2)
        bounded_bowl = Q(
            [QT(2.0, p, p), QT(8.0, q, q)],
            [AT(-4.0, p), AT(8.0, q)],
            3.0,
        )
        # The level -1 is four above the minimum, giving p ∈ [0, 4], q ∈ [-2, 0].
        MOI.add_constraint(bounded, bounded_bowl, MOI.LessThan(-1.0))
        implied = findings(
            NLPDiagnostics.analyze_static(bounded),
            :diagonal_quadratic_implied_variable_bound,
        )
        @test length(implied) == 2
        implied_by_variable = Dict(
            only(ref.index for ref in finding.affected if ref.kind == :variable) =>
                evidence_details(finding) for finding in implied
        )
        @test implied_by_variable[p.value]["derived_lower"] == "0.0"
        @test implied_by_variable[p.value]["derived_upper"] == "4.0"
        @test implied_by_variable[q.value]["derived_lower"] == "-2.0"
        @test implied_by_variable[q.value]["derived_upper"] == "0.0"

        nonlinear_bounded = new_model()
        nonlinear_p, nonlinear_q = MOI.add_variables(nonlinear_bounded, 2)
        nonlinear_bowl = MOI.ScalarNonlinearFunction(
            :+,
            Any[
                MOI.ScalarNonlinearFunction(:^, Any[nonlinear_p, 2]),
                MOI.ScalarNonlinearFunction(
                    :*,
                    Any[4.0, MOI.ScalarNonlinearFunction(:^, Any[nonlinear_q, 2])],
                ),
                MOI.ScalarNonlinearFunction(:*, Any[-4.0, nonlinear_p]),
                MOI.ScalarNonlinearFunction(:*, Any[8.0, nonlinear_q]),
                3.0,
            ],
        )
        MOI.add_constraint(nonlinear_bounded, nonlinear_bowl, MOI.LessThan(-1.0))
        nonlinear_implied = findings(
            NLPDiagnostics.analyze_static(nonlinear_bounded),
            :diagonal_quadratic_implied_variable_bound,
        )
        @test length(nonlinear_implied) == 2
        @test Set(evidence_details(finding)["derived_upper"] for finding in nonlinear_implied) ==
              Set(["4.0", "0.0"])

        conflicting_bound = new_model()
        a, b = MOI.add_variables(conflicting_bound, 2)
        conflicting_bowl = Q(
            [QT(2.0, a, a), QT(8.0, b, b)],
            [AT(-4.0, a), AT(8.0, b)],
            3.0,
        )
        MOI.add_constraint(conflicting_bound, conflicting_bowl, MOI.LessThan(-1.0))
        MOI.add_constraint(conflicting_bound, a, MOI.GreaterThan(5.0))
        contradiction = only(findings(
            NLPDiagnostics.analyze_static(conflicting_bound),
            :inconsistent_diagonal_quadratic_implied_variable_bound,
        ))
        @test contradiction.basis == NLPDiagnostics.MathematicalProof
        @test evidence_details(contradiction)["derived_upper"] == "4.0"
        @test evidence_details(contradiction)["declared_lower"] == "5.0"
    end

    @testset "initialization identifies diagonal quadratic coordinate violations" begin
        model = new_model()
        x, y = MOI.add_variables(model, 2)
        Q = MOI.ScalarQuadraticFunction{Float64}
        QT = MOI.ScalarQuadraticTerm{Float64}
        AT = MOI.ScalarAffineTerm{Float64}
        bowl = Q(
            [QT(2.0, x, x), QT(8.0, y, y)],
            [AT(-4.0, x), AT(8.0, y)],
            3.0,
        )
        MOI.add_constraint(model, bowl, MOI.LessThan(-1.0))
        MOI.set(model, MOI.VariablePrimalStart(), x, 5.0)
        MOI.set(model, MOI.VariablePrimalStart(), y, -1.0)
        report = NLPDiagnostics.analyze_initialization(model)
        violation = only(findings(
            report,
            :initialization_violates_diagonal_quadratic_implied_bound,
        ))
        @test violation.basis == NLPDiagnostics.MathematicalProof
        @test occursin(
            "value=5.0",
            Dict(violation.evidence[2].details)["v$(x.value)"],
        )

        nonlinear = new_model()
        p, q = MOI.add_variables(nonlinear, 2)
        nonlinear_bowl = MOI.ScalarNonlinearFunction(
            :+,
            Any[
                MOI.ScalarNonlinearFunction(:^, Any[p, 2]),
                MOI.ScalarNonlinearFunction(
                    :*,
                    Any[4.0, MOI.ScalarNonlinearFunction(:^, Any[q, 2])],
                ),
                MOI.ScalarNonlinearFunction(:*, Any[-4.0, p]),
                MOI.ScalarNonlinearFunction(:*, Any[8.0, q]),
                3.0,
            ],
        )
        MOI.add_constraint(nonlinear, nonlinear_bowl, MOI.LessThan(-1.0))
        MOI.set(nonlinear, MOI.VariablePrimalStart(), p, 5.0)
        MOI.set(nonlinear, MOI.VariablePrimalStart(), q, -1.0)
        nonlinear_report = NLPDiagnostics.analyze_initialization(nonlinear)
        @test length(findings(
            nonlinear_report,
            :initialization_violates_diagonal_quadratic_implied_bound,
        )) == 1

        equality = new_model()
        a, b = MOI.add_variables(equality, 2)
        circle = Q(
            [QT(2.0, a, a), QT(2.0, b, b)],
            MOI.ScalarAffineTerm{Float64}[],
            0.0,
        )
        MOI.add_constraint(equality, circle, MOI.EqualTo(4.0))
        MOI.set(equality, MOI.VariablePrimalStart(), a, 3.0)
        MOI.set(equality, MOI.VariablePrimalStart(), b, 0.0)
        equality_report = NLPDiagnostics.analyze_initialization(equality)
        @test length(findings(
            equality_report,
            :initialization_violates_diagonal_quadratic_equality_implied_bound,
        )) == 1

        nonlinear_equality = new_model()
        c, d = MOI.add_variables(nonlinear_equality, 2)
        nonlinear_circle = MOI.ScalarNonlinearFunction(
            :+,
            Any[
                MOI.ScalarNonlinearFunction(:^, Any[c, 2]),
                MOI.ScalarNonlinearFunction(:^, Any[d, 2]),
            ],
        )
        MOI.add_constraint(nonlinear_equality, nonlinear_circle, MOI.EqualTo(4.0))
        MOI.set(nonlinear_equality, MOI.VariablePrimalStart(), c, 3.0)
        MOI.set(nonlinear_equality, MOI.VariablePrimalStart(), d, 0.0)
        nonlinear_equality_report = NLPDiagnostics.analyze_initialization(nonlinear_equality)
        nonlinear_equality_violation = only(findings(
            nonlinear_equality_report,
            :initialization_violates_diagonal_quadratic_equality_implied_bound,
        ))
        @test Dict(nonlinear_equality_violation.evidence[2].details)["representation"] ==
              "ScalarNonlinearFunction"
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
        @test all(
            finding ->
                Dict(finding.evidence[1].details)["support_interval_origins"] ==
                "v$(x.value)=declared_variable_bounds:MathOptInterface.ScalarNonlinearFunction/MathOptInterface.Interval{Float64}#1",
            possible,
        )

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
        log_one_minus = MOI.ScalarNonlinearFunction(
            :log,
            Any[MOI.ScalarNonlinearFunction(:-, Any[1.0, x])],
        )
        exp_minus_one =
            MOI.ScalarNonlinearFunction(:-, Any[exp_x, 1.0])
        log_one_minus_exp = MOI.ScalarNonlinearFunction(
            :log,
            Any[MOI.ScalarNonlinearFunction(:-, Any[1.0, exp_x])],
        )
        log1p_negative_exp = MOI.ScalarNonlinearFunction(
            :log1p,
            Any[MOI.ScalarNonlinearFunction(:-, Any[exp_x])],
        )
        log_cosh = MOI.ScalarNonlinearFunction(
            :log,
            Any[MOI.ScalarNonlinearFunction(:cosh, Any[x])],
        )
        log_sum_exp = MOI.ScalarNonlinearFunction(
            :log,
            Any[MOI.ScalarNonlinearFunction(:+, Any[
                exp_x,
                MOI.ScalarNonlinearFunction(:exp, Any[
                    MOI.ScalarNonlinearFunction(:-, Any[x]),
                ]),
            ])],
        )
        log_sum_exp_three_terms = MOI.ScalarNonlinearFunction(
            :log,
            Any[MOI.ScalarNonlinearFunction(:+, Any[
                exp_x,
                MOI.ScalarNonlinearFunction(:exp, Any[
                    MOI.ScalarNonlinearFunction(:-, Any[x]),
                ]),
                MOI.ScalarNonlinearFunction(:exp, Any[
                    MOI.ScalarNonlinearFunction(:*, Any[2.0, x]),
                ]),
            ])],
        )
        log_diff_exp = MOI.ScalarNonlinearFunction(
            :log,
            Any[MOI.ScalarNonlinearFunction(:-, Any[
                MOI.ScalarNonlinearFunction(:exp, Any[1.0]),
                exp_x,
            ])],
        )
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
        logistic_exp_over_sum = MOI.ScalarNonlinearFunction(
            :/,
            Any[
                exp_x,
                MOI.ScalarNonlinearFunction(:+, Any[1.0, exp_x]),
            ],
        )
        complementary_logistic = MOI.ScalarNonlinearFunction(
            :/,
            Any[
                1.0,
                MOI.ScalarNonlinearFunction(:+, Any[1.0, exp_x]),
            ],
        )
        for expression in
            (softplus, log_one_plus, log_one_minus, exp_minus_one, log_one_minus_exp,
             log1p_negative_exp, log_cosh, log_sum_exp, log_sum_exp_three_terms,
             log_diff_exp, logistic, logistic_exp_over_sum, complementary_logistic)
            MOI.add_constraint(model, expression, MOI.LessThan(1.0e6))
        end
        report = NLPDiagnostics.analyze_expressions(model)
        @test length(findings(report, :unstable_softplus_expression)) == 1
        @test length(findings(report, :log_one_plus_cancellation_risk)) ==
              1
        @test length(findings(report, :log_one_minus_cancellation_risk)) ==
              1
        @test length(findings(report, :exp_minus_one_cancellation_risk)) ==
              1
        @test length(findings(report, :log_one_minus_exp_cancellation_risk)) ==
              2
        @test length(findings(report, :unstable_logcosh_expression)) == 1
        @test length(findings(report, :unstable_logsumexp_expression)) == 2
        @test length(findings(report, :unstable_logdiffexp_expression)) == 1
        @test length(findings(report, :unstable_logistic_expression)) == 2
        @test length(findings(report, :unstable_complementary_logistic_expression)) == 1
        @test !isempty(findings(report, :exponential_overflow_risk))
        @test !isempty(findings(report, :exponential_underflow_risk))
        reformulation_plan = NLPDiagnostics.stable_reformulation_plan(model)
        @test length(reformulation_plan.candidates) == 13
        @test Set(candidate.replacement for candidate in reformulation_plan.candidates) ==
              Set([:log1pexp, :log1p, :expm1, :log1mexp, :logcosh, :logsumexp,
                   :logdiffexp, :logistic])
        @test count(
            candidate -> candidate.requires_registered_operator,
            reformulation_plan.candidates,
        ) == 10
        reformulation_report = NLPDiagnostics.analyze_stable_reformulation_plan(reformulation_plan)
        @test length(findings(reformulation_report, :stable_reformulation_candidate)) == 13

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

        stable_domain_model = new_model()
        stable_domain_argument = MOI.add_variable(stable_domain_model)
        MOI.add_constraint(stable_domain_model, stable_domain_argument, MOI.GreaterThan(0.0))
        MOI.add_constraint(
            stable_domain_model,
            MOI.ScalarNonlinearFunction(:log1mexp, Any[stable_domain_argument]),
            MOI.LessThan(0.0),
        )
        @test count(
            issue -> issue.operator == :log1mexp &&
                     issue.assessment == NLPDiagnostics.DomainProvenViolation,
            NLPDiagnostics.domain_issues(stable_domain_model),
        ) == 1

        logdiff_domain_model = new_model()
        logdiff_a, logdiff_b = MOI.add_variables(logdiff_domain_model, 2)
        MOI.add_constraint(logdiff_domain_model, logdiff_a, MOI.LessThan(0.0))
        MOI.add_constraint(logdiff_domain_model, logdiff_b, MOI.GreaterThan(1.0))
        MOI.add_constraint(
            logdiff_domain_model,
            MOI.ScalarNonlinearFunction(:logdiffexp, Any[logdiff_a, logdiff_b]),
            MOI.LessThan(0.0),
        )
        @test count(
            issue -> issue.operator == :logdiffexp &&
                     issue.assessment == NLPDiagnostics.DomainProvenViolation,
            NLPDiagnostics.domain_issues(logdiff_domain_model),
        ) == 2

        # Stable interval rules must remain meaningful at IEEE endpoint values:
        # these are common during loose-bound static analysis, even when a
        # representative initialization is finite.
        all_negative_infinite = NLPDiagnostics.operator_interval(
            Val(:logsumexp),
            [NLPDiagnostics.IntervalEnclosure(-Inf, -Inf)],
            Any[],
        )
        mixed_infinite = NLPDiagnostics.operator_interval(
            Val(:logsumexp),
            [
                NLPDiagnostics.IntervalEnclosure(-Inf, Inf),
                NLPDiagnostics.IntervalEnclosure(-1.0, 1.0),
            ],
            Any[],
        )
        @test all_negative_infinite.lower == -Inf
        @test all_negative_infinite.upper == -Inf
        @test !isnan(mixed_infinite.lower)
        @test !isnan(mixed_infinite.upper)

        near_log1mexp_model = new_model()
        near_log1mexp = MOI.add_variable(near_log1mexp_model)
        MOI.add_constraint(
            near_log1mexp_model,
            MOI.ScalarNonlinearFunction(:log1mexp, Any[near_log1mexp]),
            MOI.LessThan(0.0),
        )
        near_log1mexp_point = NLPDiagnostics.EvaluationPoint(
            [near_log1mexp], [-1e-12]; label = "near log1mexp boundary",
        )
        near_log1mexp_report = NLPDiagnostics.analyze_expressions(
            near_log1mexp_model; point = near_log1mexp_point,
        )
        @test length(findings(
            near_log1mexp_report,
            :operating_point_strict_domain_derivative_amplification,
        )) == 1
        near_log1mexp_evidence = Dict(
            only(near_log1mexp_report.findings).evidence[end].details,
        )
        @test parse(Float64, near_log1mexp_evidence["estimated_first_derivative_magnitude"]) > 1e11
        @test parse(Float64, near_log1mexp_evidence["estimated_second_derivative_magnitude"]) > 1e23
        MOI.set(
            near_log1mexp_model,
            MOI.VariablePrimalStart(),
            near_log1mexp,
            -1e-12,
        )
        @test length(findings(
            NLPDiagnostics.analyze_initialization(near_log1mexp_model),
            :operating_point_strict_domain_derivative_amplification,
        )) == 1

        near_composite_log_model = new_model()
        near_composite_log = MOI.add_variable(near_composite_log_model)
        MOI.add_constraint(
            near_composite_log_model,
            MOI.ScalarNonlinearFunction(:log, Any[
                MOI.ScalarNonlinearFunction(:-, Any[
                    1.0,
                    MOI.ScalarNonlinearFunction(:exp, Any[near_composite_log]),
                ]),
            ]),
            MOI.LessThan(0.0),
        )
        @test length(findings(
            NLPDiagnostics.analyze_expressions(
                near_composite_log_model;
                point = NLPDiagnostics.EvaluationPoint([near_composite_log], [-1e-12]),
            ),
            :operating_point_strict_domain_derivative_amplification,
        )) == 1

        near_logdiffexp_model = new_model()
        near_a, near_b = MOI.add_variables(near_logdiffexp_model, 2)
        MOI.add_constraint(
            near_logdiffexp_model,
            MOI.ScalarNonlinearFunction(:logdiffexp, Any[near_a, near_b]),
            MOI.LessThan(0.0),
        )
        near_logdiffexp_point = NLPDiagnostics.EvaluationPoint(
            [near_a, near_b], [1.0, 1.0 - 1e-12];
            label = "near logdiffexp boundary",
        )
        near_logdiffexp_report = NLPDiagnostics.analyze_expressions(
            near_logdiffexp_model; point = near_logdiffexp_point,
        )
        @test length(findings(
            near_logdiffexp_report,
            :operating_point_strict_domain_derivative_amplification,
        )) == 1
        near_logdiffexp_evidence = Dict(
            only(near_logdiffexp_report.findings).evidence[end].details,
        )
        @test parse(Float64, near_logdiffexp_evidence["estimated_maximum_first_derivative_magnitude"]) > 1e11
        @test parse(Float64, near_logdiffexp_evidence["estimated_second_derivative_magnitude"]) > 1e23

        near_sqrt_model = new_model()
        near_sqrt = MOI.add_variable(near_sqrt_model)
        MOI.add_constraint(
            near_sqrt_model,
            MOI.ScalarNonlinearFunction(:sqrt, Any[near_sqrt]),
            MOI.LessThan(1.0),
        )
        near_sqrt_report = NLPDiagnostics.analyze_expressions(
            near_sqrt_model;
            point = NLPDiagnostics.EvaluationPoint([near_sqrt], [1e-12]),
        )
        near_sqrt_evidence = Dict(only(near_sqrt_report.findings).evidence[end].details)
        @test parse(Float64, near_sqrt_evidence["estimated_first_derivative_magnitude"]) > 1e5
        @test parse(Float64, near_sqrt_evidence["estimated_second_derivative_magnitude"]) > 1e17

        threshold_model = new_model()
        threshold_variable = MOI.add_variable(threshold_model)
        MOI.add_constraint(
            threshold_model,
            MOI.ScalarNonlinearFunction(:sqrt, Any[threshold_variable]),
            MOI.LessThan(1.0),
        )
        threshold_point = NLPDiagnostics.EvaluationPoint([threshold_variable], [1e-4])
        @test isempty(findings(
            NLPDiagnostics.analyze_expressions(threshold_model; point = threshold_point),
            :operating_point_strict_domain_derivative_amplification,
        ))
        threshold_report = NLPDiagnostics.analyze_expressions(
            threshold_model;
            point = threshold_point,
            strict_domain_proximity_threshold = 1e-3,
        )
        @test length(findings(
            threshold_report,
            :operating_point_strict_domain_derivative_amplification,
        )) == 1
        @test threshold_report.metadata[:strict_domain_proximity_threshold] == "0.001"
        @test_throws ArgumentError NLPDiagnostics.analyze_expressions(
            threshold_model;
            point = threshold_point,
            strict_domain_proximity_threshold = 0.0,
        )

        float32_derivative_model = new_model()
        float32_derivative = MOI.add_variable(float32_derivative_model)
        MOI.add_constraint(
            float32_derivative_model,
            MOI.ScalarNonlinearFunction(:sqrt, Any[float32_derivative]),
            MOI.LessThan(1.0),
        )
        float32_derivative_report = NLPDiagnostics.analyze_expressions(
            float32_derivative_model;
            point = NLPDiagnostics.EvaluationPoint([float32_derivative], [1e-30]),
            numeric_type = Float32,
        )
        float32_derivative_finding = only(findings(
            float32_derivative_report,
            :operating_point_strict_domain_derivative_amplification,
        ))
        @test float32_derivative_finding.severity == NLPDiagnostics.SeverityError
        @test float32_derivative_finding.basis == NLPDiagnostics.NumericalObservation

        near_reciprocal_model = new_model()
        near_denominator = MOI.add_variable(near_reciprocal_model)
        MOI.add_constraint(
            near_reciprocal_model,
            MOI.ScalarNonlinearFunction(:inv, Any[near_denominator]),
            MOI.LessThan(1e20),
        )
        near_reciprocal_report = NLPDiagnostics.analyze_expressions(
            near_reciprocal_model;
            point = NLPDiagnostics.EvaluationPoint([near_denominator], [1e-12]),
        )
        near_reciprocal_evidence = Dict(
            only(near_reciprocal_report.findings).evidence[end].details,
        )
        @test parse(Float64, near_reciprocal_evidence["estimated_reciprocal_first_derivative_magnitude"]) > 1e23
        @test parse(Float64, near_reciprocal_evidence["estimated_reciprocal_second_derivative_magnitude"]) > 1e35

        near_power_model = new_model()
        near_power = MOI.add_variable(near_power_model)
        MOI.add_constraint(
            near_power_model,
            MOI.ScalarNonlinearFunction(:^, Any[near_power, 1.5]),
            MOI.LessThan(1.0),
        )
        near_power_report = NLPDiagnostics.analyze_expressions(
            near_power_model;
            point = NLPDiagnostics.EvaluationPoint([near_power], [1e-12]),
        )
        near_power_evidence = Dict(only(near_power_report.findings).evidence[end].details)
        @test near_power_evidence["exponent"] == "1.5"
        @test parse(Float64, near_power_evidence["estimated_second_derivative_magnitude"]) > 1e5

        near_negative_power_model = new_model()
        near_negative_power = MOI.add_variable(near_negative_power_model)
        MOI.add_constraint(
            near_negative_power_model,
            MOI.ScalarNonlinearFunction(:^, Any[near_negative_power, -1]),
            MOI.LessThan(1e20),
        )
        near_negative_power_report = NLPDiagnostics.analyze_expressions(
            near_negative_power_model;
            point = NLPDiagnostics.EvaluationPoint([near_negative_power], [-1e-12]),
        )
        near_negative_power_evidence = Dict(
            only(near_negative_power_report.findings).evidence[end].details,
        )
        @test near_negative_power_evidence["base_requirement"] == "nonzero base"
        @test parse(Float64, near_negative_power_evidence["estimated_first_derivative_magnitude"]) > 1e23

        near_tan_model = new_model()
        near_tan = MOI.add_variable(near_tan_model)
        MOI.add_constraint(
            near_tan_model,
            MOI.ScalarNonlinearFunction(:tan, Any[near_tan]),
            MOI.LessThan(1e20),
        )
        near_tan_report = NLPDiagnostics.analyze_expressions(
            near_tan_model;
            point = NLPDiagnostics.EvaluationPoint([near_tan], [Float64(pi / 2)]),
        )
        near_tan_evidence = Dict(only(near_tan_report.findings).evidence[end].details)
        @test near_tan_evidence["denominator"] == "cos(argument)"
        @test parse(Float64, near_tan_evidence["estimated_first_derivative_magnitude"]) > 1e30

        near_tand_model = new_model()
        near_tand = MOI.add_variable(near_tand_model)
        MOI.add_constraint(
            near_tand_model,
            MOI.ScalarNonlinearFunction(:tand, Any[near_tand]),
            MOI.LessThan(1e20),
        )
        near_tand_report = NLPDiagnostics.analyze_expressions(
            near_tand_model;
            point = NLPDiagnostics.EvaluationPoint([near_tand], [90.0]),
        )
        near_tand_evidence = Dict(only(near_tand_report.findings).evidence[end].details)
        @test near_tand_evidence["denominator"] == "cosd(argument)"
        @test only(near_tand_report.findings).severity == NLPDiagnostics.SeverityError

        near_asin_model = new_model()
        near_asin = MOI.add_variable(near_asin_model)
        MOI.add_constraint(
            near_asin_model,
            MOI.ScalarNonlinearFunction(:asin, Any[near_asin]),
            MOI.LessThan(2.0),
        )
        near_asin_report = NLPDiagnostics.analyze_expressions(
            near_asin_model;
            point = NLPDiagnostics.EvaluationPoint([near_asin], [1.0 - 1e-12]),
        )
        near_asin_evidence = Dict(only(near_asin_report.findings).evidence[end].details)
        @test near_asin_evidence["boundary"] == "±1"
        @test parse(Float64, near_asin_evidence["estimated_first_derivative_magnitude"]) > 1e5

        near_asind_model = new_model()
        near_asind = MOI.add_variable(near_asind_model)
        MOI.add_constraint(
            near_asind_model,
            MOI.ScalarNonlinearFunction(:asind, Any[near_asind]),
            MOI.LessThan(100.0),
        )
        near_asind_report = NLPDiagnostics.analyze_expressions(
            near_asind_model;
            point = NLPDiagnostics.EvaluationPoint([near_asind], [1.0 - 1e-12]),
        )
        near_asind_evidence = Dict(only(near_asind_report.findings).evidence[end].details)
        @test parse(Float64, near_asind_evidence["estimated_first_derivative_magnitude"]) > 1e7

        near_asec_model = new_model()
        near_asec = MOI.add_variable(near_asec_model)
        MOI.add_constraint(
            near_asec_model,
            MOI.ScalarNonlinearFunction(:asec, Any[near_asec]),
            MOI.LessThan(2.0),
        )
        near_asec_report = NLPDiagnostics.analyze_expressions(
            near_asec_model;
            point = NLPDiagnostics.EvaluationPoint([near_asec], [1.0 + 1e-12]),
        )
        near_asec_evidence = Dict(only(near_asec_report.findings).evidence[end].details)
        @test near_asec_evidence["boundary"] == "±1"
        @test parse(Float64, near_asec_evidence["estimated_second_derivative_magnitude"]) > 1e17

        near_atanh_model = new_model()
        near_atanh = MOI.add_variable(near_atanh_model)
        MOI.add_constraint(
            near_atanh_model,
            MOI.ScalarNonlinearFunction(:atanh, Any[near_atanh]),
            MOI.LessThan(20.0),
        )
        near_atanh_report = NLPDiagnostics.analyze_expressions(
            near_atanh_model;
            point = NLPDiagnostics.EvaluationPoint([near_atanh], [1.0 - 1e-12]),
        )
        near_atanh_evidence = Dict(only(near_atanh_report.findings).evidence[end].details)
        @test parse(Float64, near_atanh_evidence["estimated_second_derivative_magnitude"]) > 1e23
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
        @test Dict(finding.evidence[1].details)["support_interval_origins"] ==
              "v$(x.value)=declared_variable_bounds:MathOptInterface.ScalarNonlinearFunction/MathOptInterface.EqualTo{Float64}#1"
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

        implied = new_model()
        implied_x = MOI.add_variable(implied)
        # log(x) ≥ 0 proves x ≥ 1 without a direct scalar variable bound.
        MOI.add_constraint(
            implied,
            MOI.ScalarNonlinearFunction(:log, Any[implied_x]),
            MOI.GreaterThan(0.0),
        )
        MOI.set(implied, MOI.VariablePrimalStart(), implied_x, 0.5)
        implied_report = NLPDiagnostics.analyze_initialization(implied)
        implied_violation = only(findings(
            implied_report,
            :initialization_violates_variable_bounds,
        ))
        @test implied_violation.basis == NLPDiagnostics.MathematicalProof
        @test occursin(
            "statically implied variable intervals",
            implied_violation.observation,
        )
        @test occursin(
            "bounds=[1.0, Inf]",
            Dict(implied_violation.evidence[2].details)["v$(implied_x.value)"],
        )
        @test occursin(
            "monotone_unary_inversion:MathOptInterface.ScalarNonlinearFunction/MathOptInterface.GreaterThan{Float64}#1",
            Dict(implied_violation.evidence[2].details)["v$(implied_x.value)"],
        )
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
        summary = NLPDiagnostics.solver_iteration_summary(records)
        @test summary.record_count == 2
        @test summary.formats == [:ipopt]
        @test summary.first_primal_infeasibility == 1.0
        @test summary.final_primal_infeasibility == 1.0e-2
        @test summary.minimum_dual_infeasibility == 3.0e-2
        @test summary.annotated_row_count == 1
        @test summary.segment_count == 1
        @test isnothing(NLPDiagnostics.solver_iteration_summary(
            NLPDiagnostics.SolverIterationRecord[],
        ))
        appended_records = [
            records[1], records[2],
            NLPDiagnostics.SolverIterationRecord(
                :ipopt, 10, 0, :regular, 3.0, 4.0, 5.0, nothing, 0.0, "appended",
            ),
        ]
        segments = NLPDiagnostics.solver_iteration_segments(appended_records)
        @test length(segments) == 2
        @test segments[2].start_line == 10
        @test segments[2].first_iteration == 0

        madnlp_log = """
        iter    objective    inf_pr   inf_du inf_compl lg(mu) lg(rg) alpha_pr ir ls
           0  1.0e+00 1.0e+00 2.0e+00 3.0e+00 -1.0 0.0 0.0 0 0
           1  2.0e+00 2.0e+01 3.0e+01 4.0e+00 -2.0 0.0 1.0 0 1
        """
        @test only(NLPDiagnostics.solver_iteration_records(madnlp_log)[2:2]).complementarity == 4.0
        report = NLPDiagnostics.analyze_solver_iterations("Ipopt", ipopt_log; residual_tolerance = 1e-3)
        @test length(findings(report, :solver_iteration_large_final_residual)) == 1
        @test report.metadata[:minimum_logged_primal_infeasibility] == "0.01"
        @test report.metadata[:annotated_iteration_row_count] == "1"
        @test report.metadata[:iteration_segment_count] == "1"
        appended_log = ipopt_log * "\n" *
            "   0  3.0e+00 4.0e+00 5.0e+00  -1.0 0.0e+00    -  0.0e+00 0.0e+00   0\n"
        appended_report = NLPDiagnostics.analyze_solver_iterations(
            "Ipopt",
            appended_log;
            residual_tolerance = 1e-3,
        )
        @test appended_report.metadata[:iteration_segment_count] == "2"
        @test isempty(findings(appended_report, :solver_iteration_residual_regression))

        model = new_model()
        x = MOI.add_variable(model)
        MOI.set(model, MOI.ObjectiveSense(), MOI.MIN_SENSE)
        MOI.set(model, MOI.ObjectiveFunction{MOI.VariableIndex}(), x)
        records = NLPDiagnostics.solver_iteration_records(ipopt_log)
        bindings = NLPDiagnostics.bind_iteration_points(
            records,
            Dict(1 => NLPDiagnostics.EvaluationPoint([x], [1.0]; label = "ipopt-1")),
        )
        @test length(bindings) == 1
        point_report = NLPDiagnostics.analyze_iteration_points(
            model,
            bindings;
            objective_agreement_factor = 1.5,
        )
        @test point_report.metadata[:iteration_1_log_line] == "3"
        @test point_report.metadata[:iteration_1_point_label] == "ipopt-1"
        @test length(
            findings(point_report, :solver_iteration_primal_residual_mismatch),
        ) == 1
        @test point_report.metadata[:iteration_1_logged_objective] == "2.0"
        @test point_report.metadata[:iteration_1_recomputed_objective] == "1.0"
        @test length(
            findings(point_report, :solver_iteration_objective_mismatch),
        ) == 1

        cone_model = new_model()
        t, z = MOI.add_variables(cone_model, 2)
        MOI.add_constraint(cone_model, MOI.VectorOfVariables([t, z]), MOI.SecondOrderCone(2))
        cone_binding = NLPDiagnostics.bind_iteration_points(
            records,
            Dict(1 => NLPDiagnostics.EvaluationPoint([t, z], [0.0, 1.0]; label = "cone-1")),
        )
        cone_report = NLPDiagnostics.analyze_iteration_points(cone_model, cone_binding)
        @test cone_report.metadata[:iteration_1_recomputed_scalar_violation] == "0.0"
        @test cone_report.metadata[:iteration_1_recomputed_coupled_violation] == "1.0"
        @test cone_report.metadata[:iteration_1_recomputed_total_violation] == "1.0"

        trend_model = new_model()
        q = MOI.add_variable(trend_model)
        MOI.add_constraint(trend_model, q, MOI.EqualTo(0.0))
        MOI.set(trend_model, MOI.ObjectiveSense(), MOI.MAX_SENSE)
        MOI.set(
            trend_model,
            MOI.ObjectiveFunction{MOI.ScalarAffineFunction{Float64}}(),
            MOI.ScalarAffineFunction([MOI.ScalarAffineTerm(-1.0, q)], 0.0),
        )
        trend_bindings = NLPDiagnostics.bind_iteration_points(
            records,
            Dict(
                0 => NLPDiagnostics.EvaluationPoint([q], [0.0]; label = "trend-0"),
                1 => NLPDiagnostics.EvaluationPoint([q], [10.0]; label = "trend-1"),
            ),
        )
        trend_report = NLPDiagnostics.analyze_iteration_points(trend_model, trend_bindings)
        @test length(
            findings(trend_report, :solver_iteration_trace_feasibility_disagreement),
        ) == 1
        @test length(
            findings(trend_report, :solver_iteration_trace_objective_disagreement),
        ) == 1
    end

    @testset "profile includes structural-stage timings" begin
        model = new_model()
        x = MOI.add_variable(model)
        case = NLPDiagnostics.ProfileCase(
            "structural-timing",
            NLPDiagnostics.EvaluationPoint([x], [0.0]),
        )
        result = NLPDiagnostics.profile_case(model, case)
        @test all(
            stage -> haskey(result.stage_seconds, stage),
            (:structural_graph, :structural_matching, :structural_dm),
        )
    end

    @testset "variable-domain intersections preserve type and infeasibility" begin
        typed = MOIU.Model{BigFloat}()
        x = MOI.add_variable(typed)
        MOI.add_constraint(typed, x, MOI.Interval(big"1.0", big"2.0"))
        domain = only(NLPDiagnostics.variable_domains(typed))
        @test domain.lower isa BigFloat
        @test domain.upper isa BigFloat
        unbounded = new_model()
        MOI.add_variable(unbounded)
        @test isnothing(only(NLPDiagnostics.variable_domains(unbounded)).lower)

        invalid_variable = MOI.VariableIndex(1)
        invalid_snapshot = NLPDiagnostics.ModelSnapshot(
            [NLPDiagnostics.VariableRecord(invalid_variable, nothing)],
            [NLPDiagnostics.ConstraintRecord(
                MOI.ConstraintIndex{MOI.VariableIndex,MOI.GreaterThan{Float64}}(1),
                invalid_variable,
                MOI.GreaterThan(NaN),
                nothing,
            )],
            nothing,
            nothing,
            String[],
        )
        @test only(NLPDiagnostics.variable_roles(invalid_snapshot)) ==
              NLPDiagnostics.InvalidVariableDomain
        invalid_report = NLPDiagnostics.analyze_static(invalid_snapshot)
        @test length(findings(invalid_report, :nan_variable_bound)) == 1

        semi_snapshot = NLPDiagnostics.ModelSnapshot(
            [NLPDiagnostics.VariableRecord(invalid_variable, nothing)],
            [NLPDiagnostics.ConstraintRecord(
                MOI.ConstraintIndex{MOI.VariableIndex,MOI.Semicontinuous{Float64}}(2),
                invalid_variable,
                MOI.Semicontinuous(1.0, 2.0),
                nothing,
            )],
            nothing,
            nothing,
            String[],
        )
        semi_report = NLPDiagnostics.analyze_static(semi_snapshot)
        @test length(findings(semi_report, :disjunctive_variable_domain)) == 1

        binary_snapshot = NLPDiagnostics.ModelSnapshot(
            [NLPDiagnostics.VariableRecord(invalid_variable, nothing)],
            [NLPDiagnostics.ConstraintRecord(
                MOI.ConstraintIndex{MOI.VariableIndex,MOI.ZeroOne}(3),
                invalid_variable,
                MOI.ZeroOne(),
                nothing,
            )],
            nothing,
            nothing,
            String[],
        )
        @test only(NLPDiagnostics.variable_roles(binary_snapshot)) ==
              NLPDiagnostics.DiscreteVariable
        binary_report = NLPDiagnostics.analyze_static(binary_snapshot)
        @test length(findings(binary_report, :discrete_variable_domain)) == 1

        binary_infeasible_snapshot = NLPDiagnostics.ModelSnapshot(
            [NLPDiagnostics.VariableRecord(invalid_variable, nothing)],
            [
                NLPDiagnostics.ConstraintRecord(
                    MOI.ConstraintIndex{MOI.VariableIndex,MOI.ZeroOne}(4),
                    invalid_variable,
                    MOI.ZeroOne(),
                    nothing,
                ),
                NLPDiagnostics.ConstraintRecord(
                    MOI.ConstraintIndex{MOI.VariableIndex,MOI.EqualTo{Float64}}(5),
                    invalid_variable,
                    MOI.EqualTo(2.0),
                    nothing,
                ),
            ],
            nothing,
            nothing,
            String[],
        )
        @test only(NLPDiagnostics.variable_roles(binary_infeasible_snapshot)) ==
              NLPDiagnostics.InfeasibleVariableDomain
        @test length(
            findings(
                NLPDiagnostics.analyze_static(binary_infeasible_snapshot),
                :inconsistent_variable_bounds,
            ),
        ) == 1

        binary_fractional_snapshot = NLPDiagnostics.ModelSnapshot(
            [NLPDiagnostics.VariableRecord(invalid_variable, nothing)],
            [
                NLPDiagnostics.ConstraintRecord(
                    MOI.ConstraintIndex{MOI.VariableIndex,MOI.ZeroOne}(6),
                    invalid_variable,
                    MOI.ZeroOne(),
                    nothing,
                ),
                NLPDiagnostics.ConstraintRecord(
                    MOI.ConstraintIndex{MOI.VariableIndex,MOI.EqualTo{Float64}}(7),
                    invalid_variable,
                    MOI.EqualTo(0.5),
                    nothing,
                ),
            ],
            nothing,
            nothing,
            String[],
        )
        @test length(
            findings(
                NLPDiagnostics.analyze_static(binary_fractional_snapshot),
                :nonintegral_discrete_fixed_value,
            ),
        ) == 1

        binary_empty_snapshot = NLPDiagnostics.ModelSnapshot(
            [NLPDiagnostics.VariableRecord(invalid_variable, nothing)],
            [
                NLPDiagnostics.ConstraintRecord(
                    MOI.ConstraintIndex{MOI.VariableIndex,MOI.ZeroOne}(8),
                    invalid_variable,
                    MOI.ZeroOne(),
                    nothing,
                ),
                NLPDiagnostics.ConstraintRecord(
                    MOI.ConstraintIndex{MOI.VariableIndex,MOI.Interval{Float64}}(9),
                    invalid_variable,
                    MOI.Interval(0.1, 0.9),
                    nothing,
                ),
            ],
            nothing,
            nothing,
            String[],
        )
        @test length(
            findings(
                NLPDiagnostics.analyze_static(binary_empty_snapshot),
                :empty_discrete_variable_domain,
            ),
        ) == 1
    end
end
