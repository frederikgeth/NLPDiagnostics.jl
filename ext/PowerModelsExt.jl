module PowerModelsExt

import NLPDiagnostics
import PowerModels
import JuMP
import MathOptInterface

const MOI = MathOptInterface

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
        angle_indices = NLPDiagnostics.powermodels_variable_indices(
            pm, :va; network = network,
        )
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
                angle_index = get(angle_indices, (network, component_id), nothing)
                !isnothing(angle_index) &&
                    (metadata["scalar_angle_coordinate"] = "va")
                push!(records, NLPDiagnostics.ComponentMetadata(
                    kind, "nw$(network):$(component_id)";
                    units = _PM_COMPONENT_UNITS[kind],
                    variables = isnothing(angle_index) ? MOI.VariableIndex[] :
                                MOI.VariableIndex[angle_index],
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
    NLPDiagnostics.powermodels_capability_report(pm)

Report which public scalar-angle coordinates are available to this adapter.
This is an adapter-capability report, not a statement about the electrical
formulation or whether a reference equation is present.
"""
function NLPDiagnostics.powermodels_capability_report(
    pm::PowerModels.AbstractPowerModel,
)
    report = NLPDiagnostics.DiagnosticReport()
    networks = sort!(collect(PowerModels.nw_ids(pm)))
    angle_indices = NLPDiagnostics.powermodels_variable_indices(pm, :va)
    report.metadata[:stage] = "powermodels_capabilities"
    report.metadata[:powermodels_network_count] = string(length(networks))
    report.metadata[:powermodels_scalar_angle_coordinate_count] =
        string(length(angle_indices))
    missing_networks = Any[]
    for network in networks
        angle_count = count(key -> key[1] == network, Base.keys(angle_indices))
        report.metadata[Symbol("powermodels_network_", network, "_scalar_angle_coordinate_count")] =
            string(angle_count)
        angle_count == 0 && push!(missing_networks, network)
    end
    report.metadata[:powermodels_scalar_angle_coordinate_missing_network_count] =
        string(length(missing_networks))
    for network in missing_networks
        push!(report, NLPDiagnostics.Finding(:powermodels_scalar_angle_coordinates_unavailable;
            severity = NLPDiagnostics.SeverityInfo,
            domain = NLPDiagnostics.RepresentationalIssue,
            basis = NLPDiagnostics.StructuralProof,
            confidence = NLPDiagnostics.ConfidenceCertain,
            observation = "PowerModels network $(network) exposes no public scalar :va coordinates.",
            why_it_matters = "This adapter cannot construct scalar common-angle candidates for that network without a formulation-specific coordinate declaration.",
            evidence = [NLPDiagnostics.Evidence("PowerModels public variable capability"; details = [
                "network_id" => network,
                "variable_key" => "va",
                "scalar_coordinate_count" => 0,
            ])],
            suggested_actions = ["Use a supported scalar angle key, analyze the JuMP model directly with explicit expected modes, or implement a formulation-specific adapter."],
        ))
    end
    return report
end

function NLPDiagnostics.component_coordinate_semantics(pm::PowerModels.AbstractPowerModel)
    semantics = NLPDiagnostics.ComponentCoordinateSemantics[]
    for ((network, bus_id), index) in sort!(
        collect(NLPDiagnostics.powermodels_variable_indices(pm, :va));
        by = first,
    )
        push!(semantics, NLPDiagnostics.ComponentCoordinateSemantics(
            :bus, "nw$(network):$(bus_id)", MOI.VariableIndex[index];
            quantity = :angle, representation = :polar,
            units = Dict("angle" => "rad"),
            description = "Public PowerModels scalar :va bus coordinate.",
        ))
    end
    return semantics
end

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
        components = _pm_component_entries(pm, network, :components)
        reference_set = Set(reference_ids)
        references_separated_by_island = count > 1 && !isnothing(components) &&
            all(length(intersect(reference_set, Set(bus_ids))) == 1 for bus_ids in values(components))
        code = count == 0 ? :powermodels_reference_bus_missing :
               count == 1 ? :powermodels_reference_bus_unique :
               references_separated_by_island ?
               :powermodels_reference_bus_multiple_across_islands :
                            :powermodels_reference_bus_multiple
        severity = count == 0 ? NLPDiagnostics.SeverityError :
                   count == 1 ? NLPDiagnostics.SeverityInfo :
                   references_separated_by_island ? NLPDiagnostics.SeverityInfo :
                                NLPDiagnostics.SeverityWarning
        observation = count == 0 ?
                      "PowerModels network $(network) declares no reference bus." :
                      count == 1 ?
                      "PowerModels network $(network) declares one reference bus ($(only(reference_ids)))." :
                      references_separated_by_island ?
                      "PowerModels network $(network) declares $count reference buses, one per declared connected component." :
                      "PowerModels network $(network) declares $count reference buses."
        why = count == 0 ?
              "A missing data-level reference can leave a polar AC formulation with an unanchored angle, but the actual model equations still need inspection." :
              count == 1 ?
              "This is compatible with a conventional single angle reference, without proving that the selected formulation enforces it." :
              references_separated_by_island ?
              "The public component map separates these references across islands, which is compatible with one anchor per island but still does not prove formulation constraints." :
              "Multiple data-level references can be intentional across islands or can overconstrain one connected system; topology and formulation evidence are still required."
        actions = count == 0 ?
                  ["Declare a reference bus per intended connected network component and then verify the model-coordinate angle constraints."] :
                  count == 1 ?
                  ["Compare this data declaration with the formulation's actual angle-reference constraint before classifying gauges."] :
                  references_separated_by_island ?
                  ["Verify the formulation has one effective angle anchor per declared island."] :
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
        isnothing(components) && continue
        for (component_id, bus_ids) in sort!(collect(components); by = first)
            component_references = sort!(
                collect(intersect(reference_set, Set(bus_ids))); by = string,
            )
            component_count = length(component_references)
            component_code = component_count == 0 ?
                             :powermodels_reference_bus_component_missing :
                             component_count == 1 ?
                             :powermodels_reference_bus_component_unique :
                             :powermodels_reference_bus_component_multiple
            component_severity = component_count == 0 ? NLPDiagnostics.SeverityError :
                                 component_count == 1 ? NLPDiagnostics.SeverityInfo :
                                                        NLPDiagnostics.SeverityWarning
            push!(report, NLPDiagnostics.Finding(component_code;
                severity = component_severity,
                domain = NLPDiagnostics.RepresentationalIssue,
                basis = NLPDiagnostics.StructuralProof,
                confidence = NLPDiagnostics.ConfidenceCertain,
                observation = component_count == 0 ?
                              "PowerModels network $(network) connected component $(component_id) declares no reference bus." :
                              component_count == 1 ?
                              "PowerModels network $(network) connected component $(component_id) declares one reference bus ($(only(component_references)))." :
                              "PowerModels network $(network) connected component $(component_id) declares $component_count reference buses.",
                why_it_matters = component_count == 0 ?
                                 "A reference in another electrical island does not anchor this component's polar angle coordinates." :
                                 component_count == 1 ?
                                 "This data configuration is compatible with one reference per island, without proving the formulation constraint exists." :
                                 "Multiple references within one declared island can be intentional, but may also over-anchor its angle coordinates.",
                evidence = [NLPDiagnostics.Evidence("PowerModels reference-bus component data"; details = [
                    "network_id" => network,
                    "component_id" => component_id,
                    "component_bus_count" => length(bus_ids),
                    "reference_bus_count" => component_count,
                    "reference_bus_ids" => join(string.(component_references), ","),
                ])],
                suggested_actions = component_count == 0 ?
                                    ["Declare or formulate a reference for this connected component before interpreting angle nullspaces."] :
                                    component_count == 1 ?
                                    ["Compare this island-level declaration with the actual formulation constraint."] :
                                    ["Check whether multiple references are intended within this connected component."],
            ))
        end
    end
    report.metadata[:stage] = "powermodels_reference_bus"
    report.metadata[:network_count] = string(length(PowerModels.nw_ids(pm)))
    report.metadata[:missing_reference_network_count] = string(count(
        finding -> finding.code == :powermodels_reference_bus_missing,
        report.findings,
    ))
    report.metadata[:multiple_reference_network_count] = string(count(
        finding -> finding.code == :powermodels_reference_bus_multiple,
        report.findings,
    ))
    report.metadata[:multiple_reference_across_islands_count] = string(count(
        finding -> finding.code == :powermodels_reference_bus_multiple_across_islands,
        report.findings,
    ))
    report.metadata[:missing_reference_component_count] = string(count(
        finding -> finding.code == :powermodels_reference_bus_component_missing,
        report.findings,
    ))
    report.metadata[:multiple_reference_component_count] = string(count(
        finding -> finding.code == :powermodels_reference_bus_component_multiple,
        report.findings,
    ))
    return report
end

"""
    NLPDiagnostics.powermodels_variable_indices(pm, key; network = nothing)

Return scalar JuMP variables exposed by PowerModels' public `var` API as MOI
variable indices, keyed by `(network_id, component_id)`. Vector/container
entries are intentionally omitted: their coordinate ordering must be declared
by a formulation-specific adapter rather than guessed here.
"""
function NLPDiagnostics.powermodels_variable_indices(
    pm::PowerModels.AbstractPowerModel,
    key::Symbol;
    network = nothing,
)
    networks = isnothing(network) ? collect(PowerModels.nw_ids(pm)) : [network]
    result = Dict{Tuple{Any,Any},MOI.VariableIndex}()
    for network_id in sort!(networks)
        entries = try
            PowerModels.var(pm, network_id, key)
        catch error
            error isa KeyError || error isa ArgumentError || rethrow()
            continue
        end
        for component_id in sort!(collect(keys(entries)); by = string)
            value = entries[component_id]
            value isa JuMP.VariableRef || continue
            result[(network_id, component_id)] = JuMP.index(value)
        end
    end
    return result
end

"""
    NLPDiagnostics.powermodels_jump_model(pm; key = :va)

Recover the single owning JuMP model of public scalar entries in
`PowerModels.var(pm, nw, key)`. Returns `nothing` when that variable family is
absent or has no scalar entries, and errors if the entries belong to different
JuMP models. This avoids reaching into PowerModels' internal fields.
"""
function NLPDiagnostics.powermodels_jump_model(
    pm::PowerModels.AbstractPowerModel;
    key::Symbol = :va,
)
    owners = JuMP.Model[]
    for network in sort!(collect(PowerModels.nw_ids(pm)))
        entries = try
            PowerModels.var(pm, network, key)
        catch error
            error isa KeyError || error isa ArgumentError || rethrow()
            continue
        end
        for value in values(entries)
            value isa JuMP.VariableRef || continue
            push!(owners, JuMP.owner_model(value))
        end
    end
    isempty(owners) && return nothing
    owner = first(owners)
    all(candidate -> candidate === owner, owners) || throw(ArgumentError(
        "public PowerModels scalar :$(key) entries belong to multiple JuMP models",
    ))
    return owner
end

"""
    NLPDiagnostics.analyze(pm::PowerModels.AbstractPowerModel; ...)

Run the generic analysis on the single JuMP model recovered from public scalar
PowerModels variables, then append PowerModels data-level reference evidence.
This method does not automatically add angle-gauge declarations: callers must
opt in with `powermodels_angle_gauge_modes` after choosing an appropriate
evaluation point and confirming formulation semantics.
"""
function NLPDiagnostics.analyze(
    pm::PowerModels.AbstractPowerModel;
    owner_variable_key::Symbol = :va,
    include_reference_bus_report::Bool = true,
    kwargs...,
)
    model = NLPDiagnostics.powermodels_jump_model(pm; key = owner_variable_key)
    isnothing(model) && throw(ArgumentError(
        "Cannot recover a JuMP model from public scalar :$(owner_variable_key) variables. " *
        "Choose a scalar formulation variable key or analyze the JuMP model directly.",
    ))
    report = NLPDiagnostics.analyze(JuMP.backend(model); kwargs...)
    metadata = NLPDiagnostics.powermodels_component_metadata(pm)
    coordinate_semantics = NLPDiagnostics.component_coordinate_semantics(pm)
    capability_report = NLPDiagnostics.powermodels_capability_report(pm)
    merge!(report.metadata, capability_report.metadata)
    append!(report.findings, capability_report.findings)
    report.metadata[:powermodels_component_metadata_count] = string(length(metadata))
    report.metadata[:powermodels_component_coordinate_semantics_count] =
        string(length(coordinate_semantics))
    report.metadata[:powermodels_owner_variable_key] = string(owner_variable_key)
    model_snapshot = NLPDiagnostics.snapshot(JuMP.backend(model))
    metadata_validation = NLPDiagnostics._component_metadata_findings(
        metadata;
        model_variables = [record.index for record in model_snapshot.variables],
        model_constraints = [
            NLPDiagnostics._constraint_ref(record) for record in model_snapshot.constraints
        ],
    )
    append!(report.findings, metadata_validation.findings)
    report.metadata[:powermodels_component_metadata_validation_finding_count] =
        string(length(metadata_validation.findings))
    coordinate_semantics_validation = NLPDiagnostics._component_coordinate_semantics_findings(
        coordinate_semantics,
        [record.index for record in model_snapshot.variables],
        components = metadata,
    )
    append!(report.findings, coordinate_semantics_validation.findings)
    report.metadata[:powermodels_component_coordinate_semantics_validation_finding_count] =
        string(length(coordinate_semantics_validation.findings))
    if include_reference_bus_report
        reference_report = NLPDiagnostics.powermodels_reference_bus_report(pm)
        append!(report.findings, reference_report.findings)
        report.metadata[:powermodels_reference_bus_report_included] = "true"
    else
        report.metadata[:powermodels_reference_bus_report_included] = "false"
    end
    sort!(report.findings; by = finding -> (-Int(finding.severity), string(finding.code)))
    return report
end

"""
    NLPDiagnostics.powermodels_analyze_degeneracy(pm, point; ...)

Run generic local degeneracy analysis on the public scalar-variable owner model
and, by default, include missing-reference common-angle candidates derived from
PowerModels data. The candidates remain representational expectations; observed
alignment is evaluated by the generic MOI Jacobian analysis.
"""
function NLPDiagnostics.powermodels_analyze_degeneracy(
    pm::PowerModels.AbstractPowerModel,
    point;
    owner_variable_key::Symbol = :va,
    include_angle_gauge_modes::Bool = true,
    expected_modes::AbstractVector{<:NLPDiagnostics.ExpectedNullspaceMode} =
        NLPDiagnostics.ExpectedNullspaceMode[],
    kwargs...,
)
    model = NLPDiagnostics.powermodels_jump_model(pm; key = owner_variable_key)
    isnothing(model) && throw(ArgumentError(
        "Cannot recover a JuMP model from public scalar :$(owner_variable_key) variables.",
    ))
    backend = JuMP.backend(model)
    evaluation = NLPDiagnostics.evaluate_numerical(backend, point)
    angle_modes = include_angle_gauge_modes ?
                  NLPDiagnostics.powermodels_angle_gauge_modes(
                      pm, evaluation; angle_key = owner_variable_key,
                  ) : NLPDiagnostics.ExpectedNullspaceMode[]
    report = NLPDiagnostics.analyze_degeneracy(
        backend, evaluation;
        expected_modes = vcat(expected_modes, angle_modes),
        kwargs...,
    )
    report.metadata[:powermodels_angle_gauge_mode_count] = string(length(angle_modes))
    report.metadata[:powermodels_angle_gauge_modes_included] =
        string(include_angle_gauge_modes)
    return report
end

"""
    NLPDiagnostics.powermodels_analyze_active_set(pm, point; ...)

Run generic active-set analysis on the recovered MOI backend and, by default,
screen missing-reference scalar angle candidates against the selected active
Jacobian. This remains local tangent evidence rather than a claim about OPF
reference correctness.
"""
function NLPDiagnostics.powermodels_analyze_active_set(
    pm::PowerModels.AbstractPowerModel,
    point;
    owner_variable_key::Symbol = :va,
    include_angle_gauge_modes::Bool = true,
    expected_modes::AbstractVector{<:NLPDiagnostics.ExpectedNullspaceMode} =
        NLPDiagnostics.ExpectedNullspaceMode[],
    kwargs...,
)
    model = NLPDiagnostics.powermodels_jump_model(pm; key = owner_variable_key)
    isnothing(model) && throw(ArgumentError(
        "Cannot recover a JuMP model from public scalar :$(owner_variable_key) variables.",
    ))
    backend = JuMP.backend(model)
    evaluation = NLPDiagnostics.evaluate_numerical(backend, point)
    angle_modes = include_angle_gauge_modes ?
                  NLPDiagnostics.powermodels_angle_gauge_modes(
                      pm, evaluation; angle_key = owner_variable_key,
                  ) : NLPDiagnostics.ExpectedNullspaceMode[]
    report = NLPDiagnostics.analyze_active_set(
        backend, evaluation;
        expected_modes = vcat(expected_modes, angle_modes),
        kwargs...,
    )
    report.metadata[:powermodels_angle_gauge_mode_count] = string(length(angle_modes))
    report.metadata[:powermodels_angle_gauge_modes_included] =
        string(include_angle_gauge_modes)
    return report
end

"""
    NLPDiagnostics.powermodels_analyze_reduced_hessian_persistence(pm, snapshots; ...)

Compare generic persistent reduced-Hessian flat directions with optional
missing-reference scalar angle candidates. The supplied snapshots remain the
only numerical evidence; PowerModels reference data supplies provenance for a
candidate direction, not a curvature explanation.
"""
function NLPDiagnostics.powermodels_analyze_reduced_hessian_persistence(
    pm::PowerModels.AbstractPowerModel,
    snapshots::AbstractVector{<:NLPDiagnostics.ReducedHessianSnapshot};
    owner_variable_key::Symbol = :va,
    include_angle_gauge_modes::Bool = true,
    expected_modes::AbstractVector{<:NLPDiagnostics.ExpectedNullspaceMode} =
        NLPDiagnostics.ExpectedNullspaceMode[],
    kwargs...,
)
    model = NLPDiagnostics.powermodels_jump_model(pm; key = owner_variable_key)
    isnothing(model) && throw(ArgumentError(
        "Cannot recover a JuMP model from public scalar :$(owner_variable_key) variables.",
    ))
    angle_modes = include_angle_gauge_modes && !isempty(snapshots) ?
                  NLPDiagnostics.powermodels_angle_gauge_modes(
                      pm, first(snapshots).evaluation; angle_key = owner_variable_key,
                  ) : NLPDiagnostics.ExpectedNullspaceMode[]
    report = NLPDiagnostics.analyze_reduced_hessian_persistence(
        JuMP.backend(model), snapshots;
        expected_modes = vcat(expected_modes, angle_modes),
        kwargs...,
    )
    report.metadata[:powermodels_angle_gauge_mode_count] = string(length(angle_modes))
    report.metadata[:powermodels_angle_gauge_modes_included] =
        string(include_angle_gauge_modes)
    return report
end

"""
    NLPDiagnostics.powermodels_angle_gauge_modes(pm, evaluation; angle_key = :va)

Construct one common-angle candidate for each PowerModels network that declares
no reference bus and exposes scalar angle variables through public `var`.
The candidate is deliberately opt-in: callers pass it as `expected_modes` to
generic MOI/JuMP degeneracy analysis after confirming that their formulation
uses `angle_key` as an angle coordinate.
"""
function NLPDiagnostics.powermodels_angle_gauge_modes(
    pm::PowerModels.AbstractPowerModel,
    evaluation::NLPDiagnostics.NumericalEvaluation;
    angle_key::Symbol = :va,
)
    indices = NLPDiagnostics.powermodels_variable_indices(pm, angle_key)
    modes = NLPDiagnostics.ExpectedNullspaceMode[]
    for network in sort!(collect(PowerModels.nw_ids(pm)))
        references = _pm_component_entries(pm, network, :ref_buses)
        reference_ids = isnothing(references) ? Set{Any}() : Set(keys(references))
        components = _pm_component_entries(pm, network, :components)
        scopes = isnothing(components) ? [(nothing, nothing)] :
                 sort!(collect(components); by = first)
        for (component_id, bus_ids) in scopes
            scope_bus_ids = isnothing(bus_ids) ? nothing : Set(bus_ids)
            !isnothing(scope_bus_ids) && !isempty(intersect(reference_ids, scope_bus_ids)) &&
                continue
            pairs = sort!(
                [(bus_id, index) for ((network_id, bus_id), index) in indices
                 if network_id == network &&
                    (isnothing(scope_bus_ids) || bus_id in scope_bus_ids)];
                by = first,
            )
            isempty(pairs) && continue
            variables = MOI.VariableIndex[last(pair) for pair in pairs]
            suffix = isnothing(component_id) ? "" : "_component_$(component_id)"
            scope_text = isnothing(component_id) ? "network $(network)" :
                         "network $(network) connected component $(component_id)"
            push!(modes, NLPDiagnostics.ExpectedNullspaceMode(
                Symbol("powermodels_angle_gauge_network_", network, suffix),
                variables,
                ones(Float64, length(variables));
                description = "Candidate common-angle shift from PowerModels $(scope_text) with no declared reference bus and scalar :$(angle_key) variables.",
            ))
        end
    end
    return modes
end

"""PowerModels extension boundary and public-reference metadata adapter."""
const POWER_MODELS_EXTENSION_READY = true

end
