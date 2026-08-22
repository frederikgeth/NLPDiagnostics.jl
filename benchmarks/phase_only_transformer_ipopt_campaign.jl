#!/usr/bin/env julia

"""Run a fixed-magnitude phase-only Ipopt campaign on a transformer truth fixture."""

using LinearAlgebra
using JSON
using JuMP
using Ipopt
import MathOptInterface as MOI
using NLPDiagnostics

rotation(theta) = [cos(theta) -sin(theta); sin(theta) cos(theta)]
blockdiag(a, b) = [a zeros(2, 2); zeros(2, 2) b]

function scaling_map(name, vr, cr)
    keys = ["primary_r", "primary_i", "secondary_r", "secondary_i"]
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

function transformer_residuals(x, target)
    ratio = 0.1
    phase_shift = 0.18
    t1, t2, t3, t4 = target
    return [
        x[1]^2 + x[2]^2 - (t1^2 + t2^2),
        x[3]^2 + x[4]^2 - (t3^2 + t4^2),
        x[3] - ratio * (cos(phase_shift) * x[1] - sin(phase_shift) * x[2]),
        x[4] - ratio * (sin(phase_shift) * x[1] + cos(phase_shift) * x[2]),
    ]
end

function build_model(vr, cr, start, target)
    model = Model(Ipopt.Optimizer)
    set_silent(model)
    @variable(model, coordinate[1:4])
    x = [sum(vr[row, col] * coordinate[col] for col in 1:4) for row in 1:4]
    # A pure target objective removes the otherwise free common winding phase
    # from the magnitude/turns-ratio manifold, making the physical endpoint
    # contract deterministic across rotated coordinates.
    @NLobjective(model, Min, 100.0 * sum((x[row] - target[row])^2 for row in 1:4))
    g = transformer_residuals(x, target)
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
    point = NLPDiagnostics.solver_result_point(model; label="transformer-$replicate-endpoint")
    isnothing(point) && error("Ipopt did not expose a transformer endpoint")
    evaluation = NLPDiagnostics.evaluate_numerical(JuMP.backend(model), point)
    return model, run, evaluation
end

function run_campaign()
    identity = Matrix{Float64}(I, 4, 4)
    vr = blockdiag(rotation(0.37), rotation(-0.52))
    cr = blockdiag(rotation(-0.61), rotation(0.28))
    # 230 V primary, 23 V secondary with a fixed winding phase shift.
    target = [230.0, 0.0, 0.1 * 230.0 * cos(0.18), 0.1 * 230.0 * sin(0.18)]
    start = [200.0, 10.0, 18.0, 4.0]
    reference_map = scaling_map("transformer-reference", identity, identity)
    candidate_map = scaling_map("transformer-phase-only", vr, cr)
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
    covariance = NLPDiagnostics.scaling_covariance_report(private[("reference", 1)].evaluation, reference_map, private[("phase_only", 1)].evaluation, candidate_map; absolute_tolerance=1.0e-5, relative_tolerance=1.0e-6, max_dense_entries=1000)
    geometry = NLPDiagnostics.scaling_coordinate_geometry_report(private[("reference", 1)].evaluation, reference_map, private[("phase_only", 1)].evaluation, candidate_map; absolute_tolerance=1.0e-5, relative_tolerance=1.0e-6, max_dense_entries=1000)
    return Dict(
        "schema_version" => "nlpdiagnostics-phase-only-transformer-ipopt-campaign-v1",
        "design" => Dict("repeats_per_policy" => 2, "magnitude_bases_held_fixed" => true, "dense_decompositions_enabled" => false, "primary_voltage" => 230.0, "secondary_voltage" => 23.0, "turns_ratio" => 0.1, "phase_shift_radians" => 0.18, "physical_start" => start),
        "intervention" => intervention,
        "endpoint_covariance" => covariance,
        "geometry" => geometry,
        "records" => records,
        "qualification" => Dict(
            "intervention_verified" => intervention["classification"] == "phase_only",
            "endpoint_covariance_passed" => covariance["overall_covariant"],
            "geometry_gate_passed" => geometry["comparison_qualified"],
            "all_endpoints_locally_solved" => all(record["termination"] == "LOCALLY_SOLVED" for record in records),
            "does_not_establish" => ["global phase-policy superiority", "wall-time portability", "full transformer connection-matrix semantics"],
        ),
    )
end

output = abspath(get(ENV, "NLPDIAGNOSTICS_PHASE_ONLY_TRANSFORMER_OUTPUT", joinpath(@__DIR__, "..", "work", "phase-only-transformer-ipopt-campaign.json")))
mkpath(dirname(output))
write(output, JSON.json(run_campaign()))
println("wrote transformer phase-only Ipopt campaign to $output")
