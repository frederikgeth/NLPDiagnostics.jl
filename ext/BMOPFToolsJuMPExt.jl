module BMOPFToolsJuMPExt

import BMOPFTools
import JuMP
import NLPDiagnostics
import MathOptInterface
import LinearAlgebra
import SparseArrays

const MOI = MathOptInterface

function _bmopf_context_model(context)
    try
        return BMOPFTools.opf_model(context)
    catch error
        error isa MethodError || rethrow()
        throw(ArgumentError(
            "context is not a staged BMOPFTools OPF context; build it with " *
            "BMOPFTools.build_opf_model after loading BMOPFTools' JuMP/IPOPT extension",
        ))
    end
end

function _bmopf_bus_terminals(context)
    network = BMOPFTools.opf_network(context)
    buses = get(network, "bus", Dict())
    return [(string(bus_id), String.(get(bus, "terminal_names", String[])))
            for (bus_id, bus) in sort!(collect(buses); by = entry -> string(first(entry)))
            if bus isa AbstractDict]
end

function _bmopf_neutral_terminal_labels(context)
    try
        return Set(String.(BMOPFTools.opf_neutral_labels(context)))
    catch error
        error isa MethodError || rethrow()
        return Set(["n", "neutral"])
    end
end

"""Build ordered voltage-coordinate semantics from public BMOPF terminal data."""
function _bmopf_voltage_terminal_semantics(
    context, bus::String, terminals::Vector{String},
)
    network = BMOPFTools.opf_network(context)
    buses = get(network, "bus", Dict())
    bus_data = get(buses, bus, Dict())
    explicitly_grounded = Set(String.(
        bus_data isa AbstractDict ?
        get(bus_data, "perfectly_grounded_terminals", String[]) : String[],
    ))
    # BMOPFTools also treats the declared neutral of a voltage-source bus as a
    # zero-voltage ground reference. Derive that only from public network data.
    source_bus = any(
        source isa AbstractDict && string(get(source, "bus", "")) == bus for
        source in values(get(network, "voltage_source", Dict()))
    )
    neutral_labels = _bmopf_neutral_terminal_labels(context)
    declared_neutral = if bus_data isa AbstractDict &&
                          haskey(bus_data, "neutral_terminal")
        string(bus_data["neutral_terminal"])
    else
        candidates = [terminal for terminal in terminals if terminal in neutral_labels]
        length(candidates) == 1 ? only(candidates) : nothing
    end
    source_bus && !isnothing(declared_neutral) &&
        push!(explicitly_grounded, declared_neutral)

    per_unit = !isnothing(BMOPFTools.opf_bases(context))
    voltage_base = _bmopf_voltage_base(context, bus)
    reference_tolerance = sqrt(eps(Float64)) *
        (per_unit ? 1.0 : something(voltage_base, 1.0))
    return NLPDiagnostics.PortTerminalCoordinateSemantics[
        if terminal in explicitly_grounded
            NLPDiagnostics.PortTerminalCoordinateSemantics(
                terminal;
                role = :ground_reference,
                nominal_scale = nothing,
                expected_value = 0.0,
                absolute_tolerance = reference_tolerance,
                description = "BMOPFTools public network data declares this terminal fixed to ground reference",
            )
        elseif terminal in neutral_labels
            NLPDiagnostics.PortTerminalCoordinateSemantics(
                terminal;
                role = :neutral,
                nominal_scale = nothing,
                description = "Explicit neutral voltage; no phase-voltage coordinate scale is inferred",
            )
        else
            NLPDiagnostics.PortTerminalCoordinateSemantics(
                terminal;
                role = :phase,
                nominal_scale = per_unit ? 1.0 : nothing,
                description = "BMOPFTools phase-terminal voltage coordinate",
            )
        end for terminal in terminals
    ]
end

function _bmopf_terminal_variables(context, bus::String, terminals::Vector{String}, component::Symbol)
    variables = MOI.VariableIndex[]
    for terminal in terminals
        object = BMOPFTools.opf_object(
            context, BMOPFTools.opf_bus_voltage_key(bus, terminal; component = component),
        )
        object isa JuMP.VariableRef || throw(ArgumentError(
            "BMOPFTools voltage registry entry for bus '$bus', terminal '$terminal', " *
            "component '$component' is not a JuMP.VariableRef",
        ))
        push!(variables, JuMP.index(object))
    end
    return variables
end

const _BMOPF_ATTACHMENT_FAMILIES = (
    ("load", :load),
    ("generator", :generator),
    ("voltage_source", :voltage_source),
    ("shunt", :shunt),
    ("capacitor", :capacitor),
    ("ibr", :ibr),
    ("switch", :switch),
)

"""Return a device's declared terminal map and owning bus, if available."""
function _bmopf_attachment_endpoints(device)
    device isa AbstractDict || return nothing
    bus = get(device, "bus", nothing)
    bus === nothing && return nothing
    terminals = get(device, "terminal_map", nothing)
    terminals === nothing && return nothing
    return (string(bus), string.(terminals))
end

"""Build a finite embedding from a device terminal order into a bus terminal order."""
function _bmopf_terminal_embedding(bus_terminals, device_terminals)
    matrix = zeros(Float64, length(bus_terminals), length(device_terminals))
    positions = Dict(string(terminal) => index for (index, terminal) in enumerate(bus_terminals))
    for (column, terminal) in enumerate(device_terminals)
        row = get(positions, string(terminal), 0)
        iszero(row) && return nothing
        matrix[row, column] = 1.0
    end
    return matrix
end

"""Append one component attachment port and its bus connection for each rectangular component."""
function _bmopf_append_attachment_port!(ports, maps, semantics, connections, skipped,
                                        context, component_type::Symbol,
                                        component_id::String, port_role::String,
                                        bus::String, device_terminals::Vector{String})
    buses = Dict(_bmopf_bus_terminals(context))
    bus_terminals = get(buses, bus, nothing)
    if isnothing(bus_terminals) || isempty(device_terminals)
        push!(skipped, "$(component_type):$(component_id):$(port_role)")
        return
    end
    embedding = _bmopf_terminal_embedding(bus_terminals, device_terminals)
    if isnothing(embedding)
        push!(skipped, "$(component_type):$(component_id):$(port_role)")
        return
    end
    per_unit = !isnothing(BMOPFTools.opf_bases(context))
    unit = per_unit ? "p.u." : "V"
    for component in (:real, :imag)
        port_id = "$(port_role)_$(component)"
        variables = MOI.VariableIndex[]
        for terminal in device_terminals
            object = BMOPFTools.opf_object(
                context, BMOPFTools.opf_bus_voltage_key(bus, terminal; component = component),
            )
            object isa JuMP.VariableRef || begin
                push!(skipped, "$(component_type):$(component_id):$(port_id)")
                variables = MOI.VariableIndex[]
                break
            end
            push!(variables, JuMP.index(object))
        end
        length(variables) == length(device_terminals) || continue
        metadata = Dict{String,String}(
            "source" => "BMOPFTools public terminal map",
            "port_role" => port_role,
            "bus" => bus,
            "attachment" => "bus terminal coordinate sharing",
        )
        push!(ports, NLPDiagnostics.ComponentPortMetadata(
            component_type, component_id, port_id;
            terminal_labels = device_terminals,
            mode_labels = device_terminals,
            variables = variables,
            connection_matrix = Matrix{Float64}(LinearAlgebra.I, length(device_terminals), length(device_terminals)),
            metadata = metadata,
        ))
        push!(maps, NLPDiagnostics.PortCoordinateMap(
            component_type, component_id, port_id, variables;
            terminal_to_variable = Matrix{Float64}(LinearAlgebra.I, length(device_terminals), length(device_terminals)),
            description = "BMOPFTools $(component_type) $(component_id) $(port_role) rectangular $(component) terminal map",
        ))
        push!(semantics, NLPDiagnostics.PortCoordinateSemantics(
            component_type, component_id, port_id;
            quantity = :voltage,
            representation = _bmopf_representation(component),
            units = Dict("voltage" => unit),
            terminal_semantics = _bmopf_voltage_terminal_semantics(
                context, bus, device_terminals,
            ),
            description = "BMOPFTools $(component_type) $(component_id) $(port_role) terminal voltage attached to bus $(bus)",
        ))
        push!(connections, NLPDiagnostics.PortConnectionMetadata(
            component_type, component_id, port_id,
            :bus, bus, _bmopf_port_id(component),
            embedding,
            Dict{String,String}(
                "source" => "BMOPFTools public terminal map",
                "role" => "attachment",
                "bus" => bus,
                "terminal_labels" => join(device_terminals, ","),
            ),
        ))
    end
end

"""Collect explicitly declared component-to-bus attachment ports.

These maps describe shared terminal coordinates only. They do not assert that
branch endpoint voltages are equal, and therefore are not used as constitutive
equations for lines or transformers.
"""
function _bmopf_attachment_port_declarations(context)
    network = BMOPFTools.opf_network(context)
    ports = NLPDiagnostics.ComponentPortMetadata{Float64}[]
    maps = NLPDiagnostics.PortCoordinateMap{Float64}[]
    semantics = NLPDiagnostics.PortCoordinateSemantics[]
    connections = NLPDiagnostics.PortConnectionMetadata{Float64}[]
    skipped = String[]
    for (family, component_type) in _BMOPF_ATTACHMENT_FAMILIES
        table = get(network, family, Dict())
        table isa AbstractDict || continue
        for (identifier, device) in sort!(collect(table); by = entry -> string(first(entry)))
            endpoint = _bmopf_attachment_endpoints(device)
            isnothing(endpoint) && continue
            bus, terminals = endpoint
            _bmopf_append_attachment_port!(ports, maps, semantics, connections, skipped,
                                           context, component_type, string(identifier),
                                           "terminal", bus, terminals)
        end
    end
    # Lines expose two endpoint maps. They are attachment ports, not a claim
    # that the line's two terminal voltages are identical.
    line_table = get(network, "line", Dict())
    if line_table isa AbstractDict
        for (identifier, line) in sort!(collect(line_table); by = entry -> string(first(entry)))
            line isa AbstractDict || continue
            for (role, bus_key, map_key) in (("from", "bus_from", "terminal_map_from"),
                                             ("to", "bus_to", "terminal_map_to"))
                bus = get(line, bus_key, nothing)
                terminals = get(line, map_key, nothing)
                (bus === nothing || terminals === nothing) && continue
                _bmopf_append_attachment_port!(ports, maps, semantics, connections, skipped,
                                               context, :line, string(identifier), role,
                                               string(bus), string.(terminals))
            end
        end
    end
    # Transformers expose winding/end terminal maps. They are attachment
    # declarations only: the transformer's voltage/current constitutive map is
    # not represented as an equality between its two bus endpoints.
    transformer_table = get(network, "transformer", Dict())
    if transformer_table isa AbstractDict
        for (subtype, records) in sort!(collect(transformer_table); by = entry -> string(first(entry)))
            records isa AbstractDict || continue
            for (identifier, transformer) in sort!(collect(records); by = entry -> string(first(entry)))
                transformer isa AbstractDict || continue
                component_id = "$(subtype):$(identifier)"
                if string(subtype) == "n_winding"
                    windings = get(transformer, "windings", Any[])
                    windings isa AbstractVector || continue
                    for (winding_index, winding) in enumerate(windings)
                        winding isa AbstractDict || continue
                        bus = get(winding, "bus", nothing)
                        terminals = get(winding, "terminal_map", nothing)
                        (bus === nothing || terminals === nothing) && continue
                        _bmopf_append_attachment_port!(
                            ports, maps, semantics, connections, skipped, context,
                            :transformer, component_id, "winding$(winding_index)",
                            string(bus), string.(terminals),
                        )
                    end
                else
                    for (role, bus_key, map_key) in (("from", "bus_from", "terminal_map_from"),
                                                     ("to", "bus_to", "terminal_map_to"))
                        bus = get(transformer, bus_key, nothing)
                        terminals = get(transformer, map_key, nothing)
                        (bus === nothing || terminals === nothing) && continue
                        _bmopf_append_attachment_port!(
                            ports, maps, semantics, connections, skipped, context,
                            :transformer, component_id, role,
                            string(bus), string.(terminals),
                        )
                    end
                end
            end
        end
    end
    return (ports = ports, maps = maps, semantics = semantics,
            connections = connections, skipped = skipped)
end

"""Resolve the physical winding/configuration label for one attachment port."""
function _bmopf_attachment_configuration(network, port)
    component_type = port.component_type
    if component_type in (:load, :generator, :voltage_source, :shunt, :capacitor, :ibr)
        record = get(get(network, string(component_type), Dict()), port.component_id, nothing)
        record isa AbstractDict || return nothing
        return uppercase(string(get(record, "configuration", "WYE")))
    elseif component_type == :transformer
        pieces = split(port.component_id, ":"; limit = 2)
        length(pieces) == 2 || return nothing
        subtype, identifier = pieces
        records = get(get(network, "transformer", Dict()), subtype, Dict())
        record = get(records, identifier, nothing)
        record isa AbstractDict || return nothing
        role = first(split(port.port_id, "_"))
        if subtype == "n_winding" && startswith(role, "winding")
            index_text = replace(role, "winding" => "")
            index = tryparse(Int, index_text)
            isnothing(index) && return nothing
            windings = get(record, "windings", Any[])
            1 <= index <= length(windings) || return nothing
            winding = windings[index]
            winding isa AbstractDict || return nothing
            return uppercase(string(get(winding, "configuration", "WYE")))
        elseif subtype == "wye_delta"
            return role == "to" ? "DELTA" : "WYE"
        elseif subtype == "delta_wye"
            return role == "from" ? "DELTA" : "WYE"
        end
        return "WYE"
    end
    return nothing
end

"""Declare conservative expected hidden voltage modes for supported port semantics.

These are physical expectations, not claims about a compiled model's nullspace:
delta and wye terminal constitutive relations can be invariant to a common
voltage shift, while grounding and network connectivity may remove that mode.
"""
function _bmopf_terminal_port_nullspace_declarations(context)
    network = BMOPFTools.opf_network(context)
    ports = _bmopf_terminal_port_metadata(context)
    modes = NLPDiagnostics.PortNullspaceMode{Float64}[]
    semantics = NLPDiagnostics.PortNullspaceModeSemantics[]
    for port in ports
        port.component_type == :bus && continue
        (endswith(port.port_id, "_real") || endswith(port.port_id, "_imag")) || continue
        configuration = _bmopf_attachment_configuration(network, port)
        configuration in ("WYE", "DELTA") || continue
        labels = port.terminal_labels
        length(labels) >= 2 || continue
        # WYE common-mode declarations are restricted to explicitly represented
        # neutral terminals. DELTA relations are line-to-line by construction.
        has_neutral = any(lowercase(label) in ("n", "neutral") for label in labels)
        configuration == "WYE" && !has_neutral && continue
        name = configuration == "DELTA" ? :delta_common_mode : :wye_common_mode
        category = configuration == "DELTA" ? :delta_common_mode : :common_mode
        description = configuration == "DELTA" ?
            "Expected common voltage-shift direction of a DELTA terminal constitutive relation; vector-group and network connections may remove it." :
            "Expected common voltage-shift direction of a WYE terminal constitutive relation with an explicit neutral; grounding and KCL may remove it."
        push!(modes, NLPDiagnostics.PortNullspaceMode(
            port.component_type, port.component_id, port.port_id, :terminal,
            ones(Float64, length(labels)); name = name, description = description,
        ))
        push!(semantics, NLPDiagnostics.PortNullspaceModeSemantics(
            port.component_type, port.component_id, port.port_id, name;
            category = category, description = description,
        ))
    end
    return (modes = modes, semantics = semantics)
end

"""Return a terminal-to-coil incidence matrix for a declared winding."""
function _bmopf_winding_incidence_matrix(terminals::Vector{String}, configuration::String;
                                         delta_roll::Int = -1)
    n = length(terminals)
    phases = [index for index in eachindex(terminals)
              if lowercase(terminals[index]) ∉ ("n", "neutral")]
    isempty(phases) && return nothing
    matrix = zeros(Float64, length(phases), n)
    if configuration == "WYE"
        neutral = findfirst(index -> lowercase(terminals[index]) in ("n", "neutral"), eachindex(terminals))
        for (row, phase) in enumerate(phases)
            matrix[row, phase] = 1.0
            !isnothing(neutral) && (matrix[row, neutral] = -1.0)
        end
    elseif configuration == "DELTA"
        length(phases) >= 2 || return nothing
        delta_roll in (-1, 1) || return nothing
        for (row, phase_position) in enumerate(eachindex(phases))
            other_position = mod1(phase_position + delta_roll, length(phases))
            matrix[row, phases[phase_position]] = 1.0
            matrix[row, phases[other_position]] = -1.0
        end
    else
        return nothing
    end
    return matrix
end

function _bmopf_transformer_coil_ratio(transformer::AbstractDict, subtype::String)
    v_from = get(transformer, "v_nom_from", nothing)
    v_to = get(transformer, "v_nom_to", nothing)
    (v_from isa Real && v_to isa Real && isfinite(v_from) && isfinite(v_to) && v_from > 0 && v_to > 0) || return nothing
    tap = get(transformer, "tap", 1.0)
    tap isa Real && isfinite(tap) && tap > 0 || return nothing
    nominal = Float64(v_from) / Float64(v_to) * Float64(tap)
    subtype == "wye_delta" && return nominal / sqrt(3.0)
    subtype == "delta_wye" && return 1.0 / (nominal * sqrt(3.0))
    return nominal
end

"""Return a declared transformer vector-group label when one is available."""
function _bmopf_transformer_vector_group(transformer::AbstractDict, subtype::String)
    for key in ("vector_group", "vector_group_label", "connection")
        value = get(transformer, key, nothing)
        value isa AbstractString && !isempty(strip(value)) && return uppercase(strip(value))
    end
    return uppercase(subtype)
end

"""Return an explicitly declared transformer phase shift in degrees, if present."""
function _bmopf_transformer_phase_shift(transformer::AbstractDict)
    for key in ("phase_shift_degrees", "phase_shift_deg", "phase_shift")
        value = get(transformer, key, nothing)
        value isa Real && isfinite(value) && return Float64(value)
    end
    return 0.0
end

"""Resolve a delta orientation without inventing one from an invalid value."""
function _bmopf_transformer_delta_roll(transformer::AbstractDict, default::Int)
    value = get(transformer, "delta_roll", default)
    value isa Real || return (default, false)
    roll = Int(value)
    return roll in (-1, 1) ? (roll, true) : (default, false)
end

"""Build constitutive voltage maps from BMOPFTools terminal/configuration metadata."""
function _bmopf_build_terminal_constitutive_maps(context)
    network = BMOPFTools.opf_network(context)
    ports = _bmopf_terminal_port_metadata(context)
    port_keys = Set((port.component_type, port.component_id, port.port_id) for port in ports)
    maps = NLPDiagnostics.PortConstitutiveMap{Float64}[]
    add_map!(component_type, component_id, map_id, port_ids, labels, matrix, equations, metadata) = begin
        all((component_type, component_id, port_id) in port_keys for port_id in port_ids) || return
        push!(maps, NLPDiagnostics.PortConstitutiveMap(
            component_type, component_id, map_id, port_ids, labels, matrix;
            equation_labels = equations, metadata = metadata,
        ))
    end

    for (family, component_type) in _BMOPF_ATTACHMENT_FAMILIES
        table = get(network, family, Dict())
        table isa AbstractDict || continue
        for (identifier, device) in sort!(collect(table); by = entry -> string(first(entry)))
            endpoint = _bmopf_attachment_endpoints(device)
            isnothing(endpoint) && continue
            _, terminals = endpoint
            configuration = uppercase(string(get(device, "configuration", "WYE")))
            configuration in ("WYE", "DELTA") || continue
            roll = Int(get(device, "delta_roll", -1))
            incidence = _bmopf_winding_incidence_matrix(terminals, configuration; delta_roll = roll)
            isnothing(incidence) && continue
            labels = [string.(terminals)]
            for component in ("real", "imag")
                add_map!(component_type, string(identifier),
                         "terminal_voltage_to_coil_voltage_$(component)",
                         ["terminal_$(component)"], labels, incidence,
                         ["coil_$(index)" for index in axes(incidence, 1)],
                         Dict("source" => "BMOPFTools public terminal/configuration metadata",
                              "map_role" => "constitutive",
                              "configuration" => configuration,
                              "delta_roll" => string(roll),
                              "coordinate_component" => component))
            end
        end
    end

    transformer_table = get(network, "transformer", Dict())
    if transformer_table isa AbstractDict
        for (subtype, records) in sort!(collect(transformer_table); by = entry -> string(first(entry)))
            records isa AbstractDict || continue
            for (identifier, transformer) in sort!(collect(records); by = entry -> string(first(entry)))
                transformer isa AbstractDict || continue
                component_id = "$(subtype):$(identifier)"
                if string(subtype) == "n_winding"
                    windings = get(transformer, "windings", Any[])
                    windings isa AbstractVector || continue
                    for (winding_index, winding) in enumerate(windings)
                        winding isa AbstractDict || continue
                        terminals = string.(get(winding, "terminal_map", String[]))
                        configuration = uppercase(string(get(winding, "configuration", "WYE")))
                        roll = Int(get(winding, "delta_roll", -1))
                        incidence = _bmopf_winding_incidence_matrix(terminals, configuration; delta_roll = roll)
                        isnothing(incidence) && continue
                        labels = [terminals]
                        for component in ("real", "imag")
                            add_map!(:transformer, component_id,
                                     "winding$(winding_index)_coil_incidence_$(component)",
                                     ["winding$(winding_index)_$(component)"], labels, incidence,
                                     ["coil_$(index)" for index in axes(incidence, 1)],
                                     Dict("source" => "BMOPFTools public transformer winding metadata",
                                         "map_role" => "constitutive",
                                          "configuration" => configuration,
                                          "delta_roll" => string(roll),
                                          "vector_group" => uppercase(string(get(winding, "vector_group", configuration))),
                                          "winding" => string(winding_index),
                                          "coordinate_component" => component))
                        end
                    end
                elseif string(subtype) in ("wye_delta", "delta_wye", "single_phase")
                    from_terminals = string.(get(transformer, "terminal_map_from", String[]))
                    to_terminals = string.(get(transformer, "terminal_map_to", String[]))
                    isempty(from_terminals) && continue
                    isempty(to_terminals) && continue
                    ratio = _bmopf_transformer_coil_ratio(transformer, string(subtype))
                    isnothing(ratio) && continue
                    vector_group = _bmopf_transformer_vector_group(transformer, string(subtype))
                    phase_shift = _bmopf_transformer_phase_shift(transformer)
                    single_phase = string(subtype) == "single_phase"
                    wye_is_from = string(subtype) != "delta_wye"
                    wye_terminals = wye_is_from ? from_terminals : to_terminals
                    delta_terminals = wye_is_from ? to_terminals : from_terminals
                    wye_matrix = _bmopf_winding_incidence_matrix(wye_terminals, "WYE")
                    default_roll = wye_is_from ? 1 : -1
                    delta_roll, delta_roll_declared = _bmopf_transformer_delta_roll(transformer, default_roll)
                    delta_matrix = _bmopf_winding_incidence_matrix(
                        delta_terminals, single_phase ? "WYE" : "DELTA";
                        delta_roll = delta_roll,
                    )
                    (isnothing(wye_matrix) || isnothing(delta_matrix)) && continue
                    rows = min(size(wye_matrix, 1), size(delta_matrix, 1))
                    rows > 0 || continue
                    matrix = zeros(Float64, rows, length(from_terminals) + length(to_terminals))
                    if wye_is_from
                        matrix[:, 1:length(from_terminals)] .= wye_matrix[1:rows, :]
                        matrix[:, length(from_terminals)+1:end] .= -ratio .* delta_matrix[1:rows, :]
                    else
                        matrix[:, 1:length(from_terminals)] .= -ratio .* delta_matrix[1:rows, :]
                        matrix[:, length(from_terminals)+1:end] .= wye_matrix[1:rows, :]
                    end
                    labels = [from_terminals, to_terminals]
                    for component in ("real", "imag")
                        add_map!(:transformer, component_id,
                                 "ideal_winding_coupling_$(component)",
                                 ["from_$(component)", "to_$(component)"], labels, matrix,
                                 ["ideal_coil_$(index)" for index in 1:rows],
                                 Dict("source" => "BMOPFTools public transformer schema",
                                      "map_role" => "constitutive",
                                      "subtype" => string(subtype),
                                      "vector_group" => vector_group,
                                      "wye_side" => wye_is_from ? "from" : "to",
                                      "coil_ratio_wye_to_delta" => string(ratio),
                                      "phase_shift_degrees" => string(phase_shift),
                                      "phase_shift_applied" => "false",
                                      "delta_roll" => string(delta_roll),
                                      "delta_roll_declared" => string(delta_roll_declared),
                                      "coordinate_component" => component))
                    end
                end
            end
        end
    end
    return maps
end

"""Build phase-aware real block maps for fixed transformer voltage coupling."""
function _bmopf_build_terminal_complex_constitutive_maps(context)
    network = BMOPFTools.opf_network(context)
    ports = _bmopf_terminal_port_metadata(context)
    port_keys = Set((port.component_type, port.component_id, port.port_id) for port in ports)
    maps = NLPDiagnostics.PortConstitutiveMap{Float64}[]
    add_map!(component_id, port_ids, labels, matrix, equations, metadata) = begin
        all((:transformer, component_id, port_id) in port_keys for port_id in port_ids) || return
        push!(maps, NLPDiagnostics.PortConstitutiveMap(
            :transformer, component_id, "ideal_winding_coupling_complex",
            port_ids, labels, matrix;
            equation_labels = equations, metadata = metadata,
        ))
    end
    transformer_table = get(network, "transformer", Dict())
    transformer_table isa AbstractDict || return maps
    for (subtype, records) in sort!(collect(transformer_table); by = entry -> string(first(entry)))
        string(subtype) in ("wye_delta", "delta_wye", "single_phase") || continue
        records isa AbstractDict || continue
        for (identifier, transformer) in sort!(collect(records); by = entry -> string(first(entry)))
            transformer isa AbstractDict || continue
            from_terminals = string.(get(transformer, "terminal_map_from", String[]))
            to_terminals = string.(get(transformer, "terminal_map_to", String[]))
            isempty(from_terminals) && continue
            isempty(to_terminals) && continue
            ratio = _bmopf_transformer_coil_ratio(transformer, string(subtype))
            isnothing(ratio) && continue
            single_phase = string(subtype) == "single_phase"
            wye_is_from = string(subtype) != "delta_wye"
            wye_terminals = wye_is_from ? from_terminals : to_terminals
            delta_terminals = wye_is_from ? to_terminals : from_terminals
            wye_matrix = _bmopf_winding_incidence_matrix(wye_terminals, "WYE")
            default_roll = wye_is_from ? 1 : -1
            delta_roll, delta_roll_declared = _bmopf_transformer_delta_roll(transformer, default_roll)
            delta_matrix = _bmopf_winding_incidence_matrix(
                delta_terminals, single_phase ? "WYE" : "DELTA";
                delta_roll = delta_roll,
            )
            (isnothing(wye_matrix) || isnothing(delta_matrix)) && continue
            rows = min(size(wye_matrix, 1), size(delta_matrix, 1))
            rows > 0 || continue
            phase = deg2rad(_bmopf_transformer_phase_shift(transformer))
            cosine, sine = cos(phase), sin(phase)
            from_real = zeros(Float64, rows, length(from_terminals))
            from_imag = zeros(Float64, rows, length(from_terminals))
            to_real = zeros(Float64, rows, length(to_terminals))
            to_imag = zeros(Float64, rows, length(to_terminals))
            if wye_is_from
                from_real .= wye_matrix[1:rows, :]
                to_real .= -ratio .* cosine .* delta_matrix[1:rows, :]
                to_imag .= ratio .* sine .* delta_matrix[1:rows, :]
            else
                from_real .= -ratio .* cosine .* delta_matrix[1:rows, :]
                from_imag .= ratio .* sine .* delta_matrix[1:rows, :]
                to_real .= wye_matrix[1:rows, :]
            end
            matrix = zeros(Float64, 2 * rows,
                            2 * (length(from_terminals) + length(to_terminals)))
            from_real_range = 1:length(from_terminals)
            from_imag_range = (length(from_terminals) + 1):(2 * length(from_terminals))
            to_offset = 2 * length(from_terminals)
            to_real_range = (to_offset + 1):(to_offset + length(to_terminals))
            to_imag_range = (to_offset + length(to_terminals) + 1):(to_offset + 2 * length(to_terminals))
            matrix[1:rows, from_real_range] .= from_real
            matrix[1:rows, from_imag_range] .= -from_imag
            matrix[rows+1:end, from_real_range] .= from_imag
            matrix[rows+1:end, from_imag_range] .= from_real
            matrix[1:rows, to_real_range] .= to_real
            matrix[1:rows, to_imag_range] .= -to_imag
            matrix[rows+1:end, to_real_range] .= to_imag
            matrix[rows+1:end, to_imag_range] .= to_real
            component_id = "$(subtype):$(identifier)"
            vector_group = _bmopf_transformer_vector_group(transformer, string(subtype))
            phase_shift = _bmopf_transformer_phase_shift(transformer)
            add_map!(component_id,
                     ["from_real", "from_imag", "to_real", "to_imag"],
                     [from_terminals, from_terminals, to_terminals, to_terminals],
                     matrix,
                     vcat(["ideal_coil_$(index)_real" for index in 1:rows],
                          ["ideal_coil_$(index)_imag" for index in 1:rows]),
                     Dict("source" => "BMOPFTools public transformer schema",
                          "map_role" => "constitutive_complex",
                          "subtype" => string(subtype),
                          "vector_group" => vector_group,
                          "wye_side" => wye_is_from ? "from" : "to",
                          "coil_ratio_wye_to_delta" => string(ratio),
                          "phase_shift_degrees" => string(phase_shift),
                          "phase_shift_applied" => "true",
                          "delta_roll" => string(delta_roll),
                          "delta_roll_declared" => string(delta_roll_declared),
                          "coordinate_components" => "real_imag_block"))
        end
    end
    return maps
end

"""Append one rectangular current port when all of its public registry entries exist."""
function _bmopf_append_current_port!(ports, maps, semantics, skipped, context,
                                     component_type::Symbol, component_id::String,
                                     registry_id::String, port_role::String,
                                     bus::String, terminal_labels::Vector{String},
                                     terminal_count::Int, key_builder)
    terminal_count > 0 || return
    per_unit = !isnothing(BMOPFTools.opf_bases(context))
    current_base = _bmopf_current_base(context, bus)
    unit = per_unit ? "p.u." : "A"
    for component in (:real, :imag)
        variables = MOI.VariableIndex[]
        for conductor in 1:terminal_count
            key = key_builder(registry_id, conductor; component = component)
            object = try
                BMOPFTools.opf_object(context, key)
            catch
                nothing
            end
            if !(object isa JuMP.VariableRef)
                push!(skipped, "$(component_type):$(component_id):$(port_role)_current_$(component)")
                variables = MOI.VariableIndex[]
                break
            end
            push!(variables, JuMP.index(object))
        end
        length(variables) == terminal_count || continue
        port_id = "$(port_role)_current_$(component)"
        metadata = Dict{String,String}(
            "source" => "BMOPFTools public current registry",
            "quantity" => "current",
            "port_role" => port_role,
            "bus" => bus,
            "coordinate_component" => string(component),
        )
        !isnothing(current_base) && (metadata["physical_current_base_A"] = string(current_base))
        identity = Matrix{Float64}(LinearAlgebra.I, terminal_count, terminal_count)
        push!(ports, NLPDiagnostics.ComponentPortMetadata(
            component_type, component_id, port_id;
            terminal_labels = terminal_labels[1:terminal_count],
            mode_labels = terminal_labels[1:terminal_count],
            variables = variables,
            connection_matrix = identity,
            metadata = metadata,
        ))
        push!(maps, NLPDiagnostics.PortCoordinateMap(
            component_type, component_id, port_id, variables;
            terminal_to_variable = identity,
            description = "BMOPFTools $(component_type) $(component_id) $(port_role) rectangular $(component) terminal-current map",
        ))
        push!(semantics, NLPDiagnostics.PortCoordinateSemantics(
            component_type, component_id, port_id;
            quantity = :current,
            representation = _bmopf_representation(component),
            units = Dict("current" => unit),
            nominal_scale = per_unit ? 1.0 : nothing,
            description = "BMOPFTools $(component_type) $(component_id) $(port_role) terminal current",
        ))
    end
end

"""Count contiguous real/imag current coordinates exposed by a public key builder."""
function _bmopf_available_current_count(context, registry_id::String,
                                        key_builder, maximum::Int)
    count = 0
    for conductor in 1:maximum
        available = true
        for component in (:real, :imag)
            key = key_builder(registry_id, conductor; component = component)
            object = try
                BMOPFTools.opf_object(context, key)
            catch
                nothing
            end
            available &= object isa JuMP.VariableRef
        end
        available || break
        count += 1
    end
    return count
end

"""Collect current-coordinate ports from BMOPFTools' public variable-key registry.

Current ports intentionally have no voltage-style connection matrix: endpoint
currents participate in KCL/constitutive equations, so declaring their
coordinates is useful evidence but does not assert equality across a component.
"""
function _bmopf_current_port_declarations(context)
    network = BMOPFTools.opf_network(context)
    ports = NLPDiagnostics.ComponentPortMetadata{Float64}[]
    maps = NLPDiagnostics.PortCoordinateMap{Float64}[]
    semantics = NLPDiagnostics.PortCoordinateSemantics[]
    skipped = String[]
    buses = Dict(_bmopf_bus_terminals(context))
    terminal_count(bus, terminals) = length(get(buses, string(bus), String[])) > 0 ?
        length(string.(terminals)) : 0

    for (identifier, line) in sort!(collect(get(network, "line", Dict())); by = entry -> string(first(entry)))
        line isa AbstractDict || continue
        for (role, bus_key, map_key, side) in (("from", "bus_from", "terminal_map_from", :from),
                                                ("to", "bus_to", "terminal_map_to", :to))
            bus = get(line, bus_key, nothing)
            terminals = get(line, map_key, nothing)
            (bus === nothing || terminals === nothing) && continue
            n = terminal_count(bus, terminals)
            n > 0 || continue
            builder = (id, conductor; component = :real) ->
                BMOPFTools.opf_line_current_key(id, conductor; side = side, component = component)
            available = _bmopf_available_current_count(context, string(identifier), builder, n)
            available > 0 || continue
            _bmopf_append_current_port!(ports, maps, semantics, skipped, context,
                                        :line, string(identifier), string(identifier), role,
                                        string(bus), string.(terminals), available, builder)
        end
    end

    for (family, component_type, key_function) in (
        ("load", :load, BMOPFTools.opf_load_current_key),
        ("generator", :generator, BMOPFTools.opf_generator_current_key),
        ("voltage_source", :voltage_source, BMOPFTools.opf_voltage_source_current_key),
        ("ibr", :ibr, BMOPFTools.opf_ibr_current_key),
    )
        table = get(network, family, Dict())
        table isa AbstractDict || continue
        for (identifier, device) in sort!(collect(table); by = entry -> string(first(entry)))
            endpoint = _bmopf_attachment_endpoints(device)
            isnothing(endpoint) && continue
            bus, terminals = endpoint
            n = terminal_count(bus, terminals)
            n > 0 || continue
            builder = (id, conductor; component = :real) -> key_function(id, conductor; component = component)
            n = _bmopf_available_current_count(context, string(identifier), builder, max(n, 1))
            n > 0 || continue
            _bmopf_append_current_port!(ports, maps, semantics, skipped, context,
                                        component_type, string(identifier), string(identifier),
                                        "terminal", bus, string.(terminals), n, builder)
        end
    end

    switch_table = get(network, "switch", Dict())
    if switch_table isa AbstractDict
        for (identifier, switch) in sort!(collect(switch_table); by = entry -> string(first(entry)))
            switch isa AbstractDict || continue
            for (role, bus_key, map_key) in (("from", "bus_from", "terminal_map_from"),
                                              ("to", "bus_to", "terminal_map_to"))
                bus = get(switch, bus_key, nothing)
                terminals = get(switch, map_key, nothing)
                (bus === nothing || terminals === nothing) && continue
                n = terminal_count(bus, terminals)
                n > 0 || continue
                builder = (id, conductor; component = :real) ->
                    BMOPFTools.opf_switch_current_key(id, conductor; component = component)
                n = _bmopf_available_current_count(context, string(identifier), builder, max(n, 1))
                n > 0 || continue
                _bmopf_append_current_port!(ports, maps, semantics, skipped, context,
                                            :switch, string(identifier), string(identifier), role,
                                            string(bus), string.(terminals), n, builder)
            end
        end
    end

    transformer_table = get(network, "transformer", Dict())
    if transformer_table isa AbstractDict
        for (subtype, records) in sort!(collect(transformer_table); by = entry -> string(first(entry)))
            records isa AbstractDict || continue
            for (identifier, transformer) in sort!(collect(records); by = entry -> string(first(entry)))
                transformer isa AbstractDict || continue
                component_id = "$(subtype):$(identifier)"
                if string(subtype) == "n_winding"
                    windings = get(transformer, "windings", Any[])
                    windings isa AbstractVector || continue
                    for (winding_index, winding) in enumerate(windings)
                        winding isa AbstractDict || continue
                        bus = get(winding, "bus", nothing)
                        terminals = get(winding, "terminal_map", nothing)
                        (bus === nothing || terminals === nothing) && continue
                        n = terminal_count(bus, terminals)
                        n > 0 || continue
                        builder = (id, conductor; component = :real) ->
                            BMOPFTools.opf_nwinding_current_key(id, winding_index, conductor; component = component)
                        n = _bmopf_available_current_count(context, string(identifier), builder, max(n, 1))
                        n > 0 || continue
                        _bmopf_append_current_port!(ports, maps, semantics, skipped, context,
                                                    :transformer, component_id, string(identifier),
                                                    "winding$(winding_index)", string(bus), string.(terminals), n, builder)
                    end
                else
                    for (role, bus_key, map_key, side) in (("from", "bus_from", "terminal_map_from", :from),
                                                            ("to", "bus_to", "terminal_map_to", :to))
                        bus = get(transformer, bus_key, nothing)
                        terminals = get(transformer, map_key, nothing)
                        (bus === nothing || terminals === nothing) && continue
                        n = terminal_count(bus, terminals)
                        n > 0 || continue
                        builder = (id, conductor; component = :real) ->
                            BMOPFTools.opf_transformer_current_key(id, side, conductor; component = component)
                        n = _bmopf_available_current_count(context, string(identifier), builder, max(n, 1))
                        n > 0 || continue
                        _bmopf_append_current_port!(ports, maps, semantics, skipped, context,
                                                    :transformer, component_id, string(identifier), role,
                                                    string(bus), string.(terminals), n, builder)
                    end
                end
            end
        end
    end
    return (ports = ports, maps = maps, semantics = semantics, skipped = skipped)
