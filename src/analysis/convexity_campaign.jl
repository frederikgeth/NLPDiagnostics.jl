"""One reproducible Jensen-inequality trial for a scalar model function."""
struct ConvexityCampaignTrial{T<:AbstractFloat}
    index::Int
    left::Vector{T}
    right::Vector{T}
    mixed::Vector{T}
    weight::T
    left_value::Union{Nothing,T}
    right_value::Union{Nothing,T}
    mixed_value::Union{Nothing,T}
    chord_value::Union{Nothing,T}
    violation::Union{Nothing,T}
    threshold::Union{Nothing,T}
    status::Symbol
    reason::Union{Nothing,String}
end

"""
A bounded, seeded search for a point-pair violation of convexity or concavity.
`conclusion == :counterexample_found` is a numerical witness under the recorded
tolerance. `:not_observed` is never a certificate of convexity or concavity.
"""
struct ConvexityCampaignSummary{T<:AbstractFloat}
    available::Bool
    reason::Union{Nothing,String}
    conclusion::Symbol
    claim::Symbol
    source::Union{Nothing,EntityRef}
    model_fingerprint::String
    variables::Vector{MOI.VariableIndex}
    lower::Vector{T}
    upper::Vector{T}
    seed::Int
    weight::T
    absolute_tolerance::T
    relative_tolerance::T
    requested_pairs::Int
    trials::Vector{ConvexityCampaignTrial{T}}
    witness_index::Union{Nothing,Int}
    domain_basis::Symbol
end

const _CONVEXITY_REAL_OPERATORS = Set((
    :+, :-, :*, :/, :^, :abs, :sqrt, :exp, :expm1,
    :log, :log10, :log2, :log1p, :sin, :cos, :tan,
    :asin, :acos, :atan, :sinh, :cosh, :tanh, :atanh,
    :min, :max,
))

_convexity_supported_function(value::Real) = isfinite(value)
_convexity_supported_function(::MOI.VariableIndex) = true
_convexity_supported_function(::MOI.ScalarAffineFunction) = true
_convexity_supported_function(::MOI.ScalarQuadraticFunction) = true
function _convexity_supported_function(value::MOI.ScalarNonlinearFunction)
    value.head in _CONVEXITY_REAL_OPERATORS || return false
    return all(_convexity_supported_function, value.args)
end
_convexity_supported_function(value) = false

function _convexity_campaign_unavailable(
    model_fingerprint, variables, lower, upper, seed, weight,
    absolute_tolerance, relative_tolerance, requested_pairs, claim, source,
    reason; domain_basis = :unavailable,
)
    return ConvexityCampaignSummary{Float64}(
        false, String(reason), :unavailable, claim, source,
        model_fingerprint, variables, lower, upper, seed, weight,
        absolute_tolerance, relative_tolerance, requested_pairs,
        ConvexityCampaignTrial{Float64}[], nothing, domain_basis,
    )
end

function _convexity_campaign_target(model_snapshot, row)
    if isnothing(row)
        objective = model_snapshot.objective
        isnothing(objective) && return nothing, nothing,
            "the model has no ordinary scalar objective"
        source = _objective_ref(objective.function_value)
        return objective.function_value, source, nothing
    end
    functions, sources = _ordinary_rows(model_snapshot)
    1 <= row <= length(functions) ||
        throw(ArgumentError("row must index an ordinary evaluated scalar row"))
    return functions[row], sources[row], nothing
end

function _convexity_value(model, function_value, variables, values)
    lookup = Dict(variable => values[index] for
        (index, variable) in enumerate(variables))
    raw = try
        MOI.Utilities.eval_variables(
            variable -> lookup[variable], model, function_value,
        )
    catch error
        return nothing, "function evaluation failed: $(sprint(showerror, error))"
    end
    raw isa Real || return nothing, "function evaluation was not real-valued"
    value = try
        Float64(raw)
    catch
        return nothing, "function value cannot be represented as Float64"
    end
    isfinite(value) || return nothing, "function evaluation was non-finite"
    return value, nothing
end

