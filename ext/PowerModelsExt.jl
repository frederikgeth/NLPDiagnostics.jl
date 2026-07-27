module PowerModelsExt

import NLPDiagnostics
import PowerModels

"""
PowerModels extension boundary.

This initial optional extension intentionally does not inspect PowerModels
internals or parse JuMP variable names. It establishes the extension load
boundary; component and expected-nullspace declarations will be added only
against tested public PowerModels APIs.
"""
const POWER_MODELS_EXTENSION_READY = true

end
