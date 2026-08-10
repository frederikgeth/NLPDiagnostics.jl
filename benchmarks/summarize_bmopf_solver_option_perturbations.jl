#!/usr/bin/env julia

"""Summarize bounded solver-option perturbation matrices."""

using JSON
using SHA

Base.include(@__MODULE__, joinpath(@__DIR__, "benchmark_environment.jl"))

_dict(value) = value isa AbstractDict ? Dict{String,Any}(string(k) => v for (k, v) in value) : Dict{String,Any}()

function _canonical(value)
    value isa AbstractDict && return Dict{String,Any}(
        String(key) => _canonical(value[key]) for
        key in sort!(collect(keys(value)); by = string)
    )
    value isa AbstractVector && return [_canonical(item) for item in value]
    return value
end

_fingerprint(value) = bytes2hex(SHA.sha256(codeunits(JSON.json(_canonical(value)))))

function _model_semantic_contract(case)
    context_codes = _dict(get(case, "bmopf_context_finding_codes", nothing))
    context_profile = _dict(get(case, "bmopf_context_profile", nothing))
    context_metadata = _dict(get(context_profile, "metadata", nothing))
    source_contract = _dict(get(case, "source_behavior_contract", nothing))
    structural_prefixes = (
        "bmopf_component_",
        "bmopf_grounding_",
        "bmopf_opf_registry_",
        "bmopf_source_schema_",
        "bmopf_terminal_",
        "component_port_assembly_",
        "component_port_nominal_scale_",
    )
    structural_metadata = Dict{String,Any}(
        key => value for (key, value) in context_metadata
        if any(prefix -> startswith(key, prefix), structural_prefixes)
    )
    contract = Dict{String,Any}(
        "model_variable_count" => get(case, "model_variable_count", nothing),
        "context_profile_available" => !isempty(context_profile),
        "context_structural_metadata" => structural_metadata,
        "source_behavior_contract" => source_contract,
    )
    return contract, _fingerprint(contract), context_codes
end

function _tolerances()
    absolute = parse(Float64, get(ENV,
        "NLPDIAGNOSTICS_BMOPF_OPTION_RESIDUAL_ABSOLUTE_TOLERANCE", "1.0e-10"))
    relative = parse(Float64, get(ENV,
        "NLPDIAGNOSTICS_BMOPF_OPTION_RESIDUAL_RELATIVE_TOLERANCE", "1.0e-8"))
    endpoint = parse(Float64, get(ENV,
        "NLPDIAGNOSTICS_BMOPF_OPTION_ENDPOINT_TOLERANCE", "1.0e-6"))
    all(value -> isfinite(value) && value >= 0.0, (absolute, relative, endpoint)) ||
        error("option-perturbation tolerances must be finite and nonnegative")
    return (absolute = absolute, relative = relative, endpoint = endpoint)
end

function _material_change(baseline::Number, changed::Number, tolerances)
    return abs(changed - baseline) > tolerances.absolute +
        tolerances.relative * max(abs(baseline), abs(changed))
end

function _row_peak(trace)
    peak = Dict{String,Float64}()
    for raw_row in get(_dict(trace), "rows", Any[])
        for (family, raw_family) in _dict(get(_dict(raw_row), "families", nothing))
            value = get(_dict(raw_family), "max_feasibility_violation", nothing)
            value isa Number && isfinite(Float64(value)) &&
                (peak[family] = max(get(peak, family, 0.0), Float64(value)))
        end
    end
    return [Dict{String,Any}("family" => family, "peak" => value)
            for (family, value) in first(sort!(collect(peak); by = pair -> (-pair.second, pair.first)),
                min(length(peak), 5))]
end

function _row_peak_map(trace)
    peaks = Dict{String,Float64}()
    for raw_row in get(_dict(trace), "rows", Any[])
        for (family, raw_family) in _dict(get(_dict(raw_row), "families", nothing))
            value = get(_dict(raw_family), "max_feasibility_violation", nothing)
            value isa Number && isfinite(Float64(value)) &&
                (peaks[family] = max(get(peaks, family, 0.0), Float64(value)))
        end
    end
    return peaks
end