"""
    convexity_counterexample_campaign(model; lower, upper, row = nothing,
        claim = :convex, seed = 1, pairs = 32, weight = 0.5, ...)

Search a declared coordinate box for violations of the scalar Jensen
inequality. `row = nothing` selects the ordinary objective; an integer selects
an ordinary scalar row in `evaluate_numerical` order. The target must have a
supported public MOI expression, and interval domain analysis must establish
that it is real-valued throughout the box. The campaign checks function
convexity or concavity on the box, not feasibility or convexity of the model's
constraint set. A missing witness is not a proof of the requested property.
"""
function convexity_counterexample_campaign(
    model::MOI.ModelLike;
    lower::AbstractVector{<:Real},
    upper::AbstractVector{<:Real},
    row::Union{Nothing,Integer} = nothing,
    claim::Symbol = :convex,
    seed::Integer = 1,
    pairs::Integer = 32,
    weight::Real = 0.5,
    absolute_tolerance::Real = 1.0e-9,
    relative_tolerance::Real = 1.0e-9,
)
    claim in (:convex, :concave) ||
        throw(ArgumentError("claim must be :convex or :concave"))
    1 <= pairs <= 256 || throw(ArgumentError("pairs must lie in 1:256"))
    seed >= 0 || throw(ArgumentError("seed must be nonnegative"))
    seed <= typemax(Int) || throw(ArgumentError("seed exceeds Int range"))
    converted_weight = Float64(weight)
    isfinite(converted_weight) && 0 < converted_weight < 1 ||
        throw(ArgumentError("weight must lie strictly between zero and one"))
    absolute = Float64(absolute_tolerance)
    relative = Float64(relative_tolerance)
    isfinite(absolute) && absolute >= 0 ||
        throw(ArgumentError("absolute_tolerance must be finite and nonnegative"))
    isfinite(relative) && relative >= 0 ||
        throw(ArgumentError("relative_tolerance must be finite and nonnegative"))
    variables = MOI.get(model, MOI.ListOfVariableIndices())
    length(lower) == length(upper) == length(variables) ||
        throw(DimensionMismatch("box endpoints must match the model variable order"))
    low = Float64.(lower)
    high = Float64.(upper)
    all(isfinite, low) && all(isfinite, high) && all(low .<= high) ||
        throw(ArgumentError("box endpoints must be finite and lower <= upper"))
    all(isfinite, high .- low) ||
        throw(ArgumentError("box widths must be finite in Float64"))
    any(low .< high) || throw(ArgumentError("the box must have a nonzero width"))

    model_snapshot = snapshot(model)
    fingerprint = model_fingerprint(model)
    function_value, source, target_reason = _convexity_campaign_target(
        model_snapshot, row,
    )
    unavailable(reason; domain_basis = :unavailable) =
        _convexity_campaign_unavailable(
            fingerprint, variables, low, high, Int(seed), converted_weight,
            absolute, relative, Int(pairs), claim, source, reason;
            domain_basis,
        )
    isnothing(target_reason) || return unavailable(target_reason)
    _convexity_supported_function(function_value) || return unavailable(
        "the selected function is not in the supported ordinary scalar expression subset",
    )

    declared = _domain_variable_intervals(model_snapshot)
    for (index, variable) in enumerate(variables)
        interval = declared[variable]
        interval.valid && low[index] >= interval.lower &&
            high[index] <= interval.upper || return unavailable(
                "the supplied box is not contained in the certified coordinate interval for variable $(variable.value)",
            )
    end
    box = Dict(variable => IntervalEnclosure(low[index], high[index]; certified = true)
        for (index, variable) in enumerate(variables))
    issues = ExpressionDomainIssue[]
    _source_domain_issues!(issues, function_value, source, box;
        skip_constant_source = false)
    isempty(issues) || return unavailable(
        "the selected function's real domain is not certified throughout the box: " *
        join(unique(issue.requirement for issue in issues), ", ");
        domain_basis = :interval_domain_analysis,
    )

    rng = Random.MersenneTwister(Int(seed))
    trials = ConvexityCampaignTrial{Float64}[]
    witness_index = nothing
    best_margin = -Inf
    for index in 1:Int(pairs)
        left = low .+ (high .- low) .* rand(rng, length(low))
        right = low .+ (high .- low) .* rand(rng, length(low))
        mixed = converted_weight .* left .+ (1 - converted_weight) .* right
        if !all(isfinite, left) || !all(isfinite, right) ||
           !all(isfinite, mixed) || !all(low .<= left) ||
           !all(left .<= high) || !all(low .<= right) ||
           !all(right .<= high) || !all(low .<= mixed) ||
           !all(mixed .<= high)
            push!(trials, ConvexityCampaignTrial{Float64}(
                index, left, right, mixed, converted_weight,
                nothing, nothing, nothing, nothing, nothing, nothing,
                :evaluation_unavailable,
                "sampled coordinates were not finite and inside the certified box",
            ))
            continue
        end
        left_value, left_reason = _convexity_value(
            model, function_value, variables, left,
        )
        right_value, right_reason = _convexity_value(
            model, function_value, variables, right,
        )
        mixed_value, mixed_reason = _convexity_value(
            model, function_value, variables, mixed,
        )
        reason = !isnothing(left_reason) ? left_reason :
            !isnothing(right_reason) ? right_reason : mixed_reason
        if !isnothing(reason)
            push!(trials, ConvexityCampaignTrial{Float64}(
                index, left, right, mixed, converted_weight,
                left_value, right_value, mixed_value, nothing, nothing,
                nothing, :evaluation_unavailable, reason,
            ))
            continue
        end
        chord = converted_weight * left_value +
            (1 - converted_weight) * right_value
        if !isfinite(chord)
            push!(trials, ConvexityCampaignTrial{Float64}(
                index, left, right, mixed, converted_weight,
                left_value, right_value, mixed_value, nothing, nothing,
                nothing, :evaluation_unavailable, "chord value was non-finite",
            ))
            continue
        end
        violation = claim == :convex ? mixed_value - chord : chord - mixed_value
        threshold = absolute + relative * max(
            abs(left_value), abs(right_value), abs(mixed_value), abs(chord), 1.0,
        )
        if !isfinite(violation) || !isfinite(threshold)
            push!(trials, ConvexityCampaignTrial{Float64}(
                index, left, right, mixed, converted_weight,
                left_value, right_value, mixed_value, chord, nothing,
                nothing, :evaluation_unavailable,
                "violation or tolerance threshold was non-finite",
            ))
            continue
        end
        status = violation > threshold ? :counterexample : :no_violation
        push!(trials, ConvexityCampaignTrial{Float64}(
            index, left, right, mixed, converted_weight,
            left_value, right_value, mixed_value, chord, violation,
            threshold, status, nothing,
        ))
        if status == :counterexample && violation - threshold > best_margin
            best_margin = violation - threshold
            witness_index = index
        end
    end
    model_fingerprint(model) == fingerprint || return unavailable(
        "the public model description changed during the campaign";
        domain_basis = :certified_coordinate_box,
    )
    conclusion = !isnothing(witness_index) ? :counterexample_found :
        any(trial -> trial.status == :evaluation_unavailable, trials) ?
        :inconclusive : :not_observed
    return ConvexityCampaignSummary{Float64}(
        true, nothing, conclusion, claim, source, fingerprint,
        variables, low, high, Int(seed), converted_weight, absolute,
        relative, Int(pairs), trials, witness_index,
        :certified_coordinate_box,
    )
