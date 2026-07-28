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
        "point" => Dict(
            "label" => case.point.label,
            "variables" => [variable.value for variable in case.point.variables],
            "values" => copy(case.point.values),
        ),
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
    unit_circle_radius_tolerance::Real = 1.0e-6,
    rank_relative_tolerance::Real =
        max(length(case.point.variables), 1) * eps(T),
    rank_max_dense_entries::Integer = 4_000_000,
    feasibility_tolerance::Real = sqrt(eps(T)),
    active_tolerance::Real = sqrt(eps(T)),
    strict_domain_proximity_threshold::Union{Nothing,Real} = nothing,
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
        strict_domain_proximity_threshold = strict_domain_proximity_threshold,
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
            Float64(pi / 2),
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
