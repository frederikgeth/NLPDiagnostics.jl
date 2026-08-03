module JuMPExt # Optional direct support for JuMP.Model

import JuMP
import NLPDiagnostics

NLPDiagnostics.snapshot(model::JuMP.Model) =
    NLPDiagnostics.snapshot(JuMP.backend(model))

NLPDiagnostics.analyze(model::JuMP.Model; kwargs...) =
    NLPDiagnostics.analyze(JuMP.backend(model); kwargs...)

"""
NLPDiagnostics.solver_postmortem(model::JuMP.Model)

Read a postmortem from the optimizer currently attached to `model`. This only
uses `JuMP.unsafe_backend` to select a solver-specific, read-only adapter; it
does not expose optimizer indices or modify the model. Call it after solving,
or after explicitly attaching an optimizer for a solver-specific inspection.
"""
function NLPDiagnostics.solver_postmortem(model::JuMP.Model)
    optimizer = try
        JuMP.unsafe_backend(model)
    catch error
        throw(ArgumentError(
            "No optimizer is attached to this JuMP model. Set and attach a " *
            "supported optimizer before requesting its postmortem. " *
            "Original error: $(sprint(showerror, error))",
        ))
    end
    return NLPDiagnostics.solver_postmortem(optimizer)
end

NLPDiagnostics.solver_result_point(model::JuMP.Model; kwargs...) =
    NLPDiagnostics.solver_result_point(JuMP.backend(model); kwargs...)

NLPDiagnostics.ipopt_iteration_trace_capture(model::JuMP.Model; kwargs...) =
    NLPDiagnostics.ipopt_iteration_trace_capture(JuMP.backend(model); kwargs...)

function NLPDiagnostics.ipopt_optimize_with_iteration_trace!(
    model::JuMP.Model;
    capture::NLPDiagnostics.IterationTraceCapture = NLPDiagnostics.IterationTraceCapture(),
    capture_points::Bool = false,
)
    NLPDiagnostics.ipopt_iteration_trace_capture(JuMP.backend(model);
        capture, capture_points,
    )
    JuMP.optimize!(model)
    return NLPDiagnostics.iteration_trace(capture)
end

function NLPDiagnostics.madnlp_optimize_with_iteration_trace!(
    model::JuMP.Model;
    capture::NLPDiagnostics.IterationTraceCapture = NLPDiagnostics.IterationTraceCapture(),
)
    callback, capture = NLPDiagnostics.madnlp_iteration_trace_callback(; capture)
    JuMP.set_optimizer_attribute(model, "intermediate_callback", callback)
    JuMP.optimize!(model)
    return NLPDiagnostics.iteration_trace(capture)
end

function NLPDiagnostics.ipopt_profile_with_iteration_trace!(
    model::JuMP.Model;
    capture::NLPDiagnostics.IterationTraceCapture = NLPDiagnostics.IterationTraceCapture(),
    capture_points::Bool = false,
    kwargs...,
)
    return NLPDiagnostics.profile_solver_with_iteration_trace!(
        model,
        current -> NLPDiagnostics.ipopt_optimize_with_iteration_trace!(current;
            capture, capture_points,
        );
        kwargs...,
    )
end

function NLPDiagnostics.madnlp_profile_with_iteration_trace!(
    model::JuMP.Model;
    capture::NLPDiagnostics.IterationTraceCapture = NLPDiagnostics.IterationTraceCapture(),
    kwargs...,
)
    return NLPDiagnostics.profile_solver_with_iteration_trace!(
        model,
        current -> NLPDiagnostics.madnlp_optimize_with_iteration_trace!(current;
            capture,
        );
        kwargs...,
    )
end