end

"""Return all sampled points, values, and qualification as renderer-neutral data."""
function convexity_counterexample_campaign_data(summary::ConvexityCampaignSummary)
    return Dict{String,Any}(
        "schema_version" => "nlpdiagnostics-convexity-campaign-v1",
        "available" => summary.available,
        "reason" => summary.reason,
        "unavailable_reason" => summary.available ? nothing :
            unavailable_reason_data(UnavailableReason(
                something(summary.reason, "campaign prerequisites were unavailable");
                code = :convexity_campaign_unavailable,
                category = summary.domain_basis == :interval_domain_analysis ?
                    :domain : :capability,
                stage = :convexity_campaign,
            )),
        "conclusion" => string(summary.conclusion),
        "claim" => string(summary.claim),
        "source" => isnothing(summary.source) ? nothing : entity_data(summary.source),
        "model_fingerprint" => summary.model_fingerprint,
        "variables" => [variable.value for variable in summary.variables],
        "lower" => copy(summary.lower),
        "upper" => copy(summary.upper),
        "seed" => summary.seed,
        "weight" => summary.weight,
        "absolute_tolerance" => summary.absolute_tolerance,
        "relative_tolerance" => summary.relative_tolerance,
        "requested_pairs" => summary.requested_pairs,
        "completed_pairs" => count(trial -> trial.status != :evaluation_unavailable,
            summary.trials),
        "domain_basis" => string(summary.domain_basis),
        "witness_index" => summary.witness_index,
        "trials" => [Dict{String,Any}(
            "index" => trial.index,
            "left" => copy(trial.left),
            "right" => copy(trial.right),
            "mixed" => copy(trial.mixed),
            "weight" => trial.weight,
            "left_value" => trial.left_value,
            "right_value" => trial.right_value,
            "mixed_value" => trial.mixed_value,
            "chord_value" => trial.chord_value,
            "violation" => trial.violation,
            "threshold" => trial.threshold,
            "status" => string(trial.status),
            "reason" => trial.reason,
        ) for trial in summary.trials],
        "qualification" => Dict(
            "counterexample" => "sampled Jensen inequality violation on an interval-domain-certified coordinate box",
            "not_observed" => "no violation found among the recorded samples; no convexity or concavity certificate",
            "constraint_row" => "property of a scalar row function, not of the feasible set",
        ),
    )
