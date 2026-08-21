#!/usr/bin/env julia

"""Run the matched multi-converter AC/DC base campaign with MadNLP.

This is the metric-telemetry companion to
`bmopf_acdc_multiconverter_campaign.jl`. It retains the identical fixture,
factorial cells, physical starts, endpoint contract, and initial-point geometry.
MadNLP supplies cumulative factorization, backsolve, derivative-evaluation, and
linear-solver-time counters. Its public callback does not supply primal iterate
coordinates, so no trace-resolved family geometry is claimed.

Environment controls use the prefix `NLPDIAGNOSTICS_ACDC_MULTI_MADNLP_`.
"""

include(joinpath(@__DIR__, "bmopf_acdc_multiconverter_campaign.jl"))

using MadNLP

const _ACDC_MULTI_MADNLP_RUNNER_VERSION =
    "bmopf-acdc-multiconverter-madnlp-campaign-v1"

const _ACDC_MULTI_MADNLP_CUMULATIVE_FIELDS = (
    "factorization_count_cumulative",
    "backsolve_count_cumulative",
    "linear_solver_time_seconds_cumulative",
    "objective_evaluation_count_cumulative",
    "objective_gradient_evaluation_count_cumulative",
    "constraint_evaluation_count_cumulative",
    "jacobian_evaluation_count_cumulative",
    "hessian_evaluation_count_cumulative",
)

function _madnlp_telemetry_field(artifact, field)
    telemetry = get(artifact, "linear_solver_telemetry", Dict())
    fields = get(telemetry, "fields", Dict())
    return get(fields, field, Dict())
end

function _madnlp_telemetry_final(artifact, field)
    record = _madnlp_telemetry_field(artifact, field)
    get(record, "coverage_complete", false) === true || return nothing
    get(record, "monotone_within_segments", false) === true || return nothing
    value = get(record, "final", nothing)
    return value isa Real && isfinite(value) ? Float64(value) : nothing
end

function _madnlp_telemetry_current_maximum(artifact, field)
    record = _madnlp_telemetry_field(artifact, field)
    get(record, "coverage_complete", false) === true || return nothing
    value = get(record, "maximum", nothing)
    return value isa Real && isfinite(value) ? Float64(value) : nothing
end

function _madnlp_run_telemetry_record(run)
    artifact = get(run, "artifact", Dict())
    telemetry = get(artifact, "linear_solver_telemetry", Dict())
    physical_endpoint = get(artifact, "physical_endpoint", Dict())
    public_endpoint = get(
        physical_endpoint,
        "public_solver_multiplier_report",
        physical_endpoint,
    )
    stationarity = get(public_endpoint, "stationarity", Dict())
    objective_weight_consistency = get(
        stationarity, "objective_weight_consistency", Dict(),
    )
    completion = get(
        physical_endpoint, "fixed_variable_dual_completion", Dict(),
    )
    cumulative = Dict{String,Any}(
        field => _madnlp_telemetry_final(artifact, field)
        for field in _ACDC_MULTI_MADNLP_CUMULATIVE_FIELDS
    )
    refinement = _madnlp_telemetry_current_maximum(
        artifact, "iterative_refinement_count_current",
    )
    line_search_counter = _madnlp_telemetry_current_maximum(
        artifact, "line_search_counter_at_callback",
    )
    factorization_numerics = get(
        telemetry, "factorization_numerics", Dict(),
    )
    coverage_complete =
        get(telemetry, "available", false) === true &&
        get(telemetry, "factorization_work_available", false) === true &&
        get(telemetry, "linear_solver_time_available", false) === true &&
        all(value -> value isa Real, values(cumulative)) &&
        refinement isa Real && line_search_counter isa Real
    return Dict{String,Any}(
        "policy" => get(run, "policy", nothing),
        "replicate" => get(run, "replicate", nothing),
        "coverage_complete" => coverage_complete,
        "cumulative_final" => cumulative,
        "iterative_refinement_count_maximum" => refinement,
        "line_search_counter_maximum" => line_search_counter,
        "factorization_work_available" =>
            get(telemetry, "factorization_work_available", false),
        "linear_solver_time_available" =>
            get(telemetry, "linear_solver_time_available", false),
        "factorization_numerics" => factorization_numerics,
        "inertia_available" =>
            get(factorization_numerics, "inertia_available", false),
        "pivot_statistics_available" =>
            get(factorization_numerics, "pivot_statistics_available", false),
        "fill_ratio_available" =>
            get(factorization_numerics, "fill_ratio_available", false),
        "backward_error_available" =>
            get(factorization_numerics, "backward_error_available", false),
        "objective_weight_consistency" => objective_weight_consistency,
        "potential_multiplier_normalization_mismatch" => get(
            objective_weight_consistency,
            "potential_multiplier_normalization_mismatch",
            false,
        ),
        "public_multiplier_endpoint_accepted" =>
            get(public_endpoint, "acceptance_passed", nothing),
        "completed_multiplier_endpoint_accepted" =>
            get(physical_endpoint, "acceptance_passed", nothing),
        "fixed_variable_dual_completion" => completion,
        "fixed_variable_dual_completion_available" =>
            get(completion, "available", false),
    )
