# Reporting dimensions are independent: severity is not epistemic confidence.
@enum Severity::UInt8 begin
    SeverityInfo = 0
    SeverityWarning = 1
    SeverityError = 2
end

@enum Confidence::UInt8 begin
    ConfidenceLow = 0
    ConfidenceMedium = 1
    ConfidenceHigh = 2
    ConfidenceCertain = 3
end

"""
The epistemic basis of a finding.

This is deliberately separate from `Confidence`. For example, a physical
expectation may have high confidence without being a mathematical proof.
"""
@enum EvidenceBasis::UInt8 begin
    MathematicalProof = 0
    StructuralProof = 1
    PhysicalExpectation = 2
    NumericalObservation = 3
    LocalInference = 4
    HeuristicInterpretation = 5
end

"""
The primary nature of the issue, answering whether it is mathematical,
numerical, physical, or representational.
"""
@enum IssueDomain::UInt8 begin
    MathematicalIssue = 0
    NumericalIssue = 1
    PhysicalIssue = 2
    RepresentationalIssue = 3
end

"""
Typed explanation for an unavailable capability or bounded computation.

This record is the stable internal schema for future unavailable-result
adapters. Existing numerical result structs retain their historical string
`reason` fields for compatibility; adapters can progressively attach this
typed record at report boundaries without changing those positional layouts.
"""
struct UnavailableReason
    code::Symbol
    category::Symbol
    message::String
    stage::Union{Nothing,Symbol}
    exception_type::Union{Nothing,String}
end

function UnavailableReason(
    message::AbstractString;
    code::Symbol = :unavailable,
    category::Symbol = :capability,
    stage::Union{Nothing,Symbol} = nothing,
    exception_type::Union{Nothing,AbstractString} = nothing,
)
    isempty(message) && throw(ArgumentError("unavailable message must not be empty"))
    category in (:capability, :work_guard, :dependency, :domain, :numerical, :input) ||
        throw(ArgumentError("unsupported unavailable category: $category"))
    return UnavailableReason(
        code,
        category,
        String(message),
        stage,
        isnothing(exception_type) ? nothing : String(exception_type),
    )
end

Base.string(reason::UnavailableReason) = reason.message

"""Return the renderer-neutral schema for one typed unavailable reason."""
function unavailable_reason_data(reason::UnavailableReason)
    return Dict{String,Any}(
        "schema_version" => "nlpdiagnostics-unavailable-reason-v1",
        "code" => string(reason.code),
        "category" => string(reason.category),
        "message" => reason.message,
        "stage" => isnothing(reason.stage) ? nothing : string(reason.stage),
        "exception_type" => reason.exception_type,
    )
end

"""
    unavailable_reason(result; code = :unavailable, category = :capability,
                       stage = nothing)

Adapt an availability-bearing result with `available` and `reason` fields to
the typed schema. Available results return `nothing`; unavailable results
retain their original reason text while gaining stable classification fields.
This adapter deliberately avoids changing the positional layout of legacy
numerical result structs.
"""
function unavailable_reason(
    result;
    code::Symbol = :unavailable,
    category::Symbol = :capability,
    stage::Union{Nothing,Symbol} = nothing,
)
    hasproperty(result, :available) && hasproperty(result, :reason) ||
        throw(ArgumentError("result must expose available and reason fields"))
    getproperty(result, :available) && return nothing
    raw_reason = getproperty(result, :reason)
    message = isnothing(raw_reason) ?
        "result is unavailable without a reason" : string(raw_reason)
    return UnavailableReason(
        message;
        code,
        category,
        stage,
    )
end

struct EntityRef
    kind::Symbol
    index::Int
    subindex::Union{Nothing,Int}
    name::Union{Nothing,String}
    function_type::Union{Nothing,String}
    set_type::Union{Nothing,String}
end

EntityRef(
    kind::Symbol,
    index::Int,
    name::Union{Nothing,String},
    function_type::Union{Nothing,String},
    set_type::Union{Nothing,String},
) = EntityRef(kind, index, nothing, name, function_type, set_type)