function NLPDiagnostics.analyze_solver_result(
    model::JuMP.Model;
    result_index::Integer = 1,
    label::AbstractString = "solver-result",
    postmortem::Union{Nothing,NLPDiagnostics.SolverPostmortem} = nothing,
    read_postmortem::Bool = true,
    kwargs...,
)
    resolved_postmortem = postmortem
    read_error = nothing
    if isnothing(resolved_postmortem) && read_postmortem
        try
            resolved_postmortem = NLPDiagnostics.solver_postmortem(model)
        catch error
            read_error = sprint(showerror, error)
        end
    end
    return NLPDiagnostics._analyze_solver_result(
        JuMP.backend(model);
        result_index,
        label,
        postmortem = resolved_postmortem,
        postmortem_read_error = read_error,
        kwargs...,
    )
end

function NLPDiagnostics.profile_solver_result(
    model::JuMP.Model;
    name::AbstractString = "solver-result",
    label::AbstractString = "solver-result",
    result_index::Integer = 1,
    postmortem::Union{Nothing,NLPDiagnostics.SolverPostmortem} = nothing,
    read_postmortem::Bool = true,
    solver_log::Union{Nothing,AbstractString} = nothing,
    solver_name::Union{Nothing,AbstractString} = nothing,
    solver_log_residual_tolerance::Real = 1.0e-6,
    solver_log_max_evidence_lines::Integer = 20,
    solver_log_objective_agreement_factor::Real = 100,
    solver_result_objective_relative_tolerance::Real = 1.0e-6,
    iteration_trace::Union{Nothing,NLPDiagnostics.SolverIterationTrace} = nothing,
    iteration_bindings = nothing,
    iteration_kwargs::NamedTuple = NamedTuple(),
    profile_kwargs::NamedTuple = NamedTuple(),
    case_kwargs::NamedTuple = NamedTuple(),
)
    resolved_postmortem = postmortem
    read_error = nothing
    if isnothing(resolved_postmortem) && read_postmortem
        try
            resolved_postmortem = NLPDiagnostics.solver_postmortem(model)
        catch error
            read_error = sprint(showerror, error)
        end
    end
    return NLPDiagnostics._profile_solver_result(
        JuMP.backend(model);
        name,
        label,
        result_index,
        postmortem = resolved_postmortem,
        postmortem_read_error = read_error,
        read_postmortem = false,
        solver_log,
        solver_name,
        solver_log_residual_tolerance,
        solver_log_max_evidence_lines,
        solver_log_objective_agreement_factor,
        solver_result_objective_relative_tolerance,
        iteration_trace,
        iteration_bindings,
        iteration_kwargs,
        profile_kwargs,
        case_kwargs,
    )
end

NLPDiagnostics.analyze_static(model::JuMP.Model) =
    NLPDiagnostics.analyze_static(JuMP.backend(model))

NLPDiagnostics.analyze_domains(model::JuMP.Model) =
    NLPDiagnostics.analyze_domains(JuMP.backend(model))

NLPDiagnostics.analyze_derivatives(model::JuMP.Model; kwargs...) =
    NLPDiagnostics.analyze_derivatives(JuMP.backend(model); kwargs...)

NLPDiagnostics.analyze_expressions(model::JuMP.Model; kwargs...) =
    NLPDiagnostics.analyze_expressions(JuMP.backend(model); kwargs...)

NLPDiagnostics.analyze_initialization(model::JuMP.Model; kwargs...) =
    NLPDiagnostics.analyze_initialization(JuMP.backend(model); kwargs...)

NLPDiagnostics.analyze_numerical(model::JuMP.Model, point; kwargs...) =
    NLPDiagnostics.analyze_numerical(JuMP.backend(model), point; kwargs...)

NLPDiagnostics.analyze_active_set(model::JuMP.Model, point; kwargs...) =
    NLPDiagnostics.analyze_active_set(JuMP.backend(model), point; kwargs...)

NLPDiagnostics.analyze_coupled_set_qualification(model::JuMP.Model, point; kwargs...) =
    NLPDiagnostics.analyze_coupled_set_qualification(JuMP.backend(model), point; kwargs...)

