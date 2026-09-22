module PowerDiagnosticsV2

# These implementations remain unchanged so the historical frozen evaluations
# can still be replayed. New orchestration and reporting live in this module.
include("power_repair_pilot/load_status_contract.jl")
const Legacy = LoadStatusContract
const S = Legacy.S
const E = Legacy.E
const R = Legacy.P.R

export SourceRevision, SourceLoadReference, check_load_status_contract
export diagnose_power_model, diagnose_partial, diagnose_with_load_status, markdown_report

const SourceLoadReference = S.SourceLoadReference

"""Caller-selected mapping of a current revision label to source bytes.

Matching this record establishes consistency with that selection, not
authentication of source intent, operator authorization, or evidence references.
"""
struct SourceRevision
    source_sha256::String
    current_revision::String
    function SourceRevision(source_sha256::AbstractString, current_revision::AbstractString)
        occursin(r"^[0-9a-f]{64}$", source_sha256) ||
            throw(ArgumentError("source_sha256 must be a lowercase SHA-256 digest"))
        isempty(strip(current_revision)) && throw(ArgumentError("current_revision is required"))
        new(String(source_sha256), String(current_revision))
    end
end

SourceRevision(manifest::AbstractDict) = SourceRevision(
    manifest["source_sha256"], manifest["current_revision"],
)

"""Stage schema is independent of whether this particular run has null reasons."""
struct ReportStage
    name::String
    status::String
    reason::Union{Nothing,String}
end

stage_data(stage::ReportStage) = Dict{String,Any}(
    "name" => stage.name, "status" => stage.status, "reason" => stage.reason,
)

function check_load_status_contract(data, reference, contract;
        revision=nothing, rebase_to=nothing, physical_tolerance=1e-8)
    selected = Dict{String,Any}(
        "status" => "unavailable",
        "source_sha256" => revision isa SourceRevision ? revision.source_sha256 : nothing,
        "expected_revision" => revision isa SourceRevision ? revision.current_revision : nothing,
        "reported_revision" => contract isa AbstractDict ? get(contract, "source_revision", nothing) : nothing,
        "scope" => "Consistency with a caller-selected manifest; not authenticated authorization.",
    )
    reason = if !(revision isa SourceRevision)
        "A selected SourceRevision manifest is required for switching provenance."
    elseif revision.source_sha256 != reference.sha256
        "Selected revision manifest refers to a different source hash."
    elseif !(contract isa AbstractDict) || get(contract, "source_revision", nothing) != revision.current_revision
        "Source revision does not match the selected manifest."
    else
        nothing
    end
    if !isnothing(reason)
        return (available=false, status="unavailable", reason=reason, revision_validation=selected)
    end
    selected["status"] = "matched_selected_manifest"
    result = Legacy.check_load_status_contract(data, reference, contract; rebase_to, physical_tolerance)
    # A revision match does not bypass byte verification, load allocation, or
    # switching-history checks. Retain their independent outcomes and reasons.
    return merge(result, (revision_validation=selected,))
end

function summarize_workflow(raw, model; switching=false)
    report = R.summarize_workflow(raw)
    stages = ReportStage[ReportStage(
        "Model contract", model.available ? "matched" : "unavailable",
        model.available ? nothing : model.reason,
    )]
    for stage in report["stages"]
        name = switching && stage["name"] == "Source loads" ?
            "Nominal loads and switching history" : stage["name"]
        push!(stages, ReportStage(name, stage["status"], stage["reason"]))
    end
    report["stages"] = Dict{String,Any}[stage_data(stage) for stage in stages]
    report["schema_version"] = "power-diagnostic-report-v2"
    report["model_binding_verified"] = model.available
    report["limits"] = [
        "Experimental version 2 workflow; historical frozen evaluation results are preserved separately.",
        "Verified tolerance compliance is not exact feasibility, optimality, or operational security.",
        "Source agreement covers selected bus-load totals only, not generator/branch units or authenticated intent.",
        "Not ruled out does not mean feasible; not run is distinct from unavailable.",
    ]
    if switching
        lineage = raw.lineage
        report["revision_validation"] = report["evidence"]["lineage"]["revision_validation"]
        report["load_comparison_scope"] = get(lineage, :comparison_scope, "unavailable_or_nominal_source_mismatch")
        if lineage.available && lineage.status == "source_consistent"
            disabled = get(lineage, :disabled_load_ids, String[])
            report["stages"][2]["reason"] = "Nominal amounts agree within tolerance; declared inactive load IDs: " *
                (isempty(disabled) ? "none" : join(disabled, ", "))
        end
        push!(report["limits"], "Source comparison concerns nominal loads before declared switching; the event ledger and revision manifest are caller-selected, not authenticated authorization.")
    end
    if !model.available
        report["headline"] = "Partial results; model contract unavailable"
        report["next_step"] = "Review the independent source result and model-scope reason. No solver acceptance is authorized."
        for finding in report["findings"]
            finding["binding"] = "supplied_data_only"
            finding["interpretation"] = "Disagreement in supplied load data. Correspondence to the actual backend is unverified; no model-infeasibility claim."
        end
        push!(report["limits"], "Source findings concern supplied data only while the model contract is unavailable.")
    end
    return report
end

"""Run independent source/model checks, then the unchanged island and point verifier.

Supplying a switching `load_contract` requires a separately selected `revision`.
Invalid provenance or unsupported model scope stops before invoking the solver.
"""
function diagnose_power_model(pm, data, reference; load_contract=nothing,
        revision=nothing, rebase_to=nothing, physical_tolerance=1e-8, absolute_tolerance=1e-6)
    switching = !isnothing(load_contract)
    !switching && !isnothing(revision) && throw(ArgumentError("revision requires a load_contract"))
    lineage = switching ? check_load_status_contract(data, reference, load_contract;
        revision, rebase_to, physical_tolerance) :
        S.check_source_loads(data, reference; rebase_to, physical_tolerance)
    model = E.CMC.checked_capacity_preflight(pm, data)
    raw = if !model.available
        (available=false, status="partial_results", reason=model.reason,
            lineage=lineage, model_contract=model, solver_invoked=false)
    elseif !lineage.available
        (available=false, status="source_contract_unavailable",
            lineage=lineage, model_contract=model, solver_invoked=false)
    elseif lineage.status == "source_mismatch"
        (available=true, status="rejected_by_source_mismatch",
            lineage=lineage, model_contract=model, solver_invoked=false)
    else
        workflow = S.I.solve_with_island_preflight(pm, data; absolute_tolerance)
        (available=workflow.available, status=workflow.status,
            lineage=lineage, model_contract=model, workflow=workflow)
    end
    return summarize_workflow(raw, model; switching)
end

const diagnose_partial = diagnose_power_model
diagnose_with_load_status(pm, data, reference, contract; kwargs...) =
    diagnose_power_model(pm, data, reference; load_contract=contract, kwargs...)

function markdown_report(report)
    text = R.markdown_report(report)
    if haskey(report, "revision_validation")
        revision = report["revision_validation"]
        text *= "\nRevision check: " * R.safe(revision["status"]) *
            "; selected revision: " * R.safe(revision["expected_revision"]) * ".\n"
    end
    return report["model_binding_verified"] ? text : replace(text, ", model " => ", supplied data ")
end

end