function EntityRef(
    kind::Symbol,
    index::Integer;
    subindex::Union{Nothing,Integer} = nothing,
    name::Union{Nothing,AbstractString} = nothing,
    function_type::Union{Nothing,AbstractString} = nothing,
    set_type::Union{Nothing,AbstractString} = nothing,
)
    return EntityRef(
        kind,
        Int(index),
        isnothing(subindex) ? nothing : Int(subindex),
        isnothing(name) ? nothing : String(name),
        isnothing(function_type) ? nothing : String(function_type),
        isnothing(set_type) ? nothing : String(set_type),
    )
end

"""
An inspectable piece of evidence supporting a finding.

`details` intentionally uses printable string pairs so reports remain stable,
serializable, and suitable for terminal, Markdown, and JSON renderers.
"""
struct Evidence
    summary::String
    details::Vector{Pair{String,String}}
end

function Evidence(
    summary::AbstractString;
    details::AbstractVector{<:Pair} = Pair{String,String}[],
)
    normalized = Pair{String,String}[
        string(first(item)) => string(last(item)) for item in details
    ]
    return Evidence(String(summary), normalized)
end

struct Finding
    code::Symbol
    severity::Severity
    domain::IssueDomain
    basis::EvidenceBasis
    confidence::Confidence
    observation::String
    why_it_matters::String
    evidence::Vector{Evidence}
    suggested_actions::Vector{String}
    affected::Vector{EntityRef}
end

function Finding(
    code::Symbol;
    severity::Severity,
    domain::IssueDomain,
    basis::EvidenceBasis,
    confidence::Confidence,
    observation::AbstractString,
    why_it_matters::AbstractString,
    evidence::AbstractVector{Evidence} = Evidence[],
    suggested_actions::AbstractVector{<:AbstractString} = String[],
    affected::AbstractVector{EntityRef} = EntityRef[],
)
    isempty(observation) && throw(ArgumentError("observation must not be empty"))
    isempty(why_it_matters) &&
        throw(ArgumentError("why_it_matters must not be empty"))
    return Finding(
        code,
        severity,
        domain,
        basis,
        confidence,
        String(observation),
        String(why_it_matters),
        collect(evidence),
        String.(suggested_actions),
        collect(affected),
    )
end

struct DiagnosticReport
    findings::Vector{Finding}
    metadata::Dict{Symbol,String}
end

DiagnosticReport() = DiagnosticReport(Finding[], Dict{Symbol,String}())

function Base.push!(report::DiagnosticReport, finding::Finding)
    push!(report.findings, finding)
    return report
end

Base.isempty(report::DiagnosticReport) = isempty(report.findings)
Base.length(report::DiagnosticReport) = length(report.findings)
Base.iterate(report::DiagnosticReport, state...) =
    iterate(report.findings, state...)

"""
    findings(report; code = nothing, severity = nothing, domain = nothing, basis = nothing, confidence = nothing)

Return findings satisfying every supplied classification filter. The returned
vector is independent of the report's storage and may be safely reordered by a
caller.
"""
function findings(
    report::DiagnosticReport;
    code::Union{Nothing,Symbol} = nothing,
    severity::Union{Nothing,Severity} = nothing,
    domain::Union{Nothing,IssueDomain} = nothing,
    basis::Union{Nothing,EvidenceBasis} = nothing,
    confidence::Union{Nothing,Confidence} = nothing,
)
    return Finding[
        finding for finding in report.findings if
        (isnothing(code) || finding.code == code) &&
        (isnothing(severity) || finding.severity == severity) &&
        (isnothing(domain) || finding.domain == domain) &&
        (isnothing(basis) || finding.basis == basis) &&
        (isnothing(confidence) || finding.confidence == confidence)
    ]
end

findings(report::DiagnosticReport, code::Symbol) = findings(report; code = code)

"""Return deterministic per-code finding counts for one diagnostic report."""
function finding_code_counts(report::DiagnosticReport)
    counts = Dict{Symbol,Int}()
    for finding in report.findings
        counts[finding.code] = get(counts, finding.code, 0) + 1
    end
    return Dict(code => counts[code] for code in sort!(collect(keys(counts)); by = string))