end

function _madnlp_numeric_summary(values)
    numbers = Float64[
        Float64(value) for value in values if value isa Real && isfinite(value)
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
        "mean" => sum(numbers) / length(numbers),
        "spread" => maximum(numbers) - minimum(numbers),
    )
end

function _madnlp_policy_telemetry_summary(records)
    return Dict{String,Any}(
        "run_count" => length(records),
        "coverage_complete" => !isempty(records) && all(
            get(record, "coverage_complete", false) === true
            for record in records
        ),
        "factorization_count" => _madnlp_numeric_summary([
            get(record["cumulative_final"],
                "factorization_count_cumulative", nothing)
            for record in records
        ]),
        "backsolve_count" => _madnlp_numeric_summary([
            get(record["cumulative_final"],
                "backsolve_count_cumulative", nothing)
            for record in records
        ]),
        "linear_solver_time_seconds" => _madnlp_numeric_summary([
            get(record["cumulative_final"],
                "linear_solver_time_seconds_cumulative", nothing)
            for record in records
        ]),
        "jacobian_evaluation_count" => _madnlp_numeric_summary([
            get(record["cumulative_final"],
                "jacobian_evaluation_count_cumulative", nothing)
            for record in records
        ]),
        "hessian_evaluation_count" => _madnlp_numeric_summary([
            get(record["cumulative_final"],
                "hessian_evaluation_count_cumulative", nothing)
            for record in records
        ]),
        "iterative_refinement_count_maximum" => _madnlp_numeric_summary([
            get(record, "iterative_refinement_count_maximum", nothing)
            for record in records
        ]),
        "objective_weight_consistency_available_count" => count(
            record -> get(
                record["objective_weight_consistency"], "available", false,
            ) === true,
            records,
        ),
        "potential_multiplier_normalization_mismatch_count" => count(
            record -> get(
                record,
                "potential_multiplier_normalization_mismatch",
                false,
            ) === true,
            records,
        ),
        "fitted_physical_objective_weight" => _madnlp_numeric_summary([
            get(
                record["objective_weight_consistency"],
                "least_squares_fitted_physical_weight",
                nothing,
            ) for record in records
        ]),
        "public_multiplier_endpoint_acceptance_count" => count(
            record -> get(
                record, "public_multiplier_endpoint_accepted", false,
            ) === true,
            records,
        ),
        "completed_multiplier_endpoint_acceptance_count" => count(
            record -> get(
                record, "completed_multiplier_endpoint_accepted", false,
            ) === true,
            records,
        ),
        "fixed_variable_dual_completion_available_count" => count(
            record -> get(
                record, "fixed_variable_dual_completion_available", false,
            ) === true,
            records,
        ),
        "fixed_variable_dual_completion_maximum_correction" =>
            _madnlp_numeric_summary([
                get(
                    record["fixed_variable_dual_completion"],
                    "maximum_correction",
                    nothing,
                ) for record in records
            ]),
    )
end

