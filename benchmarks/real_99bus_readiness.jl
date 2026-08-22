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

function semantic_map_probe(root)
    relative = SELECTED_SNAPSHOTS[1]
    path = joinpath(root, relative)
    try
        network = BMOPFTools.parse_bmopf(path)
        context = BMOPFTools.build_opf_model(deepcopy(network); optimizer=Ipopt.Optimizer, add_objective=true)
        BMOPFTools.enforce_kcl!(context)
        point = NLPDiagnostics.bmopf_start_completion_point(context; missing_value=0.0, label="real-99bus-readiness-probe")
        evaluation = NLPDiagnostics.evaluate_numerical(JuMP.backend(BMOPFTools.opf_model(context)), point)
        build = NLPDiagnostics.bmopf_semantic_block_scaling_map(context, evaluation)
        return Dict(
            "available" => build["available"],
            "variable_count" => length(evaluation.point.variables),
            "constraint_count" => length(evaluation.constraint_sources),
            "applied_variable_block_count" => get(build, "applied_variable_block_count", nothing),
            "applied_constraint_block_count" => get(build, "applied_constraint_block_count", nothing),
            "skipped_declaration_count" => length(get(build, "skipped_declarations", Any[])),
        )
    catch error
        return Dict(
            "available" => false,
            "probe_snapshot" => relative,
            "reason" => sprint(showerror, error),
        )
    end
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
            "phase_only_real_campaign_ready" => all_integrity_clean && probe["available"] === true,
            "blocking_reason" => probe["available"] === true ? nothing : get(probe, "reason", "semantic map probe unavailable"),
        ),
        "qualification" => Dict(
            "claim" => "The selected real ENWL 99-bus snapshots are available, parseable, integrity-clean, and accompanied by saved SI results; phase-only execution remains gated on the versioned BMOPF semantic-block schema.",
            "does_not_establish" => ["phase-only solver behavior on the real network", "global phase-policy superiority", "wall-time portability", "automatic policy safety"],
        ),
    )
end

output = abspath(get(ENV, "NLPDIAGNOSTICS_REAL_99BUS_OUTPUT", joinpath(@__DIR__, "..", "work", "real-99bus-readiness.json")))
mkpath(dirname(output))
write(output, JSON.json(run_inventory()))
println("wrote real 99-bus readiness report to $output")
