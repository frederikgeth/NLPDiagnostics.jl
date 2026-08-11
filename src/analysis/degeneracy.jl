_entity_row_key(reference::EntityRef) =
    (reference.kind, reference.index, reference.subindex)

"""
    expected_nullspace_modes(model, evaluation)

Extension hook for domain packages. Return named expected right-nullspace
directions in model variable coordinates. The generic default declares no
physical or representational gauges.
"""
expected_nullspace_modes(model::MOI.ModelLike, evaluation::NumericalEvaluation) =
    ExpectedNullspaceMode[]

"""Optional domain-plugin component declarations; the generic default is empty."""
component_metadata(model::MOI.ModelLike) = ComponentMetadata[]
component_metadata(model::ModelSnapshot) = ComponentMetadata[]
"""Report expected-rank declaration coverage for supplied component metadata."""
function component_rank_capability_report(
    components::AbstractVector{<:ComponentMetadata};
    source::AbstractString = "domain-plugin component metadata",
    stage::Symbol = :component_rank_capability,
)
    report = DiagnosticReport()
    declared = count(component -> !isnothing(component.expected_rank), components)
    unavailable = length(components) - declared
    report.metadata[:stage] = string(stage)
    report.metadata[:component_metadata_count] = string(length(components))
    report.metadata[:component_expected_rank_declared_count] = string(declared)
    report.metadata[:component_expected_rank_unavailable_count] = string(unavailable)
    report.metadata[:component_expected_rank_coverage] = isempty(components) ?
        "unavailable" : string(declared / length(components))
    unavailable == 0 && return report
    missing_components = filter(component -> isnothing(component.expected_rank), components)
    affected = EntityRef[]
    for component in missing_components
        append!(affected, (EntityRef(:variable, variable.value) for variable in component.variables))
        append!(affected, component.constraints)
    end
    push!(report, Finding(:component_expected_rank_unavailable;
        severity = SeverityInfo,
        domain = RepresentationalIssue,
        basis = StructuralProof,
        confidence = ConfidenceCertain,
        observation = "$unavailable component declaration(s) do not provide an expected physical rank.",
        why_it_matters = "Component-rank comparison can only interpret observed local rank against a domain-plugin declaration; absent declarations must not be interpreted as zero rank loss or full rank.",
        evidence = [Evidence("Component expected-rank capability"; details = [
            "component_count" => length(components),
            "expected_rank_declared_count" => declared,
            "expected_rank_unavailable_count" => unavailable,
            "expected_rank_coverage" => isempty(components) ? "unavailable" : string(declared / length(components)),
            "source" => String(source),
        ])],
        affected = unique(affected),
        suggested_actions = [
            "Add expected_rank declarations only when component equations and coordinate scopes are physically justified.",
            "Use generic Jacobian and structural persistence evidence independently of this capability boundary.",
        ],
    ))
    return report
end
"""Optional plugin declarations of component model-coordinate semantics."""
component_coordinate_semantics(model::MOI.ModelLike) = ComponentCoordinateSemantics[]
component_coordinate_semantics(model::ModelSnapshot) = ComponentCoordinateSemantics[]
component_constraint_scale_semantics(model::MOI.ModelLike) = ComponentConstraintScaleSemantics[]
component_constraint_scale_semantics(model::ModelSnapshot) = ComponentConstraintScaleSemantics[]
"""Optional PowerModels adapter hook; extended only when PowerModels is loaded."""
powermodels_component_metadata(model) = ComponentMetadata[]
"""Optional PowerModels expected-rank capability report hook."""
powermodels_component_rank_capability_report(model) = DiagnosticReport()
"""Optional PowerModels public-API capability report hook."""
powermodels_capability_report(model) = DiagnosticReport()
"""Optional PowerModels data-level reference-bus report hook."""
powermodels_reference_bus_report(model) = DiagnosticReport()
"""Optional PowerModels public-variable to MOI-index adapter hook."""
powermodels_variable_indices(model, key::Symbol; network = nothing) =
    Dict{Tuple{Any,Any},MOI.VariableIndex}()
"""Optional PowerModels scalar-angle expected-gauge adapter hook."""
powermodels_angle_gauge_modes(model, evaluation; kwargs...) = ExpectedNullspaceMode[]
"""Optional PowerModels-to-owning-JuMP-model adapter hook."""
powermodels_jump_model(model; kwargs...) = nothing
"""Optional PowerModels expected-angle-mode degeneracy analysis entry point."""
function powermodels_analyze_degeneracy(model, point; kwargs...)
    throw(ArgumentError("PowerModels support is not loaded for this model"))
end
"""Optional PowerModels expected-angle-mode active-set analysis entry point."""
function powermodels_analyze_active_set(model, point; kwargs...)
    throw(ArgumentError("PowerModels support is not loaded for this model"))
end
"""Optional PowerModels expected-angle-mode reduced-Hessian persistence entry point."""
function powermodels_analyze_reduced_hessian_persistence(model, snapshots; kwargs...)
    throw(ArgumentError("PowerModels support is not loaded for this model"))
end
"""Optional PowerModels cross-point Jacobian persistence entry point."""
function powermodels_analyze_jacobian_rank_persistence(model, points; kwargs...)
    throw(ArgumentError("PowerModels support is not loaded for this model"))
end
"""Optional PowerModels cross-point component-rank persistence entry point."""
function powermodels_analyze_component_rank_persistence(model, points; kwargs...)
    throw(ArgumentError("PowerModels support is not loaded for this model"))
end
function _bmopf_extension(name::Symbol, message::String)
    extension = Base.get_extension(@__MODULE__, name)
    isnothing(extension) && throw(ArgumentError(message))
    return extension
end

"""Optional BMOPFTools terminal/grounding adapter entry point."""
bmopf_terminal_report(net) = _bmopf_extension(:BMOPFToolsExt,
    "BMOPFTools support is not loaded; install BMOPFTools to analyze BMOPF terminal data")._bmopf_terminal_report(net)
"""Optional BMOPFTools staged-OPF diagnostic entry point."""
bmopf_analyze_opf(context; kwargs...) = _bmopf_extension(:BMOPFToolsJuMPExt,
    "BMOPFTools and JuMP support are required to analyze a staged BMOPF OPF context")._bmopf_analyze_opf(context; kwargs...)
"""Optional BMOPFTools staged-OPF profile-case entry point."""
bmopf_profile_case(context, case; kwargs...) = _bmopf_extension(:BMOPFToolsJuMPExt,
    "BMOPFTools and JuMP support are required to profile a staged BMOPF OPF context")._bmopf_profile_case(context, case; kwargs...)
"""Run BMOPF semantic/context diagnostics at one explicit evaluated point without generic Jacobian profiling."""
bmopf_context_profile_report(context, point; kwargs...) = _bmopf_extension(:BMOPFToolsJuMPExt,
    "BMOPFTools and JuMP support are required for BMOPF context profiling")._bmopf_context_profile_report(context, point; kwargs...)
"""Optional BMOPFTools build-and-profile benchmark entry point."""
bmopf_build_and_profile(network, case_builder; kwargs...) = _bmopf_extension(:BMOPFToolsJuMPExt,
    "BMOPFTools' JuMP/IPOPT staged-build extension is required to build and profile a BMOPF network")._bmopf_build_and_profile(network, case_builder; kwargs...)
"""Optional BMOPFTools build-and-structurally-analyze benchmark entry point."""
bmopf_build_and_analyze_opf(network; kwargs...) = _bmopf_extension(:BMOPFToolsJuMPExt,
    "BMOPFTools' JuMP/IPOPT staged-build extension is required to build and analyze a BMOPF network")._bmopf_build_and_analyze_opf(network; kwargs...)
"""Optional BMOPFTools staged-OPF initialization-point entry point."""
bmopf_initialization_point(context; kwargs...) = _bmopf_extension(:BMOPFToolsJuMPExt,
    "BMOPFTools and JuMP support are required to inspect staged BMOPF initialization")._bmopf_initialization_point(context; kwargs...)
"""Explicitly apply BMOPFTools' public generated start-value policy and return its point."""
bmopf_set_start_values!(context; kwargs...) = _bmopf_extension(:BMOPFToolsJuMPExt,
    "BMOPFTools and JuMP support are required to apply staged BMOPF start values")._bmopf_set_start_values!(context; kwargs...)
"""Construct a non-mutating complete point from BMOPF starts plus an explicit fallback."""
bmopf_start_completion_point(context; kwargs...) = _bmopf_extension(:BMOPFToolsJuMPExt,
    "BMOPFTools and JuMP support are required to complete staged BMOPF start values")._bmopf_start_completion_point(context; kwargs...)
"""Map saved BMOPF result coordinates into a labeled partial evaluation point."""
bmopf_result_voltage_point(context, result; kwargs...) = _bmopf_extension(:BMOPFToolsJuMPExt,
    "BMOPFTools and JuMP support are required to map a BMOPF result point")._bmopf_result_voltage_point(context, result; kwargs...)
"""Report the representational coverage of one `bmopf_result_voltage_point` mapping."""
bmopf_result_mapping_report(mapping) = _bmopf_extension(:BMOPFToolsJuMPExt,
    "BMOPFTools and JuMP support are required to report BMOPF saved-result mapping coverage")._bmopf_result_mapping_report(mapping)
"""Return the explicit BMOPF saved-result field/unit catalog."""
bmopf_result_field_catalog() = _bmopf_extension(:BMOPFToolsJuMPExt,
    "BMOPFTools and JuMP support are required to inspect the BMOPF saved-result field catalog")._bmopf_result_field_catalog()
"""Attribute scalar feasibility violations to supported BMOPF variable families."""
bmopf_constraint_feasibility_field_attribution(context, result; kwargs...) =
    _bmopf_extension(:BMOPFToolsJuMPExt,
        "BMOPFTools and JuMP support are required for BMOPF feasibility-field attribution")._bmopf_constraint_feasibility_field_attribution(context, result; kwargs...)
