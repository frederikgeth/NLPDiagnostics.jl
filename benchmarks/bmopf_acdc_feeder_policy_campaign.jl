#!/usr/bin/env julia

"""Run a sparse-only, feeder-embedded AC/DC scaling campaign.

The ENWL corpus contains real unbalanced feeders but no independent AC/DC
coordinate zones. This runner therefore replaces AC zone 2 of the retained
three-converter P/V fixture with an unmodified ENWL feeder. The feeder keeps its
source, loads, lines, controllers, and IBRs; the zone-2 converter is attached at
the feeder source bus. Five mechanism-distinct policies are retained:

  * classic 1 MVA coordinates;
  * the all-low factorial anchor;
  * AC-zone-2-high only;
  * all four factors high; and
  * the qualified AC1/AC2/DC interaction control.

Dense rank and singular-spectrum work is disabled unconditionally. Ipopt
supplies bounded primal-trajectory family geometry; MadNLP supplies cumulative
linear-algebra work. Public and explicitly completed MadNLP multiplier
representatives remain separate evidence.
"""

include(joinpath(
    @__DIR__, "bmopf_acdc_multiconverter_madnlp_campaign.jl",
))

using SHA

const _ACDC_FEEDER_RUNNER_VERSION =
    "bmopf-acdc-feeder-policy-campaign-v1"
const _ACDC_FEEDER_DEFAULT_CASES = [
    "ENWLsnapshots/30bus_LN/30bus_LN_t01_0800.bmopf.json",
    "ENWLsnapshots/30bus_LG/30bus_LG_t01_0800.bmopf.json",
]
const _ACDC_FEEDER_POLICY_SPECS = [
    (
        name="factorial_all_low",
        s_ac1=10_000.0,
        s_ac2=10_000.0,
        s_ac3=10_000.0,
        s_dc=10_000.0,
        role="factorial anchor",
    ),
    (
        name="factorial_a2_high_only",
        s_ac1=10_000.0,
        s_ac2=100_000.0,
        s_ac3=10_000.0,
        s_dc=10_000.0,
        role="qualified AC-zone-2 main-effect candidate",
    ),
    (
        name="factorial_all_high",
        s_ac1=1_000_000.0,
        s_ac2=100_000.0,
        s_ac3=50_000.0,
        s_dc=200_000.0,
        role="joint high-level control",
    ),
    (
        name="factorial_a1_a2_dc_high",
        s_ac1=1_000_000.0,
        s_ac2=100_000.0,
        s_ac3=10_000.0,
        s_dc=200_000.0,
        role="AC1/AC2/DC interaction control",
    ),
]

function _acdc_feeder_selected_cases(root, value)
    cases = filter(!isempty, strip.(split(value, ',')))
    isempty(cases) && (cases = copy(_ACDC_FEEDER_DEFAULT_CASES))
    selected = Dict{String,Any}[]
    root_path = realpath(root)
    for relative in cases
        isabspath(relative) && error(
            "feeder case selections must be relative to the benchmark root",
        )
        endswith(lowercase(relative), ".bmopf.json") || error(
            "feeder case must end in .bmopf.json: $relative",
        )
        path = normpath(joinpath(root_path, relative))
        startswith(path, root_path * Base.Filesystem.path_separator) || error(
            "feeder case escapes the benchmark root: $relative",
        )
        isfile(path) || error("selected feeder case is missing: $path")
        push!(selected, Dict{String,Any}(
            "relative_path" => relative,
            "path" => path,
            "name" => replace(basename(path), ".bmopf.json" => ""),
            "sha256" => bytes2hex(SHA.sha256(read(path))),
        ))
    end
    return selected
end

function _acdc_feeder_selected_solvers(value)
    names = unique(lowercase.(filter(!isempty, strip.(split(value, ',')))))
    isempty(names) && error("at least one feeder campaign solver is required")
    unknown = setdiff(names, ["ipopt", "madnlp"])
    isempty(unknown) || error(
        "unsupported feeder campaign solvers: $(join(unknown, ", "))",
    )
    return names
end

function _acdc_feeder_merge_family!(network, feeder, family)
    source = get(feeder, family, nothing)
    source isa AbstractDict || return
    target = get!(network, family, Dict{String,Any}())
    target isa AbstractDict || error(
        "target component family $family is not a dictionary",
    )
    conflicts = intersect(Set(string.(keys(target))), Set(string.(keys(source))))
    isempty(conflicts) || error(
        "component identifiers collide while embedding feeder family $family: " *
        join(sort!(collect(conflicts)), ", "),
    )
    for (identifier, component) in source
        target[string(identifier)] = deepcopy(component)
    end
