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
