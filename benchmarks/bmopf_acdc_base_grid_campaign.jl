#!/usr/bin/env julia

"""Run a bounded 2^3 AC/DC power-base allocation campaign.

The three experimental factors are the power-coordinate bases at AC zone 1,
AC zone 2, and the DC network. Every low/high combination is compared with a
classic 1 MVA reference under the qualified matched-run contract. Descriptive
factorial contrasts are retained separately for every controller/start stratum;
they are not combined into a policy score or a global ranking.

Environment controls:

  * `NLPDIAGNOSTICS_ACDC_GRID_S_AC1` (default `10000,1000000` VA)
  * `NLPDIAGNOSTICS_ACDC_GRID_S_AC2` (default `10000,100000` VA)
  * `NLPDIAGNOSTICS_ACDC_GRID_S_DC` (default `10000,200000` W)
  * `NLPDIAGNOSTICS_ACDC_GRID_REPEATS` (default `2`, minimum `2`)
  * `NLPDIAGNOSTICS_ACDC_GRID_SEEDS` (default `11`; native is also run)
  * `NLPDIAGNOSTICS_ACDC_GRID_PERTURBATION` (default `0.001`)
  * `NLPDIAGNOSTICS_ACDC_GRID_MAX_ITER` (default `150`)
  * `NLPDIAGNOSTICS_ACDC_GRID_TOL` (default `1e-8`)
  * `NLPDIAGNOSTICS_ACDC_GRID_OUTPUT` (default under `work/`)
"""

include(joinpath(@__DIR__, "bmopf_acdc_scaling_campaign.jl"))

const _ACDC_GRID_RUNNER_VERSION = "bmopf-acdc-base-grid-campaign-v1"
const _ACDC_GRID_FACTORS = ("s_ac1", "s_ac2", "s_dc")

function _full_factorial_effect_specs(factors)
    names = String.(collect(factors))
    return [
        (
            join((names[index] for index in eachindex(names) if
                mask & (1 << (index - 1)) != 0), ":"),
            Tuple(names[index] for index in eachindex(names) if
                mask & (1 << (index - 1)) != 0),
        ) for mask in 1:(1 << length(names)) - 1
    ]
end

const _ACDC_GRID_EFFECT_SPECS =
    _full_factorial_effect_specs(_ACDC_GRID_FACTORS)

function _validate_acdc_grid_levels(levels)
    for factor in _ACDC_GRID_FACTORS
        values = getproperty(levels, Symbol(factor))
        length(values) == 2 || throw(ArgumentError(
            "$factor must contain exactly two levels",
        ))
        all(value -> isfinite(value) && value > 0, values) ||
            throw(ArgumentError("$factor levels must be finite and positive"))
        values[1] < values[2] || throw(ArgumentError(
            "$factor levels must be strictly increasing (low,high)",
        ))
    end
    return levels
end

function _parse_acdc_grid_levels(name, value)
    tokens = strip.(split(value, ','))
    length(tokens) == 2 || error("$name must contain exactly two numbers")
    levels = Float64[]
    for token in tokens
        parsed = tryparse(Float64, token)
        isnothing(parsed) && error("$name must contain two numeric values")
        push!(levels, parsed)
    end
    all(level -> isfinite(level) && level > 0, levels) ||
        error("$name levels must be finite and positive")
    levels[1] < levels[2] ||
        error("$name levels must be strictly increasing (low,high)")
    return levels
end