function _madnlp_multiconverter_attribution(campaign, cell_specs)
    records = [_madnlp_run_telemetry_record(run)
        for run in get(campaign, "run_records", Any[])]
    grouped = Dict{String,Vector{Dict{String,Any}}}()
    for record in records
        policy = string(get(record, "policy", ""))
        push!(get!(grouped, policy, Dict{String,Any}[]), record)
    end
    policies = Dict{String,Any}(
        policy => _madnlp_policy_telemetry_summary(policy_records)
        for (policy, policy_records) in sort!(collect(grouped); by=first)
    )
    cells = Dict{String,Any}[]
    for spec in cell_specs
        cell = deepcopy(spec)
        summary = get(policies, cell["policy"], Dict())
        cell["responses"] = Dict{String,Any}(
            "factorization_count_mean" => _available_mean(
                get(summary, "factorization_count", Dict()),
            ),
            "backsolve_count_mean" => _available_mean(
                get(summary, "backsolve_count", Dict()),
            ),
            "linear_solver_time_seconds_mean" => _available_mean(
                get(summary, "linear_solver_time_seconds", Dict()),
            ),
            "jacobian_evaluation_count_mean" => _available_mean(
                get(summary, "jacobian_evaluation_count", Dict()),
            ),
            "hessian_evaluation_count_mean" => _available_mean(
                get(summary, "hessian_evaluation_count", Dict()),
            ),
            "iterative_refinement_count_maximum_mean" => _available_mean(
                get(summary, "iterative_refinement_count_maximum", Dict()),
            ),
        )
        cell["qualified"] = get(summary, "coverage_complete", false) === true
        push!(cells, cell)
    end
    response_names = [
        "factorization_count_mean",
        "backsolve_count_mean",
        "linear_solver_time_seconds_mean",
        "jacobian_evaluation_count_mean",
        "hessian_evaluation_count_mean",
        "iterative_refinement_count_maximum_mean",
    ]
    coverage_complete = !isempty(records) && all(
        get(record, "coverage_complete", false) === true for record in records
    )
    cell_coverage_complete = length(cells) == 16 && all(
        get(cell, "qualified", false) === true && all(
            response -> get(cell["responses"], response, nothing) isa Real,
            response_names,
        ) for cell in cells
    )
    unsupported_numerics_truthful = all(
        get(record, "inertia_available", true) === false &&
        get(record, "pivot_statistics_available", true) === false &&
        get(record, "fill_ratio_available", true) === false &&
        get(record, "backward_error_available", true) === false
        for record in records
    )
    normalization_mismatch_count = count(
        record -> get(
            record, "potential_multiplier_normalization_mismatch", false,
        ) === true,
        records,
    )
    qualified = coverage_complete && cell_coverage_complete &&
        unsupported_numerics_truthful
    return Dict{String,Any}(
        "schema_version" => "bmopf-acdc-multiconverter-madnlp-attribution-v1",
        "available" => !isempty(records),
        "attribution_qualified" => qualified,
        "run_count" => length(records),
        "records" => records,
        "policies" => policies,
        "cells" => cells,
        "effects" => _acdc_grid_effects(
            cells, response_names; effect_specs=_ACDC_MULTI_EFFECT_SPECS,
        ),
        "gates" => Dict{String,Any}(
            "cumulative_counter_coverage_complete" => coverage_complete,
            "complete_factorial_cell_response_coverage" =>
                cell_coverage_complete,
            "unsupported_factorization_numerics_truthfully_unavailable" =>
                unsupported_numerics_truthful,
            "public_moi_multiplier_normalization_consistent" =>
                normalization_mismatch_count == 0,
            "multiplier_normalization_is_not_a_linear_work_gate" => true,
        ),
        "endpoint_multiplier_normalization" => Dict{String,Any}(
            "potential_mismatch_count" => normalization_mismatch_count,
            "run_count" => length(records),
            "all_public_moi_multipliers_consistent_with_objective_weight_one" =>
                normalization_mismatch_count == 0,
            "interpretation" =>
                "an inconsistent multiplier representative limits public-dual KKT claims but does not invalidate callback work counters",
        ),
        "fixed_variable_dual_completion" => Dict{String,Any}(
            "available_count" => count(
                record -> get(
                    record,
                    "fixed_variable_dual_completion_available",
                    false,
                ) === true,
                records,
            ),
            "public_endpoint_acceptance_count" => count(
                record -> get(
                    record, "public_multiplier_endpoint_accepted", false,
                ) === true,
                records,
            ),
            "completed_endpoint_acceptance_count" => count(
                record -> get(
                    record, "completed_multiplier_endpoint_accepted", false,
                ) === true,
                records,
            ),
            "public_and_completed_representatives_retained" => true,
            "completion_is_not_a_linear_work_gate" => true,
        ),
        "primal_trajectory_capability" => Dict{String,Any}(
            "available" => false,
            "reason" =>
                "MadNLP's public intermediate callback has no stable public primal-vector accessor",
            "family_geometry_at_iterates_available" => false,
            "absence_is_not_a_qualification_failure" => true,
        ),
        "factorization_capability" => Dict{String,Any}(
            "work_counters_available" => true,
            "linear_solver_time_available" => true,
            "inertia_available" => false,
            "pivot_statistics_available" => false,
            "fill_ratio_available" => false,
            "backward_error_available" => false,
        ),
        "response_semantics" => Dict{String,Any}(
            "cumulative_counts" =>
                "final callback counter values; descriptive replicate means",
            "linear_solver_time" =>
                "solver-reported cumulative seconds; environment-local and not a repeatability gate",
            "effects" =>
                "within-controller/start unweighted 2^4 descriptive contrasts",
        ),
        "qualification" => Dict{String,Any}(
            "claim" =>
                "complete MadNLP cumulative factorization-work and derivative-counter attribution on the retained factorial cells",
            "does_not_establish" => [
                "primal-iterate family geometry",
                "factorization stability, inertia, fill, pivots, or backward error",
                "correct normalization of public MOI endpoint multipliers",
                "causality between initial geometry and linear-algebra work",
                "timing portability to another machine or run environment",
            ],
        ),
    )
