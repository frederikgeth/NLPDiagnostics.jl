#!/usr/bin/env julia

"""Validate trace coverage against truth-labelled 30-bus bound-regime controls.

This runner joins the solver-trace comparison with the independently reviewed
`ibr_p_upper` bound-regime ledger. It checks expected positive and negative
control outcomes without converting the labels into a solver score.
"""

using JSON

Base.include(@__MODULE__, joinpath(@__DIR__, "common.jl"))
using .NLPDiagnosticsBenchmarkCommon: read_summary, write_json

length(ARGS) == 2 || length(ARGS) >= 4 || error(
    "usage: validate_bmopf_trace_truth_labels.jl <comparison.json> <ledger.json> [scope-comparison.json ...] <output.json>",
)

comparison_path, ledger_path = abspath.(ARGS[1:2])
comparison = read_summary(comparison_path; root = "/")
ledger = read_summary(ledger_path; root = "/")
scope_comparison_paths = length(ARGS) >= 4 ? abspath.(ARGS[3:end-1]) : String[]
scope_comparisons = [read_summary(path; root = "/") for path in scope_comparison_paths]

function case_key(path)
    normalized = replace(String(path), '\\' => '/')
    normalized = replace(normalized, ".bmopf.json" => "")
    return replace(normalized, '/' => "__")
end

const EXPECTED_CASES = Dict{String,Dict{String,Any}}(
    case_key("ENWLsnapshots/30bus_LN/30bus_LN_t01_0800.bmopf.json") => Dict(
        "truth_role" => "positive_control",
        "regime" => "zero_bound",
        "expected_physical_kkt_acceptance_passed" => false,
        "expected_strict_complementarity_failure" => true,
    ),
    case_key("ENWLsnapshots/30bus_LN/30bus_LN_t13_1400.bmopf.json") => Dict(
        "truth_role" => "negative_control",
        "regime" => "positive_bound",
        "expected_physical_kkt_acceptance_passed" => true,
        "expected_strict_complementarity_failure" => false,
    ),
    case_key("ENWLsnapshots/30bus_LG/30bus_LG_t01_0800.bmopf.json") => Dict(
        "truth_role" => "positive_control",
        "regime" => "zero_bound",
        "expected_physical_kkt_acceptance_passed" => false,
        "expected_strict_complementarity_failure" => true,
    ),
    case_key("ENWLsnapshots/30bus_LG/30bus_LG_t13_1400.bmopf.json") => Dict(
        "truth_role" => "negative_control",
        "regime" => "positive_bound",
        "expected_physical_kkt_acceptance_passed" => true,
        "expected_strict_complementarity_failure" => false,
    ),
    case_key("ENWLsnapshots/99bus_LN/99bus_LN_t13_1400.bmopf.json") => Dict(
        "truth_role" => "negative_control",
        "expected_physical_kkt_acceptance_passed" => true,
        "expected_strict_complementarity_failure" => false,
        "reviewed_source" => "docs/real_99bus_phase_only_kkt_failure_summary.json",
    ),
    case_key("ENWLsnapshots/99bus_LN/99bus_LN_t01_0800.bmopf.json") => Dict(
        "truth_role" => "positive_control",
        "expected_physical_kkt_acceptance_passed" => false,
        "expected_strict_complementarity_failure" => true,
        "reviewed_source" => "docs/real_99bus_phase_only_kkt_failure_summary.json",
    ),
    case_key("ENWLsnapshots/99bus_LG/99bus_LG_t01_0800.bmopf.json") => Dict(
        "truth_role" => "positive_control",
        "expected_physical_kkt_acceptance_passed" => false,
        "expected_strict_complementarity_failure" => true,
        "reviewed_source" => "docs/real_99bus_phase_only_kkt_failure_summary.json",
    ),
    case_key("ENWLsnapshots/99bus_LG/99bus_LG_t13_1400.bmopf.json") => Dict(
        "truth_role" => "negative_control",
        "expected_physical_kkt_acceptance_passed" => true,
        "expected_strict_complementarity_failure" => false,
        "reviewed_source" => "docs/real_99bus_phase_only_kkt_failure_summary.json",
    ),
    case_key("ENWLsnapshots/99bus_LN/99bus_LN_t25_2000.bmopf.json") => Dict(
        "truth_role" => "positive_control",
        "expected_physical_kkt_acceptance_passed" => false,
        "expected_strict_complementarity_failure" => true,
        "reviewed_source" => "docs/real_99bus_phase_only_kkt_failure_summary.json",
    ),
    case_key("ENWLsnapshots/99bus_LG/99bus_LG_t25_2000.bmopf.json") => Dict(
        "truth_role" => "positive_control",
        "expected_physical_kkt_acceptance_passed" => false,
        "expected_strict_complementarity_failure" => true,
        "reviewed_source" => "docs/real_99bus_phase_only_kkt_failure_summary.json",
    ),
)