function _acdc_grid_policies(levels)
    _validate_acdc_grid_levels(levels)
    policies = Tuple{String,Function}[
        ("classic_1mva", () -> BMOPFTools.OpfScaling(:classic; power_base=1.0e6)),
    ]
    cells = Dict{String,Any}[]
    voltage_bases = Dict("f1" => 230.0, "f2" => 230.0)
    labels = ("low", "high")
    signs = (-1, 1)
    for i1 in 1:2, i2 in 1:2, idc in 1:2
        s_ac1 = Float64(levels.s_ac1[i1])
        s_ac2 = Float64(levels.s_ac2[i2])
        s_dc = Float64(levels.s_dc[idc])
        policy_name = "grid_a1_$(labels[i1])_a2_$(labels[i2])_dc_$(labels[idc])"
        policy_symbol = Symbol(policy_name)
        push!(policies, (
            policy_name,
            () -> BMOPFTools.OpfScaling(
                name=policy_symbol,
                voltage_bases=copy(voltage_bases),
                power_bases=Dict("f1" => s_ac1, "f2" => s_ac2),
                dc_voltage_base=850.0,
                dc_power_base=s_dc,
            ),
        ))
        push!(cells, Dict{String,Any}(
            "policy" => policy_name,
            "levels" => Dict(
                "s_ac1" => labels[i1],
                "s_ac2" => labels[i2],
                "s_dc" => labels[idc],
            ),
            "coded_levels" => Dict(
                "s_ac1" => signs[i1],
                "s_ac2" => signs[i2],
                "s_dc" => signs[idc],
            ),
            "power_bases" => Dict(
                "s_ac1" => s_ac1,
                "s_ac2" => s_ac2,
                "s_dc" => s_dc,
            ),
            "converter_coefficients" => Dict(
                "vsc1_s_ac_over_s_dc" => s_ac1 / s_dc,
                "vsc2_s_ac_over_s_dc" => s_ac2 / s_dc,
            ),
        ))
    end
    return policies, cells
end

function _available_mean(record)
    record isa AbstractDict || return nothing
    get(record, "available", false) === true || return nothing
    value = get(record, "mean", nothing)
    return value isa Real && isfinite(value) ? Float64(value) : nothing
end

function _acdc_grid_cell_responses(campaign, policy)
    policy_summary = get(get(campaign, "policies", Dict()), policy, Dict())
    comparison = get(get(campaign, "comparisons", Dict()), policy, Dict())
    geometry = get(comparison, "geometry_ratio_ranges", Dict())
    condition_ratio = _available_mean(get(geometry, "condition_proxy", Dict()))
    row_ratio = _available_mean(get(geometry, "row_norm_spread", Dict()))
    column_ratio = _available_mean(get(geometry, "column_norm_spread", Dict()))
    return Dict{String,Any}(
        "callback_record_count_mean" => _available_mean(
            get(policy_summary, "record_count_range", Dict()),
        ),
        "line_search_trial_sum_mean" => _available_mean(
            get(policy_summary, "line_search_trial_sum_range", Dict()),
        ),
        "restoration_record_count_mean" => _available_mean(
            get(policy_summary, "restoration_record_count_range", Dict()),
        ),
        "condition_proxy_ratio_to_classic" => condition_ratio,
        "row_norm_spread_ratio_to_classic" => row_ratio,
        "column_norm_spread_ratio_to_classic" => column_ratio,
        "log10_condition_proxy_ratio_to_classic" =>
            condition_ratio isa Real && condition_ratio > 0 ?
                log10(condition_ratio) : nothing,
        "log10_row_norm_spread_ratio_to_classic" =>
            row_ratio isa Real && row_ratio > 0 ? log10(row_ratio) : nothing,
        "log10_column_norm_spread_ratio_to_classic" =>
            column_ratio isa Real && column_ratio > 0 ?
                log10(column_ratio) : nothing,
    )
end

function _acdc_grid_effects(
    cells,
    response_names;
    effect_specs=_ACDC_GRID_EFFECT_SPECS,
)
    effects = Dict{String,Any}()
    denominator = length(cells) / 2
    for response_name in response_names
        values = [get(cell["responses"], response_name, nothing) for cell in cells]
        all(value -> value isa Real && isfinite(value), values) || continue
        response_effects = Dict{String,Any}()
        for (effect_name, factors) in effect_specs
            estimate = sum(
                prod(cell["coded_levels"][factor] for factor in factors) * value
                for (cell, value) in zip(cells, values)
            ) / denominator
            response_effects[effect_name] = Dict{String,Any}(
                "estimate" => estimate,
                "definition" =>
                    "unweighted high-minus-low 2^3 descriptive contrast",
                "cell_count" => length(cells),
            )
        end
        effects[response_name] = response_effects
    end
    return effects
end

