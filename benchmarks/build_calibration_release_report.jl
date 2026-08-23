#!/usr/bin/env julia

"""Render the calibration release-gate ledger as a reviewable Markdown report."""

include(joinpath(@__DIR__, "common.jl"))
using .NLPDiagnosticsBenchmarkCommon

const ROOT = repo_root()
const OUTPUT = abspath(get(
    ENV,
    "NLPDIAGNOSTICS_CALIBRATION_REPORT_OUTPUT",
    joinpath(ROOT, "docs", "calibration_release_report.md"),
))

function _status_label(status)
    status == "pass" && return "PASS"
    status == "partial" && return "PARTIAL"
    status == "blocked" && return "BLOCKED"
    return uppercase(string(status))
end

function _report_lines(summary)
    gates = get(summary, "gates", Any[])
    lines = String[
        "# Calibration release report",
        "",
        "This report is generated from `docs/calibration_release_gate_summary.json`. " *
        "It separates bounded evidence from release blockers and does not promote " *
        "local observations into causal or physical claims.",
        "",
        "## Release status",
        "",
        "- Project phase: `$(get(summary, "project_phase", "unknown"))`",
        "- Release ready: `$(get(summary, "release_ready", false))`",
        "- Blocking gates: `$(get(summary, "blocking_gate_count", "unknown"))`",
        "",
        "## Gate ledger",
        "",
        "| Gate | Status | Blocking |",
        "| --- | --- | --- |",
    ]
    for gate in gates
        push!(lines, "| `$(gate["id"])` | $(_status_label(gate["status"])) | `$(gate["blocking"])` |")
    end
    push!(lines, "", "## Evidence and blockers", "")
    for gate in gates
        push!(lines, "### `$(_status_label(gate["status"]))` — `$(gate["id"])`")
        push!(lines, "", gate["rationale"], "")
        evidence = get(gate, "evidence", Any[])
        if !isempty(evidence)
            push!(lines, "Evidence:")
            for path in evidence
                push!(lines, "- [`$path`]($path)")
            end
            push!(lines, "")
        end
    end
    push!(lines,
        "## Review boundary",
        "",
        "A partial or blocked gate is not a failed scientific result; it marks " *
        "evidence that is unavailable, incomplete, or not yet release-qualified.",
        "",
    )
    return lines
end

function main()
    summary = read_summary("docs/calibration_release_gate_summary.json")
    mkpath(dirname(OUTPUT))
    write(OUTPUT, join(_report_lines(summary), '\n') * '\n')
    println("wrote calibration release report to $OUTPUT")
end

main()
