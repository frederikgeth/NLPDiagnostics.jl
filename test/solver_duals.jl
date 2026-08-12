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
    family_summary = Dict{String,Any}(
        "state" => Dict{String,Any}(
            "passed_count" => 1,
            "failed_count" => 0,
            "maxima" => Dict("residual" => 1.0e-9),
        ),
    )
    attribution = Dict{String,Any}(
        section => Dict{String,Any}("families" => deepcopy(family_summary))
        for section in (
            "primal_feasibility", "stationarity", "complementarity",
        )
    )
    reference_artifact = deepcopy(combined)
    candidate_artifact = deepcopy(combined)
    reference_artifact["physical_endpoint"]["semantic_attribution"] =
        deepcopy(attribution)
    candidate_artifact["physical_endpoint"]["semantic_attribution"] =
        deepcopy(attribution)
    reference_artifact["solver_trace_profile"]["solver_profile"][
        "postmortem"
    ] = Dict("termination" => "optimal")
    candidate_artifact["solver_trace_profile"]["solver_profile"][
        "postmortem"
    ] = Dict("termination" => "optimal")
    matched = NLPDiagnostics.scaling_solver_experiment_comparison(
        reference_artifact,
        candidate_artifact;
        intervention=:baseline_repeat,
        intervention_report=NLPDiagnostics.scaling_intervention_classification(
            scaling, scaling,
        ),
        covariance_report=Dict("equivalence_gate_passed" => true),
        geometry_report=Dict("semantic_interpretation_qualified" => true),
        hypothesis="a baseline repeat should retain the same evidence contract",
    )
    @test matched["available"]
    @test matched["comparison_qualified"]
    @test matched["gates"]["native_metric_semantics_compatible"]
    @test matched["native_work"]["comparisons"]["record_count"][
        "candidate_to_reference_ratio"
    ] == 1.0
    @test matched["physical_endpoint_families"][
        "numeric_comparison_allowed"
    ]
    withheld = NLPDiagnostics.scaling_solver_experiment_comparison(
        reference_artifact,
        candidate_artifact;
        intervention=:magnitude_only,
        intervention_report=Dict(
            "available" => true,
            "classification" => "magnitude_only",
        ),
        covariance_report=Dict("equivalence_gate_passed" => false),
        geometry_report=Dict("semantic_interpretation_qualified" => true),
    )
    @test !withheld["comparison_qualified"]
    @test !withheld["physical_endpoint_families"][
        "numeric_comparison_allowed"
    ]
    @test_throws ArgumentError NLPDiagnostics.scaling_solver_experiment_comparison(
        reference_artifact, candidate_artifact; intervention=:mystery,
    )
    endpoint_contract = Dict{String,Any}(
        "acceptance_passed" => true,
        "primal_feasibility" => Dict(
            "residuals" => Dict(
                "g" => Dict("absolute_tolerance" => 1.0e-3),
            ),
        ),
        "stationarity" => Dict(
            "stationarity" => Dict(
                "x" => Dict("absolute_tolerance" => 1.0e-4),
            ),
        ),
        "complementarity" => Dict(
            "sides" => Dict{String,Any}(),
        ),
    )
    covariance_metrics = Dict{String,Any}(
        metric => Dict("passed" => true) for metric in (
            "physical_point",
            "constraint_function_values",
            "constraint_sets",
            "physical_jacobian",
        )
    )
    covariance_metrics["constraint_residuals"] = Dict(
        "passed" => false,
        "maximum_absolute_difference" => 5.0e-4,
    )
    endpoint_equivalence =
        NLPDiagnostics.physical_endpoint_equivalence_report(
            Dict("metrics" => covariance_metrics),
            endpoint_contract,
            deepcopy(endpoint_contract),
        )
    @test endpoint_equivalence["equivalence_gate_passed"]
    @test !endpoint_equivalence["qualification"][
        "constraint_residual_covariance_is_required"
    ]
    mismatched_contract = deepcopy(endpoint_contract)
    mismatched_contract["stationarity"]["stationarity"]["x"][
        "absolute_tolerance"
    ] = 2.0e-4
    rejected_endpoint_equivalence =
        NLPDiagnostics.physical_endpoint_equivalence_report(
            Dict("metrics" => covariance_metrics),
            endpoint_contract,
            mismatched_contract,
        )
    @test !rejected_endpoint_equivalence["equivalence_gate_passed"]
    @test !rejected_endpoint_equivalence["tolerance_contracts_agree"]
    magnitude_comparison =
        NLPDiagnostics.scaling_solver_experiment_comparison(
            reference_artifact,
            candidate_artifact;
            intervention=:magnitude_only,
            intervention_report=Dict(
                "available" => true,
                "classification" => "magnitude_only",
            ),
            covariance_report=Dict("equivalence_gate_passed" => true),
            geometry_report=Dict(
                "semantic_interpretation_qualified" => true,
            ),
        )
    campaign_runs = [
        Dict(
            "policy" => policy,
            "replicate" => replicate,
            "provenance_fingerprint" => "same-environment",
            "common_start_covariance_passed" => true,
            "artifact" => policy == "reference" ?
                deepcopy(reference_artifact) : deepcopy(candidate_artifact),
        ) for policy in ("reference", "candidate") for replicate in 1:2
    ]
    campaign_comparisons = [
        Dict(
            "candidate_policy" => "reference",
            "reference_replicate" => 1,
            "candidate_replicate" => 2,
            "comparison" => deepcopy(matched),
        ),
        [
            Dict(
                "candidate_policy" => "candidate",
                "reference_replicate" => replicate,
                "candidate_replicate" => replicate,
                "comparison" => deepcopy(magnitude_comparison),
            ) for replicate in 1:2
        ]...,
    ]
    campaign = NLPDiagnostics.scaling_solver_experiment_campaign_data(
        campaign_runs,
        campaign_comparisons;
        reference_policy="reference",
        minimum_repeats=2,
    )
    @test campaign["campaign_qualified"]
    native_start_runs = deepcopy(campaign_runs)
    for record in native_start_runs
        record["native_initialization_covariance_passed"] = true
    end
    native_start_campaign =
        NLPDiagnostics.scaling_solver_experiment_campaign_data(
            native_start_runs,
            campaign_comparisons;
            reference_policy="reference",
            minimum_repeats=2,
            require_native_initialization_covariance=true,
        )
    @test native_start_campaign["campaign_qualified"]
    @test native_start_campaign["gates"][
        "native_initialization_covariance_required"
    ]
    native_start_runs[end]["native_initialization_covariance_passed"] = false
    rejected_native_start =
        NLPDiagnostics.scaling_solver_experiment_campaign_data(
            native_start_runs,
            campaign_comparisons;
            reference_policy="reference",
            minimum_repeats=2,
            require_native_initialization_covariance=true,
        )
    @test !rejected_native_start["campaign_qualified"]
    @test !rejected_native_start["gates"][
        "all_native_initializations_covariant"
    ]
    @test campaign["gates"]["provenance_stable"]
    @test campaign["policies"]["candidate"]["termination_stable"]
    @test campaign["comparisons"]["candidate"]["comparison_count"] == 2
    broken_runs = deepcopy(campaign_runs)
    broken_runs[end]["provenance_fingerprint"] = "different-environment"
    broken_campaign = NLPDiagnostics.scaling_solver_experiment_campaign_data(
        broken_runs,
        campaign_comparisons;
        reference_policy="reference",
        minimum_repeats=2,
    )
    @test !broken_campaign["campaign_qualified"]
    @test !broken_campaign["gates"]["provenance_stable"]
    @test_throws ArgumentError NLPDiagnostics.scaling_solver_experiment_campaign_data(
        campaign_runs,
        campaign_comparisons;
        reference_policy="reference",
        minimum_repeats=1,
    )
    stratified = NLPDiagnostics.scaling_solver_experiment_stratified_campaign_data(
        [
            Dict("stratum" => "native", "campaign" => deepcopy(campaign)),
            Dict("stratum" => "nearby-seed-11", "campaign" => deepcopy(campaign)),
        ];
        minimum_strata=2,
        minimum_repeats=2,
    )
    @test stratified["campaign_qualified"]
    @test stratified["gates"]["policy_coverage_consistent"]
    @test stratified["policies"]["candidate"]["run_count"] == 4
    @test stratified["policies"]["candidate"]["record_count_range"][
        "sample_count"
    ] == 4
    @test stratified["policies"]["reference"]["record_count_range"]["minimum"] ==
        campaign["policies"]["reference"]["record_count_range"]["minimum"]
    duplicate_strata = NLPDiagnostics.scaling_solver_experiment_stratified_campaign_data(
        [
            Dict("stratum" => "native", "campaign" => deepcopy(campaign)),
            Dict("stratum" => "native", "campaign" => deepcopy(campaign)),
        ],
    )
    @test !duplicate_strata["campaign_qualified"]
    @test !duplicate_strata["gates"]["stratum_ids_unique"]
    changed_policy = deepcopy(campaign)
    changed_policy["policies"]["extra"] =
        deepcopy(changed_policy["policies"]["candidate"])
    inconsistent = NLPDiagnostics.scaling_solver_experiment_stratified_campaign_data(
        [
            Dict("stratum" => "native", "campaign" => deepcopy(campaign)),
            Dict("stratum" => "nearby", "campaign" => changed_policy),
        ],
    )
    @test !inconsistent["campaign_qualified"]
    @test !inconsistent["gates"]["policy_coverage_consistent"]
    @test_throws ArgumentError NLPDiagnostics.scaling_solver_experiment_stratified_campaign_data(
        [Dict("stratum" => "native", "campaign" => campaign)];
        minimum_strata=1,
    )
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