function _acdc_grid_factorial_analysis(
    campaign,
    cell_specs;
    factors=_ACDC_GRID_FACTORS,
    effect_specs=_full_factorial_effect_specs(factors),
    schema_version="bmopf-acdc-base-grid-factorial-analysis-v1",
    required_responses=[
        "callback_record_count_mean",
        "line_search_trial_sum_mean",
        "condition_proxy_ratio_to_classic",
        "row_norm_spread_ratio_to_classic",
        "column_norm_spread_ratio_to_classic",
    ],
    effect_responses=[
        "callback_record_count_mean",
        "line_search_trial_sum_mean",
        "restoration_record_count_mean",
        "log10_condition_proxy_ratio_to_classic",
        "log10_row_norm_spread_ratio_to_classic",
        "log10_column_norm_spread_ratio_to_classic",
    ],
)
    cells = Dict{String,Any}[]
    policy_summaries = get(campaign, "policies", Dict())
    comparison_summaries = get(campaign, "comparisons", Dict())
    for spec in cell_specs
        cell = deepcopy(spec)
        policy = cell["policy"]
        cell["responses"] = _acdc_grid_cell_responses(campaign, policy)
        policy_summary = get(policy_summaries, policy, Dict())
        comparison = get(comparison_summaries, policy, Dict())
        cell["qualified"] =
            get(policy_summary, "all_physical_endpoints_accepted", false) === true &&
            get(policy_summary, "all_common_starts_covariant", false) === true &&
            get(policy_summary, "all_native_initializations_covariant", false) === true &&
            get(comparison, "all_qualified", false) === true
        push!(cells, cell)
    end
    policy_ids = string.(getindex.(cells, "policy"))
    expected_cell_count = 1 << length(factors)
    cell_coverage_complete = length(cells) == expected_cell_count &&
        length(unique(policy_ids)) == expected_cell_count &&
        all(policy -> haskey(policy_summaries, policy), policy_ids) &&
        all(policy -> haskey(comparison_summaries, policy), policy_ids)
    response_coverage_complete = all(
        cell -> all(
            response -> get(cell["responses"], response, nothing) isa Real,
            required_responses,
        ),
        cells,
    )
    all_cells_qualified = all(
        get(cell, "qualified", false) === true for cell in cells
    )
    qualified = cell_coverage_complete && response_coverage_complete &&
        all_cells_qualified
    return Dict{String,Any}(
        "schema_version" => schema_version,
        "available" => true,
        "analysis_qualified" => qualified,
        "factor_count" => length(factors),
        "cell_count" => length(cells),
        "reference_policy" => get(campaign, "reference_policy", nothing),
        "cells" => cells,
        "effects" => _acdc_grid_effects(
            cells, effect_responses; effect_specs,
        ),
        "gates" => Dict{String,Any}(
            "complete_2x2x2_cell_coverage" => cell_coverage_complete,
            "complete_two_level_factorial_cell_coverage" =>
                cell_coverage_complete,
            "required_response_coverage_complete" => response_coverage_complete,
            "all_cells_qualified" => all_cells_qualified,
        ),
        "response_semantics" => Dict{String,Any}(
            "required_responses" => collect(required_responses),
            "effect_responses" => collect(effect_responses),
            "solver_work" =>
                "arithmetic replicate means; contrasts have native count units",
            "geometry" =>
                "log10 candidate-to-classic ratios at the common physical start",
            "effects" =>
                "descriptive contrasts within one controller/start stratum",
        ),
        "qualification" => Dict{String,Any}(
            "claim" =>
                "complete qualified two-level factorial descriptive base-allocation contrasts for this retained stratum",
            "does_not_establish" => [
                "statistical significance from two deterministic replicates",
                "causal attribution outside the retained factor levels",
                "a scalar policy ranking",
                "performance portability to another model or solver",
            ],
        ),
    )
end

