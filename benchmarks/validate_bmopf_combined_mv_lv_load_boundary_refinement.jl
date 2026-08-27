#!/usr/bin/env julia

"""Validate the refined combined MV/LV demand boundary."""

using JSON

include(joinpath(@__DIR__, "common.jl"))
using .NLPDiagnosticsBenchmarkCommon: repo_root, write_json

const ROOT = repo_root()
const INPUT = abspath(isempty(ARGS) ?
    joinpath(ROOT, "docs", "bmopf_combined_mv_lv_load_boundary_refinement_summary.json") : ARGS[1])
const OUTPUT = abspath(length(ARGS) < 2 ?
    joinpath(ROOT, "docs", "bmopf_combined_mv_lv_load_boundary_refinement_validation_summary.json") : ARGS[2])
const EXPECTED_MULTIPLIERS = [0.25, 0.3, 0.35, 0.4]

isfile(INPUT) || error("refined load boundary sweep is missing: $INPUT")
sweep = JSON.parsefile(INPUT)
failures = String[]
get(sweep, "campaign", nothing) == "boundary_refinement" || push!(failures, "unexpected sweep campaign")
get(sweep, "status", nothing) == "completed" || push!(failures, "sweep status is not completed")
Float64.(get(sweep, "multipliers", Any[])) == EXPECTED_MULTIPLIERS ||
    push!(failures, "multipliers do not match the reviewed refinement ladder")
results = get(sweep, "results", Any[])
length(results) == length(EXPECTED_MULTIPLIERS) || push!(failures, "result count does not match the refinement ladder")

by_multiplier = Dict{Float64,Any}()
for result in results
    result isa AbstractDict || (push!(failures, "a result is not an object"); continue)
    multiplier = get(result, "load_multiplier", nothing)
    multiplier isa Number || (push!(failures, "a result has no numeric multiplier"); continue)
    by_multiplier[Float64(multiplier)] = result
    records = get(result, "records", Any[])
    labels = sort!(String[get(record, "label", "") for record in records if record isa AbstractDict])
    labels == ["feasibility_voltage_transfer", "native"] ||
        push!(failures, "multiplier $multiplier does not contain one native and one transfer record")
end

higher_failures = 0
for multiplier in EXPECTED_MULTIPLIERS
    haskey(by_multiplier, multiplier) || (push!(failures, "multiplier $multiplier is missing"); continue)
    solved = get(by_multiplier[multiplier], "hard_locally_solved", false)
    if multiplier == 0.25
        solved || push!(failures, "0.25 multiplier is not a paired local solve")
        for record in get(by_multiplier[multiplier], "records", Any[])
            get(record, "termination_status", nothing) == "LOCALLY_SOLVED" ||
                push!(failures, "0.25 multiplier has a non-local-solve termination")
            get(record, "primal_status", nothing) == "FEASIBLE_POINT" ||
                push!(failures, "0.25 multiplier has a non-feasible primal status")
        end
    else
        !solved && (global higher_failures += 1)
    end
end
higher_failures == 3 || push!(failures, "refined upper multipliers do not all remain outside local-solve acceptance")

status = isempty(failures) ? "pass" : "fail"
write_json(OUTPUT, Dict{String,Any}(
    "schema_version" => "nlpdiagnostics-bmopf-combined-mv-lv-load-boundary-refinement-validation-v1",
    "status" => status,
    "source" => relpath(INPUT, ROOT),
    "expected_multipliers" => EXPECTED_MULTIPLIERS,
    "validated_multiplier_count" => length(results),
    "paired_local_solve_multiplier" => 0.25,
    "upper_boundary_failure_count" => higher_failures,
    "failure_count" => length(failures),
    "failures" => failures,
    "interpretation" => "This validates the refined fixture-demand bracket observed under the declared bounded solver guard. It does not establish a physical demand threshold, universal scaling policy, or solver superiority.",
))
println("wrote combined MV/LV refined load-boundary validation to $OUTPUT")
status == "pass" || exit(1)
