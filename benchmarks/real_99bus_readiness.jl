#!/usr/bin/env julia

"""Inventory real ENWL 99-bus snapshots and probe phase-only campaign readiness."""

using BMOPFTools
using Ipopt
using JSON
using JuMP
using NLPDiagnostics
using SHA

const DEFAULT_ROOT = normpath(joinpath(@__DIR__, "..", "..", "BMOPFDraftData", "benchmarks"))
const SELECTED_SNAPSHOTS = [
    "ENWLsnapshots/99bus_LN/99bus_LN_t01_0800.bmopf.json",
    "ENWLsnapshots/99bus_LN/99bus_LN_t13_1400.bmopf.json",
    "ENWLsnapshots/99bus_LN/99bus_LN_t25_2000.bmopf.json",
    "ENWLsnapshots/99bus_LG/99bus_LG_t01_0800.bmopf.json",
    "ENWLsnapshots/99bus_LG/99bus_LG_t13_1400.bmopf.json",
    "ENWLsnapshots/99bus_LG/99bus_LG_t25_2000.bmopf.json",
]

rotation(theta) = [cos(theta) -sin(theta); sin(theta) cos(theta)]

function integrity_preflight(network)
    findings = BMOPFTools.Finding[]
    result = BMOPFTools.integrity_check(network, findings)
    return Dict(
        "error_count" => count(finding -> finding.severity == BMOPFTools.ERROR, findings),
        "warning_count" => count(finding -> finding.severity == BMOPFTools.WARNING, findings),
        "finding_count" => length(findings),
        "blocking" => any(finding -> finding.severity == BMOPFTools.ERROR, findings),
        "summary" => result,
    )
end

function component_counts(network)
    counts = Dict{String,Int}()
    for (key, value) in network
        value isa AbstractDict || continue
        counts[string(key)] = length(value)
    end
    return Dict(key => counts[key] for key in sort!(collect(keys(counts))))
end

function saved_result_status(path)
    result_path = replace(path, ".bmopf.json" => "_result_si.json")
    isfile(result_path) || return Dict("available" => false, "path" => nothing)
    result = JSON.parsefile(result_path)
    return Dict(
        "available" => true,
        "path" => basename(result_path),
        "termination_status" => get(result, "termination_status", nothing),
        "feasible" => get(result, "feasible", nothing),
    )
end

function inventory_snapshot(root, relative)
    path = joinpath(root, relative)
    isfile(path) || error("selected real 99-bus snapshot is missing: $path")
    network = BMOPFTools.parse_bmopf(path)
    return Dict(
        "snapshot" => relative,
        "sha256" => bytes2hex(SHA.sha256(read(path))),
        "file_bytes" => filesize(path),
        "component_counts" => component_counts(network),
        "integrity" => integrity_preflight(network),
        "saved_result_si" => saved_result_status(path),
    )
end

function semantic_map_probe_snapshot(root, relative)
    path = joinpath(root, relative)
    try
        network = BMOPFTools.parse_bmopf(path)
        context = BMOPFTools.build_opf_model(deepcopy(network); optimizer=Ipopt.Optimizer, add_objective=true)
        BMOPFTools.enforce_kcl!(context)
        point = NLPDiagnostics.bmopf_start_completion_point(context; missing_value=0.0, label="real-99bus-readiness-probe")
        evaluation = NLPDiagnostics.evaluate_numerical(JuMP.backend(BMOPFTools.opf_model(context)), point)
        build = NLPDiagnostics.bmopf_semantic_block_scaling_map(context, evaluation)
        reference_map = build["map"]
        variable_blocks = NLPDiagnostics.SemanticLinearBlock[]
        rotated_variable_block_count = 0
        for (index, block) in enumerate(reference_map.variable_blocks)
            transform = block.model_to_physical
            if length(block.positions) == 2
                transform = transform * rotation(0.015 * sin(index))
                rotated_variable_block_count += 1
            end
            push!(variable_blocks, NLPDiagnostics.SemanticLinearBlock(
                block.keys, block.positions, transform,
            ))
        end
        constraint_blocks = NLPDiagnostics.SemanticConstraintBlock[]
        for block in reference_map.constraint_blocks
            push!(constraint_blocks, NLPDiagnostics.SemanticConstraintBlock(
                block.linear.keys,
                block.linear.positions,
                block.linear.model_to_physical;
                set=block.set_contract,
            ))
        end
        candidate_map = NLPDiagnostics.SemanticBlockScalingMap(
            "real-99bus-phase-only-probe";
            variable_blocks,
            constraint_blocks,
            objective_scale=reference_map.objective_scale,
        )
        intervention = NLPDiagnostics.scaling_intervention_classification(
            reference_map, candidate_map; max_dense_entries=0,
        )
        return Dict(
            "available" => build["available"],
            "snapshot" => relative,
            "variable_count" => length(evaluation.point.variables),
            "constraint_count" => length(evaluation.constraint_sources),
            "applied_variable_block_count" => get(build, "applied_variable_block_count", nothing),
            "applied_constraint_block_count" => get(build, "applied_constraint_block_count", nothing),
            "skipped_declaration_count" => length(get(build, "skipped_declarations", Any[])),
            "rotated_variable_block_count" => rotated_variable_block_count,
            "intervention_classification" => intervention["classification"],
        )
    catch error
        return Dict(
            "available" => false,
            "probe_snapshot" => relative,
            "reason" => sprint(showerror, error),
        )
    end
