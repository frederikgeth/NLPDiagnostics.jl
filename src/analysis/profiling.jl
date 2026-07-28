function _profile_stage!(seconds, allocations, key, operation)
    measured = @timed operation()
    seconds[key] = measured.time
    allocations[key] = measured.bytes
    return measured.value
end

function _count_symbols(values)
    counts = Dict{Symbol,Int}()
    for value in values
        counts[value] = get(counts, value, 0) + 1
    end
    return counts
end

"""
    profile_case(model, case; cache = EvaluationCache(), ...)

Run the generic static, expression, stable-reformulation, numerical, active-set,
and structural-numerical degeneracy stages for one labeled `ProfileCase`. No
solver is invoked and no model data is modified. The result retains timing and
derivative-provenance counts alongside the full reports so formulation cases can
be compared reproducibly.
"""
function profile_case(
    model::MOI.ModelLike,
    case::ProfileCase{T};
    cache::EvaluationCache = EvaluationCache(),
    relative_step::Real = cbrt(eps(T)),
    scale_ratio_threshold::Real = 1.0e6,
    rank_relative_tolerance::Real =
        max(length(case.point.variables), 1) * eps(T),
    rank_max_dense_entries::Integer = 4_000_000,
    feasibility_tolerance::Real = sqrt(eps(T)),
    active_tolerance::Real = sqrt(eps(T)),
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
        analyze_static(structural_snapshot; graph = structural_graph),
    )

    expression_report = _profile_stage!(timings, allocations, :expressions, () ->
        analyze_expressions(model; numeric_type = T),
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
        rank_relative_tolerance = rank_relative_tolerance,
        rank_max_dense_entries = rank_max_dense_entries,
    ))

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
    ))

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
    metrics = (
        :jacobian_rank => :jacobian_rank_available,
        :sparse_qr_rank => :sparse_qr_rank_available,
        :sparse_qr_condition_proxy => nothing,
    )
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
            "boundary_atanh",
            "atanh(x) near one",
            1.0 - 1.0e-12,
            x -> MOI.ScalarNonlinearFunction(:atanh, Any[x]),
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