end

function _madnlp_effect_direction_summary(case_records; qualified_only=false)
    samples = Dict{Tuple{String,String},Vector{Dict{String,Any}}}()
    for case_record in case_records
        for stratum_record in case_record["campaign"]["stratum_records"]
            qualified_only &&
                get(
                    stratum_record["campaign"],
                    "campaign_qualified",
                    false,
                ) !== true && continue
            attribution = stratum_record["campaign"]["linear_work_attribution"]
            for (response, effects) in get(attribution, "effects", Dict())
                for (effect, record) in effects
                    sample = Dict{String,Any}(
                        "case" => case_record["case"],
                        "stratum" => stratum_record["stratum"],
                        "estimate" => record["estimate"],
                    )
                    push!(
                        get!(samples, (response, effect), Dict{String,Any}[]),
                        sample,
                    )
                end
            end
        end
    end
    summary = Dict{String,Any}()
    for ((response, effect), records) in sort!(collect(samples); by=first)
        estimates = Float64[record["estimate"] for record in records]
        directions = [
            abs(value) <= 1.0e-12 ? "zero" :
            value > 0 ? "positive" : "negative"
            for value in estimates
        ]
        response_summary = get!(summary, response, Dict{String,Any}())
        response_summary[effect] = Dict{String,Any}(
            "sample_count" => length(records),
            "minimum" => minimum(estimates),
            "maximum" => maximum(estimates),
            "directions" => sort!(unique(directions)),
            "strict_direction_consistency" => length(unique(directions)) == 1,
            "samples" => records,
        )
    end
    return summary
end

function _acdc_multiconverter_solver_evidence_matrix()
    return Dict{String,Any}(
        "Ipopt" => Dict{String,Any}(
            "primal_iterate_geometry" => true,
            "regularization_at_iterates" => true,
            "cumulative_factorization_work" => false,
            "linear_solver_time" => false,
            "factorization_numerics" => false,
            "source" => "matched Ipopt companion campaign capability contract",
        ),
        "MadNLP" => Dict{String,Any}(
            "primal_iterate_geometry" => false,
            "regularization_at_iterates" => false,
            "cumulative_factorization_work" => true,
            "linear_solver_time" => true,
            "factorization_numerics" => false,
            "source" => "retained public MadNLP callback capability contract",
        ),
        "joint_same_run_geometry_and_factorization_work" => false,
        "interpretation" =>
            "the matched campaigns triangulate complementary evidence; they do not supply same-run causal linkage",
    )
end

