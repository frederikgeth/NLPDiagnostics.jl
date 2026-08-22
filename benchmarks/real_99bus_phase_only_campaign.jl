#!/usr/bin/env julia

"""Run bounded matched reference and phase-only Ipopt solves on real ENWL snapshots."""

using BMOPFTools
using Ipopt
using JSON
using JuMP
using NLPDiagnostics
using Random
using SHA
import MathOptInterface as MOI

const DEFAULT_ROOT = normpath(joinpath(@__DIR__, "..", "..", "BMOPFDraftData", "benchmarks"))
const SELECTED_SNAPSHOTS = [
    "ENWLsnapshots/99bus_LN/99bus_LN_t01_0800.bmopf.json",
    "ENWLsnapshots/99bus_LN/99bus_LN_t13_1400.bmopf.json",
    "ENWLsnapshots/99bus_LN/99bus_LN_t25_2000.bmopf.json",
    "ENWLsnapshots/99bus_LG/99bus_LG_t01_0800.bmopf.json",
    "ENWLsnapshots/99bus_LG/99bus_LG_t13_1400.bmopf.json",
    "ENWLsnapshots/99bus_LG/99bus_LG_t25_2000.bmopf.json",
]

function set_start_values!(model, variables, values)
    length(variables) == length(values) || error("start vector does not match model variables")
    for (variable, value) in zip(variables, values)
        MOI.set(JuMP.backend(model), MOI.VariablePrimalStart(), variable, value)
    end
end

function apply_ipopt_options!(model; max_iter, ipopt_options=Dict{String,Any}())
    JuMP.set_optimizer_attribute(model, "max_iter", max_iter)
    for (name, value) in ipopt_options
        JuMP.set_optimizer_attribute(model, String(name), value)
    end
    return model
end

function campaign_perturbed_point(context, point; seed, relative_size)
    model = BMOPFTools.opf_model(context)
    rng = MersenneTwister(seed)
    values = copy(Float64.(point.values))
    for (index, variable) in enumerate(point.variables)
        reference = JuMP.VariableRef(model, variable)
        JuMP.is_fixed(reference) && continue
        scale = max(abs(values[index]), 1.0)
        proposed = values[index] + relative_size * scale * randn(rng)
        lower = JuMP.has_lower_bound(reference) ? JuMP.lower_bound(reference) : -Inf
        upper = JuMP.has_upper_bound(reference) ? JuMP.upper_bound(reference) : Inf
        if isfinite(lower) && isfinite(upper) && lower == upper
            values[index] = lower
            continue
        end
        width = upper - lower
        margin = isfinite(width) ? min(0.01 * width, 1.0e-8 * max(abs(lower), abs(upper), 1.0)) : 0.0
        isfinite(lower) && (proposed = max(proposed, lower + margin))
        isfinite(upper) && (proposed = min(proposed, upper - margin))
        values[index] = proposed
    end
    return NLPDiagnostics.EvaluationPoint(
        point.variables,
        values;
        label="real-99bus-phase-only-campaign-perturbed-start-$seed",
        provenance=NLPDiagnostics.EvaluationPointProvenance(
            NLPDiagnostics.PerturbedPoint;
            source="deterministic bounded perturbation of completed start",
            complete=true,
            metadata=Dict(
                "seed" => seed,
                "relative_size" => relative_size,
                "base_fingerprint" => NLPDiagnostics.evaluation_point_fingerprint(point),
            ),
        ),
    )
end

function campaign_initialization_point(context, policy)
    policy in ("completed", "bmopf", "zero", "perturbed") || error(
        "NLPDIAGNOSTICS_REAL_99BUS_INITIALIZATION_POLICY must be completed, bmopf, zero, or perturbed",
    )
    completed = NLPDiagnostics.bmopf_start_completion_point(
        context;
        missing_value=0.0,
        label="real-99bus-phase-only-campaign-completed-start",
    )
    policy == "completed" && return completed
    policy == "zero" && return NLPDiagnostics.EvaluationPoint(
        completed.variables,
        zeros(length(completed.values));
        label="real-99bus-phase-only-campaign-zero-start",
    )
    if policy == "perturbed"
        seed = parse(Int, get(ENV, "NLPDIAGNOSTICS_REAL_99BUS_START_PERTURBATION_SEED", "11"))
        relative_size = parse(Float64, get(
            ENV, "NLPDIAGNOSTICS_REAL_99BUS_START_PERTURBATION_RELATIVE_SIZE", "1.0e-3",
        ))
        return campaign_perturbed_point(
            context,
            completed;
            seed,
            relative_size,
        )
    end
    native = NLPDiagnostics.bmopf_initialization_point(context)
    native isa NLPDiagnostics.EvaluationPoint || error(
        "BMOPFTools native initialization point is unavailable",
    )
    return native
end

function solve_reference(context, point; max_iter, ipopt_options=Dict{String,Any}())
    model = BMOPFTools.opf_model(context)
    set_start_values!(model, point.variables, point.values)
    apply_ipopt_options!(model; max_iter, ipopt_options)
    try
        JuMP.optimize!(model)
        return Dict{String,Any}(
            "available" => true,
            "model" => model,
            "solver_run_completed" => true,
            "termination_status" => string(JuMP.termination_status(model)),
            "primal_status" => string(JuMP.primal_status(model)),
            "objective_value" => try Float64(JuMP.objective_value(model)) catch; nothing end,
        )
    catch error
        return Dict{String,Any}(
            "available" => false,
            "solver_run_completed" => false,
            "reason" => "reference optimizer failed",
            "error" => sprint(showerror, error),
        )
    end
end