end

"""Turn one campaign conclusion into a typed diagnostic finding."""
function convexity_counterexample_campaign_report(summary::ConvexityCampaignSummary)
    report = DiagnosticReport()
    report.metadata[:stage] = "convexity_counterexample_campaign"
    report.metadata[:conclusion] = string(summary.conclusion)
    report.metadata[:model_fingerprint] = summary.model_fingerprint
    report.metadata[:seed] = string(summary.seed)
    code, severity, observation, why = if summary.conclusion == :counterexample_found
        (
            :convexity_counterexample_observed,
            SeverityWarning,
            "A sampled pair violates the $(summary.claim) Jensen inequality by more than the declared tolerance.",
            "This is a reproducible numerical counterexample for the selected scalar function on the declared box; it does not diagnose the cause or characterize the whole model.",
        )
    elseif summary.conclusion == :not_observed
        (
            :convexity_counterexample_not_observed,
            SeverityInfo,
            "No $(summary.claim) Jensen violation was observed in $(summary.requested_pairs) seeded pairs.",
            "Finite sampling cannot establish convexity or concavity.",
        )
    elseif summary.conclusion == :inconclusive
        (
            :convexity_campaign_inconclusive,
            SeverityInfo,
            "Some seeded function evaluations were unavailable and no counterexample was found.",
            "Incomplete numerical coverage cannot support a conclusion about the requested property.",
        )
    else
        (
            :convexity_campaign_unavailable,
            SeverityInfo,
            "The requested convexity campaign could not run.",
            "The target function or certified domain prerequisites were not established.",
        )
    end
    witness = isnothing(summary.witness_index) ? nothing :
        summary.trials[summary.witness_index]
    finding_keywords = (;
        severity,
        domain = NumericalIssue,
        basis = NumericalObservation,
        confidence = ConfidenceHigh,
        observation,
        why_it_matters = why,
        affected = isnothing(summary.source) ? EntityRef[] : [summary.source],
        evidence = [Evidence("Seeded scalar Jensen campaign"; details = [
            "model_fingerprint" => summary.model_fingerprint,
            "claim" => string(summary.claim),
            "seed" => summary.seed,
            "requested_pairs" => summary.requested_pairs,
            "completed_pairs" => count(trial -> trial.status != :evaluation_unavailable,
                summary.trials),
            "domain_basis" => string(summary.domain_basis),
            "reason" => summary.reason,
            "witness_index" => summary.witness_index,
            "witness_violation" => isnothing(witness) ? nothing : witness.violation,
            "witness_threshold" => isnothing(witness) ? nothing : witness.threshold,
        ])],
        suggested_actions = [
            "Replay the recorded point pair and function values with an independent evaluation or tighter numerical policy.",
            "Inspect the expression and declared domain before drawing model-level conclusions.",
        ],
    )
    finding = if code == :convexity_counterexample_observed
        Finding(:convexity_counterexample_observed; finding_keywords...)
    elseif code == :convexity_counterexample_not_observed
        Finding(:convexity_counterexample_not_observed; finding_keywords...)
    elseif code == :convexity_campaign_inconclusive
        Finding(:convexity_campaign_inconclusive; finding_keywords...)
    else
        Finding(:convexity_campaign_unavailable; finding_keywords...)
    end
    push!(report, finding)
    return report
end
