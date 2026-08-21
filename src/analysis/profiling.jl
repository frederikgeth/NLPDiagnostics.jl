function _profile_stage!(seconds, allocations, key, operation)
    measured = @timed operation()
    seconds[key] = measured.time
    allocations[key] = measured.bytes
    return measured.value
end

_profile_sorted_data(values) = Dict(
    string(key) => values[key] for key in sort!(collect(keys(values)); by = string)
)

function _profile_case_data(case::ProfileCase)
    point_trust = select_trusted_evaluation_points([case.point])
    return Dict{String,Any}(
        "name" => case.name,
        "description" => case.description,
        "task" => case.task,
        "formulation" => case.formulation,
        "initialization" => case.initialization,
        "scale" => case.scale,
        "solver" => case.solver,
        "tags" => string.(case.tags),
        "metadata" => _profile_sorted_data(case.metadata),
        "expected_evidence" => string.(case.expected_evidence),
        "point" => _evaluation_point_data(case.point),
        "point_fingerprint" => evaluation_point_fingerprint(case.point),
        "point_trust" => trusted_point_selection_data(point_trust),
    )
end

"""Return renderer-neutral, serializable data for one retained profile run."""
function profile_result_data(result::ProfileResult)
    return Dict{String,Any}(
        "case" => _profile_case_data(result.case),
        "reports" => Dict(
            "static" => report_data(result.static_report),
            "expressions" => report_data(result.expression_report),
            "reformulation" => report_data(result.reformulation_report),
            "numerical" => report_data(result.numerical_report),
            "active_set" => report_data(result.active_set_report),
            "degeneracy" => report_data(result.degeneracy_report),
        ),
        "stage_seconds" => _profile_sorted_data(result.stage_seconds),
        "stage_allocations" => _profile_sorted_data(result.stage_allocations),
        "callback_statistics" => Dict(
            string(key) => Dict("count" => value[1], "seconds" => value[2]) for
            (key, value) in sort!(collect(result.callback_statistics); by = item -> string(first(item)))
        ),
        "derivative_row_method_counts" => _profile_sorted_data(result.derivative_row_method_counts),
        "capability_source_counts" => _profile_sorted_data(result.capability_source_counts),
        "cache" => Dict("hits" => result.cache_hits, "misses" => result.cache_misses),
    )
end

"""Return serializable data for a solver-result profile capture."""
function profile_result_data(result::SolverProfileResult)
    return Dict{String,Any}(
        "profile" => isnothing(result.profile) ? nothing : profile_result_data(result.profile),
        "case" => isnothing(result.case) ? nothing : _profile_case_data(result.case),
        "postmortem" => isnothing(result.postmortem) ? nothing : Dict(
            "solver" => result.postmortem.solver,
            "termination" => string(result.postmortem.termination),
            "raw_status" => result.postmortem.raw_status,
            "iterations" => result.postmortem.iterations,
            "objective_value" => result.postmortem.objective_value,
            "primal_residual" => result.postmortem.primal_residual,
            "dual_residual" => result.postmortem.dual_residual,
            "complementarity" => result.postmortem.complementarity,
            "restoration_attempted" => result.postmortem.restoration_attempted,
            "restoration_succeeded" => result.postmortem.restoration_succeeded,
            "metadata" => _profile_sorted_data(result.postmortem.metadata),
        ),
        "result_report" => report_data(result.result_report),
        "result_index" => result.result_index,
        "postmortem_read_error" => result.postmortem_read_error,
    )
end

"""Return serializable data for a trace-capturing solver profile run."""
function profile_result_data(result::SolverTraceProfileRun)
    return Dict{String,Any}(
        "iteration_trace" => iteration_trace_data(result.trace),
        "solver_profile" => profile_result_data(result.result),
    )
end

function _solver_trace_physical_endpoint_bundle(
    run::SolverTraceProfileRun,
    physical_endpoint::AbstractDict,
)
    trace_data = iteration_trace_data(run.trace)
    last_record = isempty(trace_data["records"]) ? nothing :
        last(trace_data["records"])
    endpoint_available = get(physical_endpoint, "acceptance_passed", nothing) !==
        nothing
    return Dict{String,Any}(
        "schema_version" => "solver-trace-physical-endpoint-v1",
        "available" => endpoint_available,
        "acceptance_passed" =>
            get(physical_endpoint, "acceptance_passed", nothing),
        "solver_trace_profile" => profile_result_data(run),
        "linear_solver_telemetry" => solver_linear_telemetry_data(run.trace),
        "last_captured_solver_record" => last_record,
        "physical_endpoint" => Dict{String,Any}(physical_endpoint),
        "evidence_relationship" => Dict{String,Any}(
            "native_trace_role" =>
                "solver-reported progress and stopping evidence in each record's declared coordinates",
            "physical_endpoint_role" =>
                "independently evaluated first-order endpoint evidence in caller-declared physical coordinates",
            "numeric_residual_comparison_performed" => false,
            "reason" =>
                "solver metrics and physical residuals are juxtaposed, not subtracted or ratioed, unless an explicit coordinate-and-tolerance translation is available",
            "same_endpoint_claim" =>
                "the physical endpoint is tied to the public solver result; the last captured trace row may precede that result",
        ),
    )
end

"""
    solver_trace_physical_endpoint_data(run, physical_endpoint)

Attach a precomputed physical endpoint contract to a retained solver trace.
The native trace is serialized unchanged, and no numerical comparison is made
between solver-scaled metrics and dimensional physical residuals.
"""
solver_trace_physical_endpoint_data(
    run::SolverTraceProfileRun,
    physical_endpoint::AbstractDict,
) = _solver_trace_physical_endpoint_bundle(run, physical_endpoint)

"""
    solver_trace_physical_endpoint_data(model, run, map;
        dual_snapshot_kwargs=NamedTuple(), physical_kkt_kwargs=NamedTuple())

Read the endpoint dual for the solver result retained by `run`, evaluate the
physical KKT contract using the exact cached endpoint evaluation, and return a
single serializable trace-plus-endpoint artifact. This function does not solve
the model or reinterpret native solver residuals.
"""
function solver_trace_physical_endpoint_data(
    model::MOI.ModelLike,
    run::SolverTraceProfileRun,
    map::Union{DiagonalScalingMap,SemanticBlockScalingMap};
    dual_snapshot_kwargs::NamedTuple = NamedTuple(),
    physical_kkt_kwargs::NamedTuple = NamedTuple(),
)
    profile = run.result.profile
    if isnothing(profile)
        return _solver_trace_physical_endpoint_bundle(
            run,
            Dict{String,Any}(
                "report_version" => "physical-kkt-acceptance-v2",
                "acceptance_passed" => nothing,
                "reason" =>
                    "the solver trace profile has no complete public endpoint evaluation",
            ),
        )
    end
    dual_options = merge(
        (result_index=run.result.result_index,), dual_snapshot_kwargs,
    )
    duals = solver_dual_snapshot(
        model, profile.evaluation; dual_options...,
    )
    endpoint = physical_kkt_acceptance_report(
        profile.evaluation, map, duals; physical_kkt_kwargs...,
    )
    return _solver_trace_physical_endpoint_bundle(run, endpoint)
end

const _SCALING_EXPERIMENT_INTERVENTIONS = Set((
    :baseline_repeat,
    :magnitude_only,
    :phase_only,
    :magnitude_and_phase,
    :general_coordinate_change,
))

function _physical_endpoint_tolerance_contract(endpoint::AbstractDict)
    primal = get(
        get(endpoint, "primal_feasibility", Dict()), "residuals", Dict(),
    )
    stationarity = get(
        get(endpoint, "stationarity", Dict()), "stationarity", Dict(),
    )
    complementarity = get(
        get(endpoint, "complementarity", Dict()), "sides", Dict(),
    )
    return Dict{String,Any}(
        "primal_feasibility" => Dict{String,Any}(
            string(key) => get(record, "absolute_tolerance", nothing)
            for (key, record) in primal
        ),
        "stationarity" => Dict{String,Any}(
            string(key) => get(record, "absolute_tolerance", nothing)
            for (key, record) in stationarity
        ),
        "dual_feasibility" => Dict{String,Any}(
            string(key) => get(record, "dual_absolute_tolerance", nothing)
            for (key, record) in complementarity
        ),
        "complementarity" => Dict{String,Any}(
            string(key) => get(
                record, "complementarity_absolute_tolerance", nothing,
            ) for (key, record) in complementarity
        ),
    )
end

"""
    physical_endpoint_equivalence_report(
        covariance_report, reference_endpoint, candidate_endpoint)

Convert a same-point physical covariance report into an endpoint-equivalence
gate. Physical points, constraint functions, sets, and Jacobians must remain
covariant, both KKT endpoints must pass, and their complete physical tolerance
contracts must agree. Near-zero constraint-residual differences are retained
as evidence but are judged by the endpoint acceptance contracts rather than by
an unrelated uniform covariance tolerance.
"""
function physical_endpoint_equivalence_report(
    covariance_report::AbstractDict,
    reference_endpoint::AbstractDict,
    candidate_endpoint::AbstractDict,
)
    metrics = get(covariance_report, "metrics", Dict())
    base_required_metrics = (
        "physical_point",
        "constraint_function_values",
        "constraint_sets",
        "physical_jacobian",
    )
    optional_objective_metrics = (
        "objective_value",
        "objective_gradient",
    )
    required_metrics = String[base_required_metrics...]
    for metric in optional_objective_metrics
        get(get(metrics, metric, Dict()), "available", false) === true &&
            push!(required_metrics, metric)
    end
    metric_gates = Dict{String,Any}(
        metric => get(get(metrics, metric, Dict()), "passed", nothing)
        for metric in required_metrics
    )
    required_covariance_passed = all(
        get(metric_gates, metric, nothing) === true for metric in required_metrics
    )
    reference_contract = _physical_endpoint_tolerance_contract(
        reference_endpoint,
    )
    candidate_contract = _physical_endpoint_tolerance_contract(
        candidate_endpoint,
    )
    tolerance_entry_count = sum(length, values(reference_contract); init=0) +
        sum(length, values(candidate_contract); init=0)
    contract_coverage_complete = tolerance_entry_count > 0 && all(
        value -> !isnothing(value),
        Iterators.flatten((values(section) for section in
            values(reference_contract))),
    ) && all(
        value -> !isnothing(value),
        Iterators.flatten((values(section) for section in
            values(candidate_contract))),
    )
    tolerance_contracts_agree = reference_contract == candidate_contract
    reference_accepted = get(
        reference_endpoint, "acceptance_passed", nothing,
    )
    candidate_accepted = get(
        candidate_endpoint, "acceptance_passed", nothing,
    )
    gate = required_covariance_passed && contract_coverage_complete &&
        tolerance_contracts_agree && reference_accepted === true &&
        candidate_accepted === true
    return Dict{String,Any}(
        "report_version" => "physical-endpoint-equivalence-v1",
        "available" => true,
        "equivalence_gate_passed" => gate,
        "required_covariance_metrics" => metric_gates,
        "objective_covariance_required" => Dict(
            metric => metric in required_metrics for
            metric in optional_objective_metrics
        ),
        "required_covariance_passed" => required_covariance_passed,
        "reference_endpoint_accepted" => reference_accepted,
        "candidate_endpoint_accepted" => candidate_accepted,
        "tolerance_contract_coverage_complete" =>
            contract_coverage_complete,
        "tolerance_entry_count" => tolerance_entry_count,
        "tolerance_contracts_agree" => tolerance_contracts_agree,
        "reference_tolerance_contract" => reference_contract,
        "candidate_tolerance_contract" => candidate_contract,
        "constraint_residual_covariance" =>
            get(metrics, "constraint_residuals", nothing),
        "source_covariance_report" => covariance_report,
        "qualification" => Dict{String,Any}(
            "claim" =>
                "physically covariant endpoint coordinates and derivatives with accepted common KKT tolerance semantics",
            "constraint_residual_covariance_is_required" => false,
            "reason" =>
                "two accepted near-zero residual vectors need not have a stable relative or uniform absolute difference",
            "does_not_establish" => [
                "exact equality of endpoint coordinates",
                "global solution uniqueness",
                "solver-policy superiority",
            ],
        ),
    )
end

function _scaling_experiment_trace(artifact::AbstractDict)
    profile = get(artifact, "solver_trace_profile", nothing)
    profile isa AbstractDict || return nothing
    trace = get(profile, "iteration_trace", nothing)
    return trace isa AbstractDict ? trace : nothing
end

function _scaling_experiment_endpoint(artifact::AbstractDict)
    endpoint = get(artifact, "physical_endpoint", nothing)
    return endpoint isa AbstractDict ? endpoint : nothing
end

function _scaling_experiment_work_summary(trace::AbstractDict)
    records = get(trace, "records", Any[])
    record_count = length(records)
    line_search_values = [
        get(record, "line_search_trials", nothing) for record in records
        if get(record, "line_search_trials", nothing) isa Integer
    ]
    final_iterations = [
        get(segment, "final_iteration", nothing) for
        segment in get(trace, "segments", Any[])
        if get(segment, "final_iteration", nothing) isa Integer
    ]
    return Dict{String,Any}(
        "record_count" => record_count,
        "segment_count" => get(trace, "segment_count", nothing),
        "final_iteration_by_segment" => final_iterations,
        "restoration_record_count" => count(
            record -> get(record, "phase", "") == "restoration", records,
        ),
        "line_search_trial_coverage" => length(line_search_values),
        "line_search_trial_coverage_complete" =>
            length(line_search_values) == record_count,
        "line_search_trial_sum" =>
            length(line_search_values) == record_count ?
            sum(line_search_values; init=0) : nothing,
    )
end

function _scaling_experiment_metric_semantics(trace::AbstractDict)
    fields = (
        "objective",
        "primal_infeasibility",
        "dual_infeasibility",
        "complementarity",
        "barrier_parameter",
    )
    records = get(trace, "records", Any[])
    result = Dict{String,Any}()
    for field in fields
        values = sort!(unique!(String[
            string(value) for record in records
            for value in (get(get(record, "metric_semantics", Dict()), field, nothing),)
            if !isnothing(value)
        ]))
        result[field] = Dict{String,Any}(
            "values" => values,
            "internally_consistent" => length(values) <= 1,
        )
    end
    return result
end

function _scaling_experiment_semantics_comparison(reference, candidate)
    fields = sort!(collect(union(Set(keys(reference)), Set(keys(candidate)))))
    records = Dict{String,Any}()
    compatible = true
    for field in fields
        reference_values = get(get(reference, field, Dict()), "values", String[])
        candidate_values = get(get(candidate, field, Dict()), "values", String[])
        field_compatible = reference_values == candidate_values &&
            length(reference_values) <= 1
        compatible &= field_compatible
        records[field] = Dict{String,Any}(
            "reference" => reference_values,
            "candidate" => candidate_values,
            "compatible" => field_compatible,
        )
    end
    return Dict{String,Any}(
        "compatible" => compatible,
        "metrics" => records,
    )
end

function _scaling_experiment_numeric_comparison(reference, candidate)
    ratio = candidate isa Real && reference isa Real && isfinite(candidate) &&
        isfinite(reference) && reference > 0 ? Float64(candidate / reference) : nothing
    return Dict{String,Any}(
        "reference" => reference,
        "candidate" => candidate,
        "candidate_to_reference_ratio" => ratio,
        "difference" => candidate isa Real && reference isa Real &&
            isfinite(candidate) && isfinite(reference) ?
            Float64(candidate - reference) : nothing,
    )
end

function _scaling_experiment_work_comparison(reference, candidate)
    scalar_metrics = (
        "record_count",
        "segment_count",
        "restoration_record_count",
        "line_search_trial_sum",
    )
    return Dict{String,Any}(
        metric => _scaling_experiment_numeric_comparison(
            get(reference, metric, nothing), get(candidate, metric, nothing),
        ) for metric in scalar_metrics
    )
end

