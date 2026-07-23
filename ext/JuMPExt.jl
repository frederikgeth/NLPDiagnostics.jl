module JuMPExt # Optional direct support for JuMP.Model

import JuMP
import NLPDiagnostics

NLPDiagnostics.snapshot(model::JuMP.Model) =
    NLPDiagnostics.snapshot(JuMP.backend(model))

NLPDiagnostics.analyze(model::JuMP.Model) =
    NLPDiagnostics.analyze(JuMP.backend(model))

end