function run_acdc_multiconverter_madnlp_campaign(;
    levels,
    repeats,
    seeds,
    relative_perturbation,
    max_iter,
    solver_tolerance,
    endpoint_absolute_tolerance=0.2,
    endpoint_relative_tolerance=3.0e-5,
    physical_complementarity_tolerance=2.0e-4,
)
    _validate_acdc_multi_levels(levels)
    repeats >= 2 || throw(ArgumentError("repeats must be at least two"))
    isempty(seeds) && throw(ArgumentError(
        "at least one perturbed-start seed is required for stratification",
    ))
    environment = _benchmark_environment()
    environment_fingerprint = _benchmark_environment_fingerprint(environment)
    policies, cells = _acdc_multiconverter_policies(levels)
    case_records = Dict{String,Any}[]
    for (control_case, droop) in (
        ("three-converter-p-v", false),
        ("three-converter-droop-sharing", true),
    )
        network = _acdc_multiconverter_fixture(; droop)
        anchor_context = _build_context(
            network,
            first(policies)[2]();
            add_objective=true,
            optimizer=MadNLP.Optimizer,
        )
        base_point = NLPDiagnostics.bmopf_start_completion_point(
            anchor_context;
            missing_value=0.0,
            label="$control_case-madnlp-native-start",
        )
        anchor_model = BMOPFTools.opf_model(anchor_context)
        strata = [(name="native", point=base_point)]
        append!(strata, [(
            name="nearby-seed-$seed",
            point=_safe_perturbed_point(
                anchor_model, base_point, seed, relative_perturbation,
            ),
        ) for seed in seeds])
        stratum_records = Dict{String,Any}[]
        for stratum in strata
            anchor_evaluation = NLPDiagnostics.evaluate_numerical(
                JuMP.backend(anchor_model), stratum.point,
            )
            campaign = _acdc_campaign_for_stratum(
                network,
                policies,
                control_case,
                stratum.name,
                anchor_context,
                anchor_evaluation,
                environment_fingerprint;
                repeats,
                max_iter,
                solver_tolerance,
                endpoint_absolute_tolerance,
                endpoint_relative_tolerance,
                physical_complementarity_tolerance,
                runner_version=_ACDC_MULTI_MADNLP_RUNNER_VERSION,
                optimizer=MadNLP.Optimizer,
                solver=:madnlp,
                solver_name="MadNLP",
                capture_points=false,
                trace_geometry=false,
                complete_fixed_variable_duals=true,
            )
            factorial = _acdc_grid_factorial_analysis(
                campaign,
                cells;
                factors=_ACDC_MULTI_FACTORS,
                effect_specs=_ACDC_MULTI_EFFECT_SPECS,
                schema_version=
                    "bmopf-acdc-multiconverter-madnlp-factorial-analysis-v1",
                required_responses=[
                    "condition_proxy_ratio_to_classic",
                    "row_norm_spread_ratio_to_classic",
                    "column_norm_spread_ratio_to_classic",
                ],
                effect_responses=[
                    "log10_condition_proxy_ratio_to_classic",
                    "log10_row_norm_spread_ratio_to_classic",
                    "log10_column_norm_spread_ratio_to_classic",
                ],
            )
            attribution = _madnlp_multiconverter_attribution(campaign, cells)
            campaign["factorial_analysis"] = factorial
            campaign["linear_work_attribution"] = attribution
            campaign["campaign_qualified"] =
                get(campaign, "campaign_qualified", false) === true &&
                get(factorial, "analysis_qualified", false) === true &&
                get(attribution, "attribution_qualified", false) === true
            push!(stratum_records, Dict{String,Any}(
                "stratum" => stratum.name,
                "campaign" => campaign,
            ))
        end
        stratified = NLPDiagnostics.scaling_solver_experiment_stratified_campaign_data(
            stratum_records;
            minimum_strata=length(strata),
            minimum_repeats=repeats,
            metadata=Dict(
                "case" => control_case,
                "relative_perturbation" => relative_perturbation,
                "seeds" => seeds,
                "factorial_cell_count" => length(cells),
                "solver" => "MadNLP",
            ),
        )
        contract_gates_passed = all(
            get(record["campaign"]["acdc_scaling_contract_gate"], "passed", false) === true
            for record in stratum_records
        )
        factorial_gates_passed = all(
            get(record["campaign"]["factorial_analysis"], "analysis_qualified", false) === true
            for record in stratum_records
        )
        attribution_gates_passed = all(
            get(record["campaign"]["linear_work_attribution"], "attribution_qualified", false) === true
            for record in stratum_records
        )
        stratified["acdc_scaling_contract_gates_passed"] = contract_gates_passed
        stratified["factorial_analysis_gates_passed"] = factorial_gates_passed
        stratified["linear_work_attribution_gates_passed"] =
            attribution_gates_passed
        stratified["campaign_qualified"] =
            get(stratified, "campaign_qualified", false) === true &&
            contract_gates_passed && factorial_gates_passed &&
            attribution_gates_passed
        push!(case_records, Dict{String,Any}(
            "case" => control_case,
            "campaign" => stratified,
        ))
    end
    qualified = all(
        get(record["campaign"], "campaign_qualified", false) === true
        for record in case_records
    )
    return Dict{String,Any}(
        "schema_version" => "bmopf-acdc-multiconverter-madnlp-study-v1",
        "runner_version" => _ACDC_MULTI_MADNLP_RUNNER_VERSION,
        "available" => true,
        "campaign_qualified" => qualified,
        "case_count" => length(case_records),
        "cases" => case_records,
        "environment" => environment,
        "environment_fingerprint" => environment_fingerprint,
        "factorial_design" => Dict{String,Any}(
            "type" => "full 2^4 two-level factorial",
            "factors" => collect(_ACDC_MULTI_FACTORS),
            "levels" => Dict(
                factor => collect(Float64.(getproperty(levels, Symbol(factor))))
                for factor in _ACDC_MULTI_FACTORS
            ),
            "cell_count" => length(cells),
            "cells" => cells,
            "reference_policy" => first(policies)[1],
            "policy_ranking_performed" => false,
        ),
        "effect_direction_summary" => _acdc_grid_direction_summary(case_records),
        "linear_work_effect_direction_summary" =>
            _madnlp_effect_direction_summary(case_records),
        "qualified_linear_work_effect_direction_summary" =>
            _madnlp_effect_direction_summary(
                case_records; qualified_only=true,
            ),
        "solver_evidence_boundary" => Dict{String,Any}(
            "solver" => "MadNLP",
            "initial_point_geometry_available" => true,
            "primal_iterate_geometry_available" => false,
            "cumulative_factorization_work_available" => true,
            "linear_solver_time_available" => true,
            "factorization_numerics_available" => false,
        ),
        "solver_evidence_matrix" =>
            _acdc_multiconverter_solver_evidence_matrix(),
        "design" => Dict{String,Any}(
            "objective_bearing" => true,
            "converter_count" => 3,
            "dc_topology" => "meshed three-node pole-and-metallic-return",
            "repeats_per_policy_per_stratum" => repeats,
            "native_start_included" => true,
            "perturbed_start_seeds" => seeds,
            "relative_perturbation" => relative_perturbation,
            "native_acdc_contract_required" => true,
            "factorization_work_attribution_required" => true,
            "primal_trajectory_geometry_required" => false,
            "solver" => "MadNLP",
        ),
        "qualification" => Dict{String,Any}(
            "claim" =>
                "qualified matched MadNLP factorization-work evidence on the retained multi-converter factorial campaign",
            "does_not_establish" => [
                "primal-iterate semantic geometry",
                "factorization stability or numerical accuracy",
                "causality between coordinate bases and linear-algebra work",
                "timing portability beyond the retained environment",
            ],
        ),
    )