function _scaling_experiment_family_endpoint_comparison(
    reference_endpoint::AbstractDict,
    candidate_endpoint::AbstractDict;
    allow_numeric_comparison::Bool,
)
    string_key_get(dictionary, key, default=nothing) = haskey(dictionary, key) ?
        dictionary[key] : haskey(dictionary, Symbol(key)) ?
        dictionary[Symbol(key)] : default
    reference_attribution = get(reference_endpoint, "semantic_attribution", nothing)
    candidate_attribution = get(candidate_endpoint, "semantic_attribution", nothing)
    if !(reference_attribution isa AbstractDict &&
         candidate_attribution isa AbstractDict)
        return Dict{String,Any}(
            "available" => false,
            "reason" => "one or both physical endpoints lack semantic attribution",
        )
    end
    sections = Dict{String,Any}()
    family_sets_agree = true
    for section in ("primal_feasibility", "stationarity", "complementarity")
        reference_families = get(
            get(reference_attribution, section, Dict()), "families", Dict(),
        )
        candidate_families = get(
            get(candidate_attribution, section, Dict()), "families", Dict(),
        )
        reference_names = Set(string.(keys(reference_families)))
        candidate_names = Set(string.(keys(candidate_families)))
        family_sets_agree &= reference_names == candidate_names
        family_records = Dict{String,Any}()
        for family in sort!(collect(intersect(reference_names, candidate_names)))
            reference_family = string_key_get(
                reference_families, family, Dict{String,Any}(),
            )
            candidate_family = string_key_get(
                candidate_families, family, Dict{String,Any}(),
            )
            reference_maxima = get(reference_family, "maxima", Dict())
            candidate_maxima = get(candidate_family, "maxima", Dict())
            metrics = Dict{String,Any}()
            for metric in sort!(collect(union(
                Set(string.(keys(reference_maxima))),
                Set(string.(keys(candidate_maxima))),
            )))
                metrics[metric] = allow_numeric_comparison ?
                    _scaling_experiment_numeric_comparison(
                        string_key_get(reference_maxima, metric),
                        string_key_get(candidate_maxima, metric),
                    ) : Dict{String,Any}(
                        "reference" => string_key_get(reference_maxima, metric),
                        "candidate" => string_key_get(candidate_maxima, metric),
                        "candidate_to_reference_ratio" => nothing,
                        "difference" => nothing,
                        "withheld" => "physical covariance gate did not pass",
                    )
            end
            family_records[family] = Dict{String,Any}(
                "metrics" => metrics,
                "reference_passed_count" =>
                    get(reference_family, "passed_count", nothing),
                "candidate_passed_count" =>
                    get(candidate_family, "passed_count", nothing),
                "reference_failed_count" =>
                    get(reference_family, "failed_count", nothing),
                "candidate_failed_count" =>
                    get(candidate_family, "failed_count", nothing),
            )
        end
        sections[section] = Dict{String,Any}(
            "family_sets_agree" => reference_names == candidate_names,
            "reference_only_families" =>
                sort!(collect(setdiff(reference_names, candidate_names))),
            "candidate_only_families" =>
                sort!(collect(setdiff(candidate_names, reference_names))),
            "families" => family_records,
        )
    end
    return Dict{String,Any}(
        "available" => true,
        "numeric_comparison_allowed" => allow_numeric_comparison,
        "family_sets_agree" => family_sets_agree,
        "sections" => sections,
    )
end

"""
    scaling_solver_experiment_comparison(reference, candidate; ...)

Build a score-free matched scaling-experiment artifact from two retained
trace-plus-physical-endpoint artifacts. Solver-native work, physical endpoint
acceptance, semantic family residuals, covariance, and coordinate geometry
remain separate evidence layers. The caller must declare the intervention;
this function does not infer that a policy changed only magnitude or phase.
"""
function scaling_solver_experiment_comparison(
    reference::AbstractDict,
    candidate::AbstractDict;
    intervention::Symbol,
    intervention_report::Union{Nothing,AbstractDict}=nothing,
    covariance_report::Union{Nothing,AbstractDict}=nothing,
    geometry_report::Union{Nothing,AbstractDict}=nothing,
    hypothesis::AbstractString="",
    metadata::AbstractDict=Dict{String,Any}(),
)
    intervention in _SCALING_EXPERIMENT_INTERVENTIONS || throw(ArgumentError(
        "intervention must be one of $(sort!(collect(_SCALING_EXPERIMENT_INTERVENTIONS)))",
    ))
    reference_trace = _scaling_experiment_trace(reference)
    candidate_trace = _scaling_experiment_trace(candidate)
    reference_endpoint = _scaling_experiment_endpoint(reference)
    candidate_endpoint = _scaling_experiment_endpoint(candidate)
    artifacts_available = reference_trace isa AbstractDict &&
        candidate_trace isa AbstractDict &&
        reference_endpoint isa AbstractDict &&
        candidate_endpoint isa AbstractDict
    if !artifacts_available
        return Dict{String,Any}(
            "schema_version" => "scaling-solver-experiment-comparison-v1",
            "available" => false,
            "comparison_qualified" => false,
            "intervention" => string(intervention),
            "reason" =>
                "both inputs must contain solver_trace_profile.iteration_trace and physical_endpoint",
        )
    end
    reference_work = _scaling_experiment_work_summary(reference_trace)
    candidate_work = _scaling_experiment_work_summary(candidate_trace)
    reference_semantics = _scaling_experiment_metric_semantics(reference_trace)
    candidate_semantics = _scaling_experiment_metric_semantics(candidate_trace)
    semantics = _scaling_experiment_semantics_comparison(
        reference_semantics, candidate_semantics,
    )
    covariance_passed = covariance_report isa AbstractDict ?
        get(covariance_report, "equivalence_gate_passed", nothing) : nothing
    geometry_qualified = geometry_report isa AbstractDict ? get(
        geometry_report,
        "semantic_interpretation_qualified",
        get(geometry_report, "comparison_qualified", nothing),
    ) : nothing
    reference_endpoint_passed =
        get(reference_endpoint, "acceptance_passed", nothing)
    candidate_endpoint_passed =
        get(candidate_endpoint, "acceptance_passed", nothing)
    expected_intervention_class = intervention == :baseline_repeat ?
        "identity" : string(intervention)
    observed_intervention_class = intervention_report isa AbstractDict ?
        get(intervention_report, "classification", nothing) : nothing
    intervention_verified = intervention_report isa AbstractDict ?
        get(intervention_report, "available", false) === true &&
        observed_intervention_class == expected_intervention_class : nothing
    endpoint_comparison = _scaling_experiment_family_endpoint_comparison(
        reference_endpoint,
        candidate_endpoint;
        allow_numeric_comparison=covariance_passed === true,
    )
    comparison_qualified = covariance_passed === true &&
        geometry_qualified === true &&
        intervention_verified === true &&
        reference_endpoint_passed === true &&
        candidate_endpoint_passed === true &&
        semantics["compatible"] === true &&
        get(endpoint_comparison, "available", false) === true &&
        get(endpoint_comparison, "family_sets_agree", false) === true
    return Dict{String,Any}(
        "schema_version" => "scaling-solver-experiment-comparison-v1",
        "available" => true,
        "comparison_qualified" => comparison_qualified,
        "intervention" => string(intervention),
        "intervention_verification" => Dict{String,Any}(
            "expected_classification" => expected_intervention_class,
            "observed_classification" => observed_intervention_class,
            "verified" => intervention_verified,
            "report" => intervention_report,
        ),
        "hypothesis" => String(hypothesis),
        "metadata" => Dict{String,Any}(
            string(key) => value for (key, value) in metadata
        ),
        "gates" => Dict{String,Any}(
            "physical_covariance_passed" => covariance_passed,
            "semantic_geometry_qualified" => geometry_qualified,
            "intervention_verified" => intervention_verified,
            "reference_physical_endpoint_passed" => reference_endpoint_passed,
            "candidate_physical_endpoint_passed" => candidate_endpoint_passed,
            "native_metric_semantics_compatible" => semantics["compatible"],
            "endpoint_family_sets_agree" =>
                get(endpoint_comparison, "family_sets_agree", nothing),
        ),
        "native_work" => Dict{String,Any}(
            "reference" => reference_work,
            "candidate" => candidate_work,
            "comparisons" => _scaling_experiment_work_comparison(
                reference_work, candidate_work,
            ),
            "metric_semantics" => semantics,
        ),
        "physical_endpoint_families" => endpoint_comparison,
        "covariance_report" => covariance_report,
        "geometry_report" => geometry_report,
        "qualification" => Dict{String,Any}(
            "claim" =>
                "matched, score-free comparison of declared scaling interventions",
            "intervention_is_inferred" => false,
            "solver_native_and_physical_metrics_are_ratioed" => false,
            "does_not_establish" => [
                "global policy superiority",
                "causality from a single matched solve pair",
                "intervention purity beyond the caller declaration",
                "equivalence when the covariance gate is absent or failed",
            ],
        ),
    )
end

function _scaling_campaign_numeric_range(values)
    numbers = Float64[
        Float64(value) for value in values if
        value isa Real && isfinite(Float64(value))
    ]
    isempty(numbers) && return Dict{String,Any}(
        "available" => false,
        "sample_count" => 0,
    )
    return Dict{String,Any}(
        "available" => true,
        "sample_count" => length(numbers),
        "minimum" => minimum(numbers),
        "maximum" => maximum(numbers),
        "spread" => maximum(numbers) - minimum(numbers),
        "mean" => sum(numbers) / length(numbers),
    )
end

function _scaling_campaign_run_summary(records)
    artifacts = [get(record, "artifact", Dict()) for record in records]
    traces = [_scaling_experiment_trace(artifact) for artifact in artifacts]
    endpoints = [_scaling_experiment_endpoint(artifact) for artifact in artifacts]
    work = [
        trace isa AbstractDict ? _scaling_experiment_work_summary(trace) :
        Dict{String,Any}() for trace in traces
    ]
    terminations = Any[]
    for artifact in artifacts
        solver_profile = get(
            get(artifact, "solver_trace_profile", Dict()),
            "solver_profile",
            Dict(),
        )
        postmortem = get(solver_profile, "postmortem", nothing)
        push!(
            terminations,
            postmortem isa AbstractDict ?
            get(postmortem, "termination", nothing) : nothing,
        )
    end
    finite_terminations = filter(!isnothing, terminations)
    endpoint_acceptance = [
        endpoint isa AbstractDict ?
        get(endpoint, "acceptance_passed", nothing) : nothing
        for endpoint in endpoints
    ]
    common_start_covariance = [
        get(record, "common_start_covariance_passed", nothing)
        for record in records
    ]
    native_initialization_covariance = [
        get(record, "native_initialization_covariance_passed", nothing)
        for record in records
    ]
    replicates = [get(record, "replicate", nothing) for record in records]
    return Dict{String,Any}(
        "run_count" => length(records),
        "replicates" => replicates,
        "replicate_ids_unique" => length(unique(replicates)) == length(replicates),
        "artifact_available_count" => count(
            artifact -> get(artifact, "available", false) === true, artifacts,
        ),
        "physical_endpoint_acceptance" => endpoint_acceptance,
        "all_physical_endpoints_accepted" =>
            !isempty(endpoint_acceptance) && all(==(true), endpoint_acceptance),
        "common_start_covariance" => common_start_covariance,
        "common_start_covariance_coverage_complete" =>
            all(value -> value isa Bool, common_start_covariance),
        "all_common_starts_covariant" =>
            !isempty(common_start_covariance) &&
            all(==(true), common_start_covariance),
        "native_initialization_covariance" =>
            native_initialization_covariance,
        "native_initialization_covariance_coverage_complete" =>
            all(value -> value isa Bool, native_initialization_covariance),
        "all_native_initializations_covariant" =>
            !isempty(native_initialization_covariance) &&
            all(==(true), native_initialization_covariance),
        "termination_values" => sort!(unique!(string.(finite_terminations))),
        "termination_coverage_complete" =>
            length(finite_terminations) == length(records),
        "termination_stable" => length(finite_terminations) == length(records) &&
            length(unique(string.(finite_terminations))) == 1,
        "record_count_range" => _scaling_campaign_numeric_range([
            get(item, "record_count", nothing) for item in work
        ]),
        "line_search_trial_sum_range" => _scaling_campaign_numeric_range([
            get(item, "line_search_trial_sum", nothing) for item in work
        ]),
        "restoration_record_count_range" => _scaling_campaign_numeric_range([
            get(item, "restoration_record_count", nothing) for item in work
        ]),
    )
end

function _scaling_campaign_comparison_summary(records)
    comparisons = [get(record, "comparison", Dict()) for record in records]
    qualified = [
        get(comparison, "comparison_qualified", false) === true
        for comparison in comparisons
    ]
    ratios = Dict{String,Any}()
    for metric in (
        "record_count", "line_search_trial_sum", "restoration_record_count",
    )
        ratios[metric] = _scaling_campaign_numeric_range([
            get(
                get(
                    get(comparison, "native_work", Dict()),
                    "comparisons",
                    Dict(),
                ),
                metric,
                Dict(),
            )["candidate_to_reference_ratio"] for comparison in comparisons
            if haskey(
                get(
                    get(
                        get(comparison, "native_work", Dict()),
                        "comparisons",
                        Dict(),
                    ),
                    metric,
                    Dict(),
                ),
                "candidate_to_reference_ratio",
            )
        ])
    end
    observed_classes = Any[
        get(
            get(comparison, "intervention_verification", Dict()),
            "observed_classification",
            nothing,
        ) for comparison in comparisons
    ]
    geometry_ratio_ranges = Dict{String,Any}()
    for metric in ("condition_proxy", "row_norm_spread", "column_norm_spread")
        geometry_ratio_ranges[metric] = _scaling_campaign_numeric_range([
            get(
                get(
                    get(comparison, "geometry_report", Dict()),
                    "comparisons",
                    Dict(),
                ),
                metric,
                Dict(),
            )["candidate_to_reference_ratio"] for comparison in comparisons
            if haskey(
                get(
                    get(
                        get(comparison, "geometry_report", Dict()),
                        "comparisons",
                        Dict(),
                    ),
                    metric,
                    Dict(),
                ),
                "candidate_to_reference_ratio",
            )
        ])
    end
    endpoint_residual_covariance = [
        get(
            get(comparison, "covariance_report", Dict()),
            "constraint_residual_covariance",
            nothing,
        ) for comparison in comparisons
    ]
    return Dict{String,Any}(
        "comparison_count" => length(records),
        "qualified_count" => count(identity, qualified),
        "all_qualified" => !isempty(qualified) && all(identity, qualified),
        "observed_intervention_classes" =>
            sort!(unique!(string.(filter(!isnothing, observed_classes)))),
        "native_work_ratio_ranges" => ratios,
        "geometry_ratio_ranges" => geometry_ratio_ranges,
        "endpoint_residual_difference_range" =>
            _scaling_campaign_numeric_range([
                get(record, "maximum_absolute_difference", nothing)
                for record in endpoint_residual_covariance
                if record isa AbstractDict
            ]),
        "exact_endpoint_residual_covariance_pass_count" => count(
            record -> record isa AbstractDict &&
                get(record, "passed", false) === true,
            endpoint_residual_covariance,
        ),
        "endpoint_residual_covariance_is_qualification_gate" => false,
    )
end

"""
    scaling_solver_experiment_campaign_data(runs, comparisons; ...)

Aggregate repeated matched scaling runs without ranking policies. Each run
record must contain `policy`, `replicate`, `provenance_fingerprint`, and
`artifact`, plus the explicit `common_start_covariance_passed` gate. A caller
may additionally require independently generated engine starts to pass
`native_initialization_covariance_passed`. Each
comparison record must contain `candidate_policy` and
`comparison`. Qualification requires repeated coverage, stable provenance,
accepted physical endpoints, stable termination, and qualified matched
comparisons for every policy.
"""
function scaling_solver_experiment_campaign_data(
    runs::AbstractVector,
    comparisons::AbstractVector;
    reference_policy::AbstractString,
    minimum_repeats::Integer=2,
    require_native_initialization_covariance::Bool=false,
    metadata::AbstractDict=Dict{String,Any}(),
)
    minimum_repeats >= 2 || throw(ArgumentError(
        "minimum_repeats must be at least two for a repeatability campaign",
    ))
    isempty(strip(reference_policy)) && throw(ArgumentError(
        "reference_policy must not be empty",
    ))
    all(record -> record isa AbstractDict, runs) || throw(ArgumentError(
        "runs must contain dictionary records",
    ))
    all(record -> record isa AbstractDict, comparisons) || throw(ArgumentError(
        "comparisons must contain dictionary records",
    ))
    policy_records = Dict{String,Vector{Any}}()
    for record in runs
        policy = string(get(record, "policy", ""))
        isempty(policy) && throw(ArgumentError(
            "each run record must contain a nonempty policy",
        ))
        haskey(record, "artifact") || throw(ArgumentError(
            "each run record must contain an artifact",
        ))
        push!(get!(policy_records, policy, Any[]), record)
    end
    haskey(policy_records, String(reference_policy)) || throw(ArgumentError(
        "reference_policy $(repr(reference_policy)) has no run records",
    ))
    policy_summaries = Dict{String,Any}(
        policy => _scaling_campaign_run_summary(records)
        for (policy, records) in sort!(collect(policy_records); by=first)
    )
    fingerprints = [
        get(record, "provenance_fingerprint", nothing) for record in runs
    ]
    fingerprint_coverage_complete = all(!isnothing, fingerprints)
    provenance_stable = fingerprint_coverage_complete &&
        length(unique(string.(fingerprints))) == 1
    comparison_records = Dict{String,Vector{Any}}()
    for record in comparisons
        candidate_policy = string(get(record, "candidate_policy", ""))
        isempty(candidate_policy) && throw(ArgumentError(
            "each comparison record must contain a nonempty candidate_policy",
        ))
        haskey(record, "comparison") || throw(ArgumentError(
            "each comparison record must contain a comparison",
        ))
        push!(get!(comparison_records, candidate_policy, Any[]), record)
    end
    comparison_summaries = Dict{String,Any}(
        policy => _scaling_campaign_comparison_summary(records)
        for (policy, records) in sort!(collect(comparison_records); by=first)
    )
    run_coverage_complete = all(
        get(summary, "run_count", 0) >= minimum_repeats &&
        get(summary, "replicate_ids_unique", false) === true
        for summary in values(policy_summaries)
    )
    endpoints_accepted = all(
        get(summary, "all_physical_endpoints_accepted", false) === true
        for summary in values(policy_summaries)
    )
    common_starts_covariant = all(
        get(summary, "all_common_starts_covariant", false) === true
        for summary in values(policy_summaries)
    )
    native_initialization_coverage_complete = all(
        get(
            summary,
            "native_initialization_covariance_coverage_complete",
            false,
        ) === true for summary in values(policy_summaries)
    )
    native_initializations_covariant =
        !require_native_initialization_covariance || all(
            get(
                summary, "all_native_initializations_covariant", false,
            ) === true for summary in values(policy_summaries)
        )
    terminations_stable = all(
        get(summary, "termination_stable", false) === true
        for summary in values(policy_summaries)
    )
    expected_comparison_policies = Set(keys(policy_records))
    comparison_policy_coverage = Set(keys(comparison_records)) ==
        expected_comparison_policies
    comparison_coverage_complete = comparison_policy_coverage && all(
        begin
            required = policy == reference_policy ? minimum_repeats - 1 :
                minimum_repeats
            get(comparison_summaries[policy], "comparison_count", 0) >= required
        end for policy in keys(policy_records)
    )
    all_comparisons_qualified = comparison_coverage_complete && all(
        get(comparison_summaries[policy], "all_qualified", false) === true
        for policy in keys(policy_records)
    )
    campaign_qualified = run_coverage_complete && provenance_stable &&
        common_starts_covariant && native_initializations_covariant &&
        endpoints_accepted && terminations_stable && all_comparisons_qualified
    return Dict{String,Any}(
        "schema_version" => "scaling-solver-experiment-campaign-v1",
        "available" => !isempty(runs),
        "campaign_qualified" => campaign_qualified,
        "reference_policy" => String(reference_policy),
        "minimum_repeats" => Int(minimum_repeats),
        "policy_count" => length(policy_records),
        "run_count" => length(runs),
        "comparison_count" => length(comparisons),
        "gates" => Dict{String,Any}(
            "run_coverage_complete" => run_coverage_complete,
            "provenance_fingerprint_coverage_complete" =>
                fingerprint_coverage_complete,
            "provenance_stable" => provenance_stable,
            "all_common_starts_covariant" => common_starts_covariant,
            "native_initialization_covariance_required" =>
                require_native_initialization_covariance,
            "native_initialization_covariance_coverage_complete" =>
                native_initialization_coverage_complete,
            "all_native_initializations_covariant" =>
                native_initializations_covariant,
            "all_physical_endpoints_accepted" => endpoints_accepted,
            "terminations_stable_within_policy" => terminations_stable,
            "comparison_policy_coverage_complete" =>
                comparison_policy_coverage,
            "comparison_coverage_complete" => comparison_coverage_complete,
            "all_comparisons_qualified" => all_comparisons_qualified,
        ),
        "provenance_fingerprints" =>
            sort!(unique!(string.(filter(!isnothing, fingerprints)))),
        "policies" => policy_summaries,
        "comparisons" => comparison_summaries,
        "run_records" => collect(runs),
        "comparison_records" => collect(comparisons),
        "metadata" => Dict{String,Any}(
            string(key) => value for (key, value) in metadata
        ),
        "qualification" => Dict{String,Any}(
            "claim" =>
                "repeatability-qualified, score-free matched scaling campaign",
            "does_not_establish" => [
                "global policy superiority",
                "performance portability to another solver or case family",
                "causality without the retained intervention and covariance evidence",
            ],
        ),
    )
