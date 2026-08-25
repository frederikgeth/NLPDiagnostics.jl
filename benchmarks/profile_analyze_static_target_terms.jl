#!/usr/bin/env julia

"""Compare cached affine target-term preparation in `analyze_static`."""

using NLPDiagnostics
import MathOptInterface as MOI

include(joinpath(@__DIR__, "common.jl"))
using .NLPDiagnosticsBenchmarkCommon

const ROOT = repo_root()
const OUTPUT = abspath(isempty(ARGS) ?
    joinpath(ROOT, "docs", "analyze_static_target_terms_summary.json") : ARGS[1])

function parse_positive_list(raw::AbstractString)
    values = try
        parse.(Int, split(raw, ','))
    catch
        error("NLPDIAGNOSTICS_ANALYZE_STATIC_TARGET_TERMS_DIMENSIONS must be comma-separated integers")
    end
    isempty(values) && error("target-term dimensions must not be empty")
    all(>(2), values) || error("target-term dimensions must be greater than two")
    length(unique(values)) == length(values) || error("target-term dimensions must not contain duplicates")
    return values
end

dimensions = parse_positive_list(get(
    ENV, "NLPDIAGNOSTICS_ANALYZE_STATIC_TARGET_TERMS_DIMENSIONS", "16,32,64",
))
repetitions = try
    parse(Int, get(ENV, "NLPDIAGNOSTICS_ANALYZE_STATIC_TARGET_TERMS_REPETITIONS", "3"))
catch
    error("NLPDIAGNOSTICS_ANALYZE_STATIC_TARGET_TERMS_REPETITIONS must be a positive integer")
end
repetitions > 0 || error("target-term repetitions must be positive")

function dense_affine_model(dimension::Int)
    model = MOI.Utilities.Model{Float64}()
    variables = [MOI.add_variable(model) for _ in 1:dimension]
    for row in 1:dimension
        terms = MOI.ScalarAffineTerm{Float64}[
            MOI.ScalarAffineTerm(
                isodd(row + column) ? 1.0 / column : -1.0 / column,
                variables[column],
            ) for column in 1:dimension
        ]
        MOI.add_constraint(model, MOI.ScalarAffineFunction(terms, 0.0), MOI.EqualTo(0.0))
    end
    for variable in variables
        MOI.add_constraint(model, variable, MOI.GreaterThan(-1.0))
        MOI.add_constraint(model, variable, MOI.LessThan(1.0))
    end
    return model
end

function sparse_affine_model(dimension::Int)
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
    Dict{String,Any}(
        "mean" => sum(values) / length(values),
        "minimum" => minimum(values),
        "maximum" => maximum(values),
    )
end

function static_result(snapshot, graph, target_terms::Bool)
    GC.gc()
    timed = @timed NLPDiagnostics.analyze_static(
        snapshot;
        graph = graph,
        cache_affine_coefficients = true,
        cache_affine_target_terms = target_terms,
    )
    report = timed.value
    counts = NLPDiagnostics.finding_code_counts(report)
    Dict{String,Any}(
        "elapsed_seconds" => timed.time,
        "allocated_bytes" => timed.bytes,
        "finding_count" => length(report),
        "finding_code_counts" => Dict(string(code) => count for (code, count) in counts),
        "affine_interval_propagation_passes" => get(report.metadata, :affine_interval_propagation_passes, "missing"),
        "affine_interval_propagation_converged" => get(report.metadata, :affine_interval_propagation_converged, "missing"),
    )
end

function measure_workload(builder::Function, workload::AbstractString)
    records = Dict{String,Any}[]
    for dimension in dimensions
        runs = Dict{String,Any}[]
        for repetition in 1:repetitions
            model = builder(dimension)
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
            "workload" => workload,
            "dimension" => dimension,
            "repetitions" => repetitions,
            "equivalent_across_repetitions" => all(run["equivalent"] for run in runs),
            "baseline" => Dict("elapsed_seconds" => summarize(baseline_times), "allocated_bytes" => summarize(baseline_allocations)),
            "candidate" => Dict("elapsed_seconds" => summarize(candidate_times), "allocated_bytes" => summarize(candidate_allocations)),
            "elapsed_speedup" => baseline_mean / candidate_mean,
            "allocation_reduction_ratio" => 1.0 - sum(candidate_allocations) / sum(baseline_allocations),
            "runs" => runs,
        ))
    end
    return records
end

# Warm up both workload families and both paths before recording evidence.
for builder in (dense_affine_model, sparse_affine_model)
    model = builder(first(dimensions))
    snapshot = NLPDiagnostics.snapshot(model)
    graph = NLPDiagnostics.incidence_graph(snapshot)
    static_result(snapshot, graph, false)
    static_result(snapshot, graph, true)
end

records = vcat(
    measure_workload(dense_affine_model, "dense_affine_rows"),
    measure_workload(sparse_affine_model, "sparse_affine_chain"),
)
status_entries = git_status_entries()
equivalence_passed = all(record["equivalent_across_repetitions"] for record in records)
speedups = [record["elapsed_speedup"] for record in records]
write_json(OUTPUT, Dict{String,Any}(
    "schema_version" => "nlpdiagnostics-analyze-static-target-terms-v1",
    "source" => Dict(
        "runner" => "benchmarks/profile_analyze_static_target_terms.jl",
        "dimensions" => dimensions,
        "repetitions" => repetitions,
        "workloads" => ["dense_affine_rows", "sparse_affine_chain"],
        "baseline" => "cache affine coefficient maps once per analyze_static call and filter target terms during every propagation pass",
        "candidate" => "cache each affine row's other-variable terms once per analyze_static call",
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
    "equivalence_passed" => equivalence_passed,
    "candidate_not_slower_at_every_workload" => all(speedup -> speedup >= 1.0, speedups),
    "decision" => equivalence_passed ?
        "The target-term cache is semantics-preserving; retain its bounded timing result as local evidence and do not promote a portable performance claim." :
        "The target-term cache did not preserve all bounded findings or propagation metadata and is not eligible for promotion.",
    "interpretation" => Dict(
        "claim" => "The target-term cache compares an opt-in static-stage implementation on dense and sparse affine fixtures while retaining finding and propagation equivalence checks.",
        "does_not_establish" => [
            "a portable performance guarantee",
            "equivalence for unsupported function families not represented by these fixtures",
            "allocator-level peak-memory behavior",
        ],
    ),
))
println("wrote analyze_static target-term summary to $OUTPUT")