end

_bmopf_port_id(component::Symbol) = component == :real ? "voltage_real" : "voltage_imag"
_bmopf_representation(component::Symbol) = component == :real ? :rectangular_real : :rectangular_imag

const _BMOPF_RESULT_FIELD_FAMILIES = (
    :bus_voltage,
    :line_current,
    :load_current,
    :generator_current,
    :generator_power,
    :source_current,
    :ibr_current,
    :ibr_power,
    :switch_current,
    :ground_current,
)

const _BMOPF_RESULT_FIELD_CATALOG = Dict{Symbol,NamedTuple}(
    :bus_voltage => (
        quantity = "rectangular terminal voltage",
        result_paths = ["bus/*/*/vr", "bus/*/*/vi"],
        model_key_families = ["vr", "vi"],
        base_kind = "voltage",
        physical_unit = "V",
        adapter_supported = true,
        notes = "Mapped through the public per-bus terminal voltage base when declared SI.",
    ),
    :line_current => (
        quantity = "rectangular branch-terminal current",
        result_paths = ["line/*/*/cr_fr", "line/*/*/ci_fr", "line/*/*/cr_to", "line/*/*/ci_to"],
        model_key_families = ["cr_fr", "ci_fr", "cr_to", "ci_to"],
        base_kind = "current",
        physical_unit = "A",
        adapter_supported = true,
        notes = "Mapped through the public current base at the corresponding terminal bus.",
    ),
    :load_current => (
        quantity = "rectangular load-terminal current",
        result_paths = ["load/*/*/crd", "load/*/*/cid"],
        model_key_families = ["crd", "cid"],
        base_kind = "current",
        physical_unit = "A",
        adapter_supported = true,
        notes = "Mapped through the public current base at the load bus.",
    ),
    :generator_current => (
        quantity = "rectangular generator-terminal current",
        result_paths = ["generator/*/*/crg", "generator/*/*/cig"],
        model_key_families = ["crg", "cig"],
        base_kind = "current",
        physical_unit = "A",
        adapter_supported = true,
        notes = "Mapped through the public current base at the generator bus.",
    ),
    :generator_power => (
        quantity = "generator active/reactive power from saved result",
        result_paths = ["generator/*/*/pg", "generator/*/*/qg"],
        model_key_families = String[],
        base_kind = "power",
        physical_unit = "W",
        adapter_supported = true,
        notes = "Used for saved-result equation residuals; the public model registry exposes the bilinear power map through voltage/current coordinates.",
    ),
    :source_current => (
        quantity = "rectangular voltage-source current",
        result_paths = ["voltage_source/*/*/cr", "voltage_source/*/*/ci"],
        model_key_families = ["cr_src", "ci_src"],
        base_kind = "current",
        physical_unit = "A",
        adapter_supported = true,
        notes = "Mapped through the public current base at the source bus.",
    ),
    :ibr_current => (
        quantity = "rectangular inverter-terminal current",
        result_paths = ["ibr/*/*/cri", "ibr/*/*/cii"],
        model_key_families = ["cri", "cii"],
        base_kind = "current",
        physical_unit = "A",
        adapter_supported = true,
        notes = "Mapped through the public current base at the IBR bus.",
    ),
    :ibr_power => (
        quantity = "IBR active/reactive power auxiliary",
        result_paths = ["ibr/*/*/pg", "ibr/*/*/qg"],
        model_key_families = ["p_ibr", "q_ibr"],
        base_kind = "power",
        physical_unit = "W",
        adapter_supported = true,
        notes = "Mapped through the public system power base; exported line/thermal powers are separate fields.",
    ),
    :ibr_voltage_magnitude => (
        quantity = "reconstructed IBR monitored-voltage magnitude",
        result_paths = ["derived:ibr/*/*/u_ibr"],
        model_key_families = ["u_ibr"],
        base_kind = "voltage",
        physical_unit = "V",
        adapter_supported = true,
        notes = "Reconstructed from saved bus rectangular voltages; not a direct saved-result field.",
    ),
    :switch_current => (
        quantity = "rectangular switch current",
        result_paths = ["switch/*/*/cr", "switch/*/*/ci"],
        model_key_families = ["cr_sw", "ci_sw"],
        base_kind = "current",
        physical_unit = "A",
        adapter_supported = true,
        notes = "Mapped through the public current base at the switch from-bus.",
    ),
    :ground_current => (
        quantity = "rectangular perfect-ground current",
        result_paths = ["ground/*/*/cg_r", "ground/*/*/cg_i"],
        model_key_families = ["cr_gnd", "ci_gnd"],
        base_kind = "current",
        physical_unit = "A",
        adapter_supported = true,
        notes = "Mapped through the public current base at the grounded bus.",
    ),
)

function _bmopf_result_field_catalog()
    return Dict{String,Any}(
        "catalog_version" => "bmopf-result-field-catalog-v1",
        "interpretation" => "Declared adapter semantics and conversion bases; this does not certify the units of any individual export file.",
        "families" => Dict{String,Any}(
            string(family) => Dict{String,Any}(
                "quantity" => entry.quantity,
                "result_paths" => copy(entry.result_paths),
                "model_key_families" => copy(entry.model_key_families),
                "base_kind" => entry.base_kind,
                "physical_unit" => entry.physical_unit,
                "adapter_supported" => entry.adapter_supported,
                "notes" => entry.notes,
            ) for (family, entry) in sort!(collect(_BMOPF_RESULT_FIELD_CATALOG); by = first)
        ),
    )
end

"""Normalize the optional per-family saved-result unit policy.

`result_units` remains the backwards-compatible default.  A field policy is
deliberately explicit: it prevents a mixed BMOPF export from being treated as
one homogeneous SI or per-unit file merely because its filename says so.
"""
function _bmopf_result_field_units(result_units::Symbol, field_units)
    result_units in (:si, :pu, :model) ||
        throw(ArgumentError("result_units must be :si, :pu, or :model"))
    field_units isa AbstractDict || throw(ArgumentError("field_units must be an AbstractDict mapping result families to :si, :pu, or :model"))
    policy = Dict{Symbol,Symbol}(family => result_units for family in _BMOPF_RESULT_FIELD_FAMILIES)
    for (raw_family, raw_unit) in field_units
        family = Symbol(lowercase(String(raw_family)))
        family in _BMOPF_RESULT_FIELD_FAMILIES || throw(ArgumentError(
            "unknown BMOPF saved-result field family '$family'; supported families are $(join(_BMOPF_RESULT_FIELD_FAMILIES, ", "))",
        ))
        unit = Symbol(lowercase(String(raw_unit)))
        unit in (:si, :pu, :model) || throw(ArgumentError(
            "unit for BMOPF saved-result field family '$family' must be :si, :pu, or :model",
        ))
        policy[family] = unit
    end
    return policy
end

_bmopf_result_field_units_string(policy) = join(
    ("$(family)=$(policy[family])" for family in _BMOPF_RESULT_FIELD_FAMILIES), ",",
)

"""Return a finite positive physical voltage base declared for a per-unit bus."""
function _bmopf_voltage_base(context, bus::String)
    bases = BMOPFTools.opf_bases(context)
    isnothing(bases) && return nothing
    hasproperty(bases, :v_base) || return nothing
    value = get(getproperty(bases, :v_base), bus, nothing)
    value isa Real && isfinite(value) && value > 0 || return nothing
    return Float64(value)
end

"""Return the public positive current base, or one for SI model coordinates."""
function _bmopf_current_base(context, bus::String)
    bases = BMOPFTools.opf_bases(context)
    isnothing(bases) && return 1.0
    hasproperty(bases, :i_base) || return nothing
    value = get(getproperty(bases, :i_base), bus, nothing)
    value isa Real && isfinite(value) && value > 0 || return nothing
    return Float64(value)
end

"""Return the public system power base, or one for SI model coordinates."""
function _bmopf_power_base(context)
    bases = BMOPFTools.opf_bases(context)
    isnothing(bases) && return 1.0
    hasproperty(bases, :s_base) || return nothing
    value = getproperty(bases, :s_base)
    value isa Real && isfinite(value) && value > 0 || return nothing
    return Float64(value)
end

function _bmopf_floating_neutral_components(context)
    network = BMOPFTools.opf_network(context)
    canonical = Dict{String,Any}(string(key) => value for (key, value) in network)
    engine_report = BMOPFTools.analyze(canonical)
    grounding = get(get(engine_report.results, :provenance, Dict{String,Any}()),
                    "grounding", Dict{String,Any}())
    get(grounding, "convention", "") == "explicit" || return Vector{Vector{String}}()
    return [sort!(string.(component)) for component in
            get(grounding, "floating_components", Vector{Vector{String}}())]
end

function _bmopf_floating_neutral_mode_variables(context, buses::Vector{String}, component::Symbol)
    terminals_by_bus = Dict(_bmopf_bus_terminals(context))
    variables = MOI.VariableIndex[]
    for bus in buses
        terminals = get(terminals_by_bus, bus, nothing)
        isnothing(terminals) && throw(ArgumentError(
            "BMOPFTools grounding analysis references undeclared bus '$bus'",
        ))
        append!(variables, _bmopf_terminal_variables(context, bus, terminals, component))
    end
    return variables
end

"""
    bmopf_floating_neutral_candidate_modes(context) -> Vector{ExpectedNullspaceMode}

Construct candidate real and imaginary uniform-voltage-shift directions for
each BMOPFTools-declared explicit floating-neutral component. They are physical
expectations only: source constraints, fixed coordinates, and the compiled OPF
equations may reject them. Pass selected values explicitly as `expected_modes`
to `bmopf_analyze_opf` to compare them with a local numerical nullspace.
"""
function _bmopf_floating_neutral_candidate_modes(context)
    _bmopf_context_model(context)
    modes = NLPDiagnostics.ExpectedNullspaceMode{Float64}[]
    for (ordinal, buses) in enumerate(_bmopf_floating_neutral_components(context))
        for component in (:real, :imag)
            variables = _bmopf_floating_neutral_mode_variables(context, buses, component)
            isempty(variables) && continue
            name = Symbol("bmopf_floating_neutral_", ordinal, "_", component)
            push!(modes, NLPDiagnostics.ExpectedNullspaceMode(
                name, variables, ones(Float64, length(variables));
                description = "Candidate uniform $(component) rectangular voltage shift over " *
                              "BMOPFTools floating-neutral buses $(join(buses, ", "))",
            ))
        end
    end
    return modes
end

function _bmopf_resolved_expected_modes(
    context;
    include_floating_neutral_candidates::Bool,
    expected_modes::AbstractVector{<:NLPDiagnostics.ExpectedNullspaceMode},
)
    candidates = include_floating_neutral_candidates ?
                 _bmopf_floating_neutral_candidate_modes(context) :
                 NLPDiagnostics.ExpectedNullspaceMode[]
    return vcat(expected_modes, candidates), candidates
end

function _bmopf_candidate_metadata!(report, candidates, included::Bool)
    report.metadata[:bmopf_floating_neutral_candidate_modes_included] = string(included)
    report.metadata[:bmopf_floating_neutral_candidate_modes_applied] = string(length(candidates))
    return report
end

function _bmopf_append_candidate_provenance!(report, context, candidates, included::Bool)
    included || return _bmopf_candidate_metadata!(report, candidates, included)
    provenance = _bmopf_floating_neutral_candidate_report(context)
    append!(report.findings, provenance.findings)
    merge!(report.metadata, provenance.metadata)
    return _bmopf_candidate_metadata!(report, candidates, included)
end

"""Return the complete registered JuMP/MOI initialization point, if one exists."""
function _bmopf_initialization_point(context; kwargs...)
    owner = _bmopf_context_model(context)
    owner isa JuMP.Model || throw(ArgumentError("BMOPFTools.opf_model(context) did not return a JuMP.Model"))
    return NLPDiagnostics.initialization_point(JuMP.backend(owner); kwargs...)
end

"""
    bmopf_set_start_values!(context)

Explicitly invoke BMOPFTools' public `set_opf_start_values!` stage, then
return `nothing`. This mutates only the staged context's start values. It is
intentionally opt-in: generated starts are an engine initialization policy, not
model data observed by NLPDiagnostics. No solve is performed. The stage may
initialize only a subset of model coordinates; use
`bmopf_start_completion_point` only when an explicit fallback policy is wanted.
"""
function _bmopf_set_start_values!(
    context,
)
    owner = _bmopf_context_model(context)
    owner isa JuMP.Model || throw(ArgumentError("BMOPFTools.opf_model(context) did not return a JuMP.Model"))
    try
        BMOPFTools.set_opf_start_values!(context)
    catch error
        error isa MethodError && error.f === BMOPFTools.set_opf_start_values! || rethrow()
        throw(ArgumentError(
            "BMOPFTools.set_opf_start_values! is unavailable; load BMOPFTools' JuMP/IPOPT staged-build extension before requesting generated starts",
        ))
    end
    return nothing
end

"""
    bmopf_start_completion_point(context; missing_value,
        label = "bmopf-partial-starts-completed") -> EvaluationPoint

Create a complete point from exact BMOPF `VariablePrimalStart` values, replacing
each missing coordinate by caller-specified finite `missing_value`. The staged
model is not modified. This is an explicit *mixed* initialization policy, not
an observed complete initialization and not a physical feasibility claim. Run
`bmopf_analyze_initialization` alongside it to retain the original missing-start
evidence.
"""
function _bmopf_start_completion_point(
    context;
    missing_value::Real,
    label::AbstractString = "bmopf-partial-starts-completed",
)
    isfinite(missing_value) || throw(ArgumentError("missing_value must be finite"))
    owner = _bmopf_context_model(context)
    owner isa JuMP.Model || throw(ArgumentError("BMOPFTools.opf_model(context) did not return a JuMP.Model"))
    backend = JuMP.backend(owner)
    variables = MOI.get(backend, MOI.ListOfVariableIndices())
    values = Float64[]
    missing_variables = MOI.VariableIndex[]
    for variable in variables
        start = try
            MOI.get(backend, MOI.VariablePrimalStart(), variable)
        catch
            nothing
        end
        if start isa Real && isfinite(start)
            push!(values, Float64(start))
        else
            push!(values, Float64(missing_value))
            push!(missing_variables, variable)
        end
    end
    return NLPDiagnostics.EvaluationPoint(
        variables,
        values;
        label = label,
        provenance = NLPDiagnostics.EvaluationPointProvenance(
            NLPDiagnostics.CompletedInitializationPoint;
            source = "BMOPFTools partial-start completion",
            complete = true,
            metadata = Dict(
                "missing_value" => missing_value,
                "filled_coordinate_count" => length(missing_variables),
                "filled_variable_indices" => join(
                    (variable.value for variable in missing_variables),
                    ",",
                ),
            ),
        ),
    )
end

"""
    bmopf_result_voltage_point(context, result;
        result_units = :si, fallback_value = 0.0,
        label = "bmopf-result-voltage-partial")

Map unambiguous saved rectangular voltage and public current records to the
staged MOI model. SI values are converted using BMOPFTools' public per-bus
voltage/current bases; `:pu` and `:model` accept already-scaled
model-coordinate values directly. All other coordinates receive explicit
`fallback_value`. The returned coverage counts distinguish mapped registry
coordinates, unresolved saved records, and fallback coordinates. Thus this is
a labeled partial-result probe, never a claim that a saved result completely
represents every auxiliary model coordinate.
"""
function _bmopf_result_voltage_point(
    context,
    result::AbstractDict;
    result_units::Symbol = :si,
    field_units::AbstractDict = Dict{Symbol,Symbol}(),
    fallback_value::Real = 0.0,
    label::AbstractString = "bmopf-result-voltage-partial",
)
    field_policy = _bmopf_result_field_units(result_units, field_units)
    isfinite(fallback_value) || throw(ArgumentError("fallback_value must be finite"))
    owner = _bmopf_context_model(context)
    backend = JuMP.backend(owner)
    variables = MOI.get(backend, MOI.ListOfVariableIndices())
    values = fill(Float64(fallback_value), length(variables))
    positions = Dict(variable => position for (position, variable) in enumerate(variables))
    registered_variables = Set{MOI.VariableIndex}()
    for key in BMOPFTools.opf_object_keys(context; kind = :variable)
        object = try BMOPFTools.opf_object(context, key) catch; nothing end
        object isa JuMP.VariableRef || continue
        variable = JuMP.index(object)
        haskey(positions, variable) && push!(registered_variables, variable)
    end
    buses = get(result, "bus", Dict())
    mapped = 0
    mapped_variables = Set{MOI.VariableIndex}()
    mapped_by_family = Dict{Symbol,Int}()
    unresolved_by_family = Dict{Symbol,Int}()
    function assign!(key, value)
        value isa Real && isfinite(value) || return
        object = try BMOPFTools.opf_object(context, key) catch; nothing end
        if !(object isa JuMP.VariableRef)
            family = key.family
            unresolved_by_family[family] = get(unresolved_by_family, family, 0) + 1
            return
        end
        position = get(positions, JuMP.index(object), nothing)
        if isnothing(position)
            family = key.family
            unresolved_by_family[family] = get(unresolved_by_family, family, 0) + 1
            return
        end
        values[position] = Float64(value)
        mapped += 1
        push!(mapped_variables, JuMP.index(object))
        family = key.family
        mapped_by_family[family] = get(mapped_by_family, family, 0) + 1
    end
    assign_scaled!(key, value, base) =
        value isa Real && isfinite(value) && assign!(key, Float64(value) / base)
    for (bus, terminals) in buses
        terminals isa AbstractDict || continue
        base = field_policy[:bus_voltage] == :si ? _bmopf_voltage_base(context, string(bus)) : 1.0
        isnothing(base) && throw(ArgumentError("saved SI voltage for bus '$bus' cannot be mapped because no public voltage base is declared"))
        for (terminal, values_dict) in terminals
            values_dict isa AbstractDict || continue
            for (component, field) in ((:real, "vr"), (:imag, "vi"))
                value = get(values_dict, field, nothing)
                value isa Real && isfinite(value) || continue
                key = BMOPFTools.opf_bus_voltage_key(string(bus), string(terminal); component)
                assign!(key, Float64(value) / base)
            end
        end
    end
    network = BMOPFTools.opf_network(context)
    # Reconstruct explicitly registered monitored IBR voltage magnitudes from
    # the saved rectangular bus voltages. The public key records both reference
    # mode and controller ownership; neutral labels come from the staged engine,
    # never variable-name parsing.
    function saved_voltage(bus, terminal)
        terminals = get(buses, string(bus), nothing)
        terminals isa AbstractDict || return nothing
        entry = get(terminals, string(terminal), nothing)
        entry isa AbstractDict || return nothing
        vr = get(entry, "vr", nothing)
        vi = get(entry, "vi", nothing)
        vr isa Real && vi isa Real && isfinite(vr) && isfinite(vi) || return nothing
        base = field_policy[:bus_voltage] == :si ? _bmopf_voltage_base(context, string(bus)) : 1.0
        isnothing(base) && return nothing
        return ComplexF64(Float64(vr) / base, Float64(vi) / base)
    end
    neutral_labels = Set(string.(BMOPFTools.opf_neutral_labels(context)))
    for key in BMOPFTools.opf_object_keys(context; kind = :variable)
        key.family == :u_ibr || continue
        index = key.index
        index isa Tuple && length(index) == 4 || continue
        ibr_id, phase, reference_raw, _ = index
        phase isa Integer || continue
        inv = get(get(network, "ibr", Dict()), string(ibr_id), nothing)
        inv isa AbstractDict || continue
        bus = string(get(inv, "bus", ""))
        terminals = string.(get(inv, "terminal_map", String[]))
        isempty(terminals) && continue
        topology = string(get(inv, "topology", "FOUR_LEG"))
        phase_positions = [position for (position, terminal) in enumerate(terminals)
                           if !(terminal in neutral_labels)]
        phase <= length(phase_positions) || continue
        phase_terminal = terminals[phase_positions[phase]]
        reference = Symbol(reference_raw)
        voltage = if reference == :pg || reference == :single_pg
            saved_voltage(bus, phase_terminal)
        elseif reference == :pn
            neutral_positions = findall(terminal -> terminal in neutral_labels, terminals)
            length(neutral_positions) == 1 || continue
            phase_voltage = saved_voltage(bus, phase_terminal)
            neutral_voltage = saved_voltage(bus, terminals[only(neutral_positions)])
            isnothing(phase_voltage) || isnothing(neutral_voltage) ? nothing :
                phase_voltage - neutral_voltage
        elseif reference == :pp
            topology == "THREE_LEG" || topology == "FOUR_LEG" || continue
            length(phase_positions) >= 2 || continue
            next_terminal = terminals[phase_positions[mod1(phase + 1, length(phase_positions))]]
            phase_voltage = saved_voltage(bus, phase_terminal)
            next_voltage = saved_voltage(bus, next_terminal)
            isnothing(phase_voltage) || isnothing(next_voltage) ? nothing :
                phase_voltage - next_voltage
        elseif reference == :single_diff
            length(terminals) >= 2 || continue
            phase_voltage = saved_voltage(bus, phase_terminal)
            reference_voltage = saved_voltage(bus, terminals[2])
            isnothing(phase_voltage) || isnothing(reference_voltage) ? nothing :
                phase_voltage - reference_voltage
        else
            continue
        end
        isnothing(voltage) && continue
        assign!(key, abs(voltage))
    end
    # Saved currents are keyed by terminal labels while public model keys use
    # conductor positions. SI current values are converted through public bases
    # at the corresponding component terminal bus.
    for (line_id, line_result) in get(result, "line", Dict())
            line = get(get(network, "line", Dict()), string(line_id), nothing)
            line isa AbstractDict && line_result isa AbstractDict || continue
            for (result_map_field, key_map_field, bus_field, rfield, side) in (
                ("terminal_map_from", "terminal_map_from", "bus_from", "cr_fr", :from),
                # Result records use the from-side terminal label, whereas the
                # public :to key is indexed in the to-side conductor order.
                ("terminal_map_from", "terminal_map_to", "bus_to", "cr_to", :to),
            )
                result_terminals = string.(get(line, result_map_field, String[]))
                key_terminals = string.(get(line, key_map_field, String[]))
                base = field_policy[:line_current] == :si ? _bmopf_current_base(context, string(get(line, bus_field, ""))) : 1.0
                isnothing(base) && continue
                for (position, terminal) in enumerate(result_terminals)
                    position <= length(key_terminals) || continue
                    entry = get(line_result, terminal, nothing)
                    entry isa AbstractDict || continue
                    assign_scaled!(BMOPFTools.opf_line_current_key(string(line_id), position; side), get(entry, rfield, nothing), base)
                    assign_scaled!(BMOPFTools.opf_line_current_key(string(line_id), position; side, component = :imag), get(entry, replace(rfield, "cr" => "ci"), nothing), base)
                end
            end
    end
    for (section, real_family, imag_family, result_real, result_imag) in (
        ("load", :crd, :cid, "crd", "cid"),
        ("generator", :crg, :cig, "crg", "cig"),
        ("voltage_source", :cr_src, :ci_src, "cr", "ci"),
        ("ibr", :cri, :cii, "cri", "cii"),
    )
        for (id, component_result) in get(result, section, Dict())
            component = get(get(network, section, Dict()), string(id), nothing)
            component isa AbstractDict && component_result isa AbstractDict || continue
            terminals = string.(get(component, "terminal_map", String[]))
            family = real_family == :crd ? :load_current :
                     real_family == :crg ? :generator_current :
                     real_family == :cr_src ? :source_current : :ibr_current
            base = field_policy[family] == :si ? _bmopf_current_base(context, string(get(component, "bus", ""))) : 1.0
            isnothing(base) && continue
            for (position, terminal) in enumerate(terminals)
                entry = get(component_result, terminal, nothing)
                entry isa AbstractDict || continue
                key = if real_family == :crd
                    BMOPFTools.opf_load_current_key(string(id), position)
                elseif real_family == :crg
                    BMOPFTools.opf_generator_current_key(string(id), position)
                elseif real_family == :cr_src
                    BMOPFTools.opf_voltage_source_current_key(string(id), position)
                else
                    BMOPFTools.opf_ibr_current_key(string(id), position)
                end
                assign_scaled!(key, get(entry, result_real, nothing), base)
                assign_scaled!(BMOPFTools.OpfModelKey(key.kind, imag_family, key.index), get(entry, result_imag, nothing), base)
                if section == "ibr"
                    power_base = field_policy[:ibr_power] == :si ? _bmopf_power_base(context) : 1.0
                    isnothing(power_base) && continue
                    assign_scaled!(BMOPFTools.opf_ibr_power_key(string(id), position), get(entry, "pg", nothing), power_base)
                    assign_scaled!(BMOPFTools.opf_ibr_power_key(string(id), position; component = :reactive), get(entry, "qg", nothing), power_base)
                end
            end
        end
    end
    for (switch_id, switch_result) in get(result, "switch", Dict())
        switch = get(get(network, "switch", Dict()), string(switch_id), nothing)
        switch isa AbstractDict && switch_result isa AbstractDict || continue
        terminals = string.(get(switch, "terminal_map_from", String[]))
        base = field_policy[:switch_current] == :si ? _bmopf_current_base(context, string(get(switch, "bus_from", ""))) : 1.0
        isnothing(base) && continue
        for (position, terminal) in enumerate(terminals)
            entry = get(switch_result, terminal, nothing)
            entry isa AbstractDict || continue
            assign_scaled!(BMOPFTools.opf_switch_current_key(string(switch_id), position), get(entry, "cr", nothing), base)
            assign_scaled!(BMOPFTools.opf_switch_current_key(string(switch_id), position; component = :imag), get(entry, "ci", nothing), base)
        end
    end
    for (bus, terminals) in get(result, "ground", Dict())
        base = field_policy[:ground_current] == :si ? _bmopf_current_base(context, string(bus)) : 1.0
        isnothing(base) && continue
        terminals isa AbstractDict || continue
        for (terminal, entry) in terminals
            entry isa AbstractDict || continue
            assign_scaled!(BMOPFTools.opf_ground_current_key(string(bus), string(terminal)), get(entry, "cg_r", nothing), base)
            assign_scaled!(BMOPFTools.opf_ground_current_key(string(bus), string(terminal); component = :imag), get(entry, "cg_i", nothing), base)
        end
    end
    return (
        point = NLPDiagnostics.EvaluationPoint(
            variables,
            values;
            label = label,
            provenance = NLPDiagnostics.EvaluationPointProvenance(
                NLPDiagnostics.SolverResultPoint;
                source = "BMOPFTools saved result mapping",
                complete = mapped == length(variables),
                metadata = Dict(
                    "mapped_coordinate_count" => mapped,
                    "fallback_coordinate_count" => length(variables) - mapped,
                    "fallback_value" => fallback_value,
                ),
            ),
        ),
        mapped_coordinate_count = mapped,
        # Retained for source compatibility; this now counts voltage and public
        # current coordinates, so new callers should use mapped_coordinate_count.
        mapped_voltage_coordinate_count = mapped,
        fallback_coordinate_count = length(variables) - mapped,
        registered_coordinate_count = length(registered_variables),
        unregistered_model_coordinate_count = length(variables) - length(registered_variables),
        unmapped_registered_coordinate_count = length(setdiff(registered_variables, mapped_variables)),
        mapped_registered_coordinate_fraction = isempty(registered_variables) ?
                                               0.0 : length(mapped_variables) / length(registered_variables),
        result_units = result_units,
        field_units = Dict{Symbol,Symbol}(field_policy),
        mapped_coordinate_counts_by_family = Dict(string(key) => value for (key, value) in mapped_by_family),
        unresolved_saved_coordinate_counts_by_family = Dict(string(key) => value for (key, value) in unresolved_by_family),
    )
end

"""
    bmopf_result_mapping_report(mapping) -> DiagnosticReport

Describe the exact adapter coverage returned by `bmopf_result_voltage_point`.
This is representational evidence: a fallback coordinate is not evidence that
the saved solution is infeasible, only that the result file did not specify
that staged-model coordinate through the supported public mapping.
"""
function _bmopf_result_mapping_report(mapping)
    required = (
        :mapped_coordinate_count,
        :fallback_coordinate_count,
        :registered_coordinate_count,
        :unregistered_model_coordinate_count,
        :unmapped_registered_coordinate_count,
        :mapped_registered_coordinate_fraction,
        :result_units,
        :field_units,
        :mapped_coordinate_counts_by_family,
        :unresolved_saved_coordinate_counts_by_family,
    )
    all(property -> hasproperty(mapping, property), required) || throw(ArgumentError(
        "mapping must be the named result returned by bmopf_result_voltage_point",
    ))
    mapped = mapping.mapped_coordinate_count
    fallback = mapping.fallback_coordinate_count
    registered = mapping.registered_coordinate_count
    unregistered_model = mapping.unregistered_model_coordinate_count
    unmapped_registered = mapping.unmapped_registered_coordinate_count
    fraction = mapping.mapped_registered_coordinate_fraction
    mapped >= 0 && fallback >= 0 && registered >= 0 && unregistered_model >= 0 && unmapped_registered >= 0 || throw(ArgumentError(
        "mapping counts must be nonnegative",
    ))
    0.0 <= fraction <= 1.0 || throw(ArgumentError(
        "mapped_registered_coordinate_fraction must lie in [0, 1]",
    ))
    report = NLPDiagnostics.DiagnosticReport()
    report.metadata[:stage] = "bmopf_saved_result_mapping"
    report.metadata[:bmopf_saved_result_coordinate_count] = string(mapped + fallback)
    report.metadata[:bmopf_saved_result_mapped_coordinate_count] = string(mapped)
    report.metadata[:bmopf_saved_result_fallback_coordinate_count] = string(fallback)
    report.metadata[:bmopf_saved_result_registered_coordinate_count] = string(registered)
    report.metadata[:bmopf_saved_result_unregistered_model_coordinate_count] = string(unregistered_model)
    report.metadata[:bmopf_saved_result_unmapped_registered_coordinate_count] = string(unmapped_registered)
    report.metadata[:bmopf_saved_result_registered_coordinate_fraction] = string(fraction)
    report.metadata[:bmopf_saved_result_units] = string(mapping.result_units)
    report.metadata[:bmopf_saved_result_field_units] = _bmopf_result_field_units_string(mapping.field_units)
    report.metadata[:bmopf_saved_result_mapped_families] = join(sort!(collect(keys(mapping.mapped_coordinate_counts_by_family))), ",")
    report.metadata[:bmopf_saved_result_unresolved_families] = join(sort!(collect(keys(mapping.unresolved_saved_coordinate_counts_by_family))), ",")
    push!(report, NLPDiagnostics.Finding(:bmopf_saved_result_mapping_coverage;
        severity = fallback == 0 ? NLPDiagnostics.SeverityInfo : NLPDiagnostics.SeverityWarning,
        domain = NLPDiagnostics.RepresentationalIssue,
        basis = NLPDiagnostics.NumericalObservation,
        confidence = NLPDiagnostics.ConfidenceCertain,
        observation = "$mapped saved-result coordinate(s) mapped into the staged model; $fallback coordinate(s) use the explicit fallback.",
        why_it_matters = fallback == 0 ?
            "The adapter covered every staged coordinate at this boundary; this still does not establish feasibility or optimality of the saved values." :
            "Derivative and feasibility observations at this point combine saved values with a caller-selected fallback, so they are not an unqualified diagnosis of the saved solution.",
        evidence = [NLPDiagnostics.Evidence("BMOPF saved-result mapping"; details = [
            "mapped_coordinate_count" => mapped,
            "fallback_coordinate_count" => fallback,
            "registered_coordinate_count" => registered,
            "unregistered_model_coordinate_count" => unregistered_model,
            "unmapped_registered_coordinate_count" => unmapped_registered,
            "mapped_registered_coordinate_fraction" => fraction,
            "result_units" => mapping.result_units,
            "field_units" => _bmopf_result_field_units_string(mapping.field_units),
            "mapped_by_family" => join(("$key=$(value)" for (key, value) in sort!(collect(mapping.mapped_coordinate_counts_by_family))), ","),
        ])],
        suggested_actions = fallback == 0 ?
            ["Inspect feasibility, derivative, and solver-status evidence separately; mapping coverage alone is not a physical validation."] :
            ["Inspect the mapped and fallback family counts before treating numerical findings as properties of the saved solution.", "Extend the public result adapter only for fields with an unambiguous BMOPFTools semantic key and unit basis."],
    ))
    if unregistered_model > 0
        push!(report, NLPDiagnostics.Finding(:bmopf_saved_result_unregistered_model_coordinates;
            severity = NLPDiagnostics.SeverityWarning,
            domain = NLPDiagnostics.RepresentationalIssue,
            basis = NLPDiagnostics.StructuralProof,
            confidence = NLPDiagnostics.ConfidenceCertain,
            observation = "$unregistered_model staged-model coordinate(s) have no public BMOPFTools registry key.",
            why_it_matters = "A saved-result adapter cannot map these auxiliary coordinates by component semantics. Their fallback values are a formulation-boundary limitation, not evidence that the saved physical state is invalid.",
            evidence = [NLPDiagnostics.Evidence("BMOPFTools public registry coverage"; details = [
                "model_coordinate_count" => mapped + fallback,
                "registered_coordinate_count" => registered,
                "unregistered_model_coordinate_count" => unregistered_model,
            ])],
            suggested_actions = ["Inspect `bmopf_opf_registry_report(context)` to identify the unregistered variables before interpreting a saved-result numerical profile.", "Add public semantic registry keys in BMOPFTools where those coordinates represent stable model concepts."],
        ))
    end
    if unmapped_registered > 0
        push!(report, NLPDiagnostics.Finding(:bmopf_saved_result_unmapped_registered_coordinates;
            severity = NLPDiagnostics.SeverityWarning,
            domain = NLPDiagnostics.RepresentationalIssue,
            basis = NLPDiagnostics.NumericalObservation,
            confidence = NLPDiagnostics.ConfidenceCertain,
            observation = "$unmapped_registered registered staged-model coordinate(s) are absent from the supported saved-result mapping.",
            why_it_matters = "These semantic coordinates are known to the model but were not supplied by this result file or adapter slice, so fallback values affect the numerical probe.",
            evidence = [NLPDiagnostics.Evidence("BMOPF registered-coordinate mapping coverage"; details = [
                "registered_coordinate_count" => registered,
                "mapped_registered_coordinate_fraction" => fraction,
                "unmapped_registered_coordinate_count" => unmapped_registered,
            ])],
            suggested_actions = ["Inspect the result schema and mapped-family counts; extend the adapter only where units and public semantic keys are unambiguous."],
        ))
    end
    unresolved = mapping.unresolved_saved_coordinate_counts_by_family
    if !isempty(unresolved)
        push!(report, NLPDiagnostics.Finding(:bmopf_saved_result_unresolved_records;
            severity = NLPDiagnostics.SeverityWarning,
            domain = NLPDiagnostics.RepresentationalIssue,
            basis = NLPDiagnostics.NumericalObservation,
            confidence = NLPDiagnostics.ConfidenceCertain,
            observation = "Saved-result records for $(sum(values(unresolved))) coordinate(s) have no matching public staged-model coordinate.",
            why_it_matters = "The result and staged model may use different component coverage, terminal ordering, or formulation auxiliaries; silently discarding those records would hide a compatibility boundary.",
            evidence = [NLPDiagnostics.Evidence("Unresolved BMOPF saved-result records"; details = [
                "counts_by_family" => join(("$key=$(value)" for (key, value) in sort!(collect(unresolved))), ","),
            ])],
            suggested_actions = ["Compare the result-file component inventory and the staged model registry before using this result as a benchmark point."],
        ))
    end
    return report