end

function _scaling_stratified_policy_summary(campaigns, policy)
    records = Any[
        record for campaign in campaigns for record in
        get(campaign, "run_records", Any[])
        if string(get(record, "policy", "")) == policy
    ]
    summary = _scaling_campaign_run_summary(records)
    summary["stratum_count"] = length(campaigns)
    return summary
end

"""
    scaling_solver_experiment_stratified_campaign_data(records; ...)

Aggregate complete repeated scaling campaigns across physically distinct start
strata. Each record must contain a unique `stratum` and a `campaign` produced by
[`scaling_solver_experiment_campaign_data`](@ref). Qualification is deliberately
strict: every stratum campaign must qualify independently, use the same policy
set and reference policy, have stable environment provenance, and meet the
declared repeat floor. Results remain available per stratum so initialization
effects are not erased by pooling.
"""
function scaling_solver_experiment_stratified_campaign_data(
    records::AbstractVector;
    minimum_strata::Integer=2,
    minimum_repeats::Integer=2,
    metadata::AbstractDict=Dict{String,Any}(),
)
    minimum_strata >= 2 || throw(ArgumentError(
        "minimum_strata must be at least two",
    ))
    minimum_repeats >= 2 || throw(ArgumentError(
        "minimum_repeats must be at least two",
    ))
    all(record -> record isa AbstractDict, records) || throw(ArgumentError(
        "records must contain dictionary records",
    ))
    strata = String[]
    campaigns = Any[]
    for record in records
        stratum = string(get(record, "stratum", ""))
        isempty(stratum) && throw(ArgumentError(
            "each record must contain a nonempty stratum",
        ))
        campaign = get(record, "campaign", nothing)
        campaign isa AbstractDict || throw(ArgumentError(
            "each record must contain a campaign dictionary",
        ))
        push!(strata, stratum)
        push!(campaigns, campaign)
    end
    unique_strata = length(unique(strata)) == length(strata)
    stratum_coverage_complete = length(records) >= minimum_strata && unique_strata
    campaigns_qualified = !isempty(campaigns) && all(
        get(campaign, "campaign_qualified", false) === true
        for campaign in campaigns
    )
    repeat_coverage_complete = !isempty(campaigns) && all(
        get(campaign, "minimum_repeats", 0) >= minimum_repeats
        for campaign in campaigns
    )
    reference_policies = string.([
        get(campaign, "reference_policy", "") for campaign in campaigns
    ])
    reference_policy_consistent = !isempty(reference_policies) &&
        all(!isempty, reference_policies) &&
        length(unique(reference_policies)) == 1
    policy_sets = [
        Set(string.(keys(get(campaign, "policies", Dict()))))
        for campaign in campaigns
    ]
    policy_coverage_consistent = !isempty(policy_sets) &&
        !isempty(first(policy_sets)) && all(==(first(policy_sets)), policy_sets)
    fingerprints = [
        string(fingerprint) for campaign in campaigns for fingerprint in
        get(campaign, "provenance_fingerprints", Any[])
    ]
    provenance_coverage_complete = length(fingerprints) >= length(campaigns) &&
        all(campaign -> !isempty(
            get(campaign, "provenance_fingerprints", Any[]),
        ), campaigns)
    provenance_stable = provenance_coverage_complete &&
        length(unique(fingerprints)) == 1
    policy_summaries = policy_coverage_consistent ? Dict{String,Any}(
        policy => _scaling_stratified_policy_summary(campaigns, policy)
        for policy in sort!(collect(first(policy_sets)))
    ) : Dict{String,Any}()
    qualified = stratum_coverage_complete && campaigns_qualified &&
        repeat_coverage_complete && reference_policy_consistent &&
        policy_coverage_consistent && provenance_stable
    return Dict{String,Any}(
        "schema_version" => "scaling-solver-experiment-stratified-campaign-v1",
        "available" => !isempty(records),
        "campaign_qualified" => qualified,
        "minimum_strata" => Int(minimum_strata),
        "minimum_repeats" => Int(minimum_repeats),
        "stratum_count" => length(records),
        "strata" => strata,
        "reference_policy" => reference_policy_consistent ?
            first(reference_policies) : nothing,
        "gates" => Dict{String,Any}(
            "stratum_coverage_complete" => stratum_coverage_complete,
            "stratum_ids_unique" => unique_strata,
            "all_stratum_campaigns_qualified" => campaigns_qualified,
            "repeat_coverage_complete" => repeat_coverage_complete,
            "reference_policy_consistent" => reference_policy_consistent,
            "policy_coverage_consistent" => policy_coverage_consistent,
            "provenance_fingerprint_coverage_complete" =>
                provenance_coverage_complete,
            "provenance_stable" => provenance_stable,
        ),
        "provenance_fingerprints" => sort!(unique(fingerprints)),
        "policies" => policy_summaries,
        "stratum_records" => collect(records),
        "metadata" => Dict{String,Any}(
            string(key) => value for (key, value) in metadata
        ),
        "qualification" => Dict{String,Any}(
            "claim" =>
                "repeatability-qualified matched scaling evidence across explicitly distinct physical-start strata",
            "does_not_establish" => [
                "global policy superiority",
                "initialization-independent behavior outside the retained strata",
                "performance portability to another solver or case family",
            ],
        ),
    )
end

function _trace_geometry_selected_bindings(
    trace::SolverIterationTrace;
    phase::Union{Nothing,Symbol},
    max_points::Union{Nothing,Integer},
)
    isnothing(phase) || phase in (:regular, :restoration, :robust) ||
        throw(ArgumentError(
            "phase must be nothing, :regular, :restoration, or :robust",
        ))
    if !isnothing(max_points)
        max_points >= 1 || throw(ArgumentError(
            "max_points must be positive when supplied",
        ))
    end
    candidates = [
        binding for binding in trace.bindings
        if isnothing(phase) || binding.record.phase == phase
    ]
    if isnothing(max_points) || length(candidates) <= max_points
        return candidates, length(candidates)
    end
    budget = Int(max_points)
    priority = Int[1]
    budget > 1 && push!(priority, length(candidates))
    for index in 2:length(candidates)
        if candidates[index].record.phase != candidates[index - 1].record.phase
            push!(priority, index - 1, index)
        end
    end
    regularized = filter(
        index -> begin
            value = candidates[index].record.regularization_size
            value isa Real && isfinite(value) && value > 0
        end,
        eachindex(candidates),
    )
    sort!(regularized; by=index -> (
        -Float64(candidates[index].record.regularization_size), index,
    ))
    append!(priority, regularized)
    for field in (
        :primal_infeasibility,
        :dual_infeasibility,
        :complementarity,
        :step_norm,
        :line_search_trials,
    )
        finite_indices = filter(
            index -> begin
                value = getfield(candidates[index].record, field)
                value isa Real && isfinite(value)
            end,
            eachindex(candidates),
        )
        isempty(finite_indices) || push!(
            priority,
            finite_indices[argmax(Float64[
                abs(getfield(candidates[index].record, field))
                for index in finite_indices
            ])],
        )
    end
    uniform = budget == 1 ? Int[1] : round.(Int, range(
        1, length(candidates); length=budget,
    ))
    selected_indices = Int[]
    for index in Iterators.flatten((priority, uniform))
        index in selected_indices && continue
        push!(selected_indices, index)
        length(selected_indices) == budget && break
    end
    sort!(selected_indices)
    return candidates[selected_indices], length(candidates)
end

function _trace_geometry_numeric_summary(values)
    finite = Float64[
        Float64(value) for value in values if value isa Real && isfinite(value)
    ]
    positive = filter(>(0.0), finite)
    return Dict{String,Any}(
        "sample_count" => length(values),
        "available_count" => length(finite),
        "first" => isempty(finite) ? nothing : first(finite),
        "last" => isempty(finite) ? nothing : last(finite),
        "minimum" => isempty(finite) ? nothing : minimum(finite),
        "maximum" => isempty(finite) ? nothing : maximum(finite),
        "maximum_to_minimum_positive_ratio" => isempty(positive) ? nothing :
            maximum(positive) / minimum(positive),
    )
end

function _trace_geometry_family_trajectories(snapshots, axis, metrics)
    families = sort!(unique!(String[
        string(family) for snapshot in snapshots
        if get(snapshot, "available", false) === true
        for family in keys(get(get(snapshot, axis, Dict()), "families", Dict()))
    ]))
    return Dict{String,Any}(
        family => Dict{String,Any}(
            metric => _trace_geometry_numeric_summary([
                get(
                    get(
                        get(get(snapshot, axis, Dict()), "families", Dict()),
                        family,
                        Dict(),
                    ),
                    metric,
                    nothing,
                ) for snapshot in snapshots
            ]) for metric in metrics
        ) for family in families
    )
end

"""
    iteration_trace_jacobian_family_geometry_data(model, trace; ...)

Evaluate selected, explicitly captured solver iterates and retain local
Jacobian row/column-family geometry beside the corresponding callback metrics.
The trajectory is descriptive. It does not infer model coordinates for
metric-only callbacks or claim that a family caused regularization or solver
work.
"""
function iteration_trace_jacobian_family_geometry_data(
    model::MOI.ModelLike,
    trace::SolverIterationTrace;
    row_labels,
    column_labels,
    phase::Union{Nothing,Symbol}=nothing,
    max_points::Union{Nothing,Integer}=nothing,
)
    selected, candidate_count = _trace_geometry_selected_bindings(
        trace; phase, max_points,
    )
    snapshots = Dict{String,Any}[]
    for binding in selected
        snapshot = Dict{String,Any}(
            "iteration" => binding.record.iteration,
            "segment" => binding.segment,
            "phase" => string(binding.record.phase),
            "point_label" => binding.point.label,
            "point_fingerprint" => evaluation_point_fingerprint(binding.point),
            "solver_metrics" => Dict{String,Any}(
                "objective" => binding.record.objective,
                "primal_infeasibility" => binding.record.primal_infeasibility,
                "dual_infeasibility" => binding.record.dual_infeasibility,
                "complementarity" => binding.record.complementarity,
                "barrier_parameter" => binding.record.barrier_parameter,
                "step_norm" => binding.record.step_norm,
                "regularization_size" => binding.record.regularization_size,
                "primal_step" => binding.record.primal_step,
                "dual_step" => binding.record.dual_step,
                "line_search_trials" => binding.record.line_search_trials,
                "linear_telemetry" => copy(binding.record.linear_telemetry),
            ),
        )
        try
            evaluation = evaluate_numerical(model, binding.point)
            rows = jacobian_row_family_scale_attribution(
                evaluation, row_labels,
            )
            columns = jacobian_column_family_scale_attribution(
                evaluation, column_labels,
            )
            snapshot["available"] = true
            snapshot["rows"] = rows
            snapshot["columns"] = columns
            snapshot["derivative_rows_complete"] =
                get(columns, "derivative_rows_complete", false)
        catch error
            snapshot["available"] = false
            snapshot["reason"] = sprint(showerror, error)
        end
        push!(snapshots, snapshot)
    end
    available_count = count(
        snapshot -> get(snapshot, "available", false) === true, snapshots,
    )
    row_metrics = (
        "smallest_positive_row_norm",
        "row_norm_median",
        "largest_finite_row_norm",
        "row_scale_ratio",
    )
    column_metrics = (
        "smallest_positive_column_norm",
        "column_norm_median",
        "largest_finite_column_norm",
        "column_scale_ratio",
    )
    return Dict{String,Any}(
        "schema_version" => "iteration-trace-jacobian-family-geometry-v1",
        "available" => available_count > 0,
        "coverage_complete" => !isempty(selected) &&
            available_count == length(selected),
        "trace_record_count" => length(trace.records),
        "trace_binding_count" => length(trace.bindings),
        "candidate_binding_count" => candidate_count,
        "selected_binding_count" => length(selected),
        "available_snapshot_count" => available_count,
        "phase_filter" => isnothing(phase) ? "all" : string(phase),
        "max_points" => isnothing(max_points) ? nothing : Int(max_points),
        "selected_iterations" => [
            binding.record.iteration for binding in selected
        ],
        "snapshots" => snapshots,
        "trajectories" => Dict{String,Any}(
            "rows" => _trace_geometry_family_trajectories(
                snapshots, "rows", row_metrics,
            ),
            "columns" => _trace_geometry_family_trajectories(
                snapshots, "columns", column_metrics,
            ),
        ),
        "qualification" => Dict{String,Any}(
            "claim" =>
                "local Jacobian family geometry along explicitly captured solver iterates",
            "selection_policy" =>
                "event-preserving bounded selection after optional phase filtering: endpoints, phase boundaries, largest positive regularization rows, solver-metric extrema, then uniform fill",
            "does_not_establish" => [
                "causality between family geometry and solver telemetry",
                "KKT factorization conditioning",
                "geometry at callback rows without captured model coordinates",
            ],
        ),
    )
end

"""Return renderer-neutral, serializable data for a repeated profile aggregate."""
function profile_aggregate_data(aggregate::ProfileAggregate)
    timing_data = Dict(
        string(stage) => Dict(
            "sample_count" => summary.sample_count,
            "minimum" => summary.minimum,
            "mean" => summary.mean,
            "maximum" => summary.maximum,
            "standard_deviation" => summary.standard_deviation,
        ) for (stage, summary) in
        sort!(collect(aggregate.stage_timing); by = item -> string(first(item)))
    )
    allocation_data = Dict(
        string(stage) => Dict(
            "sample_count" => summary.sample_count,
            "minimum" => summary.minimum,
            "mean" => summary.mean,
            "maximum" => summary.maximum,
            "standard_deviation" => summary.standard_deviation,
        ) for (stage, summary) in
        sort!(collect(aggregate.stage_allocations); by = item -> string(first(item)))
    )
    return Dict{String,Any}(
        "case" => _profile_case_data(aggregate.case),
        "warmup_performed" => aggregate.warmup_performed,
        "runs" => [profile_result_data(run) for run in aggregate.runs],
        "stage_timing" => timing_data,
        "stage_allocations" => allocation_data,
        "finding_stability" => [
            Dict(
                "stage" => string(item.stage), "code" => string(item.code),
                "occurrence_count" => item.occurrence_count,
                "run_count" => item.run_count, "fraction" => item.fraction,
            ) for item in aggregate.finding_stability
        ],
        "expected_evidence" => [
            Dict(
                "code" => string(item.code),
                "occurrence_count" => item.occurrence_count,
                "run_count" => item.run_count, "fraction" => item.fraction,
            ) for item in aggregate.expected_evidence
        ],
        "numerical_summary" => [
            Dict(
                "metric" => string(item.metric), "run_count" => item.run_count,
                "available_count" => item.available_count, "minimum" => item.minimum,
                "mean" => item.mean, "maximum" => item.maximum,
                "standard_deviation" => item.standard_deviation,
            ) for item in aggregate.numerical_summary
        ],
    )
