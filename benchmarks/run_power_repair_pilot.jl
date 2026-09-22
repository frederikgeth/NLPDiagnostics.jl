const PILOT_LOAD_START=time_ns()
module PowerRepairPilot
using SHA, TOML, JSON
include(joinpath(@__DIR__, "common.jl"))
using .NLPDiagnosticsBenchmarkCommon: git_revision, git_status_entries
import PowerModels as PM
import JuMP
import MathOptInterface as MOI
import Ipopt
import NLPDiagnostics as ND
const ROOT=normpath(joinpath(@__DIR__,".."))
const ENV_DIR=joinpath(@__DIR__,"environments","power_repair_pilot")
const FIXTURE=joinpath(ROOT,"test","fixtures","power_repair_case3.m")
const FIXTURE_SHA="d2173e913ab554dd4fe6cfdcf17bcc5d3f882b769bcdfc37470cb273f0df507b"
const TOL=1e-6
include("power_repair_pilot/physics.jl")
# Deterministic serialization also preserves nonfinite extension data as tags.
function canonical(x)
    x isa AbstractDict && return "{"*join((JSON.json(string(k))*":"*canonical(x[k]) for k in sort!(collect(keys(x));by=string)),",")*"}"
    x isa AbstractArray && return "["*join(canonical.(x),",")*"]"
    x isa AbstractFloat && !isfinite(x) && return canonical(Dict("nonfinite_literal"=>string(x)))
    return JSON.json(x)
end
save(path,x)=(mkpath(dirname(path));write(path,canonical(x)*"\n");path)
digest(x)=bytes2hex(sha256(canonical(x)))
filehash(p)=bytes2hex(sha256(read(p)))
function no_reference_build(pm)
    PM.variable_bus_voltage(pm);PM.variable_gen_power(pm)
    PM.variable_branch_power(pm);PM.variable_dcline_power(pm)
    PM.objective_min_fuel_and_flow_cost(pm);PM.constraint_model_voltage(pm)
    for i in PM.ids(pm,:bus);PM.constraint_power_balance(pm,i);end
    for i in PM.ids(pm,:branch)
        PM.constraint_ohms_yt_from(pm,i);PM.constraint_ohms_yt_to(pm,i)
        PM.constraint_voltage_angle_difference(pm,i)
        PM.constraint_thermal_limit_from(pm,i);PM.constraint_thermal_limit_to(pm,i)
    end
    for i in PM.ids(pm,:dcline);PM.constraint_dcline_power_losses(pm,i);end
end
build(data;missing_reference=false)=PM.instantiate_model(deepcopy(data),PM.ACPPowerModel,missing_reference ? no_reference_build : PM.build_opf)
function checked_physics(data,solution;kwargs...)
    try
        result=physical_checks(data,solution;kwargs...)
        result["available"]=true
        return result
    catch e
        return Dict("available"=>false,"passed"=>false,"reason"=>sprint(showerror,e))
    end
end
function pointmap(pm)
    vs=JuMP.all_variables(pm.model)
    length(unique(JuMP.name.(vs)))==length(vs) || error("nonunique variable names")
    Dict(JuMP.name(v)=>JuMP.value(v) for v in vs)
end
function starts!(pm,point)
    vs=JuMP.all_variables(pm.model)
    Set(JuMP.name.(vs))==Set(keys(point)) || error("variable layout changed")
    for v in vs;JuMP.set_start_value(v,point[JuMP.name(v)]);end
end
function feasibility(pm;starts=false)
    try
        point=Dict(v=>(starts ? JuMP.start_value(v) : JuMP.value(v)) for v in JuMP.all_variables(pm.model))
        r=JuMP.primal_feasibility_report(pm.model,point;atol=TOL)
        return Dict("available"=>true,"violation_count"=>length(r),
            "violations"=>[Dict("constraint"=>string(c),"residual"=>v) for (c,v) in r])
    catch e
        return Dict("available"=>false,"reason"=>sprint(showerror,e))
    end
end
function solve!(pm,logfile)
    started=time_ns()
    try
        result=PM.optimize_model!(pm;optimizer=JuMP.optimizer_with_attributes(Ipopt.Optimizer,
            "print_level"=>0,"file_print_level"=>5,"output_file"=>logfile,
            "tol"=>1e-9,"max_iter"=>500,"max_cpu_time"=>60.0))
        return Dict("available"=>true,"termination"=>string(result["termination_status"]),
            "objective"=>get(result,"objective",nothing),"solution"=>get(result,"solution",nothing),
            "seconds"=>(time_ns()-started)/1e9,"log_file"=>logfile,
            "jump_feasibility"=>feasibility(pm))
    catch e
        return Dict("available"=>false,"reason"=>sprint(showerror,e),"seconds"=>(time_ns()-started)/1e9,"log_file"=>logfile)
    end