"""Return the BMOPFTools semantic family/index for every evaluated scalar row."""
bmopf_constraint_semantic_row_map(context, evaluation) =
    _bmopf_extension(:BMOPFToolsJuMPExt,
        "BMOPFTools and JuMP support are required for BMOPF constraint-row semantics")._bmopf_constraint_semantic_row_map(context, evaluation)
"""Attribute Jacobian row-scale evidence using public BMOPFTools row families."""
bmopf_jacobian_row_family_scale_attribution(context, evaluation) =
    _bmopf_extension(:BMOPFToolsJuMPExt,
        "BMOPFTools and JuMP support are required for BMOPF Jacobian row-family scale attribution")._bmopf_jacobian_row_family_scale_attribution(context, evaluation)
"""Run a controlled BMOPF Jacobian row-family scaling experiment."""
bmopf_jacobian_row_family_scaling_experiment(context, evaluation; kwargs...) =
    _bmopf_extension(:BMOPFToolsJuMPExt,
        "BMOPFTools and JuMP support are required for BMOPF Jacobian row-family scaling experiments")._bmopf_jacobian_row_family_scaling_experiment(context, evaluation; kwargs...)
"""Report complete public semantic-registry coverage for evaluated BMOPF rows."""
bmopf_constraint_registry_coverage_report(context, evaluation) =
    _bmopf_extension(:BMOPFToolsJuMPExt,
        "BMOPFTools and JuMP support are required for BMOPF constraint-registry coverage")._bmopf_constraint_registry_coverage_report(context, evaluation)
"""Run a local Jacobian row-family perturbation using BMOPFTools semantics."""
bmopf_analyze_jacobian_row_family_perturbations(context, evaluation; kwargs...) =
    _bmopf_extension(:BMOPFToolsJuMPExt,
        "BMOPFTools and JuMP support are required for BMOPF Jacobian row-family perturbations")._bmopf_analyze_jacobian_row_family_perturbations(context, evaluation; kwargs...)
"""Build a labeled profile case and qualification report from a saved BMOPF result."""
bmopf_saved_result_profile_case(name, context, result; kwargs...) = _bmopf_extension(:BMOPFToolsJuMPExt,
    "BMOPFTools and JuMP support are required to profile a saved BMOPF result")._bmopf_saved_result_profile_case(name, context, result; kwargs...)
"""Profile a saved BMOPF result and retain its mapping qualification automatically."""
bmopf_profile_saved_result(context, name, result; kwargs...) = _bmopf_extension(:BMOPFToolsJuMPExt,
    "BMOPFTools and JuMP support are required to profile a saved BMOPF result")._bmopf_profile_saved_result(context, name, result; kwargs...)
"""Optional BMOPFTools explicit synthetic coordinate-probe point entry point."""
bmopf_coordinate_probe_point(context; kwargs...) = _bmopf_extension(:BMOPFToolsJuMPExt,
    "BMOPFTools and JuMP support are required to construct a staged BMOPF coordinate probe")._bmopf_coordinate_probe_point(context; kwargs...)
"""Optional BMOPFTools staged-OPF initialization analysis entry point."""
bmopf_analyze_initialization(context; kwargs...) = _bmopf_extension(:BMOPFToolsJuMPExt,
    "BMOPFTools and JuMP support are required to analyze staged BMOPF initialization")._bmopf_analyze_initialization(context; kwargs...)
"""Optional BMOPFTools local degeneracy analysis entry point."""
bmopf_analyze_degeneracy(context, point; kwargs...) = _bmopf_extension(:BMOPFToolsJuMPExt,
    "BMOPFTools and JuMP support are required to analyze staged BMOPF OPF degeneracy")._bmopf_analyze_degeneracy(context, point; kwargs...)
"""Optional BMOPFTools active-set analysis entry point."""
bmopf_analyze_active_set(context, point; kwargs...) = _bmopf_extension(:BMOPFToolsJuMPExt,
    "BMOPFTools and JuMP support are required to analyze staged BMOPF OPF active sets")._bmopf_analyze_active_set(context, point; kwargs...)
"""Optional BMOPFTools reduced-Hessian persistence entry point."""
bmopf_analyze_reduced_hessian_persistence(context, snapshots; kwargs...) = _bmopf_extension(:BMOPFToolsJuMPExt,
    "BMOPFTools and JuMP support are required to analyze staged BMOPF reduced-Hessian persistence")._bmopf_analyze_reduced_hessian_persistence(context, snapshots; kwargs...)
"""Optional BMOPFTools Jacobian-rank persistence entry point."""
bmopf_analyze_jacobian_rank_persistence(context, points; kwargs...) = _bmopf_extension(:BMOPFToolsJuMPExt,
    "BMOPFTools and JuMP support are required to analyze staged BMOPF Jacobian-rank persistence")._bmopf_analyze_jacobian_rank_persistence(context, points; kwargs...)
"""Optional BMOPFTools sparse-QR right-nullspace persistence entry point."""
bmopf_analyze_sparse_qr_nullspace_persistence(context, points; kwargs...) = _bmopf_extension(:BMOPFToolsJuMPExt,
    "BMOPFTools and JuMP support are required to analyze staged BMOPF sparse-QR nullspace persistence")._bmopf_analyze_sparse_qr_nullspace_persistence(context, points; kwargs...)
"""Optional BMOPFTools component-rank persistence entry point."""
bmopf_analyze_component_rank_persistence(context, points; kwargs...) = _bmopf_extension(:BMOPFToolsJuMPExt,
    "BMOPFTools and JuMP support are required to analyze staged BMOPF component-rank persistence")._bmopf_analyze_component_rank_persistence(context, points; kwargs...)
"""Optional BMOPFTools staged-OPF terminal-port metadata hook."""
bmopf_terminal_port_metadata(context) = _bmopf_extension(:BMOPFToolsJuMPExt,
    "BMOPFTools and JuMP support are required to inspect staged BMOPF terminal ports")._bmopf_terminal_port_metadata(context)
"""Optional BMOPFTools staged-OPF terminal-to-model-coordinate map hook."""
bmopf_terminal_port_coordinate_maps(context) = _bmopf_extension(:BMOPFToolsJuMPExt,
    "BMOPFTools and JuMP support are required to inspect staged BMOPF terminal ports")._bmopf_terminal_port_coordinate_maps(context)
"""Optional BMOPFTools staged-OPF terminal-coordinate semantics hook."""
bmopf_terminal_port_coordinate_semantics(context) = _bmopf_extension(:BMOPFToolsJuMPExt,
    "BMOPFTools and JuMP support are required to inspect staged BMOPF terminal ports")._bmopf_terminal_port_coordinate_semantics(context)
"""Optional BMOPFTools staged-OPF component-to-bus port-connection hook."""
bmopf_terminal_port_connections(context) = _bmopf_extension(:BMOPFToolsJuMPExt,
    "BMOPFTools and JuMP support are required to inspect staged BMOPF port connections")._bmopf_terminal_port_connections(context)
"""Return the BMOPFTools component/bus port assembly summary."""
bmopf_terminal_port_assembly(context) = _bmopf_extension(:BMOPFToolsJuMPExt,
    "BMOPFTools and JuMP support are required to inspect staged BMOPF port assembly")._bmopf_terminal_port_assembly(context)
"""Report BMOPFTools port assembly connected components and endpoint validity."""
bmopf_terminal_port_assembly_report(context) = _bmopf_extension(:BMOPFToolsJuMPExt,
    "BMOPFTools and JuMP support are required to report staged BMOPF port assembly")._bmopf_terminal_port_assembly_report(context)
"""Return static BMOPFTools nonlinear-current law fingerprints."""
bmopf_current_law_fingerprints(context) = _bmopf_extension(:BMOPFToolsJuMPExt,
    "BMOPFTools and JuMP support are required to inspect staged BMOPF current laws")._bmopf_current_law_fingerprints_public(context)
"""Report BMOPFTools nonlinear-current law domains and derivative hazards."""
bmopf_current_law_report(context) = _bmopf_extension(:BMOPFToolsJuMPExt,
    "BMOPFTools and JuMP support are required to report staged BMOPF current laws")._bmopf_current_law_report_public(context)
"""Probe BMOPF current laws at an explicit evaluation point or saved result."""
bmopf_current_law_operating_point_probes(context, source; kwargs...) =
    _bmopf_extension(:BMOPFToolsJuMPExt,
        "BMOPFTools and JuMP support are required for current-law operating-point probes")._bmopf_current_law_operating_point_probes_public(context, source; kwargs...)
"""Return typed public Volt-var/Volt-watt observations at one point."""
bmopf_controller_curve_operating_point_observations(context, source; kwargs...) =
    _bmopf_extension(:BMOPFToolsJuMPExt,
        "BMOPFTools and JuMP support are required for controller-curve observations")._bmopf_controller_curve_operating_point_observations_public(context, source; kwargs...)
"""Report domain and derivative evidence for BMOPF current laws at one point."""
bmopf_current_law_operating_point_report(context, source; kwargs...) =
    _bmopf_extension(:BMOPFToolsJuMPExt,
        "BMOPFTools and JuMP support are required for current-law operating-point reports")._bmopf_current_law_operating_point_report_public(context, source; kwargs...)
"""Compare BMOPF current-law operating-point probes across explicit snapshots."""
bmopf_current_law_operating_point_persistence(context, sources; kwargs...) =
    _bmopf_extension(:BMOPFToolsJuMPExt,
        "BMOPFTools and JuMP support are required for current-law persistence reports")._bmopf_current_law_operating_point_persistence_public(context, sources; kwargs...)
"""Probe BMOPF current laws over explicitly captured solver iterates."""
bmopf_current_law_operating_point_trace(context, trace; kwargs...) =
    _bmopf_extension(:BMOPFToolsJuMPExt,
        "BMOPFTools and JuMP support are required for solver-iterate current-law traces")._bmopf_current_law_operating_point_trace_public(context, trace; kwargs...)
"""Return BMOPFTools rectangular terminal-current coordinate ports."""
bmopf_terminal_current_port_metadata(context) = _bmopf_extension(:BMOPFToolsJuMPExt,
    "BMOPFTools and JuMP support are required to inspect staged BMOPF current ports")._bmopf_terminal_current_port_metadata(context)