function _acdc_grid_direction_summary(case_records)
    samples = Dict{Tuple{String,String},Vector{Dict{String,Any}}}()
    for case_record in case_records
        for stratum_record in case_record["campaign"]["stratum_records"]
            analysis = stratum_record["campaign"]["factorial_analysis"]
            for (response, effects) in get(analysis, "effects", Dict())
                for (effect, record) in effects
                    sample = Dict{String,Any}(
                        "case" => case_record["case"],
                        "stratum" => stratum_record["stratum"],
                        "estimate" => record["estimate"],
                    )
                    push!(get!(samples, (response, effect), Dict{String,Any}[]), sample)
                end
            end
        end
    end
    summary = Dict{String,Any}()
    for ((response, effect), records) in sort!(collect(samples); by=first)
        estimates = Float64[record["estimate"] for record in records]
        directions = [
            abs(value) <= 1.0e-12 ? "zero" : value > 0 ? "positive" : "negative"
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

function run_acdc_base_grid_campaign(;
    levels,
    repeats,
    seeds,
    relative_perturbation,
    max_iter,
    solver_tolerance,
    endpoint_absolute_tolerance=0.1,
    endpoint_relative_tolerance=2.0e-5,
    physical_complementarity_tolerance=1.0e-4,
)
    _validate_acdc_grid_levels(levels)
    repeats >= 2 || throw(ArgumentError("repeats must be at least two"))
    isempty(seeds) && throw(ArgumentError(
        "at least one perturbed-start seed is required for stratification",
    ))
    environment = _benchmark_environment()
    environment_fingerprint = _benchmark_environment_fingerprint(environment)
    policies, cells = _acdc_grid_policies(levels)
    case_records = Dict{String,Any}[]
    for (control_case, droop) in (("p-v-control", false), ("droop-v-control", true))
        network = _acdc_objective_fixture(; droop)
        anchor_context = _build_context(
            network, first(policies)[2](); add_objective=true,
        )
        base_point = NLPDiagnostics.bmopf_start_completion_point(
            anchor_context;
            missing_value=0.0,
            label="$control_case-grid-native-start",
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
                runner_version=_ACDC_GRID_RUNNER_VERSION,
            )
            analysis = _acdc_grid_factorial_analysis(campaign, cells)
            campaign["factorial_analysis"] = analysis
            campaign["campaign_qualified"] =
                get(campaign, "campaign_qualified", false) === true &&
                get(analysis, "analysis_qualified", false) === true
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
        stratified["acdc_scaling_contract_gates_passed"] = contract_gates_passed
        stratified["factorial_analysis_gates_passed"] = factorial_gates_passed
        stratified["campaign_qualified"] =
            get(stratified, "campaign_qualified", false) === true &&
            contract_gates_passed && factorial_gates_passed
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
        "schema_version" => "bmopf-acdc-base-grid-study-v1",
        "runner_version" => _ACDC_GRID_RUNNER_VERSION,
        "available" => true,
        "campaign_qualified" => qualified,
        "case_count" => length(case_records),
        "cases" => case_records,
        "environment" => environment,
        "environment_fingerprint" => environment_fingerprint,
        "factorial_design" => Dict{String,Any}(
            "type" => "full 2^3 two-level factorial",
            "factors" => collect(_ACDC_GRID_FACTORS),
            "levels" => Dict(
                "s_ac1" => collect(Float64.(levels.s_ac1)),
                "s_ac2" => collect(Float64.(levels.s_ac2)),
                "s_dc" => collect(Float64.(levels.s_dc)),
            ),
            "cell_count" => length(cells),
            "cells" => cells,
            "reference_policy" => first(policies)[1],
            "policy_ranking_performed" => false,
        ),
        "effect_direction_summary" => _acdc_grid_direction_summary(case_records),
        "design" => Dict{String,Any}(
            "objective_bearing" => true,
            "lossless_converters" => true,
            "reactive_converter_power_fixed" => true,
            "repeats_per_policy_per_stratum" => repeats,
            "native_start_included" => true,
            "perturbed_start_seeds" => seeds,
            "relative_perturbation" => relative_perturbation,
            "controller_modes" => ["P/V", "droop/V"],
            "native_acdc_contract_required" => true,
            "factorial_response_coverage_required" => true,
            "solver" => "Ipopt",
        ),
        "qualification" => Dict{String,Any}(
            "claim" =>
                "qualified within-stratum 2^3 descriptive contrasts for AC/DC power-base allocation on the retained fixture",
            "does_not_establish" => [
                "a best power-base allocation",
                "statistical significance",
                "response monotonicity between or beyond the two retained levels",
                "behavior on larger or lossy AC/DC networks",
                "performance portability to another nonlinear solver",
            ],
        ),
    )
end

