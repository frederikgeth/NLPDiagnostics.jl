using LinearAlgebra
using Test

import MathOptInterface as MOI
import NLPDiagnostics

function _rank_calibration_evaluation(
    matrix::AbstractMatrix{<:Real};
    label::AbstractString,
)
    values = Float64.(matrix)
    rows, columns = size(values)
    variables = [MOI.VariableIndex(column) for column in 1:columns]
    point = NLPDiagnostics.EvaluationPoint(
        variables,
        zeros(columns);
        label,
    )
    entries = NLPDiagnostics.JacobianEntry{Float64}[]
    for column in axes(values, 2), row in axes(values, 1)
        iszero(values[row, column]) && continue
        push!(entries, NLPDiagnostics.JacobianEntry(row, column, values[row, column]))
    end
    sources = [NLPDiagnostics.EntityRef(:constraint, row) for row in 1:rows]
    return NLPDiagnostics.NumericalEvaluation{Float64}(
        point,
        nothing,
        nothing,
        Union{Missing,Float64}[0.0 for _ in 1:columns],
        Union{Missing,Float64}[0.0 for _ in 1:rows],
        sources,
        entries,
        fill(:calibration_exact, rows),
        NLPDiagnostics.EvaluatorCapabilities[],
        NLPDiagnostics.EvaluationFailure[],
    )
end

@testset "multi-seed Golub-Kahan dense-oracle coverage" begin
    cases = [
        (name = "dependent square", matrix = [1.0 2.0; 2.0 4.0], nullity = 1),
        (name = "underdetermined", matrix = [1.0 0.0 1.0; 0.0 1.0 1.0], nullity = 1),
        (name = "full column rank", matrix = [1.0 0.0; 0.0 1.0; 1.0 1.0], nullity = 0),
        (name = "cluster and zero", matrix = Matrix(Diagonal([1.0, 1.0e-6, 0.0])), nullity = 1),
        (name = "zero rectangular", matrix = zeros(2, 3), nullity = 3),
    ]
    policy = NLPDiagnostics.RankPolicy(
        Float64;
        backend = :dense_svd,
        relative_tolerance = 1.0e-8,
        compute_vectors = true,
        provenance = :multi_seed_coverage_corpus,
    )
    agreement_count = 0
    for case in cases
        evaluation = _rank_calibration_evaluation(case.matrix; label = case.name)
        calibration = NLPDiagnostics.golub_kahan_dense_calibration(
            evaluation;
            dense_policy = policy,
            seed_count = 6,
            steps = size(case.matrix, 2),
            residual_relative_tolerance = 1.0e-8,
        )
        @test calibration.available
        @test calibration.dense_right_nullity == case.nullity
        @test calibration.candidate_span_rank == case.nullity
        @test calibration.relation in (
            :subspace_agreement, :dimension_agreement_no_candidate,
        )
        case.nullity > 0 && @test something(
            calibration.minimum_principal_cosine, 0.0,
        ) >= 0.99
        agreement_count += calibration.relation in (
            :subspace_agreement, :dimension_agreement_no_candidate,
        )
    end
    @test agreement_count == length(cases)

    # Deliberately inadequate one-step projections must expose misses rather
    # than being promoted to rank conclusions. The zero operator is the one
    # easy exception because independent seeds themselves span its nullspace.
    short_budget_cases = filter(case -> case.nullity > 0, cases)
    miss_count = 0
    for case in short_budget_cases
        calibration = NLPDiagnostics.golub_kahan_dense_calibration(
            _rank_calibration_evaluation(case.matrix; label = "short $(case.name)");
            dense_policy = policy,
            seed_count = 6,
            steps = 1,
            residual_relative_tolerance = 1.0e-8,
        )
        miss_count += calibration.relation == :candidate_miss
    end
    @test miss_count == 3
    @test length(short_budget_cases) == 4
end

