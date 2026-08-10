using Test

import MathOptInterface as MOI
import NLPDiagnostics

mutable struct CrosscheckJacVecEvaluator <: MOI.AbstractNLPEvaluator
    requested::Vector{Symbol}
end

MOI.features_available(::CrosscheckJacVecEvaluator) = [:Grad, :Jac, :JacVec, :Hess, :HessVec]
MOI.initialize(evaluator::CrosscheckJacVecEvaluator, requested::Vector{Symbol}) =
    (evaluator.requested = copy(requested); nothing)
MOI.eval_objective(::CrosscheckJacVecEvaluator, x) = x[1]^2
MOI.eval_objective_gradient(::CrosscheckJacVecEvaluator, gradient, x) =
    (gradient[1] = 2 * x[1]; nothing)
MOI.eval_constraint(::CrosscheckJacVecEvaluator, values, x) =
    (values[1] = x[1]; nothing)
MOI.jacobian_structure(::CrosscheckJacVecEvaluator) = [(1, 1)]
MOI.eval_constraint_jacobian(::CrosscheckJacVecEvaluator, values, x) =
    (values[1] = 1.0; nothing)
MOI.eval_constraint_jacobian_product(::CrosscheckJacVecEvaluator, values, x, direction) =
    (values[1] = direction[1]; nothing)
MOI.eval_constraint_jacobian_transpose_product(::CrosscheckJacVecEvaluator, values, x, direction) =
    (values[1] = direction[1]; nothing)
MOI.hessian_lagrangian_structure(::CrosscheckJacVecEvaluator) = [(1, 1)]
MOI.eval_hessian_lagrangian(::CrosscheckJacVecEvaluator, values, x, sigma, mu) =
    (values[1] = 2 * sigma; nothing)
MOI.eval_hessian_lagrangian_product(::CrosscheckJacVecEvaluator, values, x, direction, sigma, mu) =
    (values[1] = 2 * sigma * direction[1]; nothing)

