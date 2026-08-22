#!/usr/bin/env julia

"""Run a bounded three-snapshot phase-only Ipopt campaign on a 99-bus feeder surrogate."""

using LinearAlgebra
using JSON
using JuMP
using Ipopt
import MathOptInterface as MOI
using NLPDiagnostics

const BUS_COUNT = 99
const COORDINATE_COUNT = 2 * BUS_COUNT

rotation(theta) = [cos(theta) -sin(theta); sin(theta) cos(theta)]

function block_rotation_matrix(angles)
    matrix = zeros(Float64, COORDINATE_COUNT, COORDINATE_COUNT)
    for bus in 1:BUS_COUNT
        rows = 2 * bus - 1:2 * bus
        matrix[rows, rows] .= rotation(angles[bus])
    end
    return matrix
end

function scaling_map(name, vr, cr)
    variable_blocks = NLPDiagnostics.SemanticLinearBlock[]
    constraint_blocks = NLPDiagnostics.SemanticConstraintBlock[]
    for bus in 1:BUS_COUNT
        indices = [2 * bus - 1, 2 * bus]
        keys = ["bus$(bus)_r", "bus$(bus)_i"]
        push!(variable_blocks, NLPDiagnostics.SemanticLinearBlock(keys, indices, vr[indices, indices]))
        push!(constraint_blocks, NLPDiagnostics.SemanticConstraintBlock(keys, indices, cr[indices, indices]; set=NLPDiagnostics.ZeroEqualitySetContract()))
    end
    return NLPDiagnostics.SemanticBlockScalingMap(
        name;
        variable_blocks=variable_blocks,
        constraint_blocks=constraint_blocks,
    )
end

function snapshot_target(scale, phase_bias)
    target = zeros(Float64, COORDINATE_COUNT)
    target[1:2] .= [1.04 * scale * cos(phase_bias), 1.04 * scale * sin(phase_bias)]
    for bus in 2:BUS_COUNT
        previous = 2 * (bus - 1) - 1
        current = 2 * bus - 1
        conductance = 0.995 - 0.00015 * (bus % 7)
        susceptance = 0.002 + 0.00015 * (bus % 5)
        target[current] = conductance * target[previous] - susceptance * target[previous + 1]
        target[current + 1] = susceptance * target[previous] + conductance * target[previous + 1]
    end
    return target
end

function physical_start(target, snapshot_index)
    start = copy(target)
    for bus in 1:BUS_COUNT
        index = 2 * bus - 1
        start[index] *= 1.0 + 0.012 * cos(0.17 * bus + snapshot_index)
        start[index + 1] += 0.008 * sin(0.13 * bus + snapshot_index)
    end
    return start
end

function feeder_residuals(x, target)
    residuals = Any[]
    for bus in 1:BUS_COUNT
        index = 2 * bus - 1
        push!(residuals, x[index]^2 + x[index + 1]^2 - (target[index]^2 + target[index + 1]^2))
        if bus == 1
            push!(residuals, x[index + 1] - target[index + 1])
        else
            previous = index - 2
            conductance = 0.995 - 0.00015 * (bus % 7)
            susceptance = 0.002 + 0.00015 * (bus % 5)
            push!(residuals, (x[index] - conductance * x[previous] + susceptance * x[previous + 1]) + 0.5 * (x[index + 1] - susceptance * x[previous] - conductance * x[previous + 1]))
        end
    end
    return residuals
end

function physical_coordinates(vr, coordinate)
    physical = Any[]
    for bus in 1:BUS_COUNT
        index = 2 * bus - 1
        push!(physical, vr[index, index] * coordinate[index] + vr[index, index + 1] * coordinate[index + 1])
        push!(physical, vr[index + 1, index] * coordinate[index] + vr[index + 1, index + 1] * coordinate[index + 1])
    end
    return physical
end

function build_model(vr, cr, start, target)
    model = Model(Ipopt.Optimizer)
    set_silent(model)
    @variable(model, coordinate[1:COORDINATE_COUNT])
    physical = physical_coordinates(vr, coordinate)
    @NLobjective(model, Min, 100.0 * sum((physical[index] - target[index])^2 for index in 1:COORDINATE_COUNT))
    residuals = feeder_residuals(physical, target)
    for bus in 1:BUS_COUNT
        index = 2 * bus - 1
        @NLconstraint(model, cr[index, index] * residuals[index] + cr[index + 1, index] * residuals[index + 1] == 0.0)
        @NLconstraint(model, cr[index, index + 1] * residuals[index] + cr[index + 1, index + 1] * residuals[index + 1] == 0.0)
    end
    for index in 1:COORDINATE_COUNT
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

function run_once(pair, start, target, snapshot_index, policy)
    vr, cr = pair
    model = build_model(vr, cr, transpose(vr) * start, target)
    run = NLPDiagnostics.ipopt_profile_with_iteration_trace!(model; capture_points=true)
    point = NLPDiagnostics.solver_result_point(model; label="99bus-$policy-$snapshot_index-endpoint")
    isnothing(point) && error("Ipopt did not expose a 99-bus endpoint")
    evaluation = NLPDiagnostics.evaluate_numerical(JuMP.backend(model), point)
    return model, run, evaluation