end

function _compact_acdc_multiconverter_madnlp_campaign(campaign)
    return Dict{String,Any}(
        "schema_version" =>
            "bmopf-acdc-multiconverter-madnlp-study-summary-v1",
        "source_schema_version" => campaign["schema_version"],
        "runner_version" => campaign["runner_version"],
        "available" => campaign["available"],
        "campaign_qualified" => campaign["campaign_qualified"],
        "case_count" => campaign["case_count"],
        "environment_fingerprint" => campaign["environment_fingerprint"],
        "factorial_design" => campaign["factorial_design"],
        "effect_direction_summary" => campaign["effect_direction_summary"],
        "linear_work_effect_direction_summary" =>
            campaign["linear_work_effect_direction_summary"],
        "qualified_linear_work_effect_direction_summary" =>
            campaign["qualified_linear_work_effect_direction_summary"],
        "solver_evidence_boundary" => campaign["solver_evidence_boundary"],
        "solver_evidence_matrix" => campaign["solver_evidence_matrix"],
        "design" => campaign["design"],
        "qualification" => campaign["qualification"],
        "cases" => [
            Dict{String,Any}(
                "case" => record["case"],
                "campaign_qualified" => record["campaign"]["campaign_qualified"],
                "gates" => record["campaign"]["gates"],
                "policies" => record["campaign"]["policies"],
                "metadata" => record["campaign"]["metadata"],
                "acdc_scaling_contract_gates_passed" =>
                    record["campaign"]["acdc_scaling_contract_gates_passed"],
                "factorial_analysis_gates_passed" =>
                    record["campaign"]["factorial_analysis_gates_passed"],
                "linear_work_attribution_gates_passed" =>
                    record["campaign"]["linear_work_attribution_gates_passed"],
                "strata" => [
                    Dict{String,Any}(
                        "stratum" => stratum["stratum"],
                        "campaign_qualified" =>
                            stratum["campaign"]["campaign_qualified"],
                        "gates" => stratum["campaign"]["gates"],
                        "policies" => stratum["campaign"]["policies"],
                        "comparisons" => stratum["campaign"]["comparisons"],
                        "factorial_analysis" =>
                            stratum["campaign"]["factorial_analysis"],
                        "linear_work_attribution" =>
                            stratum["campaign"]["linear_work_attribution"],
                    ) for stratum in record["campaign"]["stratum_records"]
                ],
            ) for record in campaign["cases"]
        ],
    )