function _compact_acdc_base_grid_campaign(campaign)
    return Dict{String,Any}(
        "schema_version" => "bmopf-acdc-base-grid-study-summary-v1",
        "source_schema_version" => campaign["schema_version"],
        "runner_version" => campaign["runner_version"],
        "available" => campaign["available"],
        "campaign_qualified" => campaign["campaign_qualified"],
        "case_count" => campaign["case_count"],
        "environment_fingerprint" => campaign["environment_fingerprint"],
        "factorial_design" => campaign["factorial_design"],
        "effect_direction_summary" => campaign["effect_direction_summary"],
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
                "strata" => [
                    Dict{String,Any}(
                        "stratum" => stratum["stratum"],
                        "campaign_qualified" =>
                            stratum["campaign"]["campaign_qualified"],
                        "gates" => stratum["campaign"]["gates"],
                        "policies" => stratum["campaign"]["policies"],
                        "comparisons" => stratum["campaign"]["comparisons"],
                        "acdc_scaling_contract_gate" =>
                            stratum["campaign"]["acdc_scaling_contract_gate"],
                        "factorial_analysis" =>
                            stratum["campaign"]["factorial_analysis"],
                        "trace_evidence_records" =>
                            _compact_trace_evidence_records(stratum["campaign"]),
                    ) for stratum in record["campaign"]["stratum_records"]
                ],
            ) for record in campaign["cases"]
        ],
    )
end

function acdc_base_grid_main()
    levels = (
        s_ac1=_parse_acdc_grid_levels(
            "NLPDIAGNOSTICS_ACDC_GRID_S_AC1",
            get(ENV, "NLPDIAGNOSTICS_ACDC_GRID_S_AC1", "10000,1000000"),
        ),
        s_ac2=_parse_acdc_grid_levels(
            "NLPDIAGNOSTICS_ACDC_GRID_S_AC2",
            get(ENV, "NLPDIAGNOSTICS_ACDC_GRID_S_AC2", "10000,100000"),
        ),
        s_dc=_parse_acdc_grid_levels(
            "NLPDIAGNOSTICS_ACDC_GRID_S_DC",
            get(ENV, "NLPDIAGNOSTICS_ACDC_GRID_S_DC", "10000,200000"),
        ),
    )
    repeats = _env_int("NLPDIAGNOSTICS_ACDC_GRID_REPEATS", 2; minimum=2)
    seeds = _parse_seeds(get(ENV, "NLPDIAGNOSTICS_ACDC_GRID_SEEDS", "11"))
    isempty(seeds) && error(
        "NLPDIAGNOSTICS_ACDC_GRID_SEEDS must contain at least one integer seed",
    )
    relative_perturbation = _env_float(
        "NLPDIAGNOSTICS_ACDC_GRID_PERTURBATION", 0.001; positive=true,
    )
    max_iter = _env_int("NLPDIAGNOSTICS_ACDC_GRID_MAX_ITER", 150; minimum=1)
    solver_tolerance = _env_float(
        "NLPDIAGNOSTICS_ACDC_GRID_TOL", 1.0e-8; positive=true,
    )
    output = abspath(get(
        ENV,
        "NLPDIAGNOSTICS_ACDC_GRID_OUTPUT",
        joinpath(@__DIR__, "..", "work", "bmopf-acdc-base-grid-campaign.json"),
    ))
    campaign = run_acdc_base_grid_campaign(;
        levels,
        repeats,
        seeds,
        relative_perturbation,
        max_iter,
        solver_tolerance,
    )
    mkpath(dirname(output))
    NLPDiagnosticsBenchmarkCommon.write_json(output, _json_safe(campaign))
    stem, extension = splitext(output)
    summary_output = stem * "-summary" * extension
    NLPDiagnosticsBenchmarkCommon.write_json(
        summary_output, _json_safe(_compact_acdc_base_grid_campaign(campaign)),
    )
    println("wrote AC/DC base-grid campaign to $output")
    println("wrote compact AC/DC base-grid summary to $summary_output")
    println("campaign_qualified=$(campaign["campaign_qualified"])")
    for record in campaign["cases"]
        println(
            "$(record["case"]): qualified=$(record["campaign"]["campaign_qualified"]) " *
            "strata=$(record["campaign"]["stratum_count"])",
        )
    end
end

if abspath(PROGRAM_FILE) == abspath(@__FILE__)
    acdc_base_grid_main()
end
