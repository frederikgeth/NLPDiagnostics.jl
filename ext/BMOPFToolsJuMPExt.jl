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
            nominal_scale = per_unit ? 1.0 : nothing,
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
    bmopf_start_completion_point(context; missing_value = 0.0,
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
    missing_value::Real = 0.0,
    label::AbstractString = "bmopf-partial-starts-completed",
)
    isfinite(missing_value) || throw(ArgumentError("missing_value must be finite"))
    owner = _bmopf_context_model(context)
    owner isa JuMP.Model || throw(ArgumentError("BMOPFTools.opf_model(context) did not return a JuMP.Model"))
    backend = JuMP.backend(owner)
    variables = MOI.get(backend, MOI.ListOfVariableIndices())
    values = Float64[]
    for variable in variables
        start = try
            MOI.get(backend, MOI.VariablePrimalStart(), variable)
        catch
            nothing
        end
        push!(values, start isa Real && isfinite(start) ? Float64(start) : Float64(missing_value))
    end
    return NLPDiagnostics.EvaluationPoint(variables, values; label = label)
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
        ("voltage_source", :cr_src, :ci_src, "cr", "ci"),
        ("ibr", :cri, :cii, "cri", "cii"),
    )
        for (id, component_result) in get(result, section, Dict())
            component = get(get(network, section, Dict()), string(id), nothing)
            component isa AbstractDict && component_result isa AbstractDict || continue
            terminals = string.(get(component, "terminal_map", String[]))
            family = real_family == :crd ? :load_current :
                     real_family == :cr_src ? :source_current : :ibr_current
            base = field_policy[family] == :si ? _bmopf_current_base(context, string(get(component, "bus", ""))) : 1.0
            isnothing(base) && continue
            for (position, terminal) in enumerate(terminals)
                entry = get(component_result, terminal, nothing)
                entry isa AbstractDict || continue
                key = if real_family == :crd
                    BMOPFTools.opf_load_current_key(string(id), position)
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
        point = NLPDiagnostics.EvaluationPoint(variables, values; label = label),
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

function _bmopf_constraint_result_descriptors(context)
    result = Dict{Tuple{Int,Union{Nothing,Int}},Dict{String,String}}()
    for key in BMOPFTools.opf_object_keys(context; kind = :constraint)
        object = try
            BMOPFTools.opf_object(context, key)
        catch
            nothing
        end
        object isa JuMP.ConstraintRef || continue
        index = JuMP.index(object)
        index isa MOI.ConstraintIndex || continue
        index_text = isnothing(key.index) ? "?" : sprint(show, key.index)
        result[(index.value, nothing)] = Dict{String,String}(
            "constraint_family" => string(key.family),
            "constraint_index" => index_text,
            "registered" => "true",
        )
    end
    return result
end

function _bmopf_row_constraint_support(activity, constraint_descriptors)
    source = activity.source
    descriptor = get(constraint_descriptors, (source.index, source.subindex), nothing)
    isnothing(descriptor) && (descriptor = get(
        constraint_descriptors, (source.index, nothing), nothing,
    ))
    isnothing(descriptor) && return Dict{String,String}(
        "constraint_family" => "unregistered_constraint",
        "constraint_index" => "?",
        "registered" => "false",
    )
    return descriptor
end

"""Return a compact semantic map for every evaluated scalar constraint row."""
function _bmopf_constraint_semantic_row_map(context, evaluation)
    descriptors = _bmopf_constraint_result_descriptors(context)
    rows = Dict{String,Any}()
    for (row, source) in enumerate(evaluation.constraint_sources)
        descriptor = get(descriptors, (source.index, source.subindex), nothing)
        isnothing(descriptor) && (descriptor = get(
            descriptors, (source.index, nothing), nothing,
        ))
        if isnothing(descriptor)
            rows[string(row)] = Dict{String,Any}(
                "constraint_family" => "unregistered_constraint",
                "constraint_index" => "?",
                "registered" => false,
            )
        else
            rows[string(row)] = Dict{String,Any}(
                "constraint_family" => descriptor["constraint_family"],
                "constraint_index" => descriptor["constraint_index"],
                "registered" => true,
            )
        end
    end
    return rows
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
                # The declared nominal scale is in model coordinates. A per-unit
                # voltage has nominal coordinate 1, not its physical V base.
                nominal_scale = per_unit ? 1.0 : nothing,
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
function _bmopf_build_passive_network_current_maps(context)
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
        :network, "passive_ybus", "passive_current_from_voltage",
        ["voltage_real", "voltage_imag"], labels, matrix;
        equation_labels = vcat(
            ["current_real/$(node[1])/$(node[2])" for node in ybus.nodes],
            ["current_imag/$(node[1])/$(node[2])" for node in ybus.nodes],
        ),
        metadata = Dict(
            "source" => "BMOPFTools.ybus_passive",
            "map_role" => "passive_network_current",
            "quantity" => "current_from_voltage",
            "units" => "A_from_V_SI",
            "node_count" => string(n),
            "nonzero_count" => string(SparseArrays.nnz(ybus.Y)),
            "coordinate_basis" => "SI voltage/current",
        ),
    )]