end

function _acdc_feeder_namespaced(feeder)
    result = deepcopy(feeder)
    prefix = "feeder__"
    identifier_maps = Dict{String,Dict{String,String}}()
    for family in (
        "bus", "linecode", "line", "switch", "load", "shunt",
        "generator", "ibr", "control_profile", "voltage_source",
        "transformer", "grounding",
    )
        components = get(result, family, nothing)
        components isa AbstractDict || continue
        mapping = Dict(
            string(identifier) => prefix * string(identifier)
            for identifier in keys(components)
        )
        identifier_maps[family] = mapping
        result[family] = Dict{String,Any}(
            mapping[string(identifier)] => component
            for (identifier, component) in components
        )
    end
    bus_map = get(identifier_maps, "bus", Dict{String,String}())
    linecode_map = get(identifier_maps, "linecode", Dict{String,String}())
    profile_map = get(
        identifier_maps, "control_profile", Dict{String,String}(),
    )
    for family in keys(identifier_maps)
        for component in values(result[family])
            component isa AbstractDict || continue
            for field in ("bus", "bus_from", "bus_to")
                value = get(component, field, nothing)
                value isa AbstractString && haskey(bus_map, value) &&
                    (component[field] = bus_map[value])
            end
            linecode = get(component, "linecode", nothing)
            linecode isa AbstractString && haskey(linecode_map, linecode) &&
                (component["linecode"] = linecode_map[linecode])
            profile = get(component, "control_profile", nothing)
            profile isa AbstractString && haskey(profile_map, profile) &&
                (component["control_profile"] = profile_map[profile])
        end
    end
    return result
end

function _acdc_feeder_fixture(path)
    feeder = _acdc_feeder_namespaced(BMOPFTools.parse_bmopf(path))
    network = _acdc_multiconverter_fixture(; droop=false)
    sources = get(feeder, "voltage_source", Dict())
    source_buses = unique(string(source["bus"]) for source in values(sources))
    length(source_buses) == 1 || error(
        "the embedded feeder must declare exactly one voltage-source bus",
    )
    source_bus = only(source_buses)
    feeder_buses = sort!(string.(collect(keys(feeder["bus"]))))
    source_bus in feeder_buses || error(
        "the feeder voltage-source bus is absent from the bus table",
    )
    terminals = string.(feeder["bus"][source_bus]["terminal_names"])
    "n" in terminals || error(
        "the feeder source bus must expose terminal 'n' for the retained converter",
    )
    phase_terminals = filter(!=("n"), terminals)
    isempty(phase_terminals) && error(
        "the feeder source bus has no phase terminal",
    )

    delete!(network["bus"], "f2")
    delete!(network["voltage_source"], "s2")
    delete!(network["load"], "load2")
    converter = network["ibr"]["vsc2"]
    converter["bus"] = source_bus
    converter["terminal_map"] = [first(phase_terminals), "n"]

    for family in (
        "bus", "linecode", "line", "switch", "load", "shunt",
        "generator", "ibr", "control_profile", "voltage_source",
        "transformer", "grounding",
    )
        _acdc_feeder_merge_family!(network, feeder, family)
    end
    return (
        network=network,
        feeder_bus_ids=feeder_buses,
        feeder_source_bus=source_bus,
        feeder_component_counts=Dict{String,Int}(
            family => length(get(feeder, family, Dict()))
            for family in (
                "bus", "line", "load", "ibr", "voltage_source",
            )
        ),
    )
end