"""Return explicit BMOPFTools terminal-current to MOI-variable maps."""
bmopf_terminal_current_port_coordinate_maps(context) = _bmopf_extension(:BMOPFToolsJuMPExt,
    "BMOPFTools and JuMP support are required to inspect staged BMOPF current maps")._bmopf_terminal_current_port_coordinate_maps(context)
"""Return physical semantics for BMOPFTools terminal-current coordinates."""
bmopf_terminal_current_port_coordinate_semantics(context) = _bmopf_extension(:BMOPFToolsJuMPExt,
    "BMOPFTools and JuMP support are required to inspect staged BMOPF current semantics")._bmopf_terminal_current_port_coordinate_semantics(context)
"""Validate BMOPFTools terminal-current port coverage."""
bmopf_terminal_current_port_report(context) = _bmopf_extension(:BMOPFToolsJuMPExt,
    "BMOPFTools and JuMP support are required to report staged BMOPF current-port coverage")._bmopf_terminal_current_port_report(context)
"""Return BMOPFTools expected physical terminal-port null modes."""
bmopf_terminal_port_nullspace_modes(context) = _bmopf_extension(:BMOPFToolsJuMPExt,
    "BMOPFTools and JuMP support are required to inspect staged BMOPF physical port modes")._bmopf_terminal_port_nullspace_modes(context)
"""Return semantic labels for BMOPFTools physical terminal-port null modes."""
bmopf_terminal_port_nullspace_mode_semantics(context) = _bmopf_extension(:BMOPFToolsJuMPExt,
    "BMOPFTools and JuMP support are required to inspect staged BMOPF physical port-mode semantics")._bmopf_terminal_port_nullspace_mode_semantics(context)
"""Report BMOPFTools physical terminal-port mode declarations."""
bmopf_terminal_port_nullspace_mode_report(context) = _bmopf_extension(:BMOPFToolsJuMPExt,
    "BMOPFTools and JuMP support are required to report staged BMOPF physical port modes")._bmopf_terminal_port_nullspace_mode_report(context)
"""Return a BMOPFTools plugin-specific coordinate scope for local tangent checks."""
bmopf_expected_mode_tangent_policy(context; kwargs...) = _bmopf_extension(:BMOPFToolsJuMPExt,
    "BMOPFTools and JuMP support are required to construct a BMOPF expected-mode tangent policy")._bmopf_expected_mode_tangent_policy(context; kwargs...)
"""Return BMOPFTools-derived linear constitutive voltage maps."""
bmopf_terminal_constitutive_maps(context) = _bmopf_extension(:BMOPFToolsJuMPExt,
    "BMOPFTools and JuMP support are required to inspect staged BMOPF constitutive maps")._bmopf_terminal_constitutive_maps(context)
"""Validate BMOPFTools constitutive-map dimensions and coefficients."""
bmopf_terminal_constitutive_map_report(context) = _bmopf_extension(:BMOPFToolsJuMPExt,
    "BMOPFTools and JuMP support are required to report staged BMOPF constitutive maps")._bmopf_terminal_constitutive_map_report(context)
"""Return phase-aware complex transformer constitutive maps as real block matrices."""
bmopf_terminal_complex_constitutive_maps(context) = _bmopf_extension(:BMOPFToolsJuMPExt,
    "BMOPFTools and JuMP support are required to inspect phase-aware BMOPF constitutive maps")._bmopf_terminal_complex_constitutive_maps(context)
"""Validate phase-aware complex transformer constitutive maps."""
bmopf_terminal_complex_constitutive_map_report(context) = _bmopf_extension(:BMOPFToolsJuMPExt,
    "BMOPFTools and JuMP support are required to report phase-aware BMOPF constitutive maps")._bmopf_terminal_complex_constitutive_map_report(context)
"""Return the passive-network current-from-voltage map from public BMOPFTools Ybus."""
bmopf_passive_network_current_maps(context; basis::Symbol = :si) = _bmopf_extension(:BMOPFToolsJuMPExt,
    "BMOPFTools and JuMP support are required to inspect passive network current maps")._bmopf_passive_network_current_maps(context; basis = basis)
"""Validate passive-network current maps and their unit basis."""
bmopf_passive_network_current_map_report(context; basis::Symbol = :si) = _bmopf_extension(:BMOPFToolsJuMPExt,
    "BMOPFTools and JuMP support are required to report passive network current maps")._bmopf_passive_network_current_map_report(context; basis = basis)
"""Optional BMOPFTools staged-OPF terminal-port validation report hook."""
bmopf_terminal_port_report(context) = _bmopf_extension(:BMOPFToolsJuMPExt,
    "BMOPFTools and JuMP support are required to inspect staged BMOPF terminal ports")._bmopf_terminal_port_report(context)
"""Optional BMOPFTools staged-OPF terminal-coordinate scale report hook."""
bmopf_terminal_port_coordinate_scale_report(context, point; kwargs...) = _bmopf_extension(:BMOPFToolsJuMPExt,
    "BMOPFTools and JuMP support are required to inspect staged BMOPF terminal-coordinate scales")._bmopf_terminal_port_coordinate_scale_report(context, point; kwargs...)
"""Optional BMOPFTools physical floating-neutral candidate-mode hook."""
bmopf_floating_neutral_candidate_modes(context) = _bmopf_extension(:BMOPFToolsJuMPExt,
    "BMOPFTools and JuMP support are required to inspect staged BMOPF floating-neutral candidates")._bmopf_floating_neutral_candidate_modes(context)
"""Optional BMOPFTools physical floating-neutral candidate-mode report hook."""
bmopf_floating_neutral_candidate_report(context) = _bmopf_extension(:BMOPFToolsJuMPExt,
    "BMOPFTools and JuMP support are required to inspect staged BMOPF floating-neutral candidates")._bmopf_floating_neutral_candidate_report(context)
"""Optional BMOPFTools staged-OPF lifecycle report hook."""
bmopf_opf_lifecycle_report(context) = _bmopf_extension(:BMOPFToolsJuMPExt,
    "BMOPFTools and JuMP support are required to inspect a staged BMOPF OPF lifecycle")._bmopf_opf_lifecycle_report(context)
"""Optional BMOPFTools staged-OPF differentiability report hook."""
bmopf_opf_differentiability_report(context; kwargs...) = _bmopf_extension(:BMOPFToolsJuMPExt,
    "BMOPFTools and JuMP support are required to inspect staged BMOPF differentiability")._bmopf_opf_differentiability_report(context; kwargs...)
"""Optional BMOPFTools staged-OPF semantic-registry report hook."""
bmopf_opf_registry_report(context) = _bmopf_extension(:BMOPFToolsJuMPExt,
    "BMOPFTools and JuMP support are required to inspect a staged BMOPF OPF registry")._bmopf_opf_registry_report(context)
"""Optional BMOPFTools staged-OPF semantic component metadata hook."""
bmopf_component_metadata(context) = _bmopf_extension(:BMOPFToolsJuMPExt,
    "BMOPFTools and JuMP support are required to inspect staged BMOPF components")._bmopf_component_metadata(context)
"""Optional BMOPFTools staged-OPF component-coordinate semantics hook."""
bmopf_component_coordinate_semantics(context) = _bmopf_extension(:BMOPFToolsJuMPExt,
    "BMOPFTools and JuMP support are required to inspect staged BMOPF components")._bmopf_component_coordinate_semantics(context)
"""Optional BMOPFTools staged-OPF component metadata report hook."""
bmopf_component_report(context) = _bmopf_extension(:BMOPFToolsJuMPExt,
    "BMOPFTools and JuMP support are required to inspect staged BMOPF components")._bmopf_component_report(context)
"""Report BMOPFTools expected-component-rank declaration coverage."""
bmopf_component_rank_capability_report(context) = _bmopf_extension(:BMOPFToolsJuMPExt,
    "BMOPFTools and JuMP support are required to inspect staged BMOPF component-rank capability")._bmopf_component_rank_capability_report(context)
"""Report source-schema fidelity losses recorded while converting PowerIO data to BMOPF."""
bmopf_source_schema_report(context; kwargs...) = _bmopf_extension(:BMOPFToolsJuMPExt,
    "BMOPFTools and JuMP support are required to report BMOPF source-schema fidelity")._bmopf_source_schema_report(context; kwargs...)
"""Build a separate, non-mutating auxiliary model for source voltage-behavior candidates."""
bmopf_source_behavior_auxiliary_model(context; kwargs...) =
    _bmopf_extension(:BMOPFToolsJuMPExt,
        "BMOPFTools and JuMP support are required to build the BMOPF source-behavior auxiliary model")._bmopf_source_behavior_auxiliary_model(context; kwargs...)
"""Solve an already-built isolated BMOPF source-behavior auxiliary model."""
bmopf_source_behavior_auxiliary_solve(auxiliary; kwargs...) =
    _bmopf_extension(:BMOPFToolsJuMPExt,
        "BMOPFTools and JuMP support are required to solve the BMOPF source-behavior auxiliary model")._bmopf_source_behavior_auxiliary_solve(auxiliary; kwargs...)
"""Report source voltage-behavior threshold violations at an explicit point."""
bmopf_source_behavior_report(context, point; kwargs...) =
    _bmopf_extension(:BMOPFToolsJuMPExt,
        "BMOPFTools and JuMP support are required to report BMOPF source-behavior thresholds")._bmopf_source_behavior_report(context, point; kwargs...)
"""Compare source-behavior threshold evidence with an external solver result."""
bmopf_source_behavior_solver_comparison(context, point; kwargs...) =
    _bmopf_extension(:BMOPFToolsJuMPExt,
        "BMOPFTools and JuMP support are required to compare BMOPF source-behavior evidence with a solver result")._bmopf_source_behavior_solver_comparison(context, point; kwargs...)
