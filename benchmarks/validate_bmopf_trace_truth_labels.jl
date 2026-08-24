#!/usr/bin/env julia

"""Validate trace coverage against truth-labelled 30-bus bound-regime controls.

This runner joins the solver-trace comparison with the independently reviewed
`ibr_p_upper` bound-regime ledger. It checks expected positive and negative
control outcomes without converting the labels into a solver score.
"""

using JSON

Base.include(@__MODULE__, joinpath(@__DIR__, "common.jl"))
using .NLPDiagnosticsBenchmarkCommon: read_summary, write_json

length(ARGS) in (2, 3) || error(
    "usage: validate_bmopf_trace_truth_labels.jl <comparison.json> <ledger.json> [output.json]",
)

comparison_path, ledger_path = abspath.(ARGS[1:2])
comparison = read_summary(comparison_path; root = "/")
ledger = read_summary(ledger_path; root = "/")

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
)

const EXPECTED_UNAVAILABLE_CASES = Dict{String,Dict{String,Any}}(
    case_key("ENWLsnapshots/99bus_LN/99bus_LN_t01_0800.bmopf.json") => Dict(
        "truth_role" => "unavailable_control",
        "expected_trace_availability" => "unavailable",
        "reason" => "99-bus trace collection is outside the four-case calibration campaign",
    ),
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

ledger_cases = _ledger_cases(ledger)
trace_pairs = _trace_pairs(comparison)
readiness = get(comparison, "trace_comparison_readiness", Dict())
validated = Dict{String,Any}[]
for (name, expected) in EXPECTED_CASES
    ledger_case = get(ledger_cases, name, nothing)
    pair = get(trace_pairs, name, nothing)
    observed_regime = ledger_case isa AbstractDict ? get(ledger_case, "regime", nothing) : nothing
    physical_acceptance = ledger_case isa AbstractDict ?
        get(ledger_case, "physical_kkt_acceptance_passed", nothing) : nothing
    strict_count = ledger_case isa AbstractDict ?
        get(ledger_case, "strict_complementarity_passed_count", nothing) : nothing
    row_count = ledger_case isa AbstractDict ? get(ledger_case, "row_count", nothing) : nothing
    strict_failure = strict_count isa Integer && row_count isa Integer ? strict_count < row_count : nothing
    availability = pair isa AbstractDict ? get(pair, "availability_relation", nothing) : nothing
    label_match = observed_regime == expected["regime"] &&
        physical_acceptance == expected["expected_physical_kkt_acceptance_passed"] &&
        strict_failure == expected["expected_strict_complementarity_failure"]
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
        "validated" => pair === nothing,
    ))
end

validation_passed = get(readiness, "comparison_ready", false) === true &&
    !isempty(validated) && all(get(entry, "validated", false) === true for entry in validated)
output_path = length(ARGS) == 3 ? abspath(ARGS[3]) : joinpath(dirname(comparison_path), "bmopf_trace_truth_label_validation.json")
write_json(output_path, Dict{String,Any}(
    "schema_version" => "nlpdiagnostics-bmopf-trace-truth-label-validation-v1",
    "status" => validation_passed ? "validated_with_explicit_unavailable" : "blocked",
    "source" => Dict(
        "runner" => "benchmarks/validate_bmopf_trace_truth_labels.jl",
        "comparison_summary" => basename(comparison_path),
        "truth_ledger" => basename(ledger_path),
    ),
    "readiness" => readiness,
    "case_count" => length(validated),
    "available_case_count" => count(entry -> get(entry, "trace_available_on_both_sides", false), validated),
    "unavailable_case_count" => count(entry -> get(entry, "truth_role", nothing) == "unavailable_control", validated),
    "cases" => validated,
    "validation_passed" => validation_passed,
    "interpretation" => "Truth labels validate expected bound-regime outcomes and trace availability only; they do not rank solvers or establish causal convergence claims.",
))
println("wrote BMOPF trace truth-label validation to $output_path")
validation_passed || error("truth-label validation failed")