end
function diagnostic_stage(f)
    try
        report=f()
        return Dict("available"=>true,"report"=>report)
    catch e
        e isa InterruptException && rethrow()
        return Dict("available"=>false,"reason"=>sprint(showerror,e),"report"=>Dict("findings"=>Any[]))
    end
end
# Development ordering heuristic, not a causal certificate. Only recognized
# code/basis pairs get priority; truth, network names and incident IDs are absent.
const RANKING_POLICY = "power-repair-priority-v1"
function priority_class(f)
    code, basis = f["code"], f["basis"]
    if code == "inconsistent_variable_bounds" && basis == "mathematical_proof"
        return (0, "proven contradictory bounds")
    elseif code == "initialization_violates_variable_bounds" && basis == "mathematical_proof"
        return (1, "direct initialization bound evidence")
    elseif code == "initialization_nonfinite_value" && basis == "numerical_observation"
        return (1, "direct nonfinite initialization evidence")
    elseif code == "constraint_feasibility_violation" && basis == "numerical_observation"
        return (3, "point residual; inspect direct input evidence first")
    end
    return (2, "other error; no recognized priority rule")
end
function rank_findings(findings)
    errors = filter(f -> f["severity"] == "error", findings)
    # The last key makes ordering independent of input order even when codes
    # and affected identities coincide. Identical duplicates are retained.
    identity_key(f) = (f["code"], canonical(f["affected"]), canonical(f))
    baseline = sort(errors; by = identity_key)
    ranked = sort(errors; by = f -> (first(priority_class(f)), identity_key(f)))
    return baseline, ranked
end
function diagnose(pm)
    backend=JuMP.backend(pm.model)
    # No truth, incident identifier, or expected localization is supplied here.
    static_stage=diagnostic_stage(()->ND.report_data(ND.analyze_static(backend)))
    init_stage=diagnostic_stage(()->ND.report_data(ND.analyze_initialization(backend;check_degeneracy=false,
        check_component_ranks=false,feasibility_tolerance=TOL,active_tolerance=TOL)))
    static=static_stage["report"];init=init_stage["report"]
    findings=vcat(static["findings"],init["findings"])
    baseline, actionable=rank_findings(findings)
    Dict("static"=>static,"initialization"=>init,"ranked_actionable"=>actionable,
        "baseline_ranked_actionable"=>baseline,"ranking_policy"=>RANKING_POLICY,
        "ranking_reasons"=>[Dict("rank"=>i,"priority_class"=>first(priority_class(f)),
            "reason"=>last(priority_class(f))) for (i,f) in enumerate(actionable)],
        "available"=>static_stage["available"] && init_stage["available"],
        "stages"=>Dict("static"=>static_stage,"initialization"=>init_stage))
end
function gauge_diagnostics(pm)
    stage = diagnostic_stage() do
        pm isa PM.ACPPowerModel || error("pilot gauge configuration requires ACP")
        ac_connected(pm.data) || error("pilot gauge configuration requires a connected AC network")
        backend = JuMP.backend(pm.model)
        point = ND.initialization_point(backend)
        isnothing(point) && error("gauge comparison requires complete starts")
        evaluation = ND.evaluate_numerical(backend, point)
        automatic = ND.powermodels_angle_gauge_modes(pm, evaluation)
        indices = ND.powermodels_variable_indices(pm, :va)
        variables = [indices[k] for k in sort!(collect(keys(indices)); by=string)]
        isempty(variables) && error("no scalar angle coordinates")
        # The same candidate is tested on every variant, including the clean
        # control. Declared reference metadata does not establish its equation.
        candidate = ND.ExpectedNullspaceMode(:pilot_uniform_ac_angle_shift,
            variables, ones(length(variables));
            description="Uniform scalar-angle shift on the connected ACP network; candidate only")
        report = ND.report_data(ND.analyze_degeneracy(backend, evaluation;
            expected_modes=[candidate]))
        report["candidate"] = Dict("name"=>"pilot_uniform_ac_angle_shift",
            "variable_indices"=>[v.value for v in variables],
            "coefficients"=>ones(length(variables)),
            "source"=>"connected ACP topology and public scalar angle map; applied to every variant")
        report["automatic_candidate_count"] = length(automatic)
        report["reference_metadata_report"] = ND.report_data(ND.powermodels_reference_bus_report(pm))
        report
    end
    codes = [f["code"] for f in stage["report"]["findings"]]
    stage["outcome"] = !stage["available"] ? "unavailable" :
        "expected_nullspace_mode_observed" in codes ? "local_shift_observed" :
        "expected_nullspace_mode_not_observed" in codes ? "local_shift_not_observed" :
        "expected_nullspace_mode_unaligned" in codes ? "outside_free_coordinate_scope" : "unavailable"
    stage["interpretation"] = "local numerical candidate comparison, not proof of a missing reference equation or global symmetry"
    stage
