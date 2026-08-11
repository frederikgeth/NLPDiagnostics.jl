#!/usr/bin/env julia

"""Emit deterministic dense-oracle and cross-backend smallest-mode evidence."""

using JSON
using LinearAlgebra

import MathOptInterface as MOI
import NLPDiagnostics

function _evaluation(matrix::AbstractMatrix{<:Real}, label::AbstractString)
    values = Float64.(matrix)
    rows, columns = size(values)
    variables = [MOI.VariableIndex(column) for column in 1:columns]
    point = NLPDiagnostics.EvaluationPoint(
        variables, zeros(columns); label,
    )
    entries = NLPDiagnostics.JacobianEntry{Float64}[]
    for column in axes(values, 2), row in axes(values, 1)
        iszero(values[row, column]) && continue
        push!(entries, NLPDiagnostics.JacobianEntry(
            row, column, values[row, column],
        ))
    end
    return NLPDiagnostics.NumericalEvaluation{Float64}(
        point,
        nothing,
        nothing,
        Union{Missing,Float64}[0.0 for _ in 1:columns],
        Union{Missing,Float64}[0.0 for _ in 1:rows],
        [NLPDiagnostics.EntityRef(:constraint, row) for row in 1:rows],
        entries,
        fill(:calibration_exact, rows),
        NLPDiagnostics.EvaluatorCapabilities[],
        NLPDiagnostics.EvaluationFailure[],
    )
end

function _rotated_matrices()
    left_seed = [
        sin(row * column) + cos((row + 2) * column)
        for row in 1:6, column in 1:6
    ]
    right_seed = [
        cos(2 * row * column) + sin((row + 1) * (column + 2))
        for row in 1:6, column in 1:6
    ]
    left = Matrix(qr(left_seed).Q)
    right = Matrix(qr(right_seed).Q)
    return (
        left * Diagonal([5.0, 2.0, 0.5, 0.1, 0.01, 0.001]) * transpose(right),
        left * Diagonal([5.0, 2.0, 0.5, 0.1, 0.0, 0.0]) * transpose(right),
    )
end

function _cases()
    planted, planted_null = _rotated_matrices()
    return [
        (
            name = "well_separated_diagonal",
            matrix = Matrix(Diagonal([1.0, 0.1, 0.01, 0.001])),
            dimension = 2,
            iterations = 20,
            minimum_iterations = 2,
            convergence_tolerance = 1.0e-10,
            value_tolerance = 1.0e-8,
            expected_relation = :agreement,
        ),
        (
            name = "clustered_smallest_pair",
            matrix = Matrix(Diagonal([1.0, 0.1, 0.001001, 0.001])),
            dimension = 2,
            iterations = 20,
            minimum_iterations = 2,
            convergence_tolerance = 1.0e-10,
            value_tolerance = 1.0e-8,
            expected_relation = :agreement,
        ),
        (
            name = "repeated_smallest_boundary",
            matrix = Matrix(Diagonal([1.0, 0.1, 0.001, 0.001])),
            dimension = 1,
            iterations = 20,
            minimum_iterations = 2,
            convergence_tolerance = 1.0e-10,
            value_tolerance = 1.0e-8,
            expected_relation = :agreement_nonunique_subspace,
        ),
        (
            name = "rotated_planted_spectrum",
            matrix = planted,
            dimension = 2,
            iterations = 50,
            minimum_iterations = 2,
            convergence_tolerance = 1.0e-10,
            value_tolerance = 1.0e-8,
            expected_relation = :agreement,
        ),
        (
            name = "rotated_planted_nullspace",
            matrix = planted_null,
            dimension = 2,
            iterations = 50,
            minimum_iterations = 2,
            convergence_tolerance = 1.0e-10,
            value_tolerance = 1.0e-8,
            expected_relation = :dense_target_numerically_unresolved,
        ),
        (
            name = "rectangular_right_nullspace",
            matrix = [1.0 0.0 1.0; 0.0 1.0 1.0],
            dimension = 1,
            iterations = 20,
            minimum_iterations = 2,
            convergence_tolerance = 1.0e-10,
            value_tolerance = 1.0e-8,
            expected_relation = :agreement,
        ),
        (
            name = "zero_operator_nonunique_subspace",
            matrix = zeros(2, 3),
            dimension = 2,
            iterations = 10,
            minimum_iterations = 2,
            convergence_tolerance = 1.0e-10,
            value_tolerance = 1.0e-8,
            expected_relation = :agreement_nonunique_subspace,
        ),
        (
            name = "hilbert_false_convergence_control",
            matrix = [1.0 / (row + column - 1) for row in 1:6, column in 1:6],
            dimension = 1,
            iterations = 100,
            minimum_iterations = 2,
            convergence_tolerance = 1.0e-8,
            value_tolerance = 1.0e-6,
            expected_relation = :singular_value_disagreement,
        ),
        (
            name = "badly_scaled_full_rank_control",
            matrix = Matrix(Diagonal([1.0e8, 1.0, 1.0e-8])),
            dimension = 1,
            iterations = 50,
            minimum_iterations = 2,
            convergence_tolerance = 1.0e-10,
            value_tolerance = 1.0e-6,
            expected_relation = :candidate_unconverged,
        ),
        (
            name = "insufficient_iteration_control",
            matrix = Matrix(Diagonal([1.0, 0.1, 0.01, 0.001])),
            dimension = 1,
            iterations = 1,
            minimum_iterations = 1,
            convergence_tolerance = 0.0,
            value_tolerance = 1.0e-6,
            expected_relation = :candidate_unconverged,
        ),
    ]
