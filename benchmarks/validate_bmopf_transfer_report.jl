#!/usr/bin/env julia

"""Validate the typed fields in a combined MV/LV transfer report."""

using JSON

include(joinpath(@__DIR__, "common.jl"))
using .NLPDiagnosticsBenchmarkCommon: repo_root, write_json

const ROOT = repo_root()
const INPUT = abspath(isempty(ARGS) ?
    joinpath(ROOT, "docs", "bmopf_combined_mv_lv_feasibility_start_transfer_summary.json") : ARGS[1])
const OUTPUT = abspath(length(ARGS) < 2 ?
    joinpath(ROOT, "docs", "bmopf_transfer_report_validation_summary.json") : ARGS[2])
const EXPECTED_RUNNER = "bmopf-combined-mv-lv-feasibility-start-transfer-v2"

isfile(INPUT) || error("transfer report is missing: $INPUT")
report = JSON.parsefile(INPUT)

function flattened_records(report)
    outer = get(report, "records", Any[])
    isempty(outer) && return Any[]
    report_runner = get(report, "runner_version", nothing)
    report_status = get(report, "status", nothing)
    # Isolated summaries retain one nested base report per repetition. Flatten
    # that known shape while inheriting repetition-level provenance/status;
    # ordinary reports inherit those fields from their top-level envelope.
    nested = all(entry -> entry isa AbstractDict && haskey(entry, "records"), outer)
    flattened = Dict{String,Any}[]
    for entry in outer
        if nested
            inherited_runner = get(entry, "runner_version", report_runner)
            inherited_status = get(entry, "status", report_status)
            source_records = get(entry, "records", Any[])
        else
            inherited_runner = report_runner
            inherited_status = report_status
            source_records = [entry]
        end
        for record in source_records
            record isa AbstractDict || (push!(flattened, Dict{String,Any}()); continue)
            merged = Dict{String,Any}(string(key) => value for (key, value) in record)
            haskey(merged, "runner_version") || (merged["runner_version"] = inherited_runner)
            haskey(merged, "status") || (merged["status"] = inherited_status)
            push!(flattened, merged)
        end
    end
    return flattened
end

records = flattened_records(report)
failures = String[]
validated_count = 0
runner_versions = Set{String}()
report_runner_version = get(report, "runner_version", nothing)

for (index, record) in enumerate(records)
    record isa AbstractDict || (push!(failures, "record[$index] is not an object"); continue)
    runner = get(record, "runner_version", report_runner_version)
    runner isa AbstractString || push!(failures, "record[$index] has no runner version")
    if runner isa AbstractString
        push!(runner_versions, String(runner))
        runner == EXPECTED_RUNNER || push!(failures,
            "record[$index] runner version is not $EXPECTED_RUNNER")
    end
    get(record, "status", nothing) == "bounded_hard_opf_start_transfer" ||
        push!(failures, "record[$index] has an unexpected status")
    transfer_applied = get(record, "transfer_applied", nothing)
    transfer_applied isa Bool || push!(failures, "record[$index] has no transfer flag")
    applied_count = get(record, "transferred_voltage_start_count", nothing)
    skipped_count = get(record, "transferred_voltage_start_skipped_count", nothing)
    applied_count isa Integer && applied_count >= 0 ||
        push!(failures, "record[$index] has an invalid applied count")
    skipped_count isa Integer && skipped_count >= 0 ||
        push!(failures, "record[$index] has an invalid skipped count")
    count_value = get(record, "transferred_voltage_start_validation_error_count", nothing)
    errors = get(record, "transferred_voltage_start_validation_errors", nothing)
    count_value isa Integer || push!(failures, "record[$index] has no integer validation error count")
    errors isa AbstractVector || push!(failures, "record[$index] has no validation error array")
    if count_value isa Integer && errors isa AbstractVector
        count_value == length(errors) || push!(failures,
            "record[$index] validation error count does not match array length")
        skipped_count isa Integer && skipped_count == count_value ||
            push!(failures, "record[$index] skipped count does not match validation error count")
        for (error_index, entry) in enumerate(errors)
            entry isa AbstractDict || (push!(failures, "record[$index].errors[$error_index] is not an object"); continue)
            code = get(entry, "code", nothing)
            bus = get(entry, "bus", nothing)
            terminal = get(entry, "terminal", nothing)
            code isa AbstractString || push!(failures, "record[$index].errors[$error_index] has no code")
            bus isa AbstractString || push!(failures, "record[$index].errors[$error_index] has no bus")
            terminal isa AbstractString || push!(failures, "record[$index].errors[$error_index] has no terminal")
        end
    end
    global validated_count += 1
end

status = isempty(failures) && !isempty(records) ? "pass" : "fail"
write_json(OUTPUT, Dict{String,Any}(
    "schema_version" => "nlpdiagnostics-bmopf-transfer-report-validation-v1",
    "status" => status,
    "source" => relpath(INPUT, ROOT),
    "runner_version" => get(report, "runner_version", isempty(runner_versions) ? nothing : first(runner_versions)),
    "validated_runner_versions" => sort!(collect(runner_versions)),
    "record_count" => length(records),
    "validated_record_count" => validated_count,
    "failure_count" => length(failures),
    "failures" => failures,
    "interpretation" => "This validates typed transfer-report structure and count consistency; it does not establish hard-OPF convergence or a stable upstream API.",
))
println("wrote BMOPFTools transfer-report validation to $OUTPUT")
status == "pass" || exit(1)