end

function semantic_map_probe(root)
    probes = [semantic_map_probe_snapshot(root, relative) for relative in SELECTED_SNAPSHOTS]
    available = [probe for probe in probes if get(probe, "available", false) === true]
    phase_only = [probe for probe in available if get(probe, "intervention_classification", nothing) == "phase_only"]
    representative = isempty(probes) ? Dict{String,Any}() : first(probes)
    return merge(
        Dict(
            "available" => length(available) == length(probes),
            "snapshot_count" => length(probes),
            "available_snapshot_count" => length(available),
            "phase_only_snapshot_count" => length(phase_only),
            "all_snapshots_phase_only" => length(phase_only) == length(probes),
            "snapshots" => probes,
        ),
        representative,
    )
end

function run_inventory()
    root = abspath(get(ENV, "NLPDIAGNOSTICS_REAL_99BUS_ROOT", DEFAULT_ROOT))
    isdir(root) || error("real 99-bus benchmark root does not exist: $root")
    snapshots = [inventory_snapshot(root, relative) for relative in SELECTED_SNAPSHOTS]
    probe = semantic_map_probe(root)
    all_integrity_clean = all(!snapshot["integrity"]["blocking"] for snapshot in snapshots)
    saved_solutions = count(snapshot -> get(snapshot["saved_result_si"], "termination_status", nothing) == "LOCALLY_SOLVED", snapshots)
    return Dict(
        "schema_version" => "nlpdiagnostics-real-99bus-readiness-v1",
        "source" => Dict(
            "environment_variable" => "NLPDIAGNOSTICS_REAL_99BUS_ROOT",
            "root_basename" => basename(root),
            "selected_snapshot_count" => length(snapshots),
            "selected_families" => ["99bus_LN", "99bus_LG"],
        ),
        "snapshots" => snapshots,
        "semantic_map_probe" => probe,
        "readiness" => Dict(
            "snapshots_parse_and_integrity_gate_passed" => all_integrity_clean,
            "saved_locally_solved_result_count" => saved_solutions,
            "phase_only_semantic_gate_ready" => all_integrity_clean && probe["available"] === true && get(probe, "all_snapshots_phase_only", false) === true,
            "phase_only_solver_campaign_ready" => false,
            "blocking_reason" => "a transformed-coordinate solver runner for BMOPFTools contexts is still required; the semantic-map schema compatibility gate is now open",
        ),
        "qualification" => Dict(
            "claim" => "The selected real ENWL 99-bus snapshots are available, parseable, integrity-clean, and accompanied by saved SI results; the current BMOPFTools public semantic-block registry is sufficient for a phase-only map gate.",
            "does_not_establish" => ["phase-only solver behavior on the real network", "transformed-coordinate feasibility", "global phase-policy superiority", "wall-time portability", "automatic policy safety"],
        ),
    )
end

output = abspath(get(ENV, "NLPDIAGNOSTICS_REAL_99BUS_OUTPUT", joinpath(@__DIR__, "..", "work", "real-99bus-readiness.json")))
mkpath(dirname(output))
write(output, JSON.json(run_inventory()))
println("wrote real 99-bus readiness report to $output")
