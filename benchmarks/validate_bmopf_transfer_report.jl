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

isfile(INPUT) || error("transfer report is missing: $INPUT")
report = JSON.parsefile(INPUT)
records = get(report, "records", Any[])
failures = String[]
validated_count = 0

for (index, record) in enumerate(records)
    record isa AbstractDict || (push!(failures, "record[$index] is not an object"); continue)
    count_value = get(record, "transferred_voltage_start_validation_error_count", nothing)
    errors = get(record, "transferred_voltage_start_validation_errors", nothing)
    count_value isa Integer || push!(failures, "record[$index] has no integer validation error count")
    errors isa AbstractVector || push!(failures, "record[$index] has no validation error array")
    if count_value isa Integer && errors isa AbstractVector
        count_value == length(errors) || push!(failures,
            "record[$index] validation error count does not match array length")
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
    "runner_version" => get(report, "runner_version", nothing),
    "record_count" => length(records),
    "validated_record_count" => validated_count,
    "failure_count" => length(failures),
    "failures" => failures,
    "interpretation" => "This validates typed transfer-report structure and count consistency; it does not establish hard-OPF convergence or a stable upstream API.",
))
println("wrote BMOPFTools transfer-report validation to $OUTPUT")
status == "pass" || exit(1)
