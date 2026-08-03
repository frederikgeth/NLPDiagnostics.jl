module BMOPFToolsJuMPExt

import BMOPFTools
import JuMP
import NLPDiagnostics
import MathOptInterface
import LinearAlgebra

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

_bmopf_port_id(component::Symbol) = component == :real ? "voltage_real" : "voltage_imag"
_bmopf_representation(component::Symbol) = component == :real ? :rectangular_real : :rectangular_imag

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
voltage/current bases; `:model` accepts model-coordinate values directly. All
other coordinates receive explicit `fallback_value`. The returned coverage
counts distinguish mapped registry coordinates, unresolved saved records, and
fallback coordinates. Thus this is a labeled partial-result probe, never a
claim that a saved result completely represents every auxiliary model
coordinate.
"""
function _bmopf_result_voltage_point(
    context,
    result::AbstractDict;
    result_units::Symbol = :si,
    fallback_value::Real = 0.0,
    label::AbstractString = "bmopf-result-voltage-partial",
)
    result_units in (:si, :model) || throw(ArgumentError("result_units must be :si or :model"))
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
        base = result_units == :si ? _bmopf_voltage_base(context, string(bus)) : 1.0
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
        base = result_units == :si ? _bmopf_voltage_base(context, string(bus)) : 1.0
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
                base = result_units == :si ? _bmopf_current_base(context, string(get(line, bus_field, ""))) : 1.0
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
            base = result_units == :si ? _bmopf_current_base(context, string(get(component, "bus", ""))) : 1.0
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
                    power_base = result_units == :si ? _bmopf_power_base(context) : 1.0
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
        base = result_units == :si ? _bmopf_current_base(context, string(get(switch, "bus_from", ""))) : 1.0
        isnothing(base) && continue
        for (position, terminal) in enumerate(terminals)
            entry = get(switch_result, terminal, nothing)
            entry isa AbstractDict || continue
            assign_scaled!(BMOPFTools.opf_switch_current_key(string(switch_id), position), get(entry, "cr", nothing), base)
            assign_scaled!(BMOPFTools.opf_switch_current_key(string(switch_id), position; component = :imag), get(entry, "ci", nothing), base)
        end
    end
    for (bus, terminals) in get(result, "ground", Dict())
        base = result_units == :si ? _bmopf_current_base(context, string(bus)) : 1.0
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

"""Fingerprint the coordinate magnitude implied by a saved-result unit choice."""
function _bmopf_result_unit_report(context, result::AbstractDict;
                                   result_units::Symbol)
    result_units in (:si, :model) || throw(ArgumentError("result_units must be :si or :model"))
    report = NLPDiagnostics.DiagnosticReport()
    report.metadata[:bmopf_saved_result_unit_report_stage] = "bmopf_saved_result_units"
    report.metadata[:bmopf_saved_result_units] = string(result_units)
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
                push!(ratios, result_units == :si ? magnitude / base : magnitude)
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
                "sample_count" => length(ratios),
                "median_coordinate_magnitude" => median_ratio,
                "heuristic_expected_band" => "[0.05, 20]",
            ])],
            suggested_actions = ["Confirm the numerical convention of the result file against BMOPFTools public voltage bases.", "Pass result_units = :si only for physical-voltage result fields; use :model only for already-scaled staged coordinates."],
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
        result_units, fallback_value, label,
    )
    mapping_report = _bmopf_result_mapping_report(mapping)
    _bmopf_append_report!(mapping_report,
                          _bmopf_result_unit_report(context, result; result_units))
    case_metadata = Dict{String,Any}(
        "point_policy" => "saved_result",
        "point_provenance" => "saved BMOPF result with explicit fallback for unmapped coordinates",
        "saved_result_units" => string(result_units),
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

function NLPDiagnostics.profile_result_data(result::NLPDiagnostics.BMOPFProfileResult)
    return Dict{String,Any}(
        "profile" => NLPDiagnostics.profile_result_data(result.profile),
        "bmopf_context_report" => NLPDiagnostics.report_data(result.context_report),
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
    report = NLPDiagnostics.analyze_component_rank_persistence(backend, evaluations;
        components = _bmopf_component_metadata(context), expected_modes = modes, kwargs...,
    )
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
    return semantics
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
    variables = MOI.get(JuMP.backend(owner), MOI.ListOfVariableIndices())
    report = NLPDiagnostics._component_port_metadata_findings(ports; model_variables = variables)
    for partial in (
        NLPDiagnostics._component_port_coordinate_map_findings(ports, maps; model_variables = variables),
        NLPDiagnostics._component_port_coordinate_semantics_findings(ports, semantics, maps),
    )
        append!(report.findings, partial.findings)
        merge!(report.metadata, partial.metadata)
    end
    report.metadata[:bmopf_terminal_port_count] = string(length(ports))
    report.metadata[:bmopf_terminal_port_coordinate_map_count] = string(length(maps))
    report.metadata[:bmopf_terminal_port_coordinate_semantics_count] = string(length(semantics))
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
finding into a proven model-coordinate gauge.
"""
function _bmopf_analyze_opf(
    context;
    point::Union{Nothing,NLPDiagnostics.EvaluationPoint} = nothing,
    include_floating_neutral_candidates::Bool = false,
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
    resolved_expected_modes = if isnothing(expected_modes)
        isempty(candidate_modes) ? nothing : candidate_modes
    else
        vcat(expected_modes, candidate_modes)
    end
    report = isnothing(resolved_expected_modes) ?
             NLPDiagnostics.analyze(JuMP.backend(owner); point = point, kwargs...) :
             NLPDiagnostics.analyze(JuMP.backend(owner); point = point, kwargs...,
                                    expected_modes = resolved_expected_modes)
    physical_report = NLPDiagnostics.bmopf_terminal_report(BMOPFTools.opf_network(context))
    port_report = _bmopf_terminal_port_report(context)
    candidate_report = _bmopf_floating_neutral_candidate_report(context)
    lifecycle_report = _bmopf_opf_lifecycle_report(context)
    registry_report = _bmopf_opf_registry_report(context)
    component_report = _bmopf_component_report(context)
    coordinate_scale_report = isnothing(point) ? nothing :
        _bmopf_terminal_port_coordinate_scale_report(context, point)
    append!(report.findings, physical_report.findings)
    append!(report.findings, port_report.findings)
    append!(report.findings, candidate_report.findings)
    append!(report.findings, lifecycle_report.findings)
    append!(report.findings, registry_report.findings)
    append!(report.findings, component_report.findings)
    !isnothing(coordinate_scale_report) && append!(report.findings, coordinate_scale_report.findings)
    for (key, value) in physical_report.metadata
        report.metadata[key] = value
    end
    merge!(report.metadata, port_report.metadata)
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
    report.metadata[:stages] *= ",bmopf_terminals,bmopf_terminal_ports,bmopf_floating_neutral_candidates,bmopf_opf_lifecycle,bmopf_opf_registry,bmopf_components"
    !isnothing(coordinate_scale_report) && (report.metadata[:stages] *= ",bmopf_terminal_coordinate_scales")
    return report
end

end