function native_baseline_comparison(reference, candidate; margin)
    reference_max = get(reference, "maximum_violation", nothing)
    candidate_max = get(candidate, "maximum_violation", nothing)
    comparable = reference_max isa Real && candidate_max isa Real &&
        isfinite(reference_max) && isfinite(candidate_max)
    threshold = comparable ? Float64(reference_max) + margin : nothing
    reference_by_block = get(reference, "maximum_violation_by_block", Dict())
    candidate_by_block = get(candidate, "maximum_violation_by_block", Dict())
    common_blocks = intersect(Set(keys(reference_by_block)), Set(keys(candidate_by_block)))
    block_deltas = Dict{String,Float64}(
        string(block) => Float64(candidate_by_block[block]) -
            Float64(reference_by_block[block])
        for block in common_blocks
    )
    maximum_absolute_block_delta = isempty(block_deltas) ? nothing : maximum(abs, values(block_deltas))
    worst_block_deltas = sort!(collect(block_deltas); by=pair -> abs(pair.second), rev=true)
    return Dict{String,Any}(
        "available" => comparable && length(common_blocks) == length(reference_by_block) &&
            length(common_blocks) == length(candidate_by_block),
        "common_block_count" => length(common_blocks),
        "reference_block_count" => length(reference_by_block),
        "candidate_block_count" => length(candidate_by_block),
        "reference_maximum_violation" => comparable ? Float64(reference_max) : nothing,
        "candidate_maximum_violation" => comparable ? Float64(candidate_max) : nothing,
        "absolute_margin" => margin,
        "candidate_within_native_margin" => comparable &&
            Float64(candidate_max) <= threshold &&
            all(delta -> delta <= margin, values(block_deltas)),
        "maximum_absolute_block_delta" => maximum_absolute_block_delta,
        "worst_block_deltas" => [
            Dict("block_id" => string(pair.first), "delta" => pair.second)
            for pair in Iterators.take(worst_block_deltas, 5)
        ],
        "qualification" => Dict{String,Any}(
            "claim" => "candidate endpoint residual scale is no worse than the matched native endpoint by the declared margin",
            "absolute_physical_acceptance" => false,
        ),
    )
end

function solver_floor_tolerances(reference_feasibility; model_tolerance)
    scales = get(reference_feasibility, "physical_scale_by_quantity", Dict())
    return Dict(
        string(quantity) => model_tolerance * Float64(scale)
        for (quantity, scale) in scales
        if scale isa Real && isfinite(scale) && scale > 0
    )
end

function physical_feasibility(
    context,
    evaluation;
    tolerance,
    absolute_tolerances=nothing,
    quantity_tolerances=nothing,
)
    map = NLPDiagnostics.bmopf_diagonal_scaling_map(context, evaluation)
    map["available"] || return Dict{String,Any}(
        "available" => false,
        "acceptance_passed" => nothing,
        "reason" => "the physical scaling map is unavailable",
    )
    quantities = unique(string.(map["constraint_quantities"]))
    report = !isnothing(absolute_tolerances) ?
        NLPDiagnostics.bmopf_physical_feasibility_report(
            context,
            evaluation;
            absolute_tolerances,
        ) : !isnothing(quantity_tolerances) ?
        NLPDiagnostics.bmopf_physical_feasibility_report(
            context,
            evaluation;
            quantity_absolute_tolerances=quantity_tolerances,
        ) :
        NLPDiagnostics.bmopf_physical_feasibility_report(
            context,
            evaluation;
            quantity_absolute_tolerances=Dict(quantity => tolerance for quantity in quantities),
        )
    residual_pairs = collect(pairs(get(report, "residuals", Dict())))
    residuals = [pair.second for pair in residual_pairs]
    worst = sort(residual_pairs; by=pair -> get(pair.second, "violation", 0.0), rev=true)
    scale_by_block = Dict(
        string(map["map"].constraint_keys[index]) =>
            Float64(map["map"].constraint_scales[index])
        for index in eachindex(map["map"].constraint_keys)
    )
    scale_by_quantity = Dict{String,Float64}()
    for (quantity, scale) in zip(map["constraint_quantities"], map["map"].constraint_scales)
        quantity_key = string(quantity)
        scale_value = Float64(scale)
        scale_by_quantity[quantity_key] = max(
            get(scale_by_quantity, quantity_key, 0.0), scale_value,
        )
    end
    by_block = Dict{String,Float64}()
    model_by_block = Dict{String,Float64}()
    for record in residuals
        block_id = string(get(record, "block_id", ""))
        violation = Float64(get(record, "violation", 0.0))
        by_block[block_id] = max(get(by_block, block_id, 0.0), violation)
        scale = get(scale_by_block, block_id, nothing)
        if scale isa Real && scale > 0
            model_by_block[block_id] = max(
                get(model_by_block, block_id, 0.0), violation / scale,
            )
        end
    end
    worst_records = [
        Dict(
            "residual_key" => string(pair.first),
            "id" => get(pair.second, "id", nothing),
            "block_id" => get(pair.second, "block_id", nothing),
            "physical_quantity" => get(pair.second, "physical_quantity", nothing),
            "physical_scale" => get(
                scale_by_block,
                string(get(pair.second, "block_id", "")),
                nothing,
            ),
            "violation" => get(pair.second, "violation", nothing),
            "model_violation" => begin
                block_id = string(get(pair.second, "block_id", ""))
                scale = get(scale_by_block, block_id, nothing)
                scale isa Real && scale > 0 ?
                    get(pair.second, "violation", 0.0) / scale : nothing
            end,
            "passed" => get(pair.second, "passed", nothing),
        ) for pair in Iterators.take(worst, 5)
    ]
    return Dict{String,Any}(
        "available" => get(report, "available", false),
        "acceptance_passed" => get(report, "acceptance_passed", nothing),
        "tolerance_coverage_complete" => get(report, "tolerance_coverage_complete", false),
        "residual_count" => length(residuals),
        "passed_residual_count" => count(record -> get(record, "passed", false) === true, residuals),
        "maximum_violation" => isempty(residuals) ? nothing : maximum(
            get(record, "violation", 0.0) for record in residuals),
        "maximum_violation_by_block" => by_block,
        "maximum_model_violation_by_block" => model_by_block,
        "physical_scale_by_block" => scale_by_block,
        "physical_scale_by_quantity" => scale_by_quantity,
        "worst_residuals" => worst_records,
    )
