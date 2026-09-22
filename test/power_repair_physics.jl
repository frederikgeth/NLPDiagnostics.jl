module PowerRepairPhysicsTests
using Test
include("../benchmarks/power_repair_pilot/physics.jl")
function fixture()
    branch=Dict("br_r"=>0.0,"br_x"=>1.0,"tap"=>1.0,"shift"=>0.0,
        "g_fr"=>0.0,"b_fr"=>0.0,"g_to"=>0.0,"b_to"=>0.0,
        "br_status"=>1,"f_bus"=>1,"t_bus"=>2,"rate_a"=>1.0,"angmin"=>-1.0,"angmax"=>1.0)
    data=Dict("per_unit"=>true,"bus"=>Dict(
        "1"=>Dict("bus_type"=>3,"vmin"=>0.8,"vmax"=>1.2),
        "2"=>Dict("bus_type"=>1,"vmin"=>0.8,"vmax"=>1.2)),
        "gen"=>Dict("1"=>Dict("gen_status"=>1,"gen_bus"=>1,"pmin"=>0.0,"pmax"=>1.0,"qmin"=>-1.0,"qmax"=>1.0)),
        "load"=>Dict("1"=>Dict("status"=>1,"load_bus"=>2,"pd"=>0.0,"qd"=>0.09)),
        "shunt"=>Dict(),"branch"=>Dict("1"=>branch),"dcline"=>Dict{String,Any}())
    solution=Dict("bus"=>Dict("1"=>Dict("vm"=>1.0,"va"=>0.0),"2"=>Dict("vm"=>0.9,"va"=>0.0)),
        "gen"=>Dict("1"=>Dict("pg"=>0.0,"qg"=>0.1)),
        "branch"=>Dict("1"=>Dict("pf"=>0.0,"qf"=>0.1,"pt"=>0.0,"qt"=>-0.09)),
        "dcline"=>Dict{String,Any}())
    return data,solution
end
@testset "Independent AC/DC checker accepts analytic witnesses and rejects defects" begin
    d,s=fixture()
    sf,st=branch_powers(d["branch"]["1"],1+0im,0.9+0im)
    @test sf ≈ 0.1im
    @test st ≈ -0.09im
    @test physical_checks(d,s)["passed"]
    @test ac_connected(d)
    shifted=deepcopy(s)
    for b in values(shifted["bus"]);b["va"]+=0.3;end
    @test physical_checks(d,shifted;reference=false)["passed"]
    @test !physical_checks(d,shifted)["passed"]
    for kind in (:load,:gen,:rating,:voltage,:angle,:flow,:nonfinite)
        bad=deepcopy(d);point=deepcopy(s)
        kind==:load && (bad["load"]["1"]["qd"]=0.2)
        kind==:gen && (bad["gen"]["1"]["qmax"]=0.05)
        kind==:rating && (bad["branch"]["1"]["rate_a"]=0.05)
        kind==:voltage && (bad["bus"]["1"]["vmax"]=0.95)
        kind==:angle && (point["bus"]["2"]["va"]=2.0)
        kind==:flow && (point["branch"]["1"]["pf"]=0.1)
        kind==:nonfinite && (point["bus"]["1"]["vm"]=NaN)
        @test !physical_checks(bad,point)["passed"]
    end
    d["dcline"]["1"]=Dict("br_status"=>1,"f_bus"=>1,"t_bus"=>2,"loss0"=>0.01,"loss1"=>0.0,
        "pminf"=>0.0,"pmaxf"=>1.0,"pmint"=>-1.0,"pmaxt"=>0.0,
        "qminf"=>-1.0,"qmaxf"=>1.0,"qmint"=>-1.0,"qmaxt"=>1.0)
    s["dcline"]["1"]=Dict("pf"=>0.2,"pt"=>-0.19,"qf"=>0.0,"qt"=>0.0)
    s["gen"]["1"]["pg"]=0.2;d["load"]["1"]["pd"]=0.19
    @test physical_checks(d,s)["passed"]
    d["dcline"]["1"]["loss0"]=0.02
    @test !physical_checks(d,s)["passed"]
    d["storage"]=Dict("1"=>Dict())
    @test_throws ErrorException physical_checks(d,s)
    d,s=fixture();empty!(d["branch"])
    @test !ac_connected(d)
end
end