end
# Deliberately narrow reader for the hash-pinned numeric MATPOWER fixture.
# It reads source MW/MVAr independently of PowerModels' per-unit conversion.
function source_load_ledger(path=FIXTURE)
    filehash(path)==FIXTURE_SHA || error("unsupported source fixture hash")
    source=read(path,String)
    base_match=match(r"mpc\.baseMVA\s*=\s*([0-9.eE+-]+)\s*;",source)
    buses_match=match(r"mpc\.bus\s*=\s*\[([^\]]+)\]"s,source)
    isnothing(base_match) && error("missing numeric source baseMVA")
    isnothing(buses_match) && error("missing numeric source bus table")
    base=parse(Float64,base_match.captures[1])
    isfinite(base) && base>0 || error("invalid source baseMVA")
    buses=Dict{String,Any}()
    for (row,line) in enumerate(split(strip(buses_match.captures[1]),';'))
        isempty(strip(line)) && continue
        values=parse.(Float64,split(strip(line)))
        length(values)==13 && all(isfinite,values) || error("unsupported source bus row")
        id=string(Int(values[1]))
        haskey(buses,id) && error("duplicate source bus")
        buses[id]=Dict("source_row"=>row,"pd_mw"=>values[3],"qd_mvar"=>values[4])
    end
    isempty(buses) && error("empty source bus table")
    Dict("schema_version"=>"pilot-load-lineage-v1","source_sha256"=>FIXTURE_SHA,
        "source_format"=>"pinned numeric MATPOWER bus table",
        "power_units"=>Dict("pd"=>"MW","qd"=>"MVAr"),"base_mva"=>base,"buses"=>buses)
end
function check_load_lineage(data,ledger)
    try
        ledger["source_sha256"]==FIXTURE_SHA || error("unrecognized source identity")
        ledger["power_units"]==Dict("pd"=>"MW","qd"=>"MVAr") || error("unsupported source units")
        isequal(ledger,source_load_ledger()) || error("ledger contents do not match pinned source")
        get(data,"per_unit",nothing)===true || error("per-unit declaration required")
        data["baseMVA"]==ledger["base_mva"] || error("changed power base requires explicit rebase lineage")
        source=ledger["buses"];loads=data["load"]
        mapped=Dict{String,String}()
        for (id,l) in loads
            l["status"]==1 || error("changed load status requires source lineage")
            bus=string(l["load_bus"])
            haskey(mapped,bus) && error("split loads require an aggregation lineage")
            mapped[bus]=string(id)
        end
        Set(keys(mapped))==Set(keys(source)) || error("source/load bus mapping incomplete")
        checks=Any[];mismatches=Any[]
        for bus in sort!(collect(keys(source));by=x->parse(Int,x)), (field,source_field) in (("pd","pd_mw"),("qd","qd_mvar"))
            id=mapped[bus];actual=loads[id][field]
            actual isa Real && isfinite(actual) || error("nonfinite or unsupported load value")
            expected=source[bus][source_field]/ledger["base_mva"]
            tolerance=1e-12+1e-10*abs(expected)
            row=Dict("load_id"=>id,"bus_id"=>bus,"field"=>field,
                "source_row"=>source[bus]["source_row"],"source_value"=>source[bus][source_field],
                "conversion"=>"source power divided once by source baseMVA",
                "expected_per_unit"=>expected,"actual_per_unit"=>actual,
                "absolute_residual"=>abs(actual-expected),"tolerance"=>tolerance,
                "observed_to_expected_ratio"=>iszero(expected) ? nothing : actual/expected)
            push!(checks,row)
            abs(actual-expected)>tolerance && push!(mismatches,row)
        end
        Dict("available"=>true,"outcome"=>isempty(mismatches) ? "source_consistent" : "source_mismatch",
            "checks"=>checks,"mismatches"=>mismatches,
            "source_sha256"=>ledger["source_sha256"],"ledger_sha256"=>digest(ledger),
            "interpretation"=>"consistency with recorded source, not proof of intended load or of a specific conversion bug")
    catch e
        e isa InterruptException && rethrow()
        Dict("available"=>false,"outcome"=>"unavailable","reason"=>sprint(showerror,e))
    end
