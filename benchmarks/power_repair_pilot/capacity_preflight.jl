module PowerCapacityPreflight
export capacity_preflight

function exact_number(value, path)
    value isa Union{Integer,Rational,AbstractFloat} && !(value isa Bool) && isfinite(value) ||
        throw(ArgumentError("$path must be a supported finite real number"))
    Rational{BigInt}(value)
end
function active(entry, field, path)
    value=entry[field]
    value in (0,1) || throw(ArgumentError("$path/$field must be 0 or 1"))
    value==1
end

"""
    capacity_preflight(data; contract=:unspecified)

Conditional aggregate active-power test for `:closed_acp_fixed_load` data.
The caller declares standard passive ACP balance equations, fixed unsheddable
loads, and no unlisted power sources. This function checks data premises, not
whether a model backend implements the declared equations. A nonpositive gap
means `not_ruled_out`, never feasibility or adequate island-level supply.
"""
function capacity_preflight(data; contract::Symbol=:unspecified)
    try
        contract==:closed_acp_fixed_load || throw(ArgumentError("explicit closed_acp_fixed_load contract required"))
        data["per_unit"]===true || throw(ArgumentError("per-unit declaration required"))
        base=exact_number(data["baseMVA"],"baseMVA")
        base>0 || throw(ArgumentError("baseMVA must be positive"))
        for kind in ("dcline","storage","switch","ne_branch")
            isempty(get(data,kind,Dict())) || throw(ArgumentError("unsupported device collection: $kind"))
        end
        buses=Set{String}()
        for (id,b) in data["bus"]
            b["bus_type"] in (1,2,3,4) || throw(ArgumentError("unsupported bus type at $id"))
            b["bus_type"]!=4 && push!(buses,string(id))
        end
        isempty(buses) && throw(ArgumentError("no active buses"))
        function bus_ref(entry,field,path)
            string(entry[field]) in buses || throw(ArgumentError("$path/$field references a missing or inactive bus"))
        end
        demand=big(0)//1;capacity=big(0)//1
        load_terms=Any[];generator_terms=Any[]
        for (id,l) in data["load"]
            active(l,"status","load/$id") || continue
            bus_ref(l,"load_bus","load/$id")
            p=exact_number(l["pd"],"load/$id/pd")
            exact_number(l["qd"],"load/$id/qd")
            p>=0 || throw(ArgumentError("negative active load at $id requires source modeling"))
            demand+=p
            push!(load_terms,(id=string(id),bus=string(l["load_bus"]),power_exact_pu=string(p)))
        end
        for (id,g) in data["gen"]
            active(g,"gen_status","gen/$id") || continue
            bus_ref(g,"gen_bus","gen/$id")
            upper=exact_number(g["pmax"],"gen/$id/pmax")
            lower=exact_number(g["pmin"],"gen/$id/pmin")
            lower<=upper || throw(ArgumentError("inconsistent generator bounds at $id"))
            capacity+=upper
            push!(generator_terms,(id=string(id),bus=string(g["gen_bus"]),upper_exact_pu=string(upper)))
        end
        for (id,s) in data["shunt"]
            active(s,"status","shunt/$id") || continue
            bus_ref(s,"shunt_bus","shunt/$id")
            exact_number(s["gs"],"shunt/$id/gs")>=0 || throw(ArgumentError("active-power producing shunt at $id"))
            exact_number(s["bs"],"shunt/$id/bs")
        end
        for (id,b) in data["branch"]
            active(b,"br_status","branch/$id") || continue
            bus_ref(b,"f_bus","branch/$id");bus_ref(b,"t_bus","branch/$id")
            r=exact_number(b["br_r"],"branch/$id/br_r")
            x=exact_number(b["br_x"],"branch/$id/br_x")
            r>=0 && (!iszero(r) || !iszero(x)) || throw(ArgumentError("nonpassive or zero series impedance at $id"))
            for field in ("g_fr","g_to")
                exact_number(b[field],"branch/$id/$field")>=0 || throw(ArgumentError("active-power producing branch shunt at $id"))
            end
            for field in ("b_fr","b_to","shift");exact_number(b[field],"branch/$id/$field");end
            exact_number(b["tap"],"branch/$id/tap")>0 || throw(ArgumentError("nonpositive tap at $id"))
        end
        gap=demand-capacity
        sort!(load_terms;by=t->t.id);sort!(generator_terms;by=t->t.id)
        return (available=true,status=gap>0 ? "capacity_shortage" : "not_ruled_out",
            contract=string(contract),demand_exact_pu=string(demand),capacity_exact_pu=string(capacity),
            gap_exact_pu=string(gap),gap_exact_mw=string(gap*base),load_terms=load_terms,generator_terms=generator_terms,
            reasoning="Summed active generation equals fixed load plus nonnegative passive losses, but cannot exceed summed active-generator pmax.",
            limitation="Conditional on declared equations and complete source data; no backend verification. Non-shortage does not establish feasibility, island adequacy, voltage/reactive support, or security.")
    catch e
        e isa InterruptException && rethrow()
        return (available=false,status="unavailable",contract=string(contract),reason=sprint(showerror,e))
    end
end
end