end

_report_enum_label(value::Severity) = Dict(
    SeverityInfo => "info",
    SeverityWarning => "warning",
    SeverityError => "error",
)[value]

_report_enum_label(value::Confidence) = Dict(
    ConfidenceLow => "low",
    ConfidenceMedium => "medium",
    ConfidenceHigh => "high",
    ConfidenceCertain => "certain",
)[value]

_report_enum_label(value::EvidenceBasis) = Dict(
    MathematicalProof => "mathematical_proof",
    StructuralProof => "structural_proof",
    PhysicalExpectation => "physical_expectation",
    NumericalObservation => "numerical_observation",
    LocalInference => "local_inference",
    HeuristicInterpretation => "heuristic_interpretation",
)[value]

_report_enum_label(value::IssueDomain) = Dict(
    MathematicalIssue => "mathematical",
    NumericalIssue => "numerical",
    PhysicalIssue => "physical",
    RepresentationalIssue => "representational",
)[value]

"""Return a renderer-neutral, serializable representation of one affected entity."""
function entity_data(entity::EntityRef)
    return Dict{String,Any}(
        "kind" => string(entity.kind),
        "index" => entity.index,
        "subindex" => entity.subindex,
        "name" => entity.name,
        "function_type" => entity.function_type,
        "set_type" => entity.set_type,
    )
end

"""Return a renderer-neutral, serializable representation of one evidence item."""
function evidence_data(evidence::Evidence)
    return Dict{String,Any}(
        "summary" => evidence.summary,
        "details" => Dict(detail for detail in evidence.details),
    )
end

"""Return a renderer-neutral, serializable representation of one finding."""
function finding_data(finding::Finding)
    return Dict{String,Any}(
        "code" => string(finding.code),
        "severity" => _report_enum_label(finding.severity),
        "domain" => _report_enum_label(finding.domain),
        "basis" => _report_enum_label(finding.basis),
        "confidence" => _report_enum_label(finding.confidence),
        "observation" => finding.observation,
        "why_it_matters" => finding.why_it_matters,
        "evidence" => [evidence_data(item) for item in finding.evidence],
        "suggested_actions" => copy(finding.suggested_actions),
        "affected" => [entity_data(entity) for entity in finding.affected],
    )
end

function _report_unavailable_reason_data(metadata::Dict{String,String})
    records = Dict{String,Any}[]
    for availability_key in sort!(collect(keys(metadata)))
        endswith(availability_key, "_available") || continue
        metadata[availability_key] == "false" || continue
        stem = availability_key[1:(end - length("_available"))]
        reason_key = stem * "_reason"
        reason = get(metadata, reason_key, nothing)
        if isnothing(reason) || isempty(reason)
            continue
        end
        stage_text = get(metadata, "stage", nothing)
        stage = isnothing(stage_text) || isempty(stage_text) ?
            nothing : Symbol(stage_text)
        typed = UnavailableReason(
            reason;
            code = Symbol(stem * "_unavailable"),
            category = :capability,
            stage,
        )
        data = unavailable_reason_data(typed)
        data["capability"] = stem
        data["availability_key"] = availability_key
        data["reason_key"] = reason_key
        push!(records, data)
    end
    return records
end

"""
    report_data(report)

Return a renderer-neutral dictionary containing all report findings and sorted
string metadata. The core package deliberately does not select a JSON package;
callers may pass this data directly to their preferred serializer.
"""
function report_data(report::DiagnosticReport)
    metadata = Dict{String,String}(
        string(key) => report.metadata[key] for key in sort!(collect(keys(report.metadata)); by = string)
    )
    return Dict{String,Any}(
        "findings" => [finding_data(finding) for finding in report.findings],
        "finding_code_counts" => Dict(
            string(code) => count for (code, count) in finding_code_counts(report)
        ),
        "metadata" => metadata,
        "unavailable_reasons" => _report_unavailable_reason_data(metadata),
    )
end
