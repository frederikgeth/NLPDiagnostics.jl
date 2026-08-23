#!/usr/bin/env julia

"""Run a small matched Ipopt phase-only campaign.

The reference and candidate models represent the same quadratic problem. The
candidate rotates two two-coordinate variable blocks and two equality blocks,
while holding every magnitude basis and objective scale fixed. Each policy is
solved from the same physical start transported into its coordinates.
"""

using LinearAlgebra
using JuMP
using Ipopt
import MathOptInterface as MOI
using NLPDiagnostics
Base.include(@__MODULE__, joinpath(@__DIR__, "common.jl"))
using .NLPDiagnosticsBenchmarkCommon: write_json

function _rotation(theta)
    return [cos(theta) -sin(theta); sin(theta) cos(theta)]
end

function _block_diagonal(first, second)
    return [first zeros(2, 2); zeros(2, 2) second]
end

function _map(name, variable_rotation, constraint_rotation)
    keys = ["v1r", "v1i", "v2r", "v2i"]
    identity = Matrix{Float64}(I, 2, 2)
    return NLPDiagnostics.SemanticBlockScalingMap(
        name;
        variable_blocks=[
            NLPDiagnostics.SemanticLinearBlock(
                keys[1:2], [1, 2], variable_rotation[1:2, 1:2],
            ),
            NLPDiagnostics.SemanticLinearBlock(
                keys[3:4], [3, 4], variable_rotation[3:4, 3:4],
            ),
        ],
        constraint_blocks=[
            NLPDiagnostics.SemanticConstraintBlock(
                keys[1:2], [1, 2], constraint_rotation[1:2, 1:2];
                set=NLPDiagnostics.ZeroEqualitySetContract(),
            ),
            NLPDiagnostics.SemanticConstraintBlock(
                keys[3:4], [3, 4], constraint_rotation[3:4, 3:4];
                set=NLPDiagnostics.ZeroEqualitySetContract(),
            ),
        ],
    )
end

function _build_model(variable_rotation, constraint_rotation, start, target, A, b)
    model = Model(Ipopt.Optimizer)
    set_silent(model)
    @variable(model, coordinate[1:4])
    physical = [
        sum(variable_rotation[row, column] * coordinate[column] for column in 1:4)
        for row in 1:4
    ]
    @objective(model, Min, sum((physical[row] - target[row])^2 for row in 1:4))
    @constraint(model, [row in 1:4],
        sum(
            constraint_rotation[column, row] *
            (sum(A[column, j] * physical[j] for j in 1:4) - b[column])
            for column in 1:4
        ) == 0.0,
    )
    for index in 1:4
        set_start_value(coordinate[index], start[index])
    end
    set_optimizer_attribute(model, "max_iter", 100)
    set_optimizer_attribute(model, "tol", 1.0e-9)
    return model
end

function _point(model, label)
    point = NLPDiagnostics.solver_result_point(model; label)
    isnothing(point) && error("solver did not expose a point for $label")
    return point
end

function _work(run)
    records = run.trace.records
    line_search = [record.line_search_trials for record in records
        if record.line_search_trials isa Integer]
    regularization = [record.regularization_size for record in records
        if record.regularization_size isa Real]
    return Dict{String,Any}(
        "record_count" => length(records),
        "line_search_trial_sum" => isempty(line_search) ? 0 : sum(line_search),
        "positive_regularization_record_count" => count(
            value -> value > 0, regularization,
        ),
    )
end

function _run_once(policy, replicate, physical_start, target, A, b)
    variable_rotation, constraint_rotation = policy
    coordinate_start = transpose(variable_rotation) * physical_start
    model = _build_model(
        variable_rotation,
        constraint_rotation,
        coordinate_start,
        target,
        A,
        b,
    )
    run = NLPDiagnostics.ipopt_profile_with_iteration_trace!(
        model;
        capture_points=true,
    )
    endpoint = _point(model, "$replicate-endpoint")
    evaluation = NLPDiagnostics.evaluate_numerical(
        JuMP.backend(model), endpoint,
    )
    return model, run, endpoint, evaluation
