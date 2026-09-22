module EncodedCapacityCertificate
include("capacity_model_contract.jl")
using .CapacityModelContract
const CMC=CapacityModelContract
const MOI=CMC.MOI
const JuMP=CMC.JuMP
const PM=CMC.PM
const Q=Rational{BigInt}
const Poly=Dict{Tuple,Q}
export encoded_capacity_certificate

exact(x)=(CMC.number_key(x); Q(x))
atom(v::MOI.VariableIndex)="v:$(v.value)"
mono(xs...)=Tuple(sort!(collect(xs)))
constant(x)=iszero(x) ? Poly() : Poly(()=>exact(x))
variable(v)=Poly((atom(v),)=>one(Q))
function add(a,b,scale=one(Q))
    out=copy(a)
    for (k,v) in b
        out[k]=get(out,k,zero(Q))+scale*v
        iszero(out[k]) && delete!(out,k)
    end
    length(out)<=256 || error("polynomial expansion limit")
    out
end
function multiply(a,b)
    out=Poly()
    for (ka,va) in a, (kb,vb) in b
        k=mono(ka...,kb...)
        length(k)<=4 || error("unsupported polynomial degree")
        out=add(out,Poly(k=>va*vb))
    end
    out
end
function polynomial(f,depth=0)
    depth<=64 || error("expression depth limit")
    f isa Real && return constant(f)
    f isa MOI.VariableIndex && return variable(f)
    if f isa MOI.ScalarAffineFunction || f isa MOI.ScalarQuadraticFunction
        p=constant(f.constant)
        terms=f isa MOI.ScalarAffineFunction ? f.terms : f.affine_terms
        for t in terms;p=add(p,variable(t.variable),exact(t.coefficient));end
        if f isa MOI.ScalarQuadraticFunction
            for t in f.quadratic_terms
                # MOI stores diagonal quadratic coefficients doubled.
                c=exact(t.coefficient)/(t.variable_1==t.variable_2 ? 2 : 1)
                p=add(p,multiply(variable(t.variable_1),variable(t.variable_2)),c)
            end
        end
        return p
    end
    f isa MOI.ScalarNonlinearFunction || error("unsupported expression")
    args=[polynomial(a,depth+1) for a in f.args]
    if f.head==:+
        return foldl(add,args;init=Poly())
    elseif f.head==:-
        length(args) in (1,2) || error("unsupported subtraction arity")
        return length(args)==1 ? add(Poly(),args[1],-one(Q)) : add(args[1],args[2],-one(Q))
    elseif f.head==:*
        return foldl(multiply,args;init=constant(1))
    elseif f.head==:/
        length(args)==2 && length(args[2])==1 && haskey(args[2],()) || error("only constant division supported")
        return add(Poly(),args[1],inv(args[2][()]))
    elseif f.head==:^
        length(args)==2 || error("unsupported power arity")
        exponent=get(args[2],(),zero(Q))
        all(isempty,keys(args[2])) && exponent in (0,1,2) || error("only powers 0, 1, 2 supported")
        return exponent==0 ? constant(1) : exponent==1 ? args[1] : multiply(args[1],args[1])
    elseif f.head in (:sin,:cos)
        length(args)==1 || error("unsupported trigonometric arity")
        terms=sort!(collect(args[1]);by=x->x.first)
        length(terms)==2 && all(t->length(t.first)==1 && startswith(t.first[1],"v:"),terms) || error("angle difference required")
        a,b=terms
        a.second in (-1,1) && b.second==-a.second || error("unit angle difference required")
        key="$(f.head):$(a.first[1]):$(b.first[1])"
        return Poly((key,)=>(f.head==:sin ? a.second : one(Q)))
    end
    error("unsupported operator $(f.head)")
end

# Rational dyadic enclosures; no floating square root or precision context.
function sqrt_bounds(x::Q;bits=128)
    x>=0 || error("negative square root")
    scale=big(1)<<bits
    n=isqrt(div(numerator(x)*scale^2,denominator(x)))
    lo=n//scale
    hi=lo^2==x ? lo : (n+1)//scale
    (lo,hi)
