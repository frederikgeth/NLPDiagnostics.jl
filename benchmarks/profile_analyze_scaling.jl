#!/usr/bin/env julia

"""Measure the public `analyze(model)` runtime on a sparse affine chain.

This benchmark intentionally exercises the default, point-free public entry
point on a cheap sparse model. It is a diagnostic-cost measurement, not a
complexity proof or a solver benchmark. The result is kept separate from the
existing sparse-kernel profile because backend timing alone does not establish
the cost of the composed public API.

Usage:

    julia --project=work/benchmark-environment \
        benchmarks/profile_analyze_scaling.jl \
        docs/analyze_runtime_scaling_summary.json

Environment overrides:

    NLPDIAGNOSTICS_ANALYZE_SCALING_DIMENSIONS=100,200,400
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

# Compile the public path once outside the measured records.
NLPDiagnostics.analyze(sparse_affine_chain_model(first(dimensions)))

records = Dict{String,Any}[]
for dimension in dimensions
    model = sparse_affine_chain_model(dimension)
    GC.gc()
    timed = @timed NLPDiagnostics.analyze(model)
    report = timed.value
    counts = NLPDiagnostics.finding_code_counts(report)
    push!(records, Dict{String,Any}(
        "dimension" => dimension,
        "variable_count" => dimension,
        "constraint_count" => 3 * dimension - 2,
        "elapsed_seconds" => timed.time,
        "allocated_bytes" => timed.bytes,
        "finding_count" => length(report),
        "info_finding_count" => length(NLPDiagnostics.findings(
            report; severity = NLPDiagnostics.SeverityInfo,
        )),
        "warning_finding_count" => length(NLPDiagnostics.findings(
            report; severity = NLPDiagnostics.SeverityWarning,
        )),
        "error_finding_count" => length(NLPDiagnostics.findings(
            report; severity = NLPDiagnostics.SeverityError,
        )),
        "finding_code_counts" => Dict(string(code) => count for (code, count) in counts),
        "limit_reached" => haskey(counts, :affine_interval_propagation_limit_reached),
    ))
end

status_entries = git_status_entries()
summary = Dict{String,Any}(
    "schema_version" => "nlpdiagnostics-analyze-runtime-scaling-v1",
    "source" => Dict(
        "runner" => "benchmarks/profile_analyze_scaling.jl",
        "dimensions" => dimensions,
        "model" => "sparse affine chain with simple variable bounds",
        "entry_point" => "NLPDiagnostics.analyze(model)",
        "point_supplied" => false,
        "repetitions" => 1,
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
    "interpretation" => Dict(
        "claim" => "Local runtime and allocation observations for the composed public analyze(model) entry point on a sparse affine chain.",
        "does_not_establish" => [
            "a portable complexity law",
            "OPF solver runtime or memory scaling",
            "causal attribution of any observed superlinear trend",
        ],
        "follow_up" => "Profile stage-level costs, then optimize only after the dominant stages and evidence-preserving behavior are identified.",
    ),
)

write_json(OUTPUT, summary)
println("wrote analyze runtime scaling summary to $OUTPUT")
