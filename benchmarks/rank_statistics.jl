module RankCalibrationStatistics

export summarize_records

rate(n, d) = d == 0 ? nothing : n / d

function checked_rank(value, maximum_rank, label)
    value isa Integer && !(value isa Bool) && 0 <= value <= maximum_rank ||
        throw(ArgumentError("$label must be an integer in 0:$maximum_rank"))
    return Int(value)
end

function backend_counts(records, backend)
    hard = filter(r -> r["hard_expectation"], records)
    positives = filter(r -> r["truth_positive"], hard)
    negatives = filter(r -> !r["truth_positive"], hard)
    available_positive = filter(r -> r[backend]["available"], positives)
    available_negative = filter(r -> r[backend]["available"], negatives)
    fp = count(r -> r[backend]["predicted_positive"], available_negative)
    fn = count(r -> !r[backend]["predicted_positive"], available_positive)
    return Dict{String,Any}(
        "record_count" => length(hard),
        "truth_positive_count" => length(positives),
        "truth_negative_count" => length(negatives),
        "available_positive_count" => length(available_positive),
        "available_negative_count" => length(available_negative),
        "unavailable_positive_count" => length(positives) - length(available_positive),
        "unavailable_negative_count" => length(negatives) - length(available_negative),
        "false_positive_count" => fp, "false_negative_count" => fn,
        "false_positive_rate_among_available" => rate(fp, length(available_negative)),
        "false_negative_rate_among_available" => rate(fn, length(available_positive)),
        "rank_mismatch_count" => count(r -> r[backend]["available"] && !r[backend]["rank_matches"], hard),
    )
end

function counts(records)
    hard = filter(r -> r["hard_expectation"], records)
    threshold = filter(r -> !r["hard_expectation"], records)
    complete(r) = r["dense"]["available"] && r["sparse"]["available"]
    mismatch(r) = any(r[b]["available"] && !r[b]["rank_matches"] for b in ("dense", "sparse"))
    dense = backend_counts(records, "dense")
    sparse = backend_counts(records, "sparse")
    hard_counts = Dict{String,Any}(
        "record_count" => length(hard),
        "truth_positive_count" => count(r -> r["truth_positive"], hard),
        "truth_negative_count" => count(r -> !r["truth_positive"], hard),
        "false_positive_count" => dense["false_positive_count"] + sparse["false_positive_count"],
        "false_negative_count" => dense["false_negative_count"] + sparse["false_negative_count"],
        "classification_count_unit" => "backend evaluations; use backend-specific class denominators for rates",
        "record_count_scope" => "Mismatch and unavailable counts are per record and can overlap; agreement requires both backends available and matching the oracle.",
        "mismatch_count" => count(mismatch, hard),
        "unavailable_count" => count(r -> !complete(r), hard),
        "dense_sparse_complete_count" => count(complete, hard),
        "agreement_count" => count(r -> complete(r) && !mismatch(r), hard),
        "all_match_and_available" => all(r -> complete(r) && !mismatch(r), hard),
        "backends" => Dict("dense" => dense, "sparse" => sparse),
    )
    threshold_counts = Dict{String,Any}(
        "record_count" => length(threshold),
        "backend_disagreement_count" => count(r -> complete(r) && r["dense"]["rank"] != r["sparse"]["rank"], threshold),
        "backend_agreement_count" => count(r -> complete(r) && r["dense"]["rank"] == r["sparse"]["rank"], threshold),
        "unavailable_count" => count(r -> !complete(r), threshold),
        "interpretation" => "Threshold-sensitive records describe numerical policy disagreement, not detector error.",
    )
    return hard_counts, threshold_counts
end

"""Descriptive per-record accounting, with rank deficiency as the positive class.

Rank deficiency means rank < min(rows, columns). Exact-rank errors within the
deficient class remain mismatches even when binary classification is correct.
Unavailable results have their own class counts and never count as successes.
Duplicate corpus/name identities are rejected. Related matrix families and
repeated policies are not assumed to be independent deployment samples.
"""
function summarize_records(corpora::AbstractDict)
    records = Dict{String,Any}[]
    seen = Set{Tuple{String,String}}()
    for corpus in sort!(collect(keys(corpora))), raw in corpora[corpus]
        name = String(raw["name"])
        identity = (String(corpus), name)
        identity in seen && throw(ArgumentError("duplicate rank record: $identity"))
        push!(seen, identity)
        dimensions = (raw["rows"], raw["columns"])
        all(x -> x isa Integer && !(x isa Bool) && x >= 0, dimensions) ||
            throw(ArgumentError("invalid dimensions for $identity"))
        maximum_rank = min(dimensions...)
        expected = checked_rank(raw["policy_expected_rank"], maximum_rank, "expected rank")
        hard = raw["hard_expectation"]
        hard isa Bool || throw(ArgumentError("hard_expectation must be Boolean"))
        record = Dict{String,Any}(
            "corpus" => corpus, "name" => name,
            "family" => get(raw, "case", get(raw, "oracle_class", name)),
            "seed" => get(raw, "seed", nothing),
            "rows" => dimensions[1], "columns" => dimensions[2],
            "relative_tolerance" => get(raw, "relative_tolerance", nothing),
            "hard_expectation" => hard, "truth_rank" => hard ? expected : nothing,
            "policy_expected_rank" => expected,
            "truth_positive" => hard ? expected < maximum_rank : nothing,
            "truth_scope" => "Declared construction/policy oracle; not independent certification of represented matrix rank.",
        )
        for backend in ("dense", "sparse")
            available = raw[backend * "_available"]
            available isa Bool || throw(ArgumentError("backend availability must be Boolean"))
            rank = available ? checked_rank(raw[backend * "_rank"], maximum_rank, "$backend rank") : nothing
            record[backend] = Dict{String,Any}(
                "available" => available, "rank" => rank,
                "rank_matches" => available && hard ? rank == expected : nothing,
                "predicted_positive" => available ? rank < maximum_rank : nothing,
            )
        end
        push!(records, record)
    end
    hard, threshold = counts(records)
    by_corpus = Dict{String,Any}()
    for corpus in sort!(collect(keys(corpora)))
        h, t = counts(filter(r -> r["corpus"] == corpus, records))
        by_corpus[corpus] = Dict("hard_controls" => h, "threshold_sensitive_controls" => t)
    end
    return Dict{String,Any}(
        "schema_version" => "nlpdiagnostics-rank-record-accounting-v1",
        "positive_class" => "rank < min(rows, columns)",
        "hard_controls" => hard, "threshold_sensitive_controls" => threshold,
        "by_corpus" => by_corpus, "records" => records,
        "finite_sample_uncertainty" => Dict{String,Any}(
            "available" => false, "confidence_level" => nothing,
            "zero_event_upper_bound" => nothing,
            "reason" => "Selected and related calibration cases have no specified independent deployment sampling design. Counts and class-specific empirical rates are descriptive only.",
        ),
    )
end

end