end
"""Lower bound A*x²+B*y²+C*x*y*cos(t)+D*x*y*sin(t), for 0≤x≤U, 0≤y≤V."""
function loss_bound(A::Q,B::Q,C::Q,D::Q,U::Q,V::Q)
    min(A,B,U,V)>=0 || error("nonnegative diagonal coefficients and voltage bounds required")
    radius2=C^2+D^2
    radius2<=4*A*B && return zero(Q)
    _,radius_upper=sqrt_bounds(radius2)
    geometric_lower,_=sqrt_bounds(A*B)
    -max(zero(Q),radius_upper-2*geometric_lower)*U*V
end
function equality_rows(model)
    backend=JuMP.backend(model)
    rows=Pair{String,Poly}[]
    for (F,S) in MOI.get(backend,MOI.ListOfConstraintTypesPresent())
        S<:MOI.EqualTo || continue
        for idx in MOI.get(backend,MOI.ListOfConstraintIndices{F,S}())
            f=MOI.get(backend,MOI.ConstraintFunction(),idx)
            s=MOI.get(backend,MOI.ConstraintSet(),idx)
            push!(rows,string(idx)=>add(polynomial(f),constant(s.value),-one(Q)))
        end
    end
    rows
end
function unique_row(rows,predicate)
    found=filter(r->predicate(r.second),rows)
    length(found)==1 || error("required equation is absent or ambiguous")
    only(found)
end
function finite_bounds(model,v)
    backend=JuMP.backend(model)
    lower=nothing;upper=nothing
    for (F,S) in MOI.get(backend,MOI.ListOfConstraintTypesPresent())
        F==MOI.VariableIndex || continue
        for idx in MOI.get(backend,MOI.ListOfConstraintIndices{F,S}())
            MOI.get(backend,MOI.ConstraintFunction(),idx)==v || continue
            s=MOI.get(backend,MOI.ConstraintSet(),idx)
            lo=s isa MOI.GreaterThan ? exact(s.lower) : s isa MOI.EqualTo ? exact(s.value) : s isa MOI.Interval ? exact(s.lower) : nothing
            hi=s isa MOI.LessThan ? exact(s.upper) : s isa MOI.EqualTo ? exact(s.value) : s isa MOI.Interval ? exact(s.upper) : nothing
            isnothing(lo) || (lower=isnothing(lower) ? lo : max(lower,lo))
            isnothing(hi) || (upper=isnothing(upper) ? hi : min(upper,hi))
        end
    end
    !isnothing(lower) && !isnothing(upper) && lower<=upper || error("finite consistent explicit bounds required")
    (lower,upper)
end

