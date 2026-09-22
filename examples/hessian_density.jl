using JuMP
using NLPDiagnostics.Stable

model = Model()
@variable(model, x)
@variable(model, y)
@objective(model, Min, (x * y)^2)

axis = hessian_density_summary(model, [0.0, 1.0]; label = "axis point")
interior = hessian_density_summary(model, [1.0, 1.0]; label = "interior point")

@assert axis.structure_provenance == :declared_derivative_structure
@assert axis.structural_entry_count == interior.structural_entry_count == 3
@assert axis.numerical_nonzero_count == 1
@assert interior.numerical_nonzero_count == 3

println("Axis point: ", axis)
println("Interior point: ", interior)
println("Axis numerical fraction of structure: ",
    axis.numerical_fraction_of_structure)