"""Optional domain-plugin port/connection declarations; the generic default is empty."""
component_port_metadata(model::MOI.ModelLike) = ComponentPortMetadata[]
component_port_metadata(model::ModelSnapshot) = ComponentPortMetadata[]
"""Optional plugin declarations of expected terminal/mode port null directions."""
component_port_nullspace_modes(model::MOI.ModelLike) = PortNullspaceMode[]
component_port_nullspace_modes(model::ModelSnapshot) = PortNullspaceMode[]
"""Optional plugin-owned semantic labels for named port null modes."""
component_port_nullspace_mode_semantics(model::MOI.ModelLike) = PortNullspaceModeSemantics[]
component_port_nullspace_mode_semantics(model::ModelSnapshot) = PortNullspaceModeSemantics[]
"""Optional plugin-declared directed maps between named component ports."""
component_port_connections(model::MOI.ModelLike) = PortConnectionMetadata[]
component_port_connections(model::ModelSnapshot) = PortConnectionMetadata[]
"""Optional plugin maps from declared port terminal coordinates to model variables."""
component_port_coordinate_maps(model::MOI.ModelLike) = PortCoordinateMap[]
component_port_coordinate_maps(model::ModelSnapshot) = PortCoordinateMap[]
"""Optional plugin declarations of physical terminal-coordinate semantics."""
component_port_coordinate_semantics(model::MOI.ModelLike) = PortCoordinateSemantics[]
component_port_coordinate_semantics(model::ModelSnapshot) = PortCoordinateSemantics[]

function _selected_jacobian_submatrix_evaluation(
    evaluation::NumericalEvaluation{T},
    rows::Vector{Int},
    columns::Vector{Int},
) where {T<:AbstractFloat}
    row_positions = Dict(row => position for (position, row) in enumerate(rows))
    column_positions =
        Dict(column => position for (position, column) in enumerate(columns))
    entries = JacobianEntry{T}[
        JacobianEntry{T}(
            row_positions[entry.row],
            column_positions[entry.column],
            entry.value,
        ) for entry in evaluation.jacobian_entries if
        haskey(row_positions, entry.row) && haskey(column_positions, entry.column)
    ]
    point = EvaluationPoint{T}(
        collect(evaluation.point.variables[columns]),
        T.(evaluation.point.values[columns]),
        evaluation.point.label,
        evaluation.point.provenance,
    )
    return NumericalEvaluation{T}(
        point,
        nothing,
        nothing,
        Union{Missing,T}[],
        evaluation.constraint_values[rows],
        evaluation.constraint_sources[rows],
        entries,
        evaluation.jacobian_row_methods[rows],
        evaluation.capabilities,
        evaluation.failures,
    )
end

function _unavailable_structural_numerical_comparison(
    evaluation::NumericalEvaluation{T},
    reason::AbstractString,
) where {T<:AbstractFloat}
    return StructuralNumericalComparison{T}(
        false,
        String(reason),
        evaluation.point,
        0, 0, 0, 0, 0, 0, Int[], Int[], nothing,
    )
end

"""
    structural_numerical_comparison(model, evaluation; ...)

Compare equality-pattern matching against a local Jacobian restricted to the
same free variables and alignable ordinary equality rows. A numerical rank
below matching cardinality is an unexpected *local* loss relative to the
generic structural pattern; it is not automatically a physical gauge.
"""
function structural_numerical_comparison(
    model::MOI.ModelLike,
    evaluation::NumericalEvaluation{T};
    relative_tolerance::Real =
        max(length(evaluation.point.variables), 1) * eps(T),
    max_dense_entries::Integer = 4_000_000,
    additional_variable_indices::AbstractVector{MOI.VariableIndex} =
        MOI.VariableIndex[],
) where {T<:AbstractFloat}
    graph = incidence_graph(model)
    graph.complete || return _unavailable_structural_numerical_comparison(
        evaluation,
        "structural equality incidence is incomplete",
    )
    matching = maximum_matching(graph)
    matching.complete || return _unavailable_structural_numerical_comparison(
        evaluation,
        "structural matching is unavailable",
    )
    # Prefer the complete EntityRef as the alignment key. MOI constraint
    # indices are only unique within a function/set type, so a domain row and
    # an algebraic row can legitimately share the same integer index. The
    # reduced key is retained only as a conservative fallback when it is
    # unambiguous.
    numerical_rows = Dict(
        source => row for
        (row, source) in enumerate(evaluation.constraint_sources)
    )
    numerical_rows_by_reduced_key = Dict{Tuple{Symbol,Int,Union{Nothing,Int}},Vector{Int}}()
    for (row, source) in enumerate(evaluation.constraint_sources)
        push!(get!(numerical_rows_by_reduced_key, _entity_row_key(source), Int[]), row)
    end
    selected_rows = Int[]
    for position in matching.eligible_constraint_positions
        node = graph.constraint_nodes[position]
        reference = _constraint_ref(node.constraint; row = node.row)
        row = get(numerical_rows, reference, 0)
        if iszero(row)
            candidates = get(numerical_rows_by_reduced_key, _entity_row_key(reference), Int[])
            length(candidates) == 1 && (row = only(candidates))
        end
        iszero(row) && return _unavailable_structural_numerical_comparison(
            evaluation,
            "could not align structural equality node $(reference.index) with one unambiguous evaluated row",
        )
        push!(selected_rows, row)
    end
    variable_columns = Int[]
    point_columns = Dict(
        variable => column for
        (column, variable) in enumerate(evaluation.point.variables)
    )
    for position in matching.eligible_variable_positions
        variable = graph.variables[position].index
        column = get(point_columns, variable, 0)
        iszero(column) && return _unavailable_structural_numerical_comparison(
            evaluation,
            "could not align free structural variable $(variable.value) with the evaluation point",
        )
        push!(variable_columns, column)
    end
    graph_variable_indices = Set(record.index for record in graph.variables)
    for variable in unique(additional_variable_indices)
        variable in graph_variable_indices || return _unavailable_structural_numerical_comparison(
            evaluation,
            "tangent policy references variable $(variable.value) absent from the incidence graph",
        )
        column = get(point_columns, variable, 0)
        iszero(column) && return _unavailable_structural_numerical_comparison(
            evaluation,
            "tangent policy variable $(variable.value) is absent from the evaluation point",
        )
        push!(variable_columns, column)
    end
    unique!(variable_columns)
    selected_evaluation = _selected_jacobian_submatrix_evaluation(
        evaluation,
        selected_rows,
        variable_columns,
    )
    estimate = jacobian_rank_estimate(
        selected_evaluation;
        relative_tolerance = relative_tolerance,
        max_dense_entries = max_dense_entries,
    )
    estimate.available || return StructuralNumericalComparison{T}(
        false,
        estimate.reason,
        evaluation.point,
        matching_cardinality(matching),
        length(variable_columns) - matching_cardinality(matching),
        length(selected_rows) - matching_cardinality(matching),
        0, 0, 0,
        selected_rows,
        variable_columns,
        estimate,
    )
    structural_rank = matching_cardinality(matching)
    return StructuralNumericalComparison{T}(
        true,
        nothing,
        evaluation.point,
        structural_rank,
        length(variable_columns) - structural_rank,
        length(selected_rows) - structural_rank,
        estimate.rank,
        estimate.right_nullity,
        estimate.left_nullity,
        selected_rows,
        variable_columns,
        estimate,
    )
end

"""
    nullspace_fingerprints(comparison; ...)

Extract a small set of conservative, inspectable local nullspace patterns.
Currently recognized patterns are a near-uniform right-null vector (candidate
common-coordinate shift), a compact or single-coordinate right-null vector,
and a two-row left-null vector (candidate pairwise equation dependence).
"""
function nullspace_fingerprints(
    comparison::StructuralNumericalComparison{T};
    support_relative::Real = 0.1,
    uniform_shift_correlation::Real = 0.98,
    max_compact_support::Integer = 8,
) where {T<:AbstractFloat}
    comparison.available || return NullspaceFingerprint{T}[]
    relative = convert(T, support_relative)
    correlation_threshold = convert(T, uniform_shift_correlation)
    zero(T) < relative <= one(T) ||
        throw(ArgumentError("support_relative must lie in (0, 1]"))
    zero(T) <= correlation_threshold <= one(T) ||
        throw(ArgumentError("uniform_shift_correlation must lie in [0, 1]"))
    max_compact_support >= 2 ||
        throw(ArgumentError("max_compact_support must be at least 2"))
    estimate = something(comparison.estimate)
    fingerprints = NullspaceFingerprint{T}[]
    for vector_index in axes(estimate.right_nullspace, 2)
        vector = view(estimate.right_nullspace, :, vector_index)
        maximum_magnitude = maximum(abs, vector; init = zero(T))
        iszero(maximum_magnitude) && continue
        local_support = findall(value -> abs(value) >= relative * maximum_magnitude, vector)
        support = comparison.free_variable_columns[local_support]
        correlation = abs(sum(vector)) / (sqrt(T(length(vector))) * norm(vector))
        if length(vector) >= 2 && length(local_support) == length(vector) &&
           correlation >= correlation_threshold
            push!(
                fingerprints,
                NullspaceFingerprint{T}(
                    :right,
                    vector_index,
                    :candidate_uniform_coordinate_shift,
                    support,
                    correlation,
                ),
            )
        elseif length(local_support) == 1
            push!(
                fingerprints,
                NullspaceFingerprint{T}(
                    :right,
                    vector_index,
                    :candidate_single_coordinate_null_direction,
                    support,
                    one(T),
                ),
            )
        elseif 2 <= length(local_support) <= min(max_compact_support, length(vector) - 1)
            concentration = norm(vector[local_support]) / norm(vector)
            push!(
                fingerprints,
                NullspaceFingerprint{T}(
                    :right,
                    vector_index,
                    :candidate_compact_coordinate_null_direction,
                    support,
                    concentration,
                ),
            )
        end
    end
    for vector_index in axes(estimate.left_nullspace, 2)
        vector = view(estimate.left_nullspace, :, vector_index)
        maximum_magnitude = maximum(abs, vector; init = zero(T))
        iszero(maximum_magnitude) && continue
        local_support = findall(value -> abs(value) >= relative * maximum_magnitude, vector)
        length(local_support) == 2 || continue
        push!(
            fingerprints,
            NullspaceFingerprint{T}(
                :left,
                vector_index,
                :candidate_two_row_equation_dependence,
                comparison.equality_rows[local_support],
                one(T),
            ),
        )
    end
    return fingerprints
