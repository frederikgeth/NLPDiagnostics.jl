#!/usr/bin/env julia

"""Aggregate repeated BMOPF perturbation summaries across snapshots.

The report keeps recurrence, baseline consistency, sparse-rank observations,
and cross-solver agreement separate. It is deliberately not a benchmark score.
"""

using JSON

function _load(path)
    isfile(path) || error("missing perturbation summary: $path")
    value = JSON.parsefile(path)
    value isa AbstractDict || error("summary is not a JSON object: $path")
    value
end

function _dict(value)
    value isa AbstractDict || return Dict{String,Any}()
    Dict{String,Any}(string(k) => v for (k, v) in value)
end

function _num(value)
    value isa Number && isfinite(Float64(value)) && return Float64(value)
    nothing
end

function _int(value, default = 0)
    value isa Integer && return Int(value)
    value isa Number && return Int(value)
    value isa AbstractString || return default
    try parse(Int, value) catch; default end
end

function _count!(dict, key, amount = 1)
    key = String(key)
    dict[key] = get(dict, key, 0) + amount
end

function _median(values)
    isempty(values) && return nothing
    sorted = sort(values)
    middle = (length(sorted) + 1) ÷ 2
    isodd(length(sorted)) ? sorted[middle] : (sorted[middle] + sorted[middle + 1]) / 2
end

function _direction(values)
    isempty(values) && return "unavailable"
    signs = unique(value < 0 ? "negative" : value > 0 ? "positive" : "zero" for value in values)
    length(signs) == 1 ? first(signs) : "mixed"
end

function _finding(code, severity, confidence, observation, evidence, suggested_action)
    Dict{String,Any}(
        "code" => code, "severity" => severity, "confidence" => confidence,
        "category" => "perturbation_campaign", "observation" => observation,
        "evidence" => evidence, "suggested_action" => suggested_action,
    )
end