end

function acdc_multiconverter_madnlp_main()
    levels = (
        s_ac1=_parse_acdc_grid_levels(
            "NLPDIAGNOSTICS_ACDC_MULTI_MADNLP_S_AC1",
            get(ENV, "NLPDIAGNOSTICS_ACDC_MULTI_MADNLP_S_AC1",
                "10000,1000000"),
        ),
        s_ac2=_parse_acdc_grid_levels(
            "NLPDIAGNOSTICS_ACDC_MULTI_MADNLP_S_AC2",
            get(ENV, "NLPDIAGNOSTICS_ACDC_MULTI_MADNLP_S_AC2",
                "10000,100000"),
        ),
        s_ac3=_parse_acdc_grid_levels(
            "NLPDIAGNOSTICS_ACDC_MULTI_MADNLP_S_AC3",
            get(ENV, "NLPDIAGNOSTICS_ACDC_MULTI_MADNLP_S_AC3",
                "10000,50000"),
        ),
        s_dc=_parse_acdc_grid_levels(
            "NLPDIAGNOSTICS_ACDC_MULTI_MADNLP_S_DC",
            get(ENV, "NLPDIAGNOSTICS_ACDC_MULTI_MADNLP_S_DC",
                "10000,200000"),
        ),
    )
    repeats = _env_int(
        "NLPDIAGNOSTICS_ACDC_MULTI_MADNLP_REPEATS", 2; minimum=2,
    )
    seeds = _parse_seeds(get(
        ENV, "NLPDIAGNOSTICS_ACDC_MULTI_MADNLP_SEEDS", "11",
    ))
    isempty(seeds) && error(
        "NLPDIAGNOSTICS_ACDC_MULTI_MADNLP_SEEDS must contain at least one integer seed",
    )
    relative_perturbation = _env_float(
        "NLPDIAGNOSTICS_ACDC_MULTI_MADNLP_PERTURBATION",
        0.001;
        positive=true,
    )
    max_iter = _env_int(
        "NLPDIAGNOSTICS_ACDC_MULTI_MADNLP_MAX_ITER", 200; minimum=1,
    )
    solver_tolerance = _env_float(
        "NLPDIAGNOSTICS_ACDC_MULTI_MADNLP_TOL", 1.0e-8; positive=true,
    )
    output = abspath(get(
        ENV,
        "NLPDIAGNOSTICS_ACDC_MULTI_MADNLP_OUTPUT",
        joinpath(
            @__DIR__, "..", "work",
            "bmopf-acdc-multiconverter-madnlp-campaign.json",
        ),
    ))
    campaign = run_acdc_multiconverter_madnlp_campaign(;
        levels,
        repeats,
        seeds,
        relative_perturbation,
        max_iter,
        solver_tolerance,
    )
    mkpath(dirname(output))
    write(output, JSON.json(_json_safe(campaign)))
    stem, extension = splitext(output)
    summary_output = stem * "-summary" * extension
    write(
        summary_output,
        JSON.json(_json_safe(
            _compact_acdc_multiconverter_madnlp_campaign(campaign),
        )),
    )
    println("wrote MadNLP multi-converter campaign to $output")
    println("wrote compact MadNLP multi-converter summary to $summary_output")
    println("campaign_qualified=$(campaign["campaign_qualified"])")
    for record in campaign["cases"]
        println(
            "$(record["case"]): qualified=$(record["campaign"]["campaign_qualified"]) " *
            "strata=$(record["campaign"]["stratum_count"])",
        )
    end
end

if abspath(PROGRAM_FILE) == abspath(@__FILE__)
    acdc_multiconverter_madnlp_main()
end