end

const _BMOPF_MODEL_FAMILY_TO_RESULT_FAMILY = Dict{Symbol,String}(
    :vr => "bus_voltage", :vi => "bus_voltage",
    :cr_fr => "line_current", :ci_fr => "line_current",
    :cr_to => "line_current", :ci_to => "line_current",
    :crd => "load_current", :cid => "load_current",
    :crg => "generator_current", :cig => "generator_current",
    :cr_src => "source_current", :ci_src => "source_current",
    :cri => "ibr_current", :cii => "ibr_current",
    :p_ibr => "ibr_power", :q_ibr => "ibr_power",
    :u_ibr => "ibr_voltage_magnitude",
    :cr_sw => "switch_current", :ci_sw => "switch_current",
    :cr_gnd => "ground_current", :ci_gnd => "ground_current",
)

function _bmopf_variable_result_descriptors(context)
    result = Dict{MOI.VariableIndex,Dict{String,String}}()
    for key in BMOPFTools.opf_object_keys(context; kind = :variable)
        family = get(_BMOPF_MODEL_FAMILY_TO_RESULT_FAMILY, key.family,
                     "unclassified_$(key.family)")
        object = try
            BMOPFTools.opf_object(context, key)
        catch
            nothing
        end
        object isa JuMP.VariableRef || continue
        index_text = sprint(show, key.index)
        device = key.index isa Tuple && !isempty(key.index) ? string(first(key.index)) : index_text
        result[JuMP.index(object)] = Dict(
            "result_family" => family,
            "model_key_family" => string(key.family),
            "index" => index_text,
            "device" => device,
        )
    end
    return result
end

function _bmopf_row_field_support(evaluation, row, variable_descriptors)
    families = Dict{String,Int}()
    instances = Dict{String,Int}()
    devices = Dict{String,Int}()
    columns = Int[]
    entries = 0
    for entry in evaluation.jacobian_entries
        entry.row == row || continue
        isfinite(entry.value) || continue
        iszero(entry.value) && continue
        entries += 1
        push!(columns, entry.column)
    end
    for column in unique(columns)
        1 <= column <= length(evaluation.point.variables) || continue
        variable = evaluation.point.variables[column]
        descriptor = get(variable_descriptors, variable, Dict(
            "result_family" => "unclassified_model_variable",
            "model_key_family" => "unclassified",
            "index" => "?",
            "device" => "?",
        ))
        family = descriptor["result_family"]
        families[family] = get(families, family, 0) + 1
        instance = string(family, "/", descriptor["model_key_family"], "/", descriptor["index"])
        instances[instance] = get(instances, instance, 0) + 1
        device = string(family, "/", descriptor["device"])
        devices[device] = get(devices, device, 0) + 1
    end
    return families, instances, devices, entries
end

function _bmopf_constraint_type_strings(
    ::MOI.ConstraintIndex{F,S},
) where {F,S}
    return string(F), string(S)
end

function _bmopf_constraint_source_key(source; subindex = source.subindex)
    isnothing(source.function_type) && return nothing
    isnothing(source.set_type) && return nothing
    return (
        source.index,
        String(source.function_type),
        String(source.set_type),
        isnothing(subindex) ? nothing : Int(subindex),
    )
end

_bmopf_constraint_source_name(source) =
    isnothing(source.name) ? "" : String(source.name)

function _bmopf_constraint_result_descriptors(context)
    result = Dict{
        Tuple{Int,String,String,Union{Nothing,Int}},
        Dict{String,String},
    }()
    for key in BMOPFTools.opf_object_keys(context; kind = :constraint)
        object = try
            BMOPFTools.opf_object(context, key)
        catch
            nothing
        end
        object isa JuMP.ConstraintRef || continue
        index = JuMP.index(object)
        index isa MOI.ConstraintIndex || continue
        function_type, set_type = _bmopf_constraint_type_strings(index)
        index_text = isnothing(key.index) ? "?" : sprint(show, key.index)
        result[(index.value, function_type, set_type, nothing)] = Dict{String,String}(
            "constraint_family" => string(key.family),
            "constraint_index" => index_text,
            "constraint_name" => JuMP.name(object),
            "constraint_function_type" => function_type,
            "constraint_set_type" => set_type,
            "registered" => "true",
        )
    end
    return result
end

function _bmopf_row_constraint_support(activity, constraint_descriptors)
    source = activity.source
    key = _bmopf_constraint_source_key(source)
    descriptor = isnothing(key) ? nothing : get(constraint_descriptors, key, nothing)
    if isnothing(descriptor)
        parent_key = _bmopf_constraint_source_key(source; subindex = nothing)
        descriptor = isnothing(parent_key) ? nothing :
            get(constraint_descriptors, parent_key, nothing)
    end
    isnothing(descriptor) && return Dict{String,String}(
        "constraint_family" => "unregistered_constraint",
        "constraint_index" => "?",
        "constraint_name" => _bmopf_constraint_source_name(source),
        "registered" => "false",
    )
    return descriptor
end

"""Return a compact semantic map for every evaluated scalar constraint row."""
function _bmopf_constraint_semantic_row_map(context, evaluation)
    descriptors = _bmopf_constraint_result_descriptors(context)
    rows = Dict{String,Any}()
    for (row, source) in enumerate(evaluation.constraint_sources)
        key = _bmopf_constraint_source_key(source)
        descriptor = isnothing(key) ? nothing : get(descriptors, key, nothing)
        if isnothing(descriptor)
            parent_key = _bmopf_constraint_source_key(source; subindex = nothing)
            descriptor = isnothing(parent_key) ? nothing :
                get(descriptors, parent_key, nothing)
        end
        if isnothing(descriptor)
            rows[string(row)] = Dict{String,Any}(
                "constraint_family" => "unregistered_constraint",
                "constraint_index" => "?",
                "constraint_name" => _bmopf_constraint_source_name(source),
                "constraint_function_type" => source.function_type,
                "constraint_set_type" => source.set_type,
                "registered" => false,
            )
        else
            rows[string(row)] = Dict{String,Any}(
                "constraint_family" => descriptor["constraint_family"],
                "constraint_index" => descriptor["constraint_index"],
                "constraint_name" => descriptor["constraint_name"],
                "constraint_function_type" => descriptor["constraint_function_type"],
                "constraint_set_type" => descriptor["constraint_set_type"],
                "registered" => true,
            )
        end
    end
    return rows
end

const _BMOPF_CONSTRAINT_COMPONENT_FAMILY_PREFIXES = (
    "kcl_" => "network_balance",
    "line_" => "line",
    "load_" => "load",
    "source_" => "source",
    "ground_" => "ground",
    "ibr_" => "ibr",
    "switch_" => "switch",
    "transformer_" => "transformer",
    "n_winding_" => "transformer",
    "dc_" => "dc_network",
    "variable_" => "variable_bound",
)

function _bmopf_constraint_component_family(family::AbstractString)
    family == "unregistered_constraint" && return "unregistered"
    for (prefix, component_family) in _BMOPF_CONSTRAINT_COMPONENT_FAMILY_PREFIXES
        startswith(family, prefix) && return component_family
    end
    return "unclassified"
end

"""Attribute Jacobian row-scale evidence through public BMOPFTools row keys."""
function _bmopf_jacobian_row_family_scale_attribution(context, evaluation)
    labels = _bmopf_constraint_semantic_row_map(context, evaluation)
    attribution = NLPDiagnostics.jacobian_row_family_scale_attribution(
        evaluation, labels,
    )
    attribution["label_source"] = "BMOPFTools public constraint registry"
    attribution["component_family_source"] =
        "explicit NLPDiagnostics mapping from BMOPFTools constraint families"
    component_families = Dict{String,Vector{String}}()
    for (family, data) in attribution["families"]
        component_family = _bmopf_constraint_component_family(family)
        data["component_family"] = component_family
        push!(get!(component_families, component_family, String[]), family)
    end
    attribution["component_families"] = Dict(
        component => sort!(families) for
        (component, families) in sort!(collect(component_families); by = first)
    )
    attribution["unclassified_family_count"] = count(
        data -> get(data, "component_family", "unclassified") == "unclassified",
        values(attribution["families"]),
    )
    return attribution
end

"""Run a controlled Jacobian row-family scaling experiment with BMOPF keys."""
function _bmopf_jacobian_row_family_scaling_experiment(
    context, evaluation; kwargs...
)
    labels = _bmopf_constraint_semantic_row_map(context, evaluation)
    result = NLPDiagnostics.jacobian_row_family_scaling_experiment(
        evaluation, labels; kwargs...,
    )
    result["label_source"] = "BMOPFTools public constraint registry"
    return result
end

function _bmopf_constraint_registry_coverage_report(context, evaluation)
    rows = _bmopf_constraint_semantic_row_map(context, evaluation)
    registered = Dict{String,Int}()
    unregistered_names = Dict{String,Int}()
    unregistered_rows = Int[]
    for (row_text, descriptor) in rows
        if get(descriptor, "registered", false) == true
            family = string(get(descriptor, "constraint_family", "unknown"))
            registered[family] = get(registered, family, 0) + 1
        else
            row = tryparse(Int, row_text)
            row === nothing || push!(unregistered_rows, row)
            name = string(get(descriptor, "constraint_name", ""))
            isempty(name) ||
                (unregistered_names[name] = get(unregistered_names, name, 0) + 1)
        end
    end
    sort!(unregistered_rows)
    total = length(rows)
    registered_count = sum(values(registered); init=0)
    unregistered_count = total - registered_count
    report = NLPDiagnostics.DiagnosticReport()
    report.metadata[:stage] = "bmopf_constraint_registry_coverage"
    report.metadata[:bmopf_constraint_registry_row_count] = string(total)
    report.metadata[:bmopf_constraint_registry_registered_row_count] =
        string(registered_count)
    report.metadata[:bmopf_constraint_registry_unregistered_row_count] =
        string(unregistered_count)
    report.metadata[:bmopf_constraint_registry_registered_family_row_counts] =
        _bmopf_family_count_string(registered)
    report.metadata[:bmopf_constraint_registry_unregistered_rows] =
        join(unregistered_rows, ",")
    report.metadata[:bmopf_constraint_registry_unregistered_name_counts] =
        _bmopf_family_count_string(unregistered_names)
    push!(report, NLPDiagnostics.Finding(:bmopf_constraint_registry_coverage;
        severity = unregistered_count == 0 ?
            NLPDiagnostics.SeverityInfo : NLPDiagnostics.SeverityWarning,
        domain = NLPDiagnostics.RepresentationalIssue,
        basis = NLPDiagnostics.StructuralProof,
        confidence = NLPDiagnostics.ConfidenceCertain,
        observation = unregistered_count == 0 ?
            "All $total evaluated scalar constraint row(s) have public BMOPFTools semantic keys." :
            "$unregistered_count of $total evaluated scalar constraint row(s) have no public BMOPFTools semantic key.",
        why_it_matters = unregistered_count == 0 ?
            "Numerical row evidence can be attributed without guessing from JuMP names; this proves coverage only for this exact built formulation." :
            "Unregistered rows cannot receive a physical family or component interpretation without guessing. They may be native omissions or caller-added constraints, and this report does not infer which.",
        evidence = [NLPDiagnostics.Evidence("BMOPFTools constraint registry"; details = [
            "row_count" => total,
            "registered_row_count" => registered_count,
            "unregistered_row_count" => unregistered_count,
            "registered_family_row_counts" => _bmopf_family_count_string(registered),
            "unregistered_rows" => join(unregistered_rows, ","),
            "unregistered_name_counts" => _bmopf_family_count_string(unregistered_names),
        ])],
        suggested_actions = unregistered_count == 0 ?
            ["Retain this coverage gate for every distinct formulation fixture; do not generalize it to untested builders."] :
            ["If a row belongs to BMOPFTools, register it at construction time with a stable family and component index.", "If a caller or plugin added the row, register it explicitly through BMOPFTools.register_opf_constraint!; use the JuMP name only as provenance."],
    ))
    return report
end

"""Run the generic local Jacobian row-family perturbation with BMOPF labels."""
function _bmopf_analyze_jacobian_row_family_perturbations(
    context, evaluation; kwargs...
)
    labels = _bmopf_constraint_semantic_row_map(context, evaluation)
    report = NLPDiagnostics.analyze_jacobian_row_family_perturbations(
        evaluation, labels; kwargs...
    )
    report.metadata[:bmopf_row_family_label_source] =
        "BMOPFTools public constraint registry"
    report.metadata[:bmopf_semantic_row_count] = string(length(labels))
    report.metadata[:bmopf_semantic_registered_row_count] = string(count(
        descriptor -> descriptor isa AbstractDict &&
            get(descriptor, "registered", false) == true,
        values(labels),
    ))
    return report
end

const _BMOPF_RESULT_FAMILY_COMPONENT_KIND = Dict{String,String}(
    "bus_voltage" => "bus",
    "line_current" => "line",
    "load_current" => "load",
    "source_current" => "voltage_source",
    "ibr_current" => "ibr",
    "ibr_power" => "ibr",
    "ibr_voltage_magnitude" => "ibr",
    "switch_current" => "switch",
    "ground_current" => "ground",
)

function _bmopf_component_support(devices)
    components = Dict{String,Int}()
    for (device, count) in devices
        parts = split(device, "/"; limit = 2)
        length(parts) == 2 || continue
        family, identifier = parts
        kind = get(_BMOPF_RESULT_FAMILY_COMPONENT_KIND, family, "unknown")
        component = string(kind, "/", identifier)
        components[component] = get(components, component, 0) + count
    end
    return components
end

function _bmopf_family_count_string(counts)
    return join(("$(key)=$(value)" for (key, value) in
                 sort!(collect(counts); by = first)), ",")
end

"""
    _bmopf_constraint_feasibility_field_attribution(context, result; mapping=nothing)

Attribute scalar feasibility violations to the registered BMOPF variable
families appearing in each violating row's evaluated Jacobian support. This is
structural support evidence: it identifies which mapped coordinate families
participate in a violated row, but does not prove that a particular exported
field caused the violation.
"""
function _bmopf_constraint_feasibility_field_attribution(
    context,
    result;
    mapping = nothing,
    feasibility_tolerance::Real = sqrt(eps(Float64)),
    active_tolerance::Real = sqrt(eps(Float64)),
)
    profile = hasproperty(result, :profile) ? result.profile : result
    hasproperty(profile, :evaluation) || throw(ArgumentError(
        "result must contain a NumericalEvaluation or BMOPFProfileResult",
    ))
    evaluation = profile.evaluation
    owner = _bmopf_context_model(context)
    backend = JuMP.backend(owner)
    summary = NLPDiagnostics.constraint_feasibility_summary(
        backend, evaluation;
        feasibility_tolerance, active_tolerance,
    )
    report = NLPDiagnostics.DiagnosticReport()
    report.metadata[:stage] = "bmopf_constraint_feasibility_field_attribution"
    report.metadata[:bmopf_result_field_catalog_version] = "bmopf-result-field-catalog-v1"
    report.metadata[:bmopf_feasibility_attribution_complete] = string(summary.complete)
    variable_descriptors = _bmopf_variable_result_descriptors(context)
    constraint_descriptors = _bmopf_constraint_result_descriptors(context)
    violations = filter(activity -> activity.classification == :violated,
                        summary.activities)
    family_rows = Dict{String,Int}()
    family_coordinates = Dict{String,Int}()
    field_instances = Dict{String,Int}()
    device_instances = Dict{String,Int}()
    derivative_methods = Dict{String,Int}()
    constraint_family_rows = Dict{String,Int}()
    constraint_instances = Dict{String,Int}()
    model_constraint_family_rows = Dict{String,Int}()
    model_registered_rows = 0
    model_unregistered_rows = 0
    component_candidates = Dict{String,Int}()
    row_records = Any[]
    unsupported_rows = 0
    registered_rows = 0
    # Count semantic coverage over every scalar row represented by the
    # evaluated model, not only rows that happen to be violated.  This keeps
    # the registry boundary visible even when a saved point is feasible.
    for activity in summary.activities
        constraint_support = _bmopf_row_constraint_support(
            activity, constraint_descriptors,
        )
        family = constraint_support["constraint_family"]
        model_constraint_family_rows[family] =
            get(model_constraint_family_rows, family, 0) + 1
        if constraint_support["registered"] == "true"
            model_registered_rows += 1
        else
            model_unregistered_rows += 1
        end
    end
    for activity in violations
        method = activity.row <= length(evaluation.jacobian_row_methods) ?
                 string(evaluation.jacobian_row_methods[activity.row]) : "unavailable"
        derivative_methods[method] = get(derivative_methods, method, 0) + 1
        support, instances, devices, entry_count = _bmopf_row_field_support(
            evaluation, activity.row, variable_descriptors,
        )
        isempty(support) && (unsupported_rows += 1)
        for (family, count) in support
            family_rows[family] = get(family_rows, family, 0) + 1
            family_coordinates[family] = get(family_coordinates, family, 0) + count
        end
        for (instance, count) in instances
            field_instances[instance] = get(field_instances, instance, 0) + 1
        end
        for (device, count) in devices
            device_instances[device] = get(device_instances, device, 0) + 1
        end
        constraint_support = _bmopf_row_constraint_support(
            activity, constraint_descriptors,
        )
        constraint_family = constraint_support["constraint_family"]
        constraint_family_rows[constraint_family] =
            get(constraint_family_rows, constraint_family, 0) + 1
        constraint_instance = string(
            constraint_family, "/", constraint_support["constraint_index"],
        )
        constraint_instances[constraint_instance] =
            get(constraint_instances, constraint_instance, 0) + 1
        constraint_support["registered"] == "true" && (registered_rows += 1)
        components = _bmopf_component_support(devices)
        for (component, count) in components
            component_candidates[component] =
                get(component_candidates, component, 0) + count
        end
        push!(row_records, Dict{String,Any}(
            "row" => activity.row,
            "source" => NLPDiagnostics.entity_data(activity.source),
            "value" => activity.value,
            "lower" => activity.lower,
            "upper" => activity.upper,
            "feasibility_violation" => activity.feasibility_violation,
            "jacobian_support_entry_count" => entry_count,
            "field_family_support" => support,
            "field_instances" => sort!(collect(keys(instances))),
            "device_instances" => sort!(collect(keys(devices))),
            "component_candidates" => sort!(collect(keys(components))),
            "constraint_support" => constraint_support,
        ))
    end
    report.metadata[:bmopf_feasibility_attribution_violation_count] = string(length(violations))
    report.metadata[:bmopf_feasibility_attribution_unsupported_row_count] = string(unsupported_rows)
    report.metadata[:bmopf_feasibility_attribution_family_row_counts] =
        _bmopf_family_count_string(family_rows)
    report.metadata[:bmopf_feasibility_attribution_family_coordinate_counts] =
        _bmopf_family_count_string(family_coordinates)
    report.metadata[:bmopf_feasibility_attribution_jacobian_method_counts] =
        _bmopf_family_count_string(derivative_methods)
    report.metadata[:bmopf_feasibility_attribution_field_instance_counts] =
        _bmopf_family_count_string(field_instances)
    report.metadata[:bmopf_feasibility_attribution_device_counts] =
        _bmopf_family_count_string(device_instances)
    report.metadata[:bmopf_feasibility_attribution_constraint_family_row_counts] =
        _bmopf_family_count_string(constraint_family_rows)
    report.metadata[:bmopf_feasibility_attribution_constraint_instance_counts] =
        _bmopf_family_count_string(constraint_instances)
    report.metadata[:bmopf_feasibility_attribution_component_candidate_counts] =
        _bmopf_family_count_string(component_candidates)
    report.metadata[:bmopf_feasibility_attribution_registered_constraint_row_count] =
        string(registered_rows)
    report.metadata[:bmopf_feasibility_attribution_unregistered_constraint_row_count] =
        string(length(violations) - registered_rows)
    report.metadata[:bmopf_feasibility_attribution_model_constraint_row_count] =
        string(length(summary.activities))
    report.metadata[:bmopf_feasibility_attribution_model_registered_constraint_row_count] =
        string(model_registered_rows)
    report.metadata[:bmopf_feasibility_attribution_model_unregistered_constraint_row_count] =
        string(model_unregistered_rows)
    report.metadata[:bmopf_feasibility_attribution_model_constraint_family_row_counts] =
        _bmopf_family_count_string(model_constraint_family_rows)
    power_base = _bmopf_power_base(context)
    report.metadata[:bmopf_feasibility_attribution_power_base] =
        isnothing(power_base) ? "unavailable" : string(power_base)
    if mapping !== nothing && hasproperty(mapping, :mapped_coordinate_counts_by_family)
        report.metadata[:bmopf_feasibility_attribution_mapped_coordinate_counts] =
            _bmopf_family_count_string(mapping.mapped_coordinate_counts_by_family)
    end
    isempty(violations) && return report
    push!(report, NLPDiagnostics.Finding(:bmopf_constraint_feasibility_field_attribution;
        severity = NLPDiagnostics.SeverityInfo,
        domain = NLPDiagnostics.MathematicalIssue,
        basis = NLPDiagnostics.NumericalObservation,
        confidence = NLPDiagnostics.ConfidenceCertain,
        observation = "$(length(violations)) violated scalar row(s) were attributed to registered BMOPF variable families through evaluated Jacobian support.",
        why_it_matters = "The attribution narrows which coordinate families participate in the infeasible rows while preserving the distinction between support evidence and causal unit diagnosis.",
        evidence = [NLPDiagnostics.Evidence("BMOPF feasibility-field attribution"; details = [
            "violating_row_count" => length(violations),
            "unsupported_row_count" => unsupported_rows,
            "family_row_counts" => _bmopf_family_count_string(family_rows),
            "family_coordinate_counts" => _bmopf_family_count_string(family_coordinates),
            "jacobian_method_counts" => _bmopf_family_count_string(derivative_methods),
            "field_instance_counts" => _bmopf_family_count_string(field_instances),
            "device_counts" => _bmopf_family_count_string(device_instances),
            "constraint_family_row_counts" => _bmopf_family_count_string(constraint_family_rows),
            "constraint_instance_counts" => _bmopf_family_count_string(constraint_instances),
            "component_candidate_counts" => _bmopf_family_count_string(component_candidates),
            "registered_constraint_row_count" => registered_rows,
            "unregistered_constraint_row_count" => length(violations) - registered_rows,
            "model_constraint_row_count" => length(summary.activities),
            "model_registered_constraint_row_count" => model_registered_rows,
            "model_unregistered_constraint_row_count" => model_unregistered_rows,
            "model_constraint_family_row_counts" => _bmopf_family_count_string(model_constraint_family_rows),
            "power_base" => power_base,
            "catalog_version" => "bmopf-result-field-catalog-v1",
            "row_records" => sprint(show, row_records),
        ])],
        affected = NLPDiagnostics.EntityRef[activity.source for activity in violations],
        suggested_actions = [
            "Compare the implicated field families against the explicit result-field unit policy and public BMOPFTools bases.",
            "Treat this as support attribution, not proof that one field family caused the violation.",
        ],
    ))
    return report
end

"""Fingerprint the coordinate magnitude implied by a saved-result unit choice."""
function _bmopf_result_unit_report(context, result::AbstractDict;
                                   result_units::Symbol,
                                   field_units::AbstractDict = Dict{Symbol,Symbol}())
    field_policy = _bmopf_result_field_units(result_units, field_units)
    report = NLPDiagnostics.DiagnosticReport()
    report.metadata[:bmopf_saved_result_unit_report_stage] = "bmopf_saved_result_units"
    report.metadata[:bmopf_saved_result_units] = string(result_units)
    report.metadata[:bmopf_saved_result_field_units] = _bmopf_result_field_units_string(field_policy)
    bases = BMOPFTools.opf_bases(context)
    isnothing(bases) && return report
    # A grounded-neutral coordinate is commonly exactly zero.  It carries no
    # information about the SI-to-model scale and must not dominate a median
    # fingerprint for an otherwise well-scaled result.
    ratios = Float64[]
    zero_magnitude_count = 0
    for (bus, terminals) in get(result, "bus", Dict())
        terminals isa AbstractDict || continue
        base = _bmopf_voltage_base(context, string(bus))
        isnothing(base) && continue
        for entry in values(terminals)
            entry isa AbstractDict || continue
            vr = get(entry, "vr", nothing)
            vi = get(entry, "vi", nothing)
            vr isa Real && vi isa Real && isfinite(vr) && isfinite(vi) || continue
            magnitude = hypot(Float64(vr), Float64(vi))
            if iszero(magnitude)
                zero_magnitude_count += 1
            else
                push!(ratios, field_policy[:bus_voltage] == :si ? magnitude / base : magnitude)
            end
        end
    end
    report.metadata[:bmopf_saved_result_unit_fingerprint_count] = string(length(ratios))
    report.metadata[:bmopf_saved_result_unit_fingerprint_zero_magnitude_count] =
        string(zero_magnitude_count)
    isempty(ratios) && return report
    sort!(ratios)
    median_ratio = ratios[cld(length(ratios), 2)]
    report.metadata[:bmopf_saved_result_unit_fingerprint_median_coordinate_magnitude] = string(median_ratio)
    if median_ratio < 0.05 || median_ratio > 20.0
        push!(report, NLPDiagnostics.Finding(:bmopf_saved_result_unit_scale_suspicious;
            severity = NLPDiagnostics.SeverityWarning,
            domain = NLPDiagnostics.NumericalIssue,
            basis = NLPDiagnostics.HeuristicInterpretation,
            confidence = NLPDiagnostics.ConfidenceMedium,
            observation = "Saved-result unit choice '$result_units' yields median rectangular-voltage coordinate magnitude $median_ratio.",
            why_it_matters = "Per-unit staged coordinates are usually order one. An extreme converted magnitude can indicate that SI values were treated as model coordinates (or vice versa), which distorts derivative and tolerance interpretation.",
            evidence = [NLPDiagnostics.Evidence("Saved-result voltage unit fingerprint"; details = [
                "result_units" => result_units,
                "bus_voltage_units" => field_policy[:bus_voltage],
                "field_units" => _bmopf_result_field_units_string(field_policy),
                "sample_count" => length(ratios),
                "median_coordinate_magnitude" => median_ratio,
                "heuristic_expected_band" => "[0.05, 20]",
            ])],
            suggested_actions = ["Confirm the numerical convention of each result field against BMOPFTools public bases.", "Use field_units to declare mixed exports explicitly; reserve :model for already-scaled staged coordinates."],
        ))
    end
    return report
end

"""
    bmopf_saved_result_profile_case(name, context, result; kwargs...)

Build one solver-independent `ProfileCase` from a saved BMOPF result and return
`(case, mapping, mapping_report)`. The case's point is complete only to the
extent recorded by `mapping_report`; this constructor deliberately preserves
that qualification instead of presenting a saved JSON result as an unqualified
physical state.
"""
function _bmopf_saved_result_profile_case(
    name::AbstractString,
    context,
    result::AbstractDict;
    result_units::Symbol = :si,
    field_units::AbstractDict = Dict{Symbol,Symbol}(),
    fallback_value::Real = 0.0,
    label::AbstractString = "bmopf-saved-result-partial-probe",
    description::AbstractString = "Saved BMOPF result diagnostic profile",
    task::Union{Nothing,AbstractString} = "BMOPF saved-result diagnostic benchmark",
    formulation::AbstractString = "BMOPF IVR",
    scale::AbstractString = "as declared by BMOPF snapshot",
    tags::AbstractVector{Symbol} = Symbol[:bmopf, :saved_result, :multiconductor],
    metadata::AbstractDict = Dict{String,String}(),
)
    mapping = _bmopf_result_voltage_point(context, result;
        result_units, field_units, fallback_value, label,
    )
    mapping_report = _bmopf_result_mapping_report(mapping)
    _bmopf_append_report!(mapping_report,
                          _bmopf_result_unit_report(context, result; result_units, field_units))
    case_metadata = Dict{String,Any}(
        "point_policy" => "saved_result",
        "point_provenance" => "saved BMOPF result with explicit fallback for unmapped coordinates",
        "saved_result_units" => string(result_units),
        "saved_result_field_units" => _bmopf_result_field_units_string(mapping.field_units),
        "mapped_coordinate_count" => mapping.mapped_coordinate_count,
        "fallback_coordinate_count" => mapping.fallback_coordinate_count,
        "registered_coordinate_count" => mapping.registered_coordinate_count,
        "unregistered_model_coordinate_count" => mapping.unregistered_model_coordinate_count,
        "unmapped_registered_coordinate_count" => mapping.unmapped_registered_coordinate_count,
        "mapped_registered_coordinate_fraction" => mapping.mapped_registered_coordinate_fraction,
        "mapped_coordinate_counts_by_family" => mapping.mapped_coordinate_counts_by_family,
        "unresolved_saved_coordinate_counts_by_family" => mapping.unresolved_saved_coordinate_counts_by_family,
    )
    merge!(case_metadata, Dict(string(key) => value for (key, value) in metadata))
    case = NLPDiagnostics.ProfileCase(name, mapping.point;
        description, task, formulation, initialization = "saved_result", scale,
        tags, metadata = case_metadata,
    )
    return (case = case, mapping = mapping, mapping_report = mapping_report)
end

"""
    bmopf_profile_saved_result(context, name, result; profile_kwargs = NamedTuple(), ...)

Profile a saved result against an already-built staged context. Mapping coverage
findings are appended to the ordinary BMOPF context report, so callers receive
one profile object with both numerical observations and the point-provenance
qualification. This function neither solves nor modifies the model.
"""
function _bmopf_profile_saved_result(
    context,
    name::AbstractString,
    result::AbstractDict;
    profile_kwargs::NamedTuple = NamedTuple(),
    case_kwargs::NamedTuple = NamedTuple(),
)
    saved = _bmopf_saved_result_profile_case(name, context, result; case_kwargs...)
    profile = _bmopf_profile_case(context, saved.case; profile_kwargs...)
    _bmopf_append_report!(profile.context_report, saved.mapping_report)
    profile.context_report.metadata[:bmopf_saved_result_profile] = "true"
    sort!(profile.context_report.findings;
          by = finding -> (-Int(finding.severity), string(finding.code)))
    return (profile = profile, case = saved.case, mapping = saved.mapping,
            mapping_report = saved.mapping_report)
end

"""
    bmopf_coordinate_probe_point(context; value = 0.0, label = "bmopf-zero-coordinate-probe")

Construct an explicitly synthetic constant-coordinate `EvaluationPoint` in
the staged model's public MOI order. This is not an initialization, does not
set starts, and has no physical-voltage interpretation. It exists only for
benchmarking static and numerical failure behavior when a model lacks complete
caller-provided starts.
"""
function _bmopf_coordinate_probe_point(
    context;
    value::Real = 0.0,
    label::AbstractString = "bmopf-zero-coordinate-probe",
)
    isfinite(value) || throw(ArgumentError("coordinate probe value must be finite"))
    owner = _bmopf_context_model(context)
    owner isa JuMP.Model || throw(ArgumentError("BMOPFTools.opf_model(context) did not return a JuMP.Model"))
    variables = MOI.get(JuMP.backend(owner), MOI.ListOfVariableIndices())
    return NLPDiagnostics.EvaluationPoint(variables, fill(Float64(value), length(variables));
        label = label,
        provenance = NLPDiagnostics.EvaluationPointProvenance(
            NLPDiagnostics.SyntheticSmokePoint;
            source = "BMOPFTools constant-coordinate probe",
            complete = true,
            metadata = Dict("constant_value" => value),
        ),
    )
end

"""
    bmopf_analyze_initialization(context; ...)

Run generic initialization diagnostics on a staged BMOPF model without filling
or changing missing starts. When all model variables have starts, append direct
BMOPF terminal-coordinate scale checks at that exact point.
"""
function _bmopf_analyze_initialization(
    context;
    include_floating_neutral_candidates::Bool = false,
    expected_modes::AbstractVector{<:NLPDiagnostics.ExpectedNullspaceMode} =
        NLPDiagnostics.ExpectedNullspaceMode[],
    kwargs...,
)
    owner = _bmopf_context_model(context)
    owner isa JuMP.Model || throw(ArgumentError("BMOPFTools.opf_model(context) did not return a JuMP.Model"))
    backend = JuMP.backend(owner)
    modes, candidates = _bmopf_resolved_expected_modes(context;
        include_floating_neutral_candidates, expected_modes,
    )
    report = NLPDiagnostics.analyze_initialization(backend;
        expected_modes = isempty(modes) ? nothing : modes,
        components = _bmopf_component_metadata(context), kwargs...,
    )
    point = NLPDiagnostics.initialization_point(backend)
    if !isnothing(point)
        scale_report = _bmopf_terminal_port_coordinate_scale_report(context, point)
        append!(report.findings, scale_report.findings)
        merge!(report.metadata, scale_report.metadata)
        report.metadata[:bmopf_terminal_coordinate_scales_at_initialization] = "true"
    else
        report.metadata[:bmopf_terminal_coordinate_scales_at_initialization] = "false"
    end
    _bmopf_append_candidate_provenance!(report, context, candidates,
                                        include_floating_neutral_candidates)
    report.metadata[:bmopf_opf_context] = "BMOPFTools staged OPF context"
    report.metadata[:bmopf_opf_lifecycle] = string(BMOPFTools.opf_lifecycle(context))
    stages = get(report.metadata, :stages, "initialization") * ",bmopf_initialization"
    !isnothing(point) && (stages *= ",bmopf_terminal_coordinate_scales")
    report.metadata[:stages] = stages
    return report
end

const _BMOPF_SOURCE_SCHEMA_PHYSICAL_FIELDS = Set(
    ("angle", "basekv", "kv", "phases", "vmaxpu", "vminpu", "zipv"),
)

"""Classify a PowerIO-to-BMOPF source-schema warning for report consumers."""
function _bmopf_source_schema_warning_policy(field::AbstractString)
    normalized = lowercase(strip(field))
    if normalized == "units"
        return (impact = "representational", status = "intentionally_unsupported", blocking = false)
    elseif normalized == "model"
        return (impact = "device_semantics", status = "unsupported_device_semantics", blocking = true)
    elseif normalized in _BMOPF_SOURCE_SCHEMA_PHYSICAL_FIELDS
        return (impact = "physical_or_operating_point", status = "unsupported_physical_metadata", blocking = true)
    end
    return (impact = "unknown", status = "unclassified_drop", blocking = true)
end

function _bmopf_source_schema_count_string(values::AbstractVector{<:AbstractString})
    counts = Dict{String,Int}()
    for value in values
        counts[String(value)] = get(counts, String(value), 0) + 1
    end
    return join(("$(key)=$(counts[key])" for key in sort!(collect(keys(counts)))), ",")
end

function _bmopf_source_schema_field_vector(value)
    value isa AbstractVector || return String[]
    return sort!(unique(String[string(item) for item in value]))
end

