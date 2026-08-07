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
    @test ("provenance_kind" => NLPDiagnostics.SyntheticSmokePoint) in
          point_evidence.details

    @test_throws ArgumentError NLPDiagnostics.EvaluationPointProvenance(
        NLPDiagnostics.UserPoint;
        source = " ",
    )
end
