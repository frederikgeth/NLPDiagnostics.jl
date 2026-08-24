# Plain-text rendering is intentionally concise; detailed evidence stays typed.
_label(value::Severity) = replace(string(value), "Severity" => "")
_label(value::Confidence) = replace(string(value), "Confidence" => "")

function Base.show(io::IO, finding::Finding)
    print(
        io,
        "[",
        uppercase(_label(finding.severity)),
        "] ",
        finding.code,
        ": ",
        finding.observation,
        " (",
        finding.basis,
        ", confidence=",
        lowercase(_label(finding.confidence)),
        ")",
    )
end

function _text_report_findings(report::DiagnosticReport, minimum::Severity)
    return Finding[
        finding for finding in report.findings
        if Int(finding.severity) >= Int(minimum)
    ]
end

function _text_report(
    report::DiagnosticReport;
    minimum_severity::Severity = SeverityWarning,
    maximum_findings::Union{Nothing,Integer} = nothing,
)
    maximum_findings = isnothing(maximum_findings) ? nothing : Int(maximum_findings)
    isnothing(maximum_findings) || maximum_findings >= 0 ||
        throw(ArgumentError("maximum_findings must be nonnegative or nothing"))
    selected = _text_report_findings(report, minimum_severity)
    truncated = !isnothing(maximum_findings) && length(selected) > maximum_findings
    displayed = truncated ? selected[1:maximum_findings] : selected
    hidden_info = count(finding -> Int(finding.severity) < Int(minimum_severity), report)
    io = IOBuffer()
    total = length(report)
    println(io, "NLPDiagnostics report with $total finding$(total == 1 ? "" : "s")")
    if hidden_info > 0
        println(io, "  $hidden_info informational finding$(hidden_info == 1 ? "" : "s") hidden by default")
        for family in finding_family_data(report; severity = SeverityInfo)
            count = family["count"]
            println(io, "  INFO summary: `", family["code"], "` (", count, " occurrence$(count == 1 ? "" : "s"))")
        end
    end
    for finding in displayed
        print(io, "  ")
        show(io, finding)
        println(io)
    end
    if truncated
        omitted = length(selected) - length(displayed)
        println(io, "  ... $omitted finding$(omitted == 1 ? "" : "s") omitted by maximum_findings=$(maximum_findings); use report_data(report) for complete records")
    end
    return String(take!(io))
end

"""
    text_report(report; minimum_severity = SeverityWarning, maximum_findings = nothing)

Render a concise terminal-oriented report. Informational findings are grouped
by family by default; `report_data(report)` retains every underlying record.
"""
function text_report(
    report::DiagnosticReport;
    minimum_severity::Severity = SeverityWarning,
    maximum_findings::Union{Nothing,Integer} = nothing,
)
    return _text_report(report; minimum_severity, maximum_findings)
end

function Base.show(io::IO, ::MIME"text/plain", report::DiagnosticReport)
    print(io, text_report(report))
    return
end

function _markdown_entity_label(entity::EntityRef)
    row = isnothing(entity.subindex) ? "" : "/$(entity.subindex)"
    name = isnothing(entity.name) ? "" : " ($(entity.name))"
    return "$(entity.kind)[$(entity.index)$row]$name"
end

"""
    markdown_report(report)

Render a diagnostic report as deterministic CommonMark. Detailed evidence and
actions remain attached to each finding; the renderer never changes the model
or infers a ranking among findings.
"""
function markdown_report(report::DiagnosticReport)
    io = IOBuffer()
    count = length(report)
    println(io, "# NLPDiagnostics report")
    println(io)
    println(io, "$count finding$(count == 1 ? "" : "s")")
    if !isempty(report.metadata)
        println(io)
        println(io, "## Metadata")
        println(io)
        for key in sort!(collect(keys(report.metadata)); by = string)
            println(io, "- `", key, "`: ", report.metadata[key])
        end
    end
    for finding in report.findings
        println(io)
        println(
            io,
            "## ", uppercase(_report_enum_label(finding.severity)),
            " · ", _report_enum_label(finding.domain), " · `", finding.code, "`",
        )
        println(io)
        println(io, finding.observation)
        println(io)
        println(io, "**Why it matters:** ", finding.why_it_matters)
        println(io)
        println(
            io,
            "**Evidence basis:** ", _report_enum_label(finding.basis),
            "; **confidence:** ", _report_enum_label(finding.confidence), ".",
        )
        if !isempty(finding.evidence)
            println(io)
            println(io, "### Evidence")
            println(io)
            for item in finding.evidence
                println(io, "- ", item.summary)
                for detail in item.details
                    println(io, "  - `", first(detail), "`: ", last(detail))
                end
            end
        end
        if !isempty(finding.suggested_actions)
            println(io)
            println(io, "### Suggested actions")
            println(io)
            for action in finding.suggested_actions
                println(io, "- ", action)
            end
        end
        if !isempty(finding.affected)
            println(io)
            println(io, "### Affected entities")
            println(io)
            for entity in finding.affected
                println(io, "- `", _markdown_entity_label(entity), "`")
            end
        end
    end
    return String(take!(io))
end

function Base.show(io::IO, ::MIME"text/markdown", report::DiagnosticReport)
    print(io, markdown_report(report))
    return
end