end

_history(matrix) = [collect(row) for row in eachrow(matrix)]

function _harmonic_parameters(case)
    columns = size(case.matrix, 2)
    insufficient = case.name == "insufficient_iteration_control"
    scaled = case.name == "badly_scaled_full_rank_control"
    hilbert = case.name == "hilbert_false_convergence_control"
    return (
        steps = insufficient ? 1 : hilbert ? 2 : min(max(case.dimension + 1, 2), columns),
        cycles = insufficient ? 1 : 8,
        minimum_cycles = insufficient ? 1 : 2,
        retained = min(max(case.dimension + 1, 2), columns),
        convergence_tolerance = scaled ? 1.0e-8 : case.convergence_tolerance,
        value_change_tolerance = scaled ? 1.0e-8 : max(case.convergence_tolerance, 1.0e-10),
    )
end

function _expected_harmonic_relation(case)
    return Dict(
        "well_separated_diagonal" => :agreement,
        "clustered_smallest_pair" => :agreement,
        "repeated_smallest_boundary" => :agreement_nonunique_subspace,
        "rotated_planted_spectrum" => :agreement,
        "rotated_planted_nullspace" => :dense_target_numerically_unresolved,
        "rectangular_right_nullspace" => :agreement,
        "zero_operator_nonunique_subspace" => :agreement_nonunique_subspace,
        "hilbert_false_convergence_control" => :agreement,
        "badly_scaled_full_rank_control" => :dense_target_numerically_unresolved,
        "insufficient_iteration_control" => :candidate_unconverged,
    )[case.name]
end

function _expected_crosscheck_relation(case)
    return Dict(
        "well_separated_diagonal" => :agreement,
        "clustered_smallest_pair" => :agreement,
        "repeated_smallest_boundary" => :agreement,
        "rotated_planted_spectrum" => :agreement,
        "rotated_planted_nullspace" => :agreement,
        "rectangular_right_nullspace" => :agreement,
        "zero_operator_nonunique_subspace" => :agreement,
        "hilbert_false_convergence_control" => :singular_value_disagreement,
        "badly_scaled_full_rank_control" => :restarted_unconverged,
        "insufficient_iteration_control" => :both_unconverged,
    )[case.name]
