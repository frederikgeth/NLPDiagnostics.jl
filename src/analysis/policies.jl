"""Composable policy objects for the high-dimensional `analyze` entry point."""

struct ProbePolicy
    iterative_right_nullspace_probe_dimension::Union{Nothing,Int}
    iterative_left_nullspace_probe_dimension::Union{Nothing,Int}
    iterative_spectrum_probe_dimension::Union{Nothing,Int}
    golub_kahan_probe_steps::Union{Nothing,Int}
    multi_seed_golub_kahan_probe_seed_count::Union{Nothing,Int}
    restarted_smallest_singular_candidate_dimension::Union{Nothing,Int}
    harmonic_golub_kahan_candidate_dimension::Union{Nothing,Int}
    smallest_singular_backend_crosscheck_dimension::Union{Nothing,Int}
    check_sparse_qr_nullspace::Bool
end

function _optional_positive(value, name::AbstractString)
    isnothing(value) && return nothing
    value isa Integer && value > 0 ||
        throw(ArgumentError("$name must be a positive integer or nothing"))
    return Int(value)
end

"""
    ProbePolicy(; kwargs...)

Select opt-in probe families for `analyze`. The existing probe-specific
keywords remain supported; when a `ProbePolicy` is supplied, these selectors
and `check_sparse_qr_nullspace` are authoritative while the legacy keywords
continue to provide detailed tolerances and iteration budgets.
"""
function ProbePolicy(;
    iterative_right_nullspace_probe_dimension = nothing,
    iterative_left_nullspace_probe_dimension = nothing,
    iterative_spectrum_probe_dimension = nothing,
    golub_kahan_probe_steps = nothing,
    multi_seed_golub_kahan_probe_seed_count = nothing,
    restarted_smallest_singular_candidate_dimension = nothing,
    harmonic_golub_kahan_candidate_dimension = nothing,
    smallest_singular_backend_crosscheck_dimension = nothing,
    check_sparse_qr_nullspace::Bool = false,
)
    return ProbePolicy(
        _optional_positive(
            iterative_right_nullspace_probe_dimension,
            "iterative_right_nullspace_probe_dimension",
        ),
        _optional_positive(
            iterative_left_nullspace_probe_dimension,
            "iterative_left_nullspace_probe_dimension",
        ),
        _optional_positive(
            iterative_spectrum_probe_dimension,
            "iterative_spectrum_probe_dimension",
        ),
        _optional_positive(golub_kahan_probe_steps, "golub_kahan_probe_steps"),
        _optional_positive(
            multi_seed_golub_kahan_probe_seed_count,
            "multi_seed_golub_kahan_probe_seed_count",
        ),
        _optional_positive(
            restarted_smallest_singular_candidate_dimension,
            "restarted_smallest_singular_candidate_dimension",
        ),
        _optional_positive(
            harmonic_golub_kahan_candidate_dimension,
            "harmonic_golub_kahan_candidate_dimension",
        ),
        _optional_positive(
            smallest_singular_backend_crosscheck_dimension,
            "smallest_singular_backend_crosscheck_dimension",
        ),
        check_sparse_qr_nullspace,
    )
end

"""Checks enabled by the composable `analyze` policy layer."""
struct CheckPolicy
    jacobian_directional_crosscheck::Bool
    objective_gradient_directional_crosscheck::Bool
    objective_jacobian_scaling::Bool
    convexity::Bool
    hessian_vector_crosscheck::Bool
    initialization::Bool
    active_set::Bool
    coupled_set_qualification::Bool
    degeneracy::Bool
end

# Preserve the pre-curvature positional constructor for callers that have not
# migrated to the keyword form. The new check remains opt-in by default.
CheckPolicy(
    jacobian_directional_crosscheck::Bool,
    objective_gradient_directional_crosscheck::Bool,
    objective_jacobian_scaling::Bool,
    hessian_vector_crosscheck::Bool,
    initialization::Bool,
    active_set::Bool,
    coupled_set_qualification::Bool,
    degeneracy::Bool,
) = CheckPolicy(
    jacobian_directional_crosscheck,
    objective_gradient_directional_crosscheck,
    objective_jacobian_scaling,
    false,
    hessian_vector_crosscheck,
    initialization,
    active_set,
    coupled_set_qualification,
    degeneracy,
)

"""
    CheckPolicy(; kwargs...)

Group the top-level boolean checks accepted by `analyze`. Legacy boolean
keywords remain valid and are combined with these policy selections, so
existing callers do not need to migrate in one step.
"""
function CheckPolicy(;
    jacobian_directional_crosscheck::Bool = false,
    objective_gradient_directional_crosscheck::Bool = false,
    objective_jacobian_scaling::Bool = false,
    convexity::Bool = false,
    hessian_vector_crosscheck::Bool = false,
    initialization::Bool = false,
    active_set::Bool = false,
    coupled_set_qualification::Bool = false,
    degeneracy::Bool = false,
)
    return CheckPolicy(
        jacobian_directional_crosscheck,
        objective_gradient_directional_crosscheck,
        objective_jacobian_scaling,
        convexity,
        hessian_vector_crosscheck,
        initialization,
        active_set,
        coupled_set_qualification,
        degeneracy,
    )
end