end

"""Return renderer-neutral, serializable data for a profile comparison."""
function profile_comparison_data(comparison::ProfileComparison)
    return Dict{String,Any}(
        "baseline_case" => _profile_case_data(comparison.baseline.case),
        "candidate_case" => _profile_case_data(comparison.candidate.case),
        "task_relation" => string(comparison.task_relation),
        "task" => comparison.task,
        "stage_comparisons" => [
            Dict(
                "stage" => string(item.stage),
                "baseline_seconds" => item.baseline_seconds,
                "candidate_seconds" => item.candidate_seconds,
                "seconds_ratio" => item.seconds_ratio,
                "baseline_allocations" => item.baseline_allocations,
                "candidate_allocations" => item.candidate_allocations,
                "allocations_ratio" => item.allocations_ratio,
            ) for item in comparison.stage_comparisons
        ],
        "finding_comparisons" => [
            Dict(
                "stage" => string(item.stage), "code" => string(item.code),
                "baseline_fraction" => item.baseline_fraction,
                "candidate_fraction" => item.candidate_fraction,
            ) for item in comparison.finding_comparisons
        ],
        "numerical_comparisons" => [
            Dict(
                "metric" => string(item.metric),
                "baseline_available_count" => item.baseline_available_count,
                "baseline_run_count" => item.baseline_run_count,
                "candidate_available_count" => item.candidate_available_count,
                "candidate_run_count" => item.candidate_run_count,
                "baseline_mean" => item.baseline_mean,
                "candidate_mean" => item.candidate_mean,
                "mean_difference" => item.mean_difference,
                "mean_ratio" => item.mean_ratio,
            ) for item in comparison.numerical_comparisons
        ],
    )
end

"""
    markdown_profile_aggregate(aggregate)

Render one repeated profile aggregate as concise CommonMark. It reports local
timing/allocation observations and evidence recovery without assigning a
performance score or declaring the modeled formulation valid.
"""
function markdown_profile_aggregate(aggregate::ProfileAggregate)
    io = IOBuffer()
    println(io, "# NLPDiagnostics profile: ", aggregate.case.name)
    if !isempty(aggregate.case.description)
        println(io)
        println(io, aggregate.case.description)
    end
    println(io)
    println(io, "- Retained runs: ", length(aggregate.runs))
    println(io, "- Warm-up performed: ", aggregate.warmup_performed)
    !isnothing(aggregate.case.task) && println(io, "- Declared task: ", aggregate.case.task)
    println(io)
    println(io, "## Expected evidence")
    println(io)
    println(io, "| Code | Occurrences | Fraction |")
    println(io, "| --- | ---: | ---: |")
    for item in aggregate.expected_evidence
        println(io, "| `", item.code, "` | ", item.occurrence_count, "/", item.run_count,
            " | ", item.fraction, " |")
    end
    println(io)
    println(io, "## Stage observations")
    println(io)
    println(io, "| Stage | Mean seconds | Mean allocated bytes |")
    println(io, "| --- | ---: | ---: |")
    for stage in sort!(collect(keys(aggregate.stage_timing)); by = string)
        timing = aggregate.stage_timing[stage]
        allocations = aggregate.stage_allocations[stage]
        println(io, "| `", stage, "` | ", timing.mean, " | ", allocations.mean, " |")
    end
    println(io)
    println(io, "## Numerical observations")
    println(io)
    println(io, "| Metric | Availability | Mean | Minimum | Maximum | Standard deviation |")
    println(io, "| --- | ---: | ---: | ---: | ---: | ---: |")
    for item in sort!(copy(aggregate.numerical_summary); by = entry -> string(entry.metric))
        println(
            io,
            "| `", item.metric, "` | ", item.available_count, "/", item.run_count,
            " | ", something(item.mean, "unavailable"),
            " | ", something(item.minimum, "unavailable"),
            " | ", something(item.maximum, "unavailable"),
            " | ", something(item.standard_deviation, "unavailable"), " |",
        )
    end
    println(io)
    println(io, "## Finding stability")
    println(io)
    println(io, "| Stage | Code | Fraction |")
    println(io, "| --- | --- | ---: |")
    for item in aggregate.finding_stability
        println(io, "| `", item.stage, "` | `", item.code, "` | ", item.fraction, " |")
    end
    return String(take!(io))
end

"""
    markdown_profile_comparison(comparison)

Render a descriptive profile comparison as CommonMark. Ratios remain local
observations and unavailable numerical metrics remain explicit rather than
being replaced with zeroes or a formulation score.
"""
function markdown_profile_comparison(comparison::ProfileComparison)
    io = IOBuffer()
    println(io, "# NLPDiagnostics profile comparison")
    println(io)
    println(io, "- Baseline: `", comparison.baseline.case.name, "`")
    println(io, "- Candidate: `", comparison.candidate.case.name, "`")
    println(io, "- Task relation: `", comparison.task_relation, "`")
    !isnothing(comparison.task) && println(io, "- Declared task: ", comparison.task)
    println(io)
    println(io, "## Stage observations")
    println(io)
    println(io, "| Stage | Baseline seconds | Candidate seconds | Ratio | Baseline bytes | Candidate bytes | Ratio |")
    println(io, "| --- | ---: | ---: | ---: | ---: | ---: | ---: |")
    for item in comparison.stage_comparisons
        println(io, "| `", item.stage, "` | ", item.baseline_seconds, " | ",
            item.candidate_seconds, " | ", something(item.seconds_ratio, "unavailable"),
            " | ", item.baseline_allocations, " | ", item.candidate_allocations,
            " | ", something(item.allocations_ratio, "unavailable"), " |")
    end
    println(io)
    println(io, "## Finding occurrence comparison")
    println(io)
    println(io, "| Stage | Code | Baseline fraction | Candidate fraction |")
    println(io, "| --- | --- | ---: | ---: |")
    for item in comparison.finding_comparisons
        println(io, "| `", item.stage, "` | `", item.code, "` | ",
            item.baseline_fraction, " | ", item.candidate_fraction, " |")
    end
    println(io)
    println(io, "## Numerical metric comparison")
    println(io)
    println(io, "| Metric | Baseline availability | Candidate availability | Baseline mean | Candidate mean | Difference | Ratio |")
    println(io, "| --- | ---: | ---: | ---: | ---: | ---: | ---: |")
    for item in comparison.numerical_comparisons
        println(io, "| `", item.metric, "` | ", item.baseline_available_count, "/",
            item.baseline_run_count, " | ", item.candidate_available_count, "/",
            item.candidate_run_count, " | ", something(item.baseline_mean, "unavailable"),
            " | ", something(item.candidate_mean, "unavailable"), " | ",
            something(item.mean_difference, "unavailable"), " | ",
            something(item.mean_ratio, "unavailable"), " |")
    end
    return String(take!(io))
end

function _count_symbols(values)
    counts = Dict{Symbol,Int}()
    for value in values
        counts[value] = get(counts, value, 0) + 1
    end
    return counts
end

function _append_profile_probe!(numerical_report::DiagnosticReport, probe_report::DiagnosticReport)
    append!(numerical_report.findings, probe_report.findings)
    for (key, value) in probe_report.metadata
        key in (:stage, :evaluation_point_label) && continue
        numerical_report.metadata[key] = value
    end
    sort!(
        numerical_report.findings;
        by = finding -> (-Int(finding.severity), string(finding.code)),
    )
    return numerical_report
end