end

function _record(case)
    evaluation = _evaluation(case.matrix, case.name)
    calibration =
        NLPDiagnostics.restarted_smallest_singular_dense_calibration(
            evaluation;
            dimension = case.dimension,
            iterations = case.iterations,
            minimum_iterations = case.minimum_iterations,
            convergence_tolerance = case.convergence_tolerance,
            singular_value_relative_tolerance = case.value_tolerance,
        )
    estimate = calibration.estimate
    harmonic_parameters = _harmonic_parameters(case)
    harmonic = NLPDiagnostics.harmonic_golub_kahan_dense_calibration(
        evaluation;
        dimension = case.dimension,
        steps_per_seed = harmonic_parameters.steps,
        cycles = harmonic_parameters.cycles,
        retained_dimension = harmonic_parameters.retained,
        minimum_cycles = harmonic_parameters.minimum_cycles,
        convergence_tolerance = harmonic_parameters.convergence_tolerance,
        value_change_tolerance = harmonic_parameters.value_change_tolerance,
        singular_value_relative_tolerance = case.value_tolerance,
    )
    crosscheck = NLPDiagnostics.smallest_singular_backend_crosscheck(
        evaluation;
        dimension = case.dimension,
        restarted_iterations = case.iterations,
        restarted_minimum_iterations = case.minimum_iterations,
        restarted_convergence_tolerance = case.convergence_tolerance,
        harmonic_steps_per_seed = harmonic_parameters.steps,
        harmonic_cycles = harmonic_parameters.cycles,
        harmonic_retained_dimension = harmonic_parameters.retained,
        harmonic_minimum_cycles = harmonic_parameters.minimum_cycles,
        harmonic_convergence_tolerance =
            harmonic_parameters.convergence_tolerance,
        harmonic_value_change_tolerance =
            harmonic_parameters.value_change_tolerance,
        singular_value_relative_tolerance = case.value_tolerance,
    )
    expected_harmonic = _expected_harmonic_relation(case)
    expected_crosscheck = _expected_crosscheck_relation(case)
    return Dict{String,Any}(
        "name" => case.name,
        "rows" => size(case.matrix, 1),
        "columns" => size(case.matrix, 2),
        "requested_dimension" => case.dimension,
        "requested_iterations" => case.iterations,
        "expected_relation" => String(case.expected_relation),
        "relation" => String(calibration.relation),
        "expectation_matched" => calibration.relation == case.expected_relation,
        "available" => calibration.available,
        "converged" => estimate.converged,
        "breakdown" => String(estimate.breakdown),
        "completed_iterations" => estimate.completed_iterations,
        "candidate_singular_values" => estimate.singular_values,
        "dense_singular_values" => calibration.dense_singular_values,
        "relative_singular_value_errors" => calibration.relative_singular_value_errors,
        "minimum_principal_cosine" => calibration.minimum_principal_cosine,
        "dense_target_subspace_unique" => calibration.dense_target_subspace_unique,
        "dense_target_numerically_resolved" =>
            calibration.dense_target_numerically_resolved,
        "relative_operator_residuals" => estimate.relative_operator_residual_norms,
        "relative_normal_residuals" => estimate.relative_normal_residual_norms,
        "triplet_backward_errors" => estimate.triplet_backward_errors,
        "singular_value_histories" => _history(estimate.singular_value_histories),
        "normal_residual_histories" => _history(
            estimate.normal_relative_residual_histories,
        ),
        "triplet_backward_error_histories" => _history(
            estimate.triplet_backward_error_histories,
        ),
        "subspace_alignment_history" => estimate.subspace_alignment_history,
        "harmonic_expected_relation" => String(expected_harmonic),
        "harmonic_relation" => String(harmonic.relation),
        "harmonic_expectation_matched" => harmonic.relation == expected_harmonic,
        "harmonic_available" => harmonic.available,
        "harmonic_converged" => harmonic.estimate.converged,
        "harmonic_breakdown" => String(harmonic.estimate.breakdown),
        "harmonic_candidate_singular_values" =>
            harmonic.estimate.singular_values,
        "harmonic_projection_values" => harmonic.estimate.harmonic_values,
        "harmonic_dense_singular_values" => harmonic.dense_singular_values,
        "harmonic_relative_singular_value_errors" =>
            harmonic.relative_singular_value_errors,
        "harmonic_minimum_principal_cosine" =>
            harmonic.minimum_principal_cosine,
        "harmonic_dense_target_numerically_resolved" =>
            harmonic.dense_target_numerically_resolved,
        "harmonic_trial_dimensions" => harmonic.estimate.trial_dimensions,
        "harmonic_projected_metric_ranks" =>
            harmonic.estimate.projected_metric_ranks,
        "harmonic_projected_metric_conditions" =>
            harmonic.estimate.projected_metric_condition_histories,
        "harmonic_triplet_backward_errors" =>
            harmonic.estimate.triplet_backward_errors,
        "crosscheck_expected_relation" => String(expected_crosscheck),
        "crosscheck_relation" => String(crosscheck.relation),
        "crosscheck_expectation_matched" =>
            crosscheck.relation == expected_crosscheck,
        "crosscheck_relative_singular_value_differences" =>
            crosscheck.relative_singular_value_differences,
        "crosscheck_minimum_principal_cosine" =>
            crosscheck.minimum_principal_cosine,
        "interpretation" => "Dense-oracle calibration under explicit finite-precision policies; neither convergence nor agreement is a mathematical rank certificate.",
    )
