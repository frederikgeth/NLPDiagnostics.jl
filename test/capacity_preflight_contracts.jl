module CapacityPreflightTests
using Test
include("../benchmarks/power_repair_pilot/capacity_preflight.jl")
using .PowerCapacityPreflight
function network()
    Dict{String,Any}("per_unit"=>true,"baseMVA"=>100.0,
        "bus"=>Dict("1"=>Dict("bus_type"=>3)),
        "load"=>Dict("1"=>Dict{String,Any}("status"=>1,"load_bus"=>1,"pd"=>1.0,"qd"=>0.0)),
        "gen"=>Dict("1"=>Dict{String,Any}("gen_status"=>1,"gen_bus"=>1,"pmin"=>0.0,"pmax"=>1.0)),
        "branch"=>Dict{String,Any}(),"shunt"=>Dict{String,Any}())
end
check(d)=capacity_preflight(d;contract=:closed_acp_fixed_load)
@testset "Conditional capacity preflight" begin
    d=network();before=deepcopy(d)
    @test check(d).status=="not_ruled_out"
    @test d==before
    @test capacity_preflight(d).status=="unavailable"
    d["gen"]["1"]["pmax"]=prevfloat(1.0)
    r=check(d)
    @test r.status=="capacity_shortage"
    @test r.gap_exact_pu==string(big(1)//1-Rational{BigInt}(prevfloat(1.0)))
    @test r.gap_exact_mw==string(100*(big(1)//1-Rational{BigInt}(prevfloat(1.0))))
    for cap in (1.0,nextfloat(1.0),1e300)
        d["gen"]["1"]["pmax"]=cap
        @test check(d).status=="not_ruled_out"
    end
    for invalid in (NaN,Inf,-Inf,true)
        d=network();d["load"]["1"]["pd"]=invalid
        @test check(d).status=="unavailable"
    end
    for kind in ("dcline","storage","switch","ne_branch")
        d=network();d[kind]=Dict("1"=>Dict())
        @test check(d).status=="unavailable"
    end
    for (field,value) in (("pd",-0.1),("load_bus",2),("status",2))
        d=network();d["load"]["1"][field]=value
        @test check(d).status=="unavailable"
    end
    for value in (0.0,-1.0,NaN)
        d=network();d["baseMVA"]=value
        @test check(d).status=="unavailable"
    end
    d=network();d["gen"]["1"]["pmin"]=2.0
    @test check(d).status=="unavailable"
    d=network();d["gen"]["1"]["gen_status"]=0
    @test check(d).status=="capacity_shortage"
    d=network();d["load"]["1"]["status"]=0
    @test check(d).status=="not_ruled_out"
    d=network();d["bus"]["1"]["bus_type"]=4
    @test check(d).status=="unavailable"
    d=network();delete!(d,"shunt")
    @test check(d).status=="unavailable"
    # Reactive shunts may supply vars, but must not supply active power.
    d=network();d["shunt"]["1"]=Dict("status"=>1,"shunt_bus"=>1,"gs"=>-0.1,"bs"=>0.0)
    @test check(d).status=="unavailable"
    branch=Dict{String,Any}("br_status"=>1,"f_bus"=>1,"t_bus"=>1,
        "br_r"=>0.1,"br_x"=>0.2,"tap"=>1.0,"shift"=>0.3,
        "g_fr"=>0.0,"g_to"=>0.0,"b_fr"=>-0.1,"b_to"=>0.1)
    d=network();d["branch"]["1"]=branch
    @test check(d).status=="not_ruled_out"
    for (field,value) in (("br_r",-0.1),("tap",0.0),("g_to",-0.1),("shift",Inf),("t_bus",2))
        d=network();d["branch"]["1"]=merge(branch,Dict(field=>value))
        @test check(d).status=="unavailable"
    end
    d=network();d["branch"]["1"]=merge(branch,Dict("br_r"=>0.0,"br_x"=>0.0))
    @test check(d).status=="unavailable"
    # Aggregate capacity can pass while an isolated load has no supply.
    d=network();d["bus"]["2"]=Dict("bus_type"=>1);d["gen"]["1"]["gen_bus"]=2
    @test check(d).status=="not_ruled_out"
    # Exact aggregation must not overflow when all individual inputs are finite.
    d=network();d["load"]["1"]["pd"]=1e308;d["gen"]["1"]["pmax"]=1e308
    d["load"]["2"]=deepcopy(d["load"]["1"])
    @test check(d).status=="capacity_shortage"
    @test check(d).gap_exact_pu==string(Rational{BigInt}(1e308))
end
end
