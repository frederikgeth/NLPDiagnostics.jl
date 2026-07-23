module JuMPExt # Optional direct support for JuMP.Model

import JuMP
import NLPDiagnostics

NLPDiagnostics.snapshot(model::JuMP.Model) =
    NLPDiagnostics.snapshot(JuMP.backend(model))

NLPDiagnostics.analyze(model::JuMP.Model; kwargs...) =
    NLPDiagnostics.analyze(JuMP.backend(model); kwargs...)

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

NLPDiagnostics.analyze_degeneracy(model::JuMP.Model, point; kwargs...) =
    NLPDiagnostics.analyze_degeneracy(JuMP.backend(model), point; kwargs...)

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