end

function run_campaign()
    identity = Matrix{Float64}(I, COORDINATE_COUNT, COORDINATE_COUNT)
    variable_angles = [0.06 + 0.025 * sin(0.11 * bus) for bus in 1:BUS_COUNT]
    constraint_angles = [-0.04 + 0.02 * cos(0.07 * bus) for bus in 1:BUS_COUNT]
    variable_rotation = block_rotation_matrix(variable_angles)
    constraint_rotation = block_rotation_matrix(constraint_angles)
    reference_map = scaling_map("99bus-reference", identity, identity)
    candidate_map = scaling_map("99bus-phase-only", variable_rotation, constraint_rotation)
    intervention = NLPDiagnostics.scaling_intervention_classification(reference_map, candidate_map; max_dense_entries=0)
    snapshots = [
        Dict("id" => "light", "scale" => 0.97, "phase_bias_radians" => -0.008),
        Dict("id" => "nominal", "scale" => 1.00, "phase_bias_radians" => 0.000),
        Dict("id" => "heavy", "scale" => 1.03, "phase_bias_radians" => 0.008),
    ]
    results = Dict{String,Any}[]
    for (snapshot_index, snapshot_spec) in enumerate(snapshots)
        target = snapshot_target(snapshot_spec["scale"], snapshot_spec["phase_bias_radians"])
        start = physical_start(target, snapshot_index)
        private = Dict{String,Any}()
        for (policy, pair) in (("reference", (identity, identity)), ("phase_only", (variable_rotation, constraint_rotation)))
            model, run, evaluation = run_once(pair, start, target, snapshot_index, policy)
            private[policy] = (model=model, evaluation=evaluation, work=work(run))
        end
        covariance = NLPDiagnostics.scaling_covariance_report(
            private["reference"].evaluation,
            reference_map,
            private["phase_only"].evaluation,
            candidate_map;
            max_dense_entries=0,
        )
        geometry = NLPDiagnostics.scaling_coordinate_geometry_report(
            private["reference"].evaluation,
            reference_map,
            private["phase_only"].evaluation,
            candidate_map;
            max_dense_entries=0,
        )
        reference_work = private["reference"].work
        phase_only_work = private["phase_only"].work
        push!(results, Dict(
            "snapshot" => snapshot_spec["id"],
            "scale" => snapshot_spec["scale"],
            "phase_bias_radians" => snapshot_spec["phase_bias_radians"],
            "reference" => Dict("termination" => string(termination_status(private["reference"].model)), "work" => reference_work),
            "phase_only" => Dict("termination" => string(termination_status(private["phase_only"].model)), "work" => phase_only_work),
            "endpoint_covariance_passed" => covariance["overall_covariant"] === true,
            "geometry_gate_passed" => geometry["comparison_qualified"] === true,
            "work_delta" => Dict(
                "record_count" => phase_only_work["record_count"] - reference_work["record_count"],
                "line_search_trial_sum" => phase_only_work["line_search_trial_sum"] - reference_work["line_search_trial_sum"],
                "positive_regularization_record_count" => phase_only_work["positive_regularization_record_count"] - reference_work["positive_regularization_record_count"],
            ),
        ))
    end
    all_locally_solved = all(
        row["reference"]["termination"] == "LOCALLY_SOLVED" && row["phase_only"]["termination"] == "LOCALLY_SOLVED"
        for row in results
    )
    return Dict(
        "schema_version" => "nlpdiagnostics-phase-only-99bus-snapshot-campaign-v1",
        "design" => Dict(
            "bus_count" => BUS_COUNT,
            "snapshot_count" => length(snapshots),
            "policies_per_snapshot" => 2,
            "magnitude_bases_held_fixed" => true,
            "dense_decompositions_enabled" => false,
            "fixture" => "99-bus radial feeder surrogate with nonlinear voltage magnitudes and branch-drop projections",
        ),
        "intervention" => intervention,
        "snapshots" => results,
        "qualification" => Dict(
            "intervention_verified" => intervention["classification"] == "phase_only",
            "all_snapshot_covariance_gates_passed" => all(row["endpoint_covariance_passed"] for row in results),
            "all_snapshot_geometry_gates_passed" => all(row["geometry_gate_passed"] for row in results),
            "all_endpoints_locally_solved" => all_locally_solved,
            "does_not_establish" => ["global phase-policy superiority", "wall-time portability", "causal mechanism", "full 99-bus network semantics", "automatic policy safety"],
        ),
    )
end

output = abspath(get(ENV, "NLPDIAGNOSTICS_PHASE_ONLY_99BUS_OUTPUT", joinpath(@__DIR__, "..", "work", "phase-only-99bus-snapshot-campaign.json")))
mkpath(dirname(output))
write(output, JSON.json(run_campaign()))
println("wrote 99-bus phase-only snapshot campaign to $output")
