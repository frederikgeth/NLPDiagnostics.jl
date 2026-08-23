#!/usr/bin/env julia

"""Run the nonlinear matched phase-only Ipopt truth-fixture campaign."""

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
            NLPDiagnostics.SemanticLinearBlock(keys[1:2], [1, 2], variable_rotation[1:2, 1:2]),
            NLPDiagnostics.SemanticLinearBlock(keys[3:4], [3, 4], variable_rotation[3:4, 3:4]),
        ],
        constraint_blocks=[
            NLPDiagnostics.SemanticConstraintBlock(keys[1:2], [1, 2], constraint_rotation[1:2, 1:2]; set=NLPDiagnostics.ZeroEqualitySetContract()),
            NLPDiagnostics.SemanticConstraintBlock(keys[3:4], [3, 4], constraint_rotation[3:4, 3:4]; set=NLPDiagnostics.ZeroEqualitySetContract()),
        ],
    )
end

function _physical_residuals(x, target)
    t1, t2, t3, t4 = target
    return [
        x[1]^2 + x[2]^2 + 0.2 * x[3] - (t1^2 + t2^2 + 0.2 * t3),
        sin(x[1]) + x[2] + x[4] - (sin(t1) + t2 + t4),
        x[3]^2 + x[4]^2 + 0.1 * x[1] - (t3^2 + t4^2 + 0.1 * t1),
        x[1] * x[4] - x[2] * x[3] + 0.3 * x[2] - (t1 * t4 - t2 * t3 + 0.3 * t2),
    ]
end

function _build_model(variable_rotation, constraint_rotation, start, target)
    model = Model(Ipopt.Optimizer)
    set_silent(model)
    @variable(model, coordinate[1:4])
    physical = [sum(variable_rotation[row, column] * coordinate[column] for column in 1:4) for row in 1:4]
    @NLobjective(model, Min, sum((physical[row] - target[row])^2 for row in 1:4) + 0.05 * physical[1] * physical[3])
    residuals = _physical_residuals(physical, target)
    for row in 1:4
        @NLconstraint(model, sum(constraint_rotation[column, row] * residuals[column] for column in 1:4) == 0.0)
    end
    for index in 1:4
        set_start_value(coordinate[index], start[index])
    end
    set_optimizer_attribute(model, "max_iter", 150)
    set_optimizer_attribute(model, "tol", 1.0e-9)
    return model
end

function _work(run)
    records = run.trace.records
    trials = [record.line_search_trials for record in records if record.line_search_trials isa Integer]
    regularization = [record.regularization_size for record in records if record.regularization_size isa Real]
    return Dict(
        "record_count" => length(records),
        "line_search_trial_sum" => isempty(trials) ? 0 : sum(trials),
        "positive_regularization_record_count" => count(>(0), regularization),
    )
end

function _run_once(rotation_pair, physical_start, target, replicate)
    variable_rotation, constraint_rotation = rotation_pair
    model = _build_model(
        variable_rotation,
        constraint_rotation,
        transpose(variable_rotation) * physical_start,
        target,
    )
    run = NLPDiagnostics.ipopt_profile_with_iteration_trace!(model; capture_points=true)
    point = NLPDiagnostics.solver_result_point(model; label="nonlinear-$replicate-endpoint")
    isnothing(point) && error("Ipopt did not expose an endpoint")
    evaluation = NLPDiagnostics.evaluate_numerical(JuMP.backend(model), point)
    return model, run, evaluation
end

function run_campaign()
    identity = Matrix{Float64}(I, 4, 4)
    variable_rotation = _block_diagonal(_rotation(0.37), _rotation(-0.52))
    constraint_rotation = _block_diagonal(_rotation(-0.61), _rotation(0.28))
    target = [0.8, -0.4, 0.9, 1.1]
    physical_start = [0.2, 0.1, 0.2, 0.2]
    reference_map = _map("nonlinear-reference", identity, identity)
    candidate_map = _map("nonlinear-phase-only", variable_rotation, constraint_rotation)
    intervention = NLPDiagnostics.scaling_intervention_classification(reference_map, candidate_map; max_dense_entries=0)
    records = Dict{String,Any}[]
    private = Dict{Tuple{String,Int},Any}()
    for (name, pair) in (("reference", (identity, identity)), ("phase_only", (variable_rotation, constraint_rotation)))
        for replicate in 1:2
            model, run, evaluation = _run_once(pair, physical_start, target, replicate)
            record = Dict(
                "policy" => name,
                "replicate" => replicate,
                "termination" => string(termination_status(model)),
                "primal_status" => string(primal_status(model)),
                "work" => _work(run),
            )
            push!(records, record)
            private[(name, replicate)] = (evaluation=evaluation,)
        end
    end
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
    work = Dict(
        name => [record["work"] for record in records if record["policy"] == name]
        for name in ("reference", "phase_only")
    )
    return Dict(
        "schema_version" => "nlpdiagnostics-phase-only-nonlinear-ipopt-campaign-v1",
        "design" => Dict("repeats_per_policy" => 2, "magnitude_bases_held_fixed" => true, "dense_decompositions_enabled" => false, "physical_start" => physical_start),
        "intervention" => intervention,
        "endpoint_covariance" => endpoint_covariance,
        "geometry" => geometry,
        "records" => records,
        "work_comparison" => Dict("reference" => work["reference"], "phase_only" => work["phase_only"], "work_is_reported_separately_from_geometry" => true),
        "qualification" => Dict(
            "intervention_verified" => intervention["classification"] == "phase_only",
            "endpoint_covariance_passed" => endpoint_covariance["overall_covariant"],
            "geometry_gate_passed" => geometry["comparison_qualified"],
            "all_endpoints_locally_solved" => all(record["termination"] == "LOCALLY_SOLVED" for record in records),
            "does_not_establish" => ["global phase-policy superiority", "wall-time portability", "electrical phase semantics beyond the declared blocks"],
        ),
    )
end

output = abspath(get(ENV, "NLPDIAGNOSTICS_PHASE_ONLY_NONLINEAR_OUTPUT", joinpath(@__DIR__, "..", "work", "phase-only-nonlinear-ipopt-campaign.json")))
mkpath(dirname(output))
write_json(output, run_campaign())
println("wrote nonlinear phase-only Ipopt campaign to $output")
