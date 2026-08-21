using Test

import MathOptInterface as MOI
import NLPDiagnostics

@testset "typed evaluation-point provenance" begin
    model = MOI.Utilities.UniversalFallback(MOI.Utilities.Model{Float64}())
    variable = MOI.add_variable(model)
    default_point = NLPDiagnostics.evaluation_point(model, [1.0]; label = "user point")
    @test default_point.provenance.kind == NLPDiagnostics.UserPoint
    @test default_point.provenance.source == "user"
    @test default_point.provenance.complete

    synthetic_provenance = NLPDiagnostics.EvaluationPointProvenance(
        NLPDiagnostics.SyntheticSmokePoint;
        source = "calibration smoke",
        complete = true,
        metadata = Dict("policy" => "constant zero"),
    )
    synthetic = NLPDiagnostics.evaluation_point(
        model,
        [0.0];
        label = "synthetic",
        provenance = synthetic_provenance,
    )
    @test synthetic.provenance == synthetic_provenance
    @test synthetic != default_point
    nonfinite = NLPDiagnostics.evaluation_point(
        model,
        [NaN];
        label = "non-finite diagnostic point",
    )
    @test nonfinite == nonfinite
    @test isequal(nonfinite, nonfinite)
    @test nonfinite == NLPDiagnostics.evaluation_point(
        model,
        [NaN];
        label = "non-finite diagnostic point",
    )
    @test hash(synthetic) == hash(NLPDiagnostics.evaluation_point(
        model,
        [0.0];
        label = "synthetic",
        provenance = NLPDiagnostics.EvaluationPointProvenance(
            NLPDiagnostics.SyntheticSmokePoint;
            source = "calibration smoke",
            metadata = Dict("policy" => "constant zero"),
        ),
    ))
    data = NLPDiagnostics._evaluation_point_data(synthetic)
    @test data["fingerprint"] == NLPDiagnostics.evaluation_point_fingerprint(synthetic)
    @test data["provenance"]["kind"] == "SyntheticSmokePoint"
    @test data["provenance"]["source"] == "calibration smoke"
    @test data["provenance"]["metadata"]["policy"] == "constant zero"

    MOI.set(model, MOI.VariablePrimalStart(), variable, 2.0)
    initialization = NLPDiagnostics.initialization_point(model)
    @test !isnothing(initialization)
    @test initialization.provenance.kind == NLPDiagnostics.InitializationPoint
    @test initialization.provenance.source == "MOI.VariablePrimalStart"
    @test initialization.provenance.complete

    evaluation = NLPDiagnostics.evaluate_numerical(model, synthetic)
    report = NLPDiagnostics.analyze_numerical(model, evaluation)
    @test report.metadata[:evaluation_point_provenance_kind] ==
          "SyntheticSmokePoint"
    @test report.metadata[:evaluation_point_provenance_source] ==
          "calibration smoke"
    @test report.metadata[:evaluation_point_provenance_complete] == "true"
    point_evidence = NLPDiagnostics._point_evidence(synthetic)
    @test ("provenance_kind" => "SyntheticSmokePoint") in
          point_evidence.details

    guarded_report = NLPDiagnostics.DiagnosticReport([
        NLPDiagnostics.Finding(
            :synthetic_physical_candidate;
            severity = NLPDiagnostics.SeverityWarning,
            domain = NLPDiagnostics.PhysicalIssue,
            basis = NLPDiagnostics.PhysicalExpectation,
            confidence = NLPDiagnostics.ConfidenceHigh,
            observation = "A point-local physical mode appears present.",
            why_it_matters = "This is a provenance-guard regression fixture.",
            evidence = [point_evidence],
        ),
    ], Dict{Symbol,String}())
    NLPDiagnostics._apply_point_provenance_guard!(guarded_report, synthetic)
    guarded = only(NLPDiagnostics.findings(
        guarded_report;
        code = :synthetic_physical_candidate,
    ))
    @test guarded.confidence == NLPDiagnostics.ConfidenceLow
    @test guarded.basis == NLPDiagnostics.HeuristicInterpretation
    @test length(NLPDiagnostics.findings(
        guarded_report;
        code = :physical_interpretation_limited_by_point_provenance,
    )) == 1
    @test guarded_report.metadata[
        :evaluation_point_physical_confidence_guarded_count
    ] == "1"
    NLPDiagnostics._apply_point_provenance_guard!(guarded_report, synthetic)
    @test guarded_report.metadata[
        :evaluation_point_physical_confidence_guarded_count
    ] == "1"
    @test count(
        finding -> finding.code ==
                   :physical_interpretation_limited_by_point_provenance,
        guarded_report.findings,
    ) == 1

    synthetic_case = NLPDiagnostics.ProfileCase(
        "synthetic fixture",
        default_point;
        tags = [:synthetic],
    )
    @test synthetic_case.point.provenance.kind ==
          NLPDiagnostics.SyntheticSmokePoint
    @test synthetic_case.point.provenance.source == "ProfileCase :synthetic tag"
    @test synthetic_case.point.provenance.metadata["profile_case"] ==
          "synthetic fixture"

    completed = NLPDiagnostics.evaluation_point(
        model,
        [0.0];
        label = "completed initialization",
        provenance = NLPDiagnostics.EvaluationPointProvenance(
            NLPDiagnostics.CompletedInitializationPoint;
            source = "test completion policy",
            metadata = Dict("filled_coordinates" => "1"),
        ),
    )
    completed_report = NLPDiagnostics.DiagnosticReport([
        NLPDiagnostics.Finding(
            :completed_physical_candidate;
            severity = NLPDiagnostics.SeverityWarning,
            domain = NLPDiagnostics.PhysicalIssue,
            basis = NLPDiagnostics.PhysicalExpectation,
            confidence = NLPDiagnostics.ConfidenceHigh,
            observation = "A point-local physical mode appears present.",
            why_it_matters = "This is a completed-point guard fixture.",
            evidence = [NLPDiagnostics._point_evidence(completed)],
        ),
    ], Dict{Symbol,String}())
    NLPDiagnostics._apply_point_provenance_guard!(completed_report, completed)
    completed_finding = only(NLPDiagnostics.findings(
        completed_report;
        code = :completed_physical_candidate,
    ))
    @test completed_finding.confidence == NLPDiagnostics.ConfidenceLow
    @test completed_finding.basis == NLPDiagnostics.HeuristicInterpretation

    solver_point = NLPDiagnostics.evaluation_point(
        model,
        [1.0];
        label = "solver iterate",
        provenance = NLPDiagnostics.EvaluationPointProvenance(
            NLPDiagnostics.SolverIteratePoint;
            source = "Ipopt callback",
        ),
    )
    incomplete_solver_point = NLPDiagnostics.evaluation_point(
        model,
        [1.0];
        label = "incomplete solver iterate",
        provenance = NLPDiagnostics.EvaluationPointProvenance(
            NLPDiagnostics.SolverIteratePoint;
            source = "partial callback",
            complete = false,
        ),
    )
    selection = NLPDiagnostics.select_trusted_evaluation_points([
        default_point, synthetic, solver_point, incomplete_solver_point,
    ])
    @test length(selection.selected) == 1
    @test length(selection.rejected) == 3
    @test selection.metadata["selected_count"] == "1"
    @test selection.metadata["rejected_count"] == "3"
    serialized_selection = NLPDiagnostics.trusted_point_selection_data(selection)
    @test serialized_selection["selected"][1]["fingerprint"] ==
          NLPDiagnostics.evaluation_point_fingerprint(solver_point)
    @test serialized_selection["rejected"][1]["reason"] isa String

    solver_result = NLPDiagnostics.evaluation_point(
        model,
        [1.0];
        label = "solver result",
        provenance = NLPDiagnostics.EvaluationPointProvenance(
            NLPDiagnostics.SolverResultPoint;
            source = "test solver result",
        ),
    )
    serialized_solver_case = NLPDiagnostics._profile_case_data(
        NLPDiagnostics.ProfileCase("solver result fixture", solver_result),
    )
    @test serialized_solver_case["point_trust"]["metadata"]["selected_count"] == "1"
    @test serialized_solver_case["point_trust"]["selected"][1]["fingerprint"] ==
          NLPDiagnostics.evaluation_point_fingerprint(solver_result)

    @test_throws ArgumentError NLPDiagnostics.EvaluationPointProvenance(
        NLPDiagnostics.UserPoint;
        source = " ",
    )
end
