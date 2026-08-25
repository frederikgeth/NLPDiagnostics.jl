#!/usr/bin/env julia

"""Measure the public `analyze(model)` runtime on a sparse affine chain.

This benchmark intentionally exercises the default, point-free public entry
point on a cheap sparse model. It is a diagnostic-cost measurement, not a
complexity proof or a solver benchmark. The result is kept separate from the
existing sparse-kernel profile because backend timing alone does not establish
the cost of the composed public API. The optional stage-attribution records
time the major point-free stages independently on the same model snapshot.
They are attribution evidence, not a replacement for the end-to-end measure.

Usage:

    julia --project=work/benchmark-environment \
        benchmarks/profile_analyze_scaling.jl \
        docs/analyze_runtime_scaling_summary.json

Environment overrides:

    NLPDIAGNOSTICS_ANALYZE_SCALING_DIMENSIONS=100,200,400
    NLPDIAGNOSTICS_ANALYZE_SCALING_REPETITIONS=3
"""

using NLPDiagnostics
import MathOptInterface as MOI

include(joinpath(@__DIR__, "common.jl"))
using .NLPDiagnosticsBenchmarkCommon

const REPO_ROOT = repo_root()
const OUTPUT = abspath(isempty(ARGS) ?
    joinpath(REPO_ROOT, "docs", "analyze_runtime_scaling_summary.json") :
    ARGS[1])

function parse_positive_list(raw::AbstractString)
    values = try
        parse.(Int, split(raw, ','))
    catch
        error("NLPDIAGNOSTICS_ANALYZE_SCALING_DIMENSIONS must be comma-separated integers")
    end
    isempty(values) && error("analyze scaling dimensions must not be empty")
    all(>(1), values) || error("analyze scaling dimensions must be greater than one")
    length(unique(values)) == length(values) ||
        error("analyze scaling dimensions must not contain duplicates")
    return values
end

dimensions = parse_positive_list(get(
    ENV, "NLPDIAGNOSTICS_ANALYZE_SCALING_DIMENSIONS", "100,200,400",
))
repetitions = try
    parse(Int, get(ENV, "NLPDIAGNOSTICS_ANALYZE_SCALING_REPETITIONS", "3"))
catch
    error("NLPDIAGNOSTICS_ANALYZE_SCALING_REPETITIONS must be a positive integer")
end
repetitions > 0 || error("analyze scaling repetitions must be positive")

function sparse_affine_chain_model(dimension::Int)
    model = MOI.Utilities.Model{Float64}()
    variables = [MOI.add_variable(model) for _ in 1:dimension]
    for index in 1:(dimension - 1)
        function_terms = MOI.ScalarAffineTerm{Float64}[
            MOI.ScalarAffineTerm(1.0, variables[index + 1]),
            MOI.ScalarAffineTerm(-1.0, variables[index]),
        ]
        MOI.add_constraint(
            model,
            MOI.ScalarAffineFunction(function_terms, 0.0),
            MOI.EqualTo(0.0),
        )
    end
    # Fix the first coordinate so the equality chain has a deterministic
    # propagation source. This reproduces the cheap-but-adversarial case where
    # a point-free analysis can emit one derived interval per downstream row.
    MOI.add_constraint(model, variables[1], MOI.EqualTo(0.0))
    for variable in variables[2:end]
        MOI.add_constraint(model, variable, MOI.GreaterThan(-1.0))
        MOI.add_constraint(model, variable, MOI.LessThan(1.0))
    end
    return model
end

function timed_stage(thunk::Function, stage::AbstractString)
    timed = @timed thunk()
    return Dict{String,Any}(
        "stage" => stage,
        "elapsed_seconds" => timed.time,
        "allocated_bytes" => timed.bytes,
    )
end

function stage_attribution(model::MOI.ModelLike)
    model_snapshot = NLPDiagnostics.snapshot(model)
    graph = NLPDiagnostics.incidence_graph(model_snapshot)
    stages = Dict{String,Any}[]
    push!(stages, timed_stage("snapshot") do
        NLPDiagnostics.snapshot(model)
    end)
    push!(stages, timed_stage("incidence_graph") do
        NLPDiagnostics.incidence_graph(model_snapshot)
    end)
    push!(stages, timed_stage("static") do
        NLPDiagnostics.analyze_static(model_snapshot; graph = graph)
    end)
    push!(stages, timed_stage("domains") do
        NLPDiagnostics.analyze_domains(model_snapshot)
    end)
    push!(stages, timed_stage("derivatives") do
        NLPDiagnostics.analyze_derivatives(model_snapshot)
    end)
    push!(stages, timed_stage("expressions") do
        NLPDiagnostics.analyze_expressions(model_snapshot)
    end)
    push!(stages, timed_stage("structural") do
        NLPDiagnostics.analyze_structure(model_snapshot; graph = graph)
    end)
    return stages
end

function numeric_summary(values::AbstractVector{<:Real})
    isempty(values) && error("cannot summarize an empty measurement vector")
    mean_value = sum(values) / length(values)
    return Dict{String,Any}(
        "mean" => mean_value,
        "minimum" => minimum(values),
        "maximum" => maximum(values),
    )
end