@testset "restarted smallest-direction adversarial oracle" begin
    diagonal = _rank_calibration_evaluation(
        Matrix(Diagonal([1.0, 0.1, 0.01, 0.001]));
        label = "restarted diagonal",
    )
    diagonal_calibration =
        NLPDiagnostics.restarted_smallest_singular_dense_calibration(
            diagonal;
            dimension = 2,
            iterations = 20,
            convergence_tolerance = 1.0e-10,
            singular_value_relative_tolerance = 1.0e-8,
        )
    @test diagonal_calibration.available
    @test diagonal_calibration.relation == :agreement
    @test diagonal_calibration.estimate.converged
    @test diagonal_calibration.estimate.singular_values ≈ [0.001, 0.01]
        rtol = 1.0e-8
    @test diagonal_calibration.dense_singular_values ≈ [0.001, 0.01]
        rtol = 1.0e-12
    @test diagonal_calibration.estimate.completed_iterations <= 10
    @test size(diagonal_calibration.estimate.singular_value_histories, 2) ==
        diagonal_calibration.estimate.completed_iterations
    @test size(
        diagonal_calibration.estimate.normal_relative_residual_histories,
    ) == size(diagonal_calibration.estimate.singular_value_histories)
    @test maximum(
        diagonal_calibration.estimate.relative_normal_residual_norms,
    ) <= 1.0e-10
    @test maximum(diagonal_calibration.estimate.triplet_backward_errors) <=
        1.0e-8
    @test something(diagonal_calibration.minimum_principal_cosine, 0.0) >= 0.99
    @test diagonal_calibration.dense_target_subspace_unique

    clustered = NLPDiagnostics.restarted_smallest_singular_dense_calibration(
        _rank_calibration_evaluation(
            Matrix(Diagonal([1.0, 0.1, 0.001001, 0.001]));
            label = "clustered smallest pair",
        );
        dimension = 2,
        iterations = 20,
        convergence_tolerance = 1.0e-10,
        singular_value_relative_tolerance = 1.0e-8,
    )
    @test clustered.relation == :agreement
    @test clustered.estimate.singular_values ≈ [0.001, 0.001001]
        rtol = 1.0e-8

    repeated = NLPDiagnostics.restarted_smallest_singular_dense_calibration(
        _rank_calibration_evaluation(
            Matrix(Diagonal([1.0, 0.1, 0.001, 0.001]));
            label = "repeated smallest pair",
        );
        dimension = 1,
        iterations = 20,
        convergence_tolerance = 1.0e-10,
        singular_value_relative_tolerance = 1.0e-8,
    )
    @test repeated.relation == :agreement_nonunique_subspace
    @test !repeated.dense_target_subspace_unique

    seed_left = [
        sin(i * j) + cos((i + 2) * j) for i in 1:6, j in 1:6
    ]
    seed_right = [
        cos(2 * i * j) + sin((i + 1) * (j + 2)) for i in 1:6, j in 1:6
    ]
    left_basis = Matrix(qr(seed_left).Q)
    right_basis = Matrix(qr(seed_right).Q)
    planted_matrix = left_basis *
        Diagonal([5.0, 2.0, 0.5, 0.1, 0.01, 0.001]) *
        transpose(right_basis)
    planted = NLPDiagnostics.restarted_smallest_singular_dense_calibration(
        _rank_calibration_evaluation(
            planted_matrix; label = "planted rotated spectrum",
        );
        dimension = 2,
        iterations = 50,
        convergence_tolerance = 1.0e-10,
        singular_value_relative_tolerance = 1.0e-8,
    )
    @test planted.relation == :agreement
    @test planted.estimate.singular_values ≈ [0.001, 0.01] rtol = 1.0e-8
    @test something(planted.minimum_principal_cosine, 0.0) >= 0.99

    planted_null_matrix = left_basis *
        Diagonal([5.0, 2.0, 0.5, 0.1, 0.0, 0.0]) *
        transpose(right_basis)
    planted_null =
        NLPDiagnostics.restarted_smallest_singular_dense_calibration(
            _rank_calibration_evaluation(
                planted_null_matrix; label = "planted rotated nullspace",
            );
            dimension = 2,
            iterations = 50,
            convergence_tolerance = 1.0e-10,
            singular_value_relative_tolerance = 1.0e-8,
        )
    @test planted_null.relation == :dense_target_numerically_unresolved
    @test planted_null.dense_target_subspace_unique
    @test !planted_null.dense_target_numerically_resolved
    @test maximum(planted_null.estimate.relative_operator_residual_norms) <=
        1.0e-12
    @test something(planted_null.minimum_principal_cosine, 0.0) >= 0.99

    rectangular_null =
        NLPDiagnostics.restarted_smallest_singular_dense_calibration(
            _rank_calibration_evaluation(
                [1.0 0.0 1.0; 0.0 1.0 1.0];
                label = "restarted rectangular null",
            );
            dimension = 1,
            iterations = 20,
            convergence_tolerance = 1.0e-10,
            singular_value_relative_tolerance = 1.0e-8,
        )
    @test rectangular_null.relation == :agreement
    @test only(rectangular_null.estimate.relative_operator_residual_norms) <=
        1.0e-12

    zero_operator = NLPDiagnostics.restarted_smallest_singular_dense_calibration(
        _rank_calibration_evaluation(
            zeros(2, 3); label = "restarted zero operator",
        );
        dimension = 2,
        iterations = 10,
        convergence_tolerance = 1.0e-10,
    )
    @test zero_operator.relation == :agreement_nonunique_subspace
    @test zero_operator.estimate.converged
    @test zero_operator.estimate.breakdown == :exact_invariant_subspace

    # A stationary Ritz candidate can still omit the true smallest direction
    # when the normal spectrum is severely compressed. This is a required
    # dense-oracle false-convergence control, not a tolerated flaky case.
    hilbert = [1.0 / (row + column - 1) for row in 1:6, column in 1:6]
    hilbert_calibration =
        NLPDiagnostics.restarted_smallest_singular_dense_calibration(
            _rank_calibration_evaluation(
                hilbert; label = "Hilbert false convergence control",
            );
            dimension = 1,
            iterations = 100,
            convergence_tolerance = 1.0e-8,
            singular_value_relative_tolerance = 1.0e-6,
        )
    @test hilbert_calibration.estimate.converged
    @test hilbert_calibration.relation == :singular_value_disagreement
    @test only(hilbert_calibration.relative_singular_value_errors) > 1.0e-6

    badly_scaled = NLPDiagnostics.restarted_smallest_singular_dense_calibration(
        _rank_calibration_evaluation(
            Matrix(Diagonal([1.0e8, 1.0, 1.0e-8]));
            label = "normal-spectrum scaling control",
        );
        dimension = 1,
        iterations = 50,
        convergence_tolerance = 1.0e-10,
    )
    @test badly_scaled.relation == :candidate_unconverged
    @test badly_scaled.estimate.breakdown == :trial_subspace_stagnation

    insufficient = NLPDiagnostics.restarted_smallest_singular_dense_calibration(
        diagonal;
        dimension = 1,
        iterations = 1,
        minimum_iterations = 1,
        convergence_tolerance = 0.0,
    )
    @test insufficient.relation == :candidate_unconverged
    @test insufficient.estimate.breakdown == :iteration_limit

    guarded = NLPDiagnostics.restarted_smallest_singular_candidates(
        diagonal; dimension = 2, max_basis_entries = 1,
    )
    @test !guarded.available
    @test occursin("exceeds max_basis_entries", guarded.reason)
    dense_guarded =
        NLPDiagnostics.restarted_smallest_singular_dense_calibration(
            diagonal; dimension = 1, dense_max_entries = 1,
        )
    @test !dense_guarded.available
    @test occursin("exceeding guard", dense_guarded.reason)

    candidate_report =
        NLPDiagnostics.analyze_restarted_smallest_singular_candidates(
            _rank_calibration_evaluation(
                [1.0 0.0 1.0; 0.0 1.0 1.0];
                label = "restarted report",
            );
            dimension = 1,
            iterations = 20,
            convergence_tolerance = 1.0e-10,
            near_null_relative_tolerance = 1.0e-10,
        )
    @test length(NLPDiagnostics.findings(
        candidate_report, :restarted_smallest_singular_candidate_converged,
    )) == 1
    @test length(NLPDiagnostics.findings(
        candidate_report, :restarted_smallest_singular_near_null_candidate,
    )) == 1
    disagreement_report =
        NLPDiagnostics.analyze_restarted_smallest_singular_dense_calibration(
            _rank_calibration_evaluation(
                hilbert; label = "Hilbert report",
            );
            dimension = 1,
            iterations = 100,
            convergence_tolerance = 1.0e-8,
            singular_value_relative_tolerance = 1.0e-6,
        )
    @test length(NLPDiagnostics.findings(
        disagreement_report,
        :restarted_smallest_singular_dense_calibration_disagreement,
    )) == 1

    @test_throws ArgumentError NLPDiagnostics.restarted_smallest_singular_candidates(
        diagonal; dimension = 0,
    )
    @test_throws ArgumentError NLPDiagnostics.restarted_smallest_singular_candidates(
        diagonal; dimension = 1, iterations = 1, minimum_iterations = 2,
    )
    @test_throws DimensionMismatch NLPDiagnostics.restarted_smallest_singular_candidates(
        diagonal; dimension = 1, initial_directions = zeros(3, 1),
    )