function main()
    length(ARGS) >= 1 || error(
        "usage: summarize_bmopf_perturbation_corpus.jl repeat-summary.json ... [output.json]",
    )
    paths = abspath.(ARGS)
    output_path = nothing
    if length(paths) >= 3
        output_path = pop!(paths)
    elseif length(paths) >= 2 && endswith(last(paths), ".json")
        candidate = last(paths)
        is_output = !isfile(candidate)
        if !is_output
            try
                is_output = !haskey(_load(candidate), "by_pair")
            catch
                is_output = true
            end
        end
        is_output && (output_path = pop!(paths))
    end
    isempty(paths) && error("at least one repeat summary is required")
    output_path = something(output_path, joinpath(dirname(first(paths)), "perturbation_corpus_summary.json"))
    summaries = Dict{String,Any}[_load(path) for path in paths]
    environment_fingerprints = String[]
    for summary in summaries
        for fingerprint in get(summary, "environment_fingerprints", Any[])
            fingerprint isa AbstractString && push!(environment_fingerprints, fingerprint)
        end
    end
    pairs = Dict{String,Any}[]
    source_errors = Dict{String,Any}[]
    for (path, summary) in zip(paths, summaries)
        for error in get(summary, "artifact_errors", Any[])
            push!(source_errors, Dict("summary_path" => path, "artifact" => error))
        end
        for pair_raw in values(_dict(get(summary, "by_pair", Dict())))
            pair = _dict(pair_raw)
            pair["source_summary"] = path
            push!(pairs, pair)
        end
    end
    by_family = Dict{String,Any}()
    solver_pairs = Dict{String,Vector{Dict{String,Any}}}()
    for pair in pairs
        family = String(get(pair, "family", "unknown"))
        aggregate = get!(by_family, family, Dict{String,Any}(
            "pair_count" => 0, "case_count" => 0, "cases" => String[],
            "solvers" => String[], "replicate_observation_count" => 0,
            "baseline_consistent_pair_count" => 0,
            "baseline_inconsistent_pair_count" => 0,
            "stable_pair_count" => 0, "repeatable_change_pair_count" => 0,
            "termination_change_count" => 0,
            "variant_status_counts" => Dict{String,Int}(),
            "termination_counts" => Dict{String,Int}(),
            "iteration_deltas" => Float64[],
            "sparse_rank_effect_observation_count" => 0,
        ))
        aggregate["pair_count"] += 1
        case = String(get(pair, "case", "unknown"))
        solver = String(get(pair, "solver", "unknown"))
        case in aggregate["cases"] || push!(aggregate["cases"], case)
        aggregate["case_count"] = length(aggregate["cases"])
        solver in aggregate["solvers"] || push!(aggregate["solvers"], solver)
        aggregate["replicate_observation_count"] += _int(get(pair, "replicate_count", 0))
        get(pair, "baseline_consistent", false) === true ?
            (aggregate["baseline_consistent_pair_count"] += 1) :
            (aggregate["baseline_inconsistent_pair_count"] += 1)
        get(pair, "repeatable_termination_stability", false) === true &&
            (aggregate["stable_pair_count"] += 1)
        get(pair, "repeatable_termination_change", false) === true &&
            (aggregate["repeatable_change_pair_count"] += 1)
        aggregate["termination_change_count"] += _int(get(pair, "termination_change_count", 0))
        for item_raw in get(pair, "observations", Any[])
            item = _dict(item_raw)
            _count!(aggregate["variant_status_counts"], get(item, "status", "unknown"))
            _count!(aggregate["termination_counts"], get(item, "termination", "unknown"))
            delta = _num(get(item, "iteration_delta_vs_baseline", nothing))
            !isnothing(delta) && push!(aggregate["iteration_deltas"], delta)
            row = _dict(get(item, "row_family_perturbation", nothing))
            effects = _int(get(row, "rank_effect_family_count", 0)) +
                      _int(get(row, "sparse_pattern_effect_family_count", 0))
            aggregate["sparse_rank_effect_observation_count"] += effects > 0
        end
        solver_key = join((case, family), "|")
        push!(get!(solver_pairs, solver_key, Dict{String,Any}[]), pair)
    end
    solver_agreement = Dict{String,Any}()
    agreement_count = 0
    disagreement_count = 0
    repeatability_unavailable_count = 0
    baseline_disagreement_count = 0
    variant_termination_disagreement_count = 0
    iteration_direction_disagreement_count = 0
    for (key, group) in solver_pairs
        profiles = Dict{String,Any}()
        for pair in group
            observations = [_dict(item) for item in get(pair, "observations", Any[])]
            baseline_terms = unique(String(get(item, "baseline_termination", "unknown")) for item in observations)
            variant_terms = unique(String(get(item, "termination", "unknown")) for item in observations)
            deltas = Float64[]
            for item in observations
                delta = _num(get(item, "iteration_delta_vs_baseline", nothing))
                !isnothing(delta) && push!(deltas, delta)
            end
            profiles[String(get(pair, "solver", "unknown"))] = Dict(
                "repeatable_termination_change" => get(pair, "repeatable_termination_change", false),
                "repeatable_termination_stability" => get(pair, "repeatable_termination_stability", false),
                "baseline_terminations" => baseline_terms,
                "variant_terminations" => variant_terms,
                "iteration_direction" => _direction(deltas),
                "iteration_delta_count" => length(deltas),
            )
        end
        solver_names = collect(keys(profiles))
        baseline_sets = [join(sort!(String.(get(profiles[name], "baseline_terminations", Any[]))), "|") for name in solver_names]
        variant_sets = [join(sort!(String.(get(profiles[name], "variant_terminations", Any[]))), "|") for name in solver_names]
        directions = [get(profiles[name], "iteration_direction", "unavailable") for name in solver_names]
        repeatability = [get(profiles[name], "repeatable_termination_change", false) for name in solver_names]
        repeatability_available = all(_int(get(pair, "replicate_count", 0)) >= 2 for pair in group)
        baseline_agreed = length(solver_names) >= 2 && length(unique(baseline_sets)) == 1
        variant_agreed = length(solver_names) >= 2 && length(unique(variant_sets)) == 1
        direction_agreed = length(solver_names) >= 2 &&
            length(unique(filter(!=("unavailable"), directions))) <= 1
        repeatability_agreed = length(solver_names) >= 2 && repeatability_available &&
            length(unique(repeatability)) == 1
        agreement_count += repeatability_agreed
        repeatability_unavailable_count += length(solver_names) >= 2 && !repeatability_available
        disagreement_count += length(solver_names) >= 2 && repeatability_available && !repeatability_agreed
        baseline_disagreement_count += length(solver_names) >= 2 && !baseline_agreed
        variant_termination_disagreement_count += length(solver_names) >= 2 && !variant_agreed
        iteration_direction_disagreement_count += length(solver_names) >= 2 && !direction_agreed
        solver_agreement[key] = Dict(
            "case" => first(split(key, '|')), "family" => split(key, '|')[2],
            "solver_profiles" => profiles,
            "solver_count" => length(profiles),
            "repeatability_agreed" => repeatability_agreed,
            "repeatability_available" => repeatability_available,
            "baseline_termination_agreed" => baseline_agreed,
            "variant_termination_agreed" => variant_agreed,
            "iteration_direction_agreed" => direction_agreed,
            "interpretation" => "Agreement compares observed solver signatures for the same case/family; it is not proof of common causality.",
        )
    end
    for aggregate in values(by_family)
        aggregate["cases"] = sort!(unique(aggregate["cases"]))
        aggregate["solvers"] = sort!(unique(aggregate["solvers"]))
        deltas = aggregate["iteration_deltas"]
        aggregate["iteration_delta_summary"] = Dict(
            "count" => length(deltas), "minimum" => isempty(deltas) ? nothing : minimum(deltas),
            "median" => _median(deltas), "maximum" => isempty(deltas) ? nothing : maximum(deltas),
        )
        delete!(aggregate, "iteration_deltas")
    end
    findings = Any[]
    for (family, aggregate_raw) in by_family
        aggregate = _dict(aggregate_raw)
        cases = _int(get(aggregate, "case_count", 0))
        sparse_effects = _int(get(aggregate, "sparse_rank_effect_observation_count", 0))
        stable_pairs = _int(get(aggregate, "stable_pair_count", 0))
        repeatable_changes = _int(get(aggregate, "repeatable_change_pair_count", 0))
        sparse_effects >= 2 && push!(findings, _finding(
            "family_sparse_pattern_effect_recurrence", "info", "local",
            "Family $family shows recurring local sparse-pattern effects across the selected corpus.",
            Dict("family" => family, "case_count" => cases,
                 "sparse_rank_effect_observation_count" => sparse_effects,
                 "solvers" => get(aggregate, "solvers", Any[])),
            "Inspect the affected row families and distinguish structural pattern effects from numerical rank evidence.",
        ))
        stable_pairs >= 2 && push!(findings, _finding(
            "family_perturbation_termination_stability", "info", "numerical",
            "Family $family produced stable termination relative to baseline in repeated observations.",
            Dict("family" => family, "stable_pair_count" => stable_pairs,
                 "case_count" => cases),
            "Treat this as solver- and option-scoped evidence; expand solver and initialization coverage before generalizing.",
        ))
        repeatable_changes > 0 && push!(findings, _finding(
            "family_perturbation_termination_change_recurrence", "warning", "numerical",
            "Family $family produced a repeated termination change relative to baseline.",
            Dict("family" => family, "repeatable_change_pair_count" => repeatable_changes,
                 "case_count" => cases),
            "Inspect solver logs and feasibility residuals before attributing the change to the omitted family.",
        ))
    end
    for (key, alignment_raw) in solver_agreement
        alignment = _dict(alignment_raw)
        solver_count = _int(get(alignment, "solver_count", 0))
        solver_count >= 2 && get(alignment, "baseline_termination_agreed", false) === false &&
            push!(findings, _finding(
                "solver_baseline_termination_disagreement", "warning", "numerical",
                "Solvers disagree on baseline termination for a selected case/family pair.",
                Dict("case_family" => key, "solver_profiles" => get(alignment, "solver_profiles", Dict())),
                "Keep solver-specific baselines separate before interpreting perturbation deltas.",
            ))
        solver_count >= 2 && get(alignment, "variant_termination_agreed", false) === false &&
            push!(findings, _finding(
                "solver_variant_termination_disagreement", "warning", "numerical",
                "Solvers disagree on variant termination for a selected case/family pair.",
                Dict("case_family" => key, "solver_profiles" => get(alignment, "solver_profiles", Dict())),
                "Inspect each solver trace independently; do not average variant outcomes.",
            ))
        solver_count >= 2 && get(alignment, "iteration_direction_agreed", false) === false &&
            push!(findings, _finding(
                "solver_iteration_direction_disagreement", "warning", "numerical",
                "Solvers disagree on iteration-count direction for a selected case/family pair.",
                Dict("case_family" => key, "solver_profiles" => get(alignment, "solver_profiles", Dict())),
                "Report solver-specific iteration sensitivity and preserve option/provenance metadata.",
            ))
    end
    write(output_path, JSON.json(Dict(
        "runner_version" => "bmopf-perturbation-corpus-summary-v1",
        "source_summaries" => paths, "source_error_count" => length(source_errors),
        "environment_fingerprints" => sort!(unique(environment_fingerprints)),
        "source_errors" => source_errors, "pair_count" => length(pairs),
        "family_count" => length(by_family), "by_family" => by_family,
        "solver_agreement_pair_count" => length(solver_agreement),
        "solver_agreement_count" => agreement_count,
        "solver_disagreement_count" => disagreement_count,
        "repeatability_unavailable_count" => repeatability_unavailable_count,
        "baseline_solver_disagreement_count" => baseline_disagreement_count,
        "variant_termination_disagreement_count" => variant_termination_disagreement_count,
        "iteration_direction_disagreement_count" => iteration_direction_disagreement_count,
        "findings" => findings,
        "solver_agreement" => solver_agreement,
        "interpretation" => "Corpus recurrence and solver agreement are descriptive evidence. Family omissions are incomplete formulation experiments, and sparse rank effects remain local linearized observations.",
    )))
    println("wrote BMOPF perturbation corpus summary to $output_path")
end

main()