function _peak_deltas(base, perturbed, tolerances = _tolerances())
    families = union(keys(base), keys(perturbed))
    deltas = Dict{String,Any}[]
    for family in families
        baseline = get(base, family, 0.0)
        changed = get(perturbed, family, 0.0)
        delta = changed - baseline
        isfinite(delta) || continue
        material = _material_change(baseline, changed, tolerances)
        push!(deltas, Dict{String,Any}(
            "family" => family,
            "baseline_peak" => baseline,
            "perturbed_peak" => changed,
            "delta" => delta,
            "absolute_delta" => abs(delta),
            "material_change" => material,
        ))
    end
    sort!(deltas; by = item -> (-item["absolute_delta"], item["family"]))
    return deltas
end

function _material_peak_change(base, perturbed, tolerances = _tolerances())
    any(item["material_change"] for item in _peak_deltas(base, perturbed, tolerances))
end

function _family_trajectories(trace)
    samples = Dict{String,Vector{NamedTuple{(:iteration, :phase, :value),Tuple{Any,String,Float64}}}}()
    for raw_row in get(_dict(trace), "rows", Any[])
        row = _dict(raw_row)
        phase = String(get(row, "phase", "unknown"))
        iteration = get(row, "iteration", nothing)
        for (family, raw_family) in _dict(get(row, "families", nothing))
            value = get(_dict(raw_family), "max_feasibility_violation", nothing)
            value isa Number && isfinite(Float64(value)) || continue
            push!(get!(samples, family, NamedTuple{(:iteration, :phase, :value),Tuple{Any,String,Float64}}[]),
                (iteration = iteration, phase = phase, value = Float64(value)))
        end
    end
    trajectories = Dict{String,Any}()
    for (family, values) in samples
        post_initial = length(values) > 1 ? @view(values[2:end]) : values[1:0]
        regular = filter(sample -> sample.phase == "regular", post_initial)
        restoration = filter(sample -> sample.phase == "restoration", post_initial)
        trajectories[family] = Dict{String,Any}(
            "sample_count" => length(values),
            "post_first_captured_sample_count" => length(post_initial),
            "first_captured" => first(values).value,
            "final_captured" => last(values).value,
            "global_peak" => maximum(sample.value for sample in values),
            "post_first_captured_peak" => isempty(post_initial) ? nothing :
                maximum(sample.value for sample in post_initial),
            "post_first_regular_peak" => isempty(regular) ? nothing :
                maximum(sample.value for sample in regular),
            "post_first_restoration_peak" => isempty(restoration) ? nothing :
                maximum(sample.value for sample in restoration),
        )
    end
    return trajectories
end

function _trajectory_deltas(base, perturbed, tolerances = _tolerances())
    comparisons = Dict{String,Any}[]
    statistics = (
        "first_captured",
        "final_captured",
        "post_first_captured_peak",
        "post_first_regular_peak",
        "post_first_restoration_peak",
    )
    for family in union(keys(base), keys(perturbed))
        baseline = get(base, family, nothing)
        changed = get(perturbed, family, nothing)
        item = Dict{String,Any}(
            "family" => family,
            "baseline_available" => !isnothing(baseline),
            "perturbed_available" => !isnothing(changed),
            "coverage_changed" => isnothing(baseline) != isnothing(changed),
        )
        material = false
        for statistic in statistics
            baseline_value = isnothing(baseline) ? nothing : get(baseline, statistic, nothing)
            changed_value = isnothing(changed) ? nothing : get(changed, statistic, nothing)
            changed_statistic = baseline_value isa Number && changed_value isa Number ?
                _material_change(baseline_value, changed_value, tolerances) :
                isnothing(baseline_value) != isnothing(changed_value)
            item["baseline_$statistic"] = baseline_value
            item["perturbed_$statistic"] = changed_value
            item["$(statistic)_delta"] = baseline_value isa Number && changed_value isa Number ?
                changed_value - baseline_value : nothing
            item["$(statistic)_changed"] = changed_statistic
            statistic != "first_captured" && (material |= changed_statistic)
        end
        item["trajectory_changed"] = material || item["coverage_changed"]
        push!(comparisons, item)
    end
    sort!(comparisons; by = item -> item["family"])
    return comparisons
