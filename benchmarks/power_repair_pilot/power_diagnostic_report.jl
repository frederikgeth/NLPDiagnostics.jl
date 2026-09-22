module PowerDiagnosticReport
include("source_load_contract.jl")
const S=SourceLoadContract
using JSON
export diagnose_power_model, summarize_workflow, markdown_report

function summarize_workflow(raw)
    d=JSON.parse(JSON.json(raw))
    lineage=get(d,"lineage",nothing)
    workflow=get(d,"workflow",Dict())
    island=get(workflow,"preflight",nothing)
    solve=get(workflow,"solve",nothing)
    verification=isnothing(solve) ? nothing : get(solve,"verification",nothing)
    status=get(d,"status","unavailable")
    headings=Dict(
        "accepted_primal_point"=>"Returned point verified within tolerance",
        "rejected_by_source_mismatch"=>"Model loads disagree with the selected source",
        "rejected_by_island_certificate"=>"A model contradiction is certified within tolerance",
        "primal_violated"=>"Returned point violates the declared tolerance",
        "primal_inconclusive"=>"Returned-point verification is inconclusive",
        "verified_point_without_solver_success"=>"Point verified; solver did not report local success",
        "no_primal_point"=>"Solver returned no primal point")
    # Do not let a success label alone hide missing or contradictory evidence.
    if status=="accepted_primal_point"
        valid=get(d,"available",false) && get(workflow,"available",false) && !isnothing(lineage) && get(lineage,"status","")=="source_consistent" &&
            !isnothing(island) && get(island,"status","")=="not_ruled_out" &&
            !isnothing(solve) && get(solve,"termination","")=="LOCALLY_SOLVED" &&
            !isnothing(verification) && get(verification,"status","")=="satisfied" &&
            all(get(x,"available",false) for x in (lineage,island,solve,verification))
        valid || (status="invalid_evidence")
    end
    stage(name,value)=Dict("name"=>name,"status"=>isnothing(value) ? "not_run" : get(value,"status","unavailable"),
        "reason"=>isnothing(value) ? "An earlier stage stopped the workflow." : get(value,"reason",nothing))
    stages=[stage("Source loads",lineage),stage("Island capacity",island),
        Dict("name"=>"Solver","status"=>isnothing(solve) ? "not_run" : get(solve,"termination","unavailable"),
            "reason"=>isnothing(solve) ? "No solver result was produced." : get(solve,"reason",nothing)),
        stage("Returned point",verification)]
    findings=Any[]
    if !isnothing(lineage)
        for c in get(lineage,"checks",[])
            get(c,"mismatch",false) || continue
            push!(findings,Dict("kind"=>"source_mismatch","bus"=>c["bus"],"field"=>c["field"],
                "units"=>c["units"],"source_exact"=>c["source_exact"],"actual_exact"=>c["actual_exact"],"residual_exact"=>c["residual_exact"],
                "interpretation"=>"Disagreement with the selected source, not proof of model infeasibility or a specific unit-conversion bug."))
        end
    end
    if !isnothing(island)
        for component in get(island,"islands",[])
            r=component["result"]
            r["status"]=="certified_infeasible_within_tolerances" || continue
            push!(findings,Dict("kind"=>"certified_contradiction","buses"=>component["buses"],"basis"=>get(r,"basis","unknown"),
                "interpretation"=>"No point satisfies the certified subset within the declared absolute tolerances."))
        end
    end
    reason=get(d,"reason",nothing)
    if isnothing(reason) && !isnothing(lineage);reason=get(lineage,"reason",nothing);end
    if isnothing(reason) && !isnothing(island)
        reason=get(island,"reason",nothing)
        if isnothing(reason) && get(island,"status","")=="unavailable"
            reason="One or more island analyses are unavailable; inspect the preserved evidence."
        end
    end
    if isnothing(reason) && !isnothing(solve);reason=get(solve,"reason",nothing);end
    Dict("schema_version"=>"power-diagnostic-report-v1","status"=>status,
        "headline"=>get(headings,status,"Analysis unavailable; no acceptance claim"),"reason"=>reason,
        "stages"=>stages,"findings"=>findings,
        "next_step"=>status=="rejected_by_source_mismatch" ? "Review the listed bus loads and declared power base against the selected source." :
            status=="rejected_by_island_certificate" ? "Inspect the certified rows and supply/load balance within the listed islands." :
            status=="accepted_primal_point" ? "Review the operating assumptions; this result does not establish optimality or operational security." :
            "Inspect the stage reasons and preserved row evidence before changing the model.",
        "source_sha256"=>isnothing(lineage) ? nothing : get(lineage,"source_sha256",nothing),
        "source_physical_tolerance_exact"=>isnothing(lineage) ? nothing : get(lineage,"physical_tolerance_exact",nothing),
        "model_absolute_tolerance_exact"=>isnothing(island) ? nothing : get(island,"absolute_tolerance_exact",nothing),
        "checked_rows"=>isnothing(verification) ? nothing : get(verification,"checked_rows",nothing),
        "limits"=>["Experimental, post-evaluation workflow; the frozen 11/14 failure is unchanged.",
            "Verified tolerance compliance is not exact feasibility, optimality, or operational security.",
            "Source agreement covers selected bus-load totals only, not generator/branch units or authenticated intent.",
            "Not ruled out does not mean feasible; not run is distinct from unavailable."],
        "evidence"=>d)
end
function diagnose_power_model(pm,data,reference;kwargs...)
    summarize_workflow(S.solve_with_source_contract(pm,data,reference;kwargs...))
end
safe(x)=replace(string(x),'\n'=>" ",'\r'=>" ",'|'=>"\\|",'`'=>"'")
function display_number(s)
    a,b=split(s,"//");v=Float64(parse(BigInt,a)//parse(BigInt,b))
    isfinite(v) ? string(round(v;sigdigits=8)) : "outside display range; see exact evidence"
end
function markdown_report(report)
    io=IOBuffer()
    println(io,"# ",safe(report["headline"]),"\n")
    println(io,"Status: `",safe(report["status"]),"`.\n")
    isnothing(report["reason"]) || println(io,safe(report["reason"]),"\n")
    println(io,"| Check | Outcome | Details |\n| --- | --- | --- |")
    for s in report["stages"];println(io,"| ",safe(s["name"])," | ",safe(s["status"])," | ",isnothing(s["reason"]) ? "" : safe(s["reason"])," |");end
    println(io)
    for f in report["findings"]
        if f["kind"]=="source_mismatch"
            println(io,"- Bus ",safe(f["bus"]),", ",safe(f["field"]),": source ",display_number(f["source_exact"]),
                ", model ",display_number(f["actual_exact"])," ",safe(f["units"]),
                " (difference ",display_number(f["residual_exact"]),").")
        else
            println(io,"- Certified contradiction on buses ",join(f["buses"],", "),"; basis: ",safe(f["basis"]),".")
        end
    end
    println(io,"\n",report["next_step"],"\n")
    println(io,"Full values, tolerances, source identity, and original evidence: [report.json](report.json).\n")
    for limitation in report["limits"];println(io,"- ",limitation);end
    String(take!(io))
end
end