function _bmopf_source_schema_provenance_fields(value)
    value isa AbstractDict || return String[]
    fields = _bmopf_source_schema_field_vector(get(value, "fields", get(value, :fields, Any[])))
    !isempty(fields) && return fields
    scopes = get(value, "by_scope", get(value, :by_scope, Dict()))
    scopes isa AbstractDict || return String[]
    all_fields = String[]
    for raw_fields in values(scopes)
        append!(all_fields, _bmopf_source_schema_field_vector(raw_fields))
    end
    return sort!(unique(all_fields))
end

"""Return structured fidelity findings for PowerIO fields dropped by the BMOPF schema."""
function _bmopf_source_schema_report(
    context;
    mapped_fields = nothing,
)
    network = BMOPFTools.opf_network(context)
    meta = get(network, "_meta", get(network, :_meta, Dict{Any,Any}()))
    meta isa AbstractDict || (meta = Dict{Any,Any}())
    raw_warnings = get(meta, "powerio_warnings", get(meta, :powerio_warnings, Any[]))
    raw_warnings = raw_warnings isa AbstractVector ? raw_warnings :
        (isnothing(raw_warnings) ? Any[] : Any[raw_warnings])
    warnings = String[string(item) for item in raw_warnings]
    source_path = string(get(meta, "powerio_source", get(meta, :powerio_source, "")))
    source_metadata = get(meta, "powerio_source_metadata",
                          get(meta, :powerio_source_metadata, Dict{Any,Any}()))
    provenance_fields = _bmopf_source_schema_provenance_fields(source_metadata)
    source_mapping = get(meta, "powerio_source_mapping",
                         get(meta, :powerio_source_mapping, Dict{Any,Any}()))
    source_mapping = source_mapping isa AbstractDict ? source_mapping : Dict{Any,Any}()
    mapping_by_field = get(source_mapping, "by_field",
                           get(source_mapping, :by_field, Dict{Any,Any}()))
    mapping_by_field = mapping_by_field isa AbstractDict ? mapping_by_field : Dict{Any,Any}()
    raw_mapped_fields = mapped_fields === nothing ?
        get(meta, "powerio_source_mapped_fields",
            get(meta, :powerio_source_mapped_fields, Any[])) : mapped_fields
    mapped_fields = _bmopf_source_schema_field_vector(raw_mapped_fields)
    source_semantics = get(meta, "powerio_source_semantics",
                           get(meta, :powerio_source_semantics, Dict{Any,Any}()))
    source_semantics = source_semantics isa AbstractDict ? source_semantics : Dict{Any,Any}()
    threshold_observations = get(source_semantics, "load_voltage_thresholds",
                                 get(source_semantics, :load_voltage_thresholds, Any[]))
    threshold_observations = threshold_observations isa AbstractVector ? threshold_observations : Any[]
    source_model_observations = get(source_semantics, "voltage_source_models",
                                    get(source_semantics, :voltage_source_models, Any[]))
    source_model_observations = source_model_observations isa AbstractVector ? source_model_observations : Any[]
    behavior_contract = if isdefined(BMOPFTools, :powerio_source_behavior_contract)
        try
            BMOPFTools.powerio_source_behavior_contract(network)
        catch
            Dict{String,Any}()
        end
    else
        Dict{String,Any}()
    end
    behavior_contract = behavior_contract isa AbstractDict ? behavior_contract : Dict{Any,Any}()
    behavior_observations = get(behavior_contract, "load_voltage_behavior",
                                get(behavior_contract, :load_voltage_behavior, Any[]))
    behavior_observations = behavior_observations isa AbstractVector ? behavior_observations : Any[]

    fields = String[]
    scopes = String[]
    impacts = String[]
    statuses = String[]
    blocking = Bool[]
    for message in warnings
        field_match = match(r"`([^`]+)`", message)
        field = isnothing(field_match) ? "unknown" : String(field_match.captures[1])
        scope_tokens = split(strip(message))
        scope = isempty(scope_tokens) ? "unknown" : replace(String(first(scope_tokens)), ":" => "")
        policy = _bmopf_source_schema_warning_policy(field)
        push!(fields, field)
        push!(scopes, scope)
        push!(impacts, policy.impact)
        push!(statuses, policy.status)
        push!(blocking, policy.blocking)
    end

    warning_fields = sort!(unique(fields))
    provenance_warning_fields = sort!(intersect(warning_fields, provenance_fields))
    mapped_warning_fields = sort!(intersect(warning_fields, mapped_fields))
    blocking_warning_fields = sort!(unique(fields[findall(blocking)]))
    unmapped_blocking_fields = sort!(setdiff(blocking_warning_fields, mapped_fields))

    report = NLPDiagnostics.DiagnosticReport()
    report.metadata[:stage] = "bmopf_source_schema"
    report.metadata[:bmopf_source_schema_warning_count] = string(length(warnings))
    report.metadata[:bmopf_source_schema_physical_blocking_count] = string(count(blocking))
    report.metadata[:bmopf_source_schema_representational_count] = string(count(==("representational"), impacts))
    report.metadata[:bmopf_source_schema_device_semantics_count] = string(count(==("device_semantics"), impacts))
    report.metadata[:bmopf_source_schema_unclassified_count] = string(count(==("unknown"), impacts))
    report.metadata[:bmopf_source_schema_source_path] = source_path
    report.metadata[:bmopf_source_schema_provenance_available] = string(!isempty(provenance_fields))
    report.metadata[:bmopf_source_schema_provenance_fields] = join(provenance_fields, ",")
    report.metadata[:bmopf_source_schema_provenance_field_count] = string(length(provenance_fields))
    report.metadata[:bmopf_source_schema_provenance_warning_fields] = join(provenance_warning_fields, ",")
    report.metadata[:bmopf_source_schema_provenance_warning_field_count] = string(length(provenance_warning_fields))
    report.metadata[:bmopf_source_schema_mapped_fields] = join(mapped_fields, ",")
    report.metadata[:bmopf_source_schema_mapped_field_count] = string(length(mapped_fields))
    report.metadata[:bmopf_source_schema_mapped_warning_field_count] = string(length(mapped_warning_fields))
    report.metadata[:bmopf_source_schema_unmapped_blocking_fields] = join(unmapped_blocking_fields, ",")
    report.metadata[:bmopf_source_schema_restoration_ready] = string(isempty(unmapped_blocking_fields))
    report.metadata[:bmopf_source_schema_mapping_statuses] = join(sort!(unique(
        String[string(get(value, "status", get(value, :status, "unknown")))
                 for value in values(mapping_by_field) if value isa AbstractDict])), ",")
    report.metadata[:bmopf_source_schema_mapping_field_statuses] = join(sort!(String[
        "$(key)=>$(get(value, "status", get(value, :status, "unknown")))"
        for (key, value) in mapping_by_field if value isa AbstractDict
    ]), ";")
    report.metadata[:bmopf_source_schema_mapping_targets] = join(sort!(String[
        "$(key)=>$(get(value, "target", get(value, :target, "unknown")))"
        for (key, value) in mapping_by_field if value isa AbstractDict
    ]), ";")
    report.metadata[:bmopf_source_schema_threshold_observation_count] =
        string(length(threshold_observations))
    report.metadata[:bmopf_source_schema_threshold_observation_statuses] = join(sort!(unique(String[
        string(get(item, "status", get(item, :status, "unknown")))
        for item in threshold_observations if item isa AbstractDict
    ])), ",")
    report.metadata[:bmopf_source_schema_source_model_observation_count] =
        string(length(source_model_observations))
    report.metadata[:bmopf_source_schema_source_model_contract_statuses] = join(sort!(unique(String[
        string(get(item, "status", get(item, :status, "unknown")))
        for item in source_model_observations if item isa AbstractDict
    ])), ",")
    report.metadata[:bmopf_source_schema_behavior_contract_available] = string(
        get(behavior_contract, "source_semantics_available",
            get(behavior_contract, :source_semantics_available, false)) === true)
    report.metadata[:bmopf_source_schema_behavior_contract_version] = string(
        get(behavior_contract, "contract_version", get(behavior_contract, :contract_version, "")))
    report.metadata[:bmopf_source_schema_behavior_constraint_policy] = string(
        get(behavior_contract, "constraint_policy", get(behavior_contract, :constraint_policy, "")))
    report.metadata[:bmopf_source_schema_behavior_candidate_count] = string(
        length(behavior_observations))
    report.metadata[:bmopf_source_schema_behavior_eligible_candidate_count] = string(
        get(behavior_contract, "eligible_candidate_count",
            get(behavior_contract, :eligible_candidate_count, 0)))
    report.metadata[:bmopf_source_schema_warning_fields] = join(unique(fields), ",")
    report.metadata[:bmopf_source_schema_warning_scopes] = join(unique(scopes), ",")
    report.metadata[:bmopf_source_schema_warning_impacts] = join(unique(impacts), ",")
    report.metadata[:bmopf_source_schema_warning_policy_statuses] = join(unique(statuses), ",")
    report.metadata[:bmopf_source_schema_warning_field_counts] = _bmopf_source_schema_count_string(fields)
    report.metadata[:bmopf_source_schema_warning_scope_counts] = _bmopf_source_schema_count_string(scopes)
    report.metadata[:bmopf_source_schema_warning_impact_counts] = _bmopf_source_schema_count_string(impacts)
    report.metadata[:bmopf_source_schema_warning_policy_status_counts] = _bmopf_source_schema_count_string(statuses)

    if !isempty(provenance_fields)
        push!(report, NLPDiagnostics.Finding(:bmopf_source_schema_provenance_preserved;
            severity = NLPDiagnostics.SeverityInfo,
            domain = NLPDiagnostics.RepresentationalIssue,
            basis = NLPDiagnostics.StructuralProof,
            confidence = NLPDiagnostics.ConfidenceCertain,
            observation = "The conversion record preserves a source-only metadata inventory for $(length(provenance_fields)) field(s).",
            why_it_matters = "Provenance allows source-level fields to be audited and mapped later, but it does not mean those fields are active in the BMOPF equations or solver scaling.",
            evidence = [NLPDiagnostics.Evidence("PowerIO source metadata inventory";
                details = [
                    "fields" => join(provenance_fields, ","),
                    "warning_fields_with_provenance" => join(provenance_warning_fields, ","),
                    "source" => source_path,
                ])],
            suggested_actions = ["Use the preserved field inventory to implement explicit BMOPF mappings; retain the provenance record with benchmark artifacts."],
        ))
    end
    if !isempty(threshold_observations) || !isempty(source_model_observations)
        threshold_statuses = unique(String[string(get(item, "status", get(item, :status, "unknown")))
                                    for item in threshold_observations if item isa AbstractDict])
        model_statuses = unique(String[string(get(item, "status", get(item, :status, "unknown")))
                                 for item in source_model_observations if item isa AbstractDict])
        push!(report, NLPDiagnostics.Finding(:bmopf_source_schema_behavior_observations;
            severity = NLPDiagnostics.SeverityInfo,
            domain = NLPDiagnostics.RepresentationalIssue,
            basis = NLPDiagnostics.StructuralProof,
            confidence = NLPDiagnostics.ConfidenceCertain,
            observation = "The source record preserves $(length(threshold_observations)) load voltage-behavior observation(s) and $(length(source_model_observations)) voltage-source model contract(s).",
            why_it_matters = "These observations support physical interpretation without pretending that load behavior thresholds are BMOPF bus bounds or that every source model has an active BMOPF equivalent.",
            evidence = [NLPDiagnostics.Evidence("Source semantic observation record";
                details = [
                    "load_threshold_count" => length(threshold_observations),
                    "load_threshold_statuses" => join(threshold_statuses, ","),
                    "source_model_count" => length(source_model_observations),
                    "source_model_contract_statuses" => join(model_statuses, ","),
                    "behavior_contract_version" => get(behavior_contract,
                        "contract_version", get(behavior_contract, :contract_version, "")),
                    "constraint_policy" => get(behavior_contract,
                        "constraint_policy", get(behavior_contract, :constraint_policy, "")),
                    "eligible_constraint_candidate_count" => get(behavior_contract,
                        "eligible_candidate_count", get(behavior_contract, :eligible_candidate_count, 0)),
                    "source" => source_path,
                ])],
            suggested_actions = ["Use the observations for diagnostics and retain the explicit distinction between behavioral thresholds, boundary contracts, and active optimization constraints."],
        ))
    end

    for (impact, code, severity, observation, why, action) in (
        ("physical_or_operating_point", :bmopf_source_schema_physical_metadata_loss,
            NLPDiagnostics.SeverityWarning,
            "PowerIO source fields carrying physical or operating-point semantics were dropped during BMOPF conversion.",
            "Expected physical modes, rank interpretation, and operating-point diagnostics can be incomplete when these fields are unavailable.",
            "Preserve or explicitly map the source physical fields before treating BMOPF numerical findings as physically complete."),
        ("device_semantics", :bmopf_source_schema_device_semantics_loss,
            NLPDiagnostics.SeverityWarning,
            "PowerIO device-semantics fields were dropped during BMOPF conversion.",
            "The staged model may not preserve device behavior or control interpretation needed for physical diagnosis.",
            "Add an explicit BMOPF mapping for the device-semantics fields or mark the affected device semantics unavailable."),
        ("representational", :bmopf_source_schema_representational_loss,
            NLPDiagnostics.SeverityInfo,
            "PowerIO fields were dropped because they have no direct BMOPF representation.",
            "The mathematics may still be represented, but source-level units or annotations cannot be reconstructed from the staged model.",
            "Retain the source metadata alongside the staged network when unit-aware interpretation is required."),
        ("unknown", :bmopf_source_schema_unclassified_loss,
            NLPDiagnostics.SeverityWarning,
            "PowerIO source fields were dropped without a recognized fidelity policy.",
            "Unclassified information loss can hide physical or device semantics and blocks a confident interpretation of downstream findings.",
            "Classify the field and add an explicit BMOPF mapping before relying on physical conclusions."),
    )
        selected = findall(==(impact), impacts)
        isempty(selected) && continue
        selected_fields = unique(fields[selected])
        selected_scopes = unique(scopes[selected])
        selected_messages = unique(warnings[selected])
        push!(report, NLPDiagnostics.Finding(code;
            severity = severity,
            domain = NLPDiagnostics.RepresentationalIssue,
            basis = NLPDiagnostics.StructuralProof,
            confidence = NLPDiagnostics.ConfidenceCertain,
            observation = "$(observation) Observed $(length(selected)) warning(s) for fields $(join(selected_fields, ", ")).",
            why_it_matters = why,
            evidence = [NLPDiagnostics.Evidence("PowerIO conversion warning record";
                details = [
                    "warning_count" => length(selected),
                    "fields" => join(selected_fields, ","),
                    "scopes" => join(selected_scopes, ","),
                    "messages" => join(selected_messages, " | "),
                    "provenance_fields" => join(intersect(selected_fields, provenance_fields), ","),
                    "mapped_fields" => join(intersect(selected_fields, mapped_fields), ","),
                    "unmapped_blocking_fields" => join(intersect(selected_fields, unmapped_blocking_fields), ","),
                    "mapping_targets" => get(report.metadata,
                        :bmopf_source_schema_mapping_targets, ""),
                    "source" => source_path,
                ])],
            suggested_actions = [action],
        ))
    end
    return report
end

"""Build an isolated auxiliary JuMP model for source voltage-behavior candidates."""
function _bmopf_source_behavior_auxiliary_model(
    context;
    optimizer = nothing,
    include_ineligible::Bool = false,
    source_contract = nothing,
)
    owner = _bmopf_context_model(context)
    owner isa JuMP.Model || throw(ArgumentError(
        "BMOPFTools.opf_model(context) did not return a JuMP.Model"))
    network = BMOPFTools.opf_network(context)
    source_contract_supplied = source_contract !== nothing
    contract = source_contract_supplied ? source_contract :
        BMOPFTools.powerio_source_behavior_contract(
            network; plan_auxiliary_constraints = true)
    contract isa AbstractDict || throw(ArgumentError(
        "source_contract must be a dictionary returned by powerio_source_behavior_contract"))
    auxiliary = optimizer === nothing ? JuMP.Model() : JuMP.Model(optimizer)
    voltage_real = Dict{Tuple{String,String},JuMP.VariableRef}()
    voltage_imag = Dict{Tuple{String,String},JuMP.VariableRef}()
    records = Dict{String,Any}[]
    constraints = Dict{String,Any}[]

    for candidate in get(contract, "auxiliary_constraint_candidates", Any[])
        candidate isa AbstractDict || continue
        scope = string(get(candidate, "scope", "unknown"))
        status = string(get(candidate, "status", "not_ready"))
        terminals = get(candidate, "terminal_map", Any[])
        bus = get(candidate, "bus", nothing)
        nominal = get(candidate, "nominal_voltage", Any[])
        vmin = get(candidate, "vminpu", nothing)
        vmax = get(candidate, "vmaxpu", nothing)
        ready = status == "candidate" && bus isa AbstractString &&
            terminals isa AbstractVector && length(terminals) == 2 &&
            nominal isa AbstractVector && length(nominal) == 1 &&
            nominal[1] isa Real && isfinite(Float64(nominal[1])) &&
            vmin isa Real && vmax isa Real &&
            isfinite(Float64(vmin)) && isfinite(Float64(vmax)) &&
            Float64(vmin) <= Float64(vmax) && Float64(nominal[1]) > 0.0
        if !ready
            push!(records, Dict{String,Any}(
                "scope" => scope,
                "status" => "not_materialized",
                "reason" => "terminal_voltage_projection_not_ready",
                "active_in_original_model" => false,
            ))
            continue
        end
        bus_id = String(bus)
        terminal_ids = String[string(item) for item in terminals]
        keys = [(bus_id, terminal_ids[1]), (bus_id, terminal_ids[2])]
        for key in keys
            if !haskey(voltage_real, key)
                label = replace("$(key[1])_$(key[2])", r"[^A-Za-z0-9_]" => "_")
                voltage_real[key] = JuMP.@variable(auxiliary, base_name = "vbr_$(label)")
                voltage_imag[key] = JuMP.@variable(auxiliary, base_name = "vbi_$(label)")
            end
        end
        vr = voltage_real[keys[1]] - voltage_real[keys[2]]
        vi = voltage_imag[keys[1]] - voltage_imag[keys[2]]
        magnitude_squared = vr^2 + vi^2
        source_nominal_voltage = Float64(nominal[1])
        voltage_base = _bmopf_voltage_base(context, bus_id)
        model_nominal_voltage = if source_contract_supplied && !isnothing(voltage_base)
            source_nominal_voltage / voltage_base
        else
            source_nominal_voltage
        end
        isfinite(model_nominal_voltage) && model_nominal_voltage > 0.0 || begin
            push!(records, Dict{String,Any}(
                "scope" => scope,
                "status" => "not_materialized",
                "reason" => "nominal_voltage_coordinate_alignment_unavailable",
                "active_in_original_model" => false,
            ))
            continue
        end
        physical_nominal_voltage = if source_contract_supplied
            source_nominal_voltage
        elseif !isnothing(voltage_base)
            source_nominal_voltage * voltage_base
        else
            source_nominal_voltage
        end
        lower_squared = (Float64(vmin) * model_nominal_voltage)^2
        upper_squared = (Float64(vmax) * model_nominal_voltage)^2
        lower_squared_physical = (Float64(vmin) * physical_nominal_voltage)^2
        upper_squared_physical = (Float64(vmax) * physical_nominal_voltage)^2
        lower = JuMP.@constraint(auxiliary, lower_squared <= magnitude_squared)
        upper = JuMP.@constraint(auxiliary, magnitude_squared <= upper_squared)
        push!(constraints, Dict{String,Any}(
            "scope" => scope,
            "lower" => lower,
            "upper" => upper,
            "lower_squared_V2" => lower_squared_physical,
            "upper_squared_V2" => upper_squared_physical,
            "lower_squared_model2" => lower_squared,
            "upper_squared_model2" => upper_squared,
        ))
        push!(records, Dict{String,Any}(
            "scope" => scope,
            "status" => "materialized",
            "bus" => bus_id,
            "terminal_map" => terminal_ids,
            "nominal_voltage_V" => physical_nominal_voltage,
            "nominal_voltage_model" => model_nominal_voltage,
            "model_coordinate_units" => isnothing(voltage_base) ? "SI/model-native" : "per-unit",
            "voltage_base_V" => voltage_base,
            "vminpu" => Float64(vmin),
            "vmaxpu" => Float64(vmax),
            "constraint_family" => "load_terminal_voltage_ratio_bounds",
            "constraint_form" => "vminpu <= abs(V_terminal) / v_nom <= vmaxpu",
            "active_in_original_model" => false,
            "materialization" => "auxiliary_model_only",
        ))
    end
    return Dict{String,Any}(
        "model" => auxiliary,
        "source_contract" => contract,
        "records" => records,
        "constraints" => constraints,
        "variable_count" => JuMP.num_variables(auxiliary),
        "constraint_pair_count" => length(constraints),
        "original_model" => owner,
        "original_model_variable_count" => JuMP.num_variables(owner),
        "original_model_mutated" => false,
        "status" => isempty(constraints) ? "no_materialized_candidates" : "materialized",
    )
end

"""Solve an isolated source-behavior auxiliary model when an optimizer is supplied."""
function _bmopf_source_behavior_auxiliary_solve(
    auxiliary::AbstractDict;
    optimizer = nothing,
    silent::Bool = true,
    optimizer_attributes::AbstractDict = Dict{String,Any}(),
)
    model = get(auxiliary, "model", nothing)
    model isa JuMP.Model || throw(ArgumentError(
        "auxiliary must be the result of bmopf_source_behavior_auxiliary_model"))
    if optimizer !== nothing
        JuMP.set_optimizer(model, optimizer)
    end
    try
        silent && JuMP.set_silent(model)
        for (name, value) in optimizer_attributes
            JuMP.set_optimizer_attribute(model, String(name), value)
        end
        JuMP.@objective(model, Min, 0.0)
        JuMP.optimize!(model)
    catch error
        return Dict{String,Any}(
            "status" => "unavailable",
            "termination_status" => "optimizer_not_available",
            "error" => sprint(showerror, error),
            "feasible" => false,
            "result_count" => 0,
        )
    end
    termination = string(JuMP.termination_status(model))
    result_count = JuMP.result_count(model)
    feasible = result_count > 0 && JuMP.primal_status(model) != MOI.NO_SOLUTION
    return Dict{String,Any}(
        "status" => feasible ? "solved" : "unsolved",
        "termination_status" => termination,
        "primal_status" => string(JuMP.primal_status(model)),
        "feasible" => feasible,
        "result_count" => result_count,
        "objective_value" => feasible ? JuMP.objective_value(model) : nothing,
    )
end

"""Evaluate source voltage-behavior thresholds at a typed BMOPF point."""
function _bmopf_source_behavior_report(
    context,
    point::NLPDiagnostics.EvaluationPoint;
    solve_auxiliary::Bool = false,
    optimizer = nothing,
    source_contract = nothing,
)
    auxiliary = _bmopf_source_behavior_auxiliary_model(
        context; source_contract = source_contract)
    positions = Dict(variable => value for (variable, value) in
                     zip(point.variables, point.values))
    report = NLPDiagnostics.DiagnosticReport()
    checked = 0
    below = 0
    above = 0
    unavailable = 0
    rows = Dict{String,Any}[]
    for record in get(auxiliary, "records", Any[])
        record isa AbstractDict || continue
        get(record, "status", "") == "materialized" || continue
        scope = string(get(record, "scope", "unknown"))
        bus = String(get(record, "bus", ""))
        terminals = String[string(item) for item in get(record, "terminal_map", Any[])]
        length(terminals) == 2 || continue
        values = Float64[]
        for terminal in terminals
            object = try
                BMOPFTools.opf_object(context,
                    BMOPFTools.opf_bus_voltage_key(bus, terminal; component = :real))
            catch
                nothing
            end
            imag_object = try
                BMOPFTools.opf_object(context,
                    BMOPFTools.opf_bus_voltage_key(bus, terminal; component = :imag))
            catch
                nothing
            end
            object isa JuMP.VariableRef && imag_object isa JuMP.VariableRef || break
            vr = get(positions, JuMP.index(object), nothing)
            vi = get(positions, JuMP.index(imag_object), nothing)
            vr isa Real && vi isa Real && isfinite(Float64(vr)) && isfinite(Float64(vi)) || break
            push!(values, Float64(vr)); push!(values, Float64(vi))
        end
        length(values) == 4 || begin
            unavailable += 1
            push!(rows, Dict{String,Any}("scope" => scope, "status" => "point_unavailable"))
            continue
        end
        base = _bmopf_voltage_base(context, bus)
        base = isnothing(base) ? 1.0 : base
        nominal = Float64(get(record, "nominal_voltage_V", NaN))
        ratio = base * hypot(values[1] - values[3], values[2] - values[4]) / nominal
        vmin = Float64(get(record, "vminpu", NaN))
        vmax = Float64(get(record, "vmaxpu", NaN))
        isfinite(ratio) && isfinite(vmin) && isfinite(vmax) || begin
            unavailable += 1
            push!(rows, Dict{String,Any}("scope" => scope, "status" => "nonfinite"))
            continue
        end
        checked += 1
        status = ratio < vmin ? "below_vminpu" : ratio > vmax ? "above_vmaxpu" : "within_bounds"
        status == "below_vminpu" && (below += 1)
        status == "above_vmaxpu" && (above += 1)
        push!(rows, Dict{String,Any}(
            "scope" => scope,
            "status" => status,
            "observed_ratio" => ratio,
            "nominal_voltage_V" => nominal,
            "nominal_voltage_model" => get(record, "nominal_voltage_model", nominal),
            "model_coordinate_units" => get(record, "model_coordinate_units", "unknown"),
            "voltage_base_V" => get(record, "voltage_base_V", nothing),
            "vminpu" => vmin,
            "vmaxpu" => vmax,
            "violation" => max(vmin - ratio, ratio - vmax, 0.0),
        ))
        status == "within_bounds" && continue
        push!(report, NLPDiagnostics.Finding(:bmopf_source_behavior_threshold_violation;
            severity = NLPDiagnostics.SeverityWarning,
            domain = NLPDiagnostics.PhysicalIssue,
            basis = NLPDiagnostics.NumericalObservation,
            confidence = NLPDiagnostics.ConfidenceCertain,
            observation = "Load voltage-behavior threshold $(status) observed for $(scope).",
            why_it_matters = "The operating point lies outside the source-declared load behavior domain; this is not evidence that the production BMOPF model contains a corresponding bus bound.",
            evidence = [NLPDiagnostics.Evidence("Load voltage-behavior threshold";
                details = ["scope" => scope, "observed_ratio" => ratio,
                           "vminpu" => vmin, "vmaxpu" => vmax,
                           "violation" => max(vmin - ratio, ratio - vmax, 0.0)])],
            suggested_actions = ["Inspect initialization, load-law validity, and physical operating assumptions before adding any auxiliary constraint."],
        ))
    end
    solve = solve_auxiliary ? _bmopf_source_behavior_auxiliary_solve(auxiliary; optimizer = optimizer) :
        Dict{String,Any}("status" => "not_requested")
    report.metadata[:stage] = "bmopf_source_behavior"
    report.metadata[:bmopf_source_behavior_checked_count] = string(checked)
    report.metadata[:bmopf_source_behavior_below_vminpu_count] = string(below)
    report.metadata[:bmopf_source_behavior_above_vmaxpu_count] = string(above)
    report.metadata[:bmopf_source_behavior_unavailable_count] = string(unavailable)
    report.metadata[:bmopf_source_behavior_auxiliary_constraint_pair_count] =
        string(get(auxiliary, "constraint_pair_count", 0))
    report.metadata[:bmopf_source_behavior_auxiliary_solve_status] =
        string(get(solve, "status", "unknown"))
    return (report = report, rows = rows, auxiliary = auxiliary, solve = solve)
end

"""Compare source-domain threshold evidence with a production solver result."""
function _bmopf_source_behavior_solver_comparison(
    context,
    point::NLPDiagnostics.EvaluationPoint;
    solver_name::AbstractString = "unknown",
    termination_status::AbstractString = "unknown",
    feasible = nothing,
    source_contract = nothing,
)
    source = _bmopf_source_behavior_report(
        context, point;
        solve_auxiliary = false,
        source_contract = source_contract,
    )
    rows = source.rows
    below = count(row -> get(row, "status", "") == "below_vminpu", rows)
    above = count(row -> get(row, "status", "") == "above_vmaxpu", rows)
    violations = below + above
    checked = count(row -> get(row, "status", "") in
        ("within_bounds", "below_vminpu", "above_vmaxpu"), rows)
    status = lowercase(strip(String(termination_status)))
    termination_success = status in
        ("solved", "optimal", "locally_solved", "feasible_point", "success")
    solver_success = termination_success && (feasible !== false)
    solver_known = feasible isa Bool || status != "unknown"
    classification = if checked == 0
        "source_domain_evidence_unavailable"
    elseif !solver_known
        "unknown_solver_outcome"
    elseif solver_success && violations > 0
        "solver_success_outside_source_domain"
    elseif !solver_success && violations > 0
        "solver_failure_aligned_with_source_domain_violation"
    elseif !solver_success
        "solver_failure_not_explained_by_source_domain_thresholds"
    else
        "solver_and_source_domain_consistent"
    end
    report = source.report
    report.metadata[:bmopf_source_behavior_solver_name] = String(solver_name)
    report.metadata[:bmopf_source_behavior_solver_termination_status] = String(termination_status)
    report.metadata[:bmopf_source_behavior_solver_feasible] =
        isnothing(feasible) ? "unknown" : string(feasible)
    report.metadata[:bmopf_source_behavior_solver_termination_success] =
        string(termination_success)
    report.metadata[:bmopf_source_behavior_solver_classification] = classification
    report.metadata[:bmopf_source_behavior_solver_threshold_violation_count] = string(violations)
    if classification in ("solver_success_outside_source_domain",
                          "solver_failure_aligned_with_source_domain_violation",
                          "solver_failure_not_explained_by_source_domain_thresholds")
        observation = classification == "solver_success_outside_source_domain" ?
            "The production solver returned a feasible result outside the source-declared voltage-behavior domain." :
            classification == "solver_failure_aligned_with_source_domain_violation" ?
            "The production solver did not return a feasible result and the evaluated point is outside the source-declared voltage-behavior domain." :
            "The production solver did not return a feasible result, but the evaluated point is within the source-declared voltage-behavior domain."
        why = classification == "solver_failure_not_explained_by_source_domain_thresholds" ?
            "The source voltage-behavior thresholds do not explain this solver outcome; inspect derivatives, scaling, initialization, and structural degeneracy." :
            "The alignment is evidence for a possible model-domain interaction, not proof that the source threshold caused the solver outcome."
        push!(report, NLPDiagnostics.Finding(Symbol("bmopf_source_behavior_" *
                (classification == "solver_success_outside_source_domain" ?
                 "solver_success_outside_domain" : classification ==
                 "solver_failure_aligned_with_source_domain_violation" ?
                 "solver_failure_aligned" : "solver_failure_unexplained"));
            severity = NLPDiagnostics.SeverityWarning,
            domain = NLPDiagnostics.PhysicalIssue,
            basis = NLPDiagnostics.NumericalObservation,
            confidence = NLPDiagnostics.ConfidenceMedium,
            observation = observation,
            why_it_matters = why,
            evidence = [NLPDiagnostics.Evidence("Production solver/source-domain comparison";
                details = ["solver" => String(solver_name),
                           "termination_status" => String(termination_status),
                           "feasible" => isnothing(feasible) ? "unknown" : feasible,
                           "below_vminpu_count" => below,
                           "above_vmaxpu_count" => above,
                           "classification" => classification])],
            suggested_actions = ["Inspect the source-to-BMOPF semantic contract and the solver-result point before changing production constraints."],
        ))
    end
    comparison = Dict{String,Any}(
        "solver" => String(solver_name),
        "termination_status" => String(termination_status),
        "feasible" => isnothing(feasible) ? nothing : feasible,
        "termination_success" => termination_success,
        "classification" => classification,
        "threshold_violation_count" => violations,
        "below_vminpu_count" => below,
        "above_vmaxpu_count" => above,
        "checked_count" => checked,
    )
    return (report = report, rows = rows, comparison = comparison,
            source_behavior = source)
end

function _bmopf_append_report!(target, source)
    append!(target.findings, source.findings)
    merge!(target.metadata, source.metadata)
    return target
end

"""Preserve component-rank capability in a flat profile report without adding a duplicate finding."""
function _bmopf_append_component_rank_capability_metadata!(report, context)
    capability = _bmopf_component_rank_capability_report(context)
    report.metadata[:bmopf_component_rank_capability_checked] = "true"
    report.metadata[:bmopf_component_rank_capability_finding_count] =
        string(length(capability.findings))
    for key in (:bmopf_component_metadata_count,
                :bmopf_component_expected_rank_declared_count,
                :bmopf_component_expected_rank_unavailable_count,
                :bmopf_component_expected_rank_coverage)
        haskey(capability.metadata, key) || continue
        report.metadata[key] = capability.metadata[key]
    end
    return report
end

"""Collect BMOPF-only evidence without rerunning generic profiling stages."""
function _bmopf_profile_context_report(
    context,
    point::NLPDiagnostics.EvaluationPoint;
    include_floating_neutral_candidates::Bool,
    include_differentiability::Bool = true,
)
    report = NLPDiagnostics.DiagnosticReport()
    _bmopf_append_report!(report,
        NLPDiagnostics.bmopf_terminal_report(BMOPFTools.opf_network(context)))
    _bmopf_append_report!(report, _bmopf_source_schema_report(context))
    _bmopf_append_report!(report, _bmopf_terminal_port_report(context))
    _bmopf_append_report!(report, _bmopf_opf_lifecycle_report(context))
    _bmopf_append_report!(report, _bmopf_opf_registry_report(context))
    _bmopf_append_report!(report, _bmopf_component_report(context))
    _bmopf_append_report!(report,
        _bmopf_terminal_port_coordinate_scale_report(context, point))
    # Keep the existing profile finding set stable. The standalone capability
    # report remains available to callers that want its explicit finding; the
    # profile record still exposes its counts and coverage as metadata.
    _bmopf_append_component_rank_capability_metadata!(report, context)
    if include_differentiability
        _bmopf_append_report!(report,
            NLPDiagnostics.bmopf_opf_differentiability_report(context))
    end
    candidates = include_floating_neutral_candidates ?
                 _bmopf_floating_neutral_candidate_modes(context) :
                 NLPDiagnostics.ExpectedNullspaceMode[]
    _bmopf_append_candidate_provenance!(report, context, candidates,
                                        include_floating_neutral_candidates)
    report.metadata[:stage] = "bmopf_profile_context"
    report.metadata[:bmopf_opf_context] = "BMOPFTools staged OPF context"
    report.metadata[:bmopf_opf_lifecycle] = string(BMOPFTools.opf_lifecycle(context))
    sort!(report.findings; by = finding -> (-Int(finding.severity), string(finding.code)))
    return report
end

_bmopf_context_profile_report(context, point; kwargs...) =
    _bmopf_profile_context_report(context, point; kwargs...)

"""
    bmopf_profile_case(context, case; include_initialization = true,
        include_differentiability = true, ...) -> BMOPFProfileResult

Profile one explicit `ProfileCase` against a staged BMOPF context. Generic
findings and timings are retained in `result.profile`; BMOPFTools terminal,
port, lifecycle, registry, component, direct terminal-scale, and (by default)
engine differentiability evidence are retained separately in
`result.context_report`. This function never solves or modifies the model.
"""
function _bmopf_profile_case(
    context,
    case::NLPDiagnostics.ProfileCase;
    include_initialization::Bool = true,
    include_floating_neutral_candidates::Bool = false,
    include_differentiability::Bool = true,
    cache::NLPDiagnostics.EvaluationCache = NLPDiagnostics.EvaluationCache(),
    kwargs...,
)
    owner = _bmopf_context_model(context)
    owner isa JuMP.Model || throw(ArgumentError("BMOPFTools.opf_model(context) did not return a JuMP.Model"))
    backend = JuMP.backend(owner)
    generic_timing = @timed NLPDiagnostics.profile_case(backend, case; cache, kwargs...)
    context_timing = @timed _bmopf_profile_context_report(context, case.point;
        include_floating_neutral_candidates,
        include_differentiability,
    )
    initialization_timing = include_initialization ?
        @timed(_bmopf_analyze_initialization(context;
            include_floating_neutral_candidates = include_floating_neutral_candidates,
        )) : nothing
    seconds = Dict{Symbol,Float64}(
        :bmopf_context => context_timing.time,
        :bmopf_initialization => isnothing(initialization_timing) ? 0.0 : initialization_timing.time,
    )
    allocations = Dict{Symbol,Int}(
        :bmopf_context => context_timing.bytes,
        :bmopf_initialization => isnothing(initialization_timing) ? 0 : initialization_timing.bytes,
    )
    return NLPDiagnostics.BMOPFProfileResult(
        generic_timing.value,
        context_timing.value,
        isnothing(initialization_timing) ? nothing : initialization_timing.value,
        seconds,
        allocations,
    )