end

function _record(entry, profile, options, policy, tolerances = _tolerances())
    summary_path = get(entry, "summary_path", nothing)
    summary_path isa AbstractString && isfile(summary_path) || return nothing
    summary = JSON.parsefile(summary_path)
    cases = get(summary, "cases", Any[])
    isempty(cases) && return nothing
    case = _dict(first(cases))
    trace = _dict(get(case, "trace", nothing))
    residual = _dict(get(case, "row_family_residual_trace", nothing))
    phases = _dict(get(trace, "phase_counts", nothing))
    final_primal = get(trace, "final_primal_infeasibility", nothing)
    final_dual = get(trace, "final_dual_infeasibility", nothing)
    endpoint_failure = (final_primal isa Number && abs(Float64(final_primal)) > tolerances.endpoint) ||
        (final_dual isa Number && abs(Float64(final_dual)) > tolerances.endpoint)
    semantic_contract, semantic_fingerprint, context_codes =
        _model_semantic_contract(case)
    return Dict{String,Any}(
        "key" => string(get(entry, "case", get(case, "snapshot", "unknown")),
            "|max_iter=", get(entry, "budget", "unknown")),
        "case" => get(entry, "case", get(case, "snapshot", "unknown")),
        "budget" => get(entry, "budget", nothing),
        "profile" => profile,
        "options" => options,
        "initialization_policy" => policy,
        "environment_fingerprint" => get(summary, "environment_fingerprint", nothing),
        "environment" => get(summary, "environment", nothing),
        "model_semantic_contract" => semantic_contract,
        "model_semantic_fingerprint" => semantic_fingerprint,
        "bmopf_context_finding_codes" => context_codes,
        "classification" => get(entry, "classification", "unavailable"),
        "trace_record_count" => get(trace, "record_count", nothing),
        "phase_counts" => phases,
        "restoration_record_count" => get(phases, "restoration", 0),
        "final_primal_infeasibility" => final_primal,
        "final_dual_infeasibility" => final_dual,
        "endpoint_residual_failure_signature" => endpoint_failure,
        "row_family_residual_status" => get(residual, "status", "unavailable"),
        "row_family_residual_peak_map" => _row_peak_map(residual),
        "row_family_residual_trajectories" => _family_trajectories(residual),
        "largest_family_peak_residuals" => _row_peak(residual),
    )
end

function _comparison(reference, candidate, tolerances)
    trajectory_deltas = _trajectory_deltas(
        reference["row_family_residual_trajectories"],
        candidate["row_family_residual_trajectories"], tolerances,
    )
    global_peak_changed = _material_peak_change(
        reference["row_family_residual_peak_map"],
        candidate["row_family_residual_peak_map"], tolerances,
    )
    first_captured_changed = any(
        item["first_captured_changed"] for item in trajectory_deltas
    )
    trajectory_changed = any(item["trajectory_changed"] for item in trajectory_deltas)
    semantic_changed = candidate["model_semantic_contract"] !=
        reference["model_semantic_contract"]
    context_findings_changed = candidate["bmopf_context_finding_codes"] !=
        reference["bmopf_context_finding_codes"]
    return Dict{String,Any}(
        "key" => candidate["key"],
        "profile" => candidate["profile"],
        "reference_profile" => reference["profile"],
        "candidate_profile" => candidate["profile"],
        "initialization_policy" => candidate["initialization_policy"],
        "classification_changed" => candidate["classification"] != reference["classification"],
        "restoration_signature_changed" => candidate["restoration_record_count"] !=
            reference["restoration_record_count"],
        "endpoint_residual_signature_changed" => candidate[
            "endpoint_residual_failure_signature"] != reference[
            "endpoint_residual_failure_signature"],
        "model_semantic_contract_changed" => semantic_changed,
        "bmopf_context_finding_codes_changed" => context_findings_changed,
        "reference_model_semantic_fingerprint" =>
            reference["model_semantic_fingerprint"],
        "candidate_model_semantic_fingerprint" =>
            candidate["model_semantic_fingerprint"],
        "trace_record_count_delta" => candidate["trace_record_count"] isa Number &&
            reference["trace_record_count"] isa Number ? candidate["trace_record_count"] -
            reference["trace_record_count"] : nothing,
        "row_family_residual_changed" => trajectory_changed,
        "row_family_global_peak_changed" => global_peak_changed,
        "row_family_first_captured_changed" => first_captured_changed,
        "row_family_trajectory_changed" => trajectory_changed,
        "row_family_residual_trajectory_deltas" => trajectory_deltas,
        "row_family_residual_peak_deltas" => _peak_deltas(
            reference["row_family_residual_peak_map"],
            candidate["row_family_residual_peak_map"], tolerances),
        "baseline" => reference,
        "perturbed" => candidate,
    )