NLPDiagnostics.analyze_degeneracy(model::JuMP.Model, point; kwargs...) =
    NLPDiagnostics.analyze_degeneracy(JuMP.backend(model), point; kwargs...)

NLPDiagnostics.profile_case(model::JuMP.Model, case; kwargs...) =
    NLPDiagnostics.profile_case(JuMP.backend(model), case; kwargs...)

NLPDiagnostics.profile_case_repeated(model::JuMP.Model, case; kwargs...) =
    NLPDiagnostics.profile_case_repeated(JuMP.backend(model), case; kwargs...)

NLPDiagnostics.structural_numerical_comparison(model::JuMP.Model, point; kwargs...) =
    NLPDiagnostics.structural_numerical_comparison(JuMP.backend(model), point; kwargs...)

NLPDiagnostics.evaluate_lagrangian_hessian(model::JuMP.Model, point; kwargs...) =
    NLPDiagnostics.evaluate_lagrangian_hessian(JuMP.backend(model), point; kwargs...)

NLPDiagnostics.analyze_structure(model::JuMP.Model) =
    NLPDiagnostics.analyze_structure(JuMP.backend(model))

NLPDiagnostics.evaluation_point(model::JuMP.Model, values; kwargs...) =
    NLPDiagnostics.evaluation_point(JuMP.backend(model), values; kwargs...)

NLPDiagnostics.evaluate_numerical(model::JuMP.Model, point; kwargs...) =
    NLPDiagnostics.evaluate_numerical(JuMP.backend(model), point; kwargs...)

NLPDiagnostics.constraint_feasibility_summary(model::JuMP.Model, point; kwargs...) =
    NLPDiagnostics.constraint_feasibility_summary(JuMP.backend(model), point; kwargs...)

NLPDiagnostics.coupled_set_feasibility_summary(model::JuMP.Model, point; kwargs...) =
    NLPDiagnostics.coupled_set_feasibility_summary(JuMP.backend(model), point; kwargs...)

NLPDiagnostics.coupled_set_qualification_screen(model::JuMP.Model, point; kwargs...) =
    NLPDiagnostics.coupled_set_qualification_screen(JuMP.backend(model), point; kwargs...)

NLPDiagnostics.evaluator_capabilities(model::JuMP.Model) =
    NLPDiagnostics.evaluator_capabilities(JuMP.backend(model))

NLPDiagnostics.initialization_point(model::JuMP.Model; kwargs...) =
    NLPDiagnostics.initialization_point(JuMP.backend(model); kwargs...)

NLPDiagnostics.incidence_graph(model::JuMP.Model) =
    NLPDiagnostics.incidence_graph(JuMP.backend(model))

NLPDiagnostics.maximum_matching(model::JuMP.Model) =
    NLPDiagnostics.maximum_matching(JuMP.backend(model))

NLPDiagnostics.dulmage_mendelsohn(model::JuMP.Model) =
    NLPDiagnostics.dulmage_mendelsohn(JuMP.backend(model))

NLPDiagnostics.domain_issues(model::JuMP.Model) =
    NLPDiagnostics.domain_issues(JuMP.backend(model))

NLPDiagnostics.well_determined_blocks(model::JuMP.Model) =
    NLPDiagnostics.well_determined_blocks(JuMP.backend(model))

NLPDiagnostics.structural_graph_data(model::JuMP.Model) =
    NLPDiagnostics.structural_graph_data(JuMP.backend(model))

NLPDiagnostics.structural_graph_text(model::JuMP.Model) =
    NLPDiagnostics.structural_graph_text(JuMP.backend(model))

NLPDiagnostics.structural_graph_dot(model::JuMP.Model) =
    NLPDiagnostics.structural_graph_dot(JuMP.backend(model))

NLPDiagnostics.variable_roles(model::JuMP.Model) =
    NLPDiagnostics.variable_roles(JuMP.backend(model))

end