end

function physical_kkt(context, model, evaluation, quantity_tolerances)
    try
        return NLPDiagnostics.bmopf_physical_solver_kkt_report(
            context,
            model,
            evaluation;
            quantity_feasibility_absolute_tolerances=quantity_tolerances,
            stationarity_default_absolute_tolerance=1.0e-5,
            dual_default_absolute_tolerance=1.0e-5,
            complementarity_default_absolute_tolerance=1.0e-5,
        )
    catch error
        return Dict{String,Any}(
            "report_version" => "bmopf-physical-solver-kkt-v1",
            "available" => false,
            "acceptance_passed" => nothing,
            "reason" => "the physical solver-KKT report failed",
            "error" => sprint(showerror, error),
        )
    end
end

function solver_floor_complementarity_calibration(kkt; model_tolerance)
    records = get(
        get(get(kkt, "semantic_attribution", Dict()), "complementarity", Dict()),
        "records", Dict(),
    )
    isempty(records) && return Dict{String,Any}(
        "available" => false,
        "acceptance_passed" => nothing,
        "reason" => "semantic complementarity records are unavailable",
    )
    by_family = Dict{String,Dict{String,Any}}()
    for (key, raw_record) in records
        record = raw_record isa AbstractDict ? raw_record : Dict{String,Any}()
        family = string(get(record, "constraint_family", "unknown"))
        summary = get!(by_family, family) do
            Dict{String,Any}(
                "side_count" => 0,
                "maximum_model_multiplier" => 0.0,
                "maximum_absolute_model_slack" => 0.0,
                "maximum_complementarity_residual" => 0.0,
                "failed_strict_side_count" => 0,
                "failed_strict_sides" => String[],
            )
        end
        summary["side_count"] += 1
        summary["maximum_model_multiplier"] = max(
            summary["maximum_model_multiplier"],
            abs(Float64(get(record, "model_multiplier", 0.0))),
        )
        summary["maximum_absolute_model_slack"] = max(
            summary["maximum_absolute_model_slack"],
            abs(Float64(get(record, "model_slack", 0.0))),
        )
        residual = Float64(get(record, "complementarity_residual", 0.0))
        summary["maximum_complementarity_residual"] = max(
            summary["maximum_complementarity_residual"], residual,
        )
        get(record, "passed", false) === true && continue
        summary["failed_strict_side_count"] += 1
        push!(summary["failed_strict_sides"], string(key))
    end
    barrier_candidates = [
        summary["maximum_complementarity_residual"] for summary in values(by_family)
        if summary["maximum_model_multiplier"] <= 1.0
    ]
    observed_barrier_floor = isempty(barrier_candidates) ?
        Float64(model_tolerance) : maximum(barrier_candidates)
    calibrated_passed = true
    for summary in values(by_family)
        envelope = observed_barrier_floor + Float64(model_tolerance) *
            summary["maximum_model_multiplier"]
        summary["solver_floor_complementarity_tolerance"] = envelope
        summary["solver_floor_envelope_formula"] =
            "observed barrier floor + model_tolerance * maximum absolute model multiplier"
        summary["solver_floor_passed"] =
            summary["maximum_complementarity_residual"] <= envelope
        calibrated_passed &= summary["solver_floor_passed"]
    end
    return Dict{String,Any}(
        "available" => true,
        "acceptance_passed" => calibrated_passed,
        "model_feasibility_tolerance" => Float64(model_tolerance),
        "observed_barrier_floor" => observed_barrier_floor,
        "family_count" => length(by_family),
        "families" => by_family,
        "qualification" => Dict{String,Any}(
            "claim" => "compound complementarity is within a declared solver-floor envelope",
            "strict_physical_kkt_remains_separate" => true,
            "does_not_establish" => [
                "absolute physical complementarity acceptance",
                "solver stopping-test equivalence",
                "optimality",
            ],
        ),
    )
end

function attach_solver_floor_complementarity!(kkt; model_tolerance)
    calibration = solver_floor_complementarity_calibration(
        kkt; model_tolerance,
    )
    kkt["solver_floor_complementarity"] = calibration
    return kkt
end

