using JSON, SHA
include(joinpath(@__DIR__,"common.jl"))
using .NLPDiagnosticsBenchmarkCommon
include(joinpath(@__DIR__,"power_repair_pilot","capacity_preflight.jl"))
using .PowerCapacityPreflight
root=repo_root()
input=joinpath(root,"work","power-repair-case14-capacity")
output=joinpath(root,"work","capacity-preflight-followup")
freeze=JSON.parsefile(joinpath(root,"docs","power_repair_case14_freeze.json"))
for (path,expected) in freeze["file_sha256"]
    bytes2hex(sha256(read(joinpath(root,path))))==expected || error("old frozen input changed: $path")
end
old_evaluation=JSON.parsefile(joinpath(input,"evaluation.json"))
records=Any[]
for id in ("clean","shortage_inherited_start","shortage_bounded_start")
    path=joinpath(input,id,"modified_data.json")
    data=JSON.parsefile(path)
    result=capacity_preflight(data;contract=:closed_acp_fixed_load)
    old=only(filter(r->r["id"]==id,old_evaluation["records"]))
    restored=capacity_preflight(JSON.parsefile(joinpath(input,id,"repaired_data.json"));contract=:closed_acp_fixed_load)
    push!(records,Dict("id"=>id,"preflight"=>result,"repaired_preflight"=>restored,
        "input_sha256"=>bytes2hex(sha256(read(path))),
        "frozen_static_error_count"=>old["static_error_count"],
        "frozen_capacity_witness"=>old["witness"]))
end
source_hashes=Dict(relpath(p,root)=>bytes2hex(sha256(read(p))) for p in
    [@__FILE__,joinpath(@__DIR__,"power_repair_pilot","capacity_preflight.jl")])
write_json(joinpath(output,"summary.json"),Dict("schema_version"=>"capacity-preflight-followup-v1",
    "scope"=>"post-evaluation data-aware follow-up on exposed case14; not held-out",
    "source_hashes"=>source_hashes,"frozen_evaluation_sha256"=>bytes2hex(sha256(read(joinpath(input,"evaluation.json")))),
    "frozen_criteria_met"=>old_evaluation["criteria_met"],"records"=>records,
    "interpretation"=>"The caller declares standard closed ACP equations and fixed unsheddable loads. This checks data conditions, not implementation of those equations in a backend. Not_ruled_out is not feasibility."))
println("Wrote capacity preflight follow-up to ",output)