end

function structural_numerical_comparison(
    model::MOI.ModelLike,
    point::EvaluationPoint;
    cache::EvaluationCache = EvaluationCache(),
    kwargs...,
)
    return structural_numerical_comparison(
        model,
        evaluate_numerical(model, point; cache = cache);
        kwargs...,
    )
end

function structural_numerical_comparison(
    model::MOI.ModelLike,
    values::Union{AbstractVector{<:Real},AbstractDict{MOI.VariableIndex,<:Real}};
    label::AbstractString = "user",
    kwargs...,
)
    return structural_numerical_comparison(
        model,
        evaluation_point(model, values; label = label);
        kwargs...,
    )
end

function _structural_numerical_findings(
    comparison::StructuralNumericalComparison,
)
    findings = Finding[]
    if !comparison.available
        push!(
            findings,
            Finding(
                :structural_numerical_comparison_unavailable;
                severity = SeverityInfo,
                domain = RepresentationalIssue,
                basis = StructuralProof,
                confidence = ConfidenceCertain,
                observation = "Structural-to-numerical rank comparison is unavailable at point \"$(comparison.point.label)\".",
                why_it_matters = "The debugger cannot safely call a local nullspace expected or unexpected without aligning complete structural and numerical views.",
                evidence = [
                    _point_evidence(comparison.point),
                    Evidence(
                        "Comparison availability";
                        details = ["reason" => comparison.reason],
                    ),
                ],
                suggested_actions = [
                    "Resolve opaque structural sources or incomplete derivatives, then repeat the comparison.",
                ],
            ),
        )
        return findings
    end
    estimate = something(comparison.estimate)
    evidence = [
        _point_evidence(comparison.point),
        Evidence(
            "Structural equality matching versus local Jacobian";
            details = [
                "structural_matching_rank" => comparison.structural_matching_rank,
                "structural_right_nullity" => comparison.structural_right_nullity,
                "structural_left_nullity" => comparison.structural_left_nullity,
                "numerical_rank" => comparison.numerical_rank,
                "numerical_right_nullity" => comparison.numerical_right_nullity,
                "numerical_left_nullity" => comparison.numerical_left_nullity,
                "equality_rows" => join(comparison.equality_rows, ","),
                "free_variable_columns" => join(comparison.free_variable_columns, ","),
            ],
        ),
        _rank_evidence(estimate),
    ]
    if comparison.numerical_rank < comparison.structural_matching_rank
        push!(
            findings,
            Finding(
                :unexpected_local_rank_loss;
                severity = SeverityWarning,
                domain = NumericalIssue,
                basis = LocalInference,
                confidence = ConfidenceHigh,
                observation = "The aligned local equality Jacobian has rank $(comparison.numerical_rank), below structural matching rank $(comparison.structural_matching_rank).",
                why_it_matters = "The equality pattern admits more independent equations than are observed locally. This can arise from a stationary expression, parameter value, poor scaling, or a genuine unmodeled degeneracy.",
                evidence = evidence,
                suggested_actions = [
                    "Inspect the local nullspace vectors and repeat at nearby domain-valid points.",
                    "Do not label this mode a physical gauge until a plugin or model semantics supports that interpretation.",
                ],
            ),
        )
    elseif comparison.numerical_rank == comparison.structural_matching_rank &&
           (comparison.structural_right_nullity > 0 || comparison.structural_left_nullity > 0)
        push!(
            findings,
            Finding(
                :structurally_expected_local_nullspace;
                severity = SeverityInfo,
                domain = RepresentationalIssue,
                basis = StructuralProof,
                confidence = ConfidenceHigh,
                observation = "The local equality-Jacobian rank matches the structural matching rank, with $(comparison.numerical_right_nullity) right and $(comparison.numerical_left_nullity) left null direction(s) in the aligned view.",
                why_it_matters = "The observed rectangular freedom or excess-equation pattern is consistent with the generic equality incidence. Its physical meaning remains unclassified.",
                evidence = evidence,
                suggested_actions = [
                    "Classify the mode using model semantics or a domain plugin (for example, an expected reference gauge).",
                ],
            ),
        )
    elseif comparison.numerical_rank == comparison.structural_matching_rank
        push!(
            findings,
            Finding(
                :structural_numerical_rank_agreement;
                severity = SeverityInfo,
                domain = NumericalIssue,
                basis = NumericalObservation,
                confidence = ConfidenceHigh,
                observation = "The aligned local equality-Jacobian rank agrees with structural matching rank $(comparison.structural_matching_rank).",
                why_it_matters = "No additional local rank loss is observed in this equality view at the recorded point.",
                evidence = evidence,
                suggested_actions = [
                    "This does not rule out scaling, active-set, or second-order degeneracy; inspect those stages separately.",
                ],
            ),
        )
    else
        push!(
            findings,
            Finding(
                :structural_numerical_rank_inconsistency;
                severity = SeverityWarning,
                domain = RepresentationalIssue,
                basis = NumericalObservation,
                confidence = ConfidenceMedium,
                observation = "The local equality-Jacobian rank $(comparison.numerical_rank) exceeds structural matching rank $(comparison.structural_matching_rank).",
                why_it_matters = "This should be impossible for a fully aligned exact incidence pattern and may indicate unsupported expression semantics or an alignment defect.",
                evidence = evidence,
                suggested_actions = [
                    "Inspect expression-support and evaluator provenance before interpreting the numerical result.",
                ],
            ),
        )
    end
    return findings
end

function _nullspace_fingerprint_findings(
    comparison::StructuralNumericalComparison,
    evaluation::NumericalEvaluation,
    fingerprints::Vector{<:NullspaceFingerprint} = nullspace_fingerprints(comparison),
)
    comparison.available || return Finding[]
    findings = Finding[]
    for fingerprint in fingerprints
        if fingerprint.kind == :candidate_uniform_coordinate_shift
            affected = EntityRef[
                EntityRef(:variable, comparison.point.variables[column].value) for
                column in fingerprint.support
            ]
            push!(
                findings,
                Finding(
                    :candidate_uniform_coordinate_shift_null_mode;
                    severity = SeverityInfo,
                    domain = RepresentationalIssue,
                    basis = HeuristicInterpretation,
                    confidence = ConfidenceMedium,
                    observation = "A local right-null vector is nearly uniform across $(length(fingerprint.support)) aligned free coordinates.",
                    why_it_matters = "This resembles a common-coordinate shift, but variable units and model semantics are required before it can be called an expected physical or reference gauge.",
                    evidence = [
                        _point_evidence(comparison.point),
                        Evidence(
                            "Nullspace fingerprint";
                            details = [
                                "side" => fingerprint.side,
                                "vector_index" => fingerprint.vector_index,
                                "support_columns" => join(fingerprint.support, ","),
                                "uniform_shift_correlation" => fingerprint.score,
                            ],
                        ),
                    ],
                    suggested_actions = [
                        "Confirm that the affected coordinates share units and represent a meaningful common reference direction.",
                        "Use a domain plugin to declare an expected gauge before suppressing the mode.",
                    ],
                    affected = affected,
                ),
            )
        elseif fingerprint.kind == :candidate_two_row_equation_dependence
            affected = EntityRef[
                evaluation.constraint_sources[row] for row in fingerprint.support
            ]
            push!(
                findings,
                Finding(
                    :candidate_two_row_equation_dependence;
                    severity = SeverityWarning,
                    domain = NumericalIssue,
                    basis = HeuristicInterpretation,
                    confidence = ConfidenceMedium,
                    observation = "A local left-null vector is concentrated on two equality rows with nearly balanced magnitudes.",
                    why_it_matters = "This resembles a pair of locally dependent equations, but it may be caused by a point-specific derivative cancellation rather than a duplicate model row.",
                    evidence = [
                        _point_evidence(comparison.point),
                        Evidence(
                            "Nullspace fingerprint";
                            details = [
                                "side" => fingerprint.side,
                                "vector_index" => fingerprint.vector_index,
                                "support_rows" => join(fingerprint.support, ","),
                            "support_concentration" => fingerprint.score,
                            ],
                        ),
                    ],
                    suggested_actions = [
                        "Compare the two rows with exact duplicate-expression findings and repeat at nearby points.",
                    ],
                    affected = affected,
                ),
            )
        elseif fingerprint.kind == :candidate_single_coordinate_null_direction
            column = only(fingerprint.support)
            variable = comparison.point.variables[column]
            push!(
                findings,
                Finding(
                    :candidate_single_coordinate_null_direction;
                    severity = SeverityWarning,
                    domain = NumericalIssue,
                    basis = HeuristicInterpretation,
                    confidence = ConfidenceMedium,
                    observation = "A local right-null vector is concentrated on variable $(variable.value).",
                    why_it_matters = "This coordinate is locally free to first order in the aligned equality-Jacobian view. It can arise from a missing equation, a stationary nonlinear derivative, or derivative-evaluation behavior; it does not prove any one cause.",
                    evidence = [
                        _point_evidence(comparison.point),
                        Evidence(
                            "Nullspace fingerprint";
                            details = [
                                "side" => fingerprint.side,
                                "vector_index" => fingerprint.vector_index,
                                "variable" => variable.value,
                            ],
                        ),
                    ],
                    suggested_actions = [
                        "Compare this coordinate with structural matching and zero-sensitivity evidence.",
                        "Repeat at nearby domain-valid points before classifying it as a missing equation or gauge.",
                    ],
                    affected = [EntityRef(:variable, variable.value)],
                ),
            )
        elseif fingerprint.kind == :candidate_compact_coordinate_null_direction
            affected = EntityRef[
                EntityRef(:variable, comparison.point.variables[column].value) for
                column in fingerprint.support
            ]
            push!(
                findings,
                Finding(
                    :candidate_compact_coordinate_null_direction;
                    severity = SeverityInfo,
                    domain = NumericalIssue,
                    basis = HeuristicInterpretation,
                    confidence = ConfidenceMedium,
                    observation = "A local right-null vector is concentrated on $(length(fingerprint.support)) of $(length(comparison.free_variable_columns)) aligned free coordinates.",
                    why_it_matters = "This compact direction can localize an unexpected freedom, weakly identified subsystem, or point-specific derivative cancellation. It is not proof of a missing equation or physical gauge.",
                    evidence = [
                        _point_evidence(comparison.point),
                        Evidence(
                            "Nullspace fingerprint";
                            details = [
                                "side" => fingerprint.side,
                                "vector_index" => fingerprint.vector_index,
                                "support_columns" => join(fingerprint.support, ","),
                                "support_concentration" => fingerprint.score,
                            ],
                        ),
                    ],
                    suggested_actions = [
                        "Inspect the supported variables together with structural matching and derivative-scale evidence.",
                        "Compare nearby points and declared expected modes before assigning physical meaning.",
                    ],
                    affected = affected,
                ),
            )
        end
    end
    return findings