end
function source_inventory()
    paths=String[]
    for folder in ("src","ext")
        for (dir,_,files) in walkdir(joinpath(ROOT,folder)), f in files
            endswith(f,".jl") && push!(paths,joinpath(dir,f))
        end
    end
    append!(paths,[joinpath(@__DIR__,"run_power_repair_pilot.jl"),joinpath(@__DIR__,"common.jl"),joinpath(@__DIR__,"power_repair_pilot","physics.jl")])
    Dict(relpath(p,ROOT)=>filehash(p) for p in sort!(paths))
end
function run(output;load_seconds=0.0,fixture=FIXTURE,fixture_sha=FIXTURE_SHA,
    scope="case3 development harness; no held-out or human repair measurements")
    VERSION==v"1.12.6" || error("pilot is pinned to Julia 1.12.6")
    realpath(Base.active_project())==realpath(joinpath(ENV_DIR,"Project.toml")) || error("use the dedicated pilot environment")
    filehash(fixture)==fixture_sha || error("fixture hash mismatch")
    mkpath(output)
    data=PM.parse_file(fixture)
    ledger=fixture_sha==FIXTURE_SHA ? source_load_ledger(fixture) : nothing
    lineage_check(d)=isnothing(ledger) ? Dict("available"=>false,"outcome"=>"unavailable",
        "reason"=>"frozen load-lineage policy supports only the case3 fixture") : check_load_lineage(d,ledger)
    save(joinpath(output,"source_load_ledger.json"),ledger)
    manifest=TOML.parsefile(joinpath(ENV_DIR,"Manifest.toml"))
    save(joinpath(output,"source_hashes.json"),source_inventory())
    cp(fixture,joinpath(output,fixture_sha==FIXTURE_SHA ? "case3.m" : "network.m");force=true)
    for f in ("Project.toml","Manifest.toml");cp(joinpath(ENV_DIR,f),joinpath(output,f);force=true);end
    save(joinpath(output,"original_data.json"),data)
    println("Solving and independently checking baseline")
    base=build(data);baseline=solve!(base,joinpath(output,"baseline-ipopt.log"))
    baseline["available"] || error("baseline solve unavailable")
    checks=physical_checks(data,baseline["solution"])
    save(joinpath(output,"baseline.json"),Dict("solve"=>baseline,"physical_checks"=>checks))
    checks["passed"] || error("baseline independent physical check failed")
    point=pointmap(base);save(joinpath(output,"original_point.json"),point)
    starts!(base,point)
    cold=@timed diagnose(base)
    save(joinpath(output,"cold_diagnostics.json"),cold.value)
    bus=first(sort!(collect(keys(data["bus"]));by=x->parse(Int,x)))
    load=first(sort!(collect(keys(data["load"]));by=x->parse(Int,x)))
    records=Any[]
    for id in ("clean","voltage_bound","missing_reference","voltage_start","power_units")
        println("Pilot variant: ",id)
        dir=joinpath(output,id);mkpath(dir)
        modified=deepcopy(data);patch=Dict{String,Any}();missing_ref=id=="missing_reference"
        if id=="voltage_bound"
            old=modified["bus"][bus]["vmin"];new=modified["bus"][bus]["vmax"]+0.1
            modified["bus"][bus]["vmin"]=new
            patch=Dict("path"=>["bus",bus,"vmin"],"before"=>old,"after"=>new)
        elseif id=="power_units"
            old=modified["load"][load]["pd"];new=old/modified["baseMVA"]
            modified["load"][load]["pd"]=new
            patch=Dict("path"=>["load",load,"pd"],"before"=>old,"after"=>new,"meaning"=>"erroneous second division by baseMVA")
        elseif missing_ref
            patch=Dict("builder_reference_constraints"=>"omitted","original"=>"PowerModels.build_opf")
        end
        pm=build(modified;missing_reference=missing_ref);starts!(pm,point)
        vm=PM.var(pm,:vm,parse(Int,bus));target=JuMP.index(vm).value
        initial=copy(point)
        if id=="voltage_start"
            new=modified["bus"][bus]["vmin"]-0.2
            patch=Dict("start_variable"=>JuMP.name(vm),"before"=>point[JuMP.name(vm)],"after"=>new)
            JuMP.set_start_value(vm,new);initial[JuMP.name(vm)]=new
        end
        save(joinpath(dir,"modified_data.json"),modified);save(joinpath(dir,"modified_point.json"),initial)
        save(joinpath(dir,"patch.json"),patch)
        lineage=lineage_check(modified)
        save(joinpath(dir,"load_lineage.json"),lineage)
        trial=@timed diagnose(pm);diag=trial.value;save(joinpath(dir,"diagnostics.json"),diag)
        gauge_trial=@timed gauge_diagnostics(pm)
        gauge=gauge_trial.value
        gauge["seconds"]=gauge_trial.time;gauge["allocated_bytes"]=gauge_trial.bytes
        save(joinpath(dir,"gauge_diagnostics.json"),gauge)
        start_report=feasibility(pm;starts=true)
        badsolve=solve!(pm,joinpath(dir,"modified-ipopt.log"))
        modified_checks=get(badsolve,"solution",nothing)===nothing ? nothing : checked_physics(modified,badsolve["solution"];reference=!missing_ref)
        intended_checks=get(badsolve,"solution",nothing)===nothing ? nothing : checked_physics(data,badsolve["solution"];reference=!missing_ref)
        # Adjudication happens only after diagnostics. Explicit localizations
        # are scored; generic residuals are not credited as a unit diagnosis.
        expected=id=="voltage_bound" ? ["inconsistent_variable_bounds"] : id=="voltage_start" ? ["initialization_violates_variable_bounds"] : String[]
        ranked=diag["ranked_actionable"]
        match(f)=f["code"] in expected && any(a->a["kind"]=="variable" && a["index"]==target,f["affected"])
        rank=findfirst(match,ranked)
        baseline_rank=findfirst(match,diag["baseline_ranked_actionable"])
        truth=Dict{String,Any}("family"=>id,"defective"=>id!="clean","bus"=>bus,"load"=>load,
            "target_variable"=>Dict("kind"=>"variable","index"=>target,"name"=>JuMP.name(vm)),
            "expected_localization_codes"=>expected)
        if missing_ref
            shifted=deepcopy(baseline["solution"])
            for s in values(shifted["bus"]);s["va"]+=0.3;end
            truth["ac_graph_connected"]=ac_connected(data)
            truth["uniform_shift_physical_checks"]=physical_checks(data,shifted;reference=false)
            truth["shift_violates_original_reference"]=!physical_checks(data,shifted)["passed"]
        end
        restored=deepcopy(modified)
        if id in ("voltage_bound","power_units")
            path=patch["path"];restored[path[1]][path[2]][path[3]]=patch["before"]
        end
        restored_point=copy(initial)
        id=="voltage_start" && (restored_point[patch["start_variable"]]=patch["before"])
        data_restored=isequal(restored,data);point_restored=isequal(restored_point,point)
        data_restored && point_restored || error("inverse patch did not restore inputs")
        repair_started=time_ns()
        repaired=build(restored);starts!(repaired,restored_point)
        repairsolve=solve!(repaired,joinpath(dir,"repaired-ipopt.log"))
        repaircheck=get(repairsolve,"solution",nothing)===nothing ? Dict("passed"=>false) : checked_physics(data,repairsolve["solution"])
        save(joinpath(dir,"repaired_data.json"),restored);save(joinpath(dir,"repaired_point.json"),restored_point)
        save(joinpath(dir,"truth.json"),truth)
        record=Dict("id"=>id,"truth"=>truth,"diagnostic_seconds"=>trial.time,"diagnostic_allocated_bytes"=>trial.bytes,
            "load_lineage"=>lineage,"repaired_load_lineage"=>lineage_check(restored),
            "gauge_diagnostics"=>gauge,
            "diagnostic_available"=>diag["available"],
            "diagnostic_outcome"=>!diag["available"] ? "unavailable_analysis" : !isnothing(rank) ? "correct_localization" : isempty(ranked) ? "abstention" : "unlocalized_findings",
            "localization_rank"=>rank,"localized_top3"=>!isnothing(rank) && rank<=3,
            "baseline_localization_rank"=>baseline_rank,
            "baseline_localized_top3"=>!isnothing(baseline_rank) && baseline_rank<=3,
            "actionable_count"=>length(ranked),"advisory_count"=>length(diag["static"]["findings"])+length(diag["initialization"]["findings"])-length(ranked),
            "baseline_start_feasibility"=>start_report,"modified_solve"=>badsolve,
            "modified_physical_checks"=>modified_checks,"intended_physical_checks"=>intended_checks,
            "repair_source"=>"scripted inverse patch; no autonomous or human repair claim",
            "proposed_patch"=>nothing,"applied_patch"=>Dict("inverse_of"=>patch),
            "repair_input_restored"=>data_restored && point_restored,"repair_solve"=>repairsolve,
            "repair_physical_checks"=>repaircheck,"verified_scripted_repair"=>repaircheck["passed"],
            "scripted_repair_seconds"=>(time_ns()-repair_started)/1e9,
            "original_data_sha256"=>digest(data),"modified_data_sha256"=>digest(modified),"repaired_data_sha256"=>digest(restored))
        save(joinpath(dir,"record.json"),record);push!(records,record)
    end
    defective=filter(r->r["truth"]["defective"],records)
    clean=only(filter(r->!r["truth"]["defective"],records))
    summary=Dict("schema_version"=>"power-repair-pilot-v1","scope"=>scope,
        "git_revision"=>git_revision(ROOT),"git_status_entries"=>git_status_entries(ROOT),
        "fixture_sha256"=>fixture_sha,"julia_version"=>string(VERSION),"manifest_sha256"=>filehash(joinpath(ENV_DIR,"Manifest.toml")),
        "packages"=>Dict(k=>Dict("version"=>get(v[1],"version",nothing),"tree_sha1"=>get(v[1],"git-tree-sha1",nothing),"path"=>get(v[1],"path",nothing)) for (k,v) in manifest["deps"]),
        "source_hashes_file"=>"source_hashes.json","load_seconds_excluding_process_start"=>load_seconds,
        "cold_diagnostic_seconds"=>cold.time,"diagnostic_policy"=>"static plus initialization; degeneracy/component ranks off; tolerance 1e-6",
        "ranking_policy"=>RANKING_POLICY,
        "ranking_interpretation"=>"development heuristic: recognized contradictory bounds, direct initialization evidence, other errors, numerical residuals; no causal or held-out effectiveness claim",
        "baseline_ranking_policy"=>"error severity only, then code, affected identities, and full finding; warning/info findings retained as advisory",
        "physical_units"=>"per-unit on parsed baseMVA; angles in radians",
        "localization_top3"=>Dict("numerator"=>count(r->r["localized_top3"],defective),"denominator"=>length(defective)),
        "baseline_localization_top3"=>Dict("numerator"=>count(r->r["baseline_localized_top3"],defective),"denominator"=>length(defective)),
        "abstentions"=>Dict("numerator"=>count(r->r["diagnostic_outcome"]=="abstention",records),"denominator"=>length(records)),
        "clean_actionable_error_cases"=>Dict("numerator"=>Int(clean["actionable_count"]>0),"denominator"=>1),
        "clean_actionable_error_count"=>clean["actionable_count"],
        "verified_scripted_repairs"=>Dict("numerator"=>count(r->r["verified_scripted_repair"],defective),"denominator"=>length(defective)),
        "human_repair_time"=>nothing,"diagnostic_unavailable_cases"=>count(r->!r["diagnostic_available"],records),"records"=>records)
    summary["gauge_configuration"]="connected-acp-uniform-shift-v1; separate from ranked findings"
    summary["load_lineage_configuration"]="pilot-load-lineage-v1; separate source-aware workflow"
    summary["load_lineage_outcomes"]=Dict(r["id"]=>r["load_lineage"]["outcome"] for r in records)
    summary["gauge_outcomes"]=Dict(r["id"]=>r["gauge_diagnostics"]["outcome"] for r in records)
    save(joinpath(output,"summary.json"),summary)
    println("Pilot complete: ",joinpath(output,"summary.json"))
    summary
end
end
if abspath(PROGRAM_FILE)==@__FILE__
    output=isempty(ARGS) ? joinpath(PowerRepairPilot.ROOT,"work","power-repair-pilot") : abspath(only(ARGS))
    PowerRepairPilot.run(output;load_seconds=(time_ns()-PILOT_LOAD_START)/1e9)
end