end

"""Build and optionally KCL-finalize a fresh staged context from copied data."""
function _bmopf_build_context(
    network::AbstractDict,
    ;
    build_kwargs::NamedTuple = NamedTuple(),
    prepare_context::Union{Nothing,Function} = nothing,
    copy_network::Bool = true,
    finalize_kcl::Bool = true,
)
    canonical = Dict{String,Any}(string(key) => value for (key, value) in network)
    prepared_network = copy_network ? deepcopy(canonical) : canonical
    build_timing = try
        @timed BMOPFTools.build_opf_model(prepared_network; build_kwargs...)
    catch error
        error isa MethodError && error.f === BMOPFTools.build_opf_model || rethrow()
        throw(ArgumentError(
            "BMOPFTools.build_opf_model is unavailable; load BMOPFTools' JuMP/IPOPT OPF extension before building benchmark contexts",
        ))
    end
    context = build_timing.value
    # The hook is deliberately explicit and runs before KCL finalization because
    # BMOPFTools' public lifecycle requires e.g. generated start values then.
    !isnothing(prepare_context) && prepare_context(context)
    kcl_timing = if finalize_kcl
        try
            @timed BMOPFTools.enforce_kcl!(context)
        catch error
            error isa MethodError && error.f === BMOPFTools.enforce_kcl! || rethrow()
            throw(ArgumentError(
                "BMOPFTools.enforce_kcl! is unavailable; load BMOPFTools' JuMP/IPOPT OPF extension before finalizing benchmark contexts",
            ))
        end
    else
        nothing
    end
    return (
        context = context,
        build_seconds = Float64(build_timing.time),
        build_allocations = Int(build_timing.bytes),
        kcl_seconds = isnothing(kcl_timing) ? 0.0 : Float64(kcl_timing.time),
        kcl_allocations = isnothing(kcl_timing) ? 0 : Int(kcl_timing.bytes),
        kcl_finalized = finalize_kcl,
        network_copied = copy_network,
    )
end

"""
    bmopf_build_and_profile(network, case_builder; finalize_kcl = true, build_kwargs = NamedTuple(), profile_kwargs = NamedTuple(), prepare_context = nothing)

Build a fresh staged BMOPF context from caller-owned `network`, then invoke
`case_builder(context)` to produce the explicit `ProfileCase` to profile. The
network is deep-copied by default. By default the fresh context is finalized
with BMOPFTools' public `enforce_kcl!` before profiling; pass
`finalize_kcl=false` only to benchmark an intentionally incomplete build.
The function never solves or modifies caller-owned data. The returned named
tuple retains the built context, `BMOPFProfileResult`, and separately measured
build/KCL cost.
`prepare_context`, when supplied explicitly, runs after construction but before
KCL finalization. It may mutate only the fresh staged context; callers remain
responsible for using a stage that is legal after the fused build recipe.
"""
function _bmopf_build_and_profile(
    network::AbstractDict,
    case_builder::Function;
    build_kwargs::NamedTuple = NamedTuple(),
    profile_kwargs::NamedTuple = NamedTuple(),
    prepare_context::Union{Nothing,Function} = nothing,
    copy_network::Bool = true,
    finalize_kcl::Bool = true,
)
    built = _bmopf_build_context(network;
        build_kwargs, prepare_context, copy_network, finalize_kcl,
    )
    case = case_builder(built.context)
    case isa NLPDiagnostics.ProfileCase || throw(ArgumentError(
        "case_builder(context) must return an NLPDiagnostics.ProfileCase, got $(typeof(case))",
    ))
    result = _bmopf_profile_case(built.context, case; profile_kwargs...)
    return (
        built...,
        result = result,
    )
end

"""
    bmopf_build_and_analyze_opf(network; finalize_kcl = true, build_kwargs = NamedTuple(), analysis_kwargs = NamedTuple(), prepare_context = nothing)

Build and KCL-finalize a fresh staged BMOPF context, then run the generic and
BMOPF structural analysis without an evaluation point. Consequently it never
evaluates derivatives, materializes a Jacobian, performs dense rank/SVD work,
or interprets a synthetic probe as an initialization. The network is copied by
default and neither it nor the staged model is solved or otherwise modified.
"""
function _bmopf_build_and_analyze_opf(
    network::AbstractDict;
    build_kwargs::NamedTuple = NamedTuple(),
    analysis_kwargs::NamedTuple = NamedTuple(),
    prepare_context::Union{Nothing,Function} = nothing,
    copy_network::Bool = true,
    finalize_kcl::Bool = true,
)
    built = _bmopf_build_context(network;
        build_kwargs, prepare_context, copy_network, finalize_kcl,
    )
    analysis_timing = @timed _bmopf_analyze_opf(built.context; analysis_kwargs...)
    report = analysis_timing.value
    report.metadata[:bmopf_benchmark_analysis_mode] = "structural"
    report.metadata[:bmopf_derivative_evaluation_requested] = "false"
    report.metadata[:bmopf_dense_rank_analysis_requested] = "false"
    return (
        built...,
        report = report,
        analysis_seconds = Float64(analysis_timing.time),
        analysis_allocations = Int(analysis_timing.bytes),
    )
end

function _bmopf_component_rank_capability_data(report::NLPDiagnostics.DiagnosticReport)
    metadata = report.metadata
    coverage = tryparse(Float64,
        get(metadata, :bmopf_component_expected_rank_coverage, ""))
    return Dict{String,Any}(
        "checked" => get(metadata, :bmopf_component_rank_capability_checked, "false") == "true",
        "component_count" => something(tryparse(Int,
            get(metadata, :bmopf_component_metadata_count, "")), 0),
        "expected_rank_declared_count" => something(tryparse(Int,
            get(metadata, :bmopf_component_expected_rank_declared_count, "")), 0),
        "expected_rank_unavailable_count" => something(tryparse(Int,
            get(metadata, :bmopf_component_expected_rank_unavailable_count, "")), 0),
        "expected_rank_coverage" => coverage,
        "finding_count" => something(tryparse(Int,
            get(metadata, :bmopf_component_rank_capability_finding_count, "")), 0),
    )
end

function NLPDiagnostics.profile_result_data(result::NLPDiagnostics.BMOPFProfileResult)
    return Dict{String,Any}(
        "profile" => NLPDiagnostics.profile_result_data(result.profile),
        "bmopf_context_report" => NLPDiagnostics.report_data(result.context_report),
        "bmopf_result_field_catalog" => _bmopf_result_field_catalog(),
        "bmopf_component_rank_capability" =>
            _bmopf_component_rank_capability_data(result.context_report),
        "bmopf_initialization_report" => isnothing(result.initialization_report) ?
            nothing : NLPDiagnostics.report_data(result.initialization_report),
        "bmopf_stage_seconds" => Dict(string(key) => value for
            (key, value) in sort!(collect(result.bmopf_stage_seconds); by = item -> string(first(item)))),
        "bmopf_stage_allocations" => Dict(string(key) => value for
            (key, value) in sort!(collect(result.bmopf_stage_allocations); by = item -> string(first(item)))),
    )
end

"""Report physical evidence behind opt-in BMOPF floating-neutral candidate modes."""
function _bmopf_floating_neutral_candidate_report(context)
    modes = _bmopf_floating_neutral_candidate_modes(context)
    components = _bmopf_floating_neutral_components(context)
    report = NLPDiagnostics.DiagnosticReport()
    report.metadata[:bmopf_floating_neutral_component_count] = string(length(components))
    report.metadata[:bmopf_floating_neutral_candidate_mode_count] = string(length(modes))
    for (ordinal, buses) in enumerate(components)
        push!(report, NLPDiagnostics.Finding(:bmopf_floating_neutral_candidate_mode;
            severity = NLPDiagnostics.SeverityInfo,
            domain = NLPDiagnostics.PhysicalIssue,
            basis = NLPDiagnostics.PhysicalExpectation,
            confidence = NLPDiagnostics.ConfidenceHigh,
            observation = "BMOPFTools declares floating neutral component $ordinal across $(length(buses)) bus(es), yielding real and imaginary uniform-shift candidate directions.",
            why_it_matters = "This is physical topology evidence, not a proof that the staged OPF Jacobian has either direction: voltage-source equations, fixed variables, and formulation constraints can remove the freedom.",
            evidence = [NLPDiagnostics.Evidence("BMOPFTools explicit floating-neutral component";
                details = ["component_ordinal" => ordinal, "bus_ids" => join(buses, ","), "candidate_modes" => "real,imag"])],
            suggested_actions = ["Pass the selected candidate directions to `bmopf_analyze_opf(...; expected_modes = modes)` at a meaningful evaluation point, then inspect residuals and nullspace alignment."],
        ))
    end
    return report
end

"""
    bmopf_analyze_degeneracy(context, point; ...)

Evaluate a staged BMOPF JuMP/MOI model at `point` and run generic local
degeneracy analysis. Floating-neutral directions are optional physical
expectations; they are compared with numerical evidence only when explicitly
enabled.
"""
function _bmopf_analyze_degeneracy(
    context,
    point;
    include_floating_neutral_candidates::Bool = false,
    expected_modes::AbstractVector{<:NLPDiagnostics.ExpectedNullspaceMode} =
        NLPDiagnostics.ExpectedNullspaceMode[],
    kwargs...,
)
    owner = _bmopf_context_model(context)
    owner isa JuMP.Model || throw(ArgumentError("BMOPFTools.opf_model(context) did not return a JuMP.Model"))
    backend = JuMP.backend(owner)
    evaluation = NLPDiagnostics.evaluate_numerical(backend, point)
    modes, candidates = _bmopf_resolved_expected_modes(context;
        include_floating_neutral_candidates, expected_modes,
    )
    report = NLPDiagnostics.analyze_degeneracy(backend, evaluation;
        expected_modes = modes, kwargs...,
    )
    return _bmopf_append_candidate_provenance!(report, context, candidates,
                                                include_floating_neutral_candidates)
end

"""Run generic local active-set analysis for a staged BMOPF context."""
function _bmopf_analyze_active_set(
    context,
    point;
    include_floating_neutral_candidates::Bool = false,
    expected_modes::AbstractVector{<:NLPDiagnostics.ExpectedNullspaceMode} =
        NLPDiagnostics.ExpectedNullspaceMode[],
    kwargs...,
)
    owner = _bmopf_context_model(context)
    owner isa JuMP.Model || throw(ArgumentError("BMOPFTools.opf_model(context) did not return a JuMP.Model"))
    backend = JuMP.backend(owner)
    evaluation = NLPDiagnostics.evaluate_numerical(backend, point)
    modes, candidates = _bmopf_resolved_expected_modes(context;
        include_floating_neutral_candidates, expected_modes,
    )
    report = NLPDiagnostics.analyze_active_set(backend, evaluation;
        expected_modes = modes, kwargs...,
    )
    return _bmopf_append_candidate_provenance!(report, context, candidates,
                                                include_floating_neutral_candidates)
end

"""Compare staged-BMOPF reduced-Hessian flat directions across supplied snapshots."""
function _bmopf_analyze_reduced_hessian_persistence(
    context,
    snapshots::AbstractVector{<:NLPDiagnostics.ReducedHessianSnapshot};
    include_floating_neutral_candidates::Bool = false,
    expected_modes::AbstractVector{<:NLPDiagnostics.ExpectedNullspaceMode} =
        NLPDiagnostics.ExpectedNullspaceMode[],
    kwargs...,
)
    owner = _bmopf_context_model(context)
    owner isa JuMP.Model || throw(ArgumentError("BMOPFTools.opf_model(context) did not return a JuMP.Model"))
    modes, candidates = _bmopf_resolved_expected_modes(context;
        include_floating_neutral_candidates, expected_modes,
    )
    report = NLPDiagnostics.analyze_reduced_hessian_persistence(JuMP.backend(owner), snapshots;
        expected_modes = modes, kwargs...,
    )
    return _bmopf_append_candidate_provenance!(report, context, candidates,
                                                include_floating_neutral_candidates)
end

"""Compare staged-BMOPF Jacobian rank and expected directions across points."""
function _bmopf_analyze_jacobian_rank_persistence(
    context,
    points;
    include_floating_neutral_candidates::Bool = false,
    expected_modes::AbstractVector{<:NLPDiagnostics.ExpectedNullspaceMode} =
        NLPDiagnostics.ExpectedNullspaceMode[],
    kwargs...,
)
    owner = _bmopf_context_model(context)
    owner isa JuMP.Model || throw(ArgumentError("BMOPFTools.opf_model(context) did not return a JuMP.Model"))
    backend = JuMP.backend(owner)
    evaluations = [NLPDiagnostics.evaluate_numerical(backend, point) for point in points]
    modes, candidates = _bmopf_resolved_expected_modes(context;
        include_floating_neutral_candidates, expected_modes,
    )
    report = NLPDiagnostics.analyze_jacobian_rank_persistence(evaluations;
        expected_modes = modes, kwargs...,
    )
    return _bmopf_append_candidate_provenance!(report, context, candidates,
                                                include_floating_neutral_candidates)
end

"""Compare declared BMOPF registry-family component ranks across points."""
function _bmopf_analyze_component_rank_persistence(
    context,
    points;
    include_floating_neutral_candidates::Bool = false,
    expected_modes::AbstractVector{<:NLPDiagnostics.ExpectedNullspaceMode} =
        NLPDiagnostics.ExpectedNullspaceMode[],
    kwargs...,
)
    owner = _bmopf_context_model(context)
    owner isa JuMP.Model || throw(ArgumentError("BMOPFTools.opf_model(context) did not return a JuMP.Model"))
    backend = JuMP.backend(owner)
    evaluations = [NLPDiagnostics.evaluate_numerical(backend, point) for point in points]
    modes, candidates = _bmopf_resolved_expected_modes(context;
        include_floating_neutral_candidates, expected_modes,
    )
    components = _bmopf_component_metadata(context)
    report = NLPDiagnostics.analyze_component_rank_persistence(backend, evaluations;
        components = components, expected_modes = modes, kwargs...,
    )
    declared = count(component -> !isnothing(component.expected_rank), components)
    report.metadata[:bmopf_component_expected_rank_declared_count] = string(declared)
    report.metadata[:bmopf_component_expected_rank_unavailable_count] = string(length(components) - declared)
    report.metadata[:bmopf_component_expected_rank_coverage] = isempty(components) ?
        "unavailable" : string(declared / length(components))
    return _bmopf_append_candidate_provenance!(report, context, candidates,
                                                include_floating_neutral_candidates)
end

"""Report whether a staged BMOPF OPF has reached the public KCL-finalized lifecycle."""
function _bmopf_opf_lifecycle_report(context)
    _bmopf_context_model(context)
    lifecycle = BMOPFTools.opf_lifecycle(context)
    report = NLPDiagnostics.DiagnosticReport()
    report.metadata[:bmopf_opf_lifecycle] = string(lifecycle)
    lifecycle == :kcl_finalized && return report
    push!(report, NLPDiagnostics.Finding(:bmopf_opf_model_not_finalized;
        severity = NLPDiagnostics.SeverityInfo,
        domain = NLPDiagnostics.RepresentationalIssue,
        basis = NLPDiagnostics.StructuralProof,
        confidence = NLPDiagnostics.ConfidenceCertain,
        observation = "BMOPFTools staged OPF lifecycle is '$lifecycle', not :kcl_finalized.",
        why_it_matters = "The model may intentionally be under construction, but its KCL and device-equation scope can still change; numerical rank or feasibility conclusions are therefore provisional.",
        evidence = [NLPDiagnostics.Evidence("BMOPFTools staged OPF lifecycle"; details = ["lifecycle" => lifecycle])],
        suggested_actions = ["Complete the staged build and call `enforce_kcl!` before interpreting numerical diagnostics as properties of the final OPF formulation."],
    ))
    return report
end

function _bmopf_differentiability_unavailable_report(reason::AbstractString)
    report = NLPDiagnostics.DiagnosticReport()
    report.metadata[:bmopf_opf_differentiability_available] = "false"
    push!(report, NLPDiagnostics.Finding(:bmopf_opf_differentiability_unavailable;
        severity = NLPDiagnostics.SeverityInfo,
        domain = NLPDiagnostics.RepresentationalIssue,
        basis = NLPDiagnostics.StructuralProof,
        confidence = NLPDiagnostics.ConfidenceCertain,
        observation = "BMOPFTools staged-OPF differentiability report is unavailable: $reason.",
        why_it_matters = "NLPDiagnostics can still inspect the compiled JuMP/MOI graph, but BMOPFTools-owned construction annotations and solver-state qualifications are unavailable.",
        evidence = [NLPDiagnostics.Evidence("BMOPFTools differentiability API availability")],
        suggested_actions = ["Load BMOPFTools' JuMP/IPOPT OPF extension and use a staged OPF context to include engine-owned differentiability evidence."],
    ))
    return report
end

"""
    bmopf_opf_differentiability_report(context; kwargs...) -> DiagnosticReport

Translate BMOPFTools' public staged-OPF differentiability audit into findings.
This exposes engine-owned annotations such as nonsmooth operators and dynamic
construction branches, plus local active-set qualifications. It is not a proof
of LICQ, KKT nonsingularity, or global solution-branch stability.
"""
function _bmopf_opf_differentiability_report(context; kwargs...)
    _bmopf_context_model(context)
    engine_report = try
        BMOPFTools.opf_differentiability_report(context; kwargs...)
    catch error
        error isa MethodError || rethrow()
        return _bmopf_differentiability_unavailable_report(
            "BMOPFTools' JuMP/IPOPT OPF extension is not loaded for this context",
        )
    end
    report = NLPDiagnostics.DiagnosticReport()
    report.metadata[:bmopf_opf_differentiability_available] = "true"
    report.metadata[:bmopf_opf_differentiability_ready] = string(engine_report.ready)
    report.metadata[:bmopf_opf_differentiability_lifecycle] = string(engine_report.lifecycle)
    report.metadata[:bmopf_opf_differentiability_termination_status] = engine_report.termination_status
    report.metadata[:bmopf_opf_differentiability_inequality_count] = string(engine_report.inequality_constraints)
    report.metadata[:bmopf_opf_differentiability_near_active_count] = string(length(engine_report.near_active_constraints))
    report.metadata[:bmopf_opf_differentiability_weakly_active_count] = string(length(engine_report.weakly_active_constraints))
    report.metadata[:bmopf_opf_differentiability_violated_count] = string(length(engine_report.violated_constraints))
    report.metadata[:bmopf_opf_differentiability_unused_coefficient_count] = string(length(engine_report.unused_coefficient_keys))
    for (records, category, domain) in (
        (engine_report.nonsmooth_operators, :nonsmooth_operator, NLPDiagnostics.MathematicalIssue),
        (engine_report.dynamic_branches, :dynamic_branch, NLPDiagnostics.RepresentationalIssue),
        (engine_report.unsupported_parameter_locations, :unsupported_parameter_location, NLPDiagnostics.RepresentationalIssue),
    )
        for record in records
            push!(report, NLPDiagnostics.Finding(:bmopf_opf_differentiability_annotation;
                severity = record.blocking ? NLPDiagnostics.SeverityError : NLPDiagnostics.SeverityWarning,
                domain = domain,
                basis = NLPDiagnostics.StructuralProof,
                confidence = NLPDiagnostics.ConfidenceCertain,
                observation = "BMOPFTools declares $(category) annotation '$(record.name)': $(record.description)",
                why_it_matters = record.blocking ?
                    "The engine marks this annotation as blocking for differentiability; derivative-based conclusions must not treat the staged model as smoothly differentiable." :
                    "The engine discloses this as a nonblocking qualification; inspect it before interpreting local derivatives or sensitivities.",
                evidence = [NLPDiagnostics.Evidence("BMOPFTools differentiability annotation"; details = [
                    "name" => record.name, "category" => category, "owner" => record.owner,
                    "blocking" => record.blocking,
                ])],
                suggested_actions = ["Inspect the BMOPFTools annotation metadata and the corresponding JuMP expression before relying on local derivatives."],
            ))
        end
    end
    if !isempty(engine_report.unused_coefficient_keys)
        push!(report, NLPDiagnostics.Finding(:bmopf_opf_unused_coefficient_provider;
            severity = NLPDiagnostics.SeverityWarning,
            domain = NLPDiagnostics.RepresentationalIssue,
            basis = NLPDiagnostics.StructuralProof,
            confidence = NLPDiagnostics.ConfidenceCertain,
            observation = "$(length(engine_report.unused_coefficient_keys)) BMOPFTools coefficient provider(s) were registered but not consumed.",
            why_it_matters = "A parameterized physics declaration that is not consumed can leave intended model behavior and derivative provenance disconnected.",
            evidence = [NLPDiagnostics.Evidence("BMOPFTools coefficient-provider audit")],
            suggested_actions = ["Check semantic coefficient keys, device ownership, and the staged build specification."],
        ))
    end
    if !engine_report.ready
        push!(report, NLPDiagnostics.Finding(:bmopf_opf_differentiability_not_ready;
            severity = NLPDiagnostics.SeverityInfo,
            domain = NLPDiagnostics.NumericalIssue,
            basis = NLPDiagnostics.LocalInference,
            confidence = NLPDiagnostics.ConfidenceHigh,
            observation = "BMOPFTools does not consider the current staged OPF ready for an unqualified local differentiability claim.",
            why_it_matters = "This is engine-owned local evidence; it may reflect termination, active-set, KKT, discrete-variable, or annotation qualifications rather than a generic mathematical proof.",
            evidence = [NLPDiagnostics.Evidence("BMOPFTools differentiability readiness"; details = [
                "termination_status" => engine_report.termination_status,
                "qualification_count" => length(engine_report.qualifications),
            ])],
            suggested_actions = ["Review BMOPFTools qualifications alongside NLPDiagnostics derivative, active-set, and postmortem findings."],
        ))
    end
    return report
end

_bmopf_key_label(key) = "$(key.kind):$(key.family):$(repr(key.index))"

"""Return a display-only group for an unregistered JuMP variable name.

This intentionally has no physical semantics: it is only a compact way to
show repeated engine construction labels in a registry-coverage finding.
"""
function _bmopf_unregistered_name_group(owner::JuMP.Model, variable::MOI.VariableIndex)
    label = JuMP.name(JuMP.VariableRef(owner, variable))
    isempty(label) && return "(unnamed)"
    return replace(label, r"_\d+(?:_\d+)*$" => "")
end

function _bmopf_registry_variable_families(context)
    result = Dict{Symbol,Vector{MOI.VariableIndex}}()
    for key in BMOPFTools.opf_object_keys(context; kind = :variable)
        object = BMOPFTools.opf_object(context, key)
        object isa JuMP.VariableRef || continue
        push!(get!(result, key.family, MOI.VariableIndex[]), JuMP.index(object))
    end
    for variables in values(result)
        unique!(variables)
        sort!(variables; by = variable -> variable.value)
    end
    return result
end

function _bmopf_family_semantics(family::Symbol)
    label = String(family)
    if family == :u_ibr
        return (:voltage, :magnitude, "V")
    elseif family == :p_ibr || family == :q_ibr
        return (:power, family == :p_ibr ? :active : :reactive, "VA")
    elseif startswith(label, "v")
        return (:voltage, startswith(label, "vi") ? :rectangular_imag : :rectangular_real, "V")
    elseif startswith(label, "c") || startswith(label, "i")
        return (:current, startswith(label, "ci") ? :rectangular_imag : :rectangular_real, "A")
    elseif startswith(label, "tap")
        return (:generic, :tap_ratio, "ratio")
    end
    return (:generic, :native, "unspecified")
end

"""Group direct public BMOPFTools registry variables by their semantic family."""
function _bmopf_component_metadata(context)
    _bmopf_context_model(context)
    metadata = NLPDiagnostics.ComponentMetadata[]
    for family in sort!(collect(keys(_bmopf_registry_variable_families(context))); by = string)
        variables = _bmopf_registry_variable_families(context)[family]
        quantity, _, unit = _bmopf_family_semantics(family)
        push!(metadata, NLPDiagnostics.ComponentMetadata(
            :bmopf_variable_family, string(family);
            variables = variables,
            constraints = NLPDiagnostics.EntityRef[],
            units = Dict(quantity => unit),
            metadata = Dict("source" => "BMOPFTools public OPF registry", "family" => string(family)),
        ))
    end
    return metadata
end

"""Return generic physical coordinate semantics for public BMOPFTools registry variable families."""
function _bmopf_component_coordinate_semantics(context)
    _bmopf_context_model(context)
    semantics = NLPDiagnostics.ComponentCoordinateSemantics[]
    for family in sort!(collect(keys(_bmopf_registry_variable_families(context))); by = string)
        variables = _bmopf_registry_variable_families(context)[family]
        quantity, representation, unit = _bmopf_family_semantics(family)
        push!(semantics, NLPDiagnostics.ComponentCoordinateSemantics(
            :bmopf_variable_family, string(family), variables, quantity, representation,
            Dict("$(quantity)" => unit),
            "BMOPFTools public OPF registry family $(family)",
        ))
    end
    return semantics
end

"""Validate BMOPFTools registry-family component declarations against the staged JuMP model."""
function _bmopf_component_report(context)
    owner = _bmopf_context_model(context)
    owner isa JuMP.Model || throw(ArgumentError("BMOPFTools.opf_model(context) did not return a JuMP.Model"))
    components = _bmopf_component_metadata(context)
    semantics = _bmopf_component_coordinate_semantics(context)
    variables = MOI.get(JuMP.backend(owner), MOI.ListOfVariableIndices())
    report = NLPDiagnostics._component_metadata_findings(components; model_variables = variables)
    semantic_report = NLPDiagnostics._component_coordinate_semantics_findings(
        semantics, variables; components = components,
    )
    append!(report.findings, semantic_report.findings)
    merge!(report.metadata, semantic_report.metadata)
    report.metadata[:bmopf_component_metadata_count] = string(length(components))
    report.metadata[:bmopf_component_coordinate_semantics_count] = string(length(semantics))
    expected_rank_declared = count(component -> !isnothing(component.expected_rank), components)
    report.metadata[:bmopf_component_expected_rank_declared_count] = string(expected_rank_declared)
    report.metadata[:bmopf_component_expected_rank_unavailable_count] =
        string(length(components) - expected_rank_declared)
    report.metadata[:bmopf_component_expected_rank_coverage] = isempty(components) ?
        "unavailable" : string(expected_rank_declared / length(components))
    return report
end

"""Report whether BMOPFTools component metadata can support expected-rank analysis."""
function _bmopf_component_rank_capability_report(context)
    components = _bmopf_component_metadata(context)
    declared = count(component -> !isnothing(component.expected_rank), components)
    unavailable = length(components) - declared
    report = NLPDiagnostics.DiagnosticReport()
    report.metadata[:stage] = "bmopf_component_rank_capability"
    report.metadata[:bmopf_component_metadata_count] = string(length(components))
    report.metadata[:bmopf_component_expected_rank_declared_count] = string(declared)
    report.metadata[:bmopf_component_expected_rank_unavailable_count] = string(unavailable)
    report.metadata[:bmopf_component_expected_rank_coverage] = isempty(components) ?
        "unavailable" : string(declared / length(components))
    if unavailable > 0
        push!(report, NLPDiagnostics.Finding(:bmopf_component_expected_rank_unavailable;
            severity = NLPDiagnostics.SeverityInfo,
            domain = NLPDiagnostics.RepresentationalIssue,
            basis = NLPDiagnostics.StructuralProof,
            confidence = NLPDiagnostics.ConfidenceCertain,
            observation = "$unavailable BMOPFTools component declaration(s) do not provide an expected physical rank.",
            why_it_matters = "Component-rank persistence can repeat observed rank evidence only where a plugin declares the component's expected rank in model coordinates; absent declarations must not be interpreted as zero rank loss or full rank.",
            evidence = [NLPDiagnostics.Evidence("BMOPFTools component-rank capability"; details = [
                "component_count" => length(components),
                "expected_rank_declared_count" => declared,
                "expected_rank_unavailable_count" => unavailable,
                "expected_rank_coverage" => isempty(components) ? "unavailable" : string(declared / length(components)),
                "source" => "BMOPFTools public OPF registry family metadata",
            ])],
            suggested_actions = ["Add plugin-owned expected_rank declarations only when component equations and coordinate scopes are physically justified.", "Use generic Jacobian and structural persistence evidence independently of this capability boundary."],
        ))
    end
    return report
end

"""
    bmopf_opf_registry_report(context) -> DiagnosticReport

Audit BMOPFTools' public semantic OPF-object registry against the owning JuMP
model. Direct `VariableRef` entries are checked for model ownership; derived
expressions registered under variable families are retained as aliases rather
than misclassified as variables. User-added but unregistered JuMP variables are
reported as information, because they can be legitimate model-hook extensions.
"""
function _bmopf_opf_registry_report(context)
    owner = _bmopf_context_model(context)
    owner isa JuMP.Model || throw(ArgumentError("BMOPFTools.opf_model(context) did not return a JuMP.Model"))
    backend = JuMP.backend(owner)
    model_variables = Set(MOI.get(backend, MOI.ListOfVariableIndices()))
    registry_keys = sort!(collect(BMOPFTools.opf_object_keys(context; kind = :variable));
                          by = _bmopf_key_label)
    report = NLPDiagnostics.DiagnosticReport()
    report.metadata[:bmopf_opf_registry_key_count] = string(length(registry_keys))
    registered = Set{MOI.VariableIndex}()
    aliases = Dict{MOI.VariableIndex,Vector{String}}()
    family_counts = Dict{Symbol,Int}()
    derived_count = 0
    foreign = Tuple{Any,JuMP.VariableRef}[]
    for key in registry_keys
        object = BMOPFTools.opf_object(context, key)
        object isa JuMP.VariableRef || (derived_count += 1; continue)
        push!(registered, JuMP.index(object))
        push!(get!(aliases, JuMP.index(object), String[]), _bmopf_key_label(key))
        family_counts[key.family] = get(family_counts, key.family, 0) + 1
        JuMP.owner_model(object) === owner || push!(foreign, (key, object))
    end
    report.metadata[:bmopf_opf_registry_direct_variable_count] = string(length(registered))
    report.metadata[:bmopf_opf_registry_derived_object_count] = string(derived_count)
    report.metadata[:bmopf_opf_registry_family_counts] = join([
        "$(family)=$(family_counts[family])" for family in sort!(collect(keys(family_counts)); by = string)
    ], ",")
    for (key, object) in foreign
        push!(report, NLPDiagnostics.Finding(:bmopf_opf_registry_foreign_variable;
            severity = NLPDiagnostics.SeverityError,
            domain = NLPDiagnostics.RepresentationalIssue,
            basis = NLPDiagnostics.StructuralProof,
            confidence = NLPDiagnostics.ConfidenceCertain,
            observation = "BMOPFTools registry key $(_bmopf_key_label(key)) references a JuMP variable owned by another model.",
            why_it_matters = "A semantic key that points outside the staged OPF cannot be aligned with its MOI derivatives or solver state.",
            evidence = [NLPDiagnostics.Evidence("BMOPFTools registry ownership"; details = ["variable" => JuMP.index(object).value])],
            suggested_actions = ["Rebuild the staged OPF context or re-register the object from its owning model."],
        ))
    end
    aliased = [(variable, labels) for (variable, labels) in aliases if length(labels) > 1]
    report.metadata[:bmopf_opf_registry_variable_alias_count] = string(length(aliased))
    for (variable, labels) in aliased
        push!(report, NLPDiagnostics.Finding(:bmopf_opf_registry_variable_alias;
            severity = NLPDiagnostics.SeverityInfo,
            domain = NLPDiagnostics.RepresentationalIssue,
            basis = NLPDiagnostics.StructuralProof,
            confidence = NLPDiagnostics.ConfidenceCertain,
            observation = "One JuMP variable has $(length(labels)) BMOPFTools semantic registry aliases.",
            why_it_matters = "Aliases can be intentional, but they should be visible when interpreting component ownership or derivative provenance.",
            evidence = [NLPDiagnostics.Evidence("BMOPFTools registry aliases"; details = ["variable" => variable.value, "keys" => join(labels, " | ")])],
            affected = [NLPDiagnostics.EntityRef(:variable, variable.value)],
            suggested_actions = ["Confirm that each semantic alias denotes the same physical coordinate."],
        ))
    end
    unregistered = sort!(collect(setdiff(model_variables, registered)); by = variable -> variable.value)
    report.metadata[:bmopf_opf_registry_unregistered_model_variable_count] = string(length(unregistered))
    if !isempty(unregistered)
        name_groups = Dict{String,Vector{MOI.VariableIndex}}()
        for variable in unregistered
            group = _bmopf_unregistered_name_group(owner, variable)
            push!(get!(name_groups, group, MOI.VariableIndex[]), variable)
        end
        report.metadata[:bmopf_opf_registry_unregistered_name_group_counts] = join([
            "$(group)=$(length(name_groups[group]))" for group in sort!(collect(keys(name_groups)))
        ], ",")
        push!(report, NLPDiagnostics.Finding(:bmopf_opf_registry_unregistered_model_variables;
            severity = NLPDiagnostics.SeverityInfo,
            domain = NLPDiagnostics.RepresentationalIssue,
            basis = NLPDiagnostics.StructuralProof,
            confidence = NLPDiagnostics.ConfidenceCertain,
            observation = "$(length(unregistered)) JuMP variable(s) in the staged OPF have no BMOPFTools semantic registry key.",
            why_it_matters = "This is often legitimate for model-hook extensions, but unregistered native physics variables cannot receive stable component-level interpretation from the public registry.",
            evidence = [NLPDiagnostics.Evidence("BMOPFTools registry coverage"; details = ["unregistered_variable_count" => length(unregistered)])],
            affected = [NLPDiagnostics.EntityRef(:variable, variable.value) for variable in unregistered],
            suggested_actions = ["For custom devices, register stable OpfModelKey entries; otherwise confirm these variables are intentionally private to the formulation."],
        ))
        for group in sort!(collect(keys(name_groups)))
            variables = name_groups[group]
            push!(report, NLPDiagnostics.Finding(:bmopf_opf_registry_unregistered_name_group;
                severity = NLPDiagnostics.SeverityInfo,
                domain = NLPDiagnostics.RepresentationalIssue,
                basis = NLPDiagnostics.StructuralProof,
                confidence = NLPDiagnostics.ConfidenceCertain,
                observation = "$(length(variables)) unregistered staged-model coordinate(s) use JuMP construction label group '$group'.",
                why_it_matters = "This is display-only construction provenance, not a physical classification. It helps distinguish one repeated auxiliary-variable family from scattered custom additions when planning registry coverage.",
                evidence = [NLPDiagnostics.Evidence("Unregistered JuMP construction-label group"; details = [
                    "name_group" => group,
                    "coordinate_count" => length(variables),
                    "variable_indices" => join((string(variable.value) for variable in variables), ","),
                ])],
                affected = [NLPDiagnostics.EntityRef(:variable, variable.value) for variable in variables],
                suggested_actions = ["Use the construction site and public registry API to decide whether this repeated coordinate family should receive stable semantic keys."],
            ))
        end
    end
    return report
end

"""
    bmopf_terminal_port_metadata(context) -> Vector{ComponentPortMetadata}

Declare two direct terminal-voltage ports for every BMOPF bus in a staged IVR
OPF context: one for the real rectangular coordinate and one for the imaginary
coordinate. Each has an identity terminal/mode map. These declarations describe
coordinates only; they do not claim branch equations or expected nullspaces.
"""
function _bmopf_terminal_port_metadata(context)
    _bmopf_context_model(context)
    ports = NLPDiagnostics.ComponentPortMetadata{Float64}[]
    for (bus, terminals) in _bmopf_bus_terminals(context)
        isempty(terminals) && continue
        for component in (:real, :imag)
            variables = _bmopf_terminal_variables(context, bus, terminals, component)
            voltage_base = _bmopf_voltage_base(context, bus)
            metadata = Dict(
                "source" => "BMOPFTools public OPF registry",
                "coordinate_component" => string(component),
            )
            !isnothing(voltage_base) && (metadata["physical_voltage_base_V"] = string(voltage_base))
            push!(ports, NLPDiagnostics.ComponentPortMetadata(
                :bus, bus, _bmopf_port_id(component);
                terminal_labels = terminals,
                mode_labels = terminals,
                variables = variables,
                connection_matrix = Matrix{Float64}(LinearAlgebra.I, length(terminals), length(terminals)),
                metadata = metadata,
            ))
        end
    end
    attachment = _bmopf_attachment_port_declarations(context)
    append!(ports, attachment.ports)
    return ports
