module JuMPExt # Optional direct support for JuMP.Model

import JuMP
import NLPDiagnostics

NLPDiagnostics.snapshot(model::JuMP.Model) =
    NLPDiagnostics.snapshot(JuMP.backend(model))

NLPDiagnostics.analyze(model::JuMP.Model) =
    NLPDiagnostics.analyze(JuMP.backend(model))

NLPDiagnostics.analyze_static(model::JuMP.Model) =
    NLPDiagnostics.analyze_static(JuMP.backend(model))

NLPDiagnostics.analyze_structure(model::JuMP.Model) =
    NLPDiagnostics.analyze_structure(JuMP.backend(model))

NLPDiagnostics.incidence_graph(model::JuMP.Model) =
    NLPDiagnostics.incidence_graph(JuMP.backend(model))

end
