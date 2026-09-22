module TolerantCapacityCertificate
include("encoded_capacity_certificate.jl")
using .EncodedCapacityCertificate
const ECC=EncodedCapacityCertificate
const Q=ECC.Q
export tolerant_capacity_certificate

function rational_string(s)
    parts=split(s,"//")
    length(parts)==2 || error("invalid exact rational evidence")
    parse(BigInt,parts[1])//parse(BigInt,parts[2])
end
function tolerance(x)
    q=ECC.exact(x)
    q>=0 || error("tolerances must be finite and nonnegative")
    q
end
"""
Sufficient contradiction for explicitly declared absolute, unscaled tolerances.
Each selected equality's true real residual is at most equality_tolerance.
Each generator/voltage bound may be relaxed by its respective tolerance.
This is not an automatic interpretation of an optimizer's stopping settings.
"""
function tolerant_capacity_certificate(pm,data;contract=:unspecified,
        equality_tolerance=nothing,generator_bound_tolerance=nothing,
        voltage_bound_tolerance=nothing)
    try
        contract==:absolute_unscaled || error("explicit absolute_unscaled tolerance contract required")
        eq=tolerance(equality_tolerance)
        gen=tolerance(generator_bound_tolerance)
        vm=tolerance(voltage_bound_tolerance)
        evidence=ECC.encoded_capacity_certificate(pm,data)
        evidence.available || return (available=false,status="unavailable",reason=evidence.reason)
        weights=Dict{String,Int}()
        for b in evidence.balances;weights[b.row]=get(weights,b.row,0)+1;end
        losses=Any[];loss_lower=zero(Q)
        for b in evidence.branches
            for row in b.rows;weights[row]=get(weights,row,0)-1;end
            A,B,C,D=rational_string.(b.coefficients_exact)
            U,V=rational_string.(b.voltage_upper_exact)
            # Original voltages lie in [l,U], 0<=l<=U. Relaxation gives
            # |x|<=U+vm even if the relaxed lower bound crosses zero.
            # The loss inequality holds with |x*y| for signed voltages too.
            lower=ECC.loss_bound(A,B,C,D,U+vm,V+vm)
            loss_lower+=lower
            push!(losses,(branch=b.branch,voltage_absolute_upper_exact=string.([U+vm,V+vm]),loss_lower_exact_pu=string(lower)))
        end
        row_budget=sum(abs(w)*eq for w in values(weights);init=zero(Q))
        capacity=rational_string(evidence.capacity_exact_pu)+length(evidence.generator_bounds)*gen
        margin=rational_string(evidence.demand_exact_pu)-capacity+loss_lower-row_budget
        return (available=true,status=margin>0 ? "certified_infeasible_within_tolerances" : "not_ruled_out",
            contract="absolute_unscaled",equality_tolerance_exact=string(eq),
            generator_bound_tolerance_exact=string(gen),voltage_bound_tolerance_exact=string(vm),
            equality_weights=[(row=row,weight=w) for (row,w) in sort!(collect(weights);by=first) if w!=0],
            equality_budget_exact_pu=string(row_budget),relaxed_capacity_exact_pu=string(capacity),
            relaxed_loss_lower_exact_pu=string(loss_lower),contradiction_margin_exact_pu=string(margin),
            branches=losses,encoded_evidence=evidence,
            semantics="No real point satisfies the selected encoded equalities and generator/voltage bounds within the declared absolute unscaled tolerances when the exact margin is positive.",
            limitation="Caller must bound true residuals, including numerical evaluation error. No automatic mapping from solver settings, scaling, relative tolerances, bound relaxation, or termination status. Not a feasibility, optimality, source-intent, or operational certificate.")
    catch e
        e isa InterruptException && rethrow()
        (available=false,status="unavailable",reason=sprint(showerror,e))
    end
end
end
