#!/usr/bin/env julia

"""Run a fixed-magnitude phase-only Ipopt campaign with a droop-like control equation."""

using LinearAlgebra
using JSON
using JuMP
using Ipopt
import MathOptInterface as MOI
using NLPDiagnostics

rotation(theta) = [cos(theta) -sin(theta); sin(theta) cos(theta)]
blockdiag(a, b) = [a zeros(2, 2); zeros(2, 2) b]

function scaling_map(name, vr, cr)
    keys = ["v1r", "v1i", "v2r", "v2i"]
    return NLPDiagnostics.SemanticBlockScalingMap(
        name;
        variable_blocks=[
            NLPDiagnostics.SemanticLinearBlock(keys[1:2], [1, 2], vr[1:2, 1:2]),
            NLPDiagnostics.SemanticLinearBlock(keys[3:4], [3, 4], vr[3:4, 3:4]),
        ],
        constraint_blocks=[
            NLPDiagnostics.SemanticConstraintBlock(keys[1:2], [1, 2], cr[1:2, 1:2]; set=NLPDiagnostics.ZeroEqualitySetContract()),
            NLPDiagnostics.SemanticConstraintBlock(keys[3:4], [3, 4], cr[3:4, 3:4]; set=NLPDiagnostics.ZeroEqualitySetContract()),
        ],
    )
end

function residuals(x, target)
    t1, t2, t3, t4 = target
    return [
        x[1]^2 + x[2]^2 + 0.2 * x[3] - (t1^2 + t2^2 + 0.2 * t3),
        sin(x[1]) + x[2] + x[4] - (sin(t1) + t2 + t4),
        x[3] + 0.05 * (x[1]^2 + x[2]^2) + 0.1 * x[4] - (t3 + 0.05 * (t1^2 + t2^2) + 0.1 * t4),
        x[1] * x[4] - x[2] * x[3] + 0.3 * x[2] - (t1 * t4 - t2 * t3 + 0.3 * t2),
    ]
end

function build_model(vr, cr, start, target)
    model = Model(Ipopt.Optimizer)
    set_silent(model)
    @variable(model, coordinate[1:4])
    x = [sum(vr[row, col] * coordinate[col] for col in 1:4) for row in 1:4]
    @NLobjective(model, Min, sum((x[row] - target[row])^2 for row in 1:4) + 0.05 * x[1] * x[3])
    g = residuals(x, target)
    for row in 1:4
        @NLconstraint(model, sum(cr[col, row] * g[col] for col in 1:4) == 0.0)
    end
    for index in 1:4
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
    return Dict("record_count" => length(records), "line_search_trial_sum" => isempty(trials) ? 0 : sum(trials), "positive_regularization_record_count" => count(>(0), regularization))
end

function run_once(pair, start, target, replicate)
    vr, cr = pair
    model = build_model(vr, cr, transpose(vr) * start, target)
    run = NLPDiagnostics.ipopt_profile_with_iteration_trace!(model; capture_points=true)
    point = NLPDiagnostics.solver_result_point(model; label="controller-$replicate-endpoint")
    isnothing(point) && error("Ipopt did not expose a controller endpoint")
    evaluation = NLPDiagnostics.evaluate_numerical(JuMP.backend(model), point)
    return model, run, evaluation
end

function run_campaign()
    identity = Matrix{Float64}(I, 4, 4)
    vr = blockdiag(rotation(0.37), rotation(-0.52))
    cr = blockdiag(rotation(-0.61), rotation(0.28))
    target = [0.8, -0.4, 0.9, 1.1]
    start = [0.2, 0.1, 0.2, 0.2]
    reference_map = scaling_map("controller-reference", identity, identity)
    candidate_map = scaling_map("controller-phase-only", vr, cr)
    intervention = NLPDiagnostics.scaling_intervention_classification(reference_map, candidate_map; max_dense_entries=0)
    records = Dict{String,Any}[]
    private = Dict{Tuple{String,Int},Any}()
    for (name, pair) in (("reference", (identity, identity)), ("phase_only", (vr, cr)))
        for replicate in 1:2
            model, run, evaluation = run_once(pair, start, target, replicate)
            push!(records, Dict("policy" => name, "replicate" => replicate, "termination" => string(termination_status(model)), "work" => work(run)))
            private[(name, replicate)] = (evaluation=evaluation,)
        end
    end
    covariance = NLPDiagnostics.scaling_covariance_report(private[("reference", 1)].evaluation, reference_map, private[("phase_only", 1)].evaluation, candidate_map; max_dense_entries=0)
    geometry = NLPDiagnostics.scaling_coordinate_geometry_report(private[("reference", 1)].evaluation, reference_map, private[("phase_only", 1)].evaluation, candidate_map; max_dense_entries=0)
    return Dict(
        "schema_version" => "nlpdiagnostics-phase-only-controller-ipopt-campaign-v1",
        "design" => Dict("repeats_per_policy" => 2, "magnitude_bases_held_fixed" => true, "dense_decompositions_enabled" => false, "controller_equation" => "smooth droop-like active-power/voltage coupling", "physical_start" => start),
        "intervention" => intervention,
        "endpoint_covariance" => covariance,
        "geometry" => geometry,
        "records" => records,
        "qualification" => Dict(
            "intervention_verified" => intervention["classification"] == "phase_only",
            "endpoint_covariance_passed" => covariance["overall_covariant"],
            "geometry_gate_passed" => geometry["comparison_qualified"],
            "all_endpoints_locally_solved" => all(record["termination"] == "LOCALLY_SOLVED" for record in records),
            "does_not_establish" => ["global phase-policy superiority", "wall-time portability", "full BMOPF droop-controller semantics"],
        ),
    )
end

output = abspath(get(ENV, "NLPDIAGNOSTICS_PHASE_ONLY_CONTROLLER_OUTPUT", joinpath(@__DIR__, "..", "work", "phase-only-controller-ipopt-campaign.json")))
mkpath(dirname(output))
write(output, JSON.json(run_campaign()))
println("wrote controller phase-only Ipopt campaign to $output")
