using JuMP
using NLPDiagnostics.Stable

function build_balance_model(; mixed_coordinates::Bool)
    model = Model()
    if mixed_coordinates
        @variable(model, 0 <= generation_mw <= 100)
        @variable(model, 0 <= import_w <= 100e6)
        @constraint(model, 1e6 * generation_mw + import_w == 100e6)
        @objective(model, Min, 50 * generation_mw + 1e-4 * import_w)
    else
        @variable(model, 0 <= generation_mw <= 100)
        @variable(model, 0 <= import_mw <= 100)
        @constraint(model, generation_mw + import_mw == 100)
        @objective(model, Min, 50 * generation_mw + 100 * import_mw)
    end
    return model
end

coherent = model_summary(build_balance_model(mixed_coordinates = false))
mixed = model_summary(build_balance_model(mixed_coordinates = true))

@assert coherent.coefficient_profile.linear_matrix.span_ratio == 1.0
@assert mixed.coefficient_profile.linear_matrix.span_ratio == 1.0e6
@assert any(
    occursin("check units and scaling", observation)
    for observation in mixed.coefficient_profile.observations
)

println(coherent)
println(mixed)
println.(mixed.coefficient_profile.observations)
