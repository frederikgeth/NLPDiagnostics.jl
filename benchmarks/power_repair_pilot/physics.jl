# Independent complex-voltage checks. No NLPDiagnostics, JuMP, or PowerModels
# residual/feasibility functions are used here. Inputs are per-unit network data.
function branch_powers(branch, vf, vt)
    y = inv(complex(branch["br_r"], branch["br_x"]))
    tap = branch["tap"] * cis(branch["shift"])
    yf = complex(branch["g_fr"], branch["b_fr"])
    yt = complex(branch["g_to"], branch["b_to"])
    ifrom = (y+yf)/abs2(tap)*vf - y/conj(tap)*vt
    ito = (y+yt)*vt - y/tap*vf
    return vf*conj(ifrom), vt*conj(ito)
end
function physical_checks(data, solution; reference=true, tolerance=1e-6)
    data["per_unit"] || error("physical checker requires per-unit data")
    for kind in ("storage", "switch")
        isempty(get(data,kind,Dict())) || error("pilot checker does not support $kind")
    end
    residuals=Dict{String,Float64}()
    eq(label,value)=(residuals[label]=abs(value))
    limit(label,value,lo,hi)=(residuals[label]=max(0.0,lo-value,value-hi))
    volt=Dict(k=>s["vm"]*cis(s["va"]) for (k,s) in solution["bus"])
    injection=Dict(k=>0.0+0.0im for k in keys(volt))
    for (id,b) in data["bus"]
        b["bus_type"]==4 && continue
        v=solution["bus"][id]
        limit("bus/$id/voltage",v["vm"],b["vmin"],b["vmax"])
        reference && b["bus_type"]==3 && eq("bus/$id/reference",v["va"])
    end
    for (id,g) in data["gen"]
        g["gen_status"]==0 && continue
        s=solution["gen"][id]; injection[string(g["gen_bus"])]+=complex(s["pg"],s["qg"])
        limit("gen/$id/p",s["pg"],g["pmin"],g["pmax"])
        limit("gen/$id/q",s["qg"],g["qmin"],g["qmax"])
    end
    for l in values(data["load"])
        l["status"]==0 && continue
        injection[string(l["load_bus"]) ]-=complex(l["pd"],l["qd"])
    end
    for s in values(data["shunt"])
        s["status"]==0 && continue
        bus=string(s["shunt_bus"])
        injection[bus]-=complex(s["gs"],-s["bs"])*abs2(volt[bus])
    end
    for (id,b) in data["branch"]
        b["br_status"]==0 && continue
        f,t=string(b["f_bus"]),string(b["t_bus"])
        sf,st=branch_powers(b,volt[f],volt[t])
        injection[f]-=sf;injection[t]-=st
        # Check reported branch flows too: balance alone can hide substitutions.
        s=solution["branch"][id]
        eq("branch/$id/from_flow",sf-complex(s["pf"],s["qf"]))
        eq("branch/$id/to_flow",st-complex(s["pt"],s["qt"]))
        if haskey(b,"rate_a") && b["rate_a"]>0
            limit("branch/$id/from_rating",abs(sf),0,b["rate_a"])
            limit("branch/$id/to_rating",abs(st),0,b["rate_a"])
        end
        angle=solution["bus"][f]["va"]-solution["bus"][t]["va"]
        limit("branch/$id/angle",angle,b["angmin"],b["angmax"])
    end
    for (id,d) in data["dcline"]
        d["br_status"]==0 && continue
        s=solution["dcline"][id]
        injection[string(d["f_bus"]) ]-=complex(s["pf"],s["qf"])
        injection[string(d["t_bus"]) ]-=complex(s["pt"],s["qt"])
        eq("dcline/$id/loss",(1-d["loss1"])*s["pf"]+s["pt"]-d["loss0"])
        for (field,suffix) in (("pf","f"),("pt","t"))
            limit("dcline/$id/$field",s[field],d["pmin"*suffix],d["pmax"*suffix])
        end
        for (field,suffix) in (("qf","f"),("qt","t"))
            limit("dcline/$id/$field",s[field],d["qmin"*suffix],d["qmax"*suffix])
        end
    end
    for (id,s) in injection
        eq("bus/$id/p_balance",real(s));eq("bus/$id/q_balance",imag(s))
    end
    finite=all(isfinite,values(residuals))
    maximum_residual=finite ? maximum(values(residuals);init=0.0) : Inf
    return Dict("passed"=>finite && maximum_residual<=tolerance,
        "tolerance_pu_or_radians"=>tolerance,"maximum_residual"=>maximum_residual,
        "residuals"=>residuals,"reference_checked"=>reference)
end
function ac_connected(data)
    buses=Set(string(k) for (k,b) in data["bus"] if b["bus_type"]!=4)
    isempty(buses) && return false
    seen=Set([first(sort!(collect(buses)))]); changed=true
    while changed
        changed=false
        for b in values(data["branch"])
            b["br_status"]==0 && continue
            f,t=string(b["f_bus"]),string(b["t_bus"])
            if (f in seen) != (t in seen)
                push!(seen,f);push!(seen,t);changed=true
            end
        end
    end
    seen==buses
end
