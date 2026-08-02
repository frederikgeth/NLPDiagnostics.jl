module BMOPFToolsExt

import BMOPFTools
import NLPDiagnostics

const _GROUNDING_CODES = Set([
    "E.PROV.FLOATING_NEUTRAL",
    "W.PROV.FLOATING_NEUTRAL",
    "W.PROV.IMPLICIT_GROUNDING",
    "I.PROV.KRON_REDUCIBLE",
    "I.PROV.WYE_NEUTRAL_UNGROUNDED",
])

_severity(severity) = severity == BMOPFTools.ERROR ? NLPDiagnostics.SeverityError :
                      severity == BMOPFTools.WARNING ? NLPDiagnostics.SeverityWarning :
                      NLPDiagnostics.SeverityInfo

"""
    bmopf_terminal_report(net) -> DiagnosticReport

Run BMOPFTools' public grounding and terminal-continuity analysis, then translate
its neutral-related results into NLPDiagnostics findings. This is deliberately a
data-level physical screen: it does not assert an OPF-coordinate nullspace. Use
the generic Jacobian/nullspace analyses on the compiled JuMP model to determine
whether a reported network condition produces a mathematical gauge.
"""
function _bmopf_terminal_report(net::AbstractDict)
    # BMOPFTools uses the schema's concrete Dict{String,Any} data model. Make a
    # shallow canonical top-level view without mutating caller-owned network data.
    canonical_net = Dict{String,Any}(string(key) => value for (key, value) in net)
    engine_report = BMOPFTools.analyze(canonical_net)
    grounding = get(get(engine_report.results, :provenance, Dict{String,Any}()),
                    "grounding", Dict{String,Any}())

    report = NLPDiagnostics.DiagnosticReport()
    report.metadata[:stage] = "bmopf_terminals"
    report.metadata[:bmopf_engine] = "BMOPFTools.analyze"
    for (key, value) in grounding
        report.metadata[Symbol("bmopf_grounding_" * key)] = string(value)
    end

    for finding in engine_report.findings
        finding.code in _GROUNDING_CODES || continue
        component = isnothing(finding.component_id) ? "network" : finding.component_id
        detail = isnothing(finding.detail) ? Pair{String,Any}[] : collect(finding.detail)
        push!(detail, "bmopf_code" => finding.code)
        push!(detail, "bmopf_section" => string(finding.section))
        push!(report, NLPDiagnostics.Finding(Symbol(lowercase(replace(finding.code, '.' => '_')));
            severity = _severity(finding.severity),
            domain = NLPDiagnostics.PhysicalIssue,
            basis = NLPDiagnostics.StructuralProof,
            confidence = NLPDiagnostics.ConfidenceCertain,
            observation = finding.message,
            why_it_matters = "BMOPFTools derived this from declared terminal connectivity and grounding semantics; it can indicate a physical modeling issue or an expected representational convention.",
            evidence = [NLPDiagnostics.Evidence("BMOPFTools $(finding.code)";
                details = vcat(["component" => component], detail))],
            suggested_actions = ["Run `analyze(model)` on the compiled JuMP model and compare any observed nullspace with this physical evidence."],
        ))
    end
    return report
end

end
