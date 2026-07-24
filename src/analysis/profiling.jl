function _profile_elapsed_seconds(start_time)
    return Float64(time_ns() - start_time) / 1.0e9
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

Run the generic numerical, active-set, and structural-numerical degeneracy
stages for one labeled `ProfileCase`. No solver is invoked and no model data is
modified. The result retains timing and derivative-provenance counts alongside
the full reports so formulation cases can be compared reproducibly.
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

    start = time_ns()
    evaluation = evaluate_numerical(
        model,
        case.point;
        cache = cache,
        relative_step = relative_step,
    )
    timings[:evaluation] = _profile_elapsed_seconds(start)

    start = time_ns()
    numerical_report = analyze_numerical(
        model,
        case.point;
        cache = cache,
        relative_step = relative_step,
        scale_ratio_threshold = scale_ratio_threshold,
        rank_relative_tolerance = rank_relative_tolerance,
        rank_max_dense_entries = rank_max_dense_entries,
    )
    timings[:numerical] = _profile_elapsed_seconds(start)

    start = time_ns()
    active_set_report = analyze_active_set(
        model,
        evaluation;
        feasibility_tolerance = feasibility_tolerance,
        active_tolerance = active_tolerance,
        rank_relative_tolerance = rank_relative_tolerance,
        rank_max_dense_entries = rank_max_dense_entries,
    )
    timings[:active_set] = _profile_elapsed_seconds(start)

    start = time_ns()
    degeneracy_report = analyze_degeneracy(
        model,
        evaluation;
        relative_tolerance = rank_relative_tolerance,
        max_dense_entries = rank_max_dense_entries,
    )
    timings[:degeneracy] = _profile_elapsed_seconds(start)

    return ProfileResult{T}(
        case,
        evaluation,
        numerical_report,
        active_set_report,
        degeneracy_report,
        timings,
        evaluation_call_statistics(evaluation),
        _count_symbols(evaluation.jacobian_row_methods),
        _count_symbols(capability.source for capability in evaluation.capabilities),
        cache.hits - hits_before,
        cache.misses - misses_before,
    )
end