end

function main()
    length(ARGS) in (1, 2) || error(
        "usage: summarize_bmopf_solver_option_perturbations.jl <manifest.json> [output.json]",
    )
    manifest_path = abspath(ARGS[1])
    output_path = length(ARGS) == 2 ? abspath(ARGS[2]) :
        joinpath(dirname(manifest_path), "option_perturbation_summary.json")
    manifest = JSON.parsefile(manifest_path)
    tolerances = _tolerances()
    manifest_entries = get(manifest, "entries", Any[])
    declared_expected_entries = length(get(manifest, "options", Any[])) *
        length(get(manifest, "policies", Any[]))
    observations = Dict{String,Any}[]
    missing = String[]
    for raw_entry in manifest_entries
        entry = _dict(raw_entry)
        matrix_path = get(entry, "matrix_path", nothing)
        matrix_path isa AbstractString && isfile(matrix_path) || begin
            push!(missing, String(get(entry, "label", "unknown")))
            continue
        end
        matrix = JSON.parsefile(matrix_path)
        for raw_matrix_entry in get(matrix, "entries", Any[])
            matrix_entry = _dict(raw_matrix_entry)
            row = _record(matrix_entry, get(entry, "profile", "unknown"),
                get(entry, "options", ""), get(entry, "initialization_policy", "unknown"),
                tolerances)
            isnothing(row) ? push!(missing, String(get(entry, "label", "unknown"))) : push!(observations, row)
        end
    end
    baseline = Dict{Tuple{String,String,String},Dict{String,Any}}()
    for observation in observations
        observation["profile"] == "baseline" || continue
        baseline[(observation["case"], string(observation["budget"]),
            observation["initialization_policy"])] = observation
    end
    comparisons = Dict{String,Any}[]
    for observation in observations
        observation["profile"] == "baseline" && continue
        base = get(baseline, (observation["case"], string(observation["budget"]),
            observation["initialization_policy"]), nothing)
        isnothing(base) && continue
        push!(comparisons, _comparison(base, observation, tolerances))
    end
    cells = Dict{Tuple{String,String,String},Vector{Dict{String,Any}}}()
    for observation in observations
        observation["profile"] == "baseline" && continue
        key = (observation["case"], string(observation["budget"]),
            observation["initialization_policy"])
        push!(get!(cells, key, Dict{String,Any}[]), observation)
    end
    perturbation_comparisons = Dict{String,Any}[]
    for rows in values(cells)
        sort!(rows; by = row -> row["profile"])
        length(rows) < 2 && continue
        for left in 1:(length(rows) - 1), right in (left + 1):length(rows)
            push!(perturbation_comparisons,
                _comparison(rows[left], rows[right], tolerances))
        end
    end
    perturbation_profile_count = max(length(get(manifest, "options", Any[])) - 1, 0)
    expected_perturbation_comparisons = length(baseline) *
        div(perturbation_profile_count * (perturbation_profile_count - 1), 2)
    campaign_scope = String(get(manifest, "campaign_scope", "generic"))
    multiconductor_scope = campaign_scope == "multiconductor"
    semantic_contracts_available = !isempty(observations) && all(observation -> begin
        contract = _dict(get(observation, "model_semantic_contract", nothing))
        get(contract, "context_profile_available", false) === true &&
            !isempty(_dict(get(contract, "source_behavior_contract", nothing))) &&
            get(contract, "model_variable_count", nothing) isa Number
    end, observations)
    semantic_invariance = !isempty(comparisons) && all(comparison ->
        get(comparison, "model_semantic_contract_changed", true) === false,
        comparisons,
    )
    output = Dict{String,Any}(
        "report_version" => "bmopf-solver-option-perturbation-v4",
        "manifest_report_version" => get(manifest, "report_version", "unknown"),
        "manifest" => manifest_path,
        "cases" => sort!(unique(String[item["case"] for item in observations])),
        "solvers" => ["Ipopt"],
        "budgets" => get(manifest, "budgets", nothing),
        "campaign_scope" => campaign_scope,
        "option_profiles" => get(manifest, "options", Any[]),
        "initialization_policies" => get(manifest, "policies", Any[]),
        "environment_fingerprints" => sort!(unique(String[
            observation["environment_fingerprint"] for observation in observations
            if observation["environment_fingerprint"] isa AbstractString
        ])),
        "aggregation_environment" => _benchmark_environment(),
        "observations" => observations,
        "comparisons_vs_baseline" => comparisons,
        "model_semantic_contract_change_count" => count(comparison ->
            get(comparison, "model_semantic_contract_changed", false) === true,
            comparisons,
        ),
        "bmopf_context_finding_code_change_count" => count(comparison ->
            get(comparison, "bmopf_context_finding_codes_changed", false) === true,
            comparisons,
        ),
        "comparisons_between_perturbations" => perturbation_comparisons,
        "expected_between_perturbation_comparison_count" =>
            expected_perturbation_comparisons,
        "missing_records" => unique(missing),
        "experimental_design" => get(manifest, "experimental_design", nothing),
        "readiness" => Dict{String,Any}(
            "all_matrix_files_present" => isempty(missing),
            "all_manifest_entries_completed" => all(entry ->
                get(_dict(entry), "status", "unknown") == "ok",
                manifest_entries,
            ),
            "manifest_entry_count_complete" => declared_expected_entries > 0 &&
                length(manifest_entries) == declared_expected_entries,
            "observation_count_positive" => !isempty(observations),
            "baseline_comparisons_available" => !isempty(comparisons),
            "all_nonbaseline_observations_compared" => length(comparisons) == count(
                observation -> observation["profile"] != "baseline", observations,
            ),
            "all_row_family_residual_traces_available" => !isempty(observations) && all(
                observation -> observation["row_family_residual_status"] == "available",
                observations,
            ),
            "all_row_family_trajectories_nonempty" => !isempty(observations) && all(
                observation -> !isempty(observation["row_family_residual_trajectories"]),
                observations,
            ),
            "trajectory_comparisons_available" => !isempty(comparisons) && all(
                comparison -> haskey(comparison, "row_family_trajectory_changed"),
                comparisons,
            ),
            "between_perturbation_comparisons_available" =>
                length(perturbation_comparisons) == expected_perturbation_comparisons,
            "distinct_option_sets_declared" => get(
                _dict(get(manifest, "experimental_design", nothing)),
                "distinct_option_sets_required", false,
            ) === true,
            "model_semantic_contracts_available" => semantic_contracts_available,
            "model_semantic_invariance" => semantic_invariance,
            "multiconductor_semantic_gate_passed" => !multiconductor_scope ||
                (semantic_contracts_available && semantic_invariance),
        ),
        "interpretation" =>
            "Option perturbations test persistence of observed signatures under distinct, controlled solver changes. The first captured callback residual is reported separately from subsequent and endpoint behavior so a shared start cannot mask trajectory changes. The first callback is not assumed to equal the caller's initialization. Multiconductor scope additionally requires invariant structural context and source-behavior contracts; endpoint-conditioned context finding changes remain outcomes. These comparisons do not establish causality or formulation correctness.",
        "residual_comparison_tolerance" => Dict{String,Any}(
            "absolute" => tolerances.absolute,
            "relative" => tolerances.relative,
            "endpoint" => tolerances.endpoint,
            "interpretation" => "Within-family raw residual changes below this combined absolute-relative tolerance are treated as evaluation noise. The threshold is not a physical normalization and must not be used to rank different constraint families.",
        ),
    )
    write(output_path, JSON.json(output))
    println("wrote solver-option perturbation summary to $output_path")
end

if abspath(PROGRAM_FILE) == abspath(@__FILE__)
    main()
end