"""
    profile_case(model, case; cache = EvaluationCache(), ...)

Run the generic static, expression, stable-reformulation, numerical, active-set,
and structural-numerical degeneracy stages for one labeled `ProfileCase`. No
solver is invoked and no model data is modified. The result retains timing and
derivative-provenance counts alongside the full reports so formulation cases can
be compared reproducibly. The iterative sparse probes and independent
smallest-direction backend crosscheck are disabled by default; set their
dimension keywords to record explicit additional probe stages.
expected_mode_free_coordinate_policy is passed to the degeneracy stage and
defaults to the conservative :strict policy.
expected_mode_tangent_policy optionally retains plugin-declared fixed/reference
coordinates for a local expected-mode comparison without modifying the model.
"""
function profile_case(
    model::MOI.ModelLike,
    case::ProfileCase{T};
    cache::EvaluationCache = EvaluationCache(),
    relative_step::Real = cbrt(eps(T)),
    scale_ratio_threshold::Real = 1.0e6,
    component_scale_mismatch_factor::Real = 1.0e3,
    unit_circle_radius_tolerance::Real = 1.0e-6,
    rank_relative_tolerance::Real =
        max(length(case.point.variables), 1) * eps(T),
    rank_max_dense_entries::Integer = 4_000_000,
    sparse_qr_rank_max_input_nonzeros::Integer = 1_000_000,
    sparse_qr_rank_max_factor_nonzeros::Integer = 4_000_000,
    check_jacobian_directional_crosscheck::Bool = false,
    jacobian_directional_crosscheck_direction_count::Integer = 3,
    jacobian_directional_crosscheck_relative_step::Real = cbrt(eps(T)),
    jacobian_directional_crosscheck_absolute_tolerance::Real = 0.0,
    jacobian_directional_crosscheck_relative_tolerance::Real = sqrt(eps(T)),
    jacobian_directional_crosscheck_row_methods::Union{Nothing,AbstractVector{Symbol}} = nothing,
    jacobian_directional_crosscheck_direction_policy::Symbol = :coordinate_then_dense,
    check_objective_gradient_directional_crosscheck::Bool = false,
    objective_gradient_directional_crosscheck_direction_count::Integer = 3,
    objective_gradient_directional_crosscheck_relative_step::Real = cbrt(eps(T)),
    objective_gradient_directional_crosscheck_absolute_tolerance::Real = 0.0,
    objective_gradient_directional_crosscheck_relative_tolerance::Real = sqrt(eps(T)),
    check_hessian_vector_crosscheck::Bool = false,
    hessian_vector_crosscheck_direction_count::Integer = 3,
    hessian_vector_crosscheck_relative_step::Real = cbrt(eps(T)),
    hessian_vector_crosscheck_absolute_tolerance::Real = 0.0,
    hessian_vector_crosscheck_relative_tolerance::Real = sqrt(eps(T)),
    hessian_vector_crosscheck_objective_weight::Real = 1.0,
    hessian_vector_crosscheck_constraint_multipliers::Union{Nothing,AbstractVector{<:Real}} = nothing,
    hessian_vector_crosscheck_max_finite_difference_variables::Integer = 100,
    jacobian_condition_threshold::Real = 1.0e10,
    feasibility_tolerance::Real = sqrt(eps(T)),
    active_tolerance::Real = sqrt(eps(T)),
    strict_domain_proximity_threshold::Union{Nothing,Real} = nothing,
    iterative_right_nullspace_probe_dimension::Union{Nothing,Integer} = nothing,
    iterative_right_nullspace_probe_iterations::Integer = 100,
    iterative_right_nullspace_probe_convergence_tolerance::Real = sqrt(eps(T)),
    iterative_right_nullspace_probe_residual_relative_tolerance::Real = sqrt(eps(T)),
    iterative_right_nullspace_probe_support_relative::Real = 0.1,
    iterative_left_nullspace_probe_dimension::Union{Nothing,Integer} = nothing,
    iterative_left_nullspace_probe_iterations::Integer = 100,
    iterative_left_nullspace_probe_convergence_tolerance::Real = sqrt(eps(T)),
    iterative_left_nullspace_probe_residual_relative_tolerance::Real = sqrt(eps(T)),
    iterative_left_nullspace_probe_support_relative::Real = 0.1,
    iterative_spectrum_probe_dimension::Union{Nothing,Integer} = nothing,
    iterative_spectrum_probe_iterations::Integer = 100,
    iterative_spectrum_probe_convergence_tolerance::Real = sqrt(eps(T)),
    iterative_spectrum_probe_spread_threshold::Real = 1.0e6,
    smallest_singular_backend_crosscheck_dimension::Union{Nothing,Integer} = nothing,
    smallest_singular_backend_crosscheck_restarted_iterations::Integer = 50,
    smallest_singular_backend_crosscheck_restarted_alignment_threshold::Real = 0.999,
    smallest_singular_backend_crosscheck_harmonic_steps_per_seed::Integer = 6,
    smallest_singular_backend_crosscheck_harmonic_cycles::Integer = 8,
    smallest_singular_backend_crosscheck_harmonic_alignment_threshold::Real = 0.999,
    smallest_singular_backend_crosscheck_harmonic_retained_dimension::Union{Nothing,Integer} = nothing,
    smallest_singular_backend_crosscheck_value_tolerance::Real = 1.0e-4,
    smallest_singular_backend_crosscheck_near_zero_tolerance::Real = sqrt(eps(T)),
    smallest_singular_backend_crosscheck_alignment_threshold::Real = 0.98,
    smallest_singular_backend_crosscheck_max_basis_entries::Integer = 1_000_000,
    smallest_singular_backend_crosscheck_scaling::Symbol = :none,
    smallest_singular_backend_crosscheck_dense_calibration::Bool = false,
    smallest_singular_backend_crosscheck_dense_max_entries::Integer =
        rank_max_dense_entries,
    check_sparse_qr_nullspace::Bool = false,
    sparse_qr_nullspace_scaling::Symbol = :none,
    sparse_qr_nullspace_relative_tolerance::Real = rank_relative_tolerance,
    sparse_qr_nullspace_absolute_tolerance::Real = 0.0,
    sparse_qr_nullspace_residual_relative_tolerance::Real = sqrt(eps(T)),
    sparse_qr_nullspace_fill_ratio_warning_threshold::Real = 20,
    sparse_qr_nullspace_max_input_nonzeros::Integer = 1_000_000,
    sparse_qr_nullspace_max_factor_nonzeros::Integer = 4_000_000,
    sparse_qr_nullspace_max_nullspace_entries::Integer = 1_000_000,
    sparse_qr_nullspace_dense_calibration::Bool = false,
    sparse_qr_nullspace_dense_max_entries::Integer = rank_max_dense_entries,
    jacobian_rank_tolerance_sweep_tolerances::Union{Nothing,AbstractVector{<:Real}} = nothing,
    jacobian_rank_tolerance_sweep_scaling::Symbol = :none,
    jacobian_rank_tolerance_sweep_max_dense_entries::Integer = 4_000_000,
    expected_mode_free_coordinate_policy::Symbol = :strict,
    expected_mode_tangent_policy::Union{Nothing,ExpectedNullspaceTangentPolicy} = nothing,
) where {T<:AbstractFloat}
    hits_before = cache.hits
    misses_before = cache.misses
    timings = Dict{Symbol,Float64}()
    allocations = Dict{Symbol,Int}()

    structural_snapshot = _profile_stage!(timings, allocations, :snapshot, () -> snapshot(model))
    structural_graph = _profile_stage!(timings, allocations, :structural_graph, () -> incidence_graph(structural_snapshot))

    structural_matching = _profile_stage!(timings, allocations, :structural_matching, () -> maximum_matching(structural_graph))

    _profile_stage!(timings, allocations, :structural_dm, () -> dulmage_mendelsohn(structural_graph; matching = structural_matching))

    static_report = _profile_stage!(timings, allocations, :static, () ->
        analyze_static(
            structural_snapshot;
            graph = structural_graph,
            unit_circle_radius_tolerance = unit_circle_radius_tolerance,
        ),
    )

    expression_report = _profile_stage!(timings, allocations, :expressions, () ->
        analyze_expressions(
            model;
            numeric_type = T,
            strict_domain_proximity_threshold = strict_domain_proximity_threshold,
        ),
    )

    reformulation_report = _profile_stage!(timings, allocations, :reformulation, () ->
        analyze_stable_reformulation_plan(
            stable_reformulation_plan(model; numeric_type = T),
        ),
    )

    evaluation = _profile_stage!(timings, allocations, :evaluation, () -> evaluate_numerical(
        model,
        case.point;
        cache = cache,
        relative_step = relative_step,
    ))

    numerical_report = _profile_stage!(timings, allocations, :numerical, () -> analyze_numerical(
        model,
        case.point;
        cache = cache,
        relative_step = relative_step,
        scale_ratio_threshold = scale_ratio_threshold,
        component_scale_mismatch_factor = component_scale_mismatch_factor,
        strict_domain_proximity_threshold = strict_domain_proximity_threshold,
        jacobian_condition_threshold = jacobian_condition_threshold,
        rank_relative_tolerance = rank_relative_tolerance,
        rank_max_dense_entries = rank_max_dense_entries,
        sparse_qr_rank_max_input_nonzeros =
            sparse_qr_rank_max_input_nonzeros,
        sparse_qr_rank_max_factor_nonzeros =
            sparse_qr_rank_max_factor_nonzeros,
    ))

    if !isnothing(iterative_right_nullspace_probe_dimension)
        probe_report = _profile_stage!(
            timings,
            allocations,
            :iterative_right_nullspace_probe,
            () -> analyze_iterative_right_nullspace_probe(
                evaluation;
                probe_dimension = iterative_right_nullspace_probe_dimension,
                iterations = iterative_right_nullspace_probe_iterations,
                convergence_tolerance = iterative_right_nullspace_probe_convergence_tolerance,
                residual_relative_tolerance = iterative_right_nullspace_probe_residual_relative_tolerance,
                support_relative = iterative_right_nullspace_probe_support_relative,
            ),
        )
        _append_profile_probe!(numerical_report, probe_report)
    end

    if !isnothing(iterative_left_nullspace_probe_dimension)
        probe_report = _profile_stage!(
            timings,
            allocations,
            :iterative_left_nullspace_probe,
            () -> analyze_iterative_left_nullspace_probe(
                evaluation;
                probe_dimension = iterative_left_nullspace_probe_dimension,
                iterations = iterative_left_nullspace_probe_iterations,
                convergence_tolerance = iterative_left_nullspace_probe_convergence_tolerance,
                residual_relative_tolerance = iterative_left_nullspace_probe_residual_relative_tolerance,
                support_relative = iterative_left_nullspace_probe_support_relative,
            ),
        )
        _append_profile_probe!(numerical_report, probe_report)
    end

    if !isnothing(iterative_spectrum_probe_dimension)
        probe_report = _profile_stage!(
            timings,
            allocations,
            :iterative_jacobian_spectrum_probe,
            () -> analyze_iterative_jacobian_spectrum_probe(
                evaluation;
                probe_dimension = iterative_spectrum_probe_dimension,
                iterations = iterative_spectrum_probe_iterations,
                convergence_tolerance = iterative_spectrum_probe_convergence_tolerance,
                spectral_spread_threshold = iterative_spectrum_probe_spread_threshold,
            ),
        )
        _append_profile_probe!(numerical_report, probe_report)
    end

    if !isnothing(smallest_singular_backend_crosscheck_dimension)
        scaling_intervention = _profile_stage!(
            timings,
            allocations,
            :smallest_singular_backend_crosscheck_scaling_intervention,
            () -> _diagonally_scaled_jacobian_evaluation(
                evaluation,
                smallest_singular_backend_crosscheck_scaling,
            ),
        )
        crosscheck_evaluation = scaling_intervention.evaluation
        retained_dimension = isnothing(
            smallest_singular_backend_crosscheck_harmonic_retained_dimension,
        ) ? max(Int(smallest_singular_backend_crosscheck_dimension) + 1, 2) :
            smallest_singular_backend_crosscheck_harmonic_retained_dimension
        crosscheck_report = _profile_stage!(
            timings,
            allocations,
            :smallest_singular_backend_crosscheck,
            () -> analyze_smallest_singular_backend_crosscheck(
                crosscheck_evaluation;
                original_evaluation_for_scaled_audit = evaluation,
                column_scaling_for_original_audit =
                    scaling_intervention.column_scaling,
                dimension = smallest_singular_backend_crosscheck_dimension,
                restarted_iterations =
                    smallest_singular_backend_crosscheck_restarted_iterations,
                restarted_alignment_threshold =
                    smallest_singular_backend_crosscheck_restarted_alignment_threshold,
                harmonic_steps_per_seed =
                    smallest_singular_backend_crosscheck_harmonic_steps_per_seed,
                harmonic_cycles =
                    smallest_singular_backend_crosscheck_harmonic_cycles,
                harmonic_alignment_threshold =
                    smallest_singular_backend_crosscheck_harmonic_alignment_threshold,
                harmonic_retained_dimension = retained_dimension,
                singular_value_relative_tolerance =
                    smallest_singular_backend_crosscheck_value_tolerance,
                near_zero_relative_tolerance =
                    smallest_singular_backend_crosscheck_near_zero_tolerance,
                subspace_alignment_threshold =
                    smallest_singular_backend_crosscheck_alignment_threshold,
                max_basis_entries =
                    smallest_singular_backend_crosscheck_max_basis_entries,
            ),
        )
        _annotate_smallest_singular_scaling_intervention!(
            crosscheck_report,
            scaling_intervention;
            emit_finding = true,
        )
        _append_profile_probe!(numerical_report, crosscheck_report)

        if smallest_singular_backend_crosscheck_dense_calibration
            restarted_dense_report = _profile_stage!(
                timings,
                allocations,
                :restarted_smallest_singular_dense_calibration,
                () -> analyze_restarted_smallest_singular_dense_calibration(
                    crosscheck_evaluation;
                    dimension = smallest_singular_backend_crosscheck_dimension,
                    iterations =
                        smallest_singular_backend_crosscheck_restarted_iterations,
                    subspace_alignment_threshold =
                        smallest_singular_backend_crosscheck_alignment_threshold,
                    candidate_subspace_alignment_threshold =
                        smallest_singular_backend_crosscheck_restarted_alignment_threshold,
                    dense_max_entries =
                        smallest_singular_backend_crosscheck_dense_max_entries,
                    singular_value_relative_tolerance =
                        smallest_singular_backend_crosscheck_value_tolerance,
                    max_basis_entries =
                        smallest_singular_backend_crosscheck_max_basis_entries,
                ),
            )
            _annotate_smallest_singular_scaling_intervention!(
                restarted_dense_report,
                scaling_intervention,
            )
            _append_profile_probe!(numerical_report, restarted_dense_report)
            harmonic_dense_report = _profile_stage!(
                timings,
                allocations,
                :harmonic_golub_kahan_dense_calibration,
                () -> analyze_harmonic_golub_kahan_dense_calibration(
                    crosscheck_evaluation;
                    dimension = smallest_singular_backend_crosscheck_dimension,
                    steps_per_seed =
                        smallest_singular_backend_crosscheck_harmonic_steps_per_seed,
                    cycles = smallest_singular_backend_crosscheck_harmonic_cycles,
                    retained_dimension = retained_dimension,
                    subspace_alignment_threshold =
                        smallest_singular_backend_crosscheck_alignment_threshold,
                    candidate_subspace_alignment_threshold =
                        smallest_singular_backend_crosscheck_harmonic_alignment_threshold,
                    dense_max_entries =
                        smallest_singular_backend_crosscheck_dense_max_entries,
                    singular_value_relative_tolerance =
                        smallest_singular_backend_crosscheck_value_tolerance,
                    max_basis_entries =
                        smallest_singular_backend_crosscheck_max_basis_entries,
                ),
            )
            _annotate_smallest_singular_scaling_intervention!(
                harmonic_dense_report,
                scaling_intervention,
            )
            _append_profile_probe!(numerical_report, harmonic_dense_report)
        end
    elseif smallest_singular_backend_crosscheck_dense_calibration
        throw(ArgumentError(
            "smallest-singular dense calibration requires a crosscheck dimension",
        ))
    end

    if check_sparse_qr_nullspace
        sparse_qr_report = _profile_stage!(
            timings,
            allocations,
            :sparse_qr_nullspace,
            () -> analyze_sparse_qr_nullspace(
                evaluation;
                relative_tolerance = sparse_qr_nullspace_relative_tolerance,
                absolute_tolerance = sparse_qr_nullspace_absolute_tolerance,
                scaling = sparse_qr_nullspace_scaling,
                residual_relative_tolerance =
                    sparse_qr_nullspace_residual_relative_tolerance,
                fill_ratio_warning_threshold =
                    sparse_qr_nullspace_fill_ratio_warning_threshold,
                max_input_nonzeros = sparse_qr_nullspace_max_input_nonzeros,
                max_factor_nonzeros = sparse_qr_nullspace_max_factor_nonzeros,
                max_nullspace_entries =
                    sparse_qr_nullspace_max_nullspace_entries,
            ),
        )
        _append_profile_probe!(numerical_report, sparse_qr_report)
        if sparse_qr_nullspace_dense_calibration
            sparse_qr_dense_report = _profile_stage!(
                timings,
                allocations,
                :sparse_qr_nullspace_dense_calibration,
                () -> analyze_sparse_qr_nullspace_dense_calibration(
                    evaluation;
                    relative_tolerance =
                        sparse_qr_nullspace_relative_tolerance,
                    absolute_tolerance =
                        sparse_qr_nullspace_absolute_tolerance,
                    scaling = sparse_qr_nullspace_scaling,
                    max_input_nonzeros =
                        sparse_qr_nullspace_max_input_nonzeros,
                    max_factor_nonzeros =
                        sparse_qr_nullspace_max_factor_nonzeros,
                    max_nullspace_entries =
                        sparse_qr_nullspace_max_nullspace_entries,
                    dense_max_entries =
                        sparse_qr_nullspace_dense_max_entries,
                ),
            )
            _append_profile_probe!(numerical_report, sparse_qr_dense_report)
        end
    elseif sparse_qr_nullspace_dense_calibration
        throw(ArgumentError(
            "sparse-QR nullspace dense calibration requires check_sparse_qr_nullspace = true",
        ))
    end

    if !isnothing(jacobian_rank_tolerance_sweep_tolerances)
        sweep_report = _profile_stage!(
            timings,
            allocations,
            :jacobian_rank_tolerance_sweep,
            () -> analyze_jacobian_rank_tolerance_sweep(
                evaluation;
                relative_tolerances = jacobian_rank_tolerance_sweep_tolerances,
                scaling = jacobian_rank_tolerance_sweep_scaling,
                max_dense_entries = jacobian_rank_tolerance_sweep_max_dense_entries,
            ),
        )
        _append_profile_probe!(numerical_report, sweep_report)
    end

    if check_jacobian_directional_crosscheck
        directional_rows = isnothing(
            jacobian_directional_crosscheck_row_methods,
        ) ? nothing : findall(
            method -> method in jacobian_directional_crosscheck_row_methods,
            evaluation.jacobian_row_methods,
        )
        crosscheck_report = _profile_stage!(
            timings,
            allocations,
            :jacobian_directional_crosscheck,
            () -> analyze_jacobian_directional_crosscheck(
                model,
                evaluation;
                direction_count = jacobian_directional_crosscheck_direction_count,
                relative_step = jacobian_directional_crosscheck_relative_step,
                absolute_tolerance = jacobian_directional_crosscheck_absolute_tolerance,
                relative_tolerance = jacobian_directional_crosscheck_relative_tolerance,
                row_indices = directional_rows,
                direction_policy =
                    jacobian_directional_crosscheck_direction_policy,
                cache = cache,
            ),
        )
        _append_profile_probe!(numerical_report, crosscheck_report)
    end
    if check_objective_gradient_directional_crosscheck
        objective_crosscheck_report = _profile_stage!(
            timings,
            allocations,
            :objective_gradient_directional_crosscheck,
            () -> analyze_objective_gradient_directional_crosscheck(
                model,
                evaluation;
                direction_count = objective_gradient_directional_crosscheck_direction_count,
                relative_step = objective_gradient_directional_crosscheck_relative_step,
                absolute_tolerance = objective_gradient_directional_crosscheck_absolute_tolerance,
                relative_tolerance = objective_gradient_directional_crosscheck_relative_tolerance,
                cache = cache,
            ),
        )
        _append_profile_probe!(numerical_report, objective_crosscheck_report)
    end
    if check_hessian_vector_crosscheck
        multipliers = isnothing(hessian_vector_crosscheck_constraint_multipliers) ?
            zeros(T, length(evaluation.constraint_sources)) :
            hessian_vector_crosscheck_constraint_multipliers
        hessian_report = _profile_stage!(
            timings,
            allocations,
            :hessian_evaluation,
            () -> evaluate_lagrangian_hessian(
                model,
                case.point;
                objective_weight = hessian_vector_crosscheck_objective_weight,
                constraint_multipliers = multipliers,
                max_finite_difference_variables = hessian_vector_crosscheck_max_finite_difference_variables,
            ),
        )
        hessian_crosscheck_report = _profile_stage!(
            timings,
            allocations,
            :hessian_vector_crosscheck,
            () -> analyze_hessian_vector_crosscheck(
                model,
                hessian_report;
                direction_count = hessian_vector_crosscheck_direction_count,
                relative_step = hessian_vector_crosscheck_relative_step,
                absolute_tolerance = hessian_vector_crosscheck_absolute_tolerance,
                relative_tolerance = hessian_vector_crosscheck_relative_tolerance,
                cache = cache,
            ),
        )
        _append_profile_probe!(numerical_report, hessian_crosscheck_report)
    end

    active_set_report = _profile_stage!(timings, allocations, :active_set, () -> analyze_active_set(
        model,
        evaluation;
        feasibility_tolerance = feasibility_tolerance,
        active_tolerance = active_tolerance,
        rank_relative_tolerance = rank_relative_tolerance,
        rank_max_dense_entries = rank_max_dense_entries,
    ))

    degeneracy_report = _profile_stage!(timings, allocations, :degeneracy, () -> analyze_degeneracy(
        model,
        evaluation;
        relative_tolerance = rank_relative_tolerance,
        max_dense_entries = rank_max_dense_entries,
        expected_mode_free_coordinate_policy =
            expected_mode_free_coordinate_policy,
        expected_mode_tangent_policy = expected_mode_tangent_policy,
    ))

    _apply_point_provenance_guard!(numerical_report, case.point)
    _apply_point_provenance_guard!(active_set_report, case.point)
    _apply_point_provenance_guard!(degeneracy_report, case.point)

    return ProfileResult{T}(
        case,
        evaluation,
        static_report,
        expression_report,
        reformulation_report,
        numerical_report,
        active_set_report,
        degeneracy_report,
        timings,
        allocations,
        evaluation_call_statistics(evaluation),
        _count_symbols(evaluation.jacobian_row_methods),
        _count_symbols(capability.source for capability in evaluation.capabilities),
        cache.hits - hits_before,
        cache.misses - misses_before,
    )
end

function _profile_timing_summary(samples::Vector{Float64})
    isempty(samples) && throw(ArgumentError("timing samples must not be empty"))
    average = sum(samples) / length(samples)
    variance = sum((sample - average)^2 for sample in samples) / length(samples)
    return ProfileTimingSummary(
        length(samples),
        minimum(samples),
        average,
        maximum(samples),
        sqrt(variance),
    )
end

function _profile_allocation_summary(samples::Vector{Int})
    isempty(samples) && throw(ArgumentError("allocation samples must not be empty"))
    values = Float64.(samples)
    average = sum(values) / length(values)
    variance = sum((value - average)^2 for value in values) / length(values)
    return ProfileAllocationSummary(
        length(samples),
        minimum(samples),
        average,
        maximum(samples),
        sqrt(variance),
    )
end

function _profile_finding_stability(runs::Vector{<:ProfileResult})
    counts = Dict{Tuple{Symbol,Symbol},Int}()
    for run in runs
        for (stage, report) in (
            :static => run.static_report,
            :expressions => run.expression_report,
            :reformulation => run.reformulation_report,
            :numerical => run.numerical_report,
            :active_set => run.active_set_report,
            :degeneracy => run.degeneracy_report,
        )
            for code in unique(finding.code for finding in report.findings)
                key = (stage, code)
                counts[key] = get(counts, key, 0) + 1
            end
        end
    end
    run_count = length(runs)
    return sort!(
        ProfileFindingStability[
            ProfileFindingStability(
                stage,
                code,
                count,
                run_count,
                count / run_count,
            ) for ((stage, code), count) in counts
        ];
        by = item -> (string(item.stage), string(item.code)),
    )
end

function _profile_expected_evidence_summary(runs::Vector{<:ProfileResult})
    isempty(runs) && throw(ArgumentError("profile runs must not be empty"))
    expected = runs[1].case.expected_evidence
    all(run.case.expected_evidence == expected for run in runs) ||
        throw(ArgumentError("profile runs must share expected evidence"))
    summaries = ProfileExpectedEvidenceSummary[]
    for code in sort!(collect(expected); by = string)
        occurrence_count = count(runs) do run
            any(code in (finding.code for finding in report.findings) for report in (
                run.static_report,
                run.expression_report,
                run.reformulation_report,
                run.numerical_report,
                run.active_set_report,
                run.degeneracy_report,
            ))
        end
        push!(summaries, ProfileExpectedEvidenceSummary(
            code,
            occurrence_count,
            length(runs),
            occurrence_count / length(runs),
        ))
    end
    return summaries
end