function _acdc_feeder_policy_factories(network, feeder_bus_ids)
    probe = _build_context(
        network,
        BMOPFTools.ClassicPerUnitScaling(1.0e6);
        add_objective=true,
    )
    bases = BMOPFTools.opf_bases(probe)
    isnothing(bases) && error("classic feeder probe did not publish OPF bases")
    voltage_bases = Dict(
        string(bus) => Float64(value) for (bus, value) in bases.v_base
    )
    expected_buses = Set(vcat(["f1", "f3"], feeder_bus_ids))
    Set(keys(voltage_bases)) == expected_buses || error(
        "classic voltage-base coverage does not match the embedded AC buses",
    )
    policies = Tuple{String,Function}[
        ("classic_1mva", () -> BMOPFTools.ClassicPerUnitScaling(1.0e6)),
    ]
    descriptors = Dict{String,Any}[
        Dict{String,Any}(
            "policy" => "classic_1mva",
            "role" => "external classic per-unit reference",
            "kind" => "classic",
            "uniform_power_base" => 1.0e6,
        ),
    ]
    for spec in _ACDC_FEEDER_POLICY_SPECS
        power_bases = Dict{String,Float64}(
            bus => spec.s_ac2 for bus in feeder_bus_ids
        )
        power_bases["f1"] = spec.s_ac1
        power_bases["f3"] = spec.s_ac3
        name = spec.name
        symbol = Symbol(name)
        push!(policies, (
            name,
            () -> BMOPFTools.ZonePerUnitScaling(
                name=symbol,
                voltage_bases=copy(voltage_bases),
                power_bases=copy(power_bases),
                dc_voltage_base=1000.0,
                dc_power_base=spec.s_dc,
            ),
        ))
        push!(descriptors, Dict{String,Any}(
            "policy" => name,
            "role" => spec.role,
            "kind" => "selected_factorial_cell",
            "power_bases" => Dict(
                "s_ac1" => spec.s_ac1,
                "s_ac2_feeder_zone" => spec.s_ac2,
                "s_ac3" => spec.s_ac3,
                "s_dc" => spec.s_dc,
            ),
            "converter_coefficients" => Dict(
                "vsc1_s_ac_over_s_dc" => spec.s_ac1 / spec.s_dc,
                "vsc2_s_ac_over_s_dc" => spec.s_ac2 / spec.s_dc,
                "vsc3_s_ac_over_s_dc" => spec.s_ac3 / spec.s_dc,
            ),
        ))
    end
    return policies, descriptors
end

function _acdc_feeder_sparse_budget(
    evaluation;
    maximum_variables,
    maximum_constraints,
    maximum_jacobian_entries,
    maximum_trace_jacobian_entry_evaluations,
    policy_count,
    stratum_count,
    repeats,
    trace_geometry_max_points,
)
    variables = length(evaluation.point.variables)
    constraints = length(evaluation.constraint_sources)
    entries = length(evaluation.jacobian_entries)
    trace_upper_bound = policy_count * stratum_count * repeats *
        trace_geometry_max_points * entries
    gates = Dict{String,Any}(
        "variable_budget_passed" => variables <= maximum_variables,
        "constraint_budget_passed" => constraints <= maximum_constraints,
        "stored_jacobian_entry_budget_passed" =>
            entries <= maximum_jacobian_entries,
        "trace_jacobian_entry_evaluation_budget_passed" =>
            trace_upper_bound <= maximum_trace_jacobian_entry_evaluations,
        "dense_decomposition_disabled" => true,
    )
    return Dict{String,Any}(
        "schema_version" => "bmopf-acdc-feeder-sparse-budget-v1",
        "passed" => all(value === true for value in values(gates)),
        "gates" => gates,
        "observed" => Dict(
            "variable_count" => variables,
            "constraint_count" => constraints,
            "stored_jacobian_entry_count" => entries,
            "dense_matrix_entry_count" => variables * constraints,
            "trace_jacobian_entry_evaluation_upper_bound" => trace_upper_bound,
        ),
        "limits" => Dict(
            "maximum_variables" => maximum_variables,
            "maximum_constraints" => maximum_constraints,
            "maximum_jacobian_entries" => maximum_jacobian_entries,
            "maximum_trace_jacobian_entry_evaluations" =>
                maximum_trace_jacobian_entry_evaluations,
            "max_dense_entries" => 0,
            "trace_geometry_max_points" => trace_geometry_max_points,
        ),
        "qualification" => Dict{String,Any}(
            "claim" =>
                "pre-solve sparse-work admission for the bounded feeder experiment",
            "does_not_establish" => [
                "peak solver memory",
                "sparse factorization fill or stability",
                "wall-time portability",
            ],
        ),
    )
end