function physical_kkt_tolerance_sensitivity(
    kkt;
    complementarity_tolerances=(1.0e-5, 1.1e-5, 1.2e-5, 2.0e-5, 1.0e-4),
)
    get(kkt, "available", false) === true || return Dict{String,Any}(
        "available" => false,
        "reason" => "the physical solver-KKT report is unavailable",
    )
    complementarity = get(kkt, "complementarity", Dict())
    sides = get(complementarity, "sides", Dict())
    semantic_records = get(
        get(get(kkt, "semantic_attribution", Dict()), "complementarity", Dict()),
        "records", Dict(),
    )
    residuals = Float64[
        get(side, "complementarity_residual", NaN)
        for side in values(sides)
    ]
    finite = !isempty(residuals) && all(isfinite, residuals)
    primal_and_stationarity_passed = all(
        get(get(kkt, component, Dict()), "acceptance_passed", false) === true
        for component in ("primal_feasibility", "stationarity")
    )
    dual_finite = all(
        isfinite(Float64(get(side, "dual_violation", NaN)))
        for side in values(sides)
    )
    dual_feasibility_passed = dual_finite && all(
        abs(Float64(get(side, "dual_violation", NaN))) <=
            Float64(get(side, "dual_absolute_tolerance", Inf))
        for side in values(sides)
    )
    base_gates = primal_and_stationarity_passed && dual_feasibility_passed
    policies = Dict{String,Any}()
    for raw_tolerance in complementarity_tolerances
        tolerance = Float64(raw_tolerance)
        failed_sides = [
            string(key) for (key, side) in pairs(sides)
            if !isfinite(Float64(get(side, "complementarity_residual", NaN))) ||
                Float64(get(side, "complementarity_residual", NaN)) > tolerance
        ]
        failed_families = sort!(unique([
            string(get(get(semantic_records, key, Dict()), "constraint_family", "unknown"))
            for key in failed_sides
        ]))
        policy_key = string(tolerance)
        policies[policy_key] = Dict{String,Any}(
            "complementarity_absolute_tolerance" => tolerance,
            "failed_side_count" => length(failed_sides),
            "failed_sides" => failed_sides,
            "failed_constraint_families" => failed_families,
            "compound_acceptance_passed" => base_gates && finite && isempty(failed_sides),
        )
    end
    return Dict{String,Any}(
        "available" => true,
        "base_gates_passed" => base_gates,
        "primal_and_stationarity_passed" => primal_and_stationarity_passed,
        "dual_feasibility_passed" => dual_feasibility_passed,
        "finite" => finite,
        "side_count" => length(sides),
        "maximum_complementarity_residual" => finite ? maximum(residuals) : nothing,
        "minimum_observed_complementarity_tolerance" => finite ? maximum(residuals) : nothing,
        "policies" => policies,
        "qualification" => Dict{String,Any}(
            "claim" => "compound KKT acceptance sensitivity to the declared physical complementarity tolerance",
            "does_not_establish" => [
                "absolute physical correctness",
                "solver stopping-test equivalence",
                "optimality beyond the declared KKT gates",
            ],
        ),
    )
end

function attach_physical_kkt_tolerance_sensitivity!(kkt)
    kkt["tolerance_sensitivity"] = physical_kkt_tolerance_sensitivity(kkt)
    return kkt
end

function complementarity_scaling_audit(kkt)
    records = get(
        get(get(kkt, "semantic_attribution", Dict()), "complementarity", Dict()),
        "records", Dict(),
    )
    isempty(records) && return Dict{String,Any}(
        "available" => false,
        "scaling_relation_passed" => nothing,
        "reason" => "semantic complementarity records are unavailable",
    )
    by_family = Dict{String,Dict{String,Any}}()
    maximum_relative_product_error = 0.0
    maximum_relative_slack_error = 0.0
    maximum_relative_multiplier_error = 0.0
    finite = true
    for (key, raw_record) in records
        record = raw_record isa AbstractDict ? raw_record : Dict{String,Any}()
        family = string(get(record, "constraint_family", "unknown"))
        summary = get!(by_family, family) do
            Dict{String,Any}(
                "side_count" => 0,
                "maximum_relative_product_error" => 0.0,
                "maximum_relative_slack_error" => 0.0,
                "maximum_relative_multiplier_error" => 0.0,
                "failed_strict_side_count" => 0,
                "failed_strict_sides" => String[],
            )
        end
        summary["side_count"] += 1
        model_multiplier = Float64(get(record, "model_multiplier", NaN))
        model_slack = Float64(get(record, "model_slack", NaN))
        physical_multiplier = Float64(get(record, "physical_multiplier", NaN))
        physical_slack = Float64(get(record, "physical_slack", NaN))
        residual_scale = Float64(get(record, "residual_scale", NaN))
        values_are_finite = all(isfinite, (
            model_multiplier, model_slack, physical_multiplier,
            physical_slack, residual_scale,
        )) && residual_scale > 0
        finite &= values_are_finite
        if values_are_finite
            model_product = abs(model_multiplier * model_slack)
            physical_product = abs(physical_multiplier * physical_slack)
            relative_product_error = abs(physical_product - model_product) /
                max(1.0, model_product, physical_product)
            relative_slack_error = abs(physical_slack - model_slack * residual_scale) /
                max(1.0, abs(physical_slack))
            relative_multiplier_error = abs(physical_multiplier - model_multiplier / residual_scale) /
                max(1.0, abs(physical_multiplier))
            summary["maximum_relative_product_error"] = max(
                summary["maximum_relative_product_error"], relative_product_error,
            )
            summary["maximum_relative_slack_error"] = max(
                summary["maximum_relative_slack_error"], relative_slack_error,
            )
            summary["maximum_relative_multiplier_error"] = max(
                summary["maximum_relative_multiplier_error"], relative_multiplier_error,
            )
            maximum_relative_product_error = max(
                maximum_relative_product_error, relative_product_error,
            )
            maximum_relative_slack_error = max(
                maximum_relative_slack_error, relative_slack_error,
            )
            maximum_relative_multiplier_error = max(
                maximum_relative_multiplier_error, relative_multiplier_error,
            )
        end
        if get(record, "passed", false) !== true
            summary["failed_strict_side_count"] += 1
            push!(summary["failed_strict_sides"], string(key))
        end
    end
    relation_tolerance = 1.0e-12
    return Dict{String,Any}(
        "available" => true,
        "finite" => finite,
        "record_count" => length(records),
        "maximum_relative_product_error" => maximum_relative_product_error,
        "maximum_relative_slack_error" => maximum_relative_slack_error,
        "maximum_relative_multiplier_error" => maximum_relative_multiplier_error,
        "relation_tolerance" => relation_tolerance,
        "scaling_relation_passed" => finite &&
            maximum_relative_product_error <= relation_tolerance &&
            maximum_relative_slack_error <= relation_tolerance &&
            maximum_relative_multiplier_error <= relation_tolerance,
        "families" => by_family,
        "qualification" => Dict{String,Any}(
            "claim" => "physical/model complementarity products and scalar-side scaling relations agree",
            "does_not_establish" => [
                "absolute physical feasibility",
                "solver optimality",
                "correctness of the underlying physical residual model",
            ],
        ),
    )
