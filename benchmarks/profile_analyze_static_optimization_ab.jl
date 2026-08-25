#!/usr/bin/env julia

"""Compare cached versus uncached affine-row preparation in `analyze_static`."""

using NLPDiagnostics
import MathOptInterface as MOI

include(joinpath(@__DIR__, "common.jl"))
using .NLPDiagnosticsBenchmarkCommon

const ROOT = repo_root()
const OUTPUT = abspath(isempty(ARGS) ?
    joinpath(ROOT, "docs", "analyze_static_optimization_ab_summary.json") : ARGS[1])

function parse_positive_list(raw::AbstractString)
    values = try
        parse.(Int, split(raw, ','))
    catch
        error("NLPDIAGNOSTICS_ANALYZE_STATIC_AB_DIMENSIONS must be comma-separated integers")
    end
    isempty(values) && error("static A/B dimensions must not be empty")
    all(>(1), values) || error("static A/B dimensions must be greater than one")
    length(unique(values)) == length(values) || error("static A/B dimensions must not contain duplicates")
    return values
end

dimensions = parse_positive_list(get(
    ENV, "NLPDIAGNOSTICS_ANALYZE_STATIC_AB_DIMENSIONS", "100,200,400",
))
repetitions = try
    parse(Int, get(ENV, "NLPDIAGNOSTICS_ANALYZE_STATIC_AB_REPETITIONS", "3"))
catch
    error("NLPDIAGNOSTICS_ANALYZE_STATIC_AB_REPETITIONS must be a positive integer")
end
repetitions > 0 || error("static A/B repetitions must be positive")

function sparse_affine_chain_model(dimension::Int)
    model = MOI.Utilities.Model{Float64}()
    variables = [MOI.add_variable(model) for _ in 1:dimension]
    for index in 1:(dimension - 1)
        terms = MOI.ScalarAffineTerm{Float64}[
            MOI.ScalarAffineTerm(1.0, variables[index + 1]),
            MOI.ScalarAffineTerm(-1.0, variables[index]),
        ]
        MOI.add_constraint(model, MOI.ScalarAffineFunction(terms, 0.0), MOI.EqualTo(0.0))
    end
    MOI.add_constraint(model, variables[1], MOI.EqualTo(0.0))
    for variable in variables[2:end]
        MOI.add_constraint(model, variable, MOI.GreaterThan(-1.0))
        MOI.add_constraint(model, variable, MOI.LessThan(1.0))
    end
    return model
end

function summarize(values::AbstractVector{<:Real})
    mean_value = sum(values) / length(values)
    return Dict{String,Any}(
        "mean" => mean_value,
        "minimum" => minimum(values),
        "maximum" => maximum(values),
    )
end

function static_result(model_snapshot, graph, cache_affine_coefficients)
    GC.gc()
    timed = @timed NLPDiagnostics.analyze_static(
        model_snapshot;
        graph = graph,
        cache_affine_coefficients = cache_affine_coefficients,
    )
    report = timed.value
    counts = NLPDiagnostics.finding_code_counts(report)
    return Dict{String,Any}(
        "elapsed_seconds" => timed.time,
        "allocated_bytes" => timed.bytes,
        "finding_count" => length(report),
        "finding_code_counts" => Dict(string(code) => count for (code, count) in counts),
        "affine_interval_propagation_passes" => get(report.metadata, :affine_interval_propagation_passes, "missing"),
        "affine_interval_propagation_converged" => get(report.metadata, :affine_interval_propagation_converged, "missing"),
    )
end

records = Dict{String,Any}[]
for dimension in dimensions
    runs = Dict{String,Any}[]
    for repetition in 1:repetitions
        model = sparse_affine_chain_model(dimension)
        snapshot = NLPDiagnostics.snapshot(model)
        graph = NLPDiagnostics.incidence_graph(snapshot)
        baseline = static_result(snapshot, graph, false)
        candidate = static_result(snapshot, graph, true)
        equivalent = baseline["finding_count"] == candidate["finding_count"] &&
            baseline["finding_code_counts"] == candidate["finding_code_counts"] &&
            baseline["affine_interval_propagation_passes"] == candidate["affine_interval_propagation_passes"] &&
            baseline["affine_interval_propagation_converged"] == candidate["affine_interval_propagation_converged"]
        push!(runs, Dict{String,Any}(
            "repetition" => repetition,
            "baseline" => baseline,
            "candidate" => candidate,
            "equivalent" => equivalent,
        ))
    end
    baseline_times = [run["baseline"]["elapsed_seconds"] for run in runs]
    candidate_times = [run["candidate"]["elapsed_seconds"] for run in runs]
    baseline_allocations = [run["baseline"]["allocated_bytes"] for run in runs]
    candidate_allocations = [run["candidate"]["allocated_bytes"] for run in runs]
    baseline_mean = sum(baseline_times) / length(baseline_times)
    candidate_mean = sum(candidate_times) / length(candidate_times)
    push!(records, Dict{String,Any}(
        "dimension" => dimension,
        "repetitions" => repetitions,
        "equivalent_across_repetitions" => all(run["equivalent"] for run in runs),
        "baseline" => Dict(
            "elapsed_seconds" => summarize(baseline_times),
            "allocated_bytes" => summarize(baseline_allocations),
        ),
        "candidate" => Dict(
            "elapsed_seconds" => summarize(candidate_times),
            "allocated_bytes" => summarize(candidate_allocations),
        ),
        "elapsed_speedup" => baseline_mean / candidate_mean,
        "allocation_reduction_ratio" => 1.0 - sum(candidate_allocations) / sum(baseline_allocations),
        "runs" => runs,
    ))
end

status_entries = git_status_entries()
write_json(OUTPUT, Dict{String,Any}(
    "schema_version" => "nlpdiagnostics-analyze-static-optimization-ab-v1",
    "source" => Dict(
        "runner" => "benchmarks/profile_analyze_static_optimization_ab.jl",
        "dimensions" => dimensions,
        "repetitions" => repetitions,
        "model" => "sparse affine chain with simple variable bounds",
        "baseline" => "rebuild affine coefficient maps inside every propagation pass",
        "candidate" => "cache supported affine rows and coefficient maps once per analyze_static call",
    ),
    "environment" => Dict(
        "julia_version" => string(VERSION),
        "active_project" => Base.active_project(),
        "os" => string(Sys.KERNEL),
        "architecture" => string(Sys.ARCH),
        "git_revision" => git_revision(),
        "git_worktree_dirty" => !isempty(status_entries),
    ),
    "record_count" => length(records),
    "records" => records,
    "equivalence_passed" => all(record["equivalent_across_repetitions"] for record in records),
    "candidate_not_slower_at_every_dimension" => all(
        record["candidate"]["elapsed_seconds"]["mean"] <= record["baseline"]["elapsed_seconds"]["mean"]
        for record in records
    ),
    "interpretation" => Dict(
        "claim" => "The cached affine-row candidate preserves static finding identities and propagation metadata on the bounded sparse chain while recording local timing and allocation deltas.",
        "does_not_establish" => [
            "a portable performance guarantee",
            "equivalence for unsupported function families not represented by this fixture",
            "allocator-level peak-memory behavior",
        ],
    ),
))
println("wrote analyze_static optimization A/B summary to $OUTPUT")