end

@testset "harmonic Golub-Kahan adversarial oracle" begin
    diagonal = _rank_calibration_evaluation(
        Matrix(Diagonal([1.0, 0.1, 0.01, 0.001]));
        label = "harmonic diagonal",
    )
    diagonal_calibration =
        NLPDiagnostics.harmonic_golub_kahan_dense_calibration(
            diagonal;
            dimension = 2,
            steps_per_seed = 3,
            cycles = 6,
            retained_dimension = 3,
            convergence_tolerance = 1.0e-10,
            value_change_tolerance = 1.0e-10,
            singular_value_relative_tolerance = 1.0e-8,
        )
    @test diagonal_calibration.available
    @test diagonal_calibration.relation == :agreement
    @test diagonal_calibration.estimate.converged
    @test diagonal_calibration.estimate.breakdown == :converged
    @test diagonal_calibration.estimate.singular_values ≈ [0.001, 0.01]
        rtol = 1.0e-8
    @test diagonal_calibration.dense_singular_values ≈ [0.001, 0.01]
        rtol = 1.0e-12
    @test size(diagonal_calibration.estimate.harmonic_value_histories, 2) ==
        diagonal_calibration.estimate.completed_cycles
    @test size(diagonal_calibration.estimate.singular_value_histories) ==
        size(diagonal_calibration.estimate.triplet_backward_error_histories)
    @test length(diagonal_calibration.estimate.trial_dimensions) ==
        diagonal_calibration.estimate.completed_cycles
    @test length(diagonal_calibration.estimate.projected_metric_ranks) ==
        diagonal_calibration.estimate.completed_cycles
    @test maximum(diagonal_calibration.estimate.triplet_backward_errors) <=
        1.0e-10
    @test something(diagonal_calibration.minimum_principal_cosine, 0.0) >= 0.99

    repeated = NLPDiagnostics.harmonic_golub_kahan_dense_calibration(
        _rank_calibration_evaluation(
            Matrix(Diagonal([1.0, 0.1, 0.001, 0.001]));
            label = "harmonic repeated smallest pair",
        );
        dimension = 1,
        steps_per_seed = 3,
        cycles = 6,
        retained_dimension = 2,
        convergence_tolerance = 1.0e-10,
        value_change_tolerance = 1.0e-10,
        singular_value_relative_tolerance = 1.0e-8,
    )
    @test repeated.relation == :agreement_nonunique_subspace
    @test !repeated.dense_target_subspace_unique

    rectangular_null =
        NLPDiagnostics.harmonic_golub_kahan_dense_calibration(
            _rank_calibration_evaluation(
                [1.0 0.0 1.0; 0.0 1.0 1.0];
                label = "harmonic rectangular null",
            );
            dimension = 1,
            steps_per_seed = 2,
            cycles = 6,
            retained_dimension = 2,
            convergence_tolerance = 1.0e-10,
            value_change_tolerance = 1.0e-10,
            singular_value_relative_tolerance = 1.0e-8,
        )
    @test rectangular_null.relation == :agreement
    @test rectangular_null.estimate.converged
    @test only(rectangular_null.estimate.relative_operator_residual_norms) <=
        1.0e-12

    zero_operator = NLPDiagnostics.harmonic_golub_kahan_dense_calibration(
        _rank_calibration_evaluation(
            zeros(2, 3); label = "harmonic zero operator",
        );
        dimension = 2,
        steps_per_seed = 2,
        cycles = 4,
        retained_dimension = 3,
        convergence_tolerance = 1.0e-10,
        value_change_tolerance = 1.0e-10,
    )
    @test zero_operator.relation == :agreement_nonunique_subspace
    @test zero_operator.estimate.converged
    @test all(iszero, zero_operator.estimate.singular_values)
    @test all(iszero, zero_operator.estimate.projected_metric_ranks)

    # This control is the reason for retaining an independent harmonic path:
    # the normal-residual tracker can converge to the wrong singular value,
    # while a small thick-restarted zero-target projection reaches the oracle.
    hilbert = [1.0 / (row + column - 1) for row in 1:6, column in 1:6]
    hilbert_evaluation = _rank_calibration_evaluation(
        hilbert; label = "harmonic Hilbert recovery",
    )
    harmonic_hilbert =
        NLPDiagnostics.harmonic_golub_kahan_dense_calibration(
            hilbert_evaluation;
            dimension = 1,
            steps_per_seed = 2,
            cycles = 8,
            retained_dimension = 2,
            convergence_tolerance = 1.0e-8,
            value_change_tolerance = 1.0e-8,
            singular_value_relative_tolerance = 1.0e-6,
        )
    restarted_hilbert =
        NLPDiagnostics.restarted_smallest_singular_dense_calibration(
            hilbert_evaluation;
            dimension = 1,
            iterations = 100,
            convergence_tolerance = 1.0e-8,
            singular_value_relative_tolerance = 1.0e-6,
        )
    @test harmonic_hilbert.relation == :agreement
    @test harmonic_hilbert.estimate.converged
    @test restarted_hilbert.relation == :singular_value_disagreement
    @test only(harmonic_hilbert.relative_singular_value_errors) <= 1.0e-6
    @test something(harmonic_hilbert.minimum_principal_cosine, 0.0) >= 0.99

    # Dense-oracle value errors are target-local. Normalizing only by the
    # largest singular value would incorrectly accept this missed 1e-8 mode.
    badly_scaled = NLPDiagnostics.harmonic_golub_kahan_dense_calibration(
        _rank_calibration_evaluation(
            Matrix(Diagonal([1.0e8, 1.0, 1.0e-8]));
            label = "harmonic scaling disagreement control",
        );
        dimension = 1,
        steps_per_seed = 2,
        cycles = 8,
        retained_dimension = 2,
        convergence_tolerance = 1.0e-8,
        value_change_tolerance = 1.0e-8,
        singular_value_relative_tolerance = 1.0e-6,
    )
    @test badly_scaled.estimate.converged
    @test badly_scaled.dense_target_subspace_unique
    @test badly_scaled.relation == :dense_target_numerically_unresolved
    @test !badly_scaled.dense_target_numerically_resolved
    @test only(badly_scaled.relative_singular_value_errors) > 1.0e6

    insufficient = NLPDiagnostics.harmonic_golub_kahan_dense_calibration(
        diagonal;
        dimension = 1,
        steps_per_seed = 1,
        cycles = 1,
        retained_dimension = 2,
        minimum_cycles = 1,
        convergence_tolerance = 0.0,
        value_change_tolerance = 0.0,
    )
    @test insufficient.relation == :candidate_unconverged
    @test insufficient.estimate.breakdown == :cycle_limit

    guarded = NLPDiagnostics.harmonic_golub_kahan_candidates(
        diagonal; dimension = 2, max_basis_entries = 1,
    )
    @test !guarded.available
    @test occursin("exceeds max_basis_entries", guarded.reason)
    dense_guarded = NLPDiagnostics.harmonic_golub_kahan_dense_calibration(
        diagonal; dimension = 1, dense_max_entries = 1,
    )
    @test !dense_guarded.available
    @test occursin("exceeding guard", dense_guarded.reason)

    candidate_report = NLPDiagnostics.analyze_harmonic_golub_kahan_candidates(
        _rank_calibration_evaluation(
            [1.0 0.0 1.0; 0.0 1.0 1.0];
            label = "harmonic report",
        );
        dimension = 1,
        steps_per_seed = 2,
        cycles = 6,
        retained_dimension = 2,
        convergence_tolerance = 1.0e-10,
        value_change_tolerance = 1.0e-10,
        near_null_relative_tolerance = 1.0e-10,
    )
    @test length(NLPDiagnostics.findings(
        candidate_report, :harmonic_golub_kahan_candidate_converged,
    )) == 1
    @test length(NLPDiagnostics.findings(
        candidate_report, :harmonic_golub_kahan_candidate,
    )) == 1
    @test length(NLPDiagnostics.findings(
        candidate_report, :harmonic_golub_kahan_near_null_candidate,
    )) == 1
    @test haskey(
        candidate_report.metadata,
        :harmonic_golub_kahan_projected_metric_conditions,
    )
    disagreement_report =
        NLPDiagnostics.analyze_harmonic_golub_kahan_dense_calibration(
            _rank_calibration_evaluation(
                Matrix(Diagonal([1.0e8, 1.0, 1.0e-8]));
                label = "harmonic scaled report",
            );
            dimension = 1,
            steps_per_seed = 2,
            cycles = 8,
            retained_dimension = 2,
            convergence_tolerance = 1.0e-8,
            value_change_tolerance = 1.0e-8,
            singular_value_relative_tolerance = 1.0e-6,
        )
    @test length(NLPDiagnostics.findings(
        disagreement_report,
        :harmonic_golub_kahan_dense_calibration_disagreement,
    )) == 1

    @test_throws ArgumentError NLPDiagnostics.harmonic_golub_kahan_candidates(
        diagonal; dimension = 0,
    )
    @test_throws ArgumentError NLPDiagnostics.harmonic_golub_kahan_candidates(
        diagonal; dimension = 2, retained_dimension = 1,
    )
    @test_throws ArgumentError NLPDiagnostics.harmonic_golub_kahan_candidates(
        diagonal; dimension = 1, cycles = 1, minimum_cycles = 2,
    )
    @test_throws DimensionMismatch NLPDiagnostics.harmonic_golub_kahan_candidates(
        diagonal; dimension = 1, initial_directions = zeros(3, 1),
    )
