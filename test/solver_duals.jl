@testset "Physical scalar-side complementarity contracts" begin
    variable = MOI.VariableIndex(1)
    point = NLPDiagnostics.EvaluationPoint(
        [variable],
        [0.0];
        label="synthetic-dual-endpoint",
        provenance=NLPDiagnostics.EvaluationPointProvenance(
            NLPDiagnostics.SolverResultPoint;
            source="unit-test solver result",
            complete=true,
        ),
    )
    source = NLPDiagnostics.EntityRef(:constraint, 1)
    side = NLPDiagnostics.SolverConstraintSideDual(
        1, source, :lower, 2.0, 0.0, 0.0, 0.0,
        :moi_constraint_dual,
    )
    snapshot = NLPDiagnostics.SolverDualSnapshot(
        true, nothing, point, 1, "FEASIBLE_POINT", 1.0, [-2.0], [side],
        true, 0.0, String[],
    )
    scaling = NLPDiagnostics.DiagonalScalingMap(
        "side-scale";
        variable_keys=["x"],
        variable_scales=[3.0],
        constraint_keys=["g"],
        constraint_scales=[4.0],
        constraint_bounds=[(0.0, nothing)],
    )
    report = NLPDiagnostics.physical_complementarity_report(
        snapshot,
        scaling;
        default_dual_absolute_tolerance=1.0e-12,
        default_complementarity_absolute_tolerance=1.0e-12,
    )
    @test report["available"]
    @test report["acceptance_passed"]
    @test report["sides"]["g/lower"]["physical_multiplier"] == 0.5
    @test report["sides"]["g/lower"]["physical_slack"] == 0.0

    rotated_map = NLPDiagnostics.SemanticBlockScalingMap(
        "rotated-box";
        variable_blocks=[NLPDiagnostics.SemanticLinearBlock(
            ["x"], [1], ones(1, 1),
        )],
        constraint_blocks=[NLPDiagnostics.SemanticConstraintBlock(
            ["g"], [1], -ones(1, 1);
            set=NLPDiagnostics.ScalarBoundsSetContract([(0.0, nothing)]),
        )],
    )
    unavailable = NLPDiagnostics.physical_complementarity_report(
        snapshot,
        rotated_map;
        default_dual_absolute_tolerance=1.0e-12,
        default_complementarity_absolute_tolerance=1.0e-12,
    )
    @test !unavailable["available"]
    @test occursin("unavailable", unavailable["reason"])

    iteration = NLPDiagnostics.SolverIterationRecord(
        :synthetic,
        1,
        0,
        :regular,
        0.0,
        1.0,
        2.0,
        3.0,
        nothing,
        "synthetic trace row",
    )
    trace = NLPDiagnostics.iteration_trace([iteration])
    solver_profile = NLPDiagnostics.SolverProfileResult(
        nothing,
        nothing,
        nothing,
        NLPDiagnostics.DiagnosticReport(),
        1,
        nothing,
    )
    run = NLPDiagnostics.SolverTraceProfileRun(trace, solver_profile)
    combined = NLPDiagnostics.solver_trace_physical_endpoint_data(
        run,
        Dict{String,Any}(
            "report_version" => "synthetic-physical-endpoint-v1",
            "acceptance_passed" => true,
        ),
    )
    @test combined["available"]
    @test combined["acceptance_passed"]
    @test combined["last_captured_solver_record"]["iteration"] == 0
    @test combined["solver_trace_profile"]["iteration_trace"][
        "record_count"
    ] == 1
    @test !combined["evidence_relationship"][
        "numeric_residual_comparison_performed"
    ]
end