@testset "fingerprints and directional Jacobian cross-check" begin
    model = MOI.Utilities.UniversalFallback(MOI.Utilities.Model{Float64}())
    x = MOI.add_variable(model)
    MOI.add_constraint(model, x, MOI.EqualTo(1.0))
    point = NLPDiagnostics.evaluation_point(model, [1.0]; label = "cross-check point")

    @test NLPDiagnostics.model_fingerprint(model) == NLPDiagnostics.model_fingerprint(model)
    @test NLPDiagnostics.evaluation_point_fingerprint(point) ==
          NLPDiagnostics.evaluation_point_fingerprint(point)
    evaluation = NLPDiagnostics.evaluate_numerical(model, point)
    source_fingerprint = NLPDiagnostics.evaluation_source_fingerprint(evaluation)
    @test length(source_fingerprint) == 64
    numerical_report = NLPDiagnostics.analyze_numerical(model, evaluation)
    @test numerical_report.metadata[:model_fingerprint] ==
          NLPDiagnostics.model_fingerprint(model)
    @test numerical_report.metadata[:evaluation_point_fingerprint] ==
          NLPDiagnostics.evaluation_point_fingerprint(point)
    @test numerical_report.metadata[:evaluation_source_fingerprint] == source_fingerprint

    consistent = NLPDiagnostics.analyze_jacobian_directional_crosscheck(
        model,
        evaluation;
        direction_count = 1,
    )
    @test length(NLPDiagnostics.findings(
        consistent;
        code = :jacobian_directional_crosscheck_consistent,
    )) == 1
    @test consistent.metadata[:constraint_directional_comparisons] == "1"
    @test consistent.metadata[:mismatch_count] == "0"

    mismatched = NLPDiagnostics.NumericalEvaluation{Float64}(
        evaluation.point,
        evaluation.objective_value,
        evaluation.objective_source,
        copy(evaluation.objective_gradient),
        copy(evaluation.constraint_values),
        copy(evaluation.constraint_sources),
        [NLPDiagnostics.JacobianEntry(1, 1, 2.0)],
        copy(evaluation.jacobian_row_methods),
        copy(evaluation.capabilities),
        copy(evaluation.failures),
        copy(evaluation.call_statistics),
        evaluation.objective_gradient_method,
    )
    mismatch_report = NLPDiagnostics.analyze_jacobian_directional_crosscheck(
        model,
        mismatched;
        direction_count = 1,
    )
    @test length(NLPDiagnostics.findings(
        mismatch_report;
        code = :jacobian_directional_crosscheck_mismatch,
    )) == 1
    @test mismatch_report.metadata[:mismatch_count] == "1"

    objective_model = MOI.Utilities.UniversalFallback(MOI.Utilities.Model{Float64}())
    objective_x = MOI.add_variable(objective_model)
    MOI.set(objective_model, MOI.ObjectiveSense(), MOI.MIN_SENSE)
    MOI.set(
        objective_model,
        MOI.ObjectiveFunction{MOI.ScalarAffineFunction{Float64}}(),
        MOI.ScalarAffineFunction(
            [MOI.ScalarAffineTerm(3.0, objective_x)],
            2.0,
        ),
    )
    objective_point = NLPDiagnostics.evaluation_point(objective_model, [1.0])
    objective_evaluation = NLPDiagnostics.evaluate_numerical(objective_model, objective_point)
    objective_report = NLPDiagnostics.analyze_objective_gradient_directional_crosscheck(
        objective_model,
        objective_evaluation;
        direction_count = 1,
    )
    @test length(NLPDiagnostics.findings(
        objective_report;
        code = :objective_gradient_directional_crosscheck_consistent,
    )) == 1
    @test objective_report.metadata[:objective_directional_comparisons] == "1"
    objective_sweep = NLPDiagnostics.analyze_derivative_crosscheck_scale_sweep(
        objective_model,
        objective_evaluation;
        relative_steps = [1.0e-4, 1.0e-6],
        check_jacobian = false,
        check_objective_gradient = true,
        direction_count = 1,
    )
    @test length(NLPDiagnostics.findings(
        objective_sweep;
        code = :derivative_crosscheck_scale_sweep_consistent,
    )) == 1
    @test objective_sweep.metadata[:scale_count] == "2"
    @test objective_sweep.metadata[:mismatch_count] == "0"

    jacvec_model = MOI.Utilities.UniversalFallback(MOI.Utilities.Model{Float64}())
    jacvec_variable = MOI.add_variable(jacvec_model)
    MOI.set(jacvec_model, MOI.ObjectiveSense(), MOI.MIN_SENSE)
    MOI.set(
        jacvec_model,
        MOI.NLPBlock(),
        MOI.NLPBlockData(
            [MOI.NLPBoundsPair(0.0, 0.0)],
            CrosscheckJacVecEvaluator(Symbol[]),
            true,
        ),
    )
    jacvec_capability = only(filter(
        capability -> capability.source == :nlp_block,
        NLPDiagnostics.evaluator_capabilities(jacvec_model),
    ))
    @test :JacVec in jacvec_capability.available_features
    @test :JacVec in jacvec_capability.requested_features
    jacvec_evaluation = NLPDiagnostics.evaluate_numerical(
        jacvec_model,
        NLPDiagnostics.evaluation_point(jacvec_model, [1.0]),
    )
    assembled_operator = NLPDiagnostics.jacobian_linear_operator(jacvec_evaluation)
    @test assembled_operator.available
    @test assembled_operator.source == :assembled_sparse
    @test NLPDiagnostics.jacobian_product(assembled_operator, [2.0]) == [2.0]
    @test NLPDiagnostics.jacobian_transpose_product(assembled_operator, [3.0]) == [3.0]
    native_operator = NLPDiagnostics.jacobian_linear_operator(
        jacvec_model, jacvec_evaluation,
    )
    @test native_operator.available
    @test native_operator.source == :hybrid_moi_jacvec
    @test isnothing(native_operator.native_unavailable_reason)
    @test native_operator.nlp_rows == [1]
    @test NLPDiagnostics.jacobian_product(native_operator, [2.0]) == [2.0]
    @test NLPDiagnostics.jacobian_transpose_product(native_operator, [3.0]) == [3.0]
    @test_throws DimensionMismatch NLPDiagnostics.jacobian_product(native_operator, [1.0, 2.0])
    @test_throws DimensionMismatch NLPDiagnostics.jacobian_transpose_product(native_operator, [1.0, 2.0])
    inconsistent_jacvec_evaluation = NLPDiagnostics.NumericalEvaluation{Float64}(
        jacvec_evaluation.point,
        jacvec_evaluation.objective_value,
        jacvec_evaluation.objective_source,
        copy(jacvec_evaluation.objective_gradient),
        copy(jacvec_evaluation.constraint_values),
        copy(jacvec_evaluation.constraint_sources),
        [NLPDiagnostics.JacobianEntry(1, 1, 2.0)],
        copy(jacvec_evaluation.jacobian_row_methods),
        copy(jacvec_evaluation.capabilities),
        copy(jacvec_evaluation.failures),
        copy(jacvec_evaluation.call_statistics),
        jacvec_evaluation.objective_gradient_method,
    )
    screened_operator = NLPDiagnostics.jacobian_linear_operator(
        jacvec_model, inconsistent_jacvec_evaluation,
    )
    @test screened_operator.available
    @test screened_operator.source == :assembled_sparse
    @test occursin("consistency screen failed", screened_operator.native_unavailable_reason)
    native_probe_report = NLPDiagnostics.analyze_iterative_right_nullspace_probe(
        jacvec_model,
        jacvec_evaluation.point;
        probe_dimension = 1,
        iterations = 5,
    )
    @test native_probe_report.metadata[:iterative_probe_operator_source] ==
        "hybrid_moi_jacvec"
    jacvec_report = NLPDiagnostics.analyze_jacobian_directional_crosscheck(
        jacvec_model,
        jacvec_evaluation;
        direction_count = 1,
    )
    @test jacvec_report.metadata[:jacvec_available] == "true"
    @test jacvec_report.metadata[:mismatch_count] == "0"
    @test occursin(
        "MOI.eval_constraint_jacobian_product",
        jacvec_report.metadata[:jacvec_sources],
    )

    hessian = NLPDiagnostics.evaluate_lagrangian_hessian(
        jacvec_model,
        jacvec_evaluation.point;
        objective_weight = 1.0,
        constraint_multipliers = [0.0],
    )
    hessian_report = NLPDiagnostics.analyze_hessian_vector_crosscheck(
        jacvec_model,
        hessian;
        direction_count = 1,
    )
    @test length(NLPDiagnostics.findings(
        hessian_report;
        code = :hessian_vector_crosscheck_consistent,
    )) == 1
    @test hessian_report.metadata[:hessian_directional_comparisons] == "1"
    @test hessian_report.metadata[:hessvec_directional_comparisons] == "1"
    @test hessian_report.metadata[:mismatch_count] == "0"
    @test occursin(
        "MOI.eval_hessian_lagrangian_product",
        hessian_report.metadata[:hessvec_sources],
    )
    combined_hessian_report = NLPDiagnostics.analyze(
        jacvec_model;
        evaluation = jacvec_evaluation,
        check_hessian_vector_crosscheck = true,
        hessian_vector_crosscheck_direction_count = 1,
        hessian_vector_crosscheck_constraint_multipliers = [0.0],
    )
    @test occursin(
        "hessian_vector_crosscheck",
        combined_hessian_report.metadata[:stages],
    )
    @test length(NLPDiagnostics.findings(
        combined_hessian_report;
        code = :hessian_vector_crosscheck_consistent,
    )) == 1

    changed_model = MOI.Utilities.UniversalFallback(MOI.Utilities.Model{Float64}())
    changed_x = MOI.add_variable(changed_model)
    MOI.add_constraint(changed_model, changed_x, MOI.EqualTo(2.0))
    @test NLPDiagnostics.model_fingerprint(model) !=
          NLPDiagnostics.model_fingerprint(changed_model)
    changed_point = NLPDiagnostics.evaluation_point(changed_model, [2.0])
    @test NLPDiagnostics.evaluation_point_fingerprint(point) !=
          NLPDiagnostics.evaluation_point_fingerprint(changed_point)
end