end

"""Return the passive-network current-from-voltage map, when Ybus is available."""
function _bmopf_passive_network_current_maps(context)
    _bmopf_context_model(context)
    return _bmopf_build_passive_network_current_maps(context)
end

"""Validate passive-network current maps and report public-Ybus coverage limits."""
function _bmopf_passive_network_current_map_report(context)
    maps = _bmopf_build_passive_network_current_maps(context)
    report = NLPDiagnostics._component_port_constitutive_map_findings(maps)
    report.metadata[:bmopf_passive_network_current_map_count] = string(length(maps))
    report.metadata[:bmopf_passive_network_current_map_basis] = "BMOPFTools.ybus_passive"
    if !isempty(maps)
        metadata = first(maps).metadata
        report.metadata[:bmopf_passive_network_node_count] = get(metadata, "node_count", "0")
        report.metadata[:bmopf_passive_network_nonzero_count] = get(metadata, "nonzero_count", "0")
        if !isnothing(BMOPFTools.opf_bases(context))
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
             NLPDiagnostics.analyze(JuMP.backend(owner); point = point, kwargs...) :
             NLPDiagnostics.analyze(JuMP.backend(owner); point = point, kwargs...,
                                    expected_modes = resolved_expected_modes)
    physical_report = NLPDiagnostics.bmopf_terminal_report(BMOPFTools.opf_network(context))
    port_report = _bmopf_terminal_port_report(context)
    physical_mode_report = _bmopf_terminal_port_nullspace_mode_report(context)
    constitutive_map_report = _bmopf_terminal_constitutive_map_report(context)
    complex_constitutive_map_report = _bmopf_terminal_complex_constitutive_map_report(context)
    passive_network_current_map_report = _bmopf_passive_network_current_map_report(context)
    candidate_report = _bmopf_floating_neutral_candidate_report(context)
    lifecycle_report = _bmopf_opf_lifecycle_report(context)
    registry_report = _bmopf_opf_registry_report(context)
    component_report = _bmopf_component_report(context)
    coordinate_scale_report = isnothing(point) ? nothing :
        _bmopf_terminal_port_coordinate_scale_report(context, point)
    append!(report.findings, physical_report.findings)
    append!(report.findings, port_report.findings)
    include_port_physical_modes && append!(report.findings, physical_mode_report.findings)
    append!(report.findings, constitutive_map_report.findings)
    append!(report.findings, complex_constitutive_map_report.findings)
    append!(report.findings, passive_network_current_map_report.findings)
    append!(report.findings, candidate_report.findings)
    append!(report.findings, lifecycle_report.findings)
    append!(report.findings, registry_report.findings)
    append!(report.findings, component_report.findings)
    !isnothing(coordinate_scale_report) && append!(report.findings, coordinate_scale_report.findings)
    for (key, value) in physical_report.metadata
        report.metadata[key] = value
    end
    merge!(report.metadata, port_report.metadata)
    include_port_physical_modes && merge!(report.metadata, physical_mode_report.metadata)
    merge!(report.metadata, constitutive_map_report.metadata)
    merge!(report.metadata, complex_constitutive_map_report.metadata)
    merge!(report.metadata, passive_network_current_map_report.metadata)
    merge!(report.metadata, candidate_report.metadata)
    merge!(report.metadata, lifecycle_report.metadata)
    merge!(report.metadata, registry_report.metadata)
    merge!(report.metadata, component_report.metadata)
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
    report.metadata[:stages] *= ",bmopf_terminals,bmopf_terminal_ports,bmopf_terminal_port_physical_modes,bmopf_terminal_constitutive_maps,bmopf_terminal_complex_constitutive_maps,bmopf_passive_network_current_maps,bmopf_floating_neutral_candidates,bmopf_opf_lifecycle,bmopf_opf_registry,bmopf_components"
    !isnothing(coordinate_scale_report) && (report.metadata[:stages] *= ",bmopf_terminal_coordinate_scales")
    return report
end

end
