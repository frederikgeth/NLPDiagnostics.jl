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
