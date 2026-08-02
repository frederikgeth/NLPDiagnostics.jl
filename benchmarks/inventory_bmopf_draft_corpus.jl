#!/usr/bin/env julia

# Create a read-only inventory of BMOPF JSON snapshots before selecting cases
# for numerical profiling. It neither builds a JuMP model nor evaluates any
# derivatives, so it is safe to run across a large benchmark repository.
#
# NLPDIAGNOSTICS_BMOPF_BENCHMARK_ROOT=/path/to/BMOPFDraftData/benchmarks \
#   julia --project=. benchmarks/inventory_bmopf_draft_corpus.jl

using BMOPFTools
using JSON

const _INVENTORY_SKIP_KEYS = Set(["_meta", "meta", "settings", "base", "time_series"])

function _relative_paths(root)
    paths = String[]
    for (directory, _, files) in walkdir(root)
        for file in files
            endswith(file, ".bmopf.json") || continue
            push!(paths, relpath(joinpath(directory, file), root))
        end
    end
    return sort!(paths)
end

function _component_counts(network::AbstractDict)
    counts = Dict{String,Int}()
    for (key, value) in network
        name = string(key)
        name in _INVENTORY_SKIP_KEYS && continue
        value isa AbstractDict || continue
        counts[name] = length(value)
    end
    return Dict(key => counts[key] for key in sort!(collect(keys(counts))))
end

function _coarse_size(counts)
    return sum(values(counts))
end

function main()
    root = get(ENV, "NLPDIAGNOSTICS_BMOPF_BENCHMARK_ROOT", "")
    isempty(root) && error("Set NLPDIAGNOSTICS_BMOPF_BENCHMARK_ROOT to BMOPFDraftData/benchmarks")
    isdir(root) || error("benchmark root does not exist: $root")
    output_path = get(ENV, "NLPDIAGNOSTICS_BMOPF_INVENTORY_OUTPUT",
                      joinpath(pwd(), "bmopf-draft-inventory.json"))
    records = Vector{Dict{String,Any}}()
    failures = Vector{Dict{String,Any}}()
    for relative in _relative_paths(root)
        path = joinpath(root, relative)
        try
            network = BMOPFTools.parse_bmopf(path)
            counts = _component_counts(network)
            push!(records, Dict(
                "snapshot" => relative,
                "file_bytes" => filesize(path),
                "top_level_component_counts" => counts,
                "coarse_component_count" => _coarse_size(counts),
            ))
        catch error
            push!(failures, Dict(
                "snapshot" => relative,
                "error" => sprint(showerror, error),
            ))
        end
    end
    sort!(records; by = record -> (-record["coarse_component_count"], record["snapshot"]))
    write(output_path, JSON.json(Dict(
        "benchmark_root" => abspath(root),
        "snapshot_count" => length(records),
        "parse_failure_count" => length(failures),
        "snapshots" => records,
        "parse_failures" => failures,
        "interpretation" => "Read-only schema inventory; coarse component counts are not JuMP dimensions or numerical complexity estimates.",
    )))
    println("inventoried $(length(records)) snapshots ($(length(failures)) parse failures)")
    for record in first(records, min(length(records), 10))
        snapshot = record["snapshot"]
        components = record["coarse_component_count"]
        bytes = record["file_bytes"]
        println("$snapshot: components=$components bytes=$bytes")
    end
    println("wrote $output_path")
end

main()