end

function _unknown_local_degeneracy_findings(
    comparison::StructuralNumericalComparison,
    fingerprints::Vector{<:NullspaceFingerprint},
)
    comparison.available || return Finding[]
    comparison.numerical_rank < comparison.structural_matching_rank || return Finding[]
    isempty(fingerprints) || return Finding[]
    return Finding[Finding(
        :unknown_local_degeneracy_mode;
        severity = SeverityWarning,
        domain = NumericalIssue,
        basis = LocalInference,
        confidence = ConfidenceHigh,
        observation = "Additional local rank loss is observed, but no generic nullspace fingerprint matches the aligned equality-Jacobian mode.",
        why_it_matters = "The rank loss needs model or domain semantics before it can be classified as a gauge, dependent equation, coordinate artifact, or physical mode.",
        evidence = [
            _point_evidence(comparison.point),
            Evidence("Unclassified local nullspace"; details = [
                "structural_matching_rank" => comparison.structural_matching_rank,
                "numerical_rank" => comparison.numerical_rank,
                "right_nullity" => comparison.numerical_right_nullity,
                "left_nullity" => comparison.numerical_left_nullity,
                "matched_generic_fingerprints" => 0,
            ]),
        ],
        suggested_actions = [
            "Inspect the recorded nullspace vectors and repeat at nearby valid points.",
            "Add domain metadata or a plugin classifier before assigning a physical interpretation.",
        ],
    )]
end

function _expected_nullspace_mode_findings(
    comparison::StructuralNumericalComparison{T},
    modes::AbstractVector{<:ExpectedNullspaceMode};
    residual_tolerance::Real = sqrt(eps(T)),
    free_coordinate_policy::Symbol = :strict,
    tangent_policy::Union{Nothing,ExpectedNullspaceTangentPolicy} = nothing,
) where {T<:AbstractFloat}
    comparison.available || return Finding[]
    tolerance = convert(T, residual_tolerance)
    tolerance >= zero(T) ||
        throw(ArgumentError("residual_tolerance must be nonnegative"))
    free_coordinate_policy in (:strict, :project_free) || throw(ArgumentError(
        "free_coordinate_policy must be :strict or :project_free",
    ))
    point_columns = Dict(
        variable => column for
        (column, variable) in enumerate(comparison.point.variables)
    )
    local_columns = Dict(
        column => local_position for
        (local_position, column) in enumerate(comparison.free_variable_columns)
    )
    estimate = something(comparison.estimate)
    findings = Finding[]
    for mode in modes
        direction = zeros(T, length(comparison.free_variable_columns))
        unavailable_variables = Int[]
        nonfree_variables = Int[]
        aligned_variable_count = 0
        unavailable_coefficient_squared = zero(T)
        nonfree_coefficient_squared = zero(T)
        aligned_coefficient_squared = zero(T)
        for (variable, coefficient) in zip(mode.variables, mode.direction)
            column = get(point_columns, variable, 0)
            local_column = get(local_columns, column, 0)
            coefficient_value = convert(T, coefficient)
            if iszero(column)
                push!(unavailable_variables, variable.value)
                unavailable_coefficient_squared += coefficient_value^2
            elseif iszero(local_column)
                push!(nonfree_variables, variable.value)
                nonfree_coefficient_squared += coefficient_value^2
            else
                direction[local_column] += coefficient_value
                aligned_variable_count += 1
                aligned_coefficient_squared += coefficient_value^2
            end
        end
        total_coefficient_norm = sqrt(max(zero(T), aligned_coefficient_squared +
                                          nonfree_coefficient_squared +
                                          unavailable_coefficient_squared))
        aligned_fraction = iszero(total_coefficient_norm) ? zero(T) :
                           sqrt(aligned_coefficient_squared) / total_coefficient_norm
        discarded_variables = vcat(nonfree_variables, unavailable_variables)
        discarded_coefficient_squared = nonfree_coefficient_squared +
                                        unavailable_coefficient_squared

        # The strict policy preserves the historical safety gate: every mode
        # coordinate must be part of the free comparison scope. The explicit
        # projection policy is allowed to compare only the free component, but
        # retains every discarded coordinate and coefficient norm in evidence.
        if (!isempty(discarded_variables) && free_coordinate_policy == :strict) ||
           iszero(norm(direction))
            if !isempty(discarded_variables) && !iszero(norm(direction))
                push!(
                    findings,
                    Finding(
                        :expected_nullspace_mode_partial_alignment;
                        severity = SeverityInfo,
                        domain = RepresentationalIssue,
                        basis = StructuralProof,
                        confidence = ConfidenceCertain,
                        observation = "Expected nullspace mode :$(mode.name) retains $(aligned_variable_count) aligned variable component(s), while $(length(discarded_variables)) component(s) lie outside the free-coordinate scope.",
                        why_it_matters = "The projected direction can be inspected, but dropping non-free components changes the declared mode and must not be treated as an observed physical gauge.",
                        evidence = [Evidence("Partial expected-nullspace alignment"; details = [
                            "mode" => mode.name,
                            "aligned_variable_count" => aligned_variable_count,
                            "unaligned_variable_count" => length(discarded_variables),
                            "unaligned_variable_indices" => join(discarded_variables, ","),
                            "nonfree_variable_indices" => join(nonfree_variables, ","),
                            "aligned_coefficient_fraction" => aligned_fraction,
                            "aligned_coefficient_norm" => sqrt(aligned_coefficient_squared),
                            "unaligned_coefficient_norm" => sqrt(discarded_coefficient_squared),
                        ])],
                        suggested_actions = [
                            "Inspect the terminal-to-model map and fixed-coordinate declarations before comparing the projected direction.",
                            "Only compare the full declared mode after all of its coordinates are represented in the free model scope.",
                        ],
                    ),
                )
            end
            push!(
                findings,
                Finding(
                    :expected_nullspace_mode_unaligned;
                    severity = SeverityInfo,
                    domain = RepresentationalIssue,
                    basis = StructuralProof,
                    confidence = ConfidenceCertain,
                    observation = "Expected nullspace mode :$(mode.name) cannot be aligned with the free coordinates used by the local comparison.",
                    why_it_matters = "The debugger cannot compare a declared gauge with the observed nullspace unless their variable coordinates agree.",
                    evidence = [Evidence("Expected nullspace alignment"; details = [
                        "mode" => mode.name,
                        "unaligned_variable_indices" => join(discarded_variables, ","),
                        "missing_variable_indices" => join(unavailable_variables, ","),
                        "nonfree_variable_indices" => join(nonfree_variables, ","),
                        "aligned_variable_count" => aligned_variable_count,
                        "unaligned_variable_count" => length(discarded_variables),
                        "aligned_coefficient_fraction" => aligned_fraction,
                        "aligned_coefficient_norm" => sqrt(aligned_coefficient_squared),
                        "unaligned_coefficient_norm" => sqrt(discarded_coefficient_squared),
                        "free_coordinate_policy" => free_coordinate_policy,
                    ])],
                    suggested_actions = [
                        "Declare the mode in free evaluation-point coordinates or provide plugin-specific alignment logic.",
                    ],
                ),
            )
            continue
        end
        normalized = direction / norm(direction)
        residual = if size(estimate.right_nullspace, 2) == 0
            one(T)
        else
            norm(normalized - estimate.right_nullspace * (
                transpose(estimate.right_nullspace) * normalized
            ))
        end
        affected = EntityRef[
            EntityRef(:variable, variable.value) for variable in mode.variables
        ]
        projected = !isempty(discarded_variables)
        projected_code = projected ?
                         (residual <= tolerance ?
                          :expected_nullspace_mode_free_projection_observed :
                          :expected_nullspace_mode_free_projection_not_observed) :
                         isnothing(tangent_policy) ?
                         (residual <= tolerance ?
                          :expected_nullspace_mode_observed :
                          :expected_nullspace_mode_not_observed) :
                         (residual <= tolerance ?
                          :expected_nullspace_mode_tangent_observed :
                          :expected_nullspace_mode_tangent_not_observed)
        projected_observed = residual <= tolerance
        if projected
            push!(
                findings,
                Finding(
                    projected_code;
                    severity = SeverityInfo,
                    domain = RepresentationalIssue,
                    basis = LocalInference,
                    confidence = ConfidenceMedium,
                    observation = projected_observed ?
                                  "The free-coordinate projection of expected nullspace mode :$(mode.name) aligns with the observed local right nullspace." :
                                  "The free-coordinate projection of expected nullspace mode :$(mode.name) does not align with the observed local right nullspace.",
                    why_it_matters = "This is a controlled comparison of the represented free component only. Fixed or unavailable components are retained in the evidence and prevent a physical gauge conclusion.",
                    evidence = [Evidence("Expected-nullspace free-coordinate projection"; details = [
                        "mode" => mode.name,
                        "projection_policy" => free_coordinate_policy,
                        "tangent_policy" => isnothing(tangent_policy) ? "none" :
                            string(tangent_policy.name),
                        "projection_residual" => residual,
                        "tolerance" => tolerance,
                        "aligned_variable_count" => aligned_variable_count,
                        "unaligned_variable_count" => length(discarded_variables),
                        "missing_variable_indices" => join(unavailable_variables, ","),
                        "nonfree_variable_indices" => join(nonfree_variables, ","),
                        "aligned_coefficient_fraction" => aligned_fraction,
                        "aligned_coefficient_norm" => sqrt(aligned_coefficient_squared),
                        "unaligned_coefficient_norm" => sqrt(discarded_coefficient_squared),
                        "description" => mode.description,
                    ])],
                    suggested_actions = projected_observed ?
                                        ["Retain this as projected local evidence, then repeat with the fixed/reference coordinates released or with a plugin-specific tangent policy."] :
                                        ["Inspect fixed/reference coordinates and the terminal-to-model convention before changing the physical mode declaration."],
                    affected = affected,
                ),
            )
        elseif residual <= tolerance
            push!(
                findings,
                Finding(
                    isnothing(tangent_policy) ?
                    :expected_nullspace_mode_observed :
                    :expected_nullspace_mode_tangent_observed;
                    severity = SeverityInfo,
                    domain = RepresentationalIssue,
                    basis = isnothing(tangent_policy) ? PhysicalExpectation : LocalInference,
                    confidence = isnothing(tangent_policy) ? ConfidenceHigh : ConfidenceMedium,
                    observation = isnothing(tangent_policy) ?
                                  "Declared expected nullspace mode :$(mode.name) aligns with the observed local right nullspace." :
                                  "Declared expected nullspace mode :$(mode.name) aligns with the observed local right nullspace under tangent policy :$(tangent_policy.name).",
                    why_it_matters = isnothing(tangent_policy) ?
                                     "This supports, but does not prove, the plugin or caller's interpretation of the local freedom as an expected gauge or invariance." :
                                     "This is local evidence under an explicit plugin tangent scope; it does not prove that the fixed/reference coordinates may be released physically.",
                    evidence = [Evidence("Expected-nullspace comparison"; details = [
                        "mode" => mode.name,
                        "projection_residual" => residual,
                        "tolerance" => tolerance,
                        "tangent_policy" => isnothing(tangent_policy) ? "none" : string(tangent_policy.name),
                        "description" => mode.description,
                    ])],
                    suggested_actions = [
                        "Retain the declaration and verify it across relevant operating points and formulations.",
                    ],
                    affected = affected,
                ),
            )
        else
            push!(
                findings,
                Finding(
                    isnothing(tangent_policy) ?
                    :expected_nullspace_mode_not_observed :
                    :expected_nullspace_mode_tangent_not_observed;
                    severity = SeverityInfo,
                    domain = RepresentationalIssue,
                    basis = LocalInference,
                    confidence = isnothing(tangent_policy) ? ConfidenceHigh : ConfidenceMedium,
                    observation = isnothing(tangent_policy) ?
                                  "Declared expected nullspace mode :$(mode.name) does not align with the observed local right nullspace." :
                                  "Declared expected nullspace mode :$(mode.name) does not align with the observed local right nullspace under tangent policy :$(tangent_policy.name).",
                    why_it_matters = isnothing(tangent_policy) ?
                                     "The mode may be fixed by this formulation or operating point, or the declaration may not match the model coordinates." :
                                     "The mode remains absent even after the plugin tangent scope retained its declared coordinates; this is local evidence, not a physical failure certificate.",
                    evidence = [Evidence("Expected-nullspace comparison"; details = [
                        "mode" => mode.name,
                        "projection_residual" => residual,
                        "tolerance" => tolerance,
                        "tangent_policy" => isnothing(tangent_policy) ? "none" : string(tangent_policy.name),
                        "description" => mode.description,
                    ])],
                    suggested_actions = [
                        "Check references, active constraints, and plugin assumptions before treating the missing mode as an error.",
                    ],
                    affected = affected,
                ),
            )
        end
    end
    return findings