function _profile_numerical_summary(runs::Vector{<:ProfileResult})
    metrics = Pair{Symbol,Union{Nothing,Symbol}}[
        :jacobian_rank => :jacobian_rank_available,
        :sparse_qr_rank => :sparse_qr_rank_available,
        :sparse_qr_condition_proxy => nothing,
    ]
    # These scalar summaries are added only when at least one retained run
    # explicitly requested the corresponding sparse probe. Their availability
    # flags keep unavailable probe paths out of numerical averages.
    for metric in (
        :iterative_probe_small_residual_direction_count => :iterative_probe_available,
        :iterative_left_probe_small_residual_direction_count => :iterative_left_probe_available,
        :iterative_spectrum_probe_large_spread_count => :iterative_spectrum_probe_available,
        :iterative_spectrum_probe_largest_singular_value_proxy => :iterative_spectrum_probe_available,
        :minimum_rank => nothing,
        :maximum_rank => nothing,
        :rank_span => nothing,
    )
        any(haskey(run.numerical_report.metadata, first(metric)) for run in runs) &&
            push!(metrics, metric)
    end
    summaries = ProfileNumericalSummary[]
    for (metric, availability_key) in metrics
        values = Float64[]
        for run in runs
            metadata = run.numerical_report.metadata
            haskey(metadata, metric) || continue
            if !isnothing(availability_key) &&
               get(metadata, availability_key, "false") != "true"
                continue
            end
            value = tryparse(Float64, metadata[metric])
            isnothing(value) || !isfinite(value) || push!(values, value)
        end
        if isempty(values)
            push!(summaries, ProfileNumericalSummary(
                metric, length(runs), 0, nothing, nothing, nothing, nothing,
            ))
            continue
        end
        mean_value = sum(values) / length(values)
        deviation = sqrt(sum((value - mean_value)^2 for value in values) / length(values))
        push!(summaries, ProfileNumericalSummary(
            metric,
            length(runs),
            length(values),
            minimum(values),
            mean_value,
            maximum(values),
            deviation,
        ))
    end
    return summaries
end

"""
    profile_case_repeated(model, case; repetitions = 3, warmup = true, ...)

Run independent profiling measurements with fresh evaluation caches and return
per-stage observed timing summaries. A discarded warm-up run is enabled by
default to reduce compilation effects in the retained measurements.
"""
function profile_case_repeated(
    model::MOI.ModelLike,
    case::ProfileCase{T};
    repetitions::Integer = 3,
    warmup::Bool = true,
    kwargs...,
) where {T<:AbstractFloat}
    repetitions > 0 || throw(ArgumentError("repetitions must be positive"))
    warmup && profile_case(model, case; cache = EvaluationCache(), kwargs...)
    runs = ProfileResult{T}[
        profile_case(model, case; cache = EvaluationCache(), kwargs...) for
        _ in 1:repetitions
    ]
    stages = sort!(unique!(reduce(vcat, [collect(keys(run.stage_seconds)) for run in runs])))
    timing = Dict{Symbol,ProfileTimingSummary}()
    allocations = Dict{Symbol,ProfileAllocationSummary}()
    for stage in stages
        timing[stage] = _profile_timing_summary(
            Float64[run.stage_seconds[stage] for run in runs],
        )
        allocations[stage] = _profile_allocation_summary(
            Int[run.stage_allocations[stage] for run in runs],
        )
    end
    return ProfileAggregate{T}(
        case,
        runs,
        warmup,
        timing,
        allocations,
        _profile_finding_stability(runs),
        _profile_expected_evidence_summary(runs),
        _profile_numerical_summary(runs),
    )
end

"""Run a deterministic labeled profiling corpus and retain one aggregate per case."""
function profile_cases_repeated(
    models::AbstractVector{<:MOI.ModelLike},
    cases::AbstractVector{<:ProfileCase};
    kwargs...,
)
    length(models) == length(cases) ||
        throw(ArgumentError("models and cases must have the same length"))
    names = [case.name for case in cases]
    length(unique(names)) == length(names) ||
        throw(ArgumentError("profile case names must be unique"))
    return Dict(
        case.name => profile_case_repeated(model, case; kwargs...) for
        (model, case) in zip(models, cases)
    )
end

function _profile_ratio(candidate::Real, baseline::Real)
    iszero(baseline) && return nothing
    return Float64(candidate / baseline)
end

function _profile_task_relation(
    baseline::ProfileCase,
    candidate::ProfileCase,
)
    if !isnothing(baseline.task) && !isnothing(candidate.task)
        return baseline.task == candidate.task ?
               (:declared_same_task, baseline.task) :
               (:declared_different_task, nothing)
    end
    return :undeclared_task_relation, nothing
end

"""
    compare_profiles(baseline, candidate)

Compare two repeated profile aggregates without collapsing timing, allocations,
and diagnostic evidence into a score. Ratios are descriptive local
observations: positive values above one mean the candidate's retained mean is
larger than the baseline's for that stage. `task_relation` states whether both
cases declared the same task, different tasks, or no comparable task context.
"""
function compare_profiles(
    baseline::ProfileAggregate{T},
    candidate::ProfileAggregate{T},
) where {T<:AbstractFloat}
    task_relation, task = _profile_task_relation(baseline.case, candidate.case)
    common_stages = sort!(collect(intersect(
        keys(baseline.stage_timing),
        keys(candidate.stage_timing),
    )); by = string)
    stages = ProfileStageComparison[]
    for stage in common_stages
        baseline_time = baseline.stage_timing[stage].mean
        candidate_time = candidate.stage_timing[stage].mean
        baseline_allocation = baseline.stage_allocations[stage].mean
        candidate_allocation = candidate.stage_allocations[stage].mean
        push!(stages, ProfileStageComparison(
            stage,
            baseline_time,
            candidate_time,
            _profile_ratio(candidate_time, baseline_time),
            baseline_allocation,
            candidate_allocation,
            _profile_ratio(candidate_allocation, baseline_allocation),
        ))
    end

    baseline_findings = Dict(
        (item.stage, item.code) => item.fraction for item in baseline.finding_stability
    )
    candidate_findings = Dict(
        (item.stage, item.code) => item.fraction for item in candidate.finding_stability
    )
    keys_to_compare = sort!(collect(union(
        keys(baseline_findings), keys(candidate_findings),
    )); by = key -> (string(key[1]), string(key[2])))
    findings = ProfileFindingComparison[
        ProfileFindingComparison(
            stage,
            code,
            get(baseline_findings, (stage, code), 0.0),
            get(candidate_findings, (stage, code), 0.0),
        ) for (stage, code) in keys_to_compare
    ]
    baseline_metrics = Dict(item.metric => item for item in baseline.numerical_summary)
    candidate_metrics = Dict(item.metric => item for item in candidate.numerical_summary)
    metrics = sort!(collect(union(keys(baseline_metrics), keys(candidate_metrics))); by = string)
    numerical = ProfileNumericalComparison[]
    for metric in metrics
        baseline_metric = get(baseline_metrics, metric, nothing)
        candidate_metric = get(candidate_metrics, metric, nothing)
        baseline_mean = isnothing(baseline_metric) ? nothing : baseline_metric.mean
        candidate_mean = isnothing(candidate_metric) ? nothing : candidate_metric.mean
        both_available = !isnothing(baseline_mean) && !isnothing(candidate_mean)
        push!(numerical, ProfileNumericalComparison(
            metric,
            isnothing(baseline_metric) ? 0 : baseline_metric.available_count,
            isnothing(baseline_metric) ? 0 : baseline_metric.run_count,
            isnothing(candidate_metric) ? 0 : candidate_metric.available_count,
            isnothing(candidate_metric) ? 0 : candidate_metric.run_count,
            baseline_mean,
            candidate_mean,
            both_available ? candidate_mean - baseline_mean : nothing,
            both_available ? _profile_ratio(candidate_mean, baseline_mean) : nothing,
        ))
    end
    return ProfileComparison{T}(
        baseline,
        candidate,
        task_relation,
        task,
        stages,
        findings,
        numerical,
    )
end

"""Create deterministic affine sparse-Jacobian benchmark cases for core calibration."""
function synthetic_sparse_profile_corpus(; dimension::Integer = 32)
    dimension >= 2 || throw(ArgumentError("dimension must be at least two"))
    models = MOI.Utilities.Model{Float64}[]
    cases = ProfileCase{Float64}[]
    for (name, deficient, scale) in (("sparse_banded_full_rank", false, 1.0), ("sparse_banded_rank_deficient", true, 1.0), ("sparse_banded_scaled", false, 1.0e8))
        model = MOI.Utilities.Model{Float64}()
        variables = MOI.add_variables(model, dimension)
        for row in 1:dimension
            diagonal = scale == 1.0 ? 1.0 : (isodd(row) ? scale : inv(scale))
            terms = MOI.ScalarAffineTerm{Float64}[MOI.ScalarAffineTerm(row == dimension && deficient ? 1.0 : diagonal, variables[row])]
            row > 1 && push!(terms, MOI.ScalarAffineTerm(-1.0, variables[row - 1]))
            row == dimension && deficient && (terms = MOI.ScalarAffineTerm{Float64}[MOI.ScalarAffineTerm(1.0, variables[1])])
            MOI.add_constraint(model, MOI.ScalarAffineFunction(terms, 0.0), MOI.EqualTo(0.0))
        end
        point = evaluation_point(model, zeros(Float64, dimension); label = "zero")
        push!(models, model)
        push!(cases, ProfileCase(name, point;
            description = "Deterministic sparse affine Jacobian calibration case.",
            task = "synthetic sparse banded affine system",
            formulation = "synthetic_banded_affine",
            scale = string(scale),
            expected_evidence = deficient ? [:sparse_qr_jacobian_rank_deficiency] : Symbol[],
            tags = [:synthetic, :sparse, deficient ? :rank_deficient : :full_rank],
            metadata = Dict("dimension" => dimension, "scale" => scale),
        ))
    end
    return models, cases
end

"""
    synthetic_stability_profile_corpus()

Return small, safe-point MOI models that retain deliberately fragile expression
forms. They are solver-independent profile cases for expression-analysis time,
allocation, and fingerprint recovery; their selected points avoid overflow so
numerical evaluation can proceed without hiding the static formulation risk.
"""
function synthetic_stability_profile_corpus()
    models = MOI.Utilities.Model{Float64}[]
    cases = ProfileCase{Float64}[]
    specifications = (
        (
            "stability_log1mexp_composite",
            :log_one_minus_exp_cancellation_risk,
            "log(1 - exp(x)) composition",
            -1.0,
            x -> MOI.ScalarNonlinearFunction(:log, Any[
                MOI.ScalarNonlinearFunction(:-, Any[
                    1.0, MOI.ScalarNonlinearFunction(:exp, Any[x]),
                ]),
            ]),
        ),
        (
            "stability_logcosh_composite",
            :unstable_logcosh_expression,
            "log(cosh(x)) composition",
            30.0,
            x -> MOI.ScalarNonlinearFunction(:log, Any[
                MOI.ScalarNonlinearFunction(:cosh, Any[x]),
            ]),
        ),
        (
            "stability_complementary_logistic",
            :unstable_complementary_logistic_expression,
            "1 / (1 + exp(x)) composition",
            30.0,
            x -> MOI.ScalarNonlinearFunction(:/, Any[
                1.0, MOI.ScalarNonlinearFunction(:+, Any[
                    1.0, MOI.ScalarNonlinearFunction(:exp, Any[x]),
                ]),
            ]),
        ),
    )
    for (name, expected, description, value, expression_builder) in specifications
        model = MOI.Utilities.Model{Float64}()
        variable = MOI.add_variable(model)
        MOI.add_constraint(model, variable, MOI.EqualTo(value))
        MOI.add_constraint(model, expression_builder(variable), MOI.LessThan(1.0e100))
        point = evaluation_point(model, [value]; label = "safe representative point")
        push!(models, model)
        push!(cases, ProfileCase(name, point;
            description = "Solver-independent stable-expression profiling case: $description.",
            task = "synthetic stable-expression diagnostics",
            formulation = "direct fragile composition",
            initialization = "safe representative point",
            scale = "Float64",
            expected_evidence = [expected],
            tags = [:synthetic, :stability, :expression],
            metadata = Dict("fingerprint" => expected, "representative_value" => value),
        ))
    end
    for (name, expected, description, values, expression_builder) in (
        (
            "stability_logsumexp_composite",
            :unstable_logsumexp_expression,
            "log(exp(a) + exp(b)) composition",
            [30.0, -30.0],
            (a, b) -> MOI.ScalarNonlinearFunction(:log, Any[
                MOI.ScalarNonlinearFunction(:+, Any[
                    MOI.ScalarNonlinearFunction(:exp, Any[a]),
                    MOI.ScalarNonlinearFunction(:exp, Any[b]),
                ]),
            ]),
        ),
        (
            "stability_logdiffexp_composite",
            :unstable_logdiffexp_expression,
            "log(exp(a) - exp(b)) composition",
            [30.0, 0.0],
            (a, b) -> MOI.ScalarNonlinearFunction(:log, Any[
                MOI.ScalarNonlinearFunction(:-, Any[
                    MOI.ScalarNonlinearFunction(:exp, Any[a]),
                    MOI.ScalarNonlinearFunction(:exp, Any[b]),
                ]),
            ]),
        ),
    )
        model = MOI.Utilities.Model{Float64}()
        variables = MOI.add_variables(model, 2)
        for (variable, value) in zip(variables, values)
            MOI.add_constraint(model, variable, MOI.EqualTo(value))
        end
        MOI.add_constraint(model, expression_builder(variables...), MOI.LessThan(1.0e100))
        point = evaluation_point(model, values; label = "safe representative point")
        push!(models, model)
        push!(cases, ProfileCase(name, point;
            description = "Solver-independent stable-expression profiling case: $description.",
            task = "synthetic stable-expression diagnostics",
            formulation = "direct fragile composition",
            initialization = "safe representative point",
            scale = "Float64",
            expected_evidence = [expected],
            tags = [:synthetic, :stability, :expression],
            metadata = Dict("fingerprint" => expected, "representative_values" => join(values, ",")),
        ))
    end
    return models, cases
end

"""
    profile_synthetic_stability_corpus(; kwargs...)

Run repeated solver-independent profiles for every case in
`synthetic_stability_profile_corpus`. Keyword arguments are forwarded to
`profile_cases_repeated`, including `repetitions` and `warmup`.
"""
function profile_synthetic_stability_corpus(; kwargs...)
    models, cases = synthetic_stability_profile_corpus()
    return profile_cases_repeated(models, cases; kwargs...)
end

"""
    synthetic_derivative_boundary_profile_corpus()

Return small, finite-point MOI models near ordinary primitive derivative
boundaries. These cases preserve valid function values while deliberately
creating large local first or second derivatives, so they exercise the generic
strict-domain amplification evidence without invoking a solver.
"""
function synthetic_derivative_boundary_profile_corpus()
    models = MOI.Utilities.Model{Float64}[]
    cases = ProfileCase{Float64}[]
    specifications = (
        (
            "boundary_sqrt",
            "sqrt(x) near zero",
            1.0e-12,
            x -> MOI.ScalarNonlinearFunction(:sqrt, Any[x]),
        ),
        (
            "boundary_reciprocal",
            "inv(x) near zero",
            1.0e-12,
            x -> MOI.ScalarNonlinearFunction(:inv, Any[x]),
        ),
        (
            "boundary_fractional_power",
            "x^1.5 near zero",
            1.0e-12,
            x -> MOI.ScalarNonlinearFunction(:^, Any[x, 1.5]),
        ),
        (
            "boundary_negative_power",
            "x^-1 near a negative nonzero base",
            -1.0e-12,
            x -> MOI.ScalarNonlinearFunction(:^, Any[x, -1]),
        ),
        (
            "boundary_atanh",
            "atanh(x) near one",
            1.0 - 1.0e-12,
            x -> MOI.ScalarNonlinearFunction(:atanh, Any[x]),
        ),
        (
            "boundary_asin",
            "asin(x) near one",
            1.0 - 1.0e-12,
            x -> MOI.ScalarNonlinearFunction(:asin, Any[x]),
        ),
        (
            "boundary_tan",
            "tan(x) near pi/2",
            # Do not use the rounded Float64 representation of pi/2 itself:
            # its finite cosine can obscure the pole in a floating-point
            # evaluator. This remains a finite, valid point near the pole.
            Float64(pi / 2 - 1.0e-12),
            x -> MOI.ScalarNonlinearFunction(:tan, Any[x]),
        ),
        (
            "boundary_log_one_minus_exp",
            "log(1 - exp(x)) near zero from below",
            -1.0e-12,
            x -> MOI.ScalarNonlinearFunction(:log, Any[
                MOI.ScalarNonlinearFunction(:-, Any[
                    1.0, MOI.ScalarNonlinearFunction(:exp, Any[x]),
                ]),
            ]),
        ),
    )
    for (name, description, value, expression_builder) in specifications
        model = MOI.Utilities.Model{Float64}()
        variable = MOI.add_variable(model)
        MOI.add_constraint(model, variable, MOI.EqualTo(value))
        MOI.add_constraint(model, expression_builder(variable), MOI.LessThan(1.0e100))
        point = evaluation_point(model, [value]; label = "near derivative boundary")
        push!(models, model)
        push!(cases, ProfileCase(name, point;
            description = "Solver-independent derivative-boundary profiling case: $description.",
            task = "synthetic derivative-boundary diagnostics",
            formulation = "direct primitive near a valid derivative boundary",
            initialization = "finite near-boundary point",
            scale = "Float64",
            expected_evidence = [:strict_domain_derivative_amplification],
            tags = [:synthetic, :derivatives, :initialization, :stability],
            metadata = Dict("primitive" => description, "representative_value" => value),
        ))
    end
    return models, cases
end

"""
    profile_synthetic_derivative_boundary_corpus(; kwargs...)

Run repeated solver-independent profiles for every case in
`synthetic_derivative_boundary_profile_corpus`.
"""
function profile_synthetic_derivative_boundary_corpus(; kwargs...)
    models, cases = synthetic_derivative_boundary_profile_corpus()
    return profile_cases_repeated(models, cases; kwargs...)
end