end

"""Return explicit identity terminal-to-MOI-variable maps for staged BMOPF bus voltage ports."""
function _bmopf_terminal_port_coordinate_maps(context)
    _bmopf_context_model(context)
    maps = NLPDiagnostics.PortCoordinateMap{Float64}[]
    for (bus, terminals) in _bmopf_bus_terminals(context)
        isempty(terminals) && continue
        for component in (:real, :imag)
            variables = _bmopf_terminal_variables(context, bus, terminals, component)
            push!(maps, NLPDiagnostics.PortCoordinateMap(
                :bus, bus, _bmopf_port_id(component), variables;
                terminal_to_variable = Matrix{Float64}(LinearAlgebra.I, length(terminals), length(terminals)),
                description = "BMOPFTools registered rectangular $(component) bus-terminal voltage variables",
            ))
        end
    end
    attachment = _bmopf_attachment_port_declarations(context)
    append!(maps, attachment.maps)
    return maps
end

"""Return physical coordinate semantics for staged BMOPF rectangular bus-voltage ports."""
function _bmopf_terminal_port_coordinate_semantics(context)
    _bmopf_context_model(context)
    per_unit = !isnothing(BMOPFTools.opf_bases(context))
    unit = per_unit ? "p.u." : "V"
    semantics = NLPDiagnostics.PortCoordinateSemantics[]
    for (bus, terminals) in _bmopf_bus_terminals(context)
        isempty(terminals) && continue
        for component in (:real, :imag)
            voltage_base = _bmopf_voltage_base(context, bus)
            description = "BMOPFTools rectangular $(component) voltage at declared bus terminals"
            if per_unit
                description *= isnothing(voltage_base) ?
                    "; per-unit model coordinate (physical voltage base unavailable)" :
                    "; per-unit model coordinate with physical voltage base $(voltage_base) V"
            end
            push!(semantics, NLPDiagnostics.PortCoordinateSemantics(
                :bus, bus, _bmopf_port_id(component);
                quantity = :voltage,
                representation = _bmopf_representation(component),
                units = Dict("voltage" => unit),
                # Ordered terminal declarations prevent phase-voltage scale one
                # from being assigned to a floating neutral and attach an
                # explicit zero/tolerance only to physical ground references.
                terminal_semantics = _bmopf_voltage_terminal_semantics(
                    context, bus, terminals,
                ),
                description = description,
            ))
        end
    end
    attachment = _bmopf_attachment_port_declarations(context)
    append!(semantics, attachment.semantics)
    return semantics
end

"""Return BMOPFTools component-to-bus terminal attachment maps."""
function _bmopf_terminal_port_connections(context)
    _bmopf_context_model(context)
    return _bmopf_attachment_port_declarations(context).connections
end

"""Return BMOPFTools rectangular terminal-current coordinate ports."""
function _bmopf_terminal_current_port_metadata(context)
    _bmopf_context_model(context)
    return _bmopf_current_port_declarations(context).ports
end

"""Return explicit terminal-current to MOI-variable maps."""
function _bmopf_terminal_current_port_coordinate_maps(context)
    _bmopf_context_model(context)
    return _bmopf_current_port_declarations(context).maps
end

"""Return physical semantics for BMOPFTools terminal-current coordinates."""
function _bmopf_terminal_current_port_coordinate_semantics(context)
    _bmopf_context_model(context)
    return _bmopf_current_port_declarations(context).semantics
end

"""Validate BMOPFTools terminal-current port coverage without physical inference."""
function _bmopf_terminal_current_port_report(context)
    owner = _bmopf_context_model(context)
    owner isa JuMP.Model || throw(ArgumentError("BMOPFTools.opf_model(context) did not return a JuMP.Model"))
    declaration = _bmopf_current_port_declarations(context)
    variables = MOI.get(JuMP.backend(owner), MOI.ListOfVariableIndices())
    report = NLPDiagnostics._component_port_metadata_findings(
        declaration.ports; model_variables = variables,
    )
    for partial in (
        NLPDiagnostics._component_port_coordinate_map_findings(
            declaration.ports, declaration.maps; model_variables = variables,
        ),
        NLPDiagnostics._component_port_coordinate_semantics_findings(
            declaration.ports, declaration.semantics, declaration.maps,
        ),
    )
        append!(report.findings, partial.findings)
        merge!(report.metadata, partial.metadata)
    end
    report.metadata[:bmopf_terminal_current_port_count] = string(length(declaration.ports))
    report.metadata[:bmopf_terminal_current_port_coordinate_map_count] = string(length(declaration.maps))
    report.metadata[:bmopf_terminal_current_port_coordinate_semantics_count] = string(length(declaration.semantics))
    report.metadata[:bmopf_terminal_current_port_skipped_count] = string(length(declaration.skipped))
    if !isempty(declaration.skipped)
        push!(report, NLPDiagnostics.Finding(:bmopf_terminal_current_port_unavailable;
            severity = NLPDiagnostics.SeverityInfo,
            domain = NLPDiagnostics.RepresentationalIssue,
            basis = NLPDiagnostics.StructuralProof,
            confidence = NLPDiagnostics.ConfidenceCertain,
            observation = "$(length(declaration.skipped)) BMOPFTools terminal-current coordinate port(s) could not be mapped to registered variables.",
            why_it_matters = "Current-port coverage is incomplete; no physical conclusion is made about the affected component or its KCL equations.",
            evidence = [NLPDiagnostics.Evidence("BMOPFTools current registry coverage"; details = [
                "skipped_ports" => join(sort!(unique(declaration.skipped)), ","),
            ])],
            suggested_actions = ["Inspect the component family and public current-key registry before interpreting current-port diagnostics."],
        ))
    end
    return report
end

"""Return BMOPFTools expected physical terminal-port null-mode declarations."""
function _bmopf_terminal_port_nullspace_modes(context)
    _bmopf_context_model(context)
    return _bmopf_terminal_port_nullspace_declarations(context).modes
end

"""Return BMOPFTools semantic labels for expected terminal-port null modes."""
function _bmopf_terminal_port_nullspace_mode_semantics(context)
    _bmopf_context_model(context)
    return _bmopf_terminal_port_nullspace_declarations(context).semantics
end

"""Report physical terminal-port mode declarations without treating them as observations."""
function _bmopf_terminal_port_nullspace_mode_report(context)
    declaration = _bmopf_terminal_port_nullspace_declarations(context)
    report = NLPDiagnostics.DiagnosticReport()
    report.metadata[:bmopf_terminal_port_expected_mode_count] = string(length(declaration.modes))
    report.metadata[:bmopf_terminal_port_expected_mode_semantics_count] = string(length(declaration.semantics))
    report.metadata[:bmopf_terminal_port_expected_mode_basis] = "physical expectation"
    semantic_report = NLPDiagnostics._component_port_nullspace_mode_semantic_findings(
        declaration.modes, declaration.semantics,
    )
    append!(report.findings, semantic_report.findings)
    merge!(report.metadata, semantic_report.metadata)
    if !isempty(declaration.modes)
        push!(report, NLPDiagnostics.Finding(:bmopf_terminal_port_physical_mode_declarations;
            severity = NLPDiagnostics.SeverityInfo,
            domain = NLPDiagnostics.PhysicalIssue,
            basis = NLPDiagnostics.PhysicalExpectation,
            confidence = NLPDiagnostics.ConfidenceMedium,
            observation = "BMOPFTools declares $(length(declaration.modes)) expected physical terminal-port null mode(s).",
            why_it_matters = "These directions identify component-level common-mode or delta invariance candidates; they do not prove a network or compiled-model nullspace.",
            evidence = [NLPDiagnostics.Evidence("BMOPFTools terminal-port physical mode declarations"; details = [
                "mode_names" => join((string(something(mode.name, :unnamed)) for mode in declaration.modes), ","),
            ])],
            suggested_actions = ["Pass the declarations through `bmopf_analyze_opf(...; include_port_physical_modes = true)` and compare them with observed Jacobian nullspaces."],
        ))
    end
    return report
end

"""
    _bmopf_expected_mode_tangent_policy(context; variables = :fixed)

Construct a plugin-specific coordinate scope for local expected-nullspace
comparisons. The default retains all variables whose staged domain role is
`FixedVariable`; this records the coordinate scope without releasing bounds,
changing the model, or asserting that the coordinates are physically free.
"""
function _bmopf_expected_mode_tangent_policy(
    context;
    variables = :fixed,
    name::Symbol = :bmopf_fixed_reference_grounding,
    description::AbstractString = "BMOPFTools fixed/reference/grounding coordinates retained for a local tangent comparison",
)
    owner = _bmopf_context_model(context)
    graph = NLPDiagnostics.incidence_graph(
        JuMP.backend(owner); include_variable_domains = true,
    )
    selected = if variables === :fixed
        MOI.VariableIndex[
            record.index for (record, role) in zip(graph.variables, graph.variable_roles)
            if role == NLPDiagnostics.FixedVariable
        ]
    elseif variables isa AbstractVector{<:MOI.VariableIndex}
        collect(variables)
    else
        throw(ArgumentError("variables must be :fixed or a vector of MOI.VariableIndex"))
    end
    isempty(selected) && return nothing
    return NLPDiagnostics.ExpectedNullspaceTangentPolicy(
        name,
        selected;
        description = description,
        metadata = Dict(
            "source" => "BMOPFTools staged OPF variable-domain roles",
            "selection" => variables === :fixed ? "fixed" : "explicit",
        ),
    )
end

"""Return BMOPFTools-derived linear constitutive voltage maps."""
function _bmopf_terminal_constitutive_maps(context)
    _bmopf_context_model(context)
    return _bmopf_build_terminal_constitutive_maps(context)
end

"""Validate BMOPFTools constitutive-map dimensions and finite coefficients."""
function _bmopf_terminal_constitutive_map_report(context)
    maps = _bmopf_build_terminal_constitutive_maps(context)
    report = NLPDiagnostics._component_port_constitutive_map_findings(maps)
    shifted = String[]
    for map in maps
        raw = get(map.metadata, "phase_shift_degrees", "0")
        phase_shift = try
            parse(Float64, raw)
        catch
            0.0
        end
        isfinite(phase_shift) && abs(phase_shift) > sqrt(eps(Float64)) || continue
        push!(shifted, "$(map.component_type):$(map.component_id):$(map.map_id)=$(phase_shift)deg")
    end
    report.metadata[:bmopf_terminal_constitutive_map_phase_shift_count] = string(length(unique(shifted)))
    if !isempty(shifted)
        push!(report, NLPDiagnostics.Finding(:bmopf_terminal_constitutive_map_phase_shift_unrepresented;
            severity = NLPDiagnostics.SeverityWarning,
            domain = NLPDiagnostics.RepresentationalIssue,
            basis = NLPDiagnostics.StructuralProof,
            confidence = NLPDiagnostics.ConfidenceCertain,
            observation = "$(length(unique(shifted))) transformer constitutive map(s) carry a nonzero declared phase shift that is not applied to the separated real/imaginary map coefficients.",
            why_it_matters = "The map remains useful incidence and ratio evidence, but it must not be interpreted as the complete phase-shifted complex transformer equation.",
            evidence = [NLPDiagnostics.Evidence("BMOPFTools transformer phase-shift metadata"; details = [
                "maps" => join(sort!(unique(shifted)), ","),
            ])],
            suggested_actions = ["Use the declared vector-group and phase-shift metadata when assembling a complex constitutive map, or treat the current map as a zero-phase structural approximation."],
        ))
    end
    return report
end

"""Return phase-aware complex (real block) transformer constitutive maps."""
function _bmopf_terminal_complex_constitutive_maps(context)
    _bmopf_context_model(context)
    return _bmopf_build_terminal_complex_constitutive_maps(context)
end

"""Validate phase-aware complex transformer constitutive maps."""
function _bmopf_terminal_complex_constitutive_map_report(context)
    maps = _bmopf_build_terminal_complex_constitutive_maps(context)
    report = NLPDiagnostics._component_port_constitutive_map_findings(maps)
    report.metadata[:bmopf_terminal_complex_constitutive_map_count] = string(length(maps))
    report.metadata[:bmopf_terminal_complex_constitutive_map_phase_aware] = "true"
    return report
end

"""Build a real-block passive-network current map from BMOPFTools' public Ybus."""
function _bmopf_build_passive_network_current_maps(context; basis::Symbol = :si)
    basis in (:si, :model, :pu) || throw(ArgumentError("basis must be :si, :model, or :pu"))
    requested_model_basis = basis in (:model, :pu)
    network = BMOPFTools.opf_network(context)
    ybus = try
        BMOPFTools.ybus_passive(network)
    catch
        return NLPDiagnostics.PortConstitutiveMap{Float64}[]
    end
    n = length(ybus.nodes)
    n > 0 || return NLPDiagnostics.PortConstitutiveMap{Float64}[]
    G = real.(Matrix(ybus.Y))
    B = imag.(Matrix(ybus.Y))
    voltage_bases = Float64[]
    current_bases = Float64[]
    if requested_model_basis
        for node in ybus.nodes
            voltage_base = _bmopf_voltage_base(context, string(node[1]))
            current_base = _bmopf_current_base(context, string(node[1]))
            (voltage_base isa Real && isfinite(voltage_base) && voltage_base > 0 &&
             current_base isa Real && isfinite(current_base) && current_base > 0) ||
                return NLPDiagnostics.PortConstitutiveMap{Float64}[]
            push!(voltage_bases, Float64(voltage_base))
            push!(current_bases, Float64(current_base))
        end
        scale = [voltage_bases[column] / current_bases[row]
                 for row in eachindex(current_bases), column in eachindex(voltage_bases)]
        G .*= scale
        B .*= scale
    end
    matrix = zeros(Float64, 2n, 2n)
    matrix[1:n, 1:n] .= G
    matrix[1:n, n+1:2n] .= -B
    matrix[n+1:2n, 1:n] .= B
    matrix[n+1:2n, n+1:2n] .= G
    labels = [
        ["$(node[1])/$(node[2])" for node in ybus.nodes],
        ["$(node[1])/$(node[2])" for node in ybus.nodes],
    ]
    return [NLPDiagnostics.PortConstitutiveMap(
        :network, "passive_ybus", requested_model_basis ?
            "passive_current_from_voltage_model" : "passive_current_from_voltage",
        ["voltage_real", "voltage_imag"], labels, matrix;
        equation_labels = vcat(
            ["current_real/$(node[1])/$(node[2])" for node in ybus.nodes],
            ["current_imag/$(node[1])/$(node[2])" for node in ybus.nodes],
        ),
        metadata = Dict(
            "source" => "BMOPFTools.ybus_passive",
            "map_role" => "passive_network_current",
            "quantity" => "current_from_voltage",
            "units" => requested_model_basis ? "p.u._current_from_p.u._voltage" : "A_from_V_SI",
            "node_count" => string(n),
            "nonzero_count" => string(SparseArrays.nnz(ybus.Y)),
            "coordinate_basis" => requested_model_basis ? "public per-unit bases" : "SI voltage/current",
            "voltage_base_count" => string(length(voltage_bases)),
            "current_base_count" => string(length(current_bases)),
        ),
    )]
end

"""Return the passive-network current-from-voltage map, when Ybus is available."""
function _bmopf_passive_network_current_maps(context; basis::Symbol = :si)
    _bmopf_context_model(context)
    return _bmopf_build_passive_network_current_maps(context; basis = basis)
end

"""Validate passive-network current maps and report public-Ybus coverage limits."""
function _bmopf_passive_network_current_map_report(context; basis::Symbol = :si)
    basis in (:si, :model, :pu) || throw(ArgumentError("basis must be :si, :model, or :pu"))
    requested_model_basis = basis in (:model, :pu)
    maps = _bmopf_build_passive_network_current_maps(context; basis = basis)
    report = NLPDiagnostics._component_port_constitutive_map_findings(maps)
    report.metadata[:bmopf_passive_network_current_map_count] = string(length(maps))
    report.metadata[:bmopf_passive_network_current_map_basis] = "BMOPFTools.ybus_passive"
    if !isempty(maps)
        metadata = first(maps).metadata
        report.metadata[:bmopf_passive_network_node_count] = get(metadata, "node_count", "0")
        report.metadata[:bmopf_passive_network_nonzero_count] = get(metadata, "nonzero_count", "0")
        if !requested_model_basis && !isnothing(BMOPFTools.opf_bases(context))
            push!(report, NLPDiagnostics.Finding(:bmopf_passive_network_map_si_units_on_pu_model;
                severity = NLPDiagnostics.SeverityWarning,
                domain = NLPDiagnostics.RepresentationalIssue,
                basis = NLPDiagnostics.StructuralProof,
                confidence = NLPDiagnostics.ConfidenceCertain,
                observation = "The passive Ybus map is expressed in SI A/V while the staged model declares per-unit bases.",
                why_it_matters = "The map remains valid as physical network evidence but cannot be inserted into p.u. model equations without explicit base conversion.",
                evidence = [NLPDiagnostics.Evidence("BMOPFTools Ybus units"; details = [
                    "map_units" => "A_from_V_SI",
                    "model_basis" => "per-unit",
                ])],
                suggested_actions = ["Apply bus/current base conversion before comparing this map with p.u. Jacobian coefficients."],
            ))
        end
    elseif requested_model_basis
        push!(report, NLPDiagnostics.Finding(:bmopf_passive_network_model_basis_unavailable;
            severity = NLPDiagnostics.SeverityWarning,
            domain = NLPDiagnostics.RepresentationalIssue,
            basis = NLPDiagnostics.StructuralProof,
            confidence = NLPDiagnostics.ConfidenceCertain,
            observation = "A model-basis passive Ybus map could not be assembled because one or more public bus voltage/current bases are missing or invalid.",
            why_it_matters = "The SI passive map remains available, but p.u. Jacobian comparisons would be dimensionally ambiguous without explicit bases.",
            suggested_actions = ["Declare finite positive public voltage and current bases for every Ybus node, or request basis=:si and retain the unit conversion boundary."],
        ))
    else
        push!(report, NLPDiagnostics.Finding(:bmopf_passive_network_map_unavailable;
            severity = NLPDiagnostics.SeverityInfo,
            domain = NLPDiagnostics.RepresentationalIssue,
            basis = NLPDiagnostics.StructuralProof,
            confidence = NLPDiagnostics.ConfidenceCertain,
            observation = "BMOPFTools did not provide a nonempty passive Ybus map for this staged context.",
            why_it_matters = "No passive current-from-voltage conclusion is available; nonlinear device current laws remain outside this generic map.",
            suggested_actions = ["Inspect the public network schema and model lifecycle before interpreting missing passive current evidence."],
        ))
    end
    return report
end

function _bmopf_current_law_fingerprint(component_type::Symbol, component_id::String,
                                        record::AbstractDict, terminals::Vector{String};
                                        control_profile = nothing)
    metadata = Dict{String,String}(
        "source" => "BMOPFTools public network schema",
        "configuration" => uppercase(string(get(record, "configuration", "unknown"))),
    )
    bus = get(record, "bus", nothing)
    bus !== nothing && (metadata["bus"] = string(bus))
    if component_type == :load
        model = lowercase(string(get(record, "model", "constant_power")))
        known = model in ("constant_power", "constant_current", "constant_impedance", "zip", "exponential")
        family = known ? Symbol(model) : :unknown_load_model
        differentiability = model in ("constant_current", "constant_impedance") ? :smooth :
            model == "constant_power" ? :smooth_away_from_zero :
            model in ("zip", "exponential") ? :model_dependent : :unknown
        singularity = model == "constant_power" ? :zero_voltage :
            model in ("zip", "exponential") ? :operating_point_dependent : :none
        metadata["model"] = model
        return NLPDiagnostics.CurrentLawFingerprint(
            component_type, component_id, family, terminals,
            differentiability, singularity, metadata,
        )
    elseif component_type == :generator
        metadata["dispatch_law"] = "bilinear_power_from_voltage_current"
        metadata["configuration"] = uppercase(string(get(record, "configuration", "WYE")))
        return NLPDiagnostics.CurrentLawFingerprint(
            component_type, component_id, :dispatch_power, terminals,
            :smooth_away_from_zero, :zero_voltage, metadata,
        )
    elseif component_type == :ibr
        topology = lowercase(string(get(record, "inverter_topology_type",
                                      get(record, "topology", "unknown"))))
        control = lowercase(string(get(record, "control_mode", get(record, "mode", "unknown"))))
        metadata["inverter_topology_type"] = topology
        metadata["control_mode"] = control
        profile_id = get(record, "control_profile", nothing)
        profile_id isa AbstractString && (metadata["control_profile"] = string(profile_id))
        if control_profile isa AbstractDict
            pf = get(control_profile, "power_factor", nothing)
            vv = get(control_profile, "volt_var", nothing)
            vw = get(control_profile, "volt_watt", nothing)
            sharing = get(control_profile, "power_sharing", nothing)
            if pf isa AbstractDict && get(pf, "pf", nothing) isa Real &&
               abs(Float64(get(pf, "pf", 0.0))) > 1.0e-9
                metadata["control_mode"] = "constant_power_factor"
                metadata["equation"] = "sign(pf)*Q + tan(acos(abs(pf)))*P = 0"
                metadata["power_factor"] = string(get(pf, "pf", 0.0))
                return NLPDiagnostics.CurrentLawFingerprint(
                    component_type, component_id, :constant_power_factor, terminals,
                    :smooth_away_from_zero, :zero_voltage, metadata,
                )
            elseif vv isa AbstractDict || vw isa AbstractDict
                metadata["control_mode"] = "voltage_droop"
                metadata["equation"] = "Q=fVV(|U|), P<=fVW(|U|)"
                vv isa AbstractDict && (metadata["volt_var_breakpoint_count"] =
                    string(length(get(vv, "breakpoints", Any[]))))
                vw isa AbstractDict && (metadata["volt_watt_breakpoint_count"] =
                    string(length(get(vw, "breakpoints", Any[]))))
                return NLPDiagnostics.CurrentLawFingerprint(
                    component_type, component_id, :voltage_droop, terminals,
                    :piecewise_smoothed, :operating_point_dependent, metadata,
                )
            elseif sharing isa AbstractDict
                metadata["control_mode"] = "power_sharing"
                metadata["equation"] = "plugin_owned_power_sharing"
                return NLPDiagnostics.CurrentLawFingerprint(
                    component_type, component_id, :power_sharing, terminals,
                    :model_dependent, :operating_point_dependent, metadata,
                )
            end
        end
        metadata["equation"] = "bilinear_power_from_voltage_current"
        return NLPDiagnostics.CurrentLawFingerprint(
            component_type, component_id, :ibr_box_dispatch, terminals,
            :smooth_away_from_zero, :zero_voltage, metadata,
        )
    elseif component_type in (:shunt, :capacitor)
        metadata["law"] = "linear_admittance"
        return NLPDiagnostics.CurrentLawFingerprint(
            component_type, component_id, :linear_admittance, terminals,
            :smooth, :none, metadata,
        )
    elseif component_type == :voltage_source
        metadata["law"] = "ideal_voltage_boundary"
        return NLPDiagnostics.CurrentLawFingerprint(
            component_type, component_id, :ideal_voltage_source, terminals,
            :unknown, :boundary, metadata,
        )
    end
    return NLPDiagnostics.CurrentLawFingerprint(
        component_type, component_id, :unknown, terminals,
        :unknown, :unknown, metadata,
    )
end

"""Return static current-law fingerprints from public BMOPFTools metadata."""
function _bmopf_current_law_fingerprints(context)
    network = BMOPFTools.opf_network(context)
    profiles = get(network, "control_profile", Dict())
    fingerprints = NLPDiagnostics.CurrentLawFingerprint[]
    for (family, component_type) in _BMOPF_ATTACHMENT_FAMILIES
        table = get(network, family, Dict())
        table isa AbstractDict || continue
        for (identifier, record) in sort!(collect(table); by = entry -> string(first(entry)))
            record isa AbstractDict || continue
            endpoint = _bmopf_attachment_endpoints(record)
            terminals = isnothing(endpoint) ? String[] : endpoint[2]
            control_profile = if component_type == :ibr
                profile_id = get(record, "control_profile", nothing)
                profile_id isa AbstractString ? get(profiles, profile_id, nothing) : nothing
            else
                nothing
            end
            push!(fingerprints, _bmopf_current_law_fingerprint(
                component_type, string(identifier), record, terminals;
                control_profile,
            ))
        end
    end
    return fingerprints
end

"""Report static current-law domains and derivative/singularity hazards."""
function _bmopf_current_law_report(context)
    fingerprints = _bmopf_current_law_fingerprints(context)
    report = NLPDiagnostics.DiagnosticReport()
    report.metadata[:bmopf_current_law_fingerprint_count] = string(length(fingerprints))
    family_counts = Dict{String,Int}()
    for item in fingerprints
        key = string(item.law_family)
        family_counts[key] = get(family_counts, key, 0) + 1
        if item.singularity_risk == :zero_voltage
            push!(report, NLPDiagnostics.Finding(:bmopf_current_law_zero_voltage_singularity;
                severity = NLPDiagnostics.SeverityWarning,
                domain = NLPDiagnostics.MathematicalIssue,
                basis = NLPDiagnostics.StructuralProof,
                confidence = NLPDiagnostics.ConfidenceCertain,
                observation = "$(item.component_type) $(item.component_id) uses a power/current law whose current representation is singular or undefined at zero terminal voltage.",
                why_it_matters = "A zero-voltage initialization or iterate can create undefined current and derivative values even when the network equations are otherwise structurally valid.",
                evidence = [NLPDiagnostics.Evidence("BMOPFTools current-law fingerprint"; details = [
                    "component" => "$(item.component_type):$(item.component_id)",
                    "law_family" => string(item.law_family),
                    "terminal_count" => string(length(item.terminal_labels)),
                ])],
                suggested_actions = ["Use a physically nonzero initialization and enforce a defensible voltage floor before derivative-based analysis."],
            ))
        elseif item.singularity_risk == :operating_point_dependent
            push!(report, NLPDiagnostics.Finding(:bmopf_current_law_operating_point_dependent;
                severity = NLPDiagnostics.SeverityInfo,
                domain = NLPDiagnostics.NumericalIssue,
                basis = NLPDiagnostics.StructuralProof,
                confidence = NLPDiagnostics.ConfidenceMedium,
                observation = "$(item.component_type) $(item.component_id) has a voltage-dependent current law whose derivative conditioning depends on the operating point.",
                why_it_matters = "Low-voltage or extreme-voltage iterates can change the local derivative scale and undermine comparisons across snapshots.",
                evidence = [NLPDiagnostics.Evidence("BMOPFTools voltage-dependent law"; details = [
                    "law_family" => string(item.law_family),
                ])],
                suggested_actions = ["Profile the derivative at representative operating points and retain the model's voltage-domain assumptions."],
            ))
        end
        if item.differentiability == :unknown
            push!(report, NLPDiagnostics.Finding(:bmopf_current_law_differentiability_unknown;
                severity = NLPDiagnostics.SeverityInfo,
                domain = NLPDiagnostics.RepresentationalIssue,
                basis = NLPDiagnostics.StructuralProof,
                confidence = NLPDiagnostics.ConfidenceCertain,
                observation = "The public schema identifies $(item.component_type) $(item.component_id), but does not expose enough information to certify differentiability of its current law.",
                why_it_matters = "Derivative-based diagnostics must not assume a smooth current law when control or topology details are plugin-owned.",
                evidence = [NLPDiagnostics.Evidence("BMOPFTools current-law metadata"; details = [
                    "law_family" => string(item.law_family),
                    "metadata" => join(("$(key)=$(value)" for (key, value) in sort!(collect(item.metadata); by = first)), ","),
                ])],
                suggested_actions = ["Use BMOPFTools' differentiability report or a domain-specific extension before interpreting current-Jacobian singularity."],
            ))
        end
    end
    report.metadata[:bmopf_current_law_family_counts] = join(
        ("$(key)=$(family_counts[key])" for key in sort!(collect(keys(family_counts)))), ",",
    )
    return report
end

function _bmopf_current_law_coefficient(record::AbstractDict, key::String, index::Int, count::Int)
    value = get(record, key, nothing)
    value === nothing && return 0.0
    if value isa AbstractVector
        length(value) == 1 && return Float64(value[1])
        length(value) == count && return Float64(value[index])
        return nothing
    end
    return Float64(value)
end

function _bmopf_current_law_voltage_pairs(context, record::AbstractDict;
                                          component_type::Symbol = :load)
    terminals = String.(get(record, "terminal_map", String[]))
    isempty(terminals) && return Tuple{String,Union{Nothing,String}}[]
    configuration = uppercase(string(get(record, "configuration", "WYE")))
    if component_type == :ibr
        topology = uppercase(string(get(record, "topology", "FOUR_LEG")))
        if topology == "SINGLE_PHASE" && length(terminals) >= 2
            return [(terminals[1], terminals[2])]
        elseif topology == "THREE_LEG"
            return [(terminals[index], terminals[mod1(index + 1, length(terminals))])
                    for index in eachindex(terminals)]
        end
        configuration = "WYE"
    end
    neutral_labels = try
        Set(string.(BMOPFTools.opf_neutral_labels(context)))
    catch
        Set{String}()
    end
    if configuration == "DELTA"
        return [(terminals[index], terminals[mod1(index + 1, length(terminals))])
                for index in eachindex(terminals)]
    elseif configuration == "SINGLE_PHASE" && length(terminals) == 2
        return [(terminals[1], terminals[2])]
    end
    phase_positions = [index for (index, terminal) in enumerate(terminals)
                       if !(terminal in neutral_labels)]
    isempty(phase_positions) && (phase_positions = collect(eachindex(terminals)))
    neutral_position = findfirst(terminal -> terminal in neutral_labels, terminals)
    neutral = isnothing(neutral_position) ? nothing : terminals[neutral_position]
    return [(terminals[index], neutral) for index in phase_positions]
end

function _bmopf_current_law_power(
    record::AbstractDict,
    index::Int,
    voltage_magnitude::Float64;
    voltage_base::Float64 = 1.0,
)
    p_nom = get(record, "p_nom", nothing)
    q_nom = get(record, "q_nom", nothing)
    p_nom isa AbstractVector || return nothing
    index <= length(p_nom) || return nothing
    q_value = q_nom isa AbstractVector ? (index <= length(q_nom) ? q_nom[index] : 0.0) : q_nom
    q_value isa Real || return nothing
    p_value = p_nom[index]
    p_value isa Real || return nothing
    model = lowercase(string(get(record, "model", "constant_power")))
    if model == "constant_power"
        return ComplexF64(p_value, q_value)
    end
    vnom = get(record, "v_nom", nothing)
    vnom_value = if vnom isa AbstractVector
        index <= length(vnom) ? Float64(vnom[index]) : NaN
    elseif vnom isa Real
        Float64(vnom)
    else
        NaN
    end
    isfinite(voltage_base) && voltage_base > 0.0 || return nothing
    isfinite(vnom_value) && vnom_value > 0.0 || return nothing
    # BMOPFTools stores v_nom in SI volts while staged IVR coordinates are
    # normally p.u.; keep the law evaluation in the same coordinates as the
    # supplied operating point.
    vnom_value /= voltage_base
    ratio = voltage_magnitude / vnom_value
    if model == "constant_impedance"
        return ComplexF64(p_value, q_value) * ratio^2
    elseif model == "constant_current"
        return ComplexF64(p_value, q_value) * ratio
    elseif model == "zip"
        αz = _bmopf_current_law_coefficient(record, "alpha_z", index, length(p_nom))
        αi = _bmopf_current_law_coefficient(record, "alpha_i", index, length(p_nom))
        αp = _bmopf_current_law_coefficient(record, "alpha_p", index, length(p_nom))
        βz = _bmopf_current_law_coefficient(record, "beta_z", index, length(p_nom))
        βi = _bmopf_current_law_coefficient(record, "beta_i", index, length(p_nom))
        βp = _bmopf_current_law_coefficient(record, "beta_p", index, length(p_nom))
        any(isnothing, (αz, αi, αp, βz, βi, βp)) && return nothing
        no_coefficients = all(get(record, key, nothing) === nothing for key in
                              ("alpha_z", "alpha_i", "alpha_p", "beta_z", "beta_i", "beta_p"))
        no_coefficients && (αp = 1.0; βp = 1.0)
        return ComplexF64(
            p_value * (αz * ratio^2 + αi * ratio + αp),
            q_value * (βz * ratio^2 + βi * ratio + βp),
        )
    elseif model == "exponential"
        γp = _bmopf_current_law_coefficient(record, "gamma_p", index, length(p_nom))
        γq = _bmopf_current_law_coefficient(record, "gamma_q", index, length(p_nom))
        any(isnothing, (γp, γq)) && return nothing
        return ComplexF64(p_value * ratio^γp, q_value * ratio^γq)
    end
    return nothing
end

function _bmopf_current_law_current(
    record::AbstractDict,
    index::Int,
    voltage::ComplexF64;
    voltage_base::Float64 = 1.0,
)
    magnitude = abs(voltage)
    power = _bmopf_current_law_power(record, index, magnitude; voltage_base)
    power === nothing && return nothing
    iszero(voltage) && return nothing
    return conj(power) / conj(voltage)
end

function _bmopf_current_law_bus_voltage(context, source, bus::String, terminal::String;
                                        result_units::Symbol, field_units::AbstractDict,
                                        point_positions::AbstractDict)
    if source isa NLPDiagnostics.EvaluationPoint
        point = source
        real_key = BMOPFTools.opf_bus_voltage_key(bus, terminal)
        imag_key = BMOPFTools.opf_bus_voltage_key(bus, terminal; component = :imag)
        real_object = try BMOPFTools.opf_object(context, real_key) catch; nothing end
        imag_object = try BMOPFTools.opf_object(context, imag_key) catch; nothing end
        real_object isa JuMP.VariableRef && imag_object isa JuMP.VariableRef || return nothing
        real_position = get(point_positions, JuMP.index(real_object), nothing)
        imag_position = get(point_positions, JuMP.index(imag_object), nothing)
        # Some MOI-backed JuMP models materialize equivalent variable-index
        # objects during extension loading.  Fall back to value equality so
        # point provenance remains robust across those wrappers.
        isnothing(real_position) && (real_position = findfirst(
            variable -> variable == JuMP.index(real_object), point.variables,
        ))
        isnothing(imag_position) && (imag_position = findfirst(
            variable -> variable == JuMP.index(imag_object), point.variables,
        ))
        if isnothing(real_position) || isnothing(imag_position)
            return nothing
        end
        return ComplexF64(point.values[real_position], point.values[imag_position])
    end
    source isa AbstractDict || return nothing
    terminals = get(get(source, "bus", Dict()), bus, nothing)
    terminals isa AbstractDict || return nothing
    entry = get(terminals, terminal, nothing)
    entry isa AbstractDict || return nothing
    real = get(entry, "vr", nothing)
    imag = get(entry, "vi", nothing)
    real isa Real && imag isa Real && isfinite(real) && isfinite(imag) || return nothing
    policy = _bmopf_result_field_units(result_units, field_units)
    scale = policy[:bus_voltage] == :si ? _bmopf_voltage_base(context, bus) : 1.0
    isnothing(scale) && return nothing
    return ComplexF64(Float64(real) / scale, Float64(imag) / scale)
end