if Base.find_package("Ipopt") !== nothing
    import Ipopt

    @testset "Ipopt endpoint dual and physical KKT contracts" begin
        model = JuMP.Model(Ipopt.Optimizer)
        JuMP.set_silent(model)
        JuMP.set_optimizer_attribute(model, "tol", 1.0e-10)
        JuMP.@variable(model, x >= 0.0)
        JuMP.@variable(model, y <= 3.0)
        JuMP.@variable(model, z)
        JuMP.@variable(model, w)
        lower = JuMP.@constraint(model, z >= 2.5)
        upper = JuMP.@constraint(model, w <= 1.5)
        JuMP.@objective(
            model,
            Min,
            (x + 1.0)^2 + (y - 4.0)^2 +
            (z - 2.0)^2 + (w - 2.0)^2,
        )
        JuMP.optimize!(model)
        @test JuMP.termination_status(model) in (
            MOI.LOCALLY_SOLVED, MOI.OPTIMAL, MOI.ALMOST_LOCALLY_SOLVED,
        )

        point = NLPDiagnostics.solver_result_point(model)
        @test !isnothing(point)
        evaluation = NLPDiagnostics.evaluate_numerical(model, point)
        snapshot = NLPDiagnostics.solver_dual_snapshot(model, evaluation)
        @test snapshot.available
        @test snapshot.side_decomposition_complete
        @test length(snapshot.row_multipliers) ==
            length(evaluation.constraint_sources)
        @test snapshot.maximum_point_difference == 0.0
        @test snapshot.objective_weight == 1.0

        lower_sides = filter(side -> side.side == :lower, snapshot.sides)
        upper_sides = filter(side -> side.side == :upper, snapshot.sides)
        @test length(lower_sides) == 2
        @test length(upper_sides) == 2
        @test all(side -> side.multiplier >= -1.0e-7, snapshot.sides)
        @test all(
            side -> side.side == :equality ||
                abs(side.multiplier * something(side.slack, Inf)) <= 1.0e-6,
            snapshot.sides,
        )
        model_complementarity =
            NLPDiagnostics.solver_complementarity_report(
                snapshot;
                dual_absolute_tolerance=1.0e-6,
                complementarity_absolute_tolerance=1.0e-6,
            )
        @test model_complementarity["available"]
        @test model_complementarity["acceptance_passed"]

        backend = JuMP.backend(model)
        raw_bounds = NLPDiagnostics._evaluated_row_bounds(backend, evaluation)
        bounds = [NLPDiagnostics.ScalarConstraintBounds(item...)
            for item in raw_bounds]
        scaling = NLPDiagnostics.DiagonalScalingMap(
            "test-physical";
            variable_keys=["x", "y", "z", "w"],
            variable_scales=[10.0, 20.0, 30.0, 40.0],
            constraint_keys=["constraint-$row" for row in eachindex(raw_bounds)],
            constraint_scales=[2.0 + row for row in eachindex(raw_bounds)],
            objective_scale=5.0,
            constraint_bounds=bounds,
        )
        physical_complementarity =
            NLPDiagnostics.physical_complementarity_report(
                snapshot,
                scaling;
                default_dual_absolute_tolerance=1.0e-6,
                default_complementarity_absolute_tolerance=1.0e-6,
            )
        @test physical_complementarity["available"]
        @test physical_complementarity["acceptance_passed"]
        @test all(
            record -> record["complementarity_residual"] <= 1.0e-6,
            values(physical_complementarity["sides"]),
        )

        kkt = NLPDiagnostics.physical_kkt_acceptance_report(
            evaluation,
            scaling,
            snapshot;
            feasibility_default_absolute_tolerance=1.0e-6,
            stationarity_default_absolute_tolerance=1.0e-6,
            dual_default_absolute_tolerance=1.0e-6,
            complementarity_default_absolute_tolerance=1.0e-6,
        )
        @test kkt["report_version"] == "physical-kkt-acceptance-v2"
        @test kkt["acceptance_passed"]

        displaced = NLPDiagnostics.evaluate_numerical(
            model,
            point.values .+ 1.0e-3,
        )
        mismatched = NLPDiagnostics.solver_dual_snapshot(model, displaced)
        @test !mismatched.available
        @test occursin("do not match", mismatched.reason)
        @test isempty(mismatched.row_multipliers)

        data = NLPDiagnostics.solver_dual_snapshot_data(snapshot)
        @test data["schema_version"] == "solver-dual-snapshot-v1"
        @test data["qualification"]["moi_to_lagrangian_sign"] ==
            "row_multiplier = -MOI.ConstraintDual"
        @test !isempty(data["sides"])

        # Max-sense uses objective weight -1 while the MOI-to-row-dual sign is
        # unchanged. This guards a subtle but important convention boundary.
        max_model = JuMP.Model(Ipopt.Optimizer)
        JuMP.set_silent(max_model)
        JuMP.@variable(max_model, q <= 1.0)
        JuMP.@objective(max_model, Max, -(q - 2.0)^2)
        JuMP.optimize!(max_model)
        max_point = NLPDiagnostics.solver_result_point(max_model)
        max_evaluation = NLPDiagnostics.evaluate_numerical(max_model, max_point)
        max_snapshot = NLPDiagnostics.solver_dual_snapshot(
            max_model, max_evaluation,
        )
        @test max_snapshot.available
        @test max_snapshot.objective_weight == -1.0
        @test only(max_snapshot.sides).side == :upper
        @test only(max_snapshot.sides).multiplier >= -1.0e-7
    end
end
