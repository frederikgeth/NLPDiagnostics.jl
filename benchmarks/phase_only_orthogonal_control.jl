#!/usr/bin/env julia

"""Run the bounded phase-only orthogonal algebraic control.

This control deliberately separates three questions before any solver-work
claim is attempted:

  1. is the declared intervention phase-only rather than magnitude-changing;
  2. do complete orthogonal blocks preserve the Jacobian singular values; and
  3. does a cross-block Jacobian retain coupling after the rotation?

No solver is run here. The result records solver-work evidence as unavailable,
so this control cannot be mistaken for a performance campaign.
"""

using LinearAlgebra
using JSON
import MathOptInterface as MOI
using NLPDiagnostics

function _evaluation(variables, point, gradient, constraints, jacobian; label)
    entries = NLPDiagnostics.JacobianEntry{Float64}[]
    for row in axes(jacobian, 1), column in axes(jacobian, 2)
        iszero(jacobian[row, column]) || push!(
            entries,
            NLPDiagnostics.JacobianEntry(row, column, jacobian[row, column]),
        )
    end
    rows = size(jacobian, 1)
    return NLPDiagnostics.NumericalEvaluation{Float64}(
        NLPDiagnostics.EvaluationPoint(variables, point; label),
        1.5,
        NLPDiagnostics.EntityRef(:objective, 1; name="objective"),
        Union{Missing,Float64}[gradient...],
        Union{Missing,Float64}[constraints...],
        [NLPDiagnostics.EntityRef(:constraint, row; name="row$row")
            for row in 1:rows],
        entries,
        fill(:analytic, rows),
        NLPDiagnostics.EvaluatorCapabilities[],
        NLPDiagnostics.EvaluationFailure[],
        Dict{Symbol,Tuple{Int,Float64}}(),
        :analytic,
    )
end

function _block_rotation(theta)
    return [cos(theta) -sin(theta); sin(theta) cos(theta)]
end

function _block_diagonal(first, second)
    return [first zeros(2, 2); zeros(2, 2) second]
end

function run_phase_only_control()
    variables = [MOI.VariableIndex(index) for index in 1:4]
    keys = ["v1r", "v1i", "v2r", "v2i"]
    positions = [1, 2, 3, 4]
    variable_rotation = _block_diagonal(
        _block_rotation(0.37),
        _block_rotation(-0.52),
    )
    constraint_rotation = _block_diagonal(
        _block_rotation(-0.61),
        _block_rotation(0.28),
    )
    physical_point = [2.0, -0.4, 0.7, 1.3]
    physical_gradient = [1.2, -0.7, 0.3, 0.9]
    physical_constraints = [0.1, -0.2, 0.3, -0.4]
    physical_jacobian = [
        2.0 0.5 0.3 -0.2
        -1.0 3.0 0.4 0.7
        0.8 -0.1 1.5 0.2
        0.2 0.6 -0.7 2.5
    ]
    candidate = _evaluation(
        variables,
        transpose(variable_rotation) * physical_point,
        transpose(variable_rotation) * physical_gradient,
        transpose(constraint_rotation) * physical_constraints,
        transpose(constraint_rotation) * physical_jacobian * variable_rotation;
        label="phase-only-candidate",
    )
    reference = _evaluation(
        variables,
        physical_point,
        physical_gradient,
        physical_constraints,
        physical_jacobian;
        label="phase-only-reference",
    )
    reference_map = NLPDiagnostics.SemanticBlockScalingMap(
        "phase-reference";
        variable_blocks=[NLPDiagnostics.SemanticLinearBlock(
            keys[1:2], positions[1:2], Matrix{Float64}(I, 2, 2),
        ), NLPDiagnostics.SemanticLinearBlock(
            keys[3:4], positions[3:4], Matrix{Float64}(I, 2, 2),
        )],
        constraint_blocks=[NLPDiagnostics.SemanticConstraintBlock(
            keys[1:2], positions[1:2], Matrix{Float64}(I, 2, 2);
            set=NLPDiagnostics.ZeroEqualitySetContract(),
        ), NLPDiagnostics.SemanticConstraintBlock(
            keys[3:4], positions[3:4], Matrix{Float64}(I, 2, 2);
            set=NLPDiagnostics.ZeroEqualitySetContract(),
        )],
    )
    candidate_map = NLPDiagnostics.SemanticBlockScalingMap(
        "phase-only-candidate";
        variable_blocks=[NLPDiagnostics.SemanticLinearBlock(
            keys[1:2], positions[1:2], variable_rotation[1:2, 1:2],
        ), NLPDiagnostics.SemanticLinearBlock(
            keys[3:4], positions[3:4], variable_rotation[3:4, 3:4],
        )],
        constraint_blocks=[NLPDiagnostics.SemanticConstraintBlock(
            keys[1:2], positions[1:2], constraint_rotation[1:2, 1:2];
            set=NLPDiagnostics.ZeroEqualitySetContract(),
        ), NLPDiagnostics.SemanticConstraintBlock(
            keys[3:4], positions[3:4], constraint_rotation[3:4, 3:4];
            set=NLPDiagnostics.ZeroEqualitySetContract(),
        )],
    )
    intervention = NLPDiagnostics.scaling_intervention_classification(
        reference_map, candidate_map; max_dense_entries=0,
    )
    covariance = NLPDiagnostics.scaling_covariance_report(
        reference, reference_map, candidate, candidate_map;
        max_dense_entries=0,
    )
    geometry = NLPDiagnostics.scaling_coordinate_geometry_report(
        reference, reference_map, candidate, candidate_map;
        max_dense_entries=0,
    )
    reference_singular_values = svdvals(physical_jacobian)
    candidate_singular_values = svdvals(
        transpose(constraint_rotation) * physical_jacobian * variable_rotation,
    )
    coupling = physical_jacobian[1:2, 3:4]
    return Dict{String,Any}(
        "schema_version" => "nlpdiagnostics-phase-only-control-v1",
        "intervention" => intervention,
        "covariance" => covariance,
        "geometry" => geometry,
        "singular_values" => Dict(
            "reference" => reference_singular_values,
            "candidate" => candidate_singular_values,
            "maximum_absolute_difference" => maximum(
                abs.(reference_singular_values - candidate_singular_values),
            ),
            "invariance_passed" => isapprox(
                reference_singular_values,
                candidate_singular_values;
                rtol=1.0e-10,
                atol=1.0e-12,
            ),
        ),
        "cross_block_coupling" => Dict(
            "reference_block_1_to_block_2_frobenius_norm" => norm(coupling),
            "rotation_preserves_nonzero_coupling" => !iszero(norm(coupling)),
        ),
        "solver_work" => Dict(
            "available" => false,
            "status" => "withheld_by_design",
            "reason" =>
                "the algebraic phase-only control does not run a solver; solver-work effects require a separate matched campaign",
        ),
        "qualification" => Dict(
            "phase_only_classification_passed" =>
                intervention["classification"] == "phase_only",
            "covariance_gate_passed" => covariance["equivalence_gate_passed"],
            "geometry_gate_passed" => geometry["comparison_qualified"],
            "does_not_establish" => [
                "electrical phase semantics for arbitrary plugin blocks",
                "solver-work or wall-time effects",
                "global policy superiority",
            ],
        ),
    )
end

output = abspath(get(
    ENV,
    "NLPDIAGNOSTICS_PHASE_ONLY_OUTPUT",
    joinpath(@__DIR__, "..", "work", "phase-only-orthogonal-control.json"),
))
mkpath(dirname(output))
write(output, JSON.json(run_phase_only_control()))
println("wrote phase-only orthogonal control to $output")