end

@testset "smallest-direction backend crosscheck" begin
    diagonal = _rank_calibration_evaluation(
        Matrix(Diagonal([1.0, 0.1, 0.01, 0.001]));
        label = "backend agreement diagonal",
    )
    agreement = NLPDiagnostics.smallest_singular_backend_crosscheck(
        diagonal;
        dimension = 2,
        restarted_iterations = 20,
        restarted_convergence_tolerance = 1.0e-10,
        harmonic_steps_per_seed = 3,
        harmonic_cycles = 6,
        harmonic_retained_dimension = 3,
        harmonic_convergence_tolerance = 1.0e-10,
        harmonic_value_change_tolerance = 1.0e-10,
        singular_value_relative_tolerance = 1.0e-6,
    )
    @test agreement.available
    @test agreement.relation == :agreement
    @test agreement.restarted.converged
    @test agreement.harmonic.converged
    @test maximum(agreement.relative_singular_value_differences) <= 1.0e-6
    @test something(agreement.minimum_principal_cosine, 0.0) >= 0.99

    scaling_matrix = [3.0 0.0 1.0; 4.0 2.0 0.0]
    scaling_evaluation = _rank_calibration_evaluation(
        scaling_matrix; label = "smallest-direction scaling intervention",
    )
    scaling_rank = NLPDiagnostics.jacobian_rank_estimate(
        scaling_evaluation,
        NLPDiagnostics.RankPolicy(
            Float64;
            scaling = :row_column,
            compute_vectors = false,
        ),
    )
    scaling_intervention =
        NLPDiagnostics._diagonally_scaled_jacobian_evaluation(
            scaling_evaluation,
            :row_column,
        )
    scaled_operator = NLPDiagnostics.jacobian_linear_operator(
        scaling_intervention.evaluation,
    )
    @test Matrix(scaled_operator.assembled_matrix) ≈
        Diagonal(scaling_rank.row_scaling) * scaling_matrix *
        Diagonal(scaling_rank.column_scaling)
    @test scaling_intervention.row_scaling == scaling_rank.row_scaling
    @test scaling_intervention.column_scaling == scaling_rank.column_scaling
    scaling_report = NLPDiagnostics.analyze_smallest_singular_backend_crosscheck(
        scaling_intervention.evaluation;
        original_evaluation_for_scaled_audit = scaling_evaluation,
        column_scaling_for_original_audit =
            scaling_intervention.column_scaling,
        dimension = 1,
        restarted_iterations = 10,
        harmonic_steps_per_seed = 2,
        harmonic_cycles = 4,
    )
    @test scaling_report.metadata[
        :smallest_singular_backend_crosscheck_original_audit_available,
    ] == "true"
    @test !isempty(scaling_report.metadata[
        :smallest_singular_backend_crosscheck_restarted_original_relative_residuals,
    ])
    @test_throws ArgumentError NLPDiagnostics.analyze_smallest_singular_backend_crosscheck(
        scaling_intervention.evaluation;
        original_evaluation_for_scaled_audit = scaling_evaluation,
        dimension = 1,
    )
    @test_throws ArgumentError NLPDiagnostics._diagonally_scaled_jacobian_evaluation(
        scaling_evaluation,
        :unsupported,
    )

    hilbert = [1.0 / (row + column - 1) for row in 1:6, column in 1:6]
    hilbert_evaluation = _rank_calibration_evaluation(
        hilbert; label = "backend Hilbert disagreement",
    )
    hilbert_disagreement =
        NLPDiagnostics.smallest_singular_backend_crosscheck(
            hilbert_evaluation;
            dimension = 1,
            restarted_iterations = 100,
            restarted_convergence_tolerance = 1.0e-8,
            harmonic_steps_per_seed = 2,
            harmonic_cycles = 8,
            harmonic_retained_dimension = 2,
            harmonic_convergence_tolerance = 1.0e-8,
            harmonic_value_change_tolerance = 1.0e-8,
            singular_value_relative_tolerance = 1.0e-3,
        )
    @test hilbert_disagreement.available
    @test hilbert_disagreement.restarted.converged
    @test hilbert_disagreement.harmonic.converged
    @test hilbert_disagreement.relation == :singular_value_disagreement
    @test only(hilbert_disagreement.relative_singular_value_differences) >
        1.0e-3

    rectangular_null = NLPDiagnostics.smallest_singular_backend_crosscheck(
        _rank_calibration_evaluation(
            [1.0 0.0 1.0; 0.0 1.0 1.0];
            label = "backend null agreement",
        );
        dimension = 1,
        restarted_iterations = 20,
        restarted_convergence_tolerance = 1.0e-10,
        harmonic_steps_per_seed = 2,
        harmonic_cycles = 6,
        harmonic_retained_dimension = 2,
        harmonic_convergence_tolerance = 1.0e-10,
        harmonic_value_change_tolerance = 1.0e-10,
    )
    @test rectangular_null.relation == :agreement
    @test only(rectangular_null.relative_singular_value_differences) == 0.0

    underdimensioned = NLPDiagnostics.analyze_smallest_singular_backend_crosscheck(
        _rank_calibration_evaluation(
            [1.0 0.0 1.0 0.0; 0.0 1.0 0.0 1.0];
            label = "underdimensioned rectangular crosscheck",
        );
        dimension = 1,
        restarted_iterations = 10,
        harmonic_steps_per_seed = 2,
        harmonic_cycles = 4,
    )
    @test underdimensioned.metadata[
        :smallest_singular_backend_crosscheck_structural_minimum_right_nullity,
    ] == "2"
    @test underdimensioned.metadata[
        :smallest_singular_backend_crosscheck_dimension_covers_structural_minimum,
    ] == "false"
    @test length(NLPDiagnostics.findings(
        underdimensioned,
        :smallest_singular_backend_crosscheck_dimension_below_structural_nullity,
    )) == 1

    guarded = NLPDiagnostics.smallest_singular_backend_crosscheck(
        diagonal; dimension = 2, max_basis_entries = 1,
    )
    @test !guarded.available
    @test guarded.relation == :unavailable
    @test occursin("both candidate engines", guarded.reason)

    report = NLPDiagnostics.analyze_smallest_singular_backend_crosscheck(
        diagonal;
        dimension = 2,
        restarted_iterations = 20,
        restarted_convergence_tolerance = 1.0e-10,
        harmonic_steps_per_seed = 3,
        harmonic_cycles = 6,
        harmonic_retained_dimension = 3,
        harmonic_convergence_tolerance = 1.0e-10,
        harmonic_value_change_tolerance = 1.0e-10,
    )
    @test length(NLPDiagnostics.findings(
        report, :smallest_singular_backend_crosscheck_agreement,
    )) == 1
    @test report.metadata[
        :smallest_singular_backend_crosscheck_relation,
    ] == "agreement"

    inconclusive_report = NLPDiagnostics.analyze_smallest_singular_backend_crosscheck(
        hilbert_evaluation;
        dimension = 1,
        restarted_iterations = 2,
        restarted_convergence_tolerance = 0.0,
        restarted_alignment_threshold = 1.0,
        harmonic_steps_per_seed = 1,
        harmonic_cycles = 2,
        harmonic_convergence_tolerance = 0.0,
        harmonic_value_change_tolerance = 0.0,
        harmonic_alignment_threshold = 1.0,
    )
    @test inconclusive_report.metadata[
        :smallest_singular_backend_crosscheck_relation,
    ] == "both_unconverged"
    @test length(NLPDiagnostics.findings(
        inconclusive_report,
        :smallest_singular_backend_crosscheck_inconclusive,
    )) == 1
    @test isempty(NLPDiagnostics.findings(
        inconclusive_report,
        :smallest_singular_backend_crosscheck_disagreement,
    ))

    @test_throws ArgumentError NLPDiagnostics.smallest_singular_backend_crosscheck(
        diagonal; singular_value_relative_tolerance = -1.0,
    )
    @test_throws ArgumentError NLPDiagnostics.smallest_singular_backend_crosscheck(
        diagonal; subspace_alignment_threshold = 2.0,
    )