function aggregate_stage_attribution(runs::AbstractVector)
    isempty(runs) && error("cannot aggregate an empty stage-attribution vector")
    names = sort!(unique(String(stage["stage"]) for run in runs for stage in run))
    return [
        begin
            measurements = [
                only(filter(stage -> stage["stage"] == name, run))
                for run in runs
            ]
            elapsed = numeric_summary([item["elapsed_seconds"] for item in measurements])
            allocations = numeric_summary([item["allocated_bytes"] for item in measurements])
            Dict{String,Any}(
                "stage" => name,
                "elapsed_seconds" => elapsed["mean"],
                "allocated_bytes" => round(Int, allocations["mean"]),
                "elapsed_seconds_minimum" => elapsed["minimum"],
                "elapsed_seconds_maximum" => elapsed["maximum"],
                "allocated_bytes_minimum" => allocations["minimum"],
                "allocated_bytes_maximum" => allocations["maximum"],
            )
        end for name in names
    ]
end

# Compile the public path and attribution stages once outside the measured
# records. The warm-up is discarded from the reported evidence.
warmup_model = sparse_affine_chain_model(first(dimensions))
NLPDiagnostics.analyze(warmup_model)
stage_attribution(warmup_model)

records = Dict{String,Any}[]
for dimension in dimensions
    runs = Dict{String,Any}[]
    for repetition in 1:repetitions
        model = sparse_affine_chain_model(dimension)
        GC.gc()
        timed = @timed NLPDiagnostics.analyze(model)
        report = timed.value
        counts = NLPDiagnostics.finding_code_counts(report)
        push!(runs, Dict{String,Any}(
            "repetition" => repetition,
            "elapsed_seconds" => timed.time,
            "allocated_bytes" => timed.bytes,
            "finding_count" => length(report),
            "finding_code_counts" => Dict(string(code) => count for (code, count) in counts),
            "limit_reached" => haskey(counts, :affine_interval_propagation_limit_reached),
            "stage_attribution" => stage_attribution(model),
        ))
    end
    elapsed = numeric_summary([run["elapsed_seconds"] for run in runs])
    allocations = numeric_summary([run["allocated_bytes"] for run in runs])
    reference_findings = first(runs)["finding_code_counts"]
    evidence_stable = all(
        run["finding_code_counts"] == reference_findings &&
        run["finding_count"] == first(runs)["finding_count"] &&
        run["limit_reached"] == first(runs)["limit_reached"] for run in runs
    )
    push!(records, Dict{String,Any}(
        "dimension" => dimension,
        "variable_count" => dimension,
        "constraint_count" => 3 * dimension - 2,
        "repetitions" => repetitions,
        "elapsed_seconds" => elapsed["mean"],
        "allocated_bytes" => round(Int, allocations["mean"]),
        "elapsed_seconds_minimum" => elapsed["minimum"],
        "elapsed_seconds_maximum" => elapsed["maximum"],
        "allocated_bytes_minimum" => allocations["minimum"],
        "allocated_bytes_maximum" => allocations["maximum"],
        "finding_count" => first(runs)["finding_count"],
        "finding_code_counts" => reference_findings,
        "limit_reached" => first(runs)["limit_reached"],
        "evidence_stable_across_repetitions" => evidence_stable,
        "stage_attribution" => aggregate_stage_attribution(
            [run["stage_attribution"] for run in runs],
        ),
        "runs" => runs,
    ))
end

status_entries = git_status_entries()
summary = Dict{String,Any}(
    "schema_version" => "nlpdiagnostics-analyze-runtime-scaling-v3",
    "source" => Dict(
        "runner" => "benchmarks/profile_analyze_scaling.jl",
        "dimensions" => dimensions,
        "model" => "sparse affine chain with simple variable bounds",
        "entry_point" => "NLPDiagnostics.analyze(model)",
        "point_supplied" => false,
        "repetitions" => repetitions,
        "stage_attribution" => [
            "snapshot",
            "incidence_graph",
            "static",
            "domains",
            "derivatives",
            "expressions",
            "structural",
        ],
    ),
    "environment" => Dict(
        "julia_version" => string(VERSION),
        "active_project" => Base.active_project(),
        "os" => string(Sys.KERNEL),
        "architecture" => string(Sys.ARCH),
        "git_revision" => git_revision(),
        "git_worktree_dirty" => !isempty(status_entries),
        "git_status_entry_count" => length(status_entries),
    ),
    "records" => records,
    "optimization" => Dict(
        "id" => "reuse_domain_interval_state",
        "description" =>
            "analyze_domains reuses one propagated variable-interval state for both issue detection and interval-origin provenance",
        "scope" => "domains stage",
        "evidence_preservation" =>
            "finding identities, counts, and affine-propagation limit status remain unchanged on the bounded affine-chain campaign",
    ),
    "interpretation" => Dict(
        "claim" => "Local runtime and allocation observations for the composed public analyze(model) entry point on a sparse affine chain.",
        "does_not_establish" => [
            "a portable complexity law",
            "OPF solver runtime or memory scaling",
            "causal attribution of any observed superlinear trend",
        ],
        "follow_up" => "Use repeated stage attribution and stable finding evidence to prioritize the next optimization; retain broader workload and memory validation as open.",
    ),
)

write_json(OUTPUT, summary)
println("wrote analyze runtime scaling summary to $OUTPUT")