"""
    synthetic_float32_derivative_overflow_profile_corpus()

Return finite Float32 points where a primitive value remains representable but
an estimated derivative order is not. The cases calibrate numeric-type-specific
error evidence, rather than treating Float64 behavior as universal.
"""
function synthetic_float32_derivative_overflow_profile_corpus()
    models = MOI.Utilities.Model{Float32}[]
    cases = ProfileCase{Float32}[]
    for (name, description, expression_builder) in (
        (
            "float32_boundary_sqrt",
            "sqrt(x) with an unrepresentable second derivative",
            x -> MOI.ScalarNonlinearFunction(:sqrt, Any[x]),
        ),
        (
            "float32_boundary_reciprocal",
            "inv(x) with unrepresentable reciprocal derivatives",
            x -> MOI.ScalarNonlinearFunction(:inv, Any[x]),
        ),
    )
        model = MOI.Utilities.Model{Float32}()
        variable = MOI.add_variable(model)
        value = Float32(1.0e-30)
        MOI.add_constraint(model, variable, MOI.EqualTo(value))
        MOI.add_constraint(model, expression_builder(variable), MOI.LessThan(Float32(1.0e30)))
        point = evaluation_point(model, Float32[value]; label = "Float32 derivative overflow point")
        push!(models, model)
        push!(cases, ProfileCase(name, point;
            description = "Numeric-type-specific derivative-overflow profiling case: $description.",
            task = "synthetic Float32 derivative representability",
            formulation = "direct primitive at finite Float32 value",
            initialization = "finite Float32 point",
            scale = "Float32",
            expected_evidence = [:strict_domain_derivative_amplification],
            tags = [:synthetic, :derivatives, :float32, :overflow],
            metadata = Dict("primitive" => description, "representative_value" => value),
        ))
    end
    return models, cases
end

"""
    profile_synthetic_float32_derivative_overflow_corpus(; kwargs...)

Run repeated solver-independent profiles for every Float32 derivative-overflow
case in `synthetic_float32_derivative_overflow_profile_corpus`.
"""
function profile_synthetic_float32_derivative_overflow_corpus(; kwargs...)
    models, cases = synthetic_float32_derivative_overflow_profile_corpus()
    return profile_cases_repeated(models, cases; kwargs...)
end

"""
    synthetic_coupled_cone_profile_corpus()

Return small, solver-independent coupled-cone cases for feasibility, smooth
boundary geometry, Robinson-CQ, and dependent-normal evidence. The corpus does
not scalarize cone constraints or invoke a solver.
"""
function synthetic_coupled_cone_profile_corpus()
    models = MOI.Utilities.Model{Float64}[]
    cases = ProfileCase{Float64}[]

    smooth_soc = MOI.Utilities.Model{Float64}()
    t, x = MOI.add_variables(smooth_soc, 2)
    MOI.add_constraint(smooth_soc, MOI.VectorOfVariables([t, x]), MOI.SecondOrderCone(2))
    push!(models, smooth_soc)
    push!(cases, ProfileCase(
        "coupled_smooth_soc_boundary",
        evaluation_point(smooth_soc, [1.0, 1.0]; label = "smooth SOC boundary");
        description = "A smooth second-order-cone boundary with a regular mapped normal.",
        task = "synthetic coupled-cone qualification diagnostics",
        formulation = "single second-order cone",
        initialization = "smooth feasible boundary point",
        scale = "unit cone coordinates",
        expected_evidence = [:coupled_set_robinson_cq_regular],
        tags = [:synthetic, :cone, :soc, :qualification],
        metadata = Dict("cone" => "SOC", "geometry" => "smooth boundary"),
    ))

    smooth_rotated = MOI.Utilities.Model{Float64}()
    u, v, w = MOI.add_variables(smooth_rotated, 3)
    MOI.add_constraint(
        smooth_rotated, MOI.VectorOfVariables([u, v, w]), MOI.RotatedSecondOrderCone(3),
    )
    push!(models, smooth_rotated)
    push!(cases, ProfileCase(
        "coupled_smooth_rotated_soc_boundary",
        evaluation_point(
            smooth_rotated, [1.0, 1.0, sqrt(2.0)];
            label = "smooth rotated-SOC boundary",
        );
        description = "A smooth rotated second-order-cone boundary with a regular mapped normal.",
        task = "synthetic coupled-cone qualification diagnostics",
        formulation = "single rotated second-order cone",
        initialization = "smooth feasible boundary point",
        scale = "u=v=1, w=sqrt(2)",
        expected_evidence = [:coupled_set_robinson_cq_regular],
        tags = [:synthetic, :cone, :rotated_soc, :qualification],
        metadata = Dict("cone" => "RSOC", "geometry" => "smooth boundary"),
    ))

    smooth_norm_one = MOI.Utilities.Model{Float64}()
    norm_one_t, norm_one_x, norm_one_y = MOI.add_variables(smooth_norm_one, 3)
    MOI.add_constraint(
        smooth_norm_one,
        MOI.VectorOfVariables([norm_one_t, norm_one_x, norm_one_y]),
        MOI.NormOneCone(3),
    )
    push!(models, smooth_norm_one)
    push!(cases, ProfileCase(
        "coupled_smooth_norm_one_boundary",
        evaluation_point(smooth_norm_one, [2.0, 1.0, -1.0]; label = "smooth norm-one boundary");
        description = "A norm-one-cone boundary away from every absolute-value kink.",
        task = "synthetic coupled-cone qualification diagnostics",
        formulation = "single norm-one cone",
        initialization = "smooth feasible boundary point",
        scale = "t=2, x=(1,-1)",
        expected_evidence = [:coupled_set_robinson_cq_regular],
        tags = [:synthetic, :cone, :norm_one, :qualification],
        metadata = Dict("cone" => "NormOne", "geometry" => "smooth boundary"),
    ))

    smooth_norm_infinity = MOI.Utilities.Model{Float64}()
    norm_inf_t, norm_inf_x, norm_inf_y = MOI.add_variables(smooth_norm_infinity, 3)
    MOI.add_constraint(
        smooth_norm_infinity,
        MOI.VectorOfVariables([norm_inf_t, norm_inf_x, norm_inf_y]),
        MOI.NormInfinityCone(3),
    )
    push!(models, smooth_norm_infinity)
    push!(cases, ProfileCase(
        "coupled_smooth_norm_infinity_boundary",
        evaluation_point(
            smooth_norm_infinity, [2.0, -2.0, 0.25];
            label = "smooth norm-infinity boundary",
        );
        description = "A norm-infinity-cone boundary with one unique maximum component.",
        task = "synthetic coupled-cone qualification diagnostics",
        formulation = "single norm-infinity cone",
        initialization = "smooth feasible boundary point",
        scale = "t=2, unique maximum magnitude=2",
        expected_evidence = [:coupled_set_robinson_cq_regular],
        tags = [:synthetic, :cone, :norm_infinity, :qualification],
        metadata = Dict("cone" => "NormInfinity", "geometry" => "unique maximum"),
    ))

    smooth_spectral_norm = MOI.Utilities.Model{Float64}()
    spectral_variables = MOI.add_variables(smooth_spectral_norm, 5)
    MOI.add_constraint(
        smooth_spectral_norm,
        MOI.VectorOfVariables(spectral_variables),
        MOI.NormSpectralCone(2, 2),
    )
    push!(models, smooth_spectral_norm)
    push!(cases, ProfileCase(
        "coupled_smooth_spectral_norm_boundary",
        evaluation_point(
            smooth_spectral_norm, [2.0, 2.0, 0.0, 0.0, 1.0];
            label = "simple-leading-mode spectral-norm boundary",
        );
        description = "A spectral-norm cone boundary with a unique nonzero leading singular value.",
        task = "synthetic coupled-cone qualification diagnostics",
        formulation = "single 2-by-2 spectral-norm cone",
        initialization = "smooth feasible boundary point",
        scale = "singular values 2 and 1",
        expected_evidence = [:coupled_set_robinson_cq_regular],
        tags = [:synthetic, :cone, :spectral_norm, :matrix, :qualification],
        metadata = Dict("cone" => "NormSpectral", "geometry" => "simple leading singular value"),
    ))

    smooth_nuclear_norm = MOI.Utilities.Model{Float64}()
    nuclear_variables = MOI.add_variables(smooth_nuclear_norm, 5)
    MOI.add_constraint(
        smooth_nuclear_norm,
        MOI.VectorOfVariables(nuclear_variables),
        MOI.NormNuclearCone(2, 2),
    )
    push!(models, smooth_nuclear_norm)
    push!(cases, ProfileCase(
        "coupled_smooth_nuclear_norm_boundary",
        evaluation_point(
            smooth_nuclear_norm, [3.0, 2.0, 0.0, 0.0, 1.0];
            label = "full-rank nuclear-norm boundary",
        );
        description = "A nuclear-norm cone boundary at a full-rank matrix.",
        task = "synthetic coupled-cone qualification diagnostics",
        formulation = "single 2-by-2 nuclear-norm cone",
        initialization = "smooth feasible boundary point",
        scale = "singular values 2 and 1",
        expected_evidence = [:coupled_set_robinson_cq_regular],
        tags = [:synthetic, :cone, :nuclear_norm, :matrix, :qualification],
        metadata = Dict("cone" => "NormNuclear", "geometry" => "full rank"),
    ))

    tied_spectral_norm = MOI.Utilities.Model{Float64}()
    tied_spectral_variables = MOI.add_variables(tied_spectral_norm, 5)
    MOI.add_constraint(
        tied_spectral_norm,
        MOI.VectorOfVariables(tied_spectral_variables),
        MOI.NormSpectralCone(2, 2),
    )
    push!(models, tied_spectral_norm)
    push!(cases, ProfileCase(
        "coupled_spectral_norm_tied_leading_modes",
        evaluation_point(
            tied_spectral_norm, [1.0, 1.0, 0.0, 0.0, 1.0];
            label = "tied-leading-mode spectral-norm boundary",
        );
        description = "A spectral-norm boundary with two equal leading singular values.",
        task = "synthetic coupled-cone qualification diagnostics",
        formulation = "single 2-by-2 spectral-norm cone",
        initialization = "nonsmooth feasible boundary point",
        scale = "two unit singular values",
        expected_evidence = [:coupled_set_nonsmooth_boundary_active],
        tags = [:synthetic, :cone, :spectral_norm, :matrix, :nonsmooth],
        metadata = Dict("cone" => "NormSpectral", "geometry" => "tied leading singular values"),
    ))

    rank_deficient_nuclear_norm = MOI.Utilities.Model{Float64}()
    rank_deficient_nuclear_variables = MOI.add_variables(rank_deficient_nuclear_norm, 5)
    MOI.add_constraint(
        rank_deficient_nuclear_norm,
        MOI.VectorOfVariables(rank_deficient_nuclear_variables),
        MOI.NormNuclearCone(2, 2),
    )
    push!(models, rank_deficient_nuclear_norm)
    push!(cases, ProfileCase(
        "coupled_nuclear_norm_rank_deficient_boundary",
        evaluation_point(
            rank_deficient_nuclear_norm, [2.0, 2.0, 0.0, 0.0, 0.0];
            label = "rank-deficient nuclear-norm boundary",
        );
        description = "A nuclear-norm boundary whose matrix has a zero singular value.",
        task = "synthetic coupled-cone qualification diagnostics",
        formulation = "single 2-by-2 nuclear-norm cone",
        initialization = "nonsmooth feasible boundary point",
        scale = "singular values 2 and 0",
        expected_evidence = [:coupled_set_nonsmooth_boundary_active],
        tags = [:synthetic, :cone, :nuclear_norm, :matrix, :nonsmooth],
        metadata = Dict("cone" => "NormNuclear", "geometry" => "rank deficient"),
    ))

    smooth_psd_triangle = MOI.Utilities.Model{Float64}()
    psd_entries = MOI.add_variables(smooth_psd_triangle, 3)
    MOI.add_constraint(
        smooth_psd_triangle,
        MOI.VectorOfVariables(psd_entries),
        MOI.PositiveSemidefiniteConeTriangle(2),
    )
    push!(models, smooth_psd_triangle)
    push!(cases, ProfileCase(
        "coupled_smooth_psd_triangle_boundary",
        evaluation_point(
            smooth_psd_triangle, [0.0, 0.0, 1.0];
            label = "simple-zero-mode PSD boundary",
        );
        description = "A packed 2-by-2 PSD boundary with one simple zero eigenvalue.",
        task = "synthetic coupled-cone qualification diagnostics",
        formulation = "single packed-symmetric PSD cone",
        initialization = "smooth feasible boundary point",
        scale = "eigenvalues 0 and 1",
        expected_evidence = [:coupled_set_robinson_cq_regular],
        tags = [:synthetic, :cone, :positive_semidefinite, :matrix, :qualification],
        metadata = Dict("cone" => "PositiveSemidefiniteConeTriangle", "geometry" => "simple zero eigenvalue"),
    ))

    repeated_zero_psd = MOI.Utilities.Model{Float64}()
    repeated_zero_psd_entries = MOI.add_variables(repeated_zero_psd, 3)
    MOI.add_constraint(
        repeated_zero_psd,
        MOI.VectorOfVariables(repeated_zero_psd_entries),
        MOI.PositiveSemidefiniteConeTriangle(2),
    )
    push!(models, repeated_zero_psd)
    push!(cases, ProfileCase(
        "coupled_psd_repeated_zero_mode",
        evaluation_point(repeated_zero_psd, [0.0, 0.0, 0.0]; label = "repeated-zero PSD boundary");
        description = "A PSD boundary with two zero eigenvalues and no unique boundary normal.",
        task = "synthetic coupled-cone qualification diagnostics",
        formulation = "single packed-symmetric PSD cone",
        initialization = "nonsmooth feasible boundary point",
        scale = "zero matrix",
        expected_evidence = [:coupled_set_nonsmooth_boundary_active],
        tags = [:synthetic, :cone, :positive_semidefinite, :matrix, :nonsmooth],
        metadata = Dict("cone" => "PositiveSemidefiniteConeTriangle", "geometry" => "repeated zero eigenvalue"),
    ))

    indefinite_psd = MOI.Utilities.Model{Float64}()
    indefinite_psd_entries = MOI.add_variables(indefinite_psd, 3)
    MOI.add_constraint(
        indefinite_psd,
        MOI.VectorOfVariables(indefinite_psd_entries),
        MOI.PositiveSemidefiniteConeTriangle(2),
    )
    push!(models, indefinite_psd)
    push!(cases, ProfileCase(
        "coupled_psd_negative_eigenvalue",
        evaluation_point(indefinite_psd, [-1.0, 0.0, 1.0]; label = "indefinite PSD input");
        description = "A packed PSD input with one negative eigenvalue and a proven coupled-set violation.",
        task = "synthetic coupled-cone feasibility diagnostics",
        formulation = "single packed-symmetric PSD cone",
        initialization = "infeasible matrix point",
        scale = "eigenvalues -1 and 1",
        expected_evidence = [:coupled_set_feasibility_violation],
        tags = [:synthetic, :cone, :positive_semidefinite, :matrix, :feasibility],
        metadata = Dict("cone" => "PositiveSemidefiniteConeTriangle", "geometry" => "negative eigenvalue"),
    ))

    smooth_scaled_psd_triangle = MOI.Utilities.Model{Float64}()
    scaled_psd_entries = MOI.add_variables(smooth_scaled_psd_triangle, 3)
    MOI.add_constraint(
        smooth_scaled_psd_triangle,
        MOI.VectorOfVariables(scaled_psd_entries),
        MOI.Scaled(MOI.PositiveSemidefiniteConeTriangle(2)),
    )
    push!(models, smooth_scaled_psd_triangle)
    push!(cases, ProfileCase(
        "coupled_smooth_scaled_psd_triangle_boundary",
        evaluation_point(
            smooth_scaled_psd_triangle, [1.0, sqrt(2.0), 1.0];
            label = "scaled packed PSD boundary",
        );
        description = "A scaled packed 2-by-2 PSD boundary with a nonzero off-diagonal coordinate.",
        task = "synthetic coupled-cone qualification diagnostics",
        formulation = "single scaled packed-symmetric PSD cone",
        initialization = "smooth feasible boundary point",
        scale = "unscaled matrix [1 1; 1 1]",
        expected_evidence = [:coupled_set_robinson_cq_regular],
        tags = [:synthetic, :cone, :positive_semidefinite, :scaled, :matrix, :qualification],
        metadata = Dict("cone" => "ScaledPositiveSemidefiniteConeTriangle", "geometry" => "simple zero eigenvalue"),
    ))

    smooth_logdet = MOI.Utilities.Model{Float64}()
    logdet_entries = MOI.add_variables(smooth_logdet, 5)
    MOI.add_constraint(
        smooth_logdet,
        MOI.VectorOfVariables(logdet_entries),
        MOI.LogDetConeTriangle(2),
    )
    push!(models, smooth_logdet)
    push!(cases, ProfileCase(
        "coupled_smooth_logdet_triangle_boundary",
        evaluation_point(
            smooth_logdet, [0.0, 1.0, 1.0, 0.0, 1.0];
            label = "identity log-determinant boundary",
        );
        description = "A packed 2-by-2 log-determinant cone boundary on its positive-definite slice.",
        task = "synthetic coupled-cone qualification diagnostics",
        formulation = "single packed-symmetric log-determinant cone",
        initialization = "smooth feasible boundary point",
        scale = "u=1, X=I",
        expected_evidence = [:coupled_set_robinson_cq_regular],
        tags = [:synthetic, :cone, :logdet, :matrix, :qualification],
        metadata = Dict("cone" => "LogDetConeTriangle", "geometry" => "positive-definite boundary"),
    ))

    near_singular_logdet = MOI.Utilities.Model{Float64}()
    near_singular_logdet_entries = MOI.add_variables(near_singular_logdet, 5)
    MOI.add_constraint(
        near_singular_logdet,
        MOI.VectorOfVariables(near_singular_logdet_entries),
        MOI.LogDetConeTriangle(2),
    )
    push!(models, near_singular_logdet)
    push!(cases, ProfileCase(
        "coupled_logdet_near_singular_boundary",
        evaluation_point(
            near_singular_logdet, [log(1.0e-10), 1.0, 1.0e-10, 0.0, 1.0];
            label = "near-singular log-determinant boundary",
        );
        description = "A feasible log-determinant boundary whose inverse-matrix derivative is intentionally withheld near singularity.",
        task = "synthetic coupled-cone qualification diagnostics",
        formulation = "single packed-symmetric log-determinant cone",
        initialization = "positive-definite but near-singular boundary point",
        scale = "u=1, eigenvalues 1e-10 and 1",
        expected_evidence = [:coupled_set_boundary_tangent_semantics_unavailable],
        tags = [:synthetic, :cone, :logdet, :matrix, :initialization, :derivative_domain],
        metadata = Dict("cone" => "LogDetConeTriangle", "geometry" => "near singular"),
    ))

    smooth_rootdet = MOI.Utilities.Model{Float64}()
    rootdet_entries = MOI.add_variables(smooth_rootdet, 4)
    MOI.add_constraint(
        smooth_rootdet,
        MOI.VectorOfVariables(rootdet_entries),
        MOI.RootDetConeTriangle(2),
    )
    push!(models, smooth_rootdet)
    push!(cases, ProfileCase(
        "coupled_smooth_rootdet_triangle_boundary",
        evaluation_point(
            smooth_rootdet, [1.0, 1.0, 0.0, 1.0];
            label = "identity root-determinant boundary",
        );
        description = "A packed 2-by-2 root-determinant boundary at a positive-definite matrix.",
        task = "synthetic coupled-cone qualification diagnostics",
        formulation = "single packed-symmetric root-determinant cone",
        initialization = "smooth feasible boundary point",
        scale = "t=1, X=I",
        expected_evidence = [:coupled_set_robinson_cq_regular],
        tags = [:synthetic, :cone, :rootdet, :matrix, :qualification],
        metadata = Dict("cone" => "RootDetConeTriangle", "geometry" => "positive-definite boundary"),
    ))

    soc_apex = MOI.Utilities.Model{Float64}()
    apex_t, apex_x = MOI.add_variables(soc_apex, 2)
    MOI.add_constraint(soc_apex, MOI.VectorOfVariables([apex_t, apex_x]), MOI.SecondOrderCone(2))
    push!(models, soc_apex)
    push!(cases, ProfileCase(
        "coupled_soc_apex",
        evaluation_point(soc_apex, [0.0, 0.0]; label = "SOC apex");
        description = "A nonsmooth SOC apex, intentionally unavailable to the smooth qualification screen.",
        task = "synthetic coupled-cone qualification diagnostics",
        formulation = "single second-order cone",
        initialization = "nonsmooth feasible apex",
        scale = "zero cone coordinates",
        expected_evidence = [:coupled_set_nonsmooth_boundary_active],
        tags = [:synthetic, :cone, :soc, :nonsmooth],
        metadata = Dict("cone" => "SOC", "geometry" => "apex"),
    ))

    dependent_normals = MOI.Utilities.Model{Float64}()
    dependent_t, dependent_x = MOI.add_variables(dependent_normals, 2)
    MOI.add_constraint(
        dependent_normals, MOI.VectorOfVariables([dependent_t, dependent_x]),
        MOI.SecondOrderCone(2),
    )
    MOI.add_constraint(
        dependent_normals,
        MOI.VectorAffineFunction(
            [
                MOI.VectorAffineTerm(1, MOI.ScalarAffineTerm(-1.0, dependent_t)),
                MOI.VectorAffineTerm(2, MOI.ScalarAffineTerm(1.0, dependent_x)),
            ],
            [2.0, -2.0],
        ),
        MOI.SecondOrderCone(2),
    )
    push!(models, dependent_normals)
    push!(cases, ProfileCase(
        "coupled_dependent_boundary_normals",
        evaluation_point(dependent_normals, [1.0, 1.0]; label = "dependent normals");
        description = "Two smooth SOC boundaries with opposing mapped normals and a local positive dependence.",
        task = "synthetic coupled-cone qualification diagnostics",
        formulation = "two affine-mapped second-order cones",
        initialization = "shared smooth feasible boundary point",
        scale = "unit cone coordinates",
        expected_evidence = [
            :coupled_set_robinson_cq_nonregular,
            :coupled_set_dependent_boundary_normals,
        ],
        tags = [:synthetic, :cone, :soc, :degeneracy, :qualification],
        metadata = Dict("cone" => "SOC", "geometry" => "dependent normals"),
    ))
    return models, cases
