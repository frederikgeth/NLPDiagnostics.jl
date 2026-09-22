module PartialPowerDiagnostics
include("power_diagnostic_report.jl")
const R=PowerDiagnosticReport
const S=R.S
const E=S.E
export diagnose_partial, markdown_partial

"""Run independent source and model checks; never accept without both contracts."""
function diagnose_partial(pm,data,reference;rebase_to=nothing,physical_tolerance=1e-8,absolute_tolerance=1e-6)
    lineage=S.check_source_loads(data,reference;rebase_to,physical_tolerance)
    model=E.CMC.checked_capacity_preflight(pm,data)
    raw=if !model.available
        (available=false,status="partial_results",reason=model.reason,lineage=lineage,model_contract=model,solver_invoked=false)
    elseif !lineage.available
        (available=false,status="source_contract_unavailable",lineage=lineage,model_contract=model,solver_invoked=false)
    elseif lineage.status=="source_mismatch"
        (available=true,status="rejected_by_source_mismatch",lineage=lineage,model_contract=model,solver_invoked=false)
    else
        # This remains the existing acceptance path. Neither a successful source
        # comparison nor a partial result bypasses any island/solver prerequisite.
        workflow=S.I.solve_with_island_preflight(pm,data;absolute_tolerance)
        (available=workflow.available,status=workflow.status,lineage=lineage,model_contract=model,workflow=workflow)
    end
    report=R.summarize_workflow(raw)
    report["model_binding_verified"]=model.available
    pushfirst!(report["stages"],Dict("name"=>"Model contract","status"=>model.available ? "matched" : "unavailable",
        "reason"=>model.available ? nothing : model.reason))
    if !model.available
        report["headline"]="Partial results; model contract unavailable"
        report["next_step"]="Review the independent source result and model-scope reason. No solver acceptance is authorized."
        for f in report["findings"]
            f["binding"]="supplied_data_only"
            f["interpretation"]="Disagreement in supplied load data. Correspondence to the actual backend is unverified; no model-infeasibility claim."
        end
        push!(report["limits"],"Source findings concern supplied data only while the model contract is unavailable.")
    end
    report
end
function markdown_partial(report)
    text=R.markdown_report(report)
    report["model_binding_verified"] ? text : replace(text,", model "=>", supplied data ")
end
end