const EXPECTED_UNAVAILABLE_CASES = Dict{String,Dict{String,Any}}(
)

const EXPECTED_SCOPE_CASES = Dict{String,Dict{String,Any}}(
)

function _ledger_cases(payload)
    result = Dict{String,Any}()
    for entry in get(payload, "cases", Any[])
        entry isa AbstractDict || continue
        snapshot = get(entry, "snapshot", nothing)
        snapshot === nothing && continue
        result[case_key(snapshot)] = entry
    end
    return result
end

function _trace_pairs(payload)
    coverage = get(payload, "trace_coverage_comparison", Dict())
    comparisons = get(coverage, "comparisons", Dict())
    candidate = get(comparisons, "right", Dict())
    pairs = get(candidate, "paired_traces", Any[])
    result = Dict{String,Any}()
    for pair in pairs
        pair isa AbstractDict || continue
        candidate_trace = get(pair, "candidate", Dict())
        provenance = get(candidate_trace, "provenance", Dict())
        name = get(provenance, "case", nothing)
        name === nothing && continue
        result[String(name)] = pair
    end
    return result
end

function _reviewed_truth_cases(payload)
    result = Dict{String,Any}()
    for entry in get(payload, "runs", Any[])
        entry isa AbstractDict || continue
        snapshot = get(entry, "snapshot", nothing)
        snapshot === nothing && continue
        failed_count = get(entry, "reference_failed_side_count", nothing)
        failed_count isa Integer || continue
        result[case_key(snapshot)] = Dict{String,Any}(
            "physical_kkt_acceptance_passed" => failed_count == 0,
            "strict_complementarity_failure" => failed_count > 0,
            "failed_side_count" => failed_count,
            "source" => "docs/real_99bus_phase_only_kkt_failure_summary.json",
        )
    end
    return result
end

ledger_cases = _ledger_cases(ledger)
reviewed_truth_cases = _reviewed_truth_cases(read_summary(
    "docs/real_99bus_phase_only_kkt_failure_summary.json",
))
trace_pairs = _trace_pairs(comparison)
for scope_comparison in scope_comparisons
    merge!(trace_pairs, _trace_pairs(scope_comparison))
end
readiness = get(comparison, "trace_comparison_readiness", Dict())
if !isempty(scope_comparisons)
    scope_readinesses = [get(scope, "trace_comparison_readiness", Dict()) for scope in scope_comparisons]
    readiness = Dict{String,Any}(
        "comparison_ready" => all(get(candidate, "comparison_ready", false) === true
            for candidate in [readiness; scope_readinesses]),
        "environment_fingerprint_match" => all(get(candidate, "environment_fingerprint_match", false) === true
            for candidate in [readiness; scope_readinesses]),
        "case_pairing_complete" => all(get(candidate, "case_pairing_complete", false) === true
            for candidate in [readiness; scope_readinesses]),
        "trace_availability_complete" => all(get(candidate, "trace_availability_complete", false) === true
            for candidate in [readiness; scope_readinesses]),
        "paired_trace_count" => sum(get(candidate, "paired_trace_count", 0)
            for candidate in [readiness; scope_readinesses]),
        "scope_comparison_count" => length(scope_comparisons),
    )
