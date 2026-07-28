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

function Base.show(io::IO, ::MIME"text/plain", report::DiagnosticReport)
    n = length(report)
    println(io, "NLPDiagnostics report with $n finding$(n == 1 ? "" : "s")")
    for finding in report
        print(io, "  ")
        show(io, finding)
        println(io)
    end
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