end

function run_campaign()
    identity = Matrix{Float64}(I, 4, 4)
    phase_variable = _block_diagonal(_rotation(0.37), _rotation(-0.52))
    phase_constraint = _block_diagonal(_rotation(-0.61), _rotation(0.28))
    policies = [
        ("reference", identity, identity),
        ("phase_only", phase_variable, phase_constraint),
    ]
    target = [1.0, -0.5, 0.8, 1.2]
    physical_start = [0.2, 0.1, 0.2, 0.2]
    A = [
        2.0 0.5 0.3 -0.2
        -1.0 3.0 0.4 0.7
        0.8 -0.1 1.5 0.2
        0.2 0.6 -0.7 2.5
    ]
    b = A * target
    reference_map = _map("reference", identity, identity)
    candidate_map = _map("phase-only", phase_variable, phase_constraint)
    intervention = NLPDiagnostics.scaling_intervention_classification(
        reference_map, candidate_map; max_dense_entries=0,
    )
    records = Dict{String,Any}[]
    private = Dict{Tuple{String,Int},Any}()
    for (name, variable_rotation, constraint_rotation) in policies
        for replicate in 1:2
            model, run, endpoint, evaluation = _run_once(
                (variable_rotation, constraint_rotation),
                replicate,
                physical_start,
                target,
                A,
                b,
            )
            push!(records, Dict{String,Any}(
                "policy" => name,
                "replicate" => replicate,
                "termination" => string(termination_status(model)),
                "primal_status" => string(primal_status(model)),
                "work" => _work(run),
            ))
            private[(name, replicate)] = (
                model=model,
                run=run,
                endpoint=endpoint,
                evaluation=evaluation,
            )
        end
    end
    # Endpoint covariance is the matched physical contract; the initial
    # geometry is checked independently from solver work.
    endpoint_covariance = NLPDiagnostics.scaling_covariance_report(
        private[("reference", 1)].evaluation,
        reference_map,
        private[("phase_only", 1)].evaluation,
        candidate_map;
        max_dense_entries=0,
    )
    geometry = NLPDiagnostics.scaling_coordinate_geometry_report(
        private[("reference", 1)].evaluation,
        reference_map,
        private[("phase_only", 1)].evaluation,
        candidate_map;
        max_dense_entries=0,
    )
    reference_work = [record["work"] for record in records
        if record["policy"] == "reference"]
    candidate_work = [record["work"] for record in records
        if record["policy"] == "phase_only"]
    return Dict{String,Any}(
        "schema_version" => "nlpdiagnostics-phase-only-ipopt-campaign-v1",
        "design" => Dict(
            "repeats_per_policy" => 2,
            "magnitude_bases_held_fixed" => true,
            "dense_decompositions_enabled" => false,
            "physical_start" => physical_start,
        ),
        "intervention" => intervention,
        "endpoint_covariance" => endpoint_covariance,
        "geometry" => geometry,
        "records" => records,
        "work_comparison" => Dict(
            "reference" => reference_work,
            "phase_only" => candidate_work,
            "work_is_reported_separately_from_geometry" => true,
        ),
        "qualification" => Dict(
            "intervention_verified" => intervention["classification"] == "phase_only",
            "endpoint_covariance_passed" =>
                endpoint_covariance["overall_covariant"],
            "geometry_gate_passed" => geometry["comparison_qualified"],
            "all_endpoints_accepted" => all(
                record["termination"] == "LOCALLY_SOLVED" ||
                record["termination"] == "LOCALLY_OPTIMAL" for record in records
            ),
            "does_not_establish" => [
                "global phase-policy superiority",
                "wall-time portability",
                "electrical phase semantics beyond the declared blocks",
            ],
        ),
    )
end

output = abspath(get(
    ENV,
    "NLPDIAGNOSTICS_PHASE_ONLY_IPOPT_OUTPUT",
    joinpath(@__DIR__, "..", "work", "phase-only-ipopt-campaign.json"),
))
mkpath(dirname(output))
write_json(output, run_campaign())
println("wrote phase-only Ipopt campaign to $output")