end
validated = Dict{String,Any}[]
for (name, expected) in EXPECTED_CASES
    ledger_case = get(ledger_cases, name, nothing)
    reviewed_case = get(reviewed_truth_cases, name, nothing)
    pair = get(trace_pairs, name, nothing)
    observed_case = ledger_case isa AbstractDict ? ledger_case : reviewed_case
    observed_regime = ledger_case isa AbstractDict ? get(ledger_case, "regime", nothing) : nothing
    physical_acceptance = observed_case isa AbstractDict ?
        get(observed_case, "physical_kkt_acceptance_passed", nothing) : nothing
    strict_count = ledger_case isa AbstractDict ?
        get(ledger_case, "strict_complementarity_passed_count", nothing) : nothing
    row_count = ledger_case isa AbstractDict ? get(ledger_case, "row_count", nothing) : nothing
    strict_failure = reviewed_case isa AbstractDict ?
        get(reviewed_case, "strict_complementarity_failure", nothing) :
        (strict_count isa Integer && row_count isa Integer ? strict_count < row_count : nothing)
    expected_regime = get(expected, "regime", nothing)
    expected_physical = get(expected, "expected_physical_kkt_acceptance_passed", nothing)
    expected_failure = get(expected, "expected_strict_complementarity_failure", nothing)
    availability = pair isa AbstractDict ? get(pair, "availability_relation", nothing) : nothing
    label_match = (isnothing(expected_regime) || observed_regime == expected_regime) &&
        (isnothing(expected_physical) || physical_acceptance == expected_physical) &&
        (isnothing(expected_failure) || strict_failure == expected_failure)
    push!(validated, Dict{String,Any}(
        "case" => name,
        "truth_role" => expected["truth_role"],
        "expected" => expected,
        "observed" => Dict(
            "regime" => observed_regime,
            "physical_kkt_acceptance_passed" => physical_acceptance,
            "strict_complementarity_passed_count" => strict_count,
            "row_count" => row_count,
            "strict_complementarity_failure" => strict_failure,
        ),
        "trace_availability_relation" => availability,
        "label_match" => label_match,
        "trace_pair_present" => pair isa AbstractDict,
        "trace_available_on_both_sides" => availability == "both_available",
        "validated" => label_match && availability == "both_available",
    ))
end

for (name, expected) in EXPECTED_UNAVAILABLE_CASES
    pair = get(trace_pairs, name, nothing)
    push!(validated, Dict{String,Any}(
        "case" => name,
        "truth_role" => expected["truth_role"],
        "expected" => expected,
        "observed" => Dict(
            "trace_pair_present" => pair isa AbstractDict,
            "trace_availability_relation" => pair isa AbstractDict ?
                get(pair, "availability_relation", nothing) : "unavailable",
        ),
        "trace_pair_present" => pair isa AbstractDict,
        "trace_available_on_both_sides" => false,
        "unavailable_reason" => expected["reason"],
        "reviewed_outcome" => expected["reviewed_outcome"],
        "validated" => pair === nothing,
    ))
end

for (name, expected) in EXPECTED_SCOPE_CASES
    pair = get(trace_pairs, name, nothing)
    availability = pair isa AbstractDict ? get(pair, "availability_relation", nothing) : nothing
    push!(validated, Dict{String,Any}(
        "case" => name,
        "truth_role" => expected["truth_role"],
        "expected" => expected,
        "observed" => Dict(
            "trace_pair_present" => pair isa AbstractDict,
            "trace_availability_relation" => availability,
        ),
        "trace_pair_present" => pair isa AbstractDict,
        "trace_available_on_both_sides" => availability == "both_available",
        "scope_reason" => expected["reason"],
        "validated" => availability == expected["expected_trace_availability"],
    ))
end

unavailable_case_count = count(entry -> get(entry, "truth_role", nothing) == "unavailable_control", validated)
validation_passed = get(readiness, "comparison_ready", false) === true &&
    !isempty(validated) && all(get(entry, "validated", false) === true for entry in validated)
output_path = length(ARGS) >= 4 ? abspath(ARGS[end]) :
    (length(ARGS) == 3 ? abspath(ARGS[3]) : joinpath(dirname(comparison_path), "bmopf_trace_truth_label_validation.json"))
write_json(output_path, Dict{String,Any}(
    "schema_version" => "nlpdiagnostics-bmopf-trace-truth-label-validation-v1",
    "status" => validation_passed ?
        (unavailable_case_count > 0 ? "validated_with_explicit_unavailable" : "validated") : "blocked",
    "source" => Dict(
        "runner" => "benchmarks/validate_bmopf_trace_truth_labels.jl",
        "comparison_summary" => basename(comparison_path),
        "truth_ledger" => basename(ledger_path),
        "scope_comparison_summaries" => basename.(scope_comparison_paths),
        "reviewed_truth_summary" => "real_99bus_phase_only_kkt_failure_summary.json",
    ),
    "readiness" => readiness,
    "case_count" => length(validated),
    "available_case_count" => count(entry -> get(entry, "trace_available_on_both_sides", false), validated),
    "unavailable_case_count" => unavailable_case_count,
    "cases" => validated,
    "validation_passed" => validation_passed,
    "interpretation" => "Truth labels validate expected bound-regime outcomes and trace availability only; they do not rank solvers or establish causal convergence claims.",
))
println("wrote BMOPF trace truth-label validation to $output_path")
validation_passed || error("truth-label validation failed")