end

"""Compare the declared expected-mode span with the observed right nullspace."""
function _expected_nullspace_span_findings(
    comparison::StructuralNumericalComparison{T},
    modes::AbstractVector{<:ExpectedNullspaceMode};
    residual_tolerance::Real = sqrt(eps(T)),
    free_coordinate_policy::Symbol = :strict,
    tangent_policy::Union{Nothing,ExpectedNullspaceTangentPolicy} = nothing,
) where {T<:AbstractFloat}
    comparison.available || return Finding[]
    isempty(modes) && return Finding[]
    tolerance = convert(T, residual_tolerance)
    tolerance >= zero(T) ||
        throw(ArgumentError("residual_tolerance must be nonnegative"))
    free_coordinate_policy in (:strict, :project_free) || throw(ArgumentError(
        "free_coordinate_policy must be :strict or :project_free",
    ))
    estimate = something(comparison.estimate)
    point_columns = Dict(
        variable => column for
        (column, variable) in enumerate(comparison.point.variables)
    )
    local_columns = Dict(
        column => local_position for
        (local_position, column) in enumerate(comparison.free_variable_columns)
    )
    directions = Vector{Vector{T}}()
    names = Symbol[]
    projected_names = Symbol[]
    projected_variables = Dict{Symbol,Vector{Int}}()
    for mode in modes
        direction = zeros(T, length(comparison.free_variable_columns))
        aligned = true
        discarded = Int[]
        for (variable, coefficient) in zip(mode.variables, mode.direction)
            column = get(point_columns, variable, 0)
            local_column = get(local_columns, column, 0)
            if iszero(local_column)
                push!(discarded, variable.value)
                free_coordinate_policy == :strict && (aligned = false; break)
            else
                direction[local_column] += convert(T, coefficient)
            end
        end
        aligned && !iszero(norm(direction)) || continue
        push!(directions, direction / norm(direction))
        push!(names, mode.name)
        !isempty(discarded) && begin
            push!(projected_names, mode.name)
            projected_variables[mode.name] = discarded
        end
    end
    isempty(directions) && return Finding[]
    declared = hcat(directions...)
    decomposition = svd(declared; full = false)
    threshold = isempty(decomposition.S) ? zero(T) :
                max(tolerance, eps(T) * max(size(declared)...)) *
                maximum(decomposition.S)
    declared_rank = count(value -> value > threshold, decomposition.S)
    declared_basis = declared_rank == 0 ? zeros(T, size(declared, 1), 0) :
                     decomposition.U[:, 1:declared_rank]
    observed_basis = estimate.right_nullspace
    projection_residual = size(observed_basis, 2) == 0 ? one(T) :
                          norm(declared - observed_basis *
                               (transpose(observed_basis) * declared)) / norm(declared)
    findings = Finding[]
    if !isempty(projected_names)
        push!(findings, Finding(
            :expected_nullspace_mode_span_free_projection;
            severity = SeverityInfo,
            domain = RepresentationalIssue,
            basis = LocalInference,
            confidence = ConfidenceMedium,
            observation = "The expected-mode span includes free-coordinate projections for $(length(projected_names)) declaration(s) under the :project_free policy.",
            why_it_matters = "The span comparison uses only represented free components; fixed or unavailable coordinates remain explicit and prevent a physical span certificate.",
            evidence = [Evidence("Expected-nullspace span free projection"; details = [
                "projection_policy" => free_coordinate_policy,
                "tangent_policy" => isnothing(tangent_policy) ? "none" : string(tangent_policy.name),
                "projected_mode_names" => join(string.(projected_names), ","),
                "discarded_variable_indices" => join(
                    sort!(unique(vcat(values(projected_variables)...))), ",",
                ),
            ])],
            suggested_actions = [
                "Repeat the span comparison with a plugin-specific tangent policy before assigning physical meaning.",
            ],
        ))
    end
    if declared_rank < length(names)
        push!(findings, Finding(
            :expected_nullspace_mode_declarations_dependent;
            severity = SeverityInfo,
            domain = RepresentationalIssue,
            basis = NumericalObservation,
            confidence = ConfidenceHigh,
            observation = "$(length(names)) aligned expected-nullspace declarations span only $declared_rank independent direction(s).",
            why_it_matters = "Duplicate or linearly dependent declarations obscure the expected gauge dimension and can make expected-versus-observed comparisons misleading.",
            evidence = [Evidence("Expected-nullspace declaration span"; details = [
                "aligned_modes" => join(string.(names), ","),
                "aligned_mode_count" => length(names),
                "declared_span_rank" => declared_rank,
                "rank_threshold" => threshold,
            ])],
            suggested_actions = [
                "Keep one independent declaration per expected gauge direction.",
            ],
        ))
    end
    if projection_residual <= tolerance &&
       estimate.right_nullity > declared_rank
        push!(findings, Finding(
            :undeclared_observed_nullspace_directions;
            severity = SeverityInfo,
            domain = RepresentationalIssue,
            basis = LocalInference,
            confidence = ConfidenceHigh,
            observation = "The observed local right nullspace has $(estimate.right_nullity) direction(s), while aligned expected declarations account for $declared_rank independent direction(s).",
            why_it_matters = "At least $(estimate.right_nullity - declared_rank) observed direction(s) remain semantically undeclared. They may be additional gauges, formulation freedom, or local numerical degeneracy.",
            evidence = [
                _point_evidence(comparison.point),
                Evidence("Expected versus observed nullspace span"; details = [
                    "aligned_modes" => join(string.(names), ","),
                    "declared_span_rank" => declared_rank,
                    "observed_right_nullity" => estimate.right_nullity,
                    "declared_span_projection_residual" => projection_residual,
                    "tolerance" => tolerance,
                ]),
            ],
            suggested_actions = [
                "Inspect the remaining observed nullspace vectors before declaring them expected or physical.",
                "Add an independent expected-mode declaration only when model or domain semantics justifies it.",
            ],
        ))
    end
    return findings
end

