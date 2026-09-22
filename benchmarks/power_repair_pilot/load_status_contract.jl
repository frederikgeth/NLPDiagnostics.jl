module LoadStatusContract
include("partial_power_diagnostics.jl")
const P=PartialPowerDiagnostics
const S=P.S
const E=P.E
export check_load_status_contract, diagnose_with_load_status

nonempty(x)=x isa AbstractString && !isempty(strip(x))
status_value(x)=x isa Integer && !(x isa Bool) && x in (0,1) ? Int(x) : error("status must be integer 0 or 1")
"""
Validate caller-selected nominal load allocation and an ordered switching ledger.
Every nominal record starts active. Each transition requires a unique event ID,
reason, and evidence reference. All nominal loads remain present even when off.
"""
function check_load_status_contract(data,reference,contract;rebase_to=nothing,physical_tolerance=1e-8)
    try
        contract=deepcopy(contract) # Evidence must not alias the caller's mutable event records.
        contract["source_sha256"]==reference.sha256 || error("switching contract refers to a different source")
        nonempty(contract["source_revision"]) || error("source revision required")
        nominal=contract["nominal_loads"]
        Set(keys(nominal))==Set(keys(data["load"])) || error("load records missing, added, or ambiguously mapped")
        tau=P.S.I.T.tolerance(physical_tolerance)
        base=E.exact(data["baseMVA"])
        states=Dict(id=>1 for id in keys(nominal));seen=Set{String}();events=Any[]
        for event in contract["events"]
            id=event["load_id"];haskey(states,id) || error("event references unknown load")
            key=event["event_id"]
            nonempty(key) && !(key in seen) || error("event IDs must be nonempty and unique")
            nonempty(event["reason"]) && nonempty(event["evidence_ref"]) || error("event reason and evidence reference required")
            before=status_value(event["from"]);after=status_value(event["to"])
            before==states[id] && before!=after || error("transition chain is inconsistent or has no state change")
            states[id]=after;push!(seen,key);push!(events,event)
        end
        # Check nominal amounts, including inactive records, against the source.
        # A switch cannot authorize changing, zeroing, or deleting nominal demand.
        active_copy=deepcopy(data);allocation=Any[]
        for id in sort!(collect(keys(nominal)))
            record=nominal[id];load=data["load"][id]
            record["bus"] isa Integer && !(record["bus"] isa Bool) || error("nominal bus must be an integer")
            Int(load["load_bus"])==record["bus"] || error("load-to-bus mapping changed")
            status_value(load["status"])==states[id] || error("model status lacks a matching switching history")
            for (field,source_field) in (("pd","pd_mw"),("qd","qd_mvar"))
                expected=E.exact(record[source_field]);actual=E.exact(load[field])*base
                abs(actual-expected)<=tau || error("nominal allocation changed for load $id/$field")
            end
            active_copy["load"][id]["status"]=1
            push!(allocation,(load_id=id,bus=record["bus"],status=states[id],
                nominal_pd_exact_mw=string(E.exact(record["pd_mw"])),nominal_qd_exact_mvar=string(E.exact(record["qd_mvar"]))))
        end
        source=S.check_source_loads(active_copy,reference;rebase_to,physical_tolerance)
        source.available || return source
        source.status=="source_consistent" || return source
        # Existing source evidence describes NOMINAL totals. Explicitly preserve
        # that scope: it must never be presented as active-load agreement.
        merge(source,(comparison_scope="nominal_loads_before_declared_switching",
            source_revision=contract["source_revision"],nominal_allocation=allocation,switching_events=events,
            disabled_load_ids=sort!([id for (id,s) in states if s==0]),
            limitation="Consistency with caller-selected nominal allocation and switching history, not authentication of authorization or evidence references. Inactive nominal records are retained. No DC, generator/branch-unit, or operational-safety claim."))
    catch e
        e isa InterruptException && rethrow()
        (available=false,status="unavailable",reason=sprint(showerror,e))
    end
end
function diagnose_with_load_status(pm,data,reference,contract;rebase_to=nothing,physical_tolerance=1e-8,absolute_tolerance=1e-6)
    lineage=check_load_status_contract(data,reference,contract;rebase_to,physical_tolerance)
    model=E.CMC.checked_capacity_preflight(pm,data)
    raw=if !model.available
        (available=false,status="partial_results",reason=model.reason,lineage=lineage,model_contract=model,solver_invoked=false)
    elseif !lineage.available
        (available=false,status="source_contract_unavailable",lineage=lineage,model_contract=model,solver_invoked=false)
    elseif lineage.status=="source_mismatch"
        (available=true,status="rejected_by_source_mismatch",lineage=lineage,model_contract=model,solver_invoked=false)
    else
        workflow=S.I.solve_with_island_preflight(pm,data;absolute_tolerance)
        (available=workflow.available,status=workflow.status,lineage=lineage,model_contract=model,workflow=workflow)
    end
    report=P.R.summarize_workflow(raw)
    report["model_binding_verified"]=model.available
    report["load_comparison_scope"]=get(lineage,:comparison_scope,"unavailable_or_nominal_source_mismatch")
    pushfirst!(report["stages"],Dict("name"=>"Model contract","status"=>model.available ? "matched" : "unavailable","reason"=>model.available ? nothing : model.reason))
    report["stages"][2]["name"]="Nominal loads and switching history"
    if lineage.available && lineage.status=="source_consistent"
        disabled=get(lineage,:disabled_load_ids,String[])
        report["stages"][2]["reason"]="Nominal amounts agree within tolerance; declared inactive load IDs: "*(isempty(disabled) ? "none" : join(disabled,", "))
    end
    push!(report["limits"],"Source comparison concerns nominal loads before declared switching; the event ledger is caller-selected, not authenticated authorization.")
    if !model.available
        report["headline"]="Partial results; model contract unavailable"
        report["next_step"]="Inspect the separate model-scope and switching-contract results. No solver acceptance is authorized."
        for f in report["findings"];f["binding"]="supplied_data_only";end
    end
    report
end
end