function _bmopf_current_law_component_current(
    context,
    source,
    component_type::Symbol,
    component_id::String,
    conductor::Int,
    terminal::String;
    result_units::Symbol,
    field_units::AbstractDict,
    point_positions::AbstractDict,
    bus::String,
)
    real_key = if component_type == :generator
        BMOPFTools.opf_generator_current_key(component_id, conductor)
    elseif component_type == :ibr
        BMOPFTools.opf_ibr_current_key(component_id, conductor)
    else
        return nothing
    end
    imag_key = if component_type == :generator
        BMOPFTools.opf_generator_current_key(component_id, conductor; component = :imag)
    else
        BMOPFTools.opf_ibr_current_key(component_id, conductor; component = :imag)
    end
    values = if source isa NLPDiagnostics.EvaluationPoint
        real_object = try BMOPFTools.opf_object(context, real_key) catch; nothing end
        imag_object = try BMOPFTools.opf_object(context, imag_key) catch; nothing end
        real_object isa JuMP.VariableRef && imag_object isa JuMP.VariableRef || return nothing
        real_position = get(point_positions, JuMP.index(real_object), nothing)
        imag_position = get(point_positions, JuMP.index(imag_object), nothing)
        isnothing(real_position) || isnothing(imag_position) ? nothing :
            (source.values[real_position], source.values[imag_position])
    elseif source isa AbstractDict
        section = component_type == :generator ? "generator" : "ibr"
        component_result = get(get(source, section, Dict()), component_id, nothing)
        component_result isa AbstractDict || return nothing
        entry = get(component_result, terminal, nothing)
        entry isa AbstractDict || return nothing
        real_field, imag_field = component_type == :generator ? ("crg", "cig") : ("cri", "cii")
        (get(entry, real_field, nothing), get(entry, imag_field, nothing))
    else
        return nothing
    end
    values isa Tuple && length(values) == 2 || return nothing
    real, imag = values
    real isa Real && imag isa Real && isfinite(real) && isfinite(imag) || return nothing
    if source isa AbstractDict
        policy = _bmopf_result_field_units(result_units, field_units)
        family = component_type == :generator ? :generator_current : :ibr_current
        scale = policy[family] == :si ? _bmopf_current_base(context, bus) : 1.0
        isnothing(scale) && return nothing
        return ComplexF64(Float64(real) / scale, Float64(imag) / scale)
    end
    return ComplexF64(Float64(real), Float64(imag))
end

function _bmopf_current_law_saved_power(context, source, component_type::Symbol,
                                        component_id::String, terminal::String;
                                        result_units::Symbol,
                                        field_units::AbstractDict)
    source isa AbstractDict || return nothing
    section = component_type == :generator ? "generator" : "ibr"
    component_result = get(get(source, section, Dict()), component_id, nothing)
    component_result isa AbstractDict || return nothing
    entry = get(component_result, terminal, nothing)
    entry isa AbstractDict || return nothing
    p = get(entry, "pg", nothing)
    q = get(entry, "qg", nothing)
    p isa Real && q isa Real && isfinite(p) && isfinite(q) || return nothing
    policy = _bmopf_result_field_units(result_units, field_units)
    family = component_type == :generator ? :generator_power : :ibr_power
    scale = policy[family] == :si ? _bmopf_power_base(context) : 1.0
    isnothing(scale) && return nothing
    return ComplexF64(Float64(p) / scale, Float64(q) / scale)
end

function _bmopf_current_law_bilinear_power(voltage::ComplexF64, current::ComplexF64)
    return ComplexF64(
        real(voltage) * real(current) + imag(voltage) * imag(current),
        imag(voltage) * real(current) - real(voltage) * imag(current),
    )
end

function _bmopf_current_law_bilinear_jacobian(voltage::ComplexF64, current::ComplexF64)
    # [P,Q] as a function of [Vᵣ,Vᵢ,Iᵣ,Iᵢ], matching BMOPFTools' native
    # bilinear equations for generators and IBRs.
    return Float64[
        real(current) imag(current) real(voltage) imag(voltage);
        -imag(current) real(current) imag(voltage) -real(voltage)
    ]
end

"""Return the public control-profile object referenced by an IBR record."""
function _bmopf_current_law_control_profile(context, record::AbstractDict)
    profile_id = get(record, "control_profile", nothing)
    profile_id isa AbstractString || return nothing
    network = BMOPFTools.opf_network(context)
    profiles = get(network, "control_profile", Dict())
    profiles isa AbstractDict || return nothing
    profile = get(profiles, profile_id, nothing)
    return profile isa AbstractDict ? profile : nothing
end

_bmopf_curve_log1pexp(x::Float64) = x > 0.0 ? x + log1p(exp(-x)) : log1p(exp(x))
_bmopf_curve_logistic(x::Float64) = x >= 0.0 ? 1.0 / (1.0 + exp(-x)) :
    (e = exp(x); e / (1.0 + e))

const _BMOPF_CURVE_RELATIVE_EPSILON_CACHE = IdDict{Any,Float64}()

"""Read the public relative smooth-ReLU setting, with an explicit fallback."""
function _bmopf_curve_relative_epsilon(context)
    cached = get(_BMOPF_CURVE_RELATIVE_EPSILON_CACHE, context, nothing)
    cached isa Float64 && return cached
    value = 2.0e-3
    try
        provenance = BMOPFTools.opf_research_provenance(context)
        smoothing = get(provenance, "smoothing", Dict())
        candidate = get(smoothing, "volt_var_watt_relative_epsilon", value)
        candidate isa Real && isfinite(candidate) && candidate > 0.0 &&
            (value = Float64(candidate))
    catch
        # A staged test context or an older BMOPFTools release may not expose
        # provenance. Preserve coverage with the documented BMOPFTools default.
    end
    _BMOPF_CURVE_RELATIVE_EPSILON_CACHE[context] = value
    return value
end

"""Build the public ReLU-sum representation used by BMOPFTools droop curves."""
function _bmopf_curve_triples(xs::Vector{Float64}, ys::Vector{Float64})
    length(xs) == length(ys) && length(xs) >= 2 || return nothing
    all(isfinite, xs) && all(isfinite, ys) || return nothing
    all(xs[i + 1] > xs[i] for i in 1:(length(xs) - 1)) || return nothing
    triples = Tuple{Float64,Float64}[]
    for i in 1:(length(xs) - 1)
        slope = (ys[i + 1] - ys[i]) / (xs[i + 1] - xs[i])
        isfinite(slope) || return nothing
        slope == 0.0 && continue
        push!(triples, (slope, xs[i]))
        push!(triples, (-slope, xs[i + 1]))
    end
    return (baseline = ys[1], triples = triples)
end

"""Resolve the exact monitored voltage used by a public IBR curve profile."""
function _bmopf_controller_monitored_voltage(
    context,
    source,
    record::AbstractDict,
    curve::AbstractDict,
    index::Int,
    point_positions::AbstractDict,
    result_units::Symbol,
    field_units::AbstractDict,
)
    bus = string(get(record, "bus", ""))
    pairs = _bmopf_current_law_voltage_pairs(context, record; component_type = :ibr)
    isempty(pairs) && return nothing
    phase_terms = String[first(pair) for pair in pairs]
    neutral_labels = try
        Set(string.(BMOPFTools.opf_neutral_labels(context)))
    catch
        Set{String}()
    end
    neutral = findfirst(terminal -> terminal in neutral_labels,
                        String.(get(record, "terminal_map", String[])))
    neutral_terminal = isnothing(neutral) ? nothing :
        String(get(record, "terminal_map", String[])[neutral])
    vref = uppercase(string(get(curve, "voltage_reference", "PN_PER_PHASE")))
    quantity = startswith(vref, "PG") ? :PG : startswith(vref, "PP") ? :PP : :PN
    averaged = endswith(vref, "AVERAGED")
    # The legacy record-level field overrides the curve suffix exactly as in
    # BMOPFTools' public builder.
    if haskey(record, "voltage_aggregation")
        averaged = uppercase(string(get(record, "voltage_aggregation", "PER_PHASE"))) == "AVERAGE"
    end
    topology = uppercase(string(get(record, "topology", "FOUR_LEG")))
    function magnitude_for(phase_index::Int)
        phase_index in eachindex(phase_terms) || return nothing
        positive_terminal = phase_terms[phase_index]
        negative_terminal = if topology == "SINGLE_PHASE" && quantity != :PG
            pairs[phase_index][2]
        elseif quantity == :PN
            neutral_terminal
        elseif quantity == :PP && length(phase_terms) >= 2
            phase_terms[mod1(phase_index + 1, length(phase_terms))]
        else
            nothing
        end
        positive = _bmopf_current_law_bus_voltage(
            context, source, bus, positive_terminal;
            result_units, field_units, point_positions,
        )
        positive === nothing && return nothing
        negative = isnothing(negative_terminal) ? 0.0im :
            _bmopf_current_law_bus_voltage(
                context, source, bus, negative_terminal;
                result_units, field_units, point_positions,
            )
        isnothing(negative) && return nothing
        return abs(positive - negative)
    end
    magnitudes = [magnitude_for(phase_index) for phase_index in eachindex(phase_terms)]
    any(isnothing, magnitudes) && return nothing
    values = Float64[magnitudes...]
    value = averaged ? sum(values) / length(values) : values[clamp(index, 1, length(values))]
    return (value = value, quantity = quantity, averaged = averaged,
            topology = topology, phase_count = length(phase_terms))
end

"""Fingerprint one Volt-var/Volt-watt curve at a local terminal magnitude.

The evaluator mirrors BMOPFTools' public ReLU-sum semantics. It intentionally
reports normalized curve output (before the per-device P/Q base) and the local
derivative with respect to model voltage units. This is evidence about the
declared controller profile, not a claim that a proxy terminal magnitude is the
exact monitored quantity for averaged or phase-to-phase profiles.
"""
function _bmopf_controller_curve_metadata(context, record::AbstractDict, index::Int,
                                          magnitude::Float64, fingerprint,
                                          voltage_base::Float64;
                                          monitored_voltage = nothing,
                                          curve_family::Union{Nothing,String} = nothing)
    fingerprint.component_type == :ibr || return Dict{String,String}()
    profile = _bmopf_current_law_control_profile(context, record)
    profile isa AbstractDict || return Dict{String,String}()
    family = if curve_family !== nothing
        curve_family
    elseif get(profile, "volt_var", nothing) isa AbstractDict
        "volt_var"
    elseif get(profile, "volt_watt", nothing) isa AbstractDict
        "volt_watt"
    else
        return Dict{String,String}()
    end
    curve = get(profile, family, nothing)
    curve isa AbstractDict || return Dict{String,String}()
    metadata = Dict{String,String}(
        "controller_curve_family" => family,
        "controller_curve_voltage_reference" => string(get(curve, "voltage_reference", "PN_PER_PHASE")),
        "controller_curve_voltage_semantics" => isnothing(monitored_voltage) ?
            "terminal_pair_magnitude_proxy" : "exact_public_monitored_voltage",
        "controller_curve_profile" => string(get(record, "control_profile", "")),
    )
    if !isnothing(monitored_voltage)
        metadata["controller_curve_monitored_voltage"] = string(monitored_voltage.value)
        metadata["controller_curve_monitored_voltage_quantity"] = string(monitored_voltage.quantity)
        metadata["controller_curve_monitored_voltage_aggregation"] =
            monitored_voltage.averaged ? "AVERAGE" : "PER_PHASE"
        metadata["controller_curve_monitored_voltage_phase_count"] = string(monitored_voltage.phase_count)
    end
    bps_si = get(curve, "breakpoints", Any[])
    bps_si isa AbstractVector || begin
        metadata["controller_curve_status"] = "invalid_profile"
        metadata["controller_curve_reason"] = "breakpoints_not_vector"
        return metadata
    end
    bps = try Float64.(bps_si) catch
        metadata["controller_curve_status"] = "invalid_profile"
        metadata["controller_curve_reason"] = "breakpoints_not_numeric"
        return metadata
    end
    xs = bps ./ voltage_base
    ys = if family == "volt_var"
        ql = get(curve, "q_limits", Any[])
        valid_units = get(curve, "q_unit", "VA_FRACTION") == "VA_FRACTION" &&
            get(curve, "q_ref", "VAR_MAX") == "VAR_MAX"
        if !(ql isa AbstractVector && length(ql) == 2 && length(xs) == 4 && valid_units)
            metadata["controller_curve_status"] = "invalid_profile"
            metadata["controller_curve_reason"] = "volt_var_schema_or_units"
            return metadata
        end
        qvals = try Float64.(ql) catch
            metadata["controller_curve_status"] = "invalid_profile"
            metadata["controller_curve_reason"] = "volt_var_limits_not_numeric"
            return metadata
        end
        [qvals[2], 0.0, 0.0, qvals[1]]
    else
        pl = get(curve, "p_limits", Any[])
        ref = string(get(curve, "p_ref", "S_MAX"))
        valid_units = get(curve, "p_unit", "VA_FRACTION") == "VA_FRACTION" &&
            ref in ("S_MAX", "P_MAX", "P_AVAILABLE")
        if !(pl isa AbstractVector && length(pl) == 2 && length(xs) == 2 && valid_units)
            metadata["controller_curve_status"] = "invalid_profile"
            metadata["controller_curve_reason"] = "volt_watt_schema_or_units"
            return metadata
        end
        pvals = try Float64.(pl) catch
            metadata["controller_curve_status"] = "invalid_profile"
            metadata["controller_curve_reason"] = "volt_watt_limits_not_numeric"
            return metadata
        end
        [pvals[2], pvals[1]]
    end
    representation = _bmopf_curve_triples(xs, ys)
    if representation === nothing || !isfinite(magnitude)
        metadata["controller_curve_status"] = "invalid_profile"
        metadata["controller_curve_reason"] = "nonfinite_curve_or_voltage"
        return metadata
    end
    relative_eps = _bmopf_curve_relative_epsilon(context)
    epsilon = relative_eps * (sum(xs) / length(xs))
    epsilon > 0.0 && isfinite(epsilon) || begin
        metadata["controller_curve_status"] = "invalid_profile"
        metadata["controller_curve_reason"] = "invalid_smoothing_width"
        return metadata
    end
    value = representation.baseline
    slope = 0.0
    for (a, knot) in representation.triples
        z = (magnitude - knot) / epsilon
        value += a * epsilon * _bmopf_curve_log1pexp(z)
        slope += a * _bmopf_curve_logistic(z)
    end
    distance = minimum(abs(magnitude - knot) for knot in xs)
    nearest_scale = max(epsilon, minimum(diff(xs)))
    status = distance <= epsilon ? "breakpoint_proximity" : "finite"
    metadata["controller_curve_status"] = status
    metadata["controller_curve_output_normalized"] = string(value)
    metadata["controller_curve_local_slope"] = string(slope)
    metadata["controller_curve_breakpoint_distance"] = string(distance)
    metadata["controller_curve_relative_epsilon"] = string(relative_eps)
    metadata["controller_curve_smoothing_epsilon"] = string(epsilon)
    metadata["controller_curve_nearest_breakpoint_scale"] = string(nearest_scale)
    metadata["controller_curve_breakpoint_count"] = string(length(xs))
    metadata["controller_curve_index"] = string(index)
    if family == "volt_var"
        metadata["controller_curve_output_units"] = "Q/Q_base"
        metadata["controller_curve_derivative_units"] = "(Q/Q_base)/model_voltage"
    else
        metadata["controller_curve_output_units"] = "P/P_base"
        metadata["controller_curve_derivative_units"] = "(P/P_base)/model_voltage"
        metadata["controller_curve_reference"] = string(get(curve, "p_ref", "S_MAX"))
    end
    return metadata
end

"""Return the model-unit base used by BMOPFTools for a controller curve."""
function _bmopf_controller_curve_base(context, record::AbstractDict, index::Int,
                                      family::String)
    if family == "volt_var"
        values = get(record, "s_max", Any[])
        return values isa AbstractVector && index <= length(values) && values[index] isa Real ?
            Float64(values[index]) : nothing
    end
    curve_profile = _bmopf_current_law_control_profile(context, record)
    curve = curve_profile isa AbstractDict ? get(curve_profile, family, nothing) : nothing
    curve isa AbstractDict || return nothing
    reference = string(get(curve, "p_ref", "S_MAX"))
    if reference == "S_MAX"
        values = get(record, "s_max", Any[])
        return values isa AbstractVector && index <= length(values) && values[index] isa Real ?
            Float64(values[index]) : nothing
    elseif reference == "P_MAX"
        values = get(record, "p_max", Any[])
        return values isa AbstractVector && index <= length(values) && values[index] isa Real ?
            Float64(values[index]) : nothing
    elseif reference == "P_AVAILABLE"
        available = get(record, "p_avail", nothing)
        available isa Real || return nothing
        phase_count = max(length(_bmopf_current_law_voltage_pairs(context, record; component_type = :ibr)), 1)
        power_base = _bmopf_power_base(context)
        return Float64(available) / phase_count / (isnothing(power_base) ? 1.0 : power_base)
    end
    return nothing
end

function _bmopf_current_law_operating_point_probes(
    context,
    source;
    result_units::Symbol = :si,
    field_units::AbstractDict = Dict{Symbol,Symbol}(),
    voltage_floor::Real = 1.0e-8,
    derivative_step::Real = 1.0e-6,
    derivative_norm_limit::Real = 1.0e8,
    derivative_condition_limit::Real = 1.0e10,
    controller_residual_tolerance::Real = 1.0e-6,
)
    isfinite(voltage_floor) && voltage_floor > 0.0 || throw(ArgumentError("voltage_floor must be finite and positive"))
    isfinite(derivative_step) && derivative_step > 0.0 || throw(ArgumentError("derivative_step must be finite and positive"))
    isfinite(controller_residual_tolerance) && controller_residual_tolerance > 0.0 ||
        throw(ArgumentError("controller_residual_tolerance must be finite and positive"))
    point_positions = Dict{MOI.VariableIndex,Int}()
    if source isa NLPDiagnostics.EvaluationPoint
        point_positions = Dict(variable => index for (index, variable) in enumerate(source.variables))
    elseif !(source isa AbstractDict)
        throw(ArgumentError("source must be an EvaluationPoint or saved BMOPF result dictionary"))
    end
    network = BMOPFTools.opf_network(context)
    probes = NLPDiagnostics.CurrentLawOperatingPointProbe[]
    for (family, component_type) in _BMOPF_ATTACHMENT_FAMILIES
        table = get(network, family, Dict())
        table isa AbstractDict || continue
        for (identifier, raw_record) in sort!(collect(table); by = entry -> string(first(entry)))
            raw_record isa AbstractDict || continue
            record = raw_record
            control_profile = component_type == :ibr ?
                _bmopf_current_law_control_profile(context, record) : nothing
            fingerprint = _bmopf_current_law_fingerprint(component_type, string(identifier), record,
                                                          String.(get(record, "terminal_map", String[]));
                                                          control_profile)
            supported_component = component_type in (:load, :generator, :ibr)
            pairs = supported_component ? _bmopf_current_law_voltage_pairs(
                context, record; component_type,
            ) : Tuple{String,Union{Nothing,String}}[]
            if !supported_component
                push!(probes, NLPDiagnostics.CurrentLawOperatingPointProbe(
                    component_type, string(identifier), fingerprint.law_family,
                    fingerprint.terminal_labels, NaN, NaN, nothing, nothing,
                    :unsupported, false, Dict("reason" => "exact public operating-point law is not exposed for this component type"),
                ))
                continue
            end
            for (index, pair) in enumerate(pairs)
                bus = string(get(record, "bus", ""))
                positive = _bmopf_current_law_bus_voltage(context, source, bus, pair[1];
                                                          result_units, field_units, point_positions)
                negative = isnothing(pair[2]) ? 0.0im : _bmopf_current_law_bus_voltage(
                    context, source, bus, pair[2]; result_units, field_units, point_positions,
                )
                metadata = Dict{String,String}(
                    "bus" => bus,
                    "subload_index" => string(index),
                    "model" => string(get(record, "model", "constant_power")),
                    "coordinate_units" => source isa NLPDiagnostics.EvaluationPoint ? "model" : string(result_units),
                    "voltage_floor" => string(Float64(voltage_floor)),
                    "controller_residual_tolerance" => string(Float64(controller_residual_tolerance)),
                )
                labels = isnothing(pair[2]) ? [pair[1], "ground"] : [pair[1], pair[2]]
                if isnothing(positive) || (!isnothing(pair[2]) && isnothing(negative))
                    push!(probes, NLPDiagnostics.CurrentLawOperatingPointProbe(
                        component_type, string(identifier), fingerprint.law_family, labels,
                        NaN, NaN, nothing, nothing, :missing_voltage, false, metadata,
                    ))
                    continue
                end
                voltage = ComplexF64(positive - negative)
                magnitude = abs(voltage)
                voltage_base = _bmopf_voltage_base(context, bus)
                isnothing(voltage_base) && (voltage_base = 1.0)
                if component_type == :ibr && fingerprint.law_family == :voltage_droop
                    profile = _bmopf_current_law_control_profile(context, record)
                    curve_families = profile isa AbstractDict ?
                        [family for family in ("volt_var", "volt_watt")
                         if get(profile, family, nothing) isa AbstractDict] : String[]
                    for (curve_index, family) in enumerate(curve_families)
                        curve = get(profile, family, nothing)
                        monitored_voltage = curve isa AbstractDict ?
                            _bmopf_controller_monitored_voltage(
                                context, source, record, curve, index, point_positions,
                                result_units, field_units,
                            ) : nothing
                        curve_magnitude = isnothing(monitored_voltage) ? magnitude :
                            monitored_voltage.value
                        curve_metadata = _bmopf_controller_curve_metadata(
                            context, record, index, curve_magnitude, fingerprint, voltage_base;
                            monitored_voltage,
                            curve_family = family,
                        )
                        if curve_index == 1
                            merge!(metadata, curve_metadata)
                        else
                            for (key, value) in curve_metadata
                                suffix = startswith(key, "controller_curve_") ?
                                    key[length("controller_curve_") + 1:end] : key
                                metadata["controller_curve_$(family)_$(suffix)"] = value
                            end
                        end
                    end
                end
                if component_type != :load
                    current = _bmopf_current_law_component_current(
                        context, source, component_type, string(identifier), index,
                        pair[1]; result_units, field_units, point_positions, bus,
                    )
                    if isnothing(current)
                        push!(probes, NLPDiagnostics.CurrentLawOperatingPointProbe(
                            component_type, string(identifier), fingerprint.law_family, labels,
                            magnitude, NaN, nothing, nothing, :missing_current, false, metadata,
                        ))
                        continue
                    end
                    metadata["law_equation"] = "P = dVᵣ·Iᵣ + dVᵢ·Iᵢ; Q = dVᵢ·Iᵣ − dVᵣ·Iᵢ"
                    metadata["derivative_map"] = "bilinear_power_voltage_current_to_p_q"
                    power = _bmopf_current_law_bilinear_power(voltage, current)
                    metadata["observed_power_real"] = string(real(power))
                    metadata["observed_power_imag"] = string(imag(power))
                    if component_type == :ibr && haskey(fingerprint.metadata, "power_factor")
                        pf = try parse(Float64, fingerprint.metadata["power_factor"]) catch; NaN end
                        if isfinite(pf) && abs(pf) > 1.0e-9 && abs(pf) <= 1.0
                            pf_residual = sign(pf) * imag(power) +
                                          tan(acos(abs(pf))) * real(power)
                            metadata["control_equation"] =
                                "sign(pf)*Q + tan(acos(abs(pf)))*P = 0"
                            metadata["control_equation_residual"] = string(pf_residual)
                        end
                    end
                    if component_type == :ibr && fingerprint.law_family == :voltage_droop
                        for family in ("volt_var", "volt_watt")
                            prefix = family == "volt_var" ? "controller_curve_" :
                                "controller_curve_$(family)_"
                            output = get(metadata, "$(prefix)output_normalized", nothing)
                            base = _bmopf_controller_curve_base(context, record, index, family)
                            if output isa AbstractString && !isnothing(base)
                                normalized = try parse(Float64, output) catch; NaN end
                                if isfinite(normalized) && isfinite(base)
                                    if family == "volt_var"
                                        residual = imag(power) - base * normalized
                                        metadata["controller_curve_volt_var_base"] = string(base)
                                        metadata["controller_curve_volt_var_expected_q"] = string(base * normalized)
                                        metadata["controller_curve_volt_var_equation_residual"] = string(residual)
                                    else
                                        cap = base * normalized
                                        violation = real(power) - cap
                                        metadata["controller_curve_volt_watt_base"] = string(base)
                                        metadata["controller_curve_volt_watt_cap"] = string(cap)
                                        metadata["controller_curve_volt_watt_cap_violation"] = string(violation)
                                    end
                                end
                            end
                        end
                    end
                    saved_power = _bmopf_current_law_saved_power(
                        context, source, component_type, string(identifier), pair[1];
                        result_units, field_units,
                    )
                    if !isnothing(saved_power)
                        residual = power - saved_power
                        metadata["saved_power_real"] = string(real(saved_power))
                        metadata["saved_power_imag"] = string(imag(saved_power))
                        metadata["power_equation_residual_norm"] = string(abs(residual))
                    end
                    if magnitude <= voltage_floor
                        push!(probes, NLPDiagnostics.CurrentLawOperatingPointProbe(
                            component_type, string(identifier), fingerprint.law_family, labels,
                            magnitude, abs(current), nothing, nothing, :zero_voltage, false, metadata,
                        ))
                        continue
                    end
                    jacobian = _bmopf_current_law_bilinear_jacobian(voltage, current)
                    singular_values = LinearAlgebra.svdvals(jacobian)
                    derivative_norm = maximum(singular_values)
                    derivative_condition = iszero(minimum(singular_values)) ? Inf :
                                          maximum(singular_values) / minimum(singular_values)
                    metadata["derivative_coordinate_count"] = "4"
                    status = derivative_norm > derivative_norm_limit ||
                             derivative_condition > derivative_condition_limit ?
                             :derivative_amplified : :finite
                    push!(probes, NLPDiagnostics.CurrentLawOperatingPointProbe(
                        component_type, string(identifier), fingerprint.law_family, labels,
                        magnitude, abs(current), derivative_norm, derivative_condition,
                        status, true, metadata,
                    ))
                    continue
                end
                if magnitude <= voltage_floor
                    push!(probes, NLPDiagnostics.CurrentLawOperatingPointProbe(
                        component_type, string(identifier), fingerprint.law_family, labels,
                        magnitude, NaN, nothing, nothing, :zero_voltage, false, metadata,
                    ))
                    continue
                end
                current = _bmopf_current_law_current(record, index, voltage;
                                                     voltage_base)
                if current === nothing || !isfinite(real(current)) || !isfinite(imag(current))
                    push!(probes, NLPDiagnostics.CurrentLawOperatingPointProbe(
                        component_type, string(identifier), fingerprint.law_family, labels,
                        magnitude, NaN, nothing, nothing, :nonfinite, false, metadata,
                    ))
                    continue
                end
                h = max(Float64(derivative_step) * max(1.0, magnitude), sqrt(eps(Float64)))
                samples = (
                    _bmopf_current_law_current(record, index, voltage + h; voltage_base),
                    _bmopf_current_law_current(record, index, voltage - h; voltage_base),
                    _bmopf_current_law_current(record, index, voltage + im * h; voltage_base),
                    _bmopf_current_law_current(record, index, voltage - im * h; voltage_base),
                )
                # A finite base point can still have a non-finite central
                # stencil when the perturbation crosses an exact zero or a
                # model-specific domain boundary. Preserve that as coverage
                # evidence instead of allowing `nothing` arithmetic to throw.
                all(value isa Complex && isfinite(real(value)) && isfinite(imag(value)) for value in samples) || begin
                    push!(probes, NLPDiagnostics.CurrentLawOperatingPointProbe(
                        component_type, string(identifier), fingerprint.law_family, labels,
                        magnitude, abs(current), nothing, nothing, :nonfinite, false, metadata,
                    ))
                    continue
                end
                directional = ComplexF64[
                    (samples[1] - samples[2]) / (2h),
                    (samples[3] - samples[4]) / (2h),
                ]
                jacobian = [real(directional[1]) real(directional[2]);
                            imag(directional[1]) imag(directional[2])]
                singular_values = LinearAlgebra.svdvals(jacobian)
                derivative_norm = maximum(singular_values)
                derivative_condition = iszero(minimum(singular_values)) ? Inf :
                                      maximum(singular_values) / minimum(singular_values)
                metadata["derivative_step"] = string(h)
                status = derivative_norm > derivative_norm_limit || derivative_condition > derivative_condition_limit ?
                         :derivative_amplified : :finite
                push!(probes, NLPDiagnostics.CurrentLawOperatingPointProbe(
                    component_type, string(identifier), fingerprint.law_family, labels,
                    magnitude, abs(current), derivative_norm, derivative_condition,
                    status, true, metadata,
                ))
            end
        end
    end
    return probes
end

function _bmopf_current_law_operating_point_report(context, source; kwargs...)
    probes = _bmopf_current_law_operating_point_probes(context, source; kwargs...)
    report = NLPDiagnostics.DiagnosticReport()
    report.metadata[:bmopf_current_law_operating_point_probe_count] = string(length(probes))
    status_counts = Dict{String,Int}()
    for probe in probes
        status = string(probe.domain_status)
        status_counts[status] = get(status_counts, status, 0) + 1
        component = "$(probe.component_type) $(probe.component_id)"
        curve_entries = Tuple{String,String}[("", get(probe.metadata, "controller_curve_status", ""))]
        for family in ("volt_var", "volt_watt")
            push!(curve_entries, (family, get(probe.metadata, "controller_curve_$(family)_status", "")))
        end
        for (prefix, curve_status) in curve_entries
            isempty(curve_status) && continue
            family = isempty(prefix) ? get(probe.metadata, "controller_curve_family", "controller") : prefix
            key_prefix = isempty(prefix) ? "controller_curve_" : "controller_curve_$(prefix)_"
            if curve_status == "breakpoint_proximity"
                push!(report, NLPDiagnostics.Finding(:bmopf_controller_curve_breakpoint_proximity;
                    severity = NLPDiagnostics.SeverityWarning,
                    domain = NLPDiagnostics.NumericalIssue,
                    basis = NLPDiagnostics.NumericalObservation,
                    confidence = NLPDiagnostics.ConfidenceHigh,
                    observation = "$component is evaluated within the declared smoothing width of a $family breakpoint.",
                    why_it_matters = "The controller derivative is transitioning between curve segments, so small voltage perturbations can change active control sensitivity and solver scaling.",
                    evidence = [NLPDiagnostics.Evidence("Public controller-curve fingerprint"; details = [
                        "curve_family" => family,
                        "breakpoint_distance" => get(probe.metadata, "$(key_prefix)breakpoint_distance", ""),
                        "smoothing_epsilon" => get(probe.metadata, "$(key_prefix)smoothing_epsilon", ""),
                        "local_slope" => get(probe.metadata, "$(key_prefix)local_slope", ""),
                        "voltage_reference" => get(probe.metadata, "$(key_prefix)voltage_reference", ""),
                    ])],
                    suggested_actions = ["Inspect nearby solver iterates and retain the smoothed controller derivative when comparing conditioning."],
                ))
            elseif curve_status == "invalid_profile"
                push!(report, NLPDiagnostics.Finding(:bmopf_controller_curve_profile_invalid;
                    severity = NLPDiagnostics.SeverityWarning,
                    domain = NLPDiagnostics.RepresentationalIssue,
                    basis = NLPDiagnostics.StructuralProof,
                    confidence = NLPDiagnostics.ConfidenceCertain,
                    observation = "$component declares a $family profile that cannot be evaluated from the public schema.",
                    why_it_matters = "The model may fall back to box bounds or a different controller law, so a curve-based derivative interpretation would be unsound.",
                    evidence = [NLPDiagnostics.Evidence("Public controller-curve schema"; details = [
                        "curve_family" => family,
                        "reason" => get(probe.metadata, "$(key_prefix)reason", ""),
                    ])],
                    suggested_actions = ["Validate breakpoint ordering, limit units, and reference fields against the BMOPFTools control-profile schema."],
                ))
            end
        end
        residual_tolerance = try
            parse(Float64, get(probe.metadata, "controller_residual_tolerance", "1.0e-6"))
        catch
            1.0e-6
        end
        q_residual = try
            parse(Float64, get(probe.metadata, "controller_curve_volt_var_equation_residual", "NaN"))
        catch
            NaN
        end
        if isfinite(q_residual) && abs(q_residual) > residual_tolerance
            push!(report, NLPDiagnostics.Finding(:bmopf_controller_curve_equation_residual;
                severity = NLPDiagnostics.SeverityWarning,
                domain = NLPDiagnostics.NumericalIssue,
                basis = NLPDiagnostics.NumericalObservation,
                confidence = NLPDiagnostics.ConfidenceHigh,
                observation = "$component does not satisfy the public Volt-var equality within the configured residual tolerance.",
                why_it_matters = "The observed reactive power and declared smoothed controller curve disagree after applying the device base, so the saved point may not correspond to the assembled controller equations or may use inconsistent units.",
                evidence = [NLPDiagnostics.Evidence("Device-base-scaled Volt-var residual"; details = [
                    "residual" => q_residual,
                    "tolerance" => residual_tolerance,
                    "base" => get(probe.metadata, "controller_curve_volt_var_base", ""),
                    "expected_q" => get(probe.metadata, "controller_curve_volt_var_expected_q", ""),
                ])],
                suggested_actions = ["Check saved-result power/current units and compare the point against the BMOPFTools controller constraint residual."],
            ))
        end
        vw_violation = try
            parse(Float64, get(probe.metadata, "controller_curve_volt_watt_cap_violation", "NaN"))
        catch
            NaN
        end
        if isfinite(vw_violation) && vw_violation > residual_tolerance
            push!(report, NLPDiagnostics.Finding(:bmopf_controller_curve_cap_violation;
                severity = NLPDiagnostics.SeverityWarning,
                domain = NLPDiagnostics.NumericalIssue,
                basis = NLPDiagnostics.NumericalObservation,
                confidence = NLPDiagnostics.ConfidenceHigh,
                observation = "$component exceeds the public Volt-watt active-power cap at the supplied operating point.",
                why_it_matters = "The observed active power is above the voltage-dependent controller limit after applying the device base, indicating an inconsistent point, unit mismatch, or violated controller constraint.",
                evidence = [NLPDiagnostics.Evidence("Device-base-scaled Volt-watt cap"; details = [
                    "cap_violation" => vw_violation,
                    "tolerance" => residual_tolerance,
                    "base" => get(probe.metadata, "controller_curve_volt_watt_base", ""),
                    "cap" => get(probe.metadata, "controller_curve_volt_watt_cap", ""),
                ])],
                suggested_actions = ["Validate the active-power result units and inspect the Volt-watt inequality residual before interpreting solver behavior."],
            ))
        end
        if probe.domain_status == :unsupported || probe.domain_status == :missing_voltage ||
           probe.domain_status == :missing_current
            push!(report, NLPDiagnostics.Finding(:bmopf_current_law_operating_point_unavailable;
                severity = NLPDiagnostics.SeverityInfo,
                domain = NLPDiagnostics.RepresentationalIssue,
                basis = NLPDiagnostics.NumericalObservation,
                confidence = NLPDiagnostics.ConfidenceCertain,
                observation = "No exact current-law operating-point derivative was available for $component.",
                why_it_matters = "Static metadata and local derivative evidence must remain separate when a saved result or plugin-owned law does not expose the required voltage or current coordinates.",
                evidence = [NLPDiagnostics.Evidence("Current-law operating-point coverage"; details = [
                    "status" => status,
                    "law_family" => string(probe.law_family),
                ])],
                suggested_actions = ["Provide complete terminal voltages or a domain extension with an exact current-law evaluator."],
            ))
        elseif probe.domain_status == :zero_voltage
            push!(report, NLPDiagnostics.Finding(:bmopf_current_law_operating_point_zero_voltage;
                severity = NLPDiagnostics.SeverityWarning,
                domain = NLPDiagnostics.MathematicalIssue,
                basis = NLPDiagnostics.NumericalObservation,
                confidence = NLPDiagnostics.ConfidenceHigh,
                observation = "$component is evaluated at terminal voltage magnitude $(probe.voltage_magnitude), at or below the configured voltage floor.",
                why_it_matters = "The current representation is undefined or singular at this operating point, so derivative-based conclusions cannot be trusted there.",
                evidence = [NLPDiagnostics.Evidence("Current-law operating-point probe"; details = [
                    "law_family" => string(probe.law_family),
                    "terminal_labels" => join(probe.terminal_labels, ","),
                    "voltage_floor" => get(probe.metadata, "voltage_floor", ""),
                ])],
                suggested_actions = ["Use a physically meaningful nonzero initialization or enforce a defensible voltage floor."],
            ))
        elseif probe.domain_status == :nonfinite
            push!(report, NLPDiagnostics.Finding(:bmopf_current_law_operating_point_nonfinite;
                severity = NLPDiagnostics.SeverityWarning,
                domain = NLPDiagnostics.NumericalIssue,
                basis = NLPDiagnostics.NumericalObservation,
                confidence = NLPDiagnostics.ConfidenceHigh,
                observation = "$component produced a non-finite current or derivative at the supplied operating point.",
                why_it_matters = "The local derivative geometry is unavailable; rank and conditioning reports must not treat the missing coordinates as zeros.",
                evidence = [NLPDiagnostics.Evidence("Current-law operating-point probe"; details = [
                    "law_family" => string(probe.law_family),
                    "terminal_labels" => join(probe.terminal_labels, ","),
                ])],
                suggested_actions = ["Inspect the saved-result units, voltage-domain assumptions, and model coefficients before running numerical rank analysis."],
            ))
        elseif probe.domain_status == :derivative_amplified
            push!(report, NLPDiagnostics.Finding(:bmopf_current_law_operating_point_derivative_amplification;
                severity = NLPDiagnostics.SeverityWarning,
                domain = NLPDiagnostics.NumericalIssue,
                basis = NLPDiagnostics.NumericalObservation,
                confidence = NLPDiagnostics.ConfidenceHigh,
                observation = "$component has an amplified local current-law derivative at the supplied operating point.",
                why_it_matters = "The local current Jacobian can dominate network derivatives and make solver tolerances and scaling highly operating-point dependent.",
                evidence = [NLPDiagnostics.Evidence("Current-law derivative probe"; details = [
                    "law_family" => string(probe.law_family),
                    "derivative_norm" => string(probe.derivative_norm),
                    "derivative_condition" => string(probe.derivative_condition),
                ])],
                suggested_actions = ["Compare nearby operating points and inspect voltage/current scaling before attributing solver behavior to structural degeneracy."],
            ))
        end
    end
    report.metadata[:bmopf_current_law_operating_point_status_counts] = join(
        ("$(key)=$(status_counts[key])" for key in sort!(collect(keys(status_counts)))), ",",
    )
    return report