"""
    analyze_degeneracy(model, evaluation; ...)

Report the first generic degeneracy classification: structural equality-pattern
freedom versus additional local numerical rank loss.

expected_mode_free_coordinate_policy = :strict requires every declared mode
coordinate to be present in the free-variable comparison scope. Set it to
:project_free only when a caller wants a controlled local comparison of the
represented free component; fixed and unavailable components remain explicit in
the emitted evidence and do not become a physical gauge certificate.
"""
function analyze_degeneracy(
    model::MOI.ModelLike,
    evaluation::NumericalEvaluation;
    expected_modes::AbstractVector{<:ExpectedNullspaceMode} =
        expected_nullspace_modes(model, evaluation),
    include_port_topology_modes::Bool = true,
    expected_mode_residual_tolerance::Real =
        sqrt(eps(eltype(evaluation.point.values))),
    expected_mode_free_coordinate_policy::Symbol = :strict,
    expected_mode_tangent_policy::Union{Nothing,ExpectedNullspaceTangentPolicy} = nothing,
    nullspace_support_relative::Real = 0.1,
    nullspace_uniform_shift_correlation::Real = 0.98,
    nullspace_max_compact_support::Integer = 8,
    iterative_right_nullspace_probe_dimension::Union{Nothing,Integer} = nothing,
    iterative_right_nullspace_probe_iterations::Integer = 100,
    iterative_right_nullspace_probe_convergence_tolerance::Real =
        sqrt(eps(eltype(evaluation.point.values))),
    iterative_right_nullspace_probe_residual_relative_tolerance::Real =
        sqrt(eps(eltype(evaluation.point.values))),
    iterative_right_nullspace_probe_support_relative::Real = 0.1,
    iterative_left_nullspace_probe_dimension::Union{Nothing,Integer} = nothing,
    iterative_left_nullspace_probe_iterations::Integer = 100,
    iterative_left_nullspace_probe_convergence_tolerance::Real =
        sqrt(eps(eltype(evaluation.point.values))),
    iterative_left_nullspace_probe_residual_relative_tolerance::Real =
        sqrt(eps(eltype(evaluation.point.values))),
    iterative_left_nullspace_probe_support_relative::Real = 0.1,
    iterative_spectrum_probe_dimension::Union{Nothing,Integer} = nothing,
    iterative_spectrum_probe_iterations::Integer = 100,
    iterative_spectrum_probe_convergence_tolerance::Real =
        sqrt(eps(eltype(evaluation.point.values))),
    iterative_spectrum_probe_spread_threshold::Real = 1.0e6,
    kwargs...,
)
    _validate_evaluation_variable_order(model, evaluation)
    expected_mode_free_coordinate_policy in (:strict, :project_free) ||
        throw(ArgumentError(
            "expected_mode_free_coordinate_policy must be :strict or :project_free",
        ))
    port_modes = include_port_topology_modes ? port_expected_nullspace_modes(
        component_port_metadata(model),
        component_port_nullspace_modes(model),
        component_port_connections(model),
        component_port_coordinate_maps(model),
    ) : ExpectedNullspaceMode[]
    port_summary = port_expected_nullspace_summary(port_modes)
    all_expected_modes = vcat(expected_modes, port_modes)
    tangent_variables = isnothing(expected_mode_tangent_policy) ?
                        MOI.VariableIndex[] : expected_mode_tangent_policy.variables
    comparison_kwargs = merge(
        NamedTuple(kwargs),
        (additional_variable_indices = tangent_variables,),
    )
    comparison = structural_numerical_comparison(model, evaluation; comparison_kwargs...)
    fingerprints = nullspace_fingerprints(
        comparison;
        support_relative = nullspace_support_relative,
        uniform_shift_correlation = nullspace_uniform_shift_correlation,
        max_compact_support = nullspace_max_compact_support,
    )
    report = DiagnosticReport()
    report.metadata[:expected_mode_free_coordinate_policy] =
        string(expected_mode_free_coordinate_policy)
    report.metadata[:expected_mode_free_coordinate_projection_enabled] =
        string(expected_mode_free_coordinate_policy == :project_free)
    report.metadata[:expected_mode_tangent_policy] = isnothing(expected_mode_tangent_policy) ?
        "none" : string(expected_mode_tangent_policy.name)
    report.metadata[:expected_mode_tangent_policy_variable_count] = isnothing(expected_mode_tangent_policy) ?
        "0" : string(length(expected_mode_tangent_policy.variables))
    report.metadata[:expected_mode_tangent_policy_description] = isnothing(expected_mode_tangent_policy) ?
        "" : expected_mode_tangent_policy.description
    if !isnothing(expected_mode_tangent_policy)
        for (key, value) in expected_mode_tangent_policy.metadata
            report.metadata[Symbol("expected_mode_tangent_policy_" * key)] = value
        end
    end
    append!(report.findings, _structural_numerical_findings(comparison))
    append!(report.findings, _nullspace_fingerprint_findings(comparison, evaluation, fingerprints))
    append!(report.findings, _unknown_local_degeneracy_findings(comparison, fingerprints))
    append!(
        report.findings,
        _expected_nullspace_mode_findings(
            comparison,
            all_expected_modes;
            residual_tolerance = expected_mode_residual_tolerance,
            free_coordinate_policy = expected_mode_free_coordinate_policy,
            tangent_policy = expected_mode_tangent_policy,
        ),
    )
    append!(
        report.findings,
        _expected_nullspace_span_findings(
            comparison,
            all_expected_modes;
            residual_tolerance = expected_mode_residual_tolerance,
            free_coordinate_policy = expected_mode_free_coordinate_policy,
            tangent_policy = expected_mode_tangent_policy,
        ),
    )
    if !isnothing(iterative_right_nullspace_probe_dimension)
        probe_report = analyze_iterative_right_nullspace_probe(
            evaluation;
            probe_dimension = iterative_right_nullspace_probe_dimension,
            iterations = iterative_right_nullspace_probe_iterations,
            convergence_tolerance = iterative_right_nullspace_probe_convergence_tolerance,
            residual_relative_tolerance =
                iterative_right_nullspace_probe_residual_relative_tolerance,
            support_relative = iterative_right_nullspace_probe_support_relative,
        )
        append!(report.findings, probe_report.findings)
        for (key, value) in probe_report.metadata
            key in (:stage, :evaluation_point_label) && continue
            report.metadata[key] = value
        end
    end
    if !isnothing(iterative_left_nullspace_probe_dimension)
        probe_report = analyze_iterative_left_nullspace_probe(
            evaluation;
            probe_dimension = iterative_left_nullspace_probe_dimension,
            iterations = iterative_left_nullspace_probe_iterations,
            convergence_tolerance = iterative_left_nullspace_probe_convergence_tolerance,
            residual_relative_tolerance =
                iterative_left_nullspace_probe_residual_relative_tolerance,
            support_relative = iterative_left_nullspace_probe_support_relative,
        )
        append!(report.findings, probe_report.findings)
        for (key, value) in probe_report.metadata
            key in (:stage, :evaluation_point_label) && continue
            report.metadata[key] = value
        end
    end
    if !isnothing(iterative_spectrum_probe_dimension)
        probe_report = analyze_iterative_jacobian_spectrum_probe(
            evaluation;
            probe_dimension = iterative_spectrum_probe_dimension,
            iterations = iterative_spectrum_probe_iterations,
            convergence_tolerance = iterative_spectrum_probe_convergence_tolerance,
            spectral_spread_threshold = iterative_spectrum_probe_spread_threshold,
        )
        append!(report.findings, probe_report.findings)
        for (key, value) in probe_report.metadata
            key in (:stage, :evaluation_point_label) && continue
            report.metadata[key] = value
        end
    end
    report.metadata[:stage] = "degeneracy"
    report.metadata[:evaluation_point_label] = evaluation.point.label
    report.metadata[:degeneracy_iterative_right_probe_requested] =
        string(!isnothing(iterative_right_nullspace_probe_dimension))
    report.metadata[:degeneracy_iterative_left_probe_requested] =
        string(!isnothing(iterative_left_nullspace_probe_dimension))
    report.metadata[:degeneracy_iterative_spectrum_probe_requested] =
        string(!isnothing(iterative_spectrum_probe_dimension))
    report.metadata[:structural_numerical_comparison_available] =
        string(comparison.available)
    report.metadata[:structural_matching_rank] =
        string(comparison.structural_matching_rank)
    report.metadata[:aligned_numerical_rank] = string(comparison.numerical_rank)
    report.metadata[:generic_nullspace_fingerprint_count] = string(length(fingerprints))
    report.metadata[:generic_nullspace_support_relative] = string(nullspace_support_relative)
    report.metadata[:generic_nullspace_uniform_shift_correlation] =
        string(nullspace_uniform_shift_correlation)
    report.metadata[:generic_nullspace_max_compact_support] =
        string(nullspace_max_compact_support)
    report.metadata[:declared_expected_nullspace_mode_count] = string(length(expected_modes))
    report.metadata[:port_expected_nullspace_mode_count] = string(length(port_modes))
    report.metadata[:port_expected_nullspace_independent_rank] =
        string(port_summary.rank)
    report.metadata[:port_expected_nullspace_relative_tolerance] =
        string(port_summary.relative_tolerance)
    report.metadata[:port_component_expected_nullspace_mode_count] =
        string(count(==(:component), port_summary.candidate_origins))
    report.metadata[:port_topology_expected_nullspace_mode_count] =
        string(count(==(:topology), port_summary.candidate_origins))
    _apply_point_provenance_guard!(report, evaluation.point)
    sort!(report.findings; by = finding -> (-Int(finding.severity), string(finding.code)))
    return report
end

function analyze_degeneracy(
    model::MOI.ModelLike,
    point::EvaluationPoint;
    cache::EvaluationCache = EvaluationCache(),
    kwargs...,
)
    return analyze_degeneracy(
        model,
        evaluate_numerical(model, point; cache = cache);
        kwargs...,
    )
end

function analyze_degeneracy(
    model::MOI.ModelLike,
    values::Union{AbstractVector{<:Real},AbstractDict{MOI.VariableIndex,<:Real}};
    label::AbstractString = "user",
    kwargs...,
)
    return analyze_degeneracy(
        model,
        evaluation_point(model, values; label = label);
        kwargs...,
    )
end
