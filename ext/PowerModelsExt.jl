module PowerModelsExt

import NLPDiagnostics
import PowerModels

const _PM_COMPONENT_KINDS = (
    :bus, :branch, :gen, :load, :shunt, :switch, :storage, :dcline,
)

const _PM_COMPONENT_UNITS = Dict(
    :bus => Dict(:voltage => "p.u."),
    :branch => Dict(:power => "p.u.", :current => "p.u."),
    :gen => Dict(:power => "p.u."),
    :load => Dict(:power => "p.u."),
    :shunt => Dict(:admittance => "p.u."),
    :switch => Dict(:power => "p.u.", :current => "p.u."),
    :storage => Dict(:power => "p.u.", :energy => "p.u."),
    :dcline => Dict(:power => "p.u."),
)

function _pm_component_entries(pm::PowerModels.AbstractPowerModel, network, kind::Symbol)
    try
        return PowerModels.ref(pm, network, kind)
    catch error
        error isa KeyError || error isa ArgumentError || rethrow()
        return nothing
    end
end

"""
    NLPDiagnostics.powermodels_component_metadata(pm)

Build component identities from PowerModels' public `nw_ids` and `ref` APIs.
This first slice never inspects `pm` fields, parses JuMP variable names, or
claims expected rank: coordinate and equation scopes await a tested public
JuMP-to-MOI mapping for each supported formulation.
"""
function NLPDiagnostics.powermodels_component_metadata(
    pm::PowerModels.AbstractPowerModel,
)
    records = NLPDiagnostics.ComponentMetadata[]
    for network in sort!(collect(PowerModels.nw_ids(pm)))
        reference_entries = _pm_component_entries(pm, network, :ref_buses)
        reference_ids = isnothing(reference_entries) ? Set{Any}() :
                        Set(keys(reference_entries))
        for kind in _PM_COMPONENT_KINDS
            entries = _pm_component_entries(pm, network, kind)
            isnothing(entries) && continue
            for component_id in sort!(collect(keys(entries)); by = string)
                metadata = Dict(
                    "source" => "PowerModels.ref",
                    "network_id" => string(network),
                    "component_kind" => string(kind),
                    "component_id" => string(component_id),
                )
                kind == :bus && component_id in reference_ids &&
                    (metadata["declared_reference_bus"] = "true")
                push!(records, NLPDiagnostics.ComponentMetadata(
                    kind, "nw$(network):$(component_id)";
                    units = _PM_COMPONENT_UNITS[kind],
                    metadata = metadata,
                ))
            end
        end
    end
    return records
end

NLPDiagnostics.component_metadata(pm::PowerModels.AbstractPowerModel) =
    NLPDiagnostics.powermodels_component_metadata(pm)

"""
    NLPDiagnostics.powermodels_reference_bus_report(pm)

Report the count of PowerModels-declared reference buses for each network using
only the public `ref(pm, nw, :ref_buses)` data. The report does not assert that
the formulation has added, retained, or correctly mapped an angle equation.
"""
function NLPDiagnostics.powermodels_reference_bus_report(
    pm::PowerModels.AbstractPowerModel,
)
    report = NLPDiagnostics.DiagnosticReport()
    for network in sort!(collect(PowerModels.nw_ids(pm)))
        entries = _pm_component_entries(pm, network, :ref_buses)
        reference_ids = isnothing(entries) ? Any[] : sort!(collect(keys(entries)); by = string)
        count = length(reference_ids)
        code = count == 0 ? :powermodels_reference_bus_missing :
               count == 1 ? :powermodels_reference_bus_unique :
                            :powermodels_reference_bus_multiple
        severity = count == 0 ? NLPDiagnostics.SeverityError :
                   count == 1 ? NLPDiagnostics.SeverityInfo :
                                NLPDiagnostics.SeverityWarning
        observation = count == 0 ?
                      "PowerModels network $(network) declares no reference bus." :
                      count == 1 ?
                      "PowerModels network $(network) declares one reference bus ($(only(reference_ids)))." :
                      "PowerModels network $(network) declares $count reference buses."
        why = count == 0 ?
              "A missing data-level reference can leave a polar AC formulation with an unanchored angle, but the actual model equations still need inspection." :
              count == 1 ?
              "This is compatible with a conventional single angle reference, without proving that the selected formulation enforces it." :
              "Multiple data-level references can be intentional across islands or can overconstrain one connected system; topology and formulation evidence are still required."
        actions = count == 0 ?
                  ["Declare a reference bus per intended connected network component and then verify the model-coordinate angle constraints."] :
                  count == 1 ?
                  ["Compare this data declaration with the formulation's actual angle-reference constraint before classifying gauges."] :
                  ["Check network islands and actual angle-reference constraints before treating multiple references as an error."]
        push!(report, NLPDiagnostics.Finding(code;
            severity = severity,
            domain = NLPDiagnostics.RepresentationalIssue,
            basis = NLPDiagnostics.StructuralProof,
            confidence = NLPDiagnostics.ConfidenceCertain,
            observation = observation,
            why_it_matters = why,
            evidence = [NLPDiagnostics.Evidence("PowerModels reference-bus data"; details = [
                "network_id" => network,
                "reference_bus_count" => count,
                "reference_bus_ids" => join(string.(reference_ids), ","),
            ])],
            suggested_actions = actions,
        ))
    end
    report.metadata[:stage] = "powermodels_reference_bus"
    report.metadata[:network_count] = string(length(PowerModels.nw_ids(pm)))
    return report
end

"""PowerModels extension boundary and public-reference metadata adapter."""
const POWER_MODELS_EXTENSION_READY = true

end