end

function attach_complementarity_scaling_audit!(kkt)
    kkt["complementarity_scaling_audit"] = complementarity_scaling_audit(kkt)
    return kkt
end

function run_snapshot(
    root,
    relative;
    angle,
    max_iter,
    endpoint_tolerance,
    baseline_margin,
    model_feasibility_tolerance,
    ipopt_options=Dict{String,Any}(),
    initialization_policy="completed",
)
    path = joinpath(root, relative)
    try
        network = BMOPFTools.parse_bmopf(path)
        context = BMOPFTools.build_opf_model(
            deepcopy(network);
            optimizer=Ipopt.Optimizer,
            add_objective=true,
        )
        BMOPFTools.enforce_kcl!(context)
        point = campaign_initialization_point(context, initialization_policy)
        evaluation = NLPDiagnostics.evaluate_numerical(
            JuMP.backend(BMOPFTools.opf_model(context)),
            point,
        )
        plan = NLPDiagnostics.bmopf_phase_only_transform_plan(
            context,
            evaluation;
            angle,
            max_dense_entries=0,
        )
        reference = solve_reference(context, point; max_iter, ipopt_options)
        reference_summary = Dict{String,Any}(
            "available" => get(reference, "available", false),
            "solver_run_completed" => get(reference, "solver_run_completed", false),
            "termination_status" => get(reference, "termination_status", nothing),
            "primal_status" => get(reference, "primal_status", nothing),
            "objective_value" => get(reference, "objective_value", nothing),
            "error" => get(reference, "error", nothing),
        )
        get(reference, "available", false) === true || return Dict{String,Any}(
            "snapshot" => relative,
            "available" => false,
            "reference" => reference_summary,
            "error" => "reference endpoint is unavailable",
        )
        reference_point = NLPDiagnostics.solver_result_point(
            reference["model"];
            label="real-99bus-reference-endpoint",
        )
        reference_evaluation = NLPDiagnostics.evaluate_numerical(
            JuMP.backend(reference["model"]), reference_point,
        )
        reference_feasibility = physical_feasibility(
            context,
            reference_evaluation;
            tolerance=endpoint_tolerance,
        )
        calibrated_tolerances = solver_floor_tolerances(
            reference_feasibility;
            model_tolerance=model_feasibility_tolerance,
        )
        reference_calibrated_feasibility = physical_feasibility(
            context,
            reference_evaluation;
            tolerance=endpoint_tolerance,
            quantity_tolerances=calibrated_tolerances,
        )
        reference_kkt = physical_kkt(
            context,
            reference["model"],
            reference_evaluation,
            calibrated_tolerances,
        )
        attach_solver_floor_complementarity!(
            reference_kkt; model_tolerance=model_feasibility_tolerance,
        )
        attach_physical_kkt_tolerance_sensitivity!(reference_kkt)
        attach_complementarity_scaling_audit!(reference_kkt)
        candidate_model = JuMP.Model(Ipopt.Optimizer)
        apply_ipopt_options!(candidate_model; max_iter, ipopt_options)
        phase_only = NLPDiagnostics.bmopf_phase_only_solve_model(
            context,
            evaluation;
            plan,
            optimizer_model=candidate_model,
            optimize=true,
        )
        endpoint = NLPDiagnostics.bmopf_phase_only_endpoint(
            context,
            evaluation;
            solved=phase_only,
            plan,
        )
        phase_only_feasibility = get(endpoint, "available", false) === true ?
            physical_feasibility(
                context,
                endpoint["endpoint_evaluation"];
                tolerance=endpoint_tolerance,
            ) : Dict{String,Any}(
                "available" => false,
                "acceptance_passed" => nothing,
                "reason" => "the source-coordinate phase-only endpoint was unavailable",
            )
        phase_only_calibrated_feasibility = get(endpoint, "available", false) === true ?
            physical_feasibility(
                context,
                endpoint["endpoint_evaluation"];
                tolerance=endpoint_tolerance,
                quantity_tolerances=calibrated_tolerances,
            ) : Dict{String,Any}(
                "available" => false,
                "acceptance_passed" => nothing,
                "reason" => "the source-coordinate phase-only endpoint was unavailable",
            )
        baseline_comparison = native_baseline_comparison(
            reference_feasibility,
            phase_only_feasibility;
            margin=baseline_margin,
        )
        phase_only_kkt = get(endpoint, "available", false) === true ?
            NLPDiagnostics.bmopf_phase_only_physical_solver_kkt_report(
                context,
                endpoint["endpoint_evaluation"],
                phase_only,
                endpoint;
                quantity_feasibility_absolute_tolerances=calibrated_tolerances,
                stationarity_default_absolute_tolerance=1.0e-5,
                dual_default_absolute_tolerance=1.0e-5,
                complementarity_default_absolute_tolerance=1.0e-5,
            ) : Dict{String,Any}(
                "available" => false,
                "acceptance_passed" => nothing,
                "reason" => "the source-coordinate phase-only endpoint was unavailable",
            )
        attach_solver_floor_complementarity!(
            phase_only_kkt; model_tolerance=model_feasibility_tolerance,
        )
        attach_physical_kkt_tolerance_sensitivity!(phase_only_kkt)
        attach_complementarity_scaling_audit!(phase_only_kkt)
        phase_only_covariance = get(endpoint, "available", false) === true ?
            NLPDiagnostics.bmopf_phase_only_covariance_report(
                context,
                endpoint["endpoint_evaluation"],
                phase_only,
                endpoint;
                absolute_tolerance=1.0e-8,
                relative_tolerance=1.0e-7,
                max_dense_entries=0,
            ) : Dict{String,Any}(
                "available" => false,
                "equivalence_gate_passed" => nothing,
                "reason" => "the source-coordinate phase-only endpoint was unavailable",
            )
        return Dict{String,Any}(
            "available" => true,
            "snapshot" => relative,
            "sha256" => bytes2hex(SHA.sha256(read(path))),
            "angle" => angle,
            "variable_count" => length(evaluation.point.variables),
            "constraint_count" => length(evaluation.constraint_sources),
            "rotated_variable_block_count" => plan["rotated_variable_block_count"],
            "intervention_classification" => plan["intervention"]["classification"],
            "reference" => reference_summary,
            "reference_physical_feasibility" => reference_feasibility,
            "reference_solver_floor_calibrated_feasibility" => reference_calibrated_feasibility,
            "reference_physical_solver_kkt" => reference_kkt,
            "phase_only" => Dict(
                "available" => get(phase_only, "available", false),
                "model_attached" => get(phase_only, "model_attached", false),
                "solver_run_completed" => get(phase_only, "solver_run_completed", false),
                "termination_status" => get(phase_only, "termination_status", nothing),
                "primal_status" => get(phase_only, "primal_status", nothing),
                "objective_value" => get(phase_only, "objective_value", nothing),
                "model_rebuilt" => get(get(phase_only, "rebuild", Dict()), "model_rebuilt", false),
                "start_values_copied" => get(get(phase_only, "rebuild", Dict()), "start_values_copied", false),
                "user_defined_function_count" => get(get(phase_only, "rebuild", Dict()), "user_defined_function_count", nothing),
                "error" => get(phase_only, "error", nothing),
                "endpoint_recovered" => get(endpoint, "available", false),
                "physical_feasibility" => phase_only_feasibility,
                "solver_floor_calibrated_feasibility" => phase_only_calibrated_feasibility,
                "solver_floor_tolerance_policy" => Dict(
                    "model_feasibility_tolerance" => model_feasibility_tolerance,
                    "physical_tolerance_formula" => "model_feasibility_tolerance * declared physical scale",
                    "quantity_absolute_tolerances" => calibrated_tolerances,
                    "absolute_physical_claim" => false,
                ),
                "physical_solver_kkt" => phase_only_kkt,
                "covariance" => phase_only_covariance,
                "native_baseline_comparison" => baseline_comparison,
            ),
            "qualification" => Dict(
                "physical_endpoint_validation" => false,
                "solver_campaign_ready" => false,
            ),
        )
    catch error
        return Dict{String,Any}(
            "snapshot" => relative,
            "available" => false,
            "error" => sprint(showerror, error),
        )
    end