end

function main()
    length(ARGS) == 1 || error(
        "usage: calibrate_restarted_smallest_singular.jl <output.json>",
    )
    output = abspath(ARGS[1])
    records = _record.(_cases())
    relation_counts = Dict{String,Int}()
    harmonic_relation_counts = Dict{String,Int}()
    crosscheck_relation_counts = Dict{String,Int}()
    for record in records
        relation = String(record["relation"])
        relation_counts[relation] = get(relation_counts, relation, 0) + 1
        harmonic_relation = String(record["harmonic_relation"])
        harmonic_relation_counts[harmonic_relation] =
            get(harmonic_relation_counts, harmonic_relation, 0) + 1
        crosscheck_relation = String(record["crosscheck_relation"])
        crosscheck_relation_counts[crosscheck_relation] =
            get(crosscheck_relation_counts, crosscheck_relation, 0) + 1
    end
    mismatches = [
        record["name"] for record in records
        if !record["expectation_matched"] ||
           !record["harmonic_expectation_matched"] ||
           !record["crosscheck_expectation_matched"]
    ]
    payload = Dict{String,Any}(
        "report_version" => "smallest-singular-cross-backend-calibration-v2",
        "supersedes" => "restarted-smallest-singular-calibration-v1",
        "case_count" => length(records),
        "all_expectations_matched" => isempty(mismatches),
        "expectation_mismatches" => mismatches,
        "relation_counts" => relation_counts,
        "harmonic_relation_counts" => harmonic_relation_counts,
        "crosscheck_relation_counts" => crosscheck_relation_counts,
        "records" => records,
        "interpretation" => "A deterministic software and numerical-method calibration corpus. It compares a locally optimal normal-operator tracker, a zero-target harmonic Golub--Kahan tracker, their dense-free agreement, and guarded dense SVD. Adverse and numerically unresolved controls are expected and prevent finite-search candidates from being promoted to rank claims.",
    )
    mkpath(dirname(output))
    temporary = "$output.tmp"
    write(temporary, JSON.json(payload))
    mv(temporary, output; force = true)
    isempty(mismatches) || error(
        "calibration expectation mismatch: $(join(mismatches, ','))",
    )
    println("wrote cross-backend smallest-direction calibration to $output")
end

main()
