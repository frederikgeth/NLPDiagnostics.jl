#!/usr/bin/env julia

"""Run a fixed-magnitude phase-only Ipopt campaign on a radial feeder fixture."""

using LinearAlgebra
using JSON
using JuMP
using Ipopt
import MathOptInterface as MOI
using NLPDiagnostics

rotation(theta) = [cos(theta) -sin(theta); sin(theta) cos(theta)]

function blockdiag(a, b, c)
    return [a zeros(2, 2) zeros(2, 2); zeros(2, 2) b zeros(2, 2); zeros(2, 2) zeros(2, 2) c]
end

function scaling_map(name, vr, cr)
    keys = ["slack_r", "slack_i", "mid_r", "mid_i", "end_r", "end_i"]
    return NLPDiagnostics.SemanticBlockScalingMap(
        name;
        variable_blocks=[
            NLPDiagnostics.SemanticLinearBlock(keys[1:2], [1, 2], vr[1:2, 1:2]),
            NLPDiagnostics.SemanticLinearBlock(keys[3:4], [3, 4], vr[3:4, 3:4]),
            NLPDiagnostics.SemanticLinearBlock(keys[5:6], [5, 6], vr[5:6, 5:6]),
        ],
        constraint_blocks=[
            NLPDiagnostics.SemanticConstraintBlock(keys[1:2], [1, 2], cr[1:2, 1:2]; set=NLPDiagnostics.ZeroEqualitySetContract()),
            NLPDiagnostics.SemanticConstraintBlock(keys[3:4], [3, 4], cr[3:4, 3:4]; set=NLPDiagnostics.ZeroEqualitySetContract()),
            NLPDiagnostics.SemanticConstraintBlock(keys[5:6], [5, 6], cr[5:6, 5:6]; set=NLPDiagnostics.ZeroEqualitySetContract()),
        ],
    )
end

function feeder_residuals(x, target)
    t1, t2, t3, t4, t5, t6 = target
    return [
        x[1]^2 + x[2]^2 - (t1^2 + t2^2),
        x[3]^2 + x[4]^2 - (t3^2 + t4^2),
        x[5]^2 + x[6]^2 - (t5^2 + t6^2),
        x[3] - (0.97 * x[1] - 0.04 * x[2]),
        x[4] - (0.04 * x[1] + 0.97 * x[2]),
        (x[5] - 0.96 * x[3] + 0.03 * x[4]) + 0.5 * (x[6] - 0.03 * x[3] - 0.96 * x[4]),
    ]
end

function build_model(vr, cr, start, target)
    model = Model(Ipopt.Optimizer)
    set_silent(model)
    @variable(model, coordinate[1:6])
    x = [sum(vr[row, col] * coordinate[col] for col in 1:6) for row in 1:6]
    # A pure target objective fixes the otherwise free common feeder phase and
    # makes the physical endpoint deterministic across rotated coordinates.
    @NLobjective(model, Min, 100.0 * sum((x[row] - target[row])^2 for row in 1:6))
    residuals = feeder_residuals(x, target)
    for row in 1:6
        @NLconstraint(model, sum(cr[col, row] * residuals[col] for col in 1:6) == 0.0)
    end
    for index in 1:6
        set_start_value(coordinate[index], start[index])
    end
    set_optimizer_attribute(model, "max_iter", 150)
    set_optimizer_attribute(model, "tol", 1.0e-9)
    return model
end

function work(run)
    records = run.trace.records
    trials = [record.line_search_trials for record in records if record.line_search_trials isa Integer]
    regularization = [record.regularization_size for record in records if record.regularization_size isa Real]
    return Dict(
        "record_count" => length(records),
        "line_search_trial_sum" => isempty(trials) ? 0 : sum(trials),
        "positive_regularization_record_count" => count(>(0), regularization),
    )
end

function run_once(pair, physical_start, target, replicate)
    vr, cr = pair
    model = build_model(vr, cr, transpose(vr) * physical_start, target)
    run = NLPDiagnostics.ipopt_profile_with_iteration_trace!(model; capture_points=true)
    point = NLPDiagnostics.solver_result_point(model; label="feeder-$replicate-endpoint")
    isnothing(point) && error("Ipopt did not expose a feeder endpoint")
    evaluation = NLPDiagnostics.evaluate_numerical(JuMP.backend(model), point)
    return model, run, evaluation
end

function run_campaign()
    identity = Matrix{Float64}(I, 6, 6)
    variable_rotation = blockdiag(rotation(0.22), rotation(-0.31), rotation(0.17))
    constraint_rotation = blockdiag(rotation(-0.41), rotation(0.19), rotation(-0.27))
    slack = [1.02, 0.0]
    mid = [0.97 * slack[1] - 0.04 * slack[2], 0.04 * slack[1] + 0.97 * slack[2]]
    ending = [0.96 * mid[1] - 0.03 * mid[2], 0.03 * mid[1] + 0.96 * mid[2]]
    target = vcat(slack, mid, ending)
    physical_start = [1.0, 0.05, 0.96, 0.08, 0.91, 0.12]
    reference_map = scaling_map("feeder-reference", identity, identity)
    candidate_map = scaling_map("feeder-phase-only", variable_rotation, constraint_rotation)
    intervention = NLPDiagnostics.scaling_intervention_classification(reference_map, candidate_map; max_dense_entries=0)
    records = Dict{String,Any}[]
    private = Dict{Tuple{String,Int},Any}()
    for (name, pair) in (("reference", (identity, identity)), ("phase_only", (variable_rotation, constraint_rotation)))
        for replicate in 1:2
            model, run, evaluation = run_once(pair, physical_start, target, replicate)
            push!(records, Dict(
                "policy" => name,
                "replicate" => replicate,
                "termination" => string(termination_status(model)),
                "work" => work(run),
            ))
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
    return Dict(
        "schema_version" => "nlpdiagnostics-phase-only-feeder-ipopt-campaign-v1",
        "design" => Dict(
            "repeats_per_policy" => 2,
            "magnitude_bases_held_fixed" => true,
            "dense_decompositions_enabled" => false,
            "fixture" => "three-bus radial feeder with nonlinear voltage magnitudes and branch-drop projections",
            "physical_start" => physical_start,
        ),
        "intervention" => intervention,
        "endpoint_covariance" => endpoint_covariance,
        "geometry" => geometry,
        "records" => records,
        "qualification" => Dict(
            "intervention_verified" => intervention["classification"] == "phase_only",
            "endpoint_covariance_passed" => endpoint_covariance["overall_covariant"],
            "geometry_gate_passed" => geometry["comparison_qualified"],
            "all_endpoints_locally_solved" => all(record["termination"] == "LOCALLY_SOLVED" for record in records),
            "does_not_establish" => ["global phase-policy superiority", "wall-time portability", "full feeder network semantics"],
        ),
    )
end

output = abspath(get(ENV, "NLPDIAGNOSTICS_PHASE_ONLY_FEEDER_OUTPUT", joinpath(@__DIR__, "..", "work", "phase-only-feeder-ipopt-campaign.json")))
mkpath(dirname(output))
write(output, JSON.json(run_campaign()))
println("wrote feeder phase-only Ipopt campaign to $output")