end

function run_campaign()
    root = abspath(get(ENV, "NLPDIAGNOSTICS_REAL_99BUS_ROOT", DEFAULT_ROOT))
    isdir(root) || error("real 99-bus benchmark root does not exist: $root")
    max_iter = parse(Int, get(ENV, "NLPDIAGNOSTICS_REAL_99BUS_MAX_ITER", "40"))
    angle = parse(Float64, get(ENV, "NLPDIAGNOSTICS_REAL_99BUS_PHASE_ANGLE", "0.01"))
    endpoint_tolerance = parse(Float64, get(
        ENV, "NLPDIAGNOSTICS_REAL_99BUS_ENDPOINT_TOLERANCE", "1.0e-6",
    ))
    baseline_margin = parse(Float64, get(
        ENV, "NLPDIAGNOSTICS_REAL_99BUS_BASELINE_MARGIN", "1.0e-8",
    ))
    model_feasibility_tolerance = parse(Float64, get(
        ENV, "NLPDIAGNOSTICS_REAL_99BUS_MODEL_FEASIBILITY_TOLERANCE", "1.0e-8",
    ))
    ipopt_options = Dict{String,Any}()
    for (environment_name, option_name, parser) in [
        ("NLPDIAGNOSTICS_REAL_99BUS_IPOPT_TOL", "tol", x -> parse(Float64, x)),
        ("NLPDIAGNOSTICS_REAL_99BUS_IPOPT_ACCEPTABLE_TOL", "acceptable_tol", x -> parse(Float64, x)),
        ("NLPDIAGNOSTICS_REAL_99BUS_IPOPT_ACCEPTABLE_ITER", "acceptable_iter", x -> parse(Int, x)),
    ]
        raw = get(ENV, environment_name, "")
        isempty(raw) || (ipopt_options[option_name] = parser(raw))
    end
    for (environment_name, option_name) in [
        ("NLPDIAGNOSTICS_REAL_99BUS_IPOPT_MU_STRATEGY", "mu_strategy"),
        ("NLPDIAGNOSTICS_REAL_99BUS_IPOPT_NLP_SCALING_METHOD", "nlp_scaling_method"),
    ]
        raw = get(ENV, environment_name, "")
        isempty(raw) || (ipopt_options[option_name] = raw)
    end
    initialization_policy = lowercase(strip(get(
        ENV, "NLPDIAGNOSTICS_REAL_99BUS_INITIALIZATION_POLICY", "completed",
    )))
    start_perturbation_seed = parse(Int, get(
        ENV, "NLPDIAGNOSTICS_REAL_99BUS_START_PERTURBATION_SEED", "11",
    ))
    start_perturbation_relative_size = parse(Float64, get(
        ENV, "NLPDIAGNOSTICS_REAL_99BUS_START_PERTURBATION_RELATIVE_SIZE", "1.0e-3",
    ))
    runs = [run_snapshot(
        root,
        relative;
        angle,
        max_iter,
        endpoint_tolerance,
        baseline_margin,
        model_feasibility_tolerance,
        ipopt_options,
        initialization_policy,
    ) for relative in SELECTED_SNAPSHOTS]
    solved = [
        run for run in runs
        if get(get(run, "phase_only", Dict()), "solver_run_completed", false) === true
    ]
    locally_solved = [
        run for run in solved
        if get(get(run, "phase_only", Dict()), "termination_status", nothing) == "LOCALLY_SOLVED"
    ]
    reference_physical = [
        run for run in runs
        if get(get(run, "reference_physical_feasibility", Dict()), "acceptance_passed", false) === true
    ]
    phase_only_physical = [
        run for run in runs
        if get(get(get(run, "phase_only", Dict()), "physical_feasibility", Dict()), "acceptance_passed", false) === true
    ]
    phase_only_solver_floor_calibrated = [
        run for run in runs
        if get(get(get(run, "phase_only", Dict()), "solver_floor_calibrated_feasibility", Dict()), "acceptance_passed", false) === true
    ]
    baseline_comparable = [
        run for run in runs
        if get(get(get(run, "phase_only", Dict()), "native_baseline_comparison", Dict()), "available", false) === true
    ]
    baseline_passed = [
        run for run in baseline_comparable
        if get(get(get(run, "phase_only", Dict()), "native_baseline_comparison", Dict()), "candidate_within_native_margin", false) === true
    ]
    reference_kkt_available = [
        run for run in runs
        if get(get(run, "reference_physical_solver_kkt", Dict()), "available", false) === true
    ]
    reference_kkt_accepted = [
        run for run in reference_kkt_available
        if get(get(run, "reference_physical_solver_kkt", Dict()), "acceptance_passed", false) === true
    ]
    reference_solver_floor_kkt_accepted = [
        run for run in runs
        if get(get(get(run, "reference_physical_solver_kkt", Dict()),
            "solver_floor_complementarity", Dict()),
            "acceptance_passed", false) === true
    ]
    phase_only_kkt_available = [
        run for run in runs
        if get(get(get(run, "phase_only", Dict()), "physical_solver_kkt", Dict()), "available", false) === true
    ]
    phase_only_kkt_accepted = [
        run for run in phase_only_kkt_available
        if get(get(get(run, "phase_only", Dict()), "physical_solver_kkt", Dict()), "acceptance_passed", false) === true
    ]
    phase_only_solver_floor_kkt_accepted = [
        run for run in phase_only_kkt_available
        if get(get(get(get(run, "phase_only", Dict()), "physical_solver_kkt", Dict()),
            "solver_floor_complementarity", Dict()),
            "acceptance_passed", false) === true
    ]
    reference_kkt_tolerance_sensitivity = Dict{String,Int}()
    for run in reference_kkt_available
        policies = get(
            get(get(run, "reference_physical_solver_kkt", Dict()),
                "tolerance_sensitivity", Dict()),
            "policies", Dict(),
        )
        for (tolerance, policy) in policies
            reference_kkt_tolerance_sensitivity[tolerance] =
                get(reference_kkt_tolerance_sensitivity, tolerance, 0) +
                (get(policy, "compound_acceptance_passed", false) === true ? 1 : 0)
        end
    end
    phase_only_kkt_tolerance_sensitivity = Dict{String,Int}()
    for run in phase_only_kkt_available
        policies = get(
            get(get(get(run, "phase_only", Dict()), "physical_solver_kkt", Dict()),
                "tolerance_sensitivity", Dict()),
            "policies", Dict(),
        )
        for (tolerance, policy) in policies
            phase_only_kkt_tolerance_sensitivity[tolerance] =
                get(phase_only_kkt_tolerance_sensitivity, tolerance, 0) +
                (get(policy, "compound_acceptance_passed", false) === true ? 1 : 0)
        end
    end
    reference_complementarity_scaling_audit_passed = count(
        run -> get(get(run, "reference_physical_solver_kkt", Dict()),
            "complementarity_scaling_audit", Dict())["scaling_relation_passed"] === true,
        reference_kkt_available,
    )
    phase_only_complementarity_scaling_audit_passed = count(
        run -> get(get(get(run, "phase_only", Dict()), "physical_solver_kkt", Dict()),
            "complementarity_scaling_audit", Dict())["scaling_relation_passed"] === true,
        phase_only_kkt_available,
    )
    reference_maximum_complementarity_scaling_product_relative_error = isempty(reference_kkt_available) ?
        nothing : maximum(
            get(get(get(run, "reference_physical_solver_kkt", Dict()),
                "complementarity_scaling_audit", Dict()),
                "maximum_relative_product_error", 0.0)
            for run in reference_kkt_available
        )
    phase_only_maximum_complementarity_scaling_product_relative_error = isempty(phase_only_kkt_available) ?
        nothing : maximum(
            get(get(get(get(run, "phase_only", Dict()), "physical_solver_kkt", Dict()),
                "complementarity_scaling_audit", Dict()),
                "maximum_relative_product_error", 0.0)
            for run in phase_only_kkt_available
        )
    reference_maximum_complementarity_residual = isempty(reference_kkt_available) ?
        nothing : maximum(
            get(get(get(run, "reference_physical_solver_kkt", Dict()),
                "tolerance_sensitivity", Dict()),
                "maximum_complementarity_residual", 0.0)
            for run in reference_kkt_available
        )
    phase_only_maximum_complementarity_residual = isempty(phase_only_kkt_available) ?
        nothing : maximum(
            get(get(get(get(run, "phase_only", Dict()), "physical_solver_kkt", Dict()),
                "tolerance_sensitivity", Dict()),
                "maximum_complementarity_residual", 0.0)
            for run in phase_only_kkt_available
        )
    phase_only_covariance_available = [
        run for run in runs
        if get(get(get(run, "phase_only", Dict()), "covariance", Dict()), "available", false) === true
    ]
    phase_only_covariance_accepted = [
        run for run in phase_only_covariance_available
        if get(get(get(run, "phase_only", Dict()), "covariance", Dict()), "equivalence_gate_passed", false) === true
    ]
    return Dict(
        "schema_version" => "nlpdiagnostics-real-99bus-phase-only-campaign-v5",
        "source" => Dict(
            "root_basename" => basename(root),
            "selected_snapshot_count" => length(SELECTED_SNAPSHOTS),
            "max_iter" => max_iter,
            "phase_angle" => angle,
            "endpoint_tolerance" => endpoint_tolerance,
            "baseline_margin" => baseline_margin,
            "model_feasibility_tolerance" => model_feasibility_tolerance,
            "ipopt_options" => ipopt_options,
            "initialization_policy" => initialization_policy,
            "start_perturbation_seed" => start_perturbation_seed,
            "start_perturbation_relative_size" => start_perturbation_relative_size,
        ),
        "runs" => runs,
        "summary" => Dict(
            "run_count" => length(runs),
            "available_run_count" => count(run -> get(run, "available", false) === true, runs),
            "phase_only_solver_run_count" => length(solved),
            "phase_only_locally_solved_count" => length(locally_solved),
            "all_phase_only_runs_locally_solved" => length(locally_solved) == length(SELECTED_SNAPSHOTS),
            "reference_physical_endpoint_acceptance_count" => length(reference_physical),
            "reference_physical_solver_kkt_available_count" => length(reference_kkt_available),
            "reference_physical_solver_kkt_acceptance_count" => length(reference_kkt_accepted),
            "reference_solver_floor_compound_kkt_acceptance_count" => length(reference_solver_floor_kkt_accepted),
            "all_reference_physical_solver_kkt_accepted" => length(reference_kkt_accepted) == length(SELECTED_SNAPSHOTS),
            "phase_only_physical_solver_kkt_available_count" => length(phase_only_kkt_available),
            "phase_only_physical_solver_kkt_acceptance_count" => length(phase_only_kkt_accepted),
            "phase_only_solver_floor_compound_kkt_acceptance_count" => length(phase_only_solver_floor_kkt_accepted),
            "reference_physical_solver_kkt_acceptance_by_complementarity_tolerance" => reference_kkt_tolerance_sensitivity,
            "phase_only_physical_solver_kkt_acceptance_by_complementarity_tolerance" => phase_only_kkt_tolerance_sensitivity,
            "reference_complementarity_scaling_audit_pass_count" => reference_complementarity_scaling_audit_passed,
            "phase_only_complementarity_scaling_audit_pass_count" => phase_only_complementarity_scaling_audit_passed,
            "reference_maximum_complementarity_scaling_product_relative_error" => reference_maximum_complementarity_scaling_product_relative_error,
            "phase_only_maximum_complementarity_scaling_product_relative_error" => phase_only_maximum_complementarity_scaling_product_relative_error,
            "reference_maximum_complementarity_residual" => reference_maximum_complementarity_residual,
            "phase_only_maximum_complementarity_residual" => phase_only_maximum_complementarity_residual,
            "phase_only_covariance_available_count" => length(phase_only_covariance_available),
            "phase_only_covariance_acceptance_count" => length(phase_only_covariance_accepted),
            "phase_only_physical_endpoint_acceptance_count" => length(phase_only_physical),
            "phase_only_solver_floor_calibrated_acceptance_count" => length(phase_only_solver_floor_calibrated),
            "all_phase_only_solver_floor_calibrated_accepted" => length(phase_only_solver_floor_calibrated) == length(SELECTED_SNAPSHOTS),
            "native_baseline_comparison_count" => length(baseline_comparable),
            "native_baseline_comparison_pass_count" => length(baseline_passed),
            "all_phase_only_endpoints_within_native_margin" => length(baseline_passed) == length(SELECTED_SNAPSHOTS),
            "all_reference_physical_endpoints_accepted" => length(reference_physical) == length(SELECTED_SNAPSHOTS),
            "all_phase_only_physical_endpoints_accepted" => length(phase_only_physical) == length(SELECTED_SNAPSHOTS),
            "solver_campaign_ready" => false,
            "physical_endpoint_validation" => false,
            "blocking_reason" => "solver-floor calibrated feasibility is qualified as relative solver-scale evidence, but absolute physical acceptance and full compound KKT acceptance are not yet qualified",
        ),
    )
end

if abspath(PROGRAM_FILE) == @__FILE__
    output = abspath(get(ENV, "NLPDIAGNOSTICS_REAL_99BUS_CAMPAIGN_OUTPUT", joinpath(@__DIR__, "..", "work", "real-99bus-phase-only-campaign.json")))
    mkpath(dirname(output))
    write(output, JSON.json(run_campaign()))
    println("wrote real 99-bus phase-only campaign report to $output")
end