function _acdc_feeder_madnlp_attribution(campaign)
    records = [
        _madnlp_run_telemetry_record(run)
        for run in get(campaign, "run_records", Any[])
    ]
    grouped = Dict{String,Vector{Dict{String,Any}}}()
    for record in records
        push!(
            get!(grouped, string(record["policy"]), Dict{String,Any}[]),
            record,
        )
    end
    policies = Dict{String,Any}(
        policy => _madnlp_policy_telemetry_summary(policy_records)
        for (policy, policy_records) in sort!(collect(grouped); by=first)
    )
    coverage = !isempty(records) && all(
        get(record, "coverage_complete", false) === true for record in records
    )
    unsupported_truthful = all(
        get(record, "inertia_available", true) === false &&
        get(record, "pivot_statistics_available", true) === false &&
        get(record, "fill_ratio_available", true) === false &&
        get(record, "backward_error_available", true) === false
        for record in records
    )
    return Dict{String,Any}(
        "schema_version" => "bmopf-acdc-feeder-madnlp-attribution-v1",
        "available" => !isempty(records),
        "attribution_qualified" => coverage && unsupported_truthful,
        "run_count" => length(records),
        "records" => records,
        "policies" => policies,
        "gates" => Dict{String,Any}(
            "cumulative_counter_coverage_complete" => coverage,
            "unsupported_factorization_numerics_truthfully_unavailable" =>
                unsupported_truthful,
        ),
        "fixed_variable_dual_completion" => Dict{String,Any}(
            "available_count" => count(
                record -> get(
                    record, "fixed_variable_dual_completion_available", false,
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
        ),
        "qualification" => Dict{String,Any}(
            "claim" =>
                "complete MadNLP cumulative linear-work evidence for every selected feeder policy run",
            "does_not_establish" => [
                "primal-iterate geometry",
                "factorization accuracy, inertia, pivots, or fill",
                "causality between a power base and work",
            ],
        ),
    )
end

function _acdc_feeder_policy_responses(campaign, solver_name)
    responses = Dict{String,Any}()
    madnlp_policies = get(
        get(campaign, "linear_work_attribution", Dict()),
        "policies",
        Dict(),
    )
    for (policy, summary) in get(campaign, "policies", Dict())
        record = Dict{String,Any}(
            "callback_record_count_mean" =>
                get(get(summary, "record_count_range", Dict()), "mean", nothing),
            "line_search_trial_sum_mean" => get(
                get(summary, "line_search_trial_sum_range", Dict()),
                "mean",
                nothing,
            ),
            "all_physical_endpoints_accepted" =>
                get(summary, "all_physical_endpoints_accepted", false),
        )
        if lowercase(solver_name) == "madnlp"
            work = get(madnlp_policies, policy, Dict())
            for (field, key) in (
                ("factorization_count_mean", "factorization_count"),
                ("backsolve_count_mean", "backsolve_count"),
                ("linear_solver_time_seconds_mean", "linear_solver_time_seconds"),
                ("jacobian_evaluation_count_mean", "jacobian_evaluation_count"),
                ("hessian_evaluation_count_mean", "hessian_evaluation_count"),
            )
                record[field] = get(get(work, key, Dict()), "mean", nothing)
            end
        else
            regularization = Dict{String,Any}[]
            for run in get(campaign, "run_records", Any[])
                get(run, "policy", nothing) == policy || continue
                push!(regularization, _acdc_multi_regularization_summary(
                    get(run, "artifact", Dict()),
                ))
            end
            positive = Float64[
                item["positive_record_count"] for item in regularization
                if get(item, "coverage_complete", false) === true
            ]
            record["positive_regularization_record_count_mean"] =
                isempty(positive) ? nothing : sum(positive) / length(positive)
        end
        responses[policy] = record
    end
    return responses
end

function _acdc_feeder_selected_contrasts(responses)
    reference_name = "factorial_all_low"
    reference = get(responses, reference_name, Dict())
    contrasts = Dict{String,Any}()
    for candidate_name in (
        "factorial_a2_high_only",
        "factorial_all_high",
        "factorial_a1_a2_dc_high",
        "classic_1mva",
    )
        candidate = get(responses, candidate_name, Dict())
        fields = sort!(collect(union(keys(reference), keys(candidate))))
        effects = Dict{String,Any}()
        for field in fields
            reference_value = get(reference, field, nothing)
            candidate_value = get(candidate, field, nothing)
            if reference_value isa Real && candidate_value isa Real
                difference = Float64(candidate_value - reference_value)
                effects[field] = Dict{String,Any}(
                    "reference" => reference_value,
                    "candidate" => candidate_value,
                    "candidate_minus_all_low" => difference,
                    "direction" => abs(difference) <= 1.0e-12 ? "zero" :
                        difference > 0 ? "positive" : "negative",
                )
            end
        end
        contrasts[candidate_name] = Dict{String,Any}(
            "reference_policy" => reference_name,
            "candidate_policy" => candidate_name,
            "effects" => effects,
        )
    end
    return contrasts
end

function _acdc_feeder_compact_campaign_record(campaign)
    return Dict{String,Any}(
        "campaign_qualified" => campaign["campaign_qualified"],
        "gates" => campaign["gates"],
        "policies" => campaign["policies"],
        "policy_responses" => campaign["policy_responses"],
        "selected_contrasts" => campaign["selected_contrasts"],
        "acdc_scaling_contract_gate" => campaign["acdc_scaling_contract_gate"],
        "attribution" => get(
            campaign,
            "trajectory_attribution",
            get(campaign, "linear_work_attribution", Dict()),
        ),
    )
end

function _acdc_feeder_compact_stratum(stratum)
    return merge(
        Dict{String,Any}("stratum" => stratum["stratum"]),
        _acdc_feeder_compact_campaign_record(stratum["campaign"]),
    )
end

function _acdc_feeder_compact_stratified_campaign(campaign)
    return Dict{String,Any}(
        string(key) => key == "stratum_records" ? [
            Dict{String,Any}(
                "stratum" => stratum["stratum"],
                "campaign" => _acdc_feeder_compact_campaign_record(
                    stratum["campaign"],
                ),
            )
            for stratum in value
        ] : value
        for (key, value) in campaign
    )
end

function _acdc_feeder_write_checkpoint(path, payload)
    path isa AbstractString || return
    mkpath(dirname(path))
    temporary_path = path * ".tmp"
    write(temporary_path, JSON.json(_json_safe(payload)))
    mv(temporary_path, path; force=true)
    return
end

function run_acdc_feeder_policy_campaign(;
    root,
    cases,
    solvers,
    repeats,
    seeds,
    relative_perturbation,
    max_iter,
    solver_tolerance,
    endpoint_absolute_tolerance=0.2,
    endpoint_relative_tolerance=3.0e-5,
    physical_complementarity_tolerance=2.0e-4,
    trace_geometry_max_points=6,
    maximum_variables=3_000,
    maximum_constraints=4_000,
    maximum_jacobian_entries=100_000,
    maximum_trace_jacobian_entry_evaluations=5_000_000,
    checkpoint_path=nothing,
)
    repeats >= 2 || throw(ArgumentError("repeats must be at least two"))
    isempty(seeds) && throw(ArgumentError(
        "at least one perturbed-start seed is required",
    ))
    environment = _benchmark_environment()
    environment_fingerprint = _benchmark_environment_fingerprint(environment)
    case_records = Dict{String,Any}[]
    policy_design = nothing
    for case_spec in cases
        fixture = _acdc_feeder_fixture(case_spec["path"])
        policies, case_policy_design = _acdc_feeder_policy_factories(
            fixture.network, fixture.feeder_bus_ids,
        )
        isnothing(policy_design) && (policy_design = case_policy_design)
        policy_design == case_policy_design || error(
            "selected policy design changed between feeder cases",
        )
        solver_records = Dict{String,Any}[]
        start_fingerprints = Dict{String,Dict{String,String}}()
        case_budget = nothing
        for solver_key in solvers
            is_madnlp = solver_key == "madnlp"
            optimizer = is_madnlp ? MadNLP.Optimizer : Ipopt.Optimizer
            solver_symbol = is_madnlp ? :madnlp : :ipopt
            solver_name = is_madnlp ? "MadNLP" : "Ipopt"
            anchor_context = _build_context(
                fixture.network,
                first(policies)[2]();
                add_objective=true,
                optimizer,
            )
            base_point = NLPDiagnostics.bmopf_start_completion_point(
                anchor_context;
                missing_value=0.0,
                label="$(case_spec["name"])-native-start",
            )
            anchor_model = BMOPFTools.opf_model(anchor_context)
            strata = [(name="native", point=base_point)]
            append!(strata, [(
                name="nearby-seed-$seed",
                point=_safe_perturbed_point(
                    anchor_model, base_point, seed, relative_perturbation,
                ),
            ) for seed in seeds])
            anchor_evaluation = NLPDiagnostics.evaluate_numerical(
                JuMP.backend(anchor_model), base_point,
            )
            budget = _acdc_feeder_sparse_budget(
                anchor_evaluation;
                maximum_variables,
                maximum_constraints,
                maximum_jacobian_entries,
                maximum_trace_jacobian_entry_evaluations,
                policy_count=length(policies),
                stratum_count=length(strata),
                repeats,
                trace_geometry_max_points,
            )
            isnothing(case_budget) && (case_budget = budget)
            budget["passed"] || begin
                push!(solver_records, Dict{String,Any}(
                    "solver" => solver_name,
                    "available" => false,
                    "campaign_qualified" => false,
                    "reason" => "sparse-work admission budget failed",
                    "sparse_budget" => budget,
                ))
                continue
            end
            fingerprints = Dict{String,String}()
            stratum_records = Dict{String,Any}[]
            for stratum in strata
                evaluation = NLPDiagnostics.evaluate_numerical(
                    JuMP.backend(anchor_model), stratum.point,
                )
                fingerprints[stratum.name] =
                    NLPDiagnostics.evaluation_point_fingerprint(stratum.point)
                campaign = _acdc_campaign_for_stratum(
                    fixture.network,
                    policies,
                    case_spec["name"],
                    stratum.name,
                    anchor_context,
                    evaluation,
                    environment_fingerprint;
                    repeats,
                    max_iter,
                    solver_tolerance,
                    endpoint_absolute_tolerance,
                    endpoint_relative_tolerance,
                    physical_complementarity_tolerance,
                    runner_version=_ACDC_FEEDER_RUNNER_VERSION,
                    optimizer,
                    solver=solver_symbol,
                    solver_name,
                    capture_points=!is_madnlp,
                    trace_geometry=!is_madnlp,
                    trace_geometry_max_points,
                    complete_fixed_variable_duals=is_madnlp,
                    max_dense_entries=0,
                )
                if is_madnlp
                    attribution = _acdc_feeder_madnlp_attribution(campaign)
                    campaign["linear_work_attribution"] = attribution
                else
                    attribution = _acdc_multiconverter_attribution(campaign)
                    campaign["trajectory_attribution"] = attribution
                end
                campaign["campaign_qualified"] =
                    get(campaign, "campaign_qualified", false) === true &&
                    get(attribution, "attribution_qualified", false) === true
                responses = _acdc_feeder_policy_responses(campaign, solver_name)
                campaign["policy_responses"] = responses
                campaign["selected_contrasts"] =
                    _acdc_feeder_selected_contrasts(responses)
                push!(stratum_records, Dict{String,Any}(
                    "stratum" => stratum.name,
                    "campaign" => campaign,
                ))
                _acdc_feeder_write_checkpoint(
                    checkpoint_path,
                    Dict{String,Any}(
                        "schema_version" =>
                            "bmopf-acdc-feeder-policy-checkpoint-v1",
                        "runner_version" => _ACDC_FEEDER_RUNNER_VERSION,
                        "status" => "stratum_complete",
                        "case" => case_spec["name"],
                        "solver" => solver_name,
                        "completed_stratum_count_for_solver" =>
                            length(stratum_records),
                        "stratum_records" => [
                            _acdc_feeder_compact_stratum(record)
                            for record in stratum_records
                        ],
                        "environment_fingerprint" =>
                            environment_fingerprint,
                    ),
                )
            end
            start_fingerprints[solver_name] = fingerprints
            stratified =
                NLPDiagnostics.scaling_solver_experiment_stratified_campaign_data(
                    stratum_records;
                    minimum_strata=length(strata),
                    minimum_repeats=repeats,
                    metadata=Dict(
                        "case" => case_spec["name"],
                        "solver" => solver_name,
                        "relative_perturbation" => relative_perturbation,
                        "seeds" => seeds,
                        "max_dense_entries" => 0,
                        "sparse_budget_passed" => true,
                    ),
                )
            attribution_gates = all(
                get(record["campaign"], "campaign_qualified", false) === true
                for record in stratum_records
            )
            stratified["campaign_qualified"] =
                get(stratified, "campaign_qualified", false) === true &&
                attribution_gates
            compact_stratified =
                _acdc_feeder_compact_stratified_campaign(stratified)
            push!(solver_records, Dict{String,Any}(
                "solver" => solver_name,
                "available" => true,
                "campaign_qualified" =>
                    compact_stratified["campaign_qualified"],
                "sparse_budget" => budget,
                "campaign" => compact_stratified,
            ))
            _acdc_feeder_write_checkpoint(
                checkpoint_path,
                Dict{String,Any}(
                    "schema_version" =>
                        "bmopf-acdc-feeder-policy-checkpoint-v1",
                    "runner_version" => _ACDC_FEEDER_RUNNER_VERSION,
                    "status" => "solver_complete",
                    "case" => case_spec["name"],
                    "completed_solver_count_for_case" =>
                        length(solver_records),
                    "solver_records" => solver_records,
                    "environment_fingerprint" => environment_fingerprint,
                ),
            )
        end
        solver_start_sets = collect(values(start_fingerprints))
        cross_solver_start_gate = length(solver_start_sets) <= 1 || all(
            fingerprints == first(solver_start_sets)
            for fingerprints in solver_start_sets[2:end]
        )
        all_solver_campaigns_qualified = length(solver_records) == length(solvers) &&
            all(
                get(record, "campaign_qualified", false) === true
                for record in solver_records
            )
        push!(case_records, Dict{String,Any}(
            "case" => case_spec["name"],
            "source" => case_spec,
            "feeder_embedding" => Dict{String,Any}(
                "feeder_source_bus" => fixture.feeder_source_bus,
                "feeder_bus_count" => length(fixture.feeder_bus_ids),
                "feeder_component_counts" => fixture.feeder_component_counts,
                "embedding" =>
                    "unmodified feeder retained as AC zone 2; vsc2 attached at its source bus",
            ),
            "sparse_budget" => case_budget,
            "solver_start_fingerprints" => start_fingerprints,
            "cross_solver_start_gate_passed" => cross_solver_start_gate,
            "solver_records" => solver_records,
            "campaign_qualified" => all_solver_campaigns_qualified &&
                cross_solver_start_gate,
        ))
        _acdc_feeder_write_checkpoint(
            checkpoint_path,
            Dict{String,Any}(
                "schema_version" =>
                    "bmopf-acdc-feeder-policy-checkpoint-v1",
                "runner_version" => _ACDC_FEEDER_RUNNER_VERSION,
                "status" => "case_complete",
                "completed_case_count" => length(case_records),
                "cases" => case_records,
                "environment_fingerprint" => environment_fingerprint,
            ),
        )
    end
    qualified = !isempty(case_records) && all(
        get(record, "campaign_qualified", false) === true
        for record in case_records
    )
    return Dict{String,Any}(
        "schema_version" => "bmopf-acdc-feeder-policy-study-v1",
        "runner_version" => _ACDC_FEEDER_RUNNER_VERSION,
        "available" => true,
        "campaign_qualified" => qualified,
        "case_count" => length(case_records),
        "cases" => case_records,
        "environment" => environment,
        "environment_fingerprint" => environment_fingerprint,
        "policy_design" => something(policy_design, Dict{String,Any}[]),
        "design" => Dict{String,Any}(
            "controller_case" => "P/V only",
            "feeder_embedding_zone" => "AC zone 2",
            "repeats_per_policy_per_stratum" => repeats,
            "native_start_included" => true,
            "perturbed_start_seeds" => seeds,
            "relative_perturbation" => relative_perturbation,
            "solvers" => solvers,
            "dense_decompositions_enabled" => false,
            "max_dense_entries" => 0,
            "policy_ranking_performed" => false,
            "selected_policy_count" => length(something(
                policy_design, Dict{String,Any}[],
            )),
        ),
        "qualification" => Dict{String,Any}(
            "claim" =>
                "bounded cross-solver scaling evidence after embedding real unbalanced feeder equations in the qualified AC-zone-2 mechanism",
            "does_not_establish" => [
                "performance on a native multi-zone feeder dataset",
                "droop-controller robustness",
                "automatic or globally optimal base selection",
                "factorization accuracy, fill, inertia, or pivot quality",
                "timing portability beyond the retained environment",
            ],
        ),
    )
end

function _compact_acdc_feeder_policy_campaign(campaign)
    return Dict{String,Any}(
        "schema_version" => "bmopf-acdc-feeder-policy-study-summary-v1",
        "source_schema_version" => campaign["schema_version"],
        "runner_version" => campaign["runner_version"],
        "available" => campaign["available"],
        "campaign_qualified" => campaign["campaign_qualified"],
        "case_count" => campaign["case_count"],
        "environment_fingerprint" => campaign["environment_fingerprint"],
        "policy_design" => campaign["policy_design"],
        "design" => campaign["design"],
        "qualification" => campaign["qualification"],
        "cases" => [
            Dict{String,Any}(
                "case" => record["case"],
                "source" => record["source"],
                "feeder_embedding" => record["feeder_embedding"],
                "sparse_budget" => record["sparse_budget"],
                "cross_solver_start_gate_passed" =>
                    record["cross_solver_start_gate_passed"],
                "campaign_qualified" => record["campaign_qualified"],
                "solver_records" => [
                    Dict{String,Any}(
                        "solver" => solver["solver"],
                        "available" => solver["available"],
                        "campaign_qualified" => solver["campaign_qualified"],
                        "sparse_budget" => solver["sparse_budget"],
                        "strata" => get(solver, "available", false) ? [
                            _acdc_feeder_compact_stratum(stratum)
                            for stratum in solver["campaign"]["stratum_records"]
                        ] : Any[],
                    ) for solver in record["solver_records"]
                ],
            ) for record in campaign["cases"]
        ],
    )
end

function acdc_feeder_policy_main()
    root = get(ENV, "NLPDIAGNOSTICS_BMOPF_BENCHMARK_ROOT", "")
    isempty(root) && error(
        "Set NLPDIAGNOSTICS_BMOPF_BENCHMARK_ROOT to BMOPFDraftData/benchmarks",
    )
    isdir(root) || error("benchmark root does not exist: $root")
    cases = _acdc_feeder_selected_cases(
        root, get(ENV, "NLPDIAGNOSTICS_ACDC_FEEDER_CASES", ""),
    )
    solvers = _acdc_feeder_selected_solvers(get(
        ENV, "NLPDIAGNOSTICS_ACDC_FEEDER_SOLVERS", "ipopt,madnlp",
    ))
    repeats = _env_int("NLPDIAGNOSTICS_ACDC_FEEDER_REPEATS", 2; minimum=2)
    seeds = _parse_seeds(get(
        ENV, "NLPDIAGNOSTICS_ACDC_FEEDER_SEEDS", "11",
    ))
    relative_perturbation = _env_float(
        "NLPDIAGNOSTICS_ACDC_FEEDER_PERTURBATION", 0.001; positive=true,
    )
    max_iter = _env_int(
        "NLPDIAGNOSTICS_ACDC_FEEDER_MAX_ITER", 200; minimum=1,
    )
    solver_tolerance = _env_float(
        "NLPDIAGNOSTICS_ACDC_FEEDER_TOL", 1.0e-8; positive=true,
    )
    output = abspath(get(
        ENV,
        "NLPDIAGNOSTICS_ACDC_FEEDER_OUTPUT",
        joinpath(
            @__DIR__, "..", "work", "bmopf-acdc-feeder-policy-campaign.json",
        ),
    ))
    campaign = run_acdc_feeder_policy_campaign(;
        root,
        cases,
        solvers,
        repeats,
        seeds,
        relative_perturbation,
        max_iter,
        solver_tolerance,
        trace_geometry_max_points=_env_int(
            "NLPDIAGNOSTICS_ACDC_FEEDER_TRACE_MAX_POINTS", 6; minimum=1,
        ),
        maximum_variables=_env_int(
            "NLPDIAGNOSTICS_ACDC_FEEDER_MAX_VARIABLES", 3_000; minimum=1,
        ),
        maximum_constraints=_env_int(
            "NLPDIAGNOSTICS_ACDC_FEEDER_MAX_CONSTRAINTS", 4_000; minimum=1,
        ),
        maximum_jacobian_entries=_env_int(
            "NLPDIAGNOSTICS_ACDC_FEEDER_MAX_JACOBIAN_ENTRIES",
            100_000;
            minimum=1,
        ),
        maximum_trace_jacobian_entry_evaluations=_env_int(
            "NLPDIAGNOSTICS_ACDC_FEEDER_MAX_TRACE_JACOBIAN_ENTRY_EVALUATIONS",
            5_000_000;
            minimum=1,
        ),
        checkpoint_path=output * ".checkpoint.json",
    )
    mkpath(dirname(output))
    write(output, JSON.json(_json_safe(campaign)))
    stem, extension = splitext(output)
    summary_output = stem * "-summary" * extension
    write(
        summary_output,
        JSON.json(_json_safe(_compact_acdc_feeder_policy_campaign(campaign))),
    )
    println("wrote feeder policy campaign to $output")
    println("wrote compact feeder policy summary to $summary_output")
    println("campaign_qualified=$(campaign["campaign_qualified"])")
    for record in campaign["cases"]
        println(
            "$(record["case"]): qualified=$(record["campaign_qualified"]) " *
            "buses=$(record["feeder_embedding"]["feeder_bus_count"])",
        )
    end
end

if abspath(PROGRAM_FILE) == abspath(@__FILE__)
    acdc_feeder_policy_main()
end