"""
Experimental exact-real infeasibility certificate for matched standard ACP rows.
Uses actual encoded equality coefficients and variable bounds. It does not
certify solver tolerances, real-world source intent, feasibility, or optimality.
"""
function encoded_capacity_certificate(pm,data)
    contract=CMC.checked_capacity_preflight(pm,data)
    contract.available || return (available=false,status="unavailable",reason=contract.reason)
    try
        rows=equality_rows(pm.model)
        # Use source-derived coordinates from a fresh builder, mapped by name into
        # the checked backend; mutable pm.var dictionaries are not proof evidence.
        expected=PM.instantiate_model(CMC.materialize(data),PM.ACPPowerModel,PM.build_opf)
        names=Dict(JuMP.name(v)=>JuMP.index(v) for v in JuMP.all_variables(pm.model))
        coordinate(kind,id)=names[JuMP.name(PM.var(expected,kind,id))]
        aggregate=Poly(); branch_polynomial=Poly();shunts=Poly();gens=Poly()
        branches=Any[]; balances=Any[];bound_terms=Any[]
        loss_lower=zero(Q);capacity=zero(Q)
        for (id,b) in sort!(collect(data["bus"]);by=first)
            b["bus_type"]==4 && continue
            bus=parse(Int,id);vm=coordinate(:vm,bus)
            linear=Poly()
            for (bid,br) in data["branch"]
                br["br_status"]==1 || continue
                f=Int(br["f_bus"]);t=Int(br["t_bus"])
                f==t && error("self-loop branch unsupported")
                if bus in (f,t)
                    arc=(parse(Int,bid),bus,bus==f ? t : f)
                    linear=add(linear,variable(coordinate(:p,arc)))
                end
            end
            for (gid,g) in data["gen"]
                g["gen_status"]==1 && Int(g["gen_bus"])==bus || continue
                pg=coordinate(:pg,parse(Int,gid))
                linear=add(linear,variable(pg),-one(Q))
                gens=add(gens,variable(pg),-one(Q))
                _,hi=finite_bounds(pm.model,pg);capacity+=hi
                push!(bound_terms,(generator=gid,variable=atom(pg),upper_exact_pu=string(hi)))
            end
            square=mono(atom(vm),atom(vm))
            row=unique_row(rows,p->begin
                rest=add(p,linear,-one(Q))
                all(k->k==() || k==square,keys(rest)) && get(rest,square,zero(Q))>=0 && get(rest,(),zero(Q))>=0
            end)
            aggregate=add(aggregate,row.second)
            shunts=add(shunts,Poly(square=>get(row.second,square,zero(Q))))
            push!(balances,(bus=id,row=row.first,load_constant_exact_pu=string(get(row.second,(),zero(Q)))))
        end
        for (id,b) in sort!(collect(data["branch"]);by=first)
            b["br_status"]==1 || continue
            f=Int(b["f_bus"]);t=Int(b["t_bus"]);bid=parse(Int,id)
            x=coordinate(:vm,f);y=coordinate(:vm,t)
            a=coordinate(:va,f);z=coordinate(:va,t)
            aa,zz=sort([atom(a),atom(z)])
            xx=mono(atom(x),atom(x)); yy=mono(atom(y),atom(y))
            cc=mono(atom(x),atom(y),"cos:$aa:$zz")
            ss=mono(atom(x),atom(y),"sin:$aa:$zz")
            allowed=Set([xx,yy,cc,ss]);pair=Poly();used=String[]
            for arc in ((bid,f,t),(bid,t,f))
                p=coordinate(:p,arc);vp=variable(p)
                row=unique_row(rows,r->get(r,(atom(p),),zero(Q))==1 && all(k->k in allowed,keys(add(r,vp,-one(Q)))))
                # Row p-loss=0. Subtracting it replaces the balance's p by loss.
                aggregate=add(aggregate,row.second,-one(Q))
                pair=add(pair,add(vp,row.second,-one(Q)))
                push!(used,row.first)
            end
            lx,U=finite_bounds(pm.model,x);ly,V=finite_bounds(pm.model,y)
            min(lx,ly)>=0 || error("nonnegative voltage domain required")
            A=get(pair,xx,zero(Q));B=get(pair,yy,zero(Q));C=get(pair,cc,zero(Q));D=get(pair,ss,zero(Q))
            lb=loss_bound(A,B,C,D,U,V);loss_lower+=lb
            branch_polynomial=add(branch_polynomial,pair)
            push!(branches,(branch=id,rows=used,coefficients_exact=string.([A,B,C,D]),voltage_upper_exact=string.([U,V]),loss_lower_exact_pu=string(lb)))
        end
        residual=add(add(add(aggregate,branch_polynomial,-one(Q)),shunts,-one(Q)),gens,-one(Q))
        all(isempty,keys(residual)) || error("aggregate equation failed exact cancellation")
        demand=get(residual,(),zero(Q))
        margin=demand-capacity+loss_lower
        return (available=true,status=margin>0 ? "certified_infeasible" : "not_ruled_out",
            semantics="Exact real satisfaction of the encoded scalar equations and explicit variable bounds; zero feasibility tolerance.",
            contract_digest=contract.contract_digest,demand_exact_pu=string(demand),capacity_exact_pu=string(capacity),
            aggregate_loss_lower_exact_pu=string(loss_lower),contradiction_margin_exact_pu=string(margin),
            balances=balances,generator_bounds=bound_terms,branches=branches,
            limitation="Experimental sufficient condition only. Not a solver-tolerance, feasibility, optimality, source-intent, or real-world repair certificate.")
    catch e
        e isa InterruptException && rethrow()
        return (available=false,status="unavailable",reason=sprint(showerror,e))
    end
end
end