end

_bmopf_current_law_operating_point_probes_public(context, source; kwargs...) =
    _bmopf_current_law_operating_point_probes(context, source; kwargs...)
_bmopf_current_law_operating_point_report_public(context, source; kwargs...) =
    _bmopf_current_law_operating_point_report(context, source; kwargs...)

function _bmopf_current_law_probe_key(probe::NLPDiagnostics.CurrentLawOperatingPointProbe)
    return join((
        string(probe.component_type), probe.component_id, string(probe.law_family),
        join(probe.terminal_labels, "/"), get(probe.metadata, "subload_index", ""),
    ), "|")
end

"""Extract controller-curve observations without treating absent fields as zeros."""
function _bmopf_controller_curve_snapshot_observations(probe)
    observations = Dict{String,NamedTuple}()
    primary_family = get(probe.metadata, "controller_curve_family", nothing)
    primary_family isa AbstractString && begin
        observations[String(primary_family)] = (
            status = get(probe.metadata, "controller_curve_status", ""),
            semantics = get(probe.metadata, "controller_curve_voltage_semantics", ""),
            slope = try parse(Float64, get(probe.metadata, "controller_curve_local_slope", "NaN")) catch; NaN end,
            monitored_voltage = try parse(Float64, get(probe.metadata, "controller_curve_monitored_voltage", "NaN")) catch; NaN end,
        )
    end
    for family in ("volt_var", "volt_watt")
        prefix = "controller_curve_$(family)_"
        status = get(probe.metadata, "$(prefix)status", nothing)
        status isa AbstractString || continue
        observations[family] = (
            status = String(status),
            semantics = String(get(probe.metadata, "$(prefix)voltage_semantics", "")),
            slope = try parse(Float64, get(probe.metadata, "$(prefix)local_slope", "NaN")) catch; NaN end,
            monitored_voltage = try parse(Float64, get(probe.metadata, "$(prefix)monitored_voltage", "NaN")) catch; NaN end,
        )
    end
    return observations
end

function _bmopf_optional_curve_float(metadata, key::String)
    raw = get(metadata, key, nothing)
    raw isa AbstractString || return nothing
    value = try parse(Float64, raw) catch; NaN end
    return isfinite(value) ? value : nothing
end

function _bmopf_controller_curve_observation(probe, family::String, prefix::String)
    metadata = probe.metadata
    status = Symbol(lowercase(get(metadata, "$(prefix)status", "unknown")))
    reference = Symbol(lowercase(get(metadata, "$(prefix)voltage_reference", "unknown")))
    aggregation = uppercase(get(metadata, "$(prefix)monitored_voltage_aggregation", "PER_PHASE")) == "AVERAGE" ?
        :average : :per_phase
    semantics = get(metadata, "$(prefix)voltage_semantics", "terminal_pair_magnitude_proxy") ==
        "exact_public_monitored_voltage" ? :exact_public_monitored_voltage : :terminal_pair_magnitude_proxy
    expected_key = family == "volt_var" ?
        "controller_curve_volt_var_expected_q" : "controller_curve_volt_watt_cap"
    residual_key = family == "volt_var" ?
        "controller_curve_volt_var_equation_residual" : "controller_curve_volt_watt_cap_violation"
    return NLPDiagnostics.ControllerCurveOperatingPointObservation(
        probe.component_type,
        probe.component_id,
        Symbol(family),
        copy(probe.terminal_labels),
        reference,
        aggregation,
        semantics,
        _bmopf_optional_curve_float(metadata, "$(prefix)monitored_voltage"),
        _bmopf_optional_curve_float(metadata, "$(prefix)output_normalized"),
        _bmopf_optional_curve_float(metadata, "$(prefix)local_slope"),
        _bmopf_optional_curve_float(metadata, "$(prefix)breakpoint_distance"),
        _bmopf_optional_curve_float(metadata, "$(prefix)smoothing_epsilon"),
        _bmopf_optional_curve_float(metadata,
            family == "volt_var" ? "controller_curve_volt_var_base" : "controller_curve_volt_watt_base"),
        _bmopf_optional_curve_float(metadata, expected_key),
        family == "volt_var" ? _bmopf_optional_curve_float(metadata, residual_key) : nothing,
        family == "volt_watt" ? _bmopf_optional_curve_float(metadata, residual_key) : nothing,
        status,
        copy(metadata),
    )
end

function _bmopf_controller_curve_operating_point_observations(
    context,
    source;
    kwargs...,
)
    probes = _bmopf_current_law_operating_point_probes(context, source; kwargs...)
    observations = NLPDiagnostics.ControllerCurveOperatingPointObservation[]
    for probe in probes
        primary_family = get(probe.metadata, "controller_curve_family", nothing)
        primary_family isa AbstractString && push!(observations,
            _bmopf_controller_curve_observation(probe, String(primary_family), "controller_curve_"),
        )
        for family in ("volt_var", "volt_watt")
            prefix = "controller_curve_$(family)_"
            haskey(probe.metadata, "$(prefix)status") || continue
            family == primary_family && continue
            push!(observations, _bmopf_controller_curve_observation(probe, family, prefix))
        end
    end
    return observations
end

_bmopf_controller_curve_operating_point_observations_public(context, source; kwargs...) =
    _bmopf_controller_curve_operating_point_observations(context, source; kwargs...)

"""Compare current-law operating-point evidence without treating missing probes as zeros."""
function _bmopf_current_law_operating_point_persistence(
    context,
    sources;
    minimum_snapshots::Integer = 2,
    derivative_scale_change_factor::Real = 10.0,
    condition_change_factor::Real = 10.0,
    result_units::Symbol = :si,
    field_units::AbstractDict = Dict{Symbol,Symbol}(),
    voltage_floor::Real = 1.0e-8,
    derivative_step::Real = 1.0e-6,
    derivative_norm_limit::Real = 1.0e8,
    derivative_condition_limit::Real = 1.0e10,
    controller_residual_tolerance::Real = 1.0e-6,
)
    minimum_snapshots >= 2 || throw(ArgumentError("minimum_snapshots must be at least two"))
    derivative_scale_change_factor >= 1.0 || throw(ArgumentError("derivative_scale_change_factor must be at least one"))
    condition_change_factor >= 1.0 || throw(ArgumentError("condition_change_factor must be at least one"))
    sources isa AbstractVector || throw(ArgumentError("sources must be a vector of explicit points or saved results"))
    report = NLPDiagnostics.DiagnosticReport()
    report.metadata[:stage] = "bmopf_current_law_operating_point_persistence"
    report.metadata[:bmopf_current_law_operating_point_snapshot_count] = string(length(sources))
    report.metadata[:bmopf_current_law_operating_point_snapshot_labels] = join(
        (source isa NLPDiagnostics.EvaluationPoint ? source.label : "saved_result_$(index)"
         for (index, source) in enumerate(sources)), ",",
    )
    report.metadata[:bmopf_current_law_operating_point_minimum_snapshots] = string(minimum_snapshots)
    report.metadata[:bmopf_current_law_operating_point_derivative_scale_change_factor] = string(derivative_scale_change_factor)
    report.metadata[:bmopf_current_law_operating_point_condition_change_factor] = string(condition_change_factor)
    if length(sources) < minimum_snapshots
        push!(report, NLPDiagnostics.Finding(:bmopf_current_law_operating_point_persistence_unavailable;
            severity = NLPDiagnostics.SeverityInfo,
            domain = NLPDiagnostics.NumericalIssue,
            basis = NLPDiagnostics.NumericalObservation,
            confidence = NLPDiagnostics.ConfidenceHigh,
            observation = "Only $(length(sources)) current-law operating-point snapshot(s) were supplied.",
            why_it_matters = "Derivative persistence requires repeated, explicitly supplied operating points; a single local observation cannot distinguish a persistent hazard from point-specific behavior.",
            evidence = [NLPDiagnostics.Evidence("Current-law persistence availability"; details = [
                "snapshot_count" => length(sources),
                "minimum_snapshots" => minimum_snapshots,
            ])],
            suggested_actions = ["Supply at least two coordinate-aligned points or saved results from the operating region of interest."],
        ))
        return report
    end
    probe_sets = [
        _bmopf_current_law_operating_point_probes(context, source;
            result_units, field_units, voltage_floor, derivative_step,
            derivative_norm_limit, derivative_condition_limit,
            controller_residual_tolerance,
        ) for source in sources
    ]
    key_set = Set{String}()
    for probes in probe_sets, probe in probes
        push!(key_set, _bmopf_current_law_probe_key(probe))
    end
    keys = sort!(collect(key_set))
    report.metadata[:bmopf_current_law_operating_point_key_count] = string(length(keys))
    changed_status_count = 0
    changed_scale_count = 0
    changed_condition_count = 0
    changed_curve_status_count = 0
    changed_curve_coverage_count = 0
    changed_curve_slope_count = 0
    for key in keys
        aligned = Union{Nothing,NLPDiagnostics.CurrentLawOperatingPointProbe}[]
        for probes in probe_sets
            index = findfirst(probe -> _bmopf_current_law_probe_key(probe) == key, probes)
            push!(aligned, isnothing(index) ? nothing : probes[index])
        end
        present = [probe for probe in aligned if !isnothing(probe)]
        statuses = unique(string(probe.domain_status) for probe in present)
        if length(statuses) > 1
            changed_status_count += 1
            push!(report, NLPDiagnostics.Finding(:bmopf_current_law_operating_point_domain_status_changed;
                severity = NLPDiagnostics.SeverityWarning,
                domain = NLPDiagnostics.NumericalIssue,
                basis = NLPDiagnostics.NumericalObservation,
                confidence = NLPDiagnostics.ConfidenceHigh,
                observation = "Current-law probe '$key' changes domain status across supplied operating points ($(join(statuses, ", "))).",
                why_it_matters = "A transition between finite, zero-voltage, non-finite, or unavailable states can dominate solver behavior and must not be summarized as one persistent rank or scaling conclusion.",
                evidence = [NLPDiagnostics.Evidence("Current-law status persistence"; details = [
                    "snapshot_count" => length(sources),
                    "present_snapshot_count" => length(present),
                    "statuses" => join(statuses, ","),
                ])],
                suggested_actions = ["Inspect the affected snapshots and retain their point labels before attributing the transition to a formulation defect."],
            ))
        end
        curve_keys = Set{String}()
        curve_snapshots = Dict{String,Vector{NamedTuple}}()
        for probe in present
            for (family, observation) in _bmopf_controller_curve_snapshot_observations(probe)
                push!(curve_keys, family)
                push!(get!(curve_snapshots, family, NamedTuple[]), observation)
            end
        end
        for family in sort!(collect(curve_keys))
            snapshots = curve_snapshots[family]
            curve_statuses = unique(String(snapshot.status) for snapshot in snapshots
                                    if !isempty(String(snapshot.status)))
            if length(curve_statuses) > 1
                changed_curve_status_count += 1
                push!(report, NLPDiagnostics.Finding(:bmopf_controller_curve_status_changed;
                    severity = NLPDiagnostics.SeverityWarning,
                    domain = NLPDiagnostics.NumericalIssue,
                    basis = NLPDiagnostics.NumericalObservation,
                    confidence = NLPDiagnostics.ConfidenceHigh,
                    observation = "Controller curve '$family' for probe '$key' changes status across supplied operating points ($(join(curve_statuses, ", "))).",
                    why_it_matters = "Breakpoint proximity and profile coverage can change along solver iterates, so one local controller derivative must not be treated as persistent.",
                    evidence = [NLPDiagnostics.Evidence("Controller-curve persistence"; details = [
                        "curve_family" => family,
                        "statuses" => join(curve_statuses, ","),
                        "snapshot_count" => length(snapshots),
                    ])],
                    suggested_actions = ["Retain the iterate labels and compare controller slopes on each side of the transition."],
                ))
            end
            curve_semantics = unique(String(snapshot.semantics) for snapshot in snapshots
                                     if !isempty(String(snapshot.semantics)))
            if length(curve_semantics) > 1
                changed_curve_coverage_count += 1
                push!(report, NLPDiagnostics.Finding(:bmopf_controller_curve_monitor_coverage_changed;
                    severity = NLPDiagnostics.SeverityInfo,
                    domain = NLPDiagnostics.RepresentationalIssue,
                    basis = NLPDiagnostics.NumericalObservation,
                    confidence = NLPDiagnostics.ConfidenceHigh,
                    observation = "Controller curve '$family' for probe '$key' changes monitor-coverage semantics across supplied operating points.",
                    why_it_matters = "Exact monitored-voltage evidence and proxy evidence should not be combined into one unconditional controller conclusion.",
                    evidence = [NLPDiagnostics.Evidence("Controller monitor coverage persistence"; details = [
                        "curve_family" => family,
                        "semantics" => join(curve_semantics, ","),
                    ])],
                    suggested_actions = ["Inspect missing terminal coordinates or profile-reference changes before comparing curve sensitivities."],
                ))
            end
            slopes = [snapshot.slope for snapshot in snapshots if isfinite(snapshot.slope)]
            if length(slopes) >= minimum_snapshots
                slope_ratio = maximum(abs.(slopes)) / max(minimum(abs.(slopes)), eps(Float64))
                if slope_ratio >= derivative_scale_change_factor
                    changed_curve_slope_count += 1
                    push!(report, NLPDiagnostics.Finding(:bmopf_controller_curve_slope_changed;
                        severity = NLPDiagnostics.SeverityWarning,
                        domain = NLPDiagnostics.NumericalIssue,
                        basis = NLPDiagnostics.NumericalObservation,
                        confidence = NLPDiagnostics.ConfidenceHigh,
                        observation = "Controller curve '$family' for probe '$key' changes local slope by a factor of $(round(slope_ratio; sigdigits = 4)).",
                        why_it_matters = "The controller contribution to the Jacobian can change substantially even when the current-law family and voltage domain remain finite.",
                        evidence = [NLPDiagnostics.Evidence("Controller-curve slope persistence"; details = [
                            "minimum_absolute_slope" => minimum(abs.(slopes)),
                            "maximum_absolute_slope" => maximum(abs.(slopes)),
                            "change_factor" => slope_ratio,
                        ])],
                        suggested_actions = ["Compare the curve slope with network row/column scaling and retain the smoothed derivative semantics."],
                    ))
                end
            end
        end
        if length(present) < minimum_snapshots
            push!(report, NLPDiagnostics.Finding(:bmopf_current_law_operating_point_persistence_partial;
                severity = NLPDiagnostics.SeverityInfo,
                domain = NLPDiagnostics.RepresentationalIssue,
                basis = NLPDiagnostics.NumericalObservation,
                confidence = NLPDiagnostics.ConfidenceHigh,
                observation = "Current-law probe '$key' is present at only $(length(present)) of $(length(sources)) snapshots.",
                why_it_matters = "Persistence cannot be certified when a component or terminal pair is absent from one or more snapshots.",
                evidence = [NLPDiagnostics.Evidence("Current-law probe alignment"; details = [
                    "snapshot_count" => length(sources),
                    "present_snapshot_count" => length(present),
                ])],
                suggested_actions = ["Use a stable component registry and preserve complete terminal voltage records at every snapshot."],
            ))
            continue
        end
        finite = [probe for probe in present if probe.finite &&
                  !isnothing(probe.derivative_norm) && isfinite(probe.derivative_norm) &&
                  !isnothing(probe.derivative_condition) && isfinite(probe.derivative_condition)]
        if length(finite) < minimum_snapshots
            continue
        end
        derivative_values = [probe.derivative_norm for probe in finite]
        condition_values = [probe.derivative_condition for probe in finite]
        derivative_ratio = maximum(derivative_values) / max(minimum(derivative_values), eps(Float64))
        condition_ratio = maximum(condition_values) / max(minimum(condition_values), eps(Float64))
        if derivative_ratio >= derivative_scale_change_factor
            changed_scale_count += 1
            push!(report, NLPDiagnostics.Finding(:bmopf_current_law_operating_point_derivative_scale_changed;
                severity = NLPDiagnostics.SeverityWarning,
                domain = NLPDiagnostics.NumericalIssue,
                basis = NLPDiagnostics.NumericalObservation,
                confidence = NLPDiagnostics.ConfidenceHigh,
                observation = "Current-law probe '$key' changes local derivative scale by a factor of $(round(derivative_ratio; sigdigits = 4)) across the supplied points.",
                why_it_matters = "Operating-point-dependent derivative scale can alter row/column scaling, rank thresholds, and solver tolerance semantics without proving a structural defect.",
                evidence = [NLPDiagnostics.Evidence("Current-law derivative-scale persistence"; details = [
                    "minimum_derivative_norm" => minimum(derivative_values),
                    "maximum_derivative_norm" => maximum(derivative_values),
                    "change_factor" => derivative_ratio,
                ])],
                suggested_actions = ["Compare physical voltage/current scales and repeat the probe over a controlled operating region."],
            ))
        end
        if condition_ratio >= condition_change_factor
            changed_condition_count += 1
            push!(report, NLPDiagnostics.Finding(:bmopf_current_law_operating_point_conditioning_changed;
                severity = NLPDiagnostics.SeverityWarning,
                domain = NLPDiagnostics.NumericalIssue,
                basis = NLPDiagnostics.NumericalObservation,
                confidence = NLPDiagnostics.ConfidenceHigh,
                observation = "Current-law probe '$key' changes local derivative conditioning by a factor of $(round(condition_ratio; sigdigits = 4)) across the supplied points.",
                why_it_matters = "Changing local anisotropy can make one operating point appear well behaved while another produces a poorly scaled current Jacobian.",
                evidence = [NLPDiagnostics.Evidence("Current-law conditioning persistence"; details = [
                    "minimum_condition" => minimum(condition_values),
                    "maximum_condition" => maximum(condition_values),
                    "change_factor" => condition_ratio,
                ])],
                suggested_actions = ["Inspect the real/imaginary current derivative directions and compare them with the network-coordinate scaling."],
            ))
        end
    end
    report.metadata[:bmopf_current_law_operating_point_changed_status_count] = string(changed_status_count)
    report.metadata[:bmopf_current_law_operating_point_changed_scale_count] = string(changed_scale_count)
    report.metadata[:bmopf_current_law_operating_point_changed_condition_count] = string(changed_condition_count)
    report.metadata[:bmopf_controller_curve_changed_status_count] = string(changed_curve_status_count)
    report.metadata[:bmopf_controller_curve_changed_coverage_count] = string(changed_curve_coverage_count)
    report.metadata[:bmopf_controller_curve_changed_slope_count] = string(changed_curve_slope_count)
    return report
end

_bmopf_current_law_operating_point_persistence_public(context, sources; kwargs...) =
    _bmopf_current_law_operating_point_persistence(context, sources; kwargs...)

function _bmopf_current_law_operating_point_trace(
    context,
    trace::NLPDiagnostics.SolverIterationTrace;
    phase::Union{Nothing,Symbol} = nothing,
    max_points::Union{Nothing,Integer} = nothing,
    result_units::Symbol = :si,
    field_units::AbstractDict = Dict{Symbol,Symbol}(),
    voltage_floor::Real = 1.0e-8,
    derivative_step::Real = 1.0e-6,
    derivative_norm_limit::Real = 1.0e8,
    derivative_condition_limit::Real = 1.0e10,
    controller_residual_tolerance::Real = 1.0e-6,
    minimum_snapshots::Integer = 2,
    derivative_scale_change_factor::Real = 10.0,
    condition_change_factor::Real = 10.0,
)
    isnothing(phase) || phase in (:regular, :restoration, :robust) ||
        throw(ArgumentError("phase must be nothing, :regular, :restoration, or :robust"))
    if !isnothing(max_points)
        max_points >= 1 || throw(ArgumentError("max_points must be positive when supplied"))
    end
    candidates = [binding for binding in trace.bindings
                  if isnothing(phase) || binding.record.phase == phase]
    selected = if isnothing(max_points) || length(candidates) <= max_points
        candidates
    else
        indices = unique(round.(Int, range(1, length(candidates); length = max_points)))
        candidates[indices]
    end
    metadata = Dict{String,String}(
        "stage" => "bmopf_current_law_operating_point_trace",
        "trace_record_count" => string(length(trace.records)),
        "trace_captured_binding_count" => string(length(trace.bindings)),
        "trace_phase_filter" => isnothing(phase) ? "all" : string(phase),
        "trace_candidate_binding_count" => string(length(candidates)),
        "trace_selected_binding_count" => string(length(selected)),
        "trace_unselected_binding_count" => string(length(candidates) - length(selected)),
        "trace_max_points" => isnothing(max_points) ? "unlimited" : string(max_points),
        "trace_selected_labels" => join((binding.point.label for binding in selected), ","),
        "trace_selected_iterations" => join((string(binding.record.iteration) for binding in selected), ","),
    )
    snapshot_reports = NLPDiagnostics.DiagnosticReport[]
    probes = Vector{Vector{NLPDiagnostics.CurrentLawOperatingPointProbe}}()
    for binding in selected
        point_probes = _bmopf_current_law_operating_point_probes(
            context, binding.point;
            result_units, field_units, voltage_floor, derivative_step,
            derivative_norm_limit, derivative_condition_limit,
            controller_residual_tolerance,
        )
        push!(probes, point_probes)
        push!(snapshot_reports, _bmopf_current_law_operating_point_report(
            context, binding.point;
            result_units, field_units, voltage_floor, derivative_step,
            derivative_norm_limit, derivative_condition_limit,
            controller_residual_tolerance,
        ))
    end
    persistence_report = if isempty(selected)
        report = NLPDiagnostics.DiagnosticReport()
        push!(report, NLPDiagnostics.Finding(:bmopf_current_law_operating_point_trace_unavailable;
            severity = NLPDiagnostics.SeverityInfo,
            domain = NLPDiagnostics.RepresentationalIssue,
            basis = NLPDiagnostics.NumericalObservation,
            confidence = NLPDiagnostics.ConfidenceCertain,
            observation = "No captured solver iteration binding with an EvaluationPoint was available for current-law probing.",
            why_it_matters = "Solver metrics alone do not identify BMOPFTools model coordinates, so current-law domain and derivative evidence cannot be attached to an iterate.",
            suggested_actions = ["Enable explicit primal capture for the solver callback, or supply staged EvaluationPoints separately."],
        ))
        report
    else
        _bmopf_current_law_operating_point_persistence(
            context, [binding.point for binding in selected];
            result_units, field_units, voltage_floor, derivative_step,
            derivative_norm_limit, derivative_condition_limit,
            minimum_snapshots, derivative_scale_change_factor,
            condition_change_factor,
        )
    end
    metadata["trace_persistence_finding_count"] = string(length(persistence_report.findings))
    return NLPDiagnostics.CurrentLawOperatingPointTrace(
        trace, NLPDiagnostics.IterationPointBinding[selected...], probes,
        snapshot_reports, persistence_report, metadata,
    )
end

_bmopf_current_law_operating_point_trace_public(context, trace; kwargs...) =
    _bmopf_current_law_operating_point_trace(context, trace; kwargs...)

"""Validate bus and component attachment port declarations for a staged context."""
function _bmopf_terminal_port_connection_report(context)
    attachment = _bmopf_attachment_port_declarations(context)
    report = NLPDiagnostics.DiagnosticReport()
    report.metadata[:bmopf_terminal_attachment_port_count] = string(length(attachment.ports))
    report.metadata[:bmopf_terminal_attachment_connection_count] = string(length(attachment.connections))
    report.metadata[:bmopf_terminal_attachment_skipped_count] = string(length(attachment.skipped))
    if !isempty(attachment.skipped)
        push!(report, NLPDiagnostics.Finding(:bmopf_terminal_attachment_port_unavailable;
            severity = NLPDiagnostics.SeverityInfo,
            domain = NLPDiagnostics.RepresentationalIssue,
            basis = NLPDiagnostics.StructuralProof,
            confidence = NLPDiagnostics.ConfidenceCertain,
            observation = "$(length(attachment.skipped)) BMOPFTools terminal attachment port(s) could not be mapped to registered bus-voltage coordinates.",
            why_it_matters = "The multiconductor port graph is intentionally incomplete for these endpoints; no topology or nullspace conclusion is made for them.",
            evidence = [NLPDiagnostics.Evidence("BMOPFTools terminal attachment coverage"; details = [
                "skipped_ports" => join(sort!(unique(attachment.skipped)), ","),
            ])],
            suggested_actions = ["Inspect terminal-map labels and ensure the staged public voltage registry covers every declared endpoint."],
        ))
    end
    return report
end

"""Return the declared BMOPF component/bus port assembly summary."""
function _bmopf_terminal_port_assembly(context)
    ports = _bmopf_terminal_port_metadata(context)
    connections = _bmopf_terminal_port_connections(context)
    return NLPDiagnostics.port_network_assembly_summary(ports, connections)
end

"""Report BMOPF port assembly connected components and endpoint validity."""
function _bmopf_terminal_port_assembly_report(context)
    ports = _bmopf_terminal_port_metadata(context)
    connections = _bmopf_terminal_port_connections(context)
    report = NLPDiagnostics._component_port_assembly_findings(ports, connections)
    endpoint_report = NLPDiagnostics._component_port_connection_findings(ports, connections)
    append!(report.findings, endpoint_report.findings)
    merge!(report.metadata, endpoint_report.metadata)
    return report
end

"""Return static nonlinear-current law fingerprints from BMOPFTools metadata."""
function _bmopf_current_law_fingerprints_public(context)
    _bmopf_context_model(context)
    return _bmopf_current_law_fingerprints(context)
end

"""Report static nonlinear-current law domains and derivative hazards."""
function _bmopf_current_law_report_public(context)
    _bmopf_context_model(context)
    return _bmopf_current_law_report(context)
end

"""
    bmopf_terminal_port_coordinate_scale_report(context, point; kwargs...) -> DiagnosticReport

Compare a staged BMOPF context's declared terminal-coordinate nominal scales
with values at `point`. Per-unit voltage coordinates use model-scale one; their
bus-specific physical voltage bases are retained as declaration evidence, not
used as numerical coordinate scales.
"""
function _bmopf_terminal_port_coordinate_scale_report(
    context,
    point::NLPDiagnostics.EvaluationPoint;
    kwargs...,
)
    _bmopf_context_model(context)
    report = NLPDiagnostics._port_coordinate_scale_findings(
        _bmopf_terminal_port_coordinate_semantics(context),
        _bmopf_terminal_port_coordinate_maps(context), point;
        kwargs...,
    )
    report.metadata[:bmopf_terminal_port_coordinate_scale_basis] =
        isnothing(BMOPFTools.opf_bases(context)) ? "SI model coordinates" :
        "per-unit model coordinates (nominal coordinate one)"
    return report
end

"""Validate staged BMOPF bus-terminal port declarations against their owning JuMP model."""
function _bmopf_terminal_port_report(context)
    owner = _bmopf_context_model(context)
    owner isa JuMP.Model || throw(ArgumentError("BMOPFTools.opf_model(context) did not return a JuMP.Model"))
    ports = _bmopf_terminal_port_metadata(context)
    maps = _bmopf_terminal_port_coordinate_maps(context)
    semantics = _bmopf_terminal_port_coordinate_semantics(context)
    connections = _bmopf_terminal_port_connections(context)
    variables = MOI.get(JuMP.backend(owner), MOI.ListOfVariableIndices())
    report = NLPDiagnostics._component_port_metadata_findings(ports; model_variables = variables)
    for partial in (
        NLPDiagnostics._component_port_coordinate_map_findings(ports, maps; model_variables = variables),
        NLPDiagnostics._component_port_coordinate_semantics_findings(ports, semantics, maps),
        NLPDiagnostics._component_port_connection_findings(ports, connections),
        NLPDiagnostics._component_port_assembly_findings(ports, connections),
        _bmopf_terminal_port_connection_report(context),
    )
        append!(report.findings, partial.findings)
        merge!(report.metadata, partial.metadata)
    end
    report.metadata[:bmopf_terminal_port_count] = string(length(ports))
    report.metadata[:bmopf_terminal_port_coordinate_map_count] = string(length(maps))
    report.metadata[:bmopf_terminal_port_coordinate_semantics_count] = string(length(semantics))
    report.metadata[:bmopf_terminal_port_connection_count] = string(length(connections))
    return report
end

"""
    bmopf_analyze_opf(context; kwargs...) -> DiagnosticReport

Analyze the JuMP/MOI model owned by a staged BMOPFTools OPF context and append
BMOPFTools' public terminal/grounding findings for the same prepared network.
`kwargs` are forwarded unchanged to [`analyze`](@ref), while an explicit `point`
may request Jacobian, rank, nullspace, scaling, and degeneracy stages. The same
point also checks declared BMOPF terminal-coordinate scales. The BMOPF portion
remains structural physical evidence; it does not turn a floating-neutral data
finding into a proven model-coordinate gauge. Set
`include_port_physical_modes = true` to project conservative WYE/DELTA
component-port common-mode expectations into the expected-mode comparison.
"""
function _bmopf_analyze_opf(
    context;
    point::Union{Nothing,NLPDiagnostics.EvaluationPoint} = nothing,
    include_floating_neutral_candidates::Bool = false,
    include_port_physical_modes::Bool = false,
    expected_modes::Union{Nothing,AbstractVector{<:NLPDiagnostics.ExpectedNullspaceMode}} = nothing,
    expected_mode_tangent_policy::Union{Nothing,NLPDiagnostics.ExpectedNullspaceTangentPolicy} = nothing,
    kwargs...,
)
    owner = _bmopf_context_model(context)
    owner isa JuMP.Model || throw(ArgumentError(
        "BMOPFTools.opf_model(context) did not return a JuMP.Model",
    ))
    candidate_modes = include_floating_neutral_candidates ?
                      _bmopf_floating_neutral_candidate_modes(context) :
                      NLPDiagnostics.ExpectedNullspaceMode[]
    port_physical_modes = if include_port_physical_modes
        declaration = _bmopf_terminal_port_nullspace_declarations(context)
        NLPDiagnostics.port_component_expected_nullspace_modes(
            _bmopf_terminal_port_metadata(context), declaration.modes,
            _bmopf_terminal_port_coordinate_maps(context),
        )
    else
        NLPDiagnostics.ExpectedNullspaceMode[]
    end
    resolved_expected_modes = if isnothing(expected_modes)
        isempty(candidate_modes) && isempty(port_physical_modes) ? nothing :
            vcat(candidate_modes, port_physical_modes)
    else
        vcat(expected_modes, candidate_modes, port_physical_modes)
    end
    report = isnothing(resolved_expected_modes) ?
             NLPDiagnostics.analyze(JuMP.backend(owner); point = point,
                                    expected_mode_tangent_policy = expected_mode_tangent_policy,
                                    kwargs...) :
             NLPDiagnostics.analyze(JuMP.backend(owner); point = point, kwargs...,
                                    expected_modes = resolved_expected_modes,
                                    expected_mode_tangent_policy = expected_mode_tangent_policy)
    physical_report = NLPDiagnostics.bmopf_terminal_report(BMOPFTools.opf_network(context))
    source_schema_report = _bmopf_source_schema_report(context)
    port_report = _bmopf_terminal_port_report(context)
    physical_mode_report = _bmopf_terminal_port_nullspace_mode_report(context)
    constitutive_map_report = _bmopf_terminal_constitutive_map_report(context)
    complex_constitutive_map_report = _bmopf_terminal_complex_constitutive_map_report(context)
    passive_network_current_map_report = _bmopf_passive_network_current_map_report(context)
    candidate_report = _bmopf_floating_neutral_candidate_report(context)
    lifecycle_report = _bmopf_opf_lifecycle_report(context)
    registry_report = _bmopf_opf_registry_report(context)
    component_report = _bmopf_component_report(context)
    current_law_report = _bmopf_current_law_report(context)
    coordinate_scale_report = isnothing(point) ? nothing :
        _bmopf_terminal_port_coordinate_scale_report(context, point)
    append!(report.findings, physical_report.findings)
    append!(report.findings, source_schema_report.findings)
    append!(report.findings, port_report.findings)
    include_port_physical_modes && append!(report.findings, physical_mode_report.findings)
    append!(report.findings, constitutive_map_report.findings)
    append!(report.findings, complex_constitutive_map_report.findings)
    append!(report.findings, passive_network_current_map_report.findings)
    append!(report.findings, candidate_report.findings)
    append!(report.findings, lifecycle_report.findings)
    append!(report.findings, registry_report.findings)
    append!(report.findings, component_report.findings)
    append!(report.findings, current_law_report.findings)
    !isnothing(coordinate_scale_report) && append!(report.findings, coordinate_scale_report.findings)
    for (key, value) in physical_report.metadata
        report.metadata[key] = value
    end
    merge!(report.metadata, source_schema_report.metadata)
    merge!(report.metadata, port_report.metadata)
    include_port_physical_modes && merge!(report.metadata, physical_mode_report.metadata)
    merge!(report.metadata, constitutive_map_report.metadata)
    merge!(report.metadata, complex_constitutive_map_report.metadata)
    merge!(report.metadata, passive_network_current_map_report.metadata)
    merge!(report.metadata, candidate_report.metadata)
    merge!(report.metadata, lifecycle_report.metadata)
    merge!(report.metadata, registry_report.metadata)
    merge!(report.metadata, component_report.metadata)
    merge!(report.metadata, current_law_report.metadata)
    !isnothing(coordinate_scale_report) && merge!(report.metadata, coordinate_scale_report.metadata)
    report.metadata[:bmopf_opf_context] = "BMOPFTools staged OPF context"
    report.metadata[:bmopf_opf_lifecycle] = string(BMOPFTools.opf_lifecycle(context))
    report.metadata[:bmopf_opf_owner] = "JuMP.Model"
    report.metadata[:bmopf_floating_neutral_candidates_enabled] =
        string(include_floating_neutral_candidates)
    report.metadata[:bmopf_floating_neutral_candidate_modes_applied] =
        string(length(candidate_modes))
    report.metadata[:bmopf_port_physical_modes_enabled] = string(include_port_physical_modes)
    report.metadata[:bmopf_port_physical_modes_applied] = string(length(port_physical_modes))
    report.metadata[:stages] *= ",bmopf_terminals,bmopf_source_schema,bmopf_terminal_ports,bmopf_terminal_port_physical_modes,bmopf_terminal_constitutive_maps,bmopf_terminal_complex_constitutive_maps,bmopf_passive_network_current_maps,bmopf_current_laws,bmopf_floating_neutral_candidates,bmopf_opf_lifecycle,bmopf_opf_registry,bmopf_components"
    !isnothing(coordinate_scale_report) && (report.metadata[:stages] *= ",bmopf_terminal_coordinate_scales")
    !isnothing(point) &&
        NLPDiagnostics._apply_point_provenance_guard!(report, point)
    sort!(
        report.findings;
        by = finding -> (-Int(finding.severity), string(finding.code)),
    )
    return report
end

end