end

"""Run repeated solver-independent profiles for the coupled-cone corpus."""
function profile_synthetic_coupled_cone_corpus(; kwargs...)
    models, cases = synthetic_coupled_cone_profile_corpus()
    return profile_cases_repeated(models, cases; kwargs...)
end

"""
    synthetic_quadratic_geometry_profile_corpus()

Return solver-independent quadratic-geometry cases for static scaling and
degeneracy diagnostics. The cases use only exact MOI quadratic functions and
explicit evaluation points; no solver is invoked or model data modified.
"""
function synthetic_quadratic_geometry_profile_corpus()
    models = MOI.Utilities.Model{Float64}[]
    cases = ProfileCase{Float64}[]
    Q = MOI.ScalarQuadraticFunction{Float64}
    QT = MOI.ScalarQuadraticTerm{Float64}
    AT = MOI.ScalarAffineTerm{Float64}

    circle = MOI.Utilities.Model{Float64}()
    x, y = MOI.add_variables(circle, 2)
    MOI.add_constraint(
        circle,
        Q([QT(2.0, x, x), QT(2.0, y, y)], MOI.ScalarAffineTerm{Float64}[], 0.0),
        MOI.EqualTo(4.0),
    )
    push!(models, circle)
    push!(cases, ProfileCase(
        "quadratic_nonunit_circle",
        evaluation_point(circle, [2.0, 0.0]; label = "radius-two point");
        description = "Exact unshifted circle with radius two for normalization evidence.",
        task = "synthetic quadratic-geometry diagnostics",
        formulation = "unshifted isotropic quadratic equality",
        initialization = "feasible radius-two point",
        scale = "radius=2",
        expected_evidence = [:nonunit_circular_constraint_radius],
        tags = [:synthetic, :quadratic, :geometry, :scaling],
        metadata = Dict("geometry" => "circle", "radius" => 2.0),
    ))

    nonlinear_circle = MOI.Utilities.Model{Float64}()
    nonlinear_x, nonlinear_y = MOI.add_variables(nonlinear_circle, 2)
    MOI.add_constraint(
        nonlinear_circle,
        MOI.ScalarNonlinearFunction(
            :+,
            Any[
                MOI.ScalarNonlinearFunction(:^, Any[nonlinear_x, 2]),
                MOI.ScalarNonlinearFunction(:*, Any[nonlinear_y, nonlinear_y]),
            ],
        ),
        MOI.EqualTo(4.0),
    )
    push!(models, nonlinear_circle)
    push!(cases, ProfileCase(
        "nonlinear_nonunit_circle",
        evaluation_point(nonlinear_circle, [2.0, 0.0]; label = "radius-two point");
        description = "The same radius-two circle encoded as a ScalarNonlinearFunction.",
        task = "synthetic quadratic-geometry diagnostics",
        formulation = "unshifted nonlinear sum of squares equality",
        initialization = "feasible radius-two point",
        scale = "radius=2",
        expected_evidence = [:nonunit_circular_constraint_radius],
        tags = [:synthetic, :quadratic, :geometry, :scaling, :nonlinear],
        metadata = Dict(
            "geometry" => "circle",
            "radius" => 2.0,
            "representation" => "ScalarNonlinearFunction",
            "equivalent_case" => "quadratic_nonunit_circle",
        ),
    ))

    ellipsoid = MOI.Utilities.Model{Float64}()
    u, v = MOI.add_variables(ellipsoid, 2)
    MOI.add_constraint(
        ellipsoid,
        Q(
            [QT(2.0, u, u), QT(8.0, v, v)],
            [AT(-4.0, u), AT(8.0, v)],
            0.0,
        ),
        MOI.EqualTo(-4.0),
    )
    push!(models, ellipsoid)
    push!(cases, ProfileCase(
        "quadratic_shifted_ellipsoid",
        evaluation_point(ellipsoid, [4.0, -1.0]; label = "major-axis point");
        description = "Exact shifted diagonal ellipsoid with semiaxes two and one.",
        task = "synthetic quadratic-geometry diagnostics",
        formulation = "shifted positive diagonal quadratic equality",
        initialization = "feasible major-axis point",
        scale = "semiaxes=2,1",
        expected_evidence = [:nonunit_ellipsoidal_constraint_axes],
        tags = [:synthetic, :quadratic, :geometry, :scaling, :shifted],
        metadata = Dict("geometry" => "ellipsoid", "semiaxes" => "2,1"),
    ))

    nonlinear_ellipsoid = MOI.Utilities.Model{Float64}()
    nonlinear_u, nonlinear_v = MOI.add_variables(nonlinear_ellipsoid, 2)
    MOI.add_constraint(
        nonlinear_ellipsoid,
        MOI.ScalarNonlinearFunction(
            :+,
            Any[
                MOI.ScalarNonlinearFunction(:^, Any[nonlinear_u, 2]),
                MOI.ScalarNonlinearFunction(
                    :*,
                    Any[4.0, MOI.ScalarNonlinearFunction(:^, Any[nonlinear_v, 2])],
                ),
                MOI.ScalarNonlinearFunction(:*, Any[-4.0, nonlinear_u]),
                MOI.ScalarNonlinearFunction(:*, Any[8.0, nonlinear_v]),
            ],
        ),
        MOI.EqualTo(-4.0),
    )
    push!(models, nonlinear_ellipsoid)
    push!(cases, ProfileCase(
        "nonlinear_shifted_ellipsoid",
        evaluation_point(nonlinear_ellipsoid, [4.0, -1.0]; label = "major-axis point");
        description = "The same shifted ellipsoid encoded as a ScalarNonlinearFunction.",
        task = "synthetic quadratic-geometry diagnostics",
        formulation = "shifted nonlinear positive diagonal equality",
        initialization = "feasible major-axis point",
        scale = "semiaxes=2,1",
        expected_evidence = [:nonunit_ellipsoidal_constraint_axes],
        tags = [:synthetic, :quadratic, :geometry, :scaling, :shifted, :nonlinear],
        metadata = Dict(
            "geometry" => "ellipsoid",
            "semiaxes" => "2,1",
            "representation" => "ScalarNonlinearFunction",
            "equivalent_case" => "quadratic_shifted_ellipsoid",
        ),
    ))

    zero_radius = MOI.Utilities.Model{Float64}()
    p, q = MOI.add_variables(zero_radius, 2)
    MOI.add_constraint(
        zero_radius,
        Q([QT(2.0, p, p), QT(2.0, q, q)], MOI.ScalarAffineTerm{Float64}[], 0.0),
        MOI.EqualTo(0.0),
    )
    push!(models, zero_radius)
    push!(cases, ProfileCase(
        "quadratic_zero_radius",
        evaluation_point(zero_radius, [0.0, 0.0]; label = "implicit fixed center");
        description = "Exact zero-radius circle that implicitly fixes both coordinates.",
        task = "synthetic quadratic-geometry diagnostics",
        formulation = "zero-level isotropic quadratic equality",
        initialization = "implied center",
        scale = "radius=0",
        expected_evidence = [
            :zero_radius_circular_constraint,
            :nonregular_zero_radius_quadratic_fixing,
        ],
        tags = [:synthetic, :quadratic, :geometry, :degeneracy],
        metadata = Dict("geometry" => "zero_radius_circle", "radius" => 0.0),
    ))

    impossible_circle = MOI.Utilities.Model{Float64}()
    r, s = MOI.add_variables(impossible_circle, 2)
    MOI.add_constraint(
        impossible_circle,
        Q([QT(2.0, r, r), QT(2.0, s, s)], MOI.ScalarAffineTerm{Float64}[], 0.0),
        MOI.EqualTo(-1.0),
    )
    push!(models, impossible_circle)
    push!(cases, ProfileCase(
        "quadratic_negative_radius_squared",
        evaluation_point(impossible_circle, [0.0, 0.0]; label = "infeasible center probe");
        description = "Exact circle equality with a negative radius squared, which is statically infeasible.",
        task = "synthetic quadratic-geometry diagnostics",
        formulation = "infeasible isotropic quadratic equality",
        initialization = "center probe for static-infeasible model",
        scale = "radius_squared=-1",
        expected_evidence = [:infeasible_negative_radius_squared_circular_constraint],
        tags = [:synthetic, :quadratic, :geometry, :infeasible],
        metadata = Dict("geometry" => "circle", "radius_squared" => -1.0),
    ))

    conflicting_bounds = MOI.Utilities.Model{Float64}()
    a, b = MOI.add_variables(conflicting_bounds, 2)
    MOI.add_constraint(
        conflicting_bounds,
        Q(
            [QT(2.0, a, a), QT(8.0, b, b)],
            [AT(-4.0, a), AT(8.0, b)],
            3.0,
        ),
        MOI.LessThan(-1.0),
    )
    MOI.add_constraint(conflicting_bounds, a, MOI.GreaterThan(5.0))
    push!(models, conflicting_bounds)
    push!(cases, ProfileCase(
        "quadratic_implied_bound_conflict",
        evaluation_point(conflicting_bounds, [5.0, -1.0]; label = "bound-conflict probe");
        description = "Diagonal quadratic coordinate interval conflicting with a declared scalar lower bound.",
        task = "synthetic quadratic-geometry diagnostics",
        formulation = "positive diagonal quadratic upper level with scalar-bound conflict",
        initialization = "declared-bound endpoint",
        scale = "quadratic interval x=[0,4], declared x>=5",
        expected_evidence = [:inconsistent_diagonal_quadratic_implied_variable_bound],
        tags = [:synthetic, :quadratic, :geometry, :infeasible, :bounds],
        metadata = Dict("geometry" => "ellipsoid", "conflicting_variable_lower" => 5.0),
    ))

    minimum_level = MOI.Utilities.Model{Float64}()
    h, k = MOI.add_variables(minimum_level, 2)
    MOI.add_constraint(
        minimum_level,
        Q(
            [QT(2.0, h, h), QT(8.0, k, k)],
            [AT(-4.0, h), AT(8.0, k)],
            3.0,
        ),
        MOI.LessThan(-5.0),
    )
    push!(models, minimum_level)
    push!(cases, ProfileCase(
        "quadratic_minimum_level_inequality",
        evaluation_point(minimum_level, [2.0, -1.0]; label = "minimum-level center");
        description = "Positive diagonal quadratic upper level equal to its exact minimum.",
        task = "synthetic quadratic-geometry diagnostics",
        formulation = "minimum-level positive diagonal quadratic inequality",
        initialization = "implied center",
        scale = "minimum=-5",
        expected_evidence = [
            :minimum_level_diagonal_quadratic_constraint,
            :nonregular_minimum_level_diagonal_quadratic_inequality,
        ],
        tags = [:synthetic, :quadratic, :geometry, :degeneracy, :active_set],
        metadata = Dict("geometry" => "ellipsoid", "minimum_value" => -5.0),
    ))
    return models, cases
end

"""Run repeated solver-independent profiles for the quadratic-geometry corpus."""
function profile_synthetic_quadratic_geometry_corpus(; kwargs...)
    models, cases = synthetic_quadratic_geometry_profile_corpus()
    return profile_cases_repeated(models, cases; kwargs...)
end

"""
    profile_synthetic_sparse_ladder(dimensions; ...)

Run the deterministic sparse calibration corpus at each requested dimension.
Results remain grouped by dimension and case so local timing, allocation,
availability, and expected-evidence observations are never reduced to one
cross-size performance score.
"""
function profile_synthetic_sparse_ladder(
    dimensions::AbstractVector{<:Integer};
    kwargs...,
)
    isempty(dimensions) && return Dict{Int,Dict{String,ProfileAggregate{Float64}}}()
    all(dimension -> dimension >= 2, dimensions) ||
        throw(ArgumentError("every sparse ladder dimension must be at least two"))
    length(unique(dimensions)) == length(dimensions) ||
        throw(ArgumentError("sparse ladder dimensions must be unique"))
    ladder = Dict{Int,Dict{String,ProfileAggregate{Float64}}}()
    for dimension in dimensions
        models, cases = synthetic_sparse_profile_corpus(dimension = dimension)
        ladder[Int(dimension)] = profile_cases_repeated(models, cases; kwargs...)
    end
    return ladder
end
