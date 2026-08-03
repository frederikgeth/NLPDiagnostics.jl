#!/usr/bin/env julia

# Compare two BMOPF campaign summaries without collapsing observations into a
# score. The output keeps availability, missing stages, and case-status
# changes explicit so a formulation or configuration change can be reviewed.
#
# julia --project=. benchmarks/compare_bmopf_summaries.jl \
#     baseline/summary.json candidate/summary.json [comparison.json]

using JSON

function _load_summary(path)
    isfile(path) || error("summary file is missing: $path")
    data = JSON.parsefile(path)
    data isa AbstractDict || error("summary must be a JSON object: $path")
    return data
end

_number(value) = value isa Number && isfinite(Float64(value)) ? Float64(value) : nothing

function _change_map(baseline, candidate)
    keys_union = sort!(collect(union(keys(baseline), keys(candidate))); by = string)
    return Dict(
        String(key) => Dict(
            "baseline" => get(baseline, key, 0),
            "candidate" => get(candidate, key, 0),
            "delta" => get(candidate, key, 0) - get(baseline, key, 0),
        ) for key in keys_union
    )
end

function _case_status_changes(baseline, candidate)
    function statuses(summary)
        result = Dict{String,Any}()
        for case in get(summary, "cases", Any[])
            case isa AbstractDict || continue
            name = String(get(case, "name", get(case, "snapshot", "?")))
            result[name] = Dict(
                "status" => get(case, "status", "unknown"),
                "point_policy" => get(case, "point_policy", "unknown"),
                "analysis_mode" => get(case, "analysis_mode", "unknown"),
            )
        end
        return result
    end
    before = statuses(baseline)
    after = statuses(candidate)
    names = sort!(collect(union(keys(before), keys(after))); by = string)
    changes = Dict{String,Any}()
    for name in names
        old = get(before, name, nothing)
        new = get(after, name, nothing)
        old == new && continue
        changes[name] = Dict("baseline" => old, "candidate" => new)
    end
    return changes
end

function _stage_changes(baseline, candidate)
    before = get(baseline, "profile_stage_seconds", Dict{String,Any}())
    after = get(candidate, "profile_stage_seconds", Dict{String,Any}())
    names = sort!(collect(union(keys(before), keys(after))); by = string)
    result = Dict{String,Any}()
    for name in names
        old = get(before, name, nothing)
        new = get(after, name, nothing)
        old_mean = old isa AbstractDict ? _number(get(old, "mean", nothing)) : nothing
        new_mean = new isa AbstractDict ? _number(get(new, "mean", nothing)) : nothing
        ratio = if isnothing(old_mean) || isnothing(new_mean) || old_mean == 0
            nothing
        else
            new_mean / old_mean
        end
        result[String(name)] = Dict(
            "baseline" => old,
            "candidate" => new,
            "mean_seconds_delta" => isnothing(old_mean) || isnothing(new_mean) ?
                                    nothing : new_mean - old_mean,
            "mean_seconds_ratio" => ratio,
        )
    end
    return result
end

function _coverage(summary)
    counts = get(summary, "dense_rank_case_counts", Dict{String,Any}())
    count_values = [something(_number(get(counts, key, 0)), 0.0) for key in (
        "eligible", "skipped_by_size_policy", "not_requested_structural", "unknown",
    )]
    total = sum(count_values)
    eligible = _number(get(counts, "eligible", 0))
    return Dict(
        "eligible_case_count" => eligible,
        "total_case_count" => total,
        "eligible_fraction" => isnothing(eligible) || isnothing(total) || total == 0 ?
                                nothing : eligible / total,
        "counts" => counts,
    )
end

function _mapping_changes(baseline, candidate)
    before = get(baseline, "saved_result_mapping_case_counts", Dict{String,Any}())
    after = get(candidate, "saved_result_mapping_case_counts", Dict{String,Any}())
    fields = sort!(collect(union(keys(before), keys(after))); by = string)
    result = Dict{String,Any}()
    for field in fields
        old = get(before, field, nothing)
        new = get(after, field, nothing)
        old_number = _number(old)
        new_number = _number(new)
        result[String(field)] = Dict(
            "baseline" => old,
            "candidate" => new,
            "delta" => isnothing(old_number) || isnothing(new_number) ?
                       nothing : new_number - old_number,
        )
    end
    return result
end

function _comparison(baseline, candidate)
    return Dict{String,Any}(
        "baseline_runner_version" => get(baseline, "runner_version", nothing),
        "candidate_runner_version" => get(candidate, "runner_version", nothing),
        "baseline_environment_fingerprint" => get(baseline, "environment_fingerprint", nothing),
        "candidate_environment_fingerprint" => get(candidate, "environment_fingerprint", nothing),
        "environment_changed" => get(baseline, "environment_fingerprint", nothing) !=
                                  get(candidate, "environment_fingerprint", nothing),
        "baseline_root" => get(baseline, "benchmark_root", get(baseline, "fixture_root", nothing)),
        "candidate_root" => get(candidate, "benchmark_root", get(candidate, "fixture_root", nothing)),
        "case_status_changes" => _case_status_changes(baseline, candidate),
        "generic_finding_code_changes" => _change_map(
            get(baseline, "aggregate_generic_finding_codes", Dict{String,Any}()),
            get(candidate, "aggregate_generic_finding_codes", Dict{String,Any}()),
        ),
        "context_finding_code_changes" => _change_map(
            get(baseline, "aggregate_context_finding_codes", Dict{String,Any}()),
            get(candidate, "aggregate_context_finding_codes", Dict{String,Any}()),
        ),
        "initialization_finding_code_changes" => _change_map(
            get(baseline, "aggregate_initialization_finding_codes", Dict{String,Any}()),
            get(candidate, "aggregate_initialization_finding_codes", Dict{String,Any}()),
        ),
        "profile_stage_seconds_changes" => _stage_changes(baseline, candidate),
        "dense_rank_coverage" => Dict(
            "baseline" => _coverage(baseline),
            "candidate" => _coverage(candidate),
        ),
        "saved_result_mapping_changes" => _mapping_changes(baseline, candidate),
    )
end

function main()
    length(ARGS) in (2, 3) || error(
        "usage: compare_bmopf_summaries.jl baseline/summary.json candidate/summary.json [output.json]",
    )
    comparison = _comparison(_load_summary(ARGS[1]), _load_summary(ARGS[2]))
    serialized = JSON.json(comparison)
    if length(ARGS) == 3
        write(ARGS[3], serialized)
        println("wrote ", ARGS[3])
    else
        println(serialized)
    end
end

main()