end

@testset "rank backend calibration corpus" begin
    cases = [
        (
            name = "exact row dependence",
            matrix = [1.0 2.0; 2.0 4.0],
            rank = 1,
            left_nullity = 1,
            right_nullity = 1,
        ),
        (
            name = "rectangular underdetermined",
            matrix = [1.0 0.0 1.0; 0.0 1.0 1.0],
            rank = 2,
            left_nullity = 0,
            right_nullity = 1,
        ),
        (
            name = "rectangular overdetermined",
            matrix = [1.0 0.0; 0.0 1.0; 1.0 1.0],
            rank = 2,
            left_nullity = 1,
            right_nullity = 0,
        ),
        (
            name = "clustered small and exact zero",
            matrix = Matrix(Diagonal([1.0, 1.0e-6, 0.0])),
            rank = 2,
            left_nullity = 1,
            right_nullity = 1,
        ),
        (
            name = "zero Jacobian",
            matrix = zeros(2, 3),
            rank = 0,
            left_nullity = 2,
            right_nullity = 3,
        ),
    ]

    for case in cases
        evaluation = _rank_calibration_evaluation(case.matrix; label = case.name)
        dense_policy = NLPDiagnostics.RankPolicy(
            Float64;
            backend = :dense_svd,
            relative_tolerance = 1.0e-8,
            provenance = :calibration_corpus,
        )
        sparse_policy = NLPDiagnostics.RankPolicy(
            Float64;
            backend = :sparse_qr,
            relative_tolerance = 1.0e-8,
            max_dense_entries = length(case.matrix),
            compute_vectors = false,
            provenance = :calibration_corpus,
        )
        dense = NLPDiagnostics.jacobian_rank_estimate(evaluation, dense_policy)
        sparse = NLPDiagnostics.sparse_qr_rank_estimate(evaluation, sparse_policy)
        @test dense.available
        @test sparse.available
        @test dense.rank == case.rank
        @test sparse.rank == case.rank
        @test dense.left_nullity == case.left_nullity
        @test dense.right_nullity == case.right_nullity
        @test dense.policy.provenance == :calibration_corpus
        @test sparse.policy.provenance == :calibration_corpus
        @test sparse.method == :suitesparse_qr
        @test sort(sparse.row_permutation) == collect(1:size(case.matrix, 1))
        @test sort(sparse.column_permutation) == collect(1:size(case.matrix, 2))
        @test !isnothing(sparse.factorization_relative_residual)
        @test sparse.factorization_relative_residual <= 1.0e-12
        if dense.right_nullity > 0
            @test norm(case.matrix * dense.right_nullspace) <= 1.0e-10
        end
        if dense.left_nullity > 0
            @test norm(transpose(case.matrix) * dense.left_nullspace) <= 1.0e-10
        end
    end

    ill_conditioned = _rank_calibration_evaluation(
        [1.0 0.0; 0.0 1.0e-10];
        label = "ill-conditioned full rank",
    )
    tight = NLPDiagnostics.jacobian_rank_estimate(
        ill_conditioned,
        NLPDiagnostics.RankPolicy(
            Float64;
            backend = :dense_svd,
            relative_tolerance = 1.0e-12,
            provenance = :calibration_corpus,
        ),
    )
    loose = NLPDiagnostics.jacobian_rank_estimate(
        ill_conditioned,
        NLPDiagnostics.RankPolicy(
            Float64;
            backend = :dense_svd,
            relative_tolerance = 1.0e-8,
            provenance = :calibration_corpus,
        ),
    )
    @test tight.rank == 2
    @test loose.rank == 1

    absolute_floor = NLPDiagnostics.jacobian_rank_estimate(
        ill_conditioned,
        NLPDiagnostics.RankPolicy(
            Float64;
            backend = :dense_svd,
            relative_tolerance = 0.0,
            absolute_tolerance = 1.0e-9,
            provenance = :calibration_corpus,
        ),
    )
    @test absolute_floor.rank == 1
    @test absolute_floor.absolute_threshold == 1.0e-9

    badly_scaled = _rank_calibration_evaluation(
        [1.0e-12 0.0; 0.0 1.0];
        label = "scaled full rank",
    )
    unscaled = NLPDiagnostics.jacobian_rank_estimate(
        badly_scaled;
        relative_tolerance = 1.0e-10,
    )
    scaled = NLPDiagnostics.jacobian_rank_estimate(
        badly_scaled;
        scaling = :row_column,
        relative_tolerance = 1.0e-10,
    )
    sparse_scaled = NLPDiagnostics.sparse_qr_rank_estimate(
        badly_scaled;
        scaling = :row_column,
        relative_tolerance = 1.0e-10,
    )
    @test unscaled.rank == 1
    @test scaled.rank == 2
    @test sparse_scaled.rank == 2

    qr_null_evaluation = _rank_calibration_evaluation(
        [1.0 0.0 1.0; 0.0 1.0 1.0];
        label = "sparse QR right nullspace",
    )
    qr_null = NLPDiagnostics.sparse_qr_nullspace_estimate(
        qr_null_evaluation;
        relative_tolerance = 1.0e-10,
    )
    @test qr_null.available
    @test qr_null.rank == 2
    @test qr_null.right_nullity == 1
    @test size(qr_null.directions) == (3, 1)
    @test only(qr_null.relative_residual_norms) <= 1.0e-12
    @test qr_null.orthogonality_loss <= 1.0e-12
    @test qr_null.factor_nonzeros > 0
    @test qr_null.fill_ratio > 0

    qr_null_scaled = NLPDiagnostics.sparse_qr_nullspace_estimate(
        _rank_calibration_evaluation(
            [1.0e8 0.0 1.0e8; 0.0 1.0e-8 1.0e-8];
            label = "scaled sparse QR right nullspace",
        );
        scaling = :row_column,
        relative_tolerance = 1.0e-10,
    )
    @test qr_null_scaled.available
    @test qr_null_scaled.right_nullity == 1
    @test only(qr_null_scaled.relative_residual_norms) <= 1.0e-12
    @test qr_null_scaled.column_scaling != ones(3)

    qr_zero = NLPDiagnostics.sparse_qr_nullspace_estimate(
        _rank_calibration_evaluation(
            zeros(2, 3); label = "zero sparse QR nullspace",
        );
        relative_tolerance = 1.0e-10,
    )
    @test qr_zero.available
    @test qr_zero.rank == 0
    @test qr_zero.right_nullity == 3
    @test qr_zero.directions' * qr_zero.directions ≈ Matrix{Float64}(I, 3, 3)

    qr_full = NLPDiagnostics.sparse_qr_nullspace_estimate(
        _rank_calibration_evaluation(
            [1.0 0.0; 0.0 1.0; 1.0 1.0];
            label = "full-column sparse QR nullspace",
        );
        relative_tolerance = 1.0e-10,
    )
    @test qr_full.available
    @test qr_full.right_nullity == 0
    @test size(qr_full.directions) == (2, 0)

    qr_dense_calibration =
        NLPDiagnostics.sparse_qr_nullspace_dense_calibration(
            qr_null_evaluation;
            relative_tolerance = 1.0e-10,
            dense_max_entries = 100,
        )
    @test qr_dense_calibration.available
    @test qr_dense_calibration.relation == :subspace_agreement
    @test something(qr_dense_calibration.minimum_principal_cosine, 0.0) >=
        1.0 - 1.0e-12
    @test !qr_dense_calibration.dense_threshold_ambiguous

    qr_report = NLPDiagnostics.analyze_sparse_qr_nullspace(
        qr_null_evaluation;
        relative_tolerance = 1.0e-10,
    )
    @test length(NLPDiagnostics.findings(
        qr_report, :sparse_qr_right_nullspace_candidate,
    )) == 1
    qr_dense_report =
        NLPDiagnostics.analyze_sparse_qr_nullspace_dense_calibration(
            qr_null_evaluation;
            relative_tolerance = 1.0e-10,
            dense_max_entries = 100,
        )
    @test length(NLPDiagnostics.findings(
        qr_dense_report,
        :sparse_qr_nullspace_dense_calibration_agreement,
    )) == 1

    @test !NLPDiagnostics.sparse_qr_nullspace_estimate(
        qr_null_evaluation; max_input_nonzeros = 0,
    ).available
    @test !NLPDiagnostics.sparse_qr_nullspace_estimate(
        qr_null_evaluation; max_factor_nonzeros = 0,
    ).available
    @test !NLPDiagnostics.sparse_qr_nullspace_estimate(
        qr_null_evaluation; max_nullspace_entries = 0,
    ).available
    @test_throws ArgumentError NLPDiagnostics.sparse_qr_nullspace_estimate(
        qr_null_evaluation; max_factor_nonzeros = -1,
    )

    dependent = _rank_calibration_evaluation(
        [1.0 1.0; 2.0 2.0];
        label = "backward-error calibration",
    )
    scaled_dependent = _rank_calibration_evaluation(
        1.0e9 .* [1.0 1.0; 2.0 2.0];
        label = "scaled backward-error calibration",
    )
    right = NLPDiagnostics.iterative_right_nullspace_subspace_estimate(
        dependent, 1; iterations = 300,
    )
    right_scaled = NLPDiagnostics.iterative_right_nullspace_subspace_estimate(
        scaled_dependent, 1; iterations = 300,
    )
    left = NLPDiagnostics.iterative_left_nullspace_subspace_estimate(
        dependent, 1; iterations = 300,
    )
    @test right.available && right_scaled.available && left.available
    @test only(right.relative_residual_norms) <= 1.0e-7
    @test only(right_scaled.relative_residual_norms) <= 1.0e-7
    @test only(left.relative_residual_norms) <= 1.0e-7
    @test only(right.relative_residual_norms) ≈
          only(right_scaled.relative_residual_norms) rtol = 1.0e-6 atol = 1.0e-14

    guarded_sparse = NLPDiagnostics.sparse_qr_rank_estimate(
        dependent;
        max_dense_entries = 0,
    )
    @test guarded_sparse.available
    @test isnothing(guarded_sparse.factorization_relative_residual)
    @test occursin("dense guard exceeded", guarded_sparse.factorization_residual_reason)

    @test_throws ArgumentError NLPDiagnostics.RankPolicy(Float64; backend = :unknown)
    @test_throws ArgumentError NLPDiagnostics.RankPolicy(Float64; absolute_tolerance = -1)
    @test_throws ArgumentError NLPDiagnostics.jacobian_rank_estimate(
        dependent,
        NLPDiagnostics.RankPolicy(Float64; backend = :sparse_qr),
    )

    diagonal = _rank_calibration_evaluation(
        [4.0 0.0; 0.0 2.0]; label = "Golub-Kahan diagonal",
    )
    diagonal_gk = NLPDiagnostics.golub_kahan_ritz_estimate(
        diagonal; steps = 2,
    )
    @test diagonal_gk.available
    @test diagonal_gk.completed_steps == 2
    @test diagonal_gk.operator_source == :assembled_sparse
    @test diagonal_gk.singular_values ≈ [4.0, 2.0] rtol = 1.0e-12
    @test maximum(diagonal_gk.relative_backward_errors) <= 1.0e-12
    @test diagonal_gk.projection_relative_residual <= 1.0e-12
    @test diagonal_gk.left_orthogonality_loss <= 1.0e-12
    @test diagonal_gk.right_orthogonality_loss <= 1.0e-12

    underdetermined = _rank_calibration_evaluation(
        [1.0 0.0 1.0; 0.0 1.0 1.0];
        label = "Golub-Kahan underdetermined",
    )
    underdetermined_gk = NLPDiagnostics.golub_kahan_ritz_estimate(
        underdetermined; steps = 3,
    )
    @test underdetermined_gk.available
    @test underdetermined_gk.breakdown == :left_recurrence
    @test underdetermined_gk.singular_values ≈ [sqrt(3.0), 1.0] rtol = 1.0e-12
    @test size(underdetermined_gk.projected_right_null_directions) == (3, 1)
    @test only(underdetermined_gk.projected_right_null_relative_residual_norms) <=
          1.0e-12
    gk_report = NLPDiagnostics.analyze_golub_kahan_probe(
        underdetermined; steps = 3, residual_relative_tolerance = 1.0e-10,
    )
    @test length(NLPDiagnostics.findings(
        gk_report, :golub_kahan_projected_right_null_candidate,
    )) == 1
    @test isempty(NLPDiagnostics.findings(
        gk_report, :golub_kahan_ritz_residual_large,
    ))

    rank_deficient_gk = NLPDiagnostics.golub_kahan_ritz_estimate(
        _rank_calibration_evaluation(
            [4.0 0.0; 0.0 0.0]; label = "Golub-Kahan exact null",
        ); steps = 2,
    )
    @test rank_deficient_gk.available
    @test size(rank_deficient_gk.projected_right_null_directions, 2) == 1
    @test only(rank_deficient_gk.projected_right_null_relative_residual_norms) <=
          1.0e-12

    diagonal_scaled_gk = NLPDiagnostics.golub_kahan_ritz_estimate(
        _rank_calibration_evaluation(
            1.0e9 .* [4.0 0.0; 0.0 2.0];
            label = "scaled Golub-Kahan diagonal",
        ); steps = 2,
    )
    @test diagonal_scaled_gk.singular_values ./ 1.0e9 ≈
          diagonal_gk.singular_values rtol = 1.0e-12
    @test maximum(diagonal_scaled_gk.relative_backward_errors) <= 1.0e-12
    @test_throws ArgumentError NLPDiagnostics.golub_kahan_ritz_estimate(
        diagonal; steps = 0,
    )
    @test_throws DimensionMismatch NLPDiagnostics.golub_kahan_ritz_estimate(
        diagonal; steps = 2, seed = [1.0],
    )
    @test_throws ArgumentError NLPDiagnostics.golub_kahan_ritz_estimate(
        diagonal; steps = 2, seed = [0.0, 0.0],
    )

    multi_seed = NLPDiagnostics.multi_seed_golub_kahan_estimate(
        underdetermined;
        seed_count = 4,
        steps = 3,
        residual_relative_tolerance = 1.0e-10,
    )
    @test multi_seed.available
    @test multi_seed.available_seed_count == 4
    @test multi_seed.retained_candidate_counts == fill(1, 4)
    @test multi_seed.candidate_span_rank == 1
    @test maximum(multi_seed.candidate_basis_relative_residual_norms) <= 1.0e-12
    @test multi_seed.comparable_seed_pair_count == 6
    @test multi_seed.agreeing_seed_pair_count == 6
    @test something(multi_seed.minimum_pairwise_principal_cosine, 0.0) >= 0.99

    multi_seed_report = NLPDiagnostics.analyze_multi_seed_golub_kahan_probe(
        underdetermined;
        seed_count = 4,
        steps = 3,
        residual_relative_tolerance = 1.0e-10,
    )
    @test length(NLPDiagnostics.findings(
        multi_seed_report, :multi_seed_golub_kahan_candidate_span,
    )) == 1
    @test length(NLPDiagnostics.findings(
        multi_seed_report, :multi_seed_golub_kahan_candidate_span_stable,
    )) == 1

    guarded_multi_seed = NLPDiagnostics.multi_seed_golub_kahan_estimate(
        underdetermined; seed_count = 4, steps = 3, max_basis_entries = 1,
    )
    @test !guarded_multi_seed.available
    @test occursin("exceeds max_basis_entries", guarded_multi_seed.reason)
    guarded_report = NLPDiagnostics.analyze_multi_seed_golub_kahan_probe(
        underdetermined; seed_count = 4, steps = 3, max_basis_entries = 1,
    )
    @test length(NLPDiagnostics.findings(
        guarded_report, :multi_seed_golub_kahan_probe_unavailable,
    )) == 1

    dense_policy = NLPDiagnostics.RankPolicy(
        Float64;
        backend = :dense_svd,
        relative_tolerance = 1.0e-8,
        compute_vectors = true,
        provenance = :golub_kahan_test,
    )
    dense_agreement = NLPDiagnostics.golub_kahan_dense_calibration(
        underdetermined;
        dense_policy,
        seed_count = 4,
        steps = 3,
        residual_relative_tolerance = 1.0e-10,
    )
    @test dense_agreement.available
    @test dense_agreement.relation == :subspace_agreement
    @test dense_agreement.dense_right_nullity == 1
    @test dense_agreement.candidate_span_rank == 1
    @test dense_agreement.detected_fraction == 1.0
    @test something(dense_agreement.minimum_principal_cosine, 0.0) >= 0.99
    agreement_report = NLPDiagnostics.analyze_golub_kahan_dense_calibration(
        underdetermined;
        dense_policy,
        seed_count = 4,
        steps = 3,
        residual_relative_tolerance = 1.0e-10,
    )
    @test length(NLPDiagnostics.findings(
        agreement_report, :golub_kahan_dense_calibration_agreement,
    )) == 1

    deliberate_miss = NLPDiagnostics.golub_kahan_dense_calibration(
        underdetermined;
        dense_policy,
        seed_count = 4,
        steps = 1,
        residual_relative_tolerance = 1.0e-10,
    )
    @test deliberate_miss.available
    @test deliberate_miss.relation == :candidate_miss
    @test deliberate_miss.candidate_span_rank == 0
    @test deliberate_miss.detected_fraction == 0.0
    miss_report = NLPDiagnostics.analyze_golub_kahan_dense_calibration(
        underdetermined;
        dense_policy,
        seed_count = 4,
        steps = 1,
        residual_relative_tolerance = 1.0e-10,
    )
    @test length(NLPDiagnostics.findings(
        miss_report, :golub_kahan_dense_calibration_disagreement,
    )) == 1

    scaled_multi_seed = NLPDiagnostics.multi_seed_golub_kahan_estimate(
        _rank_calibration_evaluation(
            1.0e9 .* [1.0 0.0 1.0; 0.0 1.0 1.0];
            label = "scaled multi-seed Golub-Kahan",
        );
        seed_count = 4,
        steps = 3,
        residual_relative_tolerance = 1.0e-10,
    )
    @test scaled_multi_seed.candidate_span_rank == multi_seed.candidate_span_rank
    @test maximum(scaled_multi_seed.candidate_basis_relative_residual_norms) <=
          1.0e-12
    @test_throws ArgumentError NLPDiagnostics.multi_seed_golub_kahan_estimate(
        underdetermined; seed_count = 0,
    )
    @test_throws ArgumentError NLPDiagnostics.multi_seed_golub_kahan_estimate(
        underdetermined; seed_agreement_threshold = 1.1,
    )
end
